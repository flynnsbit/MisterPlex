// Phase 3.3–3.3l-1: F3 → FIFO → NAL → SPS/PPS/slice_hdr(+full first residual) + decode.
// Hybrid: diagnostic paint is F3-only; host F1 recon owns product present (Plex.sv).

`ifndef DECODE_REAL_INTRA
`define DECODE_REAL_INTRA 0
`endif

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
	// Rotating per-stage cycle telemetry from the decode pipeline; published
	// to the ARM through the DDR mailbox.  Layout in h264_perf_counters.sv.
	output wire [63:0] decode_perf_word,
	output wire [15:0] stream_ddr_underruns,
	output wire [15:0] stream_ddr_overruns,
	output wire [31:0] stream_ddr_host_write,
	output wire [31:0] stream_ddr_fpga_read,

	output wire        has_idr,
	output wire [7:0]  idr_count,
	output wire [7:0]  sps_count,
	output wire [7:0]  pps_count,
	output wire [7:0]  slice_count,
	output logic [15:0] stub_frames,
	output logic        stub_busy,

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
	// R-csum6 Rank3: 1-cycle ST_PLACE pulse for status residual sticky freeze
	output wire        residual_place_pulse,
	output logic [7:0]  recon_sig,
	output logic [7:0]  recon_dbg,
	output logic        recon_dbg_valid,
	output logic        recon_valid,

	output logic        fs_wr_en,
	output logic [15:0] fs_wr_pixel,
	output logic        fs_wr_reset,
	output logic        fs_swap,

	// Product pixel path: h264_decode_core committed reconstruction samples,
	// plane + frame-relative (x,y), one byte per clk.  This is the ONLY path
	// that puts decoded pixels on screen under DDR_FRAME_STORE; decode_stub's
	// fs_* paint is ignored by present_core in that configuration.
	output wire         dec_px_wr_en,
	output wire  [1:0]  dec_px_plane,
	output wire [15:0]  dec_px_x,
	output wire [15:0]  dec_px_y,
	output wire  [7:0]  dec_px_data
);

	// The decode core must run on the CODED picture geometry, not the display
	// surface: FRAME_W is the 640-wide present surface, while the stream (and
	// the DDR framebuffer the reconstruction is written into) is 624x480, i.e.
	// exactly 39x30 macroblocks.  Using the display width gave the core a
	// 40-macroblock raster stride, which skewed every macroblock position by a
	// growing offset and pushed one column per row outside the picture.
`include "ddr_frame_layout_params.svh"
	localparam int CORE_FRAME_W = DDR_FRAME_CODED_WIDTH;
	localparam int CORE_FRAME_H = DDR_FRAME_CODED_HEIGHT;

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

	// ------------------------------------------------------------------
	// Local two-master mux for the single clk-domain DDR port.
	//
	// Master A is the compressed-bitstream ring reader, master B is the
	// DDR-resident decoded picture buffer.  The outer ddr_bus_arbiter already
	// owns the clock crossing for this port, so both masters stay on clk and
	// no additional CDC is needed here.
	//
	// Ownership is taken at a transaction boundary and released when the owner
	// drops its request, which is the jtframe_sdram_mux shape: exactly one
	// selected slot, data broadcast, slot released on retire.
	wire        bsr_bus_want;
	wire  [7:0] bsr_burstcnt;
	wire [28:0] bsr_addr;
	wire        bsr_rd;
	wire [63:0] bsr_din;
	wire  [7:0] bsr_be;
	wire        bsr_we;

	wire        dpb_ddr_req;
	wire  [7:0] dpb_ddr_burstcnt;
	wire [28:0] dpb_ddr_addr;
	wire        dpb_ddr_rd;
	wire [63:0] dpb_ddr_din;
	wire  [7:0] dpb_ddr_be;
	wire        dpb_ddr_we;

	// The bitstream reader keeps its own multi-beat bursts in flight across
	// several cycles, so it holds the port for as long as it wants it.
	reg  bus_owner_dpb;
	always @(posedge clk) begin
		if (reset) begin
			bus_owner_dpb <= 1'b0;
		end else if (!bus_owner_dpb) begin
			if (!bsr_bus_want && dpb_ddr_req) bus_owner_dpb <= 1'b1;
		end else begin
			if (!dpb_ddr_req) bus_owner_dpb <= 1'b0;
		end
	end

	assign ddr_bus_want  = bsr_bus_want | dpb_ddr_req;
	assign ddr_burstcnt  = bus_owner_dpb ? dpb_ddr_burstcnt : bsr_burstcnt;
	assign ddr_addr      = bus_owner_dpb ? dpb_ddr_addr     : bsr_addr;
	assign ddr_rd        = bus_owner_dpb ? dpb_ddr_rd       : bsr_rd;
	assign ddr_din       = bus_owner_dpb ? dpb_ddr_din      : bsr_din;
	assign ddr_be        = bus_owner_dpb ? dpb_ddr_be       : bsr_be;
	assign ddr_we        = bus_owner_dpb ? dpb_ddr_we       : bsr_we;

	// A master that does not own the port sees it as permanently busy, which
	// is exactly the back-off every sys/ddram.sv client already implements.
	wire bsr_ddr_busy     = ddr_busy | bus_owner_dpb;
	wire bsr_dout_ready   = ddr_dout_ready & ~bus_owner_dpb;
	wire dpb_ddr_busy     = ddr_busy | ~bus_owner_dpb;
	wire dpb_dout_ready   = ddr_dout_ready & bus_owner_dpb;

	ddr_bitstream_reader ddr_stream (
		.clk(clk), .reset(reset),
		.enable(ddr_stream_enable),
		.flush(flush),
		.out_valid(ddr_wr_en),
		.out_byte(ddr_wr_data),
		.out_flush(ddr_wr_flush),
		.out_full(bf_wr_full | si_wr_en),
		.bus_want(bsr_bus_want),
		.DDRAM_BUSY(bsr_ddr_busy),
		.DDRAM_BURSTCNT(bsr_burstcnt),
		.DDRAM_ADDR(bsr_addr),
		.DDRAM_DOUT(ddr_dout),
		.DDRAM_DOUT_READY(bsr_dout_ready),
		.DDRAM_RD(bsr_rd),
		.DDRAM_DIN(bsr_din),
		.DDRAM_BE(bsr_be),
		.DDRAM_WE(bsr_we),
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
	wire [3:0]  sl_first_mb_cbp_luma;
	wire [1:0]  sl_first_mb_cbp_chroma;
	wire [15:0] sl_first_mb_residual_bit_offset;
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

	wire sps_wr_pulse;
	wire [7:0] sps_id_w, sps_max_refs;
	wire [5:0] sps_l2poc;

	sps_parser sps (
		.clk(clk), .reset(reset | flush),
		.cap_clear(sps_cap_clear), .cap_en(sps_cap_en),
		.cap_data(sps_cap_data), .cap_end(sps_cap_end),
		.valid(sps_valid), .wr_pulse(sps_wr_pulse), .sps_id(sps_id_w),
		.profile_idc(sps_profile), .level_idc(sps_level),
		.width(sps_width), .height(sps_height),
		.log2_max_frame_num(log2_fn), .poc_type(poc_t),
		.log2_max_poc_lsb(sps_l2poc), .max_num_ref_frames(sps_max_refs),
		.mb_width(sps_mb_w), .mb_height(sps_mb_h),
		.busy(sps_busy)
	);

	wire pps_busy, pps_cabac, pps_deblock, pps_wr_pulse;
	wire pps_bfpo, pps_wp, pps_cip, pps_rpc, pps_unsup, pps_pfail;
	wire [7:0] pps_id_w, pps_sps_id, pps_nref, pps_nref1, pps_nsg;
	wire [1:0] pps_wbi;
	wire signed [7:0] pps_qp, pps_qs;
	wire signed [4:0] pps_cqpo;

	pps_parser pps (
		.clk(clk), .reset(reset | flush),
		.cap_clear(pps_cap_clear), .cap_en(pps_cap_en),
		.cap_data(pps_cap_data), .cap_end(pps_cap_end),
		.valid(pps_valid), .wr_pulse(pps_wr_pulse),
		.pps_id(pps_id_w), .sps_id(pps_sps_id),
		.entropy_cabac(pps_cabac),
		.bottom_field_pic_order_present(pps_bfpo),
		.num_slice_groups_minus1(pps_nsg),
		.num_ref_l0(pps_nref), .num_ref_l1(pps_nref1),
		.weighted_pred(pps_wp), .weighted_bipred_idc(pps_wbi),
		.pic_init_qp(pps_qp), .pic_init_qs(pps_qs),
		.chroma_qp_index_offset(pps_cqpo),
		.deblock_ctrl(pps_deblock),
		.constrained_intra_pred(pps_cip),
		.redundant_pic_cnt_present(pps_rpc),
		.unsupported(pps_unsup), .parse_fail(pps_pfail),
		.busy(pps_busy)
	);

	// Parameter set storage. The slice header parser drives ps_sel_id with the
	// pic_parameter_set_id it is decoding right now and gets that exact PPS --
	// and through it that PPS's SPS -- back combinationally in the same cycle.
	// Handing it whichever set arrived last would give a slice a PPS it does
	// not reference, changing whether the deblocking offsets are even present
	// in the bitstream and desyncing every bit after them.
	wire [7:0] ps_sel_id;
	wire ps_pps_found, ps_sps_found;
	wire [7:0] ps_pps_sps_id, ps_num_ref_l0, ps_num_ref_l1;
	wire ps_bfpo, ps_wp, ps_deblock, ps_cip, ps_rpc;
	wire [1:0] ps_wbi;
	wire signed [7:0] ps_pic_init_qp, ps_pic_init_qs;
	wire signed [4:0] ps_chroma_qp_off;
	wire [15:0] ps_sps_w, ps_sps_h;
	wire [7:0] ps_sps_mbw, ps_sps_mbh, ps_sps_max_refs;
	wire [4:0] ps_sps_l2fn;
	wire [2:0] ps_sps_poc;
	wire [5:0] ps_sps_l2poc;
	wire ps_any_pps, ps_any_sps;
	wire [7:0] ps_pps_count, ps_sps_count;

	h264_param_sets #(.NUM_PPS(4), .NUM_SPS(2)) u_param_sets (
		.clk(clk), .reset(reset | flush),
		.sps_wr(sps_wr_pulse),
		.sps_wr_id(sps_id_w),
		.sps_wr_width(sps_width),
		.sps_wr_height(sps_height),
		.sps_wr_mb_width(sps_mb_w),
		.sps_wr_mb_height(sps_mb_h),
		.sps_wr_log2_max_frame_num(log2_fn),
		.sps_wr_poc_type(poc_t),
		.sps_wr_log2_max_poc_lsb(sps_l2poc),
		.sps_wr_max_num_ref_frames(sps_max_refs),
		.pps_wr(pps_wr_pulse),
		.pps_wr_id(pps_id_w),
		.pps_wr_sps_id(pps_sps_id),
		.pps_wr_bottom_field_pic_order_present(pps_bfpo),
		.pps_wr_num_ref_l0(pps_nref),
		.pps_wr_num_ref_l1(pps_nref1),
		.pps_wr_weighted_pred(pps_wp),
		.pps_wr_weighted_bipred_idc(pps_wbi),
		.pps_wr_pic_init_qp(pps_qp),
		.pps_wr_pic_init_qs(pps_qs),
		.pps_wr_chroma_qp_index_offset(pps_cqpo),
		.pps_wr_deblock_ctrl(pps_deblock),
		.pps_wr_constrained_intra_pred(pps_cip),
		.pps_wr_redundant_pic_cnt_present(pps_rpc),
		.pps_sel_id(ps_sel_id),
		.pps_sel_found(ps_pps_found),
		.pps_sel_sps_id(ps_pps_sps_id),
		.pps_sel_bottom_field_pic_order_present(ps_bfpo),
		.pps_sel_num_ref_l0(ps_num_ref_l0),
		.pps_sel_num_ref_l1(ps_num_ref_l1),
		.pps_sel_weighted_pred(ps_wp),
		.pps_sel_weighted_bipred_idc(ps_wbi),
		.pps_sel_pic_init_qp(ps_pic_init_qp),
		.pps_sel_pic_init_qs(ps_pic_init_qs),
		.pps_sel_chroma_qp_index_offset(ps_chroma_qp_off),
		.pps_sel_deblock_ctrl(ps_deblock),
		.pps_sel_constrained_intra_pred(ps_cip),
		.pps_sel_redundant_pic_cnt_present(ps_rpc),
		.sps_sel_found(ps_sps_found),
		.sps_sel_width(ps_sps_w),
		.sps_sel_height(ps_sps_h),
		.sps_sel_mb_width(ps_sps_mbw),
		.sps_sel_mb_height(ps_sps_mbh),
		.sps_sel_log2_max_frame_num(ps_sps_l2fn),
		.sps_sel_poc_type(ps_sps_poc),
		.sps_sel_log2_max_poc_lsb(ps_sps_l2poc),
		.sps_sel_max_num_ref_frames(ps_sps_max_refs),
		.any_pps_valid(ps_any_pps),
		.any_sps_valid(ps_any_sps),
		.pps_count(ps_pps_count),
		.sps_count(ps_sps_count)
	);

	wire sl_busy, sl_is_i, sl_has_mbt, sl_res_ok;
	wire [15:0] sl_first, sl_fn, sl_idr_pic;
	wire [7:0] sl_type, sl_pps, sl_mbt;
	wire signed [7:0] sl_qpd, sl_rdc;
	wire [5:0] sl_qp;
	wire [1:0] sl_deblock_idc;
	wire [15:0] sl_poc_lsb;
	wire [7:0] sl_num_ref_l0;
	wire signed [4:0] sl_chroma_qp_off;
	wire sl_cip, sl_unsup;
	wire signed [4:0] sl_alpha_div2, sl_beta_div2, sl_alpha_off, sl_beta_off;
	wire [4:0] sl_rtc;
	wire [1:0] sl_rt1;
	wire [15:0] sl_i4_pred_mode_flags;
	wire [47:0] sl_i4_rem_modes;
	wire sl_i4_modes_present;
	wire sl_luma4x4_blocks_valid;
	wire sl_luma4x4_blocks_present;
	wire signed [15:0] sl_luma4x4_coeff [0:15][0:15];
	wire sl_place_ok;
	wire [4:0] sl_place_tc;
	wire [1:0] sl_place_t1;
	wire signed [7:0] sl_place_dc;
	wire [5:0] sl_place_qp;
	wire signed [15:0] sl_place_coeff [0:15];

	// residual_csum / residual_coeff connect straight to module outputs (no
	// unpacked-array continuous assign — Quartus-friendly).
	slice_hdr_parser slp (
		.clk(clk), .reset(reset | flush),
		.cap_clear(sl_cap_clear), .cap_en(sl_cap_en),
		.cap_data(sl_cap_data), .cap_end(sl_cap_end),
		.is_idr_nal(sl_is_idr),
		.nal_ref_idc_nonzero(sl_nal_ref_idc_nonzero),
		.log2_max_frame_num(ps_sps_l2fn),
		.poc_type(ps_sps_poc),
		.log2_max_poc_lsb(ps_sps_l2poc),
		.sps_ready(ps_any_sps),
		.pps_ready(ps_any_pps),
		.pps_found(ps_pps_found && ps_sps_found),
		.pps_deblock_ctrl(ps_deblock),
		.pps_pic_init_qp(ps_pic_init_qp),
		.pps_num_ref_l0(ps_num_ref_l0),
		.pps_chroma_qp_index_offset(ps_chroma_qp_off),
		.pps_constrained_intra_pred(ps_cip),
		.pps_bottom_field_pic_order_present(ps_bfpo),
		.pps_redundant_pic_cnt_present(ps_rpc),
		.pps_weighted_pred(ps_wp),
		.pps_sel_id(ps_sel_id),
		.valid(slice_valid),
		.first_mb(sl_first), .slice_type(sl_type), .pps_id(sl_pps),
		.frame_num(sl_fn), .idr_pic_id(sl_idr_pic),
		.pic_order_cnt_lsb(sl_poc_lsb),
		.is_i_slice(sl_is_i),
		.num_ref_idx_l0_active(sl_num_ref_l0),
		.chroma_qp_index_offset(sl_chroma_qp_off),
		.constrained_intra_pred_flag(sl_cip),
		.unsupported(sl_unsup),
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
		.first_i4_pred_mode_flags(sl_i4_pred_mode_flags),
		.first_i4_rem_modes(sl_i4_rem_modes),
		.first_i4_modes_present(sl_i4_modes_present),
		.first_luma4x4_blocks_valid(sl_luma4x4_blocks_valid),
		.first_luma4x4_blocks_present(sl_luma4x4_blocks_present),
		.first_luma4x4_coeff(sl_luma4x4_coeff),
		.first_mb_cbp_luma(sl_first_mb_cbp_luma),
		.first_mb_cbp_chroma(sl_first_mb_cbp_chroma),
		.first_mb_residual_bit_offset(sl_first_mb_residual_bit_offset),
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
		.busy(sl_busy)
	);

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

	function automatic [1:0] core_i4_bx;
		input [3:0] idx;
		begin
			case (idx)
			4'd0, 4'd2, 4'd8, 4'd10: core_i4_bx = 2'd0;
			4'd1, 4'd3, 4'd9, 4'd11: core_i4_bx = 2'd1;
			4'd4, 4'd6, 4'd12, 4'd14: core_i4_bx = 2'd2;
			default: core_i4_bx = 2'd3;
			endcase
		end
	endfunction

	function automatic [1:0] core_i4_by;
		input [3:0] idx;
		begin
			case (idx)
			4'd0, 4'd1, 4'd4, 4'd5: core_i4_by = 2'd0;
			4'd2, 4'd3, 4'd6, 4'd7: core_i4_by = 2'd1;
			4'd8, 4'd9, 4'd12, 4'd13: core_i4_by = 2'd2;
			default: core_i4_by = 2'd3;
			endcase
		end
	endfunction

	function automatic [3:0] core_i4_idx_at;
		input [1:0] bx;
		input [1:0] by;
		begin
			case ({by, bx})
			4'b0000: core_i4_idx_at = 4'd0;
			4'b0001: core_i4_idx_at = 4'd1;
			4'b0100: core_i4_idx_at = 4'd2;
			4'b0101: core_i4_idx_at = 4'd3;
			4'b0010: core_i4_idx_at = 4'd4;
			4'b0011: core_i4_idx_at = 4'd5;
			4'b0110: core_i4_idx_at = 4'd6;
			4'b0111: core_i4_idx_at = 4'd7;
			4'b1000: core_i4_idx_at = 4'd8;
			4'b1001: core_i4_idx_at = 4'd9;
			4'b1100: core_i4_idx_at = 4'd10;
			4'b1101: core_i4_idx_at = 4'd11;
			4'b1010: core_i4_idx_at = 4'd12;
			4'b1011: core_i4_idx_at = 4'd13;
			4'b1110: core_i4_idx_at = 4'd14;
			default: core_i4_idx_at = 4'd15;
			endcase
		end
	endfunction

	wire [3:0] core_i4_modes [0:15];
	reg [3:0] core_i4_modes_calc [0:15];
	integer core_mi;
	always @* begin
		for (core_mi = 0; core_mi < 16; core_mi = core_mi + 1) begin : derive_core_i4_modes
			reg [1:0] bx;
			reg [1:0] by;
			reg [3:0] left_idx;
			reg [3:0] top_idx;
			reg [3:0] pred_mode;
			reg [2:0] rem_mode;
			bx = core_i4_bx(core_mi[3:0]);
			by = core_i4_by(core_mi[3:0]);
			left_idx = (bx == 2'd0) ? 4'd0 : core_i4_idx_at(bx - 2'd1, by);
			top_idx = (by == 2'd0) ? 4'd0 : core_i4_idx_at(bx, by - 2'd1);
			if (bx != 2'd0 && by != 2'd0)
				pred_mode = (core_i4_modes_calc[left_idx] < core_i4_modes_calc[top_idx]) ?
					core_i4_modes_calc[left_idx] : core_i4_modes_calc[top_idx];
			else
				pred_mode = 4'd2;
			rem_mode = sl_i4_rem_modes[core_mi * 3 +: 3];
			if (!sl_i4_modes_present)
				core_i4_modes_calc[core_mi] = 4'd2;
			else if (sl_i4_pred_mode_flags[core_mi])
				core_i4_modes_calc[core_mi] = pred_mode;
			else
				core_i4_modes_calc[core_mi] = (rem_mode < pred_mode[2:0]) ?
					{1'b0, rem_mode} : ({1'b0, rem_mode} + 4'd1);
		end
	end

	genvar core_gi;
	generate
		for (core_gi = 0; core_gi < 16; core_gi = core_gi + 1) begin : gen_core_i4_modes
			assign core_i4_modes[core_gi] = core_i4_modes_calc[core_gi];
		end
	endgenerate

	reg core_luma4x4_valid;
	reg [3:0] core_luma4x4_idx;
	reg [5:0] core_luma4x4_qp;
	reg [4:0] core_luma4x4_total_coeff;
	reg [1:0] core_luma4x4_trailing_ones;
	reg signed [15:0] core_luma4x4_coeff_zigzag [0:15];
	reg signed [15:0] core_luma4x4_latched [0:15][0:15];
	reg core_luma_feed_active;
	reg [3:0] core_luma_feed_idx;
	integer core_li;
	integer core_lj;

	// ── Full-frame macroblock sweep ─────────────────────────────────────────
	// The slice header parser only hands over the FIRST macroblock's residual,
	// so the core used to reconstruct exactly one macroblock per slice and the
	// other 1169 stayed untouched.  Replay that residual across every macroblock
	// of the frame in raster order: each macroblock gets its own position, its
	// own neighbour context and its own prediction, so the reconstruction is
	// different for every macroblock even though the coefficients repeat.  This
	// is the driver that makes the core paint a whole picture; the per-macroblock
	// residual walker replaces the replay once the parser can deliver it.
	localparam [2:0] SW_IDLE  = 3'd0;
	localparam [2:0] SW_START = 3'd1;
	localparam [2:0] SW_GAP   = 3'd2;
	localparam [2:0] SW_FEED  = 3'd3;
	localparam [2:0] SW_BLKACK = 3'd4;
	localparam [2:0] SW_WAIT  = 3'd5;

	reg [2:0]  sweep_state;
	reg [15:0] sweep_mb;
	reg [15:0] sweep_mb_total;
	reg [15:0] sweep_guard;
	reg [5:0]  sweep_blk_guard;
	reg        core_mb_type_valid;
	wire [4:0] core_intra_blocks_done;
	wire [15:0] sweep_mb_total_next = {8'd0, sps_mb_w} * {8'd0, sps_mb_h};
	// The reconstruction front-end has accepted this block once its counter has
	// moved past the block index we are presenting.
	wire sweep_blk_taken = (core_intra_blocks_done > {1'b0, core_luma_feed_idx});

	always @(posedge clk) begin
		core_luma4x4_valid <= 1'b0;
		core_mb_type_valid <= 1'b0;
		if (reset | flush) begin
			core_luma_feed_active <= 1'b0;
			core_luma_feed_idx <= 4'd0;
			core_luma4x4_idx <= 4'd0;
			core_luma4x4_qp <= 6'd0;
			core_luma4x4_total_coeff <= 5'd0;
			core_luma4x4_trailing_ones <= 2'd0;
			sweep_state <= SW_IDLE;
			sweep_mb <= 16'd0;
			sweep_mb_total <= 16'd0;
			sweep_guard <= 16'd0;
			sweep_blk_guard <= 6'd0;
			for (core_li = 0; core_li < 16; core_li = core_li + 1) begin
				core_luma4x4_coeff_zigzag[core_li] <= 16'sd0;
				for (core_lj = 0; core_lj < 16; core_lj = core_lj + 1)
					core_luma4x4_latched[core_li][core_lj] <= 16'sd0;
			end
		end else begin
			case (sweep_state)
			SW_IDLE: begin
				if (sl_luma4x4_blocks_valid && sl_luma4x4_blocks_present &&
				    (sweep_mb_total_next != 16'd0)) begin
					core_luma4x4_qp <= sl_place_qp;
					for (core_li = 0; core_li < 16; core_li = core_li + 1)
						for (core_lj = 0; core_lj < 16; core_lj = core_lj + 1)
							core_luma4x4_latched[core_li][core_lj] <= sl_luma4x4_coeff[core_li][core_lj];
					sweep_mb <= 16'd0;
					sweep_mb_total <= sweep_mb_total_next;
					sweep_state <= SW_START;
				end
			end

			SW_START: begin
				core_mb_type_valid <= 1'b1;
				sweep_guard <= 16'd0;
				sweep_state <= SW_GAP;
			end

			// One idle edge so the core's macroblock position registers and the
			// Intra_16x16 DC front-end settle before the residual blocks land.
			SW_GAP: begin
				core_luma_feed_active <= 1'b1;
				core_luma_feed_idx <= 4'd0;
				sweep_state <= SW_FEED;
			end

			SW_FEED: begin
				core_luma4x4_valid <= 1'b1;
				core_luma4x4_idx <= core_luma_feed_idx;
				core_luma4x4_total_coeff <= 5'd16;
				core_luma4x4_trailing_ones <= 2'd0;
				for (core_li = 0; core_li < 16; core_li = core_li + 1)
					core_luma4x4_coeff_zigzag[core_li] <= core_luma4x4_latched[core_luma_feed_idx][core_li];
				sweep_blk_guard <= 6'd0;
				sweep_state <= SW_BLKACK;
			end

			// Present one block at a time and only advance once the core's
			// reconstruction pipeline has actually consumed it.  Re-present the
			// same block if it was dropped (Intra_16x16 prediction not ready
			// yet), and abandon the macroblock if the core never takes it.
			SW_BLKACK: begin
				sweep_guard <= sweep_guard + 16'd1;
				sweep_blk_guard <= sweep_blk_guard + 6'd1;
				if (sweep_guard == 16'hFFFF) begin
					core_luma_feed_active <= 1'b0;
					sweep_guard <= 16'd0;
					sweep_state <= SW_WAIT;
				end else if (sweep_blk_taken) begin
					if (core_luma_feed_idx == 4'd15) begin
						core_luma_feed_active <= 1'b0;
						sweep_guard <= 16'd0;
						sweep_state <= SW_WAIT;
					end else begin
						core_luma_feed_idx <= core_luma_feed_idx + 4'd1;
						sweep_state <= SW_FEED;
					end
				end else if (sweep_blk_guard == 6'h3F) begin
					sweep_state <= SW_FEED;
				end
			end

			// Wait for the core to drain reconstruction + writeback for this
			// macroblock.  The guard keeps the sweep from wedging the whole
			// picture if the core never lowers busy.
			SW_WAIT: begin
				sweep_guard <= sweep_guard + 16'd1;
				if ((!core_busy && (sweep_guard > 16'd3)) || (sweep_guard == 16'hFFFF)) begin
					if ((sweep_mb + 16'd1) >= sweep_mb_total)
						sweep_state <= SW_IDLE;
					else begin
						sweep_mb <= sweep_mb + 16'd1;
						sweep_state <= SW_START;
					end
				end
			end

			default: sweep_state <= SW_IDLE;
			endcase
		end
	end

	wire [7:0] core_rbsp_byte [0:63];
	// Stage C: the core's RBSP window was tied to zero, so the CAVLC residual
	// decoder could only ever read an empty bitstream. Capture the same slice
	// byte stream the header parser consumes (core window is 64 bytes).
	reg [7:0] core_rbsp_buf [0:63];
	reg [6:0] core_rbsp_len;
	integer core_rbsp_ci;
	always @(posedge clk) begin
		if (reset | flush | sl_cap_clear) begin
			core_rbsp_len <= 7'd0;
			for (core_rbsp_ci = 0; core_rbsp_ci < 64; core_rbsp_ci = core_rbsp_ci + 1)
				core_rbsp_buf[core_rbsp_ci] <= 8'd0;
		end else if (sl_cap_en && !core_rbsp_len[6]) begin
			core_rbsp_buf[core_rbsp_len[5:0]] <= sl_cap_data;
			core_rbsp_len <= core_rbsp_len + 7'd1;
		end
	end
	wire [7:0] core_recon_y [0:255];
	wire [7:0] core_recon_u [0:63];
	wire [7:0] core_recon_v [0:63];
	wire signed [15:0] core_p16_residual_y [0:255];
	wire signed [15:0] core_p16_residual_u [0:63];
	wire signed [15:0] core_p16_residual_v [0:63];
	generate
		for (core_gi = 0; core_gi < 64; core_gi = core_gi + 1) begin : gen_core_zero64
			assign core_rbsp_byte[core_gi] = core_rbsp_buf[core_gi];
			assign core_recon_u[core_gi] = 8'd128;
			assign core_recon_v[core_gi] = 8'd128;
			assign core_p16_residual_u[core_gi] = 16'sd0;
			assign core_p16_residual_v[core_gi] = 16'sd0;
		end
		for (core_gi = 0; core_gi < 256; core_gi = core_gi + 1) begin : gen_core_zero256
			assign core_recon_y[core_gi] = 8'd0;
			assign core_p16_residual_y[core_gi] = 16'sd0;
		end
	endgenerate

	wire core_dpb_wr_en;
	wire [31:0] core_dpb_wr_addr;
	wire [7:0] core_dpb_wr_data;
	wire core_dpb_rd_en;
	wire [31:0] core_dpb_rd_addr;
	wire core_frame_done;
	wire [15:0] core_frame_mb_count;
	wire core_px_wr_en;

	// ── Desync recovery ─────────────────────────────────────────────────────
	// 7 IDRs against 343 P frames means a desync costs tens of frames of wrong
	// picture, so detection has to stop the slice rather than let it keep
	// writing garbage into the reference the rest of the GOP predicts from.
	wire core_err_cavlc_miss;
	wire core_err_bad_mb_type;
	wire core_err_mb_overrun;
	wire rec_decode_enable;
	wire rec_dpb_flush;
	wire rec_poc_reset;
	wire rec_mb_state_clear;
	wire rec_freeze_output;
	wire rec_resync_active;
	wire [15:0] rec_desync_count;
	wire [2:0]  rec_desync_reason;

	// The picture is complete when every macroblock of it has been decoded.
	// Comparing the count the core actually retired against the picture size
	// at the end of the slice catches a desync that stayed inside every VLC
	// table but still lost the bit position: the macroblock count and the
	// bitstream disagree about where the slice ended.
	localparam int PIC_SIZE_IN_MBS = (FRAME_W / 16) * (FRAME_H / 16);
	wire rec_slice_end = sl_cap_end;
	wire rec_err_slice_short = rec_slice_end &&
	                           (core_frame_mb_count < PIC_SIZE_IN_MBS[15:0]);
	wire rec_err_slice_long  = rec_slice_end &&
	                           (core_frame_mb_count > PIC_SIZE_IN_MBS[15:0]);

	h264_stream_recovery u_recovery (
		.clk(clk),
		.reset(reset | flush),
		.slice_start(sl_cap_clear),
		.slice_is_idr(sl_is_idr),
		.slice_end(rec_slice_end),
		.err_cavlc_miss(core_err_cavlc_miss),
		.err_bad_mb_type(core_err_bad_mb_type),
		.err_mb_overrun(core_err_mb_overrun),
		.err_slice_short(rec_err_slice_short),
		.err_slice_long(rec_err_slice_long),
		.decode_enable(rec_decode_enable),
		.dpb_flush(rec_dpb_flush),
		.poc_reset(rec_poc_reset),
		.mb_state_clear(rec_mb_state_clear),
		.freeze_output(rec_freeze_output),
		.resync_active(rec_resync_active),
		.desync_count(rec_desync_count),
		.last_desync_reason(rec_desync_reason)
	);

	// Hold the last complete good frame on screen for the whole resync.  A
	// partially decoded frame looks worse than a stale one, and a black screen
	// looks worse than both.
	assign dec_px_wr_en = core_px_wr_en && !rec_freeze_output;
	wire core_dpb_ref_swap;
	wire        core_dpb_rd_valid;
	wire  [7:0] core_dpb_rd_data;
	wire        core_dpb_rd_stall;
	wire        core_dpb_wr_full;
	wire        dpb_ref_ready;
	wire        dpb_swap_busy;
	wire        dpb_frame_done_ack;
	wire [31:0] dpb_current_base;
	wire [31:0] dpb_reference_base;

	// The DDR-resident decoded picture buffer.  Post-deblock reconstruction
	// goes in on dpb_wr_*, motion compensation pulls reference samples back out
	// on dpb_rd_*.  REG_RESPONSE is 0 because h264_decode_core already carries
	// a skid stage on its DPB response path, so the cache answers
	// combinationally on the accepted cycle and the core's skid supplies the
	// single cycle of alignment h264_dpb_one_ref expects.
	h264_dpb_ddr #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.BANK_STRIDE(FRAME_W * FRAME_H + 2 * ((FRAME_W / 2) * (FRAME_H / 2))),
		.REG_RESPONSE(1'b0)
	) u_dpb_ddr (
		.clk(clk),
		.reset(reset | flush),
		.idr_start(rec_dpb_flush),
		.frame_done_req(core_dpb_ref_swap),
		.frame_done_ack(dpb_frame_done_ack),
		.swap_busy(dpb_swap_busy),
		.ref_ready(dpb_ref_ready),
		.current_base(dpb_current_base),
		.reference_base(dpb_reference_base),
		.rec_wr_en(core_dpb_wr_en),
		.rec_wr_addr(core_dpb_wr_addr),
		.rec_wr_data(core_dpb_wr_data),
		.rec_wr_full(core_dpb_wr_full),
		.ref_rd_en(core_dpb_rd_en),
		.ref_rd_addr(core_dpb_rd_addr),
		.ref_rd_stall(core_dpb_rd_stall),
		.ref_rd_data(core_dpb_rd_data),
		.ref_rd_valid(core_dpb_rd_valid),
		.ddr_busy(dpb_ddr_busy),
		.ddr_burstcnt(dpb_ddr_burstcnt),
		.ddr_addr(dpb_ddr_addr),
		.ddr_dout(ddr_dout),
		.ddr_dout_ready(dpb_dout_ready),
		.ddr_rd(dpb_ddr_rd),
		.ddr_din(dpb_ddr_din),
		.ddr_be(dpb_ddr_be),
		.ddr_we(dpb_ddr_we),
		.ddr_req(dpb_ddr_req)
	);
	wire [15:0] core_rbsp_request_offset;
	wire core_rbsp_request_valid;
	wire core_busy;
	wire [7:0] core_decode_state;
	wire [15:0] core_current_mb_addr;
	wire core_error;
	wire [1:0] core_i16_pred_mode =
		(sl_mbt >= 8'd1 && sl_mbt <= 8'd24) ? (sl_mbt[1:0] - 2'd1) : 2'd2;

	h264_decode_core #(
		.FRAME_W(CORE_FRAME_W),
		.FRAME_H(CORE_FRAME_H)
	) product_decode_core (
		.clk(clk),
		.reset(reset | flush),
		.slice_start(slice_valid),
		.slice_is_idr(sl_is_idr),
		.slice_is_i(sl_is_i),
		.slice_qp_y(sl_qp),
		.first_mb_in_slice(sl_first),
		.mb_width(sps_mb_w),
		.mb_height(sps_mb_h),
		.pps_chroma_qp_index_offset(sl_chroma_qp_off),
		.constrained_intra_pred_flag(sl_cip),
		.num_ref_idx_l0_active(sl_num_ref_l0),
		.disable_deblocking_filter_idc(sl_deblock_idc),
		.slice_alpha_c0_offset(sl_alpha_off),
		.slice_beta_offset(sl_beta_off),
		.rbsp_byte(core_rbsp_byte),
		.rbsp_window_base(16'd0),
		.rbsp_request_offset(core_rbsp_request_offset),
		.rbsp_request_valid(core_rbsp_request_valid),
		.mb_type_valid(core_mb_type_valid),
		.mb_type(sl_mbt[4:0]),
		.mb_skip(first_mb_p_skip),
		.intra4x4_modes(core_i4_modes),
		.intra16x16_mode(core_i16_pred_mode),
		.chroma_pred_mode(2'd0),
		.cbp_luma(sl_first_mb_cbp_luma),
		.cbp_chroma(sl_first_mb_cbp_chroma),
		.mb_qp_delta(sl_qpd[5:0]),
		.mb_residual_bit_offset(sl_first_mb_residual_bit_offset),
		.luma4x4_valid(core_luma4x4_valid),
		.luma4x4_idx(core_luma4x4_idx),
		.luma4x4_qp(core_luma4x4_qp),
		.luma4x4_total_coeff(core_luma4x4_total_coeff),
		.luma4x4_trailing_ones(core_luma4x4_trailing_ones),
		.luma4x4_coeff_zigzag(core_luma4x4_coeff_zigzag),
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
		.recon_y(core_recon_y),
		.recon_u(core_recon_u),
		.recon_v(core_recon_v),
		.p16_zero_mv_valid(1'b0),
		.p16_mb_x(8'd0),
		.p16_mb_y(8'd0),
		.p16_mb_is_ref(1'b0),
		.dpb_ref_base(32'd0),
		.p16_residual_y(core_p16_residual_y),
		.p16_residual_u(core_p16_residual_u),
		.p16_residual_v(core_p16_residual_v),
		.dpb_wr_en(core_dpb_wr_en),
		.dpb_wr_addr(core_dpb_wr_addr),
		.dpb_wr_data(core_dpb_wr_data),
		.dpb_rd_en(core_dpb_rd_en),
		.dpb_rd_addr(core_dpb_rd_addr),
		.dpb_rd_data(core_dpb_rd_data),
		.dpb_rd_valid(core_dpb_rd_valid),
		.dpb_rd_stall(core_dpb_rd_stall),
		.dpb_ref_swap(core_dpb_ref_swap),
		.px_wr_en(core_px_wr_en),
		.px_wr_plane(dec_px_plane),
		.px_wr_x(dec_px_x),
		.px_wr_y(dec_px_y),
		.px_wr_data(dec_px_data),
		.frame_done(core_frame_done),
		.frame_mb_count(core_frame_mb_count),
		.err_cavlc_miss(core_err_cavlc_miss),
		.err_bad_mb_type(core_err_bad_mb_type),
		.err_mb_overrun(core_err_mb_overrun),
		.decode_enable(rec_decode_enable),
		.perf_mbox_word(decode_perf_word),
		.busy(core_busy),
		.intra_blocks_done(core_intra_blocks_done),
		.decode_state(core_decode_state),
		.current_mb_addr(core_current_mb_addr),
		.error(core_error)
	);

	// decode_stub is DELETED, not muted.  It was diagnostic-only after Stage A
	// retired it as the pixel source, and it cost 32 DSP blocks (its legacy
	// h264_dequant4x4) plus 6,183 ALUTs.  Deleting it also removes the only
	// other thing that could paint the frame store, so any picture on screen is
	// now unambiguously the decode core's output -- do not reinstate it.
	assign recon_sig       = 8'd0;
	assign recon_dbg       = 8'd0;
	assign recon_dbg_valid = 1'b0;
	assign recon_valid     = 1'b0;
	assign stub_busy       = 1'b0;
	assign stub_frames     = 16'd0;

	// decode_stub is retired as the product pixel source.  Once the decode core
	// has committed a real sample the stub's diagnostic paint is muted so it can
	// never race the core for the non-DDR frame_store either.
	wire        stub_fs_wr_en    = 1'b0;
	wire [15:0] stub_fs_wr_pixel = 16'd0;
	wire        stub_fs_wr_reset = 1'b0;
	wire        stub_fs_swap     = 1'b0;
	reg         core_px_owns;
	always @(posedge clk) begin
		if (reset)
			core_px_owns <= 1'b0;
		else if (dec_px_wr_en)
			core_px_owns <= 1'b1;
	end
	always @* begin
		fs_wr_en    = stub_fs_wr_en    & ~core_px_owns;
		fs_wr_pixel = stub_fs_wr_pixel;
		fs_wr_reset = stub_fs_wr_reset & ~core_px_owns;
		fs_swap     = stub_fs_swap     & ~core_px_owns;
	end

	(* keep = 1 *) wire keep_si = si_active;
	(* keep = 1 *) wire keep_bf = bf_has;
	// Touch residual_csum + place pulse + a few coeff LSBs so place is not pruned.
	wire _keep = keep_si | keep_bf | |fifo_level | |bytes_in | stub_busy | sps_busy |
	             pps_busy | sl_busy | |pps_id_w | |pps_qp | pps_cabac | |sl_first |
	             |sl_fn | |sl_qpd | pps_deblock | |residual_csum | residual_place_pulse |
	             recon_valid | recon_dbg_valid | |recon_sig | |recon_dbg |
	             sl_place_ok | |sl_place_tc | |sl_place_t1 | |sl_place_qp |
	             |sl_i4_pred_mode_flags | |sl_i4_rem_modes | sl_i4_modes_present |
	             sl_luma4x4_blocks_valid | sl_luma4x4_blocks_present |
	             residual_coeff[0][0] | residual_coeff[1][0] |
	             residual_coeff[15][0] | sl_place_coeff[0][0] | sl_place_coeff[15][0] |
	             core_luma4x4_valid | core_luma_feed_active | core_dpb_wr_en |
	             core_mb_type_valid | |sweep_state | |sweep_mb | |sweep_mb_total |
	             |core_intra_blocks_done | |sweep_blk_guard |
	             |core_dpb_wr_addr | |core_dpb_wr_data | core_dpb_rd_en |
	             |core_dpb_rd_addr | core_frame_done | |core_frame_mb_count |
	             core_dpb_wr_full | core_dpb_rd_stall | dpb_ref_ready |
	             dpb_swap_busy | dpb_frame_done_ack | |dpb_current_base |
	             |dpb_reference_base |
	             core_rbsp_request_valid | |core_rbsp_request_offset | core_busy |
	             |core_decode_state | |core_current_mb_addr | core_error;

endmodule
