// Phase 3.3–3.3l-1: F3 → FIFO → NAL → SPS/PPS/slice_hdr + h264_decode_core.
// Hybrid: stub diagnostic paint is F3-only; host F1 recon owns product present (Plex.sv).

module stream_path #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [7:0]  ioctl_dout,
	input  wire        enable,
	input  wire        flush,

	input  wire        ddr_stream_enable,
	output wire        ddr_bus_want,
	input  wire        ddr_busy,
	output wire  [7:0] ddr_burstcnt,
	output wire [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output wire        ddr_rd,
	output wire [63:0] ddr_din,
	output wire  [7:0] ddr_be,
	output wire        ddr_we,

	output wire        has_stream,
	output wire [15:0] nalu_count,
	output wire [7:0]  last_nal_type,
	output wire [31:0] bytes_in,
	output wire [31:0] bytes_seen,
	output wire [15:0] fifo_level,
	output wire        stream_ddr_active,
	output wire [31:0] stream_ddr_bytes_out,
	output wire [15:0] stream_ddr_underruns,
	output wire [15:0] stream_ddr_overruns,
	output wire [31:0] stream_ddr_host_write,
	output wire [31:0] stream_ddr_fpga_read,

	output wire        has_idr,
	output wire [7:0]  idr_count,
	output wire [7:0]  sps_count,
	output wire [7:0]  pps_count,
	output wire [7:0]  slice_count,
	output wire [15:0] stub_frames,
	output wire        stub_busy,

	output wire        sps_valid,
	output wire [7:0]  sps_profile,
	output wire [7:0]  sps_level,
	output wire [15:0] sps_width,
	output wire [15:0] sps_height,
	output wire [7:0]  sps_mb_w,
	output wire [7:0]  sps_mb_h,

	output wire        pps_valid,
	output wire        slice_valid,
	output wire [7:0]  slice_type,
	output wire        slice_is_i,
	output wire [7:0]  first_mb_type,
	output wire        has_mb_type,
	output wire        first_mb_p_skip,
	output wire [7:0]  p_skip_run,
	output wire [2:0]  first_mb_part_mode,
	output wire [2:0]  first_mb_part_count,
	output wire        first_mb_uses_sub_mb,
	output wire        first_mb_intra,
	output wire [5:0]  slice_qp,
	output wire [1:0]  disable_deblocking_filter_idc,
	output wire signed [4:0] slice_alpha_c0_offset_div2,
	output wire signed [4:0] slice_beta_offset_div2,
	output wire signed [4:0] slice_alpha_c0_offset,
	output wire signed [4:0] slice_beta_offset,
	output wire [4:0]  residual_tc,
	output wire [1:0]  residual_t1,
	output wire        residual_ok,
	output wire signed [7:0] residual_dc,
	// 3.3l-1: residualCsum8=XOR sat8(coeff[0:15]); full coeffs for 3.3l-2 inv_quant.
	// residual_coeff may be left unconnected at top until inv_quant; kept below.
	output wire [7:0]  residual_csum,
	output wire signed [15:0] residual_coeff [0:15],
	// Product CAVLC handoff: first-I_NxN staging emits one pulse per luma 4x4 block.
	output wire        luma4x4_valid,
	output wire [3:0]  luma4x4_idx,
	output wire [5:0]  luma4x4_qp,
	output wire [4:0]  luma4x4_total_coeff,
	output wire [1:0]  luma4x4_trailing_ones,
	output wire [9:0]  luma4x4_bit_offset_end,
	output wire signed [15:0] luma4x4_coeff_zigzag [0:15],
	output wire        luma4x4_source_busy,
	output wire        luma4x4_source_done,
	output wire        luma4x4_source_ok,
	output wire [9:0]  luma4x4_source_bit_end,
	output wire [3:0]  i4_modes [0:15],
	output wire [15:0] i4_pred_mode_flags,
	output wire [47:0] i4_rem_modes,
	output wire [9:0]  first_mb_residual_bit_offset,
	output wire [3:0]  first_mb_cbp_luma,
	output wire [1:0]  first_mb_cbp_chroma,
	output wire        mb_syntax_valid,
	output wire [15:0] mb_syntax_addr,
	output wire [7:0]  mb_syntax_x,
	output wire [7:0]  mb_syntax_y,
	output wire [3:0]  mb_syntax_class,
	output wire [4:0]  mb_syntax_type,
	output wire        mb_syntax_p_skip,
	output wire [2:0]  mb_syntax_part_mode,
	output wire [2:0]  mb_syntax_part_count,
	output wire        mb_syntax_uses_sub_mb,
	output wire        mb_syntax_unsupported,
	output wire [1:0]  mb_syntax_ref_idx_l0 [0:3],
	output wire signed [15:0] mb_syntax_mvd_x_qpel [0:3],
	output wire signed [15:0] mb_syntax_mvd_y_qpel [0:3],
	output wire [1:0]  mb_syntax_sub_mb_type [0:3],
	output wire [3:0]  mb_syntax_cbp_luma,
	output wire [1:0]  mb_syntax_cbp_chroma,
	output wire signed [5:0] mb_syntax_mb_qp_delta,
	output wire [5:0]  mb_syntax_qpy,
	output wire [5:0]  mb_syntax_qpc,
	output wire [15:0] mb_syntax_residual_bit_offset,
	input  wire        mb_syntax_accept,
	// R-csum6 Rank3: 1-cycle ST_PLACE pulse for status residual sticky freeze
	output wire        residual_place_pulse,
	output wire [7:0]  recon_sig,
	output wire [7:0]  recon_dbg,
	output wire        recon_dbg_valid,
	output wire        recon_valid,

	output wire        fs_wr_en,
	output wire [15:0] fs_wr_pixel,
	output wire        fs_wr_reset,
	output wire        fs_swap
);

	wire        si_wr_en;
	wire [7:0]  si_wr_data;
	wire        si_wr_flush;
	wire        si_active;

	stream_ingest si (
		.clk(clk), .reset(reset),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_dout(ioctl_dout),
		.enable(enable),
		.wr_en(si_wr_en), .wr_data(si_wr_data), .wr_flush(si_wr_flush),
		.active(si_active), .bytes_in(bytes_in)
	);

	wire        ddr_wr_en;
	wire [7:0]  ddr_wr_data;
	wire        ddr_wr_flush;
	wire        bf_wr_full;

	ddr_bitstream_reader ddr_stream (
		.clk(clk), .reset(reset),
		.enable(ddr_stream_enable),
		.flush(flush),
		.out_valid(ddr_wr_en),
		.out_byte(ddr_wr_data),
		.out_flush(ddr_wr_flush),
		.out_full(bf_wr_full | si_wr_en),
		.bus_want(ddr_bus_want),
		.DDRAM_BUSY(ddr_busy),
		.DDRAM_BURSTCNT(ddr_burstcnt),
		.DDRAM_ADDR(ddr_addr),
		.DDRAM_DOUT(ddr_dout),
		.DDRAM_DOUT_READY(ddr_dout_ready),
		.DDRAM_RD(ddr_rd),
		.DDRAM_DIN(ddr_din),
		.DDRAM_BE(ddr_be),
		.DDRAM_WE(ddr_we),
		.active(stream_ddr_active),
		.bytes_out(stream_ddr_bytes_out),
		.underrun_count(stream_ddr_underruns),
		.overrun_count(stream_ddr_overruns),
		.host_write_count(stream_ddr_host_write),
		.fpga_read_count(stream_ddr_fpga_read)
	);

	wire bf_rd_en, bf_rd_empty, bf_has;
	wire [7:0] bf_rd_data;
	wire bf_wr_en = si_wr_en | ddr_wr_en;
	wire [7:0] bf_wr_data = si_wr_en ? si_wr_data : ddr_wr_data;
	wire bf_wr_flush = si_wr_flush | ddr_wr_flush | flush;

	bitstream_fifo #(.DEPTH(32768)) bfifo (
		.clk(clk), .reset(reset),
		.wr_en(bf_wr_en), .wr_data(bf_wr_data), .wr_flush(bf_wr_flush),
		.wr_full(bf_wr_full), .wr_level(fifo_level),
		.rd_en(bf_rd_en), .rd_data(bf_rd_data), .rd_empty(bf_rd_empty), .has_data(bf_has)
	);

	wire vcl_pulse, has_idr_w;
	wire [7:0] idr_c, sps_c, pps_c, slc_c;
	wire sps_cap_clear, sps_cap_en, sps_cap_end;
	wire [7:0] sps_cap_data;
	wire pps_cap_clear, pps_cap_en, pps_cap_end;
	wire [7:0] pps_cap_data;
	wire sl_cap_clear, sl_cap_en, sl_cap_end, sl_is_idr, sl_nal_ref_idc_nonzero;
	wire [7:0] sl_cap_data;

	nalu_scanner scan (
		.clk(clk), .reset(reset | flush),
		.rd_data(bf_rd_data), .rd_empty(bf_rd_empty), .rd_en(bf_rd_en),
		.nalu_count(nalu_count), .last_nal_type(last_nal_type),
		.has_stream(has_stream), .bytes_seen(bytes_seen),
		.idr_count(idr_c), .sps_count(sps_c), .pps_count(pps_c), .slice_count(slc_c),
		.has_idr(has_idr_w), .vcl_pulse(vcl_pulse),
		.sps_cap_clear(sps_cap_clear), .sps_cap_en(sps_cap_en),
		.sps_cap_data(sps_cap_data), .sps_cap_end(sps_cap_end),
		.pps_cap_clear(pps_cap_clear), .pps_cap_en(pps_cap_en),
		.pps_cap_data(pps_cap_data), .pps_cap_end(pps_cap_end),
		.sl_cap_clear(sl_cap_clear), .sl_cap_en(sl_cap_en),
		.sl_cap_data(sl_cap_data), .sl_cap_end(sl_cap_end), .sl_is_idr(sl_is_idr),
		.sl_nal_ref_idc_nonzero(sl_nal_ref_idc_nonzero)
	);

	assign has_idr     = has_idr_w;
	assign idr_count   = idr_c;
	assign sps_count   = sps_c;
	assign pps_count   = pps_c;
	assign slice_count = slc_c;

	wire [4:0] log2_fn;
	wire [2:0] poc_t;
	wire sps_busy;

	sps_parser sps (
		.clk(clk), .reset(reset | flush),
		.cap_clear(sps_cap_clear), .cap_en(sps_cap_en),
		.cap_data(sps_cap_data), .cap_end(sps_cap_end),
		.valid(sps_valid), .profile_idc(sps_profile), .level_idc(sps_level),
		.width(sps_width), .height(sps_height),
		.log2_max_frame_num(log2_fn), .poc_type(poc_t),
		.mb_width(sps_mb_w), .mb_height(sps_mb_h),
		.busy(sps_busy)
	);

	wire pps_busy, pps_cabac, pps_deblock;
	wire [7:0] pps_id_w, pps_sps_id, pps_nref;
	wire signed [7:0] pps_qp;

	wire signed [4:0] pps_chroma_qp_off;
	pps_parser pps (
		.clk(clk), .reset(reset | flush),
		.cap_clear(pps_cap_clear), .cap_en(pps_cap_en),
		.cap_data(pps_cap_data), .cap_end(pps_cap_end),
		.valid(pps_valid), .pps_id(pps_id_w), .sps_id(pps_sps_id),
		.entropy_cabac(pps_cabac), .num_ref_l0(pps_nref),
		.pic_init_qp(pps_qp), .chroma_qp_index_offset(pps_chroma_qp_off), .deblock_ctrl(pps_deblock), .busy(pps_busy)
	);

	wire sl_busy, sl_is_i, sl_has_mbt, sl_res_ok;
	wire [15:0] sl_first, sl_fn, sl_idr_pic;
	wire [7:0] sl_type, sl_pps, sl_mbt;
	wire signed [7:0] sl_qpd, sl_rdc;
	wire [5:0] sl_qp;
	wire [9:0] sl_first_mb_residual_bit_offset;
	wire [3:0] sl_first_mb_cbp_luma;
	wire [1:0] sl_first_mb_cbp_chroma;
	wire [15:0] sl_first_mb_i4_flags;
	wire [47:0] sl_first_mb_i4_rem_modes;
	wire [1:0] sl_deblock_idc;
	wire signed [4:0] sl_alpha_div2, sl_beta_div2, sl_alpha_off, sl_beta_off;
	wire [4:0] sl_rtc;
	wire [1:0] sl_rt1;
	wire sl_place_ok;
	wire [4:0] sl_place_tc;
	wire [1:0] sl_place_t1;
	wire signed [7:0] sl_place_dc;
	wire [5:0] sl_place_qp;
	wire signed [15:0] sl_place_coeff [0:15];
	reg [7:0] sl_rbsp [0:127];
	reg [7:0] sl_rbsp_len;
	integer sl_rbsp_i;
	always @(posedge clk) begin
		if (reset | flush | sl_cap_clear) begin
			sl_rbsp_len <= 8'd0;
			for (sl_rbsp_i = 0; sl_rbsp_i < 128; sl_rbsp_i = sl_rbsp_i + 1)
				sl_rbsp[sl_rbsp_i] <= 8'd0;
		end else if (sl_cap_en && sl_rbsp_len < 8'd128) begin
			sl_rbsp[sl_rbsp_len[6:0]] <= sl_cap_data;
			sl_rbsp_len <= sl_rbsp_len + 8'd1;
		end
	end

	// residual_csum / residual_coeff connect straight to module outputs (no
	// unpacked-array continuous assign — Quartus-friendly).
	slice_hdr_parser slp (
		.clk(clk), .reset(reset | flush),
		.cap_clear(sl_cap_clear), .cap_en(sl_cap_en),
		.cap_data(sl_cap_data), .cap_end(sl_cap_end),
		.is_idr_nal(sl_is_idr),
		.nal_ref_idc_nonzero(sl_nal_ref_idc_nonzero),
		.log2_max_frame_num(log2_fn),
		.poc_type(poc_t),
		.sps_ready(sps_valid),
		.pps_ready(pps_valid),
		.deblock_ctrl(pps_deblock),
		.pic_init_qp(pps_qp),
		.valid(slice_valid),
		.first_mb(sl_first), .slice_type(sl_type), .pps_id(sl_pps),
		.frame_num(sl_fn), .idr_pic_id(sl_idr_pic),
		.is_i_slice(sl_is_i),
		.slice_qp_delta(sl_qpd), .slice_qp(sl_qp),
		.disable_deblocking_filter_idc(sl_deblock_idc),
		.slice_alpha_c0_offset_div2(sl_alpha_div2),
		.slice_beta_offset_div2(sl_beta_div2),
		.slice_alpha_c0_offset(sl_alpha_off),
		.slice_beta_offset(sl_beta_off),
		.first_mb_type(sl_mbt), .has_mb_type(sl_has_mbt),
		.first_mb_p_skip(first_mb_p_skip),
		.p_skip_run(p_skip_run),
		.first_mb_part_mode(first_mb_part_mode),
		.first_mb_part_count(first_mb_part_count),
		.first_mb_uses_sub_mb(first_mb_uses_sub_mb),
		.first_mb_intra(first_mb_intra),
		.residual_tc(sl_rtc), .residual_t1(sl_rt1), .residual_ok(sl_res_ok),
		.residual_dc(sl_rdc),
		.residual_csum(residual_csum),
		.residual_coeff(residual_coeff),
		.residual_place_pulse(residual_place_pulse),
		.residual_place_ok(sl_place_ok),
		.residual_place_tc(sl_place_tc),
		.residual_place_t1(sl_place_t1),
		.residual_place_dc(sl_place_dc),
		.residual_place_qp(sl_place_qp),
		.residual_place_coeff(sl_place_coeff),
		.first_mb_residual_bit_offset(sl_first_mb_residual_bit_offset),
		.first_mb_cbp_luma(sl_first_mb_cbp_luma),
		.first_mb_cbp_chroma(sl_first_mb_cbp_chroma),
		.first_mb_i4_pred_mode_flags(sl_first_mb_i4_flags),
		.first_mb_i4_rem_modes(sl_first_mb_i4_rem_modes),
		.busy(sl_busy)
	);

	reg slice_valid_d;
	always @(posedge clk) begin
		if (reset | flush)
			slice_valid_d <= 1'b0;
		else
			slice_valid_d <= slice_valid;
	end
	wire [9:0] sl_rbsp_bit_len = (sl_rbsp_len >= 8'd128) ? 10'd1023 : {sl_rbsp_len[6:0], 3'd0};
	wire [3:0] decode_core_i4_in [0:15];
	wire [7:0] decode_core_recon_y [0:255];
	wire [7:0] decode_core_recon_u [0:63];
	wire [7:0] decode_core_recon_v [0:63];
	wire signed [15:0] decode_core_p16_residual_y [0:255];
	wire signed [15:0] decode_core_p16_residual_u [0:63];
	wire signed [15:0] decode_core_p16_residual_v [0:63];
	genvar decode_core_zero_i;
	generate
		for (decode_core_zero_i = 0; decode_core_zero_i < 16; decode_core_zero_i = decode_core_zero_i + 1) begin : gen_decode_core_i4_zero
			assign decode_core_i4_in[decode_core_zero_i] = 4'd0;
		end
		for (decode_core_zero_i = 0; decode_core_zero_i < 64; decode_core_zero_i = decode_core_zero_i + 1) begin : gen_decode_core_chroma_zero
			assign decode_core_recon_u[decode_core_zero_i] = 8'd0;
			assign decode_core_recon_v[decode_core_zero_i] = 8'd0;
			assign decode_core_p16_residual_u[decode_core_zero_i] = 16'sd0;
			assign decode_core_p16_residual_v[decode_core_zero_i] = 16'sd0;
		end
		for (decode_core_zero_i = 0; decode_core_zero_i < 256; decode_core_zero_i = decode_core_zero_i + 1) begin : gen_decode_core_luma_zero
			assign decode_core_recon_y[decode_core_zero_i] = 8'd0;
			assign decode_core_p16_residual_y[decode_core_zero_i] = 16'sd0;
		end
	endgenerate
	wire decode_core_dpb_wr_en, decode_core_dpb_rd_en, decode_core_frame_done;
	wire [31:0] decode_core_dpb_wr_addr, decode_core_dpb_rd_addr;
	wire [7:0] decode_core_dpb_wr_data, decode_core_state;
	wire [15:0] decode_core_frame_mb_count, decode_core_current_mb_addr;
	wire [15:0] decode_core_rbsp_request_offset;
	wire decode_core_rbsp_request_valid, decode_core_busy, decode_core_error;
	h264_decode_core #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H)
	) product_decode_core (
		.clk(clk),
		.reset(reset | flush),
		.slice_start(vcl_pulse),
		.slice_is_idr(sl_is_idr),
		.slice_is_i(sl_is_i),
		.slice_qp_y(sl_qp),
		.first_mb_in_slice(sl_first),
		.mb_width(sps_mb_w),
		.mb_height(sps_mb_h),
		.pps_chroma_qp_index_offset(pps_chroma_qp_off),
		.rbsp_byte(sl_rbsp),
		.rbsp_bit_len(sl_rbsp_bit_len),
		.rbsp_window_base(16'd0),
		.rbsp_request_offset(decode_core_rbsp_request_offset),
		.rbsp_request_valid(decode_core_rbsp_request_valid),
		.mb_type_valid(slice_valid & ~slice_valid_d),
		.mb_type(sl_mbt[4:0]),
		.mb_skip(first_mb_p_skip),
		.intra4x4_pred_mode_flags(sl_first_mb_i4_flags),
		.rem_intra4x4_pred_mode(sl_first_mb_i4_rem_modes),
		.intra4x4_modes(decode_core_i4_in),
		.intra16x16_mode(2'd0),
		.chroma_pred_mode(2'd0),
		.cbp_luma(sl_first_mb_cbp_luma),
		.cbp_chroma(sl_first_mb_cbp_chroma),
		.mb_qp_delta(6'sd0),
		.mb_residual_bit_offset({6'd0, sl_first_mb_residual_bit_offset}),
		.mv_x_qpel(16'sd0),
		.mv_y_qpel(16'sd0),
		.part_mode(first_mb_part_mode),
		.part_idx(2'd0),
		.mvd_x_qpel(16'sd0),
		.mvd_y_qpel(16'sd0),
		.ref_idx_l0(2'd0),
		.recon_mb_valid(1'b0),
		.recon_mb_x(8'd0),
		.recon_mb_y(8'd0),
		.recon_mb_is_ref(1'b0),
		.dpb_write_base(32'd0),
		.recon_y(decode_core_recon_y),
		.recon_u(decode_core_recon_u),
		.recon_v(decode_core_recon_v),
		.p16_zero_mv_valid(1'b0),
		.p16_mb_x(8'd0),
		.p16_mb_y(8'd0),
		.p16_mb_is_ref(1'b0),
		.dpb_ref_base(32'd0),
		.p16_residual_y(decode_core_p16_residual_y),
		.p16_residual_u(decode_core_p16_residual_u),
		.p16_residual_v(decode_core_p16_residual_v),
		.dpb_wr_en(decode_core_dpb_wr_en),
		.dpb_wr_addr(decode_core_dpb_wr_addr),
		.dpb_wr_data(decode_core_dpb_wr_data),
		.dpb_rd_en(decode_core_dpb_rd_en),
		.dpb_rd_addr(decode_core_dpb_rd_addr),
		.dpb_rd_data(8'd0),
		.dpb_rd_valid(1'b0),
		.frame_done(decode_core_frame_done),
		.frame_mb_count(decode_core_frame_mb_count),
		.luma4x4_valid(luma4x4_valid),
		.luma4x4_idx(luma4x4_idx),
		.luma4x4_qp(luma4x4_qp),
		.luma4x4_total_coeff(luma4x4_total_coeff),
		.luma4x4_trailing_ones(luma4x4_trailing_ones),
		.luma4x4_bit_offset_end(luma4x4_bit_offset_end),
		.luma4x4_coeff_zigzag(luma4x4_coeff_zigzag),
		.luma4x4_source_busy(luma4x4_source_busy),
		.luma4x4_source_done(luma4x4_source_done),
		.luma4x4_source_ok(luma4x4_source_ok),
		.luma4x4_source_bit_end(luma4x4_source_bit_end),
		.core_i4_modes(i4_modes),
		.mb_syntax_accept(mb_syntax_accept),
		.mb_syntax_valid(mb_syntax_valid),
		.mb_syntax_addr(mb_syntax_addr),
		.mb_syntax_x(mb_syntax_x),
		.mb_syntax_y(mb_syntax_y),
		.mb_syntax_class(mb_syntax_class),
		.mb_syntax_type(mb_syntax_type),
		.mb_syntax_p_skip(mb_syntax_p_skip),
		.mb_syntax_part_mode(mb_syntax_part_mode),
		.mb_syntax_part_count(mb_syntax_part_count),
		.mb_syntax_uses_sub_mb(mb_syntax_uses_sub_mb),
		.mb_syntax_unsupported(mb_syntax_unsupported),
		.mb_syntax_ref_idx_l0(mb_syntax_ref_idx_l0),
		.mb_syntax_mvd_x_qpel(mb_syntax_mvd_x_qpel),
		.mb_syntax_mvd_y_qpel(mb_syntax_mvd_y_qpel),
		.mb_syntax_sub_mb_type(mb_syntax_sub_mb_type),
		.mb_syntax_cbp_luma(mb_syntax_cbp_luma),
		.mb_syntax_cbp_chroma(mb_syntax_cbp_chroma),
		.mb_syntax_mb_qp_delta(mb_syntax_mb_qp_delta),
		.mb_syntax_qpy(mb_syntax_qpy),
		.mb_syntax_qpc(mb_syntax_qpc),
		.mb_syntax_residual_bit_offset(mb_syntax_residual_bit_offset),
		.busy(decode_core_busy),
		.decode_state(decode_core_state),
		.current_mb_addr(decode_core_current_mb_addr),
		.error(decode_core_error)
	);
	assign i4_pred_mode_flags = sl_first_mb_i4_flags;
	assign i4_rem_modes = sl_first_mb_i4_rem_modes;
	assign first_mb_residual_bit_offset = sl_first_mb_residual_bit_offset;
	assign first_mb_cbp_luma = sl_first_mb_cbp_luma;
	assign first_mb_cbp_chroma = sl_first_mb_cbp_chroma;

	assign slice_type    = sl_type;
	assign slice_is_i    = sl_is_i;
	assign first_mb_type = sl_mbt;
	assign has_mb_type   = sl_has_mbt;
	assign slice_qp      = sl_qp;
	assign disable_deblocking_filter_idc = sl_deblock_idc;
	assign slice_alpha_c0_offset_div2 = sl_alpha_div2;
	assign slice_beta_offset_div2 = sl_beta_div2;
	assign slice_alpha_c0_offset = sl_alpha_off;
	assign slice_beta_offset = sl_beta_off;
	assign residual_tc   = sl_rtc;
	assign residual_t1   = sl_rt1;
	assign residual_ok   = sl_res_ok;
	assign residual_dc   = sl_rdc;

	// Product decode is always rooted at product_decode_core above.  The legacy
	// decode_stub remains only as the diagnostic frame-store painter until the
	// core owns presentation; DECODE_REAL_INTRA no longer swaps the product
	// decoder subtree or bypasses MC/DPB/deblock.  The named generate scope is
	// load-bearing: it keeps the diagnostic painter structurally separable from
	// the product decoder subtree.
	generate
		begin : gen_diagnostic_present
		decode_stub #(
			.WIDTH(FRAME_W),
			.HEIGHT(FRAME_H)
		) stub (
			.clk(clk), .reset(reset | flush),
			.vcl_pulse(vcl_pulse),
			.last_nal_type(last_nal_type),
			.nalu_count(nalu_count),
			.idr_count(idr_c),
			.has_idr(has_idr_w),
			.sps_valid(sps_valid),
			.mb_w(sps_mb_w),
			.mb_h(sps_mb_h),
			.slice_type(sl_type),
			.slice_is_i(sl_is_i),
			.slice_valid(slice_valid),
			.first_mb_addr(sl_first),
			.has_mb_type(sl_has_mbt),
			.first_mb_p_skip(first_mb_p_skip),
			.first_mb_part_mode(first_mb_part_mode),
			.first_mb_part_count(first_mb_part_count),
			.first_mb_uses_sub_mb(first_mb_uses_sub_mb),
			.first_mb_intra(first_mb_intra),
			.residual_ok(sl_place_ok),
			.residual_tc(sl_place_tc),
			.residual_dc(sl_place_dc),
			.residual_valid(residual_place_pulse),
			.slice_qp(sl_place_qp),
			.residual_coeff(sl_place_coeff),
			.recon_sig(recon_sig),
			.recon_dbg(stub_recon_dbg),
			.recon_dbg_valid(recon_dbg_valid),
			.recon_valid(recon_valid),
			.wr_en(fs_wr_en),
			.wr_pixel(fs_wr_pixel),
			.wr_reset_ptr(fs_wr_reset),
			.swap_req(fs_swap),
			.busy(stub_busy),
			.frames_out(stub_frames)
		);
		end
	endgenerate

	// --- Product core liveness observable (W-DECODE-O5; cures failure mode 3) ---
	// The core's luma4x4_* outputs reached this module's port boundary and were
	// then left UNCONNECTED at the emu (Plex.sv) instantiation -- Plex.sv contains
	// zero occurrences of "luma4x4".  Quartus therefore elaborated
	// h264_decode_core and deleted it as zero-resource dead logic.  The (* keep *)
	// _keep wire below cannot prevent that because _keep is itself never read.
	//
	// These two sticky bits give the core's CAVLC output the first observable
	// path that actually reaches a pin:
	//   core -> recon_dbg[2:1] -> Plex.sv st_recon_dbg_sticky -> status_telem -> DDR
	//
	// HONESTY: this is INSTRUMENTATION, not presentation.  It publishes whether
	// the product core produced residual in silicon; it does not put a pixel on
	// screen.  recon_dbg[2:1] are the only two bits decode_stub never drives
	// (see decode_stub.sv recon_dbg_comb: bits 0,3,4,5,6,7 only), so the 0x79
	// deblock mask and the 0x14 residual csum golden are untouched by construction.
	wire [7:0] stub_recon_dbg;
	reg core_live_pulse, core_live_nz;
	reg core_live_nz_comb;
	integer core_live_i;
	always @* begin
		core_live_nz_comb = 1'b0;
		for (core_live_i = 0; core_live_i < 16; core_live_i = core_live_i + 1)
			if (luma4x4_coeff_zigzag[core_live_i] != 16'sd0)
				core_live_nz_comb = 1'b1;
	end
	always @(posedge clk) begin
		if (reset | flush) begin
			core_live_pulse <= 1'b0;
			core_live_nz    <= 1'b0;
		end else if (luma4x4_valid) begin
			core_live_pulse <= 1'b1;
			if (core_live_nz_comb)
				core_live_nz <= 1'b1;
		end
	end
	assign recon_dbg = stub_recon_dbg | {5'b0, core_live_nz, core_live_pulse, 1'b0};

	(* keep = 1 *) wire keep_si = si_active;
	(* keep = 1 *) wire keep_bf = bf_has;
	// Touch residual_csum + place pulse + a few coeff LSBs so place is not pruned.
	wire _keep = keep_si | keep_bf | |fifo_level | |bytes_in | stub_busy | sps_busy |
	             pps_busy | sl_busy | |pps_id_w | |pps_qp | pps_cabac | |sl_first |
	             |sl_fn | |sl_qpd | pps_deblock | |residual_csum | residual_place_pulse |
	             recon_valid | recon_dbg_valid | |recon_sig | |recon_dbg |
	             sl_place_ok | |sl_place_tc | |sl_place_t1 | |sl_place_qp |
	             |sl_first_mb_cbp_luma | |sl_first_mb_cbp_chroma |
	             |sl_first_mb_i4_flags | |sl_first_mb_i4_rem_modes |
	             luma4x4_source_busy | luma4x4_source_done | luma4x4_source_ok |
	             luma4x4_valid | |luma4x4_idx | |luma4x4_qp |
	             |luma4x4_total_coeff | |luma4x4_trailing_ones |
	             |luma4x4_bit_offset_end | |luma4x4_coeff_zigzag[0] |
	             |luma4x4_source_bit_end | |i4_modes[0] |
	             decode_core_dpb_wr_en | decode_core_dpb_rd_en | decode_core_frame_done |
	             |decode_core_dpb_wr_addr | |decode_core_dpb_rd_addr |
	             |decode_core_dpb_wr_data | |decode_core_state |
	             |decode_core_frame_mb_count | |decode_core_current_mb_addr |
	             |decode_core_rbsp_request_offset | decode_core_rbsp_request_valid |
	             decode_core_busy | decode_core_error |
	             mb_syntax_valid | |mb_syntax_addr | |mb_syntax_x | |mb_syntax_y |
	             |mb_syntax_class | |mb_syntax_type | mb_syntax_p_skip |
	             |mb_syntax_part_mode | |mb_syntax_part_count | mb_syntax_uses_sub_mb |
	             mb_syntax_unsupported | |mb_syntax_ref_idx_l0[0] |
	             |mb_syntax_mvd_x_qpel[0] | |mb_syntax_mvd_y_qpel[0] |
	             |mb_syntax_sub_mb_type[0] | |mb_syntax_cbp_luma | |mb_syntax_cbp_chroma |
	             |mb_syntax_mb_qp_delta | |mb_syntax_qpy | |mb_syntax_qpc |
	             |mb_syntax_residual_bit_offset |
	             residual_coeff[0][0] | residual_coeff[1][0] |
	             residual_coeff[15][0] | sl_place_coeff[0][0] | sl_place_coeff[15][0];

endmodule
