#!/usr/bin/env bash
# WinePS4 Enhanced: the whole package from public sources on a fresh Ubuntu 24.04 x86_64 machine (GitHub Actions'
# ubuntu-24.04, or a Claude Code cloud session) or in an Ubuntu 26.04 container (tools/ci-run.sh), docs/BUILD_FROM_SOURCE.md in one command.
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
    # Ubuntu 24.04: clang 21 from apt.llvm.org, .NET 8. Ubuntu 26.04 (BUILD_OS=26.04, tools/ci-run.sh): its own
    # clang-21 (1:21.1.8-6ubuntu1, the official v00.71's i386 compiler) and mingw binutils 2.45 (its x86_64 linker),
    # .NET 10 (26.04 has no .NET 8; tools/build-openorbis.sh builds PkgTool for the SDK it finds).
    local os; os=$(. /etc/os-release && echo "$VERSION_ID")
    $SUDO apt-get update -q
    $SUDO apt-get install -y -q flex bison mingw-w64 meson ninja-build cmake pkg-config autoconf automake libtool \
        gettext rsync python3-mako python3-yaml python3-venv glslang-tools nasm unzip zip xz-utils file patch \
        gcc-multilib libc6-dev-i386 gnupg wget curl git python3 ca-certificates make gcc g++ \
        "$([ "$os" = 24.04 ] && echo dotnet-sdk-8.0 || echo dotnet-sdk-10.0)"
    if [ "$os" = 24.04 ]; then
        wget -q --timeout=30 --tries=5 -O /tmp/llvm.sh https://apt.llvm.org/llvm.sh && $SUDO bash /tmp/llvm.sh 21
    fi
    $SUDO apt-get install -y -q clang-21 lld-21 llvm-21 llvm-21-tools
    echo "host: $(. /etc/os-release && echo "$PRETTY_NAME"); $(clang-21 --version | head -1);" \
        "$(x86_64-w64-mingw32-ld --version | head -1); dotnet $(dotnet --version)"
    if [ "${MINGW_THREADS:-posix}" = posix ]; then
        local t
        for t in x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++ i686-w64-mingw32-gcc i686-w64-mingw32-g++; do
            $SUDO update-alternatives --set "$t" "/usr/bin/$t-posix"
        done
    fi
    $SUDO mkdir -p /opt/pacbrew && $SUDO chown "$(id -u):$(id -g)" /opt/pacbrew
}

# stage <name> <command...>: one build stage, recorded in out/stages.tsv (name, start, end, seconds, result);
# a stage that fails is recorded as failed and stops the build
stage() {
    local name="$1" t0 t1 rc=0; shift
    mkdir -p "$ROOT/out"; [ -f "$ROOT/out/stages.tsv" ] || printf 'stage\tstart_utc\tend_utc\tseconds\tresult\n' > "$ROOT/out/stages.tsv"
    step "$name"; t0=$(date -u +%s)
    "$@" || rc=$?
    t1=$(date -u +%s)
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$(date -u -d @"$t0" +%FT%TZ)" "$(date -u -d @"$t1" +%FT%TZ)" $((t1 - t0)) \
        "$([ $rc = 0 ] && echo ok || echo "failed ($rc)")" >> "$ROOT/out/stages.tsv"
    [ $rc = 0 ] || { echo "stage '$name' failed with exit code $rc" >&2; exit $rc; }
}

mesa() {
    bash "$HOME/ps4-kit/gpu/build-mesa.sh" > "$HOME/ps4kit-build/logs/mesa-run.log" 2>&1
    tail -1 "$HOME/ps4kit-build/logs/mesa-run.log"
}

dxvk() {
    # (through build-sysroot.sh's fetch: the pinned sha256, and the attempt in downloads.tsv)
    "$ROOT/tools/build-sysroot.sh" dxvk
}

all() {
    stage "OpenOrbis toolchain"               "$ROOT/tools/build-openorbis.sh"
    stage "ps4-kit, libc++, kit runtime"      "$ROOT/tools/setup-ps4-kit.sh"
    stage "PS4 libraries (sysroot)"           "$ROOT/tools/build-sysroot.sh"
    stage "Mesa/RADV"                         mesa
    stage "DXVK 3.1.1"                        dxvk
    stage "Wine host build"                   "$ROOT/tools/build-wineps4.sh" wine
    stage "Wine prefix"                       "$ROOT/tools/build-wineps4.sh" prefix
    stage "Test programs"                     "$ROOT/tools/build-wineps4.sh" tests
    stage "WinePS4 app (wineps4.bin, eboot)"  "$ROOT/tools/build-wineps4.sh" app
    stage "PKG"                               "$ROOT/tools/build-wineps4.sh" package
    ls -la "$ROOT/out/"
}

# the acceptance checks (both exit non-zero on a failure, which stops the build before anything is published)
verify()  { stage "Verify the PKG"                          "$ROOT/tools/verify-pkg.sh"; }
compare() { stage "Compare with the official package"       "$ROOT/tools/compare-pkg.sh"; }
manifest() { "$ROOT/tools/build-manifest.sh" > /dev/null; echo "out/BUILD_MANIFEST.md written"; }

WHAT=("$@"); [ ${#WHAT[@]} -gt 0 ] || WHAT=(deps all verify compare manifest)
for w in "${WHAT[@]}"; do "$w"; done
