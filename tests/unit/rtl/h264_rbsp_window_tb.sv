// Testbench wrapper: exposes h264_rbsp_window, the supply side of the decoder's
// random-access RBSP view. BUF_BYTES is shrunk to 1024 so the overflow and
// stale-residue paths are reachable in simulation without feeding 8 KB.
module h264_rbsp_window_tb (
    input  wire        clk,
    input  wire        reset,
    input  wire        cap_clear,
    input  wire        cap_en,
    input  wire [7:0]  cap_data,
    input  wire        cap_end,
    input  wire        request_valid,
    input  wire [15:0] request_offset,
    output wire [7:0]  byte_out [0:63],
    output wire [15:0] window_base,
    output wire        window_valid,
    output wire [15:0] bytes_captured,
    output wire        slice_complete,
    output wire        overflow,
    output wire        underflow
);

    h264_rbsp_window #(.BUF_BYTES(1024)) u_win (
        .clk(clk),
        .reset(reset),
        .cap_clear(cap_clear),
        .cap_en(cap_en),
        .cap_data(cap_data),
        .cap_end(cap_end),
        .request_valid(request_valid),
        .request_offset(request_offset),
        .byte_out(byte_out),
        .window_base(window_base),
        .window_valid(window_valid),
        .bytes_captured(bytes_captured),
        .slice_complete(slice_complete),
        .overflow(overflow),
        .underflow(underflow)
    );

endmodule
