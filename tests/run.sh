#!/usr/bin/env bash
# Verification complete hors du jeu :
#   1. syntaxe de tous les fichiers Lua, bibliotheques embarquees a part
#   2. suite headless sur 4 configurations de client
#   3. classement de l'ingestion WCL (heuristique des zones a fuir)
#   4. fusion a la regeneration (la data ecrite a la main doit survivre)
#   5. bornes de phase (une mesure fausse serait pire que pas de mesure)
#   6. inventaire WeakAuras (c'est lui qui decide si la phase 3b vaut le coup)
#   7. .toc a jour vis-a-vis de tools/gen-toc.sh
#
# Prerequis : lua5.1 (ou lua) et python3 dans le PATH.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

LUA="${LUA:-}"
if [ -z "$LUA" ]; then
    for candidate in lua5.1 lua5.4 lua luajit; do
        if command -v "$candidate" >/dev/null 2>&1; then LUA="$candidate"; break; fi
    done
fi
if [ -z "$LUA" ]; then
    echo "aucun interpreteur Lua trouve (installe lua5.1)" >&2
    exit 2
fi

status=0

echo "== syntaxe"
while IFS= read -r file; do
    if ! "$LUA" -e "assert(loadfile('$file'))" 2>/tmp/mbs-lua-err; then
        echo "  FAIL $file"
        sed 's/^/        /' /tmp/mbs-lua-err
        status=1
    fi
done < <(find Core Modules tests -name '*.lua' -not -path 'Modules/*/Libs/*' | LC_ALL=C sort)
[ "$status" -eq 0 ] && echo "  ok"

# Les bibliotheques embarquees sont du code tiers : on ne les corrige pas, on
# verifie seulement que la copie est intacte. Une erreur ici ne dit pas "bug
# dans MyBossSuite", elle dit "la copie est tronquee ou l'amont a change".
echo
echo "== bibliotheques embarquees (copie intacte)"
lib_status=0
while IFS= read -r file; do
    if ! "$LUA" -e "assert(loadfile('$file'))" 2>/tmp/mbs-lua-err; then
        echo "  FAIL $file (code tiers — cf. Modules/CDTracker/Libs/README.md)"
        sed 's/^/        /' /tmp/mbs-lua-err
        lib_status=1
        status=1
    fi
done < <(find Modules -path 'Modules/*/Libs/*' -name '*.lua' | LC_ALL=C sort)
[ "$lib_status" -eq 0 ] && echo "  ok"

echo
echo "== suite headless"
for variant in "" "--no-c-timer" "--retail" "--retail --no-c-timer"; do
    label="${variant:-classic + C_Timer}"
    # shellcheck disable=SC2086
    if output=$("$LUA" tests/run_tests.lua $variant 2>&1); then
        echo "  ok   [$label] $(printf '%s' "$output" | tail -n 1)"
    else
        echo "  FAIL [$label]"
        printf '%s\n' "$output" | grep -E "FAIL|echec" | sed 's/^/        /'
        status=1
    fi
done

echo
echo "== ingestion WCL (logique de classement, sans reseau)"
if output=$(python3 tests/test_wcl_alerts.py 2>&1); then
    echo "  ok   $(printf '%s' "$output" | tail -n 1)"
else
    printf '%s\n' "$output" | grep -E "FAIL|Error|Traceback" | sed 's/^/        /'
    status=1
fi

echo
echo "== ingestion WCL (fusion a la regeneration, sans reseau)"
if output=$(python3 tests/test_wcl_merge.py 2>&1); then
    echo "  ok   $(printf '%s' "$output" | tail -n 1)"
else
    printf '%s\n' "$output" | grep -E "FAIL|Error|Traceback" | sed 's/^/        /'
    status=1
fi

echo
echo "== ingestion WCL (bornes de phase, sans reseau)"
if output=$(python3 tests/test_wcl_phases.py 2>&1); then
    echo "  ok   $(printf '%s' "$output" | tail -n 1)"
else
    printf '%s\n' "$output" | grep -E "FAIL|Error|Traceback" | sed 's/^/        /'
    status=1
fi

echo
echo "== inventaire WeakAuras (parsing, sans reseau)"
if output=$(python3 tests/test_wa_extract.py 2>&1); then
    echo "  ok   $(printf '%s' "$output" | tail -n 1)"
else
    printf '%s\n' "$output" | grep -E "FAIL|Error|Traceback" | sed 's/^/        /'
    status=1
fi

echo
echo "== .toc"
if tools/gen-toc.sh --check >/dev/null 2>&1; then
    echo "  ok"
else
    echo "  FAIL — lance tools/gen-toc.sh"
    status=1
fi

echo
[ "$status" -eq 0 ] && echo "tout est vert." || echo "des verifications ont echoue."
exit "$status"
