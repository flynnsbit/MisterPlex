#!/usr/bin/env bash
# test_integ_lane_evidence_markers.sh
# Permanent merge-loss detector. Ancestry alone is NOT content survival.
# true rc: 0=all markers present, 1=missing. Soft-skip never.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
fails=0
pass=0

have() {
  local path="$1" pat="$2" label="$3" min="${4:-1}"
  if [[ ! -f "$path" ]]; then
    echo "FAIL MISSING_FILE path=$path label=$label"
    fails=$((fails + 1))
    return
  fi
  local n
  n=$(rg -c --pcre2 "$pat" "$path" 2>/dev/null | awk -F: '{print $NF}' | tail -1)
  n=${n:-0}
  if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge "$min" ]]; then
    echo "OK $label count=$n path=$path"
    pass=$((pass + 1))
  else
    echo "FAIL $label count=${n:-0} want>=$min path=$path pat=$pat"
    fails=$((fails + 1))
  fi
}

STORE=fpga/Plex_MiSTer/rtl/ddr_frame_store.sv
BEAM=fpga/Plex_MiSTer/rtl/present_beam_content_de.sv
MUX=fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv
PLEX=fpga/Plex_MiSTer/Plex.sv
MAIL=host/libmisterplex/mailbox_abi_spec.hpp
LAYOUT=host/libmisterplex/ddr_frame_layout.hpp
LATCH=fpga/Plex_MiSTer/rtl/present_geom_latch.sv
Q5=host/libmisterplex/plxg_q5_aspect_cadence.hpp

echo "=== w-mem store / Option-C / reject path ==="
have "$STORE" 'rt_need_optc' 'mem.rt_need_optc' 1
have "$STORE" 'LEG_BANK_USABLE_BYTES' 'mem.LEG_BANK_USABLE_BYTES' 1
have "$STORE" 'rt_coded_w\[3:0\]' 'mem.rt_coded_w_16align' 1
have "$STORE" 'geom_reject' 'mem.geom_reject' 5

echo "=== collision #5 geom mux ==="
have "$MUX" 'plxg_live' 'mem.plxg_live' 1
have "$MUX" 'force_native_960\s*=\s*~plxg_live' 'mem.force_native_idle_only' 1

echo "=== ABI freeze PLXG ==="
have "$MAIL" 'kPlxgOffset\s*=\s*0x800u' 'abi.kPlxgOffset_0x800' 1
have "$LAYOUT" 'kDdrFramePlxgOffset' 'abi.kDdrFramePlxgOffset' 1
have "$LAYOUT" '0x800' 'abi.layout_mentions_0x800' 1

echo "=== w-clock beam port list (owner) ==="
have "$BEAM" 'use_rt_geom' 'clock.use_rt_geom' 1
have "$BEAM" 'rt_h_total' 'clock.rt_h_total' 1
have "$BEAM" 'htot_active' 'clock.htot_active' 1

echo "=== w-scaler B9 DAR consumer ==="
have "$PLEX" 'plex_video_ar' 'scaler.plex_video_ar' 1
if [[ -f "$LATCH" ]]; then
  have "$LATCH" 'dar_valid|dar_x|0x828' 'scaler.latch_q5_dar' 1
fi

echo "=== w-path / mem storage geometry APIs ==="
# Either path or mem name is required; path tip may use ddrStorageGeometryForContent only
have "$LAYOUT" 'ddrStorageGeometryForContent|ddrFfmpegGeometryForPresent' 'path.storage_geom_api' 1

echo "=== PLXG q5 ABI #2 (doorbell+0x828) ==="
q5=0
if [[ -f "$Q5" ]] && rg -q '0x828|dar_valid|content_fps' "$Q5"; then q5=1; fi
if rg -q '0x828' host/libmisterplex fpga/Plex_MiSTer 2>/dev/null; then q5=1; fi
if rg -q 'dar_valid|content_fps' host/libmisterplex fpga/Plex_MiSTer 2>/dev/null; then q5=1; fi
if [[ "$q5" -eq 1 ]]; then
  echo "OK abi.q5_present"
  pass=$((pass + 1))
else
  echo "FAIL abi.q5_present (need doorbell+0x828 DAR+fps packing)"
  fails=$((fails + 1))
fi

echo "=== summary pass=$pass fail=$fails ==="
if [[ "$fails" -gt 0 ]]; then
  echo "test_integ_lane_evidence_markers: FAIL"
  exit 1
fi
echo "test_integ_lane_evidence_markers: PASS"
exit 0
