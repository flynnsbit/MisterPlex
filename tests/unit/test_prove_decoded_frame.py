#!/usr/bin/env python3
"""Unit gate for scripts/prove_decoded_frame.py — the decode-vs-painter oracle.

Runs the hermetic red/green self-test (no hardware, no MiSTer, no capture
device) and additionally asserts the calibration margin that makes the verdict
trustworthy: the worst true-decode score must sit far above the threshold and
the best painter score far below it.

Rationale: the fleet has repeatedly mistaken "something is on screen" for
"decoding happened".  W-E2E-O5 measured that the checked-in hardware decode
golden is actually a capture of the Plex chevron idle screen.  This gate exists
so that a painter can never again be recorded as a decode.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "prove_decoded_frame.py"

sys.path.insert(0, str(ROOT / "scripts"))

failures: list[str] = []
checks = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global checks
    checks += 1
    if cond:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name} {detail}")
        failures.append(name)


def main() -> int:
    check("gate script exists", GATE.exists(), str(GATE))
    if not GATE.exists():
        print(f"\n{checks - len(failures)}/{checks} checks passed")
        return 1

    proc = subprocess.run([sys.executable, str(GATE), "--self-test"],
                          capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    check("self-test exits 0", proc.returncode == 0, f"rc={proc.returncode}\n{out}")
    check("self-test reports SELF_TEST_OK", "SELF_TEST_OK" in out)

    # The self-test must actually exercise both directions.  A self-test with no
    # red cases would be exactly the class of vacuous gate w-audit found 24 of.
    check("self-test has a true-decode green", "true-decode-clean" in out)
    check("self-test rejects the chevron idle golden", "chevron-idle-golden" in out)
    check("self-test rejects a real decoder-less capture",
          "live-capture-no-decoder-core" in out)
    check("self-test refuses flat black", "flat-black" in out)
    check("self-test refuses a degenerate reference", "degenerate-reference" in out)
    check("self-test rejects structural scrambles",
          "mirrored-reference" in out and "block-shuffled-reference" in out)

    # Calibration margin: verdicts are only meaningful if positives and
    # negatives are well separated around the threshold.
    import prove_decoded_frame as pdf  # noqa: E402
    from PIL import Image
    import numpy as np
    import tempfile

    ref_src = ROOT / "tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264"
    chevron = ROOT / ("tests/fixtures/hw_visual/"
                      "plex_real_baseline_320x240_57674f2e_mjpeg720_golden.png")
    check("reference fixture present", ref_src.exists(), str(ref_src))
    check("chevron golden fixture present", chevron.exists(), str(chevron))

    if ref_src.exists() and chevron.exists():
        with tempfile.TemporaryDirectory(dir=str(ROOT / "artifacts")) as td:
            ref = pdf.decode_reference(ref_src, Path(td))

        pos = pdf.score([pdf._pillarbox(ref)] * 3, ref)
        c = np.asarray(Image.open(chevron).convert("RGB"))
        neg = pdf.score([c, c.copy(), c.copy()], ref)

        check("true decode scores above threshold with margin",
              pos["ncc"] >= pdf.NCC_THRESHOLD + 0.15,
              f"ncc={pos['ncc']} threshold={pdf.NCC_THRESHOLD}")
        check("chevron painter scores below threshold with margin",
              neg["ncc"] <= pdf.NCC_THRESHOLD - 0.15,
              f"ncc={neg['ncc']} threshold={pdf.NCC_THRESHOLD}")
        check("positive and negative are widely separated",
              pos["ncc"] - neg["ncc"] >= 0.5,
              f"pos={pos['ncc']} neg={neg['ncc']}")

        # The measured contradiction that motivated this gate: the checked-in
        # "hardware decode golden" does not agree with the decode of the very
        # bitstream its provenance names.
        check("checked-in hw golden does NOT agree with its own reference decode",
              neg["verdict"] == pdf.NOT_DECODED, f"verdict={neg['verdict']}")

    # The live --device path is not covered by --self-test (it needs hardware),
    # so its call into capture_preflight is verified structurally instead.  An
    # earlier revision shipped these arguments transposed and the self-test
    # could not see it.
    import inspect
    sig = inspect.signature(pdf.cp.grab_n_frames)
    names = list(sig.parameters)
    check("grab_n_frames arg order is (dev,fmt,size,fps,n,out_dir,...)",
          names[:6] == ["dev", "fmt", "size", "fps", "n", "out_dir"], f"got {names[:6]}")
    try:
        sig.bind("/dev/video0", "mjpeg", "1280x720", "60", 8, Path("/x"))
        bound_ok, bind_err = True, ""
    except TypeError as e:
        bound_ok, bind_err = False, str(e)
    check("live-capture call signature binds", bound_ok, bind_err)
    check("live path passes frame count before out_dir",
          "fps, args.frames, Path(td)" in GATE.read_text(),
          "grab_n_frames call in --device path has transposed args")

    print(f"\n{checks - len(failures)}/{checks} checks passed")
    if failures:
        print("FAILURES: " + ", ".join(failures))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
