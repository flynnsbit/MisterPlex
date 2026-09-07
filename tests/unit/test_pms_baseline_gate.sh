#!/usr/bin/env bash
# Real compressed offline fixtures exercise syntax; they are not real-PMS evidence.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PROBE="$ROOT/build/pms_baseline_probe"
WORK="$ROOT/build/pms-baseline-gate"
mkdir -p "$WORK"
command -v ffmpeg >/dev/null || { echo "SKIP-NOT-PASS: ffmpeg missing"; exit 77; }
[[ "$("$PROBE" --probe-abi)" == 6 ]] || { echo "FAIL: stale profile probe ABI"; exit 1; }
python3 - "$ROOT" "$WORK" "$PROBE" <<'PY'
from pathlib import Path
import importlib.util
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

root, work, probe = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
contract = json.loads(subprocess.check_output([probe, "--probe-contract"]))
max_au = contract["max_au_bytes"]
generator = root / "assets/plex-profiles/generate_profiles.py"
spec = importlib.util.spec_from_file_location("profiles", generator)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def encode(name, *, prototype="ip", fps="24", filtering="on", size="320x240",
           extra="", profile="baseline", frames=48, sample_aspect=None, color=None):
    opts = ("cabac=0:bframes=0:ref=1:weightp=0:8x8dct=0:partitions=none:"
            "scenecut=0:threads=1:slices=1:qpmin=10:qpmax=40:vbv-maxrate=4000:vbv-bufsize=1000:"
            f"keyint={1 if prototype == 'idr' else 24}:"
            f"no-deblock={int(filtering == 'off')}" + extra)
    path = work / f"{name}.264"
    filters, color_args = [], []
    if color:
        matrix, value_range = color
        tag = "smpte170m" if matrix == "bt601" else "bt709"
        # Convert generated RGB samples; these tests do not merely retag existing encoded pixels.
        filters += [f"scale=in_range=pc:out_range={value_range}:out_color_matrix={matrix}",
                    "format=yuv420p"]
        color_args = ["-color_range", value_range, "-colorspace", tag,
                      "-color_primaries", tag, "-color_trc", tag]
    if sample_aspect:
        filters.append("setsar="+sample_aspect)
    source = "testsrc" if color else "testsrc2"
    subprocess.run(["ffmpeg", "-v", "error", "-filter_threads", "1", "-f", "lavfi",
                    "-i", f"{source}=s={size}:r={fps}",
                    "-frames:v", str(frames),
                    *(["-vf", ",".join(filters)] if filters else []),
                    "-c:v", "libx264", "-profile:v", profile,
                    "-x264-params", opts, *color_args, "-f", "h264", "-y", str(path)], check=True)
    return path

def check(path, *, prototype="ip", fps="24", filtering="on", red=None, more=()):
    args = [probe, "--annexb", str(path), "--prototype", prototype, "--fps", fps,
            "--filter", filtering, *more]
    result = subprocess.run(args, capture_output=True, text=True)
    output = result.stdout + result.stderr
    if red is None:
        assert result.returncode == 0, output
        assert "syntax-only" in output and "PCM=0" in output, output
    else:
        assert result.returncode != 0 and red in output, (red, output)

for prototype in ("idr", "ip"):
    for fps, rate in (("24", "24"), ("24000/1001", "23976")):
        for filtering in ("on", "off"):
            name, text = module.profile(prototype.upper(), rate, "filter-"+filtering)
            xml = root / f"assets/plex-profiles/{name}.xml"
            assert xml.read_text().split("\n", 1)[1] == text, f"stale generated {name}"
            tree = ET.fromstring(text)
            flags = tree.find(".//Setting[@name='VideoEncodeFlags']").attrib["value"]
            assert "-c:v libx264" in flags and "partitions=none" in flags
            assert "vbv-maxrate=4000:vbv-bufsize=1000" in flags
            assert not tree.findall("DirectPlayProfiles")
            path = encode(name, prototype=prototype, fps=fps, filtering=filtering)
            check(path, prototype=prototype, fps=fps, filtering=filtering,
                  more=("--require-full-size",))

green = encode("green")
check(green)
check(green, more=("--require-limited-bt601",), red="limited-BT601 signaling unproven")
color_report = work/"limited_bt601.json"
check(encode("limited_bt601", color=("bt601", "tv")),
      more=("--require-limited-bt601", "--json", str(color_report)))
color_data = json.loads(color_report.read_text())
assert color_data["limited_bt601_signaling_ok"]
assert color_data["geometry"][0]["color"]["full_range_flag"] == 0
assert color_data["geometry"][0]["color"]["matrix_coefficients"] == 6
for name, color, reason in (("full_bt601", ("bt601", "pc"), "unsupported full-range"),
                             ("limited_bt709", ("bt709", "tv"), "unsupported matrix_coefficients=1")):
    color_report = work/f"{name}.json"
    check(encode(name, color=color), more=("--json", str(color_report)), red=reason)
    color_data = json.loads(color_report.read_text())
    assert color_data["syntax_complete"] and not color_data["limited_bt601_signaling_ok"]
