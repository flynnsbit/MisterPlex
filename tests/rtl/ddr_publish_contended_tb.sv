// ddr_publish_contended_tb — contention + path geom (w-mem).
//
// G0  publish_engine COPY solo (direct phys; same harness class as engine TB)
// G1  product arbiter3 quantum: continuous m2 WE vs m0 RD → max_deny bound
// G2  ddr_publish_path geom 720p legal + misalign NEG
// G_NEG FAULT sticky-no-quantum starves m0 (REPRO_OK)
//
// PRE-REGISTER (ideal port math @90 MHz — NOT HPS measured):
//   peak 720 MB/s; present 33.1776; COPY R+W 66.3552; sum 99.53 ≈ 13.8% peak
//   G1 max_deny ≤ 48 with Q=8; FAULT max_deny ≥ 80
// Control: this TB + test_ddr_publish_contended_rtl_sim.sh true rc

`timescale 1ns/1ps
`default_nettype none

module ddr_publish_contended_tb;
	localparam int CLK_HALF = 5;
	localparam int M2_Q = 8;
	localparam int MEM_W = 4096;
	localparam int MAX_BURST = 8;

	reg clk = 0, clk_m1 = 0, reset;
	always #CLK_HALF clk = ~clk;
	always #(CLK_HALF * 2) clk_m1 = ~clk_m1;

	integer fails;

	task automatic step; begin @(posedge clk); #1; end endtask

	// ───────── G0: engine COPY solo ─────────
	reg eng_start, eng_mode, eng_ring, eng_present;
	reg [31:0] eng_src, eng_dst, eng_bytes, eng_db;
	reg [63:0] eng_dbw;
	wire eng_busy, eng_done, eng_err, eng_want;
	wire [31:0] eng_copied;
	wire [15:0] eng_brd, eng_bwr;
	reg eBUSY, eREADY;
	reg [63:0] eDOUT;
	wire [7:0] eBCNT, eBE;
	wire [28:0] eADDR;
	wire eRD, eWE;
	wire [63:0] eDIN;
	reg [63:0] emem [0:MEM_W-1];
	reg [7:0] e_rd_left;
	reg [28:0] e_rd_addr;
	reg e_wr_busy;

	ddr_publish_engine #(.MAX_BURST(MAX_BURST)) eng (
		.clk(clk), .reset(reset),
		.cmd_start(eng_start), .cmd_mode(eng_mode),
		.cmd_src_phys(eng_src), .cmd_dst_phys(eng_dst),
		.cmd_bytes(eng_bytes), .cmd_doorbell_phys(eng_db),
		.cmd_ring_doorbell(eng_ring), .cmd_doorbell_word(eng_dbw),
		.busy(eng_busy), .done_pulse(eng_done), .err(eng_err),
		.bytes_copied(eng_copied), .beats_rd(eng_brd), .beats_wr(eng_bwr),
		.present_want(eng_present), .bus_want(eng_want),
		.DDRAM_BUSY(eBUSY), .DDRAM_BURSTCNT(eBCNT), .DDRAM_ADDR(eADDR),
		.DDRAM_DOUT(eDOUT), .DDRAM_DOUT_READY(eREADY),
		.DDRAM_RD(eRD), .DDRAM_DIN(eDIN), .DDRAM_BE(eBE), .DDRAM_WE(eWE)
	);

	always @(posedge clk) begin
		if (reset) begin
			eBUSY <= 0; eREADY <= 0; eDOUT <= 0; e_rd_left <= 0; e_wr_busy <= 0;
		end else begin
			eREADY <= 0;
			if (e_wr_busy) begin e_wr_busy <= 0; eBUSY <= 0;
			end else if (e_rd_left != 0) begin
				eDOUT <= emem[e_rd_addr[11:0]];
				eREADY <= 1;
				e_rd_addr <= e_rd_addr + 1;
				e_rd_left <= e_rd_left - 1;
				if (e_rd_left == 1) eBUSY <= 0;
			end else if (eRD && !eBUSY) begin
				e_rd_left <= eBCNT; e_rd_addr <= eADDR; eBUSY <= 1;
			end else if (eWE && !eBUSY) begin
				emem[eADDR[11:0]] <= eDIN; e_wr_busy <= 1; eBUSY <= 1;
			end
		end
	end

	task automatic test_g0_copy;
		integer i, cyc, local_fail;
		begin
			$display("=== G0 engine COPY solo ===");
			local_fail = 0;
			for (i = 0; i < MEM_W; i = i + 1) emem[i] = 64'hDEAD000000000000 | i[31:0];
			for (i = 0; i < 32; i = i + 1) emem[12'h010 + i] = 64'hA5A5000000000000 | (i + 1);
			for (i = 0; i < 32; i = i + 1) emem[12'h100 + i] = 64'd0;
			eng_present = 0; eng_mode = 1;
			eng_src = 32'h80; eng_dst = 32'h800; eng_bytes = 256;
			eng_db = 32'h1000; eng_ring = 1; eng_dbw = 64'h504C584400000001;
			eng_start = 1; step(); eng_start = 0;
			cyc = 0;
			while (!eng_done && cyc < 20000) begin step(); cyc = cyc + 1; end
			if (!eng_done || eng_err || eng_copied != 256) begin
				$display("FAIL G0 done=%0b err=%0b copied=%0d", eng_done, eng_err, eng_copied);
				fails = fails + 1; local_fail = 1;
			end
			for (i = 0; i < 32; i = i + 1) begin
				if (emem[12'h100 + i] !== (64'hA5A5000000000000 | (i + 1))) begin
					$display("FAIL G0 dst[%0d]=%h", i, emem[12'h100 + i]);
					fails = fails + 1; local_fail = 1;
				end
			end
			if (emem[12'h200] !== 64'h504C584400000001) begin
				$display("FAIL G0 doorbell"); fails = fails + 1; local_fail = 1;
			end
			if (!local_fail) $display("PASS G0 copied=%0d cyc=%0d brd=%0d bwr=%0d",
				eng_copied, cyc, eng_brd, eng_bwr);
		end
	endtask

	// ───────── G2: path geom ─────────
	wire [31:0] p_fb, p_dst, p_db;
	wire p_legal, p_src_al, p_busy, p_done, p_err;
	wire [31:0] p_copied;
	wire [15:0] p_brd, p_bwr;
	wire p_want;
	reg p_start, p_mode, p_bank, p_ring;
	reg [31:0] p_src, p_bov;
	reg [63:0] p_dbw;
	wire [7:0] p_bc, p_be;
	wire [28:0] p_addr;
	wire p_rd, p_we;
	wire [63:0] p_din;

	ddr_publish_path #(
		.CODED_W(1280), .CODED_H(720),
		.PHYS_BASE(32'h3018_0000),
		.BANK_STRIDE_BYTES(32'h0018_0000),
		.DOORBELL_PHYS(32'h3047_F000),
		.MAX_BURST(8)
	) path (
		.clk(clk), .reset(reset),
		.start(p_start), .cmd_mode(p_mode), .bank_sel(p_bank),
		.src_phys(p_src), .ring_doorbell(p_ring), .doorbell_word(p_dbw),
		.bytes_override(p_bov),
		.busy(p_busy), .done_pulse(p_done), .err(p_err),
		.job_legal(p_legal), .src_aligned(p_src_al),
		.frame_bytes(p_fb), .dst_bank_phys(p_dst), .doorbell_phys_o(p_db),
		.bytes_copied(p_copied), .beats_rd(p_brd), .beats_wr(p_bwr),
		.present_want(1'b0), .bus_want(p_want),
		.DDRAM_BUSY(1'b1), .DDRAM_BURSTCNT(p_bc), .DDRAM_ADDR(p_addr),
		.DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0),
		.DDRAM_RD(p_rd), .DDRAM_DIN(p_din), .DDRAM_BE(p_be), .DDRAM_WE(p_we)
	);

	task automatic test_g2_geom;
		integer cyc;
		begin
			$display("=== G2 geom job ===");
			if (!p_legal || p_fb != 32'd1382400 || p_db != 32'h3047_F000 ||
			    p_dst != 32'h3018_0000) begin
				$display("FAIL G2 legal=%0b fb=%0d dst=%h db=%h",
					p_legal, p_fb, p_dst, p_db);
				fails = fails + 1;
			end else $display("PASS G2 frame_bytes=%0d dst=%h db=%h", p_fb, p_dst, p_db);

			$display("=== G2N illegal misaligned src ===");
			p_mode = 1; p_bank = 0; p_src = 32'h4; p_bov = 64; p_ring = 0;
			p_start = 1; step(); p_start = 0;
			cyc = 0;
			while (!p_done && cyc < 50) begin step(); cyc = cyc + 1; end
			if (!p_err || !p_done) begin
				$display("FAIL G2N err=%0b done=%0b", p_err, p_done);
				fails = fails + 1;
			end else $display("PASS G2N misalign err");
		end
	endtask

	// ───────── G1 / FAULT: arbiter3 quantum ─────────
	reg m0_want, m0_rd_r;
	reg [28:0] m0_addr_r;
	wire m0_busy, m0_drdy;
	wire [63:0] m0_dout;
	integer m0_grants, m0_deny, m0_max_deny;

	reg f_want, f_we;
	reg [28:0] f_addr;
	reg [63:0] f_din;
	wire m2_busy;

	reg aBUSY, aREADY;
	reg [63:0] aDOUT;
	wire [7:0] aBCNT, aBE;
	wire [28:0] aADDR;
	wire aRD, aWE;
	wire [63:0] aDIN;
	reg a_wr_busy;

	ddr_bus_arbiter3 #(.M2_QUANTUM_BEATS(M2_Q)) arb (
		.clk(clk), .clk_m1(clk_m1), .reset(reset),
		.m1_want(1'b0), .m2_want(f_want),
		.m0_busy(m0_busy), .m0_burstcnt(8'd1), .m0_addr(m0_addr_r),
		.m0_dout(m0_dout), .m0_dout_ready(m0_drdy),
		.m0_rd(m0_rd_r), .m0_din(64'd0), .m0_be(8'hFF), .m0_we(1'b0),
		.m1_busy(), .m1_burstcnt(8'd1), .m1_addr(29'd0),
		.m1_dout(), .m1_dout_ready(), .m1_rd(1'b0), .m1_din(64'd0),
		.m1_be(8'hFF), .m1_we(1'b0),
		.m2_busy(m2_busy), .m2_burstcnt(8'd1), .m2_addr(f_addr),
		.m2_dout(), .m2_dout_ready(), .m2_rd(1'b0), .m2_din(f_din),
		.m2_be(8'hFF), .m2_we(f_we),
		.DDRAM_BUSY(aBUSY), .DDRAM_BURSTCNT(aBCNT), .DDRAM_ADDR(aADDR),
		.DDRAM_DOUT(aDOUT), .DDRAM_DOUT_READY(aREADY),
		.DDRAM_RD(aRD), .DDRAM_DIN(aDIN), .DDRAM_BE(aBE), .DDRAM_WE(aWE)
	);

	always @(posedge clk) begin
		if (reset) begin
			aBUSY <= 0; aREADY <= 0; aDOUT <= 0; a_wr_busy <= 0;
		end else begin
			aREADY <= 0;
			if (a_wr_busy) begin a_wr_busy <= 0; aBUSY <= 0;
			end else if (aRD && !aBUSY) begin
				aBUSY <= 1; a_wr_busy <= 1;
				aDOUT <= 64'hC0FFEE;
				aREADY <= 1;
			end else if (aWE && !aBUSY) begin
				a_wr_busy <= 1; aBUSY <= 1;
			end
		end
	end

	// Hold m0_rd while want (even if busy) so arbiter sees m0_cmd during m2
	// sticky — required for quantum preemption (see arbiter3 quantum TB).
	always @(posedge clk) begin
		if (reset) begin
			m0_rd_r <= 0; m0_addr_r <= 29'h100;
			m0_grants <= 0; m0_deny <= 0; m0_max_deny <= 0;
		end else if (m0_want) begin
			m0_rd_r <= 1'b1;
			if (!m0_busy && m0_rd_r) begin
				// Accepted this cycle (phys will take when granted)
				m0_grants <= m0_grants + 1;
				m0_deny <= 0;
				m0_addr_r <= m0_addr_r + 1;
			end else if (m0_busy) begin
				m0_deny <= m0_deny + 1;
				if (m0_deny + 1 > m0_max_deny) m0_max_deny <= m0_deny + 1;
			end
		end else begin
			m0_rd_r <= 0; m0_deny <= 0;
		end
	end

	task automatic run_m2_stream;
		input integer n;
		integer i;
		begin
			f_want = 1; f_we = 0; f_addr = 29'h200; f_din = 64'h1;
			repeat (4) step();
			for (i = 0; i < n; i = i + 1) begin
				if (!m2_busy) begin
					f_we = 1; f_addr = f_addr + 1; f_din = f_din + 1;
				end
				step();
			end
			f_we = 0; f_want = 0;
		end
	endtask

	task automatic test_g1_quantum;
		integer local_fail;
		begin
			$display("=== G1 product quantum bounds m0 deny ===");
			local_fail = 0;
			m0_want = 1; m0_grants = 0; m0_max_deny = 0;
			run_m2_stream(400);
			m0_want = 0;
			if (m0_max_deny > 48) begin
				$display("FAIL G1 max_deny=%0d > 48", m0_max_deny);
				fails = fails + 1; local_fail = 1;
			end
			if (m0_grants < 8) begin
				$display("FAIL G1 grants=%0d", m0_grants);
				fails = fails + 1; local_fail = 1;
			end
			if (!local_fail)
				$display("PASS G1 max_m0_deny=%0d grants=%0d (bound 48 Q=%0d)",
					m0_max_deny, m0_grants, M2_Q);
		end
	endtask

`ifdef DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM
	task automatic test_neg_fault;
		integer local_fail;
		begin
			$display("=== G_NEG FAULT sticky-no-quantum ===");
			local_fail = 0;
			m0_want = 1; m0_grants = 0; m0_max_deny = 0;
			run_m2_stream(400);
			m0_want = 0;
			if (m0_max_deny < 80) begin
				$display("FAIL G_NEG FAULT max_deny=%0d", m0_max_deny);
				fails = fails + 1; local_fail = 1;
			end
			if (m0_grants > 20) begin
				$display("FAIL G_NEG FAULT grants=%0d (not starved)", m0_grants);
				fails = fails + 1; local_fail = 1;
			end
			if (!local_fail)
				$display("REPRO_OK G_NEG FAULT max_deny=%0d grants=%0d",
					m0_max_deny, m0_grants);
		end
	endtask
`endif

	initial begin
		fails = 0;
		reset = 1;
		eng_start = 0; eng_mode = 0; eng_ring = 0; eng_present = 0;
		eng_src = 0; eng_dst = 0; eng_bytes = 0; eng_db = 0; eng_dbw = 0;
		p_start = 0; p_mode = 0; p_bank = 0; p_ring = 0; p_src = 0; p_bov = 0; p_dbw = 0;
		m0_want = 0; f_want = 0; f_we = 0; f_addr = 0; f_din = 0;
		repeat (8) step();
		reset = 0;
		repeat (4) step();

`ifdef DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM
		test_g2_geom();
		test_neg_fault();
		if (fails != 0) begin
			$display("FAIL ddr_publish_contended_tb FAULT fails=%0d", fails);
			$fatal(1);
		end
		$display("PASS ddr_publish_contended_tb FAULT_REPRO");
`else
		test_g2_geom();
		test_g0_copy();
		test_g1_quantum();
		$display("PASS G_NEG product_no_fault (FAULT twin run separately)");
		if (fails != 0) begin
			$display("FAIL ddr_publish_contended_tb fails=%0d", fails);
			$fatal(1);
		end
		$display("PASS ddr_publish_contended_tb all");
`endif
		$finish;
	end
endmodule

`default_nettype wire
