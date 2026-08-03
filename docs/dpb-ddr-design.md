# DPB → DDR design (w-mem) — DPB1 in HPS DDR3

**Owner:** w-mem · **Status:** design + map reservation (no Quartus)  
**Tip context:** parent priority 2026-08-03 — 256 M10K reclaim (w-nostub hierarchy).

## Why

| Fact | Source |
|------|--------|
| On-chip `dpb_mem` dual-bank BRAM | w-nostub fit: **ALM −129 / M10K −256** if moved to DDR |
| CB fabric decode w/ DPB in DDR | ~9088 ALM / ~12 M10K / 1 DSP (w-nostub) |
| Library refFrames | N=142: **129×1** (90.8% DPB1) |
| Direct-play probes | 12/12 Constrained Baseline, `has_b_frames=0` |
| Dominant geometry | 624×480 → **449 280 B**/frame DPB1; **898 560 B** cur+ref |
| Present vs DPB | DPB is **source** resolution; present banks separate (Route B) |

**Target:** **DPB1 in DDR** — one reference + one current reconstruction, not multi-ref High profile.

---

## 0. Pre-registered predictions (publish misses)

| # | Prediction | Status |
|---|------------|--------|
| P1 | Byte-serial DPB traffic alone at 20 MHz exceeds MB budget | **HIT** (docs/p3-mc-dpb-bandwidth: 987 cy/MB vs 712 cy/MB @24) |
| P2 | 64-bit coalesced beats (~124 beats/MB) fit under 712 cy/MB **if** RTT≤~4 sys cy/beat | **CONDITIONAL** — see §3 |
| P3 | Typical f2sdram CAS≈6 clk_ddr → ~1.3 sys cy; RTT+bridge ~3–4 sys cy/beat | **MODEL** — TB grant max_lat=4 clk_ddr (product); **not** silicon |
| P4 | Worst-case arbiter contention + CDC can push ref-fetch over budget without window cache | **OPEN** — need RTL TB before fit |
| P5 | Map after Option-C end `0x3048_0000` has headroom for DPB2×0xE0000 | **HIT** (parent: reserved to 0x4000_0000; Option-C ends 0x3048_0000) |

---

## 1. DDR map (DPB1)

Present path (unchanged):

| Region | Phys | Notes |
|--------|------|-------|
| LEG banks | `0x3000_0000` stride `0x80000` | 480p present |
| Bitstream ring / PLXB | `0x3010_0000` / `0x3014_0000` | do not stomp |
| Option-C present | `0x3018_0000` stride `0x180000` | 720p **content** capacity |
| Option-C doorbell page | `0x3047_F000` .. `0x3048_0000` | end of present window |

**DPB reservation (new — w-mem):**

```
DDR_DPB_PHYS_BASE        = 0x3070_0000   // after PL330 fence 0x3060_0000
DDR_DPB_BANK_STRIDE      = 0x0018_0000   // ≥ 1 382 400; match Option-C stride
DDR_DPB_BANK0            = 0x3070_0000
DDR_DPB_BANK1            = 0x3088_0000
DDR_DPB_BYTES_MAX_FRAME  = 1 382 400     // 1280×720 I420 ceiling
DDR_DPB_TYP_FRAME        = 449 280       // 624×480 dominant
DDR_DPB_END              = 0x30A0_0000
```

- **Not** packed in `0x3048_0000..0x3060_0000` (only 1.5 MiB; dual-720p needs 3 MiB; collides triple doorbell `0x305F_F000` + PL330).
- Clear of Option-C present, triple-doorbell candidate, PL330 fence.
- Dual bank ping-pong: current write / reference read (`h264_dpb_one_ref`).
- Geometry **runtime** = coded storage (624×480 typical); bank stride is **capacity**, not pitch.
- Pitch for I420 inside bank: `y_stride = coded_w` (byte), same as `h264_dpb_i420_addr`.

