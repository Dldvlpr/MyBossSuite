#!/usr/bin/env python3
"""Ingestion WarcraftLogs -> fichier de data MyBossSuite.

Source principale de timings : les logs sont des faits mesures, pas une oeuvre
derivee, et l'API couvre les 6 flavors via les partitions / zones. Un seul
script produit donc la data de toutes les versions du jeu.

Principe : pour N logs d'un meme boss, on releve pour chaque sort ennemi le
delta entre le debut du combat et chaque cast, puis on prend la MEDIANE (robuste
aux pulls rates et aux outliers). Si l'ecart-type des deltas est eleve, le timer
est marque `variable = true` : ce n'est plus une echeance, c'est le moment ou la
capacite redevient possible. Le module l'affiche comme incertain, n'annonce rien
a l'ecoulement de l'estimation (le sort est disponible, pas lance) et attend le
cast reel — qui, lui, s'affiche quand le boss le fait.

Un fichier de data n'est pas qu'un releve. La structure — phases, seuils de vie,
libelles, `warnBefore` — s'ecrit a la main et ne se mesure pas. Une regeneration
FUSIONNE donc avec le fichier existant : seuls les champs mesures (`time`,
`repeatInterval`, `variable`) sont reecrits, tout le reste est conserve, y
compris les timers entierement manuels comme les seuils de phase. Sans ca chaque
passage jetterait le travail d'edition, et un boss a phases ne serait jamais
regenerable. `--replace` force le comportement d'ecrasement.

Pre-requis : un client API sur https://www.warcraftlogs.com/api/clients/ (OAuth,
gratuit), puis un fichier `.env` a la racine du depot (voir `.env.example`) :

    WCL_CLIENT_ID=...
    WCL_CLIENT_SECRET=...

Les variables d'environnement font aussi l'affaire et restent prioritaires
(bash : `export WCL_CLIENT_ID=...` ; PowerShell : `$env:WCL_CLIENT_ID = '...'`).

Exemples :

    # decouverte automatique des logs via le classement de la rencontre
    tools/wcl-ingest/wcl_ingest.py --encounter 1084 --npc-id 10184 \
        --flavor vanilla --raid "Onyxias_Lair" --boss Onyxia --limit 10

    # logs choisis a la main
    tools/wcl-ingest/wcl_ingest.py --report aBcDeFgH:12 --report xYz123:4 \
        --npc-id 10184 --flavor vanilla --raid "Onyxias_Lair" --boss Onyxia
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys
import urllib.error
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
# lua_table sait relire un litteral Lua sans interpreteur : c'est ce qui permet
# de rouvrir un fichier de data pour le fusionner au lieu de l'ecraser.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "wa-extract"))

import lua_table  # noqa: E402
import wcl_phases  # noqa: E402
from wcl_api import (  # noqa: E402
    FLAVORS,
    WCLError,
    discover_reports,
    fetch_events,
    fetch_fight,
    fetch_phase_transitions,
    get_token,
    load_credentials,
    parse_report_arg,
)

# Au-dela de cet ecart-type (en secondes) sur les deltas, le timing est traite
# comme non deterministe (cooldown interne + choix aleatoire, cast conditionne
# par une phase, etc.).
VARIABLE_STDEV = 2.5

# En dessous de ce nombre d'observations, on ne publie pas de repeatInterval.
MIN_SAMPLES = 3

# Signature d'une capacite gatee par une phase : le premier cast se disperse
# d'un log a l'autre (la phase n'arrive pas a heure fixe) alors que la cadence,
# elle, reste serree une fois la phase entamee. Une mecanique reellement
# aleatoire disperse les deux. C'est la seule chose qui les distingue depuis un
# delta depuis le pull, et elle ne conclut pas : elle signale.
PHASE_INTERVAL_STDEV = 1.5

# Au-dela de cette part des observations dans une meme phase, on nomme la phase
# suspectee dans le commentaire. En dessous, on dit juste qu'il y a un doute.
PHASE_HINT_SHARE = 0.6


def fetch_casts(token: str, code: str, fight_id: int, start: float):
    return fetch_events(token, code, fight_id, start, "Casts", "Enemies")


def fetch_boss_damage(token: str, code: str, fight_id: int, start: float, target_ids):
    """Degats subis par le boss — c'est ce qui porte sa vie, donc sa courbe.

    Le filtre est evalue par WCL : sans lui on rapatrie les degats de tout le
    raid pour n'en garder qu'une cible. S'il est refuse, on retombe sur la
    version non filtree plutot que de renoncer a la courbe.
    """
    expression = " or ".join("target.id = %d" % actor_id for actor_id in sorted(target_ids))
    try:
        return fetch_events(token, code, fight_id, start, "DamageDone", "Friendlies",
                            expression or None)
    except WCLError:
        return fetch_events(token, code, fight_id, start, "DamageDone", "Friendlies")


def needs_health_curve(phases) -> bool:
    return any(phase.get("trigger") == "HEALTH" for phase in phases)


# ----------------------------------------------------------------------------
# Agregation
# ----------------------------------------------------------------------------

def deltas(times):
    """Intervalles entre casts consecutifs, bornes pour ecarter le bruit.

    Sous la seconde on regarde deux coups du meme cast (multi-cible), au-dela de
    dix minutes on regarde deux phases sans rapport : ni l'un ni l'autre n'est
    une cadence.
    """
    return [round(b - a, 2) for a, b in zip(times, times[1:]) if 1.0 < (b - a) < 600.0]


def new_stat():
    return {"firsts": [], "intervals": [],
            "phases": defaultdict(lambda: {"firsts": [], "intervals": []})}


def collect(token: str, reports, npc_id: int | None, verbose: bool,
            phases=None, want_phases: bool = True):
    """Retourne (stats, nombre de logs exploites, releve des phases).

    `stats[abilityGameID]` porte les deltas depuis le pull, et — quand les
    bornes de phase ont pu etre situees — les memes deltas comptes depuis
    l'entree dans chaque phase. C'est cette seconde mesure qui rend un timer
    `PHASE` mesurable au lieu de rester ecrit a la main.
    """
    phases = phases or []
    stats = defaultdict(new_stat)
    phase_report = {"transitions": defaultdict(list), "situated": defaultdict(int),
                    "curve": 0, "asked": 0}
    used = 0

    for code, fight_id in reports:
        try:
            fight, actors, _ = fetch_fight(token, code, fight_id)
            events = fetch_casts(token, code, fight_id, float(fight["startTime"]))
        except (WCLError, urllib.error.URLError) as exc:
            print(f"  ! {code}:{fight_id} ignore ({exc})", file=sys.stderr)
            continue

        pull = float(fight["startTime"])
        by_ability = defaultdict(list)

        for event in events:
            if event.get("type") not in ("cast", "begincast"):
                continue
            source = actors.get(event.get("sourceID"))
            if source is None:
                continue
            if npc_id is not None and source.get("gameID") != npc_id:
                continue
            ability = event.get("abilityGameID")
            if ability is None:
                continue
            by_ability[ability].append((float(event["timestamp"]) - pull) / 1000.0)

        if not by_ability:
            print(f"  ! {code}:{fight_id} : aucun cast ennemi retenu", file=sys.stderr)
            continue

        used += 1
        for ability, times in by_ability.items():
            times.sort()
            entry = stats[ability]
            entry["firsts"].append(times[0])
            entry["intervals"].extend(deltas(times))

        bounds = {}
        if want_phases:
            bounds = situate_phases(token, code, fight_id, fight, actors, npc_id,
                                    phases, by_ability, phase_report)
            for index in bounds:
                phase_report["situated"][index] += 1

        if bounds and phases:
            split_by_phase(stats, by_ability, bounds, len(phases))

        if verbose:
            situated = ", ".join(str(index) for index in sorted(bounds)) or "aucune"
            print(f"  + {code}:{fight_id} — {len(by_ability)} sort(s), pull {fight['name']}"
                  f" ; phases situees : {situated}")

    return stats, used, phase_report


def situate_phases(token, code, fight_id, fight, actors, npc_id, phases,
                   by_ability, phase_report):
    """Bornes de phase d'un combat, et releve des transitions pour la proposition.

    Aucun echec n'arrete l'ingestion : une phase non situee laisse simplement le
    timer `PHASE` correspondant tel qu'il a ete ecrit a la main, ce qui est
    exactement l'etat d'avant.
    """
    pull = float(fight["startTime"])
    raw, names = fetch_phase_transitions(token, code, fight_id)
    # Tout le module de phases raisonne en secondes depuis le pull, comme la
    # courbe et les casts : la conversion se fait ici, une fois.
    transitions = [(index, (timestamp - pull) / 1000.0) for index, timestamp in raw]

    # La courbe de vie coute cher (les degats du raid entier avant filtrage) :
    # on ne la demande que si quelque chose la lit — un seuil de vie a rejouer,
    # ou une proposition de phases a etayer.
    curve = []
    if needs_health_curve(phases) or (not phases and transitions):
        phase_report["asked"] += 1
        # Sans npcId on ne sait pas qui filtrer : mieux vaut ne pas filtrer du
        # tout que d'enumerer tous les acteurs du rapport dans l'expression.
        target_ids = [actor_id for actor_id, actor in actors.items()
                      if actor.get("gameID") == npc_id] if npc_id is not None else []
        try:
            damage = fetch_boss_damage(token, code, fight_id, pull, target_ids)
            curve = wcl_phases.health_curve(damage, actors, npc_id, pull)
        except (WCLError, urllib.error.URLError) as exc:
            print(f"  ! {code}:{fight_id} : courbe de vie indisponible ({exc})",
                  file=sys.stderr)
        if curve:
            phase_report["curve"] += 1

    if not phases:
        # Rien a situer, mais tout a relever : ces transitions sont la matiere
        # de la proposition de `phases` pour un fichier qui n'en a pas encore.
        for index, delta in transitions:
            phase_report["transitions"][index].append((delta, wcl_phases.health_at(curve, delta)))
        phase_report["names"] = names
        return {}

    return wcl_phases.phase_bounds(phases, curve, by_ability, transitions)


def split_by_phase(stats, by_ability, bounds, phase_count: int):
    """Repartit les casts par phase et recompte les deltas depuis chaque borne."""
    for ability, times in by_ability.items():
        per_phase = defaultdict(list)
        for time in times:
            index = wcl_phases.phase_of(bounds, phase_count, time)
            if index is not None:
                per_phase[index].append(time)
        for index, phase_times in per_phase.items():
            entry = stats[ability]["phases"][index]
            entry["firsts"].append(round(phase_times[0] - bounds[index], 2))
            entry["intervals"].extend(deltas(phase_times))


def measure(firsts, intervals):
    """Mediane des deltas + dispersion, la brique commune pull / phase."""
    first = statistics.median(firsts)
    first_stdev = statistics.pstdev(firsts) if len(firsts) > 1 else 0.0
    interval = statistics.median(intervals) if len(intervals) >= MIN_SAMPLES else None
    interval_stdev = statistics.pstdev(intervals) if len(intervals) > 1 else 0.0
    return {
        "time": round(first, 1),
        "timeStdev": round(first_stdev, 2),
        "repeatInterval": round(interval, 1) if interval else None,
        "intervalStdev": round(interval_stdev, 2),
        "samples": len(firsts),
    }


def phase_hint(phase_rows):
    """Phase (>= 2) qui concentre les observations, ou None si elles se partagent.

    Sert uniquement a nommer une piste dans un commentaire. Une majorite franche
    est une indication ; une repartition equilibree n'en est pas une, et on
    prefere alors ne rien nommer plutot que de designer au hasard.
    """
    if not phase_rows:
        return None
    total = sum(row["samples"] for row in phase_rows.values())
    late = {index: row for index, row in phase_rows.items() if index >= 2}
    if not total or not late:
        return None
    index, row = max(late.items(), key=lambda item: item[1]["samples"])
    return index if row["samples"] / total >= PHASE_HINT_SHARE else None


def summarise(stats, min_reports: int):
    rows = []
    for ability, entry in stats.items():
        firsts = entry["firsts"]
        if len(firsts) < min_reports:
            continue
        row = measure(firsts, entry["intervals"])
        row["spellId"] = ability

        row["phases"] = {
            index: measure(data["firsts"], data["intervals"])
            for index, data in sorted(entry.get("phases", {}).items())
            if len(data["firsts"]) >= min_reports
        }

        # Un premier cast disperse alors que la cadence reste serree ne veut pas
        # dire "timing aleatoire" : ca veut dire que le sort attend quelque chose
        # — une phase — avant de partir, puis tourne comme une horloge. Le
        # generateur le signale (`-- TODO phase ?` + `provisional`) au lieu de le
        # noyer dans `variable`, qui dirait le contraire de ce qu'on a mesure.
        tight_cadence = (row["repeatInterval"] is not None
                         and row["intervalStdev"] <= PHASE_INTERVAL_STDEV)
        row["phaseGated"] = row["timeStdev"] > VARIABLE_STDEV and tight_cadence
        row["phaseHint"] = phase_hint(row["phases"]) if row["phaseGated"] else None
        row["variable"] = (not row["phaseGated"]
                           and max(row["timeStdev"], row["intervalStdev"]) > VARIABLE_STDEV)

        rows.append(row)
    rows.sort(key=lambda row: row["time"])
    return rows


# ----------------------------------------------------------------------------
# Fusion avec le fichier existant
# ----------------------------------------------------------------------------
# Ce que les logs mesurent, et donc ce qu'une regeneration a le droit de
# reecrire. Tout le reste d'un timer — trigger, phase, setPhase, seuil, libelle,
# warnBefore — est ecrit a la main : c'est de la structure, pas une mesure.
MEASURED_FIELDS = ("time", "repeatInterval", "variable")

# Triggers pour lesquels un `time` veut dire quelque chose. Ailleurs (CAST,
# AURA, EMOTE, DEATH) le champ est mort et doit disparaitre.
TIME_TRIGGERS = ("PULL", "PHASE")

# Ordre d'emission des champs, pour que deux regenerations du meme fichier
# donnent le meme diff. Les champs inconnus suivent, tries : un champ ajoute au
# format plus tard sort quand meme, il est juste mal place.
FIELD_ORDER = (
    "trigger", "time", "phase", "phases", "spellId", "castStart",
    "threshold", "pattern", "npcId", "on", "event",
    "name", "difficulties", "repeatInterval", "warnBefore", "once",
    "announce", "countdown", "flash", "bar", "variable", "pendingWindow",
    "testTime", "color", "icon", "key", "source", "provisional",
)

# Ordre d'emission d'une entree de `phases`. Meme raison.
PHASE_FIELD_ORDER = (
    "name", "trigger", "time", "threshold", "spellId", "castStart",
    "event", "pattern", "npcId", "alert", "difficulties",
    "warnBefore", "bar", "color", "testTime", "provisional",
)


def lua_array(table):
    """Partie tableau d'une table parsee (cles 1..n), dans l'ordre."""
    out, index = [], 1
    while index in table:
        out.append(table[index])
        index += 1
    return out


def lua_number(value):
    if isinstance(value, float) and value == int(value):
        return str(int(value))
    return ("%g" % value) if isinstance(value, float) else str(value)


def ordered_keys(table, order):
    """Cles de `table` : celles de `order` d'abord, le reste trie derriere."""
    keys = [key for key in order if key in table]
    return keys + sorted(key for key in table if key not in order)


