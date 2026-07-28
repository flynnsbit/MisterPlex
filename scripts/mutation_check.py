#!/usr/bin/env python3
"""Mechanical non-vacuity check: prove a test actually constrains behaviour.

The vacuous-control pattern
---------------------------
A comparison that does not vary the thing it claims to test looks like strong
evidence and is worth nothing.  The parent's SDC exoneration compared four
builds that all carried the SAME new SDC: it demonstrated fitter determinism,
not SDC neutrality.  The same family: gates that exit 0 without running,
`Scope: 0` passes, reachability that reaches only through a retired stub.

For a TEST, the equivalent question is: **if the behaviour under test were
wrong, would this test notice?**  The only mechanical answer is to break the
behaviour on purpose and require the test to go red.  A mutation that SURVIVES
is a proof of vacuity, not a style opinion.

This is not hypothetical.  Running this harness on my own capture gate,
two mutations survived:

    SURVIVED  chevron-fill-gate-removed
    SURVIVED  chevron-fill-threshold-zeroed

My regression case was rejected by an *aspect* check before the *fill* check
ever ran, so the fill gate was unconstrained and I had not noticed.  I would
have shipped it believing it was covered.

Usage
-----
    python3 scripts/mutation_check.py --spec <spec.json>
    python3 scripts/mutation_check.py --self-test

Spec format (JSON)::

    {
      "test": ["python3", "tests/unit/test_x.py"],
      "mutations": [
        {"name": "gate-removed", "target": "scripts/x.py",
         "old": "if limit_exceeded:", "new": "if False:"}
      ]
    }

Paths are resolved relative to the repository root.

Exit codes
----------
  0  every mutation was killed (test is non-vacuous for these behaviours)
  1  at least one mutation SURVIVED, or an anchor string was not found
  2  REFUSE — unusable spec, or the baseline test is not green

REFUSE on a red baseline is deliberate: mutation results are meaningless if the
test does not pass unmutated, and a red baseline would otherwise "kill" every
mutation and report a confident, meaningless green.

Scope limits (declared up front)
--------------------------------
* Proves only that the listed mutations are detected.  It cannot enumerate the
  behaviours you FORGOT to mutate -- an empty or lazy mutation list still
  reports success, which is why an empty list is refused.
* Applies literal string substitution, not semantic mutation.
* Restores every target file in a `finally:` block, and verifies restoration
  before exiting.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

EXIT_OK, EXIT_VACUOUS, EXIT_REFUSE = 0, 1, 2

ROOT = Path(__file__).resolve().parents[1]


def run(cmd: list[str]) -> int:
    return subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True).returncode


def load_spec(path: Path) -> tuple[list[str], list[dict]] | None:
    try:
        spec = json.loads(path.read_text())
    except Exception as exc:
        print(f"REFUSE: cannot parse spec {path}: {exc}", file=sys.stderr)
        return None
    test = spec.get("test")
    muts = spec.get("mutations")
    if not isinstance(test, list) or not test:
        print("REFUSE: spec needs a non-empty \"test\" command list", file=sys.stderr)
        return None
    if not isinstance(muts, list) or not muts:
        # An empty mutation list would otherwise report a vacuous success --
        # exactly the pattern this tool exists to detect.
        print("REFUSE: spec has no mutations; an empty mutation list would report "
              "success without testing anything", file=sys.stderr)
        return None
    for m in muts:
        if not all(k in m for k in ("name", "target", "old", "new")):
            print(f"REFUSE: mutation missing a required key: {m}", file=sys.stderr)
            return None
        if m["old"] == m["new"]:
            print(f"REFUSE: mutation {m['name']!r} does not change anything "
                  "(old == new); it is a vacuous control by construction",
                  file=sys.stderr)
            return None
    return test, muts


def mutation_check(test: list[str], muts: list[dict], quiet: bool = False) -> int:
    targets = {}
    for m in muts:
        p = (ROOT / m["target"]).resolve()
        if not p.is_file():
            print(f"REFUSE: target not found: {m['target']}", file=sys.stderr)
            return EXIT_REFUSE
        targets[p] = p.read_text()

    print(f"Scope: {len(muts)} mutations across {len(targets)} file(s); "
          f"test = {' '.join(test)}")

    base = run(test)
    if base != 0:
        print(f"REFUSE: baseline test is not green (rc={base}); mutation results "
              "would be meaningless — every mutation would appear killed",
              file=sys.stderr)
        return EXIT_REFUSE
    if not quiet:
        print("baseline rc=0 GREEN")

    killed, survived = [], []
    try:
        for m in muts:
            p = (ROOT / m["target"]).resolve()
            orig = targets[p]
            if m["old"] not in orig:
                print(f"ANCHOR-MISSING  {m['name']}: {m['old']!r} not in {m['target']}")
                survived.append(f"{m['name']} (anchor missing)")
                continue
            p.write_text(orig.replace(m["old"], m["new"], 1))
            rc = run(test)
            p.write_text(orig)
            if rc == 0:
                print(f"SURVIVED  {m['name']}  — test still green, behaviour UNCONSTRAINED")
                survived.append(m["name"])
            else:
                if not quiet:
                    print(f"KILLED    {m['name']}  (rc={rc})")
                killed.append(m["name"])
    finally:
        for p, txt in targets.items():
            p.write_text(txt)

    for p, txt in targets.items():
        if p.read_text() != txt:
            print(f"REFUSE: failed to restore {p}", file=sys.stderr)
            return EXIT_REFUSE

    print(f"\nScope: {len(muts)} mutations; killed {len(killed)}, survived {len(survived)}")
    if survived:
        print("SURVIVORS (vacuous coverage): " + ", ".join(survived))
        return EXIT_VACUOUS
    print("MUTATION_OK — every mutation turned the test red")
    return EXIT_OK


def self_test() -> int:
    """Hermetic red/green using a throwaway module and test."""
    checks: list[tuple[str, bool, str]] = []
    with tempfile.TemporaryDirectory(dir=str(ROOT / "artifacts")) as td:
        d = Path(td)
        src = d / "widget.py"
        src.write_text("def grade(v):\n"
                       "    if v > 10:\n"
                       "        return 'HIGH'\n"
                       "    return 'LOW'\n")

        # A REAL test: checks both branches.
        good = d / "test_good.py"
        good.write_text("import sys; sys.path.insert(0, r'%s')\n"
                        "import widget\n"
                        "assert widget.grade(50) == 'HIGH'\n"
                        "assert widget.grade(1) == 'LOW'\n" % d)
        # A VACUOUS test: only ever exercises the LOW branch, so removing the
        # threshold entirely goes unnoticed.
        weak = d / "test_weak.py"
        weak.write_text("import sys; sys.path.insert(0, r'%s')\n"
                        "import widget\n"
                        "assert widget.grade(1) == 'LOW'\n" % d)

        mut = [{"name": "threshold-removed", "target": str(src.relative_to(ROOT)),
                "old": "    if v > 10:", "new": "    if False:"}]

        rc = mutation_check([sys.executable, str(good)], mut, quiet=True)
        checks.append(("real test kills the mutation (rc=0)", rc == EXIT_OK, f"rc={rc}"))

        rc = mutation_check([sys.executable, str(weak)], mut, quiet=True)
        checks.append(("VACUOUS test is caught (rc=1)", rc == EXIT_VACUOUS, f"rc={rc}"))

        checks.append(("source file restored after mutation",
                       src.read_text().startswith("def grade(v):\n    if v > 10:"),
                       src.read_text()))

        # Red baseline must REFUSE, not silently "kill" everything.
        red = d / "test_red.py"
        red.write_text("raise SystemExit(1)\n")
        rc = mutation_check([sys.executable, str(red)], mut, quiet=True)
        checks.append(("red baseline REFUSES (rc=2), never a false green",
                       rc == EXIT_REFUSE, f"rc={rc}"))

        # A no-op mutation is a vacuous control by construction.
        noop = [{"name": "noop", "target": str(src.relative_to(ROOT)),
                 "old": "    if v > 10:", "new": "    if v > 10:"}]
        spec = d / "noop.json"
        spec.write_text(json.dumps({"test": [sys.executable, str(good)],
                                    "mutations": noop}))
        checks.append(("no-op mutation (old == new) is refused",
                       load_spec(spec) is None, "accepted a no-op mutation"))

        empty = d / "empty.json"
        empty.write_text(json.dumps({"test": [sys.executable, str(good)],
                                     "mutations": []}))
        checks.append(("empty mutation list is refused",
                       load_spec(empty) is None, "accepted an empty list"))

    ok = 0
    for name, passed, detail in checks:
        print(f"{'PASS' if passed else 'FAIL'} {name}" + ("" if passed else f"  [{detail}]"))
        ok += passed
    print(f"\n{ok}/{len(checks)} self-test checks passed")
    return 0 if ok == len(checks) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", help="JSON spec file")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.spec:
        print("REFUSE: --spec or --self-test required", file=sys.stderr)
        return EXIT_REFUSE
    loaded = load_spec(Path(args.spec))
    if loaded is None:
        return EXIT_REFUSE
    test, muts = loaded
    return mutation_check(test, muts, quiet=args.quiet)


if __name__ == "__main__":
    raise SystemExit(main())
