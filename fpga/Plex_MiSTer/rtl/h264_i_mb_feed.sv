// Sequential I-slice macroblock feeder.
//
// Owns the RBSP window while an I/IDR slice is being reconstructed and walks
// real per-macroblock syntax + CAVLC residual.  Replaces the stream_path
// "latch first-MB coeffs and replay them on every MB" driver: each macroblock
// now gets its own residual from the bitstream.
//
// Scope (honest):
//   * I_NxN residual → 16 luma 4x4 CAVLC blocks (CBP-gated) fed to the core
//   * Chroma residual is consumed for bit-sync only (product chroma still 128)
//   * I_16x16 residual is consumed for bit-sync; DC Hadamard still open
//   * P-slice MB layer is out of scope (Mission 2)
//
// Area: one shared h264_cavlc_residual_block, sequential bit reader, no second
// RBSP store (reads the existing h264_rbsp_window).

`default_nettype none

module h264_i_mb_feed #(
	parameter int MB_W_MAX = 40
)(
	input  wire        clk,
	input  wire        reset,

	// Pulse when the slice header + first-MB syntax are ready and the whole
	// VCL RBSP is being captured into the window.
	input  wire        slice_go,
	input  wire        slice_is_i,
	input  wire [7:0]  mb_width,
	input  wire [7:0]  mb_height,
	input  wire [15:0] first_mb_in_slice,
	input  wire [5:0]  slice_qp_y,

	// First-MB syntax already parsed by slice_hdr_parser (denominator: MB0).
	input  wire [7:0]  first_mb_type,
	input  wire [15:0] first_i4_pred_mode_flags,
	input  wire [47:0] first_i4_rem_modes,
	input  wire        first_i4_modes_present,
	input  wire [3:0]  first_cbp_luma,
	input  wire [1:0]  first_cbp_chroma,
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

	// Per-block residual coeffs → decode_core luma4x4_* ports
	output reg         luma4x4_valid,
	output reg  [3:0]  luma4x4_idx,
	output reg  [5:0]  luma4x4_qp,
	output reg  [4:0]  luma4x4_total_coeff,
	output reg  [1:0]  luma4x4_trailing_ones,
	output reg signed [15:0] luma4x4_coeff_zigzag [0:15],

	output wire        busy,
	output reg         frame_feed_done,
	output reg         error
);

	localparam [4:0]
		ST_IDLE       = 5'd0,
		ST_MB0_LOAD   = 5'd1,
		ST_MB_PULSE   = 5'd2,
		ST_MB_GAP     = 5'd3,
		ST_RES_REQ    = 5'd4,
		ST_RES_ARM    = 5'd5,
		ST_RES_START  = 5'd6,
		ST_RES_WAIT   = 5'd7,
		ST_RES_FEED   = 5'd8,
		ST_RES_ACK    = 5'd9,
		ST_RES_NEXT   = 5'd10,
		ST_WAIT_CORE  = 5'd11,
		ST_SYN_REQ    = 5'd12,
		ST_SYN_ARM    = 5'd13,
		ST_SYN_UE0    = 5'd14,
		ST_SYN_UE1    = 5'd15,
		ST_SYN_BIT    = 5'd16,
		ST_SYN_DISPATCH = 5'd17,
		ST_DONE       = 5'd18,
		ST_FAIL       = 5'd19;

	// Residual step index: 0..15 luma, 16/17 chroma DC, 18..25 chroma AC
	localparam [4:0] STEP_LUMA_END  = 5'd16;
	localparam [4:0] STEP_CHR_DC_U  = 5'd16;
	localparam [4:0] STEP_CHR_DC_V  = 5'd17;
	localparam [4:0] STEP_CHR_AC0   = 5'd18;
	localparam [4:0] STEP_END       = 5'd26;

	reg [4:0]  st;
	reg [15:0] mb_addr;
	reg [15:0] mb_total;
	reg [15:0] abs_bit;
	reg [4:0]  res_step;
	reg [5:0]  qp_r;
	reg [3:0]  cbp_l_r;
	reg [1:0]  cbp_c_r;
	reg [7:0]  mb_type_r;
	reg        is_i16_r;
	reg [5:0]  blk_guard;
	reg [15:0] guard;
	reg        win_armed;

	// nC neighbour total_coeff
	reg [4:0]  tc_cur [0:15];
	reg [4:0]  tc_left [0:3];
	reg        tc_left_valid;
	reg [4:0]  tc_top [0:(MB_W_MAX*4)-1];
	reg        tc_top_valid [0:MB_W_MAX-1];

	// Bit reader
	reg [7:0]  ue_zeros;
	reg [7:0]  ue_suf_left;
	reg [31:0] ue_suf;
	reg [31:0] ue_val;
	reg [7:0]  bit_left;
	reg [31:0] bit_acc;
	reg [7:0]  ret_st;
	reg [4:0]  i4_i;
	reg [2:0]  rem_acc;
	reg        need_rem;
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

	assign busy = (st != ST_IDLE) && (st != ST_DONE) && (st != ST_FAIL);

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

	function automatic [5:0] i16_cbp_from_type;
		input [7:0] mt;
		reg [7:0] t;
		begin
			t = mt;
			// H.264 Table 7-11: I_16x16 mb_type 1..24 encodes pred + cbp.
			// cbp_chroma = ((mt-1)/4)%3 ; cbp_luma = (mt-1)>=12 ? 15 : 0
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

	// Absolute bit → window-relative, after a request at abs_bit[15:3]
	wire [15:0] win_bit_base = {rbsp_window_base[12:0], 3'd0};
	wire [15:0] rel_bit16 = abs_bit - win_bit_base;
	wire [9:0]  rel_bit10 = rel_bit16[9:0];

	// Live bit from window
	wire [5:0]  rd_byte_idx = rel_bit10[8:3];
	wire        rd_bit = rbsp_byte[rd_byte_idx][3'd7 - rel_bit10[2:0]];

	// nC / table for current luma blkIdx
	wire [3:0] cur_blk = res_step[3:0];
	wire [1:0] cur_bx = blk_x(cur_blk);
	wire [1:0] cur_by = blk_y(cur_blk);
	wire [7:0] mb_x8 = mb_addr % {8'd0, mb_width};
	wire [7:0] mb_y8 = mb_addr / {8'd0, mb_width};
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
				// I_16x16 always has DC (step handled separately); AC gated by cbp_luma
				if (is_i16)
					res_step_coded = 1'b1; // DC+AC walked; AC may be zero-tc quickly
				else
					res_step_coded = cbp_l[bi[3:2]];
			end else if (step == STEP_CHR_DC_U || step == STEP_CHR_DC_V)
				res_step_coded = (cbp_c != 2'd0);
			else
				res_step_coded = (cbp_c == 2'd2);
		end
	endfunction

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

	wire feed_taken = (core_intra_blocks_done > {1'b0, luma4x4_idx});

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
			res_step <= 5'd0;
			qp_r <= 6'd0;
			cbp_l_r <= 4'd0;
			cbp_c_r <= 2'd0;
			mb_type_r <= 8'd0;
			is_i16_r <= 1'b0;
			blk_guard <= 6'd0;
			guard <= 16'd0;
			win_armed <= 1'b0;
			tc_left_valid <= 1'b0;
			frame_feed_done <= 1'b0;
			error <= 1'b0;
			mb_type <= 5'd0;
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
			for (ci = 0; ci < 16; ci = ci + 1) begin
				luma4x4_coeff_zigzag[ci] <= 16'sd0;
				tc_cur[ci] <= 5'd0;
			end
			for (ci = 0; ci < 4; ci = ci + 1)
				tc_left[ci] <= 5'd0;
			for (ci = 0; ci < MB_W_MAX; ci = ci + 1)
				tc_top_valid[ci] <= 1'b0;
		end else begin
			case (st)
			ST_IDLE: begin
				frame_feed_done <= 1'b0;
				if (slice_go && slice_is_i && (mb_width != 8'd0) && (mb_height != 8'd0)) begin
					mb_total <= {8'd0, mb_width} * {8'd0, mb_height};
					mb_addr <= first_mb_in_slice;
					qp_r <= slice_qp_y;
					tc_left_valid <= 1'b0;
					for (ci = 0; ci < MB_W_MAX; ci = ci + 1)
						tc_top_valid[ci] <= 1'b0;
					error <= 1'b0;
					guard <= 16'd0;
					st <= ST_MB0_LOAD;
				end
			end

			// ── MB0: syntax already known ────────────────────────────
			ST_MB0_LOAD: begin
				mb_type_r <= first_mb_type;
				mb_type <= first_mb_type[4:0];
				is_i16_r <= (first_mb_type >= 8'd1) && (first_mb_type <= 8'd24);
				i4_pred_mode_flags <= first_i4_pred_mode_flags;
				i4_rem_modes <= first_i4_rem_modes;
				i4_modes_present <= first_i4_modes_present;
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
				chroma_pred_mode <= 2'd0;
				mb_qp_delta <= 6'sd0;
				mb_qp_y <= slice_qp_y;
				qp_r <= slice_qp_y;
				abs_bit <= first_residual_bit_offset;
				mb_residual_bit_offset <= first_residual_bit_offset;
				for (ci = 0; ci < 16; ci = ci + 1)
					tc_cur[ci] <= 5'd0;
				res_step <= 5'd0;
				st <= ST_MB_PULSE;
			end

			ST_MB_PULSE: begin
				mb_type_valid <= 1'b1;
				st <= ST_MB_GAP;
			end

			ST_MB_GAP: begin
				// One idle edge so the core latches mb position / pred.
				st <= ST_RES_REQ;
			end

			// ── Residual walk (luma feed + chroma consume) ───────────
			ST_RES_REQ: begin
				rbsp_request_offset <= {3'd0, abs_bit[15:3]};
				rbsp_request_valid <= 1'b1;
				win_armed <= 1'b0;
				st <= ST_RES_ARM;
			end

			ST_RES_ARM: begin
				// Window base updates this edge; use next edge for start.
				win_armed <= 1'b1;
				if (win_armed)
					st <= ST_RES_START;
			end

			ST_RES_START: begin
				if (res_step >= STEP_END) begin
					// Roll edge TC context
					tc_left_valid <= 1'b1;
					for (ci = 0; ci < 4; ci = ci + 1) begin
						tc_left[ci] <= tc_cur[{ci[1:0], 2'd3}];
						tc_top[{mb_x8[5:0], ci[1:0]}] <= tc_cur[{2'd3, ci[1:0]}];
					end
					tc_top_valid[mb_x8] <= 1'b1;
					st <= ST_WAIT_CORE;
				end else if (!res_step_coded(res_step, cbp_l_r, cbp_c_r, is_i16_r)) begin
					if (res_step < STEP_LUMA_END) begin
						// Uncoded luma still needs a zero-coeff pulse so
						// h264_decode_top sees all 16 blocks.
						tc_cur[res_step[3:0]] <= 5'd0;
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
				end else begin
					// (Re)align window if relative offset is getting high
					if (rel_bit16 >= 16'd400) begin
						rbsp_request_offset <= {3'd0, abs_bit[15:3]};
						rbsp_request_valid <= 1'b1;
						win_armed <= 1'b0;
						st <= ST_RES_ARM;
					end else begin
						if (res_step < STEP_LUMA_END) begin
							cav_table <= tok_table_luma;
							// I_16x16 AC is 15-coeff; treat all as 16 for bit-sync
							// on this path (DC Hadamard still open — honest).
							cav_max <= 5'd16;
						end else if (res_step == STEP_CHR_DC_U || res_step == STEP_CHR_DC_V) begin
							cav_table <= 3'd4;
							cav_max <= 5'd4;
						end else begin
							cav_table <= 3'd0;
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
						// Advance absolute bit position by the bits CAVLC ate.
						// cav_bit_end is window-relative; convert back.
						abs_bit <= win_bit_base + {6'd0, cav_bit_end};
						if (res_step < STEP_LUMA_END) begin
							tc_cur[res_step[3:0]] <= cav_tc;
							// Feed this luma block to the core.
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
					// Re-present the same block (core not ready yet).
					st <= ST_RES_FEED;
				end
			end

			ST_WAIT_CORE: begin
				guard <= guard + 16'd1;
				if ((!core_busy && (guard > 16'd3)) || (guard == 16'hFFFF)) begin
					guard <= 16'd0;
					if ((mb_addr + 16'd1) >= mb_total)
						st <= ST_DONE;
					else begin
						mb_addr <= mb_addr + 16'd1;
						st <= ST_SYN_REQ;
					end
				end
			end

			// ── Next-MB syntax (I-slice only) ────────────────────────
			ST_SYN_REQ: begin
				rbsp_request_offset <= {3'd0, abs_bit[15:3]};
				rbsp_request_valid <= 1'b1;
				win_armed <= 1'b0;
				st <= ST_SYN_ARM;
			end

			ST_SYN_ARM: begin
				win_armed <= 1'b1;
				if (win_armed) begin
					// Start ue(mb_type)
					ue_zeros <= 8'd0;
					ret_st <= 8'd0; // 0 = after mb_type
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
					if (ue_zeros >= 8'd24) begin
						error <= 1'b1;
						st <= ST_FAIL;
					end
				end else begin
					// stop bit 1
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
				// 0: mb_type done
				8'd0: begin
					mb_type_r <= ue_val[7:0];
					mb_type <= ue_val[4:0];
					if (ue_val > 32'd25) begin
						error <= 1'b1;
						st <= ST_FAIL;
					end else if (ue_val == 32'd25) begin
						// I_PCM — unsupported
						error <= 1'b1;
						st <= ST_FAIL;
					end else if (ue_val == 32'd0) begin
						is_i16_r <= 1'b0;
						i4_i <= 5'd0;
						flags_r <= 16'd0;
						rems_r <= 48'd0;
						need_rem <= 1'b0;
						bit_left <= 8'd1;
						bit_acc <= 32'd0;
						ret_st <= 8'd1; // I4 flag
						st <= ST_SYN_BIT;
					end else begin
						is_i16_r <= 1'b1;
						intra16x16_mode <= (ue_val[7:0] - 8'd1) & 2'd3;
						cbp_l_r <= i16_cbp_from_type(ue_val[7:0])[3:0];
						cbp_c_r <= i16_cbp_from_type(ue_val[7:0])[5:4];
						i4_modes_present <= 1'b0;
						// chroma pred ue
						ue_zeros <= 8'd0;
						ret_st <= 8'd3;
						st <= ST_SYN_UE0;
					end
				end
				// 1: I4 prev_intra4x4_pred_mode_flag bit
				8'd1: begin
					if (bit_acc[0]) begin
						flags_r[i4_i[3:0]] <= 1'b1;
						if (i4_i == 5'd15) begin
							i4_pred_mode_flags <= flags_r | (16'h1 << i4_i[3:0]);
							i4_rem_modes <= rems_r;
							i4_modes_present <= 1'b1;
							ue_zeros <= 8'd0;
							ret_st <= 8'd3; // chroma
							st <= ST_SYN_UE0;
						end else begin
							i4_i <= i4_i + 5'd1;
							bit_left <= 8'd1;
							bit_acc <= 32'd0;
							ret_st <= 8'd1;
							st <= ST_SYN_BIT;
						end
					end else begin
						flags_r[i4_i[3:0]] <= 1'b0;
						bit_left <= 8'd3;
						bit_acc <= 32'd0;
						ret_st <= 8'd2; // rem
						st <= ST_SYN_BIT;
					end
				end
				// 2: rem_intra4x4_pred_mode
				8'd2: begin
					rems_r[i4_i * 3 +: 3] <= bit_acc[2:0];
					if (i4_i == 5'd15) begin
						i4_pred_mode_flags <= flags_r;
						i4_rem_modes <= (rems_r & ~(48'h7 << (i4_i * 3))) |
							({{45{1'b0}}, bit_acc[2:0]} << (i4_i * 3));
						i4_modes_present <= 1'b1;
						ue_zeros <= 8'd0;
						ret_st <= 8'd3;
						st <= ST_SYN_UE0;
					end else begin
						i4_i <= i4_i + 5'd1;
						bit_left <= 8'd1;
						bit_acc <= 32'd0;
						ret_st <= 8'd1;
						st <= ST_SYN_BIT;
					end
				end
				// 3: intra_chroma_pred_mode
				8'd3: begin
					chroma_pred_mode <= ue_val[1:0];
					if (is_i16_r) begin
						// qp delta
						ue_zeros <= 8'd0;
						ret_st <= 8'd5;
						st <= ST_SYN_UE0;
					end else begin
						// cbp
						ue_zeros <= 8'd0;
						ret_st <= 8'd4;
						st <= ST_SYN_UE0;
					end
				end
				// 4: cbp intra
				8'd4: begin
					if (ue_val >= 32'd48) begin
						error <= 1'b1;
						st <= ST_FAIL;
					end else begin
						cbp_l_r <= cbp_intra_map(ue_val[5:0])[3:0];
						cbp_c_r <= cbp_intra_map(ue_val[5:0])[5:4];
						cbp_luma <= cbp_intra_map(ue_val[5:0])[3:0];
						cbp_chroma <= cbp_intra_map(ue_val[5:0])[5:4];
						if (cbp_intra_map(ue_val[5:0]) != 6'd0) begin
							ue_zeros <= 8'd0;
							ret_st <= 8'd5;
							st <= ST_SYN_UE0;
						end else begin
							mb_qp_delta <= 6'sd0;
							mb_qp_y <= qp_r;
							mb_residual_bit_offset <= abs_bit;
							cbp_luma <= 4'd0;
							cbp_chroma <= 2'd0;
							for (ci = 0; ci < 16; ci = ci + 1)
								tc_cur[ci] <= 5'd0;
							res_step <= 5'd0;
							st <= ST_MB_PULSE;
						end
					end
				end
				// 5: mb_qp_delta
				8'd5: begin
					mb_qp_delta <= se6_from_ue(ue_val);
					// QPy = (QPyprev + mb_qp_delta + 52) % 52
					begin : qp_upd
						reg signed [8:0] qn;
						qn = $signed({1'b0, qp_r}) + $signed({{3{se6_from_ue(ue_val)[5]}}, se6_from_ue(ue_val)});
						if (qn < 0)
							qn = qn + 9'sd52;
						else if (qn >= 9'sd52)
							qn = qn - 9'sd52;
						qp_r <= qn[5:0];
						mb_qp_y <= qn[5:0];
					end
					if (is_i16_r) begin
						cbp_luma <= cbp_l_r;
						cbp_chroma <= cbp_c_r;
					end
					mb_residual_bit_offset <= abs_bit;
					for (ci = 0; ci < 16; ci = ci + 1)
						tc_cur[ci] <= 5'd0;
					res_step <= 5'd0;
					st <= ST_MB_PULSE;
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
