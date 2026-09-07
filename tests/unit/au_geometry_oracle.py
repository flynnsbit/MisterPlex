"""Geometry-aware scoring of actual fixed-stride DDR snapshots, never DUT inputs."""
from fractions import Fraction
import re

from check_pms_capture_oracle import extract_i420_region, geometry_from_trace, packed_i420_layout
from ddr_native_oracle import compare_native
from gop12_oracle import verify_build

ALLOCATION = packed_i420_layout(320, 240)
ALLOCATION_SUFFIX = ".allocation"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def delivered_geometry(trace, frames):
    geometry = geometry_from_trace(trace)
    validate_geometry(geometry)
    visible = (geometry["display_width"], geometry["display_height"])
    require(all((frame["width"], frame["height"]) == visible for frame in frames),
            "ordinary visible dimensions differ from delivered SPS crop")
    return geometry


def validate_geometry(geometry):
    cw, ch = geometry["coded_width"], geometry["coded_height"]
    left, right, top, bottom = geometry["crop_left_right_top_bottom"]
    require(0 < cw <= 320 and 0 < ch <= 240 and cw % 16 == ch % 16 == 0,
            "delivered coded rectangle exceeds the fixed allocation")
    require(all(value >= 0 and value % 2 == 0 for value in (left, right, top, bottom)) and
            left + right < cw and top + bottom < ch,
            "invalid delivered progressive 4:2:0 crop")
    require((geometry["display_width"], geometry["display_height"]) ==
            (cw - left - right, ch - top - bottom), "inconsistent visible geometry")
    require((geometry["sar_known"] and geometry["sar_num"] > 0 and geometry["sar_den"] > 0) or
            (not geometry["sar_known"] and geometry["sar_num"] == geometry["sar_den"] == 0),
            "inconsistent delivered SAR; unknown must remain 0/0")


def write_geometry(path, geometry):
    validate_geometry(geometry)
    values = [geometry["coded_width"], geometry["coded_height"],
              *geometry["crop_left_right_top_bottom"]]
    path.write_text(" ".join(map(str, values)) + "\n")


def verify_reference_crop(coded, visible, geometry, frames):
    cw, ch = geometry["coded_width"], geometry["coded_height"]
    vw, vh = geometry["display_width"], geometry["display_height"]
    left, _, top, _ = geometry["crop_left_right_top_bottom"]
    layout = packed_i420_layout(cw, ch)
    coded_size, visible_size = layout["frame_bytes"], vw * vh * 3 // 2
    require(len(coded) == frames * coded_size and len(visible) == frames * visible_size,
            "ordinary coded/visible reference byte counts differ from delivered geometry")
    for frame in range(frames):
        mapped = extract_i420_region(coded[frame * coded_size:(frame + 1) * coded_size],
                                     layout, vw, vh, left, top)
        require(mapped == visible[frame * visible_size:(frame + 1) * visible_size],
                f"frame {frame}: independent coded-to-visible reference crop differs")


def padding_score(allocations, geometry):
    require(len(allocations) % ALLOCATION["frame_bytes"] == 0, "partial DDR allocation")
    cw, ch = geometry["coded_width"], geometry["coded_height"]
    frames = len(allocations) // ALLOCATION["frame_bytes"]
    planes = {name: {"samples": 0, "mismatches": 0, "expected_value": 16 if name == "Y" else 128}
              for name in ("Y", "U", "V")}
    first = None
    for frame in range(frames):
        for plane, name in enumerate(("Y", "U", "V")):
            scale = 1 if plane == 0 else 2
            stride, rows = ALLOCATION["strides"][plane], ALLOCATION["plane_rows"][plane]
            base = frame * ALLOCATION["frame_bytes"] + ALLOCATION["plane_offsets"][plane]
            for y in range(rows):
                start = cw // scale if y < ch // scale else 0
                for x in range(start, stride):
                    actual = allocations[base + y * stride + x]
                    metric = planes[name]
                    metric["samples"] += 1
                    if actual != metric["expected_value"]:
                        metric["mismatches"] += 1
                        if first is None:
                            first = {"index": frame, "plane": name, "x": x, "y": y,
                                     "actual": actual, "expected": metric["expected_value"]}
    wrong = sum(plane["mismatches"] for plane in planes.values())
    return {"exact": wrong == 0, "frames": frames, "mismatches": wrong, "planes": planes,
            "first_mismatch": first,
            "scope": "Only storage outside the coded rectangle; cropped coded margins are not padding."}


