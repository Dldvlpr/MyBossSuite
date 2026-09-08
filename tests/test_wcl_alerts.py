#!/usr/bin/env python3
"""Tests de la logique d'ingestion des alertes, sans reseau.

Ce qui merite d'etre teste ici, c'est le CLASSEMENT : la liste "kick" est une
preuve directe et ne peut pas se tromper, mais la liste "move" est une
heuristique, et une heuristique non testee est une heuristique fausse.

Le scenario rejoue cinq sorts qui couvrent les quatre pieges :
  * une zone au sol            -> doit etre retenue ;
  * un DoT                     -> ecarte (debuff du meme sort sur la cible) ;
  * un degat de raid           -> ecarte (touche tout le monde) ;
  * un cleave                  -> ecarte (toujours les memes cibles) ;
  * un coup de tank            -> ecarte (une seule cible).
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "wcl-ingest"))

import wcl_alerts as wa  # noqa: E402

passed = failed = 0


def ok(condition, label):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   {label}")
    else:
        failed += 1
        print(f"  FAIL {label}")


def equal(actual, expected, label):
    ok(actual == expected, f"{label} (attendu {expected!r}, obtenu {actual!r})")


def suite(name):
    print(f"\n== {name}")


# ----------------------------------------------------------------------------
# Scenario
# ----------------------------------------------------------------------------

BOSS = {"id": 50, "gameID": 10184, "name": "Onyxia", "type": "NPC"}
ADD = {"id": 51, "gameID": 99999, "name": "Whelp", "type": "NPC"}
PLAYER_SOURCE = {"id": 1, "gameID": 1, "name": "Testeur", "type": "Player"}
ACTORS = {50: BOSS, 51: ADD, 1: PLAYER_SOURCE}

RAID = list(range(1, 11))   # dix joueurs

ZONE, DOT, RAID_WIDE, CLEAVE, TANK = 100, 200, 300, 400, 500


def damage(ability, target, timestamp, tick=False, source=50):
    event = {"type": "damage", "abilityGameID": ability, "sourceID": source,
             "targetID": target, "timestamp": timestamp, "amount": 500}
    if tick:
        event["tick"] = True
    return event


def build_fight(zone_targets, cleave_targets):
    """Un pull : la zone touche qui n'en est pas sorti, le cleave les memes corps a corps."""
    events = []
    clock = 1000
    for target in zone_targets:
        for i in range(4):
            events.append(damage(ZONE, target, clock + i * 2000, tick=True))
    for target in (1, 2):
        for i in range(3):
            events.append(damage(DOT, target, clock + i * 3000, tick=True))
    for target in RAID:
        events.append(damage(RAID_WIDE, target, clock + 5000))
    for target in cleave_targets:
        events.append(damage(CLEAVE, target, clock + 7000))
    events.append(damage(TANK, 1, clock + 9000))
    return events


def build_debuffs(fight_end):
    """Seul le DoT pose une aura sur ses cibles."""
    events = []
    for target in (1, 2):
        events.append({"type": "applydebuff", "abilityGameID": DOT,
                       "targetID": target, "timestamp": 500})
        events.append({"type": "removedebuff", "abilityGameID": DOT,
                       "targetID": target, "timestamp": fight_end})
    return events


def run_scenario(fights, npc_id=None):
    stats = wa.new_stats()
    for index, (zone_targets, cleave_targets) in enumerate(fights):
        end = 60000
        windows = wa.debuff_windows(build_debuffs(end), end)
        by_ability = wa.aggregate_fight(build_fight(zone_targets, cleave_targets),
                                        windows, ACTORS, npc_id)
        wa.merge_fight(stats, by_ability, len(RAID), f"log{index}:1")
    return stats


class Args:
    min_reports = 2
    min_targets = 2
    min_spread = 1.5
    raid_wide = 0.85


# ----------------------------------------------------------------------------

suite("Fenetres de debuff")

windows = wa.debuff_windows(build_debuffs(60000), 60000)
ok(wa.covered_by_debuff(windows, 1, DOT, 3000), "un tick pendant le debuff est couvert")
ok(not wa.covered_by_debuff(windows, 1, ZONE, 3000), "un autre sort n'est pas couvert")
ok(not wa.covered_by_debuff(windows, 9, DOT, 3000), "un autre joueur n'est pas couvert")

# Un debuff jamais retire doit quand meme fermer sa fenetre a la fin du combat.
open_only = wa.debuff_windows(
    [{"type": "applydebuff", "abilityGameID": DOT, "targetID": 3, "timestamp": 100}], 60000)
ok(wa.covered_by_debuff(open_only, 3, DOT, 55000),
   "debuff sans retrait : fenetre fermee a la fin du combat")

# ----------------------------------------------------------------------------

suite("Agregation d'un pull")

end = 60000
by_ability = wa.aggregate_fight(build_fight([3, 4], [1, 2]),
                                wa.debuff_windows(build_debuffs(end), end), ACTORS, None)
