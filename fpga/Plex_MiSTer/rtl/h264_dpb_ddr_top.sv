// Product-facing DDR-resident DPB top (fabric decode foundation).
//
// Composes:
//   h264_dpb_slot_mgr     — multi-slot bases in product DPB map
//   h264_dpb_one_ref      — existing MC window walker (byte mem port)
//   h264_dpb_ddr_byte_bridge — byte port -> 64b DDR master
//
// Optional path (separate instance for MC lanes that want burst window fill):
//   h264_dpb_ref_win_cache — on-chip 21x21/9x9 M10K window (2 M10K PREREG)
//
// DDR masters are EXPORTED, not attached to ddr_bus_arbiter3 here.
// w-mem owns arbitration policy; DPB is a new master (proposed m3).
//
// Address map: ddr_frame_layout_params.svh DDR_FRAME_720P_DPB_*
//   phys = DPB_PHYS_BASE + slot * STRIDE; I420 planes match present.
`default_nettype none

module h264_dpb_ddr_top #(
	parameter int FRAME_W = 1280,
	parameter int FRAME_H = 720,
	parameter int NUM_SLOTS = 5,
	parameter int DPB_PHYS_BASE = 32'h3080_0000,
	parameter int DPB_SLOT_STRIDE = 32'h0018_0000
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        idr_start,
	input  wire        frame_done,
	input  wire [15:0] frame_num,

	// Filtered sample write (POST-deblock) into current slot
	input  wire        filtered_sample_valid,
	input  wire [7:0]  filtered_mb_x,
	input  wire [7:0]  filtered_mb_y,
	input  wire [1:0]  filtered_plane,
	input  wire [7:0]  filtered_sample_idx,
	input  wire [7:0]  filtered_sample,

	// MC fetch (uses List0[0] = most recent ref)
	input  wire        fetch_start,
	input  wire [7:0]  fetch_mb_x,
	input  wire [7:0]  fetch_mb_y,
	input  wire [2:0]  fetch_part_mode,
	input  wire [1:0]  fetch_part_idx,
	input  wire [4:0]  fetch_part_w,
	input  wire [4:0]  fetch_part_h,
	input  wire signed [15:0] fetch_mv_x_qpel,
	input  wire signed [15:0] fetch_mv_y_qpel,

	output wire        ref_ready,
	output wire [2:0]  ref_count,
	output wire [31:0] current_base,
	output wire [31:0] reference_base,
	output wire [31:0] ref_base1,
	output wire [31:0] ref_base2,
	output wire [31:0] ref_base3,
	output wire        alloc_error,
	output wire        evict_pulse,

	output wire        fetch_busy,
	output wire        fetch_done,
	output wire        fetch_error_no_ref,
	output wire [1:0]  luma_frac_x,
	output wire [1:0]  luma_frac_y,
	output wire [2:0]  chroma_frac_x,
	output wire [2:0]  chroma_frac_y,
	output wire signed [15:0] luma_origin_x,
	output wire signed [15:0] luma_origin_y,
	output wire signed [15:0] chroma_origin_x,
	output wire signed [15:0] chroma_origin_y,
	output wire        luma_window_valid,
	output wire [8:0]  luma_window_idx,
	output wire [7:0]  luma_window_sample,
	output wire        chroma_u_window_valid,
	output wire        chroma_v_window_valid,
	output wire [6:0]  chroma_window_idx,
	output wire [7:0]  chroma_window_sample,

	// Exported DDR master (single port: bridge muxes RD/WE)
	output wire        ddr_want,
	input  wire        ddr_busy,
	output wire [7:0]  ddr_burstcnt,
	output wire [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output wire        ddr_rd,
	output wire [63:0] ddr_din,
	output wire [7:0]  ddr_be,
	output wire        ddr_we
);
	wire [2:0]  cur_slot;
	wire [31:0] ref0;

	h264_dpb_slot_mgr #(
		.NUM_SLOTS(NUM_SLOTS),
		.DPB_PHYS_BASE(DPB_PHYS_BASE),
		.DPB_SLOT_STRIDE(DPB_SLOT_STRIDE)
	) u_slots (
		.clk(clk),
		.reset(reset),
		.idr_start(idr_start),
		.frame_done(frame_done),
		.frame_num(frame_num),
		.ref_ready(ref_ready),
		.ref_count(ref_count),
		.current_slot(cur_slot),
		.current_base(current_base),
		.ref_base0(ref0),
		.ref_base1(ref_base1),
		.ref_base2(ref_base2),
		.ref_base3(ref_base3),
		.alloc_error(alloc_error),
		.evict_pulse(evict_pulse)
	);

	assign reference_base = ref0;

	// one_ref uses relative BANK0/1 ping-pong — override by driving bases
	// from slot_mgr via parameter 0 and wiring absolute addresses through
	// the write/read path: we instantiate with BANK0=0,BANK1=0 and add
	// current_base/reference_base to the byte addresses at the bridge.
	// Cleaner: feed absolute bases into a thin wrapper.

	wire        mem_we;
	wire [31:0] mem_waddr_rel;
	wire [7:0]  mem_wdata;
	wire        mem_rd;
	wire [31:0] mem_raddr_rel;
	wire [7:0]  mem_rdata;
	wire        mem_rvalid;

	// Local relative DPB: bank0=0, bank1=stride so one_ref ping-pong still
	// works for 2-deep; multi-slot promotion is owned by slot_mgr for bases
	// exposed upstream. For data path we map:
	//   write -> current_base + offset_in_frame
	//   read  -> reference_base + offset_in_frame
	// by stripping one_ref's bank base and re-basing.
	wire [31:0] one_cur;
	wire [31:0] one_refb;

	h264_dpb_one_ref #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.BANK0_BASE(0),
		.BANK1_BASE(FRAME_W * FRAME_H * 3 / 2)
	) u_one (
		.clk(clk),
		.reset(reset),
		.idr_start(idr_start),
		.frame_done(frame_done),
		.ref_ready(), // slot_mgr owns product ref_ready
		.current_base(one_cur),
		.reference_base(one_refb),
		.filtered_sample_valid(filtered_sample_valid),
		.filtered_mb_x(filtered_mb_x),
		.filtered_mb_y(filtered_mb_y),
		.filtered_plane(filtered_plane),
		.filtered_sample_idx(filtered_sample_idx),
		.filtered_sample(filtered_sample),
		.mem_we(mem_we),
		.mem_waddr(mem_waddr_rel),
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
		.mem_raddr(mem_raddr_rel),
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

	// Re-base: subtract one_ref's bank base, add product slot base.
	// mem_waddr_rel is absolute within one_ref banks (0 or FRAME_BYTES+).
	wire [31:0] frame_bytes = FRAME_W * FRAME_H + 2 * ((FRAME_W / 2) * (FRAME_H / 2));
	wire        wr_in_bank1 = (mem_waddr_rel >= frame_bytes);
	wire [31:0] wr_off = wr_in_bank1 ? (mem_waddr_rel - frame_bytes) : mem_waddr_rel;
	// one_ref current_base tracks which relative bank is current; map to slot_mgr
	// current_base always (slot_mgr is source of truth for product slots).
	wire [31:0] mem_waddr_abs = current_base + wr_off;

	wire        rd_in_bank1 = (mem_raddr_rel >= frame_bytes);
	wire [31:0] rd_off = rd_in_bank1 ? (mem_raddr_rel - frame_bytes) : mem_raddr_rel;
	// Reads always from List0[0] product base when ref_ready.
	wire [31:0] mem_raddr_abs = reference_base + rd_off;

	// Gate one_ref's internal ref_ready: force via idr/frame_done on one_ref
	// already; fetch_error_no_ref still comes from one_ref. Align one_ref
	// promotion with slot_mgr by sharing idr_start/frame_done.

	h264_dpb_ddr_byte_bridge u_bridge (
		.clk(clk),
		.reset(reset),
		.mem_we(mem_we),
		.mem_waddr(mem_waddr_abs),
		.mem_wdata(mem_wdata),
		.mem_rd(mem_rd),
		.mem_raddr(mem_raddr_abs),
		.mem_rdata(mem_rdata),
		.mem_rvalid(mem_rvalid),
		.ddr_want(ddr_want),
		.ddr_busy(ddr_busy),
		.ddr_burstcnt(ddr_burstcnt),
		.ddr_addr(ddr_addr),
		.ddr_dout(ddr_dout),
		.ddr_dout_ready(ddr_dout_ready),
		.ddr_rd(ddr_rd),
		.ddr_din(ddr_din),
		.ddr_be(ddr_be),
		.ddr_we(ddr_we)
	);

	// Silence unused
	wire _unused = |{cur_slot, one_cur, one_refb, fetch_part_w, fetch_part_h};
endmodule

`default_nettype wire