def compare_available(actual, reference, width, height, expected):
    size = width * height * 3 // 2
    count = len(actual) // size
    if not count or len(actual) % size or count > expected:
        return {"exact": False, "mismatches": None, "frames": [], "captured_frames": count}
    result = compare_native(actual, reference[:len(actual)], width, height, count)
    result["captured_frames"] = count
    return result


def score_geometry(visible, allocations, reference_visible, reference_coded, geometry, expected):
    validate_geometry(geometry)
    verify_reference_crop(reference_coded, reference_visible, geometry, expected)
    cw, ch = geometry["coded_width"], geometry["coded_height"]
    vw, vh = geometry["display_width"], geometry["display_height"]
    left, _, top, _ = geometry["crop_left_right_top_bottom"]
    allocation_size = ALLOCATION["frame_bytes"]
    allocation_count = len(allocations) // allocation_size
    comparison = compare_available(visible, reference_visible, vw, vh, expected)
    errors = []
    if len(visible) != expected * vw * vh * 3 // 2:
        errors.append("actual packed visible output is incomplete or oversized")
    valid_allocations = bool(allocations) and len(allocations) % allocation_size == 0 and allocation_count <= expected
    if len(allocations) != expected * allocation_size:
        errors.append("actual fixed-stride DDR allocation snapshots are missing/incomplete/oversized")
    coded, mapped_visible = bytearray(), bytearray()
    if valid_allocations:
        for frame in range(allocation_count):
            data = allocations[frame * allocation_size:(frame + 1) * allocation_size]
            coded.extend(extract_i420_region(data, ALLOCATION, cw, ch))
            mapped_visible.extend(extract_i420_region(data, ALLOCATION, vw, vh, left, top))
        padding = padding_score(allocations, geometry)
    else:
        padding = {"exact": False, "frames": allocation_count, "mismatches": None, "planes": {}}
    coded_comparison = compare_available(coded, reference_coded, cw, ch, expected)
    visible_mapping_exact = valid_allocations and bytes(mapped_visible) == visible
    if not comparison["exact"]:
        errors.append("actual packed visible Y/U/V differs from ordinary default decoding")
    if not coded_comparison["exact"]:
        errors.append("actual fixed-stride coded Y/U/V differs from ordinary uncropped decoding")
    if not padding["exact"]:
        errors.append("actual unused allocation padding differs from the FPGA Y16/U128/V128 contract")
    if not visible_mapping_exact:
        errors.append("actual packed visible output does not match the actual DDR plane/row crop")
    return {"comparison": comparison, "coded_comparison": coded_comparison,
            "allocation_padding": padding, "visible_from_allocation_exact": visible_mapping_exact,
            "allocation_frames": allocation_count, "errors": errors, "pass": not errors,
            "fixed_allocation_layout": ALLOCATION}


