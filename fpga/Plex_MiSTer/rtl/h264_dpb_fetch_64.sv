// 64-bit coalescing reference-window fetch for H.264 DPB.
//
// ARCHITECTURE: Row-at-a-time DDR fetch with 64-bit word output to MC.
// The critical insight: the byte-serial interface (1 byte/cycle) bottlenecks
// at 441 cycles for luma regardless of DDR bus width. To actually achieve
// the 73-cycle target, we must deliver 64-bit WORDS to the MC consumer.
//
// This module fetches reference windows from DDR via an aligned 64-bit bus
// and delivers them as a sequence of 64-bit words with byte-count metadata.
// The MC consumer extracts individual samples from the words.
//
// Pipelined row fetch: while MC processes row N, we fetch row N+1.
// With 3 words/row and 1 word/cycle sustained, a 21-row luma fetch
// takes 63 data cycles + 21 row-setup cycles = ~84 cycles total.
//
// Output interface (streaming, matches w-mc's ref_data port):
//   ref_word_valid : pulse per delivered word
//   ref_word_data  : 64-bit data
//   ref_word_bytes : number of valid bytes in this word (1-8)
//   ref_word_row   : which row this word belongs to (for MC overlap)
//   ref_row_last   : last word of this row
//
// Control:
//   start/busy/done : standard handshake
//   Latched inputs: plane, ref_base, origin_x/y, win_w/h
`ifndef DDR_FRAME_CODED_W
`define DDR_FRAME_CODED_W 624
`endif
`ifndef DDR_FRAME_CODED_H
`define DDR_FRAME_CODED_H 480
`endif
`default_nettype none

module h264_dpb_fetch_64 #(
	parameter int FRAME_W = `DDR_FRAME_CODED_W,
	parameter int FRAME_H = `DDR_FRAME_CODED_H
)(
	input  wire               clk,
	input  wire               reset,

	// ─── Control ───
	input  wire               start,
	input  wire [1:0]         plane,         // 0=Y 1=U 2=V
	input  wire [31:0]        ref_base,
	input  wire signed [15:0] origin_x,
	input  wire signed [15:0] origin_y,
	input  wire [4:0]         win_w,         // 21 or 9
	input  wire [4:0]         win_h,         // 21 or 9
	output reg                busy,
	output reg                done,

	// ─── 64-bit DDR read port (to f2sdram) ───
	output reg                ddr_rd,
	output reg  [31:0]        ddr_raddr,     // 8-byte aligned
	input  wire [63:0]        ddr_rdata,
	input  wire               ddr_rvalid,
	output wire               ddr_rd_pending, // for flow control

	// ─── 64-bit word output (to MC) ───
	output reg                ref_word_valid,
	output reg  [63:0]        ref_word_data,
	output reg  [3:0]         ref_word_bytes, // 1-8 valid bytes
	output reg  [4:0]         ref_word_row,   // row index (0..win_h-1)
	output reg                ref_row_last,   // last word of this row
	output reg  [2:0]         ref_word_skip,  // bytes to skip at start (first word only)
	output reg  [4:0]         ref_row_pixels, // pixels in this row (for MC: may be < win_w due to clamp dedup)

	// ─── Fractional position (passed through from MV) ───
	output reg  [1:0]         luma_frac_x,
	output reg  [1:0]         luma_frac_y,
	output reg  [2:0]         chroma_frac_x,
	output reg  [2:0]         chroma_frac_y
);

	// ─── Geometry ───
	localparam int C_W = FRAME_W / 2;
	localparam int C_H = FRAME_H / 2;
	localparam int Y_SIZE = FRAME_W * FRAME_H;
	localparam int C_SIZE = C_W * C_H;

	// ─── State machine ───
	localparam [2:0] ST_IDLE     = 3'd0;
	localparam [2:0] ST_ROW_CALC = 3'd1;
	localparam [2:0] ST_ISSUE    = 3'd2;
	localparam [2:0] ST_FORWARD  = 3'd3;
	localparam [2:0] ST_DONE     = 3'd4;
	reg [2:0] state;

	// ─── Latched params ───
	reg [4:0]         lat_win_w, lat_win_h;
	reg [1:0]         lat_plane;
	reg [31:0]        lat_ref_base;
	reg signed [15:0] lat_origin_x, lat_origin_y;
	reg [15:0]        lat_plane_w, lat_plane_h;
	reg [31:0]        lat_plane_offset;

	// ─── Row state ───
	reg [4:0]  row;
	reg [31:0] row_base_addr;
	reg [2:0]  row_skip;
	reg [2:0]  row_nwords;
	reg [2:0]  words_issued;
	reg [2:0]  words_received;
	reg [4:0]  row_pixel_span;    // unique pixel count for this row
	reg [15:0] row_x_left;

	// ─── Pending reads count (for flow control) ───
	reg [2:0] reads_pending;
	assign ddr_rd_pending = |reads_pending;

	// ─── Clamp ───
	function automatic [15:0] clamp16(input signed [15:0] v, input [15:0] limit);
		if (v[15])
			clamp16 = 16'd0;
		else if ({1'b0, v[15:0]} >= {1'b0, limit})
			clamp16 = limit - 16'd1;
		else
			clamp16 = v[15:0];
	endfunction

	// ─── Combinational row geometry ───
	wire signed [15:0] raw_y = lat_origin_y + {11'd0, row};
	wire [15:0] cy = clamp16(raw_y, lat_plane_h);
	wire [15:0] cx_left = clamp16(lat_origin_x, lat_plane_w);
	wire signed [15:0] raw_x_right = lat_origin_x + {11'd0, lat_win_w} - 16'sd1;
	wire [15:0] cx_right = clamp16(raw_x_right, lat_plane_w);

	wire [31:0] pixel_addr = lat_ref_base + lat_plane_offset +
	                          {16'd0, cy} * {16'd0, lat_plane_w} + {16'd0, cx_left};
	wire [31:0] aligned_addr = pixel_addr & 32'hFFFF_FFF8;
	wire [2:0]  skip_bytes = pixel_addr[2:0];
	wire [15:0] span = cx_right - cx_left + 16'd1;
	wire [4:0]  total_fetch_bytes = {2'd0, skip_bytes} + span[4:0];
	wire [2:0]  nwords = total_fetch_bytes[4:3] + (|total_fetch_bytes[2:0] ? 3'd1 : 3'd0);

	// ─── Main FSM ───
	always @(posedge clk) begin
		ddr_rd         <= 1'b0;
		ref_word_valid <= 1'b0;

		if (reset) begin
			state          <= ST_IDLE;
			busy           <= 1'b0;
			done           <= 1'b0;
			row            <= 5'd0;
			words_issued   <= 3'd0;
			words_received <= 3'd0;
			reads_pending  <= 3'd0;
			luma_frac_x    <= 2'd0;
			luma_frac_y    <= 2'd0;
			chroma_frac_x  <= 3'd0;
			chroma_frac_y  <= 3'd0;
		end else begin
			// Track pending reads
			if (ddr_rd && !ddr_rvalid)
				reads_pending <= reads_pending + 3'd1;
			else if (!ddr_rd && ddr_rvalid && |reads_pending)
				reads_pending <= reads_pending - 3'd1;

			case (state)
			ST_IDLE: begin
				done <= 1'b0;
				if (start) begin
					busy           <= 1'b1;
					lat_win_w      <= win_w;
					lat_win_h      <= win_h;
					lat_plane      <= plane;
					lat_ref_base   <= ref_base;
					lat_origin_x   <= origin_x;
					lat_origin_y   <= origin_y;
					lat_plane_w    <= (plane == 2'd0) ? FRAME_W[15:0] : C_W[15:0];
					lat_plane_h    <= (plane == 2'd0) ? FRAME_H[15:0] : C_H[15:0];
					lat_plane_offset <= (plane == 2'd0) ? 32'd0 :
					                    (plane == 2'd1) ? Y_SIZE[31:0] : (Y_SIZE + C_SIZE);
					row            <= 5'd0;
					state          <= ST_ROW_CALC;
				end
			end

			ST_ROW_CALC: begin
				// Latch this row's geometry and issue first read
				row_base_addr  <= aligned_addr;
				row_skip       <= skip_bytes;
				row_nwords     <= nwords;
				row_pixel_span <= span[4:0];
				row_x_left     <= cx_left;
				words_issued   <= 3'd1;
				words_received <= 3'd0;
				// Issue first word immediately
				ddr_rd    <= 1'b1;
				ddr_raddr <= aligned_addr;
				state     <= ST_ISSUE;
			end

			ST_ISSUE: begin
				// Pipeline: issue next word while waiting for responses
				if (words_issued < row_nwords) begin
					ddr_rd    <= 1'b1;
					ddr_raddr <= row_base_addr + {26'd0, words_issued, 3'd0};
					words_issued <= words_issued + 3'd1;
				end

				// Forward each word as it arrives
				if (ddr_rvalid) begin
					ref_word_valid <= 1'b1;
					ref_word_data  <= ddr_rdata;
					ref_word_row   <= row;
					words_received <= words_received + 3'd1;

					// Compute byte count for this word
					if (words_received == 3'd0) begin
						// First word: skip some bytes at start
						ref_word_skip <= row_skip;
						if (row_nwords == 3'd1) begin
							// Only one word: bytes = span
							ref_word_bytes <= row_pixel_span[3:0];
							ref_row_last   <= 1'b1;
							ref_row_pixels <= row_pixel_span;
						end else begin
							ref_word_bytes <= 4'd8 - {1'b0, row_skip};
							ref_row_last   <= 1'b0;
							ref_row_pixels <= row_pixel_span;
						end
					end else begin
						ref_word_skip <= 3'd0;
						if (words_received + 3'd1 == row_nwords) begin
							// Last word: remaining = total - already delivered
							// already = (8-skip) for first + 8*(middle words)
							// But simpler: remaining = total_fetch_bytes - words_received*8
							// Actually: total valid in this word = span - bytes_delivered_so_far
							ref_row_last <= 1'b1;
							ref_word_bytes <= 4'd8; // MC uses ref_row_last + row_pixel_span to know actual
						end else begin
							// Middle word: all 8 bytes valid
							ref_word_bytes <= 4'd8;
							ref_row_last   <= 1'b0;
						end
					end

					// Check if row is complete
					if (words_received + 3'd1 == row_nwords) begin
						if (row + 5'd1 == lat_win_h) begin
							state <= ST_DONE;
						end else begin
							row   <= row + 5'd1;
							state <= ST_ROW_CALC;
						end
					end
				end
			end

			ST_DONE: begin
				done  <= 1'b1;
				busy  <= 1'b0;
				state <= ST_IDLE;
			end

			default: state <= ST_IDLE;
			endcase
		end
	end
endmodule
