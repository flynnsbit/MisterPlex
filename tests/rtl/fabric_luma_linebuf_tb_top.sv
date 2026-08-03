`default_nettype none
module fabric_luma_linebuf_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        wr_en,
	input  wire [10:0] wr_addr,
	input  wire [7:0]  wr_data,
	input  wire        rd_en,
	input  wire [10:0] rd_addr,
	output wire [7:0]  rd_data,
	output wire        rd_valid
);
	fabric_luma_linebuf #(.LINE_BYTES(1280)) dut (
		.clk(clk), .reset(reset),
		.wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
		.rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid)
	);
endmodule
`default_nettype wire
