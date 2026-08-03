#!/usr/bin/env bash
# Red/green gate for clk_pix separate-PLL plan (no device, no fit).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHK="$ROOT/scripts/check_clk_pix_pll_plan.py"
CONTRACT="$ROOT/assets/clk_pix_pll_plan_contract.json"
TMPDIR_LOCAL="$ROOT/.agent-work/w-clock/_gate_tmp_clk_pix"
mkdir -p "$TMPDIR_LOCAL"

echo "=== green ==="
python3 "$CHK" --root "$ROOT"; echo "OK shipping true rc=$?"

echo "=== red: claim PIX24 works at PPC=1 ==="
python3 - "$CONTRACT" "$TMPDIR_LOCAL/bad_ppc.json" <<'PY'
import json, sys
from pathlib import Path
c = json.loads(Path(sys.argv[1]).read_text())
c["targets"]["PIX24"]["min_ppc"] = 1
c["targets"]["PIX24"]["peak_fabric_mpix_at_min_ppc"] = 20.0
Path(sys.argv[2]).write_text(json.dumps(c))
PY
set +e
python3 "$CHK" --root "$ROOT" --contract "$TMPDIR_LOCAL/bad_ppc.json"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then echo "FAIL expected rc!=0 for ppc1 lie"; exit 1; fi
echo "OK ppc1_lie true rc=$rc"

echo "=== red: allow clk_sys bump for scanout ==="
python3 - "$CONTRACT" "$TMPDIR_LOCAL/bad_bump.json" <<'PY'
import json, sys
from pathlib import Path
c = json.loads(Path(sys.argv[1]).read_text())
c["forbidden"]["clk_sys_bump_for_scanout"] = False
Path(sys.argv[2]).write_text(json.dumps(c))
PY
set +e
python3 "$CHK" --root "$ROOT" --contract "$TMPDIR_LOCAL/bad_bump.json"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then echo "FAIL expected rc!=0 for sys-bump allow"; exit 1; fi
echo "OK sys_bump_lie true rc=$rc"

rm -rf "$TMPDIR_LOCAL"
echo "PASS test_clk_pix_pll_plan"
exit 0
