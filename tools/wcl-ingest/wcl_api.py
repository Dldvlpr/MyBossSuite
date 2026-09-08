#!/usr/bin/env python3
"""Transport WarcraftLogs v2 partage par les ingesteurs.

Extrait de `wcl_ingest.py` quand un deuxieme consommateur est apparu
(`wcl_alerts.py`) : OAuth, GraphQL, decouverte de logs et pagination d'events
sont identiques quelle que soit la data qu'on en tire. Le reste — quels events
on demande et comment on les agrege — reste propre a chaque script.
"""

from __future__ import annotations

import base64
import http.server
import json
import os
import pathlib
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

TOKEN_URL = "https://www.warcraftlogs.com/oauth/token"
AUTHORIZE_URL = "https://www.warcraftlogs.com/oauth/authorize"

# Deux endpoints, deux authentifications. `/client` suffit pour tout ce qui est
# public et se contente du couple ID/secret. `/user` est le seul a servir les
# rapports ARCHIVES (plus de 2 ans), et il exige un jeton d'UTILISATEUR : c'est
# l'abonnement du compte qui ouvre les archives, pas la cle applicative.
API_URL = "https://www.warcraftlogs.com/api/v2/client"
USER_API_URL = "https://www.warcraftlogs.com/api/v2/user"

# L'endpoint reellement utilise pour la session en cours. Fixe une fois par
# `authenticate()` : les appelants de `graphql` n'ont pas a savoir sous quelle
# identite ils tournent.
ACTIVE_API_URL = API_URL

# Doit correspondre A L'IDENTIQUE a une redirect URL enregistree sur le client
# API (https://www.warcraftlogs.com/api/clients/). OAuth compare la chaine
# entiere, port et chemin compris.
DEFAULT_REDIRECT_PORT = 4480
REDIRECT_PATH = "/callback"

# Sans scope demande, l'autorisation aboutit quand meme et rend un jeton
# parfaitement valide — qui se fait ensuite refuser le CONTENU des rapports,
# sans 401 ni rien qui pointe vers la cause. `view-private-reports` est celui
# qui compte ici ; `view-user-profile` l'accompagne pour pouvoir interroger le
# compte (cf. --whoami, seul moyen de distinguer un scope manquant d'un
# abonnement non pris en compte).
SCOPES = ("view-user-profile", "view-private-reports")

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


# ----------------------------------------------------------------------------
# Jeton utilisateur (rapports archives)
# ----------------------------------------------------------------------------

# Le jeton utilisateur et surtout son refresh_token sont des secrets : meme
# emplacement de confiance que le `.env`, meme exclusion du depot.
TOKEN_CACHE_NAME = ".wcl-token.json"

# Marge avant expiration : un jeton valide 30 s ne survivra pas a une ingestion
# de dix logs. Mieux vaut le rafraichir une requete trop tot que planter au
# milieu d'un passage.
TOKEN_EXPIRY_MARGIN = 120


def token_cache_path() -> pathlib.Path:
    return DOTENV_DIRS[0] / TOKEN_CACHE_NAME


