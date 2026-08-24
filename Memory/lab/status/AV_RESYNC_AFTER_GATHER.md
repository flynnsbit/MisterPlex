# A/V resync after a faster present (L56 item 3)

**Status:** DESIGN only. **No knob PR.** Branch B / skip-ARM-memcpy has **not**
moved unique fps. **P3-720P24 IN_PROGRESS / pfps FAIL.** Soft-skip ≠ PASS.

Freddo: a faster blit blows A/V tuned for the slow path
(`FREDDO_YUV_LAST_RGB.md` §3). **Do not retune until unique pfps actually moves.**

## Current defaults (do not change)

| Knob | Default | Call sites |
|------|--------:|------------|
| `AV_RESYNC_DROP_MS` | **80** (`resyncDropMs_`, `kDefaultResyncDropMs`) | `main.cpp` conf; `avDecide`; OSD `O[1]` on→80 / off→0 |
| `AV_PRESENT_LEAD_MS` | **40** (`presentLeadMs_`) | `main.cpp` conf; `avDecide` lead |
| `AUDIO_DELAY_MS` | **0** | `main.cpp` → FFmpeg `adelay` |
| `Video delay` / `av_offset` | **0** (`kOsdAvOffsetDefaultMs`) | OSD `O[9:6]`; live `frameMs += avOffsetMs`; conf `AV_OFFSET_MS` |

`avDecide`: drop when `drift > dropMs` (0 = hold-only). `maxDropRun=1` → DROP_MS=80
on a ~15 fps present **half-drops**.

## G-AV facts (dirty-main `docs/PHASE_BACKLOG.md`)

- **G-AV8 PASS:** pace off audible `(written − queued)`. Mid-play ring ~35 kB ≈ **185 ms**.
- **G-AV9 PASS:** `Video delay` **0 ms** eyes-on (`osd lo=0x0000` / `av_offset_ms=0`).
  Old **+80** was submitted-byte ring depth — **not transferable**.
- **G-AV11 PASS:** grabber **−215 ms** at the same in-sync setting. Relative/drift
  only; **+215** to treat as absolute; never bake without eyes-on.

## Do not copy from True480 / slow 720p memcpy

- `Video delay +80` (G-AV4 old clock) · `AUDIO_DELAY_MS=60` · `AUDIO_CLOCK_PPM=+685`
- Grabber **−215** as a product constant
- **`AV_RESYNC_DROP_MS=80` leftover** — unique **7.80** was this (every-other-frame).
  `0` → **15.2–15.47** still **FAIL** (gate ≥23.9)

## Re-measure only after gather moves unique fps

Trigger: Branch B lands **and** presented unique **moves** (not blit rate, not F).

1. Unique pfps on `real720p_1500k` — gate **≥23.9**. Historical **15.47 on e @
   DROP_MS=0 is FAIL**. **F=32.31 is producer ceiling only.** 200 fps blit ≠ 24 unique.
2. DROP_MS leftover: if still 80, half-drop fakes a fps FAIL. Measure at **0** first.
3. Eyes-on lipsync at delay/adelay/LEAD **0/0/40** (G-AV9). Do not start from +80.
4. Grabber flash↔beep is **relative**; apply **+215** (G-AV11); eyes-on before any new constant.
5. Ring / G-AV8 servo still ~100 ms target? Faster present must not starve LEAD=40.

**Lipsync ≠ unique-fps.** Two gates. Conf/OSD retune cannot buy 23.9. Host knobs exhausted.

P4-DISPLAY / P4-720P-MIX stay **TODO**. No RGB565. No `MPX_FABRIC_DIRECT` enable. No play this card.
