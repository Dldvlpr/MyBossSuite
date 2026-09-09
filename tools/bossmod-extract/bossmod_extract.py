#!/usr/bin/env python3
"""Extraction des timings de boss depuis les boss mods installes localement.

    tools/bossmod-extract/bossmod_extract.py --flavor vanilla --install "C:/World of Warcraft/_classic_era_"

Ce que ca fait : lire les modules DBM et BigWigs **de ton propre client**, en
tirer les timings, et ecrire un addon compagnon
`Interface/AddOns/MyBossSuite_BossModData/` que MyBossSuite chargera comme une
source de data supplementaire.

Ce que ca ne fait pas, et c'est deliberé : **rien n'est ecrit dans le depot**.
La sortie va dans ton dossier AddOns, jamais dans `Modules/BossTimer/Data/`.
MyBossSuite est publie sous GPL sur un depot public ; DBM et BigWigs sont *All
Rights Reserved*. Une data derivee d'eux qui partirait en `git push` cesserait
d'etre un usage local — l'ecrire ailleurs qu'a cote du client rendrait cet
accident possible, donc l'outil ne le propose pas. `--out` reste la si tu veux
inspecter la sortie, et refuse un chemin situe dans le depot.

Preseance a l'execution, du plus sur au moins sur :

    data du depot (mesuree)  >  data extraite (ce fichier)  >  pont DBM/BigWigs live

Chaque entree generee porte `provisional = true` et sa source. Ce sont les
chiffres de DBM ou de BigWigs, pas des mesures : `tools/wcl-ingest` reste ce qui
produit de la data mesuree.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bw_source
import dbm_source

ADDON_NAME = "MyBossSuite_BossModData"
GLOBAL_TABLE = "MyBossSuiteBossModData"

# Meme table que tools/gen-toc.sh, qui fait foi. Un numero depasse rend l'addon
# "obsolete", donc desactive tant que la case n'est pas cochee.
INTERFACE = {
    "vanilla": "11509",
    "tbc": "20506",
    "wrath": "30405, 38002",
    "cata": "40402",
    "mists": "50504",
    "retail": "120100",
}
FLAVORS = tuple(INTERFACE)

# Le nom du dossier ne suffit PAS a decider du flavor, et s'y fier produit
# silencieusement la mauvaise data. `_classic_` est le client de progression :
# il a ete Vanilla, puis TBC, Wrath, Cata, et vaut Mists aujourd'hui. Seule la
# version du client tranche. `.build.info`, a la racine de l'installation,
# porte une ligne par produit avec sa version : c'est la source, et le nom du
# dossier ne sert plus qu'a savoir quelle ligne lire.
PRODUCT_FROM_FOLDER = {
    "_retail_": "wow",
    "_ptr_": "wow",
    "_classic_era_": "wow_classic_era",
    "_classic_era_ptr_": "wow_classic_era",
    "_anniversary_": "wow_anniversary",
    "_classic_": "wow_classic",
    "_classic_ptr_": "wow_classic",
}

# Numero majeur du client -> flavor. Retail est hors table : il est reconnu a
# son produit, pas a son numero, qui continue de monter.
FLAVOR_FROM_MAJOR = {1: "vanilla", 2: "tbc", 3: "wrath", 4: "cata", 5: "mists"}

# `kind` deduit du pack dont vient le module. Un world boss n'a pas la meme
# detection de fin de combat qu'un boss de raid : se tromper la se voit en jeu.
_DUNGEON = re.compile(r"(DBM-Party|DBM-Challenges|_Party|Dungeon)", re.I)
_WORLD = re.compile(r"(WorldEvents|DBM-Azeroth|World_|Outdoor|WorldBoss)", re.I)

_SKIP_DIRS = re.compile(
    r"(DBM-Core|DBM-GUI|DBM-Test|DBM-VPVEM|DBM-CountPack|DBM-StatusBarTimers"
    r"|BigWigs_Options|BigWigs_Plugins|BigWigs_Core|Locale|!Locales)", re.I
)
_SKIP_FILES = re.compile(r"(localization|locales?)\.", re.I)


def content_kind(path: str) -> str:
    if _WORLD.search(path):
        return "world"
    if _DUNGEON.search(path):
        return "dungeon"
    return "raid"


# Suffixe de `.toc` par flavor — meme convention que nos six fichiers, et que
# ceux de DBM et BigWigs.
TOC_SUFFIX = {
    "vanilla": "_Vanilla", "tbc": "_TBC", "wrath": "_Wrath",
    "cata": "_Cata", "mists": "_Mists", "retail": "_Mainline",
}

_TOC_COMMENT = re.compile(r"^\s*(#|$)")


def toc_for(folder: pathlib.Path, flavor: str):
    """Le `.toc` que ce client chargerait pour cet addon, ou None.

    C'est le filtre qui compte. DBM installe les packs de TOUTES les extensions
    dans chaque client : sur Classic Era, `DBM-Party-Shadowlands` est present et
    ne se charge jamais — il n'a qu'un `_Mainline.toc`. Marcher recursivement
    dans les dossiers verserait donc des centaines de rencontres mortes dans la
    data. Le `.toc` par flavor dit exactement ce qui vit sur ce client, et il
    dit aussi dans quel ORDRE : c'est la reponse, pas une heuristique."""
    suffixed = folder / ("%s%s.toc" % (folder.name, TOC_SUFFIX[flavor]))
    if suffixed.is_file():
        return suffixed
    # Un addon qui n'a qu'un `.toc` nu ne cible qu'un client : le nom suffixe
    # est la convention multi-version, son absence veut dire « retail seul ».
    plain = folder / ("%s.toc" % folder.name)
    if flavor == "retail" and plain.is_file():
        return plain
    return None


