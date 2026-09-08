-- tests/run_tests.lua
-- Tests headless du socle : lua5.1 tests/run_tests.lua
--
-- On charge les fichiers dans l'ordre du .toc, avec le meme vararg
-- (addonName, ns) que le client, puis on pilote le temps et les events a la
-- main. Ca ne remplace pas un test en jeu, mais ca attrape les regressions de
-- logique sans lancer WoW.

package.path = "tests/?.lua;" .. package.path
require("wow_mock")

--------------------------------------------------------------------------------
-- Framework minimal
--------------------------------------------------------------------------------

local passed, failed = 0, 0
local currentSuite = ""

-- print() est capture par le mock (c'est la sortie de l'addon) : le harness
-- ecrit directement sur stdout.
local function say(line) io.write(line, "\n") end

local function suite(name) currentSuite = name; say("\n== " .. name) end

local function ok(condition, label)
    if condition then
        passed = passed + 1
        say("  ok   " .. label)
    else
        failed = failed + 1
        say("  FAIL " .. label)
    end
end

local function equal(actual, expected, label)
    if type(expected) == "number" and type(actual) == "number" then
        ok(math.abs(actual - expected) < 0.05,
            ("%s (attendu %s, obtenu %s)"):format(label, expected, tostring(actual)))
    else
        ok(actual == expected,
            ("%s (attendu %s, obtenu %s)"):format(label, tostring(expected), tostring(actual)))
    end
end

--------------------------------------------------------------------------------
-- Chargement
--------------------------------------------------------------------------------

local FILES = {
    "Core/Compat.lua",
    "Core/Scheduler.lua",
    "Core/EventBus.lua",
    "Core/DB.lua",
    "Core/Anchors.lua",
    "Core/Bars.lua",
    "Core/Alerts.lua",
    "Core/Config.lua",
    "Core/ModuleLoader.lua",
    "Modules/SwingTimer/SwingTimer.lua",
    "Modules/BossTimer/BossTimer.lua",
    "Modules/InterruptAlert/InterruptAlert.lua",
    "Modules/MoveAlert/MoveAlert.lua",
    "Modules/BossTimer/Data/vanilla/Onyxias_Lair/Onyxia.lua",
}

-- `--no-c-timer` simule un client Classic Era ancien sans C_Timer : c'est le
-- fallback OnUpdate de Compat qui doit alors faire tourner tout le Scheduler.
local useNativeTimers = true
-- `--retail` rejoue exactement la meme suite sur un client mainline : c'est le
-- test qui verifie que Compat absorbe la divergence sans qu'aucun module bouge.
local retail = false
for _, argument in ipairs({ ... }) do
    if argument == "--no-c-timer" then useNativeTimers = false end
    if argument == "--retail" then retail = true end
end
Mock.InstallTimerAPI(useNativeTimers)
if retail then Mock.InstallRetail() end

local ns = {}
for _, file in ipairs(FILES) do
    local chunk = assert(loadfile(file))
    chunk("MyBossSuite", ns)
end

local BOSS_GUID = "Creature-0-1-2-3-10184-000001"
local PLAYER_GUID = "Player-0-0001"

--------------------------------------------------------------------------------

suite("Compat")
equal(ns.has.nativeTimers, useNativeTimers, "detection de C_Timer")
equal(ns.flavor, retail and "retail" or "vanilla", "flavor detecte")
equal(ns.isRetail, retail, "isRetail")
equal(ns.has.encounterEvents, retail, "presence de ENCOUNTER_START")
equal(ns.has.parryHaste, not retail, "parry haste seulement en classic")
equal(ns.NpcIdFromGUID(BOSS_GUID), 10184, "npcId extrait du GUID")
equal(ns.NpcIdFromGUID(PLAYER_GUID), nil, "GUID joueur -> pas de npcId")
equal(ns.GetSpellName(17086), "Flame Breath",
    retail and "nom de sort via C_Spell" or "nom de sort via GetSpellInfo")
equal(ns.GetSpellTexture(17086), "icon-17086", "texture de sort via Compat")

--------------------------------------------------------------------------------

suite("Scheduler")
local fired = 0
ns.Scheduler:Schedule("test_a", 5, function() fired = fired + 1 end)
ns.Scheduler:Schedule("test_b", 5, function() fired = fired + 10 end)
ok(ns.Scheduler:IsScheduled("test_a"), "timer programme")
ns.Scheduler:Cancel("test_b")
Mock.Advance(6)
equal(fired, 1, "un seul timer a tire, l'autre etait annule")

