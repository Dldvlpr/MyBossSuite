-- Modules/BossTimer/BossTimer.lua
-- Moteur runtime du boss timer.
--
-- Detection d'engage : ENCOUNTER_START partout ou il existe (Cata Classic, MoP
-- Classic, retail — pas seulement retail), combat log en second filet, flag
-- `engaged` pour que les deux ne declenchent pas deux fois.

local _, ns = ...

local M = ns:NewModule("bossTimer", {
    enabled = true,
    sound   = true,
})
M.title = "Boss Timer"

local Bars      = ns.Bars
local Scheduler = ns.Scheduler
local EventBus  = ns.EventBus
local GetTime   = GetTime

-- Tables remplies par les fichiers de Data/, chargees apres ce fichier.
ns.BossTimerData      = ns.BossTimerData or {}
ns.BossTimerEncounter = ns.BossTimerEncounter or {}

local BossTimerData      = ns.BossTimerData
local BossTimerEncounter = ns.BossTimerEncounter

local GENERIC_ANCHOR = "BossTimer_GenericBar"
local BAR_COLOR      = { 0.25, 0.55, 0.9 }

local HEALTH_POLL_INTERVAL = 0.5

--------------------------------------------------------------------------------
-- Etat de pull
--------------------------------------------------------------------------------

M.engaged       = nil    -- npcId
M.bossGUID      = nil
M.castTriggers  = nil    -- [spellId] = timerDef, construit une fois a l'engage
M.healthTriggers = nil
M.pullTime      = 0

--------------------------------------------------------------------------------
-- Groupes de bars
--------------------------------------------------------------------------------

local function TestGenericBars(group)
    Bars:TestBar(group, "boss1", 12, "Flame Breath", nil, BAR_COLOR)
    Bars:TestBar(group, "boss2", 25, "Fireball Volley", nil, BAR_COLOR)
    Bars:TestBar(group, "boss3", 40, "Deep Breath", nil, { 0.8, 0.3, 0.8 })
end

function M:GetGroup(anchorKey)
    local isGeneric = (anchorKey == GENERIC_ANCHOR)
    return Bars:GetGroup(anchorKey, {
        label        = isGeneric and "Boss Timer" or anchorKey,
        width        = 240,
        height       = 18,
        color        = BAR_COLOR,
        defaultPoint = isGeneric and { "CENTER", "UIParent", "CENTER", 300, 0 } or nil,
        test         = isGeneric and TestGenericBars
            or function(group)
                Bars:TestBar(group, anchorKey, 20, anchorKey:match("(%d+)$") or "Alerte",
                    nil, BAR_COLOR)
            end,
    })
end

--- Cree les groupes correspondant aux overrides deja sauvegardes, pour qu'ils
-- soient deplacables en mode unlock meme hors combat.
function M:CreateSavedOverrideGroups()
    if not ns.db then return end
    for anchorKey in pairs(ns.db.anchors) do
        if anchorKey:sub(1, 16) == "BossTimer_Alert_" then
            self:GetGroup(anchorKey)
        end
    end
end

function M:ClearBars()
    for anchorKey, group in pairs(Bars.groups) do
        if anchorKey:sub(1, 10) == "BossTimer_" then group:StopAll() end
    end
end

--------------------------------------------------------------------------------
-- Affichage d'un timer
--------------------------------------------------------------------------------

local function TimerLabel(def)
    return def.name or (def.spellId and ns.GetSpellName(def.spellId)) or "?"
end

local function TimerIcon(def)
    if def.icon then return def.icon end
    if def.spellId then return ns.GetSpellTexture(def.spellId) end
    return nil
end

--- Affiche la bar qui compte a rebours jusqu'a la prochaine occurrence.
function M:ShowBar(def, duration)
    if def.bar == false or duration <= 0 then return end
    local anchorKey = ns:ResolveAnchorKey(def.spellId)
    local group = self:GetGroup(anchorKey)
    group:StartBar(def.key, duration, TimerLabel(def), TimerIcon(def), {
        color      = def.color or BAR_COLOR,
        warnBefore = def.warnBefore,
        -- Un timing mesure avec un fort ecart-type s'affiche comme incertain
        -- plutot que de mentir sur une precision qu'on n'a pas.
        variable   = def.variable,
    })
