# Content FPS vs ARM budget vs `clk_pix` (analysis only — fit scope unchanged)

**Fit stays:** 960×540 / **24** content + `PRESENT_CLK_PIX_PLL` @ **29.7 MHz**.  
**This doc:** next-question analysis. No QSF/PLL product retarget.

**Parent pre-registered prediction (not a lab 30 fps measure):**
```
content   deadline    ARM 960×540 (decode+sws+copy=34.50)   verdict
24 fps    41.667 ms   34.50                                  PASS  +7.16
25 fps    40.000 ms   34.50                                  PASS  +5.50
30 fps    33.333 ms   34.50                                  FAIL  -1.17
```

---

## 1) Can we ask PMS for a fixed 24 fps?

### What we ship today (quoted)

`buildUniversalTranscodeUrl` (`plex_resolve.cpp`) sends:

- `videoResolution`, `maxVideoBitrate`, `videoQuality`
- `videoCodec`, `audioCodec`, `videoProfile`, `videoLevel`
- **No** `frameRate` / max-fps query field

`plexClientProfileExtra` already uses Plex limitation syntax for **width/height/profile/level**:

```cpp
add-limitation(... type=upperBound&name=video.width&value=W ...)
add-limitation(... type=upperBound&name=video.height&value=H ...)
// no video.frameRate today
```

Client capabilities string: `h264{profile:…&resolution:WxH&level:…}` — **no fps**.

On play, `media_player` forces **source** rate into FFmpeg:

```cpp
vfReq.fps_filter = "fps=" + num + "/" + den;  // from PMS Stream@frameRate
```

So if the **bitstream** is 30 fps, the ARM **decodes 30** and paces 30.  
A **local** `fps=24` filter only drops **after** decode → **does not** buy the 1.17 ms; it can waste work.

### Is a server-side cap available?

| Lever | In our tree? | Evidence class |
|-------|--------------|----------------|
| Universal URL `frameRate=` | **Not used** | Unknown if PMS honours it on `/universal/start` |
| `X-Plex-Client-Profile-Extra` `upperBound name=video.frameRate` | **Not wired**; same *pattern* as width/height | **Plausible** (client-profile docs); **unverified on this lab** |
| Server `Profiles/MiSTerPlex.xml` fps limit | Possible ops path | Not owned by w-clock; must measure |
| Local FFmpeg `fps=24` | Easy | **Does not reduce decode load** if input is still 30 fps |

**w-clock read (timing, not w-path ownership):**  
The **right shape** of lever is the same as resolution: **ask PMS to emit fewer frames** via client-profile / decision limitations, not client-side decimation.  
**w-path owns** wiring `video.frameRate` into `plexClientProfileExtra` + decision URL parity.  

**Pass/fail experiment (parent, when device+PMS up) — pre-register:**

```text
A) baseline universal 960x540, 30fps source title → probe delivered avg_frame_rate
B) same + profile-extra upperBound video.frameRate=24 (or 24000/1001)
PASS if delivered CFR ≤ 24.1 and ARM wall/frame drops vs A
FAIL if PMS ignores limitation (still ~30) or quality/decision rejects
```

Until B is green, **do not** treat “force 24 from PMS” as product fact.

---

## 2) Forced 24 on 30 fps source — quality (honest)

30→24 is **not** telecine inverse. It is **5:4 decimation** (drop 1 of every 5):

| Effect | Severity |
|--------|----------|
| Judder on pans / UI motion | **High** — visible on most TV |
| Sports / 60→24 even worse | **Severe** if anyone forces 24 on 60 |
| Film 23.976/24 | Fine (already native) |
| 25 PAL → 24 | Mild cadence error; often acceptable |

**Engineering opinion:**  
Forced global 24 is a **good emergency budget valve** and a **bad default for “plays video”**.  
Prefer:

1. **fps-aware ladder** (keep motion, shrink pixels), else  
2. optional conf `MAX_CONTENT_FPS=24` for weak hosts / film-heavy libraries,  
3. never silent 60→24 without user intent.

Cadence/OSD already thinks in 12/24/30/60 (`contentFpsHint`, `SOURCE_FPS`) — product language is multi-rate; a hard 24 default fights that.

---

## 3) What 30 fps actually requires

Deadline **33.333 ms**. Parent **measured** path costs (cite parent; not re-measured here):

| Tier | ms/frame (as cited) | @24 margin | @30 margin | Note |
|------|--------------------:|-----------:|-----------:|------|
| 960×540 + sws + copy | **34.50** | +7.16 | **−1.17 FAIL** | Product film path |
| 854×480 decode+copy | **27.36** | +14.31 | **+5.97** | Parent table; **sws not in that row** |
| 854×480 + ~3.57 sws (pred.) | **~30.93** | ~+10.7 | **~+2.4** | **PREDICTION** — same sws delta as 960 refine |
| 624×480 decode+copy | **21.09** | +20.57 | **+12.24** | Comfortable @30 |
| 1024×576 decode+copy | **35.61** | +6.05 | **−2.28 FAIL** | Even worse @30 |

