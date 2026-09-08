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
| 3a | `tools/wcl-ingest` (WarcraftLogs) | outil écrit, **data à générer** |
| 3b | `tools/wa-extract` (WeakAuras perso) | outil écrit |
| 3c | Extraction depuis DBM/BigWigs | non fait — décision de licence à trancher |
| 4 | Module Swing Timer | fait |
| 5 | Module CD Tracker | non fait — dépend d'un test LibOpenRaid en groupe réel |
| 6 | Module Interrupt Rotation | non fait — dépend de la phase 5 |
| 7 | `Core/Alerts.lua`, alerte Kick, alerte Move (GTFO) | fait |

Livrable atteint : **un addon installable, configurable, avec quatre modules
fonctionnels** (Swing Timer, Boss Timer, alerte Kick, alerte Move), plutôt que
six modules à moitié faits.

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
| `/mbs test boss <npcId>` | rejoue la timeline d'un boss hors combat |
| `/mbs test stop` | arrête le mode test |
| `/mbs list` | état des modules |
| `/mbs enable\|disable\|toggle <module>` | activation à chaud |
| `/mbs profile [nom\|list\|copy <nom>\|reset]` | gestion des profils |
| `/mbs debug` | messages de debug |

### Alertes (kick et move)

| Commande | Effet |
|---|---|
| `/mbs alert` | liste les alertes et leurs réglages |
| `/mbs alert <kick\|move> test` | joue l'alerte telle quelle, son compris |
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
| `/mbs move [status\|list]` | seuils et liste des zones connues |
| `/mbs move add\|remove\|ignore\|unignore <spellId>` | édite la liste personnelle |
| `/mbs move seuil <pct>` / `apprentissage on\|off` | seuil en % des PV max, mémorisation auto |

Presets de son : `raidwarning`, `readycheck`, `alarm`, `ping`, `murloc`. Un id de
SOUNDKIT (`/mbs alert kick son 8959`) ou un chemin de fichier
(`/mbs alert move son Interface\AddOns\Perso\move.ogg`) font aussi l'affaire.
Les deux alertes se déplacent comme le reste : `/mbs unlock`, puis `/mbs test`
pour les faire apparaître hors combat.

## Architecture

L'ordre de load du `.toc` est le seul mécanisme de dépendance qui existe :

```
Compat → Scheduler → EventBus → DB → Anchors → Bars → Alerts → Config → ModuleLoader → Modules → Data
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
  bus de messages internes entre modules.
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
* **Alerte = frame dédiée, la barre reste une barre.** `warnBefore` continue de
  faire passer une barre en rouge ; les alertes kick et move passent par
  `Core/Alerts.lua`, avec son et visuel réglables séparément.

## Limites assumées

* **Seuils `HEALTH` en classic** : il n'y a pas d'unité `boss1..5`, seulement
  `target`/`focus`/`mouseover`. Le module sonde ces unités pendant l'engage —
  la détection est donc structurellement moins fiable qu'en Cata+/retail. C'est
  documenté plutôt que maquillé.
* **La data d'Onyxia livrée est provisoire** : elle sert de référence de format.
  Elle doit être régénérée par `tools/wcl-ingest` avant tout usage sérieux.
* **Swing timer** : main-hand uniquement. Le combat log ne distingue pas les
  coups de main gauche sur `SWING_DAMAGE`.
* **Précision du CD Tracker** (quand il existera) : Blizzard bloque la lecture
  du cooldown exact d'un autre joueur sans son broadcast. Sans addon compatible
  en face, ce sera de l'estimé — et un CD estimé devra s'afficher comme tel.
* **Alerte kick sur les clients les plus anciens** : `UnitCastingInfo` ne répond
  rien sur une unité hostile. Le repli lit `SPELL_CAST_START` dans le combat log,
  qui ne dit pas si le sort est protégé — l'alerte assume alors *interruptible*.
  Une alerte de trop se voit, un kick manqué non. Le repli ne voit pas non plus
  les sorts sans temps d'incantation, qui ne sont de toute façon pas kickables.
* **Interrupts de familier** (Spell Lock, Contre-sort du démoniste) : le cooldown
  d'un sort de familier n'est pas lisible comme celui du joueur. Ces classes
  n'auront d'alerte fiable qu'avec `/mbs kick dispo off`, qui retire la condition
  de disponibilité.
* **Alerte move : faux négatifs assumés.** Une zone qui ne tape qu'une fois, ou
  qui pose un debuff en même temps qu'elle tape, n'est pas détectée au premier
  contact — elle l'est ensuite via `/mbs move add <spellId>`. C'est le prix de
  l'absence de base de données curée ; l'inverse (alerter à tort sur chaque coup
  de boss) serait pire.

## Outils

```bash
tools/gen-toc.sh            # régénère les 6 .toc (--check en CI)
tools/wcl-ingest/wcl_ingest.py --help
tools/wa-extract/wa_extract.py count WeakAuras.lua
```

* **`wcl-ingest`** — source principale de timings. OAuth client credentials
  (`WCL_CLIENT_ID` / `WCL_CLIENT_SECRET`), API GraphQL v2, médiane des deltas
  depuis le pull, écart-type élevé ⇒ `variable = true` (barre affichée comme
  incertaine plutôt que faussement précise). Les timings mesurés sont des faits,
  pas une œuvre dérivée : aucune contrainte de licence.
* **`wa-extract`** — répond d'abord à la question qui décide de tout :
  `count` donne la répartition `EVENT` / `BOSS_MOD` de tes auras. Les
  `BOSS_MOD` sont des wrappers DBM/BigWigs sans durée propre, rien n'en sort ;
  seules les `EVENT` sur combat log se convertissent (`extract --lua`).

## Tests

```bash
tests/run.sh        # syntaxe + suite headless (4 clients simulés) + .toc à jour
```

La suite charge le vrai code dans un mock d'API WoW et pilote le temps à la
main : elle vérifie le socle et les quatre modules sur client classic **et**
retail, avec et sans `C_Timer`. Ça ne remplace pas un test en jeu, mais ça
attrape les régressions de logique sans lancer WoW.

## Questions encore ouvertes

1. **BigWigs/DBM : acceptes-tu de passer l'addon sous GPL ?** Tant que la
   réponse est non, la phase 3c reste hors table, WCL est la source unique — et
   aucun fichier de licence n'est posé dans le dépôt en attendant ta décision.
2. **WeakAuras : quel est ton ratio `EVENT` / `BOSS_MOD` ?**
   `tools/wa-extract/wa_extract.py count <ton WeakAuras.lua>` répond en 30
   secondes et décide si la phase 3b vaut le code qu'elle demande.
3. **LibOpenRaid tourne-t-elle sur tes flavors classic ?** À tester en groupe
   réel avant d'écrire la moindre ligne du CD Tracker : si la réponse est non,
   le module est en fallback statique 100 % du temps en classic, ce qui change
   sa valeur et peut-être la décision de le faire.
