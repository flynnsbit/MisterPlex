// H.264 Motion Compensation Interpolation Engine
// Block-level luma quarter-pel and chroma eighth-pel interpolation.
// Designed for 64-bit coalesced reference access.
//
// Interface:
//   cmd_*     — command port: block dimensions, fractional MV, mode
//   ref_*     — 64-bit reference data input (row-major, row by row)
//   pred_*    — predicted sample output (one sample per cycle)
//
// Operation:
//   1. Accept a command (block size, luma/chroma, fractional MV)
//   2. Receive reference window data via 64-bit port
//   3. Compute interpolated samples for the entire block
//   4. Stream out predicted samples one per cycle
//
// Reference window sizes:
//   Luma:   (blk_w + 5) cols × (blk_h + 5) rows  (6-tap needs [-2..+3])
//   Chroma: (blk_w + 1) cols × (blk_h + 1) rows  (bilinear needs [0..+1])
//
// The caller (w-rel) is responsible for fetching the reference window from DDR
// with edge clamping applied, and streaming it in row-major order via ref_data.
`default_nettype none

module h264_mc_interp (
	input  wire        clk,
	input  wire        rst_n,

	// Command interface
	input  wire        cmd_valid,
	output reg         cmd_ready,
	input  wire        cmd_is_chroma,   // 0 = luma, 1 = chroma
	input  wire [1:0]  cmd_frac_x,      // luma quarter-pel x fraction (0-3)
	input  wire [1:0]  cmd_frac_y,      // luma quarter-pel y fraction (0-3)
	input  wire [2:0]  cmd_chroma_dx,   // chroma eighth-pel x fraction (0-7)
	input  wire [2:0]  cmd_chroma_dy,   // chroma eighth-pel y fraction (0-7)
	input  wire [4:0]  cmd_blk_w,       // output block width  (4, 8, or 16)
	input  wire [4:0]  cmd_blk_h,       // output block height (4, 8, or 16)

	// Reference data input — 64 bits, row-major, MSB-first byte order
	// Caller streams the full reference window: luma (blk_w+5)×(blk_h+5)
	// or chroma (blk_w+1)×(blk_h+1) samples, packed into 64-bit words.
	input  wire        ref_valid,
	output reg         ref_ready,
	input  wire [63:0] ref_data,
	input  wire [3:0]  ref_byte_count,  // valid bytes in this word (1-8)

	// Predicted sample output
	output reg         pred_valid,
	input  wire        pred_ready,
	output reg  [7:0]  pred_sample,
	output reg         pred_last        // asserted on the final sample
);

	// -----------------------------------------------------------------------
	// Reference buffer — max 21×21 = 441 bytes for luma 16×16 at quarter-pel
	// Addressed linearly: buf[row * ref_cols + col]
	// -----------------------------------------------------------------------
	localparam REF_BUF_SIZE = 512; // next power of 2 >= 441
	reg [7:0] ref_buf [0:REF_BUF_SIZE-1];
	reg [9:0] ref_wr_ptr;          // write pointer into ref_buf
	reg [9:0] ref_total;           // total bytes expected for this window

	// Latched command parameters
	reg        is_chroma;
	reg [1:0]  frac_x;
	reg [1:0]  frac_y;
	reg [2:0]  chroma_dx;
	reg [2:0]  chroma_dy;
	reg [4:0]  blk_w;
	reg [4:0]  blk_h;
	reg [4:0]  ref_cols;   // reference window width
	reg [4:0]  ref_rows;   // reference window height

	// Output iteration
	reg [4:0]  out_row;
	reg [4:0]  out_col;
	reg [7:0]  out_total;     // blk_w × blk_h
	reg [7:0]  out_count;     // samples output so far

	// State machine
	localparam [1:0] S_IDLE    = 2'd0;
	localparam [1:0] S_LOAD    = 2'd1;
	localparam [1:0] S_COMPUTE = 2'd2;
	reg [1:0] state;

	// -----------------------------------------------------------------------
	// Luma 6-tap filter — horizontal raw (full precision, no rounding)
	// -----------------------------------------------------------------------
	function automatic signed [20:0] luma_h6_raw;
		input [9:0] base;  // index of center sample in ref_buf
		begin
			luma_h6_raw = $signed({1'b0, 12'd0, ref_buf[base - 10'd2]})
			            - $signed({1'b0, 12'd0, ref_buf[base - 10'd1]}) * 21'sd5
			            + $signed({1'b0, 12'd0, ref_buf[base]})         * 21'sd20
			            + $signed({1'b0, 12'd0, ref_buf[base + 10'd1]}) * 21'sd20
			            - $signed({1'b0, 12'd0, ref_buf[base + 10'd2]}) * 21'sd5
			            + $signed({1'b0, 12'd0, ref_buf[base + 10'd3]});
		end
	endfunction

	// -----------------------------------------------------------------------
	// Clip to [0, 255]
	// -----------------------------------------------------------------------
	function automatic [7:0] clip1;
		input signed [31:0] v;
		begin
			if (v < 0) clip1 = 8'd0;
			else if (v > 255) clip1 = 8'd255;
			else clip1 = v[7:0];
		end
	endfunction

	// -----------------------------------------------------------------------
	// Reference buffer index for (row, col) in the reference window
	// -----------------------------------------------------------------------
	function automatic [9:0] ridx;
		input [4:0] row;
		input [4:0] col;
		begin
			ridx = {5'd0, row} * {5'd0, ref_cols} + {5'd0, col};
		end
	endfunction

	// -----------------------------------------------------------------------
	// Compute one luma sample at output position (out_row, out_col)
	// Reference window origin is at (-2, -2) relative to the integer-pel.
	// So the integer-pel sample for output (r, c) is at ref_buf row (r+2),
	// col (c+2). Centre of the 6-tap window for that sample is also (r+2, c+2).
	// -----------------------------------------------------------------------
	reg [7:0] luma_result;

	// Intermediate wires for luma computation (always computed, used in S_COMPUTE)
	wire [4:0] luma_ref_row = out_row + 5'd2;  // row of integer-pel in ref window
	wire [4:0] luma_ref_col = out_col + 5'd2;  // col of integer-pel in ref window

	// Integer-pel samples
	wire [7:0] pix_G  = ref_buf[ridx(luma_ref_row, luma_ref_col)];
	wire [7:0] pix_H  = ref_buf[ridx(luma_ref_row, luma_ref_col + 5'd1)];
	wire [7:0] pix_M  = ref_buf[ridx(luma_ref_row + 5'd1, luma_ref_col)];

	// Half-pel horizontal 'b' at (int_x, int_y)
	wire [9:0] b_base = ridx(luma_ref_row, luma_ref_col);
	wire signed [20:0] b_raw = luma_h6_raw(b_base);
	wire [7:0] half_b = clip1((b_raw + 21'sd16) >>> 5);

	// Half-pel vertical 'h' at (int_x, int_y)
	wire signed [20:0] h_raw =
		$signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row - 5'd2, luma_ref_col)]})
		- $signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row - 5'd1, luma_ref_col)]}) * 21'sd5
		+ $signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row,       luma_ref_col)]}) * 21'sd20
		+ $signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row + 5'd1, luma_ref_col)]}) * 21'sd20
		- $signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row + 5'd2, luma_ref_col)]}) * 21'sd5
		+ $signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row + 5'd3, luma_ref_col)]});
	wire [7:0] half_h = clip1((h_raw + 21'sd16) >>> 5);

	// Half-pel vertical 'k' at (int_x+1, int_y) — right of h
	wire signed [20:0] k_raw =
		$signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row - 5'd2, luma_ref_col + 5'd1)]})
		- $signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row - 5'd1, luma_ref_col + 5'd1)]}) * 21'sd5
		+ $signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row,       luma_ref_col + 5'd1)]}) * 21'sd20
		+ $signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row + 5'd1, luma_ref_col + 5'd1)]}) * 21'sd20
		- $signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row + 5'd2, luma_ref_col + 5'd1)]}) * 21'sd5
		+ $signed({1'b0, 12'd0, ref_buf[ridx(luma_ref_row + 5'd3, luma_ref_col + 5'd1)]});
	wire [7:0] half_k = clip1((k_raw + 21'sd16) >>> 5);

	// Half-pel horizontal 's' at (int_x, int_y+1) — below b
	wire [9:0] s_base = ridx(luma_ref_row + 5'd1, luma_ref_col);
	wire signed [20:0] s_raw = luma_h6_raw(s_base);
	wire [7:0] half_s = clip1((s_raw + 21'sd16) >>> 5);

	// Centre half-pel 'j': vertical 6-tap on horizontal intermediates
	// Horizontal intermediates at rows (int_y-2)..(int_y+3)
	wire signed [20:0] j_h0 = luma_h6_raw(ridx(luma_ref_row - 5'd2, luma_ref_col));
	wire signed [20:0] j_h1 = luma_h6_raw(ridx(luma_ref_row - 5'd1, luma_ref_col));
	wire signed [20:0] j_h2 = luma_h6_raw(ridx(luma_ref_row,        luma_ref_col));
	wire signed [20:0] j_h3 = luma_h6_raw(ridx(luma_ref_row + 5'd1, luma_ref_col));
	wire signed [20:0] j_h4 = luma_h6_raw(ridx(luma_ref_row + 5'd2, luma_ref_col));
	wire signed [20:0] j_h5 = luma_h6_raw(ridx(luma_ref_row + 5'd3, luma_ref_col));
	wire signed [31:0] j_sum = j_h0 - 32'sd5 * j_h1 + 32'sd20 * j_h2
	                         + 32'sd20 * j_h3 - 32'sd5 * j_h4 + j_h5;
	wire [7:0] half_j = clip1((j_sum + 32'sd512) >>> 10);

	// Bilinear average
	function automatic [7:0] avg2;
		input [7:0] a;
		input [7:0] b;
		begin
			avg2 = ({1'b0, a} + {1'b0, b} + 9'd1) >> 1;
		end
	endfunction

	// Luma sub-position mux
	always @* begin
		case ({frac_y, frac_x})
			4'b0000: luma_result = pix_G;
			4'b0001: luma_result = avg2(pix_G, half_b);
			4'b0010: luma_result = half_b;
			4'b0011: luma_result = avg2(half_b, pix_H);
			4'b0100: luma_result = avg2(pix_G, half_h);
			4'b0101: luma_result = avg2(half_b, half_h);
			4'b0110: luma_result = avg2(half_b, half_j);
			4'b0111: luma_result = avg2(half_b, half_k);
			4'b1000: luma_result = half_h;
			4'b1001: luma_result = avg2(half_h, half_j);
			4'b1010: luma_result = half_j;
			4'b1011: luma_result = avg2(half_j, half_k);
			4'b1100: luma_result = avg2(half_h, pix_M);
			4'b1101: luma_result = avg2(half_s, half_h);
			4'b1110: luma_result = avg2(half_j, half_s);
			4'b1111: luma_result = avg2(half_s, half_k);
		endcase
	end

	// -----------------------------------------------------------------------
	// Chroma eighth-pel bilinear interpolation
	// Reference window origin is at (0, 0) relative to the integer-pel.
	// Output (r, c) uses ref samples at (r, c), (r, c+1), (r+1, c), (r+1, c+1).
	// -----------------------------------------------------------------------
	wire [7:0] c_p00 = ref_buf[ridx(out_row, out_col)];
	wire [7:0] c_p10 = ref_buf[ridx(out_row, out_col + 5'd1)];
	wire [7:0] c_p01 = ref_buf[ridx(out_row + 5'd1, out_col)];
	wire [7:0] c_p11 = ref_buf[ridx(out_row + 5'd1, out_col + 5'd1)];

	wire [3:0] cwx0 = 4'd8 - {1'b0, chroma_dx};
	wire [3:0] cwy0 = 4'd8 - {1'b0, chroma_dy};
	wire [3:0] cwx1 = {1'b0, chroma_dx};
	wire [3:0] cwy1 = {1'b0, chroma_dy};

	wire [15:0] chroma_sum = cwx0 * cwy0 * {8'd0, c_p00}
	                       + cwx1 * cwy0 * {8'd0, c_p10}
	                       + cwx0 * cwy1 * {8'd0, c_p01}
	                       + cwx1 * cwy1 * {8'd0, c_p11}
	                       + 16'd32;
	wire [7:0] chroma_result = chroma_sum[13:6];

	// -----------------------------------------------------------------------
	// Compute the final sample (luma or chroma)
	// -----------------------------------------------------------------------
	wire [7:0] computed_sample = is_chroma ? chroma_result : luma_result;

	// -----------------------------------------------------------------------
	// Reference data unpacking — extract individual bytes from 64-bit word
	// -----------------------------------------------------------------------
	wire [7:0] ref_byte [0:7];
	assign ref_byte[0] = ref_data[63:56];
	assign ref_byte[1] = ref_data[55:48];
	assign ref_byte[2] = ref_data[47:40];
	assign ref_byte[3] = ref_data[39:32];
	assign ref_byte[4] = ref_data[31:24];
	assign ref_byte[5] = ref_data[23:16];
	assign ref_byte[6] = ref_data[15:8];
	assign ref_byte[7] = ref_data[7:0];

	// -----------------------------------------------------------------------
	// State machine
	// -----------------------------------------------------------------------
	integer i;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state     <= S_IDLE;
			cmd_ready <= 1'b1;
			ref_ready <= 1'b0;
			pred_valid <= 1'b0;
			pred_sample <= 8'd0;
			pred_last  <= 1'b0;
			ref_wr_ptr <= 10'd0;
			ref_total  <= 10'd0;
			out_row    <= 5'd0;
			out_col    <= 5'd0;
			out_total  <= 8'd0;
			out_count  <= 8'd0;
			is_chroma  <= 1'b0;
			frac_x     <= 2'd0;
			frac_y     <= 2'd0;
			chroma_dx  <= 3'd0;
			chroma_dy  <= 3'd0;
			blk_w      <= 5'd0;
			blk_h      <= 5'd0;
			ref_cols   <= 5'd0;
			ref_rows   <= 5'd0;
		end else begin
			case (state)
			S_IDLE: begin
				pred_valid <= 1'b0;
				pred_last  <= 1'b0;
				if (cmd_valid && cmd_ready) begin
					// Latch command
					is_chroma  <= cmd_is_chroma;
					frac_x     <= cmd_frac_x;
					frac_y     <= cmd_frac_y;
					chroma_dx  <= cmd_chroma_dx;
					chroma_dy  <= cmd_chroma_dy;
					blk_w      <= cmd_blk_w;
					blk_h      <= cmd_blk_h;
					if (cmd_is_chroma) begin
						ref_cols <= cmd_blk_w + 5'd1;
						ref_rows <= cmd_blk_h + 5'd1;
						ref_total <= ({5'd0, cmd_blk_w} + 10'd1) *
						             ({5'd0, cmd_blk_h} + 10'd1);
					end else begin
						ref_cols <= cmd_blk_w + 5'd5;
						ref_rows <= cmd_blk_h + 5'd5;
						ref_total <= ({5'd0, cmd_blk_w} + 10'd5) *
						             ({5'd0, cmd_blk_h} + 10'd5);
					end
					out_total  <= cmd_blk_w[4:0] * cmd_blk_h[4:0];
					ref_wr_ptr <= 10'd0;
					out_row    <= 5'd0;
					out_col    <= 5'd0;
					out_count  <= 8'd0;
					cmd_ready  <= 1'b0;
					ref_ready  <= 1'b1;
					state      <= S_LOAD;
				end
			end

			S_LOAD: begin
				if (ref_valid && ref_ready) begin
					// Store incoming bytes into reference buffer
					for (i = 0; i < 8; i = i + 1) begin
						if (i[3:0] < ref_byte_count &&
						    (ref_wr_ptr + i[3:0]) < REF_BUF_SIZE[9:0]) begin
							ref_buf[ref_wr_ptr + i[3:0]] <= ref_byte[i];
						end
					end
					ref_wr_ptr <= ref_wr_ptr + {6'd0, ref_byte_count};

					// Check if we've received all reference data
					if ((ref_wr_ptr + {6'd0, ref_byte_count}) >= ref_total) begin
						ref_ready <= 1'b0;
						state     <= S_COMPUTE;
					end
				end
			end

			S_COMPUTE: begin
				if (!pred_valid || pred_ready) begin
					pred_valid  <= 1'b1;
					pred_sample <= computed_sample;
					out_count   <= out_count + 8'd1;

					if (out_count + 8'd1 == out_total) begin
						pred_last <= 1'b1;
					end else begin
						pred_last <= 1'b0;
					end

					// Advance output position
					if (out_col + 5'd1 == blk_w) begin
						out_col <= 5'd0;
						out_row <= out_row + 5'd1;
					end else begin
						out_col <= out_col + 5'd1;
					end

					// Check completion
					if (out_count + 8'd1 == out_total) begin
						state     <= S_IDLE;
						cmd_ready <= 1'b1;
						ref_ready <= 1'b0;
					end
				end
			end

			default: begin
				state     <= S_IDLE;
				cmd_ready <= 1'b1;
			end
			endcase
		end
	end

	// -----------------------------------------------------------------------
	// Cycle counter — measure cycles from cmd accept to last pred_valid
	// -----------------------------------------------------------------------
	reg [15:0] cycle_count;
	reg        counting;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			cycle_count <= 16'd0;
			counting    <= 1'b0;
		end else begin
			if (state == S_IDLE && cmd_valid && cmd_ready) begin
				cycle_count <= 16'd1;
				counting    <= 1'b1;
			end else if (counting) begin
				cycle_count <= cycle_count + 16'd1;
				if (pred_valid && pred_ready && pred_last)
					counting <= 1'b0;
			end
		end
	end

endmodule

`default_nettype wire
