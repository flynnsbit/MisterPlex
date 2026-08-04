# w-mem fabric publish + contended arbiter3

Branch: `w-mem-720p-present-origin` (based origin/main)
Date: 2026-08-04
Worker: w-mem

## Delivered (.sv, not product-wired)

| Module | Role | M10K | ALM |
|---|---|---:|---|
| `ddr_publish_engine.sv` | DIRECT/COPY publication | **0** (bounce `ramstyle=logic`) | ~250–450 EST |
| `ddr_publish_path.sv` | job+geom+engine compose | 0 | ~80 EST |
| `ddr_publish_job.sv` | job latch/handshake | 0 | ~40 EST |
| `ddr_i420_bank_geom.sv` | Option-C geometry | 0 | ~30 EST |
| `ddr_frame_base_mux.sv` | present base select (w-nostub PR#9 shape) | 0 | ~20 EST |
| `ddr_bus_arbiter3.sv` | m0>m2>m1 + M2_QUANTUM_BEATS=8 | ≤1 typical (m1 FIFO) | ~400–600 EST |

**Budget control (parent fit artifact nostub-poststrip1):** M10K 197/553 HIT; free ~356. Engine+path+geom+job+mux claim **0 M10K**. Arbiter3 claims ≤1.

**NOT in product `files.qip`** until parent enables.

## Controls run (this worktree)

```
bash tests/unit/test_ddr_publish_engine_rtl_sim.sh
  PASS DIRECT / G0 / G1 / G_NEG ; true rc=0

bash tests/unit/test_ddr_publish_contended_rtl_sim.sh
  FAULT: REPRO_OK G_NEG FAULT max_deny=387 grants=8 ; true rc=0
  PRODUCT: PASS G0 copied=256; PASS G2 frame_bytes=1382400;
           PASS G1 max_m0_deny=17 grants=59 (bound 48 Q=8);
           true rc=0

python3 tests/unit/test_ddr_frame_base_mux_static.py
  PASS M10K=0 DYN_BASE_EN default fixed ; true rc=0
```

## Contention attack (rd-duck open)

**Scheme:** m0 (present) > m2 (publish) > m1 (bitstream). m2 sticky while m0 idle;
when m0_cmd during m2 sticky, yield after `M2_QUANTUM_BEATS=8`.
FAULT twin `DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM` holds sticky → REPRO starve.

**TB negative:** FAULT max_deny=387 vs PRODUCT max_deny=17 (same continuous m0_rd+m2_we stimulus).
Naive "always sticky m2" fails FAULT control; product quantum interleaves m0 (grants=59 / 256-beat stream).

**Ideal port math only (NOT HPS-measured):**
- 720p24 I420 R_req = 33.1776 MB/s/dir
- COPY R+W = 66.3552; concurrent with present ~99.53 ≈ 13.8% of 720 MB/s peak @90MHz×8
- Achievable sustained under real f2sdram / BL8 / refresh: **UNKNOWN** — check is device capture after parent wires + fit.

**OPEN:**
1. Engine bit-exact COPY *through* arbiter under concurrency (TB solo COPY is direct-to-bridge).
2. Device BW / contention under live present reader.
3. Product wire + fit (parent exclusive slot).

## One-core note
ARM dual-core decode||copy rescue WITHDRAWN (parent /proc/stat: MiSTer ~100% one core).
Fabric publish remains the only copy-retire path.
