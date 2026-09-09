-- Modules/BossTimer/Bridge.lua
-- Pont vers les boss mods installes chez le joueur : DBM et BigWigs.
--
-- Ce fichier ne CONTIENT aucune data de boss et n'en extrait aucune. Il ecoute
-- les callbacks publics que les deux addons emettent en jeu — la meme surface
-- que le trigger `BOSS_MOD` de WeakAuras utilise depuis des annees — et
-- redessine leurs barres sur les ancres de MyBossSuite. Rien n'est copie, rien
-- n'est derive, rien n'est versionne : c'est de l'interoperabilite a
-- l'execution, chez celui qui a deja les deux addons installes.
--
-- C'est exactement ce qui distingue ce pont de la phase 3c (docs/ROADMAP.md),
-- fermee : ecrire les timings de DBM/BigWigs dans Modules/BossTimer/Data/
-- ferait une oeuvre derivee de deux projets All Rights Reserved. Les lire chez
-- le joueur, non — c'est son client, ses addons, sa memoire.
--
-- Regle de preseance, non negociable : **la data de MyBossSuite gagne
-- toujours**. Le pont ne parle que la ou on n'a rien — rencontre inconnue, ou
-- aucune data pour ce flavor. Des qu'un `Engage` reel a lieu, les barres du
-- pont disparaissent : deux sources pour la meme capacite, c'est une de trop.
--
-- Et une barre du pont porte sa source dans son libelle. Un chiffre de DBM
-- n'est pas une mesure de MyBossSuite ; l'afficher comme telle serait le seul
-- vrai mensonge que ce module puisse commettre.

local _, ns = ...

local Bars     = ns.Bars
local EventBus = ns.EventBus
local GetTime  = GetTime

local Bridge = {}
ns.BossTimerBridge = Bridge

local ANCHOR_KEY   = "BossTimer_Bridge"
-- Gris-bleu eteint, deliberement different du bleu des barres mesurees.
local BRIDGE_COLOR = { 0.55, 0.55, 0.62 }

-- Duree hors de laquelle un timer recu n'est pas un timer : une valeur qui
-- tombe la vient d'un decalage d'arguments en amont, pas d'un boss.
local MAX_DURATION = 3600
local MAX_STAGE    = 20

local SOURCE_LABEL = { dbm = "DBM", bw = "BigWigs" }
local SOURCE_TAG   = { dbm = "|cff999999DBM|r ", bw = "|cff999999BW|r " }

Bridge.hooked = {}    -- [source] = true si les callbacks sont poses
Bridge.bars   = {}    -- [barId]  = { source, label, icon, endTime, paused, remaining }
Bridge.stats  = { started = 0, ignored = 0 }
Bridge.active = false
Bridge.engagedBy = nil   -- source ayant declenche l'engage generique en cours

--------------------------------------------------------------------------------
-- Preseance
--------------------------------------------------------------------------------

local function Module()
    return ns.modules and ns.modules.bossTimer
end

function Bridge:Enabled()
    if not self.active then return false end
    local module = Module()
    if not module or not module.isEnabled then return false end
    local config = module:GetConfig()
    return not config or config.bridge ~= false
end

--- Le pont ne parle que la ou MyBossSuite n'a rien : pas en mode test, et pas
-- pendant une rencontre dont on a la data. Chaque handler commence par ce test,
-- ce qui rend le decrochage des callbacks facultatif : meme si l'amont ne sait
-- pas les retirer, ils ne font plus rien.
function Bridge:Accepts()
    if not self:Enabled() then return false end
    local module = Module()
    if module.testing then return false end
    if module.engaged and not module.generic then return false end
    return true
end

--------------------------------------------------------------------------------
-- Barres
--------------------------------------------------------------------------------

local function TestBars(group)
    Bars:TestBar(group, "bridge1", 18, SOURCE_TAG.dbm .. "Flame Breath", nil, BRIDGE_COLOR)
    Bars:TestBar(group, "bridge2", 32, SOURCE_TAG.bw .. "Fireball Volley", nil, BRIDGE_COLOR)
end

function Bridge:GetGroup()
    return Bars:GetGroup(ANCHOR_KEY, {
        label        = "Boss Timer - autre addon",
        width        = 240,
        height       = 18,
        color        = BRIDGE_COLOR,
        defaultPoint = { "CENTER", "UIParent", "CENTER", 300, -160 },
        test         = TestBars,
    })
