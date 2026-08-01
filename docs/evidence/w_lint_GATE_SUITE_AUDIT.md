# w-lint — gate suite audit (blind-green / blind-red / rc=77 laundering)

**Branch tip at write:** see git log `w-lint-gate-integrity`  
**Rule 0:** classifications below cite code paths and unit-captured true rc.  
**No device SSH this lane.**

---

## DEFECT 1 — running bitstream identity (`scripts/video_regression.sh`)

### Claim (parent)
Disk md5 + CORENAME=Plex always → DDR daemon + SPI core (black screen) can pass GREEN.

### Measured on this branch (host unit fixtures, direct true rc)

| Scenario | GATE_RESULT | true rc | Evidence |
|----------|-------------|---------|----------|
| SPI claim + DDR daemon live | `FAIL` | **1** | `test_video_regression_liveness` mixed-spi-core-ddr-daemon |
| DDR claim + SPI daemon live | `FAIL` | **1** | mixed-ddr-core-spi-daemon |
| Coherent SPI pair, no PLXC | `CORE_IDENTITY_UNVERIFIED` | **2** | new-live |
| Coherent + `VIDREG_CORE_ID=ddr` inject | `FULL_PASS` | **0** | coreid-ddr-ok |
| Empty disk hash (dropped probe class) | `NO_DATA` | **4** | nodata-disk |

Command:
```bash
bash tests/unit/test_video_regression_liveness.sh; echo "true rc=$?"
# parent device:
bash scripts/video_regression.sh verify; echo "true rc=$?"
# expect pre-PLXC: GATE_RESULT=CORE_IDENTITY_UNVERIFIED PROMOTE_OK=0 true rc=2
# expect mixed pair: GATE_RESULT=FAIL PROMOTE_OK=0 true rc=1
```

### Can software name the RUNNING rbf today?

| Signal | Identifies which rbf? | Cite |
|--------|----------------------|------|
| `/tmp/CORENAME`, `/tmp/RBFNAME` | **NO** — always `Plex` | `plexctl.sh` / conf |
| On-disk `md5sum Plex*.rbf` | **NO** — file ≠ fabric | verify_baseline |
| Claim + RBFNAME mtime | Reload event + last load path | interim only |
| PLXD `0x504C5844` / PLXS `0x504C5853` | **Family/liveness only** | `mailbox_abi_spec.hpp:91-106` |
| `plxa_used`, banks, `frames_done` | Handshake/liveness, **not** build id | `input_mailbox.hpp`, bank-select |
| Bank phys 320 vs 480 stride | Tier forensic, not unique rbf | layout exports |
| PLXC @ doorbell+0x130 | **Designed** build id | **not shipping** on c5382bee |
| HDMI fingerprint | Parent-only; md5 invalid both ways for content | AGENTS.md who-tests |

**Honest negative (success):** there is **no** software path today that returns the running bitstream content hash. Gate must not FULL_PASS without `VERIFIED_PLXC` (or future PLXC word). Intermediate `OK daemon-live` lines are step checks — scanners must use `GATE_RESULT=` / `PROMOTE_OK=` / `true rc=`.

`core_conf_geometry` rc=77 for unknown md5 remains correct — **not** deploy identity, **not** weakened.

---

## DEFECT 2 — blind-RED `set +e` glue into md5

### Parent symptom
`got=…81848set +e want=…81848` on v2-rollback-core.

### Fix (capture, not comparison) — already on this branch

| Mechanism | Path |
|-----------|------|
| `gate_join_remote_parts` forces `\n` between remote fragments | `promotion_gate_check.sh:156-169` |
| `gate_assert_md5_shape` rejects `*set *`, whitespace, non-32-hex | `:182-200` |
| RBG unit | `test_harness_capture_integrity.py` + `test_promotion_gates.sh` glue path |

```bash
python3 tests/unit/test_harness_capture_integrity.py; echo "true rc=$?"
bash tests/unit/test_promotion_gates.sh; echo "true rc=$?"
```

