#!/usr/bin/env python3
"""Tests de la mesure des timers PHASE, sans reseau.

Ce qui merite d'etre teste ici, c'est ce qui distingue une mesure d'une
invention. Situer une borne de phase dans un log permet enfin de mesurer un
timer `PHASE` — mais la meme machinerie, mal bornee, produirait des chiffres
precis et faux, ce qui est pire que le `provisional` qu'elle remplace.

Le scenario rejoue un boss facon Onyxia : trois phases, Flame Breath en P1 et en
P3 (deux timers, un seul spellId), Fireball Volley en P2 seulement.

  * la courbe de vie est reconstruite depuis les degats subis ;
  * un trou dans la courbe -> borne non situee, pas borne devinee ;
  * un cast entre deux bornes dont l'une manque -> ecarte, pas attribue ;
  * le timer PHASE recoit le delta depuis SA borne, pas depuis le pull ;
  * un premier cast disperse + une cadence serree -> `-- TODO phase ?`,
    pas `variable`.
"""

import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "wcl-ingest"))
sys.path.insert(0, str(ROOT / "tools" / "wa-extract"))

import wcl_ingest as wi  # noqa: E402
import wcl_phases as wp  # noqa: E402

passed = failed = 0


def ok(condition, label):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   {label}")
    else:
        failed += 1
        print(f"  FAIL {label}")


def equal(actual, expected, label):
    ok(actual == expected, f"{label} (attendu {expected!r}, obtenu {actual!r})")


def close(actual, expected, label, tolerance=0.2):
    ok(actual is not None and abs(actual - expected) <= tolerance,
       f"{label} (attendu ~{expected}, obtenu {actual!r})")


def suite(name):
    print(f"\n== {name}")


# ----------------------------------------------------------------------------
# Scenario
# ----------------------------------------------------------------------------

BOSS_ID, NPC_ID, MAX_HP = 50, 10184, 1000000
ADD_ID = 51
ACTORS = {BOSS_ID: {"id": BOSS_ID, "gameID": NPC_ID, "name": "Onyxia", "type": "NPC"},
          ADD_ID: {"id": ADD_ID, "gameID": 99999, "name": "Whelp", "type": "NPC"}}

PULL = 1000.0            # timestamp du pull, en ms
FLAME, VOLLEY = 17086, 18435

PHASES = [
    {"name": "Sol"},
    {"name": "Vol", "trigger": "HEALTH", "threshold": 0.65},
    {"name": "Sol", "trigger": "HEALTH", "threshold": 0.40},
]


def hit(time, fraction, target=BOSS_ID):
    """Un coup encaisse par le boss : c'est ce qui porte sa vie dans un log."""
    return {"type": "damage", "targetID": target, "timestamp": PULL + time * 1000,
            "hitPoints": int(fraction * MAX_HP), "maxHitPoints": MAX_HP}


def linear_curve(step=2.0, duration=200.0):
    """Vie qui descend regulierement de 100 % a 0 sur `duration` secondes."""
    events, time = [], 0.0
    while time <= duration:
        events.append(hit(time, 1.0 - time / duration))
        time += step
    return events


# 65 % a t=70, 40 % a t=120 sur 200 s de combat.
DAMAGE = linear_curve()
CURVE = wp.health_curve(DAMAGE, ACTORS, NPC_ID, PULL)


# ----------------------------------------------------------------------------
suite("Courbe de vie")

ok(len(CURVE) > 50, "la courbe est reconstruite depuis les degats subis")
close(CURVE[0][1], 1.0, "elle part a pleine vie")
close(wp.health_at(CURVE, 100.0), 0.5, "la vie a un instant donne est relue")

equal(wp.health_curve(DAMAGE, ACTORS, 99999, PULL), [],
      "les degats sur un add ne comptent pas dans la vie du boss")
equal(wp.health_at(CURVE, 500.0), None,
      "au-dela du dernier coup, on ne prolonge pas la courbe")

close(wp.crossed_at(CURVE, 0.65), 70.0, "le seuil de 65 % est date")
close(wp.crossed_at(CURVE, 0.40), 120.0, "le seuil de 40 % est date")
equal(wp.crossed_at(wp.health_curve([hit(0, 1.0), hit(4, 0.9)], ACTORS, NPC_ID, PULL), 0.5),
      None, "un seuil que le log ne montre jamais franchi n'est pas date")