ns.Scheduler:Schedule("prefix_1", 3, function() fired = fired + 100 end)
ns.Scheduler:Schedule("prefix_2", 3, function() fired = fired + 100 end)
ns.Scheduler:Schedule("autre_1", 3, function() fired = fired + 1 end)
ns.Scheduler:CancelPrefix("prefix_")
Mock.Advance(4)
equal(fired, 2, "CancelPrefix n'annule que son prefixe")

local ticks = 0
ns.Scheduler:Repeat("tick", 1, function() ticks = ticks + 1 end)
Mock.Advance(3.5)
ns.Scheduler:Cancel("tick")
ok(ticks >= 3, "ticker repete (" .. ticks .. " ticks)")
Mock.Advance(3)
equal(ticks, ticks, "ticker annule ne tire plus")

--------------------------------------------------------------------------------

suite("DB + bootstrap")
Mock.FireEvent("ADDON_LOADED", "AutreAddon")
equal(ns.DB.initialized, nil, "ADDON_LOADED d'un autre addon ignore")
Mock.FireEvent("ADDON_LOADED", "MyBossSuite")
ok(ns.DB.initialized, "DB initialisee")
equal(ns.DB:GetProfileName(), "Testeur-Mock", "profil par personnage")
ok(type(ns.db.anchors) == "table", "db.anchors existe des le premier lancement")
equal(ns.db.modules.swingTimer.enabled, true, "defaults du module fusionnes")
equal(ns.db.modules.bossTimer.sound, true, "defaults specifiques du module")

Mock.FireEvent("PLAYER_LOGIN")
equal(ns:IsModuleEnabled("swingTimer"), true, "module actif au login")
equal(ns:IsModuleEnabled("cdTracker"), false, "module desactive par defaut")
equal(ns:IsModuleEnabled("interruptAlert"), true, "alerte kick active par defaut")
equal(ns:IsModuleEnabled("moveAlert"), true, "alerte move active par defaut")

-- Les deux modules d'alerte ecoutent le combat log : on les eteint pendant les
-- suites qui le pilotent pour autre chose, chacun a la sienne plus bas.
ns:SetModuleEnabled("interruptAlert", false)
ns:SetModuleEnabled("moveAlert", false)

--------------------------------------------------------------------------------

suite("ModuleLoader")
local swing = ns:GetModule("swingTimer")
ok(ns.EventBus.handlers["COMBAT_LOG_EVENT_UNFILTERED"] ~= nil, "CLEU enregistre")
ns:SetModuleEnabled("swingTimer", false)
equal(swing.isEnabled, false, "module desactive a chaud")
equal(next(swing._events), nil, "plus aucun event apres OnDisable")
equal(ns.db.modules.swingTimer.enabled, false, "etat persiste dans le profil")
ns:SetModuleEnabled("swingTimer", true)
equal(swing.isEnabled, true, "module reactive a chaud")
ok(swing._events["COMBAT_LOG_EVENT_UNFILTERED"] ~= nil, "events re-enregistres")

--------------------------------------------------------------------------------

suite("Anchors")
local group = ns.Bars.groups["SwingTimer_Bar"]
ok(group ~= nil, "groupe swing timer enregistre comme ancre")
equal(group.anchorKey, "SwingTimer_Bar", "anchorKey pose")
group:SetPoint("CENTER", UIParent, "CENTER", 123, -45)
group:SetScale(1.25)
group:SaveAnchor()
local saved = ns.db.anchors["SwingTimer_Bar"]
equal(saved.x, 123, "position sauvegardee")
equal(saved.scale, 1.25, "scale sauvegarde")
equal(saved.relTo, "UIParent", "relativeTo conserve")
group:ClearAllPoints()
group:LoadAnchor()
local point, _, _, x = group:GetPoint()
equal(point, "CENTER", "point restaure")
equal(x, 123, "offset restaure")
group:ResetAnchor()
equal(ns.db.anchors["SwingTimer_Bar"], nil, "reset efface la sauvegarde")

