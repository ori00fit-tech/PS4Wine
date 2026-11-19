#!/usr/bin/env bash
# WinePS4 Enhanced: ps4-kit at the public commit closest to v00.71 (docs/BUILD_FROM_SOURCE.md steps 3-4): the kit
# checked out at ~/ps4-kit, its build tree ~/ps4kit-build, the libc overlay, libc++ 21 and the kit's runtime library.
# Needs tools/build-openorbis.sh first (the LLVM 21.1.6 runtimes checkout in ~/oo-src is reused for libc++).
#   tools/setup-ps4-kit.sh
set -euo pipefail
KIT_COMMIT="${PS4_KIT_COMMIT:-1f2bd79}"   # 2026-11-06, the day of v00.71 (upstream built with 56b3d86, not public)
REPO="$HOME/ps4-kit-repo" WT="$HOME/ps4-kit-${KIT_COMMIT}"
[ -d "$REPO/.git" ] || git clone -q https://github.com/iHaiDeeZ/ps4-kit "$REPO"
[ -d "$WT" ] || git -C "$REPO" worktree add -q --detach "$WT" "$KIT_COMMIT"
ln -sfn "$WT" "$HOME/ps4-kit"
# (the kit's scripts are committed without the executable bit; its own scripts call each other directly)
chmod +x "$WT"/toolchain/*.sh "$WT"/scripts/*.sh "$WT"/gpu/*.sh "$WT"/toolchain/bin/*
mkdir -p "$HOME"/ps4kit-build/{src,build,out,logs,oelf,host-tools/bin,sysroot/lib,sysroot/include}
bash "$HOME/ps4-kit/toolchain/prepare-sysroot.sh" > "$HOME/ps4kit-build/logs/prepare-sysroot.log" 2>&1
LLVM_LOCAL_SRC="${LLVM_LOCAL_SRC:-${OO_SRC:-$HOME/oo-src}/llvm-project-21.1.6}" \
    bash "$HOME/ps4-kit/toolchain/build-libcxx.sh" > "$HOME/ps4kit-build/logs/libcxx.log" 2>&1
bash "$HOME/ps4-kit/toolchain/build-runtime.sh"
echo "ps4-kit $(git -C "$WT" log -1 --format='%h %ad' --date=short) at ~/ps4-kit; libc++ and the runtime built"