Host/RTL constants: `ddr_frame_layout_params.svh` + `ddr_frame_layout.hpp` (`kDdrDpb*`).

---

## 2. Ports, arbiter, CDC

### Masters on f2sdram (product today)

| Port | Role | Pri |
|------|------|-----|
| m0 | `ddr_frame_store` scanout | absolute |
| m1 | bitstream / PLXG poll | mid |
| m3 | PLXC chrome | lowest |

### Proposed m2 — DPB client

- New master **m2** on `ddr_bus_arbiter_plxc` (or arbiter4): **below m0, above m1/m3**.
- Scanout must never starve (same lost-read / `m0_ov` rules as today).
- DPB is latency-sensitive for MC but can absorb multi-cycle `mem_rvalid`.

### Clock domains

| Domain | Clock | Role |
|--------|-------|------|
| Decode / `h264_dpb_one_ref` | `clk_sys` **20 MHz** (today) | issues fetch/write |
| DDR bridge | `clk_ddr` **90 MHz** | bursts |
| Optional future | decoder PLL (w-clock) | if decoder leaves 20 MHz |

**CDC (required even if decoder stays on clk_sys):**  
Address/cmd async FIFO decode→ddr; 64-bit data FIFO ddr→decode; `mem_rvalid` in decode domain only after FIFO pop.  
If w-clock moves decoder to a faster domain, **same FIFOs** — do not hard-code 20↔90 ratio in the client; parameterize.

### Replace BRAM latency contract

Quoted `h264_dpb.sv:182-184` / `decode_stub.sv:597-599`:

```
// decode_stub registers raddr_q → combinational rdata
// so rdata arrives 1 cycle after rvalid's source rd signal
dpb_mem_rvalid <= dpb_mem_rd;   // +1 cycle
```

**DDR cannot meet +1 cycle.** New contract:

```
mem_rd + mem_raddr  →  (N cycles later) mem_rvalid + mem_rdata
N ≥ 1, stall-safe: one_ref must hold issue until accept, or use credit window.
```

`h264_dpb_one_ref` already has `pending_*_d1` for 1-cycle align — generalize to **skid + credit** (accept when `mem_r_ready`, complete on `mem_rvalid`). Byte-serial issue loop stays; backing store returns multi-cycle.

---

## 3. Bandwidth & round-trip (evidence + model)

### Traffic (quoted `docs/p3-mc-dpb-bandwidth.md`, 624×480, ref=1)

| Item | Bytes/MB |
|------|--------:|
| Filtered writeback | 384 |
| Ref fetch (21×21 Y + 9×9 U/V) | 603 |
| **Total** | **987** |

| Rate | Value |
|------|------:|
| MB/frame | 1170 |
| @24 fps | **27.72 MB/s** DPB alone |
| @25 fps | **28.87 MB/s** |
| Present host push 624×480@24 | 10.78 MB/s |
| Present scanout read ~same | ~10.8 MB/s |
| **Combined rough** | **~49 MB/s** ≪ 720 MB/s peak (90 MHz×8) |

Peak **closes**. Binding constraint is **cycles/MB on clk_sys**, not DDR peak.

### Decode cycle budget @20 MHz

```
budget = 20e6 / (1170 × fps)
@24 → 712.3 cy/MB
@25 → 683.8 cy/MB
```

Byte-serial DPB alone (987 cy/MB) **exceeds** budget (**P1 HIT**) — true on BRAM or DDR if 1 B/cy issue.

### Round-trip model (clk_sys equivalent)

Assumptions (labeled **MODEL**, not silicon):

| Component | clk_ddr | → clk_sys (×20/90) |
|-----------|--------:|-------------------:|
| Typical CAS (TB models 4–6) | 6 | 1.33 |
| Bridge/FIFO CDC | — | +2..3 |
| **RTT typical / beat** | | **~3.3–4.5** |
| Contended arb + m0 bursts | +20 | +4.4 |
| **RTT worst / beat** | | **~12–15** |

