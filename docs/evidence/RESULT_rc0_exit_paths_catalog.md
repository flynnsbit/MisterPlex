# RESULT — daemon rc=0 exit RCA + EXIT_REASON + soak identity

**Branch:** `w-cpu-rc0-exit` (own worktree)  
**Rebased on:** `377c71a6` (parent tip; baseline note `c5b42e26`+merges)  
**Device:** not touched.

## Status (plain)

| Question | Answer |
|----------|--------|
| Why did device EXIT rc=0 at run_s=1543/196/514? | **UNKNOWN on device** without death file from that life. Source says product rc=0 = handled SIGTERM/INT only. |
| Does product voluntary idle-exit? | **No path in source** (catalog + host e2e). |
| Grep empty for shutdown/SIGTERM in daemon log | **Log absence only** — not proof of design, not proof of external kill. |

## 1) Every rc=0 route (`arm/misterplexd/main.cpp`)

| site | lines | reachable live product? |
|------|-------|-------------------------|
| `--version` | `:264-265` deathBreadcrumbExit(0) | CLI only |
| `--help` | `:295-296` | CLI only |
| `lab-play-file-done` | `:904` exitReported(0) | lab `--play-file` only |
| **`main_loop_g_stop`** | `:1697` exitReported(0, why with sig/si_*) | **only product loop rc=0** |

- Sole `g_stop.store(true)`: `on_signal_info` `:80` (SIGINT/SIGTERM SA_SIGINFO `:626-633`)
- No `exit(0)` / `quick_exit` / timer keywords in product main
- Child `_exit(127)` only on exec fail (`media_player.cpp:306`, `:1432`) — not rc=0

## 2) EXIT_REASON

Already choke-point `deathBreadcrumbExit` → stderr `EXIT_REASON code=… why=… signal=… si_pid=…` + `misterplexd.death`.

This bead: `fflush(stderr)` + `fsync(death fd)` before return; host e2e SIGTERM proves path.

## 3) Counter reset visibility (P4)

- `droppedFrames_.store(0)` / `publishMisses_.store(0)` per stream start (`media_player.cpp:3084-3085`)
- **Already:** hz status line emits `process_epoch` + `pid` + `session_epoch` + `lifetime_*`
- **This bead:** bind `process_epoch`/`pid`/`session_epoch` on **A/V resync drop**, **publish_miss**, **SESSION_COLLAPSE_LEDGER** so grepping `drops=` cannot lose life identity
- Tools: `tools/soak_continuity_assert.py` (FAIL on epoch change), `tools/soak_ledger_report.py` (multi-life sum + REFUSE_SINGLE_LIFE_CLEAN)

## 4) Host gates (true rc)

| cmd | rc |
|-----|-----|
| test_death_breadcrumb | 0 |
| test_exit_reason_sigterm_e2e | 0 |
| test_main_rc0_paths | 0 |
| test_drops_bind_process_epoch | 0 |
| rollcall (commands **175** = 172+3) | 0 |
| make unit | (run at ship) |

## 5) Parent hardware sequence (DISCRIMINATE)

PRE_REG:
- A) If product self-exits: death `signal=0` / why without sig=15
- B) If external SIGTERM: `signal=15 si_code_name=SI_USER si_pid≠0 sender_cmd=…`
- C) If SIGKILL: no death write (or stale); supervise rc=137

```sh
ROOT=/media/fat/misterplex_v2
# 1) Snapshot before soak
cp -a "$ROOT/misterplexd.death" /tmp/death.before 2>/dev/null || true
# 2) Note current process identity from log or status
grep -E 'process_epoch=|EXIT_REASON' "$ROOT/misterplexd.log" | tail -5
# 3) Run soak N minutes WITHOUT deploy/restore
# 4) On any supervise EXIT rc=0:
echo "=== death after EXIT ==="
cat "$ROOT/misterplexd.death"; echo "true rc=$?"
echo "=== SUPERVISE_EXIT ==="
grep SUPERVISE_EXIT "$ROOT/misterplexd_supervise.log" | tail -5; echo "true rc=$?"
echo "=== EXIT_REASON ==="
grep EXIT_REASON "$ROOT/misterplexd.log" | tail -5; echo "true rc=$?"
# 5) Single-session proof on soak log excerpt:
python3 tools/soak_continuity_assert.py --log /path/to/soak_excerpt.log; echo "true rc=$?"
# FAIL = process_epoch/pid changed → do NOT quote drops= as single life
python3 tools/soak_ledger_report.py --ledger "$ROOT/misterplexd.frame_ledger"; echo "true rc=$?"
```

**Unfinished:** root cause of *device* 1543/196/514 senders not named until parent runs step 4 on a fresh exit. Instrumentation + source catalog are shipped; fixing the sender (if lab tooling) is ops, not a product code change until death names it.
