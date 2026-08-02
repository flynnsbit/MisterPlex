# Daemon clean rc=0 exits — RCA + attribution ship

## Pre-register

**Prediction:** product path is handled SIGINT/SIGTERM → `g_stop` → `exitReported(0)`; `run_s` spread = external signal timing; parent grepped wrong substrings (`shutdown|SIGTERM|fatal|panic`).

**Status:** SOURCE-DEFINITIVE for path. SENDER still needs on-device `si_pid` (commands below).

## 1. Every main() path that returns 0 (quoted)

| # | Site | When | Running service? |
|---|---|---|---|
| A | `main.cpp` `--help` → `return 0` after `deathBreadcrumbExit(0,"site=main.cpp:--help")` | CLI help | **no** |
| B | `exitReported(0,"site=main.cpp:lab-play-file-done")` | `--play-file` lab | **no** |
| C | `exitReported(0, why)` after `while (!g_stop)` with `why=site=main.cpp:main_loop_g_stop sig=…` | **SIGINT/SIGTERM handler** | **YES — only product path** |

`g_stop.store(true)` appears **once**, in `on_signal_info` (`main.cpp:59`).  
No idle timer / MAX_RUN / auto-exit keywords (gate `test_main_rc0_paths.sh`).

### Why supervise logs `rc=0` for SIGTERM

Daemon installs `sigaction(SIGTERM, on_signal_info)` → sets `g_stop` → orderly teardown → `return 0`.  
Shell `wait` then sees **WIFEXITED status 0**, not WIFSIGNALED 15.

Comment in source (`main.cpp:37-40`, `:1507-1508`):
> Handled signals yield process exit status 0 (WIFEXITED), NOT WIFSIGNALED — that is why a "clean rc=0" can still be an external SIGTERM.

**rc=0 is not proof of voluntary self-exit.**

## 2. `run_s` spread (98 … 7387)

No fixed timer in product main. Spread is **consistent with external SIGTERM timing** and **inconsistent with** a fixed internal timeout.  
Idle/no-client timeout: **no such path in source** (absence of keywords + single g_stop writer).

## 3. Why parent greps found nothing

Absence of `shutdown|SIGTERM|fatal|panic` in the daemon log is **evidence those strings are not present**, **not** proof the exit was non-signal.

Actual choke-point strings:

| String | Where |
|---|---|
| `misterplexd: main_loop exit pending` | daemon log |
| `misterplexd: EXIT_REASON code=` | daemon log + death file overwrite |
| `signal=` `si_pid=` `si_code_name=` | `misterplexd.death` |
| `event=process_exit` | `misterplexd.frame_ledger` |

On-device supervise (old) only logged:
```
EXIT pid=… rc=0 run_s=… — respawn in 2s
```
with **no** death/si_pid/sender — so 80 clean exits were **attribution-blind**.

## 4. Soak counter corruption (mechanism)

- `droppedFrames_` / `presentCount_` reset per stream / process.
- Respawn re-zeros lifetime counters.
- Cross-respawn truth: `misterplexd.frame_ledger` sums + stable `process_epoch` only.

## 5. What this lane shipped

1. **Upgraded** `scripts/misterplexd_supervise.sh` — every EXIT line now includes:
   `WIFEXITED_approx|WIFSIGNALED_approx`, `death_sig`, `si_pid`, `si_code_name`,
   `sender_cmd`, `sender_chain`, `death=[…]`, `last=[…]`, `log_tail=[EXIT_REASON…]`
   while keeping legacy `EXIT pid= rc= run_s=` prefix.
2. Host gates: `test_main_rc0_paths.sh`, `test_supervise_rc0_attribution.sh`,
   `test_supervise_exit_classify.sh` (handled-TERM→0).

**Does not stop external SIGTERM.** Stops blindness. Parent stops the sender once `si_pid` is known.

## 6. Parent commands (read-only first)

### 6a. One-shot attribution NOW (no restart)

