// Integrated beam → mock-store → ordered tag → npx (rd-duck integration class).
//
// GREEN_NO_FRAME / GREEN_FRAME:
//   Single ordered pipeline (LAT) for *all* groups — blank and DE share latency.
//   Uses real present_pix_rate_match. Continuous multi-frame source (never
//   stops mid-score). Asserts H_TOTAL out slots/line + HS width + mid-stream ur=0.
//
// RED_DUAL_OR:
//   Intentionally broken dual latency: blank ~1 cyc, DE response LAT cyc, OR'd
//   into one valid. Proves group drop / slot shortfall (rd-duck defect class).
//   Must FAIL the slot/group accounting check (test expects RED PASS message).
//
// RED_BAD_LAT: store RGB LAT mismatched vs tag (content wrong; optional).
`timescale 1ps/1ps
`default_nettype none

module present_mp_integrated_tb #(
	parameter int PX_PER_CLK   = 2,
	parameter int H_DE         = 1280,
	parameter int H_TOTAL      = 1650,
	parameter int V_ACTIVE     = 8,
	parameter int V_TOTAL      = 12,
	parameter int H_SYNC_S     = 1390,
	parameter int H_SYNC_E     = 1430,
	parameter int V_SYNC_S     = 9,
	parameter int V_SYNC_E     = 11,
	parameter int STORE_LAT    = 4,
	parameter bit HAS_FRAME    = 1'b0,
	parameter bit RED_BAD_LAT  = 1'b0,
	parameter bit RED_DUAL_OR  = 1'b0,
	parameter int NUM_FRAMES   = 2
);
	localparam int PPC = PX_PER_CLK;
	localparam int TAG_LAT = STORE_LAT;
	localparam int BLANK_LAT = 1;
	localparam int FS_LAT = RED_BAD_LAT ? (STORE_LAT + 2) : STORE_LAT;
	localparam int HS_W = H_SYNC_E - H_SYNC_S;
	localparam int GROUPS_PER_LINE = H_TOTAL / PPC;
	localparam int GROUPS_PER_FRAME = GROUPS_PER_LINE * V_TOTAL;

	reg clk = 1'b0;
	reg clk_pix = 1'b0;
	always #25000 clk = ~clk;
	always #16835 clk_pix = ~clk_pix;

	reg reset = 1'b1;
	wire in_ready;
	wire rate_fire;
	wire beam_en = ~reset & in_ready & rate_fire;

	present_pix_rate_match #(
		.F_SYS_HZ(20_000_000),
		.F_PIX_HZ(29_700_000),
		.PX_PER_CLK(PPC)
	) u_rate (
		.clk(clk),
		.reset(reset),
		.in_ready(in_ready),
		.fire(rate_fire)
	);

	wire beam_ce, hb, hs, vb, vs, fstart;
	wire [11:0] glass_x0, glass_y;
	wire [PPC-1:0] lane_de;

	present_beam_ppc #(
		.PX_PER_CLK(PPC),
		.H_DE(H_DE),
		.H_TOTAL(H_TOTAL),
		.V_ACTIVE(V_ACTIVE),
		.V_TOTAL(V_TOTAL),
		.H_SYNC_S(H_SYNC_S),
		.H_SYNC_E(H_SYNC_E),
		.V_SYNC_S(V_SYNC_S),
		.V_SYNC_E(V_SYNC_E)
	) u_beam (
		.clk(clk),
		.reset(reset),
		.enable(beam_en),
		.beam_ce(beam_ce),
		.glass_x0(glass_x0),
		.glass_y(glass_y),
		.lane_de(lane_de),
		.HBlank(hb),
		.HSync(hs),
		.VBlank(vb),
		.VSync(vs),
		.frame_start(fstart)
	);

	reg [FS_LAT-1:0] m_v, m_de;
	reg [11:0] m_x [0:FS_LAT-1];
	reg [11:0] m_y [0:FS_LAT-1];
	integer li;
	always @(posedge clk) begin
		if (reset) begin
			m_v <= '0; m_de <= '0;
			for (li = 0; li < FS_LAT; li = li + 1) begin
				m_x[li] <= '0; m_y[li] <= '0;
			end
		end else begin
			for (li = FS_LAT-1; li > 0; li = li - 1) begin
				m_v[li]  <= m_v[li-1];
				m_de[li] <= m_de[li-1];
				m_x[li]  <= m_x[li-1];
				m_y[li]  <= m_y[li-1];
			end
			m_v[0]  <= beam_ce;
			m_de[0] <= beam_ce && (|lane_de);
			m_x[0]  <= glass_x0;
			m_y[0]  <= glass_y;
		end
	end
	wire fs_n_valid = HAS_FRAME && m_v[FS_LAT-1] && m_de[FS_LAT-1];
	wire [11:0] fs_x = m_x[FS_LAT-1];
	wire [11:0] fs_y = m_y[FS_LAT-1];
	wire [PPC*8-1:0] fs_r_n, fs_g_n, fs_b_n;
	genvar gi;
	generate
		for (gi = 0; gi < PPC; gi = gi + 1) begin : gfs
			assign fs_r_n[gi*8 +: 8] = fs_x[7:0] + gi[7:0];
			assign fs_g_n[gi*8 +: 8] = fs_y[7:0];
			assign fs_b_n[gi*8 +: 8] = 8'hA5;
		end
	endgenerate

	reg [TAG_LAT-1:0] tq_v;
	reg tq_hb [0:TAG_LAT-1], tq_hs [0:TAG_LAT-1], tq_vb [0:TAG_LAT-1], tq_vs [0:TAG_LAT-1];
	reg [PPC-1:0] tq_lde [0:TAG_LAT-1];
	integer ti;
	always @(posedge clk) begin
		if (reset) begin
			tq_v <= '0;
			for (ti = 0; ti < TAG_LAT; ti = ti + 1) begin
				tq_hb[ti] <= 1'b1; tq_hs[ti] <= 1'b0;
				tq_vb[ti] <= 1'b1; tq_vs[ti] <= 1'b0;
				tq_lde[ti] <= '0;
			end
		end else begin
			for (ti = TAG_LAT-1; ti > 0; ti = ti - 1) begin
				tq_v[ti]   <= tq_v[ti-1];
				tq_hb[ti]  <= tq_hb[ti-1];
				tq_hs[ti]  <= tq_hs[ti-1];
				tq_vb[ti]  <= tq_vb[ti-1];
				tq_vs[ti]  <= tq_vs[ti-1];
				tq_lde[ti] <= tq_lde[ti-1];
			end
			tq_v[0]   <= beam_ce;
			tq_hb[0]  <= beam_ce ? hb : 1'b1;
			tq_hs[0]  <= beam_ce ? hs : 1'b0;
			tq_vb[0]  <= beam_ce ? vb : 1'b1;
			tq_vs[0]  <= beam_ce ? vs : 1'b0;
			tq_lde[0] <= beam_ce ? lane_de : '0;
		end
	end

	reg [BLANK_LAT-1:0] bq_v;
	reg bq_hb [0:BLANK_LAT-1], bq_hs [0:BLANK_LAT-1], bq_vb [0:BLANK_LAT-1], bq_vs [0:BLANK_LAT-1];
	integer bi;
	always @(posedge clk) begin
		if (reset) begin
			bq_v <= '0;
			for (bi = 0; bi < BLANK_LAT; bi = bi + 1) begin
				bq_hb[bi] <= 1'b1; bq_hs[bi] <= 1'b0;
				bq_vb[bi] <= 1'b1; bq_vs[bi] <= 1'b0;
			end
		end else begin
			for (bi = BLANK_LAT-1; bi > 0; bi = bi - 1) begin
				bq_v[bi]  <= bq_v[bi-1];
				bq_hb[bi] <= bq_hb[bi-1];
				bq_hs[bi] <= bq_hs[bi-1];
				bq_vb[bi] <= bq_vb[bi-1];
				bq_vs[bi] <= bq_vs[bi-1];
			end
			bq_v[0]  <= beam_ce && !(|lane_de);
			bq_hb[0] <= beam_ce ? hb : 1'b1;
			bq_hs[0] <= beam_ce ? hs : 1'b0;
			bq_vb[0] <= beam_ce ? vb : 1'b1;
			bq_vs[0] <= beam_ce ? vs : 1'b0;
		end
	end

	wire ord_push    = tq_v[TAG_LAT-1];
	wire ord_push_de = |tq_lde[TAG_LAT-1];
	wire blank_push  = bq_v[BLANK_LAT-1];
	wire act_push    = tq_v[TAG_LAT-1] && ord_push_de;

	wire npx_valid = RED_DUAL_OR ? (act_push | blank_push) : ord_push;
	wire coll_drop = RED_DUAL_OR && act_push && blank_push;

	wire use_fs = RED_DUAL_OR
		? (act_push && fs_n_valid)
		: (ord_push && ord_push_de && fs_n_valid);

	wire [PPC*8-1:0] npx_r = use_fs ? fs_r_n : '0;
	wire [PPC*8-1:0] npx_g = use_fs ? fs_g_n : '0;
	wire [PPC*8-1:0] npx_b = use_fs ? fs_b_n : '0;
	wire [PPC-1:0] npx_lv = npx_valid ? {PPC{1'b1}} : '0;

	wire npx_hb = RED_DUAL_OR
		? (act_push ? tq_hb[TAG_LAT-1] : bq_hb[BLANK_LAT-1])
		: tq_hb[TAG_LAT-1];
	wire npx_hs = RED_DUAL_OR
		? (act_push ? tq_hs[TAG_LAT-1] : bq_hs[BLANK_LAT-1])
		: tq_hs[TAG_LAT-1];
	wire npx_vb = RED_DUAL_OR
		? (act_push ? tq_vb[TAG_LAT-1] : bq_vb[BLANK_LAT-1])
		: tq_vb[TAG_LAT-1];
	wire npx_vs = RED_DUAL_OR
		? (act_push ? tq_vs[TAG_LAT-1] : bq_vs[BLANK_LAT-1])
		: tq_vs[TAG_LAT-1];

	integer push_count, coll_count, beam_ce_count;
	always @(posedge clk) begin
		if (reset) begin
			push_count <= 0; coll_count <= 0; beam_ce_count <= 0;
		end else begin
			if (beam_ce) beam_ce_count <= beam_ce_count + 1;
			if (npx_valid) push_count <= push_count + 1;
			if (coll_drop) coll_count <= coll_count + 1;
		end
	end

	wire out_ce, out_hb, out_hs, out_vb, out_vs, rd_ur, rd_empty;
	wire [7:0] out_r, out_g, out_b;
	wire wr_full, wr_af;

	present_npx_path #(
		.PX_PER_CLK(PPC),
		.FIFO_AW(6),
		.INCLUDE_SYNC(1'b1),
		.PREFILL_GROUPS(8)
	) u_npx (
		.clk_sys(clk),
		.reset_sys(reset),
		.clk_pix(clk_pix),
		.reset_pix(reset),
		.in_valid(npx_valid),
		.in_r(npx_r),
		.in_g(npx_g),
		.in_b(npx_b),
		.in_lane_valid(npx_lv),
		.in_hblank(npx_hb),
		.in_hsync(npx_hs),
		.in_vblank(npx_vb),
		.in_vsync(npx_vs),
		.in_ready(in_ready),
		.out_ce(out_ce),
		.out_r(out_r),
		.out_g(out_g),
		.out_b(out_b),
		.out_hblank(out_hb),
		.out_hsync(out_hs),
		.out_vblank(out_vb),
		.out_vsync(out_vs),
		.wr_full(wr_full),
		.wr_almost_full(wr_af),
		.rd_underrun(rd_ur),
		.rd_empty(rd_empty)
	);

	integer act_px, ur_score, hs_rise, vs_rise;
	integer line_slots, lines_done, bad_line_slots;
	integer hs_high_run, hs_width_seen, bad_hs_w;
	integer out_slots_total;
	reg out_hs_d, out_vs_d;
	reg scoring;
	integer exp_slots_rem;

	always @(posedge clk_pix) begin
		if (reset) begin
			act_px <= 0; ur_score <= 0; hs_rise <= 0; vs_rise <= 0;
			line_slots <= 0; lines_done <= 0; bad_line_slots <= 0;
			hs_high_run <= 0; hs_width_seen <= 0; bad_hs_w <= 0;
			out_slots_total <= 0;
			out_hs_d <= 0; out_vs_d <= 0;
			scoring <= 0;
			exp_slots_rem <= H_TOTAL * V_TOTAL * NUM_FRAMES;
		end else begin
			if (out_ce) begin
				scoring <= 1'b1;
				out_slots_total <= out_slots_total + 1;
				if (exp_slots_rem > 0)
					exp_slots_rem <= exp_slots_rem - 1;

				if (line_slots + 1 >= H_TOTAL) begin
					if (line_slots + 1 == H_TOTAL)
						lines_done <= lines_done + 1;
					else
						bad_line_slots <= bad_line_slots + 1;
					line_slots <= 0;
				end else begin
					line_slots <= line_slots + 1;
				end

				if (!out_hb && !out_vb) begin
					act_px <= act_px + 1;
					if (HAS_FRAME && !RED_DUAL_OR) begin
						if (out_b !== 8'hA5) begin
							$display("FAIL frame RGB b=%02x act=%0d", out_b, act_px + 1);
							$fatal(1);
						end
					end else if (!HAS_FRAME && !RED_DUAL_OR) begin
						if (out_r !== 8'd0 || out_g !== 8'd0 || out_b !== 8'd0) begin
							$display("FAIL no-frame black got %02x%02x%02x", out_r, out_g, out_b);
							$fatal(1);
						end
					end
				end

				if (out_hs && !out_hs_d)
					hs_rise <= hs_rise + 1;
				if (out_vs && !out_vs_d)
					vs_rise <= vs_rise + 1;

				if (out_hs) begin
					hs_high_run <= hs_high_run + 1;
				end else if (out_hs_d && hs_high_run > 0) begin
					if (hs_width_seen == 0)
						hs_width_seen <= hs_high_run;
					if (hs_high_run != HS_W)
						bad_hs_w <= bad_hs_w + 1;
					hs_high_run <= 0;
				end

				out_hs_d <= out_hs;
				out_vs_d <= out_vs;
			end
			if (rd_ur && scoring && (exp_slots_rem > 0))
				ur_score <= ur_score + 1;
		end
	end

	integer cycles, frames_seen;
	integer exp_beam_groups;
	initial begin
		if (H_TOTAL % PPC != 0) begin
			$display("FAIL H_TOTAL %% PPC");
			$fatal(1);
		end
		cycles = 0; frames_seen = 0;
		repeat (40) @(posedge clk);
		reset = 0;

		while (frames_seen < (NUM_FRAMES + 1) && cycles < 20_000_000) begin
			@(posedge clk);
			cycles = cycles + 1;
			if (fstart) frames_seen = frames_seen + 1;
		end
		repeat (200_000) @(posedge clk);

		exp_beam_groups = GROUPS_PER_FRAME * NUM_FRAMES;

		if (RED_DUAL_OR) begin
			if (coll_count == 0 && push_count >= beam_ce_count) begin
				$display("FAIL RED_DUAL_OR expected collision/drop coll=%0d push=%0d beam_ce=%0d",
					coll_count, push_count, beam_ce_count);
				$fatal(1);
			end
			if (out_slots_total >= (H_TOTAL * V_TOTAL * NUM_FRAMES) && coll_count == 0) begin
				$display("FAIL RED_DUAL_OR no observable damage slots=%0d coll=%0d",
					out_slots_total, coll_count);
				$fatal(1);
			end
			$display("PASS present_mp_integrated RED_DUAL_OR coll=%0d push=%0d slots=%0d beam_ce=%0d",
				coll_count, push_count, out_slots_total, beam_ce_count);
			$finish;
		end

		if (ur_score != 0) begin
			$display("FAIL mid-window underrun ur=%0d", ur_score);
			$fatal(1);
		end
		if (out_slots_total < (H_TOTAL * V_TOTAL * NUM_FRAMES)) begin
			$display("FAIL slots=%0d want>=%0d", out_slots_total, H_TOTAL * V_TOTAL * NUM_FRAMES);
			$fatal(1);
		end
		if (lines_done < (V_TOTAL * NUM_FRAMES - 2)) begin
			$display("FAIL lines_done=%0d", lines_done);
			$fatal(1);
		end
		if (bad_line_slots != 0) begin
			$display("FAIL bad_line_slots=%0d", bad_line_slots);
			$fatal(1);
		end
		if (hs_rise < (V_TOTAL * NUM_FRAMES - 2)) begin
			$display("FAIL hs_rise=%0d", hs_rise);
			$fatal(1);
		end
		if (hs_width_seen != HS_W) begin
			$display("FAIL hs_width_seen=%0d want %0d bad_hs_w=%0d", hs_width_seen, HS_W, bad_hs_w);
			$fatal(1);
		end
		if (act_px < (H_DE * V_ACTIVE * NUM_FRAMES) / 2) begin
			$display("FAIL act_px=%0d", act_px);
			$fatal(1);
		end
		if (push_count + TAG_LAT + 8 < beam_ce_count) begin
			$display("FAIL push starved push=%0d beam_ce=%0d", push_count, beam_ce_count);
			$fatal(1);
		end

		if (HAS_FRAME)
			$display("PASS present_mp_integrated FRAME act=%0d slots=%0d hs=%0d hsw=%0d ur=0 lines=%0d",
				act_px, out_slots_total, hs_rise, hs_width_seen, lines_done);
		else
			$display("PASS present_mp_integrated NO_FRAME act=%0d slots=%0d hs=%0d hsw=%0d ur=0 black",
				act_px, out_slots_total, hs_rise, hs_width_seen);
		$finish;
	end
endmodule
`default_nettype wire
