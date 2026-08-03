// Cosim: present_beam_ppc emits genuine CEA 1280×720 DE geometry.
// Counts active DE lane-pixels over one full frame and checks H/V totals.
`default_nettype none

module present_beam_720p_tb #(
	parameter int PX_PER_CLK = 2
);
	localparam int H_DE     = 1280;
	localparam int H_TOTAL  = 1650;
	localparam int V_ACTIVE = 720;
	localparam int V_TOTAL  = 750;
	localparam int H_SYNC_S = 1390;
	localparam int H_SYNC_E = 1430;
	localparam int V_SYNC_S = 725;
	localparam int V_SYNC_E = 730;
	localparam int ACTIVE_PX = H_DE * V_ACTIVE; // 921_600

	reg clk = 1'b0;
	always #25 clk = ~clk; // 20 MHz

	reg reset = 1'b1;
	reg enable = 1'b0;

	wire beam_ce;
	wire [11:0] glass_x0, glass_y;
	wire [PX_PER_CLK-1:0] lane_de;
	wire HBlank, HSync, VBlank, VSync, frame_start;

	present_beam_ppc #(
		.PX_PER_CLK(PX_PER_CLK),
		.H_DE(H_DE),
		.H_TOTAL(H_TOTAL),
		.V_ACTIVE(V_ACTIVE),
		.V_TOTAL(V_TOTAL),
		.H_SYNC_S(H_SYNC_S),
		.H_SYNC_E(H_SYNC_E),
		.V_SYNC_S(V_SYNC_S),
		.V_SYNC_E(V_SYNC_E)
	) dut (
		.clk(clk),
		.reset(reset),
		.enable(enable),
		.beam_ce(beam_ce),
		.glass_x0(glass_x0),
		.glass_y(glass_y),
		.lane_de(lane_de),
		.HBlank(HBlank),
		.HSync(HSync),
		.VBlank(VBlank),
		.VSync(VSync),
		.frame_start(frame_start)
	);

	// Timing package cross-check (same constants)
	wire [11:0] t_h_de, t_h_total, t_v_act, t_v_total;
	wire [11:0] t_hs_s, t_hs_e, t_vs_s, t_vs_e;
	wire [15:0] t_fps_milli;
	wire        t_need_fast;
	present_video_timing_720p #(.CLK_PIX_HZ(20_000_000)) u_t (
		.h_de(t_h_de), .h_total(t_h_total), .v_active(t_v_act), .v_total(t_v_total),
		.h_sync_s(t_hs_s), .h_sync_e(t_hs_e), .v_sync_s(t_vs_s), .v_sync_e(t_vs_e),
		.fps_eff_milli(t_fps_milli), .cea_24_needs_faster_pix(t_need_fast)
	);

	integer de_px;
	integer frames;
	integer cycles;
	integer li;
	integer max_x_seen;
	integer max_y_seen;
	integer hs_cycles;
	integer vs_cycles;
	integer errors;

	always @(posedge clk) begin
		if (reset) begin
			// hold
		end else if (enable && beam_ce) begin
			cycles = cycles + 1;
			for (li = 0; li < PX_PER_CLK; li = li + 1) begin
				if (lane_de[li])
					de_px = de_px + 1;
			end
			if (glass_x0 > max_x_seen)
				max_x_seen = glass_x0;
			if (glass_y > max_y_seen)
				max_y_seen = glass_y;
			if (HSync)
				hs_cycles = hs_cycles + 1;
			if (VSync)
				vs_cycles = vs_cycles + 1;
			if (frame_start)
				frames = frames + 1;
		end
	end

	initial begin
		de_px = 0;
		frames = 0;
		cycles = 0;
		max_x_seen = 0;
		max_y_seen = 0;
		hs_cycles = 0;
		vs_cycles = 0;
		errors = 0;

		repeat (4) @(posedge clk);
		reset = 1'b0;
		@(posedge clk);
		enable = 1'b1;

		// Package constants
		if (t_h_de != 12'd1280 || t_v_act != 12'd720 || t_h_total != 12'd1650
		    || t_v_total != 12'd750) begin
			$display("FAIL timing package constants");
			$fatal(1);
		end
		// @20 MHz: fps_milli = 20000000*1000/1237500 = 16161
		if (t_fps_milli != 16'd16161) begin
			$display("FAIL fps_eff_milli got %0d want 16161", t_fps_milli);
			$fatal(1);
		end
		if (!t_need_fast) begin
			$display("FAIL: 20 MHz must flag cea_24_needs_faster_pix");
			$fatal(1);
		end

		// Run until second frame_start (one complete frame after first wrap)
		// First frame_start occurs at end of frame 0.
		wait (frames >= 1);
		de_px = 0;
		cycles = 0;
		max_x_seen = 0;
		max_y_seen = 0;
		hs_cycles = 0;
		vs_cycles = 0;
		wait (frames >= 2);

		if (de_px != ACTIVE_PX) begin
			$display("FAIL DE pixel count got %0d want %0d ppc=%0d",
				de_px, ACTIVE_PX, PX_PER_CLK);
			$fatal(1);
		end
		// Beam groups per frame. PPC=2: 1650/2 * 750 = 618_750.
		// PPC=4: 1650%4=2 → per line 412 full steps + 1 short(2) = 413 groups
		//         * 750 = 309_750.
		if (PX_PER_CLK == 2 && cycles != (H_TOTAL / 2) * V_TOTAL) begin
			$display("FAIL beam cycles got %0d want %0d", cycles, (H_TOTAL / 2) * V_TOTAL);
			$fatal(1);
		end
		if (PX_PER_CLK == 4 && cycles != 413 * V_TOTAL) begin
			$display("FAIL beam cycles ppc4 got %0d want %0d", cycles, 413 * V_TOTAL);
			$fatal(1);
		end
		if (max_x_seen < (H_DE - PX_PER_CLK)) begin
			$display("FAIL max glass_x0 %0d too small for H_DE=%0d", max_x_seen, H_DE);
			$fatal(1);
		end
		if (max_y_seen < (V_ACTIVE - 1)) begin
			$display("FAIL max glass_y %0d want >= %0d", max_y_seen, V_ACTIVE - 1);
			$fatal(1);
		end
		// HSync window 40 px.
		if (PX_PER_CLK == 2 && hs_cycles != 20 * V_TOTAL) begin
			$display("FAIL HSync cycles got %0d want %0d", hs_cycles, 20 * V_TOTAL);
			$fatal(1);
		end
		// PPC=4: 40/4 = 10 groups per line in HSync window (1390..1429 aligned).
		if (PX_PER_CLK == 4 && hs_cycles != 10 * V_TOTAL) begin
			$display("FAIL HSync cycles ppc4 got %0d want %0d", hs_cycles, 10 * V_TOTAL);
			$fatal(1);
		end
		// VSync 5 lines
		if (PX_PER_CLK == 2 && vs_cycles != 5 * (H_TOTAL / 2)) begin
			$display("FAIL VSync cycles got %0d want %0d", vs_cycles, 5 * (H_TOTAL / 2));
			$fatal(1);
		end
		if (PX_PER_CLK == 4 && vs_cycles != 5 * 413) begin
			$display("FAIL VSync cycles ppc4 got %0d want %0d", vs_cycles, 5 * 413);
			$fatal(1);
		end
		// Right-edge: last DE group must not need Y straddle (single qword).
		// Checked in check_present_720p_fit_contract.py; beam DE count proves coverage.

		$display("PASS present_beam_720p de_px=%0d cycles=%0d ppc=%0d fps_milli=%0d",
			de_px, cycles, PX_PER_CLK, t_fps_milli);
		$finish;
	end
endmodule

`default_nettype wire
