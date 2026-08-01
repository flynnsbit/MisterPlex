# Daemon clean `rc=0` exit RCA (w-cpu)

**Status:** SOURCE-DEFINITIVE for *which path* returns 0. SENDER is on-device evidence
(death file / SUPERVISE_EXIT), not inventable from repo alone.

**ERROR 17:** discarded entirely. Nothing in this lane built on `fps=24/1` vs 23.976.
Fixtures are 24.000; rational path is correct. No unwind.

---

## 1. Every `main()` path that can return 0

| # | Site (quoted) | When | Product? |
|---|---|---|---|
| A | `main.cpp` `--help` → `deathBreadcrumbExit(0,"site=main.cpp:--help"); return 0;` (~L257) | CLI help | no (lab/CLI) |
| B | `exitReported(0, "site=main.cpp:lab-play-file-done", …)` (~L798) | `--play-file` finished | no (lab) |
| C | `exitReported(0, why, …)` after `while (!g_stop)` (~L1501) with `why` = `site=main.cpp:main_loop_g_stop sig=…` | **SIGINT or SIGTERM handler set `g_stop`** | **YES — only product path** |

Non-zero product/lab exits (not this bug class):

- `lab-play-file-failed` → 1
- `lab-play-file-zero-frames` → 2
- `companion-start-failed` → 1

**Gate:** `tests/unit/test_main_rc0_paths.sh` locks catalog: exactly 2× `exitReported(0,`, 1× bare `return 0;`, 1× `g_stop.store`, no timer-exit keywords.

### Product loop (quoted contract)

```
// Product main loop exits ONLY when g_stop is set. The only writers are the
// SIGINT/SIGTERM handlers … Handled signals yield process exit status 0
// (WIFEXITED), NOT WIFSIGNALED — that is why a "clean rc=0" can still be an
// external SIGTERM.
```

`g_stop.store(true)` appears **once**, in `on_signal_info` (`main.cpp` ~L59).
There is **no** fixed-timer / idle-auto-exit / MAX_RUN product path in `main.cpp`.

### Why supervisor sees `rc=0` for SIGTERM

`scripts/plexctl.sh` supervise block (generated `/tmp/plexctl_supervise.sh`):

```
#   st < 128  → WIFEXITED-like, exit_status=st  (handled SIGTERM → often st=0)
#   st >= 128 → WIFSIGNALED-like, signal=(st-128)
```

Handled SIGTERM → process **exits 0** → shell `wait` → `st=0` → log looks like a clean exit.
That is **not** proof of voluntary idle exit. It is the designed handled-signal path.

`SIGKILL` → `st=137` (128+9). Parent verified separately; not this class.

---

## 2. "No shutdown|SIGTERM|fatal|panic in daemon log"

**Absence of those substrings is not evidence the exit was non-signal.**

Actual choke-point strings (must grep these):

| String | Where |
|---|---|
| `misterplexd: main_loop exit pending` | stderr / daemon log |
| `misterplexd: EXIT_REASON code=` | stderr + always attempted |
| `misterplexd.death` | confDir beside conf |
| `event=process_exit` | `misterplexd.frame_ledger` |
| `SUPERVISE_EXIT` / `WIFEXITED_approx` | supervise log |

If those lines are also missing on a live `rc=0` death, that is a **breadcrumb gap** (binary older than breadcrumb, confDir wrong, or hang before `exitReported` with only signal-safe death line). It is still not proof of a voluntary timer.

---

## 3. Counter corruption (parent’s real pain)

Quoted product behaviour:

- `droppedFrames_` / `presentCount_` reset per stream (`media_player.cpp` play start / session end path).
- In-process `lifetime_*` accumulate across streams **until process death**.
- On respawn, lifetime starts at 0 again.

**Cross-respawn truth** is only in append-only:

- `<confDir>/misterplexd.frame_ledger` — `process_start` / `session_end` / `process_exit`
- Sum tool: `frameLedgerSumFile` / `tools/frame_ledger_report.py`
- Telemetry `session_epoch=process_epoch.stream_seq` — **must invalidate** any soak window that spans a `process_epoch` change (`frame_ledger.hpp` P4).

So: any published “drops=2 across 7075 frames” from a **single live status line** after unknown respawns is **segment-local**, not soak-global. That claim class is invalid without ledger sum + stable `process_epoch`.

---

## 4. What sends SIGTERM? (candidates — not findings until death file says so)

Source cannot name the sender. Candidates for **on-device** discrimination via `si_pid` / `sender_cmd` / `sender_chain` on SUPERVISE_EXIT:

1. `plexctl` stop/reload/deploy (`stop_all` → kill child)
2. Supervisor `trap 'kill $child …' TERM INT` when the supervisor itself is signalled
3. Manual/lab `kill`, ssh session teardown scripts
4. Another agent/tool touching the service (forbidden for workers; parent owns device)

**Not** a finding without `si_pid` / chain. Varying `run_s` (196 / 514 / 1543) is **consistent with external SIGTERM**, inconsistent with a fixed internal timer (and no timer exists in source).

---

## 5. Code fix shipped this turn (does not stop external SIGTERM)

| Change | Why |
|---|---|
| `deathBreadcrumbExit` keeps `signal=` / `si_code=` / `si_code_name=` / `si_pid=` after overwrite | SUPERVISE_EXIT previously risked losing SI_USER sender when orderly exit replaced the signal-safe death line |
| `deathBreadcrumbUptimeS()` + `exitReported` default uptime from breadcrumb | `frame_ledger` `process_exit` had `uptime_s=0` always (silent) |
| `tests/unit/test_main_rc0_paths.sh` | Locks catalog of return-0 paths; fails if a new voluntary exit is added |
| death unit asserts orderly exit preserves `si_pid=4242` | Red-before-green for the preserve fix |

