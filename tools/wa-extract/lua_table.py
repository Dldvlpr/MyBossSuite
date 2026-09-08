"""Parseur minimal de litteraux Lua (assez pour un fichier SavedVariables).

Un fichier SavedVariables ne contient que des affectations de donnees : pas
d'appels, pas d'operateurs. Un parseur de litteraux suffit donc, et evite de
dependre d'un interpreteur Lua sur la machine.
"""

from __future__ import annotations

import re

_WS = re.compile(r"(?:\s+|--\[(=*)\[.*?\]\1\]|--[^\n]*)*", re.S)
_NUMBER = re.compile(r"-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)")
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

_ESCAPES = {
    "a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r",
    "t": "\t", "v": "\v", "\\": "\\", '"': '"', "'": "'", "\n": "\n",
}


class LuaSyntaxError(ValueError):
    pass


class Parser:
    def __init__(self, text: str):
        self.text = text
        self.pos = 0

    # -- primitives ---------------------------------------------------------

    def skip(self) -> None:
        match = _WS.match(self.text, self.pos)
        if match:
            self.pos = match.end()

    def peek(self) -> str:
        self.skip()
        return self.text[self.pos] if self.pos < len(self.text) else ""

    def expect(self, char: str) -> None:
        if self.peek() != char:
            raise LuaSyntaxError(f"attendu {char!r} a l'offset {self.pos}")
        self.pos += 1

    def accept(self, char: str) -> bool:
        if self.peek() == char:
            self.pos += 1
            return True
        return False

    # -- valeurs ------------------------------------------------------------

    def parse_string(self) -> str:
        quote = self.text[self.pos]
        self.pos += 1
        out = []
        while True:
            if self.pos >= len(self.text):
                raise LuaSyntaxError("chaine non terminee")
            char = self.text[self.pos]
            if char == "\\":
                self.pos += 1
                escape = self.text[self.pos]
                if escape.isdigit():
                    digits = ""
                    while len(digits) < 3 and self.text[self.pos].isdigit():
                        digits += self.text[self.pos]
                        self.pos += 1
                    out.append(chr(int(digits)))
                    continue
                if escape == "x":
                    hex_digits = self.text[self.pos + 1:self.pos + 3]
                    out.append(chr(int(hex_digits, 16)))
                    self.pos += 3
                    continue
                out.append(_ESCAPES.get(escape, escape))
                self.pos += 1
            elif char == quote:
                self.pos += 1
                return "".join(out)
            else:
                out.append(char)
                self.pos += 1

    def parse_long_string(self) -> str:
        match = re.compile(r"\[(=*)\[").match(self.text, self.pos)
        if not match:
            raise LuaSyntaxError(f"chaine longue invalide a l'offset {self.pos}")
        level = match.group(1)
        start = match.end()
        end = self.text.find(f"]{level}]", start)
        if end < 0:
            raise LuaSyntaxError("chaine longue non terminee")
        self.pos = end + len(level) + 2
        value = self.text[start:end]
        return value[1:] if value.startswith("\n") else value

    def parse_value(self):
        char = self.peek()
        if char == "{":
            return self.parse_table()
        if char in "\"'":
            return self.parse_string()
        if char == "[":
            return self.parse_long_string()
        match = _NUMBER.match(self.text, self.pos)
        if match:
            self.pos = match.end()
            raw = match.group(0)
            if raw.lower().startswith(("0x", "-0x")):
                return int(raw, 16)
            return float(raw) if any(c in raw for c in ".eE") else int(raw)
        match = _NAME.match(self.text, self.pos)
        if match:
            self.pos = match.end()
            word = match.group(0)
            if word == "true":
                return True
            if word == "false":
                return False
            if word == "nil":
                return None
            return word
        raise LuaSyntaxError(f"valeur inattendue a l'offset {self.pos}: {self.text[self.pos:self.pos+20]!r}")

    def parse_table(self) -> dict:
        self.expect("{")
        table: dict = {}
        index = 1
        while True:
            if self.accept("}"):
                return table
            if self.peek() == "[":
                # Distinguer une cle [k] d'une chaine longue [[...]].
                if re.compile(r"\[=*\[").match(self.text, self.pos):
                    table[index] = self.parse_value()
                    index += 1
                else:
                    self.pos += 1
                    key = self.parse_value()
                    self.expect("]")
                    self.expect("=")
                    table[key] = self.parse_value()
            else:
                start = self.pos
                match = _NAME.match(self.text, self.pos)
                if match:
                    self.pos = match.end()
                    if self.peek() == "=" and self.text[self.pos + 1] != "=":
                        self.pos += 1
                        table[match.group(0)] = self.parse_value()
                    else:
                        self.pos = start
                        table[index] = self.parse_value()
                        index += 1
                else:
                    table[index] = self.parse_value()
                    index += 1
            if not (self.accept(",") or self.accept(";")):
                self.expect("}")
                return table


def parse_saved_variables(text: str) -> dict:
    """Retourne { nom_de_variable: valeur } pour chaque affectation top-level."""
    out = {}
    for match in re.finditer(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*", text, re.M):
        parser = Parser(text)
        parser.pos = match.end()
        try:
            out[match.group(1)] = parser.parse_value()
        except LuaSyntaxError as exc:
            out[match.group(1)] = {"__error__": str(exc)}
    return out
