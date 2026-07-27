// Testbench-only top for full-frame stream_path presentation comparison.
// The product stream_path RTL is instantiated unchanged; FAULT_PIXEL_XOR only
// perturbs the testbench-visible output so the comparator has a behavior red path.
`default_nettype none

module stream_path_full_frame_tb #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter bit FAULT_PIXEL_XOR = 1'b0
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
	output wire        fs_wr_en,
	output wire [15:0] fs_wr_pixel,
	output wire        fs_wr_reset,
	output wire        fs_swap
);
	wire [7:0] sps_level;
	wire [5:0] slice_qp;
	wire [4:0] residual_tc;
	wire [1:0] residual_t1;
	wire residual_ok;
	wire signed [7:0] residual_dc;
	wire [7:0] residual_csum;
	wire signed [8:0] residual_coeff [0:15];
	wire residual_place_pulse;
	wire recon_dbg_valid;
	wire [15:0] fs_wr_pixel_dut;

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
		.has_stream(has_stream),
		.nalu_count(nalu_count),
		.last_nal_type(last_nal_type),
		.bytes_in(bytes_in),
		.bytes_seen(bytes_seen),
		.fifo_level(fifo_level),
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
		.slice_qp(slice_qp),
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
		.fs_swap(fs_swap)
	);

	assign fs_wr_pixel = FAULT_PIXEL_XOR ? (fs_wr_pixel_dut ^ 16'hffff) : fs_wr_pixel_dut;
endmodule

`default_nettype wire
