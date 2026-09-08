#!/usr/bin/env python3
"""Ingestion WarcraftLogs -> data des alertes kick et move.

Deux listes, deux natures de preuve — c'est la distinction qui structure tout le
script :

  * KICK (`Modules/InterruptAlert/Data/<flavor>/<Raid>.lua`)
    Un sort qui apparait en `extraAbilityGameID` d'un evenement `interrupt` a ete
    interrompu pour de vrai, dans cette version du jeu. C'est une PREUVE : une
    seule occurrence suffit, aucun seuil statistique n'a de sens.

  * MOVE (`Modules/MoveAlert/Data/<flavor>/<Raid>.lua`)
    Aucun evenement ne dit "ce sort etait evitable". C'est une STATISTIQUE, et
    les criteres sont donc explicites et auditables (voir plus bas). Chaque
    entree generee porte en commentaire les chiffres qui l'ont fait passer, pour
    qu'un humain puisse la contester.

Les deux sont des faits mesures dans des logs, pas une oeuvre derivee d'un autre
addon : aucune contrainte de licence, contrairement a une reprise de la base de
GTFO ou de DBM.

## Criteres "move"

Un sort est retenu comme zone evitable si :

  1. il a touche au moins `--min-targets` joueurs differents ;
  2. il n'est PAS explique par un debuff du meme sort sur la cible au moment du
     coup (moins de 50 % des coups) — sinon c'est un DoT, et s'ecarter n'y change
     rien ;
  3. il n'a pas touche tout le raid a chaque pull (`--raid-wide`) — un degat de
     raid inevitable n'est pas un "bouge" ;
  4. il est periodique (tick), OU il touche des joueurs DIFFERENTS d'un pull a
     l'autre (`--min-spread`). C'est ce dernier critere qui separe un swirl au
     sol d'un cleave : le cleave touche les memes corps a corps a chaque pull, la
     zone touche ceux qui n'en sont pas sortis.

Avec un seul log, le critere 4 ne peut pas se prononcer : les sorts non
periodiques sont alors ecartes. C'est volontaire — mieux vaut une liste courte
et juste qu'une liste longue qui alerte a tort.

## Usage

    # identifiants dans `.env` a la racine du depot (voir `.env.example`),
    # ou dans l'environnement, qui reste prioritaire.

    # les deux listes, decouverte automatique des logs
    tools/wcl-ingest/wcl_alerts.py --encounter 1084 --npc-id 10184 \\
        --flavor vanilla --raid "Onyxias_Lair" --limit 15

    # seulement les kicks, sur des logs choisis
    tools/wcl-ingest/wcl_alerts.py --mode interrupts \\
        --report aBcDeFgH:12 --report xYz123:4 --flavor vanilla --raid "Onyxias_Lair"

Le fichier d'un raid s'enrichit boss par boss : les entrees deja presentes sont
conservees et fusionnees, sauf avec `--replace`.
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys
import urllib.error
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from wcl_api import (  # noqa: E402
    FLAVORS,
    WCLError,
    discover_reports,
    fetch_events,
    fetch_fight,
    get_token,
    load_credentials,
    parse_report_arg,
)

# WCL numerote l'attaque au corps a corps 1 : ce n'est ni un kick ni une zone.
MELEE_ABILITY = 1

# Au-dela de cette fraction des coups couverts par un debuff du meme sort, on
# considere que le sort est un DoT.
DEBUFF_RATIO_MAX = 0.5

TARGET_TABLE = {
    "interrupts": ("InterruptableData", "InterruptAlert"),
    "zones": ("MoveAlertData", "MoveAlert"),
}


# ----------------------------------------------------------------------------
# Kick : liste de preuves
# ----------------------------------------------------------------------------

def extract_interrupts(events, actors, npc_id):
    """Sorts interrompus dans ces events. `extraAbilityGameID` = le sort coupe,
    `abilityGameID` serait le kick lui-meme."""
    out = []
    for event in events:
        if event.get("type") != "interrupt":
            continue
        spell = event.get("extraAbilityGameID")
        if not spell or spell == MELEE_ABILITY:
            continue
        if npc_id is not None:
            target = actors.get(event.get("targetID")) or {}
            if target.get("gameID") != npc_id:
                continue
        out.append(spell)
    return out


def collect_interrupts(token, reports, npc_id, verbose):
    """{ spellId: {"name", "count", "reports": set} } — sorts reellement interrompus."""
    found = defaultdict(lambda: {"name": None, "count": 0, "reports": set()})
    used = 0

    for code, fight_id in reports:
        try:
            fight, actors, abilities = fetch_fight(token, code, fight_id)
            # hostilityType Friendlies : la source d'un kick est un joueur.
            events = fetch_events(token, code, fight_id, float(fight["startTime"]),
                                  "Interrupts", "Friendlies")
        except (WCLError, urllib.error.URLError) as exc:
            print(f"  ! {code}:{fight_id} ignore ({exc})", file=sys.stderr)
            continue

        used += 1
        spells = extract_interrupts(events, actors, npc_id)
        for spell in spells:
            entry = found[spell]
            entry["count"] += 1
            entry["reports"].add(f"{code}:{fight_id}")
            entry["name"] = entry["name"] or abilities.get(spell)

        if verbose:
            print(f"  + {code}:{fight_id} — {len(spells)} interruption(s)")

    return found, used


# ----------------------------------------------------------------------------
# Move : statistique auditable
# ----------------------------------------------------------------------------

def debuff_windows(events, fight_end):
    """{ (targetID, ability): [(start, end), ...] } depuis les events de debuff."""
    windows = defaultdict(list)
    open_at = {}

    for event in events:
        kind = event.get("type")
        key = (event.get("targetID"), event.get("abilityGameID"))
        timestamp = float(event.get("timestamp", 0))
        if kind in ("applydebuff", "refreshdebuff"):
            open_at.setdefault(key, timestamp)
        elif kind == "removedebuff":
            start = open_at.pop(key, None)
            if start is not None:
                windows[key].append((start, timestamp))

    # Un debuff encore actif a la fin du combat n'a pas d'evenement de retrait.
    for key, start in open_at.items():
        windows[key].append((start, fight_end))

    return windows


def covered_by_debuff(windows, target, ability, timestamp) -> bool:
    for start, end in windows.get((target, ability), ()):
        # Marge d'une demi-seconde : le premier tick tombe parfois quelques
        # dizaines de millisecondes avant l'application enregistree.
        if start - 500 <= timestamp <= end + 500:
            return True
    return False


def new_stats():
    return defaultdict(lambda: {
        "name": None,
        "targets": set(),          # tous les joueurs touches, tous pulls confondus
        "per_fight_targets": [],   # nombre de joueurs touches, pull par pull
        "hits": 0,
        "ticks": 0,
        "debuffed": 0,
        "reports": set(),
        "raid_ratios": [],
    })


def aggregate_fight(damage, windows, actors, npc_id):
    """Degats subis d'un pull, regroupes par sort. Fonction pure : c'est elle qui
    porte le filtrage, donc c'est elle qu'on teste."""
    by_ability = defaultdict(lambda: {"targets": set(), "hits": 0, "ticks": 0, "debuffed": 0})

    for event in damage:
        if event.get("type") != "damage":
            continue
        ability = event.get("abilityGameID")
        if not ability or ability == MELEE_ABILITY:
            continue

        source = actors.get(event.get("sourceID"))
        # Une source joueur, c'est du degat de zone allie ou une chute mal
        # attribuee : rien a voir avec "sors de la zone".
        if source is not None and source.get("type") == "Player":
            continue
        if npc_id is not None and (source or {}).get("gameID") != npc_id:
            continue

        target = event.get("targetID")
        row = by_ability[ability]
        row["targets"].add(target)
        row["hits"] += 1
        if event.get("tick"):
            row["ticks"] += 1
        if covered_by_debuff(windows, target, ability, float(event.get("timestamp", 0))):
            row["debuffed"] += 1

    return by_ability


def merge_fight(stats, by_ability, raid_size, key, abilities=None):
    for ability, row in by_ability.items():
        entry = stats[ability]
        entry["name"] = entry["name"] or (abilities or {}).get(ability)
        entry["targets"].update(row["targets"])
        entry["per_fight_targets"].append(len(row["targets"]))
        entry["hits"] += row["hits"]
        entry["ticks"] += row["ticks"]
        entry["debuffed"] += row["debuffed"]
        entry["reports"].add(key)
        entry["raid_ratios"].append(len(row["targets"]) / raid_size)


def collect_zones(token, reports, npc_id, verbose):
    """Agrege, par sort, de quoi decider s'il s'agit d'une zone evitable."""
    stats = new_stats()
    used = 0

    for code, fight_id in reports:
        try:
            fight, actors, abilities = fetch_fight(token, code, fight_id)
            start = float(fight["startTime"])
            damage = fetch_events(token, code, fight_id, start, "DamageTaken", "Friendlies")
            debuffs = fetch_events(token, code, fight_id, start, "Debuffs", "Friendlies")
        except (WCLError, urllib.error.URLError) as exc:
            print(f"  ! {code}:{fight_id} ignore ({exc})", file=sys.stderr)
            continue

        raid_size = len(fight.get("friendlyPlayers") or []) or 1
        windows = debuff_windows(debuffs, float(fight["endTime"]))
        by_ability = aggregate_fight(damage, windows, actors, npc_id)

        if not by_ability:
            print(f"  ! {code}:{fight_id} : aucun degat subi retenu", file=sys.stderr)
            continue

        used += 1
        merge_fight(stats, by_ability, raid_size, f"{code}:{fight_id}", abilities)

        if verbose:
            print(f"  + {code}:{fight_id} — {len(by_ability)} sort(s) subi(s), raid {raid_size}")

    return stats, used


