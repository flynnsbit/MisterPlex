// Present geometry latch — DDR PLXG 6×u64 (MAGIC_G) at FIXED +0x800..+0x82F.
// OWNER: w-mem (parent arbitration #3). PLXG/ABI#2 producer + B16 promote.
// Non-owners: patch contract only — never whole-file adopt. Nets: plxg_*.
//
// B4: epoch/session in q0[47:34]; zero epoch rejected (restart ABA).
// B16: commit STAGES only. Live outputs update on frame_boundary (atomic
//      promote at frame start). Mid-active commit must NOT change pitch/base
//      (or DAR/fps) inside a raster.
// ABI #2: q5 carries DAR + content_fps; reserved[63:34] MUST be zero or reject.
// Parent #4: bit34 fps_1001 (#2.1) VACATED — still inside reserved; E4 rejects.
// DAR blackout: same WxH/stride DAR change never hits store geom_layout_chg
// (store compares enable/W/H/stride/map only). Hold dar_hold_black on the
// aspect path for N frame starts. Compare DAR tuple only — NOT PLXG seq
// (seq advances every frame). FAULT_NO_DAR_BLACKOUT = red twin.
//
// FAULT_IMMEDIATE_COMMIT: restore pre-B16 promote-on-commit (red twin REPRO).
// FAULT_LOSE_COINCIDENT: split ifs lose commit+boundary same-cycle (rd-duck).
// FAULT_NO_EPOCH: seq-only accept (B4 red twin).
// FAULT_IGNORE_Q5_RESERVED: accept nonzero reserved (ABI #2 red twin).
//
// Wire ABI: host/libmisterplex/plxg_record.hpp + mailbox_abi_spec.hpp.

`timescale 1ns/1ps
`default_nettype none

module present_geom_latch (
	input  wire        clk,
	input  wire        reset,
	// DDR consumer write port (6 beats, then commit).
	input  wire        wr_en,
	input  wire [2:0]  wr_idx,   // 0..5
	input  wire [63:0] wr_data,
	input  wire        commit,   // pulse: stage shadow → pending (not live)
	// B16: pulse at frame start (e.g. VSync rising on clk_sys). Promotes pending→live.
	input  wire        frame_boundary,
	// Live window + geometry (stable after promote until next promote).
	output reg         win_enable,
	output reg         geom_enable,
	output reg  [10:0] content_w,
	output reg  [10:0] content_h,
	output reg  [10:0] content_x0,
	output reg  [10:0] content_y0,
	output reg  [11:0] h_de,
	output reg  [11:0] v_de,
	output reg  [10:0] coded_w,
	output reg  [10:0] coded_h,
	output reg  [11:0] y_stride,
	output reg  [10:0] chroma_stride,
	output reg  [10:0] display_w,
	output reg  [10:0] display_h,
	output reg  [10:0] present_x,
	output reg  [10:0] present_y,
	output reg  [10:0] crop_left,
	output reg  [10:0] crop_top,
	// q5: display aspect + cadence (parent ABI arbitration #2)
	output reg  [11:0] dar_x,
	output reg  [11:0] dar_y,
	output reg  [7:0]  content_fps,
	output reg         dar_valid,
	output reg         fps_valid,
	output reg         live_valid,
	output reg  [15:0] live_seq,
	output reg  [13:0] live_epoch,
	// B16: sticky — pending staged, not yet promoted (debug / blackout).
	output reg         pending_valid,
	// Pulse 1 clk when pending → live (store geom-epoch bump).
	output reg         promote_pulse,
	// Sticky: rejected commit due to q5 reserved nonzero (debug).
	output reg         q5_reserved_reject,
	// Aspect-path blackout: DAR tuple changed at promote (same-size SAR/DAR).
	// Product: wire into ddr_frame_store/present_core content RGB black.
	// HDMI_BLACKOUT→ascal.swblack is size-only (no-op for same WxH DAR).
	output reg         dar_hold_black
);

	// Match mailbox_abi::kPlxgMagic / plxg_ddr_poller (string-hex "PLXG").
	localparam [31:0] MAGIC_G = 32'h504C_5847;

	reg [63:0] sh0, sh1, sh2, sh3, sh4, sh5;

	// Pending (staged at commit; promoted at frame_boundary).
	reg         pend_win_en, pend_geom_en;
	reg  [10:0] pend_cw, pend_ch, pend_cx0, pend_cy0;
	reg  [11:0] pend_hde, pend_vde;
	reg  [10:0] pend_coded_w, pend_coded_h;
	reg  [11:0] pend_y_stride;
	reg  [10:0] pend_c_stride;
	reg  [10:0] pend_dw, pend_dh, pend_px, pend_py, pend_cl, pend_ct;
	reg  [11:0] pend_dar_x, pend_dar_y;
	reg  [7:0]  pend_fps;
	reg         pend_dar_valid, pend_fps_valid;
	reg  [15:0] pend_seq;
	reg  [13:0] pend_epoch;
	reg  [1:0]  dar_black_vs_left;
	// Blocking flag inside always_ff: DAR-changing promote this cycle.
	reg         dar_chg_promote;

	// DAR tuple change vs current live (ignore first acquire; ignore seq).
	function automatic logic dar_tuple_chg;
		input logic had_live;
		input logic old_v;
		input [11:0] old_x, old_y;
		input logic new_v;
		input [11:0] new_x, new_y;
		begin
			if (!had_live)
				dar_tuple_chg = 1'b0;
			else if (old_v != new_v)
				dar_tuple_chg = 1'b1;
			else if (new_v && ((old_x != new_x) || (old_y != new_y)))
				dar_tuple_chg = 1'b1;
			else
				dar_tuple_chg = 1'b0;
		end
	endfunction

	wire [31:0] sh_magic = sh0[31:0];
	wire [15:0] sh_seq   = sh0[63:48];
	wire [13:0] sh_epoch = sh0[47:34];
	wire        sh_win   = sh0[32];
	wire        sh_geom  = sh0[33];
	wire        magic_ok = (sh_magic == MAGIC_G);

	// q5 reserved [63:34] must be zero (forward-compat trap).
	wire        q5_reserved_nz = |sh5[63:34];
