# Sorts interruptibles

`Modules/InterruptAlert/Data/<flavor>/<Raid>.lua`

```lua
local _, ns = ...

ns.InterruptableData[17086] = true   -- Flame Breath — 12 interruption(s), 4 log(s)
```

## À quoi ça sert, et à quoi ça ne sert pas

**L'API du client fait foi.** `UnitCastingInfo` renvoie `notInterruptible` : c'est
l'information de Blizzard, exacte, à jour à chaque patch, et valable pour tous les
mobs — y compris ceux qu'aucune liste ne référencera jamais. Quand elle répond,
cette data n'est pas consultée du tout, et elle ne peut **jamais** la contredire.

Cette liste ne sert que dans un cas : les clients où `UnitCastingInfo` ne répond
rien sur une unité hostile. Le module lit alors `SPELL_CAST_START` dans le combat
log, qui ne dit pas si le sort est protégé. Par défaut il assume *interruptible*
(une alerte de trop se voit, un kick manqué non) et affiche un `(?)` derrière le
nom du sort. La data supprime le doute pour les sorts qu'elle couvre.

`/mbs kick strict on` bascule dans l'autre sens : sur ce repli, n'annoncer que ce
que la data prouve. Zéro faux positif, au prix des sorts non couverts.

## Génération

```bash
tools/wcl-ingest/wcl_alerts.py --mode interrupts --encounter <id> \
    --npc-id <npcId> --flavor vanilla --raid Onyxias_Lair
```

Chaque entrée est une **preuve** : le sort apparaît en `extraAbilityGameID` d'un
événement `interrupt` dans un log de cette version du jeu. Une seule occurrence
suffit — contrairement à la data `MoveAlert`, il n'y a rien de statistique ici.

Le fichier d'un raid s'enrichit boss par boss : les entrées existantes sont
conservées, sauf avec `--replace`.

Après génération, relancer `tools/gen-toc.sh` pour inscrire le fichier dans les
`.toc` — seul le dossier du flavor correspondant y est ajouté, aucune data morte
n'est chargée ailleurs.
