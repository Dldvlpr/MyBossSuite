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
    -- Les fichiers de data se chargent en dernier, comme dans un .toc.
    "Modules/BossTimer/Data/vanilla/Onyxias_Lair/Onyxia.lua",
    "Modules/BossTimer/Data/vanilla/Blasted_Lands/Lord_Kazzak.lua",
    "Modules/BossTimer/Data/vanilla/Scarlet_Monastery/Herod.lua",
    "tests/fixtures/BossData.lua",
    "tests/fixtures/AlertData.lua",
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
equal(ns.has.encounterProgress, retail, "presence de IsEncounterInProgress")
equal(ns.GetContentKind(), "world", "hors instance = world")
Mock.instance.type = "party"
equal(ns.GetContentKind(), "dungeon", "instance party = dungeon")
Mock.instance.type = "raid"
equal(ns.GetContentKind(), "raid", "instance raid = raid")
Mock.instance.type = "none"
equal(ns.IsGroupInCombat(), false, "personne en combat")
Mock.units.player.combat = true
equal(ns.IsGroupInCombat(), true, "joueur en combat")
Mock.units.player.combat = false

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
equal(boss:CountData(), 5, "data chargee (Onyxia, Kazzak, Herod + 2 fixtures)")
equal(ns.BossTimerAlias[99002], 99001, "npcId secondaire aliase vers la rencontre")
if retail then
    -- La data vanilla chargee sur un client retail doit etre signalee.
    equal(boss:ValidateData(), 3, "data d'un autre flavor detectee")
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
equal(boss.kind, "raid", "nature de la rencontre lue dans la data")
equal(boss.phase, 1, "phase 1 a l'engage")
equal(boss:PhaseLabel(), "Phase 1/3 - Sol", "libelle de phase")
ok(boss.phaseFrame:IsShown(), "cadre de phase affiche")
Mock.Advance(0.3)
ok(boss.phaseFrame.title:GetText():find("Onyxia", 1, true) ~= nil, "cadre : nom du boss")
ok(boss.phaseFrame.title:GetText():find("Phase 1/3", 1, true) ~= nil, "cadre : phase courante")

local generic = ns.Bars.groups["BossTimer_GenericBar"]
ok(generic:GetBar("t1") ~= nil, "barre du timer PULL affichee")
equal(generic:GetBar("t1").duration, 12, "duree = offset depuis le pull")
equal(generic:GetBar("t4"), nil, "timer de phase 3 pas encore programme")

local firedTimers = {}
ns.EventBus:On("BOSS_TIMER_FIRED", function(def) firedTimers[#firedTimers + 1] = def.name end)
local function CountFired(name)
    local n = 0
    for _, fired in ipairs(firedTimers) do if fired == name then n = n + 1 end end
    return n
end
local phaseChanges = {}
ns.EventBus:On("BOSS_PHASE_CHANGED", function(index, _, _, reason)
    phaseChanges[#phaseChanges + 1] = index .. ":" .. tostring(reason)
end)

Mock.Advance(12.5)
equal(firedTimers[1], "Flame Breath", "timer PULL declenche a l'heure")
equal(generic:GetBar("t1").duration, 25, "repeatInterval relance la barre")

-- Un cast observe resynchronise la prochaine occurrence.
Mock.Advance(5)
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 17086)
equal(generic:GetBar("t1"):GetRemaining(), 25, "resynchro sur le cast observe")

-- Un timer reserve a la phase 2 ne reagit pas en phase 1.
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 18435)
equal(CountFired("Fireball Volley"), 0, "timer de phase 2 muet en phase 1")

-- Seuil de vie : phase 2. Les timers de phase 1 tombent, ceux de phase 2 vivent.
local bossDisplay = ns.Alerts:Get("boss").display
Mock.units.target.health = 60
Mock.Advance(1)
equal(boss.phase, 2, "seuil HEALTH 65% : phase 2")
equal(phaseChanges[#phaseChanges], "2:health", "BOSS_PHASE_CHANGED emis avec la raison")
equal(generic:GetBar("t1"), nil, "Flame Breath (phase 1) coupe au changement de phase")
ok(bossDisplay:IsShown(), "annonce de phase affichee")
equal(bossDisplay.text:GetText(), "Phase 2", "texte de l'annonce de phase")
equal(bossDisplay.subtitle:GetText(), "Vol", "nom de la phase en sous-titre")
equal(boss:PhaseLabel(), "Phase 2/3 - Vol", "libelle de la phase 2")
Mock.Advance(0.3)
ok(boss.phaseFrame.title:GetText():find("Phase 2/3", 1, true) ~= nil, "cadre mis a jour")
ok(boss.phaseFrame.health:GetText() == "60%", "cadre : vie du boss")

-- Un trigger CAST tire une seule fois par sort, meme avec START + SUCCESS.
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18435)
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 18435)
equal(CountFired("Fireball Volley"), 1, "pas de double declenchement START + SUCCESS")

-- Annonce plein ecran d'un timer marque `announce`, sur SPELL_CAST_START.
Mock.Advance(3)
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18431)
equal(bossDisplay.text:GetText(), "DEEP BREATH", "annonce du timer au cast")

