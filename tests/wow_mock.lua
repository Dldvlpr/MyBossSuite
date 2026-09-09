-- tests/wow_mock.lua
-- Mock minimal de l'API WoW, suffisant pour faire tourner le socle hors du jeu.
-- Le temps est pilote a la main : Mock.Advance(dt) fait avancer GetTime, les
-- timers et les scripts OnUpdate.

local Mock = {}
_G.Mock = Mock

Mock.now = 1000
Mock.printed = {}
Mock.frames = {}

--------------------------------------------------------------------------------
-- Utilitaires WoW
--------------------------------------------------------------------------------

function _G.print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, " ")
    Mock.printed[#Mock.printed + 1] = line
    if Mock.verbose then io.write(line, "\n") end
end

function _G.strjoin(sep, ...)
    return table.concat({ ... }, sep)
end

function _G.tostringall(...)
    local n = select("#", ...)
    local out = {}
    for i = 1, n do out[i] = tostring((select(i, ...))) end
    return unpack(out, 1, n)
end

_G.tinsert = table.insert
_G.tremove = table.remove
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.strsplit = function(sep, str) return string.match(str, "(.-)" .. sep .. "(.*)") end

function _G.GetTime() return Mock.now end
function _G.GetBuildInfo() return "1.15.7", "60000", "Jan 1 2026", 11507 end

_G.WOW_PROJECT_ID = 2
_G.WOW_PROJECT_MAINLINE = 1
_G.WOW_PROJECT_CLASSIC = 2
_G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5
_G.WOW_PROJECT_WRATH_CLASSIC = 11
_G.WOW_PROJECT_CATACLYSM_CLASSIC = 14
_G.WOW_PROJECT_MISTS_CLASSIC = 19

_G.UISpecialFrames = {}
_G.SlashCmdList = {}
_G.SOUNDKIT = { RAID_WARNING = 1 }

-- Les sons joues sont enregistres : c'est la seule facon de verifier qu'une
-- alerte muette l'est vraiment.
Mock.sounds = {}

function _G.PlaySound(id, channel)
    Mock.sounds[#Mock.sounds + 1] = { kit = id, channel = channel }
end

function _G.PlaySoundFile(path, channel)
    Mock.sounds[#Mock.sounds + 1] = { file = path, channel = channel }
end

--------------------------------------------------------------------------------
-- Units
--------------------------------------------------------------------------------

Mock.units = {
    player = {
        guid = "Player-0-0001", name = "Testeur", class = "ROGUE",
        health = 100, healthMax = 100, exists = true,
    },
    target = nil,
}

function _G.UnitExists(unit) return Mock.units[unit] ~= nil end
function _G.UnitGUID(unit) local u = Mock.units[unit] return u and u.guid end
function _G.UnitName(unit) local u = Mock.units[unit] return u and u.name end
function _G.UnitHealth(unit) local u = Mock.units[unit] return u and u.health or 0 end
function _G.UnitHealthMax(unit) local u = Mock.units[unit] return u and u.healthMax or 0 end
function _G.UnitAttackSpeed() return Mock.attackSpeed or 2.6 end
function _G.UnitClass(unit)
    local u = Mock.units[unit]
    return u and u.class or nil, u and u.class or nil
end
function _G.UnitCanAttack(_, unit)
    local u = Mock.units[unit]
    return u ~= nil and u.friendly ~= true
end
function _G.UnitIsDead(unit)
    local u = Mock.units[unit]
    return u ~= nil and u.dead == true
end
function _G.UnitIsDeadOrGhost(unit) return UnitIsDead(unit) end
function _G.UnitAffectingCombat(unit)
    local u = Mock.units[unit]
    return u ~= nil and u.combat == true
end
function _G.GetRealmName() return "Mock" end

-- 0 = solo, comme le vrai client. Mock.groupSize / Mock.inRaid pilotent le groupe.
Mock.groupSize = 0
Mock.inRaid = false
function _G.GetNumGroupMembers() return Mock.groupSize or 0 end
function _G.IsInRaid() return Mock.inRaid == true end

-- Instance courante, pilotee par les tests : hors instance par defaut.
Mock.instance = { name = "Azshara", type = "none", difficulty = 0, difficultyName = nil, instanceId = 0 }

function _G.GetInstanceInfo()
    local i = Mock.instance
    return i.name, i.type, i.difficulty, i.difficultyName, 40, 0, false, i.instanceId, nil
end

function _G.IsInInstance()
    local t = Mock.instance.type
    return t ~= "none", t
end

--------------------------------------------------------------------------------
-- Spells
--------------------------------------------------------------------------------

Mock.spells = {
    [17086] = { name = "Flame Breath", icon = "icon-17086" },
    [18435] = { name = "Fireball Volley", icon = "icon-18435" },
    [1766]  = { name = "Kick", icon = "icon-1766" },
    [2139]  = { name = "Counterspell", icon = "icon-2139" },
    [22271] = { name = "Fire Patch", icon = "icon-22271" },
    [22272] = { name = "Corruption", icon = "icon-22272" },
    [22273] = { name = "Cleave", icon = "icon-22273" },
    [22274] = { name = "Fire Wall", icon = "icon-22274" },
}

-- Grimoire du personnage mock : un voleur qui connait Kick, et rien d'autre.
Mock.knownSpells = { [1766] = true }

-- [spellId] = { start = , duration = } — absent = pret.
Mock.cooldowns = {}

function _G.GetSpellInfo(id)
    local spell = Mock.spells[id]
    if not spell then return nil end
    return spell.name, nil, spell.icon, 0
end

function _G.GetSpellTexture(id)
    local spell = Mock.spells[id]
    return spell and spell.icon
end

--- Accepte un id ou un nom, comme le vrai client : c'est ce qui permet de
-- tester le repli par nom de `ns.KnowsSpell` (les rangs classic).
local function SpellIdOf(identifier)
    if type(identifier) == "number" then return identifier end
    for id, spell in pairs(Mock.spells) do
        if spell.name == identifier then return id end
    end
    return nil
end

Mock.SpellIdOf = SpellIdOf

function _G.GetSpellCooldown(identifier)
    local id = SpellIdOf(identifier)
    if not id or not Mock.knownSpells[id] then return nil end
    local cooldown = Mock.cooldowns[id]
    if not cooldown then return 0, 0, true end
    return cooldown.start, cooldown.duration, true
end

function _G.IsSpellKnown(id) return Mock.knownSpells[id] == true end

function _G.IsSpellInRange(_, unit)
    if Mock.outOfRange then return 0 end
    return Mock.units[unit] and 1 or nil
end

--------------------------------------------------------------------------------
-- Incantations
--------------------------------------------------------------------------------

-- [unit] = { name, icon, spellId, notInterruptible, channel }
Mock.casts = {}

function Mock.SetCast(unit, spellId, notInterruptible, channel)
    if not spellId then Mock.casts[unit] = nil return end
    local spell = Mock.spells[spellId]
    Mock.casts[unit] = {
        name             = spell and spell.name or "?",
        icon             = spell and spell.icon,
        spellId          = spellId,
        notInterruptible = notInterruptible and true or false,
        channel          = channel and true or false,
    }
end

-- Mock.legacyCastInfo = true reproduit Classic Era : UnitCastingInfo et
-- UnitChannelInfo n'y rendent pas `notInterruptible`, et le spellId occupe la
-- case du booleen. Compat doit s'en sortir sans perdre le spellId.
function _G.UnitCastingInfo(unit)
    local cast = Mock.casts[unit]
    if not cast or cast.channel then return nil end
    if Mock.legacyCastInfo then
        return cast.name, nil, cast.icon, Mock.now * 1000, (Mock.now + 2) * 1000,
            false, "cast1", cast.spellId
    end
    return cast.name, nil, cast.icon, Mock.now * 1000, (Mock.now + 2) * 1000,
        false, "cast1", cast.notInterruptible, cast.spellId
end

function _G.UnitChannelInfo(unit)
    local cast = Mock.casts[unit]
    if not cast or not cast.channel then return nil end
    if Mock.legacyCastInfo then
        return cast.name, nil, cast.icon, Mock.now * 1000, (Mock.now + 2) * 1000,
            false, cast.spellId
    end
    return cast.name, nil, cast.icon, Mock.now * 1000, (Mock.now + 2) * 1000,
        false, cast.notInterruptible, cast.spellId
end

--------------------------------------------------------------------------------
-- Auras
--------------------------------------------------------------------------------

Mock.auras = {}   -- [unit] = { { spellId = , name = }, ... }

function _G.UnitAura(unit, index)
    local list = Mock.auras[unit]
    local aura = list and list[index]
    if not aura then return nil end
    local spell = Mock.spells[aura.spellId]
    return aura.name or (spell and spell.name) or "?", spell and spell.icon, 1, nil,
        10, Mock.now + 10, "boss1", nil, nil, aura.spellId
end
-- Les messages addon envoyes sont conserves : c'est ce qui permet de verifier
-- ce qu'un joueur annonce a son groupe. Un pair se simule en rejouant
-- CHAT_MSG_ADDON avec un autre nom d'expediteur.
Mock.addonMessages = {}

function _G.SendAddonMessage(prefix, message, channel)
    Mock.addonMessages[#Mock.addonMessages + 1] = { prefix = prefix, message = message, channel = channel }
end
function _G.RegisterAddonMessagePrefix() end

function Mock.LastAddonMessage()
    return Mock.addonMessages[#Mock.addonMessages]
end

--------------------------------------------------------------------------------
-- Combat log
--------------------------------------------------------------------------------

Mock.combatLogPayload = {}
Mock.combatLogCount = 0

function _G.CombatLogGetCurrentEventInfo()
    return unpack(Mock.combatLogPayload, 1, math.max(24, Mock.combatLogCount))
end

--- Emet un evenement de combat log. Les positions suivent la signature reelle :
-- timestamp, subevent, hideCaster, srcGUID, srcName, srcFlags, srcRaidFlags,
-- dstGUID, dstName, dstFlags, dstRaidFlags, puis les parametres du suffixe a
-- partir de la 12e position, autant qu'on en passe (les nil sont conserves :
-- isOffHand est le 21e argument de SWING_DAMAGE).
function Mock.FireCombatLog(subevent, srcGUID, dstGUID, ...)
    local payload = { Mock.now, subevent, false, srcGUID, "src", 0, 0, dstGUID, "dst", 0, 0 }
    local n = select("#", ...)
    for i = 1, n do payload[11 + i] = (select(i, ...)) end
    Mock.combatLogPayload = payload
    Mock.combatLogCount = 11 + n
    Mock.FireEvent("COMBAT_LOG_EVENT_UNFILTERED")
end

--------------------------------------------------------------------------------
-- Boss mods tiers (pont DBM / BigWigs)
--------------------------------------------------------------------------------
-- Faux DBM et faux BigWigs, reduits a ce que le pont utilise : poser un
-- callback, le retirer, le declencher. Ce qui est verifie ici n'est pas DBM —
-- c'est que MyBossSuite lit correctement ce que DBM lui envoie, et refuse ce
-- qui n'a pas la bonne forme.
--
-- Les deux repassent le nom de l'evenement en premier argument, comme en jeu
-- (DBM le fait explicitement, BigWigs par CallbackHandler).

Mock.bossMods = { dbm = {}, bw = {} }

function Mock.InstallDBM()
    local callbacks = {}
    _G.DBM = {
        RegisterCallback = function(_, event, fn)
            callbacks[event] = callbacks[event] or {}
            table.insert(callbacks[event], fn)
        end,
        UnregisterCallback = function(_, event, fn)
            local list = callbacks[event]
            if not list then return end
            for i = #list, 1, -1 do
                if list[i] == fn then table.remove(list, i) end
            end
        end,
    }
    Mock.bossMods.dbm = callbacks
end

function Mock.FireDBM(event, ...)
    local list = Mock.bossMods.dbm[event]
    if not list then return 0 end
    for i = 1, #list do list[i](event, ...) end
    return #list
end

function Mock.InstallBigWigs()
    -- CallbackHandler indexe par (message, cible) : une cible ne peut avoir
    -- qu'un handler par message, ce que le pont respecte avec sa table relais.
    local registry = {}
    _G.BigWigsLoader = {
        RegisterMessage = function(target, message, fn)
            registry[message] = registry[message] or {}
            registry[message][target] = fn
        end,
        UnregisterMessage = function(target, message)
            if registry[message] then registry[message][target] = nil end
        end,
    }
    Mock.bossMods.bw = registry
end

function Mock.FireBigWigs(message, ...)
    local list = Mock.bossMods.bw[message]
    if not list then return 0 end
    local fired = 0
    for _, fn in pairs(list) do
        fn(message, ...)
        fired = fired + 1
    end
    return fired
end

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

local FrameMeta = {}
FrameMeta.__index = FrameMeta

local function NoOp() end

local NOOP_METHODS = {
    "SetMovable", "EnableMouse", "EnableMouseWheel", "SetClampedToScreen",
    "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetFrameStrata",
    "SetFrameLevel", "SetStatusBarTexture", "SetMinMaxValues", "SetValue",
    "SetTexCoord", "SetJustifyH", "SetTexture", "SetColorTexture", "SetAlpha",
    "SetStatusBarColor", "SetChecked", "GetChecked", "SetWidth",
    "SetHeight", "SetAllPoints", "SetFontObject", "SetNormalTexture",
    "RegisterForClicks", "SetHitRectInsets", "SetBackdrop", "SetTextColor",
    "SetShadowOffset", "SetDrawLayer",
}

for _, name in ipairs(NOOP_METHODS) do FrameMeta[name] = NoOp end

-- Le texte est conserve : les tests d'alerte verifient ce qui est affiche.
function FrameMeta:SetText(text) self.text = text end
function FrameMeta:GetText() return self.text end
function FrameMeta:SetFont(path, size, flags)
    self.font, self.fontSize, self.fontFlags = path, size, flags
end
function FrameMeta:GetFont() return self.font, self.fontSize, self.fontFlags end

function FrameMeta:GetFrameLevel() return 1 end
function FrameMeta:GetName() return self.frameName end
function FrameMeta:GetScale() return self.scale or 1 end
function FrameMeta:SetScale(scale) self.scale = scale end
function FrameMeta:SetSize(w, h) self.width, self.height = w, h end
function FrameMeta:GetWidth() return self.width or 0 end
function FrameMeta:GetHeight() return self.height or 0 end
function FrameMeta:Show() self.shown = true end
function FrameMeta:Hide() self.shown = false end
function FrameMeta:IsShown() return self.shown == true end
function FrameMeta:IsVisible() return self.shown == true end

function FrameMeta:SetPoint(point, relTo, relPoint, x, y)
    if type(relTo) == "string" then relTo = _G[relTo] end
    self.points = { point, relTo, relPoint, x, y }
end

function FrameMeta:GetPoint()
    local p = self.points
    if not p then return nil end
    return p[1], p[2], p[3], p[4], p[5]
end

function FrameMeta:ClearAllPoints() self.points = nil end

function FrameMeta:SetScript(script, fn) self.scripts[script] = fn end
function FrameMeta:GetScript(script) return self.scripts[script] end
function FrameMeta:HookScript(script, fn) self.scripts[script] = fn end

function FrameMeta:RegisterEvent(event)
    if Mock.unknownEvents[event] then
        error("Attempted to register unknown event '" .. event .. "'")
    end
    self.events[event] = true
end

function FrameMeta:UnregisterEvent(event) self.events[event] = nil end
function FrameMeta:UnregisterAllEvents() self.events = {} end
function FrameMeta:IsEventRegistered(event) return self.events[event] == true end

function FrameMeta:CreateTexture()
    return setmetatable({ scripts = {}, events = {}, shown = true }, FrameMeta)
end

function FrameMeta:CreateFontString()
    return setmetatable({ scripts = {}, events = {}, shown = true }, FrameMeta)
end

-- Events absents de ce "client" mock : on simule un client vanilla, ou
-- ENCOUNTER_START n'existe pas.
Mock.unknownEvents = {
    ENCOUNTER_START = true,
    ENCOUNTER_END = true,
    UNIT_HEALTH_FREQUENT = true,
    INSTANCE_ENCOUNTER_ENGAGE_UNIT = true,
}

function _G.CreateFrame(frameType, name, parent, template)
    local frame = setmetatable({
        frameType = frameType,
        frameName = name,
        parent    = parent,
        template  = template,
        scripts   = {},
        events    = {},
        shown     = true,
    }, FrameMeta)
    if name then _G[name] = frame end
    Mock.frames[#Mock.frames + 1] = frame
    return frame
end

_G.UIParent = CreateFrame("Frame", "UIParent")

--------------------------------------------------------------------------------
-- Bascule "client retail"
--------------------------------------------------------------------------------
-- Meme suite de tests, autre client : WOW_PROJECT_ID different, tous les events
-- disponibles, et les API C_* modernes en place. C'est ce qui verifie que
-- Compat aiguille correctement sans qu'aucun module ne change.

function Mock.InstallRetail()
    _G.WOW_PROJECT_ID = _G.WOW_PROJECT_MAINLINE
    Mock.unknownEvents = {}
    Mock.retail = true

    function _G.GetBuildInfo() return "11.2.0", "60000", "Jan 1 2026", 110200 end

    -- Le preset "alarm" doit choisir ce kit-la en retail, et retomber sur
    -- RAID_WARNING en classic ou il n'existe pas.
    _G.SOUNDKIT.UI_RAID_BOSS_WHISPER_WARNING = 42

    _G.C_Spell = {
        GetSpellInfo = function(id)
            local spell = Mock.spells[id]
            if not spell then return nil end
            return { name = spell.name, iconID = spell.icon, castTime = 0 }
        end,
        GetSpellCooldown = function(identifier)
            local id = Mock.SpellIdOf(identifier)
            if not id or not Mock.knownSpells[id] then return nil end
            local cooldown = Mock.cooldowns[id]
            if not cooldown then return { startTime = 0, duration = 0, isEnabled = true } end
            return { startTime = cooldown.start, duration = cooldown.duration, isEnabled = true }
        end,
        GetSpellTexture = function(id)
            local spell = Mock.spells[id]
            return spell and spell.icon
        end,
    }

    _G.C_UnitAuras = {
        GetAuraDataByIndex = function(unit, index)
            local list = Mock.auras[unit]
            local aura = list and list[index]
            if not aura then return nil end
            local spell = Mock.spells[aura.spellId]
            return {
                name           = aura.name or (spell and spell.name) or "?",
                icon           = spell and spell.icon,
                applications   = 1,
                duration       = 10,
                expirationTime = Mock.now + 10,
                sourceUnit     = "boss1",
                spellId        = aura.spellId,
            }
        end,
    }

    _G.C_ChatInfo = {
        SendAddonMessage = function(prefix, message, channel)
            _G.SendAddonMessage(prefix, message, channel)
            return 0
        end,
        RegisterAddonMessagePrefix = function() return 0 end,
    }

    _G.C_AddOns = {
        GetAddOnMetadata = function(_, field)
            return field == "Version" and "0.1.0" or nil
        end,
    }

    -- Le module kick doit passer par ns.IsSpellInRange : la variante retail
    -- rend un booleen la ou l'ancienne API rendait 0/1.
    _G.C_Spell.IsSpellInRange = function(_, unit)
        if Mock.outOfRange then return false end
        if not Mock.units[unit] then return nil end
        return true
    end

    _G.C_EncounterJournal = {}
    _G.C_LossOfControl = {}

    -- IsEncounterInProgress n'existe que sur les clients recents : c'est le
    -- signal qui garde une rencontre engagee quand tout le groupe est mort.
    Mock.encounterInProgress = false
    _G.IsEncounterInProgress = function() return Mock.encounterInProgress end
    _G.C_NamePlate = {}
    _G.GetSpecialization = function() return 1 end
end

--------------------------------------------------------------------------------
-- Dispatch d'events
--------------------------------------------------------------------------------

function Mock.FireEvent(event, ...)
    for i = 1, #Mock.frames do
        local frame = Mock.frames[i]
        if frame.events[event] then
            local handler = frame.scripts.OnEvent
            if handler then handler(frame, event, ...) end
        end
    end
end

--------------------------------------------------------------------------------
-- Temps
--------------------------------------------------------------------------------

Mock.timers = {}

local TimerMeta = {}
TimerMeta.__index = TimerMeta
function TimerMeta:Cancel() self.cancelled = true end
function TimerMeta:IsCancelled() return self.cancelled == true end

local function NewMockTimer(delay, callback, interval)
    local timer = setmetatable({
        at = Mock.now + delay, callback = callback, interval = interval,
    }, TimerMeta)
    Mock.timers[#Mock.timers + 1] = timer
    return timer
end

Mock.nativeTimers = true

function Mock.InstallTimerAPI(native)
    Mock.nativeTimers = native
    if native then
        _G.C_Timer = {
            NewTimer  = function(delay, cb) return NewMockTimer(delay, cb, nil) end,
            NewTicker = function(interval, cb) return NewMockTimer(interval, cb, interval) end,
            After     = function(delay, cb) NewMockTimer(delay, cb, nil) end,
        }
    else
        _G.C_Timer = nil
    end
end

Mock.InstallTimerAPI(true)

local function StepTimers()
    for i = #Mock.timers, 1, -1 do
        local timer = Mock.timers[i]
        if timer.cancelled then
            table.remove(Mock.timers, i)
        elseif timer.at <= Mock.now then
            if timer.interval then
                timer.at = timer.at + timer.interval
            else
                timer.cancelled = true
                table.remove(Mock.timers, i)
            end
            timer.callback()
        end
    end
end

local function StepOnUpdate(step)
    for i = 1, #Mock.frames do
        local frame = Mock.frames[i]
        local handler = frame.scripts.OnUpdate
        if handler and frame.shown then handler(frame, step) end
    end
end

--- Avance le temps par petits pas, en declenchant timers et OnUpdate.
function Mock.Advance(seconds, step)
    step = step or 0.05
    local remaining = seconds
    while remaining > 0 do
        local delta = math.min(step, remaining)
        Mock.now = Mock.now + delta
        remaining = remaining - delta
        StepOnUpdate(delta)
        StepTimers()
    end
end

function Mock.Reset()
    Mock.printed = {}
    Mock.sounds = {}
end

function Mock.FindPrinted(pattern)
    for i = 1, #Mock.printed do
        if Mock.printed[i]:find(pattern, 1, true) then return Mock.printed[i] end
    end
end

return Mock
