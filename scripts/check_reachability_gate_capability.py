#!/usr/bin/env python3
"""Refuse to cite `--root` evidence from a checker that cannot honour `--root`.

W-FIT-O5 measured, on `parent/integ-hour27`, that the 200-line variant of
`scripts/check_rtl_module_instantiations.py` **has no argument parser at all**.
Reproduced here at `1ad5706`:

```
$ python3 scripts/check_rtl_module_instantiations.py \
      --root h264_decode_core --require h264_decode_top ; echo $?
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=44 bench_only=24 root=emu
0
$ python3 scripts/check_rtl_module_instantiations.py --zzz-nonexistent ; echo $?
0
$ python3 scripts/check_rtl_module_instantiations.py --help ; echo $?
0
```

It ignores every flag, answers the *plain masked `emu`* question, prints
`root=emu` while you asked for `h264_decode_core`, and exits 0. That is a true
number about the wrong thing, produced silently, and it is precisely the
evidence the parent's ruling forbids. Anyone who merges the ruling's command
line into a branch carrying that variant gets a confident-looking green.

Nothing shipped on one branch can fix another branch's file, so this probe is
built to work **against a degraded copy** rather than to assume a good one. The
load-bearing probe is deliberately negative: a checker that **exits 0 on an
invalid flag cannot be parsing flags**, therefore cannot be honouring `--root`
or `--require`, whatever it printed. That test needs no cooperation from the
checker and is portable to every branch.

Skips are impossible here by construction: if the checker is missing, that is a
hard fail, not an UNSCORED -- a missing structural gate is exactly the condition
we must never paper over.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CHECKER = ROOT / "scripts" / "check_rtl_module_instantiations.py"
BOGUS_FLAG = "--w-gate-capability-probe-should-not-parse"
REQUIRED_HELP_FLAGS = ("--root", "--require", "--allow-non-product-root")
REQUIRED_MARKERS = ("TRUNK_PROOF", "UNDECIDABLE_GENERATE_MODULES")


def fail(msg: str) -> None:
    print(f"REACHABILITY_GATE_CAPABILITY_FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def run(checker: Path, args: list[str]) -> tuple[int, str]:
    """Run the checker and read its status directly -- never through a pipe.

    W-FIT-O5 volunteered having read `$?` after `| tail` and nearly reported the
    fleet's mandated instrument as broken; `tail` had returned 0 over eight real
    failures. That is the third time a pipe has manufactured a false green in
    this repo, so this helper exists so no caller has to get it right again.
    """
    proc = subprocess.run(
        [sys.executable, str(checker), *args],
        # Run the checker in *its own* tree. Manifests such as
        # nondefault_config_modules.txt are branch state, so invoking a foreign
        # copy from this worktree produces a phantom failure -- a trap this
        # project has already been caught by once.
        cwd=checker.resolve().parents[1],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def probe_rejects_unknown_flag(checker: Path) -> str | None:
    """The load-bearing probe, and the one that needed tightening.

    A bare `rc != 0` is not evidence of argument parsing: the first draft of this
    file scored the degraded copy as OK because that copy died with rc=1 for an
    unrelated manifest reason. Non-zero for an unexamined reason is the same
    vacuity class this gate exists to hunt, so the probe now demands the specific
    signature of a real parser -- argparse's rc=2 plus an "unrecognized"/"unknown"
    diagnostic naming the flag.
    """
    rc, out = run(checker, [BOGUS_FLAG])
    if rc == 0:
        return (
            f"exits 0 on the invalid flag {BOGUS_FLAG}, so it parses no arguments; any "
            "--root/--require result from it is the plain masked emu answer wearing a "
            "different label"
        )
    lowered = out.lower()
    if rc != 2 or not ("unrecognized" in lowered or "unknown" in lowered):
        return (
            f"exited {rc} on {BOGUS_FLAG} without an argument-parser diagnostic, so the "
            "non-zero status is not evidence that the flag was rejected: "
            + repr(out.strip()[:160])
        )
    return None


def probe_help_advertises_flags(checker: Path) -> str | None:
    rc, out = run(checker, ["--help"])
    if rc != 0:
        return f"--help exited {rc}; a gate that cannot describe itself cannot be audited"
    missing = [flag for flag in REQUIRED_HELP_FLAGS if flag not in out]
    if missing:
        return "--help does not advertise " + ", ".join(missing)
    return None


def probe_bad_root_is_fatal(checker: Path) -> str | None:
    rc, out = run(checker, ["--root", "w_gate_no_such_module_anywhere"])
    if rc == 0:
        return "accepts a --root naming a module that does not exist and still exits 0"
    if "not exist" not in out:
        return f"rejects a bogus --root without saying why: {out.strip()[:160]!r}"
    return None


def probe_emits_trunk_and_undecidability(checker: Path) -> str | None:
    rc, out = run(checker, [])
    if rc != 0:
        return f"the default product run exited {rc}; capability cannot be assessed"
    missing = [marker for marker in REQUIRED_MARKERS if marker not in out]
    if missing:
        return (
            "the default run prints no " + ", ".join(missing) + " line, so its logs cannot "
            "be told apart from a degraded copy's logs after the fact"
        )
    return None


PROBES = (
    ("rejects_unknown_flag", probe_rejects_unknown_flag),
    ("help_advertises_flags", probe_help_advertises_flags),
    ("bad_root_is_fatal", probe_bad_root_is_fatal),
    ("emits_trunk_and_undecidability", probe_emits_trunk_and_undecidability),
)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--checker", default=str(DEFAULT_CHECKER))
    args = ap.parse_args(argv)

    checker = Path(args.checker)
    if not checker.is_absolute():
        checker = ROOT / checker

    print(
        "Scope: reachability_capability_probes=%d checker=%s"
        % (len(PROBES), checker.name),
        flush=True,
    )
    if not PROBES:
        fail("Scope: 0 probes; the gate cannot claim a PASS over an empty set")
    if not checker.is_file():
        fail(f"the structural reachability gate is missing entirely: {checker}")

    defects: list[tuple[str, str]] = []
    for name, probe in PROBES:
        problem = probe(checker)
        status = "FAIL" if problem else "OK"
        print(f"REACHABILITY_CAPABILITY_PROBE {name} {status}")
        if problem:
            defects.append((name, problem))

    for name, problem in defects:
        print(f"REACHABILITY_GATE_DEGRADED {name}: {problem}", file=sys.stderr)
    if defects:
        fail(
            f"{len(defects)}/{len(PROBES)} capability probe(s) failed on {checker.name}. This "
            "branch's checker cannot honour the core-rooted evidence standard, so no --root or "
            "--require result from it may be cited as product evidence. Merge the guarded "
            "checker before quoting reachability from this branch."
        )

    print(f"REACHABILITY_GATE_CAPABLE probes={len(PROBES)} checker={checker.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
