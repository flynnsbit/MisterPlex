// fabric_i420_pattern_src — pluggable qword I420 source for fabric_ddr_writer.
// Generates a full planar I420 frame (Y ramp, U=128, V=128) with zero ARM work.
// Macro FABRIC_DDR_WRITER (default OFF) gates product use with the writer.
//
`default_nettype none

module fabric_i420_pattern_src #(
	parameter int CODED_W = 1280,
	parameter int CODED_H = 720
)(
	input  wire        clk,
	input  wire        reset,

	// Pulse start (level also OK if held until busy)
	input  wire        start,
	input  wire [1:0]  bank_id,

	// Stream to fabric_ddr_writer
	output reg         src_valid,
	input  wire        src_ready,
	output reg  [63:0] src_data,
	output reg         src_frame_start,
	output reg  [1:0]  src_bank_id,

	output wire        busy,
	output reg         done_pulse
);

	localparam int Y_BYTES = CODED_W * CODED_H;
	localparam int C_BYTES = Y_BYTES / 4;
	localparam int FRAME_BYTES = Y_BYTES + 2 * C_BYTES;
	localparam int FRAME_QWORDS = FRAME_BYTES / 8;
	localparam int Y_QWORDS = Y_BYTES / 8;
	localparam int C_QWORDS = C_BYTES / 8;

	reg        active;
	reg [31:0] q_index;
	reg [1:0]  bank_r;

	assign busy = active;

	// Pack 8 bytes into a qword. Y: ascending byte = (q*8+b) & 0xFF
	// U/V planes: 0x80 each byte (neutral chroma).
	function automatic [63:0] make_y_q(input [31:0] qi);
		reg [63:0] v;
		integer b;
		begin
			v = 64'd0;
			for (b = 0; b < 8; b = b + 1)
				v[b*8 +: 8] = 8'((qi * 32'd8 + 32'(b)) & 32'hFF);
			make_y_q = v;
		end
	endfunction

	localparam [63:0] CHROMA_Q = {8{8'h80}};

	always @(posedge clk) begin
		if (reset) begin
			active          <= 1'b0;
			q_index         <= 32'd0;
			bank_r          <= 2'd0;
			src_valid       <= 1'b0;
			src_data        <= 64'd0;
			src_frame_start <= 1'b0;
			src_bank_id     <= 2'd0;
			done_pulse      <= 1'b0;
		end else begin
			done_pulse <= 1'b0;

			if (!active) begin
				src_valid       <= 1'b0;
				src_frame_start <= 1'b0;
				if (start) begin
					active          <= 1'b1;
					q_index         <= 32'd0;
					bank_r          <= bank_id;
					src_bank_id     <= bank_id;
					src_frame_start <= 1'b1;
					src_valid       <= 1'b1;
					src_data        <= make_y_q(32'd0);
				end
			end else begin
				// Advance on handshake
				if (src_valid && src_ready) begin
					if (q_index + 32'd1 >= 32'(FRAME_QWORDS)) begin
						active          <= 1'b0;
						src_valid       <= 1'b0;
						src_frame_start <= 1'b0;
						done_pulse      <= 1'b1;
						q_index         <= 32'd0;
					end else begin
						q_index         <= q_index + 32'd1;
						src_frame_start <= 1'b0;
						src_valid       <= 1'b1;
						src_bank_id     <= bank_r;
						if (q_index + 32'd1 < 32'(Y_QWORDS))
							src_data <= make_y_q(q_index + 32'd1);
						else
							src_data <= CHROMA_Q;
					end
				end else begin
					// Hold valid/data stable
					src_valid <= 1'b1;
					if (q_index == 32'd0)
						src_frame_start <= 1'b1;
				end
			end
		end
	end

endmodule

`default_nettype wire
