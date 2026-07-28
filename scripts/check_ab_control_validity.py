#!/usr/bin/env python3
"""Does this A/B comparison actually vary the thing it claims to test?

W-FIT-O5 refuted a published exoneration with this. `Plex.sdc` was declared
netlist-neutral on the strength of four fit slots agreeing -- but all four
carried the **same** SDC. The comparison never varied the independent variable,
so it demonstrated fitter determinism and nothing else. Four slots agreeing on
an identical input proves reproducibility, not neutrality.

That is the same family as `Scope: 0`: a real, correctly-computed result that
does not measure what everyone believes it measures. `Scope: 0` is "I compared
nothing"; a vacuous control is "I compared two copies of the same thing".

Independently corroborated here from the local slot artefacts, which is how the
gate's real red/green is built -- no synthesis required:

    wfit-hour27-sdc-a  Plex.rbf fb4bad84
    wfit-hour27-sdc-b  Plex.rbf fb4bad84   identical -> the pair can exonerate nothing
    wfit-hour27-a      Plex.rbf 3b1e8435
    wfit-hour27-bdiag-b Plex.rbf fb4bad84  differ    -> a real comparison

Verdicts:
  CONTROLLED        the named variable differs, and nothing outside it does
  VACUOUS_CONTROL   the named variable is byte-identical -- the claim is unsupported
  CONFOUNDED        something outside the named variable also differs
  rc=2              nothing comparable to compare (a Scope: 0)
  rc=77             an input set is missing; unscored, never a pass
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import sys
from pathlib import Path

CONTROLLED, NOT_CONTROLLED, REFUSED, UNSCORED = 0, 1, 2, 77


def digest(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect(root: Path, ignore: list[str]) -> dict[str, Path]:
    files: dict[str, Path] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        rel = str(path.relative_to(root))
        if any(fnmatch.fnmatch(rel, pattern) for pattern in ignore):
            continue
        files[rel] = path
    return files


def matches(rel: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(rel, pattern) for pattern in patterns)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--a", required=True, help="one side of the comparison")
    ap.add_argument("--b", required=True, help="the other side")
    ap.add_argument("--variable", action="append", default=[], metavar="GLOB",
                    help="the independent variable this comparison claims to vary")
    ap.add_argument("--ignore", action="append", default=[], metavar="GLOB",
                    help="paths that are noise (logs, timings, stats)")
    ap.add_argument("--outcome", action="append", default=[], metavar="GLOB",
                    help="the dependent variable, e.g. Plex.rbf")
    args = ap.parse_args(argv)

    side_a, side_b = Path(args.a), Path(args.b)
    for side in (side_a, side_b):
        if not side.is_dir():
            print(f"Scope: 0 -- not a directory: {side}")
            print(f"SKIP: comparison input missing: {side}", file=sys.stderr)
            return UNSCORED

    if not args.variable:
        print("Scope: 0 -- no --variable named")
        print(
            "REFUSED: name the independent variable. A comparison that cannot say "
            "what it varies cannot be checked for varying it.",
            file=sys.stderr,
        )
        return REFUSED

    files_a = collect(side_a, args.ignore)
    files_b = collect(side_b, args.ignore)
    common = sorted(set(files_a) & set(files_b))
    only_a = sorted(set(files_a) - set(files_b))
    only_b = sorted(set(files_b) - set(files_a))

    print(f"Scope: compared_files={len(common)} a_only={len(only_a)} "
          f"b_only={len(only_b)} variables={len(args.variable)} "
          f"ignored_globs={len(args.ignore)}")

    if not common:
        print(
            "REFUSED: the two sides share no comparable file, so nothing was "
            "actually compared",
            file=sys.stderr,
        )
        return REFUSED

    differing: list[str] = []
    for rel in common:
        if digest(files_a[rel]) != digest(files_b[rel]):
            differing.append(rel)

    variable_files = [rel for rel in common if matches(rel, args.variable)]
    variable_differs = [rel for rel in differing if matches(rel, args.variable)]
    outcome_differs = [rel for rel in differing if matches(rel, args.outcome)]
    confounds = [
        rel for rel in differing
        if not matches(rel, args.variable) and not matches(rel, args.outcome)
    ]

    print(f"VARIABLE_FILES present={len(variable_files)} differing={len(variable_differs)}")
    for rel in variable_files:
        state = "DIFFERS" if rel in variable_differs else "IDENTICAL"
        print(f"  VARIABLE {state} {rel}")
    for rel in outcome_differs:
        print(f"  OUTCOME DIFFERS {rel}")
    for rel in confounds[:20]:
        print(f"  CONFOUND {rel}")
    if only_a or only_b:
        for rel in (only_a + only_b)[:10]:
            print(f"  ASYMMETRIC {rel}")

    rc = CONTROLLED

    if not variable_files:
        print(
            "REFUSED: the named variable matches no file present on both sides, so "
            "this comparison cannot be assessed: " + ", ".join(args.variable),
            file=sys.stderr,
        )
        return REFUSED

    if not variable_differs:
        print(
            "VACUOUS_CONTROL: the independent variable is byte-identical on both "
            "sides. This comparison demonstrates reproducibility, not the property "
            "it is being cited for. Any conclusion about "
            + ", ".join(args.variable)
            + " drawn from it is unsupported.",
            file=sys.stderr,
        )
        if outcome_differs:
            print(
                "  And the outcome differs anyway (" + ", ".join(outcome_differs)
                + "), so an input that nobody declared is varying.",
                file=sys.stderr,
            )
        rc = NOT_CONTROLLED

    if confounds:
        print(
            f"CONFOUNDED: {len(confounds)} file(s) outside the named variable also "
            "differ, so an observed effect cannot be attributed to it: "
            + ", ".join(confounds[:5]) + ("..." if len(confounds) > 5 else ""),
            file=sys.stderr,
        )
        rc = NOT_CONTROLLED

    if rc == CONTROLLED:
        effect = "outcome_differs" if outcome_differs else "outcome_identical"
        print(
            f"AB_CONTROL_OK varied={len(variable_differs)} confounds=0 {effect} "
            "-- the comparison does vary what it claims to vary"
        )
        if not outcome_differs and args.outcome:
            print(
                "  Note: a real variation produced no change in the outcome. That is "
                "a genuine null result, and is the only shape that can support a "
                "neutrality claim."
            )
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