Product PLXC grant TB (measured): `max_lat=4` clk_ddr, `vid_underrun=0` — **order-of-magnitude** for light load only.

64-bit beats per MB: ⌈603/8⌉=76 rd + ⌈384/8⌉=48 wr.

| Mode | cy/MB (sys, model) | vs 712 @24 |
|------|-------------------:|------------|
| Coalesced, RTT≈3.3, 1 cy issue | ~425 | **fits** |
| Coalesced, RTT≈13 worst | ~1047 | **FAIL** |
| Byte-serial + RTT/byte | thousands | **FAIL** |
| **Window cache: 1–2 bursts for 21×21** | ≪100 + MC | **target** |

### Can prefetch/burst hide latency?

**Yes — required, not optional.**

1. **MB window cache (M10K):** 21×21 Y + 2×9×9 C ≈ 603 B → **one M10K** (1280 B). Fill once per partition from DDR with 64-bit bursts (`BURSTCNT` 4–16).
2. **MC / qpel reads only the M10K window** at 1-cycle BRAM latency (preserves today’s `one_ref` consumer math).
3. **Writeback:** coalesce 16×16 MB to 32 qwords/plane burst WR (posted on f2sdram).
4. **Line/row prefetch** optional for horizontal MV coherence.

Without (1), worst-case RTT makes DPB-in-DDR a **throughput regression** despite M10K win (**P4**).

### Plain answer (parent P2)

| Question | Answer |
|----------|--------|
| Typical DDR RTT for one ref beat | **~4–8 clk_ddr** light load (**MODEL**); ≈**1–2 clk_sys** equivalent + CDC → **~3–5 sys cy** to first data |
| Worst-case RTT | **tens of clk_ddr** under m0 linefill storms; can exceed MB budget if every byte/beat waits |
| Hide with existing path? | **Partial** — arbiter burst OK; **must add window cache + multi-cycle `mem_rvalid`**. Raw byte-serial DDR behind `one_ref` **does not close** at 20 MHz |
| 33 MB/s present + ~28 MB/s DPB | Peak **yes**; cycle budget **only with coalesced window fill** |

---

## 4. Implementation plan (ordered)

1. **Map constants** + collision unit test (this commit).  
2. **`h264_dpb_mem_if`**: multi-cycle ready/valid; BRAM backend keeps +1 for sim.  
3. **`h264_dpb_window_cache`**: M10K 21×21 fill FSM; DDR master m2.  
4. **Arbiter m2** port + priority; lost-read twins extended.  
5. **decode_stub**: `ifdef DPB_IN_DDR` remove `dpb_mem[]`; wire cache.  
6. Verilator: MC TB with CAS model 4/8/16; pre-register cy/MB.  
7. Parent fit after w-nostub slot free.

**Non-goals this slice:** multi-ref DPB, CABAC, B-frames, fabric NN upscale.

---

## 5. Cross-lane

| Lane | Need |
|------|------|
| w-clock | Decoder clock domain decision; if faster domain, share CDC params |
| w-nostub | Fit measures M10K after `DPB_IN_DDR`; owns exclusive Quartus |
| w-rel / decode | `one_ref` accept multi-cycle rvalid (interface only) |

---

## 6. Related answers (same priority packet)

- **FAB_W=1280:** optional writer only — `docs/route-b-fab-writer-sizing.md` (not Route B content DE).  
- **B14 426:** **pad→432**, display/DE=426, crop L2/R4 — `docs/b14-coded-width-policy.md`, commit `2126d0e3`.  
- **m_gnt:** product `test_ddr_plxc_grant` underrun=0 max_lat=4; lost-read product+fault twins pass.  
- **q5 freeze:** `mailbox_abi_spec.hpp` §q5 — bit34 **RESERVED**, `fps_1001` not awarded.
