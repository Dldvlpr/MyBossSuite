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
    "Core/Comm.lua",
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
    "Modules/CDTracker/CDTracker.lua",
    "Modules/InterruptRotation/InterruptRotation.lua",
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

-- Incantations : meme forme de sortie quel que soit le nombre de valeurs
-- rendues par le client. Classic Era n'a pas `notInterruptible`, et le spellId
-- occupe alors la case du booleen.
Mock.SetCast("target", 17086, true)
local castName, _, _, _, castProtected, castSpell = ns.GetCastInfo("target")
equal(castName, "Flame Breath", "GetCastInfo : nom")
equal(castProtected, true, "GetCastInfo : cast protege")
equal(castSpell, 17086, "GetCastInfo : spellId")
Mock.legacyCastInfo = true
castName, _, _, _, castProtected, castSpell = ns.GetCastInfo("target")
equal(castProtected, false, "forme Classic Era : sans notInterruptible, lu interruptible")
equal(castSpell, 17086, "forme Classic Era : spellId retrouve malgre le decalage")
Mock.SetCast("target", 18435, false, true)
local chanName, _, _, _, _, chanSpell, isChannel = ns.GetCastInfo("target")
equal(chanName, "Fireball Volley", "GetCastInfo : channel")
equal(chanSpell, 18435, "forme Classic Era : spellId d'un channel retrouve")
equal(isChannel, true, "GetCastInfo : channel signale")
Mock.legacyCastInfo = false
Mock.SetCast("target", nil)

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

