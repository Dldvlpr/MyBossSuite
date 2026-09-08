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

Un fichier de data n'est pas qu'un releve. La structure — phases, seuils de vie,
libelles, `warnBefore` — s'ecrit a la main et ne se mesure pas. Une regeneration
FUSIONNE donc avec le fichier existant : seuls les champs mesures (`time`,
`repeatInterval`, `variable`) sont reecrits, tout le reste est conserve, y
compris les timers entierement manuels comme les seuils de phase. Sans ca chaque
passage jetterait le travail d'edition, et un boss a phases ne serait jamais
regenerable. `--replace` force le comportement d'ecrasement.

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
import os
import re
import statistics
import sys
import urllib.error
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
# lua_table sait relire un litteral Lua sans interpreteur : c'est ce qui permet
# de rouvrir un fichier de data pour le fusionner au lieu de l'ecraser.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "wa-extract"))

import lua_table  # noqa: E402
from wcl_api import (  # noqa: E402
    FLAVORS,
    WCLError,
    discover_reports,
    fetch_events,
    fetch_fight,
    get_token,
    parse_report_arg,
)

# Au-dela de cet ecart-type (en secondes) sur les deltas, le timing est traite
# comme non deterministe (cooldown interne + choix aleatoire, cast conditionne
# par une phase, etc.).
VARIABLE_STDEV = 2.5

# En dessous de ce nombre d'observations, on ne publie pas de repeatInterval.
MIN_SAMPLES = 3


def fetch_casts(token: str, code: str, fight_id: int, start: float):
    return fetch_events(token, code, fight_id, start, "Casts", "Enemies")


# ----------------------------------------------------------------------------
# Agregation
# ----------------------------------------------------------------------------

def collect(token: str, reports, npc_id: int | None, verbose: bool):
    """Retourne { abilityGameID: {"firsts": [...], "intervals": [...], "name": str} }."""
    stats = defaultdict(lambda: {"firsts": [], "intervals": [], "name": None})
    used = 0

    for code, fight_id in reports:
        try:
            fight, actors, _ = fetch_fight(token, code, fight_id)
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
# Fusion avec le fichier existant
# ----------------------------------------------------------------------------
# Ce que les logs mesurent, et donc ce qu'une regeneration a le droit de
# reecrire. Tout le reste d'un timer — trigger, phase, setPhase, seuil, libelle,
# warnBefore — est ecrit a la main : c'est de la structure, pas une mesure.
MEASURED_FIELDS = ("time", "repeatInterval", "variable")

# Triggers pour lesquels un `time` veut dire quelque chose. Ailleurs (CAST,
# AURA, EMOTE, DEATH) le champ est mort et doit disparaitre.
TIME_TRIGGERS = ("PULL", "PHASE")

# Ordre d'emission des champs, pour que deux regenerations du meme fichier
# donnent le meme diff. Les champs inconnus suivent, tries : un champ ajoute au
# format plus tard sort quand meme, il est juste mal place.
FIELD_ORDER = (
    "trigger", "time", "phase", "phases", "spellId", "castStart",
    "threshold", "pattern", "npcId", "on", "event",
    "name", "difficulties", "repeatInterval", "warnBefore", "once",
    "announce", "countdown", "flash", "bar", "variable",
    "testTime", "color", "icon", "key", "provisional",
)

# Ordre d'emission d'une entree de `phases`. Meme raison.
PHASE_FIELD_ORDER = (
    "name", "trigger", "time", "threshold", "spellId", "castStart",
    "event", "pattern", "npcId", "alert", "difficulties",
    "warnBefore", "bar", "color", "testTime",
)


def lua_array(table):
    """Partie tableau d'une table parsee (cles 1..n), dans l'ordre."""
    out, index = [], 1
    while index in table:
        out.append(table[index])
        index += 1
    return out


def lua_number(value):
    if isinstance(value, float) and value == int(value):
        return str(int(value))
    return ("%g" % value) if isinstance(value, float) else str(value)


