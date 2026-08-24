// HEVC slice header ports (Phase 0).
// Parse is exp-Golomb / fixed on clk_sys. Reject B, tiles, WPP, dependent slices, CTB 64.
// After first_slice_segment_in_pic and slice_qp, payload bits go to CABAC (clk_ddr).

`default_nettype none
`include "hevc_pkg.svh"

module hevc_slice_hdr (
    input  wire        clk_sys,
    input  wire        reset,

    input  wire        rbsp_valid,
    input  wire [7:0]  rbsp_byte,
    input  wire        rbsp_last,
    output wire        rbsp_ready,
    input  wire [5:0]  nal_unit_type,
    input  wire        nal_is_idr,

    // latched SPS/PPS (from hevc_sps / hevc_pps, later)
    input  wire [5:0]  log2_ctb_size,          // 4=16, 5=32; 6=64 reject
    input  wire        tiles_enabled,
    input  wire        entropy_sync_enabled,   // WPP
    input  wire        dependent_slice_enabled,
    input  wire [4:0]  bit_depth_luma_minus8,
    input  wire [1:0]  chroma_format_idc,
    input  wire [3:0]  sps_max_num_reorder_pics,
    input  wire [4:0]  num_ref_idx_l0_default,

    output reg         hdr_valid,
    output reg         hdr_reject,
    output reg  [3:0]  hdr_reject_code,
    output reg  [1:0]  slice_type,             // 2=I 1=P 0=B (B reject)
    output reg         first_slice_segment,
    output reg  [15:0] slice_segment_addr,
    output reg signed [7:0] slice_qp_delta,
    output reg  [5:0]  slice_qp,               // 0..51
    output reg         sao_luma_flag,
    output reg         sao_chroma_flag,
    output reg         cabac_init_flag,
    output reg  [4:0]  num_ref_idx_l0_active,
    output reg         slice_deblock_disabled,
    output reg signed [3:0] beta_offset_div2,
    output reg signed [3:0] tc_offset_div2,

    // bit cursor handoff to CABAC domain
    output reg         payload_valid,          // remaining RBSP after header
    output reg  [7:0]  payload_byte,
    output reg         payload_last,
    input  wire        payload_ready
);
    assign rbsp_ready = payload_ready || !payload_valid;

    localparam [3:0]
        REJ_OK      = 4'd0,
        REJ_B       = 4'd1,
        REJ_TILE    = 4'd2,
        REJ_WPP     = 4'd3,
        REJ_DEP     = 4'd4,
        REJ_CTB64   = 4'd5,
        REJ_10BIT   = 4'd6,
        REJ_CHROMA  = 4'd7,
        REJ_REORDER = 4'd8,
        REJ_REFS    = 4'd9;

    always @(posedge clk_sys) begin
        if (reset) begin
            hdr_valid <= 1'b0;
            hdr_reject <= 1'b0;
            hdr_reject_code <= REJ_OK;
            slice_type <= 2'd2;
            first_slice_segment <= 1'b1;
            slice_segment_addr <= 16'd0;
            slice_qp_delta <= 8'sd0;
            slice_qp <= 6'd26;
            sao_luma_flag <= 1'b0;
            sao_chroma_flag <= 1'b0;
            cabac_init_flag <= 1'b0;
            num_ref_idx_l0_active <= 5'd1;
            slice_deblock_disabled <= 1'b0;
            beta_offset_div2 <= 4'sd0;
            tc_offset_div2 <= 4'sd0;
            payload_valid <= 1'b0;
            payload_byte <= 8'd0;
            payload_last <= 1'b0;
        end
    end
endmodule

`default_nettype wire
