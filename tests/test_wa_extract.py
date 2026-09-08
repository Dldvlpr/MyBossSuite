#!/usr/bin/env python3
"""Tests de l'inventaire des WeakAuras perso, sans reseau.

C'est `count` qui decide si la phase 3b vaut le code qu'elle demande : si tes
auras de raid sont majoritairement des `BOSS_MOD`, il n'y a rien a extraire et
la question est close. Une reponse fausse a cette question fait ecrire — ou
abandonner — une source de data pour rien, d'ou ces tests.

Le vrai `WeakAuras.lua` fait plusieurs megaoctets de Lua ecrit par un autre
outil. La fixture reproduit ce qui casse un parseur naif : les deux schemas de
trigger (l'ancien `trigger`, le nouveau `triggers[n].trigger`), des cles
numeriques, des nombres negatifs et en notation scientifique, des commentaires,
et du code utilisateur stocke comme une chaine — accolades et guillemets
echappes compris.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "wa-extract"))

import lua_table  # noqa: E402
import wa_extract as wa  # noqa: E402

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


FIXTURE = ROOT / "tests" / "fixtures" / "WeakAuras.lua"


# ----------------------------------------------------------------------------
suite("Relecture d'un SavedVariables")

displays = wa.load_displays(FIXTURE)
equal(len(displays), 4, "les auras sont relues")
ok("Deep Breath" in displays, "une aura est indexee par son nom")

# Une chaine de code utilisateur contient des accolades et des guillemets
# echappes : lue comme du Lua plutot que comme du texte, elle ferme la table
# trop tot et le reste du fichier part en vrille.
equal(displays["Flame Breath"]["customText"],
      'function() return "P1 : " .. { } end',
      "une chaine a echappements est relue telle quelle")
equal(displays["Deep Breath"]["xOffset"], -120.5, "un nombre negatif est relu")
equal(displays["Deep Breath"]["alpha"], 1.0, "la notation scientifique aussi")


# ----------------------------------------------------------------------------
suite("Comptage")

counts, usable = wa.classify(displays)
equal(counts["EVENT"], 3, "les triggers EVENT sont comptes")
equal(counts["BOSS_MOD"], 1, "les wrappers DBM/BigWigs aussi")

# Les deux schemas doivent etre lus : n'en lire qu'un sous-compte les auras
# exploitables et fait conclure a tort que la source ne vaut rien.
names = {entry["name"] for entry in usable}
equal(names, {"Deep Breath", "Flame Breath"},
      "les deux schemas de trigger sont lus (`trigger` et `triggers[n]`)")

deep = next(entry for entry in usable if entry["name"] == "Deep Breath")
equal(deep["spellIds"], [18431], "le spellId est extrait")
equal(deep["subevent"], "SPELL_CAST_START", "le sous-evenement combat log aussi")
equal(next(e for e in usable if e["name"] == "Flame Breath")["spellIds"],
      [17086, 18435], "une aura a plusieurs sorts les rend tous")

# Ce qui doit rester dehors : un BOSS_MOD n'a pas de duree propre, et un EVENT
# qui n'ecoute pas le combat log ne parle pas de sorts.
ok("Onyxia Pack" not in names, "un BOSS_MOD n'est pas exploitable")
ok("Vie du groupe" not in names, "un EVENT hors combat log non plus")


# ----------------------------------------------------------------------------
suite("Extraction des spellIds")

equal(wa.spell_ids({"spellIds": {1: 17086, 2: 18435}}), [17086, 18435],
      "une table de spellIds est aplatie dans l'ordre")
equal(wa.spell_ids({"spellId": "17086"}), [17086],
      "un spellId ecrit comme une chaine est converti")
equal(wa.spell_ids({"spellIds": {1: 17086, 2: 17086}}), [17086],
      "les doublons sont ecartes")
equal(wa.spell_ids({"spellName": "Flame Breath"}), [],
      "un nom de sort n'est pas un id : rien a extraire")


# ----------------------------------------------------------------------------
suite("Fichier illisible")

broken = ROOT / "tests" / "_tmp_wa.lua"
broken.write_text('WeakAurasSaved = { ["displays"] = { ["x"] = ', encoding="utf-8")
try:
    wa.load_displays(broken)
    ok(False, "un fichier tronque doit lever, pas retourner un inventaire vide")
except (lua_table.LuaSyntaxError, SystemExit, IndexError):
    ok(True, "un fichier tronque leve au lieu de faire croire a zero aura")
finally:
    broken.unlink()

empty = ROOT / "tests" / "_tmp_wa.lua"
empty.write_text("SomethingElse = {}\n", encoding="utf-8")
try:
    wa.load_displays(empty)
    ok(False, "un fichier sans WeakAurasSaved doit le dire")
except SystemExit:
    ok(True, "un fichier sans WeakAurasSaved le dit au lieu de compter zero")
finally:
    empty.unlink()


print(f"\n{passed} ok, {failed} echec(s)")
sys.exit(0 if failed == 0 else 1)
