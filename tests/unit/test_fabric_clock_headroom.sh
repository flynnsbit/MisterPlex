#!/usr/bin/env bash
# Red-before-green: present no-bump + 720p24 decode wall arithmetic.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_fabric_clock_headroom.py"
CONTRACT="$ROOT/assets/fabric_clock_headroom_contract.json"
WORK="$ROOT/build/fabric-clock-headroom-gate"
rm -rf "$WORK"
mkdir -p "$WORK"
chmod +x "$GATE"

run_case() {
  local label="$1" want="$2"
  shift 2
  local out rc
  set +e
  out=$(python3 "$GATE" "$@" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out" | sed 's|^|  |'
  if [[ "$rc" -ne "$want" ]]; then
    echo "FAIL test_fabric_clock_headroom: $label rc=$rc want=$want" >&2
    exit 1
  fi
  echo "OK $label true rc=$rc"
}

echo "=== green ==="
run_case shipping 0 --root "$ROOT" --contract "$CONTRACT"
pass_out=$(python3 "$GATE" --root "$ROOT" --contract "$CONTRACT" 2>&1)
grep -q "PASS fabric_clock_headroom_contract" <<<"$pass_out" || exit 1
grep -q "VERDICT present_bump=False" <<<"$pass_out" || {
  echo "FAIL: present must not require clk_sys bump" >&2
  exit 1
}
grep -q "FAIL_WALL" <<<"$pass_out" || {
  echo "FAIL: decode paint class must remain FAIL_WALL" >&2
  exit 1
}

echo "=== red: claim present needs bump ==="
python3 - "$CONTRACT" "$WORK/bump.json" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1], encoding="utf-8").read())
d["present_verdict"]["clk_sys_bump_required_for_fabric_work"] = True
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(d, indent=2))
PY
run_case present_bump_lie 1 --root "$ROOT" --contract "$WORK/bump.json"

echo "=== red: claim PLL-only rescues decode ==="
python3 - "$CONTRACT" "$WORK/pll.json" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1], encoding="utf-8").read())
d["decode_720p24"]["verdict_pll_only_rescues_720p24_decode"] = True
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(d, indent=2))
PY
run_case pll_rescue_lie 1 --root "$ROOT" --contract "$WORK/pll.json"

echo "PASS test_fabric_clock_headroom"
