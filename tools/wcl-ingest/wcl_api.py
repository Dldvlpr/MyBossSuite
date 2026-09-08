#!/usr/bin/env python3
"""Transport WarcraftLogs v2 partage par les ingesteurs.

Extrait de `wcl_ingest.py` quand un deuxieme consommateur est apparu
(`wcl_alerts.py`) : OAuth, GraphQL, decouverte de logs et pagination d'events
sont identiques quelle que soit la data qu'on en tire. Le reste — quels events
on demande et comment on les agrege — reste propre a chaque script.
"""

from __future__ import annotations

import base64
import json
import os
import pathlib
import urllib.error
import urllib.parse
import urllib.request

TOKEN_URL = "https://www.warcraftlogs.com/oauth/token"
API_URL = "https://www.warcraftlogs.com/api/v2/client"

FLAVORS = ["vanilla", "tbc", "wrath", "cata", "mists", "retail"]


class WCLError(RuntimeError):
    pass


# ----------------------------------------------------------------------------
# Identifiants
# ----------------------------------------------------------------------------

# Un secret n'a rien a faire dans le depot : il se lit dans l'environnement, ou
# dans un `.env` non versionne. Le fichier est un CONFORT, pas une deuxieme
# source de verite — l'environnement garde la priorite, pour qu'un `.env` oublie
# ne prenne jamais le pas sur ce qu'un CI ou un shell a explicitement pose.
CREDENTIAL_VARS = ("WCL_CLIENT_ID", "WCL_CLIENT_SECRET")

# Cherche a cote du depot d'abord, puis dans le repertoire courant : lancer les
# scripts depuis la racine est le cas nominal, mais on ne l'impose pas.
DOTENV_DIRS = (
    pathlib.Path(__file__).resolve().parents[2],
    pathlib.Path.cwd(),
)


def parse_dotenv(text: str) -> dict:
    """Lit un `.env` minimal : KEY=VALUE, un par ligne.

    Volontairement pauvre — pas d'interpolation, pas de multi-ligne. Un `.env`
    qui aurait besoin de plus serait un fichier de config, et un fichier de
    config n'a pas sa place ici. `export ` en tete est tolere pour qu'un meme
    fichier serve aussi a `source .env` sous bash.
    """
    values = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        value = value.strip()
        # Les guillemets sont retires seulement s'ils encadrent la valeur : un
        # secret peut legitimement contenir une quote au milieu.
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def load_dotenv() -> dict:
    """Fusionne les `.env` trouves. Un fichier illisible est ignore en silence.

    Silencieux parce qu'un `.env` absent est le cas normal (l'environnement
    suffit) : c'est `load_credentials` qui parle quand il manque vraiment
    quelque chose, avec un message qui couvre les deux sources a la fois.
    """
    values = {}
    seen = set()
    for directory in DOTENV_DIRS:
        path = (directory / ".env").resolve()
        if path in seen:
            continue
        seen.add(path)
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        values.update(parse_dotenv(text))
    return values


def load_credentials() -> tuple:
    """Rend (client_id, client_secret), ou leve WCLError en expliquant ou les mettre."""
    found = {name: os.environ.get(name) or "" for name in CREDENTIAL_VARS}
    if not all(found.values()):
        from_file = load_dotenv()
        for name in CREDENTIAL_VARS:
            if not found[name]:
                found[name] = (from_file.get(name) or "").strip()

    missing = [name for name in CREDENTIAL_VARS if not found[name]]
    if missing:
        raise WCLError(
            "%s manquant(s).\n"
            "Cree un client API sur https://www.warcraftlogs.com/api/clients/, puis\n"
            "soit un fichier `.env` a la racine du depot (non versionne) :\n"
            "    WCL_CLIENT_ID=...\n"
            "    WCL_CLIENT_SECRET=...\n"
            "soit des variables d'environnement (bash : `export WCL_CLIENT_ID=...`,\n"
            "PowerShell : `$env:WCL_CLIENT_ID = '...'`)."
            % " / ".join(missing)
        )
    return found[CREDENTIAL_VARS[0]], found[CREDENTIAL_VARS[1]]


# ----------------------------------------------------------------------------
# Transport
# ----------------------------------------------------------------------------

def get_token(client_id: str, client_secret: str) -> str:
    data = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
    request = urllib.request.Request(TOKEN_URL, data=data)
    credentials = f"{client_id}:{client_secret}".encode()
    request.add_header("Authorization", "Basic " + base64.b64encode(credentials).decode())
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)["access_token"]
    except urllib.error.HTTPError as exc:
        raise WCLError(
            f"OAuth refuse ({exc.code}) : verifie WCL_CLIENT_ID / WCL_CLIENT_SECRET"
        ) from exc


def graphql(token: str, query: str, variables: dict) -> dict:
    payload = json.dumps({"query": query, "variables": variables}).encode()
    request = urllib.request.Request(API_URL, data=payload)
    request.add_header("Authorization", "Bearer " + token)
    request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=60) as response:
        body = json.load(response)
    if "errors" in body:
        raise WCLError(json.dumps(body["errors"], indent=2))
    return body["data"]


# ----------------------------------------------------------------------------
# Requetes communes
# ----------------------------------------------------------------------------

RANKINGS_QUERY = """
query($encounterId: Int!, $partition: Int) {
  worldData {
    encounter(id: $encounterId) {
      name
      fightRankings(metric: speed, partition: $partition)
    }
  }
}
"""

