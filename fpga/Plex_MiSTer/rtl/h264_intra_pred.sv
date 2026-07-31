// Phase 3.3l-3: H.264 intra prediction helpers.
// Behaviour matches host/libmisterplex/h264_recon.hpp for the measured all-intra
// Plex vector. All intra modes supported: I4x4 (9 modes), I16x16 (4 modes incl.
// Plane per clause 8.3.3.4), Chroma 8x8 (4 modes incl. Plane per clause 8.3.4.4).
// I_PCM (mb_type 25) remains UNSUPPORTED — mode guard fires unsupported_code for it.

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

	// Pixel → integer (explicit; kills WIDTHEXPAND on 8→32 assigns/adds).
	function automatic integer px;
		input [7:0] p;
		begin
			px = integer'(p);
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
	integer tl;
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

		t0 = px(above[0]); t1 = px(above[1]); t2 = px(above[2]); t3 = px(above[3]);
		t4 = px(above[4]); t5 = px(above[5]); t6 = px(above[6]); t7 = px(above[7]);
		l0 = px(left[0]);  l1 = px(left[1]);  l2 = px(left[2]);  l3 = px(left[3]);
		tl = px(top_left);

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
				dc_sum = t0 + t1 + t2 + t3 + l0 + l1 + l2 + l3 + 4;
				dc_v = 8'(dc_sum >>> 3);
			end else if (has_above) begin
				dc_sum = t0 + t1 + t2 + t3 + 2;
				dc_v = 8'(dc_sum >>> 2);
			end else if (has_left) begin
				dc_sum = l0 + l1 + l2 + l3 + 2;
				dc_v = 8'(dc_sum >>> 2);
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
			put(0, 1, (l1 + 2 * l0 + tl + 2) >>> 2); put(1, 2, (l1 + 2 * l0 + tl + 2) >>> 2); put(2, 3, (l1 + 2 * l0 + tl + 2) >>> 2);
			put(0, 0, (l0 + 2 * tl + t0 + 2) >>> 2); put(1, 1, (l0 + 2 * tl + t0 + 2) >>> 2); put(2, 2, (l0 + 2 * tl + t0 + 2) >>> 2); put(3, 3, (l0 + 2 * tl + t0 + 2) >>> 2);
			put(1, 0, (tl + 2 * t0 + t1 + 2) >>> 2); put(2, 1, (tl + 2 * t0 + t1 + 2) >>> 2); put(3, 2, (tl + 2 * t0 + t1 + 2) >>> 2);
			put(2, 0, (t0 + 2 * t1 + t2 + 2) >>> 2); put(3, 1, (t0 + 2 * t1 + t2 + 2) >>> 2);
			put(3, 0, (t1 + 2 * t2 + t3 + 2) >>> 2);
		end
		4'd5: begin // Vertical-Right
			put(0, 0, (tl + t0 + 1) >>> 1); put(1, 2, (tl + t0 + 1) >>> 1);
			put(1, 0, (t0 + t1 + 1) >>> 1); put(2, 2, (t0 + t1 + 1) >>> 1);
			put(2, 0, (t1 + t2 + 1) >>> 1); put(3, 2, (t1 + t2 + 1) >>> 1);
			put(3, 0, (t2 + t3 + 1) >>> 1);
			put(0, 1, (l0 + 2 * tl + t0 + 2) >>> 2); put(1, 3, (l0 + 2 * tl + t0 + 2) >>> 2);
			put(1, 1, (tl + 2 * t0 + t1 + 2) >>> 2); put(2, 3, (tl + 2 * t0 + t1 + 2) >>> 2);
			put(2, 1, (t0 + 2 * t1 + t2 + 2) >>> 2); put(3, 3, (t0 + 2 * t1 + t2 + 2) >>> 2);
			put(3, 1, (t1 + 2 * t2 + t3 + 2) >>> 2);
			put(0, 2, (tl + 2 * l0 + l1 + 2) >>> 2); put(0, 3, (l0 + 2 * l1 + l2 + 2) >>> 2);
		end
		4'd6: begin // Horizontal-Down
			put(0, 0, (tl + l0 + 1) >>> 1); put(2, 1, (tl + l0 + 1) >>> 1);
			put(1, 0, (l0 + 2 * tl + t0 + 2) >>> 2); put(3, 1, (l0 + 2 * tl + t0 + 2) >>> 2);
			put(2, 0, (tl + 2 * t0 + t1 + 2) >>> 2); put(3, 0, (t0 + 2 * t1 + t2 + 2) >>> 2);
			put(0, 1, (l0 + l1 + 1) >>> 1); put(2, 2, (l0 + l1 + 1) >>> 1);
			put(1, 1, (tl + 2 * l0 + l1 + 2) >>> 2); put(3, 2, (tl + 2 * l0 + l1 + 2) >>> 2);
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

