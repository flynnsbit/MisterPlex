// Cosim: present_npx_path beat conservation (N-wide sys → 1-wide pix).
`default_nettype none

module present_npx_path_tb #(
	parameter int PX_PER_CLK = 4,
	parameter bit RED_DROP_READ = 1'b0
);
	reg clk_sys = 1'b0;
	reg clk_pix = 1'b0;
	// ~20 MHz sys, ~74 MHz pix (period ratio ~1:3.7) — pix faster so FIFO drains
	always #25 clk_sys = ~clk_sys; // 20 MHz
	always #7  clk_pix = ~clk_pix; // ~71.4 MHz

	reg reset_sys = 1'b1;
	reg reset_pix = 1'b1;

	reg in_valid = 1'b0;
	reg [PX_PER_CLK*8-1:0] in_r = '0, in_g = '0, in_b = '0;
	reg [PX_PER_CLK-1:0] in_lane_valid = '0;

	wire out_ce;
	wire [7:0] out_r, out_g, out_b;
	wire wr_full, wr_almost_full, rd_empty;
	wire rd_underrun;
	wire in_ready;

	present_npx_path #(
		.PX_PER_CLK(PX_PER_CLK),
		.FIFO_AW(5)
	) dut (
		.clk_sys(clk_sys),
		.reset_sys(reset_sys),
		.clk_pix(clk_pix),
		.reset_pix(reset_pix),
		.in_valid(in_valid),
		.in_r(in_r),
		.in_g(in_g),
		.in_b(in_b),
		.in_lane_valid(in_lane_valid),
		.in_ready(in_ready),
		.out_ce(out_ce),
		.out_r(out_r),
		.out_g(out_g),
		.out_b(out_b),
		.wr_full(wr_full),
		.wr_almost_full(wr_almost_full),
		.rd_underrun(rd_underrun),
		.rd_empty(rd_empty)
	);

	integer wr_beats;
	integer rd_beats;
	integer errors;
	integer g;
	integer li;
	integer timeout;

	task automatic sys_tick;
		begin
			@(posedge clk_sys);
			#1;
		end
	endtask

	// Push one group of PX_PER_CLK pixels with distinct R = base+lane
	task automatic push_group(input integer base);
		begin
			in_r = '0;
			in_g = '0;
			in_b = '0;
			in_lane_valid = {PX_PER_CLK{1'b1}};
			for (li = 0; li < PX_PER_CLK; li = li + 1) begin
				in_r[li*8 +: 8] = base[7:0] + li[7:0];
				in_g[li*8 +: 8] = 8'h10;
				in_b[li*8 +: 8] = 8'h20;
			end
			in_valid = 1'b1;
			sys_tick;
			in_valid = 1'b0;
			wr_beats = wr_beats + PX_PER_CLK;
			// Allow expander to drain into FIFO (up to PPC cycles + slack)
			repeat (PX_PER_CLK + 4) sys_tick;
		end
	endtask

	// Pix-side monitor
	always @(posedge clk_pix) begin
		if (!reset_pix && out_ce && !RED_DROP_READ)
			rd_beats = rd_beats + 1;
	end

	initial begin
		wr_beats = 0;
		rd_beats = 0;
		errors = 0;
		repeat (8) sys_tick;
		reset_sys = 1'b0;
		reset_pix = 1'b0;
		repeat (8) sys_tick;

		// 8 groups × PPC pixels
		for (g = 0; g < 8; g = g + 1)
			push_group(g * 16);

		// Wait for pix domain to drain
		timeout = 0;
		while (rd_beats < wr_beats && timeout < 5000) begin
			sys_tick;
			timeout = timeout + 1;
		end

		if (RED_DROP_READ) begin
			// Force a conservation fail claim: we never counted reads
			if (rd_beats != 0) begin
				$display("FAIL RED setup: rd_beats should stay 0");
				$fatal(1);
			end
			if (wr_beats == 0) begin
				$display("FAIL RED setup: no writes");
				$fatal(1);
			end
			$display("PASS present_npx_path RED: beat mismatch wr=%0d rd=%0d",
				wr_beats, rd_beats);
			$fatal(1);
		end

		if (rd_beats != wr_beats) begin
			$display("FAIL beat conservation wr=%0d rd=%0d", wr_beats, rd_beats);
			$fatal(1);
		end
		$display("PASS present_npx_path beat_ok wr=rd=%0d ppc=%0d", wr_beats, PX_PER_CLK);
		$finish;
	end
endmodule

`default_nettype wire
