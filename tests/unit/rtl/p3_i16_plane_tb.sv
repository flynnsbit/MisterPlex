// Testbench wrapper for Intra 16x16 prediction verification.
// Collects serial h264_intra16x16_pred stream into pred[0:255] + valid.
module p3_i16_plane_tb (
	input  wire        clk,
	input  wire        start,
	input  wire [1:0]  mode,
	input  wire [7:0]  above [0:15],
	input  wire [7:0]  left [0:15],
	input  wire [7:0]  top_left,
	input  wire        has_above,
	input  wire        has_left,
	output wire        unsupported,
	output reg         valid,
	output reg  [7:0]  pred [0:255]
);
	wire busy, done, px_valid;
	wire [7:0] px_addr, px_data;
	integer i;

	h264_intra16x16_pred uut (
		.clk(clk),
		.reset(1'b0),
		.start(start),
		.mode(mode),
		.above(above),
		.left(left),
		.top_left(top_left),
		.has_above(has_above),
		.has_left(has_left),
		.unsupported(unsupported),
		.busy(busy),
		.done(done),
		.px_valid(px_valid),
		.px_addr(px_addr),
		.px_data(px_data)
	);

	always @(posedge clk) begin
		valid <= 1'b0;
		if (start) begin
			for (i = 0; i < 256; i = i + 1)
				pred[i] <= 8'd128;
		end
		if (px_valid)
			pred[px_addr] <= px_data;
		if (done)
			valid <= 1'b1;
	end
endmodule
