#!/usr/bin/env python3
"""Tests du flux OAuth utilisateur (rapports archives), sans reseau ni navigateur.

Ce qui se teste ici, c'est tout ce qui entoure l'echange reseau — donc tout ce
qui peut casser en silence :

  * le `state` CSRF. Sans lui, n'importe quelle page ouverte dans le navigateur
    pourrait appeler le port local et injecter son propre code d'autorisation.
    Une redirection dont le state ne correspond pas doit etre REFUSEE, pas
    ignoree.
  * le couplage endpoint / identite. Un jeton utilisateur sur `/client` est
    refuse, et l'inverse aussi : `authenticate` doit fixer les deux ensemble.
  * la tolerance du cache. Un cache absent, tronque ou expire ne doit jamais
    faire echouer une ingestion — il doit juste ne pas etre utilise.
  * la detection du rapport archive, qui est ce qui transforme un message d'API
    obscur en une consigne actionnable.

L'echange HTTP lui-meme n'est pas teste : il demande un vrai serveur OAuth.
"""

import json
import sys
import time
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


def raises(fn, label):
    try:
        fn()
    except wcl_api.WCLError:
        ok(True, label)
        return
    ok(False, label)


print("redirection OAuth")

url = wcl_api.build_authorize_url("cid", 4480, "st4te")
ok("client_id=cid" in url, "l'URL d'autorisation porte le client_id")
ok("response_type=code" in url, "response_type=code")
ok("state=st4te" in url, "le state est transmis")
ok("scope=view-user-profile+view-private-reports" in url,
   "les deux scopes sont demandes (sans view-private-reports, le jeton est "
   "valide mais le contenu des rapports reste refuse)")
ok("redirect_uri=http%3A%2F%2Flocalhost%3A4480%2Fcallback" in url, "redirect_uri encodee")
ok(wcl_api.redirect_uri(4480) == "http://localhost:4480/callback", "redirect_uri lisible")

ok(wcl_api.extract_code("/callback?code=abc&state=st4te", "st4te") == "abc",
   "code extrait quand le state correspond")
raises(lambda: wcl_api.extract_code("/callback?code=abc&state=autre", "st4te"),
       "state qui ne correspond pas : refuse (CSRF)")
raises(lambda: wcl_api.extract_code("/callback?code=abc", "st4te"),
       "state absent : refuse")
raises(lambda: wcl_api.extract_code("/callback?error=access_denied&state=st4te", "st4te"),
       "refus de l'utilisateur : erreur explicite")
raises(lambda: wcl_api.extract_code("/callback?state=st4te", "st4te"),
       "redirection sans code : erreur explicite")

print()
print("cache de jeton")

