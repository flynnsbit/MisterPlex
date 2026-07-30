// h264_p_mb_traverse — full P/I-slice macroblock raster walker.
//
// Owns all-MB traversal: repeated mb_skip_run (P only), per-MB mode parse,
// raster advance, slice termination. P_Skip emits one MB event per skipped
// address (not a no-op). Residual bits of coded MBs are consumed via product
// h264_cavlc_residual_block so the next mb_skip_run/mb_type stays aligned.
//
// I/IDR slices (slice_type 2/7): no mb_skip_run; I mb_type numbering
// (0=I_NxN, 1..24=I_16x16, 25=PCM). Residual block coeffs are exported on
// res_blk_* for the I-slice recon sink (pred+IQ/IDCT+store).
//
// Interaction: does NOT own MVD reconstruction quality (sv-mvd), residual-add
// (sv-resadd), or real ref pictures (sv-ref). Emits per-MB syntax events;
// consumers attach MV/residual/ref independently. Zero-MVD MC remains valid for
// P_Skip when MVP=0.
//
// Scaffold evidence (pre-fix): slice_hdr_parser ST_MBT/ST_P_MBT → ST_DONE after
// the first P MB only (first_mb_* ports). That is by design, not a mid-loop bug.
//
// Area (cycle-iterative): RBSP access RESTRUCTURED (not attribute-only — Quartus
// left prior ramstyle uninferred). Single-port h264_byte_ram_sp: one raddr/cycle,
// registered q; bit engine uses that byte; ST_RES_WIN_LOAD serial 64B (kills the
// 8k:1/16k:1 res_win mux bomb, map2d 1,180,271 comb ALUTs self). Target <=3000 ALMs.
// Docs: docs/cycle-iterative-traverse-area.md. Units: map number is comb ALUTs.

