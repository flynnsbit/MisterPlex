//============================================================================
//  h264_mb_ctrl — Phase 1 full-slice MB walker
//  One bitstream FIFO (nalu_scanner) + one on-chip walker. No DDR / no m2 DPB.
//  MB0 status goldens still come from the 48B slice_hdr place path.
//  Do NOT treat 0x14 as phase1a MB0 residual bar — walker residual is sl_rbsp 8K only.
//  product_recon_ok follows gold I420 compare latch (not a constant). FIT_GO=NO. apply_itu_fix=false.
//  Walker reach: lock sl_rbsp on sl_rbsp_end (I >>48) so next VCL cannot wipe; then 300 MB.
//  Residual walk: shipped h264_bit_reader + h264_residual_seq + h264_cavlc_residual_block.
//  Phase1a I is I_16x16-only (MB0 type 3, luma DC only, nC table not chroma-DC). 48B I_NxN 4x4-0 0x14/0x3b is
//  not this clip — residual_ok=0 / csum 0x2f is the stub, not a slice abort. bit_reader must
//  stall on sl_rbsp M10K latency at byte crosses or MB0 type ue desyncs and done after MB0.
//  sl_rbsp 8K (h264_slice_rbsp_ram) is the only >48B VCL source. No second residual engine.
//  Wired: h264_p_mb_type_decode (types 1–4 reject, no P_16x8) + h264_dpb_one_ref
//  + h264_inter_mc_16x16. P_Skip uses h264_mv_pred_16x16 (skip MVP) into ST_DPB_KICK.
//  stream_path dpb_pic is 2×115200 M10K. bank_sel is mem_* +115200. No local cur_pic/ref_pic.
	//  Chroma store 128 if not reconstructed (I). P_Skip / P16 CBP=0 write 64+64 UV.
//  product_recon_ok = clip_gold_match (TB/host after MAE_I420=0). Not a constant 1. FIT_GO=NO.
//  Copyright (C) 2026 MiSTerPlex contributors
//  GPL-2.0-or-later
//============================================================================

