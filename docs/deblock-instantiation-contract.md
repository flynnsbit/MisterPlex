# Deblock Filter Instantiation Contract

Owner: w-deblock  
Module: `h264_deblock_mb_scheduler` (in `h264_deblock_scheduler.sv`)  
Status: **verified module-level, not instantiated in product**  
Consumers: w-rel (datapath), w-ctl (line buffer), w-dpb (post-deblock writeback)

## Port Interface

```systemverilog
module h264_deblock_mb_scheduler (
    input  wire              clk,
    input  wire              reset,

    // ─── Control handshake ───
    input  wire              start,       // pulse high for 1 cycle to begin
    output wire              busy,        // high while processing
    output wire              done,        // pulse high for 1 cycle when complete

    // ─── Slice parameters (stable before start) ───
    input  wire [1:0]        disable_idc,       // 0=filter, 1=disable, 2=disable across slice
    input  wire [5:0]        qp,                // QPy (luma QP for this MB)
    input  wire signed [4:0] alpha_offset,      // slice_alpha_c0_offset_div2 * 2
    input  wire signed [4:0] beta_offset,       // slice_beta_offset_div2 * 2

    // ─── Neighbor availability (from w-ctl) ───
    input  wire              left_avail,        // left MB exists and is not outside slice (idc=2)
    input  wire              top_avail,         // top MB exists
    input  wire              left_same_slice,   // for disable_idc=2
    input  wire              top_same_slice,

    // ─── Per-4x4-block metadata (16 blocks per MB, H.264 raster scan) ───
    input  wire [15:0]       mb_intra,          // bit[i] = 1 if block i is intra-coded
    input  wire [15:0]       mb_nonzero,        // bit[i] = 1 if block i has nonzero residual
    input  wire signed [11:0] mb_mvx  [0:15],   // motion vector x (quarter-pel)
    input  wire signed [11:0] mb_mvy  [0:15],   // motion vector y (quarter-pel)
    input  wire [1:0]        mb_ref  [0:15],    // reference index

    // ─── Left neighbor metadata (4 blocks along right edge of left MB) ───
    input  wire [3:0]        left_intra,
    input  wire [3:0]        left_nonzero,
    input  wire signed [11:0] left_mvx [0:3],
    input  wire signed [11:0] left_mvy [0:3],
    input  wire [1:0]        left_ref [0:3],

    // ─── Top neighbor metadata (4 blocks along bottom edge of top MB) ───
    input  wire [3:0]        top_intra,
    input  wire [3:0]        top_nonzero,
    input  wire signed [11:0] top_mvx [0:3],
    input  wire signed [11:0] top_mvy [0:3],
    input  wire [1:0]        top_ref [0:3],

    // ─── Luma samples (256 bytes, 16x16) ───
    input  wire              sample_wr,         // write strobe
    input  wire [7:0]        sample_waddr,      // {y[3:0], x[3:0]}
    input  wire [7:0]        sample_wdata,
    input  wire [7:0]        sample_raddr,
    output wire [7:0]        sample_rdata,      // combinational read

    // ─── Chroma samples (64 bytes each for Cb and Cr, 8x8) ───
    input  wire              chroma_wr,
    input  wire [5:0]        chroma_waddr,      // {y[2:0], x[2:0]}
    input  wire [7:0]        chroma_wdata,
    input  wire              chroma_sel,        // 0=Cb, 1=Cr

    input  wire [5:0]        chroma_raddr,
    input  wire              chroma_rsel,       // 0=Cb, 1=Cr
    output wire [7:0]        chroma_rdata,      // combinational read

    // ─── Chroma QP (QPc from H.264 table 8-15) ───
    input  wire [5:0]        chroma_qp,         // QPc ≠ QPy above QP 30

    // ─── Performance instrumentation ───
    output wire [7:0]        cycle_count        // cycles used this MB
);
```

## Handshake Protocol

```
                 ┌──────────────────────────────────────┐
    start ──────►│ Load samples (sample_wr, chroma_wr)  │
                 │ Set metadata, qp, neighbors          │
                 │ Assert start for 1 cycle             │
                 └──────────────┬───────────────────────┘
                                │
                 ┌──────────────▼───────────────────────┐
                 │ busy=1, processing luma→Cb→Cr        │
                 │ 80-96 cycles (do NOT write samples)  │
                 └──────────────┬───────────────────────┘
                                │
                 ┌──────────────▼───────────────────────┐
    done ◄───────│ done=1 pulse, busy=0                 │
                 │ Read filtered samples via raddr      │
                 └──────────────────────────────────────┘
```

