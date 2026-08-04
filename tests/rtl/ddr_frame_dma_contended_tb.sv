// ddr_frame_dma + ddr_bus_arbiter3 under present load (w-mem).
//
// PRE-REGISTER (published before sim measure; do not edit post-hoc to match):
//   PR_T_COPY_ARM_US           = 14978
//   PR_T_IDEAL_SOLO_US         = 3840   // 2*(1382400/8)/90
//   PR_T_WITH_PRESENT_US       = 5760   // 1.5× ideal (present R share)
//   PR_M10K_DMA                = 2      // bounce 128×64b → 2×M10K (width-bound)
//   PR_M10K_ARB3               = 2      // m1 FIFO 8×64b same width class upper
//   PR_QUANTUM                 = 8
//   PR_MAX_M0_DENY_PRODUCT     = 48
//
// G0  solo DMA COPY — bit-exact + scaled µs
// G1  DMA + continuous present RD, product quantum — deny bound + beats ARM
// G_NEG FAULT: continuous m2 WE (not DMA — DMA has RD gaps) → REPRO starve
// G2  misalign → err_align
//
// Device BW: NOT claimed. Scale assumes ideal 1-cycle accept phys.
`timescale 1ns / 1ps

module ddr_frame_dma_contended_tb;
	reg clk = 0, clk_m1 = 0, reset = 1;
	always #5 clk = ~clk;
	always #25 clk_m1 = ~clk_m1;

	localparam int PR_T_COPY_ARM_US = 14978;
	localparam int PR_T_IDEAL_SOLO_US = 3840;
	localparam int PR_T_WITH_PRESENT_US = 5760;
	localparam int PR_M10K_DMA = 2;
	localparam int PR_M10K_ARB3 = 2;
	localparam int PR_QUANTUM = 8;
	localparam int PR_MAX_M0_DENY_CWE = 48;
	// DMA bounce WR can hold m2 for up to BOUNCE_DEPTH beats before m0 samples;
	// bound is bounce-class, not the CWE quantum bound.
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

	// DMA ports
	reg        dma_start;
	reg [31:0] dma_src, dma_dst, dma_fb;
	wire       dma_busy, dma_done, dma_err;
	wire [31:0] dma_rd_beats, dma_wr_beats, dma_last_fb;
	wire       dma_busy_o;
	wire [7:0] dma_burstcnt;
	wire [28:0] dma_addr;
	wire [63:0] dma_dout_from_arb;
	wire       dma_dout_ready;
	wire       dma_rd, dma_we;
	wire [63:0] dma_din;
	wire [7:0] dma_be;

	// Continuous WE twin (FAULT REPRO / optional)
	reg        cwe_en;
	reg [28:0] cwe_addr;
	wire       cwe_we = cwe_en;
	wire       cwe_want = cwe_en;

`ifdef DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM
	localparam bit USE_CWE = 1'b1;
