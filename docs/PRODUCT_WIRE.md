# PRODUCT_WIRE — fabric publish enable draft (w-mem WAVE4)

**Status: DRAFT ONLY. PRODUCT_WIRE = 0 on tree tip `947d8620`.**  
rd-duck NACK stands: product wire is still off. Unit RTL (engine + arbiter3 + path) is landed; **not** in `files.qip`, **not** in `Plex.sv`.

| Layer | State | Evidence |
|-------|--------|----------|
| Unit RTL | Landed | `ddr_publish_{engine,path,job}.sv`, `ddr_bus_arbiter3.sv`, `ddr_i420_bank_geom.sv` |
| Product QIP / instance | **OFF** | `test_fabric_publish_product_wire_static` → `PRODUCT_WIRE=0` |
| Engine sim | GREEN | `test_ddr_publish_engine_rtl_sim` true rc=0 |
| Contended arb3 sim | GREEN | `test_ddr_publish_contended_rtl_sim` (separate) |
| Device / Quartus fit | **NOT RUN** | No device; no fit; **no BUILD_OK claim** |

Fail-closed gate: `tests/unit/test_fabric_publish_product_wire_static.py`  
- PASS only while publish modules are absent from `files.qip` **and** `Plex.sv`.  
- Any QIP entry or `Plex.sv` token match for `ddr_publish_*` / `ddr_bus_arbiter3` → **RED** (intentional enable must update that gate first).

---

## Why (settled premise)

- ARM `/dev/mem` whole-frame `T_copy` ~15 ms fails serial 720p24.
- Product layout on main: phys `0x30000000`, bank stride `0x180000`, doorbell `0x302FF000` (`ddr_frame_layout_params.svh`).
- Fabric publish: DIRECT (doorbell only when payload already in bank) first; COPY mem2mem fallback.
- Priority on shared f2sdram: **present (m0) > publish (m2) > bitstream (m1)**.

---

## Macro (default OFF)

Prefer a **dedicated** publish wire macro so compose cuts do not silently enable publish:

```tcl
# Plex.qsf — leave COMMENTED until parent enable + gate update
#set_global_assignment -name VERILOG_MACRO "PRODUCT_WIRE=1"
```

Optional alias for compose stack (G-COMPOSE / historical name):

```tcl
# Either alone is enough if Plex.sv uses the OR form below.
#set_global_assignment -name VERILOG_MACRO "FABRIC_FRAME_DMA=1"
```

**Default product path:** neither macro defined → keep `ddr_bus_arbiter` (2-master), no publish path.

`Plex.sv` guard form (draft — **do not land until enable**):

```systemverilog
`if defined(PRODUCT_WIRE) || defined(FABRIC_FRAME_DMA)
  // arb3 + ddr_publish_path
`else
  // existing ddr_bus_arbiter
`endif
```

Quartus/`ifdef` note: use nested `` `ifdef PRODUCT_WIRE `` / `` `else `` / `` `ifdef FABRIC_FRAME_DMA `` or define one canonical macro in QSF. Do **not** put module-name tokens into `Plex.sv` under a comment-only draft if the static gate still scans the whole file — the unit gate is regex, not ifdef-aware.

---

## Exact `files.qip` lines (add only at enable)

Insert **with** the `Plex.sv` instance (never QIP-only — dead-QIP is a hard FAIL):

```tcl
# Fabric publish (PRODUCT_WIRE / FABRIC_FRAME_DMA) — parent enable only
set_global_assignment -name SYSTEMVERILOG_FILE rtl/ddr_i420_bank_geom.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/ddr_publish_job.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/ddr_publish_engine.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/ddr_publish_path.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/ddr_bus_arbiter3.sv
# Optional (dyn-base present path research; not required for DIRECT doorbell):
# set_global_assignment -name SYSTEMVERILOG_FILE rtl/ddr_frame_base_mux.sv
```

