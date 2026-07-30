// Phase 3.3–3.3d: annex-B scan + typed counts + RBSP capture (SPS/PPS/slice).
// EPB (00 00 03) stripped.
// Slice header path: sl_cap_end after first 48 RBSP bytes (first-MB + sticky residual).
// MB traversal path: sl_rbsp_eop at true type-1 *and* type-5 (IDR) NAL end
// (start code / EOF / MAX). Full IDR RBSP is required for the I-slice residual
// walk — the old scaffold stopped IDR store at 48 B and never pulsed eop.
// Splitting hdr-end vs eop prevents the next NAL's sl_cap_clear from aborting
// a late cap_end parse.

module nalu_scanner #(
	// 624x480 IDR RBSP ≈11KB; keep headroom for larger I-slices.
	parameter int MAX_SLICE_RBSP = 16384
) (
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
	output reg         sl_rbsp_eop,
	output reg         sl_is_idr,
	output reg         sl_nal_ref_idc_nonzero
);

	reg [1:0] zrun;
	reg       pend_type;
	reg       data_valid;
	reg [1:0] cap_tgt; // 0 none, 1 sps, 2 pps, 3 slice
	reg [1:0] epb_z;
	reg [15:0] cap_len;
	reg       sl_idr_r;
	reg       sl_ref_r;
	reg       sl_hdr_ended; // sl_cap_end already issued for this slice
	reg       sl_done;      // full RBSP store complete (eop/MAX) for type-1/5
	// Last VCL may lack a trailing start code — flush after FIFO idle.
	reg [15:0] eof_idle;

	wire [4:0] nal_t = rd_data[4:0];
	// Full RBSP up to MAX for both IDR and non-IDR VCL (I residual walk needs IDR).
	// Do NOT slice MAX to [13:0]: 16384 = 1<<14 would truncate to 0.
	wire [15:0] sl_store_limit = MAX_SLICE_RBSP[15:0];
	wire       can_store = (cap_tgt != 2'd0) && !sl_done &&
	                       !(cap_tgt == 2'd3 && cap_len >= sl_store_limit);
	// open_cap for EOF: VCL still filling past hdr end counts as open
	wire       open_cap = (cap_tgt == 2'd3) && !sl_done && (cap_len != 16'd0);

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
			sl_hdr_ended  <= 0;
			sl_done       <= 0;
			eof_idle      <= 0;
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
			sl_rbsp_eop   <= 0;
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
			sl_rbsp_eop   <= 1'b0;

			rd_en <= !rd_empty;

			if (data_valid) begin
				bytes_seen <= bytes_seen + 1'd1;
				has_stream <= 1'b1;
				eof_idle   <= 16'd0;

				if (pend_type) begin
					// Close prior SPS/PPS only (slice uses early hdr end + rbsp_eop)
					if (cap_tgt == 2'd1) sps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd2) pps_cap_end <= 1'b1;

					last_nal_type <= rd_data;
					nalu_count    <= nalu_count + 1'd1;
					pend_type     <= 1'b0;
					zrun          <= 0;
					epb_z         <= 0;
					cap_len       <= 0;
					sl_hdr_ended  <= 0;
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
							sl_is_idr    <= 1'b1;
							sl_ref_r     <= (rd_data[6:5] != 2'd0);
							sl_nal_ref_idc_nonzero <= (rd_data[6:5] != 2'd0);
							sl_cap_clear <= 1'b1;
						end
						5'd1: begin
							slice_count  <= slice_count + 1'd1;
							vcl_pulse    <= 1'b1;
							cap_tgt      <= 2'd3;
							sl_idr_r     <= 1'b0;
							sl_is_idr    <= 1'b0;
							sl_ref_r     <= (rd_data[6:5] != 2'd0);
							sl_nal_ref_idc_nonzero <= (rd_data[6:5] != 2'd0);
							sl_cap_clear <= 1'b1;
						end
						default: cap_tgt <= 2'd0;
					endcase
				end else if (rd_data == 8'h00) begin
					if (zrun < 2'd3)
						zrun <= zrun + 1'd1;
					if (can_store) begin
						if (epb_z < 2'd2)
							epb_z <= epb_z + 1'd1;
						if (cap_tgt == 2'd1) begin
							sps_cap_en <= 1'b1; sps_cap_data <= 8'h00;
						end else if (cap_tgt == 2'd2) begin
							pps_cap_en <= 1'b1; pps_cap_data <= 8'h00;
						end else begin
							sl_cap_en <= 1'b1; sl_cap_data <= 8'h00;
						end
						cap_len <= cap_len + 1'd1;
						if (cap_tgt == 2'd3) begin
							// Header window: first 48 B → slice_hdr_parser (do not
							// end the RBSP store — walker needs the full NAL).
							if (!sl_hdr_ended && (cap_len + 14'd1) >= 14'd48) begin
								sl_cap_end <= 1'b1;
								sl_is_idr  <= sl_idr_r;
								sl_nal_ref_idc_nonzero <= sl_ref_r;
								sl_hdr_ended <= 1'b1;
							end
							// Hard cap (IDR + type-1)
							if ((cap_len + 16'd1) >= sl_store_limit) begin
								sl_rbsp_eop <= 1'b1;
								sl_done <= 1'b1;
							end
						end
					end
				end else if (rd_data == 8'h01 && zrun >= 2'd2) begin
					// Start code: end SPS/PPS; finish VCL RBSP; hdr if short NAL
					if (cap_tgt == 2'd1) sps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd2) pps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd3) begin
						if (!sl_hdr_ended) begin
							sl_cap_end <= 1'b1;
							sl_is_idr  <= sl_idr_r;
							sl_nal_ref_idc_nonzero <= sl_ref_r;
							sl_hdr_ended <= 1'b1;
						end
						if (!sl_done) begin
							sl_rbsp_eop <= 1'b1;
							sl_done <= 1'b1;
						end
					end
					cap_tgt   <= 2'd0;
					sl_done   <= 1'b0;
					sl_hdr_ended <= 1'b0;
					epb_z     <= 0;
					cap_len   <= 0;
					pend_type <= 1'b1;
					zrun      <= 0;
				end else begin
					if (can_store) begin
						if (rd_data == 8'h03 && epb_z >= 2'd2) begin
							epb_z <= 0; // skip EPB
						end else begin
							if (cap_tgt == 2'd1) begin
								sps_cap_en <= 1'b1; sps_cap_data <= rd_data;
							end else if (cap_tgt == 2'd2) begin
								pps_cap_en <= 1'b1; pps_cap_data <= rd_data;
							end else begin
								sl_cap_en <= 1'b1; sl_cap_data <= rd_data;
							end
							cap_len <= cap_len + 1'd1;
							epb_z <= 0;
							if (cap_tgt == 2'd3) begin
								if (!sl_hdr_ended && (cap_len + 14'd1) >= 14'd48) begin
									sl_cap_end <= 1'b1;
									sl_is_idr  <= sl_idr_r;
									sl_nal_ref_idc_nonzero <= sl_ref_r;
									sl_hdr_ended <= 1'b1;
								end
								if ((cap_len + 16'd1) >= sl_store_limit) begin
									sl_rbsp_eop <= 1'b1;
									sl_done <= 1'b1;
								end
							end
						end
					end
					zrun <= 0;
				end
			end else if (rd_empty && open_cap) begin
				if (eof_idle >= 16'd32) begin
					if (cap_tgt == 2'd1) sps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd2) pps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd3) begin
						if (!sl_hdr_ended) begin
							sl_cap_end <= 1'b1;
							sl_is_idr  <= sl_idr_r;
							sl_nal_ref_idc_nonzero <= sl_ref_r;
							sl_hdr_ended <= 1'b1;
						end
						if (!sl_done) begin
							sl_rbsp_eop <= 1'b1;
							sl_done <= 1'b1;
						end
					end
					cap_tgt  <= 2'd0;
					eof_idle <= 16'd0;
				end else
					eof_idle <= eof_idle + 16'd1;
			end else if (rd_empty)
				eof_idle <= 16'd0;

			data_valid <= rd_en && !rd_empty;
		end
	end

endmodule
