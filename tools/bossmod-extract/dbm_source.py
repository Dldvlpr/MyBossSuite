"""Lecture d'un module DBM : metadonnees, timers, phases.

DBM a une forme tres reguliere, et c'est ce qui rend l'extraction possible :

    local mod = DBM:NewMod("OnyxiaVanilla", "DBM-Raids-Vanilla", 7)
    mod:SetCreatureID(10184)
    mod:SetEncounterID(1084)
    local timerFlameBreathCD = mod:NewVarTimer("v9.7-35.6", 18435, ...)
    local timerBreath        = mod:NewCastTimer(5, 17086, ...)

    function mod:OnCombatStart()
        timerFlameBreathCD:Start("v11.3-28.5")     -- → timer PULL a 11.3 s
    end

    function mod:SPELL_CAST_START(args)
        if args:IsSpell(18435) ... then
            timerFlameBreathCD:Start()             -- → timer CAST, duree declaree
        end
    end

Deux niveaux, donc. La **declaration** donne le sort et la duree par defaut ; le
**gestionnaire** donne le declencheur, et parfois une duree qui remplace celle
de la declaration. Un timer demarre dans `OnCombatStart` est un `PULL` ; demarre
sous une branche `args:IsSpell(id)` d'un gestionnaire de combat log, c'est un
`CAST` (ou `AURA`) sur ce sort.

Ce qui n'est pas litteral n'est pas extrait. `timer:Start(self:IsHeroic() and 20
or 30)` ne rend rien : un timer absent se remarque et se corrige, un timer faux
se croit. Le compteur de rejets est rendu au CLI.
"""

from __future__ import annotations

import re

import lua_source as L

# `mod:New<X>Timer(duree, sortId, ...)`. La famille est ouverte (DBM en ajoute),
# donc on matche la forme plutot qu'une liste close.
_TIMER_DECL = re.compile(
    r"\blocal\s+([A-Za-z_]\w*)\s*=\s*(?:mod|self)\s*:\s*(New\w*Timer)\s*\("
)

# `<var>:Start(...)` / `:Schedule(delai, ...)` / `:Stop()`
_TIMER_START = re.compile(r"\b([A-Za-z_]\w*)\s*:\s*(Start|Schedule)\s*\(")

_IS_SPELL = re.compile(r"\bargs\s*:\s*IsSpell\s*\(")
_SPELL_EQ = re.compile(r"\bargs\.spellId\s*==\s*(\d+)")

_META = L.call_pattern(
    ["mod", "self"],
    ["SetCreatureID", "SetEncounterID", "SetZone", "RegisterCombat", "SetStage"],
)
_NEW_MOD = L.call_pattern(["DBM"], ["NewMod"])
_SET_STAGE = L.call_pattern(["mod", "self"], ["SetStage"])

# Gestionnaires de combat log dont une branche `IsSpell` designe un declencheur.
_CAST_EVENTS = {
    "SPELL_CAST_START": "CAST",
    "SPELL_CAST_SUCCESS": "CAST",
    "SPELL_AURA_APPLIED": "AURA",
    "SPELL_AURA_APPLIED_DOSE": "AURA",
    "SPELL_AURA_REFRESH": "AURA",
    "SPELL_SUMMON": "CAST",
}

# `NewTimer(duree, "NomLocalise", icone, ...)` met le sort en 3e position, la ou
# toutes les autres familles le mettent en 2e.
_MAX_SPELL_ARG = 3

_CAMEL = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")


def _label_from_variable(name: str) -> str:
    """`timerFlameBreathCD` → « Flame Breath ».

    Le champ `name` de la data MyBossSuite est purement d'affichage (la cle est
    le npcId), et DBM ne stocke pas de libelle en clair : il resout le nom du
    sort a l'execution. Le nom de variable est la meilleure source hors ligne,
    et elle est lisible."""
    stem = re.sub(r"^(timer|warn|specWarn|yell|voice)", "", name)
    stem = re.sub(r"(CD|Timer)$", "", stem)
    words = [w for w in _CAMEL.split(stem) if w]
    return " ".join(words) if words else name


