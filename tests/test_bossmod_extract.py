#!/usr/bin/env python3
"""Tests du releve des boss mods installes, sans WoW ni addon reel.

Ce qui merite d'etre teste ici, c'est ce que le parseur REFUSE. Prendre une
valeur de trop est bien pire que d'en rater une : une duree fausse ecrite dans
la data ressort en jeu comme une barre qui ment, et personne ne saura d'ou elle
vient. Les fixtures reproduisent donc les formes piegeuses :

  * DBM      : un temps d'incantation negatif (« prends celui du sort »), un
               timer de phase sans spellId, un timer sans sort du tout, un
               `:Start(12 - delay)` qui est un offset et pas une cadence ;
  * BigWigs  : des durees enfouies dans des handlers (l'approche shim + dofile
               echoue justement la-dessus), une cle `args.spellId` qui n'a de
               sens qu'a travers le `self:Log` qui a enregistre le handler, et
               une duree conditionnelle qui n'est pas un nombre.

Et la regle de fusion, qui est la seule qui protege ton travail : l'outil
remplit des trous, il n'ecrase jamais une valeur mesuree.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "bossmod-extract"))
sys.path.insert(0, str(ROOT / "tools" / "wcl-ingest"))

import bossmod_extract as bm  # noqa: E402
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


FIXTURES = ROOT / "tests" / "fixtures" / "bossmods"


def lua_list(items):
    return {index + 1: item for index, item in enumerate(items)}


# ----------------------------------------------------------------------------
suite("Lecture d'appels Lua")

text = "self:CDBar(args.spellId, self:Mythic() and 22 or 26)"
args, _ = bm.call_args(text, text.index("("))
equal(len(args), 2, "un appel imbrique ne casse pas le decoupage des arguments")
equal(args[1], "self:Mythic() and 22 or 26", "l'argument imbrique reste entier")

text = 'mod:NewTimer(15, "un, deux", 136116)'
args, _ = bm.call_args(text, text.index("("))
equal(len(args), 3, "une virgule dans une chaine n'est pas un separateur")

equal(bm.as_duration("25.5"), (25.5, False), "une duree simple est lue")
equal(bm.as_duration('"20-30"'), (20.0, True), "une fourchette : borne basse + variable")
equal(bm.as_duration("-4"), (None, False), "un temps d'incantation negatif est ecarte")
equal(bm.as_duration("self:Mythic() and 22 or 26"), (None, False),
      "une duree conditionnelle est ecartee, pas devinee")
equal(bm.as_spell("-19983"), None, "une cle negative BigWigs n'est pas un sort")


# ----------------------------------------------------------------------------
suite("Parsing DBM")

mods = {mod.source: mod for mod in bm.scan_mods(FIXTURES)}
dbm = mods["DBM"]
equal(dbm.npc_ids, [99001, 99002], "SetCreatureID : tous les npcIds")
equal(dbm.encounter_id, 4242, "SetEncounterID")
equal(dbm.instance_id, 249, "instanceId lu dans NewMod")

cadences = dbm.cadences()
equal(sorted(cadences), [99210, 99211], "seuls les timers exploitables sortent")
equal(cadences[99210].seconds, 25.5, "un CD est une cadence")
equal(cadences[99211].seconds, 20.0, "une fourchette donne sa borne basse")
equal(cadences[99211].variable, True, "... et dit que le timing est incertain")
ok(99212 not in cadences, "un temps d'incantation negatif n'entre pas")
equal(cadences[99210].starts, [18.5],
      "les :Start() numeriques sont releves pour information")
ok(all(t.spell_id != 99001 for t in dbm.timers), "un timer de phase sans sort est ecarte")
equal(dbm.berserk().seconds, 600.0, "l'enrage est retrouve")


# ----------------------------------------------------------------------------
suite("Parsing BigWigs")

bw = mods["BigWigs"]
equal(bw.npc_ids, [99001, 99002], "RegisterEnableMob")
equal(bw.encounter_id, 4242, "engageId")

cadences = bw.cadences()
equal(sorted(cadences), [99210, 99211, 99213],
      "les durees enfouies dans les handlers sont bien lues")
equal(cadences[99210].seconds, 12.0, "une CDBar au top-level du handler d'engage")
equal(cadences[99213].seconds, 20.5,
      "`args.spellId` est resolu par le self:Log qui enregistre le handler")
equal(bw.berserk().seconds, 600.0, "l'enrage est retrouve")


# ----------------------------------------------------------------------------
suite("Comparaison avec la data existante")

existing = {
    "name": "Test", "kind": "raid", "encounterId": 4242,
    "timers": lua_list([
        # deja mesure, et proche : rien a dire
        {"trigger": "CAST", "spellId": 99210, "repeatInterval": 25, "bar": True},
        # mesure, mais tres loin de ce que dit le mod : divergence a signaler
        {"trigger": "CAST", "spellId": 99211, "repeatInterval": 45, "bar": True},
        # fenetre ecrite a la main : ce sort n'a pas de cadence, et un boss mod
        # en donnera toujours une. C'est exactement ce qu'on refuse d'ecraser.
        {"trigger": "PHASE", "time": 0, "phase": 2, "spellId": 99213,
         "variable": True, "pendingWindow": "phase", "bar": True},
    ]),
}

missing, diverging, covered = bm.compare(dbm, existing)
equal([spell for spell, _ in missing], [], "rien ne manque : les deux sorts sont connus")
equal([spell for spell, _, _ in diverging], [99211], "l'ecart de cadence est signale")
equal(len(covered), 1, "le timer proche est compte comme couvert")

missing, diverging, covered = bm.compare(bw, existing)
equal([spell for spell, _, _ in covered if spell == 99213], [99213],
      "une fenetre `pendingWindow` est laissee tranquille, jamais 'manquante'")


# ----------------------------------------------------------------------------
suite("Fusion : remplir des trous, jamais ecraser")

hole = {
    "name": "Test", "kind": "raid", "encounterId": 4242,
    "timers": lua_list([
        {"trigger": "CAST", "spellId": 99210, "repeatInterval": 25,
         "name": "Ecrit a la main", "announce": "SOUFFLE", "bar": True},
        {"trigger": "CAST", "spellId": 99211, "name": "Sans cadence", "bar": True},
        {"trigger": "PHASE", "time": 0, "phase": 2, "spellId": 99213,
         "variable": True, "pendingWindow": "phase", "bar": True},
    ]),
}

timers, notes, added, filled = bm.fill_timers(hole, bw, "BigWigs_TestSuite")
by_spell = {t.get("spellId"): t for t in timers if t.get("spellId")}

equal(by_spell[99210]["repeatInterval"], 25, "une cadence mesuree n'est PAS remplacee")
equal(by_spell[99210]["name"], "Ecrit a la main", "un libelle ecrit a la main survit")
equal(by_spell[99210]["announce"], "SOUFFLE", "une annonce ecrite a la main survit")
ok("source" not in by_spell[99210], "et rien ne vient salir une entree intacte")

equal(by_spell[99211]["repeatInterval"], 20.5, "un trou, lui, est rempli")
equal(by_spell[99211]["source"], "BigWigs_TestSuite", "avec sa provenance")
equal(by_spell[99211]["name"], "Sans cadence", "sans toucher au reste de l'entree")

ok("repeatInterval" not in by_spell[99213],
   "une fenetre `pendingWindow` ne recoit jamais de cadence")
equal(by_spell[99213]["pendingWindow"], "phase", "... et reste une fenetre")

enrage = [t for t in timers if t.get("name") == "Enrage"]
equal(len(enrage), 1, "l'enrage est ajoute : c'est le seul vrai delai depuis le pull")
equal(enrage[0]["trigger"], "PULL", "et il s'ecrit en PULL")
equal(enrage[0]["provisional"], True, "provisoire, comme tout ce qui n'est pas mesure")
equal(filled, 1, "un seul trou a remplir")

# Deuxieme passage : tout est deja la, il ne doit plus rien se passer.
again = {"name": "Test", "timers": lua_list(timers)}
_, _, added2, filled2 = bm.fill_timers(again, bw, "BigWigs_TestSuite")
equal((added2, filled2), (0, 0), "un second passage n'ajoute rien : c'est idempotent")


# Deux sources sur le meme fichier — tu as DBM *et* BigWigs installes. Traitees
# separement, la seconde repartirait de la version d'avant et effacerait les
# ajouts de la premiere.
groups = bm.group_by_file([bw, dbm], [(Path("x.lua"), 99001, hole)])
equal(len(groups), 1, "les deux boss mods pointent sur un seul fichier")
equal(len(next(iter(groups.values()))[2]), 2, "et sont fusionnes ensemble")

chained = [dict(t) for t in wi.lua_array(hole["timers"])]
for mod in (bw, dbm):
    state = dict(hole)
    state["timers"] = lua_list(chained)
    chained, _, _, _ = bm.fill_timers(state, mod, mod.addon)
spells = [t.get("spellId") for t in chained]
equal(spells.count(99213), 1, "chainage : aucun doublon d'un passage a l'autre")
ok(99213 in spells and 99211 in spells,
   "et les apports de la premiere source survivent a la seconde")


# ----------------------------------------------------------------------------
suite("Emission")

lua = bm.write_file(Path("x.lua"), 99001, hole, timers, notes, "vanilla", "Test")
ok("GENERE PAR tools/wcl-ingest" not in lua, "le bandeau dit le bon outil")
ok("bossmod-extract" in lua, "et le nomme")
ok(re.search(r'source\s+= "BigWigs_TestSuite",', lua), "la provenance est emise")
ok("releve dans BigWigs_TestSuite" in lua, "chaque entree importee dit d'ou elle sort")
ok("-- enrage releve dans" in lua, "l'enrage aussi")

tmp = ROOT / "tests" / "_tmp_bossmod.lua"
tmp.write_text(lua, encoding="utf-8")
try:
    lua_bin = shutil.which("lua5.1") or shutil.which("lua")
    if lua_bin:
        result = subprocess.run([lua_bin, "-e", "assert(loadfile('%s'))" % tmp],
                                capture_output=True, text=True)
        ok(result.returncode == 0, "le fichier emis est du Lua valide")
    else:
        print("  --   lua absent : validation syntaxique sautee")
    reread = wi.read_existing(tmp, 99001)
    ok(reread is not None, "et il se relit avec le parseur de wcl-ingest")
    equal(len(wi.lua_array(reread["timers"])), len(timers),
          "tous les timers ont survecu a l'aller-retour")
finally:
    tmp.unlink()


print(f"\n{passed} ok, {failed} echec(s)")
sys.exit(1 if failed else 0)
