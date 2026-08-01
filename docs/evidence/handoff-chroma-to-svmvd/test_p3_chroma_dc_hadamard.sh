#!/usr/bin/env bash
# Minimal GREEN + one mutation twin for chroma DC Hadamard.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_VERILATOR="${ROOT}/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_chroma_dc_hadamard_inv.sv"
TB="$ROOT/tests/unit/rtl/p3_chroma_dc_hadamard_tb.sv"
CPP="$ROOT/tests/unit/test_p3_chroma_dc_hadamard_verilator.cpp"
BUILD="$ROOT/build/verilator/p3_chroma_dc_hadamard"
MUT_BUILD="$ROOT/build/verilator/p3_chroma_dc_hadamard_mut"

if ! "$RUN_VERILATOR" --version >/dev/null 2>&1; then
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" --top-module p3_chroma_dc_hadamard_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TB" "$RTL" "$CPP"
"$BUILD/Vp3_chroma_dc_hadamard_tb"
echo "OK chroma_dc_hadamard green"

# Mutation twin: flip >>7 to >>6 (scale error) — must go RED
rm -rf "$MUT_BUILD"
mkdir -p "$MUT_BUILD"
MUT_RTL="$MUT_BUILD/h264_chroma_dc_hadamard_inv_mut.sv"
sed 's/>>> 7;/>>> 6;/g' "$RTL" > "$MUT_RTL"
if grep -q '>>> 6;' "$MUT_RTL" && ! grep -q '>>> 7;' "$MUT_RTL"; then
  :
else
  echo "FAIL mutation did not land" >&2
  exit 1
fi
set +e
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$MUT_BUILD" --top-module p3_chroma_dc_hadamard_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TB" "$MUT_RTL" "$CPP" >/dev/null 2>&1
"$MUT_BUILD/Vp3_chroma_dc_hadamard_tb" >"$MUT_BUILD/mut_out.txt" 2>&1
MUT_RC=$?
set -e
if [[ "$MUT_RC" -eq 0 ]]; then
  echo "FAIL mutation twin stayed GREEN (expected RED)" >&2
  cat "$MUT_BUILD/mut_out.txt" >&2 || true
  exit 1
fi
echo "OK chroma_dc_hadamard mutation twin RED rc=$MUT_RC"
echo "OK test_p3_chroma_dc_hadamard"
