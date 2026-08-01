#!/usr/bin/env bash
# Red-before-green gate: fabric H.264 inventory vs fitted Plex.fit.rpt + phase3-decode.md
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${ROOT}/scripts/check_fabric_decode_inventory.py"
FIX="${ROOT}/tests/fixtures/fabric_decode_inventory.json"
EXCERPT="${ROOT}/tests/fixtures/fabric_decode_fit_hierarchy_8fdf440f.excerpt.rpt"
DOC="${ROOT}/docs/phase3-decode.md"
WORK="${ROOT}/.agent-work/w-fit-1/fabric-inv-gate-$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

run() {
  # shellcheck disable=SC2086
  python3 "$PY" "$@"
  return $?
}

echo "=== A) GREEN: excerpt fit.rpt matches fixture + doc ==="
run --fit-rpt "$EXCERPT" --fixture "$FIX" --doc "$DOC" --require-doc
echo "green true rc=$?"

echo "=== B) RED: claim CAVLC present (must_absent violation) ==="
python3 - <<PY
import json
from pathlib import Path
fix = json.loads(Path("$FIX").read_text())
# Force a present row for an entity that must be absent — inject fake expect by
# removing it from must_absent and adding to must_present with nonsense ALMs.
fix["must_absent"] = [e for e in fix["must_absent"] if e != "h264_cavlc_residual_block"]
fix["must_present"].append({
    "entity": "h264_cavlc_residual_block",
    "hierarchy_contains": "",
    "alm": 999.0,
    "alm_tol": 0.1,
})
Path("$WORK/fix_cavlc.json").write_text(json.dumps(fix))
PY
set +e
run --fit-rpt "$EXCERPT" --fixture "$WORK/fix_cavlc.json" --skip-totals >"$WORK/red_cavlc.out" 2>"$WORK/red_cavlc.err"
rc=$?
set -e
echo "red_cavlc true rc=$rc"
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected RED when CAVLC claimed present/missing" >&2
  cat "$WORK/red_cavlc.err" >&2
  exit 1
fi
if ! grep -q "must_present missing entity=h264_cavlc_residual_block" "$WORK/red_cavlc.err"; then
  echo "FAIL: red path did not name missing CAVLC entity" >&2
  cat "$WORK/red_cavlc.err" >&2
  exit 1
fi
echo "REPRO_OK cavlc-claimed-present → missing entity fail"

echo "=== C) RED: wrong ALM on decode_stub ==="
python3 - <<PY
import json
from pathlib import Path
fix = json.loads(Path("$FIX").read_text())
for m in fix["must_present"]:
    if m["entity"] == "decode_stub":
        m["alm"] = 1.0
        m["alm_tol"] = 0.1
Path("$WORK/fix_alm.json").write_text(json.dumps(fix))
PY
set +e
run --fit-rpt "$EXCERPT" --fixture "$WORK/fix_alm.json" --skip-totals >"$WORK/red_alm.out" 2>"$WORK/red_alm.err"
rc=$?
set -e
echo "red_alm true rc=$rc"
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected RED on ALM mismatch" >&2
  exit 1
fi
if ! grep -q "decode_stub: ALMs" "$WORK/red_alm.err"; then
  echo "FAIL: red path did not name decode_stub ALM mismatch" >&2
  cat "$WORK/red_alm.err" >&2
  exit 1
fi
echo "REPRO_OK decode_stub ALM drift → fail"

echo "=== D) RED: doc inventory PRESENT rows disagree ==="
# Corrupt only the marked table block's decode_stub ALM
python3 - <<PY
from pathlib import Path
doc = Path("$DOC").read_text()
begin = "<!-- FABRIC_DECODE_INVENTORY_BEGIN -->"
end = "<!-- FABRIC_DECODE_INVENTORY_END -->"
if begin not in doc or end not in doc:
    raise SystemExit("doc markers missing — cannot run doc-red arm")
pre, rest = doc.split(begin, 1)
mid, post = rest.split(end, 1)
mid2 = mid.replace("| \`decode_stub\` | 9216.9 | PRESENT |", "| \`decode_stub\` | 1.0 | PRESENT |", 1)
if mid2 == mid:
    raise SystemExit("could not corrupt decode_stub row in doc block")
Path("$WORK/doc_bad.md").write_text(pre + begin + mid2 + end + post)
PY
set +e
run --fit-rpt "$EXCERPT" --fixture "$FIX" --doc "$WORK/doc_bad.md" --require-doc \
  >"$WORK/red_doc.out" 2>"$WORK/red_doc.err"
rc=$?
set -e
echo "red_doc true rc=$rc"
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected RED when doc table disagrees with fit" >&2
  exit 1
fi
if ! grep -q "doc inventory PRESENT rows disagree" "$WORK/red_doc.err"; then
  echo "FAIL: red path did not report doc/fit disagree" >&2
  cat "$WORK/red_doc.err" >&2
  exit 1
fi
echo "REPRO_OK doc/fit disagree → fail"

echo "=== E) RED: missing fit report → rc=4 ==="
set +e
run --fit-rpt "$WORK/no_such.rpt" --fixture "$FIX" >"$WORK/red_miss.out" 2>"$WORK/red_miss.err"
rc=$?
set -e
echo "red_missing true rc=$rc"
if [[ "$rc" -ne 4 ]]; then
  echo "FAIL: expected rc=4 for missing fit rpt, got $rc" >&2
  exit 1
fi
echo "REPRO_OK missing fit rpt → rc=4"

echo "OK fabric_decode_inventory: GREEN excerpt+doc + RED cavlc/ALM/doc/missing (TB executed)"
exit 0
