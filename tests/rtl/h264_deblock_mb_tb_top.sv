// Test bench top for the product macroblock deblocking filter.
// Exposes h264_deblock_mb_filter with flat sample ports so the C++ harness can
// drive a real macroblock neighbourhood and read the filtered neighbourhood
// back.  Product RTL lives in fpga/Plex_MiSTer/rtl/h264_deblock.sv.
`default_nettype none

module h264_deblock_mb_tb_top (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    output wire        busy,
    output wire        done,

    input  wire [1:0]        disable_deblocking_filter_idc,
    input  wire signed [4:0] slice_alpha_c0_offset,
    input  wire signed [4:0] slice_beta_offset,
    input  wire signed [4:0] chroma_qp_index_offset,
    input  wire              left_mb_avail,
    input  wire              top_mb_avail,
    input  wire              left_mb_other_slice,
    input  wire              top_mb_other_slice,

    input  wire         cur_intra,
    input  wire [5:0]   cur_qp_y,
    input  wire [15:0]  cur_nz,
    input  wire [191:0] cur_mvx,
    input  wire [191:0] cur_mvy,
    input  wire [31:0]  cur_ref,

    input  wire         left_intra,
    input  wire [5:0]   left_qp_y,
    input  wire [15:0]  left_nz,
    input  wire [191:0] left_mvx,
    input  wire [191:0] left_mvy,
    input  wire [31:0]  left_ref,

    input  wire         top_intra,
    input  wire [5:0]   top_qp_y,
    input  wire [15:0]  top_nz,
    input  wire [191:0] top_mvx,
    input  wire [191:0] top_mvy,
    input  wire [31:0]  top_ref,

    input  wire [7:0] nb_y_i [0:399],
    input  wire [7:0] nb_u_i [0:143],
    input  wire [7:0] nb_v_i [0:143],
    output wire [7:0] nb_y_o [0:399],
    output wire [7:0] nb_u_o [0:143],
    output wire [7:0] nb_v_o [0:143],

    output wire [15:0] luma_modified_samples,
    output wire [15:0] chroma_modified_samples,
    output wire [15:0] edge_segments_filtered,
    output wire [15:0] bs4_segments,
    output wire [5:0]  last_chroma_qp_avg,
    output wire        filter_pipe_error,
    output wire        unsupported_ref
);

    h264_deblock_mb_filter u_dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .busy(busy),
        .done(done),
        .disable_deblocking_filter_idc(disable_deblocking_filter_idc),
        .slice_alpha_c0_offset(slice_alpha_c0_offset),
        .slice_beta_offset(slice_beta_offset),
        .chroma_qp_index_offset(chroma_qp_index_offset),
        .left_mb_avail(left_mb_avail),
        .top_mb_avail(top_mb_avail),
        .left_mb_other_slice(left_mb_other_slice),
        .top_mb_other_slice(top_mb_other_slice),
        .cur_intra(cur_intra),
        .cur_qp_y(cur_qp_y),
        .cur_nz(cur_nz),
        .cur_mvx(cur_mvx),
        .cur_mvy(cur_mvy),
        .cur_ref(cur_ref),
        .left_intra(left_intra),
        .left_qp_y(left_qp_y),
        .left_nz(left_nz),
        .left_mvx(left_mvx),
        .left_mvy(left_mvy),
        .left_ref(left_ref),
        .top_intra(top_intra),
        .top_qp_y(top_qp_y),
        .top_nz(top_nz),
        .top_mvx(top_mvx),
        .top_mvy(top_mvy),
        .top_ref(top_ref),
        .nb_y_i(nb_y_i),
        .nb_u_i(nb_u_i),
        .nb_v_i(nb_v_i),
        .nb_y_o(nb_y_o),
        .nb_u_o(nb_u_o),
        .nb_v_o(nb_v_o),
        .luma_modified_samples(luma_modified_samples),
        .chroma_modified_samples(chroma_modified_samples),
        .edge_segments_filtered(edge_segments_filtered),
        .bs4_segments(bs4_segments),
        .last_chroma_qp_avg(last_chroma_qp_avg),
        .filter_pipe_error(filter_pipe_error),
        .unsupported_ref(unsupported_ref)
    );

endmodule

`default_nettype wire
