#!/usr/bin/env bash
# GATE: product IDR frame bit-exact vs FFmpeg deblock-OFF golden (Y+U+V).
# One-command human-free assertion for g-fit / merge trees.
#
#   bash tests/unit/test_idr_yuv_exact.sh
#
# Runs TWO fixtures (both must PASS):
#   624x480 → IDR_YUV_EXACT_OK mb=1170/1170 Y=299520 U=74880 V=74880
#   320x240 → IDR_YUV_EXACT_OK mb=300/300   Y=76800  U=19200 V=19200
#
# 320x240 caught I4x4 MPM rem vs pred=8 (mode-8 truncated to [2:0]) and
# runtime mb_width wrap — 624 alone was a blind spot.
#
# Never ALLOW_MISSING_VERILATOR. Does not start Quartus or touch MiSTer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPARE="$ROOT/tests/unit/test_stream_path_product_frame_compare.sh"

export PATH="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite}/bin:${PATH:-}"
if [[ -d "$HOME/.local/oss-cad-suite-20260726" ]]; then
  export OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
  export PATH="$OSS_CAD_SUITE/bin:$PATH"
fi

check_json() {
  local tag="$1" off_json="$2" y_tot="$3" u_tot="$4" v_tot="$5" mb_tot="$6"
  if [[ ! -f "$off_json" ]]; then
    echo "IDR_YUV_EXACT_FAIL[$tag]: missing $off_json" >&2
    exit 2
  fi
  python3 - "$tag" "$off_json" "$y_tot" "$u_tot" "$v_tot" "$mb_tot" <<'PY'
import json, sys
from pathlib import Path

tag, off_path = sys.argv[1], Path(sys.argv[2])
need = {"Y": int(sys.argv[3]), "U": int(sys.argv[4]), "V": int(sys.argv[5])}
mb_want = int(sys.argv[6])
off = json.loads(off_path.read_text())
frames = off.get("frames") or []
if not frames:
    print(f"IDR_YUV_EXACT_FAIL[{tag}]: no frames", file=sys.stderr)
    sys.exit(1)
fr0 = frames[0]
planes = {p.get("plane"): p for p in (fr0.get("planes") or [])}
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
if mb_e != mb_t or mb_t != mb_want:
    bad.append(f"mb_exact={mb_e}/{mb_t} (want {mb_want}/{mb_want})")
obs = off.get("observability") or {}
if obs.get("product_slice_desync"):
    bad.append(f"desync mb={obs.get('product_desync_mb')}")
if obs.get("product_rbsp_overflow"):
    bad.append("rbsp_overflow")
if obs.get("product_core_error"):
    bad.append("core_error")
if bad:
    print(f"IDR_YUV_EXACT_FAIL[{tag}]: " + "; ".join(bad), file=sys.stderr)
    sys.exit(1)
print(f"IDR_YUV_EXACT_OK[{tag}] mb={mb_e}/{mb_t} Y={need['Y']} U={need['U']} V={need['V']}")
sys.exit(0)
PY
}

if [[ "${IDR_YUV_EXACT_SKIP_RUN:-0}" != "1" ]]; then
  # 624x480 (default fixtures)
  bash "$COMPARE"
fi
check_json "624x480" "$ROOT/build/p3_product_frame/product_compare_deblock_off.json" \
  299520 74880 74880 1170

if [[ "${IDR_YUV_EXACT_SKIP_RUN:-0}" != "1" ]]; then
  PRODUCT_FRAME_BITSTREAM="$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264" \
  PRODUCT_FRAME_SEQUENCE="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_sequence_v1.json" \
  PRODUCT_FRAME_GOLDEN_OFF="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv" \
  PRODUCT_FRAME_GOLDEN_OFF_MANIFEST="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_frame_planes_v1.json" \
  PRODUCT_FRAME_MAX_VCL=1 \
  bash "$COMPARE"
  mkdir -p "$ROOT/build/p3_product_frame_320"
  cp -f "$ROOT/build/p3_product_frame/product_compare_deblock_off.json" \
        "$ROOT/build/p3_product_frame_320/product_compare_deblock_off.json"
fi
check_json "320x240" "$ROOT/build/p3_product_frame_320/product_compare_deblock_off.json" \
  76800 19200 19200 300

echo "IDR_YUV_EXACT_OK both fixtures 624x480+320x240"
