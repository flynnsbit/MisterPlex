`timescale 1ps/1ps
// B20 beam DE hold (rd-duck): delayed pending_ready past one fstart must NOT
// advance H_DE while store would still show old bank/app geometry.
// GREEN: hold old DE until swap_fire; then take new DE.
// RED FAULT_B20_BEAM_FREE_RUN: takes new DE on first fstart after promote (REPRO).
`default_nettype none
module b20_beam_de_hold_tb;
	localparam int CLK_HALF = 25000; // 20 MHz
	// Tiny raster for speed: H=80 V=20 (still > DE pads)
	localparam int H_TOT = 80;
	localparam int V_TOT = 20;
	localparam int OLD_W = 32;
	localparam int OLD_H = 16;
	localparam int NEW_W = 48;
	localparam int NEW_H = 16;

	reg clk = 0;
	always #CLK_HALF clk = ~clk;
	reg reset = 1;

	reg [10:0] cand_w = OLD_W;
	reg [10:0] cand_h = OLD_H;
	reg        swap_pending = 0;
	reg        pending_ready = 0;
	// Product path: Plex.sv ties use_frame_store=0 (force-bars OFF).
	// B20 arms on external-store path (!use_frame_store), not force-bars.
	// This TB drives candidates directly into rt_* (no app_* shadow), so apply
	// is level-qualified on pending&&ready (store-ready). present_core gates
	// via app_* + fstart ack; both must refuse DE/app change while !ready.
	wire use_frame_store = 1'b0;
	wire geom_live_valid = 1'b1;
	wire b20_ext_store_path = !use_frame_store;
	wire beam_swap_ready = swap_pending && pending_ready;
	wire beam_de_free   = !b20_ext_store_path; // force-bars only
	wire beam_de_idle   = b20_ext_store_path && !swap_pending && !geom_live_valid;
	wire beam_de_apply  = beam_de_free || beam_swap_ready || beam_de_idle;

	wire ce, hb, hs, vb, vs, fstart;
	wire [10:0] hc, vc, hde_a, htot_a, vact_a, vtot_a;

	present_beam_content_de #(
		.H_DE(OLD_W), .V_ACTIVE(OLD_H),
		.H_TOTAL(H_TOT), .V_TOTAL(V_TOT),
		.H_SYNC_S(OLD_W+4), .H_SYNC_E(OLD_W+8),
		.V_SYNC_S(OLD_H+1), .V_SYNC_E(OLD_H+2)
	) beam (
		.clk(clk), .reset(reset),
		.use_rt_vtotal(1'b0), .rt_vtotal(11'd0),
		.use_rt_geom(1'b1),
		.rt_h_de(cand_w),
		.rt_h_total(11'(H_TOT)),
		.rt_v_active(cand_h),
		.rt_de_apply(beam_de_apply),
		.ce_pix(ce), .HBlank(hb), .HSync(hs), .VBlank(vb), .VSync(vs),
		.frame_start(fstart),
		.hc_out(hc), .vc_out(vc),
		.vtot_active(vtot_a), .hde_active(hde_a),
		.htot_active(htot_a), .vact_active(vact_a)
	);

	reg fs_d;
	integer frames, guard;
	integer hde_at_frame;

	task automatic wait_fstarts;
		input integer n;
		integer g, got;
		begin
			got = 0; g = 0; fs_d = 0;
			while (got < n && g < n * H_TOT * V_TOT * 4) begin
				@(posedge clk);
				g = g + 1;
				if (ce && fstart && !fs_d) got = got + 1;
				fs_d = fstart;
			end
			if (got < n) begin
				$display("FAIL timeout fstarts got=%0d want=%0d", got, n);
				$fatal(1);
			end
		end
	endtask

	initial begin
		$display("b20_beam_de_hold_tb start");
`ifdef FAULT_B20_BEAM_FREE_RUN
		$display("MODE FAULT_B20_BEAM_FREE_RUN (expect REPRO new DE early)");
`else
		$display("MODE product B20 beam DE hold");
`endif
		reset = 1;
		cand_w = OLD_W; cand_h = OLD_H;
		swap_pending = 0; pending_ready = 0;
		repeat (10) @(posedge clk);
		reset = 0;
		// Settle one full frame on OLD
		wait_fstarts(2);
		if (hde_a != OLD_W) begin
			$display("FAIL baseline hde=%0d want %0d", hde_a, OLD_W);
			$fatal(1);
		end
		$display("OK baseline DE=%0d", hde_a);

		// Promote candidate NEW (models present_geom_latch at VSync) while
		// DDR prep is NOT ready — swap_pending=1, pending_ready=0.
		cand_w = NEW_W; cand_h = NEW_H;
		swap_pending = 1;
		pending_ready = 0;
		// One fstart must pass with delayed ready
		wait_fstarts(1);
		hde_at_frame = hde_a;
`ifdef FAULT_B20_BEAM_FREE_RUN
		if (hde_at_frame != NEW_W) begin
			$display("FAIL RED free-run did not take NEW DE (got %0d)", hde_at_frame);
			$fatal(1);
		end
		$display("MEASURED FAULT REPRO_OK: hde=%0d NEW while pending_ready=0 (island class)", hde_at_frame);
		$display("PASS b20_beam_de_hold_tb RED free_run");
`else
		if (hde_at_frame != OLD_W) begin
			$display("FAIL held DE broke: hde=%0d want OLD %0d after delayed ready fstart",
				hde_at_frame, OLD_W);
			$fatal(1);
		end
		$display("OK hold OLD DE=%0d across fstart with pending_ready=0 (candidate was %0d)",
			hde_at_frame, NEW_W);

		// Now ready rises; next fstart is swap_fire — DE must become NEW
		pending_ready = 1;
		wait_fstarts(1);
		if (hde_a != NEW_W) begin
			$display("FAIL after swap_fire hde=%0d want NEW %0d", hde_a, NEW_W);
			$fatal(1);
		end
		$display("OK swap_fire applied NEW DE=%0d", hde_a);
		$display("PASS b20_beam_de_hold_tb GREEN hold");
`endif
		$finish;
	end
endmodule
`default_nettype wire
