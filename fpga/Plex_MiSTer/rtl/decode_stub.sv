// Phase 3.3b/3.3d/3.3j/k: stand-in for H.264 soft-core.
// On each VCL NAL, wait for slice/residual probe then paint 320×240 RGB565
// diagnostic into frame_store (or residual MB0 gray when residual_ok).
// 3.3j: paint after residual_ok/slice_valid so MB0 gray matches probe;
//       hybrid product present is host F1 (see Plex.sv host_owns_fs).
// P3-3l5: publish hybrid ownership + product_recon_ok. STREAM may skip host F1
// only when product_recon_ok (full I-slice, no host_required). Unsupported /
// inter / CABAC MBs sticky-assert hybrid_host_required — never silent product-ok.

module decode_stub #(
	parameter int WIDTH  = 320,
	parameter int HEIGHT = 240,
	parameter bit ENABLE_DPB_REF_SEAM = 1'b1,
	// Mutation twin: force DPB fetch MV to zero (proves product MV path is live).
	parameter bit FAULT_FORCE_ZERO_FETCH_MV = 1'b0
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
	// Parsed first-MB mvd_l0 se(v) from slice_hdr_parser (qpel).
	input  wire signed [15:0] first_mb_mvd_x,
	input  wire signed [15:0] first_mb_mvd_y,

	// Full P-slice MB traversal events (h264_p_mb_traverse via stream_path hold).
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
	input  wire signed [15:0] trav_mvd_x,
	input  wire signed [15:0] trav_mvd_y,
	input  wire        trav_mvd_valid,
	input  wire        trav_slice_done,
	// P3-3l5: PPS entropy + first I mb_type for hybrid ownership
	input  wire        entropy_cabac,
	input  wire [7:0]  first_mb_type_i, // I-slice mb_type when has_mb_type
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

	// P3-3l5 hybrid product handoff (see h264_hybrid_mb_own.sv)
	output reg         hybrid_fpga_owned,     // last classified MB owned by FPGA
	output reg         hybrid_host_required,  // sticky: any host-required MB/CABAC/fail
	output reg         product_recon_ok,      // sticky: full I path may own present
	output reg  [2:0]  hybrid_own_code,
	output reg  [3:0]  hybrid_own_reason,

	// Product MV actually driven into h264_dpb_ref_commit / one_ref (post MVP+mvd).
	output reg  signed [15:0] product_fetch_mv_x,
	output reg  signed [15:0] product_fetch_mv_y,
	output wire signed [15:0] product_luma_origin_x,
	output wire signed [15:0] product_luma_origin_y,


	// P3-3l5 recon export tap → h264_recon_export
	output wire        exp_sample_valid,
	output wire [31:0] exp_sample_off,
	output wire [7:0]  exp_sample_data,
	output wire        exp_frame_start,
	output wire        exp_frame_done,
	output wire        exp_frame_abort,

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
	reg            p_fetch_advance;
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
	// First-MB mvd latched for the opening P MB; cleared on multi-MB advance
	// so later stub-walk MBs use MVP-only (mvd=0) until full syntax lands.
	reg signed [15:0] lat_mvd_x;
	reg signed [15:0] lat_mvd_y;
	reg signed [15:0] pending_mvd_x;
	reg signed [15:0] pending_mvd_y;

	// Walker slice lifetime (sv-traverse owns MB sequence).
	reg            trav_slice_pending;
	reg            trav_active_slice;
	reg            trav_got_mb;
	reg            p_commit_deblock_done; // sticky: deblock_mb_done is 1-cycle
	reg [15:0]     mvd_parsed_mb_count;
	reg [15:0]     mvd_nonzero_mb_count;
	// Launch-cycle neighbour snapshot (A/B/C/D) for median MVP 8.4.1.3.
	localparam int MV_NB_MAX = 40;
	reg signed [15:0] mv_left_x, mv_left_y;
	reg               mv_left_v;
	reg signed [15:0] mv_above_x [0:MV_NB_MAX-1];
	reg signed [15:0] mv_above_y [0:MV_NB_MAX-1];
	reg               mv_above_v [0:MV_NB_MAX-1];
	reg signed [15:0] mv_d_x, mv_d_y;
	reg               mv_d_v;
	reg signed [15:0] mv_col_al_x, mv_col_al_y;
	reg               mv_col_al_v;
	integer        mv_nb_i;
	// P3-3l5 hybrid latches
	reg            lat_cabac;
	reg            lat_hybrid_host;
	reg            lat_hybrid_fpga;
	reg [2:0]      lat_hybrid_code;
	reg [3:0]      lat_hybrid_reason;
	integer        coeff_i;

	// Live ownership of the currently observed MB (first-MB handoff today;
	// all-MB traversal lanes OR into lat_hybrid_host without contract change).
	wire        hy_fpga;
	wire        hy_host;
	wire        hy_product_mb;
	wire [2:0]  hy_code;
	wire [3:0]  hy_reason;
	wire        hy_is_p = slice_valid && !slice_is_i;
	wire        hy_p_inter = hy_is_p && has_mb_type && !first_mb_intra &&
	                         (first_mb_p_skip || (first_mb_part_mode <= 3'd4));
	h264_hybrid_mb_own u_hybrid_mb (
		.slice_is_i(slice_is_i || (last_nal_type[4:0] == 5'd5)),
		.entropy_cabac(entropy_cabac),
		.fail_mb(1'b0),
		.mb_valid(slice_valid && has_mb_type),
		.mb_type(first_mb_type_i),
		.is_p_slice_mb(hy_is_p),
		.p_skipped(first_mb_p_skip),
		.p_is_intra(first_mb_intra),
		.p_is_inter(hy_p_inter),
		.p_uses_sub_mb(first_mb_uses_sub_mb),
		.p_part_mode(first_mb_part_mode),
		.p_unsupported(hy_is_p && has_mb_type && !first_mb_intra && !hy_p_inter && !first_mb_p_skip),
		.fpga_owned(hy_fpga),
		.host_required(hy_host),
		.product_mb_ok(hy_product_mb),
		.own_code(hy_code),
		.own_reason(hy_reason)
	);
	wire _hy_keep = hy_product_mb;

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
	wire [7:0]        dpb_filtered_sample = (dpb_filtered_plane == 2'd0) ? (8'h20 ^ dpb_abs_x[7:0] ^ {dpb_abs_y[4:0], 3'b000}) :
	                                       (dpb_filtered_plane == 2'd1) ? (8'h80 + {2'd0, dpb_abs_x[5:0]}) :
	                                                                      (8'h80 + {2'd0, dpb_abs_y[5:0]});
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
	wire [15:0]       lat_p_next_mb_addr = lat_p_mb_addr + 16'd1;
	wire [15:0]       lat_p_next_mb_x16 = (lat_p_mb_width == 16'd0) ? 16'd0 : (lat_p_next_mb_addr % lat_p_mb_width);
	wire [15:0]       lat_p_next_mb_y16 = (lat_p_mb_width == 16'd0) ? 16'd0 : (lat_p_next_mb_addr / lat_p_mb_width);
	wire [7:0]        lat_p_next_mb_x = lat_p_next_mb_x16[7:0];
	wire [7:0]        lat_p_next_mb_y = lat_p_next_mb_y16[7:0];
	wire              p_fetch_candidate = slice_valid && !slice_is_i && has_mb_type && !first_mb_intra &&
	                                      ((first_mb_part_mode == 3'd0) || (first_mb_part_mode == 3'd1) ||
	                                       (first_mb_part_mode == 3'd2) || (first_mb_part_mode == 3'd3) ||
	                                       (first_mb_part_mode == 3'd4));
	wire              p_fetch_edge = p_fetch_candidate && !p_candidate_seen;

	// Walker owns type-1 P MB sequence when live.
	wire              use_trav = trav_active_slice || trav_slice_pending || trav_mb_valid;
	// Accept walker beats in IDLE, between FETCHes, or at end of product P-MB commit.
	wire              trav_can_accept =
		(phase == PH_IDLE) ||
		(phase == PH_FETCH && !p_fetch_launch_pending && (dpb_fetch_done || !dpb_fetch_busy)) ||
		(phase == PH_DPB_FILL && recon_p_mb_commit &&
		 (dpb_fill_sample_idx == 9'd384) &&
		 (ref_commit_deblock_mb_done || p_commit_deblock_done));
	assign trav_mb_ready = trav_mb_valid && trav_can_accept;

	// Product MVP + mvd → final qpel MV for DPB fetch (replaces hardwired 0).
	// MV neighbour array is MV_NB_MAX entries; index with clog2 width.
	localparam int MV_NB_AW = $clog2(MV_NB_MAX);
	wire [MV_NB_AW-1:0] mv_nb_x = lat_p_mb_x[MV_NB_AW-1:0];
	wire [MV_NB_AW-1:0] mv_nb_x_c = lat_p_mb_x[MV_NB_AW-1:0] + {{(MV_NB_AW-1){1'b0}}, 1'b1};
	wire              prod_avail_a = (lat_p_mb_x != 8'd0) && mv_left_v;
	wire              prod_avail_b = (lat_p_mb_y != 8'd0) &&
	                                 (lat_p_mb_x < MV_NB_MAX[7:0]) && mv_above_v[mv_nb_x];
	wire              prod_avail_c = (lat_p_mb_y != 8'd0) &&
	                                 (lat_p_mb_x + 8'd1 < lat_mb_w) &&
	                                 (lat_p_mb_x + 8'd1 < MV_NB_MAX[7:0]) &&
	                                 mv_above_v[mv_nb_x_c];
	wire              prod_avail_d = (lat_p_mb_x != 8'd0) && (lat_p_mb_y != 8'd0) && mv_d_v;
	wire signed [15:0] prod_mv_a_x = mv_left_x;
	wire signed [15:0] prod_mv_a_y = mv_left_y;
	wire signed [15:0] prod_mv_b_x = (lat_p_mb_x < MV_NB_MAX[7:0]) ? mv_above_x[mv_nb_x] : 16'sd0;
	wire signed [15:0] prod_mv_b_y = (lat_p_mb_x < MV_NB_MAX[7:0]) ? mv_above_y[mv_nb_x] : 16'sd0;
	wire signed [15:0] prod_mv_c_x = (lat_p_mb_x + 8'd1 < MV_NB_MAX[7:0]) ? mv_above_x[mv_nb_x_c] : 16'sd0;
	wire signed [15:0] prod_mv_c_y = (lat_p_mb_x + 8'd1 < MV_NB_MAX[7:0]) ? mv_above_y[mv_nb_x_c] : 16'sd0;
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


	// Recon export tap: current-frame DPB writes only.
	wire [31:0] exp_cur_base = dpb_current_base;
	wire [31:0] exp_off_raw = dpb_mem_waddr - exp_cur_base;
	assign exp_sample_valid = dpb_mem_we &&
	                          (dpb_mem_waddr >= exp_cur_base) &&
	                          (exp_off_raw < DPB_FRAME_BYTES[31:0]);
	assign exp_sample_off = exp_off_raw;
	assign exp_sample_data = dpb_mem_wdata;
	assign exp_frame_start = dpb_idr_start;
	assign exp_frame_done = ENABLE_DPB_REF_SEAM ? deblock_ref_ready_pulse : dpb_frame_done_pulse;
	assign exp_frame_abort = reset | deblock_commit_order_error;

	// DPB read port (for MC reference fetch) — 1-cycle latency
	assign dpb_mem_rdata = (dpb_mem_raddr_q < DPB_MEM_BYTES[31:0]) ?
	                       dpb_mem[dpb_mem_raddr_q[17:0]] : 8'h00;

	// ── Product recon → deblock → DPB (h264_dpb_ref_commit) ─────────────
	// Closes the diagnostic XOR fill: reconstructed MB samples stream into
	// deblock_mb, POST samples store into DPB, frame-boundary promotion is
	// owned by the commit controller. Fetch MVs are product MVP+mvd.
	reg               recon_mb_start_r;
	reg [7:0]         recon_mb_x_r, recon_mb_y_r;
	reg [DPB_MB_AW-1:0] recon_mb_addr_r;
	reg               recon_mb_is_ref_r;
	reg               recon_mb_is_intra_r;
	reg               recon_frame_done_r;
	reg               recon_sample_valid_r;
	reg [8:0]         recon_sample_idx_r;
	reg [7:0]         recon_sample_r;
	reg               recon_sample_done_r;
	reg               recon_slice_start_r;
	reg               recon_frame_boundary_r;
	reg signed [15:0] recon_mv_x_r, recon_mv_y_r;
	reg               recon_p_mb_commit; // 1 = commit single P MB after fetch, not full IDR walk
	// PH_DPB_FILL / post-P commit sequencer uses dpb_fill_* counters.
	// Sample source: IDR → residual recon_px block0 + DC/128 plane;
	//                 P   → Clip1(pred+residual) inter_recon_* planes.
	wire              recon_commit_is_p = lat_p_inter && (phase == PH_FETCH || phase == PH_DPB_FILL);
	wire [7:0]        recon_src_y = (dpb_fill_sample_idx < 9'd256) ? (
	                      recon_commit_is_p ? inter_recon_y[dpb_fill_sample_idx[7:0]] :
	                      ((dpb_fill_mb_addr == 16'd0) && (dpb_fill_sample_idx < 9'd16) && lat_res_ok) ?
	                          recon_px[{dpb_fill_sample_idx[3:2], dpb_fill_sample_idx[1:0]}] :
	                      ((dpb_fill_mb_addr == 16'd0) && lat_res_ok) ?
	                          8'd128 :
	                      8'd128
	                  ) : 8'd128;
	wire [7:0]        recon_src_u = recon_commit_is_p ?
	                      inter_recon_u[dpb_fill_sample_idx[5:0]] : 8'd128;
	wire [7:0]        recon_src_v = recon_commit_is_p ?
	                      inter_recon_v[dpb_fill_sample_idx[5:0]] : 8'd128;
	wire [7:0]        recon_src_sample =
	                      (dpb_fill_sample_idx < 9'd256) ? recon_src_y :
	                      (dpb_fill_sample_idx < 9'd320) ? recon_src_u : recon_src_v;

	wire              ref_commit_deblock_busy;
	wire              ref_commit_deblock_mb_done;
	wire              ref_commit_invalidate;
	wire              ref_commit_wb_valid;
	wire [DPB_MB_AW-1:0] ref_commit_wb_mb_addr;
	wire              ref_commit_order_error;

	h264_dpb_ref_commit #(
		.FRAME_W(WIDTH),
		.FRAME_H(HEIGHT),
		.MB_COUNT(DPB_MB_COUNT),
		.BANK0_BASE(0),
		.BANK1_BASE(DPB_FRAME_BYTES)
	) u_product_ref_commit (
		.clk(clk), .reset(reset),
		.slice_start(recon_slice_start_r),
		.idr_frame_start(vcl_pulse && (last_nal_type[4:0] == 5'd5)),
		.disable_deblocking(1'b0),
		.slice_alpha_c0_offset(5'sd0),
		.slice_beta_offset(5'sd0),
		.frame_boundary(recon_frame_boundary_r),
		.recon_mb_start(recon_mb_start_r),
		.recon_mb_x(recon_mb_x_r),
		.recon_mb_y(recon_mb_y_r),
		.recon_mb_addr(recon_mb_addr_r),
		.recon_mb_is_ref(recon_mb_is_ref_r),
		.recon_mb_is_intra(recon_mb_is_intra_r),
		.recon_frame_done(recon_frame_done_r),
		.recon_qp_y(lat_qp),
		.recon_qp_c(lat_qp),
		.recon_nz_luma(16'hFFFF),
		.recon_mv_x(recon_mv_x_r),
		.recon_mv_y(recon_mv_y_r),
		.recon_ref_idx(2'd0),
		.recon_sample_valid(recon_sample_valid_r),
		.recon_sample_idx(recon_sample_idx_r),
		.recon_sample(recon_sample_r),
		.recon_sample_done(recon_sample_done_r),
		.ref_ready(dpb_ref_ready),
		.current_base(dpb_current_base),
		.reference_base(dpb_reference_base),
		.ref_ready_pulse(deblock_ref_ready_pulse),
		.wb_valid(ref_commit_wb_valid),
		.wb_mb_addr(ref_commit_wb_mb_addr),
		.commit_order_error(ref_commit_order_error),
		.dpb_invalidate_refs(ref_commit_invalidate),
		.deblock_busy(ref_commit_deblock_busy),
		.deblock_mb_done(ref_commit_deblock_mb_done),
		.mem_we(dpb_mem_we), .mem_waddr(dpb_mem_waddr), .mem_wdata(dpb_mem_wdata),
		.mem_rd(dpb_mem_rd), .mem_raddr(dpb_mem_raddr),
		.mem_rdata(dpb_mem_rdata), .mem_rvalid(dpb_mem_rvalid),
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
		.luma_window_valid(dpb_luma_window_valid),
		.luma_window_idx(dpb_luma_window_idx),
		.luma_window_sample(dpb_luma_window_sample),
		.chroma_u_window_valid(dpb_chroma_u_window_valid),
		.chroma_v_window_valid(dpb_chroma_v_window_valid),
		.chroma_window_idx(dpb_chroma_window_idx),
		.chroma_window_sample(dpb_chroma_window_sample)
	);

	// Keep legacy net names live for _keep_dpb_mc / diagnostics.
	assign deblock_wb_valid = ref_commit_wb_valid;
	assign deblock_wb_mb_addr = ref_commit_wb_mb_addr;
	assign deblock_wb_is_ref = 1'b1;
	assign deblock_dpb_invalidate_refs = ref_commit_invalidate;
	assign deblock_ref_ready_slot = 2'd0;
	assign deblock_commit_order_error = ref_commit_order_error;
	// dpb_idr_start already ORs deblock_dpb_invalidate_refs.

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
	                                   |deblock_ref_ready_slot | deblock_commit_order_error |
	                                   |product_fetch_mv_x | |product_fetch_mv_y |
	                                   |fetch_mv_x_qpel | |fetch_mv_y_qpel |
	                                   recon_mb_start_r | recon_sample_valid_r |
	                                   recon_frame_boundary_r | ref_commit_deblock_mb_done;

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
		recon_mb_start_r <= 1'b0;
		recon_sample_valid_r <= 1'b0;
		recon_sample_done_r <= 1'b0;
		recon_frame_done_r <= 1'b0;
		recon_slice_start_r <= 1'b0;
		recon_frame_boundary_r <= 1'b0;
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
			p_fetch_advance <= 0;
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
			lat_mvd_x <= 16'sd0;
			lat_mvd_y <= 16'sd0;
			pending_mvd_x <= 16'sd0;
			pending_mvd_y <= 16'sd0;
			trav_slice_pending <= 1'b0;
			trav_active_slice <= 1'b0;
			trav_got_mb <= 1'b0;
			p_commit_deblock_done <= 1'b0;
			mvd_parsed_mb_count <= 16'd0;
			mvd_nonzero_mb_count <= 16'd0;
			mv_left_x <= 16'sd0;
			mv_left_y <= 16'sd0;
			mv_left_v <= 1'b0;
			mv_d_x <= 16'sd0;
			mv_d_y <= 16'sd0;
			mv_d_v <= 1'b0;
			mv_col_al_x <= 16'sd0;
			mv_col_al_y <= 16'sd0;
			mv_col_al_v <= 1'b0;
			product_fetch_mv_x <= 16'sd0;
			product_fetch_mv_y <= 16'sd0;
			for (mv_nb_i = 0; mv_nb_i < MV_NB_MAX; mv_nb_i = mv_nb_i + 1) begin
				mv_above_x[mv_nb_i] <= 16'sd0;
				mv_above_y[mv_nb_i] <= 16'sd0;
				mv_above_v[mv_nb_i] <= 1'b0;
			end
			recon_mb_start_r <= 1'b0;
			recon_mb_x_r <= 8'd0;
			recon_mb_y_r <= 8'd0;
			recon_mb_addr_r <= '0;
			recon_mb_is_ref_r <= 1'b0;
			recon_mb_is_intra_r <= 1'b0;
			recon_frame_done_r <= 1'b0;
			recon_sample_valid_r <= 1'b0;
			recon_sample_idx_r <= 9'd0;
			recon_sample_r <= 8'd0;
			recon_sample_done_r <= 1'b0;
			recon_slice_start_r <= 1'b0;
			recon_frame_boundary_r <= 1'b0;
			recon_mv_x_r <= 16'sd0;
			recon_mv_y_r <= 16'sd0;
			recon_p_mb_commit <= 1'b0;
			lat_cabac <= 0;
			lat_hybrid_host <= 0;
			lat_hybrid_fpga <= 0;
			lat_hybrid_code <= 0;
			lat_hybrid_reason <= 0;
			hybrid_fpga_owned <= 0;
			hybrid_host_required <= 0;
			product_recon_ok <= 0;
			hybrid_own_code <= 0;
			hybrid_own_reason <= 0;
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
			// One-cycle delayed residual plane load (lat_coeff → IQ/IDCT settled).
			if (inter_res_load_pending) begin
				inter_res_load_pending <= 1'b0;
				// First residual 4×4 → Y block0 raster positions.
				for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1) begin
					// 8-bit MB-plane index: block0 row={y[1:0],2'b00}, col=x[1:0]
					inter_res_y[{2'b00, coeff_i[3:2], 2'b00, coeff_i[1:0]}] <=
						idct_residual[coeff_i][15:0];
				end
			end
			// Sticky OR host_required while slice is live (never silent FPGA claim).
			if (entropy_cabac)
				lat_cabac <= 1'b1;
			if (slice_valid && has_mb_type) begin
				lat_hybrid_fpga <= hy_fpga;
				lat_hybrid_code <= hy_code;
				lat_hybrid_reason <= hy_reason;
				if (hy_host || entropy_cabac)
					lat_hybrid_host <= 1'b1;
			end
			// Walker slice lifetime (sticky done until P commit drains).
			if (trav_mb_ready)
				trav_active_slice <= 1'b1;
			if (trav_slice_done) begin
				trav_slice_pending <= 1'b1;
				trav_active_slice <= 1'b0;
			end
			if (p_fetch_edge && !use_trav) begin
				pending_p_fetch <= 1'b1;
				pending_p_skip <= first_mb_p_skip;
				pending_p_mb_x <= p_req_mb_x;
				pending_p_mb_y <= p_req_mb_y;
				pending_p_part_mode <= first_mb_part_mode;
				pending_p_part_count <= first_mb_part_count;
				pending_p_uses_sub_mb <= first_mb_uses_sub_mb;
				pending_p_intra <= first_mb_intra;
				pending_mvd_x <= first_mb_mvd_x;
				pending_mvd_y <= first_mb_mvd_y;
			end
			if (!slice_valid)
				p_candidate_seen <= 1'b0;
			else if (p_fetch_candidate)
				p_candidate_seen <= 1'b1;
			if (phase == PH_IDLE) begin
			// Idle: IDR/I wait for residual; type-1 P is walker-owned (no WAIT).
			if (vcl_pulse && (last_nal_type[4:0] != 5'd1)) begin
				phase    <= PH_WAIT;
				busy     <= 1'b1;
				wait_cnt <= WAIT_MAX[11:0];
				lat_type <= last_nal_type;
				lat_nalu <= nalu_count;
				lat_idr  <= idr_count;
				lat_p_inter <= 1'b0;
				lat_inter_recon_ok <= 1'b0;
				recon_slice_start_r <= 1'b1;
				// New IDR invalidates neighbour MV context.
				if (last_nal_type[4:0] == 5'd5) begin
					mv_left_v <= 1'b0;
					mv_d_v <= 1'b0;
					mv_col_al_v <= 1'b0;
					for (mv_nb_i = 0; mv_nb_i < MV_NB_MAX; mv_nb_i = mv_nb_i + 1)
						mv_above_v[mv_nb_i] <= 1'b0;
				end
				// Clear hybrid stickies for new VCL; CABAC sticky clears only on new VCL
				// so a CABAC PPS mid-stream still fails closed until next VCL samples it.
				lat_cabac <= entropy_cabac;
				lat_hybrid_host <= 1'b0;
				lat_hybrid_fpga <= 1'b0;
				lat_hybrid_code <= 3'd0;
				lat_hybrid_reason <= 4'd0;
				product_recon_ok <= 1'b0;
				hybrid_host_required <= 1'b0;
				hybrid_fpga_owned <= 1'b0;
			end else if (vcl_pulse && (last_nal_type[4:0] == 5'd1)) begin
				// Remember P VCL; FETCH starts on trav_mb_ready or first-MB fallback.
				lat_type <= last_nal_type;
				lat_nalu <= nalu_count;
				lat_idr  <= idr_count;
				lat_p_inter <= 1'b0;
				lat_inter_recon_ok <= 1'b0;
				recon_slice_start_r <= 1'b1;
				lat_cabac <= entropy_cabac;
				lat_hybrid_host <= 1'b0;
				lat_hybrid_fpga <= 1'b0;
				product_recon_ok <= 1'b0;
				hybrid_host_required <= 1'b0;
				hybrid_fpga_owned <= 1'b0;
			end else if (trav_mb_ready && trav_intra) begin
				trav_got_mb <= 1'b0;
			end else if (trav_mb_ready) begin
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
				lat_mvd_x <= trav_mvd_valid ? trav_mvd_x : 16'sd0;
				lat_mvd_y <= trav_mvd_valid ? trav_mvd_y : 16'sd0;
				if (trav_mvd_valid) begin
					mvd_parsed_mb_count <= mvd_parsed_mb_count + 16'd1;
					if ((trav_mvd_x != 16'sd0) || (trav_mvd_y != 16'sd0))
						mvd_nonzero_mb_count <= mvd_nonzero_mb_count + 16'd1;
				end
				mv_d_v <= (trav_mb_x != 8'd0) && (trav_mb_y != 8'd0) && mv_col_al_v;
				mv_d_x <= mv_col_al_x;
				mv_d_y <= mv_col_al_y;
				if ((trav_mb_y != 8'd0) && (trav_mb_x < MV_NB_MAX[7:0])) begin
					mv_col_al_v <= mv_above_v[trav_mb_x[MV_NB_AW-1:0]];
					mv_col_al_x <= mv_above_x[trav_mb_x[MV_NB_AW-1:0]];
					mv_col_al_y <= mv_above_y[trav_mb_x[MV_NB_AW-1:0]];
				end else begin
					mv_col_al_v <= 1'b0;
					mv_col_al_x <= 16'sd0;
					mv_col_al_y <= 16'sd0;
				end
				trav_got_mb <= 1'b1;
				lat_hybrid_host <= 1'b1;
				lat_hybrid_fpga <= 1'b0;
				lat_hybrid_code <= 3'd1;
				lat_hybrid_reason <= 4'd5;
				product_recon_ok <= 1'b0;
				recon_valid <= 1'b0;
				recon_dbg_valid <= 1'b0;
				for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
					lat_coeff[coeff_i] <= 16'sd0;
				dpb_fetch_start <= 1'b1;
				p_fetch_launch_pending <= 1'b1;
			end else if (pending_p_fetch && dpb_ref_ready && !use_trav) begin
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
				mv_d_v <= (pending_p_mb_x != 8'd0) && (pending_p_mb_y != 8'd0) && mv_col_al_v;
				mv_d_x <= mv_col_al_x;
				mv_d_y <= mv_col_al_y;
				if ((pending_p_mb_y != 8'd0) && (pending_p_mb_x < MV_NB_MAX[7:0])) begin
					mv_col_al_v <= mv_above_v[pending_p_mb_x[MV_NB_AW-1:0]];
					mv_col_al_x <= mv_above_x[pending_p_mb_x[MV_NB_AW-1:0]];
					mv_col_al_y <= mv_above_y[pending_p_mb_x[MV_NB_AW-1:0]];
				end else begin
					mv_col_al_v <= 1'b0;
					mv_col_al_x <= 16'sd0;
					mv_col_al_y <= 16'sd0;
				end
				lat_inter_recon_ok <= 1'b0;
				// P-fetch path is host-required under default CAP_INTER_*=0.
				lat_hybrid_host <= 1'b1;
				lat_hybrid_fpga <= 1'b0;
				lat_hybrid_code <= 3'd1; // OWN_HOST_INTER
				lat_hybrid_reason <= 4'd5; // RSN_INTER
				product_recon_ok <= 1'b0;
				pending_p_fetch <= 1'b0;
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
				phase        <= ((lat_type[4:0] == 5'd5) && ENABLE_DPB_REF_SEAM ? PH_DPB_FILL : PH_PAINT);
				pix_i        <= 0;
				x            <= 0;
				y            <= 0;
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
				lat_p_inter  <= p_fetch_candidate || pending_p_fetch;
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
				// Capture hybrid ownership at residual place time.
				lat_cabac <= lat_cabac | entropy_cabac;
				if (has_mb_type) begin
					lat_hybrid_fpga <= hy_fpga;
					lat_hybrid_code <= hy_code;
					lat_hybrid_reason <= hy_reason;
					if (hy_host || entropy_cabac)
						lat_hybrid_host <= 1'b1;
				end else if (!slice_is_i && !(lat_type[4:0] == 5'd5)) begin
					// P/B without mb_type yet: fail closed to host
					lat_hybrid_host <= 1'b1;
					lat_hybrid_fpga <= 1'b0;
					lat_hybrid_code <= 3'd6;
					lat_hybrid_reason <= 4'd8;
				end
				if ((lat_type[4:0] == 5'd5) && ENABLE_DPB_REF_SEAM) begin
					dpb_fill_mb_addr <= '0;
					dpb_fill_sample_idx <= 9'd0;
					recon_p_mb_commit <= 1'b0;
					recon_mb_is_intra_r <= 1'b1;
					recon_mb_is_ref_r <= 1'b1;
					recon_mv_x_r <= 16'sd0;
					recon_mv_y_r <= 16'sd0;
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
				if (p_fetch_candidate && dpb_ref_ready && !use_trav) begin
					phase <= PH_FETCH;
					dpb_fetch_start <= 1'b1;
					p_fetch_launch_pending <= 1'b1;
					pending_p_fetch <= 1'b0;
				end
			end
			end else if (p_fetch_advance && !use_trav) begin
				lat_p_mb_addr <= lat_p_next_mb_addr;
				lat_p_mb_x <= lat_p_next_mb_x;
				lat_p_mb_y <= lat_p_next_mb_y;
				lat_mvd_x <= 16'sd0;
				lat_mvd_y <= 16'sd0;
				mv_d_v <= (lat_p_next_mb_x != 8'd0) && (lat_p_next_mb_y != 8'd0) && mv_col_al_v;
				mv_d_x <= mv_col_al_x;
				mv_d_y <= mv_col_al_y;
				if ((lat_p_next_mb_y != 8'd0) && (lat_p_next_mb_x < MV_NB_MAX[7:0])) begin
					mv_col_al_v <= mv_above_v[lat_p_next_mb_x[MV_NB_AW-1:0]];
					mv_col_al_x <= mv_above_x[lat_p_next_mb_x[MV_NB_AW-1:0]];
					mv_col_al_y <= mv_above_y[lat_p_next_mb_x[MV_NB_AW-1:0]];
				end else begin
					mv_col_al_v <= 1'b0;
					mv_col_al_x <= 16'sd0;
					mv_col_al_y <= 16'sd0;
				end
				// Subsequent P MBs: residual plane cleared until per-MB residual
				// walk is connected (CBP-gated CAVLC in h264_decode_core).
				for (coeff_i = 0; coeff_i < 256; coeff_i = coeff_i + 1)
					inter_res_y[coeff_i] <= 16'sd0;
				for (coeff_i = 0; coeff_i < 64; coeff_i = coeff_i + 1) begin
					inter_res_u[coeff_i] <= 16'sd0;
					inter_res_v[coeff_i] <= 16'sd0;
				end
				// Advancing across P MBs: still host-required under default caps.
				lat_hybrid_host <= 1'b1;
				dpb_fetch_start <= 1'b1;
				p_fetch_launch_pending <= 1'b1;
				p_fetch_advance <= 1'b0;
			end else if (phase == PH_FETCH) begin
			if (p_fetch_launch_pending && !dpb_fetch_done) begin
				p_fetch_launch_pending <= 1'b0;
			end else if (!p_fetch_launch_pending && dpb_fetch_done) begin
				// Capture Clip1(pred+residual) via inter_recon_* (TB taps these).
				inter_capture_valid <= dpb_inter_ok;
				lat_inter_recon_ok <= lat_inter_recon_ok | dpb_inter_ok;
				// Publish product MV actually consumed by this fetch.
				product_fetch_mv_x <= fetch_mv_x_qpel;
				product_fetch_mv_y <= fetch_mv_y_qpel;
				// Commit neighbour store for subsequent MVP.
				if (lat_p_mb_x < MV_NB_MAX[7:0]) begin
					mv_above_x[lat_p_mb_x[MV_NB_AW-1:0]] <= prod_mv_x;
					mv_above_y[lat_p_mb_x[MV_NB_AW-1:0]] <= prod_mv_y;
					mv_above_v[lat_p_mb_x[MV_NB_AW-1:0]] <= 1'b1;
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
				// Inter diagnostic may set recon_sig, but product hybrid stays host.
				lat_hybrid_host <= 1'b1;
				// Stream Clip1(pred+residual) into product ref-commit (deblocked DPB).
				phase <= PH_DPB_FILL;
				recon_p_mb_commit <= 1'b1;
				dpb_fill_mb_addr <= lat_p_mb_addr;
				dpb_fill_sample_idx <= 9'd0;
				recon_mb_is_intra_r <= 1'b0;
				recon_mb_is_ref_r <= 1'b1;
				recon_mv_x_r <= fetch_mv_x_qpel;
				recon_mv_y_r <= fetch_mv_y_qpel;
			end
			end else if (phase == PH_DPB_FILL) begin
			// Product recon sample stream → h264_dpb_ref_commit (deblock + DPB store).
			if (dpb_fill_sample_idx < 9'd384) begin
				if (dpb_fill_sample_idx == 9'd0) begin
					recon_mb_start_r <= 1'b1;
					recon_mb_x_r <= recon_p_mb_commit ? lat_p_mb_x : dpb_fill_mb_x;
					recon_mb_y_r <= recon_p_mb_commit ? lat_p_mb_y : dpb_fill_mb_y;
					recon_mb_addr_r <= recon_p_mb_commit ? lat_p_mb_addr[DPB_MB_AW-1:0]
					                                     : dpb_fill_mb_addr[DPB_MB_AW-1:0];
				end
				recon_sample_valid_r <= 1'b1;
				recon_sample_idx_r <= dpb_fill_sample_idx;
				recon_sample_r <= recon_src_sample;
				recon_sample_done_r <= (dpb_fill_sample_idx == 9'd383);
				dpb_fill_sample_idx <= dpb_fill_sample_idx + 9'd1;
			end else if (dpb_fill_sample_idx == 9'd384) begin
				// Wait for in-loop deblock MB completion before next MB / promote.
				// mb_done is a 1-cycle pulse — latch so trav-wait cannot miss it.
				if (ref_commit_deblock_mb_done)
					p_commit_deblock_done <= 1'b1;
				if (ref_commit_deblock_mb_done || p_commit_deblock_done) begin
					if (recon_p_mb_commit) begin
						// Single P-MB commit complete — next trav MB, slice end, or fallback.
						trav_got_mb <= 1'b0;
						if (trav_mb_ready && !trav_intra) begin
							recon_p_mb_commit <= 1'b0;
							p_commit_deblock_done <= 1'b0;
							phase <= PH_FETCH;
							lat_p_skip <= trav_mb_skip;
							lat_p_mb_x <= trav_mb_x;
							lat_p_mb_y <= trav_mb_y;
							lat_p_mb_addr <= trav_mb_addr;
							lat_p_part_mode <= trav_part_mode;
							lat_p_part_count <= trav_part_count;
							lat_p_uses_sub_mb <= trav_uses_sub_mb;
							lat_p_intra <= 1'b0;
							lat_mvd_x <= trav_mvd_valid ? trav_mvd_x : 16'sd0;
							lat_mvd_y <= trav_mvd_valid ? trav_mvd_y : 16'sd0;
							if (trav_mvd_valid) begin
								mvd_parsed_mb_count <= mvd_parsed_mb_count + 16'd1;
								if ((trav_mvd_x != 16'sd0) || (trav_mvd_y != 16'sd0))
									mvd_nonzero_mb_count <= mvd_nonzero_mb_count + 16'd1;
							end
							mv_d_v <= (trav_mb_x != 8'd0) && (trav_mb_y != 8'd0) && mv_col_al_v;
							mv_d_x <= mv_col_al_x;
							mv_d_y <= mv_col_al_y;
							if ((trav_mb_y != 8'd0) && (trav_mb_x < MV_NB_MAX[7:0])) begin
								mv_col_al_v <= mv_above_v[trav_mb_x[MV_NB_AW-1:0]];
								mv_col_al_x <= mv_above_x[trav_mb_x[MV_NB_AW-1:0]];
								mv_col_al_y <= mv_above_y[trav_mb_x[MV_NB_AW-1:0]];
							end else begin
								mv_col_al_v <= 1'b0;
								mv_col_al_x <= 16'sd0;
								mv_col_al_y <= 16'sd0;
							end
							trav_got_mb <= 1'b1;
							dpb_fetch_start <= 1'b1;
							p_fetch_launch_pending <= 1'b1;
						end else if (trav_mb_ready && trav_intra) begin
							// consume intra-in-P beat; stay armed for next
							trav_got_mb <= 1'b0;
						end else if (trav_slice_pending || trav_slice_done) begin
							recon_p_mb_commit <= 1'b0;
							p_commit_deblock_done <= 1'b0;
							trav_slice_pending <= 1'b0;
							trav_active_slice <= 1'b0;
							recon_frame_done_r <= 1'b1;
							dpb_fill_sample_idx <= 9'd385;
						end else if (use_trav) begin
							// Wait for next walker beat; keep recon_p_mb_commit + sticky done.
						end else if (lat_p_inter && (lat_p_next_mb_addr <= DPB_LAST_MB_ADDR)) begin
							recon_p_mb_commit <= 1'b0;
							p_commit_deblock_done <= 1'b0;
							phase <= PH_FETCH;
							p_fetch_advance <= 1'b1;
						end else begin
							// Last P MB (fallback path): frame_done then boundary.
							recon_p_mb_commit <= 1'b0;
							p_commit_deblock_done <= 1'b0;
							recon_frame_done_r <= 1'b1;
							dpb_fill_sample_idx <= 9'd385;
						end
					end else if (dpb_fill_mb_addr == DPB_LAST_MB_ADDR) begin
						p_commit_deblock_done <= 1'b0;
						recon_frame_done_r <= 1'b1;
						dpb_fill_sample_idx <= 9'd385;
					end else begin
						p_commit_deblock_done <= 1'b0;
						dpb_fill_mb_addr <= dpb_fill_mb_addr + 1'b1;
						dpb_fill_sample_idx <= 9'd0;
					end
				end
			end else if (dpb_fill_sample_idx == 9'd385) begin
				// frame_boundary one cycle after terminal MB commit (ref_pending race).
				recon_frame_boundary_r <= 1'b1;
				dpb_fill_sample_idx <= 9'd386;
			end else if (dpb_fill_sample_idx == 9'd386) begin
				// Allow registered ref_ready_pulse to rise; always paint next.
				dpb_fill_sample_idx <= 9'd387;
			end else if (dpb_fill_sample_idx >= 9'd387) begin
				// Paint regardless of promote pulse — P fetch still keys off ref_ready.
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
				recon_dbg   <= recon_dbg_comb | {1'b0, lat_inter_recon_ok, lat_p_inter, dpb_ref_ready, 4'd0};
				recon_dbg_valid <= 1'b1;
				// Diagnostic recon_valid unchanged; product_recon_ok is separate.
				recon_valid <= lat_res_ok | lat_inter_recon_ok;
				hybrid_fpga_owned <= lat_hybrid_fpga && !lat_hybrid_host && !lat_cabac;
				hybrid_host_required <= lat_hybrid_host | lat_cabac | lat_p_inter;
				hybrid_own_code <= lat_hybrid_code;
				hybrid_own_reason <= lat_hybrid_reason;
				// Doc §3.3l-5: STREAM may skip host F1 only when FPGA recon_ok on a
				// pure FPGA-owned I-slice. Inter/CABAC/fail → never product_recon_ok.
				// residual_ok here is first-MB probe, not full-frame mae; software must
				// still require competitive mae before acting on this sticky.
				product_recon_ok <= is_i_frame && lat_res_ok && lat_hybrid_fpga &&
				                    !lat_hybrid_host && !lat_cabac && !lat_p_inter;
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
