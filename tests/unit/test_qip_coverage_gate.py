#!/usr/bin/env python3
"""Regression suite for the Quartus file-list coverage gate.

The gate was adopted from W-FIT-O5 (`ee2ed89`, `parent/integ-hour27`) on their
instruction "take it, don't rebuild it". Before adopting it, W-GATE-O5 attacked
it and measured five ways to make it report coverage it did not have. Each is
pinned here as a permanent red/green pair: every case mutates the Quartus
project, asserts the gate FAILS, restores, and asserts it PASSES again.

  A1 commented-out `set_global_assignment` counted as compiled
  A2 basename-only matching: an attic copy or a stale out-of-tree path counted
  A3 a file-list entry naming a file that is not on disk was never flagged
  A4 denominator was `rtl/*.sv` only -- .v and subdirectory RTL unaudited
  A5 the allowlist was a dict inside the script: a red could be turned green by
     appending a line, and an excuse never expired

Plus the blind spot W-FIT declared themselves: the gate must follow Plex.qsf's
`source` includes, or a file compiled from sys/sys.tcl reads as NOT_COMPILED.

Exit codes: 0 all cases pass, 1 a case failed, 77 nothing to test.
"""

import importlib.util
import io
import contextlib
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "check_qip_coverage.py"


def load_gate(root):
    """Load the gate rebased on a scratch repo root."""
    spec = importlib.util.spec_from_file_location("qip_gate_under_test", GATE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.ROOT = root
    mod.PROJECT_DIR = root / "fpga" / "Plex_MiSTer"
    mod.QSF = mod.PROJECT_DIR / "Plex.qsf"
    mod.QIP = mod.PROJECT_DIR / "files.qip"
    mod.RTL_DIR = mod.PROJECT_DIR / "rtl"
    mod.ALLOWED_ABSENT_MANIFEST = mod.RTL_DIR / "qip_allowed_absent.txt"
    return mod


def build_project(root, tracked, qip_lines, qsf_lines=None, allowed=None):
    """Create a synthetic Quartus project and return the gate bound to it."""
    rtl = root / "fpga" / "Plex_MiSTer" / "rtl"
    rtl.mkdir(parents=True, exist_ok=True)
    for rel in tracked:
        path = rtl / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"module {Path(rel).stem}; endmodule\n")
    proj = root / "fpga" / "Plex_MiSTer"
    (proj / "files.qip").write_text("\n".join(qip_lines) + "\n")
    if qsf_lines is None:
        qsf_lines = ["source files.qip"]
    (proj / "Plex.qsf").write_text("\n".join(qsf_lines) + "\n")
    if allowed is not None:
        (rtl / "qip_allowed_absent.txt").write_text("\n".join(allowed) + "\n")

    gate = load_gate(root)
    rels = ["fpga/Plex_MiSTer/rtl/" + r for r in tracked]
    gate.tracked_rtl = lambda: [Path(r) for r in rels]
    return gate


def run(gate, argv=None):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = gate.main(argv or [])
    return rc, buf.getvalue()


def qline(path):
    return f"set_global_assignment -name SYSTEMVERILOG_FILE {path}"


CASES = []


def case(fn):
    CASES.append(fn)
    return fn


@case
def case_a1_commented_assignment_is_not_coverage(tmp):
    """A1: `# set_global_assignment ... alpha.sv` must not count as compiled.

    The red arm keeps a second live assignment on purpose. A first draft
    commented out the only line, so the gate returned rc=2 REFUSED (Scope: 0)
    rather than rc=1 NOT_COMPILED -- a red for the wrong reason, which is the
    same vacuity class these gates exist to catch. Assert the diagnostic, not
    just a non-zero exit.
    """
    live = build_project(
        tmp / "a1g",
        ["alpha.sv", "keep.sv"],
        [qline("rtl/keep.sv"), qline("rtl/alpha.sv")],
    )
    rc, out = run(live)
    assert rc == 0, f"green expected, got {rc}\n{out}"

    dead = build_project(
        tmp / "a1r",
        ["alpha.sv", "keep.sv"],
        [qline("rtl/keep.sv"), "# " + qline("rtl/alpha.sv")],
    )
    rc, out = run(dead)
    assert rc == 1, f"commented line still counted as coverage, rc={rc}\n{out}"
    assert "NOT_COMPILED" in out and "alpha.sv" in out, out
    assert "REFUSED" not in out, f"red for the wrong reason (Scope: 0)\n{out}"
    return "commented assignment: green rc=0 / red rc=1 NOT_COMPILED"


@case
def case_a1_trailing_comment_does_not_hide_a_real_entry(tmp):
    """A1 inverse: a trailing comment must not delete a genuine assignment."""
    g = build_project(
        tmp / "a1t", ["alpha.sv"], [qline("rtl/alpha.sv") + "  # keep me"]
    )
    rc, out = run(g)
    assert rc == 0, f"trailing comment wrongly voided a real entry\n{out}"
    return "trailing comment after a live assignment stays compiled"


