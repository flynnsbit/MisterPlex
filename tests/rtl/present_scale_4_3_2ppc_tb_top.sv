// 2-PPC Y scaler TB — comb req_* → 1-cycle line model → taps_valid + lerp.
// Proves M10K-style latency alignment (not same-cycle tap feed).
`default_nettype none

module present_scale_4_3_2ppc_tb (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,
	input  wire [10:0] hc_g,
	input  wire [10:0] py,
	input  wire        in_content,
	// TB preload: two source lines as 960-byte arrays written before sample.
	// Model: on ce_pix, capture req and present taps next ce_pix (RAM_LAT=1).
	input  wire [7:0]  src_y0_0,
	input  wire [7:0]  src_y0_1,
	input  wire [7:0]  src_y0_2,
	input  wire [7:0]  src_y0_3,
	input  wire [7:0]  src_y1_0,
	input  wire [7:0]  src_y1_1,
	input  wire [7:0]  src_y1_2,
	input  wire [7:0]  src_y1_3,
	// Force-feed path: when use_direct_taps=1, bypass RAM model (lat0 debug).
	input  wire        use_direct_taps,
	output wire [10:0] req_tap_base_x,
	output wire [10:0] req_y0,
	output wire [10:0] req_y1,
	output wire        req_valid,
	output wire [10:0] tap_base_x,
	output wire [10:0] store_x0,
	output wire [10:0] store_x1_a,
	output wire [10:0] store_x0_b,
	output wire [10:0] store_x1_b,
	output wire [10:0] store_y0,
	output wire [10:0] store_y1,
	output wire [1:0]  phase_x0,
	output wire [1:0]  phase_x1,
	output wire [1:0]  phase_y,
	output wire [8:0]  wx0_a,
	output wire [8:0]  wx1_a,
	output wire [8:0]  wx0_b,
	output wire [8:0]  wx1_b,
	output wire [8:0]  wy0,
	output wire [8:0]  wy1,
	output wire [7:0]  pix0,
	output wire [7:0]  pix1,
	output wire        de_r,
	output wire        out_valid
);
	// 1-cycle delay model of dual-line byte taps (stands in for M10K).
	reg        taps_v_r;
	reg [7:0]  t00, t01, t02, t03, t10, t11, t12, t13;

	wire [7:0] tap_in_00 = use_direct_taps ? src_y0_0 : t00;
	wire [7:0] tap_in_01 = use_direct_taps ? src_y0_1 : t01;
	wire [7:0] tap_in_02 = use_direct_taps ? src_y0_2 : t02;
	wire [7:0] tap_in_03 = use_direct_taps ? src_y0_3 : t03;
	wire [7:0] tap_in_10 = use_direct_taps ? src_y1_0 : t10;
	wire [7:0] tap_in_11 = use_direct_taps ? src_y1_1 : t11;
	wire [7:0] tap_in_12 = use_direct_taps ? src_y1_2 : t12;
	wire [7:0] tap_in_13 = use_direct_taps ? src_y1_3 : t13;
	wire       taps_v    = use_direct_taps ? in_content : taps_v_r;

	// Capture TB-provided window on request cycle → present next cycle.
	always @(posedge clk) begin
		if (reset) begin
			taps_v_r <= 1'b0;
			t00 <= 0; t01 <= 0; t02 <= 0; t03 <= 0;
			t10 <= 0; t11 <= 0; t12 <= 0; t13 <= 0;
		end else if (ce_pix) begin
			// Model: addr cycle samples src_* (caller already indexed by req)
			t00 <= src_y0_0; t01 <= src_y0_1; t02 <= src_y0_2; t03 <= src_y0_3;
			t10 <= src_y1_0; t11 <= src_y1_1; t12 <= src_y1_2; t13 <= src_y1_3;
			taps_v_r <= in_content;
		end
	end

	present_scale_4_3_2ppc #(.RAM_LAT(1)) dut (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix),
		.hc_g(hc_g),
		.py(py),
		.in_content(in_content),
		.req_tap_base_x(req_tap_base_x),
		.req_x0(),
		.req_x1(),
		.req_x2(),
		.req_x3(),
		.req_y0(req_y0),
		.req_y1(req_y1),
		.req_valid(req_valid),
		.taps_valid(taps_v),
		.tap_y0_0(tap_in_00),
		.tap_y0_1(tap_in_01),
		.tap_y0_2(tap_in_02),
		.tap_y0_3(tap_in_03),
		.tap_y1_0(tap_in_10),
		.tap_y1_1(tap_in_11),
		.tap_y1_2(tap_in_12),
		.tap_y1_3(tap_in_13),
		.tap_base_x(tap_base_x),
		.store_x0(store_x0),
		.store_x1_a(store_x1_a),
		.store_x0_b(store_x0_b),
		.store_x1_b(store_x1_b),
		.store_y0(store_y0),
		.store_y1(store_y1),
		.phase_x0(phase_x0),
		.phase_x1(phase_x1),
		.phase_y(phase_y),
		.wx0_a(wx0_a),
		.wx1_a(wx1_a),
		.wx0_b(wx0_b),
		.wx1_b(wx1_b),
		.wy0(wy0),
		.wy1(wy1),
		.pix0(pix0),
		.pix1(pix1),
		.de_r(de_r),
		.out_valid(out_valid)
	);
endmodule

`default_nettype wire
