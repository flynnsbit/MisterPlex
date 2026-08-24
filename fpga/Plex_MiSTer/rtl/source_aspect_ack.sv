// Collect ioctl index 4 PLXA (9 bytes) and toggle a clk-domain ACK snapshot.
// ddr_frame_store writes PLXJ at the 480p mailbox page 0x3007F130
// (doorbell-family +0x130). L4-only 0x3047F130 must not be the sole path.
//
// Commit on the 9th PLXA byte (not ioctl_download falling edge). Mux analog
// Template path can drop or retarget ioctl_index by the time download clears;
// gold 5f1c8614 250 ms ACK must still see a toggle. Index is latched at
// download start. RED SOURCE_ASPECT_ACK_FAULT_IGNORE_INDEX_MAGIC ACKs any
// ioctl (wrong index / non-PLXA magic) so the product checks are load-bearing.
module source_aspect_ack (
	input  wire        clk,
	input  wire        reset,
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [7:0]  ioctl_dout,
	input  wire [15:0] ioctl_index,
	output reg         ack_toggle,
	output reg  [11:0] ack_x,
	output reg  [11:0] ack_y,
	output reg  [7:0]  ack_token
);
	localparam [31:0] MAGIC_A = 32'h4158_4C50; // "PLXA" LE
	reg        was_dl;
	reg        saw_plxa;
	reg        committed; // 1 after 9th-byte toggle this download
	reg [3:0]  idx;
	reg [7:0]  b0, b1, b2, b3, b4, b5, b6, b7, b8;

	wire [31:0] magic = {b3, b2, b1, b0};
`ifdef SOURCE_ASPECT_ACK_FAULT_IGNORE_INDEX_MAGIC
	// RED twin: accept any ioctl index and any 9-byte payload as PLXA.
	wire index_ok = 1'b1;
	wire magic_ok = 1'b1;
`else
	wire index_ok = (ioctl_index[5:0] == 6'd4);
	wire magic_ok = (magic == MAGIC_A);
`endif

	always @(posedge clk) begin
		if (reset) begin
			was_dl <= 1'b0;
			saw_plxa <= 1'b0;
			committed <= 1'b0;
			idx <= 4'd0;
			ack_toggle <= 1'b0;
			ack_x <= 12'd0;
			ack_y <= 12'd0;
			ack_token <= 8'd0;
			b0 <= 8'd0; b1 <= 8'd0; b2 <= 8'd0; b3 <= 8'd0;
			b4 <= 8'd0; b5 <= 8'd0; b6 <= 8'd0; b7 <= 8'd0; b8 <= 8'd0;
		end else begin
			if (ioctl_download && !was_dl) begin
				idx <= 4'd0;
				saw_plxa <= index_ok;
				committed <= 1'b0;
				if (index_ok && ioctl_wr) begin
					b0 <= ioctl_dout;
					idx <= 4'd1;
				end
			end else if (saw_plxa && ioctl_download && ioctl_wr && idx < 4'd9) begin
				case (idx)
					4'd0: b0 <= ioctl_dout;
					4'd1: b1 <= ioctl_dout;
					4'd2: b2 <= ioctl_dout;
					4'd3: b3 <= ioctl_dout;
					4'd4: b4 <= ioctl_dout;
					4'd5: b5 <= ioctl_dout;
					4'd6: b6 <= ioctl_dout;
					4'd7: b7 <= ioctl_dout;
					default: b8 <= ioctl_dout;
				endcase
				// 9th byte: payload is stable (b0..b7 already held). Toggle
				// here so ACK does not depend on ioctl_index still being 4
				// when download falls (mux analog Template miss class).
				if (idx == 4'd8 && magic_ok) begin
					ack_x <= {b5[3:0], b4};
					ack_y <= {b7[3:0], b6};
					ack_token <= ioctl_dout;
					ack_toggle <= ~ack_toggle;
					committed <= 1'b1;
				end
				idx <= idx + 4'd1;
			end else if (saw_plxa && was_dl && !ioctl_download) begin
				// mux10: mux6–9 glass wrote PLXJ *after* gold 250 ms.
				// S_IDLE was emptied (mux9) and still late → ioctl commit
				// missed. Gold 480p ACK used download falling edge. If the
				// 9th-byte beat dropped, fall here with latched bytes.
				if (!committed && magic_ok && (idx >= 4'd8)) begin
					ack_x <= {b5[3:0], b4};
					ack_y <= {b7[3:0], b6};
					ack_token <= b8;
					ack_toggle <= ~ack_toggle;
				end
				saw_plxa <= 1'b0;
				committed <= 1'b0;
			end
			was_dl <= ioctl_download;
		end
	end
endmodule
