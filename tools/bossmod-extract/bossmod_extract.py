#!/usr/bin/env python3
"""Releve des timings declares par les boss mods installes en local.

Ce que fait cet outil : il lit les fichiers de DBM et de BigWigs presents dans
ton dossier `Interface/AddOns`, en sort les couples (spellId, duree) declares en
clair dans le code, et les rapproche de ta propre data. Trois modes :

    bossmod_extract.py scan                    # ce que tu as installe
    bossmod_extract.py report                  # ce qu'ils ont et que tu n'as pas
    bossmod_extract.py write [--dry-run]       # remplir les trous de ta data

PROVENANCE. Chaque timer importe porte `source = "<addon>"` et
`provisional = true`, et le fichier recoit un bandeau qui nomme l'origine. Ce
n'est pas decoratif : une valeur sans provenance est inverifiable, et celles-ci
ne viennent pas de tes logs. `wcl-ingest` les remesurera et fera tomber le
`provisional` — c'est la trajectoire prevue, ces entrees sont un point de
depart, pas une arrivee.

LICENCE. DBM (`All Rights Reserved`) et BigWigs (`All Rights Reserved: you are
free to fork and modify on GitHub, please ask us about anything else`) ne
concedent aucun droit de derivation. Ce qui est repris ici, ce sont des durees
constatees sur le jeu de Blizzard — des faits, non protegeables en tant que
tels. La limite se situe ailleurs : une extraction *systematique* touche a la
compilation (droit sui generis des bases de donnees, art. L341-1 CPI en
Europe). C'est pour ca que l'outil ne recopie rien d'autre que des nombres, ne
prend jamais un libelle ecrit par eux, et n'ecrase jamais une valeur que tu as
mesuree toi-meme : il remplit des trous, il ne constitue pas une copie de leur
base. Voir `docs/ROADMAP.md`, phase 3c.

CE QU'IL NE SAIT PAS FAIRE. Un boss mod ne declare pas de delai depuis le pull
(ses timers demarrent sur un evenement), donc rien ici ne produit de timer
`PULL` — sauf l'enrage, qui en est un par nature. Les durees importees sont des
CADENCES, ecrites sur un trigger `CAST` : le sort se declenche a l'observation,
et la prochaine occurrence est predite a cette cadence. C'est exactement le
modele du module, et ca n'invente aucun offset.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "wcl-ingest"))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "wa-extract"))

import lua_table  # noqa: E402
import wcl_ingest as wi  # noqa: E402

FLAVOR_BY_FOLDER = {
    "_classic_era_": "vanilla",
    "_classic_": "wrath",
    "_classic_beta_": "wrath",
    "_retail_": "retail",
    "_ptr_": "retail",
    "_xptr_": "retail",
}

WINDOWS_ROOTS = (
    r"C:\Program Files (x86)\World of Warcraft",
    r"C:\Program Files\World of Warcraft",
    r"C:\World of Warcraft",
    r"D:\World of Warcraft",
)

MAC_ROOTS = ("/Applications/World of Warcraft",)


# ----------------------------------------------------------------------------
# Lecture d'appels Lua
# ----------------------------------------------------------------------------

def call_args(text: str, open_index: int):
    """Arguments d'un appel dont la parenthese ouvrante est a `open_index`.

    Un `split(",")` casse des le premier appel imbrique (`self:Bar(args.spellId,
    self:Mythic() and 20 or 25)`), qui est la forme normale dans un boss mod
    moderne. On compte donc les parentheses, et on ignore les virgules qui sont
    dans une chaine.
    """
    depth, arg, out = 0, [], []
    quote = None
    index = open_index
    while index < len(text):
        char = text[index]
        if quote:
            arg.append(char)
            if char == quote and text[index - 1] != "\\":
                quote = None
        elif char in "\"'":
            quote = char
            arg.append(char)
        elif char in "([{":
            depth += 1
            if depth > 1:
                arg.append(char)
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                out.append("".join(arg).strip())
                return [a for a in out if a != ""], index
            arg.append(char)
        elif char == "," and depth == 1:
            out.append("".join(arg).strip())
            arg = []
        else:
            arg.append(char)
        index += 1
    return [], len(text)


NUMBER = re.compile(r"^-?\d+(?:\.\d+)?$")
RANGE = re.compile(r"^[\"']?[a-z]?(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)[\"']?$")


def as_duration(arg: str):
    """(secondes, variable) depuis un argument de duree, ou (None, False).

    Trois formes dans la nature : un nombre, une fourchette `"20-30"` — qui dit
    exactement ce que le module appelle `variable` — et un nombre negatif, qui
    chez DBM veut dire « prends le temps d'incantation du sort ». Ce dernier
    n'est pas une cadence : on l'ecarte plutot que de le prendre pour tel.
    """
    if arg is None:
        return None, False
    arg = arg.strip()
    match = RANGE.match(arg)
    if match:
        return float(match.group(1)), True
    if NUMBER.match(arg):
        value = float(arg)
        if value <= 0:
            return None, False
        return value, False
    return None, False


def as_spell(arg: str):
    """spellId depuis un argument, ou None (cle textuelle, variable, nil...)."""
    if arg is None:
        return None
    arg = arg.strip()
    if NUMBER.match(arg):
        value = int(float(arg))
        # Une cle negative est une entree d'interface chez BigWigs (section du
        # menu d'options), pas un sort.
        return value if value > 0 else None
    return None


# ----------------------------------------------------------------------------
# Modeles
# ----------------------------------------------------------------------------

class Timer:
    def __init__(self, spell_id, seconds, kind, variable=False, starts=None):
        self.spell_id = spell_id
        self.seconds = seconds
        self.kind = kind            # next | cd | cast | berserk | phase | buff
        self.variable = variable
        self.starts = starts or []  # valeurs vues dans les :Start(...) du mod

    def __repr__(self):
        return "Timer(%s, %s, %s)" % (self.spell_id, self.seconds, self.kind)


class Mod:
    def __init__(self, source, addon, path):
        self.source = source        # "DBM" | "BigWigs"
        self.addon = addon
        self.path = path
        self.npc_ids = []
        self.encounter_id = None
        self.instance_id = None
        self.timers = []

    @property
    def label(self):
        return "%s/%s" % (self.addon, self.path.name)

    def cadences(self):
        """Un timer par spellId : la cadence la plus courte l'emporte.

        Un meme sort porte souvent plusieurs timers dans un boss mod (un par
        difficulte, un par phase). Retenir la plus courte evite d'annoncer trop
        tard ; c'est de toute facon une valeur de depart, destinee a etre
        remesuree.
        """
        best = {}
        for timer in self.timers:
            if timer.spell_id is None or timer.seconds is None:
                continue
            if timer.kind in ("cast", "buff"):
                # Duree d'incantation ou d'un buff : ce n'est pas une cadence.
                continue
            current = best.get(timer.spell_id)
            if current is None or timer.seconds < current.seconds:
                best[timer.spell_id] = timer
        return best

    def berserk(self):
        for timer in self.timers:
            if timer.kind == "berserk" and timer.seconds:
                return timer
        return None


# ----------------------------------------------------------------------------
# DBM
# ----------------------------------------------------------------------------

DBM_TIMER = re.compile(r"(?:local\s+(\w+)\s*=\s*)?\w+:New(\w*?)Timer\s*\(")
DBM_CREATURE = re.compile(r":SetCreatureID\s*\(")
DBM_ENCOUNTER = re.compile(r":SetEncounterID\s*\(")
DBM_NEWMOD = re.compile(r"DBM:NewMod\s*\(")
DBM_START = re.compile(r"\b(\w+):Start\s*\(\s*([-\d.]+)\s*\)")

DBM_KINDS = {
    "": "next", "Next": "next", "CD": "cd", "CDCount": "cd", "NextCount": "next",
    "CDSpecial": "cd", "Cast": "cast", "CastCount": "cast", "Berserk": "berserk",
    "Phase": "phase", "BuffActive": "buff", "Target": "buff", "Adds": "next",
    "AI": "cd", "Achievement": None, "Combo": "next", "RP": None,
}


def parse_dbm(path: Path, text: str) -> Mod:
    mod = Mod("DBM", path.parent.name, path)

    match = DBM_NEWMOD.search(text)
    if match:
        args, _ = call_args(text, match.end() - 1)
        if len(args) >= 4 and NUMBER.match(args[3]):
            mod.instance_id = int(float(args[3]))

    for match in DBM_CREATURE.finditer(text):
        args, _ = call_args(text, match.end() - 1)
        for arg in args:
            npc = as_spell(arg)
            if npc and npc not in mod.npc_ids:
                mod.npc_ids.append(npc)

    match = DBM_ENCOUNTER.search(text)
    if match:
        args, _ = call_args(text, match.end() - 1)
        if args:
            mod.encounter_id = as_spell(args[0])

    # Les valeurs passees a :Start() sont ce que le mod affiche vraiment, la ou
    # l'argument du constructeur n'est que la valeur par defaut. On les releve
    # pour les montrer, sans les substituer : choisir entre elles demanderait de
    # savoir dans quelle phase on est, ce qu'un parsing statique ne dit pas.
    starts = {}
    for match in DBM_START.finditer(text):
        value, _ = as_duration(match.group(2))
        if value:
            starts.setdefault(match.group(1), []).append(value)

    for match in DBM_TIMER.finditer(text):
        var, raw_kind = match.group(1), match.group(2)
        kind = DBM_KINDS.get(raw_kind, "next")
        if kind is None:
            continue
        args, _ = call_args(text, match.end() - 1)
        if not args:
            continue
        seconds, variable = as_duration(args[0])
        spell = as_spell(args[1]) if len(args) > 1 else None
        if kind == "berserk":
            spell = None
        elif spell is None:
            continue
        if seconds is None:
            continue
        mod.timers.append(Timer(spell, seconds, kind, variable, starts.get(var, [])))

    return mod


# ----------------------------------------------------------------------------
# BigWigs
# ----------------------------------------------------------------------------
# Les durees ne sont pas au top-level (c'est ce qui fait echouer l'approche
# shim + dofile), mais elles sont ecrites en clair dans les handlers. Le seul
# travail en plus : `args.spellId` doit etre resolu, et il l'est — `self:Log`
# dit quel sort declenche quel handler.

BW_ENGAGE = re.compile(r"\bmod\.engageId\s*=\s*(\d+)")
BW_MOBS = re.compile(r":RegisterEnableMob\s*\(")
BW_LOG = re.compile(r"self:Log\s*\(")
BW_FUNC = re.compile(r"function\s+mod:(\w+)\s*\(")
BW_BAR = re.compile(r"self:(CDBar|Bar|CastBar|Berserk)\s*\(")

BW_KINDS = {"Bar": "next", "CDBar": "cd", "CastBar": "cast", "Berserk": "berserk"}


def parse_bigwigs(path: Path, text: str) -> Mod:
    mod = Mod("BigWigs", path.parent.name, path)

    match = BW_ENGAGE.search(text)
    if match:
        mod.encounter_id = int(match.group(1))

    for match in BW_MOBS.finditer(text):
        args, _ = call_args(text, match.end() - 1)
        for arg in args:
            npc = as_spell(arg)
            if npc and npc not in mod.npc_ids:
                mod.npc_ids.append(npc)

    # handler -> spellIds, pour resoudre `args.spellId`.
    handlers = {}
    for match in BW_LOG.finditer(text):
        args, _ = call_args(text, match.end() - 1)
        if len(args) < 2:
            continue
        name = args[1].strip("\"'")
        for arg in args[2:]:
            spell = as_spell(arg)
            if spell:
                handlers.setdefault(name, []).append(spell)

    # Position de depart de chaque fonction, pour savoir dans quel handler tombe
    # un appel a self:Bar.
    bounds = [(m.start(), m.group(1)) for m in BW_FUNC.finditer(text)]

    def handler_at(index):
        current = None
        for start, name in bounds:
            if start > index:
                break
            current = name
        return current

    for match in BW_BAR.finditer(text):
        kind = BW_KINDS[match.group(1)]
        args, _ = call_args(text, match.end() - 1)
        if not args:
            continue
        if kind == "berserk":
            seconds, variable = as_duration(args[0])
            if seconds:
                mod.timers.append(Timer(None, seconds, "berserk", variable))
            continue
        if len(args) < 2:
            continue
        seconds, variable = as_duration(args[1])
        if seconds is None:
            continue
        spell = as_spell(args[0])
        if spell is None and "spellId" in args[0]:
            for candidate in handlers.get(handler_at(match.start()) or "", []):
                mod.timers.append(Timer(candidate, seconds, kind, variable))
            continue
        if spell is None:
            continue
        mod.timers.append(Timer(spell, seconds, kind, variable))

    return mod


# ----------------------------------------------------------------------------
# Decouverte
# ----------------------------------------------------------------------------

def find_addons_dir(explicit=None):
    if explicit:
        path = Path(explicit)
        if not path.is_dir():
            raise SystemExit("dossier introuvable : %s" % path)
        return path
    candidates = []
    for root in WINDOWS_ROOTS + MAC_ROOTS:
        for folder in FLAVOR_BY_FOLDER:
            candidates.append(Path(root) / folder / "Interface" / "AddOns")
    env = os.environ.get("WOW_ADDONS")
    if env:
        candidates.insert(0, Path(env))
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    raise SystemExit(
        "dossier AddOns introuvable. Passe --addons "
        "\"C:\\Program Files (x86)\\World of Warcraft\\_classic_era_\\Interface\\AddOns\" "
        "(ou pose WOW_ADDONS dans l'environnement)."
    )


def flavor_for(addons_dir: Path, explicit=None):
    if explicit:
        return explicit
    for part in addons_dir.parts:
        if part in FLAVOR_BY_FOLDER:
            return FLAVOR_BY_FOLDER[part]
    return None


def scan_mods(addons_dir: Path):
    """Tous les modules de boss lisibles sous `addons_dir`."""
    mods = []
    for folder in sorted(p for p in addons_dir.iterdir() if p.is_dir()):
        name = folder.name
        is_dbm = name.startswith("DBM-")
        is_bw = name.startswith("BigWigs")
        if not (is_dbm or is_bw):
            continue
        for path in sorted(folder.rglob("*.lua")):
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            mod = parse_dbm(path, text) if is_dbm else parse_bigwigs(path, text)
            if mod.timers and (mod.npc_ids or mod.encounter_id):
                mods.append(mod)
    return mods


# ----------------------------------------------------------------------------
# Data MyBossSuite
# ----------------------------------------------------------------------------

DATA_KEY = re.compile(r"ns\.BossTimerData\[(\d+)\]")


def scan_data(data_dir: Path, flavor=None):
    """[(path, npcId, def), ...] pour les fichiers de data existants."""
    out = []
    roots = [data_dir / flavor] if flavor else [data_dir]
    for root in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.lua")):
            text = path.read_text(encoding="utf-8", errors="replace")
            match = DATA_KEY.search(text)
            if not match:
                continue
            npc_id = int(match.group(1))
            try:
                existing = wi.read_existing(path, npc_id)
            except lua_table.LuaSyntaxError as exc:
                print("  !! %s illisible (%s) : ignore" % (path, exc), file=sys.stderr)
                continue
            if isinstance(existing, dict):
                out.append((path, npc_id, existing))
    return out


def match_mod(mod: Mod, data):
    """Le fichier de data qui decrit la meme rencontre, ou None.

    Deux cles possibles, dans cet ordre : le npcId (ce que la data indexe) puis
    l'encounterId (ce que le client livre sur ENCOUNTER_START). L'une des deux
    suffit ; se tromper de rencontre ecrirait des timings justes dans le mauvais
    fichier, ce qui est pire que de ne rien ecrire.
    """
    for path, npc_id, existing in data:
        npcs = {npc_id}
        for extra in wi.lua_array(existing.get("npcIds") or {}):
            if isinstance(extra, (int, float)):
                npcs.add(int(extra))
        if npcs & set(mod.npc_ids):
            return path, npc_id, existing
    if mod.encounter_id:
        for path, npc_id, existing in data:
            if existing.get("encounterId") == mod.encounter_id:
                return path, npc_id, existing
    return None


def existing_by_spell(existing: dict):
    out = {}
    for timer in wi.lua_array(existing.get("timers") or {}):
        spell = timer.get("spellId")
        if spell is not None:
            out.setdefault(int(spell), []).append(timer)
    return out


def compare(mod: Mod, existing: dict):
    """(manquants, divergents, couverts) entre un boss mod et un fichier."""
    mine = existing_by_spell(existing)
    missing, diverging, covered = [], [], []
    for spell, timer in sorted(mod.cadences().items()):
        rows = mine.get(spell)
        if not rows:
            missing.append((spell, timer))
            continue
        # Une fenetre ecrite a la main dit « ce sort n'a pas de cadence ». Un
        # boss mod en donnera toujours une : c'est justement ce qu'on refuse.
        if any(row.get("pendingWindow") for row in rows):
            covered.append((spell, timer, None))
            continue
        known = [row.get("repeatInterval") for row in rows if row.get("repeatInterval")]
        if not known:
            missing.append((spell, timer))
        elif all(abs(float(value) - timer.seconds) > 1.5 for value in known):
            diverging.append((spell, timer, known[0]))
        else:
            covered.append((spell, timer, known[0]))
    return missing, diverging, covered


# ----------------------------------------------------------------------------
# Ecriture
# ----------------------------------------------------------------------------

def imported_timer(spell: int, timer: Timer, source: str):
    """Un timer neuf, honnete sur ce qu'il est.

    `CAST` et pas `PULL` : un boss mod ne connait pas de delai depuis le pull,
    ses barres partent sur un evenement. Ce qu'on tient est une cadence, et un
    trigger `CAST` la joue exactement — declenchement a l'observation, prochaine
    occurrence predite. Aucun offset invente.
    """
    out = {
        "trigger": "CAST",
        "spellId": spell,
        "repeatInterval": round(timer.seconds, 1),
        "bar": True,
    }
    if timer.variable:
        out["variable"] = True
    out["source"] = source
    out["provisional"] = True
    return out


def fill_timers(existing: dict, mod: Mod, source: str):
    """Retourne (timers, notes, added, filled).

    Regle unique, et elle ne bouge pas : on remplit des trous. Une valeur deja
    presente — mesuree par toi, ou ecrite a la main — n'est jamais remplacee.
    Sinon le premier passage de cet outil effacerait ce que `wcl-ingest` a
    mesure sur tes propres logs, ce qui serait exactement l'inverse du but.
    """
    timers = [dict(t) for t in wi.lua_array(existing.get("timers") or {})]
    notes, added, filled = {}, 0, 0
    by_spell = {}
    for index, timer in enumerate(timers):
        spell = timer.get("spellId")
        if spell is not None:
            by_spell.setdefault(int(spell), []).append(index)

    # L'enrage est le seul timer d'un boss mod qui compte vraiment depuis le
    # pull : c'est une duree de combat, pas une cadence. Il s'ecrit donc en
    # `PULL`, et seulement si la data n'en connait pas deja un.
    berserk = mod.berserk()
    if berserk and not any(re.search(r"enrage|berserk|frenzy", str(t.get("name") or ""),
                                     re.I) for t in timers):
        timers.append({
            "trigger": "PULL", "time": round(berserk.seconds, 1),
            "name": "Enrage", "warnBefore": 10, "bar": True,
            "source": source, "provisional": True,
        })
        notes[len(timers) - 1] = [
            "        -- enrage releve dans %s : une duree de combat, pas une cadence"
            % source
        ]
        added += 1

    for spell, timer in sorted(mod.cadences().items()):
        indexes = by_spell.get(spell)
        if indexes:
            for index in indexes:
                row = timers[index]
                if row.get("pendingWindow") or row.get("repeatInterval"):
                    continue
                row["repeatInterval"] = round(timer.seconds, 1)
                if timer.variable:
                    row["variable"] = True
                row["source"] = source
                notes.setdefault(index, []).append(
                    "        -- cadence de %s (%s) : trou rempli, a remesurer"
                    % (source, timer.kind))
                filled += 1
        else:
            timers.append(imported_timer(spell, timer, source))
            index = len(timers) - 1
            starts = (" — :Start vus a %s"
                      % ", ".join("%gs" % v for v in sorted(set(timer.starts)))
                      ) if timer.starts else ""
            notes[index] = [
                "        -- releve dans %s (%s%s), jamais mesure ici"
                % (source, timer.kind, starts)
            ]
            added += 1

    return timers, notes, added, filled


BANNER = [
    "-- %s — flavor %s (npcId %d)",
    "--",
    "-- Timings de depart releves dans les boss mods installes en local, fusionnes",
    "-- par tools/bossmod-extract/bossmod_extract.py. Chaque entree concernee porte",
    "-- `source` et reste `provisional` : ces durees ne viennent pas de tes logs.",
    "-- `wcl-ingest` les remesurera et fera tomber le `provisional` — c'est la",
    "-- trajectoire prevue, ces valeurs sont un point de depart.",
    "--",
    "-- L'outil ne remplit que des trous : une valeur deja mesuree, un libelle, une",
    "-- annonce, une fenetre `pendingWindow` ne sont jamais remplaces.",
]


def write_file(path: Path, npc_id: int, existing: dict, timers, notes, flavor, boss):
    header = {key: value for key, value in existing.items() if key != "timers"}
    args = argparse.Namespace(boss=boss, flavor=flavor, npc_id=npc_id)
    banner = [BANNER[0] % (boss, flavor, npc_id)] + BANNER[1:]
    return wi.render_lua(args, header, [(timer, None) for timer in timers],
                         banner=banner, notes=notes)


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def cmd_scan(mods, _args):
    if not mods:
        print("aucun module de boss trouve.")
        return 0
    print("%d module(s) de boss lisible(s) :\n" % len(mods))
    for mod in mods:
        cadences = mod.cadences()
        print("  %-11s %-34s npcIds %-22s encounter %-6s %d cadence(s)"
              % (mod.source, mod.label,
                 ", ".join(str(n) for n in mod.npc_ids) or "-",
                 mod.encounter_id or "-", len(cadences)))
    return 0


def cmd_report(mods, args, data, flavor):
    matched = 0
    for mod in mods:
        found = match_mod(mod, data)
        if found and args.npc_id and found[1] != args.npc_id:
            continue
        if not found:
            print("\n== %s — aucun fichier de data (npcIds %s, encounter %s)"
                  % (mod.label,
                     ", ".join(str(n) for n in mod.npc_ids) or "-",
                     mod.encounter_id or "-"))
            print("   %d cadence(s) relevee(s) : cree le fichier, puis relance"
                  % len(mod.cadences()))
            continue
        matched += 1
        path, npc_id, existing = found
        missing, diverging, covered = compare(mod, existing)
        print("\n== %s (npcId %d) — %s" % (existing.get("name", "?"), npc_id, path))
        print("   source %s" % mod.label)
        for spell, timer in missing:
            print("   manquant : spell %-7d cadence %gs (%s)%s"
                  % (spell, timer.seconds, timer.kind,
                     " [variable]" if timer.variable else ""))
        for spell, timer, mine in diverging:
            print("   diverge  : spell %-7d toi %gs / %s %gs"
                  % (spell, float(mine), mod.source, timer.seconds))
        if covered:
            print("   couvert  : %d timer(s) deja en place" % len(covered))
        if not (missing or diverging or covered):
            print("   rien de commun : verifie que c'est bien la meme rencontre")
    if not matched:
        print("\naucune rencontre appariee avec ta data.")
    return 0


def group_by_file(mods, data, only_npc=None):
    """path -> (npcId, def, [mods]).

    Un fichier de data recoit souvent DEUX sources — tu as DBM *et* BigWigs
    installes, et DBM eclate parfois un raid en plusieurs fichiers. Les traiter
    un par un ferait ecrire le meme fichier deux fois, le second passage
    repartant de la version d'avant : les ajouts du premier disparaitraient.
    On regroupe donc par fichier, et on fusionne tout avant d'ecrire une fois.
    """
    groups = {}
    for mod in mods:
        found = match_mod(mod, data)
        if not found:
            continue
        path, npc_id, existing = found
        if only_npc and npc_id != only_npc:
            continue
        groups.setdefault(path, (npc_id, existing, []))[2].append(mod)
    return groups


def cmd_write(mods, args, data, flavor):
    if not flavor:
        raise SystemExit("flavor indeterminable : passe --flavor")
    groups = group_by_file(mods, data, args.npc_id)
    touched = 0
    for path, (npc_id, existing, here) in sorted(groups.items()):
        timers = [dict(t) for t in wi.lua_array(existing.get("timers") or {})]
        notes, added, filled, sources = {}, 0, 0, []
        for mod in here:
            state = dict(existing)
            state["timers"] = {i + 1: t for i, t in enumerate(timers)}
            timers, mod_notes, mod_added, mod_filled = fill_timers(state, mod, mod.addon)
            for index, lines in mod_notes.items():
                notes.setdefault(index, []).extend(lines)
            added, filled = added + mod_added, filled + mod_filled
            if mod_added or mod_filled:
                sources.append(mod.label)
        if not (added or filled):
            continue
        boss = existing.get("name") or path.stem
        text = write_file(path, npc_id, existing, timers, notes, flavor, boss)
        print("%s : %d ajout(s), %d trou(s) rempli(s) depuis %s"
              % (path, added, filled, ", ".join(sources)))
        if args.dry_run:
            if args.verbose:
                print(text)
        else:
            path.write_text(text, encoding="utf-8")
        touched += 1
    if not touched:
        print("rien a ecrire : tout ce que ces boss mods declarent est deja couvert.")
    elif args.dry_run:
        print("\n--dry-run : aucun fichier ecrit.")
    return 0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["scan", "report", "write"])
    parser.add_argument("--addons", help="dossier Interface/AddOns (autodetecte sinon)")
    parser.add_argument("--data", default="Modules/BossTimer/Data",
                        help="racine de la data MyBossSuite")
    parser.add_argument("--flavor", choices=sorted(set(FLAVOR_BY_FOLDER.values())) +
                        ["tbc", "cata", "mists"],
                        help="flavor cible (deduit du chemin AddOns sinon)")
    parser.add_argument("--npc-id", type=int, help="ne traiter que cette rencontre")
    parser.add_argument("--dry-run", action="store_true",
                        help="affiche ce qui serait ecrit, sans ecrire")
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    addons = find_addons_dir(args.addons)
    flavor = flavor_for(addons, args.flavor)
    mods = scan_mods(addons)

    if args.mode == "scan":
        if args.npc_id:
            mods = [m for m in mods if args.npc_id in m.npc_ids]
        return cmd_scan(mods, args)

    data = scan_data(Path(args.data), flavor)
    if not data:
        raise SystemExit("aucun fichier de data lu sous %s (flavor %s)"
                         % (args.data, flavor or "?"))
    if args.mode == "report":
        return cmd_report(mods, args, data, flavor)
    return cmd_write(mods, args, data, flavor)


if __name__ == "__main__":
    sys.exit(main())
