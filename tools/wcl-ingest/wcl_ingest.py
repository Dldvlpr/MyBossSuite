#!/usr/bin/env python3
"""Ingestion WarcraftLogs -> fichier de data MyBossSuite.

Source principale de timings : les logs sont des faits mesures, pas une oeuvre
derivee, et l'API couvre les 6 flavors via les partitions / zones. Un seul
script produit donc la data de toutes les versions du jeu.

Principe : pour N logs d'un meme boss, on releve pour chaque sort ennemi le
delta entre le debut du combat et chaque cast, puis on prend la MEDIANE (robuste
aux pulls rates et aux outliers). Si l'ecart-type des deltas est eleve, le timer
est marque `variable = true` : la barre s'affichera comme incertaine plutot que
de mentir sur une precision qu'on n'a pas.

Pre-requis : un client API sur https://www.warcraftlogs.com/api/clients/ (OAuth,
gratuit), puis :

    export WCL_CLIENT_ID=...
    export WCL_CLIENT_SECRET=...

Exemples :

    # decouverte automatique des logs via le classement de la rencontre
    tools/wcl-ingest/wcl_ingest.py --encounter 1084 --npc-id 10184 \
        --flavor vanilla --raid "Onyxias_Lair" --boss Onyxia --limit 10

    # logs choisis a la main
    tools/wcl-ingest/wcl_ingest.py --report aBcDeFgH:12 --report xYz123:4 \
        --npc-id 10184 --flavor vanilla --raid "Onyxias_Lair" --boss Onyxia
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

TOKEN_URL = "https://www.warcraftlogs.com/oauth/token"
API_URL = "https://www.warcraftlogs.com/api/v2/client"

# Au-dela de cet ecart-type (en secondes) sur les deltas, le timing est traite
# comme non deterministe (cooldown interne + choix aleatoire, cast conditionne
# par une phase, etc.).
VARIABLE_STDEV = 2.5

# En dessous de ce nombre d'observations, on ne publie pas de repeatInterval.
MIN_SAMPLES = 3


class WCLError(RuntimeError):
    pass


# ----------------------------------------------------------------------------
# Transport
# ----------------------------------------------------------------------------

def get_token(client_id: str, client_secret: str) -> str:
    data = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
    request = urllib.request.Request(TOKEN_URL, data=data)
    credentials = f"{client_id}:{client_secret}".encode()
    import base64

    request.add_header("Authorization", "Basic " + base64.b64encode(credentials).decode())
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)["access_token"]
    except urllib.error.HTTPError as exc:
        raise WCLError(f"OAuth refuse ({exc.code}) : verifie WCL_CLIENT_ID / WCL_CLIENT_SECRET") from exc


def graphql(token: str, query: str, variables: dict) -> dict:
    payload = json.dumps({"query": query, "variables": variables}).encode()
    request = urllib.request.Request(API_URL, data=payload)
    request.add_header("Authorization", "Bearer " + token)
    request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=60) as response:
        body = json.load(response)
    if "errors" in body:
        raise WCLError(json.dumps(body["errors"], indent=2))
    return body["data"]


# ----------------------------------------------------------------------------
# Requetes
# ----------------------------------------------------------------------------

RANKINGS_QUERY = """
query($encounterId: Int!, $partition: Int) {
  worldData {
    encounter(id: $encounterId) {
      name
      fightRankings(metric: speed, partition: $partition)
    }
  }
}
"""

FIGHT_QUERY = """
query($code: String!, $fight: Int!) {
  reportData {
    report(code: $code) {
      fights(fightIDs: [$fight]) {
        id
        startTime
        endTime
        encounterID
        name
      }
      masterData {
        actors(type: "NPC") { id gameID name }
      }
    }
  }
}
"""

EVENTS_QUERY = """
query($code: String!, $fight: Int!, $start: Float) {
  reportData {
    report(code: $code) {
      events(
        dataType: Casts
        hostilityType: Enemies
        fightIDs: [$fight]
        startTime: $start
        limit: 10000
      ) {
        data
        nextPageTimestamp
      }
    }
  }
}
"""


def discover_reports(token: str, encounter_id: int, limit: int, partition: int | None):
    data = graphql(token, RANKINGS_QUERY, {"encounterId": encounter_id, "partition": partition})
    encounter = data["worldData"]["encounter"]
    if not encounter:
        raise WCLError(f"rencontre {encounter_id} inconnue")
    rankings = encounter["fightRankings"] or {}
    out = []
    for ranking in rankings.get("rankings", [])[:limit]:
        report = ranking.get("report") or {}
        code, fight = report.get("code"), report.get("fightID")
        if code and fight:
            out.append((code, int(fight)))
    return encounter["name"], out


def fetch_fight(token: str, code: str, fight_id: int):
    data = graphql(token, FIGHT_QUERY, {"code": code, "fight": fight_id})
    report = data["reportData"]["report"]
    fights = report["fights"]
    if not fights:
        raise WCLError(f"combat {fight_id} absent du rapport {code}")
    actors = {a["id"]: a for a in (report["masterData"]["actors"] or [])}
    return fights[0], actors


def fetch_casts(token: str, code: str, fight_id: int, start: float):
    events, cursor = [], start
    while cursor is not None:
        data = graphql(token, EVENTS_QUERY, {"code": code, "fight": fight_id, "start": cursor})
        block = data["reportData"]["report"]["events"]
        events.extend(block["data"] or [])
        cursor = block.get("nextPageTimestamp")
    return events


# ----------------------------------------------------------------------------
# Agregation
# ----------------------------------------------------------------------------

def collect(token: str, reports, npc_id: int | None, verbose: bool):
    """Retourne { abilityGameID: {"firsts": [...], "intervals": [...], "name": str} }."""
    stats = defaultdict(lambda: {"firsts": [], "intervals": [], "name": None})
    used = 0

    for code, fight_id in reports:
        try:
            fight, actors = fetch_fight(token, code, fight_id)
            events = fetch_casts(token, code, fight_id, float(fight["startTime"]))
        except (WCLError, urllib.error.URLError) as exc:
            print(f"  ! {code}:{fight_id} ignore ({exc})", file=sys.stderr)
            continue

        pull = float(fight["startTime"])
        by_ability = defaultdict(list)

        for event in events:
            if event.get("type") not in ("cast", "begincast"):
                continue
            source = actors.get(event.get("sourceID"))
            if source is None:
                continue
            if npc_id is not None and source.get("gameID") != npc_id:
                continue
            ability = event.get("abilityGameID")
            if ability is None:
                continue
            by_ability[ability].append((float(event["timestamp"]) - pull) / 1000.0)

        if not by_ability:
            print(f"  ! {code}:{fight_id} : aucun cast ennemi retenu", file=sys.stderr)
            continue

        used += 1
        for ability, times in by_ability.items():
            times.sort()
            entry = stats[ability]
            entry["firsts"].append(times[0])
            entry["intervals"].extend(
                round(b - a, 2) for a, b in zip(times, times[1:]) if 1.0 < (b - a) < 600.0
            )

        if verbose:
            print(f"  + {code}:{fight_id} — {len(by_ability)} sort(s), pull {fight['name']}")

    return stats, used


def summarise(stats, min_reports: int):
    rows = []
    for ability, entry in stats.items():
        firsts = entry["firsts"]
        if len(firsts) < min_reports:
            continue
        first = statistics.median(firsts)
        first_stdev = statistics.pstdev(firsts) if len(firsts) > 1 else 0.0

        intervals = entry["intervals"]
        interval = statistics.median(intervals) if len(intervals) >= MIN_SAMPLES else None
        interval_stdev = statistics.pstdev(intervals) if len(intervals) > 1 else 0.0

        rows.append(
            {
                "spellId": ability,
                "time": round(first, 1),
                "timeStdev": round(first_stdev, 2),
                "repeatInterval": round(interval, 1) if interval else None,
                "intervalStdev": round(interval_stdev, 2),
                "samples": len(firsts),
                "variable": max(first_stdev, interval_stdev) > VARIABLE_STDEV,
            }
        )
    rows.sort(key=lambda row: row["time"])
    return rows


# ----------------------------------------------------------------------------
# Emission Lua
# ----------------------------------------------------------------------------

def render_lua(args, rows, encounter_name: str, used_reports: int) -> str:
    lines = [
        f"-- {args.boss} — flavor {args.flavor} (npcId {args.npc_id})",
        "--",
        "-- GENERE PAR tools/wcl-ingest/wcl_ingest.py — mediane des deltas mesures.",
        f"-- Rencontre WCL : {encounter_name or '?'} | logs retenus : {used_reports}",
        "-- Les timers marques `variable` ont un ecart-type eleve : mecanique non",
        "-- deterministe, la barre s'affiche comme incertaine.",
        "",
        "local _, ns = ...",
        "",
        f"ns.BossTimerData[{args.npc_id}] = {{",
        f'    name    = "{args.boss}",',
    ]
    if args.encounter:
        lines.append(f"    encounterId = {args.encounter},")
    lines += [
        f"    flavors = {{ {args.flavor} = true }},",
        "    timers  = {",
    ]

    for row in rows:
        parts = [
            '            trigger        = "PULL",',
            f"            time           = {row['time']},",
            f"            spellId        = {row['spellId']},",
        ]
        if row["repeatInterval"]:
            parts.append(f"            repeatInterval = {row['repeatInterval']},")
        if row["variable"]:
            parts.append("            variable       = true,")
        parts.append("            bar            = true,")
        comment = (
            f"        -- {row['samples']} log(s), sigma pull {row['timeStdev']}s"
            f" / interval {row['intervalStdev']}s"
        )
        lines.append(comment)
        lines.append("        {")
        lines.extend(parts)
        lines.append("        },")

    lines += ["    },", "}", ""]
    if args.encounter:
        lines.append(f"ns.BossTimerEncounter[{args.encounter}] = {args.npc_id}")
        lines.append("")
    return "\n".join(lines)


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--report", action="append", default=[], metavar="CODE:FIGHT",
                        help="log a analyser, repetable")
    parser.add_argument("--encounter", type=int, help="encounterID WCL (decouverte automatique des logs)")
    parser.add_argument("--partition", type=int, help="partition WCL (une par version/saison)")
    parser.add_argument("--npc-id", type=int, required=True, help="npcId du boss, cle du fichier de data")
    parser.add_argument("--flavor", required=True,
                        choices=["vanilla", "tbc", "wrath", "cata", "mists", "retail"])
    parser.add_argument("--raid", required=True, help="dossier de raid, ex. Onyxias_Lair")
    parser.add_argument("--boss", required=True, help="nom du boss (affichage + nom de fichier)")
    parser.add_argument("--limit", type=int, default=10, help="nombre de logs (defaut 10)")
    parser.add_argument("--min-reports", type=int, default=2,
                        help="nombre minimum de logs ou un sort doit apparaitre (defaut 2)")
    parser.add_argument("--out", help="chemin de sortie (defaut : Modules/BossTimer/Data/<flavor>/<raid>/<boss>.lua)")
    parser.add_argument("--dry-run", action="store_true", help="affiche les stats sans ecrire de fichier")
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    client_id = os.environ.get("WCL_CLIENT_ID")
    client_secret = os.environ.get("WCL_CLIENT_SECRET")
    if not client_id or not client_secret:
        print("WCL_CLIENT_ID / WCL_CLIENT_SECRET manquants dans l'environnement.", file=sys.stderr)
        return 2

    try:
        token = get_token(client_id, client_secret)
    except WCLError as exc:
        print(exc, file=sys.stderr)
        return 2

    encounter_name = ""
    reports = []
    for item in args.report:
        code, _, fight = item.partition(":")
        if not fight.isdigit():
            print(f"format attendu CODE:FIGHT, recu {item!r}", file=sys.stderr)
            return 2
        reports.append((code, int(fight)))

    if args.encounter and not reports:
        try:
            encounter_name, reports = discover_reports(token, args.encounter, args.limit, args.partition)
        except WCLError as exc:
            print(exc, file=sys.stderr)
            return 2

    if not reports:
        print("aucun log a analyser : passe --report CODE:FIGHT ou --encounter <id>.", file=sys.stderr)
        return 2

    print(f"analyse de {len(reports)} log(s)...")
    stats, used = collect(token, reports, args.npc_id, args.verbose)
    if used == 0:
        print("aucun log exploitable (npcId correct ?).", file=sys.stderr)
        return 1

    rows = summarise(stats, args.min_reports)
    if not rows:
        print("aucun sort retenu : baisse --min-reports.", file=sys.stderr)
        return 1

    print(f"{len(rows)} sort(s) retenu(s) sur {used} log(s) :")
    for row in rows:
        flag = " [variable]" if row["variable"] else ""
        interval = f", toutes les {row['repeatInterval']}s" if row["repeatInterval"] else ""
        print(f"  spell {row['spellId']:>7} : pull +{row['time']}s{interval}"
              f" ({row['samples']} log(s)){flag}")

    lua = render_lua(args, rows, encounter_name, used)
    if args.dry_run:
        print()
        print(lua)
        return 0

    out = Path(args.out) if args.out else Path("Modules/BossTimer/Data") / args.flavor / args.raid / f"{args.boss}.lua"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(lua, encoding="utf-8")
    print(f"\necrit : {out}")
    print("Pense a relancer tools/gen-toc.sh pour inscrire le fichier dans les .toc.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
