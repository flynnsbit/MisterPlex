// Sequential eighth-sample chroma interpolator (ITU-T H.264 8.4.2.2.2).
//
// In 4:2:0 a chroma sample spans two luma samples, so a motion vector in
// quarter-luma-sample units is already in eighth-chroma-sample units: the
// fractional parts are mvx & 7 and mvy & 7, and the integer chroma offset is
// mvx >>> 3 / mvy >>> 3.  Both are produced by the DPB fetch, which also
// edge-clamps every tap, so a vector pointing outside the picture replicates
// the border sample rather than reading garbage.
//
//   predC = ((8-xFrac)(8-yFrac)A + xFrac(8-yFrac)B
//          + (8-xFrac)yFrac C + xFrac*yFrac*D + 32) >> 6
//
// The 9x9 window is one sample wider and taller than the 8x8 block because the
// bilinear needs A..D at (x,y),(x+1,y),(x,y+1),(x+1,y+1).
//
// U and V share the schedule and run in lockstep.  The four weight products
// are computed once and broadcast to every lane and both planes, so the engine
// is LANES*4*2 small multipliers rather than the 128 the fully combinational
// form needs.
//
// THROUGHPUT
//   clk_sys is 20 MHz, and 1170 macroblocks at ~24 fps leaves 712 cycles per
//   macroblock for the whole decoder.  One output sample per cycle cost 64
//   cycles here.  That was not the critical path while luma took 368, but once
//   the luma engine retires a full-pel block in 16 cycles the chroma bilinear
//   becomes the thing holding P_Skip open, so it retires LANES columns per
//   cycle and takes the same integer-motion shortcut.
//
//   LANES = 4:  full-pel 8 cycles, otherwise 16, against 64 before.
//
// The samples read here are POST-deblocking reference samples out of the DPB.
// Intra prediction neighbour taps are a separate, PRE-deblocking path and
// never enter this module.

`default_nettype none

module h264_mc_chroma_epel #(
	// Output columns retired per cycle.  Must divide 8.
	parameter int LANES = 4
) (
	input  wire        clk,
	input  wire        reset,

	input  wire        start,
	input  wire [7:0]  ref_u [0:80],
	input  wire [7:0]  ref_v [0:80],
	input  wire [2:0]  frac_x,
	input  wire [2:0]  frac_y,

	output reg         busy,
	output reg         done,
	output reg  [7:0]  pred_u [0:63],
	output reg  [7:0]  pred_v [0:63]
);
	localparam int WIN_COLS = 9;
	localparam int NGRP     = 8 / LANES;

	reg [1:0] state;
	localparam [1:0] S_IDLE = 2'd0;
	localparam [1:0] S_RUN  = 2'd1;
	localparam [1:0] S_COPY = 2'd2;
	localparam [1:0] S_DONE = 2'd3;

	reg [3:0] grp;
	reg [3:0] row;

	// Integer chroma motion needs no interpolation at all, only the top-left
	// tap of each 2x2 neighbourhood.  P_Skip dominates the frame, so this is
	// worth the one extra state.
	wire full_pel = (frac_x == 3'd0) && (frac_y == 3'd0);

	// Bilinear weights.  xFrac/yFrac are 0..7 so every weight is 0..8 and every
	// product is 0..64; the four together always sum to exactly 64.
	wire [3:0] wx1 = {1'b0, frac_x};
	wire [3:0] wy1 = {1'b0, frac_y};
	wire [3:0] wx0 = 4'd8 - wx1;
	wire [3:0] wy0 = 4'd8 - wy1;
	wire [6:0] w00 = wx0 * wy0;
	wire [6:0] w10 = wx1 * wy0;
	wire [6:0] w01 = wx0 * wy1;
	wire [6:0] w11 = wx1 * wy1;

	// Window index for row r, column c of the 9x9 reference region.
	function automatic [6:0] cwix(input [3:0] r, input [3:0] c);
		cwix = 7'(r) * 7'd9 + 7'(c);
	endfunction

	// Column within an 8-wide output row.
	function automatic [2:0] ccix(input [3:0] c);
		ccix = c[2:0];
	endfunction

	wire [3:0] col_base = grp * LANES[3:0];

	function automatic [7:0] bilerp(input [7:0] a, input [7:0] b,
	                                input [7:0] c, input [7:0] d,
	                                input [6:0] k00, input [6:0] k10,
	                                input [6:0] k01, input [6:0] k11);
		reg [15:0] sum;
		begin
			// Max is 64*255 + 32 = 16352, so 16 bits never overflows.
			sum = k00 * a + k10 * b + k01 * c + k11 * d + 16'd32;
			bilerp = sum[13:6];
		end
	endfunction

	wire [7:0] u_out [0:LANES-1];
	wire [7:0] v_out [0:LANES-1];

	genvar gc;
	generate
		for (gc = 0; gc < LANES; gc = gc + 1) begin : gen_lane
			localparam int GC = gc;
			wire [3:0] lcol = col_base + GC[3:0];
			wire [6:0] b00 = cwix(row, lcol);
			wire [6:0] b01 = cwix(row, lcol + 4'd1);
			wire [6:0] b10 = cwix(row + 4'd1, lcol);
			wire [6:0] b11 = cwix(row + 4'd1, lcol + 4'd1);
			assign u_out[gc] = bilerp(ref_u[b00], ref_u[b01], ref_u[b10], ref_u[b11],
			                          w00, w10, w01, w11);
			assign v_out[gc] = bilerp(ref_v[b00], ref_v[b01], ref_v[b10], ref_v[b11],
			                          w00, w10, w01, w11);
		end
	endgenerate

	integer i;
	integer n;
	always @(posedge clk) begin
		if (reset) begin
			state <= S_IDLE;
			busy  <= 1'b0;
			done  <= 1'b0;
			grp   <= 4'd0;
			row   <= 4'd0;
			for (i = 0; i < 64; i = i + 1) begin
				pred_u[i] <= 8'd128;
				pred_v[i] <= 8'd128;
			end
		end else begin
			done <= 1'b0;
			case (state)
			S_IDLE: begin
				busy <= 1'b0;
				if (start) begin
					busy  <= 1'b1;
					grp   <= 4'd0;
					row   <= 4'd0;
					state <= full_pel ? S_COPY : S_RUN;
				end
			end
			// Integer motion: a whole 8-sample row of both planes per cycle.
			S_COPY: begin
				for (n = 0; n < 8; n = n + 1) begin
					pred_u[{row[2:0], n[2:0]}] <= ref_u[cwix(row, n[3:0])];
					pred_v[{row[2:0], n[2:0]}] <= ref_v[cwix(row, n[3:0])];
				end
				if (row == 4'd7) state <= S_DONE;
				else row <= row + 4'd1;
			end
			S_RUN: begin
				for (n = 0; n < LANES; n = n + 1) begin
					pred_u[{row[2:0], ccix(col_base + n[3:0])}] <= u_out[n];
					pred_v[{row[2:0], ccix(col_base + n[3:0])}] <= v_out[n];
				end
				if (grp == NGRP[3:0] - 4'd1) begin
					grp <= 4'd0;
					if (row == 4'd7) state <= S_DONE;
					else row <= row + 4'd1;
				end else begin
					grp <= grp + 4'd1;
				end
			end
			S_DONE: begin
				busy  <= 1'b0;
				done  <= 1'b1;
				state <= S_IDLE;
			end
			default: state <= S_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
