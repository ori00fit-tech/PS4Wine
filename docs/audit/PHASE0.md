# WinePS4 Enhanced — Phase 0 Audit Report (read-only)

Date: 2026-11-19 · Scope: read-only. No file in `ori00fit-tech/PS4Wine` was edited, committed or pushed.

> **Status:** rebuilding the upstream v00.71 release from source has NOT been proven yet (see B3, B5).
> Branch `upstream-v00.71` = upstream tag `v00.71` = commit `fd9595f98a9a495f19da295fe07d11f20578d50f`, unmodified.
> (The tag itself could not be pushed from this environment; the commit is identical.)

Evidence tags: **CODE-VERIFIED** (read in source), **DOC-VERIFIED** (stated in upstream NOTES/README, not re-checked),
**UNVERIFIED** (inference / not yet checked). Nothing in this report is BUILD-VERIFIED or DEVICE-TESTED.

---

## 0. Blocking facts found first

| # | Finding | Tag |
|---|---|---|
| B1 | At audit time the fork `ori00fit-tech/PS4Wine` was empty. **Resolved 2026-11-19:** `upstream-v00.71` and `development` were created at `fd9595f`. | CODE-VERIFIED |
| B2 | Upstream `iHaiDeeZ/WinePS4`: `main` = tag `v00.71` = `fd9595f` (82 commits, last 2026-11-13). | CODE-VERIFIED |
| B3 | `docs/BUILDING.md:3` says v00.71 was built with **ps4-kit `56b3d86`**. That commit **does not exist** in public `iHaiDeeZ/ps4-kit` (HEAD `79d173b`, 32 commits, history starts 2026-10-29 "Initial import"). The history was rewritten when it was published, so **the exact v00.71 toolchain can't be reproduced bit for bit**. | CODE-VERIFIED |
| B4 | Public ps4-kit includes Mesa patch **0032** (2026-11-17, after v00.71), which changes RADV pipeline switching. Building from today's kit gives a RADV that differs from the release. To be close to v00.71, use the series up to 0031. | CODE-VERIFIED |
| B5 | ps4-kit's **sysroot is not reproducible from public sources**: `scripts/seed-build-tree.sh` copies it from `~/vita3k-build/sysroot`, a private tree of another port. It holds OpenSSL (`libcrypto.a`, which WinePS4 links for bcrypt), zlib, FFmpeg and others. No script in either repo builds OpenSSL or zlib for the PS4. `prepare-sysroot.sh` / `build-libcxx.sh` rebuild only the libc overlay and libc++. | CODE-VERIFIED |
| B6 | `docs/BUILDING.md` and `app/package.sh` mention `scripts/build-host-wine.sh` and `scripts/make-prefix.sh`. **Neither file is in the repo**. BUILDING.md gives the commands inline instead. | CODE-VERIFIED |
| B7 | **Upstream's only recorded test console is FW 13.52** (`NOTES.md:3`, "Probe v00.01 ... FW 13.52"). Your console is on **FW 13.50** (corrected by the user; first written as 12.50), close to 13.52, so this risk is low. The kernel struct offsets the freeze report reads (`kinfo_proc` 1096-byte records, `NOTES.md:687,781`), the budget syscalls and the direct-memory aliasing behaviour were all measured on 13.52 only. | DOC-VERIFIED |
| B8 | **v00.71 itself was never confirmed on a console.** NOTES ends with "To check: the priorities line; Iron Snout's RADV starting; no freeze when a game starts or closes" (`NOTES.md:829`). The v00.71 baseline is a release whose main fix (thread priorities) is untested. | DOC-VERIFIED |

---

## 1. Repository map (upstream v00.71, 132 files, 8 MB)

