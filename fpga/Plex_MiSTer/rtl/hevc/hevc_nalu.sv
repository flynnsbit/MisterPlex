// HEVC Annex-B NAL scanner + header ports.
// Phase 0: Main still / low-delay P. Reject tiles, WPP, B, 10-bit, CTB 64.
// Lives on clk_sys for byte ingest. Hands RBSP to CABAC across clk_ddr FIFO (not in this file).
// Do not instantiate in Plex.sv.

`default_nettype none
`include "hevc_pkg.svh"

module hevc_nalu (
    input  wire        clk_sys,
    input  wire        reset,

    input  wire        in_valid,
    input  wire [7:0]  in_byte,
    input  wire        in_last,
    output wire        in_ready,

    output reg         nal_valid,
    output reg  [5:0]  nal_unit_type,
    output reg  [5:0]  nuh_layer_id,
    output reg  [2:0]  nuh_temporal_id_plus1,
    output reg         nal_is_vcl,
    output reg         nal_is_idr,
    output reg         nal_reject,      // RASL/RADL, reserved, or layer != 0
    output reg  [3:0]  nal_reject_code,

    // RBSP byte stream toward slice / VPS-SPS-PPS (clk_sys). CABAC takes this via async FIFO.
    output reg         rbsp_valid,
    output reg  [7:0]  rbsp_byte,
    output reg         rbsp_last,
    input  wire        rbsp_ready
);
    assign in_ready = rbsp_ready || !rbsp_valid;

    localparam [3:0]
        REJ_OK     = 4'd0,
        REJ_LAYER  = 4'd1,
        REJ_RASL   = 4'd2,
        REJ_RADL   = 4'd3,
        REJ_TYPE   = 4'd4;

    // Skeleton: start-code hunt + 2-byte NAL header. Body is a later fill by MisterFPGA.
    always @(posedge clk_sys) begin
        if (reset) begin
            nal_valid <= 1'b0;
            nal_unit_type <= 6'd0;
            nuh_layer_id <= 6'd0;
            nuh_temporal_id_plus1 <= 3'd1;
            nal_is_vcl <= 1'b0;
            nal_is_idr <= 1'b0;
            nal_reject <= 1'b0;
            nal_reject_code <= REJ_OK;
            rbsp_valid <= 1'b0;
            rbsp_byte <= 8'd0;
            rbsp_last <= 1'b0;
        end
    end
endmodule

`default_nettype wire
