#!/usr/bin/env python3
"""Generate/verify per-frame I420 plane hashes for derived H.264 validation assets."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

FORMAT = "misterplex.derived_h264_plane_hashes.v1"


def run(cmd: list[str], *, capture: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=False,
    )


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def ffmpeg_version() -> str:
    r = run(["ffmpeg", "-version"])
    if r.returncode != 0:
        raise SystemExit(f"ffmpeg -version failed: {r.stderr.strip()}")
    return r.stdout.splitlines()[0]


def ffprobe_stream(path: Path) -> dict[str, Any]:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-count_frames",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name,profile,width,height,coded_width,coded_height,pix_fmt,has_b_frames,level,nb_frames,nb_read_frames,r_frame_rate,avg_frame_rate",
        "-of",
        "json",
        str(path),
    ]
    r = run(cmd)
    if r.returncode != 0:
        raise SystemExit(f"ffprobe failed for {path}: {r.stderr.strip()}")
    data = json.loads(r.stdout)
    streams = data.get("streams") or []
    if not streams:
        raise SystemExit(f"ffprobe found no video stream in {path}")
    return streams[0]


def decode_hashes(path: Path, width: int, height: int, loop_filter: str) -> tuple[list[dict[str, Any]], str]:
    frame_size = width * height * 3 // 2
    y_size = width * height
    uv_size = (width // 2) * (height // 2)
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]
    if loop_filter == "disabled":
        cmd += ["-skip_loop_filter", "all"]
    cmd += ["-i", str(path), "-map", "0:v:0", "-pix_fmt", "yuv420p", "-f", "rawvideo", "pipe:1"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdout is not None
    frames: list[dict[str, Any]] = []
    index = 0
    while True:
        chunk = proc.stdout.read(frame_size)
        if not chunk:
            break
        if len(chunk) != frame_size:
            proc.kill()
            raise SystemExit(f"short raw frame {index}: got {len(chunk)} bytes, want {frame_size}")
        y = chunk[:y_size]
        u = chunk[y_size : y_size + uv_size]
        v = chunk[y_size + uv_size :]
        frames.append(
            {
                "index": index,
                "frame_sha256": hashlib.sha256(chunk).hexdigest(),
                "planes": {
                    "Y": hashlib.sha256(y).hexdigest(),
                    "U": hashlib.sha256(u).hexdigest(),
                    "V": hashlib.sha256(v).hexdigest(),
                },
            }
        )
        index += 1
    stderr = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
    rc = proc.wait()
    if rc != 0:
        raise SystemExit(f"ffmpeg decode failed rc={rc}: {stderr.strip()}")
    return frames, " ".join(cmd)


def build_manifest(path: Path, loop_filter: str) -> dict[str, Any]:
    stream = ffprobe_stream(path)
    width = int(stream["width"])
    height = int(stream["height"])
    if width % 2 or height % 2:
        raise SystemExit(f"I420 requires even dimensions, got {width}x{height}")
    frames, command = decode_hashes(path, width, height, loop_filter)
    return {
        "format": FORMAT,
        "scope": {
            "asset_class": "derived_reencoded_validation_asset",
            "not_original_library_content": True,
            "not_original_part_direct_play_evidence": True,
            "source_summary": "HEVC /library/metadata/3, 696x540, re-encoded to H.264 Constrained Baseline 624x480",
        },
        "source": {
            "path": str(path),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        },
        "decoder": {
            "ffmpeg_version": ffmpeg_version(),
            "loop_filter": loop_filter,
            "command": command,
            "pixel_format": "yuv420p",
        },
        "stream": stream,
        "geometry": {
            "width": width,
            "height": height,
            "frame_bytes": width * height * 3 // 2,
            "y_stride": width,
            "uv_stride": width // 2,
            "colorspace": "I420_NATIVE",
        },
        "frame_count": len(frames),
        "frames": frames,
        "blind_spots": [
            "Per-plane hashes detect exact plane mismatches but do not localize pixels unless a candidate comparator reports a mismatching frame/plane.",
            "Hashes cannot prove why a mismatch occurred; a zig-zag, dequant, IDCT, motion-compensation, or deblock bug can alias if the exercised coefficients/samples are unchanged by that bug.",
            "This manifest scores only native I420 at the declared H.264 loop-filter contract; RGB/RGB565 round trips, masked presentation output, and a different loop-filter stage are out of scope.",
            "A U/V swap is detectable only for frames whose U and V hashes differ; the verification self-check requires that condition for this asset.",
        ],
    }


def comparable_manifest(m: dict[str, Any]) -> dict[str, Any]:
    # Stable comparison keys. Keep blind_spots/provenance in the checked contract.
    return m


def verify_self_checks(manifest: dict[str, Any]) -> list[str]:
    frames = manifest["frames"]
    failures: list[str] = []
    if not frames:
        return ["no frames in manifest"]
    uv_diff = [f["index"] for f in frames if f["planes"]["U"] != f["planes"]["V"]]
    if not uv_diff:
        failures.append("U/V swap sentinel weak: no frame has distinct U/V hashes")
    elif len(uv_diff) < max(1, len(frames) * 9 // 10):
        failures.append(
            f"U/V swap sentinel weak: only {len(uv_diff)}/{len(frames)} frames have distinct U/V hashes"
        )
    if len(frames) >= 2:
        differing_adjacent = any(frames[i]["frame_sha256"] != frames[i - 1]["frame_sha256"] for i in range(1, len(frames)))
        if not differing_adjacent:
            failures.append("stuck-frame sentinel weak: no adjacent frame hash differs")
    y_values = {f["planes"]["Y"] for f in frames}
    if len(y_values) < max(2, len(frames) // 20):
        failures.append(f"Y variation weak: only {len(y_values)} unique Y hashes across {len(frames)} frames")
    return failures


def compare_candidate_planes(manifest: dict[str, Any], candidate: Path, colorspace: str) -> list[str]:
    if colorspace != "I420_NATIVE":
        return [f"candidate colorspace mismatch: got={colorspace} want=I420_NATIVE"]
    geom = manifest["geometry"]
    width = int(geom["width"])
    height = int(geom["height"])
    frame_size = int(geom["frame_bytes"])
    y_size = width * height
    uv_size = (width // 2) * (height // 2)
    expected_frames = manifest["frames"]
    expected_size = frame_size * len(expected_frames)
    actual_size = candidate.stat().st_size
    if actual_size != expected_size:
        return [f"candidate size got={actual_size} want={expected_size}"]
    failures: list[str] = []
    with candidate.open("rb") as f:
        for ef in expected_frames:
            index = int(ef["index"])
            chunk = f.read(frame_size)
            y = chunk[:y_size]
            u = chunk[y_size : y_size + uv_size]
            v = chunk[y_size + uv_size :]
            got = {
                "frame_sha256": hashlib.sha256(chunk).hexdigest(),
                "planes": {
                    "Y": hashlib.sha256(y).hexdigest(),
                    "U": hashlib.sha256(u).hexdigest(),
                    "V": hashlib.sha256(v).hexdigest(),
                },
            }
            if got["frame_sha256"] != ef["frame_sha256"]:
                failures.append(
                    f"candidate frame_hash frame={index} got={got['frame_sha256']} want={ef['frame_sha256']}"
                )
                for plane in ("Y", "U", "V"):
                    if got["planes"][plane] != ef["planes"][plane]:
                        failures.append(
                            f"candidate plane_hash frame={index} plane={plane} got={got['planes'][plane]} want={ef['planes'][plane]}"
                        )
                break
    return failures


def cmd_generate(args: argparse.Namespace) -> int:
    manifest = build_manifest(Path(args.input), args.h264_loop_filter)
    failures = verify_self_checks(manifest)
    if failures:
        for failure in failures:
            print(f"DERIVED_HASH_SELF_CHECK_FAIL {failure}", file=sys.stderr)
        return 3
    out = Path(args.manifest_out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        "DERIVED_HASH_GENERATED "
        f"manifest={out} frames={manifest['frame_count']} "
        f"source_sha256={manifest['source']['sha256']} loop_filter={args.h264_loop_filter}"
    )
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest)
    expected = json.loads(manifest_path.read_text(encoding="utf-8"))
    if expected.get("format") != FORMAT:
        print(f"DERIVED_HASH_FAIL format={expected.get('format')} expected={FORMAT}", file=sys.stderr)
        return 2
    source = Path(args.input or expected["source"]["path"])
    actual = build_manifest(source, expected["decoder"]["loop_filter"])
    failures: list[str] = []
    if comparable_manifest(actual) != comparable_manifest(expected):
        if actual["source"]["sha256"] != expected["source"]["sha256"]:
            failures.append(f"source_sha256 got={actual['source']['sha256']} want={expected['source']['sha256']}")
        if actual["frame_count"] != expected["frame_count"]:
            failures.append(f"frame_count got={actual['frame_count']} want={expected['frame_count']}")
        for af, ef in zip(actual["frames"], expected["frames"]):
            if af != ef:
                failures.append(f"frame_hash frame={ef.get('index')} got={af.get('frame_sha256')} want={ef.get('frame_sha256')}")
                for plane in ("Y", "U", "V"):
                    if af["planes"][plane] != ef["planes"][plane]:
                        failures.append(
                            f"plane_hash frame={ef.get('index')} plane={plane} got={af['planes'][plane]} want={ef['planes'][plane]}"
                        )
                break
        if not failures:
            failures.append("manifest metadata mismatch")
    failures.extend(verify_self_checks(expected))
    if args.candidate_planes:
        failures.extend(compare_candidate_planes(expected, Path(args.candidate_planes), args.candidate_colorspace))
    if failures:
        for failure in failures:
            print(f"DERIVED_HASH_FAIL {failure}", file=sys.stderr)
        return 1
    if args.candidate_planes:
        print(
            "DERIVED_CANDIDATE_OK "
            f"candidate={args.candidate_planes} frames={expected['frame_count']} colorspace={args.candidate_colorspace}"
        )
    print(
        "DERIVED_HASH_OK "
        f"manifest={manifest_path} frames={expected['frame_count']} "
        f"loop_filter={expected['decoder']['loop_filter']} source_sha256={expected['source']['sha256']}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--input", required=True)
    gen.add_argument("--manifest-out", required=True)
    gen.add_argument("--h264-loop-filter", choices=("enabled", "disabled"), default="disabled")
    gen.set_defaults(func=cmd_generate)
    ver = sub.add_parser("verify")
    ver.add_argument("--manifest", required=True)
    ver.add_argument("--input")
    ver.add_argument("--candidate-planes")
    ver.add_argument("--candidate-colorspace", default="I420_NATIVE")
    ver.set_defaults(func=cmd_verify)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
