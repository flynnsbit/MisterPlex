// Thin wrapper so Verilator can elaborate yuv_bt601_npx with PX_PER_CLK=2.
module yuv_bt601_npx_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        in_valid,
	input  wire [10:0] src_x0,
	input  wire [63:0] y_qword,
	input  wire [63:0] u_qword,
	input  wire [63:0] v_qword,
	input  wire [63:0] y_qword_hi,
	input  wire        y_hi_valid,
	output wire        out_valid,
	output wire [15:0] out_r,
	output wire [15:0] out_g,
	output wire [15:0] out_b,
	output wire [1:0]  out_lane_valid
);
	yuv_bt601_npx #(.PX_PER_CLK(2), .X_W(11)) u_dut (
		.clk(clk),
		.reset(reset),
		.in_valid(in_valid),
		.src_x0(src_x0),
		.y_qword(y_qword),
		.u_qword(u_qword),
		.v_qword(v_qword),
		.y_qword_hi(y_qword_hi),
		.y_hi_valid(y_hi_valid),
		.out_valid(out_valid),
		.out_r(out_r),
		.out_g(out_g),
		.out_b(out_b),
		.out_lane_valid(out_lane_valid)
	);
endmodule
