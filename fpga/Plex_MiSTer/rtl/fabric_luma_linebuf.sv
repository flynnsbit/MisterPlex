// fabric_luma_linebuf — one luma line store sized for 720p.
// 1280 bytes = 10240 bits = exactly one Cyclone V M10K bit budget.
// Parameter LINE_BYTES: 624 (480p) or 1280 (720p). Same module, no fork.
// Macro FABRIC_DDR_WRITER default OFF.
//
`default_nettype none

module fabric_luma_linebuf #(
	parameter int LINE_BYTES = 1280
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        wr_en,
	input  wire [10:0] wr_addr,
	input  wire [7:0]  wr_data,

	input  wire        rd_en,
	input  wire [10:0] rd_addr,
	output reg  [7:0]  rd_data,
	output reg         rd_valid
);

	localparam int DEPTH = LINE_BYTES;
	(* ramstyle = "M10K" *) reg [7:0] mem [0:DEPTH-1];

	wire wr_ok = wr_en && ({{21{1'b0}}, wr_addr} < DEPTH[31:0]);
	wire rd_ok = rd_en && ({{21{1'b0}}, rd_addr} < DEPTH[31:0]);

	always @(posedge clk) begin
		if (reset) begin
			rd_data  <= 8'd0;
			rd_valid <= 1'b0;
		end else begin
			if (wr_ok)
				mem[wr_addr] <= wr_data;

			if (rd_ok) begin
				rd_data  <= mem[rd_addr];
				rd_valid <= 1'b1;
			end else begin
				rd_valid <= 1'b0;
			end
		end
	end

endmodule

`default_nettype wire
