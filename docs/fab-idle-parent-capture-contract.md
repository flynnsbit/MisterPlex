# FAB_IDLE parent capture contract (pre-registered)

**Lane:** w-osd · **Commit family:** `a3761b0e` / `a6864e58` + signature follow-up  
**Default:** `PLEX_FAB_IDLE` **undefined** → bit-identical idle-off path vs macros-at-reset  
**Parent owns all device capture.** This is the enable path + PASS/FAIL numbers
**before** any glass photo is taken.

---

## 1. How to turn it ON (integration build only)

| Knob | Where | Value |
|------|-------|-------|
| **Macro** | `fpga/Plex_MiSTer/Plex.qsf` | Uncomment: `set_global_assignment -name VERILOG_MACRO "PLEX_FAB_IDLE=1"` |
| **Alternate** | fit script / `VERILOG_MACRO` env for remote build | `PLEX_FAB_IDLE=1` |
| **Runtime conf** | none required for pixels | Fabric forces `has_frame_chrome=0` |
| **ARM conf (optional, for log proof)** | misterplexd conf | `CHROME_PLANE=1` — only affects ARM skip log when PLXO `chrome_hw` is seen |

**Macros at reset (OFF):** `has_frame_chrome=1`, no idle takeover, no cyan, no screensaver —
chrome still in HDMI path (1-cycle delay) but transparent. Matches “default OFF /
nostub-safe” for integration bit-identity of *idle behaviour*.

**w-clock coordination:** Fabric idle composites in **HDMI pixel space**
(`hdmi_width`/`hdmi_height` after ascal). For a **true 1280×720 canvas**:

```
# MiSTer /media/fat/MiSTer.ini  [Plex] or global:
video_mode=0
video_mode_ntsc=0
video_mode_pal=0
```

(`0` = 1280×720@60 per `docs/display-resolution.md` / README). Soft-reboot after
ini change. If the beam is still 480p-class, chevron math still runs but **ACTIVE
geometry and cyan mark size in capture space change** — agree video_mode=0 with
w-clock before the exclusive fit.

Chrome does **not** program video_mode. w-clock owns the mode; we own the plane.

---

## 2. Pre-registered visual expectation (PASS picture)

When **ON** + HDMI mode 1280×720:

| Element | Spec |
|---------|------|
| **Background** | Dark blue-grey `#1F2326` full active raster |
| **Chevron** | Plex amber `#E5A00D`, size `min(W,H)/3` = **240 px**, **drifts** (screensaver) |
| **Motion** | `idle_phase++` every HDMI **vsync** (~60 Hz). Triangle-wave drift over ~20 s period (`phase % 1200`). Visible shift in a few seconds. |
| **Fabric signature (unambiguous)** | **Cyan `#00C8FF` L-brackets** top-left + bottom-right: 64×12 bars. **ARM `idle_screen.hpp` never emits this colour.** |
| **Not present** | Boot `#` glyph (PLXC enable forced 0 under FAB_IDLE) |
| **Dimensions** | Content filled to HDMI active; with `video_mode=0` expect ~1280×720 picture content (capture may letterbox into 1920×1080 grabber) |

### ARM idle (control — must NOT match PASS)

**Parent measured on glass 2026-08-03** (core `d1b24e0c`, `video_mode=0`, grabber chain):

```
MEAN=14.4  STD=24.4  ORANGE_PX=12889  CYAN_PX=0  ACTIVE=923x717  TRY=1  rc=0
```

Visual: ARM orange chevron + STOPPED overlay 0:00/0:00, dark canvas, letterboxed in
1920×1080 grabber. **CYAN_PX=0 on this exact capture chain** — closes the false-GREEN trap.

| Element | ARM today |
|---------|-----------|
| Colours | Same amber/bg (`kIdleFg/Bg`) — **colour alone is not proof** |
| Canvas | 480p-class content letterboxed → measured **ACTIVE≈923×717** @ mode 0 |
| Cyan corners | **Never** — measured **CYAN_PX=0** |
| Motion | Only if daemon screensaver loop runs; **stops if daemon stopped** |
| Log | `media: idle screen painted` / DDR publish — **not** fabric skip line |

**Second discriminator (parent):** fabric native 1280×720 canvas should grow **ACTIVE**
toward the full raster vs control **923×717**. Colour (CYAN) and geometry (ACTIVE)
must **agree**. If they disagree, report both — do not green on one alone.

---