`default_nettype none

module h264_p_mb_traverse #(
	parameter int MAX_RBSP_BYTES = 8192,
	parameter bit FAULT_BAD_SKIP_RUN = 1'b0,     // mutation: treat skip_run as 0
	parameter bit FAULT_DROP_LAST_ROW_MB = 1'b0, // mutation: drop last MB of each row
	parameter bit FAULT_NO_QP_WRAP = 1'b0,       // mutation: skip QP_Y mod-52 (4× residual)
	parameter bit FAULT_SKIP_WIN_LOAD = 1'b0,    // mutation: skip serial RBSP→res_win (area twin)
	parameter bit FAULT_SKIP_TC_TOP_NB = 1'b0    // mutation: zero top-row nC/mode edge cache
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        clear,

	// RBSP byte stream (EPB already stripped by nalu_scanner)
	input  wire        in_valid,
	input  wire [7:0]  in_byte,
	input  wire        in_last,
	output wire        in_ready,

	// Geometry / slice context (from SPS/PPS; header parsed from RBSP)
	input  wire        start,              // pulse: begin walk on closed RBSP
	input  wire [7:0]  mb_width,
	input  wire [7:0]  mb_height,
	input  wire [4:0]  log2_max_frame_num,
	input  wire [2:0]  poc_type,
	input  wire        is_idr_nal,
	input  wire        nal_ref_idc_nonzero,
	input  wire        pps_deblock_ctrl,
	input  wire signed [7:0] pps_pic_init_qp,
	input  wire [2:0]  num_ref_idx_l0_active_minus1,

	// Per-MB event stream (ready/valid). When mb_valid && !mb_ready, walker stalls.
	output reg         mb_valid,
	input  wire        mb_ready,
	output reg  [15:0] mb_addr,
	output reg  [7:0]  mb_x,
	output reg  [7:0]  mb_y,
	output reg         mb_skip,
	output reg  [7:0]  mb_type,
	output reg  [2:0]  part_mode,          // 0=16x16 1=16x8 2=8x16 3=8x8 4=sub 7=intra
	output reg  [2:0]  part_count,
	output reg         uses_sub_mb,
	output reg         is_intra,
	output reg  [5:0]  cbp,
	output reg signed [7:0] mb_qp,
	output reg  [15:0] residual_bit_offset,

	// Per-block residual export (CAVLC levels, scan order). Handshake:
	// when res_blk_valid && !res_blk_ready the walker stalls in ST_RES_HOLD.
	output reg         res_blk_valid,
	input  wire        res_blk_ready,
	output reg  [15:0] res_blk_mb_addr,
	output reg  [7:0]  res_blk_mb_x,
	output reg  [7:0]  res_blk_mb_y,
	output reg  [4:0]  res_blk_idx,        // schedule index (I16:0=DC,1..16=AC)
	output reg         res_blk_is_i16,
	output reg         res_blk_is_luma,    // 1 = luma DC/AC 4x4; 0 = chroma (deferred)
	output reg  [5:0]  res_blk_qp,
	output reg  [4:0]  res_blk_max_coeff,  // 16 / 15 / 4
	output reg signed [15:0] res_blk_coeff [0:15],
	// Intra pred mode for this block (I4: 0..8; I16 DC slot carries 0..3).
	// Sink uses one shared 4x4 pred unit per cycle (area-safe).
	output reg  [3:0]  res_blk_pred_mode,
	output reg         res_mb_end,         // pulse: residual schedule done for MB
	output reg  [15:0] res_mb_end_addr,

	output reg  [15:0] mb_count,           // MBs emitted this slice
	output reg         slice_done,         // pulse: walk finished
	output reg         busy,
	output reg         error,
	output reg         unsupported
);
	localparam int MAX_BITS = MAX_RBSP_BYTES * 8;
	localparam [2:0]
		PART_P16x16 = 3'd0,
		PART_P16x8  = 3'd1,
		PART_P8x16  = 3'd2,
		PART_P8x8   = 3'd3,
		PART_SUB    = 3'd4,
		PART_INTRA  = 3'd7;

	localparam [7:0]
		ST_IDLE           = 8'd0,
		ST_BITS           = 8'd1,
		ST_UE_ZERO        = 8'd2,
		ST_UE_SUFFIX      = 8'd3,
		ST_HDR_FIRST      = 8'd4,
		ST_HDR_TYPE       = 8'd5,
		ST_HDR_PPS        = 8'd6,
		ST_HDR_FRAME      = 8'd7,
		ST_HDR_IDR        = 8'd8,
		ST_HDR_REFIDX_F   = 8'd9,
		ST_HDR_REFIDX_L0  = 8'd10,
		ST_HDR_LISTMOD_F  = 8'd11,  // ref_pic_list_modification_flag_l0
		ST_HDR_LISTMOD_IDC = 8'd12, // modification_of_pic_nums_idc loop
		ST_HDR_REFMARK    = 8'd13,
		ST_HDR_QPD_PRE    = 8'd14,
		ST_HDR_QPD        = 8'd15,
		ST_HDR_DIDC       = 8'd16,
		ST_HDR_ALPHA      = 8'd17,
		ST_HDR_BETA       = 8'd18,
		ST_START          = 8'd19,
		ST_SKIP_UE        = 8'd20,
		ST_SKIP_EMIT      = 8'd21,
		ST_TYPE_UE        = 8'd22,
		ST_TYPE           = 8'd23,
		ST_SUB_UE         = 8'd24,
		ST_MVD_X          = 8'd25,
		ST_MVD_Y          = 8'd26,
		ST_MVD_PAIR_DONE  = 8'd27,
		ST_CBP_UE         = 8'd28,
		ST_CBP            = 8'd29,
		ST_QP_UE          = 8'd30,
		ST_EMIT_CODED     = 8'd31,
		ST_RES_SETUP      = 8'd32,
		ST_RES_WAIT       = 8'd33,
		ST_NEXT_MB        = 8'd34,
		ST_DONE           = 8'd35,
		ST_FAIL           = 8'd36,
		ST_I4_FLAG        = 8'd37,
		ST_I4_REM         = 8'd38,
		ST_CHR_UE         = 8'd39,
		ST_CBP_INTRA_UE   = 8'd40,
		ST_HDR_LISTMOD_ARG = 8'd41, // abs_diff_pic_num / long_term_pic_num
		ST_RES_HOLD       = 8'd42, // stall until residual consumer ACKs
		ST_RES_MB_END     = 8'd43, // pulse res_mb_end then NEXT_MB
		ST_RES_WIN_LOAD   = 8'd44, // serial 64B RBSP→res_win (M10K, 1B/cyc)
		ST_INIT_XY        = 8'd45, // first_mb → curr_x/y counters (no / %)
		ST_NB_RAM_CLR     = 8'd46, // serial clear tc/mode top M10K at slice start
		ST_EDGE_LOAD      = 8'd47, // serial load 4 tc + 4 i4 modes for curr MB
		ST_EDGE_STORE     = 8'd48, // serial write bottom-edge tc/mode to M10K
		ST_I4_GO          = 8'd49, // after edge load: start_bits → ST_I4_FLAG
		ST_I16_GO         = 8'd50; // after edge load: start_ue → ST_CHR_UE

	// ---- RBSP bitstream buffer (ACCESS RESTRUCTURE, not attribute-only) ----
	// map2d root cause was 64 parallel dynamic reads of 8KB rbsp → 8k:1/16k:1
	// mux trees (~1.18M comb ALUTs). Attributes on the old array were already
	// tried and left uninferred. Fix = one registered read port per cycle via
	// h264_byte_ram_sp + serial ST_RES_WIN_LOAD (see cycle-iterative-traverse-area).
	localparam int RBSP_AW = (MAX_RBSP_BYTES <= 1) ? 1 : $clog2(MAX_RBSP_BYTES);
	wire [7:0] rbsp_q;
	reg [RBSP_AW-1:0] rbsp_raddr;
	reg [RBSP_AW-1:0] rbsp_ra_d1;
	reg        rbsp_we;
	reg [RBSP_AW-1:0] rbsp_waddr;
	reg [7:0]  rbsp_wdata;
	reg [15:0] rbsp_len;
	// Must hold MAX_RBSP_BYTES*8 (16384*8=131072 → 18 bits). 16-bit bit_pos
	// wrapped at 65536 and ended the 624x480 IDR walk at ~250/1170 MBs.
	reg [17:0] bit_pos;
	wire [31:0] rbsp_bit_total = {16'd0, rbsp_len} << 3;
	// Registered current parse byte (no combo index into RBSP storage).
	reg [7:0]  bit_byte;
	reg [RBSP_AW-1:0] bit_byte_addr;
	reg        bit_byte_v;
	wire [RBSP_AW-1:0] bit_need_addr = bit_pos[3 +: RBSP_AW];
	wire        bit_from_q = (rbsp_ra_d1 == bit_need_addr);
	wire        bit_ready = (bit_byte_v && (bit_byte_addr == bit_need_addr)) || bit_from_q;
	wire        cur_bit = (bit_byte_v && (bit_byte_addr == bit_need_addr))
		? bit_byte[3'd7 - bit_pos[2:0]]
		: rbsp_q[3'd7 - bit_pos[2:0]];
	// Serial residual window load (one byte/cycle from rbsp_q)
	reg [RBSP_AW-1:0] win_base;
	reg [7:0]  win_k;

	h264_byte_ram_sp #(.DEPTH(MAX_RBSP_BYTES), .AW(RBSP_AW)) u_rbsp_ram (
		.clk(clk),
		.we(rbsp_we),
		.waddr(rbsp_waddr),
		.wdata(rbsp_wdata),
		.raddr(rbsp_raddr),
		.q(rbsp_q)
	);
	reg [7:0] st, ret_st;
	reg [7:0] fixed_left;
	reg [31:0] fixed_acc;
	reg [7:0] ue_zero, ue_suffix_left;
	reg [31:0] ue_suffix, ue_value;

	reg [15:0] curr_mb;
	reg [15:0] pic_mbs;
	reg [15:0] skip_left;
	reg [15:0] skip_run_lat;
	reg [7:0] mvd_pairs_left;
	reg [2:0] sub_idx;
	reg [5:0] cbp_r;
	reg signed [7:0] qp_r;
	reg [7:0] mb_type_r;
	reg [2:0] part_mode_r;
	reg [2:0] part_count_r;
	reg uses_sub_r;
	reg is_intra_r;
	reg is_i16_r;              // I_16x16: luma DC first, AC max=15
	reg is_i_slice_r;          // slice_type 2 or 7 (I/SI all-I coding)
	reg [4:0] i4_idx;
	reg [1:0] i16_mode_r;      // I_16x16 pred mode 0..3 from mb_type
	// I4 modes in residual/scan order index 0..15 (same as blk4_x/y).
	// Also spatial maps for MPM: mode_spat[by*4+bx].
	reg [3:0] i4_mode_scan [0:15];
	reg [3:0] i4_mode_spat [0:15];
	reg       i4_mode_spat_v [0:15]; // valid for MPM within MB
	// Left MB right-edge modes (4 rows). Top-row modes live in M10K + edge cache.
	reg [3:0] i4_mode_left [0:3];
	reg       i4_mode_left_v [0:3];
	// Edge cache: top-row i4 modes for curr_mb_x*4 + 0..3 (loaded ST_EDGE_LOAD)
	reg [3:0] i4_mode_top_e [0:3];
	reg       i4_mode_top_e_v [0:3];
	reg [7:0] slice_type_r;
	// Residual export hold (copy of last CAVLC result while waiting ready)
	reg [4:0] res_hold_idx;
	reg       res_hold_is_i16;
	reg       res_hold_is_luma;
	reg       res_hold_from_cavlc; // 0 = zero-export (no bit_pos/tc update)
	reg [5:0] res_hold_qp;
	reg [4:0] res_hold_max;
	reg signed [15:0] res_hold_coeff [0:15];
	reg [15:0] res_hold_mb;
	reg [7:0]  res_hold_x, res_hold_y;
	reg [15:0] first_mb_r;
	reg [4:0] log2_fn_r;
	reg db_lat;
	reg idr_lat;
	reg nal_ref_lat;
	reg signed [7:0] init_qp_r;

	// Residual block schedule
	reg [4:0] res_block_i;       // 0..15 luma, 16..17 chroma DC, 18..25 chroma AC
	reg [4:0] res_blocks_total;
	reg [3:0] res_luma_mask;     // which 8x8 luma groups coded
	reg [1:0] res_chroma;        // 0 none, 1 DC, 2 DC+AC
	reg [17:0] res_win_bit0;     // absolute bit pos of window base (byte-aligned)
	reg [7:0] res_win [0:63];
	reg       cavlc_start_r;

	// nC neighbour total_coeff — phase-2 area:
	// picture top-row in M10K (h264_byte_ram_sp); within-MB spat + 4-entry edge cache.
	// Kills 256-deep fabric arrays + combo nC mux (prior traverse self 7079 ALUT MISS).
	localparam int MAX_MB_W = 64;
	localparam int NB_TOP_N = MAX_MB_W * 4; // 256
	localparam int NB_AW = $clog2(NB_TOP_N);
	reg [4:0] tc_spat [0:15];
	reg       tc_spat_v [0:15];
	reg [4:0] tc_top_e [0:3];
	reg       tc_top_e_v [0:3];
	reg [4:0] tc_left [0:3];
	reg       tc_left_v [0:3];
	// tc_top M10K: byte pack {2'b0, v, tc[4:0]}
	reg               tc_ram_we;
	reg [NB_AW-1:0]   tc_ram_waddr;
	reg [7:0]         tc_ram_wdata;
	reg [NB_AW-1:0]   tc_ram_raddr;
	wire [7:0]        tc_ram_q;
	// i4_mode_top M10K: byte pack {3'b0, v, mode[3:0]}
	reg               im_ram_we;
	reg [NB_AW-1:0]   im_ram_waddr;
	reg [7:0]         im_ram_wdata;
	reg [NB_AW-1:0]   im_ram_raddr;
	wire [7:0]        im_ram_q;
	h264_byte_ram_sp #(.DEPTH(NB_TOP_N), .AW(NB_AW)) u_tc_top_ram (
		.clk(clk), .we(tc_ram_we), .waddr(tc_ram_waddr), .wdata(tc_ram_wdata),
		.raddr(tc_ram_raddr), .q(tc_ram_q)
	);
	h264_byte_ram_sp #(.DEPTH(NB_TOP_N), .AW(NB_AW)) u_i4_mode_top_ram (
		.clk(clk), .we(im_ram_we), .waddr(im_ram_waddr), .wdata(im_ram_wdata),
		.raddr(im_ram_raddr), .q(im_ram_q)
	);
	// Edge preload/store FSM helpers
	reg [3:0]  nb_k;
	reg [8:0]  nb_clr_i; // 0..256 clear index
	reg [1:0]  nb_rd_ph; // 0 issue 1 wait 2 capt
	reg [7:0]  edge_next_st;
	reg [3:0]  store_mode; // 0=i4 edge commit 1=tc zero-4 2=unused 3=clr both
	// Chroma AC nC: still fabric (2×128); secondary to luma top/mode gate.
	reg [4:0] tc_chr_top [0:1][0:MAX_MB_W*2-1];
	reg       tc_chr_top_v [0:1][0:MAX_MB_W*2-1];
	reg [4:0] tc_chr_left [0:1][0:1];
	reg       tc_chr_left_v [0:1][0:1];

	wire [15:0] mb_w16 = (mb_width == 8'd0) ? 16'd20 : {8'd0, mb_width};
	wire [15:0] mb_h16 = (mb_height == 8'd0) ? 16'd15 : {8'd0, mb_height};
	wire [31:0] pic_mbs32 = {16'd0, mb_w16} * {16'd0, mb_h16};
	// Explicit MB x/y counters (no runtime / or % per reference).
	reg [7:0] curr_x_r, curr_y_r;
	reg [15:0] xy_rem;
	wire [15:0] curr_x = {8'd0, curr_x_r};
	wire [15:0] curr_y = {8'd0, curr_y_r};
	wire        drop_this_mb = FAULT_DROP_LAST_ROW_MB && (curr_x == (mb_w16 - 16'd1));

	assign in_ready = !busy && (rbsp_len < MAX_RBSP_BYTES[15:0]);

	// Track prior raddr for bit_ready (1-cycle registered RAM latency).
	always @(posedge clk) begin
		rbsp_ra_d1 <= rbsp_raddr;
	end

	function automatic signed [7:0] se8_from_ue;
		input [31:0] code;
		reg signed [31:0] tmp;
		begin
			if (code[0])
				tmp = $signed({1'b0, code[31:1]}) + 32'sd1;
			else
				tmp = -$signed({1'b0, code[31:1]});
			se8_from_ue = tmp[7:0];
		end
	endfunction

	// H.264 8.5.1 / host wrapQpY: QP_Y += mb_qp_delta modulo 52 (8-bit).
	// Clamping negatives to 0 is wrong: after rate-control wrap, qp can go
	// negative in the running sum and must map e.g. 1+(-22)=-21 → 31.
	// Without this, qp_r[5:0] turns -21 into 43 (=gold+12) → qdiv+2 → 4× residual.
	function automatic signed [7:0] wrap_qp_y;
		input signed [7:0] qpy;
		input signed [7:0] delta;
		reg signed [15:0] v;
		begin
			if (FAULT_NO_QP_WRAP) begin
				v = qpy + delta;
				wrap_qp_y = v[7:0];
			end else begin
				v = qpy + delta;
				v = v % 16'sd52; // toward-zero (Verilator/C++11)
				if (v < 0)
					v = v + 16'sd52;
				wrap_qp_y = v[7:0];
			end
		end
	endfunction

	// Slice header slice_qp_delta: host clamps to 0..51 (not mod-52).
	function automatic signed [7:0] clamp_qp_y;
		input signed [7:0] qpy;
		input signed [7:0] delta;
		reg signed [15:0] v;
		begin
			v = qpy + delta;
			if (v < 0)
				v = 0;
			if (v > 51)
				v = 16'sd51;
			clamp_qp_y = v[7:0];
		end
	endfunction

	function automatic [5:0] cbp_inter_map;
		input [5:0] code;
		begin
			case (code)
			6'd0: cbp_inter_map = 6'd0; 6'd1: cbp_inter_map = 6'd16; 6'd2: cbp_inter_map = 6'd1; 6'd3: cbp_inter_map = 6'd2;
			6'd4: cbp_inter_map = 6'd4; 6'd5: cbp_inter_map = 6'd8; 6'd6: cbp_inter_map = 6'd32; 6'd7: cbp_inter_map = 6'd3;
			6'd8: cbp_inter_map = 6'd5; 6'd9: cbp_inter_map = 6'd10; 6'd10: cbp_inter_map = 6'd12; 6'd11: cbp_inter_map = 6'd15;
			6'd12: cbp_inter_map = 6'd47; 6'd13: cbp_inter_map = 6'd7; 6'd14: cbp_inter_map = 6'd11; 6'd15: cbp_inter_map = 6'd13;
			6'd16: cbp_inter_map = 6'd14; 6'd17: cbp_inter_map = 6'd6; 6'd18: cbp_inter_map = 6'd9; 6'd19: cbp_inter_map = 6'd31;
			6'd20: cbp_inter_map = 6'd35; 6'd21: cbp_inter_map = 6'd37; 6'd22: cbp_inter_map = 6'd42; 6'd23: cbp_inter_map = 6'd44;
			6'd24: cbp_inter_map = 6'd33; 6'd25: cbp_inter_map = 6'd34; 6'd26: cbp_inter_map = 6'd36; 6'd27: cbp_inter_map = 6'd40;
			6'd28: cbp_inter_map = 6'd39; 6'd29: cbp_inter_map = 6'd43; 6'd30: cbp_inter_map = 6'd45; 6'd31: cbp_inter_map = 6'd46;
			6'd32: cbp_inter_map = 6'd17; 6'd33: cbp_inter_map = 6'd18; 6'd34: cbp_inter_map = 6'd20; 6'd35: cbp_inter_map = 6'd24;
			6'd36: cbp_inter_map = 6'd19; 6'd37: cbp_inter_map = 6'd21; 6'd38: cbp_inter_map = 6'd26; 6'd39: cbp_inter_map = 6'd28;
			6'd40: cbp_inter_map = 6'd23; 6'd41: cbp_inter_map = 6'd27; 6'd42: cbp_inter_map = 6'd29; 6'd43: cbp_inter_map = 6'd30;
			6'd44: cbp_inter_map = 6'd22; 6'd45: cbp_inter_map = 6'd25; 6'd46: cbp_inter_map = 6'd38; 6'd47: cbp_inter_map = 6'd41;
			default: cbp_inter_map = 6'd0;
			endcase
		end
	endfunction

	function automatic [5:0] cbp_intra_map;
		input [5:0] code;
		begin
			case (code)
			6'd0: cbp_intra_map = 6'd47; 6'd1: cbp_intra_map = 6'd31; 6'd2: cbp_intra_map = 6'd15; 6'd3: cbp_intra_map = 6'd0;
			6'd4: cbp_intra_map = 6'd23; 6'd5: cbp_intra_map = 6'd27; 6'd6: cbp_intra_map = 6'd29; 6'd7: cbp_intra_map = 6'd30;
			6'd8: cbp_intra_map = 6'd7; 6'd9: cbp_intra_map = 6'd11; 6'd10: cbp_intra_map = 6'd13; 6'd11: cbp_intra_map = 6'd14;
			6'd12: cbp_intra_map = 6'd39; 6'd13: cbp_intra_map = 6'd43; 6'd14: cbp_intra_map = 6'd45; 6'd15: cbp_intra_map = 6'd46;
			6'd16: cbp_intra_map = 6'd16; 6'd17: cbp_intra_map = 6'd3; 6'd18: cbp_intra_map = 6'd5; 6'd19: cbp_intra_map = 6'd10;
			6'd20: cbp_intra_map = 6'd12; 6'd21: cbp_intra_map = 6'd19; 6'd22: cbp_intra_map = 6'd21; 6'd23: cbp_intra_map = 6'd26;
			6'd24: cbp_intra_map = 6'd28; 6'd25: cbp_intra_map = 6'd35; 6'd26: cbp_intra_map = 6'd37; 6'd27: cbp_intra_map = 6'd42;
			6'd28: cbp_intra_map = 6'd44; 6'd29: cbp_intra_map = 6'd1; 6'd30: cbp_intra_map = 6'd2; 6'd31: cbp_intra_map = 6'd4;
			6'd32: cbp_intra_map = 6'd8; 6'd33: cbp_intra_map = 6'd17; 6'd34: cbp_intra_map = 6'd18; 6'd35: cbp_intra_map = 6'd20;
			6'd36: cbp_intra_map = 6'd24; 6'd37: cbp_intra_map = 6'd6; 6'd38: cbp_intra_map = 6'd9; 6'd39: cbp_intra_map = 6'd22;
			6'd40: cbp_intra_map = 6'd25; 6'd41: cbp_intra_map = 6'd32; 6'd42: cbp_intra_map = 6'd33; 6'd43: cbp_intra_map = 6'd34;
			6'd44: cbp_intra_map = 6'd36; 6'd45: cbp_intra_map = 6'd40; 6'd46: cbp_intra_map = 6'd38; 6'd47: cbp_intra_map = 6'd41;
			default: cbp_intra_map = 6'd0;
			endcase
		end
	endfunction

	function automatic [7:0] sub_mb_mvd_pairs;
		input [31:0] sub_type;
		begin
			case (sub_type[1:0])
			2'd0: sub_mb_mvd_pairs = 8'd1;
			2'd1: sub_mb_mvd_pairs = 8'd2;
			2'd2: sub_mb_mvd_pairs = 8'd2;
			default: sub_mb_mvd_pairs = 8'd4;
			endcase
		end
	endfunction

	function automatic [2:0] part_mode_of;
		input skipped;
		input [7:0] mt;
		begin
			if (skipped || mt == 8'd0) part_mode_of = PART_P16x16;
			else if (mt == 8'd1) part_mode_of = PART_P16x8;
			else if (mt == 8'd2) part_mode_of = PART_P8x16;
			else if (mt == 8'd3 || mt == 8'd4) part_mode_of = PART_P8x8;
			else part_mode_of = PART_INTRA;
		end
	endfunction

	function automatic [2:0] part_count_of;
		input skipped;
		input [7:0] mt;
		begin
			if (skipped || mt == 8'd0) part_count_of = 3'd1;
			else if (mt == 8'd1 || mt == 8'd2) part_count_of = 3'd2;
			else if (mt == 8'd3 || mt == 8'd4) part_count_of = 3'd4;
			else part_count_of = 3'd0;
		end
	endfunction

	// Luma 4x4 scan inside MB: block index 0..15 → (bx,by) in 4x4 units
	function automatic [1:0] blk4_x;
		input [3:0] i;
		begin
			// 0 1 4 5 / 2 3 6 7 / 8 9 12 13 / 10 11 14 15
			case (i)
			4'd0,4'd2,4'd8,4'd10: blk4_x = 2'd0;
			4'd1,4'd3,4'd9,4'd11: blk4_x = 2'd1;
			4'd4,4'd6,4'd12,4'd14: blk4_x = 2'd2;
			default: blk4_x = 2'd3;
			endcase
		end
	endfunction
	function automatic [1:0] blk4_y;
		input [3:0] i;
		begin
			case (i)
			4'd0,4'd1,4'd4,4'd5: blk4_y = 2'd0;
			4'd2,4'd3,4'd6,4'd7: blk4_y = 2'd1;
			4'd8,4'd9,4'd12,4'd13: blk4_y = 2'd2;
			default: blk4_y = 2'd3;
			endcase
		end
	endfunction

	function automatic [2:0] nc_table;
		input [5:0] nC;
		begin
			if ($signed({1'b0, nC}) < 0) // chroma DC uses table 4 via caller
				nc_table = 3'd4;
			else if (nC < 6'd2) nc_table = 3'd0;
			else if (nC < 6'd4) nc_table = 3'd1;
			else if (nC < 6'd8) nc_table = 3'd2;
			else nc_table = 3'd3;
		end
	endfunction

	// Intra4x4 MostProbableMode (ITU 8.3.1.1). scan_i uses residual order.
	function automatic [3:0] i4_mpm;
		input [3:0] scan_i;
		reg [1:0] bx, by;
		reg signed [4:0] modeA, modeB;
		reg [15:0] abs_x;
		begin
			bx = blk4_x(scan_i);
			by = blk4_y(scan_i);
			// Left
			if (bx != 2'd0) begin
				if (i4_mode_spat_v[{by, bx - 2'd1}])
					modeA = {1'b0, i4_mode_spat[{by, bx - 2'd1}]};
				else
					modeA = -5'sd1;
			end else if (curr_x != 16'd0 && i4_mode_left_v[by])
				modeA = {1'b0, i4_mode_left[by]};
			else
				modeA = -5'sd1;
			// Above — same-MB spat or preloaded top-edge cache (M10K)
			abs_x = {curr_x[13:0], 2'b00} + {14'd0, bx};
			if (by != 2'd0) begin
				if (i4_mode_spat_v[{by - 2'd1, bx}])
					modeB = {1'b0, i4_mode_spat[{by - 2'd1, bx}]};
				else
					modeB = -5'sd1;
			end else if (curr_y != 16'd0 && i4_mode_top_e_v[bx])
				modeB = {1'b0, i4_mode_top_e[bx]};
			else
				modeB = -5'sd1;
			if (modeA < 0 || modeB < 0)
				i4_mpm = 4'd2; // DC
			else if (modeA[3:0] < modeB[3:0])
				i4_mpm = modeA[3:0];
			else
				i4_mpm = modeB[3:0];
		end
	endfunction

	function automatic [3:0] i4_mode_from_rem;
		input [3:0] mpm;
		input [2:0] rem;
		reg [3:0] m;
		begin
			m = {1'b0, rem};
			if (m < mpm)
				i4_mode_from_rem = m;
			else
				i4_mode_from_rem = m + 4'd1;
		end
	endfunction

	// nC for luma 4x4 i inside current MB (edge cache + spat; no fabric tc_top[])
	function automatic [5:0] luma_nC;
		input [3:0] bi;
		reg [1:0] bx, by;
		reg avail_a, avail_b;
		reg [4:0] nA, nB;
		reg [5:0] sum;
		begin
			bx = blk4_x(bi);
			by = blk4_y(bi);
			avail_a = (bx != 2'd0) ? 1'b1 : (curr_x != 16'd0);
			avail_b = (by != 2'd0) ? 1'b1 : (curr_y != 16'd0);
			if (bx != 2'd0)
				nA = tc_left[by];
			else if (curr_x != 16'd0)
				nA = tc_left_v[by] ? tc_left[by] : 5'd0;
			else
				nA = 5'd0;
			if (by != 2'd0)
				nB = tc_spat_v[{by - 2'd1, bx}] ? tc_spat[{by - 2'd1, bx}] : 5'd0;
			else if (curr_y != 16'd0)
				nB = tc_top_e_v[bx] ? tc_top_e[bx] : 5'd0;
			else begin
				nB = 5'd0;
				avail_b = 1'b0;
			end
			if (!avail_a && !avail_b)
				luma_nC = 6'd0;
			else if (!avail_a)
				luma_nC = {1'b0, nB};
			else if (!avail_b)
				luma_nC = {1'b0, nA};
			else begin
				sum = {1'b0, nA} + {1'b0, nB};
				luma_nC = (sum + 6'd1) >> 1;
			end
		end
	endfunction

	// Chroma 2x2 block coords from scan index 0..3 (row-major)
	function automatic [0:0] chr_bx;
		input [1:0] bi;
		chr_bx = bi[0];
	endfunction
	function automatic [0:0] chr_by;
		input [1:0] bi;
		chr_by = bi[1];
	endfunction

	// nC for chroma AC plane p, block bi (0..3)
	function automatic [5:0] chroma_nC;
		input       p;
		input [1:0] bi;
		reg avail_a, avail_b;
		reg [4:0] nA, nB;
		reg [5:0] sum;
		reg [15:0] abs_x;
		reg bx, by;
		begin
			bx = chr_bx(bi);
			by = chr_by(bi);
			abs_x = {curr_x[14:0], 1'b0} + {15'd0, bx};
			avail_a = bx ? 1'b1 : (curr_x != 16'd0);
			avail_b = by ? 1'b1 : (curr_y != 16'd0);
			if (bx)
				nA = tc_chr_left[p][by];
			else if (curr_x != 16'd0)
				nA = tc_chr_left_v[p][by] ? tc_chr_left[p][by] : 5'd0;
			else
				nA = 5'd0;
			if (by)
				nB = (abs_x < MAX_MB_W*2 && tc_chr_top_v[p][abs_x]) ?
					tc_chr_top[p][abs_x] : 5'd0;
			else if (curr_y != 16'd0 && abs_x < MAX_MB_W*2)
				nB = tc_chr_top_v[p][abs_x] ? tc_chr_top[p][abs_x] : 5'd0;
			else
				nB = 5'd0;
			if (!avail_a && !avail_b)
				chroma_nC = 6'd0;
			else if (!avail_a)
				chroma_nC = {1'b0, nB};
			else if (!avail_b)
				chroma_nC = {1'b0, nA};
			else begin
				sum = {1'b0, nA} + {1'b0, nB};
				chroma_nC = (sum + 6'd1) >> 1;
			end
		end
	endfunction

	task automatic start_bits;
		input [7:0] nbits;
		input [7:0] next_st;
		begin
			fixed_left <= nbits;
			fixed_acc <= 32'd0;
			ret_st <= next_st;
			st <= ST_BITS;
		end
	endtask

	task automatic start_ue;
		input [7:0] next_st;
		begin
			ue_zero <= 8'd0;
			ue_suffix_left <= 8'd0;
			ue_suffix <= 32'd0;
			ue_value <= 32'd0;
			ret_st <= next_st;
			st <= ST_UE_ZERO;
		end
	endtask

	task automatic fail;
		begin
`ifdef VERILATOR
			$display("TRAV_FAIL_NOW mb=%0d st=%0d bit_pos=%0d rbsp_bits=%0d res_i=%0d i_slice=%0d i16=%0d cbp=%0h unsup=%0d",
				curr_mb, st, bit_pos, rbsp_bit_total, res_block_i,
				is_i_slice_r, is_i16_r, cbp_r, unsupported);
