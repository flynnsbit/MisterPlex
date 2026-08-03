#!/usr/bin/env bash
# Static: PRESENT default is fpga; red twin runs the real green checks on a
# mutated fb0 copy and requires them to FAIL (not merely "mutation detectable").
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MAIN="$ROOT/arm/misterplexd/main.cpp"
HPP="$ROOT/arm/misterplexd/media_player.hpp"
MP="$ROOT/arm/misterplexd/media_player.cpp"
WORK="$ROOT/build/present-default-unit"
mkdir -p "$WORK"

green_checks() {
  local main="$1" hpp="$2" mp="$3"
  grep -q 'std::string presentMode = "fpga"' "$main" || return 1
  grep -q 'std::string presentMode_ = "fpga"' "$hpp" || return 1
  if grep -nE 'presentMode(_)? = "fb0"' "$main" "$hpp" >/dev/null; then
    return 1
  fi
  grep -q 'wantFpga = true' "$mp" || return 1
  grep -q 'ERROR FPGA SPI unavailable' "$mp" || return 1
  grep -q 'ERROR idle cannot open FPGA' "$mp" || return 1
  if grep -E '^PRESENT=fb0' "$ROOT/assets/misterplex.conf.example" >/dev/null; then
    return 1
  fi
  grep -qE '^PRESENT=fpga' "$ROOT/assets/misterplex.conf.example" || return 1
  return 0
}

if ! green_checks "$MAIN" "$HPP" "$MP"; then
  echo "FAIL: green PRESENT=fpga / always-open FPGA checks failed on tip sources" >&2
  exit 1
fi
echo "PASS green present default fpga checks on tip"

# RED TWIN: inject fb0 default into a temp main.cpp and require green_checks to FAIL.
cp "$MAIN" "$WORK/main.cpp"
cp "$HPP" "$WORK/media_player.hpp"
cp "$MP" "$WORK/media_player.cpp"
sed -i 's/std::string presentMode = "fpga"/std::string presentMode = "fb0"/' "$WORK/main.cpp"
if grep -q 'std::string presentMode = "fpga"' "$WORK/main.cpp"; then
  echo "FAIL: red twin could not inject fb0 default" >&2
  exit 1
fi
set +e
green_checks "$WORK/main.cpp" "$WORK/media_player.hpp" "$WORK/media_player.cpp"
RED_RC=$?
set -e
echo "present_default_red_twin true rc=$RED_RC"
if [[ "$RED_RC" -eq 0 ]]; then
  echo "FAIL: red twin — green_checks still passed after presentMode=fb0 inject (vacuous)" >&2
  exit 1
fi
echo "PASS red twin: green_checks fail on injected presentMode=fb0 (rc=$RED_RC)"

echo "OK present default fpga + always-open FPGA idle path"
