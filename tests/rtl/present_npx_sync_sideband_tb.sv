// Dual-clock present_npx_path with INCLUDE_SYNC=1.
// Proves sync sideband survives async_fifo and matches RGB beat order.
`default_nettype none

module present_npx_sync_sideband_tb #(
	parameter int PX_PER_CLK = 2,
	parameter int N_GROUPS   = 512
);
	reg clk_sys = 1'b0;
	reg clk_pix = 1'b0;
	// 20 MHz sys, ~29.7 MHz pix (CEA PIX24 class periods)
	always #25 clk_sys = ~clk_sys;       // 20.0 MHz
	always #16.835 clk_pix = ~clk_pix;   // ~29.7 MHz

	reg reset_sys = 1'b1;
	reg reset_pix = 1'b1;

	reg in_valid = 1'b0;
	reg [PX_PER_CLK*8-1:0] in_r = '0, in_g = '0, in_b = '0;
	reg [PX_PER_CLK-1:0] in_lane_valid = '0;
	reg in_hb = 1'b0, in_hs = 1'b0, in_vb = 1'b0, in_vs = 1'b0;
	wire in_ready;

	wire out_ce;
	wire [7:0] out_r, out_g, out_b;
	wire out_hb, out_hs, out_vb, out_vs;
	wire wr_full, wr_almost_full, rd_empty, rd_underrun;

	present_npx_path #(
		.PX_PER_CLK(PX_PER_CLK),
		.FIFO_AW(6),
		.INCLUDE_SYNC(1'b1)
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
		.in_hblank(in_hb),
		.in_hsync(in_hs),
		.in_vblank(in_vb),
		.in_vsync(in_vs),
		.in_ready(in_ready),
		.out_ce(out_ce),
		.out_r(out_r),
		.out_g(out_g),
		.out_b(out_b),
		.out_hblank(out_hb),
		.out_hsync(out_hs),
		.out_vblank(out_vb),
		.out_vsync(out_vs),
		.wr_full(wr_full),
		.wr_almost_full(wr_almost_full),
		.rd_underrun(rd_underrun),
		.rd_empty(rd_empty)
	);

	typedef struct packed {
		logic [7:0] r;
		logic hb, hs, vb, vs;
	} exp_t;

	exp_t exp_q [$];
	integer wr_beats, rd_beats, errors, g, li, timeout, stall;
	exp_t got;

	task automatic sys_tick;
		begin
			@(posedge clk_sys);
			#1;
		end
	endtask

	always @(posedge clk_pix) begin
		if (!reset_pix && out_ce) begin
			rd_beats = rd_beats + 1;
			if (exp_q.size() == 0) begin
				errors = errors + 1;
				$display("FAIL unexpected pix with empty q");
			end else begin
				got = exp_q.pop_front();
				if (out_r !== got.r || out_g !== 8'hC3 || out_b !== 8'h3C ||
				    out_hb !== got.hb || out_hs !== got.hs ||
				    out_vb !== got.vb || out_vs !== got.vs) begin
					errors = errors + 1;
					$display("FAIL mismatch g r=%02x hb=%0d hs=%0d vb=%0d vs=%0d exp r=%02x hb=%0d hs=%0d",
						out_r, out_hb, out_hs, out_vb, out_vs,
						got.r, got.hb, got.hs);
				end
			end
		end
	end

	initial begin
		wr_beats = 0;
		rd_beats = 0;
		errors = 0;
		repeat (16) sys_tick;
		reset_sys = 1'b0;
		reset_pix = 1'b0;
		repeat (16) sys_tick;

		for (g = 0; g < N_GROUPS; g = g + 1) begin
			stall = 0;
			while (!in_ready && stall < 20000) begin
				sys_tick;
				stall = stall + 1;
			end
			if (!in_ready) begin
				$display("FAIL in_ready stuck g=%0d", g);
				$fatal(1);
			end

			// Rotate sync pattern per group (blank every 8th group).
			in_hb = (g[2:0] == 3'd7);
			in_hs = g[0];
			in_vb = (g[4:0] == 5'd31);
			in_vs = g[1];

			in_r = '0;
			in_g = '0;
			in_b = '0;
			in_lane_valid = {PX_PER_CLK{1'b1}};
			for (li = 0; li < PX_PER_CLK; li = li + 1) begin
				in_r[li*8 +: 8] = g[7:0] + li[7:0];
				in_g[li*8 +: 8] = 8'hC3;
				in_b[li*8 +: 8] = 8'h3C;
				got.r  = g[7:0] + li[7:0];
				got.hb = in_hb;
				got.hs = in_hs;
				got.vb = in_vb;
				got.vs = in_vs;
				exp_q.push_back(got);
			end
			in_valid = 1'b1;
			sys_tick;
			in_valid = 1'b0;
			wr_beats = wr_beats + PX_PER_CLK;
			if (g[3:0] == 4'd0)
				repeat (2) sys_tick;
		end

		timeout = 0;
		while ((rd_beats < wr_beats || exp_q.size() != 0) && timeout < 300000) begin
			sys_tick;
			timeout = timeout + 1;
		end

		if (rd_beats != wr_beats) begin
			$display("FAIL beat wr=%0d rd=%0d", wr_beats, rd_beats);
			$fatal(1);
		end
		if (exp_q.size() != 0) begin
			$display("FAIL residual q %0d", exp_q.size());
			$fatal(1);
		end
		if (errors != 0) begin
			$display("FAIL errors=%0d", errors);
			$fatal(1);
		end
		$display("PASS present_npx_sync_sideband wr=rd=%0d groups=%0d", wr_beats, N_GROUPS);
		$finish;
	end
endmodule

`default_nettype wire
