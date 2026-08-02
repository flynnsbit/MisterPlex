#!/usr/bin/env bash
# N>=6 same-session HDMI windows + glass cadence. PARENT runs. No cast/deploy.
#
# Env:
#   OUT N DURATION MARKER_PERIOD_S MIN_PAIRS GAP_S TIER DECODE_GEOM LABEL_PREFIX
#   REQUIRE_STABLE_EPOCH=1 (default) — mid-window respawn → rc=79 skip row
# Exit: 0 if >=MIN_SCORED windows written; 77 if too few scored; last soak rc otherwise
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/avsync_hdmi_out/multiwindow}"
N="${N:-6}"
DUR="${DURATION:-45}"
GAP_S="${GAP_S:-15}"
MARKER_PERIOD_S="${MARKER_PERIOD_S:-2.0}"
MIN_PAIRS="${MIN_PAIRS:-15}"
TIER="${TIER:-480p}"
DECODE_GEOM="${DECODE_GEOM:-624x480}"
PREFIX="${LABEL_PREFIX:-w}"
MIN_SCORED="${MIN_SCORED:-6}"
REQUIRE_STABLE_EPOCH="${REQUIRE_STABLE_EPOCH:-1}"
mkdir -p "$OUT"

echo "=== avsync_multiwindow ==="
echo "N=$N duration_s=$DUR gap_s=$GAP_S min_scored=$MIN_SCORED src=caller_supplied"
echo "tier=$TIER decode_geom=$DECODE_GEOM src=caller_supplied"
echo "=== PRE-REGISTER ==="
echo "P_RATE: report fraction timing_class=WANDER among scored windows (no rate claim if n_scored<6)"
echo "P_CADENCE: WANDER windows show higher n_interval_outliers OR NOT — publish either way"
echo "P_SNR: residual F-test STABLE vs WANDER pools if both nonempty"
echo "predictions_src=caller_supplied_pre_register"

SUMMARY="$OUT/multiwindow_summary.csv"
echo "label,soak_rc,timing_class,residual_rms_ms,detrended_max_abs_ms,excess_wander_rms_ms,n_pairs,session_epoch,interval_p50,interval_p99,interval_max,n_interval_outliers,est_missed_markers" >"$SUMMARY"

