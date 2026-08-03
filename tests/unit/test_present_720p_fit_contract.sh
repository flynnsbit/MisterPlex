#!/usr/bin/env bash
# Red-before-green: present 720p fit-survival contract (no Quartus, no device).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_present_720p_fit_contract.py"
CONTRACT="$ROOT/assets/present_720p_fit_contract.json"
WORK="$ROOT/build/present-720p-fit-gate"
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
    echo "FAIL test_present_720p_fit_contract: $label rc=$rc want=$want" >&2
    exit 1
  fi
  echo "OK $label rc=$rc"
}

echo "=== green ==="
run_case shipping 0 --root "$ROOT" --contract "$CONTRACT"
pass_out=$(python3 "$GATE" --root "$ROOT" --contract "$CONTRACT" 2>&1)
grep -q "PASS present_720p_fit_contract" <<<"$pass_out" || {
  echo "FAIL: missing PASS line" >&2
  exit 1
}
grep -q "VERDICT cea60_ppc2=FAIL" <<<"$pass_out" || {
  echo "FAIL: must keep cea60@2ppc FAIL" >&2
  exit 1
}
grep -q "same_clk_out=FAIL_NEED_CLK_PIX" <<<"$pass_out" || {
  echo "FAIL: must not claim same-clock 74 MHz out" >&2
  exit 1
}

echo "=== red: strip async_fifo false_path from SDC copy ==="
python3 - "$ROOT/fpga/Plex_MiSTer/Plex.sdc" "$WORK/bad.sdc" "$CONTRACT" "$WORK/bad.json" <<'PY'
from pathlib import Path
import json, sys
sdc_src, sdc_dst, cj, jdst = sys.argv[1:5]
text = Path(sdc_src).read_text(encoding="utf-8")
# Comment out false_path block
lines = []
skip = 0
for line in text.splitlines(True):
    if "set_false_path" in line and "async_fifo" in text[text.find(line):text.find(line)+200]:
        lines.append("# RED " + line)
        skip = 2
        continue
    if skip:
        lines.append("# RED " + line)
        skip -= 1
        continue
    lines.append(line)
# Simpler: remove mem marker
out = "".join(lines).replace("async_fifo*mem", "REMOVED_mem").replace(
    "async_fifo*rd_data_r", "REMOVED_rd"
)
Path(sdc_dst).write_text(out)
d = json.loads(Path(cj).read_text(encoding="utf-8"))
d["sdc"]["plex_sdc"] = str(Path(sdc_dst).relative_to(Path(cj).resolve().parents[1])) if False else sdc_dst
# Use absolute via rewriting to path under WORK relative to root — point contract at bad sdc basename
d["sdc"]["plex_sdc"] = "build/present-720p-fit-gate/bad.sdc"
Path(jdst).write_text(json.dumps(d, indent=2))
PY
run_case sdc_stripped 1 --root "$ROOT" --contract "$WORK/bad.json"

echo "=== red: self-weaken cea60 ppc2 verdict ==="
python3 - "$CONTRACT" "$WORK/weak.json" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1], encoding="utf-8").read())
d["rates_mhz"]["verdict_cea60_ppc2_vs_nostub"] = "OK"
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(d, indent=2))
PY
run_case verdict_weaken 1 --root "$ROOT" --contract "$WORK/weak.json"

echo "PASS test_present_720p_fit_contract"