end

local function BarId(source, key)
    return source .. ":" .. tostring(key)
end

--- Une texture valide, ou rien. `SetTexture` lance sur un type inattendu, et un
-- argument decale en amont arriverait ici sous forme de table.
local function CleanIcon(icon)
    local kind = type(icon)
    if kind == "string" or kind == "number" then return icon end
    return nil
end

function Bridge:Ignore(source, why, value)
    self.stats.ignored = self.stats.ignored + 1
    ns.Debug("pont", source, why, tostring(value))
    return false
end

function Bridge:StartBar(source, key, text, duration, icon)
    if not self:Accepts() then return false end
    if key == nil then return self:Ignore(source, "barre sans identifiant") end

    duration = tonumber(duration)
    if not duration or duration <= 0 or duration > MAX_DURATION then
        return self:Ignore(source, "duree refusee", duration)
    end

    if type(text) ~= "string" or text == "" then text = tostring(key) end
    icon = CleanIcon(icon)

    local id    = BarId(source, key)
    local label = (SOURCE_TAG[source] or "") .. text
    self.bars[id] = {
        source  = source,
        label   = label,
        icon    = icon,
        endTime = GetTime() + duration,
    }
    self.stats.started = self.stats.started + 1
    self:GetGroup():StartBar(id, duration, label, icon, { color = BRIDGE_COLOR })
    return true
end

--- Arreter n'est jamais conditionne a `Accepts` : une barre affichee avant que
-- la preseance change doit pouvoir disparaitre ensuite.
function Bridge:StopBar(source, key)
    local id = BarId(source, key)
    if not self.bars[id] then return false end
    self.bars[id] = nil
    local group = Bars.groups[ANCHOR_KEY]
    if group then group:StopBar(id) end
    return true
end

--- `Core/Bars.lua` ne connait pas la pause : on retient le restant et on retire
-- la barre, la reprise la relance pour cette duree-la.
function Bridge:PauseBar(source, key)
    local entry = self.bars[BarId(source, key)]
    if not entry or entry.paused then return false end
    entry.paused    = true
    entry.remaining = math.max(0, entry.endTime - GetTime())
    local group = Bars.groups[ANCHOR_KEY]
    if group then group:StopBar(BarId(source, key)) end
    return true
end

function Bridge:ResumeBar(source, key)
    local id    = BarId(source, key)
    local entry = self.bars[id]
    if not entry or not entry.paused then return false end
    local remaining = entry.remaining or 0
    entry.paused, entry.remaining = nil, nil
    if remaining <= 0 or not self:Accepts() then
        self.bars[id] = nil
        return false
    end
    entry.endTime = GetTime() + remaining
    self:GetGroup():StartBar(id, remaining, entry.label, entry.icon, { color = BRIDGE_COLOR })
    return true
end

--- DBM recale un timer en cours (`elapsed` / `total`), il ne le redemarre pas.
function Bridge:UpdateBar(source, key, elapsed, total)
    local id    = BarId(source, key)
    local entry = self.bars[id]
    if not entry then return false end

    elapsed, total = tonumber(elapsed), tonumber(total)
    if not elapsed or not total or total <= 0 or total > MAX_DURATION then
        return self:Ignore(source, "recalage refuse", total)
    end

    local remaining = total - elapsed
    if remaining <= 0 then return self:StopBar(source, key) end
    entry.endTime = GetTime() + remaining
    if entry.paused then
        entry.remaining = remaining
        return true
    end
    if not self:Accepts() then return false end
    self:GetGroup():StartBar(id, remaining, entry.label, entry.icon, { color = BRIDGE_COLOR })
    return true
end

--- Efface les barres d'une source, ou toutes si `source` est nil.
function Bridge:Clear(source)
    local group = Bars.groups[ANCHOR_KEY]
    for id, entry in pairs(self.bars) do
        if not source or entry.source == source then
            self.bars[id] = nil
            if group then group:StopBar(id) end
        end
    end
end

function Bridge:Count()
    local n = 0
    for _ in pairs(self.bars) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------------
-- Rencontre
--------------------------------------------------------------------------------

