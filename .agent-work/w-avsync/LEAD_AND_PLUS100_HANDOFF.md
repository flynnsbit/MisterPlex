# Handoff — LEAD falsifier + +100 ms instrument proof

## Host evidence (measured this session)
- AudioID 60s pair: Δmedian = **99.2885 ms** (err 0.71) → INSTRUMENT_RESOLVES_100MS rc=0
- GlassAV 600s pair: Δmedian = **99.9978 ms** (err 0.002) → INSTRUMENT_RESOLVES_100MS rc=0
- Tools: `avsync_measure_hdmi.py` flash↔beep; not av_drift_ms

## New tools
- `tools/avsync_plus100_ab.sh` — host/live A/B for designed +100 ms
- `tools/avsync_lead_falsifier.sh` — card + score_logs/score_hdmi
- `tools/avsync_capture_session_epoch.sh` — session_epoch (rc=77 if NO-DATA)

## LEAD pre-register
- Servo Δ ∈ [+12,+28] ⇒ circular
- HDMI Δ ≈ +20±15 or ≈0 (both informative)

## Quote
av_clock.hpp: av_drift ∈ [-lead,drop) BY CONSTRUCTION; av_drift_role=servo_error_not_lipsync
main.cpp: MISTERPLEX_AV_PRESENT_LEAD_MS env overrides conf without writing conf
