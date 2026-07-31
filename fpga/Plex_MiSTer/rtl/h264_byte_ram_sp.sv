// h264_byte_ram_sp — single-port byte RAM, one registered read per cycle.
//
// Purpose: force an access pattern Quartus can map to M10K. Attributes alone
// do NOT guarantee inference when the parent does multi-index dynamic reads
// (map2d showed 8k:1 / 16k:1 res_win mux trees at ~1.18M comb ALUTs on the
// old combo rbsp[]). This module has exactly:
//   - one write port (we/waddr/wdata)
//   - one read address (raddr) → registered q next cycle
// No async read, no multi-port, no function-indexed access.
//
// Pattern matches h264_mc_luma_qpel winram (318k → ~484 ALMs after serial).

`default_nettype none

module h264_byte_ram_sp #(
	parameter int DEPTH = 16384,
	parameter int AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
	input  wire             clk,
	input  wire             we,
	input  wire [AW-1:0]    waddr,
	input  wire [7:0]       wdata,
	input  wire [AW-1:0]    raddr,
	output reg  [7:0]       q
);
	(* ramstyle = "M10K, no_rw_check" *)
	reg [7:0] mem [0:DEPTH-1];

	always @(posedge clk) begin
		if (we)
			mem[waddr] <= wdata;
		q <= mem[raddr];
	end
endmodule

`default_nettype wire
