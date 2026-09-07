#!/usr/bin/env python3
"""Verify bounded real-PMS bytes/default decoding; no missing RTL output can pass."""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
from gop12_oracle import canonical, digest, file_hash, slice_headers, write_json

ROOT = Path(__file__).resolve().parents[2]
FRONTEND_RBSP_BYTES = 65536
LEGACY_FRONTEND_RBSP_BYTES = 8192
TRANSPORT_AU_BYTES = 262048


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def probe(ffprobe, path, frames=False):
    command = [ffprobe, "-v", "error", "-select_streams", "v:0", "-show_streams",
               "-show_frames" if frames else "-show_packets"]
    if not frames:
        command += ["-show_data_hash", "sha256"]
    command += ["-of", "json", str(path)]
    return json.loads(subprocess.check_output(command, cwd=ROOT)), command


def freeze_case(case, root, target):
    source = Path(case["path"]).resolve()
    require(source.is_relative_to(root), "capture case escapes declared campaign")
    hashes = {}
    for name, expected in case["files"].items():
        require(Path(name).name == name, "capture input must be a named file")
        content = (source / name).read_bytes()
        require(len(content) == expected["bytes"] and digest(content) == expected["sha256"],
                f"capture hash/size mismatch: {case['name']}/{name}")
        if name.endswith(".json"):
            require(not re.search(rb'(?i)(?:X-Plex-Token|plex_token)["\s]*[:=]\s*["]?[a-z0-9_-]{8,}', content),
                    "possible live token in capture metadata; refusing to copy")
        dest = target / name
        if dest.exists():
            require(file_hash(dest) == expected["sha256"], f"frozen input changed: {dest}")
        else:
            dest.write_bytes(content)
            dest.chmod(0o444)
        hashes[name] = expected["sha256"]
    return hashes


def capture_cases(handoff, path):
    if "cases" in handoff:
        return handoff["cases"], Path(handoff["root"]).resolve()
    if "captures" in handoff:
        root = path.resolve().parent
        cases = []
        for entry in handoff["captures"]:
            directory = Path(entry["directory"]).resolve()
            require(directory.is_relative_to(root), "capture directory escapes handoff root")
            normalized, _ = capture_cases({"origin": "real-PMS", "frames": entry["frames"],
                                           "sha256": entry["sha256"]}, directory / "oracle-handoff.json")
            case = normalized[0]
            case["original_capture_gate"] = {
                "reported_exit": entry["exitcode"], "source_label": handoff["source_label"],
                "source_fixture_sha256": handoff["source_fixture_sha256"],
                "subtitle_requested": entry["subtitle_requested"],
                "subtitle_visual": handoff.get("subtitle_visual") if entry["subtitle_requested"] else None,
            }
            cases.append(case)
        return cases, root
    require(handoff.get("origin") == "real-PMS" and isinstance(handoff.get("sha256"), dict)
            and handoff["sha256"], "unsupported capture handoff schema")
    root = path.resolve().parent
    declared = handoff["sha256"]
    required = {"delivered.264", "delivered.ts", "delivered-network.ts", "measurement.json",
                "source.json", "packets.json", "network-packets.json", "default-decoder.framemd5"}
    files = {}
    for name in sorted(required | declared.keys()):
        require(Path(name).name == name, "capture input must be a named file")
        content = (root / name).read_bytes()
        sha = digest(content)
        if name in declared:
            require(sha == declared[name], f"operator-declared capture hash mismatch: {name}")
        files[name] = {"sha256": sha, "bytes": len(content)}
    return [{"name": root.name, "path": str(root), "frames": handoff["frames"], "files": files,
             "operator_declared_hash_files": sorted(declared),
             "additional_artifacts_observed_at_freeze": sorted(required - declared.keys()),
             "original_capture_gate": {name: handoff[name] for name in
                                       ("full_size_gate_exit", "reason", "supplementary_bounded_geometry_gate_exit",
                                        "geometry_rejection_preserved", "new_core_acceptance") if name in handoff}}], root


