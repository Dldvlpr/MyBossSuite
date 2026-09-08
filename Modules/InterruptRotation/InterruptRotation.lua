-- Modules/InterruptRotation/InterruptRotation.lua
-- Rotation d'interrupt : a qui le tour, et surtout — quand se taire.
--
-- Le module ne mesure rien lui-meme. Tout ce qu'il sait vient du CD Tracker
-- (phase 5), qui tient deja la seule information exacte disponible : le
-- cooldown que chaque joueur annonce lui-meme. La rotation n'en est que la
-- lecture ordonnee. Sans CD Tracker actif, elle n'a rien a dire et le dit.
--
-- Deux regles portent tout le module :
--
--   1. **`SPELL_CAST_SUCCESS`, jamais `SPELL_INTERRUPT`.** Un kick lance dans le
--      vide (rien a interrompre a cet instant) part quand meme en cooldown sans
--      generer le moindre `SPELL_INTERRUPT`. Ecouter le mauvais evenement, c'est
--      designer un joueur qui n'a plus son kick — et l'interrupt passe a
--      travers. C'est le bug qui tue la credibilite d'une rotation, donc c'est
--      celui contre lequel le module est ecrit.
--
--   2. **« Je ne sais pas » n'est pas « c'est pret ».** Un joueur n'entre dans
--      l'ordre que s'il a annonce son interrupt au moins une fois. Un joueur
--      muet (pas d'addon) n'est jamais designe, jamais compte, et ne fait donc
--      jamais taire personne.
--
-- Ordre : les porteurs d'interrupt tries par NOM, pas par position de groupe.
-- `party1` n'est pas le meme joueur pour toi et pour moi, alors que le tri par
-- nom donne le meme ordre sur tous les clients — sans le negocier, sans un seul
-- message reseau de plus.

local _, ns = ...

local GetTime      = GetTime
local UnitFullName = ns.UnitFullName
local ShortName    = ns.ShortName

-- Delai au bout duquel une incantation encore vivante rend la main a tout le
-- monde. Le joueur designe n'a pas kicke (mort, silence, distance, absent
-- devant son ecran) : passe ce delai, un kick en double coute moins cher qu'un
-- kick manque. C'est le compromis central du module.
local DEFAULT_HANDOFF = 1.2

local MAX_LINES    = 5
local LIST_REFRESH = 0.25

-- Le cadre reevalue sa visibilite tout seul : personne n'emet d'evenement quand
-- un troisieme porteur de kick se declare au milieu du combat.
local WATCH_INTERVAL = 1

local M = ns:NewModule("interruptRotation", {
    enabled    = true,
    list       = true,              -- cadre de file a l'ecran
    hold       = true,              -- retenir l'alerte kick quand ce n'est pas ton tour
    combatOnly = true,              -- ... et ne montrer le cadre qu'en combat
    handoff    = DEFAULT_HANDOFF,   -- secondes avant de rendre la main a tous
    minPlayers = 2,                 -- en dessous, il n'y a pas de rotation
})
M.title = "Rotation d'interrupt"

local ANCHOR_KEY = "InterruptRotation_List"

local COLOR_READY = "|cff40dd60"
local COLOR_WAIT  = "|cffaaaaaa"
local COLOR_TURN  = "|cffffd100"

--------------------------------------------------------------------------------
-- Sorts d'interruption
--------------------------------------------------------------------------------
-- La liste par classe vit dans le module d'alerte kick (`ns.InterruptSpells`),
-- deja curee et testee. Ici on n'a besoin que de l'ensemble a plat : « ce
-- spellId est-il un interrupt, quelle que soit la classe ». Construit a la
-- premiere demande, parce que le fichier de data peut se charger apres celui-ci.

local interruptIds

function M:InterruptIds()
    if interruptIds then return interruptIds end
    interruptIds = {}
    for _, list in pairs(ns.InterruptSpells or {}) do
        for i = 1, #list do interruptIds[list[i]] = true end
    end
    return interruptIds
