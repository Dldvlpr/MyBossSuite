#!/usr/bin/env bash
# Genere les 6 .toc depuis tools/toc.template.
#
# Un seul .toc ne suffit pas : les clients classic cherchent un fichier suffixe
# par flavor. Le contenu est identique a `## Interface:` et a la liste de data
# pres, donc il est genere plutot que duplique a la main.
#
# Usage : tools/gen-toc.sh [--check]
#   --check : ne reecrit rien, sort en erreur si un .toc n'est pas a jour
#             (utilisable en CI / hook pre-commit).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/tools/toc.template"
VERSION="0.1.0"

# Bumper a chaque patch majeur du client concerne.
# suffixe:flavor:interface
FLAVORS=(
    "Vanilla:vanilla:11507"
    "TBC:tbc:20504"
    "Wrath:wrath:30403"
    "Cata:cata:40402"
    "Mists:mists:50500"
    "Mainline:retail:110200"
)

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

status=0

for entry in "${FLAVORS[@]}"; do
    IFS=":" read -r suffix flavor interface <<< "$entry"
    target="$ROOT/MyBossSuite_${suffix}.toc"

    data_files=""
    for dir in "Modules/BossTimer/Data/$flavor" "Modules/CDTracker/Data/$flavor"; do
        if [ -d "$ROOT/$dir" ]; then
            while IFS= read -r file; do
                data_files+="${file#"$ROOT"/}"$'\n'
            done < <(find "$ROOT/$dir" -type f -name '*.lua' | LC_ALL=C sort)
        fi
    done
    data_files="${data_files%$'\n'}"
    [ -z "$data_files" ] && data_files="# (aucune data pour ce flavor)"

    rendered="$(
        awk -v iface="$interface" -v flavor="$flavor" -v version="$VERSION" \
            -v data="$data_files" '
            {
                gsub(/@INTERFACE@/, iface)
                gsub(/@FLAVOR@/, flavor)
                gsub(/@VERSION@/, version)
                if ($0 == "@DATA_FILES@") { print data; next }
                print
            }' "$TEMPLATE"
    )"

    if [ "$CHECK" -eq 1 ]; then
        if ! printf '%s\n' "$rendered" | diff -q - "$target" >/dev/null 2>&1; then
            echo "obsolete : $(basename "$target")" >&2
            status=1
        fi
    else
        printf '%s\n' "$rendered" > "$target"
        echo "genere : $(basename "$target") (Interface $interface)"
    fi
done

exit "$status"
