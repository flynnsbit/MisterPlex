# w-lint false-green systematic hunt

Lane: **w-lint-gate-integrity**. Rule 0: file:line or NOT-FOUND. Never weaken scoring tools.

## Blast radius

| B | Meaning |
|---|---------|
| 1 | Promotion / decoder contract / lab number locked as product truth |
| 2 | Gate can lie green, launder skip, or mis-label measurement |
| 3 | Stub lock / intentional freeze / medium |
| 4 | Acceptable RTL-literal self-pin or existing guard |

## Findings (ranked)

### B1 `CRITICAL_SOFT_SKIP` — `scripts/run_with_skip_summary.py:73-105+165-201`

live-pms-baseline-profile CRITICAL when MISTERPLEX_BASELINE_KEY/PLEX_KEY absent; make unit process_rc=78 PASS_INCOMPLETE (not 0). Exposure: PMS drift from FPGA decoder contract unenforced on host-only CI.

Evidence: `PASS_INCOMPLETE_RC=78; GATE_SKIP CRITICAL live-pms-baseline-profile`

### B1 `CRITICAL_SOFT_SKIP` — `tests/hw/test_pms_baseline_profile.sh:18-22`

SKIP-NOT-PASS exit 77 when PLEX_BASE/TOKEN/KEY missing. Correct refusal; must not launder to pass.

Evidence: `exit 77`

### B1 `PARENT_PATTERN_1` — `NOT-FOUND on w-lint worktree`

av_phase_rtl_quanta.hpp / kParentClusterSepMsX100=11710 absent here. Scrubbed on w-avsync-hdmi-measure@8a7df256 with #error guard + unit pin. Merge risk if older branch reintroduces without guard.

Evidence: `git show 8a7df256`

### B1 `PARENT_PATTERN_2` — `NOT-FOUND on w-lint worktree`

tools/avsync_session_latch.py absent here. On w-avsync self-test uses synthetic medians labeled NOT lab claims (not Q4 -293..).

Evidence: `8a7df256 latch _self_test`

### B2 `AV_DRIFT_AS_PASS` — `tests/unit/test_av_drift_not_lipsync_pass.py:13`

possible av-lock/drift still used near PASS language

Evidence: `This scanner flags scripts that still pass/fail gates on av_drift or av-lock.`

### B2 `AV_DRIFT_AS_PASS` — `tests/unit/test_av_drift_not_lipsync_pass.py:39`

possible av-lock/drift still used near PASS language

Evidence: `| av_drift_ms[^\n]{0,40}(?:pass|PASS|ok\b|OK\b)`

### B2 `AV_DRIFT_AS_PASS` — `tests/unit/test_av_drift_not_lipsync_pass.py:40`

possible av-lock/drift still used near PASS language

Evidence: `| clock=av-lock[^\n]{0,40}(?:pass|PASS)`

### B2 `IDENTITY_PARTIAL` — `scripts/video_regression.sh (GATE_CORE_IDENTITY/PROMOTE_OK)`

Refuses FULL_PASS without VERIFIED identity (rc=2). Cannot content-hash RUNNING RBF from software; PLXC fit-gated. Mixed pair rc=1. Blind-green blocked; promote blocked until PLXC or parent HDMI fingerprint.

Evidence: `GATE_RESULT=CORE_IDENTITY_UNVERIFIED PROMOTE_OK=0`

### B2 `RC77_TAXONOMY` — `aggregate n=61`

taxonomy counts={'A_could_not_measure': 55, 'B_measured_withheld': 5, 'C_should_be_3': 1}; rc=77 still conflates A could-not-measure vs B withheld (C should be 3)

Evidence: `scripts/check_arm_profile_asset.sh:14[A_could_not_measure]; scripts/check_arm_profile_asset.sh:23[A_could_not_measure]; scripts/check_arm_profile_asset.sh:27[A_could_not_measure]; scripts/check_arm_profile_asset.sh:31[A_could_not_measure]; `

### B2 `SOFT_SKIP_GAP` — `core_conf_geometry / assets/core_geometry_map.tsv`

SKIP-NOT-PASS rc=77 for unmapped core md5 — correct refusal; unknown cores have no geometry gate.

Evidence: `rc=77`

### B2 `UNOBSERVABLE_ABSENCE` — `tests/hw/test_idle_screen_telemetry.sh:166`

grep -c FAIL-ish then ==0 as pass — never-ran vs never-failed ambiguous

Evidence: `# grep -c: rc 0 = matches, rc 1 = zero matches (prints 0), rc 2 = error → NO_DATA.`

### B3 `HAS_SELF_TEST` — `tools/hdmi_motion_instrument.py:850`

self-test present — verify fixtures are synthetic not retracted lab

