#!/usr/bin/env python3
"""Generate deterministic 480-line flash/click A/V measurement fixtures."""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import wave
from array import array
from dataclasses import dataclass
from pathlib import Path


SAMPLE_RATE = 48_000
SUPPORTED_RATES = ("24000/1001", "24", "25", "30000/1001", "30")
SUPPORTED_RATE_VALUES = {
    (24000, 1001),
    (24, 1),
    (25, 1),
    (30000, 1001),
    (30, 1),
}


@dataclass(frozen=True)
class Rate:
    num: int
    den: int

    @property
    def text(self) -> str:
        return str(self.num) if self.den == 1 else f"{self.num}/{self.den}"

    @property
    def file_tag(self) -> str:
        return self.text.replace("/", "_")

    @property
    def marker_period_frames(self) -> int:
        if self.den == 1001:
            return self.num // 1000
        return self.num

    @property
    def marker_period_samples(self) -> int:
        numerator = self.marker_period_frames * self.den * SAMPLE_RATE
        if numerator % self.num:
            raise ValueError(f"{self.text} marker period is not sample-exact")
        return numerator // self.num


def validate_rate(rate: Rate) -> None:
    if (
        isinstance(rate.num, bool)
        or isinstance(rate.den, bool)
        or not isinstance(rate.num, int)
        or not isinstance(rate.den, int)
        or rate.num <= 0
        or rate.den <= 0
    ):
        raise ValueError("source rate numerator and denominator must be positive integers")
    if (rate.num, rate.den) not in SUPPORTED_RATE_VALUES:
        raise ValueError(f"unsupported source rate {rate.num}/{rate.den}")


def parse_rate(text: str) -> Rate:
    aliases = {
        "24": Rate(24, 1),
        "24/1": Rate(24, 1),
        "25": Rate(25, 1),
        "25/1": Rate(25, 1),
        "30": Rate(30, 1),
        "30/1": Rate(30, 1),
        "24000/1001": Rate(24000, 1001),
        "30000/1001": Rate(30000, 1001),
    }
    try:
        return aliases[text.strip()]
    except KeyError as exc:
        raise argparse.ArgumentTypeError(
            f"unsupported rate {text!r}; choose {', '.join(SUPPORTED_RATES)}"
        ) from exc


def parse_offset_profile(text: str) -> tuple[float, float, float]:
    try:
        values = tuple(float(part.strip()) for part in text.split(","))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("offset profile must be three comma-separated ms values") from exc
    if len(values) != 3:
        raise argparse.ArgumentTypeError("offset profile must contain start,middle,end")
    if not all(math.isfinite(value) for value in values):
        raise argparse.ArgumentTypeError("offset profile values must be finite")
    return values  # type: ignore[return-value]


