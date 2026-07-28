#!/usr/bin/env python3
"""Unit coverage for the --root/--require product-reachability guard.

Motivation, measured 2026-07-28 on origin/w-deblock-seam:

    python3 scripts/check_rtl_module_instantiations.py \
        --root h264_decode_core --require h264_deblock_writeback_ctrl

returned rc=0 and printed REQUIRED_RTL_MODULE_REACHABLE, while h264_decode_core
had *zero* instantiating parents on that branch and stream_path instantiated
only decode_stub.  The identical command also returned rc=0 when rooted at
h264_decode_skeleton, which is confirmed dead code.  A gate that passes when
rooted at dead code proves nothing about the product.

The guard therefore refuses to evaluate a requirement from a root that is not
itself product-reachable, unless the caller explicitly opts in, in which case
the result is labelled SUBTREE_ONLY_CLAIM and may not be quoted as product
evidence.
"""
from __future__ import annotations

import io
import contextlib
import os
import tempfile
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_rtl_module_instantiations as rtl  # noqa: E402

# emu -> stream_path -> painter -> writeback
# orphan_core -> writeback  (orphan_core has no parents at all)
GRAPH = {
    "emu": {"stream_path"},
    "stream_path": {"painter"},
    "painter": {"writeback"},
    "orphan_core": {"writeback", "core_only_helper"},
}
MODULES = {
    name: None
    for name in ("emu", "stream_path", "painter", "writeback", "orphan_core", "core_only_helper")
}
PRODUCT_REACHABLE = {"stream_path", "painter", "writeback"}


def run(**kwargs) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rtl.check_required_modules(**kwargs)
    except SystemExit as exc:
        rc = int(exc.code or 0)
    return rc, out.getvalue(), err.getvalue()


def call(required, root, allow=False):
    return run(
        required=required,
        root=root,
        graph=GRAPH,
        modules=MODULES,
        product_reachable=PRODUCT_REACHABLE,
        allow_non_product_root=allow,
    )


def build_foreign_checkout(base: Path) -> Path:
    """A minimal MiSTerPlex-shaped checkout that shares no module with this one.

    It deliberately carries *no* bench-only / nondefault / drop manifests: the
    first --project-root implementation read this branch's manifest policy
    before it knew the query was foreign, so a foreign tree died with
    "missing explicit NONDEFAULT_CONFIG_REACHABLE list" -- a transplant
    artefact reported as a finding about the target.
    """
    proj = base / "fpga" / "Plex_MiSTer"
    rtl_dir = proj / "rtl"
    rtl_dir.mkdir(parents=True)
    (proj / "Plex.sv").write_text(
        "module emu();\n  foreign_widget u_w();\nendmodule\n"
    )
    (proj / "Plex.qsf").write_text(
        "set_global_assignment -name TOP_LEVEL_ENTITY emu\nsource files.qip\n"
    )
    (proj / "files.qip").write_text(
        "set_global_assignment -name SYSTEMVERILOG_FILE rtl/foreign_widget.sv\n"
        "set_global_assignment -name SYSTEMVERILOG_FILE rtl/foreign_orphan.sv\n"
    )
    (rtl_dir / "foreign_widget.sv").write_text("module foreign_widget();\nendmodule\n")
    (rtl_dir / "foreign_orphan.sv").write_text("module foreign_orphan();\nendmodule\n")
    (rtl_dir / "foreign_untracked.sv").write_text("module foreign_untracked();\nendmodule\n")
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "w-gate",
        "GIT_AUTHOR_EMAIL": "w-gate@example.invalid",
        "GIT_COMMITTER_NAME": "w-gate",
        "GIT_COMMITTER_EMAIL": "w-gate@example.invalid",
    }
    subprocess.run(["git", "init", "-q"], cwd=base, check=True, env=env)
    subprocess.run(
        ["git", "add", "fpga/Plex_MiSTer/Plex.sv", "fpga/Plex_MiSTer/Plex.qsf",
         "fpga/Plex_MiSTer/files.qip",
         "fpga/Plex_MiSTer/rtl/foreign_widget.sv",
         "fpga/Plex_MiSTer/rtl/foreign_orphan.sv"],
        cwd=base, check=True, env=env,
    )
    subprocess.run(["git", "commit", "-qm", "foreign"], cwd=base, check=True, env=env)
    return base


def run_gate(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "check_rtl_module_instantiations.py"), *args],
        capture_output=True,
        text=True,
    )