def ordered_keys(table, order):
    """Cles de `table` : celles de `order` d'abord, le reste trie derriere."""
    keys = [key for key in order if key in table]
    return keys + sorted(key for key in table if key not in order)


def lua_value(value, order=()):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return lua_number(value)
    if isinstance(value, str):
        return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')
    if value is None:
        return "nil"
    if isinstance(value, dict):
        items = lua_array(value)
        if items and len(items) == len(value):
            return "{ %s }" % ", ".join(lua_value(item, order) for item in items)
        parts = []
        for key in ordered_keys(value, order):
            label = key if isinstance(key, str) else "[%s]" % lua_number(key)
            parts.append("%s = %s" % (label, lua_value(value[key], order)))
        return "{ %s }" % ", ".join(parts)
    raise TypeError("valeur Lua non serialisable : %r" % (value,))


def read_existing(path: Path, npc_id: int):
    """Retourne la def du boss deja presente dans `path`, ou None.

    Un fichier illisible n'est jamais ecrase en silence : l'appelant remonte
    l'erreur. Perdre des phases ecrites a la main sur une regression du parseur
    serait exactement ce que cette fusion existe pour empecher.
    """
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8")
    match = re.search(r"ns\.BossTimerData\s*\[\s*%d\s*\]\s*=\s*" % npc_id, text)
    if match is None:
        return None
    parser = lua_table.Parser(text)
    parser.pos = match.end()
    try:
        return parser.parse_value()
    except lua_table.LuaSyntaxError:
        raise
    except Exception as exc:
        # Un fichier tronque sort du parseur en IndexError, pas en
        # LuaSyntaxError. Tout ce qui rate se lit pareil ici — "je ne sais pas
        # relire ce fichier" — et doit emprunter le meme chemin, celui qui
        # refuse d'ecrire, plutot que de remonter en traceback.
        raise lua_table.LuaSyntaxError(
            "%s (offset %d)" % (exc.__class__.__name__, parser.pos)) from exc


def merge_timer(existing: dict, row):
    """Reecrit les champs mesures d'un timer, conserve tout le reste."""
    merged = dict(existing)
    if row is None:
        return merged

    trigger = merged.get("trigger", "PULL")

    if trigger == "PULL":
        # Ce qu'on mesure est un delta depuis le pull : ca ne s'ecrit que dans
        # un timer qui compte depuis le pull.
        merged["time"] = row["time"]
        merged.pop("provisional", None)
    elif trigger == "PHASE":
        # Compte depuis l'entree dans sa phase — une origine que l'ingestion ne
        # sait pas encore situer dans un log. Y ecrire le delta depuis le pull
        # donnerait un chiffre precis et faux, donc `time` reste ecrit a la main
        # et le timer reste provisoire. Un meme sort porte souvent un timer par
        # phase (Flame Breath en P1 et en P3) : sans cette distinction, la
        # mesure de la P1 ecraserait le timing de la P3.
        pass
    else:
        merged.pop("time", None)

    # La cadence, elle, ne depend pas de l'origine : un sort relance toutes les
    # 22 s les relance toutes les 22 s dans n'importe quelle phase.
    if row["repeatInterval"]:
        merged["repeatInterval"] = row["repeatInterval"]
    if row["variable"]:
        merged["variable"] = True
    else:
        merged.pop("variable", None)
    return merged


def new_timer(row):
    timer = {"trigger": "PULL", "time": row["time"], "spellId": row["spellId"], "bar": True}
    if row["repeatInterval"]:
        timer["repeatInterval"] = row["repeatInterval"]
    if row["variable"]:
        timer["variable"] = True
    return timer


