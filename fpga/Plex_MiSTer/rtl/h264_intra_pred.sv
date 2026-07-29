// AREA NOTE (fit HARD_FAIL, 248% ALM / 130% DSP): these predictors were
// originally written fully parallel -- all nine I4x4 modes evaluated
// simultaneously and muxed, and a whole 16x16 / 8x8 plane emitted from one
// combinational cloud in 32-bit integer arithmetic. Only ONE mode is ever
// selected and only one sample is ever needed per cycle, so that cost roughly
// 9x the logic for no benefit.
//
// The rebuild below:
//   * shares ONE 2-tap / 3-tap filter bank across all nine I4x4 modes; every
//     directional mode is a permutation of the same taps, so the arithmetic is
//     built once and only the per-pixel selection differs,
//   * generates the I16x16 and Chroma 8x8 planes ONE SAMPLE PER CYCLE into a
//     single indexed-write register file (a one-hot write decoder, not 256
//     independent mode muxes),
//   * evaluates Plane with a single running accumulator -- add b per column,
//     add c per row -- instead of 256 parallel gradient evaluations,
//   * accumulates the Plane gradients with the s += d / acc += s double-sum so
//     sum (j+1)*d_j needs two adders and no multiplier,
//   * writes every remaining constant multiply as a shift/add so nothing
//     infers a DSP block.
// Latency grew (a 16x16 plane now takes ~275 cycles); area is the binding
// constraint, not throughput.

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
	// Shared neighbour vector, ordered bottom-left to top-right so that every
	// directional mode reduces to a contiguous window of q[].
	//   q[0]     = left[3]  (replicated: mode 8 needs the l2 + 2*l3 + l3 tap)
	//   q[1..4]  = left[3..0]
	//   q[5]     = top_left
	//   q[6..13] = above[0..7]
	//   q[14]    = above[7] (replicated: mode 3 needs the t6 + 3*t7 tap)
	wire [7:0] q [0:14];
	assign q[0] = left[3];
	assign q[1] = left[3];
	assign q[2] = left[2];
	assign q[3] = left[1];
	assign q[4] = left[0];
	assign q[5] = top_left;
	assign q[14] = above[7];

	// The only two filter shapes H.264 intra 4x4 ever uses.
	wire [7:0] a2 [0:13];
	wire [7:0] a3 [0:12];
	genvar qi;
	generate
		for (qi = 0; qi < 8; qi = qi + 1) begin : g_q_above
			assign q[6 + qi] = above[qi];
		end
		for (qi = 0; qi < 14; qi = qi + 1) begin : g_a2
			wire [9:0] s2 = {2'd0, q[qi]} + {2'd0, q[qi + 1]} + 10'd1;
			assign a2[qi] = s2[8:1];
		end
		for (qi = 0; qi < 13; qi = qi + 1) begin : g_a3
			wire [10:0] s3 = {3'd0, q[qi]} + {2'd0, q[qi + 1], 1'b0} +
			                 {3'd0, q[qi + 2]} + 11'd2;
			assign a3[qi] = s3[9:2];
		end
	endgenerate

	wire [9:0] sum_a = {2'd0, above[0]} + {2'd0, above[1]} +
	                   {2'd0, above[2]} + {2'd0, above[3]};
	wire [9:0] sum_l = {2'd0, left[0]} + {2'd0, left[1]} +
	                   {2'd0, left[2]} + {2'd0, left[3]};
	wire [10:0] dc_both = {1'b0, sum_a} + {1'b0, sum_l} + 11'd4;
	wire [9:0]  dc_one  = (has_above ? sum_a : sum_l) + 10'd2;
	wire [7:0]  dc_v = (has_above && has_left) ? dc_both[10:3] :
	                   (has_above || has_left) ? dc_one[9:2] : 8'd128;

	integer i, x, y, zvr, zhd, zhu;
	reg [3:0] m;
	always @* begin
		m = mode;
		if (!has_above && (mode == 4'd0 || mode == 4'd3 || mode == 4'd7)) m = 4'd2;
		if (!has_left  && (mode == 4'd1 || mode == 4'd8)) m = 4'd2;
		if ((!has_above || !has_left) &&
		    (mode == 4'd4 || mode == 4'd5 || mode == 4'd6)) m = 4'd2;
		used_mode = (mode > 4'd8) ? 4'd15 : m;

		// x and y are loop constants, so every q/a2/a3 index below folds to a
		// constant and each output pixel collapses to a plain 9-way mux.
		for (i = 0; i < 16; i = i + 1) begin
			x = i % 4;
			y = i / 4;
			zvr = 2 * x - y;
			zhd = 2 * y - x;
			zhu = x + 2 * y;
			case (used_mode)
			4'd0: pred[i] = q[6 + x];                        // Vertical
			4'd1: pred[i] = q[4 - y];                        // Horizontal
			4'd2: pred[i] = dc_v;                            // DC
			4'd3: pred[i] = a3[6 + x + y];                   // Diagonal Down-Left
			4'd4: pred[i] = a3[4 + x - y];                   // Diagonal Down-Right
			4'd5: pred[i] = (zvr < 0)        ? a3[5 + zvr] :          // Vertical-Right
			                (zvr % 2 == 0)   ? a2[5 + (zvr / 2)]
			                                 : a3[5 + ((zvr - 1) / 2)];
			4'd6: pred[i] = (zhd < 0)        ? a3[3 - zhd] :          // Horizontal-Down
			                (zhd % 2 == 0)   ? a2[4 - (zhd / 2)]
			                                 : a3[4 - ((zhd + 1) / 2)];
			4'd7: pred[i] = (y % 2 == 0)     ? a2[6 + x + (y / 2)]    // Vertical-Left
			                                 : a3[6 + x + ((y - 1) / 2)];
			4'd8: pred[i] = (zhu > 5)        ? q[1] :                 // Horizontal-Up
			                (zhu == 5)       ? a3[0] :
			                (zhu % 2 == 0)   ? a2[3 - (zhu / 2)]
			                                 : a3[2 - ((zhu - 1) / 2)];
			default: pred[i] = 8'd128;
			endcase
		end
	end
endmodule

// ---------------------------------------------------------------------------
// Intra_16x16 prediction, clause 8.3.3, modes 0..3 (V / H / DC / Plane).
// Sequential: one 16-cycle setup pass over the neighbours, two compute cycles,
// then 256 cycles emitting one predicted sample per cycle.
// ---------------------------------------------------------------------------
// PARALLEL_OUT=0 drops the 256-byte combinational `pred` port and serves the
// block through rd_addr/rd_data instead.  That is what lets the 256-sample
// buffer infer an M10K: with a parallel output every sample must live in a
// flop and every consumer pays a 256:1 byte multiplexer.  Benches that want
// the whole block at once keep the default.
//
// LATENCY CONTRACT: `valid` is a one-cycle pulse 275 cycles after `start`, for
// every mode (the old parallel RTL answered in 1-2).  Measured, not estimated.
// Consumers must wait on `valid`; any fixed-cycle wait shorter than that reads
// stale samples and looks exactly like a prediction bug.
module h264_intra16x16_pred #(
	parameter bit PARALLEL_OUT = 1
) (
	input  wire        clk,
	input  wire        start,
	input  wire [1:0]  mode,
	input  wire [7:0]  above [0:15],
	input  wire [7:0]  left [0:15],
	input  wire [7:0]  top_left,
	input  wire        has_above,
	input  wire        has_left,
	input  wire [7:0]  rd_addr,
	output reg  [7:0]  rd_data,
	output reg         unsupported,
	output reg         valid,
	output wire [7:0]  pred [0:255]
);
	(* ramstyle = "M10K" *) reg [7:0] pred_buf [0:255];

	always @(posedge clk)
		rd_data <= pred_buf[rd_addr];

	genvar gp;
	generate
		for (gp = 0; gp < 256; gp = gp + 1) begin : g_par
			if (PARALLEL_OUT) assign pred[gp] = pred_buf[gp];
			else              assign pred[gp] = 8'd0;
		end
	endgenerate
	localparam [2:0] ST_IDLE  = 3'd0,
	                 ST_SETUP = 3'd1,
	                 ST_CALC  = 3'd2,
	                 ST_SEED  = 3'd3,
	                 ST_FILL  = 3'd4;

	reg [2:0] st = ST_IDLE;
	reg [1:0] mode_r;
	reg       avail_a_r, avail_l_r;
	reg [4:0] k;
	reg [7:0] cnt;

	reg [12:0] sum_a, sum_l;
	// Gradient double-accumulator: iterating j = 7..0 with s += d then acc += s
	// yields sum (j+1)*d_j using two adders and no multiplier.
	reg signed [15:0] h_s, h_acc, v_s, v_acc;

	reg signed [15:0] plane_b, plane_c;
	reg signed [19:0] acc, row_acc;
	reg [7:0]  dc_v;

	wire [3:0] fx = cnt[3:0];
	wire [3:0] fy = cnt[7:4];

	// Gradient taps for step k: above[15-k] - (k == 0 ? top_left : above[k-1]).
	wire [3:0] k_hi = 4'd15 - k[3:0];
	wire [3:0] k_lo = k[3:0] - 4'd1;
	wire [7:0] g_hi_a = above[k_hi];
	wire [7:0] g_hi_l = left[k_hi];
	wire [7:0] g_lo_a = (k == 5'd0) ? top_left : above[k_lo];
	wire [7:0] g_lo_l = (k == 5'd0) ? top_left : left[k_lo];
	wire signed [15:0] gd_h = $signed({8'd0, g_hi_a}) - $signed({8'd0, g_lo_a});
	wire signed [15:0] gd_v = $signed({8'd0, g_hi_l}) - $signed({8'd0, g_lo_l});

	// b = (5 * grad + 32) >> 6 with 5*x written as (x << 2) + x.
	wire signed [21:0] h22 = {{6{h_acc[15]}}, h_acc};
	wire signed [21:0] v22 = {{6{v_acc[15]}}, v_acc};
	wire signed [21:0] b_raw = (h22 <<< 2) + h22 + 22'sd32;
	wire signed [21:0] c_raw = (v22 <<< 2) + v22 + 22'sd32;

	wire [13:0] dc_sum_both = {1'b0, sum_a} + {1'b0, sum_l};

	// Plane seed: a - 7*b - 7*c + 16, with a = 16*(above[15] + left[15]).
	wire signed [19:0] pb20 = {{4{plane_b[15]}}, plane_b};
	wire signed [19:0] pc20 = {{4{plane_c[15]}}, plane_c};
	wire signed [19:0] b7 = (pb20 <<< 3) - pb20;
	wire signed [19:0] c7 = (pc20 <<< 3) - pc20;
	wire [19:0] pa_sum = {12'd0, above[15]} + {12'd0, left[15]};
	wire signed [19:0] pa20 = $signed(pa_sum) <<< 4;
	wire signed [19:0] plane_seed = pa20 - b7 - c7 + 20'sd16;

	wire signed [14:0] plane_shr = acc[19:5];
	wire [7:0] plane_pix = plane_shr[14] ? 8'd0 :
	                       (|plane_shr[13:8] ? 8'd255 : plane_shr[7:0]);

	reg [7:0] sample;
	always @* begin
		if (mode_r == 2'd3)
			sample = (avail_a_r && avail_l_r) ? plane_pix : 8'd128;
		else if (mode_r == 2'd0 && avail_a_r) sample = above[fx];
		else if (mode_r == 2'd1 && avail_l_r) sample = left[fy];
		else                                  sample = dc_v;
	end

	always @(posedge clk) begin
		valid <= 1'b0;
		case (st)
		ST_IDLE: begin
			if (start) begin
				unsupported <= 1'b0;
				mode_r    <= mode;
				avail_a_r <= has_above;
				avail_l_r <= has_left;
				sum_a <= 13'd0;
				sum_l <= 13'd0;
				h_s <= 16'sd0; h_acc <= 16'sd0;
				v_s <= 16'sd0; v_acc <= 16'sd0;
				k  <= 5'd0;
				st <= ST_SETUP;
			end
		end
		ST_SETUP: begin
			sum_a <= sum_a + {5'd0, above[k[3:0]]};
			sum_l <= sum_l + {5'd0, left[k[3:0]]};
			if (!k[3]) begin
				h_s   <= h_s + gd_h;
				h_acc <= h_acc + h_s + gd_h;
				v_s   <= v_s + gd_v;
				v_acc <= v_acc + v_s + gd_v;
			end
			if (k == 5'd15) st <= ST_CALC;
			k <= k + 5'd1;
		end
		ST_CALC: begin
			// (sum + 16) >> 5 and (sum + 8) >> 4 as truncate-plus-round-bit.
			if (avail_a_r && avail_l_r)
				dc_v <= dc_sum_both[12:5] + {7'd0, dc_sum_both[4]};
			else if (avail_a_r)
				dc_v <= sum_a[11:4] + {7'd0, sum_a[3]};
			else if (avail_l_r)
				dc_v <= sum_l[11:4] + {7'd0, sum_l[3]};
			else
				dc_v <= 8'd128;
			plane_b <= b_raw[21:6];
			plane_c <= c_raw[21:6];
			st <= ST_SEED;
		end
		ST_SEED: begin
			acc     <= plane_seed;
			row_acc <= plane_seed;
			cnt <= 8'd0;
			st  <= ST_FILL;
		end
		ST_FILL: begin
			pred_buf[cnt] <= sample;
			if (fx == 4'd15) begin
				row_acc <= row_acc + pc20;
				acc     <= row_acc + pc20;
			end else begin
				acc <= acc + pb20;
			end
			if (cnt == 8'd255) begin
				valid <= 1'b1;
				st    <= ST_IDLE;
			end
			cnt <= cnt + 8'd1;
		end
		default: st <= ST_IDLE;
		endcase
	end
endmodule

// ---------------------------------------------------------------------------
// Intra_Chroma 8x8 prediction, clause 8.3.4, modes 0..3 (DC / H / V / Plane).
// Same sequential shape as the luma engine. Chroma DC is the per-quadrant rule
// of 8.3.4.1, which is NOT the luma DC rule.
//
// LATENCY CONTRACT: `valid` is a one-cycle pulse 75 cycles after `start`, for
// every mode (the old parallel RTL answered in 1-2).  Measured, not estimated.
// ---------------------------------------------------------------------------
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
	localparam [2:0] ST_IDLE  = 3'd0,
	                 ST_SETUP = 3'd1,
	                 ST_CALC  = 3'd2,
	                 ST_SEED  = 3'd3,
	                 ST_FILL  = 3'd4;

	reg [2:0] st = ST_IDLE;
	reg [1:0] mode_r;
	reg       avail_a_r, avail_l_r;
	reg [3:0] k;
	reg [5:0] cnt;

	reg [10:0] sa0, sa1, sl0, sl1;
	reg signed [15:0] h_s, h_acc, v_s, v_acc;
	reg signed [15:0] plane_b, plane_c;
	reg signed [19:0] acc, row_acc;
	reg [7:0] dc_tl, dc_tr, dc_bl, dc_br;

	wire [2:0] fx = cnt[2:0];
	wire [2:0] fy = cnt[5:3];

	// Gradient taps for step k: above[7-k] - (k == 0 ? top_left : above[k-1]).
	wire [2:0] k_hi = 3'd7 - k[2:0];
	wire [2:0] k_lo = k[2:0] - 3'd1;
	wire [7:0] g_hi_a = above[k_hi];
	wire [7:0] g_hi_l = left[k_hi];
	wire [7:0] g_lo_a = (k == 4'd0) ? top_left : above[k_lo];
	wire [7:0] g_lo_l = (k == 4'd0) ? top_left : left[k_lo];
	wire signed [15:0] gd_h = $signed({8'd0, g_hi_a}) - $signed({8'd0, g_lo_a});
	wire signed [15:0] gd_v = $signed({8'd0, g_hi_l}) - $signed({8'd0, g_lo_l});

	// b = (17 * grad + 16) >> 5 with 17*x written as (x << 4) + x.
	wire signed [21:0] h22 = {{6{h_acc[15]}}, h_acc};
	wire signed [21:0] v22 = {{6{v_acc[15]}}, v_acc};
	wire signed [21:0] b_raw = (h22 <<< 4) + h22 + 22'sd16;
	wire signed [21:0] c_raw = (v22 <<< 4) + v22 + 22'sd16;

	wire signed [19:0] pb20 = {{4{plane_b[15]}}, plane_b};
	wire signed [19:0] pc20 = {{4{plane_c[15]}}, plane_c};
	wire signed [19:0] b3 = (pb20 <<< 1) + pb20;
	wire signed [19:0] c3 = (pc20 <<< 1) + pc20;
	wire [19:0] pa_sum = {12'd0, above[7]} + {12'd0, left[7]};
	wire signed [19:0] pa20 = $signed(pa_sum) <<< 4;
	wire signed [19:0] plane_seed = pa20 - b3 - c3 + 20'sd16;

	wire signed [14:0] plane_shr = acc[19:5];
	wire [7:0] plane_pix = plane_shr[14] ? 8'd0 :
	                       (|plane_shr[13:8] ? 8'd255 : plane_shr[7:0]);

	wire [7:0] dc_quad = fy[2] ? (fx[2] ? dc_br : dc_bl)
	                           : (fx[2] ? dc_tr : dc_tl);

	// Quadrant averages, clause 8.3.4.1.
	wire [11:0] q_a0l0 = {1'b0, sa0} + {1'b0, sl0};
	wire [11:0] q_a1l1 = {1'b0, sa1} + {1'b0, sl1};

	reg [7:0] sample;
	always @* begin
		if (mode_r == 2'd3)
			sample = (avail_a_r && avail_l_r) ? plane_pix : 8'd128;
		else if (mode_r == 2'd1) sample = left[fy];
		else if (mode_r == 2'd2) sample = above[fx];
		else                     sample = dc_quad;
	end

	always @(posedge clk) begin
		valid <= 1'b0;
		case (st)
		ST_IDLE: begin
			if (start) begin
				mode_r    <= mode;
				avail_a_r <= has_above;
				avail_l_r <= has_left;
				sa0 <= 11'd0; sa1 <= 11'd0;
				sl0 <= 11'd0; sl1 <= 11'd0;
				h_s <= 16'sd0; h_acc <= 16'sd0;
				v_s <= 16'sd0; v_acc <= 16'sd0;
				k  <= 4'd0;
				st <= ST_SETUP;
			end
		end
		ST_SETUP: begin
			if (k[2]) begin
				sa1 <= sa1 + {3'd0, above[k[2:0]]};
				sl1 <= sl1 + {3'd0, left[k[2:0]]};
			end else begin
				sa0 <= sa0 + {3'd0, above[k[2:0]]};
				sl0 <= sl0 + {3'd0, left[k[2:0]]};
				h_s   <= h_s + gd_h;
				h_acc <= h_acc + h_s + gd_h;
				v_s   <= v_s + gd_v;
				v_acc <= v_acc + v_s + gd_v;
			end
			if (k == 4'd7) st <= ST_CALC;
			k <= k + 4'd1;
		end
		ST_CALC: begin
			if (avail_a_r && avail_l_r) begin
				dc_tl <= q_a0l0[10:3] + {7'd0, q_a0l0[2]};
				dc_tr <= sa1[9:2] + {7'd0, sa1[1]};
				dc_bl <= sl1[9:2] + {7'd0, sl1[1]};
				dc_br <= q_a1l1[10:3] + {7'd0, q_a1l1[2]};
			end else if (avail_a_r) begin
				dc_tl <= sa0[9:2] + {7'd0, sa0[1]};
				dc_tr <= sa1[9:2] + {7'd0, sa1[1]};
				dc_bl <= sa0[9:2] + {7'd0, sa0[1]};
				dc_br <= sa1[9:2] + {7'd0, sa1[1]};
			end else if (avail_l_r) begin
				dc_tl <= sl0[9:2] + {7'd0, sl0[1]};
				dc_tr <= sl0[9:2] + {7'd0, sl0[1]};
				dc_bl <= sl1[9:2] + {7'd0, sl1[1]};
				dc_br <= sl1[9:2] + {7'd0, sl1[1]};
			end else begin
				dc_tl <= 8'd128; dc_tr <= 8'd128;
				dc_bl <= 8'd128; dc_br <= 8'd128;
			end
			plane_b <= b_raw[20:5];
			plane_c <= c_raw[20:5];
			st <= ST_SEED;
		end
		ST_SEED: begin
			acc     <= plane_seed;
			row_acc <= plane_seed;
			cnt <= 6'd0;
			st  <= ST_FILL;
		end
		ST_FILL: begin
			pred[cnt] <= sample;
			if (fx == 3'd7) begin
				row_acc <= row_acc + pc20;
				acc     <= row_acc + pc20;
			end else begin
				acc <= acc + pb20;
			end
			if (cnt == 6'd63) begin
				valid <= 1'b1;
				st    <= ST_IDLE;
			end
			cnt <= cnt + 6'd1;
		end
		default: st <= ST_IDLE;
		endcase
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
