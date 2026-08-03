// Integrated beam → rate_match → mock-store(LAT) → ordered tag → npx.
// GREEN: TAG_LAT==FS_LAT=4; DE pixels carry exact x/y in RGB; H_TOTAL slots; HS width.
// RED_BAD_LAT: FS_LAT = TAG_LAT+2 only on *store* — tag stays 4; must fail x/y or B.
// RED_DUAL_OR: dual-latency blank|DE OR (collision class).
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
	parameter int STORE_LAT    = 4,   // product MP_STORE_LAT
	parameter bit HAS_FRAME    = 1'b0,
	parameter bit RED_BAD_LAT  = 1'b0,
	parameter bit RED_DUAL_OR  = 1'b0,
	parameter int NUM_FRAMES   = 2
);
	localparam int PPC = PX_PER_CLK;
	localparam int TAG_LAT = STORE_LAT; // always product tag depth
	// RED_BAD_LAT delays *store only* — not the tag (breaks tautology).
	localparam int FS_LAT = RED_BAD_LAT ? (STORE_LAT + 2) : STORE_LAT;
	localparam int BLANK_LAT = 1;
	localparam int HS_W = H_SYNC_E - H_SYNC_S;
	localparam int GROUPS_PER_LINE = H_TOTAL / PPC;
	localparam int GROUPS_PER_FRAME = GROUPS_PER_LINE * V_TOTAL;

	reg clk = 1'b0;
	reg clk_pix = 1'b0;
	always #25000 clk = ~clk;
	always #16835 clk_pix = ~clk_pix;

	reg reset = 1'b1;
	// pix reset: async assert / sync deassert (product class)
	reg rst_pix0 = 1'b1, rst_pix1 = 1'b1;
	always @(posedge clk_pix or posedge reset) begin
		if (reset) begin rst_pix0 <= 1'b1; rst_pix1 <= 1'b1; end
		else begin rst_pix0 <= 1'b0; rst_pix1 <= rst_pix0; end
	end
	wire reset_pix = rst_pix1;

	wire in_ready;
	wire rate_fire;
	wire beam_en = ~reset & in_ready & rate_fire;

	present_pix_rate_match #(
		.F_SYS_HZ(20_000_000),
		.F_PIX_HZ(29_700_000),
		.PX_PER_CLK(PPC)
	) u_rate (
		.clk(clk), .reset(reset), .in_ready(in_ready), .fire(rate_fire)
	);

	wire beam_ce, hb, hs, vb, vs, fstart;
	wire [11:0] glass_x0, glass_y;
	wire [PPC-1:0] lane_de;

	present_beam_ppc #(
		.PX_PER_CLK(PPC),
		.H_DE(H_DE), .H_TOTAL(H_TOTAL),
		.V_ACTIVE(V_ACTIVE), .V_TOTAL(V_TOTAL),
		.H_SYNC_S(H_SYNC_S), .H_SYNC_E(H_SYNC_E),
		.V_SYNC_S(V_SYNC_S), .V_SYNC_E(V_SYNC_E)
	) u_beam (
		.clk(clk), .reset(reset), .enable(beam_en),
		.beam_ce(beam_ce),
		.glass_x0(glass_x0), .glass_y(glass_y), .lane_de(lane_de),
		.HBlank(hb), .HSync(hs), .VBlank(vb), .VSync(vs),
		.frame_start(fstart)
	);

	// ---- mock store: delay beam DE groups by FS_LAT; RGB encodes x/y ----
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
	// Latency-tagged coordinates on RGB (oracle):
	//   R[lane] = fs_x[7:0] + lane
	//   G       = fs_y[7:0]
	//   B       = 8'hA5
	wire [PPC*8-1:0] fs_r_n, fs_g_n, fs_b_n;
	genvar gi;
	generate
		for (gi = 0; gi < PPC; gi = gi + 1) begin : gfs
			assign fs_r_n[gi*8 +: 8] = fs_x[7:0] + gi[7:0];
			assign fs_g_n[gi*8 +: 8] = fs_y[7:0];
			assign fs_b_n[gi*8 +: 8] = 8'hA5;
		end
	endgenerate

	// ---- ordered tag pipe (TAG_LAT fixed; carries expected x/y for score) ----
	reg [TAG_LAT-1:0] tq_v;
	reg tq_hb [0:TAG_LAT-1], tq_hs [0:TAG_LAT-1], tq_vb [0:TAG_LAT-1], tq_vs [0:TAG_LAT-1];
	reg [PPC-1:0] tq_lde [0:TAG_LAT-1];
	reg [11:0] tq_x [0:TAG_LAT-1];
	reg [11:0] tq_y [0:TAG_LAT-1];
	integer ti;
	always @(posedge clk) begin
		if (reset) begin
			tq_v <= '0;
			for (ti = 0; ti < TAG_LAT; ti = ti + 1) begin
				tq_hb[ti] <= 1'b1; tq_hs[ti] <= 1'b0;
				tq_vb[ti] <= 1'b1; tq_vs[ti] <= 1'b0;
				tq_lde[ti] <= '0;
				tq_x[ti] <= '0; tq_y[ti] <= '0;
			end
		end else begin
			for (ti = TAG_LAT-1; ti > 0; ti = ti - 1) begin
				tq_v[ti]   <= tq_v[ti-1];
				tq_hb[ti]  <= tq_hb[ti-1];
				tq_hs[ti]  <= tq_hs[ti-1];
				tq_vb[ti]  <= tq_vb[ti-1];
				tq_vs[ti]  <= tq_vs[ti-1];
				tq_lde[ti] <= tq_lde[ti-1];
				tq_x[ti]   <= tq_x[ti-1];
				tq_y[ti]   <= tq_y[ti-1];
			end
			tq_v[0]   <= beam_ce;
			tq_hb[0]  <= beam_ce ? hb : 1'b1;
			tq_hs[0]  <= beam_ce ? hs : 1'b0;
			tq_vb[0]  <= beam_ce ? vb : 1'b1;
			tq_vs[0]  <= beam_ce ? vs : 1'b0;
			tq_lde[0] <= beam_ce ? lane_de : '0;
			tq_x[0]   <= glass_x0;
			tq_y[0]   <= glass_y;
		end
	end

	// broken blank path
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
				bq_v[bi] <= bq_v[bi-1];
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
	wire [11:0] tag_x = tq_x[TAG_LAT-1];
	wire [11:0] tag_y = tq_y[TAG_LAT-1];

	wire npx_valid = RED_DUAL_OR ? (act_push | blank_push) : ord_push;
	wire coll_drop = RED_DUAL_OR && act_push && blank_push;
	wire use_fs = RED_DUAL_OR
		? (act_push && fs_n_valid)
		: (ord_push && ord_push_de && fs_n_valid);

	// When LAT matches, fs_x/y must equal tag_x/y on DE pushes.
	wire lat_xy_match = !ord_push_de || (fs_x == tag_x && fs_y == tag_y);
	integer lat_mismatch;
	always @(posedge clk) begin
		if (reset) lat_mismatch <= 0;
		else if (HAS_FRAME && ord_push && ord_push_de && fs_n_valid && !lat_xy_match)
			lat_mismatch <= lat_mismatch + 1;
	end

	wire [PPC*8-1:0] npx_r = use_fs ? fs_r_n : '0;
	wire [PPC*8-1:0] npx_g = use_fs ? fs_g_n : '0;
	wire [PPC*8-1:0] npx_b = use_fs ? fs_b_n : '0;
	wire [PPC-1:0] npx_lv = npx_valid ? {PPC{1'b1}} : '0;

	wire npx_hb = RED_DUAL_OR ? (act_push ? tq_hb[TAG_LAT-1] : bq_hb[BLANK_LAT-1]) : tq_hb[TAG_LAT-1];
	wire npx_hs = RED_DUAL_OR ? (act_push ? tq_hs[TAG_LAT-1] : bq_hs[BLANK_LAT-1]) : tq_hs[TAG_LAT-1];
	wire npx_vb = RED_DUAL_OR ? (act_push ? tq_vb[TAG_LAT-1] : bq_vb[BLANK_LAT-1]) : tq_vb[TAG_LAT-1];
	wire npx_vs = RED_DUAL_OR ? (act_push ? tq_vs[TAG_LAT-1] : bq_vs[BLANK_LAT-1]) : tq_vs[TAG_LAT-1];

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
		.PX_PER_CLK(PPC), .FIFO_AW(6), .INCLUDE_SYNC(1'b1), .PREFILL_GROUPS(8)
	) u_npx (
		.clk_sys(clk), .reset_sys(reset),
		.clk_pix(clk_pix), .reset_pix(reset_pix),
		.in_valid(npx_valid), .in_r(npx_r), .in_g(npx_g), .in_b(npx_b),
		.in_lane_valid(npx_lv),
		.in_hblank(npx_hb), .in_hsync(npx_hs), .in_vblank(npx_vb), .in_vsync(npx_vs),
		.in_ready(in_ready),
		.out_ce(out_ce), .out_r(out_r), .out_g(out_g), .out_b(out_b),
		.out_hblank(out_hb), .out_hsync(out_hs), .out_vblank(out_vb), .out_vsync(out_vs),
		.wr_full(wr_full), .wr_almost_full(wr_af),
		.rd_underrun(rd_ur), .rd_empty(rd_empty)
	);

	// ---- score ----
	integer act_px, ur_score, hs_rise, vs_rise;
	integer line_slots, lines_exact, bad_line;
	integer hs_high_run, hs_width_seen, bad_hs_w;
	integer out_slots_total, xy_fail, de_edge_fail, black_de;
	reg out_hs_d, out_vs_d, out_hb_d, out_de_d;
	reg scoring;
	integer exp_slots_rem;
	// reconstruct DE x/y from output stream (locked after first DE)
	integer de_x, de_y;
	reg de_locked;

	wire out_de = out_ce && !out_hb && !out_vb;

	always @(posedge clk_pix) begin
		if (reset_pix) begin
			act_px <= 0; ur_score <= 0; hs_rise <= 0; vs_rise <= 0;
			line_slots <= 0; lines_exact <= 0; bad_line <= 0;
			hs_high_run <= 0; hs_width_seen <= 0; bad_hs_w <= 0;
			out_slots_total <= 0; xy_fail <= 0; de_edge_fail <= 0; black_de <= 0;
			out_hs_d <= 0; out_vs_d <= 0; out_hb_d <= 1; out_de_d <= 0;
			scoring <= 0;
			exp_slots_rem <= H_TOTAL * V_TOTAL * NUM_FRAMES;
			de_x <= 0; de_y <= 0; de_locked <= 0;
		end else begin
			if (out_ce) begin
				scoring <= 1'b1;
				out_slots_total <= out_slots_total + 1;
				if (exp_slots_rem > 0)
					exp_slots_rem <= exp_slots_rem - 1;

				// exact H_TOTAL slots/line once streaming
				if (line_slots + 1 == H_TOTAL) begin
					lines_exact <= lines_exact + 1;
					line_slots <= 0;
				end else if (line_slots + 1 > H_TOTAL) begin
					bad_line <= bad_line + 1;
					line_slots <= 0;
				end else
					line_slots <= line_slots + 1;

				if (out_de) begin
					act_px <= act_px + 1;
					if (HAS_FRAME && !RED_DUAL_OR && out_b !== 8'hA5)
						black_de <= black_de + 1;
					if (!de_locked) begin
						de_locked <= 1'b1;
						de_x <= 1;
						de_y <= 0;
						if (HAS_FRAME && !RED_DUAL_OR && !RED_BAD_LAT) begin
							if (out_b !== 8'hA5 || out_g !== 8'd0 || out_r !== 8'd0)
								xy_fail <= xy_fail + 1;
						end
					end else begin
						if (HAS_FRAME && !RED_DUAL_OR && !RED_BAD_LAT) begin
							if (out_b !== 8'hA5)
								xy_fail <= xy_fail + 1;
							if (out_g !== de_y[7:0])
								xy_fail <= xy_fail + 1;
							if (out_r !== de_x[7:0])
								xy_fail <= xy_fail + 1;
						end
						if (de_x + 1 >= H_DE) begin
							de_x <= 0;
							de_y <= de_y + 1;
						end else
							de_x <= de_x + 1;
					end
				end else if (!HAS_FRAME && !RED_DUAL_OR && !out_hb && !out_vb) begin
					if (out_r !== 0 || out_g !== 0 || out_b !== 0)
						xy_fail <= xy_fail + 1;
				end

				// DE edge: entering DE must be x=0 after blank (line wrap already sets)
				if (out_de && !out_de_d && de_locked && HAS_FRAME && !RED_DUAL_OR && !RED_BAD_LAT) begin
					// rising DE: x should be 0 (we haven't advanced yet this cycle — check R)
					if (out_r !== 8'd0)
						de_edge_fail <= de_edge_fail + 1;
				end

				if (out_hs && !out_hs_d) hs_rise <= hs_rise + 1;
				if (out_vs && !out_vs_d) begin
					vs_rise <= vs_rise + 1;
					// new frame: resync DE x/y oracle
					de_x <= 0;
					de_y <= 0;
					de_locked <= 1'b0;
				end
				if (out_hs) hs_high_run <= hs_high_run + 1;
				else if (out_hs_d && hs_high_run > 0) begin
					if (hs_width_seen == 0) hs_width_seen <= hs_high_run;
					if (hs_high_run != HS_W) bad_hs_w <= bad_hs_w + 1;
					hs_high_run <= 0;
				end
				out_hs_d <= out_hs;
				out_vs_d <= out_vs;
				out_hb_d <= out_hb;
				out_de_d <= out_de;
			end
			if (rd_ur && scoring && (exp_slots_rem > 0))
				ur_score <= ur_score + 1;
		end
	end

	integer cycles, frames_seen;
	initial begin
		if (H_TOTAL % PPC != 0) begin $display("FAIL H_TOTAL%%PPC"); $fatal(1); end
		cycles = 0; frames_seen = 0;
		repeat (40) @(posedge clk);
		reset = 0;
		while (frames_seen < (NUM_FRAMES + 1) && cycles < 20_000_000) begin
			@(posedge clk);
			cycles = cycles + 1;
			if (fstart) frames_seen = frames_seen + 1;
		end
		repeat (200_000) @(posedge clk);

		if (RED_DUAL_OR) begin
			if (coll_count == 0 && push_count >= beam_ce_count) begin
				$display("FAIL RED_DUAL_OR no drop coll=%0d push=%0d beam=%0d",
					coll_count, push_count, beam_ce_count);
				$fatal(1);
			end
			$display("PASS present_mp_integrated RED_DUAL_OR coll=%0d push=%0d",
				coll_count, push_count);
			$finish;
		end

		if (RED_BAD_LAT) begin
			// Store-only extra LAT → DE black and/or tag≠fs coords
			if (black_de == 0 && lat_mismatch == 0) begin
				$display("FAIL RED_BAD_LAT no damage black_de=%0d lat_mis=%0d act=%0d",
					black_de, lat_mismatch, act_px);
				$fatal(1);
			end
			$display("PASS present_mp_integrated RED_BAD_LAT black_de=%0d lat_mis=%0d fs_lat=%0d tag_lat=%0d",
				black_de, lat_mismatch, FS_LAT, TAG_LAT);
			$finish;
		end

		// GREEN
		if (ur_score != 0) begin $display("FAIL ur=%0d", ur_score); $fatal(1); end
		if (out_slots_total < (H_TOTAL * V_TOTAL * NUM_FRAMES)) begin
			$display("FAIL slots=%0d", out_slots_total); $fatal(1);
		end
		if (lines_exact < (V_TOTAL * NUM_FRAMES - 2)) begin
			$display("FAIL lines_exact=%0d want H_TOTAL=%0d", lines_exact, H_TOTAL); $fatal(1);
		end
		if (bad_line != 0) begin $display("FAIL bad_line=%0d", bad_line); $fatal(1); end
		if (hs_width_seen != HS_W) begin
			$display("FAIL hsw=%0d want %0d", hs_width_seen, HS_W); $fatal(1);
		end
		if (HAS_FRAME) begin
			if (black_de != 0) begin $display("FAIL black_de=%0d", black_de); $fatal(1); end
			if (xy_fail != 0) begin $display("FAIL xy_fail=%0d", xy_fail); $fatal(1); end
			if (lat_mismatch != 0) begin $display("FAIL lat_mismatch=%0d", lat_mismatch); $fatal(1); end
			if (act_px < (H_DE * V_ACTIVE * NUM_FRAMES) / 2) begin
				$display("FAIL act=%0d", act_px); $fatal(1);
			end
			$display("PASS present_mp_integrated FRAME act=%0d slots=%0d lines=%0d hsw=%0d xy=0 lat=0",
				act_px, out_slots_total, lines_exact, hs_width_seen);
		end else begin
			if (xy_fail != 0) begin $display("FAIL black xy_fail=%0d", xy_fail); $fatal(1); end
			$display("PASS present_mp_integrated NO_FRAME act=%0d slots=%0d hsw=%0d black",
				act_px, out_slots_total, hs_width_seen);
		end
		$finish;
	end
endmodule
`default_nettype wire
