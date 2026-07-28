#!/usr/bin/env python3
"""Prove that DECODED frames are on screen — and refuse to be fooled by a painter.

Why this exists
---------------
MiSTerPlex has repeatedly shipped bitstreams that paint something plausible on
screen without decoding anything.  Post-fit hierarchy proved the deployed core
``fb4bad84`` contains no decoder at all; only the retired ``decode_stub``
painter.  Worse, the fixture used as the *hardware decode golden*
(``plex_real_baseline_320x240_57674f2e_mjpeg720_golden.png``) was measured by
W-E2E-O5 to be a capture of the Plex chevron **idle screen**, not decoded video:
its declared "MB0" ROI is flat background (9 distinct colours, std 5.35) while
the bitstream it claims to show decodes to bright colour bars (luma std 65.5,
MB0 std 53.2).

So "the screen has content" is NOT evidence of decoding, and neither is
"it matches the golden".  This gate takes the only position that cannot be
faked by a painter:

    A core has decoded a frame only if what is on screen AGREES WITH THE
    HOST DECODE OF THE EXACT BITSTREAM THAT WAS PUSHED.

A painter cannot match a reference it has never seen.

Verdicts (exit codes)
---------------------
0  DECODE_PROVEN  captured picture agrees with the host-decoded reference
1  NOT_DECODED    valid, non-flat picture that does NOT agree with the reference
2  REFUSE         cannot score (no signal / flat / degenerate reference)

A skip is never a pass.  A flat or absent signal REFUSES (2); it never returns 0
and never returns 1, because a black screen tells you nothing about decoding.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import capture_preflight as cp  # noqa: E402

# Agreement threshold on luma Pearson correlation between the captured picture
# region and the host-decoded reference.  Calibrated in --self-test: the true
# positive scores far above this and every painter/idle-screen case far below.
NCC_THRESHOLD: float = 0.75

# A reference with no structure would make anything "match".  Refuse instead.
REF_MIN_STD: float = 10.0

# Border rows/cols whose std is below this are treated as letterbox/pillarbox.
ACTIVE_EPS: float = 3.0

DECODE_PROVEN = "DECODE_PROVEN"
NOT_DECODED = "NOT_DECODED"
REFUSE = "REFUSE"

# States that carry enough picture information to score against a reference.
# A one-frame decode is legitimately frozen, so STALE_CAPTURE must be scoreable.
SCOREABLE_STATES = ("CONTENT_PRESENT", "STALE_CAPTURE")

RC = {DECODE_PROVEN: 0, NOT_DECODED: 1, REFUSE: 2}


def luma(frame: np.ndarray) -> np.ndarray:
    """BT.601 luma from an RGB uint8 frame."""
    f = frame.astype(np.float64)
    return 0.299 * f[..., 0] + 0.587 * f[..., 1] + 0.114 * f[..., 2]


def load_png(path: Path) -> np.ndarray:
    from PIL import Image

    return np.asarray(Image.open(path).convert("RGB"))


def decode_reference(path: Path, workdir: Path) -> np.ndarray:
    """Host-decode frame 0 of an Annex-B stream; the trusted oracle."""
    if path.suffix.lower() in {".png", ".bmp", ".ppm"}:
        return load_png(path)
    out = workdir / "ref_frame0.png"
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-frames:v", "1", "-y", str(out)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not out.exists():
        raise RuntimeError(f"host decode of {path} failed: {proc.stderr.strip()[:400]}")
    return load_png(out)


def active_box(frame: np.ndarray) -> tuple[int, int, int, int]:
    """Bounding box of the structured picture area, excluding flat borders."""
    y = luma(frame)
    row_std = y.std(axis=1)
    col_std = y.std(axis=0)
    rows = np.flatnonzero(row_std > ACTIVE_EPS)
    cols = np.flatnonzero(col_std > ACTIVE_EPS)
    if rows.size == 0 or cols.size == 0:
        return 0, 0, frame.shape[1], frame.shape[0]
    return int(cols[0]), int(rows[0]), int(cols[-1]) + 1, int(rows[-1]) + 1


def resize_luma(y: np.ndarray, w: int, h: int) -> np.ndarray:
    from PIL import Image

    img = Image.fromarray(np.clip(y, 0, 255).astype(np.uint8))
    return np.asarray(img.resize((w, h), Image.BILINEAR)).astype(np.float64)


def ncc(a: np.ndarray, b: np.ndarray) -> float:
    """Pearson correlation; brightness/contrast invariant."""
    a = a.ravel() - a.mean()
    b = b.ravel() - b.mean()
    da, db = np.linalg.norm(a), np.linalg.norm(b)
    if da < 1e-9 or db < 1e-9:
        return 0.0
    return float(np.dot(a, b) / (da * db))


def score(captured: list[np.ndarray], reference: np.ndarray,
          ncc_threshold: float = NCC_THRESHOLD) -> dict:
    """Score captured frames against a host-decoded reference."""
    classification = cp.classify_signal(captured)
    state = classification["state"]

    result: dict = {
        "signal_state": state,
        "signal_note": classification.get("note", ""),
        "mean_luma": round(float(classification.get("mean_luma", 0.0)), 3),
        "spatial_std": round(float(classification.get("spatial_std", 0.0)), 3),
        "ncc_threshold": ncc_threshold,
        "denominator_frames": len(captured),
    }

    ref_y = luma(reference)
    ref_std = float(ref_y.std())
    result["reference_std"] = round(ref_std, 3)
    if ref_std < REF_MIN_STD:
        result["verdict"] = REFUSE
        result["reason"] = (
            f"reference is degenerate (luma std {ref_std:.2f} < {REF_MIN_STD}); "
            "a flat reference would match anything, so this cannot prove decode"
        )
        return result

    # Scoreable states carry real picture information.  STALE_CAPTURE is a
    # *frozen picture of real content* (classify_signal's own definition), which
    # is exactly what pushing a one-frame .264 produces — refusing it would make
    # this gate unable to score its primary use case.  BLACK_SIGNAL and
    # NO_SIGNAL carry no evidence either way and must never pass or fail.
    if state not in SCOREABLE_STATES:
        result["verdict"] = REFUSE
        result["reason"] = (
            f"signal state {state}: a flat or absent picture carries no evidence "
            "about decoding. Refusing rather than passing or failing."
        )
        return result

    frame = captured[-1]
    x0, y0, x1, y1 = active_box(frame)
    result["active_box"] = [x0, y0, x1 - x0, y1 - y0]
    cap_y = luma(frame)[y0:y1, x0:x1]
    if cap_y.size == 0:
        result["verdict"] = REFUSE
        result["reason"] = "no active picture region located"
        return result

    ref_scaled = resize_luma(ref_y, cap_y.shape[1], cap_y.shape[0])
    corr = ncc(cap_y, ref_scaled)
    result["ncc"] = round(corr, 4)

    if corr >= ncc_threshold:
        result["verdict"] = DECODE_PROVEN
        result["reason"] = (
            f"captured picture agrees with host decode (ncc {corr:.4f} >= {ncc_threshold})"
        )
    else:
        result["verdict"] = NOT_DECODED
        result["reason"] = (
            f"picture present but does NOT agree with host decode "
            f"(ncc {corr:.4f} < {ncc_threshold}). A painter or idle screen scores here."
        )
    return result


def _pillarbox(ref: np.ndarray, out_w: int = 1280, out_h: int = 720,
               noise: float = 0.0, seed: int = 7) -> np.ndarray:
    """Embed a reference into a 720p frame the way the rig would capture it."""
    from PIL import Image

    scale = min(out_w / ref.shape[1], out_h / ref.shape[0])
    w, h = int(ref.shape[1] * scale), int(ref.shape[0] * scale)
    img = np.asarray(Image.fromarray(ref).resize((w, h), Image.BILINEAR)).astype(np.float64)
    if noise > 0:
        img = img + np.random.default_rng(seed).normal(0, noise, img.shape)
    canvas = np.full((out_h, out_w, 3), 7.0)
    ox, oy = (out_w - w) // 2, (out_h - h) // 2
    canvas[oy:oy + h, ox:ox + w] = img
    return np.clip(canvas, 0, 255).astype(np.uint8)


def self_test(repo: Path) -> int:
    """Hermetic red/green proof. Every green ships with its red."""
    ref_src = repo / "tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264"
    chevron = repo / "tests/fixtures/hw_visual/plex_real_baseline_320x240_57674f2e_mjpeg720_golden.png"
    live = repo / "artifacts/e2e-o5/screen_now.png"

    if not ref_src.exists():
        print(f"SELF_TEST REFUSE: missing reference fixture {ref_src}")
        return 2

    failures: list[str] = []
    checks = 0

    with tempfile.TemporaryDirectory(dir=str(repo / "artifacts")) as td:
        ref = decode_reference(ref_src, Path(td))

        def expect(name: str, frames: list[np.ndarray], want: str,
                   reference: np.ndarray = ref) -> None:
            nonlocal checks
            checks += 1
            r = score(frames, reference)
            got = r["verdict"]
            detail = f"ncc={r.get('ncc')} signal={r.get('signal_state')}"
            if got == want:
                print(f"  PASS {name}: {got} ({detail})")
            else:
                print(f"  FAIL {name}: expected {want}, got {got} ({detail})")
                failures.append(name)

        # GREEN: a real decode, captured through a realistic rig path.
        expect("true-decode-clean", [_pillarbox(ref)] * 3, DECODE_PROVEN)
        expect("true-decode-noisy", [_pillarbox(ref, noise=6.0, seed=i) for i in range(3)],
               DECODE_PROVEN)

        # RED: the painter / idle screen must NOT be accepted.
        if chevron.exists():
            c = load_png(chevron)
            expect("chevron-idle-golden", [c, c.copy(), c.copy()], NOT_DECODED)
        if live.exists():
            l = load_png(live)
            expect("live-capture-no-decoder-core", [l, l.copy(), l.copy()], NOT_DECODED)

        # RED: flat pictures must REFUSE, never pass and never fail.
        black = np.full((720, 1280, 3), 7, dtype=np.uint8)
        expect("flat-black", [black, black.copy(), black.copy()], REFUSE)
        grey = np.full((720, 1280, 3), 128, dtype=np.uint8)
        expect("flat-grey-painter", [grey, grey.copy(), grey.copy()], REFUSE)

        # RED: a degenerate reference must REFUSE, not wave everything through.
        flat_ref = np.full((240, 320, 3), 100, dtype=np.uint8)
        expect("degenerate-reference", [_pillarbox(ref)] * 3, REFUSE, reference=flat_ref)

        # RED: same palette, different spatial structure.  This proves the gate
        # keys on picture STRUCTURE, not on a colour histogram.  (Note:
        # plex_visual_640x480_golden.png is deliberately NOT used here — it is
        # the same testsrc2 colour-bar content at another resolution, and the
        # gate correctly scores it as agreeing.)
        mirrored = ref[:, ::-1, :].copy()
        expect("mirrored-reference", [_pillarbox(mirrored)] * 3, NOT_DECODED)

        blocks = ref.copy()
        bh, bw = 16, 16
        rng = np.random.default_rng(11)
        tiles = [(r, c) for r in range(0, ref.shape[0] - bh + 1, bh)
                 for c in range(0, ref.shape[1] - bw + 1, bw)]
        shuffled = list(tiles)
        rng.shuffle(shuffled)
        for (dr, dc), (sr, sc) in zip(tiles, shuffled):
            blocks[dr:dr + bh, dc:dc + bw] = ref[sr:sr + bh, sc:sc + bw]
        expect("block-shuffled-reference", [_pillarbox(blocks)] * 3, NOT_DECODED)

    print(f"\nself-test: {checks - len(failures)}/{checks} checks passed")
    if failures:
        print("SELF_TEST_FAIL: " + ", ".join(failures))
        return 1
    print("SELF_TEST_OK")
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--reference", help="Annex-B .264 pushed to the core, or a reference PNG")
    p.add_argument("--captured", nargs="*", default=[], help="captured frame PNG(s)")
    p.add_argument("--device", help="capture live from this V4L2 node instead")
    p.add_argument("--frames", type=int, default=8)
    p.add_argument("--ncc-threshold", type=float, default=NCC_THRESHOLD)
    p.add_argument("--json-out")
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args(argv)

    repo = SCRIPT_DIR.parent

    if args.self_test:
        return self_test(repo)

    if not args.reference:
        print("REFUSE: --reference is required (the bitstream actually pushed)")
        return 2
    if not args.captured and not args.device:
        print("REFUSE: provide --captured frames or --device")
        return 2

    with tempfile.TemporaryDirectory(dir=str(repo / "artifacts")) as td:
        try:
            ref = decode_reference(Path(args.reference), Path(td))
        except RuntimeError as e:
            print(f"REFUSE: {e}")
            return 2

        if args.captured:
            frames = [load_png(Path(c)) for c in args.captured]
        else:
            fmt, size, fps = "mjpeg", "1280x720", "60"
            frames, _, _, _ = cp.grab_n_frames(
                args.device, fmt, size, fps, args.frames, Path(td))
        if not frames:
            print("REFUSE: no frames captured")
            return 2

        result = score(frames, ref, args.ncc_threshold)

    result["reference"] = str(args.reference)
    print(json.dumps(result, indent=2, sort_keys=True))
    print(f"\n{result['verdict']}: {result['reason']}")
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return RC[result["verdict"]]


if __name__ == "__main__":
    sys.exit(main())
