# w-plextv — P7 last blocker handoff

## ≤10-line status
1. **Real titles ARE on local PMS** (measured 2026-08-01) — parent “section 2 = only synthetic” is **stale**.
2. Section 1 "Other Videos" = **size=0** (confirmed empty).
3. Section 2 has Contract 3 real BBB/FullBleed beside fixtures (rk 9–10,18–19,27–32).
4. Suite @ tip below: Plex Web cast + N=10 + CAPTURE_WINDOW + MEASURED_DELIVERY only + TEARDOWN_OK our-only.
5. Default discover → **rk=10 BBB 720×480 ~597s** (real, long, non-bank scale path).
6. **Green Playwright ≠ P7 closed** — you must VIEW pixels in CAPTURE_WINDOW.
7. B2 `-loglevel info` **already in this tree** `media_player.cpp` (DELIVERED_GEOM). Deploy if live daemon still has `error`.
8. B4: suite never accepts `library_media` as delivered; daemon `delivery_basis=library_media` is expect/scale only — flag for arm owner if GEOM confuses ops.

## PMS inventory (measured API, LOCAL only)

| rk | library_media | dur | what |
|----|---------------|-----|------|
| 10 | 720×480 | ~597s | **Real BBB** (default P7) |
| 30 | 624×480 | 1200s | Real BBB GlassAV long bank |
| 28 | 1440×1080 | 90s | Real BBB full-frame short |
| 27 | 624×480 | 1200s | FullBleed VRes AV (asset480) |
| 9/18/19/29/31/32 | various | 90–596s | BBB ladder |
| 1–8,11–17,20–26 | synth | — | Test/Soak/OCR — **not P7** |

Other Videos: empty. No restore needed if section 2 BBB stays scanned.

## Parent paste (you run; agent-run ≠ evidence)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form

# ERROR-12: optional clear window
# export E2E_P7_CLEAR_WAIT_SEC=30
# during wait: truncate LIVE misterplexd.log; export E2E_LOG_CLEARED_BEFORE_CAST=1
# after CAST_WINDOW_CLOSE:
#   grep -E 'MEASURED_DELIVERY|measured_delivery=|DELIVERED_GEOM|desync_risk=|session_epoch=|GEOM ' LIVE \
#     | tail -200 > build/e2e-p7/daemon_snip.txt
#   export E2E_DAEMON_LOG=$PWD/build/e2e-p7/daemon_snip.txt

PLEX_BASE=http://192.168.1.24:32400 \
PLEX_TOKEN_FILE=/tmp/local_tok.txt \
MISTER_HOST=192.168.1.183 \
E2E_TRANSITION_CYCLES=10 \
E2E_P7_HOLD_SEC=45 \
./tests/hw/e2e/run_p7_real_title.sh; echo "true rc=$?"
```

Pins: `E2E_P7_RATING_KEY=30` long bank · `28` 1440 short · `E2E_P7_ARM=fullbleed` → 27

## PREREGISTER (what you should see)
- Log: `P7_SELECTED_ITEM` / `P7_PREREGISTER` / `discover_p7_ok` with rk+title+file (measured)
- `CAST_WINDOW_OPEN/CLOSE` + `CAPTURE_WINDOW_OPEN`..deadline (~45s + 15-frame warmup)
- Glass: **not** flash-black mean luma ~3–7; recognizable BBB/FullBleed content
- Delivered geom: only from MEASURED_DELIVERY / DELIVERED_GEOM / measured_delivery= inside window
- `TRANSITIONS_OK` N=10 · `TEARDOWN_OK controller=closed` (user Plex tab untouched)

## Artifacts
`build/e2e-p7/p7_cast_manifest.json` · `p7_events.jsonl` · `e2e_run_id.txt`

## Free win flag (B2)
`arm/misterplexd/media_player.cpp` rawvideo spawn already uses `-loglevel info` + `DELIVERED_GEOM` re-log in **this branch**. If device still suppresses Stream banners, live binary is stale — redeploy misterplexd (parent owns deploy).

## SHA
```bash
git -C /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form rev-parse --short HEAD
```
