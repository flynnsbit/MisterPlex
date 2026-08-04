# w-mem fabric DDR copy engine — NACK response evidence

**Branch:** `w-mem-frame-dma-integ`  
**Role:** fabric publication DMA + 3-port arbiter + explicit source contract  
**Fit:** none (design + Verilator only)  
**Integration claim:** **NOT_INTEGRATION_READY** — product daemon still `sendDdrFrame` bank memcpy; doorbell PLXD OPEN; `FABRIC_FRAME_DMA` default OFF so fit cannot price arbiter3 routing.

## M10K / ALM (republish — rd-duck fit correction)

**Control:** `nostub-poststrip1/Plex.fit.rpt` L5258–5259:  
`|ddr_bus_arbiter:ddr_arb|` **M10Ks=0** BlockMemBits=0; `|async_fifo:m1_rsp_fifo|` **M10Ks=0** BlockMemBits=0 ALMs_for_memory=0.0.  
`async_fifo.sv` forces `ramstyle="MLAB"` — prior arbiter3 EST=2 was wrong for this codebase.

| Layout | Depth×width | ramstyle | M10K |
|---|---|---|---:|
| old bounce | 128×64 | forced M10K | **2 EST** (64b width-bound; bits/10240 illegal) |
| rev bounce | 8×64 (512b) | forced M10K | **2 EST** (still width-bound; wastes 2 blocks) |
| **rev bounce (chosen)** | **8×64** | **MLAB** | **0** |
| arbiter3 m1_rsp_fifo | AW=3 ×64 | MLAB (`async_fifo`) | **0** (fit analogue measured) |
| **Path total** | | | **0 M10K** |

ALM: fit `ddr_arb` 338.3 (incl. fifo). Bounce MLAB unfitted; small vs 27,556 free.

## rd-duck NACK items

| # | Finding | Status | Control |
|---|---|---|---|
| 1 | Mid-burst ADDR/BC/WE change under BUSY | **CLOSED** | legal ≤MAX_BURST=8; hold under waitrequest; unit TB `burst_mon=1` |
| 2 | Arbiter revoke mid-burst | **CLOSED** | `wr_lock` + `rd_lock` through full xact; yield only in DMA `ST_YIELD` window |
| 3 | TB false-green (BUSY=0, no G1 bit-exact) | **CLOSED** | G0b rand BUSY bit-exact; **G1 present+rand BUSY bit-exact**; PROTO mon; FAULT REPRO_OK |
| 3b | Mid-response m0 re-accept / rd_left freeze | **CLOSED** | arbiter: no m0 RD accept when `m2_req`; always count DOUT under `rd_lock` |
| 3c | One-cycle RD vs arbiter posedge skew under BUSY | **CLOSED (TB)** | dual-sample phys: pre-edge + post-edge RD start |
| 4 | Plex dual-kick store+DMA on status[12] | **CLOSED (RTL)** | `fabric_dma_store_kick` from `dma_done` only under `FABRIC_FRAME_DMA` |
| 5 | Staging unfilled / does not retire ARM memcpy | **OPEN (contract landed)** | API+unit gate; product path not switched |
| 6 | `std::vector` not legal `src_phys` | **CLOSED (contract)** | `fabric_dma_source.hpp` + `test_fabric_dma_source` negatives |

## Source contract (rd-duck #5/#6)

**Fact (quoted):** `arm/misterplexd/media_player.cpp:3467` `std::vector<uint8_t> frame(frameBytes)` — heap, not contiguous PA.

**Explicit path (host API, no device):**
1. Map reserved ring `kFabricDmaStagingPhys == kPl330StagingPhys == 0x30601000`, size `0x180000` (one 720p bank stride).
2. `FabricDmaStagingMap::loadCpuBytes(vector.data(), len)` — CPU fill of reserved PA (still a CPU copy; **not** bank-publication retire).
3. `visibilityBarrier()` — seq_cst fence + dummy load (noncached `/dev/mem`; no D-cache clean).
4. `armKick()` → only then is `src_phys` legal for status[12] / `ddr_frame_dma`.
5. Fabric Avalon copy staging→bank; `dma_done` → frame_store kick.

**Negatives (unit, a naive cast fails):**
- `fabricDmaMustStageHostPointer(vector.data())` always true
- truncated heap VA rejected by `fabricDmaSrcPhysLegal`
- oversize / unaligned / phys=0 / bank-base-as-src rejected
- `armKick` before fill rejected

**Control:** `./build/test_fabric_dma_source` → `true rc=0` (`test_fabric_dma_source: OK checks_passed`)

**Honesty:** staging fill does **not** retire the ~15 ms bank publication copy by itself. Fabric DMA does staging→bank. Product still calls `sendDdrFrame` bank memcpy. CMA/SG not implemented (single `src_phys` only).

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
| M10K prereg 0+0 (MLAB) | PASS |
| FAULT twin no-quantum | REPRO_OK max_deny=499 grants=0 |

## Arbitration scheme (product)

1. **m2 (DMA) default owner** while `m2_req`.
2. After Q=8 accepted m2 beats with `m0_cmd`, set `m0_pri` one-shot.
3. Yield only when `m2_yield_window` (DMA `ST_YIELD`) and `!xact_lock`.
4. m0 one-shot slice then force return to m2.
5. No new m0 RD accept when `m2_req`.
6. DOUT_READY always decrements `rd_left` under lock.

## Contention number (sim, DEVICE_BW_VERIFIED=0)

| Quantity | Value | Control |
|---|---:|---|
| PREREG T_copy ARM 720p | 14.978 ms | prior arm scope |
| G0 solo scaled full-frame | 4.830 ms | product_sim G0 |
| G1 contended+rand BUSY scaled | 5.527 ms | product_sim G1 busy_force=-1 |
| Margin vs ARM | **9.451 ms** | 14978−5527 |
| Present max_deny @Q=8 | 48 cycles | G1 owner-starve |

**DEVICE_BW_VERIFIED=0** — sim only; port collision on device unmeasured.

## PL330 cross-check

PL330 remains 0 M10K alternate sharing the same staging PA. Fabric path has legal bursts + measured present fairness in sim. Prefer fabric if product staging+kick lands; PL330 if fabric port collision on device.

## NOT_INTEGRATION_READY

- Product daemon does not call `loadCpuBytes`+status[12] (still `sendDdrFrame`)
- Doorbell PLXD not written by mover
- No device BW measurement
- `FABRIC_FRAME_DMA` default OFF → arbiter3 uninstantiated → fit cannot price path
- Candidate still start=0/busy=1 when define off (by design)