`ifdef PRESENT_GEOM_LATCH_FAULT_IGNORE_Q5_RESERVED
	wire        q5_ok = 1'b1;
`else
	wire        q5_ok = !q5_reserved_nz;
`endif

	// B4: require epoch != 0 so retained DDR after FPGA reset cannot ABA.
`ifdef PRESENT_GEOM_LATCH_FAULT_NO_EPOCH
	wire epoch_ok = 1'b1;
	wire seq_new =
		magic_ok && q5_ok &&
		( (sh_seq != live_seq) || (pending_valid && (sh_seq != pend_seq)) || !live_valid );
`else
	wire epoch_ok = (sh_epoch != 14'd0);
	// Parentheses required: && binds tighter than ||.
	wire seq_new =
		magic_ok && epoch_ok && q5_ok &&
		( (!live_valid && !pending_valid) ||
		  ({sh_epoch, sh_seq} != {live_epoch, live_seq}) ||
		  (pending_valid && ({sh_epoch, sh_seq} != {pend_epoch, pend_seq})) );
`endif

	// Commit attempted with good magic/epoch/seq but bad reserved → sticky reject.
	wire commit_reserved_fault =
		commit && magic_ok && epoch_ok && q5_reserved_nz &&
		( (!live_valid && !pending_valid) ||
		  ({sh_epoch, sh_seq} != {live_epoch, live_seq}) ||
		  (pending_valid && ({sh_epoch, sh_seq} != {pend_epoch, pend_seq})) );

	always_ff @(posedge clk) begin
		if (reset) begin
			sh0 <= 64'd0; sh1 <= 64'd0; sh2 <= 64'd0;
			sh3 <= 64'd0; sh4 <= 64'd0; sh5 <= 64'd0;
			win_enable <= 1'b0;
			geom_enable <= 1'b0;
			content_w <= 11'd0; content_h <= 11'd0;
			content_x0 <= 11'd0; content_y0 <= 11'd0;
			h_de <= 12'd0; v_de <= 12'd0;
			coded_w <= 11'd0; coded_h <= 11'd0;
			y_stride <= 12'd0; chroma_stride <= 11'd0;
			display_w <= 11'd0; display_h <= 11'd0;
			present_x <= 11'd0; present_y <= 11'd0;
			crop_left <= 11'd0; crop_top <= 11'd0;
			dar_x <= 12'd0; dar_y <= 12'd0; content_fps <= 8'd0;
			dar_valid <= 1'b0; fps_valid <= 1'b0;
			live_valid <= 1'b0;
			live_seq <= 16'd0;
			live_epoch <= 14'd0;
			pending_valid <= 1'b0;
			promote_pulse <= 1'b0;
			q5_reserved_reject <= 1'b0;
			pend_win_en <= 1'b0; pend_geom_en <= 1'b0;
			pend_cw <= 11'd0; pend_ch <= 11'd0; pend_cx0 <= 11'd0; pend_cy0 <= 11'd0;
			pend_hde <= 12'd0; pend_vde <= 12'd0;
			pend_coded_w <= 11'd0; pend_coded_h <= 11'd0;
			pend_y_stride <= 12'd0; pend_c_stride <= 11'd0;
			pend_dw <= 11'd0; pend_dh <= 11'd0; pend_px <= 11'd0; pend_py <= 11'd0;
			pend_cl <= 11'd0; pend_ct <= 11'd0;
			pend_dar_x <= 12'd0; pend_dar_y <= 12'd0; pend_fps <= 8'd0;
			pend_dar_valid <= 1'b0; pend_fps_valid <= 1'b0;
			pend_seq <= 16'd0; pend_epoch <= 14'd0;
			dar_hold_black <= 1'b0;
			dar_black_vs_left <= 2'd0;
			dar_chg_promote = 1'b0;
		end else begin
			promote_pulse <= 1'b0;
			// Set on DAR-changing promote; countdown skips that cycle.
			dar_chg_promote = 1'b0;

			if (wr_en) begin
				unique case (wr_idx)
					3'd0: sh0 <= wr_data;
					3'd1: sh1 <= wr_data;
					3'd2: sh2 <= wr_data;
					3'd3: sh3 <= wr_data;
					3'd4: sh4 <= wr_data;
					3'd5: sh5 <= wr_data;
					default: ;
				endcase
			end

			if (commit_reserved_fault)
				q5_reserved_reject <= 1'b1;
			else if (commit && seq_new)
				q5_reserved_reject <= 1'b0; // good commit clears sticky

			// Promote helpers (shadow sh* or pending pend_*).
			// rd-duck: commit && frame_boundary same cycle must NOT lose the new
			// record (old code: boundary read stale pend_*, then pending_valid<=0
			// overwrote commit's stage). Priority:
			//   1) FAULT_IMMEDIATE: always live on commit
			//   2) commit+boundary+seq_new: promote SHADOW directly to live
			//   3) commit only: stage to pending
			//   4) boundary+pending: promote pending
			// FAULT_LOSE_COINCIDENT: restore split ifs (red twin loses record).
