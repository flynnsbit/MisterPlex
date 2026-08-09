// H.264 Baseline P_Skip macroblock support.
//
// Contents:
//   h264_pskip_mv_pred    - luma MV prediction, spec 8.4.1.3 (median + the
//                           directional and substitution rules)
//   h264_pskip_mv         - P_Skip MV derivation, spec 8.4.1.1
//   h264_pskip_nb_ctx     - per-MB-row motion neighbour store feeding A/B/C/D
//   h264_mb_skip_run_track- CAVLC mb_skip_run run tracking across macroblocks
//   h264_pskip_mc_copy    - reference fetch request generator for the skipped
//                           macroblock copy
//
// Measured PMS stream: profile_idc=66 Baseline, CAVLC, max_num_ref_frames=1,
// coded 624x480 = 39x30 macroblocks. A typical P frame carries 928 P_Skip MBs
// out of 1170, so this path reconstructs most of the inter picture. Because
// max_num_ref_frames is 1 every inter refIdxL0 in the stream is 0; the RTL
// still carries refIdx so the neighbour rules stay spec-correct (an intra
// neighbour has refIdxL0 = -1, which is NOT refIdx 0).
//
// Sample taps:
//   * Motion compensation and reference-picture reads use POST-deblocking
//     samples (the DPB reference planes).
//   * Intra neighbour taps use PRE-deblocking samples (h264_intra_nb_ctx).
//
// Deblocking: a skipped macroblock is a normally coded macroblock as far as
// clause 8.7 is concerned. The future deblocking filter must NOT skip P_Skip
// macroblocks - their edges are filtered with bS derived by the usual rules
// (bS is typically 0..1 because the residual is empty, but the MV/ref
// comparisons can still raise it).

