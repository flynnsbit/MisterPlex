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

### Step 0 — Control (no geometry claim)

- RBF: nostub-class / macros **OFF** (`d1b24e0c` family)
- **Do not touch** `MiSTer.ini`
- Capture: `scripts/hdmi_capture_idle.sh …`
- Expect: daemon idle if misterplexd running — **CYAN_PX≈0**, ORANGE high possible  
- Record **ACTIVE=…** as lab baseline (often letterboxed inside 1920×1080 grabber)

### Step 1 — Fabric idle only (no ini change)

- Fit/enable: **`PLEX_FAB_IDLE=1` only** (no `PRESENT_MULTI_PIXEL`, no `PLEX_FAB_CHROME`)
- **Still no ini change**
- Expect: cyan TL+BR, drifting amber chevron, **CYAN_PX≥2000**
- **ACTIVE outer box** may match Step 0 (same HDMI mode); content is fabric
- If CYAN PASS here, geometry of marks follows **current** `hdmi_width/height`

### Step 2 — True 1280×720 HDMI canvas (ini only)

- Same FAB_IDLE RBF
- Set **only**:
  ```
  video_mode=0
  video_mode_ntsc=0
  video_mode_pal=0
  ```
  Soft-reboot / core reload after ini
- Expect: fabric idle still; chevron `size=min(W,H)/3` with W/H≈1280/720; cyan marks on 720p raster
- **ACTIVE** should move toward **1280×720-class** content (grabber may still report 1920×1080 sensor with letterbox — score ORANGE/CYAN, not only ACTIVE string)
- Geometry delta vs Step 1 is from **ini**, not from a new RBF

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
