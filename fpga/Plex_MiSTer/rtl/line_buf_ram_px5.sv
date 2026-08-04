// line_buf_ram_px5 — M10K line buffer @ 40-bit words (5×8-bit pixels).
//
// Legal Cyclone V target: **256 × 40** = 10_240 bits = **1 M10K**.
// 1280-px luma = 256 words → 1 M10K (vs 2 for naive 1K×8 byte lines).
// 640-px chroma = 128 words in 256×40 (50% util) → 1 M10K.
//
// Word port is 5-pixel granular. Use line_buf_px5_pack / line_buf_px5_stream_rd.

module line_buf_ram_px5 #(
	parameter int DEPTH = 256,
	parameter int AW    = 8
)(
	input  wire          wr_clk,
	input  wire          wr_en,
	input  wire [AW-1:0] wr_addr,
	input  wire [39:0]   wr_data,
	input  wire          rd_clk,
	input  wire [AW-1:0] rd_addr,
	output reg  [39:0]   rd_data
);
	(* ramstyle = "M10K" *) reg [39:0] mem [0:DEPTH-1];

	always @(posedge wr_clk) begin
		if (wr_en)
			mem[wr_addr] <= wr_data;
	end

	always @(posedge rd_clk) begin
		rd_data <= mem[rd_addr];
	end
endmodule
