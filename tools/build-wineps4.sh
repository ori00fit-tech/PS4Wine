#!/usr/bin/env bash
# WinePS4 Enhanced: upstream docs/BUILDING.md steps 1-3, 6 and 7 in one script, with the two host-side gaps those
# steps leave filled in. Needs tools/build-openorbis.sh, ps4-kit (docs/BUILD_FROM_SOURCE.md), tools/build-sysroot.sh,
# ps4-kit's gpu/build-mesa.sh and the DXVK 3.1.1 release in ~/wineps4-build/dxvk-3.1.1 first.
#
#   WINEPS4_VERSION=00.71 tools/build-wineps4.sh [wine|prefix|tests|app|package ...]   (default: all of them)
#
# Host gaps (only the PC's Wine build: none of it goes into the package's PS4 side):
#   - wineps4.drv's Unix half (wineps4.so) is PS4 code: on Linux audio.c fails on sockaddr_un's sun_len (BSD only)
#     and the library can't link (ps4-kit's ps4kit_set_log, ps4kit_set_window_present). make stops there and
#     make install installs no Unix library at all, ntdll.so included, so `wine wineboot --init` (the prefix)
#     can't run. Built here with sun_len pointed at sun_path[0] (the strcpy that follows overwrites it) and linked
#     with undefined symbols allowed: that host wineps4.so is never loaded (the prefix's wineboot uses no display
#     or audio driver) and not packaged (app/build.sh compiles wineps4.drv's Unix half into the PS4 app itself).
#   - Wine's fonts: not installed with --without-freetype; copied from its source (see do_wine).
#
# Matching the official v00.71's Windows side (docs/BUILD_FROM_SOURCE.md, "Comparison"; evidence in the official
# package itself):
#   - its i386 DLLs are clang's (589 of 601 carry "clang version 21.1.8", none GCC's): the developer's machine had no
#     32-bit mingw (tests/build.sh says so), and Wine's configure fell back to clang -target i686-windows. Here
#     i386_CC=clang-21 (WINE_I386_CC; empty: configure's own choice, i686-w64-mingw32-gcc when installed).
#   - no translations (user32's resources: 2 languages, 45 with them): the developer's machine had no msgfmt, which
#     turns Wine's po/ off. Here --without-gettext (WINE_GETTEXT=yes: translations as Wine builds them by default).
#   - x86_64 stays mingw-w64 GCC (13-posix in the official package: MINGW_THREADS=posix in tools/ci-build.sh).
#   - hello32.exe: winegcc's clang/lld-link refuses Wine's 32-bit import libraries without SafeSEH tables
#     ("/safeseh: ... is not compatible with SEH"): linked with /safeseh:no.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${WINEPS4_VERSION:-00.71}"
WB="$HOME/wine-ps4-build"
SRC="$WB/src/wine" BLD="$WB/build/wine-wow64" INST="$WB/install/wine-wow64" PREFIX="$WB/prefix-wow64"
JOBS="${JOBS:-$(nproc)}"