def lua_value(value, order=()):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return lua_number(value)
    if isinstance(value, str):
        return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')
    if value is None:
        return "nil"
    if isinstance(value, dict):
        items = lua_array(value)
        if items and len(items) == len(value):
            return "{ %s }" % ", ".join(lua_value(item, order) for item in items)
        parts = []
        for key in ordered_keys(value, order):
            label = key if isinstance(key, str) else "[%s]" % lua_number(key)
            parts.append("%s = %s" % (label, lua_value(value[key], order)))
        return "{ %s }" % ", ".join(parts)
    raise TypeError("valeur Lua non serialisable : %r" % (value,))


def read_existing(path: Path, npc_id: int):
    """Retourne la def du boss deja presente dans `path`, ou None.

    Un fichier illisible n'est jamais ecrase en silence : l'appelant remonte
    l'erreur. Perdre des phases ecrites a la main sur une regression du parseur
    serait exactement ce que cette fusion existe pour empecher.
    """
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8")
    match = re.search(r"ns\.BossTimerData\s*\[\s*%d\s*\]\s*=\s*" % npc_id, text)
    if match is None:
        return None
    parser = lua_table.Parser(text)
    parser.pos = match.end()
    try:
        return parser.parse_value()
    except lua_table.LuaSyntaxError:
        raise
    except Exception as exc:
        # Un fichier tronque sort du parseur en IndexError, pas en
        # LuaSyntaxError. Tout ce qui rate se lit pareil ici — "je ne sais pas
        # relire ce fichier" — et doit emprunter le meme chemin, celui qui
        # refuse d'ecrire, plutot que de remonter en traceback.
        raise lua_table.LuaSyntaxError(
            "%s (offset %d)" % (exc.__class__.__name__, parser.pos)) from exc


