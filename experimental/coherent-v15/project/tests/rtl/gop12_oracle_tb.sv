// Adapted from the existing gop12 oracle. Only Annex-B bytes enter the DUT.
module gop12_oracle_tb #(
    parameter bit ENABLE_FRAME_DEBLOCK = 1'b1,
    parameter bit STATIC_IDR_ONLY = 1'b0
) (
    input wire clk, reset, ioctl_download, ioctl_wr,
    input wire [7:0] ioctl_dout,
    output wire [15:0] frames_out,
    output wire fs_swap, native_we, native_accept,
    output wire lifetime_observed, reference_promoted, reference_error,
    output wire [7:0] decoder_error,
    output wire rgb_valid, color_metadata_observed, color_full_range,
    output wire [7:0] color_matrix,
    output wire frontend_mode_observed, legacy_diagnostic_mode,
    output wire [15:0] reference_width, reference_height,
    output wire [31:0] reference_base, native_addr,
    output wire [7:0] native_data,
    output wire [15:0] frame_num, mb_index,
    output wire [4:0] phase,
    output wire [16:0] bit_pos,
    output wire [15:0] width, height, coded_width, coded_height, fifo_level,
    output wire decoder_busy, reference_fetch_busy, reference_ready, product_recon_ok,
    output wire native_picture_valid,
    output wire filter_start, filter_busy, filter_done, filter_write, filter_read,
    output wire prediction_read,
    output wire [31:0] native_read_addr, current_base,
    output wire mb_commit,
    output wire [2:0] mb_mode,
    output wire signed [15:0] mb_mvx, mb_mvy,
    output wire [15:0] mb_nonzero,
    output wire filter_edge,
    output wire [2:0] filter_bs,
    output wire [1:0] filter_plane
);
    stream_path #(
        .LEGACY_SLICE_DIAGNOSTIC(1'b0),
        .IDR_ONLY_PROFILE(STATIC_IDR_ONLY),
        .ENABLE_FRAME_DEBLOCK(ENABLE_FRAME_DEBLOCK),
        .VIDEO_FEATURES(32'd0)
    ) dut (
        .clk(clk), .reset(reset),
        .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
        .ioctl_dout(ioctl_dout), .enable(1'b1), .flush(1'b0),
        .ddr_stream_enable(1'b0), .ddr_busy(1'b0),
        .ddr_dout(64'd0), .ddr_dout_ready(1'b0),
        .fs_wr_ready(1'b1), .fs_present_sel(1'b1), .fs_writes_idle(1'b1),
        .picture_ready(1'b0), .pub_mem_rd(1'b0), .pub_mem_addr(18'd0),
        .codec_error_committed(1'b0),
        .frames_out(frames_out), .sps_width(width), .sps_height(height),
        .fifo_level(fifo_level), .product_recon_ok(product_recon_ok)
    );
    assign fs_swap = dut.mb_ctrl.swap_req;
    assign rgb_valid = dut.mb_ctrl.wr_en && dut.mb_ctrl.wr_ready &&
                       dut.mb_ctrl.present_sel && !dut.mb_ctrl.wr_reset_ptr &&
                       !dut.mb_ctrl.swap_req;
    assign native_we = dut.dpb_mem_we;
    assign native_accept = dut.dpb_w_hit;
    assign lifetime_observed = 1'b1;
    assign reference_promoted = dut.mb_ctrl.dpb_frame_promoted;
    assign reference_error = dut.mb_ctrl.dpb_frame_error;
    assign decoder_error = dut.mb_ctrl.decode_error;
    assign reference_width = dut.mb_ctrl.u_dpb.reference_width;
    assign reference_height = dut.mb_ctrl.u_dpb.reference_height;
    assign reference_base = dut.mb_ctrl.u_dpb.reference_base;
    assign reference_ready = dut.mb_ctrl.dpb_ref_ready;
    assign native_picture_valid = dut.mb_ctrl.native_picture_valid;
    assign current_base = dut.mb_ctrl.dpb_cur_base;
    assign color_metadata_observed = 1'b1;
    assign color_full_range = dut.mb_ctrl.lat_full_range;
    assign color_matrix = dut.mb_ctrl.lat_matrix;
    assign frontend_mode_observed = 1'b1;
    assign legacy_diagnostic_mode = dut.slp.LEGACY_DIAGNOSTIC;
    assign native_addr = dut.dpb_mem_waddr;
    assign native_data = dut.dpb_mem_wdata;
    assign frame_num = dut.sl_fn;
    assign mb_index = dut.mb_index;
    assign phase = dut.mb_ctrl.phase;
    assign bit_pos = dut.mb_ctrl.br_bit_pos;
    assign coded_width = dut.mb_ctrl.present_coded_width;
    assign coded_height = dut.mb_ctrl.present_coded_height;
    assign decoder_busy = dut.mb_ctrl.busy;
    assign reference_fetch_busy = dut.mb_ctrl.dpb_fetch_busy;
    assign filter_start = dut.mb_ctrl.frame_filter_start;
    assign filter_busy = dut.mb_ctrl.frame_filter_busy;
    assign filter_done = dut.mb_ctrl.frame_filter_done;
    assign filter_write = dut.mb_ctrl.filter_owns_memory && dut.dpb_mem_we;
    assign filter_read = dut.mb_ctrl.filter_owns_memory && dut.dpb_mem_rd;
    assign prediction_read = !dut.mb_ctrl.filter_owns_memory &&
                             !dut.mb_ctrl.paint_on && dut.dpb_mem_rd;
    assign native_read_addr = dut.dpb_mem_raddr;
    assign mb_commit = dut.mb_ctrl.store_v && dut.mb_ctrl.dpb_write_ready &&
                       dut.mb_ctrl.final_mb_sample;
    assign mb_mode = dut.mb_ctrl.is_intra_mb ?
                     (dut.mb_ctrl.is_i16 ? 3'd3 : 3'd2) :
                     dut.mb_ctrl.is_pskip ? 3'd1 : 3'd0;
    assign mb_mvx = dut.mb_ctrl.is_intra_mb ? 16'sd0 : dut.mb_ctrl.mv_kick_x;
    assign mb_mvy = dut.mb_ctrl.is_intra_mb ? 16'sd0 : dut.mb_ctrl.mv_kick_y;
    for (genvar b=0; b<16; b=b+1) begin: g_nonzero
        assign mb_nonzero[b] = dut.mb_ctrl.tc_cur[b] != 0;
    end
    generate if (ENABLE_FRAME_DEBLOCK) begin: g_filter_observe
        assign filter_edge = dut.mb_ctrl.g_frame_deblock.u_filter.state == 5;
        assign filter_bs = dut.mb_ctrl.g_frame_deblock.u_filter.bs;
        assign filter_plane = dut.mb_ctrl.g_frame_deblock.u_filter.plane;
    end else begin: g_filter_absent
        assign filter_edge=1'b0, filter_bs=3'd0, filter_plane=2'd0;
    end endgenerate
endmodule