end

function M:IsInterrupt(spellId)
    return spellId ~= nil and self:InterruptIds()[spellId] == true
end

--- Un sort d'interruption sert parfois aussi de sort de degats (le Choc de
-- terre du chaman en classic). Ca ne demande aucun cas particulier : lance pour
-- taper, il part quand meme en cooldown, donc le tour passe bel et bien.

--------------------------------------------------------------------------------
-- Source des cooldowns
--------------------------------------------------------------------------------

function M:Tracker()
    local tracker = ns:GetModule("cdTracker")
    if not tracker or not tracker.isEnabled then return nil end
    return tracker
end

--- Les interrupts qu'on sait possedes par un joueur, ou `nil` si on ne sait
-- rien de lui. Un joueur muet n'a pas d'entree : « je ne sais pas » ne doit
-- jamais se confondre avec « son kick est pret ».
function M:InterruptSpellsOf(tracker, unit)
    local known = tracker:KnownSpells(unit)
    local out
    for i = 1, #known do
        if self:IsInterrupt(known[i]) then
            out = out or {}
            out[#out + 1] = known[i]
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Ordre
--------------------------------------------------------------------------------

-- Les porteurs d'interrupt du groupe, tries par nom, en cache.
--
-- Le tri par nom n'est pas un detail d'affichage : `party1` n'est pas le meme
-- joueur pour toi et pour moi, alors que le tri par nom donne le meme ordre sur
-- tous les clients — sans le negocier, sans un message reseau de plus.
--
-- Le cache, lui, est la parce que c'est un chemin chaud : l'alerte kick demande
-- le tour cinq fois par seconde pendant chaque incantation surveillee. Cette
-- liste ne change qu'a deux moments — le roster bouge, ou un joueur annonce un
-- interrupt pour la premiere fois — et les deux l'invalident. Les cooldowns,
-- eux, se relisent a chaque appel : deux lectures de table par sort, aucune
-- allocation.
local carriers
local EMPTY = {}

function M:InvalidateCarriers()
    carriers = nil
end

function M:Carriers()
    local tracker = self:Tracker()
    -- Teste avant le cache : le CD Tracker peut avoir ete eteint depuis, et une
    -- liste survivante ferait designer des joueurs sur des donnees mortes.
    if not tracker then
        carriers = nil
        return EMPTY
    end
    if carriers then return carriers end

    carriers = {}
    local me = UnitFullName("player")
    local seen = {}

    local function add(unit)
        if not unit or seen[unit] then return end
        seen[unit] = true
        local spells = self:InterruptSpellsOf(tracker, unit)
        if spells then
            carriers[#carriers + 1] = { unit = unit, spells = spells, isMe = (unit == me) }
        end
    end

    add(me)
    local prefix, count = ns.GroupUnitPrefix()
    for i = 1, count do add(UnitFullName(prefix .. i)) end

    table.sort(carriers, function(a, b) return a.unit < b.unit end)
    return carriers
end

--- Relit le cooldown d'un porteur. Un joueur qui porte deux interrupts (Pummel
-- et Bouclier percutant) est pret des que l'un des deux l'est, et son attente
-- est celle du plus court.
function M:Refresh(tracker, entry)
    local best
    for i = 1, #entry.spells do
        -- nil = aucun cooldown en cours pour un sort qu'on sait possede,
        -- c'est-a-dire pret. Cf. CDTracker:ReadyUnits.
        local remaining = tracker:Remaining(entry.unit, entry.spells[i]) or 0
        if not best or remaining < best then best = remaining end
    end
    entry.remaining = best or 0
    entry.ready = entry.remaining <= 0
    return entry
end

--- Indice du dernier joueur a avoir kicke, 0 s'il n'est pas (ou plus) dans la
-- liste. On retient un NOM, pas un indice : le groupe se recompose en combat, et
-- un indice designerait alors quelqu'un d'autre sans prevenir.
local function StartIndex(list, lastCaster)
    for i = 1, #list do
        if list[i].unit == lastCaster then return i end
    end
    return 0
end

--- Les porteurs, cooldowns a jour, dans l'ordre stable (pas dans l'ordre du
-- tour) : c'est ce que lisent le statut et les tests.
function M:Order()
    local tracker = self:Tracker()
    local list = self:Carriers()
    if not tracker then return list end
    for i = 1, #list do self:Refresh(tracker, list[i]) end
    return list
