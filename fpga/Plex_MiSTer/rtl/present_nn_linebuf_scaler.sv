// present_nn_linebuf_scaler — fabric NN H-scale from held content line(s).
//
// Path A: hold content-width line(s) in M10K; emit NN samples across de_w.
// Complements present_content_window (coordinate map). Does not replace
// ddr_frame_store LINE_COUNT prefetch.
//
// === Parent design questions (2026-08-04) — answers in parameters ===
//
// Q1 Lines buffered?  LINE_HOLD default **2** (current + previous).
//    Why: V NN reuses the same content row across many glass rows (scale-up)
//    or skips rows (scale-down). 2 covers writer pipeline + sticky V sample.
//    Not 16: store already pays DDR look-ahead LINE_COUNT 8/16 — do not double.
//
// Q2 Drop scale stage by buffering more into 356 M10K?
//    Full 720p I420 ≈ 1078 ideal M10K — does NOT fit (plex_m10k_geom.svh).
//    Half-frame luma-only ≈ 360 — starves fabric copy + store linebufs.
//    => Keep thin line hold + NN map. Do NOT build frame-BRAM scaler.
//
// Q3 DDR BW vs present reader?
//    Each wr_line_done ≡ one content line fetch (if fed from DDR).
//    Glass hits on held lines add 0 DDR. Product must use ONE reader
//    (store OR scaler-fed), not both — else R adds. rd_bw_* count only.
//    Contention with w-mem copy engine: OPEN (shared controller).
//
// M10K ideal: LINE_HOLD * CONTENT_W_MAX * PIX_W / 10240
//   default 2 * 1280 * 24 / 10240 = **6.0 M10K**
// ALM: mul-shift NN + bank mux — ESTIMATE <500, fit UNVERIFIED.
//
// V1 quality: nearest-neighbour only. No polyphase (ascal owns HDMI).
// Pixel path: mul+shift only (sx_r updated off path over 20 clks).

`default_nettype none

`include "plex_m10k_geom.svh"

module present_nn_linebuf_scaler #(
	parameter int CONTENT_W_MAX = 1280,
	parameter int DE_W_MAX      = 1280,
	parameter int LINE_HOLD     = 2,
	parameter int PIX_W         = 24
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,

	input  wire [10:0] content_w,
	input  wire [10:0] de_w,

	input  wire        wr_valid,
	input  wire [10:0] wr_x,
	input  wire [PIX_W-1:0] wr_pix,
	input  wire        wr_line_done,

	input  wire        rd_en,
	input  wire [10:0] rd_x,
	input  wire        rd_use_prev,
	output reg  [PIX_W-1:0] rd_pix,
	output reg         rd_valid,

	output wire [15:0] m10k_ideal_c,
	output wire [31:0] rd_bw_content_lines,
	output wire [31:0] rd_bw_glass_hits,
	output wire        cfg_ok
);

	localparam int AW = $clog2(CONTENT_W_MAX);
	localparam int BW = (LINE_HOLD <= 1) ? 1 : $clog2(LINE_HOLD);
	localparam int BITS_TOTAL = LINE_HOLD * CONTENT_W_MAX * PIX_W;
	localparam int M10K_IDEAL = (BITS_TOTAL + PLEX_M10K_BITS - 1) / PLEX_M10K_BITS;
	localparam bit M10K_FITS_FREE =
		(M10K_IDEAL <= PLEX_M10K_FREE_POSTSTRIP);
	localparam bit NO_FULL_FRAME =
		(PLEX_M10K_FULL_I420_720P_IDEAL > PLEX_M10K_FREE_POSTSTRIP);

	assign m10k_ideal_c = 16'(M10K_IDEAL);
	assign cfg_ok = M10K_FITS_FREE && NO_FULL_FRAME &&
		(LINE_HOLD >= 1) && (LINE_HOLD <= 4);

