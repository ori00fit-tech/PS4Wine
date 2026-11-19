# WinePS4 Enhanced — Phase 1: Direct Memory Allocator Investigation (read-only)

Date: 2026-11-19 · Baseline: upstream `v00.71` (`fd9595f`), ps4-kit public `79d173b` · Target console: PS4 Slim, **FW 12.50** (GoldHEN v2.4b18.10, Baikal B1)
No code was changed. Tags: **CODE-VERIFIED**, **DOC-VERIFIED** (upstream NOTES.md, not re-checked), **UNVERIFIED**.

> Firmware: the console's System Information shows HEN 12.50 (GoldHEN v2.4b18.10). Upstream measured on 13.52.
> The official v00.71 starts on 12.50, but the kernel struct offsets the freeze report reads still need one
> confirmation run (the freeze report prints its own layout check: `NOTES.md:781`).

---

## 1. Who allocates direct memory in a process (the full list)

Wine's VM layer is **one of several** direct-memory users. An accounting design has to separate them.

| Allocator | Where | Granularity | Given back while the process runs? | Tag |
|---|---|---|---|---|
| **Wine VM layer** (Windows memory: VirtualAlloc, PE images, stacks, Wine heaps) | `port/ps4_wine_vm.c:168-222, 274-345` | 64 MiB chunks, handed out in 16 KiB pages | **No.** Pages go to a per-process free list; chunks are kept. | CODE-VERIFIED |
| **C library heap** (ps4-kit dlmalloc; Wine's Unix side, the desktop, RADV's malloc) | `ps4-kit/runtime/ps4_runtime.cpp:411-428` main heap, `:640-690` overflow heaps; sizes in `port/ps4_main.c:118-165` | main heap: desktop 384 MiB, program 64 MiB; overflow heaps of 64 MiB, up to 8 | **Main heap no. Overflow heaps yes**, after two empty checks (`trimOverflowHeaps`, `ps4_runtime.cpp:964-995`) | CODE-VERIFIED |
| **RADV / GPU buffers** (DXVK) | ps4-kit `gpu/mesa-patches/0002` (`ac_ps4_drm.c`), 0030/0031 placed maps | per buffer object | Not audited in this phase | UNVERIFIED |
| **Sections in direct memory** (off by default) | `ps4_wine_vm.c:866-928` | per section | Yes, 2 s after the section's fd ends | CODE-VERIFIED |
| Probes (section test page, freeze memory probe) | `ps4_wine_vm.c:809-817`, `ps4_kstate.c:925-943` | 1 page | Yes, at once | CODE-VERIFIED |

**Important precedent:** ps4-kit's heap already releases an overflow heap when it has been empty for two checks.
It waits for pins to drain, unmaps, then calls `sceKernelReleaseDirectMemory` (`ps4_runtime.cpp:977-990`). So the
same codebase already has a tested-looking pattern for giving direct memory back safely. The Wine VM layer simply
doesn't use it.

---

## 2. Answers to the seven questions

### Q1. Why 64 MiB chunks?
- **What the code says:** only "direct memory, taken from the system in 64 MiB chunks" (`ps4_wine_vm.c:77`),
  unchanged since the first memory layer in v00.02 (`a8358e1`). No measurement or rationale is recorded. CODE-VERIFIED.
- **What the design implies** (UNVERIFIED reasoning, not documented upstream):
  - Fewer `sceKernelAllocateDirectMemory` calls. Wine commits memory in 16 KiB steps, and a kernel call per page
    would be slow.
  - `MAX_CHUNKS = 80` × 64 MiB = 5 GiB, just above the app's 4608 MiB, which keeps the chunk table a fixed static
    array (`:78-81`).
  - A page index fits in a `uint32_t` table entry (`PAGE_DIRECT + index`, `:75`). The index is
    `chunk × 4096 + offset` (`direct_phys :163-166`).
- **Known consequence:** a run of pages must not cross chunk boundaries, because each chunk is a separate kernel
  allocation. This caused v00.46's "out of memory with 2 GiB free" and was fixed in v00.47 (`:189-193`, `25f3a18`).
  CODE-VERIFIED + DOC-VERIFIED.