-- Aura sur le joueur : annonce "SUR TOI".
Mock.Advance(3)
Mock.FireCombatLog("SPELL_AURA_APPLIED", BOSS_GUID, PLAYER_GUID, 18431, "Deep Breath", "DEBUFF")
equal(bossDisplay.text:GetText(), "Deep Breath SUR TOI", "aura sur le joueur annoncee")
Mock.FireCombatLog("SPELL_AURA_APPLIED", BOSS_GUID, "Player-0-9999", 18431, "Deep Breath", "DEBUFF")
equal(CountFired("Deep Breath"), 2, "aura sur un autre joueur : pas pour toi")

-- Phase 3 : le timer relatif a l'entree dans la phase demarre.
Mock.units.target.health = 35
Mock.Advance(1)
equal(boss.phase, 3, "seuil HEALTH 40% : phase 3")
ok(generic:GetBar("t4") ~= nil, "timer PHASE programme a l'entree en phase 3")
equal(generic:GetBar("t4").duration, 10, "duree relative a l'entree dans la phase")

-- Un seuil deja franchi ne redeclenche pas sa phase.
Mock.units.target.health = 60
Mock.Advance(1)
equal(boss.phase, 3, "un seuil deja franchi ne ramene pas en arriere")

-- Sortir de combat n'est pas la fin du combat : c'est le groupe qui decide.
Mock.printed = {}
if retail then
    Mock.FireEvent("PLAYER_REGEN_ENABLED")
    Mock.Advance(1)
    equal(boss.engaged, 10184, "hors combat : toujours engage pendant le delai de grace")
    Mock.FireEvent("ENCOUNTER_END", 1084, "Onyxia", 1, 40, 1)
    equal(boss.engaged, nil, "disengage sur ENCOUNTER_END")
    ok(Mock.FindPrinted("kill"), "resume de kill imprime")
else
    Mock.FireEvent("PLAYER_REGEN_ENABLED")
    Mock.Advance(1)
    equal(boss.engaged, 10184, "hors combat : toujours engage pendant le delai de grace")
    Mock.Advance(3)
    equal(boss.engaged, nil, "wipe : plus personne en combat apres le delai de grace")
    ok(Mock.FindPrinted("wipe"), "resume de wipe imprime")
    ok(Mock.FindPrinted("phase 3/3"), "resume : phase atteinte")
end
equal(generic:Count(), 0, "barres nettoyees")
equal(boss.phaseFrame:IsShown(), false, "cadre de phase masque")
local leftovers = 0
for key in pairs(ns.Scheduler.active) do
    if key:sub(1, 10) == "BossTimer_" then leftovers = leftovers + 1 end
