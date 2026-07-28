#!/usr/bin/env python3
"""Red/green for the decode core-subtree gate.

Parent ruling 2026-07-28: plain `emu` reachability is masked by `decode_stub`,
so it is not evidence of product decode capability. This test proves the gate
that enforces the distinction can actually fail, in both ratchet directions.

Structural red-proofs against the real RTL were performed by mutation and are
recorded in docs/test-decode-product-presence-audit.md; this file keeps a
repeatable version that does not edit tracked RTL.
"""
from __future__ import annotations

import contextlib
import io
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_decode_core_subtree as gate  # noqa: E402

SCRATCH = ROOT / "build" / "core-subtree-gate-test"


class FakeMod:
    def __init__(self, path: Path) -> None:
        self.path = path


def synthetic() -> tuple[dict[str, set[str]], dict[str, FakeMod], set[str]]:
    """emu -> stream_path -> {core, stub}; MC lives only under the stub."""
    graph = {
        "emu": {"stream_path"},
        "stream_path": {"h264_decode_core", "decode_stub"},
        "h264_decode_core": {"mv_pred"},
        "decode_stub": {"inter_mc", "dpb_ref"},
    }
    names = ["emu", "stream_path", "h264_decode_core", "decode_stub", "mv_pred", "inter_mc", "dpb_ref"]
    modules = {n: FakeMod(gate.rtl.RTL_DIR / f"{n}.sv") for n in names}
    emu_reachable = {"stream_path", "h264_decode_core", "decode_stub", "mv_pred", "inter_mc", "dpb_ref"}
    return graph, modules, emu_reachable


def run_main(argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = gate.main(argv)
    except SystemExit as exc:
        rc = int(exc.code or 0)
    return rc, out.getvalue(), err.getvalue()


def main() -> int:
    graph, modules, emu_reachable = synthetic()
    print(f"Scope: synthetic_modules={len(modules)} real_gate_invocations=3", flush=True)
    assert modules, "Scope: 0 cannot claim a PASS"

    # --- classify(): the stub must not lend product evidence to the core -----
    core, masking, _ = gate.classify(graph, modules, emu_reachable)
    assert "mv_pred" in core, core
    assert "inter_mc" not in core, "a stub-only module must never enter the core subtree"
    assert "dpb_ref" not in core, core
    assert {"inter_mc", "dpb_ref", "decode_stub"} <= masking, masking

    # A decoder that is not in the product lends nothing to anything.
    orphan_core, _, _ = gate.classify(graph, modules, emu_reachable - {"h264_decode_core"})
    assert orphan_core == set(), (
        "a non-product decoder must expose an empty subtree, not a subtree of "
        f"borrowed evidence: {sorted(orphan_core)}"
    )

    # --- real tree: green against the committed ratchet ----------------------
    rc, out, err = run_main([])
    assert out.splitlines()[0].startswith("Scope: "), out
    assert rc == 0, out + err
    assert "DECODE_CORE_SUBTREE_OK" in out, out
    baseline_masked = sorted(
        line.split()[1] for line in out.splitlines() if line.startswith("STUB_MASKED_MODULE ")
    )
    assert baseline_masked, "Scope: 0 stub-masked modules would make the ratchet vacuous here"

    # --- RED 1: an undeclared stub-masked module (new masking) ---------------
    SCRATCH.mkdir(parents=True, exist_ok=True)
    real_manifest = gate.STUB_MASKED_MANIFEST
    text = real_manifest.read_text()
    dropped = baseline_masked[0]
    shortened = SCRATCH / "missing_entry.txt"
    shortened.write_text(
        "\n".join(
            line for line in text.splitlines()
            if not line.startswith(f"{dropped}:")
        )
        + "\n"
    )
    gate.STUB_MASKED_MANIFEST = shortened
    try:
        rc, out, err = run_main([])
    finally:
        gate.STUB_MASKED_MANIFEST = real_manifest
    assert rc == 1, "an undeclared stub-masked module must fail the gate"
    assert f"STUB_MASKED_UNDECLARED {dropped}" in err, err

    # --- RED 2: a stale declaration (masking that has been fixed) ------------
    stale = SCRATCH / "stale_entry.txt"
    stale.write_text(text.rstrip("\n") + "\nh264_deblock_bs: stale ratchet entry\n")
    gate.STUB_MASKED_MANIFEST = stale
    try:
        rc, out, err = run_main([])
    finally:
        gate.STUB_MASKED_MANIFEST = real_manifest
    assert rc == 1, "a stale ratchet declaration must fail the gate, not be tolerated"
    assert "STUB_MASKED_STALE h264_deblock_bs" in err, err

    # --- green restored ------------------------------------------------------
    rc, out, _ = run_main([])
    assert rc == 0 and "DECODE_CORE_SUBTREE_OK" in out, out

    # --- the standalone script must also announce Scope first ----------------
    proc = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "check_decode_core_subtree.py")],
        capture_output=True,
        text=True,
    )
    assert proc.stdout.splitlines()[0].startswith("Scope: "), proc.stdout
    assert proc.returncode == 0, proc.stdout + proc.stderr

    print(
        "DECODE_CORE_SUBTREE_GATE_TEST_OK synthetic_cases=4 "
        f"ratchet_reds=2 baseline_stub_masked={len(baseline_masked)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
