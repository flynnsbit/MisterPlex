// Testbench wrapper for h264_mc_interp v2 — instantiates product RTL with
// optional fault injection for red-before-green verification.
`default_nettype none

module h264_mc_interp_tb #(
	parameter FAULT_BAD_LUMA_ROUND  = 0,  // corrupt luma rounding (+1 to output)
	parameter FAULT_BAD_CHROMA_WEIGHT = 0  // corrupt chroma weights (XOR)
) (
	input  wire        clk,
	input  wire        rst_n,

	input  wire        cmd_valid,
	output wire        cmd_ready,
	input  wire        cmd_is_chroma,
	input  wire [1:0]  cmd_frac_x,
	input  wire [1:0]  cmd_frac_y,
	input  wire [2:0]  cmd_chroma_dx,
	input  wire [2:0]  cmd_chroma_dy,
	input  wire [4:0]  cmd_blk_w,
	input  wire [4:0]  cmd_blk_h,
	input  wire signed [15:0] cmd_ref_x,
	input  wire signed [15:0] cmd_ref_y,

	input  wire        ref_valid,
	output wire        ref_ready,
	input  wire [63:0] ref_data,
	input  wire [3:0]  ref_byte_count,

	output wire        pred_valid,
	input  wire        pred_ready,
	output wire [7:0]  pred_sample0_out,
	output wire [7:0]  pred_sample1_out,
	output wire        pred_pair,
	output wire        pred_last,

	output wire [15:0] cycle_count
);

	wire [7:0] pred_sample0_raw;
	wire [7:0] pred_sample1_raw;

	h264_mc_interp u_dut (
		.clk(clk),
		.rst_n(rst_n),
		.cmd_valid(cmd_valid),
		.cmd_ready(cmd_ready),
		.cmd_is_chroma(cmd_is_chroma),
		.cmd_frac_x(cmd_frac_x),
		.cmd_frac_y(cmd_frac_y),
		.cmd_chroma_dx(cmd_chroma_dx),
		.cmd_chroma_dy(cmd_chroma_dy),
		.cmd_blk_w(cmd_blk_w),
		.cmd_blk_h(cmd_blk_h),
		.cmd_ref_x(cmd_ref_x),
		.cmd_ref_y(cmd_ref_y),
		.ref_valid(ref_valid),
		.ref_ready(ref_ready),
		.ref_data(ref_data),
		.ref_byte_count(ref_byte_count),
		.pred_valid(pred_valid),
		.pred_ready(pred_ready),
		.pred_sample0(pred_sample0_raw),
		.pred_sample1(pred_sample1_raw),
		.pred_pair(pred_pair),
		.pred_last(pred_last),
		.cycle_count(cycle_count)
	);

	// Fault injection for red-before-green checks
	generate
		if (FAULT_BAD_LUMA_ROUND) begin : gen_luma_fault
			assign pred_sample0_out = cmd_is_chroma ? pred_sample0_raw
			                                        : (pred_sample0_raw + 8'd1);
			assign pred_sample1_out = cmd_is_chroma ? pred_sample1_raw
			                                        : (pred_sample1_raw + 8'd1);
		end else if (FAULT_BAD_CHROMA_WEIGHT) begin : gen_chroma_fault
			assign pred_sample0_out = cmd_is_chroma ? (pred_sample0_raw ^ 8'd3)
			                                        : pred_sample0_raw;
			assign pred_sample1_out = cmd_is_chroma ? (pred_sample1_raw ^ 8'd3)
			                                        : pred_sample1_raw;
		end else begin : gen_no_fault
			assign pred_sample0_out = pred_sample0_raw;
			assign pred_sample1_out = pred_sample1_raw;
		end
	endgenerate

endmodule

`default_nettype wire
