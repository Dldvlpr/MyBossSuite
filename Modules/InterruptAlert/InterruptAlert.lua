-- Modules/InterruptAlert/InterruptAlert.lua
-- Alerte "KICK" quand la cible (ou le focus) lance un sort interruptible ET que
-- TON interrupt est reellement disponible.
--
-- Le point qui fait la difference entre une alerte utile et un clignotant qu'on
-- finit par ignorer : les trois conditions sont verifiees ensemble, en continu
-- pendant l'incantation. Un kick qui revient de cooldown au milieu du cast
-- declenche l'alerte, et un cast protege (`notInterruptible`) n'en declenche
-- jamais.

local _, ns = ...

local Alerts = ns.Alerts

-- Remplie par les fichiers de Data/, chargés après ce fichier : les sorts dont
-- un log prouve qu'ils ont ete interrompus dans cette version du jeu.
ns.InterruptableData = ns.InterruptableData or {}

local InterruptableData = ns.InterruptableData

local M = ns:NewModule("interruptAlert", {
    enabled       = true,
    watchFocus    = true,    -- surveille aussi le focus
    onlyWhenReady = true,    -- n'alerte que si ton kick est dispo
    checkRange    = true,    -- ... et que la cible est a portee
    dataOnly      = false,   -- repli combat log : n'alerter que sur la data
    spellId       = nil,     -- override manuel du sort d'interruption
    alert = Alerts.MakeDefaults({
        text      = "KICK",
        color     = { 0.25, 0.85, 1 },
        fontSize  = 48,
        duration  = 1.5,
        soundName = "alarm",
    }),
})
M.title = "Alerte Kick"

local ALERT_KEY  = "kick"
local ANCHOR_KEY = "InterruptAlert_Display"

-- 0.15s : assez fin pour attraper la fin d'un cooldown au milieu d'un cast,
-- assez lache pour ne rien couter. Le ticker ne tourne que pendant une
-- incantation surveillee.
local POLL_INTERVAL = 0.15

-- Duree de vie d'une incantation deduite du combat log, quand le client ne sait
-- pas repondre a UnitCastingInfo sur une unite hostile. Aucun sort de boss ne
-- s'incante plus longtemps sans que SPELL_CAST_SUCCESS ne tombe.
local FALLBACK_CAST_MAX = 6

--------------------------------------------------------------------------------
-- Sorts d'interruption
--------------------------------------------------------------------------------
-- Table par classe, plusieurs ids par classe : le bon est celui que le joueur
-- connait reellement (`ns.KnowsSpell` couvre aussi les rangs classic). Un
-- override manuel reste possible via /mbs kick spell <id>, pour les cas que la
-- table ne couvre pas (interrupt de familier, sort de talent exotique).

local INTERRUPTS = {
    WARRIOR     = { 6552, 72 },                   -- Pummel, Shield Bash
    ROGUE       = { 1766 },                       -- Kick
    MAGE        = { 2139 },                       -- Counterspell
    SHAMAN      = { 57994, 8042 },                -- Wind Shear, Earth Shock
    PRIEST      = { 15487 },                      -- Silence
    DRUID       = { 106839, 80965, 16979 },       -- Skull Bash, Feral Charge
    PALADIN     = { 96231, 31935 },               -- Rebuke, Avenger's Shield
    DEATHKNIGHT = { 47528, 47476 },               -- Mind Freeze, Strangulate
    HUNTER      = { 147362, 187707, 34490 },      -- Counter Shot, Muzzle, Silencing Shot
    WARLOCK     = { 19647, 119910, 132409 },      -- Spell Lock (familier)
    MONK        = { 116705 },                     -- Spear Hand Strike
    DEMONHUNTER = { 183752 },                     -- Disrupt
    EVOKER      = { 351338 },                     -- Quell
}

M.INTERRUPTS = INTERRUPTS