# Un boss immunise ne prend rien : sa courbe s'arrete, et on sait seulement que
# le seuil est tombe quelque part dans le trou. Placer la borne au premier coup
# d'apres donnerait une mesure a la seconde sur une information qu'on n'a pas.
GAPPED = wp.health_curve([hit(0, 1.0), hit(10, 0.9), hit(45, 0.5)], ACTORS, NPC_ID, PULL)
equal(wp.crossed_at(GAPPED, 0.65), None,
      "un trou dans la courbe : le seuil n'est pas date")


# ----------------------------------------------------------------------------
suite("Bornes de phase")

CASTS = {
    # Flame Breath : P1 a partir de 12 s, puis P3 a partir de 130 s (borne + 10).
    FLAME: [12.0, 37.0, 62.0, 130.0, 155.0, 180.0],
    # Fireball Volley : P2 uniquement.
    VOLLEY: [75.0, 90.0, 105.0],
}

bounds = wp.phase_bounds(PHASES, CURVE, CASTS)
equal(bounds.get(1), 0.0, "la phase 1 commence au pull, par definition")
close(bounds.get(2), 70.0, "la phase 2 est situee sur son seuil de vie")
close(bounds.get(3), 120.0, "la phase 3 est situee sur le sien")

equal(wp.phase_bounds([], CURVE, CASTS), {},
      "sans tableau `phases`, il n'y a rien a situer")
equal(wp.phase_bounds(PHASES, [], CASTS), {1: 0.0},
      "sans courbe de vie, les seuils ne sont pas situes")

# Un declencheur `CAST` designe le premier cast APRES la borne precedente : la
# premiere occurrence dans l'absolu designerait la phase 1.
cast_phases = [{"name": "Sol"},
               {"name": "Vol", "trigger": "HEALTH", "threshold": 0.65},
               {"name": "Atterrissage", "trigger": "CAST", "spellId": FLAME}]
close(wp.phase_bounds(cast_phases, CURVE, CASTS).get(3), 130.0,
      "un declencheur CAST est rejoue apres la borne precedente")

# Un declencheur localise (EMOTE) n'est pas rejouable hors du jeu : sans secours,
# la borne reste inconnue plutot que d'etre approchee.
emote_phases = [{"name": "Sol"}, {"name": "Adds", "trigger": "EMOTE", "pattern": "rugit"}]
equal(wp.phase_bounds(emote_phases, CURVE, CASTS), {1: 0.0},
      "un declencheur EMOTE n'est pas situable depuis un log")

# `phaseTransitions` prend le relais, mais seulement si WCL decoupe la rencontre
# comme la data : un decoupage qui ne compte pas pareil ne s'aligne pas index par
# index, et un mauvais alignement mesure precisement la mauvaise phase.
transitions = [(1, 0.0), (2, 68.0)]   # deja converties en secondes depuis le pull
close(wp.phase_bounds(emote_phases, CURVE, CASTS, transitions).get(2), 68.0,
      "phaseTransitions comble une borne quand le decoupage correspond")
equal(wp.phase_bounds(PHASES, [], CASTS, transitions), {1: 0.0},
      "un decoupage qui ne compte pas pareil n'est pas aligne de force")


# ----------------------------------------------------------------------------
suite("Attribution des casts a une phase")

equal(wp.phase_of(bounds, 3, 12.0), 1, "un cast avant la premiere borne est en phase 1")
equal(wp.phase_of(bounds, 3, 75.0), 2, "un cast entre deux bornes est dans la phase")
equal(wp.phase_of(bounds, 3, 130.0), 3, "un cast apres la derniere borne est en phase 3")

# Borne 2 inconnue : un cast a 75 s appartient a la phase 1 ou a la phase 2, le
# log ne tranche pas. L'ecarter est la seule reponse honnete.
partial = {1: 0.0, 3: 120.0}
equal(wp.phase_of(partial, 3, 75.0), None,
      "entre deux bornes dont une manque, le cast n'est attribue a personne")
equal(wp.phase_of(partial, 3, 130.0), 3,
      "mais apres la derniere borne connue, il n'y a plus d'ambiguite")


