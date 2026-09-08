# Bibliotheques embarquees

Ces dossiers ne sont **pas** du code MyBossSuite. Ils sont copies tels quels
depuis leur depot amont, licence comprise, et ne doivent pas etre edites : une
modification locale serait perdue a la prochaine mise a jour et rendrait le
diff amont illisible. Toute correction remonte chez l'auteur.

| Bibliotheque | Version embarquee | Licence | Amont |
|---|---|---|---|
| LibStub | minor 2 | domaine public | https://github.com/WoWUIDev/Ace3 (`LibStub/`), commit `88e0a1733fcfc8b8f09dd86ae71eee7a780c2980` |
| LibOpenRaid-1.0 | `CONST_LIB_VERSION` 177 | LGPL 2.1 | https://github.com/Tercioo/Open-Raid-Library, commit `8a6e6bdb2b6df4e628f24ff54b76d6d00239ea04` |

## LibOpenRaid : LGPL 2.1, pas une licence permissive

La fiche de route annoncait `embed (licence permissive)`. C'est faux : le depot
porte le texte complet de la **LGPL 2.1**. En pratique ca ne gene pas un addon
WoW — la LGPL demande de distribuer la source de la bibliotheque et de signaler
les modifications, or un addon *est* distribue en source et on n'en modifie
aucune ligne. Son `LICENSE` est conserve dans le dossier, ce qui est exactement
ce que la licence demande. Sa section 3 permet en plus de prendre une copie sous
GPL v2 « ou une version plus recente si vous le souhaitez » : il n'y a donc
aucun conflit avec la GPL v3 du reste de l'addon. On garde la bibliotheque sous
sa propre licence plutot que de la convertir — c'est plus honnete et ca ne coute
rien.

## LibOpenRaid ne se charge PAS hors retail

`LibOpenRaid.lua` sort en tete de fichier :

```lua
LIB_OPEN_RAID_CAN_LOAD = false
--don't load if it's not retail, emergencial patch due to classic and bcc stuff not transposed yet
if (WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE and not isExpansion_Dragonflight()) then
    return
end
```

Sur Classic Era, TBC, Wrath, Cata et MoP Classic, `LIB_OPEN_RAID_CAN_LOAD` reste
`false`, aucune bibliotheque n'est declaree dans LibStub, et
`LibStub:GetLibrary("LibOpenRaid-1.0", true)` rend `nil`. Les fichiers
`ThingsToMantain_Era/BurningCrusade/Wrath/Cata/Pandaria` existent bien — l'auteur
prevoit le support classic — mais ils ne sont jamais atteints tant que cette
garde est la.

Consequence pour le CD Tracker : sur cinq des six flavors vises, il n'y a **rien**
a recevoir de la bibliotheque. Tout CD d'un autre joueur y sera estime, donc a
afficher comme estime. C'est la reponse a la question ouverte « LibOpenRaid
tourne-t-elle sur tes flavors classic ? », et elle se lit dans le code : elle n'a
pas demande de test en groupe reel.

## Mise a jour

```bash
git clone --depth 1 https://github.com/Tercioo/Open-Raid-Library /tmp/lor
cp /tmp/lor/*.lua /tmp/lor/lib.xml /tmp/lor/docs.txt /tmp/lor/LICENSE \
   Modules/CDTracker/Libs/LibOpenRaid/
tools/gen-toc.sh
```

Verifier apres coup que `lib.xml` n'a pas gagne de fichier : `tools/gen-toc.sh`
inscrit la liste dans les `.toc` a la main, il ne lit pas le XML (les clients
classic ne chargent pas de `.xml` de la meme facon selon les versions, et un
ordre de load implicite est exactement le genre de dependance qui casse en
silence).
