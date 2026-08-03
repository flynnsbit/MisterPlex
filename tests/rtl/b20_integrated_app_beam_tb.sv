`timescale 1ps/1ps
// B20 integrated app-shadow + beam timing (rd-duck NBA lag).
//
// Models present_core coupling — NOT the older b20_beam_de_hold_tb which drives
// candidates straight into rt_* with level-qualified apply (blind to app NBA).
//
// Product timing:
//   visual_swap_ack = frame_start && swap_pending && pending_ready
//   app_* updates on visual_swap_ack (registered; sees fstart one clk after v_wrap)
//   beam latches rt_* at v_wrap (same edge that sets frame_start via NBA)
//
// GREEN (feed-forward): beam_src = armed ? cand : app
//   → v_wrap latches NEW DE; fstart promotes app/bank; no island frame.
// RED FAULT_B20_NO_BEAM_FEEDFORWARD: beam_src = app only
//   → v_wrap latches OLD DE; fstart promotes app; full frame NEW-app under OLD DE.
//   With product beam_hold, blackout covers that frame; without hold it paints island.
// RED FAULT_B20_NO_BEAM_HOLD + no feed-forward: live-vs-app hold clears at hc=1
//   → MEASURED island (hde_old while app_new && !black).
`default_nettype none
module b20_integrated_app_beam_tb;
	localparam int CLK_HALF = 25000;
	localparam int H_TOT = 80;
	localparam int V_TOT = 20;
	localparam int OLD_W = 32;
	localparam int OLD_H = 16;
	localparam int NEW_W = 48;
	localparam int NEW_H = 16;

	reg clk = 0;
	always #CLK_HALF clk = ~clk;
	reg reset = 1;

	// Live candidate (PLXG latch outputs)
	reg [10:0] content_w = OLD_W;
	reg [10:0] content_h = OLD_H;
	reg [15:0] geom_live_seq = 16'd1;
	reg        geom_live_valid = 1'b1;
	reg        swap_pending = 1'b0;
	reg        pending_ready = 1'b0;

	// --- present_core B20 shadow (mirrors product) ---
	reg [10:0] app_content_w;
	reg [10:0] app_content_h;
	reg [15:0] app_live_seq;
	reg        app_live_valid;

	wire frame_start;
	wire b20_ext = 1'b1; // product external-store path
	wire visual_swap_ack = frame_start && swap_pending && pending_ready;
	wire b20_swap_armed  = b20_ext && swap_pending && pending_ready;
	wire visual_geom_apply = visual_swap_ack; // ext path; ignore free/idle here

	always @(posedge clk) begin
		if (reset) begin
			app_content_w  <= OLD_W;
			app_content_h  <= OLD_H;
			app_live_seq   <= 16'd1;
			app_live_valid <= 1'b1;
		end else if (visual_geom_apply) begin
			app_content_w  <= content_w;
			app_content_h  <= content_h;
			app_live_seq   <= geom_live_seq;
			app_live_valid <= geom_live_valid;
		end
	end

	// Bank model: flips on same fstart ack as app (store vsync_pulse path)
	reg disp_bank;
	reg pending_bank;
	always @(posedge clk) begin
		if (reset) begin
			disp_bank <= 1'b0;
			pending_bank <= 1'b0;
		end else begin
			if (swap_pending && pending_ready && !frame_start)
				pending_bank <= 1'b1; // new bank waiting
			if (visual_swap_ack) begin
				disp_bank <= pending_bank;
				// clear pending like store
				// (TB drives swap_pending low after ack observed)
			end
		end
	end

`ifdef FAULT_B20_NO_BEAM_FEEDFORWARD
	wire [10:0] beam_src_w = app_content_w;
	wire [10:0] beam_src_h = app_content_h;
	wire [15:0] beam_src_seq = app_live_seq;
	wire        beam_src_valid = app_live_valid;
	localparam bit FEEDFORWARD = 0;
`else
	wire [10:0] beam_src_w = b20_swap_armed ? content_w : app_content_w;
	wire [10:0] beam_src_h = b20_swap_armed ? content_h : app_content_h;
	wire [15:0] beam_src_seq = b20_swap_armed ? geom_live_seq : app_live_seq;
	wire        beam_src_valid = b20_swap_armed ? geom_live_valid : app_live_valid;
	localparam bit FEEDFORWARD = 1;