end

--- La file, tournee pour commencer juste apres le dernier joueur a avoir kicke.
-- Alloue, donc reservee a l'affichage et aux commandes — jamais au chemin chaud.
function M:Queue()
    local tracker = self:Tracker()
    local list = self:Carriers()
    local count = #list
    local out = {}
    if not tracker or count == 0 then return out end

    local start = StartIndex(list, self.lastCaster)
    for i = 0, count - 1 do
        out[#out + 1] = self:Refresh(tracker, list[((start + i) % count) + 1])
    end
    return out
end

--- Le joueur designe : le premier de la file dont l'interrupt est reellement
-- pret. `nil` quand personne ne l'est — et ca veut dire « debrouillez-vous »,
-- pas « attendez ».
-- Deuxieme retour : celui qui revient le plus tot, pour l'affichage.
function M:Designated()
    local tracker = self:Tracker()
    local list = self:Carriers()
    local count = #list
    if not tracker or count == 0 then return nil end

    local start = StartIndex(list, self.lastCaster)
    local soonest
    for i = 0, count - 1 do
        local entry = self:Refresh(tracker, list[((start + i) % count) + 1])
        if entry.ready then return entry, entry end
        if not soonest or entry.remaining < soonest.remaining then soonest = entry end
    end
    return nil, soonest
end

--- Y a-t-il seulement une rotation ? Trois conditions, et la troisieme compte
-- autant que les autres : si TU ne portes pas d'interrupt, aucune rotation ne
-- te concerne et rien ne doit retenir ton alerte.
function M:IsActive()
    local config = self:GetConfig()
    if not config then return false end
    local list = self:Carriers()
    local minimum = math.max(2, tonumber(config.minPlayers) or 2)
    if #list < minimum then return false end
    for i = 1, #list do
        if list[i].isMe then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Tour de garde
--------------------------------------------------------------------------------

function M:ClearHold()
    self.hold = nil
end

--- Qui doit kicker cette incantation a ta place, ou `nil` si c'est a toi (ou si
-- rien ne s'y oppose). `castKey` identifie l'incantation en cours : c'est lui
-- qui date le debut de l'attente, donc qui declenche la remise en jeu.
--
-- Appele par le module d'alerte kick a chaque evaluation. Le module de rotation
-- reste optionnel : sans lui, l'alerte est celle de toujours.
function M:Holder(castKey)
    local config = self:GetConfig()
    if not config or config.hold == false then return nil end
    if not self:IsActive() then return nil end

    local designated = self:Designated()
    if not designated or designated.isMe then
        self:ClearHold()
        return nil
    end

    local now = GetTime()
    local hold = self.hold
    if not hold or hold.key ~= castKey then
        hold = { key = castKey, since = now }
        self.hold = hold
    end

    local handoff = tonumber(config.handoff) or DEFAULT_HANDOFF
    if handoff > 0 and now - hold.since >= handoff then return nil end

    return ShortName(designated.unit)
end

--- Un interrupt vient de partir : le tour passe a celui d'apres.
-- Le tour avance meme quand ce n'est pas le joueur designe qui a kicke : la
-- rotation suit ce qui s'est reellement passe, elle ne le corrige pas.
function M:NoteCast(unit, spellId)
    if not unit then return false end
    self.lastCaster = unit
    self.lastCastAt = GetTime()
    self.lastCastSpell = spellId
    self:ClearHold()
    self:RefreshList()
    ns.EventBus:Fire("INTERRUPT_ROTATION_ADVANCED", unit, spellId)
    return true
end

function M:Reset()
    self.lastCaster, self.lastCastAt, self.lastCastSpell = nil, nil, nil
    self:ClearHold()
    self:RefreshList()
end

--------------------------------------------------------------------------------
-- Combat log — chemin chaud
--------------------------------------------------------------------------------
-- Deux comparaisons pour sortir : le sous-evenement, puis le GUID. La table des
-- GUID du groupe est refaite sur changement de roster, jamais dans le handler.

local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

function M:RebuildGuidMap()
    local map = {}
    local guid = UnitGUID("player")
    if guid then map[guid] = UnitFullName("player") end

    local prefix, count = ns.GroupUnitPrefix()
    for i = 1, count do
        local unit = prefix .. i
        local unitGuid = UnitGUID(unit)
        if unitGuid then map[unitGuid] = UnitFullName(unit) end
    end

    self.guidNames = map
    return map
end

local function OnCombatLog()
    local _, sub, _, srcGUID, _, _, _, _, _, _, _, spellId = CombatLogGetCurrentEventInfo()
    if sub ~= "SPELL_CAST_SUCCESS" then return end

    local names = M.guidNames
    local unit = names and names[srcGUID]
    if not unit then return end
    if not M:IsInterrupt(spellId) then return end

    M:NoteCast(unit, spellId)
end

--------------------------------------------------------------------------------
-- Cadre de file
--------------------------------------------------------------------------------
-- Qui vient, dans l'ordre, avec l'attente de chacun. Le designe porte un chevron
-- et la couleur d'appel ; les autres sont gris. C'est la seule chose a regarder
-- quand on ne sait pas si on doit kicker ou garder son kick.

function M:GetListFrame()
    if self.listFrame then return self.listFrame end

    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(160, 20 + MAX_LINES * 14)
    frame:Hide()

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    ns.SetSolidColor(bg, 0, 0, 0, 0.55)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -4)
    title:SetJustifyH("LEFT")
    title:SetText("Interrupts")
    frame.title = title

    frame.lines = {}
    for i = 1, MAX_LINES do
        local line = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -18 - (i - 1) * 14)
        line:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -18 - (i - 1) * 14)
        line:SetJustifyH("LEFT")
        frame.lines[i] = line
    end

    frame.sinceRefresh = 0
    frame:SetScript("OnUpdate", function(f, elapsed)
        f.sinceRefresh = f.sinceRefresh + elapsed
        if f.sinceRefresh < LIST_REFRESH then return end
        f.sinceRefresh = 0
        M:RefreshList()
    end)

    ns.Anchors:Register(frame, ANCHOR_KEY, {
        label        = "Rotation d'interrupt",
        defaultPoint = { "CENTER", "UIParent", "CENTER", -280, 0 },
        test         = function() M:TestList() end,
    })

    self.listFrame = frame
    return frame
