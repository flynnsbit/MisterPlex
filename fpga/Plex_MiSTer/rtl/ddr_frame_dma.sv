// Fabric DDR→DDR frame packer — publication engine (w-mem).
// Retires ARM sendDdrFrame memcpy (T_copy_arm ≈ 14.978 ms @720p24 measured).
//
// Copies frame_bytes planar YUV420p src_phys → bank_phys on the single HPS
// f2sdram port. Bounce holds one burst so RD then WE share the port.
//
// M10K COST (stated up front — layout, not bits/10240):
//   bounce[BOUNCE_DEPTH] × 64b, DEPTH=128 → 8192 bits logical.
//   Cyclone V M10K legal modes max width 40b (256×40). **64b is not native.**
//   Implementation: 2× parallel M10K (typ. 256×32 each), depth 128 used of 256.
//   => **2 M10K EST** (NOT 1). Control: nostub-poststrip1 fit entity rows for
//   line_buf_ram DATA_W=64 (yram 4992b→2 M10K; uram 2496b→2 M10K) — width-bound.
//   Bits-only 8192/10240=1 was the parent-corrected false premise; retracted.
//   ALM EST ~300–500 (FSM; UNVERIFIED fit). Budget free 356 M10K / 27_556 ALM.
//
// Beat math (payload RATE, not CPU time) — ideal solo port:
//   R_req @720p24     = 33.1776 MB/s one direction (1_382_400 * 24)
//   combined R+W      = 66.3552 MB/s
//   clk_ddr           = 90 MHz, 8 B/beat peak = 720 MB/s
//   duty              ≈ 66.4/720 ≈ 9.2% of peak if fully fed
//   ideal copy time   = 2 * (frame_bytes/8) / 90e6  ≈ 3.840 ms/frame @720p
//
// CONTENTION (present reader on same port) — PRE-REG then measure in TB:
//   present R_req @720p24 ≈ 33.18 MB/s → concurrent R+W+R ≈ 99.5 MB/s (13.8% peak)
//   PRE-REG T_copy_with_present ≈ 5.760 ms (1.5× ideal; scaled share)
//   Device sustained BW: UNVERIFIED (parent fit + HDMI capture only).
//
// Default OFF: `define FABRIC_FRAME_DMA only when integration enables it.
// Product QSF must NOT set FABRIC_FRAME_DMA until parent device-proves it.
//
// Does NOT ring the doorbell. done pulses when bank payload is fully written.

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

	// 128×64b → 2 M10K EST (2×256×32 parallel; see header). Keep M10K for burst BW.
	(* ramstyle = "no_rw_check, M10K" *) reg [63:0] bounce [0:BOUNCE_DEPTH-1];
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