scored=0
last_rc=0
for i in $(seq 1 "$N"); do
  lab="${PREFIX}${i}"
  wout="$OUT/$lab"
  mkdir -p "$wout"
  echo "=== WINDOW $i/$N label=$lab ==="
  set +e
  TIER="$TIER" DECODE_GEOM="$DECODE_GEOM" LABEL="$lab" OUT="$wout" \
    DURATION="$DUR" MARKER_PERIOD_S="$MARKER_PERIOD_S" MIN_PAIRS="$MIN_PAIRS" \
    bash "$ROOT/tools/avsync_wander_rca.sh" >"$wout/wrap.txt" 2>&1
  rc=$?
  set -e
  echo "window_$lab true rc=$rc"
  last_rc=$rc
  if [[ "$rc" -eq 79 ]]; then
    echo "INVALID_SESSION_RESPAWN — row not scored; recast fixture before continuing"
    echo "$lab,79,INVALID,,,,,,,,,," >>"$SUMMARY"
    # do not sleep-gap forever on death loops
    continue
  fi

  # cadence from timeseries (pairs) and report if present
  ts=$(ls "$wout"/*_offset_timeseries.csv 2>/dev/null | head -1 || true)
  rep=$(ls "$wout"/*_report.json 2>/dev/null | head -1 || true)
  flash=$(ls "$wout"/*_flash_onsets.csv 2>/dev/null | head -1 || true)
  set +e
  if [[ -n "$flash" ]]; then
    python3 "$ROOT/tools/avsync_glass_cadence.py" \
      --flash-csv "$flash" --marker-period-s "$MARKER_PERIOD_S" \
      --label "$lab" --json-out "$wout/cadence.json" \
      ${ts:+--timeseries "$ts"} \
      >"$wout/cadence.txt" 2>&1
  elif [[ -n "$rep" ]]; then
    python3 "$ROOT/tools/avsync_glass_cadence.py" \
      --report "$rep" --marker-period-s "$MARKER_PERIOD_S" \
      --label "$lab" --json-out "$wout/cadence.json" \
      >"$wout/cadence.txt" 2>&1
  elif [[ -n "$ts" ]]; then
    python3 "$ROOT/tools/avsync_glass_cadence.py" \
      --timeseries "$ts" --marker-period-s "$MARKER_PERIOD_S" \
      --label "$lab" --json-out "$wout/cadence.json" \
      >"$wout/cadence.txt" 2>&1
  else
    echo "cadence=NO-DATA" >"$wout/cadence.txt"
  fi
  set -e

  python3 - "$wout" "$lab" "$rc" "$SUMMARY" <<'PY'
import json, re, sys
from pathlib import Path
wout, lab, rc, summary = sys.argv[1:5]
w = Path(wout)
text = ""
for p in w.glob("*_stdout.txt"):
    text += p.read_text(errors="replace")
text += (w / "wrap.txt").read_text(errors="replace") if (w / "wrap.txt").is_file() else ""
def g(pat, cast=float):
    m = re.search(pat, text, re.M)
    if not m: return ""
    try: return cast(m.group(1))
    except Exception: return m.group(1)
tc = g(r"timing_class=([A-Z_]+)", str) or ""
residual = g(r"residual_rms_ms=([-\d.eE]+)")
det = g(r"detrended_max_abs_ms=([-\d.eE]+)")
ex = g(r"excess_wander_rms_ms=([-\d.eE]+)")
npairs = g(r"^n_pairs=(\d+)", int)
epoch = g(r"session_epoch_before=([-\d.]+)", str) or g(r"session_epoch=([-\d.]+)", str)
cad = {}
cj = w / "cadence.json"
if cj.is_file():
    cad = json.loads(cj.read_text()).get("inter_flash") or {}
row = [
    lab, rc, tc, residual, det, ex, npairs, epoch,
    cad.get("interval_ms_p50", ""),
    cad.get("interval_ms_p99", ""),
    cad.get("interval_ms_max", ""),
    cad.get("n_interval_outliers", ""),
    cad.get("est_missed_markers", ""),
]
with open(summary, "a") as f:
    f.write(",".join(str(x) for x in row) + "\n")
print("summary_row", row)
PY
  scored=$((scored + 1))
  if [[ "$i" -lt "$N" ]]; then
    sleep "$GAP_S"
  fi
done

echo "=== SUMMARY csv=$SUMMARY scored_attempts=$scored ==="
cat "$SUMMARY"

# Pool F-test if we have STABLE and WANDER timeseries
ST_TS=$(SUMMARY="$SUMMARY" OUT="$OUT" python3 - <<'PY'
import csv, glob, os
rows = list(csv.DictReader(open(os.environ["SUMMARY"])))
out = os.environ["OUT"]
for r in rows:
    if r.get("timing_class") == "STABLE" and str(r.get("soak_rc")) != "79":
        g = glob.glob(f"{out}/{r['label']}/*_offset_timeseries.csv")
        if g:
            print(g[0])
            break
print(f"n_stable_rows={sum(1 for r in rows if r.get('timing_class')=='STABLE')}", file=__import__('sys').stderr)
print(f"n_wander_rows={sum(1 for r in rows if r.get('timing_class')=='WANDER')}", file=__import__('sys').stderr)
PY
)
W_TS=$(SUMMARY="$SUMMARY" OUT="$OUT" python3 - <<'PY'
import csv, glob, os
rows = list(csv.DictReader(open(os.environ["SUMMARY"])))
out = os.environ["OUT"]
for r in rows:
    if r.get("timing_class") == "WANDER":
        g = glob.glob(f"{out}/{r['label']}/*_offset_timeseries.csv")
        if g:
            print(g[0])
            break
PY
)
if [[ -n "${ST_TS:-}" && -n "${W_TS:-}" ]]; then
  echo "=== POOL residual F-test STABLE vs WANDER example windows ==="
  python3 "$ROOT/tools/avsync_glass_cadence.py" \
    --timeseries "$ST_TS" --compare-timeseries "$W_TS" \
    --marker-period-s "$MARKER_PERIOD_S" --label STABLE --label-b WANDER \
    | tee "$OUT/pool_f_test.txt"
else
  echo "pool_f_test=NO-DATA need_both_STABLE_and_WANDER_timeseries src=measured"
fi

n_ok=$(awk -F, 'NR>1 && $2!=79 {c++} END{print c+0}' "$SUMMARY")
echo "n_scored_windows=$n_ok min_scored=$MIN_SCORED src=measured"
if [[ "$n_ok" -lt "$MIN_SCORED" ]]; then
  echo "VERDICT=UNSCORED rc=77 reason=fewer_than_min_scored_windows"
  exit 77
fi
echo "VERDICT=MULTIWINDOW_COMPLETE rc=0 n_scored=$n_ok"
exit 0