### Q2. Are freed pages returned to an internal allocator or kept for good?
**To an internal allocator, and they are reused, but they are never given back to the kernel.** CODE-VERIFIED.
- Free path: `vm_munmap` → `release_range` → `forget_range` → `give_direct(page, 1)` pushes the page onto
  `free_pages[]` (`:218-222, :231-256, :258-272`). Wine's decommit (`mmap(MAP_FIXED, PROT_NONE)`) takes the same
  path through `vm_mmap :624-626`.
- Reuse path: `take_direct` pops from `free_pages[]` **before** asking for a new chunk (`:198-208`).
- Nothing in `ps4_wine_vm.c` calls `sceKernelReleaseDirectMemory` for a VM chunk. Its only calls are for the
  section probe page and for sections (`:817, :901, :921`).
- So this is a **pool, not a leak**: the memory is held for reuse by the same process. It becomes a problem only
  when *another* process needs it. That matches your reviewer's caution.

### Q3. Can other Wine processes reuse the retained memory?
**No.** CODE-VERIFIED.
- `free_pages[]`, `chunk_phys[]` and the counters are `static` in each process's own image
  (`ps4_wine_vm.c:78-81`). Every Wine process (desktop, each local process, each outside process) is a separate PS4
  process with its own copy.
- Even with the physical offsets, another process mapping them needs direct-memory aliasing across processes, which
  the PS4 refused in v00.69 (`0x8002000d`, `NOTES.md:749-751`). DOC-VERIFIED (13.52).
- A held chunk is available to other processes only after the holder **releases it to the kernel** or **exits**.

### Q4. Exact lifecycle of a VM direct-memory page
```
reserve      mmap(PROT_NONE)            → sceKernelReserveVirtualRange; table = RESERVED       (:597-655)
commit       mprotect(RW) / mmap(RW)    → back_range → take_direct:
                                            free_pages[] (reuse)  OR  new chunk (bump chunk_used)
                                          → sceKernelMapDirectMemory(FIXED) → memset 0 → mprotect   (:274-345)
                                          table = DIRECT+index; backed_direct += n
exec         mprotect(+X) and !direct_exec → copied to system flexible memory, page → free list    (:347-378)
decommit/free mmap(FIXED,NONE) / munmap → forget_range: give_direct, backed_direct--, UNTRACKED
                                          → sceKernelMunmap (4 GiB pieces)                          (:231-272)
             (mmap FIXED then re-reserves the range: reserve_fixed)
section view  ps4_vm_map_section       → forget_range over the view (pages to the free list)        (:951-972)
process exit  SYS_exit, with no unmapping or release (port/ps4_wine_port.c:296-318)  → the kernel's job
```
All of this runs under `vm_lock`, a recursive mutex (`:507-552`).

### Q5. Does process termination release all its direct memory?
**Not proven. This is the most important open question.** UNVERIFIED.
- Code: a program process exits with a raw `SYS_exit` and never unmaps or releases anything
  (`ps4_wine_port.c:296-318`). Reclamation depends entirely on the kernel.
- Indirect evidence (DOC-VERIFIED, 13.52 klog): on exit the kernel logs per-process direct-memory bookkeeping,
  `dmem_handle_vmspace_exited ... app_maps_count 5 -> 4` (`NOTES.md:760-761`). That shows the kernel tracks the
  process's mappings, but **not** whether the process's *allocations* (as opposed to its *mappings*) go back to the
  app pool. All local processes share one app direct-memory pool (`dmem#1`).
- No upstream log in the repo shows direct-memory free before and after a program's exit (logs/ is git-ignored).
- **This must be measured on your console before anything is changed** (section 4, test T1). If allocations
  survive process exit, that is a real leak across process lifetimes and outranks M1.

