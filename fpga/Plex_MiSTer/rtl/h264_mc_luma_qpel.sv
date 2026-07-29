// Lane-parallel separable quarter-sample luma interpolator (ITU-T H.264 8.4.2.2.1).
//
// THROUGHPUT BUDGET -- why this module was widened
//   clk_sys is 20 MHz (rtl/pll/pll_0002.v output_clock_frequency0), not 100.
//   624x480 is 39x30 = 1170 macroblocks and the content is ~24 fps, so the
//   whole decoder gets 20e6 / (1170 * 24) = 712 cycles per macroblock for
//   every stage combined: reference fetch, prediction, residual,
//   reconstruction and the in-loop filter.
//
//   The first sequential version of this engine spent 6*16 priming cycles,
//   16*16 run cycles and 16 shift cycles = 368 cycles on luma prediction
//   alone, over half the entire macroblock budget, for one 16x16 partition.
//   It is not that the 6-tap needed six cycles -- it was already a one-cycle
//   shift-add dot product -- it is that only one output sample was retired
//   per cycle.
//
// WHAT CHANGED
//   1. LANES output columns retire per cycle instead of one.  The 6-tap is
//      shift-add only, so a lane costs adders, not DSPs or memory ports.
//   2. The b1 sliding row buffer is only maintained for the five sub-sample
//      positions that actually read the centre sample j.  Every other
//      position needs at most the horizontal 6-tap of the current output row
//      and the row below it, which are computed directly from the window.
//      That removes both the prime pass and the shift pass for 11 of the 16
//      positions.
//   3. Full-pel (frac_x == 0 && frac_y == 0) is a straight window copy and
//      retires a whole 16-sample row per cycle.  P_Skip is 79% of our
//      macroblocks and lands here whenever the predicted motion vector is
//      integer, so this is the single hottest path in the decoder.
//
//   Resulting schedule, with LANES = 4:
//     full-pel                        16 cycles
//     no centre sample (11 of 16)     16 * 4          =  64 cycles
//     centre sample    ( 5 of 16)     24 + 64 + 16    = 104 cycles
//   against 368 before.
//
// GEOMETRY
//   ref_win is the 21x21 POST-deblock reference region the DPB fetch
//   produced, raster order, already edge-clamped by h264_luma_ref_tap_addr so
//   motion vectors that point outside the picture replicate the border
//   sample.  The integer sample for output (x,y) is ref_win[(y+2)*21+(x+2)].
//
// SEPARABILITY AND THE DOUBLE-ROUNDING TRAP
//   b1(r,x) is the raw horizontal 6-tap at full precision, NOT rounded:
//     b1 = W[r][x] - 5W[r][x+1] + 20W[r][x+2] + 20W[r][x+3] - 5W[r][x+4] + W[r][x+5]
//   The half-sample b is Clip1((b1 + 16) >> 5), but the centre sample j is a
//   vertical 6-tap over the *unrounded* b1 values followed by a single
//   (j1 + 512) >> 10.  Rounding b1 before the vertical pass is the classic
//   conformance bug and is exactly what the b1 row buffer here exists to
//   avoid.  The direct-b1 shortcut below is bit-identical because brow[2] and
//   brow[3] always held the raw horizontal taps of window rows y+2 and y+3.