def applied_measure(timer: dict, row):
    """Mesure qui s'applique a ce timer, et son origine.

    Un timer `PHASE` compte depuis l'entree dans sa phase : il ne peut recevoir
    que la mesure prise depuis cette borne-la, quand le log a permis de la
    situer. Un timer restreint a une phase (`phase = n`) prend lui aussi la
    mesure de cette phase : sinon sa cadence melange deux phases. Flame Breath
    revient toutes les 25 s en P1 puis toutes les 25 s en P3, mais l'ecart entre
    le dernier cast de la P1 et le premier de la P3 est un trou de 70 s, pas un
    intervalle — compte dans le tas, il fait passer un timer parfaitement regulier
    pour du non deterministe.

    Cette fonction est le seul endroit ou ce choix se fait : la fusion et le
    commentaire emis doivent parler de la meme mesure, sinon le fichier documente
    autre chose que ce qu'il porte.
    """
    if row is None:
        return None, None
    measured = (row.get("phases") or {}).get(timer.get("phase"))
    if timer.get("trigger") == "PHASE":
        # Sans borne situee, rien ne s'applique : son `time` reste ecrit a la main.
        return (measured, "phase %s" % timer.get("phase")) if measured else (None, None)
    if measured is not None:
        return measured, "phase %s" % timer.get("phase")
    return row, "pull"


