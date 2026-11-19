# Building WinePS4 from public sources only

Upstream's `docs/BUILDING.md` needs two things that are not public: ps4-kit `56b3d86` and a PS4 sysroot copied
from another port's tree. This guide replaces both with public sources. It was worked out in a Claude Code cloud
session (Ubuntu 24.04, x86_64, 4 cores, 15 GB RAM).

Status per step: **BUILD-VERIFIED** = built here. Nothing in this file is DEVICE-TESTED yet.

| # | Step | Script | Status |
|---|---|---|---|
| 1 | Host packages, LLVM 21 | below | BUILD-VERIFIED |
| 2 | OpenOrbis toolchain at `/opt/pacbrew/ps4/openorbis` | `tools/build-openorbis.sh` | BUILD-VERIFIED |
| 3 | ps4-kit at `1f2bd79` (closest public commit to v00.71) | below | checked out |
| 4 | libc overlay, libc++ 21, kit runtime | ps4-kit `prepare-sysroot.sh`, `build-libcxx.sh`, `build-runtime.sh` | BUILD-VERIFIED |
| 5 | zlib, OpenSSL, FreeType, FFmpeg, libsmb2, libnfs | `tools/build-sysroot.sh` | BUILD-VERIFIED |
| 6 | ps4-kit test app → eboot.bin, `check-oelf` OK | `~/smoke` (see below) | BUILD-VERIFIED |
| 7 | Mesa/RADV 26.0.8 + kit patches 0001–0031 | ps4-kit `gpu/build-mesa.sh` | in progress |
| 8 | Wine 11.0 + `patches/wine-ps4.patch` (46 commits apply cleanly) | upstream BUILDING step 1–2 | patch applies; build in progress |
| 9 | DXVK 3.1.1 release (sha256 `40565b4a…f54e608`) | download | done |
| 10 | `app/build.sh`, `app/package.sh` | upstream | not yet |

## 1. Host
```bash
apt-get install -y flex bison mingw-w64 meson ninja-build cmake pkg-config autoconf automake libtool gettext \
    rsync python3-mako python3-yaml glslang-tools nasm unzip zip xz-utils file patch gcc-multilib dotnet-sdk-8.0
wget -qO /tmp/llvm.sh https://apt.llvm.org/llvm.sh && bash /tmp/llvm.sh 21
apt-get install -y clang-21 lld-21 llvm-21 llvm-21-tools
```

## 2. OpenOrbis toolchain
```bash
tools/build-openorbis.sh        # fetch bin headers musl fself vars libs llvmrt pkgtool
```
Follows PacBrew's PKGBUILDs (github.com/PacBrew/ps4-openorbis) and their pinned commits, with these changes:
- clang 21 from apt.llvm.org instead of PacBrew's clang 12. ps4-kit compiles with 21 anyway.
- compiler-rt builtins and libunwind from LLVM 21.1.6.
- **create-fself `f2da622` instead of `30d2e10`**: the older one writes the data PT_LOAD twice, and the console
  refuses the eboot (CE-41839-5).
- System library stubs generated with OpenOrbis' `orbis-lib-gen` from `idc/ps4libdoc` 9.00 (493 libraries), as
  assembly. PacBrew uses a prebuilt release archive instead. The generated `libc.so` is left out so that `-lc`
  finds musl's `libc.a`.
- PkgTool (LibOrbisPkg `594021f`) on .NET 8, with ps4-kit's three fixes.

## 3–4. ps4-kit
```bash
git clone https://github.com/iHaiDeeZ/ps4-kit ~/ps4-kit-repo
git -C ~/ps4-kit-repo worktree add --detach ~/ps4-kit-v0071 1f2bd79
ln -sfn ~/ps4-kit-v0071 ~/ps4-kit
chmod +x ~/ps4-kit/toolchain/*.sh ~/ps4-kit/scripts/*.sh ~/ps4-kit/gpu/*.sh ~/ps4-kit/toolchain/bin/*
mkdir -p ~/ps4kit-build/{src,build,out,logs,oelf,host-tools/bin,sysroot/lib,sysroot/include}
bash ~/ps4-kit/toolchain/prepare-sysroot.sh
LLVM_LOCAL_SRC=$HOME/oo-src/llvm-project-21.1.6 bash ~/ps4-kit/toolchain/build-libcxx.sh
bash ~/ps4-kit/toolchain/build-runtime.sh
```
Why `1f2bd79`: upstream built v00.71 with `56b3d86`, which the public history no longer has. `1f2bd79` is the last
public commit dated 2026-11-06, the day of v00.71. It has Mesa patches 0001–0031 and
`ps4_kit_set_new_thread_priority`, which v00.71 calls.

## 5. Libraries
```bash
tools/build-sysroot.sh          # zlib openssl freetype ffmpeg libsmb2 libnfs
```

## 6. Toolchain check
A ps4-kit app with `ps4_kit_app()` and some libc++ code links to `eboot.bin`, and `check-oelf` reports
"segments OK".

## 7–10. Mesa, Wine, the app
```bash
bash ~/ps4-kit/gpu/build-mesa.sh
# Wine: docs/BUILDING.md steps 1-3 (clone wine-11.0, git am patches/wine-ps4.patch, configure, make, prefix)
WINEPS4_VERSION=00.71 app/build.sh all && WINEPS4_VERSION=00.71 app/package.sh
```
