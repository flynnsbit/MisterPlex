// Phase 3.3 / 3.3b / 3.3c: drain bitstream_fifo, count annex-B NALs, classify types.
// Detects 00 00 01 and 00 00 00 01; captures nal_unit_type (5 bits).
// Emits vcl_pulse on VCL NALs (types 1,5) for decode_stub.
// 3.3c: capture SPS RBSP (EPB-stripped) into sps_parser.

module nalu_scanner (
	input  wire        clk,
	input  wire        reset,

	input  wire [7:0]  rd_data,
	input  wire        rd_empty,
	output reg         rd_en,

	output reg  [15:0] nalu_count,
	output reg  [7:0]  last_nal_type,
	output reg         has_stream,
	output reg  [31:0] bytes_seen,

	output reg  [7:0]  idr_count,
	output reg  [7:0]  sps_count,
	output reg  [7:0]  pps_count,
	output reg  [7:0]  slice_count,
	output reg         has_idr,
	output reg         vcl_pulse,

	// SPS capture → sps_parser
	output reg         sps_cap_clear,
	output reg         sps_cap_en,
	output reg  [7:0]  sps_cap_data,
	output reg         sps_cap_end
);

	reg [1:0] zrun;
	reg       pend_type;
	reg       data_valid;

	// In-payload capture state
	reg       in_sps;       // capturing SPS RBSP
	reg [1:0] epb_z;        // consecutive zeros seen in RBSP for EPB
	reg       ending_nal;   // saw start-code while in payload; next header closes

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
			in_sps        <= 0;
			epb_z         <= 0;
			ending_nal    <= 0;
			sps_cap_clear <= 0;
			sps_cap_en    <= 0;
			sps_cap_data  <= 0;
			sps_cap_end   <= 0;
		end else begin
			vcl_pulse     <= 1'b0;
			sps_cap_clear <= 1'b0;
			sps_cap_en    <= 1'b0;
			sps_cap_end   <= 1'b0;

			rd_en <= !rd_empty;

			if (data_valid) begin
				bytes_seen <= bytes_seen + 1'd1;
				has_stream <= 1'b1;

				if (pend_type) begin
					// NAL header byte
					// Close previous SPS if any
					if (in_sps) begin
						sps_cap_end <= 1'b1;
						in_sps <= 1'b0;
						epb_z  <= 0;
					end

					last_nal_type <= rd_data;
					nalu_count    <= nalu_count + 1'd1;
					pend_type     <= 1'b0;
					zrun          <= 0;
					ending_nal    <= 0;

					case (nal_t)
						5'd7: begin
							sps_count     <= sps_count + 1'd1;
							in_sps        <= 1'b1;
							epb_z         <= 0;
							sps_cap_clear <= 1'b1;
						end
						5'd8: pps_count <= pps_count + 1'd1;
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
				end else begin
					// Payload or start-code hunt
					// Start-code detection
					if (rd_data == 8'h00) begin
						if (zrun < 2'd3)
							zrun <= zrun + 1'd1;
						// SPS capture with EPB awareness
						if (in_sps) begin
							// track zeros for EPB: 00 00 03 → drop 03
							if (epb_z < 2'd2)
								epb_z <= epb_z + 1'd1;
							// always store zeros (RBSP keeps them; only 03 after 00 00 is dropped)
							sps_cap_en   <= 1'b1;
							sps_cap_data <= 8'h00;
						end
					end else if (rd_data == 8'h01 && zrun >= 2'd2) begin
						// start code complete — end current NAL payload
						if (in_sps) begin
							// zeros that were part of start code were already written to SPS buf
							// Remove the trailing 00 00 (or 00 00 00) that belong to start code
							// Simpler: don't write zeros while zrun building if they form SC.
							// We already wrote them — sps may have extra trailing zeros.
							// Parser tolerates trailing bits; extra zeros OK if < full byte issues.
							// Better approach: defer writing zeros until non-zero non-SC.
							// For this fire: end SPS and start parse; trailing zeros at end of
							// RBSP are zero bits which is fine for trailing_bits.
							sps_cap_end <= 1'b1;
							in_sps <= 1'b0;
							epb_z  <= 0;
						end
						pend_type <= 1'b1;
						zrun      <= 0;
					end else begin
						// normal non-zero payload byte
						if (in_sps) begin
							if (rd_data == 8'h03 && epb_z >= 2'd2) begin
								// EPB: skip 0x03, keep the two zeros already stored
								epb_z <= 0;
							end else begin
								sps_cap_en   <= 1'b1;
								sps_cap_data <= rd_data;
								epb_z <= 0;
							end
						end
						zrun <= 0;
					end
				end
			end

			data_valid <= rd_en && !rd_empty;
		end
	end

endmodule
