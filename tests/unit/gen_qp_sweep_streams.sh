#!/usr/bin/env bash
# Generate H.264 Annex B streams at all 52 QP values (0–51) using x264.
# Uses constant-QP mode (--qp N) to ensure each stream exercises exactly one QP.
# Produces 320x240 I-frame-only streams compatible with the MiSTerPlex test corpus.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTDIR="${ROOT}/build/qp_sweep_streams"
SRCYUV="${ROOT}/build/qp_sweep_src.yuv"
WIDTH=320
HEIGHT=240
FRAMES=1

if ! command -v x264 >/dev/null 2>&1; then
    echo "FAIL qp-sweep-gen: x264 not found" >&2
    exit 2
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "FAIL qp-sweep-gen: ffmpeg not found" >&2
    exit 2
fi

mkdir -p "$OUTDIR"

# Generate a test source frame (gradient pattern for good coverage of all coefficients)
if [ ! -f "$SRCYUV" ]; then
    ffmpeg -y -f lavfi -i "testsrc2=duration=0.04:size=${WIDTH}x${HEIGHT}:rate=25" \
        -pix_fmt yuv420p -frames:v "$FRAMES" "$SRCYUV" 2>/dev/null
fi

echo "Generating QP 0–51 H.264 streams (${WIDTH}x${HEIGHT}, I-only, Baseline profile)..."

GENERATED=0
FAILED=0

for QP in $(seq 0 51); do
    OUTFILE="${OUTDIR}/qp${QP}.264"
    if [ -f "$OUTFILE" ] && [ -s "$OUTFILE" ]; then
        GENERATED=$((GENERATED + 1))
        continue
    fi

    # QP 0 is lossless — requires High 4:4:4 profile.
    if [ "$QP" -eq 0 ]; then
        PROFILE="high444"
    else
        PROFILE="baseline"
    fi

    if x264 --input-res "${WIDTH}x${HEIGHT}" --fps 25 \
            --profile "$PROFILE" --level 3.1 \
            --qp "$QP" --keyint 1 --bframes 0 \
            --no-cabac --no-deblock \
            --frames "$FRAMES" \
            -o "$OUTFILE" "$SRCYUV" >/dev/null 2>&1; then
        if [ -s "$OUTFILE" ]; then
            GENERATED=$((GENERATED + 1))
        else
            echo "  WARN: QP=$QP produced empty file" >&2
            FAILED=$((FAILED + 1))
        fi
    else
        echo "  WARN: QP=$QP encoding failed (x264 rc=$?)" >&2
        FAILED=$((FAILED + 1))
    fi
done

echo "Generated: $GENERATED/52 streams, failed: $FAILED"
echo "Output: $OUTDIR/"

if [ "$GENERATED" -lt 52 ]; then
    echo "FAIL qp-sweep-gen: only $GENERATED/52 streams generated" >&2
    exit 1
fi

# Print stream sizes as a basic sanity check
echo ""
echo "Stream sizes (bytes):"
echo "QP  | Size    | Note"
echo "----|---------|-----"
for QP in $(seq 0 51); do
    SIZE=$(stat -c%s "${OUTDIR}/qp${QP}.264" 2>/dev/null || echo "0")
    NOTE=""
    if [ "$QP" -le 4 ]; then NOTE="← low QP (never tested before)"; fi
    if [ "$QP" -ge 28 ]; then NOTE="← high QP (never tested before)"; fi
    if [ "$QP" -eq 0 ] || [ "$QP" -eq 51 ]; then NOTE="← EXTREME boundary"; fi
    printf "%-3d | %7s | %s\n" "$QP" "$SIZE" "$NOTE"
done

echo ""
echo "OK qp-sweep-gen: 52/52 streams generated at QP 0–51"
