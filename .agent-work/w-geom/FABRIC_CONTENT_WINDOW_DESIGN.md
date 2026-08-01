# Fabric content window — offload ARM scale/pad to FPGA

**Lane:** w-geom · **Branch:** `w-avsync-hdmi-measure` · **No Quartus** (design + host math only)  
**Fit owner:** w-fit-1 (coordinate ONE fit with decode_stub reclaim)  
**Artifact baseline for cost facts:** RBF `8fdf440f` fit summary  
`ALM 23585/41910 · M10K 465/553 (88 free) · DSP 44/112`

---

## 0. Just finished (prior turn)

1. ARM vf no longer V-resamples when delivery height is already 480 (`crop_pad_no_v_scale`).  
2. Commit `150718b4`; ARM md5 `92c1993889bd3f5859d804fe93cb4d6d`.  
3. Gate RED rc=1 / GREEN rc=0 (`test_ffmpeg_vf`).  
4. ~475 defect is **ARM-only** today; **subsumed** for the 320 path if this fabric work lands (ARM stops scale entirely).  
5. Vernier pad_total 0 vs 5 is the glass primary; pitch 3.99 supporting.

---

## 1. Problem (measured → source)

| Fact | Evidence |
|------|----------|
| Every 320×240 frame is swscaled to 618×480 + pad 624 | GEOM `arm_rescale=1 reason=scale_pad_crop` + vf `scale=618:480:…decrease,pad=624:480` |
| Store is synthesis-fixed 624×480 | `ddr_frame_layout_params.svh` CODED 624, Y_STRIDE 624, YUV bytes 449280 |
| `present_core` maps **full** FRAME (640×480) across DE | `STORE_X_SCALE=(FRAME_W*39647)/320`, `NATIVE_V_1TO1` y=vc |
| Pad-only without fabric scale → quarter picture | w-cpu-1 correct negative; DE still samples full bank |
| Native 480p: `arm_rescale=0 identity_skip=1` | Resample is geometry-tax only |
| ffmpeg ~38.5–62.9 %onecpu dominated by scaler | Parent measured; fast_bilinear lever exists only while scale exists |

**Fix location:** `present_core` (+ `ddr_frame_store` stride/window) — **not** ARM pad-only.

---

## 2. ascal — can it do this alone?

**Short answer: No — not without changing the core’s output timing. Do not build a second polyphase scaler.**

Quoted wiring (`sys_top.v` ~714–780):

```
ascal ( … .i_clk(clk_ihdmi), .i_ce(ce_hpix), .i_r/g/b(hr_out…),
        .i_hs/vs/de(…), .iauto(1), .himin/himax/vimin/vimax(0),
        .o_* → HDMI, .hdisp(WIDTH), .vdisp(HEIGHT), … )
```

- **ascal already runs** on the HDMI path and costs the budgeted **~1936 ALM / 43 M10K / 23 DSP** (framework).  
- `iauto=1` auto-detects **input** size from the core’s DE. It scales **whatever full-frame raster the core emits** up to HDMI (e.g. 529×480 → 1920×1080).  
- If the core still emits a 480-line Template DE whose **pixels** are a 320×240 island in a black 624 canvas, ascal faithfully upscales that island → **quarter-size on glass** (same failure mode as pad-only).  
- To “just use ascal,” the core would have to emit **DE = content size** (320×240 timing). That fights:
  - FBAR / Template `H_DE=529` lock (`present_core.sv:172`, colorbars),
  - clk_sys=20 MHz line budget,
  - misterplexd OSD / content_res assumptions,
  - every glass instrument calibrated on 480-line capture geometry.

**Recommendation:** Keep ascal as the **HDMI** scaler only. Put **content→DE** scale in `present_core` (nearest-neighbour first) — the same mul-shift path that already maps FRAME→DE.

---

## 3. Design — runtime content window

### 3.1 Already half-wired (unused today)

`Plex.sv:226-228`:

```systemverilog
wire content_res_640x480 = status[4];
wire [9:0] content_width  = content_res_640x480 ? 10'd640 : 10'd320;
wire [9:0] content_height = content_res_640x480 ? 10'd480 : 10'd240;
```

These **do not** drive `present_core` store mapping (synthesis `FRAME_W/H` still win). O[4] is the natural OSD hook; daemon should also program **exact** delivery WxH via PLXD/status when PMS ≠ 320/640 ladder.

### 3.2 Registers (target)

| Reg | Bits | Reset | Role |
|-----|------|-------|------|
| `content_w` | 10 | 624 or 640 | Active content width in store |
| `content_h` | 10 | 480 | Active content height |
| `content_x0` | 10 | 0 | Origin x in coded bank |
| `content_y0` | 10 | 0 | Origin y |
| `y_stride` | 11 | 624 | Luma bytes/line (runtime) |
| `chroma_stride` | 10 | stride/2 | |
| `win_enable` | 1 | 0 | 0 = legacy full-bank (safe) |

