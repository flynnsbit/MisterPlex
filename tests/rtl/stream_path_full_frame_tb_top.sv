// Testbench-only top for full-frame stream_path presentation comparison.
// The product stream_path RTL is instantiated unchanged; FAULT_PIXEL_XOR only
// perturbs the testbench-visible output so the comparator has a behavior red path.
`default_nettype none

module stream_path_full_frame_tb #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter bit FAULT_PIXEL_XOR = 1'b0,
	parameter bit FAULT_TRACE_COEFF0_PLUS1 = 1'b0
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [7:0]  ioctl_dout,
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
	output wire [7:0]  recon_sig,
	output wire [7:0]  recon_dbg,
	output wire        recon_valid,
	output wire [5:0]  trace_slice_qp,
	output wire [4:0]  trace_residual_tc,
	output wire [1:0]  trace_residual_t1,
	output wire signed [7:0] trace_residual_dc,
	output wire [7:0]  trace_residual_csum,
	output wire signed [15:0] trace_residual_coeff [0:15],
	output wire signed [28:0] trace_idct_dequant [0:15],
	output wire signed [28:0] trace_idct_residual [0:15],
	output wire [7:0]  trace_recon_px [0:15],
	output wire        fs_wr_en,
	output wire [15:0] fs_wr_pixel,
	output wire        fs_wr_reset,
	output wire        fs_swap,

	output wire        native_inter_valid,
	output wire [15:0] native_inter_frame_idx,
	output wire [7:0]  native_inter_mb_x,
	output wire [7:0]  native_inter_mb_y,
	output wire        native_inter_p_skip,
	output wire [2:0]  native_inter_part_mode,
	output wire [7:0]  native_inter_pred_y [0:255],
	output wire [7:0]  native_inter_pred_u [0:63],
	output wire [7:0]  native_inter_pred_v [0:63],

	// Native I420 DPB write tap — per-sample stream from reconstruction path
	output wire        native_i420_wr_en,
	output wire [31:0] native_i420_wr_offset,
	output wire [7:0]  native_i420_wr_data,
	output wire [15:0] native_i420_wr_frame,

	// Product decode_core presentation stream (native I420 plane samples).
	// This is the only path that paints under DDR_FRAME_STORE; compare against
	// FFmpeg yuv420p goldens for full-frame product correctness.
	output wire        product_px_wr_en,
	output wire [1:0]  product_px_plane,
	output wire [15:0] product_px_x,
	output wire [15:0] product_px_y,
	output wire [7:0]  product_px_data,
	output wire        product_frame_done,
	output wire [15:0] product_frame_mb_count,
	output wire        product_core_busy,
	output wire [7:0]  product_decode_state,
	output wire [15:0] product_current_mb_addr,
	output wire        product_core_error,
	output wire        product_feed_frame_done,
	output wire        product_feed_busy,
	output wire        product_slice_desync,
	output wire [3:0]  product_slice_desync_cause,
	output wire [15:0] product_slice_desync_mb,
	output wire        product_rbsp_overflow,
	output wire [15:0] product_rbsp_length,
	output wire        product_rbsp_complete,
	output wire        product_feed_slice_go,
	output wire        product_feed_started,
	output wire        product_feed_i_ready,
	output wire [5:0]  product_feed_st,
	output wire [15:0] product_feed_mb_addr,
	output wire        product_slice_valid,
	output wire        product_slice_is_i,
	output wire [7:0]  product_sps_mb_w,
	output wire [7:0]  product_sps_mb_h,

	// DPB reference pre-fill — testbench injects real IDR reference data
	input  wire        dpb_prefill_en,
	input  wire [31:0] dpb_prefill_addr,
	input  wire [7:0]  dpb_prefill_data
);
	wire [7:0] sps_level;
	wire [5:0] slice_qp;
	wire [4:0] residual_tc;
	wire [1:0] residual_t1;
	wire residual_ok;
	wire signed [7:0] residual_dc;
	wire [7:0] residual_csum;
	wire signed [15:0] residual_coeff [0:15];
	wire residual_place_pulse;
	wire recon_dbg_valid;
	wire [15:0] fs_wr_pixel_dut;
	wire ddr_bus_want, ddr_rd, ddr_we;
	wire [7:0] ddr_burstcnt, ddr_be;
	wire [28:0] ddr_addr;
	wire [63:0] ddr_din;
	wire stream_ddr_active;
	wire [31:0] stream_ddr_bytes_out, stream_ddr_host_write, stream_ddr_fpga_read;
	wire [15:0] stream_ddr_underruns, stream_ddr_overruns;
	wire [1:0] disable_deblocking_filter_idc;
	wire signed [4:0] slice_alpha_c0_offset_div2;
	wire signed [4:0] slice_beta_offset_div2;
	wire signed [4:0] slice_alpha_c0_offset;
	wire signed [4:0] slice_beta_offset;
	wire first_mb_p_skip_w;
	wire [7:0] p_skip_run_w;
	wire [2:0] first_mb_part_mode_w;
	wire [2:0] first_mb_part_count_w;
	wire first_mb_uses_sub_mb_w;
	wire first_mb_intra_w;

	// Minimal DDR3 model for DPB write/read (word-addressed 64-bit).
	// h264_dpb_ddr uses DDR_BASE=0x3040_0000 → word base 0x608_0000.
	// Contended grants (busy_hold) so product DPB is not scored on a quiet bus.
	localparam int DDR_WORDS = (FRAME_W * FRAME_H * 3 / 2 * 2) / 8 + 4096;
	localparam [28:0] DDR_BASE_W = 29'h06080000;
	reg [63:0] ddr_mem [0:DDR_WORDS-1];
	reg        ddr_busy_r;
	reg        ddr_dout_ready_r;
	reg [63:0] ddr_dout_r;
	reg [7:0]  rd_left;
	reg [28:0] rd_addr_r;
	reg [2:0]  busy_hold;
	wire [28:0] wr_idx = ddr_addr - DDR_BASE_W;
	wire [28:0] rd_idx = rd_addr_r - DDR_BASE_W;
	integer    di;
	initial begin
		for (di = 0; di < DDR_WORDS; di = di + 1) ddr_mem[di] = 64'd0;
		ddr_busy_r = 1'b0;
		ddr_dout_ready_r = 1'b0;
		ddr_dout_r = 64'd0;
		rd_left = 8'd0;
		rd_addr_r = 29'd0;
		busy_hold = 3'd0;
	end
	always @(posedge clk) begin
		if (reset) begin
			ddr_busy_r <= 1'b0;
			ddr_dout_ready_r <= 1'b0;
			ddr_dout_r <= 64'd0;
			rd_left <= 8'd0;
			rd_addr_r <= 29'd0;
			busy_hold <= 3'd0;
		end else begin
			ddr_dout_ready_r <= 1'b0;
			if (busy_hold != 3'd0) begin
				ddr_busy_r <= 1'b1;
				busy_hold <= busy_hold - 3'd1;
			end else if (rd_left != 8'd0) begin
				ddr_busy_r <= 1'b0;
				ddr_dout_ready_r <= 1'b1;
				ddr_dout_r <= (rd_idx < DDR_WORDS[28:0]) ? ddr_mem[rd_idx] : 64'd0;
				rd_addr_r <= rd_addr_r + 29'd1;
				rd_left <= rd_left - 8'd1;
				busy_hold <= 3'd1;
			end else if (ddr_we && !ddr_busy_r) begin
				if (wr_idx < DDR_WORDS[28:0]) begin
					if (ddr_be[0]) ddr_mem[wr_idx][7:0]   <= ddr_din[7:0];
					if (ddr_be[1]) ddr_mem[wr_idx][15:8]  <= ddr_din[15:8];
					if (ddr_be[2]) ddr_mem[wr_idx][23:16] <= ddr_din[23:16];
					if (ddr_be[3]) ddr_mem[wr_idx][31:24] <= ddr_din[31:24];
					if (ddr_be[4]) ddr_mem[wr_idx][39:32] <= ddr_din[39:32];
					if (ddr_be[5]) ddr_mem[wr_idx][47:40] <= ddr_din[47:40];
					if (ddr_be[6]) ddr_mem[wr_idx][55:48] <= ddr_din[55:48];
					if (ddr_be[7]) ddr_mem[wr_idx][63:56] <= ddr_din[63:56];
				end
				ddr_busy_r <= 1'b1;
				busy_hold <= 3'd1;
			end else if (ddr_rd && !ddr_busy_r) begin
				rd_addr_r <= ddr_addr;
				rd_left <= (ddr_burstcnt == 8'd0) ? 8'd1 : ddr_burstcnt;
				ddr_busy_r <= 1'b1;
				busy_hold <= 3'd1;
			end else begin
				ddr_busy_r <= 1'b0;
			end
		end
	end

	stream_path #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H)
	) dut (
		.clk(clk),
		.reset(reset),
		.ioctl_download(ioctl_download),
		.ioctl_wr(ioctl_wr),
		.ioctl_dout(ioctl_dout),
		.enable(1'b1),
		.flush(flush),
		.ddr_stream_enable(1'b0),
		.ddr_bus_want(ddr_bus_want),
		.ddr_busy(ddr_busy_r),
		.ddr_burstcnt(ddr_burstcnt),
		.ddr_addr(ddr_addr),
		.ddr_dout(ddr_dout_r),
		.ddr_dout_ready(ddr_dout_ready_r),
		.ddr_rd(ddr_rd),
		.ddr_din(ddr_din),
		.ddr_be(ddr_be),
		.ddr_we(ddr_we),
		.has_stream(has_stream),
		.nalu_count(nalu_count),
		.last_nal_type(last_nal_type),
		.bytes_in(bytes_in),
		.bytes_seen(bytes_seen),
		.fifo_level(fifo_level),
		.stream_ddr_active(stream_ddr_active),
		.stream_ddr_bytes_out(stream_ddr_bytes_out),
		.stream_ddr_underruns(stream_ddr_underruns),
		.stream_ddr_overruns(stream_ddr_overruns),
		.stream_ddr_host_write(stream_ddr_host_write),
		.stream_ddr_fpga_read(stream_ddr_fpga_read),
		.has_idr(has_idr),
		.idr_count(idr_count),
		.sps_count(sps_count),
		.pps_count(pps_count),
		.slice_count(slice_count),
		.stub_frames(stub_frames),
		.stub_busy(stub_busy),
		.sps_valid(sps_valid),
		.sps_profile(sps_profile),
		.sps_level(sps_level),
		.sps_width(sps_width),
		.sps_height(sps_height),
		.sps_mb_w(sps_mb_w),
		.sps_mb_h(sps_mb_h),
		.pps_valid(pps_valid),
		.slice_valid(slice_valid),
		.slice_type(slice_type),
		.slice_is_i(slice_is_i),
		.first_mb_type(first_mb_type),
		.has_mb_type(has_mb_type),
		.first_mb_p_skip(first_mb_p_skip_w),
		.p_skip_run(p_skip_run_w),
		.first_mb_part_mode(first_mb_part_mode_w),
		.first_mb_part_count(first_mb_part_count_w),
		.first_mb_uses_sub_mb(first_mb_uses_sub_mb_w),
		.first_mb_intra(first_mb_intra_w),
		.slice_qp(slice_qp),
		.disable_deblocking_filter_idc(disable_deblocking_filter_idc),
		.slice_alpha_c0_offset_div2(slice_alpha_c0_offset_div2),
		.slice_beta_offset_div2(slice_beta_offset_div2),
		.slice_alpha_c0_offset(slice_alpha_c0_offset),
		.slice_beta_offset(slice_beta_offset),
		.residual_tc(residual_tc),
		.residual_t1(residual_t1),
		.residual_ok(residual_ok),
		.residual_dc(residual_dc),
		.residual_csum(residual_csum),
		.residual_coeff(residual_coeff),
		.residual_place_pulse(residual_place_pulse),
		.recon_sig(recon_sig),
		.recon_dbg(recon_dbg),
		.recon_dbg_valid(recon_dbg_valid),
		.recon_valid(recon_valid),
		.fs_wr_en(fs_wr_en),
		.fs_wr_pixel(fs_wr_pixel_dut),
		.fs_wr_reset(fs_wr_reset),
		.fs_swap(fs_swap),
		.dec_px_wr_en(product_px_wr_en),
		.dec_px_plane(product_px_plane),
		.dec_px_x(product_px_x),
		.dec_px_y(product_px_y),
		.dec_px_data(product_px_data),
		.slice_desync(product_slice_desync),
		.slice_desync_early(),
		.slice_desync_long(),
		.slice_desync_cause(product_slice_desync_cause),
		.slice_desync_mb(product_slice_desync_mb)
	);

	// Hierarchical product-core observability (not all promoted to stream_path ports).
	assign product_frame_done = dut.core_frame_done;
	assign product_frame_mb_count = dut.core_frame_mb_count;
	assign product_core_busy = dut.core_busy;
	assign product_decode_state = dut.core_decode_state;
	assign product_current_mb_addr = dut.core_current_mb_addr;
	assign product_core_error = dut.core_error;
	assign product_feed_frame_done = dut.feed_frame_done;
	assign product_feed_busy = dut.feed_busy;
	assign product_rbsp_overflow = dut.core_rbsp_overflow;
	assign product_rbsp_length = dut.core_rbsp_length;
	assign product_rbsp_complete = dut.core_rbsp_complete;
	assign product_feed_slice_go = dut.feed_slice_go;
	assign product_feed_started = dut.feed_started;
	assign product_feed_i_ready = dut.feed_i_ready;
	assign product_feed_st = dut.feed_dbg_st;
	assign product_feed_mb_addr = dut.feed_dbg_mb_addr;
	assign product_slice_valid = slice_valid;
	assign product_slice_is_i = slice_is_i;
	assign product_sps_mb_w = sps_mb_w;
	assign product_sps_mb_h = sps_mb_h;

	assign fs_wr_pixel = FAULT_PIXEL_XOR ? (fs_wr_pixel_dut ^ 16'hffff) : fs_wr_pixel_dut;
	// Stage-A product path: decode_stub is ABSENT. Product scoring uses
	// dec_px_* / product_* hierarchy above. Native/stub taps are tied off so
	// this TB still elaborates; do not resurrect gen_diagnostic_present.stub.
	assign trace_slice_qp = 6'd0;
	assign trace_residual_tc = 5'd0;
	assign trace_residual_t1 = dut.sl_place_t1;
	assign trace_residual_dc = 16'sd0;
	assign trace_residual_csum = residual_csum;
	assign native_inter_valid = 1'b0;
	assign native_inter_frame_idx = 16'd0;
	assign native_inter_mb_x = 8'd0;
	assign native_inter_mb_y = 8'd0;
	assign native_inter_p_skip = 1'b0;
	assign native_inter_part_mode = 3'd0;
	genvar trace_i;
	generate
		for (trace_i = 0; trace_i < 16; trace_i = trace_i + 1) begin : gen_trace
			assign trace_residual_coeff[trace_i] = 9'sd0;
			assign trace_idct_dequant[trace_i] = 29'sd0;
			assign trace_idct_residual[trace_i] = 29'sd0;
			assign trace_recon_px[trace_i] = 8'd0;
		end
	endgenerate
	genvar native_y_i;
	generate
		for (native_y_i = 0; native_y_i < 256; native_y_i = native_y_i + 1) begin : gen_native_y
			assign native_inter_pred_y[native_y_i] = 8'd0;
		end
	endgenerate
	genvar native_c_i;
	generate
		for (native_c_i = 0; native_c_i < 64; native_c_i = native_c_i + 1) begin : gen_native_c
			assign native_inter_pred_u[native_c_i] = 8'd0;
			assign native_inter_pred_v[native_c_i] = 8'd0;
		end
	endgenerate

	// Native I420 DPB write tap unused on product path (dec_px is the source).
	assign native_i420_wr_en     = 1'b0;
	assign native_i420_wr_offset = 32'd0;
	assign native_i420_wr_data   = 8'd0;
	assign native_i420_wr_frame  = 16'd0;

	// Prefill no-op: product DPB is inside product_decode_core (no stub SRAM).
	always @(posedge clk) begin
		if (dpb_prefill_en) begin
			// intentionally empty
		end
	end
endmodule

`default_nettype wire
