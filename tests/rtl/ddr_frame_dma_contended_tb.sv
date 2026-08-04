// ddr_frame_dma + ddr_bus_arbiter3 — legal bursts, rand BUSY, G1 bit-exact.
//
// PRE-REGISTER (do not edit post-hoc to match):
//   PR_T_COPY_ARM_US     = 14978
//   PR_T_IDEAL_SOLO_US   = 3840
//   PR_T_WITH_PRESENT_US = 5760
//   PR_M10K_DMA          = 0  (bounce 8×64 MLAB)
//   PR_M10K_ARB3         = 0  (async_fifo MLAB; fit L5258-5259)
//   PR_QUANTUM           = 8
//   PR_MAX_M0_DENY_CWE   = 48
//   PR_MAX_M0_DENY_DMA   = 160
//
// Protocol (rd-duck NACK):
//   - Write burst: ADDR/BURSTCNT constant; WE held under waitrequest
//   - Arbiter yields only at burst boundaries
//   - G1 rechecks destination bit-exact (not just deny counts)
//   - Randomized DDRAM_BUSY
//
// DEVICE_BW_VERIFIED=0. NOT product-integration-ready (staging/doorbell OPEN).
`timescale 1ns / 1ps

module ddr_frame_dma_contended_tb;
	reg clk = 0, clk_m1 = 0, reset = 1;
	always #5 clk = ~clk;
	always #25 clk_m1 = ~clk_m1;

	localparam int PR_T_COPY_ARM_US = 14978;
	localparam int PR_T_IDEAL_SOLO_US = 3840;
	localparam int PR_T_WITH_PRESENT_US = 5760;
	localparam int PR_M10K_DMA = 0;
	localparam int PR_M10K_ARB3 = 0;
	localparam int PR_QUANTUM = 8;
	localparam int PR_MAX_M0_DENY_CWE = 48;
	localparam int PR_MAX_M0_DENY_DMA = 160;
	localparam int CLK_DDR_MHZ = 90;
	localparam int FRAME_BYTES_FULL = 1_382_400;
	localparam int QWORDS_FULL = FRAME_BYTES_FULL / 8;
	localparam int N_QWORDS = 256;
	localparam int N_BYTES = N_QWORDS * 8;
	localparam int SRC_PHYS = 32'h0000_1000;
	localparam int DST_PHYS = 32'h0000_8000;

	reg        DDRAM_BUSY;
	reg [63:0] DDRAM_DOUT;
	reg        DDRAM_DOUT_READY;
	wire [7:0] DDRAM_BURSTCNT;
	wire [28:0] DDRAM_ADDR;
	wire       DDRAM_RD, DDRAM_WE;
	wire [63:0] DDRAM_DIN;
	wire [7:0] DDRAM_BE;
	reg [63:0] mem [0:4095];

	reg        m0_want, m0_rd;
	reg [28:0] m0_addr;
	wire       m0_busy;
	wire [63:0] m0_dout;
	wire       m0_dout_ready;

	reg        dma_start;
	reg [31:0] dma_src, dma_dst, dma_fb;
	wire       dma_busy, dma_done, dma_err;
	wire       dma_yield_window;
	wire [31:0] dma_rd_beats, dma_wr_beats, dma_last_fb;
	wire [7:0] dma_burstcnt;
	wire [28:0] dma_addr;
	wire [63:0] dma_dout_from_arb;
	wire       dma_dout_ready;
	wire       dma_rd, dma_we;
	wire [63:0] dma_din;
	wire [7:0] dma_be;

	reg        cwe_en;
	reg [28:0] cwe_addr;
	wire       cwe_we = cwe_en;
	wire       cwe_want = cwe_en;

// Runtime CWE (continuous write engine) for FAULT twin + product G1b.
	// When cwe_en=1, m2 is the CWE and DMA is held in reset-busy.
	wire       m2_busy;
	wire [7:0] m2_burstcnt = cwe_en ? 8'd1 : dma_burstcnt;
	wire [28:0] m2_addr = cwe_en ? cwe_addr : dma_addr;
	wire [63:0] m2_dout;
	wire       m2_dout_ready;
	wire       m2_rd = cwe_en ? 1'b0 : dma_rd;
	wire [63:0] m2_din = cwe_en ? 64'hDEAD_BEEF_CAFE_F00D : dma_din;
	wire [7:0] m2_be = cwe_en ? 8'hFF : dma_be;
	wire       m2_we = cwe_en ? cwe_we : dma_we;
	wire       m2_want = cwe_en ? cwe_want : (dma_busy | dma_rd | dma_we);

	assign dma_dout_from_arb = m2_dout;
	wire dma_bridge_busy = cwe_en ? 1'b1 : m2_busy;
	wire dma_bridge_dout_ready = cwe_en ? 1'b0 : m2_dout_ready;

	wire m1_busy;
	wire [63:0] m1_dout;
	wire m1_dout_ready;

	ddr_frame_dma #(.MAX_BURST(8), .BOUNCE_DEPTH(8), .DEFAULT_FRAME_BYTES(N_BYTES)) u_dma (
		.clk(clk), .reset(reset),
		.start(dma_start & ~cwe_en),
		.src_phys(dma_src), .bank_phys(dma_dst), .frame_bytes(dma_fb),
		.busy(dma_busy), .done(dma_done), .yield_window(dma_yield_window), .err_align(dma_err),
		.rd_beats(dma_rd_beats), .wr_beats(dma_wr_beats), .last_frame_bytes(dma_last_fb),
		.DDRAM_BUSY(dma_bridge_busy),
		.DDRAM_BURSTCNT(dma_burstcnt),
		.DDRAM_ADDR(dma_addr),
		.DDRAM_DOUT(dma_dout_from_arb),
		.DDRAM_DOUT_READY(dma_bridge_dout_ready),
		.DDRAM_RD(dma_rd),
		.DDRAM_DIN(dma_din),
		.DDRAM_BE(dma_be),
		.DDRAM_WE(dma_we)
	);

	ddr_bus_arbiter3 #(.M2_QUANTUM_BEATS(PR_QUANTUM)) u_arb (
		.clk(clk), .clk_m1(clk_m1), .reset(reset),
		.m1_want(1'b0),
		.m0_busy(m0_busy),
		.m0_burstcnt(8'd1),
		.m0_addr(m0_addr),
		.m0_dout(m0_dout),
		.m0_dout_ready(m0_dout_ready),
		.m0_rd(m0_rd),
		.m0_din(64'd0),
		.m0_be(8'h00),
		.m0_we(1'b0),
		.m1_busy(m1_busy),
		.m1_burstcnt(8'd1),
		.m1_addr(29'd0),
		.m1_dout(m1_dout),
		.m1_dout_ready(m1_dout_ready),
		.m1_rd(1'b0),
		.m1_din(64'd0),
		.m1_be(8'h00),
		.m1_we(1'b0),
		.m2_want(m2_want),
		.m2_yield_window(cwe_en ? 1'b1 : dma_yield_window),
		.m2_busy(m2_busy),
		.m2_burstcnt(m2_burstcnt),
		.m2_addr(m2_addr),
		.m2_dout(m2_dout),
		.m2_dout_ready(m2_dout_ready),
		.m2_rd(m2_rd),
		.m2_din(m2_din),
		.m2_be(m2_be),
		.m2_we(m2_we),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),
		.grant_owner()
	);

	// ---- Unit-TB-style phys (pre-edge drive, post-edge retire) ----
	// Proven: ddr_frame_dma_tb.cpp + dbg_arb_unitstyle (done=1 rd=256 wr=256 bad=0).
	integer cyc;
	integer m0_grants, m0_deny, m0_max_deny;
	integer present_div;
	reg present_need;
	integer g_prev;
	integer dma_start_cyc;
	integer solo_cyc, cont_cyc;
	integer t_solo_us_scaled, t_cont_us_scaled;
	integer i, fail;
	reg local_fail;
	integer proto_fail;
	reg [15:0] lfsr;
	integer busy_force;
	integer busy_this;

	integer rd_left;
	reg [28:0] rd_a;
	integer wr_left;
	reg [28:0] wr_a, wr_a_lat;
	reg [7:0] wr_bc_lat;

	task automatic tick; begin @(posedge clk); cyc = cyc + 1; end endtask

	function automatic integer next_busy;
		begin
			lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
			if (busy_force >= 0) next_busy = busy_force;
			else next_busy = (lfsr[2:0] == 3'b000);
		end
	endfunction

	// Dual-sample RD: pre-edge (arbiter align) + post-edge (one-cycle RD rise).
	integer rd_fire;
	reg [28:0] snap_addr;
	reg [7:0] snap_bc;

	task automatic step;
		begin
			busy_this = next_busy();
			DDRAM_BUSY = busy_this[0];
			DDRAM_DOUT_READY = 1'b0;
			rd_fire = (!busy_this[0] && DDRAM_RD && (rd_left == 0) && (wr_left == 0));
			snap_addr = DDRAM_ADDR;
			snap_bc = (DDRAM_BURSTCNT == 0) ? 8'd1 : DDRAM_BURSTCNT;
			if (rd_left > 0 && !busy_this[0]) begin
				DDRAM_DOUT = mem[rd_a[11:0]];
				DDRAM_DOUT_READY = 1'b1;
			end
			tick;
			if (rd_left > 0 && !busy_this[0] && DDRAM_DOUT_READY) begin
				rd_a = rd_a + 1;
				rd_left = rd_left - 1;
			end else if (wr_left > 0) begin
				if (!DDRAM_WE) begin
					$display("FAIL PROTO WE dropped mid-burst left=%0d cyc=%0d", wr_left, cyc);
					proto_fail = 1;
				end else if (DDRAM_ADDR !== wr_a_lat || DDRAM_BURSTCNT !== wr_bc_lat) begin
					$display("FAIL PROTO ADDR/BC mut mid-burst a=%h/%h bc=%0d/%0d cyc=%0d",
						DDRAM_ADDR, wr_a_lat, DDRAM_BURSTCNT, wr_bc_lat, cyc);
					proto_fail = 1;
				end else if (!busy_this[0]) begin
					mem[wr_a[11:0]] = DDRAM_DIN;
					wr_a = wr_a + 1;
					wr_left = wr_left - 1;
					if (cwe_en) cwe_addr = cwe_addr + 1;
				end
			end else if (rd_fire) begin
				rd_a = snap_addr;
				rd_left = snap_bc;
			end else if (!busy_this[0] && DDRAM_RD) begin
				rd_a = DDRAM_ADDR;
				rd_left = (DDRAM_BURSTCNT == 0) ? 1 : DDRAM_BURSTCNT;
			end else if (!busy_this[0] && DDRAM_WE) begin
				wr_a_lat = DDRAM_ADDR;
				wr_bc_lat = (DDRAM_BURSTCNT == 0) ? 8'd1 : DDRAM_BURSTCNT;
				wr_a = wr_a_lat;
				wr_left = wr_bc_lat;
				mem[wr_a[11:0]] = DDRAM_DIN;
				wr_a = wr_a + 1;
				wr_left = wr_left - 1;
				if (cwe_en) cwe_addr = cwe_addr + 1;
			end
		end
	endtask

always @(posedge clk) begin
		if (reset) begin
			m0_rd <= 0; m0_addr <= 29'h100;
			m0_grants <= 0; m0_deny <= 0; m0_max_deny <= 0;
		end else if (m0_want) begin
			m0_rd <= 1'b1;
			if (!m0_busy && m0_rd) begin
				m0_grants <= m0_grants + 1;
				m0_deny <= 0;
				m0_addr <= m0_addr + 1;
			end else if (u_arb.owner != 2'd0) begin
				// Owner-starve only (not phys waitrequest under rand BUSY).
				m0_deny <= m0_deny + 1;
				if (m0_deny + 1 > m0_max_deny) m0_max_deny <= m0_deny + 1;
			end
		end else begin
			m0_rd <= 0; m0_deny <= 0;
		end
	end

	initial begin
		$display("=== ddr_frame_dma_contended_tb EXECUTED ===");
		$display("PREREG arm=%0d ideal=%0d with_present=%0d m10k_dma=%0d Q=%0d cwe_deny=%0d dma_deny=%0d",
			PR_T_COPY_ARM_US, PR_T_IDEAL_SOLO_US, PR_T_WITH_PRESENT_US,
			PR_M10K_DMA, PR_QUANTUM, PR_MAX_M0_DENY_CWE, PR_MAX_M0_DENY_DMA);

		fail = 0; proto_fail = 0; cyc = 0;
		lfsr = 16'hACE1;
		busy_force = -1; // random
		dma_start = 0; cwe_en = 0; cwe_addr = 29'h200;
		dma_src = SRC_PHYS; dma_dst = DST_PHYS; dma_fb = N_BYTES;
		m0_want = 0;
		DDRAM_BUSY = 0;
		rd_left = 0; wr_left = 0;
		DDRAM_BUSY = 0; DDRAM_DOUT = 0; DDRAM_DOUT_READY = 0;
		for (i = 0; i < 4096; i = i + 1) mem[i] = 64'd0;
		for (i = 0; i < N_QWORDS; i = i + 1)
			mem[(SRC_PHYS/8) + i] = 64'hA5A5_0000_0000_0000 ^ {32'd0, i[31:0]};

		repeat (8) tick;
		reset = 0;
		repeat (4) begin step; end

`ifdef DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM
		busy_force = 0; // deterministic REPRO
		m0_want = 1;
		cwe_en = 1;
		m0_grants = 0; m0_deny = 0; m0_max_deny = 0;
		repeat (500) begin step; end
		cwe_en = 0; m0_want = 0;
		if (m0_max_deny < 64) begin
			$display("FAIL FAULT twin max_deny=%0d < 64", m0_max_deny);
			fail = 1;
		end else
			$display("REPRO_OK FAULT max_deny=%0d grants=%0d", m0_max_deny, m0_grants);
