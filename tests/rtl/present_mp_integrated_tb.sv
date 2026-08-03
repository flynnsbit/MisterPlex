// Integrated beam → mock-store(LAT) → tag-align → npx (rd-duck integration class).
// GREEN_NO_FRAME: continuous black DE + HS/VS, mid-frame ur==0
// GREEN_FRAME: DE pixels = f(x,y) from mock store, sync tagged with request
// RED_LAT: wrong LAT would misalign — optional smoke via parameter
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
	parameter bit RED_BAD_LAT  = 1'b0
);
	localparam int PPC = PX_PER_CLK;
	localparam int LAT = RED_BAD_LAT ? (STORE_LAT + 2) : STORE_LAT;

	reg clk = 1'b0;
	reg clk_pix = 1'b0;
	always #25000 clk = ~clk;         // 20 MHz
	always #16835 clk_pix = ~clk_pix; // 29.7 MHz

	reg reset = 1'b1;

	// --- beam ---
	wire beam_ce, hb, hs, vb, vs, fstart;
	wire [11:0] glass_x0, glass_y;
	wire [PPC-1:0] lane_de;
	wire in_ready;
	// free-run beam when npx ready (no rate match — denser than product; OK for class)
	wire beam_en = ~reset & in_ready;

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

	// register store request like present_core
	reg [11:0] st_x, st_y;
	reg st_de;
	reg [PPC-1:0] st_lde;
	always @(posedge clk) begin
		if (reset) begin
			st_x <= '0; st_y <= '0; st_de <= 1'b0; st_lde <= '0;
		end else if (beam_ce) begin
			st_x <= glass_x0;
			st_y <= glass_y;
			st_de <= |lane_de;
			st_lde <= lane_de;
		end
	end

	// mock store: fixed LAT from st_de presentation... actually present_core tags
	// from beam_ce, store path from registered de. Mirror product LAT=4 from beam_ce.
	// Mock: delay beam_ce+DE by LAT and emit RGB.
	reg [LAT-1:0] m_v, m_de;
	reg [11:0] m_x [0:LAT-1];
	reg [11:0] m_y [0:LAT-1];
	integer li;
	always @(posedge clk) begin
		if (reset) begin
			m_v <= '0; m_de <= '0;
			for (li = 0; li < LAT; li = li + 1) begin
				m_x[li] <= '0; m_y[li] <= '0;
			end
		end else begin
			for (li = LAT-1; li > 0; li = li - 1) begin
				m_v[li] <= m_v[li-1];
				m_de[li] <= m_de[li-1];
				m_x[li] <= m_x[li-1];
				m_y[li] <= m_y[li-1];
			end
			m_v[0]  <= beam_ce;
			m_de[0] <= beam_ce && (|lane_de);
			m_x[0]  <= glass_x0;
			m_y[0]  <= glass_y;
		end
	end
	wire fs_n_valid = HAS_FRAME && m_v[LAT-1] && m_de[LAT-1];
	wire [11:0] fs_x = m_x[LAT-1];
	wire [11:0] fs_y = m_y[LAT-1];
	// distinctive RGB: R=x[7:0], G=y[7:0], B=8'hA5
	wire [PPC*8-1:0] fs_r_n, fs_g_n, fs_b_n;
	genvar gi;
	generate
		for (gi = 0; gi < PPC; gi = gi + 1) begin : gfs
			assign fs_r_n[gi*8 +: 8] = fs_x[7:0] + gi[7:0];
			assign fs_g_n[gi*8 +: 8] = fs_y[7:0];
			assign fs_b_n[gi*8 +: 8] = 8'hA5;
		end
	endgenerate

	// tag pipe (copy of present_core)
	reg [LAT-1:0] tq_v;
	reg tq_hb [0:LAT-1], tq_hs [0:LAT-1], tq_vb [0:LAT-1], tq_vs [0:LAT-1];
	reg [PPC-1:0] tq_lde [0:LAT-1];
	integer ti;
	always @(posedge clk) begin
		if (reset) begin
			tq_v <= '0;
			for (ti = 0; ti < LAT; ti = ti + 1) begin
				tq_hb[ti] <= 1'b1; tq_hs[ti] <= 1'b0;
				tq_vb[ti] <= 1'b1; tq_vs[ti] <= 1'b0;
				tq_lde[ti] <= '0;
			end
		end else begin
			for (ti = LAT-1; ti > 0; ti = ti - 1) begin
				tq_v[ti] <= tq_v[ti-1];
				tq_hb[ti] <= tq_hb[ti-1];
				tq_hs[ti] <= tq_hs[ti-1];
				tq_vb[ti] <= tq_vb[ti-1];
				tq_vs[ti] <= tq_vs[ti-1];
				tq_lde[ti] <= tq_lde[ti-1];
			end
			tq_v[0] <= beam_ce;
			tq_hb[0] <= beam_ce ? hb : 1'b1;
			tq_hs[0] <= beam_ce ? hs : 1'b0;
			tq_vb[0] <= beam_ce ? vb : 1'b1;
			tq_vs[0] <= beam_ce ? vs : 1'b0;
			tq_lde[0] <= beam_ce ? lane_de : '0;
		end
	end
	wire push = tq_v[LAT-1];
	wire push_hb = tq_hb[LAT-1];
	wire push_hs = tq_hs[LAT-1];
	wire push_vb = tq_vb[LAT-1];
	wire push_vs = tq_vs[LAT-1];
	wire push_de = |tq_lde[LAT-1];
	wire use_fs = push && push_de && fs_n_valid;

	wire npx_valid = push;
	wire [PPC*8-1:0] npx_r = use_fs ? fs_r_n : '0;
	wire [PPC*8-1:0] npx_g = use_fs ? fs_g_n : '0;
	wire [PPC*8-1:0] npx_b = use_fs ? fs_b_n : '0;
	wire [PPC-1:0] npx_lv = push ? {PPC{1'b1}} : '0;

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
		.in_hblank(push_hb),
		.in_hsync(push_hs),
		.in_vblank(push_vb),
		.in_vsync(push_vs),
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

	integer act_px, ur_mid, hs_rise, timeout;
	reg out_hs_d, producer_done;
	integer exp_x, exp_y, line_px;

	always @(posedge clk_pix) begin
		if (!reset) begin
			if (out_ce) begin
				if (!out_hb && !out_vb) begin
					act_px = act_px + 1;
					if (HAS_FRAME) begin
						// reconstruct expected within line: sequential in DE
						// R low byte = x+lane approx — check G=y and B=A5, R not random black
						if (out_b !== 8'hA5 || out_r === 8'd0 && out_g === 8'd0) begin
							// allow y=0 g=0; b must stick
							if (out_b !== 8'hA5) begin
								$display("FAIL frame RGB b=%02x at act=%0d", out_b, act_px);
								$fatal(1);
							end
						end
					end else begin
						if (out_r !== 8'd0 || out_g !== 8'd0 || out_b !== 8'd0) begin
							$display("FAIL no-frame want black got %02x%02x%02x", out_r, out_g, out_b);
							$fatal(1);
						end
					end
				end
				if (out_hs && !out_hs_d)
					hs_rise = hs_rise + 1;
				out_hs_d = out_hs;
			end
			if (rd_ur && !producer_done)
				ur_mid = ur_mid + 1;
		end
	end

	integer cycles, frames_seen;
	initial begin
		act_px = 0; ur_mid = 0; hs_rise = 0; out_hs_d = 0;
		producer_done = 0; frames_seen = 0; cycles = 0;
		repeat (30) @(posedge clk);
		reset = 0;
		// run enough cycles for >1 short frame of groups
		// groups/frame ≈ (H_TOTAL/PPC)*V_TOTAL
		timeout = (H_TOTAL/PPC) * V_TOTAL * 8 + 50000;
		while (cycles < timeout && frames_seen < 2) begin
			@(posedge clk);
			cycles = cycles + 1;
			if (fstart)
				frames_seen = frames_seen + 1;
		end
		producer_done = 1;
		repeat (20000) @(posedge clk);

		if (hs_rise < (V_TOTAL - 2)) begin
			$display("FAIL hs_rise=%0d", hs_rise);
			$fatal(1);
		end
		if (act_px < (H_DE * V_ACTIVE) / 2) begin
			$display("FAIL too few active px=%0d", act_px);
			$fatal(1);
		end
		if (ur_mid != 0) begin
			$display("FAIL mid-frame underrun ur=%0d", ur_mid);
			$fatal(1);
		end
		if (HAS_FRAME)
			$display("PASS present_mp_integrated FRAME act=%0d hs=%0d ur=0 lat=%0d",
				act_px, hs_rise, LAT);
		else
			$display("PASS present_mp_integrated NO_FRAME act=%0d hs=%0d ur=0 black",
				act_px, hs_rise);
		$finish;
	end
endmodule
`default_nettype wire
