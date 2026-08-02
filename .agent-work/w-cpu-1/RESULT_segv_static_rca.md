# Static RCA — supervise `rc=139` (SIGSEGV) on misterplexd

**Lane:** w-cpu · **Deploy of sender capture deferred** · **No device access this turn**  
**Product config under review:** `PRESENT=fpga`, `DDR_YUV_FORCE_SCALE=1`, `DECODE=624x480`, STREAM=0 raw I420 → DDR YUV F1.

## What `rc=139` means (measured semantics)

- Shell `wait` status **139 = 128 + 11** → process died from **SIGSEGV**.
- Not SIGTERM (handled → `WIFEXITED 0`), not SIGKILL (137), not SIGPIPE (141).
- **Historical death file often ABSENT** for this class: pre-`c9e8a4aa`, `crashGuardHandler` only CONT Main + re-raise and did **not** write death (`fpga_spi.cpp` crashGuard; gate `tests/unit/test_crash_guard_writes_death.sh`). **Absence of death ≠ absence of SEGV** (evidence: log/supervise only).
- After deploy of `c9e8a4aa+`: death should show `signal=11` + `si_code_name=SEGV_MAPERR|SEGV_ACCERR` + `si_addr` **before** re-raise. That is the live discriminator this static note cannot replace.

## PRE_REG (static — no live crash yet)

| ID | Prediction | How falsified later |
|----|------------|---------------------|
| S1 | Product SEGV is most likely **mmap/UAF or bad pointer on DDR/SPI map**, not “ffmpeg math” | death `si_addr` in DDR window / FPGA map vs heap |
| S2 | `presentMu_` serialises product DDR publish vs OSD/idle/input → **cross-thread munmap during memcpy is unlikely on product path if every ddrMap_ touch holds the lock** | code path found that touches `ddrMap_`/`map_` without `presentMu_` or `spiMutex` |
| S3 | Historical “silent death” backlog was often **SIGPIPE (141)**, not 139 — do not collapse classes | supervise histogram separates 139 vs 141 |

## Call graph (product hot path)

```
play thr_ → presentCleanFrame (media_player.cpp ~3618)
  → lock presentMu_
  → publishDdrFrame → fpga_.publishDdrFrame
       → maybe setDdrFrameLayout → releaseDdrMap/munmap  (same call stack, still under presentMu_)
       → sendDdrFrame
            → ensureDdrMap (/dev/mem mmap)
            → readBankRelease / kick via ddrMap_
            → memcpy(ddrMap_ + bankOff, payload, len)   fpga_spi.cpp ~1530
            → cleanDcacheRange (syscall; fail → err, not SEGV)
            → kickDdrDoorbell(ddrMap_)
OSD / idle / input: also take presentMu_ before fpga_ DDR/SPI  (media_player.cpp ~561,592,701,817)
stop(): join thr_ THEN stopOsdPoll/stopIdle  (media_player.cpp ~1171–1232)
  comment documents prior class: ioctl through unmapped handle if OSD outlives map
```

## Enumerated fault sites (quote + reachable?)

### A. DDR frame path — **product-reachable** (rank 1)

| Site | File:line | Mechanism | Reachable under product? |
|------|-----------|-----------|---------------------------|
| `memcpy(ddrMap_+bankOff, payload, len)` | `fpga_spi.cpp:1530` | Null/stale `ddrMap_`, or `bankOff+len` past map → SEGV/BUS | **Yes** every F1 present. Mitigations: `ensureDdrMap` before copy; `sendDdrFrame` rejects plan/layout mismatch; `ddrFrameLayoutValid` requires `bank1End <= doorbell_phys` and doorbell inside `map_bytes` (`ddr_frame_layout.hpp:327–350`). Residual risk = **race that unmaps under us** or **logic bug bypassing valid()**. |
| `kickDdrDoorbell` / mailbox reads via `ddrMap_` | `fpga_spi.cpp:785–886` | Same map lifetime | **Yes** under publish; bounds-checked `kOff+8 > ddrMapLen_` |
| `setDdrFrameLayout` → `releaseDdrMap` | `fpga_spi.cpp:705–726, 745–758` | munmap while another thread still copies | **Product publish holds `presentMu_`** before `publishDdrFrame`. Layout change runs **on that same stack** before remap+memcpy — OK for single-threaded publish. **SEGV if any path calls publish/send without `presentMu_`.** Grep: product F1 present and recon DDR take the lock; idle paint takes lock (`media_player.cpp:817`). |
| `cleanDcacheRange` | `fpga_spi.cpp:52–64, 1536` | `__ARM_NR_cacheflush` | Fail returns false; **not expected SEGV** |
| FPGA reg `map_` SPI (`SpiExclusive` / `MainSafeWindow`) | `fpga_spi.cpp:177–277, 320+` | `*gpoReg(map)` if map dangling | Product F1 doorbell prefers mmap; SPI fallback still used for status/kick probe. Callers use `presentMu_` + `ok()` checks. Null `map` skipped in window (`if (map)`). **Dangling after `close()` without join** was the documented stop hazard — `stop()` joins thr_ and stops OSD/idle before further use; comment still says “closes FpgaSpi” but **current `stop()` does not call `fpga_.close()`** (re-paints idle instead). Destructor/`close` at process exit only. |

