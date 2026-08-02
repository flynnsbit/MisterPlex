# P7 parent HDMI capture recipe (suite does not grab)

Playwright emits `CAPTURE_WINDOW_OPEN_*` / `CAPTURE_WINDOW_CLOSE_*` wall clocks.
**Green Playwright ≠ P7 closed.** Viewed pixels are parent-only.

## Suite command (host)

```bash
cd /path/to/.worktrees/w-plextv-e2e-form
export PLEX_BASE="..." PLEX_TOKEN_FILE="..." MISTER_HOST="..."
# Optional pin (never commit lab rks as CI truth):
# export E2E_P7_RATING_KEY=...
E2E_TRANSITION_CYCLES=10 E2E_P7_HOLD_SEC=45 \
  ./tests/hw/e2e/run_p7_real_title.sh; echo "true rc=$?"
```

## When to capture

Watch suite stdout for:

1. `P7_CLEAR_WAIT` / `P7_LOG_CLEAR_RECIPE` — truncate LIVE daemon log **before** play if correlating GEOM.
2. `PLAY_ISSUED correlation_id=...` — cast started.
3. `CAPTURE_WINDOW_OPEN wall_ms=... wall_iso=...` — **start grab now**.
4. `CAPTURE_WINDOW_CLOSE ...` — stop grab; score only frames inside open..close (after warmup skip).

## Parent grab + score (device host; suite never opens video0)

```bash
mkdir -p build/e2e-p7-capture && rm -f build/e2e-p7-capture/f_*.png
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i "${E2E_HDMI_VIDEO_DEV:-/dev/video0}" -frames:v 1500 \
  -y build/e2e-p7-capture/f_%04d.png; echo "true rc=$?"

python3 tools/hdmi_motion_instrument.py build/e2e-p7-capture \
  --warmup-skip 15 --source-fps "${E2E_HDMI_SOURCE_FPS:-24}" \
  --capture-fps "${E2E_HDMI_CAPTURE_FPS:-30}" --json; echo "true rc=$?"
```

If grabber is dead (`Pixelclock: 0`, frozen PNG): **do not** call P7 pixel-closed.
Record `CAPTURE_NO_SIGNAL` / `INSUFFICIENT_EVIDENCE` for glass; suite control-plane may still PASS.

## What suite asserts vs parent

| Claim | Who |
|-------|-----|
| Real title (not flash fixture) selected | Suite (PMS metadata / Contract 3) |
| Cast + session + transitions | Suite |
| Delivered geom (measured=) | Suite if log/telemetry provided |
| Recognizable picture / motion on glass | **Parent HDMI only** |