def merge_timer(existing: dict, row):
    """Reecrit les champs mesures d'un timer, conserve tout le reste."""
    merged = dict(existing)
    if row is None:
        return merged

    # `pendingWindow` est une affirmation ecrite a la main : cette capacite n'a
    # pas d'heure, elle a une fenetre (le souffle d'Onyxia en vol, possible tant
    # que la phase dure, jamais garanti). Les logs, eux, mesurent toujours
    # quelque chose — la mediane des souffles observes, la cadence des ticks du
    # souffle lui-meme — et l'ecrire ici transformerait la fenetre en echeance
    # fausse au premier passage. On ne touche a rien.
    if merged.get("pendingWindow") is not None:
        return merged

    trigger = merged.get("trigger", "PULL")
    source, origin = applied_measure(merged, row)
    # `source` peut etre la mesure globale : ce qui distingue les deux cas, c'est
    # l'origine, pas la presence d'une mesure.
    from_phase = origin is not None and origin != "pull"

    if trigger == "PULL":
        # Ce qu'on mesure est un delta depuis le pull : ca ne s'ecrit que dans
        # un timer qui compte depuis le pull. La phase 1 commence au pull, donc
        # sa mesure a la meme origine — elle est juste mieux isolee.
        merged["time"] = source["time"]
        if row.get("phaseGated") and not from_phase:
            # Mesure suspecte : le sort a l'air d'attendre une phase. On garde
            # le chiffre — c'est le meilleur qu'on ait — mais le timer reste
            # provisoire et le commentaire emis dit quoi verifier.
            merged["provisional"] = True
        else:
            merged.pop("provisional", None)
    elif trigger == "PHASE":
        # Compte depuis l'entree dans sa phase. Quand la borne a pu etre situee
        # dans le log (seuil de vie rejoue, cast declencheur, `phaseTransitions`),
        # le delta est mesurable et le timer cesse d'etre provisoire. Sinon son
        # `time` reste celui ecrit a la main : y ecrire le delta depuis le pull
        # donnerait un chiffre precis et faux. Un meme sort porte souvent un
        # timer par phase (Flame Breath en P1 et en P3) : c'est cette distinction
        # qui empeche la mesure de la P1 d'ecraser le timing de la P3.
        if source is not None:
            merged["time"] = source["time"]
            merged.pop("provisional", None)
    else:
        merged.pop("time", None)

    # Cadence et dispersion viennent de la meme mesure que le `time` : melanger
    # une cadence de phase et une dispersion globale ferait dire au fichier le
    # contraire de ce qu'on a mesure.
    # Timer PHASE dont la borne manque : sa cadence n'est pas mesurable a part,
    # on retombe sur la mesure globale — c'est la seule qu'on ait.
    cadence = source or row
    if cadence["repeatInterval"]:
        merged["repeatInterval"] = cadence["repeatInterval"]
    if is_variable(cadence):
        merged["variable"] = True
    else:
        merged.pop("variable", None)
    return merged


