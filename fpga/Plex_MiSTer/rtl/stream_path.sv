// Phase 3.3–3.3l-1: F3 → FIFO → NAL → SPS/PPS/slice_hdr(+full first residual) + decode.
// Hybrid: diagnostic paint is F3-only; host F1 recon owns product present (Plex.sv).

`ifndef DECODE_REAL_INTRA
`define DECODE_REAL_INTRA 0
`endif

module stream_path #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	// Compressed-bitstream ring geometry.  These are parameters and not literals
	// on purpose: a higher-bitrate stream needs a longer ring and a deeper
	// prefetch, and that must not require editing the delivery path.  RING_BYTES
	// must be a power of two and must match what misterplexd allocates.
	parameter int BITSTREAM_RING_BYTES      = 262144,
	parameter int BITSTREAM_PREFETCH_QWORDS = 64,
	parameter int BITSTREAM_PREFETCH_BURST  = 16,
	parameter int BITSTREAM_RING_LOW_BYTES  = 8192
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
	// Values mirror DDR_FRAME_CODED_WIDTH/HEIGHT in ddr_frame_layout_params.svh.
	// They are spelled out here rather than `include`d because stream_path is
	// elaborated by benches that do not put rtl/ on the include path.
	localparam int CORE_FRAME_W = 624;
	localparam int CORE_FRAME_H = 480;

	// Whole-slice RBSP capacity.  624x480 Baseline I-slices measure a few KB at
	// the bitrates we ship, but the buffer must not be sized to that: it is a
	// parameter so a higher-bitrate stream only costs memory, not correctness.
	localparam int RBSP_DEPTH_BYTES = 8192;

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

	ddr_bitstream_reader #(
		.RING_BYTES(BITSTREAM_RING_BYTES),
		.RING_LOW_BYTES(BITSTREAM_RING_LOW_BYTES),
		.PREFETCH_QWORDS(BITSTREAM_PREFETCH_QWORDS),
		.PREFETCH_BURST(BITSTREAM_PREFETCH_BURST)
	) ddr_stream (
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
	wire vcl_cap_clear, vcl_cap_en, vcl_cap_end;
	wire [7:0] vcl_cap_data;
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
		.sl_nal_ref_idc_nonzero(sl_nal_ref_idc_nonzero),
		.vcl_cap_clear(vcl_cap_clear), .vcl_cap_en(vcl_cap_en),
		.vcl_cap_data(vcl_cap_data), .vcl_cap_end(vcl_cap_end)
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

	pps_parser pps (
		.clk(clk), .reset(reset | flush),
		.cap_clear(pps_cap_clear), .cap_en(pps_cap_en),
		.cap_data(pps_cap_data), .cap_end(pps_cap_end),
		.valid(pps_valid), .pps_id(pps_id_w), .sps_id(pps_sps_id),
		.entropy_cabac(pps_cabac), .num_ref_l0(pps_nref),
		.pic_init_qp(pps_qp), .deblock_ctrl(pps_deblock), .busy(pps_busy)
	);

	wire sl_busy, sl_is_i, sl_has_mbt, sl_res_ok;
	wire [15:0] sl_first, sl_fn, sl_idr_pic;
	wire [7:0] sl_type, sl_pps, sl_mbt;
	wire signed [7:0] sl_qpd, sl_rdc;
	wire [5:0] sl_qp;
	wire [1:0] sl_deblock_idc;
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

	// Forward declarations for the I-MB residual feeder (instantiated below).
	wire [15:0] feed_i4_pred_mode_flags;
	wire [47:0] feed_i4_rem_modes;
	wire        feed_i4_modes_present;
	wire [1:0]  feed_i16_mode;
	wire [1:0]  feed_chroma_pred_mode;
	wire [3:0]  feed_cbp_luma;
	wire [1:0]  feed_cbp_chroma;
	wire signed [5:0] feed_mb_qp_delta;
	wire [5:0]  feed_mb_qp_y;
	wire [15:0] feed_mb_residual_bit_offset;
	wire        feed_busy;
	wire        feed_frame_done;
	wire        feed_error;
	wire [15:0] feed_rbsp_request_offset;
	wire        feed_rbsp_request_valid;
	wire        core_mb_type_valid;
	wire [4:0]  core_mb_type;
	wire [4:0]  core_intra_blocks_done;
	wire        core_luma4x4_valid;
	wire [3:0]  core_luma4x4_idx;
	wire [5:0]  core_luma4x4_qp;
	wire [4:0]  core_luma4x4_total_coeff;
	wire [1:0]  core_luma4x4_trailing_ones;
	wire signed [15:0] core_luma4x4_coeff_zigzag [0:15];
	wire        core_busy;

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
			rem_mode = feed_i4_rem_modes[core_mi * 3 +: 3];
			if (!feed_i4_modes_present)
				core_i4_modes_calc[core_mi] = 4'd2;
			else if (feed_i4_pred_mode_flags[core_mi])
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

	// ── Per-MB I-slice residual feed (no MB0 coeff replay) ──────────────────
	// slice_hdr_parser only exposes the FIRST macroblock.  h264_i_mb_feed walks
	// real CAVLC residual from the whole-slice RBSP window for every MB and
	// parses subsequent I-MB syntax so each macroblock gets its own coeffs.

	// Whole-slice RBSP store with a real sliding window.  The old 64-byte
	// capture could never answer rbsp_request_offset, so the core's request was
	// dropped on the floor and every macroblock past the first read the same 64
	// bytes.  h264_rbsp_window holds the entire emulation-prevention-stripped
	// VCL NAL and serves a 64-byte window combinationally at whatever offset
	// the active consumer (I-MB feed or P residual walker) asks for.
	wire [15:0] core_rbsp_request_offset_raw;
	wire        core_rbsp_request_valid_raw;
	wire [15:0] core_rbsp_request_offset =
		feed_busy ? feed_rbsp_request_offset : core_rbsp_request_offset_raw;
	wire        core_rbsp_request_valid =
		feed_busy ? feed_rbsp_request_valid : core_rbsp_request_valid_raw;
	wire [7:0]  core_rbsp_byte [0:63];
	wire [15:0] core_rbsp_window_base;
	wire [15:0] core_rbsp_avail;
	wire [15:0] core_rbsp_length;
	wire        core_rbsp_complete;
	wire        core_rbsp_overflow;

	h264_rbsp_window #(
		.DEPTH_BYTES(RBSP_DEPTH_BYTES),
		.WINDOW_BYTES(64)
	) core_rbsp (
		.clk(clk),
		.reset(reset | flush),
		.wr_clear(vcl_cap_clear),
		.wr_en(vcl_cap_en),
		.wr_data(vcl_cap_data),
		.wr_end(vcl_cap_end),
		.req_valid(core_rbsp_request_valid),
		.req_offset(core_rbsp_request_offset),
		.window(core_rbsp_byte),
		.window_base(core_rbsp_window_base),
		.window_avail(core_rbsp_avail),
		.length(core_rbsp_length),
		.complete(core_rbsp_complete),
		.overflow(core_rbsp_overflow)
	);

	// Start the feeder once the first-MB residual probe is placed AND the VCL
	// RBSP capture has finished (window holds the whole NAL).  One-shot: the
	// feeder latches on the rising edge of slice_go.
	reg sl_luma_blocks_seen;
	reg feed_started;
	wire feed_slice_go = sl_luma_blocks_seen && core_rbsp_complete && sl_is_i &&
	                     (sps_mb_w != 8'd0) && (sps_mb_h != 8'd0) &&
	                     !feed_started && !feed_busy;
	always @(posedge clk) begin
		if (reset | flush | vcl_cap_clear) begin
			sl_luma_blocks_seen <= 1'b0;
			feed_started <= 1'b0;
		end else begin
			if (sl_luma4x4_blocks_valid && sl_luma4x4_blocks_present)
				sl_luma_blocks_seen <= 1'b1;
			// Stay started for this VCL NAL even after frame_feed_done so we
			// do not immediately re-arm on the same sticky complete/present.
			if (feed_slice_go)
				feed_started <= 1'b1;
		end
	end

	h264_i_mb_feed #(
		.MB_W_MAX(40)
	) i_mb_feed (
		.clk(clk),
		.reset(reset | flush),
		.slice_go(feed_slice_go),
		.slice_is_i(sl_is_i),
		.mb_width(sps_mb_w),
		.mb_height(sps_mb_h),
		.first_mb_in_slice(sl_first),
		.slice_qp_y(sl_qp),
		.first_mb_type(sl_mbt),
		.first_i4_pred_mode_flags(sl_i4_pred_mode_flags),
		.first_i4_rem_modes(sl_i4_rem_modes),
		.first_i4_modes_present(sl_i4_modes_present),
		.first_cbp_luma(sl_first_mb_cbp_luma),
		.first_cbp_chroma(sl_first_mb_cbp_chroma),
		.first_residual_bit_offset(sl_first_mb_residual_bit_offset),
		.rbsp_byte(core_rbsp_byte),
		.rbsp_window_base(core_rbsp_window_base),
		.rbsp_request_offset(feed_rbsp_request_offset),
		.rbsp_request_valid(feed_rbsp_request_valid),
		.rbsp_length(core_rbsp_length),
		.rbsp_complete(core_rbsp_complete),
		.core_busy(core_busy),
		.core_intra_blocks_done(core_intra_blocks_done),
		.mb_type_valid(core_mb_type_valid),
		.mb_type(core_mb_type),
		.i4_pred_mode_flags(feed_i4_pred_mode_flags),
		.i4_rem_modes(feed_i4_rem_modes),
		.i4_modes_present(feed_i4_modes_present),
		.intra16x16_mode(feed_i16_mode),
		.chroma_pred_mode(feed_chroma_pred_mode),
		.cbp_luma(feed_cbp_luma),
		.cbp_chroma(feed_cbp_chroma),
		.mb_qp_delta(feed_mb_qp_delta),
		.mb_qp_y(feed_mb_qp_y),
		.mb_residual_bit_offset(feed_mb_residual_bit_offset),
		.luma4x4_valid(core_luma4x4_valid),
		.luma4x4_idx(core_luma4x4_idx),
		.luma4x4_qp(core_luma4x4_qp),
		.luma4x4_total_coeff(core_luma4x4_total_coeff),
		.luma4x4_trailing_ones(core_luma4x4_trailing_ones),
		.luma4x4_coeff_zigzag(core_luma4x4_coeff_zigzag),
		.busy(feed_busy),
		.frame_feed_done(feed_frame_done),
		.error(feed_error)
	);
	wire [7:0] core_recon_y [0:255];
	wire [7:0] core_recon_u [0:63];
	wire [7:0] core_recon_v [0:63];
	wire signed [15:0] core_p16_residual_y [0:255];
	wire signed [15:0] core_p16_residual_u [0:63];
	wire signed [15:0] core_p16_residual_v [0:63];
	generate
		for (core_gi = 0; core_gi < 64; core_gi = core_gi + 1) begin : gen_core_zero64
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
	reg core_dpb_rd_valid;
	always @(posedge clk) begin
		if (reset | flush)
			core_dpb_rd_valid <= 1'b0;
		else
			core_dpb_rd_valid <= core_dpb_rd_en;
	end
	wire core_frame_done;
	wire [15:0] core_frame_mb_count;
	wire [7:0] core_decode_state;
	wire [15:0] core_current_mb_addr;
	wire core_error;
	// h264_decode_core.slice_start is a PULSE: it hard-resets the intra
	// reconstruction front-end and the DPB slice state.  slice_valid from the
	// slice header parser is a LEVEL that stays high for the rest of the run,
	// so wiring it straight through held h264_decode_top in permanent reset and
	// no macroblock was ever reconstructed.  Edge-detect it.
	reg core_slice_valid_d;
	always @(posedge clk) begin
		if (reset | flush)
			core_slice_valid_d <= 1'b0;
		else
			core_slice_valid_d <= slice_valid;
	end
	wire core_slice_start = slice_valid & ~core_slice_valid_d;

	h264_decode_core #(
		.FRAME_W(CORE_FRAME_W),
		.FRAME_H(CORE_FRAME_H)
	) product_decode_core (
		.clk(clk),
		.reset(reset | flush),
		.slice_start(core_slice_start),
		.slice_is_idr(sl_is_idr),
		.slice_is_i(sl_is_i),
		.slice_qp_y(sl_qp),
		.first_mb_in_slice(sl_first),
		.mb_width(sps_mb_w),
		.mb_height(sps_mb_h),
		.pps_chroma_qp_index_offset(5'sd0),
		.rbsp_byte(core_rbsp_byte),
		.rbsp_window_base(core_rbsp_window_base),
		.rbsp_request_offset(core_rbsp_request_offset_raw),
		.rbsp_request_valid(core_rbsp_request_valid_raw),
		.mb_type_valid(core_mb_type_valid),
		.mb_type(core_mb_type),
		.mb_skip(1'b0),
		.intra4x4_modes(core_i4_modes),
		.intra16x16_mode(feed_i16_mode),
		.chroma_pred_mode(feed_chroma_pred_mode),
		.cbp_luma(feed_cbp_luma),
		.cbp_chroma(feed_cbp_chroma),
		.mb_qp_delta(feed_mb_qp_delta),
		.mb_residual_bit_offset(feed_mb_residual_bit_offset),
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
		.dpb_rd_data(8'd0),
		.dpb_rd_valid(core_dpb_rd_valid),
		.px_wr_en(dec_px_wr_en),
		.px_wr_plane(dec_px_plane),
		.px_wr_x(dec_px_x),
		.px_wr_y(dec_px_y),
		.px_wr_data(dec_px_data),
		.frame_done(core_frame_done),
		.frame_mb_count(core_frame_mb_count),
		.busy(core_busy),
		.intra_blocks_done(core_intra_blocks_done),
		.decode_state(core_decode_state),
		.current_mb_addr(core_current_mb_addr),
		.error(core_error)
	);

	// Product decode is always rooted at product_decode_core above.  The legacy
	// decode_stub remains only as the diagnostic frame-store painter until the
	// core owns presentation; DECODE_REAL_INTRA no longer swaps the product
	// decoder subtree or bypasses MC/DPB/deblock.
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
			.recon_dbg(recon_dbg),
			.recon_dbg_valid(recon_dbg_valid),
			.recon_valid(recon_valid),
			.wr_en(stub_fs_wr_en),
			.wr_pixel(stub_fs_wr_pixel),
			.wr_reset_ptr(stub_fs_wr_reset),
			.swap_req(stub_fs_swap),
			.busy(stub_busy),
			.frames_out(stub_frames)
		);
		end
	endgenerate

	// decode_stub is retired as the product pixel source: under DDR_FRAME_STORE
	// present_core ignores fs_* entirely, so the stub's diagnostic paint never
	// reaches the screen and the decode core's dec_px_* stream is the only
	// pixel source.  The fs_* path is left intact for the non-DDR frame_store
	// configuration and for the diagnostic frame-cadence benches.
	wire        stub_fs_wr_en;
	wire [15:0] stub_fs_wr_pixel;
	wire        stub_fs_wr_reset;
	wire        stub_fs_swap;
	always @* begin
		fs_wr_en    = stub_fs_wr_en;
		fs_wr_pixel = stub_fs_wr_pixel;
		fs_wr_reset = stub_fs_wr_reset;
		fs_swap     = stub_fs_swap;
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
	             core_luma4x4_valid | core_dpb_wr_en |
	             core_mb_type_valid | feed_busy | feed_frame_done | feed_error |
	             |core_intra_blocks_done | |feed_cbp_luma | |feed_mb_residual_bit_offset |
	             |core_dpb_wr_addr | |core_dpb_wr_data | core_dpb_rd_en |
	             |core_dpb_rd_addr | core_frame_done | |core_frame_mb_count |
	             core_rbsp_request_valid | |core_rbsp_request_offset | core_busy |
	             |core_rbsp_avail | |core_rbsp_length | core_rbsp_complete |
	             core_rbsp_overflow | |core_rbsp_window_base |
	             vcl_cap_clear | vcl_cap_en | vcl_cap_end | |vcl_cap_data |
	             |core_decode_state | |core_current_mb_addr | core_error;

endmodule
