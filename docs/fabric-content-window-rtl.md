# Fabric content window — RTL (w-scaler), 720p-native

**Branch:** `w-scaler-window` · **No Quartus**  
**Mandate:** move work off ARM so 720p fits the 41.7 ms/f budget.  
**Extends:** `FABRIC_CONTENT_WINDOW_DESIGN.md` + `PRESENT_DDR_OFFLOAD_RERANK.md`

---

## Design choice (ARM out, not ARM cheaper)

| Option | ARM still does | Chosen? |
|--------|----------------|---------|
| fast_bilinear / cheaper swscale | scale every frame | **No** — still burns the budget 720p needs |
| Pad-only to 624, fabric samples island | pad + full-bank present | **No** — quarter-size dead end (w-cpu-1) |
| **Fabric NN window + native publish + runtime stride** | **no scale** (memcpy only until fabric writer) | **Yes** |

NN in fabric is “uglier” than polyphase, but **ARM leaves the scale loop entirely**. ascal keeps HDMI quality.

---

## 720p from day one

| Parameter | Value | Why |
|-----------|------:|-----|
| `STORE_W` / `MAX_CODED_W` | **1280** | one M10K per luma line |
| `STORE_H` / `MAX_CODED_H` | **720** | 720p frame |
| `content_w/h/x0/y0` | **11 bits** | covers 1280×720 |
| `h_de` / `v_de` | **11 bits**, 0→default 529/480 | 720p DE = reg write, not redesign |
| Window SX | endpoint-exact **ceil** Q16 | last DE sample hits last content pixel |
| Legacy SX | `FRAME_W * 39647 / 320` | bit-exact 480p when `win_enable=0` |
| Runtime y_stride | **12 bits** (bytes) | 1280 for 720p tight pack |
| Linebufs | MAX 160/80 qwords | physical WIDTH max; fetch length = eff_* |

Product 480p still uses H_DE=529 FBAR lock. `win_enable=0` + `geom_enable=0` → bit-exact legacy.

---

## Runtime bank geometry (`ddr_frame_store`)

`geom_enable=0` (reset): synthesis CODED_W/H (product 624×480), plane bases U=37440 V=46800 qwords.

`geom_enable=1`: host programs coded_w/h, y_stride, chroma_stride, present/display/crop.
Plane bases (qwords):

```
u_base = (y_stride * coded_h) / 8
c_plane = (chroma_stride * (coded_h/2)) / 8
v_base = u_base + c_plane
```

720p tight (1280×720, y_stride=1280, c_stride=640): **U=115200 V=144000**.

Ownership: **w-scaler = READ/present**; **w-mem = WRITE** (`fabric_ddr_writer`) + ABI headers.
Option-C bank contract (w-mem): base `0x30180000`, bank stride `0x180000`, doorbell `0x3047F000`.
Legacy product defaults remain `0x30000000` / `0x80000` / `0x300FF000` at reset.

---

## ARM milliseconds removed

| Lever | ms/f | How known | Condition |
|-------|-----:|-----------|-----------|
| **Scale leg** | **2.954** | FEED table (624×480, 1800 frames) | ARM vf scale **off** after win_enable+native WxH |
| Present/DDR bytes | **unknown** | need `copy_us`/`flush_us` with native publish + runtime stride | Parent measure |
| 720p scale leg | **unknown** | not measured on device for this path | Parent FEED-class 720p |

**This RTL alone does not turn off ARM scale** — `fabric_win_enable` and `fabric_geom_enable` default **0**. Full evacuation = RTL + PLXW enable + ARM identity publish (+ w-mem writer for zero per-pixel).

Parent real 720p decode: **41.073 ms/f** (98.6% of 41.667 budget). Non-decode must leave ARM.

---

## Register map (PLXG — reconcile w/ w-mem ABI)

**Magic is PLXG (`0x504C5847`), not PLXW** — PLXW is already the bitstream session-low stat.

