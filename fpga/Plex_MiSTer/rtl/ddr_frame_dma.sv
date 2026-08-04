// Fabric DDR→DDR frame packer (option b): retire ARM sendDdrFrame memcpy.
//
// Copies frame_bytes of planar YUV420p from src_phys into bank_phys using the
// single HPS DDRAM port (f2sdram). Bounce BRAM holds one burst so RD then WE
// share the port without ARM CPU time (T_copy_arm ≈ 14.978 ms @720p24).
//
// Beat math (agreed terms — payload RATE, not CPU time):
//   R_req @720p24     = 33.1776 MB/s one direction (1382400 * 24)
//   combined R+W      = 66.3552 MB/s
//   clk_ddr           = 90 MHz, 8 B/beat peak = 720 MB/s
//   duty              ≈ 66.4/720 ≈ 9.2% of peak if fully fed
//   ideal copy time   = 2 * (frame_bytes/8) / 90e6  ≈ 3.84 ms/frame @720p
//     (<< T_copy_arm 14.978 ms; serial deficit 6.0 ms vanishes if this replaces memcpy)
//
// Default OFF: define FABRIC_FRAME_DMA only in research/sim builds.
// Product QSF must NOT set FABRIC_FRAME_DMA until parent device-proves it.
//
// M10K (EST, layout-stated — NOT the retracted "1280 B/block" premise):
//   bounce[DEPTH=128] × 64-bit = 8192 bits useful.
//   Native M10K max width is 40b (handbook); 64b needs ≥2 blocks in parallel.
//   Likely map: 2 × (256×32) → 2 M10K (depth 128 fits in 256; half depth spare).
//   Byte-wide 1K×8 arithmetic does NOT apply (this is a 64-bit burst bounce).
//   Unfitted — post-fit entity row is the only measurement that closes this.
// Budget: 2 of ~356 free M10K (parent nostub HIT 197/553).
//
// Does NOT ring the doorbell (w-mem owns mailbox ABI). done pulses when the
// bank payload is fully written; host/firmware may kick doorbell after.

