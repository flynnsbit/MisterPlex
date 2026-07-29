// On-chip reference picture (or luma plane) for deterministic MC fetches.
// Single-clock simple dual-port M10K: write during post-frame DDR reload,
// registered read for ref_rd. Keeps the DDR DPB write path intact.
//
// Depth defaults to one 624x480 luma plane (299520). Full I420 is 449280.
// Do not dual-bank here: 2x full YUV exceeds device M10K; 2x luma is ~468
// blocks and does not fit beside the rest of the design (~205 blocks used).
module h264_dpb_bram_ref #(
	parameter int DEPTH = 299520,
	parameter int AW    = 19
)(
	input  wire             clk,
	input  wire             we,
	input  wire [AW-1:0]    waddr,
	input  wire [7:0]       wdata,
	input  wire [AW-1:0]    raddr,
	output reg  [7:0]       rdata
);
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem [0:DEPTH-1];

	always @(posedge clk) begin
		if (we)
			mem[waddr] <= wdata;
		rdata <= mem[raddr];
	end
endmodule
