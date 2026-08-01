# Parent three gate defects — mutation evidence

**Branch:** `w-lint-gate-integrity`  
**Host-only.** No device. `true rc` captured directly (never through a pipe).

## Meta suite

```bash
bash tests/unit/test_parent_three_gate_defects.sh; echo "true rc=$?"
```

**Measured:** `true rc=0` (FAIL=0).

---

## (1) `scripts/video_regression.sh` — running bitstream

**Limitation (stated in script + gate output):**
- `/tmp/CORENAME` / `/tmp/RBFNAME` are vacuous (always `Plex`).
- On-disk RBF md5 is **not** the fabric.
- PLXC @ doorbell+0x130 is the only designed content-hash identity; **not shipping** on c5382bee.
- Until VERIFIED_PLXC: **refuse FULL_PASS** → `GATE_RESULT=CORE_IDENTITY_UNVERIFIED` **true rc=2**, `PROMOTE_OK=0`.

**Authority used instead:**
1. `.running_core_claim` after verified load (RBFNAME mtime match)
2. (core,daemon) pair table — SPI/DDR must not mix
3. Optional parent inject `VIDREG_CORE_ID=absent|ddr|spi`

| Mutation | true rc | Marker |
|----------|--------:|--------|
| SPI core claim + DDR daemon | **1** | `FAIL pair-mismatch` / `SPI/DDR mix` |
| DDR core + SPI daemon | **1** | pair-mismatch |
| no claim | **1** | `cannot soft-skip unknown fabric` |
| pair OK but no PLXC | **2** | `CORE_IDENTITY_UNVERIFIED` / `REFUSE FULL_PASS` |
| dead daemon (old disk-only would pass) | **1** | n_daemon=0 FAIL |
| suite | **0** | `test_video_regression_liveness.sh` |

```bash
bash tests/unit/test_video_regression_liveness.sh; echo "true rc=$?"
```

---

## (2) deploy / restore false greens

### `scripts/deploy_misterplexd.sh`

| Mutation | true rc | Guarantees |
|----------|--------:|------------|
| dead daemon n=0 | **1** | not exit 0 |
| dual daemon n=2 | **1** / policy **3** | refuse two on :3005 |
| force v1 while live v2 | **1** / resolve **2** | live `/proc/exe` root |
| disk-only (live md5 ≠ host) | **1** / **5** | ETXTBSY class |
| green control | **0** | ships named artifact to live root |
| unit suite | **0** | `test_deploy_misterplexd.sh` pass=29 |

```bash
bash tests/unit/test_deploy_misterplexd.sh; echo "true rc=$?"
bash tests/unit/test_deploy_restore_mutations.sh; echo "true rc=$?"
```

### `scripts/restore_misterplexd_prev.sh`

| Mutation | true rc | Guarantees |
|----------|--------:|------------|
| any half-restore (no PAIR_ID) | **10** | REFUSE — does **not** restore Plex.rbf |
| R5 DECODE 240 vs expect 480 | **8** | `restore_postconditions.sh` broken picture |
| R3 installed ≠ PREV | **5** | discarded-md5 class |

```bash
env -u PAIR_ID bash scripts/restore_misterplexd_prev.sh; echo "true rc=$?"
# → true rc=10
```

Atomic restore: `PAIR_ID=… scripts/rollback_v2.sh restore` (core+daemon+conf).

---

## (3) COMPILE-FAIL / missing input ≠ PASS

| Gate / mutation | true rc | Notes |
|-----------------|--------:|-------|
| fake verilator prints PINNOTFOUND exits 0 | **2** | `run_verilator.sh` hard-fail |
| clean verilator control | **0** | |
| `test_gate_false_green_guard.py` | **0** | RBG both dirs; ALLOW_MISSING ≠ 0 |
| unknown core md5 geometry | **77** | SKIP-NOT-PASS (not PASS) |
| live-pms missing MISTERPLEX_BASELINE_KEY | **77** | SKIP-NOT-PASS |
| CRITICAL skip in wrapper | process **78** | `PASS_INCOMPLETE` — exit≠0 |
| soft-skip alone | **77** | never success |

```bash
# PINNOTFOUND even if tool exits 0:
VERILATOR=/path/to/fake_pinnotfound bash scripts/run_verilator.sh --version; echo "true rc=$?"
python3 tests/unit/test_gate_false_green_guard.py; echo "true rc=$?"
bash tests/unit/test_core_conf_geometry_gate.sh; echo "true rc=$?"
bash tests/unit/test_pms_baseline_gate.sh; echo "true rc=$?"
python3 scripts/run_with_skip_summary.py --self-test; echo "true rc=$?"
```

**Rule:** rc=77 / UNSCORED / PASS_INCOMPLETE are **never** success. Do not weaken to make green.

---

## Related empty-input class (same session)

`getconf CLK_TCK` empty → CPU 0.0; `set -- $12` wrong fields — fixed + mutated in  
`tests/unit/test_instrument_empty_input.sh` (commit `626133f4`).