**This does not flip default SUSPEND or stop external kills.** It makes the next death **attributable**.

Stopping the respawns requires the parent to read `si_pid`/`sender_chain` and stop that actor — or accept respawns and **only** quote ledger sums.

---

## 6. Parent on-device commands (safe, read-only)

**PRE_REG predictions (publish hit/miss):**

| ID | Prediction | Hit if |
|---|---|---|
| P1 | Latest `misterplexd.death` or SUPERVISE_EXIT death= contains `signal=15` or `sig=15` | SIGTERM handled path |
| P2 | `si_code_name=SI_USER` (or `si_code=0`) | kill(2)/shell kill, not kernel fault |
| P3 | `si_pid` resolves to plexctl/supervise/flock/sh chain OR gone pid | external stop |
| P4 | Daemon log near exit has `EXIT_REASON` and/or `main_loop exit pending` | breadcrumb alive on device binary |
| P5 | `frame_ledger` shows `process_exit` rows with matching uptime ≈ run_s | ledger path works; uptime non-zero after new binary |

**Miss handling:** If P1 false and wait_st=0 with empty death → unknown; capture binary md5 vs host build. If signal=9 → different class (SIGKILL).

### 6a. One-shot read (no service mutation)

```sh
# Parent runs on device or via existing ssh helper. Read-only.
# Resolve conf root the same way plexctl does (adjust if dual-root).
ROOT="${MISTERPLEX_ROOT:-/media/fat/misterplex}"
SUPLOG="$ROOT/supervise.log"
# Some labs use /media/fat/misterplex_v2 — check both if needed.
for ROOT in /media/fat/misterplex /media/fat/misterplex_v2; do
  [ -d "$ROOT" ] || continue
  echo "=== ROOT=$ROOT ==="
  echo "--- death ---"; cat "$ROOT/misterplexd.death" 2>/dev/null || echo "NO-DATA death"
  echo "--- last ---"; cat "$ROOT/misterplexd.last" 2>/dev/null || echo "NO-DATA last"
  echo "--- ledger tail ---"
  if [ -f "$ROOT/misterplexd.frame_ledger" ]; then
    tail -n 30 "$ROOT/misterplexd.frame_ledger"
    echo "process_start count=$(grep -c 'event=process_start' "$ROOT/misterplexd.frame_ledger" || true)"
    echo "process_exit count=$(grep -c 'event=process_exit' "$ROOT/misterplexd.frame_ledger" || true)"
  else
    echo "NO-DATA frame_ledger"
  fi
  echo "--- SUPERVISE_EXIT tail ---"
  if [ -f "$ROOT/supervise.log" ]; then tail -n 20 "$ROOT/supervise.log"
  elif [ -f /tmp/plexctl_supervise.log ]; then tail -n 20 /tmp/plexctl_supervise.log
  else ls -la "$ROOT"/*sup* "$ROOT"/*.log 2>/dev/null | head
  fi
  echo "--- daemon log EXIT_REASON / main_loop ---"
  # path varies; common:
  for L in "$ROOT/misterplexd.log" "$ROOT/log/misterplexd.log" /tmp/misterplexd.log; do
    [ -f "$L" ] || continue
    echo "log=$L"
    grep -E 'EXIT_REASON|main_loop exit pending|FRAME_LEDGER event=process_' "$L" | tail -n 30
  done
done
echo "true rc=$?"
```

### 6b. After next observed EXIT (same method)

Do **not** kill the daemon to test unless intentional. On next natural SUPERVISE_EXIT line, record:

- `wait_st` / `how=`
- `death=[…]` full snap (`signal=` `si_pid=` `si_code_name=`)
- `sender_cmd=` `sender_chain=`
- matching `EXIT_REASON` line if present

### 6c. Soak claim rule (binding)

```
OK:   sum(session_end drops/presents/frames) from frame_ledger over window
      with process_start/exit annotated; reject if process_epoch changes mid-window
BAD:  single status line drops= after unknown SUPERVISE_EXIT count
```

---

## 7. Headroom statistic (secondary, closed)

**Do not quote** `166.4/200 ⇒ 33.6 headroom`.

MiSTer Main is an **elastic scavenger** (`poll(...,0)` spin). Replace with:

| Tool | Meaning |
|---|---|
| `tools/schedstat_sample.py` | runqueue wait fraction for ffmpeg/daemon |
| `tools/fixed_work_probe.py` | fixed-work wall ratio under load |
| `tools/starvation_480p_verdict.py` | combine inelastic + wait |
| H1 inelastic | ffmpeg% + daemon% only (exe-resolved) |

Method: `P=100*dticks/(HZ*dwall)`, resolve by `readlink -f /proc/<pid>/exe`, absence=NO-DATA.

---

## 8. Verdict

| Question | Answer |
|---|---|
| Why rc=0? | **Handled SIGINT/SIGTERM → `g_stop` → `exitReported(0)`.** Only product path. |
| Voluntary timer? | **No such path in source** (gate-enforced). |
| Who sends signal? | **Unknown until death/SUPERVISE_EXIT si_pid** — commands above. |
| Fix to stop exits? | **Cannot stop external SIGTERM in-daemon.** Ship attribution + uptime + path gate; parent stops sender or quotes ledger. |
| Soak drops claims | **Invalid across respawn without frame_ledger sum + process_epoch stability.** |

---

## 9. Host verification (this change)

```sh
make unit; echo "true rc=$?"
# targeted:
./build/test_death_breadcrumb; echo "true rc=$?"
bash tests/unit/test_main_rc0_paths.sh; echo "true rc=$?"
bash tests/unit/test_supervise_exit_classify.sh; echo "true rc=$?"
```