def marker_schedule(
    rate: Rate,
    marker_count: int,
    lead_intervals: int,
    tail_intervals: int,
    offset_profile_ms: tuple[float, float, float],
) -> tuple[int, int, list[dict[str, int | float]]]:
    validate_rate(rate)
    if marker_count < 1:
        raise ValueError("marker count must be positive")
    if lead_intervals < 0 or tail_intervals < 0:
        raise ValueError("lead and tail intervals must be non-negative")
    if not all(math.isfinite(value) for value in offset_profile_ms):
        raise ValueError("synthetic offset profile values must be finite")
    period_frames = rate.marker_period_frames
    total_frames = (lead_intervals + marker_count + tail_intervals) * period_frames
    total_sample_num = total_frames * rate.den * SAMPLE_RATE
    if total_sample_num % rate.num:
        raise ValueError("fixture duration must end on an exact audio sample")
    total_samples = total_sample_num // rate.num
    markers: list[dict[str, int | float]] = []
    for index in range(marker_count):
        frame = (lead_intervals + index) * period_frames
        sample_num = frame * rate.den * SAMPLE_RATE
        if sample_num % rate.num:
            raise ValueError(f"marker frame {frame} is not sample-exact")
        nominal_sample = sample_num // rate.num
        third = min(2, (nominal_sample * 3) // total_samples)
        offset_ms = offset_profile_ms[third]
        offset_samples = round(offset_ms * SAMPLE_RATE / 1000.0)
        audio_sample = nominal_sample + offset_samples
        if audio_sample < 0 or audio_sample >= total_samples:
            raise ValueError("audio offset moves a marker outside the fixture")
        markers.append(
            {
                "index": index,
                "video_frame": frame,
                "nominal_audio_sample": nominal_sample,
                "audio_sample": audio_sample,
                "nominal_time_ms": nominal_sample * 1000.0 / SAMPLE_RATE,
                "synthetic_audio_offset_ms": offset_samples * 1000.0 / SAMPLE_RATE,
                "window": third,
            }
        )
    return total_frames, total_samples, markers


def write_click_wav(path: Path, total_samples: int, markers: list[dict[str, int | float]]) -> None:
    click_samples = round(0.012 * SAMPLE_RATE)
    ramp_samples = round(0.001 * SAMPLE_RATE)
    pcm = array("h", [0]) * (total_samples * 2)
    for marker in markers:
        start = int(marker["audio_sample"])
        for i in range(click_samples):
            pos = start + i
            if pos >= total_samples:
                break
            gain = 1.0
            if i < ramp_samples:
                gain = i / ramp_samples
            elif i >= click_samples - ramp_samples:
                gain = (click_samples - 1 - i) / ramp_samples
            value = round(0.82 * 32767 * gain * math.sin(2.0 * math.pi * 2000.0 * i / SAMPLE_RATE))
            pcm[pos * 2] = value
            pcm[pos * 2 + 1] = value
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm.tobytes())


