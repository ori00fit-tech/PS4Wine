#!/usr/bin/env bash
# WinePS4 Enhanced: compares the package built here with the official one (out/COMPARISON.md). Runs after
# tools/verify-pkg.sh (it reuses that script's extracted tree and param.sfo). Exits non-zero when a difference is
# left unexplained (tools/compare-pkg.py).
#   WINEPS4_VERSION=00.71 tools/compare-pkg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="${WINEPS4_VERSION:-00.71}"
PKGTOOL="${OPENORBIS:-/opt/pacbrew/ps4/openorbis}/bin/linux/PkgTool.Core"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
DL="${DL:-$HOME/ps4kit-build/src/downloads}" DL_LOG="${DL_LOG:-$HOME/ps4kit-build/logs/downloads.tsv}"
source "$ROOT/tools/lib-fetch.sh"
case "$V" in
    00.71) OFFICIAL_SHA=95ec4804f27c43f7606d3d1ac024690ffff7082cc380b6d534bee8177c98478c ;;
    *) echo "no pinned checksum for the official v$V package: add it here" >&2; exit 1 ;;
esac
fetch "official-WinePS4-v$V.pkg" "$OFFICIAL_SHA" "https://github.com/iHaiDeeZ/WinePS4/releases/download/v$V/WinePS4-v$V.pkg"
W="$ROOT/out/verify"
[ -d "$W/x/uroot" ] || { echo "run tools/verify-pkg.sh first" >&2; exit 1; }
rm -rf "$W/official"; mkdir -p "$W/official"
"$PKGTOOL" pkg_extract --passcode 00000000000000000000000000000000 "$DL/official-WinePS4-v$V.pkg" "$W/official/x" > "$W/official/extract.txt" 2>&1
id=$("$PKGTOOL" pkg_listentries "$DL/official-WinePS4-v$V.pkg" | awk '$NF == "PARAM_SFO" { print $(NF-1) }')
"$PKGTOOL" pkg_extractentry "$DL/official-WinePS4-v$V.pkg" "$id" "$W/official/param.sfo" > /dev/null
"$PKGTOOL" sfo_listentries "$W/official/param.sfo" > "$W/official/param.txt"
python3 -I "$ROOT/tools/compare-pkg.py" "$W/official/x/uroot" "$W/x/uroot" "$W/official/param.txt" "$W/param.txt" "$ROOT/out/COMPARISON.md"