`ifndef SYNTHESIS
	initial begin
		if ((1280 * 8) != PLEX_M10K_BITS)
			$error("plex_m10k_geom: 1280*8 != 10240");
		if (PLEX_M10K_LUMA_LINE_1280 != 1)
			$error("plex_m10k_geom: luma line must be 1.0 M10K ideal");
		if (!cfg_ok)
			$error("present_nn_linebuf_scaler cfg_ok=0 M10K_IDEAL=%0d", M10K_IDEAL);
	end
`endif

	wire [10:0] cw_eff = (content_w == 11'd0) ? 11'd1 :
		(content_w > 11'(CONTENT_W_MAX)) ? 11'(CONTENT_W_MAX) : content_w;
	wire [10:0] dw_eff = (de_w == 11'd0) ? 11'd1 :
		(de_w > 11'(DE_W_MAX)) ? 11'(DE_W_MAX) : de_w;

	// ---- geometry → sx_r = floor(cw * 65536 / dw) ----
	// Integer divide runs ONLY when content_w/de_w change (off pixel path).
	// Pixel path remains mul+shift of rd_x * sx_r.
	reg [10:0] cw_r, dw_r;
	reg [19:0] sx_r;
	reg        geom_valid;

	always @(posedge clk) begin
		if (reset) begin
			cw_r <= 11'd1;
			dw_r <= 11'd1;
			sx_r <= 20'h10000;
			geom_valid <= 1'b0;
		end else if ((cw_eff != cw_r) || (dw_eff != dw_r)) begin
			cw_r <= cw_eff;
			dw_r <= dw_eff;
			// 27b numerator / 11b denominator → 20b Q16 scale (LPM_DIVIDE class).
			sx_r <= 20'((32'(cw_eff) << 16) / 32'(dw_eff));
			geom_valid <= 1'b1;
		end
	end

	// ---- M10K line hold ----
	(* ramstyle = "M10K" *) reg [PIX_W-1:0] line_mem [0:LINE_HOLD-1][0:CONTENT_W_MAX-1];

	reg [BW-1:0] wr_bank, cur_bank, prev_bank;
	reg [31:0] lines_in_r, glass_hits_r;
	assign rd_bw_content_lines = lines_in_r;
	assign rd_bw_glass_hits = glass_hits_r;

	wire wr_x_ok = (wr_x < cw_r);
	wire [AW-1:0] wr_a = AW'(wr_x);

	// NN: content_x = (rd_x * sx_r) >> 16
	wire [31:0] map_prod = {21'd0, rd_x} * {12'd0, sx_r};
	wire [15:0] map_hi = map_prod[31:16];
	wire [10:0] map_x =
		(map_hi >= {5'd0, cw_r}) ? (cw_r - 11'd1) : map_hi[10:0];
	wire [AW-1:0] rd_a = AW'(map_x);

	wire [BW-1:0] rd_bank = (LINE_HOLD == 1) ? cur_bank :
		(rd_use_prev ? prev_bank : cur_bank);

	always @(posedge clk) begin
		if (reset) begin
			wr_bank <= '0;
			cur_bank <= '0;
			prev_bank <= '0;
			rd_pix <= '0;
			rd_valid <= 1'b0;
			lines_in_r <= 32'd0;
			glass_hits_r <= 32'd0;
		end else begin
			if (wr_valid && wr_x_ok)
				line_mem[wr_bank][wr_a] <= wr_pix;

			if (wr_line_done) begin
				prev_bank <= cur_bank;
				cur_bank <= wr_bank;
				if (LINE_HOLD == 1)
					wr_bank <= '0;
				else if (wr_bank == BW'(LINE_HOLD - 1))
					wr_bank <= '0;
				else
					wr_bank <= wr_bank + 1'b1;
				if (lines_in_r != 32'hFFFF_FFFF)
					lines_in_r <= lines_in_r + 32'd1;
			end

			if (rd_en && geom_valid) begin
				rd_pix <= line_mem[rd_bank][rd_a];
				rd_valid <= 1'b1;
				if (glass_hits_r != 32'hFFFF_FFFF)
					glass_hits_r <= glass_hits_r + 32'd1;
			end else if (ce_pix) begin
				rd_valid <= 1'b0;
			end
		end
	end

	(* noprune *) wire        cfg_ok_k = cfg_ok;
	(* noprune *) wire [15:0] m10k_k   = m10k_ideal_c;

endmodule

`default_nettype wire
