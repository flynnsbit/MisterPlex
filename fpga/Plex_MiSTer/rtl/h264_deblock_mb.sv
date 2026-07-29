// H.264 Baseline in-loop deblocking filter: macroblock engine.
//
// Consumes one reconstructed macroblock as a 384 sample stream (the same
// ordering the writeback path uses: 256 luma raster, 64 Cb, 64 Cr), filters it
// in normative order (all four vertical luma edges left to right, then all four
// horizontal luma edges top to bottom, chroma at two edges each direction) and
// re-emits the filtered window as an absolute (plane, x, y, sample) stream.
//
// The emitted window is wider than the macroblock: filtering edge 0 of a
// macroblock modifies samples that belong to the left / upper neighbour, so the
// engine re-emits those strips. Downstream writes are idempotent, so re-writing
// a strip with its final value is exactly what the loop filter needs.
//
// PRE-deblock samples are NOT disturbed: this engine owns private copies. The
// intra prediction neighbour context in the decode core keeps reading the
// PRE-deblock reconstruction, while the DPB / present writes take this
// POST-deblock stream.
//
// Skipped macroblocks are filtered like any other: the caller simply presents
// their reconstruction (pure motion compensation, no residual) with
// mb_nz_luma == 0, which still yields bS 1 whenever the motion vectors or the
// reference index differ across the edge.

