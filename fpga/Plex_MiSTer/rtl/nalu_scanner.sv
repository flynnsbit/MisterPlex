// Phase 3.3–3.3d: annex-B scan + typed counts + RBSP capture (SPS/PPS/slice hdr).
// EPB (00 00 03) stripped.
//
// TWO SLICE PORTS, DELIBERATELY.
//
//   sl_cap_*   first 96 RBSP bytes, then sl_cap_end. This is slice_hdr_parser's
//              contract: it wants the header and nothing more, and ending the
//              capture early is what stops it parsing into residual data.
//   sl_rbsp_*  the WHOLE slice NAL, de-escaped, to the next start code.
//
// The 96-byte limit is a header window, not a slice. Measured content is about
// 7.2 KB per VCL NAL, so a decoder fed from sl_cap_* runs off the end of its
// bitstream after 96 bytes and sees zeros for the remaining 99% of the picture.
// h264_rbsp_window consumes sl_rbsp_* for that reason. Both ports are driven
// from the same byte stream in the same cycle, so they cannot disagree about
// EPB removal or slice boundaries.

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

	output reg         sps_cap_clear,
	output reg         sps_cap_en,
	output reg  [7:0]  sps_cap_data,
	output reg         sps_cap_end,

	output reg         pps_cap_clear,
	output reg         pps_cap_en,
	output reg  [7:0]  pps_cap_data,
	output reg         pps_cap_end,

	output reg         sl_cap_clear,
	output reg         sl_cap_en,
	output reg  [7:0]  sl_cap_data,
	output reg         sl_cap_end,

	// Full slice RBSP, unbounded. Trailing zero bytes belonging to the next
	// start code can appear here (the scanner emits 00 before it knows a start
	// code follows); they land after rbsp_stop_one_bit and are ignored by any
	// conformant consumer.
	output reg         sl_rbsp_clear,
	output reg         sl_rbsp_en,
	output reg  [7:0]  sl_rbsp_data,
	output reg         sl_rbsp_end,

	output reg         sl_is_idr,
	output reg         sl_nal_ref_idc_nonzero
);

	reg [1:0] zrun;
	reg       pend_type;
	reg       data_valid;
	reg [1:0] cap_tgt; // 0 none, 1 sps, 2 pps, 3 slice
	reg [1:0] epb_z;
	reg [6:0] cap_len;
	reg       sl_idr_r;
	reg       sl_ref_r;
	reg       sl_done; // slice header already ended (still draining NAL)

	wire [4:0] nal_t = rd_data[4:0];
	// Slice header + first I_NxN MB luma residual window fit in ~96 bytes of RBSP.
	wire       can_store = (cap_tgt != 2'd0) && !sl_done &&
	                       !(cap_tgt == 2'd3 && cap_len >= 7'd96);
`ifdef NALU_SCANNER_FAULT_SLICE_RBSP_96
	// Intentional fault: starve the full-slice port back to the header window.
	wire       can_stream_slice = can_store && (cap_tgt == 2'd3);
`else
	// The full-slice port is gated only by "we are inside a slice NAL": no
	// length limit, and not stopped by sl_done, which only ends the header.
	wire       can_stream_slice = (cap_tgt == 2'd3);
`endif

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
			cap_tgt       <= 0;
			epb_z         <= 0;
			cap_len       <= 0;
			sl_idr_r      <= 0;
			sl_done       <= 0;
			sps_cap_clear <= 0;
			sps_cap_en    <= 0;
			sps_cap_data  <= 0;
			sps_cap_end   <= 0;
			pps_cap_clear <= 0;
			pps_cap_en    <= 0;
			pps_cap_data  <= 0;
			pps_cap_end   <= 0;
			sl_cap_clear  <= 0;
			sl_cap_en     <= 0;
			sl_cap_data   <= 0;
			sl_cap_end    <= 0;
			sl_rbsp_clear <= 0;
			sl_rbsp_en    <= 0;
			sl_rbsp_data  <= 0;
			sl_rbsp_end   <= 0;
			sl_is_idr     <= 0;
			sl_nal_ref_idc_nonzero <= 0;
			sl_ref_r      <= 0;
		end else begin
			vcl_pulse     <= 1'b0;
			sps_cap_clear <= 1'b0;
			sps_cap_en    <= 1'b0;
			sps_cap_end   <= 1'b0;
			pps_cap_clear <= 1'b0;
			pps_cap_en    <= 1'b0;
			pps_cap_end   <= 1'b0;
			sl_cap_clear  <= 1'b0;
			sl_cap_en     <= 1'b0;
			sl_cap_end    <= 1'b0;
			sl_rbsp_clear <= 1'b0;
			sl_rbsp_en    <= 1'b0;
			sl_rbsp_end   <= 1'b0;

			rd_en <= !rd_empty;

			if (data_valid) begin
				bytes_seen <= bytes_seen + 1'd1;
				has_stream <= 1'b1;

				if (pend_type) begin
					// Close prior capture
					if (cap_tgt == 2'd1) sps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd2) pps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd3 && !sl_done) begin
						sl_cap_end <= 1'b1;
						sl_is_idr  <= sl_idr_r;
						sl_nal_ref_idc_nonzero <= sl_ref_r;
					end
					// The full-slice stream ends with the NAL, not with the
					// header, so it is closed independently of sl_done.
					if (cap_tgt == 2'd3)
						sl_rbsp_end <= 1'b1;

					last_nal_type <= rd_data;
					nalu_count    <= nalu_count + 1'd1;
					pend_type     <= 1'b0;
					zrun          <= 0;
					epb_z         <= 0;
					cap_len       <= 0;
					sl_done       <= 0;

					case (nal_t)
						5'd7: begin
							sps_count     <= sps_count + 1'd1;
							cap_tgt       <= 2'd1;
							sps_cap_clear <= 1'b1;
						end
						5'd8: begin
							pps_count     <= pps_count + 1'd1;
							cap_tgt       <= 2'd2;
							pps_cap_clear <= 1'b1;
						end
						5'd5: begin
							idr_count    <= idr_count + 1'd1;
							has_idr      <= 1'b1;
							vcl_pulse    <= 1'b1;
							cap_tgt      <= 2'd3;
							sl_idr_r     <= 1'b1;
							sl_ref_r     <= (rd_data[6:5] != 2'd0);
							sl_cap_clear <= 1'b1;
							sl_rbsp_clear <= 1'b1;
						end
						5'd1: begin
							slice_count  <= slice_count + 1'd1;
							vcl_pulse    <= 1'b1;
							cap_tgt      <= 2'd3;
							sl_idr_r     <= 1'b0;
							sl_ref_r     <= (rd_data[6:5] != 2'd0);
							sl_cap_clear <= 1'b1;
							sl_rbsp_clear <= 1'b1;
						end
						default: cap_tgt <= 2'd0;
					endcase
				end else if (rd_data == 8'h00) begin
					if (zrun < 2'd3)
						zrun <= zrun + 1'd1;
					if (can_stream_slice) begin
						sl_rbsp_en   <= 1'b1;
						sl_rbsp_data <= 8'h00;
					end
					// EPB state tracks the byte stream, not the capture: gating
					// it on can_store froze it once the 96-byte header window
					// closed, so every 00 00 03 past byte 96 would have been
					// emitted verbatim into the full-slice RBSP.
					if (cap_tgt != 2'd0 && epb_z < 2'd2)
						epb_z <= epb_z + 1'd1;
					if (can_store) begin
						if (cap_tgt == 2'd1) begin
							sps_cap_en <= 1'b1; sps_cap_data <= 8'h00;
						end else if (cap_tgt == 2'd2) begin
							pps_cap_en <= 1'b1; pps_cap_data <= 8'h00;
						end else begin
							sl_cap_en <= 1'b1; sl_cap_data <= 8'h00;
						end
						cap_len <= cap_len + 1'd1;
						if (cap_tgt == 2'd3 && cap_len == 7'd95) begin
							sl_cap_end <= 1'b1;
							sl_is_idr  <= sl_idr_r;
							sl_nal_ref_idc_nonzero <= sl_ref_r;
							sl_done    <= 1'b1;
						end
					end
				end else if (rd_data == 8'h01 && zrun >= 2'd2) begin
					if (cap_tgt == 2'd3)
						sl_rbsp_end <= 1'b1;
					if (cap_tgt == 2'd1) sps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd2) pps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd3 && !sl_done) begin
						sl_cap_end <= 1'b1;
						sl_is_idr  <= sl_idr_r;
						sl_nal_ref_idc_nonzero <= sl_ref_r;
					end
					cap_tgt   <= 2'd0;
					sl_done   <= 0;
					epb_z     <= 0;
					cap_len   <= 0;
					pend_type <= 1'b1;
					zrun      <= 0;
				end else begin
					if (can_stream_slice && !(rd_data == 8'h03 && epb_z >= 2'd2)) begin
						sl_rbsp_en   <= 1'b1;
						sl_rbsp_data <= rd_data;
					end
					// Any non-zero byte ends the zero run, whether it was an
					// EPB that got dropped or ordinary payload.
					if (cap_tgt != 2'd0)
						epb_z <= 2'd0;
					if (can_store) begin
						if (rd_data == 8'h03 && epb_z >= 2'd2) begin
							// skip EPB
						end else begin
							if (cap_tgt == 2'd1) begin
								sps_cap_en <= 1'b1; sps_cap_data <= rd_data;
							end else if (cap_tgt == 2'd2) begin
								pps_cap_en <= 1'b1; pps_cap_data <= rd_data;
							end else begin
								sl_cap_en <= 1'b1; sl_cap_data <= rd_data;
							end
							cap_len <= cap_len + 1'd1;
							if (cap_tgt == 2'd3 && cap_len == 7'd95) begin
								sl_cap_end <= 1'b1;
								sl_is_idr  <= sl_idr_r;
								sl_nal_ref_idc_nonzero <= sl_ref_r;
								sl_done    <= 1'b1;
							end
						end
					end
					zrun <= 0;
				end
			end

			data_valid <= rd_en && !rd_empty;
		end
	end

endmodule