def load_cached_token(now=None) -> str:
    """Rend un access_token encore valide, ou "" — jamais une exception.

    Un cache illisible, tronque ou d'une version anterieure ne doit pas bloquer
    l'ingestion : on le traite comme absent et on refait le flux complet.
    """
    now = time.time() if now is None else now
    try:
        data = json.loads(token_cache_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    if not isinstance(data, dict):
        return ""
    token = data.get("access_token") or ""
    expires_at = data.get("expires_at") or 0
    if not isinstance(expires_at, (int, float)):
        return ""
    # Un jeton obtenu avec moins de scopes que ceux demandes aujourd'hui est
    # inutilisable : il vaut mieux redemander une autorisation que rejouer en
    # boucle un jeton qui se fera refuser le contenu.
    if sorted(data.get("scopes") or []) != sorted(SCOPES):
        return ""
    if token and expires_at - TOKEN_EXPIRY_MARGIN > now:
        return token
    return ""


def load_refresh_token() -> str:
    try:
        data = json.loads(token_cache_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    if not isinstance(data, dict):
        return ""
    if sorted(data.get("scopes") or []) != sorted(SCOPES):
        return ""  # rafraichir ne rendrait qu'un jeton aux memes scopes insuffisants
    return data.get("refresh_token") or ""


def save_cached_token(payload: dict, now=None) -> None:
    """Ecrit le cache en 0600. Un echec d'ecriture n'est pas fatal.

    Ne pas pouvoir cacher le jeton coute une re-autorisation au prochain
    passage ; ca ne justifie pas de faire echouer une ingestion qui, elle, a
    tout ce qu'il lui faut.
    """
    now = time.time() if now is None else now
    data = {
        "access_token": payload.get("access_token", ""),
        "refresh_token": payload.get("refresh_token", ""),
        "expires_at": now + float(payload.get("expires_in") or 0),
        # WCL ne renvoie pas les scopes accordes (`scope` est null) : on note
        # ceux qu'on a DEMANDES, ce qui suffit a detecter un cache perime par
        # un changement de cette liste.
        "scopes": list(SCOPES),
    }
    path = token_cache_path()
    try:
        path.write_text(json.dumps(data, indent=2), encoding="utf-8")
        os.chmod(path, 0o600)
    except OSError:
        pass


def _post_token(fields: dict) -> dict:
    data = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(TOKEN_URL, data=data)
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = " : " + exc.read().decode("utf-8", "replace")[:300]
        except Exception:  # noqa: BLE001 - le detail est un bonus, jamais un bloqueur
            pass
        raise WCLError("echange OAuth refuse (%s)%s" % (exc.code, detail)) from exc
    except urllib.error.URLError as exc:
        raise WCLError("echange OAuth injoignable : %s" % exc.reason) from exc


def redirect_uri(port: int) -> str:
    return "http://localhost:%d%s" % (port, REDIRECT_PATH)


def build_authorize_url(client_id: str, port: int, state: str) -> str:
    query = urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": redirect_uri(port),
        "response_type": "code",
        "state": state,
        "scope": " ".join(SCOPES),
    })
    return "%s?%s" % (AUTHORIZE_URL, query)


def extract_code(raw_path: str, expected_state: str) -> str:
    """Valide la redirection et rend le code d'autorisation.

    Le `state` n'est pas une formalite : sans lui, n'importe quelle page ouverte
    dans le navigateur pourrait appeler le port local et injecter son propre
    code d'autorisation.
    """
    parsed = urllib.parse.urlparse(raw_path)
    params = urllib.parse.parse_qs(parsed.query)
    error = (params.get("error") or [""])[0]
    if error:
        description = (params.get("error_description") or [""])[0]
        raise WCLError(("autorisation refusee : %s %s" % (error, description)).strip())
    if (params.get("state") or [""])[0] != expected_state:
        raise WCLError("state OAuth invalide : la redirection ne vient pas de cette session.")
    code = (params.get("code") or [""])[0]
    if not code:
        raise WCLError("aucun code d'autorisation dans la redirection.")
    return code


