// Dual-geometry present path TB top — elaborates Template + L4 side-by-side.
`timescale 1ns / 1ps
`default_nettype none

module present_geom_dual_tb_top (
	// Template 640×480 (MODE=0)
	output wire [15:0] tpl_h_de,
	output wire [15:0] tpl_v,
	output wire [15:0] tpl_store_w,
	output wire [15:0] tpl_store_h,
	output wire [31:0] tpl_bank,
	output wire        tpl_is_529,
	// L4 1280×720 (MODE=1)
	output wire [15:0] l4_h_de,
	output wire [15:0] l4_v,
	output wire [15:0] l4_h_total,
	output wire [15:0] l4_v_total,
	output wire [15:0] l4_store_w,
	output wire [15:0] l4_store_h,
	output wire [31:0] l4_bank,
	output wire        l4_is_529,
	output wire        l4_native_de,
	// NEGATIVE twin: L4 with FAULT_L4_USE_TPL_H_DE — must report is_529=1
	output wire [15:0] bad_h_de,
	output wire        bad_is_529,
	output wire        bad_native_de
);
	present_geometry_derived #(
		.FRAME_W(640),
		.FRAME_H(480),
		.MODE(0),
		.FAULT_L4_USE_TPL_H_DE(1'b0)
	) u_tpl (
		.h_de(tpl_h_de),
		.v_store_or_act(tpl_v),
		.h_total(),
		.v_total(),
		.store_w(tpl_store_w),
		.store_h(tpl_store_h),
		.bank_stride_bytes(tpl_bank),
		.y_stride(),
		.chroma_stride(),
		.is_template_h_de_529(tpl_is_529),
		.is_l4_native_de()
	);

	present_geometry_derived #(
		.FRAME_W(1280),
		.FRAME_H(720),
		.MODE(1),
		.FAULT_L4_USE_TPL_H_DE(1'b0)
	) u_l4 (
		.h_de(l4_h_de),
		.v_store_or_act(l4_v),
		.h_total(l4_h_total),
		.v_total(l4_v_total),
		.store_w(l4_store_w),
		.store_h(l4_store_h),
		.bank_stride_bytes(l4_bank),
		.y_stride(),
		.chroma_stride(),
		.is_template_h_de_529(l4_is_529),
		.is_l4_native_de(l4_native_de)
	);

	// Wrong implementation twin: L4 still emits Template H_DE=529.
	present_geometry_derived #(
		.FRAME_W(1280),
		.FRAME_H(720),
		.MODE(1),
		.FAULT_L4_USE_TPL_H_DE(1'b1)
	) u_bad (
		.h_de(bad_h_de),
		.v_store_or_act(),
		.h_total(),
		.v_total(),
		.store_w(),
		.store_h(),
		.bank_stride_bytes(),
		.y_stride(),
		.chroma_stride(),
		.is_template_h_de_529(bad_is_529),
		.is_l4_native_de(bad_native_de)
	);
endmodule

`default_nettype wire