Contaminated capture → **FAIL shape** (rc≠0), never “trim to pass”. Green path still rc=0 with pure 32-hex.

---

## DEFECT 3 — suite classification (selected promote-critical)

| Gate / script | blind-green? | blind-red? | soft-skip note |
|---------------|--------------|------------|----------------|
| `video_regression.sh verify` | **Closed** for mixed (rc=1) and unproven fabric (rc=2) | NO-DATA→4 not mismatch | N/A |
| `promotion_gate_check.sh` | Pair + boot hook + motion; motion 77→hard fail | Shape FAIL on glue (correct) | motion UNSCORED≠pass |
| `core_conf_geometry` | No — unknown→77 not pass | N/A | **77 = could-not-map** (correct gap) |
| `run_with_skip_summary.py` | Critical skip → process_rc=**78** | N/A | 77 wrapped stays 77 |
| `run_verilator.sh` | PINNOTFOUND→rc=2 hard | missing verilator→77 only if allowed | compile-fail≠skip |
| `check_timing_margin` / STA build path | absent STA≠zero slack | N/A | 77 skip-not-pass |
| `pair_visual_gate.sh` | parent pixels | N/A | 77 unscored if no capture |
| `validate_playback_controls_hw.sh` | av_drift no longer pass | N/A | telemetry only |
| `deploy_misterplexd.sh` | dual-daemon stop path present; idempotence greps v1+v2 | N/A | geometry 77 not deploy success |
| `plexctl.sh load_core` | host `[ -f ]` false MISSING fixed → NOT_ON_DEVICE rc=4 | N/A | — |

### rc=77 taxonomy (repo still conflates — do not paper over)

| Kind | Meaning | Examples | Should become |
|------|---------|----------|---------------|
| **A COULD_NOT_MEASURE** | missing tool/input/key | Verilator absent, no BASELINE_KEY, unknown core md5 | keep **77** SKIP-NOT-PASS; CRITICAL→**78** aggregate |
| **B MEASURED_WITHHELD** | measured but absolute verdict withheld | some HW unscored | prefer distinct code or explicit `UNSCORED` token + never promote |
| **C INSTRUMENT_BROKEN** | scorer/instrument failed | w-instr `RC_INSTRUMENT_BROKEN=3` | **3** (already for motion green-cast class) — **not 77** |

**Live gap (A, CRITICAL):** `GATE_SKIP CRITICAL live-pms-baseline-profile` missing `MISTERPLEX_BASELINE_KEY` → `make unit` **process_rc=78**, not 0.

Sites inventory method: scan `exit 77` / `HW_RC_UNSCORED` — ~58 hits; majority A (tool/input); Verilator allow path A; HW_RC_UNSCORED default 77 is B-risk if used after a detected fail (w-instr fixed green-cast→2).

---

## expected_commands merge hazard

| Tree | protected command count |
|------|-------------------------|
| `w-lint-gate-integrity` | **125** (`test_unit_rollcall.py`) |
| `fix/gate-liveness` | **102** — **CLOSE, do not merge** |

Re-derive only: `python3 tests/unit/test_unit_rollcall.py --write-expected`

---

## Parent device commands (this lane does not run them)

```bash
# 1) Identity gate
bash scripts/video_regression.sh verify; echo "true rc=$?"
# expect: GATE_RESULT=CORE_IDENTITY_UNVERIFIED PROMOTE_OK=0 true rc=2  (pre-PLXC)
# mixed SPI core + DDR daemon: GATE_RESULT=FAIL true rc=1

# 2) Promotion capture shape (if promote dry-run)
PROMOTE_GATE_BLOB=/path/to/clean_blob bash scripts/promotion_gate_check.sh verify-live
# glued blob must FAIL shape, not soft-pass

# 3) Soft-skip critical visible
unset MISTERPLEX_BASELINE_KEY
make unit; echo "make_exit=$?"
# expect GATE_RESULT=PASS_INCOMPLETE process_rc=78 in log (make exit often 2)
```
