#!/usr/bin/env python3
"""Generate ramped-flash 480p soak fixture (sub-frame onset friendly).

Compared to RK8 (gen_avsync_blip soak): same geometry/rate/codec contract, but
the white flash is a multi-frame LINEAR luma ramp so tools/avsync_measure_hdmi.py
uses linear-interp onset (not the step guard that pins flash to a capture frame).

Contract (must match RK8 soak for A/B comparability):
  - 624x480 coded (DDR bank size; NOT 640x480)
  - 24.000 fps exact (r=24/1)
  - H.264 Constrained Baseline, no B-frames
  - AAC 48 kHz stereo
  - burned-in TREK24 n=<frame> on every frame
  - 360 s duration
  - flash+beep period 1.0 s

Ramp design (content domain @ 24.000 fps):
  - RAMP_FRAMES content frames of linear black->white (default 4)
  - peak hold 1 content frame, then black
  - Frames are generated in Python (constant luma per content frame staircase
    approximating a linear ramp). At capture 30 fps, 4 content frames ~ 166.7 ms
    ~ 5 capture samples of soft edge.
  - Per-capture-interval rise ~ contrast * (33.3/166.7) ~ 0.20*C < STEP_RISE_FRAC=0.70
    -> instrument path is linear-interp, not step (avsync_measure_hdmi.py detect_flashes)

Expected onset resolution (derivation, not a silicon measurement):
  - Step path quant: capture_frame_period = 1000/30 ~ 33.33 ms (parent measured
    flash_onset_n_interp:0 on RK8).
  - Linear path: thr crossing placed within one capture interval via
    ts = t0 + frac*(t1-t0), frac=(thr-y0)/(y1-y0).
  - Luma is 8-bit mean; with contrast C~200, frac granularity ~ 1/C ->
    theoretical ~ 33.33/200 ~ 0.17 ms. Practical floor is noise/compression/
    grabber, not the frame grid — expect a few ms, well under one capture frame.
  - State: expected_onset_resolution_ms ~ 2-5 ms practical (sub-frame); hard
    upper bound one capture interval if interp fails and falls back to step.

Beep: 1 kHz, 50 ms body, 1 ms linear attack envelope (sharp Goertzel edge).
"""
from __future__ import annotations

import argparse
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError as e:  # pragma: no cover
    raise SystemExit(f"Pillow required: {e}") from e

ROOT = Path(__file__).resolve().parents[1]
FONT_CANDIDATES = (
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
)


def pick_font(size: int):
    for f in FONT_CANDIDATES:
        if Path(f).is_file():
            return ImageFont.truetype(f, size=size)
    return ImageFont.load_default()


def write_pcm_sharp(
    path: Path,
    duration_s: float,
    sample_rate: int = 48000,
    *,
    beep_s: float = 0.050,
    attack_s: float = 0.001,
    freq_hz: float = 1000.0,
) -> None:
    """1 kHz beep every integer second; 1 ms linear attack then hold, zero else."""
    n = int(round(duration_s * sample_rate))
    with path.open("wb") as f:
        for i in range(n):
            t = i / sample_rate
            sec = int(math.floor(t))
            phase = t - sec
            if sec < int(duration_s) and 0.0 <= phase < beep_s:
                env = (phase / attack_s) if phase < attack_s else 1.0
                v = int(0.9 * 32767 * env * math.sin(2 * math.pi * freq_hz * t))
            else:
                v = 0
            f.write(struct.pack("<hh", v, v))


def frame_luma(n: int, fps: float, ramp_frames: int, peak_frames: int) -> int:
    """Return 0..255 full-frame luma for content frame index n."""
    frames_per_period = int(round(fps))  # 24 at 24.000
    k = n % frames_per_period
    if k < ramp_frames:
        # Linear staircase: frame 0 -> 1/R, ..., frame R-1 -> R/R = 1.0
        return int(round(255.0 * (k + 1) / float(ramp_frames)))
    if k < ramp_frames + peak_frames:
        return 255
    return 0


