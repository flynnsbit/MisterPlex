# Mutation gates (w-lint) — GREP IS NOT EVIDENCE

**Branch:** `w-lint-gate-integrity`  
**Model:** `tests/unit/test_soak_continuity_assert.sh` — inject defect, assert non-zero.

## Suite

`tests/unit/test_deploy_restore_mutations.sh` (wired into `make unit` / rollcall)

| Mutation | true rc | Notes |
|----------|--------:|-------|
| cov_empty (rc=0 + 0 notes) | 77 | coverage rule |
| cov_ok | 0 | notes present |
| pair_miss | 77 | artifact pair missing |
| pair_ok | 0 | stamp printed |
| restore_r1..r6 (no PAIR_ID) | 10 | hard refuse half-restore |
| pc_green | 0 | postconditions healthy |
| **pc_r3** installed≠PREV | **5** | discarded-md5 class |
| **pc_r5** DECODE 240 vs expect 480 | **8** | broken-picture class |
| pc_r1 missing PREV | 4 | |
| pc_r2 empty PREV | 4 | |
| pc_r4 HTTP bad | 7 | |
| pc_r6 started_after=0 | 3 | |
| pc_dead n_daemon=0 | 3 | |
| deploy_green | 0 | fake transport |
| **deploy_dead** n=0 | **1** | parent-proven class |
| deploy_http | 1 | |
| deploy_diskonly live≠host | 1 | ETXTBSY class |
| overlay_blank bright | 1 | no invented PAUSED |
| defpar_t7 strip | 1 | define-parity T7 |
| soak continuity harness | 0 | red/green internal |

**Suite true rc=0** (FAIL=0 FINDINGS=0). Captured with `cmd; echo "true rc=$?"` style (direct `$?`, never through a pipe).

## Overlay blank-panel fix

`tools/readback_overlay_text.py` `separation_score`:
- `sep < 0.08` → score 0 (brightness alone cannot manufacture PASS)
- recovered requires `score>=0.40` **and** resolved font

Blank bright 640×480 panel: `score=0.0000 recovered=<empty> true rc=1`  
`--selftest-pair`: `true rc=0` (GREEN recovers STOPPED).

## Fleet libs

- `scripts/lib/gate_coverage.inc.sh` — empty inspection → UNSCORED 77
- `scripts/lib/artifact_pair.inc.sh` — missing pair → 77 (set -u safe)
- `scripts/restore_postconditions.sh` — host temp-root R1–R6

Docs: `docs/GATE_COVERAGE_RULE.md`, `docs/ARTIFACT_PAIR_MANIFEST.md`

## Open FINDING (not on this tree)

Parent: `#error` guard vs C++ `constexpr` is inert (`#if defined()` cannot see constexpr).  
On this worktree: **no `av_phase_rtl_quanta.hpp` / no such `#error` block found** (search). Merge risk lives on `w-avsync-hdmi-measure` — do not invent a guard here without the symbol. See `docs/evidence/w_lint_FALSE_GREEN_HUNT.md`.

## Host-only

No device SSH, no Quartus. Conf files are user-owned state — mutations use temp roots under `build/`.
