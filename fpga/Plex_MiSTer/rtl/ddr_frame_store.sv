// HPS-DDR-backed YUV420p frame store.
//
// Reads planar YUV420 from HPS DDR banks into bank-tagged M10K line buffers.
// Legacy defaults match host/libmisterplex/ddr_frame_layout.hpp (624×480).
// Runtime geometry (PLXW / geom_enable) sizes the *fetch* for native content
// up to MAX_CODED 1280×720 (one M10K per luma line). Line RAMs are synthesis-
// sized to the max; active line qwords/pitch come from registers.
//
// geom_enable=0 (reset): bit-exact parameter path (CODED_W/H, stride=CODED_W).
// Bank phys base/stride remain parameters — Option-C (w-mem) is a param set,
// not a unilateral redefine of the bank contract here.

module ddr_frame_store #(
	parameter int FRAME_W = 640,
	parameter int FRAME_H = 480,
	parameter int FRAME_STRIDE = FRAME_W,
	parameter int CODED_W = FRAME_W,
	parameter int CODED_H = FRAME_H,
	// Max content the linebufs/datapath can address (720p-native).
	parameter int MAX_CODED_W = 1280,
	parameter int MAX_CODED_H = 720,
	parameter int DISPLAY_W = FRAME_W,
	parameter int DISPLAY_H = FRAME_H,
	parameter int CROP_LEFT = 0,
	parameter int CROP_TOP = 0,
	parameter int PRESENT_X = 0,
	parameter int PRESENT_Y = 0,
	parameter int LINE_COUNT = 8,
	parameter [31:0] PHYS_BASE = 32'h3000_0000,
	parameter int HPS_BANK_STRIDE_BYTES = 524288,
	parameter [31:0] DOORBELL_PHYS = PHYS_BASE + (2 * HPS_BANK_STRIDE_BYTES) - 32'h1000,
	parameter [31:0] MAILBOX_PHYS  = DOORBELL_PHYS + 32'h100,
	parameter [31:0] INPUT_MAILBOX_PHYS = DOORBELL_PHYS + 32'h108,
	parameter [31:0] SDRAM_MAILBOX_PHYS = DOORBELL_PHYS + 32'h110,
	parameter [31:0] FRAME_MAILBOX_PHYS = DOORBELL_PHYS + 32'h118,
	parameter [31:0] BANK_MAILBOX_PHYS  = DOORBELL_PHYS + 32'h128,
	parameter int DDR_BURST_MAX = 128,
	parameter bit IGNORE_STALE_DOORBELL_AFTER_RESET = 1'b1,
	parameter int STALE_DOORBELL_FALLBACK_POLLS = 4096,
	parameter bit PIPELINE_REFILL_SCHEDULER = 1'b1,
	parameter bit STRICT_YUV_DOORBELL = 1'b1,
	// 1: want_y / y_hit follow vertical beam (src_y_line) — product anti-thrash.
	// 0: legacy X-gated src_y thrash (HBlank want_y→0) — shear control only.
	parameter bit WANT_Y_LINE_ONLY = 1'b1,
	// 1: pending_ready holds while prep is complete even if IDLE schedules a
	//    current-window refill (product). 0: legacy clear-on-current-sched —
	//    freezes when want_y tracks the beam (silicon 9eb1431a class).
	parameter bit PENDING_READY_STICKY_PREP = 1'b1,
	// 1: prep slot alloc recycles valid-but-stale (wrong bank/line) slots.
	// 0: invalid-only (9eb1431a) — after first swap prep set is full of old-bank
	//    lines and hammers prep_base forever.
	parameter bit PREP_SLOT_RECYCLE = 1'b1,
	// 1 (product): if a new swap_req is accepted on the same sys clk as a vsync
	//    swap, keep swap_pending=1 for the newly latched pending_bank. Legacy
	//    NBA order cleared swap_pending after setting it, dropping the doorbell
	//    under sustained high-rate publish (playback ~24 fps) while idle's slow
	//    presents rarely collide with the 1-cycle vsync window.
	parameter bit SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC = 1'b1
)(
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,

	// rd_x/y: presentation or content coords (up to max(FRAME, MAX_CODED)).
	input  wire [$clog2((FRAME_W > MAX_CODED_W) ? FRAME_W : MAX_CODED_W)-1:0] rd_x,
	input  wire [$clog2((FRAME_H > MAX_CODED_H) ? FRAME_H : MAX_CODED_H)-1:0] rd_y,
	input  wire        rd_active,
	output reg  [7:0]  rd_r,
	output reg  [7:0]  rd_g,
	output reg  [7:0]  rd_b,

	// Runtime bank geometry (PLXW). geom_enable=0 → parameter legacy path.
	// Callers must tie these (product: Plex/present_core; TBs: 0).
	// No port defaults — Verilator was ignoring C++ drivers when defaults existed.
	input  wire        geom_enable,
	input  wire [10:0] rt_coded_w,
	input  wire [10:0] rt_coded_h,
	input  wire [11:0] rt_y_stride,
	input  wire [10:0] rt_chroma_stride,
	input  wire [10:0] rt_display_w,
	input  wire [10:0] rt_display_h,
	input  wire [10:0] rt_present_x,
	input  wire [10:0] rt_present_y,
	input  wire [10:0] rt_crop_left,
	input  wire [10:0] rt_crop_top,

	input  wire        start_req,
	input  wire        bank_sel,
	input  wire [15:0] status_osd,
	input  wire        input_cmd_valid,
	input  wire  [7:0] input_cmd,
	input  wire  [3:0] sdram_test_state,
	input  wire  [3:0] sdram_size_code,
	input  wire [15:0] sdram_error_count,

	output wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output reg   [7:0] DDRAM_BURSTCNT,
	output reg  [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output reg         DDRAM_RD,
	output reg  [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output reg         DDRAM_WE,

	input  wire        vsync_pulse,
	output reg         has_frame,
	output reg         swap_pending,
	output reg  [15:0] underrun_count,
	output reg  [15:0] frames_done,
	output reg         doorbell_ok,
	output wire  [7:0] debug_state
);
	// Port/scan domain: cover presentation FRAME and max content.
	localparam int RD_W_MAX = (FRAME_W > MAX_CODED_W) ? FRAME_W : MAX_CODED_W;
	localparam int RD_H_MAX = (FRAME_H > MAX_CODED_H) ? FRAME_H : MAX_CODED_H;
	localparam int X_W = $clog2(RD_W_MAX);
	localparam int Y_W = $clog2(RD_H_MAX);
	// Line RAM physical size = max coded line (1280 → 160 qwords = 1 M10K @64b).
	localparam int Y_LINE_QWORDS_MAX = MAX_CODED_W / 8;   // 160
	localparam int C_LINE_QWORDS_MAX = MAX_CODED_W / 16;  // 80
	localparam int Y_QW_AW = $clog2(Y_LINE_QWORDS_MAX);
	localparam int C_QW_AW = $clog2(C_LINE_QWORDS_MAX);
	// Legacy parameter path (geom_enable=0) — keep names used below.
	localparam int CODED_X_W = $clog2(MAX_CODED_W);
	localparam int CODED_Y_W = $clog2(MAX_CODED_H);
	localparam int Y_LINE_QWORDS = CODED_W / 8;           // legacy default fetch
	localparam int C_LINE_QWORDS = CODED_W / 16;
	localparam int LINE_SLOTS = LINE_COUNT * 2;
	localparam int SLOT_W = $clog2(LINE_SLOTS);
	localparam [SLOT_W-1:0] SECOND_SET_BASE = SLOT_W'(LINE_COUNT);
	localparam [X_W-1:0] LAST_X = X_W'(FRAME_W - 1);
	localparam [Y_W-1:0] LAST_Y = Y_W'(FRAME_H - 1);
	localparam [X_W-1:0] LEG_PRESENT_X = X_W'(PRESENT_X);
	localparam [Y_W-1:0] LEG_PRESENT_Y = Y_W'(PRESENT_Y);
	localparam [X_W-1:0] LEG_PRESENT_END_X = X_W'(PRESENT_X + DISPLAY_W);
	localparam [Y_W-1:0] LEG_PRESENT_END_Y = Y_W'(PRESENT_Y + DISPLAY_H);
	localparam [CODED_X_W-1:0] LEG_CROP_LEFT = CODED_X_W'(CROP_LEFT);
	localparam [CODED_Y_W-1:0] LEG_CROP_TOP = CODED_Y_W'(CROP_TOP);
	localparam [28:0] BASE_W0 = PHYS_BASE[31:3];
	localparam [28:0] HPS_BANK_STRIDE_QWORDS = 29'(HPS_BANK_STRIDE_BYTES / 8);
	localparam [28:0] BASE_W1 = PHYS_BASE[31:3] + HPS_BANK_STRIDE_QWORDS;
	localparam [28:0] DOORBELL_W = DOORBELL_PHYS[31:3];
	localparam [28:0] MAILBOX_W  = MAILBOX_PHYS[31:3];
	localparam [28:0] INPUT_MAILBOX_W = INPUT_MAILBOX_PHYS[31:3];
	localparam [28:0] SDRAM_MAILBOX_W = SDRAM_MAILBOX_PHYS[31:3];
	localparam [28:0] FRAME_MAILBOX_W = FRAME_MAILBOX_PHYS[31:3];
	localparam [28:0] BANK_MAILBOX_W  = BANK_MAILBOX_PHYS[31:3];
	// Legacy plane layout (stride == CODED_W).
	localparam [28:0] LEG_Y_PLANE_QWORDS = 29'((CODED_W * CODED_H) / 8);
	localparam [28:0] LEG_C_PLANE_QWORDS = 29'((CODED_W * CODED_H) / 32);
	localparam [28:0] LEG_U_PLANE_BASE = LEG_Y_PLANE_QWORDS;
	localparam [28:0] LEG_V_PLANE_BASE = LEG_Y_PLANE_QWORDS + LEG_C_PLANE_QWORDS;
	localparam [28:0] LEG_Y_LINE_QWORDS_W = 29'(Y_LINE_QWORDS);
	localparam [28:0] LEG_C_LINE_QWORDS_W = 29'(C_LINE_QWORDS);
	// Back-compat aliases (fault defines / older refs).
	localparam [28:0] Y_PLANE_QWORDS = LEG_Y_PLANE_QWORDS;
	localparam [28:0] C_PLANE_QWORDS = LEG_C_PLANE_QWORDS;
	localparam [28:0] U_PLANE_BASE = LEG_U_PLANE_BASE;
	localparam [28:0] V_PLANE_BASE = LEG_V_PLANE_BASE;
	localparam [28:0] Y_LINE_QWORDS_W = LEG_Y_LINE_QWORDS_W;
	localparam [28:0] C_LINE_QWORDS_W = LEG_C_LINE_QWORDS_W;
	localparam [Y_QW_AW:0] DDR_BURST_MAX_QWORDS = (Y_QW_AW+1)'(DDR_BURST_MAX);

	// ---- Runtime effective geometry (registered on clk; safe default = legacy) ----
	reg        geom_en_r;
	reg [10:0] eff_coded_w;
	reg [10:0] eff_coded_h;
	reg [11:0] eff_y_stride;
	reg [10:0] eff_c_stride;
	reg [10:0] eff_disp_w;
	reg [10:0] eff_disp_h;
	reg [10:0] eff_pres_x;
	reg [10:0] eff_pres_y;
	reg [10:0] eff_crop_l;
	reg [10:0] eff_crop_t;
	// Derived (qwords / plane bases) — recomputed with regs.
	reg [8:0]  eff_y_fetch_qw;   // ceil active luma line fetch (coded_w/8)
	reg [7:0]  eff_c_fetch_qw;   // coded_w/16
	reg [8:0]  eff_y_pitch_qw;   // y_stride/8
	reg [7:0]  eff_c_pitch_qw;   // chroma_stride/8
	reg [28:0] eff_u_base_qw;
	reg [28:0] eff_v_base_qw;

	wire [10:0] rt_cw_nz = (rt_coded_w == 11'd0) ? 11'(CODED_W) : rt_coded_w;
	wire [10:0] rt_ch_nz = (rt_coded_h == 11'd0) ? 11'(CODED_H) : rt_coded_h;
	wire [11:0] rt_ys_nz = (rt_y_stride == 12'd0) ? 12'(CODED_W) : rt_y_stride;
	wire [10:0] rt_cs_nz = (rt_chroma_stride == 11'd0) ? 11'(CODED_W/2) : rt_chroma_stride;
	wire [10:0] rt_dw_nz = (rt_display_w == 11'd0) ? rt_cw_nz : rt_display_w;
	wire [10:0] rt_dh_nz = (rt_display_h == 11'd0) ? rt_ch_nz : rt_display_h;

	// Clamp coded to MAX so line RAM addr never overflows.
	wire [10:0] rt_cw_cl = (rt_cw_nz > 11'(MAX_CODED_W)) ? 11'(MAX_CODED_W) : rt_cw_nz;
	wire [10:0] rt_ch_cl = (rt_ch_nz > 11'(MAX_CODED_H)) ? 11'(MAX_CODED_H) : rt_ch_nz;
	wire [11:0] rt_ys_cl = (rt_ys_nz > 12'(MAX_CODED_W)) ? 12'(MAX_CODED_W) : rt_ys_nz;
	wire [10:0] rt_cs_cl = (rt_cs_nz > 11'(MAX_CODED_W/2)) ? 11'(MAX_CODED_W/2) : rt_cs_nz;

	wire [28:0] rt_y_bytes_qw = ({17'd0, rt_ys_cl} * {18'd0, rt_ch_cl}) >> 3; // (ys*ch)/8
	wire [28:0] rt_c_bytes_qw = ({18'd0, rt_cs_cl} * {19'd0, rt_ch_cl[10:1]}) >> 3; // (cs*ch/2)/8

	// FAULT: ignore geom_enable (always legacy pitch) — red twin for runtime-stride gate.
`ifdef DDR_FRAME_STORE_FAULT_IGNORE_GEOM
	wire geom_enable_eff = 1'b0;
`else
	wire geom_enable_eff = geom_enable;
`endif

	always @(posedge clk) begin
		if (reset) begin
			geom_en_r      <= 1'b0;
			eff_coded_w    <= 11'(CODED_W);
			eff_coded_h    <= 11'(CODED_H);
			eff_y_stride   <= 12'(CODED_W);
			eff_c_stride   <= 11'(CODED_W/2);
			eff_disp_w     <= 11'(DISPLAY_W);
			eff_disp_h     <= 11'(DISPLAY_H);
			eff_pres_x     <= 11'(PRESENT_X);
			eff_pres_y     <= 11'(PRESENT_Y);
			eff_crop_l     <= 11'(CROP_LEFT);
			eff_crop_t     <= 11'(CROP_TOP);
			eff_y_fetch_qw <= 9'(Y_LINE_QWORDS);
			eff_c_fetch_qw <= 8'(C_LINE_QWORDS);
			eff_y_pitch_qw <= 9'(Y_LINE_QWORDS);
			eff_c_pitch_qw <= 8'(C_LINE_QWORDS);
			eff_u_base_qw  <= LEG_U_PLANE_BASE;
			eff_v_base_qw  <= LEG_V_PLANE_BASE;
		end else if (!geom_enable_eff) begin
			geom_en_r      <= 1'b0;
			eff_coded_w    <= 11'(CODED_W);
			eff_coded_h    <= 11'(CODED_H);
			eff_y_stride   <= 12'(CODED_W);
			eff_c_stride   <= 11'(CODED_W/2);
			eff_disp_w     <= 11'(DISPLAY_W);
			eff_disp_h     <= 11'(DISPLAY_H);
			eff_pres_x     <= 11'(PRESENT_X);
			eff_pres_y     <= 11'(PRESENT_Y);
			eff_crop_l     <= 11'(CROP_LEFT);
			eff_crop_t     <= 11'(CROP_TOP);
			eff_y_fetch_qw <= 9'(Y_LINE_QWORDS);
			eff_c_fetch_qw <= 8'(C_LINE_QWORDS);
			eff_y_pitch_qw <= 9'(Y_LINE_QWORDS);
			eff_c_pitch_qw <= 8'(C_LINE_QWORDS);
			eff_u_base_qw  <= LEG_U_PLANE_BASE;
			eff_v_base_qw  <= LEG_V_PLANE_BASE;
		end else begin
			geom_en_r      <= 1'b1;
			eff_coded_w    <= rt_cw_cl;
			eff_coded_h    <= rt_ch_cl;
			eff_y_stride   <= rt_ys_cl;
			eff_c_stride   <= rt_cs_cl;
			eff_disp_w     <= rt_dw_nz;
			eff_disp_h     <= rt_dh_nz;
			eff_pres_x     <= rt_present_x;
			eff_pres_y     <= rt_present_y;
			eff_crop_l     <= rt_crop_left;
			eff_crop_t     <= rt_crop_top;
			eff_y_fetch_qw <= rt_cw_cl[10:3]; // coded_w/8 (require multiple of 8)
			eff_c_fetch_qw <= rt_cw_cl[10:4]; // coded_w/16
			eff_y_pitch_qw <= rt_ys_cl[11:3]; // stride/8
			eff_c_pitch_qw <= rt_cs_cl[10:3];
			eff_u_base_qw  <= rt_y_bytes_qw;
			eff_v_base_qw  <= rt_y_bytes_qw + rt_c_bytes_qw;
		end
	end

	wire [X_W-1:0] PRESENT_X_L = X_W'(eff_pres_x);
	wire [Y_W-1:0] PRESENT_Y_L = Y_W'(eff_pres_y);
	wire [X_W-1:0] PRESENT_END_X = X_W'(eff_pres_x + eff_disp_w);
	wire [Y_W-1:0] PRESENT_END_Y = Y_W'(eff_pres_y + eff_disp_h);
	wire [CODED_X_W-1:0] CROP_LEFT_L = CODED_X_W'(eff_crop_l);
	wire [CODED_Y_W-1:0] CROP_TOP_L = CODED_Y_W'(eff_crop_t);
	localparam [31:0] MAGIC = 32'h504C_584B;
	localparam [31:0] MAGIC_S = 32'h504C_5853;
	localparam [31:0] MAGIC_I = 32'h504C_5849;
	localparam [31:0] MAGIC_M = 32'h504C_584D;
	localparam [31:0] MAGIC_F = 32'h504C_5846;
	localparam [31:0] MAGIC_D = 32'h504C_5844; // PLXD bank-release (Display-bank)
	localparam [1:0] DOORBELL_FORMAT_YUV420P = 2'd1;
	localparam [7:0] DEBUG_FORMAT_ERROR = 8'hE1; // PLXF frame-debug: rejected non-YUV doorbell

	// Gray-code conversions for safe multi-bit CDC (want_y crossing)
	function automatic [Y_W-1:0] y_bin2gray(input [Y_W-1:0] b);
		y_bin2gray = b ^ (b >> 1);
	endfunction

	function automatic [Y_W-1:0] y_gray2bin(input [Y_W-1:0] g);
		integer gi;
		begin
			y_gray2bin[Y_W-1] = g[Y_W-1];
			for (gi = Y_W-2; gi >= 0; gi = gi - 1)
				y_gray2bin[gi] = y_gray2bin[gi+1] ^ g[gi];
		end
	endfunction

	assign DDRAM_CLK = clk_ddr;
	assign DDRAM_BE = 8'hFF;

	reg [LINE_SLOTS-1:0] y_wr, u_wr, v_wr;
	reg [Y_QW_AW-1:0] y_wr_addr;
	reg [C_QW_AW-1:0] c_wr_addr;
	reg [63:0] y_wr_data, u_wr_data, v_wr_data;
	wire [63:0] y_q [0:LINE_SLOTS-1];
	wire [63:0] u_q [0:LINE_SLOTS-1];
	wire [63:0] v_q [0:LINE_SLOTS-1];
	wire rd_x_at_or_after_origin;
	wire rd_y_at_or_after_origin;
	generate
		if (PRESENT_X == 0) begin : gen_present_x_zero
			assign rd_x_at_or_after_origin = 1'b1;
		end else begin : gen_present_x_nonzero
			assign rd_x_at_or_after_origin = (rd_x >= PRESENT_X_L);
		end
		if (PRESENT_Y == 0) begin : gen_present_y_zero
			assign rd_y_at_or_after_origin = 1'b1;
		end else begin : gen_present_y_nonzero
			assign rd_y_at_or_after_origin = (rd_y >= PRESENT_Y_L);
		end
	endgenerate
	wire rd_x_visible = rd_x_at_or_after_origin && (rd_x < PRESENT_END_X);
	wire rd_y_visible = rd_y_at_or_after_origin && (rd_y < PRESENT_END_Y);
	wire rd_visible = rd_x_visible && rd_y_visible;
	wire [X_W-1:0] display_x = rd_x - PRESENT_X_L;
	wire [Y_W-1:0] display_y = rd_y - PRESENT_Y_L;
	// Pixel path: X+Y gate (outside present window → black / addr 0).
	wire [CODED_X_W-1:0] src_x = rd_visible ? (display_x + CROP_LEFT_L) : '0;
	wire [CODED_Y_W-1:0] src_y = rd_visible ? (display_y + CROP_TOP_L) : '0;
	// Line identity / prefetch path: follow the vertical beam whenever Y is inside
	// the present band — independent of horizontal blank. Gating line match and
	// want_y on full rd_visible forced src_y→0 every HBlank (including store_x=LAST),
	// which thrashed the fill scheduler off the beam line and produced a variable
	// black prefix at DE open (parent: ragged left edge, interiors aligned, median
	// miss ~420 px on silicon). Do NOT use force_top (WANT_Y_FORCE_TOP) — that
	// freeze-class latch cost two fits; vsync/leave-VBlank naturally returns the
	// beam (and thus want_y) to the top via present_core store_y.
	// WANT_Y_LINE_ONLY=0 restores X-gated thrash for freeze/shear control builds.
	wire [CODED_Y_W-1:0] src_y_line = rd_y_visible ? (display_y + CROP_TOP_L) : '0;
	wire [CODED_Y_W-1:0] pref_y = WANT_Y_LINE_ONLY ? src_y_line : src_y;
	wire [Y_QW_AW-1:0] y_rd_addr = src_x[CODED_X_W-1:3];
	wire [C_QW_AW-1:0] c_rd_addr = src_x[CODED_X_W-1:4];

	genvar li;
	generate
		for (li = 0; li < LINE_SLOTS; li = li + 1) begin : gen_line
			// Physical WIDTH = max line; active fetch length is eff_*_fetch_qw.
			line_buf_ram #(.WIDTH(Y_LINE_QWORDS_MAX), .AW(Y_QW_AW), .DATA_W(64)) yram (
				.wr_clk(clk_ddr), .wr_en(y_wr[li]), .wr_addr(y_wr_addr), .wr_data(y_wr_data),
				.rd_clk(clk), .rd_addr(y_rd_addr), .rd_data(y_q[li])
			);
			line_buf_ram #(.WIDTH(C_LINE_QWORDS_MAX), .AW(C_QW_AW), .DATA_W(64)) uram (
				.wr_clk(clk_ddr), .wr_en(u_wr[li]), .wr_addr(c_wr_addr), .wr_data(u_wr_data),
				.rd_clk(clk), .rd_addr(c_rd_addr), .rd_data(u_q[li])
			);
			line_buf_ram #(.WIDTH(C_LINE_QWORDS_MAX), .AW(C_QW_AW), .DATA_W(64)) vram (
				.wr_clk(clk_ddr), .wr_en(v_wr[li]), .wr_addr(c_wr_addr), .wr_data(v_wr_data),
				.rd_clk(clk), .rd_addr(c_rd_addr), .rd_data(v_q[li])
			);
		end
	endgenerate

	reg disp_bank;
	reg pending_bank;
	reg pending_bank_ddr;
	reg disp_buf;
	reg swap_req_s1, swap_req_s2, swap_req_seen;
	reg pending_bank_s1, pending_bank_s2;
	reg pending_ready_s1, pending_ready_s2;
	reg pending_ready_ddr;
	reg swap_req_t_ddr;
	reg vsync_toggle;
	reg reset_ddr_s1, reset_ddr_s2;
	wire reset_ddr = reset_ddr_s2;

	always @(posedge clk_ddr) begin
		if (reset) begin
			reset_ddr_s1 <= 1'b1;
			reset_ddr_s2 <= 1'b1;
		end else begin
			reset_ddr_s1 <= 1'b0;
			reset_ddr_s2 <= reset_ddr_s1;
		end
	end

	always @(posedge clk) begin
		if (reset) begin
			disp_bank <= 1'b0;
			pending_bank <= 1'b0;
			disp_buf <= 1'b0;
			has_frame <= 1'b0;
			swap_pending <= 1'b0;
			frames_done <= 16'd0;
			vsync_toggle <= 1'b0;
			swap_req_s1 <= 1'b0;
			swap_req_s2 <= 1'b0;
			swap_req_seen <= 1'b0;
			pending_bank_s1 <= 1'b0;
			pending_bank_s2 <= 1'b0;
			pending_ready_s1 <= 1'b0;
			pending_ready_s2 <= 1'b0;
		end else begin
			swap_req_s1 <= swap_req_t_ddr;
			swap_req_s2 <= swap_req_s1;
			pending_bank_s1 <= pending_bank_ddr;
			pending_bank_s2 <= pending_bank_s1;
			pending_ready_s1 <= pending_ready_ddr;
			pending_ready_s2 <= pending_ready_s1;

			// Capture new doorbell before vsync-swap decision so a same-cycle collision
			// can retain swap_pending for the newly latched bank (product).
			// Legacy: both branches NBA-assigned swap_pending; the vsync clear
			// won, consuming swap_req_seen while dropping the new pending frame.
			if (swap_req_s2 != swap_req_seen) begin
				swap_req_seen <= swap_req_s2;
				pending_bank <= pending_bank_s2;
				if (!(SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC
				      && vsync_pulse && swap_pending && pending_ready_s2))
					swap_pending <= 1'b1;
			end

			if (vsync_pulse && swap_pending && pending_ready_s2) begin
`ifndef DDR_FRAME_STORE_FAULT_HOLD_DISP_BANK
				// Uses pre-NBA pending_bank: the bank that was ready this cycle.
				// A same-cycle swap_req updates pending_bank for the *next* swap.
				disp_bank <= pending_bank;
`endif
				disp_buf <= ~disp_buf;
				has_frame <= 1'b1;
				if (SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC
				    && (swap_req_s2 != swap_req_seen))
					swap_pending <= 1'b1;
				else
					swap_pending <= 1'b0;
				frames_done <= frames_done + 16'd1;
				vsync_toggle <= ~vsync_toggle;
			end else if (vsync_pulse) begin
				vsync_toggle <= ~vsync_toggle;
			end
		end
	end

	function automatic [7:0] pick_byte(input [63:0] q, input [2:0] sel);
		case (sel)
			3'd0: pick_byte = q[7:0];
			3'd1: pick_byte = q[15:8];
			3'd2: pick_byte = q[23:16];
			3'd3: pick_byte = q[31:24];
			3'd4: pick_byte = q[39:32];
			3'd5: pick_byte = q[47:40];
			3'd6: pick_byte = q[55:48];
			default: pick_byte = q[63:56];
		endcase
	endfunction

	function automatic [7:0] sat8(input signed [11:0] v);
		begin
			if (v < 0)
				sat8 = 8'd0;
			else if (v > 12'sd255)
				sat8 = 8'd255;
			else
				sat8 = v[7:0];
		end
	endfunction

	reg [LINE_SLOTS-1:0] y_valid_v1, y_valid_v2, c_valid_v1, c_valid_v2;
	reg [LINE_SLOTS-1:0] y_bank_v1, y_bank_v2, c_bank_v1, c_bank_v2;
	reg [Y_W-1:0] y_line_v1 [0:LINE_SLOTS-1];
	reg [Y_W-1:0] y_line_v2 [0:LINE_SLOTS-1];
	reg [Y_W-2:0] c_line_v1 [0:LINE_SLOTS-1];
	reg [Y_W-2:0] c_line_v2 [0:LINE_SLOTS-1];
	reg [Y_W-1:0] want_y_sys;
	reg [Y_W-1:0] want_y_gray;  // Gray-encoded want_y for safe CDC

	// Source-domain status registers for clk → clk_ddr telemetry.
	reg [15:0] status_osd_hold;
	reg [23:0] sdram_status_hold;
	reg        frame_miss_toggle;

	reg rd_active_r, rd_active_d, rd_visible_r, rd_visible_d, miss_d;
	reg y_hit_r, c_hit_r;
	reg [SLOT_W-1:0] y_hit_idx_r, c_hit_idx_r;
	reg [2:0] y_sel_r, c_sel_r;

	integer vi;
	reg y_hit_now, c_hit_now;
	reg [SLOT_W-1:0] y_hit_idx_now, c_hit_idx_now;
	reg [63:0] selected_y_q, selected_u_q, selected_v_q;
	reg [SLOT_W-1:0] video_slot;
`ifdef DDR_FRAME_STORE_FAULT_CHROMA_VERTICAL_FULLRES
	wire [CODED_Y_W-2:0] rd_cy = src_y_line[CODED_Y_W-2:0];
`else
	wire [CODED_Y_W-2:0] rd_cy = src_y_line[CODED_Y_W-1:1];
`endif
	always @* begin
		y_hit_now = 1'b0;
		c_hit_now = 1'b0;
		y_hit_idx_now = '0;
		c_hit_idx_now = '0;
		selected_y_q = 64'd0;
		selected_u_q = 64'd0;
		selected_v_q = 64'd0;
		for (vi = 0; vi < LINE_COUNT; vi = vi + 1) begin
			video_slot = (disp_buf ? SECOND_SET_BASE : '0) + vi[SLOT_W-1:0];
			// Match beam line via pref_y (product: src_y_line; thrash control: src_y).
			if (y_valid_v2[video_slot] && (y_bank_v2[video_slot] == disp_bank)
			    && (y_line_v2[video_slot] == Y_W'(pref_y)) && !y_hit_now) begin
				y_hit_now = 1'b1;
				y_hit_idx_now = video_slot;
			end
			if (c_valid_v2[video_slot] && (c_bank_v2[video_slot] == disp_bank)
			    && (c_line_v2[video_slot] == (Y_W-1)'(rd_cy)) && !c_hit_now) begin
				c_hit_now = 1'b1;
				c_hit_idx_now = video_slot;
			end
			if (y_hit_idx_r == video_slot)
				selected_y_q = y_q[video_slot];
			if (c_hit_idx_r == video_slot) begin
				selected_u_q = u_q[video_slot];
				selected_v_q = v_q[video_slot];
			end
		end
	end
	// Miss when the line under the beam is not yet in an M10K slot → RGB black.
	// Primary left-edge class: HBlank want_y/src_y thrash (fixed via src_y_line).
	// Residual miss under true DDR backlog still counts as underrun.
	wire rd_miss_now = rd_active && rd_visible && has_frame && (!y_hit_now || !c_hit_now);

	wire [7:0] y_pix = pick_byte(selected_y_q, y_sel_r);
	wire [7:0] u_pix = pick_byte(selected_u_q, c_sel_r);
	wire [7:0] v_pix = pick_byte(selected_v_q, c_sel_r);
	wire signed [11:0] y_s = {4'd0, y_pix};
	wire signed [11:0] u_s = {4'd0, u_pix} - 12'sd128;
	wire signed [11:0] v_s = {4'd0, v_pix} - 12'sd128;
	wire signed [20:0] y_ext = {{9{y_s[11]}}, y_s};
	wire signed [20:0] r_calc_w = (y_ext <<< 8) + (21'sd359 * v_s);
	wire signed [20:0] g_calc_w = (y_ext <<< 8) - (21'sd88 * u_s) - (21'sd183 * v_s);
	wire signed [20:0] b_calc_w = (y_ext <<< 8) + (21'sd454 * u_s);
	wire signed [11:0] r_calc = r_calc_w[19:8];
	wire signed [11:0] g_calc = g_calc_w[19:8];
	wire signed [11:0] b_calc = b_calc_w[19:8];

	always @(posedge clk) begin
		if (reset) begin
			rd_active_r <= 1'b0;
			rd_active_d <= 1'b0;
			rd_visible_r <= 1'b0;
			rd_visible_d <= 1'b0;
			miss_d <= 1'b0;
			underrun_count <= 16'd0;
			want_y_sys <= '0;
			want_y_gray <= '0;
			status_osd_hold <= 16'd0;
			sdram_status_hold <= 24'd0;
			frame_miss_toggle <= 1'b0;
			y_valid_v1 <= '0;
			y_valid_v2 <= '0;
			c_valid_v1 <= '0;
			c_valid_v2 <= '0;
			y_bank_v1 <= '0;
			y_bank_v2 <= '0;
			c_bank_v1 <= '0;
			c_bank_v2 <= '0;
			y_hit_r <= 1'b0;
			c_hit_r <= 1'b0;
			y_hit_idx_r <= '0;
			c_hit_idx_r <= '0;
			y_sel_r <= 3'd0;
			c_sel_r <= 3'd0;
		end else begin
			y_valid_v1 <= y_valid_hold;
			y_valid_v2 <= y_valid_v1;
			c_valid_v1 <= c_valid_hold;
			c_valid_v2 <= c_valid_v1;
			y_bank_v1 <= y_bank_hold;
			y_bank_v2 <= y_bank_v1;
			c_bank_v1 <= c_bank_hold;
			c_bank_v2 <= c_bank_v1;
			for (vi = 0; vi < LINE_SLOTS; vi = vi + 1) begin
				y_line_v1[vi] <= y_line_hold[vi];
				y_line_v2[vi] <= y_line_v1[vi];
				c_line_v1[vi] <= c_line_hold[vi];
				c_line_v2[vi] <= c_line_v1[vi];
			end

			// want_y: product uses pref_y=src_y_line (Y beam only). Thrash control
			// uses pref_y=src_y (X-gated). No FORCE_TOP.
			// When WANT_Y_LINE_ONLY=0, rd_visible low forces pref_y=0 every HBlank.
			if (WANT_Y_LINE_ONLY ? rd_y_visible : rd_visible) begin
				if (want_y_sys != Y_W'(pref_y))
					want_y_sys <= Y_W'(pref_y);
			end else if (want_y_sys != '0) begin
				want_y_sys <= '0;
			end
			want_y_gray <= y_bin2gray(want_y_sys);

			if (status_osd != status_osd_hold) begin
				status_osd_hold <= status_osd;
			end

			if ({sdram_error_count, sdram_size_code, sdram_test_state} != sdram_status_hold)
				sdram_status_hold <= {sdram_error_count, sdram_size_code, sdram_test_state};

			rd_active_r <= rd_active;
			rd_active_d <= rd_active_r;
			rd_visible_r <= rd_visible;
			rd_visible_d <= rd_visible_r;
			y_hit_r <= y_hit_now;
			c_hit_r <= c_hit_now;
			y_hit_idx_r <= y_hit_idx_now;
			c_hit_idx_r <= c_hit_idx_now;
			y_sel_r <= src_x[2:0];
			c_sel_r <= src_x[3:1];
			miss_d <= rd_miss_now;
			if (miss_d && underrun_count != 16'hFFFF) begin
				underrun_count <= underrun_count + 16'd1;
				frame_miss_toggle <= ~frame_miss_toggle;
			end

			if ((rd_active_d || !rd_active) && rd_visible_d && has_frame && !miss_d && y_hit_r && c_hit_r) begin
				rd_r <= sat8(r_calc);
				rd_g <= sat8(g_calc);
				rd_b <= sat8(b_calc);
			end else if (!has_frame || !rd_visible_d || miss_d) begin
				rd_r <= 8'd0;
				rd_g <= 8'd0;
				rd_b <= 8'd0;
			end
		end
	end

	localparam [3:0] S_IDLE       = 4'd0;
	localparam [3:0] S_LINE_ISSUE = 4'd1;
	localparam [3:0] S_LINE_WAIT  = 4'd2;
	localparam [3:0] S_POLL_WAIT  = 4'd3;
	localparam [3:0] S_WRITE_WAIT = 4'd4;

	reg [3:0] state_ddr;
	reg [LINE_SLOTS-1:0] y_valid, c_valid;
	reg [LINE_SLOTS-1:0] y_bank, c_bank;
	reg [Y_W-1:0] y_line [0:LINE_SLOTS-1];
	reg [Y_W-2:0] c_line [0:LINE_SLOTS-1];
	reg disp_bank_d1, disp_bank_d2;
	reg disp_buf_d1, disp_buf_d2;
	reg has_frame_d1, has_frame_d2;
	reg swap_pending_d1, swap_pending_d2;
	reg pending_bank_d1, pending_bank_d2;
	reg [Y_W-1:0] want_y_gray_s1, want_y_gray_s2;  // Gray-coded 2-FF sync
	reg [Y_W-1:0] desired_y_r [0:LINE_COUNT-1];
	reg [15:0] poll_div;
	reg poll_pending;
	wire [LINE_SLOTS-1:0] y_valid_hold, c_valid_hold;
	wire [LINE_SLOTS-1:0] y_bank_hold, c_bank_hold;
	wire [Y_W-1:0] y_line_hold [0:LINE_SLOTS-1];
	wire [Y_W-2:0] c_line_hold [0:LINE_SLOTS-1];
	localparam int STALE_DB_POLL_MAX = (STALE_DOORBELL_FALLBACK_POLLS < 1) ? 1 : STALE_DOORBELL_FALLBACK_POLLS;
	localparam int STALE_DB_POLL_W = $clog2(STALE_DB_POLL_MAX + 1);
	reg [31:0] last_seq;
	reg have_seq;
	reg doorbell_primed;
	reg format_error;
	reg [STALE_DB_POLL_W-1:0] stale_db_polls;
	reg [15:0] mbox_seq, mbox_last;
	reg mbox_req, mbox_valid;
	reg [17:0] mbox_hb;
	reg [7:0] sdram_mbox_seq, frame_mbox_seq;
	reg [23:0] sdram_mbox_last, frame_mbox_last;
	reg sdram_mbox_req, sdram_mbox_valid;
	reg frame_mbox_req, frame_mbox_valid;
	reg [17:0] sdram_mbox_hb, frame_mbox_hb;
	reg bank_mbox_req, bank_mbox_valid;
	reg [17:0] bank_mbox_hb;
	reg [7:0] bank_mbox_seq;
	reg [15:0] bank_vsync_count;
	reg [15:0] frames_done_d1, frames_done_d2; // clk→clk_ddr (PLXD pack)
	reg bank_plxd_swap_d, bank_plxd_disp_d;    // edge detect for fresher free_mask
	reg vsync_t_d1, vsync_t_d2, vsync_t_seen;
	reg start_d1, start_d2, start_seen;
	reg bank_sel_d1, bank_sel_d2;

	genvar mi, ybi, cbi;
	generate
		for (mi = 0; mi < LINE_SLOTS; mi = mi + 1) begin : gen_meta_hold_pad
			mplex_hold_lcell y_valid_pad (.din(y_valid[mi]), .dout(y_valid_hold[mi]));
			mplex_hold_lcell c_valid_pad (.din(c_valid[mi]), .dout(c_valid_hold[mi]));
			mplex_hold_lcell y_bank_pad  (.din(y_bank[mi]),  .dout(y_bank_hold[mi]));
			mplex_hold_lcell c_bank_pad  (.din(c_bank[mi]),  .dout(c_bank_hold[mi]));
			for (ybi = 0; ybi < Y_W; ybi = ybi + 1) begin : gen_y_line_hold_pad
				mplex_hold_lcell y_line_pad (.din(y_line[mi][ybi]), .dout(y_line_hold[mi][ybi]));
			end
			for (cbi = 0; cbi < Y_W-1; cbi = cbi + 1) begin : gen_c_line_hold_pad
				mplex_hold_lcell c_line_pad (.din(c_line[mi][cbi]), .dout(c_line_hold[mi][cbi]));
			end
		end
	endgenerate

	// clk → clk_ddr telemetry receivers.
	reg [15:0] status_osd_s1, status_osd_s2, status_osd_s3;
	reg [15:0] status_osd_safe;
	reg [23:0] sdram_status_s1, sdram_status_s2, sdram_status_s3;
	reg [23:0] sdram_status_safe;
	reg        frame_miss_tog_s1, frame_miss_tog_s2, frame_miss_tog_seen;
	reg [15:0] frame_underrun_ddr;
	reg [23:0] frame_status_ddr;

	wire cmd_empty;
	wire [7:0] cmd_rdata;
	reg cmd_pop;
	async_fifo #(.WIDTH(8), .AW(2)) input_fifo (
		.wr_clk(clk), .wr_reset(reset),
		.wr_en(input_cmd_valid && (input_cmd != 8'd0)), .wr_data(input_cmd),
		.wr_full(), .wr_almost_full(),
		.rd_clk(clk_ddr), .rd_reset(reset_ddr), .rd_en(cmd_pop), .rd_data(cmd_rdata), .rd_empty(cmd_empty)
	);

	// max_h = effective coded height (legacy FRAME_H/CODED_H when geom off).
	function automatic [Y_W-1:0] clamp_ahead(input [Y_W-1:0] base, input integer ahead, input integer max_h);
		integer sum;
		integer last;
		begin
			sum = {{(32-Y_W){1'b0}}, base};
			sum = sum + ahead;
			last = (max_h > 0) ? (max_h - 1) : 0;
			clamp_ahead = (sum >= max_h) ? Y_W'(last) : sum[Y_W-1:0];
		end
	endfunction

	integer ti, tj, tk;
	reg need_y_cur_c, need_c_cur_c, need_y_prep_c, need_c_prep_c, pending_ready_c;
	reg [Y_W-1:0] target_y_cur_c, target_y_prep_c;
	reg [Y_W-2:0] target_c_cur_c, target_c_prep_c;
	reg [SLOT_W-1:0] target_y_idx_cur_c, target_y_idx_prep_c, target_c_idx_cur_c, target_c_idx_prep_c;
	reg found_line, slot_keep, found_slot_y_cur, found_slot_y_prep, found_slot_c_cur, found_slot_c_prep;
	reg [Y_W-1:0] desired_y;
	reg [Y_W-2:0] desired_c;
	reg [SLOT_W-1:0] cur_base_idx, prep_base_idx;
	reg sched_valid, sched_is_y, sched_for_pending;
	reg sched_bank, sched_pending_ready;
	reg [Y_W-1:0] sched_y;
	reg [Y_W-2:0] sched_cy;
	reg [SLOT_W-1:0] sched_idx;
	always @* begin
		cur_base_idx = disp_buf_d2 ? SECOND_SET_BASE : '0;
		prep_base_idx = disp_buf_d2 ? '0 : SECOND_SET_BASE;
		need_y_cur_c = 1'b0;
		need_c_cur_c = 1'b0;
		need_y_prep_c = 1'b0;
		need_c_prep_c = 1'b0;
		target_y_cur_c = desired_y_r[0];
		target_y_prep_c = '0;
		target_c_cur_c = desired_y_r[0][Y_W-1:1];
		target_c_prep_c = '0;
		target_y_idx_cur_c = cur_base_idx;
		target_y_idx_prep_c = prep_base_idx;
		target_c_idx_cur_c = cur_base_idx;
		target_c_idx_prep_c = prep_base_idx;
		found_slot_y_cur = 1'b0;
		found_slot_y_prep = 1'b0;
		found_slot_c_cur = 1'b0;
		found_slot_c_prep = 1'b0;
		pending_ready_c = 1'b1;

		for (ti = 0; ti < LINE_COUNT; ti = ti + 1) begin
			desired_y = desired_y_r[ti];
			desired_c = desired_y_r[ti][Y_W-1:1];
			found_line = 1'b0;
			for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
				if (y_valid[cur_base_idx + tj[SLOT_W-1:0]] && (y_bank[cur_base_idx + tj[SLOT_W-1:0]] == disp_bank_d2)
				    && (y_line[cur_base_idx + tj[SLOT_W-1:0]] == desired_y))
					found_line = 1'b1;
			end
			if (!found_line && !need_y_cur_c) begin
				need_y_cur_c = 1'b1;
				target_y_cur_c = desired_y;
			end

			found_line = 1'b0;
			for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
				if (c_valid[cur_base_idx + tj[SLOT_W-1:0]] && (c_bank[cur_base_idx + tj[SLOT_W-1:0]] == disp_bank_d2)
				    && (c_line[cur_base_idx + tj[SLOT_W-1:0]] == desired_c))
					found_line = 1'b1;
			end
			if (!found_line && !need_c_cur_c) begin
				need_c_cur_c = 1'b1;
				target_c_cur_c = desired_c;
			end

			found_line = 1'b0;
			for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
				if (y_valid[prep_base_idx + tj[SLOT_W-1:0]] && (y_bank[prep_base_idx + tj[SLOT_W-1:0]] == pending_bank_d2)
				    && (y_line[prep_base_idx + tj[SLOT_W-1:0]] == ti[Y_W-1:0]))
					found_line = 1'b1;
			end
			if (swap_pending_d2 && !found_line) begin
				pending_ready_c = 1'b0;
				if (!need_y_prep_c) begin
					need_y_prep_c = 1'b1;
					target_y_prep_c = ti[Y_W-1:0];
				end
			end

			found_line = 1'b0;
			for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
				if (c_valid[prep_base_idx + tj[SLOT_W-1:0]] && (c_bank[prep_base_idx + tj[SLOT_W-1:0]] == pending_bank_d2)
				    && (c_line[prep_base_idx + tj[SLOT_W-1:0]] == ti[Y_W-1:1]))
					found_line = 1'b1;
			end
			if (swap_pending_d2 && !found_line) begin
				pending_ready_c = 1'b0;
				if (!need_c_prep_c) begin
					need_c_prep_c = 1'b1;
					target_c_prep_c = ti[Y_W-1:1];
				end
			end
		end

		for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
			slot_keep = 1'b0;
			for (tk = 0; tk < LINE_COUNT; tk = tk + 1) begin
				if (y_valid[cur_base_idx + tj[SLOT_W-1:0]] && (y_bank[cur_base_idx + tj[SLOT_W-1:0]] == disp_bank_d2)
				    && (y_line[cur_base_idx + tj[SLOT_W-1:0]] == desired_y_r[tk]))
					slot_keep = 1'b1;
			end
			if ((!y_valid[cur_base_idx + tj[SLOT_W-1:0]] || !slot_keep) && !found_slot_y_cur) begin
				found_slot_y_cur = 1'b1;
				target_y_idx_cur_c = cur_base_idx + tj[SLOT_W-1:0];
			end

			slot_keep = 1'b0;
			for (tk = 0; tk < LINE_COUNT; tk = tk + 1) begin
				if (c_valid[cur_base_idx + tj[SLOT_W-1:0]] && (c_bank[cur_base_idx + tj[SLOT_W-1:0]] == disp_bank_d2)
				    && (c_line[cur_base_idx + tj[SLOT_W-1:0]] == desired_y_r[tk][Y_W-1:1]))
					slot_keep = 1'b1;
			end
			if ((!c_valid[cur_base_idx + tj[SLOT_W-1:0]] || !slot_keep) && !found_slot_c_cur) begin
				found_slot_c_cur = 1'b1;
				target_c_idx_cur_c = cur_base_idx + tj[SLOT_W-1:0];
			end

			// Prep slots must recycle stale post-swap contents (valid but wrong
			// bank/line). Invalid-only selection left the set full of old-bank
			// lines and hammered prep_base forever — prep never reached
			// pending_ready_c (freeze after first swap under src_y_line).
			if (PREP_SLOT_RECYCLE) begin
				slot_keep = 1'b0;
				for (tk = 0; tk < LINE_COUNT; tk = tk + 1) begin
					if (y_valid[prep_base_idx + tj[SLOT_W-1:0]]
					    && (y_bank[prep_base_idx + tj[SLOT_W-1:0]] == pending_bank_d2)
					    && (y_line[prep_base_idx + tj[SLOT_W-1:0]] == tk[Y_W-1:0]))
						slot_keep = 1'b1;
				end
				if ((!y_valid[prep_base_idx + tj[SLOT_W-1:0]] || !slot_keep) && !found_slot_y_prep) begin
					found_slot_y_prep = 1'b1;
					target_y_idx_prep_c = prep_base_idx + tj[SLOT_W-1:0];
				end
				slot_keep = 1'b0;
				for (tk = 0; tk < LINE_COUNT; tk = tk + 1) begin
					if (c_valid[prep_base_idx + tj[SLOT_W-1:0]]
					    && (c_bank[prep_base_idx + tj[SLOT_W-1:0]] == pending_bank_d2)
					    && (c_line[prep_base_idx + tj[SLOT_W-1:0]] == tk[Y_W-1:1]))
						slot_keep = 1'b1;
				end
				if ((!c_valid[prep_base_idx + tj[SLOT_W-1:0]] || !slot_keep) && !found_slot_c_prep) begin
					found_slot_c_prep = 1'b1;
					target_c_idx_prep_c = prep_base_idx + tj[SLOT_W-1:0];
				end
			end else begin
				if ((!y_valid[prep_base_idx + tj[SLOT_W-1:0]]) && !found_slot_y_prep) begin
					found_slot_y_prep = 1'b1;
					target_y_idx_prep_c = prep_base_idx + tj[SLOT_W-1:0];
				end
				if ((!c_valid[prep_base_idx + tj[SLOT_W-1:0]]) && !found_slot_c_prep) begin
					found_slot_c_prep = 1'b1;
					target_c_idx_prep_c = prep_base_idx + tj[SLOT_W-1:0];
				end
			end
		end
	end


	reg fill_bank, fill_is_chroma, fill_plane_v;
	reg [Y_W-1:0] fill_y;
	reg [Y_W-2:0] fill_cy;
	reg [SLOT_W-1:0] fill_idx;
	reg [Y_QW_AW:0] fill_qword;
	reg [Y_QW_AW:0] burst_left;
	reg [Y_QW_AW:0] qwords_remaining;
	reg [7:0] imbox_cmd_seq;
	reg [15:0] imbox_seq;
	// Geometry is session-static (programmed before play). Two-flop into clk_ddr
	// for fill address math; pixel path stays on clk with eff_*.
	reg [8:0]  d_y_fetch_qw, d_y_pitch_qw;
	reg [7:0]  d_c_fetch_qw, d_c_pitch_qw;
	reg [28:0] d_u_base_qw, d_v_base_qw;
	reg [10:0] d_coded_h;
	reg [8:0]  d_y_fetch_qw_m, d_y_pitch_qw_m;
	reg [7:0]  d_c_fetch_qw_m, d_c_pitch_qw_m;
	reg [28:0] d_u_base_qw_m, d_v_base_qw_m;
	reg [10:0] d_coded_h_m;
	always @(posedge clk_ddr) begin
		if (reset_ddr) begin
			d_y_fetch_qw_m <= 9'(Y_LINE_QWORDS);
			d_c_fetch_qw_m <= 8'(C_LINE_QWORDS);
			d_y_pitch_qw_m <= 9'(Y_LINE_QWORDS);
			d_c_pitch_qw_m <= 8'(C_LINE_QWORDS);
			d_u_base_qw_m  <= LEG_U_PLANE_BASE;
			d_v_base_qw_m  <= LEG_V_PLANE_BASE;
			d_coded_h_m    <= 11'(CODED_H);
			d_y_fetch_qw   <= 9'(Y_LINE_QWORDS);
			d_c_fetch_qw   <= 8'(C_LINE_QWORDS);
			d_y_pitch_qw   <= 9'(Y_LINE_QWORDS);
			d_c_pitch_qw   <= 8'(C_LINE_QWORDS);
			d_u_base_qw    <= LEG_U_PLANE_BASE;
			d_v_base_qw    <= LEG_V_PLANE_BASE;
			d_coded_h      <= 11'(CODED_H);
		end else begin
			d_y_fetch_qw_m <= eff_y_fetch_qw;
			d_c_fetch_qw_m <= eff_c_fetch_qw;
			d_y_pitch_qw_m <= eff_y_pitch_qw;
			d_c_pitch_qw_m <= eff_c_pitch_qw;
			d_u_base_qw_m  <= eff_u_base_qw;
			d_v_base_qw_m  <= eff_v_base_qw;
			d_coded_h_m    <= eff_coded_h;
			d_y_fetch_qw   <= d_y_fetch_qw_m;
			d_c_fetch_qw   <= d_c_fetch_qw_m;
			d_y_pitch_qw   <= d_y_pitch_qw_m;
			d_c_pitch_qw   <= d_c_pitch_qw_m;
			d_u_base_qw    <= d_u_base_qw_m;
			d_v_base_qw    <= d_v_base_qw_m;
			d_coded_h      <= d_coded_h_m;
		end
	end

	wire [28:0] fill_bank_base = fill_bank ? BASE_W1 : BASE_W0;
	// Pitch from runtime y_stride/chroma_stride (legacy: pitch == fetch == CODED_W/8).
	wire [28:0] y_pitch_qw_w = {20'd0, d_y_pitch_qw};
	wire [28:0] c_pitch_qw_w = {21'd0, d_c_pitch_qw};
	wire [28:0] fill_y_qword = {{(29-Y_W){1'b0}}, fill_y} * y_pitch_qw_w;
`ifdef DDR_FRAME_STORE_FAULT_CHROMA_LUMA_STRIDE
	wire [28:0] fill_cy_qword = {{(30-Y_W){1'b0}}, fill_cy} * y_pitch_qw_w;
`else
	wire [28:0] fill_cy_qword = {{(30-Y_W){1'b0}}, fill_cy} * c_pitch_qw_w;
`endif
	wire [28:0] fill_qword_y = {{(29-Y_QW_AW){1'b0}}, fill_qword[Y_QW_AW-1:0]};
	wire [28:0] fill_qword_c = {{(29-C_QW_AW){1'b0}}, fill_qword[C_QW_AW-1:0]};
	wire [28:0] y_addr = fill_bank_base + fill_y_qword + fill_qword_y;
	wire [28:0] u_addr = fill_bank_base + d_u_base_qw + fill_cy_qword + fill_qword_c;
	wire [28:0] v_addr = fill_bank_base + d_v_base_qw + fill_cy_qword + fill_qword_c;
`ifdef DDR_FRAME_STORE_FAULT_SWAP_UV_READ
	wire [28:0] chroma_addr = fill_plane_v ? u_addr : v_addr;
`else
	wire [28:0] chroma_addr = fill_plane_v ? v_addr : u_addr;
`endif
	wire [28:0] line_addr = fill_is_chroma ? chroma_addr : y_addr;
	wire [Y_QW_AW:0] burst_cap = (qwords_remaining > DDR_BURST_MAX_QWORDS) ? DDR_BURST_MAX_QWORDS : qwords_remaining;
	wire [7:0] burst_this = burst_cap[7:0];
	wire db_magic_ok = poll_pending && DDRAM_DOUT_READY && (DDRAM_DOUT[31:0] == MAGIC);
	wire [31:0] db_token = DDRAM_DOUT[63:32];
	wire [1:0] db_format = db_token[30:29];
	wire db_format_ok = (db_format == DOORBELL_FORMAT_YUV420P) || !STRICT_YUV_DOORBELL;
	wire db_bad_format = db_magic_ok && !db_format_ok;
	wire db_valid_token = db_magic_ok && db_format_ok;
	wire db_token_new = db_valid_token && (!have_seq || (db_token != last_seq));
	wire db_token_same = db_valid_token && have_seq && (db_token == last_seq);
	wire db_stale_fallback = db_token_same && IGNORE_STALE_DOORBELL_AFTER_RESET &&
	                         doorbell_primed &&
	                         (stale_db_polls == STALE_DB_POLL_W'(STALE_DB_POLL_MAX));
	wire db_new_seq = (db_token_new && (!IGNORE_STALE_DOORBELL_AFTER_RESET || doorbell_primed)) ||
	                  db_stale_fallback;
	wire spi_edge_ddr = start_d2 != start_seen;

	assign debug_state = format_error ? DEBUG_FORMAT_ERROR : {LINE_COUNT[2:0], |y_valid, state_ddr};

	always @(posedge clk_ddr) begin
		if (reset_ddr) begin
			state_ddr <= S_IDLE;
			DDRAM_RD <= 1'b0;
			DDRAM_WE <= 1'b0;
			DDRAM_ADDR <= 29'd0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_DIN <= 64'd0;
			y_wr <= '0;
			u_wr <= '0;
			v_wr <= '0;
			y_wr_addr <= '0;
			c_wr_addr <= '0;
			y_wr_data <= 64'd0;
			u_wr_data <= 64'd0;
			v_wr_data <= 64'd0;
			y_valid <= '0;
			c_valid <= '0;
			y_bank <= '0;
			c_bank <= '0;
			for (ti = 0; ti < LINE_SLOTS; ti = ti + 1) begin
				y_line[ti] <= '0;
				c_line[ti] <= '0;
			end
			disp_bank_d1 <= 1'b0;
			disp_bank_d2 <= 1'b0;
			disp_buf_d1 <= 1'b0;
			disp_buf_d2 <= 1'b0;
			has_frame_d1 <= 1'b0;
			has_frame_d2 <= 1'b0;
			swap_pending_d1 <= 1'b0;
			swap_pending_d2 <= 1'b0;
			pending_bank_d1 <= 1'b0;
			pending_bank_d2 <= 1'b0;
			want_y_gray_s1 <= '0;
			want_y_gray_s2 <= '0;
			for (ti = 0; ti < LINE_COUNT; ti = ti + 1)
				desired_y_r[ti] <= '0;
			pending_ready_ddr <= 1'b0;
			pending_bank_ddr <= 1'b0;
			swap_req_t_ddr <= 1'b0;
			poll_div <= 16'd0;
			poll_pending <= 1'b0;
			last_seq <= 32'd0;
			have_seq <= 1'b0;
			doorbell_primed <= 1'b0;
			format_error <= 1'b0;
			stale_db_polls <= '0;
			doorbell_ok <= 1'b0;
			start_d1 <= 1'b0;
			start_d2 <= 1'b0;
			start_seen <= 1'b0;
			bank_sel_d1 <= 1'b0;
			bank_sel_d2 <= 1'b0;
			status_osd_s1 <= 16'd0;
			status_osd_s2 <= 16'd0;
			status_osd_s3 <= 16'd0;
			status_osd_safe <= 16'd0;
			sdram_status_s1 <= 24'd0;
			sdram_status_s2 <= 24'd0;
			sdram_status_s3 <= 24'd0;
			sdram_status_safe <= 24'd0;
			frame_miss_tog_s1 <= 1'b0;
			frame_miss_tog_s2 <= 1'b0;
			frame_miss_tog_seen <= 1'b0;
			frame_underrun_ddr <= 16'd0;
			frame_status_ddr <= 24'd0;
			mbox_seq <= 16'd0;
			mbox_last <= 16'd0;
			mbox_req <= 1'b1;
			mbox_valid <= 1'b0;
			mbox_hb <= 18'd0;
			sdram_mbox_seq <= 8'd0;
			sdram_mbox_last <= 24'd0;
			sdram_mbox_req <= 1'b1;
			sdram_mbox_valid <= 1'b0;
			sdram_mbox_hb <= 18'd0;
			frame_mbox_seq <= 8'd0;
			frame_mbox_last <= 24'd0;
			frame_mbox_req <= 1'b1;
			frame_mbox_valid <= 1'b0;
			frame_mbox_hb <= 18'd0;
			bank_mbox_req <= 1'b1;
			bank_mbox_valid <= 1'b0;
			bank_mbox_hb <= 18'd0;
			bank_mbox_seq <= 8'd0;
			bank_vsync_count <= 16'd0;
			frames_done_d1 <= 16'd0;
			frames_done_d2 <= 16'd0;
			bank_plxd_swap_d <= 1'b0;
			bank_plxd_disp_d <= 1'b0;
			vsync_t_d1 <= 1'b0;
			vsync_t_d2 <= 1'b0;
			vsync_t_seen <= 1'b0;
			cmd_pop <= 1'b0;
			sched_valid <= 1'b0;
			sched_is_y <= 1'b0;
			sched_for_pending <= 1'b0;
			sched_bank <= 1'b0;
			sched_pending_ready <= 1'b0;
			sched_y <= '0;
			sched_cy <= '0;
			sched_idx <= '0;
			imbox_seq <= 16'd0;
			imbox_cmd_seq <= 8'd0;
			fill_qword <= '0;
			burst_left <= '0;
			qwords_remaining <= '0;
			fill_is_chroma <= 1'b0;
			fill_plane_v <= 1'b0;
		end else begin
			if (!DDRAM_BUSY) begin
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
			end
			y_wr <= '0;
			u_wr <= '0;
			v_wr <= '0;
			cmd_pop <= 1'b0;

			disp_bank_d1 <= disp_bank;
			disp_bank_d2 <= disp_bank_d1;
			disp_buf_d1 <= disp_buf;
			disp_buf_d2 <= disp_buf_d1;
			has_frame_d1 <= has_frame;
			has_frame_d2 <= has_frame_d1;
			swap_pending_d1 <= swap_pending;
			swap_pending_d2 <= swap_pending_d1;
			pending_bank_d1 <= pending_bank;
			pending_bank_d2 <= pending_bank_d1;
			frames_done_d1 <= frames_done;
			frames_done_d2 <= frames_done_d1;

			// want_y: Gray-coded 2-FF sync (crossing #13)
			want_y_gray_s1 <= want_y_gray;
			want_y_gray_s2 <= want_y_gray_s1;
			for (ti = 0; ti < LINE_COUNT; ti = ti + 1)
				desired_y_r[ti] <= clamp_ahead(y_gray2bin(want_y_gray_s2), ti, integer'(d_coded_h));

			start_d1 <= start_req;
			start_d2 <= start_d1;
			bank_sel_d1 <= bank_sel;
			bank_sel_d2 <= bank_sel_d1;

			status_osd_s1 <= status_osd_hold;
			status_osd_s2 <= status_osd_s1;
			status_osd_s3 <= status_osd_s2;
			if (status_osd_s2 == status_osd_s3)
				status_osd_safe <= status_osd_s3;

			sdram_status_s1 <= sdram_status_hold;
			sdram_status_s2 <= sdram_status_s1;
			sdram_status_s3 <= sdram_status_s2;
			if (sdram_status_s2 == sdram_status_s3)
				sdram_status_safe <= sdram_status_s3;

			frame_miss_tog_s1 <= frame_miss_toggle;
			frame_miss_tog_s2 <= frame_miss_tog_s1;
			if (frame_miss_tog_s2 != frame_miss_tog_seen) begin
				frame_miss_tog_seen <= frame_miss_tog_s2;
				if (frame_underrun_ddr != 16'hFFFF)
					frame_underrun_ddr <= frame_underrun_ddr + 16'd1;
			end
			frame_status_ddr <= {frame_underrun_ddr, debug_state};

			mbox_hb <= mbox_hb + 18'd1;
			if (!mbox_valid || (status_osd_safe != mbox_last) || (mbox_hb == 18'd0))
				mbox_req <= 1'b1;
			sdram_mbox_hb <= sdram_mbox_hb + 18'd1;
			if (!sdram_mbox_valid || (sdram_status_safe != sdram_mbox_last) || (sdram_mbox_hb == 18'd0))
				sdram_mbox_req <= 1'b1;
			frame_mbox_hb <= frame_mbox_hb + 18'd1;
			if (!frame_mbox_valid || (frame_status_ddr != frame_mbox_last) || (frame_mbox_hb == 18'd0))
				frame_mbox_req <= 1'b1;

			// PLXD bank-release: vsync toggle sync and heartbeat
			vsync_t_d1 <= vsync_toggle;
			vsync_t_d2 <= vsync_t_d1;
			if (vsync_t_d2 != vsync_t_seen) begin
				vsync_t_seen <= vsync_t_d2;
				bank_vsync_count <= bank_vsync_count + 16'd1;
				bank_mbox_req <= 1'b1;
			end
			// Fresher free_mask: republish when swap_pending or disp_bank changes,
			// not only on vsync/heartbeat. Closes the stale-free window that lets
			// ARM overwrite the new display bank under playback-rate presents.
			if ((swap_pending_d2 != bank_plxd_swap_d) || (disp_bank_d2 != bank_plxd_disp_d)) begin
				bank_plxd_swap_d <= swap_pending_d2;
				bank_plxd_disp_d <= disp_bank_d2;
				bank_mbox_req <= 1'b1;
			end
			bank_mbox_hb <= bank_mbox_hb + 18'd1;
			if (!bank_mbox_valid || (bank_mbox_hb == 18'd0))
				bank_mbox_req <= 1'b1;

			if (db_bad_format) begin
				format_error <= 1'b1;
				doorbell_ok <= 1'b0;
				frame_mbox_req <= 1'b1;
			end
			if (db_token_new) begin
				last_seq <= db_token;
				have_seq <= 1'b1;
				format_error <= 1'b0;
			end
			if (db_magic_ok && doorbell_primed && !db_token_new && !db_stale_fallback) begin
				if (stale_db_polls != STALE_DB_POLL_W'(STALE_DB_POLL_MAX))
					stale_db_polls <= stale_db_polls + 1'b1;
			end
			if (db_token_new)
				stale_db_polls <= '0;
			if (db_new_seq) begin
				pending_bank_ddr <= DDRAM_DOUT[63];
				swap_req_t_ddr <= ~swap_req_t_ddr;
				doorbell_ok <= 1'b1;
				stale_db_polls <= '0;
			end
			if (spi_edge_ddr) begin
				start_seen <= start_d2;
				if (!STRICT_YUV_DOORBELL || (have_seq && !format_error)) begin
					pending_bank_ddr <= bank_sel_d2;
					swap_req_t_ddr <= ~swap_req_t_ddr;
				end
			end

			case (state_ddr)
				S_IDLE: begin
					// Product (PENDING_READY_STICKY_PREP=1): once prep lines are
					// complete, keep pending_ready high even while IDLE schedules
					// a *current* refill. Legacy ternary
					//   sched_valid ? (sched_for_pending && sched_pending_ready)
					//               : pending_ready_c
					// clears ready whenever sched_valid && !sched_for_pending —
					// continuous need_y_cur under src_y_line (beam-tracking want_y
					// through VBlank) then misses the 1-cycle vsync swap window and
					// freezes bank0 (silicon 9eb1431a). Do not revive FORCE_TOP.
					if (PENDING_READY_STICKY_PREP) begin
						pending_ready_ddr <= swap_pending_d2 &&
						                     (pending_ready_c ||
						                      (sched_valid && sched_for_pending && sched_pending_ready));
					end else begin
						pending_ready_ddr <= swap_pending_d2 &&
						                     (sched_valid ? (sched_for_pending && sched_pending_ready)
						                                  : pending_ready_c);
					end
					poll_div <= poll_div + 16'd1;
					if (frame_mbox_req && (!frame_mbox_valid || poll_div[7:0] == 8'd224)
					    && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= FRAME_MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {frame_status_ddr, frame_mbox_seq + 8'd1, MAGIC_F};
						DDRAM_WE <= 1'b1;
						frame_mbox_seq <= frame_mbox_seq + 8'd1;
						frame_mbox_last <= frame_status_ddr;
						frame_mbox_valid <= 1'b1;
						frame_mbox_req <= 1'b0;
						state_ddr <= S_WRITE_WAIT;
					end else if (bank_mbox_req && (!bank_mbox_valid || poll_div[7:0] == 8'd160)
					    && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						// PLXD bank-release: tell ARM which bank is safe to write
						// Layout: [63:48] frames_done, [35] swap_pending,
						//   [34] disp_bank, [33:32] free_bank_mask, [31:0] magic
						// frames_done MUST be the real swap counter (not
						// bank_vsync_count). Packing vsync kept PLXD "live" while
						// swaps stuck — ARM stale detector could not fire
						// (playback freeze class on c5382bee). ARM now also
						// gates on free/disp identity; keep ABI honest.
						DDRAM_ADDR <= BANK_MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {frames_done_d2,                       // [63:48] real swaps (CDC)
						              12'd0,                                // [47:36] reserved
						              swap_pending_d2,                      // [35]
						              disp_bank_d2,                         // [34]
						              swap_pending_d2 ? 2'b00 :             // [33:32] free_bank_mask
						                (disp_bank_d2 ? 2'b01 : 2'b10),
						              MAGIC_D};                             // [31:0]
						DDRAM_WE <= 1'b1;
						bank_mbox_seq <= bank_mbox_seq + 8'd1;
						bank_mbox_valid <= 1'b1;
						bank_mbox_req <= 1'b0;
						bank_mbox_hb <= 18'd0;
						state_ddr <= S_WRITE_WAIT;
					end else if (PIPELINE_REFILL_SCHEDULER && sched_valid) begin
						fill_bank <= sched_bank;
						fill_idx <= sched_idx;
						fill_plane_v <= 1'b0;
						fill_qword <= '0;
						sched_valid <= 1'b0;
						if (sched_is_y) begin
							fill_y <= sched_y;
							y_valid[sched_idx] <= 1'b0;
							y_bank[sched_idx] <= sched_bank;
							qwords_remaining <= d_y_fetch_qw[Y_QW_AW:0]; // ddr-domain y fetch
							fill_is_chroma <= 1'b0;
						end else begin
							fill_cy <= sched_cy;
							c_valid[sched_idx] <= 1'b0;
							c_bank[sched_idx] <= sched_bank;
							qwords_remaining <= {{(Y_QW_AW+1-8){1'b0}}, d_c_fetch_qw}; // ddr-domain c fetch
							fill_is_chroma <= 1'b1;
						end
						state_ddr <= S_LINE_ISSUE;
					end else if ((swap_pending_d2 && need_y_prep_c) || (has_frame_d2 && need_y_cur_c)) begin
						if (PIPELINE_REFILL_SCHEDULER) begin
							sched_valid <= 1'b1;
							sched_is_y <= 1'b1;
							sched_for_pending <= swap_pending_d2 && need_y_prep_c;
							sched_bank <= (swap_pending_d2 && need_y_prep_c) ? pending_bank_d2 : disp_bank_d2;
							sched_y <= (swap_pending_d2 && need_y_prep_c) ? target_y_prep_c : target_y_cur_c;
							sched_idx <= (swap_pending_d2 && need_y_prep_c) ? target_y_idx_prep_c : target_y_idx_cur_c;
							sched_pending_ready <= pending_ready_c;
						end else begin
							fill_bank <= (swap_pending_d2 && need_y_prep_c) ? pending_bank_d2 : disp_bank_d2;
							fill_y <= (swap_pending_d2 && need_y_prep_c) ? target_y_prep_c : target_y_cur_c;
							fill_idx <= (swap_pending_d2 && need_y_prep_c) ? target_y_idx_prep_c : target_y_idx_cur_c;
							y_valid[(swap_pending_d2 && need_y_prep_c) ? target_y_idx_prep_c : target_y_idx_cur_c] <= 1'b0;
							y_bank[(swap_pending_d2 && need_y_prep_c) ? target_y_idx_prep_c : target_y_idx_cur_c] <= (swap_pending_d2 && need_y_prep_c) ? pending_bank_d2 : disp_bank_d2;
							fill_is_chroma <= 1'b0;
							fill_plane_v <= 1'b0;
							fill_qword <= '0;
							qwords_remaining <= d_y_fetch_qw[Y_QW_AW:0]; // ddr-domain y fetch
							state_ddr <= S_LINE_ISSUE;
						end
					end else if ((swap_pending_d2 && need_c_prep_c) || (has_frame_d2 && need_c_cur_c)) begin
						if (PIPELINE_REFILL_SCHEDULER) begin
							sched_valid <= 1'b1;
							sched_is_y <= 1'b0;
							sched_for_pending <= swap_pending_d2 && need_c_prep_c;
							sched_bank <= (swap_pending_d2 && need_c_prep_c) ? pending_bank_d2 : disp_bank_d2;
							sched_cy <= (swap_pending_d2 && need_c_prep_c) ? target_c_prep_c : target_c_cur_c;
							sched_idx <= (swap_pending_d2 && need_c_prep_c) ? target_c_idx_prep_c : target_c_idx_cur_c;
							sched_pending_ready <= pending_ready_c;
						end else begin
							fill_bank <= (swap_pending_d2 && need_c_prep_c) ? pending_bank_d2 : disp_bank_d2;
							fill_cy <= (swap_pending_d2 && need_c_prep_c) ? target_c_prep_c : target_c_cur_c;
							fill_idx <= (swap_pending_d2 && need_c_prep_c) ? target_c_idx_prep_c : target_c_idx_cur_c;
							c_valid[(swap_pending_d2 && need_c_prep_c) ? target_c_idx_prep_c : target_c_idx_cur_c] <= 1'b0;
							c_bank[(swap_pending_d2 && need_c_prep_c) ? target_c_idx_prep_c : target_c_idx_cur_c] <= (swap_pending_d2 && need_c_prep_c) ? pending_bank_d2 : disp_bank_d2;
							fill_is_chroma <= 1'b1;
							fill_plane_v <= 1'b0;
							fill_qword <= '0;
							qwords_remaining <= {{(Y_QW_AW+1-8){1'b0}}, d_c_fetch_qw}; // ddr-domain c fetch
							state_ddr <= S_LINE_ISSUE;
						end
					end else if (!poll_pending && poll_div[7:0] == 8'd0 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= DOORBELL_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						poll_pending <= 1'b1;
						state_ddr <= S_POLL_WAIT;
					end else if (!cmd_empty && poll_div[7:0] == 8'd64 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= INPUT_MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {imbox_seq + 16'd1, imbox_cmd_seq + 8'd1, cmd_rdata, MAGIC_I};
						DDRAM_WE <= 1'b1;
						cmd_pop <= 1'b1;
						imbox_seq <= imbox_seq + 16'd1;
						imbox_cmd_seq <= imbox_cmd_seq + 8'd1;
						state_ddr <= S_WRITE_WAIT;
					end else if (mbox_req && poll_div[7:0] == 8'd128 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {mbox_seq + 16'd1, status_osd_safe, MAGIC_S};
						DDRAM_WE <= 1'b1;
						mbox_seq <= mbox_seq + 16'd1;
						mbox_last <= status_osd_safe;
						mbox_valid <= 1'b1;
						mbox_req <= 1'b0;
						state_ddr <= S_WRITE_WAIT;
					end else if (sdram_mbox_req && poll_div[7:0] == 8'd192 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= SDRAM_MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {sdram_status_safe, sdram_mbox_seq + 8'd1, MAGIC_M};
						DDRAM_WE <= 1'b1;
						sdram_mbox_seq <= sdram_mbox_seq + 8'd1;
						sdram_mbox_last <= sdram_status_safe;
						sdram_mbox_valid <= 1'b1;
						sdram_mbox_req <= 1'b0;
						state_ddr <= S_WRITE_WAIT;
					end
				end

				S_LINE_ISSUE: begin
					if (!DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= line_addr;
						DDRAM_BURSTCNT <= burst_this;
						DDRAM_RD <= 1'b1;
						burst_left <= burst_cap;
						state_ddr <= S_LINE_WAIT;
					end
				end

				S_LINE_WAIT: begin
					if (DDRAM_DOUT_READY) begin
						if (fill_is_chroma) begin
							c_wr_addr <= fill_qword[C_QW_AW-1:0];
							if (fill_plane_v) begin
								v_wr_data <= DDRAM_DOUT;
								v_wr[fill_idx] <= 1'b1;
							end else begin
								u_wr_data <= DDRAM_DOUT;
								u_wr[fill_idx] <= 1'b1;
							end
						end else begin
							y_wr_addr <= fill_qword[Y_QW_AW-1:0];
							y_wr_data <= DDRAM_DOUT;
							y_wr[fill_idx] <= 1'b1;
						end
						fill_qword <= fill_qword + 1'b1;
						qwords_remaining <= qwords_remaining - 1'b1;
						burst_left <= burst_left - 1'b1;
						if (qwords_remaining == 1) begin
							if (fill_is_chroma && !fill_plane_v) begin
								fill_plane_v <= 1'b1;
								fill_qword <= '0;
								qwords_remaining <= {{(Y_QW_AW+1-8){1'b0}}, d_c_fetch_qw}; // ddr-domain c fetch
								state_ddr <= S_LINE_ISSUE;
							end else begin
								if (fill_is_chroma) begin
									c_line[fill_idx] <= fill_cy;
									c_bank[fill_idx] <= fill_bank;
									c_valid[fill_idx] <= 1'b1;
								end else begin
									y_line[fill_idx] <= fill_y;
									y_bank[fill_idx] <= fill_bank;
									y_valid[fill_idx] <= 1'b1;
								end
								state_ddr <= S_IDLE;
							end
						end else if (burst_left == 1) begin
							state_ddr <= S_LINE_ISSUE;
						end
					end
				end

				S_POLL_WAIT: begin
					if (DDRAM_DOUT_READY) begin
						doorbell_primed <= 1'b1;
						poll_pending <= 1'b0;
						state_ddr <= S_IDLE;
					end
				end

				S_WRITE_WAIT: begin
					if (!DDRAM_BUSY && !DDRAM_WE)
						state_ddr <= S_IDLE;
				end

				default: state_ddr <= S_IDLE;
			endcase
		end
	end
endmodule

module mplex_hold_lcell (
	input  wire din,
	output wire dout
);
`ifdef VERILATOR
	assign dout = din;
`else
	cyclonev_lcell_comb #(
		.lut_mask(64'hAAAAAAAAAAAAAAAA),
		.dont_touch("on")
	) hold_lcell (
		.dataa(din),
		.datab(1'b0),
		.datac(1'b0),
		.datad(1'b0),
		.datae(1'b0),
		.dataf(1'b0),
		.combout(dout)
	);
`endif
endmodule
