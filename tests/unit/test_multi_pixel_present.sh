#!/usr/bin/env bash
# Red-before-green for scripts/check_multi_pixel_present.py
# No Quartus fit. No device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_multi_pixel_present.py"
CONTRACT="$ROOT/assets/multi_pixel_present_contract.json"
WORK="$ROOT/build/multi-pixel-present-gate"

rm -rf "$WORK"
mkdir -p "$WORK"
chmod +x "$GATE"

run_case() {
  local label="$1" want_rc="$2"
  shift 2
  local out rc
  set +e
  out=$(python3 "$GATE" "$@" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out" | sed "s|^|  |"
  if [[ "$rc" -ne "$want_rc" ]]; then
    echo "FAIL test_multi_pixel_present: $label rc=$rc want=$want_rc" >&2
    exit 1
  fi
  echo "OK $label rc=$rc"
}

echo "=== green: shipping contract arithmetic + RTL present, macro OFF ==="
run_case "shipping_pass" 0 --root "$ROOT" --contract "$CONTRACT" --require-rtl
pass_out=$(python3 "$GATE" --root "$ROOT" --contract "$CONTRACT" --require-rtl 2>&1)
grep -q "PASS multi_pixel_present_contract" <<<"$pass_out" || {
  echo "FAIL: must print PASS multi_pixel_present_contract" >&2
  exit 1
}
grep -q "VERDICT cea_720p60_ppc2_nostub=FAIL" <<<"$pass_out" || {
  echo "FAIL: must state CEA720p60 @2ppc fails nostub" >&2
  exit 1
}
grep -q "VERDICT content_720p24_ppc2_ship20=OK" <<<"$pass_out" || {
  echo "FAIL: must state 720p24 @2ppc OK on ship 20" >&2
  exit 1
}

echo "=== red: corrupt expected need (arith mismatch) ==="
python3 - "$CONTRACT" "$WORK/bad.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.loads(open(src, encoding="utf-8").read())
d["expected_need_mhz"]["content_720p24"]["2"] = 99.0
open(dst, "w", encoding="utf-8").write(json.dumps(d, indent=2))
PY
run_case "arith_mismatch" 1 --root "$ROOT" --contract "$WORK/bad.json"

echo "=== red: wrong verdict table (self-weaken attempt) ==="
python3 - "$CONTRACT" "$WORK/weak.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.loads(open(src, encoding="utf-8").read())
d["verdicts_vs_fmax"]["cea_720p60_ppc2_nostub"] = "OK"
open(dst, "w", encoding="utf-8").write(json.dumps(d, indent=2))
PY
run_case "verdict_self_weaken" 1 --root "$ROOT" --contract "$WORK/weak.json"

echo "=== red: missing RTL module ==="
python3 - "$CONTRACT" "$WORK/nortl.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.loads(open(src, encoding="utf-8").read())
d["rtl"]["modules"] = ["fpga/Plex_MiSTer/rtl/does_not_exist_ppc.sv"]
open(dst, "w", encoding="utf-8").write(json.dumps(d, indent=2))
PY
run_case "missing_rtl" 1 --root "$ROOT" --contract "$WORK/nortl.json" --require-rtl

echo "PASS test_multi_pixel_present"