FIGHT_QUERY = """
query($code: String!, $fight: Int!) {
  reportData {
    report(code: $code) {
      fights(fightIDs: [$fight]) {
        id
        startTime
        endTime
        encounterID
        name
        friendlyPlayers
      }
      masterData {
        actors { id gameID name type subType }
        abilities { gameID name }
      }
    }
  }
}
"""

# `dataType` et `hostilityType` sont injectes en dur plutot que passes en
# variables : ce sont des enums GraphQL, pas des String, et les parametrer
# demanderait une query par combinaison.
EVENTS_QUERY = """
query($code: String!, $fight: Int!, $start: Float, $filter: String) {
  reportData {
    report(code: $code) {
      events(
        dataType: %(data_type)s
        hostilityType: %(hostility)s
        fightIDs: [$fight]
        startTime: $start
        filterExpression: $filter
        limit: 10000
      ) {
        data
        nextPageTimestamp
      }
    }
  }
}
"""

# Bornes de phase telles que WarcraftLogs les a segmentees. Requete separee de
# FIGHT_QUERY expres : la couverture de `phaseTransitions` hors retail n'est pas
# garantie, et une ingestion classic ne doit pas tomber parce qu'un champ
# facultatif manque. Ici l'echec se degrade en "phases non situees".
PHASES_QUERY = """
query($code: String!, $fight: Int!) {
  reportData {
    report(code: $code) {
      fights(fightIDs: [$fight]) {
        id
        phaseTransitions { id startTime }
      }
      phases {
        encounterID
        phases { id name isIntermission }
      }
    }
  }
}
"""


def discover_reports(token: str, encounter_id: int, limit: int, partition: int | None):
    """Retourne (nom de la rencontre, [(code, fightID), ...]) depuis le classement."""
    data = graphql(token, RANKINGS_QUERY, {"encounterId": encounter_id, "partition": partition})
    encounter = data["worldData"]["encounter"]
    if not encounter:
        raise WCLError(f"rencontre {encounter_id} inconnue")
    rankings = encounter["fightRankings"] or {}
    out = []
    for ranking in rankings.get("rankings", [])[:limit]:
        report = ranking.get("report") or {}
        code, fight = report.get("code"), report.get("fightID")
        if code and fight:
            out.append((code, int(fight)))
    return encounter["name"], out


def fetch_fight(token: str, code: str, fight_id: int):
    """Retourne (fight, actors indexes par id du rapport, noms de sorts par gameID).

    Les noms de sorts ne servent qu'aux commentaires des fichiers generes : la
    data reste indexee par spellId, jamais par nom (un nom est localise)."""
    data = graphql(token, FIGHT_QUERY, {"code": code, "fight": fight_id})
    report = data["reportData"]["report"]
    fights = report["fights"]
    if not fights:
        raise WCLError(f"combat {fight_id} absent du rapport {code}")
    master = report["masterData"] or {}
    actors = {a["id"]: a for a in (master.get("actors") or [])}
    abilities = {a["gameID"]: a.get("name") for a in (master.get("abilities") or [])}
    return fights[0], actors, abilities


def fetch_events(token: str, code: str, fight_id: int, start: float,
                 data_type: str, hostility: str = "Enemies",
                 filter_expression: str | None = None):
    """Pagine `events` jusqu'au bout — un pull long depasse la limite d'une page.

    `filter_expression` est evalue par WCL, donc il economise le transfert et
    pas seulement le traitement : sur les degats d'un raid entier, la difference
    entre tout rapatrier et ne demander que la cible utile se compte en dizaines
    de pages.
    """
    query = EVENTS_QUERY % {"data_type": data_type, "hostility": hostility}
    events, cursor = [], start
    while cursor is not None:
        data = graphql(token, query, {"code": code, "fight": fight_id,
                                      "start": cursor, "filter": filter_expression})
        block = data["reportData"]["report"]["events"]
        events.extend(block["data"] or [])
        cursor = block.get("nextPageTimestamp")
    return events


def fetch_phase_transitions(token: str, code: str, fight_id: int):
    """Retourne ([(id de phase, startTime ms), ...], {id: nom}).

    Ne leve jamais : `phaseTransitions` est renseigne par WarcraftLogs sur les
    rencontres qu'il sait decouper, ce qui n'est pas le cas partout hors retail.
    Une absence n'est pas une erreur, c'est juste une source en moins — la
    detection par la data du boss (seuils de vie, casts) prend alors le relais.
    """
    try:
        data = graphql(token, PHASES_QUERY, {"code": code, "fight": fight_id})
    except (WCLError, urllib.error.URLError):
        return [], {}
    report = data.get("reportData", {}).get("report") or {}
    fights = report.get("fights") or []
    if not fights:
        return [], {}
    transitions = [
        (int(t["id"]), float(t["startTime"]))
        for t in (fights[0].get("phaseTransitions") or [])
    ]
    transitions.sort(key=lambda item: item[1])

    names = {}
    for entry in (report.get("phases") or []):
        for phase in (entry.get("phases") or []):
            names.setdefault(int(phase["id"]), phase.get("name"))
    return transitions, names


def parse_report_arg(item: str):
    """`CODE:FIGHT` -> (code, fight). Leve WCLError sur un format invalide."""
    code, _, fight = item.partition(":")
    if not code or not fight.isdigit():
        raise WCLError(f"format attendu CODE:FIGHT, recu {item!r}")
    return code, int(fight)
