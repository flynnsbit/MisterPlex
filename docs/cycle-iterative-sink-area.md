# Cycle-iterative area review: `h264_i_res_recon_sink`

**Owner of RTL:** `sv-traverse` (sink + I path). Chroma pieces also touched by `sv-mvd`.  
**Integrate role:** measurement + architecture only.  
**Evidence (coord-map2d):** sink **40,439 comb ALUTs**, **15,343 regs**, **64 DSP** ·  
children: `h264_intra16x16_pred` **10,805** comb · `h264_intra4x4_pred` **1,490** ·  
device DSP budget **112** — sink alone uses **64 (~57%)**.

Sink is ~**1× the entire ALM device** if packed poorly, and **already illegal on DSP** if nothing else used DSPs. Product map already burns **74 DSP**; sink’s 64 cannot stack.

---

## 1. What the map attributed

| Hierarchy | Comb | Regs | DSP |
|-----------|------|------|-----|
| `h264_i_res_recon_sink` | 40,439 | 15,343 | 64 |
| `h264_intra16x16_pred` | 10,805 | 2,285 | 0 |
| `h264_intra4x4_pred` | 1,490 | 0 | 0 |
| (rest: IQ/IDCT/recon/neighbor/planes) | ~28k | ~13k | 64 |

IQ/IDCT path is the DSP hog (parallel 4×4 dequant × coeffs).

---

## 2. Structural cost centers (from RTL shape)

### 2.1 Combo neighbor gather (`always @*`)

```systemverilog
// plane_y[0:255] and top_row[0:MAX_PIC_W-1] read with runtime indices
i4_above[t] = plane_y[(i4_y0 - 1)*16 + (i4_x0 + t)];
i16_above[t] = top_row[mb_x*16 + t];
```

- `plane_y`: 256-entry runtime mux nets, many ports (i4 above/left/tl).  
- `top_row`: **MAX_PIC_W=1024** by default — 1024:1 byte muxes × 16 for I16 above.  
Same disease as RBSP/qpel window.

### 2.2 Parallel 4×4 IQ / IDCT / recon

```systemverilog
h264_dequant4x4 u_dq (...);  // 16 coeffs wide
h264_idct4x4   u_idct (...);
h264_recon4x4  u_recon (...);
h264_i16_dc_hadamard u_had (...); // also 16-wide + DSP in map
```

One block per cycle is fine **algorithmically**, but a fully parallel dequant of 16 lanes × multipliers explains **tens of DSPs**. Product already has serial MC using few DSPs; sink must not assume 64 free.

### 2.3 `h264_intra16x16_pred` at 10.8k comb

I16 pred outputs `pred[0:255]` — if the module builds all 256 predictors with parallel plane/mode logic, that alone is a quarter of the device. Prefer:

- shared row/column accumulator for DC/horizontal/vertical  
- **one pixel or one 4×4 per cycle** written into `plane_y` M10K  
- Plane mode: serial dot-product, not 256 parallel

### 2.4 Plane storage as regs

`plane_y[0:255]`, `plane_u/v[0:63]`, `write_*` mirrors — OK as small regs **if** not multi-ported combinationally. Better: **one M10K plane** with x,y address, serial apply of recon pixels.

### 2.5 Chroma at `1e1fbe1` (added cost on top of map2d sink)

`1e1fbe1` sink adds:

- `h264_chroma8x8_pred`  
- `h264_chroma_qp` (tiny LUT — OK combo)  
- `h264_chroma_dc_hadamard_inv` (2×2 + scale — small, a few DSP if mapped as mul)  
- `top_u/v`, `left_u/v`, plane chroma paths  

Integrate runs a **chroma-focused map** (coord-map3); treat chroma pred like I16: **no 64-wide combo pred port array**.

---

## 3. Cycle-iterative target design

### 3.1 Pixel / coeff granularity

| Stage | Current | Target |
|-------|---------|--------|
| Neighbor sample fetch | combo multi-tap from plane/top | 1–8 reads/cycle from M10K into small regs |
| I4 pred | 16 preds combo | keep small I4 unit (1.5k OK) or 1 px/cycle |
| I16 pred | 256 preds | **serial**: ≤16 cy/mode setup + 256 cy write, or 16×16 cy |
| Dequant | 16-lane | **1–4 lanes** time-mux; DSP target **≤ 8** total for sink |
| IDCT | 16-lane full | row-column serial 4×4 (classic) or 1D×2 passes |
| Recon Clip1 | 16-lane | match IDCT cadence |
| Plane write | block parallel for | 1–16 writes/cycle max |

### 3.2 DSP budget (hard)

| Consumer | Cap |
|----------|-----|
| Whole device | 112 |
| Product wire6 map | 74 already |
| **Sink + chroma residual** | **≤ 12 DSP** preferred, **≤ 20 hard** |
| Hadamard / chroma DC scale | shift-add where possible (qpel lesson: filters without DSP) |

If dequant needs mults, **one** shared multiplier + coeff index 0..15 over 16 cycles beats 16 mults.

### 3.3 ALM pre-register (next map after redesign)

| Piece | Target ALMs |
|-------|-------------|
| sink control + plane M10K glue | ≤ 800 |
| I4 pred | ≤ 1,500 (current OK-ish) |
| I16 pred serial | ≤ 1,000 |
| IQ/IDCT/recon serial | ≤ 1,200 |
| chroma pred + DC | ≤ 800 |
| **sink total** | **≤ 4,000 ALMs, ≤ 12 DSP** |

map2d **40,439 → ≤4,000** is a **~10×** cut (easier than traverse’s 650× if IQ is shared).

### 3.4 Cycle budget

Per 4×4 residual block: **32–128 cycles** OK.  
Per I-MB (16 luma 4×4 + chroma): **&lt; 2000 cycles** aligns with traverse §4.

---

## 4. Checklist

1. `top_row` / chroma tops: M10K, `MAX_PIC_W` for product = **320** (not 1024) unless needed.  
2. Kill `always @*` gathers over `plane_y`/`top_row`; use registered fetch states.  
3. Serialise IQ/IDCT to one shared unit; publish DSP count.  
4. I16 pred: do not emit `wire [7:0] pred [0:255]` into a sea of combo — write plane serially.  
5. Chroma: same rules; `h264_chroma_qp` may stay combo LUT.  
6. Freeze SHA → integrate map; no competing Quartus.  
7. Functional gate remains scorer/fixtures owned by traverse/mvd — area gate is separate.

---

## 5. Fit math (still unsoftened)

```
product        21,645
traverse     1,180,271   (blocker #1)
sink            40,439   (blocker #2, also DSP)
deblock         25,433   (blocker #3)
chroma           TBD
-----------------------
CANNOT FIT
```

Even **after** traverse→3k: `21645+3000+40439+25433 ≫ 41910` — **sink and deblock must both crash-diet** before a real loop filter returns to the chip. Identity deblock stays until then.
