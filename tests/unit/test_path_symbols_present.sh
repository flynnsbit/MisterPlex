#!/usr/bin/env bash
# Grep gate: w-path public symbols must remain in tree (merge-drop red twin).
# Parent 2026-08-03: clean merge silently dropped ddrStorageGeometryForContent etc.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
if [[ ! -f "$ROOT/host/libmisterplex/path_public_symbols.hpp" ]]; then
  echo "FAIL missing host/libmisterplex/path_public_symbols.hpp" >&2
  fail=1
else
  echo "ok: path_public_symbols.hpp file"
fi
need=(
  "ddrStorageGeometryForContent"
  "ddrFfmpegGeometryForPresent"
  "ddrFrameGeometryForFpgaPresent"
  "kPlex360pCodedWidth"
  "kPlex360pCodedHeight"
  "kPlxgQ5ByteOffset"
  "packPlxgQ5"
  "selectSourceAwarePmsRequest"
  "selectPlxgAspectCadence"
)
for s in "${need[@]}"; do
  if ! rg -q --fixed-strings "$s" "$ROOT/host/libmisterplex" "$ROOT/arm/misterplexd" 2>/dev/null; then
    echo "FAIL missing symbol/string: $s" >&2
    fail=1
  else
    echo "ok: $s"
  fi
done
# Must live in ddr_frame_layout (not only a stale comment elsewhere)
for s in ddrStorageGeometryForContent ddrFfmpegGeometryForPresent kPlex360pCodedWidth; do
  if ! rg -n --fixed-strings "$s" "$ROOT/host/libmisterplex/ddr_frame_layout.hpp" >/dev/null; then
    echo "FAIL $s not in ddr_frame_layout.hpp" >&2
    fail=1
  fi
done
if [[ "$fail" -ne 0 ]]; then
  echo "test_path_symbols_present: FAIL" >&2
  exit 1
fi
echo "test_path_symbols_present: PASS"
exit 0
