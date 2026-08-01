#!/usr/bin/env bash
# Parent-only: poll PLXD frames_done on the MiSTer during playback and write CSV
# for tools/fabric_frames_done_hold_hist.py.
#
# Does NOT deploy, does NOT load cores. Agent must not run this against the device.
#
# Usage (parent, while 480p OCR fixture is playing on product path):
#   OUT=./fabric_fd_hold.csv DURATION_S=60 PERIOD_MS=2 \
#     ./scripts/poll_plxd_frames_done_hold.sh
#   python3 tools/fabric_frames_done_hold_hist.py --csv "$OUT"
#
# Env:
#   MISTER_HOST (default 192.168.1.183)
#   MISTER_PASS (default 1)
#   OUT          CSV path (required)
#   DURATION_S   default 60
#   PERIOD_MS    poll period default 2 (need << 16.7ms)
#
# PLXD layout (quoted ddr_frame_store.sv): magic PLXD @ doorbell+0x128,
# frames_done in [63:48] of that 64-bit word. bank_vsync_count is NOT packed.
set -euo pipefail

: "${OUT:?set OUT=path/to.csv}"
: "${MISTER_HOST:=192.168.1.183}"
: "${MISTER_PASS:=1}"
: "${DURATION_S:=60}"
: "${PERIOD_MS:=2}"

# Product YUV doorbell 0x300FF000 → PLXD 0x300FF128
PLXD_PHYS=0x300FF128

echo "PRE-REGISTER (parent): expect fabric frac_ge4 in one of:"
echo "  healthy [0,0.03] | hdmi_match [0.08,0.13] | lean [0.05,0.15]"
echo "polling ${MISTER_HOST} PLXD@${PLXD_PHYS} for ${DURATION_S}s every ${PERIOD_MS}ms -> ${OUT}"

# Busybox-friendly remote loop: devmem reads 32-bit; frames_done is hi half of 64-bit
# word at PLXD — read phys+4 for upper 32 bits containing frames_done in [31:16].
REMOTE_SCRIPT=$(cat <<'EOS'
set -e
PLXD_HI=$((0x300FF128 + 4))
DUR=${1:-60}
PER_MS=${2:-2}
# print mono_ms,frames_done
start=$(cut -d' ' -f1 /proc/uptime)
end=$(awk -v s="$start" -v d="$DUR" 'BEGIN{print s+d}')
while true; do
  now=$(cut -d' ' -f1 /proc/uptime)
  awk -v n="$now" -v e="$end" 'BEGIN{exit !(n<e)}' || break
  # uptime seconds -> ms
  ms=$(awk -v n="$now" -v s="$start" 'BEGIN{printf "%.3f", (n-s)*1000}')
  raw=$(devmem2 "$PLXD_HI" w 2>/dev/null | awk '/Read/{print $NF}')
  # frames_done = raw[31:16]
  if [ -n "$raw" ]; then
    fd=$(( (raw >> 16) & 0xFFFF ))
    echo "${ms},${fd}"
  fi
  # sleep PERIOD_MS
  usleep $((PER_MS * 1000)) 2>/dev/null || sleep 0.00${PER_MS} 2>/dev/null || true
done
EOS
)

echo "mono_ms,frames_done" >"$OUT"
# sshpass if available
if command -v sshpass >/dev/null 2>&1; then
  sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no root@"$MISTER_HOST" \
    "sh -s -- $DURATION_S $PERIOD_MS" <<<"$REMOTE_SCRIPT" >>"$OUT" || true
else
  ssh -o StrictHostKeyChecking=no root@"$MISTER_HOST" \
    "sh -s -- $DURATION_S $PERIOD_MS" <<<"$REMOTE_SCRIPT" >>"$OUT" || true
fi

ROWS=$(($(wc -l <"$OUT") - 1))
echo "wrote $OUT rows=$ROWS (header excluded)"
if [[ "$ROWS" -lt 50 ]]; then
  echo "WARN: few rows — check devmem2 on MiSTer and that Plex core is running" >&2
fi
echo "Score with:"
echo "  python3 tools/fabric_frames_done_hold_hist.py --csv $OUT"
echo "  # optional measured vsync: --t-vsync-ms 16.667"
exit 0
