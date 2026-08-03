#!/usr/bin/env bash
# q5 end-to-end product wire: latch → plxg_* → AR + fps_sel.
# Static Plex.sv connectivity + hierarchy RTL. Red: FAULT_DROP_LATCH_Q5.
# Presence is not connectivity — this is parent miss #11 class.
# HOST SEQLOCK FENCE (rd-duck): this proves FABRIC consumers only. Standalone
# writePlxgQ5 at doorbell+0x828 never promotes under w-mem poller; q5 must ride
# writePlxgRecord (6-qword) on bootstrap 0x300FF800 and Option-C. See
# test_plxg_q5_host_seqlock_static.py — fabric PASS ≠ host publish PASS.
set -euo pipefail

assert_exec() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0 m
  for m in "$@"; do
    grep -q -- "$m" <<<"$log" || { echo "FAIL $label missing: $m" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLEX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
RUN="$ROOT/scripts/run_verilator.sh"

echo "=== STATIC Plex.sv q5 connectivity (undriven-class greps) ===" >&2
# Canonical plxg_* only — no fabric_* split brain
if grep -nE 'fabric_dar_|fabric_content_fps|fabric_fps_valid' "$PLEX"; then
  echo "FAIL fabric_* q5 aliases still present — use plxg_* only" >&2
  exit 1
fi
# Latch drives plxg_*
for pin in 'dar_valid(plxg_dar_valid)' 'dar_x(plxg_dar_x)' 'dar_y(plxg_dar_y)' \
           'fps_valid(plxg_fps_valid)' 'content_fps(plxg_content_fps)'; do
  grep -q "\.$pin" "$PLEX" || { echo "FAIL u_plxg_latch missing .$pin" >&2; exit 1; }
done
# Consumers
grep -q 'host_dar_valid(plxg_dar_valid)' "$PLEX" || { echo "FAIL video_ar not on plxg_dar_valid" >&2; exit 1; }
grep -q 'host_dar_x(plxg_dar_x)' "$PLEX" || { echo "FAIL video_ar not on plxg_dar_x" >&2; exit 1; }
grep -q 'host_dar_y(plxg_dar_y)' "$PLEX" || { echo "FAIL video_ar not on plxg_dar_y" >&2; exit 1; }
grep -q 'u_content_fps_sel' "$PLEX" || { echo "FAIL plex_content_fps_sel not instantiated" >&2; exit 1; }
grep -q 'fps_valid(plxg_fps_valid)' "$PLEX" || { echo "FAIL fps_sel missing plxg_fps_valid" >&2; exit 1; }
grep -q 'content_fps_q5(plxg_content_fps)' "$PLEX" || { echo "FAIL fps_sel missing plxg_content_fps" >&2; exit 1; }
# Product must not hardwire content_fps outside FAULT
if awk '
  /FAULT_B15_FPS_HARDWIRE_24/ { fault=1; next }
  /`endif/ && fault { fault=0; next }
  !fault && /wire[[:space:]]*\[7:0\][[:space:]]*content_fps[[:space:]]*=[[:space:]]*8.d24/ { found=1 }
  END { exit found?0:1 }
' "$PLEX"; then
  echo "FAIL product hardwires content_fps=8'd24 outside FAULT_B15" >&2
  exit 1
fi
# present_core must take content_fps net (sel output), not a second literal
grep -q '\.content_fps(content_fps)' "$PLEX" || { echo "FAIL present_core.content_fps not wired" >&2; exit 1; }
echo "OK static Plex.sv q5 producer→consumer connectivity"

set +e
"$RUN" --version >/dev/null 2>&1
VRC=$?
set -e
if [[ "$VRC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && exit 77
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
fi

SV=(
  "$ROOT/tests/rtl/plex_q5_product_wire_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_geom_latch.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_video_ar.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_content_fps_sel.sv"
  "$ROOT/tests/rtl/plex_q5_product_wire_tb.cpp"
)
VFLAGS=(--cc --exe --build --top-module plex_q5_product_wire_tb
  -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
  -CFLAGS "-std=c++17 -O2")

run_case() {
  local name="$1" define="$2" expect_rc="$3"; shift 3
  local bdir="$ROOT/build/verilator/plex_q5_wire_${name}"
  mkdir -p "$bdir"
  echo "=== BUILD q5_wire $name ===" >&2
  if [[ -n "$define" ]]; then
    "$RUN" "${VFLAGS[@]}" -D"$define" --Mdir "$bdir" --prefix Vplex_q5_product_wire_tb "${SV[@]}"
  else
    "$RUN" "${VFLAGS[@]}" --Mdir "$bdir" --prefix Vplex_q5_product_wire_tb "${SV[@]}"
  fi
  set +e
  local out rc
  out="$(Q5_WIRE_CASE="$name" "$bdir/Vplex_q5_product_wire_tb" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "q5_wire_${name} true rc=$rc"
  assert_exec "q5-$name" "$out" "$@"
  if [[ "$rc" -ne "$expect_rc" ]]; then
    echo "FAIL q5_wire_$name want rc=$expect_rc got $rc" >&2
    exit 1
  fi
}

run_case green "" 0 \
  "EXECUTED green" "PASS q5-wire-green" \
  "EXECUTED unspecified_fps" "PASS unspecified_fps" \
  "PASS no_dar_fallback_4_3" \
  "plex_q5_product_wire_tb: PASS"

run_case drop "FAULT_DROP_LATCH_Q5" 0 \
  "EXECUTED drop" "PASS q5-wire-drop" \
  "plex_q5_product_wire_tb: PASS"

echo "test_plex_q5_product_wire_rtl_sim: PASS"
exit 0
