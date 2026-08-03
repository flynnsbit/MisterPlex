// present_geometry_derived — pure-parameter present-path geometry table
//
// Instantiated by tests/rtl/present_geom_dual_tb at BOTH:
//   MODE=0  Template/FBAR default (product v0.3.0)  FRAME 640×480
//   MODE=1  L4 720p content path                     FRAME 1280×720
//
// Purpose: one module, two elaborations. A leftover 480p-era hardcode on the
// L4 path (e.g. H_DE still 529) must make MODE=1 assertions go RED.
//
// Product Plex.sv does NOT instantiate this — simulation / unit gate only.
// Do not add to files.qip (Quartus product netlist unchanged).

`timescale 1ns / 1ps
`default_nettype none

module present_geometry_derived #(
	parameter int FRAME_W = 640,
	parameter int FRAME_H = 480,
	// 0 = Template FBAR path (H_DE=529, V_STORE=240, bank 512 KiB)
	// 1 = L4 720p content path (H_DE=1280, V_ACT=720, bank 1.5 MiB)
	parameter int MODE = 0,
	// Fault inject for NEGATIVE case (testbench only): force Template H_DE on L4.
	parameter bit FAULT_L4_USE_TPL_H_DE = 1'b0
)(
	output wire [15:0] h_de,
	output wire [15:0] v_store_or_act,
	output wire [15:0] h_total,
	output wire [15:0] v_total,
	output wire [15:0] store_w,
	output wire [15:0] store_h,
	output wire [31:0] bank_stride_bytes,
	output wire [15:0] y_stride,
	output wire [15:0] chroma_stride,
	output wire        is_template_h_de_529,
	output wire        is_l4_native_de
);
	// ---- Template / FBAR (product default) — fixed colorbars DE, not FRAME_* ----
	localparam int TPL_H_DE     = 529;
	localparam int TPL_V_STORE  = 240;
	localparam int TPL_H_TOTAL  = 0; // Template beam is colorbars-owned; not claimed here
	localparam int TPL_V_TOTAL  = 0;
	localparam int TPL_BANK     = 32'h0008_0000; // 512 KiB — matches ddr_frame_layout

	// ---- L4 720p content (w-clock beam kit H=1312 V=762) ----
	// Content DE tracks FRAME when QSF sets FRAME_W=1280 FRAME_H=720.
	localparam int L4_H_DE      = 1280;
	localparam int L4_V_ACT     = 720;
	localparam int L4_H_TOTAL   = 1312;
	localparam int L4_V_TOTAL   = 762;
	localparam int L4_BANK      = 32'h0018_0000; // 1.5 MiB — I420 1280×720 fits

	wire l4 = (MODE == 1);

	// Store domain ALWAYS tracks FRAME_* so QSF 1280×720 cannot disagree.
	assign store_w = 16'(FRAME_W);
	assign store_h = 16'(FRAME_H);

	// L4 DE: either native 1280 or FAULT inject of Template 529 (negative twin).
	wire [15:0] l4_h_de_nom = 16'(L4_H_DE);
	wire [15:0] l4_h_de =
		FAULT_L4_USE_TPL_H_DE ? 16'(TPL_H_DE) : l4_h_de_nom;

	assign h_de = l4 ? l4_h_de : 16'(TPL_H_DE);
	assign v_store_or_act = l4 ? 16'(L4_V_ACT) : 16'(TPL_V_STORE);
	assign h_total = l4 ? 16'(L4_H_TOTAL) : 16'(TPL_H_TOTAL);
	assign v_total = l4 ? 16'(L4_V_TOTAL) : 16'(TPL_V_TOTAL);
	assign bank_stride_bytes = l4 ? 32'(L4_BANK) : 32'(TPL_BANK);
	assign y_stride = l4 ? 16'(FRAME_W) : 16'(FRAME_W); // both: Y stride = FRAME_W
	assign chroma_stride = l4 ? 16'(FRAME_W / 2) : 16'(FRAME_W / 2);

	assign is_template_h_de_529 = (h_de == 16'(TPL_H_DE));
	assign is_l4_native_de =
		l4 && (h_de == 16'(L4_H_DE)) && (v_store_or_act == 16'(L4_V_ACT));
endmodule

`default_nettype wire
