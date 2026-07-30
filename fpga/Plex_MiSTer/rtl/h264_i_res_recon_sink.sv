// I-slice residual → Clip1(pred + residual) MB plane sink.
//
// Phase-2 area base: plane_y + top_row + plane_u + plane_v + top_u + top_v all
// via h264_byte_ram_sp (M10K, registered read: issue → wait → capture). No
// parallel multi-index reads of plane_* or top_* arrays. Serial neighbour
// fetch, serial IQ (shared via EXT_SERIAL_DQ or private for unit tests),
// serial I16 pred, combinational chroma DC hadamard inv (Table 8-15 QPc via
// h264_chroma_qp), one-plane-at-a-time h264_chroma8x8_pred with registered
// above/left/tl neighbours loaded from M10K.
//
// Faults: FAULT_SERIAL_IQ_ZERO / FAULT_SERIAL_I16_PRED_128 / FAULT_SKIP_PLANE_NB.
//
// Chroma bit-exact intent matches docs/evidence/rebase_patches_788/
// chroma_sink_pre_rebase.sv (300/300 UV+Y under EXT_SERIAL_DQ=1).

`default_nettype none

module h264_i_res_recon_sink #(
	parameter int  MAX_PIC_W = 1024,
	parameter bit  FAULT_SERIAL_IQ_ZERO = 1'b0,
	parameter bit  FAULT_SERIAL_I16_PRED_128 = 1'b0,
	parameter bit  FAULT_SKIP_PLANE_NB = 1'b0,
	// EXT_SERIAL_DQ=1: no private mul — product shares one h264_dequant4x4_serial
	parameter bit  EXT_SERIAL_DQ = 1'b0
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        clear,

	input  wire        res_blk_valid,
	output wire        res_blk_ready,
	input  wire [15:0] res_blk_mb_addr,
	input  wire [7:0]  res_blk_mb_x,
	input  wire [7:0]  res_blk_mb_y,
	input  wire [4:0]  res_blk_idx,
	input  wire        res_blk_is_i16,
	input  wire        res_blk_is_luma,
	input  wire [5:0]  res_blk_qp,
	input  wire [4:0]  res_blk_max_coeff,
	input  wire [3:0]  res_blk_pred_mode,
	input  wire signed [15:0] res_blk_coeff [0:15],

	input  wire        res_mb_end,
	input  wire [15:0] res_mb_end_addr,
	input  wire [1:0]  res_mb_chroma_mode,
	input  wire signed [4:0] chroma_qp_index_offset,

	// Shared serial dequant (used when EXT_SERIAL_DQ=1)
	output wire        ext_dq_start,
	output wire signed [15:0] ext_dq_coeff [0:15],
	output wire [5:0]  ext_dq_qp,
	output wire [4:0]  ext_dq_max_coeff,
	input  wire        ext_dq_busy,
	input  wire        ext_dq_done,
	input  wire signed [28:0] ext_dq_dequant [0:15],

	output reg         write_req,
	output reg  [15:0] write_mb_addr,
	output reg  [7:0]  write_y [0:255],
	output reg  [7:0]  write_u [0:63],
	output reg  [7:0]  write_v [0:63],
	input  wire        write_busy,
	output reg  [31:0] dbg_blk_applied,
	output reg  [31:0] dbg_mb_written,
	output reg  [31:0] dbg_luma_nz,
	output reg  [31:0] dbg_chr_applied,
	output wire        drain_idle,

	// Seed neighbours from P-inter reconstruction so Intra-in-P has correct
	// A/B samples (constrained_intra_pred_flag=0 on product clips).
	// Pulse nb_commit when drain_idle; samples = right col + bottom row.
	input  wire        nb_commit,
	input  wire [7:0]  nb_mb_x,
	input  wire [7:0]  nb_mb_y,
	input  wire [7:0]  nb_y_right [0:15],
	input  wire [7:0]  nb_y_bot   [0:15],
	input  wire [7:0]  nb_u_right [0:7],
	input  wire [7:0]  nb_u_bot   [0:7],
	input  wire [7:0]  nb_v_right [0:7],
	input  wire [7:0]  nb_v_bot   [0:7],
	output wire        nb_commit_busy
);
	localparam int MAX_PIC_CW = MAX_PIC_W / 2;
	localparam int TOP_AW = (MAX_PIC_W  <= 1) ? 1 : $clog2(MAX_PIC_W);
	localparam int TCW_AW = (MAX_PIC_CW <= 1) ? 1 : $clog2(MAX_PIC_CW);

	// FSM — 5-bit to hold the chroma-branch additions.
	localparam [4:0]
		ST_IDLE        = 5'd0,
		ST_MB_INIT     = 5'd1,
		ST_SETTLE      = 5'd2,
		ST_I16_NB      = 5'd3,
		ST_I16_START   = 5'd4,
		ST_I16_PRED    = 5'd5,
		ST_HAD_WAIT    = 5'd6,
		ST_HAD_PAINT   = 5'd7,
		ST_I4_NB       = 5'd8,
		ST_IQ_WAIT     = 5'd9,
		ST_APPLY_PX    = 5'd10,
		ST_MB_DUMP_Y   = 5'd11,
		ST_MB_DUMP_U   = 5'd12,
		ST_MB_DUMP_V   = 5'd13,
		ST_MB_FIN      = 5'd14,
		ST_CHR_NB      = 5'd15,
		ST_CHR_START   = 5'd16,
		ST_CHR_WAIT    = 5'd17,
		ST_CHR_PAINT   = 5'd18,
		ST_CHR_DC_ONLY = 5'd19,
		ST_NB_SEED     = 5'd20;

	// I4_NB subphases
	localparam [2:0]
		NB_A0   = 3'd0,
		NB_A1   = 3'd1,
		NB_LEFT = 3'd2,
		NB_TL   = 3'd3,
		NB_DONE = 3'd4;

	// 3-cycle registered RAM read sub-phase: 0=issue, 1=wait, 2=capture
	localparam [1:0] RD_ISSUE = 2'd0, RD_WAIT = 2'd1, RD_CAPT = 2'd2;

	reg [4:0] st;
	reg [8:0] cnt;
	reg [1:0] rd_ph;
	reg       after_init_settle;

	reg        have_mb;
	reg [15:0] cur_mb;
	reg [7:0]  cur_mb_x, cur_mb_y;

	// Luma neighbours (regs — tiny, no multi-index parallel plane reads).
	reg [7:0] left_col [0:15];
	reg [7:0] tl_mb, tl_for_right_mb;
	reg       left_col_v;
	reg [7:0] bot_row [0:15];

	// Chroma neighbours (small regs — plane column/row saved during MB_DUMP).
	reg [7:0] left_u [0:7];
	reg [7:0] left_v [0:7];
	reg [7:0] tl_u, tl_v;
	reg [7:0] tl_u_for_right_mb, tl_v_for_right_mb;
	reg       left_chr_v;
	reg [7:0] bot_row_u [0:7];
	reg [7:0] bot_row_v [0:7];

	// Latched res_blk_* (stable across serial IQ / apply).
	reg        lat_is_i16, lat_is_luma;
	reg [4:0]  lat_idx, lat_max;
	reg [5:0]  lat_qp;
	reg [3:0]  lat_mode;
	reg signed [15:0] lat_coeff [0:15];

	// I16 DC / chroma DC state.
	reg signed [15:0] i16_dc [0:15];
	reg        i16_dc_valid, i16_pred_done;
	reg [15:0] pend_mb_end_addr;
	reg [1:0]  pend_chr_mode;
	reg        pend_mb_end;

	// Chroma pred/DC/AC completion tracking.
	reg        chr_pred_u_done, chr_pred_v_done;
	reg        chr_dc_u_valid, chr_dc_v_valid;
	reg signed [15:0] chr_dc_u [0:3];
	reg signed [15:0] chr_dc_v [0:3];
	reg [3:0]  chr_ac_u_done, chr_ac_v_done;
	reg [1:0]  chr_mode_r;
	reg        chr_mode_valid;
	reg        chr_pred_sel_v;      // 0=U pred pending, 1=V pred pending
	reg        chr_after_pred_apply;// 1=return to ST_SETTLE, 0=return to ST_IDLE
	reg        chr_dc_only_active;  // sticky inject across IQ_WAIT/APPLY_PX
	reg [1:0]  chr_dc_only_bi;
	reg        chr_dc_only_plane;   // 0=U, 1=V
	reg [5:0]  chr_qp_y_hold;       // last qp for qpc at finish

	// Apply-state
	reg [4:0]  apply_i;
	reg        apply_any_nz;
	reg        apply_is_i4;
	reg        apply_is_i16_ac;
	reg        apply_is_chr;
	reg        apply_chr_plane_v;
	reg [1:0]  apply_bx, apply_by;
	reg [7:0]  rmw_addr;

	// ---------------- M10K byte-RAMs ----------------

	reg              py_we;
	reg [7:0]        py_waddr, py_raddr;
	reg [7:0]        py_wdata;
	wire [7:0]       py_q;
	h264_byte_ram_sp #(.DEPTH(256)) u_plane_y (
		.clk(clk), .we(py_we), .waddr(py_waddr), .wdata(py_wdata),
		.raddr(py_raddr), .q(py_q)
	);

	reg              pu_we;
	reg [5:0]        pu_waddr, pu_raddr;
	reg [7:0]        pu_wdata;
	wire [7:0]       pu_q;
	h264_byte_ram_sp #(.DEPTH(64), .AW(6)) u_plane_u (
		.clk(clk), .we(pu_we), .waddr(pu_waddr), .wdata(pu_wdata),
		.raddr(pu_raddr), .q(pu_q)
	);

	reg              pv_we;
	reg [5:0]        pv_waddr, pv_raddr;
	reg [7:0]        pv_wdata;
	wire [7:0]       pv_q;
	h264_byte_ram_sp #(.DEPTH(64), .AW(6)) u_plane_v (
		.clk(clk), .we(pv_we), .waddr(pv_waddr), .wdata(pv_wdata),
		.raddr(pv_raddr), .q(pv_q)
	);

	reg              tr_we;
	reg [TOP_AW-1:0] tr_waddr, tr_raddr;
	reg [7:0]        tr_wdata;
	wire [7:0]       tr_q;
	h264_byte_ram_sp #(.DEPTH(MAX_PIC_W), .AW(TOP_AW)) u_top_row (
		.clk(clk), .we(tr_we), .waddr(tr_waddr), .wdata(tr_wdata),
		.raddr(tr_raddr), .q(tr_q)
	);

	reg              tu_we;
	reg [TCW_AW-1:0] tu_waddr, tu_raddr;
	reg [7:0]        tu_wdata;
	wire [7:0]       tu_q;
	h264_byte_ram_sp #(.DEPTH(MAX_PIC_CW), .AW(TCW_AW)) u_top_u (
		.clk(clk), .we(tu_we), .waddr(tu_waddr), .wdata(tu_wdata),
		.raddr(tu_raddr), .q(tu_q)
	);

	reg              tv_we;
	reg [TCW_AW-1:0] tv_waddr, tv_raddr;
	reg [7:0]        tv_wdata;
	wire [7:0]       tv_q;
	h264_byte_ram_sp #(.DEPTH(MAX_PIC_CW), .AW(TCW_AW)) u_top_v (
		.clk(clk), .we(tv_we), .waddr(tv_waddr), .wdata(tv_wdata),
		.raddr(tv_raddr), .q(tv_q)
	);

	assign res_blk_ready = (st == ST_IDLE) && !write_busy && !pend_mb_end;
	assign drain_idle    = (st == ST_IDLE) && !pend_mb_end && !have_mb;
	assign nb_commit_busy = (st == ST_NB_SEED);

	// ---------------- utility functions ----------------

	function automatic [1:0] blk4_x;
		input [3:0] i;
		case (i)
		4'd0,4'd2,4'd8,4'd10: blk4_x = 2'd0;
		4'd1,4'd3,4'd9,4'd11: blk4_x = 2'd1;
		4'd4,4'd6,4'd12,4'd14: blk4_x = 2'd2;
		default: blk4_x = 2'd3;
		endcase
	endfunction
	function automatic [1:0] blk4_y;
		input [3:0] i;
		case (i)
		4'd0,4'd1,4'd4,4'd5: blk4_y = 2'd0;
		4'd2,4'd3,4'd6,4'd7: blk4_y = 2'd1;
		4'd8,4'd9,4'd12,4'd13: blk4_y = 2'd2;
		default: blk4_y = 2'd3;
		endcase
	endfunction
	function automatic [3:0] blk4_idx;
		input [1:0] bx;
		input [1:0] by;
		case ({by, bx})
		4'b0000: blk4_idx = 4'd0;  4'b0001: blk4_idx = 4'd1;
		4'b0100: blk4_idx = 4'd2;  4'b0101: blk4_idx = 4'd3;
		4'b0010: blk4_idx = 4'd4;  4'b0011: blk4_idx = 4'd5;
		4'b0110: blk4_idx = 4'd6;  4'b0111: blk4_idx = 4'd7;
		4'b1000: blk4_idx = 4'd8;  4'b1001: blk4_idx = 4'd9;
		4'b1100: blk4_idx = 4'd10; 4'b1101: blk4_idx = 4'd11;
		4'b1010: blk4_idx = 4'd12; 4'b1011: blk4_idx = 4'd13;
		4'b1110: blk4_idx = 4'd14; default: blk4_idx = 4'd15;
		endcase
	endfunction
	function automatic [7:0] clip_u8;
		input signed [17:0] v;
		if (v < 18'sd0) clip_u8 = 8'd0;
		else if (v > 18'sd255) clip_u8 = 8'd255;
		else clip_u8 = v[7:0];
	endfunction
	function automatic [7:0] add_res;
		input [7:0] base;
		input signed [28:0] res;
		reg signed [17:0] s;
		s = $signed({10'd0, base}) + res[17:0];
		add_res = clip_u8(s);
	endfunction
	// y,x in 0..15 → y*16+x
	function automatic [7:0] plane_addr_y;
		input [4:0] y;
		input [4:0] x;
		plane_addr_y = {y[3:0], x[3:0]};
	endfunction
	// y,x in 0..7 → y*8+x
	function automatic [5:0] plane_addr_c;
		input [3:0] y;
		input [3:0] x;
		plane_addr_c = {y[2:0], x[2:0]};
	endfunction

	// Chroma-slot classifiers (indices per traverse).
	function automatic is_chr_dc_slot;
		input i16; input [4:0] idx;
		if (i16) is_chr_dc_slot = (idx == 5'd17) || (idx == 5'd18);
		else     is_chr_dc_slot = (idx == 5'd16) || (idx == 5'd17);
	endfunction
	function automatic chr_is_v;
		input i16; input [4:0] idx;
		if (i16) chr_is_v = (idx == 5'd18) || (idx >= 5'd23);
		else     chr_is_v = (idx == 5'd17) || (idx >= 5'd22);
	endfunction
	function automatic [1:0] chr_ac_bi;
		input i16; input [4:0] idx;
		reg [4:0] base;
		begin
			if (i16) base = chr_is_v(i16, idx) ? (idx - 5'd23) : (idx - 5'd19);
			else     base = chr_is_v(i16, idx) ? (idx - 5'd22) : (idx - 5'd18);
			chr_ac_bi = base[1:0];
		end
	endfunction

	// ---------------- I4 neighbours (regs, fed serially) ----------------

	wire [1:0] i4_bx = blk4_x(lat_idx[3:0]);
	wire [1:0] i4_by = blk4_y(lat_idx[3:0]);
	wire [4:0] i4_x0 = {1'b0, i4_bx, 2'b00};
	wire [4:0] i4_y0 = {1'b0, i4_by, 2'b00};
	wire [15:0] abs_x0 = {8'd0, cur_mb_x} * 16'd16 + {11'd0, i4_x0};
	wire i4_ar_ok = (i4_bx != 2'd3) &&
		(blk4_idx(i4_bx + 2'd1, i4_by - 2'd1) < lat_idx[3:0]);

	reg [7:0] i4_above [0:7];
	reg [7:0] i4_left  [0:3];
	reg [7:0] i4_tl;
	reg       i4_ha, i4_hl;

	reg [7:0] i16_above [0:15];
	reg [7:0] i16_left  [0:15];
	reg [7:0] i16_tl;
	reg       i16_ha, i16_hl;
	reg [7:0] i16_above0_cap;

	reg [2:0] nb_ph;
	reg       i4_ar_live_r;

	wire [7:0] i4_pred [0:15];
	wire [3:0] i4_used_mode;
	h264_intra4x4_pred u_i4 (
		.mode(lat_mode), .above(i4_above), .left(i4_left), .top_left(i4_tl),
		.has_above(i4_ha), .has_left(i4_hl), .used_mode(i4_used_mode), .pred(i4_pred)
	);

	reg i16_start;
	wire i16_busy, i16_done, i16_unsup, i16_px_valid;
	wire [7:0] i16_px_addr, i16_px_data;
	h264_intra16x16_pred #(.FAULT_FORCE_128(FAULT_SERIAL_I16_PRED_128)) u_i16 (
		.clk(clk), .reset(reset | clear), .start(i16_start),
		.mode(lat_mode[1:0]), .above(i16_above), .left(i16_left), .top_left(i16_tl),
		.has_above(i16_ha), .has_left(i16_hl),
		.unsupported(i16_unsup), .busy(i16_busy), .done(i16_done),
		.px_valid(i16_px_valid), .px_addr(i16_px_addr), .px_data(i16_px_data)
	);

	// ---------------- Chroma pred (loaded serially from top_u/v M10K) ----------------

	reg [7:0] chr_above [0:7];
	reg [7:0] chr_left  [0:7];
	reg [7:0] chr_tl;
	reg       chr_ha, chr_hl;
	reg       chr_pred_start;
	wire      chr_pred_valid;
	wire [7:0] chr_pred [0:63];
	wire [1:0] chr_pred_mode_w = chr_mode_valid ? chr_mode_r : lat_mode[1:0];

	h264_chroma8x8_pred u_chr_pred (
		.clk(clk),
		.start(chr_pred_start),
		.mode(chr_pred_mode_w),
		.above(chr_above),
		.left(chr_left),
		.top_left(chr_tl),
		.has_above(chr_ha),
		.has_left(chr_hl),
		.valid(chr_pred_valid),
		.pred(chr_pred)
	);

	wire [15:0] chr_abs_x0 = {8'd0, cur_mb_x} * 16'd8;

	// ---------------- Serial IQ + shared/private mux ----------------

	wire signed [28:0] dq_raw [0:15];
	wire signed [28:0] dq_raw_int [0:15];
	wire signed [28:0] idct_r [0:15];
	wire [7:0]         recon_px [0:15];
	wire signed [15:0] dc_had [0:15];
	wire               dq_busy_int, dq_done_int;
	wire               dq_busy, dq_done;
	wire               had_busy, had_done;
	reg                dq_start;
	reg                had_start;

	reg signed [15:0] coeff_for_iq [0:15];
	reg [4:0]         max_for_iq;
	reg [5:0]         qp_for_iq;
	integer           ci;

	assign ext_dq_start     = EXT_SERIAL_DQ ? dq_start : 1'b0;
	assign ext_dq_qp        = qp_for_iq;
	assign ext_dq_max_coeff = max_for_iq;
	genvar g_ext;
	generate
		for (g_ext = 0; g_ext < 16; g_ext = g_ext + 1) begin : g_ext_coeff
			assign ext_dq_coeff[g_ext] = coeff_for_iq[g_ext];
		end
	endgenerate
	assign dq_busy = EXT_SERIAL_DQ ? ext_dq_busy : dq_busy_int;
	assign dq_done = EXT_SERIAL_DQ ? ext_dq_done : dq_done_int;
	generate
		for (g_ext = 0; g_ext < 16; g_ext = g_ext + 1) begin : g_ext_dq
			assign dq_raw[g_ext] = EXT_SERIAL_DQ ? ext_dq_dequant[g_ext]
			                                    : dq_raw_int[g_ext];
		end
	endgenerate

	// QPc: wrapped QP_Y (or held for finish) + offset via Table 8-15.
	wire [5:0] qpc_w;
	h264_chroma_qp u_qpc (
		.qpy((chr_dc_only_active || (st == ST_CHR_DC_ONLY)) ? chr_qp_y_hold : lat_qp),
		.chroma_qp_index_offset(chroma_qp_index_offset),
		.qpc(qpc_w)
	);

	wire signed [15:0] chr_dc_coeff_in [0:3];
	wire signed [15:0] chr_dc_out [0:3];
	assign chr_dc_coeff_in[0] = lat_coeff[0];
	assign chr_dc_coeff_in[1] = lat_coeff[1];
	assign chr_dc_coeff_in[2] = lat_coeff[2];
	assign chr_dc_coeff_in[3] = lat_coeff[3];
	h264_chroma_dc_hadamard_inv u_chr_dc (
		.coeff(chr_dc_coeff_in),
		.qpc(qpc_w),
		.dc_out(chr_dc_out)
	);

	// DC inject at [0] before IDCT (shared for I16 luma AC + chroma AC/DC-only).
	reg use_dc_inject;
	reg signed [15:0] inject_dc;
	wire signed [28:0] dq_for_idct [0:15];
	genvar gi;
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : gen_dq_mux
			if (gi == 0)
				assign dq_for_idct[0] = use_dc_inject ?
					{{13{inject_dc[15]}}, inject_dc} : dq_raw[0];
			else
				assign dq_for_idct[gi] = dq_raw[gi];
		end
	endgenerate

	wire [3:0] i16_ac_scan = lat_idx[3:0] - 4'd1;
	wire [3:0] i16_ac_spat = {blk4_y(i16_ac_scan), blk4_x(i16_ac_scan)};

	always @(*) begin
		for (ci = 0; ci < 16; ci = ci + 1)
			coeff_for_iq[ci] = lat_coeff[ci];
		max_for_iq = lat_max;
		qp_for_iq  = lat_qp;
		use_dc_inject = 1'b0;
		inject_dc  = 16'sd0;

		if (lat_is_i16 && lat_is_luma && lat_idx >= 5'd1 && lat_idx <= 5'd16) begin
			max_for_iq = 5'd15;
			use_dc_inject = i16_dc_valid;
			inject_dc = i16_dc[i16_ac_spat];
		end

		// Chroma AC live: QPc + max15 + DC inject at [0]
		if (!lat_is_luma && !chr_dc_only_active && (st != ST_CHR_DC_ONLY) &&
		    !is_chr_dc_slot(lat_is_i16, lat_idx)) begin
			qp_for_iq = qpc_w;
			max_for_iq = 5'd15;
			use_dc_inject = 1'b1;
			if (chr_is_v(lat_is_i16, lat_idx))
				inject_dc = chr_dc_v_valid ? chr_dc_v[chr_ac_bi(lat_is_i16, lat_idx)]
				                           : 16'sd0;
			else
				inject_dc = chr_dc_u_valid ? chr_dc_u[chr_ac_bi(lat_is_i16, lat_idx)]
				                           : 16'sd0;
		end

		// DC-only finish: serial dequant of zeros + DC inject.
		if (chr_dc_only_active || (st == ST_CHR_DC_ONLY)) begin
			qp_for_iq = qpc_w;
			max_for_iq = 5'd15;
			use_dc_inject = 1'b1;
			for (ci = 0; ci < 16; ci = ci + 1)
				coeff_for_iq[ci] = 16'sd0;
			if (chr_dc_only_plane)
				inject_dc = chr_dc_v_valid ? chr_dc_v[chr_dc_only_bi] : 16'sd0;
			else
				inject_dc = chr_dc_u_valid ? chr_dc_u[chr_dc_only_bi] : 16'sd0;
		end
	end

	generate
		if (!EXT_SERIAL_DQ) begin : g_int_dq
			h264_dequant4x4_serial #(.FAULT_FORCE_ZERO(FAULT_SERIAL_IQ_ZERO)) u_dq (
				.clk(clk), .reset(reset | clear), .start(dq_start),
				.coeff(coeff_for_iq), .qp(qp_for_iq), .max_coeff(max_for_iq),
				.busy(dq_busy_int), .done(dq_done_int), .dequant(dq_raw_int)
			);
		end else begin : g_no_int_dq
			assign dq_busy_int = 1'b0;
			assign dq_done_int = 1'b0;
			genvar gz;
			for (gz = 0; gz < 16; gz = gz + 1) begin : g_z
				assign dq_raw_int[gz] = 29'sd0;
			end
		end
	endgenerate

	h264_idct4x4 u_idct (.dequant(dq_for_idct), .residual(idct_r));
	h264_recon4x4 u_recon (.pred(i4_pred), .residual(idct_r), .recon(recon_px));
	h264_i16_dc_hadamard_serial u_had (
		.clk(clk), .reset(reset | clear), .start(had_start),
		.coeff(lat_coeff), .qp(lat_qp),
		.busy(had_busy), .done(had_done), .dc_out(dc_had)
	);

	// ---------------- Apply-address helpers ----------------

	wire [1:0] apx_y = apply_i[3:2];
	wire [1:0] apx_x = apply_i[1:0];
	// Luma pixel address: (apply_by*4 + apx_y)*16 + (apply_bx*4 + apx_x)
	wire [7:0] apply_addr_y =
		(({6'd0, apply_by} * 8'd4 + {6'd0, apx_y}) << 4) +
		 ({6'd0, apply_bx} * 8'd4 + {6'd0, apx_x});
	// Chroma pixel address: (apply_by[0]*4 + apx_y)*8 + (apply_bx[0]*4 + apx_x)
	wire [5:0] apply_addr_c =
		(({4'd0, apply_by[0]} * 6'd4 + {4'd0, apx_y}) * 6'd8) +
		 ({4'd0, apply_bx[0]} * 6'd4 + {4'd0, apx_x});
	wire [3:0] apply_res_idx = {apx_y, apx_x};

	reg signed [17:0] tsum;
	reg any_nz;
	reg [1:0] cbi;
	reg cplane_v;
	wire any_nz_c = (lat_coeff[0]!=0)||(lat_coeff[1]!=0)||(lat_coeff[2]!=0)||(lat_coeff[3]!=0)
		||(lat_coeff[4]!=0)||(lat_coeff[5]!=0)||(lat_coeff[6]!=0)||(lat_coeff[7]!=0)
		||(lat_coeff[8]!=0)||(lat_coeff[9]!=0)||(lat_coeff[10]!=0)||(lat_coeff[11]!=0)
		||(lat_coeff[12]!=0)||(lat_coeff[13]!=0)||(lat_coeff[14]!=0)||(lat_coeff[15]!=0);

	integer yi, ui, k;

	// ---------------- FSM ----------------

	always @(posedge clk) begin
		write_req <= 1'b0;
		i16_start <= 1'b0;
		dq_start  <= 1'b0;
		had_start <= 1'b0;
		chr_pred_start <= 1'b0;
		py_we <= 1'b0;
		pu_we <= 1'b0;
		pv_we <= 1'b0;
		tr_we <= 1'b0;
		tu_we <= 1'b0;
		tv_we <= 1'b0;

		if (reset || clear) begin
			st <= ST_IDLE;
			cnt <= 9'd0;
			rd_ph <= RD_ISSUE;
			after_init_settle <= 1'b0;
			have_mb <= 1'b0;
			cur_mb <= 16'd0;
			cur_mb_x <= 8'd0;
			cur_mb_y <= 8'd0;
			i16_dc_valid <= 1'b0;
			i16_pred_done <= 1'b0;
			pend_mb_end <= 1'b0;
			pend_mb_end_addr <= 16'd0;
			pend_chr_mode <= 2'd0;
			left_col_v <= 1'b0;
			left_chr_v <= 1'b0;
			tl_mb <= 8'd128;
			tl_for_right_mb <= 8'd128;
			tl_u <= 8'd128;
			tl_v <= 8'd128;
			tl_u_for_right_mb <= 8'd128;
			tl_v_for_right_mb <= 8'd128;
			dbg_blk_applied <= 32'd0;
			dbg_mb_written <= 32'd0;
			dbg_luma_nz <= 32'd0;
			dbg_chr_applied <= 32'd0;
			write_mb_addr <= 16'd0;
			py_raddr <= 8'd0;
			pu_raddr <= 6'd0;
			pv_raddr <= 6'd0;
			tr_raddr <= {TOP_AW{1'b0}};
			tu_raddr <= {TCW_AW{1'b0}};
			tv_raddr <= {TCW_AW{1'b0}};
			apply_i <= 5'd0;
			apply_any_nz <= 1'b0;
			apply_is_i4 <= 1'b0;
			apply_is_i16_ac <= 1'b0;
			apply_is_chr <= 1'b0;
			apply_chr_plane_v <= 1'b0;
			apply_bx <= 2'd0;
			apply_by <= 2'd0;
			chr_pred_u_done <= 1'b0;
			chr_pred_v_done <= 1'b0;
			chr_dc_u_valid <= 1'b0;
			chr_dc_v_valid <= 1'b0;
			chr_ac_u_done <= 4'd0;
			chr_ac_v_done <= 4'd0;
			chr_mode_valid <= 1'b0;
			chr_mode_r <= 2'd0;
			chr_pred_sel_v <= 1'b0;
			chr_after_pred_apply <= 1'b0;
			chr_dc_only_active <= 1'b0;
			chr_dc_only_bi <= 2'd0;
			chr_dc_only_plane <= 1'b0;
			chr_qp_y_hold <= 6'd0;
			chr_ha <= 1'b0;
			chr_hl <= 1'b0;
			chr_tl <= 8'd128;
			nb_ph <= NB_A0;
			i4_ha <= 1'b0;
			i4_hl <= 1'b0;
			i16_ha <= 1'b0;
			i16_hl <= 1'b0;
			i4_ar_live_r <= 1'b0;
			i16_above0_cap <= 8'd128;
			rmw_addr <= 8'd0;
			lat_is_i16 <= 1'b0;
			lat_is_luma <= 1'b1;
			lat_idx <= 5'd0;
			lat_qp <= 6'd0;
			lat_max <= 5'd16;
			lat_mode <= 4'd2;
			for (yi = 0; yi < 256; yi = yi + 1)
				write_y[yi] <= 8'd128;
			for (ui = 0; ui < 64; ui = ui + 1) begin
				write_u[ui] <= 8'd128;
				write_v[ui] <= 8'd128;
			end
			for (ci = 0; ci < 16; ci = ci + 1) begin
				lat_coeff[ci] <= 16'sd0;
				i16_dc[ci] <= 16'sd0;
				left_col[ci] <= 8'd128;
				i16_above[ci] <= 8'd128;
				i16_left[ci] <= 8'd128;
				bot_row[ci] <= 8'd128;
			end
			for (ci = 0; ci < 8; ci = ci + 1) begin
				i4_above[ci] <= 8'd128;
				left_u[ci] <= 8'd128;
				left_v[ci] <= 8'd128;
				bot_row_u[ci] <= 8'd128;
				bot_row_v[ci] <= 8'd128;
				chr_above[ci] <= 8'd128;
				chr_left[ci] <= 8'd128;
			end
			for (ci = 0; ci < 4; ci = ci + 1) begin
				i4_left[ci] <= 8'd128;
				chr_dc_u[ci] <= 16'sd0;
				chr_dc_v[ci] <= 16'sd0;
			end
			i4_tl <= 8'd128;
			i16_tl <= 8'd128;
		end else begin
			if (res_mb_end) begin
				pend_mb_end <= 1'b1;
				pend_mb_end_addr <= res_mb_end_addr;
				pend_chr_mode <= res_mb_chroma_mode;
			end

			case (st)
			//============================================================
			ST_IDLE: begin
				// P-inter neighbour seed (right/bot edges) before any Intra-in-P.
				if (nb_commit && !have_mb && !pend_mb_end && !write_busy) begin
					cur_mb_x <= nb_mb_x;
					cur_mb_y <= nb_mb_y;
					for (ci = 0; ci < 16; ci = ci + 1) begin
						left_col[ci] <= nb_y_right[ci];
						bot_row[ci]  <= nb_y_bot[ci];
					end
					for (ci = 0; ci < 8; ci = ci + 1) begin
						left_u[ci]    <= nb_u_right[ci];
						left_v[ci]    <= nb_v_right[ci];
						bot_row_u[ci] <= nb_u_bot[ci];
						bot_row_v[ci] <= nb_v_bot[ci];
					end
					left_col_v <= 1'b1;
					left_chr_v <= 1'b1;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_NB_SEED;
				end else if (res_blk_valid && res_blk_ready) begin
					if (!have_mb || (res_blk_mb_addr != cur_mb)) begin
						have_mb <= 1'b1;
						cur_mb <= res_blk_mb_addr;
						cur_mb_x <= res_blk_mb_x;
						cur_mb_y <= res_blk_mb_y;
						i16_dc_valid <= 1'b0;
						i16_pred_done <= 1'b0;
						chr_pred_u_done <= 1'b0;
						chr_pred_v_done <= 1'b0;
						chr_dc_u_valid <= 1'b0;
						chr_dc_v_valid <= 1'b0;
						chr_ac_u_done <= 4'd0;
						chr_ac_v_done <= 4'd0;
						chr_mode_valid <= 1'b0;
						chr_mode_r <= 2'd0;
						chr_dc_only_active <= 1'b0;
						for (k = 0; k < 4; k = k + 1) begin
							chr_dc_u[k] <= 16'sd0;
							chr_dc_v[k] <= 16'sd0;
						end
						if (res_blk_mb_x == 8'd0) begin
							left_col_v <= 1'b0;
							left_chr_v <= 1'b0;
						end
						if (res_blk_mb_x != 8'd0 && res_blk_mb_y != 8'd0) begin
							tl_mb <= tl_for_right_mb;
							tl_u  <= tl_u_for_right_mb;
							tl_v  <= tl_v_for_right_mb;
						end else begin
							tl_mb <= 8'd128;
							tl_u  <= 8'd128;
							tl_v  <= 8'd128;
						end
						cnt <= 9'd0;
						after_init_settle <= 1'b1;
						lat_is_i16 <= res_blk_is_i16;
						lat_is_luma <= res_blk_is_luma;
						lat_idx <= res_blk_idx;
						lat_qp <= res_blk_qp;
						lat_max <= res_blk_max_coeff;
						lat_mode <= res_blk_pred_mode;
						chr_qp_y_hold <= res_blk_qp;
						if (!res_blk_is_luma) begin
							chr_mode_r <= res_blk_pred_mode[1:0];
							chr_mode_valid <= 1'b1;
						end
						for (ci = 0; ci < 16; ci = ci + 1)
							lat_coeff[ci] <= res_blk_coeff[ci];
						st <= ST_MB_INIT;
					end else begin
						lat_is_i16 <= res_blk_is_i16;
						lat_is_luma <= res_blk_is_luma;
						lat_idx <= res_blk_idx;
						lat_qp <= res_blk_qp;
						lat_max <= res_blk_max_coeff;
						lat_mode <= res_blk_pred_mode;
						chr_qp_y_hold <= res_blk_qp;
						for (ci = 0; ci < 16; ci = ci + 1)
							lat_coeff[ci] <= res_blk_coeff[ci];

						if (!res_blk_is_luma) begin
							chr_mode_r <= res_blk_pred_mode[1:0];
							chr_mode_valid <= 1'b1;
							cplane_v = chr_is_v(res_blk_is_i16, res_blk_idx);
							if ((cplane_v && !chr_pred_v_done) ||
							    (!cplane_v && !chr_pred_u_done)) begin
								chr_pred_sel_v <= cplane_v;
								chr_after_pred_apply <= 1'b1;
								cnt <= 9'd0;
								rd_ph <= RD_ISSUE;
								st <= ST_CHR_NB;
							end else
								st <= ST_SETTLE;
						end else
							st <= ST_SETTLE;
					end
				end else if (pend_mb_end && !write_busy && have_mb &&
				             (pend_mb_end_addr == cur_mb)) begin
					// MB finish path — first ensure both chroma preds are done,
					// then any missing chroma AC via DC-only, then dump.
					if (!chr_mode_valid) begin
						chr_mode_r <= pend_chr_mode;
						chr_mode_valid <= 1'b1;
					end
					if (!chr_pred_u_done || !chr_pred_v_done) begin
						chr_pred_sel_v <= chr_pred_u_done; // U first then V
						chr_after_pred_apply <= 1'b0;
						cnt <= 9'd0;
						rd_ph <= RD_ISSUE;
						st <= ST_CHR_NB;
					end else if ((chr_dc_u_valid && (chr_ac_u_done != 4'hF)) ||
					             (chr_dc_v_valid && (chr_ac_v_done != 4'hF))) begin
						if (chr_dc_u_valid && (chr_ac_u_done != 4'hF)) begin
							chr_dc_only_plane <= 1'b0;
							if      (!chr_ac_u_done[0]) chr_dc_only_bi <= 2'd0;
							else if (!chr_ac_u_done[1]) chr_dc_only_bi <= 2'd1;
							else if (!chr_ac_u_done[2]) chr_dc_only_bi <= 2'd2;
							else                        chr_dc_only_bi <= 2'd3;
						end else begin
							chr_dc_only_plane <= 1'b1;
							if      (!chr_ac_v_done[0]) chr_dc_only_bi <= 2'd0;
							else if (!chr_ac_v_done[1]) chr_dc_only_bi <= 2'd1;
							else if (!chr_ac_v_done[2]) chr_dc_only_bi <= 2'd2;
							else                        chr_dc_only_bi <= 2'd3;
						end
						lat_is_luma <= 1'b0;
						st <= ST_CHR_DC_ONLY;
					end else begin
						cnt <= 9'd0;
						rd_ph <= RD_ISSUE;
						st <= ST_MB_DUMP_Y;
					end
				end else if (pend_mb_end && !write_busy &&
				             !(have_mb && pend_mb_end_addr == cur_mb)) begin
					// MB end for an MB we never accepted: emit gray.
					write_req <= 1'b1;
					write_mb_addr <= pend_mb_end_addr;
					for (yi = 0; yi < 256; yi = yi + 1)
						write_y[yi] <= 8'd128;
					for (ui = 0; ui < 64; ui = ui + 1) begin
						write_u[ui] <= 8'd128;
						write_v[ui] <= 8'd128;
					end
					dbg_mb_written <= dbg_mb_written + 32'd1;
					pend_mb_end <= 1'b0;
				end
			end

			//============================================================
			ST_MB_INIT: begin
				// Clear plane_y (256 cy). During the first 64 cy also clear
				// plane_u/v — one write to each M10K per cycle.
				if (cnt < 9'd256) begin
					py_we <= 1'b1;
					py_waddr <= cnt[7:0];
					py_wdata <= 8'd128;
					if (cnt < 9'd64) begin
						pu_we <= 1'b1;
						pu_waddr <= cnt[5:0];
						pu_wdata <= 8'd128;
						pv_we <= 1'b1;
						pv_waddr <= cnt[5:0];
						pv_wdata <= 8'd128;
					end
					cnt <= cnt + 9'd1;
				end else begin
					cnt <= 9'd0;
					if (after_init_settle) begin
						after_init_settle <= 1'b0;
						// If first block of MB is chroma with pred still needed,
						// launch chroma NB. Otherwise fall through to SETTLE.
						if (!lat_is_luma) begin
							cplane_v = chr_is_v(lat_is_i16, lat_idx);
							if ((cplane_v && !chr_pred_v_done) ||
							    (!cplane_v && !chr_pred_u_done)) begin
								chr_pred_sel_v <= cplane_v;
								chr_after_pred_apply <= 1'b1;
								rd_ph <= RD_ISSUE;
								st <= ST_CHR_NB;
							end else
								st <= ST_SETTLE;
						end else
							st <= ST_SETTLE;
					end else
						st <= ST_IDLE;
				end
			end

			//============================================================
			ST_SETTLE: begin
				if (lat_is_luma && lat_is_i16 && lat_idx == 5'd0 && !i16_pred_done) begin
					i16_ha <= (cur_mb_y != 8'd0);
					i16_hl <= (cur_mb_x != 8'd0) && left_col_v;
					for (ci = 0; ci < 16; ci = ci + 1) begin
						i16_above[ci] <= 8'd128;
						i16_left[ci] <= ((cur_mb_x != 8'd0) && left_col_v) ?
							left_col[ci] : 8'd128;
					end
					i16_tl <= 8'd128;
					i16_above0_cap <= 8'd128;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					if (FAULT_SKIP_PLANE_NB || (cur_mb_y == 8'd0)) begin
						if ((cur_mb_x != 8'd0) && left_col_v)
							i16_tl <= left_col[0];
						st <= ST_I16_START;
					end else
						st <= ST_I16_NB;
				end else if (lat_is_luma && lat_is_i16 && lat_idx == 5'd0) begin
					had_start <= 1'b1;
					st <= ST_HAD_WAIT;
				end else if (lat_is_luma && lat_is_i16 &&
				             lat_idx >= 5'd1 && lat_idx <= 5'd16) begin
					dq_start <= 1'b1;
					st <= ST_IQ_WAIT;
				end else if (lat_is_luma && !lat_is_i16 && lat_idx < 5'd16) begin
					i4_ha <= 1'b0;
					i4_hl <= 1'b0;
					i4_tl <= 8'd128;
					for (ci = 0; ci < 8; ci = ci + 1) i4_above[ci] <= 8'd128;
					for (ci = 0; ci < 4; ci = ci + 1) i4_left[ci] <= 8'd128;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					nb_ph <= NB_A0;
					i4_ar_live_r <= i4_ar_ok;
					if (FAULT_SKIP_PLANE_NB) begin
						dq_start <= 1'b1;
						st <= ST_IQ_WAIT;
					end else
						st <= ST_I4_NB;
				end else if (!lat_is_luma && is_chr_dc_slot(lat_is_i16, lat_idx)) begin
					// Chroma DC: combinational hadamard_inv; latch into chr_dc_u/v.
					if (chr_is_v(lat_is_i16, lat_idx)) begin
						for (k = 0; k < 4; k = k + 1)
							chr_dc_v[k] <= chr_dc_out[k];
						chr_dc_v_valid <= 1'b1;
					end else begin
						for (k = 0; k < 4; k = k + 1)
							chr_dc_u[k] <= chr_dc_out[k];
						chr_dc_u_valid <= 1'b1;
					end
					dbg_chr_applied <= dbg_chr_applied + 32'd1;
					st <= ST_IDLE;
				end else if (!lat_is_luma) begin
					// Chroma AC: serial dequant + DC inject then ST_APPLY_PX.
					dq_start <= 1'b1;
					st <= ST_IQ_WAIT;
				end else
					st <= ST_IDLE;
			end

			//============================================================
			// top_row → i16_above: 3 cy/sample (issue/wait/capt)
			ST_I16_NB: begin
				if (rd_ph == RD_ISSUE) begin
					if (({8'd0, cur_mb_x} * 16 + {8'd0, cnt[7:0]}) < 32'(MAX_PIC_W))
						tr_raddr <= TOP_AW'(({8'd0, cur_mb_x} * 16 + {8'd0, cnt[7:0]}));
					rd_ph <= RD_WAIT;
				end else if (rd_ph == RD_WAIT) begin
					rd_ph <= RD_CAPT;
				end else begin
					i16_above[cnt[3:0]] <= tr_q;
					if (cnt == 9'd0)
						i16_above0_cap <= tr_q;
					rd_ph <= RD_ISSUE;
					if (cnt == 9'd15) begin
						if (i16_ha && i16_hl)
							i16_tl <= tl_mb;
						else if (i16_ha)
							i16_tl <= (cnt == 9'd0) ? tr_q : i16_above0_cap;
						else if (i16_hl)
							i16_tl <= i16_left[0];
						cnt <= 9'd0;
						st <= ST_I16_START;
					end else
						cnt <= cnt + 9'd1;
				end
			end

			//============================================================
			ST_I16_START: begin
				i16_start <= 1'b1;
				st <= ST_I16_PRED;
			end

			//============================================================
			ST_I16_PRED: begin
				if (i16_px_valid) begin
					py_we <= 1'b1;
					py_waddr <= i16_px_addr;
					py_wdata <= i16_px_data;
				end
				if (i16_done) begin
					i16_pred_done <= 1'b1;
					had_start <= 1'b1;
					st <= ST_HAD_WAIT;
				end
			end

			//============================================================
			ST_HAD_WAIT: begin
				if (had_done) begin
					for (ci = 0; ci < 16; ci = ci + 1)
						i16_dc[ci] <= dc_had[ci];
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_HAD_PAINT;
				end
			end

			//============================================================
			ST_HAD_PAINT: begin
				if (rd_ph == RD_ISSUE) begin
					rmw_addr <= cnt[7:0];
					py_raddr <= cnt[7:0];
					rd_ph <= RD_WAIT;
				end else if (rd_ph == RD_WAIT) begin
					rd_ph <= RD_CAPT;
				end else begin
					tsum = $signed({10'd0, py_q}) +
					       18'(($signed(dc_had[{rmw_addr[7:6], rmw_addr[3:2]}]) + 18'sd32) >>> 6);
					py_we <= 1'b1;
					py_waddr <= rmw_addr;
					py_wdata <= clip_u8(tsum);
					rd_ph <= RD_ISSUE;
					if (cnt == 9'd255) begin
						i16_dc_valid <= 1'b1;
						dbg_blk_applied <= dbg_blk_applied + 32'd1;
						st <= ST_IDLE;
						cnt <= 9'd0;
					end else
						cnt <= cnt + 9'd1;
				end
			end

			//============================================================
			ST_I4_NB: begin
				case (nb_ph)
				NB_A0: begin
					if (i4_by != 2'd0) begin
						i4_ha <= 1'b1;
						if (rd_ph == RD_ISSUE) begin
							py_raddr <= plane_addr_y(i4_y0 - 5'd1, i4_x0 + {3'b0, cnt[1:0]});
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							i4_above[cnt[1:0]] <= py_q;
							rd_ph <= RD_ISSUE;
							if (cnt == 9'd3) begin
								cnt <= 9'd0;
								nb_ph <= NB_A1;
							end else
								cnt <= cnt + 9'd1;
						end
					end else if (cur_mb_y != 8'd0) begin
						i4_ha <= 1'b1;
						if (rd_ph == RD_ISSUE) begin
							if ((abs_x0 + {14'd0, cnt[1:0]}) < MAX_PIC_W[15:0])
								tr_raddr <= TOP_AW'(abs_x0 + {14'd0, cnt[1:0]});
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							i4_above[cnt[1:0]] <= tr_q;
							rd_ph <= RD_ISSUE;
							if (cnt == 9'd3) begin
								cnt <= 9'd0;
								nb_ph <= NB_A1;
							end else
								cnt <= cnt + 9'd1;
						end
					end else begin
						cnt <= 9'd0;
						rd_ph <= RD_ISSUE;
						nb_ph <= NB_LEFT;
					end
				end
				NB_A1: begin
					if (i4_by != 2'd0) begin
						if (i4_ar_live_r) begin
							if (rd_ph == RD_ISSUE) begin
								py_raddr <= plane_addr_y(i4_y0 - 5'd1,
									i4_x0 + 5'd4 + {3'b0, cnt[1:0]});
								rd_ph <= RD_WAIT;
							end else if (rd_ph == RD_WAIT) begin
								rd_ph <= RD_CAPT;
							end else begin
								i4_above[{1'b1, cnt[1:0]}] <= py_q;
								rd_ph <= RD_ISSUE;
								if (cnt == 9'd3) begin
									cnt <= 9'd0;
									nb_ph <= NB_LEFT;
								end else
									cnt <= cnt + 9'd1;
							end
						end else begin
							i4_above[4] <= i4_above[3];
							i4_above[5] <= i4_above[3];
							i4_above[6] <= i4_above[3];
							i4_above[7] <= i4_above[3];
							cnt <= 9'd0;
							rd_ph <= RD_ISSUE;
							nb_ph <= NB_LEFT;
						end
					end else if (cur_mb_y != 8'd0) begin
						if (rd_ph == RD_ISSUE) begin
							if ((abs_x0 + 16'd4 + {14'd0, cnt[1:0]}) < MAX_PIC_W[15:0])
								tr_raddr <= TOP_AW'(abs_x0 + 16'd4 + {14'd0, cnt[1:0]});
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							if ((abs_x0 + 16'd4 + {14'd0, cnt[1:0]}) < MAX_PIC_W[15:0])
								i4_above[{1'b1, cnt[1:0]}] <= tr_q;
							else
								i4_above[{1'b1, cnt[1:0]}] <= i4_above[3];
							rd_ph <= RD_ISSUE;
							if (cnt == 9'd3) begin
								cnt <= 9'd0;
								nb_ph <= NB_LEFT;
							end else
								cnt <= cnt + 9'd1;
						end
					end else begin
						cnt <= 9'd0;
						rd_ph <= RD_ISSUE;
						nb_ph <= NB_LEFT;
					end
				end
				NB_LEFT: begin
					if (i4_bx != 2'd0) begin
						i4_hl <= 1'b1;
						if (rd_ph == RD_ISSUE) begin
							py_raddr <= plane_addr_y(i4_y0 + {3'b0, cnt[1:0]},
								i4_x0 - 5'd1);
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							i4_left[cnt[1:0]] <= py_q;
							rd_ph <= RD_ISSUE;
							if (cnt == 9'd3) begin
								cnt <= 9'd0;
								nb_ph <= NB_TL;
							end else
								cnt <= cnt + 9'd1;
						end
					end else if ((cur_mb_x != 8'd0) && left_col_v) begin
						i4_hl <= 1'b1;
						i4_left[0] <= left_col[i4_y0[3:0] + 4'd0];
						i4_left[1] <= left_col[i4_y0[3:0] + 4'd1];
						i4_left[2] <= left_col[i4_y0[3:0] + 4'd2];
						i4_left[3] <= left_col[i4_y0[3:0] + 4'd3];
						cnt <= 9'd0;
						rd_ph <= RD_ISSUE;
						nb_ph <= NB_TL;
					end else begin
						cnt <= 9'd0;
						rd_ph <= RD_ISSUE;
						nb_ph <= NB_TL;
					end
				end
				NB_TL: begin
					if (i4_ha && i4_hl) begin
						if (i4_bx != 2'd0 && i4_by != 2'd0) begin
							if (rd_ph == RD_ISSUE) begin
								py_raddr <= plane_addr_y(i4_y0 - 5'd1, i4_x0 - 5'd1);
								rd_ph <= RD_WAIT;
							end else if (rd_ph == RD_WAIT) begin
								rd_ph <= RD_CAPT;
							end else begin
								i4_tl <= py_q;
								rd_ph <= RD_ISSUE;
								nb_ph <= NB_DONE;
							end
						end else if (i4_bx != 2'd0 && i4_by == 2'd0) begin
							if (abs_x0 > 0) begin
								if (rd_ph == RD_ISSUE) begin
									tr_raddr <= TOP_AW'(abs_x0 - 16'd1);
									rd_ph <= RD_WAIT;
								end else if (rd_ph == RD_WAIT) begin
									rd_ph <= RD_CAPT;
								end else begin
									i4_tl <= tr_q;
									rd_ph <= RD_ISSUE;
									nb_ph <= NB_DONE;
								end
							end else begin
								i4_tl <= 8'd128;
								nb_ph <= NB_DONE;
							end
						end else if (i4_bx == 2'd0 && i4_by != 2'd0) begin
							i4_tl <= left_col[i4_y0[3:0] - 4'd1];
							nb_ph <= NB_DONE;
						end else begin
							i4_tl <= tl_mb;
							nb_ph <= NB_DONE;
						end
					end else if (i4_ha) begin
						i4_tl <= i4_above[0];
						nb_ph <= NB_DONE;
					end else if (i4_hl) begin
						i4_tl <= i4_left[0];
						nb_ph <= NB_DONE;
					end else
						nb_ph <= NB_DONE;
				end
				default: begin // NB_DONE
					dq_start <= 1'b1;
					st <= ST_IQ_WAIT;
					nb_ph <= NB_A0;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
				end
				endcase
			end

			//============================================================
			ST_IQ_WAIT: begin
				if (dq_done) begin
					any_nz = 1'b0;
					for (ci = 0; ci < 16; ci = ci + 1)
						if (lat_coeff[ci] != 0) any_nz = 1'b1;

					if (chr_dc_only_active) begin
						// apply_* already set in ST_CHR_DC_ONLY
					end else if (!lat_is_luma) begin
						apply_is_chr <= 1'b1;
						apply_is_i4 <= 1'b0;
						apply_is_i16_ac <= 1'b0;
						cbi = chr_ac_bi(lat_is_i16, lat_idx);
						apply_bx <= {1'b0, cbi[0]};
						apply_by <= {1'b0, cbi[1]};
						apply_chr_plane_v <= chr_is_v(lat_is_i16, lat_idx);
						apply_any_nz <= 1'b1;
					end else begin
						apply_is_chr <= 1'b0;
						apply_is_i16_ac <=
							(lat_is_i16 && lat_idx >= 5'd1 && lat_idx <= 5'd16);
						apply_is_i4 <= (!lat_is_i16 && lat_idx < 5'd16);
						if (lat_is_i16 && lat_idx >= 5'd1 && lat_idx <= 5'd16) begin
							apply_bx <= blk4_x(lat_idx[3:0] - 4'd1);
							apply_by <= blk4_y(lat_idx[3:0] - 4'd1);
						end else begin
							apply_bx <= blk4_x(lat_idx[3:0]);
							apply_by <= blk4_y(lat_idx[3:0]);
						end
						apply_any_nz <= any_nz;
					end
					apply_i <= 5'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_APPLY_PX;
				end
			end

			//============================================================
			ST_APPLY_PX: begin
				if (apply_is_chr) begin
					// Chroma RMW into plane_u/v M10K (3-cy per pixel).
					if (rd_ph == RD_ISSUE) begin
						rmw_addr <= {2'd0, apply_addr_c};
						if (apply_chr_plane_v)
							pv_raddr <= apply_addr_c;
						else
							pu_raddr <= apply_addr_c;
						rd_ph <= RD_WAIT;
					end else if (rd_ph == RD_WAIT) begin
						rd_ph <= RD_CAPT;
					end else begin
						if (apply_chr_plane_v) begin
							pv_we <= 1'b1;
							pv_waddr <= rmw_addr[5:0];
							pv_wdata <= add_res(pv_q, idct_r[apply_res_idx]);
						end else begin
							pu_we <= 1'b1;
							pu_waddr <= rmw_addr[5:0];
							pu_wdata <= add_res(pu_q, idct_r[apply_res_idx]);
						end
						rd_ph <= RD_ISSUE;
						if (apply_i == 5'd15) begin
							if (chr_dc_only_active) begin
								if (chr_dc_only_plane)
									chr_ac_v_done[chr_dc_only_bi] <= 1'b1;
								else
									chr_ac_u_done[chr_dc_only_bi] <= 1'b1;
								chr_dc_only_active <= 1'b0;
							end else begin
								cbi = chr_ac_bi(lat_is_i16, lat_idx);
								if (apply_chr_plane_v)
									chr_ac_v_done[cbi] <= 1'b1;
								else
									chr_ac_u_done[cbi] <= 1'b1;
							end
							dbg_chr_applied <= dbg_chr_applied + 32'd1;
							apply_is_chr <= 1'b0;
							apply_i <= 5'd0;
							st <= ST_IDLE;
						end else
							apply_i <= apply_i + 5'd1;
					end
				end else if (apply_is_i16_ac) begin
					// I16 AC RMW into plane_y M10K.
					if (rd_ph == RD_ISSUE) begin
						rmw_addr <= apply_addr_y;
						py_raddr <= apply_addr_y;
						rd_ph <= RD_WAIT;
					end else if (rd_ph == RD_WAIT) begin
						rd_ph <= RD_CAPT;
					end else begin
						if (any_nz_c) begin
							tsum = 18'($signed({10'd0, py_q})
								- 18'(($signed(i16_dc[{apply_by, apply_bx}]) + 18'sd32) >>> 6)
								+ idct_r[apply_res_idx]);
							py_we <= 1'b1;
							py_waddr <= rmw_addr;
							py_wdata <= clip_u8(tsum);
						end
						rd_ph <= RD_ISSUE;
						if (apply_i == 5'd15) begin
							if (apply_any_nz)
								dbg_luma_nz <= dbg_luma_nz + 32'd1;
							dbg_blk_applied <= dbg_blk_applied + 32'd1;
							st <= ST_IDLE;
						end else
							apply_i <= apply_i + 5'd1;
					end
				end else begin
					// I4 straight write into plane_y M10K.
					py_we <= 1'b1;
					py_waddr <= apply_addr_y;
					py_wdata <= any_nz_c ? recon_px[apply_res_idx]
					                     : i4_pred[apply_res_idx];
					if (apply_i == 5'd15) begin
						if (apply_any_nz)
							dbg_luma_nz <= dbg_luma_nz + 32'd1;
						dbg_blk_applied <= dbg_blk_applied + 32'd1;
						st <= ST_IDLE;
					end else
						apply_i <= apply_i + 5'd1;
				end
			end

			//============================================================
			// Chroma NB fetch: 8 above from top_u/v (M10K, 3cy/sample) +
			// left/tl from small regs. chr_pred_sel_v selects plane.
			ST_CHR_NB: begin
				chr_ha <= (cur_mb_y != 8'd0);
				chr_hl <= (cur_mb_x != 8'd0) && left_chr_v;
				if (FAULT_SKIP_PLANE_NB || (cur_mb_y == 8'd0)) begin
					// No above from top_u/v — leave chr_above at 128 (regs already).
					chr_ha <= 1'b0;
					for (ci = 0; ci < 8; ci = ci + 1) chr_above[ci] <= 8'd128;
					if ((cur_mb_x != 8'd0) && left_chr_v) begin
						chr_hl <= 1'b1;
						for (ci = 0; ci < 8; ci = ci + 1)
							chr_left[ci] <= chr_pred_sel_v ? left_v[ci] : left_u[ci];
						chr_tl <= chr_pred_sel_v ? left_v[0] : left_u[0];
					end else begin
						for (ci = 0; ci < 8; ci = ci + 1) chr_left[ci] <= 8'd128;
						chr_tl <= 8'd128;
					end
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_CHR_START;
				end else if (rd_ph == RD_ISSUE) begin
					if ((chr_abs_x0 + {13'd0, cnt[2:0]}) < MAX_PIC_CW[15:0]) begin
						if (chr_pred_sel_v)
							tv_raddr <= TCW_AW'(chr_abs_x0 + {13'd0, cnt[2:0]});
						else
							tu_raddr <= TCW_AW'(chr_abs_x0 + {13'd0, cnt[2:0]});
					end
					rd_ph <= RD_WAIT;
				end else if (rd_ph == RD_WAIT) begin
					rd_ph <= RD_CAPT;
				end else begin
					chr_above[cnt[2:0]] <= chr_pred_sel_v ? tv_q : tu_q;
					rd_ph <= RD_ISSUE;
					if (cnt == 9'd7) begin
						// Load left/tl from tiny regs on the same cycle we finish above.
						if ((cur_mb_x != 8'd0) && left_chr_v) begin
							for (ci = 0; ci < 8; ci = ci + 1)
								chr_left[ci] <= chr_pred_sel_v ? left_v[ci] : left_u[ci];
						end else begin
							for (ci = 0; ci < 8; ci = ci + 1) chr_left[ci] <= 8'd128;
						end
						// TL selection: MB corner from tl_u/tl_v snapshot; else
						// derive from what is available (matches pre-rebase combo).
						if ((cur_mb_y != 8'd0) &&
						    (cur_mb_x != 8'd0) && left_chr_v)
							chr_tl <= chr_pred_sel_v ? tl_v : tl_u;
						else if (cur_mb_y != 8'd0)
							chr_tl <= chr_pred_sel_v ? tv_q : tu_q; // above[0]
						else if ((cur_mb_x != 8'd0) && left_chr_v)
							chr_tl <= chr_pred_sel_v ? left_v[0] : left_u[0];
						else
							chr_tl <= 8'd128;
						cnt <= 9'd0;
						st <= ST_CHR_START;
					end else
						cnt <= cnt + 9'd1;
				end
			end

			//============================================================
			ST_CHR_START: begin
				chr_pred_start <= 1'b1;
				cnt <= 9'd0;
				st <= ST_CHR_WAIT;
			end

			//============================================================
			ST_CHR_WAIT: begin
				if (chr_pred_valid) begin
					cnt <= 9'd0;
					st <= ST_CHR_PAINT;
				end
			end

			//============================================================
			// Paint chr_pred[0..63] into plane_u/v M10K (1 write per cy).
			ST_CHR_PAINT: begin
				if (chr_pred_sel_v) begin
					pv_we <= 1'b1;
					pv_waddr <= cnt[5:0];
					pv_wdata <= chr_pred[cnt[5:0]];
				end else begin
					pu_we <= 1'b1;
					pu_waddr <= cnt[5:0];
					pu_wdata <= chr_pred[cnt[5:0]];
				end
				if (cnt == 9'd63) begin
					if (chr_pred_sel_v)
						chr_pred_v_done <= 1'b1;
					else
						chr_pred_u_done <= 1'b1;
					cnt <= 9'd0;
					if (chr_after_pred_apply)
						st <= ST_SETTLE;
					else
						st <= ST_IDLE;
				end else
					cnt <= cnt + 9'd1;
			end

			//============================================================
			ST_CHR_DC_ONLY: begin
				chr_dc_only_active <= 1'b1;
				apply_is_chr <= 1'b1;
				apply_is_i4 <= 1'b0;
				apply_is_i16_ac <= 1'b0;
				apply_chr_plane_v <= chr_dc_only_plane;
				apply_bx <= {1'b0, chr_dc_only_bi[0]};
				apply_by <= {1'b0, chr_dc_only_bi[1]};
				apply_any_nz <= 1'b1;
				apply_i <= 5'd0;
				rd_ph <= RD_ISSUE;
				dq_start <= 1'b1;
				st <= ST_IQ_WAIT;
			end

			//============================================================
			// Dump plane_y M10K → write_y + capture left_col/bot_row/tl_for_right,
			// then write 16 bytes to top_row.
			ST_MB_DUMP_Y: begin
				if (cnt < 9'd256) begin
					if (rd_ph == RD_ISSUE) begin
						py_raddr <= cnt[7:0];
						rd_ph <= RD_WAIT;
					end else if (rd_ph == RD_WAIT) begin
						rd_ph <= RD_CAPT;
					end else begin
						write_y[cnt[7:0]] <= py_q;
						if (cnt[3:0] == 4'd15)
							left_col[cnt[7:4]] <= py_q;
						if (cnt[7:4] == 4'd15)
							bot_row[cnt[3:0]] <= py_q;
						rd_ph <= RD_ISSUE;
						cnt <= cnt + 9'd1;
					end
				end else if (cnt == 9'd256) begin
					// Snapshot top_row[mbx*16+15] BEFORE overwrite as TL for right MB.
					if (cur_mb_y != 8'd0 &&
					    (({8'd0, cur_mb_x} * 16 + 16'd15) < MAX_PIC_W[15:0])) begin
						if (rd_ph == RD_ISSUE) begin
							tr_raddr <= TOP_AW'(({8'd0, cur_mb_x} * 16 + 16'd15));
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							tl_for_right_mb <= tr_q;
							rd_ph <= RD_ISSUE;
							cnt <= 9'd257;
						end
					end else begin
						tl_for_right_mb <= 8'd128;
						rd_ph <= RD_ISSUE;
						cnt <= 9'd257;
					end
				end else if (cnt < 9'd273) begin
					// cnt 257..272 → write 16 top_row bytes (index cnt-257)
					tr_we <= 1'b1;
					tr_waddr <= TOP_AW'(({8'd0, cur_mb_x} * 16 + 16'(cnt - 9'd257)));
					tr_wdata <= bot_row[4'(cnt - 9'd257)];
					cnt <= cnt + 9'd1;
				end else begin
					left_col_v <= 1'b1;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_MB_DUMP_U;
				end
			end

			//============================================================
			// Dump plane_u M10K → write_u + capture left_u/bot_row_u/tl_u_for_right,
			// then write 8 bytes to top_u.
			ST_MB_DUMP_U: begin
				if (cnt < 9'd64) begin
					if (rd_ph == RD_ISSUE) begin
						pu_raddr <= cnt[5:0];
						rd_ph <= RD_WAIT;
					end else if (rd_ph == RD_WAIT) begin
						rd_ph <= RD_CAPT;
					end else begin
						write_u[cnt[5:0]] <= pu_q;
						if (cnt[2:0] == 3'd7)
							left_u[cnt[5:3]] <= pu_q;
						if (cnt[5:3] == 3'd7)
							bot_row_u[cnt[2:0]] <= pu_q;
						rd_ph <= RD_ISSUE;
						cnt <= cnt + 9'd1;
					end
				end else if (cnt == 9'd64) begin
					// Snapshot top_u[mbx*8+7] BEFORE overwrite.
					if (cur_mb_y != 8'd0 &&
					    (({8'd0, cur_mb_x} * 8 + 16'd7) < MAX_PIC_CW[15:0])) begin
						if (rd_ph == RD_ISSUE) begin
							tu_raddr <= TCW_AW'(({8'd0, cur_mb_x} * 8 + 16'd7));
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							tl_u_for_right_mb <= tu_q;
							rd_ph <= RD_ISSUE;
							cnt <= 9'd65;
						end
					end else begin
						tl_u_for_right_mb <= 8'd128;
						rd_ph <= RD_ISSUE;
						cnt <= 9'd65;
					end
				end else if (cnt < 9'd73) begin
					// cnt 65..72 → write 8 top_u bytes (index cnt-65)
					if ((({8'd0, cur_mb_x} * 8 + 16'(cnt - 9'd65))) < MAX_PIC_CW[15:0]) begin
						tu_we <= 1'b1;
						tu_waddr <= TCW_AW'(({8'd0, cur_mb_x} * 8 + 16'(cnt - 9'd65)));
						tu_wdata <= bot_row_u[3'(cnt - 9'd65)];
					end
					cnt <= cnt + 9'd1;
				end else begin
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_MB_DUMP_V;
				end
			end

			//============================================================
			ST_MB_DUMP_V: begin
				if (cnt < 9'd64) begin
					if (rd_ph == RD_ISSUE) begin
						pv_raddr <= cnt[5:0];
						rd_ph <= RD_WAIT;
					end else if (rd_ph == RD_WAIT) begin
						rd_ph <= RD_CAPT;
					end else begin
						write_v[cnt[5:0]] <= pv_q;
						if (cnt[2:0] == 3'd7)
							left_v[cnt[5:3]] <= pv_q;
						if (cnt[5:3] == 3'd7)
							bot_row_v[cnt[2:0]] <= pv_q;
						rd_ph <= RD_ISSUE;
						cnt <= cnt + 9'd1;
					end
				end else if (cnt == 9'd64) begin
					if (cur_mb_y != 8'd0 &&
					    (({8'd0, cur_mb_x} * 8 + 16'd7) < MAX_PIC_CW[15:0])) begin
						if (rd_ph == RD_ISSUE) begin
							tv_raddr <= TCW_AW'(({8'd0, cur_mb_x} * 8 + 16'd7));
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							tl_v_for_right_mb <= tv_q;
							rd_ph <= RD_ISSUE;
							cnt <= 9'd65;
						end
					end else begin
						tl_v_for_right_mb <= 8'd128;
						rd_ph <= RD_ISSUE;
						cnt <= 9'd65;
					end
				end else if (cnt < 9'd73) begin
					if ((({8'd0, cur_mb_x} * 8 + 16'(cnt - 9'd65))) < MAX_PIC_CW[15:0]) begin
						tv_we <= 1'b1;
						tv_waddr <= TCW_AW'(({8'd0, cur_mb_x} * 8 + 16'(cnt - 9'd65)));
						tv_wdata <= bot_row_v[3'(cnt - 9'd65)];
					end
					cnt <= cnt + 9'd1;
				end else begin
					left_chr_v <= 1'b1;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_MB_FIN;
				end
			end

			//============================================================
			ST_MB_FIN: begin
				write_req <= 1'b1;
				write_mb_addr <= cur_mb;
				dbg_mb_written <= dbg_mb_written + 32'd1;
				have_mb <= 1'b0;
				i16_dc_valid <= 1'b0;
				i16_pred_done <= 1'b0;
				pend_mb_end <= 1'b0;
				chr_pred_u_done <= 1'b0;
				chr_pred_v_done <= 1'b0;
				chr_dc_u_valid <= 1'b0;
				chr_dc_v_valid <= 1'b0;
				chr_ac_u_done <= 4'd0;
				chr_ac_v_done <= 4'd0;
				chr_mode_valid <= 1'b0;
				chr_dc_only_active <= 1'b0;
				st <= ST_IDLE;
			end

			// Seed top_row/top_u/top_v from P-inter bottom edges (M10K write).
			// left_* already loaded on entry. Snapshot TL-for-right like MB_DUMP.
			ST_NB_SEED: begin
				if (cnt == 9'd0) begin
					// Snapshot top_row[mbx*16+15] BEFORE overwrite as TL for right.
					if (cur_mb_y != 8'd0 &&
					    (({8'd0, cur_mb_x} * 16 + 16'd15) < MAX_PIC_W[15:0])) begin
						if (rd_ph == RD_ISSUE) begin
							tr_raddr <= TOP_AW'(({8'd0, cur_mb_x} * 16 + 16'd15));
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							tl_for_right_mb <= tr_q;
							rd_ph <= RD_ISSUE;
							cnt <= 9'd1;
						end
					end else begin
						tl_for_right_mb <= 8'd128;
						rd_ph <= RD_ISSUE;
						cnt <= 9'd1;
					end
				end else if (cnt < 9'd17) begin
					// cnt 1..16 → write 16 top_row bytes
					tr_we <= 1'b1;
					tr_waddr <= TOP_AW'(({8'd0, cur_mb_x} * 16 + 16'(cnt - 9'd1)));
					tr_wdata <= bot_row[4'(cnt - 9'd1)];
					cnt <= cnt + 9'd1;
				end else if (cnt == 9'd17) begin
					if (cur_mb_y != 8'd0 &&
					    (({8'd0, cur_mb_x} * 8 + 16'd7) < MAX_PIC_CW[15:0])) begin
						if (rd_ph == RD_ISSUE) begin
							tu_raddr <= TCW_AW'(({8'd0, cur_mb_x} * 8 + 16'd7));
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							tl_u_for_right_mb <= tu_q;
							rd_ph <= RD_ISSUE;
							cnt <= 9'd18;
						end
					end else begin
						tl_u_for_right_mb <= 8'd128;
						rd_ph <= RD_ISSUE;
						cnt <= 9'd18;
					end
				end else if (cnt < 9'd26) begin
					// cnt 18..25 → write 8 top_u
					if ((({8'd0, cur_mb_x} * 8 + 16'(cnt - 9'd18))) < MAX_PIC_CW[15:0]) begin
						tu_we <= 1'b1;
						tu_waddr <= TCW_AW'(({8'd0, cur_mb_x} * 8 + 16'(cnt - 9'd18)));
						tu_wdata <= bot_row_u[3'(cnt - 9'd18)];
					end
					cnt <= cnt + 9'd1;
				end else if (cnt == 9'd26) begin
					if (cur_mb_y != 8'd0 &&
					    (({8'd0, cur_mb_x} * 8 + 16'd7) < MAX_PIC_CW[15:0])) begin
						if (rd_ph == RD_ISSUE) begin
							tv_raddr <= TCW_AW'(({8'd0, cur_mb_x} * 8 + 16'd7));
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							tl_v_for_right_mb <= tv_q;
							rd_ph <= RD_ISSUE;
							cnt <= 9'd27;
						end
					end else begin
						tl_v_for_right_mb <= 8'd128;
						rd_ph <= RD_ISSUE;
						cnt <= 9'd27;
					end
				end else if (cnt < 9'd35) begin
					// cnt 27..34 → write 8 top_v
					if ((({8'd0, cur_mb_x} * 8 + 16'(cnt - 9'd27))) < MAX_PIC_CW[15:0]) begin
						tv_we <= 1'b1;
						tv_waddr <= TCW_AW'(({8'd0, cur_mb_x} * 8 + 16'(cnt - 9'd27)));
						tv_wdata <= bot_row_v[3'(cnt - 9'd27)];
					end
					cnt <= cnt + 9'd1;
				end else begin
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_IDLE;
				end
			end

			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
