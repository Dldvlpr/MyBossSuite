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

# Bumper a chaque patch majeur du client concerne. Un numero depasse rend
# l'addon "obsolete", donc desactive tant que l'option "charger les addons
# obsoletes" n'est pas cochee. Plusieurs numeros separes par des virgules sont
# acceptes quand un meme flavor a plusieurs builds en vie (Wrath : 30405 et le
# build 38002 que DBM et BigWigs declarent aussi).
# Reference : les .toc de DBM-Core, releves le 2026-09-08.
# suffixe:flavor:interface
FLAVORS=(
    "Vanilla:vanilla:11509"
    "TBC:tbc:20506"
    "Wrath:wrath:30405, 38002"
    "Cata:cata:40402"
    "Mists:mists:50504"
    "Mainline:retail:120100"
)

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

status=0

for entry in "${FLAVORS[@]}"; do
    IFS=":" read -r suffix flavor interface <<< "$entry"
    target="$ROOT/MyBossSuite_${suffix}.toc"

    # Les bibliotheques embarquees ne sont chargees que la ou elles servent.
    # LibOpenRaid sort en tete de son propre fichier sur tout client non retail
    # ("emergencial patch due to classic and bcc stuff not transposed yet") : sur
    # les cinq flavors classic, l'inscrire au .toc ne ferait que compiler 600 Ko
    # de Lua pour rien. Le jour ou l'amont retire cette garde, il suffit d'elargir
    # ce test — cf. Modules/CDTracker/Libs/README.md.
    lib_files="# LibOpenRaid ne se charge pas sur ce flavor (garde amont retail)."
    if [ "$flavor" = "retail" ]; then
        lib_files="$(cat <<'LIBS'
# Bibliotheques embarquees (voir Modules/CDTracker/Libs/README.md).
# LibStub d'abord : LibOpenRaid s'y declare.
Modules/CDTracker/Libs/LibStub/LibStub.lua
Modules/CDTracker/Libs/LibOpenRaid/LibOpenRaid.lua
Modules/CDTracker/Libs/LibOpenRaid/Functions.lua
Modules/CDTracker/Libs/LibOpenRaid/GetPlayerInformation.lua
Modules/CDTracker/Libs/LibOpenRaid/Deprecated.lua
Modules/CDTracker/Libs/LibOpenRaid/ThingsToMantain_WarWithin.lua
Modules/CDTracker/Libs/LibOpenRaid/ThingsToMantain_Dragonflight.lua
Modules/CDTracker/Libs/LibOpenRaid/ThingsToMantain_Shadowlands.lua
Modules/CDTracker/Libs/LibOpenRaid/ThingsToMantain_Wrath.lua
Modules/CDTracker/Libs/LibOpenRaid/ThingsToMantain_Era.lua
Modules/CDTracker/Libs/LibOpenRaid/ThingsToMantain_BurningCrusade.lua
Modules/CDTracker/Libs/LibOpenRaid/ThingsToMantain_Cata.lua
Modules/CDTracker/Libs/LibOpenRaid/ThingsToMantain_Pandaria.lua
Modules/CDTracker/Libs/LibOpenRaid/ThingsToMantain_Midnight.lua
LIBS
)"
    fi

    data_files=""
    for dir in "Modules/BossTimer/Data/$flavor" \
               "Modules/InterruptAlert/Data/$flavor" \
               "Modules/MoveAlert/Data/$flavor" \
               "Modules/CDTracker/Data/$flavor"; do
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
            -v data="$data_files" -v libs="$lib_files" '
            {
                gsub(/@INTERFACE@/, iface)
                gsub(/@FLAVOR@/, flavor)
                gsub(/@VERSION@/, version)
                if ($0 == "@LIB_FILES@") { print libs; next }
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
