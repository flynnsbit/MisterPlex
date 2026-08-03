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

## Register map (PLXW — reconcile w/ w-mem ABI)

Proposed block @ doorbell+0x130 (host-writable; w-mem owns final ABI headers):

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