# ----------------------------------------------------------------------------
suite("Mesure depuis la borne de phase")

stats = defaultdict(wi.new_stat)
wi.split_by_phase(stats, CASTS, bounds, len(PHASES))

flame_phases = stats[FLAME]["phases"]
close(flame_phases[1]["firsts"][0], 12.0, "P1 : Flame Breath mesure depuis le pull")
close(flame_phases[3]["firsts"][0], 10.0,
      "P3 : le meme sort mesure depuis l'atterrissage, pas depuis le pull")
equal(stats[VOLLEY]["phases"].keys() | set(), {2},
      "Fireball Volley n'est vu qu'en phase 2")

# Deux logs identiques : la mediane doit sortir la meme chose, avec une cadence.
# Les deltas depuis le pull sont releves a part par `collect` — on les simule
# ici, sinon le sort n'atteint pas `--min-reports` et n'est pas publie du tout.
for _ in range(2):
    wi.split_by_phase(stats, CASTS, bounds, len(PHASES))
for spell, times in CASTS.items():
    stats[spell]["firsts"].extend([times[0]] * 3)
    stats[spell]["intervals"].extend(wi.deltas(times) * 3)
rows = {row["spellId"]: row for row in wi.summarise(stats, min_reports=2)}
flame = rows[FLAME]
close(flame["phases"][3]["time"], 10.0, "la mediane du delta de phase est publiee")
close(flame["phases"][3]["repeatInterval"], 25.0, "la cadence de la phase aussi")


# ----------------------------------------------------------------------------
suite("Fusion : un timer PHASE devient mesurable")

phase_timer = {"trigger": "PHASE", "phase": 3, "time": 14, "spellId": FLAME,
               "name": "Flame Breath", "provisional": True}
merged = wi.merge_timer(phase_timer, flame)
close(merged["time"], 10.0, "le `time` ecrit a la main est remplace par la mesure")
ok("provisional" not in merged, "et le timer cesse d'etre provisoire")
equal(merged["name"], "Flame Breath", "le libelle survit")

# Sans mesure pour cette phase, on ne touche a rien : c'est l'etat d'avant, et
# c'est le bon. Un timer PHASE qui recevrait le delta depuis le pull afficherait
# une barre fausse avec l'aplomb d'une barre mesuree.
orphan = dict(phase_timer, phase=9)
kept = wi.merge_timer(orphan, flame)
equal(kept["time"], 14, "phase non mesuree : le `time` ecrit a la main reste")
equal(kept["provisional"], True, "et le timer reste provisoire")


# Un sort present dans deux phases : entre son dernier cast en P1 et son premier
# en P3 il y a un trou de 70 s, qui n'est pas une cadence. Compte dans le tas, il
# fait passer un timer parfaitement regulier pour du non deterministe — c'est
# exactement ce que la mesure par phase permet enfin d'eviter.
mixed = rows[FLAME]
ok(mixed["intervalStdev"] > wi.VARIABLE_STDEV,
   "la cadence globale d'un sort multi-phases est polluee par le passage de phase")
equal(mixed["phases"][1]["intervalStdev"], 0.0, "la cadence de la P1 est propre")
equal(mixed["phases"][3]["intervalStdev"], 0.0, "celle de la P3 aussi")

p1 = wi.merge_timer({"trigger": "PULL", "phase": 1, "spellId": FLAME}, mixed)
ok("variable" not in p1, "un timer restreint a une phase n'herite pas de cette pollution")
close(p1["repeatInterval"], 25.0, "il prend la cadence de sa phase")

nowhere = wi.merge_timer({"trigger": "PULL", "spellId": FLAME}, mixed)
equal(nowhere["variable"], True,
      "un timer sans phase declaree, lui, garde la mesure globale telle quelle")


# ----------------------------------------------------------------------------
suite("Proposition de phase (`-- TODO phase ?`)")

# Le premier cast se disperse d'un log a l'autre, la cadence ne bouge pas : la
# signature d'un sort qui attend une phase, pas d'une mecanique aleatoire.
gated = wi.summarise({FLAME: {"firsts": [12.0, 40.0, 25.0, 55.0],
                              "intervals": [25.0, 25.2, 24.8, 25.1],
                              "phases": {}}}, min_reports=2)[0]
