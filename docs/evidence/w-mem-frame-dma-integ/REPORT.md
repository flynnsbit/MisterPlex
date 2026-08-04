# w-mem fabric DDR copy engine — NACK response evidence

**Branch:** `w-mem-frame-dma-integ`  
**Role:** fabric publication DMA + 3-port arbiter (rd-duck NACK closure)  
**Fit:** none (design + Verilator only)  
**Integration claim:** **NOT_INTEGRATION_READY** — staging `0x30601000` still unfilled by product; doorbell PLXD OPEN.

## M10K / ALM (EST, handbook width-bound)

| Module | M10K EST | Layout | Control |
|---|---:|---|---|
| `ddr_frame_dma` bounce[8]×64b | **2** | 64b → 2 blocks (not 1K×8) | header + static gate |
| `ddr_bus_arbiter3` m1 async_fifo 64b | **2** | same | header + static gate |
| Path total | **4 EST** | | free budget 356 M10K (post-strip fit parent) |

## rd-duck NACK items

| # | Finding | Status | Control |
|---|---|---|---|
| 1 | Mid-burst ADDR/BC/WE change under BUSY | **CLOSED** | legal ≤MAX_BURST=8; hold under waitrequest; unit TB `burst_mon=1` |
| 2 | Arbiter revoke mid-burst | **CLOSED** | `wr_lock` + `rd_lock` through full xact; yield only in DMA `ST_YIELD` window |
| 3 | TB false-green (BUSY=0, no G1 bit-exact) | **CLOSED** | rand BUSY G0b; G1 bit-exact dst; PROTO mon; FAULT twin REPRO_OK |
| 4 | Plex dual-kick store+DMA on status[12] | **CLOSED (RTL)** | `fabric_dma_store_kick` from `dma_done` only under `FABRIC_FRAME_DMA` |
| 5 | Staging unfilled / does not retire ARM memcpy | **OPEN** | product never populates `0x30601000` |

## Contended sim (product)

Control: `bash tests/unit/test_ddr_frame_dma_contended_rtl_sim.sh` → `true rc=0`

| Gate | Result |
|---|---|
| G2 misalign | PASS |
| G0 solo bit-exact | PASS cyc=644 t_full_us_scaled=4830 (PR_ideal=3840) |
| G0b rand BUSY bit-exact | PASS |
| G1 copy bit-exact | PASS rd=256 wr=256 |
| G1 present fairness | PASS max_deny=29 grants=22 (PR≤160) |
| G1 vs ARM T_copy | PASS margin_us=9991 (t_cont=4987 < arm=14978) |
| G1b CWE quantum | PASS max_deny=9 grants=486 (PR≤48) |
| PROTO burst hold | PASS |
| M10K prereg 2+2 | PASS |
| FAULT twin no-quantum | REPRO_OK max_deny=499 grants=0 |

## Arbitration scheme (product)

1. **m2 (DMA) default owner** while `m2_req`.
2. After Q=8 accepted m2 beats with `m0_cmd`, set `m0_pri` one-shot.
3. Yield only when `m2_yield_window` (DMA `ST_YIELD`, ≥2 clean !WE cycles after each WR burst) and `!xact_lock`.
4. m0 one-shot slice: finish RD response (`rd_lock`/`m0_rsp`), then force return to m2 even if present holds `m0_rd`.
5. New RD accept blocked while `rd_lock` (prevents continuous-RD reload hang).
6. Half-duplex scrub: write accept clears stale `rd_left`.

## Contention number (sim, DEVICE_BW_VERIFIED=0)

| Quantity | Value | Control |
|---|---:|---|
| PREREG T_copy ARM 720p | 14.978 ms | prior arm scope |
| G0 solo scaled full-frame | 4.830 ms | product_sim G0 |
| G1 contended scaled | 4.987 ms | product_sim G1 |
| Margin vs ARM | **9.991 ms** | 14978−4987 |
| Present max_deny @Q=8 | 29 cycles | G1 |
| MEASURE ratio vs PR_with_present | 86 (100=match) | G1 |

**Pre-register (earlier):** fabric retires T_copy with present duty; contended ~1.15× solo.  
**Hit/miss:** solo 4830 vs ideal 3840 (~1.26×); contended 4987 vs PR 5760 (under PR — HIT on arm margin).

## PL330 cross-check

PL330 remains 0 M10K alternate. Fabric path now has **legal bursts + measured present fairness in sim**. Staging fill still required before either path retires ARM memcpy. Prefer fabric if staging lands; PL330 if fabric port collision on device (DEVICE_BW_VERIFIED=0).

## NOT_INTEGRATION_READY

- Staging phys unfilled by product daemon path  
- Doorbell PLXD not written by mover  
- No device BW measurement  
- `FABRIC_FRAME_DMA` default remains a compose flag for w-fitgate  

