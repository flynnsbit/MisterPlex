# w-plextv status report (definition-of-done: Playwright half)

**Tip:** see `status.txt` `sha=`  
**Branch:** `w-plextv-cast-picker-e2e-fix2`  
**Worktree:** `.worktrees/w-plextv-e2e-fix`  
**Agent runs are not evidence.** Parent runs score.

---

## 1. What is landed (code)

| Area | Location | Notes |
|------|----------|--------|
| Cast picker E2E | `tests/hw/e2e/test_cast_picker_playwright.js` | Real Plex Web UI |
| Entrypoint | `tests/hw/e2e/run_cast_picker.sh` | |
| N-loop S6 | `E2E_TRANSITION_CYCLES` default **10** | `TRANSITION_CYCLE_ROW` + pass==N only |
| UI-first transport | pause/resume/seek/stop | HTTP fallback **tagged** |
| Seek fwd + **back** | 8s then 2s | New |
| UI↔daemon clock | `ui_timeline.js` | |
| PID/exe stability | telemetry `readlink` | not pidof |
| Correlation | `run_correlate.js` `E2E_RUN_ID` + `/player/e2e_mark` | |
| Timeline series | `timeline_series.js` `PLEX_TIMELINE_SAMPLE` | wall↔plex_time |
| Glass loss % | `glass_counter_loss.js` + instrument | when capture provided |
| Per-transition glass contract | `glass_expect.js` **`GLASS_EXPECT`** | parent HDMI join |
| Offline glass score | `score_glass_capture.js` | no grabber |
| Red-path proof | `prove_red_paths.js` | rc=1/2 classes |
| Teardown | our controller only | user tab safe |
| Real-content arm | `test_real_content_playwright.js` | often empty lib |

## 2. Parent-proven vs not

| Claim | Evidence |
|-------|----------|
| Picker exact + ghost reject + play + transitions N=1 + TEARDOWN | **Parent** @ `93fa0c04` `true rc=0` |
| N=10 on tip | **Not yet parent-run** — code default 10 |
| Glass loss gate / GLASS_EXPECT markers | **Unit/code only** until parent scores capture |
| UI timeline truthfulness on tip | **Not yet parent-run** on tip SHA |
| Agent E2E | **Never evidence** |

## 3. Exit codes (never confuse)

| rc | Meaning | Pass? |
|----|---------|-------|
| 0 | `CAST_PICKER_E2E_RESULT=PASS` | Yes |
| 1 | FAIL (assert disproved) | **No** |
| 2 | `UNVERIFIED` (PMS down) | **No** |
| 77 | SKIP-NOT-PASS (deps/token/chromium) | **No** |

Soft-skip logs (`GLASS_NOT_SCORED`, `GLASS_LOSS_SOFT_SKIP`, PID soft) are **not** passes.

## 4. Gaps (honest)

1. **Glass pixels** — suite emits `GLASS_EXPECT` + optional score; **you** capture/score HDMI. Without capture, control-plane can PASS while glass is wrong (`GLASS_NOT_SCORED=1`).
2. **Discovery after daemon restart** — suite does not restart daemon. Cold discovery = first picker open; mid-run recheck = `E2E_DISCOVERY_RECHECK=1` (default on). After you restart daemon, re-run suite.
3. **N=10 tip** — needs your run for evidence.
4. **Lipsync** — never asserted (correct).
5. **Real library titles** — weak when empty.

## 5. Transition set per cycle (N times)

idle→play (reset) → **pause** → **resume** → **seek_fwd@8s** → **seek_back@2s** → **stop** → idle→play → idle (forced)

Each emits `GLASS_EXPECT` with `picture=` / `counter=` / `hold_ms=` / `wall_ms=`.

## 6. Parent commands

```bash
cd .worktrees/w-plextv-e2e-fix

# A) Red paths (no cast)
node tests/hw/e2e/prove_red_paths.js; echo "true rc=$?"

# B) Full DoD control-plane + N=10 + glass markers (you HDMI-align on GLASS_EXPECT)
E2E_TIER=480p E2E_DAEMON_DECODE=624x480 E2E_TRANSITION_CYCLES=10 \
E2E_DISCOVERY_RECHECK=1 E2E_REQUIRE_UI_TIMELINE=1 E2E_REQUIRE_PID=1 \
E2E_REQUIRE_DAEMON=1 \
PLEX_BASE=http://YOUR-PLEX-SERVER:32400 PLEX_TOKEN=<tok> PLEX_WEB_USER=<profile> \
MISTER_HOST=<mister> \
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"

# C) Pair glass score with a capture you took during GLASS_EXPECT holds
E2E_GLASS_CAPTURE_DIR=<pngs> E2E_GLASS_MAX_LOSS_PCT=1.0 \
  node tests/hw/e2e/score_glass_capture.js; echo "true rc=$?"

# D) Require glass in full run (FAIL if no capture)
E2E_REQUIRE_GLASS=1 E2E_GLASS_CAPTURE_DIR=<pngs> ... run_cast_picker.sh; echo "true rc=$?"
```

### GLASS_EXPECT → what you should SEE

| transition | picture | counter (TREK) | glass |
|------------|---------|----------------|-------|
| play after | motion | advancing | moving decode |
| pause after | frozen | pinned | still frame |
| resume after | motion | advancing | motion from pin |
| seek_fwd/back after | seek_discontinuity | jump then advance | n jumps |
| stop / idle after | idle_logo | na | static Plex logo |

Join: `wall_ms` + `E2E_RUN_ID` + daemon `e2e_mark`.

### Pre-registered

- B PASS → rc=0, `pass==10`, `DISCOVERY_RECHECK_OK`, `TEARDOWN_OK`, idle at end  
- B without glass capture → may PASS control-plane with `GLASS_NOT_SCORED=1` (not glass pass)  
- C 1.54% loss → rc=1 `glass_frame_loss`  
- PMS down → rc=2; daemon down → rc=1 `daemon_unreachable`
