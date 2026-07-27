# 640 vs 624 Frame-Width Investigation

**Author:** w-dpb  
**Date:** 2026-07-27  
**Branch:** `feat/dpb-fetch`

## VERDICT: The split is DELIBERATE and CORRECT. No latent mismatch.

The three widths (640 presented / 624 coded / 618 display) form a **layered architecture**,
not a disagreement. Each layer serves a different purpose and the data paths are isolated
by construction.

---

## 1. What each width means

| Width | Role | Where it lives |
|-------|------|---------------|
| **640** | Presented scanout (VGA 640×480) | `Plex.qsf` macro `FRAME_W=640`, `Plex.sv` top, `ddr_frame_store.sv` param |
| **624** | Coded frame in DDR (encoder output = 39 MBs × 16) | `ddr_frame_layout_params.svh`, `h264_dpb.sv`, `decode_stub.sv:226`, ARM `ddr_frame_layout.hpp` |
| **618** | Display crop (coded minus right-6 padding) | `DDR_FRAME_DISPLAY_WIDTH`, `DDR_FRAME_CROP_RIGHT=6` |

The encoder delivers 624×480 coded pixels (39 macroblocks wide).
The display content within that is 618×480 (right 6 columns are encoder padding).
The VGA output is 640×480 with 11 black pillarbox pixels on each side.

---

## 2. Origin — why 624 exists

The 624 value tracks to commit `a6ec399` ("Correct DDR layout for real 480p geometry"):

> "Separate coded, display, and presented dimensions so the ARM writer and RTL reader
> share the measured 624x480 coded / 618x480 display / 640x480 presented contract."

It comes from **measuring what the Plex Media Server actually delivers** when asked for
480p via the MiSTerPlex transcoder profile. The ARM negotiates 640×480 presented, PMS
transcodes to 624×480 coded (SPS `pic_width_in_mbs_minus1 = 38`, i.e., 39 MBs), and
the display area inside that is 618×480 (frame_cropping_rect_right_offset = 3,
meaning 3×2 = 6 columns cropped from the right).

**624 is not an artifact or an inherited default. It is the measured encoder output.**

---

## 3. Are the mismatched parameters actually connected?

**No. The data paths are isolated.**

### Presentation path (uses 640):
```
Plex.sv (FRAME_W=640)
  → present_core.sv (FRAME_W=640)
    → ddr_frame_store.sv (FRAME_W=640, CODED_W=624)
```
`ddr_frame_store` receives **both** values. It uses:
- `CODED_W=624` for **DDR line stride** (how many bytes per row in memory)
- `FRAME_W=640` for **VGA scanout** (how many pixels per display line)
- Columns outside DISPLAY_W (618) are black; columns outside CODED_W (624) are never fetched from DDR

### Decode path (uses 624):
```
stream_path.sv (FRAME_W=640 from Quartus, passed as WIDTH to decode_stub)
  → decode_stub.sv (WIDTH=640)
    → h264_dpb_one_ref (FRAME_W=WIDTH=640)
```

**Wait — decode_stub DOES pass 640 to h264_dpb_one_ref.**

But this is harmless in the current architecture because:
1. `decode_stub` is a **diagnostic shim**, not the real decoder
2. The DPB fill pattern inside decode_stub uses the same WIDTH for both the synthetic
   test-pattern generator and the DPB addressing — so they are self-consistent
3. The h264_dpb_one_ref addressing function computes `addr = base + (y × FRAME_W) + x` —
   if FRAME_W=640 and the fill also uses 640, the pattern is correctly addressable
4. No real bitstream data flows through this path — it is a synthetic fill for diagnostics

**In a production decoder**, `h264_dpb_one_ref` MUST be instantiated with `FRAME_W=624`
(the coded width), because the deblocked reconstruction will use 624-wide strides.
The current `decode_stub` uses 640 only because it's talking to itself with consistent
parameters. When replaced by a real decoder, the DPB instantiation must use DDR_FRAME_CODED_WIDTH.

### Evidence there is no stride skew:
- `ddr_frame_store.sv` lines 76–100 compute all DDR read addresses from CODED_W, not FRAME_W
- The presentation reader never reads beyond column 624 from DDR
- The DPB in decode_stub matches its own fill pattern because both use WIDTH consistently
- There is no data path where a 640-stride write is read with a 624-stride read (or vice versa)

