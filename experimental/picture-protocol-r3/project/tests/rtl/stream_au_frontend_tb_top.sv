module stream_au_frontend_tb #(
	parameter int RBSP_ADDR_W = 13
) (
	input wire clk,
	input wire reset,
	input wire push,
	input wire [7:0] byte_in,
	input wire au_end,
	input wire rbsp_release,
	input wire scan_hold,
	input wire [RBSP_ADDR_W-1:0] read_addr,
	output wire [7:0] read_data,
	output wire [RBSP_ADDR_W:0] length,
	output wire [RBSP_ADDR_W:0] reported_length,
	output wire fifo_full,
	output wire [15:0] fifo_level,
	output wire done,
	output wire overflow,
	output wire au_done,
	output wire idle,
	output wire [15:0] nalu_count,
	output wire [31:0] bytes_seen
);
	wire rd_en, empty;
	wire [7:0] data;
	bitstream_fifo #(.DEPTH(32768)) fifo (
		.clk(clk), .reset(reset), .wr_en(push), .wr_data(byte_in), .wr_flush(1'b0),
		.wr_full(fifo_full), .wr_level(fifo_level),
		.rd_en(rd_en && !scan_hold), .rd_data(data),
		.rd_empty(empty), .has_data()
	);
	wire rbsp_clear, rbsp_en, rbsp_end;
	wire [7:0] rbsp_data;
	nalu_scanner #(.ENABLE_AU_END(1'b1)) scanner (
		.clk(clk), .reset(reset), .rd_data(data), .rd_empty(empty || scan_hold), .rd_en(rd_en),
		.au_end(au_end), .rbsp_release(rbsp_release), .au_done(au_done), .idle(idle),
		.nalu_count(nalu_count), .bytes_seen(bytes_seen), .last_nal_type(),
		.has_stream(), .idr_count(), .sps_count(), .pps_count(), .slice_count(),
		.has_idr(), .vcl_pulse(), .sps_cap_clear(), .sps_cap_en(), .sps_cap_data(),
		.sps_cap_end(), .pps_cap_clear(), .pps_cap_en(), .pps_cap_data(), .pps_cap_end(),
		.sl_cap_clear(), .sl_cap_en(), .sl_cap_data(), .sl_cap_end(), .sl_is_idr(),
		.sl_rbsp_clear(rbsp_clear), .sl_rbsp_en(rbsp_en), .sl_rbsp_data(rbsp_data),
		.sl_rbsp_end(rbsp_end), .sl_rbsp_len(reported_length)
	);
	h264_slice_rbsp_ram #(.DEPTH(1 << RBSP_ADDR_W)) ram (
		.clk(clk), .reset(reset), .wr_clear(rbsp_clear), .wr_en(rbsp_en),
		.wr_data(rbsp_data), .wr_end(rbsp_end), .rd_addr(read_addr),
		.rd_data(read_data), .len(length), .done(done), .overflow(overflow)
	);
endmodule
