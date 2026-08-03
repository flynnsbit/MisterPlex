`timescale 1ps/1ps
// B15: exact frame counts for content_fps → V_TOTAL → beam rate.
// Window = 4 * 1182 * 705 clocks:
//   fps=24 → V=705 → 4 frames exact
//   fps=30 → V=564 → 5 frames exact (4*705/564 = 5)
// RED FAULT_B15_IGNORE_FPS: always V=705 even when fps=30 → expect fail path
`default_nettype none
module b15_cadence_framecount_tb;
	localparam int CLK_PS = 25000; // 20 MHz
	localparam int H_TOT = 1182;
	localparam int V30 = 564;
	localparam int V24 = 705;
	localparam int FRAMES_WIN = 4;
	localparam int WINDOW_CLKS = FRAMES_WIN * H_TOT * V24; // 4*1182*705

	reg clk = 0;
	always #(CLK_PS/2) clk = ~clk;
	reg reset = 1;

	// DUT-facing fps (product threshold <=25 → 705)
	reg [7:0] content_fps;

`ifdef FAULT_B15_IGNORE_FPS
	// RED: ignore runtime fps — permanent film total (pre-B15 product shape)
	wire [10:0] beam_vtot_req = 11'(V24);
`else
	wire [10:0] beam_vtot_req = (content_fps <= 8'd25) ? 11'(V24) : 11'(V30);
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

	integer frames, armed, clks;
	reg fs_d;

	task automatic run_fps;
		input integer fps;
		input integer exp_frames;
		input bit expect_pass; // 0 = this run must mismatch (RED path driver)
		integer guard;
		begin
			content_fps = 8'(fps);
			reset = 1;
			frames = 0; armed = 0; clks = 0; fs_d = 0;
			repeat (20) @(posedge clk);
			reset = 0;
			// Drain one frame_start after reset before arming window
			guard = 0;
			while (guard < H_TOT * V24) begin
				@(posedge clk);
				if (ce && fstart && !fs_d) begin
					armed = 1;
					frames = 0;
					clks = 0;
					fs_d = fstart;
					guard = H_TOT * V24; // break
				end else begin
					fs_d = fstart;
					guard = guard + 1;
				end
			end
			// Exact wall window
			while (clks < WINDOW_CLKS) begin
				@(posedge clk);
				if (ce) begin
					if (fstart && !fs_d) frames = frames + 1;
					fs_d = fstart;
					clks = clks + 1;
				end
			end
			#1;
			$display("B15 fps=%0d vtot=%0d window_clks=%0d frames=%0d exp=%0d",
				fps, vtot_act, clks, frames, exp_frames);
			if (expect_pass) begin
				if (frames !== exp_frames) begin
					$display("FAIL framecount fps=%0d got=%0d exp=%0d", fps, frames, exp_frames);
					$fatal(1);
				end
				if (fps <= 25 && vtot_act !== 11'(V24)) begin
					$display("FAIL vtot film"); $fatal(1);
				end
				if (fps > 25 && vtot_act !== 11'(V30)) begin
					$display("FAIL vtot tv"); $fatal(1);
				end
				$display("OK B15 fps=%0d frames=%0d exact vtot=%0d", fps, frames, vtot_act);
			end else begin
				// RED driver: caller expects mismatch vs TV count
				if (frames === exp_frames) begin
					$display("FAIL RED did not break TV framecount (still %0d)", frames);
					$fatal(1);
				end
				$display("OK RED ignore-fps broke count frames=%0d (not %0d)", frames, exp_frames);
			end
		end
	endtask

	initial begin
`ifdef FAULT_B15_IGNORE_FPS
		$display("RED FAULT_B15_IGNORE_FPS");
		// Drive fps=30 but hardware ignores → film rate → 4 frames not 5
		run_fps(30, 5, 1'b0);
		$display("PASS b15_cadence_framecount RED");
`else
		$display("GREEN B15 cadence framecount");
		run_fps(24, 4, 1'b1);
		run_fps(30, 5, 1'b1);
		// Also 23 film-class and 60 tv-class thresholds
		run_fps(23, 4, 1'b1);
		run_fps(60, 5, 1'b1);
		$display("PASS b15_cadence_framecount GREEN");
`endif
		$finish;
	end
endmodule
`default_nettype wire
