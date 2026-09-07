//============================================================================
//  h264_slice_rbsp_ram — on-chip VCL RBSP (EPB already stripped)
//  Filled from nalu_scanner sl_rbsp_* . Does not replace the 48B sl_cap
//  window used by slice_hdr_parser (residual_csum 0x14 / recon_sig 0x3b).
//  Copyright (C) 2026 MiSTerPlex contributors
//  GPL-2.0-or-later
//============================================================================

module h264_slice_rbsp_ram #(
	parameter int DEPTH = 8192
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        wr_clear,
	input  wire        wr_en,
	input  wire [7:0]  wr_data,
	input  wire        wr_end,
	input  wire [$clog2(DEPTH)-1:0] rd_addr,
	output reg  [7:0]  rd_data,
	output reg  [$clog2(DEPTH):0] len,
	output reg         done,
	output reg         overflow
);

	localparam int AW = $clog2(DEPTH);

	(* ramstyle = "M10K" *) reg [7:0] mem [0:DEPTH-1];
	reg [AW-1:0] wr_ptr;

	always @(posedge clk) begin
		if (reset || wr_clear) begin
			wr_ptr <= {AW{1'b0}};
			len    <= '0;
			done   <= 1'b0;
			overflow <= 1'b0;
		end else begin
			if (wr_en && !done && (len < (AW+1)'(DEPTH))) begin
				mem[wr_ptr] <= wr_data;
				wr_ptr      <= wr_ptr + {{(AW-1){1'b0}}, 1'b1};
				len         <= len + 1'b1;
			end
			if (wr_en && !done && (len >= (AW+1)'(DEPTH)))
				overflow <= 1'b1;
			if (wr_end)
				done <= 1'b1;
		end
		rd_data <= (32'(rd_addr) < 32'(DEPTH)) ? mem[rd_addr] : 8'd0;
	end

endmodule
