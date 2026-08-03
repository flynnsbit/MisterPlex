`timescale 1ps/1ps
// Forced consumer stall: freeze clk_pix while producer fills against AF/skid.
// Exact group/pixel conservation + sticky almost_full near full.
`default_nettype none
module present_npx_af_conserve_tb;
	localparam int PPC = 2;
	localparam int N_PUSH_MAX = 64;

	reg clk_sys = 0;
	reg clk_pix = 0;
	reg run_pix = 0;
	always #25000 clk_sys = ~clk_sys;
	always begin
		if (run_pix) begin
			#16835 clk_pix = ~clk_pix;
		end else begin
			#16835;
		end
	end

	reg reset_sys = 1, reset_pix = 1;
	reg in_valid = 0;
	reg [PPC*8-1:0] in_r = 0, in_g = 0, in_b = 0;
	reg [PPC-1:0] in_lv = 0;
	reg in_hb = 1, in_hs = 0, in_vb = 1, in_vs = 0;
	wire in_ready, out_ce, wr_full, wr_af, rd_ur, rd_empty;
	wire [7:0] out_r, out_g, out_b;
	wire out_hb, out_hs, out_vb, out_vs;

	present_npx_path #(
		.PX_PER_CLK(PPC),
		.FIFO_AW(4),
		.INCLUDE_SYNC(1),
		.PREFILL_GROUPS(4),
		.SKID_AW(4)
	) dut (
		.clk_sys(clk_sys), .reset_sys(reset_sys),
		.clk_pix(clk_pix), .reset_pix(reset_pix),
		.in_valid(in_valid), .in_r(in_r), .in_g(in_g), .in_b(in_b),
		.in_lane_valid(in_lv),
		.in_hblank(in_hb), .in_hsync(in_hs), .in_vblank(in_vb), .in_vsync(in_vs),
		.in_ready(in_ready),
		.out_ce(out_ce), .out_r(out_r), .out_g(out_g), .out_b(out_b),
		.out_hblank(out_hb), .out_hsync(out_hs), .out_vblank(out_vb), .out_vsync(out_vs),
		.wr_full(wr_full), .wr_almost_full(wr_af),
		.rd_underrun(rd_ur), .rd_empty(rd_empty)
	);

	integer wr_n, rd_n, af_seen, full_seen, blocked_no_af, cycles, stuck;
	integer exp_id, mism;

	task automatic tick; begin @(posedge clk_sys); #1; end endtask

	always @(posedge clk_pix) begin
		if (!reset_pix && out_ce && !out_hb && !out_vb) begin
			if (out_r !== exp_id[7:0])
				mism = mism + 1;
			rd_n = rd_n + 1;
			exp_id = exp_id + 1;
		end
	end

	initial begin
		wr_n = 0; rd_n = 0; af_seen = 0; full_seen = 0;
		blocked_no_af = 0; mism = 0; exp_id = 0; stuck = 0;
		repeat (20) tick;
		reset_sys = 0;
		reset_pix = 0;
		run_pix = 0;
		repeat (10) tick;

		// Fill until skid/FIFO saturated (in_ready stays low) or cap.
		while (wr_n < N_PUSH_MAX) begin
			if (in_ready) begin
				in_r = {8'(2*wr_n + 1), 8'(2*wr_n)};
				in_g = {8'hA5, 8'hA5};
				in_b = {8'h5A, 8'h5A};
				in_lv = {PPC{1'b1}};
				in_hb = 0; in_vb = 0; in_hs = 0; in_vs = 0;
				in_valid = 1;
				tick;
				in_valid = 0;
				wr_n = wr_n + 1;
				stuck = 0;
				if (wr_af) af_seen = af_seen + 1;
				if (wr_full) full_seen = full_seen + 1;
			end else begin
				if (!wr_af && !wr_full)
					blocked_no_af = blocked_no_af + 1;
				if (wr_af) af_seen = af_seen + 1;
				if (wr_full) full_seen = full_seen + 1;
				tick;
				stuck = stuck + 1;
				// Saturated: enough groups accepted and ready stayed low.
				if (wr_n >= 12 && stuck > 64)
					break;
			end
		end

		if (wr_n < 12) begin
			$display("FAIL too few groups under stall wr=%0d", wr_n);
			$fatal(1);
		end
		if (af_seen < 2) begin
			$display("FAIL never sticky almost_full af=%0d full=%0d wr=%0d",
				af_seen, full_seen, wr_n);
			$fatal(1);
		end
		if (blocked_no_af > 8) begin
			$display("FAIL blocked without AF/full count=%0d", blocked_no_af);
			$fatal(1);
		end

		run_pix = 1;
		cycles = 0;
		while (rd_n < wr_n * PPC && cycles < 500000) begin
			tick;
			cycles = cycles + 1;
		end
		repeat (2000) tick;

		if (rd_n != wr_n * PPC) begin
			$display("FAIL conserve wr_g=%0d rd_px=%0d want=%0d",
				wr_n, rd_n, wr_n * PPC);
			$fatal(1);
		end
		if (mism != 0) begin
			$display("FAIL id mismatch mism=%0d", mism);
			$fatal(1);
		end
		$display("PASS present_npx_af_conserve wr_g=%0d rd_px=%0d af=%0d full=%0d",
			wr_n, rd_n, af_seen, full_seen);
		$finish;
	end
endmodule
`default_nettype wire
