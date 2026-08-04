#!/usr/bin/env bash
# test_avsync_ramp_onset.sh — prove ramped-flash fixture forces linear-interp onset
#
# Host-only. Does NOT touch the device.
#
# RED (step blip, assets/avsync/sync_24fps_blip.mp4):
#   flash_onset_n_interp == 0  (all onsets take step path; capture-frame quant)
# GREEN (gen_avsync_ramp_soak.py short clip):
#   flash_onset_n_interp == n_flashes  (and n_step == 0)
#
# Exit codes captured DIRECTLY (never through a pipe). rc=77 is never treated as pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$ROOT/tools/avsync_measure_hdmi.py"
GEN="$ROOT/scripts/gen_avsync_ramp_soak.py"
STEP_FIX="$ROOT/assets/avsync/sync_24fps_blip.mp4"
OUT="$ROOT/build/avsync_ramp_onset"
DUR=12

mkdir -p "$OUT"
rm -rf "${OUT:?}/"*
mkdir -p "$OUT"

fail=0
pass=0

if [[ ! -f "$TOOL" ]]; then
  echo "FAIL missing tool $TOOL"
  exit 1
fi
if [[ ! -f "$GEN" ]]; then
  echo "FAIL missing generator $GEN"
  exit 1
fi
if [[ ! -f "$STEP_FIX" ]]; then
  echo "FAIL missing step fixture $STEP_FIX"
  exit 1
fi

# --- GREEN candidate: short ramped soak (same geometry/rate contract as RK8 soak) ---
set +e
python3 "$GEN" --out "$OUT/ramp12.mp4" --duration "$DUR" --ramp-frames 4 \
  >"$OUT/gen_ramp.log" 2>&1
grc=$?
set -e
echo "gen_ramp true_rc=$grc"
if [[ "$grc" -ne 0 ]]; then
  echo "FAIL gen_ramp rc=$grc"
  tail -n 20 "$OUT/gen_ramp.log" | sed 's/^/  | /'
  exit 1
fi

# Measure properties (not intent)
set +e
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,profile,has_b_frames \
  -of default=nw=1 "$OUT/ramp12.mp4" >"$OUT/ramp12_v.txt" 2>"$OUT/ramp12_v.err"
vrc=$?
set -e
echo "ffprobe_ramp_v true_rc=$vrc"
cat "$OUT/ramp12_v.txt"
if [[ "$vrc" -ne 0 ]]; then
  echo "FAIL ffprobe ramp video"
  exit 1
fi
# Hard checks on contract fields
python3 - <<PY
from pathlib import Path
p = Path("$OUT/ramp12_v.txt").read_text()
need = {
  "width=624": False,
  "height=480": False,
  "r_frame_rate=24/1": False,
  "avg_frame_rate=24/1": False,
  "profile=Constrained Baseline": False,
  "has_b_frames=0": False,
}
for k in need:
  if k in p:
    need[k] = True
bad = [k for k,v in need.items() if not v]
if bad:
  raise SystemExit("FAIL ramp contract missing: " + ",".join(bad))
print("PASS ramp_ffprobe_contract")
PY

run_tool() {
  local name="$1" input="$2"
  local dir="$OUT/run_$name"
  mkdir -p "$dir"
  set +e
  python3 "$TOOL" --input "$input" --out "$dir" --label "$name" \
    --tol-ms 500 --slope-tol-ms-per-s 5 \
    --json-out "$dir/report.json" >"$dir/stdout.txt" 2>&1
  local rc=$?
  set -e
  echo "$rc" >"$dir/true_rc.txt"
  echo "$rc"
}

extract_onset() {
  local report="$1"
  python3 - <<PY
import json
from pathlib import Path
d = json.loads(Path("$report").read_text())
fm = d["result"]["flash_meta"]
print(f"n_flashes={fm.get('n_flashes')}")
print(f"flash_onset_n_step={fm.get('flash_onset_n_step')}")
print(f"flash_onset_n_interp={fm.get('flash_onset_n_interp')}")
print(f"capture_frame_quant_ms_no_interp={fm.get('capture_frame_quant_ms_no_interp')}")
PY
}

echo "=== RED: step blip must use step onset (n_interp==0) ==="
rc="$(run_tool step "$STEP_FIX")"
echo "CASE step true_rc=$rc"
if [[ "$rc" -eq 77 ]]; then
  echo "FAIL step returned UNSCORED rc=77 (not a pass)"
  fail=$((fail + 1))
