#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/build/decode-throughput-unit"
mkdir -p "$WORK"

COMPARE="$WORK/compare_624.json"
RATCHET="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_624x480_decode_throughput_v1.json"
REPORT="$WORK/report_624.json"
RED_RATCHET="$WORK/red_ratchet.json"

cat >"$COMPARE" <<'JSON'
{
  "format": "misterplex.p3.frame_planes_compare.v1",
  "source": {
    "path": "tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264",
    "bytes": 70348,
    "sha256": "9b79749478f331d6e523a548a88fbad38d1719beb6a2623b289e4e0190bf17a9"
  },
  "geometry": {
    "width": 624,
    "height": 480,
    "colorspace": "I420_FROM_RGB565",
    "planes": [
      {"plane": "Y", "width": 624, "height": 480},
      {"plane": "U", "width": 312, "height": 240},
      {"plane": "V", "width": 312, "height": 240}
    ]
  },
  "summary": {
    "nals": 15,
    "idr": 1,
    "p": 11,
    "cycles": 3641853,
    "first_bad_frame": 0,
    "first_bad": null,
    "strict_pass": false,
    "expectation": "red"
  },
  "frames": [{}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}]
}
JSON

"$ROOT/tools/check_decode_throughput.py" \
  --compare-json "$COMPARE" --ratchet "$RATCHET" \
  --label unit-624x480 --report "$REPORT"
python3 - "$REPORT" <<'PY'
import json
import sys

r = json.load(open(sys.argv[1]))
assert r["run"]["label"] == "unit-624x480", r
assert r["source"]["sha256"] == "9b79749478f331d6e523a548a88fbad38d1719beb6a2623b289e4e0190bf17a9", r
assert r["geometry"]["mbs_per_frame"] == 1170, r
assert r["target"]["stream_path_clock_hz"] == 20_000_000, r
assert abs(r["measured"]["cycles_per_mb"] - 259.3912393162) < 1e-6, r
assert abs(r["budget"]["cycles_per_mb"] - 683.7606837607) < 1e-6, r
assert r["budget"]["margin_ratio"] > 2.6, r
assert any(s["status"] == "unknown" for s in r["stage_coverage"]), r
PY

python3 - "$RATCHET" "$RED_RATCHET" <<'PY'
import json
import sys

r = json.load(open(sys.argv[1]))
r["thresholds"]["max_cycles_total"] = 3_000_000
r["thresholds"]["max_cycles_per_frame"] = 250_000.0
r["thresholds"]["max_cycles_per_mb"] = 220.0
r["thresholds"]["min_budget_margin_ratio"] = 3.0
json.dump(r, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY

set +e
RED_OUT="$("$ROOT/tools/check_decode_throughput.py" \
  --compare-json "$COMPARE" --ratchet "$RED_RATCHET" 2>&1)"
RED_RC=$?
set -e
if [[ "$RED_RC" -eq 0 ]]; then
  printf '%s\n' "$RED_OUT"
  echo "FAIL decode throughput red proof: regressed ratchet unexpectedly passed" >&2
  exit 1
fi
grep -q "cycles_total 3641853 > ratchet 3000000" <<<"$RED_OUT"
grep -q "budget margin 2.636 < required 3.000" <<<"$RED_OUT"
echo "RED OK decode throughput ratchet rejects cycle and margin regressions"
echo "PASS decode throughput gate"
