#!/usr/bin/env bash
# WinePS4 Enhanced: runs tools/ci-build.sh on this machine (BUILD_OS=24.04, the default: GitHub's ubuntu-24.04) or
# in an Ubuntu 26.04 container on it (BUILD_OS=26.04), the release whose clang-21 (1:21.1.8-6ubuntu1) and mingw
# binutils (2.45) the official v00.71 package's PE files record (docs/BUILD_FROM_SOURCE.md, run #9's review).
#   BUILD_OS=26.04 tools/ci-run.sh deps all verify compare manifest
# The container (wineps4-build) is started on the first call and kept for the later ones (each workflow step is one
# call). It sees the checkout and $HOME at the same paths, gets the build's environment variables, and runs as
# root; "tools/ci-run.sh chown" gives the files it made back to this machine's user.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OS="${BUILD_OS:-24.04}"
IMAGE="ubuntu:${BUILD_OS}" NAME=wineps4-build
case "$BUILD_OS" in
    24.04) [ "${1:-}" = chown ] || exec "$ROOT/tools/ci-build.sh" "$@"; exit 0 ;;
    26.04) ;;
    *) echo "BUILD_OS: 24.04 or 26.04" >&2; exit 1 ;;
esac
if [ -z "$(docker ps -q --filter "name=^${NAME}$")" ]; then
    docker pull -q "$IMAGE"
    docker run -d --name "$NAME" -v "$ROOT:$ROOT" -v "$HOME:$HOME" -w "$ROOT" "$IMAGE" sleep infinity > /dev/null
    # (the checkout belongs to this machine's user: git refuses a repository of another owner without this)
    docker exec "$NAME" git config --system --add safe.directory '*' 2> /dev/null ||
        docker exec "$NAME" bash -c 'mkdir -p /etc && printf "[safe]\n\tdirectory = *\n" >> /etc/gitconfig'
    docker exec "$NAME" bash -c '. /etc/os-release; echo "container: $PRETTY_NAME ($(uname -m))"'
fi
if [ "${1:-}" = chown ]; then
    docker exec "$NAME" chown -R "$(id -u):$(id -g)" "$ROOT" "$HOME"
    exit 0
fi
envs=()
for v in WINEPS4_VERSION MINGW_THREADS WINE_CONFIGURE_EXTRA WINE_I386_CC WINE_GETTEXT WINE_PREFIX_USER JOBS \
         GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_SHA GIT_COMMITTER_DATE; do
    [ -n "${!v+x}" ] && envs+=(-e "$v=${!v}")
done
exec docker exec "${envs[@]}" -e HOME="$HOME" -e BUILD_OS="$BUILD_OS" -e DEBIAN_FRONTEND=noninteractive \
    -w "$ROOT" "$NAME" "$ROOT/tools/ci-build.sh" "$@"
