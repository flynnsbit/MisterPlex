// Fabric DDR→DDR frame packer — publication engine (w-mem).
//
// Avalon-MM / f2sdram (sys/f2sdram_safe_terminator.sv):
//   Do not break a burst. Under waitrequest hold ADDR/BURSTCNT/RD|WE/DIN/BE.
//   Write: ADDR+BURSTCNT constant for all beats; WE held until last accept.
//   Read: one-cycle RD pulse when !BUSY (product ddr_frame_store style);
//         then collect BURSTCNT DOUT_READY beats.
//   MAX_BURST default 8 (= arbiter3 quantum) so yield is inter-burst only.
//   ST_YIELD: one-cycle (or longer if busy) !RD&&!WE between WR and RD.
//
// M10K layout (republish after rd-duck fit correction):
//   old BOUNCE_DEPTH=128 ×64 forced M10K → 2 EST (64b width-bound; bits/10240 illegal)
//   rev BOUNCE_DEPTH=8   ×64 forced M10K → 2 EST (still width-bound, wastes 2 blocks)
//   rev BOUNCE_DEPTH=8   ×64 MLAB        → **0 M10K** (512b fits MLAB; chosen)
// Control: async_fifo ramstyle=MLAB → fit M10K=0 (nostub-poststrip1 L5259).
// ALM EST ~300–500. Does not ring doorbell; `done` is the handoff.