Program path (pick one in fit integration):

1. **OSD O[4]** coarse 320 vs 640 (existing wires → connect).  
2. **PLXD mailbox extension** (preferred product): ARM writes measured delivery WxH after GEOM, one-time per session — pairs with `MEASURED_DELIVERY`.

### 3.3 `present_core` mapping (NN — preferred V1)

Replace synthesis `STORE_*_SCALE` from `FRAME_*` with **runtime content_*** when `win_enable`:

```
// DE domain unchanged: hc 0..H_DE-1, py 0..V_DE-1 (480 native)
store_x = content_x0 + floor(hc * content_w / H_DE)
store_y = content_y0 + floor(py * content_h / V_DE)
```

Integer form (same style as today):

```
SX = (content_w * 39647) / 320;   // when H_DE=529; generalize: content_w * 65536 / H_DE
SY = (content_h * 65536) / V_DE;
store_x = content_x0 + (hc * SX) >> 16;
store_y = content_y0 + (py * SY) >> 16;
```

Clamps to `content_x0+content_w-1` / `content_y0+content_h-1`.

**This is already the structure of `present_core.sv:177-206`** — only the scale source becomes registers instead of `localparam FRAME_*`.

### 3.4 `ddr_frame_store` changes

Today plane layout is **localparam CODED_W/H + fixed U/V offsets** (`Y_STRIDE=624`, U@299520, V@374400).

**V1a — minimal (fits 88 M10K):** Keep **bank capacity** 624×480 / 0x80000, but:

- Reads use `content_*` window inside bank.  
- ARM writes **native 320×240 packed at (0,0)** with **stride = content_w** (320), **not** 624.  
- Store address gen: `y_off = rd_y * y_stride` (reg), chroma `y/2 * chroma_stride`.  
- Plane sizes become functions of content_w/h (or max-coded with unused tail ignored).  
- Doorbell/swap unchanged.

**V1b — ARM still uses stride 624 but only fills content_w×content_h:** saves scale CPU, **not** full DDR bandwidth (still ~partial lines). Prefer V1a.

**Must not break 480p:** `win_enable=0` or content=624×480 → bit-identical to today’s 1:1 path.

### 3.5 Scaler quality ladder

| Tier | Algo | Extra M10K (est.) | DSP | Quality | Fit gate |
|------|------|-------------------|-----|---------|----------|
| **V1 (ship)** | **Nearest-neighbour** (existing mul-shift) | **0–2** | 0–2 | Blocky 2×; acceptable for 320→DE then **ascal** polyphase to HDMI | **≤88 free** |
| V2 | Bilinear (1–2 line buffers @ ≤640×16b) | **4–8** | 2–4 | Soft 2× | ≤88 |
| V3 | Polyphase in-core | **40+** | 20+ | ascal-class | **Needs stub reclaim (~356 free)**; **reject for V1** — ascal already does HDMI |

**Honest choice:** **V1 NN in present_core + existing ascal to HDMI.**  
Double-scale (NN content→480, polyphase→1080) is normal for MiSTer cores. Building in-core polyphase **duplicates ascal** and burns the stub reclaim budget better spent on decode.

---

## 4. Budget pre-register (before fit)

### 4.1 V1 NN + runtime window (target for ONE fit with stub work)

| Resource | Pre-register Δ | Notes |
|----------|----------------|-------|
| ALM | **+80 … +250** | reg multipliers mux, stride adders, mailbox decode |
| M10K | **+0 … +2** | optional shadow regs; line buffers **not** required |
| DSP | **+0 … +2** | if mul moves to DSP; else soft mul in ALM |
| Timing | **hold clk_sys 20 MHz** | same critical path family as today’s `store_x_prod`; Fmax headroom unknown — **post-fit STA gate required** |
| Free M10K after | **≥86** of 88 without stub | **does not depend on stub reclaim** |

### 4.2 Optional V2 bilinear (same fit only if easy)

| Resource | Pre-register Δ |
|----------|----------------|
| M10K | +6 (two 640×16 linebufs + margin) |
| ALM | +200–400 |
| DSP | +4 |

Mark **optional**; not required for ARM offload.

### 4.3 Stub reclaim dependency

| Item | M10K | ALM |
|------|------|-----|
| Free today (`8fdf440f`) | 88 | ~18k |
| decode_stub dark (parent/w-fit-1) | **~268** | **~9217** |
| Free after stub remove | **~356** | ample |