`ifdef PRESENT_GEOM_LATCH_FAULT_IMMEDIATE_COMMIT
			if (commit && seq_new) begin
				win_enable     <= sh_win;
				geom_enable    <= sh_geom;
				content_w      <= sh1[10:0];
				content_h      <= sh1[26:16];
				content_x0     <= sh1[42:32];
				content_y0     <= sh1[58:48];
				h_de           <= sh2[11:0];
				v_de           <= sh2[27:16];
				coded_w        <= sh2[42:32];
				coded_h        <= sh2[58:48];
				y_stride       <= sh3[11:0];
				chroma_stride  <= sh3[26:16];
				display_w      <= sh3[42:32];
				display_h      <= sh3[58:48];
				present_x      <= sh4[10:0];
				present_y      <= sh4[26:16];
				crop_left      <= sh4[42:32];
				crop_top       <= sh4[58:48];
				if (dar_tuple_chg(live_valid, dar_valid, dar_x, dar_y,
				                  sh5[32], sh5[11:0], sh5[23:12]))
					dar_chg_promote = 1'b1;
				dar_x          <= sh5[11:0];
				dar_y          <= sh5[23:12];
				content_fps    <= sh5[31:24];
				dar_valid      <= sh5[32];
				fps_valid      <= sh5[33];
				live_seq       <= sh_seq;
				live_epoch     <= sh_epoch;
				live_valid     <= 1'b1;
				pending_valid  <= 1'b0;
				promote_pulse  <= 1'b1;
			end
`elsif PRESENT_GEOM_LATCH_FAULT_LOSE_COINCIDENT
			// RED twin: independent ifs — same-cycle commit+boundary drops new.
			if (commit && seq_new) begin
				pend_win_en    <= sh_win;
				pend_geom_en   <= sh_geom;
				pend_cw        <= sh1[10:0];
				pend_ch        <= sh1[26:16];
				pend_cx0       <= sh1[42:32];
				pend_cy0       <= sh1[58:48];
				pend_hde       <= sh2[11:0];
				pend_vde       <= sh2[27:16];
				pend_coded_w   <= sh2[42:32];
				pend_coded_h   <= sh2[58:48];
				pend_y_stride  <= sh3[11:0];
				pend_c_stride  <= sh3[26:16];
				pend_dw        <= sh3[42:32];
				pend_dh        <= sh3[58:48];
				pend_px        <= sh4[10:0];
				pend_py        <= sh4[26:16];
				pend_cl        <= sh4[42:32];
				pend_ct        <= sh4[58:48];
				pend_dar_x     <= sh5[11:0];
				pend_dar_y     <= sh5[23:12];
				pend_fps       <= sh5[31:24];
				pend_dar_valid <= sh5[32];
				pend_fps_valid <= sh5[33];
				pend_seq       <= sh_seq;
				pend_epoch     <= sh_epoch;
				pending_valid  <= 1'b1;
			end
			if (frame_boundary && pending_valid) begin
				win_enable     <= pend_win_en;
				geom_enable    <= pend_geom_en;
				content_w      <= pend_cw;
				content_h      <= pend_ch;
				content_x0     <= pend_cx0;
				content_y0     <= pend_cy0;
				h_de           <= pend_hde;
				v_de           <= pend_vde;
				coded_w        <= pend_coded_w;
				coded_h        <= pend_coded_h;
				y_stride       <= pend_y_stride;
				chroma_stride  <= pend_c_stride;
				display_w      <= pend_dw;
				display_h      <= pend_dh;
				present_x      <= pend_px;
				present_y      <= pend_py;
				crop_left      <= pend_cl;
				crop_top       <= pend_ct;
				if (dar_tuple_chg(live_valid, dar_valid, dar_x, dar_y,
				                  pend_dar_valid, pend_dar_x, pend_dar_y))
					dar_chg_promote = 1'b1;
				dar_x          <= pend_dar_x;
				dar_y          <= pend_dar_y;
				content_fps    <= pend_fps;
				dar_valid      <= pend_dar_valid;
				fps_valid      <= pend_fps_valid;
				live_seq       <= pend_seq;
				live_epoch     <= pend_epoch;
				live_valid     <= 1'b1;
				pending_valid  <= 1'b0;
				promote_pulse  <= 1'b1;
			end
