#!/usr/bin/env python3
"""Red/green for the argv contract: a gate must refuse what it cannot honour.

The anchor is not synthetic. `check_rtl_module_instantiations.py` on
`w-cast-play-state` `667a237` (and baseline `ddb7c97`) contains zero
`add_argument` calls and never references `sys.argv`. Measured in that
worktree, in place:

    $ python3 scripts/check_rtl_module_instantiations.py \
          --root h264_decode_core --require totally_bogus_module_xyz
    RTL_MODULE_INSTANTIATION_OK rtl_modules=70 reachable=48 bench_only=22 root=emu
    rc=0

A module that exists nowhere in the repository passed, and `root=emu` was
checked despite `--root h264_decode_core`. The contract gate must flag that
blob and clear the argparse version that replaced it.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "check_argv_contract.py"
VACUOUS_REFS = ("w-cast-play-state", "ddb7c97")
TARGET = "scripts/check_rtl_module_instantiations.py"


def scratch():
    base = ROOT / "build" / "w-gate-o5-scratch"
    base.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(prefix="argvcontract-", dir=str(base))


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(GATE), *args],
                          capture_output=True, text=True, cwd=ROOT)


def probe(td: str, body: str, name: str = "check_probe.py") -> str:
    Path(td, name).write_text(body)
    return td


def case_no_argv_reading_is_flagged() -> None:
    body = '''from pathlib import Path
def main() -> int:
    print("PROBE_OK")
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
'''
    with scratch() as td:
        proc = run("--scripts-dir", probe(td, body))
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "IGNORES_ARGV check_probe.py" in proc.stdout, proc.stdout
        assert "ARGV_CONTRACT_FAIL" in proc.stderr, proc.stderr


def case_manual_argv_is_flagged() -> None:
    body = '''import sys
def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "default"
    print(out)
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
'''
    with scratch() as td:
        proc = run("--scripts-dir", probe(td, body))
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "MANUAL_ARGV" in proc.stdout, proc.stdout


def case_parse_known_args_is_flagged() -> None:
    """argparse's own opt-out from the check this gate requires."""
    body = '''import argparse
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root")
    args, _rest = ap.parse_known_args()
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
'''
    with scratch() as td:
        proc = run("--scripts-dir", probe(td, body))
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "ACCEPTS_UNKNOWN" in proc.stdout, proc.stdout


def case_parse_args_conforms() -> None:
    body = '''import argparse
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root")
    ap.parse_args()
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
'''
    with scratch() as td:
        proc = run("--scripts-dir", probe(td, body), "--show-ok")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "ARGV_OK check_probe.py" in proc.stdout, proc.stdout


def case_explicit_refusal_conforms() -> None:
    body = '''import strict_argv
def main() -> int:
    strict_argv.refuse_unrecognised_argv()
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
'''
    with scratch() as td:
        proc = run("--scripts-dir", probe(td, body), "--show-ok")
        assert proc.returncode == 0, proc.stdout + proc.stderr


def case_import_only_module_is_not_required_to_parse() -> None:
    """A module nobody runs cannot be handed a flag; flagging it is a false red."""
    body = '''from pathlib import Path
def helper(x):
    return x + 1
'''
    with scratch() as td:
        proc = run("--scripts-dir", probe(td, body, "rtl_helpers.py"), "--show-ok")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "libraries=1" in proc.stdout, proc.stdout


def case_empty_scan_refuses() -> None:
    with scratch() as td:
        proc = run("--scripts-dir", td)
        assert proc.returncode == 2, proc.stdout + proc.stderr
        assert "proved over nothing" in proc.stderr, proc.stderr


def case_strict_argv_helper_refuses() -> None:
    helper = ROOT / "scripts" / "strict_argv.py"
    body = f'''import sys
sys.path.insert(0, {str(helper.parent)!r})
import strict_argv
strict_argv.refuse_unrecognised_argv()
print("reached")
'''
    with scratch() as td:
        script = Path(td, "user.py")
        script.write_text(body)
        clean = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
        assert clean.returncode == 0 and "reached" in clean.stdout, clean
        dirty = subprocess.run([sys.executable, str(script), "--bogus"],
                               capture_output=True, text=True)
        assert dirty.returncode == 2, dirty.stdout + dirty.stderr
        assert "ARGV_REFUSED" in dirty.stderr, dirty.stderr
        assert "reached" not in dirty.stdout, dirty.stdout


def available_refs() -> list[str]:
    found = []
    for ref in VACUOUS_REFS:
        probe = subprocess.run(["git", "cat-file", "-e", f"{ref}:{TARGET}"],
                               cwd=ROOT, capture_output=True)
        if probe.returncode == 0:
            found.append(ref)
    return found


def case_real_vacuous_gate_anchor(refs: list[str]) -> int:
    """The measured instances: a reachability gate that discards --require."""
    anchors = 0
    for ref in refs:
        blob = subprocess.run(["git", "show", f"{ref}:{TARGET}"],
                              cwd=ROOT, capture_output=True, text=True)
        assert blob.returncode == 0, blob.stderr
        assert "add_argument" not in blob.stdout, (
            f"{ref} was expected to be the pre-argparse blob; it now parses flags, "
            "so this anchor no longer measures the defect")
        with scratch() as td:
            Path(td, "check_rtl_module_instantiations.py").write_text(blob.stdout)
            proc = run("--scripts-dir", td)
            assert proc.returncode == 1, f"{ref}: {proc.stdout}{proc.stderr}"
            assert "IGNORES_ARGV check_rtl_module_instantiations.py" in proc.stdout, proc.stdout
        anchors += 1
    return anchors


def case_current_reachability_gate_conforms() -> None:
    """The fixed version in this tree, checked for real rather than assumed."""
    live = ROOT / "scripts" / "check_rtl_module_instantiations.py"
    with scratch() as td:
        Path(td, live.name).write_text(live.read_text())
        proc = run("--scripts-dir", td, "--show-ok")
        assert proc.returncode == 0, proc.stdout + proc.stderr


def main() -> int:
    cases = (
        case_no_argv_reading_is_flagged,
        case_manual_argv_is_flagged,
        case_parse_known_args_is_flagged,
        case_parse_args_conforms,
        case_explicit_refusal_conforms,
        case_import_only_module_is_not_required_to_parse,
        case_empty_scan_refuses,
        case_strict_argv_helper_refuses,
        case_current_reachability_gate_conforms,
    )
    refs = available_refs()
    print(f"Scope: argv_contract_cases={len(cases)} "
          f"real_vacuous_anchors={len(refs)}/{len(VACUOUS_REFS)} "
          f"refs={','.join(refs) if refs else '<none>'}")
    for case in cases:
        case()
    anchors = case_real_vacuous_gate_anchor(refs)
    assert anchors == len(refs), (anchors, len(refs))
    print(f"ARGV_CONTRACT_TEST_OK cases={len(cases)} real_anchors={anchors}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