def toc_lua_files(toc: pathlib.Path):
    """Les `.lua` listes par un `.toc`, dans l'ordre, chemins normalises."""
    try:
        lines = toc.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        if _TOC_COMMENT.match(line):
            continue
        entry = line.strip().replace("\\", "/")
        if entry.lower().endswith(".lua"):
            out.append(entry)
    return out


def iter_module_files(addons: pathlib.Path, flavor: str):
    """Les fichiers Lua qui se chargent vraiment sur ce client, addon par addon."""
    for folder in sorted(addons.iterdir()):
        if not folder.is_dir() or _SKIP_DIRS.search(folder.name):
            continue
        if not (folder.name.lower().startswith("dbm")
                or folder.name.lower().startswith("bigwigs")):
            continue
        toc = toc_for(folder, flavor)
        if toc is None:
            continue
        for entry in toc_lua_files(toc):
            if _SKIP_FILES.search(os.path.basename(entry)):
                continue
            path = folder / entry
            if path.is_file():
                yield path


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def zone_of(path: pathlib.Path, addons: pathlib.Path) -> str:
    """Le dossier du module fait office de zone : c'est ce que le boss mod a
    juge etre une unite de contenu, et c'est traçable."""
    try:
        parts = path.relative_to(addons).parts
    except ValueError:
        parts = path.parts
    if len(parts) >= 3:
        return parts[-2]
    return parts[0] if parts else "Inconnu"


# ------------------------------------------------------------------------------


def timer_key(timer: dict):
    return (timer.get("trigger"), timer.get("spell_id"))


# `PULL`, `PHASE` et `CAST` finissent tous dans la meme table de recherche du
# moteur (`castTriggers`, indexee par spellId) : un spellId sur un timer `PULL`
# sert deja de resynchronisation sur le cast observe. Deux entrees pour le meme
# sort y donnent donc deux barres concurrentes. `AURA` a sa propre table et
# reste distinct : une aura posee n'est pas un cast.
_CAST_FAMILY = ("PULL", "PHASE", "CAST")
_TRIGGER_RANK = {"PULL": 0, "PHASE": 1, "CAST": 2}


