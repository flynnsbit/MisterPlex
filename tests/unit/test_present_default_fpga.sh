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

# Canonical machineId default (silent misterplex-1 broke casting once).
if ! grep -q 'std::string machineId = "misterplex-dev"' "$MAIN"; then
  echo "FAIL: main.cpp machineId default is not misterplex-dev" >&2
  grep -n 'machineId' "$MAIN" | head -10 >&2 || true
  exit 1
fi
if grep -nE 'machineId(_)? = "misterplex-1"' "$MAIN" \
  "$ROOT/arm/misterplexd/companion.hpp" >/dev/null; then
  echo "FAIL: residual machineId default misterplex-1" >&2
  exit 1
fi
grep -q 'std::string machineId_ = "misterplex-dev"' \
  "$ROOT/arm/misterplexd/companion.hpp" || {
  echo "FAIL: companion.hpp machineId_ default is not misterplex-dev" >&2
  exit 1
}
grep -q 'ERROR non-canonical --id=' "$MAIN" || {
  echo "FAIL: missing loud non-canonical --id log" >&2
  exit 1
}
echo "PASS machineId default misterplex-dev + non-canonical ERROR log"

# Deploy/package paths must not reintroduce silent wrong --id or bare conf.
PKG="$ROOT/scripts/package_release.sh"
DEP="$ROOT/scripts/deploy_misterplexd.sh"
if grep -nE -- '--id misterplex([^-a-zA-Z0-9_]|$)' "$PKG" >/dev/null; then
  echo "FAIL: package_release.sh still ships bare --id misterplex" >&2
  grep -nE -- '--id misterplex' "$PKG" >&2 || true
  exit 1
fi
grep -q -- '--id misterplex-dev' "$PKG" || {
  echo "FAIL: package_release.sh missing --id misterplex-dev" >&2
  exit 1
}
grep -q 'PRESENT=fpga' "$DEP" || {
  echo "FAIL: deploy_misterplexd.sh bootstrap missing PRESENT=fpga" >&2
  exit 1
}
grep -q 'machineIdentifier=' "$DEP" || {
  echo "FAIL: deploy_misterplexd.sh missing /resources machineIdentifier check" >&2
  exit 1
}
grep -q 'DAEMON_ID_MISMATCH' "$DEP" || {
  echo "FAIL: deploy_misterplexd.sh missing DAEMON_ID_MISMATCH hard-fail" >&2
  exit 1
}
# Red twin: bare --id misterplex in a copy must fail the package check above.
cp "$PKG" "$WORK/package_release.sh"
if ! grep -q -- '--id misterplex-dev' "$WORK/package_release.sh"; then
  echo "FAIL: fixture package missing misterplex-dev to mutate" >&2
  exit 1
fi
sed -i 's/--id misterplex-dev/--id misterplex/' "$WORK/package_release.sh"
set +e
grep -nE -- '--id misterplex([^-a-zA-Z0-9_]|$)' "$WORK/package_release.sh" >/dev/null
PKG_RED=$?
set -e
echo "package_id_red_twin detect true rc=$PKG_RED"
if [[ "$PKG_RED" -ne 0 ]]; then
  echo "FAIL: red twin did not detect injected --id misterplex" >&2
  exit 1
fi
echo "PASS package/deploy silent-default gates (id + PRESENT + resources check)"

# Deploy wrong-id path must hard-fail rc=7 (offline selftest; no SSH).
set +e
bash "$DEP" --selftest-id-gate >"$WORK/deploy_id_selftest.out" 2>"$WORK/deploy_id_selftest.err"
DEP_ST=$?
set -e
echo "deploy_selftest_id_gate true rc=$DEP_ST"
if [[ "$DEP_ST" -ne 7 ]]; then
  echo "FAIL: deploy --selftest-id-gate must exit 7 on wrong --id, got $DEP_ST" >&2
  cat "$WORK/deploy_id_selftest.out" "$WORK/deploy_id_selftest.err" >&2 || true
  exit 1
fi
grep -q 'DAEMON_ID_MISMATCH' "$WORK/deploy_id_selftest.err" || {
  echo "FAIL: selftest missing DAEMON_ID_MISMATCH" >&2
  cat "$WORK/deploy_id_selftest.err" >&2
  exit 1
}
echo "PASS deploy wrong-id selftest hard-fails rc=7"

echo "OK present default fpga + always-open FPGA idle path"