Keep existing:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE rtl/ddr_bus_arbiter.sv
```

(Product OFF path still needs the 2-master arbiter module; arb3 is additional.)

---

## `Plex.sv` instance sketch (replace 2-master block under DDR_FRAME_STORE)

**Today (PRODUCT_WIRE=0)** — `Plex.sv` ~972–1005:

```systemverilog
`ifdef DDR_FRAME_STORE
ddr_bus_arbiter ddr_arb (
	.clk(clk_ddr),
	.clk_m1(clk_sys),
	.reset(reset),
	.m1_want(stream_ddr_bus_want),
	// m0 = present_ddr_*, m1 = stream_ddr_*, phys DDRAM_*
	...
);
`endif
```

**Enable sketch** — arb2 → arb3 + publish path on m2 (DIRECT-first stub controls):

```systemverilog
`ifdef DDR_FRAME_STORE
`ifdef PRODUCT_WIRE
// ── PRODUCT_WIRE ON: present m0 > publish m2 > bitstream m1 ──
wire        pub_busy, pub_done, pub_err, pub_job_legal, pub_src_aligned;
wire        pub_bus_want;
wire [31:0] pub_frame_bytes, pub_dst_bank, pub_db_phys, pub_bytes_copied;
wire [15:0] pub_beats_rd, pub_beats_wr;
wire  [7:0] pub_burstcnt, pub_be;
wire [28:0] pub_addr;
wire [63:0] pub_dout, pub_din;
wire        pub_dout_ready, pub_rd, pub_we;
wire        pub_m2_busy;

// Host kick CDC (clk_sys → clk_ddr) is parent/w-path scope.
// Bring-up: tie start=0 until mailbox/status bit is assigned.
wire        pub_start_ddr;      // TODO: status/mailbox rising edge on clk_ddr
wire        pub_cmd_mode;       // 0 DIRECT, 1 COPY
wire        pub_bank_sel;
wire [31:0] pub_src_phys;
wire        pub_ring_db;
wire [63:0] pub_db_word;
wire [31:0] pub_bytes_override;

// present_want: fence NEW publish issues while present is commanding
wire present_cmd = present_ddr_rd | present_ddr_we;

ddr_publish_path #(
	.CODED_W(DDR_FRAME_CODED_WIDTH),       // from ddr_frame_layout_params.svh
	.CODED_H(DDR_FRAME_CODED_HEIGHT),
	.PHYS_BASE(32'h3000_0000),
	.BANK_STRIDE_BYTES(DDR_FRAME_YUV420P_BANK_STRIDE), // 0x0018_0000
	.DOORBELL_PHYS(DDR_FRAME_YUV420P_DOORBELL_PHYS),   // 0x302F_F000
	.MAX_BURST(16),
	.ADDR_W(29)
) u_pub (
	.clk(clk_ddr),
	.reset(reset),
	.start(pub_start_ddr),
	.cmd_mode(pub_cmd_mode),
	.bank_sel(pub_bank_sel),
	.src_phys(pub_src_phys),
	.ring_doorbell(pub_ring_db),
	.doorbell_word(pub_db_word),
	.bytes_override(pub_bytes_override),
	.busy(pub_busy),
	.done_pulse(pub_done),
	.err(pub_err),
	.job_legal(pub_job_legal),
	.src_aligned(pub_src_aligned),
	.frame_bytes(pub_frame_bytes),
	.dst_bank_phys(pub_dst_bank),
	.doorbell_phys_o(pub_db_phys),
	.bytes_copied(pub_bytes_copied),
	.beats_rd(pub_beats_rd),
	.beats_wr(pub_beats_wr),
	.present_want(present_cmd),
	.bus_want(pub_bus_want),
	.DDRAM_BUSY(pub_m2_busy),
	.DDRAM_BURSTCNT(pub_burstcnt),
	.DDRAM_ADDR(pub_addr),
	.DDRAM_DOUT(pub_dout),
	.DDRAM_DOUT_READY(pub_dout_ready),
	.DDRAM_RD(pub_rd),
	.DDRAM_DIN(pub_din),
	.DDRAM_BE(pub_be),
	.DDRAM_WE(pub_we)
);

ddr_bus_arbiter3 #(.M2_QUANTUM_BEATS(8)) ddr_arb3 (
	.clk(clk_ddr),
	.clk_m1(clk_sys),
	.reset(reset),
	.m1_want(stream_ddr_bus_want),
	.m2_want(pub_bus_want),
	// m0 present
	.m0_busy(present_ddr_busy),
	.m0_burstcnt(present_ddr_burstcnt),
	.m0_addr(present_ddr_addr),
	.m0_dout(present_ddr_dout),
	.m0_dout_ready(present_ddr_dout_ready),
	.m0_rd(present_ddr_rd),
	.m0_din(present_ddr_din),
	.m0_be(present_ddr_be),
	.m0_we(present_ddr_we),
	// m1 bitstream
	.m1_busy(stream_ddr_busy),
	.m1_burstcnt(stream_ddr_burstcnt),
	.m1_addr(stream_ddr_addr),
	.m1_dout(stream_ddr_dout),
	.m1_dout_ready(stream_ddr_dout_ready),
	.m1_rd(stream_ddr_rd),
	.m1_din(stream_ddr_din),
	.m1_be(stream_ddr_be),
	.m1_we(stream_ddr_we),
	// m2 publish
	.m2_busy(pub_m2_busy),
	.m2_burstcnt(pub_burstcnt),
	.m2_addr(pub_addr),
	.m2_dout(pub_dout),
	.m2_dout_ready(pub_dout_ready),
	.m2_rd(pub_rd),
	.m2_din(pub_din),
	.m2_be(pub_be),
	.m2_we(pub_we),
	// physical DDRAM
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);