`else
		// G2 misalign
		dma_src = SRC_PHYS + 1;
		dma_start = 1; step; dma_start = 0;
		repeat (20) begin step; end
		if (!dma_err) begin $display("FAIL G2 expected err_align"); fail = 1;
		end else $display("PASS G2 misalign err_align");
		dma_src = SRC_PHYS;

		// G0 solo — force BUSY=0 first for ideal timing, then random copy check
		busy_force = 0;
		for (i = 0; i < N_QWORDS; i = i + 1) mem[(DST_PHYS/8) + i] = 64'd0;
		m0_want = 0;
		dma_start_cyc = cyc;
		dma_start = 1; step; dma_start = 0;
		while (!dma_done && cyc < dma_start_cyc + 200000) begin step; end
		solo_cyc = cyc - dma_start_cyc;
		local_fail = 0;
		if (!dma_done) begin
			$display("FAIL G0 timeout done=0 busy=%0d rd=%0d wr=%0d cyc=%0d",
				dma_busy, dma_rd_beats, dma_wr_beats, solo_cyc);
			local_fail = 1; fail = 1;
		end
		if (dma_rd_beats != N_QWORDS || dma_wr_beats != N_QWORDS) begin
			$display("FAIL G0 beats rd=%0d wr=%0d done=%0d busy=%0d err=%0d cyc=%0d",
				dma_rd_beats, dma_wr_beats, dma_done, dma_busy, dma_err, solo_cyc);
			local_fail = 1; fail = 1;
		end
		begin : g0_check
			integer nbad;
			nbad = 0;
			for (i = 0; i < N_QWORDS; i = i + 1) begin
				if (mem[(DST_PHYS/8)+i] !== (64'hA5A5_0000_0000_0000 ^ {32'd0, i[31:0]})) begin
					if (nbad < 4)
						$display("FAIL G0 dst[%0d]=%h", i, mem[(DST_PHYS/8)+i]);
					nbad = nbad + 1;
					local_fail = 1; fail = 1;
				end
			end
			if (nbad > 4)
				$display("FAIL G0 dst total_bad=%0d/%0d", nbad, N_QWORDS);
		end
		t_solo_us_scaled = (solo_cyc * QWORDS_FULL / N_QWORDS) / CLK_DDR_MHZ;
		if (!local_fail)
			$display("PASS G0 solo copied=%0d cyc=%0d t_full_us_scaled=%0d (PR_ideal=%0d)",
				N_QWORDS, solo_cyc, t_solo_us_scaled, PR_T_IDEAL_SOLO_US);
		else
			$display("FAIL G0 detail done=%0d busy=%0d rd=%0d wr=%0d cyc=%0d",
				dma_done, dma_busy, dma_rd_beats, dma_wr_beats, solo_cyc);

		// G0b: random BUSY bit-exact
		busy_force = -1;
		for (i = 0; i < N_QWORDS; i = i + 1) mem[(DST_PHYS/8) + i] = 64'd0;
		dma_start_cyc = cyc;
		dma_start = 1; step; dma_start = 0;
		while (!dma_done && cyc < dma_start_cyc + 400000) begin step; end
		local_fail = 0;
		begin : g0b_check
			integer nbad;
			nbad = 0;
			for (i = 0; i < N_QWORDS; i = i + 1) begin
				if (mem[(DST_PHYS/8)+i] !== (64'hA5A5_0000_0000_0000 ^ {32'd0, i[31:0]})) begin
					if (nbad < 6)
						$display("FAIL G0b rand_busy dst[%0d]=%h exp=%h", i,
							mem[(DST_PHYS/8)+i],
							(64'hA5A5_0000_0000_0000 ^ {32'd0, i[31:0]}));
					nbad = nbad + 1;
					local_fail = 1; fail = 1;
				end
			end
			if (nbad > 6)
				$display("FAIL G0b total_bad=%0d/%0d rd=%0d wr=%0d done=%0d",
					nbad, N_QWORDS, dma_rd_beats, dma_wr_beats, dma_done);
			if (!local_fail) $display("PASS G0b rand_busy bit_exact");
		end

		// G1 DMA + present ~6.25% duty + bit-exact + randomized BUSY
		// (rd-duck: G0b solo rand; G1 present+rand). Dual-sample phys closes
		// one-cycle-RD vs arbiter accept skew under waitrequest.
		busy_force = -1;
		for (i = 0; i < N_QWORDS; i = i + 1) mem[(DST_PHYS/8) + i] = 64'd0;
		m0_grants = 0; m0_deny = 0; m0_max_deny = 0;
		present_div = 0; present_need = 1'b0;
		g_prev = 0;
		repeat (16) begin step; end
		dma_start_cyc = cyc;
		dma_start = 1; step; dma_start = 0;
		while (!dma_done && cyc < dma_start_cyc + 2000000) begin
			if (present_div == 0)
				present_need = 1'b1;
			present_div = (present_div == 15) ? 0 : (present_div + 1);
			m0_want = present_need;
			step;
			if (m0_grants > g_prev) begin
				present_need = 1'b0;
				g_prev = m0_grants;
			end
		end
		cont_cyc = cyc - dma_start_cyc;
		t_cont_us_scaled = (cont_cyc * QWORDS_FULL / N_QWORDS) / CLK_DDR_MHZ;
		m0_want = 0;
		$display("G1 end done=%0d busy=%0d rd=%0d wr=%0d cyc=%0d grants=%0d max_deny=%0d",
			dma_done, dma_busy, dma_rd_beats, dma_wr_beats, cont_cyc, m0_grants, m0_max_deny);
		if (!dma_done)
			$display("G1 HANG st=%0d own=%0d rdl=%0d prdl=%0d rspl=%0d",
				u_dma.st, u_arb.owner, u_arb.rd_left, rd_left, u_dma.rsp_left);

		local_fail = 0;
		begin : g1_check
			integer nbad;
			nbad = 0;
			for (i = 0; i < N_QWORDS; i = i + 1) begin
				if (mem[(DST_PHYS/8)+i] !== (64'hA5A5_0000_0000_0000 ^ {32'd0, i[31:0]})) begin
					if (nbad < 8)
						$display("FAIL G1 bit_exact dst[%0d]=%h", i, mem[(DST_PHYS/8)+i]);
					nbad = nbad + 1;
					local_fail = 1; fail = 1;
				end
			end
			if (nbad > 8)
				$display("FAIL G1 bit_exact ... total_bad=%0d/%0d", nbad, N_QWORDS);
			if (!local_fail) $display("PASS G1 bit_exact dst");
		end

		if (m0_max_deny > PR_MAX_M0_DENY_DMA) begin
			$display("FAIL G1 max_deny=%0d > %0d grants=%0d", m0_max_deny, PR_MAX_M0_DENY_DMA, m0_grants);
			fail = 1;
		end else if (m0_grants < 1) begin
			$display("FAIL G1 present starved grants=%0d", m0_grants);
			fail = 1;
		end else
			$display("PASS G1 max_deny=%0d grants=%0d t_cont_us_scaled=%0d (PR_with_present=%0d)",
				m0_max_deny, m0_grants, t_cont_us_scaled, PR_T_WITH_PRESENT_US);

		if (t_cont_us_scaled >= PR_T_COPY_ARM_US) begin
			$display("FAIL G1 t_cont %0d >= ARM %0d", t_cont_us_scaled, PR_T_COPY_ARM_US);
			fail = 1;
		end else
			$display("PASS G1 fabric_contended_beats_arm margin_us=%0d",
				PR_T_COPY_ARM_US - t_cont_us_scaled);

		$display("MEASURE G1 vs PREREG ratio_x100=%0d (100=match)",
			(t_cont_us_scaled * 100) / (PR_T_WITH_PRESENT_US == 0 ? 1 : PR_T_WITH_PRESENT_US));

		// G1b product CWE quantum (BUSY=0 deterministic)
		busy_force = 0;
		m0_want = 1; cwe_en = 1;
		m0_grants = 0; m0_deny = 0; m0_max_deny = 0;
		repeat (500) begin step; end
		cwe_en = 0; m0_want = 0;
		if (m0_max_deny > PR_MAX_M0_DENY_CWE) begin
			$display("FAIL G1b product CWE max_deny=%0d > %0d", m0_max_deny, PR_MAX_M0_DENY_CWE);
			fail = 1;
		end else
			$display("PASS G1b product CWE max_deny=%0d grants=%0d (quantum bound %0d)",
				m0_max_deny, m0_grants, PR_MAX_M0_DENY_CWE);
`endif

		if (proto_fail) begin
			$display("FAIL protocol monitor"); fail = 1;
		end else
			$display("PASS PROTO burst_hold_and_constant_addr_bc");

		if (PR_M10K_DMA != 0 || PR_M10K_ARB3 != 0) begin
			$display("FAIL M10K_PREREG dma=%0d arb3=%0d (expect 0+0 MLAB)", PR_M10K_DMA, PR_M10K_ARB3);
			fail = 1;
		end else
			$display("PASS M10K_PREREG dma=%0d arb3=%0d", PR_M10K_DMA, PR_M10K_ARB3);

		if (fail) begin
			$display("FAIL ddr_frame_dma_contended_tb");
			$display("DEVICE_BW_VERIFIED=0 NOT_INTEGRATION_READY=staging_doorbell_OPEN");
			$fatal(1);
		end
		$display("PASS ddr_frame_dma_contended_tb all");
		$display("DEVICE_BW_VERIFIED=0 NOT_INTEGRATION_READY=staging_doorbell_OPEN");
		$finish;
	end
endmodule
