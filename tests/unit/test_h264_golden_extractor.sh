#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
mkdir -p build/p3_golden
IN="tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264"
REF="tests/fixtures/p3_host_recon/mb0_luma_v1.json"
OUT_A="build/p3_golden/mb0_a.json"
OUT_B="build/p3_golden/mb0_b.json"
./build/extract_h264_golden --input "$IN" --mb 0 --output "$OUT_A" --verify-mb0-reference "$REF"
./build/extract_h264_golden --input "$IN" --mb 0 --output "$OUT_B" --verify-mb0-reference "$REF"
cmp -s "$OUT_A" "$OUT_B"
grep -q '"format": "misterplex.p3.mb_golden.v1"' "$OUT_A"
grep -q '"first_residual_checksum8_hex": "0x14"' "$OUT_A"
grep -q '"first_recon_signature8_hex": "0x3b"' "$OUT_A"
echo "test_h264_golden_extractor: OK deterministic MB0 golden; ref csum=0x14 recon_sig=0x3b"