**Conclusions:**

- Fixed **960×540 for all libraries** is a **24/25 film path**, not a 30 fps path.  
- **Frame-rate-aware tier selection** is the clean product lever:
  - source ≤25 → allow 960×540  
  - source ≥29.97 → **854×480** (or 624) until DMA/write-combine kills copy  
- 854@30 with sws is **thin (~2 ms)** — concurrent peer / HTTP still eats double digits; treat as **needs end-to-end glass measure**, not a promise.  
- **1.17 ms clawback on 960@30** (tiny decode wins) is the **wrong** fight vs tier or PMS fps.

Copy dominates the gap story long-term: kill 8–15 ms copy (w-path DMA/WC) and 960@30 becomes **~19.5–26 ms** class — then 960 works at 30. Until then, ladder must know fps.

### Cadence note (fabric)

`present_cadence` / host `cadence.hpp`: unique advance = f(content_fps, display_hz).  
Glass can free-run faster than content (ascal @60) while unique banks advance at content rate.  
**ARM still must finish each unique frame within content deadline** — cadence does not create ARM headroom.

---

## 4) Does this change `clk_pix`?

CEA totals **1650×750** (unchanged):

| Content glass rate | `clk_pix` = 1 237 500 × fps | Status in PLL plan |
|--------------------|----------------------------:|--------------------|
| 24 Hz | **29.700 MHz** | **PIX24 — fit target (hold)** |
| 25 Hz | 30.9375 MHz | Not a named target |
| 30 Hz | **37.125 MHz** | **PIX30 — next staged string** |
| 60 Hz | **74.250 MHz** | PIX60 already proposed |

### Does the held fit’s 29.7 survive a multi-rate library?

| Strategy | clk_pix | ARM | Motion |
|----------|---------|-----|--------|
| A. Cap content ≤24 (PMS or policy) | **29.7 OK for all titles** | Budget OK at 960 | Judder on 30/60 sources |
| B. fps-aware tier, glass tracks content | 29.7 **or** 37.125 | Tier picks res | Correct motion |
| C. Glass always 60 Hz (74.25), cadence unique | **74.25** | Still need ARM ≤ content period | Best UX; hardest STA |

**Held fit (A/B @24 only): `clk_pix=29.7` unchanged.**  

**PIX30:** same PLL outclk_3 retarget `37.125000 MHz`, fractional VCO, STA prereg:

- `Fmax(clk_pix) ≥ 37.125` hard  
- PPC≥2: peak sys 40 Mpix/s ≥ 37.125 → **fabric OK at ship 20 MHz** (balance)  
- Related-edge / CDC story same class as PIX24 (sys↔pix async_fifo)  

**PIX60:** already in plan; needs PPC=4 for fabric 18.56 &lt; 20; STA unknown until fit.

**ascal:** HDMI remains `video_mode` 720p60; core rate is **input** to ascal. 29.7 vs 37.125 is **content delivery rate into scaler**, not VIC legality (see `ASCAL_VS_CORE_RASTER.md`).

### Recommendation (next, not this fit)

1. Ship film path: 960 + PIX24 + identity/scaler map.  
2. w-path: prototype `video.frameRate` upperBound; **measure**.  
3. Ladder: `if source_fps ≥ 29.5 → max tier 854 (or 624)` until copy fixed.  
4. PLL: keep PIX24 default; add **PIX30 string under ifdef** only when parent grants second STA — do not block current fit.  
5. Long-term: PIX60 + cadence if one glass rate must cover all libraries without PMS fps games.

---

## 5) Coordination map

| Owner | Action |
|-------|--------|
| **w-path** | Profile-extra / decision `video.frameRate`; ladder fps branch; do **not** rely on local fps= for budget |
| **w-clock** | PIX24 fit; document PIX30=37.125; rate-match params when retargeting F_PIX |
| **w-mem** | Bank capacity (held fit blocker) — unchanged by fps |
| **w-scaler** | 540→720 map; no fps change |
| **Parent** | Measure PMS fps limitation; E2E 30 fps cast when device lives |

---

## 6) One-line answers

1. **PMS 24 cap?** Not in URL today; **plausible** via `video.frameRate` upperBound like width — **unproven here**. Local fps= does not save decode.  
2. **30→24 quality?** Judder; OK as opt-in, **bad as silent default** for TV.  
3. **30 fps need?** ARM ≤33.33 → **960 fails**; **fps-aware lower tier** (854/624) or kill copy.  
4. **clk_pix?** Fit **29.7 stays**. True 30 Hz glass needs **37.125** (or 74.25@60). STA prereg must gain PIX30 floor before that fit.
