#!/usr/bin/env python3
"""Attack the pre-fit hierarchy/A&S parser without running Quartus."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


DEFAULT_ROOT = Path("/home/flynnsbit/Projects/mp-wt-integ")
DEFAULT_FIT = DEFAULT_ROOT / "fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.fit.rpt"
DEFAULT_LOG = DEFAULT_ROOT / "fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/compile.log"


def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
    p = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return p.returncode, p.stdout


def git(root: Path, *args: str) -> str:
    rc, out = run(["git", "--no-pager", *args], root)
    return out.strip() if rc == 0 else f"UNKNOWN(rc={rc})"


def split_row(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip(";").split(";")]


def fit_full_paths(path: Path, entity: str) -> list[str]:
    rows: list[str] = []
    header: list[str] | None = None
    for line in path.read_text(errors="ignore").splitlines():
        if "Compilation Hierarchy Node" in line and "Full Hierarchy Name" in line:
            header = [re.sub(r"\s+", " ", c.strip()) for c in split_row(line)]
            continue
        if not header or not line.lstrip().startswith(";"):
            continue
        cells = split_row(line)
        if len(cells) != len(header) or not cells or not cells[0].startswith("|"):
            continue
        data = dict(zip(header, cells))
        if data.get("Entity Name", "") == entity:
            rows.append(data.get("Full Hierarchy Name", ""))
    return rows


def print_selected(prefix: str, out: str) -> None:
    for line in out.splitlines():
        if (
            line.startswith("Scope:")
            or line.startswith("required modules:")
            or line.startswith("PRESENT ")
            or line.startswith("ABSENT ")
            or line.startswith("  MASKED ")
            or line.startswith("    elaborated_as:")
            or line.startswith("PREFIT_HIERARCHY_")
        ):
            print(f"{prefix}{line}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--integ-root", type=Path, default=DEFAULT_ROOT)
    ap.add_argument("--fit-rpt", type=Path, default=DEFAULT_FIT)
    ap.add_argument("--compile-log", type=Path, default=DEFAULT_LOG)
    args = ap.parse_args()

    root = args.integ_root
    checker = root / "scripts/check_map_hierarchy.py"
    print(f"BRANCH {git(root, 'rev-parse', '--abbrev-ref', 'HEAD')}")
    print(f"COMMIT {git(root, 'rev-parse', '--short', 'HEAD')}")
    print(f"CHECKER {checker}")
    print(f"REPORT {args.fit_rpt}")

    cases = [
        (
            "direct_stub_child_control_red",
            ["--require", "h264_dpb_one_ref", "--forbid-only-under", "decode_stub"],
            "TRUE_MASKED: direct child only under decode_stub",
        ),
        (
            "nested_stub_child_false_green",
            ["--require", "h264_dpb_i420_addr", "--forbid-only-under", "decode_stub"],
            "TRUE_MASKED: nested descendant only under decode_stub",
        ),
        (
            "elab_summary_parent_masks_stub_ancestor",
            [
                "--elab-log",
                str(args.compile_log),
                "--require",
                "h264_inter_mc_16x16",
            ],
            "ABSENT: elaborated only beneath decode_stub, then optimized away",
        ),
    ]

    for name, extra, truth in cases:
        rc, out = run(["python3", str(checker), str(args.fit_rpt), *extra], root)
        print(f"CASE {name} rc={rc} truth={truth}")
        print_selected("  ", out)
        req = extra[extra.index("--require") + 1]
        paths = fit_full_paths(args.fit_rpt, req)
        if paths:
            for p in paths[:3]:
                print(f"  independent_fit_path={p}")
        elif name != "elab_summary_parent_masks_stub_ancestor":
            print("  independent_fit_path=<none>")

    scratch = Path(__file__).resolve().parents[1] / "build/w_audit_prefit_elab_attack"
    scratch.mkdir(parents=True, exist_ok=True)
    fake = scratch / "fake_unbounded_map.rpt"
    fake.write_text(
        "Resource Utilization by Entity\n"
        "; table header that is skipped ;\n"
        ";    |emu:emu| ; real top-ish row ;\n"
        "Later unrelated table, not an entity resource table\n"
        ";    |h264_decode_core:not_entity| ; this is not an entity-resource row ;\n"
    )
    try:
        rc, out = run(["python3", str(checker), str(fake), "--require", "h264_decode_core"], root)
        print(f"CASE unbounded_trailing_table_false_green rc={rc} truth=NOT_ENTITY_ROW path={fake}")
        print_selected("  ", out)
    finally:
        if fake.exists():
            fake.unlink()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