def is_variable(source) -> bool:
    """Timing non deterministe : les deux dispersions sont larges.

    Sur la mesure globale le drapeau est deja calcule (il tient compte de la
    piste "phase") ; sur une mesure de phase il se recalcule ici, sur les seuls
    chiffres de cette phase.
    """
    if "variable" in source:
        return source["variable"]
    return max(source["timeStdev"], source["intervalStdev"]) > VARIABLE_STDEV


def new_timer(row):
    timer = {"trigger": "PULL", "time": row["time"], "spellId": row["spellId"], "bar": True}
    if row["repeatInterval"]:
        timer["repeatInterval"] = row["repeatInterval"]
    if row["variable"]:
        timer["variable"] = True
    if row.get("phaseGated"):
        timer["provisional"] = True
    return timer


def merge_timers(existing_timers, rows):
    """Retourne [(timer, row|None), ...] : l'ordre du fichier existant d'abord.

    Conserver l'ordre plutot que retrier par `time` garde les diffs lisibles
    d'un passage a l'autre. Les sorts jamais vus jusqu'ici arrivent a la fin,
    la ou on les remarque.
    """
    by_spell = {row["spellId"]: row for row in rows}
    merged, seen = [], set()

    for timer in existing_timers:
        spell = timer.get("spellId")
        row = by_spell.get(spell) if spell is not None else None
        if row is not None:
            seen.add(spell)
        merged.append((merge_timer(timer, row), row))

    for row in rows:
        if row["spellId"] not in seen:
            merged.append((new_timer(row), row))

    return merged