Proposed block @ doorbell+0x130 (host-writable; w-mem owns final ABI headers).
RTL latch: `present_geom_latch.sv` (wired in `Plex.sv`, wr tied 0 until poller).

| Off | Field | Bits | Reset | Notes |
|----:|-------|-----:|------:|-------|
| +0 | magic | 32 | — | PLXG |
| +0 | win_enable / geom_enable | 1/1 | 0 | Q0 bits 32/33 |
| +0 | seq | 16 | 0 | Q0 [63:48]; must change to commit |
| +8..+28 | content/DE/coded/stride/present/crop | — | 0 | see pack in present_geom_latch.sv |

Legacy table (logical fields):

| Off | Field | Bits | Reset | Notes |
|----:|-------|-----:|------:|-------|
| +0 | win_enable | 1 | 0 | content window NN |
| +0 | geom_enable | 1 | 0 | runtime bank geometry |
| +4 | content_w / content_h | 11/11 | 0 | window size for window |
| +8 | content_x0 / content_y0 | 11/11 | 0 | origin in bank |
| +0xC | h_de / v_de | 11/11 | 0→529/480 | DE for SX/SY |
| +0x10 | coded_w / coded_h | 11/11 | 0→CODED | bank coded size |
| +0x14 | y_stride | 12 | 0→CODED_W | bytes/line (720p: 1280) |
| +0x16 | chroma_stride | 11 | 0→CODED_W/2 | bytes/line (720p: 640) |
| +0x18 | display_w / display_h | 11/11 | 0→coded | present window size |
| +0x1C | present_x / present_y | 11/11 | 0 | present origin |
| +0x20 | crop_left / crop_top | 11/11 | 0 | coded crop |

---

## Area / timing pre-reg

| Resource | Δ | Reasoning |
|----------|--:|-----------|
| ALM | +150…+400 | window muls + geom regs + wider addr math |
| M10K | **+~line growth** | linebufs WIDTH 78→160 Y / 39→80 C qwords × slots; 1280B = 1 M10K/line |
| DSP | 0…2 | optional |
| Fmax | low–mod | dividers on reg update only; pitch×y is 9×11 mul on fill path (clk_ddr) |

Threat: pixel-path divide; keep SX/SY registered. Fill-path `fill_y * pitch` is 29b — watch clk_ddr STA after nostub fit (not this lane).

---

## Sim evidence (true rc)

```
# content window
legacy     rc=0  REPRO quarter_class
window320  rc=0  PASS unique 320×240
legacy480  rc=0  PASS identity 480
720de480   rc=0  PASS x→1279 y→719
720id      rc=0  PASS 1280×720 identity

# runtime stride (ddr_frame_store)
legacy624  rc=0  U/V 37440/46800
rt720      rc=0  U/V 115200/144000
neg_geom0  rc=0  red-check fixed-624 ≠ 720p bases
FAULT_IGNORE_GEOM red twin rc=0  correctly misses 720p bases

host math  rc=0
native_480p rc=0  (geom tied off)
```

## Follow-ons

1. PLXW mailbox decode (wire fabric_* from host; w-mem ABI)  
2. w-mem `fabric_ddr_writer` + Option-C bank live  
3. ARM native publish + win_enable=1 + geom_enable=1  
4. Parent glass + FEED remeasure (scale + present bytes)

## Qword export (multi-pixel free lunch)

`DDR_FRAME_STORE_EXPORT_QWORDS` (compile-time, **off in product**) adds ports on
`ddr_frame_store`:

| Port | Width | Meaning |
|------|-------|---------|
| `rd_y_qword` | 64 | Y linebuf qword at the YUV-calc stage |
| `rd_y_qword_hi` | 64 | Next Y qword (straddle when lanes cross 8-byte boundary) |
| `rd_y_hi_valid` | 1 | Hi qword in-range for this line |
| `rd_u_qword` / `rd_v_qword` | 64 | Chroma qwords (same stage) |
| `rd_src_x_q` | 11 | Store X aligned with `y_sel_r` (one beam cycle) |
| `rd_qword_valid` | 1 | Hit + visible + has_frame at that stage |

