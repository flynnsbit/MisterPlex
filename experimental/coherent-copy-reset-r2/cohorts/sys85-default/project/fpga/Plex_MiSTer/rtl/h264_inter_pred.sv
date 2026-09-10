`default_nettype none

module h264_mv_pred_16x16 (
	input  wire               avail_a,
	input  wire               avail_b,
	input  wire               avail_c,
	input  wire               avail_d,
	input  wire               intra_a,
	input  wire               intra_b,
	input  wire               intra_c,
	input  wire               intra_d,
	input  wire signed [15:0] mv_a_x,
	input  wire signed [15:0] mv_a_y,
	input  wire signed [15:0] mv_b_x,
	input  wire signed [15:0] mv_b_y,
	input  wire signed [15:0] mv_c_x,
	input  wire signed [15:0] mv_c_y,
	input  wire signed [15:0] mv_d_x,
	input  wire signed [15:0] mv_d_y,
	input  wire signed [15:0] mvd_x,
	input  wire signed [15:0] mvd_y,
	input  wire               p_skip,
	output wire signed [15:0] pred_x,
	output wire signed [15:0] pred_y,
	output wire signed [15:0] mv_x,
	output wire signed [15:0] mv_y,
	output wire               skip_zero
);
	// Availability is spatial/slice availability, not "has an inter MV".
	// An available intra C must not be replaced with D.
	wire match_a = avail_a && !intra_a;
	wire match_b = avail_b && !intra_b;
	wire match_c = avail_c ? !intra_c : (avail_d && !intra_d);
	wire signed [15:0] cand_c_x = match_c ? (avail_c ? mv_c_x : mv_d_x) : 16'sd0;
	wire signed [15:0] cand_c_y = match_c ? (avail_c ? mv_c_y : mv_d_y) : 16'sd0;
	wire [1:0] match_count = {1'b0, match_a} + {1'b0, match_b} + {1'b0, match_c};

	function automatic signed [15:0] min2(input signed [15:0] a, input signed [15:0] b);
		min2 = (a < b) ? a : b;
	endfunction

	function automatic signed [15:0] max2(input signed [15:0] a, input signed [15:0] b);
		max2 = (a > b) ? a : b;
	endfunction

	function automatic signed [15:0] median3(
		input signed [15:0] a,
		input signed [15:0] b,
		input signed [15:0] c
	);
		// Three independent signed comparisons select the actual middle
		// operand, including signed16 extremes, without a sum/min/max chain.
		median3 = (a > b) ? ((b > c) ? b : ((a > c) ? c : a)) :
		                      ((a > c) ? a : ((b > c) ? c : b));
	endfunction

	function automatic signed [15:0] pred_one(
		input               aa,
		input               bb,
		input               cc,
		input signed [15:0] a,
		input signed [15:0] b,
		input signed [15:0] c
	);
		begin
			if (match_count == 2'd0) pred_one = 16'sd0;
			else if (match_count == 2'd1) pred_one = aa ? a : (bb ? b : c);
			else pred_one = median3(aa ? a : 16'sd0, bb ? b : 16'sd0, cc ? c : 16'sd0);
		end
	endfunction

	wire signed [15:0] median_x = pred_one(match_a, match_b, match_c, mv_a_x, mv_b_x, cand_c_x);
	wire signed [15:0] median_y = pred_one(match_a, match_b, match_c, mv_a_y, mv_b_y, cand_c_y);
	assign skip_zero = p_skip && (!avail_a || !avail_b ||
	                              (match_a && (mv_a_x == 16'sd0) && (mv_a_y == 16'sd0)) ||
	                              (match_b && (mv_b_x == 16'sd0) && (mv_b_y == 16'sd0)));
	assign pred_x = skip_zero ? 16'sd0 : median_x;
	assign pred_y = skip_zero ? 16'sd0 : median_y;
	assign mv_x = p_skip ? pred_x : pred_x + mvd_x;
	assign mv_y = p_skip ? pred_y : pred_y + mvd_y;
endmodule

module h264_luma_qpel_sample (
	input  wire [7:0] ref_pix [0:80],
	input  wire [1:0] frac_x,
	input  wire [1:0] frac_y,
	output reg  [7:0] sample
);
	function automatic integer clip1(input integer v);
		begin
			if (v < 0) clip1 = 0;
			else if (v > 255) clip1 = 255;
			else clip1 = v;
		end
	endfunction

	function automatic integer pix(input integer r, input integer c);
		pix = {24'd0, ref_pix[r * 9 + c]};
	endfunction

	function automatic integer avg2(input integer a, input integer b);
		avg2 = (a + b + 1) >>> 1;
	endfunction

	function automatic integer hraw(input integer row, input integer col);
		hraw = pix(row, col - 2) - 5 * pix(row, col - 1) +
		       20 * pix(row, col) + 20 * pix(row, col + 1) -
		       5 * pix(row, col + 2) + pix(row, col + 3);
	endfunction

	function automatic integer half_h(input integer rowoff, input integer coloff);
		half_h = clip1((hraw(4 + rowoff, 4 + coloff) + 16) >>> 5);
	endfunction

	function automatic integer half_v(input integer rowoff, input integer coloff);
		integer col;
		begin
			col = 4 + coloff;
			half_v = clip1((pix(2 + rowoff, col) - 5 * pix(3 + rowoff, col) +
			                20 * pix(4 + rowoff, col) + 20 * pix(5 + rowoff, col) -
			                5 * pix(6 + rowoff, col) + pix(7 + rowoff, col) + 16) >>> 5);
		end
	endfunction

	function automatic integer half_c(input integer rowoff, input integer coloff);
		integer sum;
		integer row;
		integer col;
		begin
			row = 4 + rowoff;
			col = 4 + coloff;
			sum = hraw(row - 2, col) - 5 * hraw(row - 1, col) +
			      20 * hraw(row, col) + 20 * hraw(row + 1, col) -
			      5 * hraw(row + 2, col) + hraw(row + 3, col);
			half_c = clip1((sum + 512) >>> 10);
		end
	endfunction

	always @* begin
		integer v;
		case ({frac_y, frac_x})
			4'b0000: begin v = pix(4, 4); sample = v[7:0]; end
			4'b0001: begin v = avg2(pix(4, 4), half_h(0, 0)); sample = v[7:0]; end
			4'b0010: begin v = half_h(0, 0); sample = v[7:0]; end
			4'b0011: begin v = avg2(half_h(0, 0), pix(4, 5)); sample = v[7:0]; end
			4'b0100: begin v = avg2(pix(4, 4), half_v(0, 0)); sample = v[7:0]; end
			4'b0101: begin v = avg2(half_h(0, 0), half_v(0, 0)); sample = v[7:0]; end
			4'b0110: begin v = avg2(half_h(0, 0), half_c(0, 0)); sample = v[7:0]; end
			4'b0111: begin v = avg2(half_h(0, 0), half_v(0, 1)); sample = v[7:0]; end
			4'b1000: begin v = half_v(0, 0); sample = v[7:0]; end
			4'b1001: begin v = avg2(half_v(0, 0), half_c(0, 0)); sample = v[7:0]; end
			4'b1010: begin v = half_c(0, 0); sample = v[7:0]; end
			4'b1011: begin v = avg2(half_c(0, 0), half_v(0, 1)); sample = v[7:0]; end
			4'b1100: begin v = avg2(half_v(0, 0), pix(5, 4)); sample = v[7:0]; end
			4'b1101: begin v = avg2(half_h(1, 0), half_v(0, 0)); sample = v[7:0]; end
			4'b1110: begin v = avg2(half_c(0, 0), half_h(1, 0)); sample = v[7:0]; end
			4'b1111: begin v = avg2(half_h(1, 0), half_v(0, 1)); sample = v[7:0]; end
		endcase
	end
endmodule

module h264_chroma_epel_sample (
	input  wire [7:0] p00,
	input  wire [7:0] p10,
	input  wire [7:0] p01,
	input  wire [7:0] p11,
	input  wire [2:0] frac_x,
	input  wire [2:0] frac_y,
	output wire [7:0] sample
);
	wire [3:0] wx0 = 4'd8 - {1'b0, frac_x};
	wire [3:0] wy0 = 4'd8 - {1'b0, frac_y};
	wire [9:0] a = wx0 * wy0;
	wire [9:0] b = {1'b0, frac_x} * wy0;
	wire [9:0] c = wx0 * {1'b0, frac_y};
	wire [9:0] d = {1'b0, frac_x} * {1'b0, frac_y};
	wire [15:0] sum = a * p00 + b * p10 + c * p01 + d * p11 + 16'd32;
	assign sample = sum[13:6];
endmodule

module h264_ref_clamp (
	input  wire signed [15:0] x,
	input  wire signed [15:0] y,
	input  wire        [15:0] width,
	input  wire        [15:0] height,
	output reg         [15:0] clamped_x,
	output reg         [15:0] clamped_y
);
	always @* begin
		if (x < 0) clamped_x = 16'd0;
		else if ($signed({1'b0, x}) >= $signed({1'b0, width})) clamped_x = width - 16'd1;
		else clamped_x = x[15:0];

		if (y < 0) clamped_y = 16'd0;
		else if ($signed({1'b0, y}) >= $signed({1'b0, height})) clamped_y = height - 16'd1;
		else clamped_y = y[15:0];
	end
endmodule

module h264_luma_ref_tap_addr (
	input  wire signed [15:0] base_x,
	input  wire signed [15:0] base_y,
	input  wire        [6:0]  tap_idx,
	input  wire        [15:0] width,
	input  wire        [15:0] height,
	output wire        [15:0] tap_x,
	output wire        [15:0] tap_y
);
	wire [6:0] tap_ix = tap_idx % 7'd9;
	wire [6:0] tap_iy = tap_idx / 7'd9;
	wire signed [15:0] tap_col = $signed({9'd0, tap_ix}) - 16'sd4;
	wire signed [15:0] tap_row = $signed({9'd0, tap_iy}) - 16'sd4;
	h264_ref_clamp u_clamp (
		.x(base_x + tap_col),
		.y(base_y + tap_row),
		.width(width),
		.height(height),
		.clamped_x(tap_x),
		.clamped_y(tap_y)
	);
endmodule

`default_nettype wire
