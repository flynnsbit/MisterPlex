// Path B / future: RBSP bit window + optional EPB strip.
// NOT in files.qip (parent Path A — fabric decoder does not fit).
// Unit TBs compile this file explicitly; product build does not.

// -----------------------------------------------------------------------------
// bitstream_bit_feeder — byte stream → EPB strip → bit window (MSB-first).
// Path B / future only — NOT listed in files.qip (parent Path A decision).
// -----------------------------------------------------------------------------
module bitstream_bit_feeder #(
	parameter int BYTE_Q_DEPTH = 8, // power-of-two skid after optional EPB strip
	// 1: annex-B in, strip 0x000003 (standalone path / ENABLE_BIT_FEED)
	// 0: already-RBSP bytes in (after h264_rbsp_filter) — bit window only
	parameter bit STRIP_EPB = 1'b1
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        clear,

	// Bytes in: annex-B when STRIP_EPB=1, RBSP when STRIP_EPB=0
	input  wire        in_valid,
	input  wire [7:0]  in_byte,
	input  wire        in_last,   // pulses with final byte of a NAL payload
	output wire        in_ready,

	// Continuous bit stream for CAVLC / exp-golomb (H.264 MSB-first within byte)
	output wire        bit_valid,
	output wire        bit_value,
	input  wire        bit_ready,

	output reg         nal_bit_last, // 1-cycle pulse after last RBSP bit of NAL drained
	output reg  [15:0] epb_removed,
	output reg  [15:0] rbsp_bytes,
	output reg  [31:0] bits_out,
	output wire        byte_q_full,
	output wire        byte_q_empty
);
	localparam int QAW = $clog2(BYTE_Q_DEPTH);

	// --- Optional EPB strip (same contract as h264_rbsp_filter when STRIP_EPB=1) ---
	reg [1:0] zero_count;
	reg       inhibit_skip;
	wire      epb_can_accept;
	wire      skip_epb;

	// --- RBSP byte skid (holds bytes while bit consumer backpressures) ---
	reg [7:0] q_data [0:BYTE_Q_DEPTH-1];
	reg       q_last [0:BYTE_Q_DEPTH-1];
	reg [QAW:0] q_wr;
	reg [QAW:0] q_rd;
	wire [QAW:0] q_level = q_wr - q_rd;
	assign byte_q_empty = (q_wr == q_rd);
	assign byte_q_full  = (q_level >= BYTE_Q_DEPTH[QAW:0]);
	assign epb_can_accept = !byte_q_full;
	assign skip_epb = STRIP_EPB && in_valid && epb_can_accept && !inhibit_skip &&
	                  (zero_count == 2'd2) && (in_byte == 8'h03);
	// Accept input when EPB stage can push or skip without growing a full queue.
	assign in_ready = epb_can_accept;

	// --- Current byte under bit extraction ---
	reg        have_cur;
	reg [7:0]  cur_byte;
	reg        cur_last;
	reg [2:0]  bit_idx; // 0 = MSB (bit7)
	reg        pending_nal_last;

	wire bits_in_cur = have_cur;
	assign bit_valid = bits_in_cur;
	assign bit_value = cur_byte[3'd7 - bit_idx];

	wire take_bit = bit_valid && bit_ready;
	wire load_cur = !have_cur && !byte_q_empty;

	integer qi;
	always @(posedge clk) begin
		if (reset || clear) begin
			zero_count <= 2'd0;
			inhibit_skip <= 1'b0;
			epb_removed <= 16'd0;
			rbsp_bytes <= 16'd0;
			bits_out <= 32'd0;
			q_wr <= '0;
			q_rd <= '0;
			have_cur <= 1'b0;
			cur_byte <= 8'd0;
			cur_last <= 1'b0;
			bit_idx <= 3'd0;
			pending_nal_last <= 1'b0;
			nal_bit_last <= 1'b0;
			for (qi = 0; qi < BYTE_Q_DEPTH; qi = qi + 1) begin
				q_data[qi] <= 8'd0;
				q_last[qi] <= 1'b0;
			end
		end else begin
			nal_bit_last <= 1'b0;

			// Optional EPB filter → push RBSP bytes into skid
			if (in_valid && in_ready) begin
				if (skip_epb) begin
					if (epb_removed != 16'hFFFF)
						epb_removed <= epb_removed + 16'd1;
					inhibit_skip <= 1'b1;
					// EPB is not last-of-RBSP content; if in_last, NAL ends after skip
					if (in_last)
						pending_nal_last <= 1'b1;
				end else begin
					q_data[q_wr[QAW-1:0]] <= in_byte;
					q_last[q_wr[QAW-1:0]] <= in_last;
					q_wr <= q_wr + 1'd1;
					if (rbsp_bytes != 16'hFFFF)
						rbsp_bytes <= rbsp_bytes + 16'd1;
					if (STRIP_EPB) begin
						if (in_byte == 8'h00)
							zero_count <= (zero_count == 2'd2) ? 2'd2 : (zero_count + 2'd1);
						else
							zero_count <= 2'd0;
						inhibit_skip <= 1'b0;
					end
				end
			end

			// Load next RBSP byte into bit window when empty
			if (load_cur) begin
				cur_byte <= q_data[q_rd[QAW-1:0]];
				cur_last <= q_last[q_rd[QAW-1:0]];
				q_rd <= q_rd + 1'd1;
				have_cur <= 1'b1;
				bit_idx <= 3'd0;
			end

			// Consume one bit under backpressure
			if (take_bit) begin
				if (bits_out != 32'hFFFF_FFFF)
					bits_out <= bits_out + 32'd1;
				if (bit_idx == 3'd7) begin
					have_cur <= 1'b0;
					bit_idx <= 3'd0;
					if (cur_last || (pending_nal_last && byte_q_empty)) begin
						nal_bit_last <= 1'b1;
						pending_nal_last <= 1'b0;
					end
				end else begin
					bit_idx <= bit_idx + 3'd1;
				end
			end
		end
	end
endmodule
