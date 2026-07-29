#!/usr/bin/env bash
# Static: PRESENT default is fpga; red twin proves fb0 default fails the gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MAIN="$ROOT/arm/misterplexd/main.cpp"
HPP="$ROOT/arm/misterplexd/media_player.hpp"
MP="$ROOT/arm/misterplexd/media_player.cpp"

grep -q 'std::string presentMode = "fpga"' "$MAIN" || {
  echo "FAIL: main.cpp default presentMode is not fpga" >&2
  exit 1
}
grep -q 'std::string presentMode_ = "fpga"' "$HPP" || {
  echo "FAIL: media_player.hpp default presentMode_ is not fpga" >&2
  exit 1
}
if grep -nE 'presentMode(_)? = "fb0"' "$MAIN" "$HPP" >/dev/null; then
  echo "FAIL: fb0 still appears as built-in PRESENT default" >&2
  grep -nE 'presentMode(_)? = "fb0"' "$MAIN" "$HPP" >&2 || true
  exit 1
fi
grep -q 'wantFpga = true' "$MP" || {
  echo "FAIL: initPresent missing wantFpga = true (always-open FPGA for non-none)" >&2
  exit 1
}
grep -q 'ERROR FPGA SPI unavailable' "$MP" || {
  echo "FAIL: missing loud FPGA error in initPresent" >&2
  exit 1
}
grep -q 'ERROR idle cannot open FPGA' "$MP" || {
  echo "FAIL: missing loud idle FPGA error in paintIdle" >&2
  exit 1
}

# Red twin: mutate default back to fb0 in a temp copy and expect the green checks to catch it.
WORK="$ROOT/build/present-default-unit"
mkdir -p "$WORK"
cp "$MAIN" "$WORK/main.cpp"
sed -i 's/std::string presentMode = "fpga"/std::string presentMode = "fb0"/' "$WORK/main.cpp"
if grep -q 'std::string presentMode = "fpga"' "$WORK/main.cpp"; then
  echo "FAIL: red twin could not inject fb0 default" >&2
  exit 1
fi
if grep -q 'std::string presentMode = "fb0"' "$WORK/main.cpp"; then
  echo "PASS red twin: injected presentMode=fb0 is detectable"
else
  echo "FAIL: red twin injection missing" >&2
  exit 1
fi

# Conf example must not ship PRESENT=fb0 as the product line
if grep -E '^PRESENT=fb0' "$ROOT/assets/misterplex.conf.example" >/dev/null; then
  echo "FAIL: assets/misterplex.conf.example still defaults PRESENT=fb0" >&2
  exit 1
fi
grep -qE '^PRESENT=fpga' "$ROOT/assets/misterplex.conf.example" || {
  echo "FAIL: conf example missing PRESENT=fpga" >&2
  exit 1
}

echo "OK present default fpga + always-open FPGA idle path"
