// Testbench-only top level. NOT part of the Quartus project and never synthesised.
//
// Drives the real product modules in fpga/Plex_MiSTer/rtl/h264_intra16_dc.sv and
// cross-checks their DC output against the DC path already shipping inside
// h264_intra_pred.sv, so the two implementations cannot drift apart.
`default_nettype none

module h264_intra16_dc_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [7:0]  above [0:15],
	input  wire [7:0]  left [0:15],
	input  wire [7:0]  c_above [0:7],
	input  wire [7:0]  c_left [0:7],
	input  wire        has_above,
	input  wire        has_left,

	output wire        luma_valid,
	output wire [7:0]  luma_dc,
	output wire [7:0]  luma_pred [0:255],
	output wire        chroma_valid,
	output wire [7:0]  chroma_dc_tl,
	output wire [7:0]  chroma_dc_tr,
	output wire [7:0]  chroma_dc_bl,
	output wire [7:0]  chroma_dc_br,
	output wire [7:0]  chroma_pred [0:63],

	output wire        ref_luma_valid,
	output wire [7:0]  ref_luma_pred [0:255],
	output wire        ref_chroma_valid,
	output wire [7:0]  ref_chroma_pred [0:63]
);
	h264_intra16_dc u_luma_dc (
		.clk(clk),
		.reset(reset),
		.start(start),
		.above(above),
		.left(left),
		.has_above(has_above),
		.has_left(has_left),
		.valid(luma_valid),
		.dc_value(luma_dc),
		.pred(luma_pred)
	);

	h264_chroma8_dc u_chroma_dc (
		.clk(clk),
		.reset(reset),
		.start(start),
		.above(c_above),
		.left(c_left),
		.has_above(has_above),
		.has_left(has_left),
		.valid(chroma_valid),
		.dc_tl(chroma_dc_tl),
		.dc_tr(chroma_dc_tr),
		.dc_bl(chroma_dc_bl),
		.dc_br(chroma_dc_br),
		.pred(chroma_pred)
	);

	wire ref_unsupported;
	h264_intra16x16_pred u_ref_luma (
		.clk(clk),
		.start(start),
		.mode(2'd2),
		.above(above),
		.left(left),
		.top_left(8'd0),
		.has_above(has_above),
		.has_left(has_left),
		.unsupported(ref_unsupported),
		.valid(ref_luma_valid),
		.pred(ref_luma_pred)
	);

	h264_chroma8x8_pred u_ref_chroma (
		.clk(clk),
		.start(start),
		.mode(2'd0),
		.above(c_above),
		.left(c_left),
		.top_left(8'd0),
		.has_above(has_above),
		.has_left(has_left),
		.valid(ref_chroma_valid),
		.pred(ref_chroma_pred)
	);
endmodule

`default_nettype wire