// Keep publish telemetry live so Quartus cannot strip the path:
// (* keep *) wire _pub_keep = pub_busy | pub_done | pub_err | pub_job_legal;

`else
// ── PRODUCT_WIRE OFF (default): product 2-master path ──
ddr_bus_arbiter ddr_arb (
	.clk(clk_ddr),
	.clk_m1(clk_sys),
	.reset(reset),
	.m1_want(stream_ddr_bus_want),
	.m0_busy(present_ddr_busy),
	.m0_burstcnt(present_ddr_burstcnt),
	.m0_addr(present_ddr_addr),
	.m0_dout(present_ddr_dout),
	.m0_dout_ready(present_ddr_dout_ready),
	.m0_rd(present_ddr_rd),
	.m0_din(present_ddr_din),
	.m0_be(present_ddr_be),
	.m0_we(present_ddr_we),
	.m1_busy(stream_ddr_busy),
	.m1_burstcnt(stream_ddr_burstcnt),
	.m1_addr(stream_ddr_addr),
	.m1_dout(stream_ddr_dout),
	.m1_dout_ready(stream_ddr_dout_ready),
	.m1_rd(stream_ddr_rd),
	.m1_din(stream_ddr_din),
	.m1_be(stream_ddr_be),
	.m1_we(stream_ddr_we),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);
`endif // PRODUCT_WIRE
`endif // DDR_FRAME_STORE
```

`include "ddr_frame_layout_params.svh"` (or parameter passthrough from existing product constants) required at the enable site for CODED_W/H / stride / doorbell.

---

## Parent enable checklist (order)

1. **Update** `test_fabric_publish_product_wire_static.py` so intentional wire is GREEN  
   (today it hard-fails on any qip/plex hit — that is correct for unit-only land).
2. Add QIP lines + `Plex.sv` sketch together (no orphan QIP).
3. Uncomment `PRODUCT_WIRE=1` in `Plex.qsf` (or `FABRIC_FRAME_DMA=1` if using that alias).
4. Host kick path: status bit or mmap mailbox → `pub_start_ddr` on `clk_ddr`; DIRECT first (`cmd_mode=0`).
5. Exclusive Quartus fit (w-fit sole); hierarchy must show `ddr_arb3` / `u_pub` non-zero ALM.
6. Device BW + present underrun measure — **BUILD_OK ≠ product PASS**.
7. Only then delete ARM `T_copy` (G-PUBLISH).

---

## Cost notes (source control, not post-fit)

| Block | M10K | Notes |
|-------|------|--------|
| engine bounce | **0** | `ramstyle="logic"`, depth=MAX_BURST×64b = 1024 useful bits |
| arb3 m1 rsp FIFO | **0** (MLAB) | `async_fifo #(.WIDTH(64),.AW(3))` → DEPTH=8×64; worst EST 1×M10K if MLAB fails |
| path/job/geom | **0** | wires/params |
| ALM | EST 250–600 publish + arb delta | **UNKNOWN** until entity row after wire |

Against PRODUCT_NO_STUB free ~356 M10K (parent HIT M10K=197).

---

## What this draft does **not** claim

- Not product-wired.
- Not fitted. No RBF. No device BW.
- No BUILD_OK. No retirement of ARM T_copy.
- No compose (L4 / MULTI / clk_pix) enable — G-COMPOSE is a separate exclusive fit.

---

## Verify (unit-only tree)

```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-fleet-mem
python3 tests/unit/test_fabric_publish_product_wire_static.py; echo "true rc=$?"
bash tests/unit/test_ddr_publish_engine_rtl_sim.sh; echo "true rc=$?"
# optional:
bash tests/unit/test_ddr_publish_contended_rtl_sim.sh; echo "true rc=$?"
```

Expected while PRODUCT_WIRE=0:

```
PASS ... PRODUCT_WIRE=0 (not in qip/Plex.sv) ...
true rc=0
PASS test_ddr_publish_engine_rtl_sim
true rc=0
```
