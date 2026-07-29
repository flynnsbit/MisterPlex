#!/usr/bin/env bash
# GATE: product IDR frame bit-exact vs FFmpeg deblock-OFF golden (Y+U+V).
# One-command human-free assertion for g-fit / merge trees.
#
#   bash tests/unit/test_idr_yuv_exact.sh
#
# PASS prints:  IDR_YUV_EXACT_OK mb=1170/1170 Y=299520 U=74880 V=74880
# FAIL exits non-zero with first_bad plane/MB from product_compare_deblock_off.json.
#
# Never ALLOW_MISSING_VERILATOR. Does not start Quartus or touch MiSTer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPARE="$ROOT/tests/unit/test_stream_path_product_frame_compare.sh"
OUT_DIR="${PRODUCT_FRAME_OUT_DIR:-$ROOT/build/p3_product_frame}"
OFF_JSON="$OUT_DIR/product_compare_deblock_off.json"
SUMMARY="$OUT_DIR/summary.txt"

export PATH="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite}/bin:${PATH:-}"
# Prefer pinned suite if present (same as product compare).
if [[ -d "$HOME/.local/oss-cad-suite-20260726" ]]; then
  export OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
  export PATH="$OSS_CAD_SUITE/bin:$PATH"
fi

if [[ "${IDR_YUV_EXACT_SKIP_RUN:-0}" != "1" ]]; then
  bash "$COMPARE"
fi

if [[ ! -f "$OFF_JSON" ]]; then
  echo "IDR_YUV_EXACT_FAIL: missing $OFF_JSON (compare did not produce dump)" >&2
  exit 2
fi

python3 - "$OFF_JSON" "$SUMMARY" <<'PY'
import json, sys
from pathlib import Path

off_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
off = json.loads(off_path.read_text())
frames = off.get("frames") or []
if not frames:
    print("IDR_YUV_EXACT_FAIL: no frames in product_compare_deblock_off.json", file=sys.stderr)
    sys.exit(1)
fr0 = frames[0]
if fr0.get("slice_kind") not in ("I", "IDR", "i", None):
    # Still accept if frame0 is the IDR/I plane set.
    pass
planes = {p.get("plane"): p for p in (fr0.get("planes") or [])}
need = {"Y": 299520, "U": 74880, "V": 74880}
bad = []
for name, total in need.items():
    pl = planes.get(name)
    if not pl:
        bad.append(f"{name}:missing")
        continue
    ex = int(pl.get("exact_pixels") or 0)
    tot = int(pl.get("total_pixels") or 0)
    fb = pl.get("first_bad")
    if ex != total or tot != total or fb is not None:
        if fb:
            bad.append(
                f"{name}:exact={ex}/{tot} first_bad=mb_addr={fb.get('mb_addr')}"
                f" (x={fb.get('x')},y={fb.get('y')}) got={fb.get('got')} ref={fb.get('ref')}"
            )
        else:
            bad.append(f"{name}:exact={ex}/{tot}")
mb_e = fr0.get("mb_exact")
mb_t = fr0.get("mb_total")
if mb_e != mb_t or mb_t != 1170:
    bad.append(f"mb_exact={mb_e}/{mb_t} (want 1170/1170)")

obs = off.get("observability") or {}
if obs.get("product_slice_desync"):
    bad.append(f"desync mb={obs.get('product_desync_mb')} cause={obs.get('product_desync_cause')}")
if obs.get("product_rbsp_overflow"):
    bad.append("rbsp_overflow")

line_sum = ""
if summary_path.is_file():
    for line in summary_path.read_text().splitlines():
        if line.startswith("IDR_deblock_OFF:"):
            line_sum = line
            break

if bad:
    print("IDR_YUV_EXACT_FAIL: " + "; ".join(bad), file=sys.stderr)
    if line_sum:
        print(line_sum, file=sys.stderr)
    sys.exit(1)

print(
    f"IDR_YUV_EXACT_OK mb={mb_e}/{mb_t} "
    f"Y={need['Y']} U={need['U']} V={need['V']}"
)
if line_sum:
    print(line_sum)
sys.exit(0)
PY