### B3 `SELF_PIN_CONST` — `tests/unit/test_input_mailbox.cpp:105`

kFrameStoreDebugFormatError==0 mirrors definition at host/libmisterplex/input_mailbox.hpp:29

Evidence: `constexpr uint8_t kFrameStoreDebugFormatError = 0xE1;`

### B3 `SELF_PIN_CONST` — `tests/unit/test_osd_menu.cpp:131`

kOsdIdleMask==0 mirrors definition at host/libmisterplex/osd_menu.hpp:76

Evidence: `constexpr uint16_t kOsdIdleMask = 0xC000;`

### B3 `SELF_PIN_CONST` — `tests/unit/test_osd_menu.cpp:83`

kOsdContentTierMask==0 mirrors definition at host/libmisterplex/osd_menu.hpp:79

Evidence: `constexpr uint16_t kOsdContentTierMask = 0x0030;`

### B3 `SELF_PIN_CONST` — `tests/unit/test_osd_menu.cpp:84`

kOsdOwnedMask==0 mirrors definition at host/libmisterplex/osd_menu.hpp:233

Evidence: `constexpr uint16_t kOsdOwnedMask = 0xC3FA;`

### B3 `STUB_LOCK` — `docs/evidence/w_lint_STUB_LOCK_INVENTORY.md`

Four intentional stub pins (adelay, ddrFrameFormatCode, kStubDcPaintY, geometry ignore decode WxH). Class (a).

Evidence: `inventory only`

### B4 `GUARD_PRESENT` — `tests/unit/test_absence_as_zero_static_guard.py`

static guard already on branch

### B4 `GUARD_PRESENT` — `tests/unit/test_av_drift_not_lipsync_pass.py`

static guard already on branch

### B4 `GUARD_PRESENT` — `tests/unit/test_gate_false_green_guard.py`

static guard already on branch

### B4 `GUARD_PRESENT` — `tests/unit/test_pipe_rc_trap.py`

static guard already on branch

### B2 `MAYBE_NO_RBG` — `n=3 unit shells`

shell unit tests with OK/PASS grep but no obvious red-before-green path (manual review)

Evidence: `tests/unit/test_ddr_frame_store_plxd_handshake.sh; tests/unit/test_ddr_frame_store_scanout_freeze.sh; tests/unit/test_ddr_frame_store_scanout_sustained.sh`

## CRITICAL `live-pms-baseline-profile` — enforce recipe

**Do not lower severity or convert to advisory.**

### What it guards

Delivered PMS SPS must match FPGA Baseline decoder contract:
`profile_idc=66`, CAVLC, `ref=1`, no B-slices, coded **624×480** / display **618×480**
(see GATE_SKIP would_catch text in `run_with_skip_summary.py`).

### How to enforce (pick one)

1. **Live PMS** — `make pms-baseline-live` or `scripts/run_pms_baseline_live_gate.sh`
   - Export `PLEX_BASE=http://<pms-host>:32400`
   - Export `MISTERPLEX_BASELINE_KEY=/library/metadata/<id>` (or `PLEX_KEY`)
   - Provide `PLEX_TOKEN` (live script prompts hidden; hw test accepts env)
   - Needs: `curl`, `ffmpeg`, `build/pms_baseline_probe`
2. **Offline Annex-B** (no token / no network PMS):
   ```bash
   MISTERPLEX_BASELINE_ANNEXB=/path/to/baseline.264 \
     scripts/run_pms_baseline_live_gate.sh
   # expect: true rc=0 when stream matches contract; non-zero on drift
   ```
3. **make unit** with key present in env → inventory does not emit CRITICAL skip;
   live/offline probe still must be run separately unless wired into unit-unlocked
   (currently **not** auto-run without credentials — by design).

### What `make unit` does without the key

- Emits `GATE_SKIP CRITICAL live-pms-baseline-profile`
- Ends `GATE_RESULT=PASS_INCOMPLETE process_rc=78` when wrapped suite is otherwise 0
- **rc=78 is not success.** CI must not treat 78 as green.
- `make unit-unlocked` stays rc=0 and **does not claim** PMS coverage — label clearly.

### Exposure while unenforced

PMS (or a mis-tagged library item) can drift to CABAC / B-frames / multi-ref / wrong
coded size. Host tests and pair pins will not catch it. This is the same contract
family as the user-visible 480p frame-drop / decoder mismatch class. **Residual risk
is production decode contract, not cosmetics.**

## Parent patterns (1)(2)(3) on this worktree

