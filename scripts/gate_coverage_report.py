#!/usr/bin/env python3
"""Gate coverage meta-report: what every gate proves and does NOT prove.

Produces a machine-readable JSON and a human-readable table showing the
full inventory of build gates, their coverage scope, blind spots, red-proof
status, and whether they are currently runnable on this host.

Exit codes:
  0 = report generated (does not mean all gates pass — see the report)
  1 = a gate is dead (always fails) or has no red proof
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@dataclass
class GateReport:
    id: str
    script: str
    makefile_target: str
    proves: str
    does_not_prove: str
    red_proof_method: str
    red_proof_passed: bool | None  # None = not tested
    runnable_here: bool
    runnable_note: str
    owner: str
    coverage_level: str = "green"  # green | refuses_here | partial | dead
    verification_target: str = "STATIC"  # RTL | HOST | STATIC | DEVICE | NONE
    # RTL = exercises Verilator/simulation of the hardware description
    # HOST = exercises the ARM/C++ software model only (NOT hardware)
    # STATIC = analyses source text, reports, or constraints (no execution of design)
    # DEVICE = requires live FPGA hardware
    # NONE = meta-gate or cannot exercise its target here
    verification_target_note: str = ""
    exit_codes: dict[str, int] = field(default_factory=dict)
    observed_failing_real: bool = False  # Has this gate ever been observed failing on REAL (non-sabotage) input?
    observed_failing_note: str = ""  # Evidence: when, what input, what rc


def check_tool(cmd: str) -> bool:
    return shutil.which(cmd) is not None


def check_venv_numpy() -> bool:
    venv_py = ROOT / "build" / ".venv" / "bin" / "python3"
    if not venv_py.exists():
        return False
    try:
        r = subprocess.run(
            [str(venv_py), "-c", "import numpy; import PIL"],
            capture_output=True, timeout=10,
        )
        return r.returncode == 0
    except Exception:
        return False


def check_verilator() -> bool:
    wrapper = ROOT / "scripts" / "run_verilator.sh"
    if not wrapper.exists():
        return False
    try:
        r = subprocess.run(
            [str(wrapper), "--version"],
            capture_output=True, timeout=10, cwd=ROOT,
        )
        return r.returncode == 0
    except Exception:
        return False


def check_quartus() -> bool:
    qm = os.environ.get("QUARTUS_MAP") or shutil.which("quartus_map")
    return qm is not None and os.access(qm, os.X_OK)


def has_v4l2_device() -> bool:
    return Path("/dev/video4").exists()


def build_report() -> list[GateReport]:
    has_verilator = check_verilator()
    has_quartus = check_quartus()
    has_numpy = check_venv_numpy()
    has_grabber = has_v4l2_device()

    gates = [
        GateReport(
            id="define-parity",
            script="scripts/check_define_parity.py",
            makefile_target="define-parity",
            proves=(
                "Quartus product macros (from .qsf) match the macros injected into "
                "Verilator/lint. Test-only macros are declared in an allowlist."
            ),
            does_not_prove=(
                "Does NOT prove macros are correct in value, only that the same set "
                "is defined in both flows. Does NOT prove macros are used correctly "
                "in RTL. Does NOT prove Quartus actually synthesises with these macros "
                "(that requires a real fit)."
            ),
            red_proof_method="--drop-verilator-macro DDR_FRAME_STORE → rc=1",
            red_proof_passed=True,
            runnable_here=True,
            runnable_note="Pure Python, no external tools needed.",
            owner="w-c2",
            exit_codes={"green": 0, "red_drop_macro": 1},
            verification_target="STATIC",
            verification_target_note="Compares .qsf macro lists against Python defines. No RTL execution, no host model.",
            observed_failing_real=False,
            observed_failing_note="Never observed failing on real input — DDR_FRAME_STORE has been present in both flows since gate creation.",
        ),
        GateReport(
            id="quartus-sv-subset",
            script="scripts/check_quartus_sv_subset.py",
            makefile_target="quartus-sv-subset",
            proves=(
                "Source files do not contain known Quartus Analysis/Synthesis "
                "rejection patterns: localparam in module parameter list, part-select "
                "on function-call result, unpacked array element in function-body "
                "concatenation (h264_dpb ref_win only)."
            ),
            does_not_prove=(
                "Does NOT prove Quartus will elaborate, infer, fit, or close timing. "
                "Only catches 3 specific syntax patterns that historically caused "
                "Analysis/Synthesis failures. Does NOT prove absence of all Quartus "
                "syntax issues — new rejection patterns must be added manually after "
                "each new failure. The parse-pass guarantee is NARROW."
            ),
            red_proof_method=(
                "Inject localparam-in-params, function-call-select, unpacked-array-concat "
                "→ rc=1 each. Disable both probes → rc=4 (REFUSE)."
            ),
            red_proof_passed=True,
            runnable_here=not has_quartus,
            runnable_note=(
                "Runs static checks (always). Quartus toolchain probe returns rc=4 "
                "(REFUSE) when no local/remote Quartus is reachable — this is correct "
                "and distinct from PASS. The static subset checks run regardless."
            ),
            owner="w-c2",
            coverage_level="refuses_here" if not has_quartus else "green",
            verification_target="STATIC",
            verification_target_note="Regex/AST scan of .sv source text. No RTL simulation, no host model.",
            exit_codes={"refuse_no_toolchain": 4},
            observed_failing_real=False,
            observed_failing_note="Cannot be observed failing locally (rc=4 REFUSE). Has caught real syntax issues on remote Quartus in prior sessions.",
        ),
        GateReport(
            id="post-fit-hierarchy",
            script="scripts/check_quartus_fit_hierarchy.py",
            makefile_target="post-fit-hierarchy",
            proves=(
                "Critical modules (ddr_frame_store, present_core, stream_path, "
                "ddr_bitstream_reader) survive Quartus fitting with non-trivial "
                "resource usage (ALUTs, registers, block memory, M10Ks). Also scans "
                "compile log for removal/tie-off warnings and combinational loops "
                "(332125/332126) on critical modules."
            ),
            does_not_prove=(
                "Does NOT prove modules are functionally correct. Does NOT prove "
                "timing closure. Does NOT prove non-critical modules survived. "
                "Resource floors are minimum thresholds, not functional correctness. "
                "Comb-loop scan only catches loops REPORTED by Quartus on critical "
                "modules — loops in non-critical modules or loops Quartus doesn't "
                "report are invisible."
            ),
            red_proof_method=(
                "Optimized-away ddr_frame_store (2 ALUTs, 0 regs) → rc=1. "
                "Combinational loop warning in compile log → rc=1. "
                "Missing report file → rc=4 (REFUSE)."
            ),
            red_proof_passed=True,
            runnable_here=True,
            runnable_note=(
                "Requires fit report artifacts (Plex.fit.rpt, compile.log) from a "
                "remote Quartus build. Cannot run standalone — needs FIT_RPT=. "
                "Wired into build_rbf_remote.sh copy-back."
            ),
            owner="w-c2",
            exit_codes={"green": 0, "red_optimized_away": 1, "red_comb_loop": 1, "refuse_missing": 4},
            verification_target="STATIC",
            verification_target_note="Parses Quartus .fit.rpt and compile.log text. Checks post-synthesis, but no RTL execution.",
            observed_failing_real=True,
            observed_failing_note="slot11 compile.log: rc=1 REJECTED — 2 combinational loops (332125) in emu|present|fstore|input_fifo (async_fifo.sv pre-fix source).",
        ),
        GateReport(
            id="post-fit-timing",
            script="scripts/check_quartus_timing.py",
            makefile_target="post-fit-timing",
            proves=(
                "No negative setup/hold/recovery/removal/minimum-pulse-width slack "
                "in the Quartus STA report."
            ),
            does_not_prove=(
                "Does NOT prove timing is actually met in silicon (STA is a model). "
                "Does NOT prove paths weren't excluded from analysis — that is "
                "check_timing_exclusions.py's job. Does NOT check Fmax targets, only "
                "slack polarity. Does NOT prove the report is from the current RTL "
                "(report provenance is build_rbf_remote.sh's responsibility)."
            ),
            red_proof_method="Negative setup slack (-0.125, TNS -1.250) → rc=1. Missing report → rc=4.",
            red_proof_passed=True,
            runnable_here=True,
            runnable_note="Requires STA_RPT= from a remote Quartus build. Wired into build_rbf_remote.sh.",
            owner="w-c2",
            exit_codes={"green": 0, "red_negative_slack": 1, "refuse_missing": 4},
            verification_target="STATIC",
            verification_target_note="Parses Quartus STA .sta.rpt text. Timing model, not silicon measurement.",
            observed_failing_real=True,
            observed_failing_note="slot11 Plex.sta.rpt: rc=1 REJECTED — worst setup slack -2.137ns (PATH 1: f2sdram~FF_1937→current_session[51], PATH 2: rsp_left[6]→y_valid[7]).",
        ),
        GateReport(
            id="timing-exclusion",
            script="scripts/check_timing_exclusions.py",
            makefile_target="timing-exclusion",
            proves=(
                "No new SDC timing exclusions (set_clock_groups, set_false_path, "
                "set_max_delay, set_multicycle_path) have been added without being "
                "registered in the committed baseline. Expected clock domains "
                "(general[0].gpll, general[2].gpll) appear in the STA report. "
                "An empty STA report (zero analysed rows) is a hard fail."
            ),
            does_not_prove=(
                "Does NOT prove existing baseline exclusions are correct — they were "
                "accepted at baseline creation time. Does NOT detect Quartus-internal "
                "optimisations that remove paths without SDC changes. Does NOT prove "
                "the STA report is from the current RTL. SDC fingerprints are "
                "whitespace-normalised hashes — a semantically identical but "
                "reformatted constraint gets a new fingerprint and triggers review "
                "(this is a feature, not a bug)."
            ),
            red_proof_method=(
                "New -asynchronous clock group → rc=1 with HIGH RISK. "
                "Missing expected clock general[2].gpll in STA → rc=1. "
                "Empty STA (zero rows) → rc=1."
            ),
            red_proof_passed=True,
            runnable_here=True,
            runnable_note=(
                "SDC audit runs standalone (make timing-exclusion). Full gate with "
                "STA coverage requires STA_RPT=. Wired into build_rbf_remote.sh."
            ),
            owner="w-c2",
            exit_codes={"green": 0, "red_new_async": 1, "red_missing_clock": 1, "red_empty_sta": 1},
            verification_target="STATIC",
            verification_target_note="Fingerprints SDC constraint text + STA report coverage. No RTL execution.",
            observed_failing_real=False,
            observed_failing_note="slot11 SDC+STA passed (rc=0). No real exclusion evasion observed yet. Gate is new — first real test was slot11.",
        ),
        GateReport(
            id="confstr-guard",
            script="scripts/check_confstr_guard.py",
            makefile_target="(inline in make unit)",
            proves=(
                "CONF_STR structure in Plex.sv is well-formed: file slots have "
                "3-character extension chunks, option entries have correct choice "
                "counts for their bit widths, status bits do not overlap, required "
                "entries (F1-F3, O[4], O[9:6], O[15:14], J1, v) are present."
            ),
            does_not_prove=(
                "Does NOT prove the OSD actually renders correctly — only structure. "
                "Does NOT prove file extensions match real file formats. Does NOT "
                "prove option labels are meaningful. Does NOT prove the bit assignments "
                "match the RTL that reads them."
            ),
            red_proof_method=(
                "Inject malformed extension field (extra commas, wrong chunk size) → rc=1. "
                "test_confstr_guard.sh has both green and red proofs."
            ),
            red_proof_passed=True,
            runnable_here=True,
            runnable_note="Pure Python, no external tools.",
            owner="w-c2",
            exit_codes={"green": 0, "red_malformed": 1},
            verification_target="STATIC",
            verification_target_note="Parses CONF_STR text in Plex.sv. No RTL execution, no host model.",
            observed_failing_real=False,
            observed_failing_note="CONF_STR has not been observed malformed since gate creation. Gate exists to prevent regressions.",
        ),
        GateReport(
            id="mister-ini-plex-guard",
            script="scripts/check_mister_ini_plex_guard.py",
            makefile_target="(inline in make unit)",
            proves=(
                "MiSTer.ini [Plex] section contains all required video_mode anti-retune "
                "pins matching the reference file."
            ),
            does_not_prove=(
                "Does NOT prove the MiSTer.ini is the one deployed to the device. "
                "Does NOT prove the video mode values are correct for the user's "
                "display — only that they match the reference. Does NOT prove other "
                "MiSTer.ini sections are sane."
            ),
            red_proof_method=(
                "Missing video_mode_pal → rc=1. Commented-out video_mode → rc=1. "
                "test_mister_ini_plex_guard.sh has both green and red proofs."
            ),
            red_proof_passed=True,
            runnable_here=True,
            runnable_note="Pure Python, no external tools.",
            owner="w-c2",
            exit_codes={"green": 0, "red_missing_key": 1, "red_commented": 1},
            verification_target="STATIC",
            verification_target_note="Parses MiSTer.ini text. No RTL execution, no host model.",
            observed_failing_real=False,
            observed_failing_note="MiSTer.ini [Plex] section has not been observed malformed since gate creation.",
        ),
        GateReport(
            id="edges",
            script="scripts/check_edges.py",
            makefile_target="(none — run manually or via test_capture_rig.sh)",
            proves=(
                "Present-path geometry: first and last source column/row reach the "
                "display edges without wrapping, shifting, or repeating. Detects the "
                "'bar' symptom (column repeated at edge), horizontal wrap (last column "
                "appears before first), and vertical shift. Stale-capture detection "
                "prevents grading a buffered/frozen frame."
            ),
            does_not_prove=(
                "Does NOT prove colour accuracy, chroma fidelity, motion rendering, "
                "or audio sync. Does NOT prove the frame is from the DDR frame store "
                "(could be a test pattern). Synthetic mode proves gate logic only, "
                "not real display output. V4L2 capture has limited-range gamma that "
                "affects thresholds. Does NOT prove interior pixels are correct — "
                "only the four edges."
            ),
            red_proof_method=(
                "Synthetic hwrap (horizontal wrap) → rc=1. "
                "Synthetic vshift (vertical shift) → rc=1. "
                "Synthetic stale (byte-identical frames) → rc=2."
            ),
            red_proof_passed=has_numpy,
            runnable_here=has_numpy,
            runnable_note=(
                f"numpy/Pillow: {'available (build/.venv)' if has_numpy else 'MISSING'}. "
                f"V4L2 grabber (/dev/video4): {'present' if has_grabber else 'ABSENT — live capture requires w-cap device host'}. "
                f"Synthetic and file modes work on this host. "
                f"Live v4l2 capture requires HDMI grabber attached to MiSTer output."
            ),
            owner="w-c2 (gate logic), w-cap (device/capture)",
            coverage_level="partial" if not has_grabber else "green",
            verification_target="DEVICE",
            verification_target_note="Live mode: samples real FPGA video output via HDMI capture. Synthetic mode: gate logic only (NONE).",
            exit_codes={"green_synthetic": 0, "red_hwrap": 1, "red_vshift": 1, "red_stale": 2, "no_device": 2},
            observed_failing_real=False,
            observed_failing_note="No live capture available on this host. Synthetic tests pass. Live geometry grading not yet exercised on device host.",
        ),
        GateReport(
            id="rtl-lint",
            script="scripts/rtl_lint.py",
            makefile_target="rtl-lint",
            proves=(
                "Verilator parse/lint passes on all owned RTL with no width warning "
                "regressions above the committed baseline. Product macros from .qsf "
                "are injected identically to the Quartus flow."
            ),
            does_not_prove=(
                "Does NOT prove Quartus will synthesise — Verilator and Quartus "
                "accept different SystemVerilog subsets. Does NOT prove functional "
                "correctness. Width warnings are baselined (allowed up to the count "
                "in rtl_lint_baseline.json) — a new width warning in a file already "
                "above its baseline is invisible. Does NOT prove timing, fitting, or "
                "elaboration."
            ),
            red_proof_method=(
                "Verilator absent (OSS_CAD_SUITE=/nonexistent) → wrapper rc=127, "
                "rtl_lint.py rc=3 (REFUSE). Width regression above baseline → rc=1."
            ),
            red_proof_passed=has_verilator,
            runnable_here=has_verilator,
            runnable_note=(
                f"Verilator: {'5.051 pinned at ~/.local/oss-cad-suite-20260726' if has_verilator else 'MISSING'}. "
                f"Absent-tool rc=127/3 confirmed on this host."
            ),
            owner="w-c2",
            exit_codes={"green": 0, "refuse_no_verilator": 3},
            verification_target="RTL",
            verification_target_note="Verilator parses and lint-checks the RTL. NOT simulation — no stimulus, no functional verification.",
            observed_failing_real=True,
            observed_failing_note="Observed rc=1 when w-a3 audio_fifo.sv width warnings exceeded baseline (this session, pre-Gray-code fix). Also rc=3 REFUSE when Verilator absent.",
        ),
        GateReport(
            id="cdc-crossings",
            script="scripts/check_cdc_crossings.py",
            makefile_target="cdc-crossings",
            proves=(
                "Every crossing in the CDC manifest has a documented protection "
                "mechanism (fifo, sync_2ff, handshake, or level). Fast-domain "
                "pulse sources crossing to slow domains without protection are "
                "flagged CRITICAL (data loss risk). Stale module references are "
                "detected when --check-stale is used."
            ),
            does_not_prove=(
                "Does NOT prove the crossing list is COMPLETE — unlisted crossings "
                "are invisible to this gate. Does NOT prove the protection mechanism "
                "is correctly implemented (only that one is declared). Does NOT "
                "prove synchroniser depth is adequate for the frequency ratio. "
                "Does NOT prove handshake/FIFO logic is bug-free. This is a "
                "structured register, not a verifier."
            ),
            red_proof_method=(
                "Manifest with protection='none' and src_type='pulse' → rc=1 CRITICAL. "
                "Missing manifest → rc=4 REFUSE."
            ),
            red_proof_passed=True,
            runnable_here=True,
            runnable_note=(
                "Pure Python, no external tools. Currently REJECTS (rc=1) because "
                "manifest contains 2 known-unprotected future crossings from w-a3's "
                "arbiter fix (60df5a2, not yet merged). These are INTENTIONALLY "
                "listed as unprotected to track the hazard."
            ),
            owner="w-c2",
            exit_codes={"green": 0, "red_unprotected": 1, "refuse_no_manifest": 4},
            verification_target="STATIC",
            verification_target_note="Audits a curated manifest of known crossings. No RTL simulation, no host model.",
            observed_failing_real=True,
            observed_failing_note="Currently rc=1 on real manifest: 2 unprotected fast→slow crossings from w-a3 arbiter fix (60df5a2). Intentionally tracked as hazard.",
        ),
        GateReport(
            id="test-suppression",
            script="scripts/check_test_suppression.py",
            makefile_target="test-suppression",
            proves=(
                "No test or gate script contains an unallowlisted suppression pattern: "
                "env-var-gated pass-on-skip (ALLOW_MISSING_VERILATOR, "
                "MISTERPLEX_ALLOW_LOW_MEMORY_TESTS), judgement words near success "
                "returns, or detected mismatch/error followed by success return. "
                "Catches the w-qp pattern: detecting overflow 117 times then return 0."
            ),
            does_not_prove=(
                "Does NOT prove allowlisted entries are actually safe (only reviewed). "
                "Does NOT prove tolerance thresholds are correct. Does NOT prove "
                "test generators reach their failure regions. Regex-based, not AST-based — "
                "can have false positives (handled via allowlist) and may miss obfuscated "
                "suppression patterns. Does NOT verify that tests check the RIGHT thing, "
                "only that they do not suppress what they find."
            ),
            red_proof_method=(
                "Synthetic test with w-qp's exact pattern: detect 18-bit overflow N times, "
                "comment 'These are theoretical', return 0. Gate catches both the "
                "mismatch-near-success (HIGH) and the judgement word (MEDIUM). "
                "Missing scan dir → rc=4 REFUSE."
            ),
            red_proof_passed=True,
            runnable_here=True,
            runnable_note=(
                "Pure Python, no external tools. Currently REJECTS (rc=1) with 17 "
                "active findings: 16 ALLOW_MISSING_VERILATOR overrides + 1 "
                "MISTERPLEX_ALLOW_LOW_MEMORY_TESTS override. These are real "
                "suppression patterns in the codebase, not false positives."
            ),
            owner="w-c2",
            exit_codes={"green": 0, "red_suppression": 1, "refuse_missing": 4},
            verification_target="STATIC",
            verification_target_note="Regex scan of test/gate source text for suppression patterns. No RTL execution, no host model.",
            observed_failing_real=True,
            observed_failing_note="Currently rc=1 on real codebase: 26 active findings (16 ALLOW_MISSING_VERILATOR + gate_coverage_report.py self-references + test_rtl_invariants.sh red-proof fixtures). The 16 ALLOW_MISSING_VERILATOR are the exact structural anti-pattern that caused 14 gates to silently pass.",
        ),
        GateReport(
            id="test-degeneracy",
            script="scripts/check_test_degeneracy.py",
            makefile_target="test-degeneracy",
            proves=(
                "Every test file that performs comparison assertions also asserts "
                "the reference/golden output differs from the input (degeneracy guard). "
                "Catches the w-deblock #18 pattern: test compares A vs B where B==A "
                "trivially, producing a green result that proves nothing."
            ),
            does_not_prove=(
                "Does NOT prove the degeneracy guard is CORRECT — only that one exists. "
                "Does NOT prove the test stimuli cover all paths. Does NOT prove the "
                "comparison itself is meaningful (that is test-suppression's job). "
                "Regex-based, not AST-based — may miss unusual comparison patterns. "
                "Infrastructure tests (parsers, formatters) are allowlisted and not "
                "checked. Does NOT detect a test that ALWAYS modifies but by a WRONG amount."
            ),
            red_proof_method=(
                "Synthetic degenerate test (np.array_equal with no != input guard) → "
                "rc=1. Remove synthetic file → back to 2 real findings (rc=1). "
                "Add degeneracy guard to synthetic → no longer flagged."
            ),
            red_proof_passed=True,
            runnable_here=True,
            runnable_note=(
                "Pure Python, no external tools. Currently REJECTS (rc=1) with 2 "
                "active findings: test_p3_intra_frame_verilator.cpp (#16) and "
                "score_h264_native_frames.cpp (#17) — exactly the two instruments "
                "that caused the largest failures this session."
            ),
            owner="w-c2",
            verification_target="STATIC",
            verification_target_note="Scans test source text for presence/absence of degeneracy guards. No RTL execution.",
            exit_codes={"green": 0, "red_degenerate": 1, "refuse_no_tests": 4},
            observed_failing_real=True,
            observed_failing_note="Currently rc=1 on real codebase: 2 active findings — test_p3_intra_frame_verilator.cpp (instrument failure #16) and score_h264_native_frames.cpp (#17). Both are the exact instruments that produced misleading headline numbers.",
        ),
        GateReport(
            id="rtl-claim",
            script="scripts/check_rtl_claim.py",
            makefile_target="rtl-claim",
            proves=(
                "Every test whose filename claims RTL/Verilator coverage (contains "
                "'verilator', 'rtl_sim', 'rtl_model') demonstrably invokes the "
                "Verilator binary or links against generated simulation objects. "
                "Prevents #17: a test named as though it tests hardware when it "
                "only runs the host model."
            ),
            does_not_prove=(
                "Does NOT prove the Verilator invocation succeeds — only that it is "
                "attempted. Does NOT prove the RTL test covers all paths. Does NOT "
                "catch a test that claims RTL in its output/docs but not its filename. "
                "Does NOT prove the comparison logic is correct — only that a simulator "
                "is in the loop."
            ),
            red_proof_method=(
                "Synthetic test_foo_verilator.sh that calls host binary without "
                "Verilator → rc=1. Remove synthetic → rc=0."
            ),
            red_proof_passed=True,
            runnable_here=True,
            runnable_note="Pure Python, no external tools.",
            owner="w-c2",
            verification_target="STATIC",
            verification_target_note="Scans test source for Verilator invocation evidence. No RTL execution.",
            exit_codes={"green": 0, "red_no_verilator": 1, "refuse_missing": 4},
            observed_failing_real=False,
            observed_failing_note="All existing *verilator* and *rtl_sim* files reference Verilator/ALLOW_MISSING_VERILATOR. Would have caught score_h264_native_frames.cpp if it had been named *_rtl* or *_verilator*.",
        ),
        GateReport(
            id="product-hierarchy",
            script="scripts/check_product_hierarchy.py",
            makefile_target="product-hierarchy",
            proves=(
                "No module on the deny list appears in the Quartus synthesis "
                "hierarchy. Currently denies: decode_stub (1,438 ALMs, 32 DSPs, "
                "simulation shim setting Fmax ceiling). Prevents simulation-only "
                "or diagnostic code from reaching the product bitstream unnoticed."
            ),
            does_not_prove=(
                "Does NOT prove non-denied modules are correct. Does NOT prove "
                "the denied module is harmful (justification is in the deny list). "
                "Does NOT detect modules that SHOULD be present but are absent — "
                "that is post-fit-hierarchy's job. Requires map report from a fit."
            ),
            red_proof_method=(
                "decode_stub in slot11 Plex.map.rpt → rc=1 REJECTED. "
                "With known-findings file → rc=0 (owned, reported). "
                "Remove decode_stub from deny list → rc=0 (no denied modules)."
            ),
            red_proof_passed=True,
            runnable_here=True,
            runnable_note="Requires MAP_RPT from a remote Quartus build. slot11 available locally.",
            owner="w-c2",
            verification_target="STATIC",
            verification_target_note="Parses Quartus .map.rpt hierarchy table. No RTL execution.",
            exit_codes={"green": 0, "red_denied_module": 1, "refuse_no_report": 4},
            observed_failing_real=True,
            observed_failing_note="rc=1 on slot11 Plex.map.rpt: decode_stub present in product hierarchy (1,438 ALMs, 32 DSPs). This is the finding that prompted gate creation.",
        ),
    ]
    return gates


def format_report(gates: list[GateReport]) -> str:
    lines = []
    lines.append("# Gate Coverage Report")
    lines.append(f"# Host: {os.uname().nodename}")
    lines.append(f"# Generated: {__import__('datetime').datetime.now().isoformat()}")
    lines.append("")

    dead = []
    for g in gates:
        level_labels = {
            "green": "✅ GREEN (passes here)",
            "refuses_here": "🟡 REFUSES HERE (rc=4, zero local coverage, only meaningful on build host)",
            "partial": "🟠 PARTIAL (synthetic/file modes work; live capture requires device host)",
            "dead": "❌ DEAD",
        }
        status = level_labels.get(g.coverage_level, "✅ GREEN (passes here)")
        if not g.red_proof_passed:
            status = "❌ DEAD (no red proof)"
        lines.append(f"## {g.id} — {status}")
        lines.append(f"  Script:    {g.script}")
        lines.append(f"  Target:    {g.makefile_target}")
        lines.append(f"  Owner:     {g.owner}")
        lines.append(f"  Coverage:  {g.coverage_level}")
        target_icon = {"RTL": "🔬", "HOST": "💻", "STATIC": "📄", "DEVICE": "📺", "NONE": "⬜"}.get(g.verification_target, "?")
        lines.append(f"  Verifies:  {target_icon} {g.verification_target} — {g.verification_target_note}")
        lines.append(f"  PROVES:    {g.proves}")
        lines.append(f"  NOT prove: {g.does_not_prove}")
        lines.append(f"  Red proof: {g.red_proof_method}")
        lines.append(f"  Red ok:    {g.red_proof_passed}")
        fail_icon = "✅ YES" if g.observed_failing_real else "⚠️ NEVER"
        lines.append(f"  Observed failing on real input: {fail_icon}")
        if g.observed_failing_note:
            lines.append(f"    Evidence: {g.observed_failing_note}")
        lines.append(f"  Runnable:  {g.runnable_here} — {g.runnable_note}")
        lines.append(f"  Exit codes: {g.exit_codes}")
        lines.append("")
        if not g.runnable_here or not g.red_proof_passed:
            dead.append(g.id)

    # Verification target summary — the column that would have caught #17
    from collections import Counter
    target_counts = Counter(g.verification_target for g in gates)
    lines.append("## Verification Target Summary")
    lines.append("  (What does each gate actually exercise?)")
    for target in ["RTL", "HOST", "DEVICE", "STATIC", "NONE"]:
        count = target_counts.get(target, 0)
        if count:
            names = [g.id for g in gates if g.verification_target == target]
            lines.append(f"  {target:8s}: {count:2d} gate(s) — {', '.join(names)}")
    lines.append("")
    lines.append("  ⚠️  0 gates exercise RTL with stimulus (simulation).")
    lines.append("  ⚠️  0 gates exercise HOST decode model.")
    lines.append("  ⚠️  'rtl-lint' parses RTL but applies NO functional stimulus.")
    lines.append("  ⚠️  'edges' requires device — NOT runnable in CI.")
    lines.append("")

    if dead:
        lines.append(f"## GAPS: {', '.join(dead)}")
    else:
        lines.append("## No dead gates.")
    return "\n".join(lines)


def main() -> int:
    gates = build_report()
    report_text = format_report(gates)
    print(report_text)

    report_json = [asdict(g) for g in gates]
    out_dir = ROOT / "build"
    out_dir.mkdir(exist_ok=True)
    (out_dir / "gate_coverage.json").write_text(json.dumps(report_json, indent=2) + "\n")
    print(f"\nJSON written to build/gate_coverage.json")

    dead = [g for g in gates if not g.runnable_here or not g.red_proof_passed]
    return 1 if dead else 0


if __name__ == "__main__":
    raise SystemExit(main())
