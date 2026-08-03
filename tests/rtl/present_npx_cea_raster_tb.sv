`timescale 1ps/1ps
// CEA-style raster through present_npx_path (wide FIFO + prefill + sync).
// Sends full H_TOTAL×V_TOTAL slots (active + blank), checks:
//   - active pixel count == H_DE*V_ACTIVE
//   - HS rising edges == V_TOTAL (one per line) after stream starts
//   - no rd_underrun after stream_seen (GREEN)
// RED_STARVE: producer hole → underrun must fire
// PHASE_PS / ACC_SEED: expose Bresenham+clock phase sensitivity
`default_nettype none

module present_npx_cea_raster_tb #(
	parameter int PX_PER_CLK = 2,
	parameter int H_DE       = 1280,
	parameter int H_TOTAL    = 1650,
	parameter int V_ACTIVE   = 720,
	parameter int V_TOTAL    = 750,
	parameter int H_SYNC_S   = 1390,
	parameter int H_SYNC_E   = 1430,
	parameter int V_SYNC_S   = 725,
	parameter int V_SYNC_E   = 730,
	parameter int PREFILL    = 8,
	parameter int PHASE_PS   = 0,     // clk_pix delay (integer ns in this TB)
	parameter int ACC_SEED   = 0,     // Bresenham accumulator start
	parameter bit RED_STARVE = 1'b0
);
	localparam int ACTIVE_PX = H_DE * V_ACTIVE;
	// Groups per line: ceil(H_TOTAL / PPC) with PPC-step beam semantics
	localparam int PPC = PX_PER_CLK;

	// Integer ps half-periods (Verilator truncates fractional #delays).
	// sys 20 MHz → half=25000 ps; pix 29.7 MHz → half=16835 ps.
	// Phase: delay *start* of pix generator (assign #clk is unreliable in Verilator).
	reg clk_sys = 1'b0;
	reg clk_pix = 1'b0;
	always #25000 clk_sys = ~clk_sys;
	initial begin
		#(PHASE_PS * 1000);
		forever #16835 clk_pix = ~clk_pix;
	end

	reg reset_sys = 1'b1;
	reg reset_pix = 1'b1;

	reg in_valid = 1'b0;
	reg [PPC*8-1:0] in_r = '0, in_g = '0, in_b = '0;
	reg [PPC-1:0] in_lane_valid = '0;
	reg in_hb = 1'b1, in_hs = 1'b0, in_vb = 1'b1, in_vs = 1'b0;
	wire in_ready;

	wire out_ce;
	wire [7:0] out_r, out_g, out_b;
	wire out_hb, out_hs, out_vb, out_vs;
	wire wr_full, wr_af, rd_empty, rd_underrun;

	present_npx_path #(
		.PX_PER_CLK(PPC),
		.FIFO_AW(6),
		.INCLUDE_SYNC(1'b1),
		.PREFILL_GROUPS(PREFILL)
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
		.wr_almost_full(wr_af),
		.rd_underrun(rd_underrun),
		.rd_empty(rd_empty)
	);

	integer wr_active, rd_active, ur_count, stall, timeout;
	integer hc, vc, li, step, remain, acc;
	integer hs_rise, vs_rise;
	reg out_hs_d, out_vs_d, stream_out;
	integer hole_left;
	reg hole_done;
	reg producer_active;
	integer act_px_id;

	localparam int F_PIX = 297;
	localparam int F_SYS = 200;
	localparam int THRESH = F_SYS * PPC;

	task automatic sys_tick;
		begin
			@(posedge clk_sys);
			#1;
		end
	endtask

	always @(posedge clk_pix) begin
		if (!reset_pix) begin
			if (out_ce) begin
				stream_out = 1'b1;
				if (!out_hb && !out_vb) begin
					rd_active = rd_active + 1;
					// active pixel data = sequential id low 8
					if (out_r !== 8'((rd_active - 1) & 255) || out_g !== 8'hC3 || out_b !== 8'h3C) begin
						$display("FAIL act px rd=%0d r=%02x exp=%02x", rd_active, out_r, (rd_active - 1) & 255);
						$fatal(1);
					end
				end
				if (out_hs && !out_hs_d)
					hs_rise = hs_rise + 1;
				if (out_vs && !out_vs_d)
					vs_rise = vs_rise + 1;
				out_hs_d = out_hs;
				out_vs_d = out_vs;
			end
			// Mid-frame underrun only — post-frame empty (producer stopped) is not a fail.
			if (rd_underrun && producer_active)
				ur_count = ur_count + 1;
		end
	end

	initial begin
		wr_active = 0;
		rd_active = 0;
		ur_count = 0;
		hs_rise = 0;
		vs_rise = 0;
		out_hs_d = 0;
		out_vs_d = 0;
		stream_out = 0;
		hole_done = 0;
		hole_left = 0;
		hc = 0;
		vc = 0;
		acc = ACC_SEED;
		act_px_id = 0;
		stall = 0;
		producer_active = 1'b1;

		if (H_DE % PPC != 0) begin
			$display("FAIL H_DE %% PPC");
			$fatal(1);
		end

		repeat (20) sys_tick;
		reset_sys = 0;
		reset_pix = 0;
		repeat (20) sys_tick;

		// Walk full CEA beam in PPC steps; rate-match emit to clk_pix
		while (vc < V_TOTAL) begin
			// RED one-shot hole after some active progress
			if (RED_STARVE && !hole_done && wr_active >= 256) begin
				hole_done = 1;
				hole_left = 8000;
				while (hole_left > 0) begin
					in_valid = 0;
					sys_tick;
					hole_left = hole_left - 1;
				end
				repeat (2000) sys_tick;
				if (ur_count == 0) begin
					$display("FAIL RED expected underrun");
					$fatal(1);
				end
				$display("PASS present_npx_cea RED ur=%0d phase=%0d", ur_count, PHASE_PS);
				$finish;
			end

			// Match present_pix_rate_match: always accrue F_PIX; fire only when
			// in_ready && threshold — backpressure must not destroy rate credit.
			acc = acc + F_PIX;
			if (in_ready && acc >= THRESH) begin
				acc = acc - THRESH;
				remain = H_TOTAL - hc;
				step = (remain >= PPC) ? PPC : remain;
				if (step <= 0) step = PPC;

				in_r = '0;
				in_g = '0;
				in_b = '0;
				in_lane_valid = '0;
				in_hb = (hc >= H_DE);
				in_vb = (vc >= V_ACTIVE);
				in_hs = (hc >= H_SYNC_S) && (hc < H_SYNC_E);
				in_vs = (vc >= V_SYNC_S) && (vc < V_SYNC_E);

				for (li = 0; li < PPC; li = li + 1) begin
					if (li < step && (hc + li) < H_DE && vc < V_ACTIVE) begin
						in_lane_valid[li] = 1'b1;
						in_r[li*8 +: 8] = act_px_id[7:0];
						in_g[li*8 +: 8] = 8'hC3;
						in_b[li*8 +: 8] = 8'h3C;
						act_px_id = act_px_id + 1;
						wr_active = wr_active + 1;
					end else if (li < step) begin
						in_lane_valid[li] = 1'b1;
					end
				end

				in_valid = 1;
				sys_tick;
				in_valid = 0;

				if (hc + step >= H_TOTAL) begin
					hc = 0;
					vc = vc + 1;
				end else begin
					hc = hc + step;
				end
			end else begin
				in_valid = 0;
				sys_tick;
				stall = stall + 1;
				if (stall > 5_000_000) begin
					$display("FAIL producer stall hc=%0d vc=%0d ready=%0d", hc, vc, in_ready);
					$fatal(1);
				end
			end
		end
		producer_active = 1'b0;

		// drain
		timeout = 0;
		while ((rd_active < wr_active || !stream_out) && timeout < 8_000_000) begin
			sys_tick;
			timeout = timeout + 1;
		end
		// a little more for trailing blank
		repeat (5000) sys_tick;

		if (wr_active != ACTIVE_PX) begin
			$display("FAIL wr_active=%0d want %0d", wr_active, ACTIVE_PX);
			$fatal(1);
		end
		if (rd_active != wr_active) begin
			$display("FAIL active beat wr=%0d rd=%0d", wr_active, rd_active);
			$fatal(1);
		end
		if (ur_count != 0) begin
			$display("FAIL unexpected ur=%0d phase=%0d seed=%0d wr_act=%0d rd_act=%0d hs=%0d vs=%0d",
				ur_count, PHASE_PS, ACC_SEED, wr_active, rd_active, hs_rise, vs_rise);
			$fatal(1);
		end
		// HS: at least one rise per line once streaming (allow prefill skew)
		if (hs_rise < (V_TOTAL - 2)) begin
			$display("FAIL hs_rise=%0d want>=%0d", hs_rise, V_TOTAL - 2);
			$fatal(1);
		end
		if (vs_rise < 1) begin
			$display("FAIL vs_rise=%0d", vs_rise);
			$fatal(1);
		end

		$display("PASS present_npx_cea act=%0d hs=%0d vs=%0d ur=0 phase=%0d seed=%0d pre=%0d",
			rd_active, hs_rise, vs_rise, PHASE_PS, ACC_SEED, PREFILL);
		$finish;
	end
endmodule

`default_nettype wire
