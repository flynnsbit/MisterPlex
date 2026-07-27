module h264_cabac_engine_tb_top (
    input  wire               clk,
    input  wire               reset,
    input  wire               load,
    input  wire signed [31:0] load_low,
    input  wire        [8:0]  load_range,
    output wire        [15:0] refill_addr,
    input  wire        [15:0] refill_data,
    input  wire               valid,
    output wire               ready,
    input  wire        [1:0]  mode,
    input  wire        [6:0]  state_in,
    output wire               out_valid,
    output wire               bin,
    output wire        [6:0]  state_out,
    output wire signed [31:0] low_dbg,
    output wire        [8:0]  range_dbg,
    output wire        [15:0] byte_pos_dbg
);
    wire dut_bin;

    h264_cabac_engine dut (
        .clk(clk),
        .reset(reset),
        .load(load),
        .load_low(load_low),
        .load_range(load_range),
        .refill_addr(refill_addr),
        .refill_data(refill_data),
        .valid(valid),
        .ready(ready),
        .mode(mode),
        .state_in(state_in),
        .out_valid(out_valid),
        .bin(dut_bin),
        .state_out(state_out),
        .low_dbg(low_dbg),
        .range_dbg(range_dbg),
        .byte_pos_dbg(byte_pos_dbg)
    );

`ifdef CABAC_NEGATIVE_TEST
    assign bin = ~dut_bin;
`else
    assign bin = dut_bin;
`endif
endmodule
