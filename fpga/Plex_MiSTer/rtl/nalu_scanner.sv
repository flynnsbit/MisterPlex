// Phase 3.3 bring-up: drain bitstream_fifo and count annex-B NAL units.
// Detects 00 00 01 and 00 00 00 01 start codes; captures nal_unit_type (5 bits).
// Not a decoder — proves F3 → BRAM → parse path before H.264 soft-core.

module nalu_scanner (
	input  wire        clk,
	input  wire        reset,

	input  wire [7:0]  rd_data,
	input  wire        rd_empty,
	output reg         rd_en,

	// rd_data is registered one cycle after rd_en; track valid
	output reg  [15:0] nalu_count,
	output reg  [7:0]  last_nal_type,
	output reg         has_stream,
	output reg  [31:0] bytes_seen
);

	// Start-code FSM: track trailing zeros
	reg [1:0] zrun; // 0..3 consecutive zeros seen
	reg       pend_type; // next non-empty byte is NAL header
	reg       data_valid; // rd_data holds a previously requested byte

	always @(posedge clk) begin
		if (reset) begin
			rd_en         <= 0;
			nalu_count    <= 0;
			last_nal_type <= 0;
			has_stream    <= 0;
			bytes_seen    <= 0;
			zrun          <= 0;
			pend_type     <= 0;
			data_valid    <= 0;
		end else begin
			// Issue read whenever FIFO has data (one byte/cycle)
			rd_en <= !rd_empty;
			// Registered FIFO: data valid the cycle after a successful rd_en
			// while not empty at issue time. Approximate: if we asserted rd_en
			// last cycle and had data, consume.
			if (data_valid) begin
				bytes_seen <= bytes_seen + 1'd1;
				has_stream <= 1'b1;

				if (pend_type) begin
					last_nal_type <= rd_data;
					nalu_count    <= nalu_count + 1'd1;
					pend_type     <= 1'b0;
					zrun          <= 0;
				end else if (rd_data == 8'h00) begin
					if (zrun < 2'd3)
						zrun <= zrun + 1'd1;
				end else if (rd_data == 8'h01 && zrun >= 2'd2) begin
					// start code complete (3- or 4-byte)
					pend_type <= 1'b1;
					zrun      <= 0;
				end else begin
					zrun <= 0;
				end
			end

			// data_valid lags rd_en by 1 cycle when FIFO was non-empty
			data_valid <= rd_en && !rd_empty;
		end
	end

endmodule
