// Dual-clock line buffer RAM (M10K).
// Port A: write (wr_clk) + read (rd_clk) — product simple dual-port path.
// Port B: optional second read on rd_clk for multi-pixel Y qword+1 (straddle).
// Callers that do not need B tie rd_addr_b=0 and leave rd_data_b unused.
module line_buf_ram #(
	parameter int WIDTH = 320,
	parameter int AW = 9,
	parameter int DATA_W = 16
)(
	input  wire          wr_clk,
	input  wire          wr_en,
	input  wire [AW-1:0] wr_addr,
	input  wire [DATA_W-1:0] wr_data,

	input  wire          rd_clk,
	input  wire [AW-1:0] rd_addr,
	output reg  [DATA_W-1:0] rd_data,
	// Second read port (same rd_clk). Unused sites: tie addr 0.
	input  wire [AW-1:0] rd_addr_b,
	output reg  [DATA_W-1:0] rd_data_b
);
	(* ramstyle = "M10K" *) reg [DATA_W-1:0] mem [0:WIDTH-1];

	always @(posedge wr_clk) begin
		if (wr_en)
			mem[wr_addr] <= wr_data;
	end

	always @(posedge rd_clk) begin
		rd_data   <= mem[rd_addr];
		rd_data_b <= mem[rd_addr_b];
	end
endmodule
