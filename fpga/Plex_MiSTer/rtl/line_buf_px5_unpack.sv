// line_buf_px5_unpack — registered phase extract from a 2-word window.
//
// word0/word1 already registered. phase = pixel_x % 5 (0..4).
// PPC consecutive pixels; phase+PPC-1 may span into word1 (e.g. phase=4,PPC=2).
//
// One register stage on clk — no long comb from RAM dout to YUV math.
// M10K: 0. ALM EST ~30.

module line_buf_px5_unpack #(
	parameter int PPC = 2
)(
	input  wire             clk,
	input  wire             reset,
	input  wire             in_valid,
	input  wire [39:0]      word0,
	input  wire [39:0]      word1,
	input  wire [2:0]       phase,
	output reg              out_valid,
	output reg  [8*PPC-1:0] px_bytes
);
	wire [79:0] window = {word1, word0};
	integer i;
	reg [3:0] idx;

	always @(posedge clk) begin
		if (reset) begin
			out_valid <= 1'b0;
			px_bytes <= '0;
		end else begin
			out_valid <= in_valid;
			if (in_valid) begin
				for (i = 0; i < PPC; i = i + 1) begin
					idx = 4'(phase) + 4'(i);
					px_bytes[i*8 +: 8] <= window[idx*8 +: 8];
				end
			end
		end
	end
endmodule