--- Pull annonce par le boss mod. Sur les clients sans ENCOUNTER_START (vanilla,
-- TBC, Wrath), c'est la seule facon d'avoir un chrono de combat sur un boss dont
-- MyBossSuite n'a pas la data : le moteur maison, lui, exige un npcId connu.
-- Si un boss connu agit ensuite, `Engage` remplace cet engage generique sans
-- perdre l'heure du pull — le chemin d'upgrade existe deja.
function Bridge:Engage(source, encounterId, name)
    if not self:Accepts() then return false end
    local module = Module()
    if module.engaged then return false end
    module:EngageGeneric(encounterId or (source .. "-pull"),
        name or ("Rencontre (" .. (SOURCE_LABEL[source] or source) .. ")"))
    if not module.engaged then return false end
    self.engagedBy = source
    ns.Debug("pont", source, "engage generique", tostring(name))
    return true
end

--- Kill ou wipe annonce par le boss mod. On ne coupe la rencontre que si c'est
-- ce pont qui l'avait ouverte : le moteur maison sait finir ses propres combats,
-- et un boss mod qui se trompe ne doit pas pouvoir effacer une rencontre reelle.
function Bridge:End(source, reason)
    self:Clear(source)
    if self.engagedBy ~= source then return false end
    local module = Module()
    if not module or not module.engaged or not module.generic then return false end
    module:Disengage(reason)
    return true
end

--- Changement de stage annonce par le boss mod. Applique a une rencontre
-- generique seulement — celle ou MyBossSuite n'a pas de data, donc pas de
-- tableau `phases` a contredire. Les entrees sont creees a la volee : on ne
-- connait que les stages dont on a ete informe, et le libelle affiche donc
-- « Phase 2/2 » plutot qu'un total invente.
function Bridge:SetStage(source, stage)
    if not self:Accepts() then return false end
    local module = Module()
    if not module.engaged or not module.generic or not module.def then return false end

    stage = tonumber(stage)
    if not stage or stage < 1 or stage > MAX_STAGE then
        return self:Ignore(source, "stage refuse", stage)
    end

    local def = module.def
    def.phases = def.phases or {}
    for i = 1, stage do
        def.phases[i] = def.phases[i] or { alert = "Phase " .. i }
    end

    -- Une phase lue chez DBM n'est pas une observation a rediffuser au groupe :
    -- les autres porteurs de MyBossSuite ont leur propre boss mod, et le drapeau
    -- anti-echo existe exactement pour ca.
    local wasSyncing = module.syncing
    module.syncing = true
    local ok = module:SetPhase(stage, "bridge")
    module.syncing = wasSyncing
    return ok
end

--------------------------------------------------------------------------------
-- DBM
--------------------------------------------------------------------------------
-- Callbacks publics de DBM-Core. Les positions d'arguments sont celles que DBM
-- documente ; elles sont quand meme validees a l'arrivee. Si l'amont les
-- reordonne un jour, l'evenement est compte en « ignore » et rien ne s'affiche —
-- une barre fausse serait pire qu'une barre absente, et `/mbs boss` montre le
-- compteur.
--
--   DBM_TimerStart  (event, id, msg, duree, icon, timerType, spellId, ...)
--   DBM_TimerStop   (event, id)
--   DBM_TimerUpdate (event, id, elapsed, total)
--   DBM_TimerPause  (event, id)
--   DBM_TimerResume (event, id)
--   DBM_SetStage    (event, mod, modId, stage, ...)
--   DBM_Pull        (event, mod, delai, synced, startHp)
--   DBM_Kill / DBM_Wipe (event, mod)
--
-- Le premier argument est le nom du callback : il est absorbe par `_`, de sorte
-- qu'une version qui ne le passerait pas decale tout et echoue a la validation
-- au lieu d'afficher n'importe quoi.

local function DbmModName(mod)
    if type(mod) ~= "table" then return nil end
    local localization = mod.localization
    local general = type(localization) == "table" and localization.general or nil
    local name = type(general) == "table" and general.name or nil
    if type(name) == "string" and name ~= "" then return name end
    return nil
end

local function DbmModId(mod)
    if type(mod) ~= "table" then return nil end
    local id = mod.id
    if type(id) == "string" or type(id) == "number" then return id end
    return nil
end

