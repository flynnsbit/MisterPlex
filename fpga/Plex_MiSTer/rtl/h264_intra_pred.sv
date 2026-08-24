// Phase 3.3l-3: H.264 intra prediction helpers.
// Behaviour matches host/libmisterplex/h264_recon.hpp. I16 V/H/DC/Plane are
// sequential (one selected mode, one row/cycle). Guard may still flag Plane.

module h264_intra4x4_pred (
	input  wire [3:0] mode,
	input  wire [7:0] above [0:7],
	input  wire [7:0] left [0:3],
	input  wire [7:0] top_left,
	input  wire       has_above,
	input  wire       has_left,
	output reg  [3:0] used_mode,
	output reg  [7:0] pred [0:15]
);
	function automatic [7:0] clip8;
		input integer v;
		begin
			if (v < 0) clip8 = 8'd0;
			else if (v > 255) clip8 = 8'd255;
			else clip8 = v[7:0];
		end
	endfunction

	task automatic put;
		input int x;
		input int y;
		input int v;
		begin
			pred[y * 4 + x] = clip8(v);
		end
	endtask

	integer x, y, i;
	reg [3:0] m;
	integer t0, t1, t2, t3, t4, t5, t6, t7;
	integer l0, l1, l2, l3;
	integer dc_sum;
	reg [7:0] dc_v;
	always @* begin
		dc_sum = 0;
		dc_v = 8'd128;
		for (i = 0; i < 16; i = i + 1) pred[i] = 8'd128;
		m = mode;
		if (!has_above && (mode == 4'd0 || mode == 4'd3 || mode == 4'd7)) m = 4'd2;
		if (!has_left  && (mode == 4'd1 || mode == 4'd8)) m = 4'd2;
		if ((!has_above || !has_left) && (mode == 4'd4 || mode == 4'd5 || mode == 4'd6)) m = 4'd2;
		used_mode = m;

		t0 = above[0]; t1 = above[1]; t2 = above[2]; t3 = above[3];
		t4 = above[4]; t5 = above[5]; t6 = above[6]; t7 = above[7];
		l0 = left[0];  l1 = left[1];  l2 = left[2];  l3 = left[3];

		case (m)
		4'd0: begin // Vertical
			for (y = 0; y < 4; y = y + 1)
				for (x = 0; x < 4; x = x + 1) pred[y * 4 + x] = above[x];
		end
		4'd1: begin // Horizontal
			for (y = 0; y < 4; y = y + 1)
				for (x = 0; x < 4; x = x + 1) pred[y * 4 + x] = left[y];
		end
		4'd2: begin // DC
			if (has_above && has_left) begin
				dc_sum = t0 + t1 + t2 + t3 + l0 + l1 + l2 + l3 + 10'd4;
				dc_v = dc_sum >>> 3;
			end else if (has_above) begin
				dc_sum = t0 + t1 + t2 + t3 + 10'd2;
				dc_v = dc_sum >>> 2;
			end else if (has_left) begin
				dc_sum = l0 + l1 + l2 + l3 + 10'd2;
				dc_v = dc_sum >>> 2;
			end else begin
				dc_v = 8'd128;
			end
			for (i = 0; i < 16; i = i + 1) pred[i] = dc_v;
		end
		4'd3: begin // Diagonal Down-Left
			put(0, 0, (t0 + t2 + 2 * t1 + 2) >>> 2);
			put(1, 0, (t1 + t3 + 2 * t2 + 2) >>> 2); put(0, 1, (t1 + t3 + 2 * t2 + 2) >>> 2);
			put(2, 0, (t2 + t4 + 2 * t3 + 2) >>> 2); put(1, 1, (t2 + t4 + 2 * t3 + 2) >>> 2); put(0, 2, (t2 + t4 + 2 * t3 + 2) >>> 2);
			put(3, 0, (t3 + t5 + 2 * t4 + 2) >>> 2); put(2, 1, (t3 + t5 + 2 * t4 + 2) >>> 2); put(1, 2, (t3 + t5 + 2 * t4 + 2) >>> 2); put(0, 3, (t3 + t5 + 2 * t4 + 2) >>> 2);
			put(3, 1, (t4 + t6 + 2 * t5 + 2) >>> 2); put(2, 2, (t4 + t6 + 2 * t5 + 2) >>> 2); put(1, 3, (t4 + t6 + 2 * t5 + 2) >>> 2);
			put(3, 2, (t5 + t7 + 2 * t6 + 2) >>> 2); put(2, 3, (t5 + t7 + 2 * t6 + 2) >>> 2);
			put(3, 3, (t6 + 3 * t7 + 2) >>> 2);
		end
		4'd4: begin // Diagonal Down-Right
			put(0, 3, (l3 + 2 * l2 + l1 + 2) >>> 2);
			put(0, 2, (l2 + 2 * l1 + l0 + 2) >>> 2); put(1, 3, (l2 + 2 * l1 + l0 + 2) >>> 2);
			put(0, 1, (l1 + 2 * l0 + top_left + 2) >>> 2); put(1, 2, (l1 + 2 * l0 + top_left + 2) >>> 2); put(2, 3, (l1 + 2 * l0 + top_left + 2) >>> 2);
			put(0, 0, (l0 + 2 * top_left + t0 + 2) >>> 2); put(1, 1, (l0 + 2 * top_left + t0 + 2) >>> 2); put(2, 2, (l0 + 2 * top_left + t0 + 2) >>> 2); put(3, 3, (l0 + 2 * top_left + t0 + 2) >>> 2);
			put(1, 0, (top_left + 2 * t0 + t1 + 2) >>> 2); put(2, 1, (top_left + 2 * t0 + t1 + 2) >>> 2); put(3, 2, (top_left + 2 * t0 + t1 + 2) >>> 2);
			put(2, 0, (t0 + 2 * t1 + t2 + 2) >>> 2); put(3, 1, (t0 + 2 * t1 + t2 + 2) >>> 2);
			put(3, 0, (t1 + 2 * t2 + t3 + 2) >>> 2);
		end
		4'd5: begin // Vertical-Right
			put(0, 0, (top_left + t0 + 1) >>> 1); put(1, 2, (top_left + t0 + 1) >>> 1);
			put(1, 0, (t0 + t1 + 1) >>> 1); put(2, 2, (t0 + t1 + 1) >>> 1);
			put(2, 0, (t1 + t2 + 1) >>> 1); put(3, 2, (t1 + t2 + 1) >>> 1);
			put(3, 0, (t2 + t3 + 1) >>> 1);
			put(0, 1, (l0 + 2 * top_left + t0 + 2) >>> 2); put(1, 3, (l0 + 2 * top_left + t0 + 2) >>> 2);
			put(1, 1, (top_left + 2 * t0 + t1 + 2) >>> 2); put(2, 3, (top_left + 2 * t0 + t1 + 2) >>> 2);
			put(2, 1, (t0 + 2 * t1 + t2 + 2) >>> 2); put(3, 3, (t0 + 2 * t1 + t2 + 2) >>> 2);
			put(3, 1, (t1 + 2 * t2 + t3 + 2) >>> 2);
			put(0, 2, (top_left + 2 * l0 + l1 + 2) >>> 2); put(0, 3, (l0 + 2 * l1 + l2 + 2) >>> 2);
		end
		4'd6: begin // Horizontal-Down
			put(0, 0, (top_left + l0 + 1) >>> 1); put(2, 1, (top_left + l0 + 1) >>> 1);
			put(1, 0, (l0 + 2 * top_left + t0 + 2) >>> 2); put(3, 1, (l0 + 2 * top_left + t0 + 2) >>> 2);
			put(2, 0, (top_left + 2 * t0 + t1 + 2) >>> 2); put(3, 0, (t0 + 2 * t1 + t2 + 2) >>> 2);
			put(0, 1, (l0 + l1 + 1) >>> 1); put(2, 2, (l0 + l1 + 1) >>> 1);
			put(1, 1, (top_left + 2 * l0 + l1 + 2) >>> 2); put(3, 2, (top_left + 2 * l0 + l1 + 2) >>> 2);
			put(0, 2, (l1 + l2 + 1) >>> 1); put(2, 3, (l1 + l2 + 1) >>> 1);
			put(1, 2, (l0 + 2 * l1 + l2 + 2) >>> 2); put(3, 3, (l0 + 2 * l1 + l2 + 2) >>> 2);
			put(0, 3, (l2 + l3 + 1) >>> 1); put(1, 3, (l1 + 2 * l2 + l3 + 2) >>> 2);
		end
		4'd7: begin // Vertical-Left
			put(0, 0, (t0 + t1 + 1) >>> 1); put(1, 0, (t1 + t2 + 1) >>> 1); put(0, 2, (t1 + t2 + 1) >>> 1);
			put(2, 0, (t2 + t3 + 1) >>> 1); put(1, 2, (t2 + t3 + 1) >>> 1);
			put(3, 0, (t3 + t4 + 1) >>> 1); put(2, 2, (t3 + t4 + 1) >>> 1);
			put(3, 2, (t4 + t5 + 1) >>> 1);
			put(0, 1, (t0 + 2 * t1 + t2 + 2) >>> 2);
			put(1, 1, (t1 + 2 * t2 + t3 + 2) >>> 2); put(0, 3, (t1 + 2 * t2 + t3 + 2) >>> 2);
			put(2, 1, (t2 + 2 * t3 + t4 + 2) >>> 2); put(1, 3, (t2 + 2 * t3 + t4 + 2) >>> 2);
			put(3, 1, (t3 + 2 * t4 + t5 + 2) >>> 2); put(2, 3, (t3 + 2 * t4 + t5 + 2) >>> 2);
			put(3, 3, (t4 + 2 * t5 + t6 + 2) >>> 2);
		end
		4'd8: begin // Horizontal-Up
			put(0, 0, (l0 + l1 + 1) >>> 1); put(1, 0, (l0 + 2 * l1 + l2 + 2) >>> 2);
			put(2, 0, (l1 + l2 + 1) >>> 1); put(0, 1, (l1 + l2 + 1) >>> 1);
			put(3, 0, (l1 + 2 * l2 + l3 + 2) >>> 2); put(1, 1, (l1 + 2 * l2 + l3 + 2) >>> 2);
			put(2, 1, (l2 + l3 + 1) >>> 1); put(0, 2, (l2 + l3 + 1) >>> 1);
			put(3, 1, (l2 + 2 * l3 + l3 + 2) >>> 2); put(1, 2, (l2 + 2 * l3 + l3 + 2) >>> 2);
			put(3, 2, l3); put(1, 3, l3); put(0, 3, l3); put(2, 2, l3); put(2, 3, l3); put(3, 3, l3);
		end
		default: begin
			used_mode = 4'd15;
			for (i = 0; i < 16; i = i + 1) pred[i] = 8'd128;
		end
		endcase
	end
endmodule

module h264_intra16x16_pred (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [1:0]  mode,
	input  wire [7:0]  above [0:15],
	input  wire [7:0]  left [0:15],
	input  wire [7:0]  top_left,
	input  wire        has_above,
	input  wire        has_left,
	output reg         busy,
	output reg         done,
	output reg         unsupported,
	output reg  [7:0]  pred [0:255]
);
	// Sequential selected-mode I16 (V/H/DC/Plane). One neighbor-prep
	// then one MB row/cycle. No 4-mode parallel engines, no 256-wide
	// combo generate. 0 DSP: shift-add for 5*H and bb*(x-7).
	localparam [1:0] ST_IDLE = 2'd0;
	localparam [1:0] ST_HV   = 2'd1;
	localparam [1:0] ST_COEF = 2'd2;
	localparam [1:0] ST_FILL = 2'd3;

	reg [1:0]  st;
	reg [1:0]  mode_r;
	reg        ha_r, hl_r;
	reg [7:0]  above_r [0:15];
	reg [7:0]  left_r [0:15];
	reg [7:0]  tl_r;
	reg [3:0]  ii;
	reg [3:0]  ry;
	reg signed [15:0] Hp, Vp;
	reg signed [13:0] aa;
	reg signed [12:0] bb, cc;
	reg [7:0]  dc_v;
	reg        plane_ok;

	reg [7:0] a_hi, a_lo, l_hi, l_lo;
	reg [7:0] left_row;
	reg signed [9:0] da, dl;
	reg signed [15:0] term_a, term_l;
	reg signed [4:0] dy;
	reg signed [16:0] row_c;
	reg signed [16:0] valv0, valv1, valv2, valv3;
	reg signed [16:0] valv4, valv5, valv6, valv7;
	reg signed [16:0] valv8, valv9, valva, valvb;
	reg signed [16:0] valvc, valvd, valve, valvf;
	integer si;
	integer sum_i;

	function automatic [7:0] clip8s;
		input signed [16:0] v;
		reg signed [16:0] t;
		begin
			t = v;
			if (t < 17'sd0) clip8s = 8'd0;
			else if (t > 17'sd255) clip8s = 8'd255;
			else clip8s = t[7:0];
		end
	endfunction

	function automatic signed [16:0] kmul;
		input signed [12:0] k;
		input signed [4:0] d;
		reg signed [16:0] acc;
		reg signed [4:0] ad;
		reg neg;
		begin
			neg = (d < 5'sd0);
			ad  = neg ? -d : d;
			acc = 17'sd0;
			if (ad[0]) acc = acc + k;
			if (ad[1]) acc = acc + (k <<< 1);
			if (ad[2]) acc = acc + (k <<< 2);
			if (ad[3]) acc = acc + (k <<< 3);
			kmul = neg ? -acc : acc;
		end
	endfunction

	function automatic signed [15:0] scale_d;
		input [3:0] n; // 1..8
		input signed [9:0] d;
		begin
			case (n)
			4'd1: scale_d = d;
			4'd2: scale_d = d <<< 1;
			4'd3: scale_d = (d <<< 1) + d;
			4'd4: scale_d = d <<< 2;
			4'd5: scale_d = (d <<< 2) + d;
			4'd6: scale_d = (d <<< 2) + (d <<< 1);
			4'd7: scale_d = (d <<< 3) - d;
			default: scale_d = d <<< 3;
			endcase
		end
	endfunction

	// Latch-then-slice neighbor picks (no variable 2D window).
	always @* begin
		a_hi = 8'd0; a_lo = 8'd0; l_hi = 8'd0; l_lo = 8'd0;
		case (ii)
		4'd0: begin a_hi = above_r[8];  a_lo = above_r[6]; l_hi = left_r[8];  l_lo = left_r[6]; end
		4'd1: begin a_hi = above_r[9];  a_lo = above_r[5]; l_hi = left_r[9];  l_lo = left_r[5]; end
		4'd2: begin a_hi = above_r[10]; a_lo = above_r[4]; l_hi = left_r[10]; l_lo = left_r[4]; end
		4'd3: begin a_hi = above_r[11]; a_lo = above_r[3]; l_hi = left_r[11]; l_lo = left_r[3]; end
		4'd4: begin a_hi = above_r[12]; a_lo = above_r[2]; l_hi = left_r[12]; l_lo = left_r[2]; end
		4'd5: begin a_hi = above_r[13]; a_lo = above_r[1]; l_hi = left_r[13]; l_lo = left_r[1]; end
		4'd6: begin a_hi = above_r[14]; a_lo = above_r[0]; l_hi = left_r[14]; l_lo = left_r[0]; end
		default: begin a_hi = above_r[15]; a_lo = tl_r;    l_hi = left_r[15]; l_lo = tl_r;     end
		endcase
		da = $signed({1'b0, a_hi}) - $signed({1'b0, a_lo});
		dl = $signed({1'b0, l_hi}) - $signed({1'b0, l_lo});
		term_a = scale_d(ii + 4'd1, da);
		term_l = scale_d(ii + 4'd1, dl);

		left_row = 8'd128;
		case (ry)
		4'd0:  left_row = left_r[0];
		4'd1:  left_row = left_r[1];
		4'd2:  left_row = left_r[2];
		4'd3:  left_row = left_r[3];
		4'd4:  left_row = left_r[4];
		4'd5:  left_row = left_r[5];
		4'd6:  left_row = left_r[6];
		4'd7:  left_row = left_r[7];
		4'd8:  left_row = left_r[8];
		4'd9:  left_row = left_r[9];
		4'd10: left_row = left_r[10];
		4'd11: left_row = left_r[11];
		4'd12: left_row = left_r[12];
		4'd13: left_row = left_r[13];
		4'd14: left_row = left_r[14];
		default: left_row = left_r[15];
		endcase

		dy = $signed({1'b0, ry}) - 5'sd7;
		row_c = kmul(cc, dy);
		valv0 = (aa + kmul(bb, -5'sd7) + row_c + 17'sd16) >>> 5;
		valv1 = (aa + kmul(bb, -5'sd6) + row_c + 17'sd16) >>> 5;
		valv2 = (aa + kmul(bb, -5'sd5) + row_c + 17'sd16) >>> 5;
		valv3 = (aa + kmul(bb, -5'sd4) + row_c + 17'sd16) >>> 5;
		valv4 = (aa + kmul(bb, -5'sd3) + row_c + 17'sd16) >>> 5;
		valv5 = (aa + kmul(bb, -5'sd2) + row_c + 17'sd16) >>> 5;
		valv6 = (aa + kmul(bb, -5'sd1) + row_c + 17'sd16) >>> 5;
		valv7 = (aa + kmul(bb,  5'sd0) + row_c + 17'sd16) >>> 5;
		valv8 = (aa + kmul(bb,  5'sd1) + row_c + 17'sd16) >>> 5;
		valv9 = (aa + kmul(bb,  5'sd2) + row_c + 17'sd16) >>> 5;
		valva = (aa + kmul(bb,  5'sd3) + row_c + 17'sd16) >>> 5;
		valvb = (aa + kmul(bb,  5'sd4) + row_c + 17'sd16) >>> 5;
		valvc = (aa + kmul(bb,  5'sd5) + row_c + 17'sd16) >>> 5;
		valvd = (aa + kmul(bb,  5'sd6) + row_c + 17'sd16) >>> 5;
		valve = (aa + kmul(bb,  5'sd7) + row_c + 17'sd16) >>> 5;
		valvf = (aa + kmul(bb,  5'sd8) + row_c + 17'sd16) >>> 5;
	end

	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			st          <= ST_IDLE;
			busy        <= 1'b0;
			done        <= 1'b0;
			unsupported <= 1'b0;
			mode_r      <= 2'd0;
			ha_r        <= 1'b0;
			hl_r        <= 1'b0;
			tl_r        <= 8'd0;
			ii          <= 4'd0;
			ry          <= 4'd0;
			Hp          <= 16'sd0;
			Vp          <= 16'sd0;
			aa          <= 14'sd0;
			bb          <= 13'sd0;
			cc          <= 13'sd0;
			dc_v        <= 8'd128;
			plane_ok    <= 1'b0;
			for (si = 0; si < 256; si = si + 1)
				pred[si] <= 8'd128;
			for (si = 0; si < 16; si = si + 1) begin
				above_r[si] <= 8'd0;
				left_r[si]  <= 8'd0;
			end
		end else if (start) begin
			busy        <= 1'b1;
			done        <= 1'b0;
			unsupported <= 1'b0;
			mode_r      <= mode;
			ha_r        <= has_above;
			hl_r        <= has_left;
			tl_r        <= top_left;
			for (si = 0; si < 16; si = si + 1) begin
				above_r[si] <= above[si];
				left_r[si]  <= left[si];
			end
			sum_i = 0;
			if (has_above)
				sum_i = sum_i + above[0] + above[1] + above[2] + above[3]
				              + above[4] + above[5] + above[6] + above[7]
				              + above[8] + above[9] + above[10] + above[11]
				              + above[12] + above[13] + above[14] + above[15];
			if (has_left)
				sum_i = sum_i + left[0] + left[1] + left[2] + left[3]
				              + left[4] + left[5] + left[6] + left[7]
				              + left[8] + left[9] + left[10] + left[11]
				              + left[12] + left[13] + left[14] + left[15];
			if (mode == 2'd3) begin
				plane_ok <= (has_above && has_left);
				if (has_above && has_left)
					dc_v <= 8'd128;
				else if (has_above || has_left)
					dc_v <= (sum_i + 8) >> 4;
				else
					dc_v <= 8'd128;
			end else if (has_above && has_left)
				dc_v <= (sum_i + 16) >> 5;
			else if (has_above || has_left)
				dc_v <= (sum_i + 8) >> 4;
			else
				dc_v <= 8'd128;
			Hp       <= 16'sd0;
			Vp       <= 16'sd0;
			ii       <= 4'd0;
			ry       <= 4'd0;
			if ((mode == 2'd3) && has_above && has_left)
				st <= ST_HV;
			else
				st <= ST_FILL;
		end else begin
			case (st)
			ST_HV: begin
				Hp <= Hp + term_a;
				Vp <= Vp + term_l;
				if (ii == 4'd7)
					st <= ST_COEF;
				else
					ii <= ii + 4'd1;
			end
			ST_COEF: begin
				// bb=(5*Hp+32)>>>6, cc=(5*Vp+32)>>>6 — extend then shift-add, 0 DSP
				aa <= ($signed({6'd0, above_r[15]}) + $signed({6'd0, left_r[15]})) <<< 4;
				bb <= ($signed({{2{Hp[15]}}, Hp}) + $signed({Hp, 2'b00}) + 18'sd32) >>> 6;
				cc <= ($signed({{2{Vp[15]}}, Vp}) + $signed({Vp, 2'b00}) + 18'sd32) >>> 6;
				ry <= 4'd0;
				st <= ST_FILL;
			end
			ST_FILL: begin
				if (mode_r == 2'd0 && ha_r) begin
					pred[{ry, 4'd0}]  <= above_r[0];
					pred[{ry, 4'd1}]  <= above_r[1];
					pred[{ry, 4'd2}]  <= above_r[2];
					pred[{ry, 4'd3}]  <= above_r[3];
					pred[{ry, 4'd4}]  <= above_r[4];
					pred[{ry, 4'd5}]  <= above_r[5];
					pred[{ry, 4'd6}]  <= above_r[6];
					pred[{ry, 4'd7}]  <= above_r[7];
					pred[{ry, 4'd8}]  <= above_r[8];
					pred[{ry, 4'd9}]  <= above_r[9];
					pred[{ry, 4'd10}] <= above_r[10];
					pred[{ry, 4'd11}] <= above_r[11];
					pred[{ry, 4'd12}] <= above_r[12];
					pred[{ry, 4'd13}] <= above_r[13];
					pred[{ry, 4'd14}] <= above_r[14];
					pred[{ry, 4'd15}] <= above_r[15];
				end else if (mode_r == 2'd1 && hl_r) begin
					pred[{ry, 4'd0}]  <= left_row;
					pred[{ry, 4'd1}]  <= left_row;
					pred[{ry, 4'd2}]  <= left_row;
					pred[{ry, 4'd3}]  <= left_row;
					pred[{ry, 4'd4}]  <= left_row;
					pred[{ry, 4'd5}]  <= left_row;
					pred[{ry, 4'd6}]  <= left_row;
					pred[{ry, 4'd7}]  <= left_row;
					pred[{ry, 4'd8}]  <= left_row;
					pred[{ry, 4'd9}]  <= left_row;
					pred[{ry, 4'd10}] <= left_row;
					pred[{ry, 4'd11}] <= left_row;
					pred[{ry, 4'd12}] <= left_row;
					pred[{ry, 4'd13}] <= left_row;
					pred[{ry, 4'd14}] <= left_row;
					pred[{ry, 4'd15}] <= left_row;
				end else if ((mode_r == 2'd3) && plane_ok) begin
					pred[{ry, 4'd0}]  <= clip8s(valv0);
					pred[{ry, 4'd1}]  <= clip8s(valv1);
					pred[{ry, 4'd2}]  <= clip8s(valv2);
					pred[{ry, 4'd3}]  <= clip8s(valv3);
					pred[{ry, 4'd4}]  <= clip8s(valv4);
					pred[{ry, 4'd5}]  <= clip8s(valv5);
					pred[{ry, 4'd6}]  <= clip8s(valv6);
					pred[{ry, 4'd7}]  <= clip8s(valv7);
					pred[{ry, 4'd8}]  <= clip8s(valv8);
					pred[{ry, 4'd9}]  <= clip8s(valv9);
					pred[{ry, 4'd10}] <= clip8s(valva);
					pred[{ry, 4'd11}] <= clip8s(valvb);
					pred[{ry, 4'd12}] <= clip8s(valvc);
					pred[{ry, 4'd13}] <= clip8s(valvd);
					pred[{ry, 4'd14}] <= clip8s(valve);
					pred[{ry, 4'd15}] <= clip8s(valvf);
				end else begin
					pred[{ry, 4'd0}]  <= dc_v;
					pred[{ry, 4'd1}]  <= dc_v;
					pred[{ry, 4'd2}]  <= dc_v;
					pred[{ry, 4'd3}]  <= dc_v;
					pred[{ry, 4'd4}]  <= dc_v;
					pred[{ry, 4'd5}]  <= dc_v;
					pred[{ry, 4'd6}]  <= dc_v;
					pred[{ry, 4'd7}]  <= dc_v;
					pred[{ry, 4'd8}]  <= dc_v;
					pred[{ry, 4'd9}]  <= dc_v;
					pred[{ry, 4'd10}] <= dc_v;
					pred[{ry, 4'd11}] <= dc_v;
					pred[{ry, 4'd12}] <= dc_v;
					pred[{ry, 4'd13}] <= dc_v;
					pred[{ry, 4'd14}] <= dc_v;
					pred[{ry, 4'd15}] <= dc_v;
				end
				if (ry == 4'd15) begin
					st   <= ST_IDLE;
					busy <= 1'b0;
					done <= 1'b1;
				end else
					ry <= ry + 4'd1;
			end
			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule

module h264_chroma8x8_pred (
	input  wire [1:0] mode,
	input  wire [7:0] above [0:7],
	input  wire [7:0] left [0:7],
	input  wire [7:0] top_left,
	input  wire       has_above,
	input  wire       has_left,
	output reg  [7:0] pred [0:63]
);
	function automatic [7:0] clip8;
		input integer v;
		begin
			if (v < 0) clip8 = 8'd0;
			else if (v > 255) clip8 = 8'd255;
			else clip8 = v[7:0];
		end
	endfunction

	task automatic fill4;
		input int x0;
		input int y0;
		input int v;
		integer x, y;
		begin
			for (y = 0; y < 4; y = y + 1)
				for (x = 0; x < 4; x = x + 1) pred[(y0 + y) * 8 + x0 + x] = clip8(v);
		end
	endtask

	integer x, y, i;
	integer hgrad, vgrad, a, b, c, val;
	integer sum_a0, sum_a1, sum_l0, sum_l1;
	integer ai [0:7];
	integer li [0:7];
	integer tli;
	always @* begin
		hgrad = 0;
		vgrad = 0;
		a = 0;
		b = 0;
		c = 0;
		val = 0;
		for (i = 0; i < 64; i = i + 1) pred[i] = 8'd128;
		for (i = 0; i < 8; i = i + 1) begin
			ai[i] = above[i];
			li[i] = left[i];
		end
		tli = top_left;
		sum_a0 = ai[0] + ai[1] + ai[2] + ai[3];
		sum_a1 = ai[4] + ai[5] + ai[6] + ai[7];
		sum_l0 = li[0] + li[1] + li[2] + li[3];
		sum_l1 = li[4] + li[5] + li[6] + li[7];
		if (mode == 2'd0) begin
			if (has_above && has_left) begin
				fill4(0, 0, (sum_a0 + sum_l0 + 4) >>> 3);
				fill4(4, 0, (sum_a1 + 2) >>> 2);
				fill4(0, 4, (sum_l1 + 2) >>> 2);
				fill4(4, 4, (sum_a1 + sum_l1 + 4) >>> 3);
			end else if (has_above) begin
				fill4(0, 0, (sum_a0 + 2) >>> 2); fill4(4, 0, (sum_a1 + 2) >>> 2);
				fill4(0, 4, (sum_a0 + 2) >>> 2); fill4(4, 4, (sum_a1 + 2) >>> 2);
			end else if (has_left) begin
				fill4(0, 0, (sum_l0 + 2) >>> 2); fill4(4, 0, (sum_l0 + 2) >>> 2);
				fill4(0, 4, (sum_l1 + 2) >>> 2); fill4(4, 4, (sum_l1 + 2) >>> 2);
			end
		end else if (mode == 2'd1) begin
			for (y = 0; y < 8; y = y + 1)
				for (x = 0; x < 8; x = x + 1) pred[y * 8 + x] = left[y];
		end else if (mode == 2'd2) begin
			for (y = 0; y < 8; y = y + 1)
				for (x = 0; x < 8; x = x + 1) pred[y * 8 + x] = above[x];
		end else begin
			for (i = 0; i < 4; i = i + 1) begin
				hgrad = hgrad + (i + 1) * (ai[4 + i] - ((i == 3) ? tli : ai[2 - i]));
				vgrad = vgrad + (i + 1) * (li[4 + i]  - ((i == 3) ? tli : li[2 - i]));
			end
			a = 16 * (ai[7] + li[7]);
			b = (17 * hgrad + 16) >>> 5;
			c = (17 * vgrad + 16) >>> 5;
			for (y = 0; y < 8; y = y + 1)
				for (x = 0; x < 8; x = x + 1) begin
					val = (a + b * (x - 3) + c * (y - 3) + 16) >>> 5;
					pred[y * 8 + x] = clip8(val);
				end
		end
	end
endmodule

module h264_intra_mode_guard (
	input  wire        clk,
	input  wire        reset,
	input  wire        mb_valid,
	input  wire [7:0]  mb_type,
	input  wire [1:0]  i16_pred_mode,
	input  wire [15:0] mb_index,
	input  wire [4:0]  block_index,
	output reg         unsupported_valid,
	output reg         unsupported_seen,
	output reg  [3:0]  unsupported_code,
	output reg  [15:0] unsupported_mb,
	output reg  [4:0]  unsupported_block
);
	localparam [3:0] UNSUP_I16_PLANE = 4'd1;
	localparam [3:0] UNSUP_IPCM      = 4'd2;
	localparam [3:0] UNSUP_MB_TYPE   = 4'd3;

	wire is_i16 = (mb_type >= 8'd1) && (mb_type <= 8'd24);
	wire is_i4  = (mb_type == 8'd0);
	wire is_ipcm = (mb_type == 8'd25);
	wire i16_plane = is_i16 && (i16_pred_mode == 2'd3);
	wire bad_type = !(is_i4 || is_i16 || is_ipcm);

	always @(posedge clk) begin
		unsupported_valid <= 1'b0;
		if (reset) begin
			unsupported_seen  <= 1'b0;
			unsupported_code  <= 4'd0;
			unsupported_mb    <= 16'd0;
			unsupported_block <= 5'd0;
		end else if (mb_valid && (i16_plane || is_ipcm || bad_type)) begin
			unsupported_valid <= 1'b1;
			unsupported_seen  <= 1'b1;
			unsupported_code  <= i16_plane ? UNSUP_I16_PLANE : (is_ipcm ? UNSUP_IPCM : UNSUP_MB_TYPE);
			unsupported_mb    <= mb_index;
			unsupported_block <= block_index;
		end
	end
endmodule
