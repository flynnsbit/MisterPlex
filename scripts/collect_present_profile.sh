#!/bin/bash
# collect_present_profile.sh — Collect present-path timing decomposition from MiSTer.
#
# PURPOSE: Decompose the 63ms unexplained gap in the present interval.
# Enables PRESENT_PROFILE in misterplexd, collects one profile emission,
# then disables profiling and reports the breakdown.
#
# REQUIRES: SSH to MiSTer (MISTER_HOST/MISTER_PASS).
# NO hardware capture needed. Runs entirely over SSH.
#
# The profile breaks the present interval into:
#   read_us_f         — ffmpeg pipe read (= ARM decode time per frame)
#   pacing_wait_us_f  — A/V sync hold time per frame
#   ddr_prep_wait_us_p— usleep(1500) before DDR push
#   ddr_copy_us_p     — memcpy frame → DDR bank
#   ddr_flush_us_p    — dcache clean
#   ddr_doorbell_us_p — doorbell write + poll
#   ddr_post_wait_us_p— usleep(500) after DDR push
#   ddr_total_us_p    — total DDR push wall time
#   overlay_us_p      — OSD text render
#   fb_us_p           — framebuffer blit (fb0)
#
# EXIT:
#   0 = profile collected and parsed
#   1 = profile collection failed (daemon not running, no playback, timeout)
#   2 = SSH connectivity failure
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
TIMEOUT="${PROFILE_TIMEOUT:-30}"  # seconds to wait for a profile emission

ssh_cmd() {
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "root@$HOST" "$@" 2>/dev/null
}

echo "PRESENT_PROFILE_COLLECT host=$HOST timeout=${TIMEOUT}s"

# Check SSH connectivity
if ! ssh_cmd "echo ok" >/dev/null 2>&1; then
    echo "FAIL cannot reach $HOST via SSH" >&2
    exit 2
fi

# Check if misterplexd is running
if ! ssh_cmd "pgrep -f misterplexd" >/dev/null 2>&1; then
    echo "FAIL misterplexd not running on $HOST" >&2
    exit 1
fi

# Record resident RBF md5 (first line of any measurement)
RBF_MD5=$(ssh_cmd "md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | awk '{print \$1}'" || echo "unknown")
echo "PRESENT_PROFILE_COLLECT rbf_md5=$RBF_MD5"

# Enable profiling
echo "PRESENT_PROFILE_COLLECT enabling PRESENT_PROFILE..."
CONF="/media/fat/misterplex/misterplex.ini"
ssh_cmd "grep -q '^PRESENT_PROFILE=' $CONF 2>/dev/null && \
    sed -i 's/^PRESENT_PROFILE=.*/PRESENT_PROFILE=1/' $CONF || \
    echo 'PRESENT_PROFILE=1' >> $CONF"

# Signal daemon to reload config (SIGHUP)
ssh_cmd "pkill -HUP -f misterplexd" || true
sleep 2

# Wait for a present_profile log line (emitted every N frames during playback)
echo "PRESENT_PROFILE_COLLECT waiting for profile emission (${TIMEOUT}s)..."
PROFILE_LINE=""
END_TIME=$((SECONDS + TIMEOUT))
while [[ $SECONDS -lt $END_TIME ]]; do
    # Check the daemon log for the profile line
    LINE=$(ssh_cmd "journalctl -u misterplexd --since '30 seconds ago' --no-pager 2>/dev/null | grep 'present_profile' | tail -1" || true)
    if [[ -z "$LINE" ]]; then
        # Try syslog if journalctl unavailable
        LINE=$(ssh_cmd "grep 'present_profile' /tmp/misterplexd.log 2>/dev/null | tail -1" || true)
    fi
    if [[ -z "$LINE" ]]; then
        # Try dmesg or direct log
        LINE=$(ssh_cmd "cat /tmp/misterplex_media.log 2>/dev/null | grep 'present_profile' | tail -1" || true)
    fi
    if [[ -n "$LINE" ]]; then
        PROFILE_LINE="$LINE"
        break
    fi
    sleep 2
done

# Disable profiling
echo "PRESENT_PROFILE_COLLECT disabling PRESENT_PROFILE..."
ssh_cmd "sed -i 's/^PRESENT_PROFILE=.*/PRESENT_PROFILE=0/' $CONF" || true
ssh_cmd "pkill -HUP -f misterplexd" || true

if [[ -z "$PROFILE_LINE" ]]; then
    echo "FAIL no present_profile emission within ${TIMEOUT}s (is content playing?)" >&2
    echo "NOTE: profiling requires active playback. Start a video on the Plex client first." >&2
    exit 1
fi

echo ""
echo "=== RAW PROFILE LINE ==="
echo "$PROFILE_LINE"
echo ""

# Parse the profile line
echo "=== DECOMPOSITION ==="
parse_field() {
    local field="$1"
    echo "$PROFILE_LINE" | grep -oP "${field}=\K[0-9]+" || echo "?"
}