def dedupe_timers(entry: dict) -> dict:
    """Une seule entree par (famille, sortId).

    DBM et BigWigs declarent naturellement le meme sort deux fois : une fois au
    pull (`OnCombatStart` / `OnEngage`), une fois sur son propre cast. Chez eux
    c'est le MEME objet timer redemarre ; transcrit tel quel, ca devient deux
    timers distincts pour MyBossSuite, donc deux barres qui se contredisent.

    On garde l'entree la plus informative — `PULL` d'abord, parce que seule elle
    porte un `time` depuis le pull — et on lui verse la cadence de l'autre. La
    cadence prise sur un cast observe prime sur celle d'une declaration : c'est
    ce que `repeatInterval` veut dire ici, et l'ecart eventuel est conserve en
    commentaire plutot qu'arbitre en silence."""
    families = {}
    order = []
    for timer in entry.get("timers", []):
        trigger = timer.get("trigger")
        family = "cast" if trigger in _CAST_FAMILY else trigger
        key = (family, timer.get("spell_id"))
        if key not in families:
            families[key] = timer
            order.append(key)
            continue

        kept = families[key]
        if _TRIGGER_RANK.get(trigger, 9) < _TRIGGER_RANK.get(kept.get("trigger"), 9):
            kept, timer = timer, kept
            families[key] = kept

        # `timer` est desormais celui qu'on absorbe.
        for field in ("time", "test_time"):
            if kept.get(field) is None and timer.get(field) is not None:
                kept[field] = timer[field]

        mine, theirs = kept.get("repeat_interval"), timer.get("repeat_interval")
        if theirs is not None:
            if mine is None:
                kept["repeat_interval"] = theirs
            elif abs(mine - theirs) > 0.5:
                # La cadence armee sur un cast observe decrit mieux le combat
                # qu'une valeur de declaration : elle passe devant, l'autre est
                # notee.
                if timer.get("trigger") == "CAST" and kept.get("trigger") != "CAST":
                    kept["repeat_interval"] = theirs
                    kept.setdefault("disagreement", {})["repeat_interval"] = (
                        "pull", mine)
                else:
                    kept.setdefault("disagreement", {})["repeat_interval"] = (
                        "cast", theirs)

        if timer.get("variable"):
            kept["variable"] = True
        if timer.get("cast_start"):
            kept["cast_start"] = True
        if not kept.get("name"):
            kept["name"] = timer.get("name")
        for field in ("from", "disagreement"):
            if kept.get(field) is None and timer.get(field) is not None:
                kept[field] = timer[field]

    entry["timers"] = [families[key] for key in order]
    return entry


def merge_boss(primary: dict, other: dict) -> dict:
    """Fusionne deux lectures du meme boss (DBM et BigWigs).

    `primary` gagne sur les valeurs ; `other` comble les trous et laisse une
    trace quand les deux ne disent pas la meme chose. Les deux sources sont des
    estimations tierces, aucune n'est une mesure : cacher leur desaccord serait
    choisir a la place du lecteur."""
    merged = dict(primary)
    merged["sources"] = sorted(set(primary.get("sources", [primary["source"]]))
                               | set(other.get("sources", [other["source"]])))

    for key in ("npc_ids", "encounter_ids", "instance_ids"):
        for value in other.get(key, []):
            if value not in merged.get(key, []):
                merged.setdefault(key, []).append(value)

    if not merged.get("name") or merged["source"] == "dbm":
        merged["name"] = other.get("name") or merged.get("name")

    # Les phases n'existent que chez BigWigs (declencheur lisible hors ligne).
    if not merged.get("phases") and other.get("phases"):
        merged["phases"] = other["phases"]

    known = {timer_key(t): t for t in merged.get("timers", [])}
    for timer in other.get("timers", []):
        key = timer_key(timer)
        existing = known.get(key)
        if existing is None:
            timer = dict(timer)
            timer["from"] = other["source"]
            merged.setdefault("timers", []).append(timer)
            known[key] = timer
            continue
        for field in ("time", "repeat_interval", "test_time"):
            mine, theirs = existing.get(field), timer.get(field)
            if theirs is None:
                continue
            if mine is None:
                existing[field] = theirs
            elif abs(mine - theirs) > 0.5:
                existing.setdefault("disagreement", {})[field] = (other["source"], theirs)
        # `variable` se propage dans le sens prudent : si une des deux sources
        # dit que la cadence n'est pas deterministe, la barre le dit aussi.
        if timer.get("variable"):
            existing["variable"] = True
        if not existing.get("name"):
            existing["name"] = timer.get("name")

    merged["files"] = sorted(
        (set(primary.get("files") or []) | set(other.get("files") or [])) - {None})
    merged["rejected"] = primary.get("rejected", 0) + other.get("rejected", 0)
    return merged