def probe(path: Path) -> dict:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=index,codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def generate(
    output: Path,
    *,
    rate: Rate,
    width: int,
    height: int,
    marker_count: int,
    codec: str,
    flash_frames: int,
    lead_intervals: int,
    tail_intervals: int,
    offset_profile_ms: tuple[float, float, float],
    force: bool,
) -> Path:
    validate_rate(rate)
    if width < 64 or height < 64 or width % 2 or height % 2:
        raise ValueError("width and height must be even and at least 64")
    if marker_count < 9:
        raise ValueError("at least 9 markers are required for three-window measurement")
    if flash_frames < 1 or flash_frames >= rate.marker_period_frames:
        raise ValueError("flash-frames must be within one marker period")
    output.parent.mkdir(parents=True, exist_ok=True)
    manifest_path = output.with_suffix(output.suffix + ".manifest.json")
    if not force and (output.exists() or manifest_path.exists()):
        raise FileExistsError(f"refusing to overwrite {output} or {manifest_path}")

    total_frames, total_samples, markers = marker_schedule(
        rate, marker_count, lead_intervals, tail_intervals, offset_profile_ms
    )
    wav_path = output.with_suffix(output.suffix + ".source.wav")
    if force:
        output.unlink(missing_ok=True)
        manifest_path.unlink(missing_ok=True)
        wav_path.unlink(missing_ok=True)
    write_click_wav(wav_path, total_samples, markers)

    start_frame = lead_intervals * rate.marker_period_frames
    period_frames = rate.marker_period_frames
    stop_frame = (lead_intervals + marker_count) * period_frames
    enable = (
        f"gte(n\\,{start_frame})*"
        f"lt(n\\,{stop_frame})*"
        f"lt(mod(n-{start_frame}\\,{period_frames})\\,{flash_frames})"
    )
    video_filter = (
        "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:"
        f"enable='{enable}',format=yuv420p"
    )
    command = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        f"color=c=black:s={width}x{height}:r={rate.text}",
        "-i",
        str(wav_path),
        "-filter:v",
        video_filter,
        "-map",
        "0:v:0",
        "-map",
        "1:a:0",
        "-frames:v",
        str(total_frames),
        "-fps_mode:v",
        "cfr",
        "-metadata",
        "comment=MiSTerPlex deterministic external A/V marker v1",
    ]
    if codec == "plex":
        command += [
            "-c:v",
            "libx264",
            "-profile:v",
            "baseline",
            "-level:v",
            "3.0",
            "-preset",
            "medium",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-g",
            str(period_frames * 2),
            "-keyint_min",
            str(period_frames),
            "-sc_threshold",
            "0",
            "-c:a",
            "aac",
            "-b:a",
            "128k",
            "-movflags",
            "+faststart",
        ]
    else:
        command += ["-c:v", "ffv1", "-level", "3", "-c:a", "pcm_s16le"]
    command += ["-shortest", str(output)]

    try:
        subprocess.run(command, check=True)
    except Exception:
        output.unlink(missing_ok=True)
        raise
    finally:
        wav_path.unlink(missing_ok=True)

    manifest = {
        "schema": "misterplex.external-av.fixture.v1",
        "purpose": "visible full-frame flashes with coincident stereo audio clicks",
        "source_rate": {"num": rate.num, "den": rate.den, "text": rate.text},
        "video": {
            "width": width,
            "height": height,
            "flash_frames": flash_frames,
            "total_frames": total_frames,
        },
        "audio": {
            "sample_rate": SAMPLE_RATE,
            "channels": 2,
            "click_frequency_hz": 2000,
            "click_duration_ms": 12,
            "total_samples": total_samples,
        },
        "schedule": {
            "lead_intervals": lead_intervals,
            "tail_intervals": tail_intervals,
            "marker_period_frames": period_frames,
            "marker_period_samples": rate.marker_period_samples,
            "marker_period_ms": rate.marker_period_samples * 1000.0 / SAMPLE_RATE,
            "markers": markers,
        },
        "encoding": codec,
        "synthetic_offset_profile_ms": list(offset_profile_ms),
        "file": output.name,
        "ffprobe": probe(output),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
    return manifest_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output", type=Path, help="generate one fixture")
    mode.add_argument("--all-rates", action="store_true", help="generate all required rates")
    parser.add_argument("--out-dir", type=Path, help="destination for --all-rates")
    parser.add_argument("--rate", type=parse_rate, default=parse_rate("24000/1001"))
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--markers", type=int, default=30)
    parser.add_argument("--codec", choices=("plex", "lossless"), default="plex")
    parser.add_argument("--flash-frames", type=int, default=2)
    parser.add_argument("--lead-intervals", type=int, default=2)
    parser.add_argument("--tail-intervals", type=int, default=2)
    parser.add_argument(
        "--synthetic-offset-profile-ms",
        type=parse_offset_profile,
        default=(0.0, 0.0, 0.0),
        metavar="START,MIDDLE,END",
        help="parser-test fault injection; production fixtures use 0,0,0",
    )
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    jobs: list[tuple[Path, Rate]] = []
    if args.all_rates:
        if args.out_dir is None:
            parser.error("--out-dir is required with --all-rates")
        extension = ".mp4" if args.codec == "plex" else ".mkv"
        for text in SUPPORTED_RATES:
            rate = parse_rate(text)
            jobs.append(
                (
                    args.out_dir
                    / f"external_av_{rate.file_tag}_{args.width}x{args.height}{extension}",
                    rate,
                )
            )
    else:
        jobs.append((args.output, args.rate))

    for output, rate in jobs:
        manifest = generate(
            output,
            rate=rate,
            width=args.width,
            height=args.height,
            marker_count=args.markers,
            codec=args.codec,
            flash_frames=args.flash_frames,
            lead_intervals=args.lead_intervals,
            tail_intervals=args.tail_intervals,
            offset_profile_ms=args.synthetic_offset_profile_ms,
            force=args.force,
        )
        print(f"generated {output}")
        print(f"manifest  {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
