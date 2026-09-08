-- Modules/MoveAlert/MoveAlert.lua
-- Alerte "MOVE" facon GTFO : tu es dans quelque chose ou tu ne devrais pas
-- etre, sors-en.
--
-- GTFO s'appuie sur une base de donnees de sorts maintenue a la main. On ne
-- peut pas la reprendre (licence, et elle ne couvre pas les six flavors), donc
-- la detection repose sur une heuristique explicite, plus une liste
-- personnelle qui se remplit toute seule :
--
--   1. degats PERIODIQUES subis sans debuff correspondant sur toi  -> zone au
--      sol. C'est le coeur : un DoT est une aura que tu portes, et s'ecarter
--      n'y change rien ; une zone tape sans rien poser sur toi.
--   2. degats d'environnement (feu, lave, slime)                  -> zone.
--   3. tout sort present dans ta liste personnelle                -> zone,
--      des le premier tick, degats directs compris.
--
-- Les sorts rencontres en 1 et 2 sont memorises dans le profil : la seconde
-- rencontre alerte immediatement, sans attendre le seuil.

local _, ns = ...

local Alerts = ns.Alerts

-- Remplie par les fichiers de Data/, charges apres ce fichier : les zones
-- etablies statistiquement sur des logs (voir tools/wcl-ingest/wcl_alerts.py).
-- Elle complete l'heuristique, elle ne la remplace pas : rien ne garantit
-- qu'un raid, un donjon ou un patch recent soit couvert.
ns.MoveAlertData = ns.MoveAlertData or {}

local MoveAlertData = ns.MoveAlertData

local M = ns:NewModule("moveAlert", {
    enabled       = true,
    threshold     = 0.02,   -- part des PV max sous laquelle un coup est ignore
    cooldown      = 2,      -- delai mini entre deux alertes pour le meme sort
    learn         = true,   -- memorise les zones rencontrees dans le profil
    environmental = true,   -- feu / lave / slime
    ignoreDebuffs = true,   -- un DoT n'est pas une zone : on ne peut pas en sortir
    spells        = {},     -- [spellId] = true — liste personnelle
    ignored       = {},     -- [spellId] = true — faux positifs mis de cote
    alert = Alerts.MakeDefaults({
        text      = "MOVE",
        color     = { 1, 0.25, 0.15 },
        fontSize  = 54,
        duration  = 1.5,
        soundName = "raidwarning",
    }),
})
M.title = "Alerte Move (GTFO)"

local ALERT_KEY  = "move"
local ANCHOR_KEY = "MoveAlert_Display"

--------------------------------------------------------------------------------
-- Sous-evenements retenus
--------------------------------------------------------------------------------

local PERIODIC_DAMAGE = {
    SPELL_PERIODIC_DAMAGE = true,
}

local DIRECT_DAMAGE = {
    SPELL_DAMAGE          = true,
    SPELL_BUILDING_DAMAGE = true,
    RANGE_DAMAGE          = true,
}

-- Types d'environnement dont on sort en bougeant. Noyade et fatigue en sont
-- volontairement absentes : l'alerte serait juste, mais permanente.
local ENVIRONMENT = {
    Fire  = "feu",
    Lava  = "lave",
    Slime = "slime",
    FIRE  = "feu",
    LAVA  = "lave",
    SLIME = "slime",
}

--------------------------------------------------------------------------------
-- Etat
--------------------------------------------------------------------------------

local playerGUID
local lastAlert = {}   -- [cle] = timestamp de la derniere alerte

--------------------------------------------------------------------------------
-- Liste personnelle
--------------------------------------------------------------------------------

--- Dans TA liste (apprise ou ajoutee a la main).
function M:IsKnown(spellId)
    local config = self:GetConfig()
    return config and config.spells[spellId] == true
end

--- Dans ta liste OU dans la data livree : les deux alertent des le premier coup.
function M:IsListed(spellId)
    if MoveAlertData[spellId] ~= nil then return true end
    return self:IsKnown(spellId)
end

function M:CountData()
    local n = 0
    for _ in pairs(MoveAlertData) do n = n + 1 end
    return n
end

