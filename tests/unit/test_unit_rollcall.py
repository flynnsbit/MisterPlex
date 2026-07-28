#!/usr/bin/env python3
"""Static roll-call for make unit-unlocked.

This catches the dangerous class where a unit test is removed from the
unit-unlocked recipe or build prerequisite list and the suite silently stays
empty/green for that check. Runtime announcement is still owned by each test;
this guard verifies the suite remains registered to run every expected test.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = Path(os.environ.get("UNIT_ROLLCALL_MAKEFILE", ROOT / "Makefile"))

EXPECTED_PREREQS = [
    "unit-rollcall",
    "preflight",
    "$(ROOT)/build/test_cadence",
    "$(ROOT)/build/test_avclock",
    "$(ROOT)/build/test_mraudio_status",
    "$(ROOT)/build/test_osd_menu",
    "$(ROOT)/build/test_last_frame_latch",
    "$(ROOT)/build/test_playback_overlay",
    "$(ROOT)/build/test_input_mailbox",
    "$(ROOT)/build/test_pixel_format",
    "$(ROOT)/build/test_main_guard",
    "$(ROOT)/build/test_status_telemetry",
    "$(ROOT)/build/test_resolve",
    "$(ROOT)/build/test_pms_timeline",
    "$(ROOT)/build/test_companion_eof",
    "$(ROOT)/build/test_companion_plant_seek",
    "$(ROOT)/build/pms_baseline_probe",
    "$(ROOT)/build/test_h264_bitstream_source",
    "$(ROOT)/build/test_bitstream_ring_lifecycle",
    "$(ROOT)/build/test_frame_store_math",
    "$(ROOT)/build/test_frame_store_sdram_sim",
    "$(ROOT)/build/test_frame_store_ddr_prefetch_sim",
    "$(ROOT)/build/test_sdram_memtest_sim",
    "$(ROOT)/build/test_sdram_mailbox",
    "$(ROOT)/build/test_annexb_count",
    "$(ROOT)/build/test_sps_parse",
    "$(ROOT)/build/test_slice_hdr",
    "$(ROOT)/build/test_cavlc_dc",
    "$(ROOT)/build/test_idct_quant",
    "$(ROOT)/build/test_p3_host_recon_vectors",
    "$(ROOT)/build/test_p3_idct_reference_model",
    "$(ROOT)/build/test_p3_inter_pred_vectors",
    "$(ROOT)/build/extract_h264_golden",
]

EXPECTED_COMMANDS = [
    "$(ROOT)/build/test_cadence",
    "$(ROOT)/build/test_avclock",
    "$(ROOT)/build/test_mraudio_status",
    "$(ROOT)/build/test_osd_menu",
    "bash $(ROOT)/tests/unit/test_osd_menu_red.sh",
    "$(ROOT)/build/test_last_frame_latch",
    "bash $(ROOT)/tests/unit/test_last_frame_latch_red.sh",
    "$(ROOT)/build/test_playback_overlay",
    "$(ROOT)/build/test_input_mailbox",
    "$(ROOT)/build/test_pixel_format",
    "$(ROOT)/build/test_main_guard",
    "$(ROOT)/build/test_status_telemetry",
    "$(ROOT)/build/test_resolve",
    "$(ROOT)/build/test_pms_timeline",
    "$(ROOT)/build/test_companion_eof",
    "$(ROOT)/build/test_companion_plant_seek",
    "$(ROOT)/tests/unit/test_pms_baseline_gate.sh",
    "$(ROOT)/tests/unit/test_pms_baseline_live_gate.sh",
    "$(ROOT)/build/test_h264_bitstream_source",
    "$(ROOT)/build/test_bitstream_ring_lifecycle",
    "$(ROOT)/build/test_frame_store_math",
    "$(ROOT)/build/test_frame_store_sdram_sim",
    "$(ROOT)/build/test_frame_store_ddr_prefetch_sim",
    "$(ROOT)/build/test_sdram_memtest_sim",
    "$(ROOT)/build/test_sdram_mailbox",
    "$(ROOT)/build/test_annexb_count",
    "python3 $(ROOT)/tests/unit/test_ddr_publish_path_static.py",
    "$(ROOT)/build/test_status_telemetry $(UNIT_ANNEXB)",
    "$(ROOT)/build/test_sps_parse $(UNIT_ANNEXB)",
    "$(ROOT)/build/test_slice_hdr $(UNIT_ANNEXB)",
    "$(ROOT)/build/test_cavlc_dc $(UNIT_ANNEXB)",
    "$(ROOT)/build/test_idct_quant $(UNIT_ANNEXB)",
    "$(ROOT)/build/test_p3_host_recon_vectors",
    "$(ROOT)/tests/unit/test_h264_golden_extractor.sh",
    "$(ROOT)/tests/unit/test_h264_frame_plane_goldens.sh",
    "$(ROOT)/tests/unit/test_derived_validation_hashes.sh",
    "$(ROOT)/tests/unit/test_i420_candidate_score.sh",
    "$(ROOT)/tests/unit/test_h264_multinal_stream_path.sh",
    "$(ROOT)/build/test_p3_idct_reference_model",
    "$(ROOT)/build/test_p3_inter_pred_vectors",
    "python3 $(ROOT)/tests/unit/test_no_conflict_markers.py",
    "python3 $(ROOT)/tests/unit/test_bench_rtl_filelists.py",
    "python3 $(ROOT)/tests/unit/test_p3_high_cabac_scope.py",
    "python3 $(ROOT)/tests/unit/test_p3_intra_mb0_verilator.py",
    "python3 $(ROOT)/tests/unit/test_h264_intra_nb_ctx_verilator.py",
    "python3 $(ROOT)/tests/unit/test_p3_idct_rtl_model.py",
    "python3 $(ROOT)/tests/unit/test_p3_intra_frame_verilator.py",
    "$(ROOT)/tests/unit/test_p3_inter_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_p3_dpb_mc_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_h264_decode_core_writeback_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_h264_decode_core_p16z_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_h264_p_slice_modes_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_p3_inter_stream_path_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_companion_http.sh",
    "$(ROOT)/tests/unit/test_plex_browse.sh",
    "$(ROOT)/tests/unit/test_play_file_delivery.sh",
    "$(ROOT)/tests/unit/test_no_private_data.sh",
    "$(ROOT)/tests/unit/test_capture_rig.sh",
    "$(ROOT)/tests/unit/test_resource_preflight.sh",
    "python3 $(ROOT)/scripts/run_with_skip_summary.py --self-test",
    "python3 $(ROOT)/scripts/check_pipe_exit_safety.py",
    "python3 $(ROOT)/scripts/check_skip_exit_codes.py",
    "$(ROOT)/scripts/check_define_parity.py",
    "python3 $(ROOT)/scripts/check_rtl_module_instantiations.py",
    "python3 $(ROOT)/scripts/check_qip_coverage.py",
    "python3 $(ROOT)/tests/unit/test_qip_coverage_gate.py",
    "python3 $(ROOT)/tests/unit/test_decode_completeness_gate.py",
    "python3 $(ROOT)/tests/unit/test_rtl_sink_and_qip_gate.py",
    "python3 $(ROOT)/scripts/check_decode_core_subtree.py",
    "python3 $(ROOT)/tests/unit/test_rtl_require_root_guard.py",
    "python3 $(ROOT)/tests/unit/test_decode_core_subtree_gate.py",
    "python3 $(ROOT)/tests/unit/test_w_audit_reachability_regressions.py",
    "python3 $(ROOT)/scripts/check_reachability_gate_capability.py",
    "python3 $(ROOT)/tests/unit/test_fit_evidence_ladder.py",
    "python3 $(ROOT)/tests/unit/test_reachability_gate_capability.py",
    "python3 $(ROOT)/tests/unit/test_dead_logic_pruning_gate.py",
    "python3 $(ROOT)/tests/unit/test_fit_request_readiness.py",
    "python3 $(ROOT)/tests/unit/test_ab_control_validity.py",
    "python3 $(ROOT)/tests/unit/test_fit_report_binding.py",
    "python3 $(ROOT)/scripts/check_fit_report_binding_policy.py",
    "python3 $(ROOT)/scripts/check_scope_discipline.py",
    "python3 $(ROOT)/tests/unit/test_scope_discipline_gate.py",
    "python3 $(ROOT)/tests/unit/test_skip_exit_code_gate.py",
    "python3 $(ROOT)/tests/unit/test_hw_visual_compare.py",
    "$(ROOT)/tests/unit/test_decode_throughput_gate.sh",
    "$(ROOT)/tests/unit/test_rtl_invariants.sh",
    "$(ROOT)/tests/unit/test_mister_ini_plex_guard.sh",
    "$(ROOT)/tests/unit/test_confstr_guard.sh",
    "$(ROOT)/tests/unit/test_release_rbf_hash.sh",
    "$(ROOT)/tests/unit/test_sdram_startup_verilator.sh",
    "$(ROOT)/tests/unit/test_sdram_dq_turnaround_verilator.sh",
    "$(ROOT)/tests/unit/test_h264_cavlc_residual_verilator.sh",
    "$(ROOT)/tests/unit/test_level_width_verilator.sh",
    "$(ROOT)/tests/unit/test_stream_path_recon_integration.sh",
    "$(ROOT)/tests/unit/test_stream_path_real_intra_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_stream_path_full_frame_compare.sh",
    "$(ROOT)/tests/unit/test_ddram_frame_rd_bank_select.sh",
    "python3 $(ROOT)/tests/parse_res_csum_status.py --self-test",
    "$(ROOT)/tests/unit/test_p3_idct_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_p3_deblock_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_p3_stream_path_recon_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_stream_path_deblock_integration.sh",
    "bash $(ROOT)/tests/unit/test_stream_path_ddr_ring_integration.sh",
    "$(ROOT)/tests/unit/test_ddr_frame_store_warm_reset.sh",
    "bash $(ROOT)/tests/unit/test_ddr_frame_store_swap_livelock.sh",
    "$(ROOT)/scripts/rtl_lint.py",
    "$(ROOT)/tests/unit/test_h264_syntax_primitives_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_h264_sps_geometry_rtl_sim.sh",
    "$(ROOT)/tests/unit/test_h264_baseline_syntax_rtl_sim.sh",
]

IGNORED_COMMANDS = [
    # Suite setup/helper commands, not tests. Everything else in unit-unlocked's
    # recipe must be registered above or the guard fails with UNREGISTERED_*.
    "mkdir -p $(ROOT)/build",
    "python3 $(ROOT)/scripts/gen_test_annexb_real.py $(UNIT_ANNEXB)",
    "chmod +x $(ROOT)/tests/unit/*.sh $(ROOT)/tests/unit/*.py $(ROOT)/tests/hw/*.sh 2>/dev/null || true",
]


def normalize_command(line: str) -> str:
    line = line.strip()
    line = line[1:] if line.startswith("@") else line
    return re.sub(r"\s+", " ", line.strip())


def parse_unit_unlocked(makefile: Path) -> tuple[list[str], list[str]]:
    lines = makefile.read_text(encoding="utf-8").splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith("unit-unlocked:"))
    except StopIteration as exc:
        raise AssertionError("unit-unlocked target not found") from exc

    target_lines: list[str] = []
    i = start
    while i < len(lines):
        target_lines.append(lines[i].rstrip("\\").strip())
        if not lines[i].rstrip().endswith("\\"):
            break
        i += 1
    target_text = " ".join(target_lines)
    prereqs = target_text.split(":", 1)[1].split()

    commands: list[str] = []
    for line in lines[i + 1 :]:
        if line and not line.startswith("\t") and re.match(r"^[^#\s].*:", line):
            break
        if line.startswith("\t"):
            commands.append(normalize_command(line))
    return prereqs, commands


def main() -> int:
    prereqs, commands = parse_unit_unlocked(MAKEFILE)
    ignored_command_set = set(IGNORED_COMMANDS)
    ignored_commands = [c for c in commands if c in ignored_command_set]
    protected_commands = [c for c in commands if c not in ignored_command_set]
    missing_prereqs = [p for p in EXPECTED_PREREQS if p not in prereqs]
    unregistered_prereqs = [p for p in prereqs if p not in EXPECTED_PREREQS]
    missing_commands = [c for c in EXPECTED_COMMANDS if c not in protected_commands]
    unregistered_commands = [c for c in protected_commands if c not in EXPECTED_COMMANDS]
    missing_ignored_commands = [c for c in IGNORED_COMMANDS if c not in ignored_commands]

    if (
        missing_prereqs
        or unregistered_prereqs
        or missing_commands
        or unregistered_commands
        or missing_ignored_commands
    ):
        print("UNIT_ROLLCALL_FAIL")
        print(
            "UNIT_ROLLCALL_COUNTS "
            f"actual_prereqs={len(prereqs)} expected_prereqs={len(EXPECTED_PREREQS)} "
            f"actual_commands={len(commands)} protected_commands={len(protected_commands)} "
            f"expected_commands={len(EXPECTED_COMMANDS)} "
            f"actual_ignored_commands={len(ignored_commands)} "
            f"expected_ignored_commands={len(IGNORED_COMMANDS)}"
        )
        for item in missing_prereqs:
            print(f"MISSING_PREREQ {item}")
        for item in unregistered_prereqs:
            print(f"UNREGISTERED_PREREQ {item} -- register this unit-unlocked prerequisite")
        for item in missing_commands:
            print(f"MISSING_COMMAND {item}")
        for item in unregistered_commands:
            print(f"UNREGISTERED_COMMAND {item} -- register this unit-unlocked command")
        for item in missing_ignored_commands:
            print(f"MISSING_IGNORED_COMMAND {item}")
        return 1

    print(
        "UNIT_ROLLCALL_OK "
        f"actual_prereqs={len(prereqs)} expected_prereqs={len(EXPECTED_PREREQS)} "
        f"actual_commands={len(commands)} protected_commands={len(protected_commands)} "
        f"expected_commands={len(EXPECTED_COMMANDS)} "
        f"actual_ignored_commands={len(ignored_commands)} "
        f"expected_ignored_commands={len(IGNORED_COMMANDS)} "
        f"makefile={MAKEFILE}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
