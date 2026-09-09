# MyBossSuite

Addon WoW unique et modulaire, modules activables/désactivables à chaud, ciblant
**toutes les versions du client** (Classic Era, TBC, Wrath, Cata, MoP Classic,
retail).

La fiche de route complète est dans [`docs/ROADMAP.md`](docs/ROADMAP.md).

## État

| Phase | Contenu | État |
|---|---|---|
| 0 | Multi-TOC, Compat, Scheduler, EventBus, DB, ModuleLoader | fait |
| 0 bis | Anchors, mode unlock, mode test | fait |
| 1 | Format de data boss timer | fait |
| 2 | Runtime engine boss timer | fait |
| 2b | Rencontres : world boss, donjon, raid ; phases, annonces, wipe/kill | fait |
| 2c | Synchronisation entre joueurs (pull, phases, kill) | fait |
| 3a | `tools/wcl-ingest` (WarcraftLogs), bornes de phase comprises | outil écrit, **data à générer** |
| 3b | `tools/wa-extract` (WeakAuras perso) | outil écrit |
| 3c | Extraction depuis DBM/BigWigs | **fermée** — les deux sont *All Rights Reserved*, pas GPL |
| 3d | `Modules/BossTimer/Bridge.lua` — pont runtime DBM/BigWigs | fait |
| 3e | `tools/bossmod-extract` — data extraite de DBM/BigWigs installés (**locale, non versionnée**) | fait |
| 4 | Module Swing Timer | fait |
| 5 | Module CD Tracker | fait, sur les 6 flavors — voir la note ci-dessous |
| 6 | Module Interrupt Rotation | fait — repose sur la phase 5 |
| 7 | `Core/Alerts.lua`, alerte Kick, alerte Move (GTFO) | fait |
| 7b | `tools/wcl-ingest/wcl_alerts.py` (data kick + move) | outil écrit, **data à générer** |

Livrable atteint : **un addon installable, configurable, avec six modules
fonctionnels** (Swing Timer, Boss Timer, CD Tracker, rotation d'interrupt,
alerte Kick, alerte Move). Ce qui manque encore ne tient plus au code, mais à la
**data** : voir « Limites assumées ».

Le CD Tracker ne s'appuie pas sur LibOpenRaid pour fonctionner, parce qu'elle ne
se charge pas hors retail. Il repose sur le fait que **chaque client connaît son
propre cooldown exactement** (`GetSpellCooldown` tient compte des talents, du
haste et des procs — pour soi) et l'annonce au groupe via `Core/Comm.lua`. C'est
exact sur les six versions du jeu, entre porteurs de MyBossSuite. LibOpenRaid
s'ajoute par-dessus sur retail, pour couvrir les joueurs qui font tourner
Details! ou OmniCD sans MyBossSuite.

Le Boss Timer est un vrai moteur de rencontre, du niveau de ce qu'on attend
d'un DBM ou d'un BigWigs : raid, donjon et world boss, phases visibles avec
chrono, annonces plein écran et compte à rebours, distinction kill / wipe /
reset, un cadre boss / phase / vie, et une synchronisation entre joueurs du
groupe (heure du pull, phases, kill). Ce qui lui manque encore par rapport à
eux tient à la **data**, pas au moteur : voir « Limites assumées ».

En attendant que cette data soit générée, `Modules/BossTimer/Bridge.lua`
**reprend les barres de DBM et de BigWigs chez ceux qui les ont installés**. Ce
n'est pas une extraction : rien n'est copié dans le dépôt, rien n'est dérivé. Le
pont écoute les callbacks publics que les deux addons émettent en jeu — la même
surface que le trigger `BOSS_MOD` de WeakAuras utilise depuis des années — et
redessine leurs timers sur les ancres de MyBossSuite. C'est ce qui sépare le
pont de la phase 3c, fermée : écrire leurs timings dans
`Modules/BossTimer/Data/` ferait une œuvre dérivée de deux projets *All Rights
Reserved*, les lire chez le joueur non.

La règle de préséance n'est pas négociable : **la data de MyBossSuite gagne
toujours**. Le pont ne parle que là où on n'a rien, et une barre reprise porte
sa source dans son libellé (`DBM`, `BW`) — un chiffre de DBM n'est pas une
mesure de MyBossSuite. `/mbs boss pont off` le coupe.

Et pour ne pas dépendre d'un boss mod qui tourne, `tools/bossmod-extract` lit
les modules DBM et BigWigs **installés sur ta machine** et en génère un addon
compagnon que MyBossSuite charge comme data. Rien n'entre dans ce dépôt : la
sortie va à côté du client, l'outil refuse tout chemin situé dans le dépôt, et
le dossier est dans le `.gitignore`. Lire ces chiffres pour son propre usage
n'est pas les redistribuer sous GPL — voir `tools/bossmod-extract/README.md`.

Trois sources, donc, du plus sûr au moins sûr :

```
data du dépôt (mesurée)  >  data extraite localement  >  pont DBM/BigWigs live
```

## Installation

Copier le dossier dans `Interface/AddOns/MyBossSuite`. Les six `.toc` cohabitent :
chaque client charge celui qui correspond à son suffixe.

## Commandes

| Commande | Effet |
|---|---|
| `/mbs` | ouvre le panneau de configuration |
| `/mbs unlock` / `lock` | déplacer les éléments (glisser), molette = taille |
| `/mbs reset` | remet toutes les positions par défaut |
| `/mbs test` | barres factices en boucle sur chaque ancre |
| `/mbs test <anchorKey>` | idem, sur une seule ancre |
| `/mbs test boss <npcId>` | rejoue la timeline d'un boss hors combat, phases comprises |
| `/mbs anchor [<spellId>\|remove <spellId>]` | ancre dédiée pour les barres d'un sort (déplaçable via `/mbs unlock`) |
| `/mbs test stop` | arrête le mode test |
| `/mbs list` | état des modules |
| `/mbs enable\|disable\|toggle <module>` | activation à chaud |
| `/mbs profile [nom\|list\|copy <nom>\|reset]` | gestion des profils |
| `/mbs debug` | messages de debug |