| # | Pattern | w-lint tree |
|---|---------|-------------|
| 1 | Self-asserting 117.10 cluster const | **NOT-FOUND** (no `av_phase_rtl_quanta.hpp`). Fixed on `w-avsync-hdmi-measure` `8a7df256` with `#error` if symbol returns. |
| 2 | Poisoned latch self-test fixture | **NOT-FOUND** (`avsync_session_latch.py` absent). Scrubbed on w-avsync to synthetic caller-supplied numbers. |
| 3 | Unobservable / wrong-window test | See `UNOBSERVABLE_ABSENCE` / `MAYBE_NO_RBG`; pause-overlay class needs positive ran signal + RBG pair. |

## Self-pin inventory (CHECK mirrors header constexpr)

Count: **4** (B3/B4 — none classified B1 measurement-shaped on this tree).

- `tests/unit/test_input_mailbox.cpp:105` `kFrameStoreDebugFormatError==0` ↔ `host/libmisterplex/input_mailbox.hpp:29`
- `tests/unit/test_osd_menu.cpp:83` `kOsdContentTierMask==0` ↔ `host/libmisterplex/osd_menu.hpp:79`
- `tests/unit/test_osd_menu.cpp:84` `kOsdOwnedMask==0` ↔ `host/libmisterplex/osd_menu.hpp:233`
- `tests/unit/test_osd_menu.cpp:131` `kOsdIdleMask==0` ↔ `host/libmisterplex/osd_menu.hpp:76`

## rc=77 site sample

Total exit/return 77 sites scanned: **61** — {'A_could_not_measure': 55, 'B_measured_withheld': 5, 'C_should_be_3': 1}

- `scripts/check_arm_profile_asset.sh:14` [A_could_not_measure] `exit 77`
- `scripts/check_arm_profile_asset.sh:23` [A_could_not_measure] `exit 77`
- `scripts/check_arm_profile_asset.sh:27` [A_could_not_measure] `exit 77`
- `scripts/check_arm_profile_asset.sh:31` [A_could_not_measure] `exit 77`
- `scripts/run_pms_baseline_live_gate.sh:80` [A_could_not_measure] `exit 77`
- `scripts/run_pms_baseline_live_gate.sh:84` [A_could_not_measure] `exit 77`
- `scripts/run_pms_baseline_live_gate.sh:94` [A_could_not_measure] `exit 77`
- `scripts/run_with_skip_summary.py:180` [A_could_not_measure] `f"process_rc=77 (exit 77 is not success; soft-skip≠PASS)"`
- `scripts/run_with_skip_summary.py:199` [A_could_not_measure] `return 77`
- `scripts/pair_visual_gate.sh:64` [A_could_not_measure] `exit 77`
- `tests/hw/avsync_measure.py:336` [B_measured_withheld] `sys.exit(77)`
- `tests/hw/avsync_rate.py:160` [B_measured_withheld] `sys.exit(77)`
- `tests/hw/test_bank_release_visual.sh:29` [B_measured_withheld] `RC_UNSCORED=77`
- `tests/hw/test_idle_screen_telemetry.sh:22` [B_measured_withheld] `RC_UNSCORED=77`
- `tests/hw/test_pms_baseline_profile.sh:22` [A_could_not_measure] `exit 77`
- `tests/hw/test_pms_baseline_profile.sh:26` [A_could_not_measure] `exit 77`
- `tests/hw/test_pms_nal_stats.sh:22` [A_could_not_measure] `exit 77`
- `tests/hw/test_pms_nal_stats.sh:26` [A_could_not_measure] `exit 77`
- `tests/unit/lib_rtl_sim_gate.sh:7` [A_could_not_measure] `#   - Only with ALLOW_MISSING_VERILATOR=1: exit 77 + SKIP-NOT-PASS line.`
- `tests/unit/lib_rtl_sim_gate.sh:28` [A_could_not_measure] `echo "SKIP RTL SIM: ALLOW_MISSING_VERILATOR=1 accepted; this is NOT a pass (exit 77)." >&2`
- `tests/unit/lib_rtl_sim_gate.sh:29` [A_could_not_measure] `exit 77`
- `tests/unit/test_ddr_frame_store_plxd_handshake.sh:34` [A_could_not_measure] `exit 77`
- `tests/unit/test_ddr_frame_store_scanout_colour.sh:35` [A_could_not_measure] `exit 77`
- `tests/unit/test_ddr_frame_store_scanout_freeze.sh:33` [A_could_not_measure] `exit 77`
- `tests/unit/test_ddr_frame_store_scanout_shear.sh:31` [A_could_not_measure] `exit 77`
- `tests/unit/test_ddr_frame_store_scanout_sustained.sh:34` [A_could_not_measure] `exit 77`
- `tests/unit/test_ddr_frame_store_warm_reset.sh:13` [A_could_not_measure] `exit 77`
- `tests/unit/test_ddram_frame_rd_bank_select.sh:20` [A_could_not_measure] `exit 77`
- `tests/unit/test_gate_false_green_guard.py:33` [A_could_not_measure] `# 1) After "Verilator not found", an exit 0 without exit 77 nearby is banned.`
- `tests/unit/test_gate_false_green_guard.py:84` [A_could_not_measure] `f"(must exit 77 SKIP-NOT-PASS; soft-skip≠PASS)"`
- `tests/unit/test_gate_false_green_guard.py:88` [A_could_not_measure] `f"{rel}:{i+1}: 'Verilator not found' followed by exit 0 without exit 77 "`
- `tests/unit/test_gate_false_green_guard.py:93` [A_could_not_measure] `f"{rel}:{i+1}: ALLOW_MISSING_VERILATOR exit 77 without SKIP-NOT-PASS marker "`
- `tests/unit/test_gate_false_green_guard.py:176` [A_could_not_measure] `for needle in ("exit 77", "SKIP-NOT-PASS", "assert_sim_executed", "ALLOW_MISSING_VERILATOR"):`
- `tests/unit/test_h264_baseline_syntax_rtl_sim.sh:15` [A_could_not_measure] `exit 77`
- `tests/unit/test_h264_cavlc_residual_verilator.sh:25` [A_could_not_measure] `exit 77`
- `tests/unit/test_h264_decode_core_p16z_rtl_sim.sh:18` [A_could_not_measure] `exit 77`
- `tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh:18` [A_could_not_measure] `exit 77`
- `tests/unit/test_h264_decode_core_writeback_rtl_sim.sh:19` [A_could_not_measure] `exit 77`
- `tests/unit/test_h264_inter_nb_mvd_rtl_sim.sh:21` [A_could_not_measure] `exit 77`
- `tests/unit/test_h264_multinal_stream_path.sh:19` [A_could_not_measure] `exit 77`

