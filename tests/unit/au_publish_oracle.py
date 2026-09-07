"""Independent scoring of the source owner's real-AU producer, built from frozen inputs."""
import json
from fractions import Fraction
from pathlib import Path
import re
import subprocess
import time

from gop12_oracle import (
    ROOT, WIDTH, HEIGHT, PICTURE, checked, compare, digest, file_hash,
    motion_coverage, negative_controls, simulate, slice_headers, verify_build, verify_files, write_json,
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run_au(build, manifest, fixture):
    expected = manifest["expected_frames"]
    input_limit = manifest["au_input_limit_bytes"]
    runtime_geometry = manifest.get("au_runtime_geometry", False)
    require(manifest["au_publish"] and expected in (1, 2, 12),
            "real-AU producer configuration is not explicitly enabled")
    directory = build / "runs" / str(time.time_ns())
    directory.mkdir(parents=True)
    ffmpeg, ffprobe = manifest["tools"]["ffmpeg"]["path"], manifest["tools"]["ffprobe"]["path"]
    packet_command = [ffprobe, "-v", "error", "-select_streams", "v:0", "-show_packets",
                      "-show_streams", "-of", "json", str(fixture)]
    packets = json.loads(checked(packet_command))
    write_json(directory / "source-packets.json", packets)
    original = fixture.read_bytes()
    selected = packets["packets"][:expected]
    require(len(selected) == expected and "K" in selected[0]["flags"],
            f"{expected} complete AUs beginning with a keyframe required")
    end = 0
    for index, packet in enumerate(selected):
        offset, size = int(packet["pos"]), int(packet["size"])
        require(offset == end and 0 < size <= input_limit and offset + size <= len(original),
                f"actual AU continuity/{input_limit}-byte producer input bound rejected fixture")
        (directory / f"au{index}.264").write_bytes(original[offset:offset + size])
        end = offset + size
    prefix = directory / "tested-prefix.264"
    prefix.write_bytes(original[:end])
    (directory / "keyframes.bin").write_bytes(bytes(int("K" in p["flags"]) for p in selected))
    timing = [{"pts": -12345 + i * 1001, "duration": 1001, "num": 1, "den": 24000,
               "source_frame_index": i} for i in range(expected)]
    original_timing = manifest.get("pts_sidecar") is not None
    source_dar = None
    if original_timing:
        require(expected == 2, "current original-timing composed producer requires two AUs")
        sidecar = json.loads((build / "inputs" / manifest["pts_sidecar"]).read_text())
        source_dar = sidecar.get("source_plex_display_aspect_ratio")
        require(file_hash(fixture) in (sidecar.get("prefix_sha256"), sidecar.get("source_annexb_sha256")),
                "original PTS sidecar does not match frozen fixture")
        require(len(sidecar["frames"]) >= expected, "original PTS sidecar lacks two frames")
        timing = []
        for index, row in enumerate(sidecar["frames"][:expected]):
            require(row["index"] == index and row["au_sha256"] == file_hash(directory / f"au{index}.264"),
                    "original PTS AU identity mismatch")
            base = Fraction(row["time_base"])
            timing.append({"pts": row["original_pts"], "duration": row["original_duration"],
                           "num": base.numerator, "den": base.denominator,
                           "source_frame_index": row.get("source_frame_index", index)})
        with (directory / "original-timing.txt").open("w") as output:
            for value in timing:
                output.write(f"{value['pts']} {value['duration']} {value['num']} {value['den']}\n")
    frame_command = [ffprobe, "-v", "error", "-select_streams", "v:0", "-show_frames",
                     "-show_streams", "-of", "json", str(prefix)]
    probe = json.loads(checked(frame_command))
    write_json(directory / "ffprobe.json", probe)
    frames = probe["frames"]
    require(len(frames) == expected, "ordinary decoder did not return every selected AU")
    if not runtime_geometry:
        require(all((f["width"], f["height"]) == (WIDTH, HEIGHT) for f in frames),
                "legacy real-AU producer requires actual 320x240 frames; no geometry normalization")
    require(frames[0]["pict_type"] == "I" and all(f["pict_type"] in ("I", "P") for f in frames),
            "real-AU producer requires an IDR followed by an I/P picture")
    pixel_format = frames[0]["pix_fmt"]
    require(pixel_format in ("yuv420p", "yuvj420p") and all(f["pix_fmt"] == pixel_format for f in frames),
            "native planar 8-bit 4:2:0 required")
    headers, header_command = slice_headers(ffmpeg, prefix, directory / "headers.log", expected)
    geometry, coded_reference, coded_decoder_command = None, None, None
    picture_bytes = PICTURE
    if runtime_geometry:
        from au_geometry_oracle import (
            ALLOCATION_SUFFIX, delivered_geometry, geometry_negative_controls, native_beam_errors, native_dar_scope,
            score_geometry, verify_reference_crop, write_geometry,
        )
        require(expected == 2 and original_timing, "runtime geometry requires two original-timed AUs")
        geometry = delivered_geometry(directory / "headers.log", frames)
        picture_bytes = geometry["display_width"] * geometry["display_height"] * 3 // 2
        write_geometry(directory / "geometry.txt", geometry)
    reference_path = directory / "oracle.i420"
    decoder_command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-threads", "1",
                       "-i", str(prefix), "-map", "0:v:0", "-fps_mode", "passthrough",
                       "-pix_fmt", pixel_format, "-f", "rawvideo", str(reference_path)]
    subprocess.run(decoder_command, cwd=ROOT, check=True)
    reference = reference_path.read_bytes()
    require(len(reference) == expected * picture_bytes, "ordinary decoder did not return all complete native pictures")
    # The producer reads this only for post-DDR comparison; no native-data input
    # is connected in the mandatory FULL_AU/INTEGRATE_STREAM elaboration.
    (directory / "reference.yuv").write_bytes(reference)
    if runtime_geometry:
        coded_decoder_command = [
            ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-threads", "1",
            "-apply_cropping", "0", "-i", str(prefix), "-map", "0:v:0",
            "-fps_mode", "passthrough", "-pix_fmt", pixel_format, "-f", "rawvideo",
            str(directory / "reference-coded.yuv"),
        ]
        subprocess.run(coded_decoder_command, cwd=ROOT, check=True)
        coded_reference = (directory / "reference-coded.yuv").read_bytes()
        verify_reference_crop(coded_reference, reference, geometry, expected)
    required_idc = manifest.get("required_disable_deblocking_filter_idc")
    require(required_idc is None or all(h["disable_deblocking_filter_idc"] == required_idc for h in headers),
            "encoded filter flags differ from frozen fixture provenance")
    errors = []
    if any(h["disable_deblocking_filter_idc"] != 1 for h in headers):
        errors.append("encoded filter-on/idc2 requires a real full filter scheduler")
    if any(h["nal_ref_idc"] == 0 for h in headers):
        errors.append("non-reference VCL requires retain-reference completion")
    if manifest.get("au_idr_only") and any("K" not in packet["flags"] for packet in selected):
        errors.append("selected static-IDR profile cannot qualify a non-keyframe AU")
    if not runtime_geometry and any(f.get("sample_aspect_ratio") != "1:1" for f in frames):
        errors.append("current AU frontend requires encoded known square SAR; unspecified/nonsquare SAR is inadmissible")
    if pixel_format != "yuv420p" or any(f.get("color_range") == "pc" or
                                       f.get("color_space", "unknown") not in
                                       ("unknown", "bt470bg", "smpte170m") for f in frames):
        errors.append("reused publication producer fixes its renderer to limited BT601; other metadata cannot qualify")
    controls = (geometry_negative_controls(reference, coded_reference, geometry, expected, build, manifest)
                if runtime_geometry else negative_controls(reference, build, manifest))
    coverage = motion_coverage(build, prefix, directory, reference) if manifest["require_color_motion"] else None
    if coverage and not coverage["qualified"]:
        errors.append("encoded fixture failed required actual color/fractional/border coverage")
    runtime_inputs = {p.name: file_hash(p) for p in directory.iterdir() if p.is_file()}
    for name in runtime_inputs:
        (directory / name).chmod(0o444)
    actual = directory / "actual.i420"
    command = [str(build / manifest["binary_path"]), str(directory), str(actual)]
    verify_build(build, manifest["input_key"], manifest["inputs"])
    status = simulate(command, directory / "simulation.log")
    verify_build(build, manifest["input_key"], manifest["inputs"])
    verify_files(directory, runtime_inputs)
    log = (directory / "simulation.log").read_text()
    observed = []
    for match in re.finditer(
            r"FRAME_PASS seq=(\d+) native_bytes=(\d+) presentation_count=(\d+) pts=(-?\d+) "
            r"tb=(\d+)/(\d+)(?: sys_cycles=(\d+))?",
            log):
        seq, size, count, pts, numerator, denominator = map(int, match.groups()[:6])
        observed.append({"au_seq": seq, "captured_native_bytes": size, "presentation_count": count,
                         "observed_transport_pts": pts, "transport_timebase_num": numerator,
                         "transport_timebase_den": denominator,
                         "verified_publication_sys_cycle": int(match[7]) if match[7] is not None else None})
    with (directory / "actual.frames.jsonl").open("w") as output:
        for frame in observed:
            output.write(json.dumps(frame, sort_keys=True) + "\n")
    captured = actual.read_bytes() if actual.is_file() else b""
    count = len(captured) // picture_bytes
    geometry_score = None
    if runtime_geometry:
        allocation_path = Path(str(actual) + ALLOCATION_SUFFIX)
        allocation_bytes = allocation_path.read_bytes() if allocation_path.is_file() else b""
        geometry_score = score_geometry(captured, allocation_bytes, reference, coded_reference, geometry, expected)
        errors.extend(geometry_score["errors"])
        comparison = geometry_score["comparison"]
    elif len(captured) % picture_bytes or count > expected:
        errors.append("actual DDR picture output has partial/extra picture bytes")
        comparison = {"exact": False, "mismatches": None, "frames": []}
    elif count:
        comparison = compare(captured, reference[:len(captured)], count)
    else:
        comparison = {"exact": False, "mismatches": None, "frames": []}
    comparison["captured_ddr_pictures"] = count
    if count != expected or len(observed) != expected:
        errors.append(f"{expected} actual DDR pictures and verified presentation identities are required")
    identities = []
    for index, (event, packet, frame, header) in enumerate(zip(observed, selected, frames, headers)):
        if (event["au_seq"], event["captured_native_bytes"], event["presentation_count"],
            event["observed_transport_pts"], event["transport_timebase_num"], event["transport_timebase_den"]) != (
                index, picture_bytes, index + 1, timing[index]["pts"], timing[index]["num"], timing[index]["den"]):
            errors.append(f"AU {index}: actual publisher identity differs from the producer's declared test metadata")
        identities.append(dict(event, index=index, source_pts=timing[index]["pts"] if original_timing else None,
                               original_duration=timing[index]["duration"] if original_timing else None,
                               source_frame_index=timing[index]["source_frame_index"], annexb_pts=frame.get("pts"),
                               encoded_header=header, picture_type=frame["pict_type"],
                               original_annexb_offset=int(packet["pos"]), annexb_bytes=int(packet["size"]),
                               au_sha256=file_hash(directory / f"au{index}.264")))
        if runtime_geometry:
            original_row = sidecar["frames"][index]
            identities[-1]["fixture_annexb_offset"] = identities[-1].pop("original_annexb_offset")
            identities[-1]["source_annexb_offset"] = original_row.get(
                "source_annexb_offset", original_row.get("annexb_offset"))
            identities[-1]["original_time_base"] = original_row["time_base"]
            identities[-1]["original_dts"] = original_row.get("original_dts")
            identities[-1]["source_nal_offset"] = original_row.get("vcl", {}).get("source_nal_offset")
    if status:
        errors.append(f"real AU decoder/publication producer exited {status}; see simulation.log")
    aspect_scope = native_dar_scope(geometry, source_dar, log) if runtime_geometry else None
    if manifest.get("au_native_beam"):
        errors.extend(native_beam_errors(aspect_scope, geometry, expected, manifest["au_native_scandouble"]))
    result = {
        "schema": "misterplex.gop12.au-publish-result.v1", "input_key": manifest["input_key"],
        "source_pin": manifest["source_pin"], "build_manifest_sha256": file_hash(build / "build.json"),
        "binary_sha256": manifest["outputs"][manifest["binary_path"]], "expected_frames": expected,
        "original_fixture_sha256": file_hash(fixture), "tested_prefix_sha256": file_hash(prefix),
        "au_input_limit_bytes": input_limit,
        "static_idr_profile": manifest.get("au_idr_only", False),
        "source_cohort_sha256": manifest.get("source_cohort_sha256"),
        "max_tested_au_bytes": max(int(packet["size"]) for packet in selected),
        "oracle_pixel_format": pixel_format, "oracle_command": decoder_command,
        "original_timing_preserved": original_timing,
        "probe_commands": [packet_command, frame_command], "header_command": header_command,
        "simulation_command": command, "simulation_rc": status, "negative_controls": controls,
        "runtime_input_hashes": runtime_inputs, "comparison": comparison, "identities": identities,
        "independent_color_motion_coverage": coverage,
        "errors": errors, "pass": not errors and comparison["exact"],
        "limitations": [
            "Actual DDR-AU decoder and native publisher/frame-store model, not hardware/glass.",
            "FULL_AU=1, FULL_AU_RTL=1 and INTEGRATE_STREAM=1 are mandatory frozen build inputs; controlled native injection is disconnected.",
            f"Only first {expected} complete AUs tested; no longer-stream or sustained-throughput qualification.",
            ("Original PTS/duration/timebase are AU-hash matched and strictly required at producer input; MVPS checks PTS/timebase, not duration."
             if original_timing else
             "Producer deliberately uses synthetic signed transport PTS -12345+i*1001 at 1/24000; not original source/PMS PTS or cadence."),
            "Actual DDR pictures and source-producer-validated MVPS are observed; individual DPB write coverage and RTL frame_num are not directly logged by this producer.",
            "Renderer check is limited BT601 and selected pixel(s), not complete RGB numerical conformance.",
            "Publication sys cycles, when available, include decoder, publisher and BFM waits; not isolated decoder throughput.",
            "The harness input limit is not proof of implemented RTL capacity; only the actual tested AU sizes are exercised.",
        ],
    }
    if runtime_geometry:
        result.update({
            "schema": "misterplex.gop12.au-publish-geometry-result.v1",
            "geometry": geometry, "coded_oracle_command": coded_decoder_command,
            "geometry_origin": "Delivered tested-prefix SPS trace, cross-checked against ordinary visible decode; "
                               "geometry.txt contains expected observation values, not a decoder geometry input.",
            "geometry_output_score": geometry_score,
            "native_dar": aspect_scope,
            "pass_scope": "Actual coded and visible YUV, fixed-allocation padding, and publication identities only; "
                          "not native-DAR/scaler/AutoFit, rate, audio, or hardware qualification.",
        })
        result["limitations"].append(result["native_dar"]["limitation"])
        if manifest.get("au_native_beam"):
            result["native_presenter"] = {
                "enabled": True, "scandouble": manifest["au_native_scandouble"],
                "scope": "Frozen source-producer CE/DE/RGB raster assertions; raw RGB is not independently rescored.",
            }
            result["limitations"].append(
                "The source-owned presenter model has fixed timing inputs, including content_fps=24; "
                "original AU PTS are unchanged, but this is not original 24000/1001 display-cadence proof.")
    result["artifacts"] = {p.name: file_hash(p) for p in directory.iterdir() if p.is_file()}
    write_json(directory / "result.json", result)
    write_json(directory / "result.sha256.json", {"result.json": file_hash(directory / "result.json")})
    for path in directory.iterdir():
        path.chmod(0o444)
    directory.chmod(0o555)
    scope = "real_AU_pixels_and_publication native_DAR=UNQUALIFIED" if runtime_geometry else "real_AU_decode_and_publication"
    print(f"{'PASS' if result['pass'] else 'FAIL'} {scope} "
          f"pictures={count}/{expected} mismatches={comparison['mismatches']}")
    print(f"RESULT {directory / 'result.json'}")
    for error in errors:
        print(f"FAIL {error}")
    return 0 if result["pass"] else 1