def collect(addons: pathlib.Path, flavor: str, only_zone=None):
    """{npcId principal: entree fusionnee}, plus les statistiques du passage."""
    bosses, stats = {}, {"fichiers": 0, "modules": 0, "rejets": 0}

    for path in iter_module_files(addons, flavor):
        stats["fichiers"] += 1
        try:
            text = read(path)
        except OSError:
            continue

        entry = None
        if "DBM:NewMod" in text:
            entry = dbm_source.extract(text)
        elif "BigWigs:NewBoss" in text:
            entry = bw_source.extract(text)
        if not entry or not entry.get("timers"):
            continue

        zone = zone_of(path, addons)
        if only_zone and only_zone.lower() not in zone.lower():
            continue

        entry["zone"] = zone
        entry["kind"] = content_kind(str(path))
        entry["file"] = str(path)
        entry["files"] = [str(path)]
        entry["sources"] = [entry["source"]]
        stats["modules"] += 1
        stats["rejets"] += entry.get("rejected", 0)

        npc_id = entry["npc_ids"][0]
        existing = bosses.get(npc_id)
        if existing is None:
            bosses[npc_id] = entry
        else:
            # BigWigs porte les phases et un nom lisible : il mene la fusion.
            if entry["source"] == "bigwigs":
                bosses[npc_id] = merge_boss(entry, existing)
            else:
                bosses[npc_id] = merge_boss(existing, entry)

    for npc_id in bosses:
        dedupe_timers(bosses[npc_id])

    return bosses, stats


# ------------------------------------------------------------------------------


def lua_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("\n", "\\n").replace("\r", "")
    return '"%s"' % escaped


def lua_number(value) -> str:
    if value is None:
        return "nil"
    if float(value) == int(value):
        return str(int(value))
    return ("%.1f" % value).rstrip("0").rstrip(".")


def render_timer(timer: dict, indent: str) -> str:
    lines = []
    trigger = timer.get("trigger", "CAST")
    lines.append('%s    trigger        = "%s",' % (indent, trigger))
    if timer.get("time") is not None:
        lines.append("%s    time           = %s," % (indent, lua_number(timer["time"])))
    if timer.get("spell_id"):
        lines.append("%s    spellId        = %d," % (indent, timer["spell_id"]))
    if timer.get("name"):
        lines.append("%s    name           = %s," % (indent, lua_string(timer["name"])))
    if timer.get("cast_start") and trigger == "CAST":
        lines.append("%s    castStart      = true," % indent)
    if timer.get("repeat_interval") is not None:
        lines.append("%s    repeatInterval = %s," % (indent, lua_number(timer["repeat_interval"])))
    if timer.get("test_time") is not None:
        lines.append("%s    testTime       = %s," % (indent, lua_number(timer["test_time"])))
    if timer.get("variable"):
        lines.append("%s    variable       = true," % indent)
    lines.append("%s    provisional    = true," % indent)

    comment = []
    if timer.get("from"):
        comment.append("source %s" % timer["from"])
    for field, (source, value) in (timer.get("disagreement") or {}).items():
        comment.append("%s dit %s = %s" % (source, field, lua_number(value)))
    head = "%s{" % indent
    if comment:
        head += "   -- %s" % " ; ".join(comment)
    return "\n".join([head] + lines + ["%s}," % indent])


def render_phase(phase: dict, index: int, indent: str) -> str:
    fields = []
    if phase.get("name"):
        fields.append("name = %s" % lua_string(phase["name"]))
    if index > 1 and phase.get("trigger"):
        fields.append('trigger = "%s"' % phase["trigger"])
        if phase.get("pattern"):
            fields.append("pattern = %s" % lua_string(phase["pattern"]))
    fields.append("provisional = true")
    return "%s{ %s }," % (indent, ", ".join(fields))


HEADER = """\
-- {name} — genere par tools/bossmod-extract, ne pas versionner.
--
-- Source : {sources}, lus dans ton installation locale.
-- Ce ne sont PAS des mesures : ce sont les chiffres que ces addons utilisent.
-- `tools/wcl-ingest` reste ce qui produit de la data mesuree, et la data du
-- depot passe devant celle-ci partout ou elle existe.
--
-- Fichier(s) d'origine :
{files}
"""


