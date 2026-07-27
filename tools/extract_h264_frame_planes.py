#!/usr/bin/env python3
"""Generate and verify per-frame I420 golden planes for H.264 Annex-B fixtures."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path
from typing import Any


FORMAT = "misterplex.p3.frame_planes_golden.v1"
SEQUENCE_FORMAT = "misterplex.p3.nal_sequence.v1"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        obj = json.load(f)
    if not isinstance(obj, dict):
        raise SystemExit(f"{path}: top-level JSON is not an object")
    return obj


def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(Path.cwd().resolve()).as_posix()
    except ValueError:
        return path.name


def tool_path(name: str) -> str:
    found = shutil.which(name)
    if not found:
        raise SystemExit(f"{name} not found")
    return found


def version_line(tool: str) -> str:
    out = subprocess.check_output([tool, "-version"], text=True, stderr=subprocess.STDOUT)
    return out.splitlines()[0]


def ffprobe_geometry(ffprobe: str, bitstream: Path) -> tuple[int, int, int]:
    out = subprocess.check_output(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height,nb_read_frames",
            "-count_frames",
            "-of",
            "csv=p=0",
            str(bitstream),
        ],
        text=True,
    ).strip()
    parts = out.split(",")
    if len(parts) != 3 or parts[2] == "N/A":
        raise SystemExit(f"ffprobe did not report width,height,frame_count for {bitstream}: {out!r}")
    return int(parts[0]), int(parts[1]), int(parts[2])


def frame_meta(sequence: dict[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for n in sequence.get("nals", []):
        if isinstance(n, dict) and "vcl_index" in n:
            out.append(
                {
                    "frame_index": int(n["vcl_index"]),
                    "frame_num": int(n.get("frame_num", -1)),
                    "slice_kind": str(n.get("slice_kind", "unknown")),
                    "nal_index": int(n.get("index", -1)),
                    "nal_type": int(n.get("nal_type", -1)),
                }
            )
    out.sort(key=lambda x: x["frame_index"])
    return out


def require_sequence_matches(
    sequence: dict[str, Any], sequence_path: Path, bitstream: Path, source_sha: str, source_bytes: int
) -> tuple[str, int, int, int]:
    if sequence.get("format") != SEQUENCE_FORMAT:
        raise SystemExit(f"{sequence_path}: format is not {SEQUENCE_FORMAT}")
    src = sequence.get("source", {})
    if src.get("sha256") != source_sha or int(src.get("bytes", -1)) != source_bytes:
        raise SystemExit(f"{sequence_path}: source hash/size does not match {bitstream}")
    seq = sequence.get("sequence", {})
    vcl = int(seq.get("vcl", -1))
    if vcl < 2 or int(seq.get("idr", 0)) < 1 or int(seq.get("p_slices", 0)) < 1:
        raise SystemExit(f"{sequence_path}: need multi-frame IDR+P sequence, got {seq}")
    frame = sequence.get("frame", {})
    coded_w = int(frame.get("coded_width", 0))
    coded_h = int(frame.get("coded_height", 0))
    return sha256_file(sequence_path), coded_w, coded_h, vcl


def decode_i420(ffmpeg: str, bitstream: Path, planes_out: Path) -> list[str]:
    planes_out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        ffmpeg,
        "-v",
        "error",
        "-y",
        "-i",
        str(bitstream),
        "-an",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "yuv420p",
        str(planes_out),
    ]
    subprocess.check_call(cmd)
    return ["ffmpeg", "-v", "error", "-y", "-i", rel(bitstream), "-an", "-f", "rawvideo",
            "-pix_fmt", "yuv420p", rel(planes_out)]


def build_manifest(
    bitstream: Path,
    sequence_path: Path,
    planes_path: Path,
    source_sha: str,
    source_bytes: int,
    sequence_sha: str,
    sequence: dict[str, Any],
    ffmpeg: str,
    ffprobe: str,
    ffmpeg_cmd: list[str],
    width: int,
    height: int,
    frames: int,
) -> dict[str, Any]:
    if width % 2 or height % 2:
        raise SystemExit(f"I420 requires even geometry, got {width}x{height}")
    y_bytes = width * height
    uv_w = width // 2
    uv_h = height // 2
    uv_bytes = uv_w * uv_h
    frame_bytes = y_bytes + uv_bytes * 2
    blob = planes_path.read_bytes()
    expected = frame_bytes * frames
    if len(blob) != expected:
        raise SystemExit(f"{planes_path}: byte count {len(blob)} != expected {expected}")

    seq_frame = sequence.get("frame", {})
    meta = {
        "format": FORMAT,
        "source": {"path": rel(bitstream), "bytes": source_bytes, "sha256": source_sha},
        "sequence_manifest": {
            "path": rel(sequence_path),
            "bytes": sequence_path.stat().st_size,
            "sha256": sequence_sha,
            "format": SEQUENCE_FORMAT,
        },
        "decoder": {
            "ffmpeg_version": version_line(ffmpeg),
            "ffprobe_version": version_line(ffprobe),
            "command": " ".join(ffmpeg_cmd),
            "pix_fmt": "yuv420p",
        },
        "geometry": {
            "coded_width": width,
            "coded_height": height,
            "display_width": int(seq_frame.get("display_width", width)),
            "display_height": int(seq_frame.get("display_height", height)),
            "planes": [
                {"plane": "Y", "width": width, "height": height, "stride": width},
                {"plane": "U", "width": uv_w, "height": uv_h, "stride": uv_w},
                {"plane": "V", "width": uv_w, "height": uv_h, "stride": uv_w},
            ],
        },
        "plane_blob": {
            "path": rel(planes_path),
            "bytes": len(blob),
            "sha256": sha256_bytes(blob),
            "layout": "I420 planar per frame: Y then U then V",
            "frame_bytes": frame_bytes,
        },
        "frames": [],
    }

    frames_meta = frame_meta(sequence)
    if len(frames_meta) != frames:
        raise SystemExit(f"{sequence_path}: VCL metadata count {len(frames_meta)} != decoded frames {frames}")
    for f in range(frames):
        base = f * frame_bytes
        planes = [
            ("Y", width, height, width, base, y_bytes),
            ("U", uv_w, uv_h, uv_w, base + y_bytes, uv_bytes),
            ("V", uv_w, uv_h, uv_w, base + y_bytes + uv_bytes, uv_bytes),
        ]
        frame_obj = {
            "frame_index": f,
            "frame_num": frames_meta[f]["frame_num"],
            "slice_kind": frames_meta[f]["slice_kind"],
            "nal_index": frames_meta[f]["nal_index"],
            "nal_type": frames_meta[f]["nal_type"],
            "planes": [],
        }
        for plane, pw, ph, stride, off, count in planes:
            frame_obj["planes"].append(
                {
                    "plane": plane,
                    "width": pw,
                    "height": ph,
                    "stride": stride,
                    "offset": off,
                    "bytes": count,
                    "sha256": sha256_bytes(blob[off : off + count]),
                }
            )
        meta["frames"].append(frame_obj)
    return meta


def validate_manifest(manifest: dict[str, Any], bitstream: Path, sequence_path: Path, planes_path: Path) -> None:
    if manifest.get("format") != FORMAT:
        raise SystemExit(f"manifest format is not {FORMAT}")
    src = manifest.get("source", {})
    blob = planes_path.read_bytes()
    if src.get("sha256") != sha256_file(bitstream) or int(src.get("bytes", -1)) != bitstream.stat().st_size:
        raise SystemExit("frame-plane golden source provenance does not match bitstream")
    seq = manifest.get("sequence_manifest", {})
    if seq.get("sha256") != sha256_file(sequence_path) or int(seq.get("bytes", -1)) != sequence_path.stat().st_size:
        raise SystemExit("frame-plane golden sequence provenance does not match manifest")
    dec = manifest.get("decoder", {})
    ffmpeg = tool_path("ffmpeg")
    ffprobe = tool_path("ffprobe")
    if dec.get("ffmpeg_version") != version_line(ffmpeg):
        raise SystemExit("frame-plane golden ffmpeg version does not match current decoder")
    if dec.get("ffprobe_version") != version_line(ffprobe):
        raise SystemExit("frame-plane golden ffprobe version does not match current decoder")
    plane_blob = manifest.get("plane_blob", {})
    if plane_blob.get("sha256") != sha256_bytes(blob) or int(plane_blob.get("bytes", -1)) != len(blob):
        raise SystemExit("frame-plane golden blob hash/size mismatch")

    frame_bytes = int(plane_blob.get("frame_bytes", 0))
    frames = manifest.get("frames", [])
    if frame_bytes <= 0 or not isinstance(frames, list) or len(frames) < 2:
        raise SystemExit("frame-plane golden must contain >=2 frames")
    if len(blob) != frame_bytes * len(frames):
        raise SystemExit("frame-plane golden blob size does not match frame count")
    for f, frame in enumerate(frames):
        if int(frame.get("frame_index", -1)) != f:
            raise SystemExit("frame indices are not contiguous")
        for p in frame.get("planes", []):
            off = int(p.get("offset", -1))
            count = int(p.get("bytes", -1))
            if off < 0 or count <= 0 or off + count > len(blob):
                raise SystemExit("frame-plane golden has invalid plane range")
            if p.get("sha256") != sha256_bytes(blob[off : off + count]):
                raise SystemExit(
                    f"frame-plane golden plane hash mismatch frame={f} plane={p.get('plane', '?')}"
                )


def compare_candidate(manifest: dict[str, Any], golden_path: Path, candidate_path: Path) -> bool:
    golden = golden_path.read_bytes()
    candidate = candidate_path.read_bytes()
    if len(candidate) != len(golden):
        raise SystemExit(f"candidate plane blob size {len(candidate)} != golden size {len(golden)}")
    exact_all = True
    for frame in manifest["frames"]:
        frame_index = int(frame["frame_index"])
        for plane in frame["planes"]:
            name = str(plane["plane"])
            off = int(plane["offset"])
            count = int(plane["bytes"])
            exact = 0
            sum_abs = 0
            max_abs = 0
            for i in range(count):
                d = abs(candidate[off + i] - golden[off + i])
                exact += d == 0
                sum_abs += d
                max_abs = max(max_abs, d)
            mae = sum_abs / count
            print(
                f"FRAME_PLANE_COMPARE raw frame={frame_index} plane={name} "
                f"exact={exact} pixels={count} mae={mae:.6f} max_abs={max_abs}"
            )
            if exact != count:
                exact_all = False
    print(
        f"FRAME_PLANE_COMPARE summary frames={len(manifest['frames'])} "
        f"bytes={len(golden)} strict_pass={1 if exact_all else 0}"
    )
    return exact_all


def generate(args: argparse.Namespace) -> int:
    bitstream = Path(args.input)
    sequence_path = Path(args.sequence)
    planes_out = Path(args.planes_out)
    manifest_out = Path(args.manifest_out)
    source_sha = sha256_file(bitstream)
    source_bytes = bitstream.stat().st_size
    sequence = read_json(sequence_path)
    sequence_sha, coded_w, coded_h, vcl = require_sequence_matches(
        sequence, sequence_path, bitstream, source_sha, source_bytes
    )
    ffmpeg = tool_path("ffmpeg")
    ffprobe = tool_path("ffprobe")
    width, height, frames = ffprobe_geometry(ffprobe, bitstream)
    if (width, height) != (coded_w, coded_h):
        raise SystemExit(f"ffprobe geometry {width}x{height} != sequence coded geometry {coded_w}x{coded_h}")
    if frames != vcl:
        raise SystemExit(f"ffprobe frames {frames} != sequence VCL count {vcl}")
    if args.expect_width and width != args.expect_width:
        raise SystemExit(f"decoded width {width} != expected {args.expect_width}")
    if args.expect_height and height != args.expect_height:
        raise SystemExit(f"decoded height {height} != expected {args.expect_height}")
    cmd = decode_i420(ffmpeg, bitstream, planes_out)
    manifest = build_manifest(
        bitstream,
        sequence_path,
        planes_out,
        source_sha,
        source_bytes,
        sequence_sha,
        sequence,
        ffmpeg,
        ffprobe,
        cmd,
        width,
        height,
        frames,
    )
    manifest_out.parent.mkdir(parents=True, exist_ok=True)
    manifest_out.write_text(json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(
        f"extract_h264_frame_planes: OK input={bitstream} frames={frames} "
        f"geometry={width}x{height} planes_sha256={manifest['plane_blob']['sha256']}"
    )
    return 0


def verify(args: argparse.Namespace) -> int:
    manifest = read_json(Path(args.manifest))
    validate_manifest(manifest, Path(args.input), Path(args.sequence), Path(args.planes))
    if args.candidate_planes:
        exact = compare_candidate(manifest, Path(args.planes), Path(args.candidate_planes))
        if args.expect_red:
            if exact:
                raise SystemExit("candidate unexpectedly matched golden in expect-red mode")
            print("extract_h264_frame_planes: OK expected-red candidate diverged from golden")
            return 0
        if not exact:
            raise SystemExit("candidate plane comparison diverged from golden")
    geom = manifest["geometry"]
    print(
        f"extract_h264_frame_planes: OK verify frames={len(manifest['frames'])} "
        f"geometry={geom['coded_width']}x{geom['coded_height']} "
        f"planes_sha256={manifest['plane_blob']['sha256']}"
    )
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="Annex-B H.264 bitstream")
    ap.add_argument("--sequence", required=True, help="misterplex.p3.nal_sequence.v1 manifest")
    ap.add_argument("--planes-out", help="output I420 plane blob")
    ap.add_argument("--manifest-out", help="output frame-plane golden JSON")
    ap.add_argument("--expect-width", type=int, default=0)
    ap.add_argument("--expect-height", type=int, default=0)
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--planes", help="existing I420 plane blob to verify")
    ap.add_argument("--manifest", help="existing frame-plane golden JSON to verify")
    ap.add_argument("--candidate-planes", help="optional I420 candidate blob to compare against the golden")
    ap.add_argument("--expect-red", action="store_true", help="candidate comparison must fail strict equality")
    args = ap.parse_args()
    if args.verify:
        if not args.planes or not args.manifest:
            raise SystemExit("--verify requires --planes and --manifest")
        return verify(args)
    if not args.planes_out or not args.manifest_out:
        raise SystemExit("generation requires --planes-out and --manifest-out")
    return generate(args)


if __name__ == "__main__":
    raise SystemExit(main())
