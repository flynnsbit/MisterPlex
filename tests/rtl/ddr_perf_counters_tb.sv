// POS: known wr/rd/stall/lat-bin/efficiency pattern matches after snap.
// NEG FAULT_MISCOUNT_STALL: stall stays 0 while stalls injected.
// NEG FAULT_MISBIN_LAT: long-latency sample forced into bin0.
`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */
/* verilator lint_off SYNCASYNCNET */

module ddr_perf_counters_tb;
`ifdef FAULT_MISCOUNT_STALL
	localparam bit FAULT_STALL = 1;
`else
	localparam bit FAULT_STALL = 0;
`endif
`ifdef FAULT_MISBIN_LAT
	localparam bit FAULT_BIN = 1;
`else
	localparam bit FAULT_BIN = 0;
`endif

	reg clk = 0;
	always #5 clk = ~clk;
	reg rst = 1;

	reg busy, rd, we, dout_ready;
	reg [7:0] burstcnt;
	reg [1:0] owner;
	reg snap, clear_req;

	wire [7:0] snap_seq;
	wire [31:0] sh_cycles, sh_wr, sh_rd, sh_stall;
	wire [31:0] sh_lat_sum, sh_lat_max, sh_lat_n;
	wire [31:0] sh_m0_rd, sh_m0_wr, sh_m1_rd, sh_m1_wr, sh_m2_rd, sh_m2_wr;
	wire [31:0] sh_b0, sh_b1, sh_b2, sh_b3, sh_b4, sh_b5;
	wire [31:0] sh_rd_cmds, sh_burst_sum, sh_single, sh_issue;
	wire [15:0] sh_sat;

	ddr_perf_counters #(
		.FAULT_MISCOUNT_STALL(FAULT_STALL),
		.FAULT_MISBIN_LAT(FAULT_BIN)
	) u_dut (
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
		.sh_lat_bin0(sh_b0), .sh_lat_bin1(sh_b1), .sh_lat_bin2(sh_b2),
		.sh_lat_bin3(sh_b3), .sh_lat_bin4(sh_b4), .sh_lat_bin5(sh_b5),
		.sh_rd_cmds(sh_rd_cmds), .sh_burst_sum(sh_burst_sum),
		.sh_single_cmds(sh_single), .sh_issue_cyc(sh_issue),
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
		$display("=== ddr_perf_counters_tb EXECUTED FAULT_STALL=%0d FAULT_BIN=%0d ===",
			FAULT_STALL, FAULT_BIN);
		repeat (4) tick;
		rst = 0;
		repeat (2) tick;

		// 10 write beats m0
		owner = 2'd0;
		for (i = 0; i < 10; i = i + 1) begin we = 1; busy = 0; tick; end
		we = 0; tick;

		// 5 write beats m1
		owner = 2'd1;
		for (i = 0; i < 5; i = i + 1) begin we = 1; busy = 0; tick; end
		we = 0; tick;

		// 7 stall cycles
		owner = 2'd0;
		we = 1; busy = 1;
		for (i = 0; i < 7; i = i + 1) tick;
		busy = 0; tick; // 11th m0 wr
		we = 0; tick;

		// RD burstcnt=4, 3 idle cycles latency → first-data lat=3 → bin0 (0-7)
		owner = 2'd0;
		rd = 1; busy = 0; burstcnt = 8'd4;
		tick; // accept
		rd = 0; busy = 0;
		tick; tick; tick; // lat_cnt ends at 3 on first data
		for (i = 0; i < 4; i = i + 1) begin dout_ready = 1; tick; end
		dout_ready = 0; tick;

		// Single-beat RD with longer latency: 20 idle cycles → bin2 (16-31)
		// (unless FAULT_MISBIN_LAT forces bin0)
		rd = 1; busy = 0; burstcnt = 8'd1;
		tick;
		rd = 0;
		for (i = 0; i < 20; i = i + 1) tick;
		dout_ready = 1; tick;
		dout_ready = 0; tick;

		// Snap
		snap = 1; tick; snap = 0; tick; tick;

		$display("SNAP seq=%0d cyc=%0d wr=%0d rd=%0d stall=%0d m0w=%0d m1w=%0d lat_n=%0d lat_sum=%0d",
			snap_seq, sh_cycles, sh_wr, sh_rd, sh_stall, sh_m0_wr, sh_m1_wr, sh_lat_n, sh_lat_sum);
		$display("BINS b0=%0d b1=%0d b2=%0d b3=%0d b4=%0d b5=%0d rd_cmds=%0d burst_sum=%0d single=%0d",
			sh_b0, sh_b1, sh_b2, sh_b3, sh_b4, sh_b5, sh_rd_cmds, sh_burst_sum, sh_single);

		if (sh_wr != 32'd16) begin $display("FAIL wr_beats exp=16 got=%0d", sh_wr); done=1; #20; $finish; end
		if (sh_m0_wr != 32'd11) begin $display("FAIL m0_wr exp=11 got=%0d", sh_m0_wr); done=1; #20; $finish; end
		if (sh_m1_wr != 32'd5) begin $display("FAIL m1_wr exp=5 got=%0d", sh_m1_wr); done=1; #20; $finish; end
		if (sh_rd != 32'd5) begin $display("FAIL rd_beats exp=5 got=%0d", sh_rd); done=1; #20; $finish; end
		if (sh_lat_n != 32'd2) begin $display("FAIL lat_n exp=2 got=%0d", sh_lat_n); done=1; #20; $finish; end
		if (sh_rd_cmds != 32'd2) begin $display("FAIL rd_cmds exp=2 got=%0d", sh_rd_cmds); done=1; #20; $finish; end
		// burst_sum = 4 + 1 = 5; single = 1
		if (sh_burst_sum != 32'd5) begin $display("FAIL burst_sum exp=5 got=%0d", sh_burst_sum); done=1; #20; $finish; end
		if (sh_single != 32'd1) begin $display("FAIL single exp=1 got=%0d", sh_single); done=1; #20; $finish; end

		if (FAULT_STALL) begin
			if (sh_stall >= 32'd7) begin
				$display("FAIL NEG expected miscount stall<7 got=%0d", sh_stall);
				done=1; #20; $finish;
			end
			$display("REPRO_OK NEG FAULT_MISCOUNT_STALL stall=%0d (injected 7)", sh_stall);
			$display("PASS ddr_perf_counters_tb FAULT_STALL=1");
		end else if (FAULT_BIN) begin
			// long lat must wrongly land in bin0; bin2 must stay 0
			if (sh_b2 != 32'd0) begin
				$display("FAIL NEG FAULT_MISBIN expected bin2=0 got=%0d", sh_b2);
				done=1; #20; $finish;
			end
			if (sh_b0 != 32'd2) begin
				$display("FAIL NEG FAULT_MISBIN expected bin0=2 got=%0d", sh_b0);
				done=1; #20; $finish;
			end
			$display("REPRO_OK NEG FAULT_MISBIN_LAT bin0=%0d bin2=%0d", sh_b0, sh_b2);
			$display("PASS ddr_perf_counters_tb FAULT_BIN=1");
		end else begin
			if (sh_stall < 32'd7) begin
				$display("FAIL stall exp>=7 got=%0d", sh_stall);
				done=1; #20; $finish;
			end
			// lat ~3 → bin0; lat ~20 → bin2
			if (sh_b0 != 32'd1) begin $display("FAIL bin0 exp=1 got=%0d", sh_b0); done=1; #20; $finish; end
			if (sh_b2 != 32'd1) begin $display("FAIL bin2 exp=1 got=%0d", sh_b2); done=1; #20; $finish; end
			if (sh_b1 != 32'd0 || sh_b3 != 32'd0 || sh_b4 != 32'd0 || sh_b5 != 32'd0) begin
				$display("FAIL unexpected bins b1=%0d b3=%0d b4=%0d b5=%0d", sh_b1, sh_b3, sh_b4, sh_b5);
				done=1; #20; $finish;
			end
			$display("PASS POS beats wr=16 rd=5 stall=%0d lat_n=2 bin0=1 bin2=1 burst_sum=5 single=1",
				sh_stall);
			$display("PASS ddr_perf_counters_tb FAULT=0");
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
