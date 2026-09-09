"""Scanner structurel de source Lua — assez pour lire un module de boss mod.

Ce n'est ni un interpreteur ni un parseur complet : c'est un scanner qui sait
trois choses, les seules dont l'extraction ait besoin.

1. **Neutraliser ce qui n'est pas du code.** `blank()` rend une copie du texte,
   de meme longueur, ou commentaires et contenus de chaines sont remplaces par
   des espaces. Toute la suite scanne ce masque et decoupe le texte d'origine
   aux memes positions : une virgule dans une chaine ne coupe donc jamais une
   liste d'arguments, et un mot-cle dans un commentaire n'ouvre jamais un bloc.
2. **Apparier les blocs.** `function`, `if`, `do` et `repeat` ouvrent, `end` et
   `until` ferment. `while ... do` et `for ... do` comptent par leur `do`, pas
   par leur mot-cle de tete — sinon chaque boucle compterait double.
3. **Decouper un appel.** `split_args` rend les arguments de premier niveau,
   parentheses, crochets et accolades imbriques respectes.

Pourquoi pas un shim Lua + `dofile`, qui executerait le vrai code ? Parce que ca
ne marche que sur la moitie du probleme. DBM declare ses timers au chargement,
donc un shim les verrait ; mais les durees qui comptent (`timer:Start(28.5)`)
sont dans les gestionnaires d'evenements, qui ne tournent pas au chargement. Et
BigWigs met *tout* dans des gestionnaires. Lire la source attrape les deux, sans
interpreteur a installer.
"""

from __future__ import annotations

import ast
import re

_LONG_BRACKET = re.compile(r"\[(=*)\[")
_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_NUMBER = re.compile(r"^-?(?:\d+\.?\d*|\.\d+)$")
_STRING = re.compile(r"^(['\"])(.*)\1$", re.S)
_ARITHMETIC = re.compile(r"^[\d\s.+\-*/()]+$")

# `while X do` et `for X do` sont comptes par leur `do`. `elseif` / `else` /
# `then` ne changent pas la profondeur.
_OPENERS = frozenset({"function", "if", "do", "repeat"})
_CLOSERS = frozenset({"end", "until"})


def _blank_span(out: list, start: int, stop: int) -> None:
    """Efface [start, stop) en gardant les retours a la ligne : les positions
    restent valides dans le texte d'origine, et les numeros de ligne aussi."""
    for i in range(start, min(stop, len(out))):
        if out[i] != "\n":
            out[i] = " "


def blank(text: str) -> str:
    """Masque de meme longueur : commentaires et chaines remplaces par des
    espaces, code inchange."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        char = text[i]

        if char == "-" and text.startswith("--", i):
            long_bracket = _LONG_BRACKET.match(text, i + 2)
            if long_bracket:
                closing = "]" + "=" * len(long_bracket.group(1)) + "]"
                end = text.find(closing, long_bracket.end())
                end = n if end < 0 else end + len(closing)
            else:
                end = text.find("\n", i)
                end = n if end < 0 else end
            _blank_span(out, i, end)
            i = end
            continue

        if char in "\"'":
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == char:
                    j += 1
                    break
                if text[j] == "\n":  # chaine non terminee : on s'arrete la
                    break
                j += 1
            _blank_span(out, i, j)
            i = max(j, i + 1)
            continue

        if char == "[":
            long_bracket = _LONG_BRACKET.match(text, i)
            if long_bracket:
                closing = "]" + "=" * len(long_bracket.group(1)) + "]"
                end = text.find(closing, long_bracket.end())
                end = n if end < 0 else end + len(closing)
                _blank_span(out, i, end)
                i = end
                continue

        i += 1

    return "".join(out)


def block_end(mask: str, start: int) -> int:
    """Position juste apres le `end` (ou `until`) qui ferme le bloc ouvert au
    mot-cle situe a `start`. La fin du fichier si le bloc n'est pas ferme."""
    depth = 0
    for match in _WORD.finditer(mask, start):
        word = match.group(0)
        if word in _OPENERS:
            depth += 1
        elif word in _CLOSERS:
            depth -= 1
            if depth == 0:
                return match.end()
    return len(mask)


def match_paren(mask: str, open_pos: int) -> int:
    """Position de la parenthese fermante appariee a celle de `open_pos`."""
    depth = 0
    for i in range(open_pos, len(mask)):
        char = mask[i]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return i
    return -1


def split_args(mask: str, text: str, open_pos: int):
    """Arguments de premier niveau d'un appel dont la parenthese ouvrante est en
    `open_pos`. Rend (liste d'arguments, position de la fermante)."""
    close = match_paren(mask, open_pos)
    if close < 0:
        return None, -1

    parts, start, depth = [], open_pos + 1, 0
    for i in range(open_pos, close + 1):
        char = mask[i]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                parts.append(text[start:i].strip())
                break
        elif char == "," and depth == 1:
            parts.append(text[start:i].strip())
            start = i + 1

    if len(parts) == 1 and not parts[0]:
        parts = []
    return parts, close


def call_pattern(receivers, methods) -> re.Pattern:
    return re.compile(
        r"\b(%s)\s*[:.]\s*(%s)\s*\(" % ("|".join(receivers), "|".join(methods))
    )


