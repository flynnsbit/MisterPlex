# w-lint GATE INTEGRITY REPORT

- branch: `w-lint-gate-integrity`
- sha: `a5d14f74330c01e28758a9544624f36b2a8adc87`
- base: `w-fit-integ-c5382bee-dequant-swap` @ `a5d14f74`
- date: 2026-07-31
- scope: host/source only (no Quartus, no deploy, no ssh device ops)

## 1. expected_commands collision

**Resolved on this branch.** Count is DERIVED from Makefile reality, not invented.

| branch / tip | EXPECTED_COMMANDS | notes |
|---|---:|---|
| w-lint-gate-integrity (this) | **112** | + `test_pipe_rc_trap.py`; `derived_protected_sha256_16=0f3c3b7132ab667a` |
| w-fit-integ-c5382bee-dequant-swap a5d14f74 | 111 | pre-lint tip |
| fix/gate-liveness 478e7dbf | 102 | historical; already ancestor of tip |
| integ/fit5-prep | 97 | stale side branch |

Failure mode when sets disagree (measured red-before-green):
```
UNIT_ROLLCALL_FAIL
UNREGISTERED_COMMAND …
UNIT_ROLLCALL_MERGE_HINT
  python3 tests/unit/test_unit_rollcall.py --write-expected
```
`true rc=1` on stale list; `true rc=0` after restore. **Do not hand-edit a count integer.**

## 2. fix/gate-liveness

**CLOSE — already landed on integ tip.**

- `f746f10f` (live `/proc/PID/exe` + HTTP liveness) **is ancestor of HEAD**
- `478e7dbf` (land liveness count; drop broken scanout ghost) **is ancestor of HEAD**
- Host mutation gate `tests/unit/test_video_regression_liveness.sh` **true rc=0** (red-before-green both directions; n_daemon=0 fails)
- `scripts/video_regression.sh` quotes ETXTBSY + disk≠live FAIL path (lines ~352–356)
- Coordinate note: `.worktrees/rollback-honest` has **uncommitted** further edits to `video_regression.sh` (SSH retry + NO-DATA empty-hash). Complementary, not a liveness regression. w-fit should merge those separately; do not thrash liveness.

## 3. PINNOTFOUND / never-ran false green

| check | evidence |
|---|---|
| `scripts/run_verilator.sh` HARD FAIL | synthetic bad.sv → **true rc=2**, log contains `HARD FAIL — … PINNOTFOUND/%Error` |
| `test_gate_false_green_guard.py` | **true rc=0**, scans 32 RTL sim scripts; requires PINNOTFOUND+exit 2 in runner |
| `lib_rtl_sim_gate.sh` | missing VL → exit 3 default / 77 only with ALLOW+SKIP-NOT-PASS |
| **FIXED** `test_sdram_dq_turnaround_verilator.sh` | was **exit 0** on missing runner (probed true rc=0). Now refuse **rc=3** / ALLOW **rc=77** SKIP-NOT-PASS |
| `test_sdram_startup_verilator.sh` | aligned to same contract; bare verilator/oss-cad fallback removed |

## 4. Soft-skip ≠ PASS

| case | measured |
|---|---|
| `run_with_skip_summary --label make-unit -- true` (no PMS key) | **true rc=0** but `GATE_RESULT=PASS_INCOMPLETE critical_skips=1` for `live-pms-baseline-profile` |
| wrap exit 77 + SKIP-NOT-PASS core_conf | **true rc=77** + `GATE_RESULT=SKIP_NOT_PASS` |
| `check_core_conf_geometry` unmapped/missing log | **true rc=77** `SKIP-NOT-PASS` |
| unit mutation `test_core_conf_geometry_gate.sh` | **true rc=0** (asserts unknown→77) |

Aggregates MUST key off `GATE_RESULT=`, never treat rc==0 alone as full coverage when CRITICAL skips exist. Exit 77 is never success.

## 5. Pipe-rc trap lint

- New: `tests/unit/test_pipe_rc_trap.py` (registered in unit-unlocked)
- Scanned 116 shell scripts; **true rc=0** after fixing:
  - `scripts/mister_soft_bounce.sh` read_corename: ssh rc captured directly, CR strip offline
  - `tests/hw/test_f3_visual_golden.sh`: `rc=${PIPESTATUS[0]}` after `python\|tee`

## 6. Gate inventory (unit-unlocked protected set)

Derived protected count: **112**. Ignored helpers: 3.

