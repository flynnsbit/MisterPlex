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

# B4 measured only
check B4_measured_only "$YF" 'return std::string(deliveryBasis) == "measured"'
check B4_reject_library_media "$YF" 'library_media is PMS *scanner display metadata*'

echo "SUMMARY pass=$pass fail=$fail"
if [[ "$fail" -ne 0 ]]; then
  echo "B2_B5_SOURCE_WIRING_FAIL"
  exit 1
fi
echo "B2_B5_SOURCE_WIRING_OK"
exit 0