```sh
ROOT=/media/fat/misterplex_v2
echo "=== death ==="; cat "$ROOT/misterplexd.death" 2>/dev/null || echo "NO-DATA death"
echo "=== last ==="; cat "$ROOT/misterplexd.last" 2>/dev/null || echo "NO-DATA last"
echo "=== supervise EXIT tail ==="
grep -E 'EXIT pid=|SUPERVISE_EXIT' "$ROOT/misterplexd_supervise.log" | tail -n 15
echo "=== daemon choke points (not shutdown|SIGTERM greps) ==="
grep -E 'EXIT_REASON|main_loop exit pending|FRAME_LEDGER event=process_' \
  "$ROOT/misterplexd.log" | tail -n 40
echo "=== ledger process boundaries ==="
if [ -f "$ROOT/misterplexd.frame_ledger" ]; then
  grep -E 'event=process_(start|exit)' "$ROOT/misterplexd.frame_ledger" | tail -n 20
  echo "process_start_n=$(grep -c 'event=process_start' "$ROOT/misterplexd.frame_ledger")"
  echo "process_exit_n=$(grep -c 'event=process_exit' "$ROOT/misterplexd.frame_ledger")"
else
  echo "NO-DATA frame_ledger"
fi
echo "=== live binary ==="
readlink -f "$ROOT/bin/misterplexd" 2>/dev/null
md5sum "$ROOT/bin/misterplexd" 2>/dev/null
echo "true rc=$?"
```

**PRE_REG:**
| ID | Prediction | Hit if |
|---|---|---|
| P1 | death or EXIT_REASON has `signal=15` (or sig=15 in why) | handled SIGTERM |
| P2 | `si_code_name=SI_USER` or `si_code=0` | kill(2)/shell, not SEGV |
| P3 | `si_pid` present (even if pid_gone) | attribution path alive |
| P4 | EXIT_REASON / main_loop lines exist in daemon log | binary has breadcrumb |
| P5 | If P4 miss on live binary → md5 older than EXIT_REASON ship | deploy newer daemon |

### 6b. Correlate last daemon lines before each of N exits

```sh
ROOT=/media/fat/misterplex_v2
L="$ROOT/misterplexd.log"
S="$ROOT/misterplexd_supervise.log"
# For each of the last 5 EXIT lines, print EXIT + preceding choke-point lines by time window.
grep -E 'EXIT pid=' "$S" | tail -n 5 | while IFS= read -r line; do
  ts=$(printf '%s' "$line" | awk '{print $1}')
  echo "======== EXIT $ts ========"
  echo "$line"
  # daemon log lines in the 30s before this UTC stamp (best-effort string match)
  grep -E 'EXIT_REASON|main_loop exit pending|playing|stopped|ended|SPAWN|MEASURED_' "$L" \
    | grep -F "$ts" || true
  # Also show last 15 choke lines overall near end of file (if timestamps differ)
  echo "--- nearest EXIT_REASON before this wall (manual scan) ---"
done
# Full last 50 choke points for human pairing:
grep -E 'EXIT_REASON|main_loop exit pending' "$L" | tail -n 50
echo "true rc=$?"
```

### 6c. After deploying upgraded supervise (parent-owned deploy)

Expect next EXIT lines to carry `si_pid=` / `sender_chain=` / `log_tail=[…EXIT_REASON…]`.  
That settles the sender; **do not kill the daily driver to test** unless intentional.

Candidates **after** si_pid (not findings yet): plexctl stop, deploy kill, soft_bounce killall, supervisor trap when supervise itself is TERM'd, manual kill.

## 7. Verdict

| Question | Answer |
|---|---|
| Why rc=0? | **Handled SIGINT/SIGTERM → main_loop → exitReported(0).** Only product path. |
| Self-timer / idle exit? | **No** in source (gate-locked). |
| run_s spread? | External signal timing. |
| Who sends? | **Unknown until death/si_pid on device** — 6a. |
| Fix to stop exits? | Stop the external sender; daemon cannot refuse SIGTERM and stay a service. |
| Evidence rule | Absence of `SIGTERM` substring ≠ non-signal exit. |