def merge_header(args, existing, proposed_phases=None):
    """Champs de tete du boss : la CLI tranche, l'existant comble le reste.

    Un tableau `phases` deja present passe par ici sans y toucher : c'est le
    champ le plus manuel du format — la mecanique du combat, pas une mesure — et
    donc celui qu'une regeneration ne doit surtout pas perdre. Une proposition
    n'est ecrite que dans le cas ou il n'y en a aucun, et chaque entree proposee
    porte `provisional = true` : elle demande une relecture, elle ne la remplace
    pas.
    """
    header = dict(existing) if existing else {}
    header.pop("timers", None)
    header["name"] = args.boss
    header["kind"] = args.kind
    if args.encounter:
        header["encounterId"] = args.encounter
    if args.zone:
        header["zone"] = args.zone
    if "flavors" not in header:
        header["flavors"] = {args.flavor: True}
    if proposed_phases and not header.get("phases"):
        header["phases"] = {index: phase for index, phase in enumerate(proposed_phases, 1)}
    return header


# ----------------------------------------------------------------------------
# Emission Lua
# ----------------------------------------------------------------------------

HEADER_ORDER = (
    "name", "kind", "encounterId", "instanceId", "npcIds", "flavors", "zone",
    "inactivity", "wipeGrace", "idleTimeout", "phases", "provisional",
)


def render_timer(timer, row, merged_existing: bool, notes=None):
    # `notes` : commentaires fournis par l'appelant (bossmod-extract dit d'ou
    # vient une entree). Ils passent avant ceux que la mesure ecrit elle-meme.
    lines = list(notes or [])
    if row is not None:
        source, origin = applied_measure(timer, row)
        if source is not None:
            lines.append(
                "        -- %d log(s), sigma %s %ss / interval %ss"
                % (source["samples"], origin, source["timeStdev"],
                   source["intervalStdev"])
            )
        else:
            # Timer PHASE dont la borne n'a pas ete situee : le dire, plutot que
            # d'afficher la dispersion depuis le pull, qui ne le concerne pas.
            lines.append(
                "        -- phase %s non situee dans ces logs : `time` reste ecrit"
                " a la main" % timer.get("phase", "?")
            )
        if timer.get("pendingWindow") is not None:
            lines.append(
                "        -- fenetre ecrite a la main : la mesure est affichee, pas"
                " ecrite dans le timer"
            )
        if row.get("phaseGated") and origin == "pull" and timer.get("trigger") == "PULL":
            # Le generateur signale, il ne tranche pas : convertir en `PHASE`
            # demande de savoir QUELLE phase, ce qu'un delta depuis le pull ne
            # dit pas. Il dit en revanche precisement pourquoi il doute.
            hint = (" — vu surtout en phase %d" % row["phaseHint"]) if row.get("phaseHint") else ""
            lines.append(
                "        -- TODO phase ? premier cast disperse (sigma %ss) mais cadence"
                " serree (sigma %ss)%s" % (row["timeStdev"], row["intervalStdev"], hint)
            )
    elif merged_existing:
        what = ("spell %d absent des logs de ce passage" % timer["spellId"]
                if timer.get("spellId") else "entree ecrite a la main")
        lines.append("        -- conserve : %s" % what)

    keys = ordered_keys(timer, FIELD_ORDER)
    width = max(len(k) for k in keys) if keys else 0

    lines.append("        {")
    for key in keys:
        lines.append("            %-*s = %s," % (width, key, lua_value(timer[key])))
    lines.append("        },")
    return lines


