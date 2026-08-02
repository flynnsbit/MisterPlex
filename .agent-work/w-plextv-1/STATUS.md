# w-plextv — PMS delivery observation (grabber dead)

## Status
1. Grabber frozen (byte-identical PNGs) — Playwright + PMS is the E2E channel.
2. **PMS_DELIVERY** from `/status/sessions`: hasTranscodeSession + delivered_geom (not daemon logs).
3. Parent ladder encoded: **397→312x240 hasTS=0** · **2000→624x480**.
4. Suite **can** observe TS presence/decision/WxH across bitrate arms; **cannot** set maxVideoBitrate (daemon conf) or prove pixels.
5. PASS_SCOPE=control_plane+pms_delivery. Picture claims → never PASS (INSUFFICIENT for glass).

## Pure proofs
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
node tests/hw/e2e/pms_control_plane.js; echo "true rc=$?"
node tests/hw/e2e/prove_red_paths.js; echo "true rc=$?"
```

## Parent — cast + PMS delivery (device)
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
export PLEX_BASE="..." PLEX_TOKEN_FILE="..." MISTER_HOST="..."
# After configuring daemon maxVideoBitrate=397:
E2E_PMS_EXPECT_GEOM=312x240 E2E_PMS_EXPECT_HAS_TRANSCODE=0 E2E_CLIENT_RATING_KEY=36 \
  ./tests/hw/e2e/run_pms_delivery_cast.sh; echo "true rc=$?"
# After maxVideoBitrate=2000:
E2E_PMS_EXPECT_GEOM=624x480 E2E_CLIENT_RATING_KEY=36 \
  ./tests/hw/e2e/run_pms_delivery_cast.sh; echo "true rc=$?"
```

## Parent — observe only while you cast (no Playwright)
```bash
export PLEX_BASE="..." PLEX_TOKEN_FILE="..."
E2E_OBSERVE_SEC=120 E2E_CLIENT_RATING_KEY=36 \
  ./tests/hw/e2e/run_pms_session_observe.sh; echo "true rc=$?"
```

## What each asserts
| assert | fails when |
|--------|------------|
| picker exact | MiSTer missing / ghost only |
| companion | wrong primary friendlyName |
| session playing rk | no/wrong PMS session |
| PMS_DELIVERY geom | delivered ≠ expect (312x240 vs 624x480) |
| PMS_DELIVERY hasTS | presence ≠ expect (397→0 is DATA) |
| pause/stop | PMS state not paused/gone |
| teardown | our controller left |

**Never:** green = pixels. rc=77/78 never pass.
