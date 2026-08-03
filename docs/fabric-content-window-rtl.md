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
| **Fabric NN window + native publish** | **no scale** (memcpy only until stride/zero-copy) | **Yes** |

NN in fabric is “uglier” than polyphase, but **ARM leaves the scale loop entirely**. ascal keeps HDMI quality.

---

## 720p from day one

| Parameter | Value | Why |
|-----------|------:|-----|
| `STORE_W` | **1280** | one M10K per luma line |
| `STORE_H` | **720** | 720p frame |
| `content_w/h/x0/y0` | **11 bits** | covers 1280×720 |
| `h_de` / `v_de` | **11 bits**, 0→default 529/480 | 720p DE = reg write, not redesign |
| Window SX | `floor(cw * 65536 / h_de)` | any DE |
| Legacy SX | `FRAME_W * 39647 / 320` | bit-exact 480p product when `win_enable=0` |

Product 480p still uses H_DE=529 FBAR lock. 720p DE retiming is separate (colorbars/Template); the mapper already accepts `h_de=1280,v_de=720`.

`present_core` currently slices store coords to `clog2(FRAME_*)` for today’s `ddr_frame_store` (FRAME 640). **w-mem 720p fit** raises FRAME/CODED and drops the slice.

---

## ARM milliseconds removed

| Lever | ms/f | How known | Condition |
|-------|-----:|-----------|-----------|
| **Scale leg** | **2.954** | FEED table `docs/evidence/p480/p720-bus-and-bitrate-margin.md` (+scale delta on 624×480, 1800 frames) | ARM vf scale **off** after `win_enable=1` + native WxH publish |
| Present/DDR bytes (320 path) | **unknown (pre-reg 2.5–5.5)** | linear-in-bytes bound on FEED present 10.411; **not measured** with this RTL on device | Needs `copy_us`/`flush_us` after native publish **and** runtime stride (not in this slice) |
| 720p scale leg | **unknown** | would be ≥320-path scale cost when ARM up/down scales 720 | Measure FEED-class scale delta on real 720p content (parent) |

**This slice alone does not turn off ARM scale** — `fabric_win_enable` defaults **0** (safe with today’s 624 publish). Full ARM evacuation = this RTL + mailbox enable + ARM identity publish (+ stride for byte win).

Parent 1080p blip (32.4 ms/f decode) shows decode is bitrate-dominated; **evacuating scale/present is what frees 720p headroom**. Do not over-claim from the synthetic blip.

---

## Register map (PLXW @ doorbell+0x130 — reconcile w/ mailbox + w-mem)

| Field | Bits | Reset | Notes |
|-------|-----:|------:|-------|
| win_enable | 1 | 0 | 0=legacy full-bank |
| content_w | 11 | 624 | delivery width (320…1280) |
| content_h | 11 | 480 | delivery height (240…720) |
| content_x0/y0 | 11 | 0 | origin in bank |
| h_de | 11 | 0→529 | active DE width for SX |
| v_de | 11 | 0→480 | active DE height for SY |
| y_stride | 12 | 624 | **ddr_frame_store follow-on** (1280 for 720p) |
| chroma_stride | 11 | stride/2 | follow-on |

---

## Area / timing pre-reg

Baseline RBF `8fdf440f`: ALM 56%, M10K 84% blocks / 53% bits, DSP 39%, clk_sys 20 MHz.

| Resource | Δ | Reasoning |
|----------|--:|-----------|
| ALM | +100…+250 | 20b scales, 11×20 muls, add/clamp, DE mux |
| M10K | 0 | NN, no linebufs |
| DSP | 0…2 | optional hc×sx |
| Fmax | low–mod risk | dividers **only** on reg update → `sx_r/sy_r`; pixel path mul+add |

Threat: synth folding `/h_de` into pixel path — keep register cut.

---

## Sim evidence (true rc)

```
legacy     rc=0  REPRO quarter_class
window320  rc=0  PASS unique 320×240
legacy480  rc=0  PASS identity 480
720de480   rc=0  PASS x→1279 y→719 on 529×480 DE
720id      rc=0  PASS 1280×720 identity
host math  rc=0
```

## Follow-ons

1. PLXW mailbox decode  
2. `ddr_frame_store` runtime stride + 1280 CODED (w-mem)  
3. ARM native publish + win_enable=1  
4. Parent glass + FEED remeasure  
