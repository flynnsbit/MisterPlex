// Testbench-only stream_path wrapper for multi-NAL ioctl injection.
// NOT part of the Quartus project. It preserves the product ioctl_download /
// ioctl_wr / ioctl_dout route into stream_path.sv.
`default_nettype none

module h264_multinal_stream_path_tb #(
    parameter bit FAULT_RECON_SIG_ZERO = 1'b0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [7:0]  ioctl_dout,
    input  wire        enable,
    input  wire        flush,
    output wire [15:0] nalu_count,
    output wire [7:0]  last_nal_type,
    output wire [31:0] bytes_in,
    output wire [31:0] bytes_seen,
    output wire [7:0]  idr_count,
    output wire [7:0]  sps_count,
    output wire [7:0]  pps_count,
    output wire [7:0]  slice_count,
    output wire [15:0] stub_frames,
    output wire        stub_busy,
    output wire        sps_valid,
    output wire [15:0] sps_width,
    output wire [15:0] sps_height,
    output wire        pps_valid,
    output wire        slice_valid,
    output wire [7:0]  slice_type,
    output wire        slice_is_i,
    output wire [7:0]  first_mb_type,
    output wire        has_mb_type,
    output wire        first_mb_p_skip,
    output wire [15:0] p_skip_run,
    output wire [2:0]  first_mb_part_mode,
    output wire [2:0]  first_mb_part_count,
    output wire        first_mb_uses_sub_mb,
    output wire        first_mb_intra,
    output wire [7:0]  residual_csum,
    output wire        residual_place_pulse,
    output wire [5:0]  slice_parser_state,
    output wire [7:0]  recon_sig,
    output wire [7:0]  recon_dbg,
    output wire        recon_valid,
    output wire        slice_desync,
    output wire        slice_desync_early,
    output wire        slice_desync_long,
    output wire [3:0]  slice_desync_cause,
    output wire [15:0] slice_desync_mb,
    output wire [15:0] slice_frame_num,
    output wire        slice_is_idr_hdr
);
    wire has_stream;
    wire [15:0] fifo_level;
    wire has_idr;
    wire [7:0] sps_profile, sps_level, sps_mb_w, sps_mb_h;
    wire [5:0] slice_qp;
    wire [1:0] disable_deblocking_filter_idc;
    wire signed [4:0] slice_alpha_c0_offset_div2;
    wire signed [4:0] slice_beta_offset_div2;
    wire signed [4:0] slice_alpha_c0_offset;
    wire signed [4:0] slice_beta_offset;
    wire [4:0] residual_tc;
    wire [1:0] residual_t1;
    wire residual_ok;
    wire signed [7:0] residual_dc;
    wire signed [15:0] residual_coeff [0:15];
    wire [7:0] recon_sig_dut;
    wire recon_dbg_valid;
    wire fs_wr_en, fs_wr_reset, fs_swap;
    wire [15:0] fs_wr_pixel;
    wire ddr_bus_want, ddr_rd, ddr_we;
    wire [7:0] ddr_burstcnt, ddr_be;
    wire [28:0] ddr_addr;
    wire [63:0] ddr_din;
    wire stream_ddr_active;
    wire [31:0] stream_ddr_bytes_out, stream_ddr_host_write, stream_ddr_fpga_read;
    wire [15:0] stream_ddr_underruns, stream_ddr_overruns;

    // Match product CORE_FRAME geometry to fixture SPS (320x240). 16x16 forced
    // mb/core mismatch and false PARSE desync on real 320x240 Annex-B.
    stream_path #(.FRAME_W(320), .FRAME_H(240)) dut (
        .clk(clk), .reset(reset),
        .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_dout(ioctl_dout),
        .enable(enable), .flush(flush),
        .ddr_stream_enable(1'b0), .ddr_bus_want(ddr_bus_want), .ddr_busy(1'b0),
        .ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr), .ddr_dout(64'd0),
        .ddr_dout_ready(1'b0), .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be),
        .ddr_we(ddr_we),
        .has_stream(has_stream), .nalu_count(nalu_count), .last_nal_type(last_nal_type),
        .bytes_in(bytes_in), .bytes_seen(bytes_seen), .fifo_level(fifo_level),
        .stream_ddr_active(stream_ddr_active), .stream_ddr_bytes_out(stream_ddr_bytes_out),
        .stream_ddr_underruns(stream_ddr_underruns), .stream_ddr_overruns(stream_ddr_overruns),
        .stream_ddr_host_write(stream_ddr_host_write), .stream_ddr_fpga_read(stream_ddr_fpga_read),
        .has_idr(has_idr), .idr_count(idr_count), .sps_count(sps_count), .pps_count(pps_count),
        .slice_count(slice_count), .stub_frames(stub_frames), .stub_busy(stub_busy),
        .sps_valid(sps_valid), .sps_profile(sps_profile), .sps_level(sps_level),
        .sps_width(sps_width), .sps_height(sps_height), .sps_mb_w(sps_mb_w), .sps_mb_h(sps_mb_h),
        .pps_valid(pps_valid), .slice_valid(slice_valid), .slice_type(slice_type),
        .slice_is_i(slice_is_i), .first_mb_type(first_mb_type), .has_mb_type(has_mb_type),
        .first_mb_p_skip(first_mb_p_skip), .p_skip_run(p_skip_run),
        .first_mb_part_mode(first_mb_part_mode), .first_mb_part_count(first_mb_part_count),
        .first_mb_uses_sub_mb(first_mb_uses_sub_mb), .first_mb_intra(first_mb_intra),
        .slice_qp(slice_qp), .disable_deblocking_filter_idc(disable_deblocking_filter_idc),
        .slice_alpha_c0_offset_div2(slice_alpha_c0_offset_div2),
        .slice_beta_offset_div2(slice_beta_offset_div2),
        .slice_alpha_c0_offset(slice_alpha_c0_offset),
        .slice_beta_offset(slice_beta_offset),
        .residual_tc(residual_tc), .residual_t1(residual_t1),
        .residual_ok(residual_ok), .residual_dc(residual_dc), .residual_csum(residual_csum),
        .residual_coeff(residual_coeff), .residual_place_pulse(residual_place_pulse),
        .recon_sig(recon_sig_dut), .recon_dbg(recon_dbg), .recon_dbg_valid(recon_dbg_valid),
        .recon_valid(recon_valid), .fs_wr_en(fs_wr_en), .fs_wr_pixel(fs_wr_pixel),
        .fs_wr_reset(fs_wr_reset), .fs_swap(fs_swap),
        .slice_desync(slice_desync), .slice_desync_early(slice_desync_early),
        .slice_desync_long(slice_desync_long), .slice_desync_cause(slice_desync_cause),
        .slice_desync_mb(slice_desync_mb)
    );
    assign slice_frame_num = dut.sl_fn;
    assign slice_is_idr_hdr = dut.sl_is_idr;

    assign recon_sig = FAULT_RECON_SIG_ZERO ? 8'h00 : recon_sig_dut;
    assign slice_parser_state = dut.slp.st;
endmodule

`default_nettype wire
