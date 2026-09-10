// Bounded 320x240 decoder integration with a two-bank native I420 RAM.
// Baseline SPI/diagnostic defaults remain available. AU mode owns metadata,
// RBSP and native pictures until the separate publisher retires them.

module stream_path #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter bit ENABLE_AU_PROTOCOL = 1'b0,
	parameter bit ENABLE_PICTURE_PUBLISH = 1'b0,
	parameter [31:0] VIDEO_BUILD_ID = 32'd0,
	parameter [31:0] VIDEO_FEATURES = 32'd0,
	parameter bit LEGACY_SLICE_DIAGNOSTIC = !ENABLE_AU_PROTOCOL,
	// Explicit override permits engineering profiles with capability mask zero.
	parameter bit IDR_ONLY_PROFILE =
		ENABLE_PICTURE_PUBLISH && VIDEO_FEATURES[4] && !VIDEO_FEATURES[5],
	parameter bit ENABLE_FRAME_DEBLOCK = 1'b0,
	// Encoded AU admission is independent of the fixed 8192-byte VCL RAM.
	parameter int MAX_AU_BYTES = 8192,
	parameter bit SYNC_MB_PLANES = ENABLE_AU_PROTOCOL
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
	output wire [5:0]  slice_qp,
	output wire [4:0]  residual_tc,
	output wire [1:0]  residual_t1,
	output wire        residual_ok,
	output wire signed [7:0] residual_dc,
	// 3.3l-1: residualCsum8=XOR sat8(coeff[0:15]); full coeffs for 3.3l-2 inv_quant.
	// residual_coeff may be left unconnected at top until inv_quant; kept below.
	output wire [7:0]  residual_csum,
	output wire signed [8:0] residual_coeff [0:15],
	// R-csum6 Rank3: 1-cycle ST_PLACE pulse for status residual sticky freeze
	output wire        residual_place_pulse,
	output wire [7:0]  recon_sig,
	output wire [7:0]  recon_dbg,
	output wire        recon_dbg_valid,
	output wire        recon_valid,
	output wire [15:0] frames_out,

	output wire        fs_wr_en,
	output wire [15:0] fs_wr_pixel,
	output wire        fs_wr_reset,
	output wire        fs_swap,
	input  wire        fs_wr_ready,  // present accept_cmd (Plex wires F1 wr_ready)
	input  wire        fs_present_sel,  // fpga_wr | stub_allow; no default (Q17 10231)
	input  wire        fs_writes_idle,
	output wire        decoder_idle,
	output wire        next_vcl_ready,
	output reg         current_au_valid,
	output reg  [63:0] current_au_session_id,
	output reg  [31:0] current_au_seq,
	output reg signed [63:0] current_au_pts,
	output reg signed [63:0] current_au_duration,
	output reg  [31:0] current_au_timebase_num,
	output reg  [31:0] current_au_timebase_den,
	output reg  [31:0] current_au_flags,
	output wire [63:0] video_nonce,
	output wire [63:0] video_session_id,
	output wire        video_reset_pending,
	output wire        transport_quiescent,
	output wire        video_clear,
	output wire        codec_error_valid,
	output reg [7:0]   codec_error_code,
	output wire        codec_error_pulse,
	input wire         codec_error_committed,
	output wire        picture_valid,
	input wire         picture_ready,
	output reg         picture_bank,
	output reg [15:0]  picture_coded_width, picture_coded_height,
	output reg [15:0]  picture_crop_left, picture_crop_right,
	output reg [15:0]  picture_crop_top, picture_crop_bottom,
	input wire         pub_mem_rd,
	input wire [17:0]  pub_mem_addr,
	output wire        pub_mem_ready,
	output wire [7:0]  pub_mem_data,
	output reg         pub_mem_valid,
	// Donor TB-only gold-compare latch; not a decoded-picture capability.
	output wire        product_recon_ok
);
	localparam int INPUT_FIFO_BYTES = 32768;
	localparam int ENCODED_AU_LIMIT = MAX_AU_BYTES < 1 ? 1 :
		(MAX_AU_BYTES > INPUT_FIFO_BYTES ? INPUT_FIFO_BYTES : MAX_AU_BYTES);

	wire        si_wr_en;
	wire [7:0]  si_wr_data;
	wire        si_wr_flush;
	wire        si_active;

	stream_ingest si (
		.clk(clk), .reset(reset),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_dout(ioctl_dout),
		.enable(enable && !(ENABLE_AU_PROTOCOL && ddr_stream_enable)),
		.wr_en(si_wr_en), .wr_data(si_wr_data), .wr_flush(si_wr_flush),
		.active(si_active), .bytes_in(bytes_in)
	);

	wire        ddr_wr_en;
	wire [7:0]  ddr_wr_data;
	wire        ddr_wr_flush;
	wire        bf_wr_full;
	wire        ddr_wr_last;
	wire        au_valid, au_ready;
	wire [63:0] au_session_id;
	wire [31:0] au_seq, au_timebase_num, au_timebase_den, au_flags;
	wire signed [63:0] au_pts, au_duration;
	reg         au_collecting;
	reg         au_bytes_complete;
	reg         codec_fault_pending;
	reg         codec_fault_reported;
	wire pipeline_reset = reset | flush | ddr_wr_flush;
	assign video_clear = pipeline_reset;
	wire ddr_selected = ddr_stream_enable &&
	                    (ENABLE_AU_PROTOCOL || !(enable && ioctl_download));
	wire reader_full = !ddr_selected | bf_wr_full | si_wr_en | pipeline_reset |
	                   (ENABLE_AU_PROTOCOL && !au_collecting);
	wire ddr_byte_accept = ddr_wr_en && !reader_full;
	wire scan_hold = ENABLE_AU_PROTOCOL && ddr_stream_enable &&
	                 (!current_au_valid || !au_bytes_complete);

	ddr_bitstream_reader #(
		.ENABLE_AU_PROTOCOL(ENABLE_AU_PROTOCOL),
		.VIDEO_BUILD_ID(VIDEO_BUILD_ID),
		.VIDEO_FEATURES(VIDEO_FEATURES),
		.MAX_AU_BYTES(ENCODED_AU_LIMIT),
		.MAX_WIDTH(16'd320),
		.MAX_HEIGHT(16'd240)
	) ddr_stream (
		.clk(clk), .reset(reset),
		.enable(ddr_stream_enable),
		.flush(flush),
		.out_valid(ddr_wr_en),
		.out_byte(ddr_wr_data),
		.out_last(ddr_wr_last),
		.out_flush(ddr_wr_flush),
		.out_full(reader_full),
		.au_valid(au_valid),
		.au_ready(au_ready),
		.au_session_id(au_session_id),
		.au_seq(au_seq),
		.au_pts(au_pts),
		.au_duration(au_duration),
		.au_timebase_num(au_timebase_num),
		.au_timebase_den(au_timebase_den),
		.au_flags(au_flags),
		.video_nonce(video_nonce),
		.video_session_id(video_session_id),
		.reset_pending(video_reset_pending),
		.transport_quiescent(transport_quiescent),
		.decoder_idle(decoder_idle),
		.decoder_fault_valid(codec_fault_pending),
		.decoder_fault_seq(current_au_seq),
		.bit_ready(1'b1),
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
	wire bf_wr_en = si_wr_en | ddr_byte_accept;
	wire [7:0] bf_wr_data = si_wr_en ? si_wr_data : ddr_wr_data;
	wire bf_wr_flush = si_wr_flush | ddr_wr_flush | flush;

	bitstream_fifo #(.DEPTH(INPUT_FIFO_BYTES)) bfifo (
		.clk(clk), .reset(reset),
		.wr_en(bf_wr_en), .wr_data(bf_wr_data), .wr_flush(bf_wr_flush),
		.wr_full(bf_wr_full), .wr_level(fifo_level),
		.rd_en(bf_rd_en && !scan_hold), .rd_data(bf_rd_data),
		.rd_empty(bf_rd_empty), .has_data(bf_has)
	);

	wire vcl_pulse, has_idr_w;
	wire [7:0] idr_c, sps_c, pps_c, slc_c;
	wire sps_cap_clear, sps_cap_en, sps_cap_end;
	wire [7:0] sps_cap_data;
	wire pps_cap_clear, pps_cap_en, pps_cap_end;
	wire [7:0] pps_cap_data;
	wire sl_cap_clear, sl_cap_en, sl_cap_end, sl_is_idr;
	wire [7:0] sl_cap_data;
	wire sl_rbsp_clear, sl_rbsp_en, sl_rbsp_end;
	wire [7:0] sl_rbsp_data;
	wire [13:0] sl_rbsp_len;
	wire scanner_idle, scanner_au_done;
	reg au_scan_complete;

	nalu_scanner #(.ENABLE_AU_END(ENABLE_AU_PROTOCOL)) scan (
		.clk(clk), .reset(pipeline_reset),
		.rd_data(bf_rd_data), .rd_empty(bf_rd_empty | scan_hold), .rd_en(bf_rd_en),
		.au_end(current_au_valid && au_bytes_complete && bf_rd_empty && !bf_rd_en),
		.rbsp_release(next_vcl_ready),
		.au_done(scanner_au_done), .idle(scanner_idle),
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
		.sl_rbsp_clear(sl_rbsp_clear), .sl_rbsp_en(sl_rbsp_en),
		.sl_rbsp_data(sl_rbsp_data), .sl_rbsp_end(sl_rbsp_end),
		.sl_rbsp_len(sl_rbsp_len)
	);

	assign has_idr     = has_idr_w;
	assign idr_count   = idr_c;
	assign sps_count   = sps_c;
	assign pps_count   = pps_c;
	assign slice_count = slc_c;

	wire [4:0] log2_fn, log2_poc;
	wire [2:0] poc_t;
	wire [7:0] active_sps_id;
	wire [7:0] sps_max_num_ref_frames;
	wire [15:0] sps_coded_w, sps_coded_h;
	wire [15:0] sps_crop_l, sps_crop_r, sps_crop_t, sps_crop_b;
	wire [15:0] sps_sar_w, sps_sar_h;
	wire sps_sar_known, sps_full_range;
	wire [7:0] sps_matrix;
	wire sps_busy, sps_error;

	sps_parser sps (
		.clk(clk), .reset(pipeline_reset),
		.cap_clear(sps_cap_clear), .cap_en(sps_cap_en),
		.cap_data(sps_cap_data), .cap_end(sps_cap_end),
		.valid(sps_valid), .profile_idc(sps_profile), .level_idc(sps_level),
		.error(sps_error),
		.sps_id(active_sps_id),
		.width(sps_width), .height(sps_height),
		.coded_width(sps_coded_w), .coded_height(sps_coded_h),
		.crop_left(sps_crop_l), .crop_right(sps_crop_r),
		.crop_top(sps_crop_t), .crop_bottom(sps_crop_b),
		.sar_width(sps_sar_w), .sar_height(sps_sar_h), .sar_known(sps_sar_known),
		.video_full_range_flag(sps_full_range), .matrix_coefficients(sps_matrix),
		.log2_max_frame_num(log2_fn), .poc_type(poc_t),
		.max_num_ref_frames(sps_max_num_ref_frames),
		.log2_max_pic_order_cnt_lsb(log2_poc),
		.mb_width(sps_mb_w), .mb_height(sps_mb_h),
		.busy(sps_busy)
	);

	wire pps_busy, pps_error, pps_cabac, pps_deblock, pps_constrained_intra;
	wire [7:0] pps_id_w, pps_sps_id, pps_nref_minus1;
	wire [7:0] pps_nref = pps_nref_minus1 + 8'd1;
	wire signed [7:0] pps_qp, pps_chroma_qp_offset;

	pps_parser pps (
		.clk(clk), .reset(pipeline_reset),
		.cap_clear(pps_cap_clear), .cap_en(pps_cap_en),
		.cap_data(pps_cap_data), .cap_end(pps_cap_end),
		.valid(pps_valid), .pps_id(pps_id_w), .sps_id(pps_sps_id),
		.error(pps_error),
		.entropy_cabac(pps_cabac), .num_ref_l0(pps_nref_minus1),
		.chroma_qp_index_offset(pps_chroma_qp_offset),
		.constrained_intra_pred(pps_constrained_intra),
		.pic_init_qp(pps_qp), .deblock_ctrl(pps_deblock), .busy(pps_busy)
	);

	wire sl_busy, sl_is_i, sl_has_mbt, sl_res_ok, sl_header_error;
	wire parameter_id_mismatch = sps_valid && pps_valid && pps_sps_id != active_sps_id;
	wire decoder_header_error = sps_error || pps_error || sl_header_error ||
	                            parameter_id_mismatch;
	wire [15:0] sl_first, sl_fn, sl_idr_pic;
	wire [7:0] sl_type, sl_pps, sl_mbt;
	wire signed [7:0] sl_qpd, sl_rdc;
	wire [5:0] sl_qp;
	wire [4:0] sl_rtc;
	wire [1:0] sl_rt1;
	wire sl_place_ok;
	wire [4:0] sl_place_tc;
	wire [1:0] sl_place_t1;
	wire signed [7:0] sl_place_dc;
	wire [5:0] sl_place_qp;
	wire signed [8:0] sl_place_coeff [0:15];
	wire [16:0] sl_bit_pos_hdr, sl_bit_pos_resid;
	wire        sl_bit_pos_valid;
	wire [1:0] sl_deblock_idc;
	wire signed [7:0] sl_alpha_div2, sl_beta_div2;
	wire [16:0] horizontal_crop = {1'b0, sps_crop_l} + {1'b0, sps_crop_r};
	wire [16:0] vertical_crop = {1'b0, sps_crop_t} + {1'b0, sps_crop_b};
	// Coded dimensions govern reconstruction/reference bounds; allocation stays
	// 320x240 with fixed plane offsets, independently of the visible crop.
	wire coded_geometry_valid = sps_coded_w != 0 && sps_coded_w <= 16'd320 &&
		sps_coded_h != 0 && sps_coded_h <= 16'd240 &&
		sps_coded_w == {4'd0, sps_mb_w, 4'd0} &&
		sps_coded_h == {4'd0, sps_mb_h, 4'd0} &&
		horizontal_crop < {1'b0, sps_coded_w} &&
		vertical_crop < {1'b0, sps_coded_h} &&
		{1'b0, sps_width} == {1'b0, sps_coded_w} - horizontal_crop &&
		{1'b0, sps_height} == {1'b0, sps_coded_h} - vertical_crop &&
		!(sps_crop_l[0] || sps_crop_r[0] || sps_crop_t[0] || sps_crop_b[0]);
	// Unspecified SAR remains 0/0/unknown in controller metadata; do not rewrite
	// a legal PMS capture to claim square pixels or an original source DAR.
	wire source_sar_supported = sps_sar_known ?
		(sps_sar_w != 0 && sps_sar_w == sps_sar_h) :
		(sps_sar_w == 0 && sps_sar_h == 0);
	wire source_format_supported = coded_geometry_valid && source_sar_supported && !sps_full_range &&
		(sps_matrix == 8'd2 || sps_matrix == 8'd5 || sps_matrix == 8'd6);

	// Preserve the existing MB0 diagnostic handoff. These are not full-picture
	// validity signals; the decoder's publication ABI is a separate dependency.
	wire [7:0] place_csum;
	wire       place_pulse;
	slice_hdr_parser #(
		.BIT_W(17), .LEGACY_DIAGNOSTIC(LEGACY_SLICE_DIAGNOSTIC)
	) slp (
		.clk(clk), .reset(pipeline_reset),
		.cap_clear(sl_cap_clear), .cap_en(sl_cap_en),
		.cap_data(sl_cap_data), .cap_end(sl_cap_end),
		.is_idr_nal(sl_is_idr),
		.nal_ref_idc(last_nal_type[6:5]),
		.log2_max_frame_num(log2_fn),
		.log2_max_pic_order_cnt_lsb(log2_poc),
		.poc_type(poc_t),
		.sps_ready(sps_valid && (LEGACY_SLICE_DIAGNOSTIC || source_format_supported)),
		.pps_ready(pps_valid && (LEGACY_SLICE_DIAGNOSTIC || pps_sps_id == active_sps_id)),
		.active_pps_id(pps_id_w), .num_ref_l0(pps_nref_minus1),
		.deblock_ctrl(pps_deblock),
		.disable_deblocking_idc(sl_deblock_idc),
		.slice_alpha_c0_offset_div2(sl_alpha_div2),
		.slice_beta_offset_div2(sl_beta_div2),
		.pic_init_qp(pps_qp),
		.valid(slice_valid),
		.error(sl_header_error),
		.first_mb(sl_first), .slice_type(sl_type), .pps_id(sl_pps),
		.frame_num(sl_fn), .idr_pic_id(sl_idr_pic),
		.is_i_slice(sl_is_i),
		.slice_qp_delta(sl_qpd), .slice_qp(sl_qp),
		.first_mb_type(sl_mbt), .has_mb_type(sl_has_mbt),
		.residual_tc(sl_rtc), .residual_t1(sl_rt1), .residual_ok(sl_res_ok),
		.residual_dc(sl_rdc),
		.residual_csum(place_csum),
		.residual_coeff(residual_coeff),
		.residual_place_pulse(place_pulse),
		.residual_place_ok(sl_place_ok),
		.residual_place_tc(sl_place_tc),
		.residual_place_t1(sl_place_t1),
		.residual_place_dc(sl_place_dc),
		.residual_place_qp(sl_place_qp),
		.residual_place_coeff(sl_place_coeff),
		.bit_pos_hdr(sl_bit_pos_hdr),
		.bit_pos_resid(sl_bit_pos_resid),
		.bit_pos_valid(sl_bit_pos_valid),
		.busy(sl_busy)
	);

	assign slice_type    = sl_type;
	assign slice_is_i    = sl_is_i;
	assign first_mb_type = sl_mbt;
	assign has_mb_type   = sl_has_mbt;
	assign slice_qp      = sl_qp;
	assign residual_tc   = sl_rtc;
	assign residual_t1   = sl_rt1;
	assign residual_dc   = sl_rdc;

	wire [7:0]  stub_recon_sig, stub_recon_dbg;
	wire        stub_recon_dbg_valid, stub_recon_valid;
	wire        stub_wr_en, stub_wr_reset, stub_swap, stub_busy_w;
	wire [15:0] stub_wr_pixel;
	wire [15:0] stub_frames_w;

	decode_stub #(
		.WIDTH(320),
		.HEIGHT(240)
	) stub (
		.clk(clk), .reset(pipeline_reset),
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
		.residual_ok(sl_place_ok),
		.residual_tc(sl_place_tc),
		.residual_dc(sl_place_dc),
		.residual_valid(place_pulse),
		.slice_qp(sl_place_qp),
		.residual_coeff(sl_place_coeff),
		.recon_sig(stub_recon_sig),
		.recon_dbg(stub_recon_dbg),
		.recon_dbg_valid(stub_recon_dbg_valid),
		.recon_valid(stub_recon_valid),
		.wr_en(stub_wr_en),
		.wr_pixel(stub_wr_pixel),
		.wr_reset_ptr(stub_wr_reset),
		.swap_req(stub_swap),
		.busy(stub_busy_w),
		.frames_out(stub_frames_w)
	);

	wire [7:0]  mb_recon_sig, mb_recon_dbg;
	wire        mb_recon_dbg_valid, mb_recon_valid;
	wire        mb_wr_en, mb_wr_reset, mb_swap, mb_busy, mb_done;
	wire [15:0] mb_wr_pixel, mb_frames, mb_index;
	wire [7:0] mb_decode_error;
	wire mb_native_valid, mb_native_release;
	wire [31:0] mb_native_base;
	reg native_seen;
	reg native_copy_accepted = 1'b0;
	wire decoder_fault = decoder_header_error || mb_decode_error != 0;
	wire picture_fault = decoder_fault || codec_fault_pending;
	wire codec_fault_detected = ENABLE_AU_PROTOCOL && current_au_valid &&
		decoder_fault && !codec_fault_pending && !pipeline_reset;
	// Early SPS/PPS failure must still let the scanner retire this AU's VCL.
	// Feedback owns the same external fence used at NAL boundaries. Cancel an
	// existing copy immediately; otherwise acquire that fence only after parse.
	assign codec_error_valid = codec_fault_pending &&
		(native_copy_accepted || (au_scan_complete && !mb_busy));
	assign codec_error_pulse = codec_error_valid && !codec_fault_reported && !pipeline_reset;
	always @(posedge clk) begin
		if (pipeline_reset) begin
			codec_fault_pending <= 1'b0;
			codec_fault_reported <= 1'b0;
			codec_error_code <= 0;
		end else begin
			if (codec_fault_detected) begin
				codec_fault_pending <= 1'b1;
				codec_error_code <= mb_decode_error != 0 ? mb_decode_error : 8'd16;
			end
			if (codec_error_pulse) codec_fault_reported <= 1'b1;
		end
	end
	reg picture_pending;
	assign picture_valid = picture_pending && !picture_fault && !pipeline_reset;
	wire mb_geometry_valid;
	wire [15:0] mb_coded_width, mb_coded_height;
	wire [15:0] mb_crop_left, mb_crop_right, mb_crop_top, mb_crop_bottom;
	// One M10K-backed array: two 115200-byte I420 banks, not a power-of-two stride.
	localparam int DPB_PIC_N = 115200;
	localparam int DPB_N     = 230400;
	wire        dpb_mem_we, dpb_mem_rd;
	wire [31:0] dpb_mem_waddr, dpb_mem_raddr;
	wire [7:0]  dpb_mem_wdata;
	wire [7:0]  dpb_mem_rdata;
	reg         dpb_mem_rvalid;
	reg [7:0] picture_read_data;
	reg picture_read_hit_q;
	assign next_vcl_ready = !pipeline_reset && !mb_busy && !sl_rbsp_en && !sl_rbsp_end &&
		!sps_busy && !pps_busy && !sl_busy &&
		!dpb_read_pending && !dpb_mem_rvalid && !pub_read_pending &&
		!sps_cap_end && !pps_cap_end && !sl_cap_end &&
		(!ENABLE_PICTURE_PUBLISH || (!mb_native_valid && !native_copy_accepted &&
		 !picture_pending && fs_writes_idle));
	(* ramstyle = "M10K" *) reg [7:0] dpb_pic [0:DPB_N-1];
	wire        dpb_w_hit = dpb_mem_we && !pipeline_reset &&
	                       (dpb_mem_waddr < DPB_N[31:0]);
	// Retain the existing one-owned-read contract through the added address
	// stage; clients may accept another request alongside the prior response.
	wire dpb_mem_rready = !pipeline_reset && !dpb_read_pending && !pub_read_pending;
	wire dpb_read_accept = dpb_mem_rd && dpb_mem_rready;
	assign pub_mem_ready = ENABLE_PICTURE_PUBLISH && !dpb_mem_rd && dpb_mem_rready;
	wire pub_read = pub_mem_rd && pub_mem_ready && {14'd0, pub_mem_addr} < 32'(DPB_N);
	reg [31:0] picture_read_addr = 0;
	reg dpb_read_pending = 0, pub_read_pending = 0;
	wire picture_read_hit = pub_read_pending ||
		(dpb_read_pending && picture_read_addr < 32'(DPB_N));
	wire native_copy_retired = native_copy_accepted && !picture_pending &&
		fs_writes_idle && !pub_read && !pub_read_pending && !pub_mem_valid;
	assign mb_native_release = ENABLE_PICTURE_PUBLISH && native_copy_retired &&
		!picture_fault && !pipeline_reset;
	// A decoder clear cancels its DPB lease, not a publisher-owned RAM/DDR
	// transaction. Keep this external lease until real retirement, even on reset.
	always @(posedge clk) begin
		if (picture_valid && picture_ready)
			native_copy_accepted <= 1'b1;
		else if (native_copy_retired)
			native_copy_accepted <= 1'b0;
	end
	assign dpb_mem_rdata = picture_read_hit_q ? picture_read_data : 8'd0;
	assign pub_mem_data = picture_read_hit_q ? picture_read_data : 8'd0;
	// Keep the range-result mux after the registered RAM output for M10K inference.
	always @(posedge clk) begin
		if (dpb_w_hit)
			dpb_pic[dpb_mem_waddr[17:0]] <= dpb_mem_wdata;
		if (picture_read_hit)
			picture_read_data <= dpb_pic[picture_read_addr[17:0]];
	end
	always @(posedge clk) begin
		dpb_read_pending <= dpb_read_accept;
		pub_read_pending <= pub_read;
		if (dpb_read_accept || pub_read)
			picture_read_addr <= pub_read ? {14'd0, pub_mem_addr} : dpb_mem_raddr;
		dpb_mem_rvalid <= dpb_read_pending;
		pub_mem_valid <= pub_read_pending;
		if (dpb_read_pending || pub_read_pending)
			picture_read_hit_q <= picture_read_hit;
		if (pipeline_reset) begin
			picture_pending <= 1'b0;
			picture_bank <= 1'b0;
			picture_coded_width <= 0;
			picture_coded_height <= 0;
			picture_crop_left <= 0; picture_crop_right <= 0;
			picture_crop_top <= 0; picture_crop_bottom <= 0;
			native_seen <= 1'b0;
		end else begin
			if (vcl_pulse) native_seen <= 1'b0;
			if (picture_fault || (picture_valid && picture_ready))
				picture_pending <= 1'b0;
			if (ENABLE_PICTURE_PUBLISH && current_au_valid && !picture_fault &&
			    mb_geometry_valid && mb_native_valid && !native_seen) begin
				native_seen <= 1'b1;
				picture_bank <= (mb_native_base == DPB_PIC_N);
				picture_pending <= 1'b1;
				picture_coded_width <= mb_coded_width;
				picture_coded_height <= mb_coded_height;
				picture_crop_left <= mb_crop_left;
				picture_crop_right <= mb_crop_right;
				picture_crop_top <= mb_crop_top;
				picture_crop_bottom <= mb_crop_bottom;
			end
		end
	end

	// sl_rbsp_* = 8K VCL RBSP from nalu_scanner (confirmed >48B). sl_cap 48B
	// feeds either the bounded AU header or the legacy MB0 diagnostic parser.
	// mb_ctrl instantiates h264_bit_reader + h264_residual_seq on that RAM.
	h264_mb_ctrl #(
		.WIDTH(320),
		.HEIGHT(240),
		.RBSP_ADDR_W(13),
		.NATIVE_PUBLISH_LEASE(ENABLE_PICTURE_PUBLISH),
		.STATIC_IDR_ONLY(IDR_ONLY_PROFILE),
		.ENABLE_FRAME_DEBLOCK(ENABLE_FRAME_DEBLOCK),
		.SYNC_MB_PLANES(SYNC_MB_PLANES),
		.EXPLICIT_READ_READY(1'b1)
	) mb_ctrl (
		.clk(clk), .reset(pipeline_reset),
		.vcl_pulse(vcl_pulse),
		.sps_valid(sps_valid && (LEGACY_SLICE_DIAGNOSTIC || source_format_supported)),
		.mb_w(sps_mb_w),
		.mb_h(sps_mb_h),
		.picture_geometry_valid(sps_valid && (LEGACY_SLICE_DIAGNOSTIC || source_format_supported)),
		.picture_is_idr(sl_is_idr),
		.picture_nal_ref_idc(last_nal_type[6:5]),
		.picture_max_num_ref_frames(sps_max_num_ref_frames),
		.picture_idr_only(IDR_ONLY_PROFILE),
		.picture_crop_left(sps_crop_l), .picture_crop_right(sps_crop_r),
		.picture_crop_top(sps_crop_t), .picture_crop_bottom(sps_crop_b),
		.picture_sar_width(sps_sar_w), .picture_sar_height(sps_sar_h),
		.picture_sar_known(sps_sar_known),
		.slice_type(sl_type),
		.slice_is_i(sl_is_i),
		.slice_valid(slice_valid && (LEGACY_SLICE_DIAGNOSTIC || !decoder_header_error)),
		.slice_error(!LEGACY_SLICE_DIAGNOSTIC && decoder_header_error),
		.slice_qp(LEGACY_SLICE_DIAGNOSTIC ? sl_place_qp : sl_qp),
		.residual_ok(sl_place_ok),
		.residual_coeff(sl_place_coeff),
		.residual_place_pulse(place_pulse),
		.first_mb(sl_first),
		.first_mb_type(sl_mbt),
		.pps_nref(pps_nref),
		.pps_deblock(pps_deblock),
		.slice_disable_deblocking_filter_idc(sl_deblock_idc),
		.slice_alpha_c0_offset({sl_alpha_div2[3:0], 1'b0}),
		.slice_beta_offset({sl_beta_div2[3:0], 1'b0}),
		.pps_chroma_qp_index_offset(pps_chroma_qp_offset[5:0]),
		.pps_constrained_intra_pred(pps_constrained_intra),
		.video_full_range(sps_full_range), .video_matrix_coefficients(sps_matrix),
		.sl_rbsp_clear(sl_rbsp_clear),
		.sl_rbsp_en(sl_rbsp_en),
		.sl_rbsp_data(sl_rbsp_data),
		.sl_rbsp_end(sl_rbsp_end),
		.sl_rbsp_len(sl_rbsp_len),
		.bit_pos_hdr(sl_bit_pos_hdr),
		.bit_pos_resid(sl_bit_pos_resid),
		.bit_pos_valid(sl_bit_pos_valid && (LEGACY_SLICE_DIAGNOSTIC || !decoder_header_error)),
		.recon_sig(mb_recon_sig),
		.recon_dbg(mb_recon_dbg),
		.recon_dbg_valid(mb_recon_dbg_valid),
		.recon_valid(mb_recon_valid),
		.wr_ready(fs_wr_ready),
		.present_sel(fs_present_sel),
		.wr_en(mb_wr_en),
		.wr_pixel(mb_wr_pixel),
		.wr_reset_ptr(mb_wr_reset),
		.swap_req(mb_swap),
		.busy(mb_busy),
		.frames_out(mb_frames),
		.decode_error(mb_decode_error),
		.product_recon_ok(product_recon_ok),
		.mb_index(mb_index),
		.done(mb_done),
		.native_picture_release(mb_native_release),
		.native_picture_valid(mb_native_valid),
		.native_picture_base(mb_native_base),
		.present_meta_valid(mb_geometry_valid),
		.present_coded_width(mb_coded_width), .present_coded_height(mb_coded_height),
		.present_crop_left(mb_crop_left), .present_crop_right(mb_crop_right),
		.present_crop_top(mb_crop_top), .present_crop_bottom(mb_crop_bottom),
		.dpb_mem_we(dpb_mem_we),
		.dpb_mem_waddr(dpb_mem_waddr),
		.dpb_mem_wdata(dpb_mem_wdata),
		.dpb_mem_rd(dpb_mem_rd),
		.dpb_mem_raddr(dpb_mem_raddr),
		.dpb_mem_rdata(dpb_mem_rdata),
		.dpb_mem_rvalid(dpb_mem_rvalid),
		.dpb_mem_rready(dpb_mem_rready)
	);

	// Keep the base diagnostic status contract independent of decoder activity.
	// frames_out is the donor walker counter, not proof of color or publication.
	wire use_mb = mb_busy | mb_done | (mb_frames != 16'd0);
	assign residual_ok = sl_res_ok;
	assign residual_place_pulse = place_pulse;
	assign residual_csum        = place_csum;
	assign recon_sig       = stub_recon_sig;
	assign recon_dbg       = stub_recon_dbg;
	assign recon_dbg_valid = stub_recon_dbg_valid;
	assign recon_valid     = stub_recon_valid;
	assign frames_out      = mb_frames;  // walker GRID_DONE counter, not gated by use_mb
	// The diagnostic painter remains available only while the walker is idle.
	// Host/frame ownership is still enforced by Plex.sv, not by the gold latch.
	wire paint_mb = (mb_frames != 16'd0);
	assign fs_wr_en        = paint_mb ? mb_wr_en    : (!use_mb & stub_wr_en);
	assign fs_wr_pixel     = paint_mb ? mb_wr_pixel : stub_wr_pixel;
	assign fs_wr_reset     = paint_mb ? mb_wr_reset : (!use_mb & stub_wr_reset);
	assign fs_swap         = paint_mb ? mb_swap     : (!use_mb & stub_swap);
	assign stub_busy       = stub_busy_w;
	assign stub_frames     = stub_frames_w;

	// Only the accepted final encoded byte authorizes EOF. Transport gaps
	// cannot close a NAL; VCL storage and AU metadata retain separate ownership.
	wire pipeline_quiet = bf_rd_empty && !bf_rd_en && !si_wr_en &&
	                      !ddr_wr_en && !vcl_pulse &&
	                      !sps_busy && !pps_busy && !sl_busy &&
	                      !sps_cap_en && !sps_cap_end &&
	                      !pps_cap_en && !pps_cap_end &&
	                      !sl_cap_en && !sl_cap_end &&
	                      !sl_rbsp_en && !sl_rbsp_end &&
	                      !mb_busy && !stub_busy_w &&
	                      (!ENABLE_PICTURE_PUBLISH || (!mb_native_valid && !native_copy_accepted)) &&
	                      !dpb_mem_rd && !dpb_read_pending && !dpb_mem_rvalid &&
	                      !picture_valid && !pub_read && !pub_read_pending && !pub_mem_valid &&
	                      !fs_wr_en && !fs_wr_reset && !fs_swap;
	reg [4:0] quiet_cycles;
	always @(posedge clk) begin
		if (pipeline_reset || !pipeline_quiet)
			quiet_cycles <= 5'd0;
		else if (quiet_cycles != 5'd31)
			quiet_cycles <= quiet_cycles + 5'd1;
	end
	wire pipeline_drained = pipeline_quiet && (quiet_cycles == 5'd31) &&
	                        (!ENABLE_AU_PROTOCOL || scanner_idle) &&
	                        (!ENABLE_AU_PROTOCOL || fs_writes_idle);
	wire feedback_retired = !ENABLE_PICTURE_PUBLISH || !codec_fault_pending ||
	                        codec_error_committed;
	// All DPB writers, including the frame filter, retain mb_busy until
	// retirement. Do not put their redundant byte-write decode on this fence.
	// synthesis translate_off
	always @(posedge clk) if (!pipeline_reset && dpb_mem_we)
		assert (mb_busy) else $fatal(1, "DPB write escaped its busy owner");
	// synthesis translate_on
	assign decoder_idle = !current_au_valid && !au_collecting &&
	                      pipeline_drained && !pipeline_reset;
	// Reserve admission only after the real drain fence. No work can enter
	// an empty AU pipeline until this one-shot credit is consumed. Keep the
	// immediate reset/SPI/fault vetoes, but not the deep drain decode, on the
	// reader's metadata handshake and parser-mode feedback.
	reg au_admission_credit;
	always @(posedge clk) begin
		if (pipeline_reset || !ddr_selected || si_active || codec_fault_pending ||
		    (au_valid && au_ready))
			au_admission_credit <= 1'b0;
		else if (decoder_idle)
			au_admission_credit <= 1'b1;
	end
	assign au_ready = ENABLE_AU_PROTOCOL && ddr_selected && au_admission_credit &&
	                  !pipeline_reset &&
	                  !si_active && !codec_fault_pending;
	// synthesis translate_off
	always @(posedge clk) if (au_valid && au_ready)
		assert (decoder_idle) else $fatal(1, "AU credit escaped the actual drain fence");
	// synthesis translate_on

	always @(posedge clk) begin
		if (pipeline_reset) begin
			au_collecting <= 1'b0;
			au_bytes_complete <= 1'b0;
			au_scan_complete <= 1'b0;
			current_au_valid <= 1'b0;
			current_au_session_id <= 64'd0;
			current_au_seq <= 32'd0;
			current_au_pts <= 64'sd0;
			current_au_duration <= 64'sd0;
			current_au_timebase_num <= 32'd0;
			current_au_timebase_den <= 32'd0;
			current_au_flags <= 32'd0;
		end else begin
			if (au_valid && au_ready) begin
				au_collecting <= 1'b1;
				au_bytes_complete <= 1'b0;
				au_scan_complete <= 1'b0;
				current_au_valid <= 1'b1;
				current_au_session_id <= au_session_id;
				current_au_seq <= au_seq;
				current_au_pts <= au_pts;
				current_au_duration <= au_duration;
				current_au_timebase_num <= au_timebase_num;
				current_au_timebase_den <= au_timebase_den;
				current_au_flags <= au_flags;
			end
			if (scanner_au_done) au_scan_complete <= 1'b1;
			if (ENABLE_AU_PROTOCOL && ddr_byte_accept && ddr_wr_last) begin
				au_collecting <= 1'b0;
				au_bytes_complete <= 1'b1;
			end
			if (current_au_valid && au_scan_complete && pipeline_drained && feedback_retired) begin
				current_au_valid <= 1'b0;
				au_bytes_complete <= 1'b0;
			end
		end
	end

endmodule
