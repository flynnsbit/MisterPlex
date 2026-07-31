# w-lint GATE INTEGRITY REPORT

- branch: `w-lint-gate-integrity`
- sha: `128735787041a7d664a1db05c94c5516cfa84aea`
- base: `w-fit-integ-c5382bee-dequant-swap` @ `a5d14f74`
- date: 2026-07-31
- scope: host/source only (no Quartus, no deploy, no ssh device ops)

## 0. BLOCKER — running bitstream identity (parent-verified class)

**Defect:** `verify_baseline` hashed on-disk RBF + live daemon. CORENAME/RBFNAME
content is always `Plex`. Mixed **SPI core + DDR daemon** (black/green screen)
passed non-visual checks. Same family as disk-only daemon hash (already fixed
by fix/gate-liveness) and deploy-rc-0-no-op.

### Device interfaces (honest)

| surface | identifies running RBF hash? | notes |
|---|---|---|
| `/tmp/CORENAME` | **NO** | always Plex |
| `/tmp/RBFNAME` content | **NO** | always Plex |
| `/tmp/RBFNAME` mtime | reload only | proves *a* load, not which file |
| on-disk `md5sum Plex*.rbf` | **NO** | file ≠ fabric |
| fpga_manager sysfs | unused on MiSTer Main path | observed empty in gate |
| USERCODE/CHIPID | not wired | |
| PLXK/PLXS/PLXD | family/liveness | not build id; residue can fake magic |
| HDMI pixels | visual only | parent-owned |

### Interim mitigation (landed this branch — no fit)

1. Claim file `/media/fat/misterplex/.running_core_claim` written **only after**
   RBFNAME mtime advances (`plexctl load_core`, `deploy_plex_core` load paths,
   `video_regression` bundle load).
2. Gate resolves running core from claim **iff** claim.rbfname_mtime == live
   RBFNAME mtime. Missing/stale/unknown → **rc=1 FAIL** (never skip).
3. `(core,daemon)` pair table: SPI `dfebf2bf…` + `{7cd10b4d,50f4eb92,3e2cbb98}`;
   DDR prefix `c5382bee` + `e9f79de2`. Mix → **FAIL pair-mismatch**.
4. Writers: `scripts/plexctl.sh`, `scripts/deploy_plex_core.sh`,
   `scripts/video_regression.sh` run_bundle.

### Red-before-green (host mutation, true rc direct)

`tests/unit/test_video_regression_liveness.sh` **true rc=0**:

| case | want | measured |
|---|---:|---|
| OLD disk-only + dead daemon | 0 (defect) | 0 |
| NEW + dead daemon | 1 | 1 |
| missing claim | 1 | 1 |
| stale claim mtime | 1 | 1 |
| SPI core + DDR daemon | 1 | 1 |
| DDR core + SPI daemon | 1 | 1 |
| coherent SPI hybrid | 0 | 0 |
| coherent DDR pair | 0 | 0 |
| HTTP dead / ETXTBSY / multi / timeout | 1 | 1 |
| respawn within wait | 0 | 0 |

### Durable PLXC (spec only — rides next fit; no slot requested)

- Offset doorbell+`0x130`, magic `0x504C5843`, build stamp in upper 32b
- Reserved in `host/libmisterplex/mailbox_abi_spec.hpp` (`kPlxcOffset/Addr/Magic`)
- Design: `docs/core-running-bitstream-identity.md`
- Until RTL publishes PLXC, claim remains mandatory

## 1. expected_commands collision

**Resolved.** Count DERIVED from Makefile:

| tip | EXPECTED_COMMANDS | sha16 |
|---|---:|---|
| this branch | **112** | `0f3c3b7132ab667a` |

`UNIT_ROLLCALL_MERGE_HINT` → `python3 tests/unit/test_unit_rollcall.py --write-expected`
**true rc=0**. Do not hand-edit the integer. Stale 97/99/101/102/107 branches
must re-derive on merge.

## 2. fix/gate-liveness

**CLOSE — already landed on integ tip** (`f746f10f`, `478e7dbf` ancestors).
Live `/proc/PID/exe` + HTTP; host mutation green. This commit extends the same
class to **core** identity (claim+pair).

## 3. PINNOTFOUND / never-ran

| check | true rc |
|---|---|
| `run_verilator.sh` bad.sv PINNOTFOUND | **2** |
| `test_gate_false_green_guard.py` | **0** |
| sdram_dq missing VL (fixed) | **3** / ALLOW **77** |

## 4. Soft-skip ≠ PASS

| case | true rc / GATE_RESULT |
|---|---|
| make-unit wrap, no PMS | rc=0 + `PASS_INCOMPLETE` critical_skips≥1 |
| core_conf unknown md5 | **77** `SKIP_NOT_PASS` |

Exit 77 and UNSCORED are never scored as pass. CRITICAL skips stay RED-not-PASS
in aggregates via `GATE_RESULT=`.

## 5. Pipe-rc trap

`tests/unit/test_pipe_rc_trap.py` scanned 116 scripts — **true rc=0**.
Fixed prior traps in mister_soft_bounce / test_f3_visual_golden.

## 6. Gate inventory snapshot

Protected unit-unlocked: **112** (see Makefile + rollcall). Full table in prior
report body / `test_unit_rollcall.py --list` if needed.

Host gates measured this session:

| gate | runs? | true rc | silent skip? |
|---|---|---:|---|
| test_unit_rollcall.py | yes | 0 | no |
| test_pipe_rc_trap.py | yes | 0 | no |
| test_gate_false_green_guard.py | yes | 0 | no |
| test_video_regression_liveness.sh | yes | 0 | no |
| video_regression verify (mocked) | yes | 0/1 per case | no — unknown→FAIL |
| run_verilator PINNOTFOUND | yes | 2 | no |
| core_conf_geometry unmapped | yes | 77 | SKIP-NOT-PASS (not pass) |
| live-pms-baseline-profile no key | wrap | PASS_INCOMPLETE | CRITICAL skip visible |
| test_rtl_invariants.py | yes | 1 pre-existing tip | `sendDdrFrame` bank select — not this lane |

## 7. Parent actions

1. Merge `w-lint-gate-integrity` into integ tip before promoting DDR pair.
2. After any load path, confirm claim file exists with matching RBFNAME mtime.
3. Ride PLXC RTL on next exclusive fit (w-fit); do not open a fit for identity alone.
4. Hardware red-green of mixed SPI/DDR remains parent (HDMI) — gate now refuses mix without pixels.
