// Phase 3.3–3.3d: annex-B scan + typed counts + RBSP capture (SPS/PPS/slice hdr).
// EPB (00 00 03) stripped. Slice capture stores first 32 bytes then ends parse.

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
	output reg         sl_is_idr,
	// CONFIRMED live: sl_rbsp 8K >48B VCL (EPB-stripped) for the MB walker.
	// sl_cap 48B UNCHANGED — slice_hdr_parser MB0 goldens only (0x14 / 0x3b).
	output reg         sl_rbsp_clear,
	output reg         sl_rbsp_en,
	output reg  [7:0]  sl_rbsp_data,
	output reg         sl_rbsp_end,
	output reg  [13:0] sl_rbsp_len
);

	reg [1:0] zrun;
	reg       pend_type;
	reg       data_valid;
	reg [1:0] cap_tgt; // 0 none, 1 sps, 2 pps, 3 slice
	reg [1:0] epb_z;
	reg [5:0] cap_len;
	reg       sl_idr_r;
	reg       sl_done; // slice header already ended (still draining NAL)
	reg [13:0] rbsp_len_r;
	reg [4:0]  idle_c;
	reg        vcl_flushed;

	localparam [13:0] RBSP_MAX = 14'd8192;

	wire [4:0] nal_t = rd_data[4:0];
	// Slice header + first mb_type + first residual stay in the 48B sl_cap path.
	wire       can_store = (cap_tgt != 2'd0) && !sl_done &&
	                       !(cap_tgt == 2'd3 && cap_len >= 6'd48);
	// Walker RBSP: same EPB-stripped VCL bytes, up to 8 KiB.
	wire       can_rbsp  = (cap_tgt == 2'd3) && (rbsp_len_r < RBSP_MAX);

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
			rbsp_len_r    <= 0;
			idle_c        <= 0;
			vcl_flushed   <= 0;
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
			sl_is_idr     <= 0;
			sl_rbsp_clear <= 0;
			sl_rbsp_en    <= 0;
			sl_rbsp_data  <= 0;
			sl_rbsp_end   <= 0;
			sl_rbsp_len   <= 0;
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
					else if (cap_tgt == 2'd3) begin
						if (!sl_done) begin
							sl_cap_end <= 1'b1;
							sl_is_idr  <= sl_idr_r;
						end
						sl_rbsp_end <= 1'b1;
					end

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
							idr_count     <= idr_count + 1'd1;
							has_idr       <= 1'b1;
							vcl_pulse     <= 1'b1;
							cap_tgt       <= 2'd3;
							sl_idr_r      <= 1'b1;
							sl_cap_clear  <= 1'b1;
							sl_rbsp_clear <= 1'b1;
							rbsp_len_r    <= 14'd0;
							sl_rbsp_len   <= 14'd0;
							vcl_flushed   <= 1'b0;
							idle_c        <= 5'd0;
						end
						5'd1: begin
							slice_count   <= slice_count + 1'd1;
							vcl_pulse     <= 1'b1;
							cap_tgt       <= 2'd3;
							sl_idr_r      <= 1'b0;
							sl_cap_clear  <= 1'b1;
							sl_rbsp_clear <= 1'b1;
							rbsp_len_r    <= 14'd0;
							sl_rbsp_len   <= 14'd0;
							vcl_flushed   <= 1'b0;
							idle_c        <= 5'd0;
						end
						default: cap_tgt <= 2'd0;
					endcase
				end else if (rd_data == 8'h00) begin
					if (zrun < 2'd3)
						zrun <= zrun + 1'd1;
					if (can_store || can_rbsp) begin
						if (epb_z < 2'd2)
							epb_z <= epb_z + 1'd1;
						if (can_store && cap_tgt == 2'd1) begin
							sps_cap_en <= 1'b1; sps_cap_data <= 8'h00;
						end else if (can_store && cap_tgt == 2'd2) begin
							pps_cap_en <= 1'b1; pps_cap_data <= 8'h00;
						end else if (can_store) begin
							sl_cap_en <= 1'b1; sl_cap_data <= 8'h00;
						end
						if (can_rbsp) begin
							sl_rbsp_en   <= 1'b1;
							sl_rbsp_data <= 8'h00;
							rbsp_len_r   <= rbsp_len_r + 14'd1;
							sl_rbsp_len  <= rbsp_len_r + 14'd1;
							if (rbsp_len_r == (RBSP_MAX - 14'd1))
								sl_rbsp_end <= 1'b1;
						end
						if (can_store)
							cap_len <= cap_len + 1'd1;
						if (can_store && cap_tgt == 2'd3 && cap_len == 6'd47) begin
							sl_cap_end <= 1'b1;
							sl_is_idr  <= sl_idr_r;
							sl_done    <= 1'b1;
						end
					end
				end else if (rd_data == 8'h01 && zrun >= 2'd2) begin
					if (cap_tgt == 2'd1) sps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd2) pps_cap_end <= 1'b1;
					else if (cap_tgt == 2'd3) begin
						if (!sl_done) begin
							sl_cap_end <= 1'b1;
							sl_is_idr  <= sl_idr_r;
						end
						sl_rbsp_end <= 1'b1;
					end
					cap_tgt   <= 2'd0;
					sl_done   <= 0;
					epb_z     <= 0;
					cap_len   <= 0;
					pend_type <= 1'b1;
					zrun      <= 0;
				end else begin
					if (can_store || can_rbsp) begin
						if (rd_data == 8'h03 && epb_z >= 2'd2) begin
							epb_z <= 0; // skip EPB (hdr + walker RBSP)
						end else begin
							if (can_store && cap_tgt == 2'd1) begin
								sps_cap_en <= 1'b1; sps_cap_data <= rd_data;
							end else if (can_store && cap_tgt == 2'd2) begin
								pps_cap_en <= 1'b1; pps_cap_data <= rd_data;
							end else if (can_store) begin
								sl_cap_en <= 1'b1; sl_cap_data <= rd_data;
							end
							if (can_rbsp) begin
								sl_rbsp_en   <= 1'b1;
								sl_rbsp_data <= rd_data;
								rbsp_len_r   <= rbsp_len_r + 14'd1;
								sl_rbsp_len  <= rbsp_len_r + 14'd1;
								if (rbsp_len_r == (RBSP_MAX - 14'd1))
									sl_rbsp_end <= 1'b1;
							end
							if (can_store)
								cap_len <= cap_len + 1'd1;
							epb_z <= 0;
							if (can_store && cap_tgt == 2'd3 && cap_len == 6'd47) begin
								sl_cap_end <= 1'b1;
								sl_is_idr  <= sl_idr_r;
								sl_done    <= 1'b1;
							end
						end
					end
					zrun <= 0;
				end
			end else if ((cap_tgt == 2'd3) && (rbsp_len_r != 14'd0) && !vcl_flushed) begin
				// Short P VCL (<48 B) has no next start-code until the next NAL
				// is fed. Pulse sl_cap_end + sl_rbsp_end after the fifo stays
				// empty (not a 1-cycle gap between ioctl bytes).
				if (!rd_empty)
					idle_c <= 5'd0;
				else if (idle_c < 5'd16)
					idle_c <= idle_c + 5'd1;
				if (rd_empty && (idle_c == 5'd12)) begin
					if (!sl_done) begin
						sl_cap_end <= 1'b1;
						sl_is_idr  <= sl_idr_r;
					end
					sl_rbsp_end <= 1'b1;
					sl_done     <= 1'b1;
					vcl_flushed <= 1'b1;
					cap_tgt     <= 2'd0;
				end
			end else
				idle_c <= 5'd0;

			data_valid <= rd_en && !rd_empty;
		end
	end

endmodule