`default_nettype none

module h264_mc_luma_qpel #(
	// Output columns retired per cycle.  Must divide 16.
	parameter int LANES = 4
) (
	input  wire        clk,
	input  wire        reset,

	input  wire        start,
	input  wire [7:0]  ref_win [0:440],
	input  wire [1:0]  frac_x,
	input  wire [1:0]  frac_y,

	output reg         busy,
	output reg         done,
	output reg  [7:0]  pred [0:255]
);
	localparam int WIN_COLS = 21;
	localparam int NGRP     = 16 / LANES;

	// b1 sliding row buffer: raw horizontal taps of window rows y..y+5 for the
	// output row being emitted.  Only maintained when the centre sample is
	// actually read.
	reg signed [15:0] brow [0:5][0:15];
	reg signed [15:0] bnext [0:15];

	reg  [2:0] state;
	localparam [2:0] S_IDLE  = 3'd0;
	localparam [2:0] S_PRIME = 3'd1;
	localparam [2:0] S_RUN   = 3'd2;
	localparam [2:0] S_SHIFT = 3'd3;
	localparam [2:0] S_COPY  = 3'd4;
	localparam [2:0] S_DONE  = 3'd5;

	reg [4:0] grp;   // 0..NGRP-1 column group within a row
	reg [4:0] row;   // prime row 0..5, or output row 0..15

	// Latched at start so the schedule cannot change under a running block.
	reg [1:0] fx_r, fy_r;
	reg       use_j_r;

	// The centre sample j is the only value that needs vertical filtering over
	// the unrounded horizontal taps, i.e. the only reason to keep six rows of
	// b1 alive.  Positions f, i, j, k and q read it.
	wire use_j = (frac_x == 2'd2 && frac_y != 2'd0) ||
	             (frac_y == 2'd2 && frac_x != 2'd0);
	wire full_pel = (frac_x == 2'd0) && (frac_y == 2'd0);

	function automatic signed [15:0] s16(input [7:0] v);
		s16 = $signed({8'd0, v});
	endfunction

	// Window index for row r, column c of the 21x21 reference region.
	function automatic [8:0] wix(input [4:0] r, input [5:0] c);
		wix = 9'(r) * 9'd21 + 9'(c);
	endfunction

	// Column within a 16-wide row, for pred/brow/bnext.
	function automatic [3:0] cix(input [4:0] c);
		cix = c[3:0];
	endfunction

	// 6-tap (1,-5,20,20,-5,1).  Written as shift-adds so no DSP block is
	// consumed and the whole engine stays in fabric.
	function automatic signed [23:0] tap6(
		input signed [23:0] a0, input signed [23:0] a1, input signed [23:0] a2,
		input signed [23:0] a3, input signed [23:0] a4, input signed [23:0] a5);
		begin
			tap6 = a0 + a5
			     - ((a1 <<< 2) + a1)
			     - ((a4 <<< 2) + a4)
			     + ((a2 <<< 4) + (a2 <<< 2))
			     + ((a3 <<< 4) + (a3 <<< 2));
		end
	endfunction

	function automatic [7:0] clip1(input signed [23:0] v);
		begin
			if (v < 0) clip1 = 8'd0;
			else if (v > 24'sd255) clip1 = 8'd255;
			else clip1 = v[7:0];
		end
	endfunction

	function automatic [7:0] avg2(input [7:0] a, input [7:0] b);
		begin
			avg2 = 8'((({1'b0, a} + {1'b0, b} + 9'd1) >> 1));
		end
	endfunction

	// Horizontal raw 6-tap of window row r starting at output column c.
	function automatic signed [23:0] horz(input [4:0] r, input [4:0] c);
		begin
			horz = tap6(24'(s16(ref_win[wix(r, {1'b0, c} + 6'd0)])),
			            24'(s16(ref_win[wix(r, {1'b0, c} + 6'd1)])),
			            24'(s16(ref_win[wix(r, {1'b0, c} + 6'd2)])),
			            24'(s16(ref_win[wix(r, {1'b0, c} + 6'd3)])),
			            24'(s16(ref_win[wix(r, {1'b0, c} + 6'd4)])),
			            24'(s16(ref_win[wix(r, {1'b0, c} + 6'd5)])));
		end
	endfunction

	// Vertical raw 6-tap over integer window samples at window column c.
	function automatic signed [23:0] vert_int(input [4:0] y0, input [5:0] c);
		begin
			vert_int = tap6(24'(s16(ref_win[wix(y0 + 5'd0, c)])),
			                24'(s16(ref_win[wix(y0 + 5'd1, c)])),
			                24'(s16(ref_win[wix(y0 + 5'd2, c)])),
			                24'(s16(ref_win[wix(y0 + 5'd3, c)])),
			                24'(s16(ref_win[wix(y0 + 5'd4, c)])),
			                24'(s16(ref_win[wix(y0 + 5'd5, c)])));
		end
	endfunction

	wire [4:0] col_base = grp * LANES[4:0];

	// While priming, hr_row walks window rows 0..5 directly; while running it
	// stages window row y+6 for the next output row.  The last output row has
	// no row y+6, so clamp the address inside the 21x21 window even though the
	// staged value is discarded.
	wire [4:0] hr_row_raw = (state == S_PRIME) ? row : (row + 5'd6);
	wire [4:0] hr_row = (hr_row_raw > 5'd20) ? 5'd20 : hr_row_raw;

	// Per-lane datapath.  Every lane is the original single-column expression
	// with col replaced by col_base + lane, so the arithmetic is unchanged.
	wire signed [23:0] lane_hraw [0:LANES-1];
	wire [7:0]         lane_qpel [0:LANES-1];

	genvar gl;
	generate
		for (gl = 0; gl < LANES; gl = gl + 1) begin : gen_lane
			localparam int GL = gl;
			wire [4:0] lcol = col_base + GL[4:0];

			assign lane_hraw[gl] = horz(hr_row, lcol);

			// b1 of the output row and of the row below it.  Taken straight
			// from the window when the buffer is not being maintained; these
			// are the same raw taps brow[2] and brow[3] would have held.
			wire signed [23:0] b1 = use_j_r ? 24'($signed(brow[2][cix(lcol)]))
			                                : horz(row + 5'd2, lcol);
			wire signed [23:0] s1 = use_j_r ? 24'($signed(brow[3][cix(lcol)]))
			                                : horz(row + 5'd3, lcol);
			wire signed [23:0] j1 = tap6(24'(brow[0][cix(lcol)]), 24'(brow[1][cix(lcol)]),
			                             24'(brow[2][cix(lcol)]), 24'(brow[3][cix(lcol)]),
			                             24'(brow[4][cix(lcol)]), 24'(brow[5][cix(lcol)]));

			wire signed [23:0] h1 = vert_int(row, {1'b0, lcol} + 6'd2);
			wire signed [23:0] m1 = vert_int(row, {1'b0, lcol} + 6'd3);

			wire [7:0] pG = ref_win[wix(row + 5'd2, {1'b0, lcol} + 6'd2)];
			wire [7:0] pH = ref_win[wix(row + 5'd2, {1'b0, lcol} + 6'd3)];
			wire [7:0] pM = ref_win[wix(row + 5'd3, {1'b0, lcol} + 6'd2)];

			wire [7:0] sb = clip1((b1 + 24'sd16) >>> 5);
			wire [7:0] ss = clip1((s1 + 24'sd16) >>> 5);
			wire [7:0] sh = clip1((h1 + 24'sd16) >>> 5);
			wire [7:0] sm = clip1((m1 + 24'sd16) >>> 5);
			wire [7:0] sj = clip1((j1 + 24'sd512) >>> 10);

			reg [7:0] q;
			always @* begin
				case ({fy_r, fx_r})
				4'b0000: q = pG;                 // G
				4'b0001: q = avg2(pG, sb);       // a
				4'b0010: q = sb;                 // b
				4'b0011: q = avg2(sb, pH);       // c
				4'b0100: q = avg2(pG, sh);       // d
				4'b0101: q = avg2(sb, sh);       // e
				4'b0110: q = avg2(sb, sj);       // f
				4'b0111: q = avg2(sb, sm);       // g
				4'b1000: q = sh;                 // h
				4'b1001: q = avg2(sh, sj);       // i
				4'b1010: q = sj;                 // j
				4'b1011: q = avg2(sj, sm);       // k
				4'b1100: q = avg2(pM, sh);       // n
				4'b1101: q = avg2(sh, ss);       // p
				4'b1110: q = avg2(sj, ss);       // q
				default: q = avg2(sm, ss);       // r
				endcase
			end
			assign lane_qpel[gl] = q;
		end
	endgenerate

	integer i;
	integer k;
	integer n;
	always @(posedge clk) begin
		if (reset) begin
			state <= S_IDLE;
			busy  <= 1'b0;
			done  <= 1'b0;
			grp   <= 5'd0;
			row   <= 5'd0;
			fx_r  <= 2'd0;
			fy_r  <= 2'd0;
			use_j_r <= 1'b0;
			for (i = 0; i < 256; i = i + 1) pred[i] <= 8'd0;
			for (k = 0; k < 16; k = k + 1) begin
				bnext[k]   <= 16'sd0;
				brow[0][k] <= 16'sd0;
				brow[1][k] <= 16'sd0;
				brow[2][k] <= 16'sd0;
				brow[3][k] <= 16'sd0;
				brow[4][k] <= 16'sd0;
				brow[5][k] <= 16'sd0;
			end
		end else begin
			done <= 1'b0;
			case (state)
			S_IDLE: begin
				busy <= 1'b0;
				if (start) begin
					busy    <= 1'b1;
					row     <= 5'd0;
					grp     <= 5'd0;
					fx_r    <= frac_x;
					fy_r    <= frac_y;
					use_j_r <= use_j;
					// Full-pel needs no filtering at all, and without the
					// centre sample there is nothing for the prime pass to
					// build.
					state <= full_pel ? S_COPY : (use_j ? S_PRIME : S_RUN);
				end
			end

			// Straight 16-sample-per-cycle window copy for integer motion.
			S_COPY: begin
				for (n = 0; n < 16; n = n + 1)
					pred[{row[3:0], n[3:0]}] <=
						ref_win[wix(row + 5'd2, 6'(n[3:0]) + 6'd2)];
				if (row == 5'd15) state <= S_DONE;
				else row <= row + 5'd1;
			end

			S_PRIME: begin
				// Fill the sliding buffer with b1 rows 0..5 at full precision.
				for (n = 0; n < LANES; n = n + 1)
					brow[row[2:0]][cix(col_base + n[4:0])] <= 16'(lane_hraw[n]);
				if (grp == NGRP[4:0] - 5'd1) begin
					grp <= 5'd0;
					if (row == 5'd5) begin
						row   <= 5'd0;
						state <= S_RUN;
					end else begin
						row <= row + 5'd1;
					end
				end else begin
					grp <= grp + 5'd1;
				end
			end

			S_RUN: begin
				for (n = 0; n < LANES; n = n + 1)
					pred[{row[3:0], cix(col_base + n[4:0])}] <= lane_qpel[n];
				// Stage b1 row y+6 for the next output row.  Rows beyond 20 do
				// not exist, and the last output row never needs one.
				if (use_j_r && ((row + 5'd6) <= 5'd20)) begin
					for (n = 0; n < LANES; n = n + 1)
						bnext[cix(col_base + n[4:0])] <= 16'(lane_hraw[n]);
				end
				if (grp == NGRP[4:0] - 5'd1) begin
					grp <= 5'd0;
					// Without the centre sample there is no buffer to rotate,
					// so the row advance happens here and the shift pass is
					// skipped entirely.
					if (use_j_r) begin
						state <= S_SHIFT;
					end else if (row == 5'd15) begin
						state <= S_DONE;
					end else begin
						row <= row + 5'd1;
					end
				end else begin
					grp <= grp + 5'd1;
				end
			end

			S_SHIFT: begin
				// Deferred by one cycle so the last bnext lane has landed.
				if (row == 5'd15) begin
					state <= S_DONE;
				end else begin
					for (k = 0; k < 16; k = k + 1) begin
						brow[0][k] <= brow[1][k];
						brow[1][k] <= brow[2][k];
						brow[2][k] <= brow[3][k];
						brow[3][k] <= brow[4][k];
						brow[4][k] <= brow[5][k];
						brow[5][k] <= bnext[k];
					end
					row   <= row + 5'd1;
					state <= S_RUN;
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
