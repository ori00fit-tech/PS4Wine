#!/usr/bin/env bash
# WinePS4 Enhanced: out/BUILD_MANIFEST.md - what went into this build: every source's exact commit, every downloaded
# archive's sha256, the tools' versions, each build stage and its time (out/stages.tsv), every download attempt with
# the retries and fallback mirrors used (downloads.tsv), and the outputs' checksums (out/SHA256SUMS).
#   WINEPS4_VERSION=00.71 tools/build-manifest.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="${WINEPS4_VERSION:-00.71}"
PSB="${PSB:-$HOME/ps4kit-build}" OO_SRC="${OO_SRC:-$HOME/oo-src}" OO="${OPENORBIS:-/opt/pacbrew/ps4/openorbis}"
OUT="$ROOT/out/BUILD_MANIFEST.md"
exec 3> "$OUT"
w() { echo "$*" >&3; }
rev() {  # rev <name> <git dir>: a table row with the checkout's commit, its date and where it came from
    local d="$2"
    if git -C "$d" rev-parse HEAD > /dev/null 2>&1; then
        w "| $1 | \`$(git -C "$d" rev-parse HEAD)\` | $(git -C "$d" log -1 --format=%cs 2>/dev/null) | $(git -C "$d" describe --tags --exact-match 2>/dev/null || echo -) | $(git -C "$d" remote get-url origin 2>/dev/null || echo -) |"
    else
        w "| $1 | **missing** ($d) | | | |"
    fi
}
ver() { "$@" 2>&1 | head -1; }

w "# Build manifest: WinePS4 v$V (UNTESTED ON DEVICE)"
w ""
w "- Built: $(date -u +%FT%TZ) on $(. /etc/os-release; echo "$PRETTY_NAME") $(uname -m), $(nproc) cores"
w "- This repository: \`$(git -C "$ROOT" rev-parse HEAD)\` ($(git -C "$ROOT" rev-parse --abbrev-ref HEAD))"
[ -n "${GITHUB_RUN_ID:-}" ] && w "- GitHub Actions run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID (#${GITHUB_RUN_NUMBER:-})"
w "- Evidence level: BUILD-VERIFIED (out/VERIFY.md) and compared with the official package (out/COMPARISON.md). Not DEVICE-TESTED."
w ""
w "## Sources (git)"
w "| Component | Commit | Date | Tag | From |"
w "|---|---|---|---|---|"
rev "WinePS4 (this repository)" "$ROOT"
rev "Wine 11.0 + patches/wine-ps4.patch" "$HOME/wine-ps4-build/src/wine"
w "| Wine base tag | \`$(git -C "$HOME/wine-ps4-build/src/wine" rev-parse 'wine-11.0^{commit}' 2>/dev/null)\` | | wine-11.0 | patch sha256 \`$(sha256sum "$ROOT/patches/wine-ps4.patch" | cut -c1-64)\`, $(git -C "$HOME/wine-ps4-build/src/wine" log --oneline 'wine-11.0..HEAD' 2>/dev/null | wc -l) commits |"
rev "ps4-kit" "$HOME/ps4-kit"
rev "Mesa (with ps4-kit's patches)" "$PSB/src/mesa"
w "| Mesa base tag | \`$(git -C "$PSB/src/mesa" rev-parse 'mesa-26.0.8^{commit}' 2>/dev/null)\` | | mesa-26.0.8 | $(grep -m1 "PS4 patches on" "$PSB/logs/mesa-run.log" 2>/dev/null) |"
rev "libdrm (headers)" "$PSB/src/libdrm"
for c in ps4-openorbis headers musl create-fself create-gp4 liborbispkg orbis-lib-gen ps4libdoc llvm-project-21.1.6; do
    rev "OpenOrbis toolchain: $c" "$OO_SRC/$c"
