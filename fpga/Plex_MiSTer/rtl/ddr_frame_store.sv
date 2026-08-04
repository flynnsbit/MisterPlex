// HPS-DDR-backed YUV420p frame store.
//
// Reads planar YUV420 from HPS DDR banks into bank-tagged M10K line buffers.
// Legacy defaults match host/libmisterplex/ddr_frame_layout.hpp (624×480).
// Runtime geometry (PLXW / geom_enable) sizes the *fetch* for native content
// up to MAX_CODED 1280×720 (one M10K per luma line). Line RAMs are synthesis-
// sized to the max; active line qwords/pitch come from registers.
//
// geom_enable=0 (reset): bit-exact parameter path (CODED_W/H, stride=CODED_W,
// bank map PHYS_BASE/0x80000/doorbell product).
// geom_enable=1: runtime plane pitch; bank map is CAPACITY-selected:
//   I420 frame_bytes = y_stride*coded_h + 2*(chroma_stride*coded_h/2)
//   usable = HPS_BANK_STRIDE − 0x1000 (doorbell/control page on bank1 tail)
//   if frame_bytes > usable (520192, NOT full 512 KiB) → Option-C
//     (0x30180000 / 0x180000 / 0x3047F000)
//   else → legacy product banks.
// Width alone must NOT select the map: product 960x540 is <1280 wide but
// 777600 B > 520192 B usable and MUST use Option-C (w-mem / parent 2026-08-03).

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
	// Option-C 720p map (parent-verified 0x30180000 / 0x180000 / 0x3047F000).
	// Runtime-selected when geom_enable && I420 payload exceeds legacy bank stride.
	// Default path uses PHYS_* (480p). Do not key Option-C on coded_w alone.
	parameter [31:0] PHYS_BASE_720P = 32'h3018_0000,
	parameter int HPS_BANK_STRIDE_BYTES_720P = 32'h0018_0000,
	parameter [31:0] DOORBELL_PHYS_720P = 32'h3047_F000,
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
	parameter bit SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC = 1'b1,
	// Multi-pixel present (w-clock). Default 1 = bit-identical scalar path.
	// PX_PER_CLK in {1,2,4}. N>1 uses yuv_bt601_npx on the latched beam qword.
	parameter int PX_PER_CLK = 1
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
	// N-wide RGB (lane0 == rd_r/g/b when PX_PER_CLK==1). Safe to leave open.
	output wire [PX_PER_CLK*8-1:0] rd_r_n,
	output wire [PX_PER_CLK*8-1:0] rd_g_n,
	output wire [PX_PER_CLK*8-1:0] rd_b_n,
	output wire [PX_PER_CLK-1:0]   rd_lane_valid_n,
	output wire                    rd_n_valid,

	// Optional multi-pixel handoff (w-clock yuv_bt601_npx). Enabled only when
	// DDR_FRAME_STORE_EXPORT_QWORDS is defined so legacy TBs stay pin-compatible.
`ifdef DDR_FRAME_STORE_EXPORT_QWORDS
	output reg  [63:0] rd_y_qword,
	output reg  [63:0] rd_y_qword_hi,
	output reg         rd_y_hi_valid,
	output reg  [63:0] rd_u_qword,
	output reg  [63:0] rd_v_qword,
	output reg  [10:0] rd_src_x_q,
	output reg         rd_qword_valid,
`endif

	// Runtime bank geometry (PLXW). geom_enable=0 → parameter legacy path.
	// Callers must tie these (product: Plex/present_core; TBs: 0).
	// No port defaults — Verilator was ignoring C++ drivers when defaults existed.
	input  wire        geom_enable = 1'b0,
	input  wire [10:0] rt_coded_w = 11'd0,
	input  wire [10:0] rt_coded_h = 11'd0,
	input  wire [11:0] rt_y_stride = 12'd0,
	input  wire [10:0] rt_chroma_stride = 11'd0,
	input  wire [10:0] rt_display_w = 11'd0,
	input  wire [10:0] rt_display_h = 11'd0,
	input  wire [10:0] rt_present_x = 11'd0,
	input  wire [10:0] rt_present_y = 11'd0,
	input  wire [10:0] rt_crop_left = 11'd0,
	input  wire [10:0] rt_crop_top = 11'd0,

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
	output wire  [7:0] debug_state,
	// B16: geometry transition hold (ascal HDMI_BLACKOUT / local RGB black).
	output reg         geom_hold_black,
	// B16: hollow/silent-legacy after prior live geom (PLXF 0xE3).
	output wire        geom_hollow_fault
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
	// ---- Compile-time bank map (B1) ----------------------------------------
	// Without OPTION_C: LEG_* = module PHYS_BASE/stride/doorbell (480p product).
	// With OPTION_C: LEG_* re-bases to Option-C so geom_enable=0 is still on a
	// capacity-safe map for the 960×540 max tier. Capacity *predicate* always
	// compares against fixed 480p usable (0x7F000), not the active LEG stride —
	// otherwise OPTION_C would make rt_need_optc vacuously false.
	// `ifdef OPTION_C is the compile-time bank path the fit gate requires;
	// FRAME_W=960 QSF alone does not re-base these localparams.
