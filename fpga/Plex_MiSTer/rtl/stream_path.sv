// Phase 3.3 / 3.3b: F3 elementary stream → bitstream_fifo → nalu_scanner → decode_stub.
// decode_stub paints frame_store on each VCL NAL until real H.264 IP lands.

module stream_path (
	input  wire        clk,
	input  wire        reset,

	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [7:0]  ioctl_dout,
	input  wire        enable,
	input  wire        flush,

	output wire        has_stream,
	output wire [15:0] nalu_count,
	output wire [7:0]  last_nal_type,
	output wire [31:0] bytes_in,
	output wire [31:0] bytes_seen,
	output wire [15:0] fifo_level,

	// 3.3b typed / decode-stub status
	output wire        has_idr,
	output wire [7:0]  idr_count,
	output wire [7:0]  sps_count,
	output wire [7:0]  pps_count,
	output wire [7:0]  slice_count,
	output wire [15:0] stub_frames,
	output wire        stub_busy,

	// frame_store write (muxed with F1 ingest at top)
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
		.clk(clk),
		.reset(reset),
		.ioctl_download(ioctl_download),
		.ioctl_wr(ioctl_wr),
		.ioctl_dout(ioctl_dout),
		.enable(enable),
		.wr_en(si_wr_en),
		.wr_data(si_wr_data),
		.wr_flush(si_wr_flush),
		.active(si_active),
		.bytes_in(bytes_in)
	);

	wire        bf_rd_en;
	wire [7:0]  bf_rd_data;
	wire        bf_rd_empty;
	wire        bf_has;

	bitstream_fifo #(
		.DEPTH(32768)
	) bfifo (
		.clk(clk),
		.reset(reset),
		.wr_en(si_wr_en),
		.wr_data(si_wr_data),
		.wr_flush(si_wr_flush | flush),
		.wr_full(),
		.wr_level(fifo_level),
		.rd_en(bf_rd_en),
		.rd_data(bf_rd_data),
		.rd_empty(bf_rd_empty),
		.has_data(bf_has)
	);

	wire        vcl_pulse;
	wire [7:0]  idr_c, sps_c, pps_c, slc_c;
	wire        has_idr_w;

	nalu_scanner scan (
		.clk(clk),
		.reset(reset | flush),
		.rd_data(bf_rd_data),
		.rd_empty(bf_rd_empty),
		.rd_en(bf_rd_en),
		.nalu_count(nalu_count),
		.last_nal_type(last_nal_type),
		.has_stream(has_stream),
		.bytes_seen(bytes_seen),
		.idr_count(idr_c),
		.sps_count(sps_c),
		.pps_count(pps_c),
		.slice_count(slc_c),
		.has_idr(has_idr_w),
		.vcl_pulse(vcl_pulse)
	);

	assign has_idr     = has_idr_w;
	assign idr_count   = idr_c;
	assign sps_count   = sps_c;
	assign pps_count   = pps_c;
	assign slice_count = slc_c;

	decode_stub #(
		.WIDTH(320),
		.HEIGHT(240)
	) stub (
		.clk(clk),
		.reset(reset | flush),
		.vcl_pulse(vcl_pulse),
		.last_nal_type(last_nal_type),
		.nalu_count(nalu_count),
		.idr_count(idr_c),
		.has_idr(has_idr_w),
		.wr_en(fs_wr_en),
		.wr_pixel(fs_wr_pixel),
		.wr_reset_ptr(fs_wr_reset),
		.swap_req(fs_swap),
		.busy(stub_busy),
		.frames_out(stub_frames)
	);

	// Keep ingest/FIFO status from being optimized away
	(* keep = 1 *) wire keep_si = si_active;
	(* keep = 1 *) wire keep_bf = bf_has;
	wire _keep = keep_si | keep_bf | |fifo_level | |bytes_in | stub_busy;

endmodule
