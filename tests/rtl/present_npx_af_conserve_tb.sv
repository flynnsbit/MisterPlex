`timescale 1ps/1ps
// Forced consumer stall: producer fills against almost_full/skid; no drop.
// Counts wr accepted vs rd pixels after release.
`default_nettype none
module present_npx_af_conserve_tb;
	localparam int PPC = 2;
	reg clk_sys=0, clk_pix=0;
	always #25000 clk_sys=~clk_sys;
	always #16835 clk_pix=~clk_pix;
	reg reset_sys=1, reset_pix=1;
	reg stall_rd=1; // hold pix from popping after prefill by... we stall by
	// gating: use a wrapper — actually stall consumer by stopping clk_pix? 
	// Better: hold reset_pix longer while writing, then release.
	// Or: write many with rd side in reset.

	reg in_valid=0;
	reg [PPC*8-1:0] in_r=0, in_g=0, in_b=0;
	reg [PPC-1:0] in_lv=0;
	reg in_hb=1, in_hs=0, in_vb=1, in_vs=0;
	wire in_ready, out_ce, wr_full, wr_af, rd_ur, rd_empty;
	wire [7:0] out_r, out_g, out_b;
	wire out_hb, out_hs, out_vb, out_vs;

	present_npx_path #(
		.PX_PER_CLK(PPC), .FIFO_AW(4), // depth 16 — easier to fill
		.INCLUDE_SYNC(1), .PREFILL_GROUPS(4)
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

	integer wr_n, rd_n, af_seen_mid, af_at_low_free, cycles;
	// Probe almost_full stays 1 while filling near full (not only at exactly 4 free)
	integer af_true_beats, fill_phase;

	task automatic tick; begin @(posedge clk_sys); #1; end endtask

	always @(posedge clk_pix) begin
		if (!reset_pix && out_ce && !out_hb && !out_vb)
			rd_n = rd_n + 1;
	end

	initial begin
		wr_n=0; rd_n=0; af_seen_mid=0; af_at_low_free=0; af_true_beats=0; fill_phase=1;
		repeat (20) tick;
		reset_sys=0;
		// Keep pix in reset while filling — consumer stalled
		reset_pix=1;
		repeat (10) tick;

		// Push groups until blocked; encode id in R
		while (wr_n < 64) begin
			if (in_ready) begin
				in_r = {8'(wr_n+1), 8'(wr_n)}; // lane1, lane0
				in_g = {8'h11, 8'h11};
				in_b = {8'h22, 8'h22};
				in_lv = {PPC{1'b1}};
				in_hb = 0; in_vb = 0;
				in_valid = 1;
				tick;
				in_valid = 0;
				wr_n = wr_n + 1;
				if (wr_af) af_true_beats = af_true_beats + 1;
			end else begin
				// backpressured — almost_full or full should be visible in band
				if (!wr_af && !wr_full) begin
					// may happen briefly; count
					af_at_low_free = af_at_low_free + 1;
				end
				if (wr_af) af_seen_mid = af_seen_mid + 1;
				tick;
				// escape if stuck long
				if (af_seen_mid > 5000) break;
			end
		end
		fill_phase=0;
		if (af_true_beats < 2 && af_seen_mid < 2) begin
			$display("FAIL never saw almost_full while filling wr=%0d", wr_n);
			$fatal(1);
		end

		// Release consumer
		repeat (5) tick;
		reset_pix=0;
		cycles=0;
		while (rd_n < wr_n * PPC && cycles < 200000) begin
			tick;
			cycles=cycles+1;
		end
		repeat (1000) tick;

		if (rd_n != wr_n * PPC) begin
			$display("FAIL conserve wr_groups=%0d rd_px=%0d want %0d", wr_n, rd_n, wr_n*PPC);
			$fatal(1);
		end
		$display("PASS present_npx_af_conserve wr_g=%0d rd_px=%0d af_beats=%0d",
			wr_n, rd_n, af_true_beats + af_seen_mid);
		$finish;
	end
endmodule
`default_nettype wire
