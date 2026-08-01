# rc=0 exit characterization + soak continuity (w-cpu)

**Date:** 2026-08-01  
**Branch tip work:** soak continuity assert + `pid=` on 1 Hz media line  
**Prior:** `8332bf93` death si_pid preserve  

## Corrections absorbed (parent)

| Claim | Action |
|---|---|
| ERROR 17 `fps=24/1` vs 23.976 | **Discarded** — never built product on it |
| 117 ms A/V "device defect" / SESSION-LATCHED | **Discarded** — parent: capture argv confound. Do not cite as device defect |
| "pause overlay never fires" | **Not used** in this lane |

Parent line refs `media_player.cpp:2312`/`:2432` for counter reset are **stale**. Current reset sites (this tree):

- `droppedFrames_.store(0)` — `media_player.cpp:2860` (present-loop start)
- `presentCount_ = 0` — `media_player.cpp:2983` (rawvideo path arm)

---

## 1. What triggers product `rc=0`? (source, not device)

### Product paths that return 0

| Path | Condition | Signal? |
|---|---|---|
| `main.cpp` `--help` → `return 0` | CLI only | no |
| `lab-play-file-done` → `exitReported(0,…)` | `--play-file` lab only | no |
| **`while (!g_stop)` ends → `exitReported(0, why)`** | **only product long-run path** | **yes: SIGINT or SIGTERM** |

Cited:

```text
main.cpp:37-40   Product main loop exits ONLY when g_stop is set.
main.cpp:46-59   on_signal_info: stores sig/si_code/si_pid; deathBreadcrumbOnSigInfo; g_stop=true
main.cpp:1465    while (!g_stop.load(...)) { sleep 200ms; ... }
main.cpp:1481-1505  why=site=main.cpp:main_loop_g_stop sig=%d si_code=%d si_pid=%d
                     → exitReported(0, why)
```

**Only writer of `g_stop`:** `on_signal_info` (`g_stop.store` once at L59).  
**No** product timer / idle-exit / MAX_RUN (enforced by `tests/unit/test_main_rc0_paths.sh`).

### Handled SIGTERM vs "genuine self-exit"

| Class | wait status | death / EXIT_REASON | Meaning |
|---|---|---|---|
| Handled SIGTERM/SIGINT | shell `wait` **0** (`WIFEXITED`) | `signal=15` (or 2), `si_code_name=SI_USER` (typical kill), `si_pid=<sender>` | **Not a crash.** Orderly teardown. **Not voluntary self-exit.** |
| Lab self-exit | 0 | `why=site=main.cpp:--help` or `lab-play-file-done`; `signal=0` `si_code_name=NONE` | Only with those argv modes |
| Unhandled fatal | `wait` ≥128 (e.g. 139 SEGV) | death signal=11 etc. | Crash |
| SIGKILL | 137 | death often stale; no handler | Kill -9 |

**`8332bf93` does distinguish** handled-SIGTERM from lab self-exit **when the death file / EXIT_REASON is from that binary**:

- Orderly exit **preserves** last SA_SIGINFO: `signal=` `si_code=` `si_code_name=` `si_pid=` on `misterplexd.death` and stderr `EXIT_REASON` (`death_breadcrumb.cpp` Exit path).
- Before that commit, orderly `deathBreadcrumbExit` **overwrote** the signal-safe line and could drop first-class `si_pid` (why= string still had them if main_loop path ran).

**Live daemon md5 `3883f5ab…` vs host `build/misterplexd` md5 `56f815c7…`:** **different.** Whether live has `8332bf93` / `process_epoch` is **unknown until parent greps device log/death** — do not assert live behaviour from host SHA alone.

### Periodic vs event-driven?

**Source:** event-driven only (external signal). **Not** periodic in-process.

**Observed run_s 196 / 514 / 1543:** consistent with **external** SIGTERM timing, inconsistent with a fixed internal timer (and no timer exists).  
Correlation with cast start/stop / idle / deploy: **unknown — settle with si_pid + sender_chain on next SUPERVISE_EXIT.**

---

## 2. Benign? (plain)

| Question | Answer |
|---|---|
| Is it a **crash** (SEGV/abort/SIGKILL)? | **No** for the reported `rc=0` class — that class is handled signal → orderly `return 0`. |
| Is it a **voluntary self-exit** (daemon decided to die)? | **No** in product source — only external SIGINT/SIGTERM sets `g_stop`. |
| Is the **restart operationally benign**? | **Unknown until sender is named.** Supervisor respawn preserves *service presence* but **destroys counter continuity** and can interrupt playback. That is **not** "crash", and **not** automatically "fine for soaks". |
| Will I assert "memory pressure"? | **No** — no measurement. |

---

## 3. Detection artifact for soaks (defensible)

### Already in tree (if binary is new enough)

