// Phase 3.3 / 3.3b / 3.3c: F3 → bitstream_fifo → nalu_scanner → sps_parser + decode_stub.

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

	output wire        has_idr,
	output wire [7:0]  idr_count,
	output wire [7:0]  sps_count,
	output wire [7:0]  pps_count,
	output wire [7:0]  slice_count,
	output wire [15:0] stub_frames,
	output wire        stub_busy,

	// 3.3c SPS
	output wire        sps_valid,
	output wire [7:0]  sps_profile,
	output wire [7:0]  sps_level,
	output wire [15:0] sps_width,
	output wire [15:0] sps_height,

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
	wire        sps_cap_clear, sps_cap_en, sps_cap_end;
	wire [7:0]  sps_cap_data;

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
		.vcl_pulse(vcl_pulse),
		.sps_cap_clear(sps_cap_clear),
		.sps_cap_en(sps_cap_en),
		.sps_cap_data(sps_cap_data),
		.sps_cap_end(sps_cap_end)
	);

	assign has_idr     = has_idr_w;
	assign idr_count   = idr_c;
	assign sps_count   = sps_c;
	assign pps_count   = pps_c;
	assign slice_count = slc_c;

	wire sps_busy;

	sps_parser sps (
		.clk(clk),
		.reset(reset | flush),
		.cap_clear(sps_cap_clear),
		.cap_en(sps_cap_en),
		.cap_data(sps_cap_data),
		.cap_end(sps_cap_end),
		.valid(sps_valid),
		.profile_idc(sps_profile),
		.level_idc(sps_level),
		.width(sps_width),
		.height(sps_height),
		.busy(sps_busy)
	);

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

	(* keep = 1 *) wire keep_si = si_active;
	(* keep = 1 *) wire keep_bf = bf_has;
	wire _keep = keep_si | keep_bf | |fifo_level | |bytes_in | stub_busy | sps_busy;

endmodule