`default_nettype none

module h264_deblock_mb #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter int MB_W = (FRAME_W + 15) / 16,
	parameter int MB_H = (FRAME_H + 15) / 16
) (
	input  wire              clk,
	input  wire              reset,

	// Slice level context. slice_start drops the neighbour availability so the
	// first macroblock of a slice never filters against stale samples.
	input  wire              slice_start,
	input  wire              disable_deblocking,
	input  wire signed [4:0] slice_alpha_c0_offset,
	input  wire signed [4:0] slice_beta_offset,

	// Macroblock metadata, sampled on mb_start.
	input  wire              mb_start,
	input  wire [7:0]        mb_x,
	input  wire [7:0]        mb_y,
	input  wire              mb_is_intra,
	input  wire [5:0]        mb_qp_y,
	input  wire [5:0]        mb_qp_c,
	input  wire [15:0]       mb_nz_luma,   // bit (y4*4 + x4) set when that 4x4 has coefficients
	input  wire signed [15:0] mb_mv_x,
	input  wire signed [15:0] mb_mv_y,
	input  wire [1:0]        mb_ref_idx,

	// Reconstructed sample stream in.
	input  wire              smp_valid,
	input  wire [8:0]        smp_idx,
	input  wire [7:0]        smp_data,
	input  wire              smp_done,

	// Filtered sample stream out.
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

	localparam [2:0] S_IDLE   = 3'd0;
	localparam [2:0] S_RECV   = 3'd1;
	localparam [2:0] S_LOAD   = 3'd2;
	localparam [2:0] S_FILT   = 3'd3;
	localparam [2:0] S_EMIT   = 3'd4;
	localparam [2:0] S_STORE  = 3'd5;
	localparam [2:0] S_STORE2 = 3'd6;

	reg [2:0] state;

	// Working window. Packed vectors (not unpacked arrays) so Quartus cannot
	// infer single-port M10K.  The gather always@* and the neighbour-copy
	// for-loops issue many parallel runtime-indexed reads; an unpacked array
	// becomes a RAM and Verific dies with "read to RAM wasn't mapped to a
	// specific read port".  Packed bit-selects are plain muxes in fabric.
	// Layout is still raster: sample i lives at bits [8*i+7 : 8*i].
	reg [8*256-1:0] wy;  // 16x16 luma MB
	reg [8*64-1:0]  wu;  // 8x8 Cb
	reg [8*64-1:0]  wv;  // 8x8 Cr
	reg [8*64-1:0]  ly;  // left luma strip 16x4
	reg [8*32-1:0]  lu;  // left Cb strip 8x4
	reg [8*32-1:0]  lv;
	reg [8*64-1:0]  ty;  // top luma strip 4x16
	reg [8*32-1:0]  tu;  // top Cb strip 4x8
	reg [8*32-1:0]  tv;

	// Byte lane helpers for the packed windows.
	function automatic [7:0] pb(input [8*256-1:0] pack, input integer idx);
		pb = pack[8*idx +: 8];
	endfunction
	function automatic [7:0] pb64(input [8*64-1:0] pack, input integer idx);
		pb64 = pack[8*idx +: 8];
	endfunction
	function automatic [7:0] pb32(input [8*32-1:0] pack, input integer idx);
		pb32 = pack[8*idx +: 8];
	endfunction

	// Upper neighbour line buffers, one entry per macroblock column.
	// Single-ported, sequential access only — M10K is correct here.
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] lb_y [0:(MB_W*64)-1];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] lb_u [0:(MB_W*32)-1];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] lb_v [0:(MB_W*32)-1];

	// Neighbour boundary-strength context.
	reg              lft_valid;
	reg              lft_intra;
	reg [3:0]        lft_nz;     // bit y4: left macroblock column x4 = 3
	reg [5:0]        lft_qp;
	reg [5:0]        lft_qpc;
	reg signed [15:0] lft_mvx;
	reg signed [15:0] lft_mvy;
	reg [1:0]        lft_ref;

	reg              top_valid [0:MB_W-1];
	reg              top_intra [0:MB_W-1];
	reg [3:0]        top_nz    [0:MB_W-1];   // bit x4: upper macroblock row y4 = 3
	reg [5:0]        top_qp    [0:MB_W-1];
	reg [5:0]        top_qpc   [0:MB_W-1];
	reg signed [15:0] top_mvx  [0:MB_W-1];
	reg signed [15:0] top_mvy  [0:MB_W-1];
	reg [1:0]        top_ref   [0:MB_W-1];

	// Latched macroblock metadata.
	reg [7:0]        mbx_r;
	reg [7:0]        mby_r;
	reg              intra_r;
	reg [5:0]        qpy_r;
	reg [5:0]        qpc_r;
	reg [15:0]       nz_r;
	reg signed [15:0] mvx_r;
	reg signed [15:0] mvy_r;
	reg [1:0]        ref_r;
	reg              use_left;
	reg              use_top;

	reg [5:0]  fstep;
	reg [9:0]  emit_idx;
	reg [6:0]  seq_idx;

	wire [7:0] mbx_left8 = (mbx_r == 8'd0) ? 8'd0 : (mbx_r - 8'd1);
	wire [MB_IDX_W-1:0] mbx_idx = mbx_r[MB_IDX_W-1:0];
	wire [MB_IDX_W-1:0] mbx_left_idx = mbx_left8[MB_IDX_W-1:0];
	wire [15:0] lb_base_y = {8'd0, mbx_idx} * 16'd64;
	wire [15:0] lb_base_c = {8'd0, mbx_idx} * 16'd32;
	wire [15:0] lb_lbase_y = {8'd0, mbx_left_idx} * 16'd64;
	wire [15:0] lb_lbase_c = {8'd0, mbx_left_idx} * 16'd32;

	assign busy = (state != S_IDLE);

	// ------------------------------------------------------------------
	// Edge scheduling.
	//   fstep[5]   : 0 = luma, 1 = chroma
	//   fstep[4]   : 0 = vertical edge, 1 = horizontal edge
	//   luma       : fstep[3:2] = edge (0..3), fstep[1:0] = 4-sample segment
	//   chroma     : fstep[3] = component, fstep[2] = edge (0..1),
	//                fstep[1:0] = 2-sample segment
	// A chroma edge inherits the boundary strength of the luma edge it sits
	// on: chroma edge e maps to luma edge 2*e and chroma segment s covers the
	// same picture rows/columns as luma segment s.
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
	wire       f_bs_unsupported_unused;
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
		.unsupported_ref(f_bs_unsupported_unused)
	);

	// ------------------------------------------------------------------
	// Window access helpers. x may be -4..15 and y -4..15 for luma, -4..7 for
	// chroma; the negative ranges select the neighbour strips.
	// ------------------------------------------------------------------
	function automatic [7:0] get_y;
		input integer x;
		input integer y;
		begin
			if (x < 0)      get_y = pb64(ly, y * 4 + (x + 4));
			else if (y < 0) get_y = pb64(ty, (y + 4) * 16 + x);
			else            get_y = pb(wy, y * 16 + x);
		end
	endfunction

	function automatic [7:0] get_c;
		input        comp;
		input integer x;
		input integer y;
		begin
			if (x < 0)      get_c = comp ? pb32(lv, y * 4 + (x + 4)) : pb32(lu, y * 4 + (x + 4));
			else if (y < 0) get_c = comp ? pb32(tv, (y + 4) * 8 + x) : pb32(tu, (y + 4) * 8 + x);
			else            get_c = comp ? pb64(wv, y * 8 + x) : pb64(wu, y * 8 + x);
		end
	endfunction

	function automatic [LBY_AW-1:0] lby_addr;
		input [15:0] a;
		begin
			lby_addr = a[LBY_AW-1:0];
		end
	endfunction

	function automatic [LBC_AW-1:0] lbc_addr;
		input [15:0] a;
		begin
			lbc_addr = a[LBC_AW-1:0];
		end
	endfunction

	task put_y;
		input integer x;
		input integer y;
		input [7:0] v;
		integer idx;
		begin
			if (x < 0) begin
				idx = y * 4 + (x + 4);
				ly[8*idx +: 8] <= v;
			end else if (y < 0) begin
				idx = (y + 4) * 16 + x;
				ty[8*idx +: 8] <= v;
			end else begin
				idx = y * 16 + x;
				wy[8*idx +: 8] <= v;
			end
		end
	endtask

	task put_c;
		input        comp;
		input integer x;
		input integer y;
		input [7:0] v;
		integer idx;
		begin
			if (x < 0) begin
				idx = y * 4 + (x + 4);
				if (comp) lv[8*idx +: 8] <= v;
				else      lu[8*idx +: 8] <= v;
			end else if (y < 0) begin
				idx = (y + 4) * 8 + x;
				if (comp) tv[8*idx +: 8] <= v;
				else      tu[8*idx +: 8] <= v;
			end else begin
				idx = y * 8 + x;
				if (comp) wv[8*idx +: 8] <= v;
				else      wu[8*idx +: 8] <= v;
			end
		end
	endtask

	// ------------------------------------------------------------------
	// Gather the four filter lanes for the current edge segment.
	// ------------------------------------------------------------------
	reg [7:0] gp3 [0:3];
	reg [7:0] gp2 [0:3];
	reg [7:0] gp1 [0:3];
	reg [7:0] gp0 [0:3];
	reg [7:0] gq0 [0:3];
	reg [7:0] gq1 [0:3];
	reg [7:0] gq2 [0:3];
	reg [7:0] gq3 [0:3];

	integer gi;
	integer g_x0;
	integer g_y0;
	integer g_pos;
	always @* begin
		g_x0 = {30'd0, f_edge} * 4;
		g_y0 = {30'd0, f_edge} * 4;
		for (gi = 0; gi < 4; gi = gi + 1) begin
			gp3[gi] = 8'd0; gp2[gi] = 8'd0; gp1[gi] = 8'd0; gp0[gi] = 8'd0;
			gq0[gi] = 8'd0; gq1[gi] = 8'd0; gq2[gi] = 8'd0; gq3[gi] = 8'd0;
			if (!f_chroma) begin
				g_pos = {30'd0, f_seg} * 4 + gi;
				if (!f_horiz) begin
					gp3[gi] = get_y(g_x0 - 4, g_pos);
					gp2[gi] = get_y(g_x0 - 3, g_pos);
					gp1[gi] = get_y(g_x0 - 2, g_pos);
					gp0[gi] = get_y(g_x0 - 1, g_pos);
					gq0[gi] = get_y(g_x0 + 0, g_pos);
					gq1[gi] = get_y(g_x0 + 1, g_pos);
					gq2[gi] = get_y(g_x0 + 2, g_pos);
					gq3[gi] = get_y(g_x0 + 3, g_pos);
				end else begin
					gp3[gi] = get_y(g_pos, g_y0 - 4);
					gp2[gi] = get_y(g_pos, g_y0 - 3);
					gp1[gi] = get_y(g_pos, g_y0 - 2);
					gp0[gi] = get_y(g_pos, g_y0 - 1);
					gq0[gi] = get_y(g_pos, g_y0 + 0);
					gq1[gi] = get_y(g_pos, g_y0 + 1);
					gq2[gi] = get_y(g_pos, g_y0 + 2);
					gq3[gi] = get_y(g_pos, g_y0 + 3);
				end
			end else if (gi < 2) begin
				g_pos = {30'd0, f_seg} * 2 + gi;
				if (!f_horiz) begin
					gp3[gi] = get_c(f_comp, g_x0 - 4, g_pos);
					gp2[gi] = get_c(f_comp, g_x0 - 3, g_pos);
					gp1[gi] = get_c(f_comp, g_x0 - 2, g_pos);
					gp0[gi] = get_c(f_comp, g_x0 - 1, g_pos);
					gq0[gi] = get_c(f_comp, g_x0 + 0, g_pos);
					gq1[gi] = get_c(f_comp, g_x0 + 1, g_pos);
					gq2[gi] = get_c(f_comp, g_x0 + 2, g_pos);
					gq3[gi] = get_c(f_comp, g_x0 + 3, g_pos);
				end else begin
					gp3[gi] = get_c(f_comp, g_pos, g_y0 - 4);
					gp2[gi] = get_c(f_comp, g_pos, g_y0 - 3);
					gp1[gi] = get_c(f_comp, g_pos, g_y0 - 2);
					gp0[gi] = get_c(f_comp, g_pos, g_y0 - 1);
					gq0[gi] = get_c(f_comp, g_pos, g_y0 + 0);
					gq1[gi] = get_c(f_comp, g_pos, g_y0 + 1);
					gq2[gi] = get_c(f_comp, g_pos, g_y0 + 2);
					gq3[gi] = get_c(f_comp, g_pos, g_y0 + 3);
				end
			end
		end
	end

	wire [7:0] ep2 [0:3];
	wire [7:0] ep1 [0:3];
	wire [7:0] ep0 [0:3];
	wire [7:0] eq0 [0:3];
	wire [7:0] eq1 [0:3];
	wire [7:0] eq2 [0:3];
	wire [7:0] e_alpha_unused;
	wire [7:0] e_beta_unused;
	wire [5:0] e_tc0_unused;

	h264_deblock_edge u_edge (
		.is_chroma(f_chroma),
		.bs(f_bs),
		.qp_avg(f_qp_avg),
		.slice_alpha_c0_offset(slice_alpha_c0_offset),
		.slice_beta_offset(slice_beta_offset),
		.p3_in(gp3), .p2_in(gp2), .p1_in(gp1), .p0_in(gp0),
		.q0_in(gq0), .q1_in(gq1), .q2_in(gq2), .q3_in(gq3),
		.p2_out(ep2), .p1_out(ep1), .p0_out(ep0),
		.q0_out(eq0), .q1_out(eq1), .q2_out(eq2),
		.alpha_dbg(e_alpha_unused),
		.beta_dbg(e_beta_unused),
		.tc0_dbg(e_tc0_unused)
	);

	// ------------------------------------------------------------------
	// Output window schedule (576 beats).
	// ------------------------------------------------------------------
	wire [9:0] em = emit_idx;
	wire [9:0] em_ll = em - 10'd256;   // luma left strip
	wire [9:0] em_lt = em - 10'd320;   // luma top strip
	wire [9:0] em_cu = em - 10'd384;   // Cb macroblock
	wire [9:0] em_cv = em - 10'd448;   // Cr macroblock
	wire [9:0] em_ul = em - 10'd512;   // Cb left strip
	wire [9:0] em_vl = em - 10'd528;   // Cr left strip
	wire [9:0] em_ut = em - 10'd544;   // Cb top strip
	wire [9:0] em_vt = em - 10'd560;   // Cr top strip

	wire [15:0] blx = {4'd0, mbx_r, 4'd0};
	wire [15:0] bly = {4'd0, mby_r, 4'd0};
	wire [15:0] bcx = {5'd0, mbx_r, 3'd0};
	wire [15:0] bcy = {5'd0, mby_r, 3'd0};

	reg [1:0]  e_plane;
	reg [15:0] e_x;
	reg [15:0] e_y;
	reg [7:0]  e_data;
	reg        e_gate;
	always @* begin
		e_plane = 2'd0;
		e_x = 16'd0;
		e_y = 16'd0;
		e_data = 8'd0;
		e_gate = 1'b1;
		if (em < 10'd256) begin
			e_plane = 2'd0;
			e_x = blx + {12'd0, em[3:0]};
			e_y = bly + {12'd0, em[7:4]};
			e_data = pb(wy, em[7:0]);
		end else if (em < 10'd320) begin
			e_plane = 2'd0;
			e_x = blx - 16'd4 + {14'd0, em_ll[1:0]};
			e_y = bly + {12'd0, em_ll[5:2]};
			e_data = pb64(ly, em_ll[5:0]);
			e_gate = use_left;
		end else if (em < 10'd384) begin
			e_plane = 2'd0;
			e_x = blx + {12'd0, em_lt[3:0]};
			e_y = bly - 16'd4 + {14'd0, em_lt[5:4]};
			e_data = pb64(ty, em_lt[5:0]);
			e_gate = use_top;
		end else if (em < 10'd448) begin
			e_plane = 2'd1;
			e_x = bcx + {13'd0, em_cu[2:0]};
			e_y = bcy + {13'd0, em_cu[5:3]};
			e_data = pb64(wu, em_cu[5:0]);
		end else if (em < 10'd512) begin
			e_plane = 2'd2;
			e_x = bcx + {13'd0, em_cv[2:0]};
			e_y = bcy + {13'd0, em_cv[5:3]};
			e_data = pb64(wv, em_cv[5:0]);
		end else if (em < 10'd528) begin
			e_plane = 2'd1;
			e_x = bcx - 16'd2 + {15'd0, em_ul[0]};
			e_y = bcy + {13'd0, em_ul[3:1]};
			e_data = pb32(lu, {em_ul[3:1], 1'b1, em_ul[0]});
			e_gate = use_left;
		end else if (em < 10'd544) begin
			e_plane = 2'd2;
			e_x = bcx - 16'd2 + {15'd0, em_vl[0]};
			e_y = bcy + {13'd0, em_vl[3:1]};
			e_data = pb32(lv, {em_vl[3:1], 1'b1, em_vl[0]});
			e_gate = use_left;
		end else if (em < 10'd560) begin
			e_plane = 2'd1;
			e_x = bcx + {13'd0, em_ut[2:0]};
			e_y = bcy - 16'd2 + {15'd0, em_ut[3]};
			e_data = pb32(tu, {1'b1, em_ut[3], em_ut[2:0]});
			e_gate = use_top;
		end else begin
			e_plane = 2'd2;
			e_x = bcx + {13'd0, em_vt[2:0]};
			e_y = bcy - 16'd2 + {15'd0, em_vt[3]};
			e_data = pb32(tv, {1'b1, em_vt[3], em_vt[2:0]});
			e_gate = use_top;
		end
	end

	integer i;
	integer wi;
	integer w_x0;
	integer w_y0;
	integer w_pos;
	integer w_lanes;

	always @(posedge clk) begin
		if (reset) begin
			state <= S_IDLE;
			fstep <= 6'd0;
			emit_idx <= 10'd0;
			seq_idx <= 7'd0;
			out_valid <= 1'b0;
			out_plane <= 2'd0;
			out_x <= 16'd0;
			out_y <= 16'd0;
			out_data <= 8'd0;
			mb_done <= 1'b0;
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
			out_valid <= 1'b0;
			mb_done <= 1'b0;

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
					if (smp_idx < 9'd256)
						wy[8*smp_idx[7:0] +: 8] <= smp_data;
					else if (smp_idx < 9'd320)
						wu[8*smp_idx[5:0] +: 8] <= smp_data;
					else
						wv[8*smp_idx[5:0] +: 8] <= smp_data;
				end
				if (smp_done) begin
					seq_idx <= 7'd0;
					state <= S_LOAD;
				end
			end

			// Pull the upper neighbour strip out of the line buffers.
			S_LOAD: begin
				ty[8*seq_idx[5:0] +: 8] <= lb_y[lby_addr(lb_base_y + {9'd0, seq_idx})];
				if (!seq_idx[5]) begin
					tu[8*seq_idx[4:0] +: 8] <= lb_u[lbc_addr(lb_base_c + {10'd0, seq_idx[5:0]})];
					tv[8*seq_idx[4:0] +: 8] <= lb_v[lbc_addr(lb_base_c + {10'd0, seq_idx[5:0]})];
				end
				if (seq_idx == 7'd63) begin
					fstep <= 6'd0;
					state <= S_FILT;
				end else begin
					seq_idx <= seq_idx + 7'd1;
				end
			end

			S_FILT: begin
				w_x0 = {30'd0, f_edge} * 4;
				w_y0 = {30'd0, f_edge} * 4;
				w_lanes = f_chroma ? 2 : 4;
				if (f_edge_avail && !disable_deblocking && (f_bs != 3'd0)) begin
					for (wi = 0; wi < 4; wi = wi + 1) begin
						if (wi < w_lanes) begin
							if (!f_chroma) begin
								w_pos = {30'd0, f_seg} * 4 + wi;
								if (!f_horiz) begin
									put_y(w_x0 - 3, w_pos, ep2[wi]);
									put_y(w_x0 - 2, w_pos, ep1[wi]);
									put_y(w_x0 - 1, w_pos, ep0[wi]);
									put_y(w_x0 + 0, w_pos, eq0[wi]);
									put_y(w_x0 + 1, w_pos, eq1[wi]);
									put_y(w_x0 + 2, w_pos, eq2[wi]);
								end else begin
									put_y(w_pos, w_y0 - 3, ep2[wi]);
									put_y(w_pos, w_y0 - 2, ep1[wi]);
									put_y(w_pos, w_y0 - 1, ep0[wi]);
									put_y(w_pos, w_y0 + 0, eq0[wi]);
									put_y(w_pos, w_y0 + 1, eq1[wi]);
									put_y(w_pos, w_y0 + 2, eq2[wi]);
								end
							end else begin
								w_pos = {30'd0, f_seg} * 2 + wi;
								if (!f_horiz) begin
									put_c(f_comp, w_x0 - 1, w_pos, ep0[wi]);
									put_c(f_comp, w_x0 + 0, w_pos, eq0[wi]);
								end else begin
									put_c(f_comp, w_pos, w_y0 - 1, ep0[wi]);
									put_c(f_comp, w_pos, w_y0 + 0, eq0[wi]);
								end
							end
						end
					end
				end
				if (fstep == 6'd63) begin
					emit_idx <= 10'd0;
					state <= S_EMIT;
				end else begin
					fstep <= fstep + 6'd1;
				end
			end

			S_EMIT: begin
				out_valid <= e_gate;
				out_plane <= e_plane;
				out_x <= e_x;
				out_y <= e_y;
				out_data <= e_data;
				if (emit_idx == 10'd575) begin
					seq_idx <= 7'd0;
					state <= S_STORE;
				end else begin
					emit_idx <= emit_idx + 10'd1;
				end
			end

			// Publish the bottom four rows of this macroblock as the upper
			// neighbour strip for the row below.
			S_STORE: begin
				lb_y[lby_addr(lb_base_y + {9'd0, seq_idx})] <=
					pb(wy, {2'b11, seq_idx[5:4], seq_idx[3:0]});
				if (!seq_idx[5]) begin
					lb_u[lbc_addr(lb_base_c + {10'd0, seq_idx[4:0]})] <=
						pb64(wu, {1'b1, seq_idx[4:3], seq_idx[2:0]});
					lb_v[lbc_addr(lb_base_c + {10'd0, seq_idx[4:0]})] <=
						pb64(wv, {1'b1, seq_idx[4:3], seq_idx[2:0]});
				end
				if (seq_idx == 7'd63) begin
					seq_idx <= 7'd0;
					state <= S_STORE2;
				end else begin
					seq_idx <= seq_idx + 7'd1;
				end
			end

			// Vertical edge 0 modified the right four columns of the left
			// macroblock after its own strip was published, so patch those
			// samples back into the line buffer before moving on.
			S_STORE2: begin
				if (use_left) begin
					lb_y[lby_addr(lb_lbase_y + {10'd0, seq_idx[3:2], 4'd0} + 16'd12 +
					     {14'd0, seq_idx[1:0]})] <=
						pb64(ly, {2'b11, seq_idx[3:2], seq_idx[1:0]});
					if (!seq_idx[3]) begin
						lb_u[lbc_addr(lb_lbase_c + {11'd0, seq_idx[2:1], 3'd0} + 16'd6 +
						     {15'd0, seq_idx[0]})] <=
							pb32(lu, {1'b1, seq_idx[2:1], 1'b1, seq_idx[0]});
						lb_v[lbc_addr(lb_lbase_c + {11'd0, seq_idx[2:1], 3'd0} + 16'd6 +
						     {15'd0, seq_idx[0]})] <=
							pb32(lv, {1'b1, seq_idx[2:1], 1'b1, seq_idx[0]});
					end
				end
				if (seq_idx == 7'd15) begin
					// Rotate this macroblock into the left / upper context.
					for (i = 0; i < 16; i = i + 1) begin
						ly[8*(i * 4 + 0) +: 8] <= pb(wy, i * 16 + 12);
						ly[8*(i * 4 + 1) +: 8] <= pb(wy, i * 16 + 13);
						ly[8*(i * 4 + 2) +: 8] <= pb(wy, i * 16 + 14);
						ly[8*(i * 4 + 3) +: 8] <= pb(wy, i * 16 + 15);
					end
					for (i = 0; i < 8; i = i + 1) begin
						lu[8*(i * 4 + 0) +: 8] <= pb64(wu, i * 8 + 4);
						lu[8*(i * 4 + 1) +: 8] <= pb64(wu, i * 8 + 5);
						lu[8*(i * 4 + 2) +: 8] <= pb64(wu, i * 8 + 6);
						lu[8*(i * 4 + 3) +: 8] <= pb64(wu, i * 8 + 7);
						lv[8*(i * 4 + 0) +: 8] <= pb64(wv, i * 8 + 4);
						lv[8*(i * 4 + 1) +: 8] <= pb64(wv, i * 8 + 5);
						lv[8*(i * 4 + 2) +: 8] <= pb64(wv, i * 8 + 6);
						lv[8*(i * 4 + 3) +: 8] <= pb64(wv, i * 8 + 7);
					end
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

			default: state <= S_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
