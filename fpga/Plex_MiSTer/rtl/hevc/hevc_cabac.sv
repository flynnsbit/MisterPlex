// HEVC CABAC engine — Phase 0 first cut.
// Clock: clk_ddr 90 MHz. Not clk_sys. Not 20 MHz.
// Target: 1 regular bin / cycle. 2-cycle/bin @ 20 MHz fails.
// Domain cross: payload FIFO (clk_sys write / clk_ddr read) is outside this module.
// Do not instantiate in Plex.sv.

`default_nettype none

module hevc_cabac (
    input  wire        clk_ddr,
    input  wire        reset,

    input  wire        slice_start,
    input  wire        cabac_init_flag,
    input  wire [1:0]  slice_type,
    input  wire [5:0]  slice_qp,
    input  wire [5:0]  ctb_log2,

    input  wire        rbsp_valid,
    input  wire [7:0]  rbsp_byte,
    output wire        rbsp_ready,
    input  wire        rbsp_last,

    input  wire        req_valid,
    input  wire [6:0]  req_ctx,
    input  wire        req_bypass,
    input  wire        req_terminate,
    output reg         req_ready,
    output reg         bin_valid,
    output reg         bin,
    output reg         cabac_error,

    output reg  [31:0] bins_this_pic,
    output reg         pic_over_budget
);
    localparam [31:0] BUDGET_720P30 = 32'd3_000_000;

    assign rbsp_ready = 1'b0;

    always @(posedge clk_ddr) begin
        if (reset) begin
            req_ready <= 1'b0;
            bin_valid <= 1'b0;
            bin <= 1'b0;
            cabac_error <= 1'b0;
            bins_this_pic <= 32'd0;
            pic_over_budget <= 1'b0;
        end else if (slice_start) begin
            bins_this_pic <= 32'd0;
            pic_over_budget <= 1'b0;
            cabac_error <= 1'b0;
        end else if (bin_valid) begin
            bins_this_pic <= bins_this_pic + 32'd1;
            if ((bins_this_pic + 32'd1) > BUDGET_720P30)
                pic_over_budget <= 1'b1;
        end
    end
endmodule

`default_nettype wire
