# w-lint PROMOTE BLOCKER REPORT

- branch: `w-lint-gate-integrity`
- HEAD: `408a166f68fb008e21addcd4e498887905f6fa41`
- date: 2026-07-31
- scope: host/static only

## Pins (never weakened)

| role | value |
|---|---|
| SPI core daily | `dfebf2bfd08dd70b473b587dd7e81848` |
| SPI daemon CURRENT | `50f4eb925de10e29172999a565c87684` |
| SPI daemon PREV hybrid | `3e2cbb9881b2f54b0e4cb60238655fa7` |
| SPI daemon base | `7cd10b4d438c714a9b8c4766dc982d59` |
| DDR core | `c5382bee73cecdee8220b811e529c297` (prefix `c5382bee`) |
| DDR daemon CURRENT | `edc3a46b` (prefix ≥8) |
| DDR daemon PREV | `e9f79de217982aff44207664fdb945c5` (device bak) |

## TASK 1 — running bitstream fail-closed

| control | status |
|---|---|
| claim + RBFNAME mtime | mandatory; missing/stale → rc=1 |
| pair table SPI↔DDR | mix → rc=1 |
| `GATE_CORE_IDENTITY=UNVERIFIED` | default loud stamp |
| `VIDREG_CORE_ID=absent\|ddr\|spi` | parent inject from live PLXC |
| `VIDREG_REQUIRE_CORE_ID=1` | RED if absent/missing (post identity RBF) |
| `RED_SPI_DAEMON_DDR_CORE` | SPI daemon + CAP_DDR fabric |
| PLXC ABI | doorbell+0x130, magic 0x504C5843; align w-fit `W_LINT_CONTRACT.md` |
| c5382bee | pre-identity; path=absent allowed until REQUIRE=1 |

Host RBG: `tests/unit/test_video_regression_liveness.sh` **true rc=0**
(includes coreid RED/GREEN/REQUIRE cases).

## TASK 2 — blind-and-green audit (class)

### Blind-and-green FIXED (this lane / ancestors)
| gate | disease | fix evidence |
|---|---|---|
| video_regression disk-only daemon | PASS with daemon DEAD | live `/proc/PID/exe` + HTTP; liveness unit |
| video_regression on-disk RBF | SPI+DDR mix green | claim+pair+PLXC inject |
| sdram_dq_turnaround verilator | exit 0 if VL missing | now rc=3 / ALLOW 77 |
| run_verilator PINNOTFOUND | could soft | HARD FAIL rc=2 (false_green_guard **rc=0**) |
| pipe `cmd\|tail; echo rc=$?` | false true rc=0 | test_pipe_rc_trap **rc=0** |

### Blind-but-honest (rc=77 / PASS_INCOMPLETE — NOT scored pass)
| gate | measured |
|---|---|
| live-pms-baseline-profile no key | GATE_RESULT=**PASS_INCOMPLETE** critical_skips=1 |
| core_conf_geometry unknown md5 | **rc=77** SKIP-NOT-PASS |
| core_conf_geometry absent log/decode | **rc=77** |

### Remaining WARN (parent HW; not unit-hard-fail)
| gate | issue |
|---|---|
| tests/hw/test_idle_screen_telemetry.sh | `pidof misterplexd` (prefer argv0+/proc/PID/exe) |
| tests/hw/test_f3_visual_golden.sh | CORENAME as identity without claim/PLXC |

### Genuinely measuring (host unit-unlocked sample)
Host C++/python units (cadence, resolve, mailbox, …), rollcall, pipe-rc,
false-green guard, video_regression liveness, core_conf_geometry mutation,
RTL sim wrappers that use `run_verilator.sh` / `lib_rtl_sim_gate.sh`.

Protected count: **113** (`derived_protected_sha256_16=eb770e5b9ffa849b`).

## TASK 3 — expected_commands

**Reconciled at HEAD:** `expected_commands=113` derived from Makefile.
Merge hint forces `--write-expected` (no hand-edit count).
Stale 99/101/103 on other branches will UNREGISTERED_COMMAND until re-derive.
`test_unit_rollcall.py` **true rc=0**.

## TASK 4 — soft skips → genuine COVERED

### live-pms-baseline-profile
**Why CRITICAL skip:** no `MISTERPLEX_BASELINE_KEY` (or `PLEX_KEY`) in env.
**To COVER (not weaken):**
1. Export `MISTERPLEX_BASELINE_KEY=/library/metadata/<N>` + `PLEX_BASE` + token for lab PMS.
2. Run `make pms-baseline-live` / wrap so `run_with_skip_summary` sees key present.
3. Gate then executes live PMS probe (profile_idc=66, CAVLC, ref=1, coded 624x480 class).
Until then aggregates must treat `PASS_INCOMPLETE` as incomplete — never full pass.

### core_conf_geometry
**Why 77:** unknown core md5 not in `assets/core_geometry_map.tsv`.
**To COVER:** map full 32-hex digests with DECODE tier evidence.
**Landed this commit (legitimate, not fudge):**
| md5 | geometry | evidence |
|---|---|---|
| `dfebf2bf…` | 320x240 | SPI daily; v2-video-baseline; FRAME_W=320 |
| `c5382bee73cecdee8220b811e529c297` | 320x240 | parent soak decode=320x240 into silicon 624 coded |
| `41adb98c…` | 320x240 | v0.3.0 (pre-existing) |

Mutation: `test_core_conf_geometry_gate.sh` **true rc=0** (map_spi/map_ddr PASS;
unknown still 77).

## Binding
- Did not modify `tools/score_i420_candidate.py`
- Soft-skip 77 / UNSCORED / PASS_INCOMPLETE never treated as full pass
- true rc captured directly in host tests
