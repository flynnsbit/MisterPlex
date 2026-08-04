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
| 3 | TB false-green (BUSY=0, no G1 bit-exact) | **CLOSED** | G0b rand BUSY bit-exact; **G1 present+rand BUSY bit-exact**; PROTO mon; FAULT REPRO_OK |
| 3b | Mid-response m0 re-accept / rd_left freeze | **CLOSED** | arbiter: no m0 RD accept when `m2_req`; always count DOUT under `rd_lock` (not gated on `!sel_rd`) |
| 3c | One-cycle RD vs arbiter posedge skew under BUSY | **CLOSED (TB)** | dual-sample phys: pre-edge + post-edge RD start; unit TB unchanged post-edge (solo DMA) |
| 4 | Plex dual-kick store+DMA on status[12] | **CLOSED (RTL)** | `fabric_dma_store_kick` from `dma_done` only under `FABRIC_FRAME_DMA` |
| 5 | Staging unfilled / does not retire ARM memcpy | **OPEN** | product never populates `0x30601000` |

## Contended sim (product)

Control: `bash tests/unit/test_ddr_frame_dma_contended_rtl_sim.sh` → `true rc=0`

| Gate | Result |
|---|---|
| G2 misalign | PASS |
| G0 solo bit-exact | PASS cyc=644 t_full_us_scaled=4830 (PR_ideal=3840) |
| G0b rand BUSY bit-exact | PASS |
| G1 copy bit-exact (present+**rand BUSY**) | PASS rd=256 wr=256 cyc=737 |
| G1 present fairness | PASS max_deny=48 grants=21 (PR≤160; owner-starve only) |
| G1 vs ARM T_copy | PASS margin_us=9451 (t_cont=5527 < arm=14978) |
| G1b CWE quantum | PASS max_deny=10 grants=49 (PR≤48) |
| PROTO burst hold | PASS |
| M10K prereg 2+2 | PASS |
| FAULT twin no-quantum | REPRO_OK max_deny=499 grants=0 |

## Arbitration scheme (product)

1. **m2 (DMA) default owner** while `m2_req`.
2. After Q=8 accepted m2 beats with `m0_cmd`, set `m0_pri` one-shot.
3. Yield only when `m2_yield_window` (DMA `ST_YIELD`, ≥2 clean !WE cycles after each WR burst) and `!xact_lock`.
4. m0 one-shot slice: finish RD response (`rd_lock`/`m0_rsp`), then force return to m2 even if present holds `m0_rd`.
5. New RD accept blocked while `rd_lock` (prevents continuous-RD reload hang).
6. No new m0 RD accept when `m2_req` (prevents NBA race: owner→m2 with stale `rd_left≤1`).
7. DOUT_READY always decrements `rd_left` under lock (present held `m0_rd` must not skip last beat).
8. Half-duplex scrub: write accept clears stale `rd_left`.

## Contention number (sim, DEVICE_BW_VERIFIED=0)

| Quantity | Value | Control |
|---|---:|---|
| PREREG T_copy ARM 720p | 14.978 ms | prior arm scope |
| G0 solo scaled full-frame | 4.830 ms | product_sim G0 |
| G1 contended+rand BUSY scaled | 5.527 ms | product_sim G1 busy_force=-1 |
| Margin vs ARM | **9.451 ms** | 14978−5527 |
| Present max_deny @Q=8 | 48 cycles | G1 owner-starve |
| MEASURE ratio vs PR_with_present | 95 (100=match) | G1 |

**Pre-register:** fabric retires T_copy with present duty under rand waitrequest; arm margin stays >9 ms.  
**Hit/miss:** solo 4830 vs ideal 3840 (~1.26×); contended+rand 5527 vs PR 5760 (under PR — HIT).  
**DEVICE_BW_VERIFIED=0** — sim only; port collision on device unmeasured.

## PL330 cross-check

PL330 remains 0 M10K alternate. Fabric path now has **legal bursts + measured present fairness in sim**. Staging fill still required before either path retires ARM memcpy. Prefer fabric if staging lands; PL330 if fabric port collision on device (DEVICE_BW_VERIFIED=0).

## NOT_INTEGRATION_READY

- Staging phys unfilled by product daemon path  
- Doorbell PLXD not written by mover  
- No device BW measurement  
- `FABRIC_FRAME_DMA` default remains a compose flag for w-fitgate  

