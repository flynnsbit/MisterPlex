// Product DPB reference commit path.
//
// Closes the reference lifecycle that decode_stub previously short-circuited with
// a diagnostic I420 pattern:
//
//   reconstructed MB samples (genuine decoded)
//     → h264_deblock_mb (in-loop filter; PRE kept private to the engine)
//     → h264_dpb_one_ref current bank (POST-deblock samples only)
//     → h264_deblock_writeback_ctrl frame-boundary promotion
//     → subsequent P fetches from the promoted reference bank
//
// PRE/POST contract (matches decode_core consumer rules):
//   PRE  — smp_* into deblock_mb only. Neighbour/intra context must never read
//          the DPB write stream from this module.
//   POST — filtered_sample_* into DPB only. MC fetch reads reference_base after
//          ref_ready is promoted at a true frame boundary.
//
// Bandwidth (already budgeted at 987 B/MB):
//   write 384 B/MB (+ ≤192 B/MB neighbour strip rewrites from deblock emit)
//   fetch 441+81+81 = 603 B/MB for full 16x16 qpel/epel windows
//   total ≤ ~1.2 kB/MB worst-case strip rewrite ≈ 35 MB/s @25fps 1170 MB —
//   still DDR-first; SDRAM remains the documented escape hatch.
//
// Interaction with parallel lanes:
//   sv-mvd supplies real MVs into fetch_mv_*_qpel — this module is MV-agnostic.
//   sv-resadd supplies residual into the recon sample stream — this module is
//   residual-agnostic. Reference content correctness does not depend on either.
//
// Fault injection (Verilator mutation twins only):
//   H264_DPB_FAULT_SKIP_DEBLOCK     — store PRE samples (must fail filtered scoreboard)
//   H264_DPB_FAULT_EARLY_PROMOTE    — promote on terminal MB commit, not frame_boundary
//   H264_DPB_FAULT_NO_IDR_INVALIDATE — drop idr_start into the DPB (must fail IDR check)