### Q6. Existing counters
| Counter | Scope | Meaning | Where it's shown | Tag |
|---|---|---|---|---|
| `backed_direct`, `backed_flexible` (pages) | per process | pages mapped *now* | `ps4_vm_backed_bytes()` → STAT → Task Manager | CODE-VERIFIED (`:93, :225-229`; `ps4_spawn_desk.c:851`; `desktop.cpp:6333`) |
| `chunk_count`, `chunk_used` | per process | chunks held; pages carved from the last one | **nowhere** | CODE-VERIFIED (`:79`) |
| `free_count` | per process | pages on the internal free list | **nowhere** | CODE-VERIFIED (`:81`) |
| `ps4_memory_census` flexible / shared | per process, every 5 s | sums from `sceKernelVirtualQuery`. **Direct mappings (kind & 2) are walked but skipped.** | STAT → Perf log, memory guard | CODE-VERIFIED (`ps4_kstate.c:683-703`) |
| `section_count` / `section_bytes` | desktop | sections in direct memory | Perf log | CODE-VERIFIED |
| App "memory used" | whole app | `total − sceKernelAvailableDirectMemorySize(...)`, which is the **largest free run** (NOTES calls it that: `NOTES.md:287, 374`), **not the total free** | Task Manager meter + Performance graph (`desktop.cpp:1685-1693`) | CODE-VERIFIED (code) / DOC-VERIFIED (API meaning) |
| Overflow heaps | per process | `heapLog` lines only. ps4-kit has no stats API. | wine.log | CODE-VERIFIED |

**New accounting finding M8:** the app-level "used" figure is *total minus the largest free block*. When direct
memory is fragmented it **over-states** use, while the per-process figures (M2) **under-state** it. The two can't be
reconciled today, so a baseline built on them would be misleading.

### Q7. Can statistics be added without changing allocation behaviour?
**Yes.** Every value the design below needs is either already a static variable in `ps4_wine_vm.c`, or available
from a read-only kernel query that is already used elsewhere (`sceKernelVirtualQuery`,
`sceKernelAvailableDirectMemorySize`). No allocation, mapping or release path has to change. CODE-VERIFIED
(the variables exist). The new queries' exact semantics on 12.50 are UNVERIFIED (see risks).

---

## 3. Proposed Memory Accounting design (not implemented)

### 3.1 Per-process VM figures (`port/ps4_wine_vm.c`)
New read-only accessor; the existing `ps4_vm_backed_bytes()` stays unchanged:
```c
struct ps4_vm_stats {
    uint64_t direct_held;      /* chunk_count × 64 MiB: what this process holds from the kernel    */
    uint64_t direct_mapped;    /* backed_direct × 16 KiB                                            */
    uint64_t direct_free_list; /* free_count × 16 KiB: freed, kept for reuse                        */
    uint64_t direct_untouched; /* (CHUNK_PAGES − chunk_used) × 16 KiB of the last chunk             */
    uint64_t flexible_backed;  /* backed_flexible × 16 KiB                                          */
    uint64_t direct_held_peak; /* high-water mark of direct_held                                    */
    uint32_t chunks;
};
void ps4_vm_get_stats( struct ps4_vm_stats *out );   /* takes vm_lock briefly */
```
**Built-in self-check:** `direct_held == direct_mapped + direct_free_list + direct_untouched`. Log it once if it ever
fails. That proves (or disproves) the allocator's bookkeeping on the real console.

### 3.2 Per-process kernel view (`port/ps4_kstate.c`)
`ps4_memory_census` already walks every mapping. Add a third sum for `kind & 2` (direct mappings). That covers the C
heap, RADV buffers, VM pages and sections: **everything direct the process maps**, independent of Wine's
bookkeeping. Do it as a new function, e.g. `ps4_memory_census_ex(&flexible, &shared, &direct)`, so the existing
callers and the memory guard stay unchanged.

### 3.3 App-wide view (desktop)
- **Total free direct memory**: enumerate free runs with `sceKernelAvailableDirectMemorySize` over successive
  `[start, end)` windows and add them up, instead of using only the largest. Keep the largest-run figure too (it is
  what new chunks need).
- **Retained after exit**: when a process ends (`control_event`, `ps4_spawn_desk.c:189-228`), log its last STAT
  figures, then app total-free at end+0 s and end+3 s:
  `memory: process 818 (IronSnout.exe) ended: held 1024 MiB (mapped 610, free list 380, untouched 34), kernel-mapped direct 1190 MiB; app direct free 1400 → 2590 MiB (+1190) after 3 s`
  The delta against the held/mapped figures **answers Q5 directly**.

