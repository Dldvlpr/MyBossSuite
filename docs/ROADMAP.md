# MyBossSuite — Fiche de route

Addon WoW unique, modulaire, modules activables/désactivables à chaud.
Cible : **toutes les versions du client, 1.x → 12.x** (Classic Era, TBC, Wrath, Cata, MoP Classic, retail).
But : remplacer DBM/BigWigs + OmniCD + WeakAuras perso + swing timer par un seul addon stable.

**Contrainte transversale** : aucune API appelée directement dans les modules si elle diffère entre flavors. Tout passe par `Core/Compat.lua`. C'est la règle qui rend le scope multi-version tenable.

---

## Phase 0 — Socle

### 0.1 Multi-TOC

Un seul `.toc` ne suffit pas : les clients classic cherchent un fichier suffixé.

- [ ] `MyBossSuite_Vanilla.toc`
- [ ] `MyBossSuite_TBC.toc`
- [ ] `MyBossSuite_Wrath.toc`
- [ ] `MyBossSuite_Cata.toc`
- [ ] `MyBossSuite_Mists.toc`
- [ ] `MyBossSuite_Mainline.toc` (retail)

Contenu identique sauf `## Interface:`. Un script `tools/gen-toc.sh` génère les 6 depuis un template pour éviter la divergence.

```
## Interface: 11507
## Title: MyBossSuite
## SavedVariables: MyBossSuiteDB
## SavedVariablesPerCharacter: MyBossSuiteCharDB
```

L'ordre de load dans le `.toc` est le seul mécanisme de dépendance qui existe : **Compat → Scheduler → EventBus → DB → Anchors → Config → ModuleLoader → Modules**.

### 0.2 `Core/Compat.lua` — couche d'abstraction API

Le fichier qui va le plus grossir. À écrire en premier, avant toute ligne de module.

Détection de flavor :

```lua
local MBS = MyBossSuite
MBS.flavor = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE and "retail")
          or (WOW_PROJECT_ID == WOW_PROJECT_CLASSIC and "vanilla")
          or (WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC and "tbc")
          or (WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC and "wrath")
          or (WOW_PROJECT_ID == WOW_PROJECT_CATACLYSM_CLASSIC and "cata")
          or (WOW_PROJECT_ID == WOW_PROJECT_MISTS_CLASSIC and "mists")
          or "unknown"
MBS.isRetail = (MBS.flavor == "retail")
```

**Mais** : le flavor sert au branchement de *data*, pas au branchement d'*API*. Pour l'API, feature-detect — c'est la seule chose qui survivra à un patch classic qui backporte une fonction.

```lua
-- Spell API : C_Spell.* introduit en 11.0 retail, backporté partiellement en classic
MBS.GetSpellCooldown = (C_Spell and C_Spell.GetSpellCooldown)
    and function(id)
        local info = C_Spell.GetSpellCooldown(id)
        if not info then return 0, 0, false end
        return info.startTime, info.duration, info.isEnabled
    end
    or GetSpellCooldown

MBS.GetSpellInfo = (C_Spell and C_Spell.GetSpellInfo)
    and function(id)
        local info = C_Spell.GetSpellInfo(id)
        if not info then return nil end
        return info.name, nil, info.iconID, info.castTime
    end
    or GetSpellInfo

MBS.GetSpellTexture = (C_Spell and C_Spell.GetSpellTexture) or GetSpellTexture
```

Autres divergences à couvrir au fil des besoins — ne les écris pas d'avance, ajoute quand un module en a besoin :

| Besoin | Ancien | Nouveau |
|---|---|---|
| Auras | `UnitBuff` / `UnitDebuff` | `C_UnitAuras.GetAuraDataByIndex` |
| Addon comm | `SendAddonMessage` | `C_ChatInfo.SendAddonMessage` |
| Prefix register | `RegisterAddonMessagePrefix` | `C_ChatInfo.RegisterAddonMessagePrefix` |
| Combat log | `CombatLogGetCurrentEventInfo()` | idem partout (ok) |
| Nameplates | `C_NamePlate` | absent vanilla early |
| Encounter | `ENCOUNTER_START` | absent vanilla, présent Cata+ |

Table de capacités plutôt que des `if isRetail` disséminés :

```lua
MBS.has = {
    encounterEvents  = C_EncounterJournal ~= nil,
    specializations  = GetSpecialization ~= nil,
    unitHealthEvent  = true,
    lossOfControl    = C_LossOfControl ~= nil,
}
```

### 0.3 `Core/Scheduler.lua` — timers annulables

`C_Timer.After` **n'est pas annulable**. Un wipe laisse tourner tous les timers du pull précédent, qui explosent en plein milieu du suivant. Tout passe par un scheduler central avec handles nommés.

```lua
local Scheduler = {}
local active = {}

function Scheduler:Schedule(key, delay, fn)
    self:Cancel(key)
    active[key] = C_Timer.NewTimer(delay, function()
        active[key] = nil
        fn()
    end)
end

function Scheduler:Repeat(key, interval, fn)
    active[key] = C_Timer.NewTicker(interval, fn)
end

function Scheduler:Cancel(key)
    local t = active[key]
    if t then t:Cancel(); active[key] = nil end
end

function Scheduler:CancelPrefix(prefix)
    for k, t in pairs(active) do
        if k:sub(1, #prefix) == prefix then t:Cancel(); active[k] = nil end
    end
end

function Scheduler:CancelAll()
    for k, t in pairs(active) do t:Cancel(); active[k] = nil end
end
```

`CancelPrefix("BossTimer_")` sur wipe/kill = clear propre d'un seul module sans toucher aux autres.

> `C_Timer.NewTimer` n'existe pas sur les tout premiers builds Classic Era. Si tu supportes vraiment 1.x, prévois un fallback maison (table de tâches + `OnUpdate` avec accumulateur) dans Compat. Sinon, note-le comme limite assumée.

### 0.4 `Core/EventBus.lua`

Dispatch interne entre modules + une **frame unique** pour les events Blizzard, qui redistribue. Une seule frame `COMBAT_LOG_EVENT_UNFILTERED` pour tout l'addon, pas une par module.

```lua
function EventBus:Fire(event, ...)
    local list = self.listeners[event]
    if not list then return end
    for i = 1, #list do list[i](...) end
end
```