end
equal(leftovers, 0, "aucun timer du pull precedent ne survit")

--------------------------------------------------------------------------------

suite("BossTimer - donjon")
Mock.instance = { name = "Terrain d'essai", type = "party", difficulty = 2, instanceId = 900 }
Mock.groupSize = 5
Mock.units.party1 = { guid = "Player-0-0002", name = "Tank", combat = true }
local DUNGEON_GUID = "Creature-0-1-2-3-99100-000002"

Mock.FireCombatLog("SPELL_CAST_SUCCESS", DUNGEON_GUID, PLAYER_GUID, 55555)
equal(boss.engaged, 99100, "boss de donjon engage via le combat log")
equal(boss.kind, "dungeon", "nature : donjon")
equal(boss:PhaseLabel(), "", "pas de phases declarees : pas de libelle")
ok(generic:GetBar("t2") ~= nil, "timer reserve a la difficulte courante programme")
equal(generic:GetBar("t1"), nil, "timer d'une autre difficulte ignore")
ok(generic:GetBar("t3") ~= nil, "timer sans restriction programme")

-- Le joueur meurt : il sort de combat, mais le groupe se bat toujours.
Mock.FireEvent("PLAYER_REGEN_ENABLED")
Mock.Advance(5)
equal(boss.engaged, 99100, "joueur hors combat, groupe en combat : toujours engage")
ok(generic:GetBar("t3") ~= nil, "les timers survivent a la mort du joueur")

Mock.units.party1.combat = false
if retail then
    Mock.encounterInProgress = true
    Mock.Advance(5)
    equal(boss.engaged, 99100, "IsEncounterInProgress garde la rencontre engagee")
    Mock.encounterInProgress = false
end
Mock.Advance(4)
equal(boss.engaged, nil, "wipe : plus personne du groupe en combat")

-- Retour en combat : le ticker de wipe s'arrete.
Mock.FireCombatLog("SPELL_CAST_SUCCESS", DUNGEON_GUID, PLAYER_GUID, 55555)
Mock.FireEvent("PLAYER_REGEN_ENABLED")
Mock.Advance(1)
ok(boss.wipeSince ~= nil, "verification de wipe en cours")
Mock.FireEvent("PLAYER_REGEN_DISABLED")
equal(boss.wipeSince, nil, "retour en combat : verification annulee")
Mock.Advance(10)
equal(boss.engaged, 99100, "toujours engage")

-- Changement de zone : la rencontre ne peut pas continuer.
Mock.instance.instanceId = 901
Mock.FireEvent("ZONE_CHANGED_NEW_AREA")
equal(boss.engaged, nil, "disengage sur changement de zone")

Mock.units.party1 = nil
Mock.groupSize = 1
Mock.instance = { name = "Azshara", type = "none", difficulty = 0, instanceId = 0 }

--------------------------------------------------------------------------------

suite("BossTimer - world boss")
local WORLD_GUID  = "Creature-0-1-2-3-99001-000003"
local WORLD_GUID2 = "Creature-0-1-2-3-99002-000004"

-- Quelqu'un d'autre tape le boss : c'est deja un engage.
Mock.FireCombatLog("SWING_DAMAGE", "Player-0-7777", WORLD_GUID)
equal(boss.engaged, 99001, "world boss engage quand un autre joueur le tape")
equal(boss.kind, "world", "nature : world boss")
equal(boss.bossGUID, WORLD_GUID, "GUID pris sur la cible du coup")

-- Compte a rebours texte avant l'echeance.
Mock.Advance(5.1)
equal(bossDisplay.text:GetText(), "3", "compte a rebours : 3")
Mock.Advance(1)
equal(bossDisplay.text:GetText(), "2", "compte a rebours : 2")
Mock.Advance(1)
equal(bossDisplay.text:GetText(), "1", "compte a rebours : 1")
Mock.Advance(1.1)
equal(bossDisplay.text:GetText(), "Compte", "echeance : annonce du timer")
equal(CountFired("Compte"), 1, "timer declenche")

