// Sequential separable quarter-sample luma interpolator (ITU-T H.264 8.4.2.2.1).
//
// WHY SEQUENTIAL
//   h264_luma_qpel_block_16x16 is arithmetically correct but computes all 256
//   output samples, in all 16 sub-sample positions, as one combinational
//   cloud.  frac_x/frac_y are runtime inputs, so every position's datapath is
//   instantiated and then muxed; the centre position alone is six 6-tap
//   horizontal filters feeding a 6-tap vertical filter, per output sample.
//   That is on the order of a thousand filter units with no pipelining.  This
//   module computes the identical result with one filter datapath reused over
//   352 cycles, which is comfortably inside the reference-window fetch time
//   the DDR DPB already costs.
//
// GEOMETRY
//   ref_win is the 21x21 POST-deblock reference region the DPB fetch produced,
//   raster order, already edge-clamped by h264_luma_ref_tap_addr so motion
//   vectors that point outside the picture replicate the border sample.
//   The integer sample for output (x,y) is ref_win[(y+2)*21 + (x+2)].
//
// SEPARABILITY AND THE DOUBLE-ROUNDING TRAP
//   b1(r,x) is the raw horizontal 6-tap at full precision, NOT rounded:
//     b1 = W[r][x] - 5W[r][x+1] + 20W[r][x+2] + 20W[r][x+3] - 5W[r][x+4] + W[r][x+5]
//   The half-sample b is Clip1((b1 + 16) >> 5), but the centre sample j is a
//   vertical 6-tap over the *unrounded* b1 values followed by a single
//   (j1 + 512) >> 10.  Rounding b1 before the vertical pass is the classic
//   conformance bug and is exactly what the sliding b1 row buffer here exists
//   to avoid.
//
// SCHEDULE
//   PRIME : 6 rows x 16 columns of b1 into a 6-deep sliding row buffer.
//   RUN   : one output sample per cycle, 16 columns x 16 rows.  While row y is
//           emitted, b1 row y+6 is computed into a staging row, and the buffer
//           shifts at the end of the row.  Output row y needs window rows
//           y..y+5 and b1 rows y..y+5, so the buffer never has to look back.