| # | command | class | host-run notes |
|---:|---|---|---|
| 1 | `build/test_cadence` | unit | registered; runs under make unit |
| 2 | `build/test_avclock` | unit | registered; runs under make unit |
| 3 | `build/test_mraudio_status` | unit | registered; runs under make unit |
| 4 | `build/test_osd_menu` | unit | registered; runs under make unit |
| 5 | `build/test_osd_control` | unit | registered; runs under make unit |
| 6 | `tests/unit/test_osd_menu_red.sh` | unit | registered; runs under make unit |
| 7 | `tests/unit/test_present_default_fpga.sh` | unit | registered; runs under make unit |
| 8 | `build/test_last_frame_latch` | unit | registered; runs under make unit |
| 9 | `tests/unit/test_last_frame_latch_red.sh` | unit | registered; runs under make unit |
| 10 | `build/test_playback_overlay` | unit | registered; runs under make unit |
| 11 | `build/test_input_mailbox` | unit | registered; runs under make unit |
| 12 | `build/test_pixel_format` | unit | registered; runs under make unit |
| 13 | `build/test_main_guard` | unit | registered; runs under make unit |
| 14 | `build/test_status_telemetry` | unit | registered; runs under make unit |
| 15 | `build/test_resolve` | unit | registered; runs under make unit |
| 16 | `build/test_log_redact` | unit | registered; runs under make unit |
| 17 | `tests/unit/test_log_redact_red.sh` | unit | registered; runs under make unit |
| 18 | `build/test_pms_timeline` | unit | registered; runs under make unit |
| 19 | `build/test_plextv_device` | unit | registered; runs under make unit |
| 20 | `build/test_companion_eof` | unit | registered; runs under make unit |
| 21 | `build/test_companion_plant_seek` | unit | registered; runs under make unit |
| 22 | `build/test_gdm_resources_parity` | unit | registered; runs under make unit |
| 23 | `tests/unit/test_gdm_storm_ports_static.sh` | unit | registered; runs under make unit |
| 24 | `tests/unit/test_pms_baseline_gate.sh` | gate-meta | registered; runs under make unit |
| 25 | `tests/unit/test_pms_baseline_live_gate.sh` | gate-meta | registered; runs under make unit |
| 26 | `build/test_h264_bitstream_source` | unit | registered; runs under make unit |
| 27 | `build/test_bitstream_ring_lifecycle` | unit | registered; runs under make unit |
| 28 | `build/test_frame_store_math` | unit | registered; runs under make unit |
| 29 | `build/test_coded_size_adopt` | unit | registered; runs under make unit |
| 30 | `build/test_ffmpeg_vf` | unit | registered; runs under make unit |
| 31 | `tests/unit/test_geometry_type_safety.sh` | unit | registered; runs under make unit |
| 32 | `build/test_frame_store_sdram_sim` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 33 | `build/test_frame_store_ddr_prefetch_sim` | unit | registered; runs under make unit |
| 34 | `build/test_ddr_want_y_hblank_thrash` | unit | registered; runs under make unit |
| 35 | `build/test_ddr_bank_mailbox_phys` | unit | registered; runs under make unit |
| 36 | `build/test_ddr_scanout_multiframe` | unit | registered; runs under make unit |
| 37 | `build/test_sdram_memtest_sim` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 38 | `build/test_sdram_mailbox` | unit | registered; runs under make unit |
| 39 | `build/test_annexb_count` | unit | registered; runs under make unit |
| 40 | `tests/unit/test_ddr_publish_path_static.py` | unit | registered; runs under make unit |
| 41 | `build/test_status_telemetry $(UNIT_ANNEXB)` | unit | registered; runs under make unit |
| 42 | `build/test_sps_parse $(UNIT_ANNEXB)` | unit | registered; runs under make unit |
| 43 | `build/test_slice_hdr $(UNIT_ANNEXB)` | unit | registered; runs under make unit |
| 44 | `build/test_cavlc_dc $(UNIT_ANNEXB)` | unit | registered; runs under make unit |
| 45 | `build/test_idct_quant $(UNIT_ANNEXB)` | unit | registered; runs under make unit |
| 46 | `build/test_p3_host_recon_vectors` | unit | registered; runs under make unit |
| 47 | `tests/unit/test_h264_golden_extractor.sh` | unit | registered; runs under make unit |
| 48 | `tests/unit/test_h264_frame_plane_goldens.sh` | unit | registered; runs under make unit |
| 49 | `tests/unit/test_derived_validation_hashes.sh` | unit | registered; runs under make unit |
| 50 | `tests/unit/test_deblock_iframe_gap.sh` | unit | registered; runs under make unit |
| 51 | `tests/unit/test_i420_candidate_score.sh` | unit | registered; runs under make unit |
| 52 | `tests/unit/test_p3_hybrid_gate.sh` | unit | registered; runs under make unit |
| 53 | `tests/unit/test_h264_multinal_stream_path.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 54 | `build/test_p3_idct_reference_model` | unit | registered; runs under make unit |
| 55 | `build/test_p3_inter_pred_vectors` | unit | registered; runs under make unit |
| 56 | `tests/unit/test_no_conflict_markers.py` | unit | registered; runs under make unit |
| 57 | `tests/unit/test_bench_rtl_filelists.py` | unit | registered; runs under make unit |
| 58 | `tests/unit/test_p3_high_cabac_scope.py` | unit | registered; runs under make unit |
| 59 | `tests/unit/test_p3_intra_mb0_verilator.py` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 60 | `tests/unit/test_h264_intra_nb_ctx_verilator.py` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 61 | `tests/unit/test_p3_idct_rtl_model.py` | unit | registered; runs under make unit |
| 62 | `tests/unit/test_p3_intra_frame_verilator.py` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 63 | `tests/unit/test_p3_inter_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 64 | `tests/unit/test_p3_dpb_mc_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 65 | `tests/unit/test_h264_decode_core_writeback_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 66 | `tests/unit/test_h264_decode_core_p16z_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 67 | `tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 68 | `tests/unit/test_h264_p_slice_modes_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 69 | `tests/unit/test_p3_inter_stream_path_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 70 | `tests/unit/test_companion_http.sh` | unit | registered; runs under make unit |
| 71 | `tests/unit/test_plex_browse.sh` | unit | registered; runs under make unit |
| 72 | `tests/unit/test_play_file_delivery.sh` | unit | registered; runs under make unit |
| 73 | `tests/unit/test_no_private_data.sh` | unit | registered; runs under make unit |
| 74 | `tests/unit/test_gate_false_green_guard.py` | static-lint | registered; runs under make unit |
| 75 | `tests/unit/test_capture_rig.sh` | unit | registered; runs under make unit |
| 76 | `tests/unit/test_resource_preflight.sh` | unit | registered; runs under make unit |
| 77 | `tests/unit/test_mister_soft_bounce_lock.sh` | unit | registered; runs under make unit |
| 78 | `scripts/check_define_parity.py` | static-lint | registered; runs under make unit |
| 79 | `tests/unit/test_hw_visual_compare.py` | unit | registered; runs under make unit |
| 80 | `tests/unit/test_decode_throughput_gate.sh` | unit | registered; runs under make unit |
| 81 | `tests/unit/test_rtl_invariants.sh` | unit | registered; runs under make unit |
| 82 | `tests/unit/test_mister_ini_plex_guard.sh` | unit | registered; runs under make unit |
| 83 | `tests/unit/test_confstr_guard.sh` | unit | registered; runs under make unit |
| 84 | `tests/unit/test_core_conf_geometry_gate.sh` | gate-meta | registered; runs under make unit |
| 85 | `tests/unit/test_video_regression_liveness.sh` | gate-meta | registered; runs under make unit |
| 86 | `tests/unit/test_pipe_rc_trap.py` | static-lint | registered; runs under make unit |
| 87 | `tests/unit/test_timing_margin_gate.sh` | unit | registered; runs under make unit |
| 88 | `tests/unit/test_release_rbf_hash.sh` | unit | registered; runs under make unit |
| 89 | `tests/unit/test_sdram_startup_verilator.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 90 | `tests/unit/test_sdram_dq_turnaround_verilator.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 91 | `tests/unit/test_h264_cavlc_residual_verilator.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 92 | `tests/unit/test_level_width_verilator.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 93 | `tests/unit/test_stream_path_recon_integration.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 94 | `tests/unit/test_stream_path_full_frame_compare.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 95 | `tests/unit/test_ddram_frame_rd_bank_select.sh` | unit | registered; runs under make unit |
| 96 | `tests/parse_res_csum_status.py --self-test` | unit | registered; runs under make unit |
| 97 | `tests/unit/test_p3_idct_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 98 | `tests/unit/test_p3_deblock_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 99 | `tests/unit/test_p3_stream_path_recon_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 100 | `tests/unit/test_stream_path_deblock_integration.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 101 | `tests/unit/test_stream_path_ddr_ring_integration.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 102 | `tests/unit/test_ddr_frame_store_warm_reset.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 103 | `tests/unit/test_ddr_frame_store_scanout_shear.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 104 | `tests/unit/test_ddr_frame_store_scanout_freeze.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 105 | `tests/unit/test_ddr_frame_store_scanout_sustained.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 106 | `tests/unit/test_ddr_frame_store_plxd_handshake.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 107 | `tests/unit/test_ddr_frame_store_scanout_colour.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 108 | `scripts/rtl_lint.py` | static-lint | registered; runs under make unit |
| 109 | `tests/unit/test_h264_syntax_primitives_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 110 | `tests/unit/test_h264_sps_geometry_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 111 | `tests/unit/test_h264_baseline_syntax_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |
| 112 | `tests/unit/test_h264_inter_nb_mvd_rtl_sim.sh` | rtl-sim | must execute TB; missing VL → 3/77 not 0; PINNOTFOUND→2 via run_verilator |