ns.Anchors:Unlock()
ok(group.mbsUnlocked, "frame deverrouillee")
ok(group:IsShown(), "frame vide rendue visible en mode unlock")
ns.Anchors:Lock()
equal(group.mbsUnlocked, false, "frame reverrouillee")
equal(group:IsShown(), false, "frame vide re-cachee")

--------------------------------------------------------------------------------

suite("Bars")
local bars = ns.Bars:GetGroup("Test_Group", { label = "test" })
local bar = bars:StartBar("x", 10, "Sort", nil, {})
equal(bars:Count(), 1, "une barre active")
Mock.Advance(4)
ok(math.abs(bar:GetRemaining() - 6) < 0.2, "temps restant decompte")
bar:SetRemaining(1)
Mock.Advance(1.2)
equal(bars:Count(), 0, "barre expiree retiree")
equal(bars:IsShown(), false, "groupe vide cache")

bars:StartBar("a", 5, "A", nil, {})
bars:StartBar("b", 2, "B", nil, {})
equal(bars.order[1].id, "b", "barres triees par temps restant")
bars:StopAll()
equal(bars:Count(), 0, "StopAll vide le groupe")

--------------------------------------------------------------------------------

suite("SwingTimer")
Mock.units.target = { guid = BOSS_GUID, name = "Onyxia", health = 100, healthMax = 100 }
Mock.FireEvent("PLAYER_TARGET_CHANGED")
Mock.attackSpeed = 2.6

Mock.FireCombatLog("SWING_DAMAGE", PLAYER_GUID, BOSS_GUID)
local playerBar = ns.Bars.groups["SwingTimer_Bar"]:GetBar("SwingTimer_Bar")
ok(playerBar ~= nil, "barre joueur demarree au premier swing")
equal(playerBar.duration, 2.6, "duree = vitesse d'attaque exacte")

-- Parry haste : c'est l'unite qui PARE dont le swing en cours est ampute.
Mock.Advance(0.5)
local before = playerBar:GetRemaining()
Mock.FireCombatLog("SWING_MISSED", BOSS_GUID, PLAYER_GUID, "PARRY")
local after = playerBar:GetRemaining()
if retail then
    equal(after, before, "pas de parry haste en retail")
else
    ok(after < before - 0.9, ("parry haste raccourcit le swing (%.2f -> %.2f)"):format(before, after))
    ok(after >= 2.6 * 0.2 - 0.01, "parry haste plafonne a 20% de la duree")
end

-- Cible : pas de delta au premier swing, mesure au second.
Mock.FireCombatLog("SWING_DAMAGE", BOSS_GUID, PLAYER_GUID)
local targetBar = ns.Bars.groups["SwingTimer_TargetBar"]:GetBar("SwingTimer_TargetBar")
ok(targetBar ~= nil, "barre cible affichee des le premier swing")
equal(targetBar.variable, true, "premier swing = barre de calibration")
Mock.Advance(2)
Mock.FireCombatLog("SWING_DAMAGE", BOSS_GUID, PLAYER_GUID)
targetBar = ns.Bars.groups["SwingTimer_TargetBar"]:GetBar("SwingTimer_TargetBar")
equal(targetBar.variable, false, "delta mesure : barre plus marquee variable")
equal(targetBar.duration, 2.0, "duree = delta mesure entre deux swings")

-- SWING_DAMAGE_LANDED (retail) ne doit jamais compter.
local beforeLanded = targetBar.endTime
Mock.FireCombatLog("SWING_DAMAGE_LANDED", BOSS_GUID, PLAYER_GUID)
equal(ns.Bars.groups["SwingTimer_TargetBar"]:GetBar("SwingTimer_TargetBar").endTime,
    beforeLanded, "SWING_DAMAGE_LANDED ignore")

--------------------------------------------------------------------------------

suite("BossTimer")
local boss = ns:GetModule("bossTimer")
equal(boss:CountData(), 1, "data Onyxia chargee")
if retail then
    -- La data vanilla chargee sur un client retail doit etre signalee.
    equal(boss:ValidateData(), 1, "data d'un autre flavor detectee")
    ok(boss._events["ENCOUNTER_START"] ~= nil, "ENCOUNTER_START enregistre")
    Mock.FireEvent("ENCOUNTER_START", 1084, "Onyxia", 1, 40)
    equal(boss.engaged, 10184, "engage via ENCOUNTER_START (encounterId -> npcId)")
    Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 12345)