### 0.5 `Core/DB.lua` — SavedVariables, profils, migration

À prévoir **maintenant**, pas après. Rajouter des profils sur une DB à plat, c'est une migration pénible.

```lua
local DEFAULTS = {
    version = 1,
    profiles = {},
    profileKeys = {},   -- ["Nom-Royaume"] = "nom du profil"
}

local PROFILE_DEFAULTS = {
    modules = {
        bossTimer         = { enabled = true },
        swingTimer        = { enabled = true },
        cdTracker         = { enabled = true },
        interruptRotation = { enabled = false },
    },
    anchors = {},
    overrides = {},     -- surcharges par spellId
}
```

- [ ] Init sur `ADDON_LOADED` (nom de l'addon vérifié), **avant** que quoi que ce soit lise `MyBossSuiteDB.anchors` — sinon nil-error au premier lancement.
- [ ] `db.version` + chaîne de fonctions de migration `migrations[1] = function(db) ... end`.
- [ ] Export/import de profil en chaîne texte (serialize + compress + base64). Pas en v1, mais la structure doit le permettre.

### 0.6 `Core/ModuleLoader.lua` — activation à chaud

Le pattern d'origine ne toggle rien :

```lua
-- ❌ évalué une seule fois au chargement du fichier
if not MyBossSuite.modules.bossTimer.enabled then return end
```

Décocher la case en jeu ne fait rien tant qu'il n'y a pas de `/reload`. Le fichier de module ne fait que **déclarer**, le loader décide.

```lua
-- dans le module
local M = MBS:NewModule("bossTimer")

function M:OnEnable()
    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    self.frame:Show()
end

function M:OnDisable()
    self:UnregisterAllEvents()
    Scheduler:CancelPrefix("BossTimer_")
    self.frame:Hide()
end
```

```lua
-- dans le loader
function MBS:SetModuleEnabled(name, enabled)
    local m = self.modules[name]
    if enabled == m.isEnabled then return end
    m.isEnabled = enabled
    if enabled then m:OnEnable() else m:OnDisable() end
    MBS.db.modules[name].enabled = enabled
end
```

`OnDisable` doit être **complet** : events, timers, frames. Un module désactivé qui laisse une frame visible ou un ticker vivant, c'est le bug qu'on ne trouve jamais.

---

## Phase 0 bis — Anchors (positioning transversal)

Chaque élément affiché (bar boss timer, alerte spell précise, swing timer, rangée CD tracker, indicateur interrupt) déplaçable indépendamment et ancrable, comme le mode unlock de WeakAuras/DBM.

- [ ] `Core/Anchors.lua` — mixin réutilisable par tous les modules

```lua
local AnchorMixin = {}

function AnchorMixin:EnablePositioning()
    self:SetMovable(true)
    self:EnableMouse(true)
    self:SetClampedToScreen(true)
    self:RegisterForDrag("LeftButton")
    self:SetScript("OnDragStart", self.StartMoving)
    self:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        f:SaveAnchor()
    end)
end

function AnchorMixin:SaveAnchor()
    local point, relTo, relPoint, x, y = self:GetPoint()
    MBS.db.anchors[self.anchorKey] = {
        point    = point,
        relTo    = (relTo and relTo:GetName()) or "UIParent",
        relPoint = relPoint,
        x = x, y = y,
        scale = self:GetScale(),
    }
end

function AnchorMixin:LoadAnchor()
    local s = MBS.db.anchors[self.anchorKey]
    self:ClearAllPoints()
    if s then
        local parent = _G[s.relTo] or UIParent
        self:SetPoint(s.point, parent, s.relPoint, s.x, s.y)
        self:SetScale(s.scale or 1)
    else
        self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

function AnchorMixin:ResetAnchor()
    MBS.db.anchors[self.anchorKey] = nil
    self:LoadAnchor()
end
```

Corrections vs version initiale : `relativeTo` conservé (sinon la position sauvée est fausse dès qu'une frame est ancrée ailleurs qu'à `UIParent`), `scale` sauvegardé (sinon changement de résolution = tout décalé), `SetClampedToScreen` (sinon on perd une frame hors écran sans moyen de la récupérer).

### Granularité `anchorKey`

- `"BossTimer_GenericBar"` — bar générique par défaut
- `"BossTimer_Alert_<spellId>"` — override par alerte spell précise
- `"SwingTimer_Bar"`, `"CDTracker_Row"`, `"InterruptRotation_Indicator"`

Resolver explicite, un seul point de vérité :

```lua
function MBS:ResolveAnchorKey(spellId)
    local specific = "BossTimer_Alert_" .. spellId
    return MBS.db.anchors[specific] and specific or "BossTimer_GenericBar"
end
```

Override seulement les cas qui gênent — pas de config manuelle systématique.

### Mode unlock + mode test

- [ ] `/mbs unlock` : affiche toutes les frames actives avec bordure pointillée + label `anchorKey` pendant le drag, bouton "Reset position" par élément.
- [ ] `/mbs test` : **indispensable, pas optionnel.** Sans lui tu ne peux pas placer tes bars hors raid. Spawn une bar factice par `anchorKey` connu, avec durée fictive qui boucle. À faire en même temps que les anchors, pas plus tard.
- [ ] `/mbs test boss <npcId>` : rejoue toute la timeline d'un boss hors combat. Vaut aussi comme test de non-régression après édition d'un fichier de data.

---

## Phase 1 — Format data boss timer

- [ ] `Modules/BossTimer/Data/<Flavor>/<Raid>/<Boss>.lua`

**Clé = `npcId`, jamais le nom.** Le nom du boss est localisé (client FR/DE/RU) : indexer par `BossTimerData["Onyxia"]` casse dès qu'on sort d'un client EN. Le nom reste, mais en champ d'affichage uniquement.

```lua
BossTimerData[10184] = {
    name        = "Onyxia",   -- display only
    encounterId = 1084,       -- retail
    flavors     = { vanilla = true, retail = true },
    timers = {
        { trigger = "PULL",   time = 12, spellId = 17086, name = "Flame Breath",
          repeatInterval = 25, bar = true },
        { trigger = "CAST",   spellId = 18435, name = "Fireball Volley",
          warnBefore = 3, bar = true },
        { trigger = "HEALTH", threshold = 0.65, name = "Phase 2 - Deep Breath",
          once = true },
    },
}

BossTimerEncounter[1084] = 10184   -- alias retail → même entrée
```

Champs :
- `trigger` : `PULL` (offset depuis l'engage) / `CAST` (combat log) / `HEALTH` (seuil %vie)
- `repeatInterval` : optionnel, relance la bar après le premier trigger
- `once` : évite le retrigger (surtout pour `HEALTH`)
- `flavors` : sur quels clients l'entrée est valide

**Les timings diffèrent par version.** Onyxia en Classic Era ≠ Onyxia en retail. Soit un dossier de data par flavor, soit un champ `timers` surchargeable :

```lua
overrides = {
    retail = { [1] = { time = 10 } },   -- Flame Breath plus tôt en retail
}
```

Le dossier séparé est plus lisible et évite de charger de la data morte. Prends celui-là.

Pas de champ "phase" complexe imposé — ajoute seulement si un boss précis en a besoin.

---

## Phase 2 — Runtime engine boss timer

- [ ] `Modules/BossTimer/BossTimer.lua`

### Détection d'engage — les deux mécanismes en parallèle

`ENCOUNTER_START` existe en Cata Classic, MoP Classic et retail, pas seulement en retail. Le brancher sur `isRetail` te fait perdre le meilleur signal sur trois flavors. Enregistre-le partout où il existe, garde le combat log en second filet, et protège avec un flag `engaged` pour qu'ils ne déclenchent pas deux fois.

```lua
function M:OnEnable()
    if MBS.has.encounterEvents then
        self:RegisterEvent("ENCOUNTER_START")
        self:RegisterEvent("ENCOUNTER_END")
    end
    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")   -- fin de combat = wipe ou kill
end

function M:Engage(bossId)
    if self.engaged then return end
    self.engaged  = bossId
    self.pullTime = GetTime()
    self:StartPullTimers(BossTimerData[bossId])
end

function M:Disengage()
    self.engaged = nil
    Scheduler:CancelPrefix("BossTimer_")
    self:ClearBars()
end
```

`ENCOUNTER_START` → `BossTimerEncounter[encounterID]` → `Engage(npcId)`.
Combat log : premier événement avec un `sourceGUID` dont le npcId est connu → `Engage(npcId)`.

Extraction du npcId depuis un GUID (format `Creature-0-XXXX-XXXX-XXXX-<npcId>-XXXXXXXX`) :

```lua
local function NpcIdFromGUID(guid)
    if not guid then return nil end
    local id = guid:match("^Creature%-0%-%d+%-%d+%-%d+%-(%d+)%-")
    return id and tonumber(id)
end
```

### Boucle combat log — c'est le chemin chaud

Il n'existe **aucun filtrage côté API** : `COMBAT_LOG_EVENT_UNFILTERED` te livre tout, tu filtres en Lua. En raid 25 c'est plusieurs milliers d'appels par seconde, et c'est le seul endroit de l'addon où la perf compte vraiment.

Règles :
1. Early-return sur le `subevent` en premier (comparaison de string, la moins chère).
2. GUID ensuite.
3. **Zéro allocation de table** dans le handler. Pas de `{...}`, pas de closure créée par appel.
4. Locals hissés hors de la fonction.

```lua
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local function OnCombatLog()
    local _, sub, _, srcGUID, _, _, _, dstGUID, _, _, _, spellId = CombatLogGetCurrentEventInfo()
    if sub ~= "SPELL_CAST_START" and sub ~= "SPELL_CAST_SUCCESS" then return end
    if srcGUID ~= M.bossGUID then return end
    local t = M.castTriggers[spellId]
    if t then M:FireTimer(t) end
end
```

`castTriggers` est une lookup table `[spellId] = timerDef` construite **une fois** à l'engage, pas une boucle sur `timers` à chaque event.

### Suite du flux

1. `PULL` → `Scheduler:Schedule("BossTimer_pull_"..i, t.time, fn)`, `repeatInterval` → `Scheduler:Repeat`.
2. `CAST` → bar sur `MBS:ResolveAnchorKey(spellId)`.
3. `HEALTH` → sur `UNIT_HEALTH` filtré sur l'unité boss, flag `fired` si `once`. Note : `UNIT_HEALTH_FREQUENT` a disparu en retail, et `UNIT_HEALTH` n'est fiable que si le boss est dans un frame surveillé. Vérifie via `UnitGUID("boss1".."boss5")` en retail ; en classic, fallback sur `target`/`focus` uniquement — les seuils `HEALTH` sont **structurellement moins fiables en classic**, assume-le plutôt que de le maquiller.
4. Mort / wipe / `ENCOUNTER_END` / `PLAYER_REGEN_ENABLED` → `Disengage()`.

---

## Phase 2b — Rencontres : world boss, donjon, raid, phases

Ce que la Phase 2 laissait de côté et qui sépare un « boss timer » d'un boss
mod : la rencontre a une nature, un début, une fin qualifiée et des phases.

### Nature de la rencontre

- [x] `kind = "raid" | "dungeon" | "world"` dans la data, déduit de
      `GetInstanceInfo` à défaut (`ns.GetContentKind`).
- [x] Engage world boss : combat log dans les deux sens — un boss connu qui
      *encaisse* (`dstGUID`) engage aussi, parce que le combat a souvent commencé
      sans toi. `INSTANCE_ENCOUNTER_ENGAGE_UNIT` en plus là où il existe.
- [x] Rencontre à plusieurs boss (`npcIds`) : engage sur n'importe lequel, kill
      à la mort du dernier.
- [x] `difficulties` sur un timer ou une phase : filtré à l'engage sur
      `difficultyId`.

### Fin de combat

`PLAYER_REGEN_ENABLED` ne suffit pas : il se déclenche quand *tu* meurs.

- [x] kill : `UNIT_DIED` de tous les `npcIds`, ou `ENCOUNTER_END` succès.
- [x] wipe : ticker hors combat, plus personne du groupe en combat
      (`UnitAffectingCombat` sur `party`/`raid`) pendant un délai de grâce
      (3 s raid/donjon, 8 s world) ; `IsEncounterInProgress` prime là où il
      existe. Le ticker **continue** tant que le joueur est hors combat : un
      joueur mort dont le groupe wipe ensuite ne reçoit plus aucun event.
- [x] reset : world boss inactif (rien lancé, rien subi) pendant 45 s.
- [x] zone : `PLAYER_ENTERING_WORLD`, `ZONE_CHANGED_NEW_AREA` vers une autre
      instance.
- [x] résumé imprimé : kill/wipe/reset, durée, phase atteinte, vie du boss.

### Phases

- [x] `phases = { ... }` dans la data ; triggers `HEALTH`, `CAST`, `AURA`,
      `EMOTE`, `DEATH`, `PULL`, `PHASE`.
- [x] timers restreints (`phase` / `phases`), coupés au changement de phase ;
      timers `PHASE` relatifs à l'entrée dans la phase.
- [x] barre « Phase n » vers la phase suivante quand son échéance est connue.
- [x] annonce plein écran au changement de phase (`Core/Alerts`, clé `boss`).
- [x] cadre boss / phase / chrono du combat / chrono de phase / vie du boss,
      déplaçable, avec aperçu en mode test.
- [x] `/mbs boss phase <n>` pour forcer quand la détection a manqué.
- [x] `/mbs test boss` rejoue les phases (`testTime`).

### Annonces façon DBM

- [x] `announce` sur un timer : annonce à l'échéance, pré-annonce à
      `warnBefore`.
- [x] `countdown = n` : compte à rebours texte n…1.
- [x] `AURA` avec `on = "player"` : annonce « X SUR TOI » automatique ;
      `on = "any"` : nom de la cible en sous-titre.
- [x] rencontre sans data sur Cata+/retail : le cadre et le chrono s'affichent
      quand même ; montée en gamme vers la data si un boss connu se manifeste.

### Synchronisation entre joueurs (`Core/Comm.lua`)

- [x] couche de messages addon : préfixe `MBS`, canal automatique
      (`INSTANCE_CHAT` / `RAID` / `PARTY`), version de protocole, filtre d'écho.
- [x] `PULL` à l'engage (heure du pull, phase) ; un pair qui a vu le pull plus
      tôt fait reculer le nôtre et rapproche les timers `PULL` d'autant
      (`ShiftPull`), jamais l'inverse.
- [x] `PHASE` à chaque changement détecté localement ; appliqué si différent,
      refusé pour revenir en arrière sur un seuil de vie.
- [x] `END kill` : la mort du boss vue par un pair termine la rencontre chez
      ceux qui sont hors de portée du combat log. Le wipe n'est pas synchronisé :
      chacun le voit par le combat de son groupe.
- [x] `REQ` à l'arrivée dans un groupe, au login, au changement de zone : un
      pair engagé répond `PULL` avec l'état courant, après un délai aléatoire,
      et se tait si quelqu'un a déjà répondu.
- [x] engage par synchronisation : timers repetitifs recalés sur le bon cycle,
      phase et heure d'entrée de phase du pair.
- [x] `/mbs boss sync on|off`, compteurs envoyés / reçus dans `/mbs boss`.
- [x] le canal est réutilisable tel quel par le CD Tracker (Phase 5) — fait, il l'utilise sans y toucher (types `CD` et `CDREQ`).

### Non fait, et pourquoi

- [ ] **Voix pour le compte à rebours** : fichiers son à produire ou à
      licencier. Le compte à rebours est texte.
- [ ] **Data** : Onyxia, Kazzak et Herod sont des références de format ;
      la couverture réelle vient de `tools/wcl-ingest` (`--kind`, `--zone`) et
      demande `WCL_CLIENT_ID` / `WCL_CLIENT_SECRET`.

---

## Phase 3 — Acquisition de la data

Réordonné par rapport à la version initiale, pour deux raisons : le shim BigWigs ne marche pas, et WarcraftLogs est la seule source qui te donne de la data **par version de jeu**, ce dont tu as besoin de toute façon vu le scope.

### 3a. WarcraftLogs — source principale

- [ ] Client API : warcraftlogs.com/api/clients/ (OAuth, gratuit)
- [ ] API v2 = GraphQL. Scriptable, donc pas limité à de la vérification ponctuelle.
- [ ] `tools/wcl-ingest/` : pull de N logs par boss → deltas depuis le pull → **médiane** par spellId → génération du fichier `Data/<Flavor>/<Raid>/<Boss>.lua`.
- [x] **Fusion à la régénération** (fait) : seuls `repeatInterval`, `variable` et le `time` mesuré (timers `PULL`, et timers `PHASE` dont la borne a été située) sont réécrits. Le tableau `phases`, les timers `PHASE`/`CAST`/`AURA`, les libellés, `announce`, `flash` — tout ce qui s'écrit à la main — survit. Sans ça, éditer un fichier est jetable et un boss à phases n'est jamais régénérable : l'ingestion en masse s'arrête au premier boss non trivial. `--replace` écrase, un fichier illisible arrête le passage avant tout appel API.
- [x] **Proposition de phase** (fait) : le couple (écart-type du premier cast élevé, écart-type des intervalles serré) est la signature d'une capacité gated par une phase, pas d'une mécanique aléatoire. Elle ne ressort plus en `variable = true` — qui dirait le contraire de ce qu'on a mesuré — mais en `-- TODO phase ?` + `provisional`, avec les deux écarts-types en commentaire et, quand une phase concentre les observations, laquelle. Le générateur signale sans deviner : convertir en `PHASE` demande de savoir *quelle* phase, ce qu'un delta depuis le pull ne dit pas.
- [x] **Origine des timers `PHASE`** (fait) : `tools/wcl-ingest/wcl_phases.py` situe les bornes de phase dans le log, et les casts sont alors comptés depuis l'entrée dans leur phase. Un timer `PHASE` dont la borne a pu être située reçoit un `time` mesuré et perd son `provisional` ; sinon rien ne bouge et il reste écrit à la main.

  Deux sources, dans cet ordre. **La data du boss elle-même** d'abord : le tableau `phases` dit déjà comment la phase se déclenche, il suffit de rejouer ce déclencheur sur le log — `HEALTH` sur la courbe de vie (reconstruite depuis les dégâts subis par le boss, filtrés côté serveur par `filterExpression`), `CAST` sur les casts déjà rapatriés, `PULL`/`PHASE` sur leur délai. C'est la source qui fait foi, parce que c'est exactement ce que le module fera en jeu. **`phaseTransitions`** ensuite, en secours, et seulement si son découpage compte autant de phases que la data : un mauvais alignement mesurerait précisément la mauvaise phase. La requête est séparée de `FIGHT_QUERY` exprès — sa couverture hors retail n'est pas garantie, et une absence se dégrade en « phase non située » au lieu de faire tomber l'ingestion.

  Effet de bord qui vaut la peine : un sort présent dans deux phases voyait sa cadence polluée par le trou entre les deux (dernier cast de la P1 → premier de la P3), ce qui le faisait passer pour non déterministe. Un timer restreint à une phase prend maintenant la cadence de *sa* phase.

  Ce qui reste non situable : un déclencheur `EMOTE` (texte localisé, non rejouable hors du jeu) et un franchissement de seuil tombé dans un trou de la courbe — le boss immunisé ne prend rien, donc sa vie n'est plus échantillonnée. Dans les deux cas la borne est déclarée inconnue, et un cast coincé entre deux bornes dont une manque n'est attribué à aucune phase.
- [x] **`variable` = fenêtre, pas échéance** (fait) : un fort écart-type ne dit pas « ça tombe à cette seconde-là », il dit « à partir de là, ça peut tomber ». Le module ne programme donc plus d'annonce sur l'estimation d'un timer `variable` — barre grisée `~`, chrono `?` une fois l'estimation écoulée, pré-alerte et compte à rebours muets — et c'est le **cast observé** dans le combat log qui déclenche l'annonce. Corollaire côté moteur : tout `spellId` posé sur un timer `PULL`/`PHASE` s'affiche quand le boss lance le sort, y compris sans `repeatInterval` — un sort au moment imprévisible n'a que ce moment-là pour se faire voir — avec une fenêtre de silence de 5 s après une annonce d'estimation, pour ne pas dire deux fois le même événement. Passé 15 s d'attente sans cast, le cycle d'estimation repart.
- [x] **Génération des entrées de `phases`** (fait) : un fichier qui n'a aucun tableau `phases` en reçoit une proposition depuis `phaseTransitions`, chaque entrée marquée `provisional = true`. Le déclencheur proposé sort de la dissymétrie entre les logs — vie constante et heures différentes ⇒ `HEALTH` + seuil médian ; heure constante et vies différentes ⇒ `PULL` + délai médian — et les chiffres qui l'ont fait retenir sont affichés. Un tableau `phases` déjà présent n'est **jamais** remplacé : c'est la mécanique du combat, pas une mesure.

```graphql
query($code: String!, $fight: Int!) {
  reportData {
    report(code: $code) {
      events(dataType: Casts, hostilityType: Enemies, fightIDs: [$fight]) {
        data
      }
    }
  }
}
```

Pourquoi principale et pas "vérification terrain" :
- Un seul script couvre les 6 flavors — il suffit de filtrer par zone/partition.
- Les timings sont des **faits mesurés**, pas une œuvre dérivée. Aucun problème de licence.
- La médiane sur 10 logs est plus fiable qu'une valeur codée en dur dans un addon tiers, qui peut elle-même être approximative ou périmée.

Prévois quand même le cas des mécaniques non déterministes (certains casts sont sur cooldown interne + choix aléatoire) : si l'écart-type des deltas est élevé, marque le timer `variable = true` et affiche la bar différemment plutôt que de mentir sur une précision que tu n'as pas.

### 3b. WeakAuras perso

- [ ] Fichier : `WTF/Account/<COMPTE>/SavedVariables/WeakAuras.lua`
- [ ] Table `WeakAurasSaved.displays["<nom>"]`, champ `trigger.type` :
  - `"EVENT"` (`COMBAT_LOG_EVENT_UNFILTERED` + spellIds) → extraction directe vers le format Phase 1
  - `"BOSS_MOD"` → wrapper DBM/BigWigs, pas autonome, aucune valeur extractible

Compte avant de coder quoi que ce soit :

```bash
grep -o '"type": *"[A-Z_]*"' WeakAuras.lua | sort | uniq -c
```

Attente réaliste : la majorité des auras de raid importées depuis Wago sont `BOSS_MOD`. Cette source rapportera probablement peu — décide après le comptage, pas avant.

### 3c. Extraction depuis un boss mod — plan de secours seulement

L'approche shim + `dofile` **ne fonctionne pas sur BigWigs** : les modules modernes appellent `self:Bar(...)` à l'intérieur de handlers d'events, pas au top-level. Charger le fichier ne déclenche que le corps principal, tu récupères les `RegisterEvent` et aucune durée.

DBM est nettement plus shimmable : les timers y sont déclarés au chargement avec la durée en argument du constructeur (`self:NewCastTimer(12, 17086)`), donc capturables statiquement.

**Correction, relevé le 2026-09-08 dans les dépôts amont** : cette phase partait du principe que DBM et BigWigs étaient sous GPL, donc qu'accepter la GPL suffirait à en dériver de la data. C'est faux, et dans le mauvais sens.

| Projet | Licence réelle | Source |
|---|---|---|
| DBM | **All Rights Reserved**, `Copyright (c) 2021 Deadly Boss Mods` | `LICENSE` du dépôt |
| BigWigs | **All Rights Reserved** : « You are free to fork and modify on GitHub, please ask us about anything else » | `## X-License` de `BigWigs.toc` |

Aucun des deux n'accorde de droit de dériver hors de son propre dépôt. Passer MyBossSuite sous GPL **n'ouvre donc rien ici** : la contrainte n'est pas « ta licence est incompatible », elle est « tu n'as pas le droit ». La phase 3c est fermée, et elle l'aurait été quelle que soit la licence choisie.

La seule porte qui reste est explicitement nommée par BigWigs : *demander*. Une autorisation écrite des auteurs, pour un usage précis. Tant qu'elle n'existe pas, WCL est la source unique — ce qui ne change rien au plan réel, puisque 3a est de toute façon la seule source qui donne de la data **par version de jeu**.

Ordre par boss : **3a** → 3b si une aura `EVENT` existe déjà et couvre le cas → 3c uniquement avec une autorisation écrite.

---

## Phase 4 — Module Swing Timer

Le module à faire en premier après le core : zéro data externe, valide vite que l'archi tient en jeu.

- [ ] `Modules/SwingTimer/SwingTimer.lua`

```lua
local lastSwing, delta

local function OnCombatLog()
    local _, sub, _, srcGUID, _, _, _, _, _, _, _, _, _, missType = CombatLogGetCurrentEventInfo()
    if srcGUID ~= M.bossGUID then return end

    -- parry haste (classic) : le swing en cours est raccourci de 40%
    if sub == "SWING_MISSED" and missType == "PARRY" and M.barEnd then
        local remaining = M.barEnd - GetTime()
        M:ShortenBar(remaining * 0.6)
        return
    end

    if sub ~= "SWING_DAMAGE" and sub ~= "SWING_MISSED" then return end

    local now = GetTime()
    if lastSwing then delta = now - lastSwing end
    lastSwing = now
    if delta then M:StartBar(delta) end
end
```

Trois pièges, deux ajoutés par rapport à la version initiale :

1. **Premier swing = pas de delta.** Rien à afficher tant que deux swings n'ont pas été vus. Affiche une bar "calibration" plutôt que rien, sinon ça a l'air cassé.
2. **Parry haste (classic uniquement).** Un parry du tank ampute le swing en cours de 40%. Sans ça, ton delta glissant est faux après chaque parry — et en tank il y en a beaucoup. Il faut raccourcir la bar en cours, pas attendre le swing suivant.
3. **`SWING_DAMAGE_LANDED`** existe en retail et double-compte si tu ne l'exclus pas explicitement. Le filtre `sub == "SWING_DAMAGE"` strict le gère, un `find("SWING")` non.

`bossGUID` doit être alimenté : `UnitGUID("target")` sur `PLAYER_TARGET_CHANGED`, ou depuis l'engage du BossTimer via l'EventBus si le module est actif. À définir explicitement — c'était implicite et non initialisé dans la version précédente.

Delta recalculé à chaque swing, jamais stocké en dur : la vitesse d'attaque change (enrage, buffs, debuffs de slow). Zéro data statique, module autonome dès le jour 1 d'un patch.

---

## Phase 5 — Module CD Tracker

Principe : chaque client connaît **son propre** cooldown exact (`GetSpellCooldown` tient compte des talents, du haste et des procs pour soi-même). Chaque client broadcast sa vraie valeur au groupe via addon message, au lieu de deviner celle des autres.

- [x] `Modules/CDTracker/Libs/LibOpenRaid/` — embarquée (fait). **Licence : LGPL 2.1, pas « permissive »** comme annoncé ici. Sans conséquence pratique — un addon WoW est distribué en source, et on ne modifie pas une ligne de la lib — et sa section 3 autorise de prendre une copie sous GPL v2 « ou une version plus récente », donc aucun conflit avec la GPL v3 de l'addon. `LibStub` est embarquée avec (domaine public) : LibOpenRaid s'y déclare et ne l'embarque pas.
- [x] `Modules/CDTracker/CDTracker.lua` (fait)

```lua
local LibOpenRaid = LibStub("LibOpenRaid-1.0", true)
if LibOpenRaid then
    LibOpenRaid.RegisterCallback(addon, "CooldownUpdate", function(unit, spellId, timeLeft)
        M:UpdateDisplay(unit, spellId, timeLeft, "exact")
    end)
end
```

**Vérifié — et la réponse est non.** LibOpenRaid n'est pas « partielle » en classic, elle ne se charge pas du tout :

```lua
LIB_OPEN_RAID_CAN_LOAD = false
--don't load if it's not retail, emergencial patch due to classic and bcc stuff not transposed yet
if (WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE and not isExpansion_Dragonflight()) then
    return
end
```

Sur Classic Era, TBC, Wrath, Cata et MoP Classic, aucune bibliothèque n'est déclarée et `LibStub:GetLibrary("LibOpenRaid-1.0", true)` rend `nil`. Les fichiers `ThingsToMantain_Era/BurningCrusade/Wrath/Cata/Pandaria` existent — l'auteur prévoit le support — mais ne sont jamais atteints. Ça n'a pas demandé de test en groupe réel : c'est en tête du fichier.

**Ce que ça change** : sur cinq des six flavors visés, il n'y a rien à recevoir. Le fallback statique n'est pas le cas dégradé du module, il *est* le module en classic. Le broadcast entre joueurs de MyBossSuite reste possible via `Core/Comm.lua` (déjà écrit pour le Boss Timer) — c'est la seule façon d'avoir un CD exact en classic, et elle ne couvre que les joueurs qui font aussi tourner MyBossSuite.

Le `.toc` n'inscrit donc la lib que sur retail : l'inscrire ailleurs ne ferait que compiler 600 Ko de Lua pour rien.

- [x] **Diffusion entre porteurs de MyBossSuite** (fait) — la source principale, et celle qui rend le module possible en classic. Chaque client lit son propre cooldown (exact : talents, haste et procs compris) et l'annonce sur `Core/Comm.lua`. Aucune table de sorts par classe et par version à maintenir : chacun annonce la sienne. C'est ce qui évite le piège habituel du CD tracker classic, qui devine les cooldowns des autres et se trompe.
- [x] **Écouter `SPELL_CAST_SUCCESS`, pas `SPELL_INTERRUPT`** (fait) — un kick lancé dans le vide part quand même en cooldown sans générer d'`SPELL_INTERRUPT`. Le point est écrit en phase 6 ; il vaut déjà ici, puisque c'est ce module qui mesure.
- [x] **Quatre sources classées** (fait) : `self` > `mbs` > `lor` > `static`. Une source moins sûre n'écrase jamais une source plus sûre encore valide.
- [ ] Fallback : joueur non compatible → table statique `Data/<flavor>/Specs.lua`. Le format est écrit et le module le consomme déjà (source `static`, barre grisée) ; **aucun fichier n'est livré**, donc rien n'est affiché comme estimé aujourd'hui. Les CD de base diffèrent énormément entre vanilla et retail, et une estimation ne vaut d'être écrite que si elle est juste.

**Affichage différencié, non négociable** : un CD estimé s'affiche grisé/hachuré, jamais comme un CD exact. Un cooldown faux présenté comme vrai est pire qu'un joueur absent de la liste ; marqué "estimé", il reste utile au raid lead qui sait quoi en faire.

Limite honnête à documenter dans le README : précision réelle uniquement si la cible tourne un addon compatible. Blizzard bloque volontairement la lecture du CD exact d'un autre joueur sans son broadcast (API anti-cheat).

---

## Phase 6 — Module Interrupt Rotation

- [x] `Modules/InterruptRotation/InterruptRotation.lua` (fait)

1. ~~Réutilise le flux LibOpenRaid de la Phase 5, sous-ensemble `interrupt = true`.~~
   **Corrigé par la Phase 5 : le flux à réutiliser n'est pas celui de LibOpenRaid,
   qui ne se charge pas hors retail, mais celui du CD Tracker** — les cooldowns
   que chaque joueur annonce lui-même sur `Core/Comm.lua`. La rotation ne mesure
   donc rien : elle ordonne ce que le CD Tracker sait, et n'existe pas sans lui
   (`/mbs rotation` le dit plutôt que de faire semblant). Le sous-ensemble
   `interrupt` vient de `ns.InterruptSpells`, la liste par classe déjà curée par
   l'alerte kick.
2. [x] Round-robin sur les joueurs dont le kick est réellement disponible.
   **Un point à corriger dans la formulation d'origine : « dans l'ordre du
   groupe » n'existe pas.** `party1` n'est pas le même joueur pour toi et pour
   moi ; deux clients ordonneraient différemment et désigneraient chacun
   quelqu'un d'autre. L'ordre est donc le **tri par nom** des porteurs
   d'interrupt : déterministe, identique partout, et sans un seul message réseau
   de plus pour se mettre d'accord.
   Un joueur n'entre dans la file que s'il a annoncé son interrupt au moins une
   fois : « je ne sais pas » n'est pas « c'est prêt ». Le tour avance même quand
   ce n'est pas le désigné qui a kické — la rotation suit ce qui s'est passé, elle
   ne le corrige pas.
3. [x] **`SPELL_CAST_SUCCESS` sur les spellId d'interrupt, jamais `SPELL_INTERRUPT`.**
   Un kick lancé dans le vide part quand même en cooldown sans générer aucun
   `SPELL_INTERRUPT` ; écouter le mauvais événement désignerait un joueur qui n'a
   plus son kick. C'est testé dans les deux sens : un `SPELL_CAST_SUCCESS`
   d'interrupt fait tourner la file, un `SPELL_INTERRUPT` ne fait rien.
4. [x] Ce que la rotation change à l'alerte kick — **le vrai livrable du module**,
   et ce que la roadmap ne disait pas : une file passive n'aurait servi à rien.
   Quand le tour est à un autre, l'alerte affiche « ATTENDS » en gris, sans son
   ni flash, et nomme celui qui doit kicker. Elle ne disparaît jamais : au bout
   du délai de remise en jeu (1,2 s, `/mbs rotation delai`), elle redevient un
   `KICK` franc pour tout le monde. Le désigné peut être mort, silencé ou hors de
   portée, et **un kick manqué coûte plus cher qu'un kick en double**. Le
   couplage ne va que dans ce sens : sans le module de rotation, l'alerte kick
   est exactement celle d'avant.
5. [x] Cadre de file déplaçable (`/mbs unlock`, `/mbs test`), affiché en combat
   seulement. « En combat » se lit sur le **groupe**, pas sur
   `PLAYER_REGEN_ENABLED` : celui-ci tombe aussi quand tu meurs, et la file
   disparaîtrait au moment où elle sert le plus.
6. [ ] Override manuel de priorité : toujours pas en v1. À ajouter si le
   round-robin se révèle insuffisant à l'usage.

---

## Phase 7 — Alertes à l'écran (kick + move)

Deux modules qui partagent une même brique : `Core/Alerts.lua`, une alerte plein
écran (gros texte, sous-titre, icône, flash) doublée d'un son, entièrement
paramétrable et déplaçable comme n'importe quel autre élément.

- [x] `Core/Alerts.lua` — affichage + son + presets, un registre d'alertes que le
  panneau et `/mbs alert` parcourent génériquement.
- [x] `Modules/InterruptAlert/InterruptAlert.lua` — alerte **KICK**.
- [x] `Modules/MoveAlert/MoveAlert.lua` — alerte **MOVE** (façon GTFO).

### 7.1 Alerte kick

Trois conditions vérifiées **ensemble et en continu** pendant l'incantation :

1. la cible (ou le focus) incante ;
2. l'incantation n'est pas protégée (`notInterruptible`) ;
3. **ton** interrupt est réellement disponible, et la cible à portée.

Le point qui décide de la crédibilité du module : un ticker de 0,15 s tourne
pendant l'incantation, parce qu'un kick qui revient de cooldown au milieu du cast
n'est signalé par aucun événement. Sans lui, l'alerte n'apparaît jamais dans le
cas qui compte le plus.

Détection de l'interrupt : table par classe, filtrée par ce que le joueur connaît
vraiment. `IsSpellKnown` teste un id exact, ce qui ne suffit pas en classic où
chaque rang a son id — d'où le repli par nom dans `ns.KnowsSpell`. Override
manuel via `/mbs kick spell <id>` pour les cas non couverts (interrupt de
familier notamment).

Repli combat log : sur les clients les plus anciens, `UnitCastingInfo` ne répond
rien sur une unité hostile. `SPELL_CAST_START` prend alors le relais, filtré sur
le GUID de la cible et du focus pour ne rien coûter en raid.

### 7.2 Alerte move (GTFO)

GTFO s'appuie sur une base de sorts maintenue à la main : non reprenable
(licence, et elle ne couvre pas les six flavors). La détection repose donc sur
une heuristique explicite plus une liste personnelle qui se remplit seule :

1. dégâts **périodiques** subis **sans debuff correspondant sur toi** → zone au
   sol. C'est le cœur : un DoT est une aura que tu portes, s'écarter n'y change
   rien ; une zone tape sans rien poser sur toi ;
2. dégâts d'environnement (feu, lave, slime) → zone ;
3. tout sort de ta liste personnelle → zone dès le premier tick, dégâts directs
   compris.

Les dégâts directs d'un sort inconnu n'alertent **jamais** : sans base de données
curée, la moindre attaque de boss ferait hurler l'addon. C'est la limite assumée
du module, et la raison de la liste personnelle (`/mbs move add|ignore`).

### 7.3 Data des deux alertes — `tools/wcl-ingest/wcl_alerts.py`

- [x] `tools/wcl-ingest/wcl_api.py` — transport WCL extrait, partagé avec `wcl_ingest.py`
- [x] `tools/wcl-ingest/wcl_alerts.py` — les deux listes en un passage
- [x] `tests/test_wcl_alerts.py` — classement testé sur des logs synthétiques
- [ ] data réellement générée (demande `WCL_CLIENT_ID` / `WCL_CLIENT_SECRET`)

Même source que les timings, donc même argument de licence : des faits mesurés
dans des logs publics, par version de jeu. Reprendre la base de GTFO ferait de
l'addon une œuvre dérivée, exactement comme une extraction depuis DBM — et elle
ne couvre pas les six flavors.

**Deux natures de preuve, à ne pas confondre.**

`Interrupts` : un sort qui apparaît en `extraAbilityGameID` d'un événement
`interrupt` *a été* interrompu dans cette version du jeu. Une occurrence suffit,
aucun seuil statistique n'a de sens. La liste ne sert qu'au repli combat log :
quand `UnitCastingInfo` répond, elle fait foi et la data n'est même pas lue.

`DamageTaken` + `Debuffs` : rien dans un log ne dit « ce sort était évitable ».
C'est une déduction, donc les critères sont explicites, réglables, et chaque
entrée générée porte en commentaire les chiffres qui l'ont fait retenir :

1. plusieurs joueurs différents touchés ;
2. pas de debuff du même sort sur eux au moment du coup (sinon : DoT) ;
3. pas tout le raid à chaque pull (sinon : dégât inévitable) ;
4. périodique, **ou** touchant des joueurs différents d'un pull à l'autre.

Le critère 4 est celui qui apporte quelque chose que l'heuristique live ne peut
pas avoir : sur un seul tick, un swirl et un cleave sont indiscernables ; sur
cinquante pulls, le cleave touche toujours les mêmes corps à corps et le swirl
touche ceux qui n'en sont pas sortis. C'est aussi ce qui permet enfin de couvrir
la zone qui **ne tape qu'une fois**, angle mort structurel du module live.

Avec un seul log, ce critère ne peut pas se prononcer et les sorts non
périodiques sont écartés : une liste courte et juste vaut mieux qu'une longue qui
alerte à tort.

---

## Ordre de build

1. **Compat + Scheduler + DB + EventBus + ModuleLoader** — rien ne peut être écrit proprement avant.
2. **Anchors + mode unlock + mode test** — tous les modules en dépendent pour être visibles et positionnables.
3. **Swing Timer** — zéro data externe, valide l'archi en jeu rapidement, et c'est déjà un module utile livrable seul.
4. **Boss Timer** — le plus gros morceau (Phases 1 à 3), engine puis ingestion WCL.
5. **CD Tracker** — après validation que LibOpenRaid tourne sur tes flavors.
6. **Interrupt Rotation** — réutilise la comm du CD Tracker, dernier car dépendant.
7. **Alertes kick et move** — indépendantes des phases 5 et 6 (aucune comm, aucune data externe), donc livrables sans attendre LibOpenRaid.

Livrable intermédiaire visé après l'étape 3 : un addon installable, configurable, avec un module fonctionnel. Ça vaut mieux que six modules à moitié faits.

---

## Checklist fichiers

```
MyBossSuite_Vanilla.toc / _TBC / _Wrath / _Cata / _Mists / _Mainline.toc
Core/
  Compat.lua
  Scheduler.lua
  EventBus.lua
  DB.lua
  Anchors.lua
  Bars.lua
  Alerts.lua
  Config.lua
  ModuleLoader.lua
Modules/
  SwingTimer/SwingTimer.lua
  InterruptAlert/InterruptAlert.lua
  MoveAlert/MoveAlert.lua
  BossTimer/
    BossTimer.lua
    Data/<flavor>/<Raid>/<Boss>.lua
  InterruptAlert/Data/<flavor>/<Raid>.lua
  MoveAlert/Data/<flavor>/<Raid>.lua
  CDTracker/
    CDTracker.lua
    Data/<flavor>/Specs.lua
    Libs/LibOpenRaid/
  InterruptRotation/InterruptRotation.lua
tools/
  gen-toc.sh
  wcl-ingest/            (source principale de data)
    wcl_api.py           (transport partage)
    wcl_ingest.py        (timings boss)
    wcl_alerts.py        (sorts kickables + zones a fuir)
  wa-extract/            (parsing WeakAuras perso)
README.md
```

---

## Questions à trancher

- **Vanilla 1.x : jusqu'où ?** `C_Timer.NewTimer` et `C_NamePlate` manquent sur les builds les plus anciens. Soit tu écris un scheduler `OnUpdate` maison dans Compat, soit tu poses un plancher (ex. Classic Era actuel plutôt que 1.12 littéral) et tu le documentes. Décider maintenant : ça conditionne la moitié de Compat.
- **Data par flavor : dossiers séparés ou table d'overrides ?** Dossiers = plus lisible et pas de data morte chargée, overrides = moins de duplication quand les timings sont identiques. Le choix impacte le générateur WCL, donc à trancher avant d'écrire `tools/wcl-ingest`.
- **WeakAuras : ratio `EVENT` vs `BOSS_MOD` ?** Le `grep` de la Phase 3b répond en 30 secondes et détermine si 3b vaut le code qu'il demande.
- ~~**BigWigs/DBM : acceptes-tu de passer l'addon sous GPL ?**~~ **Tranché, et la question était mal posée.** L'addon est sous **GPL v3** (`LICENSE` à la racine, `## X-License` dans les six `.toc`). Mais ça n'ouvre pas 3c : DBM et BigWigs sont *All Rights Reserved*, pas GPL — voir 3c. WCL est la source unique, ce qui rend l'ingestion critique.
- ~~**CD Tracker : LibOpenRaid tourne-t-elle sur tes flavors classic ?**~~ **Non — répondu par le code, sans test en jeu.** `LibOpenRaid.lua` sort en tête de fichier sur tout client non retail (`--don't load if it's not retail, emergencial patch due to classic and bcc stuff not transposed yet`). Sur les cinq flavors classic, `LIB_OPEN_RAID_CAN_LOAD` reste `false` et rien ne se déclare dans LibStub. Voir `Modules/CDTracker/Libs/README.md`.