-- Partagee avec le CD Tracker : quels sorts d'interruption existent par classe
-- est un fait, pas une affaire de module. Le publier ici evite d'en tenir deux
-- copies qui divergeront — et le CD Tracker n'a pas a dependre de l'existence
-- du module d'alerte kick pour autant.
ns.InterruptSpells = INTERRUPTS

function M:ResolveInterrupt()
    local config = self:GetConfig()

    local override = config and config.spellId
    if override then
        self.interruptSpell = override
        self.interruptName  = ns.GetSpellName(override) or tostring(override)
        return self.interruptSpell
    end

    local _, class = UnitClass("player")
    local candidates = INTERRUPTS[class or ""]
    self.interruptSpell = nil
    self.interruptName  = nil

    if not candidates then return nil end
    for i = 1, #candidates do
        local spellId = candidates[i]
        if ns.KnowsSpell(spellId) then
            self.interruptSpell = spellId
            self.interruptName  = ns.GetSpellName(spellId)
            self:Debug("interrupt detecte :", self.interruptName, spellId)
            return spellId
        end
    end

    self:Debug("aucun interrupt connu pour la classe", tostring(class))
    return nil
end

--- Le kick est-il utilisable maintenant ? nil = pas d'interrupt connu.
function M:InterruptRemaining()
    if not self.interruptSpell then return nil end
    return ns.GetSpellRemaining(self.interruptSpell)
end

--------------------------------------------------------------------------------
-- Incantations lues dans le combat log
--------------------------------------------------------------------------------
-- Repli pour les clients ou UnitCastingInfo ne repond rien sur une unite
-- hostile. Le combat log ne dit pas si le sort est protege : on assume
-- interruptible plutot que de rater le kick. Une alerte de trop se voit, un kick
-- manque ne se voit pas.

local casts = {}   -- [guid] = { name, icon, spellId, expires }

local function ClearCast(guid)
    if guid then casts[guid] = nil end
end

function M:FallbackCast(guid)
    local cast = guid and casts[guid]
    if not cast then return nil end
    if GetTime() > cast.expires then
        casts[guid] = nil
        return nil
    end
    return cast.name, cast.icon, cast.spellId
end

local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

--- GUID des unites surveillees, mis a jour sur changement de cible / focus.
-- Le combat log les compare directement : aucun appel d'API dans le chemin
-- chaud, et la table `casts` ne peut pas grossir au-dela de deux entrees.
function M:UpdateWatchedGUIDs()
    local config = self:GetConfig()
    self.targetGUID = UnitExists("target") and UnitGUID("target") or nil
    self.focusGUID  = (config and config.watchFocus ~= false)
        and UnitExists("focus") and UnitGUID("focus") or nil

    -- Une incantation retenue pour une unite qu'on ne surveille plus n'a plus
    -- de raison d'exister : sans ca, retargeter la meme unite dans les six
    -- secondes ressortirait un cast deja termine.
    for guid in pairs(casts) do
        if guid ~= self.targetGUID and guid ~= self.focusGUID then
            casts[guid] = nil
        end
    end
end

local function OnCombatLog()
    local _, sub, _, srcGUID, _, _, _, dstGUID, _, _, _, spellId, spellName =
        CombatLogGetCurrentEventInfo()

    if sub == "SPELL_CAST_START" then
        if srcGUID ~= M.targetGUID and srcGUID ~= M.focusGUID then return end
        casts[srcGUID] = {
            name    = spellName or ns.GetSpellName(spellId) or "?",
            icon    = ns.GetSpellTexture(spellId),
            spellId = spellId,
            expires = GetTime() + FALLBACK_CAST_MAX,
        }
        M:Wake()
    elseif sub == "SPELL_CAST_SUCCESS" or sub == "SPELL_CAST_FAILED" then
        if casts[srcGUID] then
            ClearCast(srcGUID)
            M:Evaluate()
        end
    elseif sub == "SPELL_INTERRUPT" then
        -- dstGUID : c'est l'unite interrompue, pas l'interrupteur.
        if casts[dstGUID] then ClearCast(dstGUID) end
        M:Evaluate()
    elseif sub == "UNIT_DIED" then
        ClearCast(dstGUID)
    end
