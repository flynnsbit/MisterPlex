#!/usr/bin/env python3
"""Encode original color texture moving in both directions; measure actual MVs separately."""
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "tests/fixtures/gop12_oracle_bidirectional"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    output = DEST / "bidirectional_color_sar1_filter_off_320x240_12f.264"
    if output.exists():
        raise SystemExit("refusing to overwrite the frozen bidirectional fixture")
    DEST.mkdir(parents=True, exist_ok=True)
    build = ROOT / "build/gop12-oracle-bidirectional"
    build.mkdir(parents=True, exist_ok=True)
    source = build / "source.i420"
    with source.open("wb") as raw:
        for frame in range(12):
            position = min(frame, 12 - frame)
            for plane, (width, height) in enumerate(((320, 240), (160, 120), (160, 120))):
                pixels = bytearray()
                for y in range(height):
                    for x in range(width):
                        scale = 1 if plane == 0 else 2
                        sx, sy = scale * x - position * 0.75, scale * y - position * 0.25
                        if plane == 0:
                            value = (125 + 38 * math.sin(sx / 9) + 27 * math.cos(sy / 11)
                                     + 18 * math.sin((sx + 2 * sy) / 17))
                        elif plane == 1:
                            value = 124 + 48 * math.sin((sx + sy) / 29) + 24 * math.cos(sy / 17)
                        else:
                            value = 131 + 43 * math.cos((2 * sx - sy) / 37) + 27 * math.sin(sx / 19)
                        pixels.append(max(16, min(235, round(value))))
                raw.write(pixels)
    ffmpeg = str(Path(shutil.which("ffmpeg") or "ffmpeg").resolve())
    command = [
        ffmpeg, "-hide_banner", "-nostdin", "-f", "rawvideo", "-pixel_format", "yuv420p",
        "-video_size", "320x240", "-framerate", "24", "-i", str(source), "-frames:v", "12",
        "-vf", "setsar=1", "-an", "-c:v", "libx264", "-preset", "medium",
        "-profile:v", "baseline", "-level:v", "3.0", "-qp", "25", "-x264-params",
        "keyint=12:min-keyint=12:scenecut=0:bframes=0:ref=1:weightp=0:8x8dct=0:partitions=none:"
        "aq-mode=0:mbtree=0:psy=0:ipratio=1.0:threads=1:sliced-threads=0:aud=1:"
        "repeat-headers=1:no-deblock=1", "-f", "h264", str(output)]
    log = build / "encode.log"
    with log.open("w") as stream:
        subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)
    provenance = {
        "license": "GPL-2.0-or-later; original procedural test artwork, no external media",
        "kind": "local source encoder fixture, not PMS or altered captured bytes",
        "source_generator": str(Path(__file__).resolve().relative_to(ROOT)),
        "generator_sha256": sha(Path(__file__)), "source_i420_sha256": sha(source),
        "annexb_sha256": sha(output), "encoder_sha256": sha(Path(ffmpeg)),
        "encoder_version": subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0],
        "encoder_command": command, "encoder_log": log.read_text(),
        "required_disable_deblocking_filter_idc": 1,
        "intended_motion_only": "position=min(frame,12-frame), shifted by (0.75,0.25) luma pixels per position; verify actual exported vectors and tap bounds",
    }
    (DEST / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(output.relative_to(ROOT), provenance["annexb_sha256"])


if __name__ == "__main__":
    main()
