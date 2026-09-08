#!/usr/bin/env python3
"""Situer les bornes de phase dans un log, pour mesurer les timers `PHASE`.

Le probleme que ce module resout : l'ingestion ne mesure qu'un delta depuis le
pull, alors qu'un timer `PHASE` compte depuis l'entree dans sa phase. Tant que
cette origine n'est pas situee dans le log, le `time` d'un timer `PHASE` reste
ecrit a la main et le timer reste `provisional` — c'est-a-dire que la moitie de
la data d'un boss a phases echappe a la mesure.

Deux sources, dans cet ordre :

1. **La data du boss elle-meme.** Le tableau `phases` dit deja comment la phase
   se declenche : `HEALTH` + seuil, `CAST` + spellId, `PULL`/`PHASE` + delai. Il
   suffit de rejouer ce declencheur sur le log. C'est la source qui fait foi,
   parce que c'est exactement ce que le module fera en jeu : si la borne mesuree
   ici differe de celle que verra le joueur, c'est la mesure qui est fausse.
2. **`phaseTransitions` de WarcraftLogs**, en secours et pour la proposition —
   utile quand le fichier n'a pas encore de `phases`, ou quand un declencheur
   n'est pas rejouable hors du jeu (`EMOTE`, dont le texte est localise).

Ce que ce module ne fait jamais : modifier un tableau `phases` existant. Il le
LIT pour situer les bornes ; il n'en propose un que lorsqu'il n'y en a aucun, et
chaque entree proposee sort marquee `provisional = true`.
"""

from __future__ import annotations

import statistics

# La courbe de vie est echantillonnee sur les degats subis par le boss : entre
# deux coups, on ne sait rien. Au-dela de cet ecart, on refuse d'interpoler et
# la borne est declaree non situee plutot que placee a la louche.
MAX_HEALTH_GAP = 8.0

# Un declencheur `CAST` peut se produire plusieurs fois dans le combat (le sort
# revient a chaque phase). On ne retient une borne que si le cast tombe apres la
# borne precedente : la premiere occurrence dans l'absolu designerait la P1.
MIN_PHASE_LENGTH = 1.0

# Proposition de phases (fichier sans `phases`) : au-dela de cette dispersion de
# la vie du boss entre les logs, la transition n'est pas pilotee par la vie.
HEALTH_SPREAD = 0.06

# Idem cote temps : au-dela, la transition n'est pas non plus a heure fixe, et
# on sort une proposition en `PULL` en le disant.
TIME_SPREAD = 6.0


# ----------------------------------------------------------------------------
# Courbe de vie
# ----------------------------------------------------------------------------

def health_curve(events, actors, npc_id: int, pull: float):
    """[(t depuis le pull, fraction de vie)] croissant, depuis les degats subis.

    Les evenements de degats portent la vie de la cible apres le coup : c'est le
    seul echantillonnage de la vie d'un boss qu'un log expose. Il est irregulier
    par nature — un boss immunise ne prend rien et sa courbe s'arrete — d'ou
    `MAX_HEALTH_GAP` cote lecture.
    """
    points = []
    for event in events:
        target = actors.get(event.get("targetID"))
        if target is None or (npc_id is not None and target.get("gameID") != npc_id):
            continue
        current, maximum = event.get("hitPoints"), event.get("maxHitPoints")
        if current is None or not maximum:
            continue
        points.append(((float(event["timestamp"]) - pull) / 1000.0,
                       max(0.0, min(1.0, float(current) / float(maximum)))))
    points.sort(key=lambda point: point[0])
    return points


def crossed_at(curve, threshold: float, after: float = 0.0):
    """Instant ou la vie passe sous `threshold`, ou None si le log ne le montre pas.

    Retourne le premier point sous le seuil, et seulement si le point precedent
    est assez proche dans le temps : sinon on sait que le boss est passe sous le
    seuil quelque part dans un trou de huit secondes, ce qui ne vaut pas une
    mesure a la seconde.
    """
    previous = None
    for time, fraction in curve:
        if time < after:
            previous = (time, fraction)
            continue
        if fraction <= threshold:
            if previous is not None and time - previous[0] > MAX_HEALTH_GAP:
                return None
            return round(time, 2)
        previous = (time, fraction)
    return None


def health_at(curve, time: float):
    """Fraction de vie a l'instant `time`, sans interpoler au-dela d'un trou."""
    best = None
    for point_time, fraction in curve:
        if point_time > time:
            break
        best = (point_time, fraction)
    if best is None or time - best[0] > MAX_HEALTH_GAP:
        return None
    return best[1]


# ----------------------------------------------------------------------------
# Bornes de phase
# ----------------------------------------------------------------------------

