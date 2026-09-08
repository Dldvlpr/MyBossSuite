-- Modules/SwingTimer/SwingTimer.lua
-- Zero data externe : le module reste juste le jour d'un patch.
--
-- Deux pistes :
--   * joueur — duree exacte via UnitAttackSpeed (talents, haste, procs inclus) ;
--   * cible  — duree mesuree entre deux swings, recalculee a chaque coup
--     (enrage, buffs, slows), jamais stockee en dur.

local _, ns = ...

local M = ns:NewModule("swingTimer", {
    enabled     = true,
    showPlayer  = true,
    showTarget  = true,
})
M.title = "Swing Timer"

local Bars   = ns.Bars
local GetTime = GetTime

local PLAYER_ANCHOR = "SwingTimer_Bar"
local TARGET_ANCHOR = "SwingTimer_TargetBar"

local PLAYER_COLOR = { 0.2, 0.7, 0.3 }
local TARGET_COLOR = { 0.8, 0.35, 0.2 }

-- Duree affichee tant qu'aucun delta n'a ete mesure : marquee `variable`, donc
-- grisee et prefixee "~". Une bar de calibration vaut mieux que rien, qui a
-- l'air casse.
local CALIBRATION_GUESS = 2.0

--------------------------------------------------------------------------------
-- Etat
--------------------------------------------------------------------------------

local playerGUID
local targetGUID          -- unite suivie par la bar "cible"
local lastSwing = {}      -- [guid] = timestamp du dernier swing
local swingSpeed = {}     -- [guid] = duree mesuree

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

function M:GetPlayerGroup()
    if not self.playerGroup then
        self.playerGroup = Bars:GetGroup(PLAYER_ANCHOR, {
            label        = "Swing Timer (joueur)",
            width        = 200,
            height       = 16,
            color        = PLAYER_COLOR,
            defaultPoint = { "CENTER", "UIParent", "CENTER", 0, -140 },
            test = function(group)
                Bars:TestBar(group, PLAYER_ANCHOR, 2.6, "Main Hand", nil, PLAYER_COLOR)
            end,
        })
    end
    return self.playerGroup
end

function M:GetTargetGroup()
    if not self.targetGroup then
        self.targetGroup = Bars:GetGroup(TARGET_ANCHOR, {
            label        = "Swing Timer (cible)",
            width        = 200,
            height       = 16,
            color        = TARGET_COLOR,
            defaultPoint = { "CENTER", "UIParent", "CENTER", 0, -162 },
            test = function(group)
                Bars:TestBar(group, TARGET_ANCHOR, 2.0, "Cible", nil, TARGET_COLOR)
            end,
        })
    end
    return self.targetGroup
end

function M:StartPlayerBar(duration, variable)
    local config = self:GetConfig()
    if not config.showPlayer then return end
    local group = self:GetPlayerGroup()
    group:StartBar(PLAYER_ANCHOR, duration, "Main Hand", nil, {
        color    = PLAYER_COLOR,
        variable = variable,
    })
end

function M:StartTargetBar(duration, variable)
    local config = self:GetConfig()
    if not config.showTarget then return end
    local group = self:GetTargetGroup()
    local name = (targetGUID and UnitExists("target") and UnitGUID("target") == targetGUID
        and UnitName("target")) or "Cible"
    group:StartBar(TARGET_ANCHOR, duration, name, nil, {
        color    = TARGET_COLOR,
        variable = variable,
    })
end

--- Parry haste (classic uniquement) : l'unite qui PARE voit son propre swing en
-- cours ampute de 40% de sa duree d'attaque, sans jamais descendre sous 20% du
-- restant total. Sans ca, le delta glissant est faux apres chaque parade — et en
-- tank il y en a beaucoup.
local function ApplyParryHaste(group, id)
    local bar = group:GetBar(id)
    if not bar then return end
    local remaining = bar:GetRemaining()
    local duration  = bar.duration
    local floorTime = duration * 0.2
    if remaining <= floorTime then return end
    bar:SetRemaining(math.max(remaining - duration * 0.4, floorTime))
end

