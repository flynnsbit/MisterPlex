// Full-raster no-gap cadence: wide-group FIFO sustains 1280×720 @ PIX24 clocks.
// GREEN: beat conservation, zero underrun after start.
// RED (RED_STARVE): producer hole → rd_underrun must fire.
`default_nettype none

module present_npx_full_raster_tb #(
	parameter int PX_PER_CLK = 2,
	parameter int H_ACTIVE   = 1280,
	parameter int V_ACTIVE   = 720,
	parameter bit RED_STARVE = 1'b0
);
	localparam int PIXELS = H_ACTIVE * V_ACTIVE;
	localparam int GROUPS = PIXELS / PX_PER_CLK;

	reg clk_sys = 1'b0;
	reg clk_pix = 1'b0;
	always #25 clk_sys = ~clk_sys;
	always #16.835 clk_pix = ~clk_pix;

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

	integer wr_px, rd_px, ur_count, g, li, stall, timeout, exp_r;
	integer acc, hole_left;
	reg hole_done;
	// F_PIX/F_SYS scaled integers (29.7/20 → 297/200)
	localparam int F_PIX = 297;
	localparam int F_SYS = 200;
	localparam int THRESH = F_SYS * PX_PER_CLK;

	task automatic sys_tick;
		begin
			@(posedge clk_sys);
			#1;
		end
	endtask

	always @(posedge clk_pix) begin
		if (!reset_pix) begin
			if (out_ce) begin
				rd_px = rd_px + 1;
				exp_r = (rd_px - 1) & 255;
				if (out_r !== exp_r[7:0] || out_g !== 8'hC3 || out_b !== 8'h3C) begin
					$display("FAIL pixel @rd=%0d r=%02x exp=%02x", rd_px, out_r, exp_r[7:0]);
					$fatal(1);
				end
			end
			if (rd_underrun)
				ur_count = ur_count + 1;
		end
	end

	initial begin
		wr_px = 0;
		rd_px = 0;
		ur_count = 0;
		acc = 0;
		g = 0;
		hole_done = 1'b0;
		if (PIXELS % PX_PER_CLK != 0) begin
			$display("FAIL PIXELS %% PPC");
			$fatal(1);
		end
		repeat (20) sys_tick;
		reset_sys = 1'b0;
		reset_pix = 1'b0;
		repeat (20) sys_tick;

		// RED: feed 64 groups, one-shot 8000-cycle hole, prove rd_underrun.
		// GREEN: full 1280×720 no-gap (beat conservation, ur==0).
		hole_left = 0;
		hole_done = 1'b0;
		while (g < GROUPS) begin
			if (RED_STARVE && g == 64 && !hole_done) begin
				hole_left = 8000;
				hole_done = 1'b1;
				while (hole_left > 0) begin
					in_valid = 1'b0;
					sys_tick;
					hole_left = hole_left - 1;
				end
				repeat (2000) sys_tick;
				if (ur_count == 0) begin
					$display("FAIL RED expected rd_underrun>0");
					$fatal(1);
				end
				$display("PASS present_npx_full_raster RED ur=%0d", ur_count);
				$finish;
			end
			stall = 0;
			while (!in_ready && stall < 100000) begin
				sys_tick;
				stall = stall + 1;
			end
			if (!in_ready) begin
				$display("FAIL in_ready stuck g=%0d", g);
				$fatal(1);
			end
			acc = acc + F_PIX;
			if (acc >= THRESH) begin
				acc = acc - THRESH;
				in_r = '0;
				in_g = '0;
				in_b = '0;
				in_lane_valid = {PX_PER_CLK{1'b1}};
				for (li = 0; li < PX_PER_CLK; li = li + 1) begin
					in_r[li*8 +: 8] = (wr_px + li) & 255;
					in_g[li*8 +: 8] = 8'hC3;
					in_b[li*8 +: 8] = 8'h3C;
				end
				in_hb = 1'b0;
				in_vb = 1'b0;
				in_hs = 1'b0;
				in_vs = (g == 0);
				in_valid = 1'b1;
				sys_tick;
				in_valid = 1'b0;
				wr_px = wr_px + PX_PER_CLK;
				g = g + 1;
			end else begin
				in_valid = 1'b0;
				sys_tick;
			end
		end

		timeout = 0;
		while (rd_px < wr_px && timeout < 5_000_000) begin
			sys_tick;
			timeout = timeout + 1;
		end

		if (wr_px != PIXELS) begin
			$display("FAIL wr_px=%0d want %0d", wr_px, PIXELS);
			$fatal(1);
		end
		if (rd_px != wr_px) begin
			$display("FAIL beat wr=%0d rd=%0d", wr_px, rd_px);
			$fatal(1);
		end
		if (ur_count != 0) begin
			$display("FAIL unexpected ur=%0d", ur_count);
			$fatal(1);
		end
		$display("PASS present_npx_full_raster pixels=%0d ur=0 ppc=%0d", rd_px, PX_PER_CLK);
		$finish;
	end
endmodule

`default_nettype wire