@case
def case_a2_same_basename_elsewhere_is_not_coverage(tmp):
    """A2: an attic copy with the same leaf name must not satisfy coverage."""
    root = tmp / "a2"
    attic = root / "attic"
    attic.mkdir(parents=True)
    (attic / "alpha.sv").write_text("module alpha; endmodule\n")
    g = build_project(root, ["alpha.sv"], [qline("../../attic/alpha.sv")])
    rc, out = run(g)
    assert rc == 1, f"a foreign path with the same basename counted\n{out}"
    assert "NOT_COMPILED" in out, out

    g2 = build_project(tmp / "a2ok", ["alpha.sv"], [qline("rtl/alpha.sv")])
    rc2, out2 = run(g2)
    assert rc2 == 0, out2
    return "attic copy rejected rc=1; real rtl/ path accepted rc=0"


@case
def case_a3_entry_for_a_missing_file_is_flagged(tmp):
    """A3: a file list entry pointing at nothing must be a hard fail.

    The original counted it as coverage, so a typo'd path could satisfy a
    --require for a module that is not in the design at all.
    """
    g = build_project(
        tmp / "a3",
        ["alpha.sv"],
        [qline("rtl/alpha.sv"), qline("rtl/never_existed.sv")],
    )
    rc, out = run(g)
    assert rc == 1, f"dangling file list entry was accepted\n{out}"
    assert "QIP_ENTRY_MISSING_FILE" in out, out
    assert "never_existed.sv" in out, out

    g2 = build_project(tmp / "a3ok", ["alpha.sv"], [qline("rtl/alpha.sv")])
    rc2, out2 = run(g2)
    assert rc2 == 0, out2
    assert "QIP_ENTRY_MISSING_FILE" not in out2, out2
    return "dangling entry rc=1 QIP_ENTRY_MISSING_FILE; clean list rc=0"


@case
def case_a3_dangling_entry_cannot_satisfy_require(tmp):
    """A3 sharpened: --require must not be satisfied by a nonexistent file."""
    g = build_project(tmp / "a3r", ["alpha.sv"], [qline("rtl/ghost.sv")])
    rc, out = run(g, ["--require", "ghost"])
    assert rc == 1, f"--require satisfied by a file that is not on disk\n{out}"
    assert "REQUIRED_FILE_NOT_COMPILED" in out, out
    return "--require ghost rc=1 REQUIRED_FILE_NOT_COMPILED"


@case
def case_a4_verilog_and_subdirectory_rtl_are_audited(tmp):
    """A4: .v files and rtl/ subdirectories must be in the denominator."""
    g = build_project(
        tmp / "a4",
        ["alpha.sv", "legacy.v", "sub/deep.sv"],
        [qline("rtl/alpha.sv")],
    )
    rc, out = run(g)
    assert rc == 1, f".v and subdirectory RTL escaped the denominator\n{out}"
    assert "legacy.v" in out, out
    assert "sub/deep.sv" in out, out
    assert "3 tracked HDL files" in out, out
    return "denominator covers .v and rtl/sub/: 3 tracked, 2 NOT_COMPILED"


@case
def case_a5_allowlist_entry_needs_a_reason(tmp):
    """A5: a bare allowlist line is not an explanation."""
    g = build_project(
        tmp / "a5n",
        ["alpha.sv"],
        [],
        qsf_lines=[qline("rtl/dummy_present.sv")],
        allowed=["alpha.sv"],
    )
    # keep one live assignment so Scope is non-zero
    (g.PROJECT_DIR / "rtl" / "dummy_present.sv").write_text("module d; endmodule\n")
    rc, out = run(g)
    assert rc == 1, f"reasonless allowlist entry accepted\n{out}"
    assert "ALLOWED_ABSENT_NO_REASON" in out, out
    return "reasonless allowlist entry rc=1 ALLOWED_ABSENT_NO_REASON"


@case
def case_a5_allowlist_goes_stale_when_the_file_is_compiled(tmp):
    """A5: an excuse must expire once the defect it excused is fixed."""
    g = build_project(
        tmp / "a5s",
        ["alpha.sv"],
        [qline("rtl/alpha.sv")],
        allowed=["alpha.sv  # excuse that outlived the defect"],
    )
    rc, out = run(g)
    assert rc == 1, f"stale allowlist entry silently absorbed\n{out}"
    assert "STALE_ALLOWED_ABSENT" in out, out
    return "allowlist entry for a now-compiled file rc=1 STALE_ALLOWED_ABSENT"