def merge_timers(existing_timers, rows):
    """Retourne [(timer, row|None), ...] : l'ordre du fichier existant d'abord.

    Conserver l'ordre plutot que retrier par `time` garde les diffs lisibles
    d'un passage a l'autre. Les sorts jamais vus jusqu'ici arrivent a la fin,
    la ou on les remarque.
    """
    by_spell = {row["spellId"]: row for row in rows}
    merged, seen = [], set()

    for timer in existing_timers:
        spell = timer.get("spellId")
        row = by_spell.get(spell) if spell is not None else None
        if row is not None:
            seen.add(spell)
        merged.append((merge_timer(timer, row), row))

    for row in rows:
        if row["spellId"] not in seen:
            merged.append((new_timer(row), row))

    return merged


def merge_header(args, existing):
    """Champs de tete du boss : la CLI tranche, l'existant comble le reste.

    `phases` passe par ici sans y toucher : c'est devenu le champ le plus
    manuel du format — la mecanique du combat, pas une mesure — et donc celui
    qu'une regeneration ne doit surtout pas perdre.
    """
    header = dict(existing) if existing else {}
    header.pop("timers", None)
    header["name"] = args.boss
    header["kind"] = args.kind
    if args.encounter:
        header["encounterId"] = args.encounter
    if args.zone:
        header["zone"] = args.zone
    if "flavors" not in header:
        header["flavors"] = {args.flavor: True}
    return header


# ----------------------------------------------------------------------------
# Emission Lua
# ----------------------------------------------------------------------------

HEADER_ORDER = (
    "name", "kind", "encounterId", "instanceId", "npcIds", "flavors", "zone",
    "inactivity", "wipeGrace", "idleTimeout", "phases", "provisional",
)


def render_timer(timer, row, merged_existing: bool):
    lines = []
    if row is not None:
        lines.append(
            "        -- %d log(s), sigma pull %ss / interval %ss"
            % (row["samples"], row["timeStdev"], row["intervalStdev"])
        )
    elif merged_existing:
        what = ("spell %d absent des logs de ce passage" % timer["spellId"]
                if timer.get("spellId") else "entree ecrite a la main")
        lines.append("        -- conserve : %s" % what)

    keys = ordered_keys(timer, FIELD_ORDER)
    width = max(len(k) for k in keys) if keys else 0

    lines.append("        {")
    for key in keys:
        lines.append("            %-*s = %s," % (width, key, lua_value(timer[key])))
    lines.append("        },")
    return lines


def render_lua(args, header, timers, encounter_name: str, used_reports: int) -> str:
    merged_existing = any(row is None for _, row in timers)
    lines = [
        "-- %s — flavor %s (npcId %d)" % (args.boss, args.flavor, args.npc_id),
        "--",
        "-- GENERE PAR tools/wcl-ingest/wcl_ingest.py — mediane des deltas mesures.",
        "-- Rencontre WCL : %s | logs retenus : %d" % (encounter_name or "?", used_reports),
        "-- Les timers marques `variable` ont un ecart-type eleve : mecanique non",
        "-- deterministe, la barre s'affiche comme incertaine.",
        "--",
        "-- Regeneration : seuls `repeatInterval`, `variable` et le `time` des timers",
        "-- PULL sont reecrits — le `time` d'un timer PHASE compte depuis l'entree",
        "-- dans sa phase, que l'ingestion ne sait pas situer. Phases, seuils,",
        "-- libelles, annonces et tout autre champ ecrit a la main sont conserves :",
        "-- editer ce fichier est sur, relancer l'ingestion ne les effacera pas.",
        "",
        "local _, ns = ...",
        "",
        "ns.BossTimerData[%d] = {" % args.npc_id,
    ]

    keys = ordered_keys(header, HEADER_ORDER)
    width = max([len(k) for k in keys] + [len("timers")])
    for key in keys:
        if key == "phases":
            # Une phase par ligne : c'est la mecanique du combat, ca se relit et
            # ca se corrige a la main, pas sur une ligne de 200 colonnes.
            lines.append("    %-*s = {" % (width, "phases"))
            for phase in lua_array(header["phases"]):
                lines.append("        %s," % lua_value(phase, PHASE_FIELD_ORDER))
            lines.append("    },")
        else:
            lines.append("    %-*s = %s," % (width, key, lua_value(header[key])))

    lines.append("    %-*s = {" % (width, "timers"))
    for timer, row in timers:
        lines.extend(render_timer(timer, row, merged_existing))
    lines += ["    },", "}", ""]

    encounter_id = header.get("encounterId")
    if encounter_id:
        lines.append("-- ENCOUNTER_START livre un encounterID, pas un npcId.")
        lines.append("ns.BossTimerEncounter[%d] = %d" % (encounter_id, args.npc_id))
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
    parser.add_argument("--flavor", required=True, choices=FLAVORS)
    parser.add_argument("--raid", required=True, help="dossier de zone (raid, donjon ou zone de monde), ex. Onyxias_Lair")
    parser.add_argument("--kind", default="raid", choices=["raid", "dungeon", "world"],
                        help="nature de la rencontre : raid (defaut), dungeon ou world (world boss)")
    parser.add_argument("--zone", help="nom de zone affiche par /mbs boss list")
    parser.add_argument("--boss", required=True, help="nom du boss (affichage + nom de fichier)")
    parser.add_argument("--limit", type=int, default=10, help="nombre de logs (defaut 10)")
    parser.add_argument("--min-reports", type=int, default=2,
                        help="nombre minimum de logs ou un sort doit apparaitre (defaut 2)")
    parser.add_argument("--out", help="chemin de sortie (defaut : Modules/BossTimer/Data/<flavor>/<raid>/<boss>.lua)")
    parser.add_argument("--replace", action="store_true",
                        help="ecrase le fichier existant au lieu de le fusionner "
                             "(perd phases, seuils et libelles ecrits a la main)")
    parser.add_argument("--dry-run", action="store_true", help="affiche les stats sans ecrire de fichier")
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args(argv)


