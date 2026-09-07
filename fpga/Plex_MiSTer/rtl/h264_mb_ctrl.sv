//============================================================================
//  320x240 CAVLC macroblock controller: I4/I16 + chroma prediction,
//  full-range signed residuals and one shared serial IQ/transform.
//  One complete coded picture within 320x240, with filtering disabled.
//  Native I420 writes retain their original read-only observation interface.
//  Picture publication follows complete Y/U/V writes and accepted RGB drain.
//  Product capability stays disabled until integrated hardware qualification.
//  Copyright (C) 2026 MiSTerPlex contributors
//  GPL-2.0-or-later
//============================================================================

module h264_mb_ctrl #(
	parameter int WIDTH  = 320,
	parameter int HEIGHT = 240,
	parameter int RBSP_ADDR_W = 13,
	parameter bit NATIVE_PUBLISH_LEASE = 1'b0,
	// Removes inter hardware; runtime policy cannot re-enable non-IDR input.
	parameter bit STATIC_IDR_ONLY = 1'b0
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        vcl_pulse,
	input  wire        sps_valid,
	input  wire [7:0]  mb_w,
	input  wire [7:0]  mb_h,
	// Crops are luma pixels: progressive 4:2:0 offsets are doubled upstream.
	// Unknown SAR is explicitly 0/0, independent of the original source DAR.
	input  wire        picture_geometry_valid,
	input  wire        picture_is_idr,
	input  wire [1:0]  picture_nal_ref_idc,
	input  wire [7:0]  picture_max_num_ref_frames,
	input  wire        picture_idr_only,
	input  wire [15:0] picture_crop_left, picture_crop_right,
	input  wire [15:0] picture_crop_top, picture_crop_bottom,
	input  wire [15:0] picture_sar_width, picture_sar_height,
	input  wire        picture_sar_known,
	input  wire [7:0]  slice_type,
	input  wire        slice_is_i,
	input  wire        slice_valid,
	input  wire        slice_error,
	input  wire [5:0]  slice_qp,
	input  wire        residual_ok,
	input  wire signed [8:0] residual_coeff [0:15],
	input  wire        residual_place_pulse,
	input  wire [15:0] first_mb,
	input  wire [7:0]  first_mb_type,
	input  wire [7:0]  pps_nref,
	input  wire        pps_deblock,
	input  wire [1:0]  slice_disable_deblocking_filter_idc,
	input  wire signed [5:0] pps_chroma_qp_index_offset,
	input  wire        pps_constrained_intra_pred,
	input  wire        video_full_range,
	input  wire [7:0]  video_matrix_coefficients,
	input  wire        sl_rbsp_clear,
	input  wire        sl_rbsp_en,
	input  wire [7:0]  sl_rbsp_data,
	input  wire        sl_rbsp_end,
	input  wire [RBSP_ADDR_W:0] sl_rbsp_len,
	input  wire [RBSP_ADDR_W+3:0] bit_pos_hdr,
	input  wire [RBSP_ADDR_W+3:0] bit_pos_resid,
	input  wire        bit_pos_valid,

	output reg  [7:0]  recon_sig,
	output reg  [7:0]  recon_dbg,
	output reg         recon_dbg_valid,
	output reg         recon_valid,
	input  wire        wr_ready,  // present accept_cmd (same as F1 ioctl_wait)
	input  wire        present_sel,  // fpga_wr | stub_allow; drives fs_wr_en/fs_swap
	output wire        wr_en,
	output wire [15:0] wr_pixel,
	output reg         wr_reset_ptr,
	output reg         swap_req,
	output reg         busy,
	output reg  [15:0] frames_out,
	output wire        product_recon_ok,
	output reg  [15:0] mb_index,
	output reg         done,
	output reg [7:0]   decode_error,
	// Release belongs to this picture's source epoch/nonce after real copy/drain.
	input  wire        native_picture_release,
	output reg         native_picture_valid,
	output wire [31:0] native_picture_base,
	// Snapshot with accepted wr_reset_ptr; activate only on accepted swap.
	// RGB is the cropped visible rectangle, packed without letterboxing.
	output reg         present_meta_valid,
	output wire [15:0] present_coded_width, present_coded_height,
	output wire [15:0] present_width, present_height,
	output reg [15:0]  present_crop_left, present_crop_right,
	output reg [15:0]  present_crop_top, present_crop_bottom,
	output reg [15:0]  present_sar_width, present_sar_height,
	output reg         present_sar_known,
	// Decoded rectangle/SAR only; original source DAR is separate metadata.
	output wire [31:0] present_dar_num, present_dar_den,
	output wire [15:0] native_luma_stride, native_chroma_stride,
	// Native padded I420 banks at byte bases 0 and 115200.
	output wire        dpb_mem_we,
	output wire [31:0] dpb_mem_waddr,
	output wire [7:0]  dpb_mem_wdata,
	output wire        dpb_mem_rd,
	output wire [31:0] dpb_mem_raddr,
	input  wire [7:0]  dpb_mem_rdata,
	input  wire        dpb_mem_rvalid
);

	// Legacy diagnostic tap cannot authorize product capability or publication.
	reg clip_gold_match /*verilator public_flat_rw*/;
	assign product_recon_ok = 1'b0;
	// Muxed present strobe. Do not advance on bare wr_ready (phantom accept).
	wire paint_ack = wr_ready & present_sel;

	`include "h264_chroma_nc.svh"

	localparam int WAIT_MAX = 4095;
	localparam int RBSP_LEN_W = RBSP_ADDR_W+1;
	localparam int RBSP_BIT_W = RBSP_ADDR_W+4;
	localparam int RBSP_MAX = 1 << RBSP_ADDR_W;
	localparam int WIN_N    = 128;

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
		ST_DPB_WAIT  = 5'd25,
		ST_PUBLISH   = 5'd26,
		ST_TAIL      = 5'd27,
		ST_NATIVE_RELEASE = 5'd28;

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
	reg lat_geometry_valid, lat_picture_is_idr;
	reg [1:0] lat_nal_ref_idc;
	reg [7:0] lat_max_num_ref_frames;
	reg lat_idr_only, prediction_reference_valid;
	reg [7:0]      lat_slice_type;
	reg            lat_slice_i;
	reg [15:0]     lat_first_mb;
	reg [7:0]      lat_nref;
	reg            lat_deblock;
	reg [1:0]      lat_filter_idc;
	reg signed [5:0] lat_chroma_offset;
	reg lat_full_range;
	reg lat_constrained_intra;
	reg [7:0] lat_matrix;
	reg [4:0] tail_bits;
	reg signed [8:0] lat_coeff [0:15];
	reg            recon_start;
	reg [7:0]      lat_recon [0:15];
	integer        coeff_i;


	wire [15:0] input_coded_width = {4'd0,mb_w,4'd0};
	wire [15:0] input_coded_height = {4'd0,mb_h,4'd0};
	wire [16:0] horizontal_crop = {1'b0,picture_crop_left}+{1'b0,picture_crop_right};
	wire [16:0] vertical_crop = {1'b0,picture_crop_top}+{1'b0,picture_crop_bottom};
	wire input_geometry_ok = picture_geometry_valid && mb_w!=0 && mb_w<=20 &&
		mb_h!=0 && mb_h<=15 && horizontal_crop<input_coded_width &&
		vertical_crop<input_coded_height &&
		(picture_sar_known ? (picture_sar_width!=0 && picture_sar_height!=0) :
		                      (picture_sar_width==0 && picture_sar_height==0)) &&
		!(picture_crop_left[0] || picture_crop_right[0] ||
		  picture_crop_top[0] || picture_crop_bottom[0]);
	assign present_coded_width = {4'd0,lat_mb_w,4'd0};
	assign present_coded_height = {4'd0,lat_mb_h,4'd0};
	assign present_width = present_coded_width-present_crop_left-present_crop_right;
	assign present_height = present_coded_height-present_crop_top-present_crop_bottom;
	assign present_dar_num = present_sar_known ? {16'd0,present_width}*{16'd0,present_sar_width} : 32'd0;
	assign present_dar_den = present_sar_known ? {16'd0,present_height}*{16'd0,present_sar_height} : 32'd0;
	// Native banks retain maximum-allocation pitch, not packed coded-width pitch.
	assign native_luma_stride = 16'd320;
	assign native_chroma_stride = 16'd160;
	wire [31:0] visible_pixels = {16'd0,present_width}*{16'd0,present_height};
	// A displayed SPS-maxRefs=0 IDR is not an eligible prediction reference.
	wire picture_reference_ok = lat_max_num_ref_frames<=1 &&
		!(lat_picture_is_idr && !lat_slice_i) &&
		(!(STATIC_IDR_ONLY || lat_idr_only || lat_max_num_ref_frames==0) || lat_picture_is_idr) &&
		(lat_slice_i || prediction_reference_valid);
	wire       wait_done = slice_valid && bit_pos_valid;

	reg signed [15:0] cavlc_coeff [0:15];
	wire signed [15:0] recon_cavlc_coeff [0:15];
	reg recon_from_mb;
	wire signed [15:0] sat_coeff [0:15];
	reg recon_use_dc;
	reg signed [31:0] recon_dc_value;
	wire [5:0] recon_qp = (fill_unc && ly_i >= 16) ? chroma_qp : lat_qp;
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
		.cavlc_coeff(recon_cavlc_coeff),
		.qp(recon_qp),
		.max_coeff(max_coeff_r),
		.pred(pred),
		.use_dc(recon_use_dc),
		.dc_value(recon_dc_value),
		.sat_coeff(sat_coeff),
		.recon(recon_blk),
		.recon_sig(recon_sig_w),
		.done(recon_done),
		.ok(recon_ok)
	);

	// One bounded VCL capture; address, byte-count and bit-cursor widths agree.
	wire [7:0]  ram_rd;
	wire [RBSP_LEN_W-1:0] rbsp_bytes;
	wire        rbsp_done;
	wire        rbsp_ram_overflow;
	wire [RBSP_ADDR_W-1:0] ram_rd_addr;
	reg         vcl_lock;
	reg         saw_commit;
	reg         stop_pend;
	reg [RBSP_LEN_W-1:0] captured_bytes;
	reg capture_overflow;
	wire        rbsp_p_short  = rbsp_done && (rbsp_bytes > 0) && (rbsp_bytes < 48);
	wire        rbsp_vcl_ok = rbsp_done && rbsp_bytes!=0;
	wire        sl_rbsp_lockable = sl_rbsp_len!=0;
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
		.done(rbsp_done),
		.overflow(rbsp_ram_overflow)
	);
	always @(posedge clk) begin
		if (reset || rbsp_wr_clear) begin captured_bytes<=0; capture_overflow<=0; end
		else if (sl_rbsp_en && !vcl_lock) begin
			if (captured_bytes<RBSP_MAX)captured_bytes<=captured_bytes+1'b1;
			else capture_overflow<=1;
		end
		if (!reset && sl_rbsp_end && sl_rbsp_len>RBSP_MAX)
			capture_overflow<=1;
	end

	// h264_bit_reader owns bit_pos after slice header (FULL_SLICE_CAVLC.md).
	// EXPERT pack (when it lands): bit_offset_end, UE/SE field order, chroma nC.
	// Do not invent those contracts here — load/start hooks only.
	reg               br_load;
	reg  [RBSP_BIT_W-1:0] br_load_pos;
	reg               br_get, br_start_ue, br_start_se, br_start_u;
	reg  [4:0]        br_un;
	wire [RBSP_ADDR_W-1:0] br_ram_addr;
	wire [RBSP_BIT_W-1:0] br_bit_pos;
	wire              br_cur_bit, br_aligned, br_eof;
	wire              br_bit_valid, br_bit_out;
	wire              br_syn_busy, br_syn_done, br_syn_ok;
	wire              br_ready, br_error;
	wire [15:0]       br_ue;
	wire signed [15:0] br_se;

	h264_bit_reader #(.ADDR_W(RBSP_ADDR_W), .RAM_LATENCY(1)) u_bit_reader (
		.clk(clk),
		.reset(reset),
		.load(br_load),
		.bit_pos_i(br_load_pos),
		.rbsp_len(rbsp_bytes),
		.rbsp_done(rbsp_done),
		.ram_rd(ram_rd),
		.ram_addr(br_ram_addr),
		.bit_pos(br_bit_pos),
		.cur_bit(br_cur_bit),
		.aligned(br_aligned),
		.eof(br_eof),
		.ready(br_ready),
		.error(br_error),
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

	wire [RBSP_BIT_W-1:0] bit_pos = br_bit_pos;
	reg  [RBSP_BIT_W-1:0] bit_len;
	wire [RBSP_LEN_W-1:0] bit_byte_addr = bit_pos[RBSP_BIT_W-1:3];

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
	reg [7:0] above16 [0:19];
	reg [7:0] left16  [0:15];
	reg [7:0] above4  [0:7];
	reg [7:0] left4p  [0:3];
	reg [7:0] i4_tl;
	reg       has_left, has_above;
	reg [7:0] chr_left_u [0:7], chr_left_v [0:7];
	wire [7:0] chr_above_u [0:7], chr_above_v [0:7];
	reg [7:0] chr_tl_u, chr_tl_v;
	reg [3:0] mode_top [0:WIDTH/4-1], mode_left [0:3];
	reg [1:0] chroma_mode;
	reg [23:0] coeff_valid;
	reg coeff_read_valid;
	reg signed [31:0] chr_dc_u [0:3], chr_dc_v [0:3];
	wire [7:0] chr_pred [0:15];
	wire [7:0] chr_pred_above [0:7], chr_pred_left [0:7];
	wire [5:0] chroma_qp = qpc(lat_qp, lat_chroma_offset);
	wire intra_has_left = has_left && (STATIC_IDR_ONLY || !lat_constrained_intra || !mv_left_v);
	wire intra_has_above = has_above && (STATIC_IDR_ONLY || !lat_constrained_intra || !mv_up_v);
	wire intra_has_tl = has_left && has_above && (STATIC_IDR_ONLY || !lat_constrained_intra || !mv_hold_d_v);
	genvar chr_neighbor;
	generate for (chr_neighbor=0;chr_neighbor<8;chr_neighbor=chr_neighbor+1) begin: g_chroma_select
		assign chr_pred_above[chr_neighbor]=ly_i[2] ? chr_above_v[chr_neighbor] : chr_above_u[chr_neighbor];
		assign chr_pred_left[chr_neighbor]=ly_i[2] ? chr_left_v[chr_neighbor] : chr_left_u[chr_neighbor];
	end endgenerate
	h264_chroma_pred_region #(.SIDE(4)) u_chr_pred (
		.mode(chroma_mode), .above(chr_pred_above), .left(chr_pred_left),
		.top_left(ly_i[2] ? chr_tl_v : chr_tl_u),
		.has_above(intra_has_above), .has_left(intra_has_left),
		.block_x(blk_x[0]), .block_y(blk_y[0]), .pred(chr_pred)
	);
	reg [4:0] nload_i;
	reg [3:0]  stamp_i;
	reg        paint_hold;
	reg        paint_reset_hold;
	reg        paint_swap_hold;
	reg [31:0] we_n;
	reg [7:0]  y0_lat;
	reg        stop_br_eof;
	reg [RBSP_LEN_W-1:0] stop_rbsp_bytes;
	reg [RBSP_BIT_W-1:0] stop_bit_pos;
	reg [15:0] stop_mb_index;
	reg [7:0]  stop_mb_w, stop_mb_h;
	reg [3:0]  stop_hdr_st;
	reg [15:0] stop_ue_val;

	reg [7:0]  cav_rbsp [0:WIN_N-1];
	reg [6:0]  win_i;
	reg [7:0]  win_count;
	reg [RBSP_LEN_W-1:0] win_base;
	assign ram_rd_addr = (phase == ST_WIN) ? win_addr : br_ram_addr;
	reg        cav_start;
	reg [2:0]  cav_table;
	reg        rseq_start, rseq_adv, rseq_wait;
	reg [4:0]  ly_i;
	wire       rseq_valid, rseq_done, rseq_cdc, rseq_chr, rseq_cb;
	wire [4:0] rseq_id, rseq_max;
	wire [1:0] rseq_x, rseq_y;
	wire [2:0] rseq_tab;
	wire       cav_busy, cav_done, cav_ok;
	wire [10:0] cav_bit_end;
	wire [4:0] cav_tc;
	wire [1:0] cav_t1;
	wire [3:0] cav_tz;
	wire signed [15:0] cav_coeff [0:15];
	wire signed [18:0] chroma_dc_wide [0:3];
	genvar dc_index;
	generate for (dc_index=0;dc_index<4;dc_index=dc_index+1) begin: g_chroma_dc_widen
		// Widen before +/- so the full signed16 coefficient range survives.
		assign chroma_dc_wide[dc_index] = {{3{cav_coeff[dc_index][15]}}, cav_coeff[dc_index]};
	end endgenerate
	wire signed [15:0] cav_lev_dbg [0:15];
	wire [3:0]         cav_run_dbg [0:15];

	reg [10:0] cav_off0;
	wire [RBSP_BIT_W-1:0] window_available_bits = win_base<rbsp_bytes ?
		(RBSP_BIT_W'(rbsp_bytes)-RBSP_BIT_W'(win_base))<<3 : '0;
	wire [10:0] window_bit_len = window_available_bits < (RBSP_BIT_W'(win_count)<<3) ?
	                             window_available_bits[10:0] : {win_count,3'd0};
	reg [RBSP_ADDR_W-1:0] win_addr;
	reg [1:0]  win_hold;
	reg [RBSP_BIT_W-1:0] res_bit_start;
	h264_cavlc_residual_block #(.MAX_BYTES(WIN_N)) u_cavlc (
		.clk(clk),
		.reset(reset),
		.start(cav_start),
		.coeff_token_table(cav_table),
		.max_coeff(max_coeff_r),
		// EXPERT: bit_offset_start latched at WIN (not live br_bit_pos).
		.bit_offset_start(cav_off0),
		.bit_len(window_bit_len),
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
	localparam int CHR_MB_W = 20;
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
	reg signed [15:0] mv_row_x [0:19];
	reg signed [15:0] mv_row_y [0:19];
	reg               mv_row_v [0:19];
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

	wire [7:0] i16_above [0:15];
	genvar ia;
	generate for (ia=0;ia<16;ia=ia+1) begin: i16_edge
		assign i16_above[ia]=above16[ia];
	end endgenerate
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
		.above(i16_above),
		.left(left16),
		.top_left(top_left_pix),
		.has_above(intra_has_above),
		.has_left(intra_has_left),
		.busy(i16_busy),
		.done(i16_done),
		.unsupported(i16_unsup),
		.pred(i16_pred)
	);

	// ITU 8.5.10 produces full-width DC values for insertion before the IDCT.
	reg signed [15:0] i16_dc_scan [0:15];
	wire signed [31:0] i16_dc [0:15];
	reg  hdc_start;
	wire hdc_done;
	h264_i16_dc_hadamard u_i16_dc (
		.clk(clk), .reset(reset), .start(hdc_start),
		.coeff_scan(i16_dc_scan),
		.qp(lat_qp),
		.dc_out(i16_dc),
		.done(hdc_done)
	);
	reg signed [31:0] i16_dc_res [0:15];
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
		.has_above(intra_has_above | (blk_y != 2'd0)),
		.has_left(intra_has_left | (blk_x != 2'd0)),
		.used_mode(i4_used),
		.pred(i4_pred)
	);

	wire signed [15:0] mv_px, mv_py, mv_xw, mv_yw;
	wire               skip_zero;
	wire        pdec_skip, pdec_inter, pdec_intra, pdec_sub, pdec_ref0, pdec_unsup;
	wire [2:0]  pdec_mode, pdec_cnt, pdec_sub_cnt;
	wire [4:0]  pdec_w, pdec_h;
	wire [3:0]  pdec_sw, pdec_sh;
	generate if (!STATIC_IDR_ONLY) begin: g_inter_prediction
	h264_mv_pred_16x16 u_mvp (
		.avail_a(has_left),
		.avail_b(has_above),
		.avail_c(has_above && lat_mb_x+8'd1<grid_w),
		.avail_d(has_above && has_left),
		.intra_a(has_left && !mv_left_v),
		.intra_b(has_above && !mv_up_v),
		.intra_c(has_above && lat_mb_x+8'd1<grid_w && !mv_c_v),
		.intra_d(has_above && has_left && !mv_d_v),
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
	end else begin: g_no_inter_prediction
		assign mv_px=16'sd0, mv_py=16'sd0, mv_xw=16'sd0, mv_yw=16'sd0;
		assign skip_zero=1'b0;
		assign pdec_skip=1'b0, pdec_inter=1'b0, pdec_intra=1'b1;
		assign pdec_sub=1'b0, pdec_ref0=1'b0, pdec_unsup=1'b1;
		assign pdec_mode=3'd0, pdec_cnt=3'd0, pdec_sub_cnt=3'd0;
		assign pdec_w=5'd16, pdec_h=5'd16, pdec_sw=4'd0, pdec_sh=4'd0;
	end endgenerate

	wire        dpb_ref_ready, dpb_fetch_busy, dpb_fetch_done, dpb_fetch_err;
	wire        dpb_write_ready;
	wire        dpb_frame_error, dpb_frame_promoted;
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
	// Native storage retains maximum-allocation pitch; the DPB owns both banks.
	reg         dpb_kick;
	reg         dpb_after_db; // 1 → ST_DB_LD after fetch, 0 → H_CBP
	reg         dpb_frm_done;
	reg  [1:0]  frm_done_hold;
	reg  [31:0] paint_base;
	assign native_picture_base = paint_base;
	reg [2:0] paint_step;
	reg [7:0] paint_y_sample, paint_u_sample, paint_v_sample;
	reg [7:0] paint_u_line [0:159], paint_v_line [0:159];
	reg paint_pixel_valid;
	reg [15:0] paint_pixel_hold;
	reg [16:0] accepted_pixels;
	reg native_complete;
	// y*320 = (y<<8)+(y<<6). No * (Q17).
	wire [17:0] paint_y320 = {y, 8'd0} + {2'b00, y, 6'd0};
	wire [31:0] paint_chroma_addr = (y>>1)*160+(x>>1);
	wire paint_need_chroma = !y[0] && !x[0];
	wire [15:0] paint_last_x = present_coded_width-present_crop_right-1'b1;
	wire [15:0] paint_last_y = present_coded_height-present_crop_bottom-1'b1;
	// A synchronous read response can be accepted immediately. Buffer it if
	// the consumer stalls, rather than inserting a register bubble per pixel.
	wire paint_response = phase==ST_PAINT && !paint_reset_hold && !paint_swap_hold &&
		dpb_mem_rvalid && ((paint_step==1 && !paint_need_chroma) || paint_step==5);
	wire [7:0] paint_out_y = paint_step==5 ? paint_y_sample : dpb_mem_rdata;
	wire [7:0] paint_out_u = paint_step==5 ? paint_u_sample : paint_u_line[x>>1];
	wire [7:0] paint_out_v = paint_step==5 ? dpb_mem_rdata : paint_v_line[x>>1];
	wire [15:0] paint_response_pixel = yuv_rgb565(paint_out_y,paint_out_u,paint_out_v);
	assign wr_en = paint_pixel_valid || paint_response;
	assign wr_pixel = paint_pixel_valid ? paint_pixel_hold : paint_response_pixel;
	wire paint_next = wr_en && paint_ack && !(x==paint_last_x && y==paint_last_y);
	wire [31:0] paint_advance = x==paint_last_x ? 32'd321-{16'd0,present_width} : 32'd1;
	wire [31:0] paint_raddr = paint_base +
		(paint_step==1 && paint_need_chroma ? 32'd76800+paint_chroma_addr :
		 paint_step==3 ? 32'd96000+paint_chroma_addr :
		 {14'd0,paint_y320}+{22'd0,x}+(paint_next ? paint_advance : 32'd0));
	wire        paint_on    = (phase == ST_PAINT);
	reg signed [15:0] mv_kick_x, mv_kick_y;
	reg        mc_hold;
	reg        mc_int_copy; // DPB packed 16x16; MC wants 21x21 at +2,+2
	reg         filt_v;
	reg  [1:0]  filt_plane;
	reg  [7:0]  filt_idx, filt_s;
	wire [7:0]  mc_luma [0:440];
	wire [7:0]  mc_u [0:80];
	wire [7:0]  mc_v [0:80];
	wire [7:0]  mc_pred_y [0:255];
	wire [7:0]  mc_pred_u [0:63];
	wire [7:0]  mc_pred_v [0:63];
	assign dpb_mem_we    = dpb_we;
	wire dpb_mem_wready = 1'b1;
	wire dpb_mem_waccept = dpb_we && dpb_mem_wready;
	assign dpb_mem_waddr = dpb_waddr;
	assign dpb_mem_wdata = dpb_wdata;
	// ST_PAINT shares the DPB read port and reads the promoted reference bank.
	assign dpb_mem_rd    = paint_on ? (!paint_reset_hold && !paint_swap_hold &&
	                                  (paint_step==0 || paint_next ||
	                                   (paint_step==1 && paint_need_chroma && dpb_mem_rvalid) ||
	                                   (paint_step==3 && dpb_mem_rvalid))) :
	                                 (STATIC_IDR_ONLY ? 1'b0 : dpb_rd);
	assign dpb_mem_raddr = paint_on ? paint_raddr : (STATIC_IDR_ONLY ? 32'd0 : dpb_raddr);
	// Same-cycle COMMIT store so mb_index=1 cannot leave dpb_pic all-zero.
	// Integer 16x16 (P_Skip / MV=0): DPB int_copy packs THIS mb at luma[0:255]
	// / chroma[0:63]. 21x21 qpel on that layout makes Y(2,10)=win[256]=0.
	wire pel_copy = !STATIC_IDR_ONLY && (pdec_mode == 3'd0) && (mv_xw == 16'sd0) && (mv_yw == 16'sd0)
	                && (is_pskip || is_p16);
	wire        store_v   = (phase == ST_COMMIT);
	wire [7:0]  store_idx = (filt_plane == 2'd0) ? cmt_i : {2'd0, cmt_i[5:0]};
	// P_Skip / P16 CBP=0: 64+64 from THIS mb (latched at fetch). Do not
	// Both intra and inter store the reconstructed chroma, never neutral filler.
	wire        store_uv  = 1'b1;
	wire [7:0]  store_s   = (filt_plane == 2'd0) ? mb_pix[cmt_i] :
	                        (store_uv && (filt_plane == 2'd1)) ? mb_u[cmt_i[5:0]] :
	                        (store_uv && (filt_plane == 2'd2)) ? mb_v[cmt_i[5:0]] :
	                        8'd128;
	// Open the DPB only after this picture's geometry/header are latched.
	// I slices in non-IDR NALs must not authorize a geometry transition.
	reg dpb_idr_start, dpb_frame_start, dpb_opened;
	h264_dpb_one_ref #(
		.FRAME_W(320), .FRAME_H(240), .BANK0_BASE(0), .BANK1_BASE(115200)
	) u_dpb (
		.clk(clk), .reset(reset),
		.frame_width(present_coded_width), .frame_height(present_coded_height),
		.reference_width(), .reference_height(),
		.idr_start(dpb_idr_start),
		.frame_start(dpb_frame_start),
		.frame_abort(phase==ST_STOP),
		.frame_done(dpb_frm_done),
		.frame_error(dpb_frame_error), .frame_promoted(dpb_frame_promoted),
		.mem_wready(dpb_mem_wready), .mem_wdrained(1'b1), .mem_rready(1'b1),
		.ref_ready(dpb_ref_ready),
		.current_base(dpb_cur_base),
		.reference_base(dpb_ref_base),
		.filtered_sample_valid(store_v),
		.filtered_mb_x(lat_mb_x), .filtered_mb_y(lat_mb_y),
		.filtered_plane(filt_plane), .filtered_sample_idx(store_idx),
		.filtered_sample(store_s),
		.filtered_sample_ready(dpb_write_ready),
		.mem_we(dpb_we), .mem_waddr(dpb_waddr), .mem_wdata(dpb_wdata),
		.fetch_start(STATIC_IDR_ONLY ? 1'b0 : dpb_kick),
		.fetch_mb_x(STATIC_IDR_ONLY ? 8'd0 : dpb_fmb_x),
		.fetch_mb_y(STATIC_IDR_ONLY ? 8'd0 : dpb_fmb_y),
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
		.mem_rdata(STATIC_IDR_ONLY ? 8'd0 : dpb_mem_rdata),
		.mem_rvalid(STATIC_IDR_ONLY ? 1'b0 : dpb_mem_rvalid),
		.luma_window_valid(dpb_luma_wv), .luma_window_idx(dpb_luma_wi),
		.luma_window_sample(dpb_luma_ws),
		.chroma_u_window_valid(dpb_cu_wv), .chroma_v_window_valid(dpb_cv_wv),
		.chroma_window_idx(dpb_chroma_wi), .chroma_window_sample(dpb_chroma_ws)
	);
	reg  mc_start;
	wire mc_done;
	genvar mc_index;
	generate if (!STATIC_IDR_ONLY) begin: g_inter_mc
		reg [7:0] luma_window [0:440];
		reg [7:0] u_window [0:80], v_window [0:80];
		for (mc_index=0;mc_index<441;mc_index=mc_index+1) begin: g_luma
			assign mc_luma[mc_index]=luma_window[mc_index];
		end
		for (mc_index=0;mc_index<81;mc_index=mc_index+1) begin: g_chroma
			assign mc_u[mc_index]=u_window[mc_index];
			assign mc_v[mc_index]=v_window[mc_index];
		end
		always @(posedge clk) begin
			if (dpb_luma_wv)luma_window[dpb_luma_wi]<=dpb_luma_ws;
			if (dpb_cu_wv)u_window[dpb_chroma_wi]<=dpb_chroma_ws;
			if (dpb_cv_wv)v_window[dpb_chroma_wi]<=dpb_chroma_ws;
		end
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
	end else begin: g_no_inter_mc
		assign mc_done=1'b0;
		for (mc_index=0;mc_index<441;mc_index=mc_index+1) begin: g_luma
			assign mc_luma[mc_index]=8'd0;
		end
		for (mc_index=0;mc_index<81;mc_index=mc_index+1) begin: g_chroma
			assign mc_u[mc_index]=8'd0;
			assign mc_v[mc_index]=8'd0;
		end
		for (mc_index=0;mc_index<256;mc_index=mc_index+1) begin: g_pred_y
			assign mc_pred_y[mc_index]=8'd0;
		end
		for (mc_index=0;mc_index<64;mc_index=mc_index+1) begin: g_pred_uv
			assign mc_pred_u[mc_index]=8'd0;
			assign mc_pred_v[mc_index]=8'd0;
		end
	end endgenerate

	wire [2:0] db_bs;
	wire       db_unsup_ref;
	generate if (!STATIC_IDR_ONLY) begin: g_deblock_bs
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
	end else begin: g_no_deblock_bs
		assign db_bs=3'd0, db_unsup_ref=1'b0;
	end endgenerate

	reg [7:0] p3_in [0:3], p2_in [0:3], p1_in [0:3], p0_in [0:3];
	reg [7:0] q3_in [0:3], q2_in [0:3], q1_in [0:3], q0_in [0:3];
	wire [7:0] p2_o [0:3], p1_o [0:3], p0_o [0:3], q0_o [0:3], q1_o [0:3], q2_o [0:3];
	wire [7:0] db_a, db_b;
	wire [5:0] db_tc0;
	genvar db_lane;
	generate if (!STATIC_IDR_ONLY) begin: g_deblock_edge
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
	end else begin: g_no_deblock_edge
		assign db_a=8'd0, db_b=8'd0, db_tc0=6'd0;
		for (db_lane=0;db_lane<4;db_lane=db_lane+1) begin: g_sample
			assign p2_o[db_lane]=8'd0, p1_o[db_lane]=8'd0, p0_o[db_lane]=8'd0;
			assign q0_o[db_lane]=8'd0, q1_o[db_lane]=8'd0, q2_o[db_lane]=8'd0;
		end
	end endgenerate

	wire [7:0] db_thr_a, db_thr_b;
	wire [5:0] db_idx_a, db_idx_b, db_tc0b;
	generate if (!STATIC_IDR_ONLY) begin: g_deblock_thresholds
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
	end else begin: g_no_deblock_thresholds
		assign db_thr_a=8'd0, db_thr_b=8'd0;
		assign db_idx_a=6'd0, db_idx_b=6'd0, db_tc0b=6'd0;
	end endgenerate

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

	function automatic [5:0] qpc(input [5:0] qy, input signed [5:0] offset);
		integer q;
		begin
			q = integer'(qy) + integer'(offset);
			if (q < 0) q=0;
			if (q > 51) q=51;
			case(q)
			30:qpc=29; 31:qpc=30; 32:qpc=31; 33,34:qpc=32;
			35:qpc=33; 36,37:qpc=34; 38,39:qpc=35; 40,41:qpc=36;
			42,43,44:qpc=37; 45,46,47:qpc=38; 48,49,50,51:qpc=39;
			default:qpc=q[5:0];
			endcase
		end
	endfunction

	function automatic signed [31:0] chroma_dc_scale(
		input signed [18:0] value, input [5:0] q);
		reg signed [35:0] v;
		reg signed [5:0] factor;
		begin
			case(q%6)
			0:factor=10; 1:factor=11; 2:factor=13;
			3:factor=14; 4:factor=16; default:factor=18;
			endcase
			v=value*factor;
			chroma_dc_scale=(v<<<(q/6))>>>1;
		end
	endfunction

	function automatic [15:0] yuv_rgb565(input [7:0] yp,up,vp);
		integer yy, uu, vv, r, g, b, scale_y, rv, gu, gv, bu;
		begin
			yy=integer'(yp)-(lat_full_range ? 0 : 16);
			uu=integer'(up)-128; vv=integer'(vp)-128;
			scale_y=lat_full_range ? 256 : 298;
			rv=lat_matrix==1 ? (lat_full_range ? 403 : 459) : (lat_full_range ? 359 : 409);
			gu=lat_matrix==1 ? (lat_full_range ? 48 : 55) : (lat_full_range ? 88 : 100);
			gv=lat_matrix==1 ? (lat_full_range ? 120 : 136) : (lat_full_range ? 183 : 208);
			bu=lat_matrix==1 ? (lat_full_range ? 475 : 541) : (lat_full_range ? 454 : 516);
			r=(scale_y*yy+rv*vv+128)>>>8;
			g=(scale_y*yy-gu*uu-gv*vv+128)>>>8;
			b=(scale_y*yy+bu*uu+128)>>>8;
			if(r<0)r=0; else if(r>255)r=255;
			if(g<0)g=0; else if(g>255)g=255;
			if(b<0)b=0; else if(b>255)b=255;
			yuv_rgb565={r[7:3],g[7:2],b[7:3]};
		end
	endfunction

	wire [3:0] mode_pos = blk_scan(i4_idx[3:0]);
	wire [1:0] mode_x = mode_pos[1:0], mode_y = mode_pos[3:2];
	wire [3:0] mode_a = mode_x==0 ? mode_left[mode_y] : i4_mode[mode_pos-1'b1];
	wire [3:0] mode_b = mode_y==0 ? mode_top[lat_mb_x*4+mode_x] : i4_mode[mode_pos-4];
	wire [3:0] mode_mpm = ((!intra_has_left && mode_x==0) || (!intra_has_above && mode_y==0)) ?
	                       4'd2 : (mode_a<mode_b ? mode_a : mode_b);

	wire [7:0]  grid_w   = lat_mb_w;
	wire [7:0]  grid_h   = lat_mb_h;
	wire [15:0] mb_count = {8'd0, grid_w} * {8'd0, grid_h};
	wire [31:0] native_samples = {16'd0,mb_count}*32'd384;
	wire        p_slice  = !STATIC_IDR_ONLY && !lat_slice_i &&
	                       ((lat_slice_type == 8'd0) || (lat_slice_type == 8'd5));
	// first_mb is admitted only at zero, and committed MBs advance in raster order.
	wire [7:0] next_mb_x = mb_index==0 || lat_mb_x+8'd1>=grid_w ? 8'd0 : lat_mb_x+8'd1;
	wire [7:0] next_mb_y = mb_index==0 ? 8'd0 :
	                       (lat_mb_x+8'd1>=grid_w ? lat_mb_y+8'd1 : lat_mb_y);

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

	// Presentation reads the cropped rectangle from promoted native YUV planes.
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
	wire [8:0] top_raddr = (nload_i >= 1 && nload_i <= 20 &&
	                                       top_base+nload_i-1 < present_coded_width) ?
	                       top_base+nload_i-1 : top_base+15;
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

	// Sixteen single-read/write banks replace a 24-way mux for each signed16
	// coefficient. ST_FILL's existing clock performs the synchronous read.
	wire coeff_store = !reset && phase==ST_CAVLC && cav_done && cav_ok &&
		((!rseq_chr && rseq_id<16) || (rseq_chr && !rseq_cdc));
	wire [4:0] coeff_store_addr = rseq_chr ? rseq_id-5'd3 : rseq_id;
	genvar coeff_bank;
	generate for (coeff_bank=0;coeff_bank<16;coeff_bank=coeff_bank+1) begin: g_coeff_bank
		(* ramstyle = "M10K" *) reg signed [15:0] samples [0:23];
		reg signed [15:0] sample_q;
		always @(posedge clk) begin
			if (coeff_store)samples[coeff_store_addr]<=cav_coeff[coeff_bank];
			if (!reset && phase==ST_FILL && ly_i<24)sample_q<=samples[ly_i];
		end
		assign recon_cavlc_coeff[coeff_bank] = recon_from_mb ?
			(coeff_read_valid ? sample_q : 16'sd0) : cavlc_coeff[coeff_bank];
	end endgenerate
	always @(posedge clk) begin
		if (reset)coeff_read_valid<=0;
		else if (phase==ST_FILL && ly_i<24)coeff_read_valid<=coeff_valid[ly_i];
	end

	// The eight column lanes are read together only at NLOAD beat zero.
	// Availability masks stale RAM; no bulk reset or asynchronous row mux.
	genvar chroma_lane;
	generate for (chroma_lane=0;chroma_lane<8;chroma_lane=chroma_lane+1) begin: g_chroma_top
		(* ramstyle = "M10K" *) reg [7:0] u_samples [0:CHR_MB_W-1];
		(* ramstyle = "M10K" *) reg [7:0] v_samples [0:CHR_MB_W-1];
		reg [7:0] u_q, v_q;
		always @(posedge clk) begin
			if (!reset && phase==ST_COMMIT && dpb_write_ready &&
			    cmt_i[5:3]==7 && cmt_i[2:0]==chroma_lane) begin
				if (filt_plane==1)u_samples[lat_mb_x]<=mb_u[56+chroma_lane];
				if (filt_plane==2)v_samples[lat_mb_x]<=mb_v[56+chroma_lane];
			end
			if (!reset && phase==ST_NLOAD && nload_i==0) begin
				u_q<=u_samples[lat_mb_x];
				v_q<=v_samples[lat_mb_x];
			end
		end
		assign chr_above_u[chroma_lane]=has_above ? u_q : 8'd128;
		assign chr_above_v[chroma_lane]=has_above ? v_q : 8'd128;
	end endgenerate

	always @(posedge clk) begin
		paint_pixel_valid <= 1'b0;
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
		dpb_frame_start <= 1'b0;
		dpb_idr_start <= 1'b0;
		filt_v       <= 1'b0;
		dpb_frm_done <= (frm_done_hold != 2'd0);
		if (frm_done_hold != 2'd0)
			frm_done_hold <= frm_done_hold - 2'd1;
		if (NATIVE_PUBLISH_LEASE && native_picture_valid && native_picture_release)
			native_picture_valid <= 1'b0;
		if (dpb_mem_waccept) begin
			// Each accepted coded macroblock contributes 384 native I420 samples.
			// 115157 = 299*384 + 256Y + 64U + 21V: last MB (19,14) V idx 21..63
			// never pulsed (43 V samples). Do not pad fake pixels.
			we_n <= we_n + 32'd1;
			if (dpb_waddr == 32'd0)
				y0_lat <= dpb_wdata;
		end
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
			decode_error    <= 0;
			recon_use_dc    <= 0;
			recon_from_mb   <= 0;
			recon_dc_value  <= 0;
			lat_filter_idc  <= 0;
			lat_chroma_offset <= 0;
			lat_full_range <= 0;
			lat_constrained_intra <= 0;
			lat_matrix <= 2;
			coeff_valid <= 0;
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
			lat_geometry_valid <= 0;
			lat_picture_is_idr <= 0;
			lat_nal_ref_idc <= 0;
			lat_max_num_ref_frames <= 0;
			lat_idr_only <= 0;
			prediction_reference_valid <= 0;
			present_meta_valid <= 0;
			native_picture_valid <= 0;
			present_crop_left <= 0; present_crop_right <= 0;
			present_crop_top <= 0; present_crop_bottom <= 0;
			present_sar_width <= 0; present_sar_height <= 0;
			present_sar_known <= 0;
			dpb_opened <= 0;
			mb_index        <= 16'd0;
			recon_sig       <= 8'd0;
			recon_dbg       <= 8'd0;
			recon_dbg_valid <= 1'b0;
			recon_valid     <= 1'b0;
			clip_gold_match <= 1'b0;
			paint_pixel_hold <= 16'd0;
			bit_len         <= '0;
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
			cav_off0        <= '0;
			win_addr        <= '0;
			win_hold        <= 2'd0;
			res_bit_start   <= '0;
			paint_hold      <= 1'b0;
			paint_reset_hold<= 1'b0;
			paint_swap_hold <= 1'b0;
			paint_base      <= 32'd0;
			paint_step <= 0;
			accepted_pixels <= 0;
			native_complete <= 0;
			we_n            <= 32'd0;
			y0_lat          <= 8'd0;
			vcl_lock        <= 1'b0;
			saw_commit      <= 1'b0;
			stop_pend       <= 1'b0;
			stop_br_eof     <= 1'b0;
			stop_rbsp_bytes <= '0;
			stop_bit_pos    <= '0;
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
			for (pi = 0; pi < 20; pi = pi + 1) begin
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
					decode_error <= 0;
					we_n <= 0;
					native_complete <= 0;
					dpb_opened <= 0;
					present_meta_valid <= 0;
					native_picture_valid <= 0;
				end
			end

			ST_WAIT_MB0: begin
				if (rbsp_done && wait_cnt != 12'd0)
					wait_cnt <= wait_cnt - 12'd1;
				if (slice_error || (rbsp_done && wait_cnt==0)) begin
					decode_error<=8'd16;
					phase<=ST_STOP;
				end else if (wait_done) begin
					lat_sps        <= sps_valid;
					lat_mb_w       <= mb_w;
					lat_mb_h       <= mb_h;
					lat_geometry_valid <= input_geometry_ok;
					lat_picture_is_idr <= picture_is_idr;
					lat_nal_ref_idc <= picture_nal_ref_idc;
					lat_max_num_ref_frames <= picture_max_num_ref_frames;
					lat_idr_only <= STATIC_IDR_ONLY || picture_idr_only;
					present_crop_left <= picture_crop_left;
					present_crop_right <= picture_crop_right;
					present_crop_top <= picture_crop_top;
					present_crop_bottom <= picture_crop_bottom;
					present_sar_width <= picture_sar_width;
					present_sar_height <= picture_sar_height;
					present_sar_known <= picture_sar_known;
					lat_res_ok     <= residual_ok;
					lat_qp         <= slice_qp;
					lat_slice_type <= slice_type;
					lat_slice_i    <= slice_is_i;
					lat_first_mb   <= first_mb;
					lat_nref       <= pps_nref;
					lat_deblock    <= pps_deblock;
					lat_filter_idc <= slice_disable_deblocking_filter_idc;
					lat_chroma_offset <= pps_chroma_qp_index_offset;
					lat_full_range <= video_full_range;
					lat_constrained_intra <= pps_constrained_intra_pred;
					lat_matrix <= video_matrix_coefficients;
					for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1) begin
						lat_coeff[coeff_i]   <= residual_coeff[coeff_i];
						cavlc_coeff[coeff_i] <= {{7{residual_coeff[coeff_i][8]}}, residual_coeff[coeff_i]};
						pred[coeff_i]        <= 8'd128;
					end
					max_coeff_r     <= 5'd16;
					recon_use_dc <= 0;
					recon_from_mb <= 0;
					recon_start     <= 1'b1;
					recon_valid     <= 1'b0;
					recon_dbg_valid <= 1'b0;
					phase           <= ST_KICK_MB0;
					if (STATIC_IDR_ONLY && (!picture_is_idr || !slice_is_i)) begin
						recon_start<=0;
						decode_error<=8'd19;
						phase<=ST_STOP;
					end
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
				// Decode only a complete captured VCL and a successful header.
				if (slice_error) begin
					decode_error<=8'd16;
					phase<=ST_STOP;
				end else if ((vcl_lock || rbsp_vcl_ok) && slice_valid && bit_pos_valid) begin
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
					tc_left_v <= 0;
					tc_up_v <= 0;
					mb_index    <= first_mb;
					// Short P after IDR: header may still show I. Force P so
					// need_skip / H_SKIP run; do not parse skip_run as I type.
					if (!slice_is_i) begin
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
					// This bounded DPB promotes every completed picture; disposable
					// VCL is unsupported until completion can retain the prior reference.
					if (slice_disable_deblocking_filter_idc != 1 || first_mb != 0 ||
					    !lat_geometry_valid || lat_nal_ref_idc==0 || !picture_reference_ok ||
					    lat_qp>51 || lat_chroma_offset < -6'sd12 || lat_chroma_offset > 6'sd12 ||
					    pps_nref != 1 || !sps_valid || !slice_valid ||
					    capture_overflow || rbsp_ram_overflow ||
					    !(video_matrix_coefficients==1 || video_matrix_coefficients==2 ||
					      video_matrix_coefficients==5 || video_matrix_coefficients==6)) begin
						decode_error <= capture_overflow || rbsp_ram_overflow ? 8'd14 :
						                slice_disable_deblocking_filter_idc != 1 ? 8'd1 :
						                !lat_geometry_valid ? 8'd17 :
						                lat_nal_ref_idc==0 ? 8'd18 :
						                !picture_reference_ok ? 8'd19 : 8'd2;
						phase <= ST_STOP;
					end else begin
						dpb_frame_start <= 1;
						dpb_idr_start <= lat_picture_is_idr;
						if(lat_picture_is_idr)prediction_reference_valid<=0;
						dpb_opened <= 1;
						present_meta_valid <= 1;
						phase <= ST_MB_SETUP;
					end
				end
			end

			ST_MB_SETUP: begin
				if (mb_index >= mb_count) begin
					phase        <= ST_TAIL;
					tail_bits <= 5'd8-{2'd0,br_bit_pos[2:0]};
					br_un <= 5'd8-{2'd0,br_bit_pos[2:0]};
					br_start_u <= 1;
					x            <= present_crop_left[9:0];
					y            <= present_crop_top[9:0];
					paint_reset_hold <= 1'b1;
					paint_swap_hold  <= 1'b0;
					paint_hold   <= 1'b1;
					paint_step <= 0;
					accepted_pixels <= 0;
					if (mb_index != mb_count || we_n != native_samples || decode_error != 0 ||
					    bit_len-br_bit_pos != RBSP_BIT_W'(8)-RBSP_BIT_W'(br_bit_pos[2:0])) begin
						decode_error<=8'd8;
						br_start_u<=0;
						phase<=ST_STOP;
					end
					// synopsys translate_off
					$display("GRID_DONE mb_index=%0d frames_out=%0d we_n=%0d",
					         mb_index, frames_out + 16'd1, we_n);
					// synopsys translate_on
				end else begin
					lat_mb_x  <= next_mb_x;
					lat_mb_y  <= next_mb_y;
					dpb_fmb_x <= next_mb_x;
					dpb_fmb_y <= next_mb_y;
					has_left  <= next_mb_x!=0;
					has_above <= next_mb_y!=0;
					nload_i     <= 5'd0;
					is_pskip    <= 1'b0;
					is_p16      <= 1'b0;
					is_i16      <= 1'b0;
					is_intra_mb <= STATIC_IDR_ONLY;
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
					coeff_valid <= 0;
					chroma_mode <= 0;
					for (pi=0;pi<4;pi=pi+1) begin
						chr_dc_u[pi]<=0; chr_dc_v[pi]<=0;
					end
					for (pi=0;pi<8;pi=pi+1) tc_chr_cur[pi]<=0;
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
				if (nload_i < 5'd22) begin
					if (nload_i == 5'd0) begin
						top_left_pix <= (has_above && has_left && (lat_mb_x != 8'd0)) ?
						                 above16[15] : 8'd128;
						chr_tl_u <= has_above && has_left ? chr_above_u[7] : 8'd128;
						chr_tl_v <= has_above && has_left ? chr_above_v[7] : 8'd128;
					end else if (nload_i >= 5'd2)
						above16[nload_q_i] <= has_above ? top_rdata : 8'd128;
					if (nload_i < 5'd16)
						left16[nload_i[3:0]] <= has_left ? left_col[nload_i[3:0]] : 8'd128;
					if (!STATIC_IDR_ONLY && nload_i == 5'd0) begin
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
				if (br_eof && !rbsp_done) begin
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
					if (!br_syn_ok && !rbsp_done)
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
				H_SKIP: if (STATIC_IDR_ONLY) begin
					decode_error<=8'd19;
					phase<=ST_STOP;
				end else begin
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
					if (ue_val > mb_count-mb_index) begin decode_error<=8'd3; phase<=ST_STOP; end
				end
				H_TYPE: begin
					if (STATIC_IDR_ONLY || lat_slice_i) begin
						cur_mbt <= ue_val[7:0];
						if (ue_val == 16'd0) begin
							is_intra_mb <= 1'b1;
							is_i16 <= 1'b0;
							i4_idx <= 0;
							i4_sub <= 0;
							i4_syn <= 1;
							ue_signed <= 0;
							phase <= ST_UE_BIT;
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
					if (ue_val>30) begin decode_error<=8'd3; phase<=ST_STOP; end
				end
				H_CHR: begin
					chroma_mode <= ue_val[1:0];
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
					if (ue_val > 3) begin decode_error<=8'd3; phase<=ST_STOP; end
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
					if (ue_val > 47) begin decode_error<=8'd4; phase<=ST_STOP; end
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
						lat_qp <= $signed({10'b0, lat_qp}) + se_val + 16'sd52;
					else if ($signed({10'b0, lat_qp}) + se_val > 16'sd51)
						lat_qp <= $signed({10'b0, lat_qp}) + se_val - 16'sd52;
					else
						lat_qp <= lat_qp + se_val[5:0];
					res_armed <= 1'b1;
					// synopsys translate_off
					if ((mb_index <= 16'd1) || (mb_index == 16'd40))
						$display("BITPOS_AFTER_H_QP mb_index=%0d bit_pos=%0d se=%0d cbp=%0d type=%0d i16=%0d",
						         mb_index, bit_pos, se_val, cur_cbp, cur_mbt, is_i16);
					// synopsys translate_on
					phase     <= ST_RES_DEC;
					if (se_val < -26 || se_val > 25) begin decode_error<=8'd5; phase<=ST_STOP; end
				end
				H_REF: if (STATIC_IDR_ONLY) begin
					decode_error<=8'd19;
					phase<=ST_STOP;
				end else begin
					hdr_st    <= H_MVDX;
					ue_signed <= 1'b1;
					ue_z      <= 6'd0;
					phase     <= ST_UE_BIT;
				end
				H_MVDX: if (STATIC_IDR_ONLY) begin
					decode_error<=8'd19;
					phase<=ST_STOP;
				end else begin
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
				H_MVDY: if (STATIC_IDR_ONLY) begin
					decode_error<=8'd19;
					phase<=ST_STOP;
				end else begin
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
				H_GO: if (STATIC_IDR_ONLY) begin
					decode_error<=8'd19;
					phase<=ST_STOP;
				end else begin
					// pdec sees latched cur_mbt_p. Only P_L0_16x16 (mode 0) continues.
					if (pdec_unsup || pdec_sub || (pdec_mode != 3'd0)) begin
						decode_error <= 8'd20;
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
						i4_mode[mode_pos] <= mode_mpm;
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
					i4_mode[mode_pos] <= ue_val[2:0] < mode_mpm ? {1'b0,ue_val[2:0]} :
					                                                     {1'b0,ue_val[2:0]}+4'd1;
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
				if (!STATIC_IDR_ONLY && is_pskip) begin
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
					if (!STATIC_IDR_ONLY && is_p16 && cur_cbp[3:0]==0) begin
						// A signalled uncoded inter plane is exactly its MC
						// prediction; do not spend 16 zero-transform handshakes.
						for (pi=0;pi<256;pi=pi+1)
							mb_pix[pi] <= pel_copy ? mc_luma[pi] : mc_pred_y[pi];
						ly_i<=16;
						if (cur_cbp==0) begin
							fill_unc<=0;
							cmt_i<=0;
							filt_plane<=0;
							phase<=ST_COMMIT;
						end
					end
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
					win_count     <= 8'd32;
					win_hold      <= 2'd0;
					res_bit_start <= br_bit_pos;
					win_base      <= br_bit_pos[RBSP_BIT_W-1:3];
					win_addr      <= RBSP_ADDR_W'(br_bit_pos>>3);
					// synopsys translate_off
					if (mb_index <= 16'd4)
						$display("RESIDUAL_START mb=%0d bit_pos=%0d id=%0d rseq_tab=%0d max=%0d",
						         mb_index, br_bit_pos, rseq_id, rseq_tab, rseq_max);
					// synopsys translate_on
					phase    <= ST_WIN;
				end
			end

			ST_WIN: begin
				// One synchronous RAM read per clock after priming. Small
				// windows retry at 64/128 bytes only when CAVLC needs more.
				if (win_hold == 2'd0) begin
					if (win_i == 7'd0) begin
						cav_off0    <= {8'd0, res_bit_start[2:0]};
						max_coeff_r <= rseq_max;
						if (rseq_cdc || (rseq_tab == 3'd4))
							cav_table <= 3'd4;
						else
							cav_table <= tok_tab;
					end
					win_hold <= 2'd1;
					win_addr <= win_addr+1'b1;
				end else begin
					cav_rbsp[win_i] <= win_base+win_i < rbsp_bytes ? ram_rd : 8'd0;
					// synopsys translate_off
					if ((mb_index <= 16'd1) && (win_i <= 7'd1))
						$display("WINBYTE mb=%0d i=%0d addr=%0d rd=%02h",
						         mb_index, win_i, win_addr, ram_rd);
					// synopsys translate_on
					if ({1'b0,win_i}+8'd1 == win_count) begin
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
						win_addr <= win_addr + 1'b1;
					end
				end
			end

			ST_CAVLC: begin
				if (cav_done) begin
					// synopsys translate_off
					$display("CAVLC mb=%0d id=%0d chr=%b cdc=%b tab=%0d nC=%0d max=%0d tc=%0d t1=%0d tz=%0d ok=%b off0=%0d end=%0d bit=%0d b0=%02h b1=%02h",
					         mb_index, rseq_id, rseq_chr, rseq_cdc, cav_table,
					         rseq_cdc ? -1 : int'(nC_w), max_coeff_r,
					         cav_tc, cav_t1, cav_tz, cav_ok, cav_off0, cav_bit_end, br_bit_pos,
					         cav_rbsp[0], cav_rbsp[1]);
					if (rseq_id == 5'd16)
						$display("LDC mb=%0d tc=%0d t1=%0d tab=%0d nC=%0d rseq_tab=%0d start=%0d end=%0d",
						         mb_index, cav_tc, cav_t1, cav_table, nC_w, rseq_tab, res_bit_start,
						         (RBSP_BIT_W'(win_base)<<3) + RBSP_BIT_W'(cav_bit_end));
					// synopsys translate_on
					if (!cav_ok) begin
						if (win_count<128 && window_available_bits>(RBSP_BIT_W'(win_count)<<3)) begin
							win_count<=win_count<<1;
							win_i<=0;win_hold<=0;win_addr<=RBSP_ADDR_W'(win_base);
							phase<=ST_WIN;
						end else begin decode_error<=8'd11; phase<=ST_STOP; end
					end else begin
					// Reload from latched window base + CAVLC end.
					br_load     <= 1'b1;
					br_load_pos <= (RBSP_BIT_W'(win_base)<<3) + RBSP_BIT_W'(cav_bit_end);
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
					if (!rseq_chr && rseq_id < 16) begin
						coeff_valid[rseq_id] <= 1;
					end else if (rseq_chr && !rseq_cdc) begin
						coeff_valid[rseq_id-3] <= 1;
					end else if (rseq_cdc) begin
						for (coeff_i=0;coeff_i<4;coeff_i=coeff_i+1) begin
							if (rseq_cb)
								chr_dc_u[coeff_i] <= chroma_dc_scale(
									chroma_dc_wide[0] +
									(coeff_i[0] ? -chroma_dc_wide[1] : chroma_dc_wide[1]) +
									(coeff_i[1] ? -chroma_dc_wide[2] : chroma_dc_wide[2]) +
									(coeff_i[0]^coeff_i[1] ? -chroma_dc_wide[3] : chroma_dc_wide[3]),
									chroma_qp);
							else
								chr_dc_v[coeff_i] <= chroma_dc_scale(
									chroma_dc_wide[0] +
									(coeff_i[0] ? -chroma_dc_wide[1] : chroma_dc_wide[1]) +
									(coeff_i[1] ? -chroma_dc_wide[2] : chroma_dc_wide[2]) +
									(coeff_i[0]^coeff_i[1] ? -chroma_dc_wide[3] : chroma_dc_wide[3]),
									chroma_qp);
						end
					end
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
					rseq_adv <= 1'b1;
					rseq_wait <= 1'b1;
					phase <= ST_RES_DEC;
					end
				end
			end

			ST_PRED: begin
				if (ly_i >= 16) begin
					for (coeff_i=0;coeff_i<16;coeff_i=coeff_i+1) begin
						pred[coeff_i] <= is_intra_mb ? chr_pred[coeff_i] :
							(ly_i[2] ? mb_v[{blk_y[0],coeff_i[3:2],blk_x[0],coeff_i[1:0]}] :
							           mb_u[{blk_y[0],coeff_i[3:2],blk_x[0],coeff_i[1:0]}]);
					end
					recon_start<=1;
					phase<=ST_KICK_BLK;
					if (is_intra_mb && ((chroma_mode==1 && !intra_has_left) ||
					    (chroma_mode==2 && !intra_has_above) ||
					    (chroma_mode==3 && (!intra_has_left || !intra_has_above || !intra_has_tl)))) begin
						recon_start<=0; decode_error<=8'd6; phase<=ST_STOP;
					end
				end else if (is_intra_mb && !is_i16 && !pred_nb) begin
					for (coeff_i = 0; coeff_i < 4; coeff_i = coeff_i + 1) begin
						left4p[coeff_i]  <= (blk_x == 2'd0) ? left16[{blk_y, coeff_i[1:0]}] :
							mb_pix[{blk_y, coeff_i[1:0], blk_x, 2'd0} - 8'd1];
						above4[coeff_i]  <= (blk_y == 2'd0) ? above16[{blk_x, coeff_i[1:0]}] :
							mb_pix[({blk_y - 2'd1, 2'd3, blk_x, coeff_i[1:0]})];
						if (blk_y==0)
							above4[coeff_i+4] <= blk_x==3 && lat_constrained_intra &&
								(lat_mb_x+1>=grid_w || (!STATIC_IDR_ONLY && mv_row_v[lat_mb_x+1])) ?
								above16[15] : above16[blk_x*4+coeff_i+4];
						else if (blk_x<3 && blk_scan({blk_y-2'd1,blk_x+2'd1}) < ly_i)
							above4[coeff_i+4] <= mb_pix[(blk_y*4-1)*16+blk_x*4+coeff_i+4];
						else
							above4[coeff_i+4] <= mb_pix[(blk_y*4-1)*16+blk_x*4+3];
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
						if (!i16_busy && !i16_done && !i16_start)
							i16_start <= 1'b1;
					end else if (!hdc_valid) begin
					end else begin
						recon_dc_value <= i16_dc[{blk_y,blk_x}];
						for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
							pred[coeff_i] <= i16_pred[({2'd0, blk_y} * 4 + {2'd0, coeff_i[3:2]}) * 16 +
							                           ({2'd0, blk_x} * 4 + {2'd0, coeff_i[1:0]})];
						recon_start <= 1'b1;
						phase       <= ST_KICK_BLK;
						if (i16_unsup || (i16_mode==3 && !intra_has_tl)) begin
							recon_start<=0; decode_error<=8'd6; phase<=ST_STOP;
						end
					end
				end else if (is_intra_mb) begin
					pred_nb <= 1'b0;
					for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
						pred[coeff_i] <= i4_pred[coeff_i];
					recon_start <= 1'b1;
					phase       <= ST_KICK_BLK;
					if (i4_used != i4_mode[{blk_y,blk_x}] ||
					    (blk_x==0 && blk_y==0 && !intra_has_tl && i4_used>=4 && i4_used<=6)) begin
						recon_start<=0; decode_error<=8'd6; phase<=ST_STOP;
					end
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
					if (ly_i >= 16) begin
						for (coeff_i=0;coeff_i<16;coeff_i=coeff_i+1)
							if (ly_i[2]) mb_v[{blk_y[0],coeff_i[3:2],blk_x[0],coeff_i[1:0]}] <= recon_blk[coeff_i];
							else mb_u[{blk_y[0],coeff_i[3:2],blk_x[0],coeff_i[1:0]}] <= recon_blk[coeff_i];
					end else begin
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
					if (!recon_ok) begin decode_error<=8'd7; phase<=ST_STOP; end
				end
			end

			ST_FILL: begin
				// Reconstruct every luma block in decoding order, including
				// uncoded blocks, before using it as an intra neighbour.
				if (ly_i >= 5'd24) begin
					fill_unc <= 1'b0;
					cmt_i <= 0;
					filt_plane <= 0;
					phase <= ST_COMMIT;
				end else begin
					recon_from_mb <= 1;
					max_coeff_r <= ly_i>=16 || is_i16 ? 15 : 16;
					recon_use_dc <= ly_i>=16 || is_i16;
					recon_dc_value <= ly_i>=16 ?
						(ly_i[2] ? chr_dc_v[ly_i[1:0]] : chr_dc_u[ly_i[1:0]]) : 0;
					blk_x <= ly_i>=16 ? {1'b0,ly_i[0]} : scan[1:0];
					blk_y <= ly_i>=16 ? {1'b0,ly_i[1]} : scan[3:2];
					pred_nb   <= 1'b0;
					phase     <= ST_PRED;
				end
			end

			ST_DB_LD: if (STATIC_IDR_ONLY) begin
				decode_error<=8'd1;
				phase<=ST_STOP;
			end else begin
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
				decode_error <= 8'd1;
				phase <= ST_STOP;
			end

			ST_DB_WR: if (STATIC_IDR_ONLY) begin
				decode_error<=8'd1;
				phase<=ST_STOP;
			end else begin
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
				decode_error <= 8'd1;
				phase <= ST_STOP;
			end

			ST_COMMIT: if (dpb_write_ready) begin
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
					if (filt_plane==1) begin
						if (cmt_i[2:0]==7) chr_left_u[cmt_i[5:3]]<=mb_u[cmt_i[5:0]];
					end else begin
						if (cmt_i[2:0]==7) chr_left_v[cmt_i[5:3]]<=mb_v[cmt_i[5:0]];
					end
					filt_idx <= {2'd0, cmt_i[5:0]};
					if (store_uv && (filt_plane == 2'd1))
						filt_s <= mb_u[cmt_i[5:0]];
					else if (store_uv && (filt_plane == 2'd2))
						filt_s <= mb_v[cmt_i[5:0]];
					else
						filt_s <= 8'd128;
				end
				if (filt_plane == 2'd0 && cmt_i == 8'd255) begin
					for (pi=0;pi<4;pi=pi+1) begin
						mode_left[pi] <= is_intra_mb && !is_i16 ? i4_mode[pi*4+3] : 4'd2;
						mode_top[lat_mb_x*4+pi] <= is_intra_mb && !is_i16 ? i4_mode[12+pi] : 4'd2;
					end
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
					if (!STATIC_IDR_ONLY) begin
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
					end
					// 7.3.4: mb_skip_run only after a coded MB (not after P_Skip).
					need_skip  <= p_slice && !is_pskip;
					filt_plane <= 2'd1;
					cmt_i      <= 8'd0;
				end else if (filt_plane == 2'd1 && cmt_i == 8'd63) begin
					filt_plane <= 2'd2;
					cmt_i      <= 8'd0;
				end else if (filt_plane == 2'd2 && cmt_i == 8'd63) begin
					mb_index <= mb_index+16'd1;
					saw_commit <= 1'b1;
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

			ST_DPB_KICK: if (STATIC_IDR_ONLY) begin
				decode_error<=8'd19;
				phase<=ST_STOP;
			end else begin
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

			ST_DPB_WAIT: if (STATIC_IDR_ONLY) begin
				decode_error<=8'd19;
				phase<=ST_STOP;
			end else begin
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
					if (dpb_fetch_err && !dpb_kick) begin decode_error<=8'd9; phase<=ST_STOP; end
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
				begin
					vcl_lock   <= 1'b0;
					phase      <= ST_IDLE;
					busy       <= 1'b0;
					done       <= 1'b0;
					paint_hold <= 1'b0;
					recon_valid <= 1'b0;
					present_meta_valid <= 0;
					prediction_reference_valid <= 0;
					native_picture_valid <= 0;
					if (decode_error==0) decode_error<=8'd10;
				end
			end

			ST_PAINT: begin
				// DPB Y → RGB565. Advance only on paint_ack (wr_ready AND present_sel).
				// Reset, then Q, then wr_en held until accepted. swap after last pixel,
				// held until present accepts. Never wr_en+swap same cycle (cmd mux).
				// synopsys translate_off
				if (paint_hold)
					$display("ST_PAINT phase=%0d hdr_st=%0d br_eof=%0d br_syn_ok=%0d ue_val=%0d mb_index=%0d lat_mb_w=%0d lat_mb_h=%0d mb_count=%0d rbsp_bytes=%0d br_bit_pos=%0d we_n=%0d Y0=%0d frames_out=%0d paint_base=%0d paint_ack=%0d",
					         phase, hdr_st, br_eof, br_syn_ok, ue_val, mb_index, lat_mb_w, lat_mb_h, mb_count, rbsp_bytes, bit_pos, we_n, y0_lat, frames_out, paint_base, paint_ack);
				// synopsys translate_on
				if (paint_reset_hold) begin
					if (wr_reset_ptr && paint_ack)
						paint_reset_hold <= 1'b0;
					else
						wr_reset_ptr <= 1'b1;
				end else if (paint_swap_hold) begin
					if (swap_req && paint_ack) begin
						paint_swap_hold <= 1'b0;
						x          <= 10'd0;
						y          <= 10'd0;
						paint_hold <= 1'b0;
						if (native_complete && accepted_pixels==visible_pixels && we_n==native_samples &&
						    mb_index==mb_count && decode_error==0) begin
							frames_out<=frames_out+16'd1;
							done<=1;
							if(NATIVE_PUBLISH_LEASE && native_picture_valid && !native_picture_release)
								phase<=ST_NATIVE_RELEASE;
							else begin
								native_picture_valid<=0;
								busy<=0;
								vcl_lock<=0;
								phase<=ST_IDLE;
							end
						end else begin
							decode_error<=8'd8;
							phase<=ST_STOP;
						end
					end else
						swap_req <= 1'b1;
				end else begin
					paint_hold<=0;
					case(paint_step)
					0:paint_step<=1;
					1:if(dpb_mem_rvalid)begin
						paint_y_sample<=dpb_mem_rdata;
						if(paint_need_chroma)paint_step<=3;
						else if(!paint_ack) begin
							paint_pixel_hold<=paint_response_pixel;
							paint_pixel_valid<=1;
							paint_step<=6;
						end
					end
					3:if(dpb_mem_rvalid)begin
						paint_u_sample<=dpb_mem_rdata;
						paint_u_line[x>>1]<=dpb_mem_rdata;
						paint_step<=5;
					end
					5:if(dpb_mem_rvalid)begin
						paint_v_line[x>>1]<=dpb_mem_rdata;
						if(!paint_ack) begin
							paint_pixel_hold<=paint_response_pixel;
							paint_pixel_valid<=1;
							paint_step<=6;
						end
					end
					6:if(!paint_ack)paint_pixel_valid<=1;
					default:paint_step<=0;
					endcase
					if (wr_en && paint_ack) begin
						accepted_pixels<=accepted_pixels+1'b1;
						paint_step<=1;
						if ((x == paint_last_x) && (y == paint_last_y)) begin
							paint_hold      <= 1'b0;
							if (native_complete && accepted_pixels==visible_pixels-1 && we_n==native_samples &&
							    mb_index==mb_count && decode_error==0)
								paint_swap_hold<=1;
							else begin decode_error<=8'd8; phase<=ST_STOP; end
						end else if (x == paint_last_x) begin
							x          <= present_crop_left[9:0];
							y          <= y + 10'd1;
						end else begin
							x          <= x + 10'd1;
						end
					end
				end
			end

			ST_PUBLISH: begin
				if(dpb_frame_promoted) begin
					native_complete<=1;
					native_picture_valid<=1;
					prediction_reference_valid<=lat_max_num_ref_frames==1;
					paint_base<=dpb_ref_base;
					phase<=ST_PAINT;
				end else if(dpb_frame_error) begin
					decode_error<=8'd13;
					phase<=ST_STOP;
				end
			end

			ST_NATIVE_RELEASE: begin
				if(!native_picture_valid || native_picture_release) begin
					native_picture_valid<=0;
					busy<=0;
					vcl_lock<=0;
					phase<=ST_IDLE;
				end
			end

			ST_TAIL: if (br_syn_done) begin
				if (br_syn_ok && br_ue == (16'd1 << (tail_bits-1'b1))) begin
					frm_done_hold<=1;
					phase<=ST_PUBLISH;
				end
				else begin decode_error<=8'd15; phase<=ST_STOP; end
			end

			default: phase <= ST_IDLE;
			endcase
			if (busy && vcl_pulse) begin decode_error<=8'd12; phase<=ST_STOP; end
			else if (busy && dpb_opened && !dpb_frame_start && !dpb_idr_start &&
			         phase!=ST_STOP && dpb_frame_error) begin
				decode_error<=8'd13; phase<=ST_STOP;
			end
		end
	end

endmodule