`else
			if (commit && seq_new && frame_boundary) begin
				// Same-cycle stage+promote from shadow (atomic).
				win_enable     <= sh_win;
				geom_enable    <= sh_geom;
				content_w      <= sh1[10:0];
				content_h      <= sh1[26:16];
				content_x0     <= sh1[42:32];
				content_y0     <= sh1[58:48];
				h_de           <= sh2[11:0];
				v_de           <= sh2[27:16];
				coded_w        <= sh2[42:32];
				coded_h        <= sh2[58:48];
				y_stride       <= sh3[11:0];
				chroma_stride  <= sh3[26:16];
				display_w      <= sh3[42:32];
				display_h      <= sh3[58:48];
				present_x      <= sh4[10:0];
				present_y      <= sh4[26:16];
				crop_left      <= sh4[42:32];
				crop_top       <= sh4[58:48];
				if (dar_tuple_chg(live_valid, dar_valid, dar_x, dar_y,
				                  sh5[32], sh5[11:0], sh5[23:12]))
					dar_chg_promote = 1'b1;
				dar_x          <= sh5[11:0];
				dar_y          <= sh5[23:12];
				content_fps    <= sh5[31:24];
				dar_valid      <= sh5[32];
				fps_valid      <= sh5[33];
				live_seq       <= sh_seq;
				live_epoch     <= sh_epoch;
				live_valid     <= 1'b1;
				pending_valid  <= 1'b0;
				promote_pulse  <= 1'b1;
			end else if (commit && seq_new) begin
				pend_win_en    <= sh_win;
				pend_geom_en   <= sh_geom;
				pend_cw        <= sh1[10:0];
				pend_ch        <= sh1[26:16];
				pend_cx0       <= sh1[42:32];
				pend_cy0       <= sh1[58:48];
				pend_hde       <= sh2[11:0];
				pend_vde       <= sh2[27:16];
				pend_coded_w   <= sh2[42:32];
				pend_coded_h   <= sh2[58:48];
				pend_y_stride  <= sh3[11:0];
				pend_c_stride  <= sh3[26:16];
				pend_dw        <= sh3[42:32];
				pend_dh        <= sh3[58:48];
				pend_px        <= sh4[10:0];
				pend_py        <= sh4[26:16];
				pend_cl        <= sh4[42:32];
				pend_ct        <= sh4[58:48];
				pend_dar_x     <= sh5[11:0];
				pend_dar_y     <= sh5[23:12];
				pend_fps       <= sh5[31:24];
				pend_dar_valid <= sh5[32];
				pend_fps_valid <= sh5[33];
				pend_seq       <= sh_seq;
				pend_epoch     <= sh_epoch;
				pending_valid  <= 1'b1;
			end else if (frame_boundary && pending_valid) begin
				win_enable     <= pend_win_en;
				geom_enable    <= pend_geom_en;
				content_w      <= pend_cw;
				content_h      <= pend_ch;
				content_x0     <= pend_cx0;
				content_y0     <= pend_cy0;
				h_de           <= pend_hde;
				v_de           <= pend_vde;
				coded_w        <= pend_coded_w;
				coded_h        <= pend_coded_h;
				y_stride       <= pend_y_stride;
				chroma_stride  <= pend_c_stride;
				display_w      <= pend_dw;
				display_h      <= pend_dh;
				present_x      <= pend_px;
				present_y      <= pend_py;
				crop_left      <= pend_cl;
				crop_top       <= pend_ct;
				if (dar_tuple_chg(live_valid, dar_valid, dar_x, dar_y,
				                  pend_dar_valid, pend_dar_x, pend_dar_y))
					dar_chg_promote = 1'b1;
				dar_x          <= pend_dar_x;
				dar_y          <= pend_dar_y;
				content_fps    <= pend_fps;
				dar_valid      <= pend_dar_valid;
				fps_valid      <= pend_fps_valid;
				live_seq       <= pend_seq;
				live_epoch     <= pend_epoch;
				live_valid     <= 1'b1;
				pending_valid  <= 1'b0;
				promote_pulse  <= 1'b1;
			end
`endif
			// Aspect-path blackout arm + countdown (not store geom_layout_chg).
`ifdef PRESENT_GEOM_LATCH_FAULT_NO_DAR_BLACKOUT
			dar_hold_black <= 1'b0;
			dar_black_vs_left <= 2'd0;
`else
			if (dar_chg_promote) begin
				dar_hold_black <= 1'b1;
				dar_black_vs_left <= 2'd2;
			end else if (frame_boundary && dar_hold_black) begin
				if (dar_black_vs_left <= 2'd1) begin
					dar_black_vs_left <= 2'd0;
					dar_hold_black <= 1'b0;
				end else begin
					dar_black_vs_left <= dar_black_vs_left - 2'd1;
				end
			end
`endif
		end
	end

endmodule
`default_nettype wire
