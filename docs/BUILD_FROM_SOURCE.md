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
| 7 | Mesa/RADV 26.0.8 + kit patches 0001–0031 (build id `bbe98bd46211`) | ps4-kit `gpu/build-mesa.sh` | BUILD-VERIFIED |
| 8 | Wine 11.0 + `patches/wine-ps4.patch` (46 commits apply cleanly), host build, prefix, test programs | `tools/build-wineps4.sh wine prefix tests` | BUILD-VERIFIED |
| 9 | DXVK 3.1.1 release (sha256 `40565b4a…f54e608`) | download | done |
| 10 | `app/build.sh`, `app/package.sh` → `out/WinePS4-v00.71.pkg` (1.74 GB) | `tools/build-wineps4.sh app package` | BUILD-VERIFIED, **not DEVICE-TESTED** |

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
curl -sSfL https://github.com/doitsujin/dxvk/releases/download/v3.1.1/dxvk-3.1.1.tar.gz | tar -xz -C ~/wineps4-build
DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 WINEPS4_VERSION=00.71 tools/build-wineps4.sh   # wine prefix tests app package
```
`tools/build-wineps4.sh` fills four gaps in upstream's steps, all on the PC side (see the script's header):
- the host build of `wineps4.drv`'s Unix half, which is PS4 code;
- Wine's own fonts, which are not installed with `--without-freetype`;
- `hello32.exe`'s link (`/safeseh:no`);
- `create-gp4`, which `make-pkg.sh` calls (added to `tools/build-openorbis.sh`).

## Comparison with the official v00.71 package
Official `WinePS4-v00.71.pkg`: sha256 `95ec4804…98478c`, 1,556,938,752 bytes. Both packages were extracted with the
PkgTool built here.

| | Official | This build |
|---|---|---|
| `wineps4.bin` | 42,491,440 B | 42,261,184 B (−0.5%) |
| Its imported system libraries | 15 | the same 15 |
| Version strings | `WinePS4 v00.71 (Wine 11.0)` | the same |
| RADV build id (hash of the Mesa patch files) | different | `bbe98bd46211` (the public kit's patch files were rewritten; this only gives the shader cache a separate identity) |
| Files | 2,076 | 2,070 |
| `wine/share`, `wine/dxvk`, fonts, wallpapers, `sce_sys` | | byte-identical sizes |
| `wine/lib` (Wine's PE DLLs) | 1.21 GB | 1.40 GB |
| PE compiler | mingw-w64 GCC 13 **posix** | mingw-w64 GCC 13 **win32** (Ubuntu's default alternative) |
| Prefix | stale copies of `kernelbase.dll`, `msctf.dll`, `wineps4.drv` kept in system32/syswow64 | identical to `lib`, so `package.sh` dedupes them into `system32-from-lib.txt` |

To get closer: `update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix` (and the
i686 and g++ ones), then rebuild Wine.

## Why run #4's comparison failed, and what changed (2026-11-19)
Run #4 (commit `26075a4`) built and verified the package, but its comparison found 1,682 Wine PE files with other
bytes that it could not explain, so it published nothing. The investigation ran in the Claude session on samples
(ntdll, user32, kernelbase, both architectures). Results are LOCAL VERIFIED unless marked otherwise:

| Finding | Evidence | Change |
|---|---|---|
| The official **i386** DLLs are **clang's**, the x86_64 ones mingw GCC 13-posix | 589 of 601 i386 DLLs carry `Ubuntu clang version 21.1.8 (6ubuntu1)` and none GCC's; `tests/build.sh` says "there is no 32-bit mingw here", so Wine's configure fell back to `clang -target i686-windows` | `i386_CC=clang-21` (`WINE_I386_CC`) |
| The official build has **no translations** | user32's resources: 2 languages, 45 here. The developer's machine had no `msgfmt`, which turns Wine's `po/` off | `--without-gettext` (`WINE_GETTEXT`) |
| With both: every section has the official size, and `.rsrc` is byte-identical | `tools/pe-sections.py` | |
| Build paths in debug info | official DWARF: `/home/shiro/wine-ps4-build/build/wine-wow64` | CI builds with `HOME=/home/shiro` (comparison only) |
| x86_64, same paths: **32 bytes** in `.text`/`.rdata` | `__CTOR_LIST__`/`__DTOR_LIST__` in `.rdata` in the official package (section 3, 0x173e0) and at the end of `.text` here (section 1, 0x71690). Our GNU ld is 2.41.90.20240122; the developer's places them in `.rdata` (version UNVERIFIED). Plus the COFF symbol table past the sections, which Windows does not load | classified as `ctor-list`, `symtab` |
| i386, same paths: 3-byte runs between functions | `0f 1f 00` (official) vs `90 90 90` (here) after `ret`: NOP padding, never executed | classified as `padding` |
| i386: build timestamps | a dword equal to each file's own COFF TimeDateStamp (debug directory) | classified as `timestamp` |
| i386 user32: **1,459 other bytes** | different `call` displacements: a function of another size. Most likely the other clang build (Ubuntu's 6ubuntu1 vs apt.llvm.org's), **UNVERIFIED** | stays UNEXPLAINED |
| Prefix: Windows user folder name | `C:\users\shiro` (official `user.reg`) vs the build machine's user. `userdef.reg` becomes identical (apart from timestamps) when wineboot runs as `shiro` | CI makes the prefix as `shiro` (`WINE_PREFIX_USER`, comparison only; the console's user is `ps4` either way) |
| Prefix: 40 MIME `Content Type` keys here, none in the official `system.reg` | written by `dlls/mshtml/mshtml.inf` [FileAssoc.Reg] when wineboot registers mshtml; the rest of mshtml's registration is in both. The official prefix also keeps older builds of 3 DLLs, which suggests it was made at another time with another Wine build. **UNVERIFIED** | stays UNEXPLAINED |

`tools/pelib.py` classifies every differing byte of a PE file by what the bytes are (padding, ctor-list, debug, symtab,
timestamp, header); anything else counts as "other", and a file with "other" bytes leaves the comparison failed.
The registry files are compared with only their timestamps taken out.

## Run #5's remaining differences: a limited investigation (2026-11-19, LOCAL VERIFIED unless marked)
Run #5 (`0869c77`, GITHUB ACTIONS VERIFIED): i386 at +0.4% (was +38%), 402 of 741 x86_64 PE files fully classified,
5 differences left unexplained. Investigated in the Claude session, in a Wine build configured as CI's (the same
`/home/shiro` paths, x86_64 mingw-w64 GCC 13-posix, i386 clang-21, `--without-gettext`, `--disable-tests`), with the
identical mingw-w64 packages (`binutils-mingw-w64-x86-64 2.41.90.20240122-1ubuntu1+11.4`,
`gcc-mingw-w64-x86-64-posix 13.2.0-6ubuntu1+26.1`: the same in run #5's apt log).

| Item | Finding | Evidence |
|---|---|---|
| x86_64: 339 files with "other" bytes (winedbg, wined3d, mshtml the largest) | **CI's configure was run by an absolute path; upstream's by a relative one.** Every `__FILE__` (Wine's debug channels, asserts) then embeds `/home/shiro/wine-ps4-build/src/wine/...` instead of `../../src/wine/...`, which changes `.rdata`'s strings and shifts `.text`'s addresses | The official wined3d.dll holds 495 `../../src/wine/` strings and no absolute one (winedbg.exe: 236 and 0). Upstream `docs/BUILDING.md:20` runs `../../src/wine/configure`; `tools/build-wineps4.sh` runs `"$SRC/configure"`. Run #5's make.log compiles `/home/shiro/wine-ps4-build/src/wine/programs/winedbg/break.c`. Built locally with the relative path, then `winebuild --builtin` as `make install` does: winedbg.exe, wined3d.dll and mshtml.dll have **0 other bytes** (ctor-list 32, symtab only) |
| i386: another clang build | the official i386 DLLs say `Ubuntu clang version 21.1.8 (6ubuntu1)`: Launchpad lists `1:21.1.8-6ubuntu1` as the release of Ubuntu 26.04 LTS (Resolute Raccoon). This build uses apt.llvm.org's 21.1.8 on Ubuntu 24.04 | consistent with the other clues (GCC 15 in the official test programs; a GNU ld that puts the CTOR lists in `.rdata`); that the developer built on 26.04 is UNVERIFIED |
| `system.reg`: mshtml.inf | none of mshtml.inf's `Classes.Reg` (0 of 29 keys), `Protocols.Reg` (0 of 6) or `IE.Reg` (0 of 4) is in the official prefix, 7 of 120 `FileAssoc.Reg` keys (other registrations write those): **the whole of mshtml.inf** (`RegInstall` through advpack, `dlls/mshtml/main.c:692-758`) was not applied when the official prefix was made, not only the MIME types | why is UNVERIFIED (no wineboot log of the developer's) |
| `user.reg`, `system.reg`: the computer name | `programs/wineboot/wineboot.c:904-910` sets `USERDOMAIN` to `GetComputerNameW()` and `LOGONSERVER` to `\\` + it; lines 828-851 the `ComputerName` and `Hostname` keys from the build machine's host name. The official prefix: `DESKTOP-6QPFRA3` in those 4 places; run #5's: its runner's name | source-level |

The comparison's report printed the x86_64 kernelbase's compiler on every area's line; it now prints the area's own
architecture's (`tools/compare-pkg.py`, reporting only: the classifier is unchanged).

## Device test of run #7's package: it does not start (2026-11-20, DEVICE TESTED)
Run #7's NOT ACCEPTED package (sha256 `6601c3ec…`) on the PS4 Slim, HEN 12.50, GoldHEN v2.4b18.10: **CE-34878-0** as
it starts; no `crash.log` and no `launcher.log` (so the launcher did start `wineps4.bin`, and the crash came before
ps4-kit's crash handler). The official v00.71 works again after going back to it. Read-only analysis of the two
packages' eboots (LOCAL VERIFIED):

| Imported from libkernel | wineps4.bin: ours / official | eboot.bin (launcher): ours / official | Cause |
|---|---|---|---|
| `__stack_chk_guard` (a variable), `__stack_chk_fail` | yes / no | yes / no | musl, compiler-rt and libunwind built with `--target=x86_64-scei-ps4`, for which clang 21 turns the strong stack protector on by default (`-stack-protector 2`, `__stack_chk_guard@GOTPCREL`); the orbis-lib-gen stubs also mark every symbol a function, this variable included. **Fixed**: `-fno-stack-protector` (tools/build-openorbis.sh); both eboots relinked locally import neither |
| `madvise` | yes / no | no / no | OpenSSL's secure heap (`libcrypto-lib-mem_sec.o`, `ld.lld -y madvise`); not changed |
| `pthread_once` | no / yes | no / yes | ps4-kit 1f2bd79 wraps pthread_once for every caller (`__wrap_pthread_once`, ps4_runtime.cpp:2077); upstream's kit 56b3d86 is not public; not changed |
| `pthread_rwlock_rdlock`, `_wrlock`, `_unlock` | – | no / yes | the same kit difference, most likely; not investigated |

Whether `__stack_chk_*` is what crashed the app is UNVERIFIED (a device test of a build without them will tell).
The comparison now lists every eboot's imported system symbols by name (ps4libdoc) and fails on any difference.

## Run #9 and its review: the official package's build machine (2026-11-20)
Run #9 (commit 8941254, GITHUB ACTIONS VERIFIED): every build stage and check passed; neither `eboot.bin` nor
`wineps4.bin` imports `__stack_chk_guard`/`__stack_chk_fail` any more (checked in the PKG CI made; PKG sha256
`9a3024c7a935ed136e1e0a243a9e1148e5b2f5a7160d7b057449ee4e7f9e982f`). Not run on a console. The comparison still
fails, 7 unexplained differences. What the review found (LOCAL VERIFIED):

- **The tools in the official PE files are Ubuntu 26.04's.** Its i386 DLLs say `Ubuntu clang version 21.1.8
  (6ubuntu1)`: 26.04's `clang-21` is `1:21.1.8-6ubuntu1`, and 24.04 has no clang 21 (this build used apt.llvm.org's).
  Its 741 x86_64 DLLs have linker version 2.45: 26.04's `binutils-mingw-w64-x86-64` is built from binutils
  2.45.90; 24.04's from 2.41.90, which this build's 2.41 files show. GCC is the same in both (13.2.0-6ubuntu1, posix).
  The linker version also brings a Load Config directory (320 bytes) into every official x86_64 DLL, and none here.
- **The prefix's PE files**: 91 of the 96 that differ are each package's own copies of its lib files; the other five
  are an older `explorer.exe` copy in the official prefix and four 16-bit files Wine extracts from the i386 builtins
  (`dlls/setupapi/fakedll.c`). They all come down to the lib differences.
- **system.reg**: the 595 lines only here are mshtml's registration (every extension and CLSID in them is in
  `dlls/mshtml/mshtml.inf` or `mshtml_classes.idl`); the 18 changed lines are the build machine (name, CPU, time zone,
  `MachineGuid`, device ids). Why the official prefix has no mshtml registration is not known. **user.reg**: the
  machine name only.
- **Imports**: `madvise` is OpenSSL's secure heap. Kit 1f2bd79 wraps `pthread_once` in every link (since its first
  commit), so this build never imports it; the official binaries do, and its kit (56b3d86) is not public.
  `pthread_rwlock_*`: in 1f2bd79 only as names in `runtime/ps4_sampler.cpp`. Both unexplained.
- **A gap in the comparison, fixed (stricter only)**: `tools/pelib.py` took the end of the PE headers from the smallest
  section offset, 0 for a section without file data (`.bss`), and skipped the header check of 655 x86_64 DLLs. The
  "650 of 741 clean" of runs #6-#9 was wrong: 0 of 741 are, once the headers are compared. Still 7 unexplained.

To test the build machine as the cause, `BUILD_OS=26.04` (the workflow's `build_os` input) runs the whole build in an
`ubuntu:26.04` container (`tools/ci-run.sh`): Ubuntu's own clang-21 and mingw binutils 2.45, and .NET 10 for PkgTool
(26.04 has no .NET 8). `24.04` builds as before.

## Run #11: built on Ubuntu 26.04 (2026-11-20, GITHUB ACTIONS VERIFIED)
Commit 91a3c22, `build_os=26.04` (run #10 stopped at the i386 `libcompiler-rt.a`: winebuild needs the unversioned
`llvm-ar`/`clang`, which GitHub's 24.04 image has and a bare 26.04 has not; 26.04's `clang`, `llvm` and `lld` packages
give them for the same clang-21). Every stage and check passed; PKG sha256
`57fdfa5f13dde46278a8aca8475aa6d16c738ab6a6e9b9061a945fe57245210c`; no `__stack_chk_*` import, the same import lists as
run #9. Not run on a console.

The build machine was the cause of the Wine PE differences: the i386 and x86_64 DLLs now have the official
package's exact total sizes (460,677,120 and 753,110,528 bytes), and all 792 + 741 differing ones are clean (no
unexplained byte; what differs is debug information, the symbol table, timestamps and the header fields they move).
Unexplained: 5 (run #9: 7) - system.reg (mshtml's registration and the build machine), user.reg (the machine name, and
4 `MimeType` values: without `shared-mime-info` winemenubuilder names file types `application/x-wine-extension-*`,
`programs/winemenubuilder/winemenubuilder.c:2131`; now installed on 26.04), the official prefix's older `explorer.exe`
copy, and the two eboots' imported symbols. `26.04` is now the workflow's default.

## Run #12 and its review (2026-11-20, LOCAL VERIFIED unless marked)
Run #12 (commit cff8754, 26.04 with `shared-mime-info`, GITHUB ACTIONS VERIFIED): user.reg differs from the official
only by the build machine's name. Its `wineps4.bin` differs from run #11's (the same source) in 261,862 bytes, all from
the Mesa commit hash in Mesa's version string (`git-02a4d19e11` vs `git-c79eb75487`): ps4-kit's `gpu/build-mesa.sh`
applies its patches with `git am`, which dates each commit when it runs. What differs: the merged string block,
reordered (235,027 bytes); the code's rip-relative references (12,276), absolute pointers (7,081), relocations (7,081 in
SCE_DYNLIBDATA) and offsets (358) to the same strings; the ELF's SHA-256 in the SELF extended info (32). Of those
offsets, 17 entries (20 bytes) point to the same strings in both builds but their table base is not identified.
`tools/ci-build.sh` now gives `git am` one commit date (`GIT_COMMITTER_DATE`, Mesa and Wine), so the hash, and with
it `wineps4.bin`, should be the same on every build: two runs of one commit check it.

The comparison (commit 43375de): ctor-list only for whole aligned pointer-size words, -1 on one side and 0 on the
other, in `.text`/`.rdata` (before, a 0xff byte of code changed to 0x00 passed); a prefix PE file explained, file by
file, when this build's copy is byte-identical to its own lib file, the official copy is not the official lib file, and
the two lib files are the same or clean (`explorer.exe`). Runs #11/#12 then: 4 unexplained (system.reg, user.reg's
machine name, the two eboots' imported symbols); run #9: 7.

## Reproducibility: runs #13-#16 (2026-11-20)
Runs #13 and #14 (commit ae93429, one `GIT_COMMITTER_DATE`): the same `wineps4.bin` and `eboot.bin`; 1,628 Wine PE
files differed only by `TimeDateStamp` and the header checksum it moves (lld-link writes it into the i386 files, GNU
strip at `make install` into the x86_64 ones, both the current time unless `SOURCE_DATE_EPOCH` is set).

Runs #15 and #16 (commit beef6e9: `SOURCE_DATE_EPOCH=1767225600`, build container host name `wineps4-build`), GITHUB
ACTIONS VERIFIED, compared file by file LOCAL VERIFIED: **2,066 of the 2,070 files are byte-identical**, among them
`wineps4.bin` (`24cc60a6...`), `eboot.bin` (`a155defd...`) and every Wine PE file. The other four are the prefix's
registry and its stamp, which wineboot makes differently on every run by design:
- `.update-timestamp`: when the prefix was made.
- `user.reg`, `userdef.reg`: only the keys' write times (`[key] <seconds>`, `#time=`).
- `system.reg`: the keys' write times, and 8 values: `MachineGuid` (random, `dlls/advapi32/crypt.c`), the HID and
  WINEBUS devices' `ContainerId` (a performance counter value, `dlls/winebus.sys/main.c` make_unique_container_id),
  the GPU's `VideoID` (random, `dlls/win32u/sysparams.c` uuid_create) and the monitor's GPU LUID property
  (`{CA085853-...}\0001`, assigned at run time).

So the build is reproducible for everything the console runs; the prefix's registry is not, and is documented here
value by value rather than normalised. The PKG files differ because these four do. The comparison with the official
package: 4 unexplained (system.reg's mshtml registration, user.reg's machine name, the two eboots' imported symbols).
Not run on a console.