| Path | What it is | Size |
|---|---|---|
| `patches/wine-ps4.patch` | **The Wine changes**: 46 `git am` commits on Wine `wine-11.0`. The source of truth for Wine edits. | 322 KB |
| `wine-overlay/` | New files that the patch also adds: `dlls/wineps4.drv` (display + audio + Vulkan surface driver), `server/ps4_input.inc` | 90 KB |
| `port/` | PS4 platform layer linked into the eboot (8.7k lines C) | |
| ├ `ps4_wine_vm.c` | **Memory layer**: wraps mmap/munmap/mprotect/madvise for ntdll and wineserver (1038 lines) | |
| ├ `ps4_spawn_desk.c` | **Process manager**: local processes (the 7), outside processes, memory guard, stats (1174 lines) | |
| ├ `ps4_wine_port.c` | Threads, signals, GS/FS base, dlopen table, fork/spawn, anon shm, GPU address space release (1073 lines) | |
| ├ `ps4_main.c` | Entry point, prefix setup, env.txt, DXVK install, user.reg defaults, heap configuration (1564 lines) | |
| ├ `ps4_kstate.c` | Freeze diagnostics: kern.proc thread view, memory census, memory probe (1062 lines) | |
| ├ `ps4_audio_desk.c` | Desktop audio mixer (sceAudioOut) | |
| ├ `ps4_ifaddrs.c`, `ps4_net.c` | getifaddrs etc. over FreeBSD ioctls (nsiproxy) | |
| ├ `ps4_unixlibs.c` | Table of built-in Unix libs (win32u, winevulkan, ...) for ntdll's dlsym | |
| └ `include/ps4_wine_compat.h` | Force-included in all Wine Unix code: FreeBSD constants, `#define mmap ps4_vm_mmap`, ... | |
| `shell/` | The Windows-11-style desktop, drawn on the CPU. `desktop.cpp` alone is **333 KB in one file**. | 1.1 MB |
| `app/` | `CMakeLists.txt` (one eboot from Wine Unix sources + port + shell), `build.sh`, `package.sh`, launcher, fonts, certs | |
| `probe/`, `baseprobe/`, `processprobe/` | Standalone on-console probe apps from the research phase | |
| `scripts/apply-*.py`, `desktop-v19/20.py` | **Historical** one-off edit scripts (`apply-ps4-edits.py`: "kept for the record; the patch is the source of truth") | |
| `tests/` | 3 tiny Windows test programs (hello, hello32, window). **No automated test suite and no CI.** | |
| `NOTES.md` | The engineering log v00.01→v00.71: the most valuable document in the repo | 67 KB |

ps4-kit (MIT): `runtime/` (dlmalloc heap with direct/flexible/overflow heaps, stdio lock, crash log, sampler,
priorities), `gpu/` (Mesa 26.0.8 + 32 patches, `ps4_vk_wsi.cpp` swapchain/window mode), `toolchain/` (clang 21,
libc++ 21.1.6, libc overlay), `scripts/make-pkg.sh`.

---

## 2. Architecture

```
PS4 app WINE00002 (GoldHEN)
│
├─ eboot.bin (launcher) ──exec──► /app0/wineps4.bin  (ET_SCE_EXEC, linked at 0x60000000 to leave 0x400000 free)
│
├─ DESKTOP PROCESS (first process: owns VideoOut, the app's GPU VM space at start)
│   ├─ wineserver ............ a THREAD, not a process (prio 600)
│   ├─ shell/ desktop loop ... CPU-drawn UI, input (pad, IME, USB kbd), Task Manager (prio 640)
│   ├─ audio mixer ........... sums WASAPI rings from programs → sceAudioOut (prio 450)
│   ├─ spawn monitor/broker .. starts every Windows process
│   ├─ memory guard .......... kills Steam's web helper when flexible pool < 96 MiB
│   └─ freeze watch / kernel report (prio 300)
│
├─ LOCAL PROCESSES (max 7, sceSystemServiceAddLocalProcess) — explorer.exe, programs, games (prio 700; web helpers 760)
│   each = /app0/wineps4.bin --wineps4-local, gets args/env/fds over a socket (HELLO/READY/STAT/EXIT)
│   memory: Wine VM pages → app DIRECT memory; everything else → app FLEXIBLE pool
│
└─ OUTSIDE PROCESSES (vfork+exec, budget_set(0): outside the app's budget) — services, winedevice, rpcss,
    svchost, msiexec, conhost, crash reporters...
    memory: REGULAR FLEXIBLE only (system pool, ≤256 MiB each, pool floor 128 MiB), never direct memory
    (direct memory in non-app processes caused kernel panics in v00.30–42)

Graphics:  program → DXVK 3.1.1 (d3d8–11) → winevulkan → RADV (Mesa 26.0.8 + PS4 patches over GNM)
           → kit WSI "window mode": linear host-visible swapchain → GPU wait → frame copied (8 MB @1080p)
             over a socket → desktop composites it.   One program on the GPU at a time.
```

