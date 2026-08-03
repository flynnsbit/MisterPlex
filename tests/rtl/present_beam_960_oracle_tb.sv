`timescale 1ps/1ps
// Beam oracle: fps_milli + true_de raster with *exact* whole-frame accounting.
// Parent defect: prior RTGEOM used de_pix lower-bound only (mid-line stop OK'd wrong totals).
// Pattern (w-scaler): line_w min..max == W..W and de_pix == W*H*frames (equality).
//
// FAULT_DROP_ONE_PER_LINE (red twin): score DE with last active pixel dropped each line.
// Exact checks must FAIL — proves oracle catches the 959×540 / store_id class.
`default_nettype none
module present_beam_960_oracle_tb;
	localparam int CLK_PS = 25000; // 20 MHz
	reg clk = 0;
	always #(CLK_PS/2) clk = ~clk;

	// ---------- timing pack (math SoT) ----------
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

	// ---------- fixed 960×540 @564 beam ----------
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
	reg use_rt_v = 1'b1;
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

	// ---------- runtime geom (reprogrammed between cases) ----------
	reg reset_rt = 1;
	reg use_g = 1'b1;
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

	// =====================================================================
	// Whole-frame scoreboard helpers (shared pattern)
	// armed after first frame_start; stop at target_frames completed.
	// line_min/max over complete lines only; de_pix only inside armed window.
	// =====================================================================
	// Fixed beam scoreboard
	integer f_line_w, f_line_min, f_line_max, f_lines, f_pix, f_done, f_armed;
	reg f_fs_d, f_in_de_d;
	integer f_hs_w, f_hs_max, f_hs_pulses, f_vs_w, f_vs_max;
	reg f_hs_d, f_vs_d;

	// V705 scoreboard
	integer v_line_w, v_line_min, v_line_max, v_lines, v_pix, v_done, v_armed;
	reg v_fs_d, v_in_de_d;

	// Runtime scoreboard
	integer r_line_w, r_line_min, r_line_max, r_lines, r_pix, r_done, r_armed;
	reg r_fs_d, r_in_de_d;
	integer r_want_w, r_want_h, r_want_frames;

	// DE sample with optional red-twin drop of last active pixel on each line
	function automatic bit de_sample;
		input bit de_raw;
		input [10:0] hc_i;
		input [10:0] hde_i;
		begin
`ifdef FAULT_DROP_ONE_PER_LINE
			// Drop last content pixel each line (959-of-960 / 319-of-320 class).
			de_sample = de_raw && (hc_i + 11'd1 != hde_i);
`else
			de_sample = de_raw;
