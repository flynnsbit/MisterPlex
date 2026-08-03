# Source-vs-output geometry defect-class sweep (w-clock)

**Date:** session after bank-predicate `rt_cw_cl >= 1280` catch  
**Scope:** `present_core`, `present_npx_path`, `present_pix_rate_match`, `present_beam_ppc`,
`present_video_timing_720p`, `clk_pix` / `CLK_VIDEO` mux in `Plex.sv`  
**Class under hunt:** code that keys on **width ≥ 1280** or treats **“720p work” ≡ “1280-wide source”**  
**Product path (parent-measured):** PMS **960×540** source → fabric **1280×720** glass  

---

## Executive answer

| # | Site | Reads | Correct for 960→1280? | Verdict |
|---|------|--------|------------------------|---------|
| 1 | `present_beam_ppc` H_DE=1280 / V_ACTIVE=720 | **Output** glass | Yes — glass is 1280×720 | **OK** (output) |
| 2 | `present_video_timing_720p` CEA 1650×750 | **Output** totals | Yes | **OK** (output) |
| 3 | `mp_mode_ok` == 1280×720×1650×750 | **Output** package | Yes | **OK** (output) |
| 4 | `present_pix_rate_match` F_SYS/F_PIX/PPC | **Clocks only** | Yes — not geometry | **OK** (not 1:1 source/out) |
| 5 | `present_npx_path` FIFO/serializer | Domain bridge | Yes — no W key | **OK** (clean) |
| 6 | `Plex.sv` CLK_VIDEO/CE_PIXEL mux | Clock select | Yes | **OK** (clean) |
| 7 | **`mp_store_x/y` identity clamp** | Glass→**store** as 1:1 | **NO** | **HIT — product-blocking** |
| 8 | Contracts/`H_OWNERSHIP` “identity when native 1280” / `content_geometry:1280×720` | Docs | Conflates glass & source | **HIT — class in paper** |
| 9 | `ddr_frame_store` N-wide `src_x0..+PPC-1` consecutive | Store/coded | Assumes **adjacent store px** | **Constraint on scaler** (not a 1280 predicate) |
| 10 | Coded **544** vs display **540** | Settled by SPS (parent) | ARM path = **540** after libav crop; beam scales **540→720** | **OK product**; 544 only fabric/bitstream ring |

**No `width >= 1280` runtime bank-style predicate** in present_* / rate_match / npx / Plex clock mux.  
The class appears as **identity glass→store + docs that freeze content=1280**, not as an `if (w>=1280)`.

---

## 1) Bresenham rate-match (parent Q1)

Quoted (`present_pix_rate_match.sv`):

```systemverilog
parameter int F_SYS_HZ   = 20_000_000,
parameter int F_PIX_HZ   = 29_700_000,
parameter int PX_PER_CLK = 2
// acc += F_PIX_HZ; fire when acc >= F_SYS_HZ * PX_PER_CLK
```

**It does not take source W/H or output W/H.**  
It only throttles **sys-domain group fires** so long-term `pixels/s ≈ F_PIX_HZ` when each fire emits `PX_PER_CLK` pixels.

| Concern | Answer |
|---------|--------|
| Assumes source==output raster 1:1? | **No** — geometry-free |
| 960×540 vs 1280×720 → underrun from 4/3? | **Not via this block** |
| What *can* underrun mid-line? | FIFO depth vs `clk_sys` fill / `clk_pix` drain, backpressure, missing sync sideband — **not** 4/3 arithmetic |

**Clean negative** for the geometry class on rate-match.

---

## 2) Identity glass→store (parent class HIT)

Quoted (`present_core.sv` multi-pixel arm):

```systemverilog
// Store map: identity glass→store (native 1280). w-scaler owns non-identity
// Clamp to FRAME_*: integration needs FRAME/CODED 1280 or right edge clips.
wire [FRAME_X_W-1:0] mp_store_x =
    (mp_glass_x0 > 12'(FRAME_LAST_X)) ? FRAME_LAST_X
        : mp_glass_x0[FRAME_X_W-1:0];
wire [FRAME_Y_W-1:0] mp_store_y =
    (mp_glass_y > 12'(FRAME_LAST_Y)) ? FRAME_LAST_Y
        : mp_glass_y[FRAME_Y_W-1:0];
```

| Glass | FRAME (example product intent 960×540) | Store coord | Picture |
|------:|----------------------------------------|-------------|---------|
| x 0..959 | 960 | x | 1:1 left band |
| x 960..1279 | 960 | **959 clamp** | **320 px right smear** |
| y 0..539 | 540 | y | 1:1 top band |
| y 540..719 | 540 | **539 clamp** | **180 line bottom smear** |

Current **product QSF** is still `FRAME_W=640` / `FRAME_H=480` (`Plex.qsf`) — even worse clamp (half-line smear).

`present_content_window` is **named in comments only** — **no module in this tree**.

