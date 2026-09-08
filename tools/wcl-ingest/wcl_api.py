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
import urllib.error
import urllib.parse
import urllib.request

TOKEN_URL = "https://www.warcraftlogs.com/oauth/token"
API_URL = "https://www.warcraftlogs.com/api/v2/client"

FLAVORS = ["vanilla", "tbc", "wrath", "cata", "mists", "retail"]


class WCLError(RuntimeError):
    pass


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
query($code: String!, $fight: Int!, $start: Float) {
  reportData {
    report(code: $code) {
      events(
        dataType: %(data_type)s
        hostilityType: %(hostility)s
        fightIDs: [$fight]
        startTime: $start
        limit: 10000
      ) {
        data
        nextPageTimestamp
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
                 data_type: str, hostility: str = "Enemies"):
    """Pagine `events` jusqu'au bout — un pull long depasse la limite d'une page."""
    query = EVENTS_QUERY % {"data_type": data_type, "hostility": hostility}
    events, cursor = [], start
    while cursor is not None:
        data = graphql(token, query, {"code": code, "fight": fight_id, "start": cursor})
        block = data["reportData"]["report"]["events"]
        events.extend(block["data"] or [])
        cursor = block.get("nextPageTimestamp")
    return events


def parse_report_arg(item: str):
    """`CODE:FIGHT` -> (code, fight). Leve WCLError sur un format invalide."""
    code, _, fight = item.partition(":")
    if not code or not fight.isdigit():
        raise WCLError(f"format attendu CODE:FIGHT, recu {item!r}")
    return code, int(fight)
