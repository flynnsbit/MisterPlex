`timescale 1ps/1ps
// Executable oracle: timing_960 fps_eff_milli + beam DE/sync/frame pulses.
// Catches 32-bit FPS overflow and constants-only (no raster) false claims.
// Also: V_TOTAL=705 film latch + runtime H/V geom (PMS-delivered DE).
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
	wire [10:0] hc, vc, vtot_act, hde_act, htot_act, vact_act;
	present_beam_content_de #(
		.H_DE(960), .V_ACTIVE(540), .H_TOTAL(1182), .V_TOTAL(564),
		.H_SYNC_S(992), .H_SYNC_E(1056), .V_SYNC_S(548), .V_SYNC_E(554)
	) beam (
		.clk(clk), .reset(reset),
		.use_rt_vtotal(1'b0), .rt_vtotal(11'd0),
		.use_rt_geom(1'b0), .rt_h_de(11'd0), .rt_h_total(11'd0), .rt_v_active(11'd0),
		.ce_pix(ce), .HBlank(hb), .HSync(hs), .VBlank(vb), .VSync(vs),
		.frame_start(fstart), .hc_out(hc), .vc_out(vc),
		.vtot_active(vtot_act), .hde_active(hde_act), .htot_active(htot_act),
		.vact_active(vact_act)
	);

	// Film tier: fixed H, runtime V_TOTAL=705
	reg reset705 = 1;
	reg use_rt_v = 0;
	reg [10:0] rt_v = 11'd705;
	wire ce705, hb705, hs705, vb705, vs705, fs705;
	wire [10:0] hc705, vc705, vtot705, hde705, htot705, vact705;
	present_beam_content_de #(
		.H_DE(960), .V_ACTIVE(540), .H_TOTAL(1182), .V_TOTAL(564),
		.H_SYNC_S(992), .H_SYNC_E(1056), .V_SYNC_S(548), .V_SYNC_E(554)
	) beam705 (
		.clk(clk), .reset(reset705),
		.use_rt_vtotal(use_rt_v), .rt_vtotal(rt_v),
		.use_rt_geom(1'b0), .rt_h_de(11'd0), .rt_h_total(11'd0), .rt_v_active(11'd0),
		.ce_pix(ce705), .HBlank(hb705), .HSync(hs705), .VBlank(vb705), .VSync(vs705),
		.frame_start(fs705), .hc_out(hc705), .vc_out(vc705),
		.vtot_active(vtot705), .hde_active(hde705), .htot_active(htot705),
		.vact_active(vact705)
	);

	// Runtime geom: PMS-style 320x240 inside generous totals (ascal lifts DE)
	reg reset_rt = 1;
	reg use_g = 0;
	reg [10:0] rthde = 11'd320, rtht = 11'd800, rtvact = 11'd240, rtvt = 11'd400;
	wire cert, hbrt, hsrt, vbrt, vsrt, fsrt;
	wire [10:0] hcrt, vcrt, vtotrt, hde_rt, htot_rt, vact_rt;
	present_beam_content_de #(
		.H_DE(960), .V_ACTIVE(540), .H_TOTAL(1182), .V_TOTAL(564)
	) beam_rt (
		.clk(clk), .reset(reset_rt),
		.use_rt_vtotal(1'b1), .rt_vtotal(rtvt),
		.use_rt_geom(use_g), .rt_h_de(rthde), .rt_h_total(rtht), .rt_v_active(rtvact),
		.ce_pix(cert), .HBlank(hbrt), .HSync(hsrt), .VBlank(vbrt), .VSync(vsrt),
		.frame_start(fsrt), .hc_out(hcrt), .vc_out(vcrt),
		.vtot_active(vtotrt), .hde_active(hde_rt), .htot_active(htot_rt),
		.vact_active(vact_rt)
	);

	integer de_w_this, de_w_max, de_lines, de_pix, frames, clks;
	integer hs_w_this, hs_w_max, hs_pulses;
	integer vs_w_this, vs_w_max;
	reg hs_d, vs_d, fstart_d, vb_d;

	integer de705_w, de705_max, de705_lines, frames705, clks705;
	reg fs705_d;

	integer dert_w, dert_max, dert_lines, dert_pix, frames_rt;
	reg fsrt_d;

	always @(posedge clk) begin
		if (reset) begin
			de_w_this = 0; de_w_max = 0; de_lines = 0; de_pix = 0;
			frames = 0; clks = 0;
			hs_w_this = 0; hs_w_max = 0; hs_pulses = 0;
			vs_w_this = 0; vs_w_max = 0;
			hs_d = 0; vs_d = 0; fstart_d = 0; vb_d = 1;
		end else if (ce) begin
			clks = clks + 1;
			if (!hb && !vb) begin
				de_pix = de_pix + 1;
				de_w_this = de_w_this + 1;
			end else if (de_w_this != 0) begin
				if (de_w_this > de_w_max) de_w_max = de_w_this;
				if (de_w_this == 960) de_lines = de_lines + 1;
				de_w_this = 0;
			end
			if (hs) hs_w_this = hs_w_this + 1;
			if (hs_d && !hs) begin
				if (hs_w_this > hs_w_max) hs_w_max = hs_w_this;
				hs_pulses = hs_pulses + 1;
				hs_w_this = 0;
			end
			if (vs) vs_w_this = vs_w_this + 1;
			if (vs_d && !vs) begin
				if (vs_w_this > vs_w_max) vs_w_max = vs_w_this;
				vs_w_this = 0;
			end
			if (fstart && !fstart_d) frames = frames + 1;
			hs_d = hs; vs_d = vs; fstart_d = fstart; vb_d = vb;
		end

		if (reset705) begin
			de705_w = 0; de705_max = 0; de705_lines = 0; frames705 = 0; clks705 = 0;
			fs705_d = 0;
		end else if (ce705) begin
			clks705 = clks705 + 1;
			if (!hb705 && !vb705) de705_w = de705_w + 1;
			else if (de705_w != 0) begin
				if (de705_w > de705_max) de705_max = de705_w;
				if (de705_w == 960) de705_lines = de705_lines + 1;
				de705_w = 0;
			end
			if (fs705 && !fs705_d) frames705 = frames705 + 1;
			fs705_d = fs705;
		end

		if (reset_rt) begin
			dert_w = 0; dert_max = 0; dert_lines = 0; dert_pix = 0; frames_rt = 0;
			fsrt_d = 0;
		end else if (cert) begin
			if (!hbrt && !vbrt) begin
				dert_pix = dert_pix + 1;
				dert_w = dert_w + 1;
			end else if (dert_w != 0) begin
				if (dert_w > dert_max) dert_max = dert_w;
				if (dert_w == 320) dert_lines = dert_lines + 1;
				dert_w = 0;
			end
			if (fsrt && !fsrt_d) frames_rt = frames_rt + 1;
			fsrt_d = fsrt;
		end
	end

	initial begin
		// --- default 960x540 @564 ---
		repeat (20) @(posedge clk);
		reset = 0;
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
		if (fps_milli !== 16'd30000) begin
			$display("FAIL fps_eff_milli=%0d want 30000", fps_milli); $fatal(1);
		end
		if (fps_milli_24 < 16'd23997 || fps_milli_24 > 16'd23998) begin
			$display("FAIL fps24_milli=%0d want 23997..23998", fps_milli_24); $fatal(1);
		end
		if (!mode30) begin $display("FAIL mode30"); $fatal(1); end
		if (de_w_max != 960) begin $display("FAIL de_w_max=%0d", de_w_max); $fatal(1); end
		if (de_lines < 1080) begin $display("FAIL de_lines=%0d", de_lines); $fatal(1); end
		if (de_pix < 960*540*2) begin $display("FAIL de_pix=%0d", de_pix); $fatal(1); end
		if (hs_w_max != 64) begin $display("FAIL hs_w_max=%0d want 64", hs_w_max); $fatal(1); end
		if (hs_pulses < 564*2 - 4) begin $display("FAIL hs_pulses=%0d", hs_pulses); $fatal(1); end
		if (vs_w_max < 1182 * 5) begin
			$display("FAIL vs_w_max=%0d too small", vs_w_max); $fatal(1);
		end
		if (frames < 2) begin $display("FAIL frames=%0d", frames); $fatal(1); end
		if (vtot_act != 11'd564) begin $display("FAIL vtot_act=%0d", vtot_act); $fatal(1); end
		if (hde_act != 11'd960 || vact_act != 11'd540 || htot_act != 11'd1182) begin
			$display("FAIL latched geom hde=%0d vact=%0d htot=%0d", hde_act, vact_act, htot_act);
			$fatal(1);
		end

		// --- V705 film companion (STA class: same 20 MHz counters) ---
		use_rt_v = 1;
		rt_v = 11'd705;
		reset705 = 1;
		repeat (10) @(posedge clk);
		reset705 = 0;
		// >1.5 frames at 1182*705
		repeat (1182 * 705 + 1182 * 400) @(posedge clk);
		#1;
		$display("V705 de_max=%0d de_lines=%0d frames=%0d vtot=%0d clks=%0d",
			de705_max, de705_lines, frames705, vtot705, clks705);
		if (vtot705 != 11'd705) begin $display("FAIL vtot705=%0d", vtot705); $fatal(1); end
		if (de705_max != 960) begin $display("FAIL de705_max=%0d", de705_max); $fatal(1); end
		if (de705_lines < 540) begin $display("FAIL de705_lines=%0d", de705_lines); $fatal(1); end
		if (frames705 < 1) begin $display("FAIL frames705=%0d", frames705); $fatal(1); end
		// fps arithmetic (host): 20e6/(1182*705) * 1000
		// checked in shell; here prove beam completes frames without stall
		$display("OK V705 beam no-stall true_de=960x540 vtot=705");

		// --- runtime geom 320x240 (PMS does not upscale) ---
		use_g = 1;
		reset_rt = 1;
		repeat (10) @(posedge clk);
		reset_rt = 0;
		repeat (800 * 400 * 2 + 2000) @(posedge clk);
		#1;
		$display("RTGEOM hde=%0d htot=%0d vact=%0d vtot=%0d de_max=%0d de_lines=%0d de_pix=%0d frames=%0d",
			hde_rt, htot_rt, vact_rt, vtotrt, dert_max, dert_lines, dert_pix, frames_rt);
		if (hde_rt != 11'd320 || vact_rt != 11'd240 || htot_rt != 11'd800 || vtotrt != 11'd400) begin
			$display("FAIL rt latched geom"); $fatal(1);
		end
		if (dert_max != 320) begin $display("FAIL dert_max=%0d", dert_max); $fatal(1); end
		if (dert_lines < 480) begin $display("FAIL dert_lines=%0d", dert_lines); $fatal(1); end
		if (dert_pix < 320*240*2) begin $display("FAIL dert_pix=%0d", dert_pix); $fatal(1); end
		if (frames_rt < 2) begin $display("FAIL frames_rt=%0d", frames_rt); $fatal(1); end
		$display("OK runtime_geom 320x240 true_de=1");

		$display("PASS present_beam_960_oracle true_de=1 fps_milli=%0d fps24_milli=%0d de=960x540 frames=%0d v705=1 rtgeom=1",
			fps_milli, fps_milli_24, frames);
		$finish;
	end
endmodule
`default_nettype wire
