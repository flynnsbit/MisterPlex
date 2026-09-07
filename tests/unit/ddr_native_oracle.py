"""Actual DDR-ring input and accepted native samples; no reference data enters RTL."""
from fractions import Fraction
import hashlib
import json
import re
import subprocess
import time

from gop12_oracle import ROOT, checked, file_hash, motion_coverage, simulate, slice_headers, verify_build, verify_files, write_json
from check_pms_capture_oracle import geometry_from_trace, require, vcl_sizes


def compare_native(actual, oracle, width, height, count):
    size = width * height * 3 // 2
    require(count > 0 and len(actual) == len(oracle) == count * size,
            "actual/reference coded native byte count mismatch")
    result = {"exact": True, "mismatches": 0, "frames": [], "first_mismatch": None}
    for index in range(count):
        planes = {}
        offset = index * size
        for name, w, h in (("Y", width, height), ("U", width // 2, height // 2),
                           ("V", width // 2, height // 2)):
            a, b = actual[offset:offset + w * h], oracle[offset:offset + w * h]
            errors = [abs(x - y) for x, y in zip(a, b)]
            wrong = sum(value != 0 for value in errors)
            planes[name] = {"samples": w * h, "mismatches": wrong,
                            "mae": sum(errors) / (w * h), "max_error": max(errors),
                            "actual_sha256": hashlib.sha256(a).hexdigest(),
                            "oracle_sha256": hashlib.sha256(b).hexdigest()}
            result["mismatches"] += wrong
            if wrong and result["first_mismatch"] is None:
                first = next(i for i, value in enumerate(errors) if value)
                result["first_mismatch"] = {"index": index, "plane": name, "x": first % w,
                                            "y": first // w, "actual": a[first], "oracle": b[first]}
            offset += w * h
        result["frames"].append({"index": index, "planes": planes})
    result["exact"] = result["mismatches"] == 0
    return result


def run_ddr(build, manifest, fixture):
    count = manifest["expected_frames"]
    out = build / "runs" / str(time.time_ns())
    out.mkdir(parents=True)
    ffmpeg, ffprobe = manifest["tools"]["ffmpeg"]["path"], manifest["tools"]["ffprobe"]["path"]
    packet_command = [ffprobe, "-v", "error", "-show_packets", "-show_streams",
                      "-select_streams", "v:0", "-of", "json", str(fixture)]
    source = json.loads(checked(packet_command))
    write_json(out / "source-packets.json", source)
    packets = source["packets"][:count]
    require(len(packets) == count, "missing complete access units")
    data = fixture.read_bytes()
    end = 0
    for index, packet in enumerate(packets):
        offset, size = int(packet["pos"]), int(packet["size"])
        require(offset == end and 0 < size <= manifest["au_input_limit_bytes"] and offset + size <= len(data),
                "AU continuity or requested input limit rejected fixture")
        (out / f"au{index}.264").write_bytes(data[offset:offset + size])
        end += size
    prefix = out / "tested-prefix.264"
    prefix.write_bytes(data[:end])
    vcls = vcl_sizes(data[:end])
    require(len(vcls) == count and vcls[0]["nal_type"] == 5, "one VCL/AU, beginning with actual IDR required")
    frame_command = [ffprobe, "-v", "error", "-show_frames", "-show_streams",
                     "-select_streams", "v:0", "-of", "json", str(prefix)]
    probe = json.loads(checked(frame_command))
    write_json(out / "ffprobe.json", probe)
    frames = probe["frames"]
    require(len(frames) == count, "ordinary decoder frame identities incomplete")
    pixel_format = frames[0]["pix_fmt"]
    require(pixel_format in ("yuv420p", "yuvj420p") and all(f["pix_fmt"] == pixel_format for f in frames),
            "native 8-bit planar 4:2:0 required")
    headers, header_command = slice_headers(ffmpeg, prefix, out / "headers.log", count)
    geometry = geometry_from_trace(out / "headers.log")
    cw, ch = geometry["coded_width"], geometry["coded_height"]
    vw, vh = geometry["display_width"], geometry["display_height"]
    require(0 < cw <= 320 and 0 < ch <= 240 and all(
        (f["width"], f["height"]) == (vw, vh) for f in frames), "coded/display geometry outside native allocation")
    if manifest.get("required_disable_deblocking_filter_idc") is not None:
        require(all(h["disable_deblocking_filter_idc"] == manifest["required_disable_deblocking_filter_idc"]
                    for h in headers), "encoded filtering differs from frozen provenance")
    decode_command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-threads", "1",
                      "-apply_cropping", "0", "-i", str(prefix), "-map", "0:v:0",
                      "-fps_mode", "passthrough", "-pix_fmt", pixel_format, "-f", "rawvideo",
                      str(out / "oracle.i420")]
    subprocess.run(decode_command, cwd=ROOT, check=True)
    reference = (out / "oracle.i420").read_bytes()
    compare_native(reference, reference, cw, ch, count)
    metadata = []
    source_dar = None
    if manifest["pts_sidecar"]:
        sidecar = json.loads((build / "inputs" / manifest["pts_sidecar"]).read_text())
        source_dar = sidecar.get("source_plex_display_aspect_ratio")
        require(file_hash(fixture) in (sidecar.get("prefix_sha256"), sidecar.get("source_annexb_sha256")),
                "original PTS sidecar is not bound to this exact fixture")
        require(len(sidecar["frames"]) >= count, "original PTS sidecar is incomplete")
        for i, row in enumerate(sidecar["frames"][:count]):
            require(row["index"] == i and row["au_sha256"] == file_hash(out / f"au{i}.264"),
                    "original PTS identity/AU payload mismatch")
            base = Fraction(row["time_base"])
            metadata.append({"pts": row["original_pts"], "duration": row["original_duration"],
                             "timebase_num": base.numerator, "timebase_den": base.denominator,
                             "source_pts": row["original_pts"],
                             "source_frame_index": row.get("source_frame_index", row["index"]),
                             "source_annexb_offset": row.get("source_annexb_offset", row["annexb_offset"])})
        pts_scope = "Original capture PTS/duration/timebase, independently AU-hash matched."
    else:
        require(manifest["fixture_timeline"], "raw Annex-B has no original PTS")
        rate_text = probe["streams"][0]["avg_frame_rate"]
        if rate_text == "0/0":
            rate_text = probe["streams"][0]["r_frame_rate"]
        rate = Fraction(rate_text)
        require(rate > 0, "fixture has no declared positive rate")
        metadata = [{"pts": i, "duration": 1, "timebase_num": rate.denominator,
                     "timebase_den": rate.numerator, "source_pts": None,
                     "source_frame_index": i, "source_annexb_offset": int(packets[i]["pos"])} for i in range(count)]
        pts_scope = "EXPLICIT synthetic local-fixture timeline at declared rate; original Annex-B PTS remain absent."
    left, right, top, bottom = geometry["crop_left_right_top_bottom"]
    with (out / "au-metadata.txt").open("w") as output:
        output.write(f"{count}\n")
        for i, (m, packet) in enumerate(zip(metadata, packets)):
            m.update(index=i, flags=int(vcls[i]["nal_type"] == 5), annexb_pts=frames[i].get("pts"),
                     au_sha256=file_hash(out / f"au{i}.264"))
            values = [i, m["pts"], m["duration"], m["timebase_num"], m["timebase_den"], m["flags"],
                      cw, ch, vw, vh, left, right, top, bottom, geometry["sar_num"], geometry["sar_den"]]
            output.write(" ".join(map(str, values)) + "\n")
    write_json(out / "expected-identities.json", metadata)
    controls = {}
    for name, offset in (("Y", 0), ("U", cw * ch), ("V", cw * ch * 5 // 4)):
        wrong = bytearray(reference)
        wrong[offset] ^= 1
        controls[f"wrong_oracle_{name}_rejected"] = not compare_native(reference, wrong, cw, ch, count)["exact"]
    size = cw * ch * 3 // 2
    if count > 1:
        controls["frozen_first_frame_rejected"] = not compare_native(reference[:size] * count, reference, cw, ch, count)["exact"]
    else:
        controls["constant_zero_rejected"] = not compare_native(bytes(size), reference, cw, ch, count)["exact"]
    try:
        compare_native(b"", reference, cw, ch, count)
        controls["missing_actual_rejected"] = False
    except RuntimeError:
        controls["missing_actual_rejected"] = True
    try:
        verify_build(build, "not-current-input-key", manifest["inputs"])
        controls["stale_build_rejected"] = False
    except RuntimeError:
        controls["stale_build_rejected"] = True
    require(all(controls.values()), "independent scorer negative control failed")
    coverage = motion_coverage(build, prefix, out, reference) if manifest["require_color_motion"] else None
    inputs = {p.name: file_hash(p) for p in out.iterdir() if p.is_file()}
    for name in inputs:
        (out / name).chmod(0o444)
    command = [str(build / manifest["binary_path"]), str(out), str(out / "actual.i420"),
               str(out / "actual.frames.jsonl"), str(manifest["au_input_limit_bytes"])]
    verify_build(build, manifest["input_key"], manifest["inputs"])
    status = simulate(command, out / "simulation.log")
    verify_build(build, manifest["input_key"], manifest["inputs"])
    verify_files(out, inputs)
    actual = (out / "actual.i420").read_bytes() if (out / "actual.i420").exists() else b""
    events = [json.loads(line) for line in (out / "actual.frames.jsonl").read_text().splitlines()] if (
        out / "actual.frames.jsonl").exists() else []
    captured = len(actual) // size
    comparison = compare_native(actual, reference[:len(actual)], cw, ch, captured) if (
        captured and not len(actual) % size and captured <= count) else {
            "exact": False, "mismatches": None, "frames": []}
    errors = []
    cap_match = re.search(r"DDR_CAPS abi=(\d+) layout=(\d+) max_au_bytes=(\d+) features=(\d+)",
                          (out / "simulation.log").read_text())
    capabilities = dict(zip(("abi", "layout", "max_au_bytes", "features"), map(int, cap_match.groups()))) if cap_match else None
    if capabilities is None or capabilities["abi"] != 2 or capabilities["layout"] != 1 or capabilities["max_au_bytes"] < manifest["au_input_limit_bytes"]:
        errors.append("actual nonce-matched reader capabilities do not support the requested test input scope")
    if captured != count or len(actual) != count * size or len(events) != count:
        errors.append("actual coded pictures and identities are incomplete")
    rgb = out / "actual.frames.jsonl.rgb565"
    if not rgb.is_file() or rgb.stat().st_size != count * vw * vh * 2:
        errors.append("actual controller RGB word capture is incomplete")
    for i, (event, expected, header, frame) in enumerate(zip(events, metadata, headers, frames)):
        if any(event[k] != expected[k] for k in ("index", "pts", "duration", "timebase_num", "timebase_den", "flags")):
            errors.append(f"frame {i}: actual decoder AU metadata differs from original/declared input")
        if event["rtl_frame_num"] != header["frame_num"]:
            errors.append(f"frame {i}: actual RTL frame_num mismatch")
        event.update({name: expected[name] for name in
                      ("source_frame_index", "source_annexb_offset", "source_pts", "annexb_pts", "au_sha256")})
        event["encoded_header"] = header
        full_range = pixel_format == "yuvj420p" or frame.get("color_range") == "pc"
        matrix = frame.get("color_space", "unknown")
        if event["color_full_range"] != int(full_range) or matrix not in ("unknown", "bt709", "bt470bg", "smpte170m") or (
                (matrix == "bt709") != (event["color_matrix"] == 1) or event["color_matrix"] not in (1, 2, 5, 6)):
            errors.append(f"frame {i}: actual color metadata mismatch")
    if any(h["disable_deblocking_filter_idc"] != 1 for h in headers):
        errors.append("encoded filter-on/idc2 requires a completed actual filter scheduler")
    if any(h["nal_ref_idc"] == 0 for h in headers):
        errors.append("non-reference VCL requires retain-reference completion")
    if coverage and not coverage["qualified"]:
        errors.append("actual fractional/color/border fixture coverage is incomplete")
    if status:
        errors.append(f"real DDR/native producer exited {status}")
    result = {
        "schema": "misterplex.gop12.ddr-native-result.v1", "input_key": manifest["input_key"],
        "source_pin": manifest["source_pin"], "build_manifest_sha256": file_hash(build / "build.json"),
        "binary_sha256": manifest["outputs"][manifest["binary_path"]], "expected_frames": count,
        "fixture_sha256": file_hash(fixture), "tested_prefix_sha256": file_hash(prefix),
        "geometry": geometry, "oracle_pixel_format": pixel_format, "oracle_command": decode_command,
        "probe_commands": [packet_command, frame_command], "header_command": header_command,
        "simulation_command": command, "simulation_rc": status, "pts_scope": pts_scope,
        "source_plex_display_aspect_ratio": source_dar,
        "au_input_limit_bytes": manifest["au_input_limit_bytes"],
        "actual_reader_capabilities": capabilities,
        "max_tested_au_bytes": max(int(p["size"]) for p in packets),
        "negative_controls": controls, "runtime_input_hashes": inputs,
        "comparison": comparison, "identities": events, "independent_color_motion_coverage": coverage,
        "errors": errors, "pass": not errors and comparison["exact"],
        "limitations": [
            "Real DDR-ring reset/Probe/Begin/AUs/Drain and stream_path decoder; only compressed bytes/metadata enter RTL.",
            "Actual accepted native bytes map from observed MAX-allocation strides/plane offsets into packed coded I420.",
            "Controller-level accepted visible RGB words are captured; the legacy outer fs mux may gate them. This is not downstream frame-store/MVPS/glass proof.",
            "ENABLE_PICTURE_PUBLISH=0 is explicit; this lane independently verifies decoder output, not publication.",
            "Cycle intervals include DDR latency, host pacing and RGB sink retirement; not sustained throughput.",
            "Requested input capacity is checked against actual reader capabilities, not hardware qualification.",
        ],
    }
    result["artifacts"] = {p.name: file_hash(p) for p in out.iterdir() if p.is_file()}
    write_json(out / "result.json", result)
    write_json(out / "result.sha256.json", {"result.json": file_hash(out / "result.json")})
    for path in out.iterdir():
        path.chmod(0o444)
    out.chmod(0o555)
    print(f"{'PASS' if result['pass'] else 'FAIL'} real_DDR_native pictures={captured}/{count} mismatches={comparison['mismatches']}")
    print(f"RESULT {out / 'result.json'}")
    for error in errors:
        print(f"FAIL {error}")
    return 0 if result["pass"] else 1