equal(len(by_ability[ZONE]["targets"]), 2, "zone : deux joueurs touches")
equal(by_ability[ZONE]["ticks"], 8, "zone : les ticks sont comptes")
equal(by_ability[ZONE]["debuffed"], 0, "zone : aucun coup couvert par un debuff")
equal(by_ability[DOT]["debuffed"], by_ability[DOT]["hits"], "DoT : tous les coups couverts")
equal(len(by_ability[RAID_WIDE]["targets"]), 10, "degat de raid : tout le monde touche")

# Le melee et les degats infliges par un joueur ne doivent jamais entrer.
noise = wa.aggregate_fight(
    [damage(wa.MELEE_ABILITY, 2, 100), damage(ZONE, 2, 200, source=1)], {}, ACTORS, None)
equal(len(noise), 0, "melee et source joueur ecartes")

# Filtre par npcId : les degats d'un add ne comptent pas.
filtered = wa.aggregate_fight([damage(ZONE, 2, 100, source=51)], {}, ACTORS, 10184)
equal(len(filtered), 0, "--npc-id ecarte les autres ennemis")

# ----------------------------------------------------------------------------

suite("Classement des zones")

# Deux pulls, la zone touche des joueurs differents a chaque fois — le cleave non.
stats = run_scenario([([3, 4], [1, 2]), ([5, 6], [1, 2])])
kept, dropped = wa.classify_zones(stats, Args)
kept_ids = {row["spellId"] for row in kept}
reasons = {row["spellId"]: row["reason"] for row in dropped}

equal(kept_ids, {ZONE}, "seule la zone au sol est retenue")
ok("DoT" in reasons[DOT], "DoT ecarte pour la bonne raison : " + reasons[DOT])
ok("raid" in reasons[RAID_WIDE], "degat de raid ecarte : " + reasons[RAID_WIDE])
ok("memes cibles" in reasons[CLEAVE], "cleave ecarte : " + reasons[CLEAVE])
ok("joueur" in reasons[TANK], "coup de tank ecarte : " + reasons[TANK])

zone_row = kept[0]
equal(zone_row["periodic"], True, "la zone est marquee periodique")
equal(zone_row["reports"], 2, "vue dans les deux logs")
equal(zone_row["targets"], 4, "quatre joueurs differents touches au total")

# Un seul log : le critere de variete ne peut pas se prononcer, et c'est le
# comportement conservateur qui doit gagner.
single = run_scenario([([3, 4], [1, 2])])
kept_single, _ = wa.classify_zones(single, Args)
equal({row["spellId"] for row in kept_single}, set(),
      "un seul log : rien n'est retenu avec --min-reports 2")


class LooseArgs(Args):
    min_reports = 1


kept_loose, _ = wa.classify_zones(single, LooseArgs)
equal({row["spellId"] for row in kept_loose}, {ZONE},
      "un seul log et --min-reports 1 : la zone periodique passe, pas le cleave")

# ----------------------------------------------------------------------------

suite("Sorts interruptibles")

interrupt_events = [
    {"type": "interrupt", "sourceID": 1, "targetID": 50,
     "abilityGameID": 1766, "extraAbilityGameID": 17086},
    {"type": "interrupt", "sourceID": 1, "targetID": 51,
     "abilityGameID": 1766, "extraAbilityGameID": 18435},
    {"type": "cast", "sourceID": 1, "abilityGameID": 1766},
]
equal(wa.extract_interrupts(interrupt_events, ACTORS, None), [17086, 18435],
      "les sorts interrompus sont releves, pas le kick")
equal(wa.extract_interrupts(interrupt_events, ACTORS, 10184), [17086],
      "--npc-id restreint a la cible voulue")

# ----------------------------------------------------------------------------

suite("Emission Lua")

import tempfile  # noqa: E402


class RenderArgs:
    flavor = "vanilla"
    raid = "Onyxias_Lair"
    replace = False
    out = None


with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "Onyxias_Lair.lua"
    RenderArgs.out = str(path)

    wa.write_output("zones", RenderArgs, [dict(zone_row)], wa.describe_zone)
    body = path.read_text(encoding="utf-8")
    ok(f"ns.MoveAlertData[{ZONE}] = true" in body, "entree ecrite dans la bonne table")
    ok("GENERE PAR" in body, "en-tete d'avertissement present")

    # Deuxieme boss du meme raid : l'existant doit survivre.
    second = dict(zone_row)
    second["spellId"] = 12345
    wa.write_output("zones", RenderArgs, [second], wa.describe_zone)
    body = path.read_text(encoding="utf-8")
    ok(f"ns.MoveAlertData[{ZONE}] = true" in body, "l'entree du premier passage est conservee")
    ok("ns.MoveAlertData[12345] = true" in body, "la nouvelle entree est ajoutee")

    RenderArgs.replace = True
    wa.write_output("zones", RenderArgs, [second], wa.describe_zone)
    body = path.read_text(encoding="utf-8")
    ok(f"ns.MoveAlertData[{ZONE}] = true" not in body, "--replace repart d'un fichier vide")

print(f"\n{passed} ok, {failed} echec(s)")
sys.exit(0 if failed == 0 else 1)
