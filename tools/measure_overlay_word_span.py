#!/usr/bin/env python3
"""Measure STOPPED/PAUSED word ink span in OUTPUT pixels on a capture.

Reports span at the capture's native width (e.g. 1920) so it is directly
comparable to a hand-measured HDMI figure. Also maps to canvas px under
explicit divisors (624/640/529/320) — each labeled, never assumed.

Usage:
  python3 tools/measure_overlay_word_span.py --image CAP.png --expect STOPPED
  python3 tools/measure_overlay_word_span.py --image CAP.png --expect STOPPED; echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Import sibling tool helpers.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from readback_overlay_text import (  # noqa: E402
    cell_span_px,
    find_string,
    load_png_luma,
    measure_ink_span,
    normalize_capture,
    print_result,
    resolve_font_from_span,
    RC_FAIL,
    RC_PASS,
    RC_UNSCORED,
)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--image", type=Path, required=True)
    ap.add_argument("--expect", default="STOPPED")
    args = ap.parse_args(argv)

    if not args.image.is_file():
        print(f"image={args.image}")
        return print_result(RC_FAIL, error="missing_image", verdict="FAIL")

    w, h, rows = load_png_luma(args.image)
    print(f"image={args.image}")
    print(f"capture_geometry={w}x{h}")

    norm, tag = normalize_capture(rows)
    if norm is None:
        print(f"geometry_tag={tag}")
        return print_result(RC_UNSCORED, recovered="<unscored>", verdict="UNSCORED")

    rec, score, meta = find_string(norm, args.expect)
    print(f"geometry_tag={tag}")
    print(f"recovered={rec!r} score={score:.4f}")
    print(f"meta_norm={meta}")

    if rec != args.expect or not meta or meta.get("x") is None:
        return print_result(RC_FAIL, recovered=rec or "<empty>", expect=args.expect,
                            verdict="FAIL_NO_WORD")

    # Map norm location → full capture pixels.
    nw = len(norm[0])
    nh = len(norm)
    sx = w / float(nw)
    sy = h / float(nh)
    fx = int(meta["x"] * sx) - 8
    fy = int(meta["y"] * sy) - 4
    # Box large enough for either font family at scale 2–3 after upscale.
    fmw = int(cell_span_px(args.expect, "12x16", 3) * sx) + 32
    fmh = int(16 * 3 * sy) + 16
    fx = max(0, fx)
    fy = max(0, fy)

    span_out = measure_ink_span(rows, fx, fy, fmw, fmh, thr=160)
    print(f"full_box=x{fx},y{fy},{fmw}x{fmh}")
    print(f"ink_span_output_px={span_out}")

    if span_out is None:
        return print_result(RC_FAIL, recovered=rec, expect=args.expect,
                            verdict="FAIL_NO_INK")

    # Predictions at this capture width for product authorships.
    pred_12 = cell_span_px(args.expect, "12x16", 2) * (w / 624.0)
    pred_8 = cell_span_px(args.expect, "8x13", 2) * (w / 624.0)
    pred_12_640 = cell_span_px(args.expect, "12x16", 2) * (w / 640.0)
    pred_8_640 = cell_span_px(args.expect, "8x13", 2) * (w / 640.0)
    print(f"pred_12x16@2_via624={pred_12:.1f}")
    print(f"pred_8x13@2_via624={pred_8:.1f}")
    print(f"pred_12x16@2_via640={pred_12_640:.1f}")
    print(f"pred_8x13@2_via640={pred_8_640:.1f}")

    for div in (624, 640, 529, 320):
        canvas = span_out * div / float(w)
        print(f"map_div{div}_canvas_px={canvas:.2f}")

    font_m, scale_m, detail = resolve_font_from_span(
        args.expect, int(round(span_out * 640.0 / w))  # span in 640-norm space
    )
    # Prefer full-res classification against 624-authored preds at this W.
    err12 = abs(span_out - pred_12) / pred_12
    err8 = abs(span_out - pred_8) / pred_8
    if err12 < 0.12 and err12 + 0.10 < err8:
        family = "12x16"
    elif err8 < 0.12 and err8 + 0.10 < err12:
        family = "8x13"
    else:
        family = "UNRESOLVED"
    print(f"family_at_output={family} err12={err12:.4f} err8={err8:.4f}")
    print(f"norm_font_from_span={font_m} scale={scale_m} detail={detail}")

    ok = rec == args.expect
    return print_result(RC_PASS if ok else RC_FAIL,
                        recovered=rec, expect=args.expect,
                        ink_span_output_px=span_out,
                        family=family,
                        verdict="PASS" if ok else "FAIL")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"error={e}", file=sys.stderr)
        print("true rc=1")
        sys.exit(1)
