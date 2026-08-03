#!/usr/bin/env bash
# Elision guard for plex_chrome list RAM — red-before-green on c74c6863 evidence.
# Parent rule: a fit whose chrome cannot render is worse than no fit.
# true rc= captured DIRECTLY (never through a pipe).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHK="$ROOT/scripts/check_plex_chrome_elision.py"
RED_FIT="$ROOT/tests/fixtures/plex_chrome_elided_c74c6863.fit.excerpt.rpt"
RED_MAP="$ROOT/tests/fixtures/plex_chrome_elided_c74c6863.map.excerpt.rpt"
GREEN_FIT="$ROOT/tests/fixtures/plex_chrome_ram_present.fit.excerpt.rpt"
LIVE_FIT="$ROOT/fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.fit.rpt"
LIVE_MAP="$ROOT/fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.map.rpt"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -x "$CHK" || -f "$CHK" ]] || fail "missing $CHK"
[[ -f "$RED_FIT" && -f "$RED_MAP" && -f "$GREEN_FIT" ]] || fail "missing fixtures"
chmod +x "$CHK" 2>/dev/null || true

echo "=== RED-A: c74c6863 fit excerpt (entity present, RAM 0/0) ==="
set +e
python3 "$CHK" --fit-rpt "$RED_FIT"
rc=$?
set -e
echo "true rc=$rc"
[[ "$rc" -eq 1 ]] || fail "RED-A expected rc=1 got $rc"

echo "=== RED-B: c74c6863 fit+map excerpt (stuck list_a) ==="
set +e
python3 "$CHK" --fit-rpt "$RED_FIT" --map-rpt "$RED_MAP"
rc=$?
set -e
echo "true rc=$rc"
[[ "$rc" -eq 1 ]] || fail "RED-B expected rc=1 got $rc"

echo "=== GREEN: synthetic dual-list M10K retained ==="
set +e
python3 "$CHK" --fit-rpt "$GREEN_FIT"
rc=$?
set -e
echo "true rc=$rc"
[[ "$rc" -eq 0 ]] || fail "GREEN expected rc=0 got $rc"

echo "=== RED-C: mutate green block bits/M10K to 0 (fixture file untouched) ==="
WORKDIR="$ROOT/.agent-work/w-fit-1"
mkdir -p "$WORKDIR"
tmp="$WORKDIR/chrome_elision_mut.rpt"
cp "$GREEN_FIT" "$tmp"
# Force elision numbers in the chrome data row only
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text().splitlines()
out = []
for l in lines:
    if "plex_chrome:u_plex_chrome" in l and "Compilation Hierarchy" not in l:
        l = l.replace("8192 (8192)", "0 (0)").replace("2 (2)", "0 (0)")
    out.append(l)
p.write_text("\n".join(out) + "\n")
PY
set +e
python3 "$CHK" --fit-rpt "$tmp"
rc=$?
set -e
echo "true rc=$rc"
[[ "$rc" -eq 1 ]] || fail "RED-C expected rc=1 got $rc"
rm -f "$tmp"

# green fixture must still pass after mutation on a copy
set +e
python3 "$CHK" --fit-rpt "$GREEN_FIT"
rc=$?
set -e
echo "true rc=$rc (green fixture intact)"
[[ "$rc" -eq 0 ]] || fail "green fixture damaged"

echo "=== RED-D (optional live): full c74c6863 remote_out if present ==="
if [[ -f "$LIVE_FIT" ]]; then
  set +e
  python3 "$CHK" --fit-rpt "$LIVE_FIT" ${LIVE_MAP:+--map-rpt "$LIVE_MAP"}
  rc=$?
  set -e
  echo "true rc=$rc"
  [[ "$rc" -eq 1 ]] || fail "LIVE c74c6863 expected rc=1 got $rc"
else
  echo "SKIP live remote_out (not in tree) — fixtures cover red-before-green"
fi

echo "PASS test_plex_chrome_elision_guard: red-before-green proven"
exit 0