def geometry_negative_controls(visible, coded, geometry, count, build, manifest):
    vw, vh = geometry["display_width"], geometry["display_height"]
    cw, ch = geometry["coded_width"], geometry["coded_height"]
    visible_size = vw * vh * 3 // 2
    controls = {"visible_self_comparison": compare_native(visible, visible, vw, vh, count)["exact"],
                "coded_self_comparison": compare_native(coded, coded, cw, ch, count)["exact"]}
    for name, offset in (("Y", 0), ("U", vw * vh), ("V", vw * vh * 5 // 4)):
        wrong = bytearray(visible)
        wrong[offset] ^= 1
        controls[f"wrong_visible_oracle_{name}_rejected"] = not compare_native(
            visible, wrong, vw, vh, count)["exact"]
    if count > 1:
        controls["frozen_first_frame_rejected"] = not compare_native(
            visible[:visible_size] * count, visible, vw, vh, count)["exact"]
    else:
        controls["constant_zero_output_rejected"] = not compare_native(
            bytes(visible_size), visible, vw, vh, count)["exact"]
    try:
        compare_native(b"", visible, vw, vh, count)
        controls["missing_visible_output_rejected"] = False
    except RuntimeError:
        controls["missing_visible_output_rejected"] = True
    controls["missing_allocation_rejected"] = not score_geometry(
        visible, b"", visible, coded, geometry, count)["pass"]
    left, right, top, bottom = geometry["crop_left_right_top_bottom"]
    if any((left, right, top, bottom)):
        x, y = (0, 0) if left or top else (cw - 1, 0) if right else (0, ch - 1)
        wrong = bytearray(coded)
        wrong[y * cw + x] ^= 1
        controls["hidden_coded_margin_corruption_rejected"] = not compare_native(
            wrong, coded, cw, ch, count)["exact"]
        controls["hidden_margin_control_leaves_visible_unchanged"] = extract_i420_region(
            wrong[:cw * ch * 3 // 2], packed_i420_layout(cw, ch), vw, vh, left, top) == visible[:visible_size]
    if cw < 320 or ch < 240:
        # Local padding-scorer probe only; never saved as a DUT input or actual output.
        padding_probe = bytearray(bytes([16]) * 76800 + bytes([128]) * 38400)
        controls["padding_scorer_baseline"] = padding_score(padding_probe, geometry)["exact"]
        for plane, name in enumerate(("Y", "U", "V")):
            scale = 1 if plane == 0 else 2
            x, y = (cw // scale, 0) if cw < 320 else (0, ch // scale)
            offset = ALLOCATION["plane_offsets"][plane] + y * ALLOCATION["strides"][plane] + x
            padding_probe[offset] ^= 1
            controls[f"unused_allocation_{name}_corruption_rejected"] = not padding_score(
                padding_probe, geometry)["exact"]
            padding_probe[offset] ^= 1
    try:
        verify_build(build, "not-current-geometry-input-key", manifest["inputs"])
        controls["stale_build_rejected"] = False
    except RuntimeError:
        controls["stale_build_rejected"] = True
    require(all(controls.values()), "geometry scorer negative control failed")
    return controls


def native_beam_errors(scope, geometry, expected, scandouble):
    observations = scope["native_de_observations"]
    errors = []
    if len(observations) != expected:
        errors.append("requested native beam lacks every source-producer raster observation")
    for index, row in enumerate(observations):
        if (row["au_seq"] != index or row["scandouble"] != scandouble or
                row["de_height"] != geometry["display_height"] * (2 if scandouble else 1) or
                row["de_width"] <= 0 or row["rgb_samples"] != row["de_width"] * row["de_height"]):
            errors.append(f"AU {index}: native-beam identity/DE/raster count differs from selected geometry/mode")
    return errors


def native_dar_scope(geometry, source_dar, log):
    ratio = None
    if source_dar is not None:
        value = Fraction(str(source_dar))
        require(value > 0, "invalid original source DAR metadata")
        ratio = {"num": value.numerator, "den": value.denominator}
    observations = []
    for match in re.finditer(r"NATIVE_PASS seq=(\d+) DE=(\d+)x(\d+) RGB_samples=(\d+) scandouble=(\d+)", log):
        seq, width, height, samples, doubled = map(int, match.groups())
        observations.append({"au_seq": seq, "de_width": width, "de_height": height,
                             "rgb_samples": samples, "scandouble": doubled})
    return {
        "qualified": False, "source_display_aspect_ratio": source_dar,
        "source_display_aspect_ratio_rational": ratio,
        "sar_known": geometry["sar_known"], "sar_num": geometry["sar_num"], "sar_den": geometry["sar_den"],
        "bitstream_display_aspect_ratio": geometry["bitstream_display_aspect_ratio"],
        "native_de_observations": observations,
        "video_ar_and_autofit_observed": False,
        "limitation": "Cropped-byte equality and even local DE/RGB assertions do not prove the scaler's native DAR. "
                      "The genuine cropped content aperture must reach the scaler with AutoFit retained; applying "
                      "original DAR (including 83:50) to a larger padded active canvas is not correct. "
                      "No VIDEO_AR/AutoFit output-signal proof is currently scored here.",
    }