def render_boss(npc_id: int, entry: dict, flavor: str) -> str:
    sources = ", ".join(entry.get("sources", [entry["source"]]))
    files = "\n".join("--   %s" % f
                      for f in (entry.get("files") or [entry.get("file", "?")]))
    out = [HEADER.format(name=entry.get("name") or npc_id, sources=sources, files=files)]
    out.append("local _, ns = ...")
    out.append("")
    out.append("ns.Data[%d] = {" % npc_id)
    if entry.get("name"):
        out.append("    name        = %s," % lua_string(str(entry["name"])))
    out.append('    kind        = "%s",' % entry.get("kind", "raid"))
    if entry.get("encounter_ids"):
        out.append("    encounterId = %d," % entry["encounter_ids"][0])
    if entry.get("instance_ids"):
        out.append("    instanceId  = %d," % entry["instance_ids"][0])
    extra = [i for i in entry.get("npc_ids", [])[1:]]
    if extra:
        out.append("    npcIds      = { %s }," % ", ".join(str(i) for i in extra))
    out.append("    flavors     = { %s = true }," % flavor)
    out.append("    zone        = %s," % lua_string(entry.get("zone", "?")))
    out.append("    provisional = true,")
    out.append('    source      = "%s",' % sources)

    phases = entry.get("phases") or []
    if phases:
        out.append("")
        out.append("    phases = {")
        for index, phase in enumerate(phases, start=1):
            out.append(render_phase(phase, index, "        "))
        out.append("    },")

    out.append("")
    out.append("    timers = {")
    for timer in entry.get("timers", []):
        out.append(render_timer(timer, "        "))
    out.append("    },")
    out.append("}")

    if entry.get("encounter_ids"):
        out.append("")
        out.append("ns.Encounter[%d] = %d" % (entry["encounter_ids"][0], npc_id))
    out.append("")
    return "\n".join(out)


BOOTSTRAP = """\
-- {addon} — genere par tools/bossmod-extract. Ne pas versionner.
--
-- Addon compagnon : il ne fait que deposer sa data dans une table globale, que
-- MyBossSuite lit au demarrage du module Boss Timer (Modules/BossTimer/
-- Extracted.lua). Passer par un global plutot que par le namespace de
-- MyBossSuite est ce qui permet aux deux addons de se charger dans n'importe
-- quel ordre, et a celui-ci de rester absent sans rien casser.

local _, ns = ...

{table} = {table} or {{ data = {{}}, encounter = {{}}, flavor = nil, generated = nil }}
{table}.flavor    = "{flavor}"
{table}.generated = "{stamp}"

ns.Data      = {table}.data
ns.Encounter = {table}.encounter
"""

TOC = """\
## Interface: {interface}
## Title: MyBossSuite — data boss mod (locale)
## Notes: Data extraite de DBM/BigWigs par tools/bossmod-extract. Usage local.
## Version: {stamp}
## X-Flavor: {flavor}
## X-Generated-By: tools/bossmod-extract
## X-Local-Only: true

# ATTENTION : genere. Ne pas versionner, ne pas redistribuer.
Bootstrap.lua

{files}
"""


def safe_name(text: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", str(text)).strip("_")
    return cleaned or "Inconnu"


def write_addon(out_dir: pathlib.Path, bosses: dict, flavor: str, stamp: str) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)

    for stale in out_dir.rglob("*.lua"):
        stale.unlink()

    written = []
    for npc_id in sorted(bosses):
        entry = bosses[npc_id]
        zone = safe_name(entry.get("zone", "Inconnu"))
        name = safe_name(entry.get("name") or npc_id)
        relative = "%s/%s_%d.lua" % (zone, name, npc_id)
        target = out_dir / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(render_boss(npc_id, entry, flavor), encoding="utf-8")
        written.append(relative)

    (out_dir / "Bootstrap.lua").write_text(
        BOOTSTRAP.format(addon=ADDON_NAME, table=GLOBAL_TABLE, flavor=flavor, stamp=stamp),
        encoding="utf-8",
    )
    (out_dir / ("%s.toc" % ADDON_NAME)).write_text(
        TOC.format(interface=INTERFACE[flavor], flavor=flavor, stamp=stamp,
                   files="\n".join(written)),
        encoding="utf-8",
    )
    return len(written)


# ------------------------------------------------------------------------------


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


