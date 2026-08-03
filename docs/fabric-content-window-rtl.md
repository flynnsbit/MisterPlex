# Fabric content window — RTL slice (w-scaler)

**Branch:** `w-scaler-window` · **No Quartus** (design + sim only)  
**Extends:** `FABRIC_CONTENT_WINDOW_DESIGN.md` (dce73e89) + `PRESENT_DDR_OFFLOAD_RERANK.md` (aec09272)

---

## What landed

| Item | Path |
|------|------|
| NN window mapper | `fpga/Plex_MiSTer/rtl/present_content_window.sv` |
| present_core integration | `fpga/Plex_MiSTer/rtl/present_core.sv` (ports + instance) |
| Safe Plex wiring | `fpga/Plex_MiSTer/Plex.sv` (`fabric_win_enable=0` default) |
| QIP | `fpga/Plex_MiSTer/files.qip` |
| Verilator RBG gate | `tests/unit/test_present_content_window_rtl_sim.sh` + `tests/rtl/present_content_window_tb*` |
| Host math lock | `tests/unit/test_fabric_content_window_math.cpp` |

## Behaviour

- `win_enable=0` (reset/default): legacy FRAME_W×FRAME_H map — product 640×480 → unique Y=480, unique X=529 max 638.
- `win_enable=1`, content 320×240 @ (0,0): NN stretch across H_DE=529 × V_DE=480 → unique X=320 (0..319), unique Y=240 (0..239).
- H_DE remains **529** (FBAR/Template lock). DE timing unchanged.
- Quality V1: **nearest-neighbour** only. ascal stays HDMI polyphase. Double-scale (NN→480, poly→1080) is intentional MiSTer-class tradeoff: blocky 2× on 320 content before HDMI soften.

## Register map (proposed — reconcile with w-mem / mailbox owner)

Doorbell-relative control page (product doorbell `0x300FF000`). Existing: PLXS +0x100, PLXF +0x118, PLXD +0x128.

| Offset | Name | Bits | Reset | Role |
|-------:|------|-----:|------:|------|
| +0x130 | **PLXW** magic | [63:32]=`PLXW` (0x504C5857) | 0 | Host write valid marker |
| +0x130 | win_enable | [0] | 0 | 0=legacy full-bank; 1=content window |
| +0x130 | reserved | [7:1] | 0 | |
| +0x132 | content_w | [9:0] in low of next half | 624 | Active content width in bank |
| +0x134 | content_h | [9:0] | 480 | Active content height |
| +0x136 | content_x0 | [9:0] | 0 | Origin x in coded bank |
| +0x138 | content_y0 | [9:0] | 0 | Origin y |
| +0x13A | y_stride | [10:0] | 624 | Luma bytes/line (ddr_frame_store follow-on) |
| +0x13C | chroma_stride | [10:0] | 312 | Chroma bytes/line |
| +0x13E | status ack | [0]=applied, [1]=legacy_active | — | Core → HPS readback |

**Packing alternative (single 64-bit PLXW word @ +0x130):**

```
[63:48] content_h[9:0] | content_w[9:0] in 20b field  — exact pack TBD with mailbox owner
[47:32] content_y0[9:0] | content_x0[9:0]
[31:16] y_stride[10:0]
[15:1]  chroma_stride / flags
[0]     win_enable
```

**V1 shipped wiring:** ports on `present_core`; `Plex.sv` holds `fabric_win_enable=1'b0` and feeds O[4] coarse `content_width/height` as the default programmed size. **Do not** auto-enable from O[4] alone while ARM still scale/pads to 624.

**720p lane (w-mem):** same regs; content_w/h vary per delivery. Bank capacity / stride follow-on is ddr_frame_store runtime stride (not in this slice).

## Area / timing estimate (pre-fit — no Quartus this lane)

Baseline artifact: RBF `8fdf440f` — ALM 23585/41910, M10K 465/553 (88 free), DSP 44/112, clk_sys 20 MHz.

| Resource | Δ pre-reg | Reasoning |
|----------|----------:|-----------|
| ALM | **+80 … +200** | 18b scale regs, two 10×18 muls (or DSP), add/clamp, mux win_enable, tiny control |
| M10K | **0** | No line buffers (NN V1) |
| DSP | **0 … 2** | Optional map of hc×sx / py×sy; else soft mul in ALM |
| Fmax risk | **Low–moderate** | Pixel path = mul + add + clamp (same family as legacy `store_x_prod`). **Dividers only on scale recompute** (content_* change), registered into `sx_r/sy_r` — off ce_pix critical path. |

**Threats to flag for fit owner:**

1. If Quartus folds the `/320` and `/V_STORE` into the pixel path by accident → STA fail risk. Keep scale regs; do not feed comb sx into hc mul without a register cut.
2. 18×10 multiplier on clk_sys 20 MHz is comfortable; do **not** introduce a per-pixel divide by 529.
3. Does not need decode_stub reclaim.

## Follow-ons (not this commit)

1. PLXW mailbox decode in `ddram_frame_rd` / control page.
2. `ddr_frame_store` runtime `y_stride` + plane offsets from content_w/h (V1a publish 115200 bytes).
3. ARM: native publish + FORCE_SCALE retarget when win ack’d.
4. ONE fit (w-nostub/w-fit owner) + parent glass.

## Sim evidence (true rc)

```
legacy  true rc=0  REPRO_OK legacy_fixed_map quarter_class=1 full_stretch=0
window  true rc=0  PASS present_content_window_320 unique_x=320 unique_y=240
legacy480 true rc=0 PASS legacy_480p_identity unique_y=480 unique_x=529
host math true rc=0
present_store_scale_math true rc=0
```