-- Emote du boss : phase 2, timer relatif a la phase, barre vers la phase 3.
Mock.FireEvent("CHAT_MSG_RAID_BOSS_EMOTE", "Le Conseil rugit de fureur !", "Conseil des Tests")
equal(boss.phase, 2, "emote : phase 2")
equal(phaseChanges[#phaseChanges], "2:emote", "raison : emote")
ok(generic:GetBar("t5") ~= nil, "timer PHASE de la phase 2 programme")
equal(generic:GetBar("t5").duration, 5, "duree relative a l'entree en phase 2")
ok(generic:GetBar("phase") ~= nil, "barre vers la phase 3")
equal(generic:GetBar("phase").duration, 30, "phase 3 dans 30s")
Mock.FireEvent("CHAT_MSG_RAID_BOSS_EMOTE", "Le Conseil rugit encore !", "Conseil des Tests")
equal(boss.phase, 2, "le meme emote ne rejoue pas la phase")
Mock.Advance(31)
equal(boss.phase, 3, "phase temporisee atteinte")
equal(phaseChanges[#phaseChanges], "3:time", "raison : delai")

-- Auras : sur toi, et sur n'importe qui.
Mock.FireCombatLog("SPELL_AURA_APPLIED", WORLD_GUID, PLAYER_GUID, 99010, "Marque", "DEBUFF")
equal(bossDisplay.text:GetText(), "Marque SUR TOI", "aura sur le joueur : SUR TOI")
Mock.Advance(2.5)
Mock.FireCombatLog("SPELL_AURA_APPLIED", WORLD_GUID, "Player-0-7777", 99011, "Bombe", "DEBUFF")
equal(bossDisplay.text:GetText(), "Bombe", "aura sur n'importe qui : annoncee")
equal(bossDisplay.subtitle:GetText(), "dst", "... avec le nom de la cible")

-- Mort d'un add.
Mock.FireCombatLog("UNIT_DIED", nil, "Creature-0-1-2-3-99020-000005")
equal(CountFired("Add mort"), 1, "trigger DEATH sur la mort d'un add")

-- Sortie de combat sur un world boss : delai de grace plus long.
Mock.FireEvent("PLAYER_REGEN_ENABLED")
Mock.Advance(4)
equal(boss.engaged, 99001, "world boss : toujours engage apres 4s hors combat")
Mock.units.player.combat = true
Mock.Advance(2)
Mock.units.player.combat = false
Mock.Advance(6)
equal(boss.engaged, 99001, "retour en combat : le compteur repart")
Mock.Advance(3)
equal(boss.engaged, nil, "wipe world boss apres le delai de grace")

-- Conseil : la rencontre ne finit qu'a la mort du dernier.
Mock.printed = {}
Mock.FireCombatLog("SPELL_CAST_SUCCESS", WORLD_GUID2, PLAYER_GUID, 55555)
equal(boss.engaged, 99001, "engage via un npcId secondaire")
Mock.FireCombatLog("UNIT_DIED", nil, WORLD_GUID2)
equal(boss.engaged, 99001, "un boss du conseil mort : toujours engage")
Mock.FireCombatLog("UNIT_DIED", nil, WORLD_GUID)
equal(boss.engaged, nil, "dernier boss mort : kill")
ok(Mock.FindPrinted("kill"), "resume de kill imprime")

-- Reset : un world boss qui ne fait plus rien a ete evade.
Mock.printed = {}
Mock.FireCombatLog("SPELL_CAST_SUCCESS", WORLD_GUID, PLAYER_GUID, 55555)
Mock.Advance(30)
Mock.FireCombatLog("SWING_DAMAGE", WORLD_GUID, PLAYER_GUID)
Mock.Advance(30)
equal(boss.engaged, 99001, "boss actif il y a 30s : toujours engage")
Mock.Advance(20)
equal(boss.engaged, nil, "boss inactif depuis 50s : reset")
ok(Mock.FindPrinted("reset"), "resume de reset imprime")

-- Phase forcee a la main.
Mock.FireCombatLog("SPELL_CAST_SUCCESS", WORLD_GUID, PLAYER_GUID, 55555)
SlashCmdList["MYBOSSSUITE"]("boss phase 2")
equal(boss.phase, 2, "/mbs boss phase <n>")
SlashCmdList["MYBOSSSUITE"]("boss phase 9")
equal(boss.phase, 2, "phase inconnue refusee")
boss:Disengage("manual")
equal(boss.engaged, nil, "disengage manuel")

if retail then
    -- Rencontre signalee par le client mais sans data : chrono quand meme.
    Mock.FireEvent("ENCOUNTER_START", 4242, "Inconnu", 1, 40)
    equal(boss.engaged, "encounter:4242", "rencontre sans data engagee")
    ok(boss.phaseFrame:IsShown(), "cadre affiche sans data")
    Mock.Advance(0.3)
    ok(boss.phaseFrame.title:GetText():find("Inconnu", 1, true) ~= nil, "cadre : nom de la rencontre")
    Mock.FireEvent("ENCOUNTER_END", 4242, "Inconnu", 1, 40, 0)
    equal(boss.engaged, nil, "fin de la rencontre sans data")
    equal(boss.phaseFrame:IsShown(), false, "cadre masque")

    -- ENCOUNTER_START non mappe, puis un boss connu qui agit : la rencontre
    -- generique cede la place a la data, sans perdre l'heure du pull.
    Mock.FireEvent("ENCOUNTER_START", 4243, "Conseil des Tests", 1, 40)
    equal(boss.engaged, "encounter:4243", "rencontre non mappee engagee en generique")
    Mock.Advance(2)
    Mock.FireCombatLog("SPELL_CAST_SUCCESS", WORLD_GUID, PLAYER_GUID, 55555)
    equal(boss.engaged, 99001, "montee en gamme vers la data au premier cast connu")
    equal(Mock.now - boss.pullTime, 2, "heure du pull conservee")
    ok(generic:GetBar("t1") ~= nil, "timers de la data lances")
    Mock.FireEvent("ENCOUNTER_END", 4243, "Conseil des Tests", 1, 40, 1)
    equal(boss.engaged, nil, "fin de rencontre")
end

--------------------------------------------------------------------------------

suite("Alertes")
-- Le boss timer et le swing timer pilotent aussi le combat log : on les eteint
-- pendant les trois suites d'alerte pour que chacune ne teste qu'elle-meme.
ns:SetModuleEnabled("bossTimer", false)
ns:SetModuleEnabled("swingTimer", false)

ok(ns.Alerts:Get("kick") ~= nil, "alerte kick declaree")
ok(ns.Alerts:Get("move") ~= nil, "alerte move declaree")
ok(ns.Alerts:Get("boss") ~= nil, "annonce boss declaree")
ok(ns.Anchors.registry["BossTimer_Display"] ~= nil, "annonce boss deplacable")
ok(ns.Anchors.registry["BossTimer_Phase"] ~= nil, "cadre de phase deplacable")
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

-- Data livree : elle ne tranche que sur le repli combat log, jamais contre
-- l'API du client.
equal(kick:CountData(), 1, "data des sorts interruptibles chargee")
ok(kick:IsKnownInterruptible(18435), "sort prouve interruptible par les logs")
equal(kick:IsKnownInterruptible(17086), nil, "sort absent de la data")

kick:GetConfig().dataOnly = true
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 17086, "Flame Breath")
equal(kickDisplay:IsShown(), false, "strict : un sort hors data ne declenche rien")
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 17086, "Flame Breath")
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
ok(kickDisplay:IsShown(), "strict : un sort prouve declenche l'alerte")
equal(kickDisplay.subtitle:GetText(), "Fireball Volley", "sort prouve : annonce sans reserve")
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")

kick:GetConfig().dataOnly = false
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 17086, "Flame Breath")
ok(kickDisplay:IsShown(), "hors strict : le sort inconnu s'annonce quand meme")
ok(kickDisplay.subtitle:GetText():find("(?)", 1, true) ~= nil,
    "... mais marque incertain, parce qu'il l'est")
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 17086, "Flame Breath")

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