`timescale 1ns / 1ps

module ddr_frame_dma #(
	parameter int MAX_BURST = 8,
	parameter int BOUNCE_DEPTH = MAX_BURST,
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
	output wire        yield_window,
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
	localparam int MAX_BURST_CLIP = (MAX_BURST < 1) ? 1 :
	                                (MAX_BURST > 255) ? 255 : MAX_BURST;
	localparam int BOUNCE_CLIP = (BOUNCE_DEPTH < MAX_BURST_CLIP) ? BOUNCE_DEPTH : MAX_BURST_CLIP;

	(* ramstyle = "no_rw_check, MLAB" *) reg [63:0] bounce [0:BOUNCE_DEPTH-1];
	reg [BW-1:0] bidx;
	reg [28:0] src_qw, dst_qw;
	reg [31:0] qw_left;
	reg [28:0] cmd_addr;
	reg [7:0]  cmd_burst;
	reg [7:0]  rsp_left /* verilator public_flat_rd */;
	reg [7:0]  wr_left;
	reg [63:0] wr_data_hold;
	reg [1:0]  yield_cnt;

	localparam logic [2:0]
		ST_IDLE     = 3'd0,
		ST_RD_ISSUE = 3'd1,
		ST_RD_DATA  = 3'd2,
		ST_WR_SETUP = 3'd3,
		ST_WR_BURST = 3'd4,
		ST_YIELD    = 3'd5, // one-cycle !RD&&!WE gap for arbiter quantum
		ST_DONE     = 3'd6;
	reg [2:0] st /* verilator public_flat_rd */;
	reg [7:0] dbg_rsp /* verilator public_flat_rd */;

	wire [31:0] fb_eff = (frame_bytes == 32'd0) ? DEFAULT_FRAME_BYTES[31:0] : frame_bytes;
	wire align_ok = (src_phys[2:0] == 3'b000) && (bank_phys[2:0] == 3'b000) &&
	                (fb_eff[2:0] == 3'b000) && (fb_eff != 32'd0);
	assign yield_window = (st == ST_YIELD);

	function automatic [7:0] clip_burst(input [31:0] n);
		if (n == 32'd0) clip_burst = 8'd0;
		else if (n > BOUNCE_CLIP[31:0]) clip_burst = BOUNCE_CLIP[7:0];
		else clip_burst = n[7:0];
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
			src_qw <= 29'd0;
			dst_qw <= 29'd0;
			qw_left <= 32'd0;
			cmd_addr <= 29'd0;
			cmd_burst <= 8'd0;
			rsp_left <= 8'd0;
			wr_left <= 8'd0;
			wr_data_hold <= 64'd0;
			yield_cnt <= 2'd0;
		end else begin
			done <= 1'b0;

			case (st)
			ST_IDLE: begin
				busy <= 1'b0;
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
				DDRAM_BE <= 8'h00;
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
						st <= ST_RD_ISSUE;
					end
				end
			end

			// One-cycle RD when !BUSY (product ddr_frame_store style).
			// Caller/arbiter must hold grant across the pulse+response window.
			ST_RD_ISSUE: begin
				DDRAM_WE <= 1'b0;
				DDRAM_BE <= 8'h00;
				DDRAM_RD <= 1'b0;
				if (qw_left == 32'd0) begin
					st <= ST_DONE;
				end else if (!DDRAM_BUSY) begin
					cmd_burst <= clip_burst(qw_left);
					cmd_addr <= src_qw;
					DDRAM_ADDR <= src_qw;
					DDRAM_BURSTCNT <= clip_burst(qw_left);
					DDRAM_RD <= 1'b1;
					bidx <= '0;
					rsp_left <= clip_burst(qw_left);
					st <= ST_RD_DATA;
				end
			end

			ST_RD_DATA: begin
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
				DDRAM_BE <= 8'h00;
				DDRAM_ADDR <= cmd_addr;
				DDRAM_BURSTCNT <= cmd_burst;
				if (DDRAM_DOUT_READY && rsp_left != 8'd0) begin
					bounce[bidx] <= DDRAM_DOUT;
					rd_beats <= rd_beats + 32'd1;
					src_qw <= src_qw + 29'd1;
					qw_left <= qw_left - 32'd1;
					if (rsp_left == 8'd1) begin
						rsp_left <= 8'd0;
						st <= ST_WR_SETUP;
					end else begin
						bidx <= bidx + 1'b1;
						rsp_left <= rsp_left - 8'd1;
					end
				end
			end

			// Settle bounce[] NBA; latch WR constants + first DIN.
			ST_WR_SETUP: begin
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
				DDRAM_BE <= 8'h00;
				cmd_addr <= dst_qw;
				wr_left <= cmd_burst;
				bidx <= '0;
				wr_data_hold <= bounce[0];
				DDRAM_ADDR <= dst_qw;
				DDRAM_BURSTCNT <= cmd_burst;
				DDRAM_DIN <= bounce[0];
				st <= ST_WR_BURST;
			end

			// Write burst: constant ADDR/BURSTCNT; hold all under BUSY.
			ST_WR_BURST: begin
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= (wr_left != 8'd0);
				DDRAM_BE <= 8'hFF;
				DDRAM_ADDR <= cmd_addr;
				DDRAM_BURSTCNT <= cmd_burst;
				DDRAM_DIN <= wr_data_hold;

				if (wr_left != 8'd0 && !DDRAM_BUSY) begin
					wr_beats <= wr_beats + 32'd1;
					dst_qw <= dst_qw + 29'd1;
					if (wr_left == 8'd1) begin
						wr_left <= 8'd0;
						// WE stays 1 this accept cycle (pre-NBA wr_left).
						// Enter YIELD next; hold ≥2 clean !WE cycles so arbiter
						// wr_lock can drop after the last beat.
						bidx <= '0;
						yield_cnt <= 2'd0;
						st <= ST_YIELD;
					end else begin
						wr_left <= wr_left - 8'd1;
						bidx <= bidx + 1'b1;
						wr_data_hold <= bounce[bidx + 1'b1];
					end
				end
			end

			// Clean gap: no RD/WE for ≥2 cycles (arb wr_lock scrub + m0 quantum).
			// If m2_busy (yielded away), freeze count until grant returns.
			ST_YIELD: begin
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
				DDRAM_BE <= 8'h00;
				if (!DDRAM_BUSY) begin
					if (yield_cnt >= 2'd1)
						st <= ST_RD_ISSUE;
					else
						yield_cnt <= yield_cnt + 2'd1;
				end
			end

			ST_DONE: begin
				busy <= 1'b0;
				done <= 1'b1;
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
				DDRAM_BE <= 8'h00;
				st <= ST_IDLE;
			end

			default: begin
				st <= ST_IDLE;
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
			end
			endcase
		end
	end
endmodule