@case
def case_a5_allowlist_goes_stale_when_the_file_is_deleted(tmp):
    """A5: an allowlist entry for an untracked file is unrecorded drift."""
    g = build_project(
        tmp / "a5d",
        ["alpha.sv"],
        [qline("rtl/alpha.sv")],
        allowed=["deleted_long_ago.sv  # was retired"],
    )
    rc, out = run(g)
    assert rc == 1, f"orphaned allowlist entry accepted\n{out}"
    assert "STALE_ALLOWED_ABSENT" in out and "deleted_long_ago.sv" in out, out
    return "allowlist entry for a vanished file rc=1 STALE_ALLOWED_ABSENT"


@case
def case_a5_valid_allowlist_entry_still_passes(tmp):
    """A5 green: a genuine, current exclusion must not fail the gate."""
    g = build_project(
        tmp / "a5ok",
        ["alpha.sv", "unused.sv"],
        [qline("rtl/alpha.sv")],
        allowed=["unused.sv  # never instantiated by the product"],
    )
    rc, out = run(g)
    assert rc == 0, f"a valid exclusion was rejected\n{out}"
    assert "ALLOWED_ABSENT" in out and "QIP_COVERAGE_OK" in out, out
    return "current, explained exclusion rc=0 QIP_COVERAGE_OK"


@case
def case_qsf_source_include_is_followed(tmp):
    """W-FIT's declared blind spot: a file compiled from a sourced list.

    Without include following, alpha.sv reads NOT_COMPILED even though Quartus
    compiles it -- a false red is as corrosive as a false green.
    """
    root = tmp / "inc"
    g = build_project(
        root,
        ["alpha.sv"],
        ["# files.qip is empty on purpose"],
        qsf_lines=["source sys/sys.tcl"],
    )
    sysdir = g.PROJECT_DIR / "sys"
    sysdir.mkdir(parents=True, exist_ok=True)
    (sysdir / "sys.tcl").write_text(qline("../rtl/alpha.sv") + "\n")
    rc, out = run(g)
    assert rc == 0, f"file sourced via sys.tcl read as NOT_COMPILED\n{out}"
    assert "sys/sys.tcl" in out, out
    return "Plex.qsf -> source sys/sys.tcl include followed, rc=0"


@case
def case_nested_qip_include_is_followed(tmp):
    """A generated .qip pulled in with QIP_FILE must be followed too."""
    root = tmp / "nest"
    g = build_project(
        root,
        ["alpha.sv"],
        ["set_global_assignment -name QIP_FILE rtl/gen.qip"],
    )
    (g.RTL_DIR / "gen.qip").write_text(qline("alpha.sv") + "\n")
    rc, out = run(g)
    assert rc == 0, f"nested QIP_FILE include not followed\n{out}"
    return "QIP_FILE nested include followed, rc=0"


@case
def case_empty_file_list_refuses_rather_than_passes(tmp):
    """Scope: 0 on either side must REFUSE (rc=2), never claim a PASS."""
    g = build_project(tmp / "ref", ["alpha.sv"], ["# nothing here"])
    rc, out = run(g)
    assert rc == 2, f"empty file list did not refuse, rc={rc}\n{out}"
    assert "REFUSED" in out and out.startswith("Scope:"), out
    return "empty Quartus file list rc=2 REFUSED"


@case
def case_sdc_and_rbf_assignments_are_not_counted_as_rtl(tmp):
    """Only source assignments are coverage; SDC/RBF lines are not."""
    g = build_project(
        tmp / "sdc",
        ["alpha.sv"],
        [
            "set_global_assignment -name SDC_FILE Plex.sdc",
            "set_global_assignment -name GENERATE_RBF_FILE ON",
            qline("rtl/alpha.sv"),
        ],
    )
    rc, out = run(g)
    assert rc == 0, out
    assert "Scope: 1 source assignments" in out, out
    return "SDC/RBF assignments excluded from Scope, rc=0"


def main():
    if not GATE.exists():
        print(f"Scope: 0 -- {GATE} not found")
        print("SKIP: nothing to test")
        return 77

    print(f"Scope: {len(CASES)} qip-coverage attack cases against {GATE.name}")
    failures = []
    with tempfile.TemporaryDirectory(prefix="qipgate-") as td:
        tmp = Path(td)
        for fn in CASES:
            try:
                detail = fn(tmp)
                print(f"  PASS {fn.__name__}: {detail}")
            except AssertionError as exc:
                print(f"  FAIL {fn.__name__}: {exc}")
                failures.append(fn.__name__)
            except Exception as exc:  # noqa: BLE001 - report, do not mask
                print(f"  FAIL {fn.__name__}: unexpected {type(exc).__name__}: {exc}")
                failures.append(fn.__name__)

    if failures:
        print(f"QIP_COVERAGE_REGRESSION_FAIL {len(failures)}/{len(CASES)}: " + ", ".join(failures))
        return 1
    print(f"QIP_COVERAGE_REGRESSION_OK cases={len(CASES)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