def read_build_info(root: pathlib.Path):
    """{produit: version} depuis le `.build.info` a la racine de l'installation.

    Fichier a colonnes separees par `|`, en-tete `Nom!TYPE:taille`."""
    try:
        lines = (root / ".build.info").read_text(
            encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return {}
    if len(lines) < 2:
        return {}
    header = [column.split("!")[0] for column in lines[0].split("|")]
    out = {}
    for line in lines[1:]:
        row = dict(zip(header, line.split("|")))
        product, version = row.get("Product"), row.get("Version")
        if product and version:
            out[product] = version
    return out


def guess_flavor(install: pathlib.Path):
    """Le flavor de ce client, lu dans `.build.info`, ou None.

    Rendre None plutot que deviner est deliberé : de la data Mists chargee sur
    un client Cata donnerait des timings faux avec l'air d'etre justes. Sans
    certitude, l'outil demande `--flavor`."""
    product = PRODUCT_FROM_FOLDER.get(install.name)
    if not product:
        return None
    # `.build.info` est a la racine de l'installation, au-dessus des dossiers de
    # produit ; on accepte aussi une copie dans le dossier du produit.
    for root in (install.parent, install):
        version = read_build_info(root).get(product)
        if not version:
            continue
        if product == "wow":
            return "retail"
        try:
            major = int(version.split(".")[0])
        except (ValueError, IndexError):
            return None
        return FLAVOR_FROM_MAJOR.get(major)
    return None


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Extrait les timings de boss de DBM/BigWigs installes localement.")
    parser.add_argument("--install", required=True,
                        help="racine d'un client, ex. \"C:/World of Warcraft/_classic_era_\"")
    parser.add_argument("--flavor", choices=FLAVORS,
                        help="flavor cible (devine depuis le nom du dossier sinon)")
    parser.add_argument("--zone", help="ne traiter que les zones contenant ce fragment")
    parser.add_argument("--out", help="dossier de sortie (defaut : Interface/AddOns/%s)" % ADDON_NAME)
    parser.add_argument("--dry-run", action="store_true",
                        help="affiche ce qui serait genere, n'ecrit rien")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    install = pathlib.Path(args.install).expanduser()
    addons = install / "Interface" / "AddOns"
    if not addons.is_dir():
        addons = install if (install / "DBM-Core").is_dir() or install.name == "AddOns" else addons
    if not addons.is_dir():
        print("dossier AddOns introuvable sous %s" % install, file=sys.stderr)
        return 2

    flavor = args.flavor or guess_flavor(install)
    if not flavor:
        print("flavor indeterminable depuis %s — passe --flavor" % install.name, file=sys.stderr)
        return 2

    out_dir = pathlib.Path(args.out).expanduser() if args.out else addons / ADDON_NAME
    root = repo_root()
    try:
        out_dir.resolve().relative_to(root)
    except ValueError:
        pass
    else:
        print("refus d'ecrire dans le depot (%s).\n"
              "Cette data derive de DBM/BigWigs, qui sont All Rights Reserved :\n"
              "elle reste locale. Laisse --out vide pour ecrire a cote du client."
              % out_dir, file=sys.stderr)
        return 2

    bosses, stats = collect(addons, flavor, args.zone)

    print("%d fichier(s) lus, %d module(s) de boss, %d rencontre(s) retenues"
          % (stats["fichiers"], stats["modules"], len(bosses)))
    if stats["rejets"]:
        print("%d timer(s) ignores : duree non litterale (calculee a l'execution)"
              % stats["rejets"])

    if args.verbose:
        for npc_id in sorted(bosses):
            entry = bosses[npc_id]
            print("  %-8d %-28s %-10s %-9s %d timer(s), %d phase(s)  [%s]" % (
                npc_id, (entry.get("name") or "?")[:28], entry.get("kind"),
                entry.get("zone", "")[:9], len(entry.get("timers", [])),
                len(entry.get("phases") or []), ",".join(entry.get("sources", []))))

    if args.dry_run:
        print("--dry-run : rien n'a ete ecrit (sortie prevue : %s)" % out_dir)
        return 0

    if not bosses:
        print("aucune rencontre extraite — rien n'est ecrit.", file=sys.stderr)
        return 1

    stamp = __import__("datetime").datetime.now().strftime("%Y%m%d%H%M")
    count = write_addon(out_dir, bosses, flavor, stamp)
    print("%d fichier(s) ecrits dans %s" % (count, out_dir))
    print("Active « MyBossSuite — data boss mod » dans la liste des addons, "
          "puis verifie avec /mbs boss list.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
