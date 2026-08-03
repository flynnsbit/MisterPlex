# Chrome / idle geometry contract (w-osd × w-clock × w-scaler)

**Lane:** w-osd · **No fit · No device**  
**Macro:** `PLEX_FAB_IDLE` default **undefined/OFF** — integration fit bit-identical to
nostub-proven path when macros at reset (chrome still in path; idle takeover OFF).

## 1. Two geometry domains (do not conflate)

| Domain | Owner | Units | What it programs |
|--------|-------|-------|------------------|
| **HDMI scanout** | MiSTer video_mode / ascal / `hdmi_width`·`hdmi_height` | output pixels | Where `plex_chrome` composites |
| **Bank / content window** | w-scaler `present_geom_latch` (PLXG) + w-mem store | coded + display + window | DDR read map, pillar/letterbox |

**`plex_chrome` composites only in HDMI pixel space.** It takes
`HDMI_WIDTH`/`HDMI_HEIGHT` from `sys_top` (`hdmi_width`/`hdmi_height` post-ascal).
It does **not** read PLXG `coded_w`/`display_w`. A 1280×720 idle means the **HDMI
mode** is 1280×720 (or ascal outputs that active area); chrome then sizes the
chevron as `min(W,H)/3` centered.

w-scaler's `present_geom_latch` `display_w`/`display_h` / content window describe
**where video sits inside the frame store**, not the OSD plane. If those disagree
with HDMI active size, video letterboxes — chrome still paints full HDMI raster
when `idle_en`.

## 2. ABI ownership (collision — surface, do not silent-pick)

| Magic | Offset (doorbell page) | Owner | Status |
|-------|------------------------|-------|--------|
| **PLXC** `0x504C5843` | **+0x130** | w-osd chrome list ctrl | **Landed** (`mailbox_abi_spec.hpp`) |
| **PLXO** `0x504C584F` | **+0x138** | w-osd chrome telemetry | Landed |
| list payload | **+0x140** | w-osd cmds | Landed |
| **PLXG** `0x504C5847` | proposed +0x130 in scaler RTL comment | w-scaler geom | **CONFLICT** |

**Resolution required before dual-wire:** PLXG must **not** use +0x130. Proposed
free slot after chrome list: **+0x280** (after 48×8B list ≈ +0x140..+0x27F), or
another page owned by w-mem. w-osd will not move PLXC; it is already in ARM + RTL.

## 3. Native 1280×720 fabric idle

| Item | Value |
|------|-------|
| Canvas | `HDMI_WIDTH=1280`, `HDMI_HEIGHT=720` |
| `body_scale` | half-even H/240 → **3** @720 |
| Logo size | `min(W,H)/3` → **240** |
| Origin | `((W-size)/2, (H-size)/2)` → **(520, 240)** |
| Stroke | `max(1, size/5)` → **48** |
| Colours | bg `24'h1F_23_26`, chevron `24'hE5_A0_0D` |
| **Fabric signature** | cyan `24'h00_C8_FF` L-brackets TL+BR (64×12) when `idle_sig_en` — **ARM never paints** |
| ARM | zero idle pixels when plane live (`chromePlaneLive`) |
| Memory | list 1–2 M10K; font/idle **0** M10K (comb) |

Parent capture PASS/FAIL: **`docs/fab-idle-parent-capture-contract.md`**.

## 4. Multi-pixel (w-clock)

From w-clock `MULTI_PIXEL_PRESENT_DESIGN.md` + `present_beam_ppc`:

- Pre-ascal PPC widens **clk_sys** store read. Chrome sits **post-ascal on
  `clk_hdmi`**.
- **Interface assumption:** product chrome default `PX_PER_CLK=1` (one RGB per
  `clk_hdmi`). If N-pixel packing ever reaches the chrome insertion point,
  instantiate `PX_PER_CLK=N` (module supports 1|2|4); hit/idle evaluated per lane
  at `hx0+lane` — no shared single-x assumption.
- fab-pace is **frame-level** (vsync); PPC-invariant. Idle **phase** advances on
  vsync edges when `PLEX_FAB_IDLE` enables fabric phase (not ARM doorbell).

## 5. fab-pace × idle

| Signal | Idle use |
|--------|----------|
| `vsync` rising on `clk_hdmi` | Fabric `idle_phase++` (screensaver drift) when FAB_IDLE |
| `has_frame` | `idle_en = !has_frame && mode!=3` |
| pace `cnt_*` | Parent-readable present stats — separate from chrome |

Default: `PLEX_FAB_IDLE` off → `has_frame_chrome=1` (no idle takeover), phase=0,
mode=logo (unused).
When on without CDC'd present flag: `has_frame_chrome=0`, **mode=screensaver (2)**,
`fab_phase_en=1` so the chevron **drifts every vsync** — fabric-generated moving
1280×720 pattern, ARM touches zero pixels (integration visual milestone).
Integration later replaces force-0 `has_frame` with CDC of
`present_core.stat_has_frame` / pace `has_frame`.

## 6. Synthesis survival

`plex_chrome` stays on the HDMI path (ascal → shadowmask → **chrome** → osd)
regardless of `PLEX_FAB_IDLE`. Macro only changes **control** (`has_frame`,
phase source). Post-fit hierarchy rows for `u_plex_chrome` must be non-zero;
elision guard remains the gate.

## 7. Parent device verify (integration RBF)

```bash
# Build/fit with +define+PLEX_FAB_IDLE=1 (parent owns fit). HDMI mode 1280x720.
DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh
# Daemon may run; with CHROME_PLANE conf + plane live, log must contain:
#   idle fabric plane=1 skip ALL ARM paint
# Capture (never bare ffmpeg 1-frame):
scripts/hdmi_capture_idle.sh docs/agent-evidence/idle720-live.png
# Score: ORANGE_PX > 0, MEAN not full-black; chevron visible on dark canvas.
# Optional: read PLXO mon W/H == 1280/720 once DDR loader is arbitrated.
```

**Unknown until device:** exact ORANGE_PX at capture scale; ARM ms removed
(profile plane=0 vs plane=1 idle path).


## 8. Capture sequence with w-clock

See **`docs/fab-idle-video-mode-sequence.md`** (single sequence, ACTIVE per step).
Playback chrome: **`docs/fab-chrome-parent-capture-contract.md`** (`PLEX_FAB_CHROME`).