end

local function LineText(entry, designated)
    local isTurn = (designated ~= nil and entry.unit == designated.unit)
    local color = isTurn and COLOR_TURN or (entry.ready and COLOR_READY or COLOR_WAIT)
    -- Arrondi vers le haut : afficher « 0s » pour un kick qui n'est pas encore
    -- revenu ferait passer la file pour cassee.
    local state = entry.ready and "pret" or ("%ds"):format(math.ceil(entry.remaining))
    return ("%s%s %s|r  %s%s|r"):format(
        color, isTurn and ">" or " ", ShortName(entry.unit),
        entry.ready and COLOR_READY or COLOR_WAIT, state)
end

function M:RefreshList()
    local frame = self.listFrame
    if not frame or not frame:IsShown() or frame.testing then return end

    -- Le designe se lit dans la file deja construite (le premier pret), plutot
    -- que par un second parcours qui dirait la meme chose.
    local queue = self:Queue()
    local designated
    for i = 1, #queue do
        if queue[i].ready then designated = queue[i] break end
    end

    for i = 1, MAX_LINES do
        local entry = queue[i]
        frame.lines[i]:SetText(entry and LineText(entry, designated) or "")
    end
end

--- Le cadre n'a de sens que quand la rotation en a un. Reevalue sur un ticker
-- lent plutot que sur evenement : rien ne signale l'arrivee d'un troisieme
-- porteur de kick au milieu d'un combat.
--
-- « En combat » se lit sur le GROUPE, jamais sur le seul `PLAYER_REGEN_ENABLED`
-- — celui-la tombe aussi quand tu meurs ou que tu sors du combat pendant que le
-- raid continue, et la file disparaitrait au moment ou elle sert le plus. Meme
-- regle que le Boss Timer.
function M:UpdateVisibility()
    local frame = self.listFrame
    local config = self:GetConfig()
    if not config then return end

    -- Fin de combat du groupe : la file repart du debut au pull suivant. La
    -- garder ferait commencer le combat suivant au milieu de l'ordre, sans que
    -- personne ne comprenne pourquoi.
    local inCombat = self.isEnabled and ns.IsGroupInCombat() or false
    if self.inCombat and not inCombat then self:Reset() end
    self.inCombat = inCombat

    if frame and (frame.mbsForcedShow or frame.mbsUnlocked or frame.testing) then return end

    local wanted = self.isEnabled and config.list ~= false and self:IsActive()
    if wanted and config.combatOnly ~= false then wanted = inCombat end

    if not wanted then
        if frame then frame:Hide() end
        return
    end

    frame = self:GetListFrame()
    frame.sinceRefresh = LIST_REFRESH
    frame:Show()
    self:RefreshList()
