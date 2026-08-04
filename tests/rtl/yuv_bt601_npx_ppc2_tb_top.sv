// Odd/even distinct-pixel RED/GREEN for PPC=2 N-wide YUV extract.
// GREEN: lane0 and lane1 RGB differ when Y[src] != Y[src+1].
// RED twin (compile-time): if extractor used only src_x0 for both lanes, fail.
`timescale 1ns/1ps
module yuv_bt601_npx_ppc2_tb_top (
    input  wire clk,
    input  wire reset,
    input  wire in_valid,
    input  wire [10:0] src_x0,
    input  wire [63:0] y_qword,
    input  wire [63:0] u_qword,
    input  wire [63:0] v_qword,
    output wire out_valid,
    output wire [15:0] out_r,
    output wire [15:0] out_g,
    output wire [15:0] out_b,
    output wire [1:0]  out_lv
);
    yuv_bt601_npx #(.PX_PER_CLK(2), .X_W(11)) u_dut (
        .clk(clk), .reset(reset),
        .in_valid(in_valid),
        .src_x0(src_x0),
        .y_qword(y_qword),
        .u_qword(u_qword),
        .v_qword(v_qword),
        .y_qword_hi(64'd0),
        .y_hi_valid(1'b0),
        .out_valid(out_valid),
        .out_r(out_r),
        .out_g(out_g),
        .out_b(out_b),
        .out_lane_valid(out_lv)
    );
endmodule