local DBM_CALLBACKS = {
    DBM_TimerStart = function(_, id, msg, duration, icon)
        Bridge:StartBar("dbm", id, msg, duration, icon)
    end,
    DBM_TimerStop = function(_, id)
        Bridge:StopBar("dbm", id)
    end,
    DBM_TimerUpdate = function(_, id, elapsed, total)
        Bridge:UpdateBar("dbm", id, elapsed, total)
    end,
    DBM_TimerPause = function(_, id)
        Bridge:PauseBar("dbm", id)
    end,
    DBM_TimerResume = function(_, id)
        Bridge:ResumeBar("dbm", id)
    end,
    DBM_SetStage = function(_, _, _, stage)
        Bridge:SetStage("dbm", stage)
    end,
    DBM_Pull = function(_, mod)
        Bridge:Engage("dbm", DbmModId(mod), DbmModName(mod))
    end,
    DBM_Kill = function()
        Bridge:End("dbm", "kill")
    end,
    DBM_Wipe = function()
        Bridge:End("dbm", "wipe")
    end,
}

function Bridge:HookDBM()
    if self.hooked.dbm then return true end
    local DBM = _G.DBM
    if type(DBM) ~= "table" or type(DBM.RegisterCallback) ~= "function" then return false end

    local posed = 0
    for event, fn in pairs(DBM_CALLBACKS) do
        if pcall(DBM.RegisterCallback, DBM, event, fn) then posed = posed + 1 end
    end
    if posed == 0 then return false end
    self.hooked.dbm = true
    ns.Debug("pont : DBM branche (" .. posed .. " callbacks)")
    return true
end

function Bridge:UnhookDBM()
    if not self.hooked.dbm then return end
    local DBM = _G.DBM
    if type(DBM) == "table" and type(DBM.UnregisterCallback) == "function" then
        for event, fn in pairs(DBM_CALLBACKS) do
            pcall(DBM.UnregisterCallback, DBM, event, fn)
        end
    end
    self.hooked.dbm = nil
end

--------------------------------------------------------------------------------
-- BigWigs
--------------------------------------------------------------------------------
-- Messages publics de BigWigs, poses sur `BigWigsLoader` : le stub de
-- chargement existe des le login, bien avant le coeur, et sa file de messages
-- est celle que le coeur alimentera.
--
--   BigWigs_StartBar  (message, module, key, texte, duree, icon, isApprox)
--   BigWigs_StopBar   (message, module, texte)
--   BigWigs_StopBars  (message, module)
--   BigWigs_PauseBar  (message, module, texte)
--   BigWigs_ResumeBar (message, module, texte)
--   BigWigs_SetStage  (message, module, stage)
--   BigWigs_OnBossEngage / OnBossWin / OnBossWipe (message, module, ...)
--
-- Attention a l'identite d'une barre : BigWigs la demarre avec (`key`, `texte`)
-- mais l'arrete avec le seul `texte`. C'est donc le TEXTE qui identifie une
-- barre BigWigs, pas la cle — s'indexer sur `key` rendrait chaque StopBar
-- inoperant.

local function BwModuleName(module)
    if type(module) ~= "table" then return nil end
    local name = module.displayName
    if type(name) == "string" and name ~= "" then return name end
    return nil
end

local function BwModuleId(module)
    if type(module) ~= "table" then return nil end
    return tonumber(module.engageId) or tonumber(module.journalId) or nil
end

local BW_MESSAGES = {
    BigWigs_StartBar = function(_, _, key, text, duration, icon)
        local id = (type(text) == "string" and text ~= "") and text or key
        Bridge:StartBar("bw", id, text, duration, icon)
    end,
    BigWigs_StopBar = function(_, _, text)
        Bridge:StopBar("bw", text)
    end,
    BigWigs_StopBars = function()
        Bridge:Clear("bw")
    end,
    BigWigs_PauseBar = function(_, _, text)
        Bridge:PauseBar("bw", text)
    end,
    BigWigs_ResumeBar = function(_, _, text)
        Bridge:ResumeBar("bw", text)
    end,
    BigWigs_SetStage = function(_, _, stage)
        Bridge:SetStage("bw", stage)
    end,
    BigWigs_OnBossEngage = function(_, module)
        Bridge:Engage("bw", BwModuleId(module), BwModuleName(module))
    end,
    BigWigs_OnBossWin = function()
        Bridge:End("bw", "kill")
    end,
    BigWigs_OnBossWipe = function()
        Bridge:End("bw", "wipe")
    end,
}

