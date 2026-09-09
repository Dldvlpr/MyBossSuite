#!/usr/bin/env python3
"""Tests de la fenetre temporelle des requetes `events`, sans reseau.

Pourquoi ce test existe : la requete envoyait `startTime` sans `endTime`. WCL
accepte, ne signale rien, et rend ZERO evenement. Cote appelant, c'est
indiscernable d'un combat ou personne n'a caste — le message d'erreur accusait
donc le npcId, et l'ingestion n'a jamais rien produit. Un echec muet qui designe
une fausse cause coute bien plus cher qu'une erreur franche.

On verifie donc que les deux bornes partent, sur tous les chemins, et que la
pagination ne perd pas la borne de fin en cours de route.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "wcl-ingest"))
sys.path.insert(0, str(ROOT / "tools" / "wa-extract"))

import wcl_api  # noqa: E402
import wcl_ingest  # noqa: E402

passed = failed = 0


def ok(condition, label):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   {label}")
    else:
        failed += 1
        print(f"  FAIL {label}")


print("la requete declare les deux bornes")

ok("$start: Float" in wcl_api.EVENTS_QUERY, "startTime declare")
ok("$end: Float" in wcl_api.EVENTS_QUERY, "endTime declare")
ok("startTime: $start" in wcl_api.EVENTS_QUERY, "startTime transmis")
ok("endTime: $end" in wcl_api.EVENTS_QUERY, "endTime transmis")

print()
print("les deux bornes arrivent jusqu'a l'API")

calls = []


def fake_graphql(token, query, variables):
    calls.append(dict(variables))
    # Deux pages, pour verifier que la borne de fin survit a la pagination.
    if len(calls) == 1:
        return {"reportData": {"report": {"events": {"data": [{"n": 1}],
                                                     "nextPageTimestamp": 500.0}}}}
    return {"reportData": {"report": {"events": {"data": [{"n": 2}],
                                                 "nextPageTimestamp": None}}}}


saved = wcl_api.graphql
wcl_api.graphql = fake_graphql
try:
    events = wcl_api.fetch_events("tok", "CODE", 1, 100.0, 900.0, "Casts", "Enemies")
    ok(len(events) == 2, "les pages sont concatenees")
    ok(all(call["end"] == 900.0 for call in calls),
       "endTime identique sur toutes les pages (la pagination ne deplace que le debut)")
    ok([call["start"] for call in calls] == [100.0, 500.0],
       "startTime avance au curseur de page")

    calls.clear()
    wcl_ingest.fetch_casts("tok", "CODE", 1, 10.0, 20.0)
    ok(calls and calls[0]["start"] == 10.0 and calls[0]["end"] == 20.0,
       "fetch_casts transmet les deux bornes")

    calls.clear()
    wcl_ingest.fetch_boss_damage("tok", "CODE", 1, 10.0, 20.0, [])
    ok(calls and calls[0]["start"] == 10.0 and calls[0]["end"] == 20.0,
       "fetch_boss_damage transmet les deux bornes")
finally:
    wcl_api.graphql = saved

print()
print(f"{passed} ok, {failed} echec(s)")
sys.exit(1 if failed else 0)
