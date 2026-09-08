#!/usr/bin/env python3
"""Isolated approved8KiB integration, using the existing gop12/FFmpeg oracle pattern."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
PROJECT = HERE / "project"
RTL = Path("fpga/Plex_MiSTer/rtl")
SOURCES = [
    "line_buf_ram",
    "stream_ingest", "ddr_bitstream_reader", "async_fifo", "bitstream_fifo",
    "nalu_scanner", "sps_parser", "pps_parser", "slice_hdr_parser",
    "h264_coeff_sat9", "h264_iq_idct_4x4", "h264_i16_dc_hadamard", "h264_recon",
    "h264_intra_pred", "h264_cavlc_residual", "h264_syntax_primitives",
    "h264_p_slice_modes", "h264_dpb", "h264_inter_pred", "h264_deblock",
    "h264_deblock_frame", "h264_bit_reader", "h264_residual_seq",
    "h264_slice_rbsp_ram", "h264_mb_ctrl", "decode_stub", "stream_path",
]
PROFILES = {"filter": (1, 0), "filter-off": (0, 0), "static-idr": (0, 1)}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def record(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def command(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def split_nals(data):
    starts = []
    i = 0
    while i + 3 < len(data):
        size = 4 if data[i:i+4] == b"\0\0\0\1" else 3 if data[i:i+3] == b"\0\0\1" else 0
        if size:
            starts.append((i, size, data[i+size] & 31))
            i += size + 1
        else:
            i += 1
    return [(start, starts[n+1][0] if n+1 < len(starts) else len(data), size, kind)
            for n, (start, size, kind) in enumerate(starts)]


def replace_slice_ue(data, trace, field, value):
    fields = re.findall(r"\]\s+(\d+)\s+" + re.escape(field) + r"\s+([01]+)\s+=\s+\d+", trace)
    new_code = bin(value + 1)[2:]
    new_code = "0" * (len(new_code)-1) + new_code
    output, index = bytearray(), 0
    for start, end, prefix, kind in split_nals(data):
        if kind not in (1, 5):
            output.extend(data[start:end])
            continue
        raw, zeros = bytearray(), 0
        for byte in data[start+prefix+1:end]:
            if zeros == 2 and byte == 3:
                zeros = 0
                continue
            raw.append(byte)
            zeros = min(2, zeros+1) if byte == 0 else 0
        bits = "".join(f"{byte:08b}" for byte in raw)
        offset, old = fields[index]
        offset, index = int(offset)-8, index+1
        if bits[offset:offset+len(old)] != old:
            raise RuntimeError("trace header offset did not match the original RBSP")
        # Retain every body bit and the trailing stop bit, then realign the RBSP.
        bits = bits[:offset] + new_code + bits[offset+len(old):].rstrip("0")
        bits += "0" * (-len(bits) % 8)
        output.extend(data[start:start+prefix+1])
        zeros = 0
        for i in range(0, len(bits), 8):
            byte = int(bits[i:i+8], 2)
            if zeros == 2 and byte <= 3:
                output.append(3)
                zeros = 0
            output.append(byte)
            zeros = min(2, zeros+1) if byte == 0 else 0
    if index != len(fields):
        raise RuntimeError("trace/VCL field count mismatch")
    return output


def encode(directory, name, width, height, qp, alpha, beta, filtering, chroma_offset=0):
    # Reuses h264_deblock_frame_vectors.py's colored MB/block-edge texture.
    source = bytearray()
    for frame in range(3):
        for plane in range(3):
            w, h = (width, height) if plane == 0 else (width // 2, height // 2)
            side = 16 if plane == 0 else 8

            def sample(x, y):
                x, y = max(0, min(w-1, x)), max(0, min(h-1, y))
                mbx, mby = x // side, y // side
                detail = ((x * y) % 17 - 8) if (mbx + mby) % 2 else 0
                return (64 + plane * 32 + (mbx % 5) * 9 + (mby % 4) * 7 +
                        (x % side // 4) * 4 + (y % side // 4) * 3 + detail)

            for y in range(h):
                for x in range(w):
                    if frame == 0:
                        value = sample(x, y)
                    elif frame == 1:
                        value = sample(x-1, y)
                    else:
                        value = (sample(x-1, y) + sample(x-2, y) + 1) // 2
                    source.append(value)
    raw, stream = directory / f"{name}.source.yuv", directory / f"{name}.264"
    raw.write_bytes(source)
    params = ("keyint=12:min-keyint=12:scenecut=0:bframes=0:cabac=0:ref=1:weightp=0:"
              "8x8dct=0:partitions=i4x4:subme=7:trellis=0:aq-mode=0:psy=0:"
              f"mbtree=0:chroma-qp-offset={chroma_offset}:aud=1:threads=1:"
              + (f"deblock={alpha},{beta}" if filtering else "no-deblock=1"))
    cmd = ["ffmpeg", "-v", "error", "-nostdin", "-f", "rawvideo", "-pix_fmt", "yuv420p",
           "-s", f"{width}x{height}", "-r", "24", "-i", raw, "-frames:v", "3",
           "-c:v", "libx264", "-profile:v", "baseline", "-qp", str(qp),
           "-color_range", "tv", "-colorspace", "smpte170m",
           "-x264-params", params, "-f", "h264", stream]
    command(cmd)
    trace = command(["ffmpeg", "-v", "info", "-nostdin", "-i", stream, "-c:v", "copy",
                     "-bsf:v", "trace_headers", "-f", "null", "-"], capture_output=True).stderr
    (directory / f"{name}.headers.log").write_bytes(trace)
    for start, end, prefix, kind in split_nals(stream.read_bytes()):
        if kind in (1, 5) and end-start-prefix-1 > 8192:
            raise RuntimeError(f"{name}: fixture VCL exceeds approved8KiB")
    reference = directory / f"{name}.reference-coded.yuv"
    command(["ffmpeg", "-v", "error", "-nostdin", "-flags2", "+ignorecrop",
             "-i", stream, "-frames:v", "3", "-pix_fmt", "yuv420p",
             "-f", "rawvideo", reference])
    bypass = directory / f"{name}.bypass-coded.yuv"
    command(["ffmpeg", "-v", "error", "-nostdin", "-flags2", "+ignorecrop",
             "-skip_loop_filter", "all", "-i", stream, "-frames:v", "3",
             "-pix_fmt", "yuv420p", "-f", "rawvideo", bypass])
    coded_width, coded_height = (width+15)//16*16, (height+15)//16*16
    size = coded_width * coded_height * 3 // 2
    if len(reference.read_bytes()) != 3 * size:
        raise RuntimeError("software decoder did not return complete coded geometry")
    if filtering and reference.read_bytes() == bypass.read_bytes():
        raise RuntimeError(f"{name}: filter-on fixture did not exercise filtering")
    return {"fixture": stream.name, "frames": 3, "reference": reference.name,
            "coded_width": coded_width, "coded_height": coded_height,
            "visible_width": width, "visible_height": height,
            "encoded_filter_idc": 0 if filtering else 1,
            "chroma_qp_index_offset": chroma_offset,
            "alpha_div2": alpha if filtering else 0, "beta_div2": beta if filtering else 0,
            "encode_command": [str(a) for a in cmd]}


def prepare():
    root = HERE / "fixtures"
    root.mkdir(exist_ok=True)
    directory = root / str(time.time_ns())
    directory.mkdir()
    cases = {}
    for spec in (("textured", 64, 48, 32, 2, -2, True),
                 ("residual", 64, 48, 21, 6, 6, True),
                 ("chroma-offset", 64, 48, 27, -2, 2, True, 6),
                 ("strong", 32, 32, 43, -3, 3, True),
                 ("cropped", 320, 212, 35, 2, -2, True),
                 ("full240", 320, 240, 35, 2, -2, True),
                 ("filter-off", 64, 48, 32, 0, 0, False)):
        cases[spec[0]] = encode(directory, *spec)
    for source in ("textured", "filter-off"):
        original = (directory / cases[source]["fixture"]).read_bytes()
        nals = split_nals(original)
        parameter_sets = b"".join(original[a:b] for a,b,_,t in nals if t in (7, 8))
        p = next((a,b) for a,b,_,t in nals if t == 1)
        name = source + "-no-reference"
        (directory / f"{name}.264").write_bytes(parameter_sets + original[p[0]:p[1]])
        cases[name] = {"fixture": name + ".264", "frames": 0, "expected_error": 19}
        first = next((a,b,prefix) for a,b,prefix,t in nals if t == 5)
        idr = bytearray(original[first[0]:first[1]])
        while idr and idr[-1] == 0:
            idr.pop()
        if idr[-1] & 1:
            raise RuntimeError("fixture tail has no alignment zero for the late-tail negative")
        idr[-1] |= 1
        name = source + "-bad-tail"
        (directory / f"{name}.264").write_bytes(parameter_sets + idr)
        cases[name] = {"fixture": name + ".264", "frames": 0, "expected_error": 15}
        name = source + "-missing-pps"
        (directory / f"{name}.264").write_bytes(
            b"".join(original[a:b] for a,b,_,t in nals if t == 7) + original[first[0]:first[1]])
        cases[name] = {"fixture": name + ".264", "frames": 0, "expected_error": 16}
    cases["filter-overlap"] = {"fixture": cases["textured"]["fixture"], "frames": 0,
                                "expected_error": 12}
    original = (directory / "textured.264").read_bytes()
    trace = (directory / "textured.headers.log").read_text()
    for name, field, value, error in (
        ("idc2", "disable_deblocking_filter_idc", 2, 0),
        ("bad-idc", "disable_deblocking_filter_idc", 3, 16),
        ("nonzero-first-mb", "first_mb_in_slice", 1, 2),
    ):
        stream = directory / f"{name}.264"
        stream.write_bytes(replace_slice_ue(original, trace, field, value))
        if error:
            cases[name] = {"fixture": stream.name, "frames": 0, "expected_error": error}
        else:
            reference = directory / f"{name}.reference-coded.yuv"
            command(["ffmpeg", "-v", "error", "-nostdin", "-flags2", "+ignorecrop",
                     "-i", stream, "-frames:v", "3", "-pix_fmt", "yuv420p",
                     "-f", "rawvideo", reference])
            if reference.read_bytes() != (directory / "textured.reference-coded.yuv").read_bytes():
                raise RuntimeError("single-slice idc2 differs from idc0 in the independent decoder")
            cases[name] = dict(cases["textured"], fixture=stream.name,
                               reference=reference.name, encoded_filter_idc=2)
        cases[name]["derivation"] = {"parent_fixture": "textured.264",
                                     "replaced_slice_ue": field, "value": value,
                                     "body_bits": "unchanged; RBSP tail realigned and EBSP escaped"}
    files = {p.name: digest(p.read_bytes()) for p in directory.iterdir() if p.is_file()}
    record(directory / "manifest.json", {"cases": cases, "files": files,
                                         "generator_sha256": digest(Path(__file__).read_bytes())})
    print(directory)


def rbsp_bytes(nal):
    result, zeros = bytearray(), 0
    for value in nal[1:].rstrip(b"\0"):
        if zeros >= 2 and value == 3:
            zeros = 0
            continue
        result.append(value)
        zeros = zeros + 1 if value == 0 else 0
    return result


def publisher_access_units(stream, count):
    aud = [a for a, _, _, kind in split_nals(stream) if kind == 9]
    if len(aud) < count or aud[0] != 0:
        raise RuntimeError("missing original AUD-delimited pictures")
    ends = aud[1:] + [len(stream)]
    aus = [stream[aud[i]:ends[i]] for i in range(count)]
    bounds = []
    for index, au in enumerate(aus):
        vcls = [(a, b, prefix, kind) for a, b, prefix, kind in split_nals(au) if kind in (1, 5)]
        if len(vcls) != 1 or vcls[0][3] != (5 if index == 0 else 1):
            raise RuntimeError("selected sequence must be one genuine IDR followed by single-slice P pictures")
        a, b, prefix, kind = vcls[0]
        rbsp = len(rbsp_bytes(au[a + prefix:b]))
        bounds.append({"picture": index, "nal_type": kind, "encoded_au_bytes": len(au),
                       "vcl_rbsp_bytes": rbsp})
    if any(row["vcl_rbsp_bytes"] > 8192 or row["encoded_au_bytes"] > 8192 for row in bounds):
        raise RuntimeError("unchanged8KiB admission failure: " + json.dumps(bounds))
    return aus, bounds


def prepare_publisher_pair(fixture_dir, name="textured", count=2):
    manifest_path = fixture_dir / "manifest.json"
    fixtures = json.loads(manifest_path.read_text())
    case = fixtures["cases"][name]
    if not 2 <= count <= case["frames"]:
        raise RuntimeError("publisher frame count exceeds the frozen feature fixture")
    names = [case["fixture"], case["reference"], name + ".bypass-coded.yuv"]
    data = {}
    for filename in names:
        data[filename] = (fixture_dir / filename).read_bytes()
        if digest(data[filename]) != fixtures["files"][filename]:
            raise RuntimeError(f"frozen joint input changed: {filename}")
    stream = data[case["fixture"]]
    aus, bounds = publisher_access_units(stream, count)
    width, height = case["coded_width"], case["coded_height"]
    if (width, height) != (case["visible_width"], case["visible_height"]):
        raise RuntimeError("selected joint fixture must not require new crop derivation")
    frame_bytes = width * height * 3 // 2
    reference = data[case["reference"]]
    if len(reference) != case["frames"] * frame_bytes or case["encoded_filter_idc"] != 0:
        raise RuntimeError("joint fixture lacks complete independent filtered pictures")
    reference = reference[:count * frame_bytes]
    if reference == data[name + ".bypass-coded.yuv"][:count * frame_bytes]:
        raise RuntimeError("selected pair does not require the loop filter")
    files = {
        **{f"au{i}.264": au for i, au in enumerate(aus)},
        "keyframes.bin": bytes([1] + [0] * (count - 1)),
        "reference.yuv": reference, "reference-coded.yuv": reference,
        "geometry.txt": f"{width} {height} 0 0 0 0\n".encode(),
    }
    legacy_pair = name == "textured" and count == 2
    provenance = {
        "purpose": "Small joint P/filter/lease test, not Plex original-PTS or cadence qualification",
        "parent_manifest_sha256": digest(manifest_path.read_bytes()),
        "parent_files_sha256": {name: digest(value) for name, value in data.items()},
        "annexb_derivation": "Unmodified prefix through the second picture; split only at original AUD"
            if legacy_pair else f"Unmodified first {count} pictures, split only at original AUD",
        "reference_derivation": "First two existing ordinary-FFmpeg coded pictures, comparison only"
            if legacy_pair else f"First {count} existing ordinary-FFmpeg coded pictures, comparison only",
        "original_container_pts_available": False,
        "synthetic_transport_timing": {"pts": list(range(count)), "duration": 1, "timebase": [1, 24]},
        "files": {name: digest(value) for name, value in files.items()},
    }
    if not legacy_pair:
        provenance["purpose"] = "Full-resolution joint P/filter/lease test, not original-PMS cadence qualification"
        provenance["admission"] = bounds
    files["provenance.json"] = (json.dumps(provenance, indent=2, sort_keys=True) + "\n").encode()
    directory = PROJECT / "tests/fixtures" / ("feature-textured-pair" if legacy_pair
                                             else f"feature-{name}-{count}")
    for name, value in files.items():
        if (directory / name).exists() and (directory / name).read_bytes() != value:
            raise RuntimeError(f"refusing to overwrite different prepared fixture: {name}")
    directory.mkdir(parents=True, exist_ok=True)
    for name, value in files.items():
        (directory / name).write_bytes(value)
    print(directory)


def build(profile):
    names = [RTL / f"{name}.sv" for name in SOURCES]
    names += [p.relative_to(PROJECT) for p in (PROJECT / RTL).glob("*.svh")]
    names += [Path("tests/rtl/gop12_oracle_tb.sv"), Path("tests/rtl/gop12_oracle_tb.cpp"),
              Path("scripts/run_verilator.sh"), Path("fpga/Plex_MiSTer/files.qip")]
    data = {str(name): (PROJECT / name).read_bytes() for name in names}
    hashes = {name: digest(value) for name, value in data.items()}
    defines = ["-DCAVLC_WINDOW_BYTES=8", "-DCAVLC_LEVEL_LANES=1"]
    key = digest(json.dumps({"profile": profile, "inputs": hashes, "defines": defines},
                            sort_keys=True).encode())
    directory = HERE / "builds" / profile / key
    manifest = directory / "build.json"
    if manifest.exists():
        old = json.loads(manifest.read_text())
        if old["binary_sha256"] != digest((directory / "obj/Vgop12_oracle_tb").read_bytes()):
            raise RuntimeError("frozen binary changed")
        for name, expected in old["inputs"].items():
            if digest((directory / "inputs" / name).read_bytes()) != expected:
                raise RuntimeError(f"frozen source changed: {name}")
        return directory
    directory.mkdir(parents=True, exist_ok=True)
    snapshot = directory / "inputs"
    for name, value in data.items():
        path = snapshot / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value)
    scratch = directory / "compiler-scratch"
    scratch.mkdir(exist_ok=True)
    filtering, static_idr = PROFILES[profile]
    cmd = ["bash", snapshot / "scripts/run_verilator.sh", "--cc", "--exe", "--build", "-j", "1",
           "--Mdir", directory / "obj", "--top-module", "gop12_oracle_tb",
           "-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-Wno-PINMISSING",
           "-I" + str(snapshot / RTL), "-CFLAGS", "-std=c++17 -O2",
           f"-GENABLE_FRAME_DEBLOCK={filtering}", f"-GSTATIC_IDR_ONLY={static_idr}"]
    cmd += defines
    cmd += [snapshot / RTL / f"{name}.sv" for name in SOURCES]
    cmd += [snapshot / "tests/rtl/gop12_oracle_tb.sv", snapshot / "tests/rtl/gop12_oracle_tb.cpp"]
    with (directory / "compile.log").open("w") as log:
        command(cmd, cwd=snapshot, env=dict(os.environ, TMPDIR=str(scratch)),
                stdout=log, stderr=subprocess.STDOUT)
    record(manifest, {"profile": profile, "inputs": hashes, "source_key": key,
                      "command": [str(a) for a in cmd],
                      "binary_sha256": digest((directory / "obj/Vgop12_oracle_tb").read_bytes())})
    return directory


def prepare_publisher_gop(fixture_path):
    expected = "42b5fd57dae44fd3855820b7c73c595932043a138d2801ff0a8d73aef9033aee"
    stream = fixture_path.read_bytes()
    parent = json.loads(fixture_path.with_name("provenance.json").read_text())
    if digest(stream) != expected or parent["annexb_sha256"] != expected:
        raise RuntimeError("selected known colored-motion GOP12 identity changed")
    aus, bounds = publisher_access_units(stream, 12)
    if sum(len(au) for au in aus) != len(stream):
        raise RuntimeError("GOP12 selection would drop original encoded bytes")
    directory = PROJECT / "tests/fixtures/color-gop12-320x240"
    if directory.exists():
        raise RuntimeError("refusing to overwrite preserved GOP12 fixture preparation")
    probe_command = ["ffprobe", "-v", "error", "-select_streams", "v:0",
                     "-show_entries", "stream=width,height,pix_fmt,has_b_frames:frame=pict_type,key_frame",
                     "-show_frames", "-of", "json", fixture_path]
    probe = json.loads(command(probe_command, capture_output=True).stdout)
    video = probe["streams"][0]
    if (video["width"], video["height"], video["pix_fmt"], video["has_b_frames"]) != (320, 240, "yuv420p", 0):
        raise RuntimeError("known GOP does not have the required unconverted full-resolution I420 format")
    if [frame["pict_type"] for frame in probe["frames"]] != ["I"] + ["P"] * 11:
        raise RuntimeError("ordinary decoder did not confirm twelve genuine I/P pictures")
    trace_command = ["ffmpeg", "-v", "info", "-nostdin", "-i", fixture_path,
                     "-c:v", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"]
    trace = command(trace_command, capture_output=True).stderr.decode()
    filter_idc = [int(value) for value in re.findall(
        r"disable_deblocking_filter_idc\s+[01]+\s+=\s+(\d+)", trace)]
    if filter_idc != [0] * 12:
        raise RuntimeError(f"selected GOP filtering syntax differs: {filter_idc}")
    directory.mkdir(parents=True)
    reference_path = directory / "reference-coded.yuv"
    decode_command = ["ffmpeg", "-v", "error", "-nostdin", "-i", fixture_path,
                      "-frames:v", "12", "-pix_fmt", "yuv420p", "-f", "rawvideo", reference_path]
    command(decode_command)
    reference = reference_path.read_bytes()
    if len(reference) != 12 * 115200:
        raise RuntimeError("ordinary FFmpeg did not return all full-resolution reference pictures")
    files = {**{f"au{i}.264": au for i, au in enumerate(aus)},
             "keyframes.bin": bytes([1] + [0] * 11),
             "reference.yuv": reference, "reference-coded.yuv": reference,
             "geometry.txt": b"320 240 0 0 0 0\n"}
    for name, data in files.items():
        (directory / name).write_bytes(data)
    record(directory / "provenance.json", {
        "parent_fixture_sha256": expected,
        "parent_provenance_sha256": digest(fixture_path.with_name("provenance.json").read_bytes()),
        "admission": bounds, "encoded_filter_idc": filter_idc,
        "decode_command": [str(value) for value in decode_command],
        "probe_command": [str(value) for value in probe_command],
        "trace_command": [str(value) for value in trace_command],
        "ordinary_decode_probe": probe,
        "original_container_pts_available": False,
        "synthetic_transport_timing": {"pts": list(range(12)), "duration": 1, "timebase": [1, 24]},
        "motion_coverage": "Only actual DUT prediction/residual observations qualify coverage, not intended motion",
        "source_derivation": "All original bytes split only at AUD; no patch, re-encode, resize or reference-pixel injection",
        "files": {name: digest(data) for name, data in files.items()},
    })
    print(directory)


def run(profile, fixture_dir, selected):
    fixtures = json.loads((fixture_dir / "manifest.json").read_text())
    for name, expected in fixtures["files"].items():
        if digest((fixture_dir / name).read_bytes()) != expected:
            raise RuntimeError(f"fixture changed: {name}")
    directory = build(profile)
    runs = directory / "runs"
    runs.mkdir(exist_ok=True)
    run_dir = runs / str(time.time_ns())
    run_dir.mkdir()
    (run_dir / "run_driver.py").write_bytes(Path(__file__).read_bytes())
    results = []
    for name in selected:
        case = dict(fixtures["cases"][name])
        if profile in ("filter-off", "static-idr") and case.get("encoded_filter_idc", 1) != 1:
            case.update(frames=0, expected_error=1)
        if profile == "static-idr" and name == "filter-off":
            case.update(frames=1, expected_error=19)
        actual, events = run_dir / f"{name}.actual.yuv", run_dir / f"{name}.events.jsonl"
        cmd = [directory / "obj/Vgop12_oracle_tb", fixture_dir / case["fixture"],
               actual, events, str(case["frames"])]
        if case.get("expected_error"):
            cmd.append(str(case["expected_error"]))
        with (run_dir / f"{name}.simulation.log").open("w") as log:
            result = subprocess.run([str(a) for a in cmd], stdout=log, stderr=subprocess.STDOUT)
        outcome = {"case": name, "return_code": result.returncode, "command": [str(a) for a in cmd],
                   "pass": False, "actual_sha256": digest(actual.read_bytes())}
        if result.returncode == 0:
            rows = [json.loads(line) for line in events.read_text().splitlines()]
            outcome["events"] = rows
            if case.get("expected_error"):
                outcome["pass"] = bool(rows and rows[-1].get("rejected") and
                                       rows[-1]["decoder_error"] == case["expected_error"])
                if case["frames"]:
                    size = case["coded_width"] * case["coded_height"] * 3 // 2
                    outcome["pass"] &= actual.read_bytes() == (fixture_dir / case["reference"]).read_bytes()[:size * case["frames"]]
            else:
                reference = (fixture_dir / case["reference"]).read_bytes()
                produced = actual.read_bytes()
                mismatches = sum(a != b for a,b in zip(produced, reference))
                outcome.update(reference_sha256=digest(reference), compared_samples=len(reference),
                               mismatches=mismatches, actual_bytes=len(produced))
                outcome["pass"] = len(produced) == len(reference) and mismatches == 0
                if not outcome["pass"]:
                    first = next((i for i,(a,b) in enumerate(zip(produced, reference)) if a != b), None)
                    outcome["first_mismatch"] = None if first is None else {
                        "offset": first, "actual": produced[first], "reference": reference[first]}
        results.append(outcome)
        print(f"{'PASS' if outcome['pass'] else 'FAIL'} {profile}/{name} rc={result.returncode}", flush=True)
    record(run_dir / "result.json", {"profile": profile, "fixture_manifest": str(fixture_dir / "manifest.json"),
                                    "fixture_manifest_sha256": digest((fixture_dir / "manifest.json").read_bytes()),
                                    "build_manifest_sha256": digest((directory / "build.json").read_bytes()),
                                    "driver_sha256": digest((run_dir / "run_driver.py").read_bytes()),
                                    "cases": results, "pass": all(row["pass"] for row in results)})
    print(run_dir / "result.json")
    return 0 if all(row["pass"] for row in results) else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    preparation = parser.add_mutually_exclusive_group()
    preparation.add_argument("--prepare", action="store_true")
    preparation.add_argument("--prepare-publisher-pair", action="store_true")
    preparation.add_argument("--prepare-publisher-gop", type=Path)
    parser.add_argument("--profile", choices=PROFILES, default="filter")
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--publisher-fixture", default="textured")
    parser.add_argument("--publisher-frames", type=int, default=2)
    parser.add_argument("--cases", nargs="+", default=["textured"])
    options = parser.parse_args()
    if options.prepare:
        prepare()
    elif options.prepare_publisher_pair:
        if options.fixtures is None:
            parser.error("--fixtures is required")
        prepare_publisher_pair(options.fixtures.resolve(), options.publisher_fixture, options.publisher_frames)
    elif options.prepare_publisher_gop:
        prepare_publisher_gop(options.prepare_publisher_gop.resolve())
    else:
        if options.fixtures is None:
            parser.error("--fixtures is required")
        sys.exit(run(options.profile, options.fixtures.resolve(), options.cases))
