// sdram_line_spill — single-line staging toward the external SDRAM stick (w-mem).
//
// Tiering intent (product architecture):
//   M10K  : active luma/chroma linebufs (1280 B = 1 M10K bit budget) — fabric_luma_linebuf
//   SDRAM : optional spill / prefetch of the NEXT line when DDR3 f2sdram is contended
//   DDR3  : double-banked full-frame I420 (Option-C 0x180000 stride)
//
// This module is a synthesizable *line* FIFO with programmable fill latency to
// model SDRAM row cost in sim. It does NOT drive the board SDRAM PHY (sdram.sv
// owns that). Single stick only — never dual-sdram.
//
// 1280-byte line default matches 720p luma = exactly one M10K.

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