def _await_authorization(client_id: str, port: int) -> str:
    """Ouvre le navigateur et attend la redirection sur le port local."""
    state = secrets.token_urlsafe(24)
    url = build_authorize_url(client_id, port, state)
    captured = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 - impose par BaseHTTPRequestHandler
            try:
                captured["code"] = extract_code(self.path, state)
                body = "Autorisation accordee. Tu peux fermer cet onglet."
            except WCLError as exc:
                captured["error"] = exc
                body = "Echec : %s" % exc
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))

        def log_message(self, *args):
            pass  # le serveur est un detail d'implementation, pas une sortie utile

    try:
        server = http.server.HTTPServer(("localhost", port), Handler)
    except OSError as exc:
        raise WCLError(
            "port %d indisponible (%s) : ferme ce qui l'occupe, ou choisis un autre "
            "port avec --auth-port — en pensant a l'enregistrer aussi comme redirect "
            "URL sur https://www.warcraftlogs.com/api/clients/." % (port, exc)
        ) from exc

    print("Autorisation WarcraftLogs necessaire (rapports archives).")
    print("Si le navigateur ne s'ouvre pas, va sur :")
    print("    %s" % url)
    try:
        webbrowser.open(url)
    except Exception:  # noqa: BLE001 - l'URL est affichee, l'ouverture est un confort
        pass

    with server:
        server.timeout = 300
        server.handle_request()

    if "error" in captured:
        raise captured["error"]
    if "code" not in captured:
        raise WCLError("aucune redirection recue en 5 minutes : autorisation abandonnee.")
    return captured["code"]


def get_user_token(client_id: str, client_secret: str, port: int = DEFAULT_REDIRECT_PORT) -> str:
    """Jeton utilisateur, du moins cher au plus cher : cache, refresh, navigateur."""
    cached = load_cached_token()
    if cached:
        return cached

    refresh = load_refresh_token()
    if refresh:
        try:
            payload = _post_token({
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": client_id,
                "client_secret": client_secret,
            })
            save_cached_token(payload)
            return payload["access_token"]
        except WCLError:
            pass  # refresh perime ou revoque : on retombe sur le flux complet

    code = _await_authorization(client_id, port)
    payload = _post_token({
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect_uri(port),
        "client_id": client_id,
        "client_secret": client_secret,
    })
    save_cached_token(payload)
    return payload["access_token"]


def authenticate(client_id: str, client_secret: str, user_auth: bool = False,
                 port: int = DEFAULT_REDIRECT_PORT) -> str:
    """Point d'entree unique : choisit le flux ET l'endpoint qui va avec.

    Les deux vont ensemble — un jeton utilisateur sur `/client` est refuse, et
    l'inverse aussi. Les lier ici evite d'avoir a y penser ailleurs.
    """
    global ACTIVE_API_URL
    if user_auth:
        ACTIVE_API_URL = USER_API_URL
        return get_user_token(client_id, client_secret, port)
    ACTIVE_API_URL = API_URL
    return get_token(client_id, client_secret)


ARCHIVED_HINT = (
    "Ce rapport est archive (plus de 2 ans). Les archives ne sont servies que par "
    "l'endpoint /user, avec un compte abonne : relance la commande avec --user-auth "
    "(un navigateur s'ouvrira une fois pour autoriser l'acces).\n"
    "La redirect URL de ton client API doit valoir exactement %s — "
    "https://www.warcraftlogs.com/api/clients/"
)


def is_archived_error(errors) -> bool:
    """Reconnait l'erreur "rapport archive" parmi les erreurs GraphQL.

    Compare sur le texte parce que l'API ne donne pas de code machine pour ce
    cas. Le test reste large (un mot, insensible a la casse) : rater la
    detection ne coute qu'un message d'erreur moins clair, jamais un faux
    positif dommageable.
    """
    return "archived" in json.dumps(errors).lower()


