# misterplexd rc=0 self-exit RCA + crash breadcrumb

**Lane:** w-fit · **NO FIT · NO DEVICE**  
**Falsified (do not resume):** steady-state drop sawtooth / CV discriminator — parent measured
**0 steady-state drops** over ~353 s × 2 soaks. Drop RCA line is **DEAD**.

---

## 1. Every `main()` return path (quoted)

| Site | rc | When | Logged via |
|------|---:|------|------------|
| `main.cpp` `--help` | **0** | CLI only | `deathBreadcrumbExit(0,"site=main.cpp:--help")` then `return 0` (~244) |
| `main.cpp` lab play-file fail | 1 | `--play-file` fail | `exitReported(1,...)` |
| `main.cpp` lab zero frames | 2 | lab empty delivery | `exitReported(2,...)` |
| `main.cpp` lab done | **0** | lab success | `exitReported(0,"site=main.cpp:lab-play-file-done")` |
| `main.cpp` companion start fail | 1 | bind/listen | `exitReported(1,...)` |
| **`main.cpp` main_loop_g_stop** | **0** | **`g_stop` after SIGINT/SIGTERM** | `exitReported(0, why with sig/si_code/si_pid)` |
| `media_player.cpp` child `_exit(127)` | n/a | **ffmpeg fork child only** | not daemon |

Product companion path after start:

```text
while (!g_stop) { sleep 200ms; resumeStrandedMain; heartbeat }
// g_stop only written by on_signal_info (SIGINT/SIGTERM)
return exitReported(0, "site=main.cpp:main_loop_g_stop sig=… si_code=… si_pid=…", &player);
```

**There is no idle timeout, watchdog exit, or “exit after N seconds” in source.**  
Variable `run_s=1543/196/514` is **not** explained by an internal timer.

### Absence of log ≠ proof of graceful design

Old binaries may leave **no** `shutdown|SIGTERM|EXIT_REASON` line. That is  
**absence of evidence in the log**, not proof the exit was voluntary.  
Handled SIGTERM still yields **`WIFEXITED(0)`**, not `WIFSIGNALED` — supervisor  
`rc=0` is **exactly** what external SIGTERM looks like after the handler sets `g_stop`.

With current tip, every normal return hits `exitReported` → stderr  
`misterplexd: EXIT_REASON code=… why=…` + `misterplexd.death`.

---

## 2. rc=0 vs rc=139 (SIGSEGV) — same bug?

| | rc=0 (WIFEXITED) | rc=139 (WIFSIGNALED SIGSEGV) |
|--|------------------|------------------------------|
| Mechanism | `on_signal_info` → `g_stop` → `return 0` | Fault → crash guard → **re-raise** SEGV |
| Handler | SIGINT/SIGTERM only | SIGSEGV/ABRT/BUS/ILL/FPE/QUIT |
| Typical cause | **External stop** (plexctl, second launch, human, OOM-adj kill -15) | **Memory bug** (null/wild ptr) |
| Same bug? | **No** — different landings, different signals | Pre-existing SEGV seen on stock `7cd10b4d` |

They are **not** the same bug with two landings. A SEGV that is **caught and converted** to clean exit **does not exist** in source: crash path re-raises after breadcrumb.

SIGKILL/OOM: no handler; death file may be **STALE** or absent — supervisor + kernel only.

---

## 3. Instrumentation delivered this commit

1. **Orderly:** `exitReported` + `EXIT_REASON` on every normal main return (already present; kept).  
2. **Fatal:** `FpgaSpi::installCrashGuard` now **SA_SIGINFO** → `deathBreadcrumbOnCrash(info,ucontext)`  
   writes `misterplexd.death` with `signal= si_code= si_pid= si_addr= pc= lr= sp= state= frames=`  
   then SIGCONT Main, re-raise (still **WIFSIGNALED**).  
3. **Init order:** `deathBreadcrumbInit` **before** `installCrashGuard` so path is live.  
4. **AS-safe:** open/write/close + integer/hex append only — **no** `backtrace()` (not AS-safe).  
   PC/LR from `ucontext` (ARM / aarch64 / x86_64).

### Parent device checks (you run)

```sh
# after next mysterious rc=0:
grep EXIT_REASON /media/fat/misterplex*/misterplexd.log | tail -5
cat /media/fat/misterplex*/misterplexd.death
# expect why=...main_loop_g_stop sig=15 si_code=… si_pid=N
# if si_pid set: tr '\0' ' ' < /proc/$si_pid/cmdline  (if still alive)

# after next rc=139:
cat /media/fat/misterplex*/misterplexd.death
# expect death signal=11 si_code=1|2 si_addr=0x… pc=0x…
```

**Do not “fix” by ignoring SIGTERM.** Identify sender via `si_pid`.

---

## 4. Host tests (red-before-green)

| Test | Proves |
|------|--------|
| `test_daemon_exit_rc0.sh` | Real `main` rc=0 (`--help`) emits `EXIT_REASON code=0` + site |
| `test_death_breadcrumb` | Orderly exit + crash OnCrash + main_loop_g_stop why shape |
| `test_crash_guard_death` | Fork + null SEGV → WIFSIGNALED(11) **and** death file has `signal=11` |

If crash guard omitted breadcrumb, `test_crash_guard_death` is **RED** (empty death).  
If `--help` silent, `test_daemon_exit_rc0` is **RED**.

---

## 5. Soak counter interaction (why this matters)

`droppedFrames_` / `presentCount_` reset per stream; **process exit re-zeros** in-memory  
lifetime visibility unless `misterplexd.frame_ledger` is read across restarts.  
rc=0 respawns **explain mid-soak counter resets** without any steady-state drop bug.
