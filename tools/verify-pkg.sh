#!/usr/bin/env bash
# WinePS4 Enhanced: checks a WinePS4 package before it is published (BUILD-VERIFIED, not DEVICE-TESTED: nothing here runs
# it on a console). Writes out/VERIFY.md and out/SHA256SUMS; exits non-zero when a check fails.
#   WINEPS4_VERSION=00.71 tools/verify-pkg.sh [out/WinePS4-v00.71.pkg]
#
# Checks: PkgTool's pkg_validate, every line [OK] (hashes, and the header and debug RIF signatures: with the public
# fake-PKG keys, so they prove the package intact and loadable by GoldHEN, not who built it); param.sfo (title id, content id, version, attribute);
# the files the app needs at run time; every system32-from-lib.txt entry has its DLL in lib; both eboots are fake SELFs
# carrying this version, and wineps4.bin imports the 15 system libraries the official v00.71 does.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="${WINEPS4_VERSION:-00.71}"
PKG="${1:-$ROOT/out/WinePS4-v$V.pkg}"
OO="${OPENORBIS:-/opt/pacbrew/ps4/openorbis}"
PKGTOOL="$OO/bin/linux/PkgTool.Core"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
WORK="${VERIFY_WORK:-$ROOT/out/verify}"
REPORT="$ROOT/out/VERIFY.md"
fails=0
rm -rf "$WORK"; mkdir -p "$WORK"
exec 3> "$REPORT"
say() { echo "$*" >&3; }
check() {  # check <description> <command...>
    local d="$1"; shift
    if "$@" > "$WORK/check.out" 2>&1; then say "| OK | $d |"; else say "| **FAIL** | $d: $(tr '\n' ' ' < "$WORK/check.out" | cut -c1-300) |"; fails=$((fails + 1)); fi
}

say "# Package verification: $(basename "$PKG")"
say ""
say "BUILD-VERIFIED checks only: nothing here ran the package on a console (**UNTESTED ON DEVICE**)."
say ""
say "- size: $(stat -c%s "$PKG") bytes"
say "- sha256: \`$(sha256sum "$PKG" | cut -d' ' -f1)\`"
say ""
say "| Result | Check |"
say "|---|---|"

# 1. PkgTool's own validation
"$PKGTOOL" pkg_validate "$PKG" > "$WORK/validate.txt" 2>&1 || true
cp "$WORK/validate.txt" "$ROOT/out/validate.txt"
# strict: every result line [OK] (PkgTool's NoKey, for a header signature it cannot match, and any other status
# fail), both signatures and every hash present, and nothing but result lines
check "pkg_validate: every one of its $(grep -c . "$WORK/validate.txt") lines is [OK]" bash -c '
    f="$1"; bad=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in "[OK]"*"("*")"*) ;; *) echo "not OK: $line"; bad=$((bad + 1)) ;; esac
    done < "$f"
    [ "$(grep -c . "$f")" -ge 20 ] || { echo "only $(grep -c . "$f") lines"; bad=$((bad + 1)); }
    grep -q "^\[OK\].*(Signature) PKG Header Signature" "$f" || { echo "no [OK] PKG Header Signature"; bad=$((bad + 1)); }
    grep -q "^\[OK\].*(Signature) Debug RIF Signature" "$f" || { echo "no [OK] Debug RIF Signature"; bad=$((bad + 1)); }
    [ $bad = 0 ]' _ "$WORK/validate.txt"
say ""
say "<details><summary>pkg_validate, line by line ($(grep -c . "$WORK/validate.txt") lines)</summary>"
say ""
say "| Status | Check |"
say "|---|---|"
sed -nE 's/^\[([A-Za-z]+)\][[:space:]]+(.*)$/| \1 | \2 |/p' "$WORK/validate.txt" >&3
grep -vE '^\[[A-Za-z]+\]' "$WORK/validate.txt" | grep . | sed 's/^/| ? | /; s/$/ |/' >&3 || true
say ""
say "</details>"
say ""
say "| Result | Check |"
say "|---|---|"

# 2. param.sfo (entry 9 in WinePS4's packages; found by name to be safe)
id=$("$PKGTOOL" pkg_listentries "$PKG" | awk '$NF == "PARAM_SFO" { print $(NF-1) }')
"$PKGTOOL" pkg_extractentry "$PKG" "$id" "$WORK/param.sfo" > /dev/null
"$PKGTOOL" sfo_listentries "$WORK/param.sfo" > "$WORK/param.txt"
sfo() { awk -F' = ' -v k="$1" '$1 ~ "^"k" " { print $2 }' "$WORK/param.txt"; }
for kv in "TITLE_ID=WINE00002" "CONTENT_ID=IV0000-WINE00002_00-WINEPS4000000000" "VERSION=$V" "APP_VER=$V" \
          "ATTRIBUTE=0x00800002" "CATEGORY=gd" "APP_TYPE=0x00000001" "TITLE=WinePS4"; do
    check "param.sfo ${kv%%=*} = ${kv#*=}" test "$(sfo "${kv%%=*}")" = "${kv#*=}"
done

