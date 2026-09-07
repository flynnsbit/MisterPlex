module p2_chroma_pred_tb (
	input wire [1:0] mode,
	input wire [7:0] above [0:7], left [0:7],
	input wire [7:0] top_left,
	input wire has_above, has_left, block_x, block_y,
	output wire [7:0] full_pred [0:63],
	output wire [7:0] block_pred [0:15]
);
	h264_chroma8x8_pred u_full (
		.mode(mode), .above(above), .left(left), .top_left(top_left),
		.has_above(has_above), .has_left(has_left), .pred(full_pred)
	);
	h264_chroma_pred_region #(.SIDE(4)) u_block (
		.mode(mode), .above(above), .left(left), .top_left(top_left),
		.has_above(has_above), .has_left(has_left),
		.block_x(block_x), .block_y(block_y), .pred(block_pred)
	);
endmodule
