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
// U and V share the schedule and run in lockstep: one output sample of each
// per cycle, 64 cycles per block.  The weight products are computed once per
// cycle and shared between the two planes, so the whole engine is four small
// multipliers rather than the 128 the fully combinational form needs.
//
// The samples read here are POST-deblocking reference samples out of the DPB.
// Intra prediction neighbour taps are a separate, PRE-deblocking path and
// never enter this module.

`default_nettype none

module h264_mc_chroma_epel (
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

	reg [1:0] state;
	localparam [1:0] S_IDLE = 2'd0;
	localparam [1:0] S_RUN  = 2'd1;
	localparam [1:0] S_DONE = 2'd2;

	reg [3:0] col;
	reg [3:0] row;

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

	wire [7:0] base = row * WIN_COLS[7:0] + {4'd0, col};

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

	wire [7:0] u_out = bilerp(ref_u[base], ref_u[base + 8'd1],
	                          ref_u[base + WIN_COLS[7:0]],
	                          ref_u[base + WIN_COLS[7:0] + 8'd1],
	                          w00, w10, w01, w11);
	wire [7:0] v_out = bilerp(ref_v[base], ref_v[base + 8'd1],
	                          ref_v[base + WIN_COLS[7:0]],
	                          ref_v[base + WIN_COLS[7:0] + 8'd1],
	                          w00, w10, w01, w11);

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			state <= S_IDLE;
			busy  <= 1'b0;
			done  <= 1'b0;
			col   <= 4'd0;
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
					col   <= 4'd0;
					row   <= 4'd0;
					state <= S_RUN;
				end
			end
			S_RUN: begin
				pred_u[{row[2:0], col[2:0]}] <= u_out;
				pred_v[{row[2:0], col[2:0]}] <= v_out;
				if (col == 4'd7) begin
					col <= 4'd0;
					if (row == 4'd7) state <= S_DONE;
					else row <= row + 4'd1;
				end else begin
					col <= col + 4'd1;
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