**V1 does not need stub reclaim.**  
Reserve reclaim for decode/DPB — **not** a second ascal. Coordinate so content-window + stub-strip ship in **one** RBF if both ready; content-window alone is fit-legal now.

---

## 5. ARM saving pre-register

| Metric | Today 320 path (measured class) | After V1 fabric window |
|--------|----------------------------------|-------------------------|
| ffmpeg vf | scale+pad every frame | **fps only** (or none) — `arm_rescale=0` |
| ffmpeg %onecpu | 38.5 (fast_bilinear) … 62.9 (default) | **≈ H.264-only residual ~6–15** (order of 480p decode leg) |
| Δ %onecpu (pre-reg) | — | **−25 … −50 points** on ffmpeg leg |
| DDR write / frame | 449280 | **115200** (320×240 I420) |
| DDR write bandwidth | 1.0× | **~0.256×** (−74%) |
| Publish memcpy | full bank | ~3.9× smaller |

**Caveat:** exact %onecpu is device-measured; pre-reg is bounded by parent’s scaler-vs-decode split at 480p (~50 vs ~6).

480p native path: **unchanged** (`content=624×480`, no ARM scale) — already `arm_rescale=0`.

---

## 6. `DDR_YUV_FORCE_SCALE` interaction (load-bearing)

**Do not delete or invert the conf key.**

| Mode | Today | After fabric window |
|------|-------|---------------------|
| FORCE_SCALE=1 (default YUV DDR) | Always scale/pad to **coded 624×480** bytes | Always ensure pipe bytes == **programmed content frame bytes** (115200 or 449280). If delivery ≠ content window, still scale **to content_w×h** (not necessarily 624). |
| FORCE_SCALE=0 + verified match | identity_skip | identity_skip when measured == content window |
| Pipe desync class (MILESTONE 4) | Reader 449280 fixed | Reader = `yuv420pFrameBytes(content_w,content_h)`; identity_skip only when verified equal |

**Ship rule:**  
`frameBytes = content_w * content_h * 3/2` with content programmed **before** first read.  
FORCE_SCALE=1 + content_w/h preset from OSD/PMS expect still pins OUTPUT size → desync class stays closed.

**GEOM:** expect `arm_rescale=0 reason=identity_skip|fabric_window` on 320 path once window programmed and ARM stops scale.

---

## 7. ~475 vertical-resample defect

| Path | Status after this work |
|------|------------------------|
| 320→618 decrease | **Subsumed** — ARM does not run decrease at all |
| 624×480 decrease into 618 | **Already fixed** ARM-side (`crop_pad_no_v_scale`, `150718b4`); fabric 1:1 also never decrease |
| Double-fix | **Do not** — no second ARM patch required if fabric 320 lands |

---

## 8. Implementation slices (for w-fit-1)

1. **RTL:** `present_core` runtime SX/SY from `content_w/h`; default = FRAME (legacy).  
2. **RTL:** `ddr_frame_store` runtime `y_stride` + content clamp on `rd_x/y`; default 624.  
3. **RTL:** wire `Plex.sv` `content_width/height` → present when O[4] says 320; mailbox override later.  
4. **ARM:** when fabric window ack’d (status bit), `buildFfmpegVideoFilter` Off/identity for matching delivery; publish `content_w*content_h*3/2` bytes; **FORCE_SCALE semantics** as §6.  
5. **Sim gates:**  
   - extend `test_present_store_scale_math` for content 320×240 → unique store rows 240, x max 319.  
   - verilator: 320 fill → full DE coverage (no quarter-size).  
   - mutation: win_enable stuck 0 with ARM native write → RED (quarter).  
6. **Fit:** ONE RBF with stub strip if ready; else content-window alone.  
7. **Parent glass:** 320 GEOM arm_rescale=0; pitch/CPU; no FBAR reg.

---

## 9. Host math gate (this commit)

`tests/unit/test_fabric_content_window_math.cpp` — pure integer model of §3.3; **true rc=0** required. No RTL edit in this slice (design-first).

---

## 10. Decision summary for parent

| Question | Answer |
|----------|--------|
| Where? | **`present_core` content window + `ddr_frame_store` stride** |
| ascal alone? | **No** (scales full core DE to HDMI; won’t enlarge a 320 island) |
| Scaler quality V1? | **Nearest-neighbour** (already in RTL structure) + ascal HDMI |
| Fits 88 M10K? | **Yes** (≈0–2 M10K) |
| Need stub reclaim? | **No for V1**; reclaim for decode, not polyphase |
| ARM saving? | ffmpeg scaler leg **−25…−50 %onecpu**; DDR write **÷3.9** |
| FORCE_SCALE? | **Keep**; retarget to content-frame bytes |
| ~475 defect? | **Subsumed** on 320 path; 480 path already ARM-fixed |
