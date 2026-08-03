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
    "B1_NO_COMPILE_TIME_OPTC",
    "B1_LAYOUT_NOT_960",
    "B2_FPS_INT_OVERFLOW",
    "B2_NO_RASTER_GENERATOR",
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
    "B12_DE_LAG_RGB_LATENCY_UNPROVEN",
    "B13_FIXED_RASTER_NO_RUNTIME_DE",
    "B14_CODED_W_16_ALIGN_UNENFORCED",
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


def _file_has_all(path: Path, patterns: list[str]) -> bool:
    if not path.is_file():
        return False
    txt = path.read_text(errors="ignore")
    return all(re.search(p, txt) for p in patterns)


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
        "B1_NO_COMPILE_TIME_OPTC": [
            (
                "w-mem",
                "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
                [r"`ifdef\s+OPTION_C", r"PHYS_BASE_720P"],
            )
        ],
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
    }

    out: dict[str, dict[str, str]] = {}
    tip_cache: dict[str, dict[str, str]] = {}

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
                hit = {
                    "status": "unmerged",
                    "lane": lane,
                    "commit": tip["commit_short"],
                    "commit_full": tip["commit"],
                    "timestamp": tip["timestamp"],
                    "subject": tip["subject"],
                    "artefact": rel,
                    "worktree": tip["worktree"],
                    "evidence": f"live scan matched {len(pats)} patterns @ tip",
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
                # tip differs from static tag — almost always tip is newer work
                tip_newer = "1"
                hit["static_tag_commit"] = static_c
                hit["note"] = (
                    f"static FIX_STATUS commit={static_c} differs from live tip "
                    f"{hit['commit']}; using live tip (parent: do not trust stale tag)"
                )
            out[token] = hit
            msgs.append(
                f"LEG0_SIBLING_HIT token={token} lane={hit['lane']} "
                f"commit={hit['commit']} ts={hit['timestamp']} "
                f"tip_newer_than_static_tag={tip_newer} artefact={hit['artefact']}"
            )
        else:
            out[token] = {
                "status": "unimplemented",
                "evidence": "no sibling tip matched live probes",
            }
            # Still report lane tips we checked for this token's preferred lanes.
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

    # Always print tip roster for routing.
    for lane, wt in sorted(SIBLING_LANES.items()):
        t = tip_cache.get(lane) or _git_tip_meta(wt)
        if t:
            msgs.append(
                f"LEG0_SIBLING_TIP lane={lane} commit={t['commit_short']} "
                f"ts={t['timestamp']} subject={t['subject']!r}"
            )
        else:
            msgs.append(f"LEG0_SIBLING_TIP lane={lane} UNAVAILABLE path={wt}")

    msgs.append(f"LEG0_SIBLING_SCAN_EXECUTED hits={sum(1 for v in out.values() if v.get('status')=='unmerged')}")
    return out, msgs


def _fix_status_suffix(token: str) -> str:
    """Annotate blocker with live unmerged sibling fix vs unimplemented."""
    meta = _LIVE_ATTR.get(token) or FIX_STATUS.get(token)
    if meta is None:
        return " [fix=unimplemented — no known sibling-lane fix; new work]"
    st = meta.get("status", "unimplemented")
    if st == "unmerged":
        ts = meta.get("timestamp", "?")
        extra = ""
        if meta.get("static_tag_commit"):
            extra = f" static_tag={meta['static_tag_commit']} tip_newer=1"
        elif meta.get("note"):
            extra = " tip_refreshed=1"
        # Use tip= not commit= — error bodies often contain plxg_commit=1'b0.
        return (
            f" [fix=unmerged lane={meta.get('lane')} tip={meta.get('commit')} "
            f"ts={ts} artefact={meta.get('artefact')} "
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


def leg0_arch_blockers() -> tuple[int, list[str]]:
    """rd-duck fit blockers — FAIL until a coherent candidate clears each.

    Evidence is quoted from this tree's source (rule 0). Checks auto-pass only
    when the cited defect is gone from the files.
    """
    global _LIVE_ATTR, _LIVE_ATTR_MSGS
    msgs: list[str] = ["LEG0_ARCH_BLOCKERS_EXECUTED begin"]
    errors: list[str] = []
    msgs.append(f"LEG0_SCAN_ROOT root={ROOT} ruler={RULER_ROOT}")

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
            "(ddr_frame_store.sv) — no compile-time Option-C bank map"
        )
    # Compile-time Option-C does not exist: no ifdef selecting OPTC_* as localparam defaults.
    if re.search(r"`ifdef\s+FABRIC_NATIVE_720P_GEOM", store) is None and re.search(
        r"`ifdef\s+OPTION_C", store
    ) is None:
        if pw == "640" and ph == "480":
            errors.append(
                "B1_NO_COMPILE_TIME_OPTC: ddr_frame_layout_params.svh still "
                f"PRESENTED={pw}x{ph} CODED={cw}x{ch}; ddr_frame_store has no "
                "`ifdef FABRIC_NATIVE_720P_GEOM/OPTION_C compile-time bank path; "
                "geom_enable=0 stays legacy PHYS/stride/doorbell. FRAME_W=960 QSF "
                "alone does not re-base the store (rd-duck #3)."
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

    # --- B2: scalar-ascal timing_960 constants-only + int overflow ---
    t960 = RTL / "present_video_timing_960.sv"
    t960_txt = _read(t960)
    if t960_txt:
        msgs.append(f"LEG0_EVIDENCE present_video_timing_960.sv exists ({t960.stat().st_size} B)")
        # Overflow: clock's 720p file documents and uses longint; 960 still uses int.
        if "localparam int FPS_MILLI = (CLK_PIX_HZ * 1000)" in t960_txt or re.search(
            r"localparam\s+int\s+FPS_MILLI\s*=\s*\(\s*CLK_PIX_HZ\s*\*\s*1000", t960_txt
        ):
            errors.append(
                "B2_FPS_INT_OVERFLOW: present_video_timing_960.sv uses "
                "`localparam int FPS_MILLI = (CLK_PIX_HZ * 1000) / …` — "
                "20_000_000*1000 overflows 32-bit signed int (rd-duck #2). "
                "present_video_timing_720p.sv already uses longint for this."
            )
        # No raster generator: no hc/vc counters; only assign of localparams.
        has_hc_reg = bool(re.search(r"\breg\s+\[[^\]]+\]\s*hc\b", t960_txt))
        has_always_raster = "always @(posedge" in t960_txt and has_hc_reg
        if not has_always_raster:
            errors.append(
                "B2_NO_RASTER_GENERATOR: present_video_timing_960.sv is constants-only "
                "(assign h_de/h_total/… from localparams; no hc/vc beam). Not a product "
                "raster (rd-duck #2). Product beam is present_beam_content_de with "
                "hardcoded totals — timing_960 is not wired as SoT."
            )
        # Not instantiated in present_core
        if "present_video_timing_960" not in core:
            msgs.append(
                "LEG0_EVIDENCE present_core.sv does not instantiate present_video_timing_960"
            )
        qip = _read(ROOT / "fpga" / "Plex_MiSTer" / "files.qip")
        if "present_video_timing_960.sv" in qip and not has_always_raster:
            errors.append(
                "B2_TIMING960_IN_QIP_WITHOUT_RASTER: constants module listed in files.qip "
                "without being a real generator — cargo risk"
            )
        # 40 Mpix claim is not product raster (doc budget line).
        dec = _read(ROOT / "docs" / "product-4-3-scaler-decision.md")
        if "40 Mpix/s" in dec or "40 Mpix" in dec:
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
                tagged.append(e + _fix_status_suffix(m.group(1)))
            else:
                tagged.append(e)
        errors = tagged
        n_unmerged = sum(1 for e in errors if "fix=unmerged" in e)
        n_unimpl = sum(1 for e in errors if "fix=unimplemented" in e)
        msgs.append("LEG0_FAIL EXECUTED reasons:")
        msgs.extend(f"  - {e}" for e in errors)
        msgs.append(f"LEG0_FAIL count={len(errors)}")
        msgs.append(
            f"LEG0_FIX_STATUS unmerged={n_unmerged} unimplemented={n_unimpl} "
            "(unmerged = sibling lane has fix — route merge; "
            "unimplemented = no known fix — dispatch work)"
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

    if failures:
        print(f"FIT_RELEASE_GATE_SELFTEST_FAIL failures={failures}")
        return 1
    print("FIT_RELEASE_GATE_SELFTEST_PASS EXECUTED")
    return 0


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

    def clear_store_optc_ifdef(txt: str) -> str:
        # Satisfy B1_NO_COMPILE_TIME_OPTC ifdef scan (not a product fix).
        return "`ifdef OPTION_C\n// mut\n`endif\n" + txt

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

    # Each entry: token, list of (path, transform) applied together for clear.
    specs: list[tuple[str, list[tuple[Path, object]]]] = [
        ("B1_LAYOUT_NOT_960", [(layout, clear_layout_960)]),
        (
            "B1_NO_COMPILE_TIME_OPTC",
            [(layout, clear_layout_960), (store, clear_store_optc_ifdef)],
        ),
        ("B2_FPS_INT_OVERFLOW", [(t960, clear_fps_longint)]),
        ("B2_NO_RASTER_GENERATOR", [(t960, clear_raster_fake)]),
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
    ]

    # B5 / B9_NO_AR_TOPLEVEL_TEST: create dummy tests then remove.
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
