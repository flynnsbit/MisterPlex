`timescale 1ps/1ps
// B15 + ABI#2 + rd-duck adversarial:
// - Count beam frame_start (raster completes), NOT "unique content banks".
// - present_cadence display_hz = CORE integer 24/30, not HDMI 60.
// - INTEGER fps only: 24/30 with content_fps==core → 1:1 advance.
// - fps=25: TV raster V=564 @30; floor(n*25/30) → 4/5 short, 25/30 long.
// - NOT NTSC: 24000/1001 and 30000/1001 are LOST by integer q5 (bucket→24/30).
//   Beam 20e6/(1182*705)=24.000672 vs 23.976024 → ~40.57s/frame slip (see
//   assets/ntsc_rational_cadence_wall.json). Do NOT claim source-lock/judder
//   control for 23.976/29.97 until rational/milli ABI + pending-bank model.
// - RED IGNORE_FPS_VALID / RED CADENCE_HDMI60 as before.
//
// frame_start pulses once per completed frame (v_wrap).
`default_nettype none
module b15_cadence_framecount_tb;
	localparam int CLK_PS = 25000;
	localparam int H_TOT = 1182;
	localparam int V30 = 564;
	localparam int V24 = 705;
	localparam int FRAMES_WIN = 4;
	// Wall clock of 4 film frames — film→4 completes, TV→5 completes.
	localparam int WINDOW_CLKS = FRAMES_WIN * H_TOT * V24;
	// Exact 6:5 proof: 30 TV raster ticks @ core 30 with content_fps=25 → 25 advances.
	localparam int LONG_RASTER = 30;
	localparam int LONG_CLKS = LONG_RASTER * H_TOT * V30;

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
	// Core raster Hz only — NOT equal to content_fps when fps=25 (TV 30 holds).
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
		.rt_h_de(11'd960), .rt_h_total(11'(H_TOT)), .rt_v_active(11'd540), .rt_de_apply(1'b1),
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

	// Run exactly n_clks free-running clocks after reset; count fstart + advances.
	task automatic run_clks;
		input bit fv;
		input integer fps;
		input integer n_clks;
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
			while (clks < n_clks) begin
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

	task automatic run_window;
		input bit fv;
		input integer fps;
		output integer o_raster;
		output integer o_swap;
		output integer o_adv;
		output integer o_vtot;
		begin
			run_clks(fv, fps, WINDOW_CLKS, o_raster, o_swap, o_adv, o_vtot);
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

		// fps=25 threshold: TV class raster, not film — still cadence 25≠30
		drive_q5(1'b1, 25);
		#1;
		if (film_class(content_fps_eff)) begin
			$display("FAIL fps=25 classified film"); $fatal(1);
		end
		if (beam_vtot_req !== 11'(V30)) begin
			$display("FAIL fps=25 vtot not 564 got %0d", beam_vtot_req); $fatal(1);
		end
		if (cadence_hz_core !== 8'd30) begin
			$display("FAIL fps=25 core hz not 30 got %0d", cadence_hz_core); $fatal(1);
		end
		if (content_fps_eff === cadence_hz_core) begin
			$display("FAIL fps=25 wrongly equals core hz (would imply false 1:1)"); $fatal(1);
		end
		$display("OK fps=25 -> TV class V=564 core_hz=30 content!=core (not 24.0007)");

		// valid 24 → film 4; content_fps==core → 1:1
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

		// valid 30 → TV 5; content_fps==core → 1:1
		run_window(1'b1, 30, r, s, a, vt);
		$display("B15 RASTER fps_valid=1 fps=30 eff=%0d film=0 vtot=%0d frame_start=%0d exp=5 swap_opp=%0d adv=%0d",
			content_fps_eff, vt, r, s, a);
		if (r !== 5 || s !== 5 || a !== 5) begin
			$display("FAIL tv30 r/s/a=%0d/%0d/%0d", r, s, a); $fatal(1);
		end
		$display("OK B15 raster frame_start=5 swap_opp=5 vtot=%0d (not unique-bank claim)", vt);
		$display("OK ADV_PROOF integer 1:1 raster=5 advances=5 (fps==core only; NOT NTSC 29.97)");

		// valid 25 short: TV raster 5; cadence floor → advances at di 0,2,3,4 = 4 NOT 5
		run_window(1'b1, 25, r, s, a, vt);
		$display("B15 RASTER fps_valid=1 fps=25 frame_start=%0d adv=%0d", r, a);
		if (r !== 5) begin
			$display("FAIL fps25 raster %0d", r); $fatal(1);
		end
		if (a !== 4) begin
			$display("FAIL fps25 advances %0d exp 4 (25/30 short)", a); $fatal(1);
		end
		if (a === r) begin
			$display("FAIL fps25 wrongly 1:1 with core"); $fatal(1);
		end
		$display("OK B15 fps=25 raster frame_start=5 advances=4 (25/30 hold, not 1:1)");

		// Long exact 6:5 window: 30 raster @30 core, content_fps=25 → exactly 25 advances
		// (rd-duck: over 30 ticks floor(n*25/30) visits 0..24 ⇒ 25 advances).
		run_clks(1'b1, 25, LONG_CLKS, r, s, a, vt);
		$display("B15 LONG25 raster=%0d exp=%0d advances=%0d exp=25 vtot=%0d",
			r, LONG_RASTER, a, vt);
		if (r !== LONG_RASTER) begin
			$display("FAIL long25 raster %0d != %0d", r, LONG_RASTER); $fatal(1);
		end
		if (a !== 25) begin
			$display("FAIL long25 advances %0d != 25 (6:5 over 30 ticks)", a); $fatal(1);
		end
		$display("OK B15 fps=25 LONG 30-raster advances=25 (exact 6:5 / 25-of-30)");

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

		$display("NOTE: integer 1:1 only when content_fps>=core_hz (24/24, 30/30). fps=25 hold. NTSC 23.976/29.97 NOT locked.");
		$display("NOTE: advance_unique = cadence; DDR swap = fstart&&swap_pending (C1).");
		$display("NOTE: swap_opp with pending=1 tracks raster — NOT ARM unique-bank proof.");
		$display("PASS b15_cadence_framecount GREEN");
`endif
		$finish;
	end
endmodule
`default_nettype wire
