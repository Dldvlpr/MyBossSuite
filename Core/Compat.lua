-- Core/Compat.lua
-- Couche d'abstraction API. AUCUN module ne doit appeler une API qui diffère
-- entre flavors : tout passe par ici.
--
-- Regle : le flavor sert au branchement de *data*, la feature-detection sert au
-- branchement d'*API*. Un patch classic qui backporte une fonction ne doit rien
-- casser.

local addonName, ns = ...

_G.MyBossSuite = ns
ns.addonName = addonName

--------------------------------------------------------------------------------
-- Flavor
--------------------------------------------------------------------------------

local projectId = _G.WOW_PROJECT_ID

local function IsProject(constant)
    local value = _G[constant]
    return value ~= nil and projectId == value
end

local function FlavorFromInterface()
    -- Filet de secours pour les builds ou WOW_PROJECT_ID n'existe pas.
    local _, _, _, iface = GetBuildInfo()
    iface = tonumber(iface) or 0
    if iface >= 100000 then return "retail" end
    if iface >= 50000 then return "mists" end
    if iface >= 40000 then return "cata" end
    if iface >= 30000 then return "wrath" end
    if iface >= 20000 then return "tbc" end
    return "vanilla"
end

ns.flavor = (projectId and (
       (IsProject("WOW_PROJECT_MAINLINE") and "retail")
    or (IsProject("WOW_PROJECT_CLASSIC") and "vanilla")
    or (IsProject("WOW_PROJECT_BURNING_CRUSADE_CLASSIC") and "tbc")
    or (IsProject("WOW_PROJECT_WRATH_CLASSIC") and "wrath")
    or (IsProject("WOW_PROJECT_CATACLYSM_CLASSIC") and "cata")
    or (IsProject("WOW_PROJECT_MISTS_CLASSIC") and "mists")
)) or FlavorFromInterface()

ns.isRetail  = (ns.flavor == "retail")
ns.isClassic = not ns.isRetail

--------------------------------------------------------------------------------
-- Detection d'events
--------------------------------------------------------------------------------
-- RegisterEvent leve une erreur sur un event inconnu : c'est le seul test fiable
-- de la presence d'un event, et il survit aux backports.

local probe = CreateFrame("Frame")

local eventExists = {}

function ns.EventExists(event)
    local cached = eventExists[event]
    if cached ~= nil then return cached end
    local ok = pcall(probe.RegisterEvent, probe, event)
    if ok then pcall(probe.UnregisterEvent, probe, event) end
    eventExists[event] = ok
    return ok
end

--------------------------------------------------------------------------------
-- Addon metadata
--------------------------------------------------------------------------------

local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
ns.version = (GetAddOnMetadata and GetAddOnMetadata(addonName, "Version")) or "dev"

--------------------------------------------------------------------------------
-- Spell API
--------------------------------------------------------------------------------
-- C_Spell.* introduit en 11.0 retail, backporte partiellement en classic.

ns.GetSpellCooldown = (C_Spell and C_Spell.GetSpellCooldown)
    and function(id)
        local info = C_Spell.GetSpellCooldown(id)
        if not info then return 0, 0, false end
        return info.startTime, info.duration, info.isEnabled
    end
    or _G.GetSpellCooldown

ns.GetSpellInfo = (C_Spell and C_Spell.GetSpellInfo)
    and function(id)
        local info = C_Spell.GetSpellInfo(id)
        if not info then return nil end
        return info.name, nil, info.iconID, info.castTime
    end
    or _G.GetSpellInfo

ns.GetSpellTexture = (C_Spell and C_Spell.GetSpellTexture)
    or _G.GetSpellTexture
    or function(id) return (select(3, ns.GetSpellInfo(id))) end

function ns.GetSpellName(id)
    local name = ns.GetSpellInfo(id)
    return name
end

--------------------------------------------------------------------------------
-- Auras
--------------------------------------------------------------------------------
-- Retourne une forme unique quelle que soit la version :
--   name, icon, count, duration, expirationTime, source, spellId

local C_UnitAuras = _G.C_UnitAuras

if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
    function ns.GetAuraByIndex(unit, index, filter)
        local data = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
        if not data then return nil end
        return data.name, data.icon, data.applications, data.duration,
               data.expirationTime, data.sourceUnit, data.spellId
    end
else
    local UnitAura = _G.UnitAura
    function ns.GetAuraByIndex(unit, index, filter)
        local name, icon, count, _, duration, expirationTime, source, _, _, spellId =
            UnitAura(unit, index, filter)
        if not name then return nil end
        return name, icon, count, duration, expirationTime, source, spellId
    end
end

