# CAVLC residual — honest gap assessment (w-scaler / fabric entropy)

**Date:** 2026-08-04  
**Scaler park:** `w-scaler-window-pipe` @ `6f354947` (28.8 MHz pipe + H_BLANK=320).  
**Evidence base:** quoted RTL + executed Verilator gates (true rc below).

## Parent finding (accepted)

`Plex.map.rpt` (p720probe1): **zero** `h264_*:instance` in hierarchy.  
Modules are in `files.qip` and parsed, but **not product-instantiated**.  
`PRODUCT_NO_STUB=1` strips `decode_stub` (`stream_path.sv:313`). ARM still owns full decode.

## What `h264_cavlc_residual.sv` implements today

### COMPLETE (block-level Baseline CAVLC residual_block)

| Spec element | Status | Evidence (file:line) |
|---|---|---|
| **nC prediction** left/up TotalCoeff | COMPLETE | `h264_cavlc_nc_predictor` L4–31: `nA_available`/`nB_available`, avg `(left+up+1)>>1`, table select nC&lt;2/4/8/≥8 |
| **coeff_token** tables 0–3 + chroma DC tab 4 | COMPLETE | `coeff_token_lookup` L146+ case tables; `coeff_token_table` port L39; chroma via tab==4 / `token_too_long` L102–103 |
| **TrailingOnes signs** | COMPLETE | `ST_SIGN` L824+ (all t1≤3 signs one cycle) |
| **level prefix/suffix** + suffixLength adapt | COMPLETE | `ST_LVL_PRE`/`SUF`/`STORE` L852–1127; `suffix_length` reg L91; `suffix_next`/`suffix_next_first` in STORE |
| **total_zeros** (luma + chroma DC) | COMPLETE | `ST_TZ_BIT` L1129+; `tz_is_chroma=(max_coeff==4)` L144; `total_zeros_lookup` |
| **run_before** | COMPLETE | `ST_RUN_BIT` L1179+ (up to 2 symbols/cycle) |
| **coeff placement** reverse scan | COMPLETE | `ST_PLACE_INIT` bulk place L1285+ |
| **maxNumCoeff 16 / 15 / 4** | COMPLETE | port `max_coeff` L40; TZ skip when `tc_r >= max_coeff` |

### PARTIAL / orchestration (not residual_block itself)

| Item | Status | Evidence |
|---|---|---|
| **Product hierarchy instance** | **ABSENT** | Parent map: 0 h264 instances. `stream_path.sv` has NAL/FIFO + stub strip; **no** `h264_decode_core` / residual instance |
| **MB residual walk (≤27 blocks, nC update)** | PARTIAL | `h264_decode_core.sv:583` `u_product_p16_residual0` — **hardcoded** `.coeff_token_table(3'd0)`, `.max_coeff(5'd16)`, `.bit_len(10'd512)`; not full I/P residual schedule |
| **nC neighbour memory (left/up TC store)** | ABSENT in product | Predictor is pure combo (L4–31); caller must latch TC — no product TC RAM |
| **Streaming bit port** | ABSENT | Block takes `rbsp[0:MAX_BYTES-1]` window + offsets (L41–43), not live `bitstream_bit_feeder` |
| **CABAC** | OUT OF SCOPE | Baseline CAVLC only (correct for product claim) |

### Skeleton (stim only)

`h264_decode_skeleton.sv:83` instantiates residual with stim XOR bytes — **not** a product path.

## Golden reference (oracle)

| Asset | Role |
|---|---|
| `host/libmisterplex/h264_cavlc.hpp` | `residualBlock()` + FFmpeg-layout tables |
| `host/libmisterplex/h264_residual_gold.hpp` | residual_csum / satS8 / first-residual gold |
| `host/libmisterplex/h264_slice_walk.hpp` | Real-stream residual window walk |

## Harness (non-tautological) — already in tree

| Gate | What | Result (this worktree) |
|---|---|---|
| `tests/unit/test_h264_cavlc_residual_verilator.sh` | POS: encode→RTL roundtrip 526 cases; NEG: `CAVLC_NEGATIVE_TABLE` XORs coeff[0] | **POS true rc=0**; **NEG true rc=1** (expected red) |
| `tests/unit/test_h264_cavlc_real_mb_cycles.sh` | Real 1280×720 Baseline stream: host walk vs RTL coeff | **true rc=0**, `coeff_match=PASS mismatches=0`, n_mb=3600 |

NEG mechanism (`tests/rtl/h264_cavlc_residual_tb_top.sv:89–93`):  
`assign coeff[i] = (i==0) ? (dut_coeff[i] ^ 16'sd1) : dut_coeff[i];` under `CAVLC_NEGATIVE_TABLE`.

## Throughput (measured, residual parse only)

Stream: `tests/fixtures/p720_cavlc/rk7_1280x720_cb_l30.264` (3600 MB).

| Metric | Value |
|---|---|
| cy/MB luma+chroma residual mean | **6.21** |
| p50 / p95 / p99 / max | **3 / 3 / 126 / 269** |
| 720p24 budget @ 20 MHz | 20e6/86400 ≈ **231.5 cy/MB** |
| HEADLINE | **PASS** CAVLC+recon_lb p95=37.0 &lt; 231.5 @20 MHz |

**Required clock (worst-case residual alone):**  
max 269 cy/MB × 86400 MB/s ≈ **23.3 MHz** if every MB hits max (pathological).  
**p99:** 126 × 86400 ≈ **10.9 MHz**.  
**Mean:** 6.21 × 86400 ≈ **0.54 MHz**.  

**Structure can hit 720p24 residual at clk_sys=20 MHz on this corpus** (p95+recon under budget).  
Full decode (headers+IQ+IDCT+intra/MC+deblock+DDR) is **other lanes**; residual is not the die-on-serial point for this content class.

Stage mix (luma+chroma probe): token ~30.6%, levels ~13.3%, run ~9.5%, place ~5.9%, other/start overhead ~30.6%.

## Architectural constraint

On-chip M10K cannot hold a 720p frame (parent: 0.51 frame).  
CAVLC block emits **16 coeffs** only — no frame buffer. DPB = DDR (w-nostub). **OK.**

## Gap closure order (smallest first)

1. ~~Block-level bit-exact~~ — DONE (POS+NEG+real MB).  
2. **Product wire:** instantiate residual path under stream/decode hierarchy (needs **w-path** / decode integrate — handoff).  
3. **MB walker:** drive `coeff_token_table` from `h264_cavlc_nc_predictor` + TC neighbour mem; clear decode_core hardcodes (`h264_decode_core.sv:583+`).  
4. **Bit window fill** from `bitstream_bit_feeder` / NAL RBSP (w-path).  
5. Do **not** build on-chip DPB.

## Commands (parent re-run)

```bash
bash tests/unit/test_h264_cavlc_residual_verilator.sh; echo "true rc=$?"
bash tests/unit/test_h264_cavlc_real_mb_cycles.sh; echo "true rc=$?"
python3 tests/unit/test_cavlc_gap_assessment_static.py; echo "true rc=$?"
```
