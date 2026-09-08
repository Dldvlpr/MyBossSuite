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

-- Retourne nil quand le sort est inconnu du client : c'est ce qui permet de
-- distinguer "cooldown a zero" de "sort absent du grimoire".
ns.GetSpellCooldown = (C_Spell and C_Spell.GetSpellCooldown)
    and function(id)
        local info = C_Spell.GetSpellCooldown(id)
        if not info then return nil end
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

--- Le joueur connait-il ce sort ?
-- `IsSpellKnown` teste un id exact : en classic, un sort a un id par rang et
-- l'id du rang 1 ne dit rien du rang 6 appris. Le repli par nom couvre tous les
-- rangs d'un coup, puisque le grimoire est indexe par nom.
function ns.KnowsSpell(spellId)
    if not spellId then return false end
    if _G.IsPlayerSpell and IsPlayerSpell(spellId) then return true end
    if _G.IsSpellKnown and IsSpellKnown(spellId) then return true end
    local name = ns.GetSpellName(spellId)
    if not name then return false end
    return ns.GetSpellCooldown(name) ~= nil
end

--- Cooldown restant d'un sort, en secondes. 0 = pret.
-- Le GCD (duree <= 1.5s) ne compte pas comme un cooldown : un kick reste
-- annonce comme disponible pendant le GCD, sinon l'alerte clignote a chaque
-- sort lance.
function ns.GetSpellRemaining(spellId)
    local start, duration = ns.GetSpellCooldown(spellId)
    if not start then return nil end
    if start == 0 or duration == 0 or duration <= 1.5 then return 0 end
    local remaining = start + duration - GetTime()
    return remaining > 0 and remaining or 0
end

--------------------------------------------------------------------------------
-- Incantations
--------------------------------------------------------------------------------
-- Forme unique quelle que soit la version :
--   name, icon, startMs, endMs, notInterruptible, spellId, isChannel
-- `notInterruptible` n'existe pas sur les clients les plus anciens : l'absence
-- de l'information se lit "interruptible", jamais "protege" — une alerte de
-- trop vaut mieux qu'un kick manque.

local UnitCastingInfo = _G.UnitCastingInfo
local UnitChannelInfo = _G.UnitChannelInfo

function ns.GetCastInfo(unit)
    if UnitCastingInfo then
        local name, _, texture, startTime, endTime, _, _, notInterruptible, spellId =
            UnitCastingInfo(unit)
        if name then
            return name, texture, startTime, endTime, notInterruptible == true, spellId, false
        end
    end
    if UnitChannelInfo then
        -- Un channel n'a pas de castID : `notInterruptible` remonte d'un cran.
        local name, _, texture, startTime, endTime, _, notInterruptible, spellId =
            UnitChannelInfo(unit)
        if name then
            return name, texture, startTime, endTime, notInterruptible == true, spellId, true
        end
    end
    return nil
end

--- Portee d'un sort sur une unite : 1 a portee, 0 hors de portee, nil quand le
-- client ne sait pas repondre. C_Spell.IsSpellInRange (11.x) rend un booleen,
-- l'ancienne API un entier : on garde la forme entiere partout.
ns.IsSpellInRange = (C_Spell and C_Spell.IsSpellInRange)
    and function(spell, unit)
        local inRange = C_Spell.IsSpellInRange(spell, unit)
        if inRange == nil then return nil end
        return inRange and 1 or 0
    end
    or _G.IsSpellInRange