end

--------------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------------

local WATCH_UNITS = { "target", "focus" }

local function CanAttackUnit(unit)
    if _G.UnitCanAttack and not UnitCanAttack("player", unit) then return false end
    if _G.UnitIsDead and UnitIsDead(unit) then return false end
    return true
end

--- Ce sort est-il prouve interruptible par les logs ? nil = inconnu de la data,
-- ce qui ne veut pas dire "protege" : la data est partielle par construction.
function M:IsKnownInterruptible(spellId)
    return InterruptableData[spellId]
end

function M:CountData()
    local n = 0
    for _ in pairs(InterruptableData) do n = n + 1 end
    return n
end

function M:ListData()
    local out = {}
    for spellId in pairs(InterruptableData) do out[#out + 1] = spellId end
    table.sort(out)
    return out
end

--- Premiere incantation interruptible trouvee sur les unites surveillees.
-- Retourne unit, name, icon, spellId.
--
-- Deux sources, dans cet ordre strict :
--   1. l'API du client (`notInterruptible`) — elle sait, elle fait foi, et la
--      data ne peut jamais la contredire ;
--   2. le combat log, la ou l'API ne repond rien sur une unite hostile. Le log
--      ne dit pas si le sort est protege : la data tranche quand elle connait le
--      sort, sinon on assume interruptible (ou on se tait, avec `dataOnly`).
function M:FindCast(config)
    for i = 1, #WATCH_UNITS do
        local unit = WATCH_UNITS[i]
        if (unit ~= "focus" or config.watchFocus ~= false)
            and UnitExists(unit) and CanAttackUnit(unit) then

            local name, icon, _, _, notInterruptible, spellId = ns.GetCastInfo(unit)
            if name then
                if not notInterruptible then
                    return unit, name, icon or (spellId and ns.GetSpellTexture(spellId)),
                        spellId, false
                end
            else
                local fallbackName, fallbackIcon, fallbackSpell = self:FallbackCast(UnitGUID(unit))
                if fallbackName then
                    local proven = InterruptableData[fallbackSpell] ~= nil
                    if proven or config.dataOnly ~= true then
                        return unit, fallbackName,
                            fallbackIcon or (fallbackSpell and ns.GetSpellTexture(fallbackSpell)),
                            fallbackSpell, not proven
                    end
                end
            end
        end
    end
    return nil
end

function M:InRange(unit)
    if not self.interruptName or not ns.IsSpellInRange then return true end
    -- 0 = hors de portee, 1 = a portee, nil = le client ne sait pas repondre :
    -- seul le 0 franc bloque l'alerte.
    return ns.IsSpellInRange(self.interruptName, unit) ~= 0
end

function M:Evaluate()
    if not self.isEnabled then return end
    local config = self:GetConfig()
    if not config then return end

    if _G.UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
        self:ClearAlert()
        return self:Sleep()
    end

    local unit, name, icon, spellId, assumed = self:FindCast(config)
    if not unit then
        self:ClearAlert()
        return self:Sleep()
    end

    -- Une incantation est en cours : le ticker tourne, meme sans alerte
    -- affichee, pour attraper la fin du cooldown ou l'entree en portee. C'est
    -- lui qui rattrape ce qu'aucun event ne signale.
    self:EnsurePolling()

    local remaining = self:InterruptRemaining()
    local ready = (remaining ~= nil and remaining <= 0)

    if config.onlyWhenReady ~= false and not ready then
        return self:ClearAlert()
    end
    if config.checkRange ~= false and not self:InRange(unit) then
        return self:ClearAlert()
    end

    self:ShowAlert(unit, name, icon, spellId, assumed, self:RotationHolder(unit, spellId))
end

--- Le joueur a qui la rotation d'interrupt donne ce kick, ou nil : module de
-- rotation absent ou eteint, aucune rotation possible, ou c'est ton tour.
-- Le couplage ne va que dans ce sens : sans le module de rotation, l'alerte est
-- exactement celle de toujours.
function M:RotationHolder(unit, spellId)
    local rotation = ns:GetModule("interruptRotation")
    if not rotation or not rotation.isEnabled or not rotation.Holder then return nil end
    return rotation:Holder(unit .. "|" .. tostring(spellId))
end

-- Le tour de quelqu'un d'autre s'affiche gris, sans son ni flash.
local HOLD_COLOR = { 0.55, 0.55, 0.6 }

--- Une signature par incantation : le meme cast ne doit pas rejouer le son ni
-- reflasher a chaque tick du ticker. Le tour en fait partie — quand la rotation
-- rend la main au milieu de l'incantation, l'alerte doit repasser en KICK.
function M:ShowAlert(unit, name, icon, spellId, assumed, holder)
    local signature = unit .. "|" .. tostring(spellId or name) .. "|" .. tostring(holder)
    if self.showing == signature then return end
    self.showing = signature

    -- Le point d'interrogation dit la verite : l'incantation vient du combat
    -- log, rien ne prouve qu'elle soit interruptible.
    local subtitle = assumed and (name .. " |cffaaaaaa(?)|r") or name

    if holder then
        -- On n'efface pas l'incantation pour autant : le joueur designe peut
        -- etre mort, silence ou hors de portee. La rotation rend la main d'elle
        -- meme au bout de son delai, et l'alerte redevient un KICK franc.
        Alerts:Show(ALERT_KEY, {
            sticky   = true,
            icon     = icon,
            text     = "ATTENDS",
            color    = HOLD_COLOR,
            subtitle = ("%s |cffaaaaaa— au tour de %s|r"):format(subtitle, holder),
            silent   = true,
            quiet    = true,
        })
    else
        Alerts:Show(ALERT_KEY, { sticky = true, icon = icon, subtitle = subtitle })
    end

    ns.EventBus:Fire("INTERRUPT_ALERT", unit, spellId, name, holder)
end

function M:ClearAlert()
    if not self.showing then return end
    self.showing = nil
    Alerts:Hide(ALERT_KEY)
end

--------------------------------------------------------------------------------
-- Ticker
--------------------------------------------------------------------------------

function M:EnsurePolling()
    if self.polling or not self.isEnabled then return end
    self.polling = true
    self:Repeat("poll", POLL_INTERVAL, function() self:Evaluate() end)
end

function M:Wake()
    if not self.isEnabled then return end
    self:EnsurePolling()
    self:Evaluate()
end

function M:Sleep()
    if not self.polling then return end
    self.polling = false
    self:CancelTimer("poll")
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function IsWatched(unit)
    return unit == "target" or unit == "focus"
end

function M:UNIT_SPELLCAST_START(_, unit)
    if IsWatched(unit) then self:Wake() end
end

M.UNIT_SPELLCAST_CHANNEL_START     = M.UNIT_SPELLCAST_START
M.UNIT_SPELLCAST_DELAYED           = M.UNIT_SPELLCAST_START
M.UNIT_SPELLCAST_INTERRUPTIBLE     = M.UNIT_SPELLCAST_START
M.UNIT_SPELLCAST_NOT_INTERRUPTIBLE = M.UNIT_SPELLCAST_START

function M:UNIT_SPELLCAST_STOP(_, unit)
    if not IsWatched(unit) then return end
    -- Le client a vu la fin de l'incantation : l'entree du repli combat log
    -- pour cette unite n'a plus lieu d'etre. Sans ca, un cast de PNJ annule par
    -- un stun ou la mort de sa cible (SPELL_CAST_FAILED n'est jamais logge pour
    -- un PNJ) ressortirait en alerte fantome jusqu'a FALLBACK_CAST_MAX.
    ClearCast(UnitGUID(unit))
    self:Evaluate()
end

M.UNIT_SPELLCAST_CHANNEL_STOP = M.UNIT_SPELLCAST_STOP
M.UNIT_SPELLCAST_SUCCEEDED    = M.UNIT_SPELLCAST_STOP
M.UNIT_SPELLCAST_INTERRUPTED  = M.UNIT_SPELLCAST_STOP
M.UNIT_SPELLCAST_FAILED       = M.UNIT_SPELLCAST_STOP

function M:PLAYER_TARGET_CHANGED()
    self:UpdateWatchedGUIDs()
    self:ClearAlert()
    self:Wake()
end

M.PLAYER_FOCUS_CHANGED = M.PLAYER_TARGET_CHANGED

function M:PLAYER_REGEN_ENABLED()
    self:ClearAlert()
    self:Sleep()
end

function M:SPELLS_CHANGED()
    self:ResolveInterrupt()
end

M.LEARNED_SPELL_IN_TAB = M.SPELLS_CHANGED

function M:PLAYER_ENTERING_WORLD()
    -- Changement de zone : le grimoire peut avoir change (spec, familier) et
    -- les unites surveillees sont a relire.
    self:ResolveInterrupt()
    self:UpdateWatchedGUIDs()
    self:Wake()
end

--------------------------------------------------------------------------------
-- Etat lisible (/mbs kick)
--------------------------------------------------------------------------------

function M:StatusLines()
    local config = self:GetConfig() or {}
    local remaining = self:InterruptRemaining()
    local spell = self.interruptSpell
        and ("%s (%d)"):format(self.interruptName or "?", self.interruptSpell)
        or "|cffff5555aucun detecte|r"
    return {
        "interrupt : " .. spell .. (config.spellId and " |cffaaaaaa(force)|r" or ""),
        ("disponible : %s"):format(
            remaining == nil and "?" or (remaining <= 0 and "oui" or ("dans %.1fs"):format(remaining))),
        ("focus : %s   portee : %s   kick dispo requis : %s"):format(
            config.watchFocus ~= false and "oui" or "non",
            config.checkRange ~= false and "oui" or "non",
            config.onlyWhenReady ~= false and "oui" or "non"),
        ("lecture des incantations : %s"):format(
            ns.has.unitCastInfo and "API du client (+ repli combat log)"
                or "combat log uniquement"),
        ("sorts interruptibles connus : %d   repli data seule : %s"):format(
            self:CountData(), config.dataOnly and "oui" or "non"),
    }
end

--------------------------------------------------------------------------------
-- Cycle de vie
--------------------------------------------------------------------------------

function M:OnInitialize()
    Alerts:Register(ALERT_KEY, {
        anchorKey    = ANCHOR_KEY,
        label        = "Alerte Kick",
        order        = 10,
        defaultPoint = { "CENTER", "UIParent", "CENTER", 0, 180 },
        getConfig    = function()
            local config = self:GetConfig()
            return config and config.alert
        end,
        defaults = ns.PROFILE_DEFAULTS.modules.interruptAlert.alert,
    })
end

function M:OnEnable()
    self:ResolveInterrupt()

    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("PLAYER_FOCUS_CHANGED")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("SPELLS_CHANGED")
    self:RegisterEvent("LEARNED_SPELL_IN_TAB")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")

    self:RegisterEvent("UNIT_SPELLCAST_START")
    self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    self:RegisterEvent("UNIT_SPELLCAST_DELAYED")
    self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTIBLE")
    self:RegisterEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE")
    self:RegisterEvent("UNIT_SPELLCAST_STOP")
    self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    self:RegisterEvent("UNIT_SPELLCAST_FAILED")

    -- Enregistre meme quand UnitCastingInfo existe : sur les clients les plus
    -- anciens l'API repond nil sur une unite hostile, et seul le combat log
    -- voit l'incantation. Le handler sort en deux comparaisons de string sinon.
    self:RegisterRawEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)

    self:UpdateWatchedGUIDs()
    self:Wake()
end

function M:OnDisable()
    self:ClearAlert()
    self:Sleep()
    self:UnregisterAllEvents()
    self:UnregisterAllMessages()
    self:CancelAllTimers()
    self.targetGUID, self.focusGUID = nil, nil
    wipe(casts)
end