1. **Load phase**: Write reconstructed (pre-deblock) samples via `sample_wr`/`chroma_wr`. Set all metadata inputs. All inputs must be stable before `start`.
2. **Processing phase**: `busy=1`. Do NOT write to samples during this time. Internal state machine processes luma V→H, Cb V→H, Cr V→H.
3. **Done**: `done` pulses for 1 cycle. Read filtered output via `sample_raddr`/`chroma_raddr`.

## Timing Budget

| Scenario | Cycles |
|----------|--------|
| Internal edges only (no boundary neighbors) | 80 |
| All edges including boundaries (full neighbors) | 96 |
| `disable_idc=1` (skip all filtering) | 1 |

Budget allocation: **100 cycles/MB**. Measured: 96 worst-case. Margin: 4 cycles.

## Ordering Contract (CRITICAL — getting this backwards drifts silently)

> **DPB stores POST-DEBLOCK output** (reference for motion compensation).  
> **Intra prediction uses PRE-DEBLOCK reconstructed neighbors.**

The datapath must:
1. Reconstruct MB (IDCT + prediction) → write to deblock register files
2. Deblock filter runs → produces POST-DEBLOCK output
3. Write POST-DEBLOCK to DPB (for future MC reference)
4. For intra-coded MBs, store PRE-DEBLOCK left/bottom edge in neighbor context (for intra prediction of next MB)

## Line-Buffer Requirements (for w-ctl)

Deblocking needs neighbor metadata + samples for boundary edges:

| Buffer | Content | Size |
|--------|---------|------|
| Left column metadata | 4 × {intra, nonzero, mvx[11:0], mvy[11:0], ref[1:0]} | 4 × 28 bits = 112 bits |
| Top row metadata | 4 × {intra, nonzero, mvx[11:0], mvy[11:0], ref[1:0]} | 4 × 28 bits = 112 bits |
| Left column samples | Not currently used (zeros for boundary p-side) | Future: 4×16 = 64 luma + 4×8 = 32 chroma bytes |
| Top row samples | Not currently used (zeros for boundary p-side) | Future: 16×4 = 64 luma + 8×4 = 32 chroma bytes |

**Currently the module uses zeros for boundary p-side samples** — this is documented as a known gap. When neighbor sample ports are added, we need ~192 bytes of line buffer for full accuracy.

**Request to w-ctl**: please store the metadata (112 bits per side) alongside whatever neighbor context you are already sizing for the parser. The deblock filter reads the same block-level metadata that CABAC/CAVLC needs for `coded_block_pattern` and MV prediction — **one buffer, not two**.

## bS Derivation Dependencies

The boundary strength derivation requires context that lives outside this module:

| bS value | Required context | Source |
|----------|-----------------|--------|
| 4 | Either block is intra AND it's a MB boundary | Parser (mb_type) |
| 3 | Either block is intra, internal edge | Parser (mb_type) |
| 2 | Either block has nonzero residual | CAVLC/CABAC (coded_block_pattern, TotalCoeff) |
| 1 | Different ref indices OR MV diff ≥ 4 qpel | MC (MVs, ref_idx) |
| 0 | Same ref, same MV (within 4 qpel), no nonzero | — |

## Chroma bS

For 4:2:0, chroma uses the **maximum** of the two luma bS values corresponding to each chroma edge segment. This is handled internally — the scheduler stores luma bS during the luma phase and looks them up during chroma processing.

## QPc (Chroma QP)

The `chroma_qp` input must be the QPc value from H.264 table 8-15, **not** QPy. QPc = QPy for QP ≤ 29, but diverges above QP 30. The caller must perform the table lookup. This is verified by the `testChromaQPcDivergence` test.

## Integration Checklist for w-rel

- [ ] Instantiate `h264_deblock_mb_scheduler` in `h264_decode_top.sv`
- [ ] Wire reconstruction output → `sample_wr`/`chroma_wr` (after IDCT + prediction)
- [ ] Wire `sample_rdata`/`chroma_rdata` → DPB write path (POST-DEBLOCK)
- [ ] Wire neighbor metadata from w-ctl's line buffer
- [ ] Wire QPc from PPS/slice header (table 8-15 lookup)
- [ ] Wire `done` → triggers DPB write + advance to next MB
- [ ] Wire `disable_idc` from slice header
- [ ] Verify PRE-DEBLOCK neighbors go to intra predictor, not POST-DEBLOCK

## Verification Status

- 15 Verilator tests green (luma + chroma + 3 red proofs)
- bS 0–4 all exercised with histogram assertion
- QPc > 30 divergence proven (16/64 Cb samples differ)
- Chroma: 28/64 Cb + 28/64 Cr samples filtered
- Degeneracy assertion: if reference changes 0 samples → FAIL
- **Module not in any datapath** — awaiting integration
