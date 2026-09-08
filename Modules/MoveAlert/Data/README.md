# Zones à fuir (alerte MOVE)

`Modules/MoveAlert/Data/<flavor>/<Raid>.lua`

```lua
local _, ns = ...

ns.MoveAlertData[22271] = true   -- Fire Patch — periodique, 11 joueur(s), 214 coup(s), spread 3.2, 5 log(s)
```

## Pourquoi une data, alors qu'il y a déjà une heuristique

L'heuristique live (tick périodique sans debuff correspondant sur toi) est
honnête mais aveugle sur un cas : la zone qui ne tape **qu'une fois**. Un coup
unique sans aura est, sur le moment, indiscernable d'une attaque de boss — le
module ne peut donc pas alerter dessus sans hurler à chaque pull.

Sur cinquante pulls, la différence est évidente : le swirl touche des joueurs
**différents** à chaque fois, le cleave touche toujours les mêmes corps à corps.
C'est ce que la data apporte, et c'est ce que l'heuristique ne peut pas voir.

Une entrée de cette liste alerte dès le premier coup, dégâts directs compris,
sans seuil ni vérification de debuff : la preuve statistique a déjà été faite.

## Ce n'est pas la base de GTFO

La base de GTFO est du code d'addon sous sa propre licence : la reprendre ferait
de cet addon une œuvre dérivée, exactement comme une extraction depuis DBM ou
BigWigs. Les entrées d'ici sont **mesurées dans des logs publics** — des faits,
sans contrainte de licence — et couvrent les six flavors, ce que GTFO ne fait
pas.

## Génération

```bash
tools/wcl-ingest/wcl_alerts.py --mode zones --encounter <id> \
    --npc-id <npcId> --flavor vanilla --raid Onyxias_Lair --limit 20
```

Un sort est retenu s'il a touché plusieurs joueurs différents, sans debuff du
même sort sur eux (sinon c'est un DoT), sans toucher tout le raid à chaque pull
(sinon c'est un dégât inévitable), et s'il est périodique **ou** touche des
joueurs différents d'un pull à l'autre.

Les seuils sont réglables (`--min-targets`, `--min-spread`, `--raid-wide`,
`--min-reports`) et `-v` affiche ce qui a été écarté et pourquoi : c'est par là
qu'il faut passer avant de baisser un seuil.

**Chaque entrée porte en commentaire les chiffres qui l'ont fait retenir.** C'est
une statistique, pas une preuve : elle doit pouvoir être contestée en lisant le
fichier. Un faux positif se corrige sans toucher à la data, avec
`/mbs move ignore <spellId>` — le choix est stocké dans ton profil et survit à
une régénération.

Après génération, relancer `tools/gen-toc.sh`.