def classify_zones(stats, args):
    """Retourne (retenus, rejetes) — les rejetes portent la raison, pour le tuning."""
    kept, dropped = [], []

    for ability, entry in stats.items():
        hits = entry["hits"]
        targets = len(entry["targets"])
        per_fight = entry["per_fight_targets"] or [0]
        median_targets = statistics.median(per_fight) or 1
        spread = targets / median_targets
        debuff_ratio = (entry["debuffed"] / hits) if hits else 0.0
        raid_ratio = statistics.median(entry["raid_ratios"] or [0])
        periodic = entry["ticks"] > 0

        row = {
            "spellId": ability,
            "name": entry["name"],
            "targets": targets,
            "hits": hits,
            "ticks": entry["ticks"],
            "periodic": periodic,
            "spread": round(spread, 2),
            "debuffRatio": round(debuff_ratio, 2),
            "raidRatio": round(raid_ratio, 2),
            "reports": len(entry["reports"]),
        }

        if row["reports"] < args.min_reports:
            row["reason"] = f"vu dans {row['reports']} log(s) seulement"
        elif targets < args.min_targets:
            row["reason"] = f"{targets} joueur(s) touche(s)"
        elif debuff_ratio >= DEBUFF_RATIO_MAX:
            row["reason"] = f"debuff du meme sort sur {debuff_ratio:.0%} des coups (DoT)"
        elif raid_ratio >= args.raid_wide:
            row["reason"] = f"touche {raid_ratio:.0%} du raid (degat inevitable)"
        elif not periodic and spread < args.min_spread:
            row["reason"] = f"non periodique et toujours les memes cibles (spread {spread:.2f})"
        else:
            row["reason"] = None

        (kept if row["reason"] is None else dropped).append(row)

    kept.sort(key=lambda r: (-r["targets"], r["spellId"]))
    dropped.sort(key=lambda r: r["spellId"])
    return kept, dropped


