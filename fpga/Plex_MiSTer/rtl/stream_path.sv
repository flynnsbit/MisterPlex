// Phase 3.3–3.3l-1: F3 → FIFO → NAL → SPS/PPS/slice_hdr(+full first residual) + decode_stub.
// Hybrid: stub diagnostic paint is F3-only; host F1 recon owns product present (Plex.sv).

module stream_path #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	// Self-produced DPB reference commit (no golden prefill). Sim/measure only
	// until product IDR recon is complete; default off preserves legacy path.
	parameter bit USE_REAL_REF_COMMIT = 1'b0,
	parameter bit FAULT_REAL_REF_XOR_FILL = 1'b0
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [7:0]  ioctl_dout,
	input  wire        enable,
	input  wire        flush,

	input  wire        ddr_stream_enable,
	output wire        ddr_bus_want,
	input  wire        ddr_busy,
	output wire  [7:0] ddr_burstcnt,
	output wire [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output wire        ddr_rd,
	output wire [63:0] ddr_din,
	output wire  [7:0] ddr_be,
	output wire        ddr_we,

	output wire        has_stream,
	output wire [15:0] nalu_count,
	output wire [7:0]  last_nal_type,
	output wire [31:0] bytes_in,
	output wire [31:0] bytes_seen,
	output wire [15:0] fifo_level,
	output wire        stream_ddr_active,
	output wire [31:0] stream_ddr_bytes_out,
	output wire [15:0] stream_ddr_underruns,
	output wire [15:0] stream_ddr_overruns,
	output wire [31:0] stream_ddr_host_write,
	output wire [31:0] stream_ddr_fpga_read,

	output wire        has_idr,
	output wire [7:0]  idr_count,
	output wire [7:0]  sps_count,
	output wire [7:0]  pps_count,
	output wire [7:0]  slice_count,
	output wire [15:0] stub_frames,
	output wire        stub_busy,

	output wire        sps_valid,
	output wire [7:0]  sps_profile,
	output wire [7:0]  sps_level,
	output wire [15:0] sps_width,
	output wire [15:0] sps_height,
	output wire [7:0]  sps_mb_w,
	output wire [7:0]  sps_mb_h,

	output wire        pps_valid,
	output wire        slice_valid,
	output wire [7:0]  slice_type,
	output wire        slice_is_i,
	output wire [7:0]  first_mb_type,
	output wire        has_mb_type,
	output wire        first_mb_p_skip,
	output wire [7:0]  p_skip_run,
	output wire [2:0]  first_mb_part_mode,
	output wire [2:0]  first_mb_part_count,
	output wire        first_mb_uses_sub_mb,
	output wire        first_mb_intra,
	// P-slice full MB traversal observables
	output wire        p_mb_valid,
	output wire [15:0] p_mb_addr,
	output wire [7:0]  p_mb_x,
	output wire [7:0]  p_mb_y,
	output wire        p_mb_skip,
	output wire [2:0]  p_mb_part_mode,
	output wire [2:0]  p_mb_part_count,
	output wire        p_mb_uses_sub_mb,
	output wire        p_mb_intra,
	output wire [15:0] p_mb_count,
	output wire        p_slice_done,
	output wire        p_traverse_busy,
	output wire signed [15:0] first_mb_mvd_x,
	output wire signed [15:0] first_mb_mvd_y,
	// Product MV actually driven into DPB fetch (post MVP+mvd).
	output wire signed [15:0] product_fetch_mv_x,
	output wire signed [15:0] product_fetch_mv_y,
	output wire signed [15:0] product_luma_origin_x,
	output wire signed [15:0] product_luma_origin_y,
	output wire [5:0]  slice_qp,
	output wire [1:0]  disable_deblocking_filter_idc,
	output wire signed [4:0] slice_alpha_c0_offset_div2,
	output wire signed [4:0] slice_beta_offset_div2,
	output wire signed [4:0] slice_alpha_c0_offset,
	output wire signed [4:0] slice_beta_offset,
	output wire [4:0]  residual_tc,
	output wire [1:0]  residual_t1,
	output wire        residual_ok,
	output wire signed [7:0] residual_dc,
	// 3.3l-1: residualCsum8=XOR sat8(coeff[0:15]); full coeffs for 3.3l-2 inv_quant.
	// residual_coeff may be left unconnected at top until inv_quant; kept below.
	output wire [7:0]  residual_csum,
	output wire signed [15:0] residual_coeff [0:15],
	// R-csum6 Rank3: 1-cycle ST_PLACE pulse for status residual sticky freeze
	output wire        residual_place_pulse,
	output wire [7:0]  recon_sig,
	output wire [7:0]  recon_dbg,
	output wire        recon_dbg_valid,
	output wire        recon_valid,

	output wire        fs_wr_en,
	output wire [15:0] fs_wr_pixel,
	output wire        fs_wr_reset,
	output wire        fs_swap
);

	wire        si_wr_en;
	wire [7:0]  si_wr_data;
	wire        si_wr_flush;
	wire        si_active;

	stream_ingest si (
		.clk(clk), .reset(reset),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_dout(ioctl_dout),
		.enable(enable),
		.wr_en(si_wr_en), .wr_data(si_wr_data), .wr_flush(si_wr_flush),
		.active(si_active), .bytes_in(bytes_in)
	);

	wire        ddr_wr_en;
	wire [7:0]  ddr_wr_data;
	wire        ddr_wr_flush;
	wire        bf_wr_full;

	ddr_bitstream_reader ddr_stream (
		.clk(clk), .reset(reset),
		.enable(ddr_stream_enable),
		.flush(flush),
		.out_valid(ddr_wr_en),
		.out_byte(ddr_wr_data),
		.out_flush(ddr_wr_flush),
		.out_full(bf_wr_full | si_wr_en),
		.bus_want(ddr_bus_want),
		.DDRAM_BUSY(ddr_busy),
		.DDRAM_BURSTCNT(ddr_burstcnt),
		.DDRAM_ADDR(ddr_addr),
		.DDRAM_DOUT(ddr_dout),
		.DDRAM_DOUT_READY(ddr_dout_ready),
		.DDRAM_RD(ddr_rd),
		.DDRAM_DIN(ddr_din),
		.DDRAM_BE(ddr_be),
		.DDRAM_WE(ddr_we),
		.active(stream_ddr_active),
		.bytes_out(stream_ddr_bytes_out),
		.underrun_count(stream_ddr_underruns),
		.overrun_count(stream_ddr_overruns),
		.host_write_count(stream_ddr_host_write),
		.fpga_read_count(stream_ddr_fpga_read)
	);

	wire bf_rd_en, bf_rd_empty, bf_has;
	wire [7:0] bf_rd_data;
	wire bf_wr_en = si_wr_en | ddr_wr_en;
	wire [7:0] bf_wr_data = si_wr_en ? si_wr_data : ddr_wr_data;
	wire bf_wr_flush = si_wr_flush | ddr_wr_flush | flush;

	bitstream_fifo #(.DEPTH(32768)) bfifo (
		.clk(clk), .reset(reset),
		.wr_en(bf_wr_en), .wr_data(bf_wr_data), .wr_flush(bf_wr_flush),
		.wr_full(bf_wr_full), .wr_level(fifo_level),
		.rd_en(bf_rd_en), .rd_data(bf_rd_data), .rd_empty(bf_rd_empty), .has_data(bf_has)
	);

	wire vcl_pulse, has_idr_w;
	wire [7:0] idr_c, sps_c, pps_c, slc_c;
	wire sps_cap_clear, sps_cap_en, sps_cap_end;
	wire [7:0] sps_cap_data;
	wire pps_cap_clear, pps_cap_en, pps_cap_end;
	wire [7:0] pps_cap_data;
	wire sl_cap_clear, sl_cap_en, sl_cap_end, sl_rbsp_eop, sl_is_idr, sl_nal_ref_idc_nonzero;
	wire [7:0] sl_cap_data;

	nalu_scanner scan (
		.clk(clk), .reset(reset | flush),
		.rd_data(bf_rd_data), .rd_empty(bf_rd_empty), .rd_en(bf_rd_en),
		.nalu_count(nalu_count), .last_nal_type(last_nal_type),
		.has_stream(has_stream), .bytes_seen(bytes_seen),
		.idr_count(idr_c), .sps_count(sps_c), .pps_count(pps_c), .slice_count(slc_c),
		.has_idr(has_idr_w), .vcl_pulse(vcl_pulse),
		.sps_cap_clear(sps_cap_clear), .sps_cap_en(sps_cap_en),
		.sps_cap_data(sps_cap_data), .sps_cap_end(sps_cap_end),
		.pps_cap_clear(pps_cap_clear), .pps_cap_en(pps_cap_en),
		.pps_cap_data(pps_cap_data), .pps_cap_end(pps_cap_end),
		.sl_cap_clear(sl_cap_clear), .sl_cap_en(sl_cap_en),
		.sl_cap_data(sl_cap_data), .sl_cap_end(sl_cap_end),
		.sl_rbsp_eop(sl_rbsp_eop), .sl_is_idr(sl_is_idr),
		.sl_nal_ref_idc_nonzero(sl_nal_ref_idc_nonzero)
	);

	assign has_idr     = has_idr_w;
	assign idr_count   = idr_c;
	assign sps_count   = sps_c;
	assign pps_count   = pps_c;
	assign slice_count = slc_c;

	wire [4:0] log2_fn;
	wire [2:0] poc_t;
	wire sps_busy;

	sps_parser sps (
		.clk(clk), .reset(reset | flush),
		.cap_clear(sps_cap_clear), .cap_en(sps_cap_en),
		.cap_data(sps_cap_data), .cap_end(sps_cap_end),
		.valid(sps_valid), .profile_idc(sps_profile), .level_idc(sps_level),
		.width(sps_width), .height(sps_height),
		.log2_max_frame_num(log2_fn), .poc_type(poc_t),
		.mb_width(sps_mb_w), .mb_height(sps_mb_h),
		.busy(sps_busy)
	);

	wire pps_busy, pps_cabac, pps_deblock;
	wire [7:0] pps_id_w, pps_sps_id, pps_nref;
	wire signed [7:0] pps_qp;

	pps_parser pps (
		.clk(clk), .reset(reset | flush),
		.cap_clear(pps_cap_clear), .cap_en(pps_cap_en),
		.cap_data(pps_cap_data), .cap_end(pps_cap_end),
		.valid(pps_valid), .pps_id(pps_id_w), .sps_id(pps_sps_id),
		.entropy_cabac(pps_cabac), .num_ref_l0(pps_nref),
		.pic_init_qp(pps_qp), .deblock_ctrl(pps_deblock), .busy(pps_busy)
	);

	wire sl_busy, sl_is_i, sl_has_mbt, sl_res_ok;
	wire [15:0] sl_first, sl_fn, sl_idr_pic;
	wire [7:0] sl_type, sl_pps, sl_mbt;
	wire signed [7:0] sl_qpd, sl_rdc;
	wire [5:0] sl_qp;
	wire [1:0] sl_deblock_idc;
	wire signed [4:0] sl_alpha_div2, sl_beta_div2, sl_alpha_off, sl_beta_off;
	wire [4:0] sl_rtc;
	wire [1:0] sl_rt1;
	wire sl_place_ok;
	wire [4:0] sl_place_tc;
	wire [1:0] sl_place_t1;
	wire signed [7:0] sl_place_dc;
	wire [5:0] sl_place_qp;
	wire signed [15:0] sl_place_coeff [0:15];

	// residual_csum / residual_coeff connect straight to module outputs (no
	// unpacked-array continuous assign — Quartus-friendly).
	slice_hdr_parser slp (
		.clk(clk), .reset(reset | flush),
		.cap_clear(sl_cap_clear), .cap_en(sl_cap_en),
		.cap_data(sl_cap_data), .cap_end(sl_cap_end),
		.is_idr_nal(sl_is_idr),
		.nal_ref_idc_nonzero(sl_nal_ref_idc_nonzero),
		.log2_max_frame_num(log2_fn),
		.poc_type(poc_t),
		.sps_ready(sps_valid),
		.pps_ready(pps_valid),
		.deblock_ctrl(pps_deblock),
		.pic_init_qp(pps_qp),
		.valid(slice_valid),
		.first_mb(sl_first), .slice_type(sl_type), .pps_id(sl_pps),
		.frame_num(sl_fn), .idr_pic_id(sl_idr_pic),
		.is_i_slice(sl_is_i),
		.slice_qp_delta(sl_qpd), .slice_qp(sl_qp),
		.disable_deblocking_filter_idc(sl_deblock_idc),
		.slice_alpha_c0_offset_div2(sl_alpha_div2),
		.slice_beta_offset_div2(sl_beta_div2),
		.slice_alpha_c0_offset(sl_alpha_off),
		.slice_beta_offset(sl_beta_off),
		.first_mb_type(sl_mbt), .has_mb_type(sl_has_mbt),
		.first_mb_p_skip(first_mb_p_skip),
		.p_skip_run(p_skip_run),
		.first_mb_part_mode(first_mb_part_mode),
		.first_mb_part_count(first_mb_part_count),
		.first_mb_uses_sub_mb(first_mb_uses_sub_mb),
		.first_mb_intra(first_mb_intra),
		.first_mb_mvd_x(first_mb_mvd_x),
		.first_mb_mvd_y(first_mb_mvd_y),
		.residual_tc(sl_rtc), .residual_t1(sl_rt1), .residual_ok(sl_res_ok),
		.residual_dc(sl_rdc),
		.residual_csum(residual_csum),
		.residual_coeff(residual_coeff),
		.residual_place_pulse(residual_place_pulse),
		.residual_place_ok(sl_place_ok),
		.residual_place_tc(sl_place_tc),
		.residual_place_t1(sl_place_t1),
		.residual_place_dc(sl_place_dc),
		.residual_place_qp(sl_place_qp),
		.residual_place_coeff(sl_place_coeff),
		.busy(sl_busy)
	);

	assign slice_type    = sl_type;
	assign slice_is_i    = sl_is_i;
	assign first_mb_type = sl_mbt;
	assign has_mb_type   = sl_has_mbt;
	assign slice_qp      = sl_qp;
	assign disable_deblocking_filter_idc = sl_deblock_idc;
	assign slice_alpha_c0_offset_div2 = sl_alpha_div2;
	assign slice_beta_offset_div2 = sl_beta_div2;
	assign slice_alpha_c0_offset = sl_alpha_off;
	assign slice_beta_offset = sl_beta_off;
	assign residual_tc   = sl_rtc;
	assign residual_t1   = sl_rt1;
	assign residual_ok   = sl_res_ok;
	assign residual_dc   = sl_rdc;

	// ── Full P/I-slice MB traversal (independent of first-MB residual sticky) ──
	// Side-buffer slice RBSP, then load the walker when idle so multi-slice
	// streams are not dropped while a prior walk is in progress.
	// Product: non-IDR only. Real-ref: also capture IDR for I-slice residual walk.
	// Walker self-drains (mb_ready=1) at syntax rate; 1-deep hold feeds stub.
	localparam int TRAV_BUF_MAX = 8192;
	// Under real-ref, capture IDR so I residual can fill recon_store before P.
	wire trav_cap_ok = USE_REAL_REF_COMMIT ? 1'b1 : !sl_is_idr;
	reg [7:0]  trav_buf [0:TRAV_BUF_MAX-1];
	reg [15:0] trav_buf_len;
	reg        trav_buf_ready;   // closed buffer awaiting load
	reg        trav_buf_active;  // capturing into buffer
	reg [15:0] trav_load_idx;
	reg [1:0]  trav_ld_st; // 0 idle, 1 clear, 2 load, 3 start
	reg        trav_start_r;
	reg        trav_clear_r;
	// Context latched at RBSP close so a later NAL cannot change walker inputs.
	reg        trav_lat_nal_ref;
	reg        trav_lat_deblock;
	reg        trav_lat_is_idr;
	reg signed [7:0] trav_lat_qp;
	reg [2:0]  trav_lat_nref;
	reg [4:0]  trav_lat_log2_fn;
	reg [2:0]  trav_lat_poc;
	reg [7:0]  trav_lat_mb_w, trav_lat_mb_h;
	wire       trav_in_ready;
	wire       trav_w_valid;
	// Product default: syntax walk self-drains (mb_ready=1) so p_mb_count is
	// independent of stub/DPB timing; hold samples opportunistically.
	// Real-ref measure: backpressure the walker to the 1-deep hold so MBs are
	// not dropped while decode_stub parks Clip1 samples into recon_store
	// (otherwise only a few dozen of 300 MBs ever reach the store).
	reg         hold_v;
	wire        trav_mb_ready; // from stub
	wire       trav_w_ready = USE_REAL_REF_COMMIT ? (!hold_v || trav_mb_ready) : 1'b1;
	wire [15:0] trav_w_addr;
	wire [7:0]  trav_w_x, trav_w_y;
	wire        trav_w_skip;
	wire [7:0]  trav_w_type;
	wire [2:0]  trav_w_part_mode, trav_w_part_count;
	wire        trav_w_uses_sub, trav_w_intra;
	wire [5:0]  trav_w_cbp;
	wire signed [7:0] trav_w_mb_qp;
	wire [15:0] trav_w_res_off;
	wire [15:0] trav_mb_count;
	wire        trav_slice_done, trav_busy, trav_err, trav_unsup;
	// I residual export → decode_stub sink
	wire        trav_res_blk_valid;
	wire        trav_res_blk_ready;
	wire [15:0] trav_res_blk_mb_addr;
	wire [7:0]  trav_res_blk_mb_x, trav_res_blk_mb_y;
	wire [4:0]  trav_res_blk_idx;
	wire        trav_res_blk_is_i16, trav_res_blk_is_luma;
	wire [5:0]  trav_res_blk_qp;
	wire [4:0]  trav_res_blk_max;
	wire [3:0]  trav_res_blk_pred_mode;
	wire signed [15:0] trav_res_blk_coeff [0:15];
	wire        trav_res_mb_end;
	wire [15:0] trav_res_mb_end_addr;

	wire trav_loading = (trav_ld_st == 2'd2);
	wire trav_in_valid = trav_loading && (trav_load_idx < trav_buf_len) && trav_in_ready;
	wire [7:0] trav_in_byte = trav_buf[trav_load_idx[12:0]];

	always @(posedge clk) begin
		if (reset | flush) begin
			trav_buf_len <= 16'd0;
			trav_buf_ready <= 1'b0;
			trav_buf_active <= 1'b0;
			trav_load_idx <= 16'd0;
			trav_ld_st <= 2'd0;
			trav_start_r <= 1'b0;
			trav_clear_r <= 1'b0;
			trav_lat_nal_ref <= 1'b0;
			trav_lat_deblock <= 1'b0;
			trav_lat_is_idr <= 1'b0;
			trav_lat_qp <= 8'sd26;
			trav_lat_nref <= 3'd0;
			trav_lat_log2_fn <= 5'd4;
			trav_lat_poc <= 3'd0;
			trav_lat_mb_w <= 8'd20;
			trav_lat_mb_h <= 8'd15;
		end else begin
			trav_start_r <= 1'b0;
			trav_clear_r <= 1'b0;

			// Capture slice RBSP (P always; IDR too under USE_REAL_REF_COMMIT)
			if (sl_cap_clear && trav_cap_ok) begin
				if (!trav_buf_ready && trav_ld_st == 2'd0) begin
					trav_buf_len <= 16'd0;
					trav_buf_active <= 1'b1;
`ifdef VERILATOR
					$display("TRAV_CAP_START idr=%0d", sl_is_idr);
`endif
				end
			end else if (sl_cap_clear && !trav_cap_ok) begin
				trav_buf_active <= 1'b0;
			end
			if (trav_buf_active && sl_cap_en && trav_cap_ok) begin
				if (trav_buf_len < TRAV_BUF_MAX[15:0]) begin
					trav_buf[trav_buf_len[12:0]] <= sl_cap_data;
					trav_buf_len <= trav_buf_len + 16'd1;
				end
			end
			// Close on true NAL end (not the 48 B header window)
			if (trav_buf_active && sl_rbsp_eop && trav_cap_ok) begin
				trav_buf_active <= 1'b0;
				trav_buf_ready <= 1'b1;
				trav_lat_nal_ref <= sl_nal_ref_idc_nonzero;
				trav_lat_deblock <= pps_deblock;
				trav_lat_is_idr <= sl_is_idr;
				trav_lat_qp <= pps_qp;
				trav_lat_nref <= pps_nref[2:0];
				trav_lat_log2_fn <= log2_fn;
				trav_lat_poc <= poc_t;
				trav_lat_mb_w <= sps_mb_w;
				trav_lat_mb_h <= sps_mb_h;
`ifdef VERILATOR
				$display("TRAV_CAP_EOP idr=%0d len=%0d mb_w=%0d mb_h=%0d",
					sl_is_idr, trav_buf_len, sps_mb_w, sps_mb_h);
`endif
			end

			// clear → load → start handshake into walker
			case (trav_ld_st)
			2'd0: begin
				if (trav_buf_ready && !trav_busy) begin
					trav_clear_r <= 1'b1;
					trav_load_idx <= 16'd0;
					trav_ld_st <= 2'd1;
				end
			end
			2'd1: begin
				// clear applied; begin byte load next cycle
				trav_ld_st <= 2'd2;
			end
			2'd2: begin
				if (trav_buf_len == 16'd0) begin
					trav_ld_st <= 2'd3;
				end else if (trav_in_valid) begin
					if (trav_load_idx + 16'd1 >= trav_buf_len)
						trav_ld_st <= 2'd3;
					else
						trav_load_idx <= trav_load_idx + 16'd1;
				end
			end
			default: begin
				trav_start_r <= 1'b1;
				trav_buf_ready <= 1'b0;
				trav_ld_st <= 2'd0;
`ifdef VERILATOR
				$display("TRAV_START idr=%0d len=%0d", trav_lat_is_idr, trav_buf_len);
`endif
			end
			endcase
		end
	end

	h264_p_mb_traverse #(
		.MAX_RBSP_BYTES(8192)
	) u_p_traverse (
		.clk(clk), .reset(reset | flush), .clear(trav_clear_r | reset | flush),
		.in_valid(trav_in_valid), .in_byte(trav_in_byte),
		.in_last(1'b0), .in_ready(trav_in_ready),
		.start(trav_start_r),
		.mb_width(trav_lat_mb_w), .mb_height(trav_lat_mb_h),
		.log2_max_frame_num(trav_lat_log2_fn),
		.poc_type(trav_lat_poc),
		.is_idr_nal(trav_lat_is_idr),
		.nal_ref_idc_nonzero(trav_lat_nal_ref),
		.pps_deblock_ctrl(trav_lat_deblock),
		.pps_pic_init_qp(trav_lat_qp),
		.num_ref_idx_l0_active_minus1(trav_lat_nref),
		.mb_valid(trav_w_valid), .mb_ready(trav_w_ready),
		.mb_addr(trav_w_addr), .mb_x(trav_w_x), .mb_y(trav_w_y),
		.mb_skip(trav_w_skip), .mb_type(trav_w_type),
		.part_mode(trav_w_part_mode), .part_count(trav_w_part_count),
		.uses_sub_mb(trav_w_uses_sub), .is_intra(trav_w_intra),
		.cbp(trav_w_cbp), .mb_qp(trav_w_mb_qp),
		.residual_bit_offset(trav_w_res_off),
		.res_blk_valid(trav_res_blk_valid),
		.res_blk_ready(trav_res_blk_ready),
		.res_blk_mb_addr(trav_res_blk_mb_addr),
		.res_blk_mb_x(trav_res_blk_mb_x),
		.res_blk_mb_y(trav_res_blk_mb_y),
		.res_blk_idx(trav_res_blk_idx),
		.res_blk_is_i16(trav_res_blk_is_i16),
		.res_blk_is_luma(trav_res_blk_is_luma),
		.res_blk_qp(trav_res_blk_qp),
		.res_blk_max_coeff(trav_res_blk_max),
		.res_blk_pred_mode(trav_res_blk_pred_mode),
		.res_blk_coeff(trav_res_blk_coeff),
		.res_mb_end(trav_res_mb_end),
		.res_mb_end_addr(trav_res_mb_end_addr),
		.mb_count(trav_mb_count),
		.slice_done(trav_slice_done),
		.busy(trav_busy), .error(trav_err), .unsupported(trav_unsup)
	);

	// 1-deep hold for decode_stub: sample walker beats when free; drop extras.
	// Syntax completeness is p_mb_count (self-drain), not hold delivery.
	reg [15:0]  hold_addr;
	reg [7:0]   hold_x, hold_y;
	reg         hold_skip;
	reg [2:0]   hold_pm, hold_pc;
	reg         hold_sub, hold_intra;
	wire        trav_mb_valid = hold_v;
	wire [15:0] trav_mb_addr = hold_addr;
	wire [7:0]  trav_mb_x = hold_x;
	wire [7:0]  trav_mb_y = hold_y;
	wire        trav_mb_skip = hold_skip;
	wire [2:0]  trav_part_mode = hold_pm;
	wire [2:0]  trav_part_count = hold_pc;
	wire        trav_uses_sub = hold_sub;
	wire        trav_intra = hold_intra;

	always @(posedge clk) begin
		if (reset | flush) begin
			hold_v <= 1'b0;
		end else begin
			if (hold_v && trav_mb_ready)
				hold_v <= 1'b0;
			// Load when empty or same-cycle consumer take
			if (trav_w_valid && (!hold_v || trav_mb_ready)) begin
				hold_v <= 1'b1;
				hold_addr <= trav_w_addr;
				hold_x <= trav_w_x;
				hold_y <= trav_w_y;
				hold_skip <= trav_w_skip;
				hold_pm <= trav_w_part_mode;
				hold_pc <= trav_w_part_count;
				hold_sub <= trav_w_uses_sub;
				hold_intra <= trav_w_intra;
			end
		end
	end

	// Sticky peak mb_count across slices (walker clears per start)
	reg [15:0] trav_mb_count_peak;
	reg        trav_slice_done_sticky;
	// Edge-pulse error/unsup so stub can retire a failed walk once.
	reg        trav_err_d, trav_unsup_d;
	wire       trav_fail_pulse = (trav_err & ~trav_err_d) | (trav_unsup & ~trav_unsup_d);
	wire       trav_slice_retire = trav_slice_done | trav_fail_pulse;
	always @(posedge clk) begin
		if (reset | flush) begin
			trav_mb_count_peak <= 16'd0;
			trav_slice_done_sticky <= 1'b0;
			trav_err_d <= 1'b0;
			trav_unsup_d <= 1'b0;
		end else begin
			trav_err_d <= trav_err;
			trav_unsup_d <= trav_unsup;
			trav_slice_done_sticky <= trav_slice_retire;
			if (trav_mb_count > trav_mb_count_peak)
				trav_mb_count_peak <= trav_mb_count;
		end
	end

	assign p_mb_valid = trav_w_valid;
	assign p_mb_addr = trav_w_addr;
	assign p_mb_x = trav_w_x;
	assign p_mb_y = trav_w_y;
	assign p_mb_skip = trav_w_skip;
	assign p_mb_part_mode = trav_w_part_mode;
	assign p_mb_part_count = trav_w_part_count;
	assign p_mb_uses_sub_mb = trav_w_uses_sub;
	assign p_mb_intra = trav_w_intra;
	assign p_mb_count = trav_mb_count_peak;
	assign p_slice_done = trav_slice_done_sticky;
	assign p_traverse_busy = trav_busy;

	decode_stub #(
		.WIDTH(FRAME_W),
		.HEIGHT(FRAME_H),
		.USE_REAL_REF_COMMIT(USE_REAL_REF_COMMIT),
		.ENABLE_FIRST_MB_P_FETCH(1'b0),
		.FAULT_REAL_REF_XOR_FILL(FAULT_REAL_REF_XOR_FILL)
	) stub (
		.clk(clk), .reset(reset | flush),
		.vcl_pulse(vcl_pulse),
		.last_nal_type(last_nal_type),
		.nalu_count(nalu_count),
		.idr_count(idr_c),
		.has_idr(has_idr_w),
		.sps_valid(sps_valid),
		.mb_w(sps_mb_w),
		.mb_h(sps_mb_h),
		.slice_type(sl_type),
		.slice_is_i(sl_is_i),
		.slice_valid(slice_valid),
		.first_mb_addr(sl_first),
		.has_mb_type(sl_has_mbt),
		.first_mb_p_skip(first_mb_p_skip),
		.first_mb_part_mode(first_mb_part_mode),
		.first_mb_part_count(first_mb_part_count),
		.first_mb_uses_sub_mb(first_mb_uses_sub_mb),
		.first_mb_intra(first_mb_intra),
		// Per-MB traversal feed (supersedes first-MB-only clone walk)
		.trav_mb_valid(trav_mb_valid),
		.trav_mb_ready(trav_mb_ready),
		.trav_mb_addr(trav_mb_addr),
		.trav_mb_x(trav_mb_x),
		.trav_mb_y(trav_mb_y),
		.trav_mb_skip(trav_mb_skip),
		.trav_part_mode(trav_part_mode),
		.trav_part_count(trav_part_count),
		.trav_uses_sub_mb(trav_uses_sub),
		.trav_intra(trav_intra),
		.trav_slice_done(trav_slice_retire),
		// I residual stream (real-ref I-slice recon sink)
		.i_res_blk_valid(trav_res_blk_valid),
		.i_res_blk_ready(trav_res_blk_ready),
		.i_res_blk_mb_addr(trav_res_blk_mb_addr),
		.i_res_blk_mb_x(trav_res_blk_mb_x),
		.i_res_blk_mb_y(trav_res_blk_mb_y),
		.i_res_blk_idx(trav_res_blk_idx),
		.i_res_blk_is_i16(trav_res_blk_is_i16),
		.i_res_blk_is_luma(trav_res_blk_is_luma),
		.i_res_blk_qp(trav_res_blk_qp),
		.i_res_blk_max_coeff(trav_res_blk_max),
		.i_res_blk_pred_mode(trav_res_blk_pred_mode),
		.i_res_blk_coeff(trav_res_blk_coeff),
		.i_res_mb_end(trav_res_mb_end),
		.i_res_mb_end_addr(trav_res_mb_end_addr),
		.first_mb_mvd_x(first_mb_mvd_x),
		.first_mb_mvd_y(first_mb_mvd_y),
		.residual_ok(sl_place_ok),
		.residual_tc(sl_place_tc),
		.residual_dc(sl_place_dc),
		.residual_valid(residual_place_pulse),
		.slice_qp(sl_place_qp),
		.residual_coeff(sl_place_coeff),
		.recon_sig(recon_sig),
		.recon_dbg(recon_dbg),
		.recon_dbg_valid(recon_dbg_valid),
		.recon_valid(recon_valid),
		.product_fetch_mv_x(product_fetch_mv_x),
		.product_fetch_mv_y(product_fetch_mv_y),
		.product_luma_origin_x(product_luma_origin_x),
		.product_luma_origin_y(product_luma_origin_y),
		.wr_en(fs_wr_en),
		.wr_pixel(fs_wr_pixel),
		.wr_reset_ptr(fs_wr_reset),
		.swap_req(fs_swap),
		.busy(stub_busy),
		.frames_out(stub_frames)
	);

	(* keep = 1 *) wire keep_si = si_active;
	(* keep = 1 *) wire keep_bf = bf_has;
	// Touch residual_csum + place pulse + a few coeff LSBs so place is not pruned.
	wire _keep = keep_si | keep_bf | |fifo_level | |bytes_in | stub_busy | sps_busy |
	             pps_busy | sl_busy | |pps_id_w | |pps_qp | pps_cabac | |sl_first |
	             |sl_fn | |sl_qpd | pps_deblock | |residual_csum | residual_place_pulse |
	             recon_valid | recon_dbg_valid | |recon_sig | |recon_dbg |
	             sl_place_ok | |sl_place_tc | |sl_place_t1 | |sl_place_qp |
	             residual_coeff[0][0] | residual_coeff[1][0] |
	             residual_coeff[15][0] | sl_place_coeff[0][0] | sl_place_coeff[15][0] |
	             trav_busy | trav_err | trav_unsup | |trav_mb_count | |trav_w_cbp |
	             |trav_w_type | |trav_w_res_off;

endmodule
