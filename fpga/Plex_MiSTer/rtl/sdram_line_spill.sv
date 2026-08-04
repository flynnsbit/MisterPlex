// sdram_line_spill — MISNOMER: M10K line hold + placeholder latency (w-mem).
//
// *** NOT SDRAM. Does NOT drive sdram.sv / board SDRAM PHY (rd-duck). ***
// Stores the line in M10K (`ramstyle=M10K`) and waits SPILL_LATENCY clocks.
// That is a latency stub for TB smoke only — not memory tiering, not a stick.
//
// Real tiering (when built): M10K linebufs + single SDRAM stick (sdram.sv) +
// DDR3 Option-C banks. This file must not be cited as "SDRAM use".
// Module name retained for qip stability; treat as m10k_line_latency_stub.

`default_nettype none

module sdram_line_spill #(
	parameter int LINE_BYTES = 1280,
	// Simulated SDRAM service latency in clk cycles after a line commit
	// (TB/parent measure real PHY later; default is a placeholder for sim).
	parameter int SPILL_LATENCY = 8
)(
	input  wire        clk,
	input  wire        reset,

	// Producer (fabric / host staging)
	input  wire        wr_en,
	input  wire [10:0] wr_addr,
	input  wire [7:0]  wr_data,
	input  wire        wr_line_commit, // pulse: line is full, begin "spill"

	// Consumer (reload into M10K linebuf)
	input  wire        rd_en,
	input  wire [10:0] rd_addr,
	output reg  [7:0]  rd_data,
	output reg         rd_valid,

	output reg         spill_busy,
	output reg         spill_done,   // pulse when latency elapsed (line durable)
	output wire        line_ready    // can accept a new commit
);

	localparam int DEPTH = LINE_BYTES;
	(* ramstyle = "M10K" *) reg [7:0] mem [0:DEPTH-1];

	reg [15:0] lat_cnt;
	assign line_ready = !spill_busy;

	wire wr_ok = wr_en && !spill_busy && ({{21{1'b0}}, wr_addr} < DEPTH[31:0]);
	wire rd_ok = rd_en && ({{21{1'b0}}, rd_addr} < DEPTH[31:0]);

	always @(posedge clk) begin
		if (reset) begin
			rd_data    <= 8'd0;
			rd_valid   <= 1'b0;
			spill_busy <= 1'b0;
			spill_done <= 1'b0;
			lat_cnt    <= 16'd0;
		end else begin
			spill_done <= 1'b0;

			if (wr_ok)
				mem[wr_addr] <= wr_data;

			if (rd_ok) begin
				rd_data  <= mem[rd_addr];
				rd_valid <= 1'b1;
			end else begin
				rd_valid <= 1'b0;
			end

			if (wr_line_commit && !spill_busy) begin
				spill_busy <= 1'b1;
				lat_cnt    <= 16'(SPILL_LATENCY);
			end else if (spill_busy) begin
				if (lat_cnt == 16'd0) begin
					spill_busy <= 1'b0;
					spill_done <= 1'b1;
				end else begin
					lat_cnt <= lat_cnt - 16'd1;
				end
			end
		end
	end

endmodule

`default_nettype wire
