// Parameterized WIDTH line buffer RAM (M10K).
//
// Dual-clock simple dual-port by default (1 write + 1 read) — one M10K bank.
//
// DUAL_RD=1: second independent read port on rd_clk (needed by ddr_frame_store
// multi-pixel qword-straddle path: y_rd_addr + y_rd_addr_hi). Implemented as a
// second physical bank written in lockstep — honest M10K cost ≈ 2×. Do NOT claim
// single-M10K true dual-read under mixed wr_clk/rd_clk without measuring fit.
//
// DUAL_RD=0 (default): rd_addr_b ignored, rd_data_b driven 0. frame_store stays
// single-port; ports exist so instances compile when connected.
module line_buf_ram #(
	parameter int WIDTH   = 320,
	parameter int AW      = 9,
	parameter int DATA_W  = 16,
	parameter bit DUAL_RD = 1'b0
)(
	input  wire              wr_clk,
	input  wire              wr_en,
	input  wire [AW-1:0]     wr_addr,
	input  wire [DATA_W-1:0] wr_data,

	input  wire              rd_clk,
	input  wire [AW-1:0]     rd_addr,
	output reg  [DATA_W-1:0] rd_data,
	// Optional second read (same rd_clk). Tie rd_addr_b=0, leave rd_data_b open
	// when DUAL_RD=0.
	input  wire [AW-1:0]     rd_addr_b,
	output reg  [DATA_W-1:0] rd_data_b
);
	(* ramstyle = "M10K" *) reg [DATA_W-1:0] mem [0:WIDTH-1];

	always @(posedge wr_clk) begin
		if (wr_en)
			mem[wr_addr] <= wr_data;
	end

	always @(posedge rd_clk) begin
		rd_data <= mem[rd_addr];
	end

	generate
		if (DUAL_RD) begin : gen_dual_rd
			// Second bank — both ports are true simple dual-port (wr + rd).
			// M10K cost: 2× vs single-port. Required for concurrent A/B reads.
			(* ramstyle = "M10K" *) reg [DATA_W-1:0] mem_b [0:WIDTH-1];

			always @(posedge wr_clk) begin
				if (wr_en)
					mem_b[wr_addr] <= wr_data;
			end

			always @(posedge rd_clk) begin
				rd_data_b <= mem_b[rd_addr_b];
			end
		end else begin : gen_single_rd
			always @(posedge rd_clk) begin
				rd_data_b <= {DATA_W{1'b0}};
			end
		end
	endgenerate
endmodule
