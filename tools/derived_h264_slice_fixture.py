#!/usr/bin/env python3
"""Generate/verify a small always-on I420 slice from the derived H.264 asset."""
from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any

FORMAT = "misterplex.derived_h264_i420_slice.v1"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def ffmpeg_version() -> str:
    r = subprocess.run(["ffmpeg", "-version"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise SystemExit(f"ffmpeg -version failed: {r.stderr.strip()}")
    return r.stdout.splitlines()[0]


def frame_record(chunk: bytes, width: int, height: int, slice_index: int, source_index: int) -> dict[str, Any]:
    y_size = width * height
    uv_size = (width // 2) * (height // 2)
    y = chunk[:y_size]
    u = chunk[y_size : y_size + uv_size]
    v = chunk[y_size + uv_size :]

    def stats(data: bytes) -> dict[str, Any]:
        return {
            "min": min(data),
            "max": max(data),
            "mean": round(statistics.fmean(data), 4),
            "pstdev": round(statistics.pstdev(data), 4),
        }

    return {
        "slice_index": slice_index,
        "source_index": source_index,
        "frame_sha256": sha256_bytes(chunk),
        "planes": {"Y": sha256_bytes(y), "U": sha256_bytes(u), "V": sha256_bytes(v)},
        "stats": {"Y": stats(y), "U": stats(u), "V": stats(v)},
    }


def decode_selected(input_path: Path, selected: list[int], width: int, height: int, loop_filter: str) -> tuple[list[bytes], str]:
    frame_size = width * height * 3 // 2
    selected_set = set(selected)
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]
    if loop_filter == "disabled":
        cmd += ["-skip_loop_filter", "all"]
    cmd += ["-i", str(input_path), "-map", "0:v:0", "-pix_fmt", "yuv420p", "-f", "rawvideo", "pipe:1"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdout is not None
    chunks: dict[int, bytes] = {}
    index = 0
    while True:
        chunk = proc.stdout.read(frame_size)
        if not chunk:
            break
        if len(chunk) != frame_size:
            proc.kill()
            raise SystemExit(f"short raw frame {index}: got {len(chunk)} bytes, want {frame_size}")
        if index in selected_set:
            chunks[index] = chunk
            if len(chunks) == len(selected):
                # Drain normally; killing ffmpeg can hide decode errors before EOF on some builds.
                pass
        index += 1
    stderr = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
    rc = proc.wait()
    if rc != 0:
        raise SystemExit(f"ffmpeg decode failed rc={rc}: {stderr.strip()}")
    missing = [i for i in selected if i not in chunks]
    if missing:
        raise SystemExit(f"selected frames missing from decode: {missing}")
    return [chunks[i] for i in selected], " ".join(cmd)


def build_manifest(
    *, input_path: Path, slice_path: Path, selected: list[int], chunks: list[bytes], width: int, height: int, loop_filter: str, command: str
) -> dict[str, Any]:
    records = [frame_record(chunk, width, height, i, src) for i, (src, chunk) in enumerate(zip(selected, chunks))]
    uv_distinct = sum(1 for r in records if r["planes"]["U"] != r["planes"]["V"])
    lf_label = "enabled" if loop_filter == "enabled" else "disabled"
    always_on = loop_filter == "disabled"
    if loop_filter == "enabled":
        stage_blind = (
            "It detects exact native-I420 byte differences at the enabled-loop-filter stage; "
            "it does not score presentation RGB/RGB565, disabled-stage control comparisons by itself, frame pacing, drops, or repeats."
        )
        stage_summary = (
            "HEVC /library/metadata/3 re-encoded to H.264 Constrained Baseline 624x480; "
            "bounded native-I420 slice decoded with in-loop deblocking filter enabled (FFmpeg default)"
        )
    else:
        stage_blind = (
            "It detects exact native-I420 byte differences at the disabled-loop-filter stage; "
            "it does not score presentation RGB/RGB565, enabled deblock, frame pacing, drops, or repeats."
        )
        stage_summary = (
            "HEVC /library/metadata/3 re-encoded to H.264 Constrained Baseline 624x480; "
            "bounded native-I420 slice decoded with loop filter disabled"
        )
    return {
        "format": FORMAT,
        "scope": {
            "asset_class": "bounded_raw_slice_from_derived_reencoded_validation_asset",
            "always_on_unit_fixture": always_on,
            "not_original_library_content": True,
            "not_original_part_direct_play_evidence": True,
            "source_summary": stage_summary,
            "h264_loop_filter": lf_label,
        },
        "source": {"path": str(input_path), "sha256": sha256_file(input_path)},
        "slice": {"path": str(slice_path), "bytes": slice_path.stat().st_size, "sha256": sha256_file(slice_path)},
        "decoder": {"ffmpeg_version": ffmpeg_version(), "loop_filter": loop_filter, "command": command, "pixel_format": "yuv420p"},
        "geometry": {"width": width, "height": height, "frame_bytes": width * height * 3 // 2, "colorspace": "I420_NATIVE"},
        "selection": {
            "source_frames": selected,
            "reason": "Chosen across the 1800-frame clip for distinct U/V chroma, high luma/chroma variation, non-grey real content, and clamp-edge coverage (Y min near 0 and max near 243).",
        },
        "coverage": {
            "frames": len(records),
            "unique_y_hashes": len({r["planes"]["Y"] for r in records}),
            "uv_distinct_frames": uv_distinct,
            "y_min": min(r["stats"]["Y"]["min"] for r in records),
            "y_max": max(r["stats"]["Y"]["max"] for r in records),
            "u_min": min(r["stats"]["U"]["min"] for r in records),
            "u_max": max(r["stats"]["U"]["max"] for r in records),
            "v_min": min(r["stats"]["V"]["min"] for r in records),
            "v_max": max(r["stats"]["V"]["max"] for r in records),
        },
        "frames": records,
        "blind_spots": [
            "The slice is only eight frames; it is an always-on smoke/reference gate, not a replacement for the full 1800-frame manifest when the media is available.",
            stage_blind,
            "It catches U/V swaps for this selected slice because every selected frame has distinct U/V hashes; it still cannot prove unsupported-stream parser coverage.",
            "Mutations that the selected frames do not express, or that alias through equal/zero coefficients or equivalent dequant classes, can remain invisible.",
        ],
    }


def verify_manifest(manifest: dict[str, Any], slice_path: Path) -> list[str]:
    failures: list[str] = []
    if manifest.get("format") != FORMAT:
        return [f"format got={manifest.get('format')} want={FORMAT}"]
    geom = manifest["geometry"]
    width = int(geom["width"])
    height = int(geom["height"])
    frame_size = int(geom["frame_bytes"])
    expected_frames = manifest["frames"]
    expected_size = frame_size * len(expected_frames)
    actual_size = slice_path.stat().st_size
    if actual_size != expected_size:
        failures.append(f"slice size got={actual_size} want={expected_size}")
        return failures
    if sha256_file(slice_path) != manifest["slice"]["sha256"]:
        failures.append(f"slice_sha256 got={sha256_file(slice_path)} want={manifest['slice']['sha256']}")
    actual_records: list[dict[str, Any]] = []
    with slice_path.open("rb") as f:
        for expected in expected_frames:
            chunk = f.read(frame_size)
            got = frame_record(chunk, width, height, int(expected["slice_index"]), int(expected["source_index"]))
            actual_records.append(got)
            if got["frame_sha256"] != expected["frame_sha256"]:
                failures.append(
                    f"frame_hash slice={expected['slice_index']} source={expected['source_index']} got={got['frame_sha256']} want={expected['frame_sha256']}"
                )
            for plane in ("Y", "U", "V"):
                if got["planes"][plane] != expected["planes"][plane]:
                    failures.append(
                        f"plane_hash slice={expected['slice_index']} source={expected['source_index']} plane={plane} got={got['planes'][plane]} want={expected['planes'][plane]}"
                    )
                if got["stats"][plane] != expected["stats"][plane]:
                    failures.append(
                        f"plane_stats slice={expected['slice_index']} source={expected['source_index']} plane={plane} got={got['stats'][plane]} want={expected['stats'][plane]}"
                    )
            if failures:
                break
    records = actual_records if len(actual_records) == len(expected_frames) else expected_frames
    uv_distinct = sum(1 for r in records if r["planes"]["U"] != r["planes"]["V"])
    unique_y = len({r["planes"]["Y"] for r in records})
    cov = manifest.get("coverage", {})
    actual_cov = {
        "frames": len(records),
        "unique_y_hashes": unique_y,
        "uv_distinct_frames": uv_distinct,
        "y_min": min(r["stats"]["Y"]["min"] for r in records),
        "y_max": max(r["stats"]["Y"]["max"] for r in records),
        "u_min": min(r["stats"]["U"]["min"] for r in records),
        "u_max": max(r["stats"]["U"]["max"] for r in records),
        "v_min": min(r["stats"]["V"]["min"] for r in records),
        "v_max": max(r["stats"]["V"]["max"] for r in records),
    }
    for key, value in actual_cov.items():
        if cov.get(key) != value:
            failures.append(f"coverage {key} got={cov.get(key)} want={value}")
    if uv_distinct != len(expected_frames):
        failures.append(f"uv_distinct_frames got={uv_distinct} want={len(expected_frames)}")
    if unique_y < len(expected_frames) - 1:
        failures.append(f"unique_y_hashes got={unique_y} want>={len(expected_frames)-1}")
    if actual_cov["y_min"] > 10 or actual_cov["y_max"] < 235:
        failures.append(f"clamp-edge coverage weak y_min={actual_cov['y_min']} y_max={actual_cov['y_max']}")
    if actual_cov["u_max"] - actual_cov["u_min"] < 32 or actual_cov["v_max"] - actual_cov["v_min"] < 32:
        failures.append(
            "chroma coverage weak "
            f"u_min={actual_cov['u_min']} u_max={actual_cov['u_max']} "
            f"v_min={actual_cov['v_min']} v_max={actual_cov['v_max']}"
        )
    return failures


def cmd_generate(args: argparse.Namespace) -> int:
    selected = [int(x) for x in args.frames.split(",") if x.strip()]
    if len(selected) != len(set(selected)) or selected != sorted(selected):
        raise SystemExit("--frames must be sorted unique comma-separated indices")
    input_path = Path(args.input)
    slice_path = Path(args.slice_out)
    manifest_path = Path(args.manifest_out)
    chunks, command = decode_selected(input_path, selected, args.width, args.height, args.h264_loop_filter)
    slice_path.parent.mkdir(parents=True, exist_ok=True)
    slice_path.write_bytes(b"".join(chunks))
    manifest = build_manifest(
        input_path=input_path,
        slice_path=slice_path,
        selected=selected,
        chunks=chunks,
        width=args.width,
        height=args.height,
        loop_filter=args.h264_loop_filter,
        command=command,
    )
    failures = verify_manifest(manifest, slice_path)
    if failures:
        for failure in failures:
            print(f"DERIVED_SLICE_SELF_CHECK_FAIL {failure}", file=sys.stderr)
        return 3
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        "DERIVED_SLICE_GENERATED "
        f"slice={slice_path} manifest={manifest_path} frames={len(selected)} "
        f"source_frames={','.join(map(str, selected))} slice_sha256={manifest['slice']['sha256']}"
    )
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest)
    slice_path = Path(args.slice)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    failures = verify_manifest(manifest, slice_path)
    if failures:
        for failure in failures:
            print(f"DERIVED_SLICE_FAIL {failure}", file=sys.stderr)
        return 1
    print(
        "DERIVED_SLICE_OK "
        f"slice={slice_path} manifest={manifest_path} frames={manifest['coverage']['frames']} "
        f"uv_distinct={manifest['coverage']['uv_distinct_frames']} unique_y={manifest['coverage']['unique_y_hashes']} "
        f"y_min={manifest['coverage']['y_min']} y_max={manifest['coverage']['y_max']}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--input", required=True)
    gen.add_argument("--slice-out", required=True)
    gen.add_argument("--manifest-out", required=True)
    gen.add_argument("--frames", required=True)
    gen.add_argument("--width", type=int, default=624)
    gen.add_argument("--height", type=int, default=480)
    gen.add_argument("--h264-loop-filter", choices=("enabled", "disabled"), default="disabled")
    gen.set_defaults(func=cmd_generate)
    ver = sub.add_parser("verify")
    ver.add_argument("--slice", required=True)
    ver.add_argument("--manifest", required=True)
    ver.set_defaults(func=cmd_verify)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
