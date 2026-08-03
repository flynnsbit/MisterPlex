# w-osd × w-clock — single capture sequence (ACTIVE expectations)

**Agree before exclusive fit.** Do not change `MiSTer.ini` and the core macros in
the same step without a capture between them.

## Two independent geometry knobs

| Knob | Owner | What it changes |
|------|-------|-----------------|
| **`[Plex] video_mode` in MiSTer.ini** | Operator / parent | HDMI/ascal **output** size → `hdmi_width`/`hdmi_height` that **plex_chrome** uses |
| **`PRESENT_MULTI_PIXEL`** | w-clock (`8003ef89`) | Core **beam DE** 1280×720 when `use_ext` (has_frame && !force bars). Same-clock fps_eff ≈ 16.16 Hz — **not** CEA 24/60 refresh |

Chrome composites **post-ascal on `clk_hdmi`**. Idle/chrome canvas size follows
**ini video_mode**, not core Template DE. w-clock multi-pixel does **not** by
itself make the OSD plane 720p if HDMI mode stays 480p-class.

`PLEX_FAB_IDLE` forces `has_frame_chrome=0` → idle takeover; core `use_ext` may
stay false (Template DE) while fabric still fills the **HDMI** raster.

## Single sequence (one change per step)

### Step 0 — Control (MEASURED — binding reference)

Parent already ran this with beam at `video_mode=0` and core `d1b24e0c` (2026-08-03):

```
MEAN=14.4  STD=24.4  ORANGE_PX=12889  CYAN_PX=0  ACTIVE=923x717  true rc=0
```

- RBF: nostub-class / macros **OFF** (`d1b24e0c`)
- Beam: **already** `video_mode=0` on device (backup `MiSTer.ini.bak-parent720`, restore=8)
- **CYAN_PX=0** on the real capture chain — fabric PASS cannot be the daemon
- **ACTIVE=923×717** = 480p-class canvas letterboxed into 720p raster (second discriminator)
- Pre-reg control HIT 4/4 — cite these numbers, not the older MEAN=23/ORANGE=20161 pair

### Step 1 — Fabric idle core (beam already mode 0 — do not re-touch ini)

- Fit/enable: **`PLEX_FAB_IDLE=1` only** (no `PRESENT_MULTI_PIXEL`, no `PLEX_FAB_CHROME`)
- **Leave `video_mode=0` alone** — parent already set it so the only delta is the core
- Expect vs control:
  - **CYAN_PX≥2000** (control was 0)
  - ORANGE present; chevron **drifts** (t0/t1)
  - **ACTIVE grows past 923×717** toward full 1280-class if native fabric canvas lands
  - CYAN and ACTIVE should **agree**; mismatch = investigate, not green

### Step 2 — (already done on device) video_mode=0

Parent completed beam switch before the fit. Re-run only if ini was restored to 8.
If someone restores mode 8 mid-session, re-do control before scoring fabric.

### Step 3 — Optional separate fit: multi-pixel core DE

- **New fit:** `PRESENT_MULTI_PIXEL=1` (+ `PRESENT_PX_PER_CLK=2`) per w-clock checklist
- Prefer **FAB_IDLE off** for this step if scoring video beam; or accept idle still paints HDMI
- Expect when `use_ext`: core DE 1280×720 (w-clock). Chrome still keys off HDMI after ascal
- Do **not** attribute Step 2 ACTIVE change to this macro if ini already set mode 0

### Playback chrome demo (orthogonal fit)

- Fit: **`PLEX_FAB_CHROME=1`**, not IDLE
- Ini: prefer `video_mode=0` so bottom panel sits on 720p
- Expect: magenta TR+BL, STOPPED bar, **no** cyan — see `fab-chrome-parent-capture-contract.md`

## What parent should NOT do

- Change ini + two macros + daemon conf in one deploy
- Use `killall` (lab ban) — **`kill <PID>`** only
- Claim 720p60 refresh from multi-pixel at 20 MHz (w-clock: fps_eff≈16.16 until faster `clk_pix`)

## Sign-off

| Lane | Owns | Agrees |
|------|------|--------|
| w-clock | beam DE, `present_video_timing_720p`, serializer | Core 1280×720 under `PRESENT_MULTI_PIXEL`+`use_ext`; Template 529 when OFF |
| w-osd | chrome/idle plane in HDMI space | Canvas = `hdmi_width/height`; idle/chrome macros default OFF |
| w-scaler | bank read geom / PLXG | Not HDMI mode; PLXG must not steal PLXC +0x130 |

If ACTIVE after Step 2 is still 480p-class with mode 0 confirmed, **unknown** until parent
quotes ini readback + capture — do not blame chrome sizing without that evidence.