---

## 3. Memory allocation map (core of Phase 3)

| Pool | Size (13.52 measurements) | Who uses it | What happens when it runs out |
|---|---|---|---|
| **App direct memory** | 4608 MiB, shared by the desktop and all local processes | Wine VM pages (ps4_wine_vm.c, 64 MiB chunks), desktop C heap (≤384 MiB), program C heaps (64 MiB + 8×64 MiB overflow), RADV/GPU buffers, screen buffers | mmap fails → ENOMEM → Windows out-of-memory (Chromium 0xE0000008). Recoverable. |
| **App flexible pool** | ~1 GiB max, 448 MiB at app start in one log | Every non-VM anonymous mapping of local processes: **Wine sections / shared memory (Chromium: 223 MiB in one log)**, the binary's data+bss (12.6 MiB per process), stacks | **The faulting thread waits in the kernel forever → whole app freezes** (v00.63–66). Not recoverable. |
| **System pool** (regular flexible) | ~420–656 MiB | Outside processes, and **the PS4's own system memory** | Below ~13 MiB the PS4 kills the whole app (AppCrash 0xa002008f, v00.53/v00.59) |

**Key point for the "Memory Engine" goal:** the freezes came from the *flexible* pool and from CPU starvation, not
from the total amount of memory. Direct memory still had 1.1–1.4 GiB free when the app froze (`NOTES.md:596,712`).

### How `ps4_wine_vm.c` works (CODE-VERIFIED)
- `PROT_NONE` anonymous mmap → only `sceKernelReserveVirtualRange` (no memory used). Page state lives in a 2-level
  table, 16 KiB granularity: `UNTRACKED / RESERVED / FLEXIBLE / DIRECT+index` (`:62-75, :110-161`).
- First access (mprotect or mmap with prot) → `back_range` maps direct memory and **memsets it to zero** (`:274-345`).
- Direct memory comes from the kernel in **64 MiB chunks**, at most 80 (`new_chunk :168`). Each process keeps
  256 MiB in reserve (`WINEPS4_DIRECT_RESERVE_MB`).
- File mappings at fixed addresses are refused (ENODEV) so Wine reads PE images into memory, because file
  mappings can't run code on the PS4.
- Chromium's 32 GiB reservations are placed from the top of the app area down (`reserve_high :450`).
- `madvise` is a no-op (`:732`). Decommit still works, because Wine decommits with `mmap(MAP_FIXED, PROT_NONE)`,
  which ends up in `release_range`.

---

## 4. Process lifecycle map (CODE-VERIFIED, `ps4_spawn_desk.c`)

```
CreateProcess (ntdll patch) ─► desktop broker ─► ps4_local_spawn
   ├─ background program (services, svchost, ...) or 7 already used or direct memory < 384 MiB free
   │     └─► start_outside: vfork → budget_set(0) → exec wineps4.bin --wineps4-outside (needs pool ≥ 256 MiB)
   └─ else start_local: sceSystemServiceAddLocalProcess (8th → 0x80aa0008)
HELLO(pid) → desktop sends argv/env/fds → READY → program runs → STAT every 1 s (cpu, VM bytes, flexible, shared)
EXIT(code) → socket closes → control_event: KillLocalProcess / SIGKILL → ps4_process_ended
Desktop ends → every outside process sees its socket close and exits.
```
Windows' own processes run outside the 7 (services, winedevice, rpcss, ...). Chromium runs as a single process
(`--single-process`). Some Steam helpers are refused.

---

## 5. Build dependency inventory