-- Data livree : la preuve statistique est deja faite, donc premier coup, degats
-- directs compris, et sans passer par le seuil.
equal(move:CountData(), 1, "data des zones chargee")
ok(move:IsListed(22274), "zone livree reconnue")
equal(move:IsKnown(22274), false, "... sans etre inscrite dans ton profil")
Mock.FireCombatLog("SPELL_DAMAGE", BOSS_GUID, PLAYER_GUID, 22274, "Fire Wall", 1, 1)
ok(moveDisplay:IsShown(), "zone livree : alerte des le premier coup direct")
Mock.Advance(3)

-- Ton choix prime sur la data livree.
move:Ignore(22274)
Mock.FireCombatLog("SPELL_DAMAGE", BOSS_GUID, PLAYER_GUID, 22274, "Fire Wall", 1, 20)
equal(moveDisplay:IsShown(), false, "un sort ignore le reste malgre la data")
move:Unignore(22274)

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
equal(boss.phase, 1, "test : phase 1")
ok(boss.phaseFrame:IsShown(), "test : cadre de phase affiche")
Mock.Advance(21)
equal(boss.phase, 2, "test : la phase 2 est rejouee a son testTime")
ns.Config:StopTest()
equal(boss.testing, false, "test boss arrete")
equal(boss.phase, nil, "test : phase effacee")
equal(boss.phaseFrame:IsShown(), false, "test : cadre masque")

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
SlashCmdList["MYBOSSSUITE"]("kick strict on")
equal(ns:GetModule("interruptAlert"):GetConfig().dataOnly, true, "/mbs kick strict on")
SlashCmdList["MYBOSSSUITE"]("kick strict off")