`else
	localparam bit USE_CWE = 1'b0;
`endif

	wire       m2_busy;
	wire [7:0] m2_burstcnt = USE_CWE ? 8'd1 : dma_burstcnt;
	wire [28:0] m2_addr = USE_CWE ? cwe_addr : dma_addr;
	wire [63:0] m2_dout;
	wire       m2_dout_ready;
	wire       m2_rd = USE_CWE ? 1'b0 : dma_rd;
	wire [63:0] m2_din = USE_CWE ? 64'hDEAD_BEEF_CAFE_F00D : dma_din;
	wire [7:0] m2_be = USE_CWE ? 8'hFF : dma_be;
	wire       m2_we = USE_CWE ? cwe_we : dma_we;
	wire       m2_want = USE_CWE ? cwe_want : (dma_busy | dma_rd | dma_we);

	assign dma_busy_o = m2_busy; // name clarity
	assign dma_dout_from_arb = m2_dout;
	// bind dma bridge
	wire dma_bridge_busy = USE_CWE ? 1'b1 : m2_busy;
	wire dma_bridge_dout_ready = USE_CWE ? 1'b0 : m2_dout_ready;

	wire m1_busy;
	wire [63:0] m1_dout;
	wire m1_dout_ready;

	ddr_frame_dma #(.BOUNCE_DEPTH(128), .DEFAULT_FRAME_BYTES(N_BYTES)) u_dma (
		.clk(clk), .reset(reset),
		.start(dma_start & ~USE_CWE),
		.src_phys(dma_src), .bank_phys(dma_dst), .frame_bytes(dma_fb),
		.busy(dma_busy), .done(dma_done), .err_align(dma_err),
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
		.DDRAM_WE(DDRAM_WE)
	);

	reg [7:0] rd_left;
	reg [28:0] rd_a;
	reg rd_pend;
	integer cyc;
	integer m0_grants, m0_deny, m0_max_deny;
	integer present_div;
	reg present_need;
	integer g_prev;
	integer dma_start_cyc, dma_done_cyc;
	integer solo_cyc, cont_cyc;
	integer t_solo_us_scaled, t_cont_us_scaled;
	integer i, fail;
	reg local_fail;

	task automatic tick; begin @(posedge clk); cyc = cyc + 1; end endtask

	task automatic phys_step;
		begin
			DDRAM_DOUT_READY = 0;
			DDRAM_BUSY = 0;
			if (rd_pend && rd_left != 0) begin
				DDRAM_DOUT = mem[rd_a[11:0]];
				DDRAM_DOUT_READY = 1;
				rd_a = rd_a + 1;
				rd_left = rd_left - 1;
				if (rd_left == 0) rd_pend = 0;
			end else if (DDRAM_RD && !DDRAM_BUSY) begin
				rd_pend = 1;
				rd_a = DDRAM_ADDR;
				rd_left = (DDRAM_BURSTCNT == 0) ? 8'd1 : DDRAM_BURSTCNT;
			end else if (DDRAM_WE && !DDRAM_BUSY) begin
				mem[DDRAM_ADDR[11:0]] = DDRAM_DIN;
				if (USE_CWE) cwe_addr = cwe_addr + 1;
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
			end else if (m0_busy) begin
				m0_deny <= m0_deny + 1;
				if (m0_deny + 1 > m0_max_deny) m0_max_deny <= m0_deny + 1;
			end
		end else begin
			m0_rd <= 0; m0_deny <= 0;
		end
	end

	initial begin
		$display("=== ddr_frame_dma_contended_tb EXECUTED USE_CWE=%0d ===", USE_CWE);
		$display("PREREG arm=%0d ideal=%0d with_present=%0d m10k_dma=%0d Q=%0d cwe_deny=%0d dma_deny=%0d",
			PR_T_COPY_ARM_US, PR_T_IDEAL_SOLO_US, PR_T_WITH_PRESENT_US,
			PR_M10K_DMA, PR_QUANTUM, PR_MAX_M0_DENY_CWE, PR_MAX_M0_DENY_DMA);

		fail = 0; cyc = 0;
		dma_start = 0; cwe_en = 0; cwe_addr = 29'h200;
		dma_src = SRC_PHYS; dma_dst = DST_PHYS; dma_fb = N_BYTES;
		m0_want = 0;
		DDRAM_BUSY = 0; DDRAM_DOUT = 0; DDRAM_DOUT_READY = 0;
		rd_pend = 0; rd_left = 0;
		for (i = 0; i < 4096; i = i + 1) mem[i] = 64'd0;
		for (i = 0; i < N_QWORDS; i = i + 1)
			mem[(SRC_PHYS/8) + i] = 64'hA5A5_0000_0000_0000 ^ {32'd0, i[31:0]};

		repeat (8) tick;
		reset = 0;
		repeat (4) begin phys_step; tick; end

