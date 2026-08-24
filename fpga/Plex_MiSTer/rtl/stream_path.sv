// Phase 3.3–3.3l-1 + Phase-1 FPGA wiring skeleton:
// DPB/P-slice ports live in h264_mb_ctrl (h264_dpb_one_ref + h264_p_mb_type_decode).
// One M10K DPB: 2×115200 I420 (bank_sel as +115200). Sync read. No FRAME_W, no m2, no 3rd pic.
// F3 → FIFO → NAL → SPS/PPS/slice_hdr(+full first residual) + decode_stub
// alongside h264_mb_ctrl (recon contract drop-in). Host F1 still owns product
// present (Plex.sv). mb_ctrl paint is preferred when busy/done; stub stays for
// diagnostic paint / golden recon_sig when the walker is idle.

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

	output wire        has_stream,
	output wire [15:0] nalu_count,
	output wire [7:0]  last_nal_type,
	output wire [31:0] bytes_in,
	output wire [31:0] bytes_seen,
	output wire [15:0] fifo_level,

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
	output wire [5:0]  slice_qp,
	output wire [4:0]  residual_tc,
	output wire [1:0]  residual_t1,
	output wire        residual_ok,
	output wire signed [7:0] residual_dc,
	// 3.3l-1: residualCsum8=XOR sat8(coeff[0:15]); full coeffs for 3.3l-2 inv_quant.
	// residual_coeff may be left unconnected at top until inv_quant; kept below.
	output wire [7:0]  residual_csum,
	output wire signed [8:0] residual_coeff [0:15],
	// R-csum6 Rank3: 1-cycle ST_PLACE pulse for status residual sticky freeze
	output wire        residual_place_pulse,
	output wire [7:0]  recon_sig,
	output wire [7:0]  recon_dbg,
	output wire        recon_dbg_valid,
	output wire        recon_valid,
	output wire [15:0] frames_out,

	output wire        fs_wr_en,
	output wire [15:0] fs_wr_pixel,
	output wire        fs_wr_reset,
	output wire        fs_swap,
	input  wire        fs_wr_ready,  // present accept_cmd (Plex wires F1 wr_ready)
	input  wire        fs_present_sel,  // fpga_wr | stub_allow; no default (Q17 10231)
	// Phase-1: sticky 0 until a full MB grid is reconstructed (skeleton = 0).
	output wire        product_recon_ok
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

	wire bf_rd_en, bf_rd_empty, bf_has;
	wire [7:0] bf_rd_data;

	bitstream_fifo #(.DEPTH(32768)) bfifo (
		.clk(clk), .reset(reset),
		.wr_en(si_wr_en), .wr_data(si_wr_data), .wr_flush(si_wr_flush | flush),
		.wr_full(), .wr_level(fifo_level),
		.rd_en(bf_rd_en), .rd_data(bf_rd_data), .rd_empty(bf_rd_empty), .has_data(bf_has)
	);

	wire vcl_pulse, has_idr_w;
	wire [7:0] idr_c, sps_c, pps_c, slc_c;
	wire sps_cap_clear, sps_cap_en, sps_cap_end;
	wire [7:0] sps_cap_data;
	wire pps_cap_clear, pps_cap_en, pps_cap_end;
	wire [7:0] pps_cap_data;
	wire sl_cap_clear, sl_cap_en, sl_cap_end, sl_is_idr;
	wire [7:0] sl_cap_data;
	wire sl_rbsp_clear, sl_rbsp_en, sl_rbsp_end;
	wire [7:0] sl_rbsp_data;
	wire [13:0] sl_rbsp_len;

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
		.sl_rbsp_clear(sl_rbsp_clear), .sl_rbsp_en(sl_rbsp_en),
		.sl_rbsp_data(sl_rbsp_data), .sl_rbsp_end(sl_rbsp_end),
		.sl_rbsp_len(sl_rbsp_len)
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
	wire [4:0] sl_rtc;
	wire [1:0] sl_rt1;
	wire sl_place_ok;
	wire [4:0] sl_place_tc;
	wire [1:0] sl_place_t1;
	wire signed [7:0] sl_place_dc;
	wire [5:0] sl_place_qp;
	wire signed [8:0] sl_place_coeff [0:15];
	wire [16:0] sl_bit_pos_hdr, sl_bit_pos_resid;
	wire        sl_bit_pos_valid;

	// residual_coeff stays a direct port. residual_csum / residual_place_pulse
	// are muxed after use_mb so walker select does not publish the 48B place stub.
	wire [7:0] place_csum;
	wire       place_pulse;
	slice_hdr_parser slp (
		.clk(clk), .reset(reset | flush),
		.cap_clear(sl_cap_clear), .cap_en(sl_cap_en),
		.cap_data(sl_cap_data), .cap_end(sl_cap_end),
		.is_idr_nal(sl_is_idr),
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
		.first_mb_type(sl_mbt), .has_mb_type(sl_has_mbt),
		.residual_tc(sl_rtc), .residual_t1(sl_rt1), .residual_ok(sl_res_ok),
		.residual_dc(sl_rdc),
		.residual_csum(place_csum),
		.residual_coeff(residual_coeff),
		.residual_place_pulse(place_pulse),
		.residual_place_ok(sl_place_ok),
		.residual_place_tc(sl_place_tc),
		.residual_place_t1(sl_place_t1),
		.residual_place_dc(sl_place_dc),
		.residual_place_qp(sl_place_qp),
		.residual_place_coeff(sl_place_coeff),
		.bit_pos_hdr(sl_bit_pos_hdr),
		.bit_pos_resid(sl_bit_pos_resid),
		.bit_pos_valid(sl_bit_pos_valid),
		.busy(sl_busy)
	);

	assign slice_type    = sl_type;
	assign slice_is_i    = sl_is_i;
	assign first_mb_type = sl_mbt;
	assign has_mb_type   = sl_has_mbt;
	assign slice_qp      = sl_qp;
	assign residual_tc   = sl_rtc;
	assign residual_t1   = sl_rt1;
	assign residual_dc   = sl_rdc;

	wire [7:0]  stub_recon_sig, stub_recon_dbg;
	wire        stub_recon_dbg_valid, stub_recon_valid;
	wire        stub_wr_en, stub_wr_reset, stub_swap, stub_busy_w;
	wire [15:0] stub_wr_pixel;
	wire [15:0] stub_frames_w;

	decode_stub #(
		.WIDTH(320),
		.HEIGHT(240)
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
		.residual_ok(sl_place_ok),
		.residual_tc(sl_place_tc),
		.residual_dc(sl_place_dc),
		.residual_valid(place_pulse),
		.slice_qp(sl_place_qp),
		.residual_coeff(sl_place_coeff),
		.recon_sig(stub_recon_sig),
		.recon_dbg(stub_recon_dbg),
		.recon_dbg_valid(stub_recon_dbg_valid),
		.recon_valid(stub_recon_valid),
		.wr_en(stub_wr_en),
		.wr_pixel(stub_wr_pixel),
		.wr_reset_ptr(stub_wr_reset),
		.swap_req(stub_swap),
		.busy(stub_busy_w),
		.frames_out(stub_frames_w)
	);

	wire [7:0]  mb_recon_sig, mb_recon_dbg;
	wire        mb_recon_dbg_valid, mb_recon_valid;
	wire        mb_wr_en, mb_wr_reset, mb_swap, mb_busy, mb_done;
	wire [15:0] mb_wr_pixel, mb_frames, mb_index;
	// ONE M10K: 2×115200 I420. bank_sel is +115200 on mem_*. No wrap, no FRAME_W.
	localparam int DPB_PIC_N = 115200;
	localparam int DPB_N     = 230400;
	wire        dpb_mem_we, dpb_mem_rd;
	wire [31:0] dpb_mem_waddr, dpb_mem_raddr;
	wire [7:0]  dpb_mem_wdata;
	reg  [7:0]  dpb_mem_rdata;
	reg         dpb_mem_rvalid;
	(* ramstyle = "M10K" *) reg [7:0] dpb_pic [0:DPB_N-1];
	wire        dpb_w_hit = dpb_mem_we && (dpb_mem_waddr < DPB_N[31:0]);
	always @(posedge clk) begin
		if (dpb_w_hit)
			dpb_pic[dpb_mem_waddr[17:0]] <= dpb_mem_wdata;
		dpb_mem_rvalid <= dpb_mem_rd;
		dpb_mem_rdata  <= dpb_pic[dpb_mem_raddr[17:0]];
	end

	// sl_rbsp_* = 8K VCL RBSP from nalu_scanner (confirmed >48B). sl_cap 48B
	// is unchanged and still feeds slice_hdr_parser MB0 goldens only.
	// mb_ctrl instantiates h264_bit_reader + h264_residual_seq on that RAM.
	h264_mb_ctrl #(
		.WIDTH(320),
		.HEIGHT(240)
	) mb_ctrl (
		.clk(clk), .reset(reset | flush),
		.vcl_pulse(vcl_pulse),
		.sps_valid(sps_valid),
		.mb_w(sps_mb_w),
		.mb_h(sps_mb_h),
		.slice_type(sl_type),
		.slice_is_i(sl_is_i),
		.slice_valid(slice_valid),
		.slice_qp(sl_place_qp),
		.residual_ok(sl_place_ok),
		.residual_coeff(sl_place_coeff),
		.residual_place_pulse(place_pulse),
		.first_mb(sl_first),
		.first_mb_type(sl_mbt),
		.pps_nref(pps_nref),
		.pps_deblock(pps_deblock),
		.sl_rbsp_clear(sl_rbsp_clear),
		.sl_rbsp_en(sl_rbsp_en),
		.sl_rbsp_data(sl_rbsp_data),
		.sl_rbsp_end(sl_rbsp_end),
		.sl_rbsp_len(sl_rbsp_len),
		.bit_pos_hdr(sl_bit_pos_hdr),
		.bit_pos_resid(sl_bit_pos_resid),
		.bit_pos_valid(sl_bit_pos_valid),
		.recon_sig(mb_recon_sig),
		.recon_dbg(mb_recon_dbg),
		.recon_dbg_valid(mb_recon_dbg_valid),
		.recon_valid(mb_recon_valid),
		.wr_ready(fs_wr_ready),
		.present_sel(fs_present_sel),
		.wr_en(mb_wr_en),
		.wr_pixel(mb_wr_pixel),
		.wr_reset_ptr(mb_wr_reset),
		.swap_req(mb_swap),
		.busy(mb_busy),
		.frames_out(mb_frames),
		.product_recon_ok(product_recon_ok),
		.mb_index(mb_index),
		.done(mb_done),
		.dpb_mem_we(dpb_mem_we),
		.dpb_mem_waddr(dpb_mem_waddr),
		.dpb_mem_wdata(dpb_mem_wdata),
		.dpb_mem_rd(dpb_mem_rd),
		.dpb_mem_raddr(dpb_mem_raddr),
		.dpb_mem_rdata(dpb_mem_rdata),
		.dpb_mem_rvalid(dpb_mem_rvalid)
	);

	// Prefer mb_ctrl paint + decode status when the walker is busy, done, or
	// has GRID_DONE frames_out; keep decode_stub as the idle/diagnostic source.
	wire use_mb = mb_busy | mb_done | (mb_frames != 16'd0);
	assign residual_ok = use_mb ? (mb_done | (mb_frames != 16'd0)) : sl_res_ok;
	// Gate product place pulse/csum so sticky cannot re-freeze 48B 0x2F stub.
	assign residual_place_pulse = use_mb ? 1'b0 : place_pulse;
	assign residual_csum        = use_mb ? 8'h00 : place_csum;
	assign recon_sig       = use_mb ? mb_recon_sig       : stub_recon_sig;
	assign recon_dbg       = use_mb ? mb_recon_dbg       : stub_recon_dbg;
	assign recon_dbg_valid = use_mb ? mb_recon_dbg_valid : stub_recon_dbg_valid;
	assign recon_valid     = mb_recon_valid | stub_recon_valid;
	assign frames_out      = mb_frames;  // walker GRID_DONE counter, not gated by use_mb
	// Phase 1a: only ST_PAINT after GRID_DONE may wr_en/swap HDMI DDR.
	// Stub must not write or swap this path (fit22 black+bar / recon_dbg=0xc1).
	wire paint_mb = (mb_frames != 16'd0);
	assign fs_wr_en        = paint_mb ? mb_wr_en    : 1'b0;
	assign fs_wr_pixel     = mb_wr_pixel;
	assign fs_wr_reset     = paint_mb ? mb_wr_reset : 1'b0;
	assign fs_swap         = paint_mb ? mb_swap     : 1'b0;
	assign stub_busy       = stub_busy_w;
	assign stub_frames     = stub_frames_w;

endmodule
