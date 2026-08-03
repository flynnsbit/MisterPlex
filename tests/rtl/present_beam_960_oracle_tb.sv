`timescale 1ps/1ps
// Executable oracle: timing_960 fps_eff_milli + beam DE/sync/frame pulses.
// Catches 32-bit FPS overflow and constants-only (no raster) false claims.
`default_nettype none
module present_beam_960_oracle_tb;
	localparam int CLK_PS = 25000; // 20 MHz
	reg clk = 0;
	always #(CLK_PS/2) clk = ~clk;
	reg reset = 1;

	wire [11:0] h_de, h_tot, v_act, v_tot, hss, hse, vss, vse;
	wire [15:0] fps_milli;
	wire mode30, need_wf;
	present_video_timing_960 #(.MODE(0), .CLK_PIX_HZ(20_000_000)) u_t0 (
		.h_de(h_de), .h_total(h_tot), .v_active(v_act), .v_total(v_tot),
		.h_sync_s(hss), .h_sync_e(hse), .v_sync_s(vss), .v_sync_e(vse),
		.fps_eff_milli(fps_milli), .mode_30hz(mode30), .needs_wide_fifo(need_wf)
	);

	wire [15:0] fps_milli_24;
	present_video_timing_960 #(.MODE(2), .CLK_PIX_HZ(20_000_000)) u_t2 (
		.h_de(), .h_total(), .v_active(), .v_total(),
		.h_sync_s(), .h_sync_e(), .v_sync_s(), .v_sync_e(),
		.fps_eff_milli(fps_milli_24), .mode_30hz(), .needs_wide_fifo()
	);

	wire ce, hb, hs, vb, vs, fstart;
	wire [10:0] hc, vc, vtot_act;
	present_beam_content_de #(
		.H_DE(960), .V_ACTIVE(540), .H_TOTAL(1182), .V_TOTAL(564),
		.H_SYNC_S(992), .H_SYNC_E(1056), .V_SYNC_S(548), .V_SYNC_E(554)
	) beam (
		.clk(clk), .reset(reset),
		.use_rt_vtotal(1'b0), .rt_vtotal(11'd0),
		.ce_pix(ce), .HBlank(hb), .HSync(hs), .VBlank(vb), .VSync(vs),
		.frame_start(fstart), .hc_out(hc), .vc_out(vc), .vtot_active(vtot_act)
	);

	integer de_w_this, de_w_max, de_lines, de_pix, frames, clks;
	integer hs_w_this, hs_w_max, hs_pulses;
	integer vs_w_this, vs_w_max;
	reg hs_d, vs_d, fstart_d, vb_d;

	always @(posedge clk) begin
		if (reset) begin
			de_w_this = 0; de_w_max = 0; de_lines = 0; de_pix = 0;
			frames = 0; clks = 0;
			hs_w_this = 0; hs_w_max = 0; hs_pulses = 0;
			vs_w_this = 0; vs_w_max = 0;
			hs_d = 0; vs_d = 0; fstart_d = 0; vb_d = 1;
		end else if (ce) begin
			clks = clks + 1;
			// Active DE
			if (!hb && !vb) begin
				de_pix = de_pix + 1;
				de_w_this = de_w_this + 1;
			end else if (de_w_this != 0) begin
				if (de_w_this > de_w_max) de_w_max = de_w_this;
				if (de_w_this == 960) de_lines = de_lines + 1;
				de_w_this = 0;
			end
			// HS pulse width
			if (hs) hs_w_this = hs_w_this + 1;
			if (hs_d && !hs) begin
				if (hs_w_this > hs_w_max) hs_w_max = hs_w_this;
				hs_pulses = hs_pulses + 1;
				hs_w_this = 0;
			end
			// VS pulse width in clocks (not lines) — just ensure non-zero span
			if (vs) vs_w_this = vs_w_this + 1;
			if (vs_d && !vs) begin
				if (vs_w_this > vs_w_max) vs_w_max = vs_w_this;
				vs_w_this = 0;
			end
			if (fstart && !fstart_d)
				frames = frames + 1;
			hs_d = hs;
			vs_d = vs;
			fstart_d = fstart;
			vb_d = vb;
		end
	end

	initial begin
		repeat (20) @(posedge clk);
		reset = 0;
		// >2 full frames
		repeat (1182 * 564 * 2 + 8000) @(posedge clk);
		#1;

		$display("TIMING h_de=%0d h_tot=%0d v_act=%0d v_tot=%0d hss=%0d hse=%0d vss=%0d vse=%0d",
			h_de, h_tot, v_act, v_tot, hss, hse, vss, vse);
		$display("FPS fps_milli=%0d fps24_milli=%0d mode30=%0d", fps_milli, fps_milli_24, mode30);
		$display("RASTER de_w_max=%0d de_lines=%0d de_pix=%0d hs_w_max=%0d hs_pulses=%0d vs_w_max=%0d frames=%0d clks=%0d vtot_act=%0d",
			de_w_max, de_lines, de_pix, hs_w_max, hs_pulses, vs_w_max, frames, clks, vtot_act);

		if (h_de !== 12'd960 || h_tot !== 12'd1182 || v_act !== 12'd540 || v_tot !== 12'd564) begin
			$display("FAIL timing geometry"); $fatal(1);
		end
		if (hss !== 12'd992 || hse !== 12'd1056 || vss !== 12'd548 || vse !== 12'd554) begin
			$display("FAIL sync constants"); $fatal(1);
		end
		// Overflow would yield ~2884 or nonsense; correct trunc is 30000.
		if (fps_milli !== 16'd30000) begin
			$display("FAIL fps_eff_milli=%0d want 30000", fps_milli); $fatal(1);
		end
		// 20e9/(1389*600)=23997.6 → trunc 23997 (allow 23997..23998 tool variance)
		if (fps_milli_24 < 16'd23997 || fps_milli_24 > 16'd23998) begin
			$display("FAIL fps24_milli=%0d want 23997..23998", fps_milli_24); $fatal(1);
		end
		if (!mode30) begin $display("FAIL mode30"); $fatal(1); end
		if (de_w_max != 960) begin $display("FAIL de_w_max=%0d", de_w_max); $fatal(1); end
		if (de_lines < 1080) begin $display("FAIL de_lines=%0d", de_lines); $fatal(1); end
		if (de_pix < 960*540*2) begin $display("FAIL de_pix=%0d", de_pix); $fatal(1); end
		if (hs_w_max != 64) begin $display("FAIL hs_w_max=%0d want 64", hs_w_max); $fatal(1); end
		if (hs_pulses < 564*2 - 4) begin $display("FAIL hs_pulses=%0d", hs_pulses); $fatal(1); end
		if (vs_w_max < 1182 * 5) begin // ~6 lines * H_TOTAL
			$display("FAIL vs_w_max=%0d too small", vs_w_max); $fatal(1);
		end
		if (frames < 2) begin $display("FAIL frames=%0d", frames); $fatal(1); end
		if (vtot_act != 11'd564) begin $display("FAIL vtot_act=%0d", vtot_act); $fatal(1); end

		$display("PASS present_beam_960_oracle true_de=1 fps_milli=%0d fps24_milli=%0d de=960x540 frames=%0d",
			fps_milli, fps_milli_24, frames);
		$finish;
	end
endmodule
`default_nettype wire
