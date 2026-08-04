# Chrome / idle geometry contract (w-osd × w-clock × w-scaler)

**Lane:** w-osd · **No fit · No device**  
**Macro:** `PLEX_FAB_IDLE` default **undefined/OFF** — integration fit bit-identical to
nostub-proven path when macros at reset (chrome still in path; idle takeover OFF).

## 1. Three geometry domains (do not conflate)

| Domain | Owner | Units | What it programs |
|--------|-------|-------|------------------|
| **STORAGE** | w-mem bank / ARM decode | coded display 960×540, 777 600 B | DDR payload only — **never** PLXC canvas |
| **CORE_DE** | core raster → ascal | near-term 960×540 DE | Pre-ascal video; chrome only if moved pre-ascal |
| **HDMI_OUT** | MiSTer `video_mode` + ascal | post-ascal 1280×720@60 | **Where product `plex_chrome` paints** |

**Product wiring (`sys_top.v`):** `ascal → shadowmask → plex_chrome → osd → pins`.
Chrome is on **HDMI_OUT**, not CORE_DE. Near-term fit: core emits 960×540; ascal
upscales to glass 1280×720; chrome layout uses **1280×720** paint-beam ports.

It does **not** read PLXG `coded_w`/`display_w`. PLXG describes bank/window, not
the OSD plane. Soft cost if chrome ever moves pre-ascal: ascal upscales glyphs
~1.333× — refused for product unless measured fit forces it
(`docs/fab-chrome-paint-domain.md`).

w-scaler `present_geom_latch` content window is STORAGE/present, not chrome.

## 2. ABI ownership (collision — surface, do not silent-pick)

| Magic | Offset (doorbell page) | Owner | Status |
|-------|------------------------|-------|--------|
| **PLXC** `0x504C5843` | **+0x130** | w-osd chrome list ctrl | **Landed** (`mailbox_abi_spec.hpp`) |
| **PLXO** `0x504C584F` | **+0x138** | w-osd chrome telemetry | Landed |
| list payload | **+0x140** .. **+0x2BF** | w-osd cmds (48×8B) | Landed |
| **PLXG** `0x504C5847` | **+0x800 FIXED** | w-scaler / w-mem present geom | **FORCED MAP** |

**FORCED MAP (rd-duck audit):** PLXC owns **+0x130**. PLXG is **FIXED +0x800** (independent of MAX_CMDS; was +0x2C0/@48 then briefly +0x4C0)
(= list_base + 48×8). `static_assert` in `mailbox_abi_spec.hpp`. Any scaler/mem
RTL still decoding geom at +0x130 is a hard integration blocker.

## 3. Native 1280×720 fabric idle

| Item | Value |
|------|-------|
| Canvas | `HDMI_WIDTH=1280`, `HDMI_HEIGHT=720` (**H_ACTIVE×V_ACTIVE only**) |
| Totals | Chrome **does not** read H_TOTAL/V_TOTAL. CORE_DE compact 720p24 is **1600×750 @ 28.8 MHz** (H_BLANK=320). Retired compact 1650@29.7; CEA VIC4 1650@74.25 still legitimate elsewhere. |
| `body_scale` | half-even H/240 → **3** @720 |
| Logo size | `min(W,H)/3` → **240** |
| Origin | `((W_ACTIVE-size)/2, (H_ACTIVE-size)/2)` → **(520, 240)** — never `(H_TOTAL-size)/2` (that is 680 @1600) |
| Stroke | `max(1, size/5)` → **48** |
| Colours | bg `24'h1F_23_26`, chevron `24'hE5_A0_0D` |
| **Fabric signature** | cyan `24'h00_C8_FF` L-brackets TL+BR (64×12) when `idle_sig_en` — **ARM never paints** |
| ARM | zero idle pixels when plane live (`chromePlaneLive`) |
| H-blank budget | Product on HDMI_OUT. Pre-ascal CORE_DE 720p24: EOL **1** cycle vs **320** blank; list jam ≤48 still fits. **Not blocking.** |
| Memory | **M10K LB 6** (list 2+2 + CDC 2; font/idle 0). Not bit-ceil. See `plex_chrome.sv` header: handbook max width 40b; prior 3–5 EST retired. Physical blocks **unmeasured** (no fit). |

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
Post-fit hard gate: **`docs/fab-idle-postfit-gate.md`**.

## 9. Product path (parent measured) — 960×540 source → 1280×720 **output**

Standing target (all measured on device; margins include sws):

```
PMS  -> Constrained Baseline 960×540  (videoProfile=baseline, pinned)
ARM  -> decode + minimal sws + bank copy ≈ 34.50 ms vs 41.667  (+7.16)
FABRIC -> upscale 960×540 → native 1280×720 raster on glass
```

| Layer | Resolution | Owner |
|-------|------------|--------|
| Coded / bank | **960×540** | w-mem store + w-scaler read geom |
| HDMI / glass | **1280×720** | w-clock `clk_pix` + video_mode=0 + ascal |
| Chrome / idle | **HDMI space only** | w-osd — **never** 960×540 |

**Hard rule for ARM PLXC:** `BuildArgs.outW/outH` and `chromeOutW_/H_` default **1280×720**.
Do **not** set them to coded 960×540 — that would place the STOPPED bar in the
wrong place under a 720p HDMI beam. Fabric idle chevron math uses `HDMI_WIDTH/HEIGHT`
from the beam, not coded size.

**Honesty label:** this ships **720p output**, not 720p source. True 1280×720 source
needs DMA (w-path) to drop the 14.97 ms copy.

**SPS (parent measured):** coded height **544** with bottom crop → **540 display** before ARM bank copy. Product chrome/idle stay on **HDMI 1280×720**; bank is **960×540 display** (777,600 B). Bitstream/fabric-decode paths must size for **544**.

**Parent glass score for this path:**  
`docs/fab-playing-parent-capture-contract.md` + `scripts/hdmi_score_pair.sh`  
(not the idle cyan contract).

## 10. rd-duck fit audit checklist (w-osd claims)

- [ ] `PLEX_FAB_IDLE` / `PLEX_FAB_CHROME` **undefined** in shipping QSF (default OFF)
- [ ] `u_plex_chrome` on path: ascal → shadowmask → chrome → osd
- [ ] `make post-fit-fab-idle` rc=0 (M10K/regs/ALUTs + stuck list)
- [x] PLXG **not** at +0x130 (PLXC owns it); PLXG = FIXED +0x800 in ABI
- [ ] Glass: vs control `CYAN=0 ACTIVE=923×717` → fabric `CYAN≥2000` + ACTIVE growth + motion
- [ ] ARM-out: `kill <PID>` still cyan+motion (partial: cyan no motion = phase stuck)
