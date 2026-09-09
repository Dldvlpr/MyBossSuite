-- Modules/BossTimer/BossTimer.lua
-- Moteur de rencontre : timers, phases, annonces, detection d'engage et de fin
-- de combat — en raid, en donjon et sur les world boss.
--
-- Detection d'engage : ENCOUNTER_START partout ou il existe (Cata Classic, MoP
-- Classic, retail), unites boss1..5 quand elles apparaissent, combat log en
-- dernier filet (un boss connu qui lance un sort, tape, ou *se fait* taper —
-- ce dernier cas est celui du world boss qu'un autre groupe a deja engage).
--
-- Fin de combat : ce n'est plus PLAYER_REGEN_ENABLED qui tranche. Mourir sort
-- du combat, et pourtant le groupe se bat toujours : les timers doivent
-- survivre a la mort du joueur. On distingue :
--   * kill   : UNIT_DIED de tous les npcIds de la rencontre, ou ENCOUNTER_END
--              avec succes ;
--   * wipe   : plus personne du groupe en combat pendant un delai de grace (et
--              IsEncounterInProgress dit non, la ou le client sait repondre) ;
--   * reset  : world boss qui n'a rien fait ni subi depuis un moment (evade) ;
--   * zone   : changement de zone / reload.
--
-- Phases : declarees dans la data, declenchees par seuil de vie, sort, emote,
-- aura, mort d'un add ou simple delai. Chaque timer peut etre restreint a une
-- ou plusieurs phases ; changer de phase coupe les timers qui n'y ont pas leur
-- place et lance ceux relatifs a l'entree dans la phase.

local _, ns = ...

local Alerts = ns.Alerts

local M = ns:NewModule("bossTimer", {
    enabled    = true,
    sound      = true,    -- son a l'echeance d'un timer sans annonce dediee
    announce   = true,    -- annonces plein ecran des timers marques `announce`
    countdown  = true,    -- compte a rebours texte (3, 2, 1) avant l'echeance
    phaseAlert = true,    -- annonce a chaque changement de phase
    phaseFrame = true,    -- cadre boss / phase / chrono
    summary    = true,    -- resume en fin de combat (kill, wipe, duree)
    sync       = true,    -- synchronisation pull / phases / kill avec le groupe
    alert = Alerts.MakeDefaults({
        text      = "BOSS",
        color     = { 1, 0.6, 0.2 },
        fontSize  = 40,
        duration  = 2,
        flash     = false,
        soundName = "raidwarning",
    }),
})
M.title = "Boss Timer"

local Bars      = ns.Bars
local Scheduler = ns.Scheduler
local EventBus  = ns.EventBus
local Comm      = ns.Comm
local GetTime   = GetTime

-- Tables remplies par les fichiers de Data/, chargees apres ce fichier.
ns.BossTimerData      = ns.BossTimerData or {}
ns.BossTimerEncounter = ns.BossTimerEncounter or {}

local BossTimerData      = ns.BossTimerData
local BossTimerEncounter = ns.BossTimerEncounter

-- [npcId] = npcId principal : une rencontre a plusieurs boss (conseil) se
-- declare une fois, sous le premier, avec les autres dans `npcIds`.
local BossTimerAlias = {}
ns.BossTimerAlias = BossTimerAlias

local GENERIC_ANCHOR = "BossTimer_GenericBar"
local PHASE_ANCHOR   = "BossTimer_Phase"
local ALERT_KEY      = "boss"
local ALERT_ANCHOR   = "BossTimer_Display"

local BAR_COLOR   = { 0.25, 0.55, 0.9 }
local PHASE_COLOR = { 0.75, 0.35, 0.9 }
local CAST_COLOR  = { 0.95, 0.75, 0.25 }

-- Ecart tolere entre l'echeance estimee d'un timer et le cast reellement
-- observe. En dessous, l'estimation etait bonne : la barre a deja fait son
-- travail et annonce, on se contente de resynchroniser la suite. Au-dela, le
-- boss a lance le sort ailleurs que la ou on l'attendait : c'est maintenant
-- qu'il faut le montrer, pas a l'heure qu'on avait devinee.
local RESYNC_TOLERANCE = 2

local HEALTH_POLL_INTERVAL = 0.5
local WIPE_POLL_INTERVAL   = 1

-- Delai de grace hors combat avant de conclure au wipe. Plus long sur un world
-- boss : on peut en sortir (mort, fuite) pendant qu'il reste engage.
local WIPE_GRACE = { raid = 3, dungeon = 3, world = 8 }

-- Des vivants mais personne en combat : boss reset, ou tout le monde a fui. On
-- laisse au boss le temps de se taire (rien lance, rien subi) avant de conclure.
local BOSS_IDLE_TIMEOUT = 15

-- Inactivite du boss meme sans sortie de combat du joueur : reset d'un world
-- boss (evade) pendant qu'on reste en combat avec ses adds. En raid, une phase
-- de transition (boss submerge, invulnerable) peut durer bien plus longtemps.
local INACTIVITY = { world = 45 }
local WATCHDOG_INTERVAL = 5

local UnitIsDeadOrGhost = _G.UnitIsDeadOrGhost

local VALID_KINDS = { raid = true, dungeon = true, world = true }

-- Synchronisation : ecart minimal (s) entre deux heures de pull pour adopter
-- celle d'un autre joueur ; fenetre pendant laquelle un PULL recu dispense de
-- repondre a une demande d'etat (sinon 39 reponses a chaque arrivant en raid).
local SYNC_PULL_TOLERANCE = 1.5
local SYNC_REPLY_WINDOW   = 2
local SYNC_REQUEST_THROTTLE = 5

local EMOTE_EVENTS = {
    "CHAT_MSG_RAID_BOSS_EMOTE",
    "CHAT_MSG_RAID_BOSS_WHISPER",
    "CHAT_MSG_MONSTER_YELL",
    "CHAT_MSG_MONSTER_EMOTE",
}

local EMPTY = {}

--------------------------------------------------------------------------------
-- Etat de pull
--------------------------------------------------------------------------------

M.engaged        = nil    -- npcId principal (ou "encounter:<id>" sans data)
M.def            = nil
M.kind           = nil    -- "raid" | "dungeon" | "world", effectif
M.bossGUID       = nil
M.pullTime       = 0
M.phase          = nil
M.phaseTime      = 0
M.lastHealthPct  = nil
M.npcSet         = nil    -- [npcId] = true, toute unite de la rencontre
M.alive          = nil    -- [npcId] = true, celles qu'il reste a tuer
M.castTriggers   = nil    -- [spellId] = { entree, ... }
M.auraTriggers   = nil    -- [spellId] = { entree, ... }
M.deathTriggers  = nil    -- [npcId]   = { entree, ... }
M.emoteTriggers  = nil    -- { entree, ... }
M.healthTriggers = nil    -- { entree, ... }

--------------------------------------------------------------------------------
-- Formatage
--------------------------------------------------------------------------------

local function FormatClock(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    return ("%d:%02d"):format(math.floor(seconds / 60), math.floor(seconds % 60))
end
M.FormatClock = FormatClock

local function TimerLabel(def)
    return def.name or (def.spellId and ns.GetSpellName(def.spellId)) or "?"
end

local function TimerIcon(def)
    if def.icon then return def.icon end
    if def.spellId then return ns.GetSpellTexture(def.spellId) end
    return nil
end

--------------------------------------------------------------------------------
-- Groupes de bars
--------------------------------------------------------------------------------

local function TestGenericBars(group)
    Bars:TestBar(group, "boss1", 12, "Flame Breath", nil, BAR_COLOR)
    Bars:TestBar(group, "boss2", 25, "Fireball Volley", nil, BAR_COLOR)
    Bars:TestBar(group, "boss3", 40, "Phase 2", nil, PHASE_COLOR)
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

--- Ancre dediee a un sort : ses barres quittent l'ancre generique pour une
-- frame a part, deplacable en mode unlock. C'est ce que ns:ResolveAnchorKey
-- consulte ; sans cette commande la mecanique n'etait atteignable nulle part.
function M:AddOverrideAnchor(spellId)
    if not ns.db or not spellId then return nil end
    local anchorKey = "BossTimer_Alert_" .. spellId
    local group = self:GetGroup(anchorKey)
    if not ns.db.anchors[anchorKey] then group:SaveAnchor() end
    return anchorKey, group
end

function M:RemoveOverrideAnchor(spellId)
    if not ns.db or not spellId then return false end
    local anchorKey = "BossTimer_Alert_" .. spellId
    if not ns.db.anchors[anchorKey] then return false end
    ns.db.anchors[anchorKey] = nil
    local group = Bars.groups[anchorKey]
    if group then
        group:StopAll()
        ns.Anchors:Unregister(anchorKey)
        group:Hide()
        -- Une frame ne se detruit pas : on la laisse orpheline et cachee.
        Bars.groups[anchorKey] = nil
    end
    return true
end

function M:ListOverrideAnchors()
    local out = {}
    if not ns.db then return out end
    for anchorKey in pairs(ns.db.anchors) do
        local spellId = anchorKey:match("^BossTimer_Alert_(%d+)$")
        if spellId then out[#out + 1] = tonumber(spellId) end
    end
    table.sort(out)
    return out
end

function M:ClearBars()
    for anchorKey, group in pairs(Bars.groups) do
        if anchorKey:sub(1, 10) == "BossTimer_" then group:StopAll() end
    end
end

--------------------------------------------------------------------------------
-- Cadre de phase
--------------------------------------------------------------------------------
-- Nom du boss, phase courante, chrono du combat et de la phase, vie du boss.
-- Une seule ligne d'information, mise a jour cinq fois par seconde : c'est ce
-- qu'on regarde entre deux barres.

local PHASE_FRAME_REFRESH = 0.2

function M:GetPhaseFrame()
    if self.phaseFrame then return self.phaseFrame end

    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(240, 36)
    frame:Hide()

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    ns.SetSolidColor(bg, 0, 0, 0, 0.55)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -4)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -4)
    title:SetJustifyH("LEFT")
    frame.title = title

    local clock = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    clock:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 6, 4)
    clock:SetJustifyH("LEFT")
    frame.clock = clock

    local health = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    health:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 4)
    health:SetJustifyH("RIGHT")
    frame.health = health

    frame.sinceRefresh = 0
    frame:SetScript("OnUpdate", function(f, elapsed)
        f.sinceRefresh = f.sinceRefresh + elapsed
        if f.sinceRefresh < PHASE_FRAME_REFRESH then return end
        f.sinceRefresh = 0
        M:RefreshPhaseFrame()
    end)

    ns.Anchors:Register(frame, PHASE_ANCHOR, {
        label        = "Boss Timer - phase",
        defaultPoint = { "CENTER", "UIParent", "CENTER", 300, 110 },
        test         = function() M:TestPhaseFrame() end,
    })

    self.phaseFrame = frame
    return frame
