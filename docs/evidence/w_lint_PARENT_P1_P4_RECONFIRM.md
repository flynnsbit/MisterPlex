# w-lint — parent PRIORITY 1–4 reconfirm (host-only)

**Branch:** `w-lint-gate-integrity`  
**Tip at measurement:** `5dcecbfe` (docs) / functional inert-gate `7a66341e`  
**Worktree:** `.worktrees/w-lint`  
**Rule 0:** all `true rc` captured **directly** (no pipe). Device not touched.

---

## PRIORITY 1 — running bitstream identity (`scripts/video_regression.sh`)

**Status: FIXED (fail-loud; no software content-hash of RUNNING rbf on c5382bee).**

| Claim path | GATE_RESULT | PROMOTE_OK | true rc |
|---|---|---|---|
| pair OK, no PLXC / `VIDREG_CORE_ID` unset | `CORE_IDENTITY_UNVERIFIED` | `0` | **2** |
| mixed SPI core + DDR daemon claim | `FAIL` | `0` | **1** |
| injected `VIDREG_CORE_ID=ddr` (PLXC / parent) | `FULL_PASS` | `1` | **0** |
| mid-script `OK daemon-live` alone | never promote green | — | — |

**Evidence (unit harness, host):**

```
tests/unit/test_video_regression_liveness.sh
  [older-spi] GATE_RESULT=CORE_IDENTITY_UNVERIFIED PROMOTE_OK=0 true rc=2
  [coreid-ddr-ok] GATE_RESULT=FULL_PASS
  ALL test_video_regression_liveness checks passed
true rc=0
```

**Why not “identify”:** `CORENAME`/`RBFNAME` always `Plex`; on-disk RBF md5 ≠ fabric; PLXD/PLXS = family/liveness only (residue can fake magic); PLXC @ doorbell+0x130 is fit-gated and **not** on shipping `c5382bee`. HDMI fingerprint = **parent-only**.  
Honest contract: **FULL_PASS only with `GATE_CORE_IDENTITY=VERIFIED_PLXC`**; otherwise refuse with `rc=2` / mixed `rc=1`. Do **not** weaken comparison.

**Parent hardware check (you run):** after any deploy that might mix SPI/DDR:

```bash
# Expect without PLXC inject: exit 2, GATE_RESULT=CORE_IDENTITY_UNVERIFIED, PROMOTE_OK=0
./scripts/video_regression.sh verify; echo "true rc=$?"
# Mixed pair must be rc=1 FAIL, never FULL_PASS
```

---

## PRIORITY 2 — blind-green / blind-red class (pattern audit)

| Pattern | Status on this branch | Proof |
|---|---|---|
| Disk-only daemon hash (ETXTBSY / dead daemon green) | **Fixed** — `/proc/PID/exe` + HTTP; n_daemon=0 → FAIL | `test_video_regression_liveness` new-http-dead / etxtbsy → `GATE_RESULT=FAIL` |
| COMPILE-FAIL scored skip (PINNOTFOUND) | **Fixed** — `run_verilator.sh` rc=2; Python `verilator_invoke.py` hard-fail even if VL rc=0 | `test_gate_false_green_guard.py` RBG; inert sweep `w_lint_INERT_GATE_SWEEP.md` |
| UNREGISTERED_COMMAND / rollcall drift | **Hard** — `expected_commands=126` sha16 `67395583620c7487` | `test_unit_rollcall.py` true rc=0 |
| set+e glued into md5 (blind-RED → temptation to relax) | **Fixed at capture** — `gate_join_remote_parts` + `gate_assert_md5_shape` reject `*set *` | `test_harness_capture_integrity.py` true rc=0; RBG_RED_SHAPE_OK |
| Inert `#if defined(constexpr)` class | Tripwire + py false-green scan | `test_false_green_pattern_guard.py`; `test_gate_false_green_guard.py` scans `.py` `return 0` |
| ALLOW_MISSING_VERILATOR soft-skip as PASS | **Fixed** → rc=77 SKIP-NOT-PASS | inert RBG |
| Direct `verilator --cc` bypass of `run_verilator.sh` | **Fixed** via `verilator_invoke.py` | inert RBG |
| av_drift / av-lock as lip-sync PASS | Documented TELEMETRY_ONLY; static guard | `w_lint_AV_DRIFT_BLIND.md` |