Mock.printed = {}
SlashCmdList["MYBOSSSUITE"]("boss list")
ok(Mock.FindPrinted("Onyxia"), "/mbs boss list affiche les rencontres")
ok(Mock.FindPrinted("world boss"), "/mbs boss list groupe par nature")
Mock.printed = {}
SlashCmdList["MYBOSSSUITE"]("boss list donjon")
ok(Mock.FindPrinted("Herod"), "/mbs boss list donjon")
equal(Mock.FindPrinted("Onyxia"), nil, "... sans les raids")
SlashCmdList["MYBOSSSUITE"]("boss annonces off")
equal(ns:GetModule("bossTimer"):GetConfig().announce, false, "/mbs boss annonces off")
SlashCmdList["MYBOSSSUITE"]("boss annonces on")
SlashCmdList["MYBOSSSUITE"]("boss cadre off")
equal(ns:GetModule("bossTimer"):GetConfig().phaseFrame, false, "/mbs boss cadre off")
SlashCmdList["MYBOSSSUITE"]("boss cadre on")
Mock.printed = {}
SlashCmdList["MYBOSSSUITE"]("boss")
ok(Mock.FindPrinted("aucune rencontre"), "/mbs boss status")

Mock.printed = {}
SlashCmdList["MYBOSSSUITE"]("kick data")
ok(Mock.FindPrinted("Fireball Volley"), "/mbs kick data liste la data livree")
SlashCmdList["MYBOSSSUITE"]("move data")
ok(Mock.FindPrinted("Fire Wall"), "/mbs move data liste la data livree")

--------------------------------------------------------------------------------

say(("\n%d ok, %d echec(s)"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