## 7. Other makefile gates (not all in unit-unlocked)

| target | runs on host? | measured/notes | silent-skip risk |
|---|---|---|---|
| `make unit` / unit-rollcall | yes | rollcall **rc=0** count=112 | low after MERGE_HINT |
| `define-parity` | yes | **rc=0** | none |
| `quartus-sv-subset` | yes (static) | not re-run this lane | refuse≠pass when no Quartus |
| `verilator-elab` | yes if VL | not timed this lane | missing VL must refuse |
| `rtl-lint` | yes | not timed this lane | — |
| `post-fit-hierarchy` | needs FIT_RPT | N/A host | refuse missing report |
| `post-fit-timing` | needs STA_RPT | N/A host | refuse missing |
| `post-fit-timing-margin` | unit mutation **rc=0** | skip-absent is 77 path tested | soft-skip≠pass |
| `timing-exclusion` | needs artifacts | N/A | — |
| `pms-baseline-check` (hw) | needs live PMS | inventory CRITICAL when key missing | **PASS_INCOMPLETE**, not PASS |
| `pms-nal-stats` (hw) | needs live PMS | SKIP-NOT-PASS 77 | not pass |
| `check-core-conf-geometry` | live or fixture | unmapped **rc=77** | not pass |
| `video_regression.sh` (device) | parent-only device | liveness unit **rc=0** | was disk-only false green — **fixed/landed** |
| `scripts/run_verilator.sh` | yes | version rc=0; bad.sv **rc=2** | cannot green %Error |
| FBAR / deploy / soak | parent device | NOT run (rule: agents do not device-test) | — |