function ns.FindAura(unit, spellId, filter)
    for i = 1, 40 do
        local name, icon, count, duration, expirationTime, source, id =
            ns.GetAuraByIndex(unit, i, filter)
        if not name then return nil end
        if id == spellId then
            return name, icon, count, duration, expirationTime, source, id
        end
    end
end

--------------------------------------------------------------------------------
-- Addon comm
--------------------------------------------------------------------------------

ns.SendAddonMessage = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or _G.SendAddonMessage
ns.RegisterAddonMessagePrefix =
    (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or _G.RegisterAddonMessagePrefix

--------------------------------------------------------------------------------
-- Timers
--------------------------------------------------------------------------------
-- C_Timer.NewTimer n'existe pas sur les tout premiers builds Classic Era.
-- Implementation maison sur OnUpdate en secours : meme interface (:Cancel()),
-- donc le Scheduler ne voit jamais la difference.

local Timer = {}
ns.Timer = Timer

local hasNativeTimer = (C_Timer and C_Timer.NewTimer and C_Timer.NewTicker) and true or false
Timer.native = hasNativeTimer

if hasNativeTimer then

    function Timer.NewTimer(delay, callback)
        return C_Timer.NewTimer(delay, callback)
    end

    function Timer.NewTicker(interval, callback)
        return C_Timer.NewTicker(interval, callback)
    end

else

    local driver = CreateFrame("Frame")
    local tasks = {}

    local TaskMeta = {}
    TaskMeta.__index = TaskMeta

    function TaskMeta:Cancel()
        self._cancelled = true
    end

    function TaskMeta:IsCancelled()
        return self._cancelled == true
    end

    driver:SetScript("OnUpdate", function(_, elapsed)
        local n = #tasks
        if n == 0 then return end
        for i = n, 1, -1 do
            local task = tasks[i]
            if task._cancelled then
                tremove(tasks, i)
            else
                task._remaining = task._remaining - elapsed
                if task._remaining <= 0 then
                    if task._interval then
                        -- On reporte le reliquat pour ne pas deriver.
                        task._remaining = task._remaining + task._interval
                        if task._remaining <= 0 then task._remaining = task._interval end
                    else
                        task._cancelled = true
                        tremove(tasks, i)
                    end
                    task._callback()
                end
            end
        end
    end)

    local function NewTask(delay, callback, interval)
        local task = setmetatable({
            _remaining = delay,
            _callback  = callback,
            _interval  = interval,
            _cancelled = false,
        }, TaskMeta)
        tasks[#tasks + 1] = task
        return task
    end

    function Timer.NewTimer(delay, callback)
        return NewTask(delay, callback, nil)
    end

    function Timer.NewTicker(interval, callback)
        return NewTask(interval, callback, interval)
    end

end

function Timer.After(delay, callback)
    return Timer.NewTimer(delay, callback)
end

--------------------------------------------------------------------------------
-- Divers
--------------------------------------------------------------------------------

ns.GetNumGroupMembers = _G.GetNumGroupMembers or function()
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then return raid end
    local party = GetNumPartyMembers and GetNumPartyMembers() or 0
    return party > 0 and (party + 1) or 0
end

ns.IsInRaidGroup = function()
    if IsInRaid then return IsInRaid() end
    return (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0
end

--------------------------------------------------------------------------------
-- Table de capacites
--------------------------------------------------------------------------------
-- Un seul point de verite, plutot que des `if isRetail` disperses.

ns.has = {
    encounterEvents     = ns.EventExists("ENCOUNTER_START"),
    bossUnitFrames      = ns.EventExists("INSTANCE_ENCOUNTER_ENGAGE_UNIT"),
    unitHealthFrequent  = ns.EventExists("UNIT_HEALTH_FREQUENT"),
    specializations     = _G.GetSpecialization ~= nil,
    lossOfControl       = _G.C_LossOfControl ~= nil,
    namePlates          = _G.C_NamePlate ~= nil,
    nativeTimers        = hasNativeTimer,
    -- Le parry haste (swing en cours ampute) n'existe plus en retail.
    parryHaste          = not ns.isRetail,
}

--------------------------------------------------------------------------------
-- GUID
--------------------------------------------------------------------------------

function ns.NpcIdFromGUID(guid)
    if not guid then return nil end
    local id = guid:match("^Creature%-0%-%d+%-%d+%-%d+%-(%d+)%-")
        or guid:match("^Vehicle%-0%-%d+%-%d+%-%d+%-(%d+)%-")
    return id and tonumber(id)
end

--------------------------------------------------------------------------------
-- Sortie console
--------------------------------------------------------------------------------

local PREFIX = "|cff33ff99MyBossSuite|r: "

function ns.Print(...)
    print(PREFIX .. strjoin(" ", tostringall(...)))
end

function ns.Debug(...)
    if not ns.debug then return end
    print("|cffff7f00MBS|r " .. strjoin(" ", tostringall(...)))
end