def find_calls(mask: str, text: str, pattern: re.Pattern, lo: int = 0, hi=None):
    """Itere les appels `<recepteur>:<methode>(...)` dans [lo, hi).

    Rend (recepteur, methode, arguments, debut, fin)."""
    hi = len(mask) if hi is None else hi
    for match in pattern.finditer(mask, lo, hi):
        args, close = split_args(mask, text, match.end() - 1)
        if args is None:
            continue
        yield match.group(1), match.group(2), args, match.start(), close


_METHOD_DEF = re.compile(r"\bfunction\s+([A-Za-z_][\w.]*)\s*[:.]\s*([A-Za-z_]\w*)\s*\(")


def find_methods(mask: str):
    """`function <recepteur>:<nom>(...)` → {nom: [(recepteur, debut, fin), ...]}.

    Le corps commence apres la parenthese fermante de la liste d'arguments et
    s'arrete au `end` apparie. Un meme nom peut apparaitre plusieurs fois : un
    module qui redefinit `GetOptions` sous condition de saison, par exemple."""
    out = {}
    for match in _METHOD_DEF.finditer(mask):
        close = match_paren(mask, match.end() - 1)
        if close < 0:
            continue
        out.setdefault(match.group(2), []).append(
            (match.group(1), close + 1, block_end(mask, match.start()))
        )
    return out


_ALLOWED_NODES = (
    ast.Expression, ast.BinOp, ast.UnaryOp, ast.Constant,
    ast.Add, ast.Sub, ast.Mult, ast.Div, ast.USub, ast.UAdd,
)


def as_number(arg: str):
    """Valeur d'un argument numerique litteral, ou None.

    Les modules ecrivent parfois `29.1 + 5` (temps de marche + incantation) :
    l'expression est evaluee, mais seulement si elle ne contient que des nombres
    et quatre operateurs — l'arbre est verifie noeud par noeud, jamais `eval`
    sur du texte arbitraire. Tout ce qui depend d'une variable (`self:Easy() and
    20 or 15`) rend None et sera ignore plus haut : mieux vaut pas de timer
    qu'un timer faux."""
    arg = (arg or "").strip()
    if _NUMBER.match(arg):
        return float(arg)
    if not _ARITHMETIC.match(arg) or not re.search(r"\d", arg):
        return None
    try:
        tree = ast.parse(arg, mode="eval")
    except SyntaxError:
        return None
    for node in ast.walk(tree):
        if not isinstance(node, _ALLOWED_NODES):
            return None
        if isinstance(node, ast.Constant) and not isinstance(node.value, (int, float)):
            return None
    try:
        value = eval(compile(tree, "<duree>", "eval"), {"__builtins__": {}}, {})
    except Exception:
        return None
    return float(value) if isinstance(value, (int, float)) else None


def as_string(arg: str):
    """Contenu d'une chaine litterale, ou None."""
    match = _STRING.match((arg or "").strip())
    return match.group(2) if match else None


def as_int(arg: str):
    value = as_number(arg)
    if value is None or value != int(value):
        return None
    return int(value)


def int_list(args):
    """Les arguments entiers d'un appel, dans l'ordre, en sautant le reste."""
    out = []
    for arg in args:
        value = as_int(arg)
        if value is not None:
            out.append(value)
    return out


_VARIABLE_RANGE = re.compile(r"^v([\d.]+)-([\d.]+)$")


def as_duration(arg: str):
    """Duree d'un timer, sous la forme (secondes, variable).

    DBM ecrit une cadence non deterministe `"v9.7-35.6"` : le timer part a la
    borne basse et la barre est marquee incertaine. On garde le minimum, pas la
    moyenne — une barre qui finit trop tot se voit, une barre qui finit trop
    tard a deja menti."""
    text = as_string(arg)
    if text:
        match = _VARIABLE_RANGE.match(text.strip())
        if match:
            try:
                return float(match.group(1)), True
            except ValueError:
                return None, False
        return None, False
    value = as_number(arg)
    return (value, False) if value is not None else (None, False)


def branches(mask: str, text: str, lo: int, hi: int):
    """Decoupe les chaines `if / elseif / else` de premier niveau dans [lo, hi).

    Rend une liste de (condition, debut du corps, fin du corps). La condition
    est vide pour un `else`. Sans ca, un gestionnaire DBM est illisible : c'est
    la condition (`args:IsSpell(18435)`) qui dit quel sort demarre quel timer, et
    le corps seul ne le dit pas."""
    out = []
    depth = 0
    base = None
    pending = []   # (condition, debut du corps, profondeur)

    for match in _WORD.finditer(mask, lo):
        if match.start() >= hi:
            break
        word = match.group(0)

        if word == "if":
            if base is None:
                base = depth
            if depth == base:
                then = mask.find("then", match.end())
                if then < 0:
                    break
                pending.append((text[match.end():then].strip(), then + 4, depth))
            depth += 1
            continue

        if word in _OPENERS:
            depth += 1
            continue

        if word in ("elseif", "else"):
            if pending and depth == pending[-1][2] + 1:
                condition, start, own = pending.pop()
                out.append((condition, start, match.start()))
                if word == "elseif":
                    then = mask.find("then", match.end())
                    if then < 0:
                        break
                    pending.append((text[match.end():then].strip(), then + 4, own))
                else:
                    pending.append(("", match.end(), own))
            continue

        if word in _CLOSERS:
            depth -= 1
            if pending and depth == pending[-1][2]:
                condition, start, _ = pending.pop()
                out.append((condition, start, match.start()))
            if base is not None and depth < base:
                break
            continue

    return out
