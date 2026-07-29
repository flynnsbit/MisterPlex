// Single-clock simple dual-port sample RAM (M10K).
// One write port + registered read. No async read, no mem reset.
module mb_sample_ram #(
	parameter int DEPTH  = 256,
	parameter int AW     = 8,
	parameter int DATA_W = 8
)(
	input  wire                 clk,
	input  wire                 we,
	input  wire [AW-1:0]        waddr,
	input  wire [DATA_W-1:0]    wdata,
	input  wire [AW-1:0]        raddr,
	output reg  [DATA_W-1:0]    rdata
);
	(* ramstyle = "M10K, no_rw_check" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

	always @(posedge clk) begin
		if (we)
			mem[waddr] <= wdata;
		rdata <= mem[raddr];
	end
endmodule
