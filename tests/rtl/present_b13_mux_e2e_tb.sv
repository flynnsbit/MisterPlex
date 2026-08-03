`timescale 1ps/1ps
// B13 E2E: PRODUCT plex_present_geom_mux → beam (does not bypass mux).
// GREEN: PLXG live DE exact; idle → 960; native→legacy disable → 624 DE + geom_en=0
// RED FAULT_B8_FORCE_ALWAYS: pins 960 over live PLXG (collision #5)
// RED FAULT_B13_DISABLE_ISLAND: disable keeps 960 beam DE while geom_en=0 (island)
`default_nettype none
module present_b13_mux_e2e_tb;
	localparam int CLK_PS = 25000;
	reg clk = 0;
	always #(CLK_PS/2) clk = ~clk;
	reg reset = 1;

	reg        plxg_live_valid = 1'b0;
	reg        plxg_win_en = 1'b1;
	reg        plxg_geom_en = 1'b1;
	reg [10:0] plxg_cw = 11'd0, plxg_ch = 11'd0;

	wire [10:0] content_width, content_height;
	wire win_en, geom_en;
	wire [10:0] cx0, cy0, hde, vde, coded_w, coded_h, c_stride, dw, dh, px, py, cl, ct;
	wire [11:0] y_stride;
	plex_present_geom_mux u_mux (
		.content_res_640x480(1'b0),
		.plxg_live_valid(plxg_live_valid),
		.plxg_win_en(plxg_win_en),
		.plxg_geom_en(plxg_geom_en),
		.plxg_cw(plxg_cw), .plxg_ch(plxg_ch),
		.plxg_cx0(11'd0), .plxg_cy0(11'd0),
		.plxg_hde(plxg_cw), .plxg_vde(plxg_ch),
		.plxg_coded_w(plxg_cw), .plxg_coded_h(plxg_ch),
		.plxg_y_stride({1'b0, plxg_cw}), .plxg_c_stride(plxg_cw >> 1),
		.plxg_dw(plxg_cw), .plxg_dh(plxg_ch),
		.plxg_px(11'd0), .plxg_py(11'd0), .plxg_cl(11'd0), .plxg_ct(11'd0),
		.present_win_enable(win_en), .present_geom_enable(geom_en),
		.content_width(content_width), .content_height(content_height),
		.present_content_x0(cx0), .present_content_y0(cy0),
		.present_win_h_de(hde), .present_win_v_de(vde),
		.present_geom_coded_w(coded_w), .present_geom_coded_h(coded_h),
		.present_geom_y_stride(y_stride), .present_geom_chroma_stride(c_stride),
		.present_geom_display_w(dw), .present_geom_display_h(dh),
		.present_geom_present_x(px), .present_geom_present_y(py),
		.present_geom_crop_left(cl), .present_geom_crop_top(ct)
	);

	wire ce, hb, hs, vb, vs, fstart;
	wire [10:0] hc, vc, vtot_act, hde_act, htot_act, vact_act;
	// Mirror present_core clamp (0→960 idle) — product mux should not emit 0 on disable.
	wire [10:0] beam_hde = (content_width == 11'd0) ? 11'd960 :
		(content_width > 11'd960) ? 11'd960 : content_width;
	wire [10:0] beam_vact = (content_height == 11'd0) ? 11'd540 :
		(content_height > 11'd540) ? 11'd540 : content_height;
	present_beam_content_de #(
		.H_DE(960), .V_ACTIVE(540), .H_TOTAL(1182), .V_TOTAL(564)
	) beam (
		.clk(clk), .reset(reset),
		.use_rt_vtotal(1'b1), .rt_vtotal(11'd564),
		.use_rt_geom(1'b1),
		.rt_h_de(beam_hde), .rt_h_total(11'd1182), .rt_v_active(beam_vact), .rt_de_apply(1'b1),
		.ce_pix(ce), .HBlank(hb), .HSync(hs), .VBlank(vb), .VSync(vs),
		.frame_start(fstart), .hc_out(hc), .vc_out(vc),
		.vtot_active(vtot_act), .hde_active(hde_act), .htot_active(htot_act),
		.vact_active(vact_act)
	);

	integer line_w, line_min, line_max, lines, pix, done, armed;
	reg fs_d, in_de_d;
	integer want_frames;
	wire de = ce && !hb && !vb;

	always @(posedge clk) begin
		if (reset) begin
			line_w = 0; line_min = 32'h7fff_ffff; line_max = 0;
			lines = 0; pix = 0; done = 0; armed = 0;
			fs_d = 0; in_de_d = 0;
		end else if (ce) begin
			if (fstart && !fs_d) begin
				if (armed == 0) armed = 1;
				else done = done + 1;
			end
			fs_d = fstart;
			if (armed != 0 && done < want_frames) begin
				if (de) begin pix = pix + 1; line_w = line_w + 1; end
				if (in_de_d && !de) begin
					if (line_w < line_min) line_min = line_w;
					if (line_w > line_max) line_max = line_w;
					lines = lines + 1; line_w = 0;
				end
			end
			in_de_d = de;
		end
	end

	task automatic run_live;
		input integer w, h;
		input bit expect_plxg_de; // 1=DE==w×h; 0=expect forced 960 (FAULT)
		integer guard, exp_pix;
		begin
			want_frames = 2;
			plxg_cw = 11'(w); plxg_ch = 11'(h);
			plxg_live_valid = 1'b1;
			plxg_win_en = 1'b1;
			plxg_geom_en = 1'b1;
			reset = 1;
			repeat (12) @(posedge clk);
			reset = 0;
			guard = 0;
			while (done < 2 && guard < 1182*564*4) begin
				@(posedge clk); guard = guard + 1;
			end
			#1;
			$display("E2E mux_out=%0dx%0d beam=%0dx%0d geom_en=%0d frames=%0d pix=%0d line_acc=%0d..%0d",
				content_width, content_height, hde_act, vact_act, geom_en,
				done, pix, line_min, line_max);
			if (expect_plxg_de) begin
				exp_pix = w * h * 2;
				if (content_width !== 11'(w) || content_height !== 11'(h)) begin
					$display("FAIL mux did not pass PLXG %0dx%0d (got %0dx%0d) — collision #5?",
						w, h, content_width, content_height);
					$fatal(1);
				end
				if (hde_act !== 11'(w) || vact_act !== 11'(h) ||
					line_min != w || line_max != w || pix != exp_pix || done < 2) begin
					$display("FAIL beam DE not exact %0dx%0d", w, h); $fatal(1);
				end
				$display("OK E2E mux→beam DE=%0dx%0d exact pix=%0d line_acc=%0d..%0d",
					w, h, pix, line_min, line_max);
			end else begin
				if (content_width !== 11'd960 || content_height !== 11'd540 ||
					hde_act !== 11'd960 || vact_act !== 11'd540) begin
					$display("FAIL FAULT_B8_FORCE_ALWAYS did not pin 960 (mux=%0dx%0d beam=%0dx%0d)",
						content_width, content_height, hde_act, vact_act);
					$fatal(1);
				end
				if (line_min != 960 || line_max != 960 || pix != 960*540*2) begin
					$display("FAIL forced 960 DE exactness"); $fatal(1);
				end
				$display("OK RED FAULT force pins 960x540 over PLXG %0dx%0d (collision #5 class)",
					w, h);
			end
		end
	endtask

	// Native 960 content → explicit disable (cw=ch=0, geom=0) → legacy 624 DE extent.
	task automatic run_native_to_legacy_exit;
		input bit expect_island; // 1 = RED island (960 DE + geom off)
		integer guard, exp_pix;
		begin
			// Phase A: native content-bearing 960
			want_frames = 1;
			plxg_live_valid = 1'b1;
			plxg_win_en = 1'b1;
			plxg_geom_en = 1'b1;
			plxg_cw = 11'd960; plxg_ch = 11'd540;
			reset = 1; repeat (12) @(posedge clk); reset = 0;
			guard = 0;
			while (done < 1 && guard < 1182*564*4) begin @(posedge clk); guard = guard + 1; end
			#1;
			if (content_width !== 11'd960 || !geom_en) begin
				$display("FAIL native phase not 960+geom (cw=%0d geom=%0d)", content_width, geom_en);
				$fatal(1);
			end
			$display("OK native phase mux DE=960 geom_en=1");

			// Phase B: mode exit — owned disable
			want_frames = 2;
			// reset counters via reset for clean DE measure
			plxg_cw = 11'd0; plxg_ch = 11'd0;
			plxg_win_en = 1'b0;
			plxg_geom_en = 1'b0;
			plxg_live_valid = 1'b1; // still owned
			reset = 1; repeat (12) @(posedge clk); reset = 0;
			guard = 0;
			while (done < 2 && guard < 1182*564*4) begin @(posedge clk); guard = guard + 1; end
			#1;
			$display("EXIT mux=%0dx%0d beam=%0dx%0d geom_en=%0d win_en=%0d pix=%0d line=%0d..%0d",
				content_width, content_height, hde_act, vact_act, geom_en, win_en,
				pix, line_min, line_max);

			// Store side: geom must be off (legacy bank)
			if (geom_en !== 1'b0) begin
				$display("FAIL exit re-armed store geom_en"); $fatal(1);
			end

			if (expect_island) begin
				// RED: 960 beam DE over legacy store
				if (content_width !== 11'd960 || hde_act !== 11'd960 ||
					line_min != 960 || line_max != 960 || pix != 960*540*2) begin
					$display("FAIL RED island twin did not keep 960 DE"); $fatal(1);
				end
				$display("OK RED FAULT_B13_DISABLE_ISLAND: 960 DE + geom_en=0 (island class)");
			end else begin
				// Product: beam DE extent = legacy 624×480 (matches store live columns)
				exp_pix = 624 * 480 * 2;
				if (content_width !== 11'd624 || content_height !== 11'd480) begin
					$display("FAIL exit content not legacy 624x480 (got %0dx%0d)",
						content_width, content_height);
					$fatal(1);
				end
				if (hde_act !== 11'd624 || vact_act !== 11'd480 ||
					line_min != 624 || line_max != 624 || pix != exp_pix) begin
					$display("FAIL exit beam DE extent not 624x480 (beam=%0dx%0d line=%0d..%0d pix=%0d)",
						hde_act, vact_act, line_min, line_max, pix);
					$fatal(1);
				end
				// Non-black / input DE extent: every counted DE pixel is inside 624×480
				// (no 960-wide lines that would be hollow beyond 624 store columns).
				if (line_max > 624) begin
					$display("FAIL DE wider than legacy store columns"); $fatal(1);
				end
				$display("OK E2E native→legacy exit DE=624x480 exact geom_en=0 pix=%0d (no island)",
					pix);
			end
		end
	endtask

	initial begin
`ifdef FAULT_B8_FORCE_ALWAYS
		$display("RED FAULT_B8_FORCE_ALWAYS collision #5 regression");
		run_live(624, 480, 1'b0);
		$display("PASS present_b13_mux_e2e RED fault_force=1");
`elsif FAULT_B13_DISABLE_ISLAND
		$display("RED FAULT_B13_DISABLE_ISLAND native→legacy island");
		run_native_to_legacy_exit(1'b1);
		$display("PASS present_b13_mux_e2e RED island");
`else
		$display("GREEN product mux→beam E2E");
		run_live(624, 480, 1'b1);
		run_live(416, 234, 1'b1);
		run_live(320, 240, 1'b1);
		run_live(960, 540, 1'b1);
		// idle fallback: !owned → 960 max tier
		plxg_live_valid = 1'b0; plxg_cw = 0; plxg_ch = 0;
		plxg_geom_en = 1'b0; plxg_win_en = 1'b0;
		want_frames = 2;
		reset = 1; repeat (12) @(posedge clk); reset = 0;
		begin : idle
			integer g; g = 0;
			while (done < 2 && g < 1182*564*4) begin @(posedge clk); g = g + 1; end
		end
		#1;
		if (content_width !== 11'd960 || hde_act !== 11'd960) begin
			$display("FAIL idle fallback not 960 (mux=%0d beam=%0d)", content_width, hde_act);
			$fatal(1);
		end
		$display("OK E2E idle fallback DE=960x540");

		// Critical: native→legacy exit measures DE extent (rd-duck island class)
		run_native_to_legacy_exit(1'b0);

		$display("PASS present_b13_mux_e2e GREEN product_mux exact");
`endif
		$finish;
	end
endmodule
`default_nettype wire
