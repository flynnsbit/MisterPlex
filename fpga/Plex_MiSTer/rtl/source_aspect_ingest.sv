`timescale 1ns/1ps
`default_nettype none

module source_aspect_ingest (
	input  wire        clk,
	input  wire        reset,
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [7:0]  ioctl_dout,
	input  wire [26:0] ioctl_addr,
	input  wire        enable,
	output reg         aspect_valid,
	output reg  [11:0] aspect_x,
	output reg  [11:0] aspect_y,
	output reg   [7:0] aspect_token,
	output reg         aspect_commit
);
	localparam [31:0] MAGIC_A = 32'h4158_4C50; // "PLXA" little-endian

	reg        was_download;
	reg [8:0]  bytes_seen;
	reg [31:0] packet_magic;
	reg [15:0] packet_x;
	reg [15:0] packet_y;
	reg  [7:0] packet_token;

	always_ff @(posedge clk) begin
		if (reset) begin
			was_download <= 1'b0;
			bytes_seen <= 9'd0;
			packet_magic <= 32'd0;
			packet_x <= 16'd0;
			packet_y <= 16'd0;
			packet_token <= 8'd0;
			aspect_valid <= 1'b0;
			aspect_x <= 12'd4;
			aspect_y <= 12'd3;
			aspect_token <= 8'd0;
			aspect_commit <= 1'b0;
		end else begin
			was_download <= ioctl_download && enable;
			aspect_commit <= 1'b0;

			if (ioctl_download && enable && !was_download) begin
				bytes_seen <= 9'd0;
				packet_magic <= 32'd0;
				packet_x <= 16'd0;
				packet_y <= 16'd0;
				packet_token <= 8'd0;
			end

			if (ioctl_download && enable && ioctl_wr && (ioctl_addr < 27'd9)) begin
				bytes_seen[ioctl_addr[3:0]] <= 1'b1;
				unique case (ioctl_addr[3:0])
					4'd0: packet_magic[7:0] <= ioctl_dout;
					4'd1: packet_magic[15:8] <= ioctl_dout;
					4'd2: packet_magic[23:16] <= ioctl_dout;
					4'd3: packet_magic[31:24] <= ioctl_dout;
					4'd4: packet_x[7:0] <= ioctl_dout;
					4'd5: packet_x[15:8] <= ioctl_dout;
					4'd6: packet_y[7:0] <= ioctl_dout;
					4'd7: packet_y[15:8] <= ioctl_dout;
					4'd8: packet_token <= ioctl_dout;
					default: ;
				endcase
			end

			if (!ioctl_download && was_download) begin
				if ((bytes_seen == 9'h1FF) && (packet_magic == MAGIC_A) &&
				    (packet_x[15:12] == 4'd0) && (packet_y[15:12] == 4'd0) &&
				    (packet_x[11:0] != 12'd0) && (packet_y[11:0] != 12'd0) &&
				    (packet_x <= (packet_y << 2)) &&
				    (packet_y <= (packet_x << 2))) begin
					aspect_x <= packet_x[11:0];
					aspect_y <= packet_y[11:0];
					aspect_token <= packet_token;
					aspect_valid <= 1'b1;
					aspect_commit <= 1'b1;
				end
			end
		end
	end
endmodule

`default_nettype wire
