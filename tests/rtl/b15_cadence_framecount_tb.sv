`timescale 1ps/1ps
// B15 + ABI#2 + rd-duck adversarial:
// - Count beam frame_start (raster completes), NOT "unique content banks".
// - present_cadence display_hz = CORE 24/30 (source-locked), not HDMI 60.
// - fps=25 → TV V=564 (film is <=24 only).
// - RED IGNORE_FPS_VALID: 30-title stays film 4 frames.
// - RED CADENCE_HDMI60: advances ~half of raster (30/60 floor).
//
// frame_start pulses once per completed frame (v_wrap). Window = 4*1182*705
// ce clocks from (0,0) after reset → film:4 completes, TV:5 completes.
`default_nettype none
module b15_cadence_framecount_tb;
	localparam int CLK_PS = 25000;
	localparam int H_TOT = 1182;
	localparam int V30 = 564;
	localparam int V24 = 705;
	localparam int FRAMES_WIN = 4;
	localparam int WINDOW_CLKS = FRAMES_WIN * H_TOT * V24; // 4 film frames wall

	function automatic [63:0] pack_q5;
		input [11:0] dar_x, dar_y;
		input [7:0] fps;
		input bit dar_v, fps_v;
		begin
			pack_q5 = 64'd0;
			pack_q5[11:0]  = dar_x;
			pack_q5[23:12] = dar_y;
			pack_q5[31:24] = fps;
			pack_q5[32]    = dar_v;
			pack_q5[33]    = fps_v;
		end
	endfunction

	function automatic bit film_class;
		input [7:0] fps;
		film_class = (fps <= 8'd24);
	endfunction

	reg clk = 0;
	always #(CLK_PS/2) clk = ~clk;
	reg reset = 1;

	reg        fps_valid;
	reg [7:0]  content_fps_q5;
	wire [7:0] content_fps_eff;
	plex_content_fps_sel u_sel (
		.fps_valid(fps_valid),
		.content_fps_q5(content_fps_q5),
		.content_fps_eff(content_fps_eff)
	);

	wire beam_film = film_class(content_fps_eff);
	wire [10:0] beam_vtot_req = beam_film ? 11'(V24) : 11'(V30);
	wire [7:0] cadence_hz_core = beam_film ? 8'd24 : 8'd30;
`ifdef FAULT_B15_CADENCE_HDMI60
	wire [7:0] cadence_hz = 8'd60;
`else
	wire [7:0] cadence_hz = cadence_hz_core;
`endif

	wire ce, hb, hs, vb, vs, fstart;
	wire [10:0] hc, vc, vtot_act, hde_act, htot_act, vact_act;
	present_beam_content_de #(
		.H_DE(960), .V_ACTIVE(540), .H_TOTAL(H_TOT), .V_TOTAL(V30)
	) beam (
		.clk(clk), .reset(reset),
		.use_rt_vtotal(1'b1), .rt_vtotal(beam_vtot_req),
		.use_rt_geom(1'b1),
		.rt_h_de(11'd960), .rt_h_total(11'(H_TOT)), .rt_v_active(11'd540),
		.ce_pix(ce), .HBlank(hb), .HSync(hs), .VBlank(vb), .VSync(vs),
		.frame_start(fstart), .hc_out(hc), .vc_out(vc),
		.vtot_active(vtot_act), .hde_active(hde_act), .htot_active(htot_act),
		.vact_active(vact_act)
	);

	wire advance_unique;
	wire [31:0] disp_i, cont_i;
	present_cadence cadence (
		.clk(clk),
		.reset(reset),
		.display_tick(fstart),
		.content_fps(content_fps_eff),
		.display_hz(cadence_hz),
		.advance_unique(advance_unique),
		.display_index(disp_i),
		.content_index(cont_i)
	);

	// Hold swap_pending so every raster complete is a fabric swap opportunity.
	// This is NOT an ARM unique-bank proof (C1 / rd-duck).
	reg swap_pending;

	task automatic drive_q5;
		input bit fv;
		input integer fps;
		reg [63:0] q5;
		begin
			q5 = pack_q5(12'd16, 12'd9, 8'(fps), 1'b0, fv);
			if (q5[63:34] !== 30'd0) begin
				$display("FAIL TB pack reserved nonzero"); $fatal(1);
			end
			fps_valid = q5[33];
			content_fps_q5 = q5[31:24];
		end
	endtask

	// Run WINDOW_CLKS free-running ce clocks after reset; count fstart + advances.
	task automatic run_window;
		input bit fv;
		input integer fps;
		output integer o_raster;
		output integer o_swap;
		output integer o_adv;
		output integer o_vtot;
		integer clks;
		begin
			drive_q5(fv, fps);
			swap_pending = 1'b1;
			reset = 1;
			o_raster = 0; o_swap = 0; o_adv = 0; clks = 0;
			repeat (8) @(posedge clk);
			reset = 0;
			// First free-running edge starts beam at (0,0)→next
			while (clks < WINDOW_CLKS) begin
				@(posedge clk);
				#1; // settle NBA (frame_start / advance_unique)
				if (fstart) begin
					o_raster = o_raster + 1;
					if (swap_pending) o_swap = o_swap + 1;
				end
				if (advance_unique) o_adv = o_adv + 1;
				clks = clks + 1;
			end
			#1;
			o_vtot = vtot_act;
		end
	endtask

	integer r, s, a, vt;

	initial begin
`ifdef FAULT_B15_IGNORE_FPS_VALID
		$display("RED FAULT_B15_IGNORE_FPS_VALID");
		// Product would give 5 TV frames for valid 30; ignore keeps film 4.
		run_window(1'b1, 30, r, s, a, vt);
		$display("B15 RED_IGN fps_valid=1 fps=30 eff=%0d raster=%0d vtot=%0d",
			content_fps_eff, r, vt);
		if (content_fps_eff !== 8'd24) begin
			$display("FAIL ignore did not force 24"); $fatal(1);
		end
		if (r === 5) begin
			$display("FAIL RED still got TV 5 frames"); $fatal(1);
		end
		if (r !== 4) begin
			$display("FAIL RED expected film 4 got %0d", r); $fatal(1);
		end
		$display("OK RED raster broken got=%0d not 5 (30 title frozen film)", r);
		$display("PASS b15 RED ignore_fps_valid");

`elsif FAULT_B15_CADENCE_HDMI60
		$display("RED FAULT_B15_CADENCE_HDMI60");
		run_window(1'b1, 30, r, s, a, vt);
		$display("B15 RED_HDMI60 raster=%0d advances=%0d cadence_hz=%0d", r, a, cadence_hz);
		if (r !== 5) begin
			$display("FAIL raster not 5 got %0d", r); $fatal(1);
		end
		// 30/60 floor → advances on ticks 0,2,4 = 3 of 5
		if (a >= r) begin
			$display("FAIL RED HDMI60 still full advances=%0d", a); $fatal(1);
		end
		if (a !== 3) begin
			$display("FAIL RED expected 3 advances got %0d", a); $fatal(1);
		end
		$display("OK RED CADENCE_HDMI60 advances=%0d < raster=%0d (halved class)", a, r);
		$display("PASS b15 RED cadence_hdmi60");

`else
		$display("GREEN B15 raster+cadence (honest claims)");

		// fps=25 threshold: TV class, not film
		drive_q5(1'b1, 25);
		#1;
		if (film_class(content_fps_eff)) begin
			$display("FAIL fps=25 classified film"); $fatal(1);
		end
		if (beam_vtot_req !== 11'(V30)) begin
			$display("FAIL fps=25 vtot not 564 got %0d", beam_vtot_req); $fatal(1);
		end
		$display("OK fps=25 -> TV class V=564 (not 24.0007)");

		// valid 24 → film 4
		run_window(1'b1, 24, r, s, a, vt);
		$display("B15 RASTER fps_valid=1 fps=24 eff=%0d film=1 vtot=%0d frame_start=%0d exp=4 swap_opp=%0d adv=%0d",
			content_fps_eff, vt, r, s, a);
		if (r !== 4 || s !== 4) begin
			$display("FAIL film24 raster/swap %0d/%0d", r, s); $fatal(1);
		end
		if (a !== 4) begin
			$display("FAIL film24 advances %0d", a); $fatal(1);
		end
		$display("OK B15 raster frame_start=4 swap_opp=4 vtot=%0d (not unique-bank claim)", vt);

		// valid 30 → TV 5 + 1:1 advance
		run_window(1'b1, 30, r, s, a, vt);
		$display("B15 RASTER fps_valid=1 fps=30 eff=%0d film=0 vtot=%0d frame_start=%0d exp=5 swap_opp=%0d adv=%0d",
			content_fps_eff, vt, r, s, a);
		if (r !== 5 || s !== 5 || a !== 5) begin
			$display("FAIL tv30 r/s/a=%0d/%0d/%0d", r, s, a); $fatal(1);
		end
		$display("OK B15 raster frame_start=5 swap_opp=5 vtot=%0d (not unique-bank claim)", vt);
		$display("OK ADV_PROOF source-locked 1:1 raster=5 advances=5");

		// valid 25 → TV raster 5; cadence 25/30 → 4 advances (not 1:1)
		// floor ticks: adv on di 0,2,3,4 = 4 of 5 (hold one display tick)
		run_window(1'b1, 25, r, s, a, vt);
		$display("B15 RASTER fps_valid=1 fps=25 frame_start=%0d adv=%0d", r, a);
		if (r !== 5) begin
			$display("FAIL fps25 raster %0d", r); $fatal(1);
		end
		if (a !== 4) begin
			$display("FAIL fps25 advances %0d exp 4 (25/30)", a); $fatal(1);
		end
		$display("OK B15 fps=25 raster frame_start=5 advances=4 (25/30 hold)");

		// unspecified valid=0 fps=30 → film default 24 → 4
		run_window(1'b0, 30, r, s, a, vt);
		$display("B15 RASTER fps_valid=0 fps=30 eff=%0d frame_start=%0d", content_fps_eff, r);
		if (content_fps_eff !== 8'd24) begin
			$display("FAIL unspecified not 24"); $fatal(1);
		end
		if (r !== 4) begin
			$display("FAIL unspecified raster %0d", r); $fatal(1);
		end
		$display("OK B15 unspecified->24 raster frame_start=4 (no invent 30)");

		$display("NOTE: advance_unique = cadence at core Hz; DDR swap = fstart&&swap_pending (C1).");
		$display("NOTE: swap_opp with pending=1 tracks raster — NOT ARM unique-bank proof.");
		$display("PASS b15_cadence_framecount GREEN");
`endif
		$finish;
	end
endmodule
`default_nettype wire
