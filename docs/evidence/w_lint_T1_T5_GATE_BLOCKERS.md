# w-lint T1–T5 gate blockers (host-only)

## T5 WITHDRAWN (parent ERROR 20) — DO NOT TREAT AS DEFECT

Parent mis-read `ddr_bank_release_select.hpp` without the enclosing block.
The file's **HISTORICAL FAULT (fixed…)** note correctly documents that an
older pack put `bank_vsync_count` into `frames_done`, and that product RTL
now packs the real swap counter. **Do not rewrite as a "stale comment" fix.**

- Restored canonical HISTORICAL FAULT block from parent-verified main tree.
- Encoded: `docs/COMMENT_CONTEXT_RULE.md`, `tests/unit/test_comment_context_guard.py`
- RBG: strip HISTORICAL FAULT → rc=1; bare present-tense claim → rc=1; restore → rc=0


**Branch tip at write:** see git. **No device / no Quartus.**

All `true rc` captured **directly** (no pipe).

---

## T1 — opposite outcomes sharing one exit code

### glass_template_skip.py

Parent found `SKIP_FAIL` and `INSTRUMENT_OR_FIXTURE_FAIL` both `rc=2`.

**On this tree (imported from w-instr `b5a4876b` + locked):**

```
RC_SKIP_FAIL = 2
RC_INSTRUMENT_FAIL = 3
verdict, rc = "INSTRUMENT_OR_FIXTURE_FAIL", RC_INSTRUMENT_FAIL
verdict, rc = "SKIP_FAIL", RC_SKIP_FAIL
```

```
python3 tools/glass_template_skip.py --self-test
  PASS D2 distinct rc SKIP_FAIL=2 INSTRUMENT=3
  PASS ERROR18 refuse rc=77
  PASS ERROR19 refuse rc=77
  SELF_TEST_OK
true rc=0
```

**Repo lock:** `tests/unit/test_exit_code_collision_guard.py`  
fails if those RC_* collide again; scans other `tools/*.py` FAIL-class constants.

```
python3 tests/unit/test_exit_code_collision_guard.py --self-test; echo "true rc=$?"
python3 tests/unit/test_exit_code_collision_guard.py; echo "true rc=$?"
```

### Audit note

Many scripts use `rc=2` for *one* failure class (usage vs hard fail) — OK if only one FAIL meaning. Collision class = **two FAIL verdicts → same numeric rc**.

---

## T2 — what input makes each gate RED?

| Gate | RED input (constructed / measured) | true rc | Decorative? |
|------|--------------------------------------|---------|-------------|
| `make define-parity` | Change `kPlex480pCodedWidth{624}`→`{623}` then restore | **1** then **0** | **No** — RBG both dirs |
| `make quartus-sv-subset` | Syntax error in listed SV / missing file (via `check_quartus_sv_subset.py`) | (not re-broken this run; script exits non-zero on parse fail) | **No** if subset list non-empty |
| `make unit` | Missing `MISTERPLEX_BASELINE_KEY` → CRITICAL skip | **2** / process_rc=**78** | Incomplete ≠ pass |
| `make post-fit-hierarchy` | Omit `FIT_RPT` | **2** `FIT_RPT is required` | **No** (also RED if module missing from rpt) |
| `make post-fit-timing` | Omit `STA_RPT` | **2** | **No** (also RED on neg slack) |
| `tests/hw/test_fbar_fast.sh` | Default (v3 core) | **77** SKIP-NOT-PASS obsolete | Soft-skip, **not** pass; not a product gate |
| `scripts/run_verilator.sh` PINNOTFOUND | Injected elab error via `test_gate_false_green_guard` | **2** HARD FAIL | **No**; Python path uses `verilator_invoke.py` same class |
| `scripts/video_regression.sh` identity | No PLXC inject | **2** CORE_IDENTITY_UNVERIFIED | Fail-loud by design |
| `test_product_path_orphan.py` | cadence / present_cadence | **1** TIER1 | Intentional product-path RED |

PINNOTFOUND RBG (unit):

```
PINNOTFOUND_RBG_RED true rc=2
PINNOTFOUND_RBG_GREEN true rc=0
gate_false_green_guard true rc=0
```

**Bypass check:** direct `verilator` without wrapper was the old bypass — guarded by `verilator_invoke.py` + false_green_guard scanning bare verilator in unit scripts.

---

## T3 — sampling margin convention

Written: [`docs/SAMPLING_MARGIN.md`](../SAMPLING_MARGIN.md)

- Inadequate margin → **UNSCORED rc=77**, never pass/fail  
- DDR `min_hold_ms = 1000/refresh_hz` (1 vsync swap floor)  
- Reference: `tools/glass_template_skip.py` F4 + ERROR18/19 self-tests  

---

## T4 — deploy / rollback post-conditions

### `scripts/deploy_misterplexd.sh`

**Already had** live `/proc/PID/exe` md5 == host (exit 5 on mismatch), n_daemon==1, HTTP 200.

**Defect fixed this pass:**  
- Early `deploy_overall` **0** and final green before geometry  
- `core_conf_geometry` **rc=77** swallowed with `|| true` → overall still 0  

**Now:**

1. Remote success token = `DEPLOY_LIVE_VERIFY_OK` (binary post-condition)  
2. Geometry **77** → `verdict=DEPLOY_INCOMPLETE_GEOMETRY_UNSCORED` **`exit 78`**  
3. Geometry hard fail → non-zero exit  
4. Only then `verdict=DEPLOY_OK` + `deploy_overall` 0  

```
tests/unit/test_deploy_misterplexd.sh
  summary pass=29 fail=0
true rc=0
```

### `scripts/restore_misterplexd_prev.sh`

**Already HARD REFUSE** (B8): does not half-restore daemon; prints instructions for `rollback_v2.sh`;  

```
bash scripts/restore_misterplexd_prev.sh
true rc=10
```

Not silent no-op success. Coordinate with w-promote for pair rollback live-exe asserts inside `rollback_v2.sh`.

---

## T5 — stale `frames_done` comment

**Wrong (was):** `ddr_bank_release_select.hpp:13` claimed `frames_done` is `bank_vsync_count`.

**Truth (cited):**

- `input_mailbox.hpp:107` — `frames_done` = monotonic **swap** count  
- `ddr_frame_store.sv` — `frames_done++` only in swap block with `disp_bank` update; `vsync_toggle` on every vsync; separate `bank_vsync_count` for mailbox republish  
- PLXD pack comment: frames_done **MUST** be real swap counter, not bank_vsync_count  

**Fixed** header comment to match RTL.  

**Grep residual:** only RTL definitions of `bank_vsync_count` + the corrected comment remain; no other host claim that frames_done==vsync count.

---

## Wiring

Makefile `unit-unlocked` adds:

- `test_exit_code_collision_guard.py` (--self-test + full)  
- `tools/glass_template_skip.py --self-test` (when tools present)

Rollcall refreshed via `--write-expected`.