`ifdef OPTION_C
	localparam [28:0] LEG_BASE_W0 = PHYS_BASE_720P[31:3];
	localparam [28:0] LEG_BANK_STRIDE_QWORDS = 29'(HPS_BANK_STRIDE_BYTES_720P / 8);
	localparam [28:0] LEG_BASE_W1 = PHYS_BASE_720P[31:3] + LEG_BANK_STRIDE_QWORDS;
	// Frame doorbell follows Option-C; PLXG bootstrap stays on 0x300FF000 via poller.
	localparam [28:0] LEG_DOORBELL_W = DOORBELL_PHYS_720P[31:3];
`else
	localparam [28:0] LEG_BASE_W0 = PHYS_BASE[31:3];
	localparam [28:0] LEG_BANK_STRIDE_QWORDS = 29'(HPS_BANK_STRIDE_BYTES / 8);
	localparam [28:0] LEG_BASE_W1 = PHYS_BASE[31:3] + LEG_BANK_STRIDE_QWORDS;
	localparam [28:0] LEG_DOORBELL_W = DOORBELL_PHYS[31:3];
`endif
	// Usable payload threshold for capacity select = legacy 480p stride − 4KiB.
	// Fixed (not derived from LEG stride) so OPTION_C re-base cannot hide oversize.
	localparam [28:0] LEG_BANK_USABLE_QWORDS = 29'(32'h0007_F000 / 8); // 520192/8
	localparam [28:0] OPTC_BASE_W0 = PHYS_BASE_720P[31:3];
	localparam [28:0] OPTC_BANK_STRIDE_QWORDS = 29'(HPS_BANK_STRIDE_BYTES_720P / 8);
	localparam [28:0] OPTC_BASE_W1 = PHYS_BASE_720P[31:3] + OPTC_BANK_STRIDE_QWORDS;
	localparam [28:0] OPTC_DOORBELL_W = DOORBELL_PHYS_720P[31:3];
	// Legacy names kept for MAILBOX_* offsets (product control page on 480p doorbell).
	// Runtime fill/poll use eff_*/d_* bank map (LEG vs Option-C).
	localparam [28:0] BASE_W0 = LEG_BASE_W0;
	localparam [28:0] BASE_W1 = LEG_BASE_W1;
	localparam [28:0] DOORBELL_W = LEG_DOORBELL_W;
	localparam [28:0] HPS_BANK_STRIDE_QWORDS = LEG_BANK_STRIDE_QWORDS;
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
	reg        eff_optc_map;
	reg [28:0] eff_base_w0;
	reg [28:0] eff_base_w1;
	reg [28:0] eff_doorbell_w;

	// RAW (pre-clamp) geometry — over-max must REJECT, not clamp-then-accept (rd-duck).
	wire rt_raw_nonzero = (rt_coded_w != 11'd0) && (rt_coded_h != 11'd0) &&
	                      (rt_y_stride != 12'd0) && (rt_chroma_stride != 11'd0);
	wire rt_raw_in_range = (rt_coded_w <= 11'(MAX_CODED_W)) &&
	                       (rt_coded_h <= 11'(MAX_CODED_H)) &&
	                       (rt_y_stride <= 12'(MAX_CODED_W)) &&
	                       (rt_chroma_stride <= 11'(MAX_CODED_W/2));
	// coded_w must be 16-aligned: chroma fetch is coded_w>>4 qwords (= w/2 bytes).
	// 8-aligned-only traps (e.g. 968) pass stride%8 but drop 4 chroma bytes (rd-duck).
	// Height: even only (4:2:0). Display 540 is valid; MB-align is NOT required here.
	wire rt_raw_aligned = (rt_coded_w[3:0] == 4'd0) && !rt_coded_h[0] &&
	                      (rt_y_stride[2:0] == 3'd0) && (rt_chroma_stride[2:0] == 3'd0) &&
	                      (rt_y_stride >= {1'b0, rt_coded_w}) &&
	                      (rt_chroma_stride >= {1'b0, rt_coded_w[10:1]});
	wire rt_raw_ok = rt_raw_nonzero && rt_raw_in_range && rt_raw_aligned;

	// Effective dims only when raw_ok (else unused; legacy path selected).
	wire [10:0] rt_cw_cl = rt_coded_w;
	wire [10:0] rt_ch_cl = rt_coded_h;
	wire [11:0] rt_ys_cl = rt_y_stride;
	wire [10:0] rt_cs_cl = rt_chroma_stride;
	wire [10:0] rt_dw_nz = (rt_display_w == 11'd0) ? rt_cw_cl : rt_display_w;
	wire [10:0] rt_dh_nz = (rt_display_h == 11'd0) ? rt_ch_cl : rt_display_h;

	wire [28:0] rt_y_bytes_qw = ({17'd0, rt_ys_cl} * {18'd0, rt_ch_cl}) >> 3;
	wire [28:0] rt_c_bytes_qw = ({18'd0, rt_cs_cl} * {19'd0, rt_ch_cl[10:1]}) >> 3;
	// Exact-byte I420 payload from RAW dims (no silent clamp into plane math).
	wire [31:0] rt_payload_bytes =
		({20'd0, rt_ys_cl} * {20'd0, rt_ch_cl}) +
		({21'd0, rt_cs_cl} * {21'd0, rt_ch_cl});
	// Capacity threshold = legacy 480p usable (stride 0x80000 − 0x1000). Not the
	// active LEG stride — under OPTION_C LEG is already Option-C sized.
	localparam [31:0] LEG_BANK_USABLE_BYTES = 32'h0007_F000; // 520192
	wire rt_need_optc = rt_raw_ok && (rt_payload_bytes > LEG_BANK_USABLE_BYTES);

	// w-mem L3: bank capacity guards (static elab-fatal + runtime sticky).
	// Instantiated before geom always so reject can OR into geom_reject_r.
	wire        bank_cap_ovf_now;
	wire        bank_cap_reject;
	wire [31:0] bank_cap_frame_bytes;
	wire [31:0] bank_cap_usable_bytes;
	ddr_bank_geom_guard #(
		.CODED_W(CODED_W),
		.CODED_H(CODED_H),
		.Y_STRIDE(CODED_W),
		.C_STRIDE(CODED_W / 2),
		.BANK_STRIDE(HPS_BANK_STRIDE_BYTES),
		.DOORBELL_PAGE(32'h1000),
		.FATAL_ON_STATIC_OVERFLOW(1'b1)
	) u_bank_cap_static (
		.clk(clk),
		.reset(reset),
		.rt_frame_bytes(32'd0),
		.rt_bank_stride(32'd0),
		.check_en(1'b1),
		.frame_bytes(bank_cap_frame_bytes),
		.usable_bytes(bank_cap_usable_bytes),
		.overflow_now(bank_cap_ovf_now),
		.overflow_reject(bank_cap_reject)
	);
	// Runtime uses active map stride (Option-C when capacity needs it).
	// eff_optc_map is registered below; use combinational need for check stride.
	wire [31:0] rt_check_stride =
		rt_need_optc ? 32'(HPS_BANK_STRIDE_BYTES_720P) : 32'(HPS_BANK_STRIDE_BYTES);
	wire bank_cap_rt_ovf_now;
	wire bank_cap_rt_reject;
	ddr_bank_geom_guard #(
		.CODED_W(CODED_W),
		.CODED_H(CODED_H),
		.Y_STRIDE(CODED_W),
		.C_STRIDE(CODED_W / 2),
		.BANK_STRIDE(HPS_BANK_STRIDE_BYTES),
		.DOORBELL_PAGE(32'h1000),
		.FATAL_ON_STATIC_OVERFLOW(1'b0)
	) u_bank_cap_runtime (
		.clk(clk),
		.reset(reset),
		.rt_frame_bytes(rt_payload_bytes),
		.rt_bank_stride(rt_check_stride),
		.check_en(geom_enable & rt_raw_ok),
		.frame_bytes(),
		.usable_bytes(),
		.overflow_now(bank_cap_rt_ovf_now),
		.overflow_reject(bank_cap_rt_reject)
	);
	wire bank_cap_any = bank_cap_reject | bank_cap_rt_reject;

	// FAULT: ignore geom_enable (always legacy pitch) — red twin for runtime-stride gate.
`ifdef DDR_FRAME_STORE_FAULT_IGNORE_GEOM
	wire geom_enable_eff = 1'b0;
