#!/usr/bin/env bash
# Parent arbitration #3: present_core must keep w-clock B15 + w-mem B7/B16 symbols.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
[[ -f "$CORE" ]] || { echo "FAIL missing core"; exit 1; }

need=(
  beam_film_class
  cadence_display_hz
  present_beam_content_de
  PHYS_BASE_720P
  HPS_BANK_STRIDE_BYTES_720P
  DOORBELL_PHYS_720P
  geom_live_seq
  geom_live_valid
  stat_geom_hold_black
  stat_geom_hollow
  DDR_FRAME_STORE_RUNTIME_GEOM
  q5_reserved_reject
)
for s in "${need[@]}"; do
  grep -q "$s" "$CORE" || { echo "FAIL missing $s (merge drop class)"; exit 1; }
  echo "OK $s"
done

# B15 film threshold still <=24 not <=25
grep -q "content_fps <= 8'd24" "$CORE" || { echo "FAIL film threshold"; exit 1; }
if grep -n "content_fps <= 8'd25" "$CORE"; then
  echo "FAIL film <=25 restored"; exit 1
fi

# Gray underrun sat uses 16-bit compare (not wrapping 15-bit)
grep -q '16'"'"'h7fff' "$CORE" || grep -q '16.h7fff' "$CORE" || \
  grep -q '16'\''h7fff' "$CORE" || { echo "FAIL missing 16-bit sat constant"; exit 1; }
grep -q '16'\''({\s*1'\''b0, mp_rd_ur_count' "$CORE" || \
  grep -q '16'"'"'({1'"'"'b0, mp_rd_ur_count' "$CORE" || \
  grep -F "16'({1'b0, mp_rd_ur_count})" "$CORE" || {
  echo "FAIL gray sat not using 16-bit sum form"; exit 1; }

echo "PASS test_present_core_owner_merge true rc=0"
exit 0
