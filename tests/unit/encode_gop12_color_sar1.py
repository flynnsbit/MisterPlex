#!/usr/bin/env python3
"""Encode a separate square-SAR, legally filter-off color GOP12."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "tests/fixtures/gop12_oracle_color/textured_color_fractional_320x240_12f.264"
PREVIOUS = ROOT / "tests/fixtures/gop12_oracle_color_filter_off/textured_color_fractional_filter_off_320x240_12f.264"
DEST = ROOT / "tests/fixtures/gop12_oracle_color_sar1_filter_off"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def vcl_units(path):
    data = path.read_bytes()
    starts = list(re.finditer(rb"\x00\x00(?:\x00)?\x01", data))
    return [data[start.end():starts[i + 1].start() if i + 1 < len(starts) else len(data)]
            for i, start in enumerate(starts) if data[start.end()] & 31 in (1, 5)]


def main():
    output = DEST / "textured_color_sar1_filter_off_320x240_12f.264"
    if output.exists():
        raise SystemExit("refusing to overwrite the frozen square-SAR fixture")
    for source in (SOURCE, PREVIOUS):
        if sha(source) != json.loads((source.parent / "provenance.json").read_text())["annexb_sha256"]:
            raise SystemExit("original local fixture provenance mismatch")
    DEST.mkdir(parents=True, exist_ok=True)
    build = ROOT / "build/gop12-oracle-color-sar1"
    build.mkdir(parents=True, exist_ok=True)
    ffmpeg = str(Path(shutil.which("ffmpeg") or "ffmpeg").resolve())
    command = [
        ffmpeg, "-hide_banner", "-nostdin", "-threads", "1", "-i", str(SOURCE),
        "-frames:v", "12", "-an", "-r", "24", "-vf", "setsar=1", "-pix_fmt", "yuv420p",
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
    if vcl_units(output) != vcl_units(PREVIOUS):
        raise SystemExit("new encoding changed VCL payloads; retain it for inspection, do not claim equivalence")
    provenance = {
        "license": "GPL-2.0-or-later; original procedural test artwork, no external media",
        "kind": "separate local ordinary x264 encoding with explicit SAR1, not PMS or header patching",
        "source_generator": str(Path(__file__).resolve().relative_to(ROOT)),
        "generator_sha256": sha(Path(__file__)),
        "source_files": {str(path.relative_to(ROOT)): sha(path) for path in (SOURCE, PREVIOUS)},
        "annexb_sha256": sha(output),
        "encoder_sha256": sha(Path(ffmpeg)),
        "encoder_version": subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0],
        "encoder_command": command,
        "encoder_log": log.read_text(),
        "required_disable_deblocking_filter_idc": 1,
        "vcl_payloads_equal_previous_filter_off_fixture": True,
        "scope": "No resizing, old fixture edits, decoder filtering override, or native/reference injection.",
    }
    (DEST / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(output.relative_to(ROOT), provenance["annexb_sha256"])


if __name__ == "__main__":
    main()
