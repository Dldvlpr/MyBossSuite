# Format des fichiers de data

`Modules/BossTimer/Data/<flavor>/<Raid>/<Boss>.lua`

Flavors : `vanilla`, `tbc`, `wrath`, `cata`, `mists`, `retail`.

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
    name        = "<nom>",       -- affichage uniquement (le nom est localise)
    encounterId = <id>,          -- optionnel, pour ENCOUNTER_START
    flavors     = { vanilla = true },
    timers      = { ... },
}

ns.BossTimerEncounter[<encounterId>] = <npcId>
```

**La clé est le `npcId`, jamais le nom** : le nom est localisé côté client, une
table indexée par nom casse dès qu'on sort d'un client EN.

## Champs d'un timer

| Champ | Obligatoire | Rôle |
|---|---|---|
| `trigger` | oui | `PULL` (offset depuis l'engage), `CAST` (combat log), `HEALTH` (seuil de vie) |
| `time` | `PULL` | délai en secondes depuis le pull |
| `spellId` | `CAST` | déclencheur combat log ; sur un timer `PULL`, sert de resynchro (la valeur observée prime sur l'estimée) |
| `threshold` | `HEALTH` | fraction de vie (0.65 = 65%) |
| `name` | non | libellé affiché ; à défaut, le nom du sort est résolu via l'API |
| `repeatInterval` | non | relance la barre après le déclenchement |
| `once` | non | interdit le re-déclenchement (surtout pour `HEALTH`) |
| `warnBefore` | non | secondes avant impact où la barre passe en alerte |
| `bar` | non | `false` pour un timer sans barre |
| `variable` | non | timing non déterministe : barre grisée et préfixée `~`, plutôt que de mentir sur une précision qu'on n'a pas |
| `castStart` | non | déclencher sur `SPELL_CAST_START` au lieu de `SPELL_CAST_SUCCESS` |
| `testTime` | non | délai utilisé par `/mbs test boss <npcId>` pour les triggers sans échéance connue |
| `color` | non | `{ r, g, b }` |

## Vérification

`/mbs test boss <npcId>` rejoue la timeline hors combat : c'est aussi le test de
non-régression après édition d'un fichier.
Le module valide la structure au chargement et signale les timers incomplets.