`else
	// Reject malformed / over-max raw geometry — no clamp-then-accept.
	wire geom_enable_eff = geom_enable & rt_raw_ok;
`endif
	// Loud reject (parent PMS AR-fit): geom requested but raw fails → sticky fault.
	// Without this, !geom_enable_eff silently reloads LEGACY 624×480 and scans a
	// host native buffer as the wrong pitch (shear). Prefer black + PLXF 0xE2.
	// FAULT twin: silent fallthrough (no sticky, no 0xE2) — red REPRO for loud path.
`ifdef DDR_FRAME_STORE_FAULT_SILENT_GEOM_REJECT
	wire geom_reject_now = 1'b0;
`else
	wire geom_reject_now = geom_enable & ~rt_raw_ok;
`endif
	reg  geom_reject_r;

	always @(posedge clk) begin
		if (reset) begin
			geom_en_r      <= 1'b0;
			geom_reject_r  <= 1'b0;
			// bank_cap sticky cleared via same reset path
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
			eff_optc_map   <= 1'b0;
			eff_base_w0    <= LEG_BASE_W0;
			eff_base_w1    <= LEG_BASE_W1;
			eff_doorbell_w <= LEG_DOORBELL_W;
		end else if (!geom_enable_eff) begin
			geom_en_r      <= 1'b0;
			// Sticky reject while host still asserts geom_enable with bad raw;
			// clear only when geom is off (mode exit) — not on silent legacy fallthrough.
			// bank_cap_any: LOUD bank overflow (w-mem) — never silent fallthrough.
			if (geom_reject_now || bank_cap_any)
				geom_reject_r <= 1'b1;
			else if (!geom_enable && !bank_cap_any)
				geom_reject_r <= 1'b0;
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
			eff_optc_map   <= 1'b0;
			eff_base_w0    <= LEG_BASE_W0;
			eff_base_w1    <= LEG_BASE_W1;
			eff_doorbell_w <= LEG_DOORBELL_W;
		end else begin
			geom_en_r      <= 1'b1;
			// Good geom clears sticky unless bank capacity still rejects.
			geom_reject_r  <= bank_cap_any ? 1'b1 : 1'b0;
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
			eff_y_fetch_qw <= 9'(rt_cw_cl[10:3]); // coded_w/8  (w%16==0 ⇒ exact)
			eff_c_fetch_qw <= 8'(rt_cw_cl[10:4]); // coded_w/16 (chroma bytes = w/2)
			eff_y_pitch_qw <= 9'(rt_ys_cl[11:3]); // stride/8
			eff_c_pitch_qw <= 8'(rt_cs_cl[10:3]);
			eff_u_base_qw  <= rt_y_bytes_qw;
			eff_v_base_qw  <= rt_y_bytes_qw + rt_c_bytes_qw;
			// Option-C when exact I420 payload > legacy usable (stride−4KiB).
			// NOT full stride, NOT coded_w>=1280. 720x482=520560→Option-C;
			// 960x540=777600→Option-C; 624x480 stays legacy. Unaligned rejected above.
`ifdef DDR_FRAME_STORE_FAULT_FORCE_LEGACY_BANK_MAP
			eff_optc_map   <= 1'b0;
			eff_base_w0    <= LEG_BASE_W0;
			eff_base_w1    <= LEG_BASE_W1;
			eff_doorbell_w <= LEG_DOORBELL_W;