`default_nettype none

module h264_mc_luma_qpel (
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

	// b1 sliding row buffer: rows y..y+5 for the output row being emitted.
	reg signed [15:0] brow [0:5][0:15];
	reg signed [15:0] bnext [0:15];

	reg  [2:0] state;
	localparam [2:0] S_IDLE  = 3'd0;
	localparam [2:0] S_PRIME = 3'd1;
	localparam [2:0] S_RUN   = 3'd2;
	localparam [2:0] S_SHIFT = 3'd3;
	localparam [2:0] S_DONE  = 3'd4;

	reg [4:0] col;   // 0..15 within a row (also 0..15 while priming)
	reg [4:0] row;   // prime row 0..5, or output row 0..15

	function automatic signed [15:0] s16(input [7:0] v);
		s16 = $signed({8'd0, v});
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
			avg2 = ({1'b0, a} + {1'b0, b} + 9'd1) >> 1;
		end
	endfunction

	// ---- horizontal raw 6-tap of window row r at output column c
	// Combinational; r/c come from the current schedule position.
	wire [4:0] hr_row_raw = (state == S_PRIME) ? row : (row + 5'd6);
	// The last output row has no row y+6 to stage; clamp so the address never
	// leaves the 21x21 window even though the result is discarded.
	wire [4:0] hr_row = (hr_row_raw > 5'd20) ? 5'd20 : hr_row_raw;
	wire [4:0] hr_col = col;
	wire signed [15:0] hraw =
		16'(tap6(24'(s16(ref_win[hr_row * WIN_COLS + hr_col + 0])),
		         24'(s16(ref_win[hr_row * WIN_COLS + hr_col + 1])),
		         24'(s16(ref_win[hr_row * WIN_COLS + hr_col + 2])),
		         24'(s16(ref_win[hr_row * WIN_COLS + hr_col + 3])),
		         24'(s16(ref_win[hr_row * WIN_COLS + hr_col + 4])),
		         24'(s16(ref_win[hr_row * WIN_COLS + hr_col + 5]))));

	// ---- vertical 6-tap over integer samples at window column c
	// h uses column x+2, m (the half sample one integer column right) uses x+3.
	function automatic signed [23:0] vert_int(input [4:0] y0, input [5:0] c);
		begin
			vert_int = tap6(24'(s16(ref_win[(y0 + 0) * WIN_COLS + c])),
			                24'(s16(ref_win[(y0 + 1) * WIN_COLS + c])),
			                24'(s16(ref_win[(y0 + 2) * WIN_COLS + c])),
			                24'(s16(ref_win[(y0 + 3) * WIN_COLS + c])),
			                24'(s16(ref_win[(y0 + 4) * WIN_COLS + c])),
			                24'(s16(ref_win[(y0 + 5) * WIN_COLS + c])));
		end
	endfunction

	wire signed [23:0] h1 = vert_int(row, {1'b0, col} + 6'd2);
	wire signed [23:0] m1 = vert_int(row, {1'b0, col} + 6'd3);

	// ---- vertical 6-tap over the UNROUNDED b1 column: the centre sample.
	wire signed [23:0] j1 = tap6(24'(brow[0][col[3:0]]), 24'(brow[1][col[3:0]]),
	                             24'(brow[2][col[3:0]]), 24'(brow[3][col[3:0]]),
	                             24'(brow[4][col[3:0]]), 24'(brow[5][col[3:0]]));

	// b is the horizontal half on the output row, s the one on the row below.
	wire signed [23:0] b1 = 24'(brow[2][col[3:0]]);
	wire signed [23:0] s1 = 24'(brow[3][col[3:0]]);

	wire [7:0] pG = ref_win[(row + 5'd2) * WIN_COLS + col + 5'd2];
	wire [7:0] pH = ref_win[(row + 5'd2) * WIN_COLS + col + 5'd3];
	wire [7:0] pM = ref_win[(row + 5'd3) * WIN_COLS + col + 5'd2];

	wire [7:0] sb = clip1((b1 + 24'sd16) >>> 5);
	wire [7:0] ss = clip1((s1 + 24'sd16) >>> 5);
	wire [7:0] sh = clip1((h1 + 24'sd16) >>> 5);
	wire [7:0] sm = clip1((m1 + 24'sd16) >>> 5);
	wire [7:0] sj = clip1((j1 + 24'sd512) >>> 10);

	reg [7:0] qpel;
	always @* begin
		case ({frac_y, frac_x})
		4'b0000: qpel = pG;                 // G
		4'b0001: qpel = avg2(pG, sb);       // a
		4'b0010: qpel = sb;                 // b
		4'b0011: qpel = avg2(sb, pH);       // c
		4'b0100: qpel = avg2(pG, sh);       // d
		4'b0101: qpel = avg2(sb, sh);       // e
		4'b0110: qpel = avg2(sb, sj);       // f
		4'b0111: qpel = avg2(sb, sm);       // g
		4'b1000: qpel = sh;                 // h
		4'b1001: qpel = avg2(sh, sj);       // i
		4'b1010: qpel = sj;                 // j
		4'b1011: qpel = avg2(sj, sm);       // k
		4'b1100: qpel = avg2(pM, sh);       // n
		4'b1101: qpel = avg2(sh, ss);       // p
		4'b1110: qpel = avg2(sj, ss);       // q
		default: qpel = avg2(sm, ss);       // r
		endcase
	end

	integer i;
	integer k;
	always @(posedge clk) begin
		if (reset) begin
			state <= S_IDLE;
			busy  <= 1'b0;
			done  <= 1'b0;
			col   <= 5'd0;
			row   <= 5'd0;
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
					busy  <= 1'b1;
					state <= S_PRIME;
					row   <= 5'd0;
					col   <= 5'd0;
				end
			end

			S_PRIME: begin
				// Fill the sliding buffer with b1 rows 0..5 at full precision.
				brow[row[2:0]][col[3:0]] <= hraw;
				if (col == 5'd15) begin
					col <= 5'd0;
					if (row == 5'd5) begin
						row   <= 5'd0;
						state <= S_RUN;
					end else begin
						row <= row + 5'd1;
					end
				end else begin
					col <= col + 5'd1;
				end
			end

			S_RUN: begin
				pred[{row[3:0], col[3:0]}] <= qpel;
				// Stage b1 row y+6 for the next output row.  Rows beyond 20 do
				// not exist, and the last output row never needs one.
				if ((row + 5'd6) <= 5'd20) bnext[col[3:0]] <= hraw;
				if (col == 5'd15) begin
					col   <= 5'd0;
					state <= S_SHIFT;
				end else begin
					col <= col + 5'd1;
				end
			end

			S_SHIFT: begin
				// Deferred by one cycle so bnext[15] has landed.
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