`endif
		end
	endfunction

	// ---- fixed path always ----
	wire f_de_raw = ce && !hb && !vb;
	wire f_de = de_sample(f_de_raw, hc, hde_act);

	always @(posedge clk) begin
		if (reset) begin
			f_line_w = 0; f_line_min = 32'h7fff_ffff; f_line_max = 0;
			f_lines = 0; f_pix = 0; f_done = 0; f_armed = 0;
			f_fs_d = 0; f_in_de_d = 0;
			f_hs_w = 0; f_hs_max = 0; f_hs_pulses = 0; f_vs_w = 0; f_vs_max = 0;
			f_hs_d = 0; f_vs_d = 0;
		end else if (ce) begin
			// arm on first frame_start; each subsequent fstart completes a frame
			if (fstart && !f_fs_d) begin
				if (!f_armed)
					f_armed = 1;
				else
					f_done = f_done + 1;
			end
			f_fs_d = fstart;

			if (f_armed && f_done < 2) begin
				if (f_de) begin
					f_pix = f_pix + 1;
					f_line_w = f_line_w + 1;
				end
				// end of active run (DE falling)
				if (f_in_de_d && !f_de) begin
					if (f_line_w < f_line_min) f_line_min = f_line_w;
					if (f_line_w > f_line_max) f_line_max = f_line_w;
					f_lines = f_lines + 1;
					f_line_w = 0;
				end
			end
			f_in_de_d = f_de;

			// sync widths (informational + hs exact)
			if (hs) f_hs_w = f_hs_w + 1;
			if (f_hs_d && !hs) begin
				if (f_hs_w > f_hs_max) f_hs_max = f_hs_w;
				f_hs_pulses = f_hs_pulses + 1;
				f_hs_w = 0;
			end
			if (vs) f_vs_w = f_vs_w + 1;
			if (f_vs_d && !vs) begin
				if (f_vs_w > f_vs_max) f_vs_max = f_vs_w;
				f_vs_w = 0;
			end
			f_hs_d = hs; f_vs_d = vs;
		end
	end

	// ---- V705 ----
	wire v_de_raw = ce705 && !hb705 && !vb705;
	wire v_de = de_sample(v_de_raw, hc705, hde705);

	always @(posedge clk) begin
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
				if (v_de) begin
					v_pix = v_pix + 1;
					v_line_w = v_line_w + 1;
				end
				if (v_in_de_d && !v_de) begin
					if (v_line_w < v_line_min) v_line_min = v_line_w;
					if (v_line_w > v_line_max) v_line_max = v_line_w;
					v_lines = v_lines + 1;
					v_line_w = 0;
				end
			end
			v_in_de_d = v_de;
		end
	end

	// ---- runtime ----
	wire r_de_raw = cert && !hbrt && !vbrt;
	wire r_de = de_sample(r_de_raw, hcrt, hde_rt);

	always @(posedge clk) begin
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
				if (r_de) begin
					r_pix = r_pix + 1;
					r_line_w = r_line_w + 1;
				end
				if (r_in_de_d && !r_de) begin
					if (r_line_w < r_line_min) r_line_min = r_line_w;
					if (r_line_w > r_line_max) r_line_max = r_line_w;
					r_lines = r_lines + 1;
					r_line_w = 0;
				end
			end
			r_in_de_d = r_de;
		end
	end

	task automatic check_exact;
		input string tag;
		input integer w, h, frames_done, pix, lines, lmin, lmax;
		integer exp_pix, exp_lines;
		begin
			exp_pix = w * h * frames_done;
			exp_lines = h * frames_done;
			$display("%s exact w=%0d h=%0d frames=%0d pix=%0d exp_pix=%0d lines=%0d exp_lines=%0d line=%0d..%0d",
				tag, w, h, frames_done, pix, exp_pix, lines, exp_lines, lmin, lmax);
			if (frames_done < 1) begin
				$display("FAIL %s frames_done=%0d", tag, frames_done); $fatal(1);
			end
			if (lmin != w || lmax != w) begin
				$display("FAIL %s line_acc=%0d..%0d want %0d..%0d", tag, lmin, lmax, w, w);
				$fatal(1);
			end
			if (lines != exp_lines) begin
				$display("FAIL %s lines=%0d exp=%0d", tag, lines, exp_lines); $fatal(1);
			end
			if (pix != exp_pix) begin
				$display("FAIL %s pix=%0d exp=%0d (drop/dup class)", tag, pix, exp_pix);
				$fatal(1);
			end
			$display("OK %s exact pix=%0d line_acc=%0d..%0d frames=%0d", tag, pix, lmin, lmax, frames_done);
		end
	endtask

	task automatic run_rtgeom;
		input integer w, h, ht, vt, nframes;
		integer guard, max_clks;
		begin
			rthde = 11'(w);
			rtvact = 11'(h);
			rtht = 11'(ht);
			rtvt = 11'(vt);
			r_want_w = w;
			r_want_h = h;
			r_want_frames = nframes;
			use_g = 1'b1;
			reset_rt = 1;
			repeat (12) @(posedge clk);
			reset_rt = 0;
			max_clks = ht * vt * (nframes + 2) + 5000;
			guard = 0;
			while (r_done < nframes && guard < max_clks) begin
				@(posedge clk);
				guard = guard + 1;
			end
			#1;
			if (r_done < nframes) begin
				$display("FAIL RTGEOM %0dx%0d timeout done=%0d", w, h, r_done); $fatal(1);
			end
			if (hde_rt != 11'(w) || vact_rt != 11'(h) || htot_rt != 11'(ht) || vtotrt != 11'(vt)) begin
				$display("FAIL RTGEOM latch w=%0d h=%0d ht=%0d vt=%0d got %0d %0d %0d %0d",
					w, h, ht, vt, hde_rt, vact_rt, htot_rt, vtotrt);
				$fatal(1);
			end
			check_exact($sformatf("RTGEOM_%0dx%0d", w, h),
				w, h, r_done, r_pix, r_lines, r_line_min, r_line_max);
		end
	endtask

	initial begin
`ifdef FAULT_DROP_ONE_PER_LINE
		$display("RED_TWIN FAULT_DROP_ONE_PER_LINE active — exact checks must FAIL");
