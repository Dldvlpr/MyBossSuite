#!/usr/bin/env python3
"""Tests de l'extraction depuis les boss mods installes, sans DBM ni BigWigs.

Ce que ces tests verifient n'est pas DBM : c'est notre lecture de DBM. Les
fixtures reproduisent la forme reelle des deux addons — celle relevee dans les
modules Onyxia des deux projets — et surtout ce qui casse un lecteur naif :

* un mot-cle de bloc dans un commentaire ou une chaine (`--[[ ... end ... ]]`) ;
* une virgule dans une chaine, au milieu d'une liste d'arguments ;
* `while ... do` et `for ... do`, qui ne doivent compter qu'une fois ;
* une duree calculee a l'execution, qui ne doit produire AUCUN timer ;
* la distinction cast / cooldown, ou une confusion afficherait 5 s la ou il en
  faut 35 ;
* l'identite d'une barre BigWigs, qui est son texte et non sa cle.

La regle qui traverse tout : ce qui n'est pas litteral n'est pas extrait. Un
timer absent se remarque et se corrige, un timer faux se croit.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "bossmod-extract"))

import bossmod_extract as extract  # noqa: E402
import bw_source  # noqa: E402
import dbm_source  # noqa: E402
import lua_source as L  # noqa: E402

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


def timer_for(entry, trigger, spell_id):
    for timer in entry["timers"]:
        if timer["trigger"] == trigger and timer["spell_id"] == spell_id:
            return timer
    return None


# ------------------------------------------------------------------------------

suite("Scanner Lua")

TRICKY = '''
--[[ ce commentaire contient function et end, il ne doit rien ouvrir ]]
local s = "une chaine avec , une virgule et le mot end dedans"
function mod:Handler(args)
    for i = 1, 3 do
        while true do
            if args:IsSpell(111) then break end
        end
    end
    timerA:Start(12.5)
end
function mod:Autre()
    timerB:Start()
end
'''

mask = L.blank(TRICKY)
equal(len(mask), len(TRICKY), "le masque garde la longueur du texte")
ok("function and end" not in mask, "les mots-cles d'un commentaire sont neutralises")
ok("virgule" not in mask, "le contenu d'une chaine est neutralise")
ok(mask.count("\n") == TRICKY.count("\n"), "les retours a la ligne survivent")

methods = L.find_methods(mask)
equal(sorted(methods), ["Autre", "Handler"], "les deux fonctions sont trouvees")
lo, hi = methods["Handler"][0][1:]
ok(TRICKY[lo:hi].count("timerA") == 1, "le corps de Handler s'arrete au bon `end`")
ok("timerB" not in TRICKY[lo:hi],
   "`for ... do` et `while ... do` ne comptent pas double (sinon le bloc deborde)")

args, _ = L.split_args(L.blank('f("a, b", 12, g(1, 2))'), 'f("a, b", 12, g(1, 2))', 1)
equal(args, ['"a, b"', "12", "g(1, 2)"],
      "decoupage : virgule dans une chaine et appel imbrique respectes")

equal(L.as_number("29.1 + 5"), 34.1, "duree ecrite comme une somme")
equal(L.as_number("self:Easy() and 20 or 15"), None,
      "duree calculee a l'execution : refusee")
equal(L.as_number("__import__('os')"), None, "rien d'autre qu'une arithmetique n'est evalue")
equal(L.as_duration('"v9.7-35.6"'), (9.7, True),
      "cadence variable DBM : borne basse, marquee incertaine")
equal(L.as_duration("12"), (12.0, False), "duree fixe")

# ------------------------------------------------------------------------------

suite("Lecture d'un module DBM")

DBM_MODULE = '''
local mod = DBM:NewMod("BossDeTest", "DBM-Raids-Test", 7)
mod:SetCreatureID(10184, 12129)
mod:SetEncounterID(1084)
mod:SetZone(249)

local timerFlameBreathCD = mod:NewVarTimer("v9.7-35.6", 18435, nil, "Tank|Healer", 3, 5)
local timerBreath        = mod:NewCastTimer(5, 17086, nil, nil, nil, 2)
local timerRoarCD        = mod:NewCDTimer(35, 18431)
local timerCalcule       = mod:NewCDTimer(20, 18500)

function mod:OnCombatStart()
    self:SetStage(1)
    timerFlameBreathCD:Start("v11.3-28.5")
end

function mod:SPELL_CAST_START(args)
    if args:IsSpell(17086, 18351) and args:IsSrcTypeHostile() then
        timerBreath:Start()
    elseif args:IsSpell(18435) then
        timerFlameBreathCD:Start()
    elseif args:IsSpell(18500) then
        timerCalcule:Start(self:IsHeroic() and 12 or 20)
    end
end

function mod:SPELL_AURA_APPLIED(args)
    if args:IsSpell(18431) then
        timerRoarCD:Start()
    end
end
'''

dbm = dbm_source.extract(DBM_MODULE)
equal(dbm["npc_ids"], [10184, 12129], "npcIds lus dans SetCreatureID")
equal(dbm["encounter_ids"], [1084], "encounterId lu")
equal(dbm["instance_ids"], [249], "instanceId lu")

pull = timer_for(dbm, "PULL", 18435)
ok(pull is not None, "le timer lance dans OnCombatStart devient un timer PULL")
equal(pull["time"], 11.3, "la duree du `Start` explicite prime sur celle declaree")
equal(pull["repeat_interval"], 9.7, "la duree declaree devient la cadence")
equal(pull["variable"], True, "cadence non deterministe reportee")
equal(pull["name"], "Flame Breath",
      "libelle deduit du nom de variable, pas du filtre de role")

cast = timer_for(dbm, "CAST", 17086)
ok(cast is not None, "une branche `IsSpell` donne un timer CAST sur ce sort")
equal(cast.get("test_time"), 5.0,
      "NewCastTimer = duree de l'incantation, jamais une cadence")
equal(cast.get("repeat_interval"), None, "... et donc pas de repeatInterval")
equal(cast.get("cast_start"), True, "SPELL_CAST_START -> castStart")

cooldown = timer_for(dbm, "CAST", 18435)
equal(cooldown.get("repeat_interval"), 9.7,
      "NewVarTimer = delai jusqu'au suivant, donc une cadence")
equal(cooldown.get("test_time"), None, "... et pas une duree d'incantation")

aura = timer_for(dbm, "AURA", 18431)
ok(aura is not None, "SPELL_AURA_APPLIED donne un trigger AURA")
equal(aura.get("cast_start"), False, "une aura ne porte pas castStart")

equal(timer_for(dbm, "CAST", 18500), None,
      "duree calculee a l'execution : aucun timer produit")
equal(dbm["rejected"], 1, "... et le rejet est compte, pas tu")

equal(dbm_source.extract("local x = 1\n"), None, "un fichier qui n'est pas un module rend None")

# ------------------------------------------------------------------------------

suite("Lecture d'un module BigWigs")

BW_MODULE = '''
local mod, CL = BigWigs:NewBoss("Boss De Test", 249, 1651)
if not mod then return end
mod:RegisterEnableMob(10184, 12129)
mod:SetEncounterID(1084)

local L = mod:GetLocale()
if L then
    L.stage2_yell_trigger = "from above"
    L.stage3_yell_trigger = "another lesson"
    L.deep_breath = "Deep Breath"
end

function mod:OnBossEnable()
    self:Log("SPELL_CAST_START", "FlameBreath", 18435)
    self:Log("SPELL_CAST_START", "Breath", 17086, 18351)
    self:Log("SPELL_AURA_APPLIED", "FlameLash", 18958)
end

function mod:OnEngage()
    self:SetStage(1)
    self:CDBar(18435, 13, CL.frontal_cone)
end

function mod:FlameBreath(args)
    self:CDBar(args.spellId, 12, CL.frontal_cone)
end

function mod:Breath()
    self:StopBar(L.deep_breath)
    self:CastBar(17086, 5, L.deep_breath)
end

function mod:FlameLash(args)
    self:Bar(args.spellId, 20)
end

function mod:CHAT_MSG_MONSTER_YELL(event, msg)
    if msg:find(L.stage2_yell_trigger, nil, true) then
        self:SetStage(2)
    elseif msg:find(L.stage3_yell_trigger, nil, true) then
        self:SetStage(3)
    end
end
'''

bw = bw_source.extract(BW_MODULE)
equal(bw["name"], "Boss De Test", "nom lu dans NewBoss")
equal(bw["npc_ids"], [10184, 12129], "npcIds lus dans RegisterEnableMob")

bw_pull = timer_for(bw, "PULL", 18435)
ok(bw_pull is not None, "une barre posee dans OnEngage devient un timer PULL")
equal(bw_pull["time"], 13.0, "duree du pull")

bw_cast = timer_for(bw, "CAST", 18435)
equal(bw_cast.get("repeat_interval"), 12.0,
      "self:Log mappe le sort au gestionnaire, dont le corps donne la cadence")
bw_breath = timer_for(bw, "CAST", 17086)
equal(bw_breath.get("test_time"), 5.0, "CastBar = duree d'incantation")
equal(bw_breath.get("repeat_interval"), None, "... et pas une cadence")
bw_aura = timer_for(bw, "AURA", 18958)
equal(bw_aura.get("repeat_interval"), 20.0, "SPELL_AURA_APPLIED -> trigger AURA")

phases = bw["phases"]
equal(len(phases), 3, "trois phases : l'engage et deux cris")
equal(phases[0].get("trigger"), None, "la phase 1 est l'engage, elle ne porte pas de trigger")
equal(phases[1]["trigger"], "EMOTE", "un SetStage sous un cri donne un trigger EMOTE")
equal(phases[1]["pattern"], "from above",
      "le fragment localise vient du bloc de localisation du module")
equal(phases[2]["pattern"], "another lesson", "phase 3 idem")

GAP = BW_MODULE.replace('    L.stage2_yell_trigger = "from above"\n', "")
equal(bw_source.extract(GAP)["phases"], [],
      "une phase 2 sans declencheur coupe la liste : une phase morte rendrait "
      "les suivantes inatteignables")

# ------------------------------------------------------------------------------

suite("Fusion des deux sources")

merged = extract.merge_boss(dict(bw, sources=["bigwigs"], files=["bw.lua"]),
                            dict(dbm, sources=["dbm"], files=["dbm.lua"]))
equal(merged["sources"], ["bigwigs", "dbm"], "les deux sources sont creditees")
equal(sorted(merged["files"]), ["bw.lua", "dbm.lua"], "les deux fichiers d'origine aussi")
equal(merged["name"], "Boss De Test", "le nom lisible de BigWigs gagne")
equal(len(merged["phases"]), 3, "les phases viennent de BigWigs, seul a les livrer")

fused = timer_for(merged, "PULL", 18435)
equal(fused["time"], 13.0, "la valeur de la source principale est retenue")
equal(fused["disagreement"]["time"], ("dbm", 11.3),
      "le desaccord est conserve, pas efface")
equal(fused["variable"], True,
      "si une source dit la cadence non deterministe, la barre le dit aussi")

only_dbm = timer_for(merged, "AURA", 18431)
ok(only_dbm is not None, "un timer que seul DBM connait est ajoute")
equal(only_dbm["from"], "dbm", "... en indiquant d'ou il vient")

# ------------------------------------------------------------------------------

suite("Un seul timer par sort")
# `PULL`, `PHASE` et `CAST` finissent dans la meme table du moteur, indexee par
# spellId : deux entrees pour le meme sort y donnent deux barres concurrentes.
# DBM et BigWigs declarent pourtant naturellement le meme sort deux fois — une
# fois au pull, une fois sur son propre cast — parce que chez eux c'est le meme
# objet timer redemarre.

doubles = extract.dedupe_timers({"timers": [
    {"trigger": "PULL", "spell_id": 18435, "time": 13.0, "repeat_interval": 9.7,
     "name": "Flame Breath"},
    {"trigger": "CAST", "spell_id": 18435, "repeat_interval": 12.0,
     "cast_start": True, "variable": True},
    {"trigger": "AURA", "spell_id": 18435, "repeat_interval": 30.0},
    {"trigger": "CAST", "spell_id": 17086, "test_time": 5.0},
]})["timers"]

equal(len(doubles), 3, "les deux entrees du meme sort fusionnent, l'aura reste a part")
fused = doubles[0]
equal(fused["trigger"], "PULL", "l'entree PULL est gardee : seule elle porte un `time`")
equal(fused["time"], 13.0, "... avec son delai depuis le pull")
equal(fused["repeat_interval"], 12.0,
      "la cadence armee sur un cast observe passe devant celle d'une declaration")
equal(fused["disagreement"]["repeat_interval"], ("pull", 9.7),
      "... et l'autre valeur est conservee, pas effacee")
equal(fused["variable"], True, "le drapeau `variable` de l'entree absorbee survit")
equal(fused["name"], "Flame Breath", "le libelle aussi")
equal(doubles[1]["trigger"], "AURA", "une aura n'est pas un cast : elle garde son entree")

order = extract.dedupe_timers({"timers": [
    {"trigger": "CAST", "spell_id": 555, "repeat_interval": 20.0},
    {"trigger": "PULL", "spell_id": 555, "time": 9.0},
]})["timers"]
equal(len(order), 1, "l'ordre de rencontre ne change pas le resultat")
equal(order[0]["trigger"], "PULL", "le PULL gagne meme s'il arrive en second")
equal(order[0]["repeat_interval"], 20.0, "... en absorbant la cadence du CAST")

suite("Rendu Lua")

rendered = extract.render_boss(10184, dict(merged, zone="Test_Zone", kind="raid"), "vanilla")
ok("ns.Data[10184]" in rendered, "la cle est le npcId")
ok('flavors     = { vanilla = true }' in rendered, "le flavor cible est declare")
ok("provisional = true" in rendered, "l'entree est marquee provisoire")
ok("ns.Encounter[1084] = 10184" in rendered, "l'alias encounterId est ecrit")
ok('pattern = "from above"' in rendered, "le fragment d'emote est echappe correctement")
ok("-- dbm dit time = 11.3" in rendered, "le desaccord est visible dans le fichier")
ok("npcIds      = { 12129 }" in rendered, "les npcIds secondaires sont listes")

quoted = extract.render_boss(1, {
    "name": 'Guerisseur "fou"', "npc_ids": [1], "timers": [], "phases": [],
    "zone": "Z", "kind": "raid", "sources": ["dbm"], "source": "dbm", "files": ["x"],
}, "vanilla")
ok('\\"fou\\"' in quoted, "les guillemets d'un nom sont echappes")

# ------------------------------------------------------------------------------

suite("Selection des fichiers par .toc")

sandbox = ROOT / "tests" / "_tmp_bossmod"
try:
    pack = sandbox / "DBM-Raids-Faux"
    (pack / "Boss").mkdir(parents=True)
    (pack / "Boss" / "Boss.lua").write_text(DBM_MODULE, encoding="utf-8")
    (pack / "Boss" / "localization.en.lua").write_text("-- rien\n", encoding="utf-8")
    (pack / "DBM-Raids-Faux_Vanilla.toc").write_text(
        "## Interface: 11509\n\n# commentaire\nBoss\\Boss.lua\nBoss\\localization.en.lua\n",
        encoding="utf-8")

    autre = sandbox / "DBM-Party-Retail"
    (autre / "Boss").mkdir(parents=True)
    (autre / "Boss" / "Boss.lua").write_text(DBM_MODULE, encoding="utf-8")
    (autre / "DBM-Party-Retail_Mainline.toc").write_text(
        "## Interface: 120100\nBoss\\Boss.lua\n", encoding="utf-8")

    files = [p.name for p in extract.iter_module_files(sandbox, "vanilla")]
    equal(files, ["Boss.lua"],
          "seul le pack qui a un .toc pour ce flavor est lu, et pas sa localisation")

    retail = [str(p) for p in extract.iter_module_files(sandbox, "retail")]
    equal(len(retail), 1, "sur retail, c'est l'autre pack qui se charge")
    ok("DBM-Party-Retail" in retail[0], "... et c'est bien celui-la")

    bosses, stats = extract.collect(sandbox, "vanilla")
    equal(list(bosses), [10184], "la rencontre est indexee sur son npcId principal")
    equal(bosses[10184]["zone"], "Boss", "la zone vient du dossier du module")
    equal(bosses[10184]["kind"], "raid", "kind deduit du pack (DBM-Raids-*)")
    equal(extract.content_kind("x/DBM-Party-Vanilla/y.lua"), "dungeon", "DBM-Party -> donjon")
    equal(extract.content_kind("x/DBM-WorldEvents/y.lua"), "world", "WorldEvents -> world boss")
finally:
    if sandbox.exists():
        for path in sorted(sandbox.rglob("*"), reverse=True):
            path.rmdir() if path.is_dir() else path.unlink()
        sandbox.rmdir()

# ------------------------------------------------------------------------------

suite("Refus d'ecrire dans le depot")

code = extract.main(["--install", str(ROOT), "--flavor", "vanilla",
                     "--out", str(ROOT / "Modules" / "BossTimer" / "Data")])
equal(code, 2, "ecrire la data derivee dans le depot est refuse, pas seulement deconseille")

print(f"\n{passed} ok, {failed} echec(s)")
sys.exit(0 if failed == 0 else 1)