def render_lua(args, header, timers, encounter_name: str = "", used_reports: int = 0,
               banner=None, notes=None) -> str:
    """Emission d'un fichier de data.

    `banner` remplace l'en-tete de commentaires (un autre outil ecrit ce fichier
    et doit dire lequel), `notes` ajoute des commentaires par timer, indexes sur
    leur position. Les deux outils partagent cet emetteur exprès : deux formats
    differents feraient un faux diff geant a chaque fois qu'on passe de l'un a
    l'autre, et on cesserait de relire les vrais.
    """
    merged_existing = banner is None and any(row is None for _, row in timers)
    notes = notes or {}
    lines = list(banner) if banner else [
        "-- %s — flavor %s (npcId %d)" % (args.boss, args.flavor, args.npc_id),
        "--",
        "-- GENERE PAR tools/wcl-ingest/wcl_ingest.py — mediane des deltas mesures.",
        "-- Rencontre WCL : %s | logs retenus : %d" % (encounter_name or "?", used_reports),
        "-- Les timers marques `variable` ont un ecart-type eleve : mecanique non",
        "-- deterministe. Leur `time` n'est pas une echeance mais le moment ou la",
        "-- capacite redevient possible : la barre s'affiche comme incertaine, elle",
        "-- reste a zero sans rien annoncer une fois l'estimation ecoulee, et c'est le",
        "-- cast observe dans le combat log qui declenche l'annonce. Un timer qui",
        "-- porte `pendingWindow` va plus loin : sa capacite n'a pas d'heure du tout,",
        "-- la mesure ne s'y ecrit pas et le timer traverse la regeneration intact.",
        "--",
        "-- Un timer PHASE compte depuis l'entree dans sa phase : il n'est mesure que",
        "-- si cette borne a pu etre situee dans le log (seuil de vie rejoue, cast",
        "-- declencheur, phaseTransitions). Sinon son `time` reste ecrit a la main et",
        "-- il reste `provisional`. Meme mot sur une phase : entree proposee, a relire.",
        "-- `-- TODO phase ?` marque un sort dont le premier cast se disperse alors que",
        "-- sa cadence est serree : la signature d'un sort qui attend une phase.",
        "--",
        "-- Regeneration : seuls `repeatInterval`, `variable` et le `time` mesure sont",
        "-- reecrits. Phases, seuils, libelles, annonces et tout autre champ ecrit a la",
        "-- main sont conserves : editer ce fichier est sur, relancer l'ingestion ne les",
        "-- effacera pas.",
    ]
    lines += ["", "local _, ns = ...", "", "ns.BossTimerData[%d] = {" % args.npc_id]

    keys = ordered_keys(header, HEADER_ORDER)
    width = max([len(k) for k in keys] + [len("timers")])
    for key in keys:
        if key == "phases":
            # Une phase par ligne : c'est la mecanique du combat, ca se relit et
            # ca se corrige a la main, pas sur une ligne de 200 colonnes.
            lines.append("    %-*s = {" % (width, "phases"))
            for phase in lua_array(header["phases"]):
                lines.append("        %s," % lua_value(phase, PHASE_FIELD_ORDER))
            lines.append("    },")
        else:
            lines.append("    %-*s = %s," % (width, key, lua_value(header[key])))

    lines.append("    %-*s = {" % (width, "timers"))
    for index, (timer, row) in enumerate(timers):
        lines.extend(render_timer(timer, row, merged_existing, notes.get(index)))
    lines += ["    },", "}", ""]

    encounter_id = header.get("encounterId")
    if encounter_id:
        lines.append("-- ENCOUNTER_START livre un encounterID, pas un npcId.")
        lines.append("ns.BossTimerEncounter[%d] = %d" % (encounter_id, args.npc_id))
        lines.append("")
    return "\n".join(lines)


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--report", action="append", default=[], metavar="CODE:FIGHT",
                        help="log a analyser, repetable")
    parser.add_argument("--encounter", type=int, help="encounterID WCL (decouverte automatique des logs)")
    parser.add_argument("--partition", type=int, help="partition WCL (une par version/saison)")
    parser.add_argument("--npc-id", type=int, required=True, help="npcId du boss, cle du fichier de data")
    parser.add_argument("--flavor", required=True, choices=FLAVORS)
    parser.add_argument("--raid", required=True, help="dossier de zone (raid, donjon ou zone de monde), ex. Onyxias_Lair")
    parser.add_argument("--kind", default="raid", choices=["raid", "dungeon", "world"],
                        help="nature de la rencontre : raid (defaut), dungeon ou world (world boss)")
    parser.add_argument("--zone", help="nom de zone affiche par /mbs boss list")
    parser.add_argument("--boss", required=True, help="nom du boss (affichage + nom de fichier)")
    parser.add_argument("--limit", type=int, default=10, help="nombre de logs (defaut 10)")
    parser.add_argument("--min-reports", type=int, default=2,
                        help="nombre minimum de logs ou un sort doit apparaitre (defaut 2)")
    parser.add_argument("--out", help="chemin de sortie (defaut : Modules/BossTimer/Data/<flavor>/<raid>/<boss>.lua)")
    parser.add_argument("--replace", action="store_true",
                        help="ecrase le fichier existant au lieu de le fusionner "
                             "(perd phases, seuils et libelles ecrits a la main)")
    parser.add_argument("--no-phases", dest="phases", action="store_false",
                        help="n'essaie pas de situer les bornes de phase : les timers "
                             "PHASE gardent leur `time` ecrit a la main et aucune "
                             "proposition n'est faite. Economise les requetes de degats.")
    parser.add_argument("--dry-run", action="store_true", help="affiche les stats sans ecrire de fichier")
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args(argv)


