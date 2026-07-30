// Serial, resource-shared H.264 in-loop deblock MB engine (product/Quartus).
//
// AREA CONTRACT (pre-registered before first map measure)
//   Target:  h264_deblock_mb_serial ≤ 2,500 ALMs
//   Concern: > 3,000 ALMs
//   Redesign:> 4,000 ALMs or whole design > 60% ALMs
//   Baseline identity path on wire6: ~960 ALMs (recv/emit/store only)
//
// WHY SERIAL
//   The Verilator multi-port engine forces ramstyle=logic windows and an
//   always@* 4-lane gather → product-wire4 measured ~34k ALMs for deblock_mb
//   alone.  This module keeps ONE h264_deblock_edge instance and walks the
//   same fstep schedule as the sim engine, but every window access is a
//   single-ported M10K read/write over multiple cycles (same lesson as
//   serial MC: fabric muxes of large windows do not fit the Cyclone V).
//
// SCHEDULE (cycles / MB, approximate)
//   RECV 384 + LOAD_TOP 64 + 64 edges * (GATH 32 + HOLD 1 + SCAT ≤24)
//     + EMIT ≤576 + STORE 64 + STORE2 16  ≈ 4k–5k cycles/MB
//   At 50 MHz, 300 MB @ 24 fps needs ~1.2M cycles/frame — headroom OK.
//
// PRE/POST contract matches h264_deblock_mb: PRE into smp_*; POST out_*.

