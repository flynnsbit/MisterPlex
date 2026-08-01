# Glass success criterion — user bug #2 (falsifiable)

**Owner:** w-osd-hires · **Scorer:** parent only (HDMI capture)  
**Design:** `docs/plex-chrome-plane-rtl-proposal.md`  
**Sim gate (host):** `tests/unit/test_plex_chrome_sim.cpp` — bank RED / fabric GREEN  

This is the **only** claim that closes bug #2. Bank F1 chrome (daemon today) is **not** PASS.

---

## 0. Budget baseline this criterion assumes

| Source | Use |
|--------|-----|
| **Deployed RBF `8fdf440f` = w-fit-integ `remote_out/fit-t7b-prog480/`** ALM **23,585** · M10K **465/553** · DSP **44** | **ONLY** binding baseline |
| `output_files/Plex.rbf` (`2890baac`) | **BANNED** — never cite its reports |
| **PRODUCT_NO_STUB** (enabler) | **−9,217 ALM / −268 M10K** → M10K **~197 used / ~356 free** |

Chrome V1 prereg: **M10K +12±4 (cap 24) · ALM +2.5k±1k · DSP 0**.  
HDMI domain: **`pll_hdmi` / `clk_hdmi`** (STA Fmax **164.93 MHz**, slack **+0.669 ns** on t7b).

---

## 1. Pre-registered numbers (publish before capture)

### Mode A — MiSTer.ini forced **1920×1080** (user-authorised lab)

| ID | Quantity | Product bank path (FAIL) | Fabric `plex_chrome` (PASS) |
|----|----------|--------------------------|-----------------------------|
| **G-CELL-H** | Glyph solid-block `#` bbox height in **output px** | **36 ± 2** (= 16 bank rows × 1080/480) | **32 ± 1** (= 8 × bodyScale4) |
| **G-CELL-W** | Same block bbox width | **49 ± 3** (16 × 1920/624) | **32 ± 1** |
| **G-RUN** | Fraction of maximal near-white H-runs with `len % 4 != 0` inside ROI | **> 0.5** (irregular NN stretch) | **= 0** |
| **G-EDGE** | 10–90% luminance transition width on a vertical stem (horizontal sample) | often **≥ 3 px** if any filter; NN may be 1 px but **wrong cell** | **≤ 2 px** AND G-CELL-* PASS |

**bodyScale at 1080p** = half-even round(1080/240) clamp 2..8 = **4**  
(`mister_video_mode.hpp` / `plex_chrome_sim::fabricBodyScale`).

### Mode B — **640×480** output (optional control)

| ID | Fabric PASS |
|----|-------------|
| G-CELL-H/W | **16 ± 1** (scale 2) |
| G-RUN | 0 bad runs vs scale 2 |

At 480p the bank path can **look** acceptable (near 1:1 with bank 480). **Do not** score PASS from 480p alone — user complaint is 1080p softness.

### Mode C — regression freeze (no chrome plane)

Working core class **`c5382bee` / current product**: pause still shows transport panel; **no black frame / no hang**. Bank path remains fail-closed when `chrome_hw=0`.

### Mode D — ARM cost (PRESENT_PROFILE) — must stay **FLAT**

Fabric plane **removes** per-frame `renderOverlay` bake when `chromePlaneLive()`; it must **not** add ARM work.

| ID | Quantity | Prediction |
|----|----------|------------|
| **P-FLAT** | `PRESENT_PROFILE=1` paired `*_us_p` / `*_cpu_us_p` table (`media_player.cpp` emit) | **overlay_us_p** and **overlay_cpu_us_p** ≤ baseline (plane0 bake) or drop toward **~0** on pause path when plane=1; **no new block** appears; **ddr_*** / **pixel_*** wall-vs-CPU shape stays flat ±10% noise |
| **P-BUG** | Any sustained **rise** in overlay or total present CPU with plane=1 | **FAIL** — plane must offload, not relocate paint to ARM |

Baseline capture: same title, pause HUD visible, `PRESENT_PROFILE=1`, 30s log before/after ONE-fit daemon+RBF.

---

## 2. How parent measures (exact commands)

Device + HDMI grab are **parent-only**. After ONE-fit deploy of RBF with `plex_chrome` + daemon that writes PLXC:

```bash
# 1) Force 1080p in MiSTer.ini (lab), menu bounce, load Plex RBF once.
# 2) Cast/pause so transport chrome is visible (or PLXC test pattern '#').
# 3) Capture one frame:
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 1 -y files/device-evidence/chrome_glass_1080.png
# 4) Score ROI (parent tool or manual):
#    - Find near-white connected component of test '#' or 'I' stem
#    - Report bbox w/h, and h-run mult-of-4 rate
# Expected PASS: G-CELL-H=32±1, G-CELL-W=32±1, G-RUN=0
# Expected FAIL on pre-plane daemon 9ce2c2d1 bank path: see overlay_lowres_stopped_*.png
```

Host pre-score (no device) — already gated:

```bash
cd .worktrees/w-osd-hires   # or repo root on branch
make "$PWD/build/test_plex_chrome_sim" && ./build/test_plex_chrome_sim; echo "true rc=$?"
# GREEN true rc=0
# Embedded RED: bank 624×480→1080 bbox 49×36 hBad=36/36
```

Prove RED alone:

```bash
# optional: .agent-work prove_bank_red → true rc=1 when claiming bank is fabric-sharp
```

---

## 3. What is **not** a PASS

| Claim | Why rejected |
|-------|----------------|
| Idle banner looks crisp | Wrong UI; may be bank path at small text |
| `plane=0` bank 12×16@2 “sharper than 320” | Still stretched by ascal — glass proof of low-res remains |
| OCR / `readback_overlay_text.py` | False PAUSED on blank panel — **banned** |
| Soft-skip rc=77 | Not a pass |
| 480p-only grab | Does not stress user mode |

---

## 4. ONE-fit cargo (coordinate)

| Lane | Deliverable in same RBF |
|------|-------------------------|
| **w-fit-1** | `PRODUCT_NO_STUB=1` (gate stub, **tie stub_busy=0**, no telem bit shift) |
| **w-osd-hires** | `plex_chrome` in `sys_top` after shadowmask; `files.qip` entry; `chrome_hw` |
| **w-geom** | content window / fabric scaler (ARM offload) if ready |

**Freeze sim green** (`test_plex_chrome_sim` + unit rollcall) **before** slot opens.  
**No fit request from this worker** while Quartus hold is ON.
