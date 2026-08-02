# RESULT — rc=139 SIGSEGV + rc=137 SIGKILL RCA (host, own worktree)

**Branch:** `w-cpu-segv-rca` @ worktree `.worktrees/w-cpu-segv-rca`  
**Does not touch parent checkout.** Device not accessed.

## Parent facts absorbed

- 5× `rc=139` (SIGSEGV) on 2026-07-30 only: 20:38:43, 20:39:11, 20:49:10, 21:00:52, **last 21:20:48Z**
- **No SEGV in supervise log after that** for >2 days (parent).  
  Rule 0: that is **“log does not contain later 139”**, **not** “SEGV is fixed forever.”
- 4× `rc=137` (SIGKILL), two with long `run_s` (4764, 5699) — OOM-shaped, uncatchable
- rc=0 closed as lab SIGTERM (parent)

## What changed around the SEGV window (git, host)

| When (commit date, local) | SHA | Note |
|---------------------------|-----|------|
| Jul 30 20:01 | `95b1e6ae` | OSD auto-detect via PLXS — **during crash hour** |
| Jul 30 20:10 | `2f81e96b` | plex.tv resources GET as list |
| Jul 30 20:38–21:20 | — | **5× SEGV (parent supervise)** |
| Jul 30 22:14–22:59 | `a0a26590` / `4946986b` | crash **backtrace** feature (side branches) — **after** last SEGV; instrumentation, not proven root-cause fix |
| Jul 30 22:20 | `e9c43c68` | OSD Auto gates on CONF_STR |
| Jul 31 01:25 | `98a7f186` | PLXD bank-release **doorbell-relative** (was legacy `0x3007F128`) — freeze/green-cast class; **in mmap window** so wrong phys is **logic desync more than classic SEGV** unless map length wrong |
| Jul 31 12:36 | `3104b7be` | no force-write of display bank |

### Verdict on “what fixed SEGV”

**UNKNOWN — not closed.**

- No commit can be named as **the** SEGV fix: no `si_addr`, no stack, no death file for the five events.
- Side-branch crash_dump (`a0a26590`) is **not** on this tip’s ancestry and was authored **after** the last 139.
- PLXD/bank fixes after 21:20 are real product fixes for **other** measured defects; **inferring** they cured SEGV from silence is forbidden.
- **Plausible alternative:** lab thrash (deploy/restore/OSD churn) that night stopped; trigger frequency dropped without a SEGV-specific code fix.

**What would reproduce / settle**

1. Deploy binary with death-on-SEGV (this branch) + optional crash_dump.
2. Next 139: read `misterplexd.death` for `signal=11 si_code_name=SEGV_MAPERR|SEGV_ACCERR si_addr=…`.
3. PRE_REG: `si_addr` in DDR mmap window vs heap/null → ranks DDR publish vs heap corruption.
4. Without a new 139, do **not** mark fixed.

## Gap found on this tip (f1c31cc8 base) — **code defect**

`crashGuardHandler` only CONT’d Main and re-raised — **did not write death**:

```cpp
// was: no deathBreadcrumb*
void crashGuardHandler(int sig) {
    mainPauseDepth().store(0);
    for (pid_t p : findMisterPids()) kill(p, SIGCONT);
    std::signal(sig, SIG_DFL);
    ::raise(sig);
}
```

So historical **absent death on 139 is expected** on this lineage — not proof of no SEGV.

### Shipped here

| Change | Why |
|--------|-----|
| `crashGuardHandler` → `SA_SIGINFO` + `deathBreadcrumbOnSigInfo` **before** raise | Next 139 leaves `signal=11` + `si_addr` |
| `si_code_name=SEGV_MAPERR\|SEGV_ACCERR` | Discriminate fault class |
| `tools/oom_sigkill_probe.sh` | Honest HIT/MISS for OOM in dmesg (**MISS ≠ never**) |
| `tools/rss_growth_sample.sh` | exe-resolved VmRSS over soak for 137@5ks |
| Host gates | `test_crash_guard_writes_death.sh`, `test_oom_rss_tools_static.sh` |

## SIGKILL / OOM

- Handler **cannot** run on 137 — death file is **NO-DATA** for pure KILL.
- Long `run_s` is **consistent with** OOM but **not proof**.
- Parent:

```sh
sh tools/oom_sigkill_probe.sh; echo "true rc=$?"
# during multi-hour soak:
INTERVAL_S=60 SAMPLES=60 sh tools/rss_growth_sample.sh; echo "true rc=$?"
```

PRE_REG: OOM HIT if dmesg names misterplexd/ffmpeg; RSS growth if VmRSS climbs unbounded toward MemAvailable.

## Host verification (this worktree)

| cmd | true rc |
|-----|---------|
| `./build/test_death_breadcrumb` | 0 |
| `bash tests/unit/test_crash_guard_writes_death.sh` | 0 |
| `bash tests/unit/test_oom_rss_tools_static.sh` | 0 |
| `python3 tests/unit/test_unit_rollcall.py` | 0 |
| `g++ -c arm/misterplexd/fpga_spi.cpp` | 0 |

Full `make unit` not claimed if host swap preflight refuses (parent observed 0MB free).

## Parent deploy note

When next shipping daemon: include this crashGuard death write. Do **not** require the 112-line supervise rewrite for this SEGV witness — death is written by the **daemon** handler.

## Process corrections absorbed

- Work only in own worktree (`w-cpu-segv-rca`).
- Device-running artifacts ≠ repo HEAD; ask parent for device copy when claiming device behaviour.