function Bridge:HookBigWigs()
    if self.hooked.bw then return true end
    local loader = _G.BigWigsLoader
    if type(loader) ~= "table" or type(loader.RegisterMessage) ~= "function" then return false end

    -- Une table relais plutot que le pont lui-meme : CallbackHandler indexe ses
    -- inscriptions par cet objet et n'a aucune raison de tenir nos champs.
    self.bwRelay = self.bwRelay or {}

    local posed = 0
    for message, fn in pairs(BW_MESSAGES) do
        if pcall(loader.RegisterMessage, self.bwRelay, message, fn) then posed = posed + 1 end
    end
    if posed == 0 then return false end
    self.hooked.bw = true
    ns.Debug("pont : BigWigs branche (" .. posed .. " messages)")
    return true
end

function Bridge:UnhookBigWigs()
    if not self.hooked.bw then return end
    local loader = _G.BigWigsLoader
    if type(loader) == "table" and type(loader.UnregisterMessage) == "function" and self.bwRelay then
        for message in pairs(BW_MESSAGES) do
            pcall(loader.UnregisterMessage, self.bwRelay, message)
        end
    end
    self.hooked.bw = nil
end

--------------------------------------------------------------------------------
-- Cycle de vie
--------------------------------------------------------------------------------

function Bridge:Hook()
    self:HookDBM()
    self:HookBigWigs()
    self:Watch()
    return self.hooked.dbm or self.hooked.bw or false
end

--- Les deux boss mods peuvent se charger apres nous (chargement differe, ordre
-- alphabetique des .toc). On reessaie a chaque addon charge, et on cesse
-- d'ecouter des que les deux sont branches.
function Bridge:Watch()
    if self.hooked.dbm and self.hooked.bw then return self:Unwatch() end
    if not self.watcher then
        local frame = CreateFrame("Frame")
        frame:SetScript("OnEvent", function()
            Bridge:HookDBM()
            Bridge:HookBigWigs()
            if Bridge.hooked.dbm and Bridge.hooked.bw then Bridge:Unwatch() end
        end)
        self.watcher = frame
    end
    self.watcher:RegisterEvent("ADDON_LOADED")
end

function Bridge:Unwatch()
    if self.watcher then self.watcher:UnregisterEvent("ADDON_LOADED") end
end

function Bridge:Enable()
    if self.active then return end
    self.active = true
    self:Hook()
end

function Bridge:Disable()
    self.active = false
    self:Unwatch()
    self:UnhookDBM()
    self:UnhookBigWigs()
    self:Clear()
    self.engagedBy = nil
end

--- Une rencontre connue prend la main : les barres du pont s'effacent. C'est la
-- regle de preseance rendue visible — on ne laisse jamais les deux sources
-- s'empiler sur la meme rencontre.
EventBus:On("BOSS_ENGAGED", function()
    local module = Module()
    if module and module.engaged and not module.generic then Bridge:Clear() end
end)

EventBus:On("BOSS_DISENGAGED", function()
    Bridge.engagedBy = nil
    Bridge:Clear()
end)

--------------------------------------------------------------------------------
-- Etat
--------------------------------------------------------------------------------

--- Ce que /mbs boss affiche. Trois choses seulement, mais les trois qui
-- comptent : qui est branche, ce qui est a l'ecran, et ce qui a ete refuse —
-- un compteur d'« ignores » qui monte veut dire que l'amont a bouge.
function Bridge:StatusLine()
    local module = Module()
    local config = module and module:GetConfig()
    if config and config.bridge == false then
        return "pont boss mod : off"
    end

    local sources = {}
    if self.hooked.dbm then sources[#sources + 1] = SOURCE_LABEL.dbm end
    if self.hooked.bw  then sources[#sources + 1] = SOURCE_LABEL.bw end
    if #sources == 0 then
        return "pont boss mod : on, aucun boss mod detecte"
    end

    return ("pont boss mod : %s   barres %d   refusees %d%s"):format(
        table.concat(sources, " + "), self:Count(), self.stats.ignored,
        self:Accepts() and "" or "   |cffaaaaaa(muet : data maison prioritaire)|r")
end
