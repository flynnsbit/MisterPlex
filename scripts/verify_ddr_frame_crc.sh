#!/bin/bash
# verify_ddr_frame_crc.sh — ARM-side CRC of the DDR frame store.
#
# PURPOSE: Verify ARM→DDR write correctness without HDMI capture hardware.
# Computes CRC-32 over the Y, U, and V planes of the specified bank in the
# DDR frame store at 0x30000000, and compares against a declared golden CRC.
#
# WHAT THIS COVERS:
#   ✅ ARM decode correctness (ffmpeg → raw I420)
#   ✅ DDR write path (mmap → f2sdram → DDR3)
#   ✅ Frame geometry (plane offsets, strides match contract)
#
# WHAT THIS DOES NOT COVER:
#   ❌ FPGA present path (DDR read → YUV→RGB → HDMI scanout)
#   ❌ Colour matrix conversion (BT.601/709, full/limited range)
#   ❌ Scaling, crop, pillarbox on the output side
#   ❌ That the user sees the correct picture on their display
#
# This is "Tier 1" verification: it proves the decode and write are correct.
# "Tier 2" (full HDMI capture via hw_visual_compare.py) is still needed for
# end-to-end visual verification including the FPGA present path.
#
# REQUIRES: ssh access to MiSTer (MISTER_HOST), dd, crc32 or cksum on target.
# No HDMI grabber, no USB device, no physical presence.
#
# USAGE:
#   scripts/verify_ddr_frame_crc.sh [--bank 0|1] [--golden CRC_FILE]
#
# The golden CRC file contains three lines (Y, U, V plane CRC-32):
#   y_crc32=XXXXXXXX  y_bytes=299520
#   u_crc32=XXXXXXXX  u_bytes=74880
#   v_crc32=XXXXXXXX  v_bytes=74880
#
# On first run with --capture-golden, it captures and saves the current CRC.
# On subsequent runs, it compares against the golden.
#
# EXIT CODES:
#   0 = CRC match (all planes)
#   1 = CRC mismatch (identifies which plane(s) differ)
#   2 = cannot read DDR (permissions, connectivity)
#   3 = golden file missing or malformed
#   7 = frame store not populated (doorbell not set or sequence=0)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
BANK="${BANK:-0}"
GOLDEN=""
CAPTURE_GOLDEN=0
RBF_MD5=""

# DDR frame store layout (from ddr_frame_layout.hpp)
PHYS_BASE=0x30000000
YUV420P_BANK_STRIDE=$((0x00080000))  # 524288
Y_OFFSET=0
U_OFFSET=299520
V_OFFSET=374400
Y_BYTES=299520      # 624 × 480
U_BYTES=74880       # 312 × 240
V_BYTES=74880       # 312 × 240
DOORBELL_OFFSET=$((YUV420P_BANK_STRIDE * 2 - 0x1000))  # 0x000FF000
DOORBELL_MAGIC="504c584b"  # PLXK

usage() {
    echo "Usage: $0 [--bank 0|1] [--golden FILE] [--capture-golden FILE] [--rbf-md5 MD5]"
    echo ""
    echo "  --bank N            DDR bank to read (default: 0)"
    echo "  --golden FILE       CRC golden file to compare against"
    echo "  --capture-golden F  Capture current CRC and save as golden"
    echo "  --rbf-md5 MD5       Expected RBF md5 (recorded in golden, not verified here)"
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bank) BANK="$2"; shift 2;;
        --golden) GOLDEN="$2"; shift 2;;
        --capture-golden) CAPTURE_GOLDEN=1; GOLDEN="$2"; shift 2;;
        --rbf-md5) RBF_MD5="$2"; shift 2;;
        -h|--help) usage;;
        *) echo "Unknown argument: $1" >&2; usage;;
    esac
done

ssh_cmd() {
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "root@$HOST" "$@" 2>/dev/null
}

# Compute physical address for this bank
BANK_BASE=$((PHYS_BASE + BANK * YUV420P_BANK_STRIDE))
DOORBELL_ADDR=$((PHYS_BASE + DOORBELL_OFFSET))

echo "DDR_FRAME_CRC host=$HOST bank=$BANK bank_base=$(printf '0x%08x' $BANK_BASE)"

# Check doorbell first — refuse to grade an unpopulated frame store
DOORBELL_HEX=$(ssh_cmd "devmem2 $(printf '0x%08x' $DOORBELL_ADDR) w 2>/dev/null | grep 'Read.*:' | awk '{print \$NF}'" || true)
if [[ -z "$DOORBELL_HEX" ]]; then
    echo "FAIL cannot read doorbell at $(printf '0x%08x' $DOORBELL_ADDR) — connectivity or permissions" >&2
    exit 2