def geometry_from_trace(path):
    names = ("pic_width_in_mbs_minus1", "pic_height_in_map_units_minus1",
             "frame_mbs_only_flag", "frame_cropping_flag",
             "frame_crop_left_offset", "frame_crop_right_offset",
             "frame_crop_top_offset", "frame_crop_bottom_offset",
             "aspect_ratio_info_present_flag", "aspect_ratio_idc", "sar_width", "sar_height")
    values = {name: set() for name in names}
    for line in path.read_text().splitlines():
        match = re.search(r"\]\s+\d+\s+(" + "|".join(names) + r")\s+\S+\s+=\s+(\d+)", line)
        if match:
            values[match[1]].add(int(match[2]))
    require(all(len(v) <= 1 for v in values.values()), "mid-stream geometry/aspect change")
    get = lambda name, default=None: next(iter(values[name]), default)
    require(get("frame_mbs_only_flag") == 1, "capture is not progressive frame-coded")
    require(get(names[0]) is not None and get(names[1]) is not None, "SPS coded geometry absent")
    width, height = 16 * (get(names[0]) + 1), 16 * (get(names[1]) + 1)
    crop = [2 * get(name, 0) for name in names[4:8]]
    aspect_present = bool(get("aspect_ratio_info_present_flag", 0))
    aspect_idc = get("aspect_ratio_idc") if aspect_present else None
    sar_table = ((0, 0), (1, 1), (12, 11), (10, 11), (16, 11), (40, 33),
                 (24, 11), (20, 11), (32, 11), (80, 33), (18, 11), (15, 11),
                 (64, 33), (160, 99), (4, 3), (3, 2), (2, 1))
    sar = (0, 0)
    if aspect_present:
        if aspect_idc == 255:
            sar = (get("sar_width", 0), get("sar_height", 0))
        else:
            require(aspect_idc is not None and 0 <= aspect_idc < len(sar_table),
                    "reserved or missing encoded aspect ratio")
            sar = sar_table[aspect_idc]
    visible_width, visible_height = width - crop[0] - crop[1], height - crop[2] - crop[3]
    known = sar[0] > 0 and sar[1] > 0
    return {"coded_width": width, "coded_height": height, "crop_left_right_top_bottom": crop,
            "display_width": visible_width, "display_height": visible_height,
            "aspect_ratio_info_present_flag": aspect_present, "aspect_ratio_idc": aspect_idc,
            "sar_known": known, "sar_num": sar[0], "sar_den": sar[1],
            "bitstream_display_aspect_ratio": str(Fraction(visible_width * sar[0], visible_height * sar[1]))
            if known else None}


