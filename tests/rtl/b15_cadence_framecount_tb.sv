`timescale 1ps/1ps
// B15 + ABI#2: PLXG q5 fps_valid/content_fps → unique frame count.
// Window = 4 * 1182 * 705 clocks:
//   fps_valid=1 fps=24 → V=705 → 4 frames
//   fps_valid=1 fps=30 → V=564 → 5 frames
//   fps_valid=0 (30 title unspecified) → film 24 → 4 frames  (not inventing 30)
// RED FAULT_B15_IGNORE_FPS_VALID: valid=1 fps=30 still yields 4 (old permanent 24)
`default_nettype none
module b15_cadence_framecount_tb;
	localparam int CLK_PS = 25000;
	localparam int H_TOT = 1182;
	localparam int V30 = 564;
	localparam int V24 = 705;
	localparam int FRAMES_WIN = 4;
	localparam int WINDOW_CLKS = FRAMES_WIN * H_TOT * V24;

	// q5 bit layout (documentation + pack helper for this TB only)
	// [31:24] content_fps  [33] fps_valid  [63:34] reserved=0
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

	wire [10:0] beam_vtot_req = (content_fps_eff <= 8'd25) ? 11'(V24) : 11'(V30);

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

	integer frames, armed, clks;
	reg fs_d;

	task automatic run_case;
		input bit fv;
		input integer fps;
		input integer exp_frames;
		input bit expect_match;
		integer guard;
		reg [63:0] q5;
		begin
			q5 = pack_q5(12'd16, 12'd9, 8'(fps), 1'b0, fv);
			// reserved must be zero in legal packs
			if (q5[63:34] !== 30'd0) begin
				$display("FAIL TB pack reserved nonzero"); $fatal(1);
			end
			fps_valid = q5[33];
			content_fps_q5 = q5[31:24];
			reset = 1;
			frames = 0; armed = 0; clks = 0; fs_d = 0;
			repeat (20) @(posedge clk);
			reset = 0;
			guard = 0;
			while (guard < H_TOT * V24) begin
				@(posedge clk);
				if (ce && fstart && !fs_d) begin
					armed = 1; frames = 0; clks = 0; fs_d = fstart;
					guard = H_TOT * V24;
				end else begin
					fs_d = fstart; guard = guard + 1;
				end
			end
			while (clks < WINDOW_CLKS) begin
				@(posedge clk);
				if (ce) begin
					if (fstart && !fs_d) frames = frames + 1;
					fs_d = fstart;
					clks = clks + 1;
				end
			end
			#1;
			$display("B15 q5 fps_valid=%0d fps=%0d eff=%0d vtot=%0d frames=%0d exp=%0d",
				fv, fps, content_fps_eff, vtot_act, frames, exp_frames);
			if (expect_match) begin
				if (frames !== exp_frames) begin
					$display("FAIL frames got=%0d exp=%0d", frames, exp_frames); $fatal(1);
				end
				$display("OK B15 fps_valid=%0d fps=%0d frames=%0d exact", fv, fps, frames);
			end else begin
				if (frames === exp_frames) begin
					$display("FAIL RED still matched TV count %0d", frames); $fatal(1);
				end
				$display("OK RED fps_valid ignored/broken frames=%0d (not %0d)", frames, exp_frames);
			end
		end
	endtask

	initial begin
`ifdef FAULT_B15_IGNORE_FPS_VALID
		$display("RED FAULT_B15_IGNORE_FPS_VALID");
		// 30 fps title with valid=1 still stuck at 24 unique frames
		run_case(1'b1, 30, 5, 1'b0);
		$display("PASS b15_cadence_framecount RED ignore_fps_valid");
`else
		$display("GREEN B15 ABI#2 q5 cadence framecount");
		// q5 pack self-check
		begin : pk
			reg [63:0] t;
			t = pack_q5(12'd4, 12'd3, 8'd30, 1'b1, 1'b1);
			if (t[31:24] !== 8'd30 || t[33] !== 1'b1 || t[32] !== 1'b1) begin
				$display("FAIL pack_q5"); $fatal(1);
			end
			if (t[11:0] !== 12'd4 || t[23:12] !== 12'd3) begin
				$display("FAIL pack_q5 dar"); $fatal(1);
			end
			$display("OK q5 pack layout dar+fps");
		end
		run_case(1'b1, 24, 4, 1'b1);
		run_case(1'b1, 30, 5, 1'b1);
		// Parent red-class product shape without fault: fps_valid=0 on a 30 title
		// → must NOT invent 30 → 4 unique frames (24 Hz beam)
		run_case(1'b0, 30, 4, 1'b1);
		$display("OK B15 fps_valid=0 does not invent 30 (frames=4)");
		run_case(1'b1, 60, 5, 1'b1);
		$display("PASS b15_cadence_framecount GREEN");
`endif
		$finish;
	end
endmodule
`default_nettype wire
