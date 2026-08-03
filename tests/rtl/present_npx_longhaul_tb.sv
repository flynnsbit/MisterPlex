// Long-haul CDC: producer lead + prefill + ±pix ppm + phase.
// Equal average rates underrun under drift; lead + backpressure must hold.
`timescale 1ps/1ps
`default_nettype none

module present_npx_longhaul_tb #(
	parameter int PX_PER_CLK = 2,
	parameter int H_DE = 1280,
	parameter int H_TOTAL = 1650,
	parameter int V_ACTIVE = 16,
	parameter int V_TOTAL = 20,
	parameter int PREFILL = 16,
	// Nominal pix half-period ps = 16835 (29.7 MHz). PPM_OFF shifts it.
	parameter int PPM_OFF = 0,     // e.g. +1000 or -1000
	parameter int PHASE_PS = 0,    // ns start delay for pix clk
	parameter int FRAMES = 4
);
	localparam int PPC = PX_PER_CLK;
	// half_ps = 16835 * (1e6 + ppm) / 1e6 ≈ 16835 + 16835*ppm/1e6
	localparam int HALF_NOM = 16835;
	localparam int HALF_PS = HALF_NOM + (HALF_NOM * PPM_OFF) / 1000000;

	// Producer lead ~1000 ppm via Bresenham integers (2973/2000 vs 2970/2000)
	localparam int F_PIX = 2973; // lead
	localparam int F_SYS = 2000;
	localparam int THRESH = F_SYS * PPC;

	reg clk_sys = 1'b0;
	reg clk_pix = 1'b0;
	always #25000 clk_sys = ~clk_sys;
	initial begin
		#(PHASE_PS * 1000);
		forever #(HALF_PS) clk_pix = ~clk_pix;
	end

	reg reset_sys = 1'b1;
	// separate pix reset release (mirrors product 2FF)
	reg r0 = 1'b1, r1 = 1'b1;
	always @(posedge clk_pix or posedge reset_sys) begin
		if (reset_sys) begin r0 <= 1'b1; r1 <= 1'b1; end
		else begin r0 <= 1'b0; r1 <= r0; end
	end
	wire reset_pix = r1;

	reg in_valid;
	reg [PPC*8-1:0] in_r, in_g, in_b;
	reg [PPC-1:0] in_lv;
	reg in_hb, in_hs, in_vb, in_vs;
	wire in_ready;
	wire out_ce, out_hb, out_hs, out_vb, out_vs, rd_ur, rd_empty;
	wire [7:0] out_r, out_g, out_b;
	wire wr_full, wr_af;

	present_npx_path #(
		.PX_PER_CLK(PPC),
		.FIFO_AW(6),
		.INCLUDE_SYNC(1'b1),
		.PREFILL_GROUPS(PREFILL)
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

	integer hc, vc, acc, frames, li, step, remain;
	integer ur_mid, act, hs_r;
	reg out_hs_d, active_run;

	task automatic sys_tick; begin @(posedge clk_sys); #1; end endtask

	always @(posedge clk_pix) begin
		if (!reset_pix) begin
			if (out_ce) begin
				active_run = 1'b1;
				if (!out_hb && !out_vb) act = act + 1;
				if (out_hs && !out_hs_d) hs_r = hs_r + 1;
				out_hs_d = out_hs;
			end
			if (rd_ur && active_run && frames < FRAMES)
				ur_mid = ur_mid + 1;
		end
	end

	initial begin
		in_valid = 0; in_r = 0; in_g = 0; in_b = 0; in_lv = 0;
		in_hb = 1; in_hs = 0; in_vb = 1; in_vs = 0;
		hc = 0; vc = 0; acc = 0; frames = 0;
		ur_mid = 0; act = 0; hs_r = 0; out_hs_d = 0; active_run = 0;
		repeat (40) sys_tick;
		reset_sys = 0;
		repeat (40) sys_tick;

		while (frames < FRAMES) begin
			acc = acc + F_PIX;
			if (in_ready && acc >= THRESH) begin
				acc = acc - THRESH;
				remain = H_TOTAL - hc;
				step = (remain >= PPC) ? PPC : remain;
				if (step <= 0) step = PPC;
				in_hb = (hc >= H_DE);
				in_vb = (vc >= V_ACTIVE);
				in_hs = (hc >= 1390) && (hc < 1430);
				in_vs = (vc >= V_TOTAL - 3) && (vc < V_TOTAL - 1);
				in_r = '0; in_g = '0; in_b = '0; in_lv = {PPC{1'b1}};
				for (li = 0; li < PPC; li = li + 1) begin
					if (li < step && (hc+li) < H_DE && vc < V_ACTIVE) begin
						in_r[li*8+:8] = (hc + li) & 255;
						in_g[li*8+:8] = vc[7:0];
						in_b[li*8+:8] = 8'h5A;
					end
				end
				in_valid = 1;
				sys_tick;
				in_valid = 0;
				if (hc + step >= H_TOTAL) begin
					hc = 0;
					if (vc + 1 >= V_TOTAL) begin
						vc = 0;
						frames = frames + 1;
					end else vc = vc + 1;
				end else hc = hc + step;
			end else begin
				in_valid = 0;
				sys_tick;
			end
		end
		active_run = 0;
		repeat (5000) sys_tick;

		if (ur_mid != 0) begin
			$display("FAIL longhaul ur=%0d ppm=%0d ph=%0d", ur_mid, PPM_OFF, PHASE_PS);
			$fatal(1);
		end
		if (act < (H_DE * V_ACTIVE * FRAMES) / 2) begin
			$display("FAIL longhaul act=%0d", act);
			$fatal(1);
		end
		$display("PASS present_npx_longhaul act=%0d ur=0 ppm=%0d ph=%0d frames=%0d half=%0d",
			act, PPM_OFF, PHASE_PS, FRAMES, HALF_PS);
		$finish;
	end
endmodule
`default_nettype wire
