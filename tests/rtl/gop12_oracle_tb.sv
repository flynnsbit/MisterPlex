// Read-only observation of native DPB writes; no reference pixels enter the DUT.
module gop12_oracle_tb (
    input wire clk, reset, ioctl_download, ioctl_wr,
    input wire [7:0] ioctl_dout,
    output wire [15:0] frames_out,
    output wire fs_swap,
    output wire native_we,
    output wire native_accept, lifetime_observed, reference_promoted, reference_error,
    output wire [7:0] decoder_error,
    output wire rgb_valid,
    output wire color_metadata_observed, color_full_range,
    output wire [7:0] color_matrix,
    output wire frontend_mode_observed, legacy_diagnostic_mode,
    output wire [15:0] reference_width, reference_height,
    output wire [31:0] reference_base,
    output wire [31:0] native_addr,
    output wire [7:0] native_data,
    output wire [15:0] frame_num, mb_index,
    output wire [4:0] phase,
    output wire [16:0] bit_pos,
    output wire [15:0] width, height,
    output wire [15:0] fifo_level
`ifdef GOP12_REAL_DDR
    ,input wire DDRAM_BUSY, DDRAM_DOUT_READY,
    input wire [63:0] DDRAM_DOUT,
    output wire [28:0] DDRAM_ADDR,
    output wire DDRAM_RD, DDRAM_WE,
    output wire [63:0] DDRAM_DIN,
    output wire [7:0] DDRAM_BE, DDRAM_BURSTCNT,
    output wire decoder_idle,
    output wire current_au_valid,
    output wire [63:0] current_au_session_id, current_au_pts, current_au_duration,
    output wire [31:0] current_au_seq, current_au_timebase_num, current_au_timebase_den, current_au_flags,
    output wire [15:0] coded_width, coded_height, visible_width, visible_height,
    output wire [15:0] crop_left, crop_right, crop_top, crop_bottom, sar_width, sar_height,
    output wire [15:0] native_y_stride, native_uv_stride,
    output wire [31:0] native_u_offset, native_v_offset, native_bank_bytes,
    output wire [19:0] full_bit_pos,
    output wire [15:0] rgb_pixel
`endif
);
    wire fs_command_valid;
`ifdef GOP12_REAL_DDR
    stream_path #(.ENABLE_AU_PROTOCOL(1'b1), .ENABLE_PICTURE_PUBLISH(1'b0)) dut (
`else
    stream_path dut (
`endif
        .clk(clk), .reset(reset),
        .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
        .ioctl_dout(ioctl_dout), .enable(1'b1), .flush(1'b0),
`ifdef GOP12_DDR_PORTS
`ifdef GOP12_REAL_DDR
        .ddr_stream_enable(1'b1), .ddr_busy(DDRAM_BUSY),
        .ddr_dout(DDRAM_DOUT), .ddr_dout_ready(DDRAM_DOUT_READY),
        .ddr_addr(DDRAM_ADDR), .ddr_rd(DDRAM_RD), .ddr_we(DDRAM_WE),
        .ddr_din(DDRAM_DIN), .ddr_be(DDRAM_BE), .ddr_burstcnt(DDRAM_BURSTCNT),
        .fs_writes_idle(1'b1), .decoder_idle(decoder_idle),
        .picture_ready(1'b0), .pub_mem_rd(1'b0), .pub_mem_addr(18'd0),
        .current_au_valid(current_au_valid), .current_au_session_id(current_au_session_id),
        .current_au_seq(current_au_seq), .current_au_pts(current_au_pts),
        .current_au_duration(current_au_duration), .current_au_timebase_num(current_au_timebase_num),
        .current_au_timebase_den(current_au_timebase_den), .current_au_flags(current_au_flags),
`else
        .ddr_stream_enable(1'b0), .ddr_busy(1'b0),
        .ddr_dout(64'd0), .ddr_dout_ready(1'b0),
`endif
`endif
        .fs_wr_ready(1'b1), .fs_present_sel(1'b1),
        .fs_wr_en(fs_command_valid),
        .frames_out(frames_out), .fs_swap(fs_swap),
        .sps_width(width), .sps_height(height), .fifo_level(fifo_level)
    );