# ----------------------------------------------------------------------------
# Emission Lua
# ----------------------------------------------------------------------------

ENTRY_RE = re.compile(r"^ns\.(\w+)\[(\d+)\]\s*=\s*true\s*(?:--\s*(.*))?$")


def read_existing(path: Path, table: str):
    """Relit nos propres entrees pour qu'un raid s'enrichisse boss par boss."""
    if not path.exists():
        return {}
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = ENTRY_RE.match(line.strip())
        if match and match.group(1) == table:
            out[int(match.group(2))] = (match.group(3) or "").strip()
    return out


def render_lua(mode: str, args, entries: dict) -> str:
    table, _ = TARGET_TABLE[mode]
    title = ("Sorts interruptibles" if mode == "interrupts"
             else "Zones a fuir (alerte MOVE)")
    lines = [
        f"-- {args.raid} — flavor {args.flavor}",
        f"-- {title}",
        "--",
        "-- GENERE PAR tools/wcl-ingest/wcl_alerts.py — ne pas editer a la main,",
        "-- relancer l'outil (les entrees existantes sont conservees et fusionnees).",
        "--",
    ]
    if mode == "interrupts":
        lines += [
            "-- Chaque entree est une PREUVE : ce sort a ete interrompu dans un log de",
            "-- cette version du jeu. La liste ne sert que de repli quand le client ne",
            "-- sait pas repondre sur une unite hostile — quand l'API repond, elle prime.",
        ]
    else:
        lines += [
            "-- Chaque entree est une STATISTIQUE : les chiffres qui l'ont fait retenir",
            "-- sont en commentaire, pour pouvoir la contester. Un faux positif se",
            "-- retire avec /mbs move ignore <spellId>, sans toucher a ce fichier.",
        ]
    lines += [
        "",
        "local _, ns = ...",
        "",
    ]

    for spell in sorted(entries):
        comment = entries[spell]
        suffix = f"   -- {comment}" if comment else ""
        lines.append(f"ns.{table}[{spell}] = true{suffix}")

    lines.append("")
    return "\n".join(lines)


