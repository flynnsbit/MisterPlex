# Ascal-native beam class: 960×540 @ **30 Hz** (LOCKED for first fit)

**Cadence DECISION (parent 2026-08-03):** **30 Hz**, not 24.  
ascal FB decouples *clocks* but not *field repeat*: 24→60 = 5:2 judder; 30→60 = 2:1 clean.

**true_de evidence (machine):**
```
PRODUCT_30_V564 H_TOT=1182 V_TOT=564 fps@20M=30.0008
de_w_max=960 de_lines=540 de_pixels=518400 true_de=1  rc=0
island_1280 true_de=0 rc=1
```
(w-scaler `test_present_true_de_count_rtl_sim` + `test_true_content_de_contract`)

**Stale log:** `npx_full_raster_run.txt` deleted (must stay gone).

**QSF card for w-nostub:** `.agent-work/w-clock/W_NOSTUB_QSF_BEAM_CONSTANTS.md`

---


## 1) Is 30 Hz achievable? Best blanking

`clocks/frame = 20e6/30 ≈ 666666.67` (not integer — pick nearest).

| Name | H_TOTAL | V_TOTAL | Hblank | Vblank | fps | Notes |
|------|--------:|--------:|-------:|-------:|----:|-------|
| **30A primary** | **1182** | **564** | **222** | **24** | **30.0008** | Best fps≈30 + healthy blank |
| 30B alt | 1190 | 560 | 230 | 20 | 30.012 | Slightly more Hblank |
| 600/1111 | 1111 | 600 | 151 | 60 | 30.003 | Parent “tight H” — workable, less H margin |
| exact 666666 | 1221 | 546 | 261 | **6** | 30.0000 | **Reject** — Vblank too thin for VS/ascal |
| 24 film opt | 1389 | 600 | 429 | 60 | 23.997 | Optional film-matched beam |

**Active rate @30A:**  
`960×540×30.0008 ≈ **15.55 Mpix/s**`

**1px path peak:** `20 Mpix/s` (CE=1) → margin **1.29×** → **B1 not required on 1px path.**  
**Legacy serialize 13.33:** 15.55 > 13.33 → B1 **would** be load-bearing if MULTI_PIXEL serialize were ON.  
First fit macros: MULTI_PIXEL **OFF**, so shipping path is 1px. B1 stays verified green (default OFF) for PPC upgrade.  
*(Parent note: 15.55>13.33 is real arithmetic but applies to the serialize ceiling, not CE=1.)*

**640×360@30:** `6.91 Mpix/s` — trivial on same 20 MHz class (exact 2× ladder tier).

**vs old 640@60/524 comment** (`present_core` ~194–196): that wall is **60 Hz × 524 lines → ~636 clocks/line**. At 30 Hz / 564 lines → **1182 clocks/line** — constraint **does not bind**.

---

## 2) Does ascal need core rate | 60? **No** (quoted)

### Mode bit = triple buffer when not low-latency

`ascal.vhd` header:

```text
MODE[3]
 0 : Direct. Single framebuffer.
 1 : Triple buffering
```

`sys_top.v:791`:

```verilog
.mode ({~lowlat, LFB_EN ? LFB_FLT : |scaler_flt, 2'b00})
```

Default `lowlat = 0` → **`~lowlat = 1`** → **MODE[3]=1 → triple buffering ON**.

### Input vs output buffer swap (decoupled)

`ascal.vhd` ~1910–1940 (paraphrase of structure, see file):

- **Input:** `o_ibuf*` ← `buf_next` on **input** end-of-frame (`i_endframe` / core VS domain).
- **Output:** `o_obuf*` ← `buf_next` on **output** VS falling edge (`o_vsv`), when `o_bufup`.
- **Triple disabled** only if `o_mode(3)='0'` (forces buf=0).

So HDMI 60 Hz **reads** completed input frames from DDR FB; core **writes** at core VS rate.  
**No requirement** that `f_core` divide `f_hdmi`. Non-integer ratios (24→60) are normal: output holds/repeats the latest completed input frame for 2 or 3 HDMI periods (classic film-on-60 **display** cadence).

**Low-latency mode** (`lowlat=1`) disables triple buffer → single FB, more tear risk, still not “must divide 60”, but worse coupling. Product default is **not** lowlat.

### What 24 vs 30 beam actually changes

| | 24 Hz core beam | 30 Hz core beam |
|--|-----------------|-----------------|
| ascal legality | OK (FB) | OK (FB) |
| 24 fps **content** on 60 panel | ~3:2 unique-frame display | still ~3:2 unique if banks@24; extra identical scans if beam@30 |
| 30 fps **content** | ascal 30→60 with uneven hold if beam 24 | **clean 2:1** if beam 30 |
| Judder of **film content** | inherent 24-on-60 | **not removed** by 30 beam |

**Parent point (3) confirmed:** scan rate ≠ content rate. ARM/bank swap sets unique FPS; beam sets ascal **sample** rate.  
**Judder fix for TV is content@30 + beam@30**, not beam@30 alone under 24 content.

**Recommendation:** **default beam = 30A (1182×564)** for first fit — serves TV tier 2:1 and 360p@30; film content still correct via cadence/bank (display 3:2 of unique). Optional MODE=2 24 Hz later if we want beam-matched film.

---

## 3) B1 / PPC

| Path | Peak | 15.55 need | B1? |
|------|-----:|----------:|-----|
| 1px CE=1 (ascal-native fit) | 20.0 | OK | **No** |
| PPC=2 serialize (old) | 13.33 | FAIL | Yes (fixed → 40) |
| PPC=2 wide FIFO | 40.0 | OK | already done, OFF |

---

## 4) STA pre-registration (before fit)

`assets/ascal_native_sta_prereg.json`:

- **PASS:** Fmax(clk_sys) ≥ 20; all setup ≥ 0; PLL pix OFF; if macro on, 960 beam hierarchy live  
- **FAIL:** Fmax_sys < 20; neg slack; still H_DE=529 while claiming 960  
- **Not scored:** Fmax(clk_pix)≥29.7  
- **Prediction:** meet 20 MHz with margin unknown until report — **no invented Fmax**

---

## 5) Deliverables

| Item | Path |
|------|------|
| Timing RTL (not yet muxed into present_core) | `present_video_timing_960.sv` |
| Arith gate | `tests/unit/test_present_beam_960_arith.sh` |
| Contract | `assets/ascal_native_beam_contract.json` |
| STA prereg | `assets/ascal_native_sta_prereg.json` |

**Wire-up** (`PRESENT_BEAM_960` → replace colorbars 529 DE) is **parent-grant** with w-nostub B4; this lane supplies the numbers and module.

---

## 6) Answers distilled

1. **Yes, 30 Hz @960×540@20 MHz** — primary **1182×564** (Hblank 222, Vblank 24, 30.0008 Hz).  
2. **ascal does not need f_core | 60** — default triple-buffer decouples input EOF from output VS (`MODE[3]`, `buf_next` on both sides).  
3. **Scan ≠ content** — agree; pick 30 for ascal/TV tier; film unique still from banks.  
4. **STA:** ≥20 MHz sys, no clk_pix floor; B1 not required on 1px path.