## Recommended next fixes (do not weaken)

1. Keep CRITICAL PMS at 78; wire CI to fail on process_rc∈{1,2,78} for full gate;
   publish offline ANNEXB path in release checklist.
2. When merging `w-avsync-hdmi-measure`, require `#error` guard for `kParentClusterSepMsX100`
   and synthetic-only latch self-test (already on that branch).
3. Add unit static scan for lab-number reintroduction (`11710`, Q4 medians in self_test).
4. For each MAYBE_NO_RBG shell, add intentional red inject or document why pure static.
5. Identity: promote stays blocked at `PROMOTE_OK=0` until PLXC fit or parent HDMI fingerprint — correct.

---

## Verification (host, direct rc — never through a pipe)

### New guard `tests/unit/test_false_green_pattern_guard.py`

| Case | Command | true rc |
|------|---------|---------|
| clean tree | `python3 tests/unit/test_false_green_pattern_guard.py` | **0** `FALSE_GREEN_PATTERN_OK` |
| inject `kParentClusterSepMsX100=11710` | same after writing probe header | **1** `POISONED_CONST` |
| remove probe | same | **0** |

### Rollcall after wiring into `unit-unlocked`

```
UNIT_ROLLCALL_OK ... expected_commands=126 protected_sha256_16=67395583620c7487
true rc=0
```

### CRITICAL PMS (already on branch)

Without `MISTERPLEX_BASELINE_KEY`: `make unit` → `GATE_RESULT=PASS_INCOMPLETE process_rc=78` (not success).
`make unit-unlocked` does not claim PMS coverage.

### Corrections to automated first-pass heuristics

| Heuristic hit | Resolution |
|---------------|------------|
| `test_av_drift_not_lipsync_pass.py` AV_DRIFT_AS_PASS | **False positive** — that file is the ban scanner, not a soak criterion. |
| `test_idle_screen_telemetry.sh` grep -c fail | **Not unobservable** — uses paint OK *and* FAIL counts; silent path (`ok=0 fail=0`) is hard fail for PRESENT=fpga\|both (lines 183–191). |
| three ddr_frame_store_*.sh MAYBE_NO_RBG | **False positive** — each has broken REPRO + good PASS with `assert_sim_executed` (RBG present). |

### Parent patterns (1)(2) on other branches

- **(1)(2) fixed on `w-avsync-hdmi-measure` @ `8a7df256`** (not yet on main/`w-lint` merge base).
- This branch adds the **reintroduction tripwire** so a merge cannot silently restore 11710 or Q4 goldens without `make unit` going RED.

### Identity promote block (standing)

`scripts/video_regression.sh`: mixed pair `rc=1` `PROMOTE_OK=0`; coherent+no PLXC `rc=2` `CORE_IDENTITY_UNVERIFIED`; only VERIFIED_PLXC/`VIDREG` inject → `FULL_PASS`. No software RUNNING-RBF content hash on c5382bee.

