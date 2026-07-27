#!/usr/bin/env bash
# Ratchet: QP coverage must span the full 0–51 range.
# This test fails if the QP sweep infrastructure is missing or incomplete.
# It prevents the coverage window from silently narrowing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWEEP_TEST="${ROOT}/tests/unit/test_dequant_qp_sweep.py"
GEN_STREAMS="${ROOT}/tests/unit/gen_qp_sweep_streams.sh"

ERRORS=0

# 1. The QP sweep test must exist and be executable
if [ ! -f "$SWEEP_TEST" ]; then
    echo "FAIL qp-ratchet: QP sweep test missing: $SWEEP_TEST" >&2
    ERRORS=$((ERRORS + 1))
fi

# 2. The stream generator must exist
if [ ! -f "$GEN_STREAMS" ]; then
    echo "FAIL qp-ratchet: QP stream generator missing: $GEN_STREAMS" >&2
    ERRORS=$((ERRORS + 1))
fi

# 3. The Verilator testbench must exist
TB_CPP="${ROOT}/tests/rtl/h264_dequant_qp_sweep_tb.cpp"
TB_SV="${ROOT}/tests/rtl/h264_dequant_qp_sweep_tb_top.sv"
if [ ! -f "$TB_CPP" ] || [ ! -f "$TB_SV" ]; then
    echo "FAIL qp-ratchet: Verilator QP sweep testbench files missing" >&2
    ERRORS=$((ERRORS + 1))
fi

# 4. Run the Python sweep test
if [ -f "$SWEEP_TEST" ]; then
    if ! python3 "$SWEEP_TEST" 2>&1; then
        echo "FAIL qp-ratchet: Python QP sweep test failed" >&2
        ERRORS=$((ERRORS + 1))
    fi
fi

# 5. Verify the sweep test explicitly tests all 52 QPs
if [ -f "$SWEEP_TEST" ]; then
    if ! grep -q 'range(52)' "$SWEEP_TEST"; then
        echo "FAIL qp-ratchet: sweep test does not iterate over range(52)" >&2
        ERRORS=$((ERRORS + 1))
    fi
fi

if [ "$ERRORS" -gt 0 ]; then
    echo "FAIL qp-ratchet: $ERRORS error(s) — QP coverage has narrowed" >&2
    exit 1
fi

echo "OK qp-ratchet: QP 0–51 coverage verified, sweep infrastructure intact"
exit 0
