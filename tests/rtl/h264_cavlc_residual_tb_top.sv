// Testbench-only wrapper for real h264_cavlc_residual.sv product RTL.
`default_nettype none

module h264_cavlc_residual_tb_top #(
    parameter int MAX_BYTES = 128
)(
    input  wire               clk,
    input  wire               reset,
    input  wire               start,
    input  wire [2:0]         coeff_token_table,
    input  wire [4:0]         max_coeff,
    input  wire [9:0]         bit_offset_start,
    input  wire [9:0]         bit_len,
    input  wire [7:0]         rbsp [0:MAX_BYTES-1],
    output wire               busy,
    output wire               done,
    output wire               ok,
    output wire [9:0]         bit_offset_end,
    output wire [4:0]         total_coeff,
    output wire [1:0]         trailing_ones,
    output wire [3:0]         total_zeros,
    output wire signed [15:0] coeff [0:15],
    output wire signed [15:0] level_dbg [0:15],
    output wire [3:0]         run_dbg [0:15],

    input  wire [7:0]         nc_mb_x,
    input  wire [7:0]         nc_mb_y,
    input  wire [15:0]        nc_mb_index,
    input  wire [7:0]         nc_mb_width,
    input  wire [15:0]        nc_first_mb_in_slice,
    input  wire [1:0]         nc_block_x,
    input  wire [1:0]         nc_block_y,
    input  wire               nc_left_tc_valid,
    input  wire [4:0]         nc_left_tc,
    input  wire               nc_up_tc_valid,
    input  wire [4:0]         nc_up_tc,
    output wire               nc_nA_available,
    output wire               nc_nB_available,
    output wire [4:0]         nc_nC,
    output wire [2:0]         nc_coeff_token_table,

    input  wire               src_start,
    input  wire [9:0]         src_bit_offset_start,
    input  wire [9:0]         src_bit_len,
    input  wire [3:0]         src_cbp_luma,
    input  wire [5:0]         src_qp,
    output wire               src_busy,
    output wire               src_done,
    output wire               src_ok,
    output wire [9:0]         src_bit_offset_end,
    output wire               src_luma4x4_valid,
    output wire [3:0]         src_luma4x4_idx,
    output wire [5:0]         src_luma4x4_qp,
    output wire [4:0]         src_luma4x4_total_coeff,
    output wire [1:0]         src_luma4x4_trailing_ones,
    output wire [9:0]         src_luma4x4_bit_offset_end,
    output wire signed [15:0] src_luma4x4_coeff_zigzag [0:15]
);
    wire signed [15:0] dut_coeff [0:15];

    h264_cavlc_residual_block #(.MAX_BYTES(MAX_BYTES)) u_residual (
        .clk(clk),
        .reset(reset),
        .start(start),
        .coeff_token_table(coeff_token_table),
        .max_coeff(max_coeff),
        .bit_offset_start(bit_offset_start),
        .bit_len(bit_len),
        .rbsp(rbsp),
        .busy(busy),
        .done(done),
        .ok(ok),
        .bit_offset_end(bit_offset_end),
        .total_coeff(total_coeff),
        .trailing_ones(trailing_ones),
        .total_zeros(total_zeros),
        .coeff(dut_coeff),
        .level_dbg(level_dbg),
        .run_dbg(run_dbg)
    );

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_coeff
`ifdef CAVLC_NEGATIVE_TEST
            assign coeff[i] = (i == 0) ? (dut_coeff[i] ^ 16'sd1) : dut_coeff[i];
`else
            assign coeff[i] = dut_coeff[i];
`endif
        end
    endgenerate

    h264_cavlc_nc_predictor u_nc (
        .mb_x(nc_mb_x),
        .mb_y(nc_mb_y),
        .mb_index(nc_mb_index),
        .mb_width(nc_mb_width),
        .first_mb_in_slice(nc_first_mb_in_slice),
        .block_x(nc_block_x),
        .block_y(nc_block_y),
        .left_tc_valid(nc_left_tc_valid),
        .left_tc(nc_left_tc),
        .up_tc_valid(nc_up_tc_valid),
        .up_tc(nc_up_tc),
        .nA_available(nc_nA_available),
        .nB_available(nc_nB_available),
        .nC(nc_nC),
        .coeff_token_table(nc_coeff_token_table)
    );

    h264_luma4x4_residual_source #(.MAX_BYTES(MAX_BYTES)) u_src (
        .clk(clk), .reset(reset), .start(src_start),
        .bit_offset_start(src_bit_offset_start), .bit_len(src_bit_len),
        .cbp_luma(src_cbp_luma), .qp(src_qp), .rbsp(rbsp),
        .busy(src_busy), .done(src_done), .ok(src_ok),
        .bit_offset_end(src_bit_offset_end),
        .luma4x4_valid(src_luma4x4_valid), .luma4x4_idx(src_luma4x4_idx),
        .luma4x4_qp(src_luma4x4_qp), .luma4x4_total_coeff(src_luma4x4_total_coeff),
        .luma4x4_trailing_ones(src_luma4x4_trailing_ones),
        .luma4x4_bit_offset_end(src_luma4x4_bit_offset_end),
        .luma4x4_coeff_zigzag(src_luma4x4_coeff_zigzag)
    );
endmodule

`default_nettype wire
