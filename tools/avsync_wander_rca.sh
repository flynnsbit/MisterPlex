#!/usr/bin/env bash
# Wander RCA: same-window HDMI lipsync soak + daemon telemetry scrape.
# PARENT runs this. Agent never casts/deploys.
#
# Purpose: decide whether HDMI WANDER is CAUSED by throughput collapse
# (vfps<<target, drops climbing) or merely correlated / independent.
#
# Gates:
#   - session_epoch BEFORE == AFTER (else INVALID, never score)
#   - live log resolve (two-roots safe)
#   - never reads av_drift_ms into HDMI SCORE (daemon fields are covariates only)
#   - NO-DATA stays NO-DATA (never || echo 0)
#
# Env:
#   OUT LABEL DURATION MARKER_PERIOD_S MIN_PAIRS DECODE_GEOM TIER
#   SKIP_SESSION_GATE=0|1
#
# Exit: soak rc, or 79 SESSION_INVALID, or 77 NO-DATA gate
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/avsync_hdmi_out/wander_rca}"
LABEL="${LABEL:-rca}"
DUR="${DURATION:-45}"
MARKER_PERIOD_S="${MARKER_PERIOD_S:-2.0}"
MIN_PAIRS="${MIN_PAIRS:-15}"
TIER="${TIER:-480p}"                 # caller_supplied label only
DECODE_GEOM="${DECODE_GEOM:-624x480}" # caller_supplied expected conf
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
mkdir -p "$OUT"

echo "=== avsync_wander_rca ==="
echo "tier=$TIER decode_geom=$DECODE_GEOM src=caller_supplied"
echo "duration_s=$DUR marker_period_s=$MARKER_PERIOD_S min_pairs=$MIN_PAIRS src=caller_supplied"
echo "NOT_USED_as_lipsync=av_drift_ms (covariate only) src=caller_supplied"
echo "=== PRE-REGISTER (publish hit/miss) ==="
echo "P_CAUSE: if mean_vfps < 22 AND residual_rms_ms > 25 → WANDER_WITH_THROUGHPUT_COLLAPSE"
echo "P_INDEP: if mean_vfps >= 23.5 AND residual_rms_ms > 25 → WANDER_WITHOUT_COLLAPSE"
echo "P_STABLE: if residual_rms_ms < 20 AND detrended_max_abs_ms < 50 → STABLE_WINDOW"
echo "P_EPOCH: epoch_before == epoch_after else INVALID"
echo "P_SERVO: av_drift_ms stays near -LEAD even when residual_rms high (circular)"
echo "predictions_src=caller_supplied_pre_register"

# --- epoch before ---
set +e
bash "$ROOT/tools/avsync_capture_session_epoch.sh" >"$OUT/${LABEL}_epoch_before.txt" 2>&1
EB_RC=$?
set -e
echo "epoch_before true rc=$EB_RC"
EPOCH_B=$(sed -n 's/^session_epoch=//p' "$OUT/${LABEL}_epoch_before.txt" | head -1)
if [[ -z "$EPOCH_B" || "$EPOCH_B" == "NO-DATA" ]]; then
  echo "session_epoch_before=NO-DATA src=measured"
  echo "VERDICT=UNSCORED rc=77 reason=epoch_before_absent"
  exit 77
fi
echo "session_epoch_before=$EPOCH_B src=measured"

# --- concurrent daemon scrape (live log) ---
RESOLVE_INC="$(cat "$ROOT/tools/avsync_live_log_resolve.inc.sh")"
DAEMON_SCRAPE="$OUT/${LABEL}_daemon_window.txt"
: >"$DAEMON_SCRAPE"
(
  # poll ~1 Hz for DUR+15 s; append supply_bucket / status lines
  end=$(( $(date +%s) + DUR + 15 ))
  while [[ $(date +%s) -lt $end ]]; do
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 \
      "${USER}@${HOST}" "sh -s" <<REMOTE 2>/dev/null || true
${RESOLVE_INC}
avsync_resolve_live_log
echo "ts_host=\$(date +%s.%N 2>/dev/null || date +%s) log_src=\${pick:-NONE}"
if [ -n "\$pick" ] && [ -f "\$pick" ]; then
  grep -E 'supply_bucket|vfps=|av_drift_ms=|session_epoch=|clock=' "\$pick" 2>/dev/null | tail -n 8
fi
REMOTE
    echo "--- poll ---" >>"$DAEMON_SCRAPE"
    sleep 1
  done
) >>"$DAEMON_SCRAPE" 2>&1 &
SCRAPE_PID=$!