`endif
		// ===== fixed 960×540 / 1182×564 — exactly 2 whole frames =====
		repeat (20) @(posedge clk);
		reset = 0;
		begin : wait_fixed
			integer g;
			g = 0;
			while (f_done < 2 && g < 1182*564*4) begin
				@(posedge clk); g = g + 1;
			end
		end
		#1;
		$display("TIMING h_de=%0d h_tot=%0d v_act=%0d v_tot=%0d hss=%0d hse=%0d vss=%0d vse=%0d",
			h_de, h_tot, v_act, v_tot, hss, hse, vss, vse);
		$display("FPS fps_milli=%0d fps24_milli=%0d mode30=%0d", fps_milli, fps_milli_24, mode30);
		$display("RASTER_FIXED frames=%0d pix=%0d lines=%0d line=%0d..%0d hs_max=%0d vs_max=%0d vtot=%0d",
			f_done, f_pix, f_lines, f_line_min, f_line_max, f_hs_max, f_vs_max, vtot_act);

		if (h_de !== 12'd960 || h_tot !== 12'd1182 || v_act !== 12'd540 || v_tot !== 12'd564)
			begin $display("FAIL timing geometry"); $fatal(1); end
		if (hss !== 12'd992 || hse !== 12'd1056 || vss !== 12'd548 || vse !== 12'd554)
			begin $display("FAIL sync constants"); $fatal(1); end
		if (fps_milli !== 16'd30000)
			begin $display("FAIL fps_eff_milli=%0d want 30000", fps_milli); $fatal(1); end
		if (fps_milli_24 < 16'd23997 || fps_milli_24 > 16'd23998)
			begin $display("FAIL fps24_milli=%0d", fps_milli_24); $fatal(1); end
		if (!mode30) begin $display("FAIL mode30"); $fatal(1); end
		if (vtot_act != 11'd564) begin $display("FAIL vtot_act"); $fatal(1); end
		if (hde_act != 11'd960 || vact_act != 11'd540 || htot_act != 11'd1182)
			begin $display("FAIL latched fixed geom"); $fatal(1); end
		if (f_hs_max != 64) begin $display("FAIL hs_w_max=%0d", f_hs_max); $fatal(1); end
		if (f_vs_max < 1182 * 5) begin $display("FAIL vs_w_max=%0d", f_vs_max); $fatal(1); end
		check_exact("FIXED_960x540", 960, 540, f_done, f_pix, f_lines, f_line_min, f_line_max);

		// ===== V705 — exactly 2 whole frames =====
		reset705 = 1;
		repeat (10) @(posedge clk);
		reset705 = 0;
		begin : wait705
			integer g;
			g = 0;
			while (v_done < 2 && g < 1182*705*4) begin
				@(posedge clk); g = g + 1;
			end
		end
		#1;
		$display("V705 frames=%0d pix=%0d lines=%0d line=%0d..%0d vtot=%0d",
			v_done, v_pix, v_lines, v_line_min, v_line_max, vtot705);
		if (vtot705 != 11'd705) begin $display("FAIL vtot705=%0d", vtot705); $fatal(1); end
		check_exact("V705_960x540", 960, 540, v_done, v_pix, v_lines, v_line_min, v_line_max);
		$display("OK V705 beam no-stall true_de=960x540 vtot=705 exact");

		// ===== runtime PMS ladder geometries (exact) =====
		// 320×240 SD delivery, 640×360 motion rung, 960×540 detail rung
		run_rtgeom(320, 240, 800, 400, 2);
		run_rtgeom(640, 360, 1000, 500, 2);
		run_rtgeom(960, 540, 1182, 564, 2);

`ifdef FAULT_DROP_ONE_PER_LINE
		// Must not reach here — check_exact should have $fatal'd.
		$display("FAIL RED_TWIN: exact checks did not catch drop-one-per-line");
		$fatal(1);
`else
		$display("PASS present_beam_960_oracle true_de=1 fps_milli=%0d fps24_milli=%0d de=960x540 frames=%0d v705=1 rtgeom_exact=1",
			fps_milli, fps_milli_24, f_done);
		$finish;
`endif
	end
endmodule
`default_nettype wire
