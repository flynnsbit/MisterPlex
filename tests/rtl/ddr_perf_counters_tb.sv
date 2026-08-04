// POS: known wr/rd/stall pattern matches counters after snap.
// NEG (FAULT_MISCOUNT_STALL): stall counter stays 0 while stalls injected → fail POS check.
`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */
/* verilator lint_off SYNCASYNCNET */

module ddr_perf_counters_tb;
`ifdef FAULT_MISCOUNT_STALL
	localparam bit FAULT = 1;
`else
	localparam bit FAULT = 0;
`endif

	reg clk = 0;
	always #5 clk = ~clk; // 100 MHz sim
	reg rst = 1;

	reg busy, rd, we, dout_ready;
	reg [7:0] burstcnt;
	reg [1:0] owner;
	reg snap, clear_req;

	wire [7:0] snap_seq;
	wire [31:0] sh_cycles, sh_wr, sh_rd, sh_stall;
	wire [31:0] sh_lat_sum, sh_lat_max, sh_lat_n;
	wire [31:0] sh_m0_rd, sh_m0_wr, sh_m1_rd, sh_m1_wr, sh_m2_rd, sh_m2_wr;
	wire [15:0] sh_sat;

	ddr_perf_counters #(.FAULT_MISCOUNT_STALL(FAULT)) u_dut (
		.clk(clk), .reset(rst),
		.DDRAM_BUSY(busy), .DDRAM_RD(rd), .DDRAM_WE(we),
		.DDRAM_DOUT_READY(dout_ready), .DDRAM_BURSTCNT(burstcnt),
		.owner(owner),
		.snap_req(snap), .clear_req(clear_req),
		.snap_seq(snap_seq),
		.sh_cycles(sh_cycles), .sh_wr_beats(sh_wr), .sh_rd_beats(sh_rd),
		.sh_stall_cyc(sh_stall),
		.sh_lat_sum(sh_lat_sum), .sh_lat_max(sh_lat_max), .sh_lat_n(sh_lat_n),
		.sh_m0_rd(sh_m0_rd), .sh_m0_wr(sh_m0_wr),
		.sh_m1_rd(sh_m1_rd), .sh_m1_wr(sh_m1_wr),
		.sh_m2_rd(sh_m2_rd), .sh_m2_wr(sh_m2_wr),
		.sh_sat_flags(sh_sat)
	);

	integer i;
	reg done;

	task automatic tick;
		begin @(posedge clk); #1; end
	endtask

	initial begin
		done = 0;
		busy = 0; rd = 0; we = 0; dout_ready = 0;
		burstcnt = 8'd1; owner = 2'd0;
		snap = 0; clear_req = 0;
		$display("=== ddr_perf_counters_tb EXECUTED FAULT=%0d ===", FAULT);
		repeat (4) tick;
		rst = 0;
		repeat (2) tick;

		// --- Inject 10 write beats on m0, no stall ---
		owner = 2'd0;
		for (i = 0; i < 10; i = i + 1) begin
			we = 1; busy = 0;
			tick;
		end
		we = 0;
		tick;

		// --- Inject 5 write beats on m1 ---
		owner = 2'd1;
		for (i = 0; i < 5; i = i + 1) begin
			we = 1; busy = 0;
			tick;
		end
		we = 0;
		tick;

		// --- 7 stall cycles (cmd held while busy) ---
		owner = 2'd0;
		we = 1; busy = 1;
		for (i = 0; i < 7; i = i + 1) tick;
		// complete the write after stalls
		busy = 0;
		tick; // 11th m0 write
		we = 0;
		tick;

		// --- Read burst: accept RD burstcnt=4, 3 stall on wait, then 4 data ---
		owner = 2'd0;
		rd = 1; busy = 0; burstcnt = 8'd4;
		tick; // accept cmd
		rd = 1; busy = 1; // stall while still presenting (optional)
		// drop cmd after accept
		rd = 0; busy = 0;
		// wait 3 cycles latency
		tick; tick; tick;
		for (i = 0; i < 4; i = i + 1) begin
			dout_ready = 1;
			tick;
		end
		dout_ready = 0;
		tick;

		// Snap
		snap = 1;
		tick;
		snap = 0;
		tick;
		tick;

		$display("SNAP seq=%0d cyc=%0d wr=%0d rd=%0d stall=%0d m0w=%0d m1w=%0d lat_n=%0d lat_sum=%0d",
			snap_seq, sh_cycles, sh_wr, sh_rd, sh_stall, sh_m0_wr, sh_m1_wr, sh_lat_n, sh_lat_sum);

		// Expected: wr = 10 + 5 + 1 = 16; m0_wr=11; m1_wr=5; rd=4; stall=7 (+ maybe more)
		if (sh_wr != 32'd16) begin
			$display("FAIL wr_beats exp=16 got=%0d", sh_wr);
			done = 1; #20; $finish;
		end
		if (sh_m0_wr != 32'd11) begin
			$display("FAIL m0_wr exp=11 got=%0d", sh_m0_wr);
			done = 1; #20; $finish;
		end
		if (sh_m1_wr != 32'd5) begin
			$display("FAIL m1_wr exp=5 got=%0d", sh_m1_wr);
			done = 1; #20; $finish;
		end
		if (sh_rd != 32'd4) begin
			$display("FAIL rd_beats exp=4 got=%0d", sh_rd);
			done = 1; #20; $finish;
		end
		if (sh_lat_n < 32'd1) begin
			$display("FAIL lat_n expected >=1 got=%0d", sh_lat_n);
			done = 1; #20; $finish;
		end

		if (!FAULT) begin
			if (sh_stall < 32'd7) begin
				$display("FAIL stall exp>=7 got=%0d", sh_stall);
				done = 1; #20; $finish;
			end
			$display("PASS POS beats wr=16 rd=4 stall=%0d m0w=11 m1w=5 lat_n=%0d",
				sh_stall, sh_lat_n);
			$display("PASS ddr_perf_counters_tb FAULT=0");
		end else begin
			// NEG: stall must NOT have counted the 7 injected stalls
			if (sh_stall >= 32'd7) begin
				$display("FAIL NEG expected miscount stall<%0d got=%0d", 7, sh_stall);
				done = 1; #20; $finish;
			end
			$display("REPRO_OK NEG FAULT_MISCOUNT_STALL stall=%0d (injected 7)", sh_stall);
			$display("PASS ddr_perf_counters_tb FAULT=1");
		end
		done = 1;
		#20;
		$finish;
	end

	initial begin
		#1_000_000;
		if (!done) begin $display("FAIL timeout"); $finish; end
	end
endmodule