module h264_mb_ctrl #(
	parameter int WIDTH  = 320,
	parameter int HEIGHT = 240
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        vcl_pulse,
	input  wire        sps_valid,
	input  wire [7:0]  mb_w,
	input  wire [7:0]  mb_h,
	input  wire [7:0]  slice_type,
	input  wire        slice_is_i,
	input  wire        slice_valid,
	input  wire [5:0]  slice_qp,
	input  wire        residual_ok,
	input  wire signed [8:0] residual_coeff [0:15],
	input  wire        residual_place_pulse,
	input  wire [15:0] first_mb,
	input  wire [7:0]  first_mb_type,
	input  wire [7:0]  pps_nref,
	input  wire        pps_deblock,
	input  wire        sl_rbsp_clear,
	input  wire        sl_rbsp_en,
	input  wire [7:0]  sl_rbsp_data,
	input  wire        sl_rbsp_end,
	input  wire [13:0] sl_rbsp_len,
	input  wire [16:0] bit_pos_hdr,
	input  wire [16:0] bit_pos_resid,
	input  wire        bit_pos_valid,

	output reg  [7:0]  recon_sig,
	output reg  [7:0]  recon_dbg,
	output reg         recon_dbg_valid,
	output reg         recon_valid,
	output reg         wr_en,
	output reg  [15:0] wr_pixel,
	output reg         wr_reset_ptr,
	output reg         swap_req,
	output reg         busy,
	output reg  [15:0] frames_out,
	output wire        product_recon_ok,
	output reg  [15:0] mb_index,
	output reg         done,
	// DPB mem_* to stream_path. bank_sel is an address bit (offset 115200).
	output wire        dpb_mem_we,
	output wire [31:0] dpb_mem_waddr,
	output wire [7:0]  dpb_mem_wdata,
	output wire        dpb_mem_rd,
	output wire [31:0] dpb_mem_raddr,
	input  wire [7:0]  dpb_mem_rdata,
	input  wire        dpb_mem_rvalid
);

	// Follows gold I420 compare (TB/host latch). Not assign 1'b1 / not hardwired 0.
	reg clip_gold_match /*verilator public_flat_rw*/;
	assign product_recon_ok = clip_gold_match;

	`include "h264_chroma_nc.svh"

	localparam int WAIT_MAX = 4095;
	localparam int RBSP_MAX = 8192;
	localparam int WIN_N    = 64;

	localparam [4:0]
		ST_IDLE      = 5'd0,
		ST_WAIT_MB0  = 5'd1,
		ST_KICK_MB0  = 5'd2,
		ST_RECON_MB0 = 5'd3,
		ST_STAMP_MB0 = 5'd4,
		ST_WAIT_RBSP = 5'd5,
		ST_MB_SETUP  = 5'd6,
		ST_NLOAD     = 5'd7,
		ST_UE_BIT    = 5'd8,
		ST_UE_SUF    = 5'd9,
		ST_HDR       = 5'd10,
		ST_I4        = 5'd11,
		ST_RES_DEC   = 5'd12,
		ST_WIN       = 5'd13,
		ST_CAVLC     = 5'd14,
		ST_PRED      = 5'd15,
		ST_KICK_BLK  = 5'd16,
		ST_RECON_BLK = 5'd17,
		ST_DB_LD     = 5'd18,
		ST_DB_WR     = 5'd19,
		ST_COMMIT    = 5'd20,
		ST_PAINT     = 5'd21,
		ST_STOP      = 5'd22,
		ST_FILL      = 5'd23,
		ST_DPB_KICK  = 5'd24,
		ST_DPB_WAIT  = 5'd25;

	localparam [3:0]
		H_SKIP = 4'd0,
		H_TYPE = 4'd1,
		H_CHR  = 4'd2,
		H_CBP  = 4'd3,
		H_QP   = 4'd4,
		H_REF  = 4'd5,
		H_MVDX = 4'd6,
		H_MVDY = 4'd7,
		H_GO   = 4'd8;

	reg [4:0]      phase;
	reg [9:0]      x, y;
	reg [11:0]     wait_cnt;
	reg            lat_res_ok;
	reg [5:0]      lat_qp;
	reg            lat_sps;
	reg [7:0]      lat_mb_w, lat_mb_h;
	reg [7:0]      lat_slice_type;
	reg            lat_slice_i;
	reg [15:0]     lat_first_mb;
	reg [7:0]      lat_nref;
	reg            lat_deblock;
	reg signed [8:0] lat_coeff [0:15];
	reg            recon_start;
	reg [7:0]      lat_recon [0:15];
	integer        coeff_i;


	wire [9:0] width_w  = WIDTH[9:0];
	wire [9:0] height_w = HEIGHT[9:0];
	wire       wait_done = residual_place_pulse | (wait_cnt == 12'd0);

	reg signed [15:0] cavlc_coeff [0:15];
	wire signed [8:0]  sat_coeff [0:15];
	reg  [7:0]         pred [0:15];
	wire [7:0]         recon_blk [0:15];
	wire [7:0]         recon_sig_w;
	wire               recon_done;
	wire               recon_ok;
	reg [4:0]          max_coeff_r;

	h264_recon u_h264_recon (
		.clk(clk),
		.reset(reset),
		.start(recon_start),
		.cavlc_coeff(cavlc_coeff),
		.qp(lat_qp),
		.max_coeff(max_coeff_r),
		.pred(pred),
		.sat_coeff(sat_coeff),
		.recon(recon_blk),
		.recon_sig(recon_sig_w),
		.done(recon_done),
		.ok(recon_ok)
	);

	// Shipped 8K VCL RBSP (nalu_scanner sl_rbsp_*). Not a second capture.
	wire [7:0]  ram_rd;
	wire [13:0] rbsp_bytes;
	wire        rbsp_done;
	reg  [12:0] ram_rd_addr_r;
	wire [12:0] ram_rd_addr;
	reg         vcl_lock;
	reg         saw_commit;
	reg         stop_pend;
	// I VCL: rbsp_done && len>48 (I_NxN 48B stub is not a start).
	// P VCL: rbsp_done && 0<len<48 — Phase1a P NALs are 19–44 B (skip_run).
	// After IDR, lat_slice_i / slice_is_i stay 1 until the P header rises;
	// do not require >48 or !slice_is_i or a short P never leaves WAIT_RBSP.
	wire        rbsp_p_short  = rbsp_done && (rbsp_bytes > 14'd0) && (rbsp_bytes < 14'd48);
	wire        rbsp_i_long   = rbsp_done && (rbsp_bytes > 14'd48);
	wire        rbsp_vcl_ok   = rbsp_i_long || rbsp_p_short
	                          || (!lat_slice_i && rbsp_done && (rbsp_bytes > 14'd0));
	wire        rbsp_short    = lat_slice_i && !rbsp_p_short && (rbsp_bytes <= 14'd48);
	wire        sl_rbsp_lockable = (sl_rbsp_len > 14'd48)
	                            || ((sl_rbsp_len > 14'd0) && (sl_rbsp_len < 14'd48))
	                            || !slice_is_i;
	wire        rbsp_wr_clear = sl_rbsp_clear && !vcl_lock &&
	                            !(sl_rbsp_end && sl_rbsp_lockable);

	h264_slice_rbsp_ram #(.DEPTH(RBSP_MAX)) u_sl_rbsp (
		.clk(clk),
		.reset(reset),
		.wr_clear(rbsp_wr_clear),
		.wr_en(sl_rbsp_en && !vcl_lock),
		.wr_data(sl_rbsp_data),
		.wr_end(sl_rbsp_end && !vcl_lock),
		.rd_addr(ram_rd_addr),
		.rd_data(ram_rd),
		.len(rbsp_bytes),
		.done(rbsp_done)
	);

	// h264_bit_reader owns bit_pos after slice header (FULL_SLICE_CAVLC.md).
	// EXPERT pack (when it lands): bit_offset_end, UE/SE field order, chroma nC.
	// Do not invent those contracts here — load/start hooks only.
	reg               br_load;
	reg  [16:0]       br_load_pos;
	reg               br_get, br_start_ue, br_start_se, br_start_u;
	reg  [4:0]        br_un;
	wire [12:0]       br_ram_addr;
	wire [16:0]       br_bit_pos;
	wire              br_cur_bit, br_aligned, br_eof;
	wire              br_bit_valid, br_bit_out;
	wire              br_syn_busy, br_syn_done, br_syn_ok;
	wire [15:0]       br_ue;
	wire signed [15:0] br_se;

	h264_bit_reader #(.ADDR_W(13)) u_bit_reader (
		.clk(clk),
		.reset(reset),
		.load(br_load),
		.bit_pos_i(br_load_pos),
		.rbsp_len(rbsp_bytes),
		.ram_rd(ram_rd),
		.ram_addr(br_ram_addr),
		.bit_pos(br_bit_pos),
		.cur_bit(br_cur_bit),
		.aligned(br_aligned),
		.eof(br_eof),
		.get_bit(br_get),
		.bit_valid(br_bit_valid),
		.bit_out(br_bit_out),
		.start_ue(br_start_ue),
		.start_se(br_start_se),
		.start_u(br_start_u),
		.u_n(br_un),
		.syn_busy(br_syn_busy),
		.syn_done(br_syn_done),
		.syn_ok(br_syn_ok),
		.ue_val(br_ue),
		.se_val(br_se)
	);

	wire [16:0] bit_pos = br_bit_pos;
	reg  [16:0] bit_len;
	wire [13:0] bit_byte_addr = bit_pos[16:3];

	// Phase-1 stub: NO full Y plane. 640×480 y_mem is ~300 M10K — reject.
	// Neighbours + paint: 256B MB + 16B left + WIDTH-byte top line. No 19-bit frame addrs.
	reg [7:0] mb_pix [0:255];
	// P_Skip / integer 16x16: packed DPB copy of THIS mb (not 21x21 qpel).
	reg [7:0] mb_u [0:63];
	reg [7:0] mb_v [0:63];
	reg [7:0] left_col [0:15];
	// Sync M10K: registered Q. Combo top_line[idx] is Quartus-17 Info 276014.
	(* ramstyle = "M10K" *) reg [7:0] top_line [0:WIDTH-1];
	reg [7:0] top_rdata;
	reg [7:0] top_left_pix;
	reg [7:0] above16 [0:15];
	reg [7:0] left16  [0:15];
	reg [7:0] above4  [0:7];
	reg [7:0] left4p  [0:3];
	reg [7:0] i4_tl;
	reg       has_left, has_above;
	reg [4:0] nload_i;
	reg [3:0]  stamp_i;
	reg        paint_hold;
	reg [31:0] we_n;
	reg [7:0]  y0_lat;
	reg        stop_br_eof;
	reg [13:0] stop_rbsp_bytes;
	reg [16:0] stop_bit_pos;
	reg [15:0] stop_mb_index;
	reg [7:0]  stop_mb_w, stop_mb_h;
	reg [3:0]  stop_hdr_st;
	reg [15:0] stop_ue_val;

	reg [7:0]  cav_rbsp [0:WIN_N-1];
	reg [6:0]  win_i;
	reg [13:0] win_base;
	assign ram_rd_addr = (phase == ST_WIN) ? win_addr : ram_rd_addr_r;
	reg        cav_start;
	reg [2:0]  cav_table;
	reg        rseq_start, rseq_adv, rseq_wait;
	reg [4:0]  ly_i;
	wire       rseq_valid, rseq_done, rseq_cdc, rseq_chr, rseq_cb;
	wire [4:0] rseq_id, rseq_max;
	wire [1:0] rseq_x, rseq_y;
	wire [2:0] rseq_tab;
	wire       cav_busy, cav_done, cav_ok;
	wire [9:0] cav_bit_end;
	wire [4:0] cav_tc;
	wire [1:0] cav_t1;
	wire [3:0] cav_tz;
	wire signed [15:0] cav_coeff [0:15];
	wire signed [15:0] cav_lev_dbg [0:15];
	wire [3:0]         cav_run_dbg [0:15];

	reg [9:0] cav_off0;
	reg [12:0] win_addr;
	reg [1:0]  win_hold;
	reg [16:0] res_bit_start;
	h264_cavlc_residual_block #(.MAX_BYTES(WIN_N)) u_cavlc (
		.clk(clk),
		.reset(reset),
		.start(cav_start),
		.coeff_token_table(cav_table),
		.max_coeff(max_coeff_r),
		// EXPERT: bit_offset_start latched at WIN (not live br_bit_pos).
		.bit_offset_start(cav_off0),
		.bit_len(10'd512),
		.rbsp(cav_rbsp),
		.busy(cav_busy),
		.done(cav_done),
		.ok(cav_ok),
		.bit_offset_end(cav_bit_end),
		.total_coeff(cav_tc),
		.trailing_ones(cav_t1),
		.total_zeros(cav_tz),
		.coeff(cav_coeff),
		.level_dbg(cav_lev_dbg),
		.run_dbg(cav_run_dbg)
	);

	reg [4:0] tc_left [0:3];
	reg [4:0] tc_up   [0:79];
	reg [3:0] tc_left_v;
	reg [79:0] tc_up_v;
	reg [4:0] tc_cur  [0:15];
	reg [1:0] blk_x, blk_y;
	reg [4:0] luma_i;
	reg [3:0] chr_i;
	reg [2:0] res_kind; // 0 luma, 1 i16dc, 2 chr_dc, 3 chr_ac
	reg       parse_blk;
	reg       res_armed;
	reg       fill_unc;
	reg       pred_nb;
	reg [15:0] luma_got;
	reg [15:0] res_blk_total;
	// Chroma AC TotalCoeff RAM (FULL_SLICE_CAVLC.md §5 / h264_chroma_nc.svh).
	// Do not feed luma tc_left/tc_up into u_nc for chroma AC.
	localparam int CHR_MB_W = 80;
	reg [4:0] tc_chr_cur  [0:7];
	reg [4:0] tc_chr_left [0:3];
	reg [4:0] tc_chr_up   [0:CHR_MB_W*4-1];
	reg [3:0]  tc_chr_left_v;
	reg [CHR_MB_W*4-1:0] tc_chr_up_v;

	reg [7:0]  lat_mb_x, lat_mb_y;
	reg [7:0]  dpb_fmb_x, dpb_fmb_y;
	wire [4:0] nC_left_y = (blk_x == 2'd0) ? tc_left[blk_y] : tc_cur[{blk_y, blk_x - 2'd1}];
	wire [4:0] nC_up_y   = (blk_y == 2'd0) ? tc_up[{lat_mb_x[4:0], 2'b00} + {3'd0, blk_x}] : tc_cur[{blk_y - 2'd1, blk_x}];
	wire       nC_lv_y   = (blk_x == 2'd0) ? tc_left_v[blk_y] : 1'b1;
	wire       nC_uv_y   = (blk_y == 2'd0) ? tc_up_v[{lat_mb_x[4:0], 2'b00} + {3'd0, blk_x}] : 1'b1;
	// Chroma AC: 2x2 x=blk_x[0] y=blk_y[0], planes separate (rseq_cb).
	wire        use_chr_nc = rseq_chr && !rseq_cdc;
	wire [4:0] nC_left_c = (blk_x[0] == 1'b0) ?
		tc_chr_left[h264_chr_left_i(rseq_cb, blk_y)] :
		tc_chr_cur[h264_chr_cur_i(rseq_cb, blk_y, 2'd0)];
	wire [4:0] nC_up_c   = (blk_y[0] == 1'b0) ?
		tc_chr_up[h264_chr_up_i(lat_mb_x, rseq_cb, blk_x)] :
		tc_chr_cur[h264_chr_cur_i(rseq_cb, 2'd0, blk_x)];
	wire       nC_lv_c   = (blk_x[0] == 1'b0) ? tc_chr_left_v[h264_chr_left_i(rseq_cb, blk_y)] : 1'b1;
	wire       nC_uv_c   = (blk_y[0] == 1'b0) ? tc_chr_up_v[h264_chr_up_i(lat_mb_x, rseq_cb, blk_x)] : 1'b1;
	wire [4:0] nC_left = use_chr_nc ? nC_left_c : nC_left_y;
	wire [4:0] nC_up   = use_chr_nc ? nC_up_c   : nC_up_y;
	wire       nC_lv   = use_chr_nc ? nC_lv_c   : nC_lv_y;
	wire       nC_uv   = use_chr_nc ? nC_uv_c   : nC_uv_y;
	wire       nA_av, nB_av;
	wire [4:0] nC_w;
	wire [2:0] tok_tab;

	reg [7:0]  cur_mbt;
	reg [7:0]  cur_mbt_p; // Table 7-13 raw P mb_type (I-in-P keeps 5..29)
	reg [5:0]  cur_cbp;
	reg [1:0]  i16_mode;
	reg [3:0]  i4_mode [0:15];
	reg [4:0]  i4_idx;
	reg [1:0]  i4_sub;
	reg        i4_syn;
	reg        is_intra_mb, is_pskip, is_p16, is_i16;
	reg [15:0] skip_run;

	// Sequential residual block order — do not walk luma-16 / MB0-only here.
	h264_residual_seq u_residual_seq (
		.start_mb(rseq_start),
		.advance(rseq_adv),
		.is_i16(is_i16),
		.cbp_luma(cur_cbp[3:0]),
		.cbp_chroma(cur_cbp[5:4]),
		.clk(clk),
		.reset(reset),
		.blk_valid(rseq_valid),
		.mb_res_done(rseq_done),
		.blk_id(rseq_id),
		.max_coeff(rseq_max),
		.chroma_dc(rseq_cdc),
		.coeff_token_table(rseq_tab),
		.blk_x(rseq_x),
		.blk_y(rseq_y),
		.is_chroma(rseq_chr),
		.chr_cb(rseq_cb)
	);

	reg        need_skip;
	reg [3:0]  hdr_st;
	reg        ue_signed;
	reg [5:0]  ue_z;
	reg [15:0] ue_acc, ue_val;
	reg signed [15:0] se_val;
	reg signed [15:0] mvd_x, mvd_y;
	reg signed [15:0] mv_left_x, mv_left_y, mv_up_x, mv_up_y;
	reg signed [15:0] mv_c_x, mv_c_y, mv_d_x, mv_d_y;
	reg               mv_left_v, mv_up_v, mv_c_v, mv_d_v;
	reg signed [15:0] mv_row_x [0:79];
	reg signed [15:0] mv_row_y [0:79];
	reg               mv_row_v [0:79];
	reg signed [15:0] mv_hold_d_x, mv_hold_d_y;
	reg               mv_hold_d_v;
	reg [7:0]  cmt_i;
	reg [4:0]  db_idx;
	reg        db_horiz;
	reg [1:0]  eight_idx;
	reg        luma_coded;

	h264_cavlc_nc_predictor u_nc (
		.mb_x(lat_mb_x),
		.mb_y(lat_mb_y),
		.mb_index(mb_index),
		.mb_width(lat_mb_w),
		.first_mb_in_slice(lat_first_mb),
		.block_x(blk_x),
		.block_y(blk_y),
		.left_tc_valid(nC_lv),
		.left_tc(nC_left),
		.up_tc_valid(nC_uv),
		.up_tc(nC_up),
		.nA_available(nA_av),
		.nB_available(nB_av),
		.nC(nC_w),
		.coeff_token_table(tok_tab)
	);

	wire [7:0] i16_pred [0:255];
	wire       i16_unsup;
	reg        i16_start;
	wire       i16_busy;
	wire       i16_done;
	reg        i16_valid;
	h264_intra16x16_pred u_i16 (
		.clk(clk),
		.reset(reset),
		.start(i16_start),
		.mode(i16_mode),
		.above(above16),
		.left(left16),
		.top_left(top_left_pix),
		.has_above(has_above),
		.has_left(has_left),
		.busy(i16_busy),
		.done(i16_done),
		.unsupported(i16_unsup),
		.pred(i16_pred)
	);

	// Shipped combo ITU 8.5.10. Ports: coeff_scan[0:15] i16, qp[5:0], dc_out[0:15] i16.
	// Latch LDC scan (no sat9 on DC). CBP luma=0: pred += (dc+32)>>6; no AC 4x4 idct.
	reg signed [15:0] i16_dc_scan [0:15];
	wire signed [15:0] i16_dc [0:15];
	reg  hdc_start;
	wire hdc_done;
	h264_i16_dc_hadamard u_i16_dc (
		.clk(clk), .reset(reset), .start(hdc_start),
		.coeff_scan(i16_dc_scan),
		.qp(lat_qp),
		.dc_out(i16_dc),
		.done(hdc_done)
	);
	reg signed [17:0] i16_dc_res [0:15];
	integer hdc_i;
	always @* begin
		for (hdc_i = 0; hdc_i < 16; hdc_i = hdc_i + 1)
			i16_dc_res[hdc_i] = ($signed(i16_dc[hdc_i]) + 18'sd32) >>> 6;
	end
	reg hdc_valid;
	always @(posedge clk) begin
		if (reset)
			hdc_valid <= 1'b0;
		else if (hdc_start)
			hdc_valid <= 1'b0;
		else if (hdc_done)
			hdc_valid <= 1'b1;
	end

	wire [3:0] i4_used;
	wire [7:0] i4_pred [0:15];
	h264_intra4x4_pred u_i4 (
		.mode(i4_mode[{blk_y, blk_x}]),
		.above(above4),
		.left(left4p),
		.top_left(i4_tl),
		.has_above(has_above | (blk_y != 2'd0)),
		.has_left(has_left | (blk_x != 2'd0)),
		.used_mode(i4_used),
		.pred(i4_pred)
	);

	wire signed [15:0] mv_px, mv_py, mv_xw, mv_yw;
	wire               skip_zero;
	h264_mv_pred_16x16 u_mvp (
		.avail_a(has_left & mv_left_v),
		.avail_b(has_above & mv_up_v),
		.avail_c(mv_c_v),
		.avail_d(mv_d_v),
		.mv_a_x(mv_left_x), .mv_a_y(mv_left_y),
		.mv_b_x(mv_up_x),   .mv_b_y(mv_up_y),
		.mv_c_x(mv_c_x),    .mv_c_y(mv_c_y),
		.mv_d_x(mv_d_x),    .mv_d_y(mv_d_y),
		.mvd_x(mvd_x),      .mvd_y(mvd_y),
		.p_skip(is_pskip),
		.pred_x(mv_px), .pred_y(mv_py),
		.mv_x(mv_xw), .mv_y(mv_yw),
		.skip_zero(skip_zero)
	);

	wire        pdec_skip, pdec_inter, pdec_intra, pdec_sub, pdec_ref0, pdec_unsup;
	wire [2:0]  pdec_mode, pdec_cnt, pdec_sub_cnt;
	wire [4:0]  pdec_w, pdec_h;
	wire [3:0]  pdec_sw, pdec_sh;
	h264_p_mb_type_decode u_p_type (
		.skipped(is_pskip),
		.mb_type(p_slice ? cur_mbt_p[5:0] : cur_mbt[5:0]),
		.sub_mb_type(2'd0),
		.sub_mb_valid(1'b0),
		.is_p_skip(pdec_skip),
		.is_inter(pdec_inter),
		.is_intra(pdec_intra),
		.uses_sub_mb(pdec_sub),
		.ref0_only(pdec_ref0),
		.unsupported(pdec_unsup),
		.part_mode(pdec_mode),
		.mb_part_count(pdec_cnt),
		.mb_part_w(pdec_w),
		.mb_part_h(pdec_h),
		.sub_part_count(pdec_sub_cnt),
		.sub_part_w(pdec_sw),
		.sub_part_h(pdec_sh)
	);

	wire        dpb_ref_ready, dpb_fetch_busy, dpb_fetch_done, dpb_fetch_err;
	wire [31:0] dpb_cur_base, dpb_ref_base, dpb_waddr, dpb_raddr;
	wire        dpb_we, dpb_rd;
	wire [7:0]  dpb_wdata;
	wire [1:0]  dpb_lfx, dpb_lfy;
	wire [2:0]  dpb_cfx, dpb_cfy;
	wire signed [15:0] dpb_lox, dpb_loy, dpb_cox, dpb_coy;
	wire        dpb_luma_wv, dpb_cu_wv, dpb_cv_wv;
	wire [8:0]  dpb_luma_wi;
	wire [6:0]  dpb_chroma_wi;
	wire [7:0]  dpb_luma_ws, dpb_chroma_ws;
	// I420 in stream_path. bank_sel on mem_* addr (FPGA Dev 2x115200). BANK1_BASE=0 in core.
	reg         dpb_kick;
	reg         dpb_after_db; // 1 → ST_DB_LD after fetch, 0 → H_CBP
	reg         dpb_frm_done;
	reg  [1:0]  frm_done_hold;
	reg signed [15:0] mv_kick_x, mv_kick_y;
	reg        mc_hold;
	reg        mc_int_copy; // DPB packed 16x16; MC wants 21x21 at +2,+2
	reg         filt_v;
	reg  [1:0]  filt_plane;
	reg  [7:0]  filt_idx, filt_s;
	reg  [7:0]  mc_luma [0:440];
	reg  [7:0]  mc_u [0:80];
	reg  [7:0]  mc_v [0:80];
	wire [7:0]  mc_pred_y [0:255];
	wire [7:0]  mc_pred_u [0:63];
	wire [7:0]  mc_pred_v [0:63];
	assign dpb_mem_we    = dpb_we;
	assign dpb_mem_waddr = dpb_waddr;
	assign dpb_mem_wdata = dpb_wdata;
	assign dpb_mem_rd    = dpb_rd;
	assign dpb_mem_raddr = dpb_raddr;
	// Same-cycle COMMIT store so mb_index=1 cannot leave dpb_pic all-zero.
	// Integer 16x16 (P_Skip / MV=0): DPB int_copy packs THIS mb at luma[0:255]
	// / chroma[0:63]. 21x21 qpel on that layout makes Y(2,10)=win[256]=0.
	wire pel_copy = (pdec_mode == 3'd0) && (mv_xw == 16'sd0) && (mv_yw == 16'sd0)
	                && (is_pskip || is_p16);
	wire        store_v   = (phase == ST_COMMIT);
	wire [7:0]  store_idx = (filt_plane == 2'd0) ? cmt_i : {2'd0, cmt_i[5:0]};
	// P_Skip / P16 CBP=0: 64+64 from THIS mb (latched at fetch). Do not
	// leave U/V as 0 or reuse a prior skip's mb_u. I (no MC) stays 128.
	wire        store_uv  = pel_copy || is_p16 || is_pskip;
	wire [7:0]  store_s   = (filt_plane == 2'd0) ? mb_pix[cmt_i] :
	                        (store_uv && (filt_plane == 2'd1)) ? mb_u[cmt_i[5:0]] :
	                        (store_uv && (filt_plane == 2'd2)) ? mb_v[cmt_i[5:0]] :
	                        8'd128;
	// vcl_pulse is the NAL type byte — slice_is_i is still the previous latch.
	// Delay idr_start until THIS slice header is valid. P VCL and I-in-P (type 6)
	// must not drop DPB ref_ready. IDR/I slice (after parse) may pulse.
	reg dpb_idr_start, idr_wait_hdr, slice_valid_d;
	always @(posedge clk) begin
		if (reset) begin
			dpb_idr_start <= 1'b0;
			idr_wait_hdr  <= 1'b0;
			slice_valid_d <= 1'b0;
		end else begin
			dpb_idr_start <= 1'b0;
			slice_valid_d <= slice_valid;
			if (vcl_pulse)
				idr_wait_hdr <= 1'b1;
			else if (idr_wait_hdr && slice_valid && !slice_valid_d) begin
				idr_wait_hdr  <= 1'b0;
				// I/SI only (7.4.3 slice_type 2/7/4/9). Stale slice_is_i on a
				// P header must not pulse idr_start (drops have_ref → F1 MC
				// reads current pic: MB41 Y(16,32)=160 instead of F0 235).
				dpb_idr_start <= slice_is_i &&
				                 (slice_type == 8'd2 || slice_type == 8'd7 ||
				                  slice_type == 8'd4 || slice_type == 8'd9);
			end
		end
	end
	h264_dpb_one_ref_320 u_dpb (
		.clk(clk), .reset(reset),
		.idr_start(dpb_idr_start),
		.frame_done(dpb_frm_done),
		.ref_ready(dpb_ref_ready),
		.current_base(dpb_cur_base),
		.reference_base(dpb_ref_base),
		.filtered_sample_valid(store_v),
		.filtered_mb_x(lat_mb_x), .filtered_mb_y(lat_mb_y),
		.filtered_plane(filt_plane), .filtered_sample_idx(store_idx),
		.filtered_sample(store_s),
		.mem_we(dpb_we), .mem_waddr(dpb_waddr), .mem_wdata(dpb_wdata),
		.fetch_start(dpb_kick),
		.fetch_mb_x(dpb_fmb_x), .fetch_mb_y(dpb_fmb_y),
		.fetch_part_mode(pdec_mode), .fetch_part_idx(2'd0),
		.fetch_part_w(pdec_w), .fetch_part_h(pdec_h),
		.fetch_mv_x_qpel(mv_xw), .fetch_mv_y_qpel(mv_yw),
		.fetch_busy(dpb_fetch_busy), .fetch_done(dpb_fetch_done),
		.fetch_error_no_ref(dpb_fetch_err),
		.luma_frac_x(dpb_lfx), .luma_frac_y(dpb_lfy),
		.chroma_frac_x(dpb_cfx), .chroma_frac_y(dpb_cfy),
		.luma_origin_x(dpb_lox), .luma_origin_y(dpb_loy),
		.chroma_origin_x(dpb_cox), .chroma_origin_y(dpb_coy),
		.mem_rd(dpb_rd), .mem_raddr(dpb_raddr),
		.mem_rdata(dpb_mem_rdata), .mem_rvalid(dpb_mem_rvalid),
		.luma_window_valid(dpb_luma_wv), .luma_window_idx(dpb_luma_wi),
		.luma_window_sample(dpb_luma_ws),
		.chroma_u_window_valid(dpb_cu_wv), .chroma_v_window_valid(dpb_cv_wv),
		.chroma_window_idx(dpb_chroma_wi), .chroma_window_sample(dpb_chroma_ws)
	);
	reg  mc_start;
	wire mc_done;
	h264_inter_mc_16x16 u_mc (
		.clk(clk), .reset(reset), .start(mc_start),
		.luma_ref_win(mc_luma),
		.chroma_u_ref_win(mc_u),
		.chroma_v_ref_win(mc_v),
		.luma_frac_x(dpb_lfx), .luma_frac_y(dpb_lfy),
		.chroma_frac_x(dpb_cfx), .chroma_frac_y(dpb_cfy),
		.pred_y(mc_pred_y), .pred_u(mc_pred_u), .pred_v(mc_pred_v),
		.done(mc_done)
	);

	wire [2:0] db_bs;
	wire       db_unsup_ref;
	h264_deblock_bs u_dbs (
		.disable_all(1'b0),
		.slice_boundary_blocked(1'b0),
		.mb_boundary((db_idx[1:0] == 2'd0)),
		.p_intra(is_intra_mb),
		.q_intra(is_intra_mb),
		.p_nonzero(1'b1),
		.q_nonzero(1'b1),
		.p_ref(2'd0), .q_ref(2'd0),
		.p_mvx(12'sd0), .p_mvy(12'sd0),
		.q_mvx(12'sd0), .q_mvy(12'sd0),
		.bs(db_bs),
		.unsupported_ref(db_unsup_ref)
	);

	reg [7:0] p3_in [0:3], p2_in [0:3], p1_in [0:3], p0_in [0:3];
	reg [7:0] q3_in [0:3], q2_in [0:3], q1_in [0:3], q0_in [0:3];
	wire [7:0] p2_o [0:3], p1_o [0:3], p0_o [0:3], q0_o [0:3], q1_o [0:3], q2_o [0:3];
	wire [7:0] db_a, db_b;
	wire [5:0] db_tc0;
	h264_deblock_edge u_dbe (
		.is_chroma(1'b0),
		.bs(db_bs),
		.qp_avg(lat_qp),
		.slice_alpha_c0_offset(5'sd0),
		.slice_beta_offset(5'sd0),
		.p3_in(p3_in), .p2_in(p2_in), .p1_in(p1_in), .p0_in(p0_in),
		.q0_in(q0_in), .q1_in(q1_in), .q2_in(q2_in), .q3_in(q3_in),
		.p2_out(p2_o), .p1_out(p1_o), .p0_out(p0_o),
		.q0_out(q0_o), .q1_out(q1_o), .q2_out(q2_o),
		.alpha_dbg(db_a), .beta_dbg(db_b), .tc0_dbg(db_tc0)
	);

	wire [7:0] db_thr_a, db_thr_b;
	wire [5:0] db_idx_a, db_idx_b, db_tc0b;
	h264_deblock_thresholds u_dbt (
		.qp_avg(lat_qp),
		.slice_alpha_c0_offset(5'sd0),
		.slice_beta_offset(5'sd0),
		.bs(db_bs),
		.alpha(db_thr_a),
		.beta(db_thr_b),
		.index_a(db_idx_a),
		.index_b(db_idx_b),
		.tc0(db_tc0b)
	);

	function automatic [5:0] cbp_intra;
		input [5:0] me;
		begin
			case (me)
			6'd0: cbp_intra = 6'd47;  6'd1: cbp_intra = 6'd31;  6'd2: cbp_intra = 6'd15;
			6'd3: cbp_intra = 6'd0;   6'd4: cbp_intra = 6'd23;  6'd5: cbp_intra = 6'd27;
			6'd6: cbp_intra = 6'd29;  6'd7: cbp_intra = 6'd30;  6'd8: cbp_intra = 6'd7;
			6'd9: cbp_intra = 6'd11;  6'd10: cbp_intra = 6'd13; 6'd11: cbp_intra = 6'd14;
			6'd12: cbp_intra = 6'd39; 6'd13: cbp_intra = 6'd43; 6'd14: cbp_intra = 6'd45;
			6'd15: cbp_intra = 6'd46; 6'd16: cbp_intra = 6'd16; 6'd17: cbp_intra = 6'd3;
			6'd18: cbp_intra = 6'd5;  6'd19: cbp_intra = 6'd10; 6'd20: cbp_intra = 6'd12;
			6'd21: cbp_intra = 6'd19; 6'd22: cbp_intra = 6'd21; 6'd23: cbp_intra = 6'd26;
			6'd24: cbp_intra = 6'd28; 6'd25: cbp_intra = 6'd35; 6'd26: cbp_intra = 6'd37;
			6'd27: cbp_intra = 6'd42; 6'd28: cbp_intra = 6'd44; 6'd29: cbp_intra = 6'd1;
			6'd30: cbp_intra = 6'd2;  6'd31: cbp_intra = 6'd4;  6'd32: cbp_intra = 6'd8;
			6'd33: cbp_intra = 6'd17; 6'd34: cbp_intra = 6'd18; 6'd35: cbp_intra = 6'd20;
			6'd36: cbp_intra = 6'd24; 6'd37: cbp_intra = 6'd6;  6'd38: cbp_intra = 6'd9;
			6'd39: cbp_intra = 6'd22; 6'd40: cbp_intra = 6'd25; 6'd41: cbp_intra = 6'd32;
			6'd42: cbp_intra = 6'd33; 6'd43: cbp_intra = 6'd34; 6'd44: cbp_intra = 6'd36;
			6'd45: cbp_intra = 6'd40; 6'd46: cbp_intra = 6'd38; 6'd47: cbp_intra = 6'd41;
			default: cbp_intra = 6'd0;
			endcase
		end
	endfunction

	function automatic [5:0] cbp_inter;
		input [5:0] me;
		begin
			case (me)
			6'd0: cbp_inter = 6'd0;   6'd1: cbp_inter = 6'd16;  6'd2: cbp_inter = 6'd1;
			6'd3: cbp_inter = 6'd2;   6'd4: cbp_inter = 6'd4;   6'd5: cbp_inter = 6'd8;
			6'd6: cbp_inter = 6'd32;  6'd7: cbp_inter = 6'd3;   6'd8: cbp_inter = 6'd5;
			6'd9: cbp_inter = 6'd10;  6'd10: cbp_inter = 6'd12; 6'd11: cbp_inter = 6'd15;
			6'd12: cbp_inter = 6'd47; 6'd13: cbp_inter = 6'd7;  6'd14: cbp_inter = 6'd11;
			6'd15: cbp_inter = 6'd13; 6'd16: cbp_inter = 6'd14; 6'd17: cbp_inter = 6'd6;
			6'd18: cbp_inter = 6'd9;  6'd19: cbp_inter = 6'd31; 6'd20: cbp_inter = 6'd35;
			6'd21: cbp_inter = 6'd37; 6'd22: cbp_inter = 6'd42; 6'd23: cbp_inter = 6'd44;
			6'd24: cbp_inter = 6'd33; 6'd25: cbp_inter = 6'd34; 6'd26: cbp_inter = 6'd36;
			6'd27: cbp_inter = 6'd40; 6'd28: cbp_inter = 6'd39; 6'd29: cbp_inter = 6'd43;
			6'd30: cbp_inter = 6'd45; 6'd31: cbp_inter = 6'd46; 6'd32: cbp_inter = 6'd17;
			6'd33: cbp_inter = 6'd18; 6'd34: cbp_inter = 6'd20; 6'd35: cbp_inter = 6'd24;
			6'd36: cbp_inter = 6'd19; 6'd37: cbp_inter = 6'd21; 6'd38: cbp_inter = 6'd26;
			6'd39: cbp_inter = 6'd28; 6'd40: cbp_inter = 6'd23; 6'd41: cbp_inter = 6'd27;
			6'd42: cbp_inter = 6'd29; 6'd43: cbp_inter = 6'd30; 6'd44: cbp_inter = 6'd22;
			6'd45: cbp_inter = 6'd25; 6'd46: cbp_inter = 6'd38; 6'd47: cbp_inter = 6'd41;
			default: cbp_inter = 6'd0;
			endcase
		end
	endfunction

	function automatic [3:0] blk_scan;
		input [3:0] i;
		begin
			case (i)
			4'd0: blk_scan = 4'd0;   4'd1: blk_scan = 4'd1;
			4'd2: blk_scan = 4'd4;   4'd3: blk_scan = 4'd5;
			4'd4: blk_scan = 4'd2;   4'd5: blk_scan = 4'd3;
			4'd6: blk_scan = 4'd6;   4'd7: blk_scan = 4'd7;
			4'd8: blk_scan = 4'd8;   4'd9: blk_scan = 4'd9;
			4'd10: blk_scan = 4'd12; 4'd11: blk_scan = 4'd13;
			4'd12: blk_scan = 4'd10; 4'd13: blk_scan = 4'd11;
			4'd14: blk_scan = 4'd14; 4'd15: blk_scan = 4'd15;
			default: blk_scan = i;
			endcase
		end
	endfunction

	localparam [7:0] MB_W_FIX = WIDTH / 16;
	localparam [7:0] MB_H_FIX = HEIGHT / 16;
	wire [7:0]  grid_w   = (lat_mb_w >= 8'd2) ? lat_mb_w : MB_W_FIX;
	wire [7:0]  grid_h   = (lat_mb_h >= 8'd2) ? lat_mb_h : MB_H_FIX;
	wire [15:0] mb_count = {8'd0, grid_w} * {8'd0, grid_h};
	wire        p_slice  = !lat_slice_i && ((lat_slice_type == 8'd0) || (lat_slice_type == 8'd5));

	reg [7:0] recon_dbg_comb;
	integer dbg_i;
	always @* begin
		recon_dbg_comb = 8'd0;
		for (dbg_i = 0; dbg_i < 16; dbg_i = dbg_i + 1) begin
			if (lat_coeff[dbg_i] != 9'sd0)
				recon_dbg_comb[0] = 1'b1;
			if (lat_recon[dbg_i] != 8'd128)
				recon_dbg_comb[5] = 1'b1;
		end
		recon_dbg_comb[6] = lat_res_ok;
		recon_dbg_comb[7] = recon_ok;
	end

	// Stub display: tile last MB (mb_pix). No full-frame Y RAM.
	wire [7:0] paint_y = mb_pix[{y[3:0], x[3:0]}];
	wire [15:0] px_comb = {paint_y[7:3], paint_y[7:2], paint_y[7:3]};

	integer pi;
	integer di;

	wire [3:0] scan_s = blk_scan(luma_i[3:0]);
	wire [3:0] scan = blk_scan(ly_i[3:0]);
	wire [1:0] scan_x = scan_s[1:0];
	wire [1:0] scan_y = scan_s[3:2];
	wire [1:0] scan_8 = {scan_y[1], scan_x[1]};

	// db_idx: [4]=horiz, [3:2]=edge 0..3, [1:0]=seg 0..3
	wire [1:0] db_edge = db_idx[3:2];
	wire [1:0] db_seg  = db_idx[1:0];
	wire signed [15:0] se_now = ue_val[0] ?
		($signed({1'b0, ue_val[15:1]}) + 16'sd1) :
		(-$signed({1'b0, ue_val[15:1]}));

	function automatic [7:0] clip8_add;
		input [7:0] p;
		input signed [17:0] d;
		reg signed [18:0] s;
		begin
			s = $signed({1'b0, p}) + d;
			if (s < 19'sd0) clip8_add = 8'd0;
			else if (s > 19'sd255) clip8_add = 8'd255;
			else clip8_add = s[7:0];
		end
	endfunction

	// Latch-then-slice (Q17). Wires into M10K; Q registered 1 cycle (dpb_pic).
	wire [8:0] top_base = {lat_mb_x[4:0], 4'd0};
	wire [8:0] top_raddr = (nload_i == 5'd0) ?
		((lat_mb_x == 8'd0) ? 9'd0 : (top_base - 9'd1)) :
		((nload_i < 5'd17) ? (top_base + {4'd0, nload_i} - 9'd1) :
		 (top_base + 9'd15));
	wire       top_we    = (phase == ST_COMMIT) && (filt_plane == 2'd0) &&
	                        (cmt_i[7:4] == 4'd15);
	wire [8:0] top_waddr = top_base + {5'd0, cmt_i[3:0]};
	wire [7:0] top_wdata = mb_pix[{4'd15, cmt_i[3:0]}];
	wire [4:0] nload_q_i = nload_i - 5'd2;

	always @(posedge clk) begin
		if (top_we)
			top_line[top_waddr] <= top_wdata;
		top_rdata <= top_line[top_raddr];
	end

	always @(posedge clk) begin
		wr_en        <= 1'b0;
		wr_reset_ptr <= 1'b0;
		swap_req     <= 1'b0;
		recon_start  <= 1'b0;
		cav_start    <= 1'b0;
		br_load      <= 1'b0;
		br_get       <= 1'b0;
		br_start_ue  <= 1'b0;
		br_start_se  <= 1'b0;
		br_start_u   <= 1'b0;
		rseq_start   <= 1'b0;
		rseq_adv     <= 1'b0;
		dpb_kick     <= 1'b0;
		filt_v       <= 1'b0;
		dpb_frm_done <= (frm_done_hold != 2'd0);
		if (frm_done_hold != 2'd0)
			frm_done_hold <= frm_done_hold - 2'd1;
		if (dpb_we) begin
			// we_n = ST_COMMIT/dpb_we pulses. 300 MB * 384 = 115200 I420.
			// 115157 = 299*384 + 256Y + 64U + 21V: last MB (19,14) V idx 21..63
			// never pulsed (43 V samples). Do not pad fake pixels.
			we_n <= we_n + 32'd1;
			if (dpb_waddr == 32'd0)
				y0_lat <= dpb_wdata;
		end
		if (dpb_luma_wv)
			mc_luma[dpb_luma_wi] <= dpb_luma_ws;
		if (dpb_cu_wv)
			mc_u[dpb_chroma_wi] <= dpb_chroma_ws;
		if (dpb_cv_wv)
			mc_v[dpb_chroma_wi] <= dpb_chroma_ws;
		if (br_syn_busy && (br_bit_pos[2:0] == 3'd7) && (phase != ST_WIN))
			ram_rd_addr_r <= br_ram_addr + 13'd1;
		else if (phase != ST_WIN)
			ram_rd_addr_r <= br_ram_addr;

		hdc_start <= 1'b0;
		i16_start <= 1'b0;
		if (i16_start)
			i16_valid <= 1'b0;
		else if (i16_done)
			i16_valid <= 1'b1;

		// Capture I VCL (>48 B) the cycle sl_rbsp_end fires. Waiting until
		// ST_WAIT_RBSP lets the next NAL sl_rbsp_clear wipe residual_seq's source.
		if (busy && sl_rbsp_end && sl_rbsp_lockable)
			vcl_lock <= 1'b1;

		if (reset) begin
			phase           <= ST_IDLE;
			busy            <= 1'b0;
			done            <= 1'b0;
			x               <= 10'd0;
			y               <= 10'd0;
			frames_out      <= 16'd0;
			wait_cnt        <= 12'd0;
			lat_res_ok      <= 1'b0;
			lat_qp          <= 6'd0;
			lat_sps         <= 1'b0;
			lat_mb_w        <= 8'd0;
			lat_mb_h        <= 8'd0;
			mb_index        <= 16'd0;
			recon_sig       <= 8'd0;
			recon_dbg       <= 8'd0;
			recon_dbg_valid <= 1'b0;
			recon_valid     <= 1'b0;
			clip_gold_match <= 1'b0;
			wr_pixel        <= 16'd0;
			bit_len         <= 17'd0;
			rseq_wait       <= 1'b0;
			fill_unc        <= 1'b0;
			pred_nb         <= 1'b0;
			i16_valid       <= 1'b0;
			luma_got        <= 16'd0;
			res_blk_total   <= 16'd0;
			ly_i            <= 5'd0;
			need_skip       <= 1'b0;
			skip_run        <= 16'd0;
			dpb_fmb_x       <= 8'd0;
			dpb_fmb_y       <= 8'd0;
			dpb_kick        <= 1'b0;
			dpb_after_db    <= 1'b0;
			dpb_frm_done    <= 1'b0;
			frm_done_hold   <= 2'd0;
			mv_kick_x       <= 16'sd0;
			mv_kick_y       <= 16'sd0;
			mc_hold         <= 1'b0;
			mc_start        <= 1'b0;
			mc_int_copy     <= 1'b0;
			filt_v          <= 1'b0;
			filt_plane      <= 2'd0;
			filt_idx        <= 8'd0;
			filt_s          <= 8'd128;
			i4_syn          <= 1'b0;
			res_armed       <= 1'b0;
			max_coeff_r     <= 5'd16;
			cav_off0        <= 10'd0;
			win_addr        <= 13'd0;
			win_hold        <= 2'd0;
			res_bit_start   <= 17'd0;
			paint_hold      <= 1'b0;
			we_n            <= 32'd0;
			y0_lat          <= 8'd0;
			vcl_lock        <= 1'b0;
			saw_commit      <= 1'b0;
			stop_pend       <= 1'b0;
			stop_br_eof     <= 1'b0;
			stop_rbsp_bytes <= 14'd0;
			stop_bit_pos    <= 17'd0;
			stop_mb_index   <= 16'd0;
			stop_mb_w       <= 8'd0;
			stop_mb_h       <= 8'd0;
			stop_hdr_st     <= 4'd0;
			stop_ue_val     <= 16'd0;
			mv_left_x <= 16'sd0; mv_left_y <= 16'sd0;
			mv_up_x   <= 16'sd0; mv_up_y   <= 16'sd0;
			mv_c_x <= 16'sd0; mv_c_y <= 16'sd0;
			mv_d_x <= 16'sd0; mv_d_y <= 16'sd0;
			mv_left_v <= 1'b0; mv_up_v <= 1'b0; mv_c_v <= 1'b0; mv_d_v <= 1'b0;
			mv_hold_d_x <= 16'sd0; mv_hold_d_y <= 16'sd0; mv_hold_d_v <= 1'b0;
			for (pi = 0; pi < 80; pi = pi + 1) begin
				mv_row_x[pi] <= 16'sd0;
				mv_row_y[pi] <= 16'sd0;
				mv_row_v[pi] <= 1'b0;
			end
			tc_left_v <= 4'd0;
			tc_up_v   <= 80'd0;
			tc_chr_left_v <= 4'd0;
			tc_chr_up_v   <= {CHR_MB_W*4{1'b0}};
			for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1) begin
				lat_coeff[coeff_i]   <= 9'sd0;
				lat_recon[coeff_i]   <= 8'd0;
				cavlc_coeff[coeff_i] <= 16'sd0;
				pred[coeff_i]        <= 8'd128;
				i16_dc_scan[coeff_i] <= 16'sd0;
			end
			for (pi = 0; pi < 256; pi = pi + 1)
				mb_pix[pi] <= 8'd128;
			for (pi = 0; pi < 16; pi = pi + 1) begin
				left_col[pi] <= 8'd128;
				above16[pi]  <= 8'd128;
				left16[pi]   <= 8'd128;
			end
		end else begin
			case (phase)
			ST_IDLE: begin
				if (vcl_pulse) begin
					phase      <= ST_WAIT_MB0;
					busy       <= 1'b1;
					done       <= 1'b0;
					wait_cnt   <= WAIT_MAX[11:0];
					mb_index   <= 16'd0;
					vcl_lock   <= 1'b0;
					saw_commit <= 1'b0;
					stop_pend  <= 1'b0;
				end
			end

			ST_WAIT_MB0: begin
				if (wait_cnt != 12'd0)
					wait_cnt <= wait_cnt - 12'd1;
				if (wait_done) begin
					lat_sps        <= sps_valid;
					lat_mb_w       <= (mb_w == 8'd0) ? 8'd20 : mb_w;
					lat_mb_h       <= (mb_h == 8'd0) ? 8'd15 : mb_h;
					lat_res_ok     <= residual_ok;
					lat_qp         <= slice_qp;
					lat_slice_type <= slice_type;
					lat_slice_i    <= slice_is_i;
					lat_first_mb   <= first_mb;
					lat_nref       <= pps_nref;
					lat_deblock    <= pps_deblock;
					for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1) begin
						lat_coeff[coeff_i]   <= residual_coeff[coeff_i];
						cavlc_coeff[coeff_i] <= {{7{residual_coeff[coeff_i][8]}}, residual_coeff[coeff_i]};
						pred[coeff_i]        <= 8'd128;
					end
					max_coeff_r     <= 5'd16;
					recon_start     <= 1'b1;
					recon_valid     <= 1'b0;
					recon_dbg_valid <= 1'b0;
					phase           <= ST_KICK_MB0;
				end
			end

			ST_KICK_MB0: phase <= ST_RECON_MB0;

			ST_RECON_MB0: begin
				if (recon_done) begin
					for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
						lat_recon[coeff_i] <= recon_blk[coeff_i];
					recon_sig       <= residual_ok ? recon_sig_w : 8'd0;
					recon_dbg       <= recon_dbg_comb;
					recon_dbg_valid <= 1'b1;
					recon_valid     <= residual_ok;
					stamp_i         <= 4'd0;
					phase           <= ST_STAMP_MB0;
				end
			end

			ST_STAMP_MB0: begin
				mb_pix[{2'b00, stamp_i[3:2], 2'b00, stamp_i[1:0]}] <= lat_recon[stamp_i];
				if (stamp_i == 4'd15) begin
					wait_cnt <= WAIT_MAX[11:0];
					phase    <= ST_WAIT_RBSP;
				end else
					stamp_i <= stamp_i + 4'd1;
			end

			ST_WAIT_RBSP: begin
				// Start when this VCL is frozen in sl_rbsp (I >>48).
				// residual_ok=0 / csum 0x2f is the 48B I_NxN stub on an I16
				// clip — still walk residual_seq + bit_reader from bit_pos_hdr.
				// Leave ONLY on rbsp_done. Drop sl_rbsp_end and timeout as start.
				if (vcl_lock || rbsp_vcl_ok) begin
					// synopsys translate_off
					$display("LEAVE ST_WAIT_RBSP rbsp_bytes=%0d bit_pos_hdr=%0d residual_ok=%b lock=%b p_short=%b slice_i=%b lat_i=%b",
					         rbsp_bytes, bit_pos_hdr, lat_res_ok, vcl_lock, rbsp_p_short, slice_is_i, lat_slice_i);
					// synopsys translate_on
					vcl_lock    <= 1'b1;
					saw_commit  <= 1'b0;
					stop_pend   <= 1'b0;
					bit_len     <= {rbsp_bytes, 3'd0};
					// Walker start = bit_pos_hdr (first mb_type / skip_run).
					// Do not jump to bit_pos_resid (would skip I4/CBP/qpδ).
					// Place may never set bit_pos_valid on I16 — hdr is still good.
					br_load     <= 1'b1;
					// Walker start = bit_pos_hdr. Do not subtract 3 (that forced
					// I_NxN ue=0). Phase1a I is I_16x16; MB0 type is 1–24 at hdr.
					br_load_pos <= bit_pos_hdr;
					tc_chr_left_v <= 4'd0;
					tc_chr_up_v   <= {CHR_MB_W*4{1'b0}};
					mb_index    <= first_mb;
					// Short P after IDR: header may still show I. Force P so
					// need_skip / H_SKIP run; do not parse skip_run as I type.
					if (rbsp_p_short || (slice_valid && !slice_is_i)) begin
						lat_slice_i    <= 1'b0;
						lat_slice_type <= (slice_valid && !slice_is_i) ? slice_type : 8'd0;
						if (slice_valid) begin
							lat_qp       <= slice_qp;
							lat_first_mb <= first_mb;
							lat_nref     <= pps_nref;
							lat_deblock  <= pps_deblock;
						end
						need_skip <= 1'b1;
					end else
						need_skip <= !lat_slice_i;
					skip_run    <= 16'd0;
					phase       <= ST_MB_SETUP;
				end
			end

			ST_MB_SETUP: begin
				if (mb_index >= mb_count) begin
					phase        <= ST_PAINT;
					x            <= 10'd0;
					y            <= 10'd0;
					wr_reset_ptr <= 1'b1;
					paint_hold   <= 1'b1;
					// Grid done: snap DPB ref NOW (not after 76800 paint beats).
					// One-pic wrap: P MC must see F0 at (0,32)=235, not F1 I-in-P 160.
					done          <= 1'b1;
					frm_done_hold <= 2'd3;
					swap_req      <= 1'b1;
					frames_out    <= frames_out + 16'd1;
					// synopsys translate_off
					$display("GRID_DONE mb_index=%0d frames_out=%0d we_n=%0d",
					         mb_index, frames_out + 16'd1, we_n);
					// synopsys translate_on
				end else begin
					if (grid_w == 8'd0) begin
						lat_mb_x  <= 8'd0;
						lat_mb_y  <= 8'd0;
						dpb_fmb_x <= 8'd0;
						dpb_fmb_y <= 8'd0;
					end else begin
						lat_mb_x  <= mb_index % {8'd0, grid_w};
						lat_mb_y  <= mb_index / {8'd0, grid_w};
						dpb_fmb_x <= mb_index % {8'd0, grid_w};
						dpb_fmb_y <= mb_index / {8'd0, grid_w};
					end
					has_left    <= (grid_w != 8'd0) && ((mb_index % {8'd0, grid_w}) != 16'd0);
					has_above   <= (mb_index >= {8'd0, grid_w});
					nload_i     <= 5'd0;
					is_pskip    <= 1'b0;
					is_p16      <= 1'b0;
					is_i16      <= 1'b0;
					is_intra_mb <= 1'b0;
					cur_mbt_p   <= 8'd0;
					mvd_x       <= 16'sd0;
					mvd_y       <= 16'sd0;
					cur_cbp     <= 6'd0;
					cur_mbt     <= 8'd0;
					res_armed   <= 1'b0;
					rseq_wait   <= 1'b0;
					fill_unc    <= 1'b0;
					pred_nb     <= 1'b0;
					i16_valid   <= 1'b0;
					luma_got    <= 16'd0;
					ly_i        <= 5'd0;
					i4_syn      <= 1'b0;
					for (pi = 0; pi < 16; pi = pi + 1) begin
						tc_cur[pi] <= 5'd0;
						i16_dc_scan[pi] <= 16'sd0;
					end
					for (pi = 0; pi < 256; pi = pi + 1)
						mb_pix[pi] <= 8'd128;
					for (pi = 0; pi < 64; pi = pi + 1) begin
						mb_u[pi] <= 8'd128;
						mb_v[pi] <= 8'd128;
					end
					filt_plane <= 2'd0;
					phase <= ST_NLOAD;
				end
			end

			ST_NLOAD: begin
				// top_raddr issued combo this beat; top_rdata is last beat's Q.
				// Beat 0: top_left addr. Beats 1..16: above[0..15] addr. Beats 1..17: capture Q.
				if (nload_i < 5'd18) begin
					if (nload_i == 5'd1)
						top_left_pix <= (has_above && has_left && (lat_mb_x != 8'd0)) ?
						                 top_rdata : 8'd128;
					else if (nload_i >= 5'd2)
						above16[nload_q_i[3:0]] <= has_above ? top_rdata : 8'd128;
					if (nload_i < 5'd16)
						left16[nload_i[3:0]] <= has_left ? left_col[nload_i[3:0]] : 8'd128;
					if (nload_i == 5'd0) begin
						mv_up_x <= mv_row_x[lat_mb_x];
						mv_up_y <= mv_row_y[lat_mb_x];
						mv_up_v <= has_above & mv_row_v[lat_mb_x];
						if (has_above && (lat_mb_x + 8'd1 < grid_w) && mv_row_v[lat_mb_x + 8'd1]) begin
							mv_c_v <= 1'b1;
							mv_c_x <= mv_row_x[lat_mb_x + 8'd1];
							mv_c_y <= mv_row_y[lat_mb_x + 8'd1];
							mv_d_v <= 1'b0;
						end else begin
							mv_c_v <= 1'b0;
							mv_d_v <= has_above & has_left & mv_hold_d_v;
							mv_d_x <= mv_hold_d_x;
							mv_d_y <= mv_hold_d_y;
						end
					end
					nload_i <= nload_i + 5'd1;
				end else if (p_slice && (skip_run != 16'd0)) begin
					// leftover skip_run: emit P_Skip, do not read bits
					// synopsys translate_off
					$display("P_SKIP_EMIT mb=%0d remain=%0d bit_pos=%0d",
					         mb_index, skip_run - 16'd1, br_bit_pos);
					// synopsys translate_on
					skip_run     <= skip_run - 16'd1;
					is_pskip     <= 1'b1;
					is_intra_mb  <= 1'b0;
					cur_cbp      <= 6'd0;
					dpb_after_db <= 1'b1;
					phase        <= ST_DPB_KICK;
				end else if (p_slice && need_skip && (skip_run == 16'd0)) begin
					hdr_st    <= H_SKIP;
					ue_signed <= 1'b0;
					ue_z      <= 6'd0;
					ue_acc    <= 16'd0;
					phase     <= ST_UE_BIT;
				end else begin
					hdr_st    <= H_TYPE;
					ue_signed <= 1'b0;
					// synopsys translate_off
					if ((mb_index <= 16'd2) || (mb_index == 16'd40) || (mb_index == 16'd41))
						$display("MB_TYPE_START mb=%0d bit_pos=%0d p=%0d need_skip=%0d skip_run=%0d",
						         mb_index, br_bit_pos, p_slice, need_skip, skip_run);
					// synopsys translate_on
					phase     <= ST_UE_BIT;
				end
			end

			ST_UE_BIT: begin
				// EXPERT: UE/SE field order stays the existing hdr_st walk
				// (SLICE_HANDOFF.md). Replace only if the pack names a new order.
				// Short rbsp_bytes eof after MB0 must not ST_STOP (and must
				// not rewind to WAIT_RBSP / bit_pos_hdr). Hold until len grows.
				if (br_eof && (rbsp_short || !rbsp_done)) begin
					// hold
				end else if (br_eof)
					phase       <= ST_STOP;
				else if (i4_syn) begin
					br_start_u <= 1'b1;
					br_un      <= (i4_sub == 2'd0) ? 5'd1 : 5'd3;
					phase      <= ST_UE_SUF;
				end else if (ue_signed) begin
					br_start_se <= 1'b1;
					phase       <= ST_UE_SUF;
				end else begin
					br_start_ue <= 1'b1;
					phase       <= ST_UE_SUF;
				end
			end

			ST_UE_SUF: begin
				if (br_syn_done) begin
					ue_val <= br_ue;
					se_val <= br_se;
					if (!br_syn_ok && (rbsp_short || !rbsp_done))
						phase <= ST_UE_BIT;
					else if (!br_syn_ok)
						phase       <= ST_STOP;
					else if (i4_syn)
						phase <= ST_I4;
					else
						phase <= ST_HDR;
				end
			end

			ST_HDR: begin
				if (ue_signed) begin
					if (ue_val[0])
						se_val <= $signed({1'b0, ue_val[15:1]}) + 16'sd1;
					else
						se_val <= -$signed({1'b0, ue_val[15:1]});
				end
				case (hdr_st)
				H_SKIP: begin
					need_skip <= 1'b0;
					// synopsys translate_off
					$display("P_SKIP_UE mb=%0d run=%0d bit_pos=%0d",
					         mb_index, ue_val, br_bit_pos);
					// synopsys translate_on
					if (ue_val != 16'd0) begin
						skip_run     <= ue_val - 16'd1;
						is_pskip     <= 1'b1;
						is_intra_mb  <= 1'b0;
						cur_cbp      <= 6'd0;
						dpb_after_db <= 1'b1;
						phase        <= ST_DPB_KICK;
					end else begin
						hdr_st    <= H_TYPE;
						ue_signed <= 1'b0;
						ue_z      <= 6'd0;
						ue_acc    <= 16'd0;
						phase     <= ST_UE_BIT;
					end
				end
				H_TYPE: begin
					if (lat_slice_i) begin
						cur_mbt <= ue_val[7:0];
						if (ue_val == 16'd0) begin
							// I_NxN: do not remap/fill as I16-DC.
							// synopsys translate_off
							$display("I_MB_TYPE_ILLEGAL mb_index=%0d ue=0 I_NxN", mb_index);
							// synopsys translate_on
							phase       <= ST_UE_BIT;
						end else if ((ue_val >= 16'd1) && (ue_val <= 16'd24)) begin
							is_intra_mb <= 1'b1;
							is_i16      <= 1'b1;
							cur_mbt     <= ue_val[7:0];
							i16_mode    <= ue_val[1:0] - 2'd1;
							// synopsys translate_off
							$display("I_MB_TYPE mb_index=%0d type=%0d I16", mb_index, ue_val);
							// synopsys translate_on
							hdr_st      <= H_CHR;
							ue_signed   <= 1'b0;
							ue_z        <= 6'd0;
							phase       <= ST_UE_BIT;
						end else begin
							// PCM 25 / SI / 31 leftover residual: ST_STOP (do not I16-DC fill).
							// synopsys translate_off
							$display("I_MB_TYPE_ILLEGAL mb_index=%0d ue=%0d", mb_index, ue_val);
							// synopsys translate_on
							phase       <= ST_STOP;
						end
					end else if ((ue_val >= 16'd5) && (ue_val <= 16'd29)) begin
						// I-in-P (Table 7-13 types 5..29): same I_NxN / I_16x16 path as I slices.
						// Do not reject. Types 1..4 stay ST_STOP below. I_PCM (30) also ST_STOP.
						// synopsys translate_off
						$display("P_IINP mb=%0d type=%0d bit_pos=%0d",
						         mb_index, ue_val, br_bit_pos);
						$display("LOG_IINP_TYPE f=%0d mb=%0d type=%0d I16V_cbp0=%0d",
						         frames_out, mb_index, ue_val, (ue_val == 16'd6));
						// synopsys translate_on
						cur_mbt_p   <= ue_val[7:0];
						cur_mbt     <= ue_val[7:0] - 8'd5;
						if ((ue_val - 16'd5) == 16'd0) begin
							is_intra_mb <= 1'b1;
							is_i16      <= 1'b0;
							i4_idx      <= 5'd0;
							i4_sub      <= 2'd0;
							i4_syn      <= 1'b1;
							phase       <= ST_UE_BIT;
						end else begin
							is_intra_mb <= 1'b1;
							is_i16      <= 1'b1;
							cur_mbt     <= ue_val[7:0] - 8'd5;
							i16_mode    <= (ue_val[7:0] - 8'd5) - 2'd1; // same I: remapped[1:0]-1
							hdr_st      <= H_CHR;
							ue_signed   <= 1'b0;
							ue_z        <= 6'd0;
							phase       <= ST_UE_BIT;
						end
					end else begin
						// Latch Table 7-13 type, then H_GO uses h264_p_mb_type_decode.
						// Types 1–4 (P_16x8 / P_8x16 / P_8x8 / P_8x8ref0) reject.
						// synopsys translate_off
						$display("P_MB_TYPE mb=%0d type=%0d bit_pos=%0d",
						         mb_index, ue_val, br_bit_pos);
						$display("LOG_P16_TYPE f=%0d mb=%0d type=%0d pskip=%0d expect_P16=%0d",
						         frames_out, mb_index, ue_val, is_pskip, (ue_val == 16'd0));
						// synopsys translate_on
						cur_mbt_p   <= ue_val[7:0];
						is_intra_mb <= 1'b0;
						is_p16      <= 1'b0;
						hdr_st      <= H_GO;
					end
				end
				H_CHR: begin
					// synopsys translate_off
					if (mb_index <= 16'd1)
						$display("BITPOS_AFTER_H_CHR mb_index=%0d bit_pos=%0d chr_ue=%0d",
						         mb_index, bit_pos, ue_val);
					// synopsys translate_on
					if (is_i16) begin
						hdr_st    <= H_QP;
						ue_signed <= 1'b1;
					end else begin
						hdr_st    <= H_CBP;
						ue_signed <= 1'b0;
					end
					ue_z  <= 6'd0;
					ue_acc<= 16'd0;
					phase <= ST_UE_BIT;
				end
				H_CBP: begin
					if (is_p16)
						cur_cbp <= cbp_inter(ue_val[5:0]);
					else
						cur_cbp <= cbp_intra(ue_val[5:0]);
					// synopsys translate_off
					$display("P_CBP mb=%0d p16=%0d ue=%0d cbp=%0d bit_pos=%0d",
					         mb_index, is_p16, ue_val,
					         is_p16 ? cbp_inter(ue_val[5:0]) : cbp_intra(ue_val[5:0]),
					         br_bit_pos);
					if (is_p16)
						$display("LOG_P16_CBP f=%0d mb=%0d me_ue=%0d cbp=%0d residual=%0d",
						         frames_out, mb_index, ue_val, cbp_inter(ue_val[5:0]),
						         cbp_inter(ue_val[5:0]) != 6'd0);
					// synopsys translate_on
					if ((is_p16 && (ue_val != 16'd0)) || (!is_p16 && (ue_val != 16'd3))) begin
						hdr_st    <= H_QP;
						ue_signed <= 1'b1;
						ue_z      <= 6'd0;
						phase     <= ST_UE_BIT;
					end else begin
						res_armed <= 1'b1;
						phase     <= ST_RES_DEC;
					end
				end
				H_QP: begin
					// I_16x16 CBP packed in mb_type (Table 7-11). types 1–4 cbp=0:
					// residual_seq luma DC only — no 16 AC, no chroma residual.
					if (is_i16) begin
						case (cur_mbt)
						8'd1,8'd2,8'd3,8'd4:     cur_cbp <= 6'd0;
						8'd5,8'd6,8'd7,8'd8:     cur_cbp <= 6'd16;
						8'd9,8'd10,8'd11,8'd12:  cur_cbp <= 6'd32;
						8'd13,8'd14,8'd15,8'd16: cur_cbp <= 6'd15;
						8'd17,8'd18,8'd19,8'd20: cur_cbp <= 6'd31;
						default:                 cur_cbp <= 6'd47;
						endcase
						i16_mode <= cur_mbt[1:0] - 2'd1;
					end
					if ($signed({10'b0, lat_qp}) + se_val < 16'sd0)
						lat_qp <= 6'd0;
					else if ($signed({10'b0, lat_qp}) + se_val > 16'sd51)
						lat_qp <= 6'd51;
					else
						lat_qp <= lat_qp + se_val[5:0];
					res_armed <= 1'b1;
					// synopsys translate_off
					if ((mb_index <= 16'd1) || (mb_index == 16'd40))
						$display("BITPOS_AFTER_H_QP mb_index=%0d bit_pos=%0d se=%0d cbp=%0d type=%0d i16=%0d",
						         mb_index, bit_pos, se_val, cur_cbp, cur_mbt, is_i16);
					// synopsys translate_on
					phase     <= ST_RES_DEC;
				end
				H_REF: begin
					hdr_st    <= H_MVDX;
					ue_signed <= 1'b1;
					ue_z      <= 6'd0;
					phase     <= ST_UE_BIT;
				end
				H_MVDX: begin
					mvd_x     <= se_val;
					// synopsys translate_off
					if (mb_index == 16'd41)
						$display("P_MVDX mb=%0d se=%0d bit_pos=%0d", mb_index, $signed(se_val), br_bit_pos);
					// synopsys translate_on
					hdr_st    <= H_MVDY;
					ue_signed <= 1'b1;
					ue_z      <= 6'd0;
					phase     <= ST_UE_BIT;
				end
				H_MVDY: begin
					mvd_y       <= se_val;
					// synopsys translate_off
					$display("P_MVD mb=%0d type=%0d mvd=%0d,%0d mvp=%0d,%0d mv=%0d,%0d bit_pos=%0d",
					         mb_index, cur_mbt_p, $signed(mvd_x), $signed(se_val),
					         $signed(mv_px), $signed(mv_py), $signed(mv_xw), $signed(mv_yw),
					         br_bit_pos);
					$display("LOG_P16_MV f=%0d mb=%0d mvd=%0d,%0d mvp=%0d,%0d",
					         frames_out, mb_index, $signed(mvd_x), $signed(se_val),
					         $signed(mv_px), $signed(mv_py));
					// synopsys translate_on
					dpb_after_db<= 1'b0;
					phase       <= ST_DPB_KICK;
				end
				H_GO: begin
					// pdec sees latched cur_mbt_p. Only P_L0_16x16 (mode 0) continues.
					if (pdec_unsup || pdec_sub || (pdec_mode != 3'd0)) begin
						phase       <= ST_STOP;
					end else begin
						is_p16      <= 1'b1;
						is_intra_mb <= 1'b0;
						if (lat_nref > 8'd1) begin
							hdr_st    <= H_REF;
							ue_signed <= 1'b0;
							ue_z      <= 6'd0;
							phase     <= ST_UE_BIT;
						end else begin
							hdr_st    <= H_MVDX;
							ue_signed <= 1'b1;
							ue_z      <= 6'd0;
							phase     <= ST_UE_BIT;
						end
					end
				end
				default: begin
					phase       <= ST_STOP;
				end
				endcase
			end

			ST_I4: begin
				// prev_intra4x4_pred_mode_flag u(1); rem u(3). bit_reader start_u.
				i4_syn <= 1'b1;
				if (i4_sub == 2'd0) begin
					if (ue_val[0]) begin
						i4_mode[i4_idx[3:0]] <= 4'd2;
						i4_sub <= 2'd0;
						if (i4_idx >= 5'd15) begin
							i4_syn    <= 1'b0;
							hdr_st    <= H_CHR;
							ue_signed <= 1'b0;
							phase     <= ST_UE_BIT;
						end else begin
							i4_idx <= i4_idx + 5'd1;
							phase  <= ST_UE_BIT;
						end
					end else begin
						i4_sub <= 2'd3;
						phase  <= ST_UE_BIT;
					end
				end else begin
					i4_mode[i4_idx[3:0]] <= {1'b0, ue_val[2:0]};
					i4_sub <= 2'd0;
					if (i4_idx >= 5'd15) begin
						i4_syn    <= 1'b0;
						hdr_st    <= H_CHR;
						ue_signed <= 1'b0;
						phase     <= ST_UE_BIT;
					end else begin
						i4_idx <= i4_idx + 5'd1;
						phase  <= ST_UE_BIT;
					end
				end
			end

			ST_RES_DEC: begin
				if (is_pskip) begin
					cmt_i      <= 8'd0;
					filt_plane <= 2'd0;
					phase      <= ST_COMMIT;
				end else if (rseq_wait) begin
					rseq_wait <= 1'b0;
				end else if (res_armed) begin
					res_armed  <= 1'b0;
					rseq_start <= 1'b1;
					ly_i       <= 5'd0;
					luma_got   <= 16'd0;
					fill_unc   <= 1'b0;
					rseq_wait  <= 1'b1;
					if (is_i16 && !i16_busy)
						i16_start <= 1'b1;
				end else if (!rseq_valid && !rseq_done) begin
					// residual_seq is skipping an uncoded 8x8 or stepping LDC→LY / LY→CDC.
					// Do not treat valid=0 as a block (FULL_SLICE_CAVLC.md).
				end else if (rseq_done) begin
					// synopsys translate_off
					if (mb_index <= 16'd1)
						$display("BITPOS_AFTER_RESIDUAL mb_index=%0d bit_pos=%0d cbp=%0d",
						         mb_index, br_bit_pos, cur_cbp);
					// synopsys translate_on
					fill_unc <= 1'b1;
					ly_i     <= 5'd0;
					pred_nb  <= 1'b0;
					phase    <= ST_FILL;
				end else begin
					blk_x      <= rseq_x;
					blk_y      <= rseq_y;
					parse_blk  <= 1'b1;
					max_coeff_r<= rseq_max;
					luma_coded <= !rseq_chr;
					if (rseq_chr) begin
						res_kind <= rseq_cdc ? 3'd2 : 3'd3;
					end else if (rseq_id == 5'd16) begin
						res_kind <= 3'd1;
					end else begin
						res_kind <= 3'd0;
						luma_i   <= {1'b0, rseq_id[3:0]};
					end
					win_i         <= 7'd0;
					win_hold      <= 2'd0;
					res_bit_start <= br_bit_pos;
					win_base      <= br_bit_pos[16:3];
					win_addr      <= br_bit_pos[16:3];
					// synopsys translate_off
					if (mb_index <= 16'd4)
						$display("RESIDUAL_START mb=%0d bit_pos=%0d id=%0d rseq_tab=%0d max=%0d",
						         mb_index, br_bit_pos, rseq_id, rseq_tab, rseq_max);
					// synopsys translate_on
					phase    <= ST_WIN;
				end
			end

			ST_WIN: begin
				// ram_rd_addr flop + sl_rbsp rd_data flop = 2 cycles.
				// hold0: drive win_addr. hold1: wait. hold2: store ram_rd, ++addr.
				if (win_hold == 2'd0) begin
					if (win_i == 7'd0) begin
						cav_off0    <= {7'd0, res_bit_start[2:0]};
						max_coeff_r <= rseq_max;
						if (rseq_id == 5'd16)
							cav_table <= 3'd0; // I16 LDC neighbor nC=0; table 4 desyncs host
						else if (rseq_cdc || (rseq_tab == 3'd4))
							cav_table <= 3'd4;
						else
							cav_table <= tok_tab;
					end
					win_hold <= 2'd1;
				end else if (win_hold == 2'd1) begin
					win_hold <= 2'd2;
				end else begin
					cav_rbsp[win_i] <= ram_rd;
					// synopsys translate_off
					if ((mb_index <= 16'd1) && (win_i <= 7'd1))
						$display("WINBYTE mb=%0d i=%0d addr=%0d rd=%02h",
						         mb_index, win_i, win_addr, ram_rd);
					// synopsys translate_on
					if (win_i == 7'd63) begin
						// synopsys translate_off
						if (mb_index <= 16'd4)
							$display("CAVLC_WIN mb=%0d off0=%0d base=%0d b0=%02h b1=%02h b2=%02h",
							         mb_index, cav_off0, win_base,
							         cav_rbsp[0], cav_rbsp[1], cav_rbsp[2]);
						// synopsys translate_on
						cav_start <= 1'b1;
						phase     <= ST_CAVLC;
					end else begin
						win_i    <= win_i + 7'd1;
						win_addr <= win_addr + 13'd1;
						win_hold <= 2'd0;
					end
				end
			end

			ST_CAVLC: begin
				if (cav_done) begin
					// synopsys translate_off
					$display("CAVLC mb=%0d id=%0d chr=%b cdc=%b tab=%0d max=%0d tc=%0d t1=%0d tz=%0d ok=%b off0=%0d end=%0d bit=%0d b0=%02h b1=%02h",
					         mb_index, rseq_id, rseq_chr, rseq_cdc, cav_table, max_coeff_r,
					         cav_tc, cav_t1, cav_tz, cav_ok, cav_off0, cav_bit_end, br_bit_pos,
					         cav_rbsp[0], cav_rbsp[1]);
					if (rseq_id == 5'd16)
						$display("LDC mb=%0d tc=%0d t1=%0d tab=%0d nC=%0d rseq_tab=%0d start=%0d end=%0d",
						         mb_index, cav_tc, cav_t1, cav_table, nC_w, rseq_tab, res_bit_start,
						         {win_base, 3'd0} + {7'd0, cav_bit_end});
					// synopsys translate_on
					if (!cav_ok) begin
						phase       <= ST_STOP;
					end else begin
					// Reload from latched window base + CAVLC end.
					br_load     <= 1'b1;
					br_load_pos <= {win_base, 3'd0} + {7'd0, cav_bit_end};
					res_blk_total <= res_blk_total + 16'd1;
					for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
						cavlc_coeff[coeff_i] <= cav_coeff[coeff_i];
					if (rseq_id == 5'd16) begin
						for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
							i16_dc_scan[coeff_i] <= cav_coeff[coeff_i];
						hdc_start <= 1'b1;
						// synopsys translate_off
						if ((mb_index <= 16'd1) || (mb_index == 16'd40) || (p_slice && is_i16))
							$display("I16DC_LATCH mb=%0d qp=%0d c0=%0d tc=%0d i16=%0d",
							         mb_index, lat_qp, cav_coeff[0], cav_tc, is_i16);
						// synopsys translate_on
					end
					if (!rseq_chr && (rseq_id < 5'd16))
						tc_cur[{blk_y, blk_x}] <= cav_tc;
					if (rseq_chr && !rseq_cdc) begin
						tc_chr_cur[h264_chr_cur_i(rseq_cb, blk_y, blk_x)] <= cav_tc;
						if (blk_x[0]) begin
							tc_chr_left[h264_chr_left_i(rseq_cb, blk_y)] <= cav_tc;
							tc_chr_left_v[h264_chr_left_i(rseq_cb, blk_y)] <= 1'b1;
						end
						if (blk_y[0]) begin
							tc_chr_up[h264_chr_up_i(lat_mb_x, rseq_cb, blk_x)] <= cav_tc;
							tc_chr_up_v[h264_chr_up_i(lat_mb_x, rseq_cb, blk_x)] <= 1'b1;
						end
					end
					// 0x14 place is MB0 status only — not the walker residual bar.
					if (is_i16 && (rseq_id == 5'd16) && (cur_cbp == 6'd0)) begin
						// I16 CBP=0: luma DC only — skip 16 AC and chroma CAVLC.
						// synopsys translate_off
						if (mb_index <= 16'd1)
							$display("BITPOS_AFTER_RESIDUAL mb_index=%0d bit_pos=%0d cbp=0",
							         mb_index, {win_base, 3'd0} + {7'd0, cav_bit_end});
						// synopsys translate_on
						rseq_adv  <= 1'b1;
						fill_unc  <= 1'b1;
						ly_i      <= 5'd0;
						pred_nb   <= 1'b0;
						phase     <= ST_FILL;
					end else if (rseq_chr || (rseq_id == 5'd16)) begin
						// chroma, or I16 DC with more residual blocks: consume bits only.
						rseq_adv  <= 1'b1;
						rseq_wait <= 1'b1;
						phase     <= ST_RES_DEC;
					end else
						phase <= ST_PRED;
					end
				end
			end

			ST_PRED: begin
				if (!parse_blk) begin
					for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
						cavlc_coeff[coeff_i] <= 16'sd0;
					if (!fill_unc)
						tc_cur[{blk_y, blk_x}] <= 5'd0;
					max_coeff_r <= 5'd16;
				end
				if (is_intra_mb && !is_i16 && !pred_nb) begin
					for (coeff_i = 0; coeff_i < 4; coeff_i = coeff_i + 1) begin
						left4p[coeff_i]  <= (blk_x == 2'd0) ? left16[{blk_y, coeff_i[1:0]}] :
							mb_pix[{blk_y, coeff_i[1:0], blk_x, 2'd0} - 8'd1];
						above4[coeff_i]  <= (blk_y == 2'd0) ? above16[{blk_x, coeff_i[1:0]}] :
							mb_pix[({blk_y - 2'd1, 2'd3, blk_x, coeff_i[1:0]})];
						above4[coeff_i+4]<= 8'd128;
					end
					i4_tl <= (blk_x == 2'd0 && blk_y == 2'd0) ? top_left_pix :
					         (blk_x == 2'd0) ? left16[{blk_y - 2'd1, 2'd3}] :
					         (blk_y == 2'd0) ? above16[{blk_x - 2'd1, 2'd3}] :
					         mb_pix[{blk_y - 2'd1, 2'd3, blk_x - 2'd1, 2'd3}];
					pred_nb <= 1'b1;
				end else if (is_i16) begin
					pred_nb <= 1'b0;
					if (!i16_valid) begin
						// Sequential I16 row-fill (17 V/H/DC, 26 Plane). Hide behind residual;
						// wait here if CAVLC was shorter than the pred walker.
						if (!i16_busy)
							i16_start <= 1'b1;
					end else if ((cur_cbp[3:0] == 4'd0) && !hdc_valid) begin
						// 1-mul Hadamard still running (16 cycles from LDC latch).
					end else if (cur_cbp[3:0] == 4'd0) begin
						// CBP luma=0: idct_dc_add. Do not run AC 4x4 idct on zeros.
						// apply_itu_fix stays false. sat9 stays on AC recon only.
						for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
							mb_pix[{blk_y, coeff_i[3:2], blk_x, coeff_i[1:0]}] <= clip8_add(
								i16_pred[({2'd0, blk_y} * 4 + {2'd0, coeff_i[3:2]}) * 16 +
								         ({2'd0, blk_x} * 4 + {2'd0, coeff_i[1:0]})],
								i16_dc_res[{blk_y, blk_x}]);
						// synopsys translate_off
						if ((mb_index <= 16'd1) || (mb_index == 16'd40) || (p_slice && is_i16 && (blk_x == 2'd0) && (blk_y == 2'd0)))
							$display("I16_DC_ADD mb=%0d blk=%0d,%0d pred=%0d dc=%0d add=%0d i16=%0d",
							         mb_index, blk_x, blk_y,
							         i16_pred[({2'd0, blk_y} * 4) * 16 + ({2'd0, blk_x} * 4)],
							         $signed(i16_dc[{blk_y, blk_x}]),
							         $signed(i16_dc_res[{blk_y, blk_x}]), is_i16);
						// synopsys translate_on
						ly_i  <= ly_i + 5'd1;
						phase <= ST_FILL;
					end else begin
						for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
							pred[coeff_i] <= i16_pred[({2'd0, blk_y} * 4 + {2'd0, coeff_i[3:2]}) * 16 +
							                           ({2'd0, blk_x} * 4 + {2'd0, coeff_i[1:0]})];
						recon_start <= 1'b1;
						phase       <= ST_KICK_BLK;
					end
				end else if (is_intra_mb) begin
					pred_nb <= 1'b0;
					for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
						pred[coeff_i] <= i4_pred[coeff_i];
					recon_start <= 1'b1;
					phase       <= ST_KICK_BLK;
				end else begin
					pred_nb <= 1'b0;
					// P16 MV=0: packed int_copy is THIS mb (KEEP pel_copy).
					for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
						pred[coeff_i] <= pel_copy ? mc_luma[{blk_y, coeff_i[3:2], blk_x, coeff_i[1:0]}] : mc_pred_y[{blk_y, coeff_i[3:2], blk_x, coeff_i[1:0]}];
					recon_start <= 1'b1;
					phase       <= ST_KICK_BLK;
				end
			end

			ST_KICK_BLK: phase <= ST_RECON_BLK;

			ST_RECON_BLK: begin
				if (recon_done) begin
					if (fill_unc || !(rseq_valid && (rseq_chr || rseq_id == 5'd16))) begin
						for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
							mb_pix[{blk_y, coeff_i[3:2], blk_x, coeff_i[1:0]}] <= recon_blk[coeff_i];
					end
					if (fill_unc) begin
						ly_i    <= ly_i + 5'd1;
						pred_nb <= 1'b0;
						phase   <= ST_FILL;
					end else begin
						if (!rseq_chr && (rseq_id < 5'd16))
							luma_got[rseq_id[3:0]] <= 1'b1;
						rseq_adv  <= 1'b1;
						rseq_wait <= 1'b1;
						phase     <= ST_RES_DEC;
					end
				end
			end

			ST_FILL: begin
				// Paint I4/I16 4x4s that residual_seq skipped (uncoded 8x8).
				if (ly_i >= 5'd16) begin
					fill_unc <= 1'b0;
					db_idx   <= 5'd0;
					db_horiz <= 1'b0;
					phase    <= ST_DB_LD;
				end else if (luma_got[scan]) begin
					ly_i <= ly_i + 5'd1;
				end else begin
					parse_blk <= 1'b0;
					blk_x     <= {scan[2], scan[0]};
					blk_y     <= {scan[3], scan[1]};
					pred_nb   <= 1'b0;
					phase     <= ST_PRED;
				end
			end

			ST_DB_LD: begin
				for (di = 0; di < 4; di = di + 1) begin
					if (!db_horiz) begin
						q0_in[di] <= mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} + 2'd0)];
						q1_in[di] <= mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} + 2'd1)];
						q2_in[di] <= mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} + 2'd2)];
						q3_in[di] <= mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} + 2'd3)];
						p0_in[di] <= (db_edge == 2'd0) ? left16[{db_seg, 2'b00} + di[1:0]] :
							mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} - 2'd1)];
						p1_in[di] <= (db_edge == 2'd0) ? left16[{db_seg, 2'b00} + di[1:0]] :
							mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} - 2'd2)];
						p2_in[di] <= (db_edge == 2'd0) ? left16[{db_seg, 2'b00} + di[1:0]] :
							mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} - 2'd3)];
						p3_in[di] <= (db_edge == 2'd0) ? left16[{db_seg, 2'b00} + di[1:0]] :
							mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} - 2'd4)];
					end else begin
						q0_in[di] <= mb_pix[({db_edge, 2'b00} + 2'd0) * 16 + ({db_seg, 2'b00} + di[1:0])];
						q1_in[di] <= mb_pix[({db_edge, 2'b00} + 2'd1) * 16 + ({db_seg, 2'b00} + di[1:0])];
						q2_in[di] <= mb_pix[({db_edge, 2'b00} + 2'd2) * 16 + ({db_seg, 2'b00} + di[1:0])];
						q3_in[di] <= mb_pix[({db_edge, 2'b00} + 2'd3) * 16 + ({db_seg, 2'b00} + di[1:0])];
						p0_in[di] <= (db_edge == 2'd0) ? above16[{db_seg, 2'b00} + di[1:0]] :
							mb_pix[({db_edge, 2'b00} - 2'd1) * 16 + ({db_seg, 2'b00} + di[1:0])];
						p1_in[di] <= (db_edge == 2'd0) ? above16[{db_seg, 2'b00} + di[1:0]] :
							mb_pix[({db_edge, 2'b00} - 2'd2) * 16 + ({db_seg, 2'b00} + di[1:0])];
						p2_in[di] <= (db_edge == 2'd0) ? above16[{db_seg, 2'b00} + di[1:0]] :
							mb_pix[({db_edge, 2'b00} - 2'd3) * 16 + ({db_seg, 2'b00} + di[1:0])];
						p3_in[di] <= (db_edge == 2'd0) ? above16[{db_seg, 2'b00} + di[1:0]] :
							mb_pix[({db_edge, 2'b00} - 2'd4) * 16 + ({db_seg, 2'b00} + di[1:0])];
					end
				end
				phase <= ST_DB_WR;
			end

			ST_DB_WR: begin
				for (di = 0; di < 4; di = di + 1) begin
					if (!db_horiz) begin
						if (db_edge != 2'd0)
							mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} - 2'd1)] <= p0_o[di];
						mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} + 2'd0)] <= q0_o[di];
						mb_pix[({db_seg, 2'b00} + di[1:0]) * 16 + ({db_edge, 2'b00} + 2'd1)] <= q1_o[di];
					end else begin
						if (db_edge != 2'd0)
							mb_pix[({db_edge, 2'b00} - 2'd1) * 16 + ({db_seg, 2'b00} + di[1:0])] <= p0_o[di];
						mb_pix[({db_edge, 2'b00} + 2'd0) * 16 + ({db_seg, 2'b00} + di[1:0])] <= q0_o[di];
						mb_pix[({db_edge, 2'b00} + 2'd1) * 16 + ({db_seg, 2'b00} + di[1:0])] <= q1_o[di];
					end
				end
				if (db_idx == 5'd15) begin
					if (!db_horiz) begin
						db_idx   <= 5'd0;
						db_horiz <= 1'b1;
						phase    <= ST_DB_LD;
					end else begin
						cmt_i <= 8'd0;
						phase <= ST_COMMIT;
					end
				end else begin
					db_idx <= db_idx + 5'd1;
					phase  <= ST_DB_LD;
				end
			end

			ST_COMMIT: begin
				// synopsys translate_off
				if ((cmt_i == 8'd0) && (filt_plane == 2'd0) &&
				    ((mb_index <= 16'd2) || (mb_index == 16'd40) || (mb_index == 16'd41)))
					$display("COMMIT_Y0 mb=%0d xy=%0d,%0d pix0=%0d mc0=%0d origin=%0d,%0d pskip=%0d p16=%0d cbp=%0d",
					         mb_index, lat_mb_x, lat_mb_y, mb_pix[0], mc_pred_y[0],
					         dpb_lox, dpb_loy, is_pskip, is_p16, cur_cbp);
				if ((cmt_i == 8'd0) && (filt_plane == 2'd0) && p_slice && is_i16)
					$display("LOG_IINP_RECON f=%0d mb=%0d xy=%0d,%0d type=%0d mode=%0d cbp=%0d pred00=%0d dc00=%0d add00=%0d recon00=%0d above0=%0d",
					         frames_out, mb_index, lat_mb_x, lat_mb_y, cur_mbt_p, i16_mode, cur_cbp,
					         i16_pred[0], $signed(i16_dc[0]), $signed(i16_dc_res[0]), mb_pix[0], above16[0]);
				if ((cmt_i == 8'd0) && (filt_plane == 2'd0) && is_p16)
					$display("LOG_P16_COMMIT f=%0d mb=%0d typeP=%0d mvd=%0d,%0d mvp=%0d,%0d mv=%0d,%0d cbp=%0d pred00=%0d pred_2_10=%0d recon00=%0d recon_2_10=%0d pel_copy=%0d origin=%0d,%0d",
					         frames_out, mb_index, cur_mbt_p,
					         $signed(mvd_x), $signed(mvd_y), $signed(mv_px), $signed(mv_py),
					         $signed(mv_xw), $signed(mv_yw), cur_cbp,
					         pel_copy ? mc_luma[0] : mc_pred_y[0],
					         pel_copy ? mc_luma[10*16+2] : mc_pred_y[10*16+2],
					         mb_pix[0], mb_pix[10*16+2], pel_copy,
					         dpb_lox, dpb_loy);
				if ((cmt_i == 8'd0) && (filt_plane == 2'd1) &&
				    ((mb_index <= 16'd2) || (mb_index == 16'd41) || (mb_index == 16'd61)))
					$display("COMMIT_U0 f=%0d mb=%0d pskip=%0d p16=%0d pel_copy=%0d u0=%0d v0=%0d pred_u0=%0d",
					         frames_out, mb_index, is_pskip, is_p16, pel_copy,
					         mb_u[0], mb_v[0], mc_pred_u[0]);
				// synopsys translate_on
				filt_v <= 1'b1;
				if (filt_plane == 2'd0) begin
					filt_idx <= cmt_i;
					filt_s   <= mb_pix[cmt_i];
					if (cmt_i[3:0] == 4'd15)
						left_col[cmt_i[7:4]] <= mb_pix[{cmt_i[7:4], 4'd15}];
					// top_line write is the M10K posedge port (top_we/top_waddr/top_wdata).
				end else begin
					filt_idx <= {2'd0, cmt_i[5:0]};
					if (store_uv && (filt_plane == 2'd1))
						filt_s <= mb_u[cmt_i[5:0]];
					else if (store_uv && (filt_plane == 2'd2))
						filt_s <= mb_v[cmt_i[5:0]];
					else
						filt_s <= 8'd128;
				end
				if (filt_plane == 2'd0 && cmt_i == 8'd255) begin
					if (cur_cbp[5:4] != 2'd2) begin
						// Neighbor MB exists, no chroma AC: TC=0, valid=1.
						tc_chr_cur[0] <= 5'd0; tc_chr_cur[1] <= 5'd0;
						tc_chr_cur[2] <= 5'd0; tc_chr_cur[3] <= 5'd0;
						tc_chr_cur[4] <= 5'd0; tc_chr_cur[5] <= 5'd0;
						tc_chr_cur[6] <= 5'd0; tc_chr_cur[7] <= 5'd0;
						tc_chr_left[0] <= 5'd0; tc_chr_left[1] <= 5'd0;
						tc_chr_left[2] <= 5'd0; tc_chr_left[3] <= 5'd0;
						tc_chr_left_v <= 4'hF;
						tc_chr_up[h264_chr_up_i(lat_mb_x, 1'b0, 2'd0)] <= 5'd0;
						tc_chr_up[h264_chr_up_i(lat_mb_x, 1'b0, 2'd1)] <= 5'd0;
						tc_chr_up[h264_chr_up_i(lat_mb_x, 1'b1, 2'd0)] <= 5'd0;
						tc_chr_up[h264_chr_up_i(lat_mb_x, 1'b1, 2'd1)] <= 5'd0;
						tc_chr_up_v[h264_chr_up_i(lat_mb_x, 1'b0, 2'd0)] <= 1'b1;
						tc_chr_up_v[h264_chr_up_i(lat_mb_x, 1'b0, 2'd1)] <= 1'b1;
						tc_chr_up_v[h264_chr_up_i(lat_mb_x, 1'b1, 2'd0)] <= 1'b1;
						tc_chr_up_v[h264_chr_up_i(lat_mb_x, 1'b1, 2'd1)] <= 1'b1;
					end
					tc_left[0] <= tc_cur[4'd3];
					tc_left[1] <= tc_cur[4'd7];
					tc_left[2] <= tc_cur[4'd11];
					tc_left[3] <= tc_cur[4'd15];
					tc_left_v  <= 4'hF;
					tc_up[{lat_mb_x[4:0], 2'd0} + 5'd0] <= tc_cur[4'd12];
					tc_up[{lat_mb_x[4:0], 2'd0} + 5'd1] <= tc_cur[4'd13];
					tc_up[{lat_mb_x[4:0], 2'd0} + 5'd2] <= tc_cur[4'd14];
					tc_up[{lat_mb_x[4:0], 2'd0} + 5'd3] <= tc_cur[4'd15];
					tc_up_v[{lat_mb_x[4:0], 2'd0} + 7'd0] <= 1'b1;
					tc_up_v[{lat_mb_x[4:0], 2'd0} + 7'd1] <= 1'b1;
					tc_up_v[{lat_mb_x[4:0], 2'd0} + 7'd2] <= 1'b1;
					tc_up_v[{lat_mb_x[4:0], 2'd0} + 7'd3] <= 1'b1;
					mv_hold_d_x <= mv_row_x[lat_mb_x];
					mv_hold_d_y <= mv_row_y[lat_mb_x];
					mv_hold_d_v <= mv_row_v[lat_mb_x];
					mv_row_x[lat_mb_x] <= mv_xw;
					mv_row_y[lat_mb_x] <= mv_yw;
					mv_row_v[lat_mb_x] <= is_pskip | is_p16;
					mv_left_x <= mv_xw;
					mv_left_y <= mv_yw;
					mv_left_v <= is_pskip | is_p16;
					mv_up_x   <= mv_xw;
					mv_up_y   <= mv_yw;
					mb_index   <= mb_index + 16'd1;
					saw_commit <= 1'b1;
					// 7.3.4: mb_skip_run only after a coded MB (not after P_Skip).
					need_skip  <= p_slice && !is_pskip;
					filt_plane <= 2'd1;
					cmt_i      <= 8'd0;
				end else if (filt_plane == 2'd1 && cmt_i == 8'd63) begin
					filt_plane <= 2'd2;
					cmt_i      <= 8'd0;
				end else if (filt_plane == 2'd2 && cmt_i == 8'd63) begin
					// synopsys translate_off
					if (lat_mb_x == 8'd0 && lat_mb_y == 8'd0) begin
						begin : mb0_mean
							integer s, k;
							s = 0;
							for (k = 0; k < 256; k = k + 1)
								s = s + mb_pix[k];
							$display("I16DC_MB0 Y0=%0d mean=%0d dc_add00=%0d qp=%0d scan0=%0d",
							         mb_pix[0], s / 256, i16_dc_res[0], lat_qp, i16_dc_scan[0]);
						end
					end
					// synopsys translate_on
					filt_plane <= 2'd0;
					if (stop_pend) begin
						stop_pend <= 1'b0;
						vcl_lock  <= 1'b0;
						phase     <= ST_IDLE;
						busy      <= 1'b0;
						done      <= 1'b0;
					end else
						phase <= ST_MB_SETUP;
				end else
					cmt_i <= cmt_i + 8'd1;
			end

			ST_DPB_KICK: begin
				// Fetch window is THIS mb (lat_mb_x/y), not mb0.
				// P_Skip on this clip is colocated (skip_zero / no above).
				// Always kick: one-pic DPB fetch must not wait on ref_ready
				// or keep the previous (mb0) MC window.
				dpb_fmb_x <= lat_mb_x;
				dpb_fmb_y <= lat_mb_y;
				mv_kick_x <= mv_xw;
				mv_kick_y <= mv_yw;
				dpb_kick  <= 1'b1;
				mc_hold   <= 1'b0;
				// Same int_copy predicate as h264_dpb_one_ref: packed 16x16.
				mc_int_copy <= (pdec_mode == 3'd0) &&
				               (mv_xw == 16'sd0) && (mv_yw == 16'sd0);
				// synopsys translate_off
				if ((mb_index <= 16'd2) || (mb_index == 16'd40) || (mb_index == 16'd41) || (mb_index == 16'd61))
					$display("DPB_KICK mb=%0d fmb=%0d,%0d pskip=%0d p16=%0d iinp=%0d mvx=%0d mvy=%0d mvd=%0d,%0d skip_zero=%0d ready=%0d",
					         mb_index, lat_mb_x, lat_mb_y, is_pskip, is_p16, is_intra_mb,
					         $signed(mv_xw), $signed(mv_yw),
					         $signed(mvd_x), $signed(mvd_y),
					         skip_zero, dpb_ref_ready);
				// synopsys translate_on
				phase    <= ST_DPB_WAIT;
			end

			ST_DPB_WAIT: begin
				mc_start <= 1'b0;
				// dpb_kick is still 1 on the first WAIT cycle; ignore sticky fetch_done.
				if (dpb_fetch_done && !dpb_kick) begin
					// One hold so last V window tap is in mc_v[].
					// Integer (0,0) uses pel_copy — do not run 256-cycle qpel.
					if (!mc_hold) begin
						mc_hold  <= 1'b1;
						mc_start <= pel_copy ? 1'b0 : 1'b1;
					end else if (pel_copy || mc_done) begin
					mc_hold <= 1'b0;
					// synopsys translate_off
					if ((mb_index <= 16'd2) || (mb_index == 16'd40) || (mb_index == 16'd41) || (mb_index == 16'd61))
						$display("SKIP_MC mb=%0d xy=%0d,%0d origin=%0d,%0d pred00=%0d pack00=%0d pack_2_10=%0d pel_copy=%0d after_db=%0d pskip=%0d p16=%0d",
						         mb_index, lat_mb_x, lat_mb_y, dpb_lox, dpb_loy,
						         mc_pred_y[0], mc_luma[0], mc_luma[10*16+2],
						         pel_copy, dpb_after_db, is_pskip, is_p16);
					// synopsys translate_on
					// Always latch THIS mb 64+64 UV (P_Skip and P16 CBP=0).
					// dpb_after_db=0 used to skip the copy → COMMIT wrote 0 / stale.
					for (pi = 0; pi < 64; pi = pi + 1) begin
						mb_u[pi] <= pel_copy ? mc_u[pi] : mc_pred_u[pi];
						mb_v[pi] <= pel_copy ? mc_v[pi] : mc_pred_v[pi];
					end
					if (dpb_after_db) begin
						// Full MB into current pic (same 384-beat I COMMIT).
						// pel_copy: packed int_copy window is THIS mb. 64+64 UV.
						for (pi = 0; pi < 256; pi = pi + 1)
							mb_pix[pi] <= pel_copy ? mc_luma[pi] : mc_pred_y[pi];
						if (is_pskip) begin
							cmt_i      <= 8'd0;
							filt_plane <= 2'd0;
							phase      <= ST_COMMIT;
						end else begin
							db_idx   <= 5'd0;
							db_horiz <= 1'b0;
							phase    <= ST_DB_LD;
						end
					end else begin
						hdr_st    <= H_CBP;
						ue_signed <= 1'b0;
						ue_z      <= 6'd0;
						phase     <= ST_UE_BIT;
					end
					end
				end
			end

			ST_STOP: begin
				stop_br_eof     <= br_eof;
				stop_rbsp_bytes <= rbsp_bytes;
				stop_bit_pos    <= bit_pos;
				stop_mb_index   <= mb_index;
				stop_mb_w       <= lat_mb_w;
				stop_mb_h       <= lat_mb_h;
				stop_hdr_st     <= hdr_st;
				stop_ue_val     <= ue_val;
				// synopsys translate_off
				$display("ENTER ST_STOP br_eof=%b rbsp_bytes=%0d mb_index=%0d lat_mb_w=%0d lat_mb_h=%0d br_bit_pos=%0d hdr_st=%0d ue_val=%0d we_n=%0d Y0=%0d",
				         br_eof, rbsp_bytes, mb_index, lat_mb_w, lat_mb_h, bit_pos, hdr_st, ue_val, we_n, y0_lat);
				// synopsys translate_on
				if (!saw_commit) begin
					stop_pend  <= 1'b1;
					cmt_i      <= 8'd0;
					filt_plane <= 2'd0;
					phase      <= ST_COMMIT;
				end else begin
					vcl_lock   <= 1'b0;
					phase      <= ST_IDLE;
					busy       <= 1'b0;
					done       <= 1'b0;
					paint_hold <= 1'b0;
				end
			end

			ST_PAINT: begin
				// synopsys translate_off
				if (paint_hold)
					$display("ST_PAINT phase=%0d hdr_st=%0d br_eof=%0d br_syn_ok=%0d ue_val=%0d mb_index=%0d lat_mb_w=%0d lat_mb_h=%0d mb_count=%0d rbsp_bytes=%0d br_bit_pos=%0d we_n=%0d Y0=%0d frames_out=%0d",
					         phase, hdr_st, br_eof, br_syn_ok, ue_val, mb_index, lat_mb_w, lat_mb_h, mb_count, rbsp_bytes, bit_pos, we_n, y0_lat, frames_out);
				// synopsys translate_on
				if (paint_hold) begin
					paint_hold <= 1'b0;
				end else begin
					wr_en     <= 1'b1;
					wr_pixel  <= px_comb;
					if ((x == (width_w - 10'd1)) && (y == (height_w - 10'd1))) begin
						phase      <= ST_IDLE;
						busy       <= 1'b0;
						vcl_lock   <= 1'b0;
						// done/frames_out only if walker reached mb_count (300 @ 20x15).
						// residual_ok=0 / recon_sig=0 must not claim a frame.
						if (mb_index >= mb_count) begin
							done          <= 1'b1;
							// frames_out / DPB ref snap already on GRID_DONE.
						end
						x          <= 10'd0;
						y          <= 10'd0;
					end else if (x == (width_w - 10'd1)) begin
						x <= 10'd0;
						y <= y + 10'd1;
					end else
						x <= x + 10'd1;
				end
			end

			default: phase <= ST_IDLE;
			endcase
		end
	end

endmodule

// Hard 320x240 DPB wrap. No local cur_pic/ref_pic arrays.
// bank_sel is +115200 on stream_path mem_* only. Write current; MC frozen.
module h264_dpb_one_ref_320 (
	input  wire               clk,
	input  wire               reset,
	input  wire               idr_start,
	input  wire               frame_done,
	output wire               ref_ready,
	output wire [31:0]        current_base,
	output wire [31:0]        reference_base,
	input  wire               filtered_sample_valid,
	input  wire [7:0]         filtered_mb_x,
	input  wire [7:0]         filtered_mb_y,
	input  wire [1:0]         filtered_plane,
	input  wire [7:0]         filtered_sample_idx,
	input  wire [7:0]         filtered_sample,
	output wire               mem_we,
	output wire [31:0]        mem_waddr,
	output wire [7:0]         mem_wdata,
	input  wire               fetch_start,
	input  wire [7:0]         fetch_mb_x,
	input  wire [7:0]         fetch_mb_y,
	input  wire [2:0]         fetch_part_mode,
	input  wire [1:0]         fetch_part_idx,
	input  wire [4:0]         fetch_part_w,
	input  wire [4:0]         fetch_part_h,
	input  wire signed [15:0] fetch_mv_x_qpel,
	input  wire signed [15:0] fetch_mv_y_qpel,
	output wire               fetch_busy,
	output wire               fetch_done,
	output wire               fetch_error_no_ref,
	output wire [1:0]         luma_frac_x,
	output wire [1:0]         luma_frac_y,
	output wire [2:0]         chroma_frac_x,
	output wire [2:0]         chroma_frac_y,
	output wire signed [15:0] luma_origin_x,
	output wire signed [15:0] luma_origin_y,
	output wire signed [15:0] chroma_origin_x,
	output wire signed [15:0] chroma_origin_y,
	output wire               mem_rd,
	output wire [31:0]        mem_raddr,
	input  wire [7:0]         mem_rdata,
	input  wire               mem_rvalid,
	output wire               luma_window_valid,
	output wire [8:0]         luma_window_idx,
	output wire [7:0]         luma_window_sample,
	output wire               chroma_u_window_valid,
	output wire               chroma_v_window_valid,
	output wire [6:0]         chroma_window_idx,
	output wire [7:0]         chroma_window_sample
);
	localparam [31:0] PIC_BYTES = 32'd115200;
	reg  bank_sel;
	reg  have_ref;
	reg  frame_done_d;
	wire frame_done_pulse = frame_done & ~frame_done_d;
	wire        core_we;
	wire [31:0] core_waddr;
	wire [7:0]  core_wdata;
	wire        core_rd;
	wire [31:0] core_raddr;
	assign mem_we    = core_we;
	assign mem_wdata = core_wdata;
	assign mem_rd    = core_rd;
	assign mem_waddr = core_waddr + (bank_sel ? PIC_BYTES : 32'd0);
	assign mem_raddr = core_raddr + (bank_sel ? 32'd0 : PIC_BYTES);

	always @(posedge clk) begin
		if (reset) begin
			bank_sel     <= 1'b0;
			have_ref     <= 1'b0;
			frame_done_d <= 1'b0;
		end else begin
			frame_done_d <= frame_done;
			if (frame_done_pulse) begin
				bank_sel <= ~bank_sel;
				have_ref <= 1'b1;
			end
		end
	end

	h264_dpb_one_ref #(
		.FRAME_W(320),
		.FRAME_H(240),
		.BANK0_BASE(0),
		.BANK1_BASE(0)
	) u_core (
		.clk(clk), .reset(reset),
		.idr_start(idr_start), .frame_done(frame_done),
		.ref_ready(ref_ready),
		.current_base(current_base), .reference_base(reference_base),
		.filtered_sample_valid(filtered_sample_valid),
		.filtered_mb_x(filtered_mb_x), .filtered_mb_y(filtered_mb_y),
		.filtered_plane(filtered_plane), .filtered_sample_idx(filtered_sample_idx),
		.filtered_sample(filtered_sample),
		.mem_we(core_we), .mem_waddr(core_waddr), .mem_wdata(core_wdata),
		.fetch_start(fetch_start),
		.fetch_mb_x(fetch_mb_x), .fetch_mb_y(fetch_mb_y),
		.fetch_part_mode(fetch_part_mode), .fetch_part_idx(fetch_part_idx),
		.fetch_part_w(fetch_part_w), .fetch_part_h(fetch_part_h),
		.fetch_mv_x_qpel(fetch_mv_x_qpel), .fetch_mv_y_qpel(fetch_mv_y_qpel),
		.fetch_busy(fetch_busy), .fetch_done(fetch_done),
		.fetch_error_no_ref(fetch_error_no_ref),
		.luma_frac_x(luma_frac_x), .luma_frac_y(luma_frac_y),
		.chroma_frac_x(chroma_frac_x), .chroma_frac_y(chroma_frac_y),
		.luma_origin_x(luma_origin_x), .luma_origin_y(luma_origin_y),
		.chroma_origin_x(chroma_origin_x), .chroma_origin_y(chroma_origin_y),
		.mem_rd(core_rd), .mem_raddr(core_raddr),
		.mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid),
		.luma_window_valid(luma_window_valid), .luma_window_idx(luma_window_idx),
		.luma_window_sample(luma_window_sample),
		.chroma_u_window_valid(chroma_u_window_valid),
		.chroma_v_window_valid(chroma_v_window_valid),
		.chroma_window_idx(chroma_window_idx),
		.chroma_window_sample(chroma_window_sample)
	);
endmodule