def write_output(mode: str, args, rows, describe) -> Path:
    table, module = TARGET_TABLE[mode]
    out = (Path(args.out) if args.out
           else Path("Modules") / module / "Data" / args.flavor / f"{args.raid}.lua")

    entries = {} if args.replace else read_existing(out, table)
    for row in rows:
        entries[row["spellId"]] = describe(row)

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render_lua(mode, args, entries), encoding="utf-8")
    return out


def describe_interrupt(row):
    name = row["name"] or "?"
    return f"{name} — {row['count']} interruption(s), {row['reports']} log(s)"


def describe_zone(row):
    name = row["name"] or "?"
    kind = "periodique" if row["periodic"] else "coup unique"
    return (f"{name} — {kind}, {row['targets']} joueur(s), {row['hits']} coup(s), "
            f"spread {row['spread']}, {row['reports']} log(s)")


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=["interrupts", "zones", "both"], default="both",
                        help="quelle(s) liste(s) generer (defaut : les deux, un seul passage)")
    parser.add_argument("--report", action="append", default=[], metavar="CODE:FIGHT",
                        help="log a analyser, repetable")
    parser.add_argument("--encounter", type=int, help="encounterID WCL (decouverte automatique)")
    parser.add_argument("--partition", type=int, help="partition WCL (une par version/saison)")
    parser.add_argument("--npc-id", type=int,
                        help="restreint a ce npcId (sinon : tous les ennemis du combat)")
    parser.add_argument("--flavor", required=True, choices=FLAVORS)
    parser.add_argument("--raid", required=True, help="nom du fichier de raid, ex. Onyxias_Lair")
    parser.add_argument("--limit", type=int, default=10, help="nombre de logs (defaut 10)")
    parser.add_argument("--min-reports", type=int, default=2,
                        help="[zones] logs minimum ou le sort doit apparaitre (defaut 2)")
    parser.add_argument("--min-targets", type=int, default=2,
                        help="[zones] joueurs differents minimum touches (defaut 2)")
    parser.add_argument("--min-spread", type=float, default=1.5,
                        help="[zones] variete des cibles exigee d'un pull a l'autre pour un "
                             "sort non periodique (defaut 1.5)")
    parser.add_argument("--raid-wide", type=float, default=0.85,
                        help="[zones] au-dela de cette fraction du raid touchee, le sort est "
                             "traite comme un degat inevitable (defaut 0.85)")
    parser.add_argument("--min-interrupts", type=int, default=1,
                        help="[kick] occurrences minimum (defaut 1 : une interruption est une preuve)")
    parser.add_argument("--out", help="chemin de sortie (un seul mode a la fois)")
    parser.add_argument("--replace", action="store_true",
                        help="repart d'un fichier vide au lieu de fusionner l'existant")
    parser.add_argument("--dry-run", action="store_true", help="affiche sans rien ecrire")
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args(argv)


