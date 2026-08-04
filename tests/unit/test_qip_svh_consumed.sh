#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHK="$ROOT/scripts/check_qip_svh_consumed.py"
W="${ROOT}/Memory/lab/fitgate-qip-svh"
mkdir -p "$W"
echo "=== test_qip_svh_consumed EXECUTED ==="

set +e
python3 "$CHK" --self-test >"$W/self.out" 2>"$W/self.err"
s=$?
set -e
echo "self true rc=$s"
[[ "$s" -eq 0 ]]

set +e
python3 "$CHK" --root "$ROOT" >"$W/prod.out" 2>"$W/prod.err"
p=$?
set -e
echo "product true rc=$p"
tail -20 "$W/prod.out"
# Product tree today: no dead bw contract in QIP → expect 0
[[ "$p" -eq 0 ]] || { cat "$W/prod.err" >&2; exit "$p"; }
grep -q QIP_SVH_CONSUMED_EXECUTED "$W/prod.out"
grep -q 'R_req_MBps_per_dir_LOCKED=33.1776' "$W/prod.out"

# RED: temp tree with dead contract in QIP
mkdir -p "$W/fake/fpga/Plex_MiSTer/rtl"
echo 'localparam int X = 1;' >"$W/fake/fpga/Plex_MiSTer/rtl/plex_720p_bw_contract.svh"
echo 'module emu; endmodule' >"$W/fake/fpga/Plex_MiSTer/rtl/emu.sv"
echo 'set_global_assignment -name SYSTEMVERILOG_FILE rtl/plex_720p_bw_contract.svh' \
  >"$W/fake/fpga/Plex_MiSTer/files.qip"
echo 'set_global_assignment -name SYSTEMVERILOG_FILE rtl/emu.sv' \
  >>"$W/fake/fpga/Plex_MiSTer/files.qip"
set +e
python3 "$CHK" --root "$W/fake" >"$W/red.out" 2>"$W/red.err"
r=$?
set -e
echo "dead_contract true rc=$r"
cat "$W/red.err"
[[ "$r" -ne 0 ]] || { echo "FAIL dead QIP svh must RED" >&2; exit 1; }
grep -q 'DEAD_QIP_HEADER\|DEAD_CONTRACT' "$W/red.err"

# RED fixture: audit_ack implies rd-duck reader CLOSED + 38.53
mkdir -p "$W/fake2/fpga/Plex_MiSTer"
echo '' >"$W/fake2/fpga/Plex_MiSTer/files.qip"
mkdir -p "$W/fake2/tests/fixtures"
cat >"$W/fake2/tests/fixtures/p720_bw_contract.json" <<'JSON'
{
  "title": "reader CLOSED 38.53 MB/s (rd-duck)",
  "audit_ack": ["rd-duck"],
  "R_req": 33.1776,
  "notes": "audit_ack proves reader CLOSED at 38.53"
}
JSON
set +e
python3 "$CHK" --root "$W/fake2" >"$W/fix.out" 2>"$W/fix.err"
f=$?
set -e
echo "bad_fixture true rc=$f"
cat "$W/fix.err"
[[ "$f" -ne 0 ]] || { echo "FAIL bad p720 fixture must RED" >&2; exit 1; }

# land-mbw if present: expect dead contract warning or fail if in QIP
LAND=/home/flynnsbit/Projects/MisterPlex-wt-land-mbw
if [[ -d "$LAND/fpga/Plex_MiSTer" ]]; then
  set +e
  python3 "$CHK" --root "$LAND" >"$W/land.out" 2>"$W/land.err"
  l=$?
  set -e
  echo "land-mbw true rc=$l"
  tail -25 "$W/land.out"
  cat "$W/land.err" 2>/dev/null | head -10 || true
fi

echo "EXECUTED qip_svh_consumed product=0 dead_red=$r fixture_red=$f"
echo "true rc=0"
exit 0
