// H.264 Baseline in-loop deblocking filter: macroblock engine (area rewrite).
//
// Same behaviour as the archived engine: normative edge order, bS 0-4, alpha/
// beta/tc0, luma weak+strong paths, chroma p0/q0 only, skip MBs filtered, and
// neighbour strips re-emitted. Storage is M10K with EXPLICIT single read and
// write ports sequenced over cycles — no integer-indexed function RAM reads
// (those trip Quartus VRFX "read to RAM wasn't mapped to a specific read port").
//
// PRE-deblock samples stay private to this engine. Callers keep PRE taps for
// intra/nb_ctx and consume the POST stream for DPB/present.

`default_nettype none

module h264_deblock_mb #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter int MB_W = (FRAME_W + 15) / 16,
	parameter int MB_H = (FRAME_H + 15) / 16
) (
	input  wire              clk,
	input  wire              reset,

	input  wire              slice_start,
	input  wire              disable_deblocking,
	input  wire signed [4:0] slice_alpha_c0_offset,
	input  wire signed [4:0] slice_beta_offset,

	input  wire              mb_start,
	input  wire [7:0]        mb_x,
	input  wire [7:0]        mb_y,
	input  wire              mb_is_intra,
	input  wire [5:0]        mb_qp_y,
	input  wire [5:0]        mb_qp_c,
	input  wire [15:0]       mb_nz_luma,
	input  wire signed [15:0] mb_mv_x,
	input  wire signed [15:0] mb_mv_y,
	input  wire [1:0]        mb_ref_idx,

	input  wire              smp_valid,
	input  wire [8:0]        smp_idx,
	input  wire [7:0]        smp_data,
	input  wire              smp_done,

	output reg               out_valid,
	output reg  [1:0]        out_plane,
	output reg  [15:0]       out_x,
	output reg  [15:0]       out_y,
	output reg  [7:0]        out_data,
	output wire              busy,
	output reg               mb_done
);
	localparam int MB_IDX_W = (MB_W <= 1) ? 1 : $clog2(MB_W);
	localparam int LBY_AW = $clog2(MB_W * 64);
	localparam int LBC_AW = $clog2(MB_W * 32);
	localparam int Y_AW = 9;   // 400 entries
	localparam int C_AW = 8;   // 144 entries

	// Top-level MB FSM
	localparam [3:0] S_IDLE    = 4'd0;
	localparam [3:0] S_RECV    = 4'd1;
	localparam [3:0] S_LOAD    = 4'd2;
	localparam [3:0] S_FGATH   = 4'd3; // issue read addr
	localparam [3:0] S_FCAP    = 4'd4; // capture rdata into tap
	localparam [3:0] S_FFILT   = 4'd5; // one settle for combo edge
	localparam [3:0] S_FSCAT   = 4'd6; // write filtered taps
	localparam [3:0] S_EMIT_A  = 4'd7; // issue emit read
	localparam [3:0] S_EMIT_D  = 4'd8; // drive out_* from rdata
	localparam [3:0] S_STORE   = 4'd9;
	localparam [3:0] S_STORE2  = 4'd10;
	localparam [3:0] S_PROMOTE = 4'd11;

	reg [3:0] state;

	// ------------------------------------------------------------------
	// M10K working windows: 20x20 luma, 12x12 chroma. Skirt at +4.
	// Dual-port: port A = write, port B = read (registered).
	// ------------------------------------------------------------------
	(* ramstyle = "M10K" *) reg [7:0] win_y [0:399];
	(* ramstyle = "M10K" *) reg [7:0] win_u [0:143];
	(* ramstyle = "M10K" *) reg [7:0] win_v [0:143];

	reg               y_we;
	reg [Y_AW-1:0]    y_waddr;
	reg [7:0]         y_wdata;
	reg [Y_AW-1:0]    y_raddr;
	reg [7:0]         y_rdata;

	reg               u_we;
	reg [C_AW-1:0]    u_waddr;
	reg [7:0]         u_wdata;
	reg [C_AW-1:0]    u_raddr;
	reg [7:0]         u_rdata;

	reg               v_we;
	reg [C_AW-1:0]    v_waddr;
	reg [7:0]         v_wdata;
	reg [C_AW-1:0]    v_raddr;
	reg [7:0]         v_rdata;

	always @(posedge clk) begin
		if (y_we) win_y[y_waddr] <= y_wdata;
		y_rdata <= win_y[y_raddr];
		if (u_we) win_u[u_waddr] <= u_wdata;
		u_rdata <= win_u[u_raddr];
		if (v_we) win_v[v_waddr] <= v_wdata;
		v_rdata <= win_v[v_raddr];
	end

	// Upper neighbour line buffers (one MB column of bottom skirt)
	(* ramstyle = "M10K" *) reg [7:0] lb_y [0:(MB_W*64)-1];
	(* ramstyle = "M10K" *) reg [7:0] lb_u [0:(MB_W*32)-1];
	(* ramstyle = "M10K" *) reg [7:0] lb_v [0:(MB_W*32)-1];
	reg               lby_we;
	reg [LBY_AW-1:0]  lby_waddr;
	reg [7:0]         lby_wdata;
	reg [LBY_AW-1:0]  lby_raddr;
	reg [7:0]         lby_rdata;
	reg               lbu_we;
	reg [LBC_AW-1:0]  lbu_waddr;
	reg [7:0]         lbu_wdata;
	reg [LBC_AW-1:0]  lbu_raddr;
	reg [7:0]         lbu_rdata;
	reg               lbv_we;
	reg [LBC_AW-1:0]  lbv_waddr;
	reg [7:0]         lbv_wdata;
	reg [LBC_AW-1:0]  lbv_raddr;
	reg [7:0]         lbv_rdata;

	always @(posedge clk) begin
		if (lby_we) lb_y[lby_waddr] <= lby_wdata;
		lby_rdata <= lb_y[lby_raddr];
		if (lbu_we) lb_u[lbu_waddr] <= lbu_wdata;
		lbu_rdata <= lb_u[lbu_raddr];
		if (lbv_we) lb_v[lbv_waddr] <= lbv_wdata;
		lbv_rdata <= lb_v[lbv_raddr];
	end

	// Neighbour boundary-strength context (small; stay in regs)
	reg              lft_valid;
	reg              lft_intra;
	reg [3:0]        lft_nz;
	reg [5:0]        lft_qp;
	reg [5:0]        lft_qpc;
	reg signed [15:0] lft_mvx;
	reg signed [15:0] lft_mvy;
	reg [1:0]        lft_ref;

	reg              top_valid [0:MB_W-1];
	reg              top_intra [0:MB_W-1];
	reg [3:0]        top_nz    [0:MB_W-1];
	reg [5:0]        top_qp    [0:MB_W-1];
	reg [5:0]        top_qpc   [0:MB_W-1];
	reg signed [15:0] top_mvx  [0:MB_W-1];
	reg signed [15:0] top_mvy  [0:MB_W-1];
	reg [1:0]        top_ref   [0:MB_W-1];

	reg [7:0]        mbx_r, mby_r;
	reg              intra_r;
	reg [5:0]        qpy_r, qpc_r;
	reg [15:0]       nz_r;
	reg signed [15:0] mvx_r, mvy_r;
	reg [1:0]        ref_r;
	reg              use_left, use_top;

	reg [5:0]  fstep;
	reg [9:0]  emit_idx;
	reg [6:0]  seq_idx;
	reg [5:0]  g_i;       // gather/scatter index
	reg        g_phase;   // 0=addr, 1=capture (for load path)

	// Tap registers for one edge segment (4 lanes x 8 samples)
	reg [7:0] tp3 [0:3], tp2 [0:3], tp1 [0:3], tp0 [0:3];
	reg [7:0] tq0 [0:3], tq1 [0:3], tq2 [0:3], tq3 [0:3];

	wire [7:0] ep2 [0:3], ep1 [0:3], ep0 [0:3];
	wire [7:0] eq0 [0:3], eq1 [0:3], eq2 [0:3];
	wire [7:0] e_alpha_u, e_beta_u;
	wire [5:0] e_tc0_u;

	wire [MB_IDX_W-1:0] mbx_idx = mbx_r[MB_IDX_W-1:0];
	wire [7:0] mbx_left8 = (mbx_r == 8'd0) ? 8'd0 : (mbx_r - 8'd1);
	wire [MB_IDX_W-1:0] mbx_left_idx = mbx_left8[MB_IDX_W-1:0];
	wire [15:0] lb_base_y = {8'd0, mbx_idx} * 16'd64;
	wire [15:0] lb_base_c = {8'd0, mbx_idx} * 16'd32;
	wire [15:0] lb_lbase_y = {8'd0, mbx_left_idx} * 16'd64;
	wire [15:0] lb_lbase_c = {8'd0, mbx_left_idx} * 16'd32;

	assign busy = (state != S_IDLE);

	// ------------------------------------------------------------------
	// Edge schedule (same packing as archived engine)
	// ------------------------------------------------------------------
	wire       f_chroma = fstep[5];
	wire       f_horiz  = fstep[4];
	wire [1:0] f_seg    = fstep[1:0];
	wire       f_comp   = fstep[3];
	wire [1:0] f_edge   = f_chroma ? {1'b0, fstep[2]} : fstep[3:2];
	wire [1:0] f_bs_edge = f_chroma ? {fstep[2], 1'b0} : fstep[3:2];
	wire       f_mb_boundary = (f_bs_edge == 2'd0);

	wire [3:0] f_q_blk = f_horiz ? {f_bs_edge, f_seg} : {f_seg, f_bs_edge};
	wire [1:0] f_p_e   = f_bs_edge - 2'd1;
	wire [3:0] f_p_blk = f_horiz ? {f_p_e, f_seg} : {f_seg, f_p_e};

	wire f_q_nz = nz_r[f_q_blk];
	wire f_p_nz_int = nz_r[f_p_blk];
	wire f_top_nz = top_nz[mbx_idx][f_seg];
	wire f_left_nz = lft_nz[f_seg];
	wire f_edge_avail = f_mb_boundary ? (f_horiz ? use_top : use_left) : 1'b1;

	wire              f_p_intra = !f_mb_boundary ? intra_r :
	                              f_horiz ? top_intra[mbx_idx] : lft_intra;
	wire              f_p_nz    = !f_mb_boundary ? f_p_nz_int :
	                              f_horiz ? f_top_nz : f_left_nz;
	wire [1:0]        f_p_ref   = !f_mb_boundary ? ref_r :
	                              f_horiz ? top_ref[mbx_idx] : lft_ref;
	wire signed [15:0] f_p_mvx  = !f_mb_boundary ? mvx_r :
	                              f_horiz ? top_mvx[mbx_idx] : lft_mvx;
	wire signed [15:0] f_p_mvy  = !f_mb_boundary ? mvy_r :
	                              f_horiz ? top_mvy[mbx_idx] : lft_mvy;
	wire [5:0]        f_p_qp    = !f_mb_boundary ? (f_chroma ? qpc_r : qpy_r) :
	                              f_horiz ? (f_chroma ? top_qpc[mbx_idx] : top_qp[mbx_idx]) :
	                                        (f_chroma ? lft_qpc : lft_qp);
	wire [5:0]        f_q_qp    = f_chroma ? qpc_r : qpy_r;
	wire [6:0]        f_qp_sum  = {1'b0, f_p_qp} + {1'b0, f_q_qp} + 7'd1;
	wire [5:0]        f_qp_avg  = f_qp_sum[6:1];

	wire [2:0] f_bs;
	wire       f_bs_unused;
	h264_deblock_bs u_bs (
		.disable_all(disable_deblocking),
		.slice_boundary_blocked(!f_edge_avail),
		.mb_boundary(f_mb_boundary),
		.p_intra(f_p_intra),
		.q_intra(intra_r),
		.p_nonzero(f_p_nz),
		.q_nonzero(f_q_nz),
		.p_ref(f_p_ref),
		.q_ref(ref_r),
		.p_mvx(f_p_mvx[11:0]),
		.p_mvy(f_p_mvy[11:0]),
		.q_mvx(mvx_r[11:0]),
		.q_mvy(mvy_r[11:0]),
		.bs(f_bs),
		.unsupported_ref(f_bs_unused)
	);

	h264_deblock_edge u_edge (
		.is_chroma(f_chroma),
		.bs(f_bs),
		.qp_avg(f_qp_avg),
		.slice_alpha_c0_offset(slice_alpha_c0_offset),
		.slice_beta_offset(slice_beta_offset),
		.p3_in(tp3), .p2_in(tp2), .p1_in(tp1), .p0_in(tp0),
		.q0_in(tq0), .q1_in(tq1), .q2_in(tq2), .q3_in(tq3),
		.p2_out(ep2), .p1_out(ep1), .p0_out(ep0),
		.q0_out(eq0), .q1_out(eq1), .q2_out(eq2),
		.alpha_dbg(e_alpha_u), .beta_dbg(e_beta_u), .tc0_dbg(e_tc0_u)
	);

	// ------------------------------------------------------------------
	// Explicit address helpers (bit-vector only; no RAM inside)
	// Luma window: (y+4)*20 + (x+4), x,y in -4..15
	// Chroma:      (y+4)*12 + (x+4), x,y in -4..7
	// ------------------------------------------------------------------
	wire [5:0] g_edge4 = {4'd0, f_edge} << 2;
	wire [5:0] g_seg4  = {4'd0, f_seg}  << 2;
	wire [5:0] g_seg2  = {4'd0, f_seg}  << 1; // chroma segment * 2

	// Gather index: luma 0..31 (lane*8+tap), chroma 0..15 (lane*8+tap, lane 0..1)
	wire [1:0] g_lane = g_i[4:3];
	wire [2:0] g_tap  = g_i[2:0]; // 0=p3 .. 7=q3
	wire       g_done_luma = (g_i == 6'd31);
	wire       g_done_chr  = (g_i == 6'd15);
	wire       g_gather_done = f_chroma ? g_done_chr : g_done_luma;

	// Signed sample coords for gather/scatter relative to MB
	wire signed [5:0] edge_x0 = $signed({1'b0, g_edge4});
	wire signed [5:0] edge_y0 = $signed({1'b0, g_edge4});
	wire signed [5:0] along_l = f_chroma ? $signed({1'b0, g_seg2}) : $signed({1'b0, g_seg4});

	// tap offset -4..+3
	wire signed [5:0] tap_off = $signed({3'b000, g_tap}) - 6'sd4;

	wire signed [5:0] g_x = f_horiz ? (along_l + $signed({4'b0, g_lane})) : (edge_x0 + tap_off);
	wire signed [5:0] g_y = f_horiz ? (edge_y0 + tap_off) : (along_l + $signed({4'b0, g_lane}));

	// Window addresses from signed coords (x+4, y+4). y*20=(y<<4)+(y<<2), y*12=(y<<3)+(y<<2).
	wire signed [6:0] g_x_p4 = g_x + 7'sd4;
	wire signed [6:0] g_y_p4 = g_y + 7'sd4;
	wire [8:0] g_y20 = {g_y_p4[4:0], 4'b0} + {2'b0, g_y_p4[4:0], 2'b0};
	wire [Y_AW-1:0] g_y_addr = g_y20 + {4'b0, g_x_p4[4:0]};
	wire [7:0] g_yc12 = {g_y_p4[3:0], 3'b0} + {1'b0, g_y_p4[3:0], 2'b0};
	wire [C_AW-1:0] g_c_addr = g_yc12 + {4'b0, g_x_p4[3:0]};

	// Scatter coord decode: g_i counts write slots
	reg [1:0] sc_lane;
	reg [2:0] sc_tap;
	reg       sc_done;
	reg [5:0] sc_sub;
	always @* begin
		sc_sub = 6'd0;
		if (f_chroma) begin
			sc_lane = {1'b0, g_i[1]};
			sc_tap  = g_i[0] ? 3'd4 : 3'd3;
			sc_done = (g_i == 6'd3);
		end else begin
			if (g_i < 6'd6) begin
				sc_lane = 2'd0; sc_sub = g_i;
			end else if (g_i < 6'd12) begin
				sc_lane = 2'd1; sc_sub = g_i - 6'd6;
			end else if (g_i < 6'd18) begin
				sc_lane = 2'd2; sc_sub = g_i - 6'd12;
			end else begin
				sc_lane = 2'd3; sc_sub = g_i - 6'd18;
			end
			sc_tap = 3'd1 + sc_sub[2:0];
			sc_done = (g_i == 6'd23);
		end
	end

	wire signed [5:0] sc_tap_off = $signed({3'b000, sc_tap}) - 6'sd4;
	wire signed [5:0] sc_x = f_horiz ? (along_l + $signed({4'b0, sc_lane})) : (edge_x0 + sc_tap_off);
	wire signed [5:0] sc_y = f_horiz ? (edge_y0 + sc_tap_off) : (along_l + $signed({4'b0, sc_lane}));
	wire signed [6:0] sc_x_p4 = sc_x + 7'sd4;
	wire signed [6:0] sc_y_p4 = sc_y + 7'sd4;
	wire [8:0] sc_y20 = {sc_y_p4[4:0], 4'b0} + {2'b0, sc_y_p4[4:0], 2'b0};
	wire [Y_AW-1:0] sc_y_addr = sc_y20 + {4'b0, sc_x_p4[4:0]};
	wire [7:0] sc_yc12 = {sc_y_p4[3:0], 3'b0} + {1'b0, sc_y_p4[3:0], 2'b0};
	wire [C_AW-1:0] sc_c_addr = sc_yc12 + {4'b0, sc_x_p4[3:0]};

	reg [7:0] sc_data;
	always @* begin
		sc_data = 8'd0;
		case (sc_tap)
		3'd1: sc_data = ep2[sc_lane];
		3'd2: sc_data = ep1[sc_lane];
		3'd3: sc_data = ep0[sc_lane];
		3'd4: sc_data = eq0[sc_lane];
		3'd5: sc_data = eq1[sc_lane];
		3'd6: sc_data = eq2[sc_lane];
		default: sc_data = 8'd0;
		endcase
	end

	// ------------------------------------------------------------------
	// Emit schedule (576 beats) — address only; data one cycle later
	// ------------------------------------------------------------------
	wire [15:0] blx = {4'd0, mbx_r, 4'd0};
	wire [15:0] bly = {4'd0, mby_r, 4'd0};
	wire [15:0] bcx = {5'd0, mbx_r, 3'd0};
	wire [15:0] bcy = {5'd0, mby_r, 3'd0};

	reg [1:0]  e_plane;
	reg [15:0] e_x, e_y;
	reg        e_gate;
	reg [1:0]  e_src; // 0=Y,1=U,2=V
	reg [Y_AW-1:0] e_yaddr;
	reg [C_AW-1:0] e_caddr;

	wire [9:0] em = emit_idx;
	// MB-relative coords for emit
	always @* begin
		e_plane = 2'd0;
		e_x = 16'd0;
		e_y = 16'd0;
		e_gate = 1'b1;
		e_src = 2'd0;
		e_yaddr = 9'd0;
		e_caddr = 8'd0;
		if (em < 10'd256) begin
			// luma MB interior: win (x+4,y+4)
			e_plane = 2'd0;
			e_x = blx + {12'd0, em[3:0]};
			e_y = bly + {12'd0, em[7:4]};
			e_src = 2'd0;
			e_yaddr = ({4'b0, em[7:4]} + 9'd4) * 9'd20 + ({5'b0, em[3:0]} + 9'd4);
		end else if (em < 10'd320) begin
			// luma left strip x=-4..-1, y=0..15 -> win x=0..3, y=4..19
			e_plane = 2'd0;
			e_x = blx - 16'd4 + {14'd0, em[1:0]};
			e_y = bly + {12'd0, em[5:2]};
			e_gate = use_left;
			e_src = 2'd0;
			e_yaddr = ({5'b0, em[5:2]} + 9'd4) * 9'd20 + {7'b0, em[1:0]};
		end else if (em < 10'd384) begin
			// luma top strip y=-4..-1, x=0..15 -> win y=0..3, x=4..19
			e_plane = 2'd0;
			e_x = blx + {12'd0, em[3:0]};
			e_y = bly - 16'd4 + {14'd0, em[5:4]};
			e_gate = use_top;
			e_src = 2'd0;
			e_yaddr = {5'b0, em[5:4]} * 9'd20 + ({5'b0, em[3:0]} + 9'd4);
		end else if (em < 10'd448) begin
			e_plane = 2'd1;
			e_x = bcx + {13'd0, em[2:0]};
			e_y = bcy + {13'd0, em[5:3]};
			e_src = 2'd1;
			e_caddr = ({4'b0, em[5:3]} + 8'd4) * 8'd12 + ({5'b0, em[2:0]} + 8'd4);
		end else if (em < 10'd512) begin
			e_plane = 2'd2;
			e_x = bcx + {13'd0, em[2:0]};
			e_y = bcy + {13'd0, em[5:3]};
			e_src = 2'd2;
			e_caddr = ({4'b0, em[5:3]} + 8'd4) * 8'd12 + ({5'b0, em[2:0]} + 8'd4);
		end else if (em < 10'd528) begin
			e_plane = 2'd1;
			e_x = bcx - 16'd2 + {15'd0, em[0]};
			e_y = bcy + {13'd0, em[3:1]};
			e_gate = use_left;
			e_src = 2'd1;
			e_caddr = ({5'b0, em[3:1]} + 8'd4) * 8'd12 + (8'd2 + {7'b0, em[0]});
		end else if (em < 10'd544) begin
			e_plane = 2'd2;
			e_x = bcx - 16'd2 + {15'd0, em[0]};
			e_y = bcy + {13'd0, em[3:1]};
			e_gate = use_left;
			e_src = 2'd2;
			e_caddr = ({5'b0, em[3:1]} + 8'd4) * 8'd12 + (8'd2 + {7'b0, em[0]});
		end else if (em < 10'd560) begin
			e_plane = 2'd1;
			e_x = bcx + {13'd0, em[2:0]};
			e_y = bcy - 16'd2 + {15'd0, em[3]};
			e_gate = use_top;
			e_src = 2'd1;
			e_caddr = (8'd2 + {7'b0, em[3]}) * 8'd12 + ({5'b0, em[2:0]} + 8'd4);
		end else begin
			e_plane = 2'd2;
			e_x = bcx + {13'd0, em[2:0]};
			e_y = bcy - 16'd2 + {15'd0, em[3]};
			e_gate = use_top;
			e_src = 2'd2;
			e_caddr = (8'd2 + {7'b0, em[3]}) * 8'd12 + ({5'b0, em[2:0]} + 8'd4);
		end
	end

	// Hold emit meta across the read latency cycle
	reg [1:0]  e_plane_d;
	reg [15:0] e_x_d, e_y_d;
	reg        e_gate_d;
	reg [1:0]  e_src_d;

	// RECV address: smp_idx -> window interior
	wire [Y_AW-1:0] recv_y_addr = ({4'b0, smp_idx[7:4]} + 9'd4) * 9'd20 + ({5'b0, smp_idx[3:0]} + 9'd4);
	wire [C_AW-1:0] recv_c_addr = ({4'b0, smp_idx[5:3]} + 8'd4) * 8'd12 + ({5'b0, smp_idx[2:0]} + 8'd4);

	// LOAD top strip from line buffer into window skirt y=0..3 / x=4..19
	wire [3:0] ld_r = seq_idx[5:4];
	wire [3:0] ld_c = seq_idx[3:0];
	wire [Y_AW-1:0] ld_y_waddr = {5'b0, ld_r} * 9'd20 + ({5'b0, ld_c} + 9'd4);
	wire [15:0] ld_y_rdoff = lb_base_y + {10'd0, seq_idx[5:0]};

	wire [1:0] ldc_r = seq_idx[4:3];
	wire [2:0] ldc_c = seq_idx[2:0];
	wire [C_AW-1:0] ld_c_waddr = {6'b0, ldc_r} * 8'd12 + ({5'b0, ldc_c} + 8'd4);
	wire [15:0] ld_c_rdoff = lb_base_c + {11'd0, seq_idx[4:0]};

	// STORE bottom: win y=16..19, x=4..19 -> lb
	wire [1:0] st_r = seq_idx[5:4];
	wire [3:0] st_c = seq_idx[3:0];
	wire [Y_AW-1:0] st_y_raddr = (9'd16 + {7'b0, st_r}) * 9'd20 + ({5'b0, st_c} + 9'd4);
	wire [15:0] st_y_wroff = lb_base_y + {10'd0, seq_idx[5:0]};

	wire [1:0] stc_r = seq_idx[4:3];
	wire [2:0] stc_c = seq_idx[2:0];
	wire [C_AW-1:0] st_c_raddr = (8'd8 + {6'b0, stc_r}) * 8'd12 + ({5'b0, stc_c} + 8'd4);
	wire [15:0] st_c_wroff = lb_base_c + {11'd0, seq_idx[4:0]};

	// PROMOTE right 4 cols -> left skirt (80 luma, 48 chroma beats)
	wire [4:0] pr_row = seq_idx[6:2];
	wire [1:0] pr_col = seq_idx[1:0];
	wire [Y_AW-1:0] pr_rd = {4'b0, pr_row} * 9'd20 + (9'd16 + {7'b0, pr_col});
	wire [Y_AW-1:0] pr_wr = {4'b0, pr_row} * 9'd20 + {7'b0, pr_col};
	wire [3:0] prc_row = seq_idx[5:2];
	wire [1:0] prc_col = seq_idx[1:0];
	wire [C_AW-1:0] prc_rd = {4'b0, prc_row} * 8'd12 + (8'd8 + {6'b0, prc_col});
	wire [C_AW-1:0] prc_wr = {4'b0, prc_row} * 8'd12 + {6'b0, prc_col};

	// STORE2: patch left-MB linebuffer bottom from filtered left skirt
	wire [1:0] s2_r = seq_idx[3:2];
	wire [1:0] s2_c = seq_idx[1:0];
	wire [Y_AW-1:0] s2_y_raddr = (9'd16 + {7'b0, s2_r}) * 9'd20 + {7'b0, s2_c};
	wire [15:0] s2_y_wroff = lb_lbase_y + 16'd12 + {10'd0, s2_r, 4'd0} + {14'd0, s2_c};
	wire [1:0] s2c_r = seq_idx[2:1];
	wire       s2c_c = seq_idx[0];
	wire [C_AW-1:0] s2_c_raddr = (8'd8 + {6'b0, s2c_r}) * 8'd12 + (8'd2 + {7'b0, s2c_c});
	wire [15:0] s2_c_wroff = lb_lbase_c + 16'd6 + {11'd0, s2c_r, 3'd0} + {15'd0, s2c_c};

	integer i;

	always @(posedge clk) begin
		// defaults each cycle
		y_we <= 1'b0; u_we <= 1'b0; v_we <= 1'b0;
		lby_we <= 1'b0; lbu_we <= 1'b0; lbv_we <= 1'b0;
		out_valid <= 1'b0;
		mb_done <= 1'b0;

		if (reset) begin
			state <= S_IDLE;
			fstep <= 6'd0;
			emit_idx <= 10'd0;
			seq_idx <= 7'd0;
			g_i <= 6'd0;
			g_phase <= 1'b0;
			out_plane <= 2'd0;
			out_x <= 16'd0;
			out_y <= 16'd0;
			out_data <= 8'd0;
			lft_valid <= 1'b0;
			lft_intra <= 1'b0;
			lft_nz <= 4'd0;
			lft_qp <= 6'd0;
			lft_qpc <= 6'd0;
			lft_mvx <= 16'sd0;
			lft_mvy <= 16'sd0;
			lft_ref <= 2'd0;
			mbx_r <= 8'd0;
			mby_r <= 8'd0;
			intra_r <= 1'b0;
			qpy_r <= 6'd0;
			qpc_r <= 6'd0;
			nz_r <= 16'd0;
			mvx_r <= 16'sd0;
			mvy_r <= 16'sd0;
			ref_r <= 2'd0;
			use_left <= 1'b0;
			use_top <= 1'b0;
			e_plane_d <= 2'd0;
			e_x_d <= 16'd0;
			e_y_d <= 16'd0;
			e_gate_d <= 1'b0;
			e_src_d <= 2'd0;
			for (i = 0; i < 4; i = i + 1) begin
				tp3[i] <= 8'd0; tp2[i] <= 8'd0; tp1[i] <= 8'd0; tp0[i] <= 8'd0;
				tq0[i] <= 8'd0; tq1[i] <= 8'd0; tq2[i] <= 8'd0; tq3[i] <= 8'd0;
			end
			for (i = 0; i < MB_W; i = i + 1) begin
				top_valid[i] <= 1'b0;
				top_intra[i] <= 1'b0;
				top_nz[i] <= 4'd0;
				top_qp[i] <= 6'd0;
				top_qpc[i] <= 6'd0;
				top_mvx[i] <= 16'sd0;
				top_mvy[i] <= 16'sd0;
				top_ref[i] <= 2'd0;
			end
		end else begin
			if (slice_start) begin
				lft_valid <= 1'b0;
				for (i = 0; i < MB_W; i = i + 1)
					top_valid[i] <= 1'b0;
			end

			case (state)
			S_IDLE: begin
				if (mb_start) begin
					mbx_r <= mb_x;
					mby_r <= mb_y;
					intra_r <= mb_is_intra;
					qpy_r <= mb_qp_y;
					qpc_r <= mb_qp_c;
					nz_r <= mb_nz_luma;
					mvx_r <= mb_mv_x;
					mvy_r <= mb_mv_y;
					ref_r <= mb_ref_idx;
					use_left <= (mb_x != 8'd0) && lft_valid && !disable_deblocking;
					use_top <= (mb_y != 8'd0) && top_valid[mb_x[MB_IDX_W-1:0]] && !disable_deblocking;
					state <= S_RECV;
				end
			end

			S_RECV: begin
				if (smp_valid) begin
					if (smp_idx < 9'd256) begin
						y_we <= 1'b1;
						y_waddr <= recv_y_addr;
						y_wdata <= smp_data;
					end else if (smp_idx < 9'd320) begin
						u_we <= 1'b1;
						u_waddr <= recv_c_addr;
						u_wdata <= smp_data;
					end else begin
						v_we <= 1'b1;
						v_waddr <= recv_c_addr;
						v_wdata <= smp_data;
					end
				end
				if (smp_done) begin
					seq_idx <= 7'd0;
					g_phase <= 1'b0;
					state <= S_LOAD;
				end
			end

			// Two-phase load of top skirt from line buffer into window
			S_LOAD: begin
				if (!g_phase) begin
					// issue LB reads
					lby_raddr <= ld_y_rdoff[LBY_AW-1:0];
					if (!seq_idx[5]) begin
						lbu_raddr <= ld_c_rdoff[LBC_AW-1:0];
						lbv_raddr <= ld_c_rdoff[LBC_AW-1:0];
					end
					g_phase <= 1'b1;
				end else begin
					if (use_top) begin
						y_we <= 1'b1;
						y_waddr <= ld_y_waddr;
						y_wdata <= lby_rdata;
						if (!seq_idx[5]) begin
							u_we <= 1'b1;
							u_waddr <= ld_c_waddr;
							u_wdata <= lbu_rdata;
							v_we <= 1'b1;
							v_waddr <= ld_c_waddr;
							v_wdata <= lbv_rdata;
						end
					end
					g_phase <= 1'b0;
					if (seq_idx == 7'd63) begin
						fstep <= 6'd0;
						g_i <= 6'd0;
						// skip filter entirely when disabled: go emit
						if (disable_deblocking)
							state <= S_EMIT_A;
						else
							state <= S_FGATH;
					end else begin
						seq_idx <= seq_idx + 7'd1;
					end
				end
			end

			// Issue one window read for gather tap
			S_FGATH: begin
				if (!f_edge_avail || (f_bs == 3'd0)) begin
					// nothing to do for this edge segment
					if (fstep == 6'd63) begin
						emit_idx <= 10'd0;
						state <= S_EMIT_A;
					end else begin
						fstep <= fstep + 6'd1;
						g_i <= 6'd0;
					end
				end else begin
					if (!f_chroma) begin
						y_raddr <= g_y_addr;
					end else if (!f_comp) begin
						u_raddr <= g_c_addr;
					end else begin
						v_raddr <= g_c_addr;
					end
					state <= S_FCAP;
				end
			end

			S_FCAP: begin
				// latch into the correct tap/lane
				if (!f_chroma) begin
					case (g_tap)
					3'd0: tp3[g_lane] <= y_rdata;
					3'd1: tp2[g_lane] <= y_rdata;
					3'd2: tp1[g_lane] <= y_rdata;
					3'd3: tp0[g_lane] <= y_rdata;
					3'd4: tq0[g_lane] <= y_rdata;
					3'd5: tq1[g_lane] <= y_rdata;
					3'd6: tq2[g_lane] <= y_rdata;
					default: tq3[g_lane] <= y_rdata;
					endcase
				end else if (!f_comp) begin
					case (g_tap)
					3'd0: tp3[g_lane[0]] <= u_rdata;
					3'd1: tp2[g_lane[0]] <= u_rdata;
					3'd2: tp1[g_lane[0]] <= u_rdata;
					3'd3: tp0[g_lane[0]] <= u_rdata;
					3'd4: tq0[g_lane[0]] <= u_rdata;
					3'd5: tq1[g_lane[0]] <= u_rdata;
					3'd6: tq2[g_lane[0]] <= u_rdata;
					default: tq3[g_lane[0]] <= u_rdata;
					endcase
				end else begin
					case (g_tap)
					3'd0: tp3[g_lane[0]] <= v_rdata;
					3'd1: tp2[g_lane[0]] <= v_rdata;
					3'd2: tp1[g_lane[0]] <= v_rdata;
					3'd3: tp0[g_lane[0]] <= v_rdata;
					3'd4: tq0[g_lane[0]] <= v_rdata;
					3'd5: tq1[g_lane[0]] <= v_rdata;
					3'd6: tq2[g_lane[0]] <= v_rdata;
					default: tq3[g_lane[0]] <= v_rdata;
					endcase
				end
				if (g_gather_done) begin
					// zero unused chroma lanes
					if (f_chroma) begin
						tp3[2] <= 8'd0; tp2[2] <= 8'd0; tp1[2] <= 8'd0; tp0[2] <= 8'd0;
						tq0[2] <= 8'd0; tq1[2] <= 8'd0; tq2[2] <= 8'd0; tq3[2] <= 8'd0;
						tp3[3] <= 8'd0; tp2[3] <= 8'd0; tp1[3] <= 8'd0; tp0[3] <= 8'd0;
						tq0[3] <= 8'd0; tq1[3] <= 8'd0; tq2[3] <= 8'd0; tq3[3] <= 8'd0;
					end
					g_i <= 6'd0;
					state <= S_FFILT;
				end else begin
					g_i <= g_i + 6'd1;
					state <= S_FGATH;
				end
			end

			S_FFILT: begin
				// combo edge sees stable taps; one cycle then scatter
				g_i <= 6'd0;
				state <= S_FSCAT;
			end

			S_FSCAT: begin
				if (!f_chroma) begin
					y_we <= 1'b1;
					y_waddr <= sc_y_addr;
					y_wdata <= sc_data;
				end else if (!f_comp) begin
					u_we <= 1'b1;
					u_waddr <= sc_c_addr;
					u_wdata <= sc_data;
				end else begin
					v_we <= 1'b1;
					v_waddr <= sc_c_addr;
					v_wdata <= sc_data;
				end
				if (sc_done) begin
					if (fstep == 6'd63) begin
						emit_idx <= 10'd0;
						state <= S_EMIT_A;
					end else begin
						fstep <= fstep + 6'd1;
						g_i <= 6'd0;
						state <= S_FGATH;
					end
				end else begin
					g_i <= g_i + 6'd1;
				end
			end

			S_EMIT_A: begin
				// issue read for emit_idx
				e_plane_d <= e_plane;
				e_x_d <= e_x;
				e_y_d <= e_y;
				e_gate_d <= e_gate;
				e_src_d <= e_src;
				if (e_src == 2'd0) y_raddr <= e_yaddr;
				else if (e_src == 2'd1) u_raddr <= e_caddr;
				else v_raddr <= e_caddr;
				state <= S_EMIT_D;
			end

			S_EMIT_D: begin
				out_valid <= e_gate_d;
				out_plane <= e_plane_d;
				out_x <= e_x_d;
				out_y <= e_y_d;
				out_data <= (e_src_d == 2'd0) ? y_rdata :
				            (e_src_d == 2'd1) ? u_rdata : v_rdata;
				if (emit_idx == 10'd575) begin
					seq_idx <= 7'd0;
					g_phase <= 1'b0;
					state <= S_STORE;
				end else begin
					emit_idx <= emit_idx + 10'd1;
					state <= S_EMIT_A;
				end
			end

			// STORE bottom skirt to line buffer (read win, write lb) two-phase
			S_STORE: begin
				if (!g_phase) begin
					y_raddr <= st_y_raddr;
					if (!seq_idx[5]) begin
						u_raddr <= st_c_raddr;
						v_raddr <= st_c_raddr;
					end
					g_phase <= 1'b1;
				end else begin
					lby_we <= 1'b1;
					lby_waddr <= st_y_wroff[LBY_AW-1:0];
					lby_wdata <= y_rdata;
					if (!seq_idx[5]) begin
						lbu_we <= 1'b1;
						lbu_waddr <= st_c_wroff[LBC_AW-1:0];
						lbu_wdata <= u_rdata;
						lbv_we <= 1'b1;
						lbv_waddr <= st_c_wroff[LBC_AW-1:0];
						lbv_wdata <= v_rdata;
					end
					g_phase <= 1'b0;
					if (seq_idx == 7'd63) begin
						seq_idx <= 7'd0;
						state <= S_STORE2;
					end else begin
						seq_idx <= seq_idx + 7'd1;
					end
				end
			end

			S_STORE2: begin
				if (!g_phase) begin
					if (use_left) begin
						y_raddr <= s2_y_raddr;
						if (!seq_idx[3]) begin
							u_raddr <= s2_c_raddr;
							v_raddr <= s2_c_raddr;
						end
					end
					g_phase <= 1'b1;
				end else begin
					if (use_left) begin
						lby_we <= 1'b1;
						lby_waddr <= s2_y_wroff[LBY_AW-1:0];
						lby_wdata <= y_rdata;
						if (!seq_idx[3]) begin
							lbu_we <= 1'b1;
							lbu_waddr <= s2_c_wroff[LBC_AW-1:0];
							lbu_wdata <= u_rdata;
							lbv_we <= 1'b1;
							lbv_waddr <= s2_c_wroff[LBC_AW-1:0];
							lbv_wdata <= v_rdata;
						end
					end
					g_phase <= 1'b0;
					if (seq_idx == 7'd15) begin
						seq_idx <= 7'd0;
						state <= S_PROMOTE;
					end else begin
						seq_idx <= seq_idx + 7'd1;
					end
				end
			end

			// Copy right 4 columns into left skirt for the next MB to the right
			S_PROMOTE: begin
				if (!g_phase) begin
					if (seq_idx < 7'd80) y_raddr <= pr_rd;
					if (seq_idx < 7'd48) begin
						u_raddr <= prc_rd;
						v_raddr <= prc_rd;
					end
					g_phase <= 1'b1;
				end else begin
					if (seq_idx < 7'd80) begin
						y_we <= 1'b1;
						y_waddr <= pr_wr;
						y_wdata <= y_rdata;
					end
					if (seq_idx < 7'd48) begin
						u_we <= 1'b1;
						u_waddr <= prc_wr;
						u_wdata <= u_rdata;
						v_we <= 1'b1;
						v_waddr <= prc_wr;
						v_wdata <= v_rdata;
					end
					g_phase <= 1'b0;
					if (seq_idx == 7'd79) begin
						lft_valid <= 1'b1;
						lft_intra <= intra_r;
						lft_nz <= {nz_r[15], nz_r[11], nz_r[7], nz_r[3]};
						lft_qp <= qpy_r;
						lft_qpc <= qpc_r;
						lft_mvx <= mvx_r;
						lft_mvy <= mvy_r;
						lft_ref <= ref_r;
						top_valid[mbx_idx] <= 1'b1;
						top_intra[mbx_idx] <= intra_r;
						top_nz[mbx_idx] <= nz_r[15:12];
						top_qp[mbx_idx] <= qpy_r;
						top_qpc[mbx_idx] <= qpc_r;
						top_mvx[mbx_idx] <= mvx_r;
						top_mvy[mbx_idx] <= mvy_r;
						top_ref[mbx_idx] <= ref_r;
						mb_done <= 1'b1;
						state <= S_IDLE;
					end else begin
						seq_idx <= seq_idx + 7'd1;
					end
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
