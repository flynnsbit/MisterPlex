# w-plextv — P7 real-title path

## Last finished
P7 suite half: real title (not flash fixture), API-measured selection, ERROR-12
correlation, CAPTURE_WINDOW for parent HDMI, N=10 transitions, our-controller teardown.
**Viewed pixels = parent only. Green Playwright ≠ P7 closed.**

Tip: see `git log -1 --oneline`

## Parent paste — P7 (you run; agent-run ≠ evidence)
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-fix

# Optional: pause 30s before PLAY so you can truncate LIVE misterplexd.log
# export E2E_P7_CLEAR_WAIT_SEC=30
# During wait: : > LIVE_LOG; export E2E_LOG_CLEARED_BEFORE_CAST=1

# After CAST_WINDOW_CLOSE (or during hold), snip correlated lines:
# grep -E 'MEASURED_DELIVERY|measured_delivery=|desync_risk=|session_epoch=|GEOM |e2e_mark' LIVE_LOG | tail -200 \
#   > build/e2e-p7/daemon_snip.txt
# export E2E_DAEMON_LOG=$PWD/build/e2e-p7/daemon_snip.txt
# export E2E_LOG_CLEARED_BEFORE_CAST=1

E2E_P7_RATING_KEY=30 E2E_TRANSITION_CYCLES=10 E2E_P7_HOLD_SEC=45 \
  ./tests/hw/e2e/run_p7_real_title.sh; echo "true rc=$?"
```

Prefer non-bank scale path: `E2E_P7_RATING_KEY=32` (720x480) or `29` (624x352).

## Artifacts
- `build/e2e-p7/p7_cast_manifest.json` — item, windows, measured
- `build/e2e-p7/p7_events.jsonl`
- `build/e2e-p7/e2e_run_id.txt`
- Log: `P7_SELECTED_ITEM`, `CAST_WINDOW_*`, `CAPTURE_WINDOW_*`, `MEASURED_DELIVERY_OK`, `TRANSITIONS_OK`, `TEARDOWN_OK`

## HDMI during CAPTURE_WINDOW_OPEN..deadline
Discard ~15 warmup frames. Suite does not open `/dev/video0`.

## NOT covered by suite
Viewed pixels (P7 promotion), overlay res, judder, lipsync, PLXD frames.
