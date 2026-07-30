// Phase 3.3b/3.3d/3.3j/k: stand-in for H.264 soft-core.
// On each VCL NAL, wait for slice/residual probe then paint 320×240 RGB565
// diagnostic into frame_store (or residual MB0 gray when residual_ok).
// 3.3j: paint after residual_ok/slice_valid so MB0 gray matches probe;
//       hybrid product present is host F1 (see Plex.sv host_owns_fs).

module decode_stub #(
	parameter int WIDTH  = 320,
	parameter int HEIGHT = 240,
	parameter bit ENABLE_DPB_REF_SEAM = 1'b1,
	// Self-produced DPB reference: recon store → writeback (no golden prefill).
	parameter bit USE_REAL_REF_COMMIT = 1'b0,
	// First-MB-only P FETCH when walker absent (unit TBs). Product stream_path
	// owns h264_p_mb_traverse and must set this 0 (avoids double-paint race).
	parameter bit ENABLE_FIRST_MB_P_FETCH = 1'b1,
	// Mutation twin: force DPB fetch MV to zero (proves product path is live).
	parameter bit FAULT_FORCE_ZERO_FETCH_MV = 1'b0,
	// Mutation twin: keep XOR diagnostic fill even when USE_REAL_REF_COMMIT=1.
	parameter bit FAULT_REAL_REF_XOR_FILL = 1'b0
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        vcl_pulse,
	input  wire [7:0]  last_nal_type,
	input  wire [15:0] nalu_count,
	input  wire [7:0]  idr_count,
	input  wire        has_idr,

	input  wire        sps_valid,
	input  wire [7:0]  mb_w,
	input  wire [7:0]  mb_h,
	input  wire [7:0]  slice_type,
	input  wire        slice_is_i,
	input  wire        slice_valid,
	input  wire [15:0] first_mb_addr,
	input  wire        has_mb_type,
	input  wire        first_mb_p_skip,
	input  wire [2:0]  first_mb_part_mode,
	input  wire [2:0]  first_mb_part_count,
	input  wire        first_mb_uses_sub_mb,
	input  wire        first_mb_intra,
	// Full P-slice MB traversal events (from h264_p_mb_traverse)
	input  wire        trav_mb_valid,
	output wire        trav_mb_ready,
	input  wire [15:0] trav_mb_addr,
	input  wire [7:0]  trav_mb_x,
	input  wire [7:0]  trav_mb_y,
	input  wire        trav_mb_skip,
	input  wire [2:0]  trav_part_mode,
	input  wire [2:0]  trav_part_count,
	input  wire        trav_uses_sub_mb,
	input  wire        trav_intra,
	input  wire        trav_slice_done,
	// I-slice residual export from h264_p_mb_traverse (real-ref I recon)
	input  wire        i_res_blk_valid,
	output wire        i_res_blk_ready,
	input  wire [15:0] i_res_blk_mb_addr,
	input  wire [7:0]  i_res_blk_mb_x,
	input  wire [7:0]  i_res_blk_mb_y,
	input  wire [4:0]  i_res_blk_idx,
	input  wire        i_res_blk_is_i16,
	input  wire        i_res_blk_is_luma,
	input  wire [5:0]  i_res_blk_qp,
	input  wire [4:0]  i_res_blk_max_coeff,
	input  wire [3:0]  i_res_blk_pred_mode,
	input  wire signed [15:0] i_res_blk_coeff [0:15],
	input  wire        i_res_mb_end,
	input  wire [15:0] i_res_mb_end_addr,
	// Parsed first-MB mvd_l0 se(v) from slice_hdr_parser (qpel).
	input  wire signed [15:0] first_mb_mvd_x,
	input  wire signed [15:0] first_mb_mvd_y,
	// 3.3g/j/k: first-MB residual cue for eyes-on recon stub
	input  wire        residual_ok,
	input  wire [4:0]  residual_tc,
	input  wire signed [7:0] residual_dc,
	input  wire        residual_valid,
	input  wire [5:0]  slice_qp,
	input  wire signed [15:0] residual_coeff [0:15],

	output reg  [7:0]  recon_sig,
	output reg  [7:0]  recon_dbg,
	output reg         recon_dbg_valid,
	output reg         recon_valid,

	// Product MV actually driven into h264_dpb_one_ref (post MVP+mvd).
	output reg  signed [15:0] product_fetch_mv_x,
	output reg  signed [15:0] product_fetch_mv_y,
	output wire signed [15:0] product_luma_origin_x,
	output wire signed [15:0] product_luma_origin_y,

	output reg         wr_en,
	output reg  [15:0] wr_pixel,
	output reg         wr_reset_ptr,
	output reg         swap_req,
	output reg         busy,
	output reg  [15:0] frames_out
);

	localparam int PIXELS = WIDTH * HEIGHT;
	localparam int ADDR_W = $clog2(PIXELS);
	// Slice RBSP cap is 48B; bit-walk + residual token ≪ 4096 cycles @ clk_sys
	localparam int WAIT_MAX = 4095;

	reg [ADDR_W:0] pix_i;
	reg [9:0]      x, y;
	// 0 idle, 1 wait residual/slice, 2 paint, 3 wait first-P-MB DPB/MC fetch,
	// 4 publish deblocked I420 samples into the DPB before reference promotion.
	reg [2:0]      phase;
	localparam [2:0] PH_IDLE = 3'd0;
	localparam [2:0] PH_WAIT = 3'd1;
	localparam [2:0] PH_PAINT = 3'd2;
	localparam [2:0] PH_FETCH = 3'd3;
	localparam [2:0] PH_DPB_FILL = 3'd4;
	// Park first-MB IDR recon into recon_store before DPB fill (legacy place path).
	localparam [2:0] PH_IDR_STORE = 3'd5;
	// Real-ref I-slice: wait for residual walk + multi-MB store, then DPB fill.
	localparam [2:0] PH_I_RECON = 3'd6;
	reg            is_idr_frame;
	reg            is_i_frame;
	reg [7:0]      lat_type;
	reg [15:0]     lat_nalu;
	reg [7:0]      lat_idr;
	reg [7:0]      lat_mb_w, lat_mb_h;
	reg            lat_sps;
	reg            lat_res_ok;
	reg [4:0]      lat_res_tc;
	reg signed [7:0] lat_res_dc;
	reg [5:0]      lat_qp;
	reg signed [15:0] lat_coeff [0:15];
	reg [11:0]     wait_cnt;
	reg            lat_wait_res;
	// Sticky residual-path debug (bits 0/3/4/5/6/7). Survives P FETCH which
	// zeroes lat_coeff so later paints still show the residual pipeline fired.
	reg [7:0]      lat_res_dbg;
	reg            lat_p_inter;
	reg            lat_p_skip;
	reg [7:0]      lat_p_mb_x;
	reg [7:0]      lat_p_mb_y;
	reg [2:0]      lat_p_part_mode;
	reg [2:0]      lat_p_part_count;
	reg            lat_p_uses_sub_mb;
	reg            lat_p_intra;
	reg            lat_inter_recon_ok;
	reg [15:0]     lat_p_mb_addr;
	reg            inter_capture_valid;
	reg            p_fetch_launch_pending;
	reg            p_candidate_seen;
	reg            pending_p_fetch;
	reg            pending_p_skip;
	reg [7:0]      pending_p_mb_x;
	reg [7:0]      pending_p_mb_y;
	reg [2:0]      pending_p_part_mode;
	reg [2:0]      pending_p_part_count;
	reg            pending_p_uses_sub_mb;
	reg            pending_p_intra;
	reg            trav_slice_pending;
	reg            trav_active_slice;
	reg            trav_got_mb;
	reg            recon_store_pending;
	reg            idr_recon_pack_pending;
	integer        coeff_i;
	integer        idr_pack_i;