elif [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
  # 0 or 2 are both scored; 2 is out-of-tol which is fine for this gate
  echo "FAIL step unexpected rc=$rc"
  tail -n 20 "$OUT/run_step/stdout.txt" | sed 's/^/  | /'
  fail=$((fail + 1))
else
  extract_onset "$OUT/run_step/report.json" | tee "$OUT/run_step/onset.txt"
  n_i=$(grep -E '^flash_onset_n_interp=' "$OUT/run_step/onset.txt" | cut -d= -f2)
  n_s=$(grep -E '^flash_onset_n_step=' "$OUT/run_step/onset.txt" | cut -d= -f2)
  n_f=$(grep -E '^n_flashes=' "$OUT/run_step/onset.txt" | cut -d= -f2)
  echo "step measured n_flashes=$n_f n_step=$n_s n_interp=$n_i"
  if [[ "${n_i:-x}" == "0" && "${n_f:-0}" -ge 4 ]]; then
    echo "PASS step_onset_all_step n_interp=0 n_flashes=$n_f n_step=$n_s"
    pass=$((pass + 1))
  else
    echo "FAIL step_onset expected n_interp=0 got n_interp=$n_i n_step=$n_s n_flashes=$n_f"
    fail=$((fail + 1))
  fi
fi

echo "=== GREEN: ramp fixture must use linear-interp onset (n_step==0) ==="
rc="$(run_tool ramp "$OUT/ramp12.mp4")"
echo "CASE ramp true_rc=$rc"
if [[ "$rc" -eq 77 ]]; then
  echo "FAIL ramp returned UNSCORED rc=77 (not a pass)"
  fail=$((fail + 1))
elif [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
  echo "FAIL ramp unexpected rc=$rc"
  tail -n 20 "$OUT/run_ramp/stdout.txt" | sed 's/^/  | /'
  fail=$((fail + 1))
else
  extract_onset "$OUT/run_ramp/report.json" | tee "$OUT/run_ramp/onset.txt"
  n_i=$(grep -E '^flash_onset_n_interp=' "$OUT/run_ramp/onset.txt" | cut -d= -f2)
  n_s=$(grep -E '^flash_onset_n_step=' "$OUT/run_ramp/onset.txt" | cut -d= -f2)
  n_f=$(grep -E '^n_flashes=' "$OUT/run_ramp/onset.txt" | cut -d= -f2)
  echo "ramp measured n_flashes=$n_f n_step=$n_s n_interp=$n_i"
  # Require every flash took interp path.
  if [[ "${n_s:-x}" == "0" && "${n_i:-0}" -eq "${n_f:-0}" && "${n_f:-0}" -ge 4 ]]; then
    echo "PASS ramp_onset_all_interp n_step=0 n_interp=$n_i n_flashes=$n_f"
    pass=$((pass + 1))
  else
    echo "FAIL ramp_onset expected n_step=0 and n_interp==n_flashes; got n_step=$n_s n_interp=$n_i n_flashes=$n_f"
    fail=$((fail + 1))
  fi
fi

echo "=== HOST PROOF: ramp interp beats step quant on real capture PTS ==="
PROOF="$ROOT/tools/avsync_ramp_onset_proof.py"
# Checked-in measured PTS grid (extracted from 480p_repeat1_capture.mkv).
# Do NOT require the 339 MB mkv; do NOT use --allow-missing-capture (SYNTH).
PTS_GRID="$ROOT/tests/fixtures/avsync/480p_repeat1_capture_pts_60s.json"
PROOF_OUT="$OUT/onset_proof.json"
if [[ ! -f "$PROOF" ]]; then
  echo "FAIL missing $PROOF"
  fail=$((fail + 1))
elif [[ ! -f "$PTS_GRID" ]]; then
  echo "FAIL missing measured PTS fixture $PTS_GRID"
  fail=$((fail + 1))
else
  # Provenance hard checks (conditional skip forbidden).
  set +e
  python3 - "$PTS_GRID" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
errs = []
if d.get("schema") != "misterplex.measured_capture_pts_grid.v1":
    errs.append(f"schema={d.get('schema')!r}")
if d.get("grid_src") != "measured_capture_pts":
    errs.append(f"grid_src={d.get('grid_src')!r}")
prov = d.get("provenance") or {}
for k in ("source_filename", "source_md5", "source_size_bytes", "captured_date_local"):
    if prov.get(k) in (None, ""):
        errs.append(f"missing provenance.{k}")
if not isinstance(d.get("pts_rel_s"), list) or len(d["pts_rel_s"]) < 30:
    errs.append("pts_rel_s too short")
if float(d.get("median_dt_ms") or 0) <= 0:
    errs.append("median_dt_ms")
if errs:
    print("FAIL pts_grid_provenance: " + "; ".join(errs))
    sys.exit(1)
print(
    "PASS pts_grid_provenance "
    f"n={len(d['pts_rel_s'])} median_dt_ms={d.get('median_dt_ms')} "
    f"src_md5={prov.get('source_md5')} src_bytes={prov.get('source_size_bytes')}"
)
sys.exit(0)
PY
  prov_rc=$?
  set -e
  echo "pts_grid_provenance true_rc=$prov_rc"
  if [[ "$prov_rc" -ne 0 ]]; then
    fail=$((fail + 1))
  else
    set +e
    python3 "$PROOF" --pts-grid "$PTS_GRID" --duration 60 --json-out "$PROOF_OUT" \
      >"$OUT/onset_proof.log" 2>&1
    prc=$?
    set -e
    echo "onset_proof true_rc=$prc"
    if [[ "$prc" -eq 0 ]] \
      && grep -q 'VERDICT=PASS' "$OUT/onset_proof.log" \
      && grep -q 'src=measured_capture_pts' "$OUT/onset_proof.log" \
      && ! grep -q 'SYNTH_GRID' "$OUT/onset_proof.log"; then
      echo "PASS onset_proof_ramp_beats_step grid_src=measured_capture_pts"
      pass=$((pass + 1))
      grep -E '^(PRE_REGISTER|MEASURED|PASS|FAIL|VERDICT|LOAD_PTS|CAPTURE_DT|PTS_GRID)' \
        "$OUT/onset_proof.log" | tail -24
    else
      echo "FAIL onset_proof"
      tail -n 40 "$OUT/onset_proof.log" | sed 's/^/  | /'
      fail=$((fail + 1))
    fi
  fi
fi

# NEGATIVE: tampered fixture must FAIL hard (not skip).
echo "=== NEG: tampered PTS fixture must FAIL (not skip) ==="
TAMPER="$OUT/pts_grid_tampered.json"
python3 - "$PTS_GRID" "$TAMPER" <<'PY'
import json, sys
from pathlib import Path
d = json.loads(Path(sys.argv[1]).read_text())
# Corrupt measured claim: empty pts + relabel as if still measured.
d["pts_rel_s"] = []
d["n_frames"] = 0
Path(sys.argv[2]).write_text(json.dumps(d) + "\n")
PY
set +e
python3 "$PROOF" --pts-grid "$TAMPER" --duration 60 >"$OUT/onset_proof_tamper.log" 2>&1
trc=$?
set -e
echo "onset_proof_tamper true_rc=$trc"
if [[ "$trc" -eq 0 ]]; then
  echo "FAIL tampered fixture unexpectedly PASSed (proof-class hole)"
  fail=$((fail + 1))
elif grep -qi 'SKIP\|UNSCORED\|allow-missing' "$OUT/onset_proof_tamper.log"; then
  echo "FAIL tampered fixture soft-skipped instead of hard FAIL"
  fail=$((fail + 1))
else
  echo "PASS neg_tampered_pts_grid_hard_fail rc=$trc"
  pass=$((pass + 1))
fi

# NEGATIVE: missing fixture path must FAIL hard.
echo "=== NEG: missing PTS fixture must FAIL (not skip) ==="
set +e
python3 "$PROOF" --pts-grid "$OUT/does_not_exist_pts.json" --duration 60 \
  >"$OUT/onset_proof_missing.log" 2>&1
mrc=$?
set -e
echo "onset_proof_missing true_rc=$mrc"
if [[ "$mrc" -eq 0 ]]; then
  echo "FAIL missing fixture unexpectedly PASSed"
  fail=$((fail + 1))
else
  echo "PASS neg_missing_pts_grid_hard_fail rc=$mrc"
  pass=$((pass + 1))
fi

echo "=== SUMMARY pass=$pass fail=$fail ==="
if [[ "$fail" -ne 0 ]]; then
  echo "AVSYNC_RAMP_ONSET_FAIL"
  exit 1
fi
echo "AVSYNC_RAMP_ONSET_OK pass=$pass"
exit 0