end

--- Libelle de la phase courante : "Phase 2/3 - Vol", ou "" sans phases.
function M:PhaseLabel()
    local def = self.def
    if not def or not self.phase then return "" end
    local phases = def.phases or EMPTY
    if #phases == 0 then return "" end
    local phaseDef = phases[self.phase]
    local name = phaseDef and phaseDef.name
    local label = ("Phase %d/%d"):format(self.phase, #phases)
    if name and name ~= "" then label = label .. " - " .. name end
    return label
end

function M:RefreshPhaseFrame()
    local frame = self.phaseFrame
    if not frame or not self.def then return end
    local now = GetTime()
    local def = self.def

    local phaseLabel = self:PhaseLabel()
    frame.title:SetText(phaseLabel ~= ""
        and ("%s  |cffffd100%s|r"):format(def.name or "?", phaseLabel)
        or (def.name or "?"))

    local fight = FormatClock(now - self.pullTime)
    if phaseLabel ~= "" then
        frame.clock:SetText(("%s  |cffaaaaaa(phase %s)|r"):format(fight, FormatClock(now - self.phaseTime)))
    else
        frame.clock:SetText(fight)
    end

    local pct = self.lastHealthPct
    frame.health:SetText(pct and ("%d%%"):format(pct * 100 + 0.5) or "")
end

function M:ShowPhaseFrame()
    local config = self:GetConfig()
    if config and config.phaseFrame == false then return end
    local frame = self:GetPhaseFrame()
    frame.sinceRefresh = PHASE_FRAME_REFRESH
    self:RefreshPhaseFrame()
    frame:Show()
end

function M:HidePhaseFrame()
    local frame = self.phaseFrame
    if not frame then return end
    if frame.mbsForcedShow or frame.mbsUnlocked then return end
    frame:Hide()
end

-- Apercu pour /mbs test : un faux combat fige, le temps de placer le cadre.
function M:TestPhaseFrame()
    if self.engaged then return end
    local frame = self:GetPhaseFrame()
    frame.title:SetText("Onyxia  |cffffd100Phase 2/3 - Vol|r")
    frame.clock:SetText("1:23  |cffaaaaaa(phase 0:12)|r")
    frame.health:SetText("58%")
    frame.testing = true
    frame:Show()
end

--------------------------------------------------------------------------------
-- Annonces
--------------------------------------------------------------------------------

function M:Announce(text, opts)
    local config = self:GetConfig()
    if config and config.announce == false then return false end
    opts = opts or {}
    opts.text = text
    return Alerts:Show(ALERT_KEY, opts)
end

--------------------------------------------------------------------------------
-- Affichage d'un timer
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Barre d'incantation
--------------------------------------------------------------------------------
-- Tous les sorts ne tombent pas a heure fixe. Certains ont un cooldown interne
-- et partent quand le boss le decide : la mediane des logs situe la fenetre,
-- pas l'instant. Pour ceux-la, la seule information juste est le cast lui-meme.
-- Il s'affiche donc quand le boss le lance, quel que soit le trigger du timer
-- qui l'attendait — une barre qui compte l'incantation, et pas une echeance
-- devinee.

local function CastBarKey(def)
    return def.key .. "_cast"
end

--- Duree d'incantation restante. Le client fait foi quand l'unite du boss est
-- lisible ; a defaut on retombe sur le `castTime` releve dans les logs. Ni l'un
-- ni l'autre : pas de barre, un sort instantane n'a pas d'incantation a montrer.
function M:CastDuration(def)
    local unit = self:ResolveBossUnit()
    if unit then
        local name, _, _, endTime, _, spellId = ns.GetCastInfo(unit)
        if name and endTime and (spellId == nil or spellId == def.spellId) then
            local remaining = endTime / 1000 - GetTime()
            if remaining > 0 then return remaining end
        end
    end
    return def.castTime
end

function M:ShowCastBar(def)
    if def.castBar == false or def.bar == false then return end
    local duration = self:CastDuration(def)
    if not duration or duration <= 0 then return end
    local group = self:GetGroup(ns:ResolveAnchorKey(def.spellId))
    group:StartBar(CastBarKey(def), duration, TimerLabel(def), TimerIcon(def), {
        color = def.color or CAST_COLOR,
    })
end

function M:StopCastBar(def)
    local group = Bars.groups[ns:ResolveAnchorKey(def.spellId)]
    if group then group:StopBar(CastBarKey(def)) end
end

local function TimerPrefix(def)
    return "BossTimer_" .. def.key .. "_"
end

--- Annule tout ce qui est programme pour ce timer : echeance, pre-alerte,
-- compte a rebours.
function M:CancelTimerSchedule(def)
    Scheduler:CancelPrefix(TimerPrefix(def))
end

function M:CancelTimerDef(def)
    self:CancelTimerSchedule(def)
    self:StopBar(def)
    self:StopCastBar(def)
end

--- Le moment ou la capacite tombe : on annonce, puis on reprogramme si le timer
-- se repete.
--- `observed` : le sort a ete vu partir dans le combat log, par opposition a
-- une echeance estimee qui arrive a terme. La distinction n'a d'importance que
-- pour un timing non deterministe, ou l'estimation ne vaut rien et
-- l'observation vaut tout.
function M:FireTimer(def, subtitle, observed)
    if def.once and def.fired then return end
    def.fired = true

    EventBus:Fire("BOSS_TIMER_FIRED", def)

    local config = self:GetConfig()
    local announce = def.announce
    -- Une aura qui vise le joueur s'annonce d'elle-meme : c'est l'information
    -- qui compte le plus dans un combat, et la data n'a pas a la repeter.
    if announce == nil and def.trigger == "AURA" and def.on == "player" then
        announce = TimerLabel(def) .. " SUR TOI"
    elseif announce == nil and def.variable and observed then
        -- Timing non deterministe : la seule chose vraie qu'on puisse en dire,
        -- c'est qu'il vient de partir. Le timer s'annonce donc de lui-meme au
        -- cast, faute de pouvoir s'annoncer a l'avance.
        announce = TimerLabel(def)
    end

    -- L'echeance estimee d'un timer `variable` est un reperage, pas une
    -- prediction : la barre grisee suffit a l'exprimer. Annoncer ou sonner a
    -- cet instant-la afficherait une certitude qu'on n'a pas.
    if def.variable and not observed then
        -- rien : la barre a expire, c'est tout ce qu'on avait a dire.
    elseif announce then
        self:Announce(type(announce) == "string" and announce or TimerLabel(def), {
            subtitle = subtitle,
            icon     = TimerIcon(def),
            color    = def.color,
            quiet    = not def.flash,
        })
    elseif config and config.sound then
        -- Par Compat, comme tout son de l'addon : un kit absent ne casse rien.
        ns.PlayAlertSound("raidwarning", "Master")
    end

    if def.repeatInterval and not def.once then
        self:ScheduleNext(def, def.repeatInterval)
    else
        self:StopBar(def)
    end
end

--- Programme l'echeance, la pre-alerte et le compte a rebours d'un timer.
function M:ScheduleNext(def, delay)
    self:CancelTimerSchedule(def)
    self:ShowBar(def, delay)
    def.dueAt = GetTime() + delay

    local prefix = TimerPrefix(def)
    Scheduler:Schedule(prefix .. "fire", delay, function()
        self:FireTimer(def)
    end)

    local config = self:GetConfig() or EMPTY

    if def.announce and def.warnBefore and delay > def.warnBefore
        and not def.variable and config.announce ~= false then
        Scheduler:Schedule(prefix .. "warn", delay - def.warnBefore, function()
            self:Announce(TimerLabel(def), {
                subtitle = ("dans %ds"):format(def.warnBefore),
                icon     = TimerIcon(def),
                color    = def.color,
                quiet    = true,
            })
        end)
    end

    local countdown = tonumber(def.countdown)
    if countdown and countdown > 0 and config.countdown ~= false then
        countdown = math.min(math.floor(countdown), 10)
        local label = TimerLabel(def)
        for i = countdown, 1, -1 do
            if delay > i then
                Scheduler:Schedule(prefix .. "cd" .. i, delay - i, function()
                    self:Announce(tostring(i), {
                        subtitle = label,
                        silent   = true,
                        quiet    = true,
                        duration = 0.95,
                    })
                end)
            end
        end
    end
end

--- Delai jusqu'a la prochaine occurrence d'un timer dont l'origine (pull ou
-- entree de phase) remonte a `elapsed` secondes : rattrape les cycles deja
-- passes d'un timer repetitif, nil si l'echeance unique est deja passee.
local function NextDelay(def, elapsed)
    local delay = def.time - (elapsed or 0)
    if delay > 0 then return delay end
    if not def.repeatInterval or def.once then return nil end
    repeat delay = delay + def.repeatInterval until delay > 0
    return delay
