# RESULT — ce727a43 stderr RCA + principled LINK_CAP (no magic constant)

Live device remains `ea643e99` (parent-verified). This build is **additive** on silicon-pin: stderr visibility + LINK_CAP math. Does not require SUSPEND change.

Binary md5: **`b281217637e6b37a417743887c97268f`**

---

## Task 2 — ce727a43 zero-frame RCA (stderr pump)

### Quoted defect (silicon-pin / pre-fix)

`media_player.cpp` `ffmpegStderrPump` previously:

```cpp
const auto g = parseFfmpegGeometryLine(line);
if (!g.ok)
    continue;   // SILENT DISCARD of every non-geometry line
```

Also only split on `'\n'`, so `-stats` CR progress could stick in the accumulator.

### What device log already proved

ce727a43 session still emitted:
- `MEASURED_FPS` / `MEASURED_DELIVERY delivered_geom=624x350`
- audio pump bytes > 0
- `short read got=0/449280 totalBytes=0 eof=1`

So: HTTP open + banner parse worked; **video stdout produced nothing**. Any post-banner fatal (`Error while opening encoder`, `Nothing was written…`, filter graph fail) would hit `!g.ok → continue` and **never appear in the daemon log**. Parent lead is **confirmed as a real silence hole**.

### What is still unknown (Rule 0)

**The exact ffmpeg fatal line for ce727a43 was not captured** — because of the hole above. Host dual-pipe A/B previously showed `-stats` alone does not zero video bytes. Tip also differed in pipe sizing, adelay form, present loop — **not proven** as the device cause without the missing stderr.

### Fix (this build)

`host/libmisterplex/ffmpeg_stderr.hpp` + pump:
- split on `\n` and `\r`
- classify: ProgressNoise | GeometryCandidate | **Diagnostic**
- **log all Diagnostic** (ERROR prefix if fatal-looking); cap spam at 32 unless fatal
- `ffmpeg_stderr_summary diagnostic_n= fatal_n=`

Gate: `test_ffmpeg_stderr` — proves Error/Invalid/Nothing-was-written are Diagnostic+fatal, not swallowed.

---

## Task 1 — bitrate: open questions answered (no new magic default)

### Still true from prior commit `02db04d5`
- Hard `maxVideoBitrate < 2000` fail **retired** (quality heuristic, not decoder contract)
- Priority: `WEAK_BITRATE` > `min(tier, LINK_CAP_KBIT)` > tier default 2000
- Tier 2000 remains **default request only**, unset LINK_CAP = no path claim

### Parent open questions — explicit answers

| Question | Answer |
|---|---|
| Is p95 the right statistic when min was 45.7 KB/s? | **No.** p95 is diagnostic. Request target uses **p10 × headroom (0.85)**, capped by median×headroom. |
| Is one 60 s observation “the” capacity? | **No — provisional** until ≥30 positive 1 s windows (`provisional=1`). |
| Measured-adaptive vs static vs direct-play? | **Static conf LINK_CAP now** (fixture/greedy writer). Adaptive only via `stepLinkCapHysteresis` (3 lower / 10 raise / **session-sticky no raise after lower**) — required for WiFi RTT 2.9–227 ms. Direct-play when STREAM=1 and source fits path is preferred when available; do not invent mid-play re-transcode yet. |
| PMS geometry ceiling 624x480→624x350 | MEASURED_DELIVERY notes `pms_resolution_is_ceiling_not_exact`. `requestedBitsPerDeliveredPixel` uses **delivered** WxH, never assume request pixels. |

### New host library

`host/libmisterplex/link_cap.hpp`:
- `recommendLinkCapFromWindowBps(windows, headroom=0.85, minWindows=30)`
- `stepLinkCapHysteresis(...)` anti-oscillation
- unit `test_link_cap` — parent-shaped unstable distribution does **not** select p95

Example (synthetic parent-shaped): cap≈**913** kbit from p10 path with headroom when lows present — **not** 1292 p95.

### Operator path (parent runs)

1. Greedy pull, N≥30 of 1 s B/s windows, playback stopped  
2. Feed windows into host helper (or paste into a one-liner later)  
3. Write `LINK_CAP_KBIT=<recommend>` only if `provisional=0` **or** accept provisional knowingly  
4. Do **not** bake that integer into the binary  

---

## Host gates (`true rc=0`)

- test_ffmpeg_stderr OK  
- test_link_cap OK  
- test_resolve OK  
- test_play_file_av_dual frames=48  
- test_main_session_suspend OK  
- UNIT_ROLLCALL_OK  

---

## Parent deploy (optional; ea643e99 may stay until ready)

Stage md5 `b281217637e6b37a417743887c97268f`. Smoke SUSPEND=0 first (frames>0).  
PRE_REG: cast a **broken** URL or bad vf once — log must show `ERROR media: ffmpeg …` not silence.  
LINK_CAP unset → bitrate 2000 tier_default; set LINK_CAP after fixture.