`endif

	// beam_disp_seq: src delayed into registered frame_start (product)
	reg [15:0] beam_src_seq_d;
	reg        beam_src_valid_d;
	reg [15:0] beam_disp_seq;
	reg        beam_disp_valid;
	always @(posedge clk) begin
		if (reset) begin
			beam_src_seq_d   <= 16'd0;
			beam_src_valid_d <= 1'b0;
			beam_disp_seq    <= 16'd0;
			beam_disp_valid  <= 1'b0;
		end else begin
			beam_src_seq_d   <= beam_src_seq;
			beam_src_valid_d <= beam_src_valid;
			if (frame_start) begin
				beam_disp_seq   <= beam_src_seq_d;
				beam_disp_valid <= beam_src_valid_d;
			end
		end
	end

	wire b20_live_hold = b20_ext && geom_live_valid && (geom_live_seq != app_live_seq);
	wire b20_beam_hold = b20_ext && app_live_valid && beam_disp_valid &&
		(beam_disp_seq != app_live_seq);
`ifdef FAULT_B20_NO_BEAM_HOLD
	wire b20_visual_hold = b20_live_hold; // clears at hc=1 on ack
	localparam bit BEAM_HOLD = 0;
`else
	wire b20_visual_hold = b20_live_hold | b20_beam_hold;
	localparam bit BEAM_HOLD = 1;
`endif

	wire ce, hb, hs, vb, vs;
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
		.rt_h_de(beam_src_w),
		.rt_h_total(11'(H_TOT)),
		.rt_v_active(beam_src_h),
		.rt_de_apply(1'b1),
		.ce_pix(ce), .HBlank(hb), .HSync(hs), .VBlank(vb), .VSync(vs),
		.frame_start(frame_start),
		.hc_out(hc), .vc_out(vc),
		.vtot_active(vtot_a), .hde_active(hde_a),
		.htot_active(htot_a), .vact_active(vact_a)
	);

	wire in_de = ce && !hb && !vb;

	// Score one full frame after a swap fstart: island = NEW bank + OLD DE + !black
	integer island_px, black_px, de_px, frame_guard;
	reg scoring;
	reg [10:0] score_hde_first;
	reg        score_bank_first;
	reg        saw_fstart_swap;

	task automatic wait_fstarts;
		input integer n;
		integer g, got;
		reg fs_d;
		begin
			got = 0; g = 0; fs_d = 0;
			while (got < n && g < n * H_TOT * V_TOT * 4) begin
				@(posedge clk);
				g = g + 1;
				if (ce && frame_start && !fs_d) got = got + 1;
				fs_d = frame_start;
			end
			if (got < n) begin
				$display("FAIL timeout fstarts got=%0d want=%0d", got, n);
				$fatal(1);
			end
		end
	endtask

	// After armed, wait until we observe visual_swap_ack then score that frame.
	task automatic run_swap_and_score;
		integer g;
		reg fs_d;
		reg acked;
		begin
			scoring = 0;
			island_px = 0;
			black_px = 0;
			de_px = 0;
			score_hde_first = 11'd0;
			score_bank_first = 1'b0;
			saw_fstart_swap = 0;
			acked = 0;
			fs_d = 0;
			g = 0;
			// Wait for ack. Do NOT poke swap_pending in the same active region as
			// the ack edge — that races DUT NBA (Verilator may clear before app_*).
			while (!acked && g < H_TOT * V_TOT * 8) begin
				@(posedge clk);
				g = g + 1;
				if (visual_swap_ack) begin
					acked = 1;
					saw_fstart_swap = 1;
				end
			end
			if (!acked) begin
				$display("FAIL never saw visual_swap_ack");
				$fatal(1);
			end
			// Let DUT NBA settle; sample post-ack app/bank on the following cycle.
			@(posedge clk);
			#1;
			if (app_content_w != NEW_W) begin
				$display("FAIL app not NEW after ack settle w=%0d", app_content_w);
				$fatal(1);
			end
			// Store clears pending after consuming swap (next-cycle model)
			swap_pending = 0;
			pending_ready = 0;
			// Score this frame (hc may already be >0) through next fstart
			scoring = 1;
			fs_d = 0;
			g = 0;
			de_px = 0;
			island_px = 0;
			black_px = 0;
			while (scoring && g < H_TOT * V_TOT * 4) begin
				@(posedge clk);
				g = g + 1;
				if (ce && in_de) begin
					de_px = de_px + 1;
					if (de_px == 1) begin
						score_hde_first = hde_a;
						score_bank_first = disp_bank;
					end
					// Island: bank already NEW, DE still OLD, not blacked out
					if (disp_bank == 1'b1 && hde_a == OLD_W && !b20_visual_hold)
						island_px = island_px + 1;
					if (b20_visual_hold)
						black_px = black_px + 1;
				end
				if (ce && frame_start && !fs_d)
					scoring = 0;
				fs_d = frame_start;
			end
			if (scoring) begin
				$display("FAIL score window timeout");
				$fatal(1);
			end
		end
	endtask

	initial begin
		$display("b20_integrated_app_beam_tb start FEEDFORWARD=%0d BEAM_HOLD=%0d",
			FEEDFORWARD, BEAM_HOLD);
`ifdef FAULT_B20_NO_BEAM_FEEDFORWARD
		$display("MODE FAULT_B20_NO_BEAM_FEEDFORWARD");
`endif
`ifdef FAULT_B20_NO_BEAM_HOLD
		$display("MODE FAULT_B20_NO_BEAM_HOLD");
`endif
		reset = 1;
		content_w = OLD_W; content_h = OLD_H;
		geom_live_seq = 16'd1;
		swap_pending = 0; pending_ready = 0;
		repeat (8) @(posedge clk);
		reset = 0;
		wait_fstarts(2);
		if (hde_a != OLD_W) begin
			$display("FAIL baseline hde=%0d", hde_a);
			$fatal(1);
		end
		$display("OK baseline DE=%0d app=%0d", hde_a, app_content_w);

		// Park mid-frame so arming cannot race the next fstart in a tiny window
		begin : park_mid
			integer pg;
			pg = 0;
			while (!((hc > 11'(H_TOT/4)) && (vc > 11'(2)) && !frame_start) && pg < H_TOT * V_TOT) begin
				@(posedge clk);
				pg = pg + 1;
			end
			if (pg >= H_TOT * V_TOT) begin
				$display("FAIL could not park mid-frame");
				$fatal(1);
			end
		end

		// Promote live candidate NEW; arm swap (ready) mid-frame
		content_w = NEW_W; content_h = NEW_H;
		geom_live_seq = 16'd2;
		swap_pending = 1;
		pending_ready = 1;
		// Must not apply app mid-active (stay well before wrap)
		repeat (8) @(posedge clk);
		if (app_content_w != OLD_W) begin
			$display("FAIL mid-active app promoted early w=%0d hc=%0d vc=%0d fs=%0d",
				app_content_w, hc, vc, frame_start);
			$fatal(1);
		end
		if (visual_geom_apply) begin
			$display("FAIL mid-active visual_geom_apply=1");
			$fatal(1);
		end

		run_swap_and_score();

		$display("SCORE after swap: hde_first=%0d bank_first=%0d de_px=%0d island_px=%0d black_px=%0d app_w=%0d beam_disp_seq=%0d",
			score_hde_first, score_bank_first, de_px, island_px, black_px,
			app_content_w, beam_disp_seq);

		if (app_content_w != NEW_W || app_live_seq != 16'd2) begin
			$display("FAIL app did not take NEW on ack");
			$fatal(1);
		end
		if (disp_bank != 1'b1) begin
			$display("FAIL bank did not flip on ack");
			$fatal(1);
		end

`ifdef FAULT_B20_NO_BEAM_FEEDFORWARD
`ifdef FAULT_B20_NO_BEAM_HOLD
		// Island REPRO: OLD DE visible under NEW bank with hold cleared
		if (island_px == 0) begin
			$display("FAIL RED expected island_px>0 (got 0) hde_first=%0d", score_hde_first);
			$fatal(1);
		end
		if (score_hde_first != OLD_W) begin
			$display("FAIL RED expected OLD DE first, got %0d", score_hde_first);
			$fatal(1);
		end
		$display("MEASURED FAULT REPRO_OK island_px=%0d hde_old under bank_new !black", island_px);
		$display("PASS b20_integrated_app_beam_tb RED island");
`else
		// No feed-forward but beam_hold: must black the lag frame, zero island paint
		if (island_px != 0) begin
			$display("FAIL hold leaked island_px=%0d", island_px);
			$fatal(1);
		end
		if (score_hde_first != OLD_W) begin
			$display("FAIL expected OLD DE without feed-forward, got %0d", score_hde_first);
			$fatal(1);
		end
		if (black_px == 0) begin
			$display("FAIL expected blackout on lag frame");
			$fatal(1);
		end
		$display("OK no-feedforward + beam_hold: black_px=%0d island=0 OLD DE covered", black_px);
		// Next frame should take NEW DE
		wait_fstarts(1);
		if (hde_a != NEW_W) begin
			$display("FAIL next frame hde=%0d want NEW", hde_a);
			$fatal(1);
		end
		if (b20_visual_hold) begin
			$display("FAIL hold stuck after beam caught up");
			$fatal(1);
		end
		$display("OK beam caught NEW DE next wrap hold cleared");
		$display("PASS b20_integrated_app_beam_tb GREEN hold-cover");
`endif
`else
		// Product feed-forward: first DE of post-swap frame must be NEW, zero island
		if (island_px != 0) begin
			$display("FAIL product island_px=%0d", island_px);
			$fatal(1);
		end
		if (score_hde_first != NEW_W) begin
			$display("FAIL product hde_first=%0d want NEW %0d (feed-forward miss)",
				score_hde_first, NEW_W);
			$fatal(1);
		end
		if (b20_visual_hold) begin
			$display("FAIL product hold stuck after atomic swap frame");
			$fatal(1);
		end
		$display("OK product feed-forward: NEW DE same frame as NEW bank, island=0");
		$display("PASS b20_integrated_app_beam_tb GREEN feedforward");
`endif
		$finish;
	end
endmodule
`default_nettype wire