else
    equal(boss:ValidateData(), 0, "data valide")
    equal(boss._events["ENCOUNTER_START"], nil, "ENCOUNTER_START absent de ce client")
    Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 12345)
    equal(boss.engaged, 10184, "engage detecte via le combat log")
end
equal(boss.bossGUID, BOSS_GUID, "GUID du boss retenu")

local generic = ns.Bars.groups["BossTimer_GenericBar"]
ok(generic:GetBar("t1") ~= nil, "barre du timer PULL affichee")
equal(generic:GetBar("t1").duration, 12, "duree = offset depuis le pull")

local firedTimers = {}
ns.EventBus:On("BOSS_TIMER_FIRED", function(def) firedTimers[#firedTimers + 1] = def.name end)

Mock.Advance(12.5)
equal(firedTimers[1], "Flame Breath", "timer PULL declenche a l'heure")
equal(generic:GetBar("t1").duration, 25, "repeatInterval relance la barre")

-- Un cast observe resynchronise la prochaine occurrence.
Mock.Advance(5)
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 17086)
equal(generic:GetBar("t1"):GetRemaining(), 25, "resynchro sur le cast observe")

-- Un trigger CAST tire une seule fois par sort, meme avec START + SUCCESS.
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18435)
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 18435)
local volleyCount = 0
for _, name in ipairs(firedTimers) do
    if name == "Fireball Volley" then volleyCount = volleyCount + 1 end
end
equal(volleyCount, 1, "pas de double declenchement START + SUCCESS")

-- Seuil de vie.
Mock.units.target.health = 60
Mock.Advance(1)
local phaseCount = 0
for _, name in ipairs(firedTimers) do
    if name == "Phase 2 - Deep Breath" then phaseCount = phaseCount + 1 end
end
equal(phaseCount, 1, "seuil HEALTH declenche a 60%")
Mock.Advance(2)
phaseCount = 0
for _, name in ipairs(firedTimers) do
    if name == "Phase 2 - Deep Breath" then phaseCount = phaseCount + 1 end
end
equal(phaseCount, 1, "`once` empeche le retrigger")

-- Fin de combat : rien du pull precedent ne doit survivre.
if retail then
    Mock.FireEvent("ENCOUNTER_END", 1084, "Onyxia", 1, 40, 1)
else
    Mock.FireEvent("PLAYER_REGEN_ENABLED")
end
equal(boss.engaged, nil, "disengage sur fin de combat")
equal(generic:Count(), 0, "barres nettoyees")
local leftovers = 0
for key in pairs(ns.Scheduler.active) do
    if key:sub(1, 10) == "BossTimer_" then leftovers = leftovers + 1 end
end
equal(leftovers, 0, "aucun timer du pull precedent ne survit")

--------------------------------------------------------------------------------

suite("Alertes")
-- Le boss timer et le swing timer pilotent aussi le combat log : on les eteint
-- pendant les trois suites d'alerte pour que chacune ne teste qu'elle-meme.
ns:SetModuleEnabled("bossTimer", false)
ns:SetModuleEnabled("swingTimer", false)

ok(ns.Alerts:Get("kick") ~= nil, "alerte kick declaree")
ok(ns.Alerts:Get("move") ~= nil, "alerte move declaree")
ok(ns.Anchors.registry["InterruptAlert_Display"] ~= nil, "alerte kick deplacable")
ok(ns.Anchors.registry["MoveAlert_Display"] ~= nil, "alerte move deplacable")

local moveDisplay = ns.Alerts:Get("move").display

