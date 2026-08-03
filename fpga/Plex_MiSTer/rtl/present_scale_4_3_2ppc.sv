// present_scale_4_3_2ppc — product 4/3 dual-destination-pixel (2-PPC) Y engine.
//
// COMPONENT CONTRACT (rd-duck): this is **one 8-bit plane**, product = **Y (luma)**.
//   - Not RGB. ddr_frame_store/yuv_bt601_npx emit RGB after YUV; scaling RGB would
//     need 3 instances and 8 RGB taps/group — wrong place (post-matrix).
//   - U/V are half-res (480×270 for 960×540 storage). Separate chroma engine later
//     with SRC_W/H halved, or NN chroma + Y-only bilin for v1 ship.
//   - Instantiate once per plane when wiring; this module stays plane-agnostic.
//
// M10K LATENCY CONTRACT (rd-duck fit-ready path):
//   Cycle N  : hc_g/py → **combinational** req_* addresses (drive line-buf rd_addr)
//              meta (phase/weights/ix/DE) registered into pipe[0]
//   Cycle N+1: caller presents tap_* from synchronous RAM rd_data; module lerps
//              using **delayed** meta (pipe matches RAM_LAT, default 1).
//   Registered tap_base_x/store_* are diagnostics only — do NOT use them to
//   address M10K for the same group. Use req_*.
//
// Pair geometry (dst base even hc_g = 2k), Y 960→1280:
//   {0,1}: floors {0,0} → H taps base..base+1 (2 unique)
//   {2,3}: floors {1,2} → H taps base..base+2 (3 unique)
//   V: y0=floor(py*3/4), y1=ceil — two source lines.
//
// Tap window at req_tap_base_x (caller clamps past SRC_W-1):
//   tap_y0[i] = Y[req_y0][base+i], tap_y1[i] = Y[req_y1][base+i], i=0..3
//
// Weights sum-256 (9-bit). out = (·+128)>>8 — constant-color exact.
// Phase = (3·dst) mod 4. FAULT_PHASE_DST → dst[1:0] (must RED).
//
// Default OFF. Not in present_core until w-clock 2-PPC bridge wires dual-line
// Y providers (two line_buf_ram rows or qword extract). Fit stays NN/off.
//
// Cost: 0 M10K here. Dual Y line hold ≈ 2×960 B ≈ 2 M10K (provider, not this file).
// Fmax: fine @29.7 MHz — no divide; pipe is regs + 8×9 muls.

