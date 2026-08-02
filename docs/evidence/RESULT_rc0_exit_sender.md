# RESULT — clean rc=0 mid-soak RCA (hypothesis + observability + multi-life soak)

## 1) Hypothesis: CONFIRMED from source

**Claim:** product `rc=0` = handled SIGTERM/INT only (`main_loop_g_stop`).

**Catalog** (`tests/unit/test_main_rc0_paths.sh`, green):

| site | kind |
|------|------|
| `site=main.cpp:--help` | bare `return 0` after deathBreadcrumbExit — lab CLI only |
| `site=main.cpp:--version` | bare `return 0` after deathBreadcrumbExit — lab CLI only |
| `site=main.cpp:lab-play-file-done` | `exitReported(0,…)` — lab only |
| `site=main.cpp:main_loop_g_stop` | **only product-loop rc=0** |

Quoted (`arm/misterplexd/main.cpp`):

- L57–61: product loop exits ONLY when `g_stop` set; handled signals → WIFEXITED 0
- L66–79: sole `g_stop.store(true)` is `on_signal_info` (SIGINT/SIGTERM, SA_SIGINFO)
- L1534–1558: after loop → `exitReported(0, why, …)` with `sig=` `si_code=` `si_pid=`

**No other product rc=0 path.** Hypothesis stands. Daemon is not voluntarily exiting idle.

Timer keywords (`MAX_RUN_S` / `IDLE_EXIT`) forbidden by catalog gate.

## 2) Sender: supervisor is NOT a timed killer

`scripts/misterplexd_supervise.sh`:
- Loop: spawn → `wait` → log → sleep backoff → respawn
- **Only** signal to child: trap TERM/INT → `kill $child` (forwards *our* stop)
- No health probe, no memory threshold, no fixed run timer

Variable `run_s` (1543 / 196 / 514) fits **external condition-triggered SIGTERM**, not a fixed supervise timer. Candidates (host-side inventory only — parent must attribute with si_pid on device):

- `plexctl.sh stop` / reload / deploy kill-captured-PIDs (`scripts/plexctl.sh:119`, `deploy_misterplexd.sh`)
- Another agent/script sending TERM
- Core reload / boot path (not proven here)

**Host cannot name the live sender.** Parent command after next exit:

```sh
ROOT=/media/fat/misterplex_v2
echo "=== death ==="; cat "$ROOT/misterplexd.death"; echo
echo "=== last SUPERVISE_EXIT ==="
grep SUPERVISE_EXIT "$ROOT/misterplexd_supervise.log" | tail -3
echo "=== EXIT_REASON in daemon log ==="
grep EXIT_REASON "$ROOT/misterplexd.log" | tail -3
true; echo "true rc=$?"
```

Expect: `signal=15` `si_code_name=SI_USER` `si_pid=N` `sender_cmd=[…]` on SUPERVISE_EXIT after this ship.

## 3) Shipped observability

Already on tip (death breadcrumb SA_SIGINFO + EXIT_REASON si_*). **Gap closed this commit:** product `misterplexd_supervise.sh` previously logged only `EXIT pid= rc= run_s=` with **no death snap**. Now matches plexctl:

- `SUPERVISE_EXIT` with `death=[…]` `si_pid=` `si_code=` `sender_cmd=` `sender_chain=`

Daemon side (pre-existing, verified): `on_signal_info` → `deathBreadcrumbOnSigInfo` → orderly `deathBreadcrumbExit` preserves signal/si_pid.

## 4) Counters across restart (positive + refuse)

| tool | role |
|------|------|
| `tools/soak_continuity_assert.py` | single-life claim; **FAIL** if process_epoch/pid changes |
| `tools/soak_ledger_report.py` **NEW** | multi-life **sum** of session_end frames/presents/drops; prints `restarts_spanned=N` and `REFUSE_SINGLE_LIFE_CLEAN` when N>0 |

`frame_ledger` already append-only across lives; `frameLedgerSumFile` unit-tested.

Naive last-life `drops=` undercounts (shown: last=5 hides life1 drops=2; product sum_drops=7).

## Host gates

| cmd | true rc |
|-----|---------|
| `bash tests/unit/test_main_rc0_paths.sh` | 0 |
| `bash tests/unit/test_soak_continuity_assert.sh` | 0 |
| `bash tests/unit/test_soak_ledger_report.sh` | 0 |
| `bash tests/unit/test_supervise_death_snap_static.sh` | 0 |
| `make unit` | **0** |

## Parent device follow-ups (parent only)

1. Deploy updated `bin/misterplexd_supervise.sh` (this file) to v2 root; restart supervise once.
2. Next unexplained exit: capture SUPERVISE_EXIT + death (command above).
3. Soak: run continuity assert for single-life; if FAIL, use `python3 tools/soak_ledger_report.py --ledger $ROOT/misterplexd.frame_ledger`.

## NOT verified on device

- Live si_pid of the 1543/196/514 exits
- That deploy/plexctl was the sender