end

function M:HideList()
    local frame = self.listFrame
    if not frame then return end
    frame.testing = nil
    if frame.mbsForcedShow or frame.mbsUnlocked then return end
    frame:Hide()
end

-- Apercu pour /mbs test : une file factice, le temps de placer le cadre hors
-- groupe. Sans elle, le cadre serait invisible partout ou on peut le deplacer.
function M:TestList()
    local frame = self:GetListFrame()
    local fake = {
        { name = "Tank",    state = "pret", turn = true },
        { name = "Voleur",  state = "4s" },
        { name = "Mage",    state = "11s" },
    }
    for i = 1, MAX_LINES do
        local entry = fake[i]
        if entry then
            local color = entry.turn and COLOR_TURN or COLOR_WAIT
            frame.lines[i]:SetText(("%s%s %s|r  %s%s|r"):format(
                color, entry.turn and ">" or " ", entry.name,
                entry.state == "pret" and COLOR_READY or COLOR_WAIT, entry.state))
        else
            frame.lines[i]:SetText("")
        end
    end
    frame.testing = true
    frame:Show()
end

--- Fin du mode test. Ecoute posee au chargement du fichier, pas dans OnEnable :
-- le cadre est deplacable et testable meme module eteint, donc son etat de test
-- doit pouvoir se terminer dans le meme cas.
function M:StopTestList()
    local frame = self.listFrame
    if not frame or not frame.testing then return end
    frame.testing = nil
    self:UpdateVisibility()
    if not frame.mbsForcedShow and not frame.mbsUnlocked and not self.isEnabled then
        frame:Hide()
    end
end

ns.EventBus:On("TEST_STOPPED", function() M:StopTestList() end)

--------------------------------------------------------------------------------
-- Etat lisible (/mbs rotation)
--------------------------------------------------------------------------------

