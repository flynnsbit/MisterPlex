# M10K depth×width — path lane correction

**Status:** control-backed correction after parent withdrew the
"1280 bytes per M10K" premise (Cyclone V handbook: depths are powers of two;
legal configs include `1K×8`, `256×40`, … — **not** `1280×8`).

Budget total is unchanged: **356 M10K free** post-strip (parent fit HIT
`197/553`). What changes is how far those blocks go for **line buffers**.

## Handbook (parent, verified by handbook — treat as design input)

| Config | Bytes if used as pure storage |
|--------|-------------------------------|
| 1K × 8 | **1024** B (byte-wide max depth) |
| 256 × 40 | 1280 B (packed; **5 px/word** access) |
| 256 × 32 | 1024 B per block at 32b |
| 512 × 16 | 1024 B per block at 16b |

A naive 1280-pixel **8-bit** line is **not** one M10K. At `1K×8` it needs
two blocks (1024+256). Packed `256×40` hits 1280 B in one block but forces
5-pixel granularity.

## Measured control — product `line_buf_ram` @ 480p (not path-owned)

**Control artifact:**  
`MisterPlex-wt-nostub-hygiene/.../nostub-poststrip1/Plex.fit.rpt`  
Fitter Resource Utilization by Entity, leaf `|line_buf_ram:gen_line[*].{y,u,v}ram|`.

| Plane | WIDTH (qwords) | DATA_W | useful bits | **M10K (fit)** |
|-------|----------------:|-------:|------------:|---------------:|
| Y | 78 (=624/8) | 64 | 4992 | **2** |
| U | 39 | 64 | 2496 | **2** |
| V | 39 | 64 | 2496 | **2** |

- Instances: **16** of each plane (`LINE_SLOTS = LINE_COUNT*2`, LINE_COUNT=8)
- **Total line_buf M10K = 16×(2+2+2) = 96** (leaf rows only; do not sum altsyncram children)
- Layout class: **64-bit dual-clock RAM** (`(* ramstyle="M10K" *)`), **not** byte-wide 1K×8
- Bits match `WIDTH*64` exactly; M10K count is **2 per plane per slot** even when
  useful bits ≪ 2×10240 — width 64 and non-power-of-two depth drive packing

### 720p scale (ESTIMATE — unfitted)

| Plane | WIDTH | useful bits | EST M10K/slot (same 64b class) |
|-------|------:|------------:|-------------------------------:|
| Y | 160 | 10240 | **2** (still 2×256×32 class if depth rounds to 256) |
| U/V | 80 | 5120 | **2** each (same as 480p chroma pattern) |

Per slot EST **6 M10K** — same structure as 480p fit, **not** 1 M10K/luma-line.
LINE_SLOTS = LINE_COUNT×2. At LINE_COUNT=16 → **32 slots × 6 = 192 M10K EST**
(rd-duck confirmed). Prior “96” was a slots/2 slip — **retracted**.
Alternates (not product RTL): byte-wide 1K×8 → 4/slot×32 = **128**; pack40 →
3/slot×32 = **96** but needs 64↔40 gearbox + PPC/scaler straddle handling.
**Closes only with a 720p-enabled fit entity row.**

## w-path module M10K table (republished)

| Module | M10K | Layout / control |
|--------|-----:|------------------|
| `ddr_i420_bank_geom` | **0** | no RAM (source) |
| `ddr_frame_base_mux` | **0** | no RAM (source) |
| `ddr_i420_store_width_check` | **0** | no RAM (source) |
| `ddr_publish_copy_budget` | **0** | params only; pins bounce EST below |
| `ddr_publish_job` | **0** | wires |
| `ddr_publish_engine` bounce | **0** | `ramstyle="logic"` (not M10K) |
| `ddr_frame_dma` bounce DEPTH=128×64b | **2 EST** | 8192 useful bits; **layout EST 2×(256×32)** — was PREREG 1 under vague "1024 B" wording; **corrected to 2**. Unfitted. |
| PL330 path | **0** fabric | HPS DMA; device BW parent-only |
| dyn-base mux retire | **0** | preferred when payload already in bank |

**None of the path pure-logic 0s depended on the 1280 B premise.**  
**The only republish that moves a number is fabric bounce 1→2 EST.**

## What path is *not* claiming

- Present `line_buf_ram` 720p M10K is **w-mem / store geometry**, not closed by path ABI
  modules. Use the measured 480p 2/2/2 packing as the prior, not 1 M10K per luma line.
- ALM figures for bounce/DMA remain UNVERIFIED pre-fit placeholders.

## Parent device commands (path does not run these)

```bash
# After a 720p-enabled fit only — extract leaf line_buf M10K:
rg 'line_buf_ram:gen_line' remote_out/<tag>/Plex.fit.rpt | rg -v altsyncram
```
