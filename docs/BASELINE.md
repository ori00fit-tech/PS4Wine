# Device baseline: the official WinePS4 v00.71 on the target console

| | |
|---|---|
| Console | PS4 Slim, Southbridge Baikal B1 (0x30201) |
| System software | HEN 12.50, GoldHEN v2.4b18.10 |
| Package | official `WinePS4-v00.71.pkg` (sha256 `95ec4804f27c43f7606d3d1ac024690ffff7082cc380b6d534bee8177c98478c`) |
| Date | 2026-11-19 |
| Evidence | photo of the Terminal window (transcribed below); no `wine.log` copied yet |

## Run 1: first start (DEVICE-TESTED)
The desktop came up with the Terminal open and no program running ("No program is running. Open one from Files or
the Start menu."). Lines read from the photo:

```
wineps4: library mountmgr.so (built in) / nsiproxy.so / win32u.so / libfreetype.so.6 (built in)
wineps4: the app's open files: 81 of 257 (wineserver: 48 it can park open, 0 parked so far)
[SceLncUtil] ... lnc_util_ipc_client.cpp(422) getAppStatus: LNC_ISOK:0x80940004
wineps4: C:\windows\system32\rpcss.exe runs outside the PS4's 7 (process 101, 3 outside now)
wineps4: C:\windows\system32\rpcss.exe started (process 101)
wineps4: process 101: outside the PS4's 7, budget 0, regular flexible memory only
wineps4 vm: outside the PS4's 7: regular flexible memory only, 256 MiB at most (the kernel says 476 MiB of it free)
wineps4 vm: address space reservable up to 0xfc00000000
wineps4 vm: regular flexible memory runs code
error: 0x80020002 [SceLncUtil] ... killLocalProcess: LNC_ISOK:0x80aa0010
[SceSystemServiceImpl] ... sceSystemServiceKillLocalProcess(145) ...
wineps4: process 97 (wineboot.exe) ended (exit code 0)
wineps4: wineboot done in 7.1 s
wineps4: Windows desktop up in 7.1 s
wineps4: Windows is ready, 156.3 s after the app started
wineps4: the app's open files: 134 of 257 (wineserver: 111 it can park open, 0 parked so far)
```

Observations:
- **The processes outside the 7 work on 12.50**: budget 0, regular flexible memory, which runs code.
- The address-space limit is the same as upstream's 13.52 measurement (0xfc00000000, `NOTES.md:107`).
- "Windows is ready" came **156.3 s** after start, although wineboot took 7.1 s. Most of that is likely the
  first-start copy of Windows' files into `/data/WinePS4/prefix` (README: "about a minute"). A second start will
  show whether this is a first-run cost. UNVERIFIED.
- `killLocalProcess 0x80aa0010` right after wineboot ended: the desktop kills the local process entry of a program
  that has already exited (`ps4_spawn_desk.c:221`). Most likely harmless. UNVERIFIED.
- Pool outside the 7 at start: 476 MiB free.
- Open files: 134 of the app's 257 at idle.

## Still to record
1. `wine.log`, `hang.log`, `boot-trace.log` from `/data/WinePS4/` (FTP).
2. A second start: is "Windows is ready" much faster than 156 s?
3. Steam start, an idle 10 minutes with the Performance log on, a program opened and closed.
4. Then the same with the source-built package (`docs/BUILD_FROM_SOURCE.md`).
