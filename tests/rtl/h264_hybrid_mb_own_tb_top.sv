// Testbench-only wrapper for h264_hybrid_mb_own product RTL.
`default_nettype none

module h264_hybrid_mb_own_tb_top #(
	parameter bit FAULT_CLAIM_INTER = 1'b0
) (
	input  wire        slice_is_i,
	input  wire        entropy_cabac,
	input  wire        fail_mb,
	input  wire        mb_valid,
	input  wire [7:0]  mb_type,
	input  wire        is_p_slice_mb,
	input  wire        p_skipped,
	input  wire        p_is_intra,
	input  wire        p_is_inter,
	input  wire        p_uses_sub_mb,
	input  wire [2:0]  p_part_mode,
	input  wire        p_unsupported,
	output wire        fpga_owned,
	output wire        host_required,
	output wire        product_mb_ok,
	output wire [2:0]  own_code,
	output wire [3:0]  own_reason
);
	wire raw_fpga;
	wire raw_host;
	wire raw_ok;
	wire [2:0] raw_code;
	wire [3:0] raw_reason;

	h264_hybrid_mb_own dut (
		.slice_is_i(slice_is_i),
		.entropy_cabac(entropy_cabac),
		.fail_mb(fail_mb),
		.mb_valid(mb_valid),
		.mb_type(mb_type),
		.is_p_slice_mb(is_p_slice_mb),
		.p_skipped(p_skipped),
		.p_is_intra(p_is_intra),
		.p_is_inter(p_is_inter),
		.p_uses_sub_mb(p_uses_sub_mb),
		.p_part_mode(p_part_mode),
		.p_unsupported(p_unsupported),
		.fpga_owned(raw_fpga),
		.host_required(raw_host),
		.product_mb_ok(raw_ok),
		.own_code(raw_code),
		.own_reason(raw_reason)
	);

	// Mutation: silently claim inter MBs as FPGA-owned (must fail the gate).
	wire claim = FAULT_CLAIM_INTER && is_p_slice_mb && (p_is_inter || p_skipped);
	assign fpga_owned    = claim ? 1'b1 : raw_fpga;
	assign host_required = claim ? 1'b0 : raw_host;
	assign product_mb_ok = claim ? 1'b1 : raw_ok;
	assign own_code      = claim ? 3'd0 : raw_code;
	assign own_reason    = claim ? 4'd2 : raw_reason;
endmodule

`default_nettype wire
