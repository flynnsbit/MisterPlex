// H.264 Motion Compensation Interpolation Engine — v3
// Block-level luma quarter-pel and chroma eighth-pel interpolation.
//
// Budget: 250 cycles/MB (37% of 684 total at 20 MHz).
//
// *** PERFORMANCE CAVEAT ***
// The measured 220 cycles/MB is a LOWER BOUND under ideal memory conditions:
// reference data always available when ref_ready is high, no DDR latency,
// no arbiter contention. Real DDR stalls add 1:1 to this number. 220 is a
// property of the compute datapath, not of the system. The system number
// depends entirely on w-dpb's ability to deliver 64-bit words without stalling.
//
// v3 architecture:
//   - 2-wide output: 2 samples per cycle (mandatory to hit budget)
//   - Pipelined load/compute: compute starts as soon as enough rows loaded
//   - Reference cache: exact-match skip; coordinates exposed for future
//     partial-overlap (sliding window) by w-rel
//   - P_Skip fast path: cmd_skip_zero bypasses FIR, fetches blk_w×blk_h
//     instead of (blk_w+5)×(blk_h+5), saving 42% DPB bandwidth
//
// Cycle budget analysis (16×16 MB):
//   Quarter-pel j (worst): startup 18 + compute 128 = 146 cycles
//   P_Skip (best): startup ~2 + compute 128 = 130 cycles (42% less BW)
//   Chroma: 2 × (startup 4 + compute 32) = 72 cycles
//   Overhead: 6 cycles
//   Total: 130–224 cycles → within 250
//
// Interface:
//   cmd_*     — command port with cache-support coordinates
//   ref_*     — 64-bit reference data input
//   pred_*    — 2-wide predicted sample output
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
	// P_Skip fast path: integer-pel, no interpolation.
	// Bypasses FIR, fetches blk_w×blk_h instead of (blk_w+5)×(blk_h+5).
	input  wire        cmd_skip_zero,
	// Cache-support: absolute ref window position in picture coordinates.
	// When identical to previous command, reference load is skipped.
	input  wire signed [15:0] cmd_ref_x,
	input  wire signed [15:0] cmd_ref_y,

	// Reference data input — 64 bits, row-major, MSB-first byte order
	input  wire        ref_valid,
	output reg         ref_ready,
	input  wire [63:0] ref_data,
	input  wire [3:0]  ref_byte_count,  // valid bytes in this word (1-8)

	// Predicted sample output — 2 samples per cycle
	output reg         pred_valid,
	input  wire        pred_ready,
	output reg  [7:0]  pred_sample0,    // always valid when pred_valid
	output reg  [7:0]  pred_sample1,    // valid when pred_pair
	output reg         pred_pair,       // 1 = two valid samples this cycle
	output reg         pred_last,       // last output for this block

	// Performance counter (cycles from cmd accept to last pred output)
	output reg  [15:0] cycle_count
);

	// -----------------------------------------------------------------------
	// Reference buffer — max 21×21 = 441 bytes for luma 16×16
	// -----------------------------------------------------------------------
	localparam REF_BUF_SIZE = 512;
	reg [7:0] ref_buf [0:REF_BUF_SIZE-1];
	reg [9:0] ref_wr_ptr;
	reg [9:0] ref_total;

	// Row-completion tracking for pipelined load/compute
	reg [4:0]  rows_loaded;        // complete rows in buffer
	reg [9:0]  next_row_boundary;  // byte count at which rows_loaded increments

	// Cache state
	reg        cache_valid;
	reg signed [15:0] cache_ref_x, cache_ref_y;
	reg [4:0]  cache_ref_cols, cache_ref_rows;
	reg        cache_is_chroma;
	reg        cache_skip_zero;

	// Latched command parameters
	reg        is_chroma;
	reg [1:0]  frac_x;
	reg [1:0]  frac_y;
	reg [2:0]  chroma_dx;
	reg [2:0]  chroma_dy;
	reg [4:0]  blk_w;
	reg [4:0]  blk_h;
	reg [4:0]  ref_cols;
	reg [4:0]  ref_rows;
	reg        skip_zero;  // P_Skip: bypass FIR, direct copy

	// Output iteration — col advances by 2 per cycle
	reg [4:0]  out_row;
	reg [4:0]  out_col;
	reg [8:0]  out_total;    // blk_w × blk_h (up to 256)
	reg [8:0]  out_count;    // samples output so far (counts by 2)

	// State machine
	localparam [1:0] S_IDLE    = 2'd0;
	localparam [1:0] S_PROCESS = 2'd1;  // combined load + compute
	reg [1:0] state;
	reg       load_done;     // all reference data received

	// -----------------------------------------------------------------------
	// Helper functions
	// -----------------------------------------------------------------------
	function automatic [7:0] clip1;
		input signed [31:0] v;
		begin
			if (v < 0) clip1 = 8'd0;
			else if (v > 255) clip1 = 8'd255;
			else clip1 = v[7:0];
		end
	endfunction

	function automatic [7:0] avg2;
		input [7:0] a;
		input [7:0] b;
		begin
			avg2 = ({1'b0, a} + {1'b0, b} + 9'd1) >> 1;
		end
	endfunction

	function automatic [9:0] ridx;
		input [4:0] row;
		input [4:0] col;
		begin
			ridx = {5'd0, row} * {5'd0, ref_cols} + {5'd0, col};
		end
	endfunction

	function automatic signed [20:0] luma_h6_raw;
		input [9:0] base;
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
	// Can-compute: enough rows loaded for current output row?
	// Luma needs rows out_row..out_row+5 (6 rows for j-position 6-tap)
	// Chroma needs rows out_row..out_row+1 (2 rows for bilinear)
	// -----------------------------------------------------------------------
	wire [4:0] rows_needed = skip_zero  ? (out_row + 5'd1) :
	                         is_chroma ? (out_row + 5'd2) : (out_row + 5'd6);
	wire       can_compute = load_done || (rows_loaded >= rows_needed);
	wire       compute_done = (out_count >= out_total);

	// -----------------------------------------------------------------------
	// LUMA SAMPLE 0 — at output position (out_row, out_col)
	// Centre in ref window: (out_row+2, out_col+2)
	// -----------------------------------------------------------------------
	wire [4:0] lr0 = out_row + 5'd2;   // luma ref row for sample 0
	wire [4:0] lc0 = out_col + 5'd2;   // luma ref col for sample 0

	// Integer-pel
	wire [7:0] pix_G0  = ref_buf[ridx(lr0, lc0)];
	wire [7:0] pix_H0  = ref_buf[ridx(lr0, lc0 + 5'd1)];
	wire [7:0] pix_M0  = ref_buf[ridx(lr0 + 5'd1, lc0)];

	// Horizontal half-pel 'b0'
	wire signed [20:0] b0_raw = luma_h6_raw(ridx(lr0, lc0));
	wire [7:0] half_b0 = clip1((b0_raw + 21'sd16) >>> 5);

	// Vertical half-pel 'h0' at (lr0, lc0)
	wire signed [20:0] h0_raw =
		$signed({1'b0, 12'd0, ref_buf[ridx(lr0 - 5'd2, lc0)]})
		- $signed({1'b0, 12'd0, ref_buf[ridx(lr0 - 5'd1, lc0)]}) * 21'sd5
		+ $signed({1'b0, 12'd0, ref_buf[ridx(lr0,        lc0)]}) * 21'sd20
		+ $signed({1'b0, 12'd0, ref_buf[ridx(lr0 + 5'd1, lc0)]}) * 21'sd20
		- $signed({1'b0, 12'd0, ref_buf[ridx(lr0 + 5'd2, lc0)]}) * 21'sd5
		+ $signed({1'b0, 12'd0, ref_buf[ridx(lr0 + 5'd3, lc0)]});
	wire [7:0] half_h0 = clip1((h0_raw + 21'sd16) >>> 5);

	// Vertical half-pel 'k0' at (lr0, lc0+1) — reused as h1 for sample 1
	wire signed [20:0] k0_raw =
		$signed({1'b0, 12'd0, ref_buf[ridx(lr0 - 5'd2, lc0 + 5'd1)]})
		- $signed({1'b0, 12'd0, ref_buf[ridx(lr0 - 5'd1, lc0 + 5'd1)]}) * 21'sd5
		+ $signed({1'b0, 12'd0, ref_buf[ridx(lr0,        lc0 + 5'd1)]}) * 21'sd20
		+ $signed({1'b0, 12'd0, ref_buf[ridx(lr0 + 5'd1, lc0 + 5'd1)]}) * 21'sd20
		- $signed({1'b0, 12'd0, ref_buf[ridx(lr0 + 5'd2, lc0 + 5'd1)]}) * 21'sd5
		+ $signed({1'b0, 12'd0, ref_buf[ridx(lr0 + 5'd3, lc0 + 5'd1)]});
	wire [7:0] half_k0 = clip1((k0_raw + 21'sd16) >>> 5);

	// Horizontal half-pel 's0' at (lr0+1, lc0) — below b0
	wire signed [20:0] s0_raw = luma_h6_raw(ridx(lr0 + 5'd1, lc0));
	wire [7:0] half_s0 = clip1((s0_raw + 21'sd16) >>> 5);

	// Centre half-pel 'j0': vertical 6-tap on horizontal intermediates
	wire signed [20:0] j0_h0 = luma_h6_raw(ridx(lr0 - 5'd2, lc0));
	wire signed [20:0] j0_h1 = luma_h6_raw(ridx(lr0 - 5'd1, lc0));
	wire signed [20:0] j0_h2 = b0_raw;  // same position
	wire signed [20:0] j0_h3 = s0_raw;  // same position
	wire signed [20:0] j0_h4 = luma_h6_raw(ridx(lr0 + 5'd2, lc0));
	wire signed [20:0] j0_h5 = luma_h6_raw(ridx(lr0 + 5'd3, lc0));
	wire signed [31:0] j0_sum = j0_h0 - 32'sd5 * j0_h1 + 32'sd20 * j0_h2
	                          + 32'sd20 * j0_h3 - 32'sd5 * j0_h4 + j0_h5;
	wire [7:0] half_j0 = clip1((j0_sum + 32'sd512) >>> 10);

	// Sample 0 sub-position mux
	reg [7:0] luma0;
	always @* begin
		case ({frac_y, frac_x})
			4'b0000: luma0 = pix_G0;
			4'b0001: luma0 = avg2(pix_G0, half_b0);
			4'b0010: luma0 = half_b0;
			4'b0011: luma0 = avg2(half_b0, pix_H0);
			4'b0100: luma0 = avg2(pix_G0, half_h0);
			4'b0101: luma0 = avg2(half_b0, half_h0);
			4'b0110: luma0 = avg2(half_b0, half_j0);
			4'b0111: luma0 = avg2(half_b0, half_k0);
			4'b1000: luma0 = half_h0;
			4'b1001: luma0 = avg2(half_h0, half_j0);
			4'b1010: luma0 = half_j0;
			4'b1011: luma0 = avg2(half_j0, half_k0);
			4'b1100: luma0 = avg2(half_h0, pix_M0);
			4'b1101: luma0 = avg2(half_s0, half_h0);
			4'b1110: luma0 = avg2(half_j0, half_s0);
			4'b1111: luma0 = avg2(half_s0, half_k0);
		endcase
	end

	// -----------------------------------------------------------------------
	// LUMA SAMPLE 1 — at output position (out_row, out_col+1)
	// Centre in ref window: (out_row+2, out_col+3)
	// Exploits sharing: pix_G1 = pix_H0, half_h1 = half_k0
	// -----------------------------------------------------------------------
	wire [4:0] lc1 = out_col + 5'd3;   // ref col for sample 1

	// Integer-pel (pix_G1 = pix_H0, reused)
	wire [7:0] pix_G1  = pix_H0;
	wire [7:0] pix_H1  = ref_buf[ridx(lr0, lc1 + 5'd1)];
	wire [7:0] pix_M1  = ref_buf[ridx(lr0 + 5'd1, lc1)];

	// Horizontal half-pel 'b1'
	wire signed [20:0] b1_raw = luma_h6_raw(ridx(lr0, lc1));
	wire [7:0] half_b1 = clip1((b1_raw + 21'sd16) >>> 5);

	// Vertical half-pel 'h1' = k0 (reused)
	wire [7:0] half_h1 = half_k0;

	// Vertical half-pel 'k1' at (lr0, lc1+1)
	wire signed [20:0] k1_raw =
		$signed({1'b0, 12'd0, ref_buf[ridx(lr0 - 5'd2, lc1 + 5'd1)]})
		- $signed({1'b0, 12'd0, ref_buf[ridx(lr0 - 5'd1, lc1 + 5'd1)]}) * 21'sd5
		+ $signed({1'b0, 12'd0, ref_buf[ridx(lr0,        lc1 + 5'd1)]}) * 21'sd20
		+ $signed({1'b0, 12'd0, ref_buf[ridx(lr0 + 5'd1, lc1 + 5'd1)]}) * 21'sd20
		- $signed({1'b0, 12'd0, ref_buf[ridx(lr0 + 5'd2, lc1 + 5'd1)]}) * 21'sd5
		+ $signed({1'b0, 12'd0, ref_buf[ridx(lr0 + 5'd3, lc1 + 5'd1)]});
	wire [7:0] half_k1 = clip1((k1_raw + 21'sd16) >>> 5);

	// Horizontal half-pel 's1' at (lr0+1, lc1)
	wire signed [20:0] s1_raw = luma_h6_raw(ridx(lr0 + 5'd1, lc1));
	wire [7:0] half_s1 = clip1((s1_raw + 21'sd16) >>> 5);

	// Centre half-pel 'j1'
	wire signed [20:0] j1_h0 = luma_h6_raw(ridx(lr0 - 5'd2, lc1));
	wire signed [20:0] j1_h1 = luma_h6_raw(ridx(lr0 - 5'd1, lc1));
	wire signed [20:0] j1_h2 = b1_raw;
	wire signed [20:0] j1_h3 = s1_raw;
	wire signed [20:0] j1_h4 = luma_h6_raw(ridx(lr0 + 5'd2, lc1));
	wire signed [20:0] j1_h5 = luma_h6_raw(ridx(lr0 + 5'd3, lc1));
	wire signed [31:0] j1_sum = j1_h0 - 32'sd5 * j1_h1 + 32'sd20 * j1_h2
	                          + 32'sd20 * j1_h3 - 32'sd5 * j1_h4 + j1_h5;
	wire [7:0] half_j1 = clip1((j1_sum + 32'sd512) >>> 10);

	// Sample 1 sub-position mux
	reg [7:0] luma1;
	always @* begin
		case ({frac_y, frac_x})
			4'b0000: luma1 = pix_G1;
			4'b0001: luma1 = avg2(pix_G1, half_b1);
			4'b0010: luma1 = half_b1;
			4'b0011: luma1 = avg2(half_b1, pix_H1);
			4'b0100: luma1 = avg2(pix_G1, half_h1);
			4'b0101: luma1 = avg2(half_b1, half_h1);
			4'b0110: luma1 = avg2(half_b1, half_j1);
			4'b0111: luma1 = avg2(half_b1, half_k1);
			4'b1000: luma1 = half_h1;
			4'b1001: luma1 = avg2(half_h1, half_j1);
			4'b1010: luma1 = half_j1;
			4'b1011: luma1 = avg2(half_j1, half_k1);
			4'b1100: luma1 = avg2(half_h1, pix_M1);
			4'b1101: luma1 = avg2(half_s1, half_h1);
			4'b1110: luma1 = avg2(half_j1, half_s1);
			4'b1111: luma1 = avg2(half_s1, half_k1);
		endcase
	end

	// -----------------------------------------------------------------------
	// CHROMA — 2-wide eighth-pel bilinear
	// Sample 0 at (out_row, out_col), Sample 1 at (out_row, out_col+1)
	// -----------------------------------------------------------------------
	wire [7:0] c0_p00 = ref_buf[ridx(out_row, out_col)];
	wire [7:0] c0_p10 = ref_buf[ridx(out_row, out_col + 5'd1)];
	wire [7:0] c0_p01 = ref_buf[ridx(out_row + 5'd1, out_col)];
	wire [7:0] c0_p11 = ref_buf[ridx(out_row + 5'd1, out_col + 5'd1)];

	// Sample 1 shares p10/p11 as p00/p01
	wire [7:0] c1_p00 = c0_p10;
	wire [7:0] c1_p10 = ref_buf[ridx(out_row, out_col + 5'd2)];
	wire [7:0] c1_p01 = c0_p11;
	wire [7:0] c1_p11 = ref_buf[ridx(out_row + 5'd1, out_col + 5'd2)];

	wire [3:0] cwx0 = 4'd8 - {1'b0, chroma_dx};
	wire [3:0] cwy0 = 4'd8 - {1'b0, chroma_dy};
	wire [3:0] cwx1 = {1'b0, chroma_dx};
	wire [3:0] cwy1 = {1'b0, chroma_dy};

	wire [15:0] chr0_sum = cwx0 * cwy0 * {8'd0, c0_p00}
	                     + cwx1 * cwy0 * {8'd0, c0_p10}
	                     + cwx0 * cwy1 * {8'd0, c0_p01}
	                     + cwx1 * cwy1 * {8'd0, c0_p11}
	                     + 16'd32;
	wire [7:0] chroma0 = chr0_sum[13:6];

	wire [15:0] chr1_sum = cwx0 * cwy0 * {8'd0, c1_p00}
	                     + cwx1 * cwy0 * {8'd0, c1_p10}
	                     + cwx0 * cwy1 * {8'd0, c1_p01}
	                     + cwx1 * cwy1 * {8'd0, c1_p11}
	                     + 16'd32;
	wire [7:0] chroma1 = chr1_sum[13:6];

	// -----------------------------------------------------------------------
	// P_Skip fast path — direct copy from buffer, no interpolation
	// Reference window is blk_w×blk_h (no border), so indices are direct
	// -----------------------------------------------------------------------
	wire [7:0] skip0 = ref_buf[ridx(out_row, out_col)];
	wire [7:0] skip1 = ref_buf[ridx(out_row, out_col + 5'd1)];

	// -----------------------------------------------------------------------
	// Final computed samples (skip, luma, or chroma, 2-wide)
	// -----------------------------------------------------------------------
	wire [7:0] computed0 = skip_zero  ? skip0  : is_chroma ? chroma0 : luma0;
	wire [7:0] computed1 = skip_zero  ? skip1  : is_chroma ? chroma1 : luma1;

	// -----------------------------------------------------------------------
	// Reference data unpacking
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
	// Cache hit detection
	// -----------------------------------------------------------------------
	wire [4:0] new_ref_cols = cmd_skip_zero ? cmd_blk_w :
	                         cmd_is_chroma ? (cmd_blk_w + 5'd1) : (cmd_blk_w + 5'd5);
	wire [4:0] new_ref_rows = cmd_skip_zero ? cmd_blk_h :
	                          cmd_is_chroma ? (cmd_blk_h + 5'd1) : (cmd_blk_h + 5'd5);
	wire       cache_hit = cache_valid
	                     && (cmd_ref_x == cache_ref_x)
	                     && (cmd_ref_y == cache_ref_y)
	                     && (new_ref_cols == cache_ref_cols)
	                     && (new_ref_rows == cache_ref_rows)
	                     && (cmd_is_chroma == cache_is_chroma)
	                     && (cmd_skip_zero == cache_skip_zero);

	// -----------------------------------------------------------------------
	// State machine — pipelined load/compute
	// -----------------------------------------------------------------------
	integer i;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state          <= S_IDLE;
			cmd_ready      <= 1'b1;
			ref_ready      <= 1'b0;
			pred_valid     <= 1'b0;
			pred_sample0   <= 8'd0;
			pred_sample1   <= 8'd0;
			pred_pair      <= 1'b0;
			pred_last      <= 1'b0;
			ref_wr_ptr     <= 10'd0;
			ref_total      <= 10'd0;
			rows_loaded    <= 5'd0;
			next_row_boundary <= 10'd0;
			load_done      <= 1'b0;
			out_row        <= 5'd0;
			out_col        <= 5'd0;
			out_total      <= 9'd0;
			out_count      <= 9'd0;
			is_chroma      <= 1'b0;
			frac_x         <= 2'd0;
			frac_y         <= 2'd0;
			chroma_dx      <= 3'd0;
			chroma_dy      <= 3'd0;
			blk_w          <= 5'd0;
			blk_h          <= 5'd0;
			ref_cols       <= 5'd0;
			ref_rows       <= 5'd0;
			cache_valid    <= 1'b0;
			cache_ref_x    <= 16'sd0;
			cache_ref_y    <= 16'sd0;
			cache_ref_cols <= 5'd0;
			cache_ref_rows <= 5'd0;
			cache_is_chroma <= 1'b0;
			cache_skip_zero <= 1'b0;
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
					skip_zero  <= cmd_skip_zero;
					ref_cols   <= new_ref_cols;
					ref_rows   <= new_ref_rows;
					ref_total  <= {5'd0, new_ref_cols} * {5'd0, new_ref_rows};
					out_total  <= {4'd0, cmd_blk_w} * {4'd0, cmd_blk_h};
					out_row    <= 5'd0;
					out_col    <= 5'd0;
					out_count  <= 9'd0;
					cmd_ready  <= 1'b0;

					if (cache_hit) begin
						// Skip loading — buffer already has the data
						load_done      <= 1'b1;
						ref_ready      <= 1'b0;
						ref_wr_ptr     <= ref_total;
						rows_loaded    <= new_ref_rows;
						next_row_boundary <= {5'd0, new_ref_cols} * {5'd0, new_ref_rows};
					end else begin
						load_done      <= 1'b0;
						ref_ready      <= 1'b1;
						ref_wr_ptr     <= 10'd0;
						rows_loaded    <= 5'd0;
						next_row_boundary <= {5'd0, new_ref_cols};
					end
					state <= S_PROCESS;
				end
			end

			S_PROCESS: begin
				// === Loading path ===
				if (!load_done && ref_valid && ref_ready) begin
					for (i = 0; i < 8; i = i + 1) begin
						if (i[3:0] < ref_byte_count &&
						    (ref_wr_ptr + i[3:0]) < REF_BUF_SIZE[9:0]) begin
							ref_buf[ref_wr_ptr + i[3:0]] <= ref_byte[i];
						end
					end
					ref_wr_ptr <= ref_wr_ptr + {6'd0, ref_byte_count};

					// Track complete rows
					if ((ref_wr_ptr + {6'd0, ref_byte_count}) >= next_row_boundary) begin
						// How many rows completed? Usually 1, but a wide
						// word can span a row boundary in small blocks.
						if ((ref_wr_ptr + {6'd0, ref_byte_count}) >= (next_row_boundary + {5'd0, ref_cols})) begin
							rows_loaded <= rows_loaded + 5'd2;
							next_row_boundary <= next_row_boundary + {4'd0, ref_cols, 1'b0};
						end else begin
							rows_loaded <= rows_loaded + 5'd1;
							next_row_boundary <= next_row_boundary + {5'd0, ref_cols};
						end
					end

					// All data received?
					if ((ref_wr_ptr + {6'd0, ref_byte_count}) >= ref_total) begin
						load_done <= 1'b1;
						ref_ready <= 1'b0;
						rows_loaded <= ref_rows;
					end
				end

				// === Compute path (2-wide) ===
				if (can_compute && !compute_done) begin
					if (!pred_valid || pred_ready) begin
						pred_valid   <= 1'b1;
						pred_sample0 <= computed0;

						// Determine if we output a pair or single
						if (out_col + 5'd2 <= blk_w) begin
							// Two samples fit
							pred_sample1 <= computed1;
							pred_pair    <= 1'b1;
							out_count    <= out_count + 9'd2;

							if (out_count + 9'd2 >= out_total)
								pred_last <= 1'b1;
							else
								pred_last <= 1'b0;

							// Advance position by 2 columns
							if (out_col + 5'd2 >= blk_w) begin
								out_col <= 5'd0;
								out_row <= out_row + 5'd1;
							end else begin
								out_col <= out_col + 5'd2;
							end
						end else begin
							// Odd last column — single sample
							pred_sample1 <= 8'd0;
							pred_pair    <= 1'b0;
							out_count    <= out_count + 9'd1;
							pred_last    <= 1'b1;
							out_col      <= 5'd0;
							out_row      <= out_row + 5'd1;
						end
					end
				end else begin
					// Can't compute yet (waiting for rows) — deassert valid
					if (pred_ready)
						pred_valid <= 1'b0;
				end

				// === Completion ===
				if (out_count >= out_total && out_count > 9'd0) begin
					state     <= S_IDLE;
					cmd_ready <= 1'b1;
					ref_ready <= 1'b0;
					// Update cache
					cache_valid    <= 1'b1;
					cache_ref_x    <= cmd_ref_x;
					cache_ref_y    <= cmd_ref_y;
					cache_ref_cols <= ref_cols;
					cache_ref_rows <= ref_rows;
					cache_is_chroma <= is_chroma;
					cache_skip_zero <= skip_zero;
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
	reg counting;

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
