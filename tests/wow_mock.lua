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
function _G.PlaySound() end

--------------------------------------------------------------------------------
-- Units
--------------------------------------------------------------------------------

Mock.units = {
    player = { guid = "Player-0-0001", name = "Testeur", health = 100, healthMax = 100, exists = true },
    target = nil,
}

function _G.UnitExists(unit) return Mock.units[unit] ~= nil end
function _G.UnitGUID(unit) local u = Mock.units[unit] return u and u.guid end
function _G.UnitName(unit) local u = Mock.units[unit] return u and u.name end
function _G.UnitHealth(unit) local u = Mock.units[unit] return u and u.health or 0 end
function _G.UnitHealthMax(unit) local u = Mock.units[unit] return u and u.healthMax or 0 end
function _G.UnitAttackSpeed() return Mock.attackSpeed or 2.6 end
function _G.GetRealmName() return "Mock" end
function _G.GetNumGroupMembers() return 1 end
function _G.IsInRaid() return false end

--------------------------------------------------------------------------------
-- Spells
--------------------------------------------------------------------------------

Mock.spells = {
    [17086] = { name = "Flame Breath", icon = "icon-17086" },
    [18435] = { name = "Fireball Volley", icon = "icon-18435" },
}

function _G.GetSpellInfo(id)
    local spell = Mock.spells[id]
    if not spell then return nil end
    return spell.name, nil, spell.icon, 0
end

function _G.GetSpellTexture(id)
    local spell = Mock.spells[id]
    return spell and spell.icon
end

function _G.GetSpellCooldown() return 0, 0, true end
function _G.UnitAura() return nil end
function _G.SendAddonMessage() end
function _G.RegisterAddonMessagePrefix() end

--------------------------------------------------------------------------------
-- Combat log
--------------------------------------------------------------------------------

Mock.combatLogPayload = {}

function _G.CombatLogGetCurrentEventInfo()
    return unpack(Mock.combatLogPayload, 1, 20)
end

--- Emet un evenement de combat log. Les positions suivent la signature reelle :
-- timestamp, subevent, hideCaster, srcGUID, srcName, srcFlags, srcRaidFlags,
-- dstGUID, dstName, dstFlags, dstRaidFlags, puis les parametres du suffixe.
function Mock.FireCombatLog(subevent, srcGUID, dstGUID, p12, p13, p14, p15)
    Mock.combatLogPayload = {
        Mock.now, subevent, false, srcGUID, "src", 0, 0, dstGUID, "dst", 0, 0,
        p12, p13, p14, p15,
    }
    Mock.FireEvent("COMBAT_LOG_EVENT_UNFILTERED")
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
    "SetStatusBarColor", "SetText", "SetChecked", "GetChecked", "SetWidth",
    "SetHeight", "SetAllPoints", "SetFontObject", "SetNormalTexture",
    "RegisterForClicks", "SetHitRectInsets", "SetBackdrop",
}

for _, name in ipairs(NOOP_METHODS) do FrameMeta[name] = NoOp end

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

    _G.C_Spell = {
        GetSpellInfo = function(id)
            local spell = Mock.spells[id]
            if not spell then return nil end
            return { name = spell.name, iconID = spell.icon, castTime = 0 }
        end,
        GetSpellCooldown = function()
            return { startTime = 0, duration = 0, isEnabled = true }
        end,
        GetSpellTexture = function(id)
            local spell = Mock.spells[id]
            return spell and spell.icon
        end,
    }

    _G.C_UnitAuras = {
        GetAuraDataByIndex = function() return nil end,
    }

    _G.C_ChatInfo = {
        SendAddonMessage = function() end,
        RegisterAddonMessagePrefix = function() end,
    }

    _G.C_AddOns = {
        GetAddOnMetadata = function(_, field)
            return field == "Version" and "0.1.0" or nil
        end,
    }

    _G.C_EncounterJournal = {}
    _G.C_LossOfControl = {}
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
end

function Mock.FindPrinted(pattern)
    for i = 1, #Mock.printed do
        if Mock.printed[i]:find(pattern, 1, true) then return Mock.printed[i] end
    end
end

return Mock