function M:ListData()
    local out = {}
    for spellId in pairs(MoveAlertData) do out[#out + 1] = spellId end
    table.sort(out)
    return out
end

function M:Learn(spellId)
    local config = self:GetConfig()
    if not config or not config.learn or not spellId then return false end
    if config.spells[spellId] then return false end
    config.spells[spellId] = true
    self:Debug("zone memorisee :", spellId, ns.GetSpellName(spellId) or "?")
    return true
end

function M:Forget(spellId)
    local config = self:GetConfig()
    if not config or not config.spells[spellId] then return false end
    config.spells[spellId] = nil
    return true
end

--- Met un sort de cote : il ne declenchera plus rien et ne sera plus reappris.
function M:Ignore(spellId)
    local config = self:GetConfig()
    if not config or not spellId then return false end
    config.ignored[spellId] = true
    config.spells[spellId] = nil
    return true
end

function M:Unignore(spellId)
    local config = self:GetConfig()
    if not config or not config.ignored[spellId] then return false end
    config.ignored[spellId] = nil
    return true
end

function M:ListSpells()
    local config = self:GetConfig()
    local out = {}
    if not config then return out end
    for spellId in pairs(config.spells) do out[#out + 1] = spellId end
    table.sort(out)
    return out
end

function M:ListIgnored()
    local config = self:GetConfig()
    local out = {}
    if not config then return out end
    for spellId in pairs(config.ignored) do out[#out + 1] = spellId end
    table.sort(out)
    return out
end

--------------------------------------------------------------------------------
-- Declenchement
--------------------------------------------------------------------------------

--- Un tick de zone dure plusieurs secondes : sans throttle par source, l'alerte
-- rejouerait son son a chaque tick.
function M:Throttled(key, cooldown)
    local now = GetTime()
    local last = lastAlert[key]
    if last and now - last < cooldown then return true end
    lastAlert[key] = now
    return false
end

function M:Trigger(key, label, icon, amount)
    local config = self:GetConfig()
    if not config then return false end
    if self:Throttled(key, tonumber(config.cooldown) or 2) then return false end

    local subtitle = label
    if amount and amount > 0 then
        subtitle = ("%s  |cffff8080-%d|r"):format(label, amount)
    end

    Alerts:Show(ALERT_KEY, { subtitle = subtitle, icon = icon })
    ns.EventBus:Fire("MOVE_ALERT", key, label, amount)
    return true
end

--------------------------------------------------------------------------------
-- Combat log — chemin chaud
--------------------------------------------------------------------------------
-- Filtre le plus selectif en premier : la quasi-totalite des lignes du combat
-- log ne te concerne pas comme destinataire.

local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

function M:MinimumAmount(config)
    local max = UnitHealthMax("player")
    if not max or max <= 0 then return 1 end
    return max * (tonumber(config.threshold) or 0)
end

--- Coeur de l'heuristique. `periodic` distingue un tick de zone d'un coup
-- direct : un coup direct n'alerte que s'il est deja dans ta liste, sinon la
-- moindre attaque de boss ferait hurler l'addon.
function M:OnDamage(spellId, spellName, amount, periodic)
    local config = self:GetConfig()
    if not config or not spellId then return false end
    if config.ignored[spellId] then return false end

    -- La data livree vaut liste personnelle : elle a deja fait la preuve
    -- statistique que l'heuristique tente de refaire a chaque tick.
    local known = config.spells[spellId] == true or MoveAlertData[spellId] ~= nil
    if not known then
        if not periodic then return false end
        if (amount or 0) < self:MinimumAmount(config) then return false end
        -- Un DoT est une aura que tu portes : bouger n'y change rien. Une zone
        -- au sol tape sans rien poser sur toi. C'est ce qui separe les deux.
        if config.ignoreDebuffs and ns.FindAura("player", spellId, "HARMFUL") then
            return false
        end
        self:Learn(spellId)
    end

    return self:Trigger(spellId, spellName or ns.GetSpellName(spellId) or "?",
        ns.GetSpellTexture(spellId), amount)
end

function M:OnEnvironmental(kind, amount)
    local config = self:GetConfig()
    if not config or config.environmental == false then return false end
    local label = ENVIRONMENT[kind]
    if not label then return false end
    if (amount or 0) < self:MinimumAmount(config) then return false end
    return self:Trigger("env:" .. kind, label, nil, amount)
end

local function OnCombatLog()
    local _, sub, _, _, _, _, _, dstGUID, _, _, _, p12, p13, _, p15 =
        CombatLogGetCurrentEventInfo()

    if dstGUID ~= playerGUID then return end
    if _G.UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return end

    if PERIODIC_DAMAGE[sub] then
        M:OnDamage(p12, p13, p15, true)
    elseif DIRECT_DAMAGE[sub] then
        M:OnDamage(p12, p13, p15, false)
    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        -- Signature differente : pas de spellId, l'environnement prend sa place.
        M:OnEnvironmental(p12, p13)
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function M:PLAYER_ENTERING_WORLD()
    playerGUID = UnitGUID("player")
end

function M:PLAYER_REGEN_ENABLED()
    -- Hors combat, plus rien ne doit rester affiche ni bloquer un throttle.
    wipe(lastAlert)
    Alerts:Hide(ALERT_KEY)
end

--------------------------------------------------------------------------------
-- Etat lisible (/mbs move)
--------------------------------------------------------------------------------

function M:StatusLines()
    local config = self:GetConfig() or {}
    return {
        ("seuil : %.0f%% des PV max   throttle : %ss")
            :format((tonumber(config.threshold) or 0) * 100, tostring(config.cooldown)),
        ("apprentissage : %s   environnement : %s   DoT ignores : %s"):format(
            config.learn ~= false and "oui" or "non",
            config.environmental ~= false and "oui" or "non",
            config.ignoreDebuffs ~= false and "oui" or "non"),
        ("zones : %d livrees + %d apprises   ignorees : %d")
            :format(self:CountData(), #self:ListSpells(), #self:ListIgnored()),
    }
end

--------------------------------------------------------------------------------
-- Cycle de vie
--------------------------------------------------------------------------------

function M:OnInitialize()
    Alerts:Register(ALERT_KEY, {
        anchorKey    = ANCHOR_KEY,
        label        = "Alerte Move",
        order        = 20,
        defaultPoint = { "CENTER", "UIParent", "CENTER", 0, 260 },
        getConfig    = function()
            local config = self:GetConfig()
            return config and config.alert
        end,
        defaults = ns.PROFILE_DEFAULTS.modules.moveAlert.alert,
    })
end

function M:OnEnable()
    playerGUID = UnitGUID("player")
    wipe(lastAlert)
    self:RegisterRawEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
end

function M:OnDisable()
    Alerts:Hide(ALERT_KEY)
    self:UnregisterAllEvents()
    self:UnregisterAllMessages()
    self:CancelAllTimers()
    wipe(lastAlert)
end
