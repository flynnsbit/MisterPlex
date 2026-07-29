// H.264 Baseline P_Skip macroblock support.
//
// Contents:
//   h264_pskip_mv_pred - luma MV prediction, spec 8.4.1.3 (median +
//                        directional/substitution rules). Shared by P_Skip
//                        and multi-partition MVP (h264_mv_pred_partition).
//
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

`default_nettype wire