class DbmTimer:
    __slots__ = ("variable", "kind", "duration", "is_variable", "spell_id", "label")

    def __init__(self, variable, kind, duration, is_variable, spell_id, label):
        self.variable = variable
        self.kind = kind
        self.duration = duration
        self.is_variable = is_variable
        self.spell_id = spell_id
        self.label = label


def _declarations(mask: str, text: str):
    """Les timers declares au chargement, par nom de variable."""
    out = {}
    for match in _TIMER_DECL.finditer(mask):
        variable, kind = match.group(1), match.group(2)
        args, _ = L.split_args(mask, text, match.end() - 1)
        if not args:
            continue

        duration, is_variable = L.as_duration(args[0])

        spell_id = None
        for index in range(1, min(len(args), _MAX_SPELL_ARG + 1)):
            candidate = L.as_int(args[index])
            # Un spellId a au moins quatre chiffres ; les petits entiers de ces
            # signatures sont des niveaux de couleur ou des compteurs.
            if candidate is not None and candidate >= 1000:
                spell_id = candidate
                break

        # Le libelle vient du nom de variable, pas des arguments : les chaines
        # qu'on y trouve sont des cles de localisation ("TimerWhelps") ou des
        # filtres de role ("Tank|Healer"), jamais un nom affichable.
        out[variable] = DbmTimer(
            variable, kind, duration, is_variable, spell_id,
            _label_from_variable(variable),
        )
    return out


def _spell_ids_in(condition: str) -> list:
    """Les sorts que teste une condition de branche."""
    mask = L.blank(condition)
    ids = []
    for match in _IS_SPELL.finditer(mask):
        args, _ = L.split_args(mask, condition, match.end() - 1)
        ids.extend(L.int_list(args or []))
    ids.extend(int(m.group(1)) for m in _SPELL_EQ.finditer(mask))
    return [i for i in ids if i >= 1000]


def _starts_in(mask: str, text: str, lo: int, hi: int):
    """Les `<var>:Start(...)` d'une region.

    Rend (variable, duree, variable?, un argument etait present). Cette derniere
    valeur est ce qui separe deux cas que rien ne distingue autrement :

        timer:Start()                        -- duree = celle de la declaration
        timer:Start(self:IsHeroic() and 12 or 20)  -- duree ILLISIBLE

    Dans le second cas, le module a explicitement remplace la duree declaree. Y
    retomber donnerait un chiffre plausible et faux — le pire des deux mondes.
    L'appelant rejette le timer."""
    out = []
    for match in _TIMER_START.finditer(mask, lo, hi):
        if match.start() >= hi:
            break
        args, _ = L.split_args(mask, text, match.end() - 1)
        args = args or []
        duration, is_variable = (None, False)
        if args:
            duration, is_variable = L.as_duration(args[0])
        out.append((match.group(1), duration, is_variable, bool(args)))
    return out


def _metadata(mask: str, text: str) -> dict:
    meta = {"npc_ids": [], "encounter_ids": [], "instance_ids": [], "mod_id": None}

    for _, _, args, _, _ in L.find_calls(mask, text, _NEW_MOD):
        if args:
            meta["mod_id"] = L.as_string(args[0]) or meta["mod_id"]
        break

    for _, method, args, _, _ in L.find_calls(mask, text, _META):
        if method == "SetCreatureID":
            meta["npc_ids"].extend(L.int_list(args))
        elif method == "SetEncounterID":
            meta["encounter_ids"].extend(L.int_list(args))
        elif method == "SetZone":
            meta["instance_ids"].extend(L.int_list(args))

    for key in ("npc_ids", "encounter_ids", "instance_ids"):
        seen, unique = set(), []
        for value in meta[key]:
            if value not in seen:
                seen.add(value)
                unique.append(value)
        meta[key] = unique
    return meta


