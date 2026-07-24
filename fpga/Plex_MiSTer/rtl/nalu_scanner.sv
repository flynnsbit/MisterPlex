// Phase 3.3 / 3.3b: drain bitstream_fifo, count annex-B NAL units, classify types.
// Detects 00 00 01 and 00 00 00 01; captures nal_unit_type (5 bits).
// Emits vcl_pulse on VCL NALs (types 1,5) to drive decode_stub → frame_store.
// Not a real decoder — proves F3 → BRAM → parse → pixel path before H.264 IP.

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
	output reg  [31:0] bytes_seen,

	// 3.3b typed stats
	output reg  [7:0]  idr_count,
	output reg  [7:0]  sps_count,
	output reg  [7:0]  pps_count,
	output reg  [7:0]  slice_count, // non-IDR VCL (type 1)
	output reg         has_idr,
	// 1-cycle pulse when a VCL NAL header is captured (type 1 or 5)
	output reg         vcl_pulse
);

	// Start-code FSM: track trailing zeros
	reg [1:0] zrun; // 0..3 consecutive zeros seen
	reg       pend_type; // next non-empty byte is NAL header
	reg       data_valid; // rd_data holds a previously requested byte

	wire [4:0] nal_t = rd_data[4:0];

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
			idr_count     <= 0;
			sps_count     <= 0;
			pps_count     <= 0;
			slice_count   <= 0;
			has_idr       <= 0;
			vcl_pulse     <= 0;
		end else begin
			vcl_pulse <= 1'b0;

			// Issue read whenever FIFO has data (one byte/cycle)
			rd_en <= !rd_empty;
			// Registered FIFO: data valid the cycle after a successful rd_en
			if (data_valid) begin
				bytes_seen <= bytes_seen + 1'd1;
				has_stream <= 1'b1;

				if (pend_type) begin
					last_nal_type <= rd_data;
					nalu_count    <= nalu_count + 1'd1;
					pend_type     <= 1'b0;
					zrun          <= 0;

					// Classify (nal_unit_type in low 5 bits)
					case (nal_t)
						5'd7: sps_count   <= sps_count + 1'd1;
						5'd8: pps_count   <= pps_count + 1'd1;
						5'd5: begin
							idr_count <= idr_count + 1'd1;
							has_idr   <= 1'b1;
							vcl_pulse <= 1'b1;
						end
						5'd1: begin
							slice_count <= slice_count + 1'd1;
							vcl_pulse   <= 1'b1;
						end
						default: ;
					endcase
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