`else
			if (rt_need_optc) begin
				eff_optc_map   <= 1'b1;
				eff_base_w0    <= OPTC_BASE_W0;
				eff_base_w1    <= OPTC_BASE_W1;
				eff_doorbell_w <= OPTC_DOORBELL_W;
			end else begin
				eff_optc_map   <= 1'b0;
				eff_base_w0    <= LEG_BASE_W0;
				eff_base_w1    <= LEG_BASE_W1;
				eff_doorbell_w <= LEG_DOORBELL_W;
			end
`endif
		end
	end

	// ---- B16: atomic geom epoch, hold-black, hollow loud-reject --------------------
	// Layout change (eff_* / geom_en_r) bumps geom_epoch_r, asserts geom_hold_black,
	// and pulses geom_inv_tog for clk_ddr line-cache invalidate + fill abort.
	// Epoch is also tagged on each line fill; video hits require epoch match so a
	// stale valid bit under a new pitch cannot resolve (counting oracles stay green
	// on mixed frames otherwise).
	reg  [3:0] geom_epoch_r;
	reg        geom_inv_tog;
	reg        geom_hollow_r;
	reg        had_geom_r;
	reg  [1:0] black_vs_left;
	reg        geom_en_r_d;
	reg [10:0] eff_cw_d, eff_ch_d;
	reg [11:0] eff_ys_d;
	reg [10:0] eff_cs_d;
	reg        eff_optc_d;

	wire geom_layout_chg =
		(geom_en_r != geom_en_r_d) ||
		(eff_coded_w != eff_cw_d) ||
		(eff_coded_h != eff_ch_d) ||
		(eff_y_stride != eff_ys_d) ||
		(eff_c_stride != eff_cs_d) ||
		(eff_optc_map != eff_optc_d);

	assign geom_hollow_fault = geom_hollow_r;

	always @(posedge clk) begin
		if (reset) begin
			geom_epoch_r    <= 4'd0;
			geom_inv_tog    <= 1'b0;
			geom_hold_black <= 1'b0;
			geom_hollow_r   <= 1'b0;
			had_geom_r      <= 1'b0;
			black_vs_left   <= 2'd0;
			geom_en_r_d     <= 1'b0;
			eff_cw_d        <= 11'(CODED_W);
			eff_ch_d        <= 11'(CODED_H);
			eff_ys_d        <= 12'(CODED_W);
			eff_cs_d        <= 11'(CODED_W/2);
			eff_optc_d      <= 1'b0;
		end else begin
			if (geom_en_r)
				had_geom_r <= 1'b1;
`ifdef DDR_FRAME_STORE_FAULT_SILENT_HOLLOW
			// red twin: never raise hollow
			geom_hollow_r <= 1'b0;
`else
			// Loud when prior live geom is lost while a frame is on-screen and
			// not already in geom_reject — silent legacy is the defect class.
			if (had_geom_r && !geom_en_r && !geom_reject_r && has_frame)
				geom_hollow_r <= 1'b1;
			else if (geom_en_r)
				geom_hollow_r <= 1'b0;