do_wine() {
    if [ ! -d "$SRC/.git" ]; then
        mkdir -p "$WB/src"
        git clone -q --branch wine-11.0 --depth 1 https://gitlab.winehq.org/wine/wine.git "$SRC"
        git -C "$SRC" -c user.name=WinePS4 -c user.email=wineps4@localhost am -q "$ROOT/patches/wine-ps4.patch"
    fi
    echo "wine: $(git -C "$SRC" log --oneline wine-11.0..HEAD 2>/dev/null | wc -l) WinePS4 commits on wine-11.0"
    local i386_cc="${WINE_I386_CC-clang-21}"   # (unset: clang-21; set empty: configure's own choice)
    mkdir -p "$BLD" && cd "$BLD"
    [ -f Makefile ] || "$SRC/configure" --enable-archs=i386,x86_64 --prefix="$INST" \
        --without-x --without-wayland --without-freetype --without-gstreamer --without-pulse --without-alsa \
        --without-oss --without-cups --without-dbus --without-sane --without-krb5 --without-gphoto \
        --without-opencl --without-pcap --without-usb --without-v4l2 --without-netapi --without-gnutls \
        --without-sdl --without-udev --without-capi --without-pcsclite --without-ffmpeg --without-opengl \
        --without-fontconfig $([ "${WINE_GETTEXT:-no}" = yes ] || echo --without-gettext) \
        ${i386_cc:+i386_CC=$i386_cc} ${WINE_CONFIGURE_EXTRA:-} > configure.log 2>&1
    grep -E '^(i386|x86_64)_(CC|TARGET) ' Makefile
    # the host gap: wineps4.drv's Unix half (see the top)
    make -j"$JOBS" dlls/ntdll/ntdll.so dlls/win32u/win32u.so > make-host-gap.log 2>&1
    make dlls/wineps4.drv/audio.o CFLAGS='-g -O2 -Dsun_len=sun_path[0]' >> make-host-gap.log 2>&1
    make dlls/wineps4.drv/wineps4.so LDFLAGS=-Wl,-z,undefs >> make-host-gap.log 2>&1
    make -j"$JOBS" > make.log 2>&1
    make install > install.log 2>&1
    # Wine's own TrueType fonts: --without-freetype turns Wine's font install off (enable_fonts), and the package
    # needs them (app/package.sh copies Liberation next to them). The official v00.71 package has exactly the 13
    # prebuilt .ttf of fonts/ there and no .fon: copied as they are.
    mkdir -p "$INST/share/wine/fonts" && cp "$SRC"/fonts/*.ttf "$INST/share/wine/fonts/"
    echo "wine: $(ls "$INST/lib/wine/x86_64-windows" | wc -l) x86_64-windows, $(ls "$INST/lib/wine/i386-windows" | wc -l) i386-windows files installed"
}

# WINE_PREFIX_USER: the Unix user name wineboot makes the prefix as, which names the Windows user folders recorded in
# user.reg and userdef.reg (C:\users\<name>). The console's user is ps4 either way (port/ps4_main.c sets USER=ps4 and
# makes C:\users\ps4); the official v00.71 package's prefix was made as "shiro" (its user.reg), which CI uses to
# reproduce it for the comparison.
do_prefix() {
    rm -rf "$PREFIX"
    env ${WINE_PREFIX_USER:+USER=$WINE_PREFIX_USER LOGNAME=$WINE_PREFIX_USER} \
        WINEPREFIX="$PREFIX" WINEDEBUG=-all "$INST/bin/wine" wineboot --init > "$WB/prefix.log" 2>&1
    WINEPREFIX="$PREFIX" "$INST/bin/wineserver" -w
    echo "prefix: $(ls "$PREFIX/drive_c/windows/system32" | wc -l) files in system32"
}

do_tests() {
    local t="$ROOT/tests"
    x86_64-w64-mingw32-gcc -O1 -Wall -o "$t/hello.exe" "$t/hello.c"
    "$INST/bin/winegcc" -b i686-windows -mconsole -o "$t/hello32.exe" "$t/hello.c" -Wl,/safeseh:no
    x86_64-w64-mingw32-gcc -O1 -Wall -municode -mwindows -o "$t/window.exe" "$t/window.c" -lgdi32 -luser32
    x86_64-w64-mingw32-gcc -O1 -Wall -o "$t/wintest.exe" "$t/wintest.c" -lgdi32 -luser32
    ls -la "$t"/*.exe
}

do_app() { cd "$ROOT" && WINEPS4_VERSION="$VERSION" bash app/build.sh all; }
do_package() { cd "$ROOT" && WINEPS4_VERSION="$VERSION" bash app/package.sh; }

WHAT=("$@"); [ ${#WHAT[@]} -gt 0 ] || WHAT=(wine prefix tests app package)
for w in "${WHAT[@]}"; do echo "--- $w"; "do_$w"; done
