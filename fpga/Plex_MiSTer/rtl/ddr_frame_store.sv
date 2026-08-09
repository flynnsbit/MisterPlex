// HPS-DDR-backed YUV420p frame store.
//
// The ARM writes planar YUV420 frames into two HPS DDR banks using the layout
// from host/libmisterplex/ddr_frame_layout.hpp. The FPGA reads Y, U, and V
// source lines directly from HPS DDR into bank-tagged M10K line buffers.

module ddr_frame_store #(
	parameter int FRAME_W = 1280,
	parameter int FRAME_H = 720,
	parameter int FRAME_STRIDE = FRAME_W,
	parameter int CODED_W = FRAME_W,
	parameter int CODED_H = FRAME_H,
	parameter int DISPLAY_W = FRAME_W,
	parameter int DISPLAY_H = FRAME_H,
	parameter int CROP_LEFT = 0,
	parameter int CROP_TOP = 0,
	parameter int PRESENT_X = 0,
	parameter int PRESENT_Y = 0,
	parameter int LINE_COUNT = 8,
	parameter [31:0] PHYS_BASE = 32'h3000_0000,
	parameter int HPS_BANK_STRIDE_BYTES = 1572864,
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
	parameter bit SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC = 1'b1,
	// Multi-pixel present path (default 1 = legacy scalar RGB). PPC in {1,2,4}.
	// Even rd_x required for PPC>1 so a group stays inside one Y qword (no dual-port).
	parameter int PX_PER_CLK = 1,
	// Product default 0: fill_bank_base via ddr_frame_base_mux.
	// DYN_BASE_EN=1 future w-mem dyn base ABI; dyn_* tied off here.
	parameter bit DYN_BASE_EN = 1'b0,
	// DIAG-only tag RCA (I1 miss composition + I2 half occupancy). Default 0 =
	// product-identical PLXF pack. DIAG_TAG_RCA=1 repacks PLXF[63:40]; MAGIC
	// and seq unchanged. DIAG ≠ product PASS. Do not leave =1 on product wire.
	parameter bit DIAG_TAG_RCA = 1'b0
)(
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,

	input  wire [$clog2(FRAME_W)-1:0] rd_x,
	input  wire [$clog2(FRAME_H)-1:0] rd_y,
	input  wire        rd_active,
	output reg  [7:0]  rd_r,
	output reg  [7:0]  rd_g,
	output reg  [7:0]  rd_b,
	// N-wide RGB (lane 0 == rd_r/g/b). Tied off when unused by present_core.
	output reg  [PX_PER_CLK*8-1:0] rd_r_n,
	output reg  [PX_PER_CLK*8-1:0] rd_g_n,
	output reg  [PX_PER_CLK*8-1:0] rd_b_n,
	output reg  [PX_PER_CLK-1:0]   rd_lane_valid_n,
	output reg                     rd_n_valid,

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
	localparam int X_W = $clog2(FRAME_W);
	localparam int Y_W = $clog2(FRAME_H);
	localparam int CODED_X_W = $clog2(CODED_W);
	localparam int CODED_Y_W = $clog2(CODED_H);
	localparam int Y_LINE_QWORDS = CODED_W / 8;
	localparam int C_LINE_QWORDS = CODED_W / 16;
	localparam int Y_QW_AW = $clog2(Y_LINE_QWORDS);
	localparam int C_QW_AW = $clog2(C_LINE_QWORDS);
	localparam int LINE_SLOTS = LINE_COUNT * 2;
	localparam int SLOT_W = $clog2(LINE_SLOTS);
	localparam [SLOT_W-1:0] SECOND_SET_BASE = SLOT_W'(LINE_COUNT);
	localparam [X_W-1:0] LAST_X = X_W'(FRAME_W - 1);
	localparam [Y_W-1:0] LAST_Y = Y_W'(FRAME_H - 1);
	localparam [X_W-1:0] PRESENT_X_L = X_W'(PRESENT_X);
	localparam [Y_W-1:0] PRESENT_Y_L = Y_W'(PRESENT_Y);
	localparam [X_W-1:0] PRESENT_END_X = X_W'(PRESENT_X + DISPLAY_W);
	localparam [Y_W-1:0] PRESENT_END_Y = Y_W'(PRESENT_Y + DISPLAY_H);
	localparam [CODED_X_W-1:0] CROP_LEFT_L = CODED_X_W'(CROP_LEFT);
	localparam [CODED_Y_W-1:0] CROP_TOP_L = CODED_Y_W'(CROP_TOP);
	localparam [28:0] BASE_W0 = PHYS_BASE[31:3];
	localparam [28:0] HPS_BANK_STRIDE_QWORDS = 29'(HPS_BANK_STRIDE_BYTES / 8);
	localparam [28:0] BASE_W1 = PHYS_BASE[31:3] + HPS_BANK_STRIDE_QWORDS;
	localparam [28:0] DOORBELL_W = DOORBELL_PHYS[31:3];
	localparam [28:0] MAILBOX_W  = MAILBOX_PHYS[31:3];
	localparam [28:0] INPUT_MAILBOX_W = INPUT_MAILBOX_PHYS[31:3];
	localparam [28:0] SDRAM_MAILBOX_W = SDRAM_MAILBOX_PHYS[31:3];
	localparam [28:0] FRAME_MAILBOX_W = FRAME_MAILBOX_PHYS[31:3];
	localparam [28:0] BANK_MAILBOX_W  = BANK_MAILBOX_PHYS[31:3];
	localparam [28:0] Y_PLANE_QWORDS = 29'((CODED_W * CODED_H) / 8);
	localparam [28:0] C_PLANE_QWORDS = 29'((CODED_W * CODED_H) / 32);
	localparam [28:0] U_PLANE_BASE = Y_PLANE_QWORDS;
	localparam [28:0] V_PLANE_BASE = Y_PLANE_QWORDS + C_PLANE_QWORDS;
	localparam [28:0] Y_LINE_QWORDS_W = 29'(Y_LINE_QWORDS);
	localparam [28:0] C_LINE_QWORDS_W = 29'(C_LINE_QWORDS);
	localparam [Y_QW_AW:0] DDR_BURST_MAX_QWORDS = (Y_QW_AW+1)'(DDR_BURST_MAX);
	localparam [31:0] MAGIC = 32'h504C_584B;
	// Consume three-lane 720p BW/ABI contract when coded 1280x720 (rd-duck: not QIP-only).
`include "plex_720p_bw_contract.svh"
	generate
		if ((CODED_W == 1280) && (CODED_H == 720)) begin : g_p720_store_contract
			if (PHYS_BASE != P720_PHYS_BASE)
				p720_store_phys_base_must_match_contract u_phys();
			if (DOORBELL_PHYS != P720_DOORBELL_PHYS)
				p720_store_doorbell_must_match_contract u_door();
			if (HPS_BANK_STRIDE_BYTES != P720_BANK_STRIDE)
				p720_store_stride_must_match_contract u_stride();
			if (LINE_COUNT < P720_LINE_COUNT)
				p720_store_line_count_below_contract_floor u_lines();
		end
	endgenerate

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
	// Widen display coords before crop add (CODED_* may exceed FRAME_* when crop>0).
	wire [CODED_X_W-1:0] src_x = rd_visible ? (CODED_X_W'(display_x) + CODED_X_W'(CROP_LEFT_L)) : '0;
	wire [CODED_Y_W-1:0] src_y = rd_visible ? (CODED_Y_W'(display_y) + CODED_Y_W'(CROP_TOP_L)) : '0;
	// Line identity / prefetch path: follow the vertical beam whenever Y is inside
	// the present band — independent of horizontal blank. Gating line match and
	// want_y on full rd_visible forced src_y→0 every HBlank (including store_x=LAST),
	// which thrashed the fill scheduler off the beam line and produced a variable
	// black prefix at DE open (parent: ragged left edge, interiors aligned, median
	// miss ~420 px on silicon). Do NOT use force_top (WANT_Y_FORCE_TOP) — that
	// freeze-class latch cost two fits; vsync/leave-VBlank naturally returns the
	// beam (and thus want_y) to the top via present_core store_y.
	// WANT_Y_LINE_ONLY=0 restores X-gated thrash for freeze/shear control builds.
	wire [CODED_Y_W-1:0] src_y_line = rd_y_visible ? (CODED_Y_W'(display_y) + CODED_Y_W'(CROP_TOP_L)) : '0;
	wire [CODED_Y_W-1:0] pref_y = WANT_Y_LINE_ONLY ? src_y_line : src_y;
	wire [Y_QW_AW-1:0] y_rd_addr = src_x[CODED_X_W-1:3];
	// softc17-cqwoff: restore softc2 C BRAM index (src_x>>4). softc15/16
	// C_X_HALF_OFF ±1 left R multi ~2× src (FAIL 120/121). Next lever is
	// DDR fill_qword_c phase (see FILL_C_QWORD_OFF below), not present-side
	// half-index offset.
	wire [C_QW_AW-1:0] c_rd_addr = src_x[CODED_X_W-1:4];

	genvar li;
	generate
		for (li = 0; li < LINE_SLOTS; li = li + 1) begin : gen_line
			line_buf_ram #(.WIDTH(Y_LINE_QWORDS), .AW(Y_QW_AW), .DATA_W(64)) yram (
				.wr_clk(clk_ddr), .wr_en(y_wr[li]), .wr_addr(y_wr_addr), .wr_data(y_wr_data),
				.rd_clk(clk), .rd_addr(y_rd_addr), .rd_data(y_q[li])
			);
			line_buf_ram #(.WIDTH(C_LINE_QWORDS), .AW(C_QW_AW), .DATA_W(64)) uram (
				.wr_clk(clk_ddr), .wr_en(u_wr[li]), .wr_addr(c_wr_addr), .wr_data(u_wr_data),
				.rd_clk(clk), .rd_addr(c_rd_addr), .rd_data(u_q[li])
			);
			line_buf_ram #(.WIDTH(C_LINE_QWORDS), .AW(C_QW_AW), .DATA_W(64)) vram (
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
	// I1 (DIAG): sticky miss composition on scanout clk (cleared only on reset).
	// Sampled against registered y_hit_r/c_hit_r with miss_d so edges align with
	// the underrun path (rd_miss_now → miss_d).
	reg        miss_y_only_sticky;
	reg        miss_c_only_sticky;
	reg        miss_both_sticky;
	reg        any_hit_sticky;

	reg rd_active_r, rd_active_d, rd_visible_r, rd_visible_d, miss_d, c_lag_d;
	// Last good active-region pixel (not HBlank). Used when linebuf misses at DE.
	reg [7:0] last_active_r, last_active_g, last_active_b;
	reg last_active_valid;
	// Previous-line RGB by coded X — vertical hold on miss (avoids single-pixel
	// horizontal color stubs when left-edge misses after line switch).
	(* ramstyle = "no_rw_check, M10K" *)
	reg [23:0] prev_line_rgb [0:2047];
	reg [23:0] prev_line_q;
	reg        prev_line_q_valid;
	reg y_hit_r, c_hit_r;
	reg [SLOT_W-1:0] y_hit_idx_r, c_hit_idx_r;
	reg [2:0] y_sel_r, c_sel_r;
	// YEL_B_UV_PHASE_PPC2: register full src_x with y/c_sel for absolute multi-pixel phase
	reg [CODED_X_W-1:0] src_x_r;

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
		// Y home slot first (matches Y_HOME_SLOT fill). Fallback scan whole half.
		video_slot = (disp_buf ? SECOND_SET_BASE : {SLOT_W{1'b0}})
		    + SLOT_W'(Y_W'(pref_y) % LINE_COUNT);
		if (y_valid_v2[video_slot] && (y_bank_v2[video_slot] == disp_bank)
		    && (y_line_v2[video_slot] == Y_W'(pref_y))) begin
			y_hit_now = 1'b1;
			y_hit_idx_now = video_slot;
		end
		for (vi = 0; vi < LINE_COUNT; vi = vi + 1) begin
			video_slot = (disp_buf ? SECOND_SET_BASE : {SLOT_W{1'b0}}) + vi[SLOT_W-1:0];
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
	// Hard miss only when Y under the beam is missing. C-only lag used to force
	// full-pixel hold (prev-line/last-active) and painted visible colored streaks
	// under content; soft-hit with neutral chroma instead (see u/v_pix below).
	// Primary left-edge class: HBlank want_y/src_y thrash (fixed via src_y_line).
	// Residual Y miss under true DDR backlog still counts as underrun.
	wire rd_miss_now = rd_active && rd_visible && has_frame && !y_hit_now;
	// Sticky C-lag for I1 RCA (not a hard display miss).
	wire rd_c_lag_now = rd_active && rd_visible && has_frame && y_hit_now && !c_hit_now;

	// BT.601 full-range helpers for multi-pixel lanes (matches host / yuv_bt601_npx).
	function automatic [7:0] yuv_r(input [7:0] y, input [7:0] u, input [7:0] v);
		reg signed [11:0] ys, us, vs, rc;
		reg signed [20:0] w;
		begin
			ys = {4'd0, y};
			us = {4'd0, u} - 12'sd128;
			vs = {4'd0, v} - 12'sd128;
			w = ({{9{ys[11]}}, ys} <<< 8) + (21'sd359 * vs);
			rc = w[19:8];
			if (rc < 0) yuv_r = 8'd0;
			else if (rc > 12'sd255) yuv_r = 8'd255;
			else yuv_r = rc[7:0];
		end
	endfunction
	function automatic [7:0] yuv_g(input [7:0] y, input [7:0] u, input [7:0] v);
		reg signed [11:0] ys, us, vs, rc;
		reg signed [20:0] w;
		begin
			ys = {4'd0, y};
			us = {4'd0, u} - 12'sd128;
			vs = {4'd0, v} - 12'sd128;
			w = ({{9{ys[11]}}, ys} <<< 8) - (21'sd88 * us) - (21'sd183 * vs);
			rc = w[19:8];
			if (rc < 0) yuv_g = 8'd0;
			else if (rc > 12'sd255) yuv_g = 8'd255;
			else yuv_g = rc[7:0];
		end
	endfunction
	function automatic [7:0] yuv_b(input [7:0] y, input [7:0] u, input [7:0] v);
		reg signed [11:0] ys, us, vs, rc;
		reg signed [20:0] w;
		begin
			ys = {4'd0, y};
			us = {4'd0, u} - 12'sd128;
			vs = {4'd0, v} - 12'sd128;
			w = ({{9{ys[11]}}, ys} <<< 8) + (21'sd454 * us);
			rc = w[19:8];
			if (rc < 0) yuv_b = 8'd0;
			else if (rc > 12'sd255) yuv_b = 8'd255;
			else yuv_b = rc[7:0];
		end
	endfunction

	// Scalar path — keep the original wire form bit-identical to pre-PPC land.
	// Soft C: DOT_CRAWL_FIX3c held last UV forever on C-lag (cleared only at
	// HBlank/line start). On multi-colour video that *smears* the previous
	// chroma into miss pixels — bright green bleed when the prior sample was
	// foliage green (user BBB HDMI 91_green_still). DOT_CRAWL_FIX3d: hold at
	// most SOFT_C_HOLD_MAX consecutive miss samples, then neutral 128 so green
	// UV cannot paint across rocks/sky/text. HOLD_MAX=0 (softc3): never hold —
	// UV cannot paint across rocks/sky/text. Orange logo edges still get 1–2
	// samples of hold (enough for free-list slip without full-line smear).
	localparam int SOFT_C_HOLD_MAX = 0;
	localparam int SOFT_C_HOLD_W = 2; // clog2(2+1)
	reg [7:0] last_u_r, last_v_r;
	reg       last_c_valid;
	reg [SOFT_C_HOLD_W-1:0] soft_c_hold_n;
	wire soft_c_hold_ok = last_c_valid && (soft_c_hold_n < SOFT_C_HOLD_W'(SOFT_C_HOLD_MAX));
	wire [7:0] y_pix = pick_byte(selected_y_q, y_sel_r);
	wire [7:0] u_raw = pick_byte(selected_u_q, c_sel_r);
	wire [7:0] v_raw = pick_byte(selected_v_q, c_sel_r);
	wire [7:0] u_pix = c_hit_r ? u_raw : (soft_c_hold_ok ? last_u_r : 8'd128);
	wire [7:0] v_pix = c_hit_r ? v_raw : (soft_c_hold_ok ? last_v_r : 8'd128);
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

	// Multi-pixel extract from the same registered qwords (PPC>1, even-aligned x).
	// Wire-form BT.601 per lane (match scalar r_calc/g_calc/b_calc). Do NOT call
	// yuv_r/g/b functions here: concurrent generate assigns can share function
	// temps under Verilator/synth and corrupt V-128<0 (PROBE_R3_P0: multi
	// 255/255/200 while scalar gold 197/201/200; product QSF PPC=2 uses rd_r_n).
	wire [7:0] r_lane [0:PX_PER_CLK-1];
	wire [7:0] g_lane [0:PX_PER_CLK-1];
	wire [7:0] b_lane [0:PX_PER_CLK-1];
	genvar gpi;
	generate
		for (gpi = 0; gpi < PX_PER_CLK; gpi = gpi + 1) begin : g_px
			// Absolute per-lane phase (match yuv_bt601_npx); BRAM 1-cy pairs with src_x_r.
			wire [CODED_X_W-1:0] x_l = src_x_r + CODED_X_W'(gpi);
			wire [2:0] y_sel_l = x_l[2:0];
			// softc17: legacy softc2 in-qword C sample (x[3:1]); fill phase is separate.
			wire [2:0] c_sel_l = x_l[3:1];
			wire [7:0] y_l = pick_byte(selected_y_q, y_sel_l);
			// Same soft-C hold limit as scalar (SOFT_C_HOLD_MAX).
			wire [7:0] u_l = c_hit_r ? pick_byte(selected_u_q, c_sel_l)
			                         : (soft_c_hold_ok ? last_u_r : 8'd128);
			wire [7:0] v_l = c_hit_r ? pick_byte(selected_v_q, c_sel_l)
			                         : (soft_c_hold_ok ? last_v_r : 8'd128);
			wire signed [11:0] y_ls = {4'd0, y_l};
			wire signed [11:0] u_ls = {4'd0, u_l} - 12'sd128;
			wire signed [11:0] v_ls = {4'd0, v_l} - 12'sd128;
			wire signed [20:0] y_lext = {{9{y_ls[11]}}, y_ls};
			wire signed [20:0] r_lw = (y_lext <<< 8) + (21'sd359 * v_ls);
			wire signed [20:0] g_lw = (y_lext <<< 8) - (21'sd88 * u_ls) - (21'sd183 * v_ls);
			wire signed [20:0] b_lw = (y_lext <<< 8) + (21'sd454 * u_ls);
			assign r_lane[gpi] = sat8(r_lw[19:8]);
			assign g_lane[gpi] = sat8(g_lw[19:8]);
			assign b_lane[gpi] = sat8(b_lw[19:8]);
		end
	endgenerate

	always @(posedge clk) begin
		if (reset) begin
			rd_active_r <= 1'b0;
			rd_active_d <= 1'b0;
			rd_visible_r <= 1'b0;
			rd_visible_d <= 1'b0;
			miss_d <= 1'b0;
			c_lag_d <= 1'b0;
			underrun_count <= 16'd0;
			want_y_sys <= '0;
			want_y_gray <= '0;
			status_osd_hold <= 16'd0;
			sdram_status_hold <= 24'd0;
			frame_miss_toggle <= 1'b0;
			miss_y_only_sticky <= 1'b0;
			miss_c_only_sticky <= 1'b0;
			miss_both_sticky <= 1'b0;
			any_hit_sticky <= 1'b0;
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
			src_x_r <= '0;
			rd_r <= 8'd0;
			rd_g <= 8'd0;
			rd_b <= 8'd0;
			rd_r_n <= '0;
			rd_g_n <= '0;
			rd_b_n <= '0;
			rd_lane_valid_n <= '0;
			rd_n_valid <= 1'b0;
			last_active_r <= 8'd0;
			last_active_g <= 8'd0;
			last_active_b <= 8'd0;
			last_active_valid <= 1'b0;
			prev_line_q <= 24'd0;
			prev_line_q_valid <= 1'b0;
			last_u_r <= 8'd128;
			last_v_r <= 8'd128;
			last_c_valid <= 1'b0;
			soft_c_hold_n <= '0;
		end else begin
			// Soft-C hold: capture good chroma; clear at blank / line start.
			// On miss, count consecutive holds; after SOFT_C_HOLD_MAX force
			// neutral UV (soft_c_hold_ok) so foliage UV cannot smear far.
			if (!rd_visible_d || (rd_visible_d && src_x_r == '0)) begin
				last_c_valid <= 1'b0;
				soft_c_hold_n <= '0;
			end else if (c_hit_r && rd_visible_d && has_frame && !miss_d) begin
				last_u_r <= u_raw;
				last_v_r <= v_raw;
				last_c_valid <= 1'b1;
				soft_c_hold_n <= '0;
			end else if (rd_visible_d && has_frame && !c_hit_r) begin
				if (soft_c_hold_n != {SOFT_C_HOLD_W{1'b1}})
					soft_c_hold_n <= soft_c_hold_n + 1'b1;
			end
			// Sync read previous-line RGB for miss path (1-cycle; addr = src_x_r).
			if (src_x_r < CODED_X_W'(2048)) begin
				prev_line_q <= prev_line_rgb[src_x_r[10:0]];
				prev_line_q_valid <= 1'b1;
			end else begin
				prev_line_q_valid <= 1'b0;
			end
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
			// LINECAM_WANT_Y_HOLD_LAST: product (WANT_Y_LINE_ONLY=1) holds last
			// in-band want_y_sys when !rd_y_visible — do NOT force 0. Force-to-0
			// jumped gray want_y last→0 every VBlank/out-of-band; after gray-hold
			// stabilized, desired_y_r snapped to top-of-frame refill tags (MEAN
			// black residual after gray-hold + cur-window-first). pref_y/src_y_line
			// still 0 out-of-band for y_hit/pixel; only the fill key holds.
			// When WANT_Y_LINE_ONLY=0, rd_visible low still forces want_y→0 (shear).
			if (WANT_Y_LINE_ONLY ? rd_y_visible : rd_visible) begin
				if (want_y_sys != Y_W'(pref_y))
					want_y_sys <= Y_W'(pref_y);
			end else if (!WANT_Y_LINE_ONLY && want_y_sys != '0) begin
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
			// softc17: legacy softc2 c_sel = x[3:1]
			c_sel_r <= src_x[3:1];
			src_x_r <= src_x;
			miss_d <= rd_miss_now;
			c_lag_d <= rd_c_lag_now;
			if (miss_d && underrun_count != 16'hFFFF) begin
				underrun_count <= underrun_count + 16'd1;
				frame_miss_toggle <= ~frame_miss_toggle;
			end
			// I1 sticky composition (always collected; published only if DIAG_TAG_RCA).
			// Y-hard-miss vs C-soft-lag tracked separately after soft-C change.
			if (miss_d && has_frame) begin
				if (!y_hit_r &&  c_hit_r) miss_y_only_sticky <= 1'b1;
				if (!y_hit_r && !c_hit_r) miss_both_sticky  <= 1'b1;
			end
			if (c_lag_d && has_frame)
				miss_c_only_sticky <= 1'b1;
			if (rd_visible_d && has_frame && !miss_d && y_hit_r && c_hit_r)
				any_hit_sticky <= 1'b1;

			// Y-hit is enough to paint (C soft-hit uses neutral UV above).
			if ((rd_active_d || !rd_active) && rd_visible_d && has_frame && !miss_d && y_hit_r) begin
				rd_r <= sat8(r_calc);
				rd_g <= sat8(g_calc);
				rd_b <= sat8(b_calc);
				// EDGE_ROLL_FIX: do NOT latch last_active for miss paint.
				// last_active (horizontal hold) painted rightward orange dots on
				// the chevron silhouette and black nicks on the left (HDMI video
				// 19_temporal_maxdiff: motion only on outline). Keep regs idle.
				last_active_valid <= 1'b0;
				// Same-X vertical hold buffer for the *next* line only.
				// Commit on any Y hit (soft-C RGB is fine) so prev_line is dense.
				if (src_x_r < CODED_X_W'(2048))
					prev_line_rgb[src_x_r[10:0]] <= {sat8(r_calc), sat8(g_calc), sat8(b_calc)};
				rd_n_valid <= 1'b1;
				begin : pack_npx
					integer pxi;
					for (pxi = 0; pxi < PX_PER_CLK; pxi = pxi + 1) begin
						rd_r_n[pxi*8 +: 8] <= r_lane[pxi];
						rd_g_n[pxi*8 +: 8] <= g_lane[pxi];
						rd_b_n[pxi*8 +: 8] <= b_lane[pxi];
						rd_lane_valid_n[pxi] <= 1'b1;
					end
				end
			end else if (rd_visible_d && has_frame && miss_d) begin
				// EDGE_ROLL_FIX2: NO hold path. prev_line same-X on diagonal
				// chevron edges crawled 1 row (vertical roll); last_active
				// smeared orange right. With Y_HOME+KEEP_VALID miss rate is
				// low — paint black on residual miss so silhouette stays put.
				rd_r <= 8'd0;
				rd_g <= 8'd0;
				rd_b <= 8'd0;
				rd_r_n <= '0;
				rd_g_n <= '0;
				rd_b_n <= '0;
				rd_lane_valid_n <= {PX_PER_CLK{1'b1}};
				rd_n_valid <= 1'b1;
			end else if (!has_frame || !rd_visible_d) begin
				// Outside active: black porch. Kill any last_active across HBlank.
				rd_r <= 8'd0;
				rd_g <= 8'd0;
				rd_b <= 8'd0;
				rd_r_n <= '0;
				rd_g_n <= '0;
				rd_b_n <= '0;
				rd_lane_valid_n <= '0;
				rd_n_valid <= 1'b0;
				last_active_valid <= 1'b0;
			end else begin
				rd_n_valid <= 1'b0;
				rd_lane_valid_n <= '0;
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
	// I1 sticky CDC (clk → clk_ddr): sticky bits only 0→1, 2-FF safe.
	reg        miss_y_only_s1, miss_y_only_s2;
	reg        miss_c_only_s1, miss_c_only_s2;
	reg        miss_both_s1,   miss_both_s2;
	reg        any_hit_s1,     any_hit_s2;
	// I2 sample regs (combo computed after schedule defines cur/prep base).
	reg [4:0]  occ_disp_y_c, occ_prep_y_c;
	reg [5:0]  bank_mm_disp_c;
	reg [4:0]  occ_disp_y_r, occ_prep_y_r;
	reg [5:0]  bank_mm_disp_r;

	wire cmd_empty;
	wire [7:0] cmd_rdata;
	reg cmd_pop;
	async_fifo #(.WIDTH(8), .AW(2)) input_fifo (
		.wr_clk(clk), .wr_reset(reset),
		.wr_en(input_cmd_valid && (input_cmd != 8'd0)), .wr_data(input_cmd),
		.wr_full(), .wr_almost_full(),
		.rd_clk(clk_ddr), .rd_reset(reset_ddr), .rd_en(cmd_pop), .rd_data(cmd_rdata), .rd_empty(cmd_empty)
	);

	function automatic [Y_W-1:0] clamp_ahead(input [Y_W-1:0] base, input integer ahead);
		integer sum;
		begin
			sum = {{(32-Y_W){1'b0}}, base};
			sum = sum + ahead;
			clamp_ahead = (sum >= FRAME_H) ? LAST_Y : sum[Y_W-1:0];
		end
	endfunction

	// Y_HOME_SLOT (Track A2): pitch-LINE_COUNT miss RCA — free-list put line L
	// in an arbitrary free slot; every L%LINE_COUNT==0 systematically failed
	// y_hit on silicon (missblack solid). Map Y fills to a stable home:
	//   idx = half_base + (line % LINE_COUNT)
	// Window size LINE_COUNT guarantees L and L+LC never co-resident.
	// Chroma keeps free-list (shared across Y pairs; different occupancy).
	function automatic [SLOT_W-1:0] y_home_off(input [Y_W-1:0] line_y);
		// LINE_COUNT is power-of-2 in product (16); % synthesizes to low bits.
		y_home_off = SLOT_W'(line_y % LINE_COUNT);
	endfunction

	integer ti, tj, tk;
	reg need_y_cur_c, need_c_cur_c, need_y_prep_c, need_c_prep_c, pending_ready_c;
	reg [Y_W-1:0] target_y_cur_c, target_y_prep_c;
	reg [Y_W-2:0] target_c_cur_c, target_c_prep_c;
	reg [SLOT_W-1:0] target_y_idx_cur_c, target_y_idx_prep_c, target_c_idx_cur_c, target_c_idx_prep_c;
	reg found_line, slot_keep, found_slot_y_cur, found_slot_y_prep, found_slot_c_cur, found_slot_c_prep;
	reg [Y_W-1:0] desired_y;
	reg [Y_W-2:0] desired_c;
	// o34: register set-base from disp_buf_d2. o28 STA −0.047 was
	// disp_buf_d2 → target_y_cur_r (9 levels / 10.561 ns) — NOT arbiter.
	// One-cycle lagged base matches existing d1/d2 bank freeze style.
	reg [SLOT_W-1:0] cur_base_idx_r, prep_base_idx_r;
	wire [SLOT_W-1:0] cur_base_idx = cur_base_idx_r;
	wire [SLOT_W-1:0] prep_base_idx = prep_base_idx_r;
	reg sched_valid, sched_is_y, sched_for_pending;
	reg sched_bank, sched_pending_ready;
	reg [Y_W-1:0] sched_y;
	reg [Y_W-2:0] sched_cy;
	reg [SLOT_W-1:0] sched_idx;
	always @(posedge clk_ddr) begin
		if (reset_ddr) begin
			cur_base_idx_r <= '0;
			prep_base_idx_r <= SECOND_SET_BASE;
		end else begin
			cur_base_idx_r <= disp_buf_d2 ? SECOND_SET_BASE : '0;
			prep_base_idx_r <= disp_buf_d2 ? '0 : SECOND_SET_BASE;
		end
	end
	always @* begin
		need_y_cur_c = 1'b0;
		need_c_cur_c = 1'b0;
		need_y_prep_c = 1'b0;
		need_c_prep_c = 1'b0;
		target_y_cur_c = desired_y_r[0];
		target_y_prep_c = '0;
		target_c_cur_c = desired_y_r[0][Y_W-1:1];
		target_c_prep_c = '0;
		// Y home default for desired[0]
		target_y_idx_cur_c = cur_base_idx + y_home_off(desired_y_r[0]);
		target_y_idx_prep_c = prep_base_idx;
		target_c_idx_cur_c = cur_base_idx;
		target_c_idx_prep_c = prep_base_idx;
		found_slot_y_cur = 1'b1; // home always exists
		found_slot_y_prep = 1'b1;
		found_slot_c_cur = 1'b0;
		found_slot_c_prep = 1'b0;
		pending_ready_c = 1'b1;

		for (ti = 0; ti < LINE_COUNT; ti = ti + 1) begin
			desired_y = desired_y_r[ti];
			desired_c = desired_y_r[ti][Y_W-1:1];
			// Y: probe home slot only (direct identity).
			found_line = y_valid[cur_base_idx + y_home_off(desired_y)]
			    && (y_bank[cur_base_idx + y_home_off(desired_y)] == disp_bank_d2)
			    && (y_line[cur_base_idx + y_home_off(desired_y)] == desired_y);
			if (!found_line && !need_y_cur_c) begin
				need_y_cur_c = 1'b1;
				target_y_cur_c = desired_y;
				target_y_idx_cur_c = cur_base_idx + y_home_off(desired_y);
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

			// Prep Y: lines 0..LINE_COUNT-1 of pending bank; home == ti.
			found_line = y_valid[prep_base_idx + y_home_off(ti[Y_W-1:0])]
			    && (y_bank[prep_base_idx + y_home_off(ti[Y_W-1:0])] == pending_bank_d2)
			    && (y_line[prep_base_idx + y_home_off(ti[Y_W-1:0])] == ti[Y_W-1:0]);
			if (swap_pending_d2 && !found_line) begin
				pending_ready_c = 1'b0;
				if (!need_y_prep_c) begin
					need_y_prep_c = 1'b1;
					target_y_prep_c = ti[Y_W-1:0];
					target_y_idx_prep_c = prep_base_idx + y_home_off(ti[Y_W-1:0]);
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

		// Chroma free-list only (Y home indices already set).
		for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
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

			if (PREP_SLOT_RECYCLE) begin
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
				if ((!c_valid[prep_base_idx + tj[SLOT_W-1:0]]) && !found_slot_c_prep) begin
					found_slot_c_prep = 1'b1;
					target_c_idx_prep_c = prep_base_idx + tj[SLOT_W-1:0];
				end
			end
		end
	end

	// clk_ddr schedule pipeline: break combinational path
	// desired_y_r → found_line/need_*_c → S_IDLE DDRAM_*/mbox enables.
	// STA (cutb-buildid-keep): Fmax 87.4 < 90 on general[2]; TNS entirely
	// launched from desired_y_r through this cone. Sample schedule outputs
	// and drive S_IDLE only from *_r (+1 clk_ddr decision latency).
	// Do not multicycle the same-clock cone; keep combo for TB probes.
	// H-R1d SCHED_RECORD_ATOMIC: also freeze prep/cur select + bank with the
	// same sample as need_*/target_*_r so S_IDLE arm never re-muxes live
	// swap_pending_d2 against a lagged index epoch (set/bank ownership skew).
	// Consume path (sched_valid issue) already uses only sched_*; latch is the gap.
	reg need_y_cur_r, need_c_cur_r, need_y_prep_r, need_c_prep_r, pending_ready_r;
	reg sel_y_prep_r, sel_c_prep_r;
	reg sched_bank_y_src_r, sched_bank_c_src_r;
	reg [Y_W-1:0] target_y_cur_r, target_y_prep_r;
	reg [Y_W-2:0] target_c_cur_r, target_c_prep_r;
	reg [SLOT_W-1:0] target_y_idx_cur_r, target_y_idx_prep_r, target_c_idx_cur_r, target_c_idx_prep_r;
	always @(posedge clk_ddr) begin
		if (reset_ddr) begin
			need_y_cur_r <= 1'b0;
			need_c_cur_r <= 1'b0;
			need_y_prep_r <= 1'b0;
			need_c_prep_r <= 1'b0;
			pending_ready_r <= 1'b1;
			sel_y_prep_r <= 1'b0;
			sel_c_prep_r <= 1'b0;
			sched_bank_y_src_r <= 1'b0;
			sched_bank_c_src_r <= 1'b0;
			target_y_cur_r <= '0;
			target_y_prep_r <= '0;
			target_c_cur_r <= '0;
			target_c_prep_r <= '0;
			target_y_idx_cur_r <= '0;
			target_y_idx_prep_r <= '0;
			target_c_idx_cur_r <= '0;
			target_c_idx_prep_r <= '0;
		end else begin
			need_y_cur_r <= need_y_cur_c;
			need_c_cur_r <= need_c_cur_c;
			need_y_prep_r <= need_y_prep_c;
			need_c_prep_r <= need_c_prep_c;
			pending_ready_r <= pending_ready_c;
			// Same-cycle sample as need_*/target_*_r (not live re-eval at arm).
			// LINECAM_CUR_WINDOW_FIRST: demote prep freeze while display half
			// misses desired (has_frame && need_*_cur). Keeps sel+bank atomic
			// with cur path (disp_bank); cold-start !has_frame still allows prep.
			sel_y_prep_r <= swap_pending_d2 && need_y_prep_c
				&& !(has_frame_d2 && need_y_cur_c);
			sel_c_prep_r <= swap_pending_d2 && need_c_prep_c
				&& !(has_frame_d2 && need_c_cur_c);
			sched_bank_y_src_r <= (swap_pending_d2 && need_y_prep_c
				&& !(has_frame_d2 && need_y_cur_c)) ? pending_bank_d2 : disp_bank_d2;
			sched_bank_c_src_r <= (swap_pending_d2 && need_c_prep_c
				&& !(has_frame_d2 && need_c_cur_c)) ? pending_bank_d2 : disp_bank_d2;
			target_y_cur_r <= target_y_cur_c;
			target_y_prep_r <= target_y_prep_c;
			target_c_cur_r <= target_c_cur_c;
			target_c_prep_r <= target_c_prep_c;
			target_y_idx_cur_r <= target_y_idx_cur_c;
			target_y_idx_prep_r <= target_y_idx_prep_c;
			target_c_idx_cur_r <= target_c_idx_cur_c;
			target_c_idx_prep_r <= target_c_idx_prep_c;
		end
	end

	// OPT-1 S_IDLE priority pipeline REGISTERED (product residual TAG/LAG):
	// Cycle N: one-hot pri_*_r from already-registered schedule + reqs only.
	// Cycle N+1: S_IDLE thin mux on pri_*_r (holdlast mbox-before-cur order).
	// FORBID: mbox_yield CE on need_*_c (combo); wrap thrash; LEAD_K thrash.
	// LINE_PRESSURE_MBOX_DEMOTE: when display window is incomplete, demote
	// frame/bank mbox using *registered* need_*_r only (STA-safe; not combo).
	// SOFT_C_Y_BEFORE_C (chevron ladder 08–12): soft-C paints U/V=128 on C lag,
	// so chroma fill is cosmetic bandwidth. YEL_A chroma RR burned ~half the
	// Y/C tier on C while display Y still incomplete → NO_HOLD black field
	// (yhome-noinv MEAN~12) despite Y_HOME killing pitch-LC. Hard Y-before-C
	// and starve all C arms while need_y_cur so residual underrun can close.
	reg pri_frame_mbox_r, pri_bank_mbox_r, pri_sched_issue_r;
	reg pri_y_arm_r, pri_c_arm_r, pri_poll_r, pri_imbox_r, pri_smbox_r, pri_sdram_r;
	wire bus_ok_c = !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE;
	wire y_arm_need_c = (has_frame_d2 && need_y_cur_r) || sel_y_prep_r;
	// C arm only when display Y window is complete (need_y_cur_r==0). Prep C
	// still allowed only when not under cur-Y pressure (sel_c_prep already
	// demoted by LINECAM_CUR_WINDOW_FIRST when need_c_cur, not need_y_cur —
	// gate here so Y pressure also blocks prep C).
	wire c_arm_need_c = ((has_frame_d2 && need_c_cur_r) || sel_c_prep_r)
	    && !(has_frame_d2 && need_y_cur_r);
	// Registered window pressure: Y-only (C lag is soft). Keeps mbox demoted
	// while Y incomplete without treating C lag as line pressure.
	wire line_pressure_r = has_frame_d2 && need_y_cur_r;
	wire mbox_frame_ok_c = !line_pressure_r
	    && frame_mbox_req
	    && (!frame_mbox_valid || poll_div[7:0] == 8'd224) && bus_ok_c;
	wire mbox_bank_ok_c = !line_pressure_r
	    && bank_mbox_req
	    && (!bank_mbox_valid || poll_div[7:0] == 8'd160) && bus_ok_c;
	wire higher_than_yc_c = mbox_frame_ok_c
	    || mbox_bank_ok_c
	    || (PIPELINE_REFILL_SCHEDULER && sched_valid);
	always @(posedge clk_ddr) begin
		if (reset_ddr) begin
			pri_frame_mbox_r <= 1'b0;
			pri_bank_mbox_r <= 1'b0;
			pri_sched_issue_r <= 1'b0;
			pri_y_arm_r <= 1'b0;
			pri_c_arm_r <= 1'b0;
			pri_poll_r <= 1'b0;
			pri_imbox_r <= 1'b0;
			pri_smbox_r <= 1'b0;
			pri_sdram_r <= 1'b0;
		end else if (state_ddr == S_IDLE) begin
			// Sample only in S_IDLE so arms match idle decision epoch.
			// Cascade: first true wins; mbox demoted under line_pressure_r.
			// Hard Y-before-C (no chroma RR).
			pri_frame_mbox_r <= mbox_frame_ok_c;
			pri_bank_mbox_r <= !mbox_frame_ok_c && mbox_bank_ok_c;
			pri_sched_issue_r <= !mbox_frame_ok_c
			    && !mbox_bank_ok_c
			    && PIPELINE_REFILL_SCHEDULER && sched_valid;
			pri_y_arm_r <= !higher_than_yc_c && y_arm_need_c;
			pri_c_arm_r <= !higher_than_yc_c && c_arm_need_c && !y_arm_need_c;
			pri_poll_r <= !higher_than_yc_c
			    && !y_arm_need_c
			    && !c_arm_need_c
			    && !poll_pending && poll_div[7:0] == 8'd0 && bus_ok_c;
			pri_imbox_r <= !higher_than_yc_c
			    && !y_arm_need_c
			    && !c_arm_need_c
			    && !(!poll_pending && poll_div[7:0] == 8'd0 && bus_ok_c)
			    && !cmd_empty && poll_div[7:0] == 8'd64 && bus_ok_c;
			pri_smbox_r <= !higher_than_yc_c
			    && !y_arm_need_c
			    && !c_arm_need_c
			    && !(!poll_pending && poll_div[7:0] == 8'd0 && bus_ok_c)
			    && !(!cmd_empty && poll_div[7:0] == 8'd64 && bus_ok_c)
			    && mbox_req && poll_div[7:0] == 8'd128 && bus_ok_c;
			pri_sdram_r <= !higher_than_yc_c
			    && !y_arm_need_c
			    && !c_arm_need_c
			    && !(!poll_pending && poll_div[7:0] == 8'd0 && bus_ok_c)
			    && !(!cmd_empty && poll_div[7:0] == 8'd64 && bus_ok_c)
			    && !(mbox_req && poll_div[7:0] == 8'd128 && bus_ok_c)
			    && sdram_mbox_req && poll_div[7:0] == 8'd192 && bus_ok_c;
		end else begin
			// Leave S_IDLE: clear so re-entry re-samples.
			pri_frame_mbox_r <= 1'b0;
			pri_bank_mbox_r <= 1'b0;
			pri_sched_issue_r <= 1'b0;
			pri_y_arm_r <= 1'b0;
			pri_c_arm_r <= 1'b0;
			pri_poll_r <= 1'b0;
			pri_imbox_r <= 1'b0;
			pri_smbox_r <= 1'b0;
			pri_sdram_r <= 1'b0;
		end
	end

	// I2 (DIAG): display/prep half occupancy + bank-mismatch on display half.
	// Uses cur_base_idx/prep_base_idx from schedule combo (same half ownership).
	integer oi;
	always @* begin
		occ_disp_y_c = 5'd0;
		occ_prep_y_c = 5'd0;
		bank_mm_disp_c = 6'd0;
		for (oi = 0; oi < LINE_COUNT; oi = oi + 1) begin
			if (y_valid[cur_base_idx + oi[SLOT_W-1:0]]) begin
				occ_disp_y_c = occ_disp_y_c + 5'd1;
				if (y_bank[cur_base_idx + oi[SLOT_W-1:0]] != disp_bank_d2)
					bank_mm_disp_c = bank_mm_disp_c + 6'd1;
			end
			if (y_valid[prep_base_idx + oi[SLOT_W-1:0]])
				occ_prep_y_c = occ_prep_y_c + 5'd1;
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
	// Bank base via ddr_frame_base_mux (DYN_BASE_EN=0 → bit-identical fixed select).
	wire [28:0] fill_bank_base;
	wire        fill_base_using_dyn;
	ddr_frame_base_mux #(
		.DYN_BASE_EN(DYN_BASE_EN)
	) u_fill_base_mux (
		.bank(fill_bank),
		.base_w0(BASE_W0),
		.base_w1(BASE_W1),
		.dyn_base0(29'd0),
		.dyn_base1(29'd0),
		.dyn_valid0(1'b0),
		.dyn_valid1(1'b0),
		.fill_bank_base(fill_bank_base),
		.using_dyn(fill_base_using_dyn)
	);
	wire [28:0] fill_y_qword = {{(29-Y_W){1'b0}}, fill_y} * Y_LINE_QWORDS_W;
`ifdef DDR_FRAME_STORE_FAULT_CHROMA_LUMA_STRIDE
	wire [28:0] fill_cy_qword = {{(30-Y_W){1'b0}}, fill_cy} * Y_LINE_QWORDS_W;
`else
	wire [28:0] fill_cy_qword = {{(30-Y_W){1'b0}}, fill_cy} * C_LINE_QWORDS_W;
`endif
	wire [28:0] fill_qword_y = {{(29-Y_QW_AW){1'b0}}, fill_qword[Y_QW_AW-1:0]};
	// softc23-cqwoffp2: FILL_C_QWORD_OFF=+2 (ladder softc17=+1 softc18=-1 softc22=-2)
	// cut R multi 2.06→1.85× still FAIL (122). This fire: OFF=-1 (signed)
	// opposite DDR C qword phase. Present path remains softc2 c_rd/c_sel.
	// HOLD_MAX=0. No UV_U_BIAS / conf thrash. Clamp [0 .. C_LINE_QWORDS-1].
	localparam int FILL_C_QWORD_OFF = 2;
	// Signed add (OFF may be negative). Widen +1 bit so -1 is not all-ones
	// cast into unsigned width (would corrupt +OFF).
	wire signed [C_QW_AW+1:0] fill_c_idx_raw =
		$signed({1'b0, fill_qword[C_QW_AW-1:0]})
		+ (C_QW_AW+2)'(signed'(FILL_C_QWORD_OFF));
	wire [C_QW_AW-1:0] fill_c_idx =
		(fill_c_idx_raw < 0) ? '0
		: (fill_c_idx_raw >= (C_QW_AW+2)'(C_LINE_QWORDS))
			? C_QW_AW'(C_LINE_QWORDS - 1)
			: fill_c_idx_raw[C_QW_AW-1:0];
	wire [28:0] fill_qword_c = {{(29-C_QW_AW){1'b0}}, fill_c_idx};
	wire [28:0] y_addr = fill_bank_base + fill_y_qword + fill_qword_y;
	wire [28:0] u_addr = fill_bank_base + U_PLANE_BASE + fill_cy_qword + fill_qword_c;
	wire [28:0] v_addr = fill_bank_base + V_PLANE_BASE + fill_cy_qword + fill_qword_c;
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

	// Product: {LINE_COUNT[2:0], |y_valid, state_ddr}. DIAG: I1 sticky nibble + state.
	// format_error remains 0xE1 in both modes (host nonYuvDoorbellRejected).
	assign debug_state = format_error ? DEBUG_FORMAT_ERROR
	                   : (DIAG_TAG_RCA
	                      ? {any_hit_s2, miss_both_s2, miss_y_only_s2, miss_c_only_s2, state_ddr}
	                      : {LINE_COUNT[2:0], |y_valid, state_ddr});

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
			miss_y_only_s1 <= 1'b0;
			miss_y_only_s2 <= 1'b0;
			miss_c_only_s1 <= 1'b0;
			miss_c_only_s2 <= 1'b0;
			miss_both_s1 <= 1'b0;
			miss_both_s2 <= 1'b0;
			any_hit_s1 <= 1'b0;
			any_hit_s2 <= 1'b0;
			occ_disp_y_r <= 5'd0;
			occ_prep_y_r <= 5'd0;
			bank_mm_disp_r <= 6'd0;
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
// INV_NONE_ON_BUF_FLIP + Y_HOME (chevron loop): no valid clear on swap.
// Hit requires bank match so stale half is ignored until refilled.
// (INVALIDATE_BOTH / INV_OUTGOING disabled — cold refill caused miss/shear.)
			has_frame_d1 <= has_frame;
			has_frame_d2 <= has_frame_d1;
			swap_pending_d1 <= swap_pending;
			swap_pending_d2 <= swap_pending_d1;
			pending_bank_d1 <= pending_bank;
			pending_bank_d2 <= pending_bank_d1;
			frames_done_d1 <= frames_done;
			frames_done_d2 <= frames_done_d1;

			// want_y: Gray-coded 2-FF sync (crossing #13).
			// Only adopt when gray is stable across the two FFs. Multi-bit jumps
			// (e.g. last line → 0 at blank) otherwise sample illegal gray codes
			// that decode to wrong beam lines → fill tags miss pref_y (DIAG
			// T3/T5: bank_mm=0, occ full, miss sticky, MEAN black). Hold last
			// desired_y_r until gray_s1==gray_s2. Keeps schedule-reg STA cut.
			want_y_gray_s1 <= want_y_gray;
			want_y_gray_s2 <= want_y_gray_s1;
			if (want_y_gray_s1 == want_y_gray_s2) begin
				for (ti = 0; ti < LINE_COUNT; ti = ti + 1)
					desired_y_r[ti] <= clamp_ahead(y_gray2bin(want_y_gray_s2), ti);
			end

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
			// UNDERRUN_EPOCH_CLEAR (product residual after OPT-1 F2 PASS / F1 sticky FFFF):
			// Clear frame_underrun_ddr on display swap (frames_done advance) so F1 can
			// climb/clear after warm miss burst. KEEP miss toggle CDC +1 path.
			// STA-safe: single compare + load; no pri/mbox/wrap thrash.
			if (frames_done_d2 != frames_done_d1) begin
				frame_underrun_ddr <= 16'd0;
				if (frame_miss_tog_s2 != frame_miss_tog_seen)
					frame_miss_tog_seen <= frame_miss_tog_s2;
			end else if (frame_miss_tog_s2 != frame_miss_tog_seen) begin
				frame_miss_tog_seen <= frame_miss_tog_s2;
				if (frame_underrun_ddr != 16'hFFFF)
					frame_underrun_ddr <= frame_underrun_ddr + 16'd1;
			end
			// I1 CDC + I2 sample (cheap; always run so DIAG param is pure pack select).
			miss_y_only_s1 <= miss_y_only_sticky;
			miss_y_only_s2 <= miss_y_only_s1;
			miss_c_only_s1 <= miss_c_only_sticky;
			miss_c_only_s2 <= miss_c_only_s1;
			miss_both_s1   <= miss_both_sticky;
			miss_both_s2   <= miss_both_s1;
			any_hit_s1     <= any_hit_sticky;
			any_hit_s2     <= any_hit_s1;
			occ_disp_y_r   <= occ_disp_y_c;
			occ_prep_y_r   <= occ_prep_y_c;
			bank_mm_disp_r <= bank_mm_disp_c;
			// Product pack vs DIAG I1/I2 pack (MAGIC/seq path unchanged at write).
			if (DIAG_TAG_RCA)
				frame_status_ddr <= {occ_disp_y_r, occ_prep_y_r, bank_mm_disp_r,
				                     any_hit_s2, miss_both_s2, miss_y_only_s2, miss_c_only_s2,
				                     state_ddr};
			else
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
					// need_*_r / target_*_r still drive S_IDLE refill (STA cut).
					// Sticky ready uses combo pending_ready_c (not lagged pending_ready_r):
					// after 6472789d schedule register, pending_ready_r stays 1 for one
					// clk_ddr when swap_pending rises while prep incomplete → false ready
					// / premature vsync swap / empty linebufs → underrun FFFF + black glass
					// (silicon cceb58e7). pending_ready_c drops same cycle as prep miss.
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
					if (pri_frame_mbox_r && bus_ok_c) begin
						DDRAM_ADDR <= FRAME_MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {frame_status_ddr, frame_mbox_seq + 8'd1, MAGIC_F};
						DDRAM_WE <= 1'b1;
						frame_mbox_seq <= frame_mbox_seq + 8'd1;
						frame_mbox_last <= frame_status_ddr;
						frame_mbox_valid <= 1'b1;
						frame_mbox_req <= 1'b0;
						state_ddr <= S_WRITE_WAIT;
					end else if (pri_bank_mbox_r && bus_ok_c) begin
						// PLXD bank-release: tell ARM which bank is safe to write
						// Layout: [63:48] frames_done (real swaps, CDC),
						//   [47:36] bank_vsync_count[11:0] (glass/vsync free-run LSBs),
						//   [35] swap_pending, [34] disp_bank,
						//   [33:32] free_bank_mask, [31:0] magic
						// frames_done MUST stay the real swap counter. Historical
						// c5382bee packed bank_vsync into [63:48] so PLXD looked
						// "live" while swaps stuck — ARM stale could not fire.
						// Glass vsync now rides the former reserved nibble only
						// (12-bit wrap ~68 s @60 Hz) so Δ glass rate is host-visible
						// without reintroducing vsync-as-frames_done.
						DDRAM_ADDR <= BANK_MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {frames_done_d2,                       // [63:48] real swaps (CDC)
						              bank_vsync_count[11:0],               // [47:36] glass vsync LSBs
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
					end else if (pri_sched_issue_r) begin
						fill_bank <= sched_bank;
						fill_idx <= sched_idx;
						fill_plane_v <= 1'b0;
						fill_qword <= '0;
						sched_valid <= 1'b0;
						// KEEP_VALID_UNTIL_FILL_DONE (yhome shear RCA): do NOT clear
						// y_valid/c_valid or retag bank here. In-place Y_HOME refill
						// used to drop valid mid-scanout → last_active orange trails
						// (14_yhome_ychold worse than softc free-list). Tag+valid
						// commit only when the full line lands (S_LINE_WAIT done).
						if (sched_is_y) begin
							fill_y <= sched_y;
							qwords_remaining <= Y_LINE_QWORDS[Y_QW_AW:0];
							fill_is_chroma <= 1'b0;
						end else begin
							fill_cy <= sched_cy;
							qwords_remaining <= C_LINE_QWORDS[Y_QW_AW:0];
							fill_is_chroma <= 1'b1;
						end
						state_ddr <= S_LINE_ISSUE;
					// LINECAM_CUR_WINDOW_FIRST: cur listed first; sel_*_prep_r already
					// demoted at schedule-reg sample when need_*_cur (see freeze above).
					end else if (pri_y_arm_r) begin
						// H-R1d: arm from frozen sel/bank/target_*_r only (no live swap_pending re-mux).
						// KEEP_VALID_UNTIL_FILL_DONE: non-pipeline path also defers valid/bank tag.
						if (PIPELINE_REFILL_SCHEDULER) begin
							sched_valid <= 1'b1;
							sched_is_y <= 1'b1;
							sched_for_pending <= sel_y_prep_r;
							sched_bank <= sched_bank_y_src_r;
							sched_y <= sel_y_prep_r ? target_y_prep_r : target_y_cur_r;
							sched_idx <= sel_y_prep_r ? target_y_idx_prep_r : target_y_idx_cur_r;
							sched_pending_ready <= pending_ready_r;
						end else begin
							fill_bank <= sched_bank_y_src_r;
							fill_y <= sel_y_prep_r ? target_y_prep_r : target_y_cur_r;
							fill_idx <= sel_y_prep_r ? target_y_idx_prep_r : target_y_idx_cur_r;
							fill_is_chroma <= 1'b0;
							fill_plane_v <= 1'b0;
							fill_qword <= '0;
							qwords_remaining <= Y_LINE_QWORDS[Y_QW_AW:0];
							state_ddr <= S_LINE_ISSUE;
						end
					end else if (pri_c_arm_r) begin
						// H-R1d + CUR_WINDOW_FIRST chroma twin — frozen sel/bank/target only.
						if (PIPELINE_REFILL_SCHEDULER) begin
							sched_valid <= 1'b1;
							sched_is_y <= 1'b0;
							sched_for_pending <= sel_c_prep_r;
							sched_bank <= sched_bank_c_src_r;
							sched_cy <= sel_c_prep_r ? target_c_prep_r : target_c_cur_r;
							sched_idx <= sel_c_prep_r ? target_c_idx_prep_r : target_c_idx_cur_r;
							sched_pending_ready <= pending_ready_r;
						end else begin
							fill_bank <= sched_bank_c_src_r;
							fill_cy <= sel_c_prep_r ? target_c_prep_r : target_c_cur_r;
							fill_idx <= sel_c_prep_r ? target_c_idx_prep_r : target_c_idx_cur_r;
							fill_is_chroma <= 1'b1;
							fill_plane_v <= 1'b0;
							fill_qword <= '0;
							qwords_remaining <= C_LINE_QWORDS[Y_QW_AW:0];
							state_ddr <= S_LINE_ISSUE;
						end
					end else if (pri_poll_r && bus_ok_c) begin
						DDRAM_ADDR <= DOORBELL_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						poll_pending <= 1'b1;
						state_ddr <= S_POLL_WAIT;
					end else if (pri_imbox_r && bus_ok_c) begin
						DDRAM_ADDR <= INPUT_MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {imbox_seq + 16'd1, imbox_cmd_seq + 8'd1, cmd_rdata, MAGIC_I};
						DDRAM_WE <= 1'b1;
						cmd_pop <= 1'b1;
						imbox_seq <= imbox_seq + 16'd1;
						imbox_cmd_seq <= imbox_cmd_seq + 8'd1;
						state_ddr <= S_WRITE_WAIT;
					end else if (pri_smbox_r && bus_ok_c) begin
						DDRAM_ADDR <= MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {mbox_seq + 16'd1, status_osd_safe, MAGIC_S};
						DDRAM_WE <= 1'b1;
						mbox_seq <= mbox_seq + 16'd1;
						mbox_last <= status_osd_safe;
						mbox_valid <= 1'b1;
						mbox_req <= 1'b0;
						state_ddr <= S_WRITE_WAIT;
					end else if (pri_sdram_r && bus_ok_c) begin
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
								qwords_remaining <= C_LINE_QWORDS[Y_QW_AW:0];
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
// mplex_hold_lcell lives in rtl/mplex_hold_lcell.sv (files.qip) — do not
// redeclare here (Quartus Error 10228: cannot be declared more than once).