One luma qword holds **8** samples → N≤8 pixels/clk with no extra DDR read when
lanes share `src_x[10:3]`. Straddle uses `y_qword_hi` (dual-port Y linebuf read).
Chroma 4:2:0: byte index `(x>>1)[2:0]`. `line_buf_ram` second read port is
tied off on chroma and on `frame_store` (legacy).

Consumer: w-clock `yuv_bt601_npx` (do not duplicate). Product path leaves the
define off so pinout and ALM stay identical for w-nostub.

RBG: `tests/unit/test_ddr_qword_export_rtl_sim.sh`
- GREEN: lanes 0..3 from one export match single-pixel `rd_r/g/b`
- RED: `FAULT_QWORD_LANE0` (always Y byte0) must mismatch lanes 1..3

## Full-pixel READ proof (sim)

Gate: `tests/unit/test_ddr_720p_pixel_rtl_sim.sh`

| Case | Expect |
|------|--------|
| full_grey | every active RGB == Y (U=V=128), rate ≥0.995 over 1280×720×2 |
| full_chroma | BT.601 unique U/V exact matrix match |
| bank_swap | bank1 poisoned mid-scan; glass stays bank0 until doorbell+vsync |
| wrong_stride | pack y_stride=1296 vs geom 1280 → dirty (negative) |
| half_chroma | U plane +1 line → dirty (negative) |

Measured (true rc=0): full_grey rate≈0.9989, last qword x∈[1272,1279] 11520/11520,
odd-line chroma ok, first Y @ `0x30180000`, U_qw=115200, V_qw=144000.

## Bank credit (agree with w-mem `7365998e`)

- Reader hits linebufs only when `y_bank==disp_bank` (never mid-write bank).
- Writer: `free_mask[i]=0` while bank is disp or swap_pending; claim→fill→doorbell→commit.
- PLXD @ doorbell+0x128 = Option-C `0x3047F128`: `free[1:0]|disp<<2|swap<<3|frames<<16`.
- This lane does not issue doorbells; w-mem writer owns produce.

## Integration macros (parent)

```
FABRIC_NATIVE_720P_GEOM=1   # force 1280 READ + Option-C (PLXG wr still 0)
FABRIC_DDR_WRITER=1         # w-mem pattern producer
```
Default QSF leaves both unset → bit-identical to `d1b24e0c` at reset.

## Parent verify command (device — parent only)

```bash
# After integration fit with macros above + menu deploy:
tests/unit/test_ddr_720p_pixel_rtl_sim.sh; echo "pixel_true_rc=$?"
# Glass (parent):
scripts/hdmi_capture_idle.sh captures/fabric720_move.png
```

## Fabric NN scale (arbitrary source → DE)

`present_content_window` with `win_enable=1`:
- `content_w/h` = bank content (e.g. PMS **720×404**, native 1280×720, 320×240)
- `h_de/v_de` = glass raster (w-clock **1280×720** under `PRESENT_MULTI_PIXEL`, or 529×480 product)
- `content_x0/y0` = letterbox/pillar origin

Quality V1 = **nearest-neighbour** (0 extra M10K, mul+>>16 on pixel path). Motion shimmer is real; bilinear V2 ≈2 M10K @1280 is affordable post-nostub but not landed. HDMI ascal does not re-filter when DE already equals the output raster.

Gate: `tests/unit/test_present_content_window_rtl_sim.sh`
- pms404 midpoint x=359 (not identity 639)
- letterbox 280,158 → 999,561
- RED: `PRESENT_WINDOW_FAULT_IDENTITY_SCALE` fails pms404