### Boss Timer

| Commande | Effet |
|---|---|
| `/mbs boss` | rencontre en cours (nature, phase, chrono, vie), data chargée, réglages |
| `/mbs boss list [raid\|donjon\|world]` | rencontres connues sur ce client, par nature |
| `/mbs boss phase <n>` | force la phase (en combat ou en test) si la détection a manqué |
| `/mbs boss annonces\|compte\|phases\|cadre\|resume\|son\|sync on\|off` | annonces des timers, compte à rebours, annonce de phase, cadre boss/phase, résumé de fin de combat, son, synchronisation de groupe |
| `/mbs boss pont on\|off` | reprendre (ou non) les barres de DBM/BigWigs là où MyBossSuite n'a pas de data |
| `/mbs boss` (ligne d'état) | nombre de rencontres extraites localement, et celles que le dépôt couvre déjà |
| `/mbs alert boss ...` | texte, couleur, taille, son de l'annonce boss (voir ci-dessous) |

### CD Tracker

| Commande | Effet |
|---|---|
| `/mbs cd` | joueurs suivis, sources actives, état de LibOpenRaid |
| `/mbs cd list` | cooldowns connus, triés par temps restant, avec leur source |
| `/mbs cd sync` | annonce les tiens et demande les leurs |
| `/mbs cd barres\|annonce\|soi\|kick\|estimes on\|off` | barres à l'écran, diffusion de tes cooldowns, s'afficher soi-même, suivre les interrupts, afficher les estimations |

### Rotation d'interrupt

| Commande | Effet |
|---|---|
| `/mbs rotation` (ou `/mbs rot`) | porteurs connus, joueur désigné, dernier kick vu, réglages |
| `/mbs rotation list` | la file dans l'ordre du tour, avec l'attente de chacun |
| `/mbs rotation reset` | remet la file à son début (le tour repart du premier) |
| `/mbs rotation cadre on\|off` | affiche ou masque le cadre de file |
| `/mbs rotation combat on\|off` | n'afficher le cadre qu'en combat (par défaut oui) |
| `/mbs rotation retenue on\|off` | l'alerte kick dit « ATTENDS » quand le tour est à un autre |
| `/mbs rotation delai <s>` | délai avant de rendre la main à tout le monde (0 = jamais) |

### Alertes (kick, move et annonce boss)

| Commande | Effet |
|---|---|
| `/mbs alert` | liste les alertes et leurs réglages |
| `/mbs alert <kick\|move\|boss> test` | joue l'alerte telle quelle, son compris |
| `/mbs alert <clé> texte <texte>` | change le texte affiché (`KICK`, `MOVE`, ce que tu veux) |
| `/mbs alert <clé> couleur <r> <g> <b>` | couleur du texte et du flash (0 à 1) |
| `/mbs alert <clé> taille <n>` / `duree <n>` | taille de police, durée d'affichage |
| `/mbs alert <clé> visuel on\|off` / `flash on\|off` | affichage et flash plein écran |
| `/mbs alert <clé> son on\|off` | coupe ou remet le son |
| `/mbs alert <clé> son <preset\|id\|chemin>` | choisit le son et le joue aussitôt |
| `/mbs alert <clé> reset` | remet l'alerte par défaut |
| `/mbs kick [status]` | interrupt détecté, disponibilité, options |
| `/mbs kick spell <id>\|auto` | force le sort d'interruption suivi |
| `/mbs kick focus\|portee\|dispo on\|off` | conditions de déclenchement |
| `/mbs kick strict on\|off` | sur le repli combat log, n'annoncer que ce que la data prouve |
| `/mbs kick data` | sorts prouvés interruptibles par les logs |
| `/mbs move [status\|list]` | seuils, zones apprises, sorts ignorés |
| `/mbs move data` | zones livrées avec l'addon |
| `/mbs move add\|remove\|ignore\|unignore <spellId>` | édite la liste personnelle |
| `/mbs move seuil <pct>` / `apprentissage on\|off` | seuil en % des PV max, mémorisation auto |

Presets de son : `raidwarning`, `readycheck`, `alarm`, `ping`, `murloc`. Un id de
SOUNDKIT (`/mbs alert kick son 8959`) ou un chemin de fichier
(`/mbs alert move son Interface\AddOns\Perso\move.ogg`) font aussi l'affaire.
Les trois alertes se déplacent comme le reste : `/mbs unlock`, puis `/mbs test`
pour les faire apparaître hors combat — le cadre boss/phase aussi.

## Architecture

L'ordre de load du `.toc` est le seul mécanisme de dépendance qui existe :

```
Compat → Scheduler → EventBus → Comm → DB → Anchors → Bars → Alerts → Config → ModuleLoader → Modules → Data
```

* **`Core/Compat.lua`** — toute API divergente passe par ici, et **aucune ligne
  de module n'appelle une API dont la signature change entre flavors**. Le
  flavor sert au branchement de *data* ; l'*API* est feature-detectée, y compris
  l'existence des events (`pcall` sur `RegisterEvent`, seul test fiable, qui
  survit à un backport).
* **`Core/Scheduler.lua`** — tous les timers sont annulables et nommés.
  `C_Timer.After` n'est jamais appelé directement : un wipe laisserait tourner
  les timers du pull précédent. `CancelPrefix("BossTimer_")` nettoie un module
  sans toucher aux autres.