## 8. Known RED on integ tip (pre-existing, not introduced by w-lint)

`tests/unit/test_rtl_invariants.sh` **true rc=1**:
```
FAIL: sendDdrFrame must use selectDdrWriteBank (display-ack / stale-free guard)
```
This is product/ARM path drift on the integ tip (w-fit bank-select work). Gate-integrity did **not** weaken the invariant. w-fit must clear before claiming unit green on the merge.

## 9. Files changed

- `tests/unit/test_unit_rollcall.py` — derive/write-expected, MERGE_HINT, fingerprints
- `tests/unit/test_pipe_rc_trap.py` — new static lint
- `Makefile` — register pipe_rc trap
- `scripts/run_with_skip_summary.py` — GATE_RESULT taxonomy
- `tests/unit/test_gate_false_green_guard.py` — broader VL-missing + bare-fallback detection
- `tests/unit/test_sdram_dq_turnaround_verilator.sh` — exit 0 false green killed
- `tests/unit/test_sdram_startup_verilator.sh` — wrapper-only + 127 handling
- `scripts/mister_soft_bounce.sh` — pipe-rc fix
- `tests/hw/test_f3_visual_golden.sh` — PIPESTATUS[0]

## 10. Parent verify commands

```bash
cd .worktrees/w-lint   # or merge branch w-lint-gate-integrity
python3 tests/unit/test_unit_rollcall.py; echo true_rc=$?
python3 tests/unit/test_pipe_rc_trap.py; echo true_rc=$?
python3 tests/unit/test_gate_false_green_guard.py; echo true_rc=$?
python3 scripts/run_with_skip_summary.py --self-test; echo true_rc=$?
bash tests/unit/test_video_regression_liveness.sh; echo true_rc=$?
# full suite (long): make unit; echo true_rc=$?
```