### B. Present / frame buffer — **conditional**

| Site | File:line | Reachable product `PRESENT=fpga`? |
|------|-----------|-------------------------------------|
| `FbPresent` mmap/ioctl | `fb_present.cpp` | **Only if fb opened.** Product `PRESENT=fpga` still opens FPGA always (`initPresent` wantFpga=true); fb0 may be off. Lower priority than DDR. |
| Overlay blit into `cleanFrame` | `media_player.cpp` present lambda | Heap buffer sized to `frameBytes`; dirty rect math — **possible OOB if dirty bounds wrong** (lab risk; not proven). |

### C. Decode / pipe / scale — **product-reachable but weaker SEGV story**

| Site | Notes |
|------|--------|
| Raw pipe read into `frame` vector | Short read breaks loop; B5 desync is **teardown classify**, not SEGV |
| `packYuv420pCenteredIntoCodedBank` / recon | Size-checked; refuse path logs ERROR and skips |
| Large `std::vector` bank alloc | OOM → often terminate/bad_alloc → **SIGABRT (134)** or kill, not classic SEGV |

### D. Companion HTTP / timeline — **reachable, different historic class**

| Site | Notes |
|------|--------|
| `send(..., MSG_NOSIGNAL)` | `companion.cpp` — SIGPIPE **fixed** (PHASE_BACKLOG G-STAB1). Was **silent death without death file**, wait status **141**, not 139. |
| Request parsers | std::string paths; no raw unchecked `strcpy` found in quick scan — **no quoted SEGV site** |

### E. crashGuard / signal path — **not the fault, affects evidence**

| Site | Notes |
|------|--------|
| `crashGuardHandler` | Must write death **before** re-raise (`c9e8a4aa`). Uses non-async-signal-safe heap in `findMisterPids` for CONT — can theoretically fault/deadlock **in the handler**, wiping the witness. Separate hardening item. |

### F. Explicitly **not** SEGV

| Class | rc | Notes |
|-------|-----|------|
| Handled SIGTERM | 0 | Parent-measured; SI_USER |
| SIGKILL / OOM | 137 | Uncatchable; see OOM probe |
| SIGPIPE | 141 | Historic silent death |
| SIGABRT (joinable thread / assert) | 134 | `~MediaPlayer` join abort class |

## Concurrent munmap hypothesis — verdict from **code structure** (not live proof)

- **Evidence we have:** every product DDR present path quoted above takes `presentMu_` before `fpga_.publishDdrFrame`; OSD/idle/input take the same lock for FPGA ops; `stop()` joins `thr_` before stopping background FPGA users.
- **Evidence we do not have:** a live `si_addr` / stack for any of the 5× historical 139s.
- **Honest status:** cross-thread DDR UAF is **structurally mitigated** on the paths read; residual SEGV candidates are (1) **logic/OOB inside a locked publish**, (2) **a path not under `presentMu_` we missed**, (3) **heap corruption earlier**, (4) **third-party in-process** (none linked for decode — ffmpeg is child).

## What would settle rank-1 on next SEGV (parent, after death deploy)

Read-only after a 139:

```sh
ROOT=$(sh -c '. tools/lib_live_misterplex_root.sh; resolve_live_misterplex_root')
echo "ROOT=$ROOT"
cat "$ROOT/misterplexd.death" 2>/dev/null || echo "NO-DATA death"
# Prefer death fields: signal= si_code_name= si_addr= (c9e8a4aa+)
# PRE_REG HIT S1: si_addr in [ddr phys window] or FPGA 0xFF00_0000 map
# PRE_REG MISS S1: si_addr heap/stack/other → different class
dmesg 2>/dev/null | grep -iE 'misterplexd|segfault|page fault' | tail -20 || true
echo "true rc=0"   # this recipe is read-only; capture real rc of each cmd directly
```

## Severity / action

| Item | Action now |
|------|------------|
| Deploy death-on-SEGV (`c9e8a4aa`) | **Still deferred by parent** — highest value for next 139 |
| Static fix without si_addr | **Do not land speculative null checks as “the fix”** — no measured site |
| Host gate | Already: `test_crash_guard_writes_death.sh` (witness exists). No red-before-green **repro** of product SEGV without a deterministic fault injection (out of scope without parent approval on daily driver) |
| rc=137 | Separate OOM probe card |

## Bottom line (Rule 0)

- **5× rc=139 is a real crash class on the daily driver supervise log** (parent count).
- **Static review:** product F1 path is DDR mmap + memcpy under `presentMu_`; layout validity guards bank/doorbell geometry; historic silent exits were often **not** this class (SIGPIPE/TERM).
- **Root cause of the five events: UNKNOWN** — death files were often never written. Next SEGV after death-on-signal deploy is the first evidence that can name a site. Until then, do not publish a single “the bug is X” claim.
