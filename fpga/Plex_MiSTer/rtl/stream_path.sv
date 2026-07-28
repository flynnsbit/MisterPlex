// Phase 3.3–3.3l-1: F3 → FIFO → NAL → SPS/PPS/slice_hdr(+full first residual) + decode.
// Hybrid: diagnostic paint is F3-only; host F1 recon owns product present (Plex.sv).

`ifndef DECODE_REAL_INTRA
`define DECODE_REAL_INTRA 0
`endif

module stream_path #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240
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
	output logic [15:0] stub_frames,
	output logic        stub_busy,

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
	output logic [7:0]  recon_sig,
	output logic [7:0]  recon_dbg,
	output logic        recon_dbg_valid,
	output logic        recon_valid,

	output logic        fs_wr_en,
	output logic [15:0] fs_wr_pixel,
	output logic        fs_wr_reset,
	output logic        fs_swap
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
	wire sl_cap_clear, sl_cap_en, sl_cap_end, sl_is_idr, sl_nal_ref_idc_nonzero;
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
		.sl_cap_data(sl_cap_data), .sl_cap_end(sl_cap_end), .sl_is_idr(sl_is_idr),
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

	generate
		if (`DECODE_REAL_INTRA) begin : gen_real_intra_decode
			localparam int REAL_PIXELS = FRAME_W * FRAME_H;
			localparam int REAL_ADDR_W = $clog2(REAL_PIXELS);
			localparam [3:0] R_IDLE = 4'd0,
			                 R_WAIT = 4'd1,
			                 R_PRED_WAIT = 4'd2,
			                 R_BLOCK = 4'd3,
			                 R_BLOCK_GAP = 4'd4,
			                 R_WAIT_MB = 4'd5,
			                 R_PAINT = 4'd6;
			localparam int REAL_WAIT_MAX = 4095;

			reg [3:0] real_state;
			reg [11:0] real_wait_cnt;
			reg [1:0] real_pred_wait;
			reg [3:0] real_feed_idx;
			reg [REAL_ADDR_W:0] real_pix_i;
			reg [9:0] real_x, real_ypos;
			reg [7:0] real_lat_type;
			reg [5:0] real_lat_qp;
			reg [7:0] real_lat_mb_type;
			reg real_lat_res_ok;
			reg signed [15:0] real_lat_coeff [0:15];
			reg real_mb_start;
			reg real_block_valid;
			reg [3:0] real_block_index;
			reg signed [15:0] real_block_coeff [0:15];
			reg [15:0] real_frames;
			reg real_busy;
			reg [7:0] real_recon_sig_comb;

			wire [1:0] real_i16_pred_mode =
				(real_lat_mb_type >= 8'd1 && real_lat_mb_type <= 8'd24) ?
				((real_lat_mb_type - 8'd1) & 8'd3) : 2'd2;
			wire signed [28:0] real_i16_dc [0:15];
			wire [3:0] real_i4_modes [0:15];
			wire [7:0] real_nb_top [0:15];
			wire [7:0] real_nb_left [0:15];
			wire [7:0] real_nb_topright [0:3];
			wire real_mb_recon_valid;
			wire [7:0] real_recon_y [0:255];
			wire [4:0] real_blocks_done;

			genvar real_gi;
			for (real_gi = 0; real_gi < 16; real_gi = real_gi + 1) begin : gen_real_defaults16
				assign real_i16_dc[real_gi] = 29'sd0;
				assign real_i4_modes[real_gi] = 4'd2;
				assign real_nb_top[real_gi] = 8'd128;
				assign real_nb_left[real_gi] = 8'd128;
			end
			for (real_gi = 0; real_gi < 4; real_gi = real_gi + 1) begin : gen_real_defaults4
				assign real_nb_topright[real_gi] = 8'd128;
			end

			h264_decode_top u_real_intra_decode (
				.clk(clk),
				.reset(reset | flush),
				.mb_start(real_mb_start),
				.mb_type(real_lat_mb_type),
				.mb_qp_y(real_lat_qp),
				.mb_x(8'd0),
				.mb_y(8'd0),
				.i16_pred_mode(real_i16_pred_mode),
				.block_valid(real_block_valid),
				.block_index(real_block_index),
				.block_coeff(real_block_coeff),
				.i16_dc_valid(real_mb_start),
				.i16_dc(real_i16_dc),
				.i4_modes(real_i4_modes),
				.mb_avail_left(1'b0),
				.mb_avail_top(1'b0),
				.mb_avail_topright(1'b0),
				.mb_avail_topleft(1'b0),
				.nb_top(real_nb_top),
				.nb_left(real_nb_left),
				.nb_topleft(8'd128),
				.nb_topright(real_nb_topright),
				.mb_recon_valid(real_mb_recon_valid),
				.recon_y(real_recon_y),
				.blocks_done(real_blocks_done)
			);

			integer real_i;
			always @* begin
				real_recon_sig_comb = 8'd0;
				for (real_i = 0; real_i < 256; real_i = real_i + 1)
					real_recon_sig_comb = real_recon_sig_comb ^ real_recon_y[real_i];
			end

			wire real_in_mb0 = (real_x < 10'd16) && (real_ypos < 10'd16);
			wire [7:0] real_mb0_idx = {real_ypos[3:0], real_x[3:0]};
			wire [7:0] real_luma_raw = real_recon_y[real_mb0_idx];
`ifdef STREAM_PATH_REAL_INTRA_FAULT_STUB_PIXEL
			wire [7:0] real_luma = 8'd128;
`else
			wire [7:0] real_luma = real_luma_raw;
`endif
			wire real_border = (real_x < 10'd4) || (real_x >= (FRAME_W[9:0] - 10'd4)) ||
			                   (real_ypos < 10'd4) || (real_ypos >= (FRAME_H[9:0] - 10'd4));
			wire [7:0] real_bg_r = real_border ? 8'h10 : 8'h08;
			wire [7:0] real_bg_g = real_border ? 8'hd0 : 8'h20;
			wire [7:0] real_bg_b = (real_lat_type[4:0] == 5'd5) ? 8'h20 : 8'he0;
			wire [7:0] real_rr = real_in_mb0 ? real_luma : real_bg_r;
			wire [7:0] real_gg = real_in_mb0 ? real_luma : real_bg_g;
			wire [7:0] real_bb = real_in_mb0 ? real_luma : real_bg_b;

			assign fs_wr_pixel = {real_rr[7:3], real_gg[7:2], real_bb[7:3]};
			assign stub_busy = real_busy;
			assign stub_frames = real_frames;

			integer real_si;
			always @(posedge clk) begin
				real_mb_start <= 1'b0;
				real_block_valid <= 1'b0;
				fs_wr_en <= 1'b0;
				fs_wr_reset <= 1'b0;
				fs_swap <= 1'b0;
				recon_dbg_valid <= 1'b0;
				recon_valid <= 1'b0;

				if (reset | flush) begin
					real_state <= R_IDLE;
					real_wait_cnt <= 12'd0;
					real_pred_wait <= 2'd0;
					real_feed_idx <= 4'd0;
					real_pix_i <= '0;
					real_x <= 10'd0;
					real_ypos <= 10'd0;
					real_lat_type <= 8'd0;
					real_lat_qp <= 6'd0;
					real_lat_mb_type <= 8'd0;
					real_lat_res_ok <= 1'b0;
					real_frames <= 16'd0;
					real_busy <= 1'b0;
					recon_sig <= 8'd0;
					recon_dbg <= 8'd0;
					for (real_si = 0; real_si < 16; real_si = real_si + 1) begin
						real_lat_coeff[real_si] <= 16'sd0;
						real_block_coeff[real_si] <= 16'sd0;
					end
				end else begin
					case (real_state)
					R_IDLE: begin
						if (residual_place_pulse) begin
							real_busy <= 1'b1;
							real_lat_type <= last_nal_type;
							real_lat_res_ok <= sl_place_ok;
							real_lat_qp <= sl_place_qp;
							real_lat_mb_type <= (sl_has_mbt && first_mb_intra) ? sl_mbt : 8'd0;
							for (real_si = 0; real_si < 16; real_si = real_si + 1)
								real_lat_coeff[real_si] <= sl_place_coeff[real_si];
							real_mb_start <= 1'b1;
							real_pred_wait <= 2'd0;
							real_feed_idx <= 4'd0;
							real_state <= R_PRED_WAIT;
						end else if (vcl_pulse) begin
							real_state <= R_WAIT;
							real_busy <= 1'b1;
							real_wait_cnt <= REAL_WAIT_MAX[11:0];
							real_lat_type <= last_nal_type;
						end
					end
					R_WAIT: begin
						if (real_wait_cnt != 12'd0)
							real_wait_cnt <= real_wait_cnt - 12'd1;
						if (residual_place_pulse || real_wait_cnt == 12'd0) begin
							real_lat_res_ok <= sl_place_ok;
							real_lat_qp <= sl_place_qp;
							real_lat_mb_type <= (sl_has_mbt && first_mb_intra) ? sl_mbt : 8'd0;
							for (real_si = 0; real_si < 16; real_si = real_si + 1)
								real_lat_coeff[real_si] <= sl_place_coeff[real_si];
							real_mb_start <= 1'b1;
							real_pred_wait <= 2'd0;
							real_feed_idx <= 4'd0;
							real_state <= R_PRED_WAIT;
						end
					end
					R_PRED_WAIT: begin
						if (real_pred_wait == 2'd2) begin
							real_state <= R_BLOCK;
						end else begin
							real_pred_wait <= real_pred_wait + 2'd1;
						end
					end
					R_BLOCK: begin
						real_block_valid <= 1'b1;
						real_block_index <= real_feed_idx;
						for (real_si = 0; real_si < 16; real_si = real_si + 1)
							real_block_coeff[real_si] <= (real_feed_idx == 4'd0 && real_lat_res_ok) ?
								real_lat_coeff[real_si] : 16'sd0;
						real_state <= R_BLOCK_GAP;
					end
					R_BLOCK_GAP: begin
						if (real_feed_idx == 4'd15) begin
							real_state <= R_WAIT_MB;
						end else begin
							real_feed_idx <= real_feed_idx + 4'd1;
							real_state <= R_BLOCK;
						end
					end
					R_WAIT_MB: begin
						if (real_mb_recon_valid) begin
							real_pix_i <= '0;
							real_x <= 10'd0;
							real_ypos <= 10'd0;
							fs_wr_reset <= 1'b1;
							real_state <= R_PAINT;
						end
					end
					default: begin
						fs_wr_en <= 1'b1;
						if (real_pix_i == '0) begin
							recon_sig <= real_recon_sig_comb;
							recon_dbg <= {real_lat_res_ok, real_blocks_done[4:0], 2'b01};
							recon_dbg_valid <= 1'b1;
							recon_valid <= real_lat_res_ok;
						end
						if (real_pix_i == REAL_PIXELS[REAL_ADDR_W:0] - 1'd1) begin
							real_state <= R_IDLE;
							real_busy <= 1'b0;
							fs_swap <= 1'b1;
							real_frames <= real_frames + 16'd1;
							real_pix_i <= '0;
							real_x <= 10'd0;
							real_ypos <= 10'd0;
						end else begin
							real_pix_i <= real_pix_i + 1'd1;
							if (real_x == (FRAME_W[9:0] - 10'd1)) begin
								real_x <= 10'd0;
								real_ypos <= real_ypos + 10'd1;
							end else begin
								real_x <= real_x + 10'd1;
							end
						end
					end
					endcase
				end
			end
		end else begin : gen_decode_stub
			decode_stub #(
				.WIDTH(FRAME_W),
				.HEIGHT(FRAME_H)
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
				.wr_en(fs_wr_en),
				.wr_pixel(fs_wr_pixel),
				.wr_reset_ptr(fs_wr_reset),
				.swap_req(fs_swap),
				.busy(stub_busy),
				.frames_out(stub_frames)
			);
		end
	endgenerate

	(* keep = 1 *) wire keep_si = si_active;
	(* keep = 1 *) wire keep_bf = bf_has;
	// Touch residual_csum + place pulse + a few coeff LSBs so place is not pruned.
	wire _keep = keep_si | keep_bf | |fifo_level | |bytes_in | stub_busy | sps_busy |
	             pps_busy | sl_busy | |pps_id_w | |pps_qp | pps_cabac | |sl_first |
	             |sl_fn | |sl_qpd | pps_deblock | |residual_csum | residual_place_pulse |
	             recon_valid | recon_dbg_valid | |recon_sig | |recon_dbg |
	             sl_place_ok | |sl_place_tc | |sl_place_t1 | |sl_place_qp |
	             residual_coeff[0][0] | residual_coeff[1][0] |
	             residual_coeff[15][0] | sl_place_coeff[0][0] | sl_place_coeff[15][0];

endmodule