--------------------------------------------------------------------------------
-- Combat log — chemin chaud
--------------------------------------------------------------------------------
-- Locals hisses, early-return sur le subevent en premier (comparaison de string,
-- la moins chere), aucune allocation de table dans le handler.

local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

local function OnCombatLog()
    local _, sub, _, srcGUID, _, _, _, dstGUID, _, _, _, missType = CombatLogGetCurrentEventInfo()

    -- SWING_DAMAGE_LANDED existe en retail et double-compterait : le test strict
    -- sur l'egalite le gere, un find("SWING") non.
    local isDamage = (sub == "SWING_DAMAGE")
    if not isDamage and sub ~= "SWING_MISSED" then return end

    if not isDamage and missType == "PARRY" and ns.has.parryHaste then
        -- dstGUID est l'unite qui a pare : c'est SON swing qui est raccourci.
        if dstGUID == playerGUID then
            ApplyParryHaste(M:GetPlayerGroup(), PLAYER_ANCHOR)
        elseif dstGUID == targetGUID then
            ApplyParryHaste(M:GetTargetGroup(), TARGET_ANCHOR)
        end
    end

    if srcGUID == playerGUID then
        local speed = UnitAttackSpeed("player")
        if not speed or speed <= 0 then
            speed = swingSpeed[srcGUID] or CALIBRATION_GUESS
        end
        lastSwing[srcGUID] = GetTime()
        M:StartPlayerBar(speed, false)
        return
    end

    if srcGUID == targetGUID then
        local now  = GetTime()
        local last = lastSwing[srcGUID]
        lastSwing[srcGUID] = now
        if last then
            local delta = now - last
            -- Un ecart absurde (changement de cible, sortie de combat) ne doit
            -- pas polluer la mesure.
            if delta > 0.4 and delta < 10 then
                swingSpeed[srcGUID] = delta
            end
        end
        local measured = swingSpeed[srcGUID]
        M:StartTargetBar(measured or CALIBRATION_GUESS, measured == nil)
    end
end

--------------------------------------------------------------------------------
-- Suivi de la cible
--------------------------------------------------------------------------------
-- Alimentation explicite de l'unite suivie : cible du joueur par defaut, GUID du
-- boss si le module BossTimer est actif et a detecte un engage.

function M:SetTrackedUnit(guid)
    if guid == targetGUID then return end
    targetGUID = guid
    self:GetTargetGroup():StopBar(TARGET_ANCHOR)
    if guid then
        local measured = swingSpeed[guid]
        if measured then self:StartTargetBar(measured, false) end
    end
end

function M:PLAYER_TARGET_CHANGED()
    if self.lockedToBoss and UnitExists("boss1") then return end
    self:SetTrackedUnit(UnitExists("target") and UnitGUID("target") or nil)
end

function M:PLAYER_REGEN_DISABLED()
    playerGUID = UnitGUID("player")
end

function M:PLAYER_REGEN_ENABLED()
    -- Hors combat, les deltas mesures n'ont plus de sens.
    for guid in pairs(lastSwing) do lastSwing[guid] = nil end
    self:GetPlayerGroup():StopBar(PLAYER_ANCHOR)
    self:GetTargetGroup():StopBar(TARGET_ANCHOR)
end

--------------------------------------------------------------------------------
-- Cycle de vie
--------------------------------------------------------------------------------

function M:OnInitialize()
    playerGUID = UnitGUID("player")
    self:GetPlayerGroup()
    self:GetTargetGroup()
end

function M:OnEnable()
    playerGUID = UnitGUID("player")
    self:RegisterRawEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterMessage("BOSS_ENGAGED", function(_, _, guid)
        if not guid then return end
        self.lockedToBoss = true
        self:SetTrackedUnit(guid)
    end)
    self:RegisterMessage("BOSS_DISENGAGED", function()
        self.lockedToBoss = false
        self:PLAYER_TARGET_CHANGED()
    end)
    self:PLAYER_TARGET_CHANGED()
end

function M:OnDisable()
    self:UnregisterAllEvents()
    self:UnregisterAllMessages()
    self:CancelAllTimers()
    if self.playerGroup then self.playerGroup:StopAll() end
    if self.targetGroup then self.targetGroup:StopAll() end
    targetGUID = nil
    self.lockedToBoss = false
end
