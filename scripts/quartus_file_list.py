#!/usr/bin/env python3
"""Resolve the true set of source files Quartus compiles for a project.

Motivation (measured, 2026-07 W-OSD-O5)
---------------------------------------
The fleet standard now says "cross-check ``files.qip``: not in the Quartus file
list means not in the design".  The intent is right; reading ``files.qip`` is
not a correct implementation of it.  On this project ``files.qip`` holds 37
references, while the design actually compiles far more, because ``Plex.qsf``
pulls the MiSTer framework in through Tcl::

    Plex.qsf:  source sys/sys.tcl
    sys.tcl:   set_global_assignment -name QIP_FILE sys/sys.qip
    sys.qip:   set_global_assignment -name VERILOG_FILE \\
                   [file join $::quartus(qip_path) osd.v]

``osd.v`` -- the OSD compositor itself -- is therefore in the design but is
invisible to anything that only reads ``files.qip``.  A membership test against
``files.qip`` would report the entire ``sys/`` framework as "not in the design",
which is false, and would give a checker author the impression of completeness
it has not earned.

Safety property
---------------
The single most dangerous behaviour for a tool like this is to *silently drop*
a reference it did not understand: that produces a confident, wrong "not in the
design" (or a short file list that hides a real input).  So every reference that
cannot be resolved to an existing file on disk is emitted as ``UNRESOLVED`` and,
in ``--gate`` mode, is a hard failure.  Unknown means unknown, never absent.

This is deliberately *not* a Tcl interpreter.  It resolves the idioms this
project actually uses and refuses to guess at anything else.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SCOPE = (
    "Scope: resolves which source files a Quartus project compiles, by following "
    "'source' directives, QIP_FILE includes and the $::quartus(qip_path) idiom. "
    "It reads the project's build description only. It does NOT prove a fit ran, "
    "does NOT prove a module survived synthesis (use post-fit hierarchy for that), "
    "and does NOT prove a module is reachable from the top level."
)

# Assignment names that introduce a source file into the compile.
SOURCE_FILE_KINDS = {
    "SYSTEMVERILOG_FILE",
    "VERILOG_FILE",
    "VHDL_FILE",
    "QIP_FILE",
    "SDC_FILE",
    "SOURCE_FILE",
    "MIF_FILE",
    "HEX_FILE",
}

# Assignment names that end in _FILE but name an *output* or a script, not a
# compiled source. Listing them here keeps them out of the file set without
# them being counted as unresolved.
NON_SOURCE_FILE_KINDS = {
    "GENERATE_RBF_FILE",
    "OUTPUT_FILE",
    "PRE_FLOW_SCRIPT_FILE",
    "POST_FLOW_SCRIPT_FILE",
    "POST_MODULE_SCRIPT_FILE",
    # jtag.cdf is written by sys/build_id.tcl during the pre-flow; it is a
    # programming chain description, never a compiled source.
    "CDF_FILE",
    # IP component descriptions emitted alongside a .qip; not compiled.
    "MISC_FILE",
}

# Options such as -entity/-library/-section_id may precede -name. Requiring
# -name to follow set_global_assignment directly made this regex skip every
# entry in rtl/pll.qip *silently* - the exact drop-on-the-floor behaviour
# this module exists to prevent. Match -name wherever it appears.
ASSIGN_RE = re.compile(
    r"set_global_assignment\s+(?:.*?\s)?-name\s+(\S+)\s+(.*?)\s*$"
)
SOURCE_RE = re.compile(r"^\s*source\s+(\S+)\s*$")
QIP_PATH_JOIN_RE = re.compile(
    r"\[\s*file\s+join\s+\$::quartus\(qip_path\)\s+\"?([^\]\s\"]+)\"?\s*\]"
)
# [join [list $::quartus(qip_path) pll_q [regexp -inline {[0-9]+} $quartus(version)] .qip] {}]
QIP_VERSION_JOIN_RE = re.compile(
    r"\[\s*join\s+\[\s*list\s+\$::quartus\(qip_path\)\s+(\S+)\s+"
    r"\[\s*regexp\s+-inline\s+\{\[0-9\]\+\}\s+\$quartus\(version\)\s*\]\s+(\S+)\s*\]"
)


class Ref:
    """One file reference discovered in the build description."""

    def __init__(self, kind: str, raw: str, origin: Path, resolved: Path | None,
                 note: str = ""):
        self.kind = kind
        self.raw = raw
        self.origin = origin
        self.resolved = resolved
        self.note = note

    @property
    def unresolved(self) -> bool:
        return self.resolved is None


def _strip_comment(line: str) -> str:
    stripped = line.strip()
    if stripped.startswith("#"):
        return ""
    return stripped


def _candidate_paths(raw: str, project: Path, container: Path,
                     quartus_version: str) -> list[Path]:
    """Turn one raw Tcl-ish path expression into candidate filesystem paths."""
    qip_dir = container.parent

    m = QIP_VERSION_JOIN_RE.search(raw)
    if m:
        stem, suffix = m.group(1), m.group(2)
        return [qip_dir / f"{stem}{quartus_version}{suffix}"]

    m = QIP_PATH_JOIN_RE.search(raw)
    if m:
        return [qip_dir / m.group(1)]

    # Anything still carrying Tcl substitution we do not model is unresolvable;
    # returning [] makes it UNRESOLVED rather than silently dropped.
    if "$" in raw or "[" in raw:
        return []

    literal = raw.strip().strip('"').strip("{}")
    if not literal:
        return []
    # A path may be written relative to the project root or, inside a .qip,
    # relative to the .qip itself. Try both and let existence decide.
    return [project / literal, qip_dir / literal]


def _parse_file(path: Path, project: Path, quartus_version: str,
                refs: list[Ref], seen: set[Path]) -> None:
    real = path.resolve()
    if real in seen:
        return
    seen.add(real)
    if not path.is_file():
        return

    for line in path.read_text(errors="replace").splitlines():
        line = _strip_comment(line)
        if not line:
            continue

        m = SOURCE_RE.match(line)
        if m:
            raw = m.group(1)
            target = project / raw.strip('"')
            refs.append(Ref("SOURCE", raw, path, target if target.is_file() else None,
                            "tcl source directive"))
            if target.is_file():
                _parse_file(target, project, quartus_version, refs, seen)
            continue

        m = ASSIGN_RE.search(line)
        if not m:
            continue
        kind, rest = m.group(1), m.group(2).strip()
        if kind in NON_SOURCE_FILE_KINDS or not kind.endswith("_FILE"):
            continue
        if kind not in SOURCE_FILE_KINDS:
            # An unfamiliar *_FILE assignment: record it so it is visible rather
            # than assumed harmless.
            refs.append(Ref(kind, rest, path, None, "unrecognised _FILE assignment"))
            continue

        candidates = _candidate_paths(rest, project, path, quartus_version)
        found = next((c for c in candidates if c.is_file()), None)
        refs.append(Ref(kind, rest, path, found))
        if found is not None and kind == "QIP_FILE":
            _parse_file(found, project, quartus_version, refs, seen)


def resolve(project: Path, quartus_version: str = "17") -> list[Ref]:
    qsf = project / f"{project.name.split('_')[0]}.qsf"
    if not qsf.is_file():
        candidates = sorted(project.glob("*.qsf"))
        if len(candidates) != 1:
            raise SystemExit(
                f"cannot identify a single .qsf in {project} (found {len(candidates)})"
            )
        qsf = candidates[0]
    refs: list[Ref] = []
    _parse_file(qsf, project, quartus_version, refs, set())
    return refs


def compiled_files(refs: list[Ref], project: Path) -> set[str]:
    out = set()
    for r in refs:
        if r.resolved is None:
            continue
        try:
            out.add(r.resolved.resolve().relative_to(project.resolve()).as_posix())
        except ValueError:
            out.add(r.resolved.as_posix())
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=SCOPE)
    ap.add_argument("--project", default="fpga/Plex_MiSTer", type=Path)
    ap.add_argument("--quartus-version", default="17")
    ap.add_argument("--json", action="store_true", help="emit the file list as JSON")
    ap.add_argument("--list", action="store_true", help="print resolved files only")
    ap.add_argument(
        "--require",
        action="append",
        default=[],
        help="fail unless this file (project-relative) is compiled; repeatable",
    )
    ap.add_argument(
        "--gate",
        action="store_true",
        help="exit non-zero if any reference could not be resolved",
    )
    args = ap.parse_args(argv)

    project: Path = args.project
    if not project.is_dir():
        print(f"FAIL project directory not found: {project}", file=sys.stderr)
        return 2

    refs = resolve(project, args.quartus_version)
    files = compiled_files(refs, project)
    unresolved = [r for r in refs if r.unresolved]

    if args.json:
        print(json.dumps({
            "files": sorted(files),
            "unresolved": [
                {"kind": r.kind, "raw": r.raw,
                 "origin": r.origin.as_posix(), "note": r.note}
                for r in unresolved
            ],
        }, indent=2))
    elif args.list:
        for f in sorted(files):
            print(f)
    else:
        print(SCOPE)
        print(f"project={project} quartus_version={args.quartus_version}")
        print(f"resolved_source_files={len(files)}")
        print(f"unresolved_references={len(unresolved)}")
        for r in unresolved:
            print(f"  UNRESOLVED {r.kind} {r.raw!r} from {r.origin} {r.note}")

    rc = 0
    for want in args.require:
        if want in files:
            print(f"OK compiled: {want}")
        else:
            print(f"FAIL not in the Quartus file list: {want}")
            rc = 1

    if args.gate and not files:
        print(
            "FAIL --gate resolved zero source files; an empty file list is a broken "
            "parse, not a project with nothing in it",
            file=sys.stderr,
        )
        rc = 1

    if args.gate and unresolved:
        print(
            f"FAIL {len(unresolved)} file reference(s) could not be resolved; "
            "an unresolved reference must never be reported as absent",
            file=sys.stderr,
        )
        rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