`ifdef VERILATOR
	// Localisation counters for flat-128 chase (printed once per run).
	integer        dbg_store_wr_total;
	integer        dbg_store_wr_idr;
	integer        dbg_store_wr_p;
	integer        dbg_store_wr_p_inter_ok;
	integer        dbg_store_wr_p_inter_fail;
	integer        dbg_residual_blk0_loads;
	integer        dbg_printed_recon_counts;
	reg [31:0]     dbg_i_recon_cycles;
`endif
	// Accept a traversal MB when idle-ready for fetch or actively fetching next.
	// Intra-in-P is accepted (no MC) so the walker never stalls on those MBs.
	// While parking Clip1 samples into the recon store, do not ACK the walker
	// except on the store-done cycle (pending still 1 under NBA that cycle).
	wire           trav_can_accept = (phase == PH_IDLE && (dpb_ref_ready || trav_intra)) ||
	                                 (phase == PH_FETCH && !p_fetch_launch_pending && dpb_fetch_done && !USE_REAL_REF_COMMIT) ||
	                                 (phase == PH_FETCH && !trav_got_mb && !p_fetch_launch_pending && !dpb_fetch_busy &&
	                                  (!recon_store_pending || recon_store_done)) ||
	                                 (phase == PH_IDLE && trav_intra) ||
	                                 // I-slice residual walk: drain MB events unconditionally so the walker
	                                 // is not stuck on mb_hold while residual export runs.
	                                 (phase == PH_I_RECON);
	assign trav_mb_ready = trav_mb_valid && trav_can_accept;
	// First-MB mvd latched for the opening P MB; cleared on multi-MB advance
	// so later stub-walk MBs use MVP-only (mvd=0) until full syntax lands.
	reg signed [15:0] lat_mvd_x;
	reg signed [15:0] lat_mvd_y;
	reg signed [15:0] pending_mvd_x;
	reg signed [15:0] pending_mvd_y;
	// Launch-cycle neighbour snapshot (A/B/C/D) for median MVP 8.4.1.3.
	// Mirrors h264_inter_nb_ctx semantics with same-cycle availability.
	localparam int MV_NB_MAX = 40;
	localparam int MV_NB_AW  = $clog2(MV_NB_MAX); // 6
	reg signed [15:0] mv_left_x, mv_left_y;
	reg               mv_left_v;
	reg signed [15:0] mv_above_x [0:MV_NB_MAX-1];
	reg signed [15:0] mv_above_y [0:MV_NB_MAX-1];
	reg               mv_above_v [0:MV_NB_MAX-1];
	reg signed [15:0] mv_d_x, mv_d_y;
	reg               mv_d_v;
	reg signed [15:0] mv_col_al_x, mv_col_al_y;
	reg               mv_col_al_v;
	reg        [1:0]  fetch_gap; // delay multi-MB advance so left publishes
	integer        mv_nb_i;

	wire [9:0] width_w  = WIDTH[9:0];
	wire [9:0] height_w = HEIGHT[9:0];
	wire border = (x < 10'd4) || (x >= (width_w - 10'd4)) ||
	              (y < 10'd4) || (y >= (height_w - 10'd4));
	wire strip  = (y < 10'd16);

	// Macroblock grid lines every 16 px when SPS known
	wire mb_line = lat_sps && ((x[3:0] == 4'd0) || (y[3:0] == 4'd0));
	// MB index colour hash
	wire [7:0] mbx = {2'd0, x[9:4]};
	wire [7:0] mby = {2'd0, y[9:4]};
	wire [7:0] mb_hash = mbx + mby + lat_nalu[7:0];
	// First MB (0,0) filled with recon stub gray when residual_ok
	wire mb0 = (x < 10'd16) && (y < 10'd16);
	wire inter_diag_tile = (x >= 10'd16) && (x < 10'd32) && (y < 10'd16);
	// 3.3l-2: first 4x4 inv_quant + IDCT (pred=128) from the shared
	// h264_iq_idct_4x4.sv RTL. The signature is XOR of reconstructed samples.
	wire signed [28:0] idct_dequant [0:15];
	wire signed [28:0] idct_residual [0:15];
	wire [7:0] idct_pred [0:15];
	wire [7:0] recon_px [0:15];
	wire [7:0] recon_sig_comb = recon_px[0]  ^ recon_px[1]  ^ recon_px[2]  ^ recon_px[3] ^
	                            recon_px[4]  ^ recon_px[5]  ^ recon_px[6]  ^ recon_px[7] ^
	                            recon_px[8]  ^ recon_px[9]  ^ recon_px[10] ^ recon_px[11] ^
	                            recon_px[12] ^ recon_px[13] ^ recon_px[14] ^ recon_px[15];
	reg [7:0] recon_dbg_comb;
	integer dbg_i;
	always @* begin
		recon_dbg_comb = 8'd0;
		for (dbg_i = 0; dbg_i < 16; dbg_i = dbg_i + 1) begin
			if (lat_coeff[dbg_i] != 16'sd0)
				recon_dbg_comb[0] = 1'b1; // coefficients seen by recon path are non-zero
			if (idct_dequant[dbg_i] != 29'sd0)
				recon_dbg_comb[3] = 1'b1; // dequant stage produced a non-zero value
			if (idct_residual[dbg_i] != 29'sd0)
				recon_dbg_comb[4] = 1'b1; // IDCT residual contribution is non-zero
			if (recon_px[dbg_i] != 8'd128)
				recon_dbg_comb[5] = 1'b1; // recon differs from pred-only 128
		end
		recon_dbg_comb[6] = lat_res_ok;
		recon_dbg_comb[7] = lat_wait_res;
	end

	genvar pred_i;
	generate
		for (pred_i = 0; pred_i < 16; pred_i = pred_i + 1) begin : gen_idct_pred
			// Inter MBs: use MC prediction from DPB reference.
			// Intra MBs: 128 placeholder (real intra prediction not yet wired).
			// This maps the first 4x4 block of dpb_pred_y into the recon path.
			assign idct_pred[pred_i] = (lat_p_inter && dpb_ref_ready) ?
			                           dpb_pred_y[pred_i] : 8'd128;
		end
	endgenerate

	h264_dequant4x4 u_h264_dequant4x4 (
		.coeff(lat_coeff),
		.qp(lat_qp),
		.max_coeff(5'd16),
		.dequant(idct_dequant)
	);

	h264_idct4x4 u_h264_idct4x4 (
		.dequant(idct_dequant),
		.residual(idct_residual)
	);

	h264_recon4x4 u_h264_recon4x4 (
		.pred(idct_pred),
		.residual(idct_residual),
		.recon(recon_px)
	);

	// P3 inter-prediction product diagnostic: keep the motion/interpolation RTL
	// instantiated in the shipped bitstream and paint a visible pass/fail tile.
	wire signed [15:0] inter_pred_x, inter_pred_y, inter_mv_x, inter_mv_y;
	wire               inter_skip_zero;
	wire [7:0]         inter_luma_ref [0:80];
	wire [7:0]         inter_luma_sample;
	wire signed [15:0] inter_part_pred_x, inter_part_pred_y, inter_part_mv_x, inter_part_mv_y;
	wire               inter_part_skip_zero;
	wire [7:0]         inter_chroma_sample;
	wire [15:0]        inter_fetch_x, inter_fetch_y;
	genvar inter_ref_i;
	generate
		for (inter_ref_i = 0; inter_ref_i < 81; inter_ref_i = inter_ref_i + 1) begin : gen_inter_ref
			assign inter_luma_ref[inter_ref_i] =
				(((inter_ref_i / 9) * 37 + (inter_ref_i % 9) * 19 +
				  ((inter_ref_i / 9) * (inter_ref_i % 9) * 7)) ^
				 (((inter_ref_i / 9) + 3) * 11)) & 8'hff;
		end
	endgenerate

	h264_mv_pred_16x16 u_inter_mv_diag (
		.avail_a(1'b1), .avail_b(1'b1), .avail_c(1'b1), .avail_d(1'b0),
		.mv_a_x(16'sd4), .mv_a_y(-16'sd2),
		.mv_b_x(-16'sd8), .mv_b_y(16'sd6),
		.mv_c_x(16'sd12), .mv_c_y(16'sd10),
		.mv_d_x(16'sd0), .mv_d_y(16'sd0),
		.mvd_x(16'sd1), .mvd_y(-16'sd1), .p_skip(1'b0),
		.pred_x(inter_pred_x), .pred_y(inter_pred_y),
		.mv_x(inter_mv_x), .mv_y(inter_mv_y), .skip_zero(inter_skip_zero)
	);

	h264_mv_pred_part u_inter_part_diag (
		.part_mode(3'd1), .part_idx(2'd0),
		.avail_a(1'b1), .avail_b(1'b1), .avail_c(1'b1), .avail_d(1'b0),
		.mv_a_x(16'sd100), .mv_a_y(16'sd0),
		.mv_b_x(16'sd1), .mv_b_y(16'sd2),
		.mv_c_x(16'sd50), .mv_c_y(16'sd0),
		.mv_d_x(16'sd0), .mv_d_y(16'sd0),
		.mvd_x(16'sd3), .mvd_y(16'sd4), .p_skip(1'b0),
		.pred_x(inter_part_pred_x), .pred_y(inter_part_pred_y),
		.mv_x(inter_part_mv_x), .mv_y(inter_part_mv_y), .skip_zero(inter_part_skip_zero)
	);

	h264_luma_qpel_sample u_inter_luma_diag (
		.ref_pix(inter_luma_ref), .frac_x(2'd3), .frac_y(2'd2), .sample(inter_luma_sample)
	);

	h264_chroma_epel_sample u_inter_chroma_diag (
		.p00(8'd23), .p10(8'd101), .p01(8'd77), .p11(8'd209),
		.frac_x(3'd3), .frac_y(3'd5), .sample(inter_chroma_sample)
	);

	h264_luma_ref_tap_addr u_inter_fetch_diag (
		.base_x(16'sd100), .base_y(16'sd50), .tap_idx(7'd80),
		.width(16'd624), .height(16'd480), .tap_x(inter_fetch_x), .tap_y(inter_fetch_y)
	);

	wire [7:0] inter_part_sig = inter_part_pred_x[7:0] ^ inter_part_pred_y[7:0] ^
	                            inter_part_mv_x[7:0] ^ inter_part_mv_y[7:0];
	wire [7:0] inter_diag_sig = inter_pred_x[7:0] ^ inter_pred_y[7:0] ^
	                            inter_mv_x[7:0] ^ inter_mv_y[7:0] ^ inter_part_sig ^
	                            inter_luma_sample ^ inter_chroma_sample ^
	                            inter_fetch_x[7:0] ^ inter_fetch_y[7:0];
	wire inter_part_ok = !inter_part_skip_zero && (inter_part_pred_x == 16'sd1) &&
	                     (inter_part_pred_y == 16'sd2) && (inter_part_mv_x == 16'sd4) &&
	                     (inter_part_mv_y == 16'sd6);
	wire inter_mv_ok = !inter_skip_zero && (inter_pred_x == 16'sd4) && (inter_pred_y == 16'sd6) &&
	                   (inter_mv_x == 16'sd5) && (inter_mv_y == 16'sd5) && inter_part_ok;
	wire inter_luma_ok = (inter_luma_sample == 8'd105);
	wire inter_chroma_ok = (inter_chroma_sample == 8'd99);
	wire inter_fetch_ok = (inter_fetch_x == 16'd104) && (inter_fetch_y == 16'd54);
	wire inter_diag_ok = (inter_diag_sig == 8'h57) && inter_mv_ok && inter_luma_ok &&
	                     inter_chroma_ok && inter_fetch_ok;
	wire [1:0] inter_diag_band = x[3:2];
	wire inter_band_ok = (inter_diag_band == 2'd0) ? inter_mv_ok :
	                     (inter_diag_band == 2'd1) ? inter_luma_ok :
	                     (inter_diag_band == 2'd2) ? inter_chroma_ok :
	                                                  inter_fetch_ok;
	wire [7:0] inter_band_sig = (inter_diag_band == 2'd0) ? (inter_pred_x[7:0] ^ inter_pred_y[7:0] ^ inter_mv_x[7:0] ^ inter_mv_y[7:0] ^ {inter_part_sig[2:0], 5'b0}) :
	                            (inter_diag_band == 2'd1) ? inter_luma_sample :
	                            (inter_diag_band == 2'd2) ? inter_chroma_sample :
	                                                         (inter_fetch_x[7:0] ^ inter_fetch_y[7:0]);

	// 3.3k fallback: paint from residual_dc (scan coeff0 → 128+dc)
	wire signed [9:0] recon_sum = 10'sd128 + {{2{lat_res_dc[7]}}, lat_res_dc};
	wire [7:0] recon_from_dc =
		(recon_sum < 10'sd0)   ? 8'd0 :
		(recon_sum > 10'sd255) ? 8'd255 : recon_sum[7:0];
	wire first4 = mb0 && (x < 10'd4) && (y < 10'd4);
	wire [3:0] first4_idx = {y[1:0], x[1:0]};
	wire [7:0] recon_y = (lat_res_ok && first4) ? recon_px[first4_idx] :
	                     (lat_res_ok ? recon_from_dc : (8'd128 + {3'b0, lat_res_tc}));

	wire idr_style = is_idr_frame || (lat_type[4:0] == 5'd5);

	wire [7:0] rr =
		(mb0 && lat_res_ok) ? recon_y :
		border   ? 8'h10 :
		inter_diag_tile ? (inter_band_ok ? 8'h10 : 8'hf0) :
		strip    ? {lat_type[4:0], 3'b000} :
		mb_line  ? (is_i_frame ? 8'h20 : 8'h80) :
		           (8'h08 + {4'b0, mb_hash[3:0]});
	wire [7:0] gg =
		(mb0 && lat_res_ok) ? recon_y :
		border   ? (idr_style ? 8'hE0 : 8'hC0) :
		inter_diag_tile ? (inter_band_ok ? 8'hf0 : 8'h10) :
		strip    ? lat_idr :
		mb_line  ? (is_i_frame ? 8'hE0 : 8'h40) :
		           (8'h18 + {3'b0, mb_hash[4:0]});
	wire [7:0] bb =
		(mb0 && lat_res_ok) ? recon_y :
		border   ? (idr_style ? 8'h20 : 8'hE0) :
		inter_diag_tile ? inter_band_sig :
		strip    ? 8'h20 :
		mb_line  ? 8'h30 :
		           (8'h40 + {mb_hash[5:0], 2'b00});
	wire [15:0] px_comb = {rr[7:3], gg[7:2], bb[7:3]};

	function automatic [4:0] p_part_w_of;
		input [2:0] mode;
		begin
			case (mode)
			3'd1: p_part_w_of = 5'd16; // P_L0_16x8
			3'd2: p_part_w_of = 5'd8;  // P_L0_8x16
			3'd3, 3'd4: p_part_w_of = 5'd8;
			default: p_part_w_of = 5'd16;
			endcase
		end
	endfunction

	function automatic [4:0] p_part_h_of;
		input [2:0] mode;
		begin
			case (mode)
			3'd1: p_part_h_of = 5'd8;
			3'd2: p_part_h_of = 5'd16;
			3'd3, 3'd4: p_part_h_of = 5'd8;
			default: p_part_h_of = 5'd16;
			endcase
		end
	endfunction

	// First-P-MB DPB/MC path. Parsed P macroblock syntax drives the MC request;
	// the reference becomes usable only through the same deblock writeback
	// controller seam that owns filtered-MB commit and frame-boundary promotion.
	reg               dpb_fetch_start;
	reg               dpb_frame_done_pulse;
	localparam int DPB_MB_W = (WIDTH + 15) / 16;
	localparam int DPB_MB_H = (HEIGHT + 15) / 16;
	localparam int DPB_MB_COUNT = DPB_MB_W * DPB_MB_H;
	localparam int DPB_MB_AW = (DPB_MB_COUNT <= 1) ? 1 : $clog2(DPB_MB_COUNT);
	localparam [31:0] DPB_LAST_MB_ADDR_32 = DPB_MB_COUNT - 1;
	localparam [15:0] DPB_LAST_MB_ADDR = DPB_LAST_MB_ADDR_32[15:0];
	reg [15:0]        dpb_fill_mb_addr;
	reg [8:0]         dpb_fill_sample_idx;
	wire              dpb_ref_ready;
	wire              deblock_wb_valid;
	wire [DPB_MB_AW-1:0] deblock_wb_mb_addr;
	wire              deblock_wb_is_ref;
	wire              deblock_dpb_invalidate_refs;
	wire              deblock_ref_ready_pulse;
	wire [1:0]        deblock_ref_ready_slot;
	wire              deblock_commit_order_error;
	wire [31:0]       dpb_current_base;
	wire [31:0]       dpb_reference_base;
	wire              dpb_mem_we;
	wire [31:0]       dpb_mem_waddr;
	wire [7:0]        dpb_mem_wdata;
	wire              dpb_fetch_busy;
	wire              dpb_fetch_done;
	wire              dpb_fetch_error_no_ref;
	wire [1:0]        dpb_luma_frac_x, dpb_luma_frac_y;
	wire [2:0]        dpb_chroma_frac_x, dpb_chroma_frac_y;
	wire signed [15:0] dpb_luma_origin_x, dpb_luma_origin_y;
	wire signed [15:0] dpb_chroma_origin_x, dpb_chroma_origin_y;
	wire              dpb_mem_rd;
	wire [31:0]       dpb_mem_raddr;
	reg [31:0]        dpb_mem_raddr_q;
	reg               dpb_mem_rvalid;
	wire [7:0]        dpb_mem_rdata;
`ifdef VERILATOR
	reg               dpb_mem_rd_dbg_q;
	reg [31:0]        dpb_mem_raddr_dbg_q;
`endif
	wire              dpb_luma_window_valid;
	wire [8:0]        dpb_luma_window_idx;
	wire [7:0]        dpb_luma_window_sample;
	wire              dpb_chroma_u_window_valid;
	wire              dpb_chroma_v_window_valid;
	wire [6:0]        dpb_chroma_window_idx;
	wire [7:0]        dpb_chroma_window_sample;
	reg [7:0]         dpb_luma_win [0:440];
	reg [7:0]         dpb_u_win [0:80];
	reg [7:0]         dpb_v_win [0:80];
	wire [7:0]        dpb_pred_y [0:255];
	wire              dpb_pred_y_valid [0:255];
	wire [7:0]        dpb_pred_u [0:63];
	wire              dpb_pred_u_valid [0:63];
	wire [7:0]        dpb_pred_v [0:63];
	wire              dpb_pred_v_valid [0:63];
	// Inter reconstruction residual plane (signed post-IDCT samples).
	// Filled from the first residual 4×4 when residual_ok; remaining samples
	// stay 0 until a full P residual walker lands. P_Skip keeps zeros.
	reg signed [15:0] inter_res_y [0:255];
	reg signed [15:0] inter_res_u [0:63];
	reg signed [15:0] inter_res_v [0:63];
	// lat_coeff → IQ/IDCT is combo; sample residual plane one cycle after place.
	reg               inter_res_load_pending;
	// recon = Clip1(pred + residual) — product inter export (pre-deblock).
	wire [7:0]        inter_recon_y [0:255];
	wire [7:0]        inter_recon_u [0:63];
	wire [7:0]        inter_recon_v [0:63];
	wire [4:0]        dpb_part_w = p_part_w_of(lat_p_part_mode);
	wire [4:0]        dpb_part_h = p_part_h_of(lat_p_part_mode);
	wire              dpb_fill_sample_phase = (phase == PH_DPB_FILL) && (dpb_fill_sample_idx < 9'd384);
	wire              dpb_diag_sample_phase = !ENABLE_DPB_REF_SEAM && (phase == PH_PAINT) && is_idr_frame && (pix_i == 0);
	wire              dpb_filtered_sample_valid = dpb_fill_sample_phase || dpb_diag_sample_phase;
	wire              dpb_filtered_mb_valid = (phase == PH_DPB_FILL) && (dpb_fill_sample_idx == 9'd384);
	wire              dpb_filtered_frame_done = dpb_filtered_mb_valid && (dpb_fill_mb_addr == DPB_LAST_MB_ADDR);
	wire              dpb_frame_boundary = (phase == PH_DPB_FILL) && (dpb_fill_sample_idx == 9'd385);
	wire [31:0]       dpb_fill_mb_addr32 = {16'd0, dpb_fill_mb_addr};
	wire [31:0]       dpb_fill_mb_x32 = dpb_fill_mb_addr32 % DPB_MB_W;
	wire [31:0]       dpb_fill_mb_y32 = dpb_fill_mb_addr32 / DPB_MB_W;
	wire [15:0]       dpb_fill_mb_x16 = dpb_fill_mb_x32[15:0];
	wire [15:0]       dpb_fill_mb_y16 = dpb_fill_mb_y32[15:0];
	wire [7:0]        dpb_fill_mb_x = dpb_fill_mb_x16[7:0];
	wire [7:0]        dpb_fill_mb_y = dpb_fill_mb_y16[7:0];
	wire [1:0]        dpb_filtered_plane = (dpb_fill_sample_idx < 9'd256) ? 2'd0 :
	                                       (dpb_fill_sample_idx < 9'd320) ? 2'd1 : 2'd2;
	wire [8:0]        dpb_sample_u_idx9 = dpb_fill_sample_idx - 9'd256;
	wire [8:0]        dpb_sample_v_idx9 = dpb_fill_sample_idx - 9'd320;
	wire [7:0]        dpb_filtered_sample_idx = (dpb_filtered_plane == 2'd0) ? dpb_fill_sample_idx[7:0] :
	                                            (dpb_filtered_plane == 2'd1) ? dpb_sample_u_idx9[7:0] :
	                                                                           dpb_sample_v_idx9[7:0];
	wire [7:0]        dpb_sample_x = (dpb_filtered_plane == 2'd0) ? {4'd0, dpb_filtered_sample_idx[3:0]} :
	                                                                  {5'd0, dpb_filtered_sample_idx[2:0]};
	wire [7:0]        dpb_sample_y = (dpb_filtered_plane == 2'd0) ? {4'd0, dpb_filtered_sample_idx[7:4]} :
	                                                                  {5'd0, dpb_filtered_sample_idx[5:3]};
	wire [15:0]       dpb_abs_x = (dpb_filtered_plane == 2'd0) ? ({4'd0, dpb_fill_mb_x, 4'd0} + {8'd0, dpb_sample_x}) :
	                                                             ({5'd0, dpb_fill_mb_x, 3'd0} + {8'd0, dpb_sample_x});
	wire [15:0]       dpb_abs_y = (dpb_filtered_plane == 2'd0) ? ({4'd0, dpb_fill_mb_y, 4'd0} + {8'd0, dpb_sample_y}) :
	                                                             ({5'd0, dpb_fill_mb_y, 3'd0} + {8'd0, dpb_sample_y});
	// ── DPB commit sample source ───────────────────────────────────────
	// WAS: synthetic XOR/chroma-ramp poisoned every P ref.
	// NOW (priority):
	//   USE_REAL_REF_COMMIT → multi-MB recon_store (full-frame self-ref measure)
	//   else product recon mux: P Clip1 inter_recon_*; IDR MB0 blk0 recon_px; else 128
	// FAULT_REAL_REF_XOR_FILL / DECODE_STUB_FAULT_DPB_SYNTHETIC_XOR → XOR (must RED).
	wire [7:0]        dpb_synthetic_sample =
	                                      (dpb_filtered_plane == 2'd0) ? (8'h20 ^ dpb_abs_x[7:0] ^ {dpb_abs_y[4:0], 3'b000}) :
	                                      (dpb_filtered_plane == 2'd1) ? (8'h80 + {2'd0, dpb_abs_x[5:0]}) :
	                                                                     (8'h80 + {2'd0, dpb_abs_y[5:0]});
	wire [7:0]        dpb_y_idx = dpb_fill_sample_idx[7:0];
	wire [5:0]        dpb_c_idx = dpb_filtered_sample_idx[5:0];
	wire              dpb_commit_is_p = lat_p_inter;
	wire [7:0]        dpb_recon_src_y =
	                      dpb_commit_is_p ? inter_recon_y[dpb_y_idx] :
	                      ((dpb_fill_mb_addr == 16'd0) && (dpb_fill_sample_idx < 9'd16) && lat_res_ok) ?
	                          recon_px[{dpb_fill_sample_idx[3:2], dpb_fill_sample_idx[1:0]}] :
	                      8'd128;
	wire [7:0]        dpb_recon_src_u = dpb_commit_is_p ? inter_recon_u[dpb_c_idx] : 8'd128;
	wire [7:0]        dpb_recon_src_v = dpb_commit_is_p ? inter_recon_v[dpb_c_idx] : 8'd128;
	wire [7:0]        dpb_recon_src_sample =
	                      (dpb_filtered_plane == 2'd0) ? dpb_recon_src_y :
	                      (dpb_filtered_plane == 2'd1) ? dpb_recon_src_u : dpb_recon_src_v;
	wire              use_real_ref = USE_REAL_REF_COMMIT && !FAULT_REAL_REF_XOR_FILL;
	// Real-ref multi-MB store sample (declared with store instance below).
	wire [7:0]        recon_store_sample;
`ifdef DECODE_STUB_FAULT_DPB_SYNTHETIC_XOR
	wire [7:0]        dpb_filtered_sample = dpb_synthetic_sample;
`else
	wire [7:0]        dpb_filtered_sample =
	                      FAULT_REAL_REF_XOR_FILL ? dpb_synthetic_sample :
	                      USE_REAL_REF_COMMIT     ? recon_store_sample :
	                                                dpb_recon_src_sample;
`endif

	wire [7:0]        dpb_filtered_mb_x_out = ENABLE_DPB_REF_SEAM ? dpb_fill_mb_x : 8'd0;
	wire [7:0]        dpb_filtered_mb_y_out = ENABLE_DPB_REF_SEAM ? dpb_fill_mb_y : 8'd0;
	wire [1:0]        dpb_filtered_plane_out = ENABLE_DPB_REF_SEAM ? dpb_filtered_plane : 2'd0;
	wire [7:0]        dpb_filtered_sample_idx_out = ENABLE_DPB_REF_SEAM ? dpb_filtered_sample_idx : 8'd0;
	wire [7:0]        dpb_filtered_sample_out = ENABLE_DPB_REF_SEAM ? dpb_filtered_sample : 8'h3b;
	wire              dpb_idr_start = deblock_dpb_invalidate_refs | (vcl_pulse && (last_nal_type[4:0] == 5'd5));
	wire [15:0]       p_mb_width = (mb_w == 0) ? 16'd20 : {8'd0, mb_w};
	wire [15:0]       p_req_mb_x16 = (p_mb_width == 16'd0) ? 16'd0 : (first_mb_addr % p_mb_width);
	wire [15:0]       p_req_mb_y16 = (p_mb_width == 16'd0) ? 16'd0 : (first_mb_addr / p_mb_width);
	wire [7:0]        p_req_mb_x = p_req_mb_x16[7:0];
	wire [7:0]        p_req_mb_y = p_req_mb_y16[7:0];
	wire [15:0]       lat_p_mb_width = (lat_mb_w == 0) ? 16'd20 : {8'd0, lat_mb_w};
	wire              p_fetch_candidate = slice_valid && !slice_is_i && has_mb_type && !first_mb_intra &&
	                                      ((first_mb_part_mode == 3'd0) || (first_mb_part_mode == 3'd1) ||
	                                       (first_mb_part_mode == 3'd2) || (first_mb_part_mode == 3'd3) ||
	                                       (first_mb_part_mode == 3'd4));
	wire              p_fetch_edge = p_fetch_candidate && !p_candidate_seen;
	// Prefer walker events; fall back to first-MB edge only if walker silent.
	// Only commit to walker-driven fetch after an accepted beat (not every pulse).
	wire              use_trav = trav_active_slice || trav_slice_pending;

	// Product MVP + mvd → final qpel MV for DPB fetch (replaces hardwired 0).
	wire [MV_NB_AW-1:0] lat_mb_x_i  = lat_p_mb_x[MV_NB_AW-1:0];
	wire [MV_NB_AW-1:0] lat_mb_xr_i = lat_p_mb_x[MV_NB_AW-1:0] + MV_NB_AW'(1);
	wire [MV_NB_AW-1:0] pend_mb_x_i = pending_p_mb_x[MV_NB_AW-1:0];
	wire [MV_NB_AW-1:0] req_mb_x_i  = p_req_mb_x[MV_NB_AW-1:0];
	wire              prod_avail_a = (lat_p_mb_x != 8'd0) && mv_left_v;
	wire              prod_avail_b = (lat_p_mb_y != 8'd0) &&
	                                 (lat_p_mb_x < MV_NB_MAX[7:0]) && mv_above_v[lat_mb_x_i];
	wire              prod_avail_c = (lat_p_mb_y != 8'd0) &&
	                                 (lat_p_mb_x + 8'd1 < lat_mb_w) &&
	                                 (lat_p_mb_x + 8'd1 < MV_NB_MAX[7:0]) &&
	                                 mv_above_v[lat_mb_xr_i];
	wire              prod_avail_d = (lat_p_mb_x != 8'd0) && (lat_p_mb_y != 8'd0) && mv_d_v;
	wire signed [15:0] prod_mv_a_x = mv_left_x;
	wire signed [15:0] prod_mv_a_y = mv_left_y;
	wire signed [15:0] prod_mv_b_x = (lat_p_mb_x < MV_NB_MAX[7:0]) ? mv_above_x[lat_mb_x_i] : 16'sd0;
	wire signed [15:0] prod_mv_b_y = (lat_p_mb_x < MV_NB_MAX[7:0]) ? mv_above_y[lat_mb_x_i] : 16'sd0;
	wire signed [15:0] prod_mv_c_x = (lat_p_mb_x + 8'd1 < MV_NB_MAX[7:0]) ? mv_above_x[lat_mb_xr_i] : 16'sd0;
	wire signed [15:0] prod_mv_c_y = (lat_p_mb_x + 8'd1 < MV_NB_MAX[7:0]) ? mv_above_y[lat_mb_xr_i] : 16'sd0;
	wire signed [15:0] prod_mvp_x, prod_mvp_y, prod_mv_x, prod_mv_y;
	wire               prod_skip_zero;
	h264_mv_pred_part u_product_mv_pred (
		.part_mode(lat_p_part_mode),
		.part_idx(2'd0),
		.avail_a(prod_avail_a), .avail_b(prod_avail_b),
		.avail_c(prod_avail_c), .avail_d(prod_avail_d),
		.mv_a_x(prod_mv_a_x), .mv_a_y(prod_mv_a_y),
		.mv_b_x(prod_mv_b_x), .mv_b_y(prod_mv_b_y),
		.mv_c_x(prod_mv_c_x), .mv_c_y(prod_mv_c_y),
		.mv_d_x(mv_d_x), .mv_d_y(mv_d_y),
		.mvd_x(lat_mvd_x), .mvd_y(lat_mvd_y),
		.p_skip(lat_p_skip),
		.pred_x(prod_mvp_x), .pred_y(prod_mvp_y),
		.mv_x(prod_mv_x), .mv_y(prod_mv_y),
		.skip_zero(prod_skip_zero)
	);
	wire signed [15:0] fetch_mv_x_qpel =
		FAULT_FORCE_ZERO_FETCH_MV ? 16'sd0 : prod_mv_x;
	wire signed [15:0] fetch_mv_y_qpel =
		FAULT_FORCE_ZERO_FETCH_MV ? 16'sd0 : prod_mv_y;
	wire [7:0]        dpb_inter_sig = dpb_pred_y[0] ^ dpb_pred_y[1] ^ dpb_pred_y[2] ^ dpb_pred_y[3] ^
	                                  dpb_pred_y[4] ^ dpb_pred_y[5] ^ dpb_pred_y[6] ^ dpb_pred_y[7] ^
	                                  dpb_pred_y[8] ^ dpb_pred_y[9] ^ dpb_pred_y[10] ^ dpb_pred_y[11] ^
	                                  dpb_pred_y[12] ^ dpb_pred_y[13] ^ dpb_pred_y[14] ^ dpb_pred_y[15];
	wire              dpb_inter_ok = lat_p_inter && dpb_ref_ready && !dpb_fetch_error_no_ref &&
	                                 dpb_pred_y_valid[0];
	// DPB local memory — two banks for ping-pong (current/reference).
	// In simulation, backed by SRAM; testbench pre-fills reference bank
	// with real IDR decode data for honest inter measurement.
	localparam int DPB_FRAME_BYTES = WIDTH * HEIGHT + 2 * ((WIDTH/2) * (HEIGHT/2));
	localparam int DPB_BANK1_BASE = DPB_FRAME_BYTES;
	localparam int DPB_MEM_BYTES  = 2 * DPB_FRAME_BYTES;
	(* ram_style = "block" *) reg [7:0] dpb_mem [0:DPB_MEM_BYTES-1];

	// DPB write port (from fill path)
	always @(posedge clk) begin
		if (dpb_mem_we && dpb_mem_waddr < DPB_MEM_BYTES[31:0])
			dpb_mem[dpb_mem_waddr[17:0]] <= dpb_mem_wdata;
	end

	// DPB read port (for MC reference fetch) — 1-cycle latency
	assign dpb_mem_rdata = (dpb_mem_raddr_q < DPB_MEM_BYTES[31:0]) ?
	                       dpb_mem[dpb_mem_raddr_q[17:0]] : 8'h00;

	h264_deblock_writeback_ctrl #(
		.MB_COUNT(DPB_MB_COUNT),
		.MB_AW(DPB_MB_AW),
		.FRAME_SLOT_W(2),
		.SAMPLES_PER_MB(384)
	) u_stream_dpb_wb (
		.clk(clk), .reset(reset),
		.idr_frame_start(vcl_pulse && (last_nal_type[4:0] == 5'd5)),
		.filtered_sample_valid(dpb_filtered_sample_valid),
		.filtered_mb_valid(dpb_filtered_mb_valid),
		.filtered_mb_addr(dpb_fill_mb_addr[DPB_MB_AW-1:0]),
		.filtered_mb_is_ref(1'b1),
		.filtered_frame_done(dpb_filtered_frame_done),
		.frame_slot_i(2'd0),
		.frame_boundary(dpb_frame_boundary),
		.wb_valid(deblock_wb_valid),
		.wb_mb_addr(deblock_wb_mb_addr),
		.wb_is_ref(deblock_wb_is_ref),
		.dpb_invalidate_refs(deblock_dpb_invalidate_refs),
		.ref_ready_pulse(deblock_ref_ready_pulse),
		.ref_ready_slot(deblock_ref_ready_slot),
		.commit_order_error(deblock_commit_order_error)
	);

	h264_dpb_one_ref #(
		.FRAME_W(WIDTH), .FRAME_H(HEIGHT),
		.BANK0_BASE(0), .BANK1_BASE(DPB_FRAME_BYTES)
	) u_stream_dpb (
		.clk(clk), .reset(reset),
		.idr_start(dpb_idr_start),
		.frame_done(ENABLE_DPB_REF_SEAM ? deblock_ref_ready_pulse : dpb_frame_done_pulse),
		.ref_ready(dpb_ref_ready),
		.current_base(dpb_current_base),
		.reference_base(dpb_reference_base),
		.filtered_sample_valid(dpb_filtered_sample_valid),
		.filtered_mb_x(dpb_filtered_mb_x_out), .filtered_mb_y(dpb_filtered_mb_y_out), .filtered_plane(dpb_filtered_plane_out),
		.filtered_sample_idx(dpb_filtered_sample_idx_out), .filtered_sample(dpb_filtered_sample_out),
		.mem_we(dpb_mem_we), .mem_waddr(dpb_mem_waddr), .mem_wdata(dpb_mem_wdata),
		.fetch_start(dpb_fetch_start),
		.fetch_mb_x(lat_p_mb_x), .fetch_mb_y(lat_p_mb_y),
		.fetch_part_mode(lat_p_part_mode), .fetch_part_idx(2'd0),
		.fetch_part_w(dpb_part_w), .fetch_part_h(dpb_part_h),
		.fetch_mv_x_qpel(fetch_mv_x_qpel), .fetch_mv_y_qpel(fetch_mv_y_qpel),
		.fetch_busy(dpb_fetch_busy), .fetch_done(dpb_fetch_done),
		.fetch_error_no_ref(dpb_fetch_error_no_ref),
		.luma_frac_x(dpb_luma_frac_x), .luma_frac_y(dpb_luma_frac_y),
		.chroma_frac_x(dpb_chroma_frac_x), .chroma_frac_y(dpb_chroma_frac_y),
		.luma_origin_x(dpb_luma_origin_x), .luma_origin_y(dpb_luma_origin_y),
		.chroma_origin_x(dpb_chroma_origin_x), .chroma_origin_y(dpb_chroma_origin_y),
		.mem_rd(dpb_mem_rd), .mem_raddr(dpb_mem_raddr),
		.mem_rdata(dpb_mem_rdata), .mem_rvalid(dpb_mem_rvalid),
		.luma_window_valid(dpb_luma_window_valid),
		.luma_window_idx(dpb_luma_window_idx),
		.luma_window_sample(dpb_luma_window_sample),
		.chroma_u_window_valid(dpb_chroma_u_window_valid),
		.chroma_v_window_valid(dpb_chroma_v_window_valid),
		.chroma_window_idx(dpb_chroma_window_idx),
		.chroma_window_sample(dpb_chroma_window_sample)
	);

	assign product_luma_origin_x = dpb_luma_origin_x;
	assign product_luma_origin_y = dpb_luma_origin_y;

	h264_inter_mc_part u_stream_mc (
		.luma_ref_win(dpb_luma_win),
		.chroma_u_ref_win(dpb_u_win),
		.chroma_v_ref_win(dpb_v_win),
		.luma_frac_x(dpb_luma_frac_x), .luma_frac_y(dpb_luma_frac_y),
		.chroma_frac_x(dpb_chroma_frac_x), .chroma_frac_y(dpb_chroma_frac_y),
		.part_w(dpb_part_w), .part_h(dpb_part_h),
		.pred_y(dpb_pred_y), .pred_y_valid(dpb_pred_y_valid),
		.pred_u(dpb_pred_u), .pred_u_valid(dpb_pred_u_valid),
		.pred_v(dpb_pred_v), .pred_v_valid(dpb_pred_v_valid)
	);

	// ── Inter residual add: recon = Clip1(pred + residual) ──────────────
	// Arithmetic already exists in h264_recon4x4; this expands it across the
	// full MB planes for the native-I420 inter export path.
	function automatic [7:0] inter_clip_u8;
		input signed [17:0] v;
		begin
`ifdef DECODE_STUB_FAULT_DROP_INTER_CLIP
			inter_clip_u8 = v[7:0];
`else
			if (v < 18'sd0) inter_clip_u8 = 8'd0;
			else if (v > 18'sd255) inter_clip_u8 = 8'd255;
			else inter_clip_u8 = v[7:0];
`endif
		end
	endfunction
`ifdef DECODE_STUB_FAULT_DROP_INTER_RESIDUAL
	wire signed [15:0] inter_res_y_term [0:255];
	wire signed [15:0] inter_res_u_term [0:63];
	wire signed [15:0] inter_res_v_term [0:63];
	genvar irz;
	generate
		for (irz = 0; irz < 256; irz = irz + 1) begin : gen_drop_res_y
			assign inter_res_y_term[irz] = 16'sd0;
		end
		for (irz = 0; irz < 64; irz = irz + 1) begin : gen_drop_res_c
			assign inter_res_u_term[irz] = 16'sd0;
			assign inter_res_v_term[irz] = 16'sd0;
		end
	endgenerate
`else
	wire signed [15:0] inter_res_y_term [0:255];
	wire signed [15:0] inter_res_u_term [0:63];
	wire signed [15:0] inter_res_v_term [0:63];
	genvar irk;
	generate
		for (irk = 0; irk < 256; irk = irk + 1) begin : gen_res_y
			assign inter_res_y_term[irk] = inter_res_y[irk];
		end
		for (irk = 0; irk < 64; irk = irk + 1) begin : gen_res_c
`ifdef DECODE_STUB_FAULT_SKIP_INTER_CHROMA_RESIDUAL
			assign inter_res_u_term[irk] = 16'sd0;
			assign inter_res_v_term[irk] = 16'sd0;
`else
			assign inter_res_u_term[irk] = inter_res_u[irk];
			assign inter_res_v_term[irk] = inter_res_v[irk];
`endif
		end
	endgenerate
`endif
	genvar iri;
	generate
		for (iri = 0; iri < 256; iri = iri + 1) begin : gen_inter_recon_y
			assign inter_recon_y[iri] = inter_clip_u8(
				$signed({10'd0, dpb_pred_y[iri]}) +
				{{2{inter_res_y_term[iri][15]}}, inter_res_y_term[iri]});
		end
		for (iri = 0; iri < 64; iri = iri + 1) begin : gen_inter_recon_c
			assign inter_recon_u[iri] = inter_clip_u8(
				$signed({10'd0, dpb_pred_u[iri]}) +
				{{2{inter_res_u_term[iri][15]}}, inter_res_u_term[iri]});
			assign inter_recon_v[iri] = inter_clip_u8(
				$signed({10'd0, dpb_pred_v[iri]}) +
				{{2{inter_res_v_term[iri][15]}}, inter_res_v_term[iri]});
		end
	endgenerate

	// ── Self-produced recon frame store (USE_REAL_REF_COMMIT) ──────────
	// I-slice: h264_i_res_recon_sink consumes traverse residual export and
	// writes every MB (pred=128 + residual; chroma deferred 128).
	// Legacy place path: PH_IDR_STORE still packs MB0 blk0 when sink idle.
	// P: every fetch_done parks Clip1(pred+residual) at lat_p_mb_addr.
	reg               recon_store_write_start;
	reg [15:0]        recon_store_write_mb;
	reg               recon_store_idr_mb0_pending;
	reg               recon_store_i_sink_pending;
	wire              recon_store_busy;
	wire              recon_store_done;
	reg [7:0]         idr_mb0_y [0:255];
	reg [7:0]         idr_mb0_u [0:63];
	reg [7:0]         idr_mb0_v [0:63];
	wire [7:0]        recon_store_y_mux [0:255];
	wire [7:0]        recon_store_u_mux [0:63];
	wire [7:0]        recon_store_v_mux [0:63];

	// I residual → MB plane sink
	wire        i_sink_write_req;
	wire [15:0] i_sink_write_mb;
	wire [7:0]  i_sink_y [0:255];
	wire [7:0]  i_sink_u [0:63];
	wire [7:0]  i_sink_v [0:63];
	wire [31:0] i_sink_dbg_blk, i_sink_dbg_mb, i_sink_dbg_nz;
	wire        i_sink_clear = vcl_pulse && (last_nal_type[4:0] == 5'd5);

	h264_i_res_recon_sink u_i_res_sink (
		.clk(clk), .reset(reset), .clear(i_sink_clear),
		.res_blk_valid(i_res_blk_valid),
		.res_blk_ready(i_res_blk_ready),
		.res_blk_mb_addr(i_res_blk_mb_addr),
		.res_blk_mb_x(i_res_blk_mb_x),
		.res_blk_mb_y(i_res_blk_mb_y),
		.res_blk_idx(i_res_blk_idx),
		.res_blk_is_i16(i_res_blk_is_i16),
		.res_blk_is_luma(i_res_blk_is_luma),
		.res_blk_qp(i_res_blk_qp),
		.res_blk_max_coeff(i_res_blk_max_coeff),
		.res_blk_pred_mode(i_res_blk_pred_mode),
		.res_blk_coeff(i_res_blk_coeff),
		.res_mb_end(i_res_mb_end),
		.res_mb_end_addr(i_res_mb_end_addr),
		.write_req(i_sink_write_req),
		.write_mb_addr(i_sink_write_mb),
		.write_y(i_sink_y),
		.write_u(i_sink_u),
		.write_v(i_sink_v),
		.write_busy(recon_store_busy | recon_store_pending),
		.dbg_blk_applied(i_sink_dbg_blk),
		.dbg_mb_written(i_sink_dbg_mb),
		.dbg_luma_nz(i_sink_dbg_nz)
	);

	// Tie-off residual ready when not using sink export (always-on ready if
	// USE_REAL_REF is 0 still needed so unused ports don't X).
	// i_res_blk_ready comes from sink.

	genvar rmi;
	generate
		for (rmi = 0; rmi < 256; rmi = rmi + 1) begin : gen_store_y_mux
			assign recon_store_y_mux[rmi] =
				recon_store_i_sink_pending ? i_sink_y[rmi] :
				recon_store_idr_mb0_pending ? idr_mb0_y[rmi] :
				inter_recon_y[rmi];
		end
		for (rmi = 0; rmi < 64; rmi = rmi + 1) begin : gen_store_c_mux
			assign recon_store_u_mux[rmi] =
				recon_store_i_sink_pending ? i_sink_u[rmi] :
				recon_store_idr_mb0_pending ? idr_mb0_u[rmi] :
				inter_recon_u[rmi];
			assign recon_store_v_mux[rmi] =
				recon_store_i_sink_pending ? i_sink_v[rmi] :
				recon_store_idr_mb0_pending ? idr_mb0_v[rmi] :
				inter_recon_v[rmi];
		end
	endgenerate
	h264_recon_frame_store #(
		.MB_COUNT(DPB_MB_COUNT)
	) u_recon_store (
		.clk(clk), .reset(reset),
		.clear(1'b0),
		.clear_y(8'd128), .clear_c(8'd128),
		.write_start(recon_store_write_start),
		.write_mb_addr(recon_store_write_mb[DPB_MB_AW-1:0]),
		.write_y(recon_store_y_mux),
		.write_u(recon_store_u_mux),
		.write_v(recon_store_v_mux),
		.write_busy(recon_store_busy),
		.write_done(recon_store_done),
		.read_mb_addr(dpb_fill_mb_addr[DPB_MB_AW-1:0]),
		.read_sample_idx(dpb_fill_sample_idx),
		.read_sample(recon_store_sample)
	);

	(* keep = 1 *) wire _keep_dpb_mc = dpb_fetch_busy | dpb_mem_we | |dpb_mem_waddr |
	                                   |dpb_mem_wdata | |dpb_luma_origin_x |
	                                   |dpb_luma_origin_y | |dpb_chroma_origin_x |
	                                   |dpb_chroma_origin_y | dpb_pred_u_valid[0] |
	                                   dpb_pred_v_valid[0] | |dpb_pred_u[0] | |dpb_pred_v[0] |
	                                   |dpb_inter_sig |
	                                   lat_p_skip | |lat_p_part_count | lat_p_uses_sub_mb |
	                                   lat_p_intra | |lat_p_mb_x | |lat_p_mb_y |
	                                   pending_p_skip | pending_p_uses_sub_mb | pending_p_intra |
	                                   deblock_wb_valid | |deblock_wb_mb_addr |
	                                   deblock_wb_is_ref | deblock_ref_ready_pulse |
	                                   |deblock_ref_ready_slot | deblock_commit_order_error;

	// Latch on the producer's explicit place-time pulse; residual_ok/coefficients
	// are sticky payload, not a safe valid edge.
	wire wait_done  = residual_valid | (wait_cnt == 12'd0);
	(* keep = 1 *) wire _slice_valid_observe = slice_valid;

	always @(posedge clk) begin
		wr_en         <= 1'b0;
		wr_reset_ptr  <= 1'b0;
		swap_req      <= 1'b0;
		dpb_fetch_start <= 1'b0;
		dpb_frame_done_pulse <= 1'b0;
		inter_capture_valid <= 1'b0;
		recon_store_write_start <= 1'b0;
		// Read data is combinational off the registered address, so rvalid must
		// lag mem_rd by exactly one cycle to stay aligned with h264_dpb's
		// pending_valid_d1 capture window.
		dpb_mem_rvalid <= dpb_mem_rd;
		dpb_mem_raddr_q <= dpb_mem_raddr;
`ifdef VERILATOR
		if (!reset && dpb_mem_rd_dbg_q && !dpb_mem_rvalid) begin
			$display("FAIL decode_stub DPB read latency contract: dpb_mem_rvalid did not follow dpb_mem_rd addr=0x%08x", dpb_mem_raddr_dbg_q);
			$fatal;
		end
		dpb_mem_rd_dbg_q <= reset ? 1'b0 : dpb_mem_rd;
		dpb_mem_raddr_dbg_q <= dpb_mem_raddr;
`endif
		if (dpb_luma_window_valid)
			dpb_luma_win[dpb_luma_window_idx] <= dpb_luma_window_sample;
		if (dpb_chroma_u_window_valid)
			dpb_u_win[dpb_chroma_window_idx] <= dpb_chroma_window_sample;
		if (dpb_chroma_v_window_valid)
			dpb_v_win[dpb_chroma_window_idx] <= dpb_chroma_window_sample;

		if (reset) begin
			phase         <= PH_IDLE;
			busy          <= 0;
			pix_i         <= 0;
			x             <= 0;
			y             <= 0;
			frames_out    <= 0;
			is_idr_frame  <= 0;
			is_i_frame    <= 0;
			lat_type      <= 0;
			lat_nalu      <= 0;
			lat_idr       <= 0;
			lat_mb_w      <= 0;
			lat_mb_h      <= 0;
			lat_sps       <= 0;
			lat_res_ok    <= 0;
			lat_res_tc    <= 0;
			lat_res_dc    <= 0;
			lat_qp        <= 0;
			for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
				lat_coeff[coeff_i] <= 16'sd0;
			for (coeff_i = 0; coeff_i < 256; coeff_i = coeff_i + 1)
				inter_res_y[coeff_i] <= 16'sd0;
			for (coeff_i = 0; coeff_i < 64; coeff_i = coeff_i + 1) begin
				inter_res_u[coeff_i] <= 16'sd0;
				inter_res_v[coeff_i] <= 16'sd0;
			end
			inter_res_load_pending <= 1'b0;
			recon_sig     <= 0;
			recon_dbg     <= 0;
			recon_dbg_valid <= 0;
			recon_valid   <= 0;
			wait_cnt      <= 0;
			lat_wait_res  <= 0;
			lat_res_dbg   <= 0;
			lat_p_inter   <= 0;
			lat_p_skip    <= 0;
			lat_p_mb_x    <= 0;
			lat_p_mb_y    <= 0;
			lat_p_part_mode <= 0;
			lat_p_part_count <= 0;
			lat_p_uses_sub_mb <= 0;
			lat_p_intra   <= 0;
			lat_inter_recon_ok <= 0;
			lat_p_mb_addr <= 0;
			inter_capture_valid <= 0;
			p_fetch_launch_pending <= 0;
			p_candidate_seen <= 0;
			pending_p_fetch <= 0;
			pending_p_skip <= 0;
			pending_p_mb_x <= 0;
			pending_p_mb_y <= 0;
			pending_p_part_mode <= 0;
			pending_p_part_count <= 0;
			pending_p_uses_sub_mb <= 0;
			pending_p_intra <= 0;
			trav_slice_pending <= 0;
			trav_active_slice <= 0;
			trav_got_mb <= 0;
			recon_store_write_start <= 1'b0;
			recon_store_write_mb <= 16'd0;
			recon_store_pending <= 1'b0;
			recon_store_idr_mb0_pending <= 1'b0;
			recon_store_i_sink_pending <= 1'b0;
			idr_recon_pack_pending <= 1'b0;
`ifdef VERILATOR
			dbg_store_wr_total <= 0;
			dbg_store_wr_idr <= 0;
			dbg_store_wr_p <= 0;
			dbg_store_wr_p_inter_ok <= 0;
			dbg_store_wr_p_inter_fail <= 0;
			dbg_residual_blk0_loads <= 0;
			dbg_printed_recon_counts <= 0;
			dbg_i_recon_cycles <= 32'd0;
`endif
			lat_mvd_x <= 16'sd0;
			lat_mvd_y <= 16'sd0;
			pending_mvd_x <= 16'sd0;
			pending_mvd_y <= 16'sd0;
			mv_left_x <= 16'sd0;
			mv_left_y <= 16'sd0;
			mv_left_v <= 1'b0;
			mv_d_x <= 16'sd0;
			mv_d_y <= 16'sd0;
			mv_d_v <= 1'b0;
			mv_col_al_x <= 16'sd0;
			mv_col_al_y <= 16'sd0;
			mv_col_al_v <= 1'b0;
			fetch_gap <= 2'd0;
			product_fetch_mv_x <= 16'sd0;
			product_fetch_mv_y <= 16'sd0;
			for (mv_nb_i = 0; mv_nb_i < MV_NB_MAX; mv_nb_i = mv_nb_i + 1) begin
				mv_above_x[mv_nb_i] <= 16'sd0;
				mv_above_y[mv_nb_i] <= 16'sd0;
				mv_above_v[mv_nb_i] <= 1'b0;
			end
			dpb_fetch_start <= 0;
			dpb_frame_done_pulse <= 0;
			dpb_fill_mb_addr <= '0;
			dpb_fill_sample_idx <= 9'd0;
			dpb_mem_raddr_q <= 0;
			dpb_mem_rvalid <= 0;
`ifdef VERILATOR
			dpb_mem_rd_dbg_q <= 1'b0;
			dpb_mem_raddr_dbg_q <= 32'd0;
`endif
			wr_pixel      <= 0;
		end else begin
			// Track walker slice lifetime (active only after accept)
			if (trav_mb_ready)
				trav_active_slice <= 1'b1;
			if (trav_slice_done) begin
				trav_slice_pending <= 1'b1;
				trav_active_slice <= 1'b0;
			end
			// I-sink → recon_store (shared arbiter with P/IDR place paths)
			if (i_sink_write_req && !recon_store_busy && !recon_store_pending) begin
				recon_store_write_start <= 1'b1;
				recon_store_write_mb <= i_sink_write_mb;
				recon_store_pending <= 1'b1;
				recon_store_i_sink_pending <= 1'b1;
				recon_store_idr_mb0_pending <= 1'b0;
`ifdef VERILATOR
				dbg_store_wr_total <= dbg_store_wr_total + 1;
				dbg_store_wr_idr <= dbg_store_wr_idr + 1;
`endif
			end else if (recon_store_pending && recon_store_done && recon_store_i_sink_pending) begin
				recon_store_pending <= 1'b0;
				recon_store_i_sink_pending <= 1'b0;
			end
			// One-cycle delayed residual plane load (lat_coeff → IQ/IDCT settled).
			if (inter_res_load_pending) begin
				inter_res_load_pending <= 1'b0;
				// First residual 4×4 → Y block0 raster positions.
				for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1) begin
					// Explicit 8-bit Y-plane index (avoids WIDTHEXPAND on 6-bit concat).
					inter_res_y[{2'b00, coeff_i[3:2], 2'b00, coeff_i[1:0]}] <=
						idct_residual[coeff_i][15:0];
				end
			end
			// first-MB-only FETCH fallback when walker is not driving (unit TBs
			// that tie trav_mb_valid=0). Product path disables via
			// ENABLE_FIRST_MB_P_FETCH=0. Cancel if walker produces an MB.
			if (ENABLE_FIRST_MB_P_FETCH && p_fetch_edge && !use_trav) begin
				pending_p_skip <= first_mb_p_skip;
				pending_p_mb_x <= p_req_mb_x;
				pending_p_mb_y <= p_req_mb_y;
				pending_p_part_mode <= first_mb_part_mode;
				pending_p_part_count <= first_mb_part_count;
				pending_p_uses_sub_mb <= first_mb_uses_sub_mb;
				pending_p_intra <= first_mb_intra;
				pending_mvd_x <= first_mb_mvd_x;
				pending_mvd_y <= first_mb_mvd_y;
				pending_p_fetch <= 1'b1;
			end
			if (trav_mb_valid || trav_mb_ready)
				pending_p_fetch <= 1'b0;
			if (!slice_valid)
				p_candidate_seen <= 1'b0;
			else if (p_fetch_candidate)
				p_candidate_seen <= 1'b1;
			if (phase == PH_IDLE) begin
			// Idle: on VCL wait for this NAL's place-time residual pulse.
			// While a walker slice is live, do not drop into WAIT (would clear
			// lat_inter_recon_ok and stall hold drain mid-P).
			// Type-1 P is owned by h264_p_mb_traverse — do not enter WAIT/busy
			// (spurious busy edges break full-frame stage timing and double-count).
			if (vcl_pulse && !use_trav && !trav_mb_valid &&
			    (last_nal_type[4:0] != 5'd1)) begin
				phase    <= PH_WAIT;
				busy     <= 1'b1;
				wait_cnt <= WAIT_MAX[11:0];
				lat_type <= last_nal_type;
				lat_nalu <= nalu_count;
				lat_idr  <= idr_count;
				lat_p_inter <= 1'b0;
				lat_inter_recon_ok <= 1'b0;
			end else if (vcl_pulse && (last_nal_type[4:0] == 5'd1) &&
			             !use_trav && !trav_mb_valid) begin
				// Remember P VCL identity; FETCH starts on trav_mb_ready.
				lat_type <= last_nal_type;
				lat_nalu <= nalu_count;
				lat_idr  <= idr_count;
				lat_p_inter <= 1'b0;
				lat_inter_recon_ok <= 1'b0;
			end else if (trav_mb_ready && trav_intra) begin
				// Intra-in-P: accept beat, no MC (other lanes own intra recon)
				lat_p_intra <= 1'b1;
				trav_got_mb <= 1'b0;
			end else if (trav_mb_ready) begin
				// Start / continue P slice from walker event
				phase <= PH_FETCH;
				busy <= 1'b1;
				lat_type <= 8'd1;
				lat_nalu <= nalu_count;
				lat_idr <= idr_count;
				is_idr_frame <= 1'b0;
				is_i_frame <= 1'b0;
				lat_sps <= sps_valid;
				lat_mb_w <= (mb_w == 0) ? 8'd20 : mb_w;
				lat_mb_h <= (mb_h == 0) ? 8'd15 : mb_h;
				lat_res_ok <= 1'b0;
				lat_res_tc <= 5'd0;
				lat_res_dc <= 8'sd0;
				lat_qp <= slice_qp;
				lat_wait_res <= 1'b0;
				lat_p_inter <= 1'b1;
				lat_p_skip <= trav_mb_skip;
				lat_p_mb_x <= trav_mb_x;
				lat_p_mb_y <= trav_mb_y;
				lat_p_mb_addr <= trav_mb_addr;
				lat_p_part_mode <= trav_part_mode;
				lat_p_part_count <= trav_part_count;
				lat_p_uses_sub_mb <= trav_uses_sub_mb;
				lat_p_intra <= 1'b0;
				// Opening MB of the slice: use parsed first_mb mvd; later MBs clear.
				lat_mvd_x <= (!trav_active_slice) ? first_mb_mvd_x : 16'sd0;
				lat_mvd_y <= (!trav_active_slice) ? first_mb_mvd_y : 16'sd0;
				trav_got_mb <= 1'b1;
				pending_p_fetch <= 1'b0;
				recon_valid <= 1'b0;
				recon_dbg_valid <= 1'b0;
				for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
					lat_coeff[coeff_i] <= 16'sd0;
				dpb_fetch_start <= 1'b1;
				p_fetch_launch_pending <= 1'b1;
			end else if (trav_slice_pending && !trav_active_slice) begin
				// Walker finished with no more MBs — commit/paint if we reconstructed any
				trav_slice_pending <= 1'b0;
				if (lat_inter_recon_ok) begin
					if (use_real_ref && ENABLE_DPB_REF_SEAM) begin
						phase <= PH_DPB_FILL;
						dpb_fill_mb_addr <= '0;
						dpb_fill_sample_idx <= 9'd0;
					end else begin
						phase <= PH_PAINT;
						wr_reset_ptr <= 1'b1;
					end
					busy <= 1'b1;
					pix_i <= 0;
					x <= 0;
					y <= 0;
				end
			end else if (pending_p_fetch && dpb_ref_ready && !use_trav) begin
				// Fallback: first-MB-only path when walker not producing
				phase <= PH_FETCH;
				busy <= 1'b1;
				lat_type <= 8'd1;
				lat_nalu <= nalu_count;
				lat_idr <= idr_count;
				is_idr_frame <= 1'b0;
				is_i_frame <= 1'b0;
				lat_sps <= sps_valid;
				lat_mb_w <= (mb_w == 0) ? 8'd20 : mb_w;
				lat_mb_h <= (mb_h == 0) ? 8'd15 : mb_h;
				lat_res_ok <= 1'b0;
				lat_res_tc <= 5'd0;
				lat_res_dc <= 8'sd0;
				lat_qp <= slice_qp;
				lat_wait_res <= 1'b0;
				lat_p_inter <= 1'b1;
				lat_p_skip <= pending_p_skip;
				lat_p_mb_x <= pending_p_mb_x;
				lat_p_mb_y <= pending_p_mb_y;
				lat_p_mb_addr <= {8'd0, pending_p_mb_y} * ((mb_w == 0) ? 16'd20 : {8'd0, mb_w}) +
				                 {8'd0, pending_p_mb_x};
				lat_p_part_mode <= pending_p_part_mode;
				lat_p_part_count <= pending_p_part_count;
				lat_p_uses_sub_mb <= pending_p_uses_sub_mb;
				lat_p_intra <= pending_p_intra;
				lat_mvd_x <= pending_mvd_x;
				lat_mvd_y <= pending_mvd_y;
				// D = sliding above-left; then capture above[x] for next D.
				mv_d_v <= (pending_p_mb_x != 8'd0) && (pending_p_mb_y != 8'd0) && mv_col_al_v;
				mv_d_x <= mv_col_al_x;
				mv_d_y <= mv_col_al_y;
				if ((pending_p_mb_y != 8'd0) && (pending_p_mb_x < MV_NB_MAX[7:0])) begin
					mv_col_al_v <= mv_above_v[pend_mb_x_i];
					mv_col_al_x <= mv_above_x[pend_mb_x_i];
					mv_col_al_y <= mv_above_y[pend_mb_x_i];
				end else begin
					mv_col_al_v <= 1'b0;
					mv_col_al_x <= 16'sd0;
					mv_col_al_y <= 16'sd0;
				end
				lat_inter_recon_ok <= 1'b0;
				pending_p_fetch <= 1'b0;
				trav_got_mb <= 1'b0;
				recon_valid <= 1'b0;
				recon_dbg_valid <= 1'b0;
				for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
					lat_coeff[coeff_i] <= 16'sd0;
				dpb_fetch_start <= 1'b1;
				p_fetch_launch_pending <= 1'b1;
			end
			end else if (phase == PH_WAIT) begin
			if (wait_cnt != 12'd0)
				wait_cnt <= wait_cnt - 12'd1;
			if (wait_done) begin
				// Default: IDR → DPB fill; other non-P → paint; P handled below
				// (must NOT paint P here — walker owns P frames).
				if ((lat_type[4:0] == 5'd5) && ENABLE_DPB_REF_SEAM)
					phase <= PH_DPB_FILL;
				else if (lat_type[4:0] == 5'd1)
					phase <= PH_IDLE;
				else
					phase <= PH_PAINT;
				pix_i        <= 0;
				x            <= 0;
				y            <= 0;
				// Only reset the frame writer when we actually enter a paint
				// path. Spurious wr_reset on P→IDLE corrupts full-frame stage
				// timing (fs_wr_reset→fs_swap) and throughput ratchets.
				if (!((lat_type[4:0] == 5'd1)))
					wr_reset_ptr <= 1'b1;
				is_idr_frame <= (lat_type[4:0] == 5'd5);
				is_i_frame   <= slice_is_i || (lat_type[4:0] == 5'd5);
				lat_sps      <= sps_valid;
				lat_mb_w     <= (mb_w == 0) ? 8'd20 : mb_w;
				lat_mb_h     <= (mb_h == 0) ? 8'd15 : mb_h;
				lat_res_ok   <= residual_ok;
				lat_res_tc   <= residual_tc;
				lat_res_dc   <= residual_dc;
				lat_qp       <= slice_qp;
				lat_wait_res <= residual_valid;
				lat_p_inter  <= p_fetch_candidate || pending_p_fetch || use_trav;
				lat_p_skip   <= first_mb_p_skip;
				lat_p_mb_x   <= p_req_mb_x;
				lat_p_mb_y   <= p_req_mb_y;
				lat_p_mb_addr <= first_mb_addr;
				lat_p_part_mode <= first_mb_part_mode;
				lat_p_part_count <= first_mb_part_count;
				lat_p_uses_sub_mb <= first_mb_uses_sub_mb;
				lat_p_intra  <= first_mb_intra;
				lat_mvd_x    <= first_mb_mvd_x;
				lat_mvd_y    <= first_mb_mvd_y;
				mv_d_v <= (p_req_mb_x != 8'd0) && (p_req_mb_y != 8'd0) && mv_col_al_v;
				mv_d_x <= mv_col_al_x;
				mv_d_y <= mv_col_al_y;
				if ((p_req_mb_y != 8'd0) && (p_req_mb_x < MV_NB_MAX[7:0])) begin
					mv_col_al_v <= mv_above_v[req_mb_x_i];
					mv_col_al_x <= mv_above_x[req_mb_x_i];
					mv_col_al_y <= mv_above_y[req_mb_x_i];
				end else begin
					mv_col_al_v <= 1'b0;
					mv_col_al_x <= 16'sd0;
					mv_col_al_y <= 16'sd0;
				end
				if ((lat_type[4:0] == 5'd5) && ENABLE_DPB_REF_SEAM) begin
					dpb_fill_mb_addr <= '0;
					dpb_fill_sample_idx <= 9'd0;
				end
				for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
					lat_coeff[coeff_i] <= residual_coeff[coeff_i];
				// Clear residual plane; load post-IDCT samples next cycle once
				// lat_coeff has settled into the shared IQ/IDCT path.
				for (coeff_i = 0; coeff_i < 256; coeff_i = coeff_i + 1)
					inter_res_y[coeff_i] <= 16'sd0;
				for (coeff_i = 0; coeff_i < 64; coeff_i = coeff_i + 1) begin
					inter_res_u[coeff_i] <= 16'sd0;
					inter_res_v[coeff_i] <= 16'sd0;
				end
				inter_res_load_pending <= residual_ok && !first_mb_p_skip;
				recon_valid  <= 1'b0;
				recon_dbg_valid <= 1'b0;
				// Real-ref: I-slice residual walk fills recon_store for all MBs
				// before DPB fill. Place-path residual is NOT used for store
				// (blk0-only); sink owns multi-MB recon (pred=128 + residual).
				if ((lat_type[4:0] == 5'd5) && ENABLE_DPB_REF_SEAM && use_real_ref) begin
					phase <= PH_I_RECON;
					busy <= 1'b1;
					inter_res_load_pending <= 1'b0;
`ifdef VERILATOR
					dbg_i_recon_cycles <= 32'd0;
					$display("I_RECON_ENTER trav_pend=%0d store_pend=%0d",
						trav_slice_pending, recon_store_pending);
`endif
					for (coeff_i = 0; coeff_i < 256; coeff_i = coeff_i + 1)
						inter_res_y[coeff_i] <= 16'sd0;
				end else if ((lat_type[4:0] == 5'd5) && ENABLE_DPB_REF_SEAM && !use_real_ref) begin
					// Non-real-ref legacy: single MB0 place pack
					if (residual_ok) begin
						phase <= PH_IDR_STORE;
						idr_recon_pack_pending <= 1'b1;
					end else begin
						phase <= PH_DPB_FILL;
					end
				end
				// P VCL: never paint/fetch from wait. Walker events own type-1.
				if (lat_type[4:0] == 5'd1) begin
					phase <= PH_IDLE;
					busy <= 1'b0;
				end
			end
			end else if (phase == PH_I_RECON) begin
			// Drain I residual walk into recon_store; then DPB fill.
			// i_sink_write_req accepted below (shared with other phases).
			if (trav_slice_done)
				trav_slice_pending <= 1'b1;
// Complete when walker finished and last store drained (mb_written
			// may be 0 if walk failed — still fill rather than hang).
			if (trav_slice_pending && !recon_store_pending && !i_sink_write_req) begin
				trav_slice_pending <= 1'b0;
				trav_active_slice <= 1'b0;
				phase <= PH_DPB_FILL;
				dpb_fill_mb_addr <= '0;
				dpb_fill_sample_idx <= 9'd0;
`ifdef VERILATOR
				if (!dbg_printed_recon_counts) begin
					$display("I_RECON_DONE mb_written=%0d blk_applied=%0d luma_nz_peak=%0d",
						i_sink_dbg_mb, i_sink_dbg_blk, i_sink_dbg_nz);
					dbg_printed_recon_counts <= 1'b1;
				end
`endif
			end
			end else if (phase == PH_IDR_STORE) begin
			// One-cycle delayed pack (lat_coeff → IQ/IDCT/recon_px settled),
			// then drain recon_store write before PH_DPB_FILL.
			if (idr_recon_pack_pending) begin
				idr_recon_pack_pending <= 1'b0;
				// MB0 Y: first 4×4 from shared recon_px; remainder DC fallback
				// (same policy as the RGB paint path for eyes-on diagnostics).
				for (idr_pack_i = 0; idr_pack_i < 256; idr_pack_i = idr_pack_i + 1) begin
					if (lat_res_ok && (idr_pack_i[7:4] < 4'd4) && (idr_pack_i[3:0] < 4'd4))
						idr_mb0_y[idr_pack_i] <= recon_px[{idr_pack_i[5:4], idr_pack_i[1:0]}];
					else if (lat_res_ok)
						idr_mb0_y[idr_pack_i] <= recon_from_dc;
					else
						idr_mb0_y[idr_pack_i] <= 8'd128;
				end
				for (idr_pack_i = 0; idr_pack_i < 64; idr_pack_i = idr_pack_i + 1) begin
					idr_mb0_u[idr_pack_i] <= 8'd128;
					idr_mb0_v[idr_pack_i] <= 8'd128;
				end
				recon_store_write_mb <= 16'd0;
				recon_store_write_start <= 1'b1;
				recon_store_pending <= 1'b1;
				recon_store_idr_mb0_pending <= 1'b1;
`ifdef VERILATOR
				dbg_residual_blk0_loads <= dbg_residual_blk0_loads + 1;
`endif
			end else if (recon_store_pending) begin
				if (recon_store_done) begin
					recon_store_pending <= 1'b0;
					recon_store_idr_mb0_pending <= 1'b0;
					// Drop IDR residual from the inter plane so the first P MB
					// does not inherit the IDR blk0 residual as a fake P residual.
					for (coeff_i = 0; coeff_i < 256; coeff_i = coeff_i + 1)
						inter_res_y[coeff_i] <= 16'sd0;
					for (coeff_i = 0; coeff_i < 64; coeff_i = coeff_i + 1) begin
						inter_res_u[coeff_i] <= 16'sd0;
						inter_res_v[coeff_i] <= 16'sd0;
					end
					inter_res_load_pending <= 1'b0;
					phase <= PH_DPB_FILL;
					dpb_fill_mb_addr <= '0;
					dpb_fill_sample_idx <= 9'd0;
`ifdef VERILATOR
					dbg_store_wr_total <= dbg_store_wr_total + 1;
					dbg_store_wr_idr <= dbg_store_wr_idr + 1;
`endif
				end
			end else begin
				// No write queued (should not happen) — still fill.
				phase <= PH_DPB_FILL;
				dpb_fill_mb_addr <= '0;
				dpb_fill_sample_idx <= 9'd0;
			end
			end else if (phase == PH_FETCH) begin
			if (p_fetch_launch_pending && !dpb_fetch_done) begin
				p_fetch_launch_pending <= 1'b0;
			end else if (recon_store_pending) begin
				// Drain recon store write before next MB / frame commit.
				if (recon_store_done) begin
					recon_store_pending <= 1'b0;
					recon_store_idr_mb0_pending <= 1'b0;
					recon_store_i_sink_pending <= 1'b0;
					trav_got_mb <= 1'b0;
					if (trav_mb_ready) begin
						lat_p_skip <= trav_mb_skip;
						lat_p_mb_x <= trav_mb_x;
						lat_p_mb_y <= trav_mb_y;
						lat_p_mb_addr <= trav_mb_addr;
						lat_p_part_mode <= trav_part_mode;
						lat_p_part_count <= trav_part_count;
						lat_p_uses_sub_mb <= trav_uses_sub_mb;
						lat_p_intra <= trav_intra;
						// Later MBs: no per-MB mvd yet → MVP only until walker carries mvd.
						lat_mvd_x <= 16'sd0;
						lat_mvd_y <= 16'sd0;
						trav_got_mb <= 1'b1;
						dpb_fetch_start <= 1'b1;
						p_fetch_launch_pending <= 1'b1;
					end else if (trav_slice_pending || trav_slice_done) begin
						trav_slice_pending <= 1'b0;
						trav_active_slice <= 1'b0;
						if (use_real_ref && ENABLE_DPB_REF_SEAM) begin
							phase <= PH_DPB_FILL;
							dpb_fill_mb_addr <= '0;
							dpb_fill_sample_idx <= 9'd0;
						end else begin
							phase <= PH_PAINT;
							wr_reset_ptr <= 1'b1;
						end
						pix_i <= 0;
						x <= 0;
						y <= 0;
					end else if (!use_trav) begin
						if (use_real_ref && ENABLE_DPB_REF_SEAM) begin
							phase <= PH_DPB_FILL;
							dpb_fill_mb_addr <= '0;
							dpb_fill_sample_idx <= 9'd0;
						end else begin
							phase <= PH_PAINT;
							wr_reset_ptr <= 1'b1;
						end
						pix_i <= 0;
						x <= 0;
						y <= 0;
					end
				end
			// trav_got_mb gates sticky fetch_done: without it the handler re-fires
			// every cycle after the first complete (fetch_done stays high until the
			// next fetch_start) and either spams store writes or starves the walker.
			end else if (!p_fetch_launch_pending && dpb_fetch_done && trav_got_mb) begin
				// Capture Clip1(pred+residual) via inter_recon_* (TB taps these).
				inter_capture_valid <= dpb_inter_ok;
				lat_inter_recon_ok <= lat_inter_recon_ok | dpb_inter_ok;
				// Publish product MV actually consumed by this fetch.
				product_fetch_mv_x <= fetch_mv_x_qpel;
				product_fetch_mv_y <= fetch_mv_y_qpel;
				// Commit neighbour store for subsequent MVP.
				if (lat_p_mb_x < MV_NB_MAX[7:0]) begin
					mv_above_x[lat_mb_x_i] <= prod_mv_x;
					mv_above_y[lat_mb_x_i] <= prod_mv_y;
					mv_above_v[lat_mb_x_i] <= 1'b1;
				end
				if (lat_p_mb_x + 8'd1 >= lat_mb_w) begin
					mv_left_v <= 1'b0;
					mv_left_x <= 16'sd0;
					mv_left_y <= 16'sd0;
				end else begin
					mv_left_v <= 1'b1;
					mv_left_x <= prod_mv_x;
					mv_left_y <= prod_mv_y;
				end
				// Consume this fetch result (sticky fetch_done stays high).
				trav_got_mb <= 1'b0;
				// Self-produced ref: park Clip1 samples for EVERY fetched MB.
				// Previously gated on dpb_inter_ok — that skipped store writes when
				// pred_y_valid[0] was low, leaving cold-128 holes in the reference.
				if (use_real_ref) begin
					recon_store_write_mb <= lat_p_mb_addr;
					recon_store_write_start <= 1'b1;
					recon_store_pending <= 1'b1;
					recon_store_idr_mb0_pending <= 1'b0;
`ifdef VERILATOR
					dbg_store_wr_total <= dbg_store_wr_total + 1;
					dbg_store_wr_p <= dbg_store_wr_p + 1;
					if (dpb_inter_ok)
						dbg_store_wr_p_inter_ok <= dbg_store_wr_p_inter_ok + 1;
					else
						dbg_store_wr_p_inter_fail <= dbg_store_wr_p_inter_fail + 1;
`endif
				end else begin
					// Next walker MB, or finish slice
					if (trav_mb_ready) begin
						lat_p_skip <= trav_mb_skip;
						lat_p_mb_x <= trav_mb_x;
						lat_p_mb_y <= trav_mb_y;
						lat_p_mb_addr <= trav_mb_addr;
						lat_p_part_mode <= trav_part_mode;
						lat_p_part_count <= trav_part_count;
						lat_p_uses_sub_mb <= trav_uses_sub_mb;
						lat_p_intra <= trav_intra;
						trav_got_mb <= 1'b1;
						dpb_fetch_start <= 1'b1;
						p_fetch_launch_pending <= 1'b1;
					end else if (trav_slice_pending || trav_slice_done) begin
						trav_slice_pending <= 1'b0;
						trav_active_slice <= 1'b0;
						phase <= PH_PAINT;
						pix_i <= 0;
						x <= 0;
						y <= 0;
						wr_reset_ptr <= 1'b1;
					end else if (!use_trav) begin
						// Fallback single-MB path ends after one fetch
						phase <= PH_PAINT;
						pix_i <= 0;
						x <= 0;
						y <= 0;
						wr_reset_ptr <= 1'b1;
					end
				end
				// else: stay in FETCH waiting for next trav_mb_valid
			end else if (!p_fetch_launch_pending && !dpb_fetch_busy && !trav_got_mb && !recon_store_pending) begin
				// Idle in FETCH waiting for next event
				if (trav_mb_ready) begin
					lat_p_skip <= trav_mb_skip;
					lat_p_mb_x <= trav_mb_x;
					lat_p_mb_y <= trav_mb_y;
					lat_p_mb_addr <= trav_mb_addr;
					lat_p_part_mode <= trav_part_mode;
					lat_p_part_count <= trav_part_count;
					lat_p_uses_sub_mb <= trav_uses_sub_mb;
					lat_p_intra <= trav_intra;
					lat_mvd_x <= 16'sd0;
					lat_mvd_y <= 16'sd0;
					trav_got_mb <= 1'b1;
					dpb_fetch_start <= 1'b1;
					p_fetch_launch_pending <= 1'b1;
				end else if (trav_slice_pending || trav_slice_done) begin
					trav_slice_pending <= 1'b0;
					trav_active_slice <= 1'b0;
					if (use_real_ref && ENABLE_DPB_REF_SEAM) begin
						phase <= PH_DPB_FILL;
						dpb_fill_mb_addr <= '0;
						dpb_fill_sample_idx <= 9'd0;
					end else begin
						phase <= PH_PAINT;
						wr_reset_ptr <= 1'b1;
					end
					pix_i <= 0;
					x <= 0;
					y <= 0;
				end
			end
			end else if (phase == PH_DPB_FILL) begin
			if (dpb_fill_sample_idx < 9'd384) begin
				dpb_fill_sample_idx <= dpb_fill_sample_idx + 9'd1;
			end else if (dpb_fill_sample_idx == 9'd384) begin
				if (dpb_fill_mb_addr == DPB_LAST_MB_ADDR) begin
					dpb_fill_sample_idx <= 9'd385;
				end else begin
					dpb_fill_mb_addr <= dpb_fill_mb_addr + 1'b1;
					dpb_fill_sample_idx <= 9'd0;
				end
			end else if (dpb_fill_sample_idx == 9'd385) begin
				dpb_fill_sample_idx <= 9'd386;
			end else if (deblock_ref_ready_pulse) begin
				phase <= PH_PAINT;
				pix_i <= 0;
				x <= 0;
				y <= 0;
				wr_reset_ptr <= 1'b1;
			end
			end else begin
			// Paint full frame
			wr_en    <= 1'b1;
			wr_pixel <= px_comb;
			if (pix_i == 0) begin
				recon_sig   <= lat_inter_recon_ok ? 8'h3b : (lat_res_ok ? recon_sig_comb : 8'd0);
				// Latch residual pipeline dbg on the first paint that still has
				// live lat_coeff (IDR), then keep it across later P paints.
				if (lat_res_ok && (recon_dbg_comb[0] | recon_dbg_comb[3]))
					lat_res_dbg <= recon_dbg_comb;
				recon_dbg   <= recon_dbg_comb | lat_res_dbg |
				               {1'b0, lat_inter_recon_ok, lat_p_inter, dpb_ref_ready, 4'd0};
				recon_dbg_valid <= 1'b1;
				recon_valid <= lat_res_ok | lat_inter_recon_ok;
`ifdef VERILATOR
				// Cumulative store-write localisation (last paint line is final).
				if (use_real_ref) begin
					dbg_printed_recon_counts <= dbg_printed_recon_counts + 1;
					$display("RECON_STORE_COUNTS frame_paint=%0d total=%0d idr=%0d p=%0d p_inter_ok=%0d p_inter_fail=%0d residual_blk0_loads=%0d",
						dbg_printed_recon_counts, dbg_store_wr_total, dbg_store_wr_idr, dbg_store_wr_p,
						dbg_store_wr_p_inter_ok, dbg_store_wr_p_inter_fail,
						dbg_residual_blk0_loads);
				end
`endif
			end

			if (pix_i == PIXELS[ADDR_W:0] - 1'd1) begin
				phase      <= PH_IDLE;
				busy       <= 1'b0;
				swap_req   <= 1'b1;
				frames_out <= frames_out + 1'd1;
				pix_i      <= 0;
				x          <= 0;
				y          <= 0;
				if (is_idr_frame && !ENABLE_DPB_REF_SEAM)
					dpb_frame_done_pulse <= 1'b1;
			end else begin
				pix_i <= pix_i + 1'd1;
				if (x == (width_w - 10'd1)) begin
					x <= 0;
					y <= y + 1'd1;
				end else
					x <= x + 1'd1;
			end
		end
		end
	end
endmodule