### 3.4 Transport and display
- `struct local_stats` (`ps4_spawn_desk.c:125-131`): append `direct_held, direct_mapped, direct_free_list,
  direct_kernel` at the end. The desktop and its children are the same binary, so the protocol stays consistent.
- Performance log (`desktop.cpp` PerfLog): one extra line every 10 s with app total-free, largest-run, and per
  process held / mapped / kernel-direct / flexible.
- Task Manager: no change in step 1, to keep the UI diff at zero. Add a "Held" column in a later step.
- Switch: follow the existing Performance log switch (`WINEPS4_PERF_LOG`). No new setting.

### 3.5 What the six requested figures map to
| Requested | Source |
|---|---|
| Direct Memory reserved | per process `direct_held`; app: `total − total_free` |
| Direct Memory mapped | per process `direct_mapped` (VM) and census `direct` (all users) |
| Direct Memory internally free | `direct_free_list + direct_untouched` |
| Flexible Memory usage | census `flexible` / `shared` (existing) + `sceKernelAvailableFlexibleMemorySize` (existing) |
| Per-process memory usage | all of the above per STAT, every 1 s (census every 5 s, as today) |
| Memory retained after application exit | exit log line: app total-free delta vs. the process's last held figure |

---

## 4. Device tests this enables (Phase 2, on your console)

| ID | Test | Answers |
|---|---|---|
| T1 | Start a 64-bit test program that commits about 512 MiB, frees it, sleeps, then exits. Log app total-free before start, after commit, after free, after exit +3 s. | Q5: does exit return held chunks? Is free-without-exit kept (M1)? |
| T2 | Same, 10 cycles in a row | Leak across lifetimes (total-free should come back to the same value) |
| T3 | Self-check invariant over a 30-min Steam session | Allocator bookkeeping correctness |
| T4 | Compare census-direct vs VM-mapped per process | How much is heap/RADV, not VM |

A test program for T1/T2 can be a ~40-line `tests/memcycle.c` built with the same mingw flow as `tests/hello.c`.
No change to the app is needed for the program itself.

---

## 5. Risks

| Risk | Mitigation |
|---|---|
| `sceKernelAvailableDirectMemorySize` window semantics on 12.50 (does `start` give the next free run?) are UNVERIFIED | First run: log both the enumeration and the largest-run figure, and cross-check against a known allocation (T1) |
| `ps4_vm_get_stats` takes `vm_lock`. Calling it from the freeze watch or a signal handler could stand. | Only call it from the stats thread. The freeze paths keep the existing lock-free `ps4_vm_backed_bytes`. |
| A longer STAT message | Same binary on both ends. Append-only fields. |
| Enumerating the free runs costs kernel calls | Desktop only, every 10 s with the Perf log, bounded loop (≤ 80 iterations) |
| Logging volume | One line per process exit, one per 10 s |
| None of this was built | Building is still blocked (Phase 0 B3/B5). The design can be written and reviewed; it can be compiled only once a PS4 sysroot exists. |

## 6. Explicitly NOT proposed now
- No `sceKernelReleaseDirectMemory` for VM chunks. If we do it later (P4), it needs a per-chunk free count, purging
  that chunk's pages from `free_pages[]`, reusable chunk slots (the page index encodes the slot), an
  "empty for N checks" delay like `trimOverflowHeaps`, and T1 to prove it helps. Not before T1/T2 show the need.
- No change to chunk size, reserve sizes, heap options or kernel behaviour.

## 7. Minimal implementation plan, once approved (each step its own commit on `development`)
1. `ps4_wine_vm.c`: `struct ps4_vm_stats` + `ps4_vm_get_stats` + invariant check (about 40 lines, no behaviour change).
2. `ps4_kstate.c`: `ps4_memory_census_ex` with the direct sum (about 15 lines).
3. `ps4_spawn_desk.c`: appended STAT fields + the exit line (about 40 lines).
4. `shell/desktop.cpp`: Perf log line with total-free enumeration (about 40 lines).
5. `tests/memcycle.c` for T1/T2.

Each step is CODE-VERIFIED only until a PS4 build is possible. They can't be BUILD-VERIFIED here (Phase 0 B3/B5).
