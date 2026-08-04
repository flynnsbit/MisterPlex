#!/usr/bin/env bash
# Post-fit release scorecard for parent after exclusive Quartus fit.
# Soft-skip (77) is NOT a pass. Capture each true rc outside pipes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FIT_RPT="${FIT_RPT:-}"
STA_RPT="${STA_RPT:-}"
MAP_RPT="${MAP_RPT:-}"
COMPILE_LOG="${COMPILE_LOG:-}"
RBF="${RBF:-}"
OUT_DIR="${OUT_DIR:-$ROOT/build/post_fit_score}"
mkdir -p "$OUT_DIR"

echo "=== post_fit_release_score EXECUTED ==="
echo "ROOT=$ROOT"
echo "FIT_RPT=${FIT_RPT:-UNSET} STA_RPT=${STA_RPT:-UNSET} RBF=${RBF:-UNSET}"

fail=0
run() {
  local label="$1"; shift
  set +e
  "$@" >"$OUT_DIR/${label}.out" 2>"$OUT_DIR/${label}.err"
  local rc=$?
  set -e
  echo "${label} true rc=$rc"
  if [[ -s "$OUT_DIR/${label}.out" ]]; then tail -n 30 "$OUT_DIR/${label}.out"; fi
  if [[ -s "$OUT_DIR/${label}.err" ]]; then tail -n 20 "$OUT_DIR/${label}.err" >&2; fi
  if [[ "$rc" -ne 0 ]]; then fail=1; fi
  return 0
}

# 0) inputs present
[[ -n "$FIT_RPT" && -f "$FIT_RPT" ]] || { echo "FAIL need FIT_RPT= path to Plex.fit.rpt" >&2; exit 2; }
[[ -n "$STA_RPT" && -f "$STA_RPT" ]] || { echo "FAIL need STA_RPT= path to Plex.sta.rpt" >&2; exit 2; }

# 1) Prefit reachability (source tree that built the RBF)
run prefit python3 "$ROOT/scripts/check_prefit_reachability.py" --root "$ROOT"

# 2) Hierarchy — product critical present; build_id >=8 regs
HIER_ARGS=(--fit-rpt "$FIT_RPT")
[[ -n "${MAP_RPT:-}" && -f "$MAP_RPT" ]] && HIER_ARGS+=(--map-rpt "$MAP_RPT")
[[ -n "${COMPILE_LOG:-}" && -f "$COMPILE_LOG" ]] && HIER_ARGS+=(--log "$COMPILE_LOG")
run hier_product python3 "$ROOT/scripts/check_quartus_fit_hierarchy.py" \
  "${HIER_ARGS[@]}" --config "$ROOT/tests/fixtures/critical_fit_hierarchy.json"

# 2b) If QSF has PRODUCT_NO_STUB, also require decode_stub absent (0 resources)
if grep -qE '^[^#]*VERILOG_MACRO.*"PRODUCT_NO_STUB=1"' "$ROOT/fpga/Plex_MiSTer/Plex.qsf" 2>/dev/null; then
  echo "PRODUCT_NO_STUB=1 active — scoring decode_stub must_be_absent"
  run hier_nostub python3 "$ROOT/scripts/check_quartus_fit_hierarchy.py" \
    "${HIER_ARGS[@]}" --config "$ROOT/tests/fixtures/critical_fit_hierarchy_product_no_stub.json"
else
  echo "PRODUCT_NO_STUB inactive — skip decode_stub-absent hierarchy (not a pass claim)"
fi

# 3) Timing hard fail on negative slack
run timing python3 "$ROOT/scripts/check_quartus_timing.py" --sta-rpt "$STA_RPT"

# 4) Timing margin vs baseline (77 = SKIP-NOT-PASS, not green)
set +e
python3 "$ROOT/scripts/check_timing_margin.py" --sta-rpt "$STA_RPT" \
  >"$OUT_DIR/timing_margin.out" 2>"$OUT_DIR/timing_margin.err"
tm_rc=$?
set -e
echo "timing_margin true rc=$tm_rc"
tail -n 20 "$OUT_DIR/timing_margin.out" || true
if [[ "$tm_rc" -eq 77 ]]; then
  echo "timing_margin SKIP-NOT-PASS rc=77 — not scored as PASS"
elif [[ "$tm_rc" -ne 0 ]]; then
  fail=1
fi

# 5) Provenance bind if RBF present
if [[ -n "${RBF:-}" && -f "$RBF" ]]; then
  run prov_emit python3 "$ROOT/scripts/rbf_provenance.py" --root "$ROOT" emit --rbf "$RBF" --builder post_fit_score
  run prov_verify python3 "$ROOT/scripts/rbf_provenance.py" --root "$ROOT" verify --rbf "$RBF"
  MD5=$(md5sum "$RBF" | awk '{print $1}')
  echo "RBF_MD5=$MD5"
  run what_built python3 "$ROOT/scripts/rbf_provenance.py" --root "$ROOT" lookup --md5 "$MD5"
else
  echo "rbf_provenance SKIP-NOT-PASS (no RBF=) — not a provenance PASS"
fi

# 6) Explicit build_id / decode_stub greps from hierarchy table (belt+suspenders)
echo "=== explicit FIT_RPT greps ==="
set +e
grep -n 'plex_rbf_build_id' "$FIT_RPT" | head -20
grep -n 'decode_stub' "$FIT_RPT" | head -20
set -e

echo "=== SCORE SUMMARY ==="
if [[ "$fail" -ne 0 ]]; then
  echo "POST_FIT_SCORE FAIL — GRANT remains NO"
  echo "true rc=1"
  exit 1
fi
echo "POST_FIT_SCORE structural PASS (hierarchy+timing+prefit[+prov])"
echo "NOTE: this does NOT prove 720p24 delivery (ARM copy / DDR write / present BW)."
echo "true rc=0"
exit 0