### Why a naive `glass * FRAME/GLASS` on `x0` is not a free fix

`ddr_frame_store` N-wide path (`yuv_bt601_npx`) extracts **consecutive** coded pixels
`src_x0 .. src_x0+PPC-1` from one Y qword (assumes adjacent store samples).

At 4/3 NN, glass lanes often need **repeat** samples (e.g. glass 0,1 → store 0,0), not
store 0,1. Scaling only `glass_x0` then issuing consecutive N **lies** for upscale.

| Approach | Owner | Status |
|----------|-------|--------|
| Identity + FRAME=1280×720 banks | old native-source plan | **Wrong for 960 source** |
| Fail closed if FRAME≠glass under MP | w-clock | **This commit** |
| Filtered / correct glass→store + N-lane map | **w-scaler** | **Required for product** |

---

## 3) Coded 544 vs display 540 — **SETTLED by parent SPS measurement**

Do **not** trust `ffprobe coded_height=540` (post-crop). Authoritative bitstream
(`ffmpeg -bsf:v trace_headers` on validated `proxy_960x540.mp4`):

```
pic_width_in_mbs_minus1        = 59   → width  = 960
pic_height_in_map_units_minus1 = 33   → height = 544   ← CODED
frame_mbs_only_flag            = 1
frame_cropping_flag            = 1
frame_crop_bottom_offset       = 2    → CropUnitY=2 → bottom crop 4 lines
544 - 4 = 540 display
```

| Path | Height / bytes | w-clock action |
|------|----------------|----------------|
| **ARM product (libav applies SPS crop)** | **540** / **777,600 B** bank payload | Glass→store map + FRAME account **540** source lines |
| Scale | **540 × 4/3 = 720 exactly** | No vertical crop in scaler; no 725.33 worry |
| Beam / rate-match | Emit **720** glass; rate-match clocks only | **Never 544** on this path |
| Future **fabric decoder** / bitstream-ring coeffs | **544** / 783,360 B pre-crop | Not present’s job; ring ABI must record 544 (w-mem) |

**Withdrawn:** “present must reason about 544 or 5-line drift on ARM path.”  
**Still true:** identity clamp with FRAME_H=540 smears glass y≥540 — that is missing
**scale**, not missing 544. `ddr_frame_layout_params.svh` still 624×480 until w-mem
lands 960×540 product constants.

---

## 4) Other 1280 mentions (classified)

| Location | Role |
|----------|------|
| `H_DE(1280)` beam/timing | Output DE — **correct** |
| Comments “native 1280”, “FRAME/CODED 1280” | **Old assumption** — product source is 960 |
| `assets/multi_pixel_present_contract.json` `"content_geometry":"1280x720"` | **Mislabelled** glass as content — fixed this commit |
| `H_OWNERSHIP_W_SCALER.md` identity only if FRAME 1280 | Honest for native; **must call out 960 product** |
| Scanout/clock docs treating 1280 content Mpix/s | Still valid as **glass** content rate once scaled; BW for **source** bank is 960×540×1.5×fps |

No present-path analogue of `if (rt_cw_cl >= 11'd1280)` bank select found.

---

## 5) CLK_VIDEO / CE_PIXEL

```systemverilog
// PRESENT_CLK_PIX_PLL: CLK_VIDEO=clk_pix, CE=1
// else: CLK_VIDEO=clk_sys, product CE path
```

No width key. **Clean.**

---

## 6) What would glass look like if we fitted MP ON today

Without w-scaler map + correct FRAME/CODED/DISPLAY for 960×540:

1. Glass timing 1280×720 (beam) — HDMI/ascal may look “720p-ish”.  
2. Store reads **clamp-identity** → left/top shows source strip, right/bottom **smear**.  
3. Plus w-mem bank capacity if stride still 512 KiB — separate HIT (parent/rd-duck).  
4. Plausible-but-wrong picture — same failure *mode* as the bank predicate bug.

---

## 7) Actions this lane took

1. This report.  
2. RTL: label identity map **PRODUCT-UNSAFE when FRAME ≠ glass**; sim `$error` if
   `PRESENT_MULTI_PIXEL` elaborated with `FRAME_W!=1280 || FRAME_H!=720`.  
3. Contracts/docs: split **glass** vs **source** geometry; drop “content=1280” lie.  
4. Gate: multi-pixel checker requires the mismatch guard text + contract fields.  

**Did not** implement glass→store 4/3 (would fight N-wide consecutive extract and
w-scaler ownership).  

**Did not** touch `ddr_frame_store` bank predicate (w-mem).  

---

## 8) Parent commands (no device)

```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-clock
python3 scripts/check_multi_pixel_present.py --root . --require-rtl; echo "true rc=$?"
make present-720p-fit-contract; echo "true rc=$?"
# After w-scaler lands map: remove/relax FRAME==glass $error under agreed define.
```
