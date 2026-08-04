// Prove scanout (m0) worst-case wait under continuous m3 single-beat traffic.
// POS: m0 accepted within MAX_BURST+slack cycles after assert while m3 floods.
// NEG (FAULT_NO_M0_YIELD): m3 sticky without quantum → m0 starves past bound.
`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */
/* verilator lint_off SYNCASYNCNET */

module ddr_arbiter4_scanout_bound_tb;
`ifdef FAULT_NO_M0_YIELD
	localparam bit FAULT = 1;
`else
	localparam bit FAULT = 0;
`endif
	localparam int MAXB = 8;
	// WC bound in cycles (idle controller): finish m3 burst + 1 + m0 accept
	localparam int BOUND = MAXB + 4;

	reg clk = 0, clk_m1 = 0;
	always #5 clk = ~clk;
	always #5 clk_m1 = ~clk_m1;
	reg rst = 1;

	// Ideal memory: never busy; RD returns data next cycle for burstcnt beats
	reg [7:0] rd_left_mem;
	wire DDRAM_BUSY = 1'b0;
	wire [7:0] DDRAM_BURSTCNT;
	wire [28:0] DDRAM_ADDR;
	reg [63:0] DDRAM_DOUT;
	reg DDRAM_DOUT_READY;
	wire DDRAM_RD, DDRAM_WE;
	wire [63:0] DDRAM_DIN;
	wire [7:0] DDRAM_BE;

	// m0
	reg m0_rd, m0_we;
	reg [7:0] m0_bc;
	reg [28:0] m0_addr;
	wire m0_busy, m0_dout_ready;
	wire [63:0] m0_dout;
	// m3 flood
	reg m3_rd, m3_we, m3_want;
	reg [7:0] m3_bc;
	reg [28:0] m3_addr;
	wire m3_busy, m3_dout_ready;
	wire [63:0] m3_dout;

	// unused masters tied off
	wire m1_busy, m1_dout_ready, m2_busy, m2_dout_ready;
	wire [63:0] m1_dout, m2_dout;
	wire [1:0] grant_owner;

`ifndef FAULT_NO_M0_YIELD
	ddr_bus_arbiter4 #(.MAX_BURST(MAXB), .M2_QUANTUM(8), .M3_QUANTUM(4)) u_dut (
`else
	// FAULT: huge m3 quantum ≈ never yield
	ddr_bus_arbiter4 #(.MAX_BURST(MAXB), .M2_QUANTUM(8), .M3_QUANTUM(255)) u_dut (
`endif
		.clk(clk), .clk_m1(clk_m1), .reset(rst),
		.m1_want(1'b0), .m2_want(1'b0), .m2_yield_window(1'b1), .m3_want(m3_want),
		.m0_busy(m0_busy), .m0_burstcnt(m0_bc), .m0_addr(m0_addr),
		.m0_dout(m0_dout), .m0_dout_ready(m0_dout_ready),
		.m0_rd(m0_rd), .m0_din(64'd0), .m0_be(8'hFF), .m0_we(m0_we),
		.m1_busy(m1_busy), .m1_burstcnt(8'd1), .m1_addr(29'd0),
		.m1_dout(m1_dout), .m1_dout_ready(m1_dout_ready),
		.m1_rd(1'b0), .m1_din(64'd0), .m1_be(8'hFF), .m1_we(1'b0),
		.m2_busy(m2_busy), .m2_burstcnt(8'd1), .m2_addr(29'd0),
		.m2_dout(m2_dout), .m2_dout_ready(m2_dout_ready),
		.m2_rd(1'b0), .m2_din(64'd0), .m2_be(8'hFF), .m2_we(1'b0),
		.m3_busy(m3_busy), .m3_burstcnt(m3_bc), .m3_addr(m3_addr),
		.m3_dout(m3_dout), .m3_dout_ready(m3_dout_ready),
		.m3_rd(m3_rd), .m3_din(64'd0), .m3_be(8'hFF), .m3_we(m3_we),
		.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.grant_owner(grant_owner)
	);

	// Simple read response model
	always @(posedge clk) begin
		if (rst) begin
			rd_left_mem <= 0;
			DDRAM_DOUT_READY <= 0;
			DDRAM_DOUT <= 0;
		end else begin
			DDRAM_DOUT_READY <= 0;
			if (rd_left_mem != 0) begin
				DDRAM_DOUT_READY <= 1;
				DDRAM_DOUT <= DDRAM_DOUT + 64'd1;
				rd_left_mem <= rd_left_mem - 8'd1;
			end else if (DDRAM_RD && !DDRAM_BUSY) begin
				rd_left_mem <= (DDRAM_BURSTCNT == 0) ? 8'd1 : DDRAM_BURSTCNT;
			end
		end
	end

	integer wait_c, i;
	reg done, m0_got;

	task automatic tick; begin @(posedge clk); #1; end endtask

	initial begin
		done = 0; m0_got = 0;
		m0_rd = 0; m0_we = 0; m0_bc = 8'd1; m0_addr = 29'h100;
		m3_rd = 0; m3_we = 0; m3_want = 0; m3_bc = 8'd1; m3_addr = 29'h200;
		$display("=== ddr_arbiter4_scanout_bound_tb FAULT=%0d BOUND=%0d ===", FAULT, BOUND);
		repeat (4) tick; rst = 0; repeat (2) tick;

		// Flood m3 single-beat reads continuously
		m3_want = 1;
		m3_rd = 1;
		m3_bc = 8'd1;
		repeat (20) tick;

		// Assert m0 read request; measure cycles until m0_dout_ready
		m0_rd = 1;
		m0_bc = 8'd1;
		wait_c = 0;
		m0_got = 0;
		for (i = 0; i < 512; i = i + 1) begin
			tick;
			wait_c = wait_c + 1;
			if (m0_dout_ready) begin
				m0_got = 1;
				i = 512; // break
			end
		end

		$display("RESULT m0_got=%0d wait_c=%0d owner=%0d", m0_got, wait_c, grant_owner);

		if (!FAULT) begin
			if (!m0_got) begin $display("FAIL POS m0 never served"); done=1; #20; $finish; end
			if (wait_c > BOUND) begin
				$display("FAIL POS scanout wait %0d > BOUND %0d", wait_c, BOUND);
				done=1; #20; $finish;
			end
			$display("PASS POS scanout wait_c=%0d <= BOUND=%0d", wait_c, BOUND);
		end else begin
			// NEG: with Q_MC=255 and continuous m3, m0 should miss BOUND
			if (m0_got && wait_c <= BOUND) begin
				$display("FAIL NEG expected starve past BOUND got wait=%0d", wait_c);
				done=1; #20; $finish;
			end
			$display("REPRO_OK NEG FAULT_NO_M0_YIELD wait_c=%0d m0_got=%0d BOUND=%0d",
				wait_c, m0_got, BOUND);
		end
		done = 1; #20; $finish;
	end
	initial begin #2_000_000; if (!done) $display("FAIL timeout"); $finish; end
endmodule