`ifdef GOP12_REAL_DDR
    assign rgb_valid = dut.mb_ctrl.wr_en && dut.mb_ctrl.wr_ready && dut.mb_ctrl.present_sel &&
                       !dut.mb_ctrl.wr_reset_ptr && !dut.mb_ctrl.swap_req;
    assign rgb_pixel = dut.mb_ctrl.wr_pixel;
`else
    assign rgb_valid = fs_command_valid && !dut.fs_wr_reset && !dut.fs_swap;
`endif
    assign native_we = dut.dpb_mem_we;
`ifdef GOP12_DPB_LIFETIME
    assign native_accept = dut.dpb_mem_we && dut.mb_ctrl.u_dpb.mem_wready;
    assign lifetime_observed = 1'b1;
    assign reference_promoted = dut.mb_ctrl.dpb_frame_promoted;
    assign reference_error = dut.mb_ctrl.dpb_frame_error;
    assign decoder_error = dut.mb_ctrl.decode_error;
    assign reference_width = dut.mb_ctrl.u_dpb.reference_width;
    assign reference_height = dut.mb_ctrl.u_dpb.reference_height;
    assign reference_base = dut.mb_ctrl.u_dpb.reference_base;
`else
    // The pinned donor backend is an always-accept synchronous BRAM.
    assign native_accept = dut.dpb_mem_we;
    assign lifetime_observed = 1'b0;
    assign reference_promoted = 1'b0;
    assign reference_error = 1'b0;
    assign decoder_error = 8'd0;
    assign reference_width = 16'd0;
    assign reference_height = 16'd0;
    assign reference_base = 32'd0;
`endif
`ifdef GOP12_COLOR_METADATA
    assign color_metadata_observed = 1'b1;
    assign color_full_range = dut.mb_ctrl.lat_full_range;
    assign color_matrix = dut.mb_ctrl.lat_matrix;
`else
    assign color_metadata_observed = 1'b0;
    assign color_full_range = 1'b0;
    assign color_matrix = 8'd0;
`endif
`ifdef GOP12_OBSERVE_FRONTEND_MODE
    assign frontend_mode_observed = 1'b1;
    assign legacy_diagnostic_mode = dut.slp.LEGACY_DIAGNOSTIC;
`else
    assign frontend_mode_observed = 1'b0;
    assign legacy_diagnostic_mode = 1'b0;
`endif
    assign native_addr = dut.dpb_mem_waddr;
    assign native_data = dut.dpb_mem_wdata;
    assign frame_num = dut.sl_fn;
    assign mb_index = dut.mb_index;
    assign phase = dut.mb_ctrl.phase;
    assign bit_pos = dut.mb_ctrl.br_bit_pos[16:0];
`ifdef GOP12_REAL_DDR
    assign full_bit_pos = 20'(dut.mb_ctrl.br_bit_pos);
    assign coded_width = dut.mb_ctrl.present_coded_width;
    assign coded_height = dut.mb_ctrl.present_coded_height;
    assign visible_width = dut.mb_ctrl.present_width;
    assign visible_height = dut.mb_ctrl.present_height;
    assign crop_left = dut.mb_ctrl.present_crop_left;
    assign crop_right = dut.mb_ctrl.present_crop_right;
    assign crop_top = dut.mb_ctrl.present_crop_top;
    assign crop_bottom = dut.mb_ctrl.present_crop_bottom;
    assign sar_width = dut.mb_ctrl.present_sar_width;
    assign sar_height = dut.mb_ctrl.present_sar_height;
    assign native_y_stride = dut.mb_ctrl.native_luma_stride;
    assign native_uv_stride = dut.mb_ctrl.native_chroma_stride;
    assign native_u_offset = dut.mb_ctrl.u_dpb.FRAME_W * dut.mb_ctrl.u_dpb.FRAME_H;
    assign native_v_offset = dut.mb_ctrl.u_dpb.FRAME_W * dut.mb_ctrl.u_dpb.FRAME_H * 5 / 4;
    assign native_bank_bytes = dut.mb_ctrl.u_dpb.BANK1_BASE - dut.mb_ctrl.u_dpb.BANK0_BASE;
`endif
endmodule
