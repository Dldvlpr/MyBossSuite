-- Modules/CDTracker/CDTracker.lua
-- Cooldowns du groupe : qui a quoi de pret, et dans combien de temps.
--
-- Le principe qui rend le module possible sur les six flavors : **chaque client
-- connait SON propre cooldown exactement**. `GetSpellCooldown` tient compte des
-- talents, du haste et des procs — pour soi. Blizzard bloque volontairement la
-- lecture du cooldown d'un autre joueur (API anti-triche), donc la seule facon
-- d'avoir un chiffre juste est que ce joueur l'annonce lui-meme. C'est ce que
-- fait `Core/Comm.lua`, deja ecrit pour le Boss Timer.
--
-- Trois sources, par ordre de confiance :
--
--   `self`   ton propre cooldown, lu directement. Exact, sans reseau.
--   `mbs`    un pair qui fait tourner MyBossSuite et annonce le sien. Exact.
--   `lor`    LibOpenRaid, qui fait la meme chose pour les addons qui l'embarquent
--            (Details!, OmniCD...). Exact aussi — mais **retail uniquement** :
--            la bibliotheque sort en tete de son propre fichier sur tout client
--            non retail. Voir Modules/CDTracker/Libs/README.md.
--   `static` estimation depuis une table par flavor. **Aucune data livree pour
--            l'instant** : rien n'est affiche comme estime aujourd'hui.
--
-- Une source moins sure n'ecrase jamais une source plus sure encore fraiche :
-- un cooldown estime affiche a la place d'un cooldown exact est pire qu'un
-- joueur absent de la liste. Et un cooldown estime s'affiche grise et prefixe
-- « ~ », jamais comme un cooldown mesure.

local _, ns = ...

local Bars      = ns.Bars
local Comm      = ns.Comm
local GetTime   = GetTime

-- Remplie par les fichiers de Data/, charges apres celui-ci : les sorts a
-- suivre par classe, en plus des interrupts. Vide tant qu'aucune table statique
-- n'est ecrite — cf. Modules/CDTracker/Data/README.md.
ns.CDTrackerData = ns.CDTrackerData or {}

local M = ns:NewModule("cdTracker", {
    enabled    = true,
    bars       = true,     -- barres a l'ecran
    broadcast  = true,     -- annoncer SES cooldowns au groupe
    showSelf   = true,     -- s'afficher soi-meme dans la liste
    interrupts = true,     -- suivre les interrupts (la liste deja curee)
    estimates  = true,     -- afficher les cooldowns estimes (grises)
})
M.title = "CD Tracker"

local ANCHOR_KEY = "CDTracker_Bars"
local COLORS = {
    interrupt = { 0.25, 0.85, 1 },
    defensive = { 0.35, 0.75, 0.4 },
    offensive = { 0.9, 0.5, 0.2 },
    utility   = { 0.6, 0.6, 0.85 },
}
local DEFAULT_COLOR = { 0.5, 0.5, 0.6 }

-- Confiance des sources. Une valeur plus basse ne remplace pas une valeur plus
-- haute tant que celle-ci n'a pas expire.
local TRUST = { self = 4, mbs = 3, lor = 2, static = 1 }

-- Le cooldown est lu juste apres le cast : a l'instant exact ou le combat log
-- signale le sort, le client n'a pas encore arme le cooldown.
local READ_DELAY = 0.1

-- Reponse a une demande d'etat : jamais plus d'une fois par cette periode, et
-- avec un decalage aleatoire. Sans ca, vingt joueurs repondent dans la meme
-- image a l'arrivee d'un vingt-et-unieme.
local ANSWER_THROTTLE = 5
local ANSWER_JITTER   = 2

--------------------------------------------------------------------------------
-- Etat
--------------------------------------------------------------------------------

-- tracked[unit][spellId] = { start, duration, source, kind }
-- `unit` est le nom complet ("Nom" ou "Nom-Royaume") : c'est ce que livre un
-- message addon, et c'est ce qui distingue deux homonymes de royaumes
-- differents.
local tracked = {}
local lastAnswer = 0

-- Qui possede quel sort, appris de ses annonces. Initialise ici et pas dans
-- OnInitialize : `ReadyUnits` doit pouvoir repondre « je ne sais rien » avant
-- meme que le module soit initialise, jamais lever.
M.known = {}

local function UnitFullName(unit)
    local name, realm = UnitName(unit)
    if not name then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

local function ShortName(unit)
    return (unit and (unit:match("^([^%-]+)") or unit)) or "?"
end

--------------------------------------------------------------------------------
-- Identite d'un joueur
--------------------------------------------------------------------------------
-- Le meme joueur n'a pas forcement le meme nom des deux cotes : l'expediteur
-- d'un message addon arrive parfois avec son royaume ("Tank-Royaume") la ou
-- `UnitName("party1")` n'en rend aucun, et l'inverse existe aussi (royaumes
-- connectes). Deux orthographes du meme joueur, c'est deux entrees dans le
-- magasin, une barre en double, et un joueur qu'on croit sans kick alors qu'il
-- vient de l'annoncer.
--
-- On ramene donc tout nom recu sur celui du roster. Le compromis est celui que
-- `ns.IsOwnName` prend deja : deux homonymes de royaumes differents dans le meme
-- groupe ne sont pas separables par le nom court. Ici on refuse alors de
-- trancher plutot que de confondre — la correspondance exacte continue de
-- marcher, seule la correspondance courte est abandonnee.

local rosterMap

function M:RosterMap()
    if rosterMap then return rosterMap end
    rosterMap = {}

    local function add(unit)
        local full = UnitFullName(unit)
        if not full then return end
        rosterMap[full] = full
        local short = ShortName(full)
        if rosterMap[short] == nil then
            rosterMap[short] = full
        elseif rosterMap[short] ~= full then
            -- Deux joueurs partagent ce nom court : il ne designe plus personne.
            rosterMap[short] = false
        end
    end

    add("player")
    local prefix, count = ns.GroupUnitPrefix()
    for i = 1, count do add(prefix .. i) end
    return rosterMap
end

function M:ForgetRoster()
    rosterMap = nil
end

--- Nom de roster correspondant a `name`, ou `name` tel quel si le joueur n'y est
-- pas (encore) : les evenements de roster arrivent parfois apres le premier
-- message d'un nouveau venu.
function M:Canonical(name)
    if not name then return nil end
    local map = self:RosterMap()
    if map[name] then return map[name] end
    local short = map[ShortName(name)]
    if short then return short end
    return name
end

--------------------------------------------------------------------------------
-- Sorts suivis
--------------------------------------------------------------------------------
-- Ce que le module suit chez SOI. La liste des autres joueurs n'a pas besoin
-- d'etre connue : chacun annonce la sienne. C'est ce qui evite d'avoir a
-- maintenir une table de sorts par classe et par version du jeu — le probleme
-- qui rend un CD tracker classic habituellement faux.

--- Sorts a suivre pour une classe : les interrupts (liste deja curee et testee
-- par le module d'alerte kick) plus ce que la data declare.
function M:SpellsForClass(class)
    local out = {}
    local seen = {}

    local config = self:GetConfig()
    if (not config or config.interrupts ~= false) and ns.InterruptSpells then
        local list = ns.InterruptSpells[class or ""]
        for i = 1, (list and #list or 0) do
            local spellId = list[i]
            if not seen[spellId] then
                seen[spellId] = true
                out[#out + 1] = { spellId = spellId, kind = "interrupt" }
            end
        end
    end

    local extra = ns.CDTrackerData[class or ""]
    for i = 1, (extra and #extra or 0) do
        local entry = extra[i]
        if entry.spellId and not seen[entry.spellId] then
            seen[entry.spellId] = true
            out[#out + 1] = { spellId = entry.spellId, kind = entry.kind or "utility" }
        end
    end

    return out
end

--- Sorts que le joueur connait REELLEMENT, parmi ceux de sa classe.
-- `ns.KnowsSpell` couvre les rangs classic (un id par rang) via le repli par
-- nom : un id de rang 1 dans la table suffit a reconnaitre le rang 6 appris.
-- Un id qui ne correspond a rien ne passe simplement jamais ce filtre — c'est
-- ce qui rend une table de data approximative inoffensive.
function M:MySpells()
    if self.mySpells then return self.mySpells end
    local _, class = UnitClass("player")
    local out = {}
    local candidates = self:SpellsForClass(class)
    for i = 1, #candidates do
        local entry = candidates[i]
        if ns.KnowsSpell(entry.spellId) then
            out[#out + 1] = entry
        end
    end
    self.mySpells = out
    self:Debug(("%d sort(s) suivi(s) pour %s"):format(#out, tostring(class)))
    return out
end

function M:ForgetMySpells()
    self.mySpells = nil
end

--------------------------------------------------------------------------------
-- Magasin
--------------------------------------------------------------------------------

--- Enregistre un cooldown. Retourne true s'il a ete retenu.
-- `remaining` peut valoir 0 : ca veut dire « pret », et ca doit effacer une
-- entree plus ancienne plutot que de laisser une barre fantome tourner.
function M:Record(unit, spellId, remaining, duration, source, kind)
    if not unit or not spellId then return false end
    spellId = tonumber(spellId)
    remaining = tonumber(remaining) or 0
    duration = tonumber(duration) or 0
    if not spellId then return false end

    local trust = TRUST[source] or 0
    local byUnit = tracked[unit]
    local existing = byUnit and byUnit[spellId]

    if existing then
        -- Une source moins sure ne parle pas par-dessus une source plus sure
        -- tant que celle-ci a encore quelque chose a dire.
        local stillValid = existing.start + existing.duration > GetTime()
        if stillValid and (TRUST[existing.source] or 0) > trust then
            return false
        end
    end

    if remaining <= 0 or duration <= 0 then
        self:Clear(unit, spellId)
        return true
    end

    byUnit = byUnit or {}
    tracked[unit] = byUnit
    byUnit[spellId] = {
        start    = GetTime() - math.max(0, duration - remaining),
        duration = duration,
        source   = source,
        kind     = kind or (existing and existing.kind) or "utility",
    }
    self:ShowBar(unit, spellId, byUnit[spellId])
    return true
end

function M:Clear(unit, spellId)
    local byUnit = tracked[unit]
    if not byUnit then return end
    byUnit[spellId] = nil
    if not next(byUnit) then tracked[unit] = nil end
    if self.group then self.group:StopBar(unit .. "|" .. spellId) end
end

function M:ClearUnit(unit)
    local byUnit = tracked[unit]
    if not byUnit then return end
    for spellId in pairs(byUnit) do
        if self.group then self.group:StopBar(unit .. "|" .. spellId) end
    end
    tracked[unit] = nil
end

function M:ClearAll()
    for unit in pairs(tracked) do tracked[unit] = nil end
    if self.group then self.group:StopAll() end
end

function M:Get(unit, spellId)
    local byUnit = tracked[unit]
    return byUnit and byUnit[spellId]
end

--- Temps restant sur un cooldown connu, ou nil si on n'en sait rien.
-- nil et 0 ne veulent pas dire la meme chose : « je ne sais pas » n'est pas
-- « c'est pret ». La rotation d'interrupt (phase 6) repose entierement sur
-- cette distinction.
function M:Remaining(unit, spellId)
    local entry = self:Get(unit, spellId)
    if not entry then return nil end
    local remaining = entry.start + entry.duration - GetTime()
    return remaining > 0 and remaining or 0
end

--- Joueurs dont le sort est pret, dans l'ordre du groupe.
--
-- Deux conditions, et la premiere est celle qui compte : il faut **savoir** que
-- le joueur possede ce sort, c'est-a-dire qu'il l'ait annonce au moins une fois.
-- Un joueur dont on ne sait rien n'est jamais compte pret — designer quelqu'un
-- qui n'a plus son kick (ou qui ne l'a jamais eu) est le bug qui tue la
-- credibilite d'une rotation.
--
-- Une fois qu'on sait qu'il l'a, l'absence de cooldown enregistre veut bien dire
-- « pret » : soit il a annonce 0, soit le cooldown qu'on suivait est arrive a
-- terme. C'est `Knows` qui porte le doute, pas `Remaining`.
function M:ReadyUnits(spellId)
    local out = {}

    local function ready(unit)
        if not self:Knows(unit, spellId) then return false end
        local remaining = self:Remaining(unit, spellId)
        return remaining == nil or remaining <= 0
    end

    local me = UnitFullName("player")
    if me and ready(me) then out[#out + 1] = me end

    local prefix, count = ns.GroupUnitPrefix()
    for i = 1, count do
        local unit = UnitFullName(prefix .. i)
        if unit and unit ~= me and ready(unit) then out[#out + 1] = unit end
    end
    return out
end

--- Sait-on que ce joueur possede ce sort ? On ne le sait que s'il l'a annonce
-- au moins une fois.
function M:Knows(unit, spellId)
    local byUnit = self.known[unit]
    return byUnit ~= nil and byUnit[spellId] == true
end

function M:NoteKnown(unit, spellId)
    local byUnit = self.known[unit]
    if not byUnit then byUnit = {}; self.known[unit] = byUnit end
    byUnit[spellId] = true
end

--------------------------------------------------------------------------------
-- Affichage
--------------------------------------------------------------------------------

function M:GetGroup()
    if not self.group then
        self.group = Bars:GetGroup(ANCHOR_KEY, {
            label        = "CD Tracker",
            width        = 220,
            height       = 16,
            maxBars      = 10,
            defaultPoint = { "CENTER", "UIParent", "CENTER", 280, 0 },
            test = function(group)
                Bars:TestBar(group, ANCHOR_KEY, 24, "Testeur — Kick", nil, COLORS.interrupt)
            end,
        })
    end
    return self.group
end

function M:ShowBar(unit, spellId, entry)
    local config = self:GetConfig()
    if not config or config.bars == false then return end
    if config.showSelf == false and unit == UnitFullName("player") then return end

    local estimated = (entry.source == "static")
    if estimated and config.estimates == false then return end

    local remaining = entry.start + entry.duration - GetTime()
    if remaining <= 0 then return end

    local name = ns.GetSpellName(spellId) or ("sort " .. spellId)
    self:GetGroup():StartBar(unit .. "|" .. spellId, remaining,
        ("%s — %s"):format(ShortName(unit), name),
        ns.GetSpellTexture and ns.GetSpellTexture(spellId) or nil, {
            color    = COLORS[entry.kind] or DEFAULT_COLOR,
            -- `variable` grise la barre et la prefixe « ~ ». C'est exactement ce
            -- qu'on veut dire d'une estimation : utilisable, mais pas mesuree.
            variable = estimated,
            onExpire = function() self:Clear(unit, spellId) end,
        })
end

function M:RefreshBars()
    if not self.group then return end
    self.group:StopAll()
    local config = self:GetConfig()
    if not config or config.bars == false then return end
    for unit, byUnit in pairs(tracked) do
        for spellId, entry in pairs(byUnit) do
            self:ShowBar(unit, spellId, entry)
        end
    end
end

--------------------------------------------------------------------------------
-- Ses propres cooldowns
--------------------------------------------------------------------------------

--- Lit un cooldown chez soi et l'enregistre. C'est la seule lecture exacte que
-- le client autorise, et elle ne coute rien.
function M:ReadOwn(spellId, kind)
    local start, duration = ns.GetSpellCooldown(spellId)
    if not start then return nil end
    local me = UnitFullName("player")
    if not me then return nil end

    self:NoteKnown(me, spellId)

    -- Le GCD n'est pas un cooldown : l'annoncer ferait clignoter la liste a
    -- chaque sort lance. Meme regle que ns.GetSpellRemaining.
    if start == 0 or duration == 0 or duration <= 1.5 then
        self:Record(me, spellId, 0, 0, "self", kind)
        return 0, 0
    end

    local remaining = start + duration - GetTime()
    if remaining < 0 then remaining = 0 end
    self:Record(me, spellId, remaining, duration, "self", kind)
    return remaining, duration
end

function M:ReadAllOwn()
    local spells = self:MySpells()
    for i = 1, #spells do
        self:ReadOwn(spells[i].spellId, spells[i].kind)
    end
end

--------------------------------------------------------------------------------
-- Diffusion
--------------------------------------------------------------------------------

function M:Broadcast(spellId, remaining, duration, kind)
    local config = self:GetConfig()
    if not config or config.broadcast == false then return false end
    -- Les durees partent en entiers : un message addon est limite a 255 octets
    -- et une decimale sur un cooldown de 15 s n'interesse personne.
    return Comm:Send("CD", spellId, math.floor(remaining + 0.5),
        math.floor(duration + 0.5), kind or "utility")
end

--- Annonce tout ce qu'on a. Sert de reponse a une demande d'etat, et de
-- presentation a l'arrivee dans un groupe : c'est ce qui fait connaitre aux
-- autres les sorts qu'on possede, meme prets.
function M:BroadcastAll()
    local spells = self:MySpells()
    for i = 1, #spells do
        local entry = spells[i]
        local remaining, duration = self:ReadOwn(entry.spellId, entry.kind)
        if remaining then
            self:Broadcast(entry.spellId, remaining, duration or 0, entry.kind)
        end
    end
end

function M:AnswerRequest()
    local now = GetTime()
    if now - lastAnswer < ANSWER_THROTTLE then return end
    lastAnswer = now
    -- Decalage aleatoire : sans lui, tout le raid repond dans la meme image.
    self:Schedule("answer", math.random() * ANSWER_JITTER, function()
        self:BroadcastAll()
    end)
end

--- Se presenter au groupe et demander l'etat des autres. Passe par le meme
-- throttle que les reponses : un raid qui se recompose emet un
-- GROUP_ROSTER_UPDATE par arrivee, et se re-presenter a chacune inonderait le
-- canal pour rien.
function M:SayHello()
    local now = GetTime()
    if now - lastAnswer < ANSWER_THROTTLE then return end
    lastAnswer = now
    self:Schedule("hello", 1 + math.random() * ANSWER_JITTER, function()
        self:BroadcastAll()
        Comm:Send("CDREQ")
    end)
end

--------------------------------------------------------------------------------
-- Reception
--------------------------------------------------------------------------------

function M:OnCooldownMessage(sender, spellId, remaining, duration, kind)
    spellId = tonumber(spellId)
    if not spellId then return end
    sender = self:Canonical(sender)
    self:NoteKnown(sender, spellId)
    self:Record(sender, spellId, tonumber(remaining) or 0, tonumber(duration) or 0,
        "mbs", kind)
end

--------------------------------------------------------------------------------
-- Combat log — chemin chaud
--------------------------------------------------------------------------------
-- On ecoute SPELL_CAST_SUCCESS, pas SPELL_INTERRUPT : un kick lance dans le
-- vide part quand meme en cooldown mais ne genere aucun SPELL_INTERRUPT. Ecouter
-- le mauvais evenement ferait croire le sort encore disponible — c'est le bug
-- qui tue la credibilite du module, et de la rotation d'interrupt qui s'appuie
-- dessus.

local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local playerGUID

local function OnCombatLog()
    local _, sub, _, srcGUID, _, _, _, _, _, _, _, spellId = CombatLogGetCurrentEventInfo()
    if sub ~= "SPELL_CAST_SUCCESS" or srcGUID ~= playerGUID then return end

    local spells = M.mySpells
    if not spells then return end
    for i = 1, #spells do
        if spells[i].spellId == spellId then
            local kind = spells[i].kind
            -- Le cooldown n'est pas encore arme a l'instant du cast.
            M:Schedule("read_" .. spellId, READ_DELAY, function()
                local remaining, duration = M:ReadOwn(spellId, kind)
                if remaining and remaining > 0 then
                    M:Broadcast(spellId, remaining, duration, kind)
                end
            end)
            return
        end
    end
end

--------------------------------------------------------------------------------
-- LibOpenRaid (retail uniquement)
--------------------------------------------------------------------------------
-- La bibliotheque couvre les joueurs qui ne font pas tourner MyBossSuite mais
-- un addon qui l'embarque (Details!, OmniCD...). Elle ne se charge pas hors
-- retail : `LibStub:GetLibrary(..., true)` rend alors nil, et le module
-- fonctionne exactement pareil, juste avec une source de moins.

function M:GetLib()
    local libStub = _G.LibStub
    if not libStub or not libStub.GetLibrary then return nil end
    local ok, lib = pcall(libStub.GetLibrary, libStub, "LibOpenRaid-1.0", true)
    return ok and lib or nil
end

--- Lecture defensive de `GetCooldownStatusFromCooldownInfo`.
-- `docs.txt` de la bibliotheque se contredit sur l'ordre des retours (deux
-- blocs, deux ordres differents pour `timeLeft` et `percent`). La source fait
-- foi — `isReady, percent, timeLeft, charges, minValue, maxValue, currentValue,
-- duration` — mais on valide quand meme le resultat : mieux vaut ignorer une
-- mise a jour qu'afficher une barre fausse si l'amont reordonne un jour.
function M:ReadLibCooldown(lib, cooldownInfo)
    local ok, isReady, _, timeLeft, _, _, _, _, duration =
        pcall(lib.GetCooldownStatusFromCooldownInfo, cooldownInfo)
    if not ok then return nil end
    if isReady then return 0, tonumber(duration) or 0 end

    timeLeft = tonumber(timeLeft)
    duration = tonumber(duration)
    if not timeLeft or not duration or duration <= 0 then return nil end
    if timeLeft < 0 or timeLeft > duration + 1 then return nil end
    return timeLeft, duration
end

function M:OnLibCooldown(unitId, spellId, cooldownInfo)
    local lib = self.lib
    if not lib then return end
    local unit = UnitFullName(unitId)
    if not unit then return end
    unit = self:Canonical(unit)
    -- Ses propres cooldowns sont deja lus a la source : ne pas les degrader.
    if unit == UnitFullName("player") then return end

    self:NoteKnown(unit, spellId)
    local remaining, duration = self:ReadLibCooldown(lib, cooldownInfo)
    if not remaining then return end
    self:Record(unit, spellId, remaining, duration, "lor")
end

function M:HookLib()
    local lib = self:GetLib()
    self.lib = lib
    if not lib or not lib.RegisterCallback then return false end

    -- La bibliotheque appelle une METHODE nommee sur l'objet qu'on lui donne :
    -- on lui passe un relais plutot que le module, pour ne pas lui laisser la
    -- main sur nos propres champs.
    self.libRelay = self.libRelay or {
        OnCooldownUpdate = function(_, unitId, spellId, cooldownInfo)
            M:OnLibCooldown(unitId, spellId, cooldownInfo)
        end,
    }
    local ok = pcall(lib.RegisterCallback, lib, self.libRelay, "CooldownUpdate", "OnCooldownUpdate")
    if ok and lib.RequestAllData then pcall(lib.RequestAllData) end
    return ok and true or false
end

function M:UnhookLib()
    local lib = self.lib
    if lib and lib.UnregisterCallback and self.libRelay then
        pcall(lib.UnregisterCallback, lib, self.libRelay, "CooldownUpdate")
    end
    self.lib = nil
end

--------------------------------------------------------------------------------
-- Etat lisible (/mbs cd)
--------------------------------------------------------------------------------

function M:Status()
    local counts = { self = 0, mbs = 0, lor = 0, static = 0 }
    local units = 0
    for _, byUnit in pairs(tracked) do
        units = units + 1
        for _, entry in pairs(byUnit) do
            counts[entry.source] = (counts[entry.source] or 0) + 1
        end
    end
    return {
        units    = units,
        counts   = counts,
        mySpells = #self:MySpells(),
        lib      = self.lib ~= nil,
        -- Pourquoi la lib manque : ce n'est pas la meme chose de ne pas l'avoir
        -- installee et de tourner sur un client ou elle refuse de se charger.
        libWhy   = self.lib and "active"
            or (ns.isRetail and "absente (non chargee)" or "absente (ne se charge pas hors retail)"),
    }
end

--- Liste triee par temps restant : ce que /mbs cd list affiche.
function M:List()
    local out = {}
    for unit, byUnit in pairs(tracked) do
        for spellId, entry in pairs(byUnit) do
            out[#out + 1] = {
                unit      = unit,
                spellId   = spellId,
                remaining = math.max(0, entry.start + entry.duration - GetTime()),
                source    = entry.source,
                kind      = entry.kind,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.remaining ~= b.remaining then return a.remaining < b.remaining end
        return tostring(a.unit) < tostring(b.unit)
    end)
    return out
end

--------------------------------------------------------------------------------
-- Groupe
--------------------------------------------------------------------------------

--- Oublie ceux qui ne sont plus la. Une barre qui continue a tourner pour un
-- joueur parti est un mensonge tranquille.
function M:PruneRoster()
    self:ForgetRoster()
    local present = {}
    local me = UnitFullName("player")
    if me then present[me] = true end
    local prefix, count = ns.GroupUnitPrefix()
    for i = 1, count do
        local unit = UnitFullName(prefix .. i)
        if unit then present[unit] = true end
    end

    for unit in pairs(tracked) do
        if not present[unit] then self:ClearUnit(unit) end
    end
    for unit in pairs(self.known) do
        if not present[unit] then self.known[unit] = nil end
    end
end

function M:GROUP_ROSTER_UPDATE()
    self:PruneRoster()
    -- Nouveau groupe : on se presente, et on demande aux autres de le faire.
    self:SayHello()
end

function M:PLAYER_ENTERING_WORLD()
    playerGUID = UnitGUID("player")
    self:ForgetRoster()
    self:ForgetMySpells()
    self:ReadAllOwn()
    self:GROUP_ROSTER_UPDATE()
end

--- Un changement de talents (ou de spec) change la liste des sorts connus.
function M:SPELLS_CHANGED()
    self:ForgetMySpells()
    self:ReadAllOwn()
end

--------------------------------------------------------------------------------
-- Cycle de vie
--------------------------------------------------------------------------------

function M:OnInitialize()
    self.known = self.known or {}
    self:GetGroup()
end

function M:OnEnable()
    self.known = self.known or {}
    playerGUID = UnitGUID("player")
    self:ForgetMySpells()

    self:RegisterRawEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
    self:RegisterEvent("GROUP_ROSTER_UPDATE")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    if ns.EventExists("SPELLS_CHANGED") then
        self:RegisterEvent("SPELLS_CHANGED")
    end

    Comm:On("CD", function(sender, ...) self:OnCooldownMessage(sender, ...) end)
    Comm:On("CDREQ", function() self:AnswerRequest() end)

    self:HookLib()
    self:ReadAllOwn()
    self:PruneRoster()

    -- On se presente une fois en arrivant : les pairs deja en place n'ont aucune
    -- raison de reparler tout seuls.
    lastAnswer = 0
    self:SayHello()
end

function M:OnDisable()
    self:UnregisterAllEvents()
    self:UnregisterAllMessages()
    self:CancelAllTimers()
    Comm:Off("CD")
    Comm:Off("CDREQ")
    self:UnhookLib()
    self:ClearAll()
    self.known = {}
    self:ForgetMySpells()
    self:ForgetRoster()
    lastAnswer = 0
    if self.group then self.group:StopAll() end
end