def phase_bounds(phases, curve, first_casts, transitions=None):
    """{index de phase 1-based : t depuis le pull} pour les phases situees.

    `phases`      : le tableau `phases` du fichier de data, deja converti en liste.
    `curve`       : sortie de `health_curve`.
    `first_casts` : {spellId : [t, ...] tries} des casts du boss.
    `transitions` : [(id, t depuis le pull)] de `phaseTransitions`, en secours.

    Une phase absente du dictionnaire n'a pas ete situee. C'est le cas normal
    pour un declencheur `EMOTE` (texte localise) ou quand la courbe de vie a un
    trou au moment du franchissement — et c'est pour ca que le resultat est un
    dictionnaire creux et pas une liste : une borne inconnue doit se voir.
    """
    bounds = {}
    if not phases:
        return bounds

    # La phase 1 est celle de l'engage : elle ne porte pas de declencheur et
    # commence au pull, par definition.
    bounds[1] = 0.0

    by_transition = {index: float(time) for index, time in (transitions or [])}
    aligned = len(by_transition) == len(phases)

    for index in range(2, len(phases) + 1):
        phase = phases[index - 1]
        previous = bounds.get(index - 1)
        trigger = phase.get("trigger")
        found = None

        if trigger == "HEALTH" and phase.get("threshold") is not None:
            found = crossed_at(curve, float(phase["threshold"]),
                               after=(previous or 0.0) + MIN_PHASE_LENGTH)
        elif trigger == "CAST" and phase.get("spellId") is not None:
            floor = (previous or 0.0) + MIN_PHASE_LENGTH
            found = next((t for t in first_casts.get(phase["spellId"], []) if t >= floor), None)
        elif trigger == "PULL" and phase.get("time") is not None:
            # Rien a mesurer : l'echeance est ecrite dans la data. La borne sert
            # quand meme d'origine aux timers `PHASE` de cette phase.
            found = float(phase["time"])
        elif trigger == "PHASE" and phase.get("time") is not None and previous is not None:
            found = previous + float(phase["time"])

        # Secours : la segmentation de WarcraftLogs, et seulement si elle a
        # autant de phases que la data. Un decoupage qui ne compte pas pareil
        # (intermission comptee a part, par exemple) ne s'aligne pas index par
        # index, et un mauvais alignement produirait des mesures precises et
        # fausses — pire que pas de mesure du tout.
        if found is None and aligned:
            found = by_transition.get(index)

        # Les bornes sont croissantes par construction. Une borne qui recule
        # signale une detection qui a mordu sur autre chose : on la jette.
        if found is None or (previous is not None and found < previous):
            continue
        bounds[index] = round(float(found), 2)

    return bounds


def phase_of(bounds, phase_count: int, time: float):
    """Index de la phase qui contient `time`, ou None si le log ne tranche pas.

    Une phase n'est attribuee que si son debut ET sa fin sont connus (ou qu'elle
    est la derniere). Entre deux bornes connues separees par une borne inconnue,
    le cast appartient a l'une des deux phases sans qu'on sache laquelle :
    l'ecarter est la seule reponse honnete.
    """
    for index in range(phase_count, 0, -1):
        start = bounds.get(index)
        if start is None or time < start:
            continue
        if index == phase_count:
            return index
        end = bounds.get(index + 1)
        if end is None:
            return None
        return index if time < end else None
    return None


# ----------------------------------------------------------------------------
# Proposition de phases (fichier sans tableau `phases`)
# ----------------------------------------------------------------------------

def propose_phases(samples, names=None):
    """Transforme les transitions relevees en entrees `phases` proposees.

    `samples` : {index de phase : [(t depuis le pull, fraction de vie|None), ...]},
    une entree par log. Le generateur signale, il ne devine pas : chaque entree
    sort `provisional = true`, et le choix du declencheur est justifie par la
    dispersion entre les logs, pas par une intuition sur la mecanique.
    """
    proposals, notes = [], []
    if not samples:
        return proposals, notes

    proposals.append({"name": "Phase 1"})
    for index in sorted(samples):
        if index < 2:
            continue
        times = [time for time, _ in samples[index]]
        healths = [health for _, health in samples[index] if health is not None]
        time_spread = statistics.pstdev(times) if len(times) > 1 else 0.0
        health_spread = statistics.pstdev(healths) if len(healths) > 1 else 0.0

        phase = {"name": "Phase %d" % index, "alert": "Phase %d" % index}
        if names and names.get(index):
            phase["name"] = names[index]

        # Une transition pilotee par la vie arrive a la meme vie et a des
        # instants tres differents d'un log a l'autre ; une transition a heure
        # fixe, l'inverse. C'est cette dissymetrie qui designe le declencheur.
        if healths and health_spread <= HEALTH_SPREAD:
            phase["trigger"] = "HEALTH"
            phase["threshold"] = round(statistics.median(healths), 2)
            reason = "vie %.0f%% (sigma %.1f pt, %d log(s))" % (
                statistics.median(healths) * 100, health_spread * 100, len(healths))
        else:
            phase["trigger"] = "PULL"
            phase["time"] = round(statistics.median(times), 1)
            reason = "pull +%.0fs (sigma %.1fs, %d log(s))" % (
                statistics.median(times), time_spread, len(times))
            if time_spread > TIME_SPREAD:
                reason += " — disperse, declencheur a trouver a la main"

        phase["provisional"] = True
        proposals.append(phase)
        notes.append("  phase %d : %s" % (index, reason))

    return proposals, notes
