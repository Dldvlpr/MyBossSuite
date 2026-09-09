# bossmod-extract — timings de boss depuis DBM/BigWigs installés

```bash
tools/bossmod-extract/bossmod_extract.py --install "C:/World of Warcraft/_classic_era_"
```

Lit les modules de boss de **ton propre client**, en tire les timings, et écrit
un addon compagnon `Interface/AddOns/MyBossSuite_BossModData/` que MyBossSuite
charge au démarrage.

## Ce qui n'est jamais écrit dans le dépôt

La sortie va **à côté du client**, jamais dans `Modules/BossTimer/Data/`.
MyBossSuite est publié sous GPL sur un dépôt public ; DBM et BigWigs sont *All
Rights Reserved*. Lire leurs chiffres sur ta machine, pour ton usage, est une
chose ; les redistribuer dans un dépôt public en est une autre. `--out` refuse
tout chemin situé dans le dépôt, et `MyBossSuite_BossModData/` est dans le
`.gitignore` — deux verrous plutôt qu'une phrase dans un README.

C'est ce qui distingue cet outil de la phase 3c de la roadmap, fermée : elle
proposait de *versionner* de la data dérivée. Celui-ci ne versionne rien.

## Préséance

```
data du dépôt (mesurée)  >  data extraite (cet outil)  >  pont live (Bridge.lua)
```

Une entrée extraite ne remplace **jamais** une entrée du dépôt, même provisoire :
celle du dépôt a été relue par quelqu'un, celle-ci non. Chaque entrée générée
porte `provisional = true` et sa source. Ce sont les chiffres de DBM ou de
BigWigs — pas des mesures. `tools/wcl-ingest` reste ce qui produit de la data
mesurée.

## Comment ça lit

Pas de shim Lua, pas de `dofile`. Un shim n'attrape que ce qui s'exécute au
chargement : chez DBM ça donne les déclarations, mais les durées qui comptent
(`timer:Start(28.5)`) sont dans les gestionnaires d'événements ; chez BigWigs
*tout* est dans les gestionnaires. `lua_source.py` scanne donc la source — il
neutralise commentaires et chaînes dans un masque de même longueur, apparie les
blocs, découpe les appels — et les deux lecteurs posent leurs règles dessus.

**DBM** (`dbm_source.py`) — la déclaration donne le sort et la durée par défaut,
le gestionnaire donne le déclencheur :

```lua
local timerFlameBreathCD = mod:NewVarTimer("v9.7-35.6", 18435, ...)

function mod:OnCombatStart()
    timerFlameBreathCD:Start("v11.3-28.5")   -- → PULL, time = 11.3, variable
end

function mod:SPELL_CAST_START(args)
    if args:IsSpell(18435) then
        timerFlameBreathCD:Start()           -- → CAST 18435, repeatInterval = 9.7
    end
end
```

La chaîne `if / elseif` est démêlée : c'est la condition qui dit quel sort mène
à quel timer, le corps seul ne le dit pas.

**BigWigs** (`bw_source.py`) — une fonction par déclencheur, et une table qui dit
laquelle :

```lua
function mod:OnBossEnable()
    self:Log("SPELL_CAST_START", "FlameBreath", 18435)   -- la table
end
function mod:OnEngage()  self:CDBar(18435, 13, ...)  end -- → PULL, time = 13
function mod:FlameBreath(args)  self:CDBar(args.spellId, 12, ...)  end -- → cadence
```

BigWigs livre en plus les **phases**, que DBM ne donne pas hors ligne :
`self:SetStage(2)` est littéral, et le fragment qui le déclenche est déclaré en
clair (`L.stage2_yell_trigger = "from above"`) — exactement ce qu'attend un
trigger `EMOTE`.

Quand les deux addons couvrent le même boss, les lectures sont **fusionnées** :
BigWigs mène (il a les phases et un nom lisible), DBM comble et apporte ses
cadences variables. Un désaccord n'est pas arbitré en silence, il est écrit en
commentaire dans le fichier généré :

```lua
{   -- dbm dit time = 11.3
    trigger = "PULL", time = 13, spellId = 18435, ...
```

## Ce qui n'est pas extrait, et pourquoi

**Ce qui n'est pas littéral n'est pas extrait.** `timer:Start(self:IsHeroic() and
12 or 20)` ne produit aucun timer — et surtout, on ne retombe pas sur la durée
déclarée : le module l'a explicitement remplacée, y revenir donnerait un chiffre
plausible et faux. Le compteur de rejets est affiché à chaque passage. Un timer
absent se remarque et se corrige, un timer faux se croit.

Ne sortent pas non plus : les phases DBM (le module appelle `SetStage(phase)`
avec une variable), les annonces, les sons, les icônes de raid.

## Sélection des fichiers

C'est le `.toc` par flavor de chaque pack qui décide, pas un parcours de
dossiers. DBM installe les packs de **toutes** les extensions dans chaque
client : sur Classic Era, `DBM-Party-Shadowlands` est présent et ne se charge
jamais. Marcher récursivement verserait des centaines de rencontres mortes —
843 au lieu de 191, mesuré. Le `.toc` du flavor dit exactement ce qui vit sur ce
client.

Le flavor lui-même est lu dans `.build.info`, à la racine de l'installation,
jamais deviné depuis le nom du dossier : `_classic_` a été Vanilla, puis TBC,
Wrath, Cata, et vaut Mists aujourd'hui. Sans certitude, l'outil s'arrête et
demande `--flavor`.

## Options

| | |
|---|---|
| `--install <dir>` | racine d'un client, ex. `"C:/World of Warcraft/_classic_era_"` |
| `--flavor` | force le flavor (sinon lu dans `.build.info`) |
| `--zone <fragment>` | ne traiter que les zones dont le dossier contient ce fragment |
| `--out <dir>` | sortie ailleurs qu'à côté du client (refuse le dépôt) |
| `--dry-run` | affiche le bilan, n'écrit rien |
| `-v` | une ligne par rencontre : npcId, nom, nature, zone, compteurs, sources |

## En jeu

Activer « MyBossSuite — data boss mod » dans la liste des addons, puis :

```
/mbs boss           -- ligne « data boss mod extraite : N rencontre(s) »
/mbs boss list      -- les rencontres connues, par nature
/mbs test boss <npcId>  -- rejoue la timeline hors combat
```

Le compagnon déclare le flavor pour lequel il a été généré. Chargé sur un autre
client, il est **refusé en bloc** et le dit — de la data Mists sur un client
Cata donnerait des timings faux avec l'air d'être justes.

Régénérer après une mise à jour de DBM ou de BigWigs : le passage réécrit tout,
et supprime les fichiers devenus obsolètes.