# --- HDMI soak (session gate on) ---
set +e
DURATION="$DUR" MARKER_PERIOD_S="$MARKER_PERIOD_S" MIN_PAIRS="$MIN_PAIRS" \
  NO_ABSOLUTE_SCORE=1 DECODE_SRC=caller_supplied WARMUP_FRAMES=20 \
  LABEL="$LABEL" OUT="$OUT" \
  bash "$ROOT/tools/avsync_lipsync_soak.sh" >"$OUT/${LABEL}_soak_wrap.txt" 2>&1
SOAK_RC=$?
set -e
echo "soak true rc=$SOAK_RC"

# stop scrape
kill "$SCRAPE_PID" 2>/dev/null || true
wait "$SCRAPE_PID" 2>/dev/null || true

# --- epoch after ---
set +e
bash "$ROOT/tools/avsync_capture_session_epoch.sh" >"$OUT/${LABEL}_epoch_after.txt" 2>&1
EA_RC=$?
set -e
echo "epoch_after true rc=$EA_RC"
EPOCH_A=$(sed -n 's/^session_epoch=//p' "$OUT/${LABEL}_epoch_after.txt" | head -1)
echo "session_epoch_after=${EPOCH_A:-NO-DATA} src=measured"

if [[ -z "$EPOCH_A" || "$EPOCH_A" == "NO-DATA" ]]; then
  echo "VERDICT=INVALID_SESSION rc=79 reason=epoch_after_absent"
  echo "RCA_RC=79"
  exit 79
fi
if [[ "$EPOCH_A" != "$EPOCH_B" ]]; then
  echo "VERDICT=INVALID_SESSION_RESPAWN rc=79 epoch_before=$EPOCH_B epoch_after=$EPOCH_A"
  echo "note=mid_window_daemon_respawn_or_new_stream — do not score wander"
  echo "RCA_RC=79"
  exit 79
fi
echo "session_epoch_stable=1 src=measured epoch=$EPOCH_B"

# --- join HDMI metrics + daemon covariates ---
python3 - "$OUT" "$LABEL" "$TIER" "$DECODE_GEOM" "$EPOCH_B" "$SOAK_RC" <<'PY'
import json, re, statistics, sys
from pathlib import Path

out, label, tier, geom, epoch, soak_rc = sys.argv[1:7]
base = Path(out)
stdout = (base / f"{label}_stdout.txt").read_text(errors="replace") if (base / f"{label}_stdout.txt").is_file() else ""
wrap = (base / f"{label}_soak_wrap.txt").read_text(errors="replace") if (base / f"{label}_soak_wrap.txt").is_file() else ""
daemon = (base / f"{label}_daemon_window.txt").read_text(errors="replace") if (base / f"{label}_daemon_window.txt").is_file() else ""
text = stdout + "\n" + wrap

def grab(pat, src, cast=float):
    m = re.search(pat, src, re.M)
    if not m:
        return None, "NO-DATA"
    try:
        return cast(m.group(1)), "measured"
    except Exception:
        return None, "NO-DATA"

residual, residual_src = grab(r"residual_rms_ms=([-\d.]+)", text)
det_max, det_src = grab(r"detrended_max_abs_ms=([-\d.]+)", text)
median, med_src = grab(r"median_offset_ms_raw=([-\d.]+)", text)
n_pairs, np_src = grab(r"^n_pairs=(\d+)", text, int)
timing = None
tm = re.search(r"timing_class=([A-Z_]+)", text)
if tm:
    timing = tm.group(1)

# daemon window covariates — never promote to lipsync
vfps = [float(x) for x in re.findall(r"\bvfps=([0-9.]+)", daemon)]
pfps = [float(x) for x in re.findall(r"\bpfps=([0-9.]+)", daemon)]
drops = [int(x) for x in re.findall(r"\bdrops=(\d+)", daemon)]
drifts = [float(x) for x in re.findall(r"\bav_drift_ms=(-?[0-9.]+)", daemon)]
epochs_d = set(re.findall(r"session_epoch=([0-9.]+)", daemon))

def med(xs):
    return statistics.median(xs) if xs else None

def mean(xs):
    return statistics.mean(xs) if xs else None

