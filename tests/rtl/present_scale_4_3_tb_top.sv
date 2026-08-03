`default_nettype none

module present_scale_4_3_tb (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,
	input  wire [10:0] hc,
	input  wire [10:0] py,
	input  wire        in_content,
	output wire [10:0] store_x,
	output wire [10:0] store_y,
	output wire [10:0] store_x1,
	output wire [10:0] store_y1,
	output wire [1:0]  phase_x,
	output wire [1:0]  phase_y,
	output wire [8:0]  wx0,
	output wire [8:0]  wx1,
	output wire [8:0]  wy0,
	output wire [8:0]  wy1,
	output wire        de_r
);
	present_scale_4_3 dut (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix),
		.hc(hc),
		.py(py),
		.in_content(in_content),
		.store_x(store_x),
		.store_y(store_y),
		.store_x1(store_x1),
		.store_y1(store_y1),
		.phase_x(phase_x),
		.phase_y(phase_y),
		.wx0(wx0),
		.wx1(wx1),
		.wy0(wy0),
		.wy1(wy1),
		.de_r(de_r)
	);
endmodule

`default_nettype wire