def resolve_out(args) -> Path:
    if args.out:
        return Path(args.out)
    return Path("Modules/BossTimer/Data") / args.flavor / args.raid / ("%s.lua" % args.boss)


def main(argv=None) -> int:
    args = parse_args(argv)
    out = resolve_out(args)

    # Relu avant le moindre appel API : un fichier qu'on ne sait pas relire doit
    # arreter le passage tout de suite, pas apres dix requetes et juste avant de
    # l'ecraser.
    existing = None
    if not args.replace:
        try:
            existing = read_existing(out, args.npc_id)
        except lua_table.LuaSyntaxError as exc:
            print("%s est illisible (%s) : corrige-le, ou passe --replace pour "
                  "repartir de zero en acceptant de perdre ce qu'il contient."
                  % (out, exc), file=sys.stderr)
            return 2
        if existing is not None and not isinstance(existing, dict):
            print("%s : ns.BossTimerData[%d] n'est pas une table." % (out, args.npc_id),
                  file=sys.stderr)
            return 2

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
        try:
            reports.append(parse_report_arg(item))
        except WCLError as exc:
            print(exc, file=sys.stderr)
            return 2

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

    existing_timers = lua_array(existing.get("timers") or {}) if existing else []
    if existing_timers:
        kept = sum(1 for timer, row in merge_timers(existing_timers, rows) if row is None)
        print("fusion avec %s : %d timer(s) existant(s), %d conserve(s) tel(s) quel(s)."
              % (out, len(existing_timers), kept))

    print(f"{len(rows)} sort(s) retenu(s) sur {used} log(s) :")
    for row in rows:
        flag = " [variable]" if row["variable"] else ""
        interval = f", toutes les {row['repeatInterval']}s" if row["repeatInterval"] else ""
        print(f"  spell {row['spellId']:>7} : pull +{row['time']}s{interval}"
              f" ({row['samples']} log(s)){flag}")

    lua = render_lua(args, merge_header(args, existing),
                     merge_timers(existing_timers, rows), encounter_name, used)
    if args.dry_run:
        print()
        print(lua)
        return 0

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(lua, encoding="utf-8")
    print(f"\necrit : {out}")
    print("Pense a relancer tools/gen-toc.sh pour inscrire le fichier dans les .toc.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