def graphql(token: str, query: str, variables: dict) -> dict:
    payload = json.dumps({"query": query, "variables": variables}).encode()
    request = urllib.request.Request(ACTIVE_API_URL, data=payload)
    request.add_header("Authorization", "Bearer " + token)
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = json.load(response)
    except urllib.error.HTTPError as exc:
        raise WCLError("API WarcraftLogs : HTTP %s" % exc.code) from exc
    except urllib.error.URLError as exc:
        raise WCLError("API WarcraftLogs injoignable : %s" % exc.reason) from exc
    if "errors" in body:
        errors = body["errors"]
        # Le message brut de l'API ne dit pas quoi FAIRE : il mentionne
        # l'endpoint /user sans dire qu'il demande une autre authentification.
        if is_archived_error(errors) and ACTIVE_API_URL != USER_API_URL:
            raise WCLError(ARCHIVED_HINT % redirect_uri(DEFAULT_REDIRECT_PORT))
        raise WCLError(json.dumps(errors, indent=2))
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
query($code: String!, $fight: Int!, $start: Float, $end: Float, $filter: String) {
  reportData {
    report(code: $code) {
      events(
        dataType: %(data_type)s
        hostilityType: %(hostility)s
        fightIDs: [$fight]
        startTime: $start
        endTime: $end
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


def token_scopes(token: str) -> list:
    """Lit les scopes ACCORDES dans le corps du JWT. Diagnostic uniquement.

    WCL ne renvoie pas les scopes dans la reponse OAuth (`scope` est null) : le
    seul endroit ou l'accorde est lisible, c'est la charge utile du jeton. On la
    decode sans verifier la signature — on ne fait confiance a rien ici, on
    AFFICHE, pour distinguer "scope refuse" de "droit refuse".
    """
    parts = token.split(".")
    if len(parts) < 2:
        return []
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)  # base64url sans padding
    try:
        body = json.loads(base64.urlsafe_b64decode(payload.encode()))
    except Exception:  # noqa: BLE001 - un jeton illisible n'est pas une panne
        return []
    scopes = body.get("scopes") or body.get("scope") or []
    if isinstance(scopes, str):
        scopes = scopes.split()
    return list(scopes)


REPORT_FIGHTS_QUERY = """
query($code: String!) {
  reportData {
    report(code: $code) {
      title
      fights { id name encounterID startTime endTime kill }
    }
  }
}
"""


def fetch_fights(token: str, code: str):
    """Rend (titre, [combats]) — de quoi choisir un fightID sans quitter le terminal.

    Le numero de combat ne se devine pas : il ne se lit ni dans le code du
    rapport, ni dans l'URL quand elle dit `fight=last`. Le demander a
    l'utilisateur sans lui donner le moyen de le trouver, c'est le renvoyer
    fouiller l'interface web pour une valeur que l'API sait donner.
    """
    data = graphql(token, REPORT_FIGHTS_QUERY, {"code": code})
    report = (data.get("reportData") or {}).get("report") or {}
    return report.get("title") or "", report.get("fights") or []


CURRENT_USER_QUERY = """
query {
  userData {
    currentUser { id name }
  }
}
"""


def fetch_current_user(token: str) -> dict:
    """Rend le compte associe au jeton. Diagnostic, pas ingestion.

    Utile parce que deux causes tres differentes donnent la meme erreur sur les
    archives : un scope manquant (le jeton ne represente personne) et un
    abonnement non pris en compte (il represente bien le compte, mais le compte
    n'a pas le droit). Cette requete les separe.
    """
    data = graphql(token, CURRENT_USER_QUERY, {})
    return (data.get("userData") or {}).get("currentUser") or {}


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


def fetch_events(token: str, code: str, fight_id: int, start: float, end: float,
                 data_type: str, hostility: str = "Enemies",
                 filter_expression: str | None = None):
    """Pagine `events` jusqu'au bout — un pull long depasse la limite d'une page.

    Les DEUX bornes sont obligatoires : `fightIDs` seul ne suffit pas a delimiter
    la fenetre, et une requete sans `endTime` rend zero evenement — sans erreur,
    ce qui la rend indiscernable d'un combat vide.

    `filter_expression` est evalue par WCL, donc il economise le transfert et
    pas seulement le traitement : sur les degats d'un raid entier, la difference
    entre tout rapatrier et ne demander que la cible utile se compte en dizaines
    de pages.
    """
    query = EVENTS_QUERY % {"data_type": data_type, "hostility": hostility}
    events, cursor = [], start
    while cursor is not None:
        data = graphql(token, query, {"code": code, "fight": fight_id,
                                      "start": cursor, "end": end,
                                      "filter": filter_expression})
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