def gen_ramp_soak(
    out: Path,
    *,
    width: int = 624,
    height: int = 480,
    fps_num: int = 24,
    fps_den: int = 1,
    duration_s: float = 360.0,
    vbitrate: str = "1500k",
    audio_bitrate: str = "128k",
    label: str = "TREK24",
    ramp_frames: int = 4,
    peak_frames: int = 1,
) -> None:
    if width != 624 or height != 480:
        raise SystemExit(f"soak geometry must be 624x480 for RK8 parity, got {width}x{height}")
    if fps_num != 24 or fps_den != 1:
        raise SystemExit(f"soak fps must be 24/1 for RK8 parity, got {fps_num}/{fps_den}")
    if ramp_frames < 2:
        raise SystemExit("ramp_frames must be >= 2 for multi-frame edge")

    out.parent.mkdir(parents=True, exist_ok=True)
    fps_val = fps_num / float(fps_den)
    fps_str = f"{fps_num}/{fps_den}" if fps_den != 1 else str(fps_num)
    n_frames = int(round(duration_s * fps_val))
    ramp_s = ramp_frames / fps_val
    peak_s = peak_frames / fps_val
    flash_end_s = ramp_s + peak_s

    fs = max(14, height // 18)
    fs_flash = max(24, height // 10)
    font = pick_font(fs)
    font_flash = pick_font(fs_flash)

    if vbitrate[-1] in "kK":
        bufsize = str(int(vbitrate[:-1]) * 2) + "k"
    else:
        bufsize = vbitrate

    # Keep temp under out.parent — project rule forbids /tmp.
    with tempfile.TemporaryDirectory(prefix="avsync_ramp_", dir=str(out.parent)) as td:
        td_path = Path(td)
        pcm = td_path / "a.s16"
        write_pcm_sharp(pcm, duration_s, 48000)

        cmd = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            "-s",
            f"{width}x{height}",
            "-r",
            fps_str,
            "-i",
            "pipe:0",
            "-f",
            "s16le",
            "-ar",
            "48000",
            "-ac",
            "2",
            "-i",
            str(pcm),
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c:v",
            "libx264",
            "-profile:v",
            "baseline",
            "-bf",
            "0",
            "-pix_fmt",
            "yuv420p",
            "-b:v",
            vbitrate,
            "-maxrate",
            vbitrate,
            "-bufsize",
            bufsize,
            "-r",
            fps_str,
            "-g",
            str(int(round(fps_val * 2))),
            "-c:a",
            "aac",
            "-b:a",
            audio_bitrate,
            "-ar",
            "48000",
            "-ac",
            "2",
            "-shortest",
            "-movflags",
            "+faststart",
            str(out),
        ]
        print("GEN", out, flush=True)
        print("CMD", " ".join(cmd), flush=True)
        print(
            f"RAMP content_frames={ramp_frames} ramp_ms={ramp_s*1000:.3f} "
            f"peak_frames={peak_frames} flash_end_ms={flash_end_s*1000:.3f} "
            f"beep_attack_ms=1.0 beep_body_ms=50 period_s=1.0 n_frames={n_frames}",
            flush=True,
        )
        cap_fps = 30.0
        cap_dt_ms = 1000.0 / cap_fps
        rise_frac_per_cap = (cap_dt_ms / 1000.0) / ramp_s
        print(
            f"ONSET_EXPECT capture_fps={cap_fps} capture_quant_ms={cap_dt_ms:.3f} "
            f"rise_frac_per_capture~{rise_frac_per_cap:.3f} "
            f"(need <0.70 to avoid step guard) "
            f"expected_onset_resolution_ms~2-5 practical "
            f"(linear frac within one capture interval; not 33.33 quant)",
            flush=True,
        )

        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        assert proc.stdin is not None
        try:
            for n in range(n_frames):
                y = frame_luma(n, fps_val, ramp_frames, peak_frames)
                img = Image.new("RGB", (width, height), (y, y, y))
                draw = ImageDraw.Draw(img)
                t = n / fps_val
                phase = t - math.floor(t)
                if phase < 0.05:
                    bx = (width - width // 4) // 2
                    by = int(height * 3 / 4)
                    bw = width // 4
                    bh = height // 10
                    draw.rectangle([bx, by, bx + bw, by + bh], fill=(255, 0, 0))
                draw.text(
                    (8, 8),
                    f"{label} n={n}",
                    font=font,
                    fill=(255, 255, 0),
                    stroke_width=2,
                    stroke_fill=(0, 0, 0),
                )
                if y > 0:
                    txt = "RAMP"
                    try:
                        l, t0, r, b = draw.textbbox((0, 0), txt, font=font_flash)
                        tw, th = r - l, b - t0
                    except Exception:
                        tw, th = int(draw.textlength(txt, font=font_flash)), fs_flash
                    draw.text(
                        ((width - tw) / 2, height / 3),
                        txt,
                        font=font_flash,
                        fill=(0, 0, 0),
                    )
                proc.stdin.write(img.tobytes())
                if (n + 1) % 240 == 0:
                    print(f"  frames {n+1}/{n_frames}", flush=True)
        finally:
            proc.stdin.close()
            rc = proc.wait()
        if rc != 0:
            raise SystemExit(f"ffmpeg failed rc={rc}")
        print("OK", out, out.stat().st_size, flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--out",
        type=Path,
        default=ROOT / "assets" / "avsync" / "sync_soak_480p24_ramp.mp4",
    )
    ap.add_argument("--duration", type=float, default=360.0)
    ap.add_argument("--ramp-frames", type=int, default=4)
    ap.add_argument("--peak-frames", type=int, default=1)
    ap.add_argument("--vbitrate", default="1500k")
    ap.add_argument("--audio-bitrate", default="128k")
    ap.add_argument("--label", default="TREK24")
    args = ap.parse_args()
    gen_ramp_soak(
        args.out,
        duration_s=args.duration,
        ramp_frames=args.ramp_frames,
        peak_frames=args.peak_frames,
        vbitrate=args.vbitrate,
        audio_bitrate=args.audio_bitrate,
        label=args.label,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
