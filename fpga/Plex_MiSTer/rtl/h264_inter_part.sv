`default_nettype none

// ---------------------------------------------------------------------------
// Inter partition support: 4x4-granular motion neighbour context, partition
// geometry, partition motion vector prediction and per-partition motion
// compensated copy.
//
// DEBLOCK NOTE: everything in this file reads the POST-deblocking reference
// picture, per clause 8.4.2. Intra prediction and the intra neighbour taps
// read PRE-deblocking samples from h264_intra_nb_ctx instead; the two must not
// be crossed. Skipped macroblocks still get deblocked, so a future deblocking
// filter must walk them too.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Motion neighbour context at 4x4 granularity, clause 6.4.11.7 / 8.4.1.3.2.
//
// h264_pskip_nb_ctx stores one motion vector per macroblock, which is exactly
// right while every macroblock is P_Skip or P_L0_16x16. As soon as 16x8, 8x16
// or 8x8 partitions appear, the A/B/C/D neighbours of a partition can be other
// partitions of the SAME macroblock, or a specific 4x4 row/column of a
// neighbouring macroblock, so the field has to be kept at 4x4 resolution.
//
// The macroblock-level availability rules are unchanged, so this module is a
// drop-in replacement for h264_pskip_nb_ctx: query it with a 16x16 partition
// at (0,0) and it produces the same A/B/C/D taps.
//
// Current-macroblock taps are only reported present once the partition that
// covers them has been written back, which is what makes "the neighbour has not
// been decoded yet" fall out correctly for later partitions.
// ---------------------------------------------------------------------------

module h264_mv_nb_ctx4x4 #(
	parameter int MB_WIDTH_MAX = 39,
	parameter int MB_WIDTH_DEFAULT = 39
)(
	input  wire        clk,
	input  wire        reset,

	input  wire [7:0]  mb_x,
	input  wire [7:0]  mb_y,
	input  wire [7:0]  mb_width,
	input  wire [15:0] first_mb_in_slice,

	// Start of a new macroblock: nothing inside it has been decoded yet.
	input  wire        mb_start,

	// Partition write-back into the current macroblock's 4x4 field.
	input  wire        blk_wr_valid,
	input  wire [15:0] blk_wr_mask,     // one bit per 4x4, raster order
	input  wire        blk_wr_inter,
	input  wire [1:0]  blk_wr_ref,
	input  wire signed [15:0] blk_wr_mv_x,
	input  wire signed [15:0] blk_wr_mv_y,

	// Retire the current macroblock into the row/column buffers.
	input  wire        mb_commit,
	input  wire [7:0]  commit_mb_x,

	// Combinational query for one partition: origin and width in luma samples.
	input  wire [4:0]  q_x,
	input  wire [4:0]  q_y,
	input  wire [4:0]  q_w,
	input  wire [1:0]  q_ref_idx,

	output wire               nb_a_present,
	output wire               nb_a_inter,
	output wire        [1:0]  nb_a_ref,
	output wire signed [15:0] nb_a_mv_x,
	output wire signed [15:0] nb_a_mv_y,

	output wire               nb_b_present,
	output wire               nb_b_inter,
	output wire        [1:0]  nb_b_ref,
	output wire signed [15:0] nb_b_mv_x,
	output wire signed [15:0] nb_b_mv_y,

	output wire               nb_c_present,
	output wire               nb_c_inter,
	output wire        [1:0]  nb_c_ref,
	output wire signed [15:0] nb_c_mv_x,
	output wire signed [15:0] nb_c_mv_y,

	output wire               nb_d_present,
	output wire               nb_d_inter,
	output wire        [1:0]  nb_d_ref,
	output wire signed [15:0] nb_d_mv_x,
	output wire signed [15:0] nb_d_mv_y
);
	wire [7:0]  active_mb_width = (mb_width == 8'd0) ? MB_WIDTH_DEFAULT[7:0] : mb_width;
	wire [15:0] active_mb_width16 = {8'd0, active_mb_width};
	wire [15:0] cur_mb_index = ({8'd0, mb_y} * active_mb_width16) + {8'd0, mb_x};
	wire [15:0] left_mb_index = cur_mb_index - 16'd1;
	wire [15:0] top_mb_index = cur_mb_index - active_mb_width16;
	wire [15:0] top_left_mb_index = top_mb_index - 16'd1;
	wire [15:0] top_right_mb_index = top_mb_index + 16'd1;

	wire has_left_col = (mb_x != 8'd0);
	wire has_top_row = (mb_y != 8'd0);
	wire has_right_col = (({8'd0, mb_x} + 16'd1) < active_mb_width16);

	wire avail_left  = has_left_col && (left_mb_index >= first_mb_in_slice);
	wire avail_top   = has_top_row && (top_mb_index >= first_mb_in_slice);
	wire avail_tr    = has_top_row && has_right_col &&
	                   (top_right_mb_index >= first_mb_in_slice);
	wire avail_tl    = has_top_row && has_left_col &&
	                   (top_left_mb_index >= first_mb_in_slice);

	localparam int COL_W = (MB_WIDTH_MAX <= 1) ? 1 : $clog2(MB_WIDTH_MAX);
	wire [COL_W-1:0] col_cur = mb_x[COL_W-1:0];
	wire [COL_W-1:0] col_right = has_right_col ? (mb_x[COL_W-1:0] + COL_W'(1))
	                                           : mb_x[COL_W-1:0];
	wire [COL_W-1:0] col_commit = commit_mb_x[COL_W-1:0];

	// Current macroblock, raster order 4x4 index = row * 4 + col.
	reg               cur_set   [0:15];
	reg               cur_inter [0:15];
	reg        [1:0]  cur_ref   [0:15];
	reg signed [15:0] cur_mv_x  [0:15];
	reg signed [15:0] cur_mv_y  [0:15];

	// Bottom 4x4 row of every macroblock in the row above.
	reg               above_inter [0:MB_WIDTH_MAX-1][0:3];
	reg        [1:0]  above_ref   [0:MB_WIDTH_MAX-1][0:3];
	reg signed [15:0] above_mv_x  [0:MB_WIDTH_MAX-1][0:3];
	reg signed [15:0] above_mv_y  [0:MB_WIDTH_MAX-1][0:3];

	// Right 4x4 column of the macroblock to the left.
	reg               left_inter [0:3];
	reg        [1:0]  left_ref   [0:3];
	reg signed [15:0] left_mv_x  [0:3];
	reg signed [15:0] left_mv_y  [0:3];

	// Bottom-right 4x4 of the above-left macroblock, latched out of the row
	// buffer just before that column is overwritten.
	reg               tl_inter;
	reg        [1:0]  tl_ref;
	reg signed [15:0] tl_mv_x;
	reg signed [15:0] tl_mv_y;

	wire [2:0] q_sx = q_x[4:2];
	wire [2:0] q_sy = q_y[4:2];
	wire [2:0] q_w4 = q_w[4:2];

	// Neighbour coordinates in 4x4 units, offset by +1 so they stay unsigned:
	// 0 means "one block above/left of the macroblock".
	wire [3:0] a_cx = {1'b0, q_sx};              // q_sx - 1 + 1
	wire [3:0] a_cy = {1'b0, q_sy} + 4'd1;
	wire [3:0] b_cx = {1'b0, q_sx} + 4'd1;
	wire [3:0] b_cy = {1'b0, q_sy};
	wire [3:0] c_cx = {1'b0, q_sx} + {1'b0, q_w4} + 4'd1;
	wire [3:0] c_cy = {1'b0, q_sy};
	wire [3:0] d_cx = {1'b0, q_sx};
	wire [3:0] d_cy = {1'b0, q_sy};

	wire [3:0] tap_cx [0:3];
	wire [3:0] tap_cy [0:3];
	assign tap_cx[0] = a_cx;  assign tap_cy[0] = a_cy;
	assign tap_cx[1] = b_cx;  assign tap_cy[1] = b_cy;
	assign tap_cx[2] = c_cx;  assign tap_cy[2] = c_cy;
	assign tap_cx[3] = d_cx;  assign tap_cy[3] = d_cy;

	wire               tap_present [0:3];
	wire               tap_inter   [0:3];
	wire        [1:0]  tap_ref     [0:3];
	wire signed [15:0] tap_mv_x    [0:3];
	wire signed [15:0] tap_mv_y    [0:3];

	genvar t;
	generate
		for (t = 0; t < 4; t = t + 1) begin : g_tap
			wire [3:0] cx = tap_cx[t];
			wire [3:0] cy = tap_cy[t];
			wire above_row = (cy == 4'd0);          // one 4x4 row above the MB
			wire left_col  = (cx == 4'd0);          // one 4x4 col left of the MB
			// cx / cy are biased by +1: 0 means one 4x4 outside the
			// macroblock, 1..4 are the macroblock's own columns / rows.
			wire [2:0] ixw = cx[2:0] - 3'd1;
			wire [2:0] iyw = cy[2:0] - 3'd1;
			wire [1:0] ix = left_col ? 2'd0 : ixw[1:0];
			wire [1:0] iy = above_row ? 2'd0 : iyw[1:0];
			wire right_of_mb = (cx >= 4'd5);        // col 4 or beyond
			wire below_mb = (cy >= 4'd5);

			// Index into the current macroblock's own 4x4 field.
			wire [3:0] cur_i = {iy, ix};

			assign tap_present[t] =
				above_row ? (left_col        ? avail_tl :
				             right_of_mb     ? avail_tr : avail_top)
				          : (left_col        ? avail_left :
				             (right_of_mb || below_mb) ? 1'b0 : cur_set[cur_i]);

			assign tap_inter[t] =
				above_row ? (left_col    ? tl_inter :
				             right_of_mb ? above_inter[col_right][0]
				                         : above_inter[col_cur][ix])
				          : (left_col    ? left_inter[iy] : cur_inter[cur_i]);
			assign tap_ref[t] =
				above_row ? (left_col    ? tl_ref :
				             right_of_mb ? above_ref[col_right][0]
				                         : above_ref[col_cur][ix])
				          : (left_col    ? left_ref[iy] : cur_ref[cur_i]);
			assign tap_mv_x[t] =
				above_row ? (left_col    ? tl_mv_x :
				             right_of_mb ? above_mv_x[col_right][0]
				                         : above_mv_x[col_cur][ix])
				          : (left_col    ? left_mv_x[iy] : cur_mv_x[cur_i]);
			assign tap_mv_y[t] =
				above_row ? (left_col    ? tl_mv_y :
				             right_of_mb ? above_mv_y[col_right][0]
				                         : above_mv_y[col_cur][ix])
				          : (left_col    ? left_mv_y[iy] : cur_mv_y[cur_i]);
		end
	endgenerate

	assign nb_a_present = tap_present[0];
	assign nb_a_inter   = tap_inter[0];
	assign nb_a_ref     = tap_ref[0];
	assign nb_a_mv_x    = tap_mv_x[0];
	assign nb_a_mv_y    = tap_mv_y[0];

	assign nb_b_present = tap_present[1];
	assign nb_b_inter   = tap_inter[1];
	assign nb_b_ref     = tap_ref[1];
	assign nb_b_mv_x    = tap_mv_x[1];
	assign nb_b_mv_y    = tap_mv_y[1];

	assign nb_c_present = tap_present[2];
	assign nb_c_inter   = tap_inter[2];
	assign nb_c_ref     = tap_ref[2];
	assign nb_c_mv_x    = tap_mv_x[2];
	assign nb_c_mv_y    = tap_mv_y[2];

	assign nb_d_present = tap_present[3];
	assign nb_d_inter   = tap_inter[3];
	assign nb_d_ref     = tap_ref[3];
	assign nb_d_mv_x    = tap_mv_x[3];
	assign nb_d_mv_y    = tap_mv_y[3];

	integer bi, ci;
	always @(posedge clk) begin
		if (reset) begin
			for (bi = 0; bi < 16; bi = bi + 1) begin
				cur_set[bi] <= 1'b0;
				cur_inter[bi] <= 1'b0;
				cur_ref[bi] <= 2'd0;
				cur_mv_x[bi] <= 16'sd0;
				cur_mv_y[bi] <= 16'sd0;
			end
			for (ci = 0; ci < MB_WIDTH_MAX; ci = ci + 1)
				for (bi = 0; bi < 4; bi = bi + 1) begin
					above_inter[ci][bi] <= 1'b0;
					above_ref[ci][bi] <= 2'd0;
					above_mv_x[ci][bi] <= 16'sd0;
					above_mv_y[ci][bi] <= 16'sd0;
				end
			for (bi = 0; bi < 4; bi = bi + 1) begin
				left_inter[bi] <= 1'b0;
				left_ref[bi] <= 2'd0;
				left_mv_x[bi] <= 16'sd0;
				left_mv_y[bi] <= 16'sd0;
			end
			tl_inter <= 1'b0;
			tl_ref <= 2'd0;
			tl_mv_x <= 16'sd0;
			tl_mv_y <= 16'sd0;
		end else begin
			if (mb_start)
				for (bi = 0; bi < 16; bi = bi + 1)
					cur_set[bi] <= 1'b0;

			if (blk_wr_valid)
				for (bi = 0; bi < 16; bi = bi + 1)
					if (blk_wr_mask[bi]) begin
						cur_set[bi] <= 1'b1;
						cur_inter[bi] <= blk_wr_inter;
						cur_ref[bi] <= blk_wr_inter ? blk_wr_ref : 2'd0;
						cur_mv_x[bi] <= blk_wr_inter ? blk_wr_mv_x : 16'sd0;
						cur_mv_y[bi] <= blk_wr_inter ? blk_wr_mv_y : 16'sd0;
					end

			if (mb_commit) begin
				// The above-left tap of the NEXT column is the value this
				// column is about to overwrite.
				tl_inter <= above_inter[col_commit][3];
				tl_ref <= above_ref[col_commit][3];
				tl_mv_x <= above_mv_x[col_commit][3];
				tl_mv_y <= above_mv_y[col_commit][3];

				for (bi = 0; bi < 4; bi = bi + 1) begin
					// Bottom 4x4 row becomes the above row for the next MB row.
					above_inter[col_commit][bi] <= cur_inter[12 + bi];
					above_ref[col_commit][bi] <= cur_ref[12 + bi];
					above_mv_x[col_commit][bi] <= cur_mv_x[12 + bi];
					above_mv_y[col_commit][bi] <= cur_mv_y[12 + bi];
					// Right 4x4 column becomes the left column for the next MB.
					left_inter[bi] <= cur_inter[bi * 4 + 3];
					left_ref[bi] <= cur_ref[bi * 4 + 3];
					left_mv_x[bi] <= cur_mv_x[bi * 4 + 3];
					left_mv_y[bi] <= cur_mv_y[bi * 4 + 3];
				end
			end
		end
	end
endmodule

module h264_part_geometry (
	input  wire [2:0]  part_mode,     // 0=16x16, 1=16x8, 2=8x16, 3=8x8
	input  wire [3:0]  slot,
	input  wire [1:0]  sub_mb_type,   // sub_mb_type of slot[3:2] when part_mode==3
	output reg  [4:0]  part_x,
	output reg  [4:0]  part_y,
	output reg  [4:0]  part_w,
	output reg  [4:0]  part_h,
	output reg         part_valid     // slot exists for this shape
);
	wire [1:0] blk = slot[3:2];
	wire [1:0] sub = slot[1:0];
	wire [4:0] blk_x = blk[0] ? 5'd8 : 5'd0;
	wire [4:0] blk_y = blk[1] ? 5'd8 : 5'd0;

	always @* begin
		part_x = 5'd0;
		part_y = 5'd0;
		part_w = 5'd16;
		part_h = 5'd16;
		part_valid = 1'b0;

		case (part_mode)
		3'd0: begin
			part_valid = (slot == 4'd0);
		end
		3'd1: begin // 16x8
			part_valid = (slot <= 4'd1);
			part_w = 5'd16;
			part_h = 5'd8;
			part_y = slot[0] ? 5'd8 : 5'd0;
		end
		3'd2: begin // 8x16
			part_valid = (slot <= 4'd1);
			part_w = 5'd8;
			part_h = 5'd16;
			part_x = slot[0] ? 5'd8 : 5'd0;
		end
		default: begin // 8x8 with sub-partitions
			case (sub_mb_type)
			2'd0: begin // 8x8
				part_valid = (sub == 2'd0);
				part_x = blk_x;
				part_y = blk_y;
				part_w = 5'd8;
				part_h = 5'd8;
			end
			2'd1: begin // 8x4
				part_valid = (sub <= 2'd1);
				part_x = blk_x;
				part_y = blk_y + {2'd0, sub[0], 2'd0};
				part_w = 5'd8;
				part_h = 5'd4;
			end
			2'd2: begin // 4x8
				part_valid = (sub <= 2'd1);
				part_x = blk_x + {2'd0, sub[0], 2'd0};
				part_y = blk_y;
				part_w = 5'd4;
				part_h = 5'd8;
			end
			default: begin // 4x4
				part_valid = 1'b1;
				part_x = blk_x + {2'd0, sub[0], 2'd0};
				part_y = blk_y + {2'd0, sub[1], 2'd0};
				part_w = 5'd4;
				part_h = 5'd4;
			end
			endcase
		end
		endcase
	end
endmodule

module h264_part_mask (
	input  wire [4:0]  part_x,
	input  wire [4:0]  part_y,
	input  wire [4:0]  part_w,
	input  wire [4:0]  part_h,
	output wire [15:0] mask
);
	genvar mi;
	generate
		for (mi = 0; mi < 16; mi = mi + 1) begin : g_mask
			localparam [4:0] MX = 5'((mi % 4) * 4);
			localparam [4:0] MY = 5'((mi / 4) * 4);
			assign mask[mi] = (MX >= part_x) && (MX < (part_x + part_w)) &&
			                  (MY >= part_y) && (MY < (part_y + part_h));
		end
	endgenerate
endmodule

module h264_mv_pred_partition (
	input  wire [2:0]  part_mode,    // 0=16x16, 1=16x8, 2=8x16, 3=8x8
	input  wire [3:0]  slot,
	input  wire [1:0]  ref_idx_l0,

	input  wire               nb_a_present,
	input  wire               nb_a_inter,
	input  wire        [1:0]  nb_a_ref,
	input  wire signed [15:0] nb_a_mv_x,
	input  wire signed [15:0] nb_a_mv_y,

	input  wire               nb_b_present,
	input  wire               nb_b_inter,
	input  wire        [1:0]  nb_b_ref,
	input  wire signed [15:0] nb_b_mv_x,
	input  wire signed [15:0] nb_b_mv_y,

	input  wire               nb_c_present,
	input  wire               nb_c_inter,
	input  wire        [1:0]  nb_c_ref,
	input  wire signed [15:0] nb_c_mv_x,
	input  wire signed [15:0] nb_c_mv_y,

	input  wire               nb_d_present,
	input  wire               nb_d_inter,
	input  wire        [1:0]  nb_d_ref,
	input  wire signed [15:0] nb_d_mv_x,
	input  wire signed [15:0] nb_d_mv_y,

	output wire signed [15:0] mvp_x,
	output wire signed [15:0] mvp_y,
	output wire               shape_override
);
	wire signed [15:0] general_x;
	wire signed [15:0] general_y;
	wire               general_directional;

	h264_pskip_mv_pred u_general (
		.ref_idx_l0(ref_idx_l0),
		.nb_a_present(nb_a_present), .nb_a_inter(nb_a_inter), .nb_a_ref(nb_a_ref),
		.nb_a_mv_x(nb_a_mv_x), .nb_a_mv_y(nb_a_mv_y),
		.nb_b_present(nb_b_present), .nb_b_inter(nb_b_inter), .nb_b_ref(nb_b_ref),
		.nb_b_mv_x(nb_b_mv_x), .nb_b_mv_y(nb_b_mv_y),
		.nb_c_present(nb_c_present), .nb_c_inter(nb_c_inter), .nb_c_ref(nb_c_ref),
		.nb_c_mv_x(nb_c_mv_x), .nb_c_mv_y(nb_c_mv_y),
		.nb_d_present(nb_d_present), .nb_d_inter(nb_d_inter), .nb_d_ref(nb_d_ref),
		.nb_d_mv_x(nb_d_mv_x), .nb_d_mv_y(nb_d_mv_y),
		.mvp_x(general_x),
		.mvp_y(general_y),
		.directional(general_directional)
	);

	// Same mbAddrC -> mbAddrD substitution the general rule performs.
	wire        c_sub_present = nb_c_present ? nb_c_present : nb_d_present;
	wire        c_sub_inter   = nb_c_present ? nb_c_inter   : nb_d_inter;
	wire [1:0]  c_sub_ref     = nb_c_present ? nb_c_ref     : nb_d_ref;
	wire signed [15:0] c_sub_mv_x = nb_c_present ? nb_c_mv_x : nb_d_mv_x;
	wire signed [15:0] c_sub_mv_y = nb_c_present ? nb_c_mv_y : nb_d_mv_y;

	wire a_match = nb_a_present && nb_a_inter && (nb_a_ref == ref_idx_l0);
	wire b_match = nb_b_present && nb_b_inter && (nb_b_ref == ref_idx_l0);
	wire c_match = c_sub_present && c_sub_inter && (c_sub_ref == ref_idx_l0);

	wire is_16x8 = (part_mode == 3'd1);
	wire is_8x16 = (part_mode == 3'd2);
	wire part1 = slot[0];

	wire use_b = is_16x8 && !part1 && b_match;
	wire use_a = (is_16x8 && part1 && a_match) || (is_8x16 && !part1 && a_match);
	wire use_c = is_8x16 && part1 && c_match;

	assign shape_override = use_a || use_b || use_c;

	assign mvp_x = use_b ? nb_b_mv_x :
	               use_a ? nb_a_mv_x :
	               use_c ? c_sub_mv_x : general_x;
	assign mvp_y = use_b ? nb_b_mv_y :
	               use_a ? nb_a_mv_y :
	               use_c ? c_sub_mv_y : general_y;
endmodule

`default_nettype wire