fi
# Strip 0x prefix if present
DOORBELL_HEX="${DOORBELL_HEX#0x}"
DOORBELL_HEX="${DOORBELL_HEX#0X}"
DOORBELL_LOWER=$(echo "$DOORBELL_HEX" | tr 'A-F' 'a-f')
if [[ "${DOORBELL_LOWER:0:8}" != "$DOORBELL_MAGIC" && "${DOORBELL_LOWER}" == "00000000" ]]; then
    echo "FAIL doorbell=$(printf '0x%s' "$DOORBELL_LOWER") — frame store not populated (no PLXK magic)" >&2
    exit 7
fi
echo "DDR_FRAME_CRC doorbell=0x$DOORBELL_LOWER"

# Read each plane and compute CRC
# Using dd from /dev/mem on the MiSTer (requires root — misterplexd runs as root)
compute_plane_crc() {
    local plane_name="$1"
    local offset="$2"
    local size="$3"
    local addr=$((BANK_BASE + offset))

    # Use dd to read the plane, pipe to cksum
    local result
    result=$(ssh_cmd "dd if=/dev/mem bs=1 skip=$addr count=$size 2>/dev/null | cksum" || true)
    if [[ -z "$result" ]]; then
        echo "FAIL cannot read $plane_name plane at $(printf '0x%08x' $addr)" >&2
        exit 2
    fi
    # cksum output: CRC SIZE
    local crc size_out
    crc=$(echo "$result" | awk '{print $1}')
    size_out=$(echo "$result" | awk '{print $2}')
    if [[ "$size_out" != "$size" ]]; then
        echo "FAIL $plane_name plane size mismatch: got $size_out, expected $size" >&2
        exit 2
    fi
    echo "$crc"
}

echo "DDR_FRAME_CRC reading planes..."
Y_CRC=$(compute_plane_crc "Y" $Y_OFFSET $Y_BYTES)
U_CRC=$(compute_plane_crc "U" $U_OFFSET $U_BYTES)
V_CRC=$(compute_plane_crc "V" $V_OFFSET $V_BYTES)

echo "DDR_FRAME_CRC y_crc=$Y_CRC y_bytes=$Y_BYTES"
echo "DDR_FRAME_CRC u_crc=$U_CRC u_bytes=$U_BYTES"
echo "DDR_FRAME_CRC v_crc=$V_CRC v_bytes=$V_BYTES"

# Capture golden mode
if [[ "$CAPTURE_GOLDEN" -eq 1 ]]; then
    if [[ -z "$GOLDEN" ]]; then
        echo "FAIL --capture-golden requires a filename" >&2
        exit 3
    fi
    mkdir -p "$(dirname "$GOLDEN")"
    cat > "$GOLDEN" <<EOF
# DDR frame store CRC golden — captured $(date -Iseconds)
# host=$HOST bank=$BANK rbf_md5=${RBF_MD5:-unknown}
# COVERS: ARM decode + DDR write correctness
# DOES NOT COVER: FPGA present path (DDR→HDMI)
y_crc=$Y_CRC  y_bytes=$Y_BYTES
u_crc=$U_CRC  u_bytes=$U_BYTES
v_crc=$V_CRC  v_bytes=$V_BYTES
EOF
    echo "CAPTURED golden saved to $GOLDEN"
    exit 0
fi

# Compare mode
if [[ -z "$GOLDEN" ]]; then
    echo "DDR_FRAME_CRC no golden specified — capture-only mode"
    exit 0
fi

if [[ ! -f "$GOLDEN" ]]; then
    echo "FAIL golden file not found: $GOLDEN" >&2
    exit 3
fi

# Parse golden
GOLDEN_Y=$(grep '^y_crc=' "$GOLDEN" | sed 's/y_crc=\([^ ]*\).*/\1/')
GOLDEN_U=$(grep '^u_crc=' "$GOLDEN" | sed 's/u_crc=\([^ ]*\).*/\1/')
GOLDEN_V=$(grep '^v_crc=' "$GOLDEN" | sed 's/v_crc=\([^ ]*\).*/\1/')

if [[ -z "$GOLDEN_Y" || -z "$GOLDEN_U" || -z "$GOLDEN_V" ]]; then
    echo "FAIL golden file malformed (missing y_crc/u_crc/v_crc)" >&2
    exit 3
fi

# Compare
MISMATCH=0
if [[ "$Y_CRC" != "$GOLDEN_Y" ]]; then
    echo "MISMATCH Y plane: got $Y_CRC, expected $GOLDEN_Y"
    MISMATCH=1
fi
if [[ "$U_CRC" != "$GOLDEN_U" ]]; then
    echo "MISMATCH U plane: got $U_CRC, expected $GOLDEN_U"
    MISMATCH=1
fi
if [[ "$V_CRC" != "$GOLDEN_V" ]]; then
    echo "MISMATCH V plane: got $V_CRC, expected $GOLDEN_V"
    MISMATCH=1
fi

if [[ "$MISMATCH" -eq 0 ]]; then
    echo "PASS DDR frame CRC matches golden (all planes)"
    exit 0
else
    echo "FAIL DDR frame CRC mismatch"
    exit 1
fi
