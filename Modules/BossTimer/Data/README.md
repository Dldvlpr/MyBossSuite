# Format des fichiers de data

`Modules/BossTimer/Data/<flavor>/<Zone>/<Boss>.lua`

Flavors : `vanilla`, `tbc`, `wrath`, `cata`, `mists`, `retail`.
Une zone est un raid, un donjon ou une zone de monde ouvert (world boss) :
le format est le même, seul `kind` change.

## Pourquoi un dossier par flavor et pas une table d'overrides

Les timings different par version : Onyxia en Classic Era n'est pas Onyxia en
retail. Un dossier par flavor est plus lisible, et surtout `tools/gen-toc.sh`
n'inscrit dans chaque `.toc` que le dossier du flavor correspondant — aucune
data morte n'est chargee en mémoire sur un client qui ne s'en servira jamais.
Le prix est un peu de duplication quand deux versions partagent un timing.

## Squelette

```lua
local _, ns = ...

ns.BossTimerData[<npcId>] = {
    name        = "<nom>",         -- affichage uniquement (le nom est localise)
    kind        = "raid",          -- "raid" | "dungeon" | "world" (defaut : deduit de l'instance)
    encounterId = <id>,            -- optionnel, pour ENCOUNTER_START (Cata+, retail)
    instanceId  = <id>,            -- optionnel, informatif (GetInstanceInfo)
    npcIds      = { <id>, ... },   -- optionnel, autres boss de la meme rencontre (conseil)
    flavors     = { vanilla = true },
    zone        = "<zone>",        -- affichage, /mbs boss list
    inactivity  = <s>,             -- optionnel, delai d'inactivite avant reset (world boss : 45)
    wipeGrace   = <s>,             -- optionnel, delai hors combat avant wipe (raid/donjon 3, world 8)
    phases      = { ... },         -- optionnel
    timers      = { ... },
}

ns.BossTimerEncounter[<encounterId>] = <npcId>
```

**La clé est le `npcId`, jamais le nom** : le nom est localisé côté client, une
table indexée par nom casse dès qu'on sort d'un client EN.

## Nature de la rencontre (`kind`)

| `kind` | Engage | Fin de combat |
|---|---|---|
| `raid` | `ENCOUNTER_START`, unités `boss1..5`, combat log | `ENCOUNTER_END`, mort du (des) boss, plus personne du groupe en combat pendant 3 s |
| `dungeon` | idem | idem |
| `world` | combat log, y compris quand **quelqu'un d'autre** tape le boss | mort, plus personne en combat pendant 8 s, ou boss inactif (rien lancé, rien subi) pendant 45 s = reset |

Sans `kind`, la nature est déduite de l'instance où se trouve le joueur au
moment de l'engage. Mourir ne termine jamais une rencontre : c'est le combat
du groupe (et `IsEncounterInProgress` là où il existe) qui décide.

## Phases

```lua
phases = {
    { name = "Sol" },                                                  -- phase 1 = engage
    { name = "Vol",   trigger = "HEALTH", threshold = 0.65, alert = "Phase 2" },
    { name = "Sol",   trigger = "HEALTH", threshold = 0.40 },
    { name = "Adds",  trigger = "EMOTE",  pattern = "rugit" },
    { name = "Enrage", trigger = "PHASE", time = 60 },                 -- 60 s apres la phase precedente
}
```

La phase 1 est celle de l'engage et ne porte pas de trigger. Les suivantes se
déclenchent par :

| `trigger` | Champs | Déclencheur |
|---|---|---|
| `HEALTH` | `threshold` | vie du boss ≤ seuil (une seule fois par seuil) |
| `CAST` | `spellId`, `castStart` | le boss lance le sort |
| `AURA` | `spellId`, `event` (`APPLIED`/`REMOVED`) | aura posée / retirée sur le boss |
| `EMOTE` | `pattern` (fragment, `lua = true` pour un motif Lua) | emote, cri ou chuchotement de boss contenant le fragment |
| `DEATH` | `npcId` | mort d'un add |
| `PULL` | `time` | délai depuis l'engage |
| `PHASE` | `time` | délai depuis l'entrée dans la phase précédente |

Champs communs : `name`, `alert` (texte annoncé, défaut `Phase n`), `color`,
`bar = false` (pas de barre vers cette phase), `warnBefore`, `difficulties`,
`testTime` (délai en mode test).

Quand la phase suivante a une échéance connue (`PULL` ou `PHASE`), une barre
« Phase n » compte à rebours vers elle. Les textes d'emote sont **localisés** :
`pattern` doit être un fragment qui existe dans la langue du client, jamais une
phrase complète.

À chaque changement de phase : annonce plein écran (son + texte), les timers
restreints à d'autres phases sont coupés, ceux de type `PHASE` de la nouvelle
phase démarrent, et le cadre boss/phase/chrono se met à jour.

## Champs d'un timer

| Champ | Obligatoire | Rôle |
|---|---|---|
| `trigger` | oui | `PULL`, `PHASE`, `CAST`, `HEALTH`, `AURA`, `EMOTE`, `DEATH` |
| `time` | `PULL`, `PHASE` | délai en secondes depuis le pull / l'entrée dans la phase |
| `phase` | `PHASE` | phase dont l'entrée démarre le timer (vaut aussi restriction) |
| `spellId` | `CAST`, `AURA` | déclencheur combat log ; sur un timer `PULL`/`PHASE`, sert de resynchro (la valeur observée prime sur l'estimée) |
| `threshold` | `HEALTH` | fraction de vie (0.65 = 65%) |
| `pattern` | `EMOTE` | fragment de texte d'emote |
| `npcId` | `DEATH` | add dont la mort déclenche le timer |
| `on` | non | `AURA` : `boss` (défaut), `player` (annonce « SUR TOI » automatique), `any` (le nom de la cible en sous-titre) |
| `event` | non | `AURA` : `APPLIED` (défaut) ou `REMOVED` |
| `phases` | non | `{ 1, 3 }` : le timer ne vit que dans ces phases |
| `difficulties` | non | `{ 1, 2 }` : ids de difficulté (`GetInstanceInfo`) où le timer s'applique |
| `name` | non | libellé affiché ; à défaut, le nom du sort est résolu via l'API |
| `repeatInterval` | non | relance la barre après le déclenchement |
| `once` | non | interdit le re-déclenchement |
| `warnBefore` | non | secondes avant impact où la barre passe en alerte (et pré-annonce si `announce`) |
| `announce` | non | `true` (libellé) ou texte : annonce plein écran à l'échéance |
| `countdown` | non | `n` : compte à rebours texte n…1 avant l'échéance |
| `flash` | non | flash plein écran avec l'annonce |
| `bar` | non | `false` pour un timer sans barre |
| `variable` | non | timing non déterministe : barre grisée et préfixée `~` |
| `castStart` | non | déclencher sur `SPELL_CAST_START` au lieu de `SPELL_CAST_SUCCESS` |
| `testTime` | non | délai utilisé par `/mbs test boss <npcId>` pour les triggers sans échéance connue |
| `color` | non | `{ r, g, b }` |

Un timer `PULL` restreint à des phases n'est programmé à l'engage que s'il est
actif en phase 1 ; pour un timer relatif à l'entrée dans une phase, utiliser
`PHASE`.

## Vérification

`/mbs test boss <npcId>` rejoue la timeline hors combat, phases comprises :
c'est aussi le test de non-régression après édition d'un fichier.
`/mbs boss list` liste ce qui est chargé, par nature. Le module valide la
structure au chargement et signale les timers et phases incomplets.
