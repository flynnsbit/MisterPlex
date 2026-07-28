#!/usr/bin/env python3
"""Bind a Quartus report to the bitstream it actually describes.

There are 92 `*.fit.rpt` files and 99 `Plex.rbf` files on this host. Almost all
of them describe builds nobody is running. Every one of them parses cleanly, so
reading the wrong one is silent: the gate is correct about a build that does not
exist, which is this project's signature defect wearing a fit report.

The rule, from the parent: **an unbound report is `UNBOUND`, never a pass.**

Usage from a gate::

    import fit_report_binding as binding
    binding.add_binding_args(ap)
    ...
    verdict = binding.require_binding(args, args.fit_rpt)
    if verdict.rc:
        return verdict.rc

`require_binding` prints its own evidence line and never raises.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path

UNSCORED = 77
MISMATCH = 1

RBF_NAMES = ("Plex.rbf",)


@dataclass(frozen=True)
class Binding:
    rc: int
    verdict: str
    rbf: Path | None
    md5: str | None


def md5(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def add_binding_args(ap) -> None:
    ap.add_argument(
        "--expect-rbf-md5",
        metavar="MD5",
        help="md5 (or unique prefix) of the bitstream this report must describe; "
             "without it the report is UNBOUND and cannot support a pass",
    )
    ap.add_argument(
        "--rbf",
        type=Path,
        help="bitstream to bind against; defaults to Plex.rbf beside the report",
    )


def find_rbf(report: Path, explicit: Path | None) -> Path | None:
    if explicit is not None:
        return explicit if explicit.is_file() else None
    for name in RBF_NAMES:
        candidate = report.parent / name
        if candidate.is_file():
            return candidate
    return None


def require_binding(args, report: Path) -> Binding:
    """Print the binding evidence and return the rc a gate must honour."""
    expect = (getattr(args, "expect_rbf_md5", None) or "").strip().lower()
    rbf = find_rbf(Path(report), getattr(args, "rbf", None))

    if not expect:
        print(
            f"FIT_REPORT_BINDING UNBOUND report={report} rbf="
            f"{rbf if rbf else '<none>'} reason=no_--expect-rbf-md5 -- "
            "this report may describe a build nobody is running; an unbound "
            "report cannot support a pass"
        )
        return Binding(UNSCORED, "UNBOUND", rbf, None)

    if rbf is None:
        print(
            f"FIT_REPORT_BINDING UNBOUND report={report} rbf=<none> "
            "reason=no_bitstream_beside_report -- cannot prove which build this "
            "report describes"
        )
        return Binding(UNSCORED, "UNBOUND", None, None)

    actual = md5(rbf)
    if not actual.startswith(expect):
        print(
            f"FIT_REPORT_BINDING MISMATCH report={report} rbf={rbf} "
            f"rbf_md5={actual} expected={expect} -- this report describes a "
            "different bitstream than the one claimed"
        )
        return Binding(MISMATCH, "MISMATCH", rbf, actual)

    print(f"FIT_REPORT_BINDING BOUND report={report} rbf={rbf} rbf_md5={actual}")
    return Binding(0, "BOUND", rbf, actual)