check(green, more=("--max-au-bytes", str(max_au+1)), red="transport ceiling")
check(green, more=("--max-au-bytes", "0"), red="zero")
check(green, more=("--max-au-bytes", "1024"), red="AU exceeds selected bound=1024")
# Valid filler keeps the codec syntax intact while exceeding a smaller consumer's AU budget.
oversized = work/"consumer_8192_overflow.264"
oversized.write_bytes(b"\x00\x00\x00\x01\x0c"+b"\xff"*8192+b"\x80"+green.read_bytes())
check(oversized)
check(oversized, more=("--max-au-bytes", "8192"), red="AU exceeds selected bound=8192")
check(oversized, more=("--max-vcl-rbsp-bytes", "8192"))
check(green, more=("--max-vcl-rbsp-bytes", "1024"), red="VCL RBSP exceeds selected bound=1024")
# Exact AU-envelope tests only: synthetic filler is not an encoder/VBV qualification sample.
data = green.read_bytes()
starts = list(re.finditer(b"\x00\x00\x00\x01|\x00\x00\x01", data))
vcl = [m.start() for m in starts if data[m.end()] & 31 in (1, 5)]
first_au_bytes = vcl[1]
for extra, red in ((0, None), (1, "AU exceeds selected bound="),
                   (32, "AU exceeds selected bound=")):
    added = max_au+extra-first_au_bytes
    assert added >= 6
    boundary = work/f"transport_boundary_plus{extra}.264"
    boundary.write_bytes(b"\x00\x00\x00\x01\x0c"+b"\xff"*(added-6)+b"\x80"+data)
    report = work/f"transport_boundary_plus{extra}.json"
    check(boundary, more=("--json", str(report)), red=red)
    if red is None:
        assert json.loads(report.read_text())["max_au_bytes"] == max_au
check(green, prototype="idr", red="all-IDR contract emitted non-IDR")
check(green, filtering="off", red="deblocking policy")
check(green, fps="24000/1001", red="VUI film rate")
check(green, more=("--mode", "480p"), red="RESERVED")
check(encode("oversize", size="640x480"), red="exceeds declared 320x240")
check(encode("crop", size="318x238"))
check(work/"crop.264", more=("--require-full-size",), red="not a full-sized")
for name, size, expected in (("short", "320x192", (320, 192, 20, 12, 240)),
                             ("variable_stride", "300x212", (304, 224, 19, 14, 266))):
    report = work/f"{name}.json"
    path = encode(name, size=size)
    check(path, more=("--json", str(report)))
    measured = json.loads(report.read_text())
    geometry = measured["geometry"][0]
    assert tuple(geometry[k] for k in ("coded_width", "coded_height", "mb_columns",
                                     "mb_rows", "macroblocks_per_picture")) == expected
    assert measured["mb"] == 48*expected[-1], "short picture incorrectly waits for300MB"
    assert geometry["packed_i420"]["y_stride"] == expected[0]
    assert geometry["packed_i420"]["chroma_stride"] == expected[0]//2
    if name == "variable_stride":
        assert (geometry["visible_width"], geometry["visible_height"]) == (300, 212)
        assert geometry["crop_pixels_lrtb"] == [0, 4, 0, 12]
        assert geometry["packed_i420"]["frame_bytes"] == 102144
    check(path, more=("--require-full-size",), red="not a full-sized")
for name, sar, known in (("anamorphic", "4/3", True), ("unspecified_sar", "0/1", False)):
    report = work/f"{name}.json"
    check(encode(name, sample_aspect=sar), more=("--json", str(report)))
    geometry = json.loads(report.read_text())["geometry"][0]
    assert geometry["sar_known"] == known
    if known:
        assert (geometry["bitstream_dar_num"], geometry["bitstream_dar_den"]) == (16, 9)
    else:
        assert geometry["bitstream_dar_num"] is None and geometry["bitstream_dar_den"] is None
check(encode("bad_ref", extra=":ref=4"), red="max_num_ref_frames=4")
check(encode("bad_b", extra=":bframes=2", profile="main"), red="profile_idc=77")
check(encode("bad_high", profile="high", extra=":8x8dct=1:partitions=all"),
      red="profile_idc=100")
check(encode("bad_partitions", extra=":partitions=all"), red="P partition unsupported")
check(encode("bad_fps", fps="25"), red="VUI film rate")
check(encode("bad_gop", extra=":keyint=50"), red="GOP exceeds")
check(encode("bad_hrd", extra=":nal-hrd=vbr"), red="NAL HRD")
check(encode("bad_pic_struct", extra=":pic-struct=1"), red="pic_struct_present_flag")

# Change Baseline PPS entropy flag, rather than relying on x264 to emit illegal Baseline.
data = bytearray(green.read_bytes())
marker = data.find(b"\x00\x00\x00\x01\x68")
assert marker >= 0
data[marker+5] |= 0x20  # PPS/SPS ids=0 occupy the first two one-bits.
(work/"bad_cabac.264").write_bytes(data)
check(work/"bad_cabac.264", red="entropy_cabac=1")
data = bytearray(green.read_bytes())
marker = data.find(b"\x00\x00\x00\x01\x67")
assert marker >= 0
data[marker+6] &= ~0x40
(work/"bad_constraint_set1.264").write_bytes(data)
check(work/"bad_constraint_set1.264", red="constraint_set1_flag=0")
(work/"truncated.264").write_bytes(green.read_bytes()[:100])
check(work/"truncated.264", red="incomplete multi-picture stream")
# A later parameter set cannot hide behind the first valid SPS.
(work/"late_bad_sps.264").write_bytes(green.read_bytes()+(work/"oversize.264").read_bytes())
check(work/"late_bad_sps.264", red="exceeds declared")
print("test_pms_baseline_gate: OK eight real compressed fixtures plus bounded red gates; offline only")
PY
set +e
missing_out="$(env -u PLEX_BASE -u PLEX_TOKEN -u MISTERPLEX_BASELINE_KEY -u PLEX_KEY \
  MISTERPLEX_CONF="$WORK/missing.conf" MISTER_CONF= \
  bash "$ROOT/tests/hw/test_pms_baseline_profile.sh" 2>&1)"
missing_rc=$?
set -e
[[ "$missing_rc" == 77 && "$missing_out" == *SKIP-NOT-PASS* ]] || {
  echo "FAIL: missing live inputs were not SKIP-NOT-PASS rc77"; exit 1;
}