end

--------------------------------------------------------------------------------
-- Phases et applicabilite
--------------------------------------------------------------------------------

--- Une entree (timer ou phase) s'applique-t-elle a la difficulte courante ?
-- `difficulties` absent = toutes.
local function AppliesToDifficulty(entry, difficultyId)
    local list = entry.difficulties
    if not list or not difficultyId or difficultyId == 0 then return true end
    for i = 1, #list do
        if list[i] == difficultyId then return true end
    end
    return false
end

--- Un timer restreint a `phase` ou `phases` ne vit que dans celles-la.
local function TimerInPhase(def, phase)
    if def.phase then return def.phase == phase end
    local list = def.phases
    if not list then return true end
    for i = 1, #list do
        if list[i] == phase then return true end
    end
    return false
end
M.TimerInPhase = TimerInPhase

local function AddTo(lookup, key, entry)
    if key == nil then return end
    local list = lookup[key]
    if not list then
        list = {}
        lookup[key] = list
    end
    list[#list + 1] = entry
end

--- Construit les tables de recherche une fois a l'engage : le combat log ne
-- doit jamais parcourir `timers`.
function M:BuildLookups(def, difficultyId)
    local castTriggers, auraTriggers, deathTriggers = {}, {}, {}
    local emoteTriggers, healthTriggers = {}, {}

    local timers = def.timers or EMPTY
    for i = 1, #timers do
        local timer = timers[i]
        timer.key     = timer.key or ("t" .. i)
        timer.fired   = false
        timer.dueAt   = nil
        timer.isPhase = nil
        timer.skipped = not AppliesToDifficulty(timer, difficultyId)
        if not timer.skipped then
            -- Un spellId sur n'importe quel type de trigger sert de resynchro :
            -- la valeur observee prime toujours sur la valeur estimee.
            if timer.trigger == "AURA" then
                AddTo(auraTriggers, timer.spellId, timer)
            elseif timer.spellId then
                AddTo(castTriggers, timer.spellId, timer)
            end
            if timer.trigger == "HEALTH" then
                healthTriggers[#healthTriggers + 1] = timer
            elseif timer.trigger == "DEATH" then
                AddTo(deathTriggers, timer.npcId, timer)
            elseif timer.trigger == "EMOTE" then
                emoteTriggers[#emoteTriggers + 1] = timer
            end
        end
    end

    local phases = def.phases or EMPTY
    for i = 1, #phases do
        local phase = phases[i]
        phase.index   = i
        phase.isPhase = true
        phase.fired   = false
        phase.skipped = not AppliesToDifficulty(phase, difficultyId)
        if not phase.skipped then
            local trigger = phase.trigger
            if trigger == "HEALTH" then
                healthTriggers[#healthTriggers + 1] = phase
            elseif trigger == "CAST" then
                AddTo(castTriggers, phase.spellId, phase)
            elseif trigger == "AURA" then
                AddTo(auraTriggers, phase.spellId, phase)
            elseif trigger == "DEATH" then
                AddTo(deathTriggers, phase.npcId, phase)
            elseif trigger == "EMOTE" then
                emoteTriggers[#emoteTriggers + 1] = phase
            end
        end
    end

    self.castTriggers   = castTriggers
    self.auraTriggers   = auraTriggers
    self.deathTriggers  = deathTriggers
    self.emoteTriggers  = emoteTriggers
    self.healthTriggers = healthTriggers
end

--- Barre vers la phase suivante, quand son echeance est connue (delai depuis
-- le pull ou depuis l'entree dans la phase courante).
function M:ShowPhaseBar(current)
    local def = self.def
    local nextDef = def.phases and def.phases[current + 1]
    local group = self:GetGroup(GENERIC_ANCHOR)
    group:StopBar("phase")
    Scheduler:Cancel("BossTimer_phase_fire")
    if not nextDef or nextDef.skipped or not nextDef.time then return end

    local remaining
    if nextDef.trigger == "PHASE" then
        remaining = self.phaseTime + nextDef.time - GetTime()
    elseif nextDef.trigger == "PULL" then
        remaining = self.pullTime + nextDef.time - GetTime()
    else
        return
    end
    if remaining <= 0 then return end

    local index = current + 1
    if nextDef.bar ~= false then
        group:StartBar("phase", remaining,
            nextDef.name and ("Phase " .. index .. " - " .. nextDef.name) or ("Phase " .. index),
            nextDef.spellId and ns.GetSpellTexture(nextDef.spellId) or nil,
            { color = PHASE_COLOR, warnBefore = nextDef.warnBefore })
    end
    Scheduler:Schedule("BossTimer_phase_fire", remaining, function()
        self:SetPhase(index, "time")
    end)
end

--- Entre dans la phase `index`. Coupe les timers qui n'y ont pas leur place,
-- lance ceux relatifs a l'entree dans la phase, annonce, et arme la suivante.
--- `elapsed` : la phase a commence il y a tant de secondes (synchronisation).
function M:SetPhase(index, reason, elapsed)
    local def = self.def
    if not def then return false end
    index = tonumber(index)
    if not index or index < 1 then return false end
    local phases = def.phases or EMPTY
    if index > math.max(1, #phases) then return false end
    if self.phase == index then return false end

    local previous = self.phase
    local phaseDef = phases[index]
    elapsed = elapsed or 0
    self.phase     = index
    self.phaseTime = GetTime() - elapsed
    if phaseDef then phaseDef.fired = true end

    local timers = def.timers or EMPTY
    for i = 1, #timers do
        local timer = timers[i]
        if not timer.skipped then
            if not TimerInPhase(timer, index) then
                self:CancelTimerDef(timer)
            elseif timer.trigger == "PHASE" and timer.phase == index and timer.time then
                local delay = NextDelay(timer, elapsed)
                if delay then self:ScheduleNext(timer, delay) end
            end
        end
    end

    self:ShowPhaseBar(index)

    if previous and reason ~= "sync" and reason ~= "test" and self.engaged then
        self:Broadcast("PHASE", self.engaged, index, math.floor(elapsed))
    end

    local config = self:GetConfig() or EMPTY
    if previous and phaseDef and config.phaseAlert ~= false then
        Alerts:Show(ALERT_KEY, {
            text     = phaseDef.alert or ("Phase " .. index),
            subtitle = phaseDef.name,
            color    = phaseDef.color or PHASE_COLOR,
            icon     = phaseDef.spellId and ns.GetSpellTexture(phaseDef.spellId) or nil,
        })
    end

    if self.phaseFrame and self.phaseFrame:IsShown() then self:RefreshPhaseFrame() end
    ns.Debug("phase", index, phaseDef and phaseDef.name or "", reason)
    EventBus:Fire("BOSS_PHASE_CHANGED", index, phaseDef, previous, reason)
    return true
end

--- Dispatch d'une entree declenchee (timer ou phase) par le combat log, un
-- emote, une mort ou un seuil de vie.
function M:Trigger(entry, reason, subtitle)
    if entry.isPhase then
        return self:SetPhase(entry.index, reason)
    end
    if not TimerInPhase(entry, self.phase or 1) then return false end
    if entry.trigger == "CAST" or entry.trigger == "AURA"
        or entry.trigger == "DEATH" or entry.trigger == "EMOTE" or entry.trigger == "HEALTH" then
        self:FireTimer(entry, subtitle, true)
        return true
    end

    -- Timer PULL/PHASE avec spellId : l'observation prime toujours sur
    -- l'estimation. Reste a savoir si elle a deja ete annoncee. Quand le cast
    -- tombe la ou la barre l'attendait, elle a fait son travail et on se
    -- contente de resynchroniser la suite ; quand il tombe ailleurs — ou que le
    -- timing est declare non deterministe, auquel cas l'echeance ne promettait
    -- rien — c'est ce cast-ci qu'il faut montrer.
    local onSchedule = not entry.variable and entry.dueAt
        and math.abs(entry.dueAt - GetTime()) <= RESYNC_TOLERANCE

    if onSchedule then
        if not entry.repeatInterval then return false end
        entry.fired = true
        self:ScheduleNext(entry, entry.repeatInterval)
        return true
    end

    self:CancelTimerSchedule(entry)
    self:FireTimer(entry, subtitle, true)
    return true
end

--------------------------------------------------------------------------------
-- Engage / disengage
--------------------------------------------------------------------------------

local function ReasonLabel(reason)
    if reason == "kill" then return "|cff00ff00kill|r" end
    if reason == "wipe" then return "|cffff5555wipe|r" end
    if reason == "reset" then return "reset (boss inactif)" end
    if reason == "zone" then return "changement de zone" end
    return reason or "fin"
end

function M:RegisterEmoteEvents()
    for i = 1, #EMOTE_EVENTS do
        self:RegisterEvent(EMOTE_EVENTS[i], "OnEmote")
    end
end

function M:UnregisterEmoteEvents()
    for i = 1, #EMOTE_EVENTS do
        self:UnregisterEvent(EMOTE_EVENTS[i])
    end
end

--- `sync` : { elapsed, phase, phaseElapsed, sender } quand l'engage vient d'un
-- autre joueur ; l'heure du pull est alors la sienne, pas la notre.
function M:Engage(npcId, guid, sync)
    if self.testing then return end
    local primary = BossTimerAlias[npcId] or npcId
    local def = BossTimerData[primary]
    if not def then return end

    -- Une rencontre signalee par le client sans data, puis un boss connu qui
    -- agit : on monte en gamme sans perdre l'heure du pull.
    local keepPull
    if self.engaged then
        if not self.generic then return end
        keepPull = self.pullTime
        self:Disengage("upgrade")
    end

    local _, _, difficultyId, _, instanceId = ns.GetInstanceInfo()

    local elapsed = sync and tonumber(sync.elapsed) or 0
    if keepPull and GetTime() - keepPull > elapsed then elapsed = GetTime() - keepPull end

    self.engaged       = primary
    self.generic       = nil
    self.def           = def
    self.kind          = VALID_KINDS[def.kind] and def.kind or ns.GetContentKind()
    self.bossGUID      = guid
    self.pullTime      = GetTime() - elapsed
    self.phase         = nil
    self.phaseTime     = self.pullTime
    self.lastHealthPct = nil
    self.lastActivity  = self.pullTime
    self.instanceId    = instanceId
    self.difficultyId  = difficultyId
    self.bossUnit      = nil

    self.npcSet, self.alive = {}, {}
    self.npcSet[primary], self.alive[primary] = true, true
    for i = 1, #(def.npcIds or EMPTY) do
        self.npcSet[def.npcIds[i]], self.alive[def.npcIds[i]] = true, true
    end

    self:BuildLookups(def, difficultyId)
    self:SetPhase(1, "engage")
    self:StartPullTimers(def, elapsed)
    if sync and tonumber(sync.phase) and tonumber(sync.phase) > 1 then
        self:SetPhase(tonumber(sync.phase), "sync", tonumber(sync.phaseElapsed) or 0)
    end

    self:Repeat("healthPoll", HEALTH_POLL_INTERVAL, function() self:PollHealth() end)
    if #self.emoteTriggers > 0 then self:RegisterEmoteEvents() end

    local inactivity = def.inactivity or INACTIVITY[self.kind]
    if inactivity then
        self.inactivity = inactivity
        self:Repeat("watchdog", WATCHDOG_INTERVAL, function() self:CheckInactivity() end)
    end

    self:ShowPhaseFrame()

    if sync then
        ns.Debug("engage synchronise depuis", sync.sender, primary, def.name, "pull il y a", elapsed)
    else
        self:Broadcast("PULL", primary, math.floor(elapsed), self.phase or 1, 0)
        ns.Debug("engage", primary, def.name, guid, self.kind)
    end
    EventBus:Fire("BOSS_ENGAGED", primary, guid, self.kind)
end

--- Rencontre signalee par le client mais sans data : on affiche au moins le
-- chrono du combat, c'est deja ce qu'on attend d'un boss mod.
function M:EngageGeneric(encounterId, name)
    if self.engaged or self.testing then return end
    local config = self:GetConfig()
    if config and config.phaseFrame == false then return end

    local _, _, difficultyId, _, instanceId = ns.GetInstanceInfo()
    self.engaged       = "encounter:" .. tostring(encounterId)
    self.generic       = true
    self.def           = { name = name or ("Rencontre " .. tostring(encounterId)), generic = true, timers = EMPTY }
    self.kind          = ns.GetContentKind()
    self.bossGUID      = nil
    self.pullTime      = GetTime()
    self.phase         = 1
    self.phaseTime     = self.pullTime
    self.lastHealthPct = nil
    self.lastActivity  = self.pullTime
    self.instanceId    = instanceId
    self.difficultyId  = difficultyId
    self.npcSet, self.alive = {}, {}
    self:BuildLookups(self.def, difficultyId)
    self:Repeat("healthPoll", HEALTH_POLL_INTERVAL, function() self:PollHealth() end)
    self:ShowPhaseFrame()
    EventBus:Fire("BOSS_ENGAGED", self.engaged, nil, self.kind)
end

function M:StartPullTimers(def, elapsed)
    local timers = def.timers or EMPTY
    for i = 1, #timers do
        local timer = timers[i]
        if timer.trigger == "PULL" and timer.time and not timer.skipped and TimerInPhase(timer, 1) then
            local delay = NextDelay(timer, elapsed)
            if delay then
                if delay < timer.time then timer.fired = true end
                self:ScheduleNext(timer, delay)
            end
        end
    end
end

--- Un autre joueur a vu le pull `delta` secondes avant nous : on recule
-- l'heure du pull et on rapproche d'autant tout ce qui en depend.
function M:ShiftPull(delta)
    if not self.def or delta <= 0 then return end
    self.pullTime = self.pullTime - delta
    local now = GetTime()
    local timers = self.def.timers or EMPTY
    for i = 1, #timers do
        local timer = timers[i]
        if timer.trigger == "PULL" and not timer.skipped and timer.dueAt
            and Scheduler:IsScheduled(TimerPrefix(timer) .. "fire") then
            local remaining = timer.dueAt - now - delta
            while remaining <= 0 and timer.repeatInterval and not timer.once do
                remaining = remaining + timer.repeatInterval
            end
            self:ScheduleNext(timer, math.max(remaining, 0.1))
        end
    end
    if self.phase then self:ShowPhaseBar(self.phase) end
end

function M:Disengage(reason)
    if not self.engaged then return end
    reason = reason or "end"
    local npcId   = self.engaged
    local def     = self.def
    local elapsed = GetTime() - self.pullTime
    local phase   = self.phase
    local pct     = self.lastHealthPct

    self.engaged        = nil
    self.generic        = nil
    self.def            = nil
    self.kind           = nil
    self.bossGUID       = nil
    self.bossUnit       = nil
    self.phase          = nil
    self.npcSet         = nil
    self.alive          = nil
    self.castTriggers   = nil
    self.auraTriggers   = nil
    self.deathTriggers  = nil
    self.emoteTriggers  = nil
    self.healthTriggers = nil
    self.inactivity     = nil
    self.wipeSince      = nil

    Scheduler:CancelPrefix("BossTimer_")
    self:CancelAllTimers()
    self:UnregisterEmoteEvents()
    self:ClearBars()
    self:HidePhaseFrame()
    Alerts:Hide(ALERT_KEY)

    local config = self:GetConfig()
    if config and config.summary ~= false and def and not def.generic
        and (reason == "kill" or reason == "wipe" or reason == "reset") then
        local details = ""
        if phase and def.phases and #def.phases > 0 then
            details = (" - phase %d/%d"):format(phase, #def.phases)
        end
        if reason ~= "kill" and pct then
            details = details .. (" - boss a %d%%"):format(pct * 100 + 0.5)
        end
        ns.Print(("%s : %s apres %s%s"):format(def.name or tostring(npcId),
            ReasonLabel(reason), FormatClock(elapsed), details))
    end

    if reason == "kill" and def and not def.generic then
        self:Broadcast("END", npcId, reason)
    end

    ns.Debug("disengage", npcId, reason)
    EventBus:Fire("BOSS_DISENGAGED", npcId, reason, elapsed)
end

--------------------------------------------------------------------------------
-- Synchronisation entre joueurs
--------------------------------------------------------------------------------
-- Ce que le combat log ne dit pas : l'heure exacte du pull quand on arrive en
-- cours de combat, la phase quand on est trop loin pour voir le seuil de vie,
-- la mort du boss quand on est hors de portee du combat log. Chaque joueur
-- annonce ce qu'il voit ; on adopte ce qui est plus precis que ce qu'on a.
--
-- Messages :
--   PULL  <npcId> <elapsed> <phase> <phaseElapsed>   engage, ou reponse a REQ
--   PHASE <npcId> <index> <elapsed>                   changement de phase
--   END   <npcId> <reason>                            kill
--   REQ                                               "y a-t-il un combat ?"
--
-- Anti-echo : rien de ce qui a ete applique depuis un message n'est rediffuse.

function M:SyncEnabled()
    local config = self:GetConfig()
    return not config or config.sync ~= false
end

function M:Broadcast(msgType, ...)
    if self.syncing or self.testing or not self:SyncEnabled() then return false end
    return Comm:Send(msgType, ...)
end

--- Etat courant, sous la forme du message PULL.
function M:SendState()
    if not self.engaged or self.generic or self.testing then return false end
    local now = GetTime()
    return self:Broadcast("PULL", self.engaged, math.floor(now - self.pullTime),
        self.phase or 1, math.floor(now - self.phaseTime))
end

function M:OnSyncPull(sender, npcId, elapsed, phase, phaseElapsed)
    if not self:SyncEnabled() or self.testing then return end
    npcId, elapsed = tonumber(npcId), tonumber(elapsed)
    if not npcId or not elapsed or elapsed < 0 then return end
    local primary = BossTimerAlias[npcId]
    if not primary then return end
    self.lastPullSeen = GetTime()

    self.syncing = true
    if not self.engaged or self.generic then
        self:Engage(primary, nil, {
            elapsed = elapsed, phase = phase, phaseElapsed = phaseElapsed, sender = sender,
        })
    elseif self.engaged == primary then
        local delta = elapsed - (GetTime() - self.pullTime)
        if delta > SYNC_PULL_TOLERANCE then self:ShiftPull(delta) end
        self:OnSyncPhase(sender, npcId, phase, phaseElapsed, true)
    end
    self.syncing = false
end

--- Une phase recue : on la prend si elle differe de la notre, sauf pour
-- revenir en arriere sur un seuil de vie, qui ne remonte jamais.
function M:OnSyncPhase(sender, npcId, index, elapsed, nested)
    if not self:SyncEnabled() or self.testing then return end
    npcId, index = tonumber(npcId), tonumber(index)
    if not npcId or not index or not self.engaged then return end
    if BossTimerAlias[npcId] ~= self.engaged then return end
    if index == self.phase then return end
    local phases = self.def.phases or EMPTY
    local phaseDef = phases[index]
    if not phaseDef then return end
    if index < (self.phase or 1) then
        local current = phases[self.phase]
        if phaseDef.trigger == "HEALTH" or (current and current.trigger == "HEALTH") then return end
    end

    if not nested then self.syncing = true end
    if phaseDef.trigger == "HEALTH" then phaseDef.fired = true end
    self:SetPhase(index, "sync", tonumber(elapsed) or 0)
    if not nested then self.syncing = false end
end

function M:OnSyncEnd(sender, npcId, reason)
    if not self:SyncEnabled() or not self.engaged then return end
    npcId = tonumber(npcId)
    if not npcId or BossTimerAlias[npcId] ~= self.engaged then return end
    if reason ~= "kill" then return end
    self.syncing = true
    self:Disengage("kill")
    self.syncing = false
end

--- Quelqu'un demande l'etat : on repond avec un leger decalage aleatoire, et
-- seulement si personne n'a repondu entre-temps.
function M:OnSyncRequest()
    if not self.engaged or self.generic or not self:SyncEnabled() then return end
    local requestedAt = GetTime()
    self:Schedule("syncReply", 0.2 + math.random() * (SYNC_REPLY_WINDOW - 0.2), function()
        if self.lastPullSeen and self.lastPullSeen >= requestedAt then return end
        self:SendState()
    end)
end

--- A l'arrivee dans un groupe (ou au login) : y a-t-il deja un combat ?
function M:RequestState()
    if self.engaged or not self:SyncEnabled() then return end
    local now = GetTime()
    if self.lastRequest and now - self.lastRequest < SYNC_REQUEST_THROTTLE then return end
    if not ns.GetGroupChannel() then return end
    self.lastRequest = now
    self:Broadcast("REQ")
end

function M:GROUP_ROSTER_UPDATE()
    self:Schedule("syncRequest", 1, function() self:RequestState() end)
end

--------------------------------------------------------------------------------
-- Fin de combat : kill, wipe, reset, zone
--------------------------------------------------------------------------------

function M:OnBossUnitDied(npcId)
    if not self.alive then return end
    self.alive[npcId] = nil
    if next(self.alive) == nil then
        self:Disengage("kill")
    else
        ns.Debug("boss mort", npcId, "- il en reste")
    end
end

--- Etat du groupe, joueur compris : (quelqu'un de vivant, quelqu'un en combat).
local function GroupState()
    local anyAlive, anyFighting = false, false
    local function Look(unit)
        if not UnitExists(unit) then return end
        if UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then return end
        anyAlive = true
        if ns.UnitAffectingCombat(unit) then anyFighting = true end
    end
    Look("player")
    local prefix, count = ns.GroupUnitPrefix()
    for i = 1, count do
        if prefix .. i ~= "player" then Look(prefix .. i) end
    end
    return anyAlive, anyFighting
end

--- Le combat est-il vraiment termine ? Appele quand le joueur sort de combat,
-- puis toutes les WIPE_POLL_INTERVAL secondes tant que la reponse est non.
--   * solo hors world boss : sortir de combat, c'est la fin ;
--   * le client dit que la rencontre continue : non ;
--   * plus personne de vivant : wipe ;
--   * quelqu'un se bat encore : non (mort, feign death, le raid continue) ;
--   * des vivants mais personne en combat : boss reset ou tout le monde a fui,
--     on attend que le boss se taise, et le delai de grace.
function M:IsFightOver()
    local now = GetTime()
    if ns.GetNumGroupMembers() <= 1 and self.kind ~= "world" then return true end
    if ns.IsEncounterInProgress and self.kind ~= "world" and ns.IsEncounterInProgress() then
        return false
    end
    local anyAlive, anyFighting = GroupState()
    if not anyAlive then return true end
    if anyFighting then return false end
    local grace = self.def.wipeGrace or WIPE_GRACE[self.kind] or WIPE_GRACE.raid
    if now - (self.wipeSince or now) < grace then return false end
    return now - self.lastActivity >= (self.def.idleTimeout or BOSS_IDLE_TIMEOUT)
end

function M:IsFightOngoing()
    return not self:IsFightOver()
end

function M:StartWipeCheck()
    if not self.engaged then return end
    self.wipeSince = GetTime()
    self:CheckWipe()
    if not self.engaged then return end
    self:Repeat("wipeCheck", WIPE_POLL_INTERVAL, function() self:CheckWipe() end)
end

function M:StopWipeCheck()
    self.wipeSince = nil
    self:CancelTimer("wipeCheck")
end

--- Tourne tant que le joueur est hors combat : un joueur mort dont le groupe
-- finit par wiper ne recevra plus aucun event, seul ce ticker peut le voir.
function M:CheckWipe()
    if not self.engaged then return self:StopWipeCheck() end
    if self:IsFightOver() then
        self:Disengage("wipe")
    elseif ns.IsGroupInCombat() then
        -- Quelqu'un se bat : le delai de grace repart de la prochaine accalmie.
        self.wipeSince = GetTime()
    end
end

function M:CheckInactivity()
    if not self.engaged or not self.inactivity then return end
    if GetTime() - self.lastActivity >= self.inactivity then
        self:Disengage("reset")
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

--- GUID d'une unite visible dont le npcId appartient a la rencontre : frames
-- boss en Cata+/retail, cible/focus/mouseover ailleurs. nil si rien n'est
-- visible.
function M:FindBossGUID(npcId)
    local primary = BossTimerAlias[npcId] or npcId
    local function Matches(unit)
        if not UnitExists(unit) then return nil end
        local guid = UnitGUID(unit)
        local id = ns.NpcIdFromGUID(guid)
        if id and BossTimerAlias[id] == primary then return guid end
        return nil
    end
    if ns.has.bossUnitFrames then
        for i = 1, 5 do
            local guid = Matches("boss" .. i)
            if guid then return guid end
        end
    end
    for _, unit in ipairs({ "target", "focus", "mouseover" }) do
        local guid = Matches(unit)
        if guid then return guid end
    end
    return nil
end

--- Le boss s'est revele (combat log, frame boss) apres un engage sans GUID.
function M:IdentifyBoss(guid)
    if not guid or self.bossGUID then return end
    self.bossGUID = guid
    EventBus:Fire("BOSS_IDENTIFIED", self.engaged, guid)
end

function M:ENCOUNTER_START(_, encounterId, encounterName)
    local npcId = BossTimerEncounter[tonumber(encounterId) or -1]
    if npcId then
        -- ENCOUNTER_START ne livre pas de GUID : on le cherche sur les frames
        -- boss tout de suite, le combat log le fournira sinon (BOSS_IDENTIFIED).
        self:Engage(npcId, self:FindBossGUID(npcId))
    else
        self:EngageGeneric(encounterId, encounterName)
    end
end

function M:ENCOUNTER_END(_, _, _, _, _, success)
    if not self.engaged then return end
    self:Disengage((tonumber(success) or 0) == 1 and "kill" or "wipe")
end

--- Les unites boss1..5 apparaissent : si l'une d'elles est connue, c'est un
-- engage (Cata+ et retail, ou ENCOUNTER_START peut ne pas etre mappe).
function M:INSTANCE_ENCOUNTER_ENGAGE_UNIT()
    if self.engaged and not self.generic then return end
    for i = 1, 5 do
        local unit = "boss" .. i
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            local npcId = ns.NpcIdFromGUID(guid)
            if npcId and BossTimerAlias[npcId] then
                self:Engage(npcId, guid)
                return
            end
        end
    end
end

function M:PLAYER_REGEN_ENABLED()
    -- Sortir de combat n'est pas la fin du combat : on verifie le groupe
    -- pendant un delai de grace avant de conclure au wipe.
    if self.engaged then self:StartWipeCheck() end
end

function M:PLAYER_REGEN_DISABLED()
    if self.engaged then self:StopWipeCheck() end
end

function M:PLAYER_ENTERING_WORLD()
    if self.engaged then self:Disengage("zone") end
    self:Schedule("syncRequest", 2, function() self:RequestState() end)
end

function M:ZONE_CHANGED_NEW_AREA()
    if not self.engaged then return end
    local _, _, _, _, instanceId = ns.GetInstanceInfo()
    if instanceId ~= self.instanceId then self:Disengage("zone") end
end

--- Emote / cri de boss : les textes sont localises, la data porte donc un
-- fragment a chercher tel quel (`pattern`), jamais une phrase complete.
function M:OnEmote(_, text)
    local list = self.emoteTriggers
    if not list or not text or #list == 0 then return end
    for i = 1, #list do
        local entry = list[i]
        local pattern = entry.pattern or entry.emote
        if pattern and text:find(pattern, 1, not entry.lua) then
            self:Trigger(entry, "emote")
        end
    end
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

--- Cette unite fait-elle partie de la rencontre engagee ?
local function IsBossGUID(guid)
    if not guid then return false end
    if guid == M.bossGUID then return true end
    local npcId = CachedNpcId(guid)
    return npcId ~= nil and M.npcSet[npcId] == true
end

local playerGUID

local function OnCombatLog()
    local _, sub, _, srcGUID, _, _, _, dstGUID, dstName, _, _, spellId = CombatLogGetCurrentEventInfo()

    if M.engaged and not M.generic then
        -- Tout ce que le boss fait ou subit prouve qu'il est encore la : c'est
        -- ce qui permet de conclure a un reset quand plus personne ne se bat.
        if IsBossGUID(srcGUID) then
            M.lastActivity = GetTime()
            if not M.bossGUID then M:IdentifyBoss(srcGUID) end
        elseif IsBossGUID(dstGUID) then
            M.lastActivity = GetTime()
        end

        if sub == "UNIT_DIED" then
            local npcId = CachedNpcId(dstGUID)
            if npcId then
                if M.npcSet[npcId] or dstGUID == M.bossGUID then
                    M:OnBossUnitDied(npcId)
                else
                    local list = M.deathTriggers[npcId]
                    if list then
                        for i = 1, #list do M:Trigger(list[i], "death") end
                    end
                end
            end
            return
        end

        if sub == "SPELL_CAST_START" or sub == "SPELL_CAST_SUCCESS" then
            if not IsBossGUID(srcGUID) then return end
            local list = M.castTriggers[spellId]
            if list then M:OnBossCast(list, sub) end
            return
        end

        if sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REMOVED" then
            local list = M.auraTriggers[spellId]
            if list then M:OnAura(list, sub, dstGUID, dstName) end
        end
        return
    end

    if M.testing then return end

    -- Pas encore engage (ou engage sans data) : filet de secours la ou
    -- ENCOUNTER_START n'existe pas, ou n'est pas mappe. Un boss connu qui agit,
    -- ou qui encaisse (world boss deja engage par d'autres).
    if sub == "SPELL_CAST_START" or sub == "SPELL_CAST_SUCCESS" then
        local npcId = CachedNpcId(srcGUID)
        if npcId and BossTimerAlias[npcId] then M:Engage(npcId, srcGUID) end
    elseif sub == "SPELL_DAMAGE" or sub == "SWING_DAMAGE" or sub == "RANGE_DAMAGE"
        or sub == "SPELL_PERIODIC_DAMAGE" then
        local npcId = CachedNpcId(srcGUID)
        if npcId and BossTimerAlias[npcId] then
            M:Engage(npcId, srcGUID)
            return
        end
        npcId = CachedNpcId(dstGUID)
        if npcId and BossTimerAlias[npcId] then M:Engage(npcId, dstGUID) end
    end
end

--- Un cast observe prime sur toute estimation : on resynchronise la prochaine
-- occurrence dessus.
-- Un sort avec temps d'incantation genere START *et* SUCCESS : on n'en retient
-- qu'un seul, sinon le timer se declenche deux fois.
function M:OnBossCast(list, subevent)
    local starting = (subevent == "SPELL_CAST_START")
    for i = 1, #list do
        local entry = list[i]
        -- La barre d'incantation ne depend pas du trigger : le boss lance le
        -- sort, ca se voit — meme quand le timer qui l'attendait comptait vers
        -- une heure estimee, et meme quand il n'y avait rien a estimer.
        if TimerInPhase(entry, self.phase or 1) then
            if starting then self:ShowCastBar(entry) else self:StopCastBar(entry) end
        end
        local wantStart = (entry.castStart == true)
        if (wantStart and starting) or (not wantStart and not starting) then
            self:Trigger(entry, "cast")
        end
    end
end

--- Aura posee / retiree. `on` = "boss" (defaut), "player" ou "any".
-- `event` = "APPLIED" (defaut) ou "REMOVED".
function M:OnAura(list, subevent, dstGUID, dstName)
    playerGUID = playerGUID or UnitGUID("player")
    local applied = (subevent == "SPELL_AURA_APPLIED")
    for i = 1, #list do
        local entry = list[i]
        local wantRemoved = (entry.event == "REMOVED")
        if applied ~= wantRemoved then
            local on = entry.on or "boss"
            local matches
            if on == "player" then
                matches = (dstGUID == playerGUID)
            elseif on == "any" then
                matches = true
            else
                matches = IsBossGUID(dstGUID)
            end
            if matches then
                self:Trigger(entry, "aura", (on == "any") and dstName or nil)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Seuils de vie
--------------------------------------------------------------------------------
-- UNIT_HEALTH_FREQUENT a disparu en retail et UNIT_HEALTH n'est fiable que si le
-- boss occupe une frame surveillee. On resout l'unite explicitement : boss1..5
-- quand elles existent, sinon cible, focus, mouseover, nameplates, puis les
-- cibles du groupe. En classic il n'y a pas d'unite boss dediee : les seuils
-- HEALTH y restent structurellement moins fiables, et c'est assume.

local BOSS_UNITS     = { "boss1", "boss2", "boss3", "boss4", "boss5" }
local FALLBACK_UNITS = { "target", "focus", "mouseover", "targettarget" }

function M:UnitIsBoss(unit)
    local guid = UnitGUID(unit)
    if not guid then return false end
    if guid == self.bossGUID then return true end
    local npcId = CachedNpcId(guid)
    return npcId ~= nil and self.npcSet[npcId] == true
end

function M:ResolveBossUnit()
    -- Chemin rapide : l'unite trouvee au tour precedent est encore la bonne.
    local cached = self.bossUnit
    if cached and UnitExists(cached) and self:UnitIsBoss(cached) then return cached end
    self.bossUnit = nil

    if ns.has.bossUnitFrames then
        for i = 1, #BOSS_UNITS do
            local unit = BOSS_UNITS[i]
            if UnitExists(unit) and self:UnitIsBoss(unit) then
                self.bossUnit = unit
                return unit
            end
        end
    end
    for i = 1, #FALLBACK_UNITS do
        local unit = FALLBACK_UNITS[i]
        if UnitExists(unit) and self:UnitIsBoss(unit) then
            self.bossUnit = unit
            return unit
        end
    end
    if ns.has.namePlateUnits then
        for i = 1, 40 do
            local unit = "nameplate" .. i
            if not UnitExists(unit) then break end
            if self:UnitIsBoss(unit) then
                self.bossUnit = unit
                return unit
            end
        end
    end
    local prefix, count = ns.GroupUnitPrefix()
    for i = 1, count do
        local unit = prefix .. i .. "target"
        if UnitExists(unit) and self:UnitIsBoss(unit) then
            self.bossUnit = unit
            return unit
        end
    end
    return nil
end

function M:PollHealth()
    if not self.def or self.def.generic then
        -- Sans data, on ne sait pas quelle unite est le boss : boss1 fait foi.
        if ns.has.bossUnitFrames and UnitExists("boss1") then
            local max = UnitHealthMax("boss1")
            if max and max > 0 then self.lastHealthPct = UnitHealth("boss1") / max end
        end
        return
    end

    local unit = self:ResolveBossUnit()
    if not unit then return end
    local max = UnitHealthMax(unit)
    if not max or max <= 0 then return end
    local pct = UnitHealth(unit) / max
    self.lastHealthPct = pct

    local triggers = self.healthTriggers
    for i = 1, #triggers do
        local entry = triggers[i]
        if not entry.fired and entry.threshold and pct <= entry.threshold then
            if entry.isPhase then
                entry.fired = true
                self:SetPhase(entry.index, "health")
            else
                self:Trigger(entry, "health")
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Mode test
--------------------------------------------------------------------------------
-- Rejoue la timeline hors combat, phases comprises. Vaut aussi comme test de
-- non-regression apres edition d'un fichier de data.

function M:TestBoss(npcId)
    if not npcId then
        ns.Print("usage : /mbs test boss <npcId>")
        return
    end
    local def = BossTimerData[BossTimerAlias[npcId] or npcId]
    if not def then
        ns.Print(("aucune data pour le npcId %d (flavor %s)."):format(npcId, ns.flavor))
        return
    end
    if self.engaged then
        ns.Print("engage en cours : test refuse.")
        return
    end

    ns.testMode = true
    self.testing   = true
    self.def       = def
    self.kind      = VALID_KINDS[def.kind] and def.kind or "raid"
    self.pullTime  = GetTime()
    self.phaseTime = self.pullTime
    self.phase     = nil
    self.lastHealthPct = 1
    self.npcSet, self.alive = {}, {}
    self:BuildLookups(def, nil)
    self:SetPhase(1, "test")

    local stagger = 6
    local timers = def.timers or EMPTY
    for i = 1, #timers do
        local timer = timers[i]
        local due
        if timer.trigger == "PULL" and timer.time then
            due = timer.time
            self:ScheduleNext(timer, due)
        elseif timer.trigger == "PHASE" and timer.time then
            -- Programme a l'entree dans sa phase par SetPhase : rien a faire.
        else
            -- CAST, HEALTH, AURA... n'ont pas d'echeance connue hors combat :
            -- on les etale pour pouvoir juger du rendu et des positions.
            due = timer.testTime or stagger
            stagger = stagger + 6
            self:ScheduleNext(timer, due)
        end
        -- Une barre d'incantation ne nait que d'un cast observe : hors combat
        -- il n'y en a pas. On la rejoue devant l'echeance du timer, sinon le
        -- seul affichage d'un sort sans horaire serait absent du test.
        if due and timer.castTime then
            local at = math.max(0.1, due - timer.castTime)
            Scheduler:Schedule("BossTimer_" .. timer.key .. "_testcast", at, function()
                self:ShowCastBar(timer)
            end)
        end
    end

    -- Les phases sans echeance sont rejouees a tour de role, pour voir le cadre,
    -- l'annonce et la bascule des timers.
    local phases = def.phases or EMPTY
    local phaseStagger = 15
    for i = 2, #phases do
        local phase = phases[i]
        if phase.trigger ~= "PULL" and phase.trigger ~= "PHASE" then
            local delay = phase.testTime or phaseStagger
            phaseStagger = phaseStagger + 15
            Scheduler:Schedule("BossTimer_phase_test" .. i, delay, function()
                self.lastHealthPct = phase.threshold or self.lastHealthPct
                self:SetPhase(i, "test")
            end)
        end
    end

    self:ShowPhaseFrame()

    ns.Print(("test : %s (%d) — %d timer(s), %d phase(s). /mbs test stop pour arreter.")
        :format(def.name or "?", npcId, #timers, #phases))
end

function M:StopTestBoss()
    if self.phaseFrame and self.phaseFrame.testing then
        self.phaseFrame.testing = nil
        if not self.engaged then self:HidePhaseFrame() end
    end
    if not self.testing then return end
    self.testing = false
    Scheduler:CancelPrefix("BossTimer_")
    self:ClearBars()
    self:HidePhaseFrame()
    Alerts:Hide(ALERT_KEY)
    self.def, self.phase, self.kind = nil, nil, nil
    self.castTriggers, self.healthTriggers = nil, nil
    self.auraTriggers, self.deathTriggers, self.emoteTriggers = nil, nil, nil
end

--------------------------------------------------------------------------------
-- Validation de la data
--------------------------------------------------------------------------------

local VALID_TRIGGERS = {
    PULL = true, PHASE = true, CAST = true, HEALTH = true,
    AURA = true, EMOTE = true, DEATH = true,
}

local function ValidateEntry(entry, what, fail, phaseCount)
    local trigger = entry.trigger
    if not VALID_TRIGGERS[trigger] then
        fail(("%s : trigger inconnu %s"):format(what, tostring(trigger)))
    elseif trigger == "PULL" and not entry.time then
        fail(("%s : trigger PULL sans `time`"):format(what))
    elseif trigger == "PHASE" and not entry.time then
        fail(("%s : trigger PHASE sans `time`"):format(what))
    elseif trigger == "CAST" and not entry.spellId then
        fail(("%s : trigger CAST sans `spellId`"):format(what))
    elseif trigger == "AURA" and not entry.spellId then
        fail(("%s : trigger AURA sans `spellId`"):format(what))
    elseif trigger == "HEALTH" and not entry.threshold then
        fail(("%s : trigger HEALTH sans `threshold`"):format(what))
    elseif trigger == "EMOTE" and not (entry.pattern or entry.emote) then
        fail(("%s : trigger EMOTE sans `pattern`"):format(what))
    elseif trigger == "DEATH" and not entry.npcId then
        fail(("%s : trigger DEATH sans `npcId`"):format(what))
    end
    if entry.phase and (type(entry.phase) ~= "number" or entry.phase > phaseCount) then
        fail(("%s : `phase` %s hors des phases declarees"):format(what, tostring(entry.phase)))
    end
    if entry.phases then
        for i = 1, #entry.phases do
            if type(entry.phases[i]) ~= "number" or entry.phases[i] > phaseCount then
                fail(("%s : `phases` reference une phase inexistante"):format(what))
                break
            end
        end
    end
end

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
        if def.kind and not VALID_KINDS[def.kind] then
            fail(("`kind` inconnu %s (raid, dungeon ou world)"):format(tostring(def.kind)))
        end
        local phases = def.phases or EMPTY
        local phaseCount = math.max(1, #phases)
        for i = 1, #phases do
            local phase = phases[i]
            if i == 1 then
                if phase.trigger and phase.trigger ~= "PULL" then
                    fail("phase 1 : c'est la phase d'engage, elle ne porte pas de trigger")
                end
            elseif not phase.trigger then
                fail(("phase %d : trigger manquant"):format(i))
            else
                ValidateEntry(phase, ("phase %d"):format(i), fail, phaseCount)
            end
        end
        if type(def.timers) ~= "table" then
            fail("champ `timers` manquant")
        else
            for i = 1, #def.timers do
                local timer = def.timers[i]
                ValidateEntry(timer, ("timer %d"):format(i), fail, phaseCount)
                if timer.trigger == "PHASE" and not timer.phase then
                    fail(("timer %d : trigger PHASE sans `phase`"):format(i))
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

--- Entrees triees par nature puis par zone, pour /mbs boss list.
function M:ListData(kind)
    local out = {}
    for npcId, def in pairs(BossTimerData) do
        local defKind = VALID_KINDS[def.kind] and def.kind or "raid"
        if not kind or kind == defKind then
            out[#out + 1] = { npcId = npcId, def = def, kind = defKind }
        end
    end
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        local za, zb = a.def.zone or "", b.def.zone or ""
        if za ~= zb then return za < zb end
        return (a.def.name or "") < (b.def.name or "")
    end)
    return out
end

function M:BuildAliases()
    wipe(BossTimerAlias)
    for npcId, def in pairs(BossTimerData) do
        BossTimerAlias[npcId] = npcId
        for i = 1, #(def.npcIds or EMPTY) do
            BossTimerAlias[def.npcIds[i]] = npcId
        end
    end
end

--------------------------------------------------------------------------------
-- Statut
--------------------------------------------------------------------------------

function M:StatusLines()
    local lines = {}
    local config = self:GetConfig() or EMPTY
    if self.engaged then
        local def = self.def
        lines[#lines + 1] = ("engage : |cffffffff%s|r (%s) depuis %s"):format(
            def.name or tostring(self.engaged), self.kind or "?",
            FormatClock(GetTime() - self.pullTime))
        local label = self:PhaseLabel()
        if label ~= "" then
            lines[#lines + 1] = ("%s depuis %s"):format(label, FormatClock(GetTime() - self.phaseTime))
        end
        if self.lastHealthPct then
            lines[#lines + 1] = ("vie du boss : %d%%"):format(self.lastHealthPct * 100 + 0.5)
        end
        if self.wipeSince then
            lines[#lines + 1] = "hors combat : verification de wipe en cours"
        end
    else
        lines[#lines + 1] = "aucune rencontre en cours"
    end
    local raid, dungeon, world = #self:ListData("raid"), #self:ListData("dungeon"), #self:ListData("world")
    lines[#lines + 1] = ("data (%s) : %d raid, %d donjon, %d world boss"):format(ns.flavor, raid, dungeon, world)
    lines[#lines + 1] = ("annonces %s   compte a rebours %s   annonce de phase %s   cadre %s   resume %s"):format(
        config.announce ~= false and "on" or "off",
        config.countdown ~= false and "on" or "off",
        config.phaseAlert ~= false and "on" or "off",
        config.phaseFrame ~= false and "on" or "off",
        config.summary ~= false and "on" or "off")
    lines[#lines + 1] = ("synchronisation : %s   canal : %s   envoyes %d / recus %d"):format(
        config.sync ~= false and "on" or "off", ns.GetGroupChannel() or "aucun (solo)",
        Comm.sent, Comm.received)
    lines[#lines + 1] = ("detection : %s%s%s"):format(
        ns.has.encounterEvents and "ENCOUNTER_START + " or "",
        ns.has.bossUnitFrames and "unites boss + " or "",
        "combat log")
    lines[#lines + 1] = ("fin de combat : %s"):format(
        ns.has.encounterProgress and "IsEncounterInProgress + combat du groupe"
            or "combat du groupe (delai de grace)")
    return lines
end

--------------------------------------------------------------------------------
-- Cycle de vie
--------------------------------------------------------------------------------

function M:OnInitialize()
    self:GetGroup(GENERIC_ANCHOR)
    self:CreateSavedOverrideGroups()
    self:GetPhaseFrame()

    Alerts:Register(ALERT_KEY, {
        anchorKey    = ALERT_ANCHOR,
        label        = "Annonce boss",
        order        = 30,
        defaultPoint = { "CENTER", "UIParent", "CENTER", 0, 100 },
        getConfig    = function()
            local config = self:GetConfig()
            return config and config.alert
        end,
        defaults = ns.PROFILE_DEFAULTS.modules.bossTimer.alert,
    })
end

function M:OnEnable()
    playerGUID = UnitGUID("player")
    self:BuildAliases()
    -- Les ancres dediees du profil courant (un changement de profil redemarre
    -- le module sans repasser par OnInitialize).
    self:CreateSavedOverrideGroups()

    if ns.has.encounterEvents then
        self:RegisterEvent("ENCOUNTER_START")
        self:RegisterEvent("ENCOUNTER_END")
    end
    if ns.has.bossUnitFrames then
        self:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    end
    self:RegisterRawEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self:RegisterEvent("GROUP_ROSTER_UPDATE")
    self:RegisterEvent("PARTY_MEMBERS_CHANGED", "GROUP_ROSTER_UPDATE")
    self:RegisterEvent("RAID_ROSTER_UPDATE", "GROUP_ROSTER_UPDATE")
    self:RegisterMessage("TEST_STOPPED", function() self:StopTestBoss() end)

    Comm:On("PULL", function(...) self:OnSyncPull(...) end)
    Comm:On("PHASE", function(...) self:OnSyncPhase(...) end)
    Comm:On("END", function(...) self:OnSyncEnd(...) end)
    Comm:On("REQ", function() self:OnSyncRequest() end)
    self:Schedule("syncRequest", 2, function() self:RequestState() end)

    local problems = self:ValidateData()
    if problems > 0 then
        ns.Print(("%d probleme(s) dans les fichiers de data."):format(problems))
    end
    ns.Debug("bossTimer actif —", self:CountData(), "boss charge(s)")
end

function M:OnDisable()
    self:Disengage("disable")
    self:StopTestBoss()
    Comm:Off("PULL")
    Comm:Off("PHASE")
    Comm:Off("END")
    Comm:Off("REQ")
    self:UnregisterAllEvents()
    self:UnregisterAllMessages()
    self:CancelAllTimers()
    self:ClearBars()
    self:HidePhaseFrame()
end