def _stages(mask: str, text: str) -> int:
    """Le plus grand numero de phase ecrit en clair dans le module.

    Beaucoup de modules appellent `SetStage(phase)` avec une variable : on ne
    voit alors que les appels litteraux, et le compte est un minorant. C'est
    dit tel quel dans le fichier genere plutot que complete au jugé."""
    highest = 1
    for _, _, args, _, _ in L.find_calls(mask, text, _SET_STAGE):
        if not args:
            continue
        value = L.as_number(args[0])
        if value is not None and value == int(value) and 1 <= value <= 20:
            highest = max(highest, int(value))
    return highest


def extract(text: str) -> dict:
    """Rend un dictionnaire neutre, commun aux deux boss mods, ou None si le
    fichier n'est pas un module de boss."""
    mask = L.blank(text)
    if "NewMod" not in mask:
        return None

    meta = _metadata(mask, text)
    if not meta["npc_ids"]:
        return None

    declared = _declarations(mask, text)
    methods = L.find_methods(mask)
    timers, rejected = [], 0

    def declaration_of(variable):
        return declared.get(variable)

    # 1. Timers de pull : tout ce qui demarre dans OnCombatStart.
    for _, lo, hi in methods.get("OnCombatStart", []):
        for variable, duration, is_variable, explicit in _starts_in(mask, text, lo, hi):
            timer = declaration_of(variable)
            if not timer:
                continue
            if explicit and duration is None:
                rejected += 1
                continue
            seconds = duration if duration is not None else timer.duration
            if seconds is None:
                rejected += 1
                continue
            timers.append({
                "trigger": "PULL",
                "time": round(seconds, 1),
                "spell_id": timer.spell_id,
                "name": timer.label,
                "variable": is_variable or timer.is_variable,
                "repeat_interval": round(timer.duration, 1) if timer.duration else None,
            })

    # 2. Timers declenches : la branche dit le sort, le corps dit le timer.
    for event, trigger in _CAST_EVENTS.items():
        for _, lo, hi in methods.get(event, []):
            for condition, start, stop in L.branches(mask, text, lo, hi):
                spell_ids = _spell_ids_in(condition)
                if not spell_ids:
                    continue
                for variable, duration, is_variable, explicit in _starts_in(mask, text, start, stop):
                    timer = declaration_of(variable)
                    if not timer:
                        continue
                    # Duree remplacee a l'execution par une expression illisible :
                    # on ne retombe pas sur celle de la declaration.
                    if explicit and duration is None:
                        rejected += 1
                        continue
                    seconds = duration if duration is not None else timer.duration
                    if seconds is None:
                        rejected += 1
                        continue

                    entry = {
                        "trigger": trigger,
                        "spell_id": spell_ids[0],
                        "name": timer.label,
                        "cast_start": event == "SPELL_CAST_START",
                    }
                    # Un `NewCastTimer` mesure la DUREE DE L'INCANTATION en
                    # cours ; toutes les autres familles (`CD`, `Next`, `Var`)
                    # mesurent le DELAI JUSQU'A LA SUIVANTE. Les confondre
                    # afficherait une barre de 5 s la ou il en faut une de 35.
                    if "Cast" in timer.kind:
                        entry["test_time"] = round(seconds, 1)
                    else:
                        entry["repeat_interval"] = round(seconds, 1)
                        entry["variable"] = is_variable or timer.is_variable
                    timers.append(entry)

    return {
        "source": "dbm",
        "mod_id": meta["mod_id"],
        "npc_ids": meta["npc_ids"],
        "encounter_ids": meta["encounter_ids"],
        "instance_ids": meta["instance_ids"],
        "name": meta["mod_id"],
        "stages": _stages(mask, text),
        "phases": [],
        "timers": timers,
        "rejected": rejected,
    }