| Component | Version | Source | Reachable from this container? |
|---|---|---|---|
| Wine | `wine-11.0` tag + `patches/wine-ps4.patch` (46 commits) | gitlab.winehq.org | ✅ HTTP 200 |
| Host Wine build (PE DLLs, WoW64) | same tree | needs mingw-w64, flex, bison | ❌ mingw-w64 and flex not installed here (bison is) |
| ps4-kit | `56b3d86` (**not public**); public HEAD `79d173b` | github | ✅ cloned |
| OpenOrbis C runtime (musl) | via PacBrew at `/opt/pacbrew/ps4/openorbis` | github PacBrew / OpenOrbis | ❌ **HTTP 403 from this environment's proxy** |
| clang / lld / llvm-objcopy | **21** (`CLANG_VER`) | apt.llvm.org | ⚠️ host has clang 18 only; apt.llvm.org reachable |
| libc++ / libc++abi | 21.1.6 | llvm releases | via `build-libcxx.sh` |
| Sysroot: OpenSSL 3.5, zlib, FFmpeg 7.1, ... | from a private tree | **no public recipe** | ❌ (B5) |
| Mesa / RADV | 26.0.8 + kit patches 0001–0031 (v00.71) / 0032 (now) | gitlab.freedesktop.org | ✅ HTTP 200; needs meson, mako, glslangValidator, libdrm headers |
| DXVK | 3.1.1 release, unchanged | github | ✅ HTTP 200 |
| FreeType | 2.13.3, static | upstream | not checked |
| FFmpeg (image decoders) | 7.1.1, `scripts/build-ffmpeg-img.sh` | upstream | not checked |
| PKG tooling | kit `scripts/make-pkg.sh`, `build-pkgtool.sh` | | not checked |

Container: x86_64, 4 cores, 15 GiB RAM, about 60 GB free disk. Enough for Wine and Mesa builds. Upstream's scripts
assume WSL with hard-coded paths (`~/ps4-kit`, `~/wine-ps4-build`, `~/wineps4-build`, `~/ps4kit-build`).

---

## 6. Confirmed and possible problems (relevant to the Memory Engine goal)

| ID | Finding | Evidence | Tag | Why it matters |
|---|---|---|---|---|
| **M1** | **A process never gives direct memory back to the app pool while it runs.** Freed pages go to a per-process free list (`give_direct`), and the 64 MiB chunks are never passed to `sceKernelReleaseDirectMemory`. The memory is reused inside the same process, but **other processes can't use it until this process exits**. | `ps4_wine_vm.c:168-222`; `grep ReleaseDirectMemory` hits only the section and probe code | CODE-VERIFIED | Your main goal: "is memory really freed after closing a program?" A long-lived process (steam.exe, explorer.exe) keeps its high-water mark. |
| **M2** | **Task Manager under-reports.** The per-process "memory" figure is `ps4_vm_backed_bytes()` = pages backed *now*. It leaves out the free-list pages the process still holds (and the C heap, RADV and the GPU). | `ps4_wine_vm.c:225`, `ps4_spawn_desk.c:851` | CODE-VERIFIED | Your baseline numbers would be wrong. A *held* figure (`chunk_count×64 MiB`) is needed next to the *backed* one. |
| M3 | Free-list fragmentation: `take_direct` reuses only runs that are contiguous at the top of the stack. After mixed frees, backing turns into one `sceKernelMapDirectMemory` call plus a 16 KiB memset per page. | `ps4_wine_vm.c:194-222` | CODE-VERIFIED (mechanism) / UNVERIFIED (cost) | Possible slowdown in allocation-heavy programs. Measure before changing. |
| M4 | Level-2 page tables (256 KiB each, from the C heap) are never freed once a partly used GiB becomes empty. | `page_set :117`, `forget_range :231` | CODE-VERIFIED | Small, slow heap growth in long sessions. |
| M5 | `free_pages[80×4096]` is a 1.25 MiB static array in every process's bss. bss is flexible memory, ×7 processes. | `ps4_wine_vm.c:81` | CODE-VERIFIED | About 9 MiB of the scarce flexible pool. Small but cheap to fix. |
| M6 | `ps4_section_release` decrements counters even when the release fails, and reports a failure only once. | `ps4_wine_vm.c:916-928` | CODE-VERIFIED | Direct-shared-memory path only, which is off by default. |
| M7 | **Direct Shared Memory (your Phase 3E) already failed on hardware**: the PS4 refused cross-process maps of desktop-allocated direct memory (`0x8002000d`). It is now off by default. | `NOTES.md:749-751`, `ps4_wine_vm.c:756-760` | DOC-VERIFIED (13.52) | Retest on 12.50 only as an experiment. Don't plan around it. |
| P1 | **Scheduling**: the PS4 schedules strictly by priority, with no time-slicing between equal priorities. v00.71's fixed priorities are untested. Two busy programs at 700 can still starve each other, and a spinning desktop thread at 640 would starve every program. | `ps4_prio.h`, `NOTES.md:797-803,829` | DOC-VERIFIED / UNVERIFIED | Phase 4 item #1. Verify on the device first. |
| P2 | The flexible-pool freeze is only *mitigated* (the memory guard kills web helpers). There is no fix for non-Chromium programs that fill the pool. The guard says "the app may stand" and does nothing more. | `ps4_spawn_desk.c:715-790` | CODE-VERIFIED | Real target for a "Memory Pressure Controller". |
| P3 | Per-process heap overhead: each local process maps a 64 MiB direct C heap up front (down from 256 MiB in v00.59). | `NOTES.md:370` | DOC-VERIFIED | Tuning candidate. |
| G1 | Every game frame is waited for on the GPU, then copied by the CPU (8 MB at 1080p) through a socket. NOTES calls it "a first path ... sharing the frames' memory is the next one". | `NOTES.md:345` | DOC-VERIFIED | Largest known graphics cost. Phase 5 target. |
| I1 | No controller in games: winebus isn't built, and the pad only drives the desktop pointer. | `NOTES.md:563-564` | DOC-VERIFIED | Phase 6 starts from zero. |
| Q1 | No automated tests, no CI, `desktop.cpp` is one 333 KB file, and the patch is one 322 KB file. | repo | CODE-VERIFIED | Changes need careful patch management: rebase the 46 commits in a real Wine git tree, never hand-edit the .patch. |

