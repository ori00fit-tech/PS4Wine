#!/usr/bin/env bash
# WinePS4 Enhanced: the PS4 libraries WinePS4 and ps4-kit link that have no public build recipe upstream
# (ps4-kit's scripts/seed-build-tree.sh copies them from another port's private tree). Built from the
# projects' own release sources with ps4-kit's compiler wrappers (toolchain/bin/ps4-cc), static.
#
#   zlib 1.3.1      -> $PS4_SYSROOT          (ps4-kit's Mesa shader cache, WinePS4)
#   OpenSSL 3.5.x   -> $PS4_SYSROOT          (libcrypto only: WinePS4's bcrypt Unix half, dlls/bcrypt/ps4.c)
#   FreeType 2.13.3 -> ~/wineps4-build/freetype   (win32u, dwrite)
#   FFmpeg 7.1.1    -> ~/wineps4-build/ffmpeg-img (the desktop's image decoders; scripts/build-ffmpeg-img.sh's options)
#
#   tools/build-sysroot.sh [zlib|openssl|freetype|ffmpeg ...]   (default: all)
set -euo pipefail
source "$HOME/ps4-kit/toolchain/env.sh"
TC="$PS4_KIT/toolchain/bin"
DL="$PSB/src/downloads"; mkdir -p "$DL" "$PSB/logs"
WB="$HOME/wineps4-build"; mkdir -p "$WB"
ZLIB_VER=1.3.1 OPENSSL_VER="${OPENSSL_VER:-3.5.4}" FREETYPE_VER=2.13.3 FFMPEG_VER=7.1.1

# get <url> <file>: download once
get() { [ -s "$DL/$2" ] || curl -sSfL -o "$DL/$2.part" "$1" && mv -f "$DL/$2.part" "$DL/$2" 2>/dev/null || true; [ -s "$DL/$2" ]; }
unpack() { rm -rf "$PSB/src/$2"; mkdir -p "$PSB/src"; tar -xf "$DL/$1" -C "$PSB/src"; }

do_zlib() {
    get "https://zlib.net/fossils/zlib-$ZLIB_VER.tar.gz" zlib-$ZLIB_VER.tar.gz
    unpack zlib-$ZLIB_VER.tar.gz zlib-$ZLIB_VER
    cd "$PSB/src/zlib-$ZLIB_VER"
    CC="$TC/ps4-cc" AR="$PS4_AR" RANLIB="$PS4_RANLIB" CFLAGS="-O2 -fPIC" ./configure --static --prefix="$PS4_SYSROOT" > "$PSB/logs/zlib.log" 2>&1
    make -j"$JOBS" libz.a >> "$PSB/logs/zlib.log" 2>&1
    make install >> "$PSB/logs/zlib.log" 2>&1
    ls -la "$PS4_SYSROOT/lib/libz.a"
}

do_openssl() {
    get "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz" openssl-$OPENSSL_VER.tar.gz ||
        get "https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz" openssl-$OPENSSL_VER.tar.gz
    unpack openssl-$OPENSSL_VER.tar.gz openssl-$OPENSSL_VER
    cd "$PSB/src/openssl-$OPENSSL_VER"
    # BSD-x86_64: the PS4's kernel is FreeBSD's. libcrypto only; no engines, modules or async (ucontext).
    CC="$TC/ps4-cc" AR="$PS4_AR" RANLIB="$PS4_RANLIB" ./Configure BSD-x86_64 --prefix="$PS4_SYSROOT" --libdir=lib \
        no-shared no-module no-engine no-dso no-async no-tests no-apps no-docs no-ui-console no-afalgeng \
        no-devcryptoeng -fPIC -O2 -U_GNU_SOURCE > "$PSB/logs/openssl.log" 2>&1
    make -j"$JOBS" build_libs >> "$PSB/logs/openssl.log" 2>&1
    make install_dev >> "$PSB/logs/openssl.log" 2>&1
    ls -la "$PS4_SYSROOT/lib/libcrypto.a"
}

do_freetype() {
    get "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.xz" freetype-$FREETYPE_VER.tar.xz
    unpack freetype-$FREETYPE_VER.tar.xz freetype-$FREETYPE_VER
    local b="$PSB/build/freetype"; rm -rf "$b"
    ps4_cmake -S "$PSB/src/freetype-$FREETYPE_VER" -B "$b" -G Ninja -DCMAKE_INSTALL_PREFIX="$WB/freetype" \
        -DBUILD_SHARED_LIBS=OFF -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
        -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON > "$PSB/logs/freetype.log" 2>&1
    ninja -C "$b" install >> "$PSB/logs/freetype.log" 2>&1
    ls -la "$WB/freetype/lib/libfreetype.a"
}

do_ffmpeg() {
    need nasm
    get "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz" ffmpeg-$FFMPEG_VER.tar.xz
    unpack ffmpeg-$FFMPEG_VER.tar.xz ffmpeg-$FFMPEG_VER
    # scripts/build-ffmpeg-img.sh, with this tree's source and ps4-kit's wrappers in place of RPCS3's
    sed -e "s#^SRC=.*#SRC=\"$PSB/src/ffmpeg-$FFMPEG_VER\"#" -e "s#^TC=.*#TC=\"$TC\"#" \
        "$(dirname "$0")/../scripts/build-ffmpeg-img.sh" > "$PSB/build/build-ffmpeg-img.sh"
    bash "$PSB/build/build-ffmpeg-img.sh" > "$PSB/logs/ffmpeg.log" 2>&1
    ls -la "$WB/ffmpeg-img/lib"
}

WHAT=("$@"); [ ${#WHAT[@]} -gt 0 ] || WHAT=(zlib openssl freetype ffmpeg)
for w in "${WHAT[@]}"; do echo "--- $w"; "do_$w"; done
