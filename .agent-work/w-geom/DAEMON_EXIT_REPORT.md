# misterplexd rc=0 exit investigation (w-geom)

Branch: `w-instr-motion-counter`  
SHA: (see git after commit)  
ARM binary: `build/arm/misterplexd`  
md5: `13a505d372f45b004fdc9812b16eb149`  
ELF: 32-bit ARM static  

Parent path note: `/tmp/misterplex-agent-w-geom.txt` is blocked in this agent runtime; this file is the progress report.

## 1. Exit path enumeration (source)

Product path after companion start is **only**:

```cpp
// main.cpp — while (!g_stop) { sleep 200ms; resumeStrandedMain; }
// then player.stop(); …; return exitReported(0, why, &player);
```

| Site | Code | When |
|------|------|------|
| `main.cpp` `--help` | 0 | CLI help only |
| `main.cpp` lab play-file fail | 1 | `--play-file` play failed |
| `main.cpp` lab zero frames | 2 | lab delivery empty |
| `main.cpp` lab done | 0 | lab success |
| `main.cpp` companion start fail | 1 | bind/listen fail |
| **`main.cpp` main_loop_g_stop** | **0** | **`g_stop` after SIGINT/SIGTERM** |
| `media_player.cpp` child `_exit(127)` | n/a | **ffmpeg fork child only**, not daemon |
| No idle timeout / watchdog exit | — | main loop has **no** timer that returns |
| Companion stop/endMedia | — | stops playback **only**, does not exit process |

**Ranking vs run_s=1543 / 196 / 514:**

- A **fixed timeout inside misterplexd does not exist** in source → poor fit for variable run lengths.
- **Best fit from source:** external **SIGINT/SIGTERM** delivered to the daemon. Handlers set `g_stop`; teardown returns **0**. That is **WIFEXITED(status=0)**, not WIFSIGNALED — so supervisor `rc=0` is **exactly** what handled SIGTERM looks like.
- Who sends the signal is **unknown from source alone** (plexctl stop, second launcher, human, cron, etc.). `si_pid` / `si_code` on the new build settle it.

Evidence boundary (Rule 0): parent’s log grep missing `shutdown|SIGTERM` is only “strings absent from log”, not “no signal”. Old binary logged **nothing** on this path.

## 2. Self-reporting (delivered)

- `death_breadcrumb.*` — `EXIT_REASON` always on **stderr** + `misterplexd.death` beside conf.
- SA_SIGINFO on SIGINT/SIGTERM → `sig=` / `si_code=` / `si_pid=` in why string.
- `exitReported()` choke point on every normal `main` return after init.
- Files under conf dir (e.g. `/media/fat/misterplex_v2/`):
  - `misterplexd.death`
  - `misterplexd.last` (throttled heartbeat)
  - `misterplexd.frame_ledger`

## 3. Supervisor WIF* (delivered)

`scripts/plexctl.sh` `write_supervisor` now logs:

```
SUPERVISE_EXIT pid=… wait_st=… WIFEXITED_approx exit_status=0|WIFSIGNALED_approx signal=N
  run_s=… death=[…] last=[…]
```

Shell `wait` is not full waitpid; classification is the portable approx (st≥128 → signal).  
Also built: `build/arm/death_capture_supervisor` (real waitpid WIF*).

## 4. Cause / fix

**Cause of rc=0:** established as **handled stop signal → return 0**.  
**Sender:** unknown until silicon shows `si_pid` on `EXIT_REASON` / `.death`.

**Do not “fix” by ignoring SIGTERM.** Real fix is stop the external sender once identified.

### Parent device commands (you run)

```sh
# install binary by hand (do NOT use deploy_misterplexd.sh)
md5sum /path/to/build/arm/misterplexd   # expect 13a505d372f45b004fdc9812b16eb149
# after next mysterious exit:
grep EXIT_REASON /media/fat/misterplex_v2/misterplexd.log | tail -5
cat /media/fat/misterplex_v2/misterplexd.death
tail -20 /media/fat/misterplex_v2/misterplexd_supervise.log
# if si_pid set: tr '\0' ' ' < /proc/<si_pid>/cmdline  (if still alive) or audit who had that pid
```

## 5. Frame ledger (delivered)

Append-only `misterplexd.frame_ledger`:

- `process_start` / `session_end` / `process_exit`
- session_end: `frames presents drops residual=frames-presents-drops`
- lifetime counters in-process never reset by demux; ledger survives restarts

Unit: `test_frame_ledger` true rc=0.

## 6. Tests

| Gate | true rc |
|------|---------|
| `test_death_breadcrumb` | 0 |
| `test_frame_ledger` | 0 |
| `make unit` | **2** — pre-existing `test_rtl_invariants`: `sendDdrFrame must use selectDdrWriteBank` (fpga_spi untouched by this work; lives in w-fit-integ stash). Not introduced here. |

## 1+2 hygiene (480p) — parent asked earlier

Keep neutral-chroma init + dead-chroma repair as cheap defence; force-scale remains the product fix. Unchanged this task.
