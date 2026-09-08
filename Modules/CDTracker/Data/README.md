# Data du CD Tracker

`Modules/CDTracker/Data/<flavor>/Specs.lua`

**Aucun fichier n'est livre pour l'instant, et c'est voulu.** Le module marche
sans : chaque client annonce ses propres cooldowns, qui sont exacts. Cette data
ne sert qu'a une chose — estimer le cooldown d'un joueur qui n'annonce rien —
et une estimation ne vaut d'etre ecrite que si elle est juste.

## A quoi elle sert exactement

| Source | Ce que c'est | Precision |
|---|---|---|
| `self` | ton propre cooldown, lu par `GetSpellCooldown` | exacte |
| `mbs` | un pair qui fait tourner MyBossSuite et l'annonce | exacte |
| `lor` | LibOpenRaid (retail uniquement) | exacte |
| `static` | **cette data** : le cooldown de base du sort, sans talents ni haste | estimee |

Une entree `static` s'affiche grisee et prefixee « ~ ». Un cooldown estime
presente comme exact est pire qu'un joueur absent de la liste : le raid lead
qui sait que c'est une estimation en fait quelque chose, celui qui croit a un
chiffre faux appelle un kick qui ne viendra pas.

Une source moins sure n'ecrase jamais une source plus sure encore valide.

## Format

```lua
local _, ns = ...

ns.CDTrackerData["ROGUE"] = {
    { spellId = 1766, kind = "interrupt" },   -- Kick
    { spellId = 2094, kind = "utility"   },   -- Blind
}
```

| Champ | Role |
|---|---|
| `spellId` | id du sort. Un id inconnu du client est ignore sans bruit : `ns.KnowsSpell` filtre, y compris les rangs classic (repli par nom) |
| `kind` | `interrupt`, `defensive`, `offensive`, `utility` — decide la couleur de la barre, et le filtre de la rotation d'interrupt (phase 6) |

La cle est le **jeton de classe** (`ROGUE`, `WARRIOR`...), jamais le nom
localise.

Les interrupts n'ont pas a etre listes ici : ils viennent de
`ns.InterruptSpells`, la table deja curee et testee du module d'alerte kick.

## Pourquoi un dossier par flavor

Les cooldowns de base different enormement d'une version a l'autre — Kick est a
10 s en Classic Era et a 15 s en retail, Contresort n'existe pas au meme rang.
`tools/gen-toc.sh` n'inscrit dans chaque `.toc` que le dossier du flavor
correspondant : aucune data morte n'est chargee sur un client qui ne s'en
servira jamais.

## Ce qu'il ne faut pas y mettre

Le cooldown *reduit par les talents ou le haste*. Cette table decrit le cas de
base, et c'est justement pourquoi elle est marquee estimee. Si tu connais la
valeur exacte pour un joueur, c'est que ce joueur peut l'annoncer lui-meme :
c'est la source `mbs`, et elle est meilleure.