## 3. Capture commands + numeric PASS / FAIL

Grabber: always `scripts/hdmi_capture_idle.sh` (never bare ffmpeg 1-frame).

```bash
# A) Dual snap ~3s apart (motion + signature)
scripts/hdmi_capture_idle.sh docs/agent-evidence/fab-idle-t0.png
sleep 3
scripts/hdmi_capture_idle.sh docs/agent-evidence/fab-idle-t1.png

# B) Strongest ARM-out proof: stop daemon, capture still moves
ssh root@${MISTER_HOST:-192.168.1.183} 'killall misterplexd || true'
sleep 2
scripts/hdmi_capture_idle.sh docs/agent-evidence/fab-idle-nodaemon.png
# Optional: restart daemon later
```

### PASS (all must hold)

| Metric | PASS | Rationale |
|--------|------|-----------|
| **CYAN_PX** | **≥ 2000** | Fabric L-brackets; control arm measured **0** |
| **ORANGE_PX** | **≥ 500** | Chevron present (control had 12889 — fabric may differ) |
| **MEAN** | **12 .. 80** | Control was 14.4; not black (0), not flat ≥100 |
| **STD** | **> 5** | Not uniform field (control 24.4) |
| **ACTIVE** | **Wider than control 923×717** toward full 1280-class | Geometry discriminator |
| **Motion** | t0 vs t1: **ORANGE centroid or ACTIVE_X shifts**, or visual chevron moved | vsync phase drift |
| **Daemon stopped** | snap still has CYAN+ORANGE+motion | ARM not required for picture |

### FAIL (any)

| Observation | Meaning |
|-------------|---------|
| CYAN_PX = 0 and ORANGE high | Likely **ARM idle**, not fabric (or macro OFF) |
| MEAN=0 STD=0 | Black / grabber — not a fabric PASS |
| CYAN high, ORANGE=0, static | Signature only / broken chevron |
| Picture dies when daemon killed | Fabric idle **not** on (macro OFF or elided) |
| Post-fit `u_plex_chrome` M10K=0 | Elided — void fit (w-nostub hierarchy gate) |

**ARM-lookalike false GREEN this contract rejects:**
- Prior: `MEAN=23 ORANGE_PX=20161` no cyan (daemon idle, pre-mode-0)
- **Mode-0 control (binding):** `MEAN=14.4 ORANGE_PX=12889 CYAN_PX=0 ACTIVE=923x717`

---

## 4. Prove ARM is out of the loop

### Strongest (preferred)

1. FAB_IDLE RBF loaded, `video_mode=0`
2. **`killall misterplexd`** (or never start it)
3. Capture: **CYAN_PX≥2000**, orange chevron, **motion across 3s**
4. ⇒ No ARM process ⇒ cannot be daemon paint

### If daemon must stay up

| Check | Expect |
|-------|--------|
| Log line **present** | `media: idle fabric plane=1 skip ALL ARM paint` |
| Log line **absent** | `media: idle screen painted` / `idle paint DDR failed` |
| Conf | `CHROME_PLANE=1` **and** PLXO `chrome_hw` (fail-closed otherwise) |
| Note | Without PLXO, daemon may still paint DDR while fabric **covers** HDMI — pixels on glass can still be fabric; log proof needs plane live |

FAB_IDLE alone covers HDMI (`idle_en` replaces `din`) even if ARM writes banks.
Daemon-stop test removes ambiguity.

---

## 5. Synthesis / elision

- `u_plex_chrome` remains on: ascal → shadowmask → **chrome** → osd → pins
- Boot still toggles `list_we` (anti-elision); under FAB_IDLE PLXC **enable=0**
- w-nostub: post-fit hierarchy rows **non-zero**; elision guard GREEN

---

## 6. Sim evidence (pre-device)

```
tests/unit/test_plex_chrome_idle720_rtl_sim.sh
  RED  FAULT_480P_GEOM     mon≠720p
  GREEN TL/BR=00C8FF, chevron amber, ss motion, subsample cyan+amber
```

---

## 7. Unknowns (honest)

- Capture CYAN_PX after MJPEG scale into 1920×1080 — threshold 2000 is pre-reg;
  if JPEG slop kills cyan, lower bound may need one recal once, with both t0/t1.
- Exact ORANGE_PX at capture resolution is **not** claimed as a single number.
- ARM ms removed: still unknown until profiled; daemon-stop test proves
  **zero ARM dependency for the picture**, not a ms figure.
