# Gate-integrity reconfirm (parent re-task 2026-08-01)

**Branch:** `w-lint-gate-integrity`  
**Tip:** run `git rev-parse --short=8 HEAD`  
**Host-only.** Direct `true rc=$?` (no pipes).

## 1. Two-roots trap

| Fact | Evidence |
|---|---|
| Pair bare v1 default is **gone** on this tip | `tools/avsync_pair_daemon_hdmi.sh`: `LOG_REMOTE="${DAEMON_LOG_REMOTE:-}"` + live resolve |
| Broken historic pair **still RED** | fixture `tests/fixtures/two_roots/avsync_pair_daemon_hdmi.BROKEN_v1_default.sh` |
| Live root authority | `tools/avsync_live_log_resolve.inc.sh` — **`--conf` first**, then `/proc/exe` `*misterplexd*`, fallback **v2 before v1** |
| Deploy hook dual-root | `deploy_misterplexd.sh` greps v1 **and** v2; fails if v1 remains when root=v2 |
| Gate | `tests/unit/test_two_roots_path_order.py` |

| Check | true rc |
|---|---:|
| two_roots `--self-test` (broken RED + product GREEN) | **0** |
| broken pair fixture alone | **1** |
| product scan | **0** |

UNSCORED/NO-DATA when session/log unresolved is **preserved** (not zero-filled).

Install recipes that *write* into v1 (`package_release`, some f3 lab tools) are not live-read first-hit; classified in `docs/evidence/w_lint_TWO_ROOTS_TRAP.md`. w-promote still owns default install root policy.

## 2. `video_regression` running bitstream

No silicon content-hash today (`CORENAME`/`RBFNAME` vacuous; disk≠fabric).  
**Fail-closed for promotion:**

| Case | true rc | `GATE_RESULT` |
|---|---:|---|
| Mixed SPI↔DDR pair | **1** | `FAIL` `PROMOTE_OK=0` |
| Coherent pair, no PLXC/VIDREG | **2** | `CORE_IDENTITY_UNVERIFIED` |
| PLXC / `VIDREG_CORE_ID=ddr\|spi` | **0** | `FULL_PASS` |
| Dead daemon / no claim | **1** | `FAIL` |
| Unpinned daemon (e.g. `9ce2c2d1`) | **1** | `FAIL` (do not weaken) |

Host suite: `tests/unit/test_video_regression_liveness.sh` → **true rc=0**.  
Design for PLXC: `docs/core-running-bitstream-identity.md`.  
Daemon liveness: `/proc/PID/exe` deleted-tolerant `*misterplexd*` (not disk alone).  
`fix/gate-liveness` content **landed/superseded** on this lineage (rollcall derived from Makefile; do not re-merge 99-count tip).

## 3. Compile-fail = RED

| Guard | Status |
|---|---|
| `scripts/run_verilator.sh` PINNOTFOUND/%Error → **rc=2** | enforced |
| `test_gate_false_green_guard.py` RBG | RED **2** / GREEN **0** |
| Freeze TB uses `run_verilator` + `assert_sim_executed` | compile-only ≠ pass |
| Missing Verilator without `ALLOW_MISSING_VERILATOR=1` | **rc=3** (not 0); with ALLOW → **77 SKIP-NOT-PASS** ≠ pass |

`GATE_SKIP CRITICAL live-pms-baseline-profile` stays CRITICAL/skip-not-pass until real `MISTERPLEX_BASELINE_KEY` — **not weakened**.

## 4. Pipe-rc trap

| Check | true rc |
|---|---:|
| `--self-test` (synthetic `false\|tail` + `$?` RED; direct capture GREEN) | **0** |
| Scan `scripts/`+`tools/`+`tests/` | **0** |

Never `cmd | tail; echo true rc=$?`.

## Parent one-shot verify

```bash
cd .worktrees/w-lint
python3 tests/unit/test_two_roots_path_order.py --self-test; echo "true rc=$?"
python3 tests/unit/test_two_roots_path_order.py \
  --path tests/fixtures/two_roots/avsync_pair_daemon_hdmi.BROKEN_v1_default.sh
echo "true rc=$?"
python3 tests/unit/test_pipe_rc_trap.py --self-test; echo "true rc=$?"
python3 tests/unit/test_pipe_rc_trap.py; echo "true rc=$?"
python3 tests/unit/test_gate_false_green_guard.py; echo "true rc=$?"
bash tests/unit/test_video_regression_liveness.sh; echo "true rc=$?"
```

Device (parent only): `scripts/video_regression.sh verify; echo "true rc=$?"`  
— key `GATE_RESULT=` / `PROMOTE_OK=` / true rc, never mid-script OK.
