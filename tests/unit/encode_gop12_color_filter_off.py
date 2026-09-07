#!/usr/bin/env python3
"""Encode a separate legal filter-off color stream; never change oracle filtering."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "tests/fixtures/gop12_oracle_color/textured_color_fractional_320x240_12f.264"
DEST = ROOT / "tests/fixtures/gop12_oracle_color_filter_off"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    output = DEST / "textured_color_fractional_filter_off_320x240_12f.264"
    if output.exists():
        raise SystemExit("refusing to overwrite frozen filter-off fixture")
    source_provenance = json.loads((SOURCE.parent / "provenance.json").read_text())
    if sha(SOURCE) != source_provenance["annexb_sha256"]:
        raise SystemExit("original local color fixture provenance mismatch")
    DEST.mkdir(parents=True, exist_ok=True)
    build = ROOT / "build/gop12-oracle-color-filter-off"
    build.mkdir(parents=True, exist_ok=True)
    ffmpeg = str(Path(shutil.which("ffmpeg") or "ffmpeg").resolve())
    command = [
        ffmpeg, "-hide_banner", "-nostdin", "-threads", "1", "-i", str(SOURCE),
        "-frames:v", "12", "-an", "-r", "24", "-pix_fmt", "yuv420p",
        "-c:v", "libx264", "-preset", "medium", "-profile:v", "baseline",
        "-level:v", "3.0", "-qp", "25", "-x264-params",
        "keyint=12:min-keyint=12:scenecut=0:bframes=0:ref=1:weightp=0:"
        "8x8dct=0:partitions=none:aq-mode=0:mbtree=0:psy=0:ipratio=1.0:"
        "threads=1:sliced-threads=0:aud=1:repeat-headers=1:no-deblock=1",
        "-f", "h264", str(output),
    ]
    log = build / "encode.log"
    with log.open("w") as stream:
        subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)
    provenance = {
        "license": "GPL-2.0-or-later; derived only from original procedural test artwork",
        "kind": "local re-encode, not PMS capture; original stream ordinarily decoded as encoder input",
        "source_generator": str(Path(__file__).resolve().relative_to(ROOT)),
        "generator_sha256": sha(Path(__file__)),
        "source_annexb": str(SOURCE.relative_to(ROOT)),
        "source_annexb_sha256": sha(SOURCE),
        "annexb_sha256": sha(output),
        "encoder_sha256": sha(Path(ffmpeg)),
        "encoder_version": subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0],
        "encoder_command": command,
        "encoder_log": log.read_text(),
        "filter_scope": "x264 encodes disabled deblocking syntax; every decoder retains normal defaults",
        "required_disable_deblocking_filter_idc": 1,
    }
    (DEST / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(output.relative_to(ROOT), provenance["annexb_sha256"])


if __name__ == "__main__":
    main()