`default_nettype none

module h264_dpb_ref_commit #(
	parameter int FRAME_W = 624,
	parameter int FRAME_H = 480,
	parameter int MB_COUNT = ((FRAME_W + 15) / 16) * ((FRAME_H + 15) / 16),
	parameter int BANK0_BASE = 0,
	parameter int BANK1_BASE = (FRAME_W * FRAME_H + 2 * ((FRAME_W / 2) * (FRAME_H / 2))),
	parameter int MB_AW = (MB_COUNT <= 1) ? 1 : $clog2(MB_COUNT)
)(
	input  wire               clk,
	input  wire               reset,

	// Slice / picture controls
	input  wire               slice_start,
	input  wire               idr_frame_start,
	input  wire               disable_deblocking,
	input  wire signed [4:0]  slice_alpha_c0_offset,
	input  wire signed [4:0]  slice_beta_offset,
	input  wire               frame_boundary,

	// Reconstructed MB handoff (genuine decoded samples, raster 384)
	input  wire               recon_mb_start,
	input  wire [7:0]         recon_mb_x,
	input  wire [7:0]         recon_mb_y,
	input  wire [MB_AW-1:0]   recon_mb_addr,
	input  wire               recon_mb_is_ref,
	input  wire               recon_mb_is_intra,
	input  wire               recon_frame_done,
	input  wire [5:0]         recon_qp_y,
	input  wire [5:0]         recon_qp_c,
	input  wire [15:0]        recon_nz_luma,
	input  wire signed [15:0] recon_mv_x,
	input  wire signed [15:0] recon_mv_y,
	input  wire [1:0]         recon_ref_idx,
	input  wire               recon_sample_valid,
	input  wire [8:0]         recon_sample_idx,
	input  wire [7:0]         recon_sample,
	input  wire               recon_sample_done,

	// DPB status
	output wire               ref_ready,
	output wire [31:0]        current_base,
	output wire [31:0]        reference_base,
	output wire               ref_ready_pulse,
	output wire               wb_valid,
	output wire [MB_AW-1:0]   wb_mb_addr,
	output wire               commit_order_error,
	output wire               dpb_invalidate_refs,
	output wire               deblock_busy,
	output wire               deblock_mb_done,

	// External memory ports (current/reference banks)
	output wire               mem_we,
	output wire [31:0]        mem_waddr,
	output wire [7:0]         mem_wdata,
	output wire               mem_rd,
	output wire [31:0]        mem_raddr,
	input  wire [7:0]         mem_rdata,
	input  wire               mem_rvalid,

	// MC fetch request / response (product h264_dpb_one_ref contract)
	input  wire               fetch_start,
	input  wire [7:0]         fetch_mb_x,
	input  wire [7:0]         fetch_mb_y,
	input  wire [2:0]         fetch_part_mode,
	input  wire [1:0]         fetch_part_idx,
	input  wire [4:0]         fetch_part_w,
	input  wire [4:0]         fetch_part_h,
	input  wire signed [15:0] fetch_mv_x_qpel,
	input  wire signed [15:0] fetch_mv_y_qpel,
	output wire               fetch_busy,
	output wire               fetch_done,
	output wire               fetch_error_no_ref,
	output wire [1:0]         luma_frac_x,
	output wire [1:0]         luma_frac_y,
	output wire [2:0]         chroma_frac_x,
	output wire [2:0]         chroma_frac_y,
	output wire signed [15:0] luma_origin_x,
	output wire signed [15:0] luma_origin_y,
	output wire signed [15:0] chroma_origin_x,
	output wire signed [15:0] chroma_origin_y,
	output wire               luma_window_valid,
	output wire [8:0]         luma_window_idx,
	output wire [7:0]         luma_window_sample,
	output wire               chroma_u_window_valid,
	output wire               chroma_v_window_valid,
	output wire [6:0]         chroma_window_idx,
	output wire [7:0]         chroma_window_sample
);
	// ── In-loop deblock ──────────────────────────────────────────────────
	wire        dbf_out_valid;
	wire [1:0]  dbf_out_plane;
	wire [15:0] dbf_out_x;
	wire [15:0] dbf_out_y;
	wire [7:0]  dbf_out_data;
	wire        dbf_busy;
	wire        dbf_mb_done;

	h264_deblock_mb #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H)
	) u_deblock (
		.clk(clk),
		.reset(reset),
		.slice_start(slice_start),
		.disable_deblocking(disable_deblocking),
		.slice_alpha_c0_offset(slice_alpha_c0_offset),
		.slice_beta_offset(slice_beta_offset),
		.mb_start(recon_mb_start),
		.mb_x(recon_mb_x),
		.mb_y(recon_mb_y),
		.mb_is_intra(recon_mb_is_intra),
		.mb_qp_y(recon_qp_y),
		.mb_qp_c(recon_qp_c),
		.mb_nz_luma(recon_nz_luma),
		.mb_mv_x(recon_mv_x),
		.mb_mv_y(recon_mv_y),
		.mb_ref_idx(recon_ref_idx),
		.smp_valid(recon_sample_valid),
		.smp_idx(recon_sample_idx),
		.smp_data(recon_sample),
		.smp_done(recon_sample_done),
		.out_valid(dbf_out_valid),
		.out_plane(dbf_out_plane),
		.out_x(dbf_out_x),
		.out_y(dbf_out_y),
		.out_data(dbf_out_data),
		.busy(dbf_busy),
		.mb_done(dbf_mb_done)
	);

	assign deblock_busy = dbf_busy;
	assign deblock_mb_done = dbf_mb_done;

	// Absolute deblock emit → MB-relative DPB write addressing.
	wire [7:0] dbf_mb_x = (dbf_out_plane == 2'd0) ? dbf_out_x[11:4] : dbf_out_x[10:3];
	wire [7:0] dbf_mb_y = (dbf_out_plane == 2'd0) ? dbf_out_y[11:4] : dbf_out_y[10:3];
	wire [7:0] dbf_sample_idx = (dbf_out_plane == 2'd0) ?
	                            {dbf_out_y[3:0], dbf_out_x[3:0]} :
	                            {2'd0, dbf_out_y[2:0], dbf_out_x[2:0]};

	// PRE path for skip-deblock fault / disable_deblocking identity store.
	// When disable_deblocking is set the engine still runs multi-cycle but
	// leaves samples unchanged; product still waits on mb_done. The SKIP
	// fault deliberately bypasses the engine so the mutation is visible.
	wire [1:0] pre_plane = (recon_sample_idx < 9'd256) ? 2'd0 :
	                       (recon_sample_idx < 9'd320) ? 2'd1 : 2'd2;
	wire [8:0] pre_u_idx = recon_sample_idx - 9'd256;
	wire [8:0] pre_v_idx = recon_sample_idx - 9'd320;
	wire [7:0] pre_sample_idx = (pre_plane == 2'd0) ? recon_sample_idx[7:0] :
	                            (pre_plane == 2'd1) ? pre_u_idx[7:0] :
	                                                   pre_v_idx[7:0];

`ifdef H264_DPB_FAULT_SKIP_DEBLOCK
	wire        dpb_sample_valid = recon_sample_valid;
	wire [7:0]  dpb_mb_x         = recon_mb_x;
	wire [7:0]  dpb_mb_y         = recon_mb_y;
	wire [1:0]  dpb_plane        = pre_plane;
	wire [7:0]  dpb_sample_idx_w = pre_sample_idx;
	wire [7:0]  dpb_sample       = recon_sample;
	wire        dpb_mb_commit    = recon_sample_done;
