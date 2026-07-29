// Sequential I/P-slice macroblock feeder.
//
// Owns the RBSP window while a VCL slice is being reconstructed and walks
// real per-macroblock syntax + CAVLC residual.  Replaces the stream_path
// "latch first-MB coeffs and replay them on every MB" driver: each macroblock
// now gets its own residual from the bitstream.
//
// Scope (honest):
//   * I_NxN residual → 16 luma 4x4 CAVLC blocks (CBP-gated) fed to the core
//   * I chroma residual: DC Hadamard + AC IDCT-add samples exported to core
//     (feed owns RBSP; core cannot re-parse chroma during ST_WAIT_CORE)
//   * P chroma residual bit-synced here; core re-parses with QPc/Hadamard
//   * I_16x16 residual is consumed for bit-sync; DC Hadamard still open
//   * P-slice full PicSizeInMbs walk with mb_skip_run (ue) runs of P_Skip
//   * P coded MBs: mb_type + pred (ref/mvd/sub) + inter/intra-in-P CBP + qpδ
//     + residual bit-sync; core re-parses residual from mb_residual_bit_offset
//   * more_rbsp_data() end-of-slice; sticky desync_early / desync_long
//
// Area: one shared h264_cavlc_residual_block, sequential bit reader, no second
// RBSP store (reads the existing h264_rbsp_window).  Single residual source.

