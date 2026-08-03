// present_content_window — NN content→DE store address map (fabric scaler V1).
//
// Maps Template DE (hc, py) into DDR/frame_store read coordinates.
//   win_enable=0 → legacy full-bank FRAME_W×FRAME_H (bit-compatible defaults)
//   win_enable=1 → stretch content_w×content_h at (content_x0,content_y0) across DE
//
// Quality: nearest-neighbour only. ascal still does HDMI polyphase. Do not add
// a second polyphase here (see FABRIC_CONTENT_WINDOW_DESIGN.md).
//
// Pixel path is mul-shift only (same family as legacy STORE_*_SCALE). Scale
// constants are registered from window regs so the /320 and /V_DE ops sit off
// the ce_pix critical path.
//
// H_DE stays 529 (FBAR/Template lock). Do not retarget DE timing here.

`default_nettype none

module present_content_window #(
	parameter int FRAME_W = 640,
	parameter int FRAME_H = 480,
	// Template active width (colorbars H_DE). Product lock = 529.
	parameter int H_DE_I = 529,
	// Active store rows in DE domain (native 480 → 480; legacy 240 → 240).
	parameter int V_STORE_I = 480
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,

	// DE beam (same domain as colorbars hc/vc → py)
	input  wire [9:0]  hc,
	input  wire [9:0]  py,
	input  wire        in_content,

	// Runtime window (host/OSD). Ignored when win_enable=0.
	input  wire        win_enable,
	input  wire [9:0]  content_w,
	input  wire [9:0]  content_h,
	input  wire [9:0]  content_x0,
	input  wire [9:0]  content_y0,

	output reg  [$clog2(FRAME_W)-1:0] store_x,
	output reg  [$clog2(FRAME_H)-1:0] store_y,
	output reg         de_r,
	// py past DE content rows — present_core ORs into VBlank (G-VID1).
	output wire        past_last_row
);

	localparam int FRAME_X_W = $clog2(FRAME_W);
	localparam int FRAME_Y_W = $clog2(FRAME_H);
	localparam [9:0] H_DE = 10'(H_DE_I);
	localparam [9:0] V_STORE = 10'(V_STORE_I);
	localparam [9:0] V_STORE_LAST = 10'(V_STORE_I - 1);

	// Legacy synthesis scales (win_enable=0). Kept as localparams so
	// test_present_store_scale_math source locks still match product math.
	// store_x ≈ floor(hc * FRAME_W / 529); 39647/65536 ≈ 320/529.
	localparam int STORE_X_SCALE = (FRAME_W * 39647) / 320;
	localparam int STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE_I;
	localparam [FRAME_X_W-1:0] FRAME_LAST_X = FRAME_X_W'(FRAME_W - 1);
	localparam [FRAME_Y_W-1:0] FRAME_LAST_Y = FRAME_Y_W'(FRAME_H - 1);
	localparam [15:0] FRAME_LAST_X_16 = 16'(FRAME_W - 1);
	localparam [15:0] FRAME_LAST_Y_16 = 16'(FRAME_H - 1);

	// Effective content geometry. win_enable=0 forces full FRAME (legacy).
	// Zero W/H collapse to 1 to avoid div-by-zero if host clears regs early.
	wire [9:0] cw_raw = win_enable ? content_w : 10'(FRAME_W);
	wire [9:0] ch_raw = win_enable ? content_h : 10'(FRAME_H);
	wire [9:0] cw_eff = (cw_raw == 10'd0) ? 10'd1 : cw_raw;
	wire [9:0] ch_eff = (ch_raw == 10'd0) ? 10'd1 : ch_raw;
	wire [9:0] x0_eff = win_enable ? content_x0 : 10'd0;
	wire [9:0] y0_eff = win_enable ? content_y0 : 10'd0;

	// Scale recompute from window regs (NOT on hc/py pixel multiply path).
	// SX = floor(cw * 39647 / 320)  — identical to host math gate.
	// SY = floor(ch * 65536 / V_STORE_I)
	// Width: product FRAME_W=640 → SX=79294; SY=65536 for 1.0 — both need >16 bits.
	// Keep 18-bit scales (max cw=1023 → SX≈126870; ch=1023/V=480 → SY≈139673).
	wire [27:0] sx_num = {18'd0, cw_eff} * 28'd39647;
	wire [27:0] sy_num = {18'd0, ch_eff} * 28'd65536;
	wire [17:0] sx_comb = sx_num[27:0] / 28'd320;
	wire [17:0] sy_comb = sy_num[27:0] / 28'(V_STORE_I);

	wire [15:0] last_x_span = {6'd0, cw_eff} - 16'd1;
	wire [15:0] last_y_span = {6'd0, ch_eff} - 16'd1;
	wire [15:0] last_x_abs  = {6'd0, x0_eff} + last_x_span;
	wire [15:0] last_y_abs  = {6'd0, y0_eff} + last_y_span;

	// Clamp absolute last into FRAME domain (store port width).
	wire [15:0] last_x_lim =
		(last_x_abs > FRAME_LAST_X_16) ? FRAME_LAST_X_16 : last_x_abs;
	wire [15:0] last_y_lim =
		(last_y_abs > FRAME_LAST_Y_16) ? FRAME_LAST_Y_16 : last_y_abs;

	reg [17:0] sx_r;
	reg [17:0] sy_r;
	reg [15:0] x0_r;
	reg [15:0] y0_r;
	reg [15:0] last_x_r;
	reg [15:0] last_y_r;

	always @(posedge clk) begin
		if (reset) begin
			// Safe power-on = legacy full-bank scales (win_enable ignored until ce).
			sx_r     <= 18'(STORE_X_SCALE);
			sy_r     <= 18'(STORE_Y_SCALE);
			x0_r     <= 16'd0;
			y0_r     <= 16'd0;
			last_x_r <= FRAME_LAST_X_16;
			last_y_r <= FRAME_LAST_Y_16;
		end else begin
			sx_r     <= sx_comb;
			sy_r     <= sy_comb;
			x0_r     <= {6'd0, x0_eff};
			y0_r     <= {6'd0, y0_eff};
			last_x_r <= last_x_lim;
			last_y_r <= last_y_lim;
		end
	end

	// Pixel path: mul-shift + add origin + clamp. No divide here.
	// hc(10) * sx(18) → 28b; Q16 index = prod[27:16] (legacy used 32b*[31:16]).
	wire [9:0] read_hc = hc;
	wire [27:0] store_x_prod = {18'd0, read_hc} * {10'd0, sx_r};
	wire [11:0] store_x_q16  = store_x_prod[27:16];
	wire [16:0] store_x_sum  = {1'b0, x0_r} + {5'd0, store_x_q16};
	wire [15:0] store_x_comb =
		(store_x_sum > {1'b0, last_x_r}) ? last_x_r : store_x_sum[15:0];

	assign past_last_row = (py >= V_STORE);
	wire [9:0] py_clamped = past_last_row ? V_STORE_LAST : py;
	wire [27:0] store_y_prod = {18'd0, py_clamped} * {10'd0, sy_r};
	wire [11:0] store_y_q16  = store_y_prod[27:16];
	wire [16:0] store_y_sum  = {1'b0, y0_r} + {5'd0, store_y_q16};
	wire [15:0] store_y_comb =
		(store_y_sum > {1'b0, last_y_r}) ? last_y_r : store_y_sum[15:0];
	wire [FRAME_X_W-1:0] store_x_clamped = store_x_comb[FRAME_X_W-1:0];
	wire [FRAME_Y_W-1:0] store_y_addr    = store_y_comb[FRAME_Y_W-1:0];

	always @(posedge clk) begin
		if (reset) begin
			store_x <= '0;
			store_y <= '0;
			de_r    <= 1'b0;
		end else if (ce_pix) begin
			de_r    <= in_content;
			store_x <= store_x_clamped;
			store_y <= store_y_addr;
		end
	end

endmodule

`default_nettype wire
