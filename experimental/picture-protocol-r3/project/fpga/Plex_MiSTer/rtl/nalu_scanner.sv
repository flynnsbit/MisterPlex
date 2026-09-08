// Annex-B framing and EPB-stripped SPS/PPS/header/8192-byte VCL capture.
module nalu_scanner #(
	parameter bit ENABLE_AU_END = 1'b0
) (
	input wire clk, reset,
	input wire [7:0] rd_data,
	input wire rd_empty,
	output reg rd_en,
	input wire au_end, rbsp_release,
	output reg au_done,
	output wire idle,
	output reg [15:0] nalu_count,
	output reg [7:0] last_nal_type,
	output reg has_stream,
	output reg [31:0] bytes_seen,
	output reg [7:0] idr_count, sps_count, pps_count, slice_count,
	output reg has_idr, vcl_pulse,
	output reg sps_cap_clear, sps_cap_en,
	output reg [7:0] sps_cap_data,
	output reg sps_cap_end,
	output reg pps_cap_clear, pps_cap_en,
	output reg [7:0] pps_cap_data,
	output reg pps_cap_end,
	output reg sl_cap_clear, sl_cap_en,
	output reg [7:0] sl_cap_data,
	output reg sl_cap_end, sl_is_idr,
	output reg sl_rbsp_clear, sl_rbsp_en,
	output reg [7:0] sl_rbsp_data,
	output reg sl_rbsp_end,
	output reg [13:0] sl_rbsp_len
);
	localparam [13:0] RBSP_MAX = 14'd8192;
	reg data_valid, pend_type, boundary_wait, au_end_seen;
	reg [1:0] cap_tgt;
	reg [5:0] cap_len;
	reg sl_idr_r, sl_done, vcl_flushed;
	reg [13:0] rbsp_len_r;
	reg [4:0] idle_c;
	// Zeros cannot be classified as payload until the following byte arrives.
	reg [15:0] zero_count, flush_zeros;
	reg pending_valid;
	reg [7:0] pending_byte;
	wire blocked = ENABLE_AU_END && boundary_wait && !rbsp_release;
	wire can_store = cap_tgt != 0 && !sl_done &&
	                 !(cap_tgt == 3 && cap_len >= 48);
	wire can_rbsp = cap_tgt == 3;
	assign idle = !data_valid && !rd_en && !pending_valid && flush_zeros == 0 &&
	              cap_tgt == 0 && !pend_type && !boundary_wait;

	task automatic emit_payload(input [7:0] value);
		begin
			if (can_store) begin
				case (cap_tgt)
					1: begin sps_cap_en <= 1; sps_cap_data <= value; end
					2: begin pps_cap_en <= 1; pps_cap_data <= value; end
					3: begin sl_cap_en <= 1; sl_cap_data <= value; end
					default: begin end
				endcase
				cap_len <= cap_len + 1'b1;
				if (cap_tgt == 3 && cap_len == 47) begin
					sl_cap_end <= 1;
					sl_is_idr <= sl_idr_r;
					sl_done <= 1;
				end
			end
			if (can_rbsp) begin
				sl_rbsp_en <= 1;
				sl_rbsp_data <= value;
				// Keep overflow attempts visible; capacity is not a NAL boundary.
				// A one-past-limit length is sufficient to reject without wrapping.
				if (rbsp_len_r <= RBSP_MAX) begin
					rbsp_len_r <= rbsp_len_r + 1'b1;
					sl_rbsp_len <= rbsp_len_r + 1'b1;
				end
			end
		end
	endtask

	task automatic close_capture;
		begin
			if (cap_tgt == 1) sps_cap_end <= 1;
			if (cap_tgt == 2) pps_cap_end <= 1;
			if (cap_tgt == 3) begin
				if (!sl_done) begin
					sl_cap_end <= 1;
					sl_is_idr <= sl_idr_r;
				end
				sl_rbsp_end <= 1;
			end
			cap_tgt <= 0;
			sl_done <= 1;
			zero_count <= 0;
			vcl_flushed <= 1;
		end
	endtask

	always @(posedge clk) begin
		if (reset) begin
			rd_en <= 0;
			data_valid <= 0;
			pend_type <= 0;
			boundary_wait <= 0;
			au_end_seen <= 0;
			au_done <= 0;
			cap_tgt <= 0;
			cap_len <= 0;
			sl_idr_r <= 0;
			sl_done <= 0;
			vcl_flushed <= 0;
			rbsp_len_r <= 0;
			idle_c <= 0;
			zero_count <= 0;
			flush_zeros <= 0;
			pending_valid <= 0;
			pending_byte <= 0;
			nalu_count <= 0;
			last_nal_type <= 0;
			has_stream <= 0;
			bytes_seen <= 0;
			idr_count <= 0;
			sps_count <= 0;
			pps_count <= 0;
			slice_count <= 0;
			has_idr <= 0;
			vcl_pulse <= 0;
			sps_cap_clear <= 0;
			sps_cap_en <= 0;
			sps_cap_data <= 0;
			sps_cap_end <= 0;
			pps_cap_clear <= 0;
			pps_cap_en <= 0;
			pps_cap_data <= 0;
			pps_cap_end <= 0;
			sl_cap_clear <= 0;
			sl_cap_en <= 0;
			sl_cap_data <= 0;
			sl_cap_end <= 0;
			sl_is_idr <= 0;
			sl_rbsp_clear <= 0;
			sl_rbsp_en <= 0;
			sl_rbsp_data <= 0;
			sl_rbsp_end <= 0;
			sl_rbsp_len <= 0;
		end else begin
			vcl_pulse <= 0;
			sps_cap_clear <= 0;
			sps_cap_en <= 0;
			sps_cap_end <= 0;
			pps_cap_clear <= 0;
			pps_cap_en <= 0;
			pps_cap_end <= 0;
			sl_cap_clear <= 0;
			sl_cap_en <= 0;
			sl_cap_end <= 0;
			sl_rbsp_clear <= 0;
			sl_rbsp_en <= 0;
			sl_rbsp_end <= 0;
			au_done <= 0;
			data_valid <= rd_en && !rd_empty;
			if (!au_end) au_end_seen <= 0;
			if (boundary_wait && rbsp_release) boundary_wait <= 0;

			// One outstanding FIFO read avoids speculative bytes while pending
			// zeros are emitted or a completed VCL is still decoder-owned.
			rd_en <= !rd_empty && !rd_en && !data_valid && !pending_valid &&
			         flush_zeros == 0 && !blocked;
			if (flush_zeros != 0) begin
				emit_payload(8'd0);
				flush_zeros <= flush_zeros - 1'b1;
				idle_c <= 0;
			end else if (pending_valid) begin
				emit_payload(pending_byte);
				pending_valid <= 0;
				idle_c <= 0;
			end else if (data_valid) begin
				bytes_seen <= bytes_seen + 1'b1;
				has_stream <= 1;
				idle_c <= 0;
				if (pend_type) begin
					last_nal_type <= rd_data;
					nalu_count <= nalu_count + 1'b1;
					pend_type <= 0;
					zero_count <= 0;
					cap_len <= 0;
					sl_done <= 0;
					case (rd_data[4:0])
						7: begin
							sps_count <= sps_count + 1'b1;
							cap_tgt <= 1;
							sps_cap_clear <= 1;
						end
						8: begin
							pps_count <= pps_count + 1'b1;
							cap_tgt <= 2;
							pps_cap_clear <= 1;
						end
						1, 5: begin
							if (rd_data[4:0] == 5) begin
								idr_count <= idr_count + 1'b1;
								has_idr <= 1;
							end else slice_count <= slice_count + 1'b1;
							vcl_pulse <= 1;
							cap_tgt <= 3;
							sl_idr_r <= rd_data[4:0] == 5;
							sl_cap_clear <= 1;
							sl_rbsp_clear <= 1;
							rbsp_len_r <= 0;
							sl_rbsp_len <= 0;
							vcl_flushed <= 0;
						end
						default: cap_tgt <= 0;
					endcase
				end else if (rd_data == 0) begin
					if (zero_count != 16'hffff) zero_count <= zero_count + 1'b1;
				end else if (rd_data == 1 && zero_count >= 2) begin
					close_capture();
					pend_type <= 1;
					if (ENABLE_AU_END && cap_tgt != 0) boundary_wait <= 1;
				end else begin
					zero_count <= 0;
					if (zero_count != 0 && cap_tgt != 0) begin
						flush_zeros <= zero_count;
						if (!(rd_data == 3 && zero_count >= 2)) begin
							pending_byte <= rd_data;
							pending_valid <= 1;
						end
					end else emit_payload(rd_data);
				end
			end else if (ENABLE_AU_END && au_end && !au_end_seen &&
			             !rd_en && !blocked) begin
				close_capture();
				pend_type <= 0;
				au_end_seen <= 1;
				au_done <= 1;
			end else if (!ENABLE_AU_END && cap_tgt == 3 &&
			             rbsp_len_r != 0 && !vcl_flushed && !rd_en && rd_empty) begin
				if (idle_c == 12) close_capture();
				else idle_c <= idle_c + 1'b1;
			end else idle_c <= 0;
		end
	end
endmodule