`default_nettype none

module h264_i_mb_feed #(
	parameter int MB_W_MAX = 40
)(
	input  wire        clk,
	input  wire        reset,

	// Pulse when the slice header + first-MB syntax are ready and the whole
	// VCL RBSP is captured into the window.
	input  wire        slice_go,
	input  wire        slice_is_i,
	input  wire [7:0]  mb_width,
	input  wire [7:0]  mb_height,
	input  wire [15:0] first_mb_in_slice,
	input  wire [5:0]  slice_qp_y,
	input  wire signed [4:0] pps_chroma_qp_index_offset,

	// First-MB syntax already parsed by slice_hdr_parser (denominator: MB0).
	input  wire [7:0]  first_mb_type,
	input  wire        first_mb_p_skip,
	input  wire [15:0] first_p_skip_run,
	input  wire        first_mb_intra,
	input  wire [2:0]  first_mb_part_mode,
	input  wire [7:0]  first_sub_mb_types,
	input  wire [7:0]  first_mb_ref_idx_l0,
	input  wire [15:0] first_mb_mvd_valid,
	input  wire signed [15:0] first_mb_mvd_x [0:15],
	input  wire signed [15:0] first_mb_mvd_y [0:15],
	input  wire [7:0]  num_ref_idx_l0_active, // 1-based active count
	input  wire [15:0] first_i4_pred_mode_flags,
	input  wire [47:0] first_i4_rem_modes,
	input  wire        first_i4_modes_present,
	input  wire [1:0]  first_chroma_pred_mode,
	input  wire [3:0]  first_cbp_luma,
	input  wire [1:0]  first_cbp_chroma,
	// Bit offset after first skip_run (P_Skip) or at first residual (coded MB).
	input  wire [15:0] first_residual_bit_offset,

	// RBSP window (combinational read; request moves the base).
	input  wire [7:0]  rbsp_byte [0:63],
	input  wire [15:0] rbsp_window_base,
	output reg  [15:0] rbsp_request_offset,
	output reg         rbsp_request_valid,
	input  wire [15:0] rbsp_length,
	input  wire        rbsp_complete,

	// Core handshake
	input  wire        core_busy,
	input  wire [4:0]  core_intra_blocks_done,

	// Per-MB syntax → decode_core
	output reg         mb_type_valid,
	output reg  [4:0]  mb_type,
	output reg         mb_skip,
	output reg         mb_intra,
	output reg  [2:0]  part_mode,
	output reg  [7:0]  sub_mb_types,
	output reg  [7:0]  ref_idx_l0_packed,
	output reg  [15:0] mvd_valid,
	output reg signed [15:0] mvd_x [0:15],
	output reg signed [15:0] mvd_y [0:15],
	output reg  [15:0] i4_pred_mode_flags,
	output reg  [47:0] i4_rem_modes,
	output reg         i4_modes_present,
	output reg  [1:0]  intra16x16_mode,
	output reg  [1:0]  chroma_pred_mode,
	output reg  [3:0]  cbp_luma,
	output reg  [1:0]  cbp_chroma,
	output reg  signed [5:0] mb_qp_delta,
	output reg  [5:0]  mb_qp_y,
	output reg  [15:0] mb_residual_bit_offset,

	// Per-block residual coeffs → decode_core luma4x4_* ports (I / intra-in-P)
	output reg         luma4x4_valid,
	output reg  [3:0]  luma4x4_idx,
	output reg  [5:0]  luma4x4_qp,
	output reg  [4:0]  luma4x4_total_coeff,
	output reg  [1:0]  luma4x4_trailing_ones,
	output reg signed [15:0] luma4x4_coeff_zigzag [0:15],

	// I/intra chroma residual samples (IDCT domain, pre-clip add). Valid after
	// residual walk completes for feed_luma MBs; zeros when chroma uncoded.
	output reg signed [15:0] chroma_residual_u [0:63],
	output reg signed [15:0] chroma_residual_v [0:63],
	output reg         chroma_residual_valid,

	// busy is low during ST_YIELD_CORE so the core can own the RBSP window
	// while it re-parses residual for inter MBs.
	output wire        busy,
	output reg         frame_feed_done,
	output reg         error,
	output reg         slice_desync,
	// Sticky PARSE desync: early = more_rbsp false before PicSizeInMbs;
	// long = data remains after PicSizeInMbs or walker past expected end.
	output reg         slice_desync_early,
	output reg         slice_desync_long
);

	localparam [5:0]
		ST_IDLE         = 6'd0,
		ST_MB0_LOAD     = 6'd1,
		ST_MB_PULSE     = 6'd2,
		ST_MB_GAP       = 6'd3,
		ST_RES_REQ      = 6'd4,
		ST_RES_ARM      = 6'd5,
		ST_RES_START    = 6'd6,
		ST_RES_WAIT     = 6'd7,
		ST_RES_FEED     = 6'd8,
		ST_RES_ACK      = 6'd9,
		ST_WAIT_CORE    = 6'd10,
		ST_YIELD_CORE   = 6'd11,
		ST_SYN_REQ      = 6'd12,
		ST_SYN_ARM      = 6'd13,
		ST_SYN_UE0      = 6'd14,
		ST_SYN_UE1      = 6'd15,
		ST_SYN_BIT      = 6'd16,
		ST_SYN_DISPATCH = 6'd17,
		ST_DONE         = 6'd18,
		ST_FAIL         = 6'd19,
		ST_P_SKIP_EMIT  = 6'd20,
		ST_P_AFTER_MB   = 6'd21,
		ST_P_SKIP_RUN   = 6'd22,
		ST_EOS_CHECK    = 6'd23;

	// Residual step index: 0..15 luma, 16/17 chroma DC, 18..25 chroma AC
	localparam [4:0] STEP_LUMA_END  = 5'd16;
	localparam [4:0] STEP_CHR_DC_U  = 5'd16;
	localparam [4:0] STEP_CHR_DC_V  = 5'd17;
	localparam [4:0] STEP_CHR_AC0   = 5'd18;
	localparam [4:0] STEP_END       = 5'd26;

	// ret_st codes for syntax dispatch
	// 0  mb_type (I or P)
	// 1  I4 flag
	// 2  I4 rem
	// 3  chroma pred
	// 4  cbp (intra or inter map selected by flag)
	// 5  mb_qp_delta
	// 6  P skip_run
	// 7  P sub_mb_type
	// 8  P ref_idx te/ue
	// 9  P mvd x
	// 10 P mvd y

	reg [5:0]  st;
	reg [15:0] mb_addr;
	reg [15:0] mb_total;
	reg [15:0] abs_bit;
	reg [15:0] res_start_bit;
	reg [4:0]  res_step;
	reg [5:0]  qp_r;
	reg [3:0]  cbp_l_r;
	reg [1:0]  cbp_c_r;
	reg [7:0]  mb_type_r;
	reg        is_i16_r;
	reg        slice_is_i_r;
	reg        mb_intra_r;
	reg        mb_skip_r;
	reg        feed_luma_r;     // 1 = pulse luma4x4 to core (I / intra-in-P)
	reg        inter_res_only_r; // 1 = bit-sync residual then yield to core
	reg [5:0]  blk_guard;
	reg [15:0] guard;
	reg        win_armed;
	reg [15:0] skip_left;
	reg [2:0]  part_mode_r;
	reg [7:0]  sub_mb_types_r;
	reg [7:0]  ref_pack_r;
	reg [15:0] mvd_valid_r;
	reg signed [15:0] mvd_x_r [0:15];
	reg signed [15:0] mvd_y_r [0:15];
	reg [2:0]  pred_blk;
	reg [2:0]  pred_sub;
	reg [2:0]  pred_ref_i;
	reg [3:0]  pred_mvd_slot;
	reg signed [15:0] mvd_x_tmp;
	reg [7:0]  num_ref_r;
	reg        use_inter_cbp;

	// nC neighbour total_coeff
	reg [4:0]  tc_cur [0:15];
	reg [4:0]  tc_left [0:3];
	reg        tc_left_valid;
	reg [4:0]  tc_top [0:(MB_W_MAX*4)-1];
	reg        tc_top_valid [0:MB_W_MAX-1];
	// Chroma AC nC (internal 2x2 only) + DC after Hadamard
	reg [4:0]  chr_tc_u [0:3];
	reg [4:0]  chr_tc_v [0:3];
	reg signed [28:0] chr_dc_u [0:3];
	reg signed [28:0] chr_dc_v [0:3];

	// Bit reader
	reg [7:0]  ue_zeros;
	reg [7:0]  ue_suf_left;
	reg [31:0] ue_suf;
	reg [31:0] ue_val;
	reg [7:0]  bit_left;
	reg [31:0] bit_acc;
	reg [7:0]  ret_st;
	reg [4:0]  i4_i;
	reg [15:0] flags_r;
	reg [47:0] rems_r;

	// CAVLC
	reg        cav_start;
	reg [2:0]  cav_table;
	reg [4:0]  cav_max;
	reg [9:0]  cav_bit_off;
	wire       cav_busy, cav_done, cav_ok;
	wire [9:0] cav_bit_end;
	wire [4:0] cav_tc;
	wire [1:0] cav_t1;
	wire [3:0] cav_tz;
	wire signed [15:0] cav_coeff [0:15];
	wire signed [15:0] cav_level_dbg [0:15];
	wire [3:0] cav_run_dbg [0:15];

	integer ci;

	// Yield releases the RBSP window to the core for inter residual/MC.
	assign busy = (st != ST_IDLE) && (st != ST_DONE) && (st != ST_FAIL) &&
	              (st != ST_YIELD_CORE);

	// ── Geometry helpers ────────────────────────────────────────────────
	function automatic [1:0] blk_x;
		input [3:0] idx;
		case (idx)
		4'd0,4'd2,4'd8,4'd10: blk_x = 2'd0;
		4'd1,4'd3,4'd9,4'd11: blk_x = 2'd1;
		4'd4,4'd6,4'd12,4'd14: blk_x = 2'd2;
		default: blk_x = 2'd3;
		endcase
	endfunction

	function automatic [1:0] blk_y;
		input [3:0] idx;
		case (idx)
		4'd0,4'd1,4'd4,4'd5: blk_y = 2'd0;
		4'd2,4'd3,4'd6,4'd7: blk_y = 2'd1;
		4'd8,4'd9,4'd12,4'd13: blk_y = 2'd2;
		default: blk_y = 2'd3;
		endcase
	endfunction

	function automatic [3:0] blk_at;
		input [1:0] bx, by;
		case ({by, bx})
		4'b0000: blk_at = 4'd0;  4'b0001: blk_at = 4'd1;
		4'b0100: blk_at = 4'd2;  4'b0101: blk_at = 4'd3;
		4'b0010: blk_at = 4'd4;  4'b0011: blk_at = 4'd5;
		4'b0110: blk_at = 4'd6;  4'b0111: blk_at = 4'd7;
		4'b1000: blk_at = 4'd8;  4'b1001: blk_at = 4'd9;
		4'b1100: blk_at = 4'd10; 4'b1101: blk_at = 4'd11;
		4'b1010: blk_at = 4'd12; 4'b1011: blk_at = 4'd13;
		4'b1110: blk_at = 4'd14; default: blk_at = 4'd15;
		endcase
	endfunction

	function automatic [5:0] cbp_intra_map;
		input [5:0] code;
		case (code)
		6'd0: cbp_intra_map=6'd47; 6'd1: cbp_intra_map=6'd31; 6'd2: cbp_intra_map=6'd15; 6'd3: cbp_intra_map=6'd0;
		6'd4: cbp_intra_map=6'd23; 6'd5: cbp_intra_map=6'd27; 6'd6: cbp_intra_map=6'd29; 6'd7: cbp_intra_map=6'd30;
		6'd8: cbp_intra_map=6'd7;  6'd9: cbp_intra_map=6'd11; 6'd10:cbp_intra_map=6'd13; 6'd11:cbp_intra_map=6'd14;
		6'd12:cbp_intra_map=6'd39; 6'd13:cbp_intra_map=6'd43; 6'd14:cbp_intra_map=6'd45; 6'd15:cbp_intra_map=6'd46;
		6'd16:cbp_intra_map=6'd16; 6'd17:cbp_intra_map=6'd3;  6'd18:cbp_intra_map=6'd5;  6'd19:cbp_intra_map=6'd10;
		6'd20:cbp_intra_map=6'd12; 6'd21:cbp_intra_map=6'd19; 6'd22:cbp_intra_map=6'd21; 6'd23:cbp_intra_map=6'd26;
		6'd24:cbp_intra_map=6'd28; 6'd25:cbp_intra_map=6'd35; 6'd26:cbp_intra_map=6'd37; 6'd27:cbp_intra_map=6'd42;
		6'd28:cbp_intra_map=6'd44; 6'd29:cbp_intra_map=6'd1;  6'd30:cbp_intra_map=6'd2;  6'd31:cbp_intra_map=6'd4;
		6'd32:cbp_intra_map=6'd8;  6'd33:cbp_intra_map=6'd17; 6'd34:cbp_intra_map=6'd18; 6'd35:cbp_intra_map=6'd20;
		6'd36:cbp_intra_map=6'd24; 6'd37:cbp_intra_map=6'd6;  6'd38:cbp_intra_map=6'd9;  6'd39:cbp_intra_map=6'd22;
		6'd40:cbp_intra_map=6'd25; 6'd41:cbp_intra_map=6'd32; 6'd42:cbp_intra_map=6'd33; 6'd43:cbp_intra_map=6'd34;
		6'd44:cbp_intra_map=6'd36; 6'd45:cbp_intra_map=6'd40; 6'd46:cbp_intra_map=6'd38; 6'd47:cbp_intra_map=6'd41;
		default: cbp_intra_map = 6'd0;
		endcase
	endfunction

	function automatic [5:0] cbp_inter_map;
		input [5:0] code;
		case (code)
		6'd0: cbp_inter_map=6'd0;  6'd1: cbp_inter_map=6'd16; 6'd2: cbp_inter_map=6'd1;  6'd3: cbp_inter_map=6'd2;
		6'd4: cbp_inter_map=6'd4;  6'd5: cbp_inter_map=6'd8;  6'd6: cbp_inter_map=6'd32; 6'd7: cbp_inter_map=6'd3;
		6'd8: cbp_inter_map=6'd5;  6'd9: cbp_inter_map=6'd10; 6'd10:cbp_inter_map=6'd12; 6'd11:cbp_inter_map=6'd15;
		6'd12:cbp_inter_map=6'd47; 6'd13:cbp_inter_map=6'd7;  6'd14:cbp_inter_map=6'd11; 6'd15:cbp_inter_map=6'd13;
		6'd16:cbp_inter_map=6'd14; 6'd17:cbp_inter_map=6'd6;  6'd18:cbp_inter_map=6'd9;  6'd19:cbp_inter_map=6'd31;
		6'd20:cbp_inter_map=6'd35; 6'd21:cbp_inter_map=6'd37; 6'd22:cbp_inter_map=6'd42; 6'd23:cbp_inter_map=6'd44;
		6'd24:cbp_inter_map=6'd33; 6'd25:cbp_inter_map=6'd34; 6'd26:cbp_inter_map=6'd36; 6'd27:cbp_inter_map=6'd40;
		6'd28:cbp_inter_map=6'd39; 6'd29:cbp_inter_map=6'd43; 6'd30:cbp_inter_map=6'd45; 6'd31:cbp_inter_map=6'd46;
		6'd32:cbp_inter_map=6'd17; 6'd33:cbp_inter_map=6'd18; 6'd34:cbp_inter_map=6'd20; 6'd35:cbp_inter_map=6'd24;
		6'd36:cbp_inter_map=6'd19; 6'd37:cbp_inter_map=6'd21; 6'd38:cbp_inter_map=6'd26; 6'd39:cbp_inter_map=6'd28;
		6'd40:cbp_inter_map=6'd23; 6'd41:cbp_inter_map=6'd27; 6'd42:cbp_inter_map=6'd29; 6'd43:cbp_inter_map=6'd30;
		6'd44:cbp_inter_map=6'd22; 6'd45:cbp_inter_map=6'd25; 6'd46:cbp_inter_map=6'd38; 6'd47:cbp_inter_map=6'd41;
		default: cbp_inter_map = 6'd0;
		endcase
	endfunction

	function automatic [5:0] i16_cbp_from_type;
		input [7:0] mt;
		reg [7:0] t;
		begin
			t = mt;
			if (t >= 8'd1 && t <= 8'd24) begin
				i16_cbp_from_type[5:4] = ((t - 8'd1) / 8'd4) % 8'd3;
				i16_cbp_from_type[3:0] = ((t - 8'd1) >= 8'd12) ? 4'hF : 4'h0;
			end else
				i16_cbp_from_type = 6'd0;
		end
	endfunction

	function automatic signed [5:0] se6_from_ue;
		input [31:0] code;
		reg signed [31:0] tmp;
		begin
			if (code[0])
				tmp = $signed({1'b0, code[31:1]}) + 32'sd1;
			else
				tmp = -$signed({1'b0, code[31:1]});
			se6_from_ue = tmp[5:0];
		end
	endfunction

	function automatic signed [15:0] se16_from_ue;
		input [31:0] code;
		reg signed [31:0] tmp;
		begin
			if (code[0])
				tmp = $signed({1'b0, code[31:1]}) + 32'sd1;
			else
				tmp = -$signed({1'b0, code[31:1]});
			se16_from_ue = tmp[15:0];
		end
	endfunction

	function automatic [2:0] p_part_mode_of;
		input [7:0] mt;
		begin
			if (mt == 8'd0)      p_part_mode_of = 3'd0;
			else if (mt == 8'd1) p_part_mode_of = 3'd1;
			else if (mt == 8'd2) p_part_mode_of = 3'd2;
			else if (mt == 8'd3 || mt == 8'd4) p_part_mode_of = 3'd3;
			else p_part_mode_of = 3'd0;
		end
	endfunction

	function automatic [2:0] p_part_count_of;
		input [7:0] mt;
		begin
			if (mt == 8'd0) p_part_count_of = 3'd1;
			else if (mt == 8'd1 || mt == 8'd2) p_part_count_of = 3'd2;
			else if (mt == 8'd3 || mt == 8'd4) p_part_count_of = 3'd4;
			else p_part_count_of = 3'd1;
		end
	endfunction

	function automatic [2:0] sub_part_count_of;
		input [1:0] smt;
		case (smt)
		2'd0: sub_part_count_of = 3'd1;
		2'd1: sub_part_count_of = 3'd2;
		2'd2: sub_part_count_of = 3'd2;
		default: sub_part_count_of = 3'd4;
		endcase
	endfunction

	// Absolute bit → window-relative, after a request at abs_bit[15:3]
	wire [15:0] win_bit_base = {rbsp_window_base[12:0], 3'd0};
	wire [15:0] rel_bit16 = abs_bit - win_bit_base;
	wire [9:0]  rel_bit10 = rel_bit16[9:0];
	wire [15:0] rbsp_bits = {rbsp_length[12:0], 3'd0};

	// Live bit from window
	wire [5:0]  rd_byte_idx = rel_bit10[8:3];
	wire        rd_bit = rbsp_byte[rd_byte_idx][3'd7 - rel_bit10[2:0]];

	// nC / table for current luma blkIdx
	wire [3:0] cur_blk = res_step[3:0];
	wire [1:0] cur_bx = blk_x(cur_blk);
	wire [1:0] cur_by = blk_y(cur_blk);
	wire [7:0] mb_x8 = (mb_width == 8'd0) ? 8'd0 : mb_addr % {8'd0, mb_width};
	wire [7:0] mb_y8 = (mb_width == 8'd0) ? 8'd0 : mb_addr / {8'd0, mb_width};
	wire       left_int = (cur_bx != 2'd0);
	wire       up_int   = (cur_by != 2'd0);
	wire [4:0] left_tc_w = left_int ? tc_cur[blk_at(cur_bx - 2'd1, cur_by)]
	                                : tc_left[cur_by];
	wire       left_tc_v = left_int ? 1'b1 : tc_left_valid;
	wire [4:0] up_tc_w = up_int ? tc_cur[blk_at(cur_bx, cur_by - 2'd1)]
	                            : tc_top[{mb_x8[5:0], cur_bx}];
	wire       up_tc_v = up_int ? 1'b1 : tc_top_valid[mb_x8];
	wire [4:0] nC_w =
		(left_tc_v && up_tc_v) ? ((left_tc_w + up_tc_w + 5'd1) >> 1) :
		left_tc_v ? left_tc_w : up_tc_v ? up_tc_w : 5'd0;
	wire [2:0] tok_table_luma =
		(nC_w < 5'd2) ? 3'd0 : (nC_w < 5'd4) ? 3'd1 : (nC_w < 5'd8) ? 3'd2 : 3'd3;

	function automatic res_step_coded;
		input [4:0] step;
		input [3:0] cbp_l;
		input [1:0] cbp_c;
		input       is_i16;
		reg [3:0] bi;
		begin
			if (step < STEP_LUMA_END) begin
				bi = step[3:0];
				if (is_i16)
					res_step_coded = 1'b1;
				else
					res_step_coded = cbp_l[bi[3:2]];
			end else if (step == STEP_CHR_DC_U || step == STEP_CHR_DC_V)
				res_step_coded = (cbp_c != 2'd0);
			else
				res_step_coded = (cbp_c == 2'd2);
		end
	endfunction

	// more_rbsp_data() (7.4.1): false when only rbsp_trailing_bits remain
	// (a single '1' stop bit plus zero alignment bits) or no bits remain.
	function automatic more_rbsp_data_at;
		input [15:0] bitpos;
		input [15:0] nbits;
		reg [15:0] left;
		reg [15:0] i;
		reg        saw_one;
		reg        bad;
		begin
			if (bitpos >= nbits) begin
				more_rbsp_data_at = 1'b0;
			end else begin
				left = nbits - bitpos;
				if (left > 16'd8) begin
					more_rbsp_data_at = 1'b1;
				end else begin
					// Peek remaining bits via window (must be armed near bitpos).
					// Conservative: treat as trailing if first remaining 1 is
					// followed only by zeros through the end.
					saw_one = 1'b0;
					bad = 1'b0;
					for (i = 16'd0; i < 16'd8; i = i + 16'd1) begin
						if (i < left) begin
							// Use rbsp_byte relative to current window; caller
							// must have window covering bitpos.
							// Fall through: if we cannot prove trailing, say more.
							bad = 1'b1; // filled below with real peek in comb wire
						end
					end
					// Implemented as comb wire more_rbsp_w below; this function
					// is kept for documentation — actual use is more_rbsp_w.
					more_rbsp_data_at = (left > 16'd0);
				end
			end
		end
	endfunction

	// Combinational more_rbsp_data using live window around abs_bit.
	// Trailing = rbsp_stop_one_bit ('1') + zero alignment (7.4.1).
	wire [15:0] more_left = (abs_bit >= rbsp_bits) ? 16'd0 : (rbsp_bits - abs_bit);
	wire [15:0] more_rbase = {rbsp_window_base[12:0], 3'd0};
	wire more_rbsp_w;
	wire more_bit [0:7];
	genvar more_gi;
	generate
		for (more_gi = 0; more_gi < 8; more_gi = more_gi + 1) begin : g_more_bits
			wire [15:0] bpos = abs_bit + more_gi[15:0];
			wire [9:0]  rb   = bpos - more_rbase;
			assign more_bit[more_gi] =
				(more_gi[15:0] < more_left) ?
					rbsp_byte[rb[8:3]][3'd7 - rb[2:0]] : 1'b0;
		end
	endgenerate
	// Collapse: any '1' that is not solely the first stop with trailing zeros.
	wire more_any = more_bit[0]|more_bit[1]|more_bit[2]|more_bit[3]|
	                more_bit[4]|more_bit[5]|more_bit[6]|more_bit[7];
	// Find index of first 1; if any 1 after that → more data.
	wire [3:0] more_first_one =
		more_bit[0] ? 4'd0 : more_bit[1] ? 4'd1 : more_bit[2] ? 4'd2 :
		more_bit[3] ? 4'd3 : more_bit[4] ? 4'd4 : more_bit[5] ? 4'd5 :
		more_bit[6] ? 4'd6 : more_bit[7] ? 4'd7 : 4'd15;
	wire more_after_stop =
		(more_first_one < 4'd7) && (
			((more_first_one < 4'd1) && (more_bit[1]|more_bit[2]|more_bit[3]|more_bit[4]|more_bit[5]|more_bit[6]|more_bit[7])) ||
			((more_first_one < 4'd2) && (more_bit[2]|more_bit[3]|more_bit[4]|more_bit[5]|more_bit[6]|more_bit[7])) ||
			((more_first_one < 4'd3) && (more_bit[3]|more_bit[4]|more_bit[5]|more_bit[6]|more_bit[7])) ||
			((more_first_one < 4'd4) && (more_bit[4]|more_bit[5]|more_bit[6]|more_bit[7])) ||
			((more_first_one < 4'd5) && (more_bit[5]|more_bit[6]|more_bit[7])) ||
			((more_first_one < 4'd6) && (more_bit[6]|more_bit[7])) ||
			((more_first_one < 4'd7) && more_bit[7])
		);
	assign more_rbsp_w = (more_left == 16'd0) ? 1'b0 :
	                     (more_left > 16'd8)  ? 1'b1 :
	                     (!more_any)          ? 1'b0 :
	                                            more_after_stop;

	h264_cavlc_residual_block #(.MAX_BYTES(64)) u_cavlc (
		.clk(clk),
		.reset(reset),
		.start(cav_start),
		.coeff_token_table(cav_table),
		.max_coeff(cav_max),
		.bit_offset_start(cav_bit_off),
		.bit_len(10'd512),
		.rbsp(rbsp_byte),
		.busy(cav_busy),
		.done(cav_done),
		.ok(cav_ok),
		.bit_offset_end(cav_bit_end),
		.total_coeff(cav_tc),
		.trailing_ones(cav_t1),
		.total_zeros(cav_tz),
		.coeff(cav_coeff),
		.level_dbg(cav_level_dbg),
		.run_dbg(cav_run_dbg)
	);

	// Chroma residual reconstruct (I/intra feed path only; P core re-parses).
	wire [5:0] feed_qp_c;
	h264_chroma_qp u_feed_chroma_qp (
		.qp_y(qp_r),
		.chroma_qp_index_offset(pps_chroma_qp_index_offset),
		.qp_c(feed_qp_c)
	);
	wire signed [28:0] feed_chr_dc_had [0:3];
	// Chroma DC CAVLC emits 4 coeffs; slice the shared 16-wide residual bus.
	wire signed [15:0] cav_coeff_chr_dc [0:3];
	assign cav_coeff_chr_dc[0] = cav_coeff[0];
	assign cav_coeff_chr_dc[1] = cav_coeff[1];
	assign cav_coeff_chr_dc[2] = cav_coeff[2];
	assign cav_coeff_chr_dc[3] = cav_coeff[3];
	h264_chroma_dc_hadamard_inv u_feed_chr_dc_had (
		.coeff(cav_coeff_chr_dc),
		.qp_c(feed_qp_c),
		.dc(feed_chr_dc_had)
	);
	wire [2:0] feed_chr_ac_i = res_step - STEP_CHR_AC0;
	wire       feed_chr_ac_is_v = feed_chr_ac_i[2];
	wire [1:0] feed_chr_ac_blk = feed_chr_ac_i[1:0];
	wire       feed_chr_left_int = feed_chr_ac_blk[0];
	wire       feed_chr_up_int   = feed_chr_ac_blk[1];
	wire [1:0] feed_chr_left_i = feed_chr_ac_blk - 2'd1;
	wire [1:0] feed_chr_up_i   = feed_chr_ac_blk - 2'd2;
	wire [4:0] feed_chr_left_tc = feed_chr_left_int ?
		(feed_chr_ac_is_v ? chr_tc_v[feed_chr_left_i] : chr_tc_u[feed_chr_left_i]) : 5'd0;
	wire [4:0] feed_chr_up_tc = feed_chr_up_int ?
		(feed_chr_ac_is_v ? chr_tc_v[feed_chr_up_i] : chr_tc_u[feed_chr_up_i]) : 5'd0;
	wire [4:0] feed_chr_nC = (feed_chr_left_int && feed_chr_up_int) ?
		((feed_chr_left_tc + feed_chr_up_tc + 5'd1) >> 1) :
		feed_chr_left_int ? feed_chr_left_tc :
		feed_chr_up_int ? feed_chr_up_tc : 5'd0;
	wire [2:0] feed_chr_ac_table = (feed_chr_nC < 5'd2) ? 3'd0 :
	                               (feed_chr_nC < 5'd4) ? 3'd1 :
	                               (feed_chr_nC < 5'd8) ? 3'd2 : 3'd3;
	wire signed [28:0] feed_chr_dc_inj =
		feed_chr_ac_is_v ? chr_dc_v[feed_chr_ac_blk] : chr_dc_u[feed_chr_ac_blk];
	wire signed [28:0] feed_dequant_raw [0:15];
	wire signed [28:0] feed_dequant [0:15];
	wire signed [28:0] feed_idct [0:15];
	wire signed [28:0] feed_dc_only_dq [0:15];
	wire signed [28:0] feed_dc_only_idct [0:15];
	h264_dequant4x4 u_feed_dequant (
		.coeff(cav_coeff),
		.qp(feed_qp_c),
		.max_coeff(5'd15),
		.dequant(feed_dequant_raw)
	);
	genvar fdi;
	generate
		for (fdi = 0; fdi < 16; fdi = fdi + 1) begin : g_feed_dq
			if (fdi == 0) begin
				assign feed_dequant[fdi] = feed_chr_dc_inj;
				assign feed_dc_only_dq[fdi] = feed_chr_dc_inj;
			end else begin
				assign feed_dequant[fdi] = feed_dequant_raw[fdi];
				assign feed_dc_only_dq[fdi] = 29'sd0;
			end
		end
	endgenerate
	h264_idct4x4 u_feed_idct (
		.dequant(feed_dequant),
		.residual(feed_idct)
	);
	h264_idct4x4 u_feed_dc_only_idct (
		.dequant(feed_dc_only_dq),
		.residual(feed_dc_only_idct)
	);
	function automatic [5:0] chroma4x4_index;
		input [1:0] block;
		input [3:0] sample;
		reg [1:0] bx, by, sx, sy;
		begin
			bx = block[0];
			by = block[1];
			sx = sample[1:0];
			sy = sample[3:2];
			chroma4x4_index = {by, sy, bx, sx};
		end
	endfunction
	function automatic signed [15:0] sat16;
		input signed [28:0] v;
		begin
			if (v > 29'sd32767) sat16 = 16'sd32767;
			else if (v < -29'sd32768) sat16 = -16'sd32768;
			else sat16 = v[15:0];
		end
	endfunction

	wire feed_taken = (core_intra_blocks_done > {1'b0, luma4x4_idx});

	task automatic clear_pred;
		integer pi;
		begin
			part_mode_r <= 3'd0;
			sub_mb_types_r <= 8'd0;
			ref_pack_r <= 8'd0;
			mvd_valid_r <= 16'd0;
			for (pi = 0; pi < 16; pi = pi + 1) begin
				mvd_x_r[pi] <= 16'sd0;
				mvd_y_r[pi] <= 16'sd0;
			end
		end
	endtask

	task automatic publish_pred;
		integer pi;
		begin
			part_mode <= part_mode_r;
			sub_mb_types <= sub_mb_types_r;
			ref_idx_l0_packed <= ref_pack_r;
			mvd_valid <= mvd_valid_r;
			for (pi = 0; pi < 16; pi = pi + 1) begin
				mvd_x[pi] <= mvd_x_r[pi];
				mvd_y[pi] <= mvd_y_r[pi];
			end
		end
	endtask

	// ── Main FSM ────────────────────────────────────────────────────────
	always @(posedge clk) begin
		mb_type_valid <= 1'b0;
		luma4x4_valid <= 1'b0;
		rbsp_request_valid <= 1'b0;
		cav_start <= 1'b0;

		if (reset) begin
			st <= ST_IDLE;
			mb_addr <= 16'd0;
			mb_total <= 16'd0;
			abs_bit <= 16'd0;
			res_start_bit <= 16'd0;
			res_step <= 5'd0;
			qp_r <= 6'd0;
			cbp_l_r <= 4'd0;
			cbp_c_r <= 2'd0;
			mb_type_r <= 8'd0;
			is_i16_r <= 1'b0;
			slice_is_i_r <= 1'b0;
			mb_intra_r <= 1'b0;
			mb_skip_r <= 1'b0;
			feed_luma_r <= 1'b0;
			inter_res_only_r <= 1'b0;
			blk_guard <= 6'd0;
			guard <= 16'd0;
			win_armed <= 1'b0;
			skip_left <= 16'd0;
			tc_left_valid <= 1'b0;
			frame_feed_done <= 1'b0;
			error <= 1'b0;
			slice_desync <= 1'b0;
			slice_desync_early <= 1'b0;
			slice_desync_long <= 1'b0;
			chroma_residual_valid <= 1'b0;
			for (ci = 0; ci < 64; ci = ci + 1) begin
				chroma_residual_u[ci] <= 16'sd0;
				chroma_residual_v[ci] <= 16'sd0;
			end
			for (ci = 0; ci < 4; ci = ci + 1) begin
				chr_tc_u[ci] <= 5'd0;
				chr_tc_v[ci] <= 5'd0;
				chr_dc_u[ci] <= 29'sd0;
				chr_dc_v[ci] <= 29'sd0;
			end
			mb_type <= 5'd0;
			mb_skip <= 1'b0;
			mb_intra <= 1'b0;
			part_mode <= 3'd0;
			sub_mb_types <= 8'd0;
			ref_idx_l0_packed <= 8'd0;
			mvd_valid <= 16'd0;
			i4_pred_mode_flags <= 16'd0;
			i4_rem_modes <= 48'd0;
			i4_modes_present <= 1'b0;
			intra16x16_mode <= 2'd2;
			chroma_pred_mode <= 2'd0;
			cbp_luma <= 4'd0;
			cbp_chroma <= 2'd0;
			mb_qp_delta <= 6'sd0;
			mb_qp_y <= 6'd0;
			mb_residual_bit_offset <= 16'd0;
			luma4x4_idx <= 4'd0;
			luma4x4_qp <= 6'd0;
			luma4x4_total_coeff <= 5'd0;
			luma4x4_trailing_ones <= 2'd0;
			rbsp_request_offset <= 16'd0;
			num_ref_r <= 8'd1;
			use_inter_cbp <= 1'b0;
			clear_pred;
			for (ci = 0; ci < 16; ci = ci + 1) begin
				luma4x4_coeff_zigzag[ci] <= 16'sd0;
				tc_cur[ci] <= 5'd0;
				mvd_x[ci] <= 16'sd0;
				mvd_y[ci] <= 16'sd0;
			end
			for (ci = 0; ci < 4; ci = ci + 1)
				tc_left[ci] <= 5'd0;
			for (ci = 0; ci < MB_W_MAX; ci = ci + 1)
				tc_top_valid[ci] <= 1'b0;
		end else begin
			case (st)
			ST_IDLE: begin
				frame_feed_done <= 1'b0;
				if (slice_go && (mb_width != 8'd0) && (mb_height != 8'd0) && rbsp_complete) begin
					mb_total <= {8'd0, mb_width} * {8'd0, mb_height};
					mb_addr <= first_mb_in_slice;
					qp_r <= slice_qp_y;
					slice_is_i_r <= slice_is_i;
					num_ref_r <= (num_ref_idx_l0_active == 8'd0) ? 8'd1 : num_ref_idx_l0_active;
					tc_left_valid <= 1'b0;
					for (ci = 0; ci < MB_W_MAX; ci = ci + 1)
						tc_top_valid[ci] <= 1'b0;
					error <= 1'b0;
					slice_desync <= 1'b0;
					slice_desync_early <= 1'b0;
					slice_desync_long <= 1'b0;
					guard <= 16'd0;
					st <= ST_MB0_LOAD;
				end
			end

			// ── MB0: syntax already known from slice_hdr_parser ───────
			ST_MB0_LOAD: begin
				abs_bit <= first_residual_bit_offset;
				qp_r <= slice_qp_y;
				mb_qp_y <= slice_qp_y;
				mb_qp_delta <= 6'sd0;
				if (slice_is_i_r) begin
					mb_skip_r <= 1'b0;
					mb_skip <= 1'b0;
					mb_intra_r <= 1'b1;
					mb_intra <= 1'b1;
					feed_luma_r <= 1'b1;
					inter_res_only_r <= 1'b0;
					mb_type_r <= first_mb_type;
					mb_type <= first_mb_type[4:0];
					is_i16_r <= (first_mb_type >= 8'd1) && (first_mb_type <= 8'd24);
					i4_pred_mode_flags <= first_i4_pred_mode_flags;
					i4_rem_modes <= first_i4_rem_modes;
					i4_modes_present <= first_i4_modes_present;
					chroma_pred_mode <= first_chroma_pred_mode;
					clear_pred;
					publish_pred;
					if ((first_mb_type >= 8'd1) && (first_mb_type <= 8'd24)) begin
						intra16x16_mode <= (first_mb_type - 8'd1) & 2'd3;
						cbp_l_r <= i16_cbp_from_type(first_mb_type)[3:0];
						cbp_c_r <= i16_cbp_from_type(first_mb_type)[5:4];
						cbp_luma <= i16_cbp_from_type(first_mb_type)[3:0];
						cbp_chroma <= i16_cbp_from_type(first_mb_type)[5:4];
					end else begin
						intra16x16_mode <= 2'd2;
						cbp_l_r <= first_cbp_luma;
						cbp_c_r <= first_cbp_chroma;
						cbp_luma <= first_cbp_luma;
						cbp_chroma <= first_cbp_chroma;
					end
					res_start_bit <= first_residual_bit_offset;
					mb_residual_bit_offset <= first_residual_bit_offset;
					for (ci = 0; ci < 16; ci = ci + 1)
						tc_cur[ci] <= 5'd0;
					for (ci = 0; ci < 4; ci = ci + 1) begin
						chr_tc_u[ci] <= 5'd0;
						chr_tc_v[ci] <= 5'd0;
						chr_dc_u[ci] <= 29'sd0;
						chr_dc_v[ci] <= 29'sd0;
					end
					chroma_residual_valid <= 1'b0;
					for (ci = 0; ci < 64; ci = ci + 1) begin
						chroma_residual_u[ci] <= 16'sd0;
						chroma_residual_v[ci] <= 16'sd0;
					end
					res_step <= 5'd0;
					st <= ST_MB_PULSE;
				end else if (first_mb_p_skip) begin
					// First skip_run already consumed. mb_skip_run==0 is legal
					// (no run present) — do not coerce to 1.
					skip_left <= first_p_skip_run;
					abs_bit <= first_residual_bit_offset;
					st <= (first_p_skip_run == 16'd0) ? ST_P_AFTER_MB : ST_P_SKIP_EMIT;
				end else begin
					// First coded P MB (or intra-in-P) fully parsed by header.
					mb_skip_r <= 1'b0;
					mb_skip <= 1'b0;
					mb_intra_r <= first_mb_intra;
					mb_intra <= first_mb_intra;
					if (first_mb_intra) begin
						// Table 7-13: mb_type 5..30 → I type 0..25
						mb_type_r <= (first_mb_type >= 8'd5) ? (first_mb_type - 8'd5) : first_mb_type;
						mb_type <= (first_mb_type >= 8'd5) ? (first_mb_type - 8'd5) : first_mb_type[4:0];
						feed_luma_r <= 1'b1;
						inter_res_only_r <= 1'b0;
						is_i16_r <= (first_mb_type >= 8'd6) && (first_mb_type <= 8'd29);
						i4_pred_mode_flags <= first_i4_pred_mode_flags;
						i4_rem_modes <= first_i4_rem_modes;
						i4_modes_present <= first_i4_modes_present;
						chroma_pred_mode <= first_chroma_pred_mode;
						if ((first_mb_type >= 8'd6) && (first_mb_type <= 8'd29)) begin
							intra16x16_mode <= (first_mb_type - 8'd6) & 2'd3;
							cbp_l_r <= i16_cbp_from_type(first_mb_type - 8'd5)[3:0];
							cbp_c_r <= i16_cbp_from_type(first_mb_type - 8'd5)[5:4];
							cbp_luma <= i16_cbp_from_type(first_mb_type - 8'd5)[3:0];
							cbp_chroma <= i16_cbp_from_type(first_mb_type - 8'd5)[5:4];
						end else begin
							intra16x16_mode <= 2'd2;
							cbp_l_r <= first_cbp_luma;
							cbp_c_r <= first_cbp_chroma;
							cbp_luma <= first_cbp_luma;
							cbp_chroma <= first_cbp_chroma;
						end
						clear_pred;
						publish_pred;
					end else begin
						mb_type_r <= first_mb_type;
						mb_type <= first_mb_type[4:0];
						feed_luma_r <= 1'b0;
						inter_res_only_r <= 1'b1;
						is_i16_r <= 1'b0;
						part_mode_r <= first_mb_part_mode;
						sub_mb_types_r <= first_sub_mb_types;
						ref_pack_r <= first_mb_ref_idx_l0;
						mvd_valid_r <= first_mb_mvd_valid;
						for (ci = 0; ci < 16; ci = ci + 1) begin
							mvd_x_r[ci] = first_mb_mvd_x[ci];
							mvd_y_r[ci] = first_mb_mvd_y[ci];
						end
						publish_pred;
						cbp_l_r <= first_cbp_luma;
						cbp_c_r <= first_cbp_chroma;
						cbp_luma <= first_cbp_luma;
						cbp_chroma <= first_cbp_chroma;
						chroma_pred_mode <= 2'd0;
						i4_modes_present <= 1'b0;
					end
					res_start_bit <= first_residual_bit_offset;
					mb_residual_bit_offset <= first_residual_bit_offset;
					for (ci = 0; ci < 16; ci = ci + 1)
						tc_cur[ci] <= 5'd0;
					res_step <= 5'd0;
					// Inter: bit-sync residual first (if any), then pulse+yield.
					// Intra-in-P / I-style: pulse then feed residual.
					if (first_mb_intra)
						st <= ST_MB_PULSE;
					else if ((first_cbp_luma != 4'd0) || (first_cbp_chroma != 2'd0))
						st <= ST_RES_REQ;
					else begin
						// No residual bits — pulse skip-style with cbp=0.
						st <= ST_MB_PULSE;
					end
				end
			end

			ST_P_SKIP_EMIT: begin
				if (skip_left == 16'd0) begin
					// Run exhausted (including run that ended the slice).
					st <= ST_P_AFTER_MB;
				end else if (mb_addr >= mb_total) begin
					// Skip run walked past PicSizeInMbs.
					slice_desync <= 1'b1;
					slice_desync_long <= 1'b1;
					st <= ST_FAIL;
				end else begin
					mb_skip_r <= 1'b1;
					mb_skip <= 1'b1;
					mb_intra_r <= 1'b0;
					mb_intra <= 1'b0;
					mb_type_r <= 8'd0;
					mb_type <= 5'd0;
					feed_luma_r <= 1'b0;
					inter_res_only_r <= 1'b0;
					is_i16_r <= 1'b0;
					cbp_l_r <= 4'd0;
					cbp_c_r <= 2'd0;
					cbp_luma <= 4'd0;
					cbp_chroma <= 2'd0;
					mb_qp_delta <= 6'sd0;
					mb_qp_y <= qp_r;
					mb_residual_bit_offset <= abs_bit;
					res_start_bit <= abs_bit;
					clear_pred;
					part_mode <= 3'd0;
					sub_mb_types <= 8'd0;
					ref_idx_l0_packed <= 8'd0;
					mvd_valid <= 16'd0;
					for (ci = 0; ci < 16; ci = ci + 1) begin
						mvd_x[ci] <= 16'sd0;
						mvd_y[ci] <= 16'sd0;
					end
					i4_modes_present <= 1'b0;
					chroma_pred_mode <= 2'd0;
					skip_left <= skip_left - 16'd1;
					st <= ST_MB_PULSE;
				end
			end

			ST_MB_PULSE: begin
				mb_type_valid <= 1'b1;
				mb_skip <= mb_skip_r;
				mb_intra <= mb_intra_r;
				publish_pred;
				st <= ST_MB_GAP;
			end

			ST_MB_GAP: begin
				if (mb_skip_r) begin
					// P_Skip: no residual; yield so core can MC.
					st <= ST_YIELD_CORE;
				end else if (inter_res_only_r) begin
					// Residual already bit-synced before pulse (or none).
					st <= ST_YIELD_CORE;
				end else begin
					// I / intra-in-P: feed residual into core.
					st <= ST_RES_REQ;
				end
			end

			// ── Residual walk (luma feed and/or bit-sync) ─────────────
			ST_RES_REQ: begin
				rbsp_request_offset <= {3'd0, abs_bit[15:3]};
				rbsp_request_valid <= 1'b1;
				win_armed <= 1'b0;
				if (feed_luma_r) begin
					chroma_residual_valid <= 1'b0;
					for (ci = 0; ci < 64; ci = ci + 1) begin
						chroma_residual_u[ci] <= 16'sd0;
						chroma_residual_v[ci] <= 16'sd0;
					end
					for (ci = 0; ci < 4; ci = ci + 1) begin
						chr_tc_u[ci] <= 5'd0;
						chr_tc_v[ci] <= 5'd0;
						chr_dc_u[ci] <= 29'sd0;
						chr_dc_v[ci] <= 29'sd0;
					end
				end
				st <= ST_RES_ARM;
			end

			ST_RES_ARM: begin
				win_armed <= 1'b1;
				if (win_armed)
					st <= ST_RES_START;
			end

			ST_RES_START: begin
				if (res_step >= STEP_END) begin
					tc_left_valid <= 1'b1;
					for (ci = 0; ci < 4; ci = ci + 1) begin
						tc_left[ci] <= tc_cur[{ci[1:0], 2'd3}];
						tc_top[{mb_x8[5:0], ci[1:0]}] <= tc_cur[{2'd3, ci[1:0]}];
					end
					tc_top_valid[mb_x8] <= 1'b1;
					if (feed_luma_r)
						chroma_residual_valid <= 1'b1;
					if (inter_res_only_r && !mb_skip_r) begin
						// Finished pre-pulse bit-sync for inter: now launch core.
						mb_residual_bit_offset <= res_start_bit;
						st <= ST_MB_PULSE;
					end else if (feed_luma_r) begin
						st <= ST_WAIT_CORE;
					end else begin
						st <= ST_YIELD_CORE;
					end
				end else if (!res_step_coded(res_step, cbp_l_r, cbp_c_r, is_i16_r)) begin
					if (res_step < STEP_LUMA_END) begin
						tc_cur[res_step[3:0]] <= 5'd0;
						if (feed_luma_r) begin
							luma4x4_idx <= res_step[3:0];
							luma4x4_qp <= qp_r;
							luma4x4_total_coeff <= 5'd0;
							luma4x4_trailing_ones <= 2'd0;
							for (ci = 0; ci < 16; ci = ci + 1)
								luma4x4_coeff_zigzag[ci] <= 16'sd0;
							blk_guard <= 6'd0;
							st <= ST_RES_FEED;
						end else begin
							res_step <= res_step + 5'd1;
						end
					end else if (res_step == STEP_CHR_DC_U || res_step == STEP_CHR_DC_V) begin
						// Uncoded chroma DC → zero Hadamard state.
						if (feed_luma_r) begin
							for (ci = 0; ci < 4; ci = ci + 1) begin
								if (res_step == STEP_CHR_DC_U)
									chr_dc_u[ci] <= 29'sd0;
								else
									chr_dc_v[ci] <= 29'sd0;
							end
						end
						res_step <= res_step + 5'd1;
					end else begin
						// Uncoded chroma AC: still inject DC-only residual when cbp!=0.
						if (feed_luma_r && (cbp_c_r != 2'd0)) begin
							for (ci = 0; ci < 16; ci = ci + 1) begin
								if (feed_chr_ac_is_v)
									chroma_residual_v[chroma4x4_index(feed_chr_ac_blk, ci[3:0])] <= sat16(feed_dc_only_idct[ci]);
								else
									chroma_residual_u[chroma4x4_index(feed_chr_ac_blk, ci[3:0])] <= sat16(feed_dc_only_idct[ci]);
							end
						end
						if (feed_luma_r) begin
							if (feed_chr_ac_is_v)
								chr_tc_v[feed_chr_ac_blk] <= 5'd0;
							else
								chr_tc_u[feed_chr_ac_blk] <= 5'd0;
						end
						res_step <= res_step + 5'd1;
					end
				end else begin
					if (rel_bit16 >= 16'd400) begin
						rbsp_request_offset <= {3'd0, abs_bit[15:3]};
						rbsp_request_valid <= 1'b1;
						win_armed <= 1'b0;
						st <= ST_RES_ARM;
					end else begin
						if (res_step < STEP_LUMA_END) begin
							cav_table <= tok_table_luma;
							cav_max <= 5'd16;
						end else if (res_step == STEP_CHR_DC_U || res_step == STEP_CHR_DC_V) begin
							cav_table <= 3'd4; // nC = -1 chroma DC coeff_token
							cav_max <= 5'd4;
						end else begin
							cav_table <= feed_chr_ac_table;
							cav_max <= 5'd15;
						end
						cav_bit_off <= rel_bit10;
						cav_start <= 1'b1;
						st <= ST_RES_WAIT;
					end
				end
			end

			ST_RES_WAIT: begin
				if (cav_done) begin
					if (!cav_ok) begin
						error <= 1'b1;
						st <= ST_FAIL;
					end else begin
						abs_bit <= win_bit_base + {6'd0, cav_bit_end};
						if (res_step < STEP_LUMA_END) begin
							tc_cur[res_step[3:0]] <= cav_tc;
							if (feed_luma_r) begin
								luma4x4_idx <= res_step[3:0];
								luma4x4_qp <= qp_r;
								luma4x4_total_coeff <= cav_tc;
								luma4x4_trailing_ones <= cav_t1;
								for (ci = 0; ci < 16; ci = ci + 1)
									luma4x4_coeff_zigzag[ci] <= cav_coeff[ci];
								blk_guard <= 6'd0;
								st <= ST_RES_FEED;
							end else begin
								res_step <= res_step + 5'd1;
								st <= ST_RES_START;
							end
						end else if (res_step == STEP_CHR_DC_U || res_step == STEP_CHR_DC_V) begin
							if (feed_luma_r) begin
								for (ci = 0; ci < 4; ci = ci + 1) begin
									if (res_step == STEP_CHR_DC_U)
										chr_dc_u[ci] <= feed_chr_dc_had[ci];
									else
										chr_dc_v[ci] <= feed_chr_dc_had[ci];
								end
							end
							res_step <= res_step + 5'd1;
							st <= ST_RES_START;
						end else begin
							// Chroma AC: dequant(max15)+DC inject+IDCT into residual plane.
							if (feed_luma_r) begin
								for (ci = 0; ci < 16; ci = ci + 1) begin
									if (feed_chr_ac_is_v)
										chroma_residual_v[chroma4x4_index(feed_chr_ac_blk, ci[3:0])] <= sat16(feed_idct[ci]);
									else
										chroma_residual_u[chroma4x4_index(feed_chr_ac_blk, ci[3:0])] <= sat16(feed_idct[ci]);
								end
								if (feed_chr_ac_is_v)
									chr_tc_v[feed_chr_ac_blk] <= cav_tc;
								else
									chr_tc_u[feed_chr_ac_blk] <= cav_tc;
							end
							res_step <= res_step + 5'd1;
							st <= ST_RES_START;
						end
					end
				end
			end

			ST_RES_FEED: begin
				luma4x4_valid <= 1'b1;
				blk_guard <= 6'd0;
				st <= ST_RES_ACK;
			end

			ST_RES_ACK: begin
				blk_guard <= blk_guard + 6'd1;
				if (feed_taken) begin
					res_step <= res_step + 5'd1;
					st <= ST_RES_START;
				end else if (blk_guard == 6'h3F) begin
					st <= ST_RES_FEED;
				end
			end

			ST_WAIT_CORE: begin
				// I path: hold busy while core finishes (uses luma ports).
				guard <= guard + 16'd1;
				if ((!core_busy && (guard > 16'd3)) || (guard == 16'hFFFF)) begin
					guard <= 16'd0;
					mb_addr <= mb_addr + 16'd1;
					st <= ST_P_AFTER_MB;
				end
			end

			ST_YIELD_CORE: begin
				// Inter / skip: busy=0 so core owns RBSP for residual+MC.
				guard <= guard + 16'd1;
				if ((!core_busy && (guard > 16'd3)) || (guard == 16'hFFFF)) begin
					guard <= 16'd0;
					mb_addr <= mb_addr + 16'd1;
					st <= ST_P_AFTER_MB;
				end
			end

			// ── After each MB: EOS / next skip_run / next syntax ──────
			ST_P_AFTER_MB: begin
				if (slice_is_i_r) begin
					if (mb_addr >= mb_total)
						st <= ST_EOS_CHECK;
					else begin
						// Next I MB syntax
						use_inter_cbp <= 1'b0;
						mb_intra_r <= 1'b1;
						feed_luma_r <= 1'b1;
						inter_res_only_r <= 1'b0;
						mb_skip_r <= 1'b0;
						st <= ST_SYN_REQ;
						ret_st <= 8'd0; // will start mb_type after arm
					end
				end else begin
					// P slice: after a skip run batch mid-emit?
					if (skip_left != 16'd0) begin
						st <= ST_P_SKIP_EMIT;
					end else if (mb_addr >= mb_total) begin
						st <= ST_EOS_CHECK;
					end else begin
						// Align window then decide more_rbsp / next skip_run
						rbsp_request_offset <= {3'd0, abs_bit[15:3]};
						rbsp_request_valid <= 1'b1;
						win_armed <= 1'b0;
						st <= ST_P_SKIP_RUN;
					end
				end
			end

			ST_P_SKIP_RUN: begin
				// Need window armed for more_rbsp_w + ue parse
				win_armed <= 1'b1;
				if (!win_armed) begin
					// wait one edge
				end else if (!more_rbsp_w) begin
					// Clean EOS if skip-run spanned to picture end; else early.
					if (mb_addr < mb_total) begin
						slice_desync <= 1'b1;
						slice_desync_early <= 1'b1;
					end
					st <= ST_EOS_CHECK;
				end else if (mb_addr >= mb_total) begin
					// Still data (or would parse more) after PicSizeInMbs.
					slice_desync <= 1'b1;
					slice_desync_long <= 1'b1;
					st <= ST_EOS_CHECK;
				end else begin
					// Parse next mb_skip_run (0 is legal → coded MB follows)
					ue_zeros <= 8'd0;
					ret_st <= 8'd6;
					st <= ST_SYN_UE0;
				end
			end

			ST_EOS_CHECK: begin
				// Cross-check PicSizeInMbs vs bitstream end.
				if (mb_addr < mb_total) begin
					slice_desync <= 1'b1;
					slice_desync_early <= 1'b1;
				end else if (mb_addr > mb_total) begin
					slice_desync <= 1'b1;
					slice_desync_long <= 1'b1;
					error <= 1'b1;
				end else if (more_rbsp_w) begin
					// Full pic decoded but trailing non-RBSP-trailing bits remain.
					slice_desync <= 1'b1;
					slice_desync_long <= 1'b1;
				end
				rbsp_request_offset <= {3'd0, abs_bit[15:3]};
				rbsp_request_valid <= 1'b1;
				st <= ST_DONE;
			end

			// ── Syntax bit reader ─────────────────────────────────────
			ST_SYN_REQ: begin
				rbsp_request_offset <= {3'd0, abs_bit[15:3]};
				rbsp_request_valid <= 1'b1;
				win_armed <= 1'b0;
				st <= ST_SYN_ARM;
			end

			ST_SYN_ARM: begin
				win_armed <= 1'b1;
				if (win_armed) begin
					// Preserve ret_st — callers set it (mb_type=0, skip_run=6, …)
					// and window realign from ST_SYN_UE0/BIT must not clobber it.
					ue_zeros <= 8'd0;
					st <= ST_SYN_UE0;
				end
			end

			ST_SYN_UE0: begin
				if (rel_bit16 >= 16'd500) begin
					rbsp_request_offset <= {3'd0, abs_bit[15:3]};
					rbsp_request_valid <= 1'b1;
					win_armed <= 1'b0;
					st <= ST_SYN_ARM;
				end else if (!rd_bit) begin
					ue_zeros <= ue_zeros + 8'd1;
					abs_bit <= abs_bit + 16'd1;
					if (ue_zeros >= 8'd28) begin
						error <= 1'b1;
						st <= ST_FAIL;
					end
				end else begin
					abs_bit <= abs_bit + 16'd1;
					if (ue_zeros == 8'd0) begin
						ue_val <= 32'd0;
						st <= ST_SYN_DISPATCH;
					end else begin
						ue_suf_left <= ue_zeros;
						ue_suf <= 32'd0;
						st <= ST_SYN_UE1;
					end
				end
			end

			ST_SYN_UE1: begin
				if (rel_bit16 >= 16'd500) begin
					rbsp_request_offset <= {3'd0, abs_bit[15:3]};
					rbsp_request_valid <= 1'b1;
					win_armed <= 1'b0;
					st <= ST_SYN_ARM;
				end else begin
					ue_suf <= {ue_suf[30:0], rd_bit};
					abs_bit <= abs_bit + 16'd1;
					if (ue_suf_left == 8'd1) begin
						ue_val <= ((32'd1 << ue_zeros) - 32'd1) + {ue_suf[30:0], rd_bit};
						st <= ST_SYN_DISPATCH;
					end else
						ue_suf_left <= ue_suf_left - 8'd1;
				end
			end

			ST_SYN_BIT: begin
				if (rel_bit16 >= 16'd500) begin
					rbsp_request_offset <= {3'd0, abs_bit[15:3]};
					rbsp_request_valid <= 1'b1;
					win_armed <= 1'b0;
					st <= ST_SYN_ARM;
				end else begin
					bit_acc <= {bit_acc[30:0], rd_bit};
					abs_bit <= abs_bit + 16'd1;
					if (bit_left == 8'd1)
						st <= ST_SYN_DISPATCH;
					else
						bit_left <= bit_left - 8'd1;
				end
			end

			ST_SYN_DISPATCH: begin
				case (ret_st)
				// 0: mb_type done (I slice or P coded)
				8'd0: begin
					if (slice_is_i_r) begin
						mb_type_r <= ue_val[7:0];
						mb_type <= ue_val[4:0];
						mb_skip_r <= 1'b0;
						mb_intra_r <= 1'b1;
						feed_luma_r <= 1'b1;
						inter_res_only_r <= 1'b0;
						if (ue_val > 32'd25) begin
							error <= 1'b1; st <= ST_FAIL;
						end else if (ue_val == 32'd25) begin
							error <= 1'b1; st <= ST_FAIL; // I_PCM
						end else if (ue_val == 32'd0) begin
							is_i16_r <= 1'b0;
							i4_i <= 5'd0; flags_r <= 16'd0; rems_r <= 48'd0;
							bit_left <= 8'd1; bit_acc <= 32'd0;
							ret_st <= 8'd1; st <= ST_SYN_BIT;
						end else begin
							is_i16_r <= 1'b1;
							intra16x16_mode <= (ue_val[7:0] - 8'd1) & 2'd3;
							cbp_l_r <= i16_cbp_from_type(ue_val[7:0])[3:0];
							cbp_c_r <= i16_cbp_from_type(ue_val[7:0])[5:4];
							i4_modes_present <= 1'b0;
							ue_zeros <= 8'd0; ret_st <= 8'd3; st <= ST_SYN_UE0;
						end
					end else begin
						// P mb_type
						mb_skip_r <= 1'b0;
						mb_skip <= 1'b0;
						if (ue_val <= 32'd4) begin
							// Inter P_L0_* / P_8x8
							mb_intra_r <= 1'b0;
							mb_intra <= 1'b0;
							mb_type_r <= ue_val[7:0];
							mb_type <= ue_val[4:0];
							feed_luma_r <= 1'b0;
							inter_res_only_r <= 1'b1;
							is_i16_r <= 1'b0;
							part_mode_r <= p_part_mode_of(ue_val[7:0]);
							clear_pred;
							part_mode_r <= p_part_mode_of(ue_val[7:0]);
							pred_blk <= 3'd0;
							pred_sub <= 3'd0;
							pred_ref_i <= 3'd0;
							i4_modes_present <= 1'b0;
							chroma_pred_mode <= 2'd0;
							if (ue_val == 32'd3 || ue_val == 32'd4) begin
								ue_zeros <= 8'd0; ret_st <= 8'd7; st <= ST_SYN_UE0;
							end else begin
								// ref_idx / mvd
								ret_st <= 8'd8; st <= ST_SYN_DISPATCH;
							end
						end else if (ue_val <= 32'd30) begin
							// Intra-in-P
							mb_intra_r <= 1'b1;
							mb_intra <= 1'b1;
							mb_type_r <= ue_val[7:0] - 8'd5;
							mb_type <= ue_val[4:0] - 5'd5;
							feed_luma_r <= 1'b1;
							inter_res_only_r <= 1'b0;
							clear_pred; publish_pred;
							if (ue_val == 32'd5) begin
								is_i16_r <= 1'b0;
								i4_i <= 5'd0; flags_r <= 16'd0; rems_r <= 48'd0;
								bit_left <= 8'd1; bit_acc <= 32'd0;
								ret_st <= 8'd1; st <= ST_SYN_BIT;
							end else if (ue_val == 32'd30) begin
								error <= 1'b1; st <= ST_FAIL; // I_PCM
							end else begin
								is_i16_r <= 1'b1;
								intra16x16_mode <= (ue_val[7:0] - 8'd6) & 2'd3;
								cbp_l_r <= i16_cbp_from_type(ue_val[7:0] - 8'd5)[3:0];
								cbp_c_r <= i16_cbp_from_type(ue_val[7:0] - 8'd5)[5:4];
								i4_modes_present <= 1'b0;
								ue_zeros <= 8'd0; ret_st <= 8'd3; st <= ST_SYN_UE0;
							end
						end else begin
							error <= 1'b1; st <= ST_FAIL;
						end
					end
				end
				// 1: I4 prev flag
				8'd1: begin
					if (bit_acc[0]) begin
						flags_r[i4_i[3:0]] <= 1'b1;
						if (i4_i == 5'd15) begin
							i4_pred_mode_flags <= flags_r | (16'h1 << i4_i[3:0]);
							i4_rem_modes <= rems_r;
							i4_modes_present <= 1'b1;
							ue_zeros <= 8'd0; ret_st <= 8'd3; st <= ST_SYN_UE0;
						end else begin
							i4_i <= i4_i + 5'd1;
							bit_left <= 8'd1; bit_acc <= 32'd0;
							ret_st <= 8'd1; st <= ST_SYN_BIT;
						end
					end else begin
						flags_r[i4_i[3:0]] <= 1'b0;
						bit_left <= 8'd3; bit_acc <= 32'd0;
						ret_st <= 8'd2; st <= ST_SYN_BIT;
					end
				end
				// 2: rem_intra4x4
				8'd2: begin
					rems_r[i4_i * 3 +: 3] <= bit_acc[2:0];
					if (i4_i == 5'd15) begin
						i4_pred_mode_flags <= flags_r;
						i4_rem_modes <= (rems_r & ~(48'h7 << (i4_i * 3))) |
							({{45{1'b0}}, bit_acc[2:0]} << (i4_i * 3));
						i4_modes_present <= 1'b1;
						ue_zeros <= 8'd0; ret_st <= 8'd3; st <= ST_SYN_UE0;
					end else begin
						i4_i <= i4_i + 5'd1;
						bit_left <= 8'd1; bit_acc <= 32'd0;
						ret_st <= 8'd1; st <= ST_SYN_BIT;
					end
				end
				// 3: intra_chroma_pred_mode
				8'd3: begin
					chroma_pred_mode <= ue_val[1:0];
					if (is_i16_r) begin
						ue_zeros <= 8'd0; ret_st <= 8'd5; st <= ST_SYN_UE0;
					end else begin
						use_inter_cbp <= 1'b0;
						ue_zeros <= 8'd0; ret_st <= 8'd4; st <= ST_SYN_UE0;
					end
				end
				// 4: cbp
				8'd4: begin
					if (ue_val >= 32'd48) begin
						error <= 1'b1; st <= ST_FAIL;
					end else begin
						if (use_inter_cbp) begin
							cbp_l_r <= cbp_inter_map(ue_val[5:0])[3:0];
							cbp_c_r <= cbp_inter_map(ue_val[5:0])[5:4];
							cbp_luma <= cbp_inter_map(ue_val[5:0])[3:0];
							cbp_chroma <= cbp_inter_map(ue_val[5:0])[5:4];
						end else begin
							cbp_l_r <= cbp_intra_map(ue_val[5:0])[3:0];
							cbp_c_r <= cbp_intra_map(ue_val[5:0])[5:4];
							cbp_luma <= cbp_intra_map(ue_val[5:0])[3:0];
							cbp_chroma <= cbp_intra_map(ue_val[5:0])[5:4];
						end
						if ((use_inter_cbp ? cbp_inter_map(ue_val[5:0])
						                   : cbp_intra_map(ue_val[5:0])) != 6'd0) begin
							ue_zeros <= 8'd0; ret_st <= 8'd5; st <= ST_SYN_UE0;
						end else begin
							mb_qp_delta <= 6'sd0;
							mb_qp_y <= qp_r;
							res_start_bit <= abs_bit;
							mb_residual_bit_offset <= abs_bit;
							for (ci = 0; ci < 16; ci = ci + 1)
								tc_cur[ci] <= 5'd0;
							res_step <= 5'd0;
							if (inter_res_only_r)
								st <= ST_MB_PULSE;
							else
								st <= ST_MB_PULSE;
						end
					end
				end
				// 5: mb_qp_delta
				8'd5: begin
					mb_qp_delta <= se6_from_ue(ue_val);
					begin : qp_upd
						reg signed [8:0] qn;
						qn = $signed({1'b0, qp_r}) + $signed({{3{se6_from_ue(ue_val)[5]}}, se6_from_ue(ue_val)});
						if (qn < 0) qn = qn + 9'sd52;
						else if (qn >= 9'sd52) qn = qn - 9'sd52;
						qp_r <= qn[5:0];
						mb_qp_y <= qn[5:0];
					end
					if (is_i16_r) begin
						cbp_luma <= cbp_l_r;
						cbp_chroma <= cbp_c_r;
					end
					res_start_bit <= abs_bit;
					mb_residual_bit_offset <= abs_bit;
					for (ci = 0; ci < 16; ci = ci + 1)
						tc_cur[ci] <= 5'd0;
					res_step <= 5'd0;
					if (inter_res_only_r && ((cbp_l_r != 4'd0) || (cbp_c_r != 2'd0) || is_i16_r))
						st <= ST_RES_REQ; // bit-sync then pulse
					else
						st <= ST_MB_PULSE;
				end
				// 6: mb_skip_run
				8'd6: begin
					skip_left <= ue_val[15:0];
					if (ue_val[15:0] != 16'd0)
						st <= ST_P_SKIP_EMIT;
					else if (!more_rbsp_w || (mb_addr >= mb_total))
						st <= ST_EOS_CHECK;
					else begin
						// coded MB follows
						ue_zeros <= 8'd0; ret_st <= 8'd0; st <= ST_SYN_UE0;
					end
				end
				// 7: sub_mb_type
				8'd7: begin
					if (ue_val > 32'd3) begin
						error <= 1'b1; st <= ST_FAIL;
					end else begin
						sub_mb_types_r[pred_blk[1:0] * 2 +: 2] <= ue_val[1:0];
						if (pred_blk >= 3'd3) begin
							pred_blk <= 3'd0;
							ret_st <= 8'd8; st <= ST_SYN_DISPATCH;
						end else begin
							pred_blk <= pred_blk + 3'd1;
							ue_zeros <= 8'd0; ret_st <= 8'd7; st <= ST_SYN_UE0;
						end
					end
				end
				// 8: ref_idx gate / consume
				8'd8: begin
					if ((num_ref_r <= 8'd1) || (mb_type_r == 8'd4) ||
					    (pred_ref_i >= p_part_count_of(mb_type_r))) begin
						pred_blk <= 3'd0;
						pred_sub <= 3'd0;
						// start mvd
						ret_st <= 8'd9; st <= ST_SYN_DISPATCH;
					end else if (num_ref_r == 8'd2) begin
						// te(1) = 1 bit inverted
						bit_left <= 8'd1; bit_acc <= 32'd0;
						ret_st <= 8'd11; st <= ST_SYN_BIT;
					end else begin
						ue_zeros <= 8'd0; ret_st <= 8'd12; st <= ST_SYN_UE0;
					end
				end
				// 9: prepare mvd_x ue
				8'd9: begin
					if (mb_type_r >= 8'd3) begin
						if (pred_blk >= 3'd4) begin
							use_inter_cbp <= 1'b1;
							ue_zeros <= 8'd0; ret_st <= 8'd4; st <= ST_SYN_UE0;
						end else if (pred_sub >= sub_part_count_of(sub_mb_types_r[pred_blk[1:0]*2 +: 2])) begin
							pred_blk <= pred_blk + 3'd1;
							pred_sub <= 3'd0;
							// loop
							ret_st <= 8'd9; st <= ST_SYN_DISPATCH;
						end else begin
							pred_mvd_slot <= {pred_blk[1:0], pred_sub[1:0]};
							ue_zeros <= 8'd0; ret_st <= 8'd13; st <= ST_SYN_UE0;
						end
					end else if (pred_blk >= p_part_count_of(mb_type_r)) begin
						use_inter_cbp <= 1'b1;
						ue_zeros <= 8'd0; ret_st <= 8'd4; st <= ST_SYN_UE0;
					end else begin
						pred_mvd_slot <= {2'd0, pred_blk[1:0]};
						ue_zeros <= 8'd0; ret_st <= 8'd13; st <= ST_SYN_UE0;
					end
				end
				// 11: te1 ref bit done
				8'd11: begin
					ref_pack_r[pred_ref_i[1:0] * 2 +: 2] <= {1'b0, ~bit_acc[0]};
					pred_ref_i <= pred_ref_i + 3'd1;
					ret_st <= 8'd8; st <= ST_SYN_DISPATCH;
				end
				// 12: ue ref_idx
				8'd12: begin
					ref_pack_r[pred_ref_i[1:0] * 2 +: 2] <= ue_val[1:0];
					pred_ref_i <= pred_ref_i + 3'd1;
					ret_st <= 8'd8; st <= ST_SYN_DISPATCH;
				end
				// 13: mvd_x
				8'd13: begin
					mvd_x_tmp <= se16_from_ue(ue_val);
					ue_zeros <= 8'd0; ret_st <= 8'd14; st <= ST_SYN_UE0;
				end
				// 14: mvd_y
				8'd14: begin
					mvd_x_r[pred_mvd_slot] <= mvd_x_tmp;
					mvd_y_r[pred_mvd_slot] <= se16_from_ue(ue_val);
					mvd_valid_r[pred_mvd_slot] <= 1'b1;
					if (mb_type_r >= 8'd3)
						pred_sub <= pred_sub + 3'd1;
					else
						pred_blk <= pred_blk + 3'd1;
					ret_st <= 8'd9; st <= ST_SYN_DISPATCH;
				end
				default: begin
					error <= 1'b1;
					st <= ST_FAIL;
				end
				endcase
			end

			ST_DONE: begin
				frame_feed_done <= 1'b1;
				if (slice_go)
					st <= ST_IDLE;
			end

			ST_FAIL: begin
				error <= 1'b1;
				if (slice_go)
					st <= ST_IDLE;
			end

			default: st <= ST_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
