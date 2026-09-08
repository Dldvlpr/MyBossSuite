#!/usr/bin/env python3
"""Tests du chargement des identifiants WCL, sans reseau.

Ce qui merite d'etre teste ici, c'est la PRIORITE et la TOLERANCE du parsing.

La priorite d'abord : un `.env` traine longtemps dans un repertoire, une
variable d'environnement est posee sciemment, pour une commande. Si le fichier
gagnait, un CI ou un shell qui surcharge volontairement les identifiants se
ferait silencieusement ignorer — le pire des echecs, celui qui ne dit rien.

La tolerance ensuite : un `.env` est tape a la main, souvent en collant une
valeur depuis une page web. Guillemets, `export ` en tete, espaces autour du
`=`, lignes vides et commentaires doivent passer sans bruit. En revanche on ne
touche pas a une quote au milieu d'un secret : elle en fait partie.
"""

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "wcl-ingest"))

import wcl_api  # noqa: E402

passed = failed = 0


def ok(condition, label):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   {label}")
    else:
        failed += 1
        print(f"  FAIL {label}")


print("parsing d'un .env")

parsed = wcl_api.parse_dotenv(
    "\n".join(
        [
            "# un commentaire",
            "",
            "WCL_CLIENT_ID=abc123",
            "export WCL_CLIENT_SECRET='sec ret'",
            '  QUOTED = "double"  ',
            "PAS_DE_EGAL",
            "MILIEU=aa'bb",
        ]
    )
)

ok(parsed.get("WCL_CLIENT_ID") == "abc123", "KEY=VALUE simple")
ok(parsed.get("WCL_CLIENT_SECRET") == "sec ret", "`export ` en tete et quotes simples")
ok(parsed.get("QUOTED") == "double", "espaces autour du = et quotes doubles")
ok("PAS_DE_EGAL" not in parsed, "ligne sans = ignoree")
ok(parsed.get("MILIEU") == "aa'bb", "quote au milieu conservee (elle fait partie du secret)")
ok("# un commentaire" not in parsed, "commentaire ignore")

print()
print("priorite environnement / fichier")


def with_state(env, dotenv, label, expected):
    saved_env = {k: os.environ.get(k) for k in wcl_api.CREDENTIAL_VARS}
    saved_loader = wcl_api.load_dotenv
    try:
        for key in wcl_api.CREDENTIAL_VARS:
            os.environ.pop(key, None)
        for key, value in env.items():
            os.environ[key] = value
        wcl_api.load_dotenv = lambda: dict(dotenv)
        try:
            got = wcl_api.load_credentials()
        except wcl_api.WCLError:
            got = "WCLError"
        ok(got == expected, label)
    finally:
        wcl_api.load_dotenv = saved_loader
        for key, value in saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


with_state(
    {"WCL_CLIENT_ID": "env-id", "WCL_CLIENT_SECRET": "env-sec"},
    {"WCL_CLIENT_ID": "file-id", "WCL_CLIENT_SECRET": "file-sec"},
    "l'environnement l'emporte sur le .env",
    ("env-id", "env-sec"),
)

with_state(
    {},
    {"WCL_CLIENT_ID": "file-id", "WCL_CLIENT_SECRET": "file-sec"},
    "le .env sert de repli quand l'environnement est vide",
    ("file-id", "file-sec"),
)

with_state(
    {"WCL_CLIENT_ID": "env-id"},
    {"WCL_CLIENT_SECRET": "file-sec"},
    "les deux sources se completent variable par variable",
    ("env-id", "file-sec"),
)

with_state(
    {"WCL_CLIENT_ID": ""},
    {"WCL_CLIENT_SECRET": "file-sec"},
    "une variable vide ne masque pas le .env",
    "WCLError",
)

with_state({}, {}, "rien nulle part : WCLError explicite", "WCLError")

print()
print(f"{passed} ok, {failed} echec(s)")
sys.exit(1 if failed else 0)
