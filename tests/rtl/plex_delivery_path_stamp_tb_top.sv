`timescale 1ns / 1ps
// Single DUT; build twice: plain vs -DFABRIC_FRAME_DMA.
module plex_delivery_path_stamp_tb_top (
	input  wire clk,
	input  wire reset,
	output wire arm_copy_path,
	output wire fabric_dma_path,
	output wire [7:0] path_class,
	output wire stamp_alive
);
plex_delivery_path_stamp dut (
	.clk(clk),
	.reset(reset),
	.arm_copy_path(arm_copy_path),
	.fabric_dma_path(fabric_dma_path),
	.path_class(path_class),
	.stamp_alive(stamp_alive)
);
endmodule
