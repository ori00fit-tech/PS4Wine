#!/usr/bin/env bash
# WinePS4 Enhanced: the whole package from public sources on a fresh Ubuntu 24.04 x86_64 machine (GitHub Actions'
# ubuntu-24.04, or a Claude Code cloud session), docs/BUILD_FROM_SOURCE.md in one command.
#   sudo apt-get ... (tools/ci-build.sh deps does it), then:
#   WINEPS4_VERSION=00.71 tools/ci-build.sh [deps] [all]
#
#   MINGW_THREADS=posix   mingw-w64's posix variant for Wine's PE side, as the official v00.71 package was built
#                         (Ubuntu's default alternative is win32; "win32" keeps it)
#   WINE_CONFIGURE_EXTRA  extra configure options for the PC's Wine build (CI: --disable-tests, which saves about
#                         half of the build's time and disk; Wine's tests are not in the package)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WINEPS4_VERSION="${WINEPS4_VERSION:-00.71}" DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo
step() { echo; echo "=== $* ($(date -u +%H:%M:%S))"; }

deps() {
    step "host packages"
    export DEBIAN_FRONTEND=noninteractive
    # (run #2 stood 24 min in this step, run #1 took 1 min: every apt download gets a timeout and retries)
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' |
        $SUDO tee /etc/apt/apt.conf.d/80-wineps4-retries > /dev/null
    $SUDO apt-get update -q
    $SUDO apt-get install -y -q flex bison mingw-w64 meson ninja-build cmake pkg-config autoconf automake libtool \
        gettext rsync python3-mako python3-yaml python3-venv glslang-tools nasm unzip zip xz-utils file patch \
        gcc-multilib libc6-dev-i386 dotnet-sdk-8.0 gnupg wget curl
    wget -q --timeout=30 --tries=5 -O /tmp/llvm.sh https://apt.llvm.org/llvm.sh && $SUDO bash /tmp/llvm.sh 21
    $SUDO apt-get install -y -q clang-21 lld-21 llvm-21 llvm-21-tools
    if [ "${MINGW_THREADS:-posix}" = posix ]; then
        local t
        for t in x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++ i686-w64-mingw32-gcc i686-w64-mingw32-g++; do
            $SUDO update-alternatives --set "$t" "/usr/bin/$t-posix"
        done
    fi
    $SUDO mkdir -p /opt/pacbrew && $SUDO chown "$(id -u):$(id -g)" /opt/pacbrew
}

all() {
    step "OpenOrbis toolchain";  "$ROOT/tools/build-openorbis.sh"
    step "ps4-kit";              "$ROOT/tools/setup-ps4-kit.sh"
    step "PS4 libraries";        "$ROOT/tools/build-sysroot.sh"
    step "Mesa/RADV";            bash "$HOME/ps4-kit/gpu/build-mesa.sh" > "$HOME/ps4kit-build/logs/mesa-run.log" 2>&1
    tail -1 "$HOME/ps4kit-build/logs/mesa-run.log"
    step "DXVK 3.1.1"
    mkdir -p "$HOME/wineps4-build" && curl -sSfL -o /tmp/dxvk-3.1.1.tar.gz \
        https://github.com/doitsujin/dxvk/releases/download/v3.1.1/dxvk-3.1.1.tar.gz
    echo "40565b4a724aadc4433fa4e010b4b23916d9b1f1baeee64e17186db94f54e608  /tmp/dxvk-3.1.1.tar.gz" | sha256sum -c -
    tar -xzf /tmp/dxvk-3.1.1.tar.gz -C "$HOME/wineps4-build"
    step "Wine, prefix, tests, app, package"; "$ROOT/tools/build-wineps4.sh"
    ls -la "$ROOT/out/"
}

WHAT=("$@"); [ ${#WHAT[@]} -gt 0 ] || WHAT=(deps all)
for w in "${WHAT[@]}"; do "$w"; done