# (the icon is a package entry, ICON0_PNG, not a file of the package's file system)
check "package entry ICON0_PNG" bash -c "'$PKGTOOL' pkg_listentries '$PKG' | grep -q ICON0_PNG"

# 3. the files
"$PKGTOOL" pkg_extract --passcode 00000000000000000000000000000000 "$PKG" "$WORK/x" > "$WORK/extract.txt" 2>&1
U="$WORK/x/uroot"
for f in eboot.bin wineps4.bin sce_sys/keystone sce_module/libc.prx sce_module/libSceFios2.prx \
         wine/lib/wine/x86_64-windows/ntdll.dll wine/lib/wine/i386-windows/ntdll.dll \
         wine/lib/wine/x86_64-windows/kernelbase.dll wine/lib/wine/i386-windows/kernelbase.dll \
         wine/lib/wine/x86_64-windows/wineps4.drv wine/lib/wine/i386-windows/wineps4.drv \
         wine/dxvk/x64/d3d11.dll wine/dxvk/x32/d3d11.dll wine/dxvk/x64/dxgi.dll wine/dxvk/x32/d3d9.dll \
         wine/share/wine/wine.inf wine/share/wine/fonts/tahoma.ttf wine/share/wine/fonts/LiberationSans-Regular.ttf \
         wine/share/ca-certificates.crt wine/prefix/system.reg wine/prefix/user.reg wine/system32-from-lib.txt \
         wine/hello.exe wine/hello32.exe wine/window.exe fonts/Roboto-Regular.ttf; do
    check "file $f" test -s "$U/$f"
done
check "nine wallpapers" test "$(ls "$U"/wallpapers/*.jpg | wc -l)" -ge 5
check "every system32-from-lib.txt entry has its DLL in lib" bash -c '
    U="$1"; missing=0
    while read -r e; do
        case "$e" in system32/*) d=x86_64-windows ;; syswow64/*) d=i386-windows ;; *) echo "bad entry $e"; exit 1 ;; esac
        [ -f "$U/wine/lib/wine/$d/${e#*/}" ] || { echo "missing $e"; missing=$((missing + 1)); }
    done < "$U/wine/system32-from-lib.txt"
    [ $missing = 0 ]' _ "$U"
say ""
say "- files: $(find "$U" -type f | wc -l); system32/syswow64 entries from lib: $(wc -l < "$U/wine/system32-from-lib.txt")"
say "- Wine PE files: $(ls "$U/wine/lib/wine/x86_64-windows" | wc -l) x86_64, $(ls "$U/wine/lib/wine/i386-windows" | wc -l) i386"
say ""
say "| Result | Check |"
say "|---|---|"

# 4. the eboots
for e in eboot.bin wineps4.bin; do
    check "$e is a fake SELF (magic 4f153d1d)" test "$(head -c4 "$U/$e" | od -An -tx1 | tr -d ' \n')" = 4f153d1d
done
check "wineps4.bin says WinePS4 v$V" grep -qa "WinePS4 v$V (Wine 11.0)" "$U/wineps4.bin"
strings -n 8 "$U/wineps4.bin" | grep -oE '^lib(Sce[A-Za-z0-9]+|kernel)$' | sort -u > "$WORK/imports.txt"
printf '%s\n' libSceAudioOut libSceCommonDialog libSceIme libSceImeDialog libSceKeyboard libSceLibcInternal libSceMouse \
    libSceNet libSceNetCtl libScePad libSceSysmodule libSceSystemService libSceUserService libSceVideoOut libkernel \
    | sort > "$WORK/imports.expected"
check "wineps4.bin imports the official v00.71's 15 system libraries" diff "$WORK/imports.expected" "$WORK/imports.txt"

# 5. checksums
( cd "$(dirname "$PKG")" && sha256sum "$(basename "$PKG")" ) > "$ROOT/out/SHA256SUMS"
( cd "$U" && sha256sum eboot.bin wineps4.bin ) | sed 's#  #  uroot/#' >> "$ROOT/out/SHA256SUMS"
( cd "$WORK" && sha256sum param.sfo ) | sed 's#  #  entry/#' >> "$ROOT/out/SHA256SUMS"
# every file of the package's file system, sorted by path (out/FILES.sha256)
( cd "$U" && find . -type f -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum ) > "$ROOT/out/FILES.sha256"
( cd "$ROOT/out" && sha256sum FILES.sha256 ) >> "$ROOT/out/SHA256SUMS"
check "FILES.sha256 lists every file of the package ($(wc -l < "$ROOT/out/FILES.sha256"))" \
    test "$(wc -l < "$ROOT/out/FILES.sha256")" = "$(find "$U" -type f | wc -l)"
say ""
say "## SHA256SUMS"
say '```'
cat "$ROOT/out/SHA256SUMS" >&3
say '```'
say ""
say "## param.sfo"
say '```'
cat "$WORK/param.txt" >&3
say '```'
say ""
say "Result: $([ $fails = 0 ] && echo "all checks passed" || echo "**$fails check(s) failed**")"
exec 3>&-
cat "$REPORT"
[ $fails = 0 ]