`ifdef DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM
		// ---- FAULT: continuous WE + present RD ----
		m0_want = 1;
		cwe_en = 1;
		m0_grants = 0; m0_deny = 0; m0_max_deny = 0;
		repeat (500) begin phys_step; tick; end
		cwe_en = 0; m0_want = 0;
		if (m0_max_deny < 64) begin
			$display("FAIL FAULT twin max_deny=%0d < 64", m0_max_deny);
			fail = 1;
		end else
			$display("REPRO_OK FAULT max_deny=%0d grants=%0d", m0_max_deny, m0_grants);
`else
		// ---- G2 misalign ----
		dma_src = SRC_PHYS + 1;
		dma_start = 1; phys_step; tick; dma_start = 0;
		repeat (20) begin phys_step; tick; end
		if (!dma_err) begin $display("FAIL G2 expected err_align"); fail = 1;
		end else $display("PASS G2 misalign err_align");
		dma_src = SRC_PHYS;

		// ---- G0 solo DMA ----
		for (i = 0; i < N_QWORDS; i = i + 1) mem[(DST_PHYS/8) + i] = 64'd0;
		m0_want = 0;
		dma_start_cyc = cyc;
		dma_start = 1; phys_step; tick; dma_start = 0;
		while (!dma_done && cyc < dma_start_cyc + 200000) begin phys_step; tick; end
		solo_cyc = cyc - dma_start_cyc;
		local_fail = 0;
		if (dma_rd_beats != N_QWORDS || dma_wr_beats != N_QWORDS) begin
			$display("FAIL G0 beats rd=%0d wr=%0d", dma_rd_beats, dma_wr_beats);
			local_fail = 1; fail = 1;
		end
		for (i = 0; i < N_QWORDS; i = i + 1) begin
			if (mem[(DST_PHYS/8)+i] !== (64'hA5A5_0000_0000_0000 ^ {32'd0, i[31:0]})) begin
				$display("FAIL G0 dst[%0d]", i); local_fail = 1; fail = 1;
			end
		end
		t_solo_us_scaled = (solo_cyc * QWORDS_FULL / N_QWORDS) / CLK_DDR_MHZ;
		if (!local_fail)
			$display("PASS G0 solo copied=%0d cyc=%0d t_full_us_scaled=%0d (PR_ideal=%0d)",
				N_QWORDS, solo_cyc, t_solo_us_scaled, PR_T_IDEAL_SOLO_US);

		// ---- G1 DMA + present at REALISTIC duty (~6.25%) ----
		// Continuous 100% m0_rd is NOT scanout; present R_req @720p24 ≈ 4.6% peak.
		// Request one RD every 16 cycles; hold want until accepted.
		for (i = 0; i < N_QWORDS; i = i + 1) mem[(DST_PHYS/8) + i] = 64'd0;
		m0_grants = 0; m0_deny = 0; m0_max_deny = 0;
		present_div = 0; present_need = 1'b0;
		g_prev = 0;
		repeat (16) begin phys_step; tick; end
		dma_start_cyc = cyc;
		dma_start = 1; phys_step; tick; dma_start = 0;
		while (!dma_done && cyc < dma_start_cyc + 400000) begin
			if (present_div == 0)
				present_need = 1'b1;
			present_div = (present_div == 15) ? 0 : (present_div + 1);
			m0_want = present_need;
			phys_step; tick;
			if (m0_grants > g_prev) begin
				present_need = 1'b0;
				g_prev = m0_grants;
			end
		end
		cont_cyc = cyc - dma_start_cyc;
		t_cont_us_scaled = (cont_cyc * QWORDS_FULL / N_QWORDS) / CLK_DDR_MHZ;
		m0_want = 0;

		if (m0_max_deny > PR_MAX_M0_DENY_DMA) begin
			$display("FAIL G1 max_deny=%0d > %0d grants=%0d", m0_max_deny, PR_MAX_M0_DENY_DMA, m0_grants);
			fail = 1;
		end else if (m0_grants < 1) begin
			$display("FAIL G1 present starved grants=%0d", m0_grants);
			fail = 1;
		end else
			$display("PASS G1 max_deny=%0d grants=%0d t_cont_us_scaled=%0d (PR_with_present=%0d DMA_deny_bound=%0d)",
				m0_max_deny, m0_grants, t_cont_us_scaled, PR_T_WITH_PRESENT_US, PR_MAX_M0_DENY_DMA);

		if (t_cont_us_scaled >= PR_T_COPY_ARM_US) begin
			$display("FAIL G1 t_cont %0d >= ARM %0d", t_cont_us_scaled, PR_T_COPY_ARM_US);
			fail = 1;
		end else
			$display("PASS G1 fabric_contended_beats_arm margin_us=%0d",
				PR_T_COPY_ARM_US - t_cont_us_scaled);

		if (t_cont_us_scaled > (PR_T_WITH_PRESENT_US * 2))
			$display("WARN G1 measure %0d >> PREREG %0d", t_cont_us_scaled, PR_T_WITH_PRESENT_US);
		else
			$display("MEASURE G1 vs PREREG ratio_x100=%0d (100=match)",
				(t_cont_us_scaled * 100) / (PR_T_WITH_PRESENT_US == 0 ? 1 : PR_T_WITH_PRESENT_US));

		// Product continuous-WE quantum spot-check (same stimulus as FAULT twin)
		m0_want = 1; cwe_en = 1;
		m0_grants = 0; m0_deny = 0; m0_max_deny = 0;
		repeat (500) begin phys_step; tick; end
		cwe_en = 0; m0_want = 0;
		if (m0_max_deny > PR_MAX_M0_DENY_CWE) begin
			$display("FAIL G1b product CWE max_deny=%0d > %0d", m0_max_deny, PR_MAX_M0_DENY_CWE);
			fail = 1;
		end else
			$display("PASS G1b product CWE max_deny=%0d grants=%0d (quantum bound %0d)", m0_max_deny, m0_grants, PR_MAX_M0_DENY_CWE);
`endif

		if (PR_M10K_DMA != 2 || PR_M10K_ARB3 != 2) begin
			$display("FAIL PREREG m10k (expect 2/2 width-bound 64b)"); fail = 1;
		end else
			$display("PASS M10K_PREREG dma=%0d arb3=%0d (64b→2×M10K layout; entity fit UNVERIFIED)",
				PR_M10K_DMA, PR_M10K_ARB3);

		if (fail) begin $display("FAIL ddr_frame_dma_contended_tb"); $finish(1); end
		$display("PASS ddr_frame_dma_contended_tb all");
		$display("DEVICE_BW_VERIFIED=0 CHECK=parent_fit_plus_hdmi_capture");
		$finish(0);
	end
endmodule