def report_phases(phase_report, existing_phases, used: int, args):
    """Rend compte des bornes situees, et propose un `phases` s'il n'y en a pas.

    Ce que l'operateur doit pouvoir lire en une ligne : est-ce que cette passe a
    rendu les timers PHASE mesurables, ou est-ce qu'ils restent ecrits a la main.
    Une phase situee dans deux logs sur dix ne vaut pas une phase situee partout,
    et le silence sur ce point ferait passer une mesure fragile pour un fait.
    """
    if not args.phases:
        return None

    if existing_phases:
        situated = phase_report["situated"]
        if not situated:
            print("aucune borne de phase situee : les timers PHASE gardent leur "
                  "`time` ecrit a la main.")
            return None
        detail = ", ".join("phase %d dans %d/%d log(s)" % (index, situated[index], used)
                           for index in sorted(situated) if index >= 2)
        print("bornes de phase situees : %s." % (detail or "phase 1 seulement (le pull)"))
        return None

    samples = phase_report["transitions"]
    if not samples:
        return None

    proposed, notes = wcl_phases.propose_phases(samples, phase_report.get("names"))
    if len(proposed) < 2:
        return None
    print("aucun tableau `phases` dans le fichier : %d phase(s) proposee(s) depuis "
          "phaseTransitions, marquees `provisional` — a relire avant de s'en servir."
          % (len(proposed) - 1))
    for note in notes:
        print(note)
    return proposed


def resolve_out(args) -> Path:
    if args.out:
        return Path(args.out)
    return Path("Modules/BossTimer/Data") / args.flavor / args.raid / ("%s.lua" % args.boss)


def main(argv=None) -> int:
    args = parse_args(argv)
    out = resolve_out(args)

    # Relu avant le moindre appel API : un fichier qu'on ne sait pas relire doit
    # arreter le passage tout de suite, pas apres dix requetes et juste avant de
    # l'ecraser.
    existing = None
    if not args.replace:
        try:
            existing = read_existing(out, args.npc_id)
        except lua_table.LuaSyntaxError as exc:
            print("%s est illisible (%s) : corrige-le, ou passe --replace pour "
                  "repartir de zero en acceptant de perdre ce qu'il contient."
                  % (out, exc), file=sys.stderr)
            return 2
        if existing is not None and not isinstance(existing, dict):
            print("%s : ns.BossTimerData[%d] n'est pas une table." % (out, args.npc_id),
                  file=sys.stderr)
            return 2

    try:
        client_id, client_secret = load_credentials()
        token = get_token(client_id, client_secret)
    except WCLError as exc:
        print(exc, file=sys.stderr)
        return 2

    encounter_name = ""
    reports = []
    for item in args.report:
        try:
            reports.append(parse_report_arg(item))
        except WCLError as exc:
            print(exc, file=sys.stderr)
            return 2

    if args.encounter and not reports:
        try:
            encounter_name, reports = discover_reports(token, args.encounter, args.limit, args.partition)
        except WCLError as exc:
            print(exc, file=sys.stderr)
            return 2

    if not reports:
        print("aucun log a analyser : passe --report CODE:FIGHT ou --encounter <id>.", file=sys.stderr)
        return 2

    existing_phases = lua_array(existing.get("phases") or {}) if existing else []

    print(f"analyse de {len(reports)} log(s)...")
    stats, used, phase_report = collect(token, reports, args.npc_id, args.verbose,
                                        existing_phases, args.phases)
    if used == 0:
        print("aucun log exploitable (npcId correct ?).", file=sys.stderr)
        return 1

    rows = summarise(stats, args.min_reports)
    if not rows:
        print("aucun sort retenu : baisse --min-reports.", file=sys.stderr)
        return 1

    proposed = report_phases(phase_report, existing_phases, used, args)

    existing_timers = lua_array(existing.get("timers") or {}) if existing else []
    if existing_timers:
        kept = sum(1 for timer, row in merge_timers(existing_timers, rows) if row is None)
        print("fusion avec %s : %d timer(s) existant(s), %d conserve(s) tel(s) quel(s)."
              % (out, len(existing_timers), kept))

    print(f"{len(rows)} sort(s) retenu(s) sur {used} log(s) :")
    for row in rows:
        flag = " [variable]" if row["variable"] else ""
        if row["phaseGated"]:
            hint = f" {row['phaseHint']} ?" if row["phaseHint"] else ""
            flag = f" [TODO phase{hint}]"
        interval = f", toutes les {row['repeatInterval']}s" if row["repeatInterval"] else ""
        measured = "".join(f", phase {index} +{data['time']}s"
                           for index, data in sorted(row["phases"].items()) if index >= 2)
        print(f"  spell {row['spellId']:>7} : pull +{row['time']}s{interval}{measured}"
              f" ({row['samples']} log(s)){flag}")

    lua = render_lua(args, merge_header(args, existing, proposed),
                     merge_timers(existing_timers, rows), encounter_name, used)
    if args.dry_run:
        print()
        print(lua)
        return 0

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(lua, encoding="utf-8")
    print(f"\necrit : {out}")
    print("Pense a relancer tools/gen-toc.sh pour inscrire le fichier dans les .toc.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
