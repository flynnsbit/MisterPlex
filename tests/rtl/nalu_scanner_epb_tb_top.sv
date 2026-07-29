// Minimal product-path EPB proof: nalu_scanner must strip 00 00 03 on SPS/PPS/VCL taps.
// Uses product bitstream_fifo read contract (registered rd_data).
// NOT part of the Quartus project.
`default_nettype none

module nalu_scanner_epb_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        wr_en,
	input  wire [7:0]  wr_data,
	input  wire        wr_flush,
	output wire        wr_full,
	output wire [15:0] wr_level,
	output wire [15:0] nalu_count,
	output wire [7:0]  last_nal_type,
	output wire [7:0]  idr_count,
	output wire [7:0]  sps_count,
	output wire [7:0]  slice_count,
	output wire        vcl_cap_clear,
	output wire        vcl_cap_en,
	output wire [7:0]  vcl_cap_data,
	output wire        vcl_cap_end,
	output wire        sps_cap_clear,
	output wire        sps_cap_en,
	output wire [7:0]  sps_cap_data,
	output wire        sps_cap_end,
	output wire        pps_cap_clear,
	output wire        pps_cap_en,
	output wire [7:0]  pps_cap_data,
	output wire        pps_cap_end
);
	wire [7:0] rd_data;
	wire       rd_empty;
	wire       rd_en;
	wire       has_data;
	wire       has_stream;
	wire [31:0] bytes_seen;
	wire [7:0] pps_count;
	wire       has_idr, vcl_pulse;
	wire       sl_cap_clear, sl_cap_en, sl_cap_end, sl_is_idr, sl_nal_ref_idc_nonzero;
	wire [7:0] sl_cap_data;

	bitstream_fifo #(.DEPTH(4096)) fifo (
		.clk(clk), .reset(reset),
		.wr_en(wr_en), .wr_data(wr_data), .wr_flush(wr_flush),
		.wr_full(wr_full), .wr_level(wr_level),
		.rd_en(rd_en), .rd_data(rd_data), .rd_empty(rd_empty), .has_data(has_data)
	);

	nalu_scanner dut (
		.clk(clk), .reset(reset),
		.rd_data(rd_data), .rd_empty(rd_empty), .rd_en(rd_en),
		.nalu_count(nalu_count), .last_nal_type(last_nal_type),
		.has_stream(has_stream), .bytes_seen(bytes_seen),
		.idr_count(idr_count), .sps_count(sps_count), .pps_count(pps_count),
		.slice_count(slice_count), .has_idr(has_idr), .vcl_pulse(vcl_pulse),
		.sps_cap_clear(sps_cap_clear), .sps_cap_en(sps_cap_en),
		.sps_cap_data(sps_cap_data), .sps_cap_end(sps_cap_end),
		.pps_cap_clear(pps_cap_clear), .pps_cap_en(pps_cap_en),
		.pps_cap_data(pps_cap_data), .pps_cap_end(pps_cap_end),
		.sl_cap_clear(sl_cap_clear), .sl_cap_en(sl_cap_en),
		.sl_cap_data(sl_cap_data), .sl_cap_end(sl_cap_end),
		.sl_is_idr(sl_is_idr), .sl_nal_ref_idc_nonzero(sl_nal_ref_idc_nonzero),
		.vcl_cap_clear(vcl_cap_clear), .vcl_cap_en(vcl_cap_en),
		.vcl_cap_data(vcl_cap_data), .vcl_cap_end(vcl_cap_end)
	);
endmodule

`default_nettype wire
