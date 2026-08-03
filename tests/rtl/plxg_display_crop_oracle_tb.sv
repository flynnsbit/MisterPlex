`timescale 1ns/1ps
// B21: PLXG q3 display/crop oracle — coded=624 display=618 crop_left=3.
// GREEN: mux emits display=618 crop=3 (not display=coded).
// RED FAULT_MUX_DISPLAY_EQ_CODED: display=624 with crop=3 (dead q3 / OOB class).
`default_nettype none
module plxg_display_crop_oracle_tb;
	reg live = 1, win = 1, geom = 1;
	reg [10:0] cw = 11'd618, ch = 11'd480;
	reg [10:0] cx0 = 0, cy0 = 0, hde = 11'd618, vde = 11'd480;
	reg [10:0] coded_w = 11'd624, coded_h = 11'd480;
	reg [11:0] y_stride = 12'd624;
	reg [10:0] c_stride = 11'd312;
	reg [10:0] dw = 11'd618, dh = 11'd480;
	reg [10:0] px = 0, py = 0, cl = 11'd3, ct = 11'd0;

	wire pwin, pgeom;
	wire [10:0] out_cw, out_ch, out_cx0, out_cy0, out_hde, out_vde;
	wire [10:0] out_cod_w, out_cod_h, out_c_stride, out_dw, out_dh, out_px, out_py, out_cl, out_ct;
	wire [11:0] out_y_stride;

	plex_present_geom_mux dut (
		.content_res_640x480(1'b0),
		.plxg_live_valid(live),
		.plxg_win_en(win),
		.plxg_geom_en(geom),
		.plxg_cw(cw), .plxg_ch(ch),
		.plxg_cx0(cx0), .plxg_cy0(cy0),
		.plxg_hde(hde), .plxg_vde(vde),
		.plxg_coded_w(coded_w), .plxg_coded_h(coded_h),
		.plxg_y_stride(y_stride), .plxg_c_stride(c_stride),
		.plxg_dw(dw), .plxg_dh(dh),
		.plxg_px(px), .plxg_py(py),
		.plxg_cl(cl), .plxg_ct(ct),
		.present_win_enable(pwin),
		.present_geom_enable(pgeom),
		.content_width(out_cw), .content_height(out_ch),
		.present_content_x0(out_cx0), .present_content_y0(out_cy0),
		.present_win_h_de(out_hde), .present_win_v_de(out_vde),
		.present_geom_coded_w(out_cod_w), .present_geom_coded_h(out_cod_h),
		.present_geom_y_stride(out_y_stride),
		.present_geom_chroma_stride(out_c_stride),
		.present_geom_display_w(out_dw), .present_geom_display_h(out_dh),
		.present_geom_present_x(out_px), .present_geom_present_y(out_py),
		.present_geom_crop_left(out_cl), .present_geom_crop_top(out_ct)
	);

	// Combinational DUT — sample after settle
	initial begin
		#1;
		$display("plxg_display_crop_oracle_tb start");
		$display("in coded=%0dx%0d display=%0dx%0d crop=%0d,%0d",
			coded_w, coded_h, dw, dh, cl, ct);
		$display("out coded=%0dx%0d display=%0dx%0d crop=%0d,%0d content=%0dx%0d",
			out_cod_w, out_cod_h, out_dw, out_dh, out_cl, out_ct, out_cw, out_ch);

		// coded always 624 for content-bearing
		if (out_cod_w !== 11'd624 || out_cod_h !== 11'd480) begin
			$display("FAIL coded out %0dx%0d", out_cod_w, out_cod_h); $fatal(1);
		end

`ifdef FAULT_MUX_DISPLAY_EQ_CODED
		// RED: display forced to coded; crop still 3 → end x = 627
		if (out_dw !== 11'd624 || out_dh !== 11'd480) begin
			$display("FAIL RED expected display=coded got %0dx%0d", out_dw, out_dh);
			$fatal(1);
		end
		if (out_cl !== 11'd3) begin
			$display("FAIL RED crop dropped"); $fatal(1);
		end
		begin : red_oob
			integer end_x;
			end_x = out_cl + out_dw; // 3+624=627 > 624
			if (end_x <= coded_w) begin
				$display("FAIL RED did not create OOB end_x=%0d", end_x); $fatal(1);
			end
			$display("REPRO_OK FAULT display=coded=%0d crop=%0d end_x=%0d > coded (OOB class)",
				out_dw, out_cl, end_x);
		end
		$display("PASS plxg_display_crop_oracle RED dead-q3");
`else
		// GREEN: display=618 crop=3; end_x = 621 <= 624
		if (out_dw !== 11'd618 || out_dh !== 11'd480) begin
			$display("FAIL display got %0dx%0d want 618x480", out_dw, out_dh); $fatal(1);
		end
		if (out_cl !== 11'd3 || out_ct !== 11'd0) begin
			$display("FAIL crop got %0d,%0d", out_cl, out_ct); $fatal(1);
		end
		if (out_cl + out_dw > out_cod_w) begin
			$display("FAIL in-bounds broken end=%0d", out_cl+out_dw); $fatal(1);
		end
		$display("OK 624/618/crop3 display=%0d crop=%0d end_x=%0d <= coded",
			out_dw, out_cl, out_cl+out_dw);

		// OOB crop rejected → safe coded + crop0
		cl = 11'd20; dw = 11'd618; // 20+618=638 > 624
		#1;
		if (out_dw !== 11'd624 || out_cl !== 11'd0) begin
			$display("FAIL OOB not sanitized dw=%0d cl=%0d", out_dw, out_cl); $fatal(1);
		end
		$display("OK OOB crop+display sanitized to coded+crop0");

		// dw=0 → coded identity
		cl = 11'd0; dw = 11'd0; dh = 11'd0;
		#1;
		if (out_dw !== 11'd624 || out_dh !== 11'd480 || out_cl !== 11'd0) begin
			$display("FAIL zero display fallback"); $fatal(1);
		end
		$display("OK dw=0 falls back to coded identity");

		$display("PASS plxg_display_crop_oracle GREEN 624/618");
`endif
		$finish;
	end
endmodule
`default_nettype wire