Configuration surface (env.txt) found in the code: `WINEPS4_VM_LOG`, `WINEPS4_DIRECT_RESERVE_MB`,
`WINEPS4_OUTSIDE`, `WINEPS4_OUTSIDE_MAX_MB`, `WINEPS4_SECTIONS_DIRECT`, `WINEPS4_MEMORY_GUARD`, `WINEPS4_PERF_LOG`,
`WINEPS4_FREEZE_REPORT`, `WINEPS4_HANG_DUMP`, `WINEPS4_CRASH_TRACE`, `WINEPS4_DXVK`, `WINEPS4_CHROMIUM_ONE_PROCESS`,
`WINEPS4_LARGE_ADDRESS_AWARE`, `WINEPS4_PROCESS_RULES`, plus the audio, Vulkan, socket, keyboard and files logs.

---

## 7. Corrections to the master plan

1. **Phase 1 (build) is blocked** by B3, B5 and the OpenOrbis 403. Without a PS4 sysroot (OpenSSL, zlib) and the
   OpenOrbis runtime, nothing in `port/` can be compiled here. What *can* be built here: the patched Wine host
   build (PE DLLs) and Mesa. That checks that the patch applies, not that it runs on the PS4.
2. **Phase 3E (Direct Shared Memory)** should move from "advanced step" to "known-negative, retest only" (M7).
3. **Phase 2 baseline needs M2 fixed first, or at least understood.** Today's Task Manager memory figure can't
   show reclamation correctly.
4. **Firmware**: the console is on 13.50 (upstream measured on 13.52). Still record the GoldHEN version.
5. The repo's licence is LGPL-2.1-or-later and ps4-kit is MIT. Keep `LICENSE` and `CREDITS.md` in the fork.

---

## 8. Recommended next task

**Phase 0.5: set up the fork (needs your approval, because it pushes to GitHub):**
push upstream `v00.71` (`fd9595f`, with the tag) to `ori00fit-tech/PS4Wine` as `upstream-v00.71` (never modified),
then create `development` from it. Then add this report as `docs/audit/PHASE0.md` on `development`.

**Then the first engineering task (small, low-risk, measurable):** M2 + M1 instrumentation only, with no change in
behaviour. Add a "held" figure per process (chunks × 64 MiB, free-list pages) to STAT, the Performance log and
Task Manager, so the baseline can tell *backed*, *held* and *returned-on-exit* apart. That gives you the reliable
reclamation measurement the plan calls the foundation, before any optimisation.

Things only you can provide: console firmware and GoldHEN version, and a decision on how to obtain a PS4 sysroot
and OpenOrbis (they are blocked here; see B5 and the 403).
