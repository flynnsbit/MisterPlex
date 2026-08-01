# PARENT CARD — lipsync GT + LEAD falsifier + +100 ms proof

## ≤10-line status
1. **Audio path YES:** MS2109 ALSA `hw:0,0` + `/dev/video0` (settled).
2. **Instrument resolves +100 ms (HOST, measured):** AudioID Δ=**99.29 ms**; GlassAV Δ=**100.00 ms**.
3. **`av_drift_ms` is NOT lipsync** — pinned in `[-lead,drop)` by construction (`av_clock.hpp` + `av_drift_role=servo_error_not_lipsync`).
4. **LEAD falsifier designed** — env `MISTERPLEX_AV_PRESENT_LEAD_MS=40|20`; pre-reg Δservo ∈[+12,+28].
5. **session_epoch required** per arm — `tools/avsync_capture_session_epoch.sh`.
6. **fps_src=caller_supplied** on supply_bucket is ASSUMPTION — do not build GT on `supply_gap` alone.
7. Agent never touches device. Soft-skip 77 ≠ pass.

## Sign
`offset_ms=(t_beep−t_flash)×1000` · **+ = audio LATE** · tags: measured|caller_supplied|DEFAULT_ASSUMED

## Host green (this session)
| Pair | zero median | plus median | Δ | rc |
|------|------------:|------------:|--:|---|
| AudioID 60s (rk23/24 class) | 81.99 | 181.28 | **99.29** | 0 |
| GlassAV 600s (rk20/21 class) | −6.35 | 93.65 | **100.00** | 0 |

```bash
# Re-run host gate anytime (no device):
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
OUT=$PWD/.agent-work/w-avsync/plus100_ab MODE=host bash tools/avsync_plus100_ab.sh
echo "true rc=$?"
```

---

## PASTE A — LEAD falsifier (you restart daemon; I do not)

Pre-register (publish hit/miss):

| ID | Prediction |
|----|------------|
| P_SERVO_A | LEAD=40 → av_drift median ∈ [−40,−15] |
| P_SERVO_B | LEAD=20 → av_drift median ∈ [−20,+5] |
| P_SERVO_Δ | median_B−A ∈ **[+12,+28]** → **CIRCULAR** (must not be lipsync GT) |
| P_HDMI_Δ | HDMI median_B−A ≈ **+20±15** (video advanced) OR ≈0 (decoupled) |
| P_CONF | conf bytes unchanged |
| P_BANNER | `AV_PRESENT_LEAD_MS=env:40` / `env:20` |

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
bash tools/avsync_lead_falsifier.sh card    # full procedure

# After arm A (LEAD=40) soak + daemon_tail saved as LOG_A / REPORT_A,
# and arm B (LEAD=20) similarly:
LOG_A=.../leadA/daemon_tail.txt LOG_B=.../leadB/daemon_tail.txt \
  REPORT_A=.../leadA_stdout.txt REPORT_B=.../leadB_stdout.txt \
  bash tools/avsync_lead_falsifier.sh score_both
echo "lead_falsifier true rc=$?"
```

Daemon restart (device; conf not written):
```text
MISTERPLEX_AV_PRESENT_LEAD_MS=40   # arm A — expect banner env:40
MISTERPLEX_AV_PRESENT_LEAD_MS=20   # arm B — expect banner env:20
```
Each arm: single `session_epoch`; soak ≥60 s:
```bash
bash tools/avsync_capture_session_epoch.sh | tee epoch.txt
OUT=$PWD/avsync_hdmi_out/leadX_$(date +%Y%m%dT%H%M%S); mkdir -p "$OUT"
DURATION=60 MARKER_PERIOD_S=2.0 MIN_PAIRS=20 TOL_MS=200 DECODE_SRC=caller_supplied \
  OUT="$OUT" LABEL=leadX bash tools/avsync_lipsync_soak.sh >"$OUT/wrap.txt" 2>&1
echo "soak true rc=$?"
# also: ssh grep av_drift_ms= + supply_bucket + session_epoch → daemon_tail.txt
```

---

## PASTE B — Live +100 ms on glass (rk=23 then rk=24)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
OUT=$PWD/avsync_hdmi_out/live100_$(date +%Y%m%dT%H%M%S); mkdir -p "$OUT"
# Cast rk=23 (AudioID 0ms), wait playing:
MODE=live ARM=zero ARM_S=45 MARKER_PERIOD_S=2.0 MIN_PAIRS=10 OUT="$OUT" \
  bash tools/avsync_plus100_ab.sh | tee "$OUT/zero_wrap.txt"
echo "zero true rc=$?"
# Cast rk=24 (audioPlus100ms), then:
MODE=live ARM=plus ARM_S=45 MARKER_PERIOD_S=2.0 MIN_PAIRS=10 OUT="$OUT" \
  bash tools/avsync_plus100_ab.sh | tee "$OUT/plus_wrap.txt"
echo "plus_ab true rc=$?"
# Expect SCORE_PLUS100_AB delta_ms ≈ 100, verdict INSTRUMENT_RESOLVES_100MS
```
Each arm stamps `session_epoch` — do not compare if either is NO-DATA.

rk=20/21 = same idea @600s (longer soak).

---

## Forbidden
- Scoring lipsync from `av_drift_ms` / av-lock alone
- Pooling across `session_epoch`
- Treating `fps_src=caller_supplied` as measured rate for supply_gap GT
- Claiming absolute HDMI median without known-zero cal (`raw_uncalibrated`)