`endif
			if (geom_layout_chg) begin
				geom_epoch_r    <= geom_epoch_r + 4'd1;
				geom_inv_tog    <= ~geom_inv_tog;
				geom_hold_black <= 1'b1;
				// Hold black across the transition frame and the first full new
				// frame start (vsync edges). Same-size SAR still needs this —
				// ascal swblack is size-only.
				black_vs_left   <= 2'd2;
			end
			geom_en_r_d <= geom_en_r;
			eff_cw_d    <= eff_coded_w;
			eff_ch_d    <= eff_coded_h;
			eff_ys_d    <= eff_y_stride;
			eff_cs_d    <= eff_c_stride;
			eff_optc_d  <= eff_optc_map;

			if (vsync_pulse && geom_hold_black) begin
				if (black_vs_left <= 2'd1) begin
					black_vs_left   <= 2'd0;
					geom_hold_black <= 1'b0;
				end else begin
					black_vs_left <= black_vs_left - 2'd1;
				end
			end
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
	// PLXF frame-debug: geom_enable=1 but rt_raw_ok=0 (unaligned/over-max/zero).
	// Was silent legacy fallback → sheared picture. Now sticky + black + 0xE2.
	localparam [7:0] DEBUG_GEOM_REJECT = 8'hE2;
	// PLXF: geom was live then dropped → silent legacy fallback (hollow / missing commit).
	localparam [7:0] DEBUG_GEOM_HOLLOW = 8'hE3;

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
	wire [63:0] y_q_hi [0:LINE_SLOTS-1];
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
	// Next Y qword for multi-pixel lanes that cross an 8-byte boundary (w-scaler
	// dual-port + w-clock yuv_bt601_npx.y_qword_hi). Beam x0%PPC==0 on 1280 DE
	// avoids active straddle for PPC in {2,4}; hi remains the safety net.
	wire [Y_QW_AW-1:0] y_rd_addr_hi = y_rd_addr + Y_QW_AW'(1'b1);
	wire [C_QW_AW-1:0] c_rd_addr = src_x[CODED_X_W-1:4];

	genvar li;
	generate
		for (li = 0; li < LINE_SLOTS; li = li + 1) begin : gen_line
			// Physical WIDTH = max line; active fetch length is eff_*_fetch_qw.
			// Y: DUAL_RD=1 for qword-straddle (y_rd_addr_hi) — 2× M10K per slot.
			// U/V: single-port (DUAL_RD=0); ports tied for module interface parity.
			line_buf_ram #(
				.WIDTH(Y_LINE_QWORDS_MAX), .AW(Y_QW_AW), .DATA_W(64), .DUAL_RD(1'b1)
			) yram (
				.wr_clk(clk_ddr), .wr_en(y_wr[li]), .wr_addr(y_wr_addr), .wr_data(y_wr_data),
				.rd_clk(clk), .rd_addr(y_rd_addr), .rd_data(y_q[li]),
				.rd_addr_b(y_rd_addr_hi), .rd_data_b(y_q_hi[li])
			);
			line_buf_ram #(
				.WIDTH(C_LINE_QWORDS_MAX), .AW(C_QW_AW), .DATA_W(64), .DUAL_RD(1'b0)
			) uram (
				.wr_clk(clk_ddr), .wr_en(u_wr[li]), .wr_addr(c_wr_addr), .wr_data(u_wr_data),
				.rd_clk(clk), .rd_addr(c_rd_addr), .rd_data(u_q[li]),
				.rd_addr_b({C_QW_AW{1'b0}}), .rd_data_b()
			);
			line_buf_ram #(
				.WIDTH(C_LINE_QWORDS_MAX), .AW(C_QW_AW), .DATA_W(64), .DUAL_RD(1'b0)
			) vram (
				.wr_clk(clk_ddr), .wr_en(v_wr[li]), .wr_addr(c_wr_addr), .wr_data(v_wr_data),
				.rd_clk(clk), .rd_addr(c_rd_addr), .rd_data(v_q[li]),
				.rd_addr_b({C_QW_AW{1'b0}}), .rd_data_b()
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
	reg [3:0] y_epoch_v1 [0:LINE_SLOTS-1];
	reg [3:0] y_epoch_v2 [0:LINE_SLOTS-1];
	reg [3:0] c_epoch_v1 [0:LINE_SLOTS-1];
	reg [3:0] c_epoch_v2 [0:LINE_SLOTS-1];
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
	reg [10:0] src_x_d;  // aligns with y_sel_r (one beam cycle)
	// N-pixel snapshot of beam qwords (aligned to scalar RGB commit cycle).
	reg [63:0] npx_y_q_r, npx_y_q_hi_r, npx_u_q_r, npx_v_q_r;
	reg [CODED_X_W-1:0] npx_src_x_r;
	reg npx_commit_r;
	reg npx_y_hi_valid_r;
	reg [CODED_X_W-1:0] src_x_r;

	integer vi;
	reg y_hit_now, c_hit_now;
	reg [SLOT_W-1:0] y_hit_idx_now, c_hit_idx_now;
	reg [63:0] selected_y_q, selected_y_q_hi, selected_u_q, selected_v_q;
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
		selected_y_q_hi = 64'd0;
		selected_u_q = 64'd0;
		selected_v_q = 64'd0;
		for (vi = 0; vi < LINE_COUNT; vi = vi + 1) begin
			video_slot = (disp_buf ? SECOND_SET_BASE : '0) + vi[SLOT_W-1:0];
			// Match beam line via pref_y (product: src_y_line; thrash control: src_y).
			if (y_valid_v2[video_slot] && (y_bank_v2[video_slot] == disp_bank)
			    && (y_line_v2[video_slot] == Y_W'(pref_y))
			    && (y_epoch_v2[video_slot] == geom_epoch_r) && !y_hit_now) begin
				y_hit_now = 1'b1;
				y_hit_idx_now = video_slot;
			end
			if (c_valid_v2[video_slot] && (c_bank_v2[video_slot] == disp_bank)
			    && (c_line_v2[video_slot] == (Y_W-1)'(rd_cy))
			    && (c_epoch_v2[video_slot] == geom_epoch_r) && !c_hit_now) begin
				c_hit_now = 1'b1;
				c_hit_idx_now = video_slot;
			end
			if (y_hit_idx_r == video_slot) begin
				selected_y_q = y_q[video_slot];
				selected_y_q_hi = y_q_hi[video_slot];
			end
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
`ifdef DDR_FRAME_STORE_EXPORT_QWORDS
			rd_y_qword <= 64'd0;
			rd_y_qword_hi <= 64'd0;
			rd_y_hi_valid <= 1'b0;
			rd_u_qword <= 64'd0;
			rd_v_qword <= 64'd0;
			rd_src_x_q <= 11'd0;
			rd_qword_valid <= 1'b0;
