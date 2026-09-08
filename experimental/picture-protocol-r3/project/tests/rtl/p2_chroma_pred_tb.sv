module p2_chroma_pred_tb (
	input wire clk, reset, start,
	input wire [1:0] mode,
	input wire [7:0] above [0:7], left [0:7],
	input wire [7:0] top_left,
	input wire has_above, has_left, block_x, block_y,
	output wire [7:0] full_pred [0:63],
	output wire [7:0] block_pred [0:15],
	output wire full_busy, block_busy, full_done, block_done,
	output wire [7:0] full_pipe_pred [0:63],
	output wire [7:0] block_pipe_pred [0:15]
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
	h264_chroma_pred_region_pipe #(.SIDE(8)) u_full_pipe (
		.clk(clk), .reset(reset), .start(start), .busy(full_busy), .done(full_done),
		.mode(mode), .above(above), .left(left), .top_left(top_left),
		.has_above(has_above), .has_left(has_left),
		.block_x(block_x), .block_y(block_y), .pred(full_pipe_pred)
	);
	h264_chroma_pred_region_pipe #(.SIDE(4)) u_block_pipe (
		.clk(clk), .reset(reset), .start(start), .busy(block_busy), .done(block_done),
		.mode(mode), .above(above), .left(left), .top_left(top_left),
		.has_above(has_above), .has_left(has_left),
		.block_x(block_x), .block_y(block_y), .pred(block_pipe_pred)
	);
endmodule
