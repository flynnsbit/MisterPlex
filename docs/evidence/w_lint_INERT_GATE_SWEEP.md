# w-lint inert-gate sweep — worst three (proven)

Branch: `w-lint-gate-integrity`. Rule 0: break stays green is the proof.

Parent pattern (already fixed on w-avsync `63b98803`): `#if defined(kParentClusterSepMsX100)`
cannot see a C++ `inline constexpr` — decorative anti-restore. **Not present on this tree**
(`av_phase_rtl_quanta` absent). This sweep found three more that *were* live here.

## #1 — `test_gate_false_green_guard.py` blind to Python (meta-inert)

**Blast:** the unit-unlocked false-green scanner itself.

**Why it could not fail:** `GLOBS` only matched `*.sh` and the auditor only looked for
`exit 0`, not Python `return 0`. Unit-unlocked Python RTL tests were invisible.

**Quoted (pre-fix):**
```python
GLOBS = (
    "*rtl_sim*.sh",
    "*verilator*.sh",
    ...
)
EXIT0 = re.compile(r"\bexit\s+0\b")
```

**RBG:**
| step | true rc |
|------|---------|
| inject `tests/unit/test_INERT_PROBE_verilator.py` with ALLOW→`return 0` | guard stayed **0** (inert) |
| after fix, same inject | guard **1** |
| remove inject | guard **0** |

**Fix:** scan `*verilator*.py` / `*dequant*.py`; treat `return 0` like `exit 0`; require
`verilator_invoke` for Python `--cc/--exe` builds.

## #2 — ALLOW_MISSING soft-skip laundered as PASS (`return 0`)

**Blast:** P3 intra MB0 / frame RTL behavioural gates in `make unit-unlocked`.

**Quoted (pre-fix) `tests/unit/test_p3_intra_mb0_verilator.py`:**
```python
        if os.environ.get("ALLOW_MISSING_VERILATOR", "0") != "1":
            ...
            return 3
        return 0   # soft-skip counted as success
```

**RBG (after fix):**
| env | true rc |
|-----|---------|
| `VERILATOR=/nonexistent ALLOW_MISSING_VERILATOR=1` | **77** SKIP-NOT-PASS |
| same, ALLOW=0 | **3** |
| real verilator | **0** |

Same contract on `test_p3_intra_frame_verilator.py`, `test_h264_intra_nb_ctx_verilator.py`,
`test_dequant_qp_sweep.py`.

## #3 — Direct verilator + PINNOTFOUND rc=0 + stale TB = GREEN

**Blast:** decoder RTL unit path (same class that burned Quartus fits via shell wrapper).

**Why it could not fail:** Python called the verilator binary directly and only checked
`proc.returncode`. A tool that prints `PINNOTFOUND` / `%Error` and exits 0 left a prior
`V*` TB in Mdir; the suite ran the stale binary and printed PASS.

**RBG (pre-helper pattern):**
| setup | true rc |
|-------|---------|
| fake verilator: PINNOTFOUND + exit 0; stale `Vprobe_tb` PASS | **0** |
| same fake via `scripts/run_verilator.sh` | **2** |

**RBG (after `tests/unit/verilator_invoke.py`):**
| setup | true rc |
|-------|---------|
| PINNOTFOUND + exit 0 + stale TB | **2** HARD FAIL |
| clean fake + exe present | **0** |

**Fix:** `run_verilator_build()` scans combined output for PINNOTFOUND/%Error/%Fatal and
exits 2 even when rc=0; requires TB path exists after claimed success. Wired into
unit-unlocked Python RTL builds.

## Tree clean

Probe files removed. `git status` shows only intentional source edits + helper.
No device touch. No Quartus.

## Not in top three (noted)

- Parent `#if defined(constexpr)` — fixed on w-avsync; N/A on this worktree file set.
- `deploy_misterplexd.sh` prints `DEPLOY_OK` / `deploy_overall 0` before geometry gate;
  geometry rc=77 is swallowed with `|| true` — follow-up, not RBG'd this pass.