`endif
			src_x_d <= 11'd0;
			npx_y_q_r <= 64'd0;
			npx_y_q_hi_r <= 64'd0;
			npx_u_q_r <= 64'd0;
			npx_v_q_r <= 64'd0;
			npx_src_x_r <= '0;
			npx_commit_r <= 1'b0;
			npx_y_hi_valid_r <= 1'b0;
			src_x_r <= '0;
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
				y_epoch_v1[vi] <= y_epoch[vi];
				y_epoch_v2[vi] <= y_epoch_v1[vi];
				c_epoch_v1[vi] <= c_epoch[vi];
				c_epoch_v2[vi] <= c_epoch_v1[vi];
			end
			// B16: on layout change, drop video-side valids immediately (no 2-beat stale hit).
			if (geom_layout_chg) begin
				y_valid_v1 <= '0;
				y_valid_v2 <= '0;
				c_valid_v1 <= '0;
				c_valid_v2 <= '0;
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
			// Delay src_x one cycle to pair with y_sel_r / selected_* (hit_idx_r).
			src_x_d <= src_x[10:0];
`ifdef DDR_FRAME_STORE_EXPORT_QWORDS
			// Export at the YUV-calc stage (matches yuv_bt601_npx inputs).
			// y_qword_hi is the next 8 Y samples when lanes straddle a qword
			// boundary (src_x_d[2:0] near 7, N>1). Single-pixel path ignores hi.
			rd_y_qword <= selected_y_q;
			rd_y_qword_hi <= selected_y_q_hi;
			// Valid when next qword index is inside the max linebuf (not past end).
			rd_y_hi_valid <= rd_active_r && rd_visible_r && has_frame && y_hit_r && c_hit_r
			                 && (src_x_d[10:3] != 8'hFF)
			                 && ({1'b0, src_x_d[10:3]} + 9'd1 < 9'(Y_LINE_QWORDS_MAX));
			rd_u_qword <= selected_u_q;
			rd_v_qword <= selected_v_q;
			rd_src_x_q <= src_x_d;
			rd_qword_valid <= rd_active_r && rd_visible_r && has_frame && y_hit_r && c_hit_r;
`endif
			miss_d <= rd_miss_now;
			if (miss_d && underrun_count != 16'hFFFF) begin
				underrun_count <= underrun_count + 16'd1;
				frame_miss_toggle <= ~frame_miss_toggle;
			end

			// geom_reject / B16 hold-black / hollow: force black (no mixed-pitch scan).
			if (geom_reject_r || geom_hold_black || geom_hollow_r) begin
				rd_r <= 8'd0;
				rd_g <= 8'd0;
				rd_b <= 8'd0;
				npx_commit_r <= 1'b0;
			end else if ((rd_active_d || !rd_active) && rd_visible_d && has_frame && !miss_d && y_hit_r && c_hit_r) begin
				rd_r <= sat8(r_calc);
				rd_g <= sat8(g_calc);
				rd_b <= sat8(b_calc);
				npx_y_q_r <= selected_y_q;
				npx_y_q_hi_r <= selected_y_q_hi;
				npx_y_hi_valid_r <= ({1'b0, src_x_d[10:3]} + 9'd1 < 9'(Y_LINE_QWORDS_MAX));
				npx_u_q_r <= selected_u_q;
				npx_v_q_r <= selected_v_q;
				npx_src_x_r <= CODED_X_W'(src_x_d);
				src_x_r <= CODED_X_W'(src_x_d);
				npx_commit_r <= 1'b1;
			end else if (!has_frame || !rd_visible_d || miss_d) begin
				rd_r <= 8'd0;
				rd_g <= 8'd0;
				rd_b <= 8'd0;
				npx_commit_r <= 1'b0;
			end else begin
				npx_commit_r <= 1'b0;
			end
		end
	end

	// --- N-wide RGB ports (w-clock multi-pixel / w-mem PPC=2 feed) -------------
	generate
		if (PX_PER_CLK == 1) begin : gen_rd_npx_scalar
			assign rd_r_n = rd_r;
			assign rd_g_n = rd_g;
			assign rd_b_n = rd_b;
			assign rd_lane_valid_n = npx_commit_r ? 1'b1 : 1'b0;
			assign rd_n_valid = npx_commit_r;
		end else begin : gen_rd_npx_wide
			wire npx_out_valid;
			wire [PX_PER_CLK*8-1:0] npx_r, npx_g, npx_b;
			wire [PX_PER_CLK-1:0] npx_lv;
			yuv_bt601_npx #(
				.PX_PER_CLK(PX_PER_CLK),
				.X_W(CODED_X_W)
			) u_yuv_npx (
				.clk(clk),
				.reset(reset),
				.in_valid(npx_commit_r),
				.src_x0(npx_src_x_r),
				.y_qword(npx_y_q_r),
				.u_qword(npx_u_q_r),
				.v_qword(npx_v_q_r),
				.y_qword_hi(npx_y_q_hi_r),
				.y_hi_valid(npx_y_hi_valid_r),
				.out_valid(npx_out_valid),
				.out_r(npx_r),
				.out_g(npx_g),
				.out_b(npx_b),
				.out_lane_valid(npx_lv)
			);
			assign rd_r_n = npx_r;
			assign rd_g_n = npx_g;
			assign rd_b_n = npx_b;
			assign rd_lane_valid_n = npx_lv;
			assign rd_n_valid = npx_out_valid;
		end
	endgenerate

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
	// B16: geom epoch tag per line slot (invalidates stale pitch under same bank/line).
	reg [3:0] y_epoch [0:LINE_SLOTS-1];
	reg [3:0] c_epoch [0:LINE_SLOTS-1];
	reg [3:0] d_geom_epoch, d_geom_epoch_m;
	reg        d_inv_s1, d_inv_s2, d_inv_seen;
	wire       d_geom_invalidate = (d_inv_s2 != d_inv_seen);
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
				    && (y_line[cur_base_idx + tj[SLOT_W-1:0]] == desired_y) && (y_epoch[cur_base_idx + tj[SLOT_W-1:0]] == d_geom_epoch))
					found_line = 1'b1;
			end
			if (!found_line && !need_y_cur_c) begin
				need_y_cur_c = 1'b1;
				target_y_cur_c = desired_y;
			end

			found_line = 1'b0;
			for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
				if (c_valid[cur_base_idx + tj[SLOT_W-1:0]] && (c_bank[cur_base_idx + tj[SLOT_W-1:0]] == disp_bank_d2)
				    && (c_line[cur_base_idx + tj[SLOT_W-1:0]] == desired_c) && (c_epoch[cur_base_idx + tj[SLOT_W-1:0]] == d_geom_epoch))
					found_line = 1'b1;
			end
			if (!found_line && !need_c_cur_c) begin
				need_c_cur_c = 1'b1;
				target_c_cur_c = desired_c;
			end

			found_line = 1'b0;
			for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
				if (y_valid[prep_base_idx + tj[SLOT_W-1:0]] && (y_bank[prep_base_idx + tj[SLOT_W-1:0]] == pending_bank_d2)
				    && (y_line[prep_base_idx + tj[SLOT_W-1:0]] == ti[Y_W-1:0]) && (y_epoch[prep_base_idx + tj[SLOT_W-1:0]] == d_geom_epoch))
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
				    && (c_line[prep_base_idx + tj[SLOT_W-1:0]] == ti[Y_W-1:1]) && (c_epoch[prep_base_idx + tj[SLOT_W-1:0]] == d_geom_epoch))
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
				    && (y_line[cur_base_idx + tj[SLOT_W-1:0]] == desired_y_r[tk]) && (y_epoch[cur_base_idx + tj[SLOT_W-1:0]] == d_geom_epoch))
					slot_keep = 1'b1;
			end
			if ((!y_valid[cur_base_idx + tj[SLOT_W-1:0]] || !slot_keep) && !found_slot_y_cur) begin
				found_slot_y_cur = 1'b1;
				target_y_idx_cur_c = cur_base_idx + tj[SLOT_W-1:0];
			end

			slot_keep = 1'b0;
			for (tk = 0; tk < LINE_COUNT; tk = tk + 1) begin
				if (c_valid[cur_base_idx + tj[SLOT_W-1:0]] && (c_bank[cur_base_idx + tj[SLOT_W-1:0]] == disp_bank_d2)
				    && (c_line[cur_base_idx + tj[SLOT_W-1:0]] == desired_y_r[tk][Y_W-1:1]) && (c_epoch[cur_base_idx + tj[SLOT_W-1:0]] == d_geom_epoch))
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
					    && (y_line[prep_base_idx + tj[SLOT_W-1:0]] == tk[Y_W-1:0]) && (y_epoch[prep_base_idx + tj[SLOT_W-1:0]] == d_geom_epoch))
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
					    && (c_line[prep_base_idx + tj[SLOT_W-1:0]] == tk[Y_W-1:1]) && (c_epoch[prep_base_idx + tj[SLOT_W-1:0]] == d_geom_epoch))
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
	reg [28:0] d_base_w0, d_base_w1, d_doorbell_w;
	reg [8:0]  d_y_fetch_qw_m, d_y_pitch_qw_m;
	reg [7:0]  d_c_fetch_qw_m, d_c_pitch_qw_m;
	reg [28:0] d_u_base_qw_m, d_v_base_qw_m;
	reg [10:0] d_coded_h_m;
	reg [28:0] d_base_w0_m, d_base_w1_m, d_doorbell_w_m;
	always @(posedge clk_ddr) begin
		if (reset_ddr) begin
			d_y_fetch_qw_m <= 9'(Y_LINE_QWORDS);
			d_c_fetch_qw_m <= 8'(C_LINE_QWORDS);
			d_y_pitch_qw_m <= 9'(Y_LINE_QWORDS);
			d_c_pitch_qw_m <= 8'(C_LINE_QWORDS);
			d_u_base_qw_m  <= LEG_U_PLANE_BASE;
			d_v_base_qw_m  <= LEG_V_PLANE_BASE;
			d_coded_h_m    <= 11'(CODED_H);
			d_base_w0_m    <= LEG_BASE_W0;
			d_base_w1_m    <= LEG_BASE_W1;
			d_doorbell_w_m <= LEG_DOORBELL_W;
			d_y_fetch_qw   <= 9'(Y_LINE_QWORDS);
			d_c_fetch_qw   <= 8'(C_LINE_QWORDS);
			d_y_pitch_qw   <= 9'(Y_LINE_QWORDS);
			d_c_pitch_qw   <= 8'(C_LINE_QWORDS);
			d_u_base_qw    <= LEG_U_PLANE_BASE;
			d_v_base_qw    <= LEG_V_PLANE_BASE;
			d_coded_h      <= 11'(CODED_H);
			d_base_w0      <= LEG_BASE_W0;
			d_base_w1      <= LEG_BASE_W1;
			d_doorbell_w   <= LEG_DOORBELL_W;
			d_geom_epoch_m <= 4'd0;
			d_geom_epoch   <= 4'd0;
			d_inv_s1       <= 1'b0;
			d_inv_s2       <= 1'b0;
		end else begin
			d_y_fetch_qw_m <= eff_y_fetch_qw;
			d_c_fetch_qw_m <= eff_c_fetch_qw;
			d_y_pitch_qw_m <= eff_y_pitch_qw;
			d_c_pitch_qw_m <= eff_c_pitch_qw;
			d_u_base_qw_m  <= eff_u_base_qw;
			d_v_base_qw_m  <= eff_v_base_qw;
			d_coded_h_m    <= eff_coded_h;
			d_base_w0_m    <= eff_base_w0;
			d_base_w1_m    <= eff_base_w1;
			d_doorbell_w_m <= eff_doorbell_w;
			d_y_fetch_qw   <= d_y_fetch_qw_m;
			d_c_fetch_qw   <= d_c_fetch_qw_m;
			d_y_pitch_qw   <= d_y_pitch_qw_m;
			d_c_pitch_qw   <= d_c_pitch_qw_m;
			d_u_base_qw    <= d_u_base_qw_m;
			d_v_base_qw    <= d_v_base_qw_m;
			d_coded_h      <= d_coded_h_m;
			d_base_w0      <= d_base_w0_m;
			d_base_w1      <= d_base_w1_m;
			d_doorbell_w   <= d_doorbell_w_m;
			d_geom_epoch_m <= geom_epoch_r;
			d_geom_epoch   <= d_geom_epoch_m;
			d_inv_s1       <= geom_inv_tog;
			d_inv_s2       <= d_inv_s1;
		end
	end

	// Runtime bank map: legacy 0x30000000 or Option-C 0x30180000.
	wire [28:0] fill_bank_base = fill_bank ? d_base_w1 : d_base_w0;
	// Control page is doorbell-relative (0x100..0x128 bytes → +0x20..+0x25 qwords).
	wire [28:0] poll_doorbell_w = d_doorbell_w;
	wire [28:0] poll_mailbox_w  = d_doorbell_w + 29'h20; // +0x100
	wire [28:0] poll_imbox_w    = d_doorbell_w + 29'h21; // +0x108
	wire [28:0] poll_sdram_w    = d_doorbell_w + 29'h22; // +0x110
	wire [28:0] poll_frame_w    = d_doorbell_w + 29'h23; // +0x118
	wire [28:0] poll_bank_w     = d_doorbell_w + 29'h25; // +0x128 PLXD
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

	// geom_reject_r (clk) → 2FF → clk_ddr for PLXF debug_state.
	reg geom_reject_s1, geom_reject_s2;
	always @(posedge clk_ddr) begin
		if (reset_ddr) begin
			geom_reject_s1 <= 1'b0;
			geom_reject_s2 <= 1'b0;
		end else begin
			geom_reject_s1 <= geom_reject_r;
			geom_reject_s2 <= geom_reject_s1;
		end
	end
	// hollow CDC
	reg geom_hollow_s1, geom_hollow_s2;
	always @(posedge clk_ddr) begin
		if (reset_ddr) begin
			geom_hollow_s1 <= 1'b0;
			geom_hollow_s2 <= 1'b0;
		end else begin
			geom_hollow_s1 <= geom_hollow_r;
			geom_hollow_s2 <= geom_hollow_s1;
		end
	end
	assign debug_state = format_error ? DEBUG_FORMAT_ERROR :
	                     (geom_reject_s2 ? DEBUG_GEOM_REJECT :
	                     (geom_hollow_s2 ? DEBUG_GEOM_HOLLOW :
	                      {LINE_COUNT[2:0], |y_valid, state_ddr}));

	always @(posedge clk_ddr) begin
		if (reset_ddr) begin
			state_ddr <= S_IDLE;
			d_inv_seen <= 1'b0;
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

			// B16: layout invalidate — drop line tags, abort in-flight DDR line fills.
			if (d_geom_invalidate) begin
				d_inv_seen <= d_inv_s2;
				y_valid <= '0;
				c_valid <= '0;
				sched_valid <= 1'b0;
				poll_pending <= 1'b0;
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
				state_ddr <= S_IDLE;
			end
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
						DDRAM_ADDR <= poll_frame_w;
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
						DDRAM_ADDR <= poll_bank_w;
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
						DDRAM_ADDR <= poll_doorbell_w;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						poll_pending <= 1'b1;
						state_ddr <= S_POLL_WAIT;
					end else if (!cmd_empty && poll_div[7:0] == 8'd64 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= poll_imbox_w;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {imbox_seq + 16'd1, imbox_cmd_seq + 8'd1, cmd_rdata, MAGIC_I};
						DDRAM_WE <= 1'b1;
						cmd_pop <= 1'b1;
						imbox_seq <= imbox_seq + 16'd1;
						imbox_cmd_seq <= imbox_cmd_seq + 8'd1;
						state_ddr <= S_WRITE_WAIT;
					end else if (mbox_req && poll_div[7:0] == 8'd128 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= poll_mailbox_w;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {mbox_seq + 16'd1, status_osd_safe, MAGIC_S};
						DDRAM_WE <= 1'b1;
						mbox_seq <= mbox_seq + 16'd1;
						mbox_last <= status_osd_safe;
						mbox_valid <= 1'b1;
						mbox_req <= 1'b0;
						state_ddr <= S_WRITE_WAIT;
					end else if (sdram_mbox_req && poll_div[7:0] == 8'd192 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= poll_sdram_w;
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
									c_epoch[fill_idx] <= d_geom_epoch;
									c_valid[fill_idx] <= 1'b1;
								end else begin
									y_line[fill_idx] <= fill_y;
									y_bank[fill_idx] <= fill_bank;
									y_epoch[fill_idx] <= d_geom_epoch;
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
