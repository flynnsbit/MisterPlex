// Testbench top for h264_cavlc_mb_decoder — multi-block CAVLC.
`default_nettype none

module h264_cavlc_mb_decoder_tb_top #(
    parameter int MAX_BYTES = 512
)(
    input  wire               clk,
    input  wire               reset,
    input  wire               start,
    input  wire [1:0]         mb_type,
    input  wire [5:0]         cbp,
    input  wire [9:0]         bit_offset_in,
    input  wire [9:0]         bit_len,
    input  wire [7:0]         rbsp [0:MAX_BYTES-1],
    input  wire [7:0]         mb_x,
    input  wire [7:0]         mb_y,
    input  wire [15:0]        mb_index,
    input  wire [7:0]         mb_width,
    input  wire [15:0]        first_mb_in_slice,
    input  wire [4:0]         left_tc_luma [0:3],
    input  wire               left_tc_luma_valid,
    input  wire [4:0]         above_tc_luma [0:3],
    input  wire               above_tc_luma_valid,
    input  wire [4:0]         left_tc_cb [0:1],
    input  wire               left_tc_cb_valid,
    input  wire [4:0]         above_tc_cb [0:1],
    input  wire               above_tc_cb_valid,
    input  wire [4:0]         left_tc_cr [0:1],
    input  wire               left_tc_cr_valid,
    input  wire [4:0]         above_tc_cr [0:1],
    input  wire               above_tc_cr_valid,
    output wire               block_done,
    output wire [4:0]         block_idx,
    output wire [4:0]         block_tc,
    output wire signed [15:0] block_coeff [0:15],
    output wire [4:0]         block_max_coeff,
    output wire               mb_done,
    output wire [9:0]         bit_offset_out,
    output wire               busy,
    output wire               error
);

    h264_cavlc_mb_decoder #(.MAX_BYTES(MAX_BYTES)) u_dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .mb_type(mb_type),
        .cbp(cbp),
        .bit_offset_in(bit_offset_in),
        .bit_len(bit_len),
        .rbsp(rbsp),
        .mb_x(mb_x),
        .mb_y(mb_y),
        .mb_index(mb_index),
        .mb_width(mb_width),
        .first_mb_in_slice(first_mb_in_slice),
        .left_tc_luma(left_tc_luma),
        .left_tc_luma_valid(left_tc_luma_valid),
        .above_tc_luma(above_tc_luma),
        .above_tc_luma_valid(above_tc_luma_valid),
        .left_tc_cb(left_tc_cb),
        .left_tc_cb_valid(left_tc_cb_valid),
        .above_tc_cb(above_tc_cb),
        .above_tc_cb_valid(above_tc_cb_valid),
        .left_tc_cr(left_tc_cr),
        .left_tc_cr_valid(left_tc_cr_valid),
        .above_tc_cr(above_tc_cr),
        .above_tc_cr_valid(above_tc_cr_valid),
        .block_done(block_done),
        .block_idx(block_idx),
        .block_tc(block_tc),
        .block_coeff(block_coeff),
        .block_max_coeff(block_max_coeff),
        .mb_done(mb_done),
        .bit_offset_out(bit_offset_out),
        .busy(busy),
        .error(error)
    );

endmodule

`default_nettype wire