Full suite maps: `docs/evidence/w_lint_GATE_SUITE_AUDIT.md`, `w_lint_FALSE_GREEN_HUNT.md`, `w_lint_INERT_GATE_SWEEP.md`.

**Harness capture (this tip):**

```
python3 tests/unit/test_harness_capture_integrity.py
  HARNESS_CAPTURE RBG_OK glue+shape+docs
true rc=0
```

**Residual (not weakened):** `deploy_misterplexd.sh` may print deploy_overall before geometry; geometry rc=77 must stay SKIP-NOT-PASS and not launder to deploy green — follow-up if still open on merge tip.

---

## PRIORITY 3 — CRITICAL soft-skip `live-pms-baseline-profile`

**Status: VISIBLE + COUNTABLE; not lowered.**

Without `MISTERPLEX_BASELINE_KEY` / `PLEX_KEY`:

```
GATE_SKIP CRITICAL live-pms-baseline-profile: reason=missing MISTERPLEX_BASELINE_KEY;
  would_catch=PMS drift away from the FPGA decoder contract ...
GATE_RESULT=PASS_INCOMPLETE wrapped_rc=0 critical_skips=1 process_rc=78
make unit true rc=2   # non-zero surfaces incomplete (not PASS)
```

`run_with_skip_summary.py --self-test` true rc=0:

- CRITICAL skip → `process_rc=78` PASS_INCOMPLETE  
- soft-skip 77 → `process_rc=77` SKIP_NOT_PASS  
- no skips → `process_rc=0` PASS  

**Enforce (do not lower):**

```bash
# Live PMS path (parent/device-capable host with key):
make pms-baseline-live
# or host Annex-B fixture:
MISTERPLEX_BASELINE_ANNEXB=path/to/baseline.264 make unit
# Host-only without claim:
make unit-unlocked   # does not launder CRITICAL as pass in full unit
```

**Exposure while key missing:** PMS can drift off FPGA decoder contract (profile_idc=66, CAVLC, ref=1, no B, 624×480 coded / 618×480 display) with **no hard unit fail** unless process_rc=78 is treated as ship-blocker (it is on `make unit`).

---

## PRIORITY 4 — `fix/gate-liveness` (323c14f1)

**Status: CLOSE / SUPERSEDED — do not merge.**

| Fact | Evidence |
|---|---|
| `323c14f1` is **not** ancestor of this HEAD | `git merge-base --is-ancestor 323c14f1 HEAD` → exit **1** |
| Liveness fix content is already on tree via `f746f10f` lineage | `git merge-base --is-ancestor f746f10f HEAD` → exit **0** |
| Stale branch carried `expected_commands≈99–103` | This branch: **126** protected; rollcall true rc=0 |
| Merge would re-introduce rollcall RED / UNREGISTERED churn | Rule: never hand-edit count; `python3 tests/unit/test_unit_rollcall.py --write-expected` |

Superseding work on this lane already includes: live `/proc/PID/exe` enum, HTTP probe, ETXTBSY disk≠live FAIL, n_daemon=0 FAIL, **plus** running-core identity refuse (rc=2) which 323c14f1 never had.

---

## Rollcall / unit snapshot (tip)

```
UNIT_ROLLCALL_OK protected_commands=126 expected_commands=126
  derived_protected_sha256_16=67395583620c7487
true rc=0

tests/unit/test_promotion_gates.sh → summary pass=66 fail=0 true rc=0
make unit (no BASELINE_KEY) → GATE_RESULT=PASS_INCOMPLETE process_rc=78; make true rc=2
```

---

## What still blocks **promotion** (by design)

1. **No PLXC / parent HDMI identity inject** → `video_regression.sh verify` stays **rc=2** `PROMOTE_OK=0` even if pair/liveness OK.  
2. **CRITICAL PMS key missing** → `make unit` **process_rc=78** / make rc≠0.  
3. **Display-side frame skips** parent measured (telemetry identity closes while HDMI skips) — **out of scope for software identity gate**; needs parent pixel instrument, not daemon residual=0.

None of these are fixed by relaxing thresholds.