`default_nettype none

module h264_deblock_mb_serial #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter int MB_W = (FRAME_W + 15) / 16,
	parameter int MB_H = (FRAME_H + 15) / 16
) (
	input  wire              clk,
	input  wire              reset,
	input  wire              slice_start,
	input  wire              disable_deblocking,
	input  wire signed [4:0] slice_alpha_c0_offset,
	input  wire signed [4:0] slice_beta_offset,
	input  wire              mb_start,
	input  wire [7:0]        mb_x,
	input  wire [7:0]        mb_y,
	input  wire              mb_is_intra,
	input  wire [5:0]        mb_qp_y,
	input  wire [5:0]        mb_qp_c,
	input  wire [15:0]       mb_nz_luma,
	input  wire signed [15:0] mb_mv_x,
	input  wire signed [15:0] mb_mv_y,
	input  wire [1:0]        mb_ref_idx,
	input  wire              smp_valid,
	input  wire [8:0]        smp_idx,
	input  wire [7:0]        smp_data,
	input  wire              smp_done,
	output reg               out_valid,
	output reg  [1:0]        out_plane,
	output reg  [15:0]       out_x,
	output reg  [15:0]       out_y,
	output reg  [7:0]        out_data,
	output wire              busy,
	output reg               mb_done
);
	localparam int MB_IDX_W = (MB_W <= 1) ? 1 : $clog2(MB_W);
	localparam int LBY_AW = $clog2(MB_W * 64);
	localparam int LBC_AW = $clog2(MB_W * 32);

	localparam [3:0] S_IDLE   = 4'd0;
	localparam [3:0] S_RECV   = 4'd1;
	localparam [3:0] S_LOAD   = 4'd2;
	localparam [3:0] S_GATH   = 4'd3;
	localparam [3:0] S_HOLD   = 4'd4;
	localparam [3:0] S_SCAT   = 4'd5;
	localparam [3:0] S_EMIT   = 4'd6;
	localparam [3:0] S_STORE  = 4'd7;
	localparam [3:0] S_STORE2 = 4'd8;
	localparam [3:0] S_DONE   = 4'd9;

	reg [3:0] state;

	// Working planes — single-port M10K only (no parallel gather).
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] wy [0:255];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] wu [0:63];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] wv [0:63];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] ty [0:63];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] tu [0:31];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] tv [0:31];
	// Left strips stay small register files (64/32/32 B) — next-MB left ctx.
	reg [7:0] ly [0:63];
	reg [7:0] lu [0:31];
	reg [7:0] lv [0:31];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] lb_y [0:(MB_W*64)-1];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] lb_u [0:(MB_W*32)-1];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] lb_v [0:(MB_W*32)-1];

	reg              lft_valid, lft_intra;
	reg [3:0]        lft_nz;
	reg [5:0]        lft_qp, lft_qpc;
	reg signed [15:0] lft_mvx, lft_mvy;
	reg [1:0]        lft_ref;
	reg              top_valid [0:MB_W-1];
	reg              top_intra [0:MB_W-1];
	reg [3:0]        top_nz    [0:MB_W-1];
	reg [5:0]        top_qp    [0:MB_W-1];
	reg [5:0]        top_qpc   [0:MB_W-1];
	reg signed [15:0] top_mvx  [0:MB_W-1];
	reg signed [15:0] top_mvy  [0:MB_W-1];
	reg [1:0]        top_ref   [0:MB_W-1];

	reg [7:0] mbx_r, mby_r;
	reg       intra_r, use_left, use_top;
	reg [5:0] qpy_r, qpc_r;
	reg [15:0] nz_r;
	reg signed [15:0] mvx_r, mvy_r;
	reg [1:0] ref_r;

	reg [5:0] fstep;
	reg [5:0] gath_i;   // 0..31 gather beat
	reg [4:0] scat_i;   // 0..23 scatter beat
	reg [9:0] emit_idx;
	reg [6:0] seq_idx;
	reg       emit_pend;
	reg [1:0] e_plane_d;
	reg [15:0] e_x_d, e_y_d;
	reg       e_gate_d;
	reg [7:0] rd_q;

	// Gathered edge samples (registered before edge filter).
	reg [7:0] gp3 [0:3], gp2 [0:3], gp1 [0:3], gp0 [0:3];
	reg [7:0] gq0 [0:3], gq1 [0:3], gq2 [0:3], gq3 [0:3];
	reg [7:0] ep2 [0:3], ep1 [0:3], ep0 [0:3];
	reg [7:0] eq0 [0:3], eq1 [0:3], eq2 [0:3];
	reg       filt_en; // edge available && bs!=0 && !disable

	wire [MB_IDX_W-1:0] mbx_idx = mbx_r[MB_IDX_W-1:0];
	wire [7:0] mbx_left8 = (mbx_r == 8'd0) ? 8'd0 : (mbx_r - 8'd1);
	wire [MB_IDX_W-1:0] mbx_left_idx = mbx_left8[MB_IDX_W-1:0];
	wire [15:0] lb_base_y = {8'd0, mbx_idx} * 16'd64;
	wire [15:0] lb_base_c = {8'd0, mbx_idx} * 16'd32;
	wire [15:0] lb_lbase_y = {8'd0, mbx_left_idx} * 16'd64;
	wire [15:0] lb_lbase_c = {8'd0, mbx_left_idx} * 16'd32;
	wire [15:0] blx = {4'd0, mbx_r, 4'd0};
	wire [15:0] bly = {4'd0, mby_r, 4'd0};
	wire [15:0] bcx = {5'd0, mbx_r, 3'd0};
	wire [15:0] bcy = {5'd0, mby_r, 3'd0};

	assign busy = (state != S_IDLE);

	// ---- fstep decode (identical encoding to sim engine) ----
	wire       f_chroma = fstep[5];
	wire       f_horiz  = fstep[4];
	wire [1:0] f_seg    = fstep[1:0];
	wire       f_comp   = fstep[3];
	wire [1:0] f_edge   = f_chroma ? {1'b0, fstep[2]} : fstep[3:2];
	wire [1:0] f_bs_edge = f_chroma ? {fstep[2], 1'b0} : fstep[3:2];
	wire       f_mb_boundary = (f_bs_edge == 2'd0);
	wire [3:0] f_q_blk = f_horiz ? {f_bs_edge, f_seg} : {f_seg, f_bs_edge};
	wire [1:0] f_p_e   = f_bs_edge - 2'd1;
	wire [3:0] f_p_blk = f_horiz ? {f_p_e, f_seg} : {f_seg, f_p_e};
	wire f_q_nz = nz_r[f_q_blk];
	wire f_p_nz_int = nz_r[f_p_blk];
	wire f_top_nz = top_nz[mbx_idx][f_seg];
	wire f_left_nz = lft_nz[f_seg];
	wire f_edge_avail = f_mb_boundary ? (f_horiz ? use_top : use_left) : 1'b1;
	wire f_p_intra = !f_mb_boundary ? intra_r : (f_horiz ? top_intra[mbx_idx] : lft_intra);
	wire f_p_nz = !f_mb_boundary ? f_p_nz_int : (f_horiz ? f_top_nz : f_left_nz);
	wire [1:0] f_p_ref = !f_mb_boundary ? ref_r : (f_horiz ? top_ref[mbx_idx] : lft_ref);
	wire signed [15:0] f_p_mvx = !f_mb_boundary ? mvx_r : (f_horiz ? top_mvx[mbx_idx] : lft_mvx);
	wire signed [15:0] f_p_mvy = !f_mb_boundary ? mvy_r : (f_horiz ? top_mvy[mbx_idx] : lft_mvy);
	wire [5:0] f_p_qp = !f_mb_boundary ? (f_chroma ? qpc_r : qpy_r) :
	                     f_horiz ? (f_chroma ? top_qpc[mbx_idx] : top_qp[mbx_idx]) :
	                               (f_chroma ? lft_qpc : lft_qp);
	wire [5:0] f_q_qp = f_chroma ? qpc_r : qpy_r;
	wire [6:0] f_qp_sum = {1'b0, f_p_qp} + {1'b0, f_q_qp} + 7'd1;
	wire [5:0] f_qp_avg = f_qp_sum[6:1];

	wire [2:0] f_bs;
	wire       f_bs_unsup;
	h264_deblock_bs u_bs (
		.disable_all(disable_deblocking),
		.slice_boundary_blocked(!f_edge_avail),
		.mb_boundary(f_mb_boundary),
		.p_intra(f_p_intra), .q_intra(intra_r),
		.p_nonzero(f_p_nz), .q_nonzero(f_q_nz),
		.p_ref(f_p_ref), .q_ref(ref_r),
		.p_mvx(f_p_mvx[11:0]), .p_mvy(f_p_mvy[11:0]),
		.q_mvx(mvx_r[11:0]), .q_mvy(mvy_r[11:0]),
		.bs(f_bs), .unsupported_ref(f_bs_unsup)
	);

	wire [7:0] edge_p2 [0:3], edge_p1 [0:3], edge_p0 [0:3];
	wire [7:0] edge_q0 [0:3], edge_q1 [0:3], edge_q2 [0:3];
	wire [7:0] alpha_u, beta_u;
	wire [5:0] tc0_u;
	h264_deblock_edge u_edge (
		.is_chroma(f_chroma),
		.bs(f_bs),
		.qp_avg(f_qp_avg),
		.slice_alpha_c0_offset(slice_alpha_c0_offset),
		.slice_beta_offset(slice_beta_offset),
		.p3_in(gp3), .p2_in(gp2), .p1_in(gp1), .p0_in(gp0),
		.q0_in(gq0), .q1_in(gq1), .q2_in(gq2), .q3_in(gq3),
		.p2_out(edge_p2), .p1_out(edge_p1), .p0_out(edge_p0),
		.q0_out(edge_q0), .q1_out(edge_q1), .q2_out(edge_q2),
		.alpha_dbg(alpha_u), .beta_dbg(beta_u), .tc0_dbg(tc0_u)
	);

	// ---- Address helpers for gather/scatter ----
	// tap_id: 0=p3 .. 7=q3; lane: 0..3
	wire [1:0] g_lane = gath_i[4:3];
	wire [2:0] g_tap  = gath_i[2:0];
	wire [1:0] s_lane = scat_i[4:3];
	wire [2:0] s_tap  = scat_i[2:0]; // 0=p2,1=p1,2=p0,3=q0,4=q1,5=q2

	wire signed [5:0] edge4 = $signed({4'd0, f_edge}) * 6'sd4;
	wire [4:0] luma_pos = {3'd0, f_seg} * 5'd4 + {3'd0, g_lane};
	wire [3:0] chr_pos  = {2'd0, f_seg} * 4'd2 + {2'd0, g_lane[0]};
	wire [4:0] luma_pos_s = {3'd0, f_seg} * 5'd4 + {3'd0, s_lane};
	wire [3:0] chr_pos_s  = {2'd0, f_seg} * 4'd2 + {2'd0, s_lane[0]};

	// Signed sample coords for current gather beat
	reg signed [5:0] gx, gy;
	always @* begin
		gx = 6'sd0; gy = 6'sd0;
		if (!f_chroma) begin
			if (!f_horiz) begin
				gy = $signed({1'b0, luma_pos});
				case (g_tap)
				3'd0: gx = edge4 - 6'sd4;
				3'd1: gx = edge4 - 6'sd3;
				3'd2: gx = edge4 - 6'sd2;
				3'd3: gx = edge4 - 6'sd1;
				3'd4: gx = edge4 + 6'sd0;
				3'd5: gx = edge4 + 6'sd1;
				3'd6: gx = edge4 + 6'sd2;
				default: gx = edge4 + 6'sd3;
				endcase
			end else begin
				gx = $signed({1'b0, luma_pos});
				case (g_tap)
				3'd0: gy = edge4 - 6'sd4;
				3'd1: gy = edge4 - 6'sd3;
				3'd2: gy = edge4 - 6'sd2;
				3'd3: gy = edge4 - 6'sd1;
				3'd4: gy = edge4 + 6'sd0;
				3'd5: gy = edge4 + 6'sd1;
				3'd6: gy = edge4 + 6'sd2;
				default: gy = edge4 + 6'sd3;
				endcase
			end
		end else begin
			if (!f_horiz) begin
				gy = $signed({2'b0, chr_pos});
				case (g_tap)
				3'd0: gx = edge4 - 6'sd4;
				3'd1: gx = edge4 - 6'sd3;
				3'd2: gx = edge4 - 6'sd2;
				3'd3: gx = edge4 - 6'sd1;
				3'd4: gx = edge4 + 6'sd0;
				3'd5: gx = edge4 + 6'sd1;
				3'd6: gx = edge4 + 6'sd2;
				default: gx = edge4 + 6'sd3;
				endcase
			end else begin
				gx = $signed({2'b0, chr_pos});
				case (g_tap)
				3'd0: gy = edge4 - 6'sd4;
				3'd1: gy = edge4 - 6'sd3;
				3'd2: gy = edge4 - 6'sd2;
				3'd3: gy = edge4 - 6'sd1;
				3'd4: gy = edge4 + 6'sd0;
				3'd5: gy = edge4 + 6'sd1;
				3'd6: gy = edge4 + 6'sd2;
				default: gy = edge4 + 6'sd3;
				endcase
			end
		end
	end

	// Read mux select
	localparam [2:0] SRC_WY = 3'd0, SRC_WU = 3'd1, SRC_WV = 3'd2;
	localparam [2:0] SRC_LY = 3'd3, SRC_LU = 3'd4, SRC_LV = 3'd5;
	localparam [2:0] SRC_TY = 3'd6, SRC_TC = 3'd7; // TC uses tu/tv via f_comp

	reg [2:0] rd_src;
	reg [7:0] rd_addr;
	always @* begin
		rd_src = SRC_WY;
		rd_addr = 8'd0;
		if (!f_chroma) begin
			if (gx < 0) begin
				rd_src = SRC_LY;
				rd_addr = {2'd0, gy[3:0], gx[1:0] + 2'd0}; // y*4+(x+4); x in -4..-1 → 0..3
				// fix: x+4
				rd_addr = gy[3:0] * 8'd4 + {6'd0, gx[1:0] + 2'd0};
				// when gx=-4, gx[1:0]=0 but need 0; when gx=-1, need 3.
				// Use (gx+4)
				rd_addr = {2'd0, gy[3:0]} * 8'd4 + {6'd0, gx[2:0] + 3'd4};
			end else if (gy < 0) begin
				rd_src = SRC_TY;
				rd_addr = {2'd0, gy[2:0] + 3'd4} * 8'd16 + {3'd0, gx[3:0]};
			end else begin
				rd_src = SRC_WY;
				rd_addr = {2'd0, gy[3:0]} * 8'd16 + {4'd0, gx[3:0]};
			end
		end else begin
			if (gx < 0) begin
				rd_src = f_comp ? SRC_LV : SRC_LU;
				rd_addr = {3'd0, gy[2:0]} * 8'd4 + {6'd0, gx[2:0] + 3'd4};
			end else if (gy < 0) begin
				rd_src = SRC_TC;
				rd_addr = {3'd0, gy[2:0] + 3'd4} * 8'd8 + {5'd0, gx[2:0]};
			end else begin
				rd_src = f_comp ? SRC_WV : SRC_WU;
				rd_addr = {3'd0, gy[2:0]} * 8'd8 + {5'd0, gx[2:0]};
			end
		end
	end


	// Emit address (576 beats with neighbour strips)
	wire [9:0] em = emit_idx;
	reg [1:0] e_plane;
	reg [15:0] e_x, e_y;
	reg [2:0] e_src;
	reg [7:0] e_addr;
	reg e_gate;
	always @* begin
		e_plane = 2'd0; e_x = 16'd0; e_y = 16'd0; e_src = SRC_WY; e_addr = 8'd0; e_gate = 1'b1;
		if (em < 10'd256) begin
			e_plane = 2'd0; e_src = SRC_WY; e_addr = em[7:0];
			e_x = blx + {12'd0, em[3:0]}; e_y = bly + {12'd0, em[7:4]};
		end else if (em < 10'd320) begin
			e_plane = 2'd0; e_src = SRC_LY; e_addr = {2'd0, em[5:0]}; // left strip 64
			// left strip layout: rows 0..15, cols -4..-1 → emit only if use_left
			e_x = blx - 16'd4 + {14'd0, em[1:0]};
			e_y = bly + {12'd0, em[5:2]};
			e_gate = use_left;
			e_addr = em[5:2] * 8'd4 + {6'd0, em[1:0]};
		end else if (em < 10'd384) begin
			e_plane = 2'd0; e_src = SRC_TY; e_addr = em[5:0];
			e_x = blx + {12'd0, em[3:0]};
			e_y = bly - 16'd4 + {14'd0, em[5:4]};
			e_gate = use_top;
			// ty index (y+4)*16+x with y in -4..-1 → em relative
			e_addr = {2'd0, em[5:4]} * 8'd16 + {4'd0, em[3:0]};
		end else if (em < 10'd448) begin
			e_plane = 2'd1; e_src = SRC_WU; e_addr = em[5:0];
			e_x = bcx + {13'd0, em[2:0]}; e_y = bcy + {13'd0, em[5:3]};
		end else if (em < 10'd512) begin
			e_plane = 2'd2; e_src = SRC_WV; e_addr = em[5:0];
			e_x = bcx + {13'd0, em[2:0]}; e_y = bcy + {13'd0, em[5:3]};
		end else if (em < 10'd544) begin
			e_plane = 2'd1; e_src = SRC_LU; e_gate = use_left;
			e_x = bcx - 16'd4 + {14'd0, em[1:0]}; e_y = bcy + {13'd0, em[4:2]};
			e_addr = em[4:2] * 8'd4 + {6'd0, em[1:0]};
		end else begin
			e_plane = 2'd2; e_src = SRC_LV; e_gate = use_left;
			e_x = bcx - 16'd4 + {14'd0, em[1:0]}; e_y = bcy + {13'd0, em[4:2]};
			e_addr = em[4:2] * 8'd4 + {6'd0, em[1:0]};
		end
	end

	// Scatter write targets
	reg signed [5:0] sx, sy;
	reg [7:0] s_data;
	reg s_write;
	always @* begin
		sx = 6'sd0; sy = 6'sd0; s_data = 8'd0; s_write = filt_en;
		if (!f_chroma) begin
			// taps p2,p1,p0,q0,q1,q2 only (6)
			if (!f_horiz) begin
				sy = $signed({1'b0, luma_pos_s});
				case (s_tap)
				3'd0: begin sx = edge4 - 6'sd3; s_data = ep2[s_lane]; end
				3'd1: begin sx = edge4 - 6'sd2; s_data = ep1[s_lane]; end
				3'd2: begin sx = edge4 - 6'sd1; s_data = ep0[s_lane]; end
				3'd3: begin sx = edge4 + 6'sd0; s_data = eq0[s_lane]; end
				3'd4: begin sx = edge4 + 6'sd1; s_data = eq1[s_lane]; end
				default: begin sx = edge4 + 6'sd2; s_data = eq2[s_lane]; end
				endcase
			end else begin
				sx = $signed({1'b0, luma_pos_s});
				case (s_tap)
				3'd0: begin sy = edge4 - 6'sd3; s_data = ep2[s_lane]; end
				3'd1: begin sy = edge4 - 6'sd2; s_data = ep1[s_lane]; end
				3'd2: begin sy = edge4 - 6'sd1; s_data = ep0[s_lane]; end
				3'd3: begin sy = edge4 + 6'sd0; s_data = eq0[s_lane]; end
				3'd4: begin sy = edge4 + 6'sd1; s_data = eq1[s_lane]; end
				default: begin sy = edge4 + 6'sd2; s_data = eq2[s_lane]; end
				endcase
			end
		end else begin
			// chroma: only p0/q0 written by strong/normal (match sim: ep0/eq0)
			s_write = filt_en && (s_lane < 2) && (s_tap == 3'd2 || s_tap == 3'd3);
			if (!f_horiz) begin
				sy = $signed({2'b0, chr_pos_s});
				if (s_tap == 3'd2) begin sx = edge4 - 6'sd1; s_data = ep0[s_lane]; end
				else begin sx = edge4 + 6'sd0; s_data = eq0[s_lane]; end
			end else begin
				sx = $signed({2'b0, chr_pos_s});
				if (s_tap == 3'd2) begin sy = edge4 - 6'sd1; s_data = ep0[s_lane]; end
				else begin sy = edge4 + 6'sd0; s_data = eq0[s_lane]; end
			end
		end
	end

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			state <= S_IDLE;
			out_valid <= 1'b0;
			mb_done <= 1'b0;
			emit_pend <= 1'b0;

			// Unified single-port read (gather addr or emit addr)
			if (state == S_EMIT) begin
				case (e_src)
				SRC_WY: rd_q <= wy[e_addr];
				SRC_WU: rd_q <= wu[e_addr[5:0]];
				SRC_WV: rd_q <= wv[e_addr[5:0]];
				SRC_LY: rd_q <= ly[e_addr[5:0]];
				SRC_LU: rd_q <= lu[e_addr[4:0]];
				SRC_LV: rd_q <= lv[e_addr[4:0]];
				SRC_TY: rd_q <= ty[e_addr[5:0]];
				default: rd_q <= f_comp ? tv[e_addr[4:0]] : tu[e_addr[4:0]];
				endcase
			end else begin
				case (rd_src)
				SRC_WY: rd_q <= wy[rd_addr];
				SRC_WU: rd_q <= wu[rd_addr[5:0]];
				SRC_WV: rd_q <= wv[rd_addr[5:0]];
				SRC_LY: rd_q <= ly[rd_addr[5:0]];
				SRC_LU: rd_q <= lu[rd_addr[4:0]];
				SRC_LV: rd_q <= lv[rd_addr[4:0]];
				SRC_TY: rd_q <= ty[rd_addr[5:0]];
				default: rd_q <= f_comp ? tv[rd_addr[4:0]] : tu[rd_addr[4:0]];
				endcase
			end
			fstep <= 6'd0;
			gath_i <= 6'd0;
			scat_i <= 5'd0;
			emit_idx <= 10'd0;
			seq_idx <= 7'd0;
			filt_en <= 1'b0;
			lft_valid <= 1'b0;
			for (i = 0; i < MB_W; i = i + 1)
				top_valid[i] <= 1'b0;
		end else begin
			out_valid <= 1'b0;
			mb_done <= 1'b0;

			if (slice_start) begin
				lft_valid <= 1'b0;
				for (i = 0; i < MB_W; i = i + 1)
					top_valid[i] <= 1'b0;
			end

			// Emit drain (1-cycle RAM lag)
			if (emit_pend) begin
				out_valid <= e_gate_d;
				out_plane <= e_plane_d;
				out_x <= e_x_d;
				out_y <= e_y_d;
				out_data <= rd_q;
			end
			emit_pend <= 1'b0;

			// RECV window load
			if (state == S_RECV && smp_valid) begin
				if (smp_idx < 9'd256) wy[smp_idx[7:0]] <= smp_data;
				else if (smp_idx < 9'd320) wu[smp_idx[5:0]] <= smp_data;
				else wv[smp_idx[5:0]] <= smp_data;
			end

			// Capture gather sample (rd_q lags one cycle behind gath_i)
			// Handled via gath pipeline: request at gath_i, capture next cycle into slot gath_i-1
			// Simplified: two-phase inside GATH using gath_phase

			case (state)
			S_IDLE: if (mb_start) begin
				mbx_r <= mb_x;
				mby_r <= mb_y;
				intra_r <= mb_is_intra;
				qpy_r <= mb_qp_y;
				qpc_r <= mb_qp_c;
				nz_r <= mb_nz_luma;
				mvx_r <= mb_mv_x;
				mvy_r <= mb_mv_y;
				ref_r <= mb_ref_idx;
				use_left <= (mb_x != 8'd0) && lft_valid && !disable_deblocking;
				use_top <= (mb_y != 8'd0) && top_valid[mb_x[MB_IDX_W-1:0]] && !disable_deblocking;
				state <= S_RECV;
			end

			S_RECV: if (smp_done) begin
				seq_idx <= 7'd0;
				state <= S_LOAD;
			end

			S_LOAD: begin
				// sequential top strip from linebuf → ty/tu/tv
				ty[seq_idx[5:0]] <= lb_y[lb_base_y[LBY_AW-1:0] + seq_idx[5:0]];
				if (!seq_idx[5]) begin
					tu[seq_idx[4:0]] <= lb_u[lb_base_c[LBC_AW-1:0] + seq_idx[4:0]];
					tv[seq_idx[4:0]] <= lb_v[lb_base_c[LBC_AW-1:0] + seq_idx[4:0]];
				end
				if (seq_idx == 7'd63) begin
					fstep <= 6'd0;
					gath_i <= 6'd0;
					filt_en <= f_edge_avail && !disable_deblocking && (f_bs != 3'd0);
					// Note: f_bs uses fstep=0 after this assign races — set filt_en in GATH entry
					state <= S_GATH;
				end else seq_idx <= seq_idx + 7'd1;
			end

			S_GATH: begin
				// Issue reads; capture previous beat into gp/gq.
				// Beat 0: issue only. Beats 1..32: capture tap (gath_i-1), issue gath_i.
				if (gath_i != 6'd0) begin
					// capture into previous lane/tap
					case ((gath_i - 6'd1))
					// expanded via tap/lane of gath_i-1
					default: begin end
					endcase
				end
				// Capture using computed previous indices
				if (gath_i > 6'd0) begin
					case ((gath_i - 6'd1) & 6'd7)
					6'd0: gp3[(gath_i - 6'd1) >> 3] <= rd_q;
					6'd1: gp2[(gath_i - 6'd1) >> 3] <= rd_q;
					6'd2: gp1[(gath_i - 6'd1) >> 3] <= rd_q;
					6'd3: gp0[(gath_i - 6'd1) >> 3] <= rd_q;
					6'd4: gq0[(gath_i - 6'd1) >> 3] <= rd_q;
					6'd5: gq1[(gath_i - 6'd1) >> 3] <= rd_q;
					6'd6: gq2[(gath_i - 6'd1) >> 3] <= rd_q;
					default: gq3[(gath_i - 6'd1) >> 3] <= rd_q;
					endcase
				end
				if (gath_i == 6'd32) begin
					// last capture done; evaluate filt_en with current fstep
					filt_en <= f_edge_avail && !disable_deblocking && (f_bs != 3'd0);
					state <= S_HOLD;
				end else begin
					gath_i <= gath_i + 6'd1;
				end
			end

			S_HOLD: begin
				// edge combo sees stable gp/gq; register outs
				ep2[0] <= edge_p2[0]; ep2[1] <= edge_p2[1]; ep2[2] <= edge_p2[2]; ep2[3] <= edge_p2[3];
				ep1[0] <= edge_p1[0]; ep1[1] <= edge_p1[1]; ep1[2] <= edge_p1[2]; ep1[3] <= edge_p1[3];
				ep0[0] <= edge_p0[0]; ep0[1] <= edge_p0[1]; ep0[2] <= edge_p0[2]; ep0[3] <= edge_p0[3];
				eq0[0] <= edge_q0[0]; eq0[1] <= edge_q0[1]; eq0[2] <= edge_q0[2]; eq0[3] <= edge_q0[3];
				eq1[0] <= edge_q1[0]; eq1[1] <= edge_q1[1]; eq1[2] <= edge_q1[2]; eq1[3] <= edge_q1[3];
				eq2[0] <= edge_q2[0]; eq2[1] <= edge_q2[1]; eq2[2] <= edge_q2[2]; eq2[3] <= edge_q2[3];
				scat_i <= 5'd0;
				if (!filt_en) begin
					// skip scatter
					if (fstep == 6'd63) begin
						emit_idx <= 10'd0;
						state <= S_EMIT;
					end else begin
						fstep <= fstep + 6'd1;
						gath_i <= 6'd0;
						state <= S_GATH;
					end
				end else state <= S_SCAT;
			end

			S_SCAT: begin
				if (s_write) begin
					if (!f_chroma) begin
						if (sx < 0)
							ly[{2'd0, sy[3:0]} * 8'd4 + {6'd0, sx[2:0] + 3'd4}] <= s_data;
						else if (sy < 0)
							ty[{2'd0, sy[2:0] + 3'd4} * 8'd16 + {4'd0, sx[3:0]}] <= s_data;
						else
							wy[{2'd0, sy[3:0]} * 8'd16 + {4'd0, sx[3:0]}] <= s_data;
					end else begin
						if (sx < 0) begin
							if (f_comp) lv[{3'd0, sy[2:0]} * 8'd4 + {6'd0, sx[2:0] + 3'd4}] <= s_data;
							else        lu[{3'd0, sy[2:0]} * 8'd4 + {6'd0, sx[2:0] + 3'd4}] <= s_data;
						end else if (sy < 0) begin
							if (f_comp) tv[{3'd0, sy[2:0] + 3'd4} * 8'd8 + {5'd0, sx[2:0]}] <= s_data;
							else        tu[{3'd0, sy[2:0] + 3'd4} * 8'd8 + {5'd0, sx[2:0]}] <= s_data;
						end else begin
							if (f_comp) wv[{3'd0, sy[2:0]} * 8'd8 + {5'd0, sx[2:0]}] <= s_data;
							else        wu[{3'd0, sy[2:0]} * 8'd8 + {5'd0, sx[2:0]}] <= s_data;
						end
					end
				end
				// 4 lanes * 6 taps = 24 beats; chroma still walks 24 but s_write gates
				if (scat_i == 5'd23) begin
					if (fstep == 6'd63) begin
						emit_idx <= 10'd0;
						state <= S_EMIT;
					end else begin
						fstep <= fstep + 6'd1;
						gath_i <= 6'd0;
						state <= S_GATH;
					end
				end else scat_i <= scat_i + 5'd1;
			end

			S_EMIT: begin
				// rd_q loaded this cycle from e_*; publish next cycle via emit_pend
				emit_pend <= 1'b1;
				e_plane_d <= e_plane;
				e_x_d <= e_x;
				e_y_d <= e_y;
				e_gate_d <= e_gate;
				if (emit_idx == 10'd575) begin
					seq_idx <= 7'd0;
					state <= S_STORE;
				end else emit_idx <= emit_idx + 10'd1;
			end

			S_STORE: begin
				lb_y[lb_base_y[LBY_AW-1:0] + seq_idx[5:0]] <=
					wy[{2'b11, seq_idx[5:4], seq_idx[3:0]}];
				if (!seq_idx[5]) begin
					lb_u[lb_base_c[LBC_AW-1:0] + seq_idx[4:0]] <=
						wu[{1'b1, seq_idx[4:3], seq_idx[2:0]}];
					lb_v[lb_base_c[LBC_AW-1:0] + seq_idx[4:0]] <=
						wv[{1'b1, seq_idx[4:3], seq_idx[2:0]}];
				end
				if (seq_idx == 7'd63) begin
					seq_idx <= 7'd0;
					state <= S_STORE2;
				end else seq_idx <= seq_idx + 7'd1;
			end

			S_STORE2: begin
				// Patch left-MB bottom strip if edge0 filtered it; serial copy right cols → ly
				if (use_left) begin
					lb_y[lb_lbase_y[LBY_AW-1:0] + {seq_idx[3:2], 4'd12} + {6'd0, seq_idx[1:0]}] <=
						ly[{2'b11, seq_idx[3:2], seq_idx[1:0]}];
				end
				// rotate right 4 cols of this MB into left strip for next MB
				ly[seq_idx[3:0] * 8'd4 + 0] <= wy[seq_idx[3:0] * 8'd16 + 8'd12];
				ly[seq_idx[3:0] * 8'd4 + 1] <= wy[seq_idx[3:0] * 8'd16 + 8'd13];
				ly[seq_idx[3:0] * 8'd4 + 2] <= wy[seq_idx[3:0] * 8'd16 + 8'd14];
				ly[seq_idx[3:0] * 8'd4 + 3] <= wy[seq_idx[3:0] * 8'd16 + 8'd15];
				if (seq_idx < 7'd8) begin
					lu[seq_idx[2:0] * 8'd4 + 0] <= wu[seq_idx[2:0] * 8'd8 + 8'd4];
					lu[seq_idx[2:0] * 8'd4 + 1] <= wu[seq_idx[2:0] * 8'd8 + 8'd5];
					lu[seq_idx[2:0] * 8'd4 + 2] <= wu[seq_idx[2:0] * 8'd8 + 8'd6];
					lu[seq_idx[2:0] * 8'd4 + 3] <= wu[seq_idx[2:0] * 8'd8 + 8'd7];
					lv[seq_idx[2:0] * 8'd4 + 0] <= wv[seq_idx[2:0] * 8'd8 + 8'd4];
					lv[seq_idx[2:0] * 8'd4 + 1] <= wv[seq_idx[2:0] * 8'd8 + 8'd5];
					lv[seq_idx[2:0] * 8'd4 + 2] <= wv[seq_idx[2:0] * 8'd8 + 8'd6];
					lv[seq_idx[2:0] * 8'd4 + 3] <= wv[seq_idx[2:0] * 8'd8 + 8'd7];
				end
				if (seq_idx == 7'd15) begin
					lft_valid <= 1'b1;
					lft_intra <= intra_r;
					lft_nz <= {nz_r[15], nz_r[11], nz_r[7], nz_r[3]};
					lft_qp <= qpy_r;
					lft_qpc <= qpc_r;
					lft_mvx <= mvx_r;
					lft_mvy <= mvy_r;
					lft_ref <= ref_r;
					top_valid[mbx_idx] <= 1'b1;
					top_intra[mbx_idx] <= intra_r;
					top_nz[mbx_idx] <= nz_r[15:12];
					top_qp[mbx_idx] <= qpy_r;
					top_qpc[mbx_idx] <= qpc_r;
					top_mvx[mbx_idx] <= mvx_r;
					top_mvy[mbx_idx] <= mvy_r;
					top_ref[mbx_idx] <= ref_r;
					state <= S_DONE;
				end else seq_idx <= seq_idx + 7'd1;
			end

			S_DONE: begin
				mb_done <= 1'b1;
				state <= S_IDLE;
			end

			default: state <= S_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
