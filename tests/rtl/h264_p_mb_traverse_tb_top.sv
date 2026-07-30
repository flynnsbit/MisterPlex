// Testbench-only wrapper for h264_p_mb_traverse product RTL.
// Streams RBSP bytes, pulses start, and exposes MB event / count / done.
// FAULT_* parameters select mutation twins (recompiled separately).
`default_nettype none

module h264_p_mb_traverse_tb_top #(
	parameter bit FAULT_BAD_SKIP_RUN = 1'b0,
	parameter bit FAULT_DROP_LAST_ROW_MB = 1'b0,
	parameter bit FAULT_FORCE_ZERO_MVD = 1'b0
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        clear,
	input  wire        in_valid,
	input  wire [7:0]  in_byte,
	input  wire        in_last,
	output wire        in_ready,
	input  wire        start,
	input  wire [7:0]  mb_width,
	input  wire [7:0]  mb_height,
	input  wire        mb_ready,
	output wire        mb_valid,
	output wire [15:0] mb_addr,
	output wire [7:0]  mb_x,
	output wire [7:0]  mb_y,
	output wire        mb_skip,
	output wire [2:0]  part_mode,
	output wire        is_intra,
	output wire [15:0] mb_count,
	output wire signed [15:0] mvd_x,
	output wire signed [15:0] mvd_y,
	output wire        mvd_valid,
	output wire        slice_done,
	output wire        busy,
	output wire        error,
	output wire        unsupported
);
	wire [7:0] mb_type_w;
	wire [2:0] part_count_w;
	wire uses_sub_w;
	wire [5:0] cbp_w;
	wire signed [7:0] mb_qp_w;
	wire [15:0] res_off_w;

	h264_p_mb_traverse #(
		.MAX_RBSP_BYTES(1024),
		.FAULT_BAD_SKIP_RUN(FAULT_BAD_SKIP_RUN),
		.FAULT_DROP_LAST_ROW_MB(FAULT_DROP_LAST_ROW_MB),
		.FAULT_FORCE_ZERO_MVD(FAULT_FORCE_ZERO_MVD)
	) dut (
		.clk(clk),
		.reset(reset),
		.clear(clear),
		.in_valid(in_valid),
		.in_byte(in_byte),
		.in_last(in_last),
		.in_ready(in_ready),
		.start(start),
		.mb_width(mb_width),
		.mb_height(mb_height),
		.log2_max_frame_num(5'd4),
		.poc_type(3'd0),
		.is_idr_nal(1'b0),
		.nal_ref_idc_nonzero(1'b0),
		.pps_deblock_ctrl(1'b0),
		.pps_pic_init_qp(8'sd26),
		.num_ref_idx_l0_active_minus1(3'd0),
		.mb_valid(mb_valid),
		.mb_ready(mb_ready),
		.mb_addr(mb_addr),
		.mb_x(mb_x),
		.mb_y(mb_y),
		.mb_skip(mb_skip),
		.mb_type(mb_type_w),
		.part_mode(part_mode),
		.part_count(part_count_w),
		.uses_sub_mb(uses_sub_w),
		.is_intra(is_intra),
		.cbp(cbp_w),
		.mb_qp(mb_qp_w),
		.residual_bit_offset(res_off_w),
		.mvd_x(mvd_x),
		.mvd_y(mvd_y),
		.mvd_valid(mvd_valid),
		.mb_count(mb_count),
		.slice_done(slice_done),
		.busy(busy),
		.error(error),
		.unsupported(unsupported)
	);
endmodule

`default_nettype wire
