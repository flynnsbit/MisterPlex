// H.264 inter motion-vector neighbour context store.
// Mirrors h264_intra_nb_ctx conventions for cross-MB availability:
//   A = left, B = above, C = above-right (falls back to D = above-left when C missing).
// Stores one final MV per MB (P_L0_16x16 / P_Skip primary path) plus the
// left/above line needed for median MVP across the MB row.
//
// Storage:
//   - Above-row line buffer: MB_WIDTH_MAX entries (mv_x, mv_y, ref, valid)
//   - Left MB registers
//   - Above-left (D) corner latched at mb_start
//   - Within-MB partition slots for 16x8 / 8x16 / 8x8 (up to 4)

`default_nettype none

module h264_inter_nb_ctx #(
	parameter int MB_WIDTH_MAX = 40
) (
	input  wire               clk,
	input  wire               reset,

	input  wire [7:0]         mb_x,
	input  wire [7:0]         mb_y,
	input  wire [7:0]         mb_width,
	input  wire               mb_start,     // pulse: new MB; latches D from above-left

	// Partition being predicted (before commit)
	input  wire [2:0]         part_mode,    // 0=16x16 1=16x8 2=8x16 3=8x8 4=sub
	input  wire [1:0]         part_idx,

	// Commit final MV after mvp+mvd (or P_Skip pred)
	input  wire               commit,
	input  wire               is_inter,     // 0 => mark this MB unavailable for later MVP
	input  wire signed [15:0] mv_x,
	input  wire signed [15:0] mv_y,
	input  wire [1:0]         ref_idx,

	// Neighbour outputs for the current partition
	output reg                avail_a,
	output reg                avail_b,
	output reg                avail_c,
	output reg                avail_d,
	output reg  signed [15:0] mv_a_x,
	output reg  signed [15:0] mv_a_y,
	output reg  signed [15:0] mv_b_x,
	output reg  signed [15:0] mv_b_y,
	output reg  signed [15:0] mv_c_x,
	output reg  signed [15:0] mv_c_y,
	output reg  signed [15:0] mv_d_x,
	output reg  signed [15:0] mv_d_y,
	output reg  [1:0]         ref_a,
	output reg  [1:0]         ref_b,
	output reg  [1:0]         ref_c,
	output reg  [1:0]         ref_d
);
	localparam [2:0] PART_P16x16 = 3'd0;
	localparam [2:0] PART_P16x8  = 3'd1;
	localparam [2:0] PART_P8x16  = 3'd2;
	localparam [2:0] PART_P8x8   = 3'd3;
	localparam int AW = (MB_WIDTH_MAX <= 1) ? 1 : $clog2(MB_WIDTH_MAX);

	wire [AW-1:0] mb_x_i  = mb_x[AW-1:0];
	wire [AW-1:0] mb_xr_i = mb_x[AW-1:0] + AW'(1);

	// Above-row line buffer (one MV sample per MB column)
	(* ramstyle = "M10K" *) reg signed [15:0] above_mv_x   [0:MB_WIDTH_MAX-1];
	(* ramstyle = "M10K" *) reg signed [15:0] above_mv_y   [0:MB_WIDTH_MAX-1];
	(* ramstyle = "M10K" *) reg        [1:0]  above_ref    [0:MB_WIDTH_MAX-1];
	(* ramstyle = "M10K" *) reg               above_valid  [0:MB_WIDTH_MAX-1];

	// Left MB
	reg signed [15:0] left_mv_x;
	reg signed [15:0] left_mv_y;
	reg        [1:0]  left_ref;
	reg               left_valid;

	// Above-left corner (D). Sliding window: each mb_start captures the
	// previous column's above-row sample (from the prior row) before this
	// row overwrites above[mb_x]. Without the slide, finishing MB(x-1,y)
	// would clobber above[x-1] and destroy D for MB(x,y).
	reg signed [15:0] d_mv_x;
	reg signed [15:0] d_mv_y;
	reg        [1:0]  d_ref;
	reg               d_valid;
	reg signed [15:0] col_al_mv_x;
	reg signed [15:0] col_al_mv_y;
	reg        [1:0]  col_al_ref;
	reg               col_al_valid;

	// Within-MB partition MVs (up to 4 for 8x8)
	reg signed [15:0] part_mv_x [0:3];
	reg signed [15:0] part_mv_y [0:3];
	reg        [1:0]  part_ref  [0:3];
	reg               part_valid[0:3];
	reg        [2:0]  cur_part_mode;
	reg               cur_is_inter;

	// Row-complete writeback of this MB's representative MV into above[]
	// Representative = last committed partition (for 16x16 that is the only one).
	reg signed [15:0] mb_mv_x;
	reg signed [15:0] mb_mv_y;
	reg        [1:0]  mb_ref;
	reg               mb_valid;
	reg               mb_done_pending;

	integer ai;
	always @(posedge clk) begin
		if (reset) begin
			left_mv_x <= 16'sd0;
			left_mv_y <= 16'sd0;
			left_ref <= 2'd0;
			left_valid <= 1'b0;
			d_mv_x <= 16'sd0;
			d_mv_y <= 16'sd0;
			d_ref <= 2'd0;
			d_valid <= 1'b0;
			col_al_mv_x <= 16'sd0;
			col_al_mv_y <= 16'sd0;
			col_al_ref <= 2'd0;
			col_al_valid <= 1'b0;
			mb_mv_x <= 16'sd0;
			mb_mv_y <= 16'sd0;
			mb_ref <= 2'd0;
			mb_valid <= 1'b0;
			mb_done_pending <= 1'b0;
			cur_part_mode <= PART_P16x16;
			cur_is_inter <= 1'b0;
			for (ai = 0; ai < 4; ai = ai + 1) begin
				part_mv_x[ai] <= 16'sd0;
				part_mv_y[ai] <= 16'sd0;
				part_ref[ai] <= 2'd0;
				part_valid[ai] <= 1'b0;
			end
			for (ai = 0; ai < MB_WIDTH_MAX; ai = ai + 1) begin
				above_mv_x[ai] <= 16'sd0;
				above_mv_y[ai] <= 16'sd0;
				above_ref[ai] <= 2'd0;
				above_valid[ai] <= 1'b0;
			end
		end else begin
			if (mb_start) begin
				// D = sliding previous-column above sample (prior row)
				if (mb_x != 8'd0 && mb_y != 8'd0)
					d_valid <= col_al_valid;
				else
					d_valid <= 1'b0;
				d_mv_x <= col_al_mv_x;
				d_mv_y <= col_al_mv_y;
				d_ref  <= col_al_ref;

				// Slide: current above[mb_x] becomes D for the next MB on this row
				if (mb_y != 8'd0 && mb_x < MB_WIDTH_MAX[7:0]) begin
					col_al_valid <= above_valid[mb_x_i];
					col_al_mv_x  <= above_mv_x[mb_x_i];
					col_al_mv_y  <= above_mv_y[mb_x_i];
					col_al_ref   <= above_ref[mb_x_i];
				end else begin
					col_al_valid <= 1'b0;
					col_al_mv_x  <= 16'sd0;
					col_al_mv_y  <= 16'sd0;
					col_al_ref   <= 2'd0;
				end

				// Clear within-MB partition slots
				for (ai = 0; ai < 4; ai = ai + 1) begin
					part_mv_x[ai] <= 16'sd0;
					part_mv_y[ai] <= 16'sd0;
					part_ref[ai] <= 2'd0;
					part_valid[ai] <= 1'b0;
				end
				mb_valid <= 1'b0;
				mb_done_pending <= 1'b0;
				cur_part_mode <= part_mode;
				cur_is_inter <= 1'b0;
			end

			if (commit) begin
				cur_is_inter <= is_inter;
				cur_part_mode <= part_mode;
				if (is_inter) begin
					part_mv_x[part_idx] <= mv_x;
					part_mv_y[part_idx] <= mv_y;
					part_ref[part_idx] <= ref_idx;
					part_valid[part_idx] <= 1'b1;
					// Representative MV for cross-MB (right / bottom edge sample)
					mb_mv_x <= mv_x;
					mb_mv_y <= mv_y;
					mb_ref <= ref_idx;
					mb_valid <= 1'b1;
				end else begin
					mb_valid <= 1'b0;
				end

				// End-of-MB detection: last partition index for the mode
				if ((part_mode == PART_P16x16 && part_idx == 2'd0) ||
				    (part_mode == PART_P16x8  && part_idx == 2'd1) ||
				    (part_mode == PART_P8x16  && part_idx == 2'd1) ||
				    ((part_mode == PART_P8x8 || part_mode == 3'd4) && part_idx == 2'd3) ||
				    !is_inter) begin
					mb_done_pending <= 1'b1;
				end
			end

			// Publish left + above after MB completes (one cycle after last commit)
			if (mb_done_pending) begin
				mb_done_pending <= 1'b0;
				if (mb_x < MB_WIDTH_MAX[7:0]) begin
					above_mv_x[mb_x_i] <= mb_mv_x;
					above_mv_y[mb_x_i] <= mb_mv_y;
					above_ref[mb_x_i] <= mb_ref;
					above_valid[mb_x_i] <= mb_valid && cur_is_inter;
				end
				left_mv_x <= mb_mv_x;
				left_mv_y <= mb_mv_y;
				left_ref <= mb_ref;
				left_valid <= mb_valid && cur_is_inter;
				// At end of row, left is not valid for next row's first MB
				if (mb_x + 8'd1 >= mb_width)
					left_valid <= 1'b0;
			end
		end
	end

	// Combinational neighbour select for current partition
	// Spec 6.4.11.7 / 8.4.1.3: A left, B above, C above-right, D above-left.
	// Within-MB: for 16x8 bottom, A is left MB still (same), B is top partition;
	//            for 8x16 right, A is left partition, C is above-right of right half.
	wire row_has_above = (mb_y != 8'd0);
	wire col_has_left  = (mb_x != 8'd0);
	wire col_has_right = (mb_x + 8'd1 < mb_width);

	wire above_v = row_has_above && above_valid[mb_x_i];
	wire above_r_v = row_has_above && col_has_right && above_valid[mb_xr_i];
	wire above_l_v = row_has_above && col_has_left && d_valid;
	wire left_v = col_has_left && left_valid;

	// Within-MB partition neighbours
	wire part_left_v  = (part_mode == PART_P8x16 && part_idx == 2'd1 && part_valid[0]) ||
	                    (part_mode == PART_P8x8  && (part_idx == 2'd1 || part_idx == 2'd3) &&
	                     part_valid[{part_idx[1], 1'b0}]);
	wire part_above_v = (part_mode == PART_P16x8 && part_idx == 2'd1 && part_valid[0]) ||
	                    (part_mode == PART_P8x8  && (part_idx == 2'd2 || part_idx == 2'd3) &&
	                     part_valid[{1'b0, part_idx[0]}]);

	always @* begin
		// Defaults: cross-MB
		avail_a = left_v;
		mv_a_x = left_mv_x;
		mv_a_y = left_mv_y;
		ref_a = left_ref;

		avail_b = above_v;
		mv_b_x = above_mv_x[mb_x_i];
		mv_b_y = above_mv_y[mb_x_i];
		ref_b = above_ref[mb_x_i];

		avail_c = above_r_v;
		mv_c_x = above_mv_x[mb_xr_i];
		mv_c_y = above_mv_y[mb_xr_i];
		ref_c = above_ref[mb_xr_i];

		avail_d = above_l_v;
		mv_d_x = d_mv_x;
		mv_d_y = d_mv_y;
		ref_d = d_ref;

		// Within-MB overrides
		if (part_mode == PART_P16x8 && part_idx == 2'd1 && part_valid[0]) begin
			// Bottom 16x8: B = top partition of this MB
			avail_b = 1'b1;
			mv_b_x = part_mv_x[0];
			mv_b_y = part_mv_y[0];
			ref_b = part_ref[0];
			// C unavailable inside MB bottom; D = top (same as B source for left-above of bottom)
			avail_c = 1'b0;
		end

		if (part_mode == PART_P8x16 && part_idx == 2'd1 && part_valid[0]) begin
			// Right 8x16: A = left partition of this MB
			avail_a = 1'b1;
			mv_a_x = part_mv_x[0];
			mv_a_y = part_mv_y[0];
			ref_a = part_ref[0];
			// D = above of left partition path: still above-left of whole MB
		end

		if (part_mode == PART_P8x8 || part_mode == 3'd4) begin
			// 8x8 blocks: 0=TL 1=TR 2=BL 3=BR
			if (part_idx == 2'd1 && part_valid[0]) begin
				avail_a = 1'b1;
				mv_a_x = part_mv_x[0];
				mv_a_y = part_mv_y[0];
				ref_a = part_ref[0];
			end
			if (part_idx == 2'd2 && part_valid[0]) begin
				avail_b = 1'b1;
				mv_b_x = part_mv_x[0];
				mv_b_y = part_mv_y[0];
				ref_b = part_ref[0];
				avail_c = part_valid[1];
				mv_c_x = part_mv_x[1];
				mv_c_y = part_mv_y[1];
				ref_c = part_ref[1];
			end
			if (part_idx == 2'd3) begin
				if (part_valid[2]) begin
					avail_a = 1'b1;
					mv_a_x = part_mv_x[2];
					mv_a_y = part_mv_y[2];
					ref_a = part_ref[2];
				end
				if (part_valid[1]) begin
					avail_b = 1'b1;
					mv_b_x = part_mv_x[1];
					mv_b_y = part_mv_y[1];
					ref_b = part_ref[1];
				end
				avail_c = 1'b0;
				if (part_valid[0]) begin
					avail_d = 1'b1;
					mv_d_x = part_mv_x[0];
					mv_d_y = part_mv_y[0];
					ref_d = part_ref[0];
				end
			end
		end
	end
endmodule

`default_nettype wire