def check_foreign_project_root() -> int:
    scratch = ROOT / "build" / "w-gate-o5-scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    cases = 0
    with tempfile.TemporaryDirectory(prefix="foreignroot-", dir=str(scratch)) as td:
        far = build_foreign_checkout(Path(td))

        # GREEN: a foreign tree with no manifests answers a structural question.
        proc = run_gate("--project-root", str(far), "--root", "emu", "--require", "foreign_widget")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "FOREIGN_PROJECT_ROOT" in proc.stdout, proc.stdout
        assert "policy was NOT applied" in proc.stdout, proc.stdout
        cases += 1

        # The numbers must describe the TARGET, not this checkout.  Without this
        # assertion --project-root could be a no-op and every result would still
        # look plausible, because both trees report rtl_modules=68.
        scope = proc.stdout.splitlines()[0]
        assert "rtl_modules=2" in scope, scope
        assert "rtl_files=2" in scope, scope  # untracked file must not count
        cases += 1

        # RED: this repo's modules do not exist over there.
        proc = run_gate("--project-root", str(far), "--root", "emu", "--require", "h264_decode_core")
        assert proc.returncode == 1 and "not exist" in proc.stderr, proc.stdout + proc.stderr
        cases += 1

        # RED: an orphan in the foreign tree is unreachable, not excused.
        proc = run_gate("--project-root", str(far), "--root", "emu", "--require", "foreign_orphan")
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "REQUIRED_RTL_MODULE_UNREACHABLE foreign_orphan" in proc.stderr, proc.stderr
        cases += 1

    # SKIP: a directory that is not a MiSTerPlex checkout is unscored, never green.
    proc = run_gate("--project-root", str(ROOT / "docs"))
    assert proc.returncode == 77, proc.stdout + proc.stderr
    assert proc.stdout.splitlines()[0].startswith("Scope: 0"), proc.stdout
    cases += 1
    return cases


def main() -> int:
    scope = len(MODULES)
    print(f"Scope: synthetic_modules={scope} cases=7", flush=True)
    assert scope > 0, "Scope: 0 cannot claim a PASS"

    # GREEN: product root, module present.
    rc, out, _ = call(["writeback"], rtl.PRODUCT_ROOT)
    assert rc == 0, out
    assert "REQUIRED_RTL_MODULE_PRODUCT_REACHABLE writeback" in out, out
    assert "product_reachable=yes" in out, out

    # RED: product root, module absent from the product graph.
    rc, _, err = call(["core_only_helper"], rtl.PRODUCT_ROOT)
    assert rc == 1, "requiring an absent module from the product root must fail"
    assert "REQUIRED_RTL_MODULE_UNREACHABLE core_only_helper" in err, err
    assert "instantiating_parents=orphan_core" in err, err

    # RED: the exact w-deblock-seam shape. The requirement is satisfiable inside
    # the subtree, but the root is an orphan, so the claim is refused.
    rc, _, err = call(["writeback"], "orphan_core")
    assert rc == 1, "a requirement rooted at a non-product module must not pass silently"
    assert "NON_PRODUCT_ROOT orphan_core product_reachable=no" in err, err
    assert "instantiating_parents=<none>" in err, err
    assert "subtree claim, not product presence" in err, err

    # AMBER: same shape, explicit opt-in. Allowed, but never labelled product.
    rc, out, err = call(["writeback"], "orphan_core", allow=True)
    assert rc == 0, err
    assert "SUBTREE_ONLY_CLAIM writeback root=orphan_core" in out, out
    assert "product_reachable=no" in out, out
    assert "REQUIRED_RTL_MODULE_PRODUCT_REACHABLE" not in out, out

    # RED: non-existent root and non-existent requirement are both hard fails.
    rc, _, err = call(["writeback"], "no_such_module")
    assert rc == 1 and "not exist" in err, err
    rc, _, err = call(["no_such_child"], rtl.PRODUCT_ROOT)
    assert rc == 1 and "not exist" in err, err

    # The guard must bite even when the orphan root is *itself* required.
    rc, _, err = call(["orphan_core"], "orphan_core")
    assert rc == 1, "self-rooted orphan requirement must not pass"

    # End-to-end: the real repository must always announce Scope first.
    proc = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "check_rtl_module_instantiations.py"),
         "--root", "h264_decode_skeleton", "--require", "h264_deblock_writeback_ctrl"],
        capture_output=True,
        text=True,
    )
    assert proc.stdout.splitlines()[0].startswith("Scope: "), proc.stdout
    assert proc.returncode == 1, (
        "h264_decode_skeleton is dead code; a requirement rooted there must fail\n"
        + proc.stdout + proc.stderr
    )
    assert "NON_PRODUCT_ROOT h264_decode_skeleton" in proc.stderr, proc.stderr

    foreign_cases = check_foreign_project_root()

    print(f"RTL_REQUIRE_ROOT_GUARD_OK cases=7 e2e=1 foreign_project_root={foreign_cases}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