suite("EventBus")
local calls = {}
local function Broken() calls[#calls + 1] = "broken"; error("boom") end
local function Healthy() calls[#calls + 1] = "healthy" end
ns.EventBus:RegisterEvent("PLAYER_ALIVE", Broken)
ns.EventBus:RegisterEvent("PLAYER_ALIVE", Healthy)
Mock.printed = {}
Mock.FireEvent("PLAYER_ALIVE")
equal(#calls, 2, "une erreur dans un handler n'empeche pas le suivant")
ok(Mock.FindPrinted("boom"), "l'erreur est signalee")
Mock.printed = {}
Mock.FireEvent("PLAYER_ALIVE")
equal(Mock.FindPrinted("boom"), nil, "... une seule fois par minute, pas a chaque event")
ns.EventBus:UnregisterEvent("PLAYER_ALIVE", Broken)

-- Un handler qui se retire pendant le dispatch : la liste en cours ne bouge
-- pas, les suivants tournent, et il ne tourne plus ensuite.
local selfRemoving
selfRemoving = function()
    calls[#calls + 1] = "self"
    ns.EventBus:UnregisterEvent("PLAYER_ALIVE", selfRemoving)
end
ns.EventBus:RegisterEvent("PLAYER_ALIVE", selfRemoving)
local function Last() calls[#calls + 1] = "last" end
ns.EventBus:RegisterEvent("PLAYER_ALIVE", Last)
calls = {}
Mock.FireEvent("PLAYER_ALIVE")
equal(table.concat(calls, ","), "healthy,self,last",
    "un handler qui se retire pendant le dispatch ne fait sauter personne")
calls = {}
Mock.FireEvent("PLAYER_ALIVE")
equal(table.concat(calls, ","), "healthy,last", "... et ne tourne plus ensuite")
ns.EventBus:UnregisterEvent("PLAYER_ALIVE", Healthy)
ns.EventBus:UnregisterEvent("PLAYER_ALIVE", Last)
equal(ns.EventBus.handlers["PLAYER_ALIVE"], nil, "event desinscrit quand plus personne n'ecoute")

-- Memes garanties sur le bus interne.
local got = 0
ns.EventBus:On("MBS_TEST_MSG", function() error("boom interne") end)
ns.EventBus:On("MBS_TEST_MSG", function() got = got + 1 end)
Mock.printed = {}
ns.EventBus:Fire("MBS_TEST_MSG")
equal(got, 1, "message interne : une erreur n'empeche pas le listener suivant")

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

-- Main gauche : la barre suit la main droite, un coup de main gauche ne la
-- relance pas (isOffHand = 21e argument de SWING_DAMAGE, 13e de SWING_MISSED).
Mock.FireCombatLog("SWING_DAMAGE", PLAYER_GUID, BOSS_GUID,
    100, 0, 1, 0, 0, 0, false, false, false, false)
playerBar = ns.Bars.groups["SwingTimer_Bar"]:GetBar("SwingTimer_Bar")
Mock.Advance(1)
local mainHandEnd = playerBar.endTime
Mock.FireCombatLog("SWING_DAMAGE", PLAYER_GUID, BOSS_GUID,
    50, 0, 1, 0, 0, 0, false, false, false, true)
equal(playerBar.endTime, mainHandEnd, "SWING_DAMAGE main gauche : barre main droite intacte")
Mock.FireCombatLog("SWING_MISSED", PLAYER_GUID, BOSS_GUID, "DODGE", true)
equal(playerBar.endTime, mainHandEnd, "SWING_MISSED main gauche : barre main droite intacte")
Mock.FireCombatLog("SWING_MISSED", PLAYER_GUID, BOSS_GUID, "DODGE", false)
ok(playerBar.endTime > mainHandEnd, "SWING_MISSED main droite : barre relancee")

--------------------------------------------------------------------------------

suite("BossTimer")
local boss = ns:GetModule("bossTimer")
equal(boss:CountData(), 6, "data chargee (Onyxia, Kazzak, Herod + 3 fixtures)")
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
Mock.groupSize = 5
Mock.units.party1 = { guid = "Player-0-0002", name = "Tank" }
Mock.FireEvent("PLAYER_REGEN_ENABLED")
Mock.Advance(1)
equal(boss.engaged, 10184, "hors combat : toujours engage tant que le boss vient d'agir")
if retail then
    Mock.FireEvent("ENCOUNTER_END", 1084, "Onyxia", 1, 40, 1)
    equal(boss.engaged, nil, "disengage sur ENCOUNTER_END")
    ok(Mock.FindPrinted("kill"), "resume de kill imprime")
else
    Mock.Advance(16)
    equal(boss.engaged, nil, "wipe : personne en combat et boss muet")
    ok(Mock.FindPrinted("wipe"), "resume de wipe imprime")
    ok(Mock.FindPrinted("phase 3/3"), "resume : phase atteinte")
end
Mock.units.party1 = nil
Mock.groupSize = 0
equal(generic:Count(), 0, "barres nettoyees")
equal(boss.phaseFrame:IsShown(), false, "cadre de phase masque")
local leftovers = 0
for key in pairs(ns.Scheduler.active) do
    if key:sub(1, 10) == "BossTimer_" then leftovers = leftovers + 1 end
end
equal(leftovers, 0, "aucun timer du pull precedent ne survit")

-- Sortie de combat du joueur != fin du combat.
local function EngageOnyxia()
    if retail then
        Mock.FireEvent("ENCOUNTER_START", 1084, "Onyxia", 1, 40)
    else
        Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 12345)
    end
end
Mock.units.target.health = 100
Mock.groupSize, Mock.inRaid = 5, false
Mock.units.party1 = { guid = "Player-0-0002", name = "Tank", combat = true }
Mock.FireEvent("PLAYER_REGEN_DISABLED")
EngageOnyxia()
equal(boss.engaged, 10184, "re-engage pour le test de mort")
Mock.units.player.dead = true
Mock.FireEvent("PLAYER_REGEN_ENABLED")
equal(boss.engaged, 10184, "mort du joueur en groupe : le pull reste engage")
ok(generic:GetBar("t1") ~= nil, "... et les barres survivent")
local firedBefore = #firedTimers
Mock.Advance(12.5)
ok(#firedTimers > firedBefore, "les timers continuent de tirer pendant que le joueur est mort")
Mock.units.party1.dead, Mock.units.party1.combat = true, false
Mock.Advance(2.5)
equal(boss.engaged, nil, "wipe (plus personne de vivant) : disengage")
equal(generic:Count(), 0, "wipe : barres nettoyees")

-- Feign death / kite : le groupe se bat encore, on garde. Boss reset : plus
-- personne en combat et boss muet, on lache apres delai.
Mock.units.player.dead = nil
Mock.units.party1 = { guid = "Player-0-0002", name = "Tank", combat = true }
Mock.FireEvent("PLAYER_REGEN_DISABLED")
EngageOnyxia()
Mock.FireEvent("PLAYER_REGEN_ENABLED")
equal(boss.engaged, 10184, "feign death : le pull reste engage tant que le groupe se bat")
Mock.units.party1.combat = false
Mock.Advance(4)
equal(boss.engaged, 10184, "boss actif il y a peu : on ne conclut pas encore")
Mock.Advance(14)
equal(boss.engaged, nil, "boss muet depuis 15 s et personne en combat : reset detecte")

-- De retour en combat : le check s'arrete, le pull tient jusqu'a la mort du boss.
Mock.units.party1.combat = true
Mock.FireEvent("PLAYER_REGEN_DISABLED")
EngageOnyxia()
Mock.FireEvent("PLAYER_REGEN_ENABLED")
Mock.FireEvent("PLAYER_REGEN_DISABLED")
Mock.units.party1.combat = false
Mock.Advance(20)
equal(boss.engaged, 10184, "retour en combat : plus de check, le pull tient")
Mock.FireCombatLog("UNIT_DIED", nil, BOSS_GUID)
equal(boss.engaged, nil, "mort du boss : disengage immediat")

-- Solo : sortir de combat, c'est la fin.
Mock.groupSize = 0
Mock.units.party1 = nil
Mock.FireEvent("PLAYER_REGEN_DISABLED")
EngageOnyxia()
Mock.FireEvent("PLAYER_REGEN_ENABLED")
equal(boss.engaged, nil, "solo : sortie de combat = disengage")

if retail then
    -- ENCOUNTER_START ne donne pas de GUID : les frames boss le fournissent...
    Mock.units.target = nil
    Mock.units.boss1 = { guid = BOSS_GUID, name = "Onyxia", health = 100, healthMax = 100 }
    Mock.FireEvent("PLAYER_REGEN_DISABLED")
    Mock.FireEvent("ENCOUNTER_START", 1084, "Onyxia", 1, 40)
    equal(boss.bossGUID, BOSS_GUID, "ENCOUNTER_START : GUID resolu via boss1")
    equal(swing.lockedToBoss, true, "le swing timer se verrouille sur le boss")
    Mock.FireEvent("ENCOUNTER_END", 1084, "Onyxia", 1, 40, 0)
    Mock.units.boss1 = nil
    -- ... ou le combat log, apres coup.
    Mock.FireEvent("ENCOUNTER_START", 1084, "Onyxia", 1, 40)
    equal(boss.bossGUID, nil, "aucune unite visible : engage sans GUID")
    equal(swing.lockedToBoss, false, "sans GUID, le swing timer ne se verrouille pas encore")
    Mock.FireCombatLog("SWING_DAMAGE", BOSS_GUID, PLAYER_GUID, 100)
    equal(boss.bossGUID, BOSS_GUID, "premier event du boss : GUID identifie")
    equal(swing.lockedToBoss, true, "BOSS_IDENTIFIED : le swing timer se verrouille")
    Mock.FireEvent("ENCOUNTER_END", 1084, "Onyxia", 1, 40, 0)
    Mock.units.target = { guid = BOSS_GUID, name = "Onyxia", health = 100, healthMax = 100 }
end

-- Ancre dediee par sort : ses barres quittent l'ancre generique.
SlashCmdList["MYBOSSSUITE"]("anchor 17086")
ok(ns.db.anchors["BossTimer_Alert_17086"] ~= nil, "/mbs anchor <spellId> cree et sauvegarde l'ancre")
equal(ns:ResolveAnchorKey(17086), "BossTimer_Alert_17086", "ResolveAnchorKey route vers l'ancre dediee")
Mock.FireEvent("PLAYER_REGEN_DISABLED")
EngageOnyxia()
equal(generic:GetBar("t1"), nil, "la barre du sort n'est plus sur l'ancre generique")
ok(ns.Bars.groups["BossTimer_Alert_17086"]:GetBar("t1") ~= nil, "... elle est sur l'ancre dediee")
boss:Disengage()
SlashCmdList["MYBOSSSUITE"]("anchor remove 17086")
equal(ns:ResolveAnchorKey(17086), "BossTimer_GenericBar", "/mbs anchor remove : retour a l'ancre generique")
equal(ns.Anchors.registry["BossTimer_Alert_17086"], nil, "ancre retiree du registre")

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
equal(boss.engaged, 99100, "personne en combat mais boss actif il y a peu : on attend")
Mock.Advance(12)
equal(boss.engaged, nil, "wipe : personne en combat et boss muet")
-- Tout le monde mort : wipe sans attendre le silence du boss.
Mock.FireCombatLog("SPELL_CAST_SUCCESS", DUNGEON_GUID, PLAYER_GUID, 55555)
Mock.units.player.dead, Mock.units.party1.dead = true, true
Mock.FireEvent("PLAYER_REGEN_ENABLED")
Mock.Advance(1.5)
equal(boss.engaged, nil, "tout le monde mort : wipe immediat")
Mock.units.player.dead, Mock.units.party1.dead = nil, nil
Mock.units.party1.combat = true

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
Mock.groupSize = 0
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
Mock.Advance(6)
equal(boss.engaged, nil, "wipe world boss : delai de grace passe et boss muet")

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

suite("BossTimer - sorts sans horaire")
-- Tous les sorts ne tombent pas a heure fixe : certains sont disponibles et
-- partent quand le boss le decide. Compter vers une mediane afficherait une
-- precision qu'on n'a pas ; ce qui est vrai, c'est le cast, et c'est lui qui
-- doit se voir au moment ou le boss le lance.
Mock.instance = { name = "Terrain d'essai", type = "party", difficulty = 1, instanceId = 900 }
local CASTER_GUID = "Creature-0-1-2-3-99200-000006"

Mock.FireCombatLog("SPELL_CAST_SUCCESS", CASTER_GUID, PLAYER_GUID, 55555)
equal(boss.engaged, 99200, "boss engage")
equal(generic:GetBar("t1"), nil, "un sort sans horaire n'affiche rien avant d'etre lance")

-- Le boss commence a incanter : la barre part, et dure ce que dure le sort.
Mock.FireCombatLog("SPELL_CAST_START", CASTER_GUID, PLAYER_GUID, 99210)
ok(generic:GetBar("t1_cast") ~= nil, "barre d'incantation au debut du cast")
equal(generic:GetBar("t1_cast").duration, 5, "duree = `castTime` de la data")
equal(CountFired("Incantation"), 1, "et le timer se declenche au cast")

-- Le sort part : l'incantation est finie, la barre n'a plus rien a montrer.
Mock.Advance(1)
Mock.FireCombatLog("SPELL_CAST_SUCCESS", CASTER_GUID, PLAYER_GUID, 99210)
equal(generic:GetBar("t1_cast"), nil, "barre coupee quand le sort part")
equal(CountFired("Incantation"), 1, "et pas de second declenchement sur SUCCESS")

-- Quand le client sait lire l'unite du boss, c'est lui qui fait foi : la data
-- n'est qu'un filet pour les clients qui ne repondent pas.
Mock.units.target = { guid = CASTER_GUID, name = "Incantateur des Tests",
                      health = 100, healthMax = 100 }
Mock.SetCast("target", 99210)
Mock.FireCombatLog("SPELL_CAST_START", CASTER_GUID, PLAYER_GUID, 99210)
equal(generic:GetBar("t1_cast").duration, 2, "duree lue sur l'unite du boss")
Mock.SetCast("target", nil)
Mock.FireCombatLog("SPELL_CAST_SUCCESS", CASTER_GUID, PLAYER_GUID, 99210)

-- Un timing `variable` : la barre reste un reperage. Son echeance n'annonce
-- rien — annoncer la, ce serait affirmer une heure qu'on ne connait pas.
Mock.printed = {}
bossDisplay:Hide()
local before = #firedTimers
Mock.Advance(20)
equal(bossDisplay:IsShown(), false, "echeance d'un timing variable : aucune annonce")
equal(#firedTimers, before + 1, "le timer a bien atteint son echeance")

-- ... mais le cast observe, lui, s'annonce : c'est la seule chose vraie qu'on
-- puisse dire d'un sort non deterministe.
Mock.FireCombatLog("SPELL_CAST_SUCCESS", CASTER_GUID, PLAYER_GUID, 99211)
ok(bossDisplay:IsShown(), "cast observe d'un sort variable : annonce")
equal(bossDisplay.text:GetText(), "Aleatoire", "... sous son propre libelle")
equal(CountFired("Aleatoire"), 2, "et le timer se declenche sur l'observation")

Mock.instance = { name = "Azshara", type = "none", difficulty = 0, instanceId = 0 }
Mock.FireEvent("ZONE_CHANGED_NEW_AREA")
Mock.units.target = nil
equal(boss.engaged, nil, "disengage")
equal(generic:Count(), 0, "barres nettoyees, incantation comprise")

--------------------------------------------------------------------------------

suite("Synchronisation")
Mock.groupSize = 5
Mock.units.target = { guid = BOSS_GUID, name = "Onyxia", health = 100, healthMax = 100 }
Mock.addonMessages = {}

-- Engage local : le groupe est prevenu, avec l'heure du pull et la phase.
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 12345)
equal(boss.engaged, 10184, "engage local")
local last = Mock.LastAddonMessage()
ok(last ~= nil and last.prefix == "MBS", "engage : message addon envoye")
equal(last and last.message, "1\tPULL\t10184\t0\t1\t0", "PULL avec l'heure du pull et la phase")
equal(last and last.channel, "PARTY", "canal du groupe")

-- Un pair a vu le pull 4 s avant nous : on adopte son heure.
Mock.Advance(2)
local remainingBefore = generic:GetBar("t1"):GetRemaining()
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tPULL\t10184\t6\t1\t6", "PARTY", "Autre-Mock")
equal(Mock.now - boss.pullTime, 6, "heure du pull du pair adoptee")
equal(generic:GetBar("t1"):GetRemaining(), remainingBefore - 4, "timer PULL rapproche d'autant")
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tPULL\t10184\t7\t1\t7", "PARTY", "Autre-Mock")
equal(Mock.now - boss.pullTime, 6, "ecart sous la tolerance ignore")
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tPULL\t10184\t1\t1\t1", "PARTY", "Autre-Mock")
equal(Mock.now - boss.pullTime, 6, "un pull plus tardif ne fait pas reculer le notre")

-- Phase recue d'un pair : appliquee, sans echo.
local sentBefore = #Mock.addonMessages
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tPHASE\t10184\t2\t3", "PARTY", "Autre-Mock")
equal(boss.phase, 2, "phase recue appliquee")
equal(Mock.now - boss.phaseTime, 3, "heure d'entree de phase du pair adoptee")
equal(generic:GetBar("t1"), nil, "timers de phase 1 coupes")
equal(#Mock.addonMessages, sentBefore, "phase synchronisee : pas d'echo")
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tPHASE\t10184\t1\t0", "PARTY", "Autre-Mock")
equal(boss.phase, 2, "retour en arriere sur un seuil de vie refuse")

-- Phase detectee localement : diffusee.
Mock.units.target.health = 35
Mock.Advance(1)
equal(boss.phase, 3, "phase 3 detectee localement")
last = Mock.LastAddonMessage()
equal(last and last.message, "1\tPHASE\t10184\t3\t0", "changement de phase local diffuse")

-- Demande d'etat : on repond, sauf si quelqu'un vient de le faire.
Mock.addonMessages = {}
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tREQ", "PARTY", "Nouveau-Mock")
Mock.Advance(2.1)
last = Mock.LastAddonMessage()
ok(last ~= nil and last.message:find("^1\tPULL\t10184\t") ~= nil, "reponse PULL a une demande d'etat")
Mock.addonMessages = {}
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", ("1\tPULL\t10184\t%d\t3\t0"):format(Mock.now - boss.pullTime),
    "PARTY", "Autre-Mock")
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tREQ", "PARTY", "Nouveau-Mock")
Mock.Advance(0.1)
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", ("1\tPULL\t10184\t%d\t3\t0"):format(Mock.now - boss.pullTime),
    "PARTY", "Autre-Mock")
Mock.Advance(2.1)
equal(#Mock.addonMessages, 0, "un pair a repondu entre-temps : silence")

-- Ce qui doit etre ignore : soi-meme, une autre version, un autre prefixe.
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tEND\t10184\tkill", "PARTY", "Testeur-Mock")
equal(boss.engaged, 10184, "ses propres messages sont ignores")
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "2\tEND\t10184\tkill", "PARTY", "Autre-Mock")
equal(boss.engaged, 10184, "autre version de protocole ignoree")
Mock.FireEvent("CHAT_MSG_ADDON", "DBMv4", "1\tEND\t10184\tkill", "PARTY", "Autre-Mock")
equal(boss.engaged, 10184, "autre prefixe ignore")
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tEND\t99001\tkill", "PARTY", "Autre-Mock")
equal(boss.engaged, 10184, "kill d'un autre boss ignore")

-- Kill vu par un pair hors de notre portee de combat log.
Mock.printed = {}
Mock.addonMessages = {}
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tEND\t10184\tkill", "PARTY", "Autre-Mock")
equal(boss.engaged, nil, "kill recu : rencontre terminee")
ok(Mock.FindPrinted("kill"), "resume de kill")
equal(#Mock.addonMessages, 0, "kill synchronise : pas d'echo")

-- Arrivee en cours de combat : engage sans le moindre event de combat log.
Mock.addonMessages = {}
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tPULL\t10184\t30\t2\t5", "PARTY", "Autre-Mock")
equal(boss.engaged, 10184, "engage par synchronisation")
equal(Mock.now - boss.pullTime, 30, "heure du pull du pair")
equal(boss.phase, 2, "phase du pair")
equal(Mock.now - boss.phaseTime, 5, "heure d'entree de phase du pair")
equal(generic:GetBar("t1"), nil, "timer de phase 1 absent en phase 2")
ok(boss.phaseFrame:IsShown(), "cadre affiche")
equal(#Mock.addonMessages, 0, "engage synchronise : pas d'echo")

-- Kill local : diffuse.
Mock.FireCombatLog("UNIT_DIED", nil, BOSS_GUID)
equal(boss.engaged, nil, "kill local")
last = Mock.LastAddonMessage()
equal(last and last.message, "1\tEND\t10184\tkill", "kill local diffuse")

-- Timer repetitif recale sur le bon cycle : pull il y a 30 s, Flame Breath a
-- 12 puis toutes les 25 s -> prochaine occurrence a 37 s, dans 7 s.
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tPULL\t10184\t30\t1\t30", "PARTY", "Autre-Mock")
equal(boss.phase, 1, "phase 1 du pair")
equal(generic:GetBar("t1"):GetRemaining(), 7, "timer repetitif recale sur le bon cycle")
boss:Disengage("manual")

-- Solo : rien a envoyer, et rien ne casse.
Mock.groupSize = 0
Mock.addonMessages = {}
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 12345)
equal(boss.engaged, 10184, "engage solo")
equal(#Mock.addonMessages, 0, "solo : aucun message")
boss:Disengage("manual")

-- Synchronisation coupee : ni envoi ni reception.
Mock.groupSize = 5
boss:GetConfig().sync = false
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tPULL\t10184\t30\t1\t30", "PARTY", "Autre-Mock")
equal(boss.engaged, nil, "sync off : PULL ignore")
Mock.addonMessages = {}
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 12345)
equal(#Mock.addonMessages, 0, "sync off : rien envoye")
boss:Disengage("manual")
boss:GetConfig().sync = true

-- Arrivee dans un groupe : demande d'etat.
Mock.addonMessages = {}
Mock.FireEvent("GROUP_ROSTER_UPDATE")
Mock.Advance(1.5)
last = Mock.LastAddonMessage()
equal(last and last.message, "1\tREQ", "demande d'etat a l'arrivee dans un groupe")
Mock.FireEvent("GROUP_ROSTER_UPDATE")
Mock.Advance(1.5)
equal(#Mock.addonMessages, 1, "demande d'etat limitee dans le temps")
Mock.groupSize = 0
Mock.units.target = nil

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

-- Cast annule sans trace dans le combat log (stun, mort de la cible) :
-- SPELL_CAST_FAILED n'est jamais logge pour un PNJ, seul le client le voit.
Mock.SetCast("target", 18435, false)
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
Mock.FireEvent("UNIT_SPELLCAST_START", "target")
ok(kickDisplay:IsShown(), "cast vu par l'API et par le combat log : alerte")
Mock.SetCast("target", nil)
Mock.FireEvent("UNIT_SPELLCAST_INTERRUPTED", "target")
equal(kickDisplay:IsShown(), false, "cast annule cote client : pas d'incantation fantome via le repli")
Mock.Advance(0.5)
equal(kickDisplay:IsShown(), false, "... et le ticker ne la ressort pas")

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

-- Coup entierement absorbe : SPELL_ABSORBED remplace SPELL_DAMAGE. Une zone de
-- la liste alerte quand meme ; un sort inconnu n'a pas d'heuristique possible.
Mock.FireCombatLog("SPELL_ABSORBED", BOSS_GUID, PLAYER_GUID, 22273, "Cleave", 1,
    PLAYER_GUID, "Testeur", 0, 0, 17, "Power Word: Shield", 2, 30)
ok(moveDisplay:IsShown(), "sort de la liste absorbe par un bouclier : alerte quand meme")
Mock.Advance(3)
Mock.FireCombatLog("SPELL_ABSORBED", BOSS_GUID, PLAYER_GUID, 22278, "Inconnu", 1,
    PLAYER_GUID, "Testeur", 0, 0, 17, "Power Word: Shield", 2, 30)
equal(moveDisplay:IsShown(), false, "sort inconnu absorbe : aucune alerte")
Mock.FireCombatLog("SPELL_ABSORBED", BOSS_GUID, PLAYER_GUID,
    PLAYER_GUID, "Testeur", 0, 0, 17, "Power Word: Shield", 2, 30)
equal(moveDisplay:IsShown(), false, "coup blanc absorbe (signature sans sort) : ignore")

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

-- Hors combat il n'y a pas de cast a observer : la barre d'incantation doit
-- quand meme etre rejouee, sinon le seul affichage d'un sort sans horaire
-- manquerait au test.
boss:TestBoss(99200)
Mock.Advance(1.2)
ok(generic:GetBar("t1_cast") ~= nil, "test : la barre d'incantation est rejouee")
equal(generic:GetBar("t1_cast").duration, 5, "test : sur la duree de `castTime`")
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
SlashCmdList["MYBOSSSUITE"]("boss sync off")
equal(ns:GetModule("bossTimer"):GetConfig().sync, false, "/mbs boss sync off")
SlashCmdList["MYBOSSSUITE"]("boss sync on")
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

suite("CD Tracker")

-- Le module repose sur un principe simple : chaque client connait SON cooldown
-- exactement, et l'annonce. Ce qui merite d'etre teste, c'est ce qui distingue
-- une information sue d'une information supposee — parce que designer un joueur
-- dont on croit a tort que le kick est pret est le bug qui tue le module, et la
-- rotation d'interrupt qui s'appuie dessus.

local cd = ns:GetModule("cdTracker")
local ME = "Testeur"
local KICK = 1766

Mock.groupSize = 3
Mock.inRaid = false
Mock.units.party1 = { guid = "Player-0-0002", name = "Tank" }
Mock.units.party2 = { guid = "Player-0-0003", name = "Heal" }
ns:SetModuleEnabled("cdTracker", true)
Mock.Advance(4)   -- l'annonce d'arrivee part avec un decalage aleatoire
                  -- (jusqu'a 3 s) : on la laisse passer avant de mesurer.

-- Le voleur mock ne connait que Kick : c'est le seul sort suivi, et il vient de
-- la liste d'interrupts deja curee, pas d'une table a maintenir.
local mine = cd:MySpells()
equal(#mine, 1, "un seul sort suivi (le mock ne connait que Kick)")
equal(mine[1].spellId, KICK, "et c'est Kick")
equal(mine[1].kind, "interrupt", "classe comme interrupt")

--- Cooldown propre : lu directement, exact, sans reseau.
Mock.cooldowns[KICK] = { start = Mock.now, duration = 15 }
local remaining, duration = cd:ReadOwn(KICK, "interrupt")
equal(remaining, 15, "son propre cooldown est lu exactement")
equal(duration, 15, "avec sa duree")
equal(cd:Remaining(ME, KICK), 15, "et retenu")
ok(cd:GetGroup():GetBar(ME .. "|" .. KICK) ~= nil, "une barre est affichee")

--- Le GCD n'est pas un cooldown : l'annoncer ferait clignoter la liste a chaque
-- sort lance.
Mock.cooldowns[KICK] = { start = Mock.now, duration = 1.5 }
equal(cd:ReadOwn(KICK, "interrupt"), 0, "le GCD n'est pas compte comme cooldown")
equal(cd:Remaining(ME, KICK), nil, "et n'entre pas dans le magasin")
Mock.cooldowns[KICK] = nil

--- Diffusion : on ecoute SPELL_CAST_SUCCESS, pas SPELL_INTERRUPT. Un kick lance
-- dans le vide part quand meme en cooldown mais ne genere aucun SPELL_INTERRUPT.
Mock.addonMessages = {}
Mock.cooldowns[KICK] = { start = Mock.now, duration = 15 }
Mock.FireCombatLog("SPELL_CAST_SUCCESS", PLAYER_GUID, BOSS_GUID, KICK)
Mock.Advance(0.5)
local sent = Mock.LastAddonMessage()
ok(sent ~= nil and sent.message:find("\tCD\t" .. KICK .. "\t", 1, true) ~= nil,
    "un cast de Kick est annonce au groupe")
ok(sent ~= nil and sent.message:find("\t15\t15\t", 1, true) ~= nil,
    "avec le restant et la duree mesures")

--- Un sort qu'on ne suit pas ne declenche rien.
Mock.addonMessages = {}
Mock.FireCombatLog("SPELL_CAST_SUCCESS", PLAYER_GUID, BOSS_GUID, 17086)
Mock.Advance(0.5)
equal(#Mock.addonMessages, 0, "un sort non suivi n'est pas annonce")

--- Reception : le cooldown d'un pair est exact, il vient de lui.
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCD\t" .. KICK .. "\t12\t15\tinterrupt",
    "PARTY", "Tank")
equal(cd:Remaining("Tank", KICK), 12, "le cooldown annonce par un pair est retenu")
ok(cd:Knows("Tank", KICK), "et on sait desormais qu'il possede ce sort")
ok(cd:GetGroup():GetBar("Tank|" .. KICK) ~= nil, "avec sa barre")

-- Le meme joueur n'a pas forcement le meme nom des deux cotes : l'expediteur
-- d'un message addon arrive parfois avec son royaume la ou le roster n'en rend
-- aucun. Deux orthographes, ce serait deux entrees, une barre en double, et un
-- joueur qu'on croit sans kick alors qu'il vient de l'annoncer.
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCD\t" .. KICK .. "\t7\t15\tinterrupt",
    "PARTY", "Tank-Royaume")
equal(cd:Remaining("Tank", KICK), 7,
    "un expediteur avec royaume est recolle sur le joueur du roster")
equal(cd:Remaining("Tank-Royaume", KICK), nil, "et ne cree pas de doublon")

--- Hierarchie des sources : une estimation ne parle pas par-dessus une mesure.
equal(cd:Record("Tank", KICK, 30, 30, "static"), false,
    "une estimation n'ecrase pas un cooldown annonce par son proprietaire")
equal(cd:Remaining("Tank", KICK), 7, "la valeur exacte tient")
equal(cd:Record("Tank", KICK, 8, 15, "mbs"), true,
    "mais le proprietaire peut se corriger lui-meme")
equal(cd:Remaining("Tank", KICK), 8, "et c'est sa nouvelle valeur qui compte")

--- Une fois la valeur sure expiree, l'estimation reprend la main.
Mock.Advance(9)
equal(cd:Remaining("Tank", KICK), nil, "un cooldown expire quitte le magasin")
equal(cd:Record("Tank", KICK, 30, 30, "static"), true,
    "plus rien de sur en face : l'estimation est acceptee")
local estimated = cd:GetGroup():GetBar("Tank|" .. KICK)
ok(estimated ~= nil and estimated.variable == true,
    "et s'affiche comme estimee (grisee, prefixee ~)")

--- « Pret » et « je ne sais pas » ne sont pas la meme chose. C'est toute la
-- difference entre une rotation qui marche et une rotation qui envoie un joueur
-- sans kick.
cd:Record("Tank", KICK, 0, 0, "mbs")
local ready = cd:ReadyUnits(KICK)
local readySet = {}
for i = 1, #ready do readySet[ready[i]] = true end
ok(readySet["Tank"] == true, "un pair dont le kick est revenu est pret")
ok(readySet["Heal-Mock"] == nil, "un joueur dont on ne sait rien n'est PAS compte pret")

Mock.cooldowns[KICK] = { start = Mock.now, duration = 15 }
cd:ReadOwn(KICK, "interrupt")
ready = cd:ReadyUnits(KICK)
readySet = {}
for i = 1, #ready do readySet[ready[i]] = true end
ok(readySet[ME] == nil, "soi-meme en cooldown n'est pas compte pret")
Mock.cooldowns[KICK] = nil
cd:ReadOwn(KICK, "interrupt")
ok(cd:Remaining(ME, KICK) == nil, "cooldown fini : plus rien a afficher")

--- Une demande d'etat est honoree, mais pas deux fois de suite : sans throttle,
-- tout le raid repond dans la meme image a chaque arrivee.
Mock.addonMessages = {}
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCDREQ", "PARTY", "Nouveau-Mock")
Mock.Advance(3)
ok(#Mock.addonMessages > 0, "une demande d'etat obtient une reponse")
local answered = #Mock.addonMessages
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCDREQ", "PARTY", "Autre-Mock")
Mock.Advance(3)
equal(#Mock.addonMessages, answered, "une deuxieme demande immediate est ignoree")

--- Un joueur qui quitte le groupe est oublie : une barre qui continue a tourner
-- pour quelqu'un qui n'est plus la est un mensonge tranquille.
cd:Record("Tank", KICK, 20, 20, "mbs")
ok(cd:Remaining("Tank", KICK) ~= nil, "cooldown suivi avant le depart")
Mock.units.party1 = nil
Mock.units.party2 = nil
Mock.groupSize = 0
cd:PruneRoster()
equal(cd:Remaining("Tank", KICK), nil, "le partant est oublie")
equal(cd:GetGroup():GetBar("Tank|" .. KICK), nil, "et sa barre disparait")
ok(cd:Knows("Tank", KICK) == false, "on n'affirme plus rien sur lui")

--- LibOpenRaid : absente en classic, et le module doit le DIRE plutot que de
-- laisser croire a une couverture qu'il n'a pas.
local status = cd:Status()
equal(status.lib, false, "LibOpenRaid n'est pas active dans le mock")
ok(status.libWhy:find(retail and "non chargee" or "hors retail", 1, true) ~= nil,
    "et le statut dit pourquoi (" .. status.libWhy .. ")")

--- Lecture defensive de la lib : `docs.txt` se contredit sur l'ordre des
-- retours. Une valeur incoherente doit etre ignoree, pas affichee.
local fakeLib = {
    GetCooldownStatusFromCooldownInfo = function(info)
        return false, 0.5, info.timeLeft, 1, 0, 0, 0, info.duration
    end,
}
equal(cd:ReadLibCooldown(fakeLib, { timeLeft = 10, duration = 30 }), 10,
    "une lecture coherente est retenue")
equal(cd:ReadLibCooldown(fakeLib, { timeLeft = 99, duration = 30 }), nil,
    "un restant superieur a la duree est refuse")
equal(cd:ReadLibCooldown(fakeLib, { timeLeft = 10, duration = 0 }), nil,
    "une duree nulle est refusee")
local brokenLib = { GetCooldownStatusFromCooldownInfo = function() error("boom") end }
equal(cd:ReadLibCooldown(brokenLib, {}), nil, "une lib qui leve ne casse rien")

--- Commandes.
Mock.printed = {}
SlashCmdList["MYBOSSSUITE"]("cd")
ok(Mock.FindPrinted("CD Tracker"), "/mbs cd affiche l'etat")
ok(Mock.FindPrinted("LibOpenRaid"), "et dit ce qu'il en est de LibOpenRaid")
cd:Record("Tank", KICK, 11, 15, "mbs")
Mock.printed = {}
SlashCmdList["MYBOSSSUITE"]("cd list")
ok(Mock.FindPrinted("Kick"), "/mbs cd list liste les cooldowns connus")
SlashCmdList["MYBOSSSUITE"]("cd barres off")
equal(ns.db.modules.cdTracker.bars, false, "/mbs cd barres off")
equal(cd:GetGroup():Count(), 0, "les barres sont retirees")
SlashCmdList["MYBOSSSUITE"]("cd barres on")
equal(ns.db.modules.cdTracker.bars, true, "/mbs cd barres on")
ok(cd:GetGroup():Count() > 0, "et reviennent sans perdre l'etat suivi")

--- Desactivation complete : aucune barre, aucun handler, aucune trace.
ns:SetModuleEnabled("cdTracker", false)
equal(cd:GetGroup():Count(), 0, "module desactive : plus une barre")
equal(cd:Remaining("Tank", KICK), nil, "ni la moindre donnee retenue")
Mock.addonMessages = {}
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCD\t" .. KICK .. "\t12\t15", "PARTY", "Tank")
equal(cd:Remaining("Tank", KICK), nil, "et plus personne n'ecoute")
Mock.cooldowns[KICK] = nil

--------------------------------------------------------------------------------

suite("Rotation d'interrupt")

-- La rotation ne mesure rien : elle ordonne ce que le CD Tracker sait deja. Ce
-- qui merite d'etre teste, c'est donc ce qui separe une rotation utile d'une
-- rotation dangereuse : qui elle designe, qui elle refuse de designer, ce qui
-- fait tourner le tour — et ce qui NE le fait pas tourner.

local rot = ns:GetModule("interruptRotation")
local COUNTERSPELL = 2139

Mock.units.party1 = { guid = "Player-0-0002", name = "Tank" }
Mock.units.party2 = { guid = "Player-0-0003", name = "Heal" }
-- Un joueur sans addon : il ne dira jamais rien de son kick.
Mock.units.party3 = { guid = "Player-0-0004", name = "Muet" }
Mock.groupSize = 4
Mock.inRaid = false

ns:SetModuleEnabled("cdTracker", true)
ns:SetModuleEnabled("interruptRotation", true)
Mock.Advance(4)   -- l'annonce d'arrivee du CD Tracker part avec un decalage

Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCD\t" .. COUNTERSPELL .. "\t0\t0\tinterrupt",
    "PARTY", "Tank")
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCD\t" .. KICK .. "\t0\t0\tinterrupt",
    "PARTY", "Heal")

--- « Je ne sais pas » n'est pas « c'est pret » : un joueur muet n'entre pas dans
-- la file. Le designer serait le bug qui tue le module — l'interrupt passerait a
-- travers, et personne ne saurait pourquoi.
local order = rot:Order()
equal(#order, 3, "trois porteurs d'interrupt : le joueur muet n'en est pas")
equal(order[1].unit, "Heal", "l'ordre est alphabetique, donc identique sur tous les clients")
equal(order[3].unit, "Testeur", "et le joueur lui-meme en fait partie")
ok(rot:IsActive(), "deux porteurs suffisent a faire une rotation")

--- Le tour, et ce qu'il fait a l'alerte kick.
equal(rot:Designated().unit, "Heal", "le premier de la file prend le premier kick")
equal(rot:Holder("target|17086"), "Heal", "ce n'est pas ton tour : l'alerte doit se taire")

-- Mais pas indefiniment : le designe peut etre mort, silence ou hors de portee.
-- Un kick manque coute plus cher qu'un kick en double.
Mock.Advance(1.5)
equal(rot:Holder("target|17086"), nil,
    "l'incantation dure toujours : la rotation rend la main a tout le monde")
equal(rot:Holder("target|18435"), "Heal", "nouvelle incantation : l'attente repart de zero")

--- Ce qui fait tourner la file : SPELL_CAST_SUCCESS, et rien d'autre.
Mock.FireCombatLog("SPELL_CAST_SUCCESS", "Player-0-0003", BOSS_GUID, KICK)
equal(rot.lastCaster, "Heal", "un interrupt lance fait tourner la file")
equal(rot:Designated().unit, "Tank", "le tour passe au suivant")

-- Un kick lance dans le vide part en cooldown sans generer le moindre
-- SPELL_INTERRUPT : ecouter cet evenement-la designerait un joueur qui n'a plus
-- son kick.
Mock.FireCombatLog("SPELL_INTERRUPT", "Player-0-0002", BOSS_GUID, COUNTERSPELL)
equal(rot.lastCaster, "Heal", "SPELL_INTERRUPT ne fait rien tourner")
Mock.FireCombatLog("SPELL_CAST_SUCCESS", "Player-0-0002", BOSS_GUID, 17086)
equal(rot.lastCaster, "Heal", "un sort qui n'est pas un interrupt non plus")
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, KICK)
equal(rot.lastCaster, "Heal", "ni un cast venu de hors du groupe")

--- Un kick en cooldown est saute : la file designe qui peut, pas qui vient.
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCD\t" .. COUNTERSPELL .. "\t20\t24\tinterrupt",
    "PARTY", "Tank")
equal(rot:Designated().unit, "Testeur", "le suivant en cooldown est saute")
equal(rot:Holder("target|17086"), nil, "c'est ton tour : l'alerte reste franche")

--- Personne de pret : ca veut dire « debrouillez-vous », pas « attendez ».
Mock.cooldowns[KICK] = { start = Mock.now, duration = 15 }
cd:ReadOwn(KICK, "interrupt")
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCD\t" .. KICK .. "\t12\t15\tinterrupt",
    "PARTY", "Heal")
equal(rot:Designated(), nil, "aucun kick pret : la rotation ne designe personne")
equal(rot:Holder("target|17086"), nil, "... et ne fait donc taire personne")

Mock.cooldowns[KICK] = nil
cd:ReadOwn(KICK, "interrupt")
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCD\t" .. KICK .. "\t0\t0\tinterrupt",
    "PARTY", "Heal")
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCD\t" .. COUNTERSPELL .. "\t0\t0\tinterrupt",
    "PARTY", "Tank")
rot:Reset()

--- Ce que ca donne a l'ecran, avec le module d'alerte kick : le couplage ne va
-- que dans ce sens, et il ne remplace jamais l'alerte par du silence.
ns:SetModuleEnabled("interruptAlert", true)
Mock.units.target = { guid = BOSS_GUID, name = "Onyxia", health = 100, healthMax = 100 }
Mock.FireEvent("PLAYER_TARGET_CHANGED")
Mock.SetCast("target", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "target")
ok(kickDisplay:IsShown(), "incantation interruptible : l'alerte s'affiche quand meme")
equal(kickDisplay.text:GetText(), "ATTENDS", "mais elle dit d'attendre au lieu de crier KICK")
ok(kickDisplay.subtitle:GetText():find("Heal", 1, true) ~= nil,
    "et nomme celui a qui le kick revient")
Mock.Advance(1.5)
equal(kickDisplay.text:GetText(), "KICK",
    "le kick designe n'est pas parti : l'alerte redevient franche")

Mock.SetCast("target", nil)
Mock.FireEvent("UNIT_SPELLCAST_STOP", "target")
ns:SetModuleEnabled("interruptAlert", false)

--- Le cadre de file : en combat seulement, et remis a zero au wipe comme au kill.
equal(rot.listFrame:IsShown(), false, "hors combat, le cadre ne s'affiche pas")
Mock.units.player.combat = true
Mock.FireEvent("PLAYER_REGEN_DISABLED")
ok(rot.listFrame:IsShown(), "en combat, la file s'affiche")
ok(rot.listFrame.lines[1]:GetText():find("Heal", 1, true) ~= nil, "le designe en tete")

Mock.FireCombatLog("SPELL_CAST_SUCCESS", "Player-0-0003", BOSS_GUID, KICK)
ok(rot.listFrame.lines[1]:GetText():find("Tank", 1, true) ~= nil,
    "et la file se reordonne des qu'un kick part")

-- Sortir de combat n'est pas la fin du combat : PLAYER_REGEN_ENABLED tombe aussi
-- quand tu meurs pendant que le raid continue. La file disparaitrait alors au
-- moment exact ou elle sert le plus.
Mock.units.party1.combat = true
Mock.units.player.combat = false
Mock.FireEvent("PLAYER_REGEN_ENABLED")
ok(rot.listFrame:IsShown(), "joueur mort, groupe toujours en combat : la file reste")
equal(rot.lastCaster, "Heal", "et le tour n'est pas remis a zero")

Mock.units.party1.combat = false
Mock.FireEvent("PLAYER_REGEN_ENABLED")
equal(rot.listFrame:IsShown(), false, "fin de combat du groupe : cadre masque")
equal(rot.lastCaster, nil, "et la file repart du debut au pull suivant")

--- Commandes.
Mock.printed = {}
SlashCmdList["MYBOSSSUITE"]("rotation")
ok(Mock.FindPrinted("Rotation d'interrupt"), "/mbs rotation affiche l'etat")
Mock.printed = {}
SlashCmdList["MYBOSSSUITE"]("rot list")
ok(Mock.FindPrinted("Heal"), "/mbs rot list montre la file")
SlashCmdList["MYBOSSSUITE"]("rotation cadre off")
equal(ns.db.modules.interruptRotation.list, false, "/mbs rotation cadre off")
SlashCmdList["MYBOSSSUITE"]("rotation cadre on")
SlashCmdList["MYBOSSSUITE"]("rotation delai 0")
equal(ns.db.modules.interruptRotation.handoff, 0,
    "/mbs rotation delai 0 — la retenue ne rend jamais la main")
SlashCmdList["MYBOSSSUITE"]("rotation delai 1.2")

--- La liste des porteurs est tenue en cache (l'alerte kick la relit cinq fois
-- par seconde) : un joueur qui s'annonce en plein combat doit y entrer aussitot,
-- sans attendre un changement de groupe.
Mock.FireEvent("CHAT_MSG_ADDON", "MBS", "1\tCD\t" .. COUNTERSPELL .. "\t0\t0\tinterrupt",
    "PARTY", "Muet")
equal(#rot:Order(), 4, "un joueur qui s'annonce entre dans la file sans attendre")

--- Seul, il n'y a pas de rotation : rien ne doit retenir quoi que ce soit.
Mock.units.party1, Mock.units.party2, Mock.units.party3 = nil, nil, nil
Mock.groupSize = 0
Mock.FireEvent("GROUP_ROSTER_UPDATE")
equal(rot:IsActive(), false, "sans groupe, aucune rotation")
equal(rot:Holder("target|17086"), nil, "et plus rien ne retient l'alerte")

--- Sans CD Tracker, la rotation n'a aucune source — et le dit, au lieu de
-- laisser croire a un ordre qu'elle n'a pas.
ns:SetModuleEnabled("cdTracker", false)
equal(#rot:Order(), 0, "CD Tracker eteint : plus aucune source")
ok(rot:StatusLines()[1]:find("CD Tracker", 1, true) ~= nil, "et le statut le dit")

--- Desactivation complete.
ns:SetModuleEnabled("interruptRotation", false)
equal(rot.listFrame:IsShown(), false, "module eteint : cadre masque")
Mock.FireCombatLog("SPELL_CAST_SUCCESS", "Player-0-0002", BOSS_GUID, COUNTERSPELL)
equal(rot.lastCaster, nil, "et plus personne n'ecoute le combat log")

--------------------------------------------------------------------------------

suite("Profils")
ns:SetModuleEnabled("interruptAlert", true)
local raidProfile = ns.DB:EnsureProfile("raid")
raidProfile.modules.interruptAlert.spellId = 2139
raidProfile.locked = false
SlashCmdList["MYBOSSSUITE"]("profile raid")
equal(ns.DB:GetProfileName(), "raid", "/mbs profile <nom>")
equal(ns:IsModuleEnabled("interruptAlert"), true, "module actif dans le nouveau profil")
equal(ns:GetModule("interruptAlert").interruptSpell, 2139,
    "changement de profil : le module actif relit sa config (interrupt force)")
equal(ns.Anchors.unlocked, true, "changement de profil : l'etat unlock du profil est applique")
SlashCmdList["MYBOSSSUITE"]("profile Testeur-Mock")
equal(ns:GetModule("interruptAlert").interruptSpell, 1766, "retour au profil initial : interrupt auto")
equal(ns.Anchors.unlocked, false, "retour au profil initial : ancres verrouillees")
equal(ns.db.modules.interruptAlert.enabled, true,
    "le redemarrage n'a rien ecrit dans le profil")
ns:SetModuleEnabled("interruptAlert", false)

--------------------------------------------------------------------------------

say(("\n%d ok, %d echec(s)"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