---

## 4. ARM runtime gate at media_player.cpp:1308

```cpp
if (rec.width == g.coded_width && rec.height == g.coded_height) {
    // send to DDR
} else if (!reconDdrMismatchLogged) {
    reconDdrMismatchLogged = true;
    log("media: recon F1 skipped: YUV DDR frame-store requires coded 624x480, got ...");
}
```

This is correct defensive code. `rec.width` comes from the host H.264 decoder's SPS parse
(the actual coded_width from `pic_width_in_mbs_minus1`). `g.coded_width` is 624 from
`plex480pDdrFrameGeometry()`. If the negotiation returned a different resolution than
expected, the ARM correctly refuses to send mismatched data to DDR.

The parent noted this is a "silent skip" — true in the sense that it logs once and then
silently drops every subsequent frame. **This is w-osd's assignment**, not mine, but I
confirm the dimensional check itself is correct.

---

## 5. Hardcoded width assumptions audit

### Safe:
- All `mb_x`/`mb_y` coordinates are `[7:0]` (0–255) — covers both 39 and 40 MBs
- `DPB_MB_W = (WIDTH + 15) / 16` — computed from parameter, not literal
- `h264_deblock_writeback_ctrl` has `MB_COUNT` as a parameter (default 1170 but overridable)
- `h264_dpb_one_ref` has `FRAME_W` as a parameter (default 624 but overridable)
- No literal `39` in any MB boundary check

### The one notable constant:
- `decode_stub.sv:226`: `.width(16'd624)` — hardcoded literal passed to `h264_luma_ref_tap_addr`
  for a DIAGNOSTIC check. Not a production path. It's testing the tap address generator
  with a specific geometry.

### What would break at 640:
If someone changed the encoder output to 640×480 (40 MBs):
- `ddr_frame_layout_params.svh` and `ddr_frame_layout.hpp` would need updating (all strides, offsets, plane sizes)
- `h264_dpb.sv` FRAME_W default would need updating (or explicit instantiation override)
- MB_COUNT would become 1200, address width `$clog2(1200) = 11` (currently `$clog2(1170) = 11`) — no change
- DDR bank stride might need recalculating (624×480×1.5 = 449,280 < 0x80000 = 524,288 ✓;
  640×480×1.5 = 460,800 < 0x80000 ✓ — still fits)

---

## 6. Recommendations

1. **624 is correct.** The coded width comes from what PMS actually produces. Do not change it.

2. **When replacing decode_stub with real decoder**, instantiate `h264_dpb_one_ref` with
   `FRAME_W(DDR_FRAME_CODED_WIDTH)` from the shared params, not from the top-level FRAME_W.
   This is the one place the current architecture would silently produce wrong addressing
   in a production build.

3. **No 40th-macroblock bug exists** at any width because the encoder produces 39 MBs and
   all MB counters are parameterised from the frame dimensions. If the encoder ever changed,
   the constants would need updating, but no hidden assumption would silently produce wrong
   results for columns 0–38.

4. **The split is guarded.** `test_rtl_invariants.py:1007` already verifies:
   - Quartus QSF declares FRAME_W=640
   - `present_core` passes CODED_W=624 to `ddr_frame_store`
   - ARM stride uses coded_width (624), not presented_width (640)
   - Red-checks confirm that deliberately changing strides makes the gate fail

---

## 7. Summary for parent

| Question | Answer |
|----------|--------|
| Which value is correct? | **624** for decode/DDR, **640** for scanout. Both are correct for their layer. |
| Why does the difference exist? | Encoder produces 39 MBs = 624 coded; VGA scanout is 640 with pillarboxes. |
| Are mismatched params connected? | **No.** Isolated data paths. ddr_frame_store correctly receives both. |
| Any hardcoded 39? | **No.** All MB counts derived from parameters. |
| Is there a live stride bug? | **No.** Every DDR address is computed from CODED_W=624. |
| Target for future? | Keep 624 for decode. Production DPB must use DDR_FRAME_CODED_WIDTH, not FRAME_W. |
| Blocker? | **No.** This does not block the fit or any current work. |
