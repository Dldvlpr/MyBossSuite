#!/usr/bin/env python3
"""Tests de la fusion a la regeneration, sans reseau.

Ce qui merite d'etre teste ici, c'est la NON-DESTRUCTION. Un fichier de data
n'est pas qu'un releve : les phases, les seuils de vie, les libelles s'ecrivent
a la main et ne se mesurent pas. Si une regeneration les efface, editer un
fichier devient jetable et un boss a phases n'est plus jamais regenerable —
c'est-a-dire que l'ingestion en masse s'arrete au premier boss non trivial.

Le scenario rejoue un passage d'ingestion sur l'Onyxia du depot :
  * le tableau `phases`         -> conserve tel quel (mecanique, pas mesure) ;
  * un timer PULL               -> time / repeatInterval reecrits ;
  * un timer PHASE du meme sort -> garde son `time`, ne recoit que la cadence ;
  * un timer CAST / AURA        -> conserve, sans `time` parasite ;
  * un sort inedit              -> ajoute a la fin.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "wcl-ingest"))
sys.path.insert(0, str(ROOT / "tools" / "wa-extract"))

import lua_table  # noqa: E402
import wcl_ingest as wi  # noqa: E402

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


ONYXIA = ROOT / "Modules" / "BossTimer" / "Data" / "vanilla" / "Onyxias_Lair" / "Onyxia.lua"
NPC_ID = 10184


def row(spell_id, time, interval=None, variable=False, samples=6):
    return {
        "spellId": spell_id, "time": time, "timeStdev": 0.5,
        "repeatInterval": interval, "intervalStdev": 0.5,
        "samples": samples, "variable": variable,
    }


def args_for(**overrides):
    argv = ["--npc-id", str(NPC_ID), "--flavor", "vanilla", "--kind", "raid",
            "--raid", "Onyxias_Lair", "--boss", "Onyxia", "--encounter", "1084"]
    for key, value in overrides.items():
        argv += ["--" + key.replace("_", "-"), str(value)]
    return wi.parse_args(argv)


# ----------------------------------------------------------------------------
suite("Relecture d'un fichier existant")

existing = wi.read_existing(ONYXIA, NPC_ID)
ok(existing is not None, "le fichier de data du depot est relu")
phases = wi.lua_array(existing["phases"])
equal(len(phases), 3, "le tableau `phases` est relu")
equal(phases[1]["threshold"], 0.65, "le trigger d'une phase est relu")
old_timers = wi.lua_array(existing["timers"])
equal(len(old_timers), 5, "les 5 timers sont relus dans l'ordre")
equal(old_timers[0]["trigger"], "PULL", "le premier timer est relu")

equal(wi.read_existing(ROOT / "n-existe-pas.lua", NPC_ID), None,
      "fichier absent : rien a fusionner")
equal(wi.read_existing(ONYXIA, 999999), None,
      "npcId absent du fichier : rien a fusionner")

# Un fichier illisible ne doit surtout pas etre traite comme vide : c'est le
# chemin par lequel on ecraserait des phases ecrites a la main.
broken = ROOT / "tests" / "_tmp_broken.lua"
broken.write_text("ns.BossTimerData[%d] = { timers = { { trigger = " % NPC_ID, encoding="utf-8")
try:
    wi.read_existing(broken, NPC_ID)
    ok(False, "un fichier tronque doit lever, pas retourner None")
except lua_table.LuaSyntaxError:
    ok(True, "fichier illisible : erreur remontee, pas d'ecrasement silencieux")
finally:
    broken.unlink()


# ----------------------------------------------------------------------------
suite("Fusion")

rows = [
    row(17086, 10.4, interval=22.0),            # Flame Breath, remesure
    row(21000, 5.0, variable=True),             # sort inedit
]
merged = wi.merge_timers(old_timers, rows)

equal(len(merged), 6, "5 timers existants + 1 sort inedit")
equal([t.get("spellId") for t, _ in merged][:5],
      [t.get("spellId") for t in old_timers],
      "l'ordre du fichier existant est conserve")
equal(merged[5][0]["spellId"], 21000, "le sort inedit arrive a la fin")

# Flame Breath porte DEUX timers : un PULL en phase 1, un PHASE en phase 3. La
# mesure est un delta depuis le pull, donc elle n'a le droit d'atterrir que dans
# le premier. Sans cette distinction, la mesure de la P1 ecraserait la P3.
flame = [t for t, _ in merged if t.get("spellId") == 17086]
equal(len(flame), 2, "les deux timers du meme sort sont retrouves")
pull = next(t for t in flame if t["trigger"] == "PULL")
phase = next(t for t in flame if t["trigger"] == "PHASE")

equal(pull["time"], 10.4, "timer PULL : `time` est remesure")
equal(pull["repeatInterval"], 22.0, "timer PULL : la cadence est remesuree")
ok("provisional" not in pull, "timer PULL mesure : il n'est plus provisoire")
ok("variable" not in pull, "`variable` retombe quand la mesure est stable")
equal(pull["warnBefore"], 3, "`warnBefore` survit a la regeneration")
equal(pull["name"], "Flame Breath", "le libelle survit a la regeneration")

equal(phase["time"], 10, "timer PHASE : son `time` ecrit a la main est intact")
equal(phase["repeatInterval"], 22.0, "timer PHASE : la cadence, elle, est mesurable")
equal(phase["provisional"], True, "timer PHASE : toujours provisoire, rien ne l'a mesure")
equal(phase["phase"], 3, "sa phase survit")

volley = next(t for t, _ in merged if t.get("spellId") == 18435)
equal(volley["trigger"], "CAST", "un trigger CAST survit")
equal(volley["phase"], 2, "sa phase survit")
ok("time" not in volley, "et il ne recoit pas de `time` parasite")

deep = next(t for t, _ in merged if t.get("trigger") == "AURA")
equal(deep["on"], "player", "`on` survit a la regeneration")
equal(deep["testTime"], 34, "`testTime` survit a la regeneration")

cast_deep = next(t for t, _ in merged
                 if t.get("spellId") == 18431 and t.get("trigger") == "CAST")
equal(cast_deep["announce"], "DEEP BREATH", "`announce` survit a la regeneration")
equal(cast_deep["flash"], True, "`flash` survit a la regeneration")
equal(cast_deep["castStart"], True, "`castStart` survit a la regeneration")

# Le meme sort, mais bascule en CAST : le delai depuis le pull devient du bruit
# et doit disparaitre plutot que de rester en place, perime.
switched = dict(old_timers[0])
switched["trigger"] = "CAST"
merged_switched = wi.merge_timer(switched, rows[0])
ok("time" not in merged_switched, "trigger CAST : le `time` mesure est ecarte")
equal(merged_switched["repeatInterval"], 22.0, "mais l'intervalle reste utile")

# Une mesure qui ne trouve pas d'intervalle ne doit pas effacer le dernier connu.
kept = wi.merge_timer(dict(old_timers[0]), row(17086, 9.0))
equal(kept["repeatInterval"], 25, "sans mesure d'intervalle, la valeur connue reste")

variable = wi.merge_timer(dict(old_timers[0]), row(17086, 9.0, variable=True))
equal(variable["variable"], True, "`variable` remonte quand la mesure se disperse")


# ----------------------------------------------------------------------------
suite("Emission")

args = args_for()
header = wi.merge_header(args, existing)
equal(len(wi.lua_array(header["phases"])), 3,
      "le tableau `phases` traverse l'en-tete intact")
equal(header["zone"], "Onyxia's Lair", "`zone` survit")
equal(header["instanceId"], 249, "un champ d'en-tete inconnu du script survit")
equal(header["kind"], "raid", "`kind` vient de la CLI")
ok("timers" not in header, "l'en-tete ne contient pas les timers")

lua = wi.render_lua(args, header, merged, "Onyxia", 7)
ok('{ name = "Vol", trigger = "HEALTH", threshold = 0.65' in lua,
   "une phase est emise sur une ligne, champs dans l'ordre")
ok(re.search(r'announce\s+= "DEEP BREATH",', lua), "`announce` est bien emis")
ok("conserve : spell 18435 absent des logs" in lua, "un sort non revu est signale")

# Idempotence : regenerer deux fois de suite avec les memes mesures doit donner
# exactement le meme fichier, sinon chaque passage produit un faux diff et on
# cesse de relire les vrais.
tmp = ROOT / "tests" / "_tmp_render.lua"
tmp.write_text(lua, encoding="utf-8")
try:
    reread = wi.read_existing(tmp, NPC_ID)
    again = wi.render_lua(args, wi.merge_header(args, reread),
                          wi.merge_timers(wi.lua_array(reread["timers"]), rows), "Onyxia", 7)
    ok(again == lua, "la regeneration est idempotente")

    lua_bin = shutil.which("lua5.1") or shutil.which("lua")
    if lua_bin:
        result = subprocess.run([lua_bin, "-e", "assert(loadfile('%s'))" % tmp],
                                capture_output=True, text=True)
        ok(result.returncode == 0, "le fichier emis est du Lua valide")
    else:
        print("  --   interpreteur Lua absent : validite syntaxique non verifiee")
finally:
    tmp.unlink()


# ----------------------------------------------------------------------------
suite("Incantation et sorts sans horaire")

# `begincast` et `cast` sont deux evenements pour un seul lancer. Melanges, ils
# font passer la duree du sort pour une cadence : c'est ce qui ecrivait des
# `repeatInterval` de 2.0 s a 0.01 s d'ecart-type — reguliers, et faux.
equal(wi.cast_times([10.0, 20.0], [12.0, 22.0]), [2.0, 2.0],
      "la duree d'incantation se lit entre begincast et le cast qui suit")
equal(wi.cast_times([10.0], [8.0, 12.5]), [2.5],
      "un cast anterieur au begincast ne compte pas")
equal(wi.cast_times([10.0], [10.0 + wi.MAX_CAST_TIME + 1]), [],
      "un ecart trop grand n'est pas une incantation")
equal(wi.cast_times([10.0], []), [], "un begincast sans cast ne mesure rien")

# Un sort qui part quand le boss le decide n'a pas d'heure a afficher. Ecrire
# la mediane produirait une barre qui compte vers un instant invente ; le seul
# fait mesurable, c'est le cast lui-meme.
stats = {
    # premier cast disperse, cadence dispersee : rien de previsible.
    701: {"firsts": [5.0, 25.0, 45.0], "intervals": [30.0, 12.0, 55.0],
          "castTimes": [2.0, 2.1, 2.0], "phases": {}},
    # premier cast serre, cadence serree : un horaire, lui, existe.
    702: {"firsts": [10.0, 10.2, 9.9], "intervals": [20.0, 20.1, 19.9],
          "castTimes": [], "phases": {}},
}
rows_by_spell = {r["spellId"]: r for r in wi.summarise(stats, 2)}

reactive = rows_by_spell[701]
equal(reactive["reactive"], True, "ni heure ni cadence : le sort est reactif")
equal(reactive["castTime"], 2.0, "sa duree d'incantation est la mediane des mesures")
timer = wi.new_timer(reactive)
equal(timer["trigger"], "CAST", "un sort sans horaire sort en trigger CAST")
equal(timer["castStart"], True, "la barre part au debut de l'incantation")
equal(timer["castTime"], 2.0, "et dure ce que dure l'incantation")
ok("time" not in timer, "aucun `time` invente pour un sort sans horaire")

steady = rows_by_spell[702]
equal(steady["reactive"], False, "un sort regulier garde son horaire")
equal(steady["castTime"], None, "sort instantane : pas de duree d'incantation")
steady_timer = wi.new_timer(steady)
equal(steady_timer["trigger"], "PULL", "et reste un timer PULL")
ok("castTime" not in steady_timer, "sans incantation mesuree, pas de champ")

# Le trigger d'un timer existant est de la structure ecrite a la main : le
# generateur le signale, il ne le rebascule pas.
hand_written = {"trigger": "PULL", "time": 5, "spellId": 701, "bar": True}
kept_trigger = wi.merge_timer(dict(hand_written), reactive)
equal(kept_trigger["trigger"], "PULL", "un trigger ecrit a la main n'est pas rebascule")
equal(kept_trigger["castTime"], 2.0, "mais il recoit la duree d'incantation mesuree")
equal(kept_trigger["variable"], True, "et reste marque non deterministe")
signalled = "\n".join(wi.render_timer(kept_trigger, reactive, False))
ok("TODO cast ?" in signalled, "le generateur signale qu'il n'y a pas d'horaire")

# Une incantation qui disparait ne doit pas laisser une duree perimee en place.
dropped = wi.merge_timer({"trigger": "PULL", "time": 5, "spellId": 702, "castTime": 9},
                         steady)
ok("castTime" not in dropped, "plus d'incantation mesuree : le champ disparait")


print(f"\n{passed} ok, {failed} echec(s)")
sys.exit(0 if failed == 0 else 1)