cache = ROOT / wcl_api.TOKEN_CACHE_NAME
saved = cache.read_text(encoding="utf-8") if cache.exists() else None
now = 1_000_000.0
try:
    full = list(wcl_api.SCOPES)

    cache.write_text(json.dumps({"access_token": "tok", "expires_at": now + 3600,
                                 "scopes": full}), encoding="utf-8")
    ok(wcl_api.load_cached_token(now) == "tok", "jeton encore valide : reutilise")

    cache.write_text(json.dumps({"access_token": "tok", "expires_at": now + 10,
                                 "scopes": full}), encoding="utf-8")
    ok(wcl_api.load_cached_token(now) == "", "jeton qui expire dans 10 s : rejete (marge)")

    cache.write_text(json.dumps({"access_token": "tok", "expires_at": now - 1,
                                 "scopes": full}), encoding="utf-8")
    ok(wcl_api.load_cached_token(now) == "", "jeton expire : rejete")

    # Le cas qui a mordu en vrai : un jeton obtenu avant l'ajout des scopes est
    # valide et non expire, donc indefiniment reutilisable — et refuse a chaque
    # requete. Il doit etre traite comme absent, pas comme utilisable.
    cache.write_text(json.dumps({"access_token": "tok", "expires_at": now + 3600}),
                     encoding="utf-8")
    ok(wcl_api.load_cached_token(now) == "", "jeton sans scopes enregistres : rejete")
    ok(wcl_api.load_refresh_token() == "", "refresh sans scopes : rejete (memes scopes au retour)")

    cache.write_text(json.dumps({"access_token": "tok", "expires_at": now + 3600,
                                 "scopes": ["view-user-profile"],
                                 "refresh_token": "r"}), encoding="utf-8")
    ok(wcl_api.load_cached_token(now) == "", "jeton aux scopes incomplets : rejete")
    ok(wcl_api.load_refresh_token() == "", "refresh aux scopes incomplets : rejete")

    cache.write_text("{ ceci n'est pas du json", encoding="utf-8")
    ok(wcl_api.load_cached_token(now) == "", "cache corrompu : traite comme absent, pas d'exception")
    ok(wcl_api.load_refresh_token() == "", "refresh d'un cache corrompu : vide, pas d'exception")

    cache.unlink()
    ok(wcl_api.load_cached_token(now) == "", "cache absent : vide, pas d'exception")

    wcl_api.save_cached_token({"access_token": "a", "refresh_token": "r", "expires_in": 3600}, now)
    written = json.loads(cache.read_text(encoding="utf-8"))
    ok(written["expires_at"] == now + 3600, "expires_in converti en date absolue")
    ok(sorted(written["scopes"]) == sorted(wcl_api.SCOPES), "scopes demandes enregistres")
    ok(wcl_api.load_refresh_token() == "r", "refresh_token relu")
finally:
    if saved is None:
        cache.unlink(missing_ok=True)
    else:
        cache.write_text(saved, encoding="utf-8")

print()
print("couplage endpoint / identite")

before = wcl_api.ACTIVE_API_URL
saved_get = wcl_api.get_token
saved_user = wcl_api.get_user_token
try:
    wcl_api.get_token = lambda *a, **k: "client-token"
    wcl_api.get_user_token = lambda *a, **k: "user-token"

    token = wcl_api.authenticate("cid", "sec", user_auth=False)
    ok(token == "client-token" and wcl_api.ACTIVE_API_URL == wcl_api.API_URL,
       "sans --user-auth : cle applicative + endpoint /client")

    token = wcl_api.authenticate("cid", "sec", user_auth=True)
    ok(token == "user-token" and wcl_api.ACTIVE_API_URL == wcl_api.USER_API_URL,
       "avec --user-auth : jeton utilisateur + endpoint /user")
finally:
    wcl_api.get_token = saved_get
    wcl_api.get_user_token = saved_user
    wcl_api.ACTIVE_API_URL = before

print()
print("lecture des scopes accordes (JWT)")

import base64  # noqa: E402 - local au bloc de diagnostic


def jwt(body):
    raw = base64.urlsafe_b64encode(json.dumps(body).encode()).decode().rstrip("=")
    return "entete.%s.signature" % raw


ok(wcl_api.token_scopes(jwt({"scopes": ["view-user-profile", "view-private-reports"]}))
   == ["view-user-profile", "view-private-reports"], "scopes lus dans le corps du JWT")
ok(wcl_api.token_scopes(jwt({"scope": "a b"})) == ["a", "b"], "forme chaine acceptee")
ok(wcl_api.token_scopes(jwt({})) == [], "JWT sans scopes : liste vide")
ok(wcl_api.token_scopes("pas-un-jwt") == [], "jeton opaque : liste vide, pas d'exception")
ok(wcl_api.token_scopes("a.!!!.c") == [], "corps illisible : liste vide, pas d'exception")

print()
print("detection du rapport archive")

archived = [{"message": "This report has been archived. Subscribing users can access "
                        "the report content via the /user API endpoint."}]
ok(wcl_api.is_archived_error(archived), "message d'archive reconnu")
ok(not wcl_api.is_archived_error([{"message": "Field 'foo' is not defined"}]),
   "une erreur GraphQL ordinaire n'est pas prise pour une archive")

print()
print(f"{passed} ok, {failed} echec(s)")
sys.exit(1 if failed else 0)
