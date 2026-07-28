// Testbench wrapper for h264_ipcm_passthrough module.
module p3_ipcm_tb (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire        wr_valid,
	input  wire [7:0]  wr_data,
	output wire        done,
	output wire        busy,
	output wire [7:0]  luma_out [0:255],
	output wire [7:0]  cb_out [0:63],
	output wire [7:0]  cr_out [0:63]
);
	h264_ipcm_passthrough uut (
		.clk(clk),
		.reset(reset),
		.start(start),
		.wr_valid(wr_valid),
		.wr_data(wr_data),
		.done(done),
		.busy(busy),
		.luma_out(luma_out),
		.cb_out(cb_out),
		.cr_out(cr_out)
	);
endmodule
