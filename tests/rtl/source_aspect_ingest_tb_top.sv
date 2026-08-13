`timescale 1ns/1ps

module source_aspect_ingest_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [7:0]  ioctl_dout,
	input  wire [26:0] ioctl_addr,
	input  wire        enable,
	output wire        aspect_valid,
	output wire [11:0] aspect_x,
	output wire [11:0] aspect_y,
	output wire  [7:0] aspect_token,
	output wire        aspect_commit
);
	source_aspect_ingest dut (
		.clk(clk),
		.reset(reset),
		.ioctl_download(ioctl_download),
		.ioctl_wr(ioctl_wr),
		.ioctl_dout(ioctl_dout),
		.ioctl_addr(ioctl_addr),
		.enable(enable),
		.aspect_valid(aspect_valid),
		.aspect_x(aspect_x),
		.aspect_y(aspect_y),
		.aspect_token(aspect_token),
		.aspect_commit(aspect_commit)
	);
endmodule