end

function M:StopBar(def)
    local group = Bars.groups[ns:ResolveAnchorKey(def.spellId)]
    if group then group:StopBar(def.key) end
end

--- Le moment ou la capacite tombe : on annonce, puis on reprogramme si le timer
-- se repete.
function M:FireTimer(def)
    if def.once and def.fired then return end
    def.fired = true

    EventBus:Fire("BOSS_TIMER_FIRED", def)

    local config = self:GetConfig()
    if config and config.sound and _G.PlaySound and _G.SOUNDKIT then
        PlaySound(SOUNDKIT.RAID_WARNING, "Master")
    end

    if def.repeatInterval and not def.once then
        self:ScheduleNext(def, def.repeatInterval)
    else
        self:StopBar(def)
    end
end

function M:ScheduleNext(def, delay)
    self:ShowBar(def, delay)
    Scheduler:Schedule("BossTimer_" .. def.key, delay, function()
        self:FireTimer(def)
    end)
end

--------------------------------------------------------------------------------
-- Engage / disengage
--------------------------------------------------------------------------------

local function BuildLookups(def)
    local castTriggers, healthTriggers = {}, {}
    for i = 1, #def.timers do
        local timer = def.timers[i]
        timer.key   = timer.key or ("t" .. i)
        timer.fired = false
        -- Un spellId sur n'importe quel type de trigger sert de resynchro :
        -- la valeur observee prime toujours sur la valeur estimee.
        if timer.spellId then castTriggers[timer.spellId] = timer end
        if timer.trigger == "HEALTH" then
            healthTriggers[#healthTriggers + 1] = timer
        end
    end
    return castTriggers, healthTriggers
end

function M:Engage(npcId, guid)
    if self.engaged then return end
    local def = BossTimerData[npcId]
    if not def then return end

    self.engaged  = npcId
    self.def      = def
    self.bossGUID = guid
    self.pullTime = GetTime()
    self.castTriggers, self.healthTriggers = BuildLookups(def)

    self:StartPullTimers(def)

    if #self.healthTriggers > 0 then
        self:Repeat("healthPoll", HEALTH_POLL_INTERVAL, function() self:PollHealth() end)
    end

    ns.Debug("engage", npcId, def.name, guid)
    EventBus:Fire("BOSS_ENGAGED", npcId, guid)
end

function M:StartPullTimers(def)
    for i = 1, #def.timers do
        local timer = def.timers[i]
        if timer.trigger == "PULL" and timer.time then
            self:ScheduleNext(timer, timer.time)
        end
    end
end

function M:Disengage()
    if not self.engaged then return end
    local npcId = self.engaged
    self.engaged        = nil
    self.def            = nil
    self.bossGUID       = nil
    self.castTriggers   = nil
    self.healthTriggers = nil
    Scheduler:CancelPrefix("BossTimer_")
    self:CancelAllTimers()
    self:ClearBars()
    EventBus:Fire("BOSS_DISENGAGED", npcId)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function M:ENCOUNTER_START(_, encounterId)
    local npcId = BossTimerEncounter[tonumber(encounterId) or -1]
    if npcId then self:Engage(npcId, nil) end
end

function M:ENCOUNTER_END()
    self:Disengage()
end

function M:PLAYER_REGEN_ENABLED()
    -- Fin de combat = wipe ou kill : dans les deux cas les timers du pull
    -- precedent doivent mourir avant le suivant.
    self:Disengage()
end

--------------------------------------------------------------------------------
-- Combat log — chemin chaud
--------------------------------------------------------------------------------

local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local NpcIdFromGUID = ns.NpcIdFromGUID

-- Memoisation du parsing de GUID : la meme poignee de GUID revient des milliers
-- de fois par pull.
local npcIdCache = {}
local npcIdCacheCount = 0

local function CachedNpcId(guid)
    if not guid then return nil end
    local cached = npcIdCache[guid]
    if cached ~= nil then return cached or nil end
    if npcIdCacheCount > 800 then
        wipe(npcIdCache)
        npcIdCacheCount = 0
    end
    local npcId = NpcIdFromGUID(guid) or false
    npcIdCache[guid] = npcId
    npcIdCacheCount = npcIdCacheCount + 1
    return npcId or nil
end

local function OnCombatLog()
    local _, sub, _, srcGUID, _, _, _, dstGUID, _, _, _, spellId = CombatLogGetCurrentEventInfo()

    if M.engaged then
        if sub == "UNIT_DIED" then
            if dstGUID == M.bossGUID or CachedNpcId(dstGUID) == M.engaged then
                M:Disengage()
            end
            return
        end

        if sub ~= "SPELL_CAST_START" and sub ~= "SPELL_CAST_SUCCESS" then return end
        if srcGUID ~= M.bossGUID and CachedNpcId(srcGUID) ~= M.engaged then return end
        if not M.bossGUID then M.bossGUID = srcGUID end

        local def = M.castTriggers[spellId]
        if def then M:OnBossCast(def, sub) end
        return
    end

    -- Pas encore engage : filet de secours la ou ENCOUNTER_START n'existe pas.
    if sub ~= "SPELL_CAST_START" and sub ~= "SPELL_CAST_SUCCESS"
        and sub ~= "SPELL_DAMAGE" and sub ~= "SWING_DAMAGE" then return end

    local npcId = CachedNpcId(srcGUID)
    if npcId and BossTimerData[npcId] then
        M:Engage(npcId, srcGUID)
    end
end

--- Un cast observe prime sur toute estimation : on resynchronise la prochaine
-- occurrence dessus.
-- Un sort avec temps d'incantation genere START *et* SUCCESS : on n'en retient
-- qu'un seul, sinon le timer se declenche deux fois.
function M:OnBossCast(def, subevent)
    local wantStart = (def.castStart == true)
    if wantStart then
        if subevent ~= "SPELL_CAST_START" then return end
    elseif subevent ~= "SPELL_CAST_SUCCESS" then
        return
    end

    if def.trigger == "CAST" then
        self:FireTimer(def)
    elseif def.repeatInterval then
        Scheduler:Cancel("BossTimer_" .. def.key)
        def.fired = true
        self:ScheduleNext(def, def.repeatInterval)
    end
end

--------------------------------------------------------------------------------
-- Seuils de vie
--------------------------------------------------------------------------------
-- UNIT_HEALTH_FREQUENT a disparu en retail et UNIT_HEALTH n'est fiable que si le
-- boss occupe une frame surveillee. On resout l'unite explicitement, et on
-- assume : les seuils HEALTH sont structurellement moins fiables en classic, ou
-- il n'existe pas d'unite boss dediee.

local BOSS_UNITS = { "boss1", "boss2", "boss3", "boss4", "boss5" }
local FALLBACK_UNITS = { "target", "focus", "mouseover" }

function M:ResolveBossUnit()
    if ns.has.bossUnitFrames then
        for i = 1, #BOSS_UNITS do
            local unit = BOSS_UNITS[i]
            if UnitExists(unit) then
                if not self.bossGUID or UnitGUID(unit) == self.bossGUID then return unit end
            end
        end
    end
    for i = 1, #FALLBACK_UNITS do
        local unit = FALLBACK_UNITS[i]
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            if guid == self.bossGUID or CachedNpcId(guid) == self.engaged then return unit end
        end
    end
    return nil
end

function M:PollHealth()
    local unit = self:ResolveBossUnit()
    if not unit then return end
    local max = UnitHealthMax(unit)
    if not max or max <= 0 then return end
    local pct = UnitHealth(unit) / max

    local triggers = self.healthTriggers
    for i = 1, #triggers do
        local def = triggers[i]
        if not def.fired and def.threshold and pct <= def.threshold then
            self:FireTimer(def)
        end
    end
end

--------------------------------------------------------------------------------
-- Mode test
--------------------------------------------------------------------------------
-- Rejoue la timeline hors combat. Vaut aussi comme test de non-regression apres
-- edition d'un fichier de data.

function M:TestBoss(npcId)
    if not npcId then
        ns.Print("usage : /mbs test boss <npcId>")
        return
    end
    local def = BossTimerData[npcId]
    if not def then
        ns.Print(("aucune data pour le npcId %d (flavor %s)."):format(npcId, ns.flavor))
        return
    end
    if self.engaged then
        ns.Print("engage en cours : test refuse.")
        return
    end

    ns.testMode = true
    self.testing = true
    self.def = def
    self.castTriggers, self.healthTriggers = BuildLookups(def)
    self.pullTime = GetTime()

    local stagger = 6
    for i = 1, #def.timers do
        local timer = def.timers[i]
        if timer.trigger == "PULL" and timer.time then
            self:ScheduleNext(timer, timer.time)
        else
            -- CAST et HEALTH n'ont pas d'echeance connue hors combat : on les
            -- etale pour pouvoir juger du rendu et des positions.
            local delay = timer.testTime or stagger
            stagger = stagger + 6
            self:ScheduleNext(timer, delay)
        end
    end

    ns.Print(("test : %s (%d) — %d timer(s). /mbs test stop pour arreter.")
        :format(def.name or "?", npcId, #def.timers))
end

function M:StopTestBoss()
    if not self.testing then return end
    self.testing = false
    Scheduler:CancelPrefix("BossTimer_")
    self:ClearBars()
    self.def, self.castTriggers, self.healthTriggers = nil, nil, nil
end

--------------------------------------------------------------------------------
-- Validation de la data
--------------------------------------------------------------------------------

local VALID_TRIGGERS = { PULL = true, CAST = true, HEALTH = true }

function M:ValidateData()
    local problems = 0
    for npcId, def in pairs(BossTimerData) do
        local function fail(msg)
            problems = problems + 1
            ns.Print(("data invalide [%s]: %s"):format(tostring(npcId), msg))
        end
        if type(npcId) ~= "number" then
            fail("la cle doit etre un npcId numerique, jamais un nom (localise)")
        end
        if def.flavors and not def.flavors[ns.flavor] then
            fail(("entree chargee sur le client %s alors que `flavors` ne le liste pas")
                :format(ns.flavor))
        end
        if type(def.timers) ~= "table" then
            fail("champ `timers` manquant")
        else
            for i = 1, #def.timers do
                local timer = def.timers[i]
                if not VALID_TRIGGERS[timer.trigger] then
                    fail(("timer %d : trigger inconnu %s"):format(i, tostring(timer.trigger)))
                elseif timer.trigger == "PULL" and not timer.time then
                    fail(("timer %d : trigger PULL sans `time`"):format(i))
                elseif timer.trigger == "CAST" and not timer.spellId then
                    fail(("timer %d : trigger CAST sans `spellId`"):format(i))
                elseif timer.trigger == "HEALTH" and not timer.threshold then
                    fail(("timer %d : trigger HEALTH sans `threshold`"):format(i))
                end
            end
        end
    end
    return problems
end

function M:CountData()
    local n = 0
    for _ in pairs(BossTimerData) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------------
-- Cycle de vie
--------------------------------------------------------------------------------

function M:OnInitialize()
    self:GetGroup(GENERIC_ANCHOR)
    self:CreateSavedOverrideGroups()
end

function M:OnEnable()
    if ns.has.encounterEvents then
        self:RegisterEvent("ENCOUNTER_START")
        self:RegisterEvent("ENCOUNTER_END")
    end
    self:RegisterRawEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterMessage("TEST_STOPPED", function() self:StopTestBoss() end)

    local problems = self:ValidateData()
    if problems > 0 then
        ns.Print(("%d probleme(s) dans les fichiers de data."):format(problems))
    end
    ns.Debug("bossTimer actif —", self:CountData(), "boss charge(s)")
end

function M:OnDisable()
    self:Disengage()
    self:StopTestBoss()
    self:UnregisterAllEvents()
    self:UnregisterAllMessages()
    self:CancelAllTimers()
    self:ClearBars()
end
