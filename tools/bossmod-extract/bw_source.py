"""Lecture d'un module BigWigs : metadonnees, timers, phases.

BigWigs est plus verbeux que DBM, mais paradoxalement plus facile a lire hors
ligne, parce qu'il n'y a pas de chaine `if / elseif` a demeler : **une fonction
par declencheur**, et une table qui dit laquelle.

    local mod = BigWigs:NewBoss("Onyxia", 249, 1651)
    mod:RegisterEnableMob(10184, 12129)
    mod:SetEncounterID(1084)

    function mod:OnBossEnable()
        self:Log("SPELL_CAST_START", "FlameBreath", 18435)   -- ← la table
    end

    function mod:OnEngage()
        self:CDBar(18435, 13, CL.frontal_cone)               -- ← timer PULL
    end

    function mod:FlameBreath(args)
        self:CDBar(args.spellId, 12, CL.frontal_cone)        -- ← cadence
    end

`self:Log(sous-evenement, "Gestionnaire", sortIds...)` suffit donc a savoir quel
sort mene a quelle fonction, et il ne reste qu'a lire les barres posees dans le
corps de cette fonction.

Les phases sortent du meme fichier, et mieux que chez DBM : `self:SetStage(2)`
est litteral, et le fragment de texte qui le declenche est declare en clair dans
le bloc de localisation (`L.stage2_yell_trigger = "from above"`). C'est
exactement ce qu'attend un trigger `EMOTE` de MyBossSuite — un fragment, pas une
phrase complete.

Rappel de la meme regle que pour DBM : ce qui n'est pas litteral n'est pas
extrait. `self:Bar(args.spellId, self:Mythic() and 20 or 30)` ne rend rien.
"""

from __future__ import annotations

import re

import lua_source as L

_NEW_BOSS = L.call_pattern(["BigWigs"], ["NewBoss"])
_META = L.call_pattern(
    ["mod", "self"], ["RegisterEnableMob", "SetEncounterID", "SetStage"]
)
_LOG = L.call_pattern(["self", "mod"], ["Log"])
_BARS = L.call_pattern(["self", "mod"], ["Bar", "CDBar", "CastBar", "TargetBar"])
_SET_STAGE = L.call_pattern(["self", "mod"], ["SetStage"])

# `L.stage2_yell_trigger = "from above"` — le fragment localise qui declenche la
# phase, ecrit en clair dans le bloc de localisation du module.
_LOCALE_ENTRY = re.compile(
    r"""\bL(?:\.(\w+)|\[\s*(['"])(.*?)\2\s*\])\s*=\s*(['"])(.*?)\4""", re.S
)
_STAGE_KEY = re.compile(r"stage(\d+)", re.I)

# `self:Log("SPELL_CAST_START", "Handler", 18435, 18351)` : sous-evenement,
# nom de la fonction, puis les sorts.
_AURA_EVENTS = ("SPELL_AURA_APPLIED", "SPELL_AURA_APPLIED_DOSE", "SPELL_AURA_REFRESH")
_CAST_EVENTS = ("SPELL_CAST_START", "SPELL_CAST_SUCCESS", "SPELL_SUMMON")

_YELL_HANDLERS = ("CHAT_MSG_MONSTER_YELL", "CHAT_MSG_RAID_BOSS_EMOTE",
                  "CHAT_MSG_MONSTER_EMOTE", "CHAT_MSG_RAID_BOSS_WHISPER")


def _metadata(mask: str, text: str) -> dict:
    meta = {
        "name": None, "instance_ids": [], "journal_id": None,
        "npc_ids": [], "encounter_ids": [],
    }

    for _, _, args, _, _ in L.find_calls(mask, text, _NEW_BOSS):
        if args:
            meta["name"] = L.as_string(args[0])
        if len(args) > 1:
            instance = L.as_int(args[1])
            # `NewBoss(nom, -1023, ...)` : un id negatif est une zone de monde
            # ouvert, pas une instance. On le garde tel quel, il est informatif.
            if instance is not None:
                meta["instance_ids"].append(instance)
        if len(args) > 2:
            meta["journal_id"] = L.as_int(args[2])
        break

    for _, method, args, _, _ in L.find_calls(mask, text, _META):
        if method == "RegisterEnableMob":
            meta["npc_ids"].extend(L.int_list(args))
        elif method == "SetEncounterID":
            meta["encounter_ids"].extend(L.int_list(args))

    for key in ("npc_ids", "encounter_ids", "instance_ids"):
        seen, unique = set(), []
        for value in meta[key]:
            if value not in seen:
                seen.add(value)
                unique.append(value)
        meta[key] = unique
    return meta


def _handler_map(mask: str, text: str, methods) -> dict:
    """{nom de fonction: (declencheur, [sortIds])} depuis les appels `self:Log`.

    Ils vivent dans `OnBossEnable`, mais certains modules en posent ailleurs :
    on balaie tout le fichier, c'est sans ambiguite."""
    out = {}
    for _, _, args, _, _ in L.find_calls(mask, text, _LOG):
        if len(args) < 2:
            continue
        subevent = L.as_string(args[0])
        handler = L.as_string(args[1])
        if not subevent or not handler:
            continue
        spell_ids = [i for i in L.int_list(args[2:]) if i >= 1000]
        if not spell_ids:
            continue
        if subevent in _AURA_EVENTS:
            trigger = "AURA"
        elif subevent in _CAST_EVENTS:
            trigger = "CAST"
        else:
            continue
        existing = out.get(handler)
        if existing:
            existing[1].extend(i for i in spell_ids if i not in existing[1])
        else:
            out[handler] = (trigger, list(spell_ids), subevent)
    return out