def packed_i420_layout(width, height):
    require(width > 0 and height > 0 and width % 2 == height % 2 == 0, "invalid I420 geometry")
    return {"width": width, "height": height,
            "strides": [width, width // 2, width // 2],
            "plane_offsets": [0, width * height, width * height * 5 // 4],
            "plane_rows": [height, height // 2, height // 2],
            "frame_bytes": width * height * 3 // 2}


def extract_i420_region(data, layout, width, height, left=0, top=0):
    require(len(data) == layout["frame_bytes"] and width > 0 and height > 0 and min(left, top) >= 0 and
            all(v % 2 == 0 for v in (width, height, left, top)), "invalid I420 source region")
    rows = []
    for plane, scale in enumerate((1, 2, 2)):
        stride, base = layout["strides"][plane], layout["plane_offsets"][plane]
        plane_end = layout["plane_offsets"][plane + 1] if plane < 2 else layout["frame_bytes"]
        row_width, row_count = width // scale, height // scale
        require((left + width) // scale <= stride and
                (top + height) // scale <= layout["plane_rows"][plane],
                "I420 region exceeds implemented plane stride/rows")
        for row in range(row_count):
            start = base + (top // scale + row) * stride + left // scale
            require(start + row_width <= plane_end, "I420 region crosses source plane boundary")
            rows.append(data[start:start + row_width])
    return b"".join(rows)


def vcl_sizes(data):
    starts = list(re.finditer(b"\x00\x00(?:\x00)?\x01", data))
    sizes = []
    for index, start in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(data)
        if start.end() >= end or (data[start.end()] & 31) not in (1, 5):
            continue
        payload = data[start.end() + 1:end]
        rbsp = payload.replace(b"\x00\x00\x03", b"\x00\x00")
        sizes.append({"nal_offset": start.start(), "nal_bytes": end - start.start(),
                      "nal_ref_idc": (data[start.end()] >> 5) & 3,
                      "nal_type": data[start.end()] & 31,
                      "ebsp_bytes": len(payload), "rbsp_bytes": len(rbsp)})
    return sizes


def capacity_summary(identities, rbsp_limit=FRONTEND_RBSP_BYTES):
    largest_au = max(frame["annexb_bytes"] for frame in identities)
    largest_rbsp = max(frame["vcl"]["rbsp_bytes"] for frame in identities)
    oversized = [
        {"index": frame["index"], "original_pts": frame["original_pts"],
         "au_bytes": frame["annexb_bytes"], "vcl_rbsp_bytes": frame["vcl"]["rbsp_bytes"],
         "nal_offset": frame["vcl"]["nal_offset"]}
        for frame in identities if frame["vcl"]["rbsp_bytes"] > rbsp_limit
    ]
    return {"transport_payload_limit_bytes": TRANSPORT_AU_BYTES,
            "vcl_rbsp_limit_bytes": rbsp_limit, "staged_au_limit_bytes": rbsp_limit,
            "max_au_bytes": largest_au, "max_vcl_rbsp_bytes": largest_rbsp,
            "transport_headroom_bytes": TRANSPORT_AU_BYTES - largest_au,
            "staged_au_headroom_bytes": rbsp_limit - largest_au,
            "vcl_rbsp_headroom_bytes": rbsp_limit - largest_rbsp,
            "oversized_vcl_count": len(oversized), "oversized_vcls": oversized,
            "oversized_staged_au_indices": [frame["index"] for frame in identities
                                           if frame["annexb_bytes"] > rbsp_limit],
            "byte_caps_satisfied": largest_au <= min(TRANSPORT_AU_BYTES, rbsp_limit) and not oversized,
            "rtl_implementation_verified": False,
            "scope": "Byte-size assessment only; assigned modern capacity does not prove implemented RTL or decoder acceptance."}


def cadence_summary(pts, frame_rate, time_base):
    period = Fraction(1) / Fraction(frame_rate) / Fraction(time_base)
    require(period > 0 and pts, "invalid declared cadence or missing PTS")
    low = period.numerator // period.denominator
    high = -(-period.numerator // period.denominator)
    deltas = [b - a for a, b in zip(pts, pts[1:])]
    require(all(delta > 0 and delta in (low, high) for delta in deltas),
            "original PTS deltas differ from rational declared cadence")
    errors = [Fraction(value - pts[0]) - index * period for index, value in enumerate(pts)]
    require(max(errors) - min(errors) < 1, "original PTS accumulate more than one tick of cadence error")
    return {"frame_period_ticks": str(period), "actual_delta_ticks": sorted(set(deltas)),
            "cumulative_phase_error_min_ticks": str(min(errors)),
            "cumulative_phase_error_max_ticks": str(max(errors)),
            "scope": "Exact original integer PTS with less than one tick of cumulative quantization span; no rescaling or rewriting."}


def run_case(case, campaign, build, tools, prefix_count, prefix_start=0):
    directory = build / case["name"]
    directory.mkdir(parents=True, exist_ok=True)
    inputs = directory / "inputs"
    inputs.mkdir(exist_ok=True)
    hashes = freeze_case(case, campaign, inputs)
    inputs.chmod(0o555)
    out = directory / "runs" / str(time.time_ns())
    out.mkdir(parents=True)
    measurement = json.loads((inputs / "measurement.json").read_text())
    source_dar = json.loads((inputs / "source.json").read_text()).get("media", {}).get("aspectRatio")
    expected_count = case["frames"]
    require(measurement["origin"] == "real-PMS", "handoff does not identify real PMS capture")
    annexb = inputs / "delivered.264"
    data = annexb.read_bytes()
    elementary, annex_probe_command = probe(tools["ffprobe"]["path"], annexb)
    decoded, frame_probe_command = probe(tools["ffprobe"]["path"], annexb, frames=True)
    transport, ts_probe_command = probe(tools["ffprobe"]["path"], inputs / "delivered.ts")
    network, network_probe_command = probe(tools["ffprobe"]["path"], inputs / "delivered-network.ts")
    packets, frames = elementary["packets"], decoded["frames"]
    ts_packets, network_packets = transport["packets"], network["packets"]
    require(len(packets) == len(frames) == len(ts_packets) == expected_count,
            "bounded Annex-B/TS/default frame counts differ")
    require(len(network_packets) >= expected_count, "network capture lacks bounded prefix")
    recorded_ts = json.loads((inputs / "packets.json").read_text())["packets"]
    recorded_network = json.loads((inputs / "network-packets.json").read_text())["packets"]
    require(len(recorded_ts) == expected_count and len(recorded_network) >= expected_count,
            "recorded packet identities lack bounded pictures")
    time_base = measurement["time_base"]
    require(transport["streams"][0]["time_base"] == network["streams"][0]["time_base"] == time_base,
            "original/remux time bases differ")
    native_format = frames[0]["pix_fmt"]
    require(native_format in ("yuv420p", "yuvj420p"), "expected native planar 8-bit 4:2:0")
    width, height = frames[0]["width"], frames[0]["height"]
    require(width % 2 == height % 2 == 0 and all(
        (f["width"], f["height"], f["pix_fmt"]) == (width, height, native_format) for f in frames),
        "changing or non-even native output geometry")
    headers, header_command = slice_headers(tools["ffmpeg"]["path"], annexb, out / "headers.log", expected_count)
    geometry = geometry_from_trace(out / "headers.log")
    require((geometry["display_width"], geometry["display_height"]) == (width, height),
            "SPS crop and ordinary decoder output disagree")
    desired_idc = 1 if measurement["filter"] == "off" else 0
    require(all(h["disable_deblocking_filter_idc"] == desired_idc for h in headers),
            "actual encoded filter flags differ from declared capture")
    oracle = out / "oracle.i420"
    decode_command = [tools["ffmpeg"]["path"], "-hide_banner", "-loglevel", "error", "-nostdin",
                      "-threads", "1", "-i", str(annexb), "-map", "0:v:0",
                      "-fps_mode", "passthrough", "-pix_fmt", native_format,
                      "-f", "rawvideo", str(oracle)]
    subprocess.run(decode_command, cwd=ROOT, check=True)
    actual_reference = oracle.read_bytes()
    frame_bytes = width * height * 3 // 2
    require(len(actual_reference) == expected_count * frame_bytes, "ordinary decoder byte count mismatch")
    visible_layout = packed_i420_layout(width, height)
    coded_layout = packed_i420_layout(geometry["coded_width"], geometry["coded_height"])
    coded_oracle = out / "oracle-coded.i420"
    coded_decode_command = [
        tools["ffmpeg"]["path"], "-hide_banner", "-loglevel", "error", "-nostdin",
        "-threads", "1", "-apply_cropping", "0", "-i", str(annexb), "-map", "0:v:0",
        "-fps_mode", "passthrough", "-pix_fmt", native_format, "-f", "rawvideo", str(coded_oracle)]
    subprocess.run(coded_decode_command, cwd=ROOT, check=True)
    coded_reference = coded_oracle.read_bytes()
    require(len(coded_reference) == expected_count * coded_layout["frame_bytes"],
            "uncropped ordinary decoder coded-plane byte count mismatch")
    md5_rows = [line.split(",") for line in (inputs / "default-decoder.framemd5").read_text().splitlines()
                if line.strip() and not line.startswith("#")]
    require(len(md5_rows) == expected_count, "missing supplied ordinary frame hashes")
    vcls = vcl_sizes(data)
    require(len(vcls) == expected_count, "capture is not one VCL NAL per access unit")
    identities = []
    offset = 0
    rebases = set()
    original_pts = []
    prefix_layout_rejections = 0
    for index, (packet, ts_packet, network_packet, frame, header, row) in enumerate(zip(
            packets, ts_packets, network_packets, frames, headers, md5_rows)):
        size = int(packet["size"])
        require(int(packet["pos"]) == offset, "Annex-B packet offsets are not contiguous")
        au = data[offset:offset + size]
        au_hash = digest(au)
        require(packet["data_hash"] == ts_packet["data_hash"] == network_packet["data_hash"] == "SHA256:" + au_hash,
                f"AU {index}: elementary/remux/original payload identity mismatch")
        for recorded, fresh in ((recorded_ts[index], ts_packet), (recorded_network[index], network_packet)):
            require(all(int(recorded[k]) == int(fresh[k]) for k in ("pts", "dts", "duration", "size")),
                    f"AU {index}: recorded packet metadata mismatch")
        pixels = actual_reference[index * frame_bytes:(index + 1) * frame_bytes]
        coded_pixels = coded_reference[index * coded_layout["frame_bytes"]:(index + 1) * coded_layout["frame_bytes"]]
        mapped_pixels = extract_i420_region(coded_pixels, coded_layout, width, height,
                                           geometry["crop_left_right_top_bottom"][0],
                                           geometry["crop_left_right_top_bottom"][2])
        require(mapped_pixels == pixels, f"frame {index}: per-plane crop differs from default ordinary decoding")
        prefix_layout_rejections += coded_pixels[:frame_bytes] != pixels
        md5 = hashlib.md5(pixels).hexdigest()
        require(len(row) == 6 and int(row[4]) == frame_bytes and row[5].strip() == md5,
                f"frame {index}: supplied default-decoder hash differs from fresh ordinary YUV")
        original_pts.append(int(network_packet["pts"]))
        rebases.add(int(ts_packet["pts"]) - int(network_packet["pts"]))
        identities.append({"index": index, "annexb_offset": offset, "annexb_bytes": size,
                           "au_sha256": au_hash, "vcl": vcls[index],
                           "frame_num": header["frame_num"], "nal_ref_idc": header["nal_ref_idc"],
                           "disable_deblocking_filter_idc": header["disable_deblocking_filter_idc"],
                           "picture_type": frame["pict_type"], "original_pts": int(network_packet["pts"]),
                           "original_dts": int(network_packet["dts"]), "original_duration": int(network_packet["duration"]),
                           "remux_pts": int(ts_packet["pts"]), "time_base": time_base,
                           "annexb_pts": packet.get("pts"), "ordinary_frame_md5": md5,
                           "ordinary_frame_bytes": frame_bytes,
                           "ordinary_coded_frame_sha256": digest(coded_pixels),
                           "ordinary_coded_frame_bytes": coded_layout["frame_bytes"]})
        offset += size
    require(offset == len(data) and len(rebases) == 1, "incomplete bytes or variable PTS rebase")
    deltas = sorted(set(b - a for a, b in zip(original_pts, original_pts[1:])))
    require(deltas == measurement["network_pts_delta_ticks"], "original network PTS cadence mismatch")
    require(rebases == {measurement["remux_pts_rebase_ticks"]}, "PTS rebase differs from capture report")
    cadence = cadence_summary(original_pts, measurement["declared_fps"], time_base)
    require(0 <= prefix_start < expected_count, "requested source frame is outside capture")
    prefix_count = min(prefix_count, expected_count - prefix_start)
    selected = identities[prefix_start:prefix_start + prefix_count]
    require(selected[0]["vcl"]["nal_type"] == 5, "standalone AU window must start at an actual IDR")
    prefix_begin = selected[0]["annexb_offset"]
    prefix_end = selected[-1]["annexb_offset"] + selected[-1]["annexb_bytes"]
    prefix = out / "first-complete-aus.264"
    prefix.write_bytes(data[prefix_begin:prefix_end])
    selected = [dict(frame, index=index, source_frame_index=frame["index"],
                     source_annexb_offset=frame["annexb_offset"],
                     vcl=dict(frame["vcl"], source_nal_offset=frame["vcl"]["nal_offset"],
                              nal_offset=frame["vcl"]["nal_offset"] - prefix_begin),
                     annexb_offset=frame["annexb_offset"] - prefix_begin)
                for index, frame in enumerate(selected)]
    write_json(out / "original-pts.json", {"source_annexb_sha256": hashes["delivered.264"],
                                          "prefix_sha256": file_hash(prefix),
                                          "prefix_start_frame": prefix_start,
                                          "source_plex_display_aspect_ratio": source_dar,
                                          "frames": selected})
    (out / "README.md").write_text(
        "# Preserved real-PMS access-unit window\n\n"
        f"Exact source frames {prefix_start}..{prefix_start + prefix_count - 1} from "
        f"{case['name']}; source Annex-B SHA256 `{hashes['delivered.264']}`.\n\n"
        "Bytes are a contiguous complete-AU window beginning at a real IDR. No "
        "re-encode, resizing, header/filter changes, reference insertion or PTS "
        "invention. `original-pts.json` preserves source frame indices, AU hashes, "
        "original timestamps and timebases separately from fresh transport sequence.\n\n"
        "Private capture bytes remain in ignored build storage. Full source and "
        "metadata identities are in the enclosing immutable capture manifest. "
        "Ordinary-reference verification is not FPGA, playback or glass acceptance.\n")
    write_json(out / "frames.json", identities)
    write_json(out / "ffprobe-frames.json", decoded)
    capacity = capacity_summary(identities)
    legacy_capacity = capacity_summary(identities, LEGACY_FRONTEND_RBSP_BYTES)
    maximum_rbsp = capacity["max_vcl_rbsp_bytes"]
    blockers = ["no actual source-bound RTL output for this captured stream; ordinary-reference verification is not decoder acceptance"]
    if (geometry["coded_width"], geometry["coded_height"], width, height) != (320, 240, 320, 240):
        blockers.append("fixed 320x240 model cannot verify this coded/display geometry; actual modern controller/DPB/publication propagation is required")
    if not geometry["sar_known"]:
        blockers.append("encoded SAR is unknown, not square; preserve independent Plex metadata DAR")
    if maximum_rbsp > FRONTEND_RBSP_BYTES:
        blockers.append("actual VCL RBSP exceeds assigned modern 65536-byte capacity")
    if capacity["max_au_bytes"] > FRONTEND_RBSP_BYTES:
        blockers.append("actual access unit exceeds assigned modern 65536-byte staging capacity")
    if capacity["max_au_bytes"] > TRANSPORT_AU_BYTES:
        blockers.append("actual access unit exceeds current ARM transport payload ceiling 262048")
    if desired_idc != 1:
        blockers.append("encoded filter-on requires the missing full filter scheduler")
    if any(h["nal_ref_idc"] == 0 for h in headers):
        blockers.append("non-reference VCL requires retain-reference completion")
    result = {"schema": "misterplex.pms.ordinary-oracle.v1", "case": case["name"],
              "reference_verification_passed": True, "pass": False, "rtl_outputs_present": False,
              "source_binding_sha256": file_hash(build / "inputs.json"),
              "handoff_sha256": file_hash(build / "handoff.json"), "prefix_frames": prefix_count,
              "prefix_start_frame": prefix_start,
              "input_hashes": hashes, "tools": tools, "geometry": geometry, "native_format": native_format,
              "operator_declared_hash_files": case.get("operator_declared_hash_files", sorted(hashes)),
              "additional_artifacts_observed_at_freeze": case.get("additional_artifacts_observed_at_freeze", []),
              "original_capture_gate": case.get("original_capture_gate"),
              "plex_metadata_display_aspect_ratio": source_dar,
              "plex_aspect_provenance": "Unmodified source.json /media/aspectRatio; not inferred from pixel dimensions.",
              "ordinary_visible_layout": visible_layout, "ordinary_coded_layout": coded_layout,
              "plane_mapping_verification": {
                  "frames": expected_count, "all_coded_to_visible_rows_exact": True,
                  "naive_packed_prefix_rejected_frames": prefix_layout_rejections,
                  "fpga_output_compared": False,
                  "scope": "Packed ordinary layouts only. FPGA capture must supply its implemented plane bases/strides; never take a packed byte prefix."},
              "frames": expected_count, "max_au_bytes": max(int(p["size"]) for p in packets),
              "max_vcl_rbsp_bytes": maximum_rbsp, "front_end_rbsp_limit": FRONTEND_RBSP_BYTES,
              "arm_transport_payload_limit": TRANSPORT_AU_BYTES, "current_byte_capacity": capacity,
              "capacity_assessment_role": "Assigned whole-modern-path 64KiB target, not a claim that current RTL is widened.",
              "legacy_8k_byte_capacity": legacy_capacity,
              "reported_capture_au_limit": measurement["au_limit_bytes"],
              "network_packets_ignored_after_bounded_prefix": len(network_packets) - expected_count,
              "original_first_pts": original_pts[0], "original_last_pts": original_pts[-1],
              "original_pts_step": deltas, "time_base": time_base, "remux_pts_rebase": next(iter(rebases)),
              "rational_cadence": cadence,
              "decode_command": decode_command, "coded_decode_command": coded_decode_command,
              "header_command": header_command,
              "probe_commands": [annex_probe_command, frame_probe_command, ts_probe_command, network_probe_command],
              "blockers": blockers, "artifacts": {p.name: file_hash(p) for p in out.iterdir() if p.is_file()}}
    write_json(out / "result.json", result)
    write_json(out / "result.sha256.json", {"result.json": file_hash(out / "result.json")})
    for path in out.iterdir():
        path.chmod(0o444)
    out.chmod(0o555)
    print(f"REFERENCE_VERIFIED {case['name']} frames={expected_count} coded="
          f"{geometry['coded_width']}x{geometry['coded_height']} display={width}x{height} "
          f"max_rbsp={maximum_rbsp} RTL_GATE=FAIL")
    print(f"RESULT {out / 'result.json'}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--handoff", required=True, type=Path)
    parser.add_argument("--case", help="exact case name; default verifies every declared case")
    parser.add_argument("--prefix-frames", type=int, default=12)
    parser.add_argument("--start-frame", type=int, default=0,
                        help="source index of an actual IDR starting the exact AU window; no bytes or original PTS changed")
    args = parser.parse_args()
    try:
        require(1 <= args.prefix_frames <= 256 and args.start_frame >= 0,
                "AU window requires 1..256 frames and a nonnegative source start")
        raw = args.handoff.read_bytes()
        handoff = json.loads(raw)
        declared_cases, campaign = capture_cases(handoff, args.handoff)
        cases = [c for c in declared_cases if args.case is None or c["name"] == args.case]
        require(cases, "requested capture case absent")
        tools = {}
        for name in ("ffmpeg", "ffprobe"):
            path = Path(shutil.which(name) or name).resolve()
            tools[name] = {"path": str(path), "sha256": file_hash(path),
                           "version": subprocess.check_output([str(path), "-version"], text=True).splitlines()[0]}
        sources = {p: (ROOT / p).read_bytes() for p in
                   ("tests/unit/check_pms_capture_oracle.py", "tests/unit/gop12_oracle.py")}
        binding = {"handoff_sha256": digest(raw), "tools": tools,
                   "prefix_frames": args.prefix_frames,
                   "prefix_start_frame": args.start_frame,
                   "sources": {p: digest(content) for p, content in sources.items()},
                   "frozen_input_manifest_sha256_as_supplied": handoff.get(
                       "frozen_input_manifest_sha256", handoff.get("frozen_manifest_sha256")),
                   "observed_case_files": {case["name"]: case["files"] for case in cases}}
        build = ROOT / "build/pms-capture-oracle" / digest(canonical(binding))
        build.mkdir(parents=True, exist_ok=True)
        for name, content in (("inputs.json", canonical(binding)), ("handoff.json", raw)):
            path = build / name
            if path.exists():
                require(path.read_bytes() == content, "frozen capture binding changed")
            else:
                path.write_bytes(content)
                path.chmod(0o444)
        for name, content in sources.items():
            path = build / "sources" / name
            if path.exists():
                require(path.read_bytes() == content, "frozen verifier source changed")
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
                path.chmod(0o444)
        for case in cases:
            require(Path(case["name"]).name == case["name"] and case["name"] not in ("", ".", ".."),
                    "unsafe case name")
            run_case(case, campaign, build, tools, args.prefix_frames, args.start_frame)
        # No actual RTL frames were supplied or executed by this ordinary-reference extension.
        return 1
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"FAIL real-PMS oracle: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