`default_nettype none

module present_scale_4_3_2ppc #(
	parameter int SRC_W   = 960,
	parameter int SRC_H   = 540,
	parameter int DST_W   = 1280,
	parameter int DST_H   = 720,
	// Synchronous line-buf read latency in ce_pix beats (M10K = 1).
	parameter int RAM_LAT = 1
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,
	// Group base: even glass X of the 2-pixel pair (hc_g, hc_g+1).
	input  wire [10:0] hc_g,
	input  wire [10:0] py,
	input  wire        in_content,

	// ----- Combinational REQUEST (cycle N) — drive M10K rd_addr now -----
	output wire [10:0] req_tap_base_x,
	output wire [10:0] req_x0,
	output wire [10:0] req_x1,
	output wire [10:0] req_x2,
	output wire [10:0] req_x3,
	output wire [10:0] req_y0,
	output wire [10:0] req_y1,
	output wire        req_valid,

	// ----- Tap RESPONSE (cycle N+RAM_LAT) — from line-buf rd_data -----
	// Aligned to the request issued RAM_LAT ce_pix beats ago.
	input  wire        taps_valid,
	input  wire [7:0]  tap_y0_0,
	input  wire [7:0]  tap_y0_1,
	input  wire [7:0]  tap_y0_2,
	input  wire [7:0]  tap_y0_3,
	input  wire [7:0]  tap_y1_0,
	input  wire [7:0]  tap_y1_1,
	input  wire [7:0]  tap_y1_2,
	input  wire [7:0]  tap_y1_3,

	// Diagnostics (registered with output pixel, NOT for same-cycle RAM addr)
	output reg  [10:0] tap_base_x,
	output reg  [10:0] store_x0,
	output reg  [10:0] store_x1_a,
	output reg  [10:0] store_x0_b,
	output reg  [10:0] store_x1_b,
	output reg  [10:0] store_y0,
	output reg  [10:0] store_y1,
	output reg  [1:0]  phase_x0,
	output reg  [1:0]  phase_x1,
	output reg  [1:0]  phase_y,
	output reg  [8:0]  wx0_a,
	output reg  [8:0]  wx1_a,
	output reg  [8:0]  wx0_b,
	output reg  [8:0]  wx1_b,
	output reg  [8:0]  wy0,
	output reg  [8:0]  wy1,
	output reg  [7:0]  pix0,
	output reg  [7:0]  pix1,
	output reg         de_r,
	output reg         out_valid
);
	localparam bit RATIO_W_OK = (SRC_W * 4 == DST_W * 3);
	localparam bit RATIO_H_OK = (SRC_H * 4 == DST_H * 3);
	localparam [10:0] SRC_X_LAST = 11'(SRC_W - 1);
	localparam [10:0] SRC_Y_LAST = 11'(SRC_H - 1);

	wire [10:0] hc0 = {hc_g[10:1], 1'b0};
	wire [10:0] hc1 = hc0 + 11'd1;

`ifdef PRESENT_SCALE_4_3_FAULT_INVERT
	wire [13:0] x0_num = {3'd0, hc0} * 14'd4;
	wire [13:0] x1_num = {3'd0, hc1} * 14'd4;
	wire [13:0] y_num  = {3'd0, py}  * 14'd4;
`else
	wire [13:0] x0_num = {3'd0, hc0} * 14'd3;
	wire [13:0] x1_num = {3'd0, hc1} * 14'd3;
	wire [13:0] y_num  = {3'd0, py}  * 14'd3;
`endif

	wire [10:0] sx0_raw = x0_num[13:2];
	wire [10:0] sx1_raw = x1_num[13:2];
	wire [10:0] sy_raw  = y_num[13:2];
	wire [10:0] sx0_f = (sx0_raw > SRC_X_LAST) ? SRC_X_LAST : sx0_raw;
	wire [10:0] sx1_f = (sx1_raw > SRC_X_LAST) ? SRC_X_LAST : sx1_raw;
	wire [10:0] sy_f  = (sy_raw  > SRC_Y_LAST) ? SRC_Y_LAST : sy_raw;
	wire [10:0] sx0_c = (sx0_f >= SRC_X_LAST) ? SRC_X_LAST : (sx0_f + 11'd1);
	wire [10:0] sx1_c = (sx1_f >= SRC_X_LAST) ? SRC_X_LAST : (sx1_f + 11'd1);
	wire [10:0] sy_c  = (sy_f  >= SRC_Y_LAST) ? SRC_Y_LAST : (sy_f  + 11'd1);

`ifdef PRESENT_SCALE_4_3_FAULT_PHASE_DST
	wire [1:0] ph_x0 = hc0[1:0];
	wire [1:0] ph_x1 = hc1[1:0];
	wire [1:0] ph_y  = py[1:0];
`elsif PRESENT_SCALE_4_3_FAULT_PHASE_OBO
	wire [1:0] ph_x0 = hc0[1:0];
	wire [1:0] ph_x1 = hc1[1:0];
	wire [1:0] ph_y  = py[1:0];
`else
	wire [1:0] ph_x0 = x0_num[1:0];
	wire [1:0] ph_x1 = x1_num[1:0];
	wire [1:0] ph_y  = y_num[1:0];
`endif

	function automatic [17:0] wrom;
		input [1:0] ph;
		begin
			case (ph)
				2'd0: wrom = {9'd256, 9'd0};
				2'd1: wrom = {9'd192, 9'd64};
				2'd2: wrom = {9'd128, 9'd128};
				default: wrom = {9'd64, 9'd192};
			endcase
		end
	endfunction

	wire [17:0] wx_a = wrom(ph_x0);
	wire [17:0] wx_b = wrom(ph_x1);
	wire [17:0] wy_p = wrom(ph_y);
	wire [8:0] wx0a = wx_a[17:9];
	wire [8:0] wx1a = wx_a[8:0];
	wire [8:0] wx0b = wx_b[17:9];
	wire [8:0] wx1b = wx_b[8:0];
	wire [8:0] wy0w = wy_p[17:9];
	wire [8:0] wy1w = wy_p[8:0];

	wire [10:0] base_x = (sx0_f <= sx1_f) ? sx0_f : sx1_f;

	function automatic [10:0] xclamp;
		input [10:0] x;
		begin
			xclamp = (x > SRC_X_LAST) ? SRC_X_LAST : x;
		end
	endfunction

	// ----- Comb request (same cycle as hc/py) -----
	assign req_tap_base_x = base_x;
	assign req_x0 = base_x;
	assign req_x1 = xclamp(base_x + 11'd1);
	assign req_x2 = xclamp(base_x + 11'd2);
	assign req_x3 = xclamp(base_x + 11'd3);
	assign req_y0 = sy_f;
	assign req_y1 = sy_c;
	assign req_valid = in_content;

	wire [10:0] off0 = sx0_f - base_x;
	wire [10:0] off1 = sx1_f - base_x;
	wire        edge0 = (sx0_f == sx0_c);
	wire        edge1 = (sx1_f == sx1_c);

	// Packed meta delayed RAM_LAT beats to meet taps.
	// {de, base, sx0,sx0c,sx1,sx1c, sy0,sy1, phx0,phx1,phy,
	//  wx0a,wx1a,wx0b,wx1b,wy0,wy1, off0,off1, edge0,edge1}
	localparam int META_W = 1+11*7+2*3+9*6+11*2+2;
	wire [META_W-1:0] meta_c = {
		in_content,
		base_x, sx0_f, sx0_c, sx1_f, sx1_c, sy_f, sy_c,
		ph_x0, ph_x1, ph_y,
		wx0a, wx1a, wx0b, wx1b, wy0w, wy1w,
		off0, off1, edge0, edge1
	};

	reg [META_W-1:0] pipe0;
	reg [META_W-1:0] pipe1;
	wire [META_W-1:0] meta_use =
		(RAM_LAT == 0) ? meta_c :
		(RAM_LAT == 1) ? pipe0 :
		                 pipe1; // RAM_LAT>=2 uses 2-deep (cap for v1)

	always @(posedge clk) begin
		if (reset) begin
			pipe0 <= '0;
			pipe1 <= '0;
		end else if (ce_pix) begin
			pipe0 <= meta_c;
			pipe1 <= pipe0;
		end
	end

	// Unpack meta_use
	wire        m_de;
	wire [10:0] m_base, m_sx0, m_sx0c, m_sx1, m_sx1c, m_sy0, m_sy1;
	wire [1:0]  m_phx0, m_phx1, m_phy;
	wire [8:0]  m_wx0a, m_wx1a, m_wx0b, m_wx1b, m_wy0, m_wy1;
	wire [10:0] m_off0, m_off1;
	wire        m_edge0, m_edge1;
	assign {
		m_de,
		m_base, m_sx0, m_sx0c, m_sx1, m_sx1c, m_sy0, m_sy1,
		m_phx0, m_phx1, m_phy,
		m_wx0a, m_wx1a, m_wx0b, m_wx1b, m_wy0, m_wy1,
		m_off0, m_off1, m_edge0, m_edge1
	} = meta_use;

	function automatic [7:0] pick4;
		input [1:0] ix;
		input [7:0] t0, t1, t2, t3;
		begin
			case (ix)
				2'd0: pick4 = t0;
				2'd1: pick4 = t1;
				2'd2: pick4 = t2;
				default: pick4 = t3;
			endcase
		end
	endfunction

	function automatic [7:0] bilin256;
		input [7:0] p00, p10, p01, p11;
		input [8:0] wx0i, wx1i, wy0i, wy1i;
		reg [17:0] h0a, h1a, oa;
		reg [7:0] h0, h1;
		begin
			h0a = p00 * wx0i + p10 * wx1i + 18'd128;
			h1a = p01 * wx0i + p11 * wx1i + 18'd128;
			h0 = h0a[15:8];
			h1 = h1a[15:8];
			oa = h0 * wy0i + h1 * wy1i + 18'd128;
			bilin256 = oa[15:8];
		end
	endfunction

	wire [1:0] ix0 = m_off0[1:0];
	wire [1:0] ix1 = m_off1[1:0];
	wire [1:0] ix0p = (m_off0 >= 11'd3) ? 2'd3 : 2'(m_off0[1:0] + 2'd1);
	wire [1:0] ix1p = (m_off1 >= 11'd3) ? 2'd3 : 2'(m_off1[1:0] + 2'd1);

	wire [7:0] a_p00 = pick4(ix0, tap_y0_0, tap_y0_1, tap_y0_2, tap_y0_3);
	wire [7:0] a_p10 = pick4(ix0p, tap_y0_0, tap_y0_1, tap_y0_2, tap_y0_3);
	wire [7:0] a_p01 = pick4(ix0, tap_y1_0, tap_y1_1, tap_y1_2, tap_y1_3);
	wire [7:0] a_p11 = pick4(ix0p, tap_y1_0, tap_y1_1, tap_y1_2, tap_y1_3);
	wire [7:0] a_p10c = m_edge0 ? a_p00 : a_p10;
	wire [7:0] a_p11c = m_edge0 ? a_p01 : a_p11;

	wire [7:0] b_p00 = pick4(ix1, tap_y0_0, tap_y0_1, tap_y0_2, tap_y0_3);
	wire [7:0] b_p10 = pick4(ix1p, tap_y0_0, tap_y0_1, tap_y0_2, tap_y0_3);
	wire [7:0] b_p01 = pick4(ix1, tap_y1_0, tap_y1_1, tap_y1_2, tap_y1_3);
	wire [7:0] b_p11 = pick4(ix1p, tap_y1_0, tap_y1_1, tap_y1_2, tap_y1_3);
	wire [7:0] b_p10c = m_edge1 ? b_p00 : b_p10;
	wire [7:0] b_p11c = m_edge1 ? b_p01 : b_p11;

	wire [7:0] pix0_w = bilin256(a_p00, a_p10c, a_p01, a_p11c,
	                             m_wx0a, m_wx1a, m_wy0, m_wy1);
	wire [7:0] pix1_w = bilin256(b_p00, b_p10c, b_p01, b_p11c,
	                             m_wx0b, m_wx1b, m_wy0, m_wy1);

	always @(posedge clk) begin
		if (reset) begin
			tap_base_x <= 0;
			store_x0 <= 0; store_x1_a <= 0; store_x0_b <= 0; store_x1_b <= 0;
			store_y0 <= 0; store_y1 <= 0;
			phase_x0 <= 0; phase_x1 <= 0; phase_y <= 0;
			wx0_a <= 9'd256; wx1_a <= 9'd0;
			wx0_b <= 9'd256; wx1_b <= 9'd0;
			wy0 <= 9'd256; wy1 <= 9'd0;
			pix0 <= 0; pix1 <= 0;
			de_r <= 0; out_valid <= 0;
		end else if (ce_pix) begin
			tap_base_x <= m_base;
			store_x0   <= m_sx0;
			store_x1_a <= m_sx0c;
			store_x0_b <= m_sx1;
			store_x1_b <= m_sx1c;
			store_y0   <= m_sy0;
			store_y1   <= m_sy1;
			phase_x0   <= m_phx0;
			phase_x1   <= m_phx1;
			phase_y    <= m_phy;
			wx0_a <= m_wx0a; wx1_a <= m_wx1a;
			wx0_b <= m_wx0b; wx1_b <= m_wx1b;
			wy0   <= m_wy0;  wy1   <= m_wy1;
			de_r  <= m_de;
			if (taps_valid && m_de) begin
				pix0 <= pix0_w;
				pix1 <= pix1_w;
				out_valid <= 1'b1;
			end else begin
				out_valid <= 1'b0;
			end
		end
	end

	wire ratio_pin = RATIO_W_OK & RATIO_H_OK;
	// synthesis translate_off
	initial begin
		if (!ratio_pin) $error("present_scale_4_3_2ppc: SRC/DST not exact 4/3");
		if (RAM_LAT < 0 || RAM_LAT > 2)
			$error("present_scale_4_3_2ppc: RAM_LAT must be 0..2 in v1");
	end
	// synthesis translate_on
endmodule

`default_nettype wire