* **`Core/EventBus.lua`** — une frame unique pour tous les events Blizzard (une
  seule inscription à `COMBAT_LOG_EVENT_UNFILTERED` pour tout l'addon) plus un
  bus de messages internes entre modules. Chaque handler tourne sous `pcall`
  (une erreur dans un module ne prive pas les autres de l'event, et elle est
  remontée à l'error handler du client, au plus une fois par minute), et les
  listes de handlers sont remplacées plutôt que modifiées en place : un module
  qui se désinscrit pendant un dispatch ne fait jamais appeler `nil`.
* **`Modules/CDTracker/CDTracker.lua`** — cooldowns du groupe. Le principe qui
  le rend possible sur les six flavors : chaque client connaît **son** cooldown
  exactement, et l'annonce. Quatre sources classées par confiance (`self`, `mbs`,
  `lor`, `static`) ; une source moins sûre n'écrase jamais une source plus sûre
  encore valide, et une estimation s'affiche grisée et préfixée `~`. Le module
  écoute `SPELL_CAST_SUCCESS`, pas `SPELL_INTERRUPT` : un kick lancé dans le vide
  part quand même en cooldown mais ne génère aucun `SPELL_INTERRUPT`, et écouter
  le mauvais événement ferait croire le sort encore disponible.
* **`Modules/InterruptRotation/InterruptRotation.lua`** — à qui le tour, et
  surtout quand se taire. Le module ne mesure rien : il ordonne ce que le CD
  Tracker sait, et n'existe donc que là où celui-ci tourne. Deux règles le
  portent. **`SPELL_CAST_SUCCESS`, jamais `SPELL_INTERRUPT`** — un kick lancé
  dans le vide part quand même en cooldown sans générer d'`SPELL_INTERRUPT`, et
  écouter le mauvais événement désignerait un joueur qui n'a plus son kick.
  **« Je ne sais pas » n'est pas « c'est prêt »** — un joueur qui n'a jamais
  annoncé son interrupt n'entre pas dans la file, n'est jamais désigné, et ne
  fait donc jamais taire personne. L'ordre est le tri **par nom** des porteurs :
  `party1` n'est pas le même joueur pour toi et pour moi, alors que le tri par
  nom donne le même ordre sur tous les clients, sans un message réseau de plus.
  Quand le tour est à un autre, l'alerte kick affiche « ATTENDS » en gris, sans
  son — et redevient un `KICK` franc si l'incantation dure encore après le délai
  de remise en jeu (1,2 s par défaut) : un kick manqué coûte plus cher qu'un kick
  en double. Le module publie `INTERRUPT_ROTATION_ADVANCED` sur l'EventBus à
  chaque tour qui passe.
* **`Core/Comm.lua`** — messages addon entre joueurs du groupe. Préfixe `MBS`,
  canal choisi seul (`INSTANCE_CHAT`, `RAID`, `PARTY`), messages typés en
  champs séparés par des tabulations, version de protocole en tête : deux
  joueurs à des versions différentes s'ignorent au lieu de se corrompre. Les
  échos de ses propres messages sont filtrés ici, une fois pour tous.
* **`Core/DB.lua`** — profils par personnage et chaîne de migrations dès la v1.
  Initialisée sur `ADDON_LOADED` avant que quoi que ce soit lise `db.anchors`.
* **`Core/Anchors.lua`** — mixin de positionnement partagé. `relativeTo` et
  `scale` sont sauvegardés, `SetClampedToScreen` évite de perdre une frame hors
  écran.
* **`Core/Bars.lua`** — widget de barre + conteneur ancrable, factorisé entre
  modules (ajout par rapport à la checklist de la roadmap : le Swing Timer et le
  Boss Timer avaient sinon deux implémentations de barre à maintenir).
* **`Core/Alerts.lua`** — alerte plein écran (texte, sous-titre, icône, flash)
  plus son, paramétrable et déplaçable. Un registre d'alertes que le panneau et
  `/mbs alert` parcourent génériquement : ajouter une alerte à un futur module ne
  demande aucune ligne d'UI. Le son passe par `pcall` dans Compat — un SOUNDKIT
  absent d'un vieux client ou un fichier introuvable ne doit jamais empêcher le
  visuel de s'afficher.
* **`Core/ModuleLoader.lua`** — un fichier de module *déclare*, le loader
  *décide*. `OnDisable` coupe events, timers et frames ; le loader repasse
  derrière en filet de sécurité.
* **`Modules/BossTimer/BossTimer.lua`** — le moteur de rencontre. Engage par
  `ENCOUNTER_START`, unités `boss1..5` ou combat log (un boss connu qui agit
  **ou qui encaisse**, cas du world boss déjà engagé par d'autres). Tables de
  recherche construites une fois à l'engage (`castTriggers`, `auraTriggers`,
  `deathTriggers`…), zéro allocation dans le handler de combat log. Phases,
  timers restreints par phase et par difficulté, annonces, compte à rebours,
  cadre boss/phase/chrono/vie, et fin de combat qualifiée : kill, wipe, reset,
  changement de zone. Format complet dans `Modules/BossTimer/Data/README.md`.
* **`Modules/BossTimer/Bridge.lua`** — le pont vers les boss mods du joueur.
  Aucune data n'y est écrite ni extraite : il pose les callbacks publics de DBM
  (`DBM_TimerStart`, `DBM_TimerStop`, `DBM_TimerUpdate`, `DBM_TimerPause`,
  `DBM_SetStage`, `DBM_Pull`, `DBM_Kill`, `DBM_Wipe`) et les messages de
  BigWigs sur `BigWigsLoader` (`BigWigs_StartBar`, `BigWigs_StopBar`,
  `BigWigs_SetStage`, `BigWigs_OnBossEngage`…), et redessine leurs barres sur
  une ancre à part. Trois règles le tiennent. **La data maison gagne toujours** :
  dès qu'un `Engage` réel a lieu, les barres du pont s'effacent et il se tait —
  deux sources pour la même capacité, c'est une de trop. **Chaque argument reçu
  est validé** : une durée non numérique ou hors de `]0 s, 1 h]` est comptée en
  « refusée » et n'affiche rien, de sorte qu'un jour où l'amont réordonne ses
  arguments on voie un compteur monter plutôt que des barres fausses (`/mbs
  boss` l'affiche). **Chaque handler commence par le test de préséance**, ce qui
  rend le décrochage des callbacks facultatif : même laissés en place, ils ne
  font plus rien. Une barre BigWigs s'identifie par son **texte** et non par sa
  clé — `BigWigs_StartBar` donne les deux, `BigWigs_StopBar` ne donne que le
  texte. Et le pont peut ouvrir une rencontre *générique* sur un pull annoncé
  par le boss mod : sur vanilla, TBC et Wrath, où `ENCOUNTER_START` n'existe
  pas, c'est le seul chronomètre possible sur un boss dont on n'a pas la data —
  le moteur maison reprend la main dès qu'un npcId connu agit, sans perdre
  l'heure du pull.
* **`Modules/BossTimer/Extracted.lua`** — le point de contact avec la data
  extraite par `tools/bossmod-extract`. Le générateur n'écrit rien dans ce
  dépôt : il produit un addon compagnon à côté du client, qui dépose sa data
  dans une table globale. Passer par un global plutôt que par le namespace de
  MyBossSuite est ce qui permet aux deux addons de se charger dans n'importe
  quel ordre, et à celui-ci de rester absent sans qu'aucun test particulier soit
  nécessaire. Ce fichier ne verse dans `ns.BossTimerData` que les rencontres
  pour lesquelles le dépôt n'a rien — une entrée relue par quelqu'un passe
  toujours devant une entrée extraite, même provisoire — et il refuse **en bloc**
  un compagnon généré pour un autre flavor, plutôt que de charger à moitié : de
  la data Mists sur un client Cata donnerait des timings faux avec l'air d'être
  justes. `Unload` retire exactement ce qui avait été versé, pour qu'un
  changement de profil ne fige rien.

## Décisions prises

* **Plancher Vanilla : aucun.** `Compat` fournit un ordonnanceur maison sur
  `OnUpdate` quand `C_Timer` est absent, avec la même interface `:Cancel()`. Le
  Scheduler ne voit jamais la différence, et la suite de tests tourne dans les
  deux configurations.
* **Data : un dossier par flavor.** Plus lisible, et `tools/gen-toc.sh`
  n'inscrit dans chaque `.toc` que le dossier correspondant — aucune data morte
  n'est chargée sur un client qui ne s'en servira pas.
* **Parry haste : c'est l'unité qui *pare* dont le swing en cours est amputé**,
  de 40 % de sa durée d'attaque et sans jamais descendre sous 20 % du restant.
  (La roadmap branchait le raccourcissement sur le `sourceGUID` ; c'est le
  `destGUID` d'un `SWING_MISSED`/`PARRY` qui identifie l'unité concernée.)
* **Sortie de combat du joueur ≠ fin du combat.** `PLAYER_REGEN_ENABLED` tombe
  quand tu meurs, à un feign death, ou quand tu sors de combat alors que le raid
  continue : s'en servir pour couper les timers les fait disparaître au moment
  où ils comptent. Le boss timer ne se désengage que sur `ENCOUNTER_END`, la
  mort du boss, ou une fin de combat établie sur le groupe : tout le monde mort
  (wipe), ou plus personne en combat **et** le boss muet depuis 15 s (reset).
  En solo, sortir de combat reste la fin. Un `ENCOUNTER_START` sans GUID
  cherche le boss sur `boss1..5`, puis le combat log l'identifie
  (`BOSS_IDENTIFIED`), pour que le swing timer se verrouille dessus quand même.
* **Un cast observé prime sur une estimation.** Un `spellId` posé sur un timer
  `PULL` sert de resynchronisation : quand le boss lance réellement le sort, la
  prochaine occurrence est recalée dessus.
* **Alerte kick : trois conditions, vérifiées en continu.** Cible (ou focus) en
  incantation, incantation non protégée, **et** ton interrupt réellement
  disponible et à portée. Un ticker de 0,15 s tourne pendant l'incantation, parce
  qu'un kick qui revient de cooldown au milieu du cast n'est signalé par aucun
  événement — sans lui, l'alerte manque justement le cas qui compte.
* **Interrupt détecté, pas configuré.** Table par classe filtrée par ce que le
  personnage connaît vraiment. `IsSpellKnown` teste un id exact, insuffisant en
  classic où chaque rang a le sien : `ns.KnowsSpell` retombe sur le grimoire par
  nom, qui couvre tous les rangs. `/mbs kick spell <id>` force le cas non couvert.
* **Alerte move : heuristique explicite, pas de base de données.** Un tick
  *périodique* subi sans debuff correspondant sur toi = zone au sol (un DoT est
  une aura que tu portes, s'écarter n'y change rien). Les dégâts *directs* d'un
  sort inconnu n'alertent jamais : sans base curée, la moindre attaque de boss
  ferait hurler l'addon. Ce qui est détecté une fois est mémorisé dans le profil.
* **La data d'alerte vient des logs, jamais d'un autre addon.** Reprendre la base
  de GTFO ferait de cet addon une œuvre dérivée, exactement comme une extraction
  depuis DBM — et elle ne couvre pas les six flavors. Les timings, les kicks et
  les zones sortent tous de la même source : des faits mesurés dans des logs
  publics, par version de jeu.
* **Une liste de kicks ne peut pas contredire le client.** Quand
  `UnitCastingInfo` répond, elle fait foi et la data n'est pas consultée. La
  liste ne sert qu'au repli combat log — et ce qu'elle ne couvre pas s'affiche
  avec un `(?)`, plutôt que de laisser croire à une certitude qu'on n'a pas.
* **Une zone livrée alerte comme une zone apprise**, dès le premier coup et sans
  seuil : la preuve statistique a déjà été faite hors ligne, la refaire à chaque
  tick n'apporterait rien. Ton `/mbs move ignore` prime dans tous les cas.
* **Alerte = frame dédiée, la barre reste une barre.** `warnBefore` continue de
  faire passer une barre en rouge ; les alertes kick et move passent par
  `Core/Alerts.lua`, avec son et visuel réglables séparément.
* **Mourir ne termine pas une rencontre.** `PLAYER_REGEN_ENABLED` se déclenche
  quand *tu* sors de combat — donc quand tu meurs, alors que le groupe se bat
  encore. La fin de combat est décidée par le groupe : plus personne en combat
  pendant un délai de grâce (3 s en raid/donjon, 8 s sur un world boss), et
  `IsEncounterInProgress` là où le client sait répondre. Un joueur mort garde
  ses timers, et un wipe est annoncé comme un wipe, avec la phase et la vie du
  boss.
* **Un world boss se détecte au premier coup, dans un sens ou dans l'autre.**
  Pas d'`ENCOUNTER_START` en classic, pas d'unité `boss1`, et souvent le combat
  a commencé sans toi : un boss connu qui *se fait* taper engage la rencontre
  aussi sûrement qu'un boss qui tape. Un world boss qui ne fait plus rien et ne
  subit plus rien pendant 45 s a été reset : la rencontre se ferme d'elle-même.
* **Les phases sont de la data, pas du code.** Seuil de vie, sort, emote, aura,
  mort d'un add ou simple délai : chaque phase déclare son déclencheur, chaque
  timer déclare ses phases. Changer de phase coupe ce qui n'a plus lieu d'être
  et lance ce qui est relatif à l'entrée dans la phase. Rien n'est câblé en dur
  par boss dans le module.
* **Le groupe se synchronise sur ce que chacun voit, jamais sur un maître.**
  Qui engage annonce l'heure du pull ; qui détecte une phase l'annonce ; qui
  voit le boss mourir l'annonce. Chaque joueur adopte ce qui est *plus précis*
  que ce qu'il a : un pull plus ancien que le sien (jamais plus récent), une
  phase qu'il n'a pas encore vue (jamais un retour en arrière sur un seuil de
  vie). Ce qui a été appliqué depuis un message n'est jamais rediffusé : pas
  d'écho, pas de boucle. Un joueur qui arrive en cours de combat demande l'état
  (`REQ`), un seul pair répond. Sans groupe, rien n'est envoyé et rien ne
  manque : la synchronisation est un bonus, pas une dépendance.
* **Une rencontre sans data affiche quand même le chrono.** Sur Cata+/retail,
  `ENCOUNTER_START` ouvre le cadre boss/phase même sans fichier de data ; si un
  boss connu se manifeste ensuite, la rencontre monte en gamme sans perdre
  l'heure du pull.

## Limites assumées

* **Seuils `HEALTH` en classic** : il n'y a pas d'unité `boss1..5`. Le module
  sonde `target`, `focus`, `mouseover`, les nameplates et les cibles du groupe
  pendant l'engage — la détection est donc structurellement moins fiable qu'en
  Cata+/retail, pour les phases à seuil de vie comme pour les timers. C'est
  documenté plutôt que maquillé.
* **Synchronisation limitée au groupe.** Un world boss engagé par d'autres
  groupes ne partage rien avec eux : hors de ton raid, les timers `PULL`
  comptent depuis *ta* détection, et les timers resynchronisés sur un cast
  observé se recalent seuls. Dans ton groupe, l'heure du pull est celle du
  premier qui l'a vue.
* **Homonymes cross-realm** : le filtre d'écho compare le nom court de
  l'expéditeur au tien. Un homonyme d'un autre royaume dans ton groupe serait
  ignoré comme si c'était toi.
* **Emotes localisés** : un déclencheur `EMOTE` cherche un fragment de texte
  dans la langue du client. La data livrée ne garantit rien hors du client où
  elle a été écrite.
* **La data livrée (Onyxia, Kazzak, Herod) est provisoire** : elle sert de
  référence de format pour un raid, un world boss et un donjon. Elle doit être
  régénérée par `tools/wcl-ingest` avant tout usage sérieux. Ce qui sépare
  encore l'addon d'un DBM à jour, c'est la couverture en data — le moteur, lui,
  sait déjà tout jouer.
* **La data extraite a l'exactitude de sa source, pas la nôtre.** Ce sont les
  chiffres de DBM et de BigWigs, avec leur marge d'erreur et leur fraîcheur.
  Chaque entrée porte `provisional = true` et le nom de sa source, et une entrée
  du dépôt passe toujours devant. Elle ne rend donc pas la phase 3a inutile : la
  data mesurée reste ce qui rendra l'addon autonome.
* **Ce qui n'est pas littéral n'est pas extrait.** Une durée calculée à
  l'exécution (`self:IsHeroic() and 12 or 20`) ne produit aucun timer, et on ne
  retombe surtout pas sur la valeur déclarée : le module l'a explicitement
  remplacée. Sur Classic Era, 233 timers sont écartés à ce titre. Le compteur
  s'affiche à chaque passage. Un timer absent se remarque et se corrige, un
  timer faux se croit.
* **Les phases ne sortent que de BigWigs.** Chez lui, `SetStage(2)` est littéral
  et le fragment qui le déclenche est déclaré en clair. Chez DBM, le module
  appelle `SetStage(phase)` avec une variable : rien n'est lisible hors ligne, et
  aucune phase n'est écrite plutôt qu'une phase inventée. Un boss couvert par
  DBM seul sort donc avec ses timers et sans ses phases.
* **La data extraite vieillit avec ta copie de DBM.** Elle est figée au moment
  de la génération ; une mise à jour de DBM ne la met pas à jour toute seule. Et
  si ta copie ne couvre pas ton client, il n'y a rien à extraire : sur
  l'installation `_classic_` (Mists 5.5.4) mesurée ici, aucun pack DBM n'a de
  `.toc` Mists — l'outil s'arrête plutôt que de générer de la data Cata.
* **Le pont ne couvre que ceux qui ont déjà un boss mod.** Il emprunte, il ne
  remplace pas : un joueur sans DBM ni BigWigs ne voit rien de plus qu'avant. Il
  ne rend donc pas la phase 3a inutile — la data mesurée reste ce qui rendra
  MyBossSuite autonome, et elle reste prioritaire sur le pont partout où elle
  existe.
* **Une barre du pont a l'exactitude de sa source, pas la nôtre.** C'est le
  chiffre de DBM ou de BigWigs, affiché tel quel, avec leur marge d'erreur et
  leur fraîcheur. D'où le préfixe `DBM` / `BW` dans le libellé et l'ancre
  séparée : rien de ce que MyBossSuite n'a pas mesuré ne doit ressembler à une
  mesure de MyBossSuite.
* **Les positions d'arguments des callbacks tiers ne sont garanties par
  personne.** Si DBM ou BigWigs en réordonne un jour, la validation rejette
  l'événement : la barre n'apparaît pas et le compteur « refusées » de
  `/mbs boss` monte. C'est le compromis choisi — une barre absente se remarque
  et se corrige, une barre fausse se croit.
* **Le pont ne reprend que les barres, les stages et les pulls.** Ni les
  annonces plein écran, ni les sons, ni les *special warnings* : DBM les émet
  déjà lui-même chez le joueur, et les doubler serait du bruit, pas de
  l'information. Un stage repris n'est appliqué qu'à une rencontre *générique*,
  jamais par-dessus le tableau `phases` d'une data écrite à la main, et il n'est
  **jamais rediffusé au groupe** : chacun a son propre boss mod, et une phase
  qu'on n'a pas observée soi-même n'a rien à faire dans `Core/Comm.lua`.
* **Swing timer** : main-hand uniquement. Les coups de main gauche
  (`isOffHand`, 21e argument de `SWING_DAMAGE`, 13e de `SWING_MISSED`) sont
  reconnus et ignorés : ils ne relancent pas la barre, mais elle ne les affiche
  pas non plus.
* **Le CD Tracker ne voit que ceux qui parlent.** Blizzard bloque la lecture du
  cooldown exact d'un autre joueur sans son broadcast (API anti-triche). Un
  joueur qui ne fait tourner ni MyBossSuite ni (en retail) un addon à
  LibOpenRaid n'apparaît donc pas du tout — ce qui est la bonne réponse : il
  vaut mieux ne rien afficher que d'inventer. En **classic, LibOpenRaid ne se
  charge pas du tout** (`--don't load if it's not retail` en tête de son
  fichier), donc la couverture s'y limite aux porteurs de MyBossSuite.
* **Le CD Tracker ne suit que les interrupts pour l'instant.** La liste vient de
  `ns.InterruptSpells`, déjà curée et testée par le module d'alerte kick.
  `Modules/CDTracker/Data/<flavor>/Specs.lua` permet d'en déclarer d'autres par
  classe ; **aucun fichier n'est livré**, et c'est voulu : une estimation ne vaut
  d'être écrite que si elle est juste. Rien n'est donc affiché comme estimé
  aujourd'hui — tout ce que tu vois vient de son propriétaire.
* **La rotation d'interrupt ne voit que ceux qui parlent** — même limite que le
  CD Tracker, dont elle est la lecture ordonnée : un joueur qui ne fait tourner
  ni MyBossSuite ni (en retail) un addon à LibOpenRaid n'entre pas dans la file.
  C'est la bonne réponse : le désigner serait envoyer quelqu'un dont on ne sait
  rien. Elle ne connaît pas non plus la portée ni la ligne de vue du joueur
  désigné, et ne peut donc pas savoir qu'il est hors de portée du caster — c'est
  exactement ce que rattrape le délai de remise en jeu, qui rend la main à tout
  le monde si rien n'est parti. `/mbs rotation delai 0` supprime ce filet, et
  `/mbs rotation retenue off` supprime la retenue de l'alerte.
* **Ordre identique sur tous les clients, à une réserve près** : le tri par nom
  est déterministe, mais chaque client ne connaît que les porteurs qui *lui* ont
  parlé. Deux joueurs qui n'ont pas reçu les mêmes annonces peuvent brièvement
  voir deux files différentes, le temps qu'un `/mbs cd sync` (ou l'arrivée dans
  le groupe) remette tout le monde d'accord.
* **Homonymes dans le CD Tracker** : un nom reçu dans un message addon est
  recollé sur le joueur du roster, y compris quand l'un porte son royaume et pas
  l'autre. Deux homonymes de royaumes différents dans le même groupe ne sont pas
  séparables par le nom court : le module refuse alors de trancher (seule la
  correspondance exacte continue de marcher) plutôt que de les confondre.
* **Alerte kick sur les clients les plus anciens** : `UnitCastingInfo` ne répond
  rien sur une unité hostile. Le repli lit `SPELL_CAST_START` dans le combat log,
  qui ne dit pas si le sort est protégé — l'alerte assume alors *interruptible*
  et le signale par un `(?)`. `/mbs kick strict on` inverse le compromis : rien
  que du prouvé. Le repli ne voit pas les sorts sans temps d'incantation, qui ne
  sont de toute façon pas kickables. Et comme `SPELL_CAST_FAILED` n'est jamais
  loggé pour un PNJ, un cast annulé (stun, mort de la cible) n'y laisse aucune
  trace : là où le client voit la fin du cast (`UNIT_SPELLCAST_STOP`), l'entrée
  du repli est purgée aussitôt ; là où il ne la voit pas, elle expire en 6 s.
* **Aucune data d'alerte n'est livrée pour l'instant** : `wcl_alerts.py` est
  écrit et testé, mais la génération demande des identifiants WarcraftLogs
  (`WCL_CLIENT_ID` / `WCL_CLIENT_SECRET`). Tant qu'elle n'a pas tourné, les deux
  modules fonctionnent sur leur seule logique runtime — c'est le mode nominal en
  donjon, en monde ouvert et sur tout contenu jamais ingéré. Déclarer d'avance
  qu'un sort est kickable ou qu'une zone est évitable sans l'avoir mesuré serait
  un mensonge fonctionnel, pas un placeholder.
* **Interrupts de familier** (Spell Lock, Contre-sort du démoniste) : le cooldown
  d'un sort de familier n'est pas lisible comme celui du joueur. Ces classes
  n'auront d'alerte fiable qu'avec `/mbs kick dispo off`, qui retire la condition
  de disponibilité.
* **Alerte move : faux négatifs assumés.** Une zone qui ne tape qu'une fois, ou
  qui pose un debuff en même temps qu'elle tape, n'est pas détectée au premier
  contact — elle l'est ensuite via `/mbs move add <spellId>`. C'est le prix de
  l'absence de base de données curée ; l'inverse (alerter à tort sur chaque coup
  de boss) serait pire. Un coup entièrement absorbé par un bouclier arrive en
  `SPELL_ABSORBED`, qui ne dit pas s'il était périodique : seules les zones de
  ta liste ou de la data alertent sous bouclier, jamais l'heuristique.

## Outils

```bash
tools/gen-toc.sh            # régénère les 6 .toc (--check en CI)
tools/wcl-ingest/wcl_ingest.py --help    # timings boss (--kind raid|dungeon|world)
tools/wcl-ingest/wcl_alerts.py --help    # sorts kickables + zones à fuir
tools/wa-extract/wa_extract.py count WeakAuras.lua
tools/bossmod-extract/bossmod_extract.py --install <client>   # data DBM/BigWigs, locale
```

Le `WeakAuras.lua` est dans
`WTF/Account/<COMPTE>/SavedVariables/WeakAuras.lua`.

> **Rapports archivés.** WarcraftLogs archive les logs de plus de 2 ans, et
> l'endpoint applicatif ne les sert pas. `--user-auth` bascule sur l'endpoint
> `/user` : le script ouvre le navigateur une fois pour une autorisation OAuth,
> puis réutilise le jeton mis en cache dans `.wcl-token.json` (non versionné —
> il contient un *refresh token*). Cela demande **un compte abonné** (palier Or
> ou plus) et une redirect URL enregistrée valant exactement
> `http://localhost:4480/callback` (modifiable via `--auth-port`).
> L'autorisation demande les scopes `view-user-profile` et
> `view-private-reports` : sans le second, le jeton est valide mais le contenu
> des rapports reste refusé, sans erreur qui le dise. `--whoami` affiche le
> compte associé au jeton et sépare les deux causes possibles d'un refus
> (scopes manquants ou abonnement non pris en compte).
> Quand c'est possible, viser une partition récente avec `--partition` reste
> préférable : pas d'abonnement, et des timings mesurés sur le contenu tel
> qu'il tourne aujourd'hui.

* **`wcl-ingest`** — source principale de timings. OAuth client credentials
  (`WCL_CLIENT_ID` / `WCL_CLIENT_SECRET`, à mettre dans un `.env` à la racine du
  dépôt — copie `.env.example` ; le fichier est ignoré par git, et les variables
  d'environnement restent prioritaires), API GraphQL v2, médiane des deltas
  depuis le pull, écart-type élevé ⇒ `variable = true` (barre affichée comme
  incertaine plutôt que faussement précise). Les timings mesurés sont des faits,
  pas une œuvre dérivée : aucune contrainte de licence.
  Il **situe aussi les bornes de phase** dans le log, ce qui rend mesurable ce
  qui ne l'était pas : un timer `PHASE` compte depuis l'entrée dans sa phase, pas
  depuis le pull. Le déclencheur écrit dans `phases` est rejoué sur le log —
  seuil de vie sur la courbe de vie du boss (reconstruite depuis les dégâts qu'il
  encaisse), cast déclencheur, délai — et `phaseTransitions` sert de secours
  quand son découpage compte autant de phases que la data. Une borne non située
  (emote localisé, boss immunisé donc courbe trouée) laisse le `time` écrit à la
  main intact : le générateur préfère ne rien dire à dire un chiffre précis et
  faux. Effet de bord utile : un sort présent dans deux phases ne se fait plus
  marquer `variable` par le trou entre les deux.
  Quand la dispersion du premier cast est forte mais la cadence serrée, il écrit
  `-- TODO phase ?` + `provisional` plutôt que `variable` : c'est la signature
  d'un sort qui attend une phase, et le générateur signale sans deviner laquelle.
* **`wcl-alerts`** (`wcl_alerts.py`) — les deux listes des modules d'alerte, en
  un seul passage sur les mêmes logs. **Deux natures de preuve, pas une** : un
  sort qui apparaît en `extraAbilityGameID` d'un événement `interrupt` *a été*
  interrompu — une occurrence suffit, il n'y a rien à pondérer. Une zone à fuir,
  elle, ne se prouve pas : elle se déduit de critères explicites (plusieurs
  joueurs touchés, pas de debuff du même sort sur eux, pas tout le raid, et
  périodique **ou** touchant des joueurs différents d'un pull à l'autre). Chaque
  entrée générée porte en commentaire les chiffres qui l'ont fait retenir, pour
  qu'elle puisse être contestée ; `-v` affiche ce qui a été écarté et pourquoi.
* **`wa-extract`** — répond d'abord à la question qui décide de tout :
  `count` donne la répartition `EVENT` / `BOSS_MOD` de tes auras. Les
  `BOSS_MOD` sont des wrappers DBM/BigWigs sans durée propre, rien n'en sort
  *hors ligne* — c'est justement ce que `Modules/BossTimer/Bridge.lua` va
  chercher en jeu, à la source ; seules les `EVENT` sur combat log se
  convertissent en data (`extract --lua`).

## Tests

```bash
tests/run.sh        # syntaxe + suite headless (4 clients simulés) + ingestion + extraction + .toc
```

Prérequis : `lua5.1` (ou `lua`) et `python3` dans le `PATH`.

La suite charge le vrai code dans un mock d'API WoW et pilote le temps à la
main : elle vérifie le socle et les six modules sur client classic **et**
retail, avec et sans `C_Timer`. Le moteur de rencontre y est joué de bout en
bout sur un raid (Onyxia et ses trois phases), un donjon (difficulté, joueur
mort pendant que le groupe se bat, wipe) et un world boss (engage par un autre
joueur, conseil à deux boss, emote, aura sur toi, compte à rebours, reset par
inactivité), et la synchronisation est jouée avec un pair simulé (pull adopté,
phase reçue, kill reçu, arrivée en cours de combat, demande d'état, échos et
versions étrangères ignorés). Le pont boss mod a ses propres faux DBM et faux
BigWigs, chargés *après* l'addon comme en jeu : ce qui est vérifié là n'est pas
DBM, c'est que MyBossSuite lit correctement ce que DBM lui envoie, refuse ce qui
n'a pas la bonne forme, et se tait dès qu'une rencontre a de la data.
`tests/test_bossmod_extract.py` fait le pendant hors du jeu, sur des fixtures qui
reproduisent ce qui casse un lecteur de source naïf : un mot-clé de bloc dans un
commentaire, une virgule dans une chaîne au milieu d'une liste d'arguments,
`while ... do` et `for ... do` qui ne doivent compter qu'une fois, une durée
calculée à l'exécution qui ne doit produire aucun timer, et l'identité d'une
barre BigWigs — son texte, pas sa clé. Ça ne
remplace pas un test en jeu, mais ça
attrape les régressions de logique sans lancer WoW. Les cas qui ont déjà
cassé en sont : coup de main gauche sur le swing timer, mort du joueur au
milieu d'un pull, cast de PNJ annulé sans trace dans le combat log, forme
Classic Era de `UnitCastingInfo`, handler d'event en erreur, et un joueur vu
sous deux orthographes selon qu'il arrive par le roster ou par un message addon.

Le CD Tracker y est joué de bout en bout : lecture exacte de son propre
cooldown, GCD écarté, diffusion sur `SPELL_CAST_SUCCESS`, réception d'un pair,
hiérarchie des sources (une estimation ne parle pas par-dessus une mesure),
throttle des demandes d'état, oubli d'un joueur qui quitte le groupe, et lecture
défensive de LibOpenRaid — dont la doc se contredit sur l'ordre de ses retours,
donc une valeur incohérente est ignorée plutôt qu'affichée.

La rotation d'interrupt est jouée sur ce qui la rend juste ou dangereuse : un
joueur qui n'a rien annoncé n'entre pas dans la file, un `SPELL_INTERRUPT` ne
fait pas tourner le tour (seul un `SPELL_CAST_SUCCESS` le fait), un kick en
cooldown est sauté, personne de prêt veut dire « débrouillez-vous » et non
« attendez », l'alerte kick passe en « ATTENDS » puis redevient un `KICK` franc
quand le délai de remise en jeu est écoulé, et mourir en plein pull ne fait
disparaître ni la file ni le tour tant que le groupe se bat.

Les numéros `## Interface` des six `.toc` sont dans `tools/gen-toc.sh` ; ils
sont à bumper à chaque patch client, sinon l'addon apparaît comme obsolète.

`tests/test_wcl_phases.py` teste la **mesure des timers `PHASE`** : courbe de vie
reconstruite, seuil non daté quand la courbe a un trou, cast déclencheur cherché
après la borne précédente, cast coincé entre deux bornes dont une manque écarté
plutôt qu'attribué, et `phaseTransitions` refusé quand son découpage ne compte
pas comme la data. Ce qui est en jeu : une borne mal située produirait des
timings précis et faux, ce qui est pire que le `provisional` qu'elle remplace.

`tests/test_wa_extract.py` teste l'inventaire des WeakAuras sur une fixture qui
reproduit ce qui casse un parseur naïf : les deux schémas de trigger (`trigger`
et `triggers[n]`), des nombres négatifs et scientifiques, et du code utilisateur
stocké comme chaîne — accolades et guillemets échappés compris. C'est `count` qui
décide si la phase 3b vaut le code qu'elle demande : une réponse fausse à cette
question fait écrire, ou abandonner, une source de data pour rien.

`tests/test_wcl_alerts.py` teste séparément le **classement** de l'ingestion, sur
des logs synthétiques et sans réseau : une zone au sol doit être retenue, un DoT,
un dégât de raid, un cleave et un coup de tank doivent être écartés — chacun pour
la bonne raison. La liste des kicks est une preuve directe et n'a rien à
départager ; la liste des zones est une heuristique, et une heuristique non testée
est une heuristique fausse.

## Licence

MyBossSuite est sous **GPL v3 ou ultérieure** (`LICENSE` à la racine).

Deux bibliothèques sont embarquées sous `Modules/CDTracker/Libs/`, avec leur
licence d'origine et sans aucune modification : **LibStub** (domaine public) et
**LibOpenRaid-1.0** (LGPL 2.1). Voir `Modules/CDTracker/Libs/README.md` pour les
versions exactes et la procédure de mise à jour.

Ce choix **n'ouvre pas** l'extraction depuis DBM ou BigWigs : les deux sont
*All Rights Reserved*, pas GPL — la contrainte n'est pas une incompatibilité de
licence, c'est une absence de droit. Les timings de l'addon viennent de mesures
faites dans des logs publics (`tools/wcl-ingest`), qui sont des faits et non une
œuvre dérivée.

## Questions encore ouvertes

1. **WeakAuras : quel est ton ratio `EVENT` / `BOSS_MOD` ?**
   `tools/wa-extract/wa_extract.py count <ton WeakAuras.lua>` répond en 30
   secondes et décide si la phase 3b vaut le code qu'elle demande.
2. **CD Tracker : que fait-il en classic ?** LibOpenRaid ne s'y charge pas (garde
   amont retail), donc le fallback n'est pas le cas dégradé du module, il *est*
   le module sur cinq flavors sur six. Trois directions possibles : lib
   uniquement (retail seul), table statique par flavor (gros travail de data),
   ou broadcast entre porteurs de MyBossSuite via `Core/Comm.lua` — exact, mais
   seulement entre joueurs qui ont l'addon.
