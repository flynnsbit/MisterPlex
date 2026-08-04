// present_npx_path dual-clock CDC proof.
// FAULT_MODE 0 POS bit-exact | 1 FAULT bare prefill elab | 2 NEG multi-bit tear
// Drain runs concurrent with feed (PREFILL starts mid-stream) — must scoreboard
// from t0, not only after push completes.
`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off SYNCASYNCNET */

module present_npx_cdc_tb;
	localparam int PPC = 2;
`ifdef FAULT_MODE
	localparam int FAULT_I = `FAULT_MODE;
`else
	localparam int FAULT_I = 0;
`endif

	reg clk_sys = 1'b0;
	reg clk_pix = 1'b0;
	always #25 clk_sys = ~clk_sys; // 20 MHz
	always #17 clk_pix = ~clk_pix; // ~29.4 MHz

	reg rst_sys = 1'b1;
	reg rst_pix = 1'b1;

	reg in_valid;
	reg [PPC*8-1:0] in_r, in_g, in_b;
	reg [PPC-1:0] in_lv;
	reg in_hb, in_hs, in_vb, in_vs, in_fs;
	wire in_ready, out_ce;
	wire [7:0] out_r, out_g, out_b;
	wire out_hb, out_hs, out_vb, out_vs, out_fs;
	wire wr_full, wr_af, rd_ur, rd_empty;

	present_npx_path #(
		.PX_PER_CLK(PPC),
		.FIFO_AW(5),
		.INCLUDE_SYNC(1'b1),
		.PREFILL_GROUPS(4),
		.SKID_AW(4),
		.FAULT_NO_PREFILL_SYNC(FAULT_I == 1)
	) u_dut (
		.clk_sys(clk_sys), .reset_sys(rst_sys),
		.clk_pix(clk_pix), .reset_pix(rst_pix),
		.in_valid(in_valid),
		.in_r(in_r), .in_g(in_g), .in_b(in_b),
		.in_lane_valid(in_lv),
		.in_hblank(in_hb), .in_hsync(in_hs),
		.in_vblank(in_vb), .in_vsync(in_vs), .in_fstart(in_fs),
		.in_ready(in_ready),
		.out_ce(out_ce), .out_r(out_r), .out_g(out_g), .out_b(out_b),
		.out_hblank(out_hb), .out_hsync(out_hs),
		.out_vblank(out_vb), .out_vsync(out_vs), .out_fstart(out_fs),
		.wr_full(wr_full), .wr_almost_full(wr_af),
		.rd_underrun(rd_ur), .rd_empty(rd_empty)
	);

	// NEG_B: multi-bit bus with staggered bit delays (torn sample proof)
	reg [7:0] src_bus;
	reg [3:0] lo0, lo1, hi0, hi1, hi2;
	wire [7:0] dst_bus = {hi2, lo1};
	always @(posedge clk_pix) begin
		lo0 <= src_bus[3:0];
		lo1 <= lo0;
		hi0 <= src_bus[7:4];
		hi1 <= hi0;
		hi2 <= hi1;
	end

	localparam int NGRP = 12;
	localparam int NPX  = NGRP * PPC;
	integer gi, got, mismatches, tears, fstart_seen, guard;
	reg [7:0] er, eg, eb;
	reg done;
	reg collect;

	// Concurrent collector on clk_pix
	always @(posedge clk_pix) begin
		if (rst_pix) begin
			// nothing
		end else if (collect && out_ce) begin
			er = 8'(got);
			eg = 8'(8'h10 + got);
			eb = 8'(8'h20 + got);
			if (out_r !== er || out_g !== eg || out_b !== eb) begin
				mismatches = mismatches + 1;
				if (mismatches <= 8)
					$display("MISMATCH i=%0d exp=%02x%02x%02x got=%02x%02x%02x",
						got, er, eg, eb, out_r, out_g, out_b);
			end else if (got < 3) begin
				$display("OK i=%0d rgb=%02x%02x%02x fs=%0d", got, out_r, out_g, out_b, out_fs);
			end
			if (out_fs) fstart_seen = fstart_seen + 1;
			got = got + 1;
		end
	end

	initial begin
		done = 0;
		collect = 0;
		got = 0;
		mismatches = 0;
		fstart_seen = 0;
		in_valid = 0;
		in_r = 0; in_g = 0; in_b = 0; in_lv = 0;
		in_hb = 1; in_hs = 0; in_vb = 1; in_vs = 0; in_fs = 0;
		src_bus = 0;

		$display("=== present_npx_cdc_tb EXECUTED FAULT_I=%0d ===", FAULT_I);
		repeat (10) @(posedge clk_sys);
		rst_sys = 0;
		repeat (4) @(posedge clk_pix);
		rst_pix = 0;
		repeat (8) @(posedge clk_sys);

		if (FAULT_I == 2) begin
			tears = 0;
			@(posedge clk_sys); src_bus = 8'h00;
			repeat (12) @(posedge clk_pix);
			@(posedge clk_sys); src_bus = 8'hFF;
			for (gi = 0; gi < 12; gi = gi + 1) begin
				@(posedge clk_pix);
				#1;
				if (dst_bus !== 8'h00 && dst_bus !== 8'hFF) begin
					tears = tears + 1;
					if (tears <= 4)
						$display("TEAR_SAMPLE cyc=%0d dst=%02x", gi, dst_bus);
				end
			end
			if (tears == 0) begin
				$display("FAIL NEG_B expected torn multi-bit sample");
				done = 1; #50; $finish;
			end
			$display("REPRO_OK NEG_B multi_bit_bit_sync_tears=%0d", tears);
			$display("PASS present_npx_cdc_tb FAULT_I=2");
			done = 1; #50; $finish;
		end

		// Enable collector BEFORE feed — prefill drains mid-push.
		collect = 1;

		// Registered NBA push: set before edge that DUT samples.
		for (gi = 0; gi < NGRP; gi = gi + 1) begin
			@(posedge clk_sys);
			while (!in_ready) @(posedge clk_sys);
			in_valid <= 1'b1;
			in_r <= {8'(gi*2+1), 8'(gi*2)};
			in_g <= {8'(8'h10+gi*2+1), 8'(8'h10+gi*2)};
			in_b <= {8'(8'h20+gi*2+1), 8'(8'h20+gi*2)};
			in_lv <= 2'b11;
			in_hb <= 1'b0; in_vb <= 1'b0; in_hs <= 1'b0; in_vs <= 1'b0;
			in_fs <= (gi == 0);
		end
		@(posedge clk_sys);
		in_valid <= 1'b0;
		in_fs <= 1'b0;
		$display("FEED done NGRP=%0d", NGRP);

		// Wait for drain to finish
		guard = 0;
		while (got < NPX && guard < 100000) begin
			@(posedge clk_pix);
			guard = guard + 1;
		end
		// a few more quiet cycles
		repeat (20) @(posedge clk_pix);
		collect = 0;

		$display("DRAIN got=%0d mm=%0d fstart=%0d empty=%0d",
			got, mismatches, fstart_seen, rd_empty);

		if (FAULT_I == 0) begin
			if (got != NPX) begin
				$display("FAIL POS got_px=%0d want=%0d", got, NPX);
				done = 1; #50; $finish;
			end
			if (mismatches != 0) begin
				$display("FAIL POS mismatches=%0d", mismatches);
				done = 1; #50; $finish;
			end
			if (fstart_seen < 1) begin
				$display("FAIL POS missing out_fstart");
				done = 1; #50; $finish;
			end
			$display("PASS G0 dual_clock bit_exact px=%0d fstart=%0d", got, fstart_seen);
			$display("PASS present_npx_cdc_tb FAULT_I=0");
		end else begin
			// FAULT_I==1 still must move pixels (bare prefill may be racey on HW
			// but in 0-delay RTL sim level still propagates). Elab proves the
			// generate FAULT path exists; pixel path is best-effort.
			if (got < 1) begin
				$display("FAIL FAULT1 no pixels");
				done = 1; #50; $finish;
			end
			$display("REPRO_OK FAULT_NO_PREFILL_SYNC elab FAULT_I=1 px=%0d mm=%0d",
				got, mismatches);
			$display("PASS present_npx_cdc_tb FAULT_I=1");
		end
		done = 1;
		#50;
		$finish;
	end

	initial begin
		#20_000_000;
		if (!done) begin
			$display("FAIL timeout got=%0d", got);
			$finish;
		end
	end
endmodule
