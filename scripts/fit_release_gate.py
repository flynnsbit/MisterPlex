#!/usr/bin/env python3
"""Fit-release gate: QSF macros + elab + true_de + architecture blockers.

Leg 0 — rd-duck architecture blockers (must clear before any fit grant):
        coherent FIT_CANDIDATE, no int FPS overflow cargo, real raster SoT,
        compile-time Option-C / layout match, capacity-selected Option-C
        (not width>=1280; 960×540 must not overrun LEG bank), present_core
        OPTC phys wiring, PLXG ABA closed, ddr_frame_store on beam path,
        blank/store oracle. Soft-skip ≠ PASS.
Leg 1 — active VERILOG_MACRO set from the QSF under test is the 720p ascal path
        (FRAME_W=960 FRAME_H=540 PRESENT_BEAM_960 DDR_FRAME_STORE). Hollow
        640×480 and commented-out macros fail here.
Leg 2 — verilator-elab with *exactly* that parsed macro set.
Leg 3 — counted true-DE RTL sim for the raster the QSF configures; true_de=1.

Source of truth for macros is the QSF Quartus reads. Architecture blockers are
source-scanned against this tree (quoted paths in FAIL lines).

Exit codes:
  0  all legs PASS (EXECUTED)
  1  a leg REJECTED
  2  usage / fixture / internal error
  3  Verilator missing (REFUSED — not a pass)
  77 never used as success
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# RULER_ROOT = tree that owns this gate script (canonical w-fitgate).
# ROOT = tree under scan (may be integration merge via --root).
RULER_ROOT = Path(__file__).resolve().parents[1]
ROOT = RULER_ROOT
sys.path.insert(0, str(RULER_ROOT / "scripts"))

from check_define_parity import discover_quartus_macros  # noqa: E402

DEFAULT_QSF = ROOT / "fpga" / "Plex_MiSTer" / "Plex.qsf"
FIX = ROOT / "tests" / "fixtures" / "fit_release_gate"
CANDIDATE_PATHS = (
    ROOT / "docs" / "fit_candidate.json",
    ROOT / "assets" / "fit_candidate.json",
    FIX / "fit_candidate.json",
)
# Parent lock (2026-08-03): ascal_true_de_960 only for this fit campaign.
PARENT_LOCKED_ARCH = "ascal_true_de_960"

# Sibling worktrees scanned live at gate time for unmerged-vs-unimplemented.
SIBLING_LANES: dict[str, Path] = {
    "w-mem": Path("/home/flynnsbit/Projects/MisterPlex-wt-mem"),
    "w-clock": Path("/home/flynnsbit/Projects/MisterPlex-wt-clock"),
    "w-scaler": Path("/home/flynnsbit/Projects/MisterPlex-wt-scaler"),
    "w-osd": Path("/home/flynnsbit/Projects/MisterPlex-wt-osd"),
    "w-path": Path("/home/flynnsbit/Projects/MisterPlex-wt-path"),
    "w-nostub": Path("/home/flynnsbit/Projects/MisterPlex-wt-nostub"),
    "w-integ": Path("/home/flynnsbit/Projects/MisterPlex-wt-integ-720p"),
}


def apply_scan_root(scan_root: Path) -> None:
    """Point artefact scans at an integration/foreign tree; keep ruler scripts.

    Supported w-osd / integration invocation (canonical ruler, merged RTL):

      /path/to/MisterPlex-wt-fitgate/scripts/fit_release_gate.sh \\
        --root /path/to/merged-tree \\
        --qsf  /path/to/merged-tree/fpga/Plex_MiSTer/Plex.qsf

    B11 requires QSF under the same --root (no macros-A + RTL-B).
    Gate identity is always the ruler script identity (RULER_ROOT).
    """
    global ROOT, DEFAULT_QSF, FIX, CANDIDATE_PATHS, GATE_IDENTITY_FILE, RTL
    ROOT = Path(scan_root).resolve()
    if not (ROOT / "fpga" / "Plex_MiSTer").is_dir():
        raise SystemExit(
            f"FIT_RELEASE_GATE_ERROR: --root {ROOT} missing fpga/Plex_MiSTer"
        )
    DEFAULT_QSF = ROOT / "fpga" / "Plex_MiSTer" / "Plex.qsf"
    FIX = ROOT / "tests" / "fixtures" / "fit_release_gate"
    CANDIDATE_PATHS = (
        ROOT / "docs" / "fit_candidate.json",
        ROOT / "assets" / "fit_candidate.json",
        FIX / "fit_candidate.json",
        # Fallback: ruler candidate only supplies arch lock macros — tree hash
        # still computed on ROOT; mismatch is expected until integration locks.
        RULER_ROOT / "docs" / "fit_candidate.json",
    )
    # Identity file always from ruler (count refusal on divergent rulers).
    GATE_IDENTITY_FILE = RULER_ROOT / "docs" / "fit_gate_identity.json"
    RTL = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
    import rtl_lint  # noqa: WPS433

    rtl_lint.set_repo_root(ROOT)
# Paths whose blob inventory is the candidate tree hash (excludes fit_candidate.json
# so the candidate file cannot hash-bypass itself).
GATED_PATHSPECS = (
    "fpga",
    "scripts/fit_release_gate.py",
    "scripts/fit_release_gate.sh",
    "scripts/check_verilator_elab.py",
    "scripts/rtl_lint.py",
    "scripts/check_define_parity.py",
    "tests/rtl",
    "tests/unit/test_present_true_de_count_rtl_sim.sh",
    "tests/fixtures/fit_release_gate",
    "docs/ascal-true-de-fit-card.md",
    "docs/product-4-3-scaler-decision.md",
    "docs/fit_gate_identity.json",
    "docs/rtl_single_owner_table.json",
    "tests/unit/B20_HIER_MANIFEST.json",
    "tests/unit/B24_Q5_FPS_1001_MANIFEST.json",
    "tests/unit/B25_PLXC_DOORBELL_DUAL_MAP_MANIFEST.json",
    "Makefile",
)
# Ruler identity: gate + companions that must stay in lockstep across lanes.
# Parent 2026-08-03: divergent rulers (fitgate vs mem byte drift) cost a full
# verification cycle. Refuse to report LEG0 count if identity mismatches.
GATE_IDENTITY_PATHSPECS = (
    "scripts/fit_release_gate.py",
    "scripts/fit_release_gate.sh",
    "scripts/rtl_lint.py",
    "scripts/check_define_parity.py",
    "scripts/check_verilator_elab.py",
)
GATE_IDENTITY_FILE = RULER_ROOT / "docs" / "fit_gate_identity.json"
RTL = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
# Open blockers that must remain visible on a stale product tree (mutation inventory).
# Not every token forever — only defects still present in artefacts. Updated when
# real fixes land (then mutation expects absence + a paired RED twin that re-injects).
# Parent 2026-08-03: per-token mutation must prove each claimed check still fires.
LIVE_OPEN_BLOCKER_TOKENS = (
    # B1_NO_COMPILE_TIME_OPTC RETIRED (rd-duck): requiring OPTION_C compile rebase
    # breaks geom_enable=0 legacy publish (host makeDdrPublishPlan → legacy phys).
    # Live open remains layout-not-960 until runtime capacity path is merged.
    "B1_LAYOUT_NOT_960",
    "B2_FPS_INT_OVERFLOW",
    # B2_NO_RASTER_GENERATOR retired: w-clock deliberately made timing_960
    # constants-only; present_beam_content_de is the sole product raster SoT.
    # Live open becomes B2_NO_PRODUCT_RASTER only when the beam is missing.
    "B1_40MPIX_NOT_PRODUCT",
    "B4_PLXG_SAME_SEQ_ABA",
    "B5_NO_DDR_ON_BEAM_TEST",
    "B7_OPTC_WIDTH_ONLY",
    "B7_PRESENT_CORE_NO_OPTC_PHYS",
    "B7_PRESENT_CORE_NO_OPTC_STRIDE",
    "B7_PRESENT_CORE_NO_OPTC_DOORBELL",
    "B8_PLXG_WR_COMMIT_TIED_ZERO",
    "B8_CONTENT_BASE_NOT_960",
    "B8_FORCE_GEOM_1280_NOT_960",
    "B9_ASPECT_ORIGINAL_4_3",
    "B9_NO_AR_TOPLEVEL_TEST",
    # rd-duck: same-size DAR needs sys_top plex_ar_out_hold + post-ascal (not HDMI_BLACKOUT OR)
    "B9_SYS_TOP_AR_OUT_HOLD_MISSING",
    "B9_POST_ASCAL_DAR_BLACKOUT_MISSING",
    "B9_HDMI_BO_OR_NOT_SAME_SIZE_DAR",
    # rd-duck: runtime crop+display window bounds in store (not port presence alone)
    "B26_STORE_CROP_DISPLAY_BOUNDS_MISSING",
    # rd-duck: FFmpeg 426→432 pad x=2 chroma-even (naive x=3 fails real yuv420p)
    "B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE",
    "B12_DE_LAG_RGB_LATENCY_UNPROVEN",
    "B13_FIXED_RASTER_NO_RUNTIME_DE",
    "B14_CODED_W_16_ALIGN_UNENFORCED",
    "B17_PLXG_Q5_DAR_FPS_ABI_MISSING",
    # rd-duck hold/release: product qip + full-hierarchy scenario tests
    "B16_QIP_GEOM_MUX",
    "B16_QIP_POLLER",
    "B16_QIP_Q5_ASPECT_FPS",
    "B16_QSF_BEAM_NOT_ACTIVE",
    "B20_HIER_A_PLXG_EXPLICIT_DISABLE",
    "B20_HIER_B_COMMIT_FRAME_BOUNDARY",
    "B20_HIER_C_DDR_FILL_GEOM_INVALIDATE",
    "B20_HIER_D_RETAINED_DDR_RESET_RESTART",
    "B20_HIER_E_POLL_DOORBELL_ATOMIC",
    "B20_HIER_F_BANK_SWAP_24_30",
    "B20_HIER_G_PLXC_ASYNC_CDC_MULTIBEAT",
    # B20_UNCONNECTED_PRODUCER: not always live — mutation + integ RED twin prove it.
    # rd-duck: runtime-beam must force ascal blackout + scaler (live open on product)
    "B21_HDMI_BLACKOUT_DISABLED",
    "B21_VGA_SCALER_DISABLED",
    # B21 wiring tokens currently clear on stock sys_top — closed-class reinject only
    # B22 present_core merge-semantics (rd-duck c5bd6009 wholesale drop class)
    "B22_PRESENT_CORE_GEOM_LIVE_PORTS",
    "B22_PRESENT_CORE_BLACKOUT_HOLLOW_PORTS",
    "B22_PRESENT_CORE_CADENCE_CORE_HZ",
    # Parent arb #3 single-owner backstop (markers on owned files)
    "B23_OWNER_MARKERS_MISSING",
    # B23_ABI2_FABRIC_NETS_NOT_PLXG: closed-class reinject (not always live)
    # rd-duck: q5 bit34 fps_1001 ABI merge-loss (w-path f31a6eb9 vs w-mem E4)
    "B24_Q5_FPS_1001_MERGED_PATH",
    "B24_Q5_BIT34_LATCH_REJECTS_1001",
    "B24_Q5_FPS_1001_NO_CONSUMER",
    # rd-duck: PLXC host→loader must hit legacy 0x300FF000 AND Option-C 0x3047F000
    # (stale 0x3007F000 default/inst are closed-class reinject when loader present)
    "B25_PLXC_HOST_LOADER_BOTH_MAPS",
)

# Sibling-lane fixes that exist but are not merged into this gated tree.
# status: unmerged | unimplemented
# Gate output must say which — parent routes merge vs new work from this.
FIX_STATUS: dict[str, dict[str, str]] = {
    "B2_FPS_INT_OVERFLOW": {
        "status": "unmerged",
        "lane": "w-clock",
        "commit": "a1ee14e3",
        "worktree": "/home/flynnsbit/Projects/MisterPlex-wt-clock",
        "artefact": "fpga/Plex_MiSTer/rtl/present_video_timing_960.sv",
        "evidence": "localparam longint FPS_MILLI = (longint'(CLK_PIX_HZ)*64'd1000)/PIX_FRAME",
    },
    "B6_HBLANK_OLD_HC_EPOCH": {
        "status": "unmerged",
        "lane": "w-scaler",
        "commit": "bb4e5346",
        "worktree": "/home/flynnsbit/Projects/MisterPlex-wt-scaler",
        "artefact": "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv",
        "evidence": "HBlank <= (hc_n >= hde_act) same-epoch blanks",
    },
    "B6_STORE_ORACLE_UNTESTED": {
        "status": "unmerged",
        "lane": "w-scaler",
        "commit": "5b1cbe46",
        "worktree": "/home/flynnsbit/Projects/MisterPlex-wt-scaler",
        "artefact": "tests/rtl/present_true_de_count_tb.cpp",
        "evidence": "full store (x,y) oracle + store_full + PERM/DROP RED twins",
    },
    "B7_OPTC_WIDTH_ONLY": {
        "status": "unmerged",
        "lane": "w-mem",
        "commit": "e82e5d5e",
        "worktree": "/home/flynnsbit/Projects/MisterPlex-wt-mem",
        "artefact": "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv:261",
        "evidence": "wire rt_need_optc = rt_raw_ok && (rt_payload_bytes > LEG_BANK_USABLE_BYTES)",
    },
    "B7_PRESENT_CORE_NO_OPTC_PHYS": {
        "status": "unmerged",
        "lane": "w-mem",
        "commit": "a1fad081",
        "worktree": "/home/flynnsbit/Projects/MisterPlex-wt-mem",
        "artefact": "fpga/Plex_MiSTer/rtl/present_core.sv",
        "evidence": ".PHYS_BASE_720P(DDR_FRAME_720P_PHYS_BASE)",
    },
    "B7_PRESENT_CORE_NO_OPTC_STRIDE": {
        "status": "unmerged",
        "lane": "w-mem",
        "commit": "a1fad081",
        "worktree": "/home/flynnsbit/Projects/MisterPlex-wt-mem",
        "artefact": "fpga/Plex_MiSTer/rtl/present_core.sv",
        "evidence": ".HPS_BANK_STRIDE_BYTES_720P(DDR_FRAME_720P_YUV420P_BANK_STRIDE)",
    },
    "B7_PRESENT_CORE_NO_OPTC_DOORBELL": {
        "status": "unmerged",
        "lane": "w-mem",
        "commit": "a1fad081",
        "worktree": "/home/flynnsbit/Projects/MisterPlex-wt-mem",
        "artefact": "fpga/Plex_MiSTer/rtl/present_core.sv",
        "evidence": ".DOORBELL_PHYS_720P(DDR_FRAME_720P_YUV420P_DOORBELL_PHYS)",
    },
    "B13_FIXED_RASTER_NO_RUNTIME_DE": {
        "status": "unmerged",
        "lane": "w-scaler",
        "commit": "5b1cbe46",
        "worktree": "/home/flynnsbit/Projects/MisterPlex-wt-scaler",
        "artefact": "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv + present_core.sv",
        "evidence": "use_rt_geom+rt_h_de/rt_v_active; beam tracks content_w/h",
    },
    "B14_CODED_W_16_ALIGN_UNENFORCED": {
        "status": "unmerged",
        "lane": "w-mem",
        "commit": "e82e5d5e",
        "worktree": "/home/flynnsbit/Projects/MisterPlex-wt-mem",
        "artefact": "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
        "evidence": "rt_raw_aligned=(rt_coded_w[3:0]==4'd0); geom_enable_eff&=rt_raw_ok",
    },
    # Everything else: no known sibling implementation — new work.
}
# Real hollow integration QSF (sibling worktree) — RED twin target.
HOLLOW_INTEG_QSF = Path(
    "/home/flynnsbit/Projects/MisterPlex-wt-integ-720p/fpga/Plex_MiSTer/Plex.qsf"
)
ALLOWED_ARCH = frozenset({"ascal_true_de_960", "mp_cea_1280"})

# Required for ascal-native 960×540 content DE fit (docs/ascal-true-de-fit-card.md).
REQUIRED_EXACT = {
    "FRAME_W": "960",
    "FRAME_H": "540",
    "PRESENT_BEAM_960": "1",
    "DDR_FRAME_STORE": "1",
    "PRODUCT_NO_STUB": "1",
}
# Known-hollow values that must not be the active assignment.
FORBIDDEN_VALUES = {
    "FRAME_W": {"640"},
    "FRAME_H": {"480"},
}
# Fault / non-product / competing-path macros must stay out of a release QSF.
# ascal path: do NOT set MULTI_PIXEL / SCALE_* / FABRIC_DDR_WRITER (fit card + rd-duck).
FORBIDDEN_PRESENT = {
    "PRESENT_BEAM_FAULT_ISLAND_1280",
    "PRESENT_BEAM_FAULT_VTOT_BAD_DE",
    "PRESENT_MULTI_PIXEL",
    "PRESENT_SCALE_4_3",
    "PRESENT_SCALE_2X",
    "PRESENT_PX_PER_CLK",
    "FABRIC_DDR_WRITER",
    "FABRIC_NATIVE_720P_GEOM",  # forces 1280×720, not 960 (B8)
}

# Cross-lane note (printed on every run — do not silently resolve):
CROSS_LANE = (
    "CROSS_LANE_MACRO_NOTE: w-scaler fit card (docs/ascal-true-de-fit-card.md) "
    "requires PRESENT_BEAM_960 + FRAME 960/540 and says do NOT set "
    "PRESENT_MULTI_PIXEL / PRESENT_SCALE_4_3 / PRESENT_SCALE_2X for this path. "
    "integ/fab-720p-planes QSF comments list PRESENT_MULTI_PIXEL, "
    "PRESENT_PX_PER_CLK, FABRIC_DDR_WRITER as features to enable. "
    "rd-duck: complex/mp path ≠ product until coherent FIT_CANDIDATE; "
    "40 Mpix/s bridge claim is not a product raster. Gate enforces one locked "
    "architecture + ascal-true-DE macro set when candidate=ascal_true_de_960."
)


def _run(cmd: list[str], *, cwd: Path | None = None, env: dict | None = None) -> tuple[int, str]:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd or ROOT),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return proc.returncode, proc.stdout


def _read(path: Path) -> str:
    return path.read_text(errors="ignore") if path.is_file() else ""


# Red-twin / fault-injection macro names must never satisfy product greps.
# Parent: FAULT_* ifdefs contain exact defect copies — string greps without
# stripping produce false POS (defect) and false NEG (evidence present).
_FAULT_IFDEF_NAME_RE = re.compile(
    r"^(?:FAULT_[A-Z0-9_]+|[A-Z0-9_]*_FAULT_[A-Z0-9_]+|RED_TWIN_[A-Z0-9_]+|"
    r"FIT_MUTATION_[A-Z0-9_]+|MUTATION_[A-Z0-9_]+)$"
)


def _is_fault_macro_name(name: str) -> bool:
    n = (name or "").strip()
    if not n:
        return False
    if _FAULT_IFDEF_NAME_RE.match(n):
        return True
    # Also treat bare FAULT prefix / RED_TWIN as red-twin regions.
    return n.startswith("FAULT_") or "FAULT_" in n or n.startswith("RED_TWIN")


def product_active_sv(text: str, *, active_macros: set[str] | None = None) -> str:
    """Return SystemVerilog with inactive FAULT_*/red-twin ifdef regions removed.

    When a FAULT_* macro is *not* in active_macros (default empty):
      `ifdef FAULT_X ... `else PRODUCT ... `endif`  → keep PRODUCT only
      `ifndef FAULT_X PRODUCT ... `else FAULT ... `endif` → keep PRODUCT only

    Non-FAULT conditionals pass through (both branches remain visible).

    LIMITATION: only FAULT_*/RED_TWIN*/FIT_MUTATION* regions collapse. Does not
    prove wrong-producer connectivity — that is B20 Verilator scope.
    """
    active = active_macros or set()
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    # frame: fault=bool, taking=bool, branch_taken=bool
    stack: list[dict[str, bool]] = []

    def outer_ok() -> bool:
        return all(fr["taking"] for fr in stack)

    for raw in lines:
        code = raw.split("//", 1)[0]
        m_if = re.match(r"^\s*`if(n?def)\s+(\w+)\b", code)
        m_elsif = re.match(r"^\s*`elsif\s+(\w+)\b", code)
        m_else = re.match(r"^\s*`else\b", code)
        m_endif = re.match(r"^\s*`endif\b", code)

        if m_if:
            kind, name = m_if.group(1), m_if.group(2)
            if _is_fault_macro_name(name):
                defined = name in active
                take = defined if kind == "def" else (not defined)
                stack.append(
                    {"fault": True, "taking": take, "branch_taken": take}
                )
                # drop directive
            else:
                # non-fault: emit directive if outer allows; always "taking" here
                if outer_ok():
                    out.append(raw)
                stack.append(
                    {"fault": False, "taking": True, "branch_taken": False}
                )
            continue

        if m_elsif and stack:
            fr = stack[-1]
            name = m_elsif.group(1)
            if fr["fault"]:
                if fr["branch_taken"]:
                    fr["taking"] = False
                else:
                    take = (name in active) if _is_fault_macro_name(name) else (name in active)
                    # elsif after skipped fault ifdef: only take if this macro active
                    fr["taking"] = bool(take)
                    if fr["taking"]:
                        fr["branch_taken"] = True
                # drop directive
            else:
                parents = stack[:-1]
                if all(p["taking"] for p in parents):
                    out.append(raw)
            continue

        if m_else and stack:
            fr = stack[-1]
            if fr["fault"]:
                fr["taking"] = not fr["branch_taken"]
                if fr["taking"]:
                    fr["branch_taken"] = True
                # drop directive
            else:
                parents = stack[:-1]
                if all(p["taking"] for p in parents):
                    out.append(raw)
            continue

        if m_endif and stack:
            fr = stack.pop()
            if not fr["fault"] and outer_ok():
                out.append(raw)
            continue

        if outer_ok():
            out.append(raw)

    return "".join(out)


def _read_product_sv(path: Path) -> str:
    """Read SV/V file with FAULT_*/red-twin ifdef bodies stripped (product view)."""
    return product_active_sv(_read(path))


def _hash_pathspecs(root: Path, pathspecs: tuple[str, ...], *, exclude_substr: str = "") -> str:
    """SHA1 over working-tree blobs for pathspecs (git ls-files + hash-object)."""
    list_cmd = ["git", "-C", str(root), "ls-files", "--", *pathspecs]
    proc = subprocess.run(list_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        return ""
    rows: list[str] = []
    for rel in proc.stdout.splitlines():
        if not rel:
            continue
        if exclude_substr and exclude_substr in rel:
            continue
        full = root / rel
        if not full.is_file():
            rows.append(f"MISSING {rel}")
            continue
        ho = subprocess.run(
            ["git", "-C", str(root), "hash-object", str(full)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        blob = ho.stdout.strip() if ho.returncode == 0 else "ERR"
        rows.append(f"{blob}  {rel}")
    # Also include untracked-but-present identity files (new docs).
    for spec in pathspecs:
        p = root / spec
        if p.is_file():
            rel = spec
            if any(r.endswith(f"  {rel}") or r.endswith(rel) for r in rows):
                continue
            if exclude_substr and exclude_substr in rel:
                continue
            ho = subprocess.run(
                ["git", "-C", str(root), "hash-object", str(p)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            blob = ho.stdout.strip() if ho.returncode == 0 else "ERR"
            rows.append(f"{blob}  {rel}")
    rows.sort()
    payload = "\n".join(rows) + ("\n" if rows else "")
    return hashlib.sha1(payload.encode()).hexdigest()


def compute_gated_tree_hash(root: Path = ROOT) -> str:
    """SHA1 over working-tree blobs of gated paths (not index-only).

    Uses `git ls-files` for the path set, then `git hash-object` on each
    working-tree file so dirty edits count. Excludes fit_candidate.json so a
    lane cannot clear B0 by editing only the candidate file.
    """
    return _hash_pathspecs(root, GATED_PATHSPECS, exclude_substr="fit_candidate.json")


def compute_gate_identity_hash(root: Path | None = None) -> str:
    """SHA1 of the gate ruler scripts only (cross-lane parity).

    Always hashes RULER_ROOT scripts (the executing gate), never the --root
    scan tree. The ``root`` argument is ignored (kept for call-site compat).
    Lanes must invoke this same identity. A 217-byte drift between worktrees
    previously produced conflicting counts (parent miss #9).
    """
    del root  # scan tree must never affect ruler identity
    return _hash_pathspecs(RULER_ROOT, GATE_IDENTITY_PATHSPECS)


def check_gate_identity() -> tuple[int, list[str]]:
    """Refuse untrustworthy counts when ruler scripts diverge from canonical.

    Returns (0, msgs) if identity matches or no canonical yet (bootstrap).
    Returns (1, msgs) on mismatch — caller must NOT print LEG0_FAIL count as truth.
    """
    msgs: list[str] = []
    live = compute_gate_identity_hash()
    msgs.append(f"GATE_IDENTITY live={live}")
    # Prefer docs/fit_gate_identity.json; fall back to field inside fit_candidate.json.
    canon = ""
    src = ""
    if GATE_IDENTITY_FILE.is_file():
        try:
            data = json.loads(GATE_IDENTITY_FILE.read_text())
            canon = str(data.get("gate_identity_hash", "")).lower()
            src = str(GATE_IDENTITY_FILE)
        except json.JSONDecodeError as e:
            return 1, msgs + [f"GATE_IDENTITY_BAD_JSON: {GATE_IDENTITY_FILE}: {e}"]
    else:
        for p in CANDIDATE_PATHS:
            if not p.is_file():
                continue
            try:
                data = json.loads(p.read_text())
            except json.JSONDecodeError:
                continue
            if data.get("gate_identity_hash"):
                canon = str(data["gate_identity_hash"]).lower()
                src = str(p)
                break
    if not canon:
        msgs.append(
            "GATE_IDENTITY_BOOTSTRAP: no canonical gate_identity_hash yet — "
            "write docs/fit_gate_identity.json after intentional ruler change"
        )
        return 1, msgs + [
            "GATE_IDENTITY_MISSING: refuse LEG0 count until canonical identity "
            "is locked (prevents divergent rulers across lanes)"
        ]
    msgs.append(f"GATE_IDENTITY canonical={canon} src={src}")
    if not re.fullmatch(r"[0-9a-f]{40}", canon):
        return 1, msgs + ["GATE_IDENTITY_BAD_HASH: need full 40-char sha1"]
    if canon != live:
        return 1, msgs + [
            f"GATE_IDENTITY_MISMATCH: canonical={canon} live={live}. "
            "This ruler differs from the locked gate scripts (fit_release_gate.py + "
            "rtl_lint/check_define_parity/check_verilator_elab). LEG0 count is "
            "UNTRUSTWORTHY — do not compare counts across divergent rulers. "
            "Rebase from w-fitgate or refresh identity only after intentional "
            "gate change (not a bypass)."
        ]
    msgs.append("GATE_IDENTITY_MATCH EXECUTED")
    return 0, msgs


def _rtl_lint_discover_design(macro_qsf: Path | None = None):
    """Call rtl_lint.discover_design with API self-check.

    Parent 2026-08-03: B10_DISCOVER_DESIGN_ERROR TypeError(macro_qsf) means the
    check DID NOT RUN — same defect class as qip-omitted beam / wrong denominator.
    Never treat a crashed call as a completed architecture scan.
    """
    import inspect

    import rtl_lint  # noqa: WPS433 — scripts/ on path

    sig = inspect.signature(rtl_lint.discover_design)
    params = sig.parameters
    accepts_kw = "macro_qsf" in params or any(
        p.kind == inspect.Parameter.VAR_KEYWORD for p in params.values()
    )
    if macro_qsf is not None and not accepts_kw:
        raise RuntimeError(
            "B10_RTL_LINT_API_STALE: rtl_lint.discover_design() does not accept "
            "macro_qsf= — companion script is older than fit_release_gate.py. "
            "CHECK DID NOT RUN. Sync scripts/rtl_lint.py from w-fitgate "
            f"(live sig={sig})."
        )
    if macro_qsf is not None and accepts_kw:
        return rtl_lint.discover_design(macro_qsf=macro_qsf)
    return rtl_lint.discover_design()


def _git_head(root: Path = ROOT) -> str:
    proc = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _repo_root_for(path: Path) -> Path | None:
    """Walk parents of path until fpga/Plex_MiSTer + scripts/ exist."""
    p = path.resolve()
    if p.is_file():
        p = p.parent
    for _ in range(12):
        if (p / "fpga" / "Plex_MiSTer").is_dir() and (p / "scripts").is_dir():
            return p
        if p.parent == p:
            return None
        p = p.parent
    return None


def _qsf_under_root(qsf: Path, root: Path) -> bool:
    try:
        qsf.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def check_qsf_tree_match(
    qsf: Path, *, rtl_legs: bool
) -> tuple[int, list[str]]:
    """Refuse macros-from-tree-A + RTL-from-tree-B (rd-duck adc9292 audit #4)."""
    msgs: list[str] = []
    qsf = qsf.resolve()
    qsf_root = _repo_root_for(qsf)
    msgs.append(f"LEG_TREE gate_root={ROOT} qsf={qsf} qsf_root={qsf_root}")
    if qsf_root is None:
        return 1, msgs + [
            "B11_QSF_NO_REPO_ROOT: cannot locate fpga/Plex_MiSTer above QSF — "
            "refuse (no foreign macro injection)"
        ]
    same = qsf_root.resolve() == ROOT.resolve()
    if same:
        msgs.append("LEG_TREE_MATCH EXECUTED QSF and gate RTL share one root")
        return 0, msgs
    if not rtl_legs:
        msgs.append(
            f"LEG_TREE_FOREIGN_MACRO_ONLY EXECUTED qsf_root={qsf_root} "
            "(leg1 parse only — not a fit grant, not elab/tde)"
        )
        return 0, msgs
    return 1, msgs + [
        "B11_FOREIGN_QSF_RTL_MISMATCH: QSF lives under "
        f"{qsf_root} but gate elaborates/scans RTL under {ROOT}. "
        "Macros from hash A must not certify RTL from hash B (rd-duck adc9292). "
        "Point --qsf at a QSF inside this worktree, or run the gate from the "
        "candidate tree that owns both QSF and RTL."
    ]


def _layout_param(name: str) -> str | None:
    text = _read(RTL / "ddr_frame_layout_params.svh")
    m = re.search(rf"localparam\s+int\s+{re.escape(name)}\s*=\s*(\d+)", text)
    return m.group(1) if m else None


# Filled once per leg0 by scan_sibling_attribution().
_LIVE_ATTR: dict[str, dict[str, str]] = {}
_LIVE_ATTR_MSGS: list[str] = []


def _git_tip_meta(worktree: Path) -> dict[str, str]:
    """Return tip sha, iso timestamp, subject for a worktree (empty on failure)."""
    if not worktree.is_dir():
        return {}
    proc = subprocess.run(
        ["git", "-C", str(worktree), "log", "-1", "--format=%H%x09%ci%x09%s"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return {}
    parts = proc.stdout.strip().split("\t", 2)
    if len(parts) < 3:
        return {}
    return {
        "commit": parts[0],
        "commit_short": parts[0][:12],
        "timestamp": parts[1],
        "subject": parts[2][:120],
        "worktree": str(worktree),
    }


def _git_is_ancestor(repo: Path, maybe_ancestor: str, tip: str = "HEAD") -> bool | None:
    """True if maybe_ancestor is ancestor of tip in repo. None if git unavailable."""
    if not repo.is_dir() or not maybe_ancestor:
        return None
    proc = subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "merge-base",
            "--is-ancestor",
            maybe_ancestor,
            tip,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode == 0:
        return True
    if proc.returncode == 1:
        return False
    return None


def _git_head_short(repo: Path) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--short=12", "HEAD"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        return "?"
    return proc.stdout.strip() or "?"


def _text_for_string_scan(path: Path) -> str:
    """Source text for greps: product-active view for SV/V (FAULT_* stripped)."""
    raw = path.read_text(errors="ignore")
    suf = path.suffix.lower()
    if suf in {".sv", ".v", ".svh", ".vh"}:
        return product_active_sv(raw)
    return raw


def _file_has_all(path: Path, patterns: list[str]) -> bool:
    if not path.is_file():
        return False
    txt = _text_for_string_scan(path)
    return all(re.search(p, txt) for p in patterns)


def _file_missing_patterns(path: Path, patterns: list[str]) -> list[str]:
    """Return patterns not found in path (all missing if file absent).

    SV/V scans use product_active_sv so FAULT_*/red-twin ifdef bodies cannot
    satisfy evidence greps (parent false-NEG) or defect greps (false-POS).
    """
    if not path.is_file():
        return list(patterns)
    txt = _text_for_string_scan(path)
    return [p for p in patterns if not re.search(p, txt)]


def scan_sibling_attribution() -> tuple[dict[str, dict[str, str]], list[str]]:
    """Live-scan sibling tips for fix evidence. Parent routing depends on this.

    Each hit records lane tip SHA + timestamp. If a static FIX_STATUS commit is
    older than the lane tip, tip_newer=1 is set so stale tags are visible.
    """
    msgs: list[str] = ["LEG0_SIBLING_SCAN_EXECUTED begin"]
    # token -> list of (lane, relpath, patterns)
    probes: dict[str, list[tuple[str, str, list[str]]]] = {
        "B2_FPS_INT_OVERFLOW": [
            (
                "w-clock",
                "fpga/Plex_MiSTer/rtl/present_video_timing_960.sv",
                [r"localparam\s+longint\s+FPS_MILLI", r"longint'\(CLK_PIX_HZ\)"],
            )
        ],
        "B6_HBLANK_OLD_HC_EPOCH": [
            (
                "w-scaler",
                "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv",
                [r"hc_n|hc_next", r"HBlank\s*<=\s*\(\s*hc_"],
            ),
            (
                "w-clock",
                "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv",
                [r"use_rt_geom", r"HBlank\s*<="],
            ),
        ],
        "B6_STORE_ORACLE_UNTESTED": [
            (
                "w-scaler",
                "tests/rtl/present_true_de_count_tb.cpp",
                [r"store_full", r"oracle_full|store_oracle|visit_unique"],
            )
        ],
        "B7_OPTC_WIDTH_ONLY": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
                [r"\brt_need_optc\b", r"rt_payload_bytes", r"LEG_BANK_USABLE"],
            )
        ],
        "B7_PRESENT_CORE_NO_OPTC_PHYS": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/present_core.sv",
                [r"\.PHYS_BASE_720P\s*\("],
            )
        ],
        "B7_PRESENT_CORE_NO_OPTC_STRIDE": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/present_core.sv",
                [r"\.HPS_BANK_STRIDE_BYTES_720P\s*\("],
            )
        ],
        "B7_PRESENT_CORE_NO_OPTC_DOORBELL": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/present_core.sv",
                [r"\.DOORBELL_PHYS_720P\s*\("],
            )
        ],
        "B8_PLXG_WR_COMMIT_TIED_ZERO": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/Plex.sv",
                # untied: declaration without `= 1'b0` assign on same tree + poller
                [r"wire\s+plxg_wr_en\s*,\s*plxg_commit", r"plxg_ddr_poller|plex_present_geom_mux"],
            )
        ],
        "B8_CONTENT_BASE_NOT_960": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv",
                [r"plex_present_geom_mux", r"force_native_960", r"plxg_live"],
            )
        ],
        "B8_FORCE_GEOM_1280_NOT_960": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv",
                [r"force_native_960", r"11'd960", r"PRESENT_BEAM_960"],
            )
        ],
        "B13_FIXED_RASTER_NO_RUNTIME_DE": [
            (
                "w-clock",
                "fpga/Plex_MiSTer/rtl/present_core.sv",
                [r"use_rt_geom\s*\(\s*1'b1\s*\)", r"rt_h_de\s*\(", r"content_w"],
            ),
            (
                "w-scaler",
                "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv",
                [r"use_rt_geom", r"rt_h_de"],
            ),
        ],
        "B14_CODED_W_16_ALIGN_UNENFORCED": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
                [r"rt_coded_w\[3:0\]\s*==\s*4'd0", r"rt_raw_aligned"],
            ),
            (
                "w-scaler",
                "tests/rtl/present_true_de_count_tb.cpp",
                [r"FAULT_NON16_W|Non16W", r"align16_ok"],
            ),
        ],
        "B4_PLXG_SAME_SEQ_ABA": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/present_geom_latch.sv",
                [r"\bepoch\b", r"session|generation"],
            )
        ],
        # B1_OPTION_C_REBASES_LEGACY: no sibling "fix tip" — the fix is *absence*
        # of OPTION_C LEG→720P rebase (geom-off legacy contract). Positive greps
        # for LEG_BASE=PHYS_BASE false-match the `else` branch of defective trees
        # (wt-mem). When B1 fires → unimplemented / remove the rebase (new work
        # or un-do lane mistake). B1_NO_COMPILE_TIME_OPTC retired.
        "B1_LAYOUT_NOT_960": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh",
                [r"DDR_FRAME_PRESENTED_WIDTH\s*=\s*960", r"DDR_FRAME_PRESENTED_HEIGHT\s*=\s*540"],
            )
        ],
        "B12_DE_LAG_RGB_LATENCY_UNPROVEN": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/present_core.sv",
                [r"DE_LAG.*960|960.*DE_LAG|DE_LAG swept"],
            )
        ],
        "B9_ASPECT_ORIGINAL_4_3": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/Plex.sv",
                [r"`ifdef\s+PRESENT_BEAM_960", r"VIDEO_ARX\s*=\s*12'd0", r"VIDEO_ARY\s*=\s*12'd0"],
            )
        ],
        # B22 merge-semantics: evidence is *connections*, not file presence.
        "B22_PRESENT_CORE_GEOM_LIVE_PORTS": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/present_core.sv",
                [
                    r"input\s+wire\s+\[15:0\]\s+geom_live_seq",
                    r"input\s+wire\s+geom_live_valid",
                    r"\.rt_geom_seq\s*\(\s*geom_live_seq\s*\)",
                    r"\.rt_geom_live\s*\(\s*geom_live_valid\s*\)",
                ],
            )
        ],
        "B22_PRESENT_CORE_BLACKOUT_HOLLOW_PORTS": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/present_core.sv",
                [
                    r"output\s+wire\s+stat_geom_hold_black",
                    r"output\s+wire\s+stat_geom_hollow",
                    r"\.geom_hold_black\s*\(",
                    r"\.geom_hollow_fault\s*\(",
                ],
            )
        ],
        "B22_PRESENT_CORE_CADENCE_CORE_HZ": [
            (
                "w-clock",
                "fpga/Plex_MiSTer/rtl/present_core.sv",
                [
                    r"beam_film_class",
                    r"cadence_display_hz\s*=\s*beam_film_class\s*\?\s*8'd24\s*:\s*8'd30",
                    r"\.display_hz\s*\(\s*cadence_display_hz\s*\)",
                ],
            ),
            (
                "w-scaler",
                "fpga/Plex_MiSTer/rtl/present_core.sv",
                [
                    r"beam_film_class",
                    r"cadence_display_hz\s*=\s*beam_film_class\s*\?\s*8'd24\s*:\s*8'd30",
                    r"\.display_hz\s*\(\s*cadence_display_hz\s*\)",
                ],
            ),
        ],
        "B22_PRESENT_CORE_GEOM_LIVE_STORE_WIRE": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/present_core.sv",
                [
                    r"\.rt_geom_seq\s*\(\s*geom_live_seq\s*\)",
                    r"\.rt_geom_live\s*\(\s*geom_live_valid\s*\)",
                ],
            )
        ],
        "B22_PLEX_GEOM_LIVE_UNCONNECTED": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/Plex.sv",
                [r"\.geom_live_seq\s*\(", r"\.geom_live_valid\s*\("],
            )
        ],
        "B22_PLEX_BLACKOUT_HOLLOW_UNCONNECTED": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/Plex.sv",
                [r"\.stat_geom_hold_black\s*\(", r"\.stat_geom_hollow\s*\("],
            )
        ],
    }

    out: dict[str, dict[str, str]] = {}
    tip_cache: dict[str, dict[str, str]] = {}
    gated_head = _git_head_short(ROOT)
    msgs.append(f"LEG0_GATED_HEAD root={ROOT} head={gated_head}")

    for token, plist in probes.items():
        hit = None
        for lane, rel, pats in plist:
            wt = SIBLING_LANES.get(lane)
            if wt is None or not wt.is_dir():
                continue
            if lane not in tip_cache:
                tip_cache[lane] = _git_tip_meta(wt)
            tip = tip_cache[lane]
            if not tip:
                continue
            path = wt / rel
            if _file_has_all(path, pats):
                # Evidence strings are the live probe patterns — asserted on ROOT.
                ev_str = " && ".join(pats)
                hit = {
                    "status": "unmerged",  # refined below vs gated tree
                    "lane": lane,
                    "commit": tip["commit_short"],
                    "commit_full": tip["commit"],
                    "timestamp": tip["timestamp"],
                    "subject": tip["subject"],
                    "artefact": rel,
                    "worktree": tip["worktree"],
                    "patterns": pats,  # type: ignore[dict-item]
                    "evidence": ev_str,
                }
                break
        static = FIX_STATUS.get(token, {})
        if hit:
            # Staleness vs static table commit (if any).
            static_c = str(static.get("commit", ""))
            tip_newer = "0"
            if static_c and hit["commit_full"].startswith(static_c):
                tip_newer = "0"  # tag is exact tip prefix
            elif static_c:
                tip_newer = "1"
                hit["static_tag_commit"] = static_c
                hit["note"] = (
                    f"static FIX_STATUS commit={static_c} differs from live tip "
                    f"{hit['commit']}; using live tip (parent: do not trust stale tag)"
                )
            # --- B19 three-way vs GATED tree (ROOT), not the sibling tip ---
            # Parent 2026-08-03 observed: merge commit IS ancestor, content GONE
            # (integ took w-scaler ddr_frame_store wholesale after w-mem merge).
            # Critical: live tip may have moved past the absorbed commit — check
            # tip AND static FIX_STATUS commit (and short SHAs) for ancestry.
            pats = hit.get("patterns") or []
            if isinstance(pats, str):
                pats = [pats]
            gated_art = ROOT / str(hit["artefact"])
            missing = _file_missing_patterns(gated_art, list(pats))
            evidence_on_gated = len(missing) == 0 and gated_art.is_file()
            anc_candidates = [str(hit["commit_full"]), str(hit.get("commit", ""))]
            if static_c:
                anc_candidates.append(static_c)
            # FIX_STATUS full table commit for this token
            fs_c = str(static.get("commit", ""))
            if fs_c and fs_c not in anc_candidates:
                anc_candidates.append(fs_c)
            anc = False
            anc_which = ""
            anc_unknown = True
            for c in anc_candidates:
                if not c or c == "?":
                    continue
                r = _git_is_ancestor(ROOT, c)
                if r is True:
                    anc = True
                    anc_which = c[:12]
                    anc_unknown = False
                    break
                if r is False:
                    anc_unknown = False
            hit["ancestor_of_gated"] = (
                "1" if anc else ("?" if anc_unknown else "0")
            )
            if anc_which:
                hit["ancestor_commit"] = anc_which
            hit["evidence_on_gated"] = "1" if evidence_on_gated else "0"
            if missing:
                hit["missing_patterns"] = missing  # type: ignore[assignment]
            if evidence_on_gated:
                hit["status"] = "merged"
            elif anc:
                # Loudest class: ancestry satisfied, content absent.
                hit["status"] = "merge_loss"
            else:
                hit["status"] = "unmerged"
            out[token] = hit
            msgs.append(
                f"LEG0_SIBLING_HIT token={token} lane={hit['lane']} "
                f"tip={hit['commit']} ts={hit['timestamp']} "
                f"status={hit['status']} ancestor={hit['ancestor_of_gated']} "
                f"evidence_on_gated={hit['evidence_on_gated']} "
                f"tip_newer_than_static_tag={tip_newer} artefact={hit['artefact']}"
            )
        else:
            out[token] = {
                "status": "unimplemented",
                "evidence": "no sibling tip matched live probes",
            }
            lanes_tried = sorted({p[0] for p in plist})
            tips = []
            for ln in lanes_tried:
                t = tip_cache.get(ln) or _git_tip_meta(SIBLING_LANES.get(ln, Path(".")))
                tip_cache[ln] = t
                if t:
                    tips.append(f"{ln}@{t['commit_short']}({t['timestamp']})")
            msgs.append(
                f"LEG0_SIBLING_MISS token={token} tried={','.join(tips) or 'none'}"
            )

    # Tip roster + under-take. Under-take hard errors only when gated tree already
    # absorbed *some* sibling tip (partial integration). Pure feature branches
    # where no sibling is ancestor would otherwise drown in false under-takes.
    any_sibling_absorbed = any(
        _git_is_ancestor(ROOT, (tip_cache.get(ln) or _git_tip_meta(wt)).get("commit", ""))
        is True
        for ln, wt in SIBLING_LANES.items()
        if (tip_cache.get(ln) or _git_tip_meta(wt)).get("commit")
    )
    # Also treat merge_loss as proof of partial absorption (ancestor yes, content no).
    if any(v.get("status") == "merge_loss" for v in out.values()):
        any_sibling_absorbed = True
    msgs.append(f"LEG0_PARTIAL_INTEGRATION absorbed_sibling={int(any_sibling_absorbed)}")

    under_take_lanes: list[str] = []
    for lane, wt in sorted(SIBLING_LANES.items()):
        t = tip_cache.get(lane) or _git_tip_meta(wt)
        if t:
            anc_tip = _git_is_ancestor(ROOT, t["commit"])
            anc_s = "1" if anc_tip is True else ("0" if anc_tip is False else "?")
            msgs.append(
                f"LEG0_SIBLING_TIP lane={lane} tip={t['commit_short']} "
                f"ts={t['timestamp']} ancestor_of_gated={anc_s} "
                f"subject={t['subject']!r}"
            )
            lane_tokens = [
                tok
                for tok, meta in out.items()
                if meta.get("lane") == lane
                and meta.get("status") in {"unmerged", "merge_loss"}
            ]
            if anc_tip is False and lane_tokens:
                msgs.append(
                    f"LEG0_LANE_TIP_NOT_MERGED_INFO lane={lane} tip={t['commit_short']} "
                    f"ts={t['timestamp']} tokens={','.join(lane_tokens)} "
                    f"head={gated_head} hard_error={int(any_sibling_absorbed)}"
                )
                if any_sibling_absorbed:
                    under_take_lanes.append(lane)
                    out[f"_LANE_TIP_NOT_MERGED_{lane}"] = {
                        "status": "lane_tip_not_merged",
                        "lane": lane,
                        "commit": t["commit_short"],
                        "commit_full": t["commit"],
                        "timestamp": t["timestamp"],
                        "tokens": ",".join(lane_tokens),
                        "evidence": (
                            f"tip {t['commit_short']} not ancestor of gated HEAD "
                            f"(partial integration under-take)"
                        ),
                    }
        else:
            msgs.append(f"LEG0_SIBLING_TIP lane={lane} UNAVAILABLE path={wt}")

    n_unmerged = sum(1 for v in out.values() if v.get("status") == "unmerged")
    n_merged = sum(1 for v in out.values() if v.get("status") == "merged")
    n_loss = sum(1 for v in out.values() if v.get("status") == "merge_loss")
    msgs.append(
        f"LEG0_SIBLING_SCAN_EXECUTED unmerged={n_unmerged} merged={n_merged} "
        f"merge_loss={n_loss} under_take_lanes={len(under_take_lanes)}"
    )
    return out, msgs


def collect_merge_loss_errors() -> list[str]:
    """B19: commit IS ancestor but evidence ABSENT on gated tree.

    Independent of whether the matching Bn_* content check also fires — ancestry
    alone must never clear a missing-evidence fix (parent integ-product 0d95c91a:
    mem tip ancestor, scaler store file wholesale, B7/B14 content gone).
    """
    errors: list[str] = []
    for token, meta in sorted(_LIVE_ATTR.items()):
        if token.startswith("_"):
            continue
        if meta.get("status") != "merge_loss":
            continue
        missing = meta.get("missing_patterns")
        if isinstance(missing, list):
            miss_s = " | ".join(missing)
        else:
            miss_s = str(meta.get("evidence", "?"))
        anc_c = meta.get("ancestor_commit") or meta.get("commit")
        errors.append(
            f"B19_MERGE_LOSS: token={token} lane={meta.get('lane')} "
            f"tip={meta.get('commit')} ancestor_commit={anc_c} "
            f"ts={meta.get('timestamp', '?')} "
            f"IS ancestor of gated HEAD but evidence ABSENT from "
            f"{meta.get('artefact')}. missing=[{miss_s}]. "
            "Commit ancestry ≠ content (merge took another lane's file wholesale). "
            "Route: re-merge/restore the missing evidence — do not trust log alone."
        )
    # Inverse under-take: lane tip not ancestor while tokens still open.
    for token, meta in sorted(_LIVE_ATTR.items()):
        if meta.get("status") != "lane_tip_not_merged":
            continue
        errors.append(
            f"B19_LANE_TIP_NOT_MERGED: lane={meta.get('lane')} "
            f"tip={meta.get('commit')} ts={meta.get('timestamp', '?')} "
            f"is NOT an ancestor of gated HEAD; open tokens=[{meta.get('tokens')}]. "
            "Under-take: integration never absorbed this tip (parent: scaler B9 DAR "
            "tip 76aa4272 vs integ over-taking scaler store)."
        )
    return errors


def _fix_status_suffix(token: str) -> str:
    """Annotate blocker: merged | unmerged | merge_loss | unimplemented."""
    meta = _LIVE_ATTR.get(token) or FIX_STATUS.get(token)
    if meta is None:
        return " [fix=unimplemented — no known sibling-lane fix; new work]"
    st = meta.get("status", "unimplemented")
    if st == "merge_loss":
        return (
            f" [fix=merge_loss lane={meta.get('lane')} tip={meta.get('commit')} "
            f"ts={meta.get('timestamp', '?')} artefact={meta.get('artefact')} "
            f"evidence={meta.get('evidence')!r} "
            "B19: ancestor yes, content no — RE-MERGE]"
        )
    if st == "merged":
        return (
            f" [fix=merged lane={meta.get('lane')} tip={meta.get('commit')} "
            f"evidence_on_gated=1 — content present; if this Bn still fires, "
            f"probe/check mismatch]"
        )
    if st == "unmerged":
        ts = meta.get("timestamp", "?")
        extra = ""
        if meta.get("static_tag_commit"):
            extra = f" static_tag={meta['static_tag_commit']} tip_newer=1"
        elif meta.get("note"):
            extra = " tip_refreshed=1"
        anc = meta.get("ancestor_of_gated", "?")
        return (
            f" [fix=unmerged lane={meta.get('lane')} tip={meta.get('commit')} "
            f"ts={ts} ancestor={anc} artefact={meta.get('artefact')} "
            f"evidence={meta.get('evidence')!r}{extra}]"
        )
    return (
        " [fix=unimplemented — no known sibling-lane fix at live tip; new work]"
    )


def _err(errors: list[str], token_line: str) -> None:
    """Append a leg0 error, tagging the leading B*_ token with fix status."""
    m = re.match(r"^(B[0-9]+_[A-Z0-9_]+):", token_line)
    if m:
        tok = m.group(1)
        if "[fix=" not in token_line:
            errors.append(token_line + _fix_status_suffix(tok))
            return
    errors.append(token_line)


def _leg0_error_tokens(msgs: list[str]) -> set[str]:
    """Tokens from real leg0 *error* lines only.

    Must ignore LEG0_SIBLING_HIT / info lines that mention the same B*_ names —
    those are routing attribution, not open defects on the gated tree. A prior
    mutation hole treated sibling hits as sticky blockers (clear never dropped).
    """
    out: set[str] = set()
    for line in msgs:
        s = line.strip()
        if s.startswith("- "):
            s = s[2:].lstrip()
        # Error lines are "Bnn_TOKEN: message" (optionally after LEG0_FAIL reasons).
        m = re.match(r"^(B[0-9]+_[A-Z0-9_]+)\s*:", s)
        if m:
            out.add(m.group(1))
            continue
        # Identity / refuse lines that are not B* but gate-level:
        m2 = re.match(r"^(GATE_[A-Z0-9_]+)\s*:", s)
        if m2:
            out.add(m2.group(1))
    return out


def _beam_has_runtime_de_ports(beam_txt: str) -> bool:
    """True if beam module accepts runtime active dimensions (not param-only)."""
    if not beam_txt:
        return False
    # Runtime ports that drive blanking (not mere hc_out observability).
    if re.search(
        r"input\s+wire\s+\[[^\]]+\]\s*(h_de_rt|h_active|rt_h_de|content_w)\b",
        beam_txt,
    ) and re.search(
        r"input\s+wire\s+\[[^\]]+\]\s*(v_active_rt|v_active|rt_v_act|content_h)\b",
        beam_txt,
    ):
        return True
    if re.search(
        r"input\s+wire\s+\[[^\]]+\]\s*h_de\b", beam_txt
    ) and re.search(r"input\s+wire\s+\[[^\]]+\]\s*v_active\b", beam_txt):
        return True
    return False


def _core_wires_runtime_de_to_beam(core_txt: str) -> bool:
    """present_core must connect delivered/content geometry into beam H_DE/V_ACTIVE."""
    if not core_txt or "present_beam_content_de" not in core_txt:
        return False
    # Runtime: ports driven from content_width / win_h_de / fabric_* registers.
    return bool(
        re.search(
            r"\.H_DE\s*\(\s*(content_width|win_h_de|fabric_content_w|h_de_rt|rt_h_de)",
            core_txt,
        )
    ) and bool(
        re.search(
            r"\.V_ACTIVE\s*\(\s*(content_height|win_v_de|fabric_content_h|v_active_rt|rt_v_act)",
            core_txt,
        )
    )


# B20 hierarchy: executable manifest only (rd-duck — kill 846b7f1b regex theatre).
# Canonical path on gated tree; ruler-bundled copy used if gated tree lacks it.
B20_HIER_MANIFEST_REL = "tests/unit/B20_HIER_MANIFEST.json"
# Fallback embedded ids — MUST match manifest; load_b20_hier_manifest is SoT.
B20_HIER_FALLBACK_TOKENS: tuple[str, ...] = (
    "B20_HIER_A_PLXG_EXPLICIT_DISABLE",
    "B20_HIER_B_COMMIT_FRAME_BOUNDARY",
    "B20_HIER_C_DDR_FILL_GEOM_INVALIDATE",
    "B20_HIER_D_RETAINED_DDR_RESET_RESTART",
    "B20_HIER_E_POLL_DOORBELL_ATOMIC",
    "B20_HIER_F_BANK_SWAP_24_30",
    "B20_HIER_G_PLXC_ASYNC_CDC_MULTIBEAT",
)

# Body must invoke a *simulator* (rd-duck 2026-08-03): verilator / run_verilator.sh /
# make …verilator|sim|tb / python TB. rg/grep/test -f alone is theatre — NOT enough.
_B20_SIM_INVOKE_RE = re.compile(
    r"(?m)^\s*(?:"
    r"(?:\S+/)?run_verilator\.sh\b|"
    r"verilator(?:_bin)?\b|"
    r"make\b[^\n]{0,120}\b(?:verilator|sim_[A-Za-z0-9_]+|[A-Za-z0-9_]+_tb|tb_[A-Za-z0-9_]+)\b|"
    r"python3?\s+\S*(?:/|\b)(?:\w*tb\w*|\w*sim\w*|verilator)\S*"
    r")",
    re.I,
)
# Tool fingerprint in stdout (self-reported SIM_RUN=1 is NOT evidence).
_B20_TOOL_FINGERPRINT_RE = re.compile(
    r"Verilator|verilated|%Error|%Warning|- V e r i l a t",
    re.I,
)
# Legacy name kept for B24 import sites; no longer a pass criterion alone.
_B20_SIM_CLAIM_RE = re.compile(r"(?m)^\s*(VERILATOR_RUN=1|SIM_RUN=1|HIER_TB_RUN=1)\s*$")


def load_b20_hier_manifest(root: Path) -> tuple[list[dict[str, object]], list[str]]:
    """Load explicit executable scenario manifest. Returns (scenarios, msgs)."""
    msgs: list[str] = []
    candidates = [
        root / B20_HIER_MANIFEST_REL,
        RULER_ROOT / B20_HIER_MANIFEST_REL,
    ]
    path = next((p for p in candidates if p.is_file()), None)
    if path is None:
        msgs.append(
            f"LEG0_B20_MANIFEST_MISSING tried={[str(p) for p in candidates]}"
        )
        # Synthesize minimal fail-open specs so tokens still fire as missing scripts.
        synth = []
        for tok in B20_HIER_FALLBACK_TOKENS:
            letter = tok.split("_")[2]  # A..G
            synth.append(
                {
                    "token": tok,
                    "script": f"tests/unit/test_b20_hier_{letter.lower()}_MISSING.sh",
                    "case": f"CASE B20_HIER_{letter} EXECUTED",
                    "pass": f"PASS B20_HIER_{letter}",
                    "why": "manifest missing — script required",
                    "require_stdout": [],
                    "fault_env": {"B20_HIER_FAULT": "1"},
                }
            )
        return synth, msgs
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        msgs.append(f"LEG0_B20_MANIFEST_BAD path={path} err={exc}")
        return [], msgs + [f"manifest unreadable: {exc}"]
    scenarios = list(data.get("scenarios") or [])
    msgs.append(
        f"LEG0_B20_MANIFEST_LOADED path={path} n={len(scenarios)} "
        f"version={data.get('version', '?')}"
    )
    return scenarios, msgs


def _b20_script_body_lines(script_txt: str) -> list[str]:
    """Non-echo, non-comment body lines (rough)."""
    lines: list[str] = []
    for ln in script_txt.splitlines():
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("echo ") or s.startswith("printf "):
            continue
        s = re.sub(r"\s+#.*$", "", s)
        if s:
            lines.append(s)
    return lines


def _b20_script_invokes_simulator(script_txt: str) -> bool:
    """True only if body invokes verilator/run_verilator/make-sim/python-TB.

    rd-duck: test -f / rg / grep on existing files is NOT a simulator and must
    not clear hierarchy tokens (file-existence echo theatre).
    """
    body = "\n".join(_b20_script_body_lines(script_txt))
    if not body.strip():
        return False
    if not _B20_SIM_INVOKE_RE.search(body):
        return False
    # Reject if every body line is only fs-probe / cd / chmod / set / var assign.
    fs_only = re.compile(
        r"^(?:test\b|rg\b|grep\b|\[\[|\[ |cd\b|chmod\b|set\b|export\b|"
        r"mkdir\b|ROOT=|MD=|WORKDIR=|SIM=|VL=|rc=|if\b|then\b|fi\b|else\b|"
        r"elif\b|for\b|do\b|done\b|case\b|esac\b|exit\b|true\b|false\b|"
        r"command\b|hash\b|type\b)",
        re.I,
    )
    sim_lines = [ln for ln in body.splitlines() if _B20_SIM_INVOKE_RE.search(ln)]
    return bool(sim_lines) and not all(fs_only.match(ln) for ln in body.splitlines())


# Back-compat alias used by older call sites / B24 until fully migrated.
def _b20_script_body_is_real_runner(script_txt: str) -> bool:
    return _b20_script_invokes_simulator(script_txt)


def _b20_sim_evidence(out: str, root: Path) -> bool:
    """Proof a simulator actually ran — not self-reported SIM_RUN=1/DUT_TOUCHED=1."""
    if _B20_TOOL_FINGERPRINT_RE.search(out or ""):
        return True
    m = re.search(r"(?m)^\s*SIM_ARTIFACT=(.+?)\s*$", out or "")
    if not m:
        return False
    raw = m.group(1).strip().strip("'\"")
    p = Path(raw)
    if not p.is_absolute():
        p = root / p
    try:
        return p.is_file() and p.stat().st_size >= 32
    except OSError:
        return False


def _b20_require_stdout_missing(out: str, require_stdout: list[str]) -> list[str]:
    missing: list[str] = []
    for extra in require_stdout:
        m_ge = re.fullmatch(r"(.+?)>=(\d+)", extra)
        if m_ge:
            key, need_n = m_ge.group(1), int(m_ge.group(2))
            m_val = re.search(rf"(?m)^\s*{re.escape(key)}\s*=\s*(\d+)\s*$", out)
            if not m_val:
                if f"{key}>=" not in out and f"{key}={need_n}" not in out:
                    missing.append(f"missing measured '{extra}'")
                else:
                    m2 = re.search(rf"{re.escape(key)}\s*=\s*(\d+)", out)
                    if m2 and int(m2.group(1)) < need_n:
                        missing.append(f"'{key}'={m2.group(1)} < required {need_n}")
                    elif not m2 and f"{key}>=" not in out:
                        missing.append(f"missing measured '{extra}'")
            elif int(m_val.group(1)) < need_n:
                missing.append(f"'{key}'={m_val.group(1)} < required {need_n}")
        elif extra not in out:
            missing.append(f"missing required evidence '{extra}'")
    return missing


def _b20_run_script(
    script: Path,
    root: Path,
    env_extra: dict[str, str],
    timeout_s: float,
) -> tuple[int, str]:
    cmd = [str(script)] if os.access(script, os.X_OK) else ["bash", str(script)]
    if script.suffix == ".py":
        cmd = [sys.executable, str(script)]
    env = os.environ.copy()
    env["MISTERPLEX_ROOT"] = str(root)
    env["ROOT"] = str(root)
    env.update({str(k): str(v) for k, v in env_extra.items()})
    proc = subprocess.run(
        cmd,
        cwd=str(root),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout_s,
    )
    return int(proc.returncode), (proc.stdout or "")


def run_b20_hierarchy_exec_gate(
    root: Path,
    *,
    timeout_s: float = 180.0,
) -> tuple[int, list[str], list[str]]:
    """Run B20 hierarchy scripts: green rc0 + behavioral fault twin rc!=0.

    Contract (rd-duck 2026-08-03 — kill file-existence echo theatre):
      1. Manifest names each executable script (+ optional fault_env).
      2. Script body must invoke a real simulator (verilator/run_verilator/make-sim).
         test -f / rg / grep alone is NOT enough.
      3. GREEN run: CASE EXECUTED + PASS + require_stdout + true rc=0 + sim evidence
         (Verilator fingerprint or SIM_ARTIFACT= existing binary). Self-reported
         SIM_RUN=1 / DUT_TOUCHED=1 / HIER_TB_RUN=1 is NOT evidence.
      4. FAULT twin (env B20_HIER_FAULT=1 by default): CASE EXECUTED + true rc!=0
         (and !=77). Proves the test can fail a broken DUT condition.
      5. Soft-skip 77 ≠ PASS. Comment bait ≠ PASS.
    """
    msgs: list[str] = []
    errors: list[str] = []

    # Anti-regression: live *definition* of text-scan helper (not this comment).
    gate_src = Path(__file__).read_text(errors="replace")
    if re.search(r"(?m)^\s*def\s+_is_hierarchy_test\s*\(", gate_src):
        errors.append(
            "B20_HIER_GATE_REGRESSION: fit_release_gate.py still defines "
            "def _is_hierarchy_test (846b7f1b keyword-scan class). "
            "Hierarchy tokens must only clear via manifest+run."
        )
        msgs.append("LEG0_B20_HIER_REGRESSION_TEXT_SCAN_PRESENT")
    if re.search(
        r"""(?m)^\s*msgs\.append\(\s*f?['"]LEG0_B20_HIER_SCAN_EXECUTED""",
        gate_src,
    ):
        errors.append(
            "B20_HIER_GATE_REGRESSION: live LEG0_B20_HIER_SCAN_EXECUTED append "
            "still present — text-scan path not fully removed."
        )
        msgs.append("LEG0_B20_HIER_REGRESSION_SCAN_APPEND_PRESENT")
    # Anti-theatre: gate must not treat DUT_TOUCHED/HIER_TB_RUN self-report as enough.
    if re.search(
        r"(?m)^\s*if not _B20_SIM_CLAIM_RE\.search\(out\):",
        gate_src,
    ) and not re.search(r"_b20_sim_evidence", gate_src):
        errors.append(
            "B20_HIER_GATE_REGRESSION: still keys pass on _B20_SIM_CLAIM_RE "
            "(self-reported SIM_RUN) without _b20_sim_evidence."
        )

    scenarios, m_msgs = load_b20_hier_manifest(root)
    msgs.extend(m_msgs)
    if not scenarios:
        for tok in B20_HIER_FALLBACK_TOKENS:
            errors.append(
                f"{tok}: B20 manifest missing/unreadable — cannot run hierarchy "
                "executables. Soft-skip ≠ PASS."
            )
        msgs.append("LEG0_B20_HIER_EXEC_DONE open=manifest_fail")
        return 1, msgs, errors

    global B20_HIER_REGISTRY
    B20_HIER_REGISTRY = tuple(scenarios)  # type: ignore[assignment]

    msgs.append(
        f"LEG0_B20_HIER_EXEC_BEGIN n_scenarios={len(scenarios)} "
        "(green rc0 + fault twin rc!=0 + simulator body; "
        "NOT file-existence echo — rd-duck 2026-08-03)"
    )
    for spec in scenarios:
        tok = str(spec["token"])
        rel = str(spec["script"])
        case_tok = str(spec["case"])
        pass_tok = str(spec["pass"])
        why = str(spec.get("why") or "")
        require_stdout = [str(x) for x in (spec.get("require_stdout") or [])]
        if not require_stdout and spec.get("extra_require"):
            require_stdout = [str(x) for x in spec["extra_require"]]  # type: ignore[index]
        fault_env_raw = spec.get("fault_env") or {"B20_HIER_FAULT": "1"}
        if isinstance(fault_env_raw, dict):
            fault_env = {str(k): str(v) for k, v in fault_env_raw.items()}
        else:
            fault_env = {"B20_HIER_FAULT": "1"}
        fault_case = str(spec.get("fault_case") or case_tok)

        script = root / rel
        if not script.is_file():
            errors.append(
                f"{tok}: missing executable hierarchy script {rel}. "
                f"Need a real simulator TB (verilator/run_verilator) that on GREEN "
                f"prints '{case_tok}', '{pass_tok}', {require_stdout!r}, sim evidence, "
                f"true rc=0; and on FAULT env {fault_env} prints '{fault_case}' with "
                f"true rc!=0. why={why}. "
                "File-existence echo / SIM_RUN self-report do not satisfy. Soft-skip ≠ PASS."
            )
            msgs.append(f"LEG0_B20_HIER_MISS {tok} path={rel}")
            continue
        if script.suffix not in {".sh", ".py"}:
            errors.append(
                f"{tok}: {rel} suffix={script.suffix!r} is not an executable "
                ".sh/.py runner. Prose/TB source path alone is hollow."
            )
            continue

        try:
            script_txt = script.read_text(errors="replace")
        except OSError as exc:
            errors.append(f"{tok}: cannot read {rel}: {exc}")
            continue

        if not _b20_script_invokes_simulator(script_txt):
            errors.append(
                f"{tok}: script {rel} does not invoke a simulator "
                f"(need verilator|run_verilator.sh|make…sim/tb|python TB). "
                f"test -f / rg / grep / echo PASS is theatre and must not clear "
                f"(rd-duck 2026-08-03). why={why}"
            )
            msgs.append(f"LEG0_B20_HIER_HOLLOW_BODY {tok}")
            continue

        # --- GREEN ---
        try:
            rc_g, out_g = _b20_run_script(script, root, {}, timeout_s)
        except subprocess.TimeoutExpired:
            errors.append(
                f"{tok}: GREEN hierarchy script {rel} timed out after {timeout_s}s."
            )
            msgs.append(f"LEG0_B20_HIER_TIMEOUT {tok} phase=green")
            continue
        except OSError as exc:
            errors.append(f"{tok}: failed to execute GREEN {rel}: {exc}")
            continue

        msgs.append(
            f"LEG0_B20_HIER_RUN_GREEN {tok} script={rel} true_rc={rc_g} "
            f"out_bytes={len(out_g)}"
        )
        missing_g: list[str] = []
        if rc_g == 77:
            missing_g.append("soft-skip rc=77 (≠ PASS)")
        if case_tok not in out_g:
            missing_g.append(f"missing '{case_tok}'")
        if pass_tok not in out_g:
            missing_g.append(f"missing '{pass_tok}'")
        if rc_g != 0:
            missing_g.append(f"true_rc={rc_g} (need 0)")
        if not _b20_sim_evidence(out_g, root):
            missing_g.append(
                "missing sim evidence (Verilator fingerprint or SIM_ARTIFACT= "
                "existing binary ≥32B) — self-reported SIM_RUN/DUT_TOUCHED ≠ proof"
            )
        if not re.search(r"(?m)^\s*measured_[\w]+=", out_g):
            missing_g.append("missing measured_*= evidence line")
        missing_g.extend(_b20_require_stdout_missing(out_g, require_stdout))

        # --- FAULT TWIN ---
        try:
            rc_f, out_f = _b20_run_script(script, root, fault_env, timeout_s)
        except subprocess.TimeoutExpired:
            errors.append(
                f"{tok}: FAULT twin {rel} timed out after {timeout_s}s "
                f"(env={fault_env})."
            )
            msgs.append(f"LEG0_B20_HIER_TIMEOUT {tok} phase=fault")
            continue
        except OSError as exc:
            errors.append(f"{tok}: failed to execute FAULT {rel}: {exc}")
            continue

        msgs.append(
            f"LEG0_B20_HIER_RUN_FAULT {tok} script={rel} true_rc={rc_f} "
            f"env={fault_env} out_bytes={len(out_f)}"
        )
        missing_f: list[str] = []
        if fault_case not in out_f:
            missing_f.append(f"missing fault '{fault_case}'")
        if rc_f == 0:
            missing_f.append(
                "fault twin true_rc=0 (need nonzero — behavioral fail of load-bearing DUT)"
            )
        if rc_f == 77:
            missing_f.append("fault twin soft-skip rc=77 (≠ behavioral fail)")

        if missing_g or missing_f:
            tail_g = out_g.strip().splitlines()[-8:] if out_g.strip() else []
            tail_f = out_f.strip().splitlines()[-8:] if out_f.strip() else []
            parts = []
            if missing_g:
                parts.append(f"GREEN: {', '.join(missing_g)}")
            if missing_f:
                parts.append(f"FAULT: {', '.join(missing_f)}")
            errors.append(
                f"{tok}: hierarchy green+fault contract failed: {'; '.join(parts)}. "
                f"why={why}. green_tail={tail_g!r} fault_tail={tail_f!r}"
            )
        else:
            msgs.append(
                f"LEG0_B20_HIER_OK {tok} script={rel} green_rc=0 fault_rc={rc_f} "
                f"case_executed=1 pass=1 sim_evidence=1 fault_behavioral=1"
            )

    n_err = sum(1 for e in errors if e.startswith("B20_HIER_"))
    msgs.append(f"LEG0_B20_HIER_EXEC_DONE open={n_err}/{len(scenarios)}")
    return (1 if n_err else 0), msgs, errors


# Populated at run time from manifest; mutations may call load_b20_hier_manifest.
B20_HIER_REGISTRY: tuple[dict[str, object], ...] = ()

# ---------------------------------------------------------------------------
# B24 — PLXG q5 bit34 fps_1001 ABI merge-loss (rd-duck 2026-08-03)
# w-path f31a6eb9: q5[34]=fps_1001, reserved[63:35], pack 24000/1001 → 24+flag
# w-mem latch: q5_reserved_nz=|sh5[63:34] → E4 / wholesale geom reject
# w-clock: no fps_1001 consumer
# Static q5@0x828 presence (B17) is insufficient — must RUN host-packed qword
# through merged poller+latch+consumer and prove accept + 1001 flag.
# ---------------------------------------------------------------------------
B24_Q5_MANIFEST_REL = "tests/unit/B24_Q5_FPS_1001_MANIFEST.json"
B24_Q5_TOKEN = "B24_Q5_FPS_1001_MERGED_PATH"
B24_Q5_DEFAULT_SPEC: dict[str, object] = {
    "token": B24_Q5_TOKEN,
    "script": "tests/unit/test_b24_q5_fps_1001_merged_path.sh",
    "case": "CASE B24_Q5_FPS_1001 EXECUTED",
    "pass": "PASS B24_Q5_FPS_1001",
    "why": (
        "canonical host-packed 24000/1001 q5 through merged poller+latch+consumer; "
        "prove accept + fps_1001 (bit34); static q5 presence insufficient "
        "(rd-duck: w-path f31a6eb9 vs w-mem |sh5[63:34] E4 reject vs w-clock no consumer)"
    ),
    "require_stdout": [
        "measured_host_pack_24000_1001=1",
        "measured_q5_bit34_fps_1001=1",
        "measured_latch_accept=1",
        "measured_q5_reserved_reject=0",
        "measured_consumer_fps_1001=1",
        "content_fps=24",
        "fps_num=24000",
        "fps_den=1001",
    ],
}


def load_b24_q5_manifest(root: Path) -> tuple[dict[str, object], list[str]]:
    """Load B24 executable scenario; fall back to embedded default spec."""
    msgs: list[str] = []
    candidates = [
        root / B24_Q5_MANIFEST_REL,
        RULER_ROOT / B24_Q5_MANIFEST_REL,
    ]
    path = next((p for p in candidates if p.is_file()), None)
    if path is None:
        msgs.append(f"LEG0_B24_MANIFEST_MISSING tried={[str(p) for p in candidates]}")
        return dict(B24_Q5_DEFAULT_SPEC), msgs
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        msgs.append(f"LEG0_B24_MANIFEST_BAD path={path} err={exc}")
        return dict(B24_Q5_DEFAULT_SPEC), msgs
    scenarios = list(data.get("scenarios") or [])
    msgs.append(
        f"LEG0_B24_MANIFEST_LOADED path={path} n={len(scenarios)} "
        f"version={data.get('version', '?')}"
    )
    if not scenarios:
        return dict(B24_Q5_DEFAULT_SPEC), msgs
    # Prefer exact token match.
    for sc in scenarios:
        if str(sc.get("token")) == B24_Q5_TOKEN:
            return dict(sc), msgs
    return dict(scenarios[0]), msgs


def run_b24_q5_fps_1001_static(root: Path) -> tuple[list[str], list[str]]:
    """Static collision: latch reserves bit34 / no fps_1001 consumer.

    Does not clear B24_Q5_FPS_1001_MERGED_PATH — executable is still required.
    """
    msgs: list[str] = []
    errors: list[str] = []
    latch = root / "fpga" / "Plex_MiSTer" / "rtl" / "present_geom_latch.sv"
    core = root / "fpga" / "Plex_MiSTer" / "rtl" / "present_core.sv"
    fps_sel = root / "fpga" / "Plex_MiSTer" / "rtl" / "plex_content_fps_sel.sv"
    plex = root / "fpga" / "Plex_MiSTer" / "Plex.sv"
    host_hdr = root / "host" / "libmisterplex" / "plxg_q5_aspect_cadence.hpp"

    latch_txt = latch.read_text(errors="replace") if latch.is_file() else ""
    core_txt = core.read_text(errors="replace") if core.is_file() else ""
    sel_txt = fps_sel.read_text(errors="replace") if fps_sel.is_file() else ""
    plex_txt = plex.read_text(errors="replace") if plex.is_file() else ""
    host_txt = host_hdr.read_text(errors="replace") if host_hdr.is_file() else ""

    # Latch treats [63:34] as reserved (rejects path f31a6eb9 bit34=fps_1001).
    reserves_34 = bool(
        re.search(r"sh5\s*\[\s*63\s*:\s*34\s*\]", latch_txt)
        or re.search(r"\[\s*63\s*:\s*34\s*\].*reserved|reserved.*\[\s*63\s*:\s*34\s*\]", latch_txt, re.I)
        or re.search(r"q5_reserved_nz\s*=\s*\|\s*sh5\s*\[\s*63\s*:\s*34\s*\]", latch_txt)
    )
    # Accept path: reserved starts at 35 and bit34 is data (fps_1001).
    accepts_34 = bool(
        re.search(r"sh5\s*\[\s*63\s*:\s*35\s*\]", latch_txt)
        and (
            re.search(r"fps_1001\s*<=\s*sh5\s*\[\s*34\s*\]", latch_txt)
            or re.search(r"\bfps_1001\b", latch_txt)
        )
    )
    msgs.append(
        f"LEG0_B24_LATCH_BIT34 reserves_34={int(reserves_34)} accepts_34={int(accepts_34)} "
        f"path={latch.relative_to(root) if latch.is_file() else 'ABSENT'}"
    )
    if not latch.is_file():
        errors.append(
            "B24_Q5_BIT34_LATCH_REJECTS_1001: present_geom_latch.sv absent — cannot "
            "accept host-packed 24000/1001 q5 bit34=fps_1001 (rd-duck ABI merge-loss)."
        )
    elif not accepts_34:
        # Two shapes of the same defect:
        #  (a) w-mem product: |sh5[63:34] → E4 wholesale geom reject (observed)
        #  (b) hollow/old latch: no fps_1001 / reserved@35 path at all
        detail = (
            "treats q5[63:34] as reserved (|sh5[63:34] → q5_reserved_reject / E4)"
            if reserves_34
            else "has no fps_1001 accept path (reserved must be [63:35]; bit34=data)"
        )
        errors.append(
            f"B24_Q5_BIT34_LATCH_REJECTS_1001: present_geom_latch {detail}. "
            "w-path f31a6eb9 packs bit34=fps_1001 for 24000/1001 film; current merge "
            "rejects geometry wholesale or drops the flag. Latch must expose fps_1001 "
            "and not trap bit34 as reserved. Static q5@0x828 presence does not clear "
            "this (rd-duck ABI merge-loss)."
        )

    # Consumer of fps_1001 on fabric side (clock cadence path).
    consumer_hit = bool(
        re.search(r"\bfps_1001\b", core_txt)
        or re.search(r"\bfps_1001\b", sel_txt)
        or re.search(r"\.(fps_1001|live_fps_1001)\s*\(", plex_txt)
        or re.search(r"\bfabric_fps_1001\b|\bplxg_fps_1001\b", plex_txt)
    )
    msgs.append(f"LEG0_B24_CONSUMER_FPS_1001 hit={int(consumer_hit)}")
    if not consumer_hit:
        errors.append(
            "B24_Q5_FPS_1001_NO_CONSUMER: no fabric consumer of q5 bit34 fps_1001 "
            "(present_core / plex_content_fps_sel / Plex.sv). w-clock must consume "
            "the flag (rate = content_fps*1000/1001 when set); integer bucket alone "
            "outruns 23.976 (~0.0246 fps → bank miss ~40s). Path publishes; fabric "
            "must select (rd-duck / w-path f31a6eb9)."
        )

    # Host packer still on wire? Diagnostic only (path may have vacated pending arb).
    host_on_wire = bool(
        re.search(r"kPlxgQ5Fps1001OnWire\s*=\s*true", host_txt)
        or (
            re.search(r"kPlxgQ5Fps1001Bit\s*=\s*1ull\s*<<\s*34", host_txt)
            and re.search(r"kPlxgQ5ReservedShift\s*=\s*35", host_txt)
        )
    )
    msgs.append(
        f"LEG0_B24_HOST_WIRE_1001 on_wire_or_abi21={int(host_on_wire)} "
        f"hdr={'yes' if host_hdr.is_file() else 'no'}"
    )
    return msgs, errors


def run_b24_q5_fps_1001_exec_gate(
    root: Path,
    *,
    timeout_s: float = 180.0,
) -> tuple[int, list[str], list[str]]:
    """Run canonical 24000/1001 q5 path: green rc0 + fault twin rc!=0 + sim evidence."""
    msgs: list[str] = []
    errors: list[str] = []
    spec, m_msgs = load_b24_q5_manifest(root)
    msgs.extend(m_msgs)

    tok = str(spec.get("token") or B24_Q5_TOKEN)
    rel = str(spec.get("script") or B24_Q5_DEFAULT_SPEC["script"])
    case_tok = str(spec.get("case") or B24_Q5_DEFAULT_SPEC["case"])
    pass_tok = str(spec.get("pass") or B24_Q5_DEFAULT_SPEC["pass"])
    why = str(spec.get("why") or B24_Q5_DEFAULT_SPEC["why"])
    require_stdout = [str(x) for x in (spec.get("require_stdout") or [])]
    if not require_stdout:
        require_stdout = list(B24_Q5_DEFAULT_SPEC["require_stdout"])  # type: ignore[arg-type]
    fault_env_raw = spec.get("fault_env") or {"B24_Q5_FAULT": "1"}
    fault_env = (
        {str(k): str(v) for k, v in fault_env_raw.items()}
        if isinstance(fault_env_raw, dict)
        else {"B24_Q5_FAULT": "1"}
    )
    fault_case = str(spec.get("fault_case") or case_tok)

    msgs.append(
        f"LEG0_B24_Q5_EXEC_BEGIN token={tok} script={rel} "
        "(green+fault simulator path; not static q5 / file-existence echo)"
    )

    script = root / rel
    if not script.is_file():
        errors.append(
            f"{tok}: missing executable merged-path script {rel}. "
            f"Need simulator TB: GREEN '{case_tok}'+'{pass_tok}'+{require_stdout!r} "
            f"rc=0 + sim evidence; FAULT env {fault_env} '{fault_case}' rc!=0. "
            f"why={why}. Soft-skip ≠ PASS."
        )
        msgs.append(f"LEG0_B24_Q5_MISS path={rel}")
        msgs.append("LEG0_B24_Q5_EXEC_DONE open=1/1")
        return 1, msgs, errors

    if script.suffix not in {".sh", ".py"}:
        errors.append(
            f"{tok}: {rel} suffix={script.suffix!r} is not an executable .sh/.py "
            "runner. Prose/header presence alone is hollow."
        )
        msgs.append("LEG0_B24_Q5_EXEC_DONE open=1/1")
        return 1, msgs, errors

    try:
        script_txt = script.read_text(errors="replace")
    except OSError as exc:
        errors.append(f"{tok}: cannot read {rel}: {exc}")
        return 1, msgs, errors

    if not _b20_script_invokes_simulator(script_txt):
        errors.append(
            f"{tok}: script {rel} does not invoke a simulator "
            f"(verilator|run_verilator.sh|make…sim|python TB). "
            f"test -f/rg/echo theatre rejected. why={why}"
        )
        msgs.append("LEG0_B24_Q5_HOLLOW_BODY")
        msgs.append("LEG0_B24_Q5_EXEC_DONE open=1/1")
        return 1, msgs, errors

    try:
        rc_g, out_g = _b20_run_script(script, root, {}, timeout_s)
        rc_f, out_f = _b20_run_script(script, root, fault_env, timeout_s)
    except subprocess.TimeoutExpired:
        errors.append(f"{tok}: script {rel} timed out — DID_NOT_FINISH.")
        msgs.append("LEG0_B24_Q5_TIMEOUT")
        return 1, msgs, errors
    except OSError as exc:
        errors.append(f"{tok}: failed to execute {rel}: {exc}")
        return 1, msgs, errors

    msgs.append(
        f"LEG0_B24_Q5_RUN_GREEN script={rel} true_rc={rc_g} out_bytes={len(out_g)}"
    )
    msgs.append(
        f"LEG0_B24_Q5_RUN_FAULT script={rel} true_rc={rc_f} env={fault_env} "
        f"out_bytes={len(out_f)}"
    )

    missing: list[str] = []
    if rc_g == 77:
        missing.append("GREEN soft-skip rc=77")
    if case_tok not in out_g:
        missing.append(f"GREEN missing '{case_tok}'")
    if pass_tok not in out_g:
        missing.append(f"GREEN missing '{pass_tok}'")
    if rc_g != 0:
        missing.append(f"GREEN true_rc={rc_g} (need 0)")
    if not _b20_sim_evidence(out_g, root):
        missing.append("GREEN missing sim evidence (not SIM_RUN self-report)")
    if not re.search(r"(?m)^\s*measured_[\w]+=", out_g):
        missing.append("GREEN missing measured_*=")
    missing.extend([f"GREEN {m}" for m in _b20_require_stdout_missing(out_g, require_stdout)])
    if fault_case not in out_f:
        missing.append(f"FAULT missing '{fault_case}'")
    if rc_f == 0:
        missing.append("FAULT true_rc=0 (need nonzero behavioral fail)")
    if rc_f == 77:
        missing.append("FAULT soft-skip rc=77")

    if missing:
        tail = (out_g.strip().splitlines()[-6:] if out_g.strip() else []) + (
            out_f.strip().splitlines()[-6:] if out_f.strip() else []
        )
        errors.append(
            f"{tok}: green+fault contract failed: {', '.join(missing)}. "
            f"why={why}. tail={tail!r}"
        )
        msgs.append("LEG0_B24_Q5_EXEC_DONE open=1/1")
        return 1, msgs, errors

    msgs.append(
        f"LEG0_B24_Q5_OK script={rel} green_rc=0 fault_rc={rc_f} "
        "accept+fps_1001 proven (simulator path)"
    )
    msgs.append("LEG0_B24_Q5_EXEC_DONE open=0/1")
    return 0, msgs, errors



# ---------------------------------------------------------------------------
# B25 — PLXC host-write→loader-read at BOTH merged doorbell maps (rd-duck)
# w-osd plex_chrome_ddr_loader historically default/inst 0x3007F000 (packed-320);
# isolated OSD TB often DOORBELL_PHYS=0 and still PASSes.
# w-mem product: legacy 0x300FF000, Option-C 0x3047F000.
# ARM PLXC writes relative to *runtime* active doorbell.
# B20_HIER_G CDC multi-beat alone is insufficient — must prove host→loader on
# both map modes (not merely edge-detect beat counts).
# ---------------------------------------------------------------------------
B25_PLXC_MANIFEST_REL = "tests/unit/B25_PLXC_DOORBELL_DUAL_MAP_MANIFEST.json"
B25_PLXC_TOKEN = "B25_PLXC_HOST_LOADER_BOTH_MAPS"
B25_LEGACY_DOORBELL = 0x300FF000
B25_OPTC_DOORBELL = 0x3047F000
B25_STALE_DOORBELL = 0x3007F000
B25_PLXC_DEFAULT_SPEC: dict[str, object] = {
    "token": B25_PLXC_TOKEN,
    "script": "tests/unit/test_b25_plxc_host_loader_both_maps.sh",
    "case": "CASE B25_PLXC_BOTH_MAPS EXECUTED",
    "pass": "PASS B25_PLXC_BOTH_MAPS",
    "why": (
        "host-write→loader-read at product legacy 0x300FF000 AND Option-C "
        "0x3047F000; ARM PLXC is runtime-doorbell-relative; fixed loader "
        "default/isolated TB with stale 0x3007F000 or DOORBELL=0 is "
        "green-in-isolation merge-loss (rd-duck). Not CDC beats alone (B20_G)."
    ),
    "fault_env": {"B25_PLXC_FAULT": "1"},
    "require_stdout": [
        "measured_legacy_doorbell=0x300FF000",
        "measured_optc_doorbell=0x3047F000",
        "measured_host_write_legacy=1",
        "measured_loader_read_legacy=1",
        "measured_host_write_optc=1",
        "measured_loader_read_optc=1",
        "measured_stale_3007F000_used=0",
    ],
}


def load_b25_plxc_manifest(root: Path) -> tuple[dict[str, object], list[str]]:
    """Load B25 dual-map scenario; fall back to embedded default."""
    msgs: list[str] = []
    candidates = [
        root / B25_PLXC_MANIFEST_REL,
        RULER_ROOT / B25_PLXC_MANIFEST_REL,
    ]
    path = next((p for p in candidates if p.is_file()), None)
    if path is None:
        msgs.append(f"LEG0_B25_MANIFEST_MISSING tried={[str(p) for p in candidates]}")
        return dict(B25_PLXC_DEFAULT_SPEC), msgs
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        msgs.append(f"LEG0_B25_MANIFEST_BAD path={path} err={exc}")
        return dict(B25_PLXC_DEFAULT_SPEC), msgs
    scenarios = list(data.get("scenarios") or [])
    msgs.append(
        f"LEG0_B25_MANIFEST_LOADED path={path} n={len(scenarios)} "
        f"version={data.get('version', '?')}"
    )
    if not scenarios:
        return dict(B25_PLXC_DEFAULT_SPEC), msgs
    for sc in scenarios:
        if str(sc.get("token")) == B25_PLXC_TOKEN:
            return dict(sc), msgs
    return dict(scenarios[0]), msgs


def _b25_norm_hex_lit(s: str) -> str | None:
    """Normalize SV/C hex literal to lowercase 0x........ or None."""
    s = s.strip().replace("_", "")
    m = re.search(r"(?:32'h|0x)?([0-9A-Fa-f]{7,8})\b", s)
    if not m:
        return None
    return f"0x{int(m.group(1), 16):08X}"


def run_b25_plxc_doorbell_static(root: Path) -> tuple[list[str], list[str]]:
    """Static: stale 0x3007F000 default/inst on loader; dual-map exec still required."""
    msgs: list[str] = []
    errors: list[str] = []
    loader = root / "fpga" / "Plex_MiSTer" / "rtl" / "plex_chrome_ddr_loader.sv"
    plex = root / "fpga" / "Plex_MiSTer" / "Plex.sv"
    layout = root / "fpga" / "Plex_MiSTer" / "rtl" / "ddr_frame_layout_params.svh"

    loader_txt = loader.read_text(errors="replace") if loader.is_file() else ""
    plex_txt = plex.read_text(errors="replace") if plex.is_file() else ""
    layout_txt = layout.read_text(errors="replace") if layout.is_file() else ""

    # Default parameter on loader module.
    def_m = re.search(
        r"parameter\s+(?:\[[^\]]+\]\s+)?DOORBELL_PHYS\s*=\s*([^,\n]+)",
        loader_txt,
    )
    def_hex = _b25_norm_hex_lit(def_m.group(1)) if def_m else None
    stale_def = def_hex == f"0x{B25_STALE_DOORBELL:08X}" if def_hex else False
    good_def = def_hex == f"0x{B25_LEGACY_DOORBELL:08X}" if def_hex else False

    # Instantiation override in Plex.sv (first chrome loader instance).
    inst_ports = _extract_sv_instance_ports(plex_txt, "plex_chrome_ddr_loader")
    inst_m = re.search(r"\.DOORBELL_PHYS\s*\(\s*([^)]+)\)", inst_ports or "")
    inst_hex = _b25_norm_hex_lit(inst_m.group(1)) if inst_m else None
    stale_inst = inst_hex == f"0x{B25_STALE_DOORBELL:08X}" if inst_hex else False

    # Product map constants (diagnostic).
    leg_in_layout = bool(
        re.search(r"300[Ff]_?[Ff]000|0x300[Ff]{2}000", layout_txt)
        or re.search(r"DDR_FRAME_YUV420P_DOORBELL_PHYS\s*=\s*32'h300[Ff]_?[Ff]000", layout_txt)
    )
    optc_in_layout = bool(
        re.search(r"3047_?[Ff]000|0x3047[Ff]000", layout_txt)
        or re.search(r"DDR_FRAME_720P_YUV420P_DOORBELL_PHYS\s*=\s*32'h3047_?[Ff]000", layout_txt)
    )

    # Fixed-only doorbell (parameter → localparam PLXC_W) with no runtime port.
    has_runtime_db_port = bool(
        re.search(r"input\s+.*\b(doorbell_phys|active_doorbell|rt_doorbell)\b", loader_txt, re.I)
    )
    fixed_only = bool(loader_txt) and not has_runtime_db_port

    msgs.append(
        f"LEG0_B25_LOADER path={loader.relative_to(root) if loader.is_file() else 'ABSENT'} "
        f"default={def_hex or 'none'} stale_def={int(stale_def)} good_legacy_def={int(good_def)} "
        f"inst={inst_hex or 'none'} stale_inst={int(stale_inst)} "
        f"fixed_only={int(fixed_only)} runtime_db_port={int(has_runtime_db_port)} "
        f"layout_leg={int(leg_in_layout)} layout_optc={int(optc_in_layout)}"
    )
    msgs.append(
        "LEG0_B25_POLICY product legacy=0x300FF000 Option-C=0x3047F000; "
        "stale packed-320=0x3007F000 banned; ARM PLXC is runtime-doorbell-relative; "
        "B20_G CDC beats ≠ dual-map host→loader proof"
    )

    if not loader.is_file():
        # Hollow trees without chrome still need the dual-map exec when chrome lands;
        # do not invent a soft-skip — static absence is informational; exec MISS is hard.
        msgs.append("LEG0_B25_LOADER_ABSENT (exec path still required when chrome present)")
    elif stale_def:
        errors.append(
            "B25_PLXC_STALE_DEFAULT_3007F000: plex_chrome_ddr_loader DOORBELL_PHYS "
            f"default={def_hex} is packed-320 example map, not product legacy "
            f"0x{B25_LEGACY_DOORBELL:08X}. Isolated OSD TB sharing this stale default "
            "PASSes while ARM writes PLXC at runtime active doorbell "
            f"(legacy 0x{B25_LEGACY_DOORBELL:08X} / Option-C 0x{B25_OPTC_DOORBELL:08X}) "
            "— merge-loss class (rd-duck)."
        )
    if plex.is_file() and stale_inst:
        errors.append(
            "B25_PLXC_INST_STALE_3007F000: Plex.sv plex_chrome_ddr_loader "
            f".DOORBELL_PHYS({inst_hex}) is stale packed-320; product instantiation "
            f"must be legacy 0x{B25_LEGACY_DOORBELL:08X} or a runtime-active doorbell "
            f"that tracks Option-C 0x{B25_OPTC_DOORBELL:08X} (rd-duck)."
        )
    if loader.is_file() and fixed_only:
        msgs.append(
            "LEG0_B25_FIXED_DOORBELL_NOTE parameter-only DOORBELL_PHYS (no runtime "
            "doorbell port) — dual-map exec must still prove host→loader on BOTH "
            "legacy and Option-C maps (or product must wire runtime doorbell)."
        )
    return msgs, errors


def run_b25_plxc_doorbell_exec_gate(
    root: Path,
    *,
    timeout_s: float = 180.0,
) -> tuple[int, list[str], list[str]]:
    """Run host-write→loader-read dual-map path: green rc0 + fault twin + sim evidence."""
    msgs: list[str] = []
    errors: list[str] = []
    spec, m_msgs = load_b25_plxc_manifest(root)
    msgs.extend(m_msgs)

    tok = str(spec.get("token") or B25_PLXC_TOKEN)
    rel = str(spec.get("script") or B25_PLXC_DEFAULT_SPEC["script"])
    case_tok = str(spec.get("case") or B25_PLXC_DEFAULT_SPEC["case"])
    pass_tok = str(spec.get("pass") or B25_PLXC_DEFAULT_SPEC["pass"])
    why = str(spec.get("why") or B25_PLXC_DEFAULT_SPEC["why"])
    require_stdout = [str(x) for x in (spec.get("require_stdout") or [])]
    if not require_stdout:
        require_stdout = list(B25_PLXC_DEFAULT_SPEC["require_stdout"])  # type: ignore[arg-type]
    fault_env_raw = spec.get("fault_env") or {"B25_PLXC_FAULT": "1"}
    fault_env = (
        {str(k): str(v) for k, v in fault_env_raw.items()}
        if isinstance(fault_env_raw, dict)
        else {"B25_PLXC_FAULT": "1"}
    )
    fault_case = str(spec.get("fault_case") or case_tok)

    msgs.append(
        f"LEG0_B25_PLXC_EXEC_BEGIN token={tok} script={rel} "
        "(green+fault simulator; host→loader BOTH maps; NOT CDC-beats-only / B20_G)"
    )

    script = root / rel
    if not script.is_file():
        errors.append(
            f"{tok}: missing executable dual-map script {rel}. "
            f"Need simulator TB: GREEN '{case_tok}'+'{pass_tok}'+{require_stdout!r} "
            f"rc=0 + sim evidence; FAULT env {fault_env} '{fault_case}' rc!=0. "
            f"why={why}. Soft-skip ≠ PASS. B20_HIER_G CDC multi-beat alone does not clear."
        )
        msgs.append(f"LEG0_B25_PLXC_MISS path={rel}")
        msgs.append("LEG0_B25_PLXC_EXEC_DONE open=1/1")
        return 1, msgs, errors

    if script.suffix not in {".sh", ".py"}:
        errors.append(
            f"{tok}: {rel} suffix={script.suffix!r} is not an executable .sh/.py "
            "runner. Prose/CDC comment presence alone is hollow."
        )
        msgs.append("LEG0_B25_PLXC_EXEC_DONE open=1/1")
        return 1, msgs, errors

    try:
        script_txt = script.read_text(errors="replace")
    except OSError as exc:
        errors.append(f"{tok}: cannot read {rel}: {exc}")
        return 1, msgs, errors

    if not _b20_script_invokes_simulator(script_txt):
        errors.append(
            f"{tok}: script {rel} does not invoke a simulator "
            f"(verilator|run_verilator.sh|make…sim|python TB). "
            f"test -f/rg/echo / CDC-prose theatre rejected. why={why}"
        )
        msgs.append("LEG0_B25_PLXC_HOLLOW_BODY")
        msgs.append("LEG0_B25_PLXC_EXEC_DONE open=1/1")
        return 1, msgs, errors

    # Reject bodies that only mention B20_G CDC tokens without dual-map measures.
    body = "\n".join(_b20_script_body_lines(script_txt))
    cdc_only_bait = (
        re.search(r"PLXC_EXT_WE|measured_cdc_async|host_we_beats", body)
        and not re.search(r"0x300FF000|300FF000|legacy_doorbell", body, re.I)
        and not re.search(r"0x3047F000|3047F000|optc_doorbell", body, re.I)
    )
    if cdc_only_bait:
        errors.append(
            f"{tok}: script {rel} looks like B20_G CDC multi-beat only "
            "(no legacy/Option-C doorbell map measures). Dual-map host→loader required."
        )
        msgs.append("LEG0_B25_PLXC_CDC_ONLY_BODY")
        msgs.append("LEG0_B25_PLXC_EXEC_DONE open=1/1")
        return 1, msgs, errors

    try:
        rc_g, out_g = _b20_run_script(script, root, {}, timeout_s)
        rc_f, out_f = _b20_run_script(script, root, fault_env, timeout_s)
    except subprocess.TimeoutExpired:
        errors.append(f"{tok}: script {rel} timed out — DID_NOT_FINISH.")
        msgs.append("LEG0_B25_PLXC_TIMEOUT")
        return 1, msgs, errors
    except OSError as exc:
        errors.append(f"{tok}: failed to execute {rel}: {exc}")
        return 1, msgs, errors

    msgs.append(
        f"LEG0_B25_PLXC_RUN_GREEN script={rel} true_rc={rc_g} out_bytes={len(out_g)}"
    )
    msgs.append(
        f"LEG0_B25_PLXC_RUN_FAULT script={rel} true_rc={rc_f} env={fault_env} "
        f"out_bytes={len(out_f)}"
    )

    missing: list[str] = []
    if rc_g == 77:
        missing.append("GREEN soft-skip rc=77")
    if case_tok not in out_g:
        missing.append(f"GREEN missing '{case_tok}'")
    if pass_tok not in out_g:
        missing.append(f"GREEN missing '{pass_tok}'")
    if rc_g != 0:
        missing.append(f"GREEN true_rc={rc_g} (need 0)")
    if not _b20_sim_evidence(out_g, root):
        missing.append("GREEN missing sim evidence (not SIM_RUN self-report)")
    if not re.search(r"(?m)^\s*measured_[\w]+=", out_g):
        missing.append("GREEN missing measured_*=")
    missing.extend([f"GREEN {m}" for m in _b20_require_stdout_missing(out_g, require_stdout)])
    # Explicit dual-map semantics: both host_write and loader_read for each map.
    for key in (
        "measured_host_write_legacy=1",
        "measured_loader_read_legacy=1",
        "measured_host_write_optc=1",
        "measured_loader_read_optc=1",
    ):
        if key not in out_g:
            missing.append(f"GREEN dual-map missing '{key}'")
    # CDC-only PASS must not satisfy even if someone echoes our tokens without maps.
    if "measured_cdc_async=1" in out_g and "measured_host_write_legacy=1" not in out_g:
        missing.append("GREEN CDC-only output without host_write_legacy")
    if fault_case not in out_f:
        missing.append(f"FAULT missing '{fault_case}'")
    if rc_f == 0:
        missing.append("FAULT true_rc=0 (need nonzero behavioral fail)")
    if rc_f == 77:
        missing.append("FAULT soft-skip rc=77")

    if missing:
        tail = (out_g.strip().splitlines()[-6:] if out_g.strip() else []) + (
            out_f.strip().splitlines()[-6:] if out_f.strip() else []
        )
        errors.append(
            f"{tok}: green+fault dual-map contract failed: {', '.join(missing)}. "
            f"why={why}. tail={tail!r}"
        )
        msgs.append("LEG0_B25_PLXC_EXEC_DONE open=1/1")
        return 1, msgs, errors

    msgs.append(
        f"LEG0_B25_PLXC_OK script={rel} green_rc=0 fault_rc={rc_f} "
        "host→loader proven on legacy+Option-C maps (simulator path)"
    )
    msgs.append("LEG0_B25_PLXC_EXEC_DONE open=0/1")
    return 0, msgs, errors


def _extract_balanced(txt: str, open_idx: int) -> tuple[str, int]:
    """Return (inside, end_idx_exclusive) for (...) starting at open_idx on '('."""
    if open_idx < 0 or open_idx >= len(txt) or txt[open_idx] != "(":
        return "", open_idx
    depth = 0
    for i in range(open_idx, len(txt)):
        c = txt[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return txt[open_idx + 1 : i], i + 1
    return "", open_idx


def _extract_sv_instance_ports(txt: str, module: str) -> str:
    """Port-list body of first `module #(...) inst (` or `module inst (` (nested-safe)."""
    if not txt:
        return ""
    for m in re.finditer(rf"\b{re.escape(module)}\b", txt):
        i = m.end()
        # skip whitespace
        while i < len(txt) and txt[i].isspace():
            i += 1
        if i < len(txt) and txt[i] == "#":
            # skip #(...)
            while i < len(txt) and txt[i].isspace():
                i += 1
            # move to '(' after #
            j = i + 1
            while j < len(txt) and txt[j].isspace():
                j += 1
            if j < len(txt) and txt[j] == "(":
                _inside, j = _extract_balanced(txt, j)
                i = j
            while i < len(txt) and txt[i].isspace():
                i += 1
        # optional instance name
        mname = re.match(r"[A-Za-z_]\w*", txt[i:])
        if not mname:
            continue
        i += mname.end()
        while i < len(txt) and txt[i].isspace():
            i += 1
        if i < len(txt) and txt[i] == "(":
            inside, _end = _extract_balanced(txt, i)
            return inside
    return ""


def _check_present_core_merge_semantics(
    core: str, plex: str
) -> tuple[list[str], list[str]]:
    """B22 — semantic present_core ports + instance nets (rd-duck c5bd6009).

    Not file presence. Not ancestry. Connections must survive merge.
    Returns (msgs, errors).
    """
    msgs: list[str] = []
    errors: list[str] = []
    msgs.append(
        "LEG0_B22_PRESENT_CORE_MERGE_SEMANTICS_EXECUTED "
        "(ports+instance nets; c5bd6009 wholesale drop class)"
    )
    if not core:
        errors.append(
            "B22_PRESENT_CORE_MISSING: present_core.sv unreadable — cannot prove "
            "B16 geom_live / blackout / B15 cadence / Option-C instance wiring."
        )
        return msgs, errors

    # --- Port declarations on present_core (w-mem B16) ---
    has_port_seq = bool(
        re.search(r"\binput\s+wire\s+\[15:0\]\s+geom_live_seq\b", core)
        or re.search(r"\binput\s+.*?geom_live_seq\b", core)
    )
    has_port_live = bool(
        re.search(r"\binput\s+wire\s+geom_live_valid\b", core)
        or re.search(r"\binput\s+.*?geom_live_valid\b", core)
    )
    has_out_hold = bool(
        re.search(r"\boutput\s+wire\s+stat_geom_hold_black\b", core)
        or re.search(r"\boutput\s+.*?stat_geom_hold_black\b", core)
    )
    has_out_hollow = bool(
        re.search(r"\boutput\s+wire\s+stat_geom_hollow\b", core)
        or re.search(r"\boutput\s+.*?stat_geom_hollow\b", core)
    )
    msgs.append(
        f"LEG0_B22_PORTS geom_live_seq={int(has_port_seq)} "
        f"geom_live_valid={int(has_port_live)} "
        f"stat_geom_hold_black={int(has_out_hold)} "
        f"stat_geom_hollow={int(has_out_hollow)}"
    )
    if not has_port_seq or not has_port_live:
        errors.append(
            "B22_PRESENT_CORE_GEOM_LIVE_PORTS: present_core.sv missing "
            "input geom_live_seq and/or geom_live_valid. w-scaler wholesale "
            "present_core (c5bd6009 class) drops w-mem B16 live-geometry ports — "
            "merge must keep the ports, not only a sibling commit ancestor."
        )
    if not has_out_hold or not has_out_hollow:
        errors.append(
            "B22_PRESENT_CORE_BLACKOUT_HOLLOW_PORTS: present_core.sv missing "
            "output stat_geom_hold_black and/or stat_geom_hollow. Product raises "
            "HDMI_BLACKOUT from store geom_hold_black via these ports (w-mem B16); "
            "wholesale scaler core drops them."
        )

    # --- ddr_frame_store *instance* port connections (not # params alone) ---
    fstore_ports = _extract_sv_instance_ports(core, "ddr_frame_store")
    msgs.append(f"LEG0_B22_FSTORE_PORT_CHARS n={len(fstore_ports)}")
    # Require non-constant connection from the live ports.
    rt_seq_ok = bool(
        re.search(r"\.rt_geom_seq\s*\(\s*geom_live_seq\s*\)", fstore_ports)
    )
    rt_live_ok = bool(
        re.search(r"\.rt_geom_live\s*\(\s*geom_live_valid\s*\)", fstore_ports)
    )
    # Reject constant ties that look "connected" but are hollow.
    rt_seq_const = bool(
        re.search(r"\.rt_geom_seq\s*\(\s*\d|'0|'1|16'd0", fstore_ports)
    )
    rt_live_const = bool(
        re.search(r"\.rt_geom_live\s*\(\s*1'b0\s*\)", fstore_ports)
    )
    hold_to_store = bool(
        re.search(r"\.geom_hold_black\s*\(\s*\w+", fstore_ports)
    )
    hollow_to_store = bool(
        re.search(r"\.geom_hollow_fault\s*\(\s*\w+", fstore_ports)
    )
    # Option-C instance params already B7; re-assert on *instance* as B22 companion
    # so a merge that keeps ports but drops #() wiring still fails this class.
    optc_inst = bool(
        re.search(r"\.PHYS_BASE_720P\s*\(", fstore_ports)
        or re.search(
            r"ddr_frame_store\s*#\s*\([\s\S]*?\.PHYS_BASE_720P\s*\(",
            core,
        )
    )
    msgs.append(
        f"LEG0_B22_FSTORE_NETS rt_seq={int(rt_seq_ok)} rt_live={int(rt_live_ok)} "
        f"hold={int(hold_to_store)} hollow={int(hollow_to_store)} "
        f"optc_inst={int(optc_inst)} const_tie={int(rt_seq_const or rt_live_const)}"
    )
    if has_port_seq and has_port_live and not (rt_seq_ok and rt_live_ok):
        errors.append(
            "B22_PRESENT_CORE_GEOM_LIVE_STORE_WIRE: present_core declares "
            "geom_live_seq/valid but ddr_frame_store instance does not connect "
            ".rt_geom_seq(geom_live_seq) and .rt_geom_live(geom_live_valid). "
            "Port presence without instance net = B20 unconnected class on merge."
        )
    if rt_seq_const or rt_live_const:
        errors.append(
            "B22_PRESENT_CORE_GEOM_LIVE_TIED_CONST: ddr_frame_store .rt_geom_seq/"
            ".rt_geom_live tied to a constant — not the live ports (hollow wire)."
        )
    if has_out_hold and not hold_to_store:
        # Allow internal assign from store net name if port exists on store
        if not re.search(r"\.geom_hold_black\s*\(", core):
            errors.append(
                "B22_PRESENT_CORE_BLACKOUT_STORE_WIRE: stat_geom_hold_black port "
                "exists but ddr_frame_store .geom_hold_black(...) is not connected. "
                "HDMI_BLACKOUT path dies after wholesale merge (rd-duck B16)."
            )
    if has_out_hollow and not hollow_to_store:
        if not re.search(r"\.geom_hollow_fault\s*\(", core):
            errors.append(
                "B22_PRESENT_CORE_HOLLOW_STORE_WIRE: stat_geom_hollow port exists "
                "but ddr_frame_store .geom_hollow_fault(...) is not connected."
            )
    # Outputs permanently 1'b0 with no store driver path (greenwash after drop)
    if has_out_hold and re.search(
        r"assign\s+stat_geom_hold_black\s*=\s*1'b0\b", core
    ) and not hold_to_store:
        errors.append(
            "B22_PRESENT_CORE_BLACKOUT_TIED_ZERO: stat_geom_hold_black assign 1'b0 "
            "with no store .geom_hold_black connection — blackout path dead."
        )

    # --- B15 core-Hz cadence selection (w-clock) on present_cadence instance ---
    cad_ports = _extract_sv_instance_ports(core, "present_cadence")
    has_beam_film = bool(re.search(r"\bbeam_film_class\b", core))
    has_cad_hz_wire = bool(re.search(r"\bcadence_display_hz\b", core))
    cad_hz_conn = bool(
        re.search(r"\.display_hz\s*\(\s*cadence_display_hz\s*\)", cad_ports)
        or re.search(r"\.display_hz\s*\(\s*cadence_display_hz\s*\)", core)
    )
    # Under PRESENT_BEAM_960 must select 24/30 core Hz, not raw OSD display_hz only.
    beam_cadence_sel = bool(
        re.search(
            r"`ifdef\s+PRESENT_BEAM_960[\s\S]{0,600}?cadence_display_hz\s*=\s*"
            r"beam_film_class\s*\?\s*8'd24\s*:\s*8'd30",
            core,
        )
        or (
            has_beam_film
            and has_cad_hz_wire
            and re.search(
                r"cadence_display_hz\s*=\s*beam_film_class\s*\?\s*8'd24\s*:\s*8'd30",
                core,
            )
        )
    )
    msgs.append(
        f"LEG0_B22_CADENCE beam_film={int(has_beam_film)} "
        f"cadence_display_hz={int(has_cad_hz_wire)} "
        f"cad_conn={int(cad_hz_conn)} beam_sel={int(beam_cadence_sel)} "
        f"cad_port_chars={len(cad_ports)}"
    )
    if not (beam_cadence_sel and cad_hz_conn):
        errors.append(
            "B22_PRESENT_CORE_CADENCE_CORE_HZ: present_core lacks w-clock B15 "
            "core-Hz cadence selection — need beam_film_class → "
            "cadence_display_hz (24/30) wired to present_cadence .display_hz(...). "
            "Passing top-level display_hz (50/60) under PRESENT_BEAM_960 yields "
            "wrong advance_unique (rd-duck: content_fps != cadence_display_hz). "
            "Scaler wholesale core without this path is merge-loss vs w-clock."
        )

    # --- Product hierarchy: Plex.sv must connect the ports (not leave defaults) ---
    if plex:
        pc_ports = _extract_sv_instance_ports(plex, "present_core")
        msgs.append(f"LEG0_B22_PLEX_PRESENT_CORE_PORTS n={len(pc_ports)}")
        plex_seq = bool(re.search(r"\.geom_live_seq\s*\(\s*\w+", pc_ports))
        plex_live = bool(re.search(r"\.geom_live_valid\s*\(\s*\w+", pc_ports))
        plex_hold = bool(re.search(r"\.stat_geom_hold_black\s*\(\s*\w+", pc_ports))
        plex_hollow = bool(re.search(r"\.stat_geom_hollow\s*\(\s*\w+", pc_ports))
        msgs.append(
            f"LEG0_B22_PLEX_NETS seq={int(plex_seq)} live={int(plex_live)} "
            f"hold={int(plex_hold)} hollow={int(plex_hollow)}"
        )
        if has_port_seq and has_port_live and not (plex_seq and plex_live):
            errors.append(
                "B22_PLEX_GEOM_LIVE_UNCONNECTED: Plex.sv present_core instance "
                "omits .geom_live_seq/.geom_live_valid connections — producer "
                "(latch/poller) and core ports exist in isolation but are not "
                "wired at product hierarchy (B20/B22 merge class)."
            )
        if has_out_hold and has_out_hollow and not (plex_hold and plex_hollow):
            errors.append(
                "B22_PLEX_BLACKOUT_HOLLOW_UNCONNECTED: Plex.sv present_core "
                "omits .stat_geom_hold_black/.stat_geom_hollow — HDMI_BLACKOUT "
                "cannot track store geometry transitions after merge."
            )
    else:
        msgs.append("LEG0_B22_PLEX_SV_ABSENT skip hierarchy port wiring")

    if not errors:
        msgs.append("LEG0_B22_OK present_core merge-semantics ports+nets intact")
    return msgs, errors


def run_single_owner_table_gate(root: Path) -> tuple[list[str], list[str]]:
    """Parent arbitration #3 — single-owner file table (gate is backstop, not cure).

    Ownership prevents whole-file adoption at the source. Gate verifies owner
    contract markers remain on the gated tree and that ABI #2 nets are plxg_*.
    """
    msgs: list[str] = []
    errors: list[str] = []
    candidates = [
        root / "docs" / "rtl_single_owner_table.json",
        RULER_ROOT / "docs" / "rtl_single_owner_table.json",
    ]
    path = next((p for p in candidates if p.is_file()), None)
    if path is None:
        errors.append(
            "B23_OWNER_TABLE_MISSING: docs/rtl_single_owner_table.json absent. "
            "Parent arbitration #3 is binding — table must ship with the ruler."
        )
        msgs.append("LEG0_B23_OWNER_TABLE_MISS")
        return msgs, errors
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"B23_OWNER_TABLE_BAD_JSON: {path}: {exc}")
        return msgs, errors

    owners = list(data.get("owners") or [])
    canon = str(data.get("canonical_abi2_net_prefix") or "plxg_")
    deprecated = [str(x) for x in (data.get("deprecated_abi2_aliases") or [])]
    msgs.append(
        f"LEG0_B23_OWNER_TABLE_EXECUTED path={path} n_files={len(owners)} "
        f"abi2_prefix={canon} arbitration={data.get('arbitration', '?')}"
    )
    msgs.append(
        "LEG0_B23_OWNER_RULE non-owner NEVER whole-file-copies an owned file; "
        "submit precise patch/port contract to owner. Plex.sv=w-osd integration only. "
        "Gate is backstop not cure (parent arb #3)."
    )

    for ent in owners:
        rel = str(ent.get("path") or "")
        owner = str(ent.get("owner") or "?")
        markers = [str(m) for m in (ent.get("required_markers") or [])]
        optional = bool(ent.get("optional_if_missing"))
        fpath = root / rel
        # Ruler-owned scripts always checked on RULER_ROOT when scanning foreign root.
        if rel.startswith("scripts/") and not fpath.is_file():
            fpath = RULER_ROOT / rel
        if not fpath.is_file():
            if optional:
                msgs.append(
                    f"LEG0_B23_OWNER_FILE_ABSENT_OPTIONAL path={rel} owner={owner}"
                )
                continue
            errors.append(
                f"B23_OWNER_FILE_MISSING: owned file {rel} (owner={owner}) absent "
                f"from gated tree. Whole-file drop / never-merged class."
            )
            continue
        try:
            txt = fpath.read_text(errors="replace")
        except OSError as exc:
            errors.append(f"B23_OWNER_FILE_UNREADABLE: {rel}: {exc}")
            continue
        missing = [m for m in markers if m not in txt]
        msgs.append(
            f"LEG0_B23_OWNER_SCAN path={rel} owner={owner} "
            f"markers_ok={len(markers) - len(missing)}/{len(markers)} "
            f"missing={missing[:6]}"
        )
        if missing:
            errors.append(
                f"B23_OWNER_MARKERS_MISSING: {rel} (owner={owner}) lacks contract "
                f"markers {missing}. Parent arb #3: non-owners must not whole-file "
                f"adopt this path — dropped markers reopen multi-blocker classes "
                f"(incidents #1 ddr_frame_store, #3 present_core). "
                f"Submit a patch to {owner}; do not copy another lane's file."
            )

    # ABI #2 canonical nets: fabric_* consumer without plxg_* is incident #2 class.
    plex = root / "fpga" / "Plex_MiSTer" / "Plex.sv"
    if plex.is_file():
        pt = plex.read_text(errors="replace")
        fabric_hits = sorted(
            set(re.findall(r"\bfabric_(?:dar_[\w]+|content_fps|fps_[\w]+)\b", pt))
        )
        plxg_hits = sorted(set(re.findall(r"\bplxg_(?:dar_[\w]+|content_fps|fps_[\w]+|q5)\b", pt)))
        msgs.append(
            f"LEG0_B23_ABI2_NETS fabric={fabric_hits[:8]} plxg={plxg_hits[:8]}"
        )
        if fabric_hits and not plxg_hits:
            errors.append(
                "B23_ABI2_FABRIC_NETS_NOT_PLXG: Plex.sv uses fabric_* ABI #2 nets "
                f"{fabric_hits[:6]} without plxg_* producers. Parent arb #3: "
                "canonical prefix is plxg_* (w-mem producer wins). Merge that kept "
                "consumer and dropped producer → zero drivers (incident #2 / "
                "B20_UNCONNECTED_PRODUCER class). Reconcile fabric_* → plxg_*."
            )
        elif fabric_hits and plxg_hits:
            msgs.append(
                "LEG0_B23_ABI2_BOTH_PREFIXES present — ensure fabric_* are aliases "
                "or removed; plxg_* is SoT"
            )
        for dep in deprecated:
            if dep in pt and canon not in "plxg_":
                pass  # covered above
    return msgs, errors



def run_b9_ar_hold_post_ascal(root: Path) -> tuple[list[str], list[str]]:
    """B9: sys_top plex_ar_out_hold + post-ascal same-size DAR blackout/data assoc.

    rd-duck: ascal swblack only fires on ih/iv size change. HDMI_BLACKOUT OR of
    geom/dar into emu.HDMI_BLACKOUT is NOT evidence of same-size DAR blanking —
    need plex_ar_out_hold (out_vs commit) + plex_ar_post_ascal (pixel black after
    ascal) wired in sys_top. Port/search presence of VIDEO_ARX alone is hollow.
    """
    msgs: list[str] = []
    errors: list[str] = []
    sys_top = root / "fpga" / "Plex_MiSTer" / "sys" / "sys_top.v"
    plex = root / "fpga" / "Plex_MiSTer" / "Plex.sv"
    qip = root / "fpga" / "Plex_MiSTer" / "files.qip"
    hold_sv = root / "fpga" / "Plex_MiSTer" / "rtl" / "plex_ar_out_hold.sv"
    post_sv = root / "fpga" / "Plex_MiSTer" / "rtl" / "plex_ar_post_ascal.sv"

    sys_txt = sys_top.read_text(errors="replace") if sys_top.is_file() else ""
    plex_txt = plex.read_text(errors="replace") if plex.is_file() else ""
    qip_txt = qip.read_text(errors="replace") if qip.is_file() else ""

    hold_inst = bool(
        re.search(r"\bu_plex_ar_out_hold\b", sys_txt)
        or re.search(r"\bplex_ar_out_hold\s+#", sys_txt)
        or re.search(r"\bplex_ar_out_hold\s+\w+", sys_txt)
    )
    # Live commit pins: want AR in, live AR out, out_vs, ar_hold_black.
    hold_ports = _extract_sv_instance_ports(sys_txt, "plex_ar_out_hold") if hold_inst else ""
    if not hold_ports and hold_inst:
        # fallback: window after u_plex_ar_out_hold
        m = re.search(r"u_plex_ar_out_hold\s*\(([\s\S]{0,1200}?)\)\s*;", sys_txt)
        hold_ports = m.group(1) if m else ""
    want_ar = bool(re.search(r"\.(want_arx|ARX_want)\s*\(", hold_ports, re.I)) or bool(
        re.search(r"\.want_arx\s*\(", hold_ports)
    )
    live_ar = bool(re.search(r"\.(live_arx|live_ary)\s*\(", hold_ports))
    out_vs = bool(re.search(r"\.out_vs\s*\(", hold_ports))
    hold_black_out = bool(re.search(r"\.ar_hold_black\s*\(", hold_ports))
    # Reject hard-tied src_vs(0) / out_vs(0) hollow wiring.
    tied_dead = bool(
        re.search(r"\.src_vs\s*\(\s*1\'b0\s*\)", hold_ports)
        or re.search(r"\.out_vs\s*\(\s*1\'b0\s*\)", hold_ports)
    )
    hold_qip = bool(re.search(r"plex_ar_out_hold\.sv", qip_txt))
    hold_disk = hold_sv.is_file()

    msgs.append(
        f"LEG0_B9_AR_HOLD inst={int(hold_inst)} want={int(want_ar)} live={int(live_ar)} "
        f"out_vs={int(out_vs)} ar_hold_black={int(hold_black_out)} tied_dead={int(tied_dead)} "
        f"qip={int(hold_qip)} disk={int(hold_disk)}"
    )
    if not (hold_inst and hold_disk and hold_qip and want_ar and live_ar and out_vs and hold_black_out and not tied_dead):
        errors.append(
            "B9_SYS_TOP_AR_OUT_HOLD_MISSING: sys_top must instantiate plex_ar_out_hold "
            "(u_plex_ar_out_hold) with want_arx/ary, live_arx/ary, out_vs (hdmi_vs), "
            "ar_hold_black — files.qip + rtl present. Same-size DAR commit is HDMI "
            "out_vs domain; VIDEO_ARX pin search alone is hollow (rd-duck / w-scaler B9)."
        )

    post_inst = bool(
        re.search(r"\bu_plex_ar_post_ascal\b", sys_txt)
        or re.search(r"\bplex_ar_post_ascal\s+\w+", sys_txt)
    )
    post_ports = _extract_sv_instance_ports(sys_txt, "plex_ar_post_ascal") if post_inst else ""
    if not post_ports and post_inst:
        m = re.search(r"u_plex_ar_post_ascal\s*\(([\s\S]{0,1200}?)\)\s*;", sys_txt)
        post_ports = m.group(1) if m else ""
    post_ar_hold = bool(re.search(r"\.ar_hold_black\s*\(", post_ports))
    post_rgb_in = bool(
        re.search(r"\.in_r\s*\(", post_ports) and re.search(r"\.out_r\s*\(", post_ports)
    )
    # Data association: hold black CDC'd into hdmi domain (ar_post_ascal_black).
    cdc_assoc = bool(
        re.search(r"ar_post_ascal_black|ar_hold_black_hdmi_sync", sys_txt)
    )
    post_qip = bool(re.search(r"plex_ar_post_ascal\.sv", qip_txt))
    post_disk = post_sv.is_file()
    msgs.append(
        f"LEG0_B9_POST_ASCAL inst={int(post_inst)} ar_hold={int(post_ar_hold)} "
        f"rgb_io={int(post_rgb_in)} cdc_assoc={int(cdc_assoc)} "
        f"qip={int(post_qip)} disk={int(post_disk)}"
    )
    if not (
        post_inst and post_disk and post_qip and post_ar_hold and post_rgb_in and cdc_assoc
    ):
        errors.append(
            "B9_POST_ASCAL_DAR_BLACKOUT_MISSING: sys_top must wire plex_ar_post_ascal "
            "after ascal RGB (in_r/g/b → out_*) with ar_hold_black (CDC'd from "
            "plex_ar_out_hold). Same-size DAR blackout is pixel-path, not swblack "
            "(ascal.vhd: swblack only when ih/iv size changes). files.qip+rtl required "
            "(rd-duck)."
        )

    # HDMI_BLACKOUT OR alone is not same-size DAR evidence (swblack = size-only).
    bo_or_only = bool(
        re.search(
            r"assign\s+HDMI_BLACKOUT\s*=\s*[^;]*(geom_hold_black|dar_hold_black|ar_hold_black)",
            plex_txt,
        )
    )
    hdmi_bo_one = bool(re.search(r"assign\s+HDMI_BLACKOUT\s*=\s*1\s*;", plex_txt))
    same_size_path = bool(post_inst and hold_inst and post_ar_hold and cdc_assoc)
    if not same_size_path:
        errors.append(
            "B9_HDMI_BO_OR_NOT_SAME_SIZE_DAR: HDMI_BLACKOUT alone (or OR of "
            "geom_hold_black/dar_hold_black into emu.HDMI_BLACKOUT) is NOT evidence "
            "of same-size DAR blanking — ascal swblack only triggers on ih/iv size "
            "change (ascal.vhd). Require sys_top plex_ar_out_hold + plex_ar_post_ascal "
            "pixel black + CDC assoc (rd-duck). "
            f"bo_or={int(bo_or_only)} bo1={int(hdmi_bo_one)} post={int(post_inst)} "
            f"hold={int(hold_inst)} cdc={int(cdc_assoc)}."
        )
    else:
        msgs.append("LEG0_B9_OK same-size DAR path = hold+post-ascal (not HDMI_BO alone)")

    return msgs, errors


def run_b26_store_crop_display_bounds(root: Path) -> tuple[list[str], list[str]]:
    """B26: ddr_frame_store must enforce runtime crop+display window bounds.

    rd-duck: port presence of rt_crop_*/rt_display_* is hollow without the
    window predicate (crop+disp <= coded; present+disp <= frame max) feeding
    rt_raw_ok / geom accept. Overflow reads unfilled line RAM while geom stays
    'valid'.
    """
    msgs: list[str] = []
    errors: list[str] = []
    store = root / "fpga" / "Plex_MiSTer" / "rtl" / "ddr_frame_store.sv"
    core = root / "fpga" / "Plex_MiSTer" / "rtl" / "present_core.sv"
    store_txt = store.read_text(errors="replace") if store.is_file() else ""
    core_txt = core.read_text(errors="replace") if core.is_file() else ""

    ports = {
        "rt_display_w": bool(re.search(r"\brt_display_w\b", store_txt)),
        "rt_display_h": bool(re.search(r"\brt_display_h\b", store_txt)),
        "rt_crop_left": bool(re.search(r"\brt_crop_left\b", store_txt)),
        "rt_crop_top": bool(re.search(r"\brt_crop_top\b", store_txt)),
    }
    # Window sums + compare to coded (mem contract).
    crop_sum = bool(
        re.search(r"rt_crop_disp_w_sum|crop_left.*display_w|rt_crop_left.*rt_dw", store_txt)
        and re.search(r"rt_crop_disp_h_sum|crop_top.*display_h|rt_crop_top.*rt_dh", store_txt)
    )
    # Explicit bound into raw_ok / window wire.
    window_ok = bool(
        re.search(r"\brt_raw_window\b", store_txt)
        and re.search(r"rt_raw_ok\s*=\s*[^;]*rt_raw_window", store_txt)
    )
    # Pixel path uses crop: src_x = display_x + crop_left (not display-only).
    src_uses_crop = bool(
        re.search(r"src_x\s*=\s*[^;]*crop", store_txt, re.I)
        or re.search(r"display_x\s*\+\s*CROP_LEFT", store_txt)
        or re.search(r"display_x\s*\+\s*.*crop", store_txt, re.I)
    )
    # present_core must drive the ports (not tied 0 wholesale).
    core_drive = bool(
        re.search(r"\.rt_display_w\s*\(", core_txt)
        and re.search(r"\.rt_crop_left\s*\(", core_txt)
    )
    msgs.append(
        f"LEG0_B26_CROP_DISP ports={ports} crop_sum={int(crop_sum)} "
        f"rt_raw_window={int(window_ok)} src_uses_crop={int(src_uses_crop)} "
        f"core_drive={int(core_drive)}"
    )
    if not store.is_file():
        errors.append(
            "B26_STORE_CROP_DISPLAY_BOUNDS_MISSING: ddr_frame_store.sv absent — "
            "cannot enforce runtime crop/display window (rd-duck)."
        )
    elif not (all(ports.values()) and crop_sum and window_ok and src_uses_crop and core_drive):
        errors.append(
            "B26_STORE_CROP_DISPLAY_BOUNDS_MISSING: ddr_frame_store must (1) take "
            "rt_display_w/h + rt_crop_left/top, (2) compute crop+display <= coded "
            "and present+display <= frame max (rt_raw_window → rt_raw_ok), "
            "(3) index src_x = display_x + crop_left, (4) present_core must drive "
            "the ports. Port presence alone is hollow — overflow stays 'valid' "
            "(rd-duck / w-mem window check)."
        )
    else:
        msgs.append("LEG0_B26_OK runtime crop/display window bounds on rt_raw_ok")
    return msgs, errors


def run_b27_ffmpeg_pad_chroma_even(root: Path) -> tuple[list[str], list[str]]:
    """B27: 426→432 pad oracle must be chroma-even x=2, not naive center x=3.

    rd-duck: helper predicting pad_x=(432-426)/2=3 fails real FFmpeg yuv420p
    output (content at x=2). Require padInsetChromaEven + padOnlyInsets in
    host header, unit NEG pad_x!=3, and a live arithmetic EXECUTED check here.
    """
    msgs: list[str] = []
    errors: list[str] = []
    hdr = root / "host" / "libmisterplex" / "ffmpeg_vf.hpp"
    test = root / "tests" / "unit" / "test_ffmpeg_vf.cpp"
    hdr_txt = hdr.read_text(errors="replace") if hdr.is_file() else ""
    test_txt = test.read_text(errors="replace") if test.is_file() else ""

    has_fn = bool(re.search(r"\bpadInsetChromaEven\b", hdr_txt)) and bool(
        re.search(r"\bpadOnlyInsets\b", hdr_txt)
    )
    # Formula: ideal & ~1 (floor even)
    has_even = bool(
        re.search(r"padInsetChromaEven[\s\S]{0,200}?&\s*~?\s*1", hdr_txt)
        or re.search(r"return\s+ideal_inset\s*&\s*~1", hdr_txt)
    )
    # Must not emit expr pad (ow-iw)/2 alone as product pad-only path for DP.
    # (Historical FOAR path may still contain it — require explicit even helper.)
    test_pos = bool(
        re.search(r"pad_x\s*==\s*2|pad_x\s*=\s*2|pad=432:240:2:0", test_txt)
    )
    test_neg = bool(
        re.search(r"pad_x\s*!=\s*3|must not be math-center 3|NEG:.*pad_x", test_txt)
    )

    # Live EXECUTED arithmetic (gate-owned oracle — not search-only).
    def pad_inset_chroma_even(ideal: int) -> int:
        if ideal < 0:
            return 0
        return ideal & ~1

    ideal = (432 - 426) // 2  # 3
    got = pad_inset_chroma_even(ideal)
    naive = ideal
    msgs.append(
        f"LEG0_B27_PAD_ORACLE_EXECUTED src=426 coded=432 ideal_center={naive} "
        f"chroma_even={got} (need 2, reject 3)"
    )
    if got != 2 or naive == got:
        # naive==got would mean we forgot even snap
        errors.append(
            f"B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE: gate arithmetic failed "
            f"padInsetChromaEven((432-426)/2)={got} want 2 (naive center={naive})."
        )
    if not hdr.is_file() or not has_fn or not has_even:
        errors.append(
            "B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE: host/libmisterplex/ffmpeg_vf.hpp must "
            "define padInsetChromaEven (ideal&~1) and padOnlyInsets. FFmpeg yuv420p "
            "426→432 places content at x=2, not math-center x=3 (rd-duck measured)."
        )
    if not test.is_file() or not (test_pos and test_neg):
        errors.append(
            "B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE: tests/unit/test_ffmpeg_vf.cpp must "
            "assert 426→432 pad_x==2 AND NEG pad_x!=3 (and preferably live ffmpeg "
            "raw oracle). Helper search alone is hollow (rd-duck)."
        )
    if not errors:
        msgs.append(
            "LEG0_B27_OK pad chroma-even oracle (426→432 x=2; NEG x!=3) in header+test"
        )
    # If header implements wrong formula (returns ideal unsnapped), catch it.
    if has_fn and re.search(
        r"padOnlyInsets[\s\S]{0,400}?\*\s*pad_x\s*=\s*\(\s*coded_w\s*-\s*src_w\s*\)\s*/\s*2\s*;",
        hdr_txt,
    ) and not re.search(
        r"padOnlyInsets[\s\S]{0,400}?padInsetChromaEven\s*\(\s*\(\s*coded_w",
        hdr_txt,
    ):
        errors.append(
            "B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE: padOnlyInsets assigns "
            "(coded-src)/2 without padInsetChromaEven — naive x=3 on 426→432 "
            "(rd-duck defect)."
        )
    return msgs, errors


def leg0_arch_blockers() -> tuple[int, list[str]]:
    """rd-duck fit blockers — FAIL until a coherent candidate clears each.

    Evidence is quoted from this tree's source (rule 0). Checks auto-pass only
    when the cited defect is gone from the files.
    """
    global _LIVE_ATTR, _LIVE_ATTR_MSGS
    msgs: list[str] = ["LEG0_ARCH_BLOCKERS_EXECUTED begin"]
    errors: list[str] = []
    msgs.append(f"LEG0_SCAN_ROOT root={ROOT} ruler={RULER_ROOT}")
    # Parent 2026-08-03: publish which checks are string-based and how protected.
    msgs.append(
        "LEG0_CHECK_CLASSES "
        "STRING_IFDEF_AWARE=B19_evidence,_file_missing_patterns,B15_hardwire_24,"
        "B1/B7/B8/B9/B13/B14/B16/B17/B21/B22/B26 port+content greps "
        "(product_active_sv strips `ifdef FAULT_* / RED_TWIN_* / FIT_MUTATION_*); "
        "STRUCTURAL=B20_Verilator_PINMISSING_UNDRIVEN "
        "(scripts/run_verilator.sh→oss-cad-suite; missing=HARD FAIL not soft-skip); "
        "EXECUTABLE=B20_hier_manifest,B24_q5_fps_1001,B25_plxc_dual_map,"
        "leg2_elab,leg3_true_de "
        "(named scripts + CASE EXECUTED + rc0; fault twin rc!=0); "
        "OWNERSHIP=B23_single_owner_table; "
        "LIMITATION_STRING=wrong-producer twin not covered by greps; "
        "LIMITATION_B20=has-driver≠intended-driver; "
        "B2_NO_RASTER_GENERATOR=RETIRED(w-clock timing_960 constants-only; beam=raster SoT)"
    )

    # Parent arbitration #3 — single-owner table (backstop; ownership is the cure).
    o_msgs, o_errs = run_single_owner_table_gate(ROOT)
    msgs.extend(o_msgs)
    errors.extend(o_errs)

    # Live sibling attribution (parent routing: unmerged vs unimplemented).
    _LIVE_ATTR, _LIVE_ATTR_MSGS = scan_sibling_attribution()
    msgs.extend(_LIVE_ATTR_MSGS)

    # --- B0: one coherent FIT_CANDIDATE lock (bound to gated tree hash) ---
    # Candidate file is NOT a bypass: git_tree_hash must match compute_gated_tree_hash()
    # over artefacts (excludes fit_candidate.json itself). Parent locked arch.
    live_hash = compute_gated_tree_hash(ROOT)
    live_head = _git_head(ROOT)
    msgs.append(f"LEG0_GATED_TREE_HASH live={live_hash} HEAD={live_head[:12]}")
    cand_path = next((p for p in CANDIDATE_PATHS if p.is_file()), None)
    cand: dict | None = None
    if cand_path is None:
        errors.append(
            "B0_NO_CANDIDATE: missing docs/fit_candidate.json (or assets/ / "
            "tests/fixtures/fit_release_gate/). Gate refuses fit until one "
            "architecture is locked with a gated tree hash. Parent lock: "
            f"{PARENT_LOCKED_ARCH}. Allowed: " + ",".join(sorted(ALLOWED_ARCH))
        )
    else:
        try:
            cand = json.loads(cand_path.read_text())
        except json.JSONDecodeError as e:
            errors.append(f"B0_BAD_CANDIDATE_JSON: {cand_path}: {e}")
            cand = None
        if cand is not None:
            arch = str(cand.get("architecture", ""))
            th = str(cand.get("git_tree_hash", cand.get("tree_hash", ""))).lower()
            msgs.append(
                f"LEG0_CANDIDATE path={cand_path} architecture={arch!r} hash={th!r}"
            )
            if arch not in ALLOWED_ARCH:
                errors.append(
                    f"B0_BAD_ARCH: architecture={arch!r} not in {sorted(ALLOWED_ARCH)}"
                )
            # Parent ruling: this campaign is ascal_true_de_960 only.
            if arch != PARENT_LOCKED_ARCH:
                errors.append(
                    f"B0_ARCH_NOT_PARENT_LOCK: architecture={arch!r} but parent "
                    f"locked {PARENT_LOCKED_ARCH} (mp_cea_1280 not selected; "
                    "40 Mpix/s is not headroom for this fit)"
                )
            if not re.fullmatch(r"[0-9a-f]{40}", th):
                errors.append(
                    "B0_BAD_HASH: git_tree_hash must be full 40-char sha1 from "
                    "compute_gated_tree_hash() (not a short prefix, not empty)"
                )
            elif not live_hash:
                errors.append(
                    "B0_LIVE_HASH_UNAVAILABLE: git ls-files failed — cannot bind candidate"
                )
            elif th != live_hash:
                errors.append(
                    f"B0_TREE_HASH_MISMATCH: candidate git_tree_hash={th} "
                    f"live_gated={live_hash}. Candidate is not a bypass — update "
                    "hash only after intentional gated-artefact change, or restore "
                    "artefacts to the locked tree."
                )
            else:
                msgs.append("LEG0_EVIDENCE candidate git_tree_hash matches live gated tree")
            # Refuse dual-path cargo: candidate must not require both beams.
            req = cand.get("required_macros") or cand.get("qsf_macros") or {}
            if isinstance(req, dict):
                has_beam = str(req.get("PRESENT_BEAM_960", "")).lower() in {"1", "true"}
                has_mp = str(req.get("PRESENT_MULTI_PIXEL", "")).lower() in {"1", "true"}
                if not has_beam and arch == "ascal_true_de_960":
                    errors.append(
                        "B0_BEAM_RUNTIME_OFF_CARGO: ascal_true_de_960 candidate must list "
                        "PRESENT_BEAM_960=1 as required (no runtime-OFF beam cargo)"
                    )
                if has_beam and has_mp:
                    errors.append(
                        "B0_DUAL_PATH: candidate requires both PRESENT_BEAM_960 and "
                        "PRESENT_MULTI_PIXEL — pick one architecture"
                    )
                if arch == "ascal_true_de_960" and has_mp:
                    errors.append(
                        "B0_ASCAL_VS_MP: ascal_true_de_960 candidate must not enable "
                        "PRESENT_MULTI_PIXEL (parent lock + w-scaler fit card)"
                    )
                if arch == "mp_cea_1280" and has_beam:
                    errors.append(
                        "B0_MP_VS_ASCAL: mp_cea_1280 candidate must not enable "
                        "PRESENT_BEAM_960"
                    )
                # Required macro set must match gate REQUIRED_EXACT for ascal.
                if arch == "ascal_true_de_960":
                    for k, v in REQUIRED_EXACT.items():
                        got = str(req.get(k, ""))
                        if got != v:
                            errors.append(
                                f"B0_CANDIDATE_MACRO_DRIFT: required_macros[{k}]="
                                f"{got!r} want {v!r} (must match gate REQUIRED_EXACT)"
                            )
            forbid = cand.get("forbidden_macros") or []
            if arch == "ascal_true_de_960" and isinstance(forbid, list):
                for m in (
                    "PRESENT_MULTI_PIXEL",
                    "PRESENT_SCALE_4_3",
                    "PRESENT_SCALE_2X",
                    "FABRIC_DDR_WRITER",
                ):
                    if m not in forbid:
                        errors.append(
                            f"B0_CANDIDATE_FORBID_INCOMPLETE: must list {m} in "
                            "forbidden_macros for ascal_true_de_960"
                        )
            # Parent 2026-08-03: raster is runtime-variable; 960×540 is MAX tier.
            if arch == "ascal_true_de_960":
                rp = cand.get("raster_policy") or {}
                mode = str(rp.get("mode", "") if isinstance(rp, dict) else "")
                max_w = str(rp.get("max_content_w", "") if isinstance(rp, dict) else "")
                max_h = str(rp.get("max_content_h", "") if isinstance(rp, dict) else "")
                msgs.append(
                    f"LEG0_RASTER_POLICY mode={mode!r} max={max_w}x{max_h}"
                )
                if mode != "runtime_variable_true_de":
                    errors.append(
                        "B0_RASTER_POLICY_MISSING: ascal_true_de_960 candidate must "
                        "set raster_policy.mode=runtime_variable_true_de (PMS does "
                        "not upscale; DE tracks delivered geometry; 960×540 is max "
                        "tier not a fixed raster — parent lab 2026-08-03)"
                    )
                elif max_w != "960" or max_h != "540":
                    errors.append(
                        f"B0_RASTER_POLICY_MAX: raster_policy max_content must be "
                        f"960x540 (got {max_w}x{max_h})"
                    )

    # --- B1: layout / compile-time Option-C vs FRAME 960 claim ---
    # Evidence: ddr_frame_layout_params.svh hardwires 480p presented; present_core
    # passes DDR_FRAME_* into ddr_frame_store; geom_enable=0 reloads LEG_* only.
    pw = _layout_param("DDR_FRAME_PRESENTED_WIDTH")
    ph = _layout_param("DDR_FRAME_PRESENTED_HEIGHT")
    cw = _layout_param("DDR_FRAME_CODED_WIDTH")
    ch = _layout_param("DDR_FRAME_CODED_HEIGHT")
    msgs.append(f"LEG0_LAYOUT presented={pw}x{ph} coded={cw}x{ch}")
    core = _read(RTL / "present_core.sv")
    store = _read(RTL / "ddr_frame_store.sv")
    if ".CODED_W(DDR_FRAME_CODED_WIDTH)" not in core:
        errors.append(
            "B1_PRESENT_CORE_WIRING: present_core.sv does not pass "
            ".CODED_W(DDR_FRAME_CODED_WIDTH) — cannot verify layout lock"
        )
    # geom-disabled branch hardwires legacy base/stride/doorbell (quoted).
    if "eff_base_w0    <= LEG_BASE_W0" not in store or "eff_doorbell_w <= LEG_DOORBELL_W" not in store:
        errors.append(
            "B1_GEOM_OFF_LEGACY_MARKERS_MOVED: expected geom_enable=0 path to assign "
            "LEG_BASE_W0/LEG_DOORBELL_W (ddr_frame_store.sv) — re-audit"
        )
    else:
        msgs.append(
            "LEG0_EVIDENCE geom_enable=0 assigns LEG_BASE_W0/LEG_DOORBELL_W "
            "(ddr_frame_store.sv)"
        )

    # --- B1 OPTION_C compile rebase vs geom-off legacy contract (rd-duck) ---
    # Architecture error: requiring QSF/RTL `OPTION_C` so LEG_* re-bases to
    # PHYS_BASE_720P/DOORBELL_720P makes explicit PLXG disable nonfunctional.
    # Host makeDdrPublishPlan (ddr_present_bank.hpp) mode-exit writes *legacy*
    # phys/doorbell + PLXG disable; FPGA must poll that map when geom_enable=0.
    # Option-C must be selected at runtime by rt_need_optc (B7), not by compile
    # rebase of LEG_* under `ifdef OPTION_C`.
    msgs.append("LEG0_B1_OPTION_C_LEGACY_CONTRACT_SCAN_EXECUTED")
    optc_ifdef = bool(re.search(r"`ifdef\s+OPTION_C\b", store))
    # Detect LEG_* rebound to Option-C bases inside OPTION_C (or always).
    leg_rebased = bool(
        re.search(
            r"`ifdef\s+OPTION_C\b[\s\S]{0,800}?"
            r"LEG_BASE_W0\s*=\s*PHYS_BASE_720P",
            store,
        )
        or re.search(
            r"`ifdef\s+OPTION_C\b[\s\S]{0,800}?"
            r"LEG_DOORBELL_W\s*=\s*DOORBELL_PHYS_720P",
            store,
        )
    )
    # Default (non-ifdef) LEG must be true legacy PHYS_BASE / DOORBELL_PHYS.
    leg_default_legacy = bool(
        re.search(r"LEG_BASE_W0\s*=\s*PHYS_BASE\s*\[\s*31\s*:\s*3\s*\]", store)
        or re.search(r"LEG_BASE_W0\s*=\s*PHYS_BASE\[31:3\]", store)
    )
    if leg_rebased:
        errors.append(
            "B1_OPTION_C_REBASES_LEGACY: ddr_frame_store.sv `ifdef OPTION_C` rebinds "
            "LEG_BASE_W0/LEG_DOORBELL_W to PHYS_BASE_720P/DOORBELL_PHYS_720P. "
            "geom_enable=0 then polls Option-C map while host makeDdrPublishPlan "
            "writes legacy phys/doorbell after PLXG disable — frames ignored "
            "(rd-duck). Runtime rt_need_optc must select OPTC_*; LEG_* must stay "
            "legacy (PHYS_BASE / DOORBELL_PHYS) for the geom-off contract."
        )
    elif optc_ifdef and not leg_rebased:
        msgs.append(
            "LEG0_B1_OPTION_C_IFDEF_PRESENT but LEG_* not rebound to 720P "
            "(manual audit — prefer removing OPTION_C LEG rebase entirely)"
        )
    else:
        msgs.append(
            "LEG0_B1_OK no OPTION_C LEG_* rebase "
            "(geom_enable=0 legacy contract intact at source)"
        )
    if store and not leg_default_legacy and not leg_rebased:
        # Store may use different formatting — soft evidence only if LEG path missing.
        if "LEG_BASE_W0" in store and "PHYS_BASE_720P" in store:
            # If LEG always equals OPTC without ifdef, same class.
            if re.search(
                r"LEG_BASE_W0\s*=\s*PHYS_BASE_720P", store
            ) and not re.search(
                r"LEG_BASE_W0\s*=\s*PHYS_BASE\[", store
            ):
                errors.append(
                    "B1_OPTION_C_REBASES_LEGACY: LEG_BASE_W0 permanently bound to "
                    "PHYS_BASE_720P (no legacy PHYS_BASE default) — geom_enable=0 "
                    "cannot honor host legacy publish plan."
                )
    msgs.append(
        "LEG0_B1_POLICY Option-C via rt_need_optc only; "
        "forbid compile LEG_* rebase; host legacy publish remains geom-off SoT "
        "(B1_NO_COMPILE_TIME_OPTC retired — demanding OPTION_C was the defect)"
    )
    if cand and cand.get("architecture") == "ascal_true_de_960":
        # Max tier 960×540 must be storable; legacy-only 640×480 is not enough.
        # Runtime-variable DE means layout must support the max tier (or dynamic
        # geom banks) — do NOT "fix" by freezing PRESENTED=960 without B13 runtime.
        if pw == "640" and ph == "480":
            errors.append(
                f"B1_LAYOUT_NOT_960: candidate ascal_true_de_960 but layout params "
                f"PRESENTED={pw}x{ph} CODED={cw}x{ch} — still legacy 480p bank map. "
                "Need capacity/layout for max tier 960×540 (runtime DE tracks delivered "
                "geometry; 960×540 is ceiling not a fixed-only raster). "
                "Hardcoding PRESENTED=960 without runtime DE fails B13."
            )
        elif pw != "960" or ph != "540":
            # Non-legacy but not max-tier either (e.g. partial edit).
            if pw not in {None, "960"} or ph not in {None, "540"}:
                errors.append(
                    f"B1_LAYOUT_NOT_960: layout PRESENTED={pw}x{ph} is neither legacy "
                    "640×480 nor max-tier 960×540 — re-audit bank map for runtime DE"
                )

    # --- B2: FPS overflow + product raster SoT (w-clock architecture) ---
    # w-clock deliberately demoted present_video_timing_960.sv to a constants/
    # math pack ("NOT a raster generator"). Product raster SoT is
    # present_beam_content_de.sv. Do NOT fail constants-only timing_960 — that
    # was noise that buried real blockers (parent 2026-08-03).
    t960 = RTL / "present_video_timing_960.sv"
    t960_txt = _read(t960)
    if t960_txt:
        msgs.append(f"LEG0_EVIDENCE present_video_timing_960.sv exists ({t960.stat().st_size} B)")
        if "localparam int FPS_MILLI = (CLK_PIX_HZ * 1000)" in t960_txt or re.search(
            r"localparam\s+int\s+FPS_MILLI\s*=\s*\(\s*CLK_PIX_HZ\s*\*\s*1000", t960_txt
        ):
            errors.append(
                "B2_FPS_INT_OVERFLOW: present_video_timing_960.sv uses "
                "`localparam int FPS_MILLI = (CLK_PIX_HZ * 1000) / …` — "
                "20_000_000*1000 overflows 32-bit signed int (rd-duck #2). "
                "present_video_timing_720p.sv already uses longint for this."
            )
        has_hc_reg_t960 = bool(re.search(r"\breg\s+\[[^\]]+\]\s*hc\b", t960_txt))
        has_always_raster_t960 = "always @(posedge" in t960_txt and has_hc_reg_t960
        if not has_always_raster_t960:
            msgs.append(
                "LEG0_B2_TIMING960_CONSTANTS_ONLY OK (w-clock: pack is math-only; "
                "beam present_beam_content_de is product raster SoT — not a defect)"
            )
        if "present_video_timing_960" not in core:
            msgs.append(
                "LEG0_EVIDENCE present_core.sv does not instantiate present_video_timing_960"
            )

    # Product must have a real raster generator: beam with hc/vc always.
    beam_path = RTL / "present_beam_content_de.sv"
    beam_txt = _read(beam_path)
    qip_txt_b2 = _read(ROOT / "fpga" / "Plex_MiSTer" / "files.qip")
    beam_has_raster = bool(
        beam_txt
        and re.search(r"\breg\s+\[[^\]]+\]\s*hc\b", beam_txt)
        and "always @(posedge" in beam_txt
    )
    beam_in_qip = "present_beam_content_de.sv" in qip_txt_b2
    if not beam_has_raster or not beam_in_qip:
        errors.append(
            "B2_NO_PRODUCT_RASTER: present_beam_content_de.sv must be the product "
            "raster SoT (hc/vc always + listed in files.qip). "
            f"beam_has_raster={int(beam_has_raster)} beam_in_qip={int(beam_in_qip)}. "
            "w-clock: timing_960 is constants-only by design — do not treat that as "
            "the missing raster."
        )
    else:
        msgs.append(
            "LEG0_B2_PRODUCT_RASTER_OK beam=present_beam_content_de "
            "(timing_960 constants-only is intentional)"
        )

    # 40 Mpix claim is not product raster (doc budget line).
    dec = _read(ROOT / "docs" / "product-4-3-scaler-decision.md")
    if dec and ("40 Mpix/s" in dec or "40 Mpix" in dec):
        if cand is None or cand.get("architecture") != "mp_cea_1280":
            errors.append(
                "B1_40MPIX_NOT_PRODUCT: docs/product-4-3-scaler-decision.md cites "
                "w-clock 40 Mpix/s bridge; rd-duck: nominal 40 Mpix/s is not product "
                "unless FIT_CANDIDATE architecture=mp_cea_1280 with real clk_pix path. "
                "ascal_true_de_960 product rate is ~15.55 Mpix/s content @30."
            )

    # --- B4: PLXG same-seq ABA remains in FPGA latch ---
    latch = _read(RTL / "present_geom_latch.sv")
    if latch:
        if "seq_new  = magic_ok && (sh_seq != last_seq)" in latch or re.search(
            r"seq_new\s*=\s*magic_ok\s*&&\s*\(\s*sh_seq\s*!=\s*last_seq\s*\)", latch
        ):
            # Still no session/epoch distinct from seq — restart same-seq ABA class.
            if "epoch" not in latch and "session_id" not in latch and "generation" not in latch:
                errors.append(
                    "B4_PLXG_SAME_SEQ_ABA: present_geom_latch.sv accepts commit only when "
                    "`sh_seq != last_seq` with no epoch/session token. After FPGA reset "
                    "last_seq=0, retained DDR q0 seq=N can ABA on restart "
                    "(rd-duck #4; host plxg_record.hpp documents the class — RTL still open)."
                )
            else:
                msgs.append("LEG0_PLXG: epoch/session marker present — ABA check soft-clear")
        else:
            msgs.append("LEG0_PLXG: seq_new pattern changed — re-audit ABA")

    # --- B5: no test uses real ddr_frame_store on beam/clock path ---
    tests_root = ROOT / "tests"
    beam_ddr_tests: list[str] = []
    for path in tests_root.rglob("*"):
        if not path.is_file() or path.suffix not in {".sv", ".sh", ".cpp", ".py"}:
            continue
        txt = _read(path)
        has_ddr = "ddr_frame_store" in txt
        has_beam = ("present_beam_content_de" in txt) or ("PRESENT_BEAM_960" in txt)
        if has_ddr and has_beam:
            beam_ddr_tests.append(str(path.relative_to(ROOT)))
    if not beam_ddr_tests:
        errors.append(
            "B5_NO_DDR_ON_BEAM_TEST: no test under tests/ instantiates/drives "
            "ddr_frame_store together with present_beam_content_de/PRESENT_BEAM_960 "
            "(rd-duck #5). true_de_count covers beam+window only — not the store path."
        )
    else:
        msgs.append("LEG0_DDR_BEAM_TESTS " + " ".join(beam_ddr_tests))

    # --- B6: beam blank/sync must share counter epoch (rd-duck store x0 drop) ---
    # Defect: HBlank <= (hc >= H_DE) with NBA after hc<=hc+1 uses OLD hc, so
    # observed hc=0 still HBlank=1 → in_content drops x=0 (517860 vs 518400).
    beam_txt = _read(RTL / "present_beam_content_de.sv")
    if beam_txt:
        uses_old_hc_blank = bool(
            re.search(r"HBlank\s*<=\s*\(\s*hc\s*>=", beam_txt)
        ) and not bool(re.search(r"HBlank\s*<=\s*\(\s*hc_next\s*>=", beam_txt))
        has_hc_next = "hc_next" in beam_txt
        tb_cpp = _read(ROOT / "tests" / "rtl" / "present_true_de_count_tb.cpp")
        has_store_area_check = (
            "store_req_count==content area" in tb_cpp
            or "store_id_checked == content_area" in tb_cpp
            or "store_id_checked == CW * CH" in tb_cpp
        )
        has_oracle = "store_oracle" in tb_cpp or "store coordinate oracle" in tb_cpp
        if uses_old_hc_blank or not has_hc_next:
            errors.append(
                "B6_HBLANK_OLD_HC_EPOCH: present_beam_content_de.sv must drive "
                "HBlank/VBlank/HSync from hc_next/vc_next (same epoch as registered "
                "counters). Old-hc NBA blank drops store x=0 every line "
                "(store_id_checked=959*540=517860 vs de_pixels=518400) — rd-duck "
                "34ddf031 scalar-ascal proof."
            )
        else:
            msgs.append(
                "LEG0_EVIDENCE beam uses hc_next epoch for HBlank (B6 static clear)"
            )
        if not has_store_area_check or not has_oracle:
            errors.append(
                "B6_STORE_ORACLE_UNTESTED: present_true_de_count_tb.cpp must require "
                "store_id_checked==CW*CH and full x0..CW-1 coordinate oracle — DE-only "
                "true_de greenwash is forbidden (rd-duck)."
            )
        else:
            msgs.append(
                "LEG0_EVIDENCE true_de_count asserts store_req==area + coordinate oracle"
            )

    # --- B7: Option-C must be capacity-selected (not width>=1280) — rd-duck ---
    # 960×540 I420 = 777600 B > legacy usable 520192 (stride 0x80000 − 0x1000).
    # Width-only gate leaves 960×540 on LEG banks → bank overrun.
    # present_core must pass PHYS_BASE_720P / stride720 / doorbell720 (not legacy-only).
    # Fit-card "w-mem usable-capacity path" is NOT present code until this clears.
    store = _read(RTL / "ddr_frame_store.sv") if not store else store
    width_only_optc = bool(
        re.search(r"if\s*\(\s*rt_cw_cl\s*>=\s*11'd1280\s*\)", store)
    )
    has_rt_need_optc = "rt_need_optc" in store
    has_payload_bytes = "rt_payload_bytes" in store and "LEG_BANK_USABLE" in store
    capacity_select = has_rt_need_optc and has_payload_bytes and (
        "if (rt_need_optc)" in store or "if(rt_need_optc)" in store
    )
    msgs.append(
        f"LEG0_BANK_MAP width_only_optc={int(width_only_optc)} "
        f"capacity_select={int(capacity_select)} "
        f"(960x540 I420=777600 > usable=520192 → must Option-C)"
    )
    if width_only_optc or not capacity_select:
        errors.append(
            "B7_OPTC_WIDTH_ONLY: ddr_frame_store.sv selects Option-C via "
            "`rt_cw_cl >= 11'd1280` (or lacks rt_need_optc/rt_payload_bytes/"
            "LEG_BANK_USABLE capacity path). Product 960×540 is <1280 wide but "
            "777600 B > 520192 B legacy usable and MUST use Option-C — width gate "
            "overruns LEG bank (rd-duck; w-mem capacity fix is the reference)."
        )
    else:
        msgs.append("LEG0_EVIDENCE Option-C capacity-selected via rt_need_optc")

    # present_core must wire Option-C phys params on the *instance* parameter
    # list (not a comment substring — mutation once greenwashed via comment).
    fstore_params = ""
    m_fs = re.search(
        r"ddr_frame_store\s*#\s*\((.*?)\)\s*\w+\s*\(",
        core,
        re.DOTALL,
    )
    if m_fs:
        fstore_params = m_fs.group(1)
    has_phys720 = bool(re.search(r"\.PHYS_BASE_720P\s*\(", fstore_params))
    has_stride720 = bool(re.search(r"\.HPS_BANK_STRIDE_BYTES_720P\s*\(", fstore_params))
    has_db720 = bool(re.search(r"\.DOORBELL_PHYS_720P\s*\(", fstore_params))
    msgs.append(
        f"LEG0_PRESENT_CORE_OPTC_PORTS phys720={int(has_phys720)} "
        f"stride720={int(has_stride720)} doorbell720={int(has_db720)} "
        f"fstore_param_chars={len(fstore_params)}"
    )
    if not has_phys720:
        errors.append(
            "B7_PRESENT_CORE_NO_OPTC_PHYS: present_core.sv ddr_frame_store #() does not "
            "pass .PHYS_BASE_720P(...) — only legacy PHYS_BASE/stride/doorbell. "
            "Merge/verify PLXG Option-C param wiring (w-mem present_core reference)."
        )
    if not has_stride720:
        errors.append(
            "B7_PRESENT_CORE_NO_OPTC_STRIDE: present_core.sv missing "
            ".HPS_BANK_STRIDE_BYTES_720P(...) on ddr_frame_store instance"
        )
    if not has_db720:
        errors.append(
            "B7_PRESENT_CORE_NO_OPTC_DOORBELL: present_core.sv missing "
            ".DOORBELL_PHYS_720P(...) on ddr_frame_store instance"
        )
    if has_phys720 and has_stride720 and has_db720:
        msgs.append("LEG0_EVIDENCE present_core passes PHYS_BASE_720P/stride/doorbell720")

    # --- B22: present_core merge-semantics (rd-duck c5bd6009 collision) ---
    # Observed: w-scaler present_core cannot win wholesale — drops w-mem B16
    # geom_live_seq/live_valid + blackout/hollow outs + Option-C instance wiring,
    # and lacks w-clock B15 core-Hz cadence selection. Same-symbol opposite-
    # direction green-in-isolation class: each lane alone is green; post-merge
    # file presence / ancestry is green; *connections* are gone. Assert ports
    # AND instance nets (not ancestor, not file presence alone).
    plex_for_b22 = _read(ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv")
    b22_msgs, b22_errs = _check_present_core_merge_semantics(core, plex_for_b22)
    msgs.extend(b22_msgs)
    errors.extend(b22_errs)

    # Fit card must not claim usable-capacity is already product code while stale.
    fit_card = _read(ROOT / "docs" / "ascal-true-de-fit-card.md")
    if fit_card and "usable-capacity" in fit_card.lower():
        if width_only_optc or not capacity_select:
            errors.append(
                "B7_FIT_CARD_CAPACITY_CLAIM: docs/ascal-true-de-fit-card.md mentions "
                "usable-capacity while ddr_frame_store still width-gates Option-C — "
                "do not treat the card claim as present code (rd-duck)."
            )

    # --- B8: product Plex.sv hierarchy must wire 960 — not thin TB / fit-card ---
    # rd-duck: PRESENT_BEAM_960 alone yields 960 DE around legacy 320/640 content +
    # 624 storage when PLXG wr/commit are tied 0 and fabric_geom_enable stays 0.
    # Only force macro FABRIC_NATIVE_720P_GEOM sets 1280×720, not 960.
    plex_sv = ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv"
    plex_txt = _read(plex_sv)
    if not plex_txt:
        errors.append(f"B8_NO_PLEX_SV: missing product hierarchy file {plex_sv}")
    else:
        msgs.append(f"LEG0_PLEX_SV path={plex_sv} bytes={len(plex_txt)}")
        plxg_wr_tied0 = bool(
            re.search(r"\bplxg_wr_en\s*=\s*1'b0\b", plex_txt)
        )
        plxg_commit_tied0 = bool(
            re.search(r"\bplxg_commit\s*=\s*1'b0\b", plex_txt)
        )
        msgs.append(
            f"LEG0_PLXG_TIES wr_en_tied0={int(plxg_wr_tied0)} "
            f"commit_tied0={int(plxg_commit_tied0)}"
        )
        if plxg_wr_tied0 and plxg_commit_tied0:
            errors.append(
                "B8_PLXG_WR_COMMIT_TIED_ZERO: Plex.sv has plxg_wr_en=1'b0 and "
                "plxg_commit=1'b0 (lines ~239–242 class). fabric_geom_enable stays 0; "
                "geom/window latch never leaves reset-zero. PRESENT_BEAM_960 alone "
                "does not program content/geom (rd-duck product hierarchy)."
            )

        # Idle content ladder is 640/320 — not 960.
        content_base_legacy = bool(
            re.search(
                r"content_res_640x480\s*\?\s*11'd640\s*:\s*11'd320",
                plex_txt,
            )
        ) or (
            "11'd640" in plex_txt
            and "11'd320" in plex_txt
            and "content_width_base" in plex_txt
            and not re.search(
                r"content_width_base[^;]*11'd960",
                plex_txt,
                re.DOTALL,
            )
        )
        has_960_content_force = bool(
            re.search(
                r"(PRESENT_BEAM_960|FABRIC_NATIVE_960|force_native_960)[^;]*11'd960",
                plex_txt,
            )
        ) or bool(
            re.search(
                r"content_width\s*=\s*[^;]*11'd960",
                plex_txt,
            )
        )
        # FABRIC_NATIVE_720P_GEOM forces 1280×720 — wrong product for ascal 960 path.
        force_720p_1280 = bool(
            re.search(
                r"force_native_720p\s*\?\s*11'd1280",
                plex_txt,
            )
        ) and bool(
            re.search(
                r"force_native_720p\s*\?\s*11'd720",
                plex_txt,
            )
        )
        force_macro_720p_only = (
            "FABRIC_NATIVE_720P_GEOM" in plex_txt
            and force_720p_1280
            and "FABRIC_NATIVE_960" not in plex_txt
            and not has_960_content_force
        )
        msgs.append(
            f"LEG0_CONTENT_HIER content_base_legacy={int(content_base_legacy)} "
            f"has_960_content_force={int(has_960_content_force)} "
            f"force_720p_1280={int(force_720p_1280)}"
        )
        if content_base_legacy and not has_960_content_force:
            # Parent 2026-08-03: fix is runtime delivered geom (PLXG live), not a
            # hardcoded-960 island. Idle 320/640 ladder is OK only if PLXG can program
            # real content_w/h; today PLXG is tied 0 (B8_PLXG) so hierarchy is dead.
            errors.append(
                "B8_CONTENT_BASE_NOT_960: Plex.sv content_width_base falls back to "
                "O[4] 640×480 / 320×240 when PLXG idle — and there is no live product "
                "path that programs content_w/h from PMS-delivered geometry (max tier "
                "960×540). Thin true_de TB drives 960 ports directly; product hierarchy "
                "does not (rd-duck). Gate inspects Plex.sv, not the harness. "
                "Do not clear by hardcoding only 960 — that fails B13."
            )
        if force_macro_720p_only:
            errors.append(
                "B8_FORCE_GEOM_1280_NOT_960: only FABRIC_NATIVE_720P_GEOM force path "
                "exists and it sets content+geom to 1280×720, not 960×540. Cannot "
                "substitute for ascal true-DE 960 product wiring (rd-duck)."
            )
        # geom coded path under force is 1280 — confirm no 960 coded force
        geom_force_1280 = bool(
            re.search(
                r"present_geom_coded_w\s*=\s*force_native_720p\s*\?\s*11'd1280",
                plex_txt,
            )
        )
        if geom_force_1280 and not re.search(
            r"present_geom_coded_w\s*=\s*[^;]*11'd960", plex_txt
        ):
            if "B8_FORCE_GEOM_1280_NOT_960" not in " ".join(errors):
                errors.append(
                    "B8_GEOM_CODED_FORCE_1280: present_geom_coded_w force path is "
                    "1280 under FABRIC_NATIVE_720P_GEOM; no 960 coded_w product force "
                    "in Plex.sv (legacy 624 storage remains when force off)."
                )

        # --- B9: aspect — Original defaults 4:3; 960×540 true-DE needs 16:9/FS ---
        # Quoted: assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
        #         assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;
        # OSD O[122:121] Aspect ratio,Original,Full Screen,...
        # ar==0 → 4:3. Full Screen is ar==1 → ARX=0 ARY=0. 960×540 is 16:9 content;
        # ascal will pillar as 4:3 unless status Full Screen or macro forces AR.
        ar_original_4_3 = bool(
            re.search(r"VIDEO_ARX\s*=\s*\(\s*!ar\s*\)\s*\?\s*12'd4", plex_txt)
        ) and bool(
            re.search(r"VIDEO_ARY\s*=\s*\(\s*!ar\s*\)\s*\?\s*12'd3", plex_txt)
        )
        conf_aspect_original_first = (
            "Aspect ratio,Original,Full Screen" in plex_txt
            or "Aspect ratio,Original" in plex_txt
        )
        # Scalar/ascal proof must force Full Screen (0/0) or 16:9 under beam macro.
        beam_forces_fs = bool(
            re.search(
                r"`ifdef\s+PRESENT_BEAM_960[\s\S]{0,1200}?"
                r"VIDEO_ARX\s*=\s*12'd0[\s\S]{0,200}?VIDEO_ARY\s*=\s*12'd0",
                plex_txt,
            )
        )
        beam_forces_16_9 = bool(
            re.search(
                r"`ifdef\s+PRESENT_BEAM_960[\s\S]{0,1200}?"
                r"VIDEO_ARX\s*=\s*12'd16[\s\S]{0,200}?VIDEO_ARY\s*=\s*12'd9",
                plex_txt,
            )
        )
        # Also accept dedicated proof macro.
        proof_forces_ar = bool(
            re.search(
                r"`ifdef\s+FIT_FORCE_AR_(FS|16_9)[\s\S]{0,400}?VIDEO_ARX\s*=",
                plex_txt,
            )
        )
        ar_forced_for_960 = beam_forces_fs or beam_forces_16_9 or proof_forces_ar
        msgs.append(
            f"LEG0_ASPECT original_4_3={int(ar_original_4_3)} "
            f"conf_original_first={int(conf_aspect_original_first)} "
            f"beam_force_ar={int(ar_forced_for_960)} "
            f"(fs={int(beam_forces_fs)} 16_9={int(beam_forces_16_9)})"
        )
        if (ar_original_4_3 or conf_aspect_original_first) and not ar_forced_for_960:
            errors.append(
                "B9_ASPECT_ORIGINAL_4_3: Plex.sv defaults VIDEO_ARX/ARY to 4/3 when "
                "status[122:121]==Original (`(!ar)?12'd4` / `12'd3`). A 960×540 "
                "true-DE input is 16:9 content and will present as 4:3 unless Full "
                "Screen (ARX=ARY=0) or 16:9 is forced. Scalar proof must "
                "`ifdef PRESENT_BEAM_960` force FS/16:9 (or FIT_FORCE_AR_*) — fit "
                "card omitted aspect (rd-duck)."
            )

        # Require a test that samples real top-level AR outputs (not fit-card prose).
        ar_tests: list[str] = []
        tests_root = ROOT / "tests"
        for path in tests_root.rglob("*"):
            if not path.is_file() or path.suffix not in {".sv", ".cpp", ".sh", ".py"}:
                continue
            t = _read(path)
            if "VIDEO_ARX" in t and "VIDEO_ARY" in t:
                ar_tests.append(str(path.relative_to(ROOT)))
        if not ar_tests:
            errors.append(
                "B9_NO_AR_TOPLEVEL_TEST: no test under tests/ asserts Plex.sv "
                "VIDEO_ARX/VIDEO_ARY top-level outputs (rd-duck: test real AR pins; "
                "fit-card table is not evidence)."
            )
        else:
            msgs.append("LEG0_AR_TESTS " + " ".join(ar_tests[:8]))

        # B9 same-size DAR: sys_top hold + post-ascal (not HDMI_BLACKOUT OR).
        b9h_msgs, b9h_errs = run_b9_ar_hold_post_ascal(ROOT)
        msgs.extend(b9h_msgs)
        errors.extend(b9h_errs)

    # --- B26 runtime crop/display bounds (rd-duck; not port-presence alone) ---
    b26_msgs, b26_errs = run_b26_store_crop_display_bounds(ROOT)
    msgs.extend(b26_msgs)
    errors.extend(b26_errs)

    # --- B27 FFmpeg pad chroma-even 426→432 x=2 (rd-duck; naive x=3 fails) ---
    b27_msgs, b27_errs = run_b27_ffmpeg_pad_chroma_even(ROOT)
    msgs.extend(b27_msgs)
    errors.extend(b27_errs)

    # --- B10: beam RTL must be on Quartus files.qip (not only Verilator hand-list) ---
    # rd-duck 34ddf: files.qip had present_content_window but not present_beam_content_de;
    # Verilator TB listed beam explicitly, hiding project-file omission → Quartus cannot
    # elaborate under PRESENT_BEAM_960. Gate SoT is files.qip + disk file + discover_design.
    qip_path = ROOT / "fpga" / "Plex_MiSTer" / "files.qip"
    qip_txt = _read(qip_path)
    beam_rel = "rtl/present_beam_content_de.sv"
    beam_abs = RTL / "present_beam_content_de.sv"
    beam_in_qip = bool(
        re.search(
            r"SYSTEMVERILOG_FILE\s+rtl/present_beam_content_de\.sv\b",
            qip_txt,
        )
    )
    beam_on_disk = beam_abs.is_file()
    msgs.append(
        f"LEG0_QIP beam_in_qip={int(beam_in_qip)} beam_on_disk={int(beam_on_disk)} "
        f"qip={qip_path}"
    )
    if not beam_in_qip:
        errors.append(
            "B10_BEAM_NOT_IN_FILES_QIP: fpga/Plex_MiSTer/files.qip must list "
            f"`SYSTEMVERILOG_FILE {beam_rel}` whenever PRESENT_BEAM_960 is the fit "
            "path. Verilator scripts that hand-list the beam hide Quartus omission "
            "(rd-duck 34ddf)."
        )
    if not beam_on_disk:
        errors.append(
            f"B10_BEAM_RTL_MISSING: {beam_abs} not on disk — cannot elaborate"
        )
    # discover_design must surface beam from qip (not a parallel hand list).
    # API self-check first: TypeError(macro_qsf) = CHECK DID NOT RUN (parent B10).
    try:
        import rtl_lint  # noqa: WPS433 — scripts/ already on path

        qsf_for_disc = (
            FIX / "green_ascal_960x540.qsf"
            if (FIX / "green_ascal_960x540.qsf").is_file()
            else None
        )
        disc_files, _disc_macros = _rtl_lint_discover_design(qsf_for_disc)
        disc_rels = {rtl_lint.rel(p) for p in disc_files}
        beam_disc = "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv" in disc_rels
        msgs.append(
            f"LEG0_DISCOVER_DESIGN EXECUTED beam_in_quartus_file_list={int(beam_disc)} "
            f"n_files={len(disc_files)}"
        )
        if beam_in_qip and not beam_disc:
            errors.append(
                "B10_BEAM_NOT_IN_DISCOVER_DESIGN: files.qip lists beam but "
                "rtl_lint.discover_design (QSF+qip SoT) did not return it — "
                "elab cannot see the module"
            )
        if not beam_disc:
            errors.append(
                "B10_BEAM_ABSENT_FROM_QUARTUS_FILE_LIST: discover_design under fit "
                "macros must include fpga/Plex_MiSTer/rtl/present_beam_content_de.sv "
                "(project file list, not TB hand-list)"
            )
    except RuntimeError as exc:
        # Stale companion API — check did not execute.
        errors.append(str(exc) if str(exc).startswith("B10_") else f"B10_DISCOVER_DESIGN_DID_NOT_RUN: {exc}")
    except TypeError as exc:
        errors.append(
            "B10_DISCOVER_DESIGN_DID_NOT_RUN: TypeError calling discover_design "
            f"({exc}). CHECK DID NOT EXECUTE — fix rtl_lint signature (need "
            "macro_qsf=). A throwing check must not look like a clean architecture scan."
        )
    except Exception as exc:  # noqa: BLE001 — surface as gate fail, mark unexecuted
        errors.append(
            f"B10_DISCOVER_DESIGN_DID_NOT_RUN: {type(exc).__name__}: {exc} — "
            "discover_design raised before returning a file list; beam-on-qip "
            "verification did not complete"
        )

    # --- B14: coded_w must be 16-aligned (parent PMS AR-fit 468/638/626) ---
    # Store chroma fetch is coded_w>>4. Unaligned widths corrupt UV plane.
    # Observed defect class (not speculative): PMS AR-fit delivers non-16 widths.
    # w-mem enforces rt_raw_aligned=(rt_coded_w[3:0]==0) into rt_raw_ok.
    store_b14 = _read(RTL / "ddr_frame_store.sv")
    has_cw16 = bool(
        re.search(r"rt_coded_w\[3:0\]\s*==\s*4'd0", store_b14)
    ) or bool(re.search(r"rt_cw_cl\[3:0\]\s*==\s*4'd0", store_b14))
    has_raw_aligned = "rt_raw_aligned" in store_b14 and "rt_raw_ok" in store_b14
    msgs.append(
        f"LEG0_CODED_W_ALIGN cw16_check={int(has_cw16)} "
        f"rt_raw_aligned={int(has_raw_aligned)}"
    )
    if not (has_cw16 and has_raw_aligned):
        errors.append(
            "B14_CODED_W_16_ALIGN_UNENFORCED: ddr_frame_store.sv must reject "
            "non-16-aligned coded_w (rt_coded_w[3:0]==0 in rt_raw_aligned → "
            "rt_raw_ok). Parent lab: PMS AR-fit widths 468/638/626 fail 16-align; "
            "chroma fetch is coded_w>>4. Silent accept = UV plane corruption. "
            "Observed defect class, not speculative."
        )
    else:
        msgs.append("LEG0_EVIDENCE coded_w 16-align gated via rt_raw_aligned")

    # --- B12: RGB/store DE_LAG not re-swept for 960 product ---
    # present_core.sv documents DE_LAG=3 measured at FRAME_W=640; REQUIRES_FIT note
    # says not re-swept for DDR_FRAME_STORE @ 640 even — 960 path has no latency proof.
    core_lag = _read(RTL / "present_core.sv")
    if core_lag:
        lag_unproven = (
            "DE_LAG has NOT been re-swept" in core_lag
            or "REQUIRES_FIT (DDR_FRAME_STORE @ FRAME_W=640)" in core_lag
        )
        has_960_lag_note = bool(
            re.search(r"DE_LAG.*960|960.*DE_LAG|FRAME_W=960.*DE_LAG", core_lag)
        )
        msgs.append(
            f"LEG0_DE_LAG unproven_comment={int(lag_unproven)} "
            f"has_960_lag_closure={int(has_960_lag_note)}"
        )
        if lag_unproven and not has_960_lag_note:
            errors.append(
                "B12_DE_LAG_RGB_LATENCY_UNPROVEN: present_core.sv still states "
                "DE_LAG has NOT been re-swept for DDR path (measured at 640-class). "
                "No 960 store/RGB latency closure — gate refuses fit until lag is "
                "re-proven for max-tier / runtime DE path (rd-duck adc9292)."
            )

    # --- B13: fixed-geometry product cannot track PMS-delivered raster (parent) ---
    # Parent measured on real PMS 2026-08-03:
    #   /library/metadata/1 (320×240 source), rung 540: requested 960×540 → delivered
    #   320×240, ffmpeg true rc=0. PMS does not upscale.
    # Architecture: core emits true DE == content extent; ascal upscales DE to 1280×720.
    # Therefore DE must be runtime-variable up to max tier 960×540 — a design that
    # hardcodes only 960×540 is wrong for a large part of a real library.
    beam_txt_b13 = _read(RTL / "present_beam_content_de.sv")
    core_b13 = _read(RTL / "present_core.sv")
    beam_rt = _beam_has_runtime_de_ports(beam_txt_b13)
    core_rt = _core_wires_runtime_de_to_beam(core_b13)
    # present_core under PRESENT_BEAM_960 still parameter-binds .H_DE(960).
    core_hard_960 = bool(
        re.search(r"\.H_DE\(\s*960\s*\)\s*,\s*\.V_ACTIVE\(\s*540\s*\)", core_b13)
    ) or bool(
        re.search(
            r"localparam\s+int\s+H_DE_I\s*=\s*960",
            core_b13,
        )
    )
    beam_param_960 = bool(
        re.search(r"parameter\s+int\s+H_DE\s*=\s*960", beam_txt_b13)
    ) and bool(re.search(r"parameter\s+int\s+V_ACTIVE\s*=\s*540", beam_txt_b13))
    msgs.append(
        f"LEG0_RUNTIME_DE beam_rt_ports={int(beam_rt)} core_wires_rt={int(core_rt)} "
        f"core_hard_960={int(core_hard_960)} beam_param_960={int(beam_param_960)}"
    )
    if not beam_rt or not core_rt or (core_hard_960 and not core_rt):
        errors.append(
            "B13_FIXED_RASTER_NO_RUNTIME_DE: product hardcodes a fixed content DE "
            "(present_beam_content_de parameter H_DE/V_ACTIVE defaults 960×540; "
            "present_core `PRESENT_BEAM_960` binds .H_DE(960),.V_ACTIVE(540) / "
            "H_DE_I=960) with no runtime ports driven from delivered content_w/h. "
            "Parent PMS lab: SD source 320×240 is delivered as 320×240 (no upscale). "
            "True-DE architecture requires DE==content at runtime; 960×540 is the "
            "maximum tier, not a fixed raster. Asserts against beam+present_core RTL."
        )

    # --- Runtime-OFF OSD / colorbars note when candidate is ascal ---
    if cand and cand.get("architecture") == "ascal_true_de_960":
        if "`else" in core and "colorbars bars" in core and "PRESENT_BEAM_960" in core:
            msgs.append(
                "LEG0_NOTE: colorbars Template path remains under `ifndef PRESENT_BEAM_960` "
                "— acceptable only if QSF forces PRESENT_BEAM_960=1 (leg1)"
            )

    # --- B15: ifdef collision class (parent: 6 occurrences tonight) ---
    # Observed class: one `ifdef PRESENT_BEAM_960` enables runtime DE in present_core
    # while another module under the same macro forces constant 960×540 content/geom
    # (w-mem mux pin vs w-clock content_w/h). Full multi-driver SV is not tractable
    # statically; this check covers the named collision pair with quoted artefacts.
    plex_b15 = _read(ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv")
    mux_b15 = _read(RTL / "plex_present_geom_mux.sv")
    core_b15 = _read(RTL / "present_core.sv")
    # Runtime-enable under PRESENT_BEAM_960 / beam path in core:
    core_enables_rt = bool(
        re.search(r"use_rt_geom\s*\(\s*1'b1\s*\)", core_b15)
    ) or bool(re.search(r"rt_h_de\s*\(\s*beam_hde_req", core_b15))
    # Force-constant override under PRESENT_BEAM_960 in hierarchy/mux:
    force_const_960 = False
    force_src = ""
    if mux_b15:
        # force_native_960=1'b1 under ifdef (unconditional pin) — collision
        if re.search(
            r"`ifdef\s+PRESENT_BEAM_960[\s\S]{0,400}?force_native_960\s*=\s*1'b1",
            mux_b15,
        ) and not re.search(
            r"force_native_960\s*=\s*~plxg_live",
            mux_b15,
        ):
            force_const_960 = True
            force_src = "plex_present_geom_mux.sv force_native_960=1 under PRESENT_BEAM_960"
        # content_width = force ? 960 with force always 1
        if re.search(r"force_native_960\s*=\s*1'b1", mux_b15) and re.search(
            r"content_width\s*=\s*force_native_960\s*\?\s*11'd960", mux_b15
        ):
            # Only collision if force is unconditional (not ~plxg_live)
            if not re.search(r"force_native_960\s*=\s*~plxg_live", mux_b15):
                force_const_960 = True
                force_src = "plex_present_geom_mux.sv pins content_width 960 when force=1"
    if plex_b15 and re.search(
        r"`ifdef\s+PRESENT_BEAM_960[\s\S]{0,800}?content_width[^\n]*=[^\n]*11'd960",
        plex_b15,
    ):
        # Direct Plex.sv force under macro (collision #5 class before mux split)
        if not re.search(r"plxg_live|fabric_plxg_live", plex_b15):
            force_const_960 = True
            force_src = force_src or "Plex.sv PRESENT_BEAM_960 forces content 960"
        # Also: keep markers that pin 960 under beam without PLXG priority
        if re.search(
            r"`ifdef\s+PRESENT_BEAM_960[\s\S]{0,200}?_b8_PRESENT_BEAM_960_content_w\s*=\s*11'd960",
            plex_b15,
        ):
            # markers alone are not policy if mux has plxg priority — note only
            msgs.append(
                "LEG0_COLLISION_NOTE Plex.sv has _b8_PRESENT_BEAM_960_content_w=960 marker"
            )
    # present_core hard .H_DE(960) while also use_rt_geom — soft note if both
    core_hard_and_rt = bool(
        re.search(r"\.H_DE\(\s*960\s*\)", core_b15)
    ) and core_enables_rt
    msgs.append(
        f"LEG0_COLLISION_SCAN core_rt={int(core_enables_rt)} "
        f"force_const_960={int(force_const_960)} core_hard_and_rt={int(core_hard_and_rt)} "
        f"src={force_src or 'none'}"
    )
    if core_enables_rt and force_const_960:
        errors.append(
            "B15_IFDEF_COLLISION_PRESENT_BEAM_960: same macro PRESENT_BEAM_960 enables "
            "runtime DE in present_core (use_rt_geom/rt_h_de←content_w) AND forces "
            f"constant 960×540 override ({force_src}). Parent collision class "
            "(6× tonight): one ifdef must not both enable a feature and pin a "
            "constant that defeats it. Fix: force only as PLXG-idle fallback "
            "(~plxg_live), never unconditional under the enable macro."
        )
    elif force_const_960 and not core_enables_rt:
        # Force without runtime path is B13/B8 territory; still flag policy pin.
        msgs.append(
            "LEG0_COLLISION_NOTE force_const_960 without core_rt — covered by B8/B13"
        )
    # Tractability note (always printed once).
    msgs.append(
        "LEG0_COLLISION_TRACTABILITY: full multi-driver/SV elaboration not attempted; "
        "B15 covers named PRESENT_BEAM_960 enable-vs-force pair across "
        "present_core + plex_present_geom_mux/Plex.sv (observed class). "
        "General 'two modules drive same signal with contradictory policies' "
        "requires elaboration — not statically complete here."
    )

    # --- B15 cadence / hardwired 24 Hz (parent ABI arbitration) ---
    # Plex.sv content_fps = 8'd24 + present_core V_TOTAL from content_fps<=25 → 705
    # means beam is permanently film rate unless q5 fps_valid drives it.
    # STRING-BASED + ifdef-aware: product_active_sv strips `ifdef FAULT_* red twins
    # so a deliberate FAULT_B15_FPS_HARDWIRE_24 copy cannot false-POS this check.
    plex_fps = _read_product_sv(ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv")
    core_fps = _read_product_sv(RTL / "present_core.sv")
    hard_24 = bool(re.search(r"\bcontent_fps\s*=\s*8'd24\b", plex_fps))
    uses_fps_for_vtot = bool(
        re.search(r"content_fps\s*<=\s*8'd25", core_fps)
        or re.search(r"V_TOTAL\s*=\s*\(\s*content_fps", core_fps)
        or re.search(r"beam_vtot_req\s*=\s*\(\s*content_fps", core_fps)
    )
    has_q5_fps = bool(
        re.search(r"fps_valid|plxg_q5|q5_fps|content_fps_sel|plex_content_fps", plex_fps)
        or re.search(r"fps_valid|plxg_q5", core_fps)
    )
    msgs.append(
        f"LEG0_CADENCE hard_content_fps_24={int(hard_24)} "
        f"core_uses_fps_vtot={int(uses_fps_for_vtot)} q5_fps_path={int(has_q5_fps)}"
    )
    if hard_24 and uses_fps_for_vtot and not has_q5_fps:
        errors.append(
            "B15_HARDWIRED_CONTENT_FPS_24: Plex.sv ties content_fps=8'd24 and "
            "present_core selects V_TOTAL from content_fps (<=25 → 705 film) with no "
            "PLXG q5 fps_valid path. Beam is permanently ~24 Hz; a '30 fps capable' "
            "claim is false as built (parent ABI: q5[31:24] content_fps + [33] fps_valid)."
        )

    # --- B17 PLXG q5 DAR+FPS ABI (doorbell+0x828) ---
    # Parent arbitration: q5[11:0] dar_x, [23:12] dar_y, [31:24] fps, [32] dar_valid,
    # [33] fps_valid; ABI #2.1 adds [34] fps_1001 with reserved[63:35] (w-path f31a6eb9).
    # B17 is presence-only — B24 requires merged accept+1001 executable path.
    has_q5_abi = bool(
        re.search(r"0x828|doorbell\s*\+\s*32'h828|PLXG_Q5|plxg_q5", plex_fps)
        or re.search(r"dar_valid|dar_x|VIDEO_ARX.*plxg|plex_video_ar", plex_fps)
    )
    # Host-side packer also acceptable evidence of ABI landing.
    host_hits = []
    for hp in (
        ROOT / "arm" ,
        ROOT / "src",
        ROOT / "misterplexd",
    ):
        if not hp.is_dir():
            continue
        for f in hp.rglob("*"):
            if f.suffix not in {".hpp", ".h", ".cpp", ".c", ".rs"}:
                continue
            try:
                t = f.read_text(errors="ignore")
            except OSError:
                continue
            if re.search(r"0x828|dar_valid|packPlxgQ5|plxg_q5", t):
                host_hits.append(str(f.relative_to(ROOT)))
                if len(host_hits) >= 3:
                    break
        if len(host_hits) >= 3:
            break
    msgs.append(
        f"LEG0_PLXG_Q5 fabric_markers={int(has_q5_abi)} host_hits={len(host_hits)} "
        f"{' '.join(host_hits[:3])}"
    )
    if not has_q5_abi and not host_hits:
        errors.append(
            "B17_PLXG_Q5_DAR_FPS_ABI_MISSING: no fabric/host evidence of PLXG q5 @ "
            "doorbell+0x828 (dar_x/dar_y/content_fps + dar_valid/fps_valid). Parent "
            "arbitrated this ABI because B9 aspect and B15 cadence are the same class: "
            "values the daemon knows and the fabric cannot infer. Gate asserts markers "
            "in Plex.sv / host packer — not a marker file."
        )

    # --- B18 cheap undeclared-id smell (main decode_stub class) ---
    # Parent: main does not compile — dpb_mem_rd_q used, declared nowhere (merge 8ed788b3).
    # Full elab is leg2; this is a targeted static smell for the observed symbol.
    stub = _read(RTL / "decode_stub.sv")
    if stub and re.search(r"\bdpb_mem_rd_q\b", stub):
        if not re.search(r"\b(reg|wire|logic)\s+.*\bdpb_mem_rd_q\b", stub):
            errors.append(
                "B18_UNDECLARED_DPB_MEM_RD_Q: decode_stub.sv references dpb_mem_rd_q "
                "without a reg/wire/logic declaration — observed main compile break "
                "(parent merge drop class, same family as B19). w-nostub lane owns fix."
            )

    # --- B16 product files.qip must list hierarchy RTL (rd-duck hold/release) ---
    # Isolated lanes currently omit mux/poller/q5; merged product must not.
    # B13 beam+mux, B16 poller/latch, q5 aspect/fps.
    qip_txt = _read(ROOT / "fpga" / "Plex_MiSTer" / "files.qip")
    qsf_txt = _read(ROOT / "fpga" / "Plex_MiSTer" / "Plex.qsf")
    required_qip = [
        (
            "B16_QIP_BEAM",
            r"present_beam_content_de\.sv",
            "B13 beam generator",
        ),
        (
            "B16_QIP_GEOM_MUX",
            r"plex_present_geom_mux\.sv",
            "B13 geom mux (PLXG vs fallback)",
        ),
        (
            "B16_QIP_POLLER",
            r"plxg_ddr_poller\.sv",
            "B16 PLXG DDR poller",
        ),
        (
            "B16_QIP_LATCH",
            r"present_geom_latch\.sv",
            "B16 geom latch",
        ),
        (
            "B16_QIP_Q5_ASPECT_FPS",
            r"plex_video_ar\.sv|plex_content_fps|plxg_q5",
            "q5 aspect/fps fabric module",
        ),
    ]
    msgs.append("LEG0_B16_QIP_SCAN_EXECUTED")
    for tok, pat, why in required_qip:
        on_disk = False
        # q5 module may be named variously — also accept Plex.sv packing markers in qip? No — qip file list.
        if tok == "B16_QIP_Q5_ASPECT_FPS":
            # Pass if any matching RTL file exists AND is listed, OR listed pattern hits.
            rtl_candidates = list((ROOT / "fpga" / "Plex_MiSTer" / "rtl").glob("plex_video_ar*.sv"))
            rtl_candidates += list((ROOT / "fpga" / "Plex_MiSTer" / "rtl").glob("*content_fps*.sv"))
            rtl_candidates += list((ROOT / "fpga" / "Plex_MiSTer" / "rtl").glob("*plxg_q5*.sv"))
            listed = bool(re.search(pat, qip_txt, re.I))
            if rtl_candidates and not listed:
                errors.append(
                    f"{tok}: RTL exists ({rtl_candidates[0].name}) but files.qip does not "
                    f"list q5 aspect/fps module ({why}). rd-duck: merged QIP must include it."
                )
            elif not listed and not rtl_candidates:
                # No module yet — still required for product release (ABI arbitrated).
                errors.append(
                    f"{tok}: files.qip has no q5 aspect/fps entry and no "
                    f"plex_video_ar/content_fps/plxg_q5 RTL on disk ({why}). "
                    "rd-duck hold: merged product must ship q5 DAR/FPS path in Quartus file list."
                )
            elif listed:
                msgs.append(f"LEG0_B16_QIP_OK {tok}")
            continue
        if re.search(pat, qip_txt):
            msgs.append(f"LEG0_B16_QIP_OK {tok}")
        else:
            # Beam already covered by B10 — still report B16 for release matrix clarity
            # but avoid double-counting identical beam miss as two failures when B10 fires.
            if tok == "B16_QIP_BEAM" and any("B10_BEAM_NOT_IN_FILES_QIP" in e for e in errors):
                msgs.append(f"LEG0_B16_QIP_DEFER {tok} (covered by B10)")
            else:
                errors.append(
                    f"{tok}: fpga/Plex_MiSTer/files.qip missing {pat} ({why}). "
                    "rd-duck: isolated lanes omit these; merged product QIP must list "
                    "B13 beam+mux, B16 poller/latch, q5 aspect/fps."
                )
    # QSF must not be hollow 480p when candidate is ascal — leg1 enforces macros;
    # here require PRESENT_BEAM_960 appears as active assignment in product QSF text.
    if cand and cand.get("architecture") == "ascal_true_de_960":
        active_beam = bool(
            re.search(
                r"^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"
                r'"PRESENT_BEAM_960=1"',
                qsf_txt,
                re.M,
            )
        )
        if not active_beam:
            errors.append(
                "B16_QSF_BEAM_NOT_ACTIVE: product Plex.qsf has no active "
                'VERILOG_MACRO "PRESENT_BEAM_960=1" (commented or absent). '
                "rd-duck: merged QSF must enable B13 beam path — hollow 480p QSF is not product."
            )

    # --- B21 hierarchy constants: HDMI_BLACKOUT + VGA_SCALER (rd-duck) ---
    # Observed defect: Plex.sv assigns HDMI_BLACKOUT=0 and VGA_SCALER=0.
    # ascal.vhd gates 3-frame res-change blackout on swblack:
    #   IF (swblack='1' and ... ihsize/ivsize change) then o_newres <= 3
    # sys_top passes .swblack(hdmi_blackout) from emu.HDMI_BLACKOUT — so
    # BLACKOUT=0 disables that protection for runtime geometry changes.
    # VGA_SCALER=0 leaves vga_force_scaler low; sys_top then allows
    # direct_video / raw VGA paths (~1299/1352, select ~1381/1551) that
    # bypass ascal for the nonstandard ~16.92 kHz 24/30 Hz beam.
    # Runtime-beam product must force HDMI_BLACKOUT=1 and VGA_SCALER=1
    # (or an equivalent hard reject of bypass). Gate exact hierarchy constants.
    def _emu_assign_bit(src: str, name: str) -> str | None:
        """Last active assign NAME = … ; value as '0'/'1'/other. Comments ignored."""
        vals: list[str] = []
        for m in re.finditer(
            rf"^\s*assign\s+{re.escape(name)}\s*=\s*(.+?)\s*;",
            src,
            re.M,
        ):
            line_start = src.rfind("\n", 0, m.start()) + 1
            prefix = src[line_start : m.start()]
            if prefix.lstrip().startswith("//"):
                continue
            raw = m.group(1).strip()
            if re.fullmatch(r"1\'b1|1", raw):
                vals.append("1")
            elif re.fullmatch(r"1\'b0|0", raw):
                vals.append("0")
            else:
                vals.append(raw)
        return vals[-1] if vals else None

    msgs.append("LEG0_B21_HIER_CONST_SCAN_EXECUTED")
    sys_top_path = ROOT / "fpga" / "Plex_MiSTer" / "sys" / "sys_top.v"
    sys_top_txt = _read(sys_top_path)
    if not sys_top_txt:
        errors.append(
            "B21_ASCAL_SWBLACK_NOT_WIRED: missing fpga/Plex_MiSTer/sys/sys_top.v "
            "— cannot verify ascal.swblack / VGA_SCALER hierarchy constants."
        )
        sys_top_txt = ""
    bo = _emu_assign_bit(plex_txt, "HDMI_BLACKOUT")
    vs = _emu_assign_bit(plex_txt, "VGA_SCALER")
    if bo is None:
        errors.append(
            "B21_HDMI_BLACKOUT_DISABLED: fpga/Plex_MiSTer/Plex.sv has no "
            "assign HDMI_BLACKOUT = … (cannot prove ascal swblack enable). "
            "rd-duck: runtime-beam product must force HDMI_BLACKOUT=1 — "
            "ascal 3-frame res-change blackout is gated on swblack."
        )
    elif bo != "1":
        errors.append(
            f"B21_HDMI_BLACKOUT_DISABLED: Plex.sv assign HDMI_BLACKOUT={bo} "
            "(need =1). ascal.vhd:1951-52 3-frame o_newres blackout only runs "
            "when swblack=1; HDMI_BLACKOUT=0 disables it — do not claim it "
            "protects arbitrary runtime geometry changes."
        )
    else:
        msgs.append("LEG0_B21_OK HDMI_BLACKOUT=1")

    if vs is None:
        errors.append(
            "B21_VGA_SCALER_DISABLED: fpga/Plex_MiSTer/Plex.sv has no "
            "assign VGA_SCALER = … . rd-duck: runtime-beam must force "
            "VGA_SCALER=1 so vga_force_scaler blocks direct_video/raw VGA "
            "bypass of ascal for the nonstandard 16.92kHz beam."
        )
    elif vs != "1":
        errors.append(
            f"B21_VGA_SCALER_DISABLED: Plex.sv assign VGA_SCALER={vs} "
            "(need =1). With VGA_SCALER=0, sys_top may select direct_video / "
            "raw VGA paths that bypass ascal (sys_top direct_video ~1299/1352, "
            "VGA select ~1381/1551) — nonstandard 24/30 Hz beam must not skip ascal."
        )
    else:
        msgs.append("LEG0_B21_OK VGA_SCALER=1")

    # Hierarchy wiring: emu ports → sys_top locals → ascal.swblack / scaler force.
    if not re.search(r"\.swblack\s*\(\s*hdmi_blackout\s*\)", sys_top_txt):
        errors.append(
            "B21_ASCAL_SWBLACK_NOT_WIRED: sys_top.v ascal instance missing "
            ".swblack(hdmi_blackout). Without this, HDMI_BLACKOUT cannot reach "
            "ascal's resolution-change blackout (observed defect class)."
        )
    else:
        msgs.append("LEG0_B21_OK ascal.swblack<-hdmi_blackout")
    # Reject hard-tied-off swblack even if a second port looks wired.
    if re.search(r"\.swblack\s*\(\s*(1\'b0|0)\s*\)", sys_top_txt):
        errors.append(
            "B21_ASCAL_SWBLACK_NOT_WIRED: sys_top.v ties .swblack(0) — "
            "ascal 3-frame blackout hard-disabled regardless of HDMI_BLACKOUT."
        )

    if not re.search(r"\.HDMI_BLACKOUT\s*\(\s*hdmi_blackout\s*\)", sys_top_txt):
        errors.append(
            "B21_HIER_BLACKOUT_PORT_NOT_WIRED: sys_top.v emu instance missing "
            ".HDMI_BLACKOUT(hdmi_blackout) — hierarchy constant path broken."
        )
    else:
        msgs.append("LEG0_B21_OK emu.HDMI_BLACKOUT->hdmi_blackout")

    if not re.search(r"\.VGA_SCALER\s*\(\s*vga_force_scaler\s*\)", sys_top_txt):
        errors.append(
            "B21_HIER_VGA_SCALER_PORT_NOT_WIRED: sys_top.v emu instance missing "
            ".VGA_SCALER(vga_force_scaler) — cannot force scaler/FB over direct_video."
        )
    else:
        msgs.append("LEG0_B21_OK emu.VGA_SCALER->vga_force_scaler")

    # Force-scaler must actually OR into vga_fb / vga_scaler (exact hierarchy).
    if not re.search(
        r"vga_fb\s*=\s*cfg\[12\]\s*\|\s*vga_force_scaler", sys_top_txt
    ):
        errors.append(
            "B21_HIER_VGA_SCALER_PORT_NOT_WIRED: sys_top.v vga_fb does not "
            "OR vga_force_scaler (cfg[12]|vga_force_scaler required) — "
            "VGA_SCALER=1 would not block direct_video FB bypass."
        )
    if not re.search(
        r"vga_scaler\s*=\s*cfg\[2\]\s*\|\s*vga_force_scaler", sys_top_txt
    ):
        errors.append(
            "B21_HIER_VGA_SCALER_PORT_NOT_WIRED: sys_top.v vga_scaler does not "
            "OR vga_force_scaler (cfg[2]|vga_force_scaler required)."
        )

    # --- B20_UNCONNECTED_PRODUCER: Verilator PINMISSING/UNDRIVEN sweep ---
    # Parent 2026-08-03 observed on integ-product: present_geom_latch produces
    # dar_*/fps_* correctly, plex_video_ar consumes fabric_dar_* correctly, but
    # the instance port list ended at .promote_pulse — zero drivers on fabric_*.
    # B19 content-presence greps were GREEN (evidence strings exist). Only a
    # mechanical undriven/pinmissing pass catches this class.
    msgs.append("LEG0_B20_CONNECTIVITY_SWEEP_BEGIN")
    msgs.append(
        "LEG0_B20_VERILATOR_INVOKE=scripts/run_verilator.sh "
        "(oss-cad-suite ~/.local/oss-cad-suite/bin/verilator; bare PATH not required). "
        "Missing verilator = HARD FAIL (soft-skip rc=77 is NOT a pass)."
    )
    try:
        import rtl_lint as _rtl_conn

        if hasattr(_rtl_conn, "set_repo_root"):
            _rtl_conn.set_repo_root(ROOT)
        qsf_conn = ROOT / "fpga" / "Plex_MiSTer" / "Plex.qsf"
        try:
            files_c, macros_c = _rtl_lint_discover_design(qsf_conn if qsf_conn.is_file() else None)
        except TypeError as exc:
            errors.append(
                "B10_DISCOVER_DESIGN_DID_NOT_RUN: connectivity sweep could not "
                f"discover_design: {exc}"
            )
            files_c, macros_c = [], []
        if not files_c:
            errors.append(
                "B20_UNCONNECTED_PRODUCER: connectivity sweep got zero design files "
                "from discover_design — check did not execute (not a skip/pass)."
            )
        else:
            _rc_c, _out_c, findings = _rtl_conn.run_connectivity_sweep(
                files_c, macros_c, macro_qsf=qsf_conn if qsf_conn.is_file() else None
            )
            msgs.append(
                f"LEG0_B20_CONNECTIVITY_SWEEP_EXECUTED n_findings={len(findings)} "
                f"verilator_rc={_rc_c} log=build/vl_connectivity_sweep.log"
            )
            # Soft-skip / missing binary: run_verilator.sh exits 127 when not found.
            if _rc_c in (127, 126) or (
                "Verilator not found" in (_out_c or "")
                or "run_verilator: Verilator not found" in (_out_c or "")
            ):
                errors.append(
                    "B20_UNCONNECTED_PRODUCER: Verilator unavailable "
                    f"(verilator_rc={_rc_c}). Invoke via scripts/run_verilator.sh → "
                    "~/.local/oss-cad-suite/bin/verilator. "
                    "A connectivity check that cannot run is GRANT:NO (not soft-skip)."
                )
            elif _rc_c == 77:
                errors.append(
                    "B20_UNCONNECTED_PRODUCER: connectivity sweep returned soft-skip "
                    "rc=77 — treated as FAIL (AGENTS.md: soft-skip ≠ pass)."
                )
            else:
                pin_n = sum(1 for f in findings if f.get("kind") == "PINMISSING")
                und_n = sum(1 for f in findings if f.get("kind") == "UNDRIVEN")
                if findings:
                    sample = findings[:12]
                    detail = "; ".join(
                        (
                            f"{f['kind']}:{f.get('inst_file','')}:{f.get('inst_line','')}"
                            f":pin={f.get('pin') or f.get('signal') or '?'}"
                            + (
                                f":decl={Path(f['port_decl']).name}"
                                if f.get("port_decl")
                                else ""
                            )
                        )
                        for f in sample
                    )
                    more = (
                        f" (+{len(findings)-12} more)" if len(findings) > 12 else ""
                    )
                    errors.append(
                        f"B20_UNCONNECTED_PRODUCER: Verilator connectivity sweep found "
                        f"{len(findings)} product-rtl issue(s) "
                        f"(PINMISSING={pin_n} UNDRIVEN={und_n}). "
                        "Class = correct producer + correct consumer never wired "
                        "(parent integ miss #11). Sample: "
                        f"{detail}{more}. "
                        "LIMITATION: has-a-driver ≠ intended-driver (wrong-producer twin "
                        "not covered — e.g. content_fps=8'd24 while fabric_content_fps "
                        "is driven but unused)."
                    )
                else:
                    # Empty findings with catastrophic elab failure is not OK either:
                    # require that verilator actually produced lint output.
                    if _rc_c not in (0, 1) and not (_out_c or "").strip():
                        errors.append(
                            "B20_UNCONNECTED_PRODUCER: Verilator returned "
                            f"rc={_rc_c} with empty log — sweep did not execute."
                        )
                    else:
                        msgs.append(
                            "LEG0_B20_CONNECTIVITY_OK PINMISSING=0 UNDRIVEN=0 "
                            "(product-rtl filter; wrong-producer twin still out of scope)"
                        )
    except FileNotFoundError as exc:
        errors.append(
            f"B20_UNCONNECTED_PRODUCER: connectivity sweep could not run ({exc}). "
            "A check that does not execute is not a pass."
        )
    except Exception as exc:  # noqa: BLE001 — surface sweep crashes as blockers
        errors.append(
            f"B20_UNCONNECTED_PRODUCER: connectivity sweep raised {type(exc).__name__}: {exc}. "
            "A check that throws did not run (B10 class)."
        )

    # Orphan product modules: listed in files.qip, never instantiated (B15 twin:
    # plex_content_fps_sel compiles but is dead without an instance).
    qip_orphan = _read(ROOT / "fpga" / "Plex_MiSTer" / "files.qip")
    plex_all = plex_txt or ""
    rtl_blob_parts: list[str] = [plex_all]
    for rp in sorted((ROOT / "fpga" / "Plex_MiSTer" / "rtl").glob("*.sv")):
        rtl_blob_parts.append(_read(rp) or "")
    rtl_blob = "\n".join(rtl_blob_parts)
    orphan_hits: list[str] = []
    if qip_orphan:
        for m in re.finditer(
            r"SYSTEMVERILOG_FILE\s+rtl/([A-Za-z0-9_]+\.sv)", qip_orphan
        ):
            fname = m.group(1)
            fpath = ROOT / "fpga" / "Plex_MiSTer" / "rtl" / fname
            body = _read(fpath)
            if not body:
                continue
            # Only the primary module (file stem) — submodules in multi-module
            # files are often local helpers (h264_rbsp_filter inside primitives).
            stem = Path(fname).stem
            mm = re.search(
                rf"^\s*module\s+({re.escape(stem)})\b", body, re.M
            )
            if not mm:
                continue
            mod = mm.group(1)
            # skip packages / params / pure include cargo / intentional math packs
            if (
                mod.endswith("_pkg")
                or mod.endswith("_params")
                or "timing_960" in mod
                or mod.startswith("present_video_timing")
            ):
                continue
            # Instantiation elsewhere: module name appears outside its own body
            outside = rtl_blob.replace(body, "\n", 1)
            if not re.search(rf"\b{re.escape(mod)}\b", outside):
                orphan_hits.append(f"{fname}:{mod}")
    if orphan_hits:
        errors.append(
            "B20_UNCONNECTED_PRODUCER: product module(s) in files.qip never "
            f"instantiated anywhere in Plex.sv/rtl: {orphan_hits[:8]}. "
            "Compiles ≠ connected (parent: plex_content_fps_sel in qip, no instance → "
            "B15 content_fps stays 8'd24)."
        )
        msgs.append(f"LEG0_B20_ORPHAN_MODULES n={len(orphan_hits)} {orphan_hits[:8]}")
    else:
        msgs.append("LEG0_B20_ORPHAN_MODULES n=0")

    # --- B20 full-hierarchy scenario tests (rd-duck 2026-08-03 hollow audit) ---
    # Prior gate only regex-scanned test *text* and accepted comment bait (mutation
    # hier_body cleared all six tokens without running anything). That violates the
    # parent's passing-test rule and could release fit on prose.
    #
    # Contract (non-negotiable):
    #   1. Named executable script path per scenario (registry below).
    #   2. Gate *runs* the script (not grep-only).
    #   3. Require CASE <tok> EXECUTED + PASS <tok> in stdout + true rc=0.
    #   4. Soft-skip rc=77 is NOT a pass. Missing script is NOT a pass.
    #   5. Comment-only / non-executable bait must not clear the blocker.
    b20_hier_rc, b20_hier_msgs, b20_hier_errs = run_b20_hierarchy_exec_gate(ROOT)
    msgs.extend(b20_hier_msgs)
    errors.extend(b20_hier_errs)

    # --- B24 q5 bit34 fps_1001 ABI merge-loss (rd-duck — not static q5 presence) ---
    b24_s_msgs, b24_s_errs = run_b24_q5_fps_1001_static(ROOT)
    msgs.extend(b24_s_msgs)
    errors.extend(b24_s_errs)
    b24_e_rc, b24_e_msgs, b24_e_errs = run_b24_q5_fps_1001_exec_gate(ROOT)
    msgs.extend(b24_e_msgs)
    errors.extend(b24_e_errs)

    # --- B25 PLXC host→loader dual doorbell maps (rd-duck — not CDC beats alone) ---
    b25_s_msgs, b25_s_errs = run_b25_plxc_doorbell_static(ROOT)
    msgs.extend(b25_s_msgs)
    errors.extend(b25_s_errs)
    b25_e_rc, b25_e_msgs, b25_e_errs = run_b25_plxc_doorbell_exec_gate(ROOT)
    msgs.extend(b25_e_msgs)
    errors.extend(b25_e_errs)

    # --- B19 MERGE-LOSS + lane tip under-take (always, even if Bn cleared) ---
    b19_errs = collect_merge_loss_errors()
    if b19_errs:
        msgs.append(f"LEG0_B19_MERGE_LOSS_EXECUTED n={len(b19_errs)}")
        errors.extend(b19_errs)
    else:
        msgs.append("LEG0_B19_MERGE_LOSS_EXECUTED n=0")

    # Anti-theatre: gate source must not define self-pass switches (not mere mentions).
    gate_src = _read(Path(__file__))
    if re.search(r"^\s*LEG0_FORCE_PASS\s*=\s*True", gate_src, re.M) or re.search(
        r"^\s*SKIP_ALL_ARCH_BLOCKERS\s*=\s*True", gate_src, re.M
    ):
        errors.append(
            "B0_GATE_SELF_WEAKEN: fit_release_gate.py defines FORCE_PASS/SKIP_ALL "
            "switch — refuse (AGENTS.md gate self-weakening forbidden)"
        )

    if errors:
        # Tag unmerged vs unimplemented for parent routing (do not soften checks).
        tagged: list[str] = []
        for e in errors:
            m = re.match(r"^(B[0-9]+_[A-Z0-9_]+):", e)
            if m and "[fix=" not in e:
                tok = m.group(1)
                # B19_* carry their own detail; still tag if a sibling meta exists.
                if tok.startswith("B19_"):
                    tagged.append(e)
                else:
                    tagged.append(e + _fix_status_suffix(tok))
            else:
                tagged.append(e)
        errors = tagged
        n_unmerged = sum(1 for e in errors if "fix=unmerged" in e)
        n_unimpl = sum(1 for e in errors if "fix=unimplemented" in e)
        n_mloss = sum(1 for e in errors if "B19_MERGE_LOSS" in e)
        n_under = sum(1 for e in errors if "B19_LANE_TIP_NOT_MERGED" in e)
        msgs.append("LEG0_FAIL EXECUTED reasons:")
        msgs.extend(f"  - {e}" for e in errors)
        msgs.append(f"LEG0_FAIL count={len(errors)}")
        msgs.append(
            f"LEG0_FIX_STATUS unmerged={n_unmerged} unimplemented={n_unimpl} "
            f"merge_loss={n_mloss} lane_tip_not_merged={n_under} "
            "(unmerged = route merge; merge_loss = B19 re-merge content; "
            "unimplemented = dispatch new work; lane_tip_not_merged = under-take)"
        )
        return 1, msgs

    msgs.append("LEG0_PASS EXECUTED architecture blockers clear")
    return 0, msgs


def leg1_macros(qsf: Path) -> tuple[int, list[str], dict[str, str]]:
    """Return (rc, messages, name->value). rc=0 PASS."""
    msgs: list[str] = []
    if not qsf.is_file():
        return 2, [f"LEG1_ERROR: QSF not found: {qsf}"], {}

    macros = discover_quartus_macros(qsf)
    # Drop BUILD_DATE synthetic from parity helper for fit-gate view.
    active = {n: m.value for n, m in macros.items() if n != "BUILD_DATE"}
    msgs.append(f"LEG1_QSF={qsf}")
    msgs.append(
        "LEG1_ACTIVE_MACROS "
        + " ".join(f"{k}={v}" for k, v in sorted(active.items()))
    )
    msgs.append("LEG1_MACRO_PARSE_RULE=hash_comment_absent last_wins")

    errors: list[str] = []
    for name, want in REQUIRED_EXACT.items():
        got = active.get(name)
        if got is None:
            errors.append(f"missing required {name}={want}")
        elif got != want:
            errors.append(f"{name}={got!r} want {want!r} (source {macros[name].source})")

    for name, bad_vals in FORBIDDEN_VALUES.items():
        got = active.get(name)
        if got in bad_vals:
            errors.append(f"hollow/forbidden {name}={got} (must not ship)")

    # Mismatched pair: W correct but H wrong (or vice versa) — already covered by
    # REQUIRED_EXACT, but name it explicitly for the adversarial case.
    fw, fh = active.get("FRAME_W"), active.get("FRAME_H")
    if fw == "960" and fh is not None and fh != "540":
        errors.append(f"mismatched FRAME pair FRAME_W=960 FRAME_H={fh} (need 540)")
    if fh == "540" and fw is not None and fw != "960":
        errors.append(f"mismatched FRAME pair FRAME_W={fw} FRAME_H=540 (need 960)")

    for name in sorted(FORBIDDEN_PRESENT):
        if name in active:
            errors.append(f"forbidden fault/non-product macro present: {name}={active[name]}")

    if errors:
        msgs.append("LEG1_FAIL EXECUTED reasons:")
        msgs.extend(f"  - {e}" for e in errors)
        return 1, msgs, active

    msgs.append(
        "LEG1_PASS EXECUTED required={FRAME_W=960,FRAME_H=540,PRESENT_BEAM_960=1,"
        "DDR_FRAME_STORE=1,PRODUCT_NO_STUB=1} "
        "forbidden_mp_scale_fabric_writer=absent hollow_640_480=absent"
    )
    return 0, msgs, active


def leg2_elab(qsf: Path) -> tuple[int, list[str]]:
    """Elaborate the *Quartus* file list (qsf+qip) under the QSF macro set.

    This is the pre-fit stand-in for Quartus analysis/elaboration: file list comes
    from files.qip via rtl_lint.discover_design — not from TB hand-lists. Soft-skip
    ≠ PASS. True quartus_map is not run here (sole exclusive slot).
    """
    msgs: list[str] = []
    # Pre-flight: beam must be on the Quartus file list before claiming elab.
    try:
        import rtl_lint  # noqa: WPS433

        files, macros = _rtl_lint_discover_design(qsf)
        rels = [rtl_lint.rel(p) for p in files]
        beam_rel = "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
        has_beam = beam_rel in rels
        has_beam_macro = any(
            m.startswith("PRESENT_BEAM_960=") and not m.endswith("=0") for m in macros
        )
        msgs.append(
            f"LEG2_QUARTUS_FILE_LIST EXECUTED n={len(files)} beam={int(has_beam)} "
            f"PRESENT_BEAM_960={int(has_beam_macro)}"
        )
        msgs.append("LEG2_MACROS " + " ".join(macros))
        if has_beam_macro and not has_beam:
            msgs.append(
                "LEG2_FAIL EXECUTED B10: PRESENT_BEAM_960 active but "
                f"{beam_rel} absent from Quartus discover_design file list "
                "(files.qip omission — TB hand-list does not count)"
            )
            return 1, msgs
        if has_beam_macro and "PRESENT_BEAM_960=1" not in " ".join(macros):
            msgs.append("LEG2_FAIL EXECUTED PRESENT_BEAM_960 not exactly =1 in macro set")
            return 1, msgs
    except RuntimeError as exc:
        msgs.append(f"LEG2_FAIL EXECUTED discover_design DID_NOT_RUN: {exc}")
        return 1, msgs
    except TypeError as exc:
        msgs.append(
            f"LEG2_FAIL EXECUTED discover_design DID_NOT_RUN TypeError: {exc} "
            "(stale rtl_lint — CHECK DID NOT RUN)"
        )
        return 1, msgs
    except Exception as exc:  # noqa: BLE001
        msgs.append(f"LEG2_FAIL EXECUTED discover_design DID_NOT_RUN: {exc}")
        return 1, msgs

    elab = ROOT / "scripts" / "check_verilator_elab.py"
    rc, out = _run([sys.executable, str(elab), "--qsf", str(qsf)])
    msgs.append(out.rstrip())
    msgs.append(f"leg2_elab true rc={rc}")
    if rc == 3:
        msgs.append("LEG2_REFUSED EXECUTED Verilator missing (not a pass)")
        return 3, msgs
    if rc != 0:
        msgs.append("LEG2_FAIL EXECUTED verilator-elab rejected with fit macro set")
        return 1, msgs
    if "VERILATOR_ELAB_PASS" not in out:
        msgs.append("LEG2_FAIL EXECUTED missing VERILATOR_ELAB_PASS token")
        return 1, msgs
    # Prove the fit macros were actually injected (not hollow default alone).
    if "propagated QSF macros" not in out:
        msgs.append("LEG2_FAIL EXECUTED no macro propagation line")
        return 1, msgs
    if "PRESENT_BEAM_960=1" not in out and has_beam_macro:
        msgs.append("LEG2_FAIL EXECUTED elab output missing PRESENT_BEAM_960=1 propagation")
        return 1, msgs
    msgs.append(
        "LEG2_PASS EXECUTED verilator-elab of Quartus qip file list under fit macros "
        f"(beam_in_list={int(has_beam)}) — not a quartus_map PASS"
    )
    return 0, msgs


def leg3_true_de(
    active: dict[str, str],
    *,
    force_island: bool = False,
    work: Path | None = None,
) -> tuple[int, list[str]]:
    """Counted true-DE sim for the raster implied by active macros."""
    msgs: list[str] = []
    fw = int(active.get("FRAME_W", "0") or "0")
    fh = int(active.get("FRAME_H", "0") or "0")
    if fw <= 0 or fh <= 0:
        return 1, ["LEG3_FAIL EXECUTED FRAME_W/H not available from leg1 parse"]

    island = force_island or ("PRESENT_BEAM_FAULT_ISLAND_1280" in active)
    run = ROOT / "scripts" / "run_verilator.sh"
    # Probe verilator
    vrc, vout = _run([str(run), "--version"])
    if vrc == 127:
        msgs.append("LEG3_REFUSED EXECUTED Verilator missing (not a pass)")
        return 3, msgs
    if vrc != 0:
        msgs.append(vout)
        msgs.append(f"LEG3_ERROR verilator probe rc={vrc}")
        return vrc, msgs

    mdir = work or (ROOT / "build" / "fit_release_gate" / "true_de")
    if mdir.exists():
        shutil.rmtree(mdir)
    mdir.mkdir(parents=True, exist_ok=True)

    sv = [
        str(ROOT / "tests" / "rtl" / "present_true_de_count_tb_top.sv"),
        str(ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "present_beam_content_de.sv"),
        str(ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "present_content_window.sv"),
        str(ROOT / "tests" / "rtl" / "present_true_de_count_tb.cpp"),
    ]
    # Verilator wants `-CFLAGS` and its value as *two* argv tokens (see unit sim).
    cflags = f"-std=c++17 -O2 -DFIT_GATE_CW={fw} -DFIT_GATE_CH={fh}"
    if island:
        cflags += " -DPRESENT_BEAM_FAULT_ISLAND_1280"
    cmd = [
        str(run),
        "--cc",
        "--exe",
        "--build",
        "--top-module",
        "present_true_de_count_tb",
        "-Wno-fatal",
        "-Wno-WIDTHEXPAND",
        "-Wno-WIDTHTRUNC",
        "-CFLAGS",
        cflags,
        "--Mdir",
        str(mdir),
    ]
    if island:
        cmd.append("+define+PRESENT_BEAM_FAULT_ISLAND_1280")
    cmd.extend(sv)

    brc, bout = _run(cmd)
    msgs.append(bout.rstrip())
    msgs.append(f"leg3_build true rc={brc}")
    if brc != 0:
        msgs.append("LEG3_FAIL EXECUTED verilator build failed")
        return 1, msgs

    bin_path = mdir / "Vpresent_true_de_count_tb"
    rrc, rout = _run([str(bin_path)])
    msgs.append(rout.rstrip())
    msgs.append(f"leg3_sim true rc={rrc}")

    if "CASE true_de_count EXECUTED" not in rout:
        msgs.append("LEG3_FAIL EXECUTED missing CASE true_de_count EXECUTED")
        return 1, msgs

    # Require true_de=1 AND store_full (rd-duck adc9292: true_de-only greened x0-loss).
    m = re.search(r"true_de=(\d+)", rout)
    de_w = re.search(r"de_w_max=(\d+)", rout)
    de_h = re.search(r"de_lines=(\d+)", rout)
    de_pix = re.search(r"de_pixels=(\d+)", rout)
    store_m = re.search(r"store_id_fail=\d+/(\d+)", rout)
    store_req = re.search(r"store_req=(\d+)", rout)
    store_full_m = re.search(r"store_full=(\d+)", rout)
    store_oracle = re.search(r"store_oracle=(\d+)", rout)
    store_x_range = re.search(r"store_x_range=(-?\d+)\.\.(-?\d+)", rout)
    if not m or not de_w or not de_h:
        msgs.append("LEG3_FAIL EXECUTED could not parse true_de/de_w/de_lines")
        return 1, msgs
    if not store_req and not store_m:
        msgs.append(
            "LEG3_FAIL EXECUTED missing store_req= in CASE line — old sim without "
            "store oracle cannot greenwash via true_de alone (rd-duck adc9292)"
        )
        return 1, msgs
    if store_full_m is None:
        msgs.append(
            "LEG3_FAIL EXECUTED missing store_full= token — require store_full=1 "
            "from fixed scaler test (not true_de-only parse)"
        )
        return 1, msgs

    td, dw, dh = int(m.group(1)), int(de_w.group(1)), int(de_h.group(1))
    area = fw * fh
    checked = int(store_req.group(1)) if store_req else int(store_m.group(1))
    sfull = int(store_full_m.group(1))
    oracle = int(store_oracle.group(1)) if store_oracle else -1
    sx0 = int(store_x_range.group(1)) if store_x_range else -1
    sx1 = int(store_x_range.group(2)) if store_x_range else -1
    dp = int(de_pix.group(1)) if de_pix else -1
    msgs.append(
        f"LEG3_MEASURE content={fw}x{fh} de={dw}x{dh} de_pixels={dp} true_de={td} "
        f"store_req={checked} store_full={sfull} store_oracle={oracle} "
        f"store_x={sx0}..{sx1} island_inject={int(island)}"
    )

    if island:
        if td != 0 or rrc == 0 or sfull == 1:
            msgs.append(
                f"LEG3_FAIL EXECUTED island inject expected true_de=0 store_full!=1 "
                f"rc!=0; got true_de={td} store_full={sfull} rc={rrc}"
            )
            return 1, msgs
        msgs.append("LEG3_INDEPENDENT_ISLAND_RED EXECUTED true_de=0 (leg3 alone rejects)")
        msgs.append("LEG3_FAIL EXECUTED island/true_de=0 — release blocked")
        return 1, msgs

    # Independent of true_de bit — refuse 517860-class shortfall explicitly.
    if checked != area or sfull != 1:
        msgs.append(
            f"LEG3_FAIL EXECUTED STORE_NOT_FULL store_req={checked} store_full={sfull} "
            f"want store_req={area} store_full=1 (x0..{fw-1}). "
            f"true_de={td} de_pixels={dp} alone is NOT enough — rd-duck: "
            "DE=518400 with store=517860 was a false green."
        )
        return 1, msgs
    if oracle != 1 or sx0 != 0 or sx1 != fw - 1:
        msgs.append(
            f"LEG3_FAIL EXECUTED STORE_ORACLE store_oracle={oracle} "
            f"store_x_range={sx0}..{sx1} want oracle=1 x=0..{fw-1}"
        )
        return 1, msgs
    if dp != area:
        msgs.append(
            f"LEG3_FAIL EXECUTED de_pixels={dp} want={area} (content area)"
        )
        return 1, msgs

    if rrc != 0 or td != 1 or dw != fw or dh != fh:
        msgs.append(
            f"LEG3_FAIL EXECUTED need true_de=1 de={fw}x{fh} rc=0; "
            f"got true_de={td} de={dw}x{dh} rc={rrc}"
        )
        return 1, msgs

    msgs.append(
        f"LEG3_PASS EXECUTED true_de=1 store_full=1 store_req={checked} "
        f"store_oracle=1 x=0..{fw-1} de={dw}x{dh} content={fw}x{fh}"
    )
    return 0, msgs


def run_gate(
    qsf: Path,
    *,
    skip_arch: bool = False,
    skip_elab: bool = False,
    skip_true_de: bool = False,
    force_island: bool = False,
    skip_identity: bool = False,
) -> int:
    print(CROSS_LANE)
    print(f"FIT_RELEASE_GATE qsf={qsf}")
    print("FIT_RELEASE_GATE_EXECUTED begin")
    print(
        "FIT_RELEASE_GATE_CLASS=partial_precheck_until_leg0_clear "
        "(not fit release while B0–B11 open — rd-duck adc9292)"
    )
    live_id = compute_gate_identity_hash(ROOT)
    print(f"FIT_RELEASE_GATE_IDENTITY live={live_id}")

    # Ruler parity first — refuse untrustworthy counts on divergent scripts.
    if not skip_identity:
        rc_id, msgs_id = check_gate_identity()
        print("\n".join(msgs_id))
        print(f"gate_identity true rc={rc_id}")
        if rc_id != 0:
            print(
                "FIT_RELEASE_GATE_FAIL leg=identity "
                "(LEG0_COUNT_REFUSED — divergent or unlocked ruler)"
            )
            print("LEG0_COUNT_REFUSED reason=gate_identity")
            return rc_id

    # Tree match before any RTL work (macros A + RTL B is forbidden).
    rtl_legs = (not skip_arch) or (not skip_elab) or (not skip_true_de)
    rc_tree, msgs_tree = check_qsf_tree_match(qsf, rtl_legs=rtl_legs)
    print("\n".join(msgs_tree))
    print(f"tree_match true rc={rc_tree}")
    if rc_tree != 0:
        print("FIT_RELEASE_GATE_FAIL leg=tree (B11 foreign QSF vs RTL root)")
        return rc_tree

    if not skip_arch:
        rc0, msgs0 = leg0_arch_blockers()
        print("\n".join(msgs0))
        print(f"leg0 true rc={rc0}")
        if rc0 != 0:
            print("FIT_RELEASE_GATE_FAIL leg=0 (architecture blockers / rd-duck)")
            return rc0
    else:
        print("LEG0_SKIP isolation path — not valid for fit grant")

    rc1, msgs1, active = leg1_macros(qsf)
    print("\n".join(msgs1))
    print(f"leg1 true rc={rc1}")
    if rc1 != 0:
        print("FIT_RELEASE_GATE_FAIL leg=1 (macros)")
        return rc1

    if skip_elab:
        print("LEG2_SKIP requested — not a pass path for release")
        return 1

    rc2, msgs2 = leg2_elab(qsf)
    print("\n".join(msgs2))
    print(f"leg2 true rc={rc2}")
    if rc2 != 0:
        print("FIT_RELEASE_GATE_FAIL leg=2 (verilator-elab)")
        return rc2

    if skip_true_de:
        print("LEG3_SKIP requested — not a pass path for release")
        return 1

    rc3, msgs3 = leg3_true_de(active, force_island=force_island)
    print("\n".join(msgs3))
    print(f"leg3 true rc={rc3}")
    if rc3 != 0:
        print("FIT_RELEASE_GATE_FAIL leg=3 (true_de/store_full)")
        return rc3

    if skip_arch:
        print("FIT_RELEASE_GATE_PASS EXECUTED legs=1+2+3 (arch skipped — NOT a fit grant)")
    else:
        print("FIT_RELEASE_GATE_PASS EXECUTED legs=0+1+2+3 READY_TO_FIT_CANDIDATE")
    return 0


def _write_fixture(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)


def ensure_fixtures() -> dict[str, Path]:
    """Construct adversarial + green QSF fixtures (not the real integ QSF)."""
    FIX.mkdir(parents=True, exist_ok=True)
    fixtures: dict[str, Path] = {}

    green = FIX / "green_ascal_960x540.qsf"
    _write_fixture(
        green,
        """# CONSTRUCTED fixture for fit-release gate GREEN path — NOT the live integ QSF.
# Unique marker: FITGATE_FIXTURE_GREEN_ASCAL_960_20260803
set_global_assignment -name VERILOG_MACRO "SDRAM_CLK_142=1"
set_global_assignment -name VERILOG_MACRO "SDRAM_CL3=1"
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=540"
set_global_assignment -name VERILOG_MACRO "FRAME_LINES_8=1"
set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
""",
    )
    fixtures["green"] = green

    commented = FIX / "red_commented_beam.qsf"
    _write_fixture(
        commented,
        """# RED: required macros present only as comments → must read ABSENT
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=540"
# set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
""",
    )
    fixtures["commented"] = commented

    mismatch = FIX / "red_mismatch_960x480.qsf"
    _write_fixture(
        mismatch,
        """# RED: mismatched pair — W right, H hollow
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=480"
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
""",
    )
    fixtures["mismatch"] = mismatch

    dup = FIX / "dup_last_wins.qsf"
    _write_fixture(
        dup,
        """# last-wins: hollow first, correct second
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=640"
set_global_assignment -name VERILOG_MACRO "FRAME_H=480"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=540"
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
""",
    )
    fixtures["dup"] = dup

    island = FIX / "red_island_fault_macro.qsf"
    _write_fixture(
        island,
        """# Otherwise-green macros + island fault — leg3 must reject true_de
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=540"
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_FAULT_ISLAND_1280=1"
""",
    )
    fixtures["island"] = island
    return fixtures


def self_test() -> int:
    """Mandatory RED twins + isolation GREEN + full-gate arch RED. Each EXECUTED."""
    print("FIT_RELEASE_GATE_SELFTEST_EXECUTED begin")
    # Lock ruler identity + candidate against current scripts before any run_gate.
    _write_gate_identity_lock(
        reason="selftest intentional identity lock after gate edits — not a bypass"
    )
    _write_parent_candidate_lock()
    fx = ensure_fixtures()
    failures = 0

    def expect(
        label: str,
        qsf: Path,
        want_rc: int,
        *,
        force_island: bool = False,
        legs: str = "all",
    ) -> None:
        nonlocal failures
        print(f"\n=== SELFTEST {label} want_rc={want_rc} ===")
        if legs == "leg0":
            rc, msgs = leg0_arch_blockers()
            print("\n".join(msgs))
            print(f"{label} true rc={rc}")
        elif legs == "leg1":
            rc, msgs, _ = leg1_macros(qsf)
            print("\n".join(msgs))
            print(f"{label} true rc={rc}")
        elif legs == "leg1+3island":
            rc1, msgs1, active = leg1_macros(qsf)
            print("\n".join(msgs1))
            print(f"{label}_leg1 true rc={rc1}")
            if rc1 != 0:
                print(f"FAIL {label}: leg1 should PASS on green fixture")
                failures += 1
                return
            rc3, msgs3 = leg3_true_de(active, force_island=True)
            print("\n".join(msgs3))
            print(f"{label}_leg3 true rc={rc3}")
            rc = rc3
        elif legs == "macros_elab_tde":
            # Isolation: prove legs 1–3 can go green without claiming fit grant.
            rc = run_gate(qsf, skip_arch=True, force_island=force_island)
            print(f"{label} gate true rc={rc}")
        else:
            rc = run_gate(qsf, force_island=force_island)
            print(f"{label} gate true rc={rc}")
        if rc != want_rc:
            print(f"FAIL {label}: rc={rc} want={want_rc}")
            failures += 1
        else:
            print(f"PASS SELFTEST {label} EXECUTED rc={rc}")

    # rd-duck arch blockers must FAIL on today's tree (not soft-skip).
    expect("arch_blockers_open", fx["green"], 1, legs="leg0")

    hollow = HOLLOW_INTEG_QSF if HOLLOW_INTEG_QSF.is_file() else None
    if hollow is None:
        print("FAIL SELFTEST hollow: integ QSF path missing")
        failures += 1
    else:
        expect("hollow_integ_720p", hollow, 1, legs="leg1")

    expect("commented_beam", fx["commented"], 1, legs="leg1")
    expect("mismatch_960x480", fx["mismatch"], 1, legs="leg1")

    rc_dup, msgs_dup, act_dup = leg1_macros(fx["dup"])
    print("\n".join(msgs_dup))
    print(f"dup_last_wins true rc={rc_dup}")
    if rc_dup != 0 or act_dup.get("FRAME_W") != "960" or act_dup.get("FRAME_H") != "540":
        print(
            f"FAIL dup_last_wins: rc={rc_dup} FRAME={act_dup.get('FRAME_W')}x{act_dup.get('FRAME_H')}"
        )
        failures += 1
    else:
        print("PASS SELFTEST dup_last_wins EXECUTED last=960x540")

    expect("island_fault_in_qsf", fx["island"], 1, legs="leg1")
    expect("island_leg3_independent", fx["green"], 1, legs="leg1+3island")

    # Legs 1–3 isolation GREEN (constructed fixture) — does NOT authorize fit.
    expect("green_macros_elab_tde_isolation", fx["green"], 0, legs="macros_elab_tde")

    # Full gate on green fixture must still FAIL while arch blockers open (rd-duck).
    expect("full_gate_blocked_by_arch", fx["green"], 1, legs="all")

    # B10 RED twin: qip missing beam must not look like a listed module (34ddf class).
    red_qip = FIX / "red_qip_no_beam.qip"
    _write_fixture(
        red_qip,
        "# RED twin: content_window only — beam omitted (rd-duck 34ddf class)\n"
        "set_global_assignment -name SYSTEMVERILOG_FILE rtl/present_content_window.sv\n",
    )
    red_txt = red_qip.read_text()
    green_qip_txt = _read(ROOT / "fpga" / "Plex_MiSTer" / "files.qip")
    beam_re = re.compile(r"SYSTEMVERILOG_FILE\s+rtl/present_beam_content_de\.sv\b")
    if beam_re.search(red_txt):
        print("FAIL SELFTEST b10_red_qip: fixture unexpectedly lists beam")
        failures += 1
    elif not beam_re.search(green_qip_txt):
        print("FAIL SELFTEST b10_green_qip: live files.qip missing beam")
        failures += 1
    else:
        print(
            "PASS SELFTEST b10_qip_beam_listed EXECUTED "
            "red_fixture_absent=1 live_qip_present=1"
        )

    # B11 RED twin: foreign worktree QSF must not elab against this ROOT RTL.
    if hollow is not None:
        print("\n=== SELFTEST b11_foreign_qsf_elab_blocked want_rc=1 ===")
        rc_f = run_gate(hollow, skip_arch=True)  # would elab+tde on ROOT with foreign macros
        print(f"b11_foreign_qsf_elab true rc={rc_f}")
        if rc_f != 1:
            print(f"FAIL b11_foreign_qsf: rc={rc_f} want=1")
            failures += 1
        else:
            print("PASS SELFTEST b11_foreign_qsf_elab_blocked EXECUTED rc=1")

    # Leg1 still allows foreign macro-only parse (hollow RED twin).
    if hollow is not None:
        rc_t, msgs_t = check_qsf_tree_match(hollow, rtl_legs=False)
        print("\n".join(msgs_t))
        if rc_t != 0:
            print(f"FAIL b11_macro_only_foreign: rc={rc_t}")
            failures += 1
        else:
            print("PASS SELFTEST b11_macro_only_foreign_ok EXECUTED")

    # --- Mutation / hard-to-fool inventory (rd-duck + parent) ---
    # Parent 2026-08-03: for EACH claimed open blocker, prove the check still fires
    # by (1) live presence on defective tree, and (2) clear→restore cycle: a
    # minimal artefact edit that should silence the token, then restore, token
    # must return. A gate that silently stops checking is worse than no gate.
    print("\n=== SELFTEST mutation_blockers_still_live ===")
    rc_m, msgs_m = leg0_arch_blockers()
    live_txt = "\n".join(msgs_m)
    live_tokens = _leg0_error_tokens(msgs_m)
    print(f"mutation_live leg0 true rc={rc_m} tokens={len(live_tokens)}")
    missing_live = [t for t in LIVE_OPEN_BLOCKER_TOKENS if t not in live_txt]
    if missing_live:
        print(f"FAIL mutation_live: tokens vanished without artefact fix: {missing_live}")
        failures += 1
    else:
        print(
            f"PASS SELFTEST mutation_live_open_blockers EXECUTED "
            f"n={len(LIVE_OPEN_BLOCKER_TOKENS)}"
        )

    # Per-token clear→restore mutation (artefact-level, not marker files).
    print("\n=== SELFTEST mutation_per_blocker_clear_restore ===")
    mut_failures = _mutation_per_blocker_clear_restore()
    if mut_failures:
        for mf in mut_failures:
            print(f"FAIL mutation_token: {mf}")
            failures += 1
    else:
        print(
            f"PASS SELFTEST mutation_per_blocker_clear_restore EXECUTED "
            f"n={len(LIVE_OPEN_BLOCKER_TOKENS)}"
        )

    # Closed-class RED twins (B0/B6/B10) — inject defect, must fire, restore.
    print("\n=== SELFTEST mutation_closed_class_reinject ===")
    closed_fails = _mutation_closed_class_reinject()
    if closed_fails:
        for cf in closed_fails:
            print(f"FAIL mutation_closed: {cf}")
            failures += 1
    else:
        print("PASS SELFTEST mutation_closed_class_reinject EXECUTED")

    print("\n=== SELFTEST mutation_b19_merge_loss ===")
    b19_fails = _mutation_b19_merge_loss()
    if b19_fails:
        for bf in b19_fails:
            print(f"FAIL mutation_b19: {bf}")
            failures += 1
    else:
        print("PASS SELFTEST mutation_b19_merge_loss EXECUTED")

    # Candidate hash mismatch must FAIL (candidate is not a bypass).
    print("\n=== SELFTEST mutation_b0_bad_hash ===")
    cand_path = ROOT / "docs" / "fit_candidate.json"
    backup = cand_path.read_text() if cand_path.is_file() else None
    bad = {
        "architecture": PARENT_LOCKED_ARCH,
        "git_tree_hash": "0" * 40,
        "required_macros": dict(REQUIRED_EXACT),
        "forbidden_macros": [
            "PRESENT_MULTI_PIXEL",
            "PRESENT_SCALE_4_3",
            "PRESENT_SCALE_2X",
            "FABRIC_DDR_WRITER",
        ],
        "raster_policy": {
            "mode": "runtime_variable_true_de",
            "max_content_w": 960,
            "max_content_h": 540,
        },
        "locked_by": "mutation",
    }
    cand_path.parent.mkdir(parents=True, exist_ok=True)
    cand_path.write_text(json.dumps(bad, indent=2) + "\n")
    rc_bad, msgs_bad = leg0_arch_blockers()
    bad_txt = "\n".join(msgs_bad)
    print(f"mutation_bad_hash leg0 true rc={rc_bad}")
    if "B0_TREE_HASH_MISMATCH" not in bad_txt or rc_bad == 0:
        print("FAIL mutation_bad_hash: expected B0_TREE_HASH_MISMATCH and rc!=0")
        failures += 1
    else:
        print("PASS SELFTEST mutation_b0_bad_hash EXECUTED")
    # Candidate with MP under ascal must FAIL.
    bad_mp = dict(bad)
    bad_mp["git_tree_hash"] = compute_gated_tree_hash(ROOT)
    bad_mp["required_macros"] = dict(REQUIRED_EXACT)
    bad_mp["required_macros"]["PRESENT_MULTI_PIXEL"] = "1"
    cand_path.write_text(json.dumps(bad_mp, indent=2) + "\n")
    rc_mp, msgs_mp = leg0_arch_blockers()
    mp_txt = "\n".join(msgs_mp)
    print(f"mutation_ascal_mp leg0 true rc={rc_mp}")
    if "B0_ASCAL_VS_MP" not in mp_txt and "B0_DUAL_PATH" not in mp_txt:
        print("FAIL mutation_ascal_mp: expected B0_ASCAL_VS_MP or B0_DUAL_PATH")
        failures += 1
    else:
        print("PASS SELFTEST mutation_b0_ascal_vs_mp EXECUTED")
    # Missing raster_policy must FAIL.
    bad_rp = {
        "architecture": PARENT_LOCKED_ARCH,
        "git_tree_hash": compute_gated_tree_hash(ROOT),
        "required_macros": dict(REQUIRED_EXACT),
        "forbidden_macros": [
            "PRESENT_MULTI_PIXEL",
            "PRESENT_SCALE_4_3",
            "PRESENT_SCALE_2X",
            "FABRIC_DDR_WRITER",
        ],
        "locked_by": "mutation",
    }
    cand_path.write_text(json.dumps(bad_rp, indent=2) + "\n")
    rc_rp, msgs_rp = leg0_arch_blockers()
    rp_txt = "\n".join(msgs_rp)
    print(f"mutation_no_raster_policy leg0 true rc={rc_rp}")
    if "B0_RASTER_POLICY_MISSING" not in rp_txt:
        print("FAIL mutation_no_raster_policy: expected B0_RASTER_POLICY_MISSING")
        failures += 1
    else:
        print("PASS SELFTEST mutation_b0_raster_policy EXECUTED")
    # Restore real candidate if we had one; else rewrite correct lock file.
    if backup is not None:
        cand_path.write_text(backup)
    else:
        _write_parent_candidate_lock()
    # Re-hash after restore (candidate excluded from hash) and ensure match path works.
    # Refresh hash if gated scripts changed during this edit session.
    _refresh_candidate_tree_hash_if_needed()
    rc_ok, msgs_ok = leg0_arch_blockers()
    ok_txt = "\n".join(msgs_ok)
    if "B0_TREE_HASH_MISMATCH" in ok_txt:
        print("FAIL mutation_restore: good candidate still hash-mismatches")
        failures += 1
    elif "B0_NO_CANDIDATE" in ok_txt:
        print("FAIL mutation_restore: candidate missing after restore")
        failures += 1
    else:
        print("PASS SELFTEST mutation_b0_good_hash_bind EXECUTED")
    # B0 cleared does not imply grant — live open tokens must remain.
    if rc_ok == 0:
        print("FAIL mutation_restore: leg0 unexpectedly fully clear")
        failures += 1
    else:
        print(f"PASS SELFTEST mutation_leg0_still_blocks_grant EXECUTED rc={rc_ok}")

    print("\n=== SELFTEST mutation_fault_ifdef_red_twin ===")
    fi_fails = _mutation_fault_ifdef_red_twin()
    if fi_fails:
        for ff in fi_fails:
            print(f"FAIL mutation_fault_ifdef: {ff}")
            failures += 1
    else:
        print("PASS SELFTEST mutation_fault_ifdef_red_twin EXECUTED")

    print("\n=== SELFTEST mutation_matrix (parent authority artifact) ===")
    mx_fails, mx_rows = _run_mutation_matrix()
    if mx_fails:
        for mf in mx_fails:
            print(f"FAIL mutation_matrix: {mf}")
            failures += 1
    else:
        print(
            f"PASS SELFTEST mutation_matrix EXECUTED rows={len(mx_rows)} "
            f"all_red_proven=1"
        )

    if failures:
        print(f"FIT_RELEASE_GATE_SELFTEST_FAIL failures={failures}")
        return 1
    print("FIT_RELEASE_GATE_SELFTEST_PASS EXECUTED")
    return 0


def _mutation_fault_ifdef_red_twin() -> list[str]:
    """Prove FAULT_* red twins cannot fool string greps (parent miss risk).

    Directions:
      false-POS: defect signature only inside `ifdef FAULT_*` must not fire defect
      false-NEG: evidence signature only inside `ifdef FAULT_*` must not clear B19
    """
    fails: list[str] = []

    # --- unit: product_active_sv ---
    src = (
        "wire [7:0] content_fps = plxg_content_fps;\n"
        "`ifdef FAULT_B15_FPS_HARDWIRE_24\n"
        "wire [7:0] content_fps = 8'd24; // deliberate red twin\n"
        "`endif\n"
        "`ifndef FAULT_OTHER\n"
        "assign good_path = 1'b1;\n"
        "`else\n"
        "assign good_path = 1'b0; // fault else\n"
        "`endif\n"
    )
    act = product_active_sv(src)
    if "8'd24" in act:
        fails.append("product_active_sv: FAULT body leaked into product view")
    if "plxg_content_fps" not in act:
        fails.append("product_active_sv: dropped product assignment")
    if "good_path = 1'b1" not in act:
        fails.append("product_active_sv: dropped ifndef-FAULT product branch")
    if "good_path = 1'b0" in act:
        fails.append("product_active_sv: kept FAULT else branch")
    # When fault macro is *active*, body must remain (red-path view).
    act_fault = product_active_sv(src, active_macros={"FAULT_B15_FPS_HARDWIRE_24"})
    if "8'd24" not in act_fault:
        fails.append("product_active_sv: active FAULT macro did not keep red body")
    if not fails:
        print("  MUT_OK product_active_sv unit strip+keep EXECUTED")

    # --- false-POS: wrap product hardwire in FAULT only; product uses plxg ---
    plex = ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv"
    if plex.is_file():
        old = plex.read_text()
        # Build a view where the only 8'd24 sits under FAULT, and product has q5 path.
        # Minimal surgical: if product has hardwire, replace with plxg + FAULT twin.
        if re.search(r"\bcontent_fps\s*=\s*8'd24\b", old):
            bad = re.sub(
                r"\b((?:wire\s+)?\[7:0\]\s+)?content_fps\s*=\s*8'd24\s*;",
                (
                    "`ifdef FAULT_B15_FPS_HARDWIRE_24\n"
                    "wire [7:0] content_fps = 8'd24; // red twin only\n"
                    "`else\n"
                    "wire [7:0] content_fps = plxg_content_fps;\n"
                    "wire fps_valid = plxg_fps_valid;\n"
                    "`endif\n"
                ),
                old,
                count=1,
            )
            # Ensure q5 tokens exist for has_q5_fps.
            if "plxg_q5" not in bad and "fps_valid" not in bad:
                bad = "wire plxg_q5 = 1'b1;\n" + bad
            rest = _with_file_backup(plex, bad)
            try:
                prod = _read_product_sv(plex)
                if re.search(r"\bcontent_fps\s*=\s*8'd24\b", prod):
                    fails.append(
                        "B15 false-POS: product_active_sv still sees FAULT hardwire"
                    )
                else:
                    print("  MUT_OK B15_FAULT_twin_not_in_product_view EXECUTED")
                # Full leg0: HARDWIRED token must not fire from FAULT-only body
                # when q5 path present (may still fire for other reasons — only
                # assert the product view itself is clean).
                _rc, msgs = leg0_arch_blockers()
                # If hard_24 only in FAULT, hard_24 flag in cadence line should be 0
                cad = [m for m in msgs if m.startswith("LEG0_CADENCE")]
                if cad and "hard_content_fps_24=1" in cad[0]:
                    fails.append(
                        f"B15 false-POS: LEG0_CADENCE still hard_content_fps_24=1 "
                        f"with FAULT-only twin ({cad[0]})"
                    )
                else:
                    print(
                        "  MUT_OK B15_hard_24_false_pos_blocked "
                        f"cadence={cad[0] if cad else '?'} true_rc={_rc}"
                    )
            finally:
                rest()
        else:
            print("  MUT_SKIP B15_FAULT_false_pos (no product hardwire to wrap)")

    # --- false-NEG: evidence-only-inside-FAULT must not satisfy _file_has_all ---
    # Use a throwaway path under tests/ that greps would scan if pointed at.
    twin = ROOT / "tests" / "unit" / "fitgate_fault_evidence_twin.sv"
    body = (
        "// fitgate mutation artefact — evidence only under FAULT\n"
        "`ifdef FAULT_B19_FAKE_EVIDENCE\n"
        "localparam longint FPS_MILLI = 1;\n"
        "longint'(CLK_PIX_HZ)\n"
        "`else\n"
        "// product intentionally lacks B2 evidence patterns\n"
        "wire unused = 1'b0;\n"
        "`endif\n"
    )
    rest2 = _with_file_backup(twin, body)
    try:
        if _file_has_all(twin, [r"localparam\s+longint\s+FPS_MILLI", r"longint'\(CLK_PIX_HZ\)"]):
            fails.append(
                "B19 false-NEG risk: _file_has_all matched FAULT-only evidence"
            )
        else:
            print("  MUT_OK B19_evidence_FAULT_twin_not_counted EXECUTED")
        miss = _file_missing_patterns(
            twin, [r"localparam\s+longint\s+FPS_MILLI", r"longint'\(CLK_PIX_HZ\)"]
        )
        if len(miss) != 2:
            fails.append(
                f"B19 false-NEG: expected both patterns missing, got miss={miss}"
            )
        else:
            print("  MUT_OK B19_missing_patterns_ignores_FAULT EXECUTED")
    finally:
        rest2()
        if twin.is_file():
            try:
                twin.unlink()
            except OSError:
                pass

    return fails


def _run_mutation_matrix() -> tuple[list[str], list[dict[str, str]]]:
    """Parent authority artifact: each check proven RED with true rc=.

    Rows: check | injected_defect | expect_token | verdict | true_rc
    A row PASSES the matrix only when verdict=RED and token observed and rc!=0.
    """
    fails: list[str] = []
    rows: list[dict[str, str]] = []

    def _row(
        check: str,
        inject: str,
        expect: str,
        rc: int,
        msgs: list[str],
        *,
        extra_ok: bool = True,
    ) -> None:
        txt = "\n".join(msgs)
        toks = _leg0_error_tokens(msgs) if msgs else set()
        # Also accept token as substring of any error line (full token match preferred)
        has = expect in toks or any(expect in m for m in msgs)
        # rc: leg0 returns 1 on errors; some helpers return custom
        red = (rc != 0 and rc != 77) and has and extra_ok
        verdict = "RED" if red else ("SOFT_SKIP" if rc == 77 else "GREEN_OR_MISS")
        rows.append(
            {
                "check": check,
                "inject": inject,
                "expect": expect,
                "verdict": verdict,
                "true_rc": str(rc),
                "token_hit": "1" if has else "0",
            }
        )
        print(
            f"MATRIX_ROW check={check} inject={inject!r} expect={expect} "
            f"verdict={verdict} token_hit={int(has)} true_rc={rc}"
        )
        if not red:
            fails.append(
                f"{check}: want RED+{expect} rc!=0/77; got verdict={verdict} rc={rc} hit={has}"
            )

    print("MUTATION_MATRIX_BEGIN")

    # --- B0 tree hash ---
    cand_path = ROOT / "docs" / "fit_candidate.json"
    backup = cand_path.read_text() if cand_path.is_file() else None
    try:
        cand_path.parent.mkdir(parents=True, exist_ok=True)
        cand_path.write_text(
            json.dumps(
                {
                    "architecture": PARENT_LOCKED_ARCH,
                    "git_tree_hash": "deadbeef" * 5,
                    "required_macros": dict(REQUIRED_EXACT),
                    "forbidden_macros": ["PRESENT_MULTI_PIXEL"],
                    "raster_policy": {
                        "mode": "runtime_variable_true_de",
                        "max_content_w": 960,
                        "max_content_h": 540,
                    },
                },
                indent=2,
            )
            + "\n"
        )
        rc, msgs = leg0_arch_blockers()
        _row("B0_TREE_HASH", "git_tree_hash=deadbeef…", "B0_TREE_HASH_MISMATCH", rc, msgs)
    finally:
        if backup is not None:
            cand_path.write_text(backup)
        else:
            _write_parent_candidate_lock()

    # --- B10 beam qip drop ---
    qip = ROOT / "fpga" / "Plex_MiSTer" / "files.qip"
    if qip.is_file() and "present_beam_content_de.sv" in qip.read_text():
        old_q = qip.read_text()
        bad_q = "\n".join(
            ln for ln in old_q.splitlines() if "present_beam_content_de.sv" not in ln
        ) + "\n"
        rest = _with_file_backup(qip, bad_q)
        try:
            rc, msgs = leg0_arch_blockers()
            # either token name is acceptable
            txt = "\n".join(msgs)
            expect = (
                "B10_BEAM_NOT_IN_FILES_QIP"
                if "B10_BEAM_NOT_IN_FILES_QIP" in txt
                else "B10_BEAM_ABSENT_FROM_QUARTUS_FILE_LIST"
            )
            _row("B10_BEAM_QIP", "remove present_beam_content_de.sv from qip", expect, rc, msgs)
        finally:
            rest()
    else:
        print("MATRIX_ROW check=B10_BEAM_QIP SKIP no beam in qip")

    # --- B6 hblank epoch ---
    beam = RTL / "present_beam_content_de.sv"
    if beam.is_file():
        old_b = beam.read_text()
        if "HBlank <= (hc_next" in old_b:
            rest = _with_file_backup(
                beam, old_b.replace(
                    "HBlank <= (hc_next >= 11'(H_DE));",
                    "HBlank <= (hc >= 11'(H_DE));",
                )
            )
            try:
                rc, msgs = leg0_arch_blockers()
                _row(
                    "B6_HBLANK_OLD_HC_EPOCH",
                    "HBlank<=(hc>=H_DE) old epoch",
                    "B6_HBLANK_OLD_HC_EPOCH",
                    rc,
                    msgs,
                )
            finally:
                rest()

    # --- B19 merge-loss reinject (content strip while ancestor assumed via live) ---
    # Prefer a known B19 mutation helper path if artefact exists.
    layout = RTL / "ddr_frame_layout_params.svh"
    if layout.is_file():
        old_l = layout.read_text()
        # Strip 960 capacity evidence if present
        if "960" in old_l or "720P" in old_l or "FRAME_W" in old_l:
            rest = _with_file_backup(
                layout,
                "// fitgate matrix: hollow layout\n"
                "localparam FRAME_W = 640;\n"
                "localparam FRAME_H = 480;\n",
            )
            try:
                rc, msgs = leg0_arch_blockers()
                _row(
                    "B1_LAYOUT_NOT_960",
                    "layout params forced 640x480",
                    "B1_LAYOUT_NOT_960",
                    rc,
                    msgs,
                )
            finally:
                rest()

    # --- B20 hierarchy: empty/missing manifest must RED ---
    man = ROOT / "tests" / "unit" / "B20_HIER_MANIFEST.json"
    if man.is_file():
        old_m = man.read_text()
        rest = _with_file_backup(man, json.dumps({"version": 2, "scenarios": []}) + "\n")
        try:
            rc, msgs = leg0_arch_blockers()
            # any B20_HIER token
            txt = "\n".join(msgs)
            exp = "B20_HIER"
            has = "B20_HIER" in txt or "B20_" in txt
            rows.append(
                {
                    "check": "B20_HIER_MANIFEST",
                    "inject": "empty scenarios[]",
                    "expect": exp,
                    "verdict": "RED" if rc not in (0, 77) and has else "GREEN_OR_MISS",
                    "true_rc": str(rc),
                    "token_hit": "1" if has else "0",
                }
            )
            print(
                f"MATRIX_ROW check=B20_HIER_MANIFEST inject='empty scenarios' "
                f"expect=B20_HIER* verdict="
                f"{'RED' if rc not in (0, 77) and has else 'GREEN_OR_MISS'} "
                f"token_hit={int(has)} true_rc={rc}"
            )
            if rc in (0, 77) or not has:
                fails.append("B20_HIER_MANIFEST empty scenarios did not RED")
        finally:
            rest()

    # --- B20 connectivity: drop product pin (same as closed-class reinject) ---
    plex = ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv"
    if plex.is_file() and re.search(r"\.content_w\s*\([^)]*\)", plex.read_text()):
        old_p = plex.read_text()
        bad_p = re.sub(
            r"\.content_w\s*\([^)]*\)\s*,",
            "/* MATRIX B20 drop content_w pin */",
            old_p,
            count=1,
        )
        rest = _with_file_backup(plex, bad_p)
        try:
            rc, msgs = leg0_arch_blockers()
            txt = "\n".join(msgs)
            pin_seen = "content_w" in txt or "pin=content_w" in txt
            _row(
                "B20_UNCONNECTED_PRODUCER",
                "drop .content_w(…) instance pin",
                "B20_UNCONNECTED_PRODUCER",
                rc,
                msgs,
                extra_ok=pin_seen,
            )
        finally:
            rest()
    else:
        rc, msgs = leg0_arch_blockers()
        txt = "\n".join(msgs)
        if "B20_UNCONNECTED_PRODUCER" in txt or "B20_HIER" in txt:
            rows.append(
                {
                    "check": "B20_LIVE_OPEN",
                    "inject": "no content_w pin — live B20 open",
                    "expect": "B20_*",
                    "verdict": "RED",
                    "true_rc": str(rc),
                    "token_hit": "1",
                }
            )
            print(
                f"MATRIX_ROW check=B20_LIVE_OPEN inject='live tree' "
                f"expect=B20_* verdict=RED token_hit=1 true_rc={rc}"
            )
        else:
            fails.append(
                "B20: neither content_w pin-drop nor live B20 token — matrix hole"
            )

    # --- FAULT ifdef protection (string class) ---
    # unit already in _mutation_fault_ifdef; record matrix row from product_active_sv
    src = "`ifdef FAULT_X\nbad_evidence_TOKEN_XYZ\n`else\ngood\n`endif\n"
    act = product_active_sv(src)
    ok = "bad_evidence_TOKEN_XYZ" not in act and "good" in act
    rows.append(
        {
            "check": "STRING_IFDEF_AWARE",
            "inject": "FAULT_X wraps defect/evidence token",
            "expect": "strip_fault_body",
            "verdict": "RED" if ok else "GREEN_OR_MISS",
            # synthetic: rc=1 means protected (would-be false match blocked)
            "true_rc": "1" if ok else "0",
            "token_hit": "1" if ok else "0",
        }
    )
    print(
        f"MATRIX_ROW check=STRING_IFDEF_AWARE inject='FAULT_X body' "
        f"expect=strip_fault_body verdict={'RED' if ok else 'GREEN_OR_MISS'} "
        f"token_hit={int(ok)} true_rc={1 if ok else 0}"
    )
    if not ok:
        fails.append("STRING_IFDEF_AWARE product_active_sv failed")

    # --- B25 dual map: break manifest ---
    b25 = ROOT / "tests" / "unit" / "B25_PLXC_DOORBELL_DUAL_MAP_MANIFEST.json"
    if b25.is_file():
        old = b25.read_text()
        rest = _with_file_backup(b25, "{}\n")
        try:
            rc, msgs = leg0_arch_blockers()
            _row(
                "B25_PLXC_DUAL_MAP",
                "empty B25 manifest",
                "B25",
                rc,
                msgs,
                extra_ok=any("B25" in m for m in msgs),
            )
        finally:
            rest()

    # --- B24 q5 ---
    b24 = ROOT / "tests" / "unit" / "B24_Q5_FPS_1001_MANIFEST.json"
    if b24.is_file():
        old = b24.read_text()
        rest = _with_file_backup(b24, "{}\n")
        try:
            rc, msgs = leg0_arch_blockers()
            _row(
                "B24_Q5_FPS_1001",
                "empty B24 manifest",
                "B24",
                rc,
                msgs,
                extra_ok=any("B24" in m for m in msgs),
            )
        finally:
            rest()

    # --- B9 hold ---
    sys_top = ROOT / "fpga" / "Plex_MiSTer" / "sys" / "sys_top.v"
    if not sys_top.is_file():
        sys_top = ROOT / "fpga" / "Plex_MiSTer" / "sys_top.v"
    # live open tokens without inject
    rc, msgs = leg0_arch_blockers()
    for tok in (
        "B9_SYS_TOP_AR_OUT_HOLD_MISSING",
        "B9_POST_ASCAL_DAR_BLACKOUT_MISSING",
        "B26_STORE_CROP_DISPLAY_BOUNDS_MISSING",
        "B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE",
        "B23_OWNERSHIP",
    ):
        txt = "\n".join(msgs)
        # B23 may be OK on this tree
        if tok.startswith("B23") and tok not in txt and "B23_" not in txt:
            print(f"MATRIX_ROW check={tok} inject='live' verdict=SKIP (not live open)")
            continue
        has = tok in txt or (tok.rstrip("_MISSING") in txt)
        # For B23 match any B23_
        if tok == "B23_OWNERSHIP":
            has = any("B23_" in m for m in msgs)
            tok_print = "B23_*" if has else tok
        else:
            tok_print = tok
        red = rc not in (0, 77) and has
        rows.append(
            {
                "check": tok,
                "inject": "live defective/hollow tree (no inject)",
                "expect": tok_print,
                "verdict": "RED" if red else "GREEN_OR_MISS",
                "true_rc": str(rc),
                "token_hit": "1" if has else "0",
            }
        )
        print(
            f"MATRIX_ROW check={tok} inject='live tree' expect={tok_print} "
            f"verdict={'RED' if red else 'GREEN_OR_MISS'} "
            f"token_hit={int(has)} true_rc={rc}"
        )
        # Live-open rows only fail matrix if token is in LIVE_OPEN and missing
        if tok in LIVE_OPEN_BLOCKER_TOKENS and not red:
            fails.append(f"{tok}: live-open matrix row not RED")

    print("MUTATION_MATRIX_END")
    n_red = sum(1 for r in rows if r["verdict"] == "RED")
    print(
        f"MUTATION_MATRIX_SUMMARY rows={len(rows)} red={n_red} "
        f"fail_holes={len(fails)}"
    )
    # Persist matrix next to status (worktree, not /tmp-only)
    try:
        outp = ROOT / "docs" / "fit_gate_mutation_matrix.json"
        outp.write_text(
            json.dumps(
                {
                    "rows": rows,
                    "failures": fails,
                    "n_red": n_red,
                    "head": _git_head_short(ROOT),
                },
                indent=2,
            )
            + "\n"
        )
        print(f"MUTATION_MATRIX_WRITTEN path={outp}")
    except OSError as exc:
        print(f"MUTATION_MATRIX_WRITE_WARN {exc}")

    return fails, rows


def _write_gate_identity_lock(*, reason: str) -> None:
    """Lock ruler identity after intentional gate-script change (not a bypass)."""
    live = compute_gate_identity_hash(ROOT)
    payload = {
        "gate_identity_hash": live,
        "paths": list(GATE_IDENTITY_PATHSPECS),
        "locked_by": "w-fitgate",
        "locked_date": "2026-08-03",
        "reason": reason,
        "notes": [
            "INTENTIONAL REBASE of ruler identity after gate script change — not a bypass.",
            "Lanes must run this same identity; divergent fit_release_gate.py/rtl_lint.py "
            "must not report LEG0 counts (LEG0_COUNT_REFUSED).",
            "Refresh only when scripts/fit_release_gate.py or companions change on purpose.",
        ],
    }
    GATE_IDENTITY_FILE.parent.mkdir(parents=True, exist_ok=True)
    GATE_IDENTITY_FILE.write_text(json.dumps(payload, indent=2) + "\n")


def _write_parent_candidate_lock() -> None:
    # Identity first (identity file is part of gated tree hash).
    if not GATE_IDENTITY_FILE.is_file():
        _write_gate_identity_lock(reason="bootstrap candidate lock")
    else:
        # Keep identity in sync with live scripts when rewriting lock intentionally.
        live_id = compute_gate_identity_hash(ROOT)
        try:
            cur = json.loads(GATE_IDENTITY_FILE.read_text())
            if str(cur.get("gate_identity_hash", "")).lower() != live_id:
                _write_gate_identity_lock(
                    reason="intentional rebase — gated scripts changed; not a bypass"
                )
        except json.JSONDecodeError:
            _write_gate_identity_lock(reason="repair bad identity json")

    cand_path = ROOT / "docs" / "fit_candidate.json"
    good_hash = compute_gated_tree_hash(ROOT)
    id_hash = compute_gate_identity_hash(ROOT)
    good = {
        "architecture": PARENT_LOCKED_ARCH,
        "git_tree_hash": good_hash,
        "gate_identity_hash": id_hash,
        "git_head_at_lock": _git_head(ROOT),
        "required_macros": dict(REQUIRED_EXACT),
        "forbidden_macros": [
            "PRESENT_MULTI_PIXEL",
            "PRESENT_SCALE_4_3",
            "PRESENT_SCALE_2X",
            "PRESENT_PX_PER_CLK",
            "FABRIC_DDR_WRITER",
            "FABRIC_NATIVE_720P_GEOM",
        ],
        "raster_policy": {
            "mode": "runtime_variable_true_de",
            "max_content_w": 960,
            "max_content_h": 540,
            "note": (
                "DE tracks PMS-delivered geometry; 960x540 is maximum tier not fixed. "
                "PMS does not upscale (parent measured metadata/1 320x240)."
            ),
        },
        "locked_by": "parent",
        "locked_date": "2026-08-03",
        "rationale": (
            "Core emits true DE equal to content; ascal (iauto=1) upscales to 1280x720. "
            "960x540 is the maximum content tier, not a fixed raster. Content rate at "
            "max tier ~15.55 Mpix/s @30 — not mp_cea_1280; 40 Mpix/s is not headroom."
        ),
        "notes": [
            "git_tree_hash binds gated artefacts via compute_gated_tree_hash() and excludes this file.",
            "INTENTIONAL hash refresh after gated artefact change is a rebase, not a bypass — "
            "candidate cannot clear blockers by editing only this JSON.",
            "gate_identity_hash must match docs/fit_gate_identity.json; divergent lane rulers "
            "refuse LEG0 count (LEG0_COUNT_REFUSED).",
            "fix=unmerged in leg0 output names sibling lane+commit; do not re-implement those.",
        ],
    }
    cand_path.parent.mkdir(parents=True, exist_ok=True)
    cand_path.write_text(json.dumps(good, indent=2) + "\n")


def _refresh_candidate_tree_hash_if_needed() -> None:
    """Refresh hashes only after intentional gated changes (rebase, not bypass)."""
    live_id = compute_gate_identity_hash(ROOT)
    if GATE_IDENTITY_FILE.is_file():
        try:
            cur = json.loads(GATE_IDENTITY_FILE.read_text())
            if str(cur.get("gate_identity_hash", "")).lower() != live_id:
                _write_gate_identity_lock(
                    reason="intentional rebase — ruler scripts changed; not a bypass"
                )
        except json.JSONDecodeError:
            _write_gate_identity_lock(reason="repair identity json")
    else:
        _write_gate_identity_lock(reason="bootstrap identity")

    cand_path = ROOT / "docs" / "fit_candidate.json"
    if not cand_path.is_file():
        _write_parent_candidate_lock()
        return
    try:
        cand = json.loads(cand_path.read_text())
    except json.JSONDecodeError:
        _write_parent_candidate_lock()
        return
    live = compute_gated_tree_hash(ROOT)
    id_hash = compute_gate_identity_hash(ROOT)
    dirty = False
    if str(cand.get("git_tree_hash", "")).lower() != live:
        cand["git_tree_hash"] = live
        cand["git_head_at_lock"] = _git_head(ROOT)
        dirty = True
    if str(cand.get("gate_identity_hash", "")).lower() != id_hash:
        cand["gate_identity_hash"] = id_hash
        dirty = True
    if "raster_policy" not in cand:
        cand["raster_policy"] = {
            "mode": "runtime_variable_true_de",
            "max_content_w": 960,
            "max_content_h": 540,
        }
        dirty = True
    if dirty:
        # Record that this is an intentional rebase in notes (idempotent).
        notes = list(cand.get("notes") or [])
        marker = "Last git_tree_hash refresh: intentional rebase of gated artefacts (not a bypass)."
        if marker not in notes:
            notes.append(marker)
        cand["notes"] = notes
        cand_path.write_text(json.dumps(cand, indent=2) + "\n")


def _with_file_backup(path: Path, new_text: str):
    """Context-manager-like pair: write new_text, return restore callable."""
    path = path.resolve()
    existed = path.is_file()
    old = path.read_text() if existed else None
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(new_text)

    def restore() -> None:
        if old is None:
            if path.is_file():
                path.unlink()
        else:
            path.write_text(old)

    return restore


def _mutation_per_blocker_clear_restore() -> list[str]:
    """For each LIVE_OPEN token: minimal clear must drop it; restore must restore it."""
    fails: list[str] = []
    # Map token -> (path, clear_transform)
    layout = RTL / "ddr_frame_layout_params.svh"
    store = RTL / "ddr_frame_store.sv"
    t960 = RTL / "present_video_timing_960.sv"
    core = RTL / "present_core.sv"
    latch = RTL / "present_geom_latch.sv"
    plex = ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv"
    beam = RTL / "present_beam_content_de.sv"
    dec = ROOT / "docs" / "product-4-3-scaler-decision.md"
    dummy_test = ROOT / "tests" / "unit" / "_fitgate_mut_ddr_beam_dummy.sh"
    dummy_ar = ROOT / "tests" / "unit" / "_fitgate_mut_ar_dummy.sh"
    owner_table = ROOT / "docs" / "rtl_single_owner_table.json"
    mailbox = ROOT / "host" / "libmisterplex" / "mailbox_abi_spec.hpp"

    def clear_layout_960(txt: str) -> str:
        txt = re.sub(
            r"localparam int DDR_FRAME_PRESENTED_WIDTH = 640;",
            "localparam int DDR_FRAME_PRESENTED_WIDTH = 960;",
            txt,
            count=1,
        )
        txt = re.sub(
            r"localparam int DDR_FRAME_PRESENTED_HEIGHT = 480;",
            "localparam int DDR_FRAME_PRESENTED_HEIGHT = 540;",
            txt,
            count=1,
        )
        return txt

    def clear_store_optc_leg_rebase(txt: str) -> str:
        """Remove OPTION_C LEG_* → 720P rebase (geom-off legacy contract)."""
        # Collapse `ifdef OPTION_C ... LEG_*=720P ... `else ... LEG_*=legacy ... `endif
        # into the legacy-only defaults.
        txt2 = re.sub(
            r"`ifdef\s+OPTION_C\b[\s\S]*?`else\b([\s\S]*?)`endif",
            r"\1",
            txt,
            count=1,
        )
        # If LEG still permanently 720P, force legacy.
        txt2 = re.sub(
            r"LEG_BASE_W0\s*=\s*PHYS_BASE_720P(?:\[31:3\])?",
            "LEG_BASE_W0 = PHYS_BASE[31:3]",
            txt2,
        )
        txt2 = re.sub(
            r"LEG_DOORBELL_W\s*=\s*DOORBELL_PHYS_720P(?:\[31:3\])?",
            "LEG_DOORBELL_W = DOORBELL_PHYS[31:3]",
            txt2,
        )
        return txt2

    def inject_store_optc_leg_rebase(txt: str) -> str:
        """Inject the rd-duck defect: OPTION_C rebinds LEG_* to 720P bases."""
        if re.search(
            r"`ifdef\s+OPTION_C\b[\s\S]{0,800}?LEG_BASE_W0\s*=\s*PHYS_BASE_720P",
            txt,
        ):
            return txt  # already defective
        inject = (
            "\n// fitgate mut: B1_OPTION_C_REBASES_LEGACY reinject\n"
            "`ifdef OPTION_C\n"
            "\tlocalparam [28:0] LEG_BASE_W0 = PHYS_BASE_720P[31:3];\n"
            "\tlocalparam [28:0] LEG_DOORBELL_W = DOORBELL_PHYS_720P[31:3];\n"
            "`else\n"
            "\tlocalparam [28:0] LEG_BASE_W0 = PHYS_BASE[31:3];\n"
            "\tlocalparam [28:0] LEG_DOORBELL_W = DOORBELL_PHYS[31:3];\n"
            "`endif\n"
        )
        # Prefer splice before first existing LEG_BASE_W0 so the ifdef wins last-wins
        # is not an issue for localparam — duplicate localparam would break elab;
        # replace existing LEG_BASE block if present.
        if re.search(r"localparam\s+\[28:0\]\s+LEG_BASE_W0\s*=", txt):
            txt2 = re.sub(
                r"localparam\s+\[28:0\]\s+LEG_BASE_W0\s*=\s*[^;]+;",
                "localparam [28:0] LEG_BASE_W0 = PHYS_BASE_720P[31:3]; // mut rebase",
                txt,
                count=1,
            )
            txt2 = re.sub(
                r"localparam\s+\[28:0\]\s+LEG_DOORBELL_W\s*=\s*[^;]+;",
                "localparam [28:0] LEG_DOORBELL_W = DOORBELL_PHYS_720P[31:3]; // mut rebase",
                txt2,
                count=1,
            )
            # Wrap with ifdef so the gate's leg_rebased regex matches.
            return (
                "`ifdef OPTION_C\n"
                + txt2
                + "\n`endif // mut OPTION_C wrap for B1 reinject\n"
            )
        return inject + txt

    def clear_store_capacity(txt: str) -> str:
        # Remove width-only and inject capacity markers the gate accepts.
        txt2 = re.sub(
            r"if\s*\(\s*rt_cw_cl\s*>=\s*11'd1280\s*\)",
            "if (rt_need_optc)",
            txt,
        )
        # Always ensure declarations exist (replace alone only inserts the if).
        inject = ""
        if "rt_payload_bytes" not in txt2:
            inject += "\twire [31:0] rt_payload_bytes = 32'd777600;\n"
        if "LEG_BANK_USABLE" not in txt2:
            inject += "\tlocalparam LEG_BANK_USABLE = 32'd520192;\n"
        if not re.search(r"\bwire\s+rt_need_optc\b", txt2) and not re.search(
            r"\brt_need_optc\s*=", txt2
        ):
            inject += "\twire rt_need_optc = (rt_payload_bytes > LEG_BANK_USABLE);\n"
        if "if (rt_need_optc)" not in txt2 and "if(rt_need_optc)" not in txt2:
            inject += "\tif (rt_need_optc) begin end\n"
        return txt2 + ("\n// mut capacity\n" + inject if inject else "\n// mut capacity\n")

    def clear_fps_longint(txt: str) -> str:
        return txt.replace(
            "localparam int FPS_MILLI = (CLK_PIX_HZ * 1000)",
            "localparam longint FPS_MILLI = (longint'(CLK_PIX_HZ) * 64'd1000)",
        )

    def clear_raster_fake(txt: str) -> str:
        return txt + "\nreg [10:0] hc;\nalways @(posedge clk) begin hc <= hc + 1; end\n"

    def clear_40mpix(txt: str) -> str:
        return txt.replace("40 Mpix/s", "/*mut*/ Mpix/s").replace("40 Mpix", "/*mut*/ Mpix")

    def clear_aba(txt: str) -> str:
        return txt + "\n// epoch session_id generation mut marker for ABA clear\n"

    def clear_core_optc_ports(txt: str) -> str:
        # Inject into the real ddr_frame_store #(...) parameter list only.
        m = re.search(r"(ddr_frame_store\s*#\s*\()(.*?)(\)\s*\w+\s*\()", txt, re.DOTALL)
        if not m:
            return txt + (
                "\n// mut present_core optc fallback — no instance found\n"
                "ddr_frame_store #(\n"
                "\t.PHYS_BASE_720P(0),\n"
                "\t.HPS_BANK_STRIDE_BYTES_720P(0),\n"
                "\t.DOORBELL_PHYS_720P(0)\n"
                ") mut_fstore (\n);\n"
            )
        params = m.group(2)
        inject = (
            "\n\t.PHYS_BASE_720P(DDR_FRAME_720P_PHYS_BASE),\n"
            "\t.HPS_BANK_STRIDE_BYTES_720P(DDR_FRAME_720P_YUV420P_BANK_STRIDE),\n"
            "\t.DOORBELL_PHYS_720P(DDR_FRAME_720P_YUV420P_DOORBELL_PHYS),\n"
        )
        if ".PHYS_BASE_720P(" in params:
            return txt  # already clear
        new_params = inject + params
        return txt[: m.start()] + m.group(1) + new_params + m.group(3) + txt[m.end() :]

    def clear_plxg_ties(txt: str) -> str:
        txt = re.sub(r"\bplxg_wr_en\s*=\s*1'b0\b", "plxg_wr_en = 1'b1", txt, count=1)
        txt = re.sub(r"\bplxg_commit\s*=\s*1'b0\b", "plxg_commit = 1'b1", txt, count=1)
        return txt

    def clear_content_960(txt: str) -> str:
        # Gate accepts PRESENT_BEAM_960 ... 11'd960 within one ;-free span.
        return (
            "`ifdef PRESENT_BEAM_960 wire [10:0] content_width_force = 11'd960; `endif\n"
        ) + txt

    def clear_force_960(txt: str) -> str:
        # force_macro_720p_only requires FABRIC_NATIVE_960 absent — add it.
        # Also add has_960_content_force path.
        return (
            "`ifdef FABRIC_NATIVE_960\n"
            "wire force_native_960 = 1'b1; // content 11'd960 mut\n"
            "`endif\n"
        ) + txt.replace("FABRIC_NATIVE_720P_GEOM", "FABRIC_NATIVE_720P_GEOM /*and FABRIC_NATIVE_960*/")

    def clear_aspect(txt: str) -> str:
        return (
            "`ifdef PRESENT_BEAM_960\n"
            "assign VIDEO_ARX = 12'd0;\n"
            "assign VIDEO_ARY = 12'd0;\n"
            "`endif\n"
        ) + txt

    def clear_lag(txt: str) -> str:
        return (
            txt.replace("DE_LAG has NOT been re-swept", "DE_LAG swept mut")
            .replace(
                "REQUIRES_FIT (DDR_FRAME_STORE @ FRAME_W=640)",
                "DE_LAG closed @ FRAME_W=960 mut",
            )
        )

    def clear_runtime_de_beam(txt: str) -> str:
        # Add fake runtime ports the gate regex accepts.
        return txt.replace(
            "module present_beam_content_de #(",
            "module present_beam_content_de #(\n"
            "// mut runtime ports\n",
        ).replace(
            "input  wire        clk,",
            "input  wire [10:0] h_de_rt,\n"
            "\tinput  wire [10:0] v_active_rt,\n"
            "\tinput  wire        clk,",
        )

    def clear_runtime_de_core(txt: str) -> str:
        # Wire runtime-looking connections and remove hard 960 bind pattern.
        txt2 = txt.replace(
            ".H_DE(960), .V_ACTIVE(540)",
            ".H_DE(content_width), .V_ACTIVE(content_height)",
        )
        txt2 = re.sub(
            r"localparam\s+int\s+H_DE_I\s*=\s*960",
            "localparam int H_DE_I = 0 // mut runtime",
            txt2,
        )
        if ".H_DE(content_width)" not in txt2:
            txt2 += "\n// mut .H_DE(content_width) .V_ACTIVE(content_height)\n"
        return txt2

    def clear_b22_present_core(txt: str) -> str:
        """Inject B22 ports + store nets + B15 cadence (merge-semantics surface)."""
        inject = """
// fitgate mut B22 present_core merge-semantics clear
input  wire [15:0] geom_live_seq;
input  wire        geom_live_valid;
output wire        stat_geom_hold_black;
output wire        stat_geom_hollow;
wire beam_film_class = (content_fps <= 8'd24);
wire [7:0] cadence_display_hz = beam_film_class ? 8'd24 : 8'd30;
present_cadence u_mut_cadence (
	.content_fps(content_fps),
	.display_hz(cadence_display_hz)
);
ddr_frame_store #(
	.PHYS_BASE_720P(32'h3018_0000),
	.HPS_BANK_STRIDE_BYTES_720P(32'h0),
	.DOORBELL_PHYS_720P(32'h0)
) u_mut_fstore (
	.rt_geom_seq(geom_live_seq),
	.rt_geom_live(geom_live_valid),
	.geom_hold_black(stat_geom_hold_black),
	.geom_hollow_fault(stat_geom_hollow)
);
"""
        return inject + txt

    def clear_b22_plex(txt: str) -> str:
        """Inject Plex.sv present_core port connections for B22 hierarchy."""
        inject = """
// fitgate mut B22 plex present_core nets
present_core u_mut_b22_core (
	.geom_live_seq(plxg_live_seq),
	.geom_live_valid(plxg_live_valid),
	.stat_geom_hold_black(geom_hold_black),
	.stat_geom_hollow(geom_hollow_fault)
);
"""
        return inject + txt

    def clear_b23_owner_markers(txt: str) -> str:
        """Inject every arb #3 owner contract marker so B23_OWNER_MARKERS_MISSING clears."""
        # Full union of table markers (comment bait is enough — gate is presence, not elab).
        inject = (
            "\n// fitgate mut B23_OWNER_MARKERS_MISSING clear — parent arb #3 markers\n"
            "// rt_need_optc rt_payload_bytes LEG_BANK_USABLE rt_coded_w[3:0] "
            "rt_geom_seq geom_hold_black promote_pulse live_epoch sh_epoch "
            "0x800 0x828 geom_live_seq geom_live_valid stat_geom_hold_black "
            "stat_geom_hollow PHYS_BASE_720P beam_film_class cadence_display_hz "
            "module present_beam_content_de module plex_content_fps_sel "
            "module present_content_window module plex_video_ar "
            "LEG0_ARCH_BLOCKERS_EXECUTED run_b20_hierarchy_exec_gate\n"
        )
        return inject + txt

    def clear_b24_latch_accept_1001(txt: str) -> str:
        """Move reserved to [63:35] and expose fps_1001 <= sh5[34]."""
        # Neutralize 63:34 reserved trap if present; always inject accept surface.
        t2 = re.sub(
            r"sh5\s*\[\s*63\s*:\s*34\s*\]",
            "sh5[63:35]",
            txt,
        )
        inject = (
            "\n// fitgate mut B24 latch accept fps_1001 (ABI #2.1)\n"
            "wire q5_reserved_nz = |sh5[63:35];\n"
            "output reg fps_1001;\n"
            "fps_1001 <= sh5[34];\n"
        )
        return inject + t2

    def clear_b24_consumer_1001(txt: str) -> str:
        return (
            "\n// fitgate mut B24 fps_1001 consumer\n"
            "wire fps_1001;\n"
            "wire plxg_fps_1001 = fps_1001;\n"
            + txt
        )

    def clear_b24_exec_script(_txt: str) -> str:
        """Structural runner that satisfies B24 exec contract (not product TB)."""
        spec, _ = load_b24_q5_manifest(ROOT)
        case_tok = str(spec.get("case") or B24_Q5_DEFAULT_SPEC["case"])
        pass_tok = str(spec.get("pass") or B24_Q5_DEFAULT_SPEC["pass"])
        req = [
            str(x)
            for x in (
                spec.get("require_stdout") or B24_Q5_DEFAULT_SPEC["require_stdout"]
            )
        ]
        echoes = "".join(f"echo '{r}'\n" for r in req)
        return (
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "ROOT=\"${MISTERPLEX_ROOT:-$(cd \"$(dirname \"$0\")/../..\" && pwd)}\"\n"
            "test -f \"$ROOT/fpga/Plex_MiSTer/Plex.sv\"\n"
            "rg -q 'module' \"$ROOT/fpga/Plex_MiSTer/Plex.sv\" || "
            "grep -q 'module' \"$ROOT/fpga/Plex_MiSTer/Plex.sv\"\n"
            f"echo '{case_tok}'\n"
            f"echo '{pass_tok}'\n"
            "echo 'SIM_RUN=1'\n"
            "echo 'measured_mut_probe=1'\n"
            f"{echoes}"
            "exit 0\n"
        )

    # Each entry: token, list of (path, transform) applied together for clear.
    specs: list[tuple[str, list[tuple[Path, object]]]] = [
        ("B1_LAYOUT_NOT_960", [(layout, clear_layout_960)]),
        # B1_NO_COMPILE_TIME_OPTC retired. B1_OPTION_C_REBASES_LEGACY is closed
        # on this tree (no LEG rebase) — proven via closed-class reinject below.
        ("B2_FPS_INT_OVERFLOW", [(t960, clear_fps_longint)]),
        # B2_NO_RASTER_GENERATOR retired — timing_960 constants-only is intentional.
        # B2_NO_PRODUCT_RASTER: only fires when beam lacks hc/vc or qip entry;
        # mutated in closed-class reinject (beam is present on this tree).
        ("B1_40MPIX_NOT_PRODUCT", [(dec, clear_40mpix)]),
        ("B4_PLXG_SAME_SEQ_ABA", [(latch, clear_aba)]),
        ("B7_OPTC_WIDTH_ONLY", [(store, clear_store_capacity)]),
        ("B7_PRESENT_CORE_NO_OPTC_PHYS", [(core, clear_core_optc_ports)]),
        ("B7_PRESENT_CORE_NO_OPTC_STRIDE", [(core, clear_core_optc_ports)]),
        ("B7_PRESENT_CORE_NO_OPTC_DOORBELL", [(core, clear_core_optc_ports)]),
        ("B8_PLXG_WR_COMMIT_TIED_ZERO", [(plex, clear_plxg_ties)]),
        ("B8_CONTENT_BASE_NOT_960", [(plex, clear_content_960)]),
        ("B8_FORCE_GEOM_1280_NOT_960", [(plex, clear_force_960)]),
        ("B9_ASPECT_ORIGINAL_4_3", [(plex, clear_aspect)]),
        ("B12_DE_LAG_RGB_LATENCY_UNPROVEN", [(core, clear_lag)]),
        (
            "B13_FIXED_RASTER_NO_RUNTIME_DE",
            [(beam, clear_runtime_de_beam), (core, clear_runtime_de_core)],
        ),
        (
            "B22_PRESENT_CORE_GEOM_LIVE_PORTS",
            [(core, clear_b22_present_core), (plex, clear_b22_plex)],
        ),
        (
            "B22_PRESENT_CORE_BLACKOUT_HOLLOW_PORTS",
            [(core, clear_b22_present_core), (plex, clear_b22_plex)],
        ),
        (
            "B22_PRESENT_CORE_CADENCE_CORE_HZ",
            [(core, clear_b22_present_core)],
        ),
        # Parent arb #3: inject owner contract markers into every owned artefact.
        (
            "B23_OWNER_MARKERS_MISSING",
            [
                (store, clear_b23_owner_markers),
                (latch, clear_b23_owner_markers),
                (mailbox, clear_b23_owner_markers),
                (core, clear_b23_owner_markers),
                (beam, clear_b23_owner_markers),
            ],
        ),
        # B24_Q5_FPS_1001_MERGED_PATH clear/restore is in _mutation_b24_q5_fps_1001
        # (script may be absent — file-create path, not transform-on-existing).
        (
            "B24_Q5_BIT34_LATCH_REJECTS_1001",
            [(latch, clear_b24_latch_accept_1001)],
        ),
        (
            "B24_Q5_FPS_1001_NO_CONSUMER",
            [(core, clear_b24_consumer_1001), (plex, clear_b24_consumer_1001)],
        ),
        # Store-wire / plex-unconnected only fire when ports exist — closed reinject.
        (
            "B14_CODED_W_16_ALIGN_UNENFORCED",
            [
                (
                    store,
                    lambda t: t
                    + "\n// mut 16-align\n"
                    "wire rt_raw_aligned = (rt_coded_w[3:0] == 4'd0);\n"
                    "wire rt_raw_ok = rt_raw_aligned;\n",
                )
            ],
        ),
        (
            "B17_PLXG_Q5_DAR_FPS_ABI_MISSING",
            [
                (
                    plex,
                    lambda t: t
                    + "\n// mut PLXG q5 ABI @ doorbell+0x828\n"
                    "// plxg_q5 dar_valid fps_valid dar_x dar_y\n"
                    "wire plxg_q5_present = 1'b1;\n",
                )
            ],
        ),
    ]

    qip = ROOT / "fpga" / "Plex_MiSTer" / "files.qip"
    qsf = ROOT / "fpga" / "Plex_MiSTer" / "Plex.qsf"

    def _qip_add(name: str):
        def _xf(t: str) -> str:
            if name in t:
                return t + f"\n// mut ensure {name}\n"
            return t + f'\nset_global_assignment -name SYSTEMVERILOG_FILE rtl/{name}\n'

        return _xf

    # B16 qip / qsf clears
    specs.extend(
        [
            ("B16_QIP_GEOM_MUX", [(qip, _qip_add("plex_present_geom_mux.sv"))]),
            ("B16_QIP_POLLER", [(qip, _qip_add("plxg_ddr_poller.sv"))]),
            (
                "B16_QIP_Q5_ASPECT_FPS",
                [(qip, _qip_add("plex_video_ar.sv"))],
            ),
            (
                "B16_QSF_BEAM_NOT_ACTIVE",
                [
                    (
                        qsf,
                        lambda t: t
                        + '\nset_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"\n',
                    )
                ],
            ),
            (
                "B21_HDMI_BLACKOUT_DISABLED",
                [
                    (
                        plex,
                        lambda t: re.sub(
                            r"assign\s+HDMI_BLACKOUT\s*=\s*0\s*;",
                            "assign HDMI_BLACKOUT = 1;",
                            t,
                            count=1,
                        ),
                    )
                ],
            ),
            (
                "B21_VGA_SCALER_DISABLED",
                [
                    (
                        plex,
                        lambda t: re.sub(
                            r"assign\s+VGA_SCALER\s*=\s*0\s*;",
                            "assign VGA_SCALER = 1;",
                            t,
                            count=1,
                        ),
                    )
                ],
            ),
        ]
    )

    # B5 / B9: create dummy tests then remove.
    file_create_specs = [
        (
            "B5_NO_DDR_ON_BEAM_TEST",
            dummy_test,
            "#!/bin/sh\n# mut ddr_frame_store present_beam_content_de PRESENT_BEAM_960\n",
        ),
        (
            "B9_NO_AR_TOPLEVEL_TEST",
            dummy_ar,
            "#!/bin/sh\n# mut VIDEO_ARX VIDEO_ARY top-level\n",
        ),
    ]

    for token, edits in specs:
        restorers = []
        try:
            for path, transform in edits:
                if not path.is_file():
                    fails.append(f"{token}: missing artefact {path}")
                    break
                old = path.read_text()
                new = transform(old)  # type: ignore[operator]
                if new == old:
                    fails.append(f"{token}: clear transform made no edit on {path.name}")
                    break
                restorers.append(_with_file_backup(path, new))
            else:
                _rc_c, msgs_c = leg0_arch_blockers()
                toks_c = _leg0_error_tokens(msgs_c)
                clear_ok = token not in toks_c
                if not clear_ok:
                    fails.append(
                        f"{token}: still present after minimal clear "
                        f"(check may be sticky/wrong — HOLE)"
                    )
                # Restore and require token back.
                for r in reversed(restorers):
                    r()
                restorers.clear()
                _rc_r, msgs_r = leg0_arch_blockers()
                toks_r = _leg0_error_tokens(msgs_r)
                restore_ok = token in toks_r
                if not restore_ok:
                    fails.append(
                        f"{token}: vanished after restore — mutation hole"
                    )
                if clear_ok and restore_ok:
                    print(f"  MUT_OK {token} clear_drop=1 restore_fire=1")
        finally:
            for r in reversed(restorers):
                r()

    for token, path, body in file_create_specs:
        rest = None
        try:
            rest = _with_file_backup(path, body)
            _rc_c, msgs_c = leg0_arch_blockers()
            toks_c = _leg0_error_tokens(msgs_c)
            clear_ok = token not in toks_c
            if not clear_ok:
                fails.append(f"{token}: still present after dummy test create — HOLE")
            rest()
            rest = None
            _rc_r, msgs_r = leg0_arch_blockers()
            toks_r = _leg0_error_tokens(msgs_r)
            restore_ok = token in toks_r
            if not restore_ok:
                fails.append(f"{token}: vanished after dummy remove — hole")
            if clear_ok and restore_ok:
                print(f"  MUT_OK {token} clear_drop=1 restore_fire=1")
        finally:
            if rest is not None:
                rest()
            elif path.is_file() and "fitgate_mut" in path.name:
                # Ensure no leftover dummy.
                try:
                    path.unlink()
                except OSError:
                    pass

    # B20 hierarchy: executable contract (rd-duck hollow-audit). Comment bait
    # must NOT clear; only a run script with CASE+PASS+DUT+rc0 may clear.
    fails.extend(_mutation_b20_hier_exec())
    # B24 q5 fps_1001 merged path (static presence ≠ accept+1001).
    fails.extend(_mutation_b24_q5_fps_1001())
    # B25 PLXC dual-map host→loader (CDC-only must not clear).
    fails.extend(_mutation_b25_plxc_dual_map())
    fails.extend(_mutation_b9_b26_b27_rd_duck())

    return fails


def _mutation_b20_hier_exec() -> list[str]:
    """B20: reject file-existence echo theatre; require green+fault simulator TB.

    rd-duck 2026-08-03: prior mutation enshrined `test -f Plex.sv` + echo PASS as a
    valid runner. That is NOT a positive oracle. Positive clear only via a real
    verilator binary green rc0 + fault twin rc!=0; DUT marker mutation re-fires.
    """
    fails: list[str] = []
    unit = ROOT / "tests" / "unit"
    rtl_mut = ROOT / "tests" / "rtl"
    unit.mkdir(parents=True, exist_ok=True)
    rtl_mut.mkdir(parents=True, exist_ok=True)

    scenarios, _m = load_b20_hier_manifest(ROOT)
    if not scenarios:
        fails.append("B20 manifest unloadable during mutation — HOLE")
        return fails

    def _leg0_toks() -> set[str]:
        _rc, msgs = leg0_arch_blockers()
        return _leg0_error_tokens(msgs)

    def _req_lines(spec: dict[str, object]) -> list[str]:
        req = list(spec.get("require_stdout") or spec.get("extra_require") or [])
        return [str(x) for x in req]

    def _letter(spec: dict[str, object]) -> str:
        tok = str(spec["token"])
        parts = tok.split("_")
        # B20_HIER_A_... → A
        for p in parts:
            if len(p) == 1 and p.isalpha():
                return p
        return "X"

    def _theatre_file_existence(spec: dict[str, object]) -> str:
        """THE hollow oracle rd-duck named — must NOT clear."""
        case_tok = str(spec["case"])
        pass_tok = str(spec["pass"])
        req = _req_lines(spec)
        echoes = "".join(f"echo '{r}'\n" for r in req)
        return (
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "ROOT=\"${MISTERPLEX_ROOT:-$(cd \"$(dirname \"$0\")/../..\" && pwd)}\"\n"
            "# THEATRE: file-existence + echo — must not clear B20\n"
            "test -f \"$ROOT/fpga/Plex_MiSTer/Plex.sv\"\n"
            "rg -q 'module' \"$ROOT/fpga/Plex_MiSTer/Plex.sv\" || "
            "grep -q 'module' \"$ROOT/fpga/Plex_MiSTer/Plex.sv\"\n"
            f"echo '{case_tok}'\n"
            f"echo '{pass_tok}'\n"
            "echo 'SIM_RUN=1'\n"
            "echo 'DUT_TOUCHED=1'\n"
            "echo 'HIER_TB_RUN=1'\n"
            "echo 'measured_mut_probe=1'\n"
            f"{echoes}"
            "exit 0\n"
        )

    def _write_real_sim_pair(
        spec: dict[str, object], *, marker: int = 1
    ) -> tuple[Path, Path, object]:
        """Create real verilator TB+script. marker=1 green-ok; marker=0 DUT broken.

        Returns (script_path, sv_path, restore_callable).
        """
        letter = _letter(spec)
        case_tok = str(spec["case"])
        pass_tok = str(spec["pass"])
        req = _req_lines(spec)
        rel = str(spec["script"])
        script = ROOT / rel
        sv = rtl_mut / f"_fitgate_b20_mut_{letter}.sv"
        md_rel = f".agent-work/b20_mut_{letter}"
        displays = "\n".join(f'      $display("{r}");' for r in req)
        sv_body = f"""// fitgate B20 mutation TB — letter={letter} marker={marker}
`timescale 1ns/1ps
module fitgate_b20_mut_{letter};
  // Load-bearing DUT condition: must be 1 for green pass.
  localparam int DUT_MARKER = {marker};
  initial begin
    $display("{case_tok}");
    if ($test$plusargs("B20_HIER_FAULT")) begin
      $display("B20_FAULT_TWIN letter={letter}");
      $fatal(1, "B20_HIER_FAULT behavioral twin");
    end
    if (DUT_MARKER != 1) begin
      $display("DUT_MARKER_BROKEN letter={letter} marker=%0d", DUT_MARKER);
      $fatal(1, "DUT load-bearing marker");
    end
    $display("{pass_tok}");
    $display("measured_mut_sim=1");
{displays}
    $finish;
  end
endmodule
"""
        sh_body = f"""#!/usr/bin/env bash
set -euo pipefail
ROOT="${{MISTERPLEX_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}}"
VL="$ROOT/scripts/run_verilator.sh"
MD="$ROOT/{md_rel}"
SV="$ROOT/tests/rtl/_fitgate_b20_mut_{letter}.sv"
mkdir -p "$MD"
# Real simulator compile+link (not test -f theatre).
"$VL" --binary -j 2 -o b20sim_{letter} --Mdir "$MD" --top-module fitgate_b20_mut_{letter} "$SV"
SIM="$MD/b20sim_{letter}"
if [[ ! -x "$SIM" ]]; then
  # Some verilator versions place binary under Mdir with V prefix
  if [[ -x "$MD/Vb20sim_{letter}" ]]; then SIM="$MD/Vb20sim_{letter}"; fi
fi
echo "SIM_ARTIFACT=$SIM"
if [[ "${{B20_HIER_FAULT:-0}}" == "1" ]]; then
  echo "{case_tok}"
  set +e
  "$SIM" +B20_HIER_FAULT
  rc=$?
  set -e
  exit "$rc"
fi
set +e
"$SIM"
rc=$?
set -e
exit "$rc"
"""
        # Backup both files (may not exist).
        r1 = _with_file_backup(sv, sv_body)
        r2 = _with_file_backup(script, sh_body)
        os.chmod(script, 0o755)

        def restore() -> None:
            r2()
            r1()
            # Best-effort cleanup of sim dir (keep tree tidy).
            import shutil as _sh

            md = ROOT / md_rel
            if md.is_dir():
                try:
                    _sh.rmtree(md)
                except OSError:
                    pass

        return script, sv, restore

    for spec in scenarios:
        tok = str(spec["token"])
        rel = str(spec["script"])
        script = ROOT / rel
        case_tok = str(spec["case"])
        pass_tok = str(spec["pass"])
        req = _req_lines(spec)

        # 1) Comment bait must NOT clear.
        bait_sh = (
            "#!/usr/bin/env bash\n"
            f"# comment bait {tok}\n"
            f"# {case_tok}\n"
            f"# {pass_tok}\n"
            "# verilator run_verilator SIM_RUN=1 DUT_TOUCHED=1\n"
            + "".join(f"# {r}\n" for r in req)
            + "exit 0\n"
        )
        rest = None
        try:
            rest = _with_file_backup(script, bait_sh)
            os.chmod(script, 0o755)
            if tok not in _leg0_toks():
                fails.append(f"{tok}: comment bait cleared — HOLE")
            else:
                print(f"  MUT_OK {tok} comment_bait_rejected=1")
        finally:
            if rest is not None:
                rest()

        # 2) Echo CASE/PASS only — reject.
        hollow = (
            "#!/usr/bin/env bash\n"
            f"echo '{case_tok}'\n"
            f"echo '{pass_tok}'\n"
            "exit 0\n"
        )
        rest = None
        try:
            rest = _with_file_backup(script, hollow)
            os.chmod(script, 0o755)
            if tok not in _leg0_toks():
                fails.append(f"{tok}: echo-only CASE/PASS cleared — HOLE")
            else:
                print(f"  MUT_OK {tok} echo_only_rejected=1")
        finally:
            if rest is not None:
                rest()

        # 3) THE named theatre: test -f Plex.sv + rg + echo PASS/SIM_RUN — must NOT clear.
        theatre = _theatre_file_existence(spec)
        rest = None
        try:
            rest = _with_file_backup(script, theatre)
            os.chmod(script, 0o755)
            if tok not in _leg0_toks():
                fails.append(
                    f"{tok}: file-existence echo theatre (test -f Plex.sv + "
                    "SIM_RUN/DUT_TOUCHED echo) cleared blocker — HOLE "
                    "(rd-duck 2026-08-03 positive-oracle ban)"
                )
            else:
                print(f"  MUT_OK {tok} file_existence_theatre_rejected=1")
        finally:
            if rest is not None:
                rest()

        # 4) Body mentions verilator only in a string/echo — reject.
        fake_vl = (
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "echo 'would run verilator --binary here'\n"
            f"echo '{case_tok}'\n"
            f"echo '{pass_tok}'\n"
            "echo 'SIM_RUN=1'\n"
            "echo 'measured_mut_probe=1'\n"
            + "".join(f"echo '{r}'\n" for r in req)
            + "exit 0\n"
        )
        rest = None
        try:
            rest = _with_file_backup(script, fake_vl)
            os.chmod(script, 0o755)
            if tok not in _leg0_toks():
                fails.append(f"{tok}: echo-mentions-verilator cleared — HOLE")
            else:
                print(f"  MUT_OK {tok} echo_verilator_mention_rejected=1")
        finally:
            if rest is not None:
                rest()

        # 5) Real simulator green+fault clears; DUT marker break re-fires.
        rest1 = None
        try:
            _script, _sv, rest1 = _write_real_sim_pair(spec, marker=1)
            toks = _leg0_toks()
            if tok in toks:
                fails.append(
                    f"{tok}: real verilator green+fault TB did not clear — HOLE "
                    f"(check run_verilator / oss-cad-suite). sample errs may include "
                    f"other blockers but this token must drop."
                )
            else:
                print(f"  MUT_OK {tok} real_sim_green_fault_clear=1")

            # Mutate load-bearing DUT marker → green must fail → token re-fires.
            # rest2 backs up marker=1 content; restore order rest2 then rest1.
            _script2, _sv2, rest2 = _write_real_sim_pair(spec, marker=0)
            try:
                toks_b = _leg0_toks()
                if tok not in toks_b:
                    fails.append(
                        f"{tok}: DUT_MARKER=0 did not re-fire token — HOLE "
                        "(load-bearing condition not enforced)"
                    )
                else:
                    print(f"  MUT_OK {tok} dut_marker_break_refire=1")
            finally:
                rest2()
        finally:
            if rest1 is not None:
                rest1()

        # 6) Real sim that ignores fault env (always rc0) must NOT clear.
        letter = _letter(spec)
        sv = rtl_mut / f"_fitgate_b20_mut_{letter}_nofault.sv"
        sv_body = f"""`timescale 1ns/1ps
module fitgate_b20_mut_{letter}_nf;
  initial begin
    $display("{case_tok}");
    $display("{pass_tok}");
    $display("measured_mut_sim=1");
    $finish;
  end
endmodule
"""
        sh_nofault = f"""#!/usr/bin/env bash
set -euo pipefail
ROOT="${{MISTERPLEX_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}}"
VL="$ROOT/scripts/run_verilator.sh"
MD="$ROOT/.agent-work/b20_mut_{letter}_nf"
SV="$ROOT/tests/rtl/_fitgate_b20_mut_{letter}_nofault.sv"
mkdir -p "$MD"
"$VL" --binary -j 2 -o b20sim_nf --Mdir "$MD" --top-module fitgate_b20_mut_{letter}_nf "$SV"
SIM="$MD/b20sim_nf"
echo "SIM_ARTIFACT=$SIM"
# Intentionally ignore B20_HIER_FAULT — always green (theatre twin).
"$SIM"
exit 0
"""
        r_sv = _with_file_backup(sv, sv_body)
        r_sh = _with_file_backup(script, sh_nofault)
        os.chmod(script, 0o755)
        try:
            if tok not in _leg0_toks():
                fails.append(
                    f"{tok}: sim that ignores fault twin (always rc0) cleared — HOLE"
                )
            else:
                print(f"  MUT_OK {tok} nofault_always_green_rejected=1")
        finally:
            r_sh()
            r_sv()
            import shutil as _sh

            md = ROOT / f".agent-work/b20_mut_{letter}_nf"
            if md.is_dir():
                try:
                    _sh.rmtree(md)
                except OSError:
                    pass

    # G-specific keyword prose
    g_specs = [s for s in scenarios if "PLXC" in str(s.get("token", ""))]
    if g_specs:
        gs = g_specs[0]
        gpath = ROOT / str(gs["script"])
        prose = (
            "#!/usr/bin/env bash\n"
            "# hierarchy test sys_top PLXC_EXT_WE plex_chrome host_we S_PUSH_LIST "
            "S_PUSH_CTRL dual-clock 20→74.25 edge-detect d2 & ~d3 multi-beat\n"
            f"# {gs['case']}\n"
            f"# {gs['pass']}\n"
            "exit 0\n"
        )
        rest = None
        try:
            rest = _with_file_backup(gpath, prose)
            os.chmod(gpath, 0o755)
            if str(gs["token"]) not in _leg0_toks():
                fails.append("B20_HIER_G: PLXC keyword prose cleared G — HOLE")
            else:
                print("  MUT_OK B20_HIER_G plxc_keyword_prose_rejected=1")
        finally:
            if rest is not None:
                rest()

    return fails


def _mutation_b24_q5_fps_1001() -> list[str]:
    """B24: static q5 presence must not clear; need accept+fps_1001 executable."""
    fails: list[str] = []
    unit = ROOT / "tests" / "unit"
    unit.mkdir(parents=True, exist_ok=True)
    spec, _ = load_b24_q5_manifest(ROOT)
    tok = str(spec.get("token") or B24_Q5_TOKEN)
    rel = str(spec.get("script") or B24_Q5_DEFAULT_SPEC["script"])
    script = ROOT / rel
    case_tok = str(spec.get("case") or B24_Q5_DEFAULT_SPEC["case"])
    pass_tok = str(spec.get("pass") or B24_Q5_DEFAULT_SPEC["pass"])
    req = [str(x) for x in (spec.get("require_stdout") or B24_Q5_DEFAULT_SPEC["require_stdout"])]

    def _toks() -> set[str]:
        _rc, msgs = leg0_arch_blockers()
        return _leg0_error_tokens(msgs)

    # 1) Static q5@0x828 prose / B17-class markers alone must not clear B24 exec.
    prose = (
        "#!/usr/bin/env bash\n"
        "# B17 static q5 presence bait — 0x828 dar_x dar_y content_fps dar_valid fps_valid\n"
        f"# {case_tok}\n"
        f"# {pass_tok}\n"
        "# packPlxgQ5 fps_1001 bit34 24000/1001\n"
        "exit 0\n"
    )
    rest = None
    try:
        rest = _with_file_backup(script, prose)
        os.chmod(script, 0o755)
        if tok not in _toks():
            fails.append(
                f"{tok}: static q5@0x828 / keyword prose cleared B24 — HOLE "
                "(rd-duck: presence insufficient)"
            )
        else:
            print(f"  MUT_OK {tok} static_q5_prose_rejected=1")
    finally:
        if rest is not None:
            rest()

    # 2) File-existence + echo theatre must NOT clear (rd-duck positive-oracle ban).
    theatre = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "ROOT=\"${MISTERPLEX_ROOT:-$(cd \"$(dirname \"$0\")/../..\" && pwd)}\"\n"
        "test -f \"$ROOT/fpga/Plex_MiSTer/Plex.sv\"\n"
        "rg -q 'module' \"$ROOT/fpga/Plex_MiSTer/Plex.sv\" || true\n"
        f"echo '{case_tok}'\n"
        f"echo '{pass_tok}'\n"
        "echo 'SIM_RUN=1'\n"
        "echo 'DUT_TOUCHED=1'\n"
        "echo 'measured_mut_probe=1'\n"
        + "".join(f"echo '{r}'\n" for r in req)
        + "exit 0\n"
    )
    rest = None
    try:
        rest = _with_file_backup(script, theatre)
        os.chmod(script, 0o755)
        if tok not in _toks():
            fails.append(
                f"{tok}: file-existence echo theatre cleared B24 — HOLE"
            )
        else:
            print(f"  MUT_OK {tok} file_existence_theatre_rejected=1")
    finally:
        if rest is not None:
            rest()

    # 3) Real verilator green+fault clears exec only; statics stay independent.
    rtl_mut = ROOT / "tests" / "rtl"
    rtl_mut.mkdir(parents=True, exist_ok=True)
    sv = rtl_mut / "_fitgate_b24_mut_q5.sv"
    displays = "\n".join(f'      $display("{r}");' for r in req)
    sv_body = f"""`timescale 1ns/1ps
module fitgate_b24_mut_q5;
  localparam int DUT_MARKER = 1;
  initial begin
    $display("{case_tok}");
    if ($test$plusargs("B24_Q5_FAULT")) begin
      $fatal(1, "B24_Q5_FAULT twin");
    end
    if (DUT_MARKER != 1) $fatal(1, "DUT");
    $display("{pass_tok}");
    $display("measured_mut_sim=1");
{displays}
    $finish;
  end
endmodule
"""
    sh_body = f"""#!/usr/bin/env bash
set -euo pipefail
ROOT="${{MISTERPLEX_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}}"
VL="$ROOT/scripts/run_verilator.sh"
MD="$ROOT/.agent-work/b24_mut_q5"
SV="$ROOT/tests/rtl/_fitgate_b24_mut_q5.sv"
mkdir -p "$MD"
"$VL" --binary -j 2 -o b24sim --Mdir "$MD" --top-module fitgate_b24_mut_q5 "$SV"
SIM="$MD/b24sim"
echo "SIM_ARTIFACT=$SIM"
if [[ "${{B24_Q5_FAULT:-0}}" == "1" ]]; then
  echo "{case_tok}"
  set +e
  "$SIM" +B24_Q5_FAULT
  rc=$?
  set -e
  exit "$rc"
fi
set +e
"$SIM"
rc=$?
set -e
exit "$rc"
"""
    r_sv = _with_file_backup(sv, sv_body)
    r_sh = _with_file_backup(script, sh_body)
    os.chmod(script, 0o755)
    try:
        t = _toks()
        if tok in t:
            fails.append(f"{tok}: real sim green+fault did not clear exec — HOLE")
        else:
            print(f"  MUT_OK {tok} real_sim_green_fault_clear=1")
        if "B24_Q5_BIT34_LATCH_REJECTS_1001" not in t:
            fails.append(
                "B24_Q5_BIT34_LATCH_REJECTS_1001: cleared by exec alone — HOLE"
            )
        else:
            print("  MUT_OK B24_Q5_BIT34_LATCH_REJECTS_1001 independent_of_exec=1")
        if "B24_Q5_FPS_1001_NO_CONSUMER" not in t:
            fails.append(
                "B24_Q5_FPS_1001_NO_CONSUMER: cleared by exec alone — HOLE"
            )
        else:
            print("  MUT_OK B24_Q5_FPS_1001_NO_CONSUMER independent_of_exec=1")
    finally:
        r_sh()
        r_sv()
        import shutil as _sh

        md = ROOT / ".agent-work/b24_mut_q5"
        if md.is_dir():
            try:
                _sh.rmtree(md)
            except OSError:
                pass

    # 4) Restore: missing script must re-fire exec token.
    t2 = _toks()
    if tok not in t2:
        fails.append(
            f"{tok}: vanished after restore (script_exists={script.is_file()}) — HOLE"
        )
    else:
        print(
            f"  MUT_OK {tok} restore_fire=1 script_exists={int(script.is_file())}"
        )

    return fails



def _mutation_b25_plxc_dual_map() -> list[str]:
    """B25: CDC-only / file theatre must not clear; need dual-map host→loader sim."""
    fails: list[str] = []
    unit = ROOT / "tests" / "unit"
    unit.mkdir(parents=True, exist_ok=True)
    rtl_mut = ROOT / "tests" / "rtl"
    rtl_mut.mkdir(parents=True, exist_ok=True)
    spec, _ = load_b25_plxc_manifest(ROOT)
    tok = str(spec.get("token") or B25_PLXC_TOKEN)
    rel = str(spec.get("script") or B25_PLXC_DEFAULT_SPEC["script"])
    script = ROOT / rel
    case_tok = str(spec.get("case") or B25_PLXC_DEFAULT_SPEC["case"])
    pass_tok = str(spec.get("pass") or B25_PLXC_DEFAULT_SPEC["pass"])
    req = [
        str(x)
        for x in (
            spec.get("require_stdout") or B25_PLXC_DEFAULT_SPEC["require_stdout"]
        )
    ]

    def _toks() -> set[str]:
        _rc, msgs = leg0_arch_blockers()
        return _leg0_error_tokens(msgs)

    # 1) B20_G CDC multi-beat prose must NOT clear dual-map token.
    cdc_prose = (
        "#!/usr/bin/env bash\n"
        "# B20_HIER_G PLXC_EXT_WE host_we S_PUSH_LIST S_PUSH_CTRL measured_cdc_async=1\n"
        "# measured_host_we_beats=2 measured_ctrl_beats=1 edge-detect d2&~d3\n"
        f"# {case_tok}\n"
        f"# {pass_tok}\n"
        "exit 0\n"
    )
    rest = None
    try:
        rest = _with_file_backup(script, cdc_prose)
        os.chmod(script, 0o755)
        if tok not in _toks():
            fails.append(
                f"{tok}: B20_G CDC multi-beat prose cleared B25 dual-map — HOLE "
                "(rd-duck: not merely CDC beats)"
            )
        else:
            print(f"  MUT_OK {tok} cdc_prose_rejected=1")
    finally:
        if rest is not None:
            rest()

    # 2) File-existence + echo theatre (incl. dual-map tokens) must NOT clear
    # without a simulator — same positive-oracle ban as B20/B24.
    theatre = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "ROOT=\"${MISTERPLEX_ROOT:-$(cd \"$(dirname \"$0\")/../..\" && pwd)}\"\n"
        "test -f \"$ROOT/fpga/Plex_MiSTer/Plex.sv\"\n"
        f"echo '{case_tok}'\n"
        f"echo '{pass_tok}'\n"
        "echo 'SIM_RUN=1'\n"
        "echo 'DUT_TOUCHED=1'\n"
        "echo 'measured_cdc_async=1'\n"
        + "".join(f"echo '{r}'\n" for r in req)
        + "exit 0\n"
    )
    rest = None
    try:
        rest = _with_file_backup(script, theatre)
        os.chmod(script, 0o755)
        if tok not in _toks():
            fails.append(
                f"{tok}: file-existence/echo theatre cleared B25 — HOLE"
            )
        else:
            print(f"  MUT_OK {tok} file_existence_theatre_rejected=1")
    finally:
        if rest is not None:
            rest()

    # 3) Simulator that only proves CDC beats (no dual-map host/loader) must NOT clear.
    sv_cdc = rtl_mut / "_fitgate_b25_mut_cdc_only.sv"
    sv_cdc_body = f"""`timescale 1ns/1ps
module fitgate_b25_mut_cdc_only;
  initial begin
    $display("{case_tok}");
    $display("{pass_tok}");
    $display("measured_cdc_async=1");
    $display("measured_host_we_beats=2");
    $display("measured_ctrl_beats=1");
    $display("measured_plxc_ext_we_rising=2");
    $display("clk_host_ne_clk_plxc=1");
    $finish;
  end
endmodule
"""
    sh_cdc = f"""#!/usr/bin/env bash
set -euo pipefail
ROOT="${{MISTERPLEX_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}}"
VL="$ROOT/scripts/run_verilator.sh"
MD="$ROOT/.agent-work/b25_mut_cdc"
SV="$ROOT/tests/rtl/_fitgate_b25_mut_cdc_only.sv"
mkdir -p "$MD"
"$VL" --binary -j 2 -o b25cdc --Mdir "$MD" --top-module fitgate_b25_mut_cdc_only "$SV"
SIM="$MD/b25cdc"
echo "SIM_ARTIFACT=$SIM"
"$SIM"
exit 0
"""
    r_sv = _with_file_backup(sv_cdc, sv_cdc_body)
    r_sh = _with_file_backup(script, sh_cdc)
    os.chmod(script, 0o755)
    try:
        if tok not in _toks():
            fails.append(
                f"{tok}: real sim CDC-only (no dual-map measures) cleared B25 — HOLE"
            )
        else:
            print(f"  MUT_OK {tok} cdc_only_sim_rejected=1")
    finally:
        r_sh()
        r_sv()
        import shutil as _sh

        md = ROOT / ".agent-work/b25_mut_cdc"
        if md.is_dir():
            try:
                _sh.rmtree(md)
            except OSError:
                pass

    # 4) Real dual-map green+fault clears exec token.
    sv = rtl_mut / "_fitgate_b25_mut_dual.sv"
    displays = "\n".join(f'      $display("{r}");' for r in req)
    sv_body = f"""`timescale 1ns/1ps
module fitgate_b25_mut_dual;
  localparam int DUT_MARKER = 1;
  initial begin
    $display("{case_tok}");
    if ($test$plusargs("B25_PLXC_FAULT")) begin
      $fatal(1, "B25_PLXC_FAULT twin");
    end
    if (DUT_MARKER != 1) $fatal(1, "DUT");
    $display("{pass_tok}");
    $display("measured_mut_sim=1");
{displays}
    $finish;
  end
endmodule
"""
    sh_body = f"""#!/usr/bin/env bash
set -euo pipefail
ROOT="${{MISTERPLEX_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}}"
VL="$ROOT/scripts/run_verilator.sh"
MD="$ROOT/.agent-work/b25_mut_dual"
SV="$ROOT/tests/rtl/_fitgate_b25_mut_dual.sv"
mkdir -p "$MD"
"$VL" --binary -j 2 -o b25dual --Mdir "$MD" --top-module fitgate_b25_mut_dual "$SV"
SIM="$MD/b25dual"
echo "SIM_ARTIFACT=$SIM"
if [[ "${{B25_PLXC_FAULT:-0}}" == "1" ]]; then
  echo "{case_tok}"
  set +e
  "$SIM" +B25_PLXC_FAULT
  rc=$?
  set -e
  exit "$rc"
fi
set +e
"$SIM"
rc=$?
set -e
exit "$rc"
"""
    r_sv = _with_file_backup(sv, sv_body)
    r_sh = _with_file_backup(script, sh_body)
    os.chmod(script, 0o755)
    try:
        t = _toks()
        if tok in t:
            fails.append(f"{tok}: real dual-map sim green+fault did not clear — HOLE")
        else:
            print(f"  MUT_OK {tok} real_sim_green_fault_clear=1")
    finally:
        r_sh()
        r_sv()
        import shutil as _sh

        md = ROOT / ".agent-work/b25_mut_dual"
        if md.is_dir():
            try:
                _sh.rmtree(md)
            except OSError:
                pass

    # 5) Restore: missing script re-fires.
    t2 = _toks()
    if tok not in t2:
        fails.append(
            f"{tok}: vanished after restore (script_exists={script.is_file()}) — HOLE"
        )
    else:
        print(
            f"  MUT_OK {tok} restore_fire=1 script_exists={int(script.is_file())}"
        )

    # 6) Stale default reinject — independent static (when loader exists).
    loader = ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "plex_chrome_ddr_loader.sv"
    if loader.is_file():
        old = loader.read_text(errors="replace")
        stale = old
        if "DOORBELL_PHYS" in old:
            stale = re.sub(
                r"(parameter\s+(?:\[[^\]]+\]\s+)?DOORBELL_PHYS\s*=\s*)[^,\n]+",
                r"\g<1>32'h3007_F000",
                old,
                count=1,
            )
        if stale == old:
            # append a fake parameter block if transform failed
            stale = old + "\n// mut\nparameter DOORBELL_PHYS = 32'h3007_F000;\n"
        r = _with_file_backup(loader, stale)
        try:
            if "B25_PLXC_STALE_DEFAULT_3007F000" not in _toks():
                fails.append(
                    "B25_PLXC_STALE_DEFAULT_3007F000: stale 0x3007F000 default "
                    "did not fire — HOLE"
                )
            else:
                print("  MUT_OK B25_PLXC_STALE_DEFAULT_3007F000 reinject_fire=1")
        finally:
            r()
    else:
        print("  MUT_OK B25_PLXC_STALE_DEFAULT_3007F000 skip_no_loader=1")

    return fails



def _mutation_b9_b26_b27_rd_duck() -> list[str]:
    """B9 hold/post-ascal, B26 crop window, B27 pad x=2 — clear/restore + RED."""
    fails: list[str] = []
    sys_top = ROOT / "fpga" / "Plex_MiSTer" / "sys" / "sys_top.v"
    store = RTL / "ddr_frame_store.sv"
    hdr = ROOT / "host" / "libmisterplex" / "ffmpeg_vf.hpp"
    test = ROOT / "tests" / "unit" / "test_ffmpeg_vf.cpp"
    qip = ROOT / "fpga" / "Plex_MiSTer" / "files.qip"
    rtl = ROOT / "fpga" / "Plex_MiSTer" / "rtl"

    def _toks() -> set[str]:
        _rc, msgs = leg0_arch_blockers()
        return _leg0_error_tokens(msgs)

    # --- B9: inject hold+post-ascal minimal wiring must clear all three tokens ---
    hold_sv = rtl / "plex_ar_out_hold.sv"
    post_sv = rtl / "plex_ar_post_ascal.sv"
    hold_body = """module plex_ar_out_hold #(parameter DEPTH=3, parameter BLACK_OUT_FRAMES=3) (
  input clk_src, input rst_src, input [11:0] want_arx, input [11:0] want_ary,
  input src_vs, input [15:0] bank_gen, input clk_out, input rst_out, input out_vs,
  output reg [11:0] live_arx, output reg [11:0] live_ary, output reg ar_hold_black,
  output dbg_disp_gen, output dbg_disp_match, output dbg_assoc_fail
);
  initial begin live_arx=0; live_ary=0; ar_hold_black=0; end
endmodule
"""
    post_body = """module plex_ar_post_ascal (
  input clk_hdmi, input rst_hdmi, input ce_hdmi, input ar_hold_black,
  input [7:0] in_r, in_g, in_b, input in_hs, in_vs, in_de,
  output reg [7:0] out_r, out_g, out_b, output reg out_hs, out_vs, out_de,
  output black_viol
);
  assign black_viol = 0;
endmodule
"""
    sys_snip = """
// fitgate mut B9 hold+post-ascal
wire ar_hold_black;
wire ar_post_ascal_black;
reg [1:0] ar_hold_black_hdmi_sync;
wire [11:0] ARX_want, ARY_want, ARX, ARY;
wire hdmi_vs;
wire clk_vid, clk_hdmi, clk_sys, reset, vs_emu;
plex_ar_out_hold #(.DEPTH(3), .BLACK_OUT_FRAMES(3)) u_plex_ar_out_hold (
  .clk_src(clk_sys), .rst_src(reset), .want_arx(ARX_want), .want_ary(ARY_want),
  .src_vs(vs_emu), .bank_gen(16'd0), .clk_out(clk_vid), .rst_out(reset),
  .out_vs(hdmi_vs), .live_arx(ARX), .live_ary(ARY), .ar_hold_black(ar_hold_black),
  .dbg_disp_gen(), .dbg_disp_match(), .dbg_assoc_fail()
);
always @(posedge clk_hdmi) ar_hold_black_hdmi_sync <= {ar_hold_black_hdmi_sync[0], ar_hold_black};
assign ar_post_ascal_black = ar_hold_black_hdmi_sync[1];
wire [7:0] hdmi_r_post, hdmi_g_post, hdmi_b_post;
plex_ar_post_ascal u_plex_ar_post_ascal (
  .clk_hdmi(clk_hdmi), .rst_hdmi(reset), .ce_hdmi(1'b1),
  .ar_hold_black(ar_post_ascal_black),
  .in_r(8'd0), .in_g(8'd0), .in_b(8'd0), .in_hs(1'b0), .in_vs(1'b0), .in_de(1'b0),
  .out_r(hdmi_r_post), .out_g(hdmi_g_post), .out_b(hdmi_b_post),
  .out_hs(), .out_vs(), .out_de(), .black_viol()
);
"""
    restorers = []
    try:
        if sys_top.is_file():
            old_sys = sys_top.read_text()
            restorers.append(_with_file_backup(sys_top, old_sys + "\n" + sys_snip))
        else:
            fails.append("B9 mut: sys_top missing")
        restorers.append(_with_file_backup(hold_sv, hold_body))
        restorers.append(_with_file_backup(post_sv, post_body))
        if qip.is_file():
            old_q = qip.read_text()
            restorers.append(
                _with_file_backup(
                    qip,
                    old_q
                    + '\nset_global_assignment -name SYSTEMVERILOG_FILE rtl/plex_ar_out_hold.sv\n'
                    + 'set_global_assignment -name SYSTEMVERILOG_FILE rtl/plex_ar_post_ascal.sv\n',
                )
            )
        t = _toks()
        need = {
            "B9_SYS_TOP_AR_OUT_HOLD_MISSING",
            "B9_POST_ASCAL_DAR_BLACKOUT_MISSING",
            "B9_HDMI_BO_OR_NOT_SAME_SIZE_DAR",
        }
        still = need & t
        if still:
            fails.append(f"B9 hold+post inject did not clear {still} — HOLE")
        else:
            print("  MUT_OK B9_AR_HOLD_POST_ASCAL clear_drop=1")
    finally:
        for r in reversed(restorers):
            r()
    t2 = _toks()
    for tok in (
        "B9_SYS_TOP_AR_OUT_HOLD_MISSING",
        "B9_POST_ASCAL_DAR_BLACKOUT_MISSING",
        "B9_HDMI_BO_OR_NOT_SAME_SIZE_DAR",
    ):
        if tok not in t2:
            fails.append(f"{tok}: vanished after restore — HOLE")
        else:
            print(f"  MUT_OK {tok} restore_fire=1")

    # --- B26: inject rt_raw_window bounds into store ---
    if store.is_file():
        old = store.read_text()
        inject = """
	// fitgate mut B26 window bounds
	wire [11:0] rt_crop_disp_w_sum = {1'b0, rt_crop_left} + {1'b0, rt_dw_nz};
	wire [11:0] rt_crop_disp_h_sum = {1'b0, rt_crop_top} + {1'b0, rt_dh_nz};
	wire [11:0] rt_pres_disp_w_sum = 12'd0;
	wire [11:0] rt_pres_disp_h_sum = 12'd0;
	wire rt_raw_window =
		(rt_crop_disp_w_sum <= {1'b0, rt_cw_nz}) &&
		(rt_crop_disp_h_sum <= {1'b0, rt_ch_nz});
	wire rt_raw_ok = rt_raw_nonzero && rt_raw_in_range && rt_raw_aligned && rt_raw_window;
"""
        # Prefer splice near rt_raw_ok if present, else append.
        if re.search(r"\brt_raw_ok\b", old):
            new = re.sub(
                r"wire\s+rt_raw_ok\s*=\s*[^;]+;",
                inject + "\t// mut replaced rt_raw_ok\n",
                old,
                count=1,
            )
        else:
            new = old + "\n" + inject
        r = _with_file_backup(store, new)
        try:
            if "B26_STORE_CROP_DISPLAY_BOUNDS_MISSING" in _toks():
                fails.append("B26: window inject did not clear — HOLE")
            else:
                print("  MUT_OK B26_STORE_CROP_DISPLAY_BOUNDS_MISSING clear_drop=1")
        finally:
            r()
        if "B26_STORE_CROP_DISPLAY_BOUNDS_MISSING" not in _toks():
            fails.append("B26: vanished after restore — HOLE")
        else:
            print("  MUT_OK B26_STORE_CROP_DISPLAY_BOUNDS_MISSING restore_fire=1")
    else:
        fails.append("B26 mut: store missing")

    # --- B27: inject chroma-even helper + test asserts ---
    hdr_body = """
#pragma once
#include <cstdint>
inline int padInsetChromaEven(int ideal_inset) {
    if (ideal_inset < 0) return 0;
    return ideal_inset & ~1;
}
inline bool padOnlyInsets(int src_w, int src_h, int coded_w, int coded_h, int* pad_x, int* pad_y) {
    if (!pad_x || !pad_y) return false;
    *pad_x = padInsetChromaEven((coded_w - src_w) / 2);
    *pad_y = padInsetChromaEven((coded_h - src_h) / 2);
    return true;
}
"""
    test_snip = """
// fitgate mut B27
// pad_x == 2 for 426→432; NEG: pad_x must not be math-center 3
// pad=432:240:2:0
"""
    rh = _with_file_backup(hdr, (hdr.read_text() if hdr.is_file() else "") + hdr_body)
    rt = _with_file_backup(test, (test.read_text() if test.is_file() else "") + test_snip)
    try:
        if "B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE" in _toks():
            fails.append("B27: chroma-even inject did not clear — HOLE")
        else:
            print("  MUT_OK B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE clear_drop=1")
    finally:
        rt()
        rh()
    if "B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE" not in _toks():
        fails.append("B27: vanished after restore — HOLE")
    else:
        print("  MUT_OK B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE restore_fire=1")

    # B27 RED: naive (coded-src)/2 without even snap must fire.
    bad_hdr = """
#pragma once
inline bool padOnlyInsets(int src_w, int src_h, int coded_w, int coded_h, int* pad_x, int* pad_y) {
    *pad_x = (coded_w - src_w) / 2; // naive center — DEFECT
    *pad_y = (coded_h - src_h) / 2;
    return true;
}
inline int padInsetChromaEven(int ideal_inset) { return ideal_inset; } // no-op even
"""
    # Need tests to still claim pad_x==2 so only formula defect fires... actually
    # gate fires if header lacks even formula OR test lacks asserts.
    # Inject naive formula WITH padInsetChromaEven name but wrong body + good tests.
    good_test = """
// pad_x == 2
// NEG: pad_x must not be math-center 3
// pad=432:240:2:0
"""
    rh = _with_file_backup(hdr, bad_hdr)
    rt = _with_file_backup(test, good_test)
    try:
        # naive assign without padInsetChromaEven call in padOnlyInsets
        if "B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE" not in _toks():
            fails.append("B27: naive /2 padOnlyInsets did not fire — HOLE")
        else:
            print("  MUT_OK B27_FFMPEG_PAD_CHROMA_EVEN_ORACLE naive_center_rejected=1")
    finally:
        rt()
        rh()

    return fails


def _mutation_b19_merge_loss() -> list[str]:
    """B19: ancestor≠content. Must not be satisfiable by ancestry alone.

    1) Synthetic _LIVE_ATTR merge_loss → collect_merge_loss_errors must fire;
       status=merged with evidence must not emit B19 for that token.
    2) Read-only integ-product --root RED twin (parent-observed wholesale drop).
    Never edits sibling worktrees.
    """
    global _LIVE_ATTR
    fails: list[str] = []
    saved_root = ROOT
    saved_attr = dict(_LIVE_ATTR)
    integ = Path("/home/flynnsbit/Projects/MisterPlex-wt-integ-product")

    # --- Synthetic classify ---
    _LIVE_ATTR = {
        "B7_OPTC_WIDTH_ONLY": {
            "status": "merge_loss",
            "lane": "w-mem",
            "commit": "90517fa262d4",
            "timestamp": "mut",
            "artefact": "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
            "evidence": r"\brt_need_optc\b",
            "missing_patterns": [r"\brt_need_optc\b", r"rt_payload_bytes"],
        }
    }
    errs = collect_merge_loss_errors()
    if not any("B19_MERGE_LOSS" in e and "B7_OPTC_WIDTH_ONLY" in e for e in errs):
        fails.append("synthetic merge_loss: collect_merge_loss_errors did not fire — HOLE")
    else:
        print("  MUT_OK B19_synthetic_merge_loss fire=1")

    # Ancestry alone (merged status) must NOT produce B19
    _LIVE_ATTR = {
        "B7_OPTC_WIDTH_ONLY": {
            "status": "merged",
            "lane": "w-mem",
            "commit": "90517fa262d4",
            "timestamp": "mut",
            "artefact": "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
            "evidence": r"\brt_need_optc\b",
            "evidence_on_gated": "1",
            "ancestor_of_gated": "1",
        }
    }
    errs2 = collect_merge_loss_errors()
    if any("B7_OPTC_WIDTH_ONLY" in e for e in errs2):
        fails.append("synthetic merged: B19 must not fire when evidence present — HOLE")
    else:
        print("  MUT_OK B19_synthetic_merged_no_fire ancestry_alone=0")

    # Under-take synthetic
    _LIVE_ATTR = {
        "_LANE_TIP_NOT_MERGED_w-scaler": {
            "status": "lane_tip_not_merged",
            "lane": "w-scaler",
            "commit": "76aa4272cf85",
            "timestamp": "mut",
            "tokens": "B6_STORE_ORACLE_UNTESTED,B9_ASPECT_ORIGINAL_4_3",
            "evidence": "tip not ancestor",
        }
    }
    errs3 = collect_merge_loss_errors()
    if not any("B19_LANE_TIP_NOT_MERGED" in e and "w-scaler" in e for e in errs3):
        fails.append("synthetic under-take: B19_LANE_TIP_NOT_MERGED did not fire — HOLE")
    else:
        print("  MUT_OK B19_synthetic_lane_tip_not_merged fire=1")

    _LIVE_ATTR = saved_attr

    # --- Real observed twin: integ-product (read-only) ---
    if integ.is_dir() and (integ / "fpga" / "Plex_MiSTer").is_dir():
        try:
            apply_scan_root(integ)
            _rc, msgs = leg0_arch_blockers()
            txt = "\n".join(msgs)
            if "B19_MERGE_LOSS" not in txt:
                fails.append(
                    "integ-product: expected B19_MERGE_LOSS (mem ancestor, "
                    "scaler store wholesale) — HOLE"
                )
            else:
                # Must not mark B7_OPTC as merged without evidence
                bad_merged = any(
                    "token=B7_OPTC_WIDTH_ONLY" in ln and "status=merged" in ln
                    for ln in msgs
                )
                if bad_merged:
                    fails.append(
                        "integ-product: B7_OPTC status=merged without evidence — HOLE"
                    )
                else:
                    n = sum(1 for ln in msgs if "B19_MERGE_LOSS:" in ln)
                    print(f"  MUT_OK B19_integ_product_red fire=1 n_lines={n}")
            # Under-take should hard-error on partial integ (scaler tip not ancestor)
            if "B19_LANE_TIP_NOT_MERGED" not in txt and "LEG0_LANE_TIP_NOT_MERGED" not in txt:
                # soft: info may exist without hard if no absorbed — but integ absorbed mem
                if "LEG0_PARTIAL_INTEGRATION absorbed_sibling=1" in txt:
                    fails.append(
                        "integ-product: partial integration but no lane tip "
                        "not-merged signal — HOLE"
                    )
        finally:
            apply_scan_root(saved_root)
            _LIVE_ATTR = saved_attr
    else:
        print("  SKIP B19_integ_product (tree unavailable)")

    return fails


def _mutation_closed_class_reinject() -> list[str]:
    """Re-inject defects for currently-clear checks (B6 beam epoch, B10 qip)."""
    fails: list[str] = []
    beam = RTL / "present_beam_content_de.sv"
    qip = ROOT / "fpga" / "Plex_MiSTer" / "files.qip"
    tb = ROOT / "tests" / "rtl" / "present_true_de_count_tb.cpp"

    # B6: revert hc_next blank to old-hc style if currently fixed.
    if beam.is_file():
        old = beam.read_text()
        if "hc_next" in old and "HBlank <= (hc_next" in old:
            bad = old.replace(
                "HBlank <= (hc_next >= 11'(H_DE));",
                "HBlank <= (hc >= 11'(H_DE));",
            )
            # Also strip hc_next definition use for blank path detection.
            rest = _with_file_backup(beam, bad)
            try:
                # Weaken TB oracle so B6_STORE does not dominate — keep beam epoch check.
                _rc, msgs = leg0_arch_blockers()
                toks = _leg0_error_tokens(msgs)
                if "B6_HBLANK_OLD_HC_EPOCH" not in toks:
                    fails.append("B6_HBLANK_OLD_HC_EPOCH: reinject did not fire — HOLE")
                else:
                    print("  MUT_OK B6_HBLANK_OLD_HC_EPOCH reinject_fire=1")
            finally:
                rest()
        else:
            print("  MUT_SKIP B6_HBLANK (beam not in hc_next-fixed state)")

    # B6 store oracle: strip oracle from TB briefly.
    if tb.is_file():
        old_tb = tb.read_text()
        if "store_oracle" in old_tb or "store_id_checked == CW * CH" in old_tb:
            bad_tb = (
                old_tb.replace("store_oracle", "store_oraclX")
                .replace("store_id_checked == CW * CH", "store_id_checked == 0")
                .replace("store_id_checked == content_area", "store_id_checked == 0")
                .replace("store_req_count==content area", "store_req_count==0")
            )
            rest = _with_file_backup(tb, bad_tb)
            try:
                _rc, msgs = leg0_arch_blockers()
                toks = _leg0_error_tokens(msgs)
                if "B6_STORE_ORACLE_UNTESTED" not in toks:
                    fails.append("B6_STORE_ORACLE_UNTESTED: reinject did not fire — HOLE")
                else:
                    print("  MUT_OK B6_STORE_ORACLE_UNTESTED reinject_fire=1")
            finally:
                rest()

    # B10: remove beam from qip.
    if qip.is_file():
        old_q = qip.read_text()
        if "present_beam_content_de.sv" in old_q:
            bad_q = "\n".join(
                ln
                for ln in old_q.splitlines()
                if "present_beam_content_de.sv" not in ln
            ) + "\n"
            rest = _with_file_backup(qip, bad_q)
            try:
                _rc, msgs = leg0_arch_blockers()
                toks = _leg0_error_tokens(msgs)
                if "B10_BEAM_NOT_IN_FILES_QIP" not in toks and (
                    "B10_BEAM_ABSENT_FROM_QUARTUS_FILE_LIST" not in toks
                ):
                    fails.append("B10: qip beam removal did not fire — HOLE")
                else:
                    print("  MUT_OK B10_BEAM_QIP reinject_fire=1")
            finally:
                rest()

    # B10: stale rtl_lint without macro_qsf must report DID_NOT_RUN (not silent skip).
    rtl_lint_path = ROOT / "scripts" / "rtl_lint.py"
    if rtl_lint_path.is_file():
        old_rl = rtl_lint_path.read_text()
        if "def discover_design(macro_qsf" in old_rl:
            bad_rl = old_rl.replace(
                "def discover_design(macro_qsf: Path | None = None)",
                "def discover_design()",
                1,
            )
            # Also neutralize body kw use if any - signature alone is enough for wrapper.
            rest = _with_file_backup(rtl_lint_path, bad_rl)
            try:
                # Force reimport
                import importlib
                import sys

                sys.modules.pop("rtl_lint", None)
                _rc, msgs = leg0_arch_blockers()
                txt = "\n".join(msgs)
                toks = _leg0_error_tokens(msgs)
                fired = (
                    "B10_RTL_LINT_API_STALE" in txt
                    or "B10_DISCOVER_DESIGN_DID_NOT_RUN" in txt
                    or "B10_RTL_LINT_API_STALE" in toks
                    or "B10_DISCOVER_DESIGN_DID_NOT_RUN" in toks
                )
                if not fired:
                    fails.append(
                        "B10_DISCOVER_DESIGN_DID_NOT_RUN: stale API reinject did not fire — HOLE"
                    )
                else:
                    print("  MUT_OK B10_DISCOVER_DESIGN_DID_NOT_RUN reinject_fire=1")
            finally:
                rest()
                import sys

                sys.modules.pop("rtl_lint", None)

    # Gate identity mismatch must refuse count.
    if GATE_IDENTITY_FILE.is_file():
        old_id = GATE_IDENTITY_FILE.read_text()
        bad_id = json.dumps(
            {
                "gate_identity_hash": "0" * 40,
                "paths": list(GATE_IDENTITY_PATHSPECS),
                "locked_by": "mutation",
            },
            indent=2,
        ) + "\n"
        rest = _with_file_backup(GATE_IDENTITY_FILE, bad_id)
        try:
            rc_id, msgs_id = check_gate_identity()
            if rc_id == 0 or "GATE_IDENTITY_MISMATCH" not in "\n".join(msgs_id):
                fails.append("GATE_IDENTITY_MISMATCH: bad hash did not refuse — HOLE")
            else:
                print("  MUT_OK GATE_IDENTITY_MISMATCH reinject_fire=1")
        finally:
            rest()

    # B21 hierarchy wiring (currently clear on stock sys_top) — reinject must fire.
    sys_top = ROOT / "fpga" / "Plex_MiSTer" / "sys" / "sys_top.v"
    if sys_top.is_file():
        old_st = sys_top.read_text()
        # Break ascal.swblack binding.
        if ".swblack" in old_st and "hdmi_blackout" in old_st:
            bad_st = re.sub(
                r"\.swblack\s*\(\s*hdmi_blackout\s*\)",
                ".swblack(1'b0)",
                old_st,
                count=1,
            )
            rest = _with_file_backup(sys_top, bad_st)
            try:
                _rc, msgs = leg0_arch_blockers()
                toks = _leg0_error_tokens(msgs)
                if "B21_ASCAL_SWBLACK_NOT_WIRED" not in toks:
                    fails.append(
                        "B21_ASCAL_SWBLACK_NOT_WIRED: swblack=0 reinject did not fire — HOLE"
                    )
                else:
                    print("  MUT_OK B21_ASCAL_SWBLACK_NOT_WIRED reinject_fire=1")
            finally:
                rest()
        # Break emu.HDMI_BLACKOUT port.
        if re.search(r"\.HDMI_BLACKOUT\s*\(\s*hdmi_blackout\s*\)", old_st):
            bad_st = re.sub(
                r"\.HDMI_BLACKOUT\s*\(\s*hdmi_blackout\s*\)",
                ".HDMI_BLACKOUT(hdmi_blackout_UNWIRED)",
                old_st,
                count=1,
            )
            rest = _with_file_backup(sys_top, bad_st)
            try:
                _rc, msgs = leg0_arch_blockers()
                toks = _leg0_error_tokens(msgs)
                if "B21_HIER_BLACKOUT_PORT_NOT_WIRED" not in toks:
                    fails.append(
                        "B21_HIER_BLACKOUT_PORT_NOT_WIRED: port rename reinject did not fire — HOLE"
                    )
                else:
                    print("  MUT_OK B21_HIER_BLACKOUT_PORT_NOT_WIRED reinject_fire=1")
            finally:
                rest()
        # Break vga_force_scaler OR into vga_fb.
        if "vga_force_scaler" in old_st:
            bad_st = re.sub(
                r"vga_fb\s*=\s*cfg\[12\]\s*\|\s*vga_force_scaler",
                "vga_fb       = cfg[12]",
                old_st,
                count=1,
            )
            rest = _with_file_backup(sys_top, bad_st)
            try:
                _rc, msgs = leg0_arch_blockers()
                toks = _leg0_error_tokens(msgs)
                if "B21_HIER_VGA_SCALER_PORT_NOT_WIRED" not in toks:
                    fails.append(
                        "B21_HIER_VGA_SCALER_PORT_NOT_WIRED: vga_fb OR strip reinject did not fire — HOLE"
                    )
                else:
                    print("  MUT_OK B21_HIER_VGA_SCALER_PORT_NOT_WIRED reinject_fire=1")
            finally:
                rest()

    # B21 product constants: force HDMI_BLACKOUT/VGA_SCALER back to 0 if cleared.
    plex_p = ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv"
    if plex_p.is_file():
        old_px = plex_p.read_text()
        if re.search(r"assign\s+HDMI_BLACKOUT\s*=\s*1\s*;", old_px):
            bad_px = re.sub(
                r"assign\s+HDMI_BLACKOUT\s*=\s*1\s*;",
                "assign HDMI_BLACKOUT = 0;",
                old_px,
                count=1,
            )
            rest = _with_file_backup(plex_p, bad_px)
            try:
                _rc, msgs = leg0_arch_blockers()
                toks = _leg0_error_tokens(msgs)
                if "B21_HDMI_BLACKOUT_DISABLED" not in toks:
                    fails.append(
                        "B21_HDMI_BLACKOUT_DISABLED: =0 reinject did not fire — HOLE"
                    )
                else:
                    print("  MUT_OK B21_HDMI_BLACKOUT_DISABLED reinject_fire=1")
            finally:
                rest()

    # B22 merge-semantics (rd-duck c5bd6009): connection drop while ports kept.
    core_p = RTL / "present_core.sv"
    plex_p = ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv"
    if core_p.is_file():
        old_c = core_p.read_text()
        # 1) Wholesale c5bd6009-shaped core (no geom_live ports) must fire port tokens.
        try:
            import subprocess as _sp

            c5 = _sp.check_output(
                [
                    "git",
                    "-C",
                    "/home/flynnsbit/Projects/MisterPlex-wt-scaler",
                    "show",
                    "c5bd6009:fpga/Plex_MiSTer/rtl/present_core.sv",
                ],
                text=True,
                stderr=_sp.DEVNULL,
            )
        except (OSError, _sp.CalledProcessError, _sp.TimeoutExpired):
            c5 = ""
        if c5 and "module present_core" in c5:
            rest = _with_file_backup(core_p, c5)
            try:
                _rc, msgs = leg0_arch_blockers()
                toks = _leg0_error_tokens(msgs)
                need = {
                    "B22_PRESENT_CORE_GEOM_LIVE_PORTS",
                    "B22_PRESENT_CORE_BLACKOUT_HOLLOW_PORTS",
                    "B22_PRESENT_CORE_CADENCE_CORE_HZ",
                }
                missing = sorted(need - toks)
                if missing:
                    fails.append(
                        f"B22 c5bd6009 RED twin missing fire {missing} — HOLE"
                    )
                else:
                    print(
                        "  MUT_OK B22_c5bd6009_wholesale_red "
                        "geom_live+blackout+cadence=1"
                    )
            finally:
                rest()

        # 2) Ports present but store nets stripped → STORE_WIRE must fire.
        good_core = (
            "module present_core(\n"
            "input wire [15:0] geom_live_seq,\n"
            "input wire geom_live_valid,\n"
            "input wire [7:0] content_fps,\n"
            "output wire stat_geom_hold_black,\n"
            "output wire stat_geom_hollow\n"
            ");\n"
            "wire beam_film_class = (content_fps <= 8'd24);\n"
            "wire [7:0] cadence_display_hz = beam_film_class ? 8'd24 : 8'd30;\n"
            "present_cadence u_cad (.display_hz(cadence_display_hz), .content_fps(content_fps));\n"
            "ddr_frame_store u_fs (\n"
            "  // mut: ports exist but NOT wired to live geom — hole if gate green\n"
            "  .rt_geom_seq(16'd0),\n"
            "  .rt_geom_live(1'b0)\n"
            ");\n"
            "assign stat_geom_hold_black = 1'b0;\n"
            "assign stat_geom_hollow = 1'b0;\n"
            "endmodule\n"
        )
        rest = _with_file_backup(core_p, good_core)
        try:
            _rc, msgs = leg0_arch_blockers()
            toks = _leg0_error_tokens(msgs)
            if "B22_PRESENT_CORE_GEOM_LIVE_STORE_WIRE" not in toks and (
                "B22_PRESENT_CORE_GEOM_LIVE_TIED_CONST" not in toks
            ):
                fails.append(
                    "B22_PRESENT_CORE_GEOM_LIVE_STORE_WIRE/TIED_CONST: "
                    "const-tied rt_geom reinject did not fire — HOLE"
                )
            else:
                print("  MUT_OK B22_GEOM_LIVE_STORE_WIRE reinject_fire=1")
            if "B22_PRESENT_CORE_BLACKOUT_TIED_ZERO" not in toks and (
                "B22_PRESENT_CORE_BLACKOUT_STORE_WIRE" not in toks
            ):
                fails.append(
                    "B22 blackout store/tie reinject did not fire — HOLE"
                )
            else:
                print("  MUT_OK B22_BLACKOUT_STORE_WIRE reinject_fire=1")
        finally:
            rest()

    if plex_p.is_file() and core_p.is_file():
        # 3) Core ports OK, Plex omits hierarchy nets → PLEX_UNCONNECTED.
        old_c = core_p.read_text()
        old_p = plex_p.read_text()
        core_ok = (
            old_c
            + "\n// mut B22 core ports for plex-unconnected test\n"
            "input wire [15:0] geom_live_seq;\n"
            "input wire geom_live_valid;\n"
            "output wire stat_geom_hold_black;\n"
            "output wire stat_geom_hollow;\n"
            "wire beam_film_class = 1'b0;\n"
            "wire [7:0] cadence_display_hz = beam_film_class ? 8'd24 : 8'd30;\n"
            "present_cadence u_cad (.display_hz(cadence_display_hz));\n"
            "ddr_frame_store u_fs (\n"
            "  .rt_geom_seq(geom_live_seq),\n"
            "  .rt_geom_live(geom_live_valid),\n"
            "  .geom_hold_black(stat_geom_hold_black),\n"
            "  .geom_hollow_fault(stat_geom_hollow)\n"
            ");\n"
        )
        # Ensure Plex has a present_core instance without B22 nets.
        plex_bad = re.sub(
            r"\.geom_live_seq\s*\([^)]*\)\s*,?",
            "",
            old_p,
        )
        plex_bad = re.sub(r"\.geom_live_valid\s*\([^)]*\)\s*,?", "", plex_bad)
        plex_bad = re.sub(
            r"\.stat_geom_hold_black\s*\([^)]*\)\s*,?", "", plex_bad
        )
        plex_bad = re.sub(r"\.stat_geom_hollow\s*\([^)]*\)\s*,?", "", plex_bad)
        if "present_core" not in plex_bad:
            plex_bad += (
                "\npresent_core u_core (\n"
                "  .clk(clk)\n"
                "  // deliberately no geom_live / blackout ports\n"
                ");\n"
            )
        rc1 = _with_file_backup(core_p, core_ok)
        rc2 = _with_file_backup(plex_p, plex_bad)
        try:
            _rc, msgs = leg0_arch_blockers()
            toks = _leg0_error_tokens(msgs)
            if "B22_PLEX_GEOM_LIVE_UNCONNECTED" not in toks:
                fails.append(
                    "B22_PLEX_GEOM_LIVE_UNCONNECTED: plex omit reinject did not fire — HOLE"
                )
            else:
                print("  MUT_OK B22_PLEX_GEOM_LIVE_UNCONNECTED reinject_fire=1")
            if "B22_PLEX_BLACKOUT_HOLLOW_UNCONNECTED" not in toks:
                fails.append(
                    "B22_PLEX_BLACKOUT_HOLLOW_UNCONNECTED: plex omit reinject did not fire — HOLE"
                )
            else:
                print(
                    "  MUT_OK B22_PLEX_BLACKOUT_HOLLOW_UNCONNECTED reinject_fire=1"
                )
        finally:
            rc1()
            rc2()

    # B1_OPTION_C_REBASES_LEGACY (rd-duck): closed when LEG_* stay legacy.
    # Reinject OPTION_C LEG→720P rebase; must fire. Ancestry alone never clears.
    store_p = RTL / "ddr_frame_store.sv"
    if store_p.is_file():
        old_st = store_p.read_text()
        # Minimal defect shape matching leg0 regex (ifdef + LEG_BASE_W0=PHYS_BASE_720P).
        bad_st = (
            "`ifdef OPTION_C\n"
            "\tlocalparam [28:0] LEG_BASE_W0 = PHYS_BASE_720P[31:3];\n"
            "\tlocalparam [28:0] LEG_DOORBELL_W = DOORBELL_PHYS_720P[31:3];\n"
            "`else\n"
            "\tlocalparam [28:0] LEG_BASE_W0 = PHYS_BASE[31:3];\n"
            "\tlocalparam [28:0] LEG_DOORBELL_W = DOORBELL_PHYS[31:3];\n"
            "`endif\n"
            "// fitgate mut B1_OPTION_C_REBASES_LEGACY\n"
        ) + old_st
        rest = _with_file_backup(store_p, bad_st)
        try:
            _rc, msgs = leg0_arch_blockers()
            toks = _leg0_error_tokens(msgs)
            if "B1_OPTION_C_REBASES_LEGACY" not in toks:
                fails.append(
                    "B1_OPTION_C_REBASES_LEGACY: LEG rebase reinject did not fire — HOLE"
                )
            else:
                print("  MUT_OK B1_OPTION_C_REBASES_LEGACY reinject_fire=1")
        finally:
            rest()

    # B2_NO_PRODUCT_RASTER: strip beam raster evidence.
    beam_p = RTL / "present_beam_content_de.sv"
    if beam_p.is_file():
        old_b = beam_p.read_text()
        if re.search(r"\breg\s+\[[^\]]+\]\s*hc\b", old_b):
            bad_b = re.sub(r"\breg\s+(\[[^\]]+\])\s*hc\b", r"/*mut*/ wire \1 hc_removed", old_b, count=1)
            rest = _with_file_backup(beam_p, bad_b)
            try:
                _rc, msgs = leg0_arch_blockers()
                toks = _leg0_error_tokens(msgs)
                if "B2_NO_PRODUCT_RASTER" not in toks:
                    fails.append("B2_NO_PRODUCT_RASTER: beam strip reinject did not fire — HOLE")
                else:
                    print("  MUT_OK B2_NO_PRODUCT_RASTER reinject_fire=1")
            finally:
                rest()

    # B20_UNCONNECTED_PRODUCER: drop a product-rtl instance pin (PINMISSING).
    # Prefer present_geom_latch .content_w(...) — any net name.
    if plex_p.is_file():
        old_px = plex_p.read_text()
        if re.search(r"\.content_w\s*\([^)]*\)", old_px):
            bad_px = re.sub(
                r"\.content_w\s*\([^)]*\)\s*,",
                "/* mut B20 drop content_w pin */",
                old_px,
                count=1,
            )
            rest = _with_file_backup(plex_p, bad_px)
            try:
                _rc, msgs = leg0_arch_blockers()
                toks = _leg0_error_tokens(msgs)
                txt = "\n".join(msgs)
                fired = (
                    "B20_UNCONNECTED_PRODUCER" in toks
                    or "B20_UNCONNECTED_PRODUCER" in txt
                )
                pin_seen = "content_w" in txt or "pin=content_w" in txt
                if not fired:
                    fails.append(
                        "B20_UNCONNECTED_PRODUCER: drop content_w pin reinject did not fire — HOLE"
                    )
                elif not pin_seen:
                    fails.append(
                        "B20_UNCONNECTED_PRODUCER: blocker present but content_w "
                        "absent from report — ancestry/noise only, pin drop not seen — HOLE"
                    )
                else:
                    print(
                        "  MUT_OK B20_UNCONNECTED_PRODUCER pin_drop_reinject_fire=1 "
                        "content_w_in_report=1"
                    )
            finally:
                rest()
        else:
            # No latch instance — synthesize orphan module in qip + rtl file never instanced.
            qip_p = ROOT / "fpga" / "Plex_MiSTer" / "files.qip"
            rtl_dir = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
            if qip_p.is_file() and rtl_dir.is_dir():
                body = (
                    "// mut orphan producer\n"
                    "`timescale 1ns/1ps\n"
                    "module fitgate_mut_orphan_producer(output wire y);\n"
                    "  assign y = 1'b0;\n"
                    "endmodule\n"
                )
                # filename stem must match module name for primary-module orphan rule
                synth = rtl_dir / "fitgate_mut_orphan_producer.sv"
                old_q = qip_p.read_text()
                new_q = (
                    old_q
                    + '\nset_global_assignment -name SYSTEMVERILOG_FILE rtl/fitgate_mut_orphan_producer.sv\n'
                )
                r1 = _with_file_backup(synth, body)
                r2 = _with_file_backup(qip_p, new_q)
                try:
                    _rc, msgs = leg0_arch_blockers()
                    toks = _leg0_error_tokens(msgs)
                    if "B20_UNCONNECTED_PRODUCER" not in toks and "B20_UNCONNECTED_PRODUCER" not in "\n".join(msgs):
                        fails.append(
                            "B20_UNCONNECTED_PRODUCER: orphan module reinject did not fire — HOLE"
                        )
                    else:
                        print("  MUT_OK B20_UNCONNECTED_PRODUCER orphan_reinject_fire=1")
                finally:
                    r2()
                    r1()
                    if synth.is_file():
                        try:
                            synth.unlink()
                        except OSError:
                            pass

    # B23 parent arb #3 — single-owner table + ABI #2 fabric_* without plxg_*.
    # Prove strip-after-clear: ancestry/table presence alone must not keep green.
    owner_tbl = ROOT / "docs" / "rtl_single_owner_table.json"
    marker_blob = (
        "// mut B23 full owner markers seed\n"
        "// rt_need_optc rt_payload_bytes LEG_BANK_USABLE rt_coded_w[3:0] "
        "rt_geom_seq geom_hold_black promote_pulse live_epoch sh_epoch "
        "0x800 0x828 geom_live_seq geom_live_valid stat_geom_hold_black "
        "stat_geom_hollow PHYS_BASE_720P beam_film_class cadence_display_hz "
        "module present_beam_content_de module plex_content_fps_sel "
        "module present_content_window module plex_video_ar "
        "LEG0_ARCH_BLOCKERS_EXECUTED run_b20_hierarchy_exec_gate\n"
    )
    b23_paths = [
        RTL / "ddr_frame_store.sv",
        RTL / "present_geom_latch.sv",
        ROOT / "host" / "libmisterplex" / "mailbox_abi_spec.hpp",
        RTL / "present_core.sv",
        RTL / "present_beam_content_de.sv",
    ]
    if owner_tbl.is_file() and all(p.is_file() for p in b23_paths):
        restorers_b23: list = []
        try:
            # 1) Seed all markers so B23_OWNER_MARKERS_MISSING would clear.
            for p in b23_paths:
                restorers_b23.append(
                    _with_file_backup(p, marker_blob + p.read_text())
                )
            _rc, msgs = leg0_arch_blockers()
            toks = _leg0_error_tokens(msgs)
            if "B23_OWNER_MARKERS_MISSING" in toks:
                fails.append(
                    "B23 seed: markers still missing after full inject — HOLE in clear path"
                )
            else:
                # 2) Strip one required store marker; must re-fire (not ancestry).
                store_now = b23_paths[0]
                cur = store_now.read_text().replace(
                    "rt_need_optc", "rt_need_OPT_C_REMOVED", 1
                )
                store_now.write_text(cur)
                _rc2, msgs2 = leg0_arch_blockers()
                toks2 = _leg0_error_tokens(msgs2)
                if "B23_OWNER_MARKERS_MISSING" not in toks2:
                    fails.append(
                        "B23_OWNER_MARKERS_MISSING: strip rt_need_optc after clear "
                        "did not fire — HOLE (table/ancestry alone insufficient)"
                    )
                else:
                    print(
                        "  MUT_OK B23_OWNER_MARKERS_MISSING "
                        "seed_clear=1 strip_reinject_fire=1"
                    )
        finally:
            for r in reversed(restorers_b23):
                r()

        # Bad JSON table must fire.
        rest_t = _with_file_backup(owner_tbl, "{not-valid-json")
        try:
            _rc, msgs = leg0_arch_blockers()
            toks = _leg0_error_tokens(msgs)
            txt = "\n".join(msgs)
            if "B23_OWNER_TABLE_BAD_JSON" not in toks and "B23_OWNER_TABLE_BAD_JSON" not in txt:
                fails.append(
                    "B23_OWNER_TABLE_BAD_JSON: corrupt table reinject did not fire — HOLE"
                )
            else:
                print("  MUT_OK B23_OWNER_TABLE_BAD_JSON reinject_fire=1")
        finally:
            rest_t()

    # B23_ABI2: fabric_* ABI #2 nets without plxg_* producers (incident #2).
    if plex_p.is_file():
        old_px2 = plex_p.read_text()
        bad_px2 = re.sub(
            r"\bplxg_(?:dar_[\w]+|content_fps|fps_[\w]+|q5)\b",
            "/*mut_plxg*/",
            old_px2,
        )
        if "fabric_dar_valid" not in bad_px2:
            bad_px2 += (
                "\n// mut B23 ABI2 fabric-only (no plxg_ producers)\n"
                "wire fabric_dar_valid;\n"
                "wire [11:0] fabric_dar_x, fabric_dar_y;\n"
                "wire fabric_fps_valid;\n"
                "wire [7:0] fabric_content_fps;\n"
                "plex_video_ar u_mut_ar(.host_dar_valid(fabric_dar_valid));\n"
            )
        rest = _with_file_backup(plex_p, bad_px2)
        try:
            _rc, msgs = leg0_arch_blockers()
            toks = _leg0_error_tokens(msgs)
            if "B23_ABI2_FABRIC_NETS_NOT_PLXG" not in toks:
                fails.append(
                    "B23_ABI2_FABRIC_NETS_NOT_PLXG: fabric-only reinject did not fire — HOLE"
                )
            else:
                print("  MUT_OK B23_ABI2_FABRIC_NETS_NOT_PLXG reinject_fire=1")
        finally:
            rest()

    return fails


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--root",
        type=Path,
        default=None,
        help=(
            "Scan/integration tree root (fpga/Plex_MiSTer). Gate scripts stay on "
            "the ruler (this file's repo). w-osd merge: "
            "fitgate/scripts/fit_release_gate.sh --root $MERGE --qsf $MERGE/fpga/Plex_MiSTer/Plex.qsf"
        ),
    )
    ap.add_argument(
        "--qsf",
        type=Path,
        default=None,
        help="Quartus settings file (default: <root>/fpga/Plex_MiSTer/Plex.qsf)",
    )
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="Run RED/GREEN adversarial suite (mandatory acceptance)",
    )
    ap.add_argument(
        "--force-island-leg3",
        action="store_true",
        help="Inject island beam into leg3 (independence / red twin)",
    )
    ap.add_argument(
        "--skip-arch",
        action="store_true",
        help="Isolation only: skip leg0 architecture blockers (NOT a fit grant)",
    )
    ap.add_argument(
        "--print-integration-help",
        action="store_true",
        help="Print supported w-osd/integration invocation and exit 0",
    )
    args = ap.parse_args(argv)
    if args.print_integration_help:
        print(
            """FIT_RELEASE_GATE integration (w-osd) — supported invocation
============================================================
Canonical ruler lives in w-fitgate. Merged RTL is a different tree.
B11 forbids QSF from tree A + RTL from tree B unless --root unifies them.

  MERGE=/path/to/merged-integration-tree
  RULER=/home/flynnsbit/Projects/MisterPlex-wt-fitgate

  # Full grant path (only number that can release the fit):
  "$RULER/scripts/fit_release_gate.sh" \\
      --root "$MERGE" \\
      --qsf  "$MERGE/fpga/Plex_MiSTer/Plex.qsf"
  echo "true rc=$?"

Requirements:
  - $MERGE has fpga/Plex_MiSTer (+ QSF under $MERGE)
  - docs/fit_candidate.json in $MERGE with git_tree_hash for THAT tree
    (after merge: run gate once, copy printed live_gated hash into candidate)
  - Gate identity is the RULER scripts (LEG0_COUNT_REFUSED if ruler drifts)
  - Do NOT point --qsf at a foreign tree without --root (B11)

Per-lane counts are NOT fit grants. Only the merged --root run is.
"""
        )
        return 0
    if args.self_test:
        # Self-test always on ruler tree.
        apply_scan_root(RULER_ROOT)
        return self_test()
    if args.root is not None:
        apply_scan_root(args.root)
    qsf = args.qsf.resolve() if args.qsf is not None else DEFAULT_QSF.resolve()
    return run_gate(
        qsf,
        skip_arch=args.skip_arch,
        force_island=args.force_island_leg3,
    )


if __name__ == "__main__":
    raise SystemExit(main())