function M:StatusLines()
    local config = self:GetConfig() or {}
    local tracker = self:Tracker()
    if not tracker then
        return {
            "|cffff5555le CD Tracker est eteint|r — la rotation n'a aucune source.",
            "  la seule donnee exacte est le cooldown que chaque joueur annonce :",
            "  /mbs enable cdTracker",
        }
    end

    local order = self:Order()
    local designated, soonest = self:Designated()
    local turn = designated and ShortName(designated.unit)
        or (soonest and ("personne — %s dans %.1fs")
            :format(ShortName(soonest.unit), soonest.remaining))
        or "personne"

    return {
        ("porteurs d'interrupt connus : %d   rotation : %s"):format(
            #order, self:IsActive() and "active" or "inactive"),
        ("au tour de : %s"):format(turn),
        ("dernier kick : %s"):format(self.lastCaster
            and ("%s il y a %.0fs"):format(ShortName(self.lastCaster),
                GetTime() - (self.lastCastAt or GetTime()))
            or "aucun vu"),
        ("cadre %s | combat seul %s | retenue de l'alerte %s | remise en jeu %.1fs"):format(
            config.list ~= false and "on" or "off",
            config.combatOnly ~= false and "on" or "off",
            config.hold ~= false and "on" or "off",
            tonumber(config.handoff) or DEFAULT_HANDOFF),
    }
end

--- Ce que /mbs rotation list affiche : la file, avec l'etat de chacun.
function M:ListLines()
    local queue = self:Queue()
    local designated = self:Designated()
    local out = {}
    for i = 1, #queue do
        local entry = queue[i]
        out[#out + 1] = ("%s%d. %-14s %s|r  |cffaaaaaa%s|r"):format(
            (designated and entry.unit == designated.unit) and COLOR_TURN or COLOR_WAIT,
            i, ShortName(entry.unit),
            entry.ready and "pret" or ("%.1fs"):format(entry.remaining),
            ns.GetSpellName(entry.spellId) or ("sort " .. tostring(entry.spellId)))
    end
    return out
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- Le joueur dont c'etait le tour vient peut-etre de partir : rien a nettoyer.
-- Le pointeur est un NOM, et un nom qui n'est plus dans la liste fait
-- simplement repartir la file de son debut (`StartIndex`). Le chercher ici
-- dependrait en plus de l'ordre des handlers du meme evenement — le CD Tracker
-- oublie les partants sur ce meme GROUP_ROSTER_UPDATE.
function M:GROUP_ROSTER_UPDATE()
    self:RebuildGuidMap()
    self:InvalidateCarriers()
    self:UpdateVisibility()
end

function M:PLAYER_ENTERING_WORLD()
    self:RebuildGuidMap()
    self:InvalidateCarriers()
    self:UpdateVisibility()
end

-- Les deux evenements de combat du joueur ne decident de rien : ils ne font que
-- provoquer une reevaluation immediate, que le ticker aurait faite dans la
-- seconde. C'est `ns.IsGroupInCombat` qui tranche.
function M:PLAYER_REGEN_DISABLED()
    self:UpdateVisibility()
end

M.PLAYER_REGEN_ENABLED = M.PLAYER_REGEN_DISABLED

--------------------------------------------------------------------------------
-- Cycle de vie
--------------------------------------------------------------------------------

function M:OnInitialize()
    self:GetListFrame()
end

function M:OnEnable()
    self:Reset()
    self:RebuildGuidMap()
    self:InvalidateCarriers()

    self:RegisterRawEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
    self:RegisterEvent("GROUP_ROSTER_UPDATE")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")

    -- Un porteur de plus (ou de moins) : la liste en cache doit repartir de la
    -- verite du CD Tracker, sinon un joueur qui vient d'annoncer son kick
    -- resterait invisible a la rotation jusqu'au prochain changement de groupe.
    self:RegisterMessage("CD_KNOWN_CHANGED", function() self:InvalidateCarriers() end)

    self:Repeat("watch", WATCH_INTERVAL, function() self:UpdateVisibility() end)
    self:UpdateVisibility()
end

function M:OnDisable()
    self.inCombat = nil
    self:UnregisterAllEvents()
    self:UnregisterAllMessages()
    self:CancelAllTimers()
    self.guidNames = nil
    self:InvalidateCarriers()
    self:Reset()
    self:HideList()
end