| Marker | Where | Rule |
|---|---|---|
| `process_epoch=N` | 1 Hz `media:` line | Must be **constant** for whole soak window |
| `session_epoch=N.M` | same | May change on **new stream** (not respawn alone) |
| `misterplexd.frame_ledger` | confDir | `process_start` / `process_exit` rows |
| `pid=` on media line | **this change** | Must be **constant**; changes on every respawn |

`process_epoch` is steady `mono_ms` at daemon stamp (`media_player` `stampProcessEpoch` / main after construct). It is the **run-id**.

### Tool (host-side; parent feeds pulled logs)

```bash
python3 tools/soak_continuity_assert.py \
  --log /path/to/daemon_media_slice.log \
  --ledger /path/to/misterplexd.frame_ledger
echo "true rc=$?"
# 0 CONTINUITY_OK | 2 CONTINUITY_FAIL | 77 NO-DATA
```

**Binding soak rule:** any drop/vfps/pfps claim over a window without `CONTINUITY_OK` is **not defensible**.

---

## 4. Parent on-device commands (read-only; daily driver safe)

### 4a. Does live binary expose continuity markers? (PRE_REG)

**PRE_REG L1:** log has `process_epoch=` on media lines → continuity tool usable.  
**PRE_REG L2:** death/EXIT_REASON has `signal=` `si_pid=` → 8332bf93-class attribution.  
**PRE_REG L3:** md5 stays `3883f5ab…` until intentional deploy — this read does not change it.

```sh
ROOT=/media/fat/misterplex   # or misterplex_v2 if that is the live root
# Resolve daemon by exe (NEVER cmdline substring — ERROR 14)
D_PID=""
for d in /proc/[0-9]*; do
  exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
  exe=${exe% (deleted)}
  case "$exe" in *misterplexd) D_PID=${d#/proc/}; break;; esac
done
echo "daemon_pid=${D_PID:-NO-DATA}"
if [ -n "$D_PID" ]; then
  tr '\0' ' ' <"/proc/$D_PID/cmdline"; echo
  md5sum "$(readlink -f /proc/$D_PID/exe)" 2>/dev/null || true
fi
# Recent media continuity fields (absence = NO-DATA, not "no exit")
for L in "$ROOT/misterplexd.log" "$ROOT/log"/*.log /var/log/misterplexd.log; do
  [ -f "$L" ] || continue
  echo "LOG=$L"
  grep -E 'process_epoch=| session_epoch=| pid=' "$L" | tail -n 5
  grep -E 'EXIT_REASON|main_loop exit pending|FRAME_LEDGER event=process_' "$L" | tail -n 20
done
echo "--- death ---"; cat "$ROOT/misterplexd.death" 2>/dev/null || echo "NO-DATA death"
echo "--- ledger process boundaries ---"
if [ -f "$ROOT/misterplexd.frame_ledger" ]; then
  grep -E 'event=process_' "$ROOT/misterplexd.frame_ledger" | tail -n 20
else
  echo "NO-DATA ledger"
fi
echo "--- SUPERVISE_EXIT ---"
# path varies by install; try common
for S in "$ROOT/supervise.log" /tmp/plexctl_supervise.log; do
  [ -f "$S" ] && { echo "SUP=$S"; tail -n 15 "$S"; }
done
echo "true rc=$?"
```

### 4b. Next natural exit (do **not** kill to test unless intentional)

On next SUPERVISE_EXIT line, record full:

`wait_st` `how=` `death=[signal= si_code_name= si_pid=]` `sender_cmd=` `sender_chain=` `run_s=`

**PRE_REG E1:** `signal=15` + `si_code_name=SI_USER` → external kill.  
**PRE_REG E2:** `si_pid` chain includes plexctl/supervise/flock/deploy → operational restart.  
**PRE_REG E3:** `signal=0` / `lab-play-file` / `--help` on product long-run → **miss** (unexpected; publish).  
**PRE_REG E4:** no death + wait 0 → binary/breadcrumb gap or hang-then-kill race — unknown.

### 4c. Soak window proof (after pulling logs)

```sh
# On host, after scp of log slice + ledger covering the soak:
python3 tools/soak_continuity_assert.py --log soak_media.log --ledger misterplexd.frame_ledger
echo "true rc=$?"
```

---

## 5. What this does / does not fix

| Does | Does not |
|---|---|
| Name the **only** product rc=0 path as handled SIGTERM/INT | Stop external SIGTERM |
| Give soak **CONTINUITY_OK/FAIL** artifact | Make old live binary emit `pid=` without deploy |
| Preserve si_pid after orderly exit (8332bf93+) | Claim live md5 already has 8332bf93 |

**Deploy of new binary is parent-owned.** Until then, soaks must use whatever markers live logs actually contain; if `process_epoch` absent → **NO-DATA**, not pass.
