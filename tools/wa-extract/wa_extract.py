#!/usr/bin/env python3
"""Inventaire et extraction des WeakAuras perso.

Fichier : WTF/Account/<COMPTE>/SavedVariables/WeakAuras.lua

Deux modes :

    wa_extract.py count   WeakAuras.lua        # combien d'auras sont exploitables
    wa_extract.py extract WeakAuras.lua [...]  # detail + brouillon de data

Attente realiste : la majorite des auras de raid importees depuis Wago sont de
type BOSS_MOD, c'est-a-dire un simple wrapper DBM/BigWigs sans duree propre —
rien d'extractible. Les auras EVENT sur COMBAT_LOG_EVENT_UNFILTERED, elles, se
convertissent directement vers le format Phase 1. On compte AVANT d'ecrire quoi
que ce soit : c'est le comptage qui decide si cette source vaut le code.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lua_table import parse_saved_variables  # noqa: E402

CLEU_EVENTS = {"Combat Log", "COMBAT_LOG_EVENT_UNFILTERED"}


def load_displays(path: Path) -> dict:
    data = parse_saved_variables(path.read_text(encoding="utf-8", errors="replace"))
    saved = data.get("WeakAurasSaved")
    if not isinstance(saved, dict):
        raise SystemExit("WeakAurasSaved introuvable dans ce fichier.")
    displays = saved.get("displays")
    if not isinstance(displays, dict):
        raise SystemExit("aucune table `displays`.")
    return displays


def iter_triggers(display: dict):
    """WA a change de schema : `trigger` (ancien) puis `triggers[n].trigger`."""
    trigger = display.get("trigger")
    if isinstance(trigger, dict):
        yield trigger
    triggers = display.get("triggers")
    if isinstance(triggers, dict):
        for entry in triggers.values():
            if isinstance(entry, dict):
                inner = entry.get("trigger")
                if isinstance(inner, dict):
                    yield inner


def spell_ids(trigger: dict):
    out = []
    for key in ("spellId", "spellIds", "auraspellids", "spellName"):
        value = trigger.get(key)
        if isinstance(value, dict):
            out.extend(int(v) for v in value.values() if isinstance(v, (int, float)))
        elif isinstance(value, (int, float)):
            out.append(int(value))
        elif isinstance(value, str) and value.isdigit():
            out.append(int(value))
    seen, unique = set(), []
    for spell in out:
        if spell not in seen:
            seen.add(spell)
            unique.append(spell)
    return unique


def classify(displays: dict):
    counts = Counter()
    usable = []
    for name, display in displays.items():
        if not isinstance(display, dict):
            continue
        for trigger in iter_triggers(display):
            kind = trigger.get("type") or "?"
            counts[kind] += 1
            if kind == "EVENT" and trigger.get("event") in CLEU_EVENTS:
                ids = spell_ids(trigger)
                if ids:
                    usable.append(
                        {
                            "name": name,
                            "spellIds": ids,
                            "subevent": "%s%s" % (
                                trigger.get("subeventPrefix", ""),
                                trigger.get("subeventSuffix", ""),
                            ),
                            "duration": trigger.get("duration"),
                        }
                    )
    return counts, usable


def cmd_count(args) -> int:
    path = Path(args.file)
    if args.grep:
        text = path.read_text(encoding="utf-8", errors="replace")
        counts = Counter(re.findall(r'\["type"\]\s*=\s*"([A-Z_]+)"', text))
    else:
        counts, _ = classify(load_displays(path))
    total = sum(counts.values())
    if total == 0:
        print("aucun trigger trouve.")
        return 1
    print(f"{total} trigger(s) :")
    for kind, count in counts.most_common():
        print(f"  {count:>5}  {kind}  ({100 * count / total:.0f}%)")
    print("\nBOSS_MOD = wrapper DBM/BigWigs : aucune duree propre, rien a extraire.")
    return 0


def cmd_extract(args) -> int:
    displays = load_displays(Path(args.file))
    counts, usable = classify(displays)

    print(f"{len(displays)} aura(s), {sum(counts.values())} trigger(s), "
          f"{len(usable)} exploitable(s) (EVENT + combat log + spellId).")
    for entry in usable:
        duration = f", duree {entry['duration']}" if entry["duration"] else ""
        print(f"  - {entry['name']} : {entry['subevent'] or '?'} "
              f"{entry['spellIds']}{duration}")

    if args.json:
        Path(args.json).write_text(json.dumps(usable, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"\necrit : {args.json}")

    if args.lua:
        if not args.npc_id:
            print("--lua exige --npc-id", file=sys.stderr)
            return 2
        lines = [
            f"-- Brouillon genere depuis WeakAuras.lua (npcId {args.npc_id}).",
            "-- Les triggers CAST sont surs (spellId observe) ; toute duree venue",
            "-- d'une aura reste a confirmer par tools/wcl-ingest.",
            "",
            "local _, ns = ...",
            "",
            f"ns.BossTimerData[{args.npc_id}] = {{",
            f'    name    = "{args.boss or "?"}",',
            f"    flavors = {{ {args.flavor} = true }},",
            "    timers  = {",
        ]
        for entry in usable:
            for spell in entry["spellIds"]:
                start = "_CAST_START" in entry["subevent"]
                lines.append(f"        -- {entry['name']}")
                lines.append("        {")
                lines.append('            trigger    = "CAST",')
                lines.append(f"            spellId    = {spell},")
                if start:
                    lines.append("            castStart  = true,")
                lines.append("            bar        = true,")
                lines.append("        },")
        lines += ["    },", "}", ""]
        Path(args.lua).write_text("\n".join(lines), encoding="utf-8")
        print(f"\necrit : {args.lua}")

    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    count = sub.add_parser("count", help="repartition des types de trigger")
    count.add_argument("file")
    count.add_argument("--grep", action="store_true",
                       help="comptage par expression reguliere, sans parser le fichier")
    count.set_defaults(func=cmd_count)

    extract = sub.add_parser("extract", help="detail des auras exploitables")
    extract.add_argument("file")
    extract.add_argument("--json", help="ecrit le detail en JSON")
    extract.add_argument("--lua", help="ecrit un brouillon de fichier de data")
    extract.add_argument("--npc-id", type=int)
    extract.add_argument("--boss")
    extract.add_argument("--flavor", default="vanilla",
                         choices=["vanilla", "tbc", "wrath", "cata", "mists", "retail"])
    extract.set_defaults(func=cmd_extract)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