equal(gated["phaseGated"], True, "premier cast disperse + cadence serree -> phase suspectee")
equal(gated["variable"], False, "et ce n'est PAS un timing aleatoire")

# Les deux disperses : la, c'est bien du non deterministe.
noisy = wi.summarise({VOLLEY: {"firsts": [12.0, 40.0, 25.0, 55.0],
                               "intervals": [10.0, 30.0, 18.0, 41.0],
                               "phases": {}}}, min_reports=2)[0]
equal(noisy["phaseGated"], False, "cadence dispersee aussi -> pas une phase")
equal(noisy["variable"], True, "-> `variable`, comme avant")

# Tout serre : rien a signaler.
clean = wi.summarise({VOLLEY: {"firsts": [12.0, 12.4, 11.8, 12.1],
                               "intervals": [25.0, 25.2, 24.8, 25.1],
                               "phases": {}}}, min_reports=2)[0]
equal((clean["phaseGated"], clean["variable"]), (False, False),
      "une mesure stable ne porte aucun drapeau")

pull_timer = {"trigger": "PULL", "time": 12, "spellId": FLAME, "bar": True}
flagged = wi.merge_timer(pull_timer, gated)
equal(flagged["provisional"], True,
      "un timer PULL dont la mesure sent la phase reste provisoire")
ok("variable" not in flagged, "et n'est pas marque `variable` a tort")

fresh = wi.new_timer(gated)
equal(fresh["provisional"], True, "un sort inedit dans le meme cas nait provisoire")

lines = "\n".join(wi.render_timer(flagged, gated, False))
ok("-- TODO phase ?" in lines, "le fichier emis porte le TODO")
ok("cadence serree" in lines, "et dit sur quoi repose le doute")

lines = "\n".join(wi.render_timer(merged, flame, False))
ok("sigma phase 3" in lines, "un timer PHASE mesure dit depuis quelle borne")
lines = "\n".join(wi.render_timer(kept, flame, False))
ok("phase 9 non situee" in lines, "un timer PHASE non mesure le dit aussi")


# ----------------------------------------------------------------------------
suite("Proposition d'un tableau `phases`")

# Transitions relevees sur trois logs : la phase 2 tombe toujours a 65 % de vie
# a des instants tres differents (pilotee par la vie), la phase 3 toujours vers
# 120 s a des vies tres differentes (pilotee par le temps).
samples = {
    1: [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0)],
    2: [(62.0, 0.65), (78.0, 0.64), (70.0, 0.66)],
    3: [(119.0, 0.30), (121.0, 0.52), (120.0, 0.41)],
}
proposed, notes = wp.propose_phases(samples)
equal(len(proposed), 3, "une entree par phase, phase 1 comprise")
equal(proposed[0], {"name": "Phase 1"}, "la phase 1 ne porte pas de declencheur")
equal(proposed[1]["trigger"], "HEALTH", "vie constante entre les logs -> HEALTH")
close(proposed[1]["threshold"], 0.65, "avec le seuil median")
equal(proposed[2]["trigger"], "PULL", "vie dispersee mais heure fixe -> PULL")
close(proposed[2]["time"], 120.0, "avec le delai median")
ok(all(phase.get("provisional") for phase in proposed[1:]),
   "toute entree proposee est marquee `provisional`")
ok(any("sigma" in note for note in notes), "chaque proposition est justifiee par ses chiffres")

# Et la regle qui compte : une proposition ne remplace jamais un tableau ecrit a
# la main. C'est ce tableau qui est la mecanique du combat.
args = wi.parse_args(["--npc-id", str(NPC_ID), "--flavor", "vanilla",
                      "--raid", "Onyxias_Lair", "--boss", "Onyxia"])
header = wi.merge_header(args, {"phases": {1: {"name": "Sol"}}}, proposed)
equal(wi.lua_array(header["phases"]), [{"name": "Sol"}],
      "un tableau `phases` existant n'est jamais remplace par une proposition")
header = wi.merge_header(args, {}, proposed)
equal(len(wi.lua_array(header["phases"])), 3,
      "mais un fichier sans phases en recoit une proposition")


print(f"\n{passed} ok, {failed} echec(s)")
sys.exit(0 if failed == 0 else 1)