def _bars_in(mask: str, text: str, lo: int, hi: int):
    """Les barres posees dans une region : (methode, cle, duree)."""
    out = []
    for _, method, args, start, _ in L.find_calls(mask, text, _BARS, lo, hi):
        if start >= hi or len(args) < 2:
            continue
        duration = L.as_number(args[1])
        if duration is None or duration <= 0:
            out.append((method, args[0].strip(), None))
            continue
        out.append((method, args[0].strip(), duration))
    return out


def _locale_strings(mask: str, text: str) -> dict:
    out = {}
    for match in _LOCALE_ENTRY.finditer(text):
        key = match.group(1) or match.group(3)
        if key:
            out.setdefault(key, match.group(5))
    return out


def _phases(mask: str, text: str, methods, locale) -> list:
    """Phases lisibles : un `SetStage(n)` litteral dans un gestionnaire de cri,
    et le fragment de texte qui l'a declenche.

    On ne rend une phase que si les deux sont la. Un `SetStage` sans fragment
    donnerait une phase qui ne se declenche jamais — pire que pas de phase."""
    found = {}
    for handler in _YELL_HANDLERS:
        for _, lo, hi in methods.get(handler, []):
            for condition, start, stop in L.branches(mask, text, lo, hi):
                stage = None
                for _, _, args, pos, _ in L.find_calls(mask, text, _SET_STAGE, start, stop):
                    if pos >= stop:
                        break
                    value = L.as_int(args[0]) if args else None
                    if value is not None and 1 < value <= 20:
                        stage = value
                        break
                if stage is None:
                    continue
                fragment = None
                for key in re.findall(r"\bL\.(\w+)", condition):
                    if key in locale:
                        fragment = locale[key]
                        break
                if fragment is None:
                    for key in re.findall(r"""\bL\[\s*['"](.*?)['"]\s*\]""", condition):
                        if key in locale:
                            fragment = locale[key]
                            break
                if fragment:
                    found.setdefault(stage, fragment)

    if not found:
        return []

    # On s'arrete au premier trou. Une phase sans declencheur ne se declenche
    # jamais, et toutes celles qui la suivent deviennent inatteignables : mieux
    # vaut une liste plus courte et vraie qu'une liste complete et morte.
    phases = [{"name": None, "trigger": None}]
    stage = 2
    while stage in found:
        phases.append({"name": None, "trigger": "EMOTE", "pattern": found[stage]})
        stage += 1
    return phases if len(phases) > 1 else []


def _resolve_key(key: str, spell_ids: list):
    """La cle d'une barre BigWigs est un spellId, `args.spellId`, ou un nom
    d'option textuel (`"stages"`). Seuls les deux premiers nous interessent."""
    literal = L.as_int(key)
    if literal is not None and literal >= 1000:
        return literal
    if "spellId" in key and spell_ids:
        return spell_ids[0]
    return None


def extract(text: str) -> dict:
    mask = L.blank(text)
    if "NewBoss" not in mask:
        return None

    meta = _metadata(mask, text)
    if not meta["npc_ids"]:
        return None

    methods = L.find_methods(mask)
    handlers = _handler_map(mask, text, methods)
    locale = _locale_strings(mask, text)
    timers, rejected = [], 0

    # 1. Timers de pull : les barres posees dans OnEngage.
    for _, lo, hi in methods.get("OnEngage", []):
        for method, key, duration in _bars_in(mask, text, lo, hi):
            if duration is None:
                rejected += 1
                continue
            spell_id = _resolve_key(key, [])
            if spell_id is None:
                continue
            timers.append({
                "trigger": "PULL",
                "time": round(duration, 1),
                "spell_id": spell_id,
                "name": None,
            })

    # 2. Timers declenches : une fonction par declencheur, la table `Log` dit
    #    lequel, le corps dit la cadence.
    for handler, (trigger, spell_ids, subevent) in handlers.items():
        for _, lo, hi in methods.get(handler, []):
            for method, key, duration in _bars_in(mask, text, lo, hi):
                if duration is None:
                    rejected += 1
                    continue
                entry = {
                    "trigger": trigger,
                    "spell_id": spell_ids[0],
                    "name": None,
                    "cast_start": subevent == "SPELL_CAST_START",
                }
                # `CastBar` mesure l'incantation en cours, `Bar` / `CDBar` le
                # delai jusqu'a la suivante. Meme distinction que chez DBM.
                if method == "CastBar":
                    entry["test_time"] = round(duration, 1)
                else:
                    entry["repeat_interval"] = round(duration, 1)
                timers.append(entry)

    return {
        "source": "bigwigs",
        "mod_id": meta["name"],
        "name": meta["name"],
        "npc_ids": meta["npc_ids"],
        "encounter_ids": meta["encounter_ids"],
        "instance_ids": [i for i in meta["instance_ids"] if i > 0],
        "stages": 1,
        "phases": _phases(mask, text, methods, locale),
        "timers": timers,
        "rejected": rejected,
    }