done
for c in libsmb2 libnfs fmt; do rev "PS4 library: $c" "$PSB/src/$c"; done
w ""
w "## Downloaded archives (sha256 pinned in tools/build-sysroot.sh, tools/compare-pkg.sh)"
w "| File | sha256 | Bytes |"
w "|---|---|---|"
for f in "$PSB/src/downloads"/*; do
    [ -f "$f" ] && w "| $(basename "$f") | \`$(sha256sum "$f" | cut -c1-64)\` | $(stat -c%s "$f") |"
done
w "| (Go for create-fself, create-gp4) | go1.17.5.linux-amd64 from go.dev | |"
w ""
w "## Downloads: attempts, retries and mirrors"
if [ -f "$PSB/logs/downloads.tsv" ]; then
    failed=$(awk -F'\t' 'NR > 1 && $4 == "failed"' "$PSB/logs/downloads.tsv" | wc -l)
    w "Failed attempts: **$failed**. For each file, the mirror that gave it and on which attempt:"
    w ""
    w "| File | URL | Attempt | Result | curl exit | Seconds |"
    w "|---|---|---|---|---|---|"
    awk -F'\t' 'NR > 1 { printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6 }' "$PSB/logs/downloads.tsv" >&3
    w ""
    awk -F'\t' 'NR > 1 && $4 == "ok" { ok[$1] = $2 } NR > 1 && $4 == "failed" { fail[$1]++ }
        END { for (f in ok) if (fail[f]) printf "- %s: %d failed attempt(s) before %s\n", f, fail[f], ok[f] }' \
        "$PSB/logs/downloads.tsv" >&3
else
    w "(no downloads.tsv)"
fi
w ""
w "## Build configuration"
w "| Setting | Value |"
w "|---|---|"
for v in BUILD_OS WINEPS4_VERSION MINGW_THREADS WINE_CONFIGURE_EXTRA WINE_I386_CC WINE_GETTEXT WINE_PREFIX_USER PS4_KIT_COMMIT \
         PS4LIBDOC_COMMIT OPENSSL_VER LLVM_VER CLANG_VER JOBS HOME USER; do
    if [ -n "${!v+x}" ]; then w "| \`$v\` | \`${!v}\` |"; else w "| \`$v\` | (unset: the scripts' default) |"; fi
done
W="$HOME/wine-ps4-build/build/wine-wow64"
w "| Wine configure | \`$(sed -n 's/^  \$ //p' "$W/config.log" 2>/dev/null | head -1)\` |"
grep -E '^(i386|x86_64)_(CC|TARGET) ' "$W/Makefile" 2>/dev/null | while read -r k _ val; do w "| Wine \`$k\` | \`$val\` |"; done
w "| Stage order | $(awk -F'\t' 'NR > 1 { printf "%s%s", (NR > 2 ? " → " : ""), $1 }' "$ROOT/out/stages.tsv" 2>/dev/null) |"
w "| Files in the package | $(wc -l < "$ROOT/out/FILES.sha256" 2>/dev/null || echo '?') (sha256 of each: FILES.sha256) |"
w ""
w "## Tools"
w "| Tool | Version |"
w "|---|---|"
w "| clang (PS4 side) | $(ver clang-21 --version) |"
w "| ld.lld | $(ver ld.lld-21 --version) |"
w "| mingw-w64 (Wine's PE side) | $(x86_64-w64-mingw32-gcc -v 2>&1 | grep -E '^(gcc version|Thread model)' | tr '\n' ' ') |"
w "| host gcc | $(ver gcc --version) |"
w "| cmake / meson / ninja | $(ver cmake --version) / $(ver meson --version) / $(ver ninja --version) |"
w "| .NET (PkgTool) | $(ver dotnet --version) |"
w "| Go | $(ver "$OO_SRC/go1.17.5/bin/go" version) |"
w ""
w "## Build stages"
if [ -f "$ROOT/out/stages.tsv" ]; then
    w "| Stage | Start (UTC) | End (UTC) | Seconds | Result |"
    w "|---|---|---|---|---|"
    awk -F'\t' 'NR > 1 { printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5 }' "$ROOT/out/stages.tsv" >&3
else
    w "(no stages.tsv: the build ran outside tools/ci-build.sh)"
fi
w ""
w "## Outputs"
w '```'
cat "$ROOT/out/SHA256SUMS" >&3 2>/dev/null || w "(no SHA256SUMS: tools/verify-pkg.sh has not run)"
w '```'
w ""
w "Verification: $(grep -m1 '^Result:' "$ROOT/out/VERIFY.md" 2>/dev/null || echo 'not run')"
w ""
w "Comparison with the official package: $(grep -m1 '^Result:' "$ROOT/out/COMPARISON.md" 2>/dev/null || echo 'not run')"
exec 3>&-
cat "$OUT"