--------------------------------------------------------------------------------
-- Sons
--------------------------------------------------------------------------------
-- Deux mecanismes distincts : un id de SOUNDKIT (son du client) ou un chemin de
-- fichier (son fourni par l'utilisateur). Les deux passent par pcall : un id
-- absent d'un vieux client ou un fichier manquant ne doit jamais casser
-- l'alerte visuelle qui l'accompagne.

local PlaySound     = _G.PlaySound
local PlaySoundFile = _G.PlaySoundFile

-- Chaine de repli : le premier nom de SOUNDKIT qui existe sur ce client gagne.
-- Les constantes varient d'une version a l'autre, la liste evite un `if
-- isRetail` de plus.
ns.SOUND_PRESETS = {
    raidwarning = { "RAID_WARNING" },
    readycheck  = { "READY_CHECK", "READY_CHECK_WARNING", "RAID_WARNING" },
    alarm       = { "UI_RAID_BOSS_WHISPER_WARNING", "RAID_BOSS_EMOTE_WARNING", "RAID_WARNING" },
    ping        = { "IG_MAINMENU_OPTION_CHECKBOX_ON", "IG_MAINMENU_OPEN" },
    murloc      = { "MURLOC_AGGRO", "RAID_WARNING" },
}

function ns.ResolveSoundKit(name)
    local kit = _G.SOUNDKIT
    if not kit then return nil end
    local candidates = ns.SOUND_PRESETS[name]
    if candidates then
        for i = 1, #candidates do
            local id = kit[candidates[i]]
            if id then return id end
        end
        return nil
    end
    return kit[name]
end

--- Joue un son decrit par une valeur de configuration :
--   nombre        -> id de SOUNDKIT brut
--   chemin        -> fichier (contient \ ou / ou finit par .ogg/.mp3/.wav)
--   nom de preset -> ns.SOUND_PRESETS
--   nom de kit    -> SOUNDKIT[nom]
-- Retourne false si rien n'a pu etre joue, pour que l'appelant puisse le dire.
function ns.PlayAlertSound(sound, channel)
    if not sound then return false end
    channel = channel or "Master"

    if type(sound) == "number" then
        if not PlaySound then return false end
        return pcall(PlaySound, sound, channel) and true or false
    end

    if type(sound) ~= "string" then return false end

    if sound:find("[\\/]") or sound:lower():find("%.%a%a%a?$") then
        if not PlaySoundFile then return false end
        return pcall(PlaySoundFile, sound, channel) and true or false
    end

    local kit = ns.ResolveSoundKit(sound)
    if kit and PlaySound then
        return pcall(PlaySound, kit, channel) and true or false
    end

    -- Tout premiers clients : PlaySound prenait un nom de son, pas un id.
    if PlaySound then return pcall(PlaySound, sound, channel) and true or false end
    return false
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

--- Prefixe et nombre des unites de groupe (hors joueur) : "raid", N ou
-- "party", N-1. Un seul point de verite pour parcourir le groupe, quel que
-- soit le client.
function ns.GroupUnitPrefix()
    if ns.IsInRaidGroup() then return "raid", ns.GetNumGroupMembers() end
    local members = ns.GetNumGroupMembers()
    return "party", math.max(0, members - 1)
end

--- Canal de messages addon du groupe courant : "INSTANCE_CHAT" (groupe
-- d'instance / LFG, retail), "RAID", "PARTY", ou nil hors groupe.
function ns.GetGroupChannel()
    if _G.IsInGroup and _G.LE_PARTY_CATEGORY_INSTANCE
        and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    end
    if ns.IsInRaidGroup() then return "RAID" end
    if ns.GetNumGroupMembers() > 1 then return "PARTY" end
    return nil
end

--------------------------------------------------------------------------------
-- Combat et instance
--------------------------------------------------------------------------------
-- Ce qui permet de distinguer un wipe d'une simple sortie de combat : en donjon
-- ou en raid, on est mort mais le groupe se bat toujours ; sur un world boss,
-- on peut sortir de combat sans que le boss soit reset.

ns.UnitAffectingCombat = _G.UnitAffectingCombat or function() return false end

-- IsEncounterInProgress n'existe pas sur les clients les plus anciens : nil
-- signifie "le client ne sait pas", jamais "pas de rencontre en cours".
ns.IsEncounterInProgress = _G.IsEncounterInProgress

--- Groupe en combat ? Le joueur d'abord (le cas le plus frequent), puis chaque
-- membre : tant qu'un seul se bat, la rencontre n'est pas finie.
function ns.IsGroupInCombat()
    if ns.UnitAffectingCombat("player") then return true end
    local prefix, count = ns.GroupUnitPrefix()
    for i = 1, count do
        if ns.UnitAffectingCombat(prefix .. i) then return true end
    end
    return false
end

--- Forme unique : name, instanceType ("none"/"party"/"raid"/"pvp"/"arena"/
-- "scenario"), difficultyId, difficultyName, instanceId.
-- GetInstanceInfo manque sur les tout premiers builds : on retombe sur
-- IsInInstance, qui ne connait ni la difficulte ni l'id.
function ns.GetInstanceInfo()
    if _G.GetInstanceInfo then
        local name, instanceType, difficultyId, difficultyName, _, _, _, instanceId =
            GetInstanceInfo()
        return name, instanceType or "none", difficultyId or 0, difficultyName, instanceId or 0
    end
    local inInstance, instanceType = false, "none"
    if _G.IsInInstance then
        inInstance, instanceType = IsInInstance()
    end
    local name = (_G.GetRealZoneText and GetRealZoneText()) or "?"
    return name, (inInstance and instanceType) or "none", 0, nil, 0
end

--- Nature du contenu ou se trouve le joueur : "raid", "dungeon" ou "world".
-- Sert de valeur par defaut quand une entree de data ne precise pas `kind`.
function ns.GetContentKind()
    local _, instanceType = ns.GetInstanceInfo()
    if instanceType == "raid" then return "raid" end
    if instanceType == "party" then return "dungeon" end
    return "world"
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
    -- Sans UnitCastingInfo, l'incantation d'une cible ne se lit que dans le
    -- combat log : le module interrupt bascule sur ce repli.
    unitCastInfo        = _G.UnitCastingInfo ~= nil,
    nativeTimers        = hasNativeTimer,
    -- Le parry haste (swing en cours ampute) n'existe plus en retail.
    parryHaste          = not ns.isRetail,
    -- IsEncounterInProgress : le client sait dire si un boss est engage, ce
    -- qui rend la detection de wipe fiable meme quand tout le groupe est mort.
    encounterProgress   = _G.IsEncounterInProgress ~= nil,
    instanceInfo        = _G.GetInstanceInfo ~= nil,
    -- Unites nameplate1..40 : en classic c'est souvent le seul moyen de lire la
    -- vie d'un boss qu'on ne cible pas.
    namePlateUnits      = ns.EventExists("NAME_PLATE_UNIT_ADDED"),
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