FRAMES=$(parse_field "frames")
PRESENTED=$(parse_field "presented")
DROPS=$(parse_field "drops")
READ_US_F=$(parse_field "read_us_f")
PACING_US_F=$(parse_field "pacing_wait_us_f")
DDR_PREP_US_P=$(parse_field "ddr_prep_wait_us_p")
DDR_COPY_US_P=$(parse_field "ddr_copy_us_p")
DDR_FLUSH_US_P=$(parse_field "ddr_flush_us_p")
DDR_DOORBELL_US_P=$(parse_field "ddr_doorbell_us_p")
DDR_POST_US_P=$(parse_field "ddr_post_wait_us_p")
DDR_TOTAL_US_P=$(parse_field "ddr_total_us_p")
DDR_UNACCOUNTED_US_P=$(parse_field "ddr_unaccounted_us_p")
OVERLAY_US_P=$(parse_field "overlay_us_p")
FB_US_P=$(parse_field "fb_us_p")

echo "frames=$FRAMES  presented=$PRESENTED  drops=$DROPS"
echo ""
echo "Per-frame (decode pipeline):"
echo "  read_us_f (ARM decode):     ${READ_US_F} µs"
echo "  pacing_wait_us_f (A/V sync): ${PACING_US_F} µs"
echo ""
echo "Per-present (DDR push):"
echo "  ddr_prep_wait_us_p:   ${DDR_PREP_US_P} µs"
echo "  ddr_copy_us_p:        ${DDR_COPY_US_P} µs"
echo "  ddr_flush_us_p:       ${DDR_FLUSH_US_P} µs"
echo "  ddr_doorbell_us_p:    ${DDR_DOORBELL_US_P} µs"
echo "  ddr_post_wait_us_p:   ${DDR_POST_US_P} µs"
echo "  ddr_total_us_p:       ${DDR_TOTAL_US_P} µs"
echo "  ddr_unaccounted_us_p: ${DDR_UNACCOUNTED_US_P} µs"
echo "  overlay_us_p:         ${OVERLAY_US_P} µs"
echo "  fb_us_p:              ${FB_US_P} µs"
echo ""

# Compute the key question: what is the 63ms?
python3 - <<PYEOF
read_ms = ${READ_US_F:-0} / 1000.0
pacing_ms = ${PACING_US_F:-0} / 1000.0
ddr_total_ms = ${DDR_TOTAL_US_P:-0} / 1000.0
ddr_copy_ms = ${DDR_COPY_US_P:-0} / 1000.0
overlay_ms = ${OVERLAY_US_P:-0} / 1000.0
fb_ms = ${FB_US_P:-0} / 1000.0
frames = ${FRAMES:-1}
presented = ${PRESENTED:-1}

present_ratio = presented / max(frames, 1)
total_per_present = read_ms + pacing_ms + ddr_total_ms + overlay_ms + fb_ms

print("=== KEY METRICS ===")
print(f"  ARM decode (read_us_f):     {read_ms:.1f} ms/frame")
print(f"  A/V pacing (wait):          {pacing_ms:.1f} ms/frame")
print(f"  DDR push total:             {ddr_total_ms:.1f} ms/present")
print(f"    of which memcpy:          {ddr_copy_ms:.1f} ms")
print(f"  Overlay render:             {overlay_ms:.1f} ms/present")
print(f"  fb0 blit:                   {fb_ms:.1f} ms/present")
print(f"  Present ratio:              {present_ratio*100:.1f}%")
print()

# The answer to "what is the 63ms?"
non_timeout_ms = read_ms + ddr_total_ms + overlay_ms + fb_ms
print(f"=== ANSWERING: what is the 63ms? ===")
print(f"  Decode + DMA + overhead:    {non_timeout_ms:.1f} ms")
print(f"  A/V pacing (separate):      {pacing_ms:.1f} ms")
print()

# Ceiling estimate
if read_ms > 0:
    decode_fps = 1000.0 / read_ms
    present_fps = 1000.0 / (read_ms + ddr_total_ms)
    print(f"=== FPS CEILING ESTIMATES ===")
    print(f"  Decode-only ceiling:        {decode_fps:.1f} fps")
    print(f"  Decode+DDR ceiling:         {present_fps:.1f} fps")
    print(f"  Content-limited (24 fps):   {min(24, present_fps):.1f} fps")
    print()
    if present_fps >= 24:
        print(f"  CONCLUSION: ARM can sustain 24 fps ({read_ms:.1f}ms decode < 41.7ms budget)")
        print(f"  Bank-release fix → 24+ fps presented (capped by content)")
    else:
        print(f"  CONCLUSION: ARM CANNOT sustain 24 fps ({read_ms:.1f}ms decode > 41.7ms budget)")
        print(f"  Even with bank-release fix, ceiling is {present_fps:.1f} fps")
        print(f"  THIS IS THE PROJECT'S MOTIVATION: decode must move to FPGA")
PYEOF

echo ""
echo "PRESENT_PROFILE_COLLECT rbf_md5=$RBF_MD5"
echo "PRESENT_PROFILE_COLLECT done"