`default_nettype none

// ---------------------------------------------------------------------------
// Luma motion vector prediction, spec 8.4.1.3 / 8.4.1.3.1.
//
// Neighbour convention (spec 6.4.11.7):
//   A = left, B = above, C = above-right, D = above-left.
//
// Each neighbour is described by two flags:
//   nb_*_present : mbAddrN exists (inside the picture and inside this slice)
//   nb_*_inter   : mbAddrN is present AND is inter coded with predFlagL0 = 1
// An intra neighbour is present but not inter: its mvL0 is treated as (0,0)
// and its refIdxL0 as -1. That distinction is what keeps the P_Skip special
// cases correct.
// ---------------------------------------------------------------------------
module h264_pskip_mv_pred (
	input  wire        [1:0]  ref_idx_l0,   // refIdxL0 of the current partition

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
	output wire               directional   // exactly-one-match rule selected
);
	localparam signed [2:0] REF_NONE = -3'sd1;

	function automatic signed [15:0] min2(input signed [15:0] a, input signed [15:0] b);
		min2 = (a < b) ? a : b;
	endfunction

	function automatic signed [15:0] max2(input signed [15:0] a, input signed [15:0] b);
		max2 = (a > b) ? a : b;
	endfunction

	function automatic signed [15:0] median3(
		input signed [15:0] a,
		input signed [15:0] b,
		input signed [15:0] c
	);
		median3 = a + b + c - min2(min2(a, b), c) - max2(max2(a, b), c);
	endfunction

	wire signed [2:0] ref_cur = $signed({1'b0, ref_idx_l0});

	// Stage 1: mbAddrC substitution by mbAddrD (8.4.1.3.1). When mbAddrC is not
	// available the D neighbour takes its place wholesale, including refIdx.
	wire        c_sub_present = nb_c_present ? nb_c_present : nb_d_present;
	wire        c_sub_inter   = nb_c_present ? nb_c_inter   : nb_d_inter;
	wire [1:0]  c_sub_ref     = nb_c_present ? nb_c_ref     : nb_d_ref;
	wire signed [15:0] c_sub_mv_x = nb_c_present ? nb_c_mv_x : nb_d_mv_x;
	wire signed [15:0] c_sub_mv_y = nb_c_present ? nb_c_mv_y : nb_d_mv_y;

	// Stage 2: when both B and C are unavailable and A is available, B and C
	// inherit A (8.4.1.3.1).
	wire bc_from_a = (!nb_b_present) && (!c_sub_present) && nb_a_present;

	wire        b_eff_present = bc_from_a ? nb_a_present : nb_b_present;
	wire        b_eff_inter   = bc_from_a ? nb_a_inter   : nb_b_inter;
	wire [1:0]  b_eff_ref     = bc_from_a ? nb_a_ref     : nb_b_ref;
	wire signed [15:0] b_eff_mv_x = bc_from_a ? nb_a_mv_x : nb_b_mv_x;
	wire signed [15:0] b_eff_mv_y = bc_from_a ? nb_a_mv_y : nb_b_mv_y;

	wire        c_eff_present = bc_from_a ? nb_a_present : c_sub_present;
	wire        c_eff_inter   = bc_from_a ? nb_a_inter   : c_sub_inter;
	wire [1:0]  c_eff_ref     = bc_from_a ? nb_a_ref     : c_sub_ref;
	wire signed [15:0] c_eff_mv_x = bc_from_a ? nb_a_mv_x : c_sub_mv_x;
	wire signed [15:0] c_eff_mv_y = bc_from_a ? nb_a_mv_y : c_sub_mv_y;

	// Stage 3: unavailable / intra neighbours contribute mv (0,0), refIdx -1.
	wire a_usable = nb_a_present && nb_a_inter;
	wire b_usable = b_eff_present && b_eff_inter;
	wire c_usable = c_eff_present && c_eff_inter;

	wire signed [2:0] ref_a = a_usable ? $signed({1'b0, nb_a_ref})   : REF_NONE;
	wire signed [2:0] ref_b = b_usable ? $signed({1'b0, b_eff_ref})  : REF_NONE;
	wire signed [2:0] ref_c = c_usable ? $signed({1'b0, c_eff_ref})  : REF_NONE;

	wire signed [15:0] mv_a_x = a_usable ? nb_a_mv_x   : 16'sd0;
	wire signed [15:0] mv_a_y = a_usable ? nb_a_mv_y   : 16'sd0;
	wire signed [15:0] mv_b_x = b_usable ? b_eff_mv_x  : 16'sd0;
	wire signed [15:0] mv_b_y = b_usable ? b_eff_mv_y  : 16'sd0;
	wire signed [15:0] mv_c_x = c_usable ? c_eff_mv_x  : 16'sd0;
	wire signed [15:0] mv_c_y = c_usable ? c_eff_mv_y  : 16'sd0;

	// Stage 4: directional rule - if exactly one neighbour uses refIdxL0, its
	// motion vector is the predictor; otherwise take the component median.
	wire match_a = (ref_a == ref_cur);
	wire match_b = (ref_b == ref_cur);
	wire match_c = (ref_c == ref_cur);
	wire [1:0] match_count = {1'b0, match_a} + {1'b0, match_b} + {1'b0, match_c};

	assign directional = (match_count == 2'd1);

	assign mvp_x = directional ? (match_a ? mv_a_x : (match_b ? mv_b_x : mv_c_x))
	                           : median3(mv_a_x, mv_b_x, mv_c_x);
	assign mvp_y = directional ? (match_a ? mv_a_y : (match_b ? mv_b_y : mv_c_y))
	                           : median3(mv_a_y, mv_b_y, mv_c_y);
endmodule

// ---------------------------------------------------------------------------
// P_Skip motion vector derivation, spec 8.4.1.1.
//
// mvL0 is (0,0) when ANY of the following holds:
//   1. mbAddrA is not available
//   2. mbAddrB is not available
//   3. refIdxL0A == 0 AND mvL0A == (0,0)
//   4. refIdxL0B == 0 AND mvL0B == (0,0)
// Otherwise mvL0 is the 8.4.1.3 prediction for a 16x16 partition with
// refIdxL0 = 0. P_Skip carries no mvd, so mvL0 == mvpL0.
//
// Notes on the traps in cases 3 and 4:
//   * "not available" means the macroblock address itself is unavailable
//     (outside the picture, or before first_mb_in_slice). An intra neighbour is
//     available, so cases 1/2 do NOT fire for it.
//   * An intra neighbour has refIdxL0 = -1, so cases 3/4 do NOT fire for it
//     either even though its motion vector reads back as (0,0). Treating an
//     intra neighbour as a zero-MV refIdx-0 neighbour forces a spurious zero MV
//     and is the classic source of slow inter drift.
//   * The refIdx test is against 0 specifically, not against "same refIdx as
//     the current MB". They coincide here only because P_Skip always uses
//     refIdxL0 = 0.
// ---------------------------------------------------------------------------
module h264_pskip_mv (
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

	output wire signed [15:0] mv_x,        // quarter-pel luma MV
	output wire signed [15:0] mv_y,
	output wire        [1:0]  ref_idx_l0,  // always 0 for P_Skip
	output wire signed [15:0] mvp_x,       // 8.4.1.3 prediction before the
	output wire signed [15:0] mvp_y,       //   special cases are applied
	output wire               zero_mv,     // any special case fired
	output wire        [3:0]  zero_reason  // {caseB0, caseA0, noB, noA}
);
	assign ref_idx_l0 = 2'd0;

	h264_pskip_mv_pred u_pred (
		.ref_idx_l0(2'd0),
		.nb_a_present(nb_a_present), .nb_a_inter(nb_a_inter), .nb_a_ref(nb_a_ref),
		.nb_a_mv_x(nb_a_mv_x), .nb_a_mv_y(nb_a_mv_y),
		.nb_b_present(nb_b_present), .nb_b_inter(nb_b_inter), .nb_b_ref(nb_b_ref),
		.nb_b_mv_x(nb_b_mv_x), .nb_b_mv_y(nb_b_mv_y),
		.nb_c_present(nb_c_present), .nb_c_inter(nb_c_inter), .nb_c_ref(nb_c_ref),
		.nb_c_mv_x(nb_c_mv_x), .nb_c_mv_y(nb_c_mv_y),
		.nb_d_present(nb_d_present), .nb_d_inter(nb_d_inter), .nb_d_ref(nb_d_ref),
		.nb_d_mv_x(nb_d_mv_x), .nb_d_mv_y(nb_d_mv_y),
		.mvp_x(mvp_x),
		.mvp_y(mvp_y),
		.directional()
	);

	// refIdxL0N of an intra or non-inter neighbour is -1, never 0.
	wire a_ref_zero = nb_a_present && nb_a_inter && (nb_a_ref == 2'd0);
	wire b_ref_zero = nb_b_present && nb_b_inter && (nb_b_ref == 2'd0);
	wire a_mv_zero  = (nb_a_mv_x == 16'sd0) && (nb_a_mv_y == 16'sd0);
	wire b_mv_zero  = (nb_b_mv_x == 16'sd0) && (nb_b_mv_y == 16'sd0);

	wire case_no_a  = !nb_a_present;
	wire case_no_b  = !nb_b_present;
	wire case_a_zero = a_ref_zero && a_mv_zero;
	wire case_b_zero = b_ref_zero && b_mv_zero;

	assign zero_reason = {case_b_zero, case_a_zero, case_no_b, case_no_a};
	assign zero_mv = case_no_a | case_no_b | case_a_zero | case_b_zero;

	assign mv_x = zero_mv ? 16'sd0 : mvp_x;
	assign mv_y = zero_mv ? 16'sd0 : mvp_y;
endmodule

// ---------------------------------------------------------------------------
// Motion neighbour context for the current macroblock row.
//
// Holds one macroblock row of committed L0 motion plus the left and above-left
// registers, and derives the A/B/C/D taps for the macroblock at (mb_x, mb_y).
// Macroblocks are committed in raster order.
//
// Availability is semantic, not storage validity: a macroblock stored in the
// row buffer but sitting before first_mb_in_slice is not available (6.4.11.7).
// Intra macroblocks must still be committed (with commit_is_inter = 0) so their
// refIdx reads back as "not 0" for the P_Skip special cases.
// ---------------------------------------------------------------------------
module h264_pskip_nb_ctx #(
	parameter int MB_WIDTH_MAX = 39,
	parameter int MB_WIDTH_DEFAULT = 39
)(
	input  wire        clk,
	input  wire        reset,

	input  wire [7:0]  mb_x,
	input  wire [7:0]  mb_y,
	input  wire [7:0]  mb_width,
	input  wire [15:0] first_mb_in_slice,

	// Commit of the macroblock that has just been decoded, in raster order.
	input  wire        mb_commit,
	input  wire [7:0]  commit_mb_x,
	input  wire        commit_is_inter,
	input  wire [1:0]  commit_ref_idx,
	input  wire signed [15:0] commit_mv_x,
	input  wire signed [15:0] commit_mv_y,

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

	assign nb_a_present = has_left_col && (left_mb_index >= first_mb_in_slice);
	assign nb_b_present = has_top_row && (top_mb_index >= first_mb_in_slice);
	assign nb_c_present = has_top_row && has_right_col &&
	                      (top_right_mb_index >= first_mb_in_slice);
	assign nb_d_present = has_top_row && has_left_col &&
	                      (top_left_mb_index >= first_mb_in_slice);

	reg               top_inter [0:MB_WIDTH_MAX-1];
	reg        [1:0]  top_ref   [0:MB_WIDTH_MAX-1];
	reg signed [15:0] top_mv_x  [0:MB_WIDTH_MAX-1];
	reg signed [15:0] top_mv_y  [0:MB_WIDTH_MAX-1];

	reg               left_inter;
	reg        [1:0]  left_ref;
	reg signed [15:0] left_mv_x;
	reg signed [15:0] left_mv_y;

	// Above-left tap: the row-buffer entry of column N is overwritten when
	// column N of the current row commits, so the pre-overwrite value is
	// latched at that moment and becomes the D neighbour of column N+1.
	reg               topleft_inter;
	reg        [1:0]  topleft_ref;
	reg signed [15:0] topleft_mv_x;
	reg signed [15:0] topleft_mv_y;

	localparam int COL_W = (MB_WIDTH_MAX <= 1) ? 1 : $clog2(MB_WIDTH_MAX);
	wire [COL_W-1:0] b_col = mb_x[COL_W-1:0];
	// Clamped so the row-buffer read stays in range on the last column, where
	// the above-right neighbour does not exist anyway.
	wire [COL_W-1:0] c_col = has_right_col ? (mb_x[COL_W-1:0] + COL_W'(1))
	                                       : mb_x[COL_W-1:0];
	wire [COL_W-1:0] commit_col = commit_mb_x[COL_W-1:0];

	assign nb_a_inter = left_inter;
	assign nb_a_ref   = left_ref;
	assign nb_a_mv_x  = left_mv_x;
	assign nb_a_mv_y  = left_mv_y;

	assign nb_b_inter = top_inter[b_col];
	assign nb_b_ref   = top_ref[b_col];
	assign nb_b_mv_x  = top_mv_x[b_col];
	assign nb_b_mv_y  = top_mv_y[b_col];

	assign nb_c_inter = top_inter[c_col];
	assign nb_c_ref   = top_ref[c_col];
	assign nb_c_mv_x  = top_mv_x[c_col];
	assign nb_c_mv_y  = top_mv_y[c_col];

	assign nb_d_inter = topleft_inter;
	assign nb_d_ref   = topleft_ref;
	assign nb_d_mv_x  = topleft_mv_x;
	assign nb_d_mv_y  = topleft_mv_y;

	integer ci;
	always @(posedge clk) begin
		if (reset) begin
			for (ci = 0; ci < MB_WIDTH_MAX; ci = ci + 1) begin
				top_inter[ci] <= 1'b0;
				top_ref[ci] <= 2'd0;
				top_mv_x[ci] <= 16'sd0;
				top_mv_y[ci] <= 16'sd0;
			end
			left_inter <= 1'b0;
			left_ref <= 2'd0;
			left_mv_x <= 16'sd0;
			left_mv_y <= 16'sd0;
			topleft_inter <= 1'b0;
			topleft_ref <= 2'd0;
			topleft_mv_x <= 16'sd0;
			topleft_mv_y <= 16'sd0;
		end else if (mb_commit) begin
			topleft_inter <= top_inter[commit_col];
			topleft_ref <= top_ref[commit_col];
			topleft_mv_x <= top_mv_x[commit_col];
			topleft_mv_y <= top_mv_y[commit_col];

			top_inter[commit_col] <= commit_is_inter;
			top_ref[commit_col] <= commit_is_inter ? commit_ref_idx : 2'd0;
			top_mv_x[commit_col] <= commit_is_inter ? commit_mv_x : 16'sd0;
			top_mv_y[commit_col] <= commit_is_inter ? commit_mv_y : 16'sd0;

			left_inter <= commit_is_inter;
			left_ref <= commit_is_inter ? commit_ref_idx : 2'd0;
			left_mv_x <= commit_is_inter ? commit_mv_x : 16'sd0;
			left_mv_y <= commit_is_inter ? commit_mv_y : 16'sd0;
		end
	end
endmodule

// ---------------------------------------------------------------------------
// CAVLC mb_skip_run tracking.
//
// h264_syntax_primitives already parses the mb_skip_run ue(v) itself; what is
// missing is the run state that spans macroblocks. In a CAVLC P slice each
// coded macroblock is preceded by mb_skip_run, so the sequence is
//   mb_skip_run = N -> N P_Skip macroblocks -> one coded macroblock -> ...
// and a slice may also end right after a run with no trailing coded MB.
//
// Drive skip_run_valid for one cycle with the parsed mb_skip_run, then pulse
// mb_consume once per macroblock issued. need_skip_run tells the slice walker
// that the next macroblock must be preceded by a fresh mb_skip_run parse.
// skip_run_valid and mb_consume may be asserted in the same cycle; the load is
// applied first.
// ---------------------------------------------------------------------------
module h264_mb_skip_run_track (
	input  wire        clk,
	input  wire        reset,
	input  wire        slice_start,

	input  wire        skip_run_valid,
	input  wire [15:0] skip_run,
	input  wire        mb_consume,

	output wire        mb_is_skip,
	output wire        need_skip_run,
	output reg  [15:0] skip_run_left,
	output reg         coded_pending
);
	reg [15:0] next_left;
	reg        next_coded;

	assign mb_is_skip = (skip_run_left != 16'd0);
	assign need_skip_run = (skip_run_left == 16'd0) && !coded_pending;

	always @(posedge clk) begin
		if (reset || slice_start) begin
			skip_run_left <= 16'd0;
			coded_pending <= 1'b0;
		end else begin
			next_left = skip_run_valid ? skip_run : skip_run_left;
			next_coded = skip_run_valid ? 1'b1 : coded_pending;
			if (mb_consume) begin
				if (next_left != 16'd0)
					next_left = next_left - 16'd1;
				else
					next_coded = 1'b0;
			end
			skip_run_left <= next_left;
			coded_pending <= next_coded;
		end
	end
endmodule

// ---------------------------------------------------------------------------
// Reference fetch request generator for a skipped macroblock.
//
// P_Skip has no residual and no transform: the reconstructed macroblock is the
// motion compensated prediction, so this walks the 16x16 luma block and the two
// 8x8 chroma blocks and requests one reference sample per output sample.
//
// The DDR reference picture read path is owned elsewhere. This module only
// drives a request/response port; ref_req_* / ref_rsp_* must be wired to that
// reader. Responses are expected in request order. The reader must return
// POST-deblocking reference samples.
//
// LIMITATION - integer motion vectors only. The luma MV is truncated with an
// arithmetic >> 2 and the chroma MV with >> 3, i.e. the quarter-pel luma phase
// and eighth-pel chroma phase are dropped, so fractional-MV macroblocks copy
// from the nearest integer position instead of interpolating. The six-tap luma
// and bilinear chroma filters already exist as h264_luma_qpel_sample and
// h264_chroma_epel_sample in h264_inter_pred.sv; wiring them in requires the
// fetch port to deliver a 9x9 luma tap window (see h264_luma_ref_tap_addr) and
// a 2x2 chroma window per output sample instead of a single sample.
// ---------------------------------------------------------------------------
module h264_pskip_mc_copy (
	input  wire        clk,
	input  wire        reset,

	input  wire        start,          // pulse: begin the copy for this MB
	input  wire [7:0]  mb_x,
	input  wire [7:0]  mb_y,
	input  wire signed [15:0] mv_x_qpel,
	input  wire signed [15:0] mv_y_qpel,
	input  wire [15:0] frame_w,        // luma width in samples
	input  wire [15:0] frame_h,        // luma height in samples

	// Reference picture read port (POST-deblock samples, owned externally).
	output wire        ref_req_valid,
	output wire [1:0]  ref_req_plane,  // 0 = Y, 1 = Cb, 2 = Cr
	output wire [15:0] ref_req_x,
	output wire [15:0] ref_req_y,
	input  wire        ref_req_ready,
	input  wire        ref_rsp_valid,
	input  wire [7:0]  ref_rsp_sample,

	// Predicted macroblock samples, raster order within each plane.
	output reg         pred_valid,
	output reg  [1:0]  pred_plane,
	output reg  [7:0]  pred_idx,
	output reg  [7:0]  pred_sample,

	output wire        busy,
	output reg         done
);
	localparam [9:0] LUMA_SAMPLES = 10'd256;
	localparam [9:0] CB_END = 10'd320;
	localparam [9:0] TOTAL_SAMPLES = 10'd384;
	localparam [3:0] MAX_OUTSTANDING = 4'd8;

	reg  [9:0] issue_idx;
	reg  [9:0] rsp_idx;
	reg        active;

	wire [9:0] outstanding = issue_idx - rsp_idx;

	assign busy = active;

	function automatic [1:0] plane_of(input [9:0] idx);
		plane_of = (idx < LUMA_SAMPLES) ? 2'd0 : ((idx < CB_END) ? 2'd1 : 2'd2);
	endfunction

	function automatic [7:0] sample_of(input [9:0] idx);
		reg [9:0] rel;
		begin
			if (idx < LUMA_SAMPLES) rel = idx;
			else if (idx < CB_END) rel = idx - LUMA_SAMPLES;
			else rel = idx - CB_END;
			sample_of = rel[7:0];
		end
	endfunction

	// Integer reference position for the sample currently being requested.
	wire issue_luma = (issue_idx < LUMA_SAMPLES);
	wire [7:0] issue_rel = sample_of(issue_idx);
	wire [3:0] luma_row = issue_rel[7:4];
	wire [3:0] luma_col = issue_rel[3:0];
	wire [2:0] chroma_row = issue_rel[5:3];
	wire [2:0] chroma_col = issue_rel[2:0];

	// xIntL = xAL + (mvLX[0] >> 2); for 4:2:0 frame chroma mvCLX = mvLX and
	// xIntC = xAC + (mvCLX[0] >> 3).
	wire signed [15:0] mv_int_luma_x = mv_x_qpel >>> 2;
	wire signed [15:0] mv_int_luma_y = mv_y_qpel >>> 2;
	wire signed [15:0] mv_int_chroma_x = mv_x_qpel >>> 3;
	wire signed [15:0] mv_int_chroma_y = mv_y_qpel >>> 3;

	// mb_x * 16 and mb_x * 8 as shifts to keep the widths explicit.
	wire signed [15:0] luma_org_x = $signed({4'd0, mb_x, 4'd0});
	wire signed [15:0] luma_org_y = $signed({4'd0, mb_y, 4'd0});
	wire signed [15:0] chroma_org_x = $signed({5'd0, mb_x, 3'd0});
	wire signed [15:0] chroma_org_y = $signed({5'd0, mb_y, 3'd0});

	wire signed [15:0] luma_base_x = luma_org_x + $signed({12'd0, luma_col}) + mv_int_luma_x;
	wire signed [15:0] luma_base_y = luma_org_y + $signed({12'd0, luma_row}) + mv_int_luma_y;
	wire signed [15:0] chroma_base_x = chroma_org_x + $signed({13'd0, chroma_col}) + mv_int_chroma_x;
	wire signed [15:0] chroma_base_y = chroma_org_y + $signed({13'd0, chroma_row}) + mv_int_chroma_y;

	wire signed [15:0] req_raw_x = issue_luma ? luma_base_x : chroma_base_x;
	wire signed [15:0] req_raw_y = issue_luma ? luma_base_y : chroma_base_y;
	wire [15:0] req_limit_w = issue_luma ? frame_w : {1'b0, frame_w[15:1]};
	wire [15:0] req_limit_h = issue_luma ? frame_h : {1'b0, frame_h[15:1]};

	h264_ref_clamp u_clamp (
		.x(req_raw_x),
		.y(req_raw_y),
		.width(req_limit_w),
		.height(req_limit_h),
		.clamped_x(ref_req_x),
		.clamped_y(ref_req_y)
	);

	assign ref_req_plane = plane_of(issue_idx);
	assign ref_req_valid = active && (issue_idx < TOTAL_SAMPLES) &&
	                       (outstanding < {6'd0, MAX_OUTSTANDING});

	always @(posedge clk) begin
		done <= 1'b0;
		pred_valid <= 1'b0;
		if (reset) begin
			issue_idx <= 10'd0;
			rsp_idx <= 10'd0;
			active <= 1'b0;
		end else if (start) begin
			issue_idx <= 10'd0;
			rsp_idx <= 10'd0;
			active <= 1'b1;
		end else if (active) begin
			if (ref_req_valid && ref_req_ready)
				issue_idx <= issue_idx + 10'd1;
			if (ref_rsp_valid) begin
				pred_valid <= 1'b1;
				pred_plane <= plane_of(rsp_idx);
				pred_idx <= sample_of(rsp_idx);
				pred_sample <= ref_rsp_sample;
				rsp_idx <= rsp_idx + 10'd1;
				if (rsp_idx == (TOTAL_SAMPLES - 10'd1)) begin
					active <= 1'b0;
					done <= 1'b1;
				end
			end
		end
	end
endmodule

`default_nettype wire
