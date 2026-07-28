#!/usr/bin/env python3
"""Cross-check tracked RTL against the Quartus file list.

Parent ruling (revised reachability standard, item 3): "Cross-check files.qip.
Not in the Quartus file list = not in the design, whatever the graph says."

A module can pass every source-level reachability check and still be absent from
the bitstream because its file was never handed to Quartus. This gate closes
that hole. It is a *file-list* oracle only: it proves a file is compiled, not
that the module inside it is instantiated. Pair it with both reachability
directions (subtree and trunk) and with `make post-fit-hierarchy`.

Adopted from W-FIT-O5's `ee2ed89` on `parent/integ-hour27` (W-FIT: "take it,
don't rebuild it"). The exit codes, output tags and `--require` semantics are
theirs and are preserved. W-GATE-O5 hardened five measured false-green vectors
in the original -- see docs/test-decode-product-presence-audit.md section 14:

  A1 a commented-out `set_global_assignment` line counted as compiled
  A2 basename matching: any path with the same leaf counted, including an
     attic copy or a stale path pointing outside rtl/
  A3 a .qip entry naming a file that does not exist on disk was not flagged
  A4 only `rtl/*.sv` was in the denominator: .v/.vhd and subdirectory RTL
     were invisible, so 4 tracked product files were never audited
  A5 ALLOWED_ABSENT was a hand-edited dict inside the script -- a red could be
     turned green by appending a line, and a stale excuse never expired

and closed W-FIT's own declared blind spot: the gate now starts at `Plex.qsf`
and follows `source` / QIP_FILE includes, so a file handed to Quartus from
sys/sys.tcl or a generated .qip is no longer a false NOT_COMPILED.

Exit codes:
  0  all tracked product RTL is compiled (and every --require is present)
  1  at least one product RTL file is tracked but not compiled, a file list
     entry points at a missing file, or the allowlist has gone stale
  2  refusal: Scope: 0 on either side -- a PASS cannot be claimed
 77  skip (the Quartus project files are absent)
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = ROOT / "fpga" / "Plex_MiSTer"
QSF = PROJECT_DIR / "Plex.qsf"
QIP = PROJECT_DIR / "files.qip"
RTL_DIR = PROJECT_DIR / "rtl"
ALLOWED_ABSENT_MANIFEST = RTL_DIR / "qip_allowed_absent.txt"

HDL_SUFFIXES = (".sv", ".v", ".vhd", ".vhdl")

# Quartus assignments that hand a *source* file to the compiler. SDC/RBF/etc.
# are deliberately excluded: they are not RTL.
# Quartus allows options such as `-library "pll"` or `-entity "x"` before
# -name. rtl/pll.qip uses exactly that form, and requiring -name to follow
# set_global_assignment immediately made four genuinely compiled files read as
# absent -- a false NOT_COMPILED, which trains people to write allowlist
# entries instead of fixing the file list.
_OPTS = r"(?:-\w+\s+(?:\"[^\"]*\"|\S+)\s+)*"
SOURCE_ASSIGNMENT = re.compile(
    r"set_global_assignment\s+" + _OPTS + r"-name\s+"
    r"(SYSTEMVERILOG_FILE|VERILOG_FILE|VHDL_FILE|AHDL_FILE)\s+(.+?)\s*$",
    re.I,
)
QIP_ASSIGNMENT = re.compile(
    r"set_global_assignment\s+" + _OPTS + r"-name\s+QIP_FILE\s+(.+?)\s*$", re.I
)
# Plex.qsf pulls files.qip and the MiSTer sys lists in with Tcl `source`.
SOURCE_DIRECTIVE = re.compile(r"^\s*source\s+(.+?)\s*$")

MAX_INCLUDE_DEPTH = 8

# `sys/sys.qip` writes its paths as Tcl expressions. Quartus defines
# $::quartus(qip_path) as the directory holding the .qip being read, so the
# common `[file join $::quartus(qip_path) name.v]` form is statically
# resolvable. The MiSTer framework also builds a version-dependent name with
# `[join [list $::quartus(qip_path) pll_q [regexp ...] .qip] {}]`, which is not
# -- for that one the literal fragments are globbed. Anything still containing
# a substitution is reported UNEVALUATED_TCL_PATH and counted, never guessed.
TCL_FILE_JOIN = re.compile(
    r"^\[\s*file\s+join\s+\$::quartus\(qip_path\)\s+(.+?)\s*\]$"
)
TCL_JOIN_LIST = re.compile(
    r"^\[\s*join\s+\[\s*list\s+\$::quartus\(qip_path\)\s+(.*?)\s*\]\s*\{\}\s*\]$"
)


def resolve_tcl_path(raw, qip_dir):
    """Resolve a Quartus Tcl path expression.

    Returns (paths, unevaluated). `paths` may hold more than one candidate when
    the expression is version-dependent: MiSTer's `pll_q<version>.qip` glob
    matches both pll_q13.qip and pll_q17.qip in this tree, and which one
    Quartus takes depends on runtime state this gate cannot read. The union is
    used for coverage -- a file reachable under *any* resolution was not
    "never handed to Quartus" -- and the ambiguity is printed, never hidden.
    """
    raw = raw.strip()
    if not raw.startswith("["):
        return [], False

    m = TCL_FILE_JOIN.match(raw)
    if m:
        return [qip_dir / m.group(1).strip().strip('"')], False

    m = TCL_JOIN_LIST.match(raw)
    if m:
        parts = m.group(1)
        # Keep the literal head and tail around the unevaluatable middle and
        # glob across it, e.g. `pll_q [regexp ...] .qip` -> `pll_q*.qip`.
        # A naive bracket-balanced substitution is not enough: the MiSTer
        # expression embeds `{[0-9]+}`, whose `]` closes the wrong bracket.
        first = min(
            (i for i in (parts.find("["), parts.find("$")) if i >= 0),
            default=-1,
        )
        last = parts.rfind("]")
        if first >= 0 and last > first:
            head = parts[:first].strip()
            tail = parts[last + 1 :].strip()
            hits = sorted(qip_dir.glob(f"{head}*{tail}"))
            if hits:
                return hits, len(hits) > 1
        return [], True

    return [], True


def strip_comment(line):
    """Drop Tcl/qip comments.

    A `#` outside quotes comments the rest of the line. Without this, commenting
    out one assignment still read as compiled -- a one-character edit that turns
    a real defect green.
    """
    out = []
    in_quote = False
    for ch in line:
        if ch == '"':
            in_quote = not in_quote
        elif ch == "#" and not in_quote:
            break
        out.append(ch)
    return "".join(out)


def _read_lines(path):
    try:
        with open(path, errors="ignore") as fh:
            return list(fh)
    except OSError:
        return []


def collect_file_assignments(entry_points):
    """Walk the Quartus project and return every source file it names.

    Returns (assignments, visited). Each assignment records the raw path, the
    resolved path, and where it was declared.

    Path base semantics, learned the hard way (see the audit doc section 14.10):
    a bare relative path in `set_global_assignment` resolves against the
    **project directory**, not against the list file that declares it. The
    proof is in fpga/Plex_MiSTer/rtl/pll.qip, which writes
    `[file join $::quartus(qip_path) "pll.cmp"]` explicitly when it wants a
    qip-relative path -- so bare relatives are not qip-relative. Resolving
    against the declaring file first made `sys/sys.tcl`'s
    `QIP_FILE sys/sys.qip` resolve to sys/sys/sys.qip, silently truncating the
    walk and reporting four genuinely compiled files as NOT_COMPILED.
    """
    assignments = []
    visited = []
    unevaluated = []
    seen = set()

    def candidates(base, rel):
        """Project-relative first (Quartus semantics), declaring dir second."""
        rel_path = Path(rel)
        if rel_path.is_absolute():
            return [rel_path]
        return [PROJECT_DIR / rel_path, base / rel_path]

    def pick(base, rel, origin, lineno):
        """Resolve a path to one or more candidates, or record it unevaluatable."""
        rel = rel.strip().strip('"')
        if rel.startswith("[") or "$" in rel:
            paths, ambiguous = resolve_tcl_path(rel, base)
            if paths and not ambiguous:
                return paths
            record = {"raw": rel, "origin": origin, "lineno": lineno,
                      "candidates": [str(p) for p in paths]}
            unevaluated.append(record)
            return paths
        for opt in candidates(base, rel):
            if opt.exists():
                return [opt]
        return [candidates(base, rel)[0]]

    def walk(path, depth):
        path = Path(path)
        try:
            key = path.resolve()
        except OSError:
            return
        if key in seen or depth > MAX_INCLUDE_DEPTH or not path.is_file():
            return
        seen.add(key)
        visited.append(path)
        base = path.parent
        for lineno, raw in enumerate(_read_lines(path), start=1):
            line = strip_comment(raw)
            if not line.strip():
                continue
            m = SOURCE_ASSIGNMENT.search(line)
            if m:
                rel = m.group(2)
                for resolved in pick(base, rel, path, lineno):
                    assignments.append(
                        {
                            "kind": m.group(1).upper(),
                            "raw": rel,
                            "resolved": resolved,
                            "origin": path,
                            "lineno": lineno,
                        }
                    )
                continue
            m = QIP_ASSIGNMENT.search(line)
            if m:
                for nxt in pick(base, m.group(1), path, lineno):
                    walk(nxt, depth + 1)
                continue
            m = SOURCE_DIRECTIVE.match(line)
            if m:
                for nxt in pick(base, m.group(1), path, lineno):
                    walk(nxt, depth + 1)

    for entry in entry_points:
        walk(entry, 0)
    return assignments, visited, unevaluated


def resolved_set(assignments):
    out = set()
    for a in assignments:
        try:
            out.add(a["resolved"].resolve())
        except OSError:
            continue
    return out


def tracked_rtl():
    """Every tracked HDL file under rtl/, including subdirectories.

    The original globbed `rtl/*.sv` only, so rtl/pll/ and the four tracked .v
    files were outside the denominator entirely.
    """
    out = subprocess.run(
        ["git", "ls-files", "fpga/Plex_MiSTer/rtl"],
        capture_output=True,
        text=True,
        cwd=ROOT,
    ).stdout.split()
    return [Path(p) for p in out if Path(p).suffix.lower() in HDL_SUFFIXES]


def load_allowed_absent(path):
    """Parse the tracked allowlist manifest. Returns (entries, no_reason)."""
    entries = {}
    no_reason = []
    if not path.exists():
        return entries, no_reason
    for raw in path.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        name, sep, reason = raw.partition("#")
        name = name.strip()
        if not name:
            continue
        reason = reason.strip()
        if not sep or not reason:
            no_reason.append(name)
        entries[name] = reason
    return entries, no_reason


def rtl_keys(rel_path):
    """Names an allowlist entry may use for a tracked rtl/ file."""
    try:
        under_rtl = rel_path.relative_to("fpga/Plex_MiSTer/rtl").as_posix()
    except ValueError:
        under_rtl = rel_path.name
    return {rel_path.as_posix(), under_rtl, rel_path.name}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Quartus file-list coverage gate")
    ap.add_argument(
        "--require",
        action="append",
        default=[],
        metavar="MODULE",
        help="assert this module's source file is compiled (repeatable)",
    )
    args = ap.parse_args(argv)

    if not QSF.exists() and not QIP.exists():
        print(f"Scope: 0 -- neither {QSF} nor {QIP} found")
        print("SKIP: no Quartus project to cross-check")
        return 77

    entry_points = [p for p in (QSF, QIP) if p.exists()]
    assignments, visited, unevaluated = collect_file_assignments(entry_points)
    compiled = resolved_set(assignments)
    tracked = tracked_rtl()

    print(
        f"Scope: {len(assignments)} source assignments across {len(visited)} "
        f"Quartus list file(s); {len(tracked)} tracked HDL files under rtl/"
    )
    print("  entry points: " + ", ".join(str(p.relative_to(ROOT)) for p in visited))
    print(f"UNEVALUATED_TCL_PATHS count={len(unevaluated)}")
    for u in unevaluated:
        cands = u.get("candidates") or []
        tag = "AMBIGUOUS_TCL_INCLUDE" if cands else "UNEVALUATED_TCL_PATH"
        print(f"  {tag} {u['origin'].name}:{u['lineno']} {u['raw']}")
        for c in cands:
            print(f"    candidate (counted as compiled): {c}")
    if not assignments or not tracked:
        print("REFUSED: Scope: 0 on one side -- a PASS cannot be claimed")
        return 2

    rc = 0

    # A3: an assignment naming a file that is not on disk. Quartus would error,
    # but the original gate counted it as coverage -- so a typo'd path could
    # satisfy a --require for a module that is not in the design.
    dangling = sorted(
        (a for a in assignments if not a["resolved"].exists()),
        key=lambda x: x["raw"],
    )
    for a in dangling:
        print(
            f"  QIP_ENTRY_MISSING_FILE {a['raw']} "
            f"({a['origin'].name}:{a['lineno']}) -- listed but not on disk"
        )
    if dangling:
        rc = 1

    product = [t for t in tracked if not t.name.startswith("tb_")]
    benches = len(tracked) - len(product)

    allowed, no_reason = load_allowed_absent(ALLOWED_ABSENT_MANIFEST)
    for name in no_reason:
        print(f"  ALLOWED_ABSENT_NO_REASON {name} -- every exclusion needs a reason")
    if no_reason:
        rc = 1

    missing = []
    claimed = set()
    for t in sorted(product, key=lambda p: p.as_posix()):
        try:
            present = (ROOT / t).resolve() in compiled
        except OSError:
            present = False
        hit = sorted(rtl_keys(t) & set(allowed))
        if present:
            if hit:
                # A5: the excuse outlived the defect.
                for k in hit:
                    print(
                        f"  STALE_ALLOWED_ABSENT {k} -- now compiled; "
                        f"remove it from {ALLOWED_ABSENT_MANIFEST.name}"
                    )
                    claimed.add(k)
                rc = 1
            continue
        missing.append((t, hit))
        claimed |= set(hit)

    print(f"product RTL: {len(product)}  (testbenches excluded: {benches})")
    print(f"tracked but NOT compiled: {len(missing)} / {len(product)}")
    unexplained = []
    for t, hit in missing:
        if hit:
            print(f"  ALLOWED_ABSENT {t.as_posix()}  -- {allowed[hit[0]]}")
        else:
            print(f"  NOT_COMPILED {t.as_posix()}")
            unexplained.append(t.name)

    # A5: an allowlist entry for a file that is no longer tracked at all.
    orphaned = sorted(set(allowed) - claimed)
    for name in orphaned:
        print(
            f"  STALE_ALLOWED_ABSENT {name} -- no such tracked rtl/ file; "
            f"remove it from {ALLOWED_ABSENT_MANIFEST.name}"
        )
    if orphaned:
        rc = 1

    by_name = {}
    for t in product:
        by_name.setdefault(t.name, t)
    for mod in args.require:
        fname = mod if Path(mod).suffix.lower() in HDL_SUFFIXES else mod + ".sv"
        tracked_hit = by_name.get(Path(fname).name)
        present = False
        if tracked_hit is not None:
            try:
                present = (ROOT / tracked_hit).resolve() in compiled
            except OSError:
                present = False
        if present:
            print(f"REQUIRED_FILE_COMPILED {fname}")
        else:
            in_git = "tracked-in-git" if tracked_hit is not None else "not-tracked"
            print(
                f"REQUIRED_FILE_NOT_COMPILED {fname} ({in_git}) "
                f"-- not handed to Quartus by {QSF.name}"
            )
            rc = 1

    if unexplained:
        print(
            f"QIP_COVERAGE_FAIL unexplained_absent={len(unexplained)} "
            f"({', '.join(unexplained)})"
        )
        rc = 1
    elif rc == 0:
        print(
            f"QIP_COVERAGE_OK product={len(product)} "
            f"compiled={len(product) - len(missing)} "
            f"allowed_absent={len(missing)}"
        )
    return rc


if __name__ == "__main__":
    sys.exit(main())
