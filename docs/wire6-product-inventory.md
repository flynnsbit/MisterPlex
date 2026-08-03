# Deployed wire6 (`14eaeff3`) — honest decode inventory

**RBF:** `14eaeff3270a6f59a434e0f777ed823d`  
**Provenance:** `.agent-work/integ-wiring/WIRE6_PROVENANCE.md`  
**Rule:** BUILD_OK ≠ decodes. This document separates the two.

## What it implements (product / Quartus path)

| Block | Present? | What it actually does | ALMs (wire6 fit) |
|-------|----------|----------------------|------------------|
| Hybrid FS gate | **Yes** | `Plex.sv`: `stub_allow &= product_recon_ok_w` | (in top) |
| `product_recon_ok` | **Partial** | Sticky only for pure FPGA-owned **I-slice** with residual_ok; inter never sets it | — |
| MVP + mvd → fetch MV | **Yes** | `h264_mv_pred_part` + `fetch_mv_* = prod_mv_*` (not hardwired 0) | ~436 (pred) |
| Serial MC | **Yes** | `h264_mc_{block,luma_qpel,chroma_epel}`: one 6-tap / epel datapath, M10K windows, multi-cycle | MC block ~520 (luma ~350 + chroma ~168) |
| Clip1(pred+residual) | **Yes** | Sample-serial `inter_clip_u8(pred + residual)` into recon stream | (in stub) |
| `h264_dpb_ref_commit` | **Yes (product)** | Instantiated outside TB-only; owns deblock→DPB→promote + fetch | ~1287 |
| Deblock (Quartus) | **Identity in deployed 14eaeff3**; **serial filter WIP** | Deployed RBF: M10K identity (~960 ALMs). WIP on `feat/disp-fix` after `db01a42`: `h264_deblock_mb_serial` (cycle-iterative, one `h264_deblock_edge`, M10K windows) wired under `ifndef VERILATOR`. **Map area not yet measured.** Pre-register ≤2500 ALMs. | wire6 ~960; serial TBD |
| Deblock (Verilator) | Full multi-port | `ramstyle=logic` windows + `always @*` 4-lane gather; unit-sim only | would be ~34k (wire4) |
| IQ/IDCT/recon4x4 | **Yes** | Existing decode_core path | idct ~897 |
| CAVLC / slice parse | **Partial** | Existing path; first-MB / limited P walk (traverse lane not merged) | — |
| ARM present / DDR | **Yes** | Unchanged host frame path; playback liveness uses this | present ~5k |

## What it does **not** implement

1. **Normative in-loop deblock on device** — product path is identity; `reference_h264_loop_filter=disabled` in full-frame log.
2. **Correct full-frame reconstruction** — measured `intra=0/300 inter=0/3300` (fullframe-mc2.log); strict pixel compare FAIL vs reference decoder.
3. **Complete I-slice residual plane** — IDR commit source is block0 residual + `8'd128` fill for the rest (`recon_src_y_idr`), not full MB residual map.
4. **All-MB P traversal** — `fe310d3` traverse module not merged into this tree.
5. **FPGA→ARM recon export** — `fd9646b` PLXO path not merged.
6. **Bit-exact residual add for all partitions** — single-partition oriented fill; sub-MB incomplete.
7. **HDMI-proven picture quality** — no capture hardware; UNKNOWN to automation.

## Synthetic XOR residual (important)

`decode_stub.sv` still defines:
```systemverilog
dpb_filtered_sample = (Y) ? (8'h20 ^ abs_x ^ …) : …
```
Those wires feed **diagnostic `dpb_filtered_*_out` ports**.  
**DPB `mem_we`/`mem_wdata` are driven by `u_product_ref_commit`**, not by that XOR expression (see instance at product ref_commit).  

So: product DPB store path is recon→(identity)deblock→DPB, **not** the old XOR fill into `mem_*`.  
However IDR plane content is still largely constant-128, and deblock is identity, so reference quality remains non-normative. Any old `inter=1606/3300` figure remains void.

## Full-frame measurement (pre-deploy, quoted)

From `.agent-work/integ-wiring/fullframe-mc2.log`:
```
mv_l0=(0,24) [quarter-pel units]
I420_CANDIDATE_SCORE summary intra=0/300 inter=0/3300 strict_pass=0
OK native inter provenance: candidate_stage=product_clip1_pred_plus_residual_then_h264_dpb_ref_commit_deblock
  reference_state=decoded_deblocked_via_h264_dpb_ref_commit
  reference_h264_loop_filter=disabled
FAIL full-frame strict: stream_path pixels differ from reference decoder at frame 0
```

## Playback evidence (not decode quality)

- Cast PMS `YOUR-PLEX-SERVER:32400` → HTTP 200  
- `fpga frame_tx ok via DDR`, `frames≈717 vfps=23.0 clock=av-lock`  
- This proves **present path liveness** with the new bitstream; it does **not** prove FPGA H.264 pixels are correct (ARM may supply present frames; no pixel readback).

## Presentation safety property

`stub_allow = ~host_owns_fs & ~ingest_dl & ~ddr_busy & product_recon_ok_w`  
Because `product_recon_ok` is I-only, FPGA stub reconstruction should **not** present on pure inter streams — host/ARM present remains the live picture path for typical cast content.

## Serial real deblock — pre-register vs measure

| Metric | Pre-register | Measured (`quartus_map` sha `0114826`) |
|--------|--------------|----------------------------------------|
| `h264_deblock_mb_serial` ALMs | **≤ 2,500** | **25,433** — **MISS (10.2×)** |
| Soft concern | > 3,000 | tripped |
| Hard redesign | > 4,000 | tripped |
| Whole design map estimate | — | **51,294 ALMs** (device 41,910) |
| `h264_deblock_edge` alone | — | 2,715 |
| wire6 identity baseline | 960 | (deployed 14eaeff3 still identity) |

Log: `.agent-work/integ-wiring/quartus_map_serial_deblock1.log`  
ALM card: `.agent-work/integ-wiring/serial-deblock-map1-ALMS.txt`

### Redesign direction (next)
1. **Single-lane** edge filter (not 4-wide `h264_deblock_edge`) — 4× less parallel mux.
2. **Linear M10K only** — no `ly[]`/`ty[]` variable-index register files; one address register + one rdata.
3. **Address ROM / counter** for gather sequence — kill large signed `always @*` coord mux trees.
4. Re-map before any fit. Deployed device stays wire6 until authorize.

### Why not “unroll edges”
wire3 taught combo 16×16 qpel = 318k ALMs. wire4 taught multi-port deblock windows = ~34k.  
v1 serial still 25k — better than 34k but **not shippable**.
## coord-map2 (2026-07-30)
See docs/coord-map2-ALMS.txt. Decode path at traverse@6dc5993 maps to ~1.24M ALMs (traverse alone ~1.18M comb). **Scoped design does not fit.**

## coord-map3 chroma (2026-07-30)
See docs/coord-map3-ALMS.txt. Chroma leaves cheap (qp=8, dc=249, chr8=0.7–3.9k); sink still ~40k+92 DSP. Traverse remains the 30× blocker.
