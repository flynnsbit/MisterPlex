`timescale 1ps/1ps
// Beam oracle: exact whole-frame DE + B13 runtime ladder + per-geom red twin.
// Equality: pix == W*H*frames; line_acc == W..W (not lower-bound).
// Red: fault_drop_one clears last DE pixel each line → must FAIL equality.
`default_nettype none
module present_beam_960_oracle_tb;
	localparam int CLK_PS = 25000; // 20 MHz
	reg clk = 0;
	always #(CLK_PS/2) clk = ~clk;

	reg fault_drop_one = 1'b0; // red twin (runtime, not compile ifdef)

	// ---------- timing pack ----------
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

	// ---------- fixed max-tier beam (params only; still latches) ----------
	reg reset = 1;
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

	// ---------- film V705 ----------
	reg reset705 = 1;
	wire ce705, hb705, hs705, vb705, vs705, fs705;
	wire [10:0] hc705, vc705, vtot705, hde705, htot705, vact705;
	present_beam_content_de #(
		.H_DE(960), .V_ACTIVE(540), .H_TOTAL(1182), .V_TOTAL(564),
		.H_SYNC_S(992), .H_SYNC_E(1056), .V_SYNC_S(548), .V_SYNC_E(554)
	) beam705 (
		.clk(clk), .reset(reset705),
		.use_rt_vtotal(1'b1), .rt_vtotal(11'd705),
		.use_rt_geom(1'b0), .rt_h_de(11'd0), .rt_h_total(11'd0), .rt_v_active(11'd0),
		.ce_pix(ce705), .HBlank(hb705), .HSync(hs705), .VBlank(vb705), .VSync(vs705),
		.frame_start(fs705), .hc_out(hc705), .vc_out(vc705),
		.vtot_active(vtot705), .hde_active(hde705), .htot_active(htot705),
		.vact_active(vact705)
	);

	// ---------- runtime geom (B13 product path) ----------
	reg reset_rt = 1;
	reg use_g = 1'b1;
	reg [10:0] rthde = 11'd320, rtht = 11'd1182, rtvact = 11'd240, rtvt = 11'd564;
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

	// scoreboards
	integer f_line_w, f_line_min, f_line_max, f_lines, f_pix, f_done, f_armed;
	reg f_fs_d, f_in_de_d;
	integer f_hs_w, f_hs_max, f_vs_w, f_vs_max;
	reg f_hs_d, f_vs_d;

	integer v_line_w, v_line_min, v_line_max, v_lines, v_pix, v_done, v_armed;
	reg v_fs_d, v_in_de_d;

	integer r_line_w, r_line_min, r_line_max, r_lines, r_pix, r_done, r_armed;
	reg r_fs_d, r_in_de_d;
	integer r_want_frames;

	function automatic bit de_sample;
		input bit de_raw;
		input [10:0] hc_i;
		input [10:0] hde_i;
		begin
			if (fault_drop_one)
				de_sample = de_raw && (hc_i + 11'd1 != hde_i);
			else
				de_sample = de_raw;
		end
	endfunction

	wire f_de = de_sample(ce && !hb && !vb, hc, hde_act);
	wire v_de = de_sample(ce705 && !hb705 && !vb705, hc705, hde705);
	wire r_de = de_sample(cert && !hbrt && !vbrt, hcrt, hde_rt);

	always @(posedge clk) begin
		if (reset) begin
			f_line_w = 0; f_line_min = 32'h7fff_ffff; f_line_max = 0;
			f_lines = 0; f_pix = 0; f_done = 0; f_armed = 0;
			f_fs_d = 0; f_in_de_d = 0;
			f_hs_w = 0; f_hs_max = 0; f_vs_w = 0; f_vs_max = 0;
			f_hs_d = 0; f_vs_d = 0;
		end else if (ce) begin
			if (fstart && !f_fs_d) begin
				if (!f_armed) f_armed = 1;
				else f_done = f_done + 1;
			end
			f_fs_d = fstart;
			if (f_armed && f_done < 2) begin
				if (f_de) begin f_pix = f_pix + 1; f_line_w = f_line_w + 1; end
				if (f_in_de_d && !f_de) begin
					if (f_line_w < f_line_min) f_line_min = f_line_w;
					if (f_line_w > f_line_max) f_line_max = f_line_w;
					f_lines = f_lines + 1; f_line_w = 0;
				end
			end
			f_in_de_d = f_de;
			if (hs) f_hs_w = f_hs_w + 1;
			if (f_hs_d && !hs) begin
				if (f_hs_w > f_hs_max) f_hs_max = f_hs_w;
				f_hs_w = 0;
			end
			if (vs) f_vs_w = f_vs_w + 1;
			if (f_vs_d && !vs) begin
				if (f_vs_w > f_vs_max) f_vs_max = f_vs_w;
				f_vs_w = 0;
			end
			f_hs_d = hs; f_vs_d = vs;
		end

		if (reset705) begin
			v_line_w = 0; v_line_min = 32'h7fff_ffff; v_line_max = 0;
			v_lines = 0; v_pix = 0; v_done = 0; v_armed = 0;
			v_fs_d = 0; v_in_de_d = 0;
		end else if (ce705) begin
			if (fs705 && !v_fs_d) begin
				if (!v_armed) v_armed = 1;
				else v_done = v_done + 1;
			end
			v_fs_d = fs705;
			if (v_armed && v_done < 2) begin
				if (v_de) begin v_pix = v_pix + 1; v_line_w = v_line_w + 1; end
				if (v_in_de_d && !v_de) begin
					if (v_line_w < v_line_min) v_line_min = v_line_w;
					if (v_line_w > v_line_max) v_line_max = v_line_w;
					v_lines = v_lines + 1; v_line_w = 0;
				end
			end
			v_in_de_d = v_de;
		end

		if (reset_rt) begin
			r_line_w = 0; r_line_min = 32'h7fff_ffff; r_line_max = 0;
			r_lines = 0; r_pix = 0; r_done = 0; r_armed = 0;
			r_fs_d = 0; r_in_de_d = 0;
		end else if (cert) begin
			if (fsrt && !r_fs_d) begin
				if (!r_armed) r_armed = 1;
				else r_done = r_done + 1;
			end
			r_fs_d = fsrt;
			if (r_armed && r_done < r_want_frames) begin
				if (r_de) begin r_pix = r_pix + 1; r_line_w = r_line_w + 1; end
				if (r_in_de_d && !r_de) begin
					if (r_line_w < r_line_min) r_line_min = r_line_w;
					if (r_line_w > r_line_max) r_line_max = r_line_w;
					r_lines = r_lines + 1; r_line_w = 0;
				end
			end
			r_in_de_d = r_de;
		end
	end

	// Returns 1 if exact; prints FAIL lines when not.
	function automatic int exact_ok;
		input string tag;
		input integer w, h, frames_done, pix, lines, lmin, lmax;
		integer exp_pix, exp_lines;
		begin
			exp_pix = w * h * frames_done;
			exp_lines = h * frames_done;
			$display("%s exact w=%0d h=%0d frames=%0d pix=%0d exp_pix=%0d lines=%0d exp_lines=%0d line_acc=%0d..%0d",
				tag, w, h, frames_done, pix, exp_pix, lines, exp_lines, lmin, lmax);
			exact_ok = 1;
			if (frames_done < 1) begin
				$display("FAIL %s frames_done=%0d", tag, frames_done); exact_ok = 0;
			end
			if (lmin != w || lmax != w) begin
				$display("FAIL %s line_acc=%0d..%0d want %0d..%0d", tag, lmin, lmax, w, w);
				exact_ok = 0;
			end
			if (lines != exp_lines) begin
				$display("FAIL %s lines=%0d exp=%0d", tag, lines, exp_lines); exact_ok = 0;
			end
			if (pix != exp_pix) begin
				$display("FAIL %s pix=%0d exp=%0d (drop/dup class)", tag, pix, exp_pix);
				exact_ok = 0;
			end
			if (exact_ok)
				$display("OK %s exact pix=%0d line_acc=%0d..%0d frames=%0d", tag, pix, lmin, lmax, frames_done);
		end
	endfunction

	task automatic run_rtgeom;
		input integer w, h, ht, vt, nframes;
		input bit expect_pass;
		integer guard, max_clks, ok;
		begin
			rthde = 11'(w);
			rtvact = 11'(h);
			rtht = 11'(ht);
			rtvt = 11'(vt);
			r_want_frames = nframes;
			use_g = 1'b1;
			reset_rt = 1;
			repeat (12) @(posedge clk);
			reset_rt = 0;
			max_clks = ht * vt * (nframes + 2) + 8000;
			guard = 0;
			while (r_done < nframes && guard < max_clks) begin
				@(posedge clk);
				guard = guard + 1;
			end
			#1;
			if (r_done < nframes) begin
				$display("FAIL RTGEOM %0dx%0d timeout done=%0d", w, h, r_done);
				if (expect_pass) $fatal(1);
			end
			if (expect_pass) begin
				if (hde_rt != 11'(w) || vact_rt != 11'(h) || htot_rt != 11'(ht) || vtotrt != 11'(vt)) begin
					$display("FAIL RTGEOM latch"); $fatal(1);
				end
			end
			ok = exact_ok($sformatf("RTGEOM_%0dx%0d", w, h),
				w, h, r_done, r_pix, r_lines, r_line_min, r_line_max);
			if (expect_pass && !ok) $fatal(1);
			if (!expect_pass && ok) begin
				$display("FAIL RED %0dx%0d: drop-one not caught", w, h); $fatal(1);
			end
			if (!expect_pass && !ok)
				$display("OK RED RTGEOM_%0dx%0d caught drop-one-per-line", w, h);
		end
	endtask

	initial begin
		fault_drop_one = 1'b0;

		// ===== fixed 960×540 / 1182×564 — 2 whole frames =====
		repeat (20) @(posedge clk);
		reset = 0;
		begin : wait_fixed
			integer g; g = 0;
			while (f_done < 2 && g < 1182*564*4) begin @(posedge clk); g = g + 1; end
		end
		#1;
		$display("TIMING h_de=%0d h_tot=%0d v_act=%0d v_tot=%0d", h_de, h_tot, v_act, v_tot);
		$display("FPS fps_milli=%0d fps24_milli=%0d mode30=%0d", fps_milli, fps_milli_24, mode30);
		if (fps_milli !== 16'd30000) begin $display("FAIL fps"); $fatal(1); end
		if (fps_milli_24 < 16'd23997 || fps_milli_24 > 16'd23998) begin $display("FAIL fps24"); $fatal(1); end
		if (f_hs_max != 64) begin $display("FAIL hs"); $fatal(1); end
		if (!exact_ok("FIXED_960x540", 960, 540, f_done, f_pix, f_lines, f_line_min, f_line_max))
			$fatal(1);

		// ===== V705 exact =====
		reset705 = 1; repeat (10) @(posedge clk); reset705 = 0;
		begin : wait705
			integer g; g = 0;
			while (v_done < 2 && g < 1182*705*4) begin @(posedge clk); g = g + 1; end
		end
		#1;
		if (vtot705 != 11'd705) begin $display("FAIL vtot705"); $fatal(1); end
		if (!exact_ok("V705_960x540", 960, 540, v_done, v_pix, v_lines, v_line_min, v_line_max))
			$fatal(1);
		$display("OK V705 beam no-stall true_de=960x540 vtot=705 exact");
		// STA note (not a pass): timing closure UNKNOWN until Plex.sta.rpt
		$display("STA_ACK V705: sim exact OK; Fmax UNKNOWN until fit (prereg meet 20 MHz)");

		// ===== B13 runtime ladder (product totals 1182×564 @30) =====
		// Parent library: 320x240 SD, 624x480 dominant, 640x360 motion, 960x540 max
		run_rtgeom(320, 240, 1182, 564, 2, 1'b1);
		run_rtgeom(624, 480, 1182, 564, 2, 1'b1);
		run_rtgeom(640, 360, 1182, 564, 2, 1'b1);
		run_rtgeom(960, 540, 1182, 564, 2, 1'b1);

		// ===== RED twin per geometry: drop one pixel/line =====
		fault_drop_one = 1'b1;
		$display("RED_TWIN fault_drop_one per geometry");
		run_rtgeom(320, 240, 1182, 564, 2, 1'b0);
		run_rtgeom(624, 480, 1182, 564, 2, 1'b0);
		run_rtgeom(640, 360, 1182, 564, 2, 1'b0);
		run_rtgeom(960, 540, 1182, 564, 2, 1'b0);
		fault_drop_one = 1'b0;

		$display("PASS present_beam_960_oracle true_de=1 fps_milli=%0d b13_rtgeom_exact=1 red_per_geom=1",
			fps_milli);
		$finish;
	end
endmodule
`default_nettype wire