`endif
			// Retire immediately: prior pattern set busy=0 + ST_FAIL, but the
			// outer `else if (busy)` guard then skipped ST_FAIL forever.
			error <= 1'b1;
			busy <= 1'b0;
			slice_done <= 1'b1;
			st <= ST_IDLE;
		end
	endtask

	// Hold one outstanding MB beat until consumer takes it (mb_ready).
	reg mb_hold;
	task automatic emit_mb;
		input skipped;
		begin
			if (drop_this_mb) begin
				// mutation twin: pretend this MB never existed
			end else begin
				mb_valid <= 1'b1;
				mb_hold <= 1'b1;
				mb_addr <= curr_mb;
				mb_x <= curr_x[7:0];
				mb_y <= curr_y[7:0];
				mb_skip <= skipped;
				mb_type <= skipped ? 8'd0 : mb_type_r;
				part_mode <= skipped ? PART_P16x16 : part_mode_r;
				part_count <= skipped ? 3'd1 : part_count_r;
				uses_sub_mb <= skipped ? 1'b0 : uses_sub_r;
				is_intra <= skipped ? 1'b0 : is_intra_r;
				cbp <= skipped ? 6'd0 : cbp_r;
				mb_qp <= qp_r;
				residual_bit_offset <= bit_pos[15:0];
				mb_count <= mb_count + 16'd1;
			end
		end
	endtask

	// CAVLC residual consumer
	wire        cavlc_busy, cavlc_done, cavlc_ok;
	wire [9:0]  cavlc_bit_end;
	wire [4:0]  cavlc_tc;
	wire [1:0]  cavlc_t1;
	wire [3:0]  cavlc_tz;
	wire signed [15:0] cavlc_coeff [0:15];
	wire signed [15:0] cavlc_lev [0:15];
	wire [3:0]  cavlc_run [0:15];

	reg [2:0] cavlc_table_r;
	reg [4:0] cavlc_max_r;
	reg [9:0] cavlc_bit0_r;   // offset within 64 B window (0..511)
	reg [9:0] cavlc_bitlen_r;

	h264_cavlc_residual_block #(.MAX_BYTES(64)) u_cavlc (
		.clk(clk), .reset(reset | clear),
		.start(cavlc_start_r),
		.coeff_token_table(cavlc_table_r),
		.max_coeff(cavlc_max_r),
		.bit_offset_start(cavlc_bit0_r),
		.bit_len(cavlc_bitlen_r),
		.rbsp(res_win),
		.busy(cavlc_busy), .done(cavlc_done), .ok(cavlc_ok),
		.bit_offset_end(cavlc_bit_end),
		.total_coeff(cavlc_tc), .trailing_ones(cavlc_t1), .total_zeros(cavlc_tz),
		.coeff(cavlc_coeff), .level_dbg(cavlc_lev), .run_dbg(cavlc_run)
	);

	integer wi, ti;
	// load_res_window removed: ST_RES_WIN_LOAD copies 64B from M10K one/cycle.

	// Residual schedule:
	//  Inter / I_NxN: idx 0..15 luma 4x4 (max16), 16..17 chrDC, 18..25 chrAC
	//  I_16x16:       idx 0 = luma DC (max16), 1..16 = luma AC max15 if cbp_l,
	//                 17..18 chrDC, 19..26 chrAC
	function automatic bit res_slot_coded;
		input [4:0] idx;
		reg [1:0] g;
		reg [3:0] ac_i;
		begin
			if (is_i16_r) begin
				if (idx == 5'd0)
					res_slot_coded = 1'b1; // luma DC always
				else if (idx <= 5'd16) begin
					ac_i = idx[3:0] - 4'd1;
					// Quartus rejects part-select on function-call results.
					begin : ac_g_pack
						reg [1:0] by, bx;
						by = blk4_y(ac_i);
						bx = blk4_x(ac_i);
						g = {by[1], bx[1]};
					end
					res_slot_coded = |res_luma_mask; // cbp_l is 0 or 15
				end else if (idx <= 5'd18)
					res_slot_coded = (res_chroma != 2'd0);
				else
					res_slot_coded = (res_chroma == 2'd2);
			end else if (idx < 5'd16) begin
				begin : p_g_pack
					reg [1:0] by, bx;
					by = blk4_y(idx[3:0]);
					bx = blk4_x(idx[3:0]);
					g = {by[1], bx[1]};
				end
				res_slot_coded = res_luma_mask[g];
			end else if (idx < 5'd18) begin
				res_slot_coded = (res_chroma != 2'd0);
			end else begin
				res_slot_coded = (res_chroma == 2'd2);
			end
		end
	endfunction

	task automatic launch_cavlc_for_slot;
		input [4:0] idx;
		reg [5:0] nCv;
		reg [4:0] maxv;
		reg [17:0] abs_bit;
		reg [3:0] ac_i;
		reg [2:0] chr_i; // 0..7 across planes
		reg p;
		reg [1:0] bi;
		begin
			abs_bit = bit_pos;
			nCv = 6'd0;
			maxv = 5'd16;
			// Window filled later in ST_RES_WIN_LOAD (serial M10K read).
			res_win_bit0 <= {abs_bit[17:3], 3'b000};
			win_base <= abs_bit[3 +: RBSP_AW];
			win_k <= 8'd0;
			if (is_i16_r) begin
				if (idx == 5'd0) begin
					// I_16x16 DC nC from left/up MB edge (block 0 neighbours)
					nCv = luma_nC(4'd0);
					maxv = 5'd16;
					cavlc_table_r <= nc_table(nCv);
					cavlc_max_r <= maxv;
				end else if (idx <= 5'd16) begin
					ac_i = idx[3:0] - 4'd1;
					nCv = luma_nC(ac_i);
					maxv = 5'd15;
					cavlc_table_r <= nc_table(nCv);
					cavlc_max_r <= maxv;
				end else if (idx <= 5'd18) begin
					nCv = 6'd0;
					maxv = 5'd4;
					cavlc_table_r <= 3'd4;
					cavlc_max_r <= maxv;
				end else begin
					// 19..26: plane-major, 4 blocks each (U then V)
					chr_i = idx - 5'd19;
					p = chr_i[2];
					bi = chr_i[1:0];
					nCv = chroma_nC(p, bi);
					maxv = 5'd15;
					cavlc_table_r <= nc_table(nCv);
					cavlc_max_r <= maxv;
				end
			end else if (idx < 5'd16) begin
				nCv = luma_nC(idx[3:0]);
				maxv = 5'd16;
				cavlc_table_r <= nc_table(nCv);
				cavlc_max_r <= maxv;
			end else if (idx < 5'd18) begin
				nCv = 6'd0;
				maxv = 5'd4;
				cavlc_table_r <= 3'd4;
				cavlc_max_r <= maxv;
			end else begin
				// 18..25: plane-major, 4 blocks each
				chr_i = idx - 5'd18;
				p = chr_i[2];
				bi = chr_i[1:0];
				nCv = chroma_nC(p, bi);
				maxv = 5'd15;
				cavlc_table_r <= nc_table(nCv);
				cavlc_max_r <= maxv;
			end
			cavlc_bit0_r <= {7'd0, abs_bit[2:0]};
			cavlc_bitlen_r <= 10'd512;
			// cavlc_start_r pulsed after ST_RES_WIN_LOAD completes
`ifdef VERILATOR
			if (is_i_slice_r && curr_mb < 16'd6)
				$display("TRAV_RES_LAUNCH mb=%0d res_i=%0d i16=%0d nC=%0d max=%0d abs_bit=%0d",
					curr_mb, idx, is_i16_r, nCv, maxv, abs_bit);
`endif
		end
	endtask

	task automatic advance_mb_xy;
		begin
			if (mb_w16 == 16'd0) begin
				curr_x_r <= 8'd0;
				curr_y_r <= 8'd0;
			end else if (curr_x_r >= (mb_w16[7:0] - 8'd1)) begin
				curr_x_r <= 8'd0;
				curr_y_r <= curr_y_r + 8'd1;
			end else begin
				curr_x_r <= curr_x_r + 8'd1;
			end
		end
	endtask

	task automatic commit_tc_after_luma;
		input [3:0] bi;
		input [4:0] tc;
		reg [1:0] bx, by;
		reg [15:0] abs_x;
		begin
			bx = blk4_x(bi);
			by = blk4_y(bi);
			abs_x = {curr_x[13:0], 2'b00} + {14'd0, bx};
			tc_left[by] <= tc;
			tc_left_v[by] <= 1'b1;
			tc_spat[{by, bx}] <= tc;
			tc_spat_v[{by, bx}] <= 1'b1;
			// Bottom row of MB is next-row top: write M10K (single port).
			// Upper rows only need spat for same-MB nB.
			if (by == 2'd3 && abs_x < NB_TOP_N) begin
				tc_ram_we <= 1'b1;
				tc_ram_waddr <= NB_AW'(abs_x);
				tc_ram_wdata <= {2'b0, 1'b1, tc};
			end
		end
	endtask

	task automatic commit_tc_after_chr;
		input       p;
		input [1:0] bi;
		input [4:0] tc;
		reg bx, by;
		reg [15:0] abs_x;
		begin
			bx = chr_bx(bi);
			by = chr_by(bi);
			abs_x = {curr_x[14:0], 1'b0} + {15'd0, bx};
			tc_chr_left[p][by] <= tc;
			tc_chr_left_v[p][by] <= 1'b1;
			if (abs_x < MAX_MB_W*2) begin
				tc_chr_top[p][abs_x] <= tc;
				tc_chr_top_v[p][abs_x] <= 1'b1;
			end
		end
	endtask

	// Zero both chroma planes' AC neighbour map for this MB (skip / cbp_c!=2).
	task automatic zero_chr_tc_mb;
		integer p, b;
		reg [15:0] abs_x;
		begin
			for (p = 0; p < 2; p = p + 1) begin
				for (b = 0; b < 4; b = b + 1) begin
					abs_x = {curr_x[14:0], 1'b0} + {15'd0, b[0]};
					tc_chr_left[p][b[1]] <= 5'd0;
					tc_chr_left_v[p][b[1]] <= 1'b1;
					if (abs_x < MAX_MB_W*2) begin
						tc_chr_top[p][abs_x] <= 5'd0;
						tc_chr_top_v[p][abs_x] <= 1'b1;
					end
				end
			end
		end
	endtask

	always @(posedge clk) begin
		if (reset || clear) begin
			rbsp_len <= 16'd0;
			bit_pos <= 18'd0;
			rbsp_we <= 1'b0;
			rbsp_waddr <= '0;
			rbsp_wdata <= 8'd0;
			rbsp_raddr <= '0;
			bit_byte <= 8'd0;
			bit_byte_addr <= '0;
			bit_byte_v <= 1'b0;
			win_base <= '0;
			win_k <= 8'd0;
			curr_x_r <= 8'd0;
			curr_y_r <= 8'd0;
			xy_rem <= 16'd0;
			busy <= 1'b0;
			st <= ST_IDLE;
			ret_st <= ST_IDLE;
			mb_valid <= 1'b0;
			mb_hold <= 1'b0;
			mb_addr <= 16'd0;
			mb_x <= 8'd0;
			mb_y <= 8'd0;
			mb_skip <= 1'b0;
			mb_type <= 8'd0;
			part_mode <= PART_INTRA;
			part_count <= 3'd0;
			uses_sub_mb <= 1'b0;
			is_intra <= 1'b0;
			cbp <= 6'd0;
			mb_qp <= 8'sd0;
			residual_bit_offset <= 16'd0;
			mb_count <= 16'd0;
			slice_done <= 1'b0;
			error <= 1'b0;
			unsupported <= 1'b0;
			curr_mb <= 16'd0;
			pic_mbs <= 16'd0;
			skip_left <= 16'd0;
			skip_run_lat <= 16'd0;
			mvd_pairs_left <= 8'd0;
			sub_idx <= 3'd0;
			cbp_r <= 6'd0;
			qp_r <= 8'sd26;
			mb_type_r <= 8'd0;
			part_mode_r <= PART_INTRA;
			part_count_r <= 3'd0;
			uses_sub_r <= 1'b0;
			is_intra_r <= 1'b0;
			is_i16_r <= 1'b0;
			is_i_slice_r <= 1'b0;
			i4_idx <= 5'd0;
			res_block_i <= 5'd0;
			res_blocks_total <= 5'd0;
			res_luma_mask <= 4'd0;
			res_chroma <= 2'd0;
			cavlc_start_r <= 1'b0;
			res_blk_valid <= 1'b0;
			res_mb_end <= 1'b0;
			res_mb_end_addr <= 16'd0;
			res_blk_mb_addr <= 16'd0;
			res_blk_mb_x <= 8'd0;
			res_blk_mb_y <= 8'd0;
			res_blk_idx <= 5'd0;
			res_blk_is_i16 <= 1'b0;
			res_blk_is_luma <= 1'b1;
			res_blk_qp <= 6'd0;
			res_blk_max_coeff <= 5'd16;
			res_blk_pred_mode <= 4'd2;
			i16_mode_r <= 2'd0;
			res_hold_from_cavlc <= 1'b0;
			for (ti = 0; ti < 16; ti = ti + 1) begin
				res_blk_coeff[ti] <= 16'sd0;
				i4_mode_scan[ti] <= 4'd2;
				i4_mode_spat[ti] <= 4'd2;
				i4_mode_spat_v[ti] <= 1'b0;
			end
			for (ti = 0; ti < 4; ti = ti + 1) begin
				i4_mode_left[ti] <= 4'd2;
				i4_mode_left_v[ti] <= 1'b0;
				i4_mode_top_e[ti] <= 4'd2;
				i4_mode_top_e_v[ti] <= 1'b0;
				tc_top_e[ti] <= 5'd0;
				tc_top_e_v[ti] <= 1'b0;
				tc_left[ti] <= 5'd0;
				tc_left_v[ti] <= 1'b0;
			end
			for (ti = 0; ti < 16; ti = ti + 1) begin
				tc_spat[ti] <= 5'd0;
				tc_spat_v[ti] <= 1'b0;
			end
			tc_ram_we <= 1'b0;
			im_ram_we <= 1'b0;
			tc_ram_raddr <= '0;
			im_ram_raddr <= '0;
			tc_ram_waddr <= '0;
			im_ram_waddr <= '0;
			tc_ram_wdata <= 8'd0;
			im_ram_wdata <= 8'd0;
			nb_k <= 4'd0;
			nb_rd_ph <= 2'd0;
			edge_next_st <= ST_IDLE;
			store_mode <= 4'd0;
			begin : rst_chr
				integer p, x;
				for (p = 0; p < 2; p = p + 1) begin
					tc_chr_left[p][0] <= 5'd0;
					tc_chr_left[p][1] <= 5'd0;
					tc_chr_left_v[p][0] <= 1'b0;
					tc_chr_left_v[p][1] <= 1'b0;
					for (x = 0; x < MAX_MB_W*2; x = x + 1) begin
						tc_chr_top[p][x] <= 5'd0;
						tc_chr_top_v[p][x] <= 1'b0;
					end
				end
			end
			for (wi = 0; wi < 64; wi = wi + 1)
				res_win[wi] <= 8'd0;
		end else begin
			slice_done <= 1'b0;
			cavlc_start_r <= 1'b0;
			res_mb_end <= 1'b0;
			rbsp_we <= 1'b0;
			tc_ram_we <= 1'b0;
			im_ram_we <= 1'b0;

			// Handshake: drop valid when accepted
			if (mb_valid && mb_ready) begin
				mb_valid <= 1'b0;
				mb_hold <= 1'b0;
			end
			if (res_blk_valid && res_blk_ready)
				res_blk_valid <= 1'b0;

			// RBSP fill: single write port into M10K
			if (!busy && in_valid && in_ready) begin
				rbsp_we <= 1'b1;
				rbsp_waddr <= rbsp_len[RBSP_AW-1:0];
				rbsp_wdata <= in_byte;
				rbsp_len <= rbsp_len + 16'd1;
			end

			// Default read address: residual window loader or current bit byte.
			// Window: issue raddr=base+k for k=0..63; capture byte k at win_k=k+2
			// (registered M10K read = 1 cycle addr→q).
			// win_k is [7:0]; must zero-extend to RBSP_AW (not win_k[RBSP_AW-1:0]
			// which is Quartus Error 10232 when RBSP_AW > 8).
			if (st == ST_RES_WIN_LOAD) begin
				if (win_k <= 8'd63)
					rbsp_raddr <= win_base + RBSP_AW'(win_k);
			end else
				rbsp_raddr <= bit_need_addr;

			// Capture registered RBSP byte for bit engine (not during window load).
			if (st == ST_RES_WIN_LOAD) begin
				bit_byte_v <= 1'b0;
			end else if (rbsp_ra_d1 == bit_need_addr) begin
				bit_byte <= rbsp_q;
				bit_byte_addr <= rbsp_ra_d1;
				bit_byte_v <= 1'b1;
			end

			// Stall FSM while an MB beat is outstanding and not taken,
			// or while residual export is waiting for consumer ready.
			if (mb_hold && !(mb_valid && mb_ready) && busy) begin
				// hold state
			end else if (res_blk_valid && !res_blk_ready && busy) begin
				// residual hold (ST_RES_HOLD also waits explicitly)
			end else if (!busy && start) begin
				busy <= 1'b1;
				error <= 1'b0;
				unsupported <= 1'b0;
				mb_count <= 16'd0;
				pic_mbs <= pic_mbs32[15:0];
				bit_pos <= 18'd0;
				bit_byte_v <= 1'b0;
				curr_x_r <= 8'd0;
				curr_y_r <= 8'd0;
				log2_fn_r <= (log2_max_frame_num == 5'd0) ? 5'd4 : log2_max_frame_num;
				db_lat <= pps_deblock_ctrl;
				idr_lat <= is_idr_nal;
				nal_ref_lat <= nal_ref_idc_nonzero;
				init_qp_r <= pps_pic_init_qp;
				qp_r <= pps_pic_init_qp;
				for (ti = 0; ti < 4; ti = ti + 1) begin
					tc_left[ti] <= 5'd0;
					tc_left_v[ti] <= 1'b0;
					tc_top_e[ti] <= 5'd0;
					tc_top_e_v[ti] <= 1'b0;
					i4_mode_top_e[ti] <= 4'd2;
					i4_mode_top_e_v[ti] <= 1'b0;
				end
				for (ti = 0; ti < 16; ti = ti + 1) begin
					tc_spat[ti] <= 5'd0;
					tc_spat_v[ti] <= 1'b0;
				end
				begin : start_chr
					integer p, x;
					for (p = 0; p < 2; p = p + 1) begin
						tc_chr_left[p][0] <= 5'd0;
						tc_chr_left[p][1] <= 5'd0;
						tc_chr_left_v[p][0] <= 1'b0;
						tc_chr_left_v[p][1] <= 1'b0;
						for (x = 0; x < MAX_MB_W*2; x = x + 1) begin
							tc_chr_top[p][x] <= 5'd0;
							tc_chr_top_v[p][x] <= 1'b0;
						end
					end
				end
				// Serial-clear top-row M10Ks (valid bits) once per slice.
				nb_clr_i <= 9'd0;
				store_mode <= 4'd3;
				st <= ST_NB_RAM_CLR;
			end else if (busy) begin
				case (st)
				ST_BITS: begin
					if (fixed_left == 8'd0) st <= ret_st;
					else if (bit_pos >= rbsp_bit_total) fail();
					else if (!bit_ready) begin
						// wait M10K byte
					end else begin
						fixed_acc <= (fixed_acc << 1) | {31'd0, cur_bit};
						bit_pos <= bit_pos + 18'd1;
						fixed_left <= fixed_left - 8'd1;
						if (fixed_left == 8'd1) st <= ret_st;
					end
				end
				ST_UE_ZERO: begin
					if (bit_pos >= rbsp_bit_total) fail();
					else if (!bit_ready) begin
						// wait M10K byte
					end else if (!cur_bit) begin
						bit_pos <= bit_pos + 18'd1;
						if (ue_zero >= 8'd24) fail();
						else ue_zero <= ue_zero + 8'd1;
					end else begin
						bit_pos <= bit_pos + 18'd1;
						if (ue_zero == 8'd0) begin
							ue_value <= 32'd0;
							st <= ret_st;
						end else begin
							ue_suffix_left <= ue_zero;
							ue_suffix <= 32'd0;
							st <= ST_UE_SUFFIX;
						end
					end
				end
				ST_UE_SUFFIX: begin
					if (bit_pos >= rbsp_bit_total) fail();
					else if (!bit_ready) begin
						// wait M10K byte
					end else begin
						// NBA-correct: old ue_suffix in RHS yields final suffix value.
						ue_suffix <= (ue_suffix << 1) | {31'd0, cur_bit};
						if (ue_suffix_left == 8'd1) begin
							ue_value <= ((32'd1 << ue_zero) - 32'd1) +
							            ((ue_suffix << 1) | {31'd0, cur_bit});
							st <= ret_st;
						end
						bit_pos <= bit_pos + 18'd1;
						ue_suffix_left <= ue_suffix_left - 8'd1;
					end
				end
				ST_HDR_FIRST: begin
					first_mb_r <= ue_value[15:0];
					curr_mb <= ue_value[15:0];
					xy_rem <= ue_value[15:0];
					curr_x_r <= 8'd0;
					curr_y_r <= 8'd0;
					st <= ST_INIT_XY;
				end
				ST_INIT_XY: begin
					// Walk first_mb steps on x/y counters (area: no divider).
					if (xy_rem == 16'd0)
						start_ue(ST_HDR_TYPE);
					else begin
						advance_mb_xy();
						xy_rem <= xy_rem - 16'd1;
					end
				end
				ST_HDR_TYPE: begin
					slice_type_r <= ue_value[7:0];
					// P: 0/5; I: 2/7. Other types unsupported here.
					if ((ue_value[7:0] == 8'd0) || (ue_value[7:0] == 8'd5)) begin
						is_i_slice_r <= 1'b0;
						start_ue(ST_HDR_PPS);
					end else if ((ue_value[7:0] == 8'd2) || (ue_value[7:0] == 8'd7)) begin
						is_i_slice_r <= 1'b1;
						start_ue(ST_HDR_PPS);
					end else begin
						unsupported <= 1'b1;
						st <= ST_DONE;
					end
				end
				ST_HDR_PPS: begin
					start_bits({3'd0, log2_fn_r}, ST_HDR_FRAME);
				end
				ST_HDR_FRAME: begin
					if (idr_lat)
						start_ue(ST_HDR_IDR);
					else if ((slice_type_r == 8'd0) || (slice_type_r == 8'd5))
						start_bits(8'd1, ST_HDR_REFIDX_F);
					else if (nal_ref_lat)
						start_bits(8'd1, ST_HDR_REFMARK);
					else
						start_ue(ST_HDR_QPD);
				end
				ST_HDR_IDR: begin
					// IDR dec_ref_pic_marking: two flags, then QP
					start_bits(8'd2, ST_HDR_QPD_PRE);
				end
				ST_HDR_REFIDX_F: begin
					// After override (or override+l0 count): ref_pic_list_modification()
					if (fixed_acc[0])
						start_ue(ST_HDR_REFIDX_L0);
					else
						start_bits(8'd1, ST_HDR_LISTMOD_F);
				end
				ST_HDR_REFIDX_L0: begin
					start_bits(8'd1, ST_HDR_LISTMOD_F);
				end
				// 7.3.3.1 ref_pic_list_modification for P: flag_l0 then optional idc loop.
				// Missing this bit misaligns QP/mb_skip_run (measured: fixture peak 147/300).
				ST_HDR_LISTMOD_F: begin
					if (fixed_acc[0])
						start_ue(ST_HDR_LISTMOD_IDC);
					else if (nal_ref_lat)
						start_bits(8'd1, ST_HDR_REFMARK);
					else
						start_ue(ST_HDR_QPD);
				end
				ST_HDR_LISTMOD_IDC: begin
					// modification_of_pic_nums_idc; 3 = end
					if (ue_value == 32'd3) begin
						if (nal_ref_lat)
							start_bits(8'd1, ST_HDR_REFMARK);
						else
							start_ue(ST_HDR_QPD);
					end else if (ue_value == 32'd0 || ue_value == 32'd1 || ue_value == 32'd2) begin
						start_ue(ST_HDR_LISTMOD_ARG);
					end else begin
						unsupported <= 1'b1;
						fail();
					end
				end
				ST_HDR_LISTMOD_ARG: begin
					// abs_diff_pic_num_minus1 or long_term_pic_num — value unused
					start_ue(ST_HDR_LISTMOD_IDC);
				end
				ST_HDR_REFMARK: begin
					// adaptive MMCO unsupported — if set, stop walk
					if (!idr_lat && fixed_acc[0]) begin
						unsupported <= 1'b1;
						st <= ST_DONE;
					end else
						start_ue(ST_HDR_QPD);
				end
				ST_HDR_QPD_PRE: begin
					start_ue(ST_HDR_QPD);
				end
				ST_HDR_QPD: begin
					// slice_qp_delta: clamp 0..51 (host parseSliceHeaderRbsp)
					qp_r <= clamp_qp_y(init_qp_r, se8_from_ue(ue_value));
					if (db_lat)
						start_ue(ST_HDR_DIDC);
					else
						st <= ST_START;
				end
				ST_HDR_DIDC: begin
					if (ue_value != 32'd1)
						start_ue(ST_HDR_ALPHA);
					else
						st <= ST_START;
				end
				ST_HDR_ALPHA: begin
					start_ue(ST_HDR_BETA);
				end
				ST_HDR_BETA: begin
					st <= ST_START;
				end
				ST_START: begin
`ifdef VERILATOR
					if (curr_mb == 16'd0)
						$display("TRAV_HDR_OK i_slice=%0d bit_pos=%0d qp=%0d pic_mbs=%0d type=%0d",
							is_i_slice_r, bit_pos, qp_r, pic_mbs, slice_type_r);
`endif
					if (curr_mb >= pic_mbs) st <= ST_DONE;
					else if (is_i_slice_r)
						start_ue(ST_TYPE_UE); // I: no mb_skip_run
					else
						start_ue(ST_SKIP_UE);
				end
				ST_SKIP_UE: begin
					skip_run_lat <= FAULT_BAD_SKIP_RUN ? 16'd0 : ue_value[15:0];
					if (FAULT_BAD_SKIP_RUN) begin
						// mutation: ignore skip_run and force coded path
						start_ue(ST_TYPE_UE);
					end else if (ue_value != 32'd0) begin
						skip_left <= ue_value[15:0];
						st <= ST_SKIP_EMIT;
					end else begin
						start_ue(ST_TYPE_UE);
					end
				end
				ST_SKIP_EMIT: begin
					if (curr_mb >= pic_mbs) begin
						st <= ST_DONE;
					end else if (skip_left != 16'd0) begin
						emit_mb(1'b1);
						// P_Skip: clear left tc; top-row zeros via ST_EDGE_STORE
						for (ti = 0; ti < 4; ti = ti + 1) begin
							tc_left[ti] <= 5'd0;
							tc_left_v[ti] <= 1'b1;
						end
						zero_chr_tc_mb();
						nb_k <= 4'd0;
						store_mode <= 4'd1; // write 4 zero tc_top
						edge_next_st <= ST_SKIP_EMIT; // return to continue skip_left
						// defer xy advance until store done
						st <= ST_EDGE_STORE;
					end else if (curr_mb >= pic_mbs) begin
						st <= ST_DONE;
					end else begin
						if (bit_pos >= rbsp_bit_total)
							st <= ST_DONE;
						else
							start_ue(ST_TYPE_UE);
					end
				end
				ST_TYPE_UE: begin
					st <= ST_TYPE;
				end
				ST_TYPE: begin
					mb_type_r <= ue_value[7:0];
					is_i16_r <= 1'b0;
					if (is_i_slice_r) begin
						// I-slice mb_type: 0=I_NxN, 1..24=I_16x16, 25=PCM
						if (ue_value == 32'd0) begin
							is_intra_r <= 1'b1;
							uses_sub_r <= 1'b0;
							part_mode_r <= PART_INTRA;
							part_count_r <= 3'd0;
							i4_idx <= 5'd0;
							begin : clr_i4_spat
								integer zi;
								for (zi = 0; zi < 16; zi = zi + 1)
									i4_mode_spat_v[zi] <= 1'b0;
							end
							for (ti = 0; ti < 16; ti = ti + 1) begin
								tc_spat[ti] <= 5'd0;
								tc_spat_v[ti] <= 1'b0;
							end
							nb_k <= 4'd0;
							nb_rd_ph <= 2'd0;
							edge_next_st <= ST_I4_GO;
							st <= ST_EDGE_LOAD;
						end else if (ue_value >= 32'd1 && ue_value <= 32'd24) begin
							is_intra_r <= 1'b1;
							is_i16_r <= 1'b1;
							uses_sub_r <= 1'b0;
							part_mode_r <= PART_INTRA;
							part_count_r <= 3'd0;
							begin : i16_cbp_i
								reg [4:0] x;
								reg [1:0] cc;
								x = ue_value[4:0] - 5'd1; // 0..23
								cc = (x / 5'd4) % 2'd3;
								cbp_r <= {cc, (x >= 5'd12) ? 4'hF : 4'h0};
								i16_mode_r <= x[1:0]; // pred_mode = x % 4
							end
							for (ti = 0; ti < 16; ti = ti + 1) begin
								tc_spat[ti] <= 5'd0;
								tc_spat_v[ti] <= 1'b0;
							end
							nb_k <= 4'd0;
							nb_rd_ph <= 2'd0;
							edge_next_st <= ST_I16_GO;
							st <= ST_EDGE_LOAD;
						end else begin
							// PCM / unknown
							unsupported <= 1'b1;
							fail();
						end
					end else if (ue_value <= 32'd4) begin
						is_intra_r <= 1'b0;
						uses_sub_r <= (ue_value == 32'd3) || (ue_value == 32'd4);
						part_mode_r <= part_mode_of(1'b0, ue_value[7:0]);
						part_count_r <= part_count_of(1'b0, ue_value[7:0]);
						if (num_ref_idx_l0_active_minus1 != 3'd0) begin
							// multi-ref: ref_idx_l0 syntax not walked here
							unsupported <= 1'b1;
							// still attempt single-ref path with zero ref idx bits
						end
						case (ue_value[2:0])
						3'd0: begin mvd_pairs_left <= 8'd1; start_ue(ST_MVD_X); end
						3'd1: begin mvd_pairs_left <= 8'd2; start_ue(ST_MVD_X); end
						3'd2: begin mvd_pairs_left <= 8'd2; start_ue(ST_MVD_X); end
						default: begin
							part_mode_r <= PART_SUB;
							sub_idx <= 3'd0;
							mvd_pairs_left <= 8'd0;
							start_ue(ST_SUB_UE);
						end
						endcase
					end else if (ue_value == 32'd5) begin
						// I_NxN in P
						is_intra_r <= 1'b1;
						uses_sub_r <= 1'b0;
						part_mode_r <= PART_INTRA;
						part_count_r <= 3'd0;
						i4_idx <= 5'd0;
						begin : clr_i4_spat_p
							integer zi;
							for (zi = 0; zi < 16; zi = zi + 1)
								i4_mode_spat_v[zi] <= 1'b0;
						end
						for (ti = 0; ti < 16; ti = ti + 1) begin
							tc_spat[ti] <= 5'd0;
							tc_spat_v[ti] <= 1'b0;
						end
						nb_k <= 4'd0;
						nb_rd_ph <= 2'd0;
						edge_next_st <= ST_I4_GO;
						st <= ST_EDGE_LOAD;
					end else if (ue_value >= 32'd6 && ue_value <= 32'd29) begin
						// I_16x16 in P: mb_type 6..29 ≡ I types 1..24
						// cbp_c = ((mt-6)/4)%3; cbp_l = ((mt-6)/12)?15:0
						is_intra_r <= 1'b1;
						is_i16_r <= 1'b1;
						uses_sub_r <= 1'b0;
						part_mode_r <= PART_INTRA;
						part_count_r <= 3'd0;
						begin : i16_cbp
							reg [4:0] x;
							reg [1:0] cc;
							x = ue_value[4:0] - 5'd6; // 0..23
							cc = (x / 5'd4) % 2'd3;
							// cbp[5:4]=chroma 0..2; cbp[3:0]=luma 0 or 15
							cbp_r <= {cc, (x >= 5'd12) ? 4'hF : 4'h0};
						end
						for (ti = 0; ti < 16; ti = ti + 1) begin
							tc_spat[ti] <= 5'd0;
							tc_spat_v[ti] <= 1'b0;
						end
						nb_k <= 4'd0;
						nb_rd_ph <= 2'd0;
						edge_next_st <= ST_I16_GO;
						st <= ST_EDGE_LOAD;
					end else if (ue_value == 32'd30) begin
						// I_PCM — unsupported in product Baseline walker
						unsupported <= 1'b1;
						fail();
					end else begin
						unsupported <= 1'b1;
						fail();
					end
				end
				ST_SUB_UE: begin
					if (ue_value > 32'd3) begin
						unsupported <= 1'b1;
						fail();
					end else begin
						mvd_pairs_left <= mvd_pairs_left + sub_mb_mvd_pairs(ue_value);
						if (sub_idx == 3'd3)
							start_ue(ST_MVD_X);
						else begin
							sub_idx <= sub_idx + 3'd1;
							start_ue(ST_SUB_UE);
						end
					end
				end
				// Arrival at ST_MVD_X means ue_value holds se(v) MVD x (or
				// pairs==0 sentinel to begin CBP). Y is the next se(v).
				ST_MVD_X: begin
					if (mvd_pairs_left == 8'd0)
						start_ue(ST_CBP_UE);
					else
						start_ue(ST_MVD_Y);
				end
				ST_MVD_Y: begin
					// ue_value holds MVD y; do not start_ue again (would steal CBP).
					if (mvd_pairs_left <= 8'd1) begin
						mvd_pairs_left <= 8'd0;
						start_ue(ST_CBP_UE);
					end else begin
						mvd_pairs_left <= mvd_pairs_left - 8'd1;
						start_ue(ST_MVD_X);
					end
				end
				ST_MVD_PAIR_DONE: begin
					// unused; kept for state encoding stability
					st <= ST_MVD_X;
				end
				ST_CBP_UE: begin
					st <= ST_CBP;
				end
				ST_CBP: begin
					if (ue_value >= 32'd48) begin
						unsupported <= 1'b1;
						fail();
					end else begin
						cbp_r <= cbp_inter_map(ue_value[5:0]);
						if (cbp_inter_map(ue_value[5:0]) != 6'd0)
							start_ue(ST_QP_UE);
						else begin
							residual_bit_offset <= bit_pos[15:0];
							st <= ST_EMIT_CODED;
						end
					end
				end
				ST_QP_UE: begin
					// mb_qp_delta: mod-52 wrap (H.264 8.5.1 / host wrapQpY)
					qp_r <= wrap_qp_y(qp_r, se8_from_ue(ue_value));
					residual_bit_offset <= bit_pos[15:0];
					st <= ST_EMIT_CODED;
				end
				ST_I4_FLAG: begin
					if (fixed_acc[0]) begin
						// prev_intra4x4_pred_mode_flag=1 → use MPM
						begin : i4_mpm_store
							reg [3:0] m, si;
							reg [1:0] bx, by;
							si = i4_idx[3:0];
							m = i4_mpm(si);
							bx = blk4_x(si);
							by = blk4_y(si);
							i4_mode_scan[si] <= m;
							i4_mode_spat[{by, bx}] <= m;
							i4_mode_spat_v[{by, bx}] <= 1'b1;
						end
						if (i4_idx == 5'd15)
							start_ue(ST_CHR_UE);
						else begin
							i4_idx <= i4_idx + 5'd1;
							start_bits(8'd1, ST_I4_FLAG);
						end
					end else begin
						start_bits(8'd3, ST_I4_REM);
					end
				end
				ST_I4_REM: begin
					begin : i4_rem_store
						reg [3:0] m, si, mpm;
						reg [1:0] bx, by;
						si = i4_idx[3:0];
						mpm = i4_mpm(si);
						m = i4_mode_from_rem(mpm, fixed_acc[2:0]);
						bx = blk4_x(si);
						by = blk4_y(si);
						i4_mode_scan[si] <= m;
						i4_mode_spat[{by, bx}] <= m;
						i4_mode_spat_v[{by, bx}] <= 1'b1;
					end
					if (i4_idx == 5'd15)
						start_ue(ST_CHR_UE);
					else begin
						i4_idx <= i4_idx + 5'd1;
						start_bits(8'd1, ST_I4_FLAG);
					end
				end
				ST_CHR_UE: begin
					// I_NxN: cbp me next. I_16x16: always mb_qp_delta then residual
					// (luma DC always coded even when cbp_l=cbp_c=0).
					// I-slice I_NxN has mb_type=0; P-slice I_NxN has mb_type=5.
					if ((is_i_slice_r && (mb_type_r == 8'd0)) ||
					    (!is_i_slice_r && (mb_type_r == 8'd5)))
						start_ue(ST_CBP_INTRA_UE);
					else
						start_ue(ST_QP_UE);
				end
				ST_CBP_INTRA_UE: begin
					if (ue_value >= 32'd48) begin
						unsupported <= 1'b1;
						fail();
					end else begin
						cbp_r <= cbp_intra_map(ue_value[5:0]);
						if (cbp_intra_map(ue_value[5:0]) != 6'd0)
							start_ue(ST_QP_UE);
						else begin
							residual_bit_offset <= bit_pos[15:0];
							st <= ST_EMIT_CODED;
						end
					end
				end
				ST_EMIT_CODED: begin
					emit_mb(1'b0);
					res_luma_mask <= cbp_r[3:0];
					res_chroma <= cbp_r[5:4];
					if (!is_i16_r && cbp_r == 6'd0) begin
						// inter/I_NxN with no residual; zero left + top-row M10K
						for (ti = 0; ti < 4; ti = ti + 1) begin
							tc_left[ti] <= 5'd0;
							tc_left_v[ti] <= 1'b1;
						end
						zero_chr_tc_mb();
						nb_k <= 4'd0;
						store_mode <= 4'd1; // 4× tc_top zero
						if (is_i_slice_r) begin
							res_mb_end <= 1'b1;
							res_mb_end_addr <= curr_mb;
							edge_next_st <= ST_RES_MB_END;
						end else
							edge_next_st <= ST_NEXT_MB;
						st <= ST_EDGE_STORE;
					end else begin
						// I_16x16 always enters residual (DC); inter if cbp!=0
						// Inter may not have run EDGE_LOAD — load nC top edge now.
						res_block_i <= 5'd0;
						if (!is_intra_r) begin
							for (ti = 0; ti < 16; ti = ti + 1) begin
								tc_spat[ti] <= 5'd0;
								tc_spat_v[ti] <= 1'b0;
							end
							nb_k <= 4'd0;
							nb_rd_ph <= 2'd0;
							edge_next_st <= ST_RES_SETUP;
							st <= ST_EDGE_LOAD;
						end else
							st <= ST_RES_SETUP;
					end
				end
				ST_RES_SETUP: begin
					// I_16x16: 0..26 (DC+16AC+2DC+8AC); else 0..25
					if ((!is_i16_r && res_block_i >= 5'd26) ||
					    (is_i16_r && res_block_i >= 5'd27)) begin
						// If chroma AC not coded, still zero neighbour map once.
						if (res_chroma != 2'd2)
							zero_chr_tc_mb();
						// Notify recon sink that this MB's residual is complete (I only).
						if (is_i_slice_r) begin
							res_mb_end <= 1'b1;
							res_mb_end_addr <= curr_mb;
							// Commit right-edge modes to left regs; bottom → M10K store.
							begin : commit_i4_left
								integer ei;
								for (ei = 0; ei < 4; ei = ei + 1) begin
									if (!is_i16_r) begin
										i4_mode_left[ei] <= i4_mode_spat[{ei[1:0], 2'd3}];
										i4_mode_left_v[ei] <= i4_mode_spat_v[{ei[1:0], 2'd3}];
									end else begin
										i4_mode_left[ei] <= 4'd2;
										i4_mode_left_v[ei] <= 1'b1;
									end
								end
							end
							nb_k <= 4'd0;
							store_mode <= 4'd0; // write 4 i4_mode_top bottom
							edge_next_st <= ST_RES_MB_END;
							st <= ST_EDGE_STORE;
						end else
							st <= ST_NEXT_MB;
					end else if (!res_slot_coded(res_block_i)) begin
						if (is_i16_r) begin
							if (res_block_i >= 5'd1 && res_block_i <= 5'd16)
								commit_tc_after_luma(res_block_i[3:0] - 4'd1, 5'd0);
						end else if (res_block_i < 5'd16) begin
							commit_tc_after_luma(res_block_i[3:0], 5'd0);
						end
						// I-slice: still export zero-coeff luma so sink runs pred
						// (uncoded residual ≠ skip prediction / neighbour write).
						if (is_i_slice_r &&
						    ((!is_i16_r && res_block_i < 5'd16) ||
						     (is_i16_r && res_block_i <= 5'd16))) begin
							begin : exp_zero
								integer ci;
								res_blk_valid <= 1'b1;
								res_blk_mb_addr <= curr_mb;
								res_blk_mb_x <= curr_x[7:0];
								res_blk_mb_y <= curr_y[7:0];
								res_blk_idx <= res_block_i;
								res_blk_is_i16 <= is_i16_r;
								res_blk_is_luma <= 1'b1;
								res_blk_qp <= qp_r[5:0];
								res_blk_max_coeff <= is_i16_r ?
									((res_block_i == 5'd0) ? 5'd16 : 5'd15) : 5'd16;
								if (is_i16_r && res_block_i == 5'd0)
									res_blk_pred_mode <= {2'd0, i16_mode_r};
								else if (!is_i16_r)
									res_blk_pred_mode <= i4_mode_scan[res_block_i[3:0]];
								else
									res_blk_pred_mode <= 4'd0;
								for (ci = 0; ci < 16; ci = ci + 1)
									res_blk_coeff[ci] <= 16'sd0;
								res_hold_idx <= res_block_i;
								res_hold_is_i16 <= is_i16_r;
								res_hold_is_luma <= 1'b1;
								res_hold_from_cavlc <= 1'b0;
							end
							st <= ST_RES_HOLD;
						end else
							res_block_i <= res_block_i + 5'd1;
					end else begin
						launch_cavlc_for_slot(res_block_i);
						st <= ST_RES_WIN_LOAD;
					end
				end
				ST_RES_WIN_LOAD: begin
					// Serial 64B from M10K. win_k=0..63 issue; capture at k+2.
					// Latency: raddr@C → q@C+1 visible to FSM @C+2 (NBA + mem).
					if (FAULT_SKIP_WIN_LOAD) begin
						cavlc_start_r <= 1'b1;
						st <= ST_RES_WAIT;
					end else begin
						if (win_k >= 8'd2) begin
							if (({18'd0, win_base} + {10'd0, win_k} - 18'd2) < {2'd0, rbsp_len})
								res_win[win_k - 8'd2] <= rbsp_q;
							else
								res_win[win_k - 8'd2] <= 8'd0;
						end
						if (win_k == 8'd65) begin
							cavlc_start_r <= 1'b1;
							st <= ST_RES_WAIT;
							win_k <= 8'd0;
						end else
							win_k <= win_k + 8'd1;
					end
				end
				ST_RES_WAIT: begin
					if (cavlc_done) begin
						if (!cavlc_ok) begin
`ifdef VERILATOR
							$display("TRAV_CAVLC_FAIL mb=%0d res_i=%0d bit_pos=%0d table=%0d max=%0d bit0=%0d end=%0d i16=%0d tc=%0d t1=%0d tz=%0d",
								curr_mb, res_block_i, bit_pos, cavlc_table_r, cavlc_max_r,
								cavlc_bit0_r, cavlc_bit_end, is_i16_r, cavlc_tc, cavlc_t1, cavlc_tz);
`endif
							fail();
						end else begin
							// Stash for HOLD commit (always).
							res_hold_idx <= res_block_i;
							res_hold_is_i16 <= is_i16_r;
							res_hold_from_cavlc <= 1'b1;
							begin : exp_res
								integer ci;
								reg is_luma_slot;
								reg [4:0] maxc;
								is_luma_slot = is_i16_r ?
									(res_block_i <= 5'd16) :
									(res_block_i < 5'd16);
								if (is_i16_r && res_block_i == 5'd0)
									maxc = 5'd16;
								else if (is_i16_r && res_block_i <= 5'd16)
									maxc = 5'd15;
								else if (!is_i16_r && res_block_i < 5'd16)
									maxc = 5'd16;
								else if ((!is_i16_r && res_block_i < 5'd18) ||
								         (is_i16_r && res_block_i <= 5'd18))
									maxc = 5'd4;
								else
									maxc = 5'd15;
								res_hold_is_luma <= is_luma_slot;
								res_hold_qp <= qp_r[5:0];
								res_hold_max <= maxc;
								res_hold_mb <= curr_mb;
								res_hold_x <= curr_x[7:0];
								res_hold_y <= curr_y[7:0];
								for (ci = 0; ci < 16; ci = ci + 1)
									res_hold_coeff[ci] <= cavlc_coeff[ci];
								// Export only on I/IDR slices (P residual still
								// bit-aligned here; recon owned by P path).
								if (is_i_slice_r) begin
									res_blk_valid <= 1'b1;
									res_blk_mb_addr <= curr_mb;
									res_blk_mb_x <= curr_x[7:0];
									res_blk_mb_y <= curr_y[7:0];
									res_blk_idx <= res_block_i;
									res_blk_is_i16 <= is_i16_r;
									res_blk_is_luma <= is_luma_slot;
									res_blk_qp <= qp_r[5:0];
									res_blk_max_coeff <= maxc;
									if (is_i16_r && res_block_i == 5'd0)
										res_blk_pred_mode <= {2'd0, i16_mode_r};
									else if (!is_i16_r && res_block_i < 5'd16)
										res_blk_pred_mode <= i4_mode_scan[res_block_i[3:0]];
									else
										res_blk_pred_mode <= 4'd0;
									for (ci = 0; ci < 16; ci = ci + 1)
										res_blk_coeff[ci] <= cavlc_coeff[ci];
								end
							end
							st <= ST_RES_HOLD;
						end
					end
				end
				ST_RES_HOLD: begin
					// I export: wait ready. P: res_blk_valid stays 0 → advance now.
					if (!res_blk_valid || res_blk_ready) begin
						if (res_hold_from_cavlc) begin
`ifdef VERILATOR
							if (is_i_slice_r && curr_mb < 16'd6)
								$display("TRAV_RES_OK mb=%0d res_i=%0d i16=%0d tc=%0d t1=%0d tz=%0d bit0=%0d bit_end_abs=%0d table=%0d max=%0d",
									curr_mb, res_hold_idx, res_hold_is_i16, cavlc_tc, cavlc_t1, cavlc_tz,
									res_win_bit0 + {6'd0, cavlc_bit0_r},
									res_win_bit0 + {6'd0, cavlc_bit_end},
									cavlc_table_r, cavlc_max_r);
`endif
							bit_pos <= res_win_bit0 + {6'd0, cavlc_bit_end};
							if (res_hold_is_i16) begin
								if (res_hold_idx >= 5'd1 && res_hold_idx <= 5'd16)
									commit_tc_after_luma(res_hold_idx[3:0] - 4'd1, cavlc_tc);
								else if (res_hold_idx >= 5'd19) begin
									commit_tc_after_chr(
										(res_hold_idx - 5'd19) >= 5'd4,
										(res_hold_idx - 5'd19) & 2'd3,
										cavlc_tc);
								end
							end else if (res_hold_idx < 5'd16) begin
								commit_tc_after_luma(res_hold_idx[3:0], cavlc_tc);
							end else if (res_hold_idx >= 5'd18) begin
								commit_tc_after_chr(
									(res_hold_idx - 5'd18) >= 5'd4,
									(res_hold_idx - 5'd18) & 2'd3,
									cavlc_tc);
							end
						end
						res_block_i <= res_hold_idx + 5'd1;
						st <= ST_RES_SETUP;
					end
				end
				ST_RES_MB_END: begin
					// one-cycle gap after res_mb_end pulse
					st <= ST_NEXT_MB;
				end
				ST_NEXT_MB: begin
					curr_mb <= curr_mb + 16'd1;
					advance_mb_xy();
					if ((curr_mb + 16'd1) >= pic_mbs)
						st <= ST_DONE;
					else if (bit_pos >= rbsp_bit_total)
						st <= ST_DONE;
					else if (is_i_slice_r)
						start_ue(ST_TYPE_UE);
					else
						start_ue(ST_SKIP_UE);
				end
				ST_NB_RAM_CLR: begin
					// Write invalid/zero to both top-row M10Ks (256 entries).
					tc_ram_we <= 1'b1;
					tc_ram_waddr <= NB_AW'(nb_clr_i[7:0]);
					tc_ram_wdata <= 8'd0;
					im_ram_we <= 1'b1;
					im_ram_waddr <= NB_AW'(nb_clr_i[7:0]);
					im_ram_wdata <= 8'd0;
					if (nb_clr_i == 9'd255) begin
						nb_clr_i <= 9'd0;
						start_ue(ST_HDR_FIRST);
					end else
						nb_clr_i <= nb_clr_i + 9'd1;
				end
				ST_EDGE_LOAD: begin
					// nb_k 0..3: tc_top edge; 4..7: i4_mode_top edge. 3cy/rd.
					if (curr_y == 16'd0) begin
						for (ti = 0; ti < 4; ti = ti + 1) begin
							tc_top_e[ti] <= 5'd0;
							tc_top_e_v[ti] <= 1'b0;
							i4_mode_top_e[ti] <= 4'd2;
							i4_mode_top_e_v[ti] <= 1'b0;
						end
						st <= edge_next_st;
					end else if (FAULT_SKIP_TC_TOP_NB) begin
						// RED twin: pretend no top neighbours
						for (ti = 0; ti < 4; ti = ti + 1) begin
							tc_top_e[ti] <= 5'd0;
							tc_top_e_v[ti] <= 1'b0;
							i4_mode_top_e[ti] <= 4'd2;
							i4_mode_top_e_v[ti] <= 1'b0;
						end
						st <= edge_next_st;
					end else if (nb_k < 4'd4) begin
						if (nb_rd_ph == 2'd0) begin
							tc_ram_raddr <= NB_AW'(({curr_x[13:0], 2'b00} + {14'd0, nb_k[1:0]}));
							nb_rd_ph <= 2'd1;
						end else if (nb_rd_ph == 2'd1) begin
							nb_rd_ph <= 2'd2;
						end else begin
							tc_top_e_v[nb_k[1:0]] <= tc_ram_q[5];
							tc_top_e[nb_k[1:0]] <= tc_ram_q[4:0];
							nb_rd_ph <= 2'd0;
							nb_k <= nb_k + 4'd1;
						end
					end else if (nb_k < 4'd8) begin
						if (nb_rd_ph == 2'd0) begin
							im_ram_raddr <= NB_AW'(({curr_x[13:0], 2'b00} + {14'd0, nb_k[1:0]}));
							nb_rd_ph <= 2'd1;
						end else if (nb_rd_ph == 2'd1) begin
							nb_rd_ph <= 2'd2;
						end else begin
							i4_mode_top_e_v[nb_k[1:0]] <= im_ram_q[4];
							i4_mode_top_e[nb_k[1:0]] <= im_ram_q[3:0];
							nb_rd_ph <= 2'd0;
							if (nb_k == 4'd7) begin
								nb_k <= 4'd0;
								st <= edge_next_st;
							end else
								nb_k <= nb_k + 4'd1;
						end
					end else begin
						nb_k <= 4'd0;
						st <= edge_next_st;
					end
				end
				ST_EDGE_STORE: begin
					// store_mode 0: i4 bottom modes; 1: four zero tc_top (skip/cbp0)
					if (store_mode == 4'd0) begin
						im_ram_we <= 1'b1;
						im_ram_waddr <= NB_AW'(({curr_x[13:0], 2'b00} + {14'd0, nb_k[1:0]}));
						if (!is_i16_r) begin
							im_ram_wdata <= {3'b0, i4_mode_spat_v[{2'd3, nb_k[1:0]}],
								i4_mode_spat[{2'd3, nb_k[1:0]}]};
						end else
							im_ram_wdata <= {3'b0, 1'b1, 4'd2};
						if (nb_k == 4'd3) begin
							nb_k <= 4'd0;
							st <= edge_next_st;
						end else
							nb_k <= nb_k + 4'd1;
					end else if (store_mode == 4'd1) begin
						tc_ram_we <= 1'b1;
						tc_ram_waddr <= NB_AW'(({curr_x[13:0], 2'b00} + {14'd0, nb_k[1:0]}));
						tc_ram_wdata <= {2'b0, 1'b1, 5'd0};
						if (nb_k == 4'd3) begin
							nb_k <= 4'd0;
							// skip path: advance after store
							if (edge_next_st == ST_SKIP_EMIT) begin
								curr_mb <= curr_mb + 16'd1;
								advance_mb_xy();
								skip_left <= skip_left - 16'd1;
							end
							st <= edge_next_st;
						end else
							nb_k <= nb_k + 4'd1;
					end else begin
						st <= edge_next_st;
					end
				end
				ST_I4_GO: begin
					start_bits(8'd1, ST_I4_FLAG);
				end
				ST_I16_GO: begin
					start_ue(ST_CHR_UE);
				end
				ST_DONE: begin
					slice_done <= 1'b1;
					busy <= 1'b0;
					st <= ST_IDLE;
`ifdef VERILATOR
					$display("TRAV_DONE mb_count=%0d err=%0d unsup=%0d",
						mb_count, error, unsupported);
`endif
				end
				ST_FAIL: begin
					// Always retire the slice toward consumers (decode_stub FETCH
					// waits on slice_done). error/unsupported already sticky.
					slice_done <= 1'b1;
					busy <= 1'b0;
					st <= ST_IDLE;
`ifdef VERILATOR
					$display("TRAV_FAIL mb_count=%0d st_prev_unsup=%0d",
						mb_count, unsupported);
`endif
				end
				default: fail();
				endcase
			end
		end
	end
endmodule

`default_nettype wire