row = {
    "label": label,
    "tier": tier,
    "tier_src": "caller_supplied",
    "decode_geom": geom,
    "decode_geom_src": "caller_supplied",
    "session_epoch": epoch,
    "session_epoch_src": "measured",
    "session_stable": True,
    "soak_rc": int(soak_rc),
    "timing_class": timing,
    "timing_class_src": "measured" if timing else "NO-DATA",
    "residual_rms_ms": residual,
    "residual_rms_ms_src": residual_src,
    "detrended_max_abs_ms": det_max,
    "detrended_max_abs_ms_src": det_src,
    "median_offset_ms_raw": median,
    "median_offset_ms_raw_src": med_src,
    "n_pairs": n_pairs,
    "n_pairs_src": np_src,
    "daemon_vfps_n": len(vfps),
    "daemon_vfps_mean": mean(vfps),
    "daemon_vfps_median": med(vfps),
    "daemon_vfps_min": min(vfps) if vfps else None,
    "daemon_vfps_src": "measured" if vfps else "NO-DATA",
    "daemon_pfps_mean": mean(pfps),
    "daemon_pfps_src": "measured" if pfps else "NO-DATA",
    "daemon_drops_last": drops[-1] if drops else None,
    "daemon_drops_max": max(drops) if drops else None,
    "daemon_drops_delta": (drops[-1] - drops[0]) if len(drops) >= 2 else None,
    "daemon_drops_src": "measured" if drops else "NO-DATA",
    "daemon_av_drift_median": med(drifts),
    "daemon_av_drift_min": min(drifts) if drifts else None,
    "daemon_av_drift_src": "measured_covariate_not_lipsync" if drifts else "NO-DATA",
    "daemon_epochs_seen": sorted(epochs_d),
    "note": "av_drift is covariate only; lipsync GT is residual_rms/detrended from HDMI",
}

# Classification (pre-registered bands)
vf = row["daemon_vfps_mean"]
rr = row["residual_rms_ms"]
dm = row["detrended_max_abs_ms"]
cls = "NO-DATA"
cls_src = "NO-DATA"
if rr is None and dm is None:
    cls = "NO-DATA_HDMI"
elif vf is None:
    cls = "NO-DATA_DAEMON_VFPS"
elif rr is not None and rr < 20 and (dm is None or dm < 50):
    cls = "STABLE_WINDOW"
    cls_src = "derived_prereg"
elif vf < 22.0 and rr is not None and rr > 25:
    cls = "WANDER_WITH_THROUGHPUT_COLLAPSE"
    cls_src = "derived_prereg"
elif vf >= 23.5 and rr is not None and rr > 25:
    cls = "WANDER_WITHOUT_COLLAPSE"
    cls_src = "derived_prereg"
elif rr is not None and rr > 25:
    cls = "WANDER_VFPS_MIDBAND"
    cls_src = "derived_prereg"
else:
    cls = "INDETERMINATE"
    cls_src = "derived_prereg"
row["rca_class"] = cls
row["rca_class_src"] = cls_src

jpath = base / f"{label}_rca.json"
jpath.write_text(json.dumps(row, indent=2) + "\n")
csv_path = base / "wander_rca_scatter.csv"
hdr = "label,tier,session_epoch,soak_rc,timing_class,residual_rms_ms,detrended_max_abs_ms,median_offset_ms_raw,n_pairs,vfps_mean,vfps_min,drops_delta,av_drift_median,rca_class\n"
line = (
    f"{label},{tier},{epoch},{soak_rc},{timing},"
    f"{residual},{det_max},{median},{n_pairs},"
    f"{row['daemon_vfps_mean']},{row['daemon_vfps_min']},{row['daemon_drops_delta']},"
    f"{row['daemon_av_drift_median']},{cls}\n"
)
if not csv_path.is_file():
    csv_path.write_text(hdr)
with csv_path.open("a") as f:
    f.write(line)

print(f"rca_json={jpath}")
print(f"scatter_csv={csv_path}")
for k in (
    "residual_rms_ms", "detrended_max_abs_ms", "daemon_vfps_mean", "daemon_vfps_min",
    "daemon_drops_delta", "daemon_av_drift_median", "daemon_av_drift_min",
    "timing_class", "rca_class", "n_pairs",
):
    v = row.get(k)
    src = row.get(f"{k}_src") or row.get("rca_class_src") or "derived"
    print(f"{k}={v} src={src}")
print(f"VERDICT={cls} soak_rc={soak_rc}")
print("SCORE_RCA uses HDMI residual + daemon vfps covariate; never av_drift as lipsync")
PY

echo "RCA_SOAK_RC=$SOAK_RC"
# Surface soak rc to parent; INVALID already exited 79
exit "$SOAK_RC"
