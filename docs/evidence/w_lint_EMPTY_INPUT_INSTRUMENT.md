# Empty/malformed input → number (instrument integrity)

**Branch:** `w-lint-gate-integrity`  
**Parent defects (2026-08-01, personally hit):**
1. `getconf CLK_TCK` empty (busybox rc=0) → `P=100*dt/(HZ*dwall)` with `HZ=""` → every process **0.0**
2. POSIX `$12` under `set --` is `$1`+`2` → wrong utime/stime when comm has spaces

## Mutation proof (`tests/unit/test_instrument_empty_input.sh`)

| ID | Mutation | true rc | Result |
|----|----------|--------:|--------|
| M1a | legacy awk empty HZ | awk_rc=2 / out empty | defect class reproduced |
| M1b | `cpu_pct_onecpu 50 1 ""` | **77** | UNSCORED (not 0.0) |
| M2 | zero HZ | **77** | refused |
| M3 | HZ=100 control | **0** pct=50.0 | green control |
| M4 | mock empty getconf | require_rc **0** after fix (HZ≈103 derived) or 77 | never empty denom |
| M5 | space-in-comm fake stat | after-) **111 222**; naive $14 **0 0** | silent wrong field |
| M6 | `set --` then `$12` | **422** ≠ 111 | parent defect reproduced |
| M7 | deploy unit (dead daemon) | **0** suite | dead path red inside |
| M8 | restore R5 geom 240≠480 | **8** | broken picture refused |
| M9 | define-parity T7 strip | **1** | not blind; green prints T7 block |
| M10 | bare `getconf\|\|echo 100` | gone | PASS |
| M11 | whole-line awk `$14` utime | gone | PASS |

**Suite true rc=0.**

## Fixes

| File | Change |
|------|--------|
| `scripts/lib/clk_tck.inc.sh` | resolve/require/cpu_pct; empty→77; derive via cpu0 |
| `scripts/lib/proc_stat.inc.sh` | utime/stime after last `)` |
| `scripts/profile_c2_present.sh` | empty CLK_TCK + after-) parse |
| `scripts/source_rate_rca.sh` | same |
| `scripts/validate_playback_controls_hw.sh` | same |
| `tests/hw/test_p480_ab_harness.sh` | same + HZ= parse first token |

## Priority gates (parent)

| Gate | Status | Evidence |
|------|--------|----------|
| deploy dead daemon | RED rc=1 in mutations | `test_deploy_restore_mutations` / `test_deploy_misterplexd` |
| restore R5 geometry | RED rc=8 | `restore_postconditions` + M8 |
| define-parity T7 | covers NATIVE_V_1TO1; strip rc=1 | M9 — **not** the old blind PASS |

Host-only. No device. Capture `true rc=$?` directly.
