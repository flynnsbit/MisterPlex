#!/usr/bin/env python3
"""hdmi_judder_cadence — classify glass-side frame-hold cadence (judder harness).

Product question (parent): 24 fps 3:2 pulldown vs 30 fps 2:1 vs pathological
2,2,2,4 (24 content through a 30 Hz core then 60 Hz glass). Screenshots cannot
tell these apart; a multi-frame capture can.

Inputs
  --frames-dir DIR   ordered f_*.png / frame_*.png / *.png
  --video PATH       decode via ffmpeg (warm-up already discarded upstream)
  --synthetic PATTERN  build known holds in-memory (selftest / red twin)

Outputs (stdout key=value + optional JSON):
  RUN_LENGTHS=3,2,3,2,...
  PATTERN=CLEAN_3_2|CLEAN_2_1|PATH_2_2_2_4|FROZEN|STATIC_FIELD|IRREGULAR|...
  JUDDER=0..        lower = closer to a clean telecine; FROZEN/STATIC → n/a flag
  MOTION_FRAC=...   mean fraction of pixels that change on NEW steps
  N_FRAMES= N_NEW= N_RUNS=

Exit:
  0  classified (including FROZEN/STATIC — those are valid measurements)
  2  usage / bad args
  3  decode/IO failure
  4  degenerate capture (too few frames, empty) — not a cadence claim

Static / frozen content must NOT score as infinite judder (naive trap).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

import numpy as np

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None  # type: ignore


# --- knobs (documented; red-twin locks behaviour) --------------------------------
# Mean abs luma delta below this ⇒ same content (repeat).
DEFAULT_LUMA_EPS = 2.5
# Fraction of pixels with |d| > pixel_eps that must flip to call NEW.
DEFAULT_PIX_FRAC = 0.002  # 0.2% of frame — catches hard-edge bar, ignores noise
DEFAULT_PIX_EPS = 12.0
# Minimum frames after warm-up to attempt classification.
MIN_FRAMES = 8
# Hold length that flags "pathological long hold" in mixed 2/3 streams.
LONG_HOLD = 4


@dataclass
class CadenceResult:
    n_frames: int
    n_new: int
    n_runs: int
    run_lengths: List[int]
    pattern: str
    judder: float
    judder_note: str
    motion_frac_mean: float
    luma_eps: float
    pix_frac_thr: float
    frozen: bool
    static_field: bool
    dropped_hint: int
    residual_2_1: float
    residual_3_2: float
    residual_224: float
    raw_is_new: List[int]

    def emit_text(self) -> None:
        rl = ",".join(str(x) for x in self.run_lengths) if self.run_lengths else ""
        print(f"N_FRAMES={self.n_frames}")
        print(f"N_NEW={self.n_new}")
        print(f"N_RUNS={self.n_runs}")
        print(f"RUN_LENGTHS={rl}")
        print(f"PATTERN={self.pattern}")
        print(f"JUDDER={self.judder:.6f}")
        print(f"JUDDER_NOTE={self.judder_note}")
        print(f"MOTION_FRAC={self.motion_frac_mean:.6f}")
        print(f"FROZEN={int(self.frozen)}")
        print(f"STATIC_FIELD={int(self.static_field)}")
        print(f"DROPPED_HINT={self.dropped_hint}")
        print(f"RESIDUAL_2_1={self.residual_2_1:.6f}")
        print(f"RESIDUAL_3_2={self.residual_3_2:.6f}")
        print(f"RESIDUAL_224={self.residual_224:.6f}")
        print(f"LUMA_EPS={self.luma_eps}")
        print(f"PIX_FRAC_THR={self.pix_frac_thr}")


def _luma(rgb: np.ndarray) -> np.ndarray:
    # rgb uint8 HxWx3 → float luma
    r = rgb[..., 0].astype(np.float32)
    g = rgb[..., 1].astype(np.float32)
    b = rgb[..., 2].astype(np.float32)
    return 0.299 * r + 0.587 * g + 0.114 * b


def load_png(path: Path) -> np.ndarray:
    if Image is None:
        raise RuntimeError("Pillow required")
    return np.array(Image.open(path).convert("RGB"), dtype=np.uint8)


def list_frame_paths(d: Path) -> List[Path]:
    files = sorted(d.glob("*.png"))
    if not files:
        return []
    # Prefer f_0001 / frame_0001 style numeric sort when present
    def key(p: Path):
        m = re.search(r"(\d+)", p.stem)
        return (int(m.group(1)) if m else 0, p.name)

    return sorted(files, key=key)


def frames_from_dir(d: Path) -> List[np.ndarray]:
    paths = list_frame_paths(d)
    if not paths:
        raise FileNotFoundError(f"no png frames in {d}")
    return [load_png(p) for p in paths]


def frames_from_video(path: Path, max_frames: int = 300) -> List[np.ndarray]:
    """Decode video to RGB frames via ffmpeg (no v4l2 here)."""
    td = tempfile.mkdtemp(prefix="judder_dec_")
    out_pat = os.path.join(td, "f_%04d.png")
    cmd = [
        "ffmpeg", "-v", "error", "-i", str(path),
        "-frames:v", str(max_frames), "-y", out_pat,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"ffmpeg decode failed rc={r.returncode}: {r.stderr[:200]}")
    try:
        return frames_from_dir(Path(td))
    finally:
        # best-effort cleanup
        for p in Path(td).glob("*"):
            try:
                p.unlink()
            except OSError:
                pass
        try:
            os.rmdir(td)
        except OSError:
            pass


def synth_moving_bar_frames(
    holds: Sequence[int],
    *,
    w: int = 160,
    h: int = 90,
    bar_w: int = 12,
) -> List[np.ndarray]:
    """Each hold entry is how many 60 Hz slots one unique bar position occupies.

    Bar steps +bar_w each NEW content frame so consecutive unique frames differ
    strongly; repeats are bit-identical.
    """
    frames: List[np.ndarray] = []
    x = 4
    for hold in holds:
        img = np.zeros((h, w, 3), dtype=np.uint8)
        img[:] = (16, 16, 24)
        x0 = int(x) % max(1, w - bar_w)
        img[:, x0 : x0 + bar_w, :] = (240, 240, 240)
        for _ in range(int(hold)):
            frames.append(img.copy())
        x += bar_w + 3
    return frames


def synth_static_frames(n: int = 60, w: int = 160, h: int = 90) -> List[np.ndarray]:
    img = np.zeros((h, w, 3), dtype=np.uint8)
    img[:] = (40, 40, 48)
    img[h // 2 - 4 : h // 2 + 4, w // 2 - 20 : w // 2 + 20] = (200, 40, 40)
    return [img.copy() for _ in range(n)]


def synth_partial_motion_frames(
    n_unique: int = 30,
    hold: int = 2,
    w: int = 160,
    h: int = 90,
) -> List[np.ndarray]:
    """Motion only in a small corner; rest of field static — detector must still see NEW."""
    frames: List[np.ndarray] = []
    base = np.zeros((h, w, 3), dtype=np.uint8)
    base[:] = (20, 24, 28)
    for i in range(n_unique):
        img = base.copy()
        # 8×8 block marches along top edge only (~0.4% of 160×90)
        x0 = 2 + (i * 5) % (w - 10)
        img[2:10, x0 : x0 + 8, :] = (0, 220, 255)
        for _ in range(hold):
            frames.append(img.copy())
    return frames


def pair_is_new(
    a: np.ndarray,
    b: np.ndarray,
    *,
    luma_eps: float,
    pix_eps: float,
    pix_frac_thr: float,
) -> Tuple[bool, float, float]:
    """Return (is_new, mean_abs_luma, frac_pixels_changed)."""
    la = _luma(a)
    lb = _luma(b)
    d = np.abs(la - lb)
    mean_abs = float(d.mean())
    frac = float((d > pix_eps).mean())
    # NEW if either global luma shift or enough pixels flip (hard edge / partial).
    is_new = (mean_abs >= luma_eps) or (frac >= pix_frac_thr)
    return is_new, mean_abs, frac


def analyze_frames(
    frames: Sequence[np.ndarray],
    *,
    luma_eps: float = DEFAULT_LUMA_EPS,
    pix_eps: float = DEFAULT_PIX_EPS,
    pix_frac_thr: float = DEFAULT_PIX_FRAC,
) -> CadenceResult:
    n = len(frames)
    if n < MIN_FRAMES:
        raise ValueError(f"need >= {MIN_FRAMES} frames, got {n}")

    is_new_flags: List[int] = [1]  # frame 0 is start of first run
    motion_on_new: List[float] = []
    mean_deltas: List[float] = []

    for i in range(1, n):
        new, mad, frac = pair_is_new(
            frames[i - 1],
            frames[i],
            luma_eps=luma_eps,
            pix_eps=pix_eps,
            pix_frac_thr=pix_frac_thr,
        )
        is_new_flags.append(1 if new else 0)
        mean_deltas.append(mad)
        if new:
            motion_on_new.append(frac)

    # Run-length encode: lengths of consecutive equal-content holds.
    runs: List[int] = []
    cur = 1
    for flag in is_new_flags[1:]:
        if flag == 0:
            cur += 1
        else:
            runs.append(cur)
            cur = 1
    runs.append(cur)

    n_new = int(sum(is_new_flags))
    frozen = n_new <= 1  # only first frame marked new, rest repeats
    # Static field == frozen content. Do NOT use mean luma alone: partial-frame
    # motion (small ROI) has tiny global mean but real NEW steps and clean holds.
    # A naive "low global motion ⇒ static" path is exactly the trap we refuse.
    global_motion = float(np.mean(mean_deltas)) if mean_deltas else 0.0
    static_field = frozen

    residual_21 = _residual_constant(runs, 2)
    residual_32 = _residual_32(runs)
    residual_224 = _residual_224(runs)

    pattern, judder, note = _classify(
        runs,
        frozen=frozen,
        static_field=static_field,
        residual_21=residual_21,
        residual_32=residual_32,
        residual_224=residual_224,
        n_frames=n,
    )

    # Dropped-frame hint: isolated run of 1 inside an otherwise 2/3 stream, or
    # a sudden 5+ hold, suggests a missing capture slot (not definitive).
    dropped_hint = 0
    if not frozen and len(runs) >= 4:
        dropped_hint += sum(1 for r in runs if r == 1)
        dropped_hint += sum(1 for r in runs if r >= 5)

    return CadenceResult(
        n_frames=n,
        n_new=n_new,
        n_runs=len(runs),
        run_lengths=runs,
        pattern=pattern,
        judder=judder,
        judder_note=note,
        motion_frac_mean=float(np.mean(motion_on_new)) if motion_on_new else 0.0,
        luma_eps=luma_eps,
        pix_frac_thr=pix_frac_thr,
        frozen=frozen,
        static_field=static_field,
        dropped_hint=dropped_hint,
        residual_2_1=residual_21,
        residual_3_2=residual_32,
        residual_224=residual_224,
        raw_is_new=is_new_flags,
    )


def _residual_constant(runs: Sequence[int], k: int) -> float:
    if not runs:
        return 999.0
    return float(np.mean([(r - k) ** 2 for r in runs]))


def _residual_32(runs: Sequence[int]) -> float:
    """MSE to ideal alternating 3,2 or 2,3 (choose better phase)."""
    if not runs:
        return 999.0
    best = 1e9
    for phase in (0, 1):
        # phase 0 → 3,2,3,2...; phase 1 → 2,3,2,3...
        err = []
        for i, r in enumerate(runs):
            expect = 3 if ((i + phase) % 2 == 0) else 2
            if phase == 1:
                expect = 2 if (i % 2 == 0) else 3
            err.append((r - expect) ** 2)
        best = min(best, float(np.mean(err)))
    return best


def _residual_224(runs: Sequence[int]) -> float:
    """MSE to repeating 2,2,2,4."""
    if not runs:
        return 999.0
    pat = (2, 2, 2, 4)
    best = 1e9
    for off in range(4):
        err = [((r - pat[(i + off) % 4]) ** 2) for i, r in enumerate(runs)]
        best = min(best, float(np.mean(err)))
    return best


def _classify(
    runs: Sequence[int],
    *,
    frozen: bool,
    static_field: bool,
    residual_21: float,
    residual_32: float,
    residual_224: float,
    n_frames: int,
) -> Tuple[str, float, str]:
    # Static / frozen: judder is not ranked — report 0 with explicit note so a
    # naive "variance of holds" detector cannot scream infinite judder.
    if frozen or static_field:
        return (
            "FROZEN" if frozen else "STATIC_FIELD",
            0.0,
            "no_content_change_judder_undefined_treated_zero",
        )

    # Prefer clean patterns when residual is tiny.
    # Thresholds locked by synthetic red-twin (exact integer holds).
    thr_clean = 0.05
    thr_path = 0.05

    if residual_21 <= thr_clean and residual_21 <= residual_32 and residual_21 <= residual_224:
        return "CLEAN_2_1", residual_21, "all_holds_near_2"
    if residual_32 <= thr_clean and residual_32 <= residual_21:
        return "CLEAN_3_2", residual_32, "alternating_holds_3_2"
    if residual_224 <= thr_path and residual_224 < residual_21 and residual_224 < residual_32:
        # Pathological is "a" cadence — judder scalar = distance from best clean.
        judder = min(residual_21, residual_32)
        return "PATH_2_2_2_4", judder, "matches_2_2_2_4_not_clean_telecine"

    # Irregular: judder = distance to nearest clean family
    judder = min(residual_21, residual_32)
    # Long-hold heavy streams get a bump so 2,2,2,4-ish ranks worse than clean.
    long_frac = sum(1 for r in runs if r >= LONG_HOLD) / max(1, len(runs))
    judder = judder + 0.5 * long_frac
    if long_frac >= 0.15 and residual_224 < 1.0:
        return "PATH_2_2_2_4", judder, "long_holds_suggest_224_family"
    return "IRREGULAR", judder, "nearest_clean_residual"


def expand_pattern_token(token: str, cycles: int) -> List[int]:
    token = token.strip().lower().replace("-", "_")
    if token in ("3_2", "32", "3:2", "telecine", "24_60"):
        unit = [3, 2]
    elif token in ("2_1", "21", "2:1", "30_60", "dup"):
        unit = [2]
    elif token in ("2_2_2_4", "224", "path", "pathological"):
        unit = [2, 2, 2, 4]
    elif token in ("static", "frozen"):
        return [cycles * 8]  # one long hold; caller may use synth_static instead
    else:
        # comma list e.g. 2,2,2,4,2,2,2,4
        if re.fullmatch(r"[0-9]+(,[0-9]+)+", token):
            unit = [int(x) for x in token.split(",")]
        else:
            raise ValueError(f"unknown synthetic pattern {token!r}")
    out: List[int] = []
    for _ in range(cycles):
        out.extend(unit)
    return out


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--frames-dir", type=Path, help="directory of ordered PNGs")
    src.add_argument("--video", type=Path, help="video file to decode")
    src.add_argument(
        "--synthetic",
        type=str,
        help="3_2 | 2_1 | 2_2_2_4 | static | partial_motion | custom 2,2,2,4",
    )
    ap.add_argument("--cycles", type=int, default=12, help="synthetic pattern cycles")
    ap.add_argument("--luma-eps", type=float, default=DEFAULT_LUMA_EPS)
    ap.add_argument("--pix-eps", type=float, default=DEFAULT_PIX_EPS)
    ap.add_argument("--pix-frac", type=float, default=DEFAULT_PIX_FRAC)
    ap.add_argument("--max-frames", type=int, default=300)
    ap.add_argument("--json-out", type=Path, default=None)
    ap.add_argument("--expect-pattern", type=str, default=None,
                    help="if set, exit 1 when PATTERN != expect (red-twin gate)")
    ap.add_argument("--write-frames", type=Path, default=None,
                    help="with --synthetic: also dump PNGs here (frames-dir round-trip)")
    args = ap.parse_args(argv)

    try:
        if args.synthetic:
            tok = args.synthetic.strip().lower()
            if tok in ("static", "frozen"):
                frames = synth_static_frames(n=max(MIN_FRAMES, args.cycles * 4))
            elif tok in ("partial", "partial_motion"):
                frames = synth_partial_motion_frames(n_unique=max(8, args.cycles), hold=2)
            else:
                holds = expand_pattern_token(args.synthetic, args.cycles)
                frames = synth_moving_bar_frames(holds)
            if args.write_frames is not None:
                if Image is None:
                    raise RuntimeError("Pillow required for --write-frames")
                args.write_frames.mkdir(parents=True, exist_ok=True)
                for i, fr in enumerate(frames, 1):
                    Image.fromarray(fr).save(args.write_frames / f"f_{i:04d}.png")
        elif args.frames_dir:
            frames = frames_from_dir(args.frames_dir)
        else:
            frames = frames_from_video(args.video, max_frames=args.max_frames)
    except FileNotFoundError as e:
        print(f"IO_ERROR={e}", file=sys.stderr)
        return 3
    except Exception as e:  # noqa: BLE001 — surface decode errors as rc=3
        print(f"IO_ERROR={e}", file=sys.stderr)
        return 3

    if len(frames) < MIN_FRAMES:
        print(f"DEGENERATE n_frames={len(frames)} min={MIN_FRAMES}", file=sys.stderr)
        return 4

    try:
        result = analyze_frames(
            frames,
            luma_eps=args.luma_eps,
            pix_eps=args.pix_eps,
            pix_frac_thr=args.pix_frac,
        )
    except ValueError as e:
        print(f"DEGENERATE {e}", file=sys.stderr)
        return 4

    result.emit_text()
    if args.json_out:
        payload = asdict(result)
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(payload, indent=2) + "\n")

    if args.expect_pattern:
        exp = args.expect_pattern.strip().upper()
        got = result.pattern.upper()
        # Allow FROZEN and STATIC_FIELD to match expect STATIC
        ok = got == exp or (exp in ("STATIC", "FROZEN", "STATIC_FIELD") and got in ("FROZEN", "STATIC_FIELD"))
        if not ok:
            print(f"EXPECT_FAIL want={exp} got={got}", file=sys.stderr)
            return 1
        print(f"EXPECT_OK pattern={got}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