// Serial I16 pred: setup 1 cycle, then 256 cycles × 1 pixel (area crash-diet).
// No 256-wide parallel write; no DSP (plane b*(x-7) via shift-add, not *).
// FAULT_FORCE_128: emit 128 for every pixel (RED — proves path load-bearing).
module h264_intra16x16_pred #(
	parameter bit FAULT_FORCE_128 = 1'b0
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [1:0]  mode,
	input  wire [7:0]  above [0:15],
	input  wire [7:0]  left [0:15],
	input  wire [7:0]  top_left,
	input  wire        has_above,
	input  wire        has_left,
	output reg         unsupported,
	output reg         busy,
	output reg         done,       // 1-cy pulse after last pixel (NBA-safe)
	output reg         px_valid,   // 1-cy write strobe
	output reg  [7:0]  px_addr,    // 0..255 raster
	output reg  [7:0]  px_data
);
	// ITU-T H.264 8.3.3: V/H/DC/Plane. Pixel stream replaces old pred[0:255].

	function automatic [7:0] clip8;
		input integer v;
		begin
			if (v < 0) clip8 = 8'd0;
			else if (v > 255) clip8 = 8'd255;
			else clip8 = v[7:0];
		end
	endfunction

	// Small signed multiply by n in -7..8 without DSP (*): shift-add.
	function automatic signed [31:0] mul_m7_p8;
		input signed [31:0] v;
		input integer n; // -7..8
		reg signed [31:0] p;
		begin
			case (n)
			-7: p = -((v <<< 3) - v);       // -(8v - v) = -7v
			-6: p = -((v <<< 2) + (v <<< 1));
			-5: p = -((v <<< 2) + v);
			-4: p = -(v <<< 2);
			-3: p = -((v <<< 1) + v);
			-2: p = -(v <<< 1);
			-1: p = -v;
			0:  p = 0;
			1:  p = v;
			2:  p = v <<< 1;
			3:  p = (v <<< 1) + v;
			4:  p = v <<< 2;
			5:  p = (v <<< 2) + v;
			6:  p = (v <<< 2) + (v <<< 1);
			7:  p = (v <<< 3) - v;
			default: p = v <<< 3; // 8
			endcase
			mul_m7_p8 = p;
		end
	endfunction

	// Gradient term (gi+1)*(p[8+gi]-p[6-gi]) with gi+1 in 1..8 via shift-add.
	function automatic signed [31:0] grad_term;
		input integer gi;
		input signed [31:0] diff;
		begin
			case (gi)
			0: grad_term = diff;
			1: grad_term = diff <<< 1;
			2: grad_term = (diff <<< 1) + diff;
			3: grad_term = diff <<< 2;
			4: grad_term = (diff <<< 2) + diff;
			5: grad_term = (diff <<< 2) + (diff <<< 1);
			6: grad_term = (diff <<< 3) - diff;
			default: grad_term = diff <<< 3; // 8
			endcase
		end
	endfunction

	localparam [1:0]
		M_V  = 2'd0,
		M_H  = 2'd1,
		M_DC = 2'd2,
		M_PL = 2'd3;

	reg [1:0] mode_r;
	reg       ha_r, hl_r;
	reg [7:0] above_r [0:15];
	reg [7:0] left_r  [0:15];
	reg [7:0] tl_r;
	reg [7:0] dc_r;
	reg signed [31:0] a_r, b_r, c_r;
	reg [8:0] k; // 0..256
	integer i, gi;
	integer hgrad, vgrad, a_c, b_c, c_c;
	integer sa_lo, sa_hi, sl_lo, sl_hi, sum;
	integer val, x, y;
	reg signed [31:0] diff;

	always @(posedge clk) begin
		done <= 1'b0;
		px_valid <= 1'b0;
		if (reset) begin
			busy <= 1'b0;
			k <= 9'd0;
			unsupported <= 1'b0;
			px_addr <= 8'd0;
			px_data <= 8'd128;
		end else if (start && !busy) begin
			busy <= 1'b1;
			unsupported <= 1'b0;
			mode_r <= mode;
			ha_r <= has_above;
			hl_r <= has_left;
			tl_r <= top_left;
			for (i = 0; i < 16; i = i + 1) begin
				above_r[i] <= above[i];
				left_r[i]  <= left[i];
			end
			k <= 9'd0;
			// Setup DC / Plane constants on start cycle (combo into regs)
			sa_lo = ((above[0]+above[1]) + (above[2]+above[3]))
			      + ((above[4]+above[5]) + (above[6]+above[7]));
			sa_hi = ((above[8]+above[9]) + (above[10]+above[11]))
			      + ((above[12]+above[13]) + (above[14]+above[15]));
			sl_lo = ((left[0]+left[1]) + (left[2]+left[3]))
			      + ((left[4]+left[5]) + (left[6]+left[7]));
			sl_hi = ((left[8]+left[9]) + (left[10]+left[11]))
			      + ((left[12]+left[13]) + (left[14]+left[15]));
			if (has_above && has_left) sum = (sa_lo + sa_hi) + (sl_lo + sl_hi);
			else if (has_above) sum = sa_lo + sa_hi;
			else if (has_left) sum = sl_lo + sl_hi;
			else sum = 0;
			if (has_above && has_left) dc_r <= (sum + 16) >>> 5;
			else if (has_above || has_left) dc_r <= (sum + 8) >>> 4;
			else dc_r <= 8'd128;

			hgrad = 0;
			vgrad = 0;
			for (gi = 0; gi < 8; gi = gi + 1) begin
				diff = $signed({1'b0, above[8 + gi]}) -
					((gi == 7) ? $signed({1'b0, top_left}) : $signed({1'b0, above[6 - gi]}));
				hgrad = hgrad + grad_term(gi, diff);
				diff = $signed({1'b0, left[8 + gi]}) -
					((gi == 7) ? $signed({1'b0, top_left}) : $signed({1'b0, left[6 - gi]}));
				vgrad = vgrad + grad_term(gi, diff);
			end
			// 16*x and 5*x via shifts (no DSP)
			a_c = ($signed({1'b0, above[15]}) + $signed({1'b0, left[15]})) <<< 4;
			b_c = (((hgrad <<< 2) + hgrad) + 32) >>> 6;
			c_c = (((vgrad <<< 2) + vgrad) + 32) >>> 6;
			a_r <= a_c;
			b_r <= b_c;
			c_r <= c_c;
		end else if (busy) begin
			if (k >= 9'd256) begin
				busy <= 1'b0;
				done <= 1'b1;
				k <= 9'd0;
			end else begin
				x = k[3:0];
				y = k[7:4];
				px_addr <= k[7:0];
				px_valid <= 1'b1;
				if (FAULT_FORCE_128) begin
					px_data <= 8'd128;
				end else begin
					case (mode_r)
					M_V: begin
						if (ha_r) px_data <= above_r[x];
						else px_data <= dc_r;
					end
					M_H: begin
						if (hl_r) px_data <= left_r[y];
						else px_data <= dc_r;
					end
					M_PL: begin
						if (ha_r && hl_r) begin
							val = (a_r + mul_m7_p8(b_r, x - 7) + mul_m7_p8(c_r, y - 7) + 32'sd16) >>> 5;
							px_data <= clip8(val);
						end else
							px_data <= 8'd128;
					end
					default: px_data <= dc_r; // DC + fallbacks
					endcase
				end
				k <= k + 9'd1;
			end
		end
	end

endmodule

module h264_chroma8x8_pred (
	input  wire        clk,
	input  wire        start,
	input  wire [1:0]  mode,
	input  wire [7:0]  above [0:7],
	input  wire [7:0]  left [0:7],
	input  wire [7:0]  top_left,
	input  wire        has_above,
	input  wire        has_left,
	output reg         valid,
	output reg  [7:0]  pred [0:63]
);
	// 2-cycle pipeline for Chroma Plane prediction (ITU-T H.264 clause 8.3.4.4).
	// Cycle 1: gradient accumulation → b, c → pre-compute 16 products bx[]/cy[]
	// Cycle 2: 64 pixels from registered a + bx[x] + cy[y] → clip
	// Modes DC/H/V: 1 cycle (register combinational result on start).

	function automatic [7:0] clip8;
		input integer v;
		begin
			if (v < 0) clip8 = 8'd0;
			else if (v > 255) clip8 = 8'd255;
			else clip8 = v[7:0];
		end
	endfunction

	function automatic integer px;
		input [7:0] p;
		begin
			px = integer'(p);
		end
	endfunction

	// Pipeline phase: 0 = idle, 1 = Plane cycle 2 pending
	reg phase = 1'b0;

	// Registered intermediates for Plane pipeline (16 products, not 64)
	reg signed [15:0] a_r;
	reg signed [15:0] bx_r [0:7];
	reg signed [15:0] cy_r [0:7];

	// Combinational gradient computation (clause 8.3.4.4)
	integer hgrad_c, vgrad_c, a_c, b_c, c_c;
	integer gi;
	always @* begin
		hgrad_c = 0;
		vgrad_c = 0;
		for (gi = 0; gi < 4; gi = gi + 1) begin
			hgrad_c = hgrad_c + (gi + 1) * (px(above[4 + gi]) - ((gi == 3) ? px(top_left) : px(above[2 - gi])));
			vgrad_c = vgrad_c + (gi + 1) * (px(left[4 + gi])  - ((gi == 3) ? px(top_left) : px(left[2 - gi])));
		end
		a_c = 16 * (px(above[7]) + px(left[7]));
		b_c = (17 * hgrad_c + 16) >>> 5;
		c_c = (17 * vgrad_c + 16) >>> 5;
	end

	integer x, y, i;
	integer sum_a0, sum_a1, sum_l0, sum_l1;
	integer val;
	reg [7:0] dc_tl, dc_tr, dc_bl, dc_br;

	always @(posedge clk) begin
		valid <= 1'b0;

		if (phase) begin
			// Plane cycle 2: evaluate 64 pixels from 16 registered products
			for (y = 0; y < 8; y = y + 1)
				for (x = 0; x < 8; x = x + 1) begin
					val = (integer'(a_r) + integer'(bx_r[x]) + integer'(cy_r[y]) + 16) >>> 5;
					pred[y * 8 + x] <= clip8(val);
				end
			valid <= 1'b1;
			phase <= 1'b0;
		end else if (start) begin
			if (mode == 2'd3) begin
				if (has_above && has_left) begin
					// Plane cycle 1: register a and 16 pre-computed products
					a_r <= a_c[15:0];
					for (i = 0; i < 8; i = i + 1) begin
						bx_r[i] <= 16'(b_c * (i - 3));
						cy_r[i] <= 16'(c_c * (i - 3));
					end
					phase <= 1'b1;
				end else begin
					for (i = 0; i < 64; i = i + 1) pred[i] <= 8'd128;
					valid <= 1'b1;
				end
			end else if (mode == 2'd0) begin
				// DC with 4 quadrant sub-averages (clause 8.3.4.1)
				sum_a0 = (px(above[0])+px(above[1])) + (px(above[2])+px(above[3]));
				sum_a1 = (px(above[4])+px(above[5])) + (px(above[6])+px(above[7]));
				sum_l0 = (px(left[0])+px(left[1])) + (px(left[2])+px(left[3]));
				sum_l1 = (px(left[4])+px(left[5])) + (px(left[6])+px(left[7]));
				if (has_above && has_left) begin
					dc_tl = clip8((sum_a0 + sum_l0 + 4) >>> 3);
					dc_tr = clip8((sum_a1 + 2) >>> 2);
					dc_bl = clip8((sum_l1 + 2) >>> 2);
					dc_br = clip8((sum_a1 + sum_l1 + 4) >>> 3);
				end else if (has_above) begin
					dc_tl = clip8((sum_a0 + 2) >>> 2);
					dc_tr = clip8((sum_a1 + 2) >>> 2);
					dc_bl = dc_tl;
					dc_br = dc_tr;
				end else if (has_left) begin
					dc_tl = clip8((sum_l0 + 2) >>> 2);
					dc_tr = dc_tl;
					dc_bl = clip8((sum_l1 + 2) >>> 2);
					dc_br = dc_bl;
				end else begin
					dc_tl = 8'd128; dc_tr = 8'd128;
					dc_bl = 8'd128; dc_br = 8'd128;
				end
				for (y = 0; y < 4; y = y + 1)
					for (x = 0; x < 4; x = x + 1) pred[y*8+x] <= dc_tl;
				for (y = 0; y < 4; y = y + 1)
					for (x = 4; x < 8; x = x + 1) pred[y*8+x] <= dc_tr;
				for (y = 4; y < 8; y = y + 1)
					for (x = 0; x < 4; x = x + 1) pred[y*8+x] <= dc_bl;
				for (y = 4; y < 8; y = y + 1)
					for (x = 4; x < 8; x = x + 1) pred[y*8+x] <= dc_br;
				valid <= 1'b1;
			end else if (mode == 2'd1) begin
				// Horizontal
				for (y = 0; y < 8; y = y + 1)
					for (x = 0; x < 8; x = x + 1) pred[y*8+x] <= left[y];
				valid <= 1'b1;
			end else begin
				// Vertical (mode 2)
				for (y = 0; y < 8; y = y + 1)
					for (x = 0; x < 8; x = x + 1) pred[y*8+x] <= above[x];
				valid <= 1'b1;
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
	wire bad_type = !(is_i4 || is_i16 || is_ipcm);

	always @(posedge clk) begin
		unsupported_valid <= 1'b0;
		if (reset) begin
			unsupported_seen  <= 1'b0;
			unsupported_code  <= 4'd0;
			unsupported_mb    <= 16'd0;
			unsupported_block <= 5'd0;
		end else if (mb_valid && (is_ipcm || bad_type)) begin
			unsupported_valid <= 1'b1;
			unsupported_seen  <= 1'b1;
			unsupported_code  <= is_ipcm ? UNSUP_IPCM : UNSUP_MB_TYPE;
			unsupported_mb    <= mb_index;
			unsupported_block <= block_index;
		end
	end
endmodule