def run_interrupts(token, reports, args) -> int:
    print("\n== sorts interruptibles")
    found, used = collect_interrupts(token, reports, args.npc_id, args.verbose)
    if used == 0:
        print("aucun log exploitable.", file=sys.stderr)
        return 1

    rows = [
        {"spellId": spell, "name": entry["name"], "count": entry["count"],
         "reports": len(entry["reports"])}
        for spell, entry in found.items()
        if entry["count"] >= args.min_interrupts
    ]
    rows.sort(key=lambda row: -row["count"])

    if not rows:
        print("aucune interruption observee dans ces logs.")
        return 0

    for row in rows:
        print(f"  spell {row['spellId']:>7} : {row['name'] or '?'} "
              f"({row['count']} interruption(s), {row['reports']} log(s))")

    if args.dry_run:
        return 0
    out = write_output("interrupts", args, rows, describe_interrupt)
    print(f"ecrit : {out}")
    return 0


def run_zones(token, reports, args) -> int:
    print("\n== zones a fuir")
    stats, used = collect_zones(token, reports, args.npc_id, args.verbose)
    if used == 0:
        print("aucun log exploitable.", file=sys.stderr)
        return 1

    kept, dropped = classify_zones(stats, args)

    if args.verbose and dropped:
        print("  ecartes :")
        for row in dropped:
            print(f"    spell {row['spellId']:>7} : {row['name'] or '?'} — {row['reason']}")

    if not kept:
        print("aucune zone retenue. Baisse --min-reports / --min-targets, ou "
              "relance avec -v pour voir ce qui a ete ecarte et pourquoi.")
        return 0

    for row in kept:
        print(f"  spell {row['spellId']:>7} : {describe_zone(row)}")

    if args.dry_run:
        return 0
    out = write_output("zones", args, kept, describe_zone)
    print(f"ecrit : {out}")
    return 0


def main(argv=None) -> int:
    args = parse_args(argv)

    if args.out and args.mode == "both":
        print("--out ne vaut que pour un seul mode : precise --mode.", file=sys.stderr)
        return 2

    try:
        client_id, client_secret = load_credentials()
        token = get_token(client_id, client_secret)
    except WCLError as exc:
        print(exc, file=sys.stderr)
        return 2

    reports = []
    for item in args.report:
        try:
            reports.append(parse_report_arg(item))
        except WCLError as exc:
            print(exc, file=sys.stderr)
            return 2

    if args.encounter and not reports:
        try:
            _, reports = discover_reports(token, args.encounter, args.limit, args.partition)
        except WCLError as exc:
            print(exc, file=sys.stderr)
            return 2

    if not reports:
        print("aucun log a analyser : passe --report CODE:FIGHT ou --encounter <id>.",
              file=sys.stderr)
        return 2

    print(f"analyse de {len(reports)} log(s)...")

    status = 0
    if args.mode in ("interrupts", "both"):
        status |= run_interrupts(token, reports, args)
    if args.mode in ("zones", "both"):
        status |= run_zones(token, reports, args)

    if not args.dry_run:
        print("\nPense a relancer tools/gen-toc.sh pour inscrire les fichiers dans les .toc.")
    return status


if __name__ == "__main__":
    sys.exit(main())