`timescale 1ns / 1ps

module ddr_frame_dma #(
	parameter int BOUNCE_DEPTH = 128,
	parameter int DEFAULT_FRAME_BYTES = 1_382_400
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        start,
	input  wire [31:0] src_phys,
	input  wire [31:0] bank_phys,
	input  wire [31:0] frame_bytes,

	output reg         busy,
	output reg         done,
	output reg         err_align,
	output reg  [31:0] rd_beats,
	output reg  [31:0] wr_beats,
	output reg  [31:0] last_frame_bytes,

	input  wire        DDRAM_BUSY,
	output reg   [7:0] DDRAM_BURSTCNT,
	output reg  [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output reg         DDRAM_RD,
	output reg  [63:0] DDRAM_DIN,
	output reg   [7:0] DDRAM_BE,
	output reg         DDRAM_WE
);
	localparam int BW = (BOUNCE_DEPTH <= 2) ? 1 : $clog2(BOUNCE_DEPTH);

	reg [63:0] bounce [0:BOUNCE_DEPTH-1];
	reg [BW-1:0] bidx;
	reg [7:0]    bcount;

	reg [28:0] src_qw;
	reg [28:0] dst_qw;
	reg [31:0] qw_left;
	reg [7:0]  rsp_left;
	reg [7:0]  wr_left;

	localparam logic [2:0]
		ST_IDLE       = 3'd0,
		ST_RD_ISSUE   = 3'd1,
		ST_RD_COLLECT = 3'd2,
		ST_WR_ISSUE   = 3'd3,
		ST_WR_BEATS   = 3'd4,
		ST_DONE       = 3'd5;
	reg [2:0] st;

	wire [31:0] fb_eff = (frame_bytes == 32'd0) ? DEFAULT_FRAME_BYTES[31:0] : frame_bytes;
	wire align_ok = (src_phys[2:0] == 3'b000) && (bank_phys[2:0] == 3'b000) &&
	                (fb_eff[2:0] == 3'b000) && (fb_eff != 32'd0);

	function automatic [7:0] clip_burst(input [31:0] n);
		if (n == 32'd0)
			clip_burst = 8'd0;
		else if (n > BOUNCE_DEPTH[31:0])
			clip_burst = BOUNCE_DEPTH[7:0];
		else
			clip_burst = n[7:0];
	endfunction

	always @(posedge clk) begin
		if (reset) begin
			st <= ST_IDLE;
			busy <= 1'b0;
			done <= 1'b0;
			err_align <= 1'b0;
			rd_beats <= 32'd0;
			wr_beats <= 32'd0;
			last_frame_bytes <= 32'd0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_ADDR <= 29'd0;
			DDRAM_RD <= 1'b0;
			DDRAM_DIN <= 64'd0;
			DDRAM_BE <= 8'h00;
			DDRAM_WE <= 1'b0;
			bidx <= '0;
			bcount <= 8'd0;
			src_qw <= 29'd0;
			dst_qw <= 29'd0;
			qw_left <= 32'd0;
			rsp_left <= 8'd0;
			wr_left <= 8'd0;
		end else begin
			done <= 1'b0;
			DDRAM_RD <= 1'b0;
			DDRAM_WE <= 1'b0;
			DDRAM_BE <= 8'h00;

			case (st)
			ST_IDLE: begin
				busy <= 1'b0;
				if (start) begin
					if (!align_ok) begin
						err_align <= 1'b1;
						done <= 1'b1;
					end else begin
						err_align <= 1'b0;
						busy <= 1'b1;
						src_qw <= src_phys[31:3];
						dst_qw <= bank_phys[31:3];
						qw_left <= fb_eff >> 3;
						last_frame_bytes <= fb_eff;
						rd_beats <= 32'd0;
						wr_beats <= 32'd0;
						bidx <= '0;
						bcount <= 8'd0;
						st <= ST_RD_ISSUE;
					end
				end
			end

			ST_RD_ISSUE: begin
				if (qw_left == 32'd0) begin
					st <= ST_DONE;
				end else if (!DDRAM_BUSY) begin
					bcount <= clip_burst(qw_left);
					rsp_left <= clip_burst(qw_left);
					bidx <= '0;
					DDRAM_ADDR <= src_qw;
					DDRAM_BURSTCNT <= clip_burst(qw_left);
					DDRAM_RD <= 1'b1;
					st <= ST_RD_COLLECT;
				end
			end

			ST_RD_COLLECT: begin
				if (DDRAM_DOUT_READY && rsp_left != 8'd0) begin
					bounce[bidx] <= DDRAM_DOUT;
					bidx <= bidx + 1'b1;
					rsp_left <= rsp_left - 8'd1;
					rd_beats <= rd_beats + 32'd1;
					src_qw <= src_qw + 29'd1;
					qw_left <= qw_left - 32'd1;
					if (rsp_left == 8'd1) begin
						bidx <= '0;
						wr_left <= bcount;
						st <= ST_WR_ISSUE;
					end
				end
			end

			ST_WR_ISSUE: begin
				if (!DDRAM_BUSY) begin
					DDRAM_ADDR <= dst_qw;
					DDRAM_BURSTCNT <= wr_left;
					DDRAM_WE <= 1'b1;
					DDRAM_BE <= 8'hFF;
					DDRAM_DIN <= bounce[0];
					wr_beats <= wr_beats + 32'd1;
					dst_qw <= dst_qw + 29'd1;
					if (wr_left == 8'd1) begin
						wr_left <= 8'd0;
						st <= ST_RD_ISSUE;
					end else begin
						bidx <= {{(BW-1){1'b0}}, 1'b1};
						wr_left <= wr_left - 8'd1;
						st <= ST_WR_BEATS;
					end
				end
			end

			ST_WR_BEATS: begin
				if (!DDRAM_BUSY && wr_left != 8'd0) begin
					DDRAM_WE <= 1'b1;
					DDRAM_BE <= 8'hFF;
					DDRAM_DIN <= bounce[bidx];
					DDRAM_ADDR <= dst_qw;
					DDRAM_BURSTCNT <= 8'd1;
					bidx <= bidx + 1'b1;
					dst_qw <= dst_qw + 29'd1;
					wr_beats <= wr_beats + 32'd1;
					if (wr_left == 8'd1) begin
						wr_left <= 8'd0;
						st <= ST_RD_ISSUE;
					end else begin
						wr_left <= wr_left - 8'd1;
					end
				end
			end

			ST_DONE: begin
				busy <= 1'b0;
				done <= 1'b1;
				st <= ST_IDLE;
			end

			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule
