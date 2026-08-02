#!/usr/bin/env bash
# B2/B5 source wiring — red-before-green via string presence in product path.
# Not a device test. true rc direct.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
YF="$ROOT/host/libmisterplex/yuv420p_chroma_health.hpp"
fail=0
pass=0

check() {
  local name="$1" file="$2" pat="$3"
  if rg -n --fixed-strings "$pat" "$file" >/dev/null; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name missing: $pat" >&2
    fail=$((fail + 1))
  fi
}

# B2 product play path must use info (not only error helpers).
if rg -n 'args.push_back\("-loglevel"\);' -A1 "$MP" | rg -q 'info'; then
  echo "PASS B2_loglevel_info_present"
  pass=$((pass + 1))
else
  echo "FAIL B2_loglevel_info_present" >&2
  fail=$((fail + 1))
fi
# Guard comment must remain load-bearing.
check B2_do_not_error_comment "$MP" 'DO NOT change to error — breaks delivered_geom'

# B5 arm teardown calls
check B5_byte_align "$MP" 'rawPipeByteAligned(totalBytes, frameBytes)'
check B5_phase_desync "$MP" 'rawPipeDesynced(prodBytes, frameBytes'
check B5_pipe_desync_log "$MP" 'PIPE_DESYNC=1'
check B5_pipe_byte_misalign_log "$MP" 'PIPE_BYTE_MISALIGN'
check B5_total_mod_frame_ok "$MP" 'total_mod_frame=0'
check B5_pipe_total_mod_hz "$MP" 'pipe_total_mod='
check B5_session_collapse_ledger "$MP" 'SESSION_COLLAPSE_LEDGER'
check B5_delivery_mismatch_log "$MP" 'DELIVERY_MISMATCH'
check B5_decode_target_match "$MP" 'decode_target_match='
check B5_coded_bank_field "$MP" 'coded_bank='
check B5_force_scale_protects "$MP" 'force_scale_protects='
check B5_vertical_detail_frac "$MP" 'vertical_detail_frac='
# Pump compares measured to DDR coded bank args, not DECODE tier alone.
check B5_pump_takes_coded_wh "$MP" 'int codedW, int codedH'
# GEOM predicts square-pixel fit from SAR/DAR (ceiling, not exact).
MAIN_GEOM="$ROOT/arm/misterplexd/main.cpp"
check GEOM_predicted_square_fit "$MAIN_GEOM" 'predicted_square_fit='
check GEOM_videoResolution_ceiling_note "$MAIN_GEOM" 'videoResolution_is_ceiling_not_exact'
check GEOM_pms_delivery_geom_hdr "$MAIN_GEOM" 'pms_delivery_geom.hpp'

# B4 measured only
check B4_measured_only "$YF" 'return std::string(deliveryBasis) == "measured"'
check B4_reject_library_media "$YF" 'library_media is PMS *scanner display metadata*'

# FORCE_SCALE product default ON (not opt-in) — parent "should default 1?" = already true
MAIN="$ROOT/arm/misterplexd/main.cpp"
check FORCE_SCALE_default_true "$MAIN" 'bool ddrYuvForceScale = true'
check FORCE_SCALE_lab_escape "$MAIN" 'DDR_YUV_FORCE_SCALE_LAB'

echo "SUMMARY pass=$pass fail=$fail"
if [[ "$fail" -ne 0 ]]; then
  echo "B2_B5_SOURCE_WIRING_FAIL"
  exit 1
fi
echo "B2_B5_SOURCE_WIRING_OK"
exit 0
