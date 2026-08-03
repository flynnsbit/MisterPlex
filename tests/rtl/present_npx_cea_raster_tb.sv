`timescale 1ps/1ps
// CEA raster via present_npx_path + real present_pix_rate_match.
// Continuous multi-frame producer. Frame-aware underrun window.
// Asserts H_TOTAL slots/line and HS width. PHASE_PS/PHASE_NS in nanoseconds
// under timescale 1ps/1ps (#(N*1000)).
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
	parameter int PHASE_NS   = 0,
	parameter int ACC_SEED   = 0,
	parameter bit RED_STARVE = 1'b0,
	parameter int NUM_FRAMES = 2,
	parameter int PHASE_PS   = -1
);
	localparam int PPC = PX_PER_CLK;
	localparam int HS_W = H_SYNC_E - H_SYNC_S;
	localparam int PHASE_USE_NS = (PHASE_PS >= 0) ? PHASE_PS : PHASE_NS;
	localparam int EXP_SLOTS = H_TOTAL * V_TOTAL * NUM_FRAMES;
	localparam int EXP_ACT = H_DE * V_ACTIVE * NUM_FRAMES;

	reg clk_sys = 1'b0;
	reg clk_pix = 1'b0;
	always #25000 clk_sys = ~clk_sys;
	initial begin
		if (PHASE_USE_NS > 0)
			#(PHASE_USE_NS * 1000);
		forever #16835 clk_pix = ~clk_pix;
	end

	reg reset_sys = 1'b1;
	reg reset_pix = 1'b1;

	reg in_valid = 1'b0;
	reg [PPC*8-1:0] in_r = '0, in_g = '0, in_b = '0;
	reg [PPC-1:0] in_lane_valid = '0;
	reg in_hb = 1'b1, in_hs = 1'b0, in_vb = 1'b1, in_vs = 1'b0;
	wire in_ready;
	wire rate_fire;

	present_pix_rate_match #(
		.F_SYS_HZ(20_000_000),
		.F_PIX_HZ(29_700_000),
		.PX_PER_CLK(PPC)
	) u_rate (
		.clk(clk_sys),
		.reset(reset_sys),
		.in_ready(in_ready),
		.fire(rate_fire)
	);

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

	integer wr_active, rd_active, ur_score, stall;
	integer hc, vc, frame_i, li, step, remain;
	integer hs_rise, vs_rise;
	integer line_slots, lines_ok, bad_line;
	integer hs_high_run, hs_width_seen, bad_hs_w;
	integer out_slots, exp_slots_rem;
	reg out_hs_d, out_vs_d, stream_out, scoring;
	integer hole_left;
	reg hole_done;
	integer act_px_id;
	reg producer_run;

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
				scoring = 1'b1;
				out_slots = out_slots + 1;
				if (exp_slots_rem > 0)
					exp_slots_rem = exp_slots_rem - 1;

				line_slots = line_slots + 1;
				if (line_slots == H_TOTAL) begin
					lines_ok = lines_ok + 1;
					line_slots = 0;
				end else if (line_slots > H_TOTAL) begin
					bad_line = bad_line + 1;
				end

				if (!out_hb && !out_vb) begin
					rd_active = rd_active + 1;
					if (out_r !== 8'((rd_active - 1) & 255) || out_g !== 8'hC3 || out_b !== 8'h3C) begin
						$display("FAIL act px rd=%0d r=%02x", rd_active, out_r);
						$fatal(1);
					end
				end
				if (out_hs && !out_hs_d)
					hs_rise = hs_rise + 1;
				if (out_vs && !out_vs_d)
					vs_rise = vs_rise + 1;

				if (out_hs)
					hs_high_run = hs_high_run + 1;
				else if (out_hs_d && hs_high_run > 0) begin
					if (hs_width_seen == 0)
						hs_width_seen = hs_high_run;
					if (hs_high_run != HS_W)
						bad_hs_w = bad_hs_w + 1;
					hs_high_run = 0;
				end

				out_hs_d = out_hs;
				out_vs_d = out_vs;
			end
			if (rd_underrun && scoring && (exp_slots_rem > 0))
				ur_score = ur_score + 1;
		end
	end

	initial begin
		wr_active = 0;
		rd_active = 0;
		ur_score = 0;
		hs_rise = 0;
		vs_rise = 0;
		out_hs_d = 0;
		out_vs_d = 0;
		stream_out = 0;
		scoring = 0;
		hole_done = 0;
		hole_left = 0;
		hc = 0;
		vc = 0;
		frame_i = 0;
		act_px_id = 0;
		stall = 0;
		producer_run = 1'b1;
		line_slots = 0;
		lines_ok = 0;
		bad_line = 0;
		hs_high_run = 0;
		hs_width_seen = 0;
		bad_hs_w = 0;
		out_slots = 0;
		exp_slots_rem = EXP_SLOTS;

		if (H_DE % PPC != 0 || H_TOTAL % PPC != 0) begin
			$display("FAIL geometry %% PPC");
			$fatal(1);
		end

		repeat (20 + (ACC_SEED % 50)) sys_tick;
		reset_sys = 0;
		reset_pix = 0;
		repeat (20) sys_tick;

		while (producer_run) begin
			if (RED_STARVE && !hole_done && wr_active >= 256) begin
				hole_done = 1;
				hole_left = 8000;
				while (hole_left > 0) begin
					in_valid = 0;
					sys_tick;
					hole_left = hole_left - 1;
				end
				repeat (2000) sys_tick;
				if (ur_score == 0) begin
					$display("FAIL RED expected underrun in score window");
					$fatal(1);
				end
				$display("PASS present_npx_cea RED ur=%0d phase_ns=%0d", ur_score, PHASE_USE_NS);
				$finish;
			end

			if (in_ready && rate_fire) begin
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
					if (vc + 1 >= V_TOTAL) begin
						vc = 0;
						frame_i = frame_i + 1;
						if (frame_i >= NUM_FRAMES)
							producer_run = 1'b0;
					end else begin
						vc = vc + 1;
					end
				end else begin
					hc = hc + step;
				end
			end else begin
				in_valid = 0;
				sys_tick;
				stall = stall + 1;
				if (stall > 5_000_000) begin
					$display("FAIL producer stall hc=%0d vc=%0d fr=%0d ready=%0d fire=%0d",
						hc, vc, frame_i, in_ready, rate_fire);
					$fatal(1);
				end
			end
		end

		stall = 0;
		while (exp_slots_rem > 0 && stall < 8_000_000) begin
			sys_tick;
			stall = stall + 1;
		end
		repeat (3000) sys_tick;

		if (wr_active != EXP_ACT) begin
			$display("FAIL wr_active=%0d want %0d", wr_active, EXP_ACT);
			$fatal(1);
		end
		if (rd_active != wr_active) begin
			$display("FAIL active beat wr=%0d rd=%0d", wr_active, rd_active);
			$fatal(1);
		end
		if (ur_score != 0) begin
			$display("FAIL ur_score=%0d phase_ns=%0d slots=%0d hs=%0d",
				ur_score, PHASE_USE_NS, out_slots, hs_rise);
			$fatal(1);
		end
		if (out_slots < EXP_SLOTS) begin
			$display("FAIL out_slots=%0d want>=%0d", out_slots, EXP_SLOTS);
			$fatal(1);
		end
		if (lines_ok < (V_TOTAL * NUM_FRAMES - 2)) begin
			$display("FAIL lines_ok=%0d bad_line=%0d", lines_ok, bad_line);
			$fatal(1);
		end
		if (bad_line != 0) begin
			$display("FAIL bad_line=%0d", bad_line);
			$fatal(1);
		end
		if (hs_rise < (V_TOTAL * NUM_FRAMES - 2)) begin
			$display("FAIL hs_rise=%0d", hs_rise);
			$fatal(1);
		end
		if (hs_width_seen != HS_W) begin
			$display("FAIL hs_width=%0d want %0d bad=%0d", hs_width_seen, HS_W, bad_hs_w);
			$fatal(1);
		end
		if (vs_rise < NUM_FRAMES) begin
			$display("FAIL vs_rise=%0d want>=%0d", vs_rise, NUM_FRAMES);
			$fatal(1);
		end

		$display("PASS present_npx_cea act=%0d slots=%0d lines=%0d hs=%0d hsw=%0d vs=%0d ur=0 phase_ns=%0d pre=%0d",
			rd_active, out_slots, lines_ok, hs_rise, hs_width_seen, vs_rise, PHASE_USE_NS, PREFILL);
		$finish;
	end
endmodule

`default_nettype wire
