#!/usr/bin/env python3
"""Red/green for the A/B control-validity gate.

W-FIT-O5's refutation: `Plex.sdc` was published as netlist-neutral on the
strength of four fit slots agreeing, but all four carried the *same* SDC. The
comparison never varied the independent variable, so it showed fitter
determinism and nothing else.

Same family as `Scope: 0`. `Scope: 0` is "I compared nothing"; a vacuous
control is "I compared two copies of the same thing". Both produce a true
number about the wrong thing.

The last case is not synthetic: it runs against the real fit slots under
`mp-wt-integ/.../remote_out/`, where `wfit-hour27-sdc-a` and `-sdc-b` hold
byte-identical `Plex.rbf` (`fb4bad84`) and `wfit-hour27-a` holds `3b1e8435`.
If those artefacts are not on this machine the case reports zero anchors rather
than passing quietly -- an anchor that silently vanishes is the same defect one
level up.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "check_ab_control_validity.py"
SLOTS = Path("/home/flynnsbit/Projects/mp-wt-integ/fpga/Plex_MiSTer/remote_out")


def scratch():
    base = ROOT / "build" / "w-gate-o5-scratch"
    base.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(prefix="abctl-", dir=str(base))


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(GATE), *args],
                          capture_output=True, text=True)


def pair(base: Path, a_files: dict[str, str], b_files: dict[str, str]) -> tuple[Path, Path]:
    side_a, side_b = base / "a", base / "b"
    for side, files in ((side_a, a_files), (side_b, b_files)):
        side.mkdir(parents=True, exist_ok=True)
        for name, text in files.items():
            path = side / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
    return side_a, side_b


def case_identical_variable_is_vacuous() -> None:
    with scratch() as td:
        a, b = pair(Path(td),
                    {"Plex.sdc": "set_false_path\n", "Plex.rbf": "AAA"},
                    {"Plex.sdc": "set_false_path\n", "Plex.rbf": "AAA"})
        proc = run("--a", str(a), "--b", str(b), "--variable", "Plex.sdc")
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "VACUOUS_CONTROL" in proc.stderr, proc.stderr
        assert "VARIABLE IDENTICAL Plex.sdc" in proc.stdout, proc.stdout


def case_real_variation_is_controlled() -> None:
    with scratch() as td:
        a, b = pair(Path(td),
                    {"Plex.sdc": "set_false_path\n", "Plex.rbf": "AAA"},
                    {"Plex.sdc": "set_max_delay 50.0\n", "Plex.rbf": "BBB"})
        proc = run("--a", str(a), "--b", str(b), "--variable", "Plex.sdc",
                   "--outcome", "Plex.rbf")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "AB_CONTROL_OK" in proc.stdout, proc.stdout
        assert "OUTCOME DIFFERS Plex.rbf" in proc.stdout, proc.stdout


def case_confound_blocks_attribution() -> None:
    with scratch() as td:
        a, b = pair(Path(td),
                    {"Plex.sdc": "old\n", "rtl/x.sv": "module x; endmodule\n", "Plex.rbf": "A"},
                    {"Plex.sdc": "new\n", "rtl/x.sv": "module x; wire y; endmodule\n",
                     "Plex.rbf": "B"})
        proc = run("--a", str(a), "--b", str(b), "--variable", "Plex.sdc",
                   "--outcome", "Plex.rbf")
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "CONFOUNDED" in proc.stderr, proc.stderr
        assert "CONFOUND rtl/x.sv" in proc.stdout, proc.stdout


def case_vacuous_with_differing_outcome_names_an_undeclared_input() -> None:
    """Identical declared input, different result: something undeclared varied."""
    with scratch() as td:
        a, b = pair(Path(td),
                    {"Plex.sdc": "same\n", "Plex.rbf": "AAA"},
                    {"Plex.sdc": "same\n", "Plex.rbf": "BBB"})
        proc = run("--a", str(a), "--b", str(b), "--variable", "Plex.sdc",
                   "--outcome", "Plex.rbf")
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "nobody declared is varying" in proc.stderr, proc.stderr


def case_genuine_null_result_is_labelled() -> None:
    """The only shape that can support a neutrality claim."""
    with scratch() as td:
        a, b = pair(Path(td),
                    {"Plex.sdc": "old\n", "Plex.rbf": "SAME"},
                    {"Plex.sdc": "new\n", "Plex.rbf": "SAME"})
        proc = run("--a", str(a), "--b", str(b), "--variable", "Plex.sdc",
                   "--outcome", "Plex.rbf")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "genuine null result" in proc.stdout, proc.stdout


def case_unnamed_variable_is_refused() -> None:
    with scratch() as td:
        a, b = pair(Path(td), {"x": "1"}, {"x": "2"})
        proc = run("--a", str(a), "--b", str(b))
        assert proc.returncode == 2, proc.stdout + proc.stderr
        assert proc.stdout.splitlines()[0].startswith("Scope: 0"), proc.stdout
        # rc=2 alone is vacuous: three different REFUSED paths all exit 2.
        assert "REFUSED: name the independent variable" in proc.stderr, proc.stderr


def case_variable_matching_nothing_is_refused() -> None:
    with scratch() as td:
        a, b = pair(Path(td), {"x": "1"}, {"x": "2"})
        proc = run("--a", str(a), "--b", str(b), "--variable", "Plex.sdc")
        assert proc.returncode == 2, proc.stdout + proc.stderr
        assert "matches no file" in proc.stderr, proc.stderr


def case_no_common_files_is_refused() -> None:
    with scratch() as td:
        a, b = pair(Path(td), {"only_a": "1"}, {"only_b": "2"})
        proc = run("--a", str(a), "--b", str(b), "--variable", "*")
        assert proc.returncode == 2, proc.stdout + proc.stderr
        assert "nothing was actually compared" in proc.stderr, proc.stderr


def case_missing_side_is_unscored() -> None:
    with scratch() as td:
        a, _ = pair(Path(td), {"x": "1"}, {"x": "1"})
        proc = run("--a", str(a), "--b", str(Path(td) / "nope"), "--variable", "x")
        assert proc.returncode == 77, proc.stdout + proc.stderr
        assert proc.stdout.splitlines()[0].startswith("Scope: 0"), proc.stdout


def case_ignore_globs_are_applied() -> None:
    with scratch() as td:
        a, b = pair(Path(td),
                    {"Plex.sdc": "old\n", "compile.log": "start 10:00\n"},
                    {"Plex.sdc": "new\n", "compile.log": "start 11:00\n"})
        noisy = run("--a", str(a), "--b", str(b), "--variable", "Plex.sdc")
        assert noisy.returncode == 1, noisy.stdout
        quiet = run("--a", str(a), "--b", str(b), "--variable", "Plex.sdc",
                    "--ignore", "*.log")
        assert quiet.returncode == 0, quiet.stdout + quiet.stderr


def case_real_fit_slots_anchor() -> int:
    """Not synthetic: the slots that produced the refuted exoneration."""
    ignore = ["--ignore", "*.log", "--ignore", "*.tsv", "--ignore", "*.rpt",
              "--ignore", "summary.txt"]
    anchors = 0
    vacuous = SLOTS / "wfit-hour27-sdc-a", SLOTS / "wfit-hour27-sdc-b"
    if all(p.is_dir() for p in vacuous):
        proc = run("--a", str(vacuous[0]), "--b", str(vacuous[1]),
                   "--variable", "Plex.rbf", *ignore)
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "VACUOUS_CONTROL" in proc.stderr, proc.stderr
        assert "VARIABLE IDENTICAL Plex.rbf" in proc.stdout, proc.stdout
        anchors += 1
    if SLOTS.is_dir():
        # The parent's four "exoneration" slots must surface as one cluster with
        # nobody having named a variable.
        proc = run("--discover", str(SLOTS), "--ignore", "*.log", "--ignore", "*.tsv",
                   "--ignore", "*.rpt", "--ignore", "summary.txt")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert ("VACUOUS_CLUSTER members=4 slots=wfit-hour27-bdiag-a,wfit-hour27-bdiag-b,"
                "wfit-hour27-sdc-a,wfit-hour27-sdc-b") in proc.stdout, proc.stdout
    real = SLOTS / "wfit-hour27-a", SLOTS / "wfit-hour27-bdiag-b"
    if all(p.is_dir() for p in real):
        proc = run("--a", str(real[0]), "--b", str(real[1]),
                   "--variable", "Plex.rbf", *ignore)
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "VARIABLE DIFFERS Plex.rbf" in proc.stdout, proc.stdout
        anchors += 1
    return anchors


def case_discovery_finds_vacuity_without_being_told_what_to_look_for() -> None:
    """Naming the variable requires remembering to ask.  Discovery asks for everybody."""
    with scratch() as td:
        root = Path(td)
        for name, rbf in (("s1", "AAA"), ("s2", "AAA"), ("s3", "AAA"), ("s4", "BBB")):
            (root / name).mkdir(parents=True)
            (root / name / "Plex.rbf").write_text(rbf)
            (root / name / "compile.log").write_text(f"timing noise {name}\n")
        proc = run("--discover", str(root), "--ignore", "*.log")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "VACUOUS_CLUSTER members=3 slots=s1,s2,s3" in proc.stdout, proc.stdout
        assert "DISTINCT members=1 slots=s4" in proc.stdout, proc.stdout
        assert "vacuous_clusters=1" in proc.stdout, proc.stdout

        # Slots asserted to be distinct that are byte-identical are a hard fail.
        red = run("--discover", str(root), "--ignore", "*.log",
                  "--require-distinct", "s1", "--require-distinct", "s2")
        assert red.returncode == 1, red.stdout + red.stderr
        assert "s1==s2" in red.stderr, red.stderr
        green = run("--discover", str(root), "--ignore", "*.log",
                    "--require-distinct", "s1", "--require-distinct", "s4")
        assert green.returncode == 0, green.stdout + green.stderr
        assert "AB_DISTINCT_OK" in green.stdout, green.stdout
        absent = run("--discover", str(root), "--require-distinct", "nope")
        assert absent.returncode == 2, absent.stdout + absent.stderr
        assert "absent slots" in absent.stderr, absent.stderr


def case_discovery_compares_content_not_filenames() -> None:
    """Regression: the first implementation compared rel->Path maps.

    Those differ per slot by construction, so every slot came out DISTINCT and the
    vacuity detector reported a confident false green on the very cluster it was
    built to find.
    """
    with scratch() as td:
        root = Path(td)
        for name in ("x", "y"):
            (root / name).mkdir(parents=True)
            (root / name / "Plex.rbf").write_text("SAME")
        proc = run("--discover", str(root))
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "VACUOUS_CLUSTER members=2 slots=x,y" in proc.stdout, proc.stdout
        assert "classes=1" in proc.stdout, proc.stdout


def case_discovery_needs_two_slots() -> None:
    with scratch() as td:
        root = Path(td)
        (root / "only").mkdir(parents=True)
        (root / "only" / "Plex.rbf").write_text("A")
        proc = run("--discover", str(root))
        assert proc.returncode == 77, proc.stdout + proc.stderr
        assert "fewer than two slots" in proc.stderr, proc.stderr


def case_no_comparison_named_is_refused() -> None:
    proc = run("--variable", "Plex.sdc")
    assert proc.returncode == 2, proc.stdout + proc.stderr
    assert "give --a and --b, or --discover" in proc.stderr, proc.stderr


def main() -> int:
    cases = (
        case_identical_variable_is_vacuous,
        case_real_variation_is_controlled,
        case_confound_blocks_attribution,
        case_vacuous_with_differing_outcome_names_an_undeclared_input,
        case_genuine_null_result_is_labelled,
        case_unnamed_variable_is_refused,
        case_variable_matching_nothing_is_refused,
        case_no_common_files_is_refused,
        case_missing_side_is_unscored,
        case_ignore_globs_are_applied,
        case_discovery_finds_vacuity_without_being_told_what_to_look_for,
        case_discovery_compares_content_not_filenames,
        case_discovery_needs_two_slots,
        case_no_comparison_named_is_refused,
    )
    available = sum(
        1 for a, b in (("wfit-hour27-sdc-a", "wfit-hour27-sdc-b"),
                       ("wfit-hour27-a", "wfit-hour27-bdiag-b"))
        if (SLOTS / a).is_dir() and (SLOTS / b).is_dir()
    )
    print(f"Scope: ab_control_cases={len(cases)} real_fit_slot_anchors={available}/2")
    for case in cases:
        case()
    anchors = case_real_fit_slots_anchor()
    assert anchors == available, (anchors, available)
    print(f"AB_CONTROL_GATE_TEST_OK cases={len(cases)} real_anchors={anchors}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
