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
	input  wire [1:0] mode,
	input  wire [7:0] above [0:15],
	input  wire [7:0] left [0:15],
	input  wire [7:0] top_left,
	input  wire       has_above,
	input  wire       has_left,
	output reg        unsupported,
	output reg  [7:0] pred [0:255]
);
	function automatic [7:0] clip8;
		input integer v;
		begin
			if (v < 0) clip8 = 8'd0;
			else if (v > 255) clip8 = 8'd255;
			else clip8 = v[7:0];
		end
	endfunction

	integer x, y, i;
	integer sum;
	reg [7:0] dc_v;
	integer hgrad, vgrad, a, b, c, val;
	always @* begin
		unsupported = 1'b0;
		sum = 0;
		dc_v = 8'd128;
		hgrad = 0;
		vgrad = 0;
		a = 0;
		b = 0;
		c = 0;
		val = 0;
		for (i = 0; i < 256; i = i + 1) pred[i] = 8'd128;
		if (mode == 2'd3) begin
			// Plane prediction (ITU-T H.264 clause 8.3.3.4)
			if (has_above && has_left) begin
				hgrad = 0;
				for (i = 0; i < 8; i = i + 1)
					hgrad = hgrad + (i + 1) * ($signed({1'b0, above[8 + i]}) - ((i == 7) ? $signed({1'b0, top_left}) : $signed({1'b0, above[6 - i]})));
				vgrad = 0;
				for (i = 0; i < 8; i = i + 1)
					vgrad = vgrad + (i + 1) * ($signed({1'b0, left[8 + i]}) - ((i == 7) ? $signed({1'b0, top_left}) : $signed({1'b0, left[6 - i]})));
				a = 16 * ($signed({1'b0, above[15]}) + $signed({1'b0, left[15]}));
				b = (5 * hgrad + 32) >>> 6;
				c = (5 * vgrad + 32) >>> 6;
				for (y = 0; y < 16; y = y + 1)
					for (x = 0; x < 16; x = x + 1) begin
						val = (a + b * (x - 7) + c * (y - 7) + 16) >>> 5;
						pred[y * 16 + x] = clip8(val);
					end
			end
			// else: neighbours unavailable, pred stays at 128 default
		end else if (mode == 2'd0 && has_above) begin
			for (y = 0; y < 16; y = y + 1)
				for (x = 0; x < 16; x = x + 1) pred[y * 16 + x] = above[x];
		end else if (mode == 2'd1 && has_left) begin
			for (y = 0; y < 16; y = y + 1)
				for (x = 0; x < 16; x = x + 1) pred[y * 16 + x] = left[y];
		end else begin
			sum = 0;
			if (has_above) for (i = 0; i < 16; i = i + 1) sum = sum + above[i];
			if (has_left)  for (i = 0; i < 16; i = i + 1) sum = sum + left[i];
			if (has_above && has_left) dc_v = (sum + 16) >>> 5;
			else if (has_above || has_left) dc_v = (sum + 8) >>> 4;
			else dc_v = 8'd128;
			for (i = 0; i < 256; i = i + 1) pred[i] = dc_v;
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
