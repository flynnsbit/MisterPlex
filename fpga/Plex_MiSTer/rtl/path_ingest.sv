// path_ingest — F1 local-play path stubs (.mpx)
//
// MiSTer F-slots stream file bytes into the core via ioctl. Real MP4s must not
// go through this path (too large; wrong consumer). Instead, tiny .mpx stubs
// carry a single absolute path line; this module captures them and holds a
// publish request for the DDR path mailbox (PLXP + path buffer).
//
// Limit: 255 path bytes. Host trims trailing CR/LF/NUL/space.

module path_ingest (
	input  wire        clk,
	input  wire        reset,

	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [7:0]  ioctl_dout,
	input  wire        enable,

	// Held until publisher acks (path_ack).
	output reg         path_req,
	output reg  [7:0]  path_len,
	// Packed path: byte i is path_bytes[i*8 +: 8], i in 0..254.
	output reg [2047:0] path_bytes,
	input  wire        path_ack
);

	reg        was_dl;
	reg        capturing;
	reg  [7:0] wr_ix;
	reg [2047:0] acc;

	always @(posedge clk) begin
		if (reset) begin
			was_dl     <= 1'b0;
			capturing  <= 1'b0;
			wr_ix      <= 8'd0;
			acc        <= 2048'd0;
			path_req   <= 1'b0;
			path_len   <= 8'd0;
			path_bytes <= 2048'd0;
		end else if (!enable) begin
			was_dl    <= ioctl_download;
			capturing <= 1'b0;
			if (path_ack)
				path_req <= 1'b0;
		end else begin
			if (path_ack)
				path_req <= 1'b0;

			// Rising edge → new stub
			if (ioctl_download && !was_dl) begin
				capturing <= 1'b1;
				wr_ix     <= 8'd0;
				acc       <= 2048'd0;
			end

			// Falling edge → publish (host trims terminators)
			if (!ioctl_download && was_dl && capturing) begin
				capturing  <= 1'b0;
				if (wr_ix != 8'd0) begin
					path_len   <= wr_ix;
					path_bytes <= acc;
					path_req   <= 1'b1;
				end
			end

			was_dl <= ioctl_download;

			if (ioctl_download && ioctl_wr && capturing) begin
				if (wr_ix != 8'd255) begin
					acc[wr_ix*8 +: 8] <= ioctl_dout;
					wr_ix <= wr_ix + 8'd1;
				end
			end
		end
	end

endmodule
