# Daemon rc=0 — sender capture + SEGV/KILL honesty

## Pre-register

**Prediction:** product rc=0 = handled SIGTERM/INT → `g_stop` → `exitReported(0)`; run_s spread = external kill timing.

**Parent measured HIT:** death file `signal=15 si_code_name=SI_USER si_pid=…` on every sampled clean exit. Self-exit claim **retracted**.

## 1. Return paths that yield process status 0

| Site | Product service? |
|---|---|
| `--help` → return 0 | no |
| `--play-file` done → exitReported(0) | no |
| **main loop `while (!g_stop)` ends → exitReported(0)** | **YES only** |

`g_stop.store(true)` once, in `on_signal_info` (`main.cpp`).  
Comment: handled signals → WIFEXITED 0, not WIFSIGNALED.

No idle timer / HTTP “return from main” path in product loop (gate-locked).

## 2. run_s spread

No timer in source. Parent uptimes 261…7655 s with sig=15 = **when a userspace killer fired**.

## 3. SEGV (rc=139) and KILL (rc=137)

| Class | wait | Death file? |
|---|---|---|
| Handled SIGTERM | rc=0 | YES — EXIT_REASON + si_* (+ sender after this ship) |
| **SIGSEGV** | **rc=139** | **Before this ship: often ABSENT** — `crashGuardHandler` only CONT Main + re-raise, **did not** call death breadcrumb. **After this ship:** `deathBreadcrumbOnSignal(sig)` first → `death signal=11`. Still no EXIT_REASON (process dies on re-raise). |
| **SIGKILL** | **rc=137** | **Never** — cannot catch. Supervisor only. `sender=GONE`/absent is expected. |

Absence of `shutdown|fatal` in daemon log = *log does not contain those strings*, not proof of non-signal exit.

## 4. What this ship adds

1. **`deathBreadcrumbCaptureSender(si_pid)`** immediately when main sees `g_stop`, **before** `player.stop()`:
   - `sender_status=LIVE|GONE|NONE`
   - `sender_cmd`, `sender_comm`, `sender_chain` (PPid walk)
   - stderr `SENDER_CAPTURE` + file `misterplexd.death.sender`
   - folded into `EXIT_REASON` / `misterplexd.death`
2. **crashGuard → deathBreadcrumbOnSignal** so SEGV leaves a death witness.
3. Host gates + `tools/daemon_exit_correlate.sh`.

## 5. Untouched-window observation (parent)

**Setup (once):** deploy daemon+supervise that include sender capture (`4ce0760a`+this commit). Confirm one intentional TERM shows `sender_status=LIVE` and your ssh/bash chain.

**Window:** mark start, touch nothing that stops/deploys/casts for **≥4 h** (or overnight). No ssh kill, no deploy, no plexctl stop.

```sh
ROOT=/media/fat/misterplex_v2
START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "UNTOUCHED_START=$START_UTC" | tee -a "$ROOT/untouched_window.txt"
# leave device alone …
```

**After window:**
```sh
ROOT=/media/fat/misterplex_v2
END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "UNTOUCHED_END=$END_UTC" | tee -a "$ROOT/untouched_window.txt"
sh /path/to/tools/daemon_exit_correlate.sh
# Also:
grep -E 'EXIT pid=|SENDER_CAPTURE|EXIT_REASON' \
  "$ROOT/misterplexd_supervise.log" "$ROOT/misterplexd.log" 2>/dev/null | tail -n 80
echo "true rc=$?"
```

**PRE_REG outcomes:**

| ID | Result | Means |
|---|---|---|
| U1 | **Zero** `EXIT pid=` / `EXIT_REASON` with ts inside window | No non-operator killer observed in window |
| U2 | EXIT with `signal=15` + `sender_status=LIVE` + chain is ssh/deploy/plexctl/**you** | Operator (or your automation) — not mysterious |
| U3 | EXIT with `signal=15` + `sender_status=LIVE` + chain is **resident** (cron, unknown binary, not your session) | **Third-party killer exists** — chase that argv |
| U4 | EXIT with `signal=15` + `sender_status=GONE` | NO-DATA on identity; count as unresolved kill, not “nobody” |
| U5 | EXIT rc=139 + death `signal=11` | SEGV class (separate from TERM) |
| U6 | EXIT rc=137 | SIGKILL — death may be stale; check dmesg OOM |

**Do not** treat U1 as proof “nothing ever kills it” outside the window — only as evidence the log does not contain exits *in that window*.

## 6. Correlate historical exits (read-only, works on current tree)

```sh
ROOT=/media/fat/misterplex_v2
sh tools/daemon_exit_correlate.sh
echo "true rc=$?"
```

Or inline:
```sh
ROOT=/media/fat/misterplex_v2
grep -E 'EXIT_REASON|main_loop exit pending' "$ROOT/misterplexd.log" | tail -40
grep 'EXIT pid=' "$ROOT/misterplexd_supervise.log" | tail -15
cat "$ROOT/misterplexd.death" 2>/dev/null || echo NO-DATA
echo "true rc=$?"
```

## 7. Verdict

| Question | Answer |
|---|---|
| Self-exit? | **No** — external SIGTERM (parent HIT) |
| Who? | Need LIVE sender_cmd after this deploy; historical si_pid often GONE |
| Fix exits? | Stop sender; daemon must not ignore SIGTERM if supervise/deploy rely on it |
| Soak counters | Still reset on respawn — use frame_ledger + process_epoch |
