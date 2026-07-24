// Phase 3.3: F3 elementary stream → bitstream_fifo → nalu_scanner.

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
	output wire [15:0] fifo_level
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

	nalu_scanner scan (
		.clk(clk),
		.reset(reset | flush),
		.rd_data(bf_rd_data),
		.rd_empty(bf_rd_empty),
		.rd_en(bf_rd_en),
		.nalu_count(nalu_count),
		.last_nal_type(last_nal_type),
		.has_stream(has_stream),
		.bytes_seen(bytes_seen)
	);

	// Keep ingest/FIFO status from being optimized away
	(* keep = 1 *) wire keep_si = si_active;
	(* keep = 1 *) wire keep_bf = bf_has;
	wire _keep = keep_si | keep_bf | |fifo_level | |bytes_in;

endmodule