`else
	wire        dpb_sample_valid = dbf_out_valid;
	wire [7:0]  dpb_mb_x         = dbf_mb_x;
	wire [7:0]  dpb_mb_y         = dbf_mb_y;
	wire [1:0]  dpb_plane        = dbf_out_plane;
	wire [7:0]  dpb_sample_idx_w = dbf_sample_idx;
	wire [7:0]  dpb_sample       = dbf_out_data;
	wire        dpb_mb_commit    = dbf_mb_done;
`endif

	// Count POST samples so writeback_ctrl sees 384 filtered beats before commit.
	// Deblock emit can exceed 384 (neighbour strips); only the first 384 unique
	// in-MB samples are counted toward the commit barrier. Strip rewrites still
	// hit the DPB (idempotent).
	localparam int SAMPLE_W = $clog2(384 + 1);
	reg [SAMPLE_W-1:0] post_count;
	reg                mb_samples_complete;
	wire               in_mb_sample =
		dpb_sample_valid &&
		(dpb_mb_x == recon_mb_x) &&
		(dpb_mb_y == recon_mb_y);

	always @(posedge clk) begin
		if (reset || recon_mb_start) begin
			post_count <= '0;
			mb_samples_complete <= 1'b0;
		end else begin
			if (in_mb_sample && !mb_samples_complete) begin
				if (post_count == SAMPLE_W'(383))
					mb_samples_complete <= 1'b1;
				else
					post_count <= post_count + 1'b1;
			end
			if (dpb_mb_commit)
				mb_samples_complete <= 1'b0;
		end
	end

	// Writeback controller owns promotion / IDR invalidate.
	wire        wb_is_ref_unused;
	wire [1:0]  ref_ready_slot_unused;
	wire        ctrl_ref_ready_pulse;
	wire        ctrl_invalidate;

	// filtered_sample_valid for the controller counts every POST beat that is
	// part of the 384-sample MB body (neighbour strip rewrites are not counted).
	wire ctrl_sample_valid = in_mb_sample && !mb_samples_complete;
	wire ctrl_mb_valid = dpb_mb_commit && (mb_samples_complete || (post_count == SAMPLE_W'(383)));

`ifdef H264_DPB_FAULT_EARLY_PROMOTE
	// Promote immediately when the terminal MB commits — skips frame_boundary.
	wire ctrl_frame_boundary = 1'b0;
	wire force_early_pulse = ctrl_mb_valid && recon_frame_done && recon_mb_is_ref;
`else
	wire ctrl_frame_boundary = frame_boundary;
	wire force_early_pulse = 1'b0;
`endif

	h264_deblock_writeback_ctrl #(
		.MB_COUNT(MB_COUNT),
		.MB_AW(MB_AW),
		.FRAME_SLOT_W(2),
		.SAMPLES_PER_MB(384)
	) u_wb_ctrl (
		.clk(clk),
		.reset(reset),
		.idr_frame_start(idr_frame_start),
		.filtered_sample_valid(ctrl_sample_valid),
		.filtered_mb_valid(ctrl_mb_valid),
		.filtered_mb_addr(recon_mb_addr),
		.filtered_mb_is_ref(recon_mb_is_ref),
		.filtered_frame_done(recon_frame_done),
		.frame_slot_i(2'd0),
		.frame_boundary(ctrl_frame_boundary),
		.wb_valid(wb_valid),
		.wb_mb_addr(wb_mb_addr),
		.wb_is_ref(wb_is_ref_unused),
		.dpb_invalidate_refs(ctrl_invalidate),
		.ref_ready_pulse(ctrl_ref_ready_pulse),
		.ref_ready_slot(ref_ready_slot_unused),
		.commit_order_error(commit_order_error)
	);

	assign dpb_invalidate_refs = ctrl_invalidate;
	assign ref_ready_pulse = ctrl_ref_ready_pulse | force_early_pulse;

	// One-cycle delayed promote so terminal commit strictly precedes ref_ready
	// (matches the established deblock-DPB seam scoreboard).
	reg promote_pulse_d1;
	always @(posedge clk) begin
		if (reset)
			promote_pulse_d1 <= 1'b0;
		else
			promote_pulse_d1 <= ref_ready_pulse;
	end

`ifdef H264_DPB_FAULT_NO_IDR_INVALIDATE
	wire dpb_idr = 1'b0;
`else
	wire dpb_idr = ctrl_invalidate | idr_frame_start;
`endif

	h264_dpb_one_ref #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.BANK0_BASE(BANK0_BASE),
		.BANK1_BASE(BANK1_BASE)
	) u_dpb (
		.clk(clk),
		.reset(reset),
		.idr_start(dpb_idr),
		.frame_done(promote_pulse_d1),
		.ref_ready(ref_ready),
		.current_base(current_base),
		.reference_base(reference_base),
		.filtered_sample_valid(dpb_sample_valid),
		.filtered_mb_x(dpb_mb_x),
		.filtered_mb_y(dpb_mb_y),
		.filtered_plane(dpb_plane),
		.filtered_sample_idx(dpb_sample_idx_w),
		.filtered_sample(dpb_sample),
		.mem_we(mem_we),
		.mem_waddr(mem_waddr),
		.mem_wdata(mem_wdata),
		.fetch_start(fetch_start),
		.fetch_mb_x(fetch_mb_x),
		.fetch_mb_y(fetch_mb_y),
		.fetch_part_mode(fetch_part_mode),
		.fetch_part_idx(fetch_part_idx),
		.fetch_part_w(fetch_part_w),
		.fetch_part_h(fetch_part_h),
		.fetch_mv_x_qpel(fetch_mv_x_qpel),
		.fetch_mv_y_qpel(fetch_mv_y_qpel),
		.fetch_busy(fetch_busy),
		.fetch_done(fetch_done),
		.fetch_error_no_ref(fetch_error_no_ref),
		.luma_frac_x(luma_frac_x),
		.luma_frac_y(luma_frac_y),
		.chroma_frac_x(chroma_frac_x),
		.chroma_frac_y(chroma_frac_y),
		.luma_origin_x(luma_origin_x),
		.luma_origin_y(luma_origin_y),
		.chroma_origin_x(chroma_origin_x),
		.chroma_origin_y(chroma_origin_y),
		.mem_rd(mem_rd),
		.mem_raddr(mem_raddr),
		.mem_rdata(mem_rdata),
		.mem_rvalid(mem_rvalid),
		.luma_window_valid(luma_window_valid),
		.luma_window_idx(luma_window_idx),
		.luma_window_sample(luma_window_sample),
		.chroma_u_window_valid(chroma_u_window_valid),
		.chroma_v_window_valid(chroma_v_window_valid),
		.chroma_window_idx(chroma_window_idx),
		.chroma_window_sample(chroma_window_sample)
	);
endmodule

`default_nettype wire