Mock.sounds = {}
ns.Alerts:Show("move", { subtitle = "zone" })
ok(moveDisplay:IsShown(), "alerte affichee")
equal(moveDisplay.text:GetText(), "MOVE", "texte par defaut du module")
equal(#Mock.sounds, 1, "son joue avec l'alerte")
Mock.Advance(3)
equal(moveDisplay:IsShown(), false, "alerte masquee une fois sa duree ecoulee")

ns.Alerts:Set("move", "sound", false)
Mock.sounds = {}
ns.Alerts:Show("move", {})
equal(#Mock.sounds, 0, "son coupe : aucun son ne part")
ok(moveDisplay:IsShown(), "... mais le visuel reste")
ns.Alerts:Hide("move")

ns.Alerts:Set("move", "sound", true)
ns.Alerts:Set("move", "visual", false)
Mock.sounds = {}
ns.Alerts:Show("move", {})
equal(moveDisplay:IsShown(), false, "visuel coupe : rien ne s'affiche")
equal(#Mock.sounds, 1, "... mais le son part quand meme")

ns.Alerts:Set("move", "visual", true)
ns.Alerts:Set("move", "text", "BOUGE")
ns.Alerts:Set("move", "fontSize", 60)
ns.Alerts:Show("move", {})
equal(moveDisplay.text:GetText(), "BOUGE", "texte personnalise")
local _, appliedSize = moveDisplay.text:GetFont()
equal(appliedSize, 60, "taille de police personnalisee")
ns.Alerts:Hide("move")

-- Le throttle se compte depuis le dernier son joue : on laisse passer le delai
-- avant de le tester, sinon c'est l'alerte precedente qu'on mesure.
Mock.Advance(1)
Mock.sounds = {}
ns.Alerts:Show("move", {})
ns.Alerts:Show("move", {})
equal(#Mock.sounds, 1, "throttle : deux alertes rapprochees, un seul son")
ns.Alerts:Preview("move")
equal(#Mock.sounds, 2, "l'apercu ignore le throttle")
ns.Alerts:Hide("move")

ns.Alerts:Reset("move")
equal(ns.Alerts:GetConfig("move").text, "MOVE", "reset : retour aux valeurs du module")
equal(ns.Alerts:GetConfig("move").fontSize, 54, "reset : taille remise par defaut")

-- Le preset "alarm" du kick : premier SOUNDKIT existant de la chaine de repli.
Mock.sounds = {}
ns.Alerts:PlaySound("kick", true)
equal(Mock.sounds[1].kit, retail and 42 or 1,
    retail and "preset alarm : kit retail" or "preset alarm : repli sur RAID_WARNING")

ns.Alerts:Set("kick", "soundName", "Interface\\AddOns\\Perso\\kick.ogg")
Mock.sounds = {}
ns.Alerts:PlaySound("kick", true)
equal(Mock.sounds[1].file, "Interface\\AddOns\\Perso\\kick.ogg",
    "un chemin de fichier est joue comme fichier")
ns.Alerts:Reset("kick")

--------------------------------------------------------------------------------

suite("InterruptAlert")
ns:SetModuleEnabled("interruptAlert", true)
local kick = ns:GetModule("interruptAlert")
local kickDisplay = ns.Alerts:Get("kick").display
equal(kick.interruptSpell, 1766, "interrupt de la classe detecte dans le grimoire")

Mock.units.target = { guid = BOSS_GUID, name = "Onyxia", health = 100, healthMax = 100 }
Mock.FireEvent("PLAYER_TARGET_CHANGED")

Mock.SetCast("target", 17086, true)
Mock.FireEvent("UNIT_SPELLCAST_START", "target")
equal(kickDisplay:IsShown(), false, "cast protege : aucune alerte")

Mock.SetCast("target", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "target")
ok(kickDisplay:IsShown(), "cast interruptible : alerte affichee")
equal(kickDisplay.text:GetText(), "KICK", "texte KICK")
equal(kickDisplay.subtitle:GetText(), "Flame Breath", "nom du sort incante affiche")

Mock.Advance(3)
ok(kickDisplay:IsShown(), "l'alerte reste tant que l'incantation dure")

Mock.SetCast("target", nil)
Mock.FireEvent("UNIT_SPELLCAST_STOP", "target")
equal(kickDisplay:IsShown(), false, "alerte retiree a la fin de l'incantation")

Mock.cooldowns[1766] = { start = Mock.now, duration = 15 }
Mock.SetCast("target", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "target")
equal(kickDisplay:IsShown(), false, "kick en cooldown : aucune alerte")

-- Le cooldown se termine au milieu de l'incantation : c'est le ticker qui doit
-- rattraper le coup, aucun event ne le signale.
Mock.cooldowns[1766] = nil
Mock.Advance(0.4)
ok(kickDisplay:IsShown(), "alerte des que le kick revient, sans nouvel event")

Mock.outOfRange = true
Mock.Advance(0.4)
equal(kickDisplay:IsShown(), false, "hors de portee : alerte retiree")
Mock.outOfRange = false
Mock.Advance(0.4)
ok(kickDisplay:IsShown(), "de retour a portee : alerte de nouveau")

-- Repli combat log, pour les clients ou UnitCastingInfo ne repond rien sur une
-- unite hostile.
Mock.SetCast("target", nil)
Mock.FireEvent("UNIT_SPELLCAST_STOP", "target")
equal(kickDisplay:IsShown(), false, "plus d'incantation, plus d'alerte")
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
ok(kickDisplay:IsShown(), "repli combat log : alerte sur SPELL_CAST_START")
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
equal(kickDisplay:IsShown(), false, "repli combat log : alerte retiree au SUCCESS")

-- Un cast d'une unite qui n'est ni la cible ni le focus ne doit rien declencher.
Mock.FireCombatLog("SPELL_CAST_START", "Creature-0-1-2-3-99999-000009", PLAYER_GUID, 18435, "Autre")
equal(kickDisplay:IsShown(), false, "incantation d'une autre unite : ignoree")

ns:SetModuleEnabled("interruptAlert", false)
equal(kickDisplay:IsShown(), false, "module eteint : alerte retiree")

--------------------------------------------------------------------------------

suite("MoveAlert")
ns:SetModuleEnabled("moveAlert", true)
local move = ns:GetModule("moveAlert")
local moveConfig = move:GetConfig()
wipe(moveConfig.spells)
wipe(moveConfig.ignored)

Mock.FireCombatLog("SPELL_PERIODIC_DAMAGE", BOSS_GUID, PLAYER_GUID, 22271, "Fire Patch", 1, 20)
ok(moveDisplay:IsShown(), "degats periodiques : alerte MOVE")
ok(move:IsKnown(22271), "la zone est memorisee dans le profil")

Mock.sounds = {}
Mock.FireCombatLog("SPELL_PERIODIC_DAMAGE", BOSS_GUID, PLAYER_GUID, 22271, "Fire Patch", 1, 20)
equal(#Mock.sounds, 0, "tick suivant : throttle, pas de seconde alerte")
Mock.Advance(3)

-- Un DoT est une aura que tu portes : bouger n'y change rien.
Mock.auras.player = { { spellId = 22272 } }
Mock.FireCombatLog("SPELL_PERIODIC_DAMAGE", BOSS_GUID, PLAYER_GUID, 22272, "Corruption", 1, 20)
equal(moveDisplay:IsShown(), false, "DoT sur toi : aucune alerte")
equal(move:IsKnown(22272), false, "... et rien de memorise")
Mock.auras.player = nil

Mock.FireCombatLog("SPELL_DAMAGE", BOSS_GUID, PLAYER_GUID, 22273, "Cleave", 1, 30)
equal(moveDisplay:IsShown(), false, "degats directs inconnus : aucune alerte")
moveConfig.spells[22273] = true
Mock.FireCombatLog("SPELL_DAMAGE", BOSS_GUID, PLAYER_GUID, 22273, "Cleave", 1, 30)
ok(moveDisplay:IsShown(), "degats directs d'un sort de la liste : alerte")
Mock.Advance(3)

Mock.FireCombatLog("SPELL_PERIODIC_DAMAGE", BOSS_GUID, PLAYER_GUID, 22275, "Poussiere", 1, 1)
equal(moveDisplay:IsShown(), false, "coup sous le seuil : ignore")

move:Ignore(22271)
Mock.FireCombatLog("SPELL_PERIODIC_DAMAGE", BOSS_GUID, PLAYER_GUID, 22271, "Fire Patch", 1, 20)
equal(moveDisplay:IsShown(), false, "sort ignore : plus aucune alerte")
equal(move:IsKnown(22271), false, "ignorer un sort le retire de la liste")
move:Unignore(22271)

Mock.FireCombatLog("ENVIRONMENTAL_DAMAGE", nil, PLAYER_GUID, "Fire", 15)
ok(moveDisplay:IsShown(), "degats d'environnement (feu) : alerte")
Mock.Advance(3)

-- Les degats subis par quelqu'un d'autre ne te concernent pas.
Mock.FireCombatLog("SPELL_PERIODIC_DAMAGE", BOSS_GUID, "Player-0-9999", 22276, "Zone", 1, 50)
equal(moveDisplay:IsShown(), false, "degats sur un autre joueur : ignores")

ns:SetModuleEnabled("moveAlert", false)
ns:SetModuleEnabled("bossTimer", true)
ns:SetModuleEnabled("swingTimer", true)

--------------------------------------------------------------------------------

suite("Mode test")
ns.Config:StartTest()
ok(ns.testMode, "mode test actif")
ok(generic:Count() > 0, "barres factices sur l'ancre generique")
Mock.Advance(45)
ok(generic:Count() > 0, "les barres de test bouclent")
ns.Config:StopTest()
equal(generic:Count(), 0, "mode test arrete, barres retirees")

boss:TestBoss(10184)
ok(generic:Count() > 0, "/mbs test boss rejoue la timeline")
ns.Config:StopTest()
equal(boss.testing, false, "test boss arrete")

--------------------------------------------------------------------------------

suite("Slash")
SlashCmdList["MYBOSSSUITE"]("list")
ok(Mock.FindPrinted("bossTimer"), "/mbs list affiche les modules")
SlashCmdList["MYBOSSSUITE"]("disable swingTimer")
equal(ns:IsModuleEnabled("swingTimer"), false, "/mbs disable")
SlashCmdList["MYBOSSSUITE"]("enable swingTimer")
equal(ns:IsModuleEnabled("swingTimer"), true, "/mbs enable")
SlashCmdList["MYBOSSSUITE"]("unlock")
ok(ns.Anchors.unlocked, "/mbs unlock")
SlashCmdList["MYBOSSSUITE"]("lock")
equal(ns.Anchors.unlocked, false, "/mbs lock")
SlashCmdList["MYBOSSSUITE"]("profile list")
ok(Mock.FindPrinted("Testeur-Mock"), "/mbs profile list")

SlashCmdList["MYBOSSSUITE"]("alert")
ok(Mock.FindPrinted("kick"), "/mbs alert liste les alertes")
SlashCmdList["MYBOSSSUITE"]("alert move taille 66")
equal(ns.Alerts:GetConfig("move").fontSize, 66, "/mbs alert <cle> taille")
SlashCmdList["MYBOSSSUITE"]("alert move texte BOUGE DE LA")
equal(ns.Alerts:GetConfig("move").text, "BOUGE DE LA", "/mbs alert <cle> texte (espaces conserves)")
SlashCmdList["MYBOSSSUITE"]("alert move couleur 0.1 0.2 0.3")
equal(ns.Alerts:GetConfig("move").color[2], 0.2, "/mbs alert <cle> couleur")
SlashCmdList["MYBOSSSUITE"]("alert move son off")
equal(ns.Alerts:GetConfig("move").sound, false, "/mbs alert <cle> son off")
SlashCmdList["MYBOSSSUITE"]("alert move son alarm")
equal(ns.Alerts:GetConfig("move").sound, true, "choisir un son rallume le son")
equal(ns.Alerts:GetConfig("move").soundName, "alarm", "/mbs alert <cle> son <preset>")
SlashCmdList["MYBOSSSUITE"]("alert move reset")
equal(ns.Alerts:GetConfig("move").text, "MOVE", "/mbs alert <cle> reset")

SlashCmdList["MYBOSSSUITE"]("move add 12345")
ok(ns:GetModule("moveAlert"):IsKnown(12345), "/mbs move add")
SlashCmdList["MYBOSSSUITE"]("move remove 12345")
equal(ns:GetModule("moveAlert"):IsKnown(12345), false, "/mbs move remove")
SlashCmdList["MYBOSSSUITE"]("move seuil 10")
equal(ns:GetModule("moveAlert"):GetConfig().threshold, 0.1, "/mbs move seuil <pct>")
SlashCmdList["MYBOSSSUITE"]("move seuil 2")

SlashCmdList["MYBOSSSUITE"]("kick spell 2139")
equal(ns:GetModule("interruptAlert").interruptSpell, 2139, "/mbs kick spell <id>")
SlashCmdList["MYBOSSSUITE"]("kick spell auto")
equal(ns:GetModule("interruptAlert").interruptSpell, 1766, "/mbs kick spell auto")
SlashCmdList["MYBOSSSUITE"]("kick focus off")
equal(ns:GetModule("interruptAlert"):GetConfig().watchFocus, false, "/mbs kick focus off")
SlashCmdList["MYBOSSSUITE"]("kick focus on")

--------------------------------------------------------------------------------

say(("\n%d ok, %d echec(s)"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
