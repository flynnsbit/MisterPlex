`include "slice_hdr_parser_bounded.svh"
`include "slice_hdr_parser_legacy.svh"
`default_nettype none

// Legacy diagnostics are a separately elaborated compatibility mode, not a
// second residual parser alongside the modern controller.
module slice_hdr_parser #(
    parameter int BIT_W = 17,
    parameter bit LEGACY_DIAGNOSTIC = 1'b0
) (
    input wire clk, reset, cap_clear, cap_en,
    input wire [7:0] cap_data,
    input wire cap_end, is_idr_nal,
    input wire [1:0] nal_ref_idc,
    input wire [4:0] log2_max_frame_num,
    input wire [4:0] log2_max_pic_order_cnt_lsb,
    input wire [2:0] poc_type,
    input wire sps_ready, pps_ready, deblock_ctrl,
    input wire signed [7:0] pic_init_qp,
    input wire [7:0] active_pps_id, num_ref_l0,
    output wire valid, error,
    output wire [15:0] first_mb,
    output wire [7:0] slice_type, pps_id,
    output wire [15:0] frame_num, idr_pic_id,
    output wire is_i_slice,
    output wire signed [7:0] slice_qp_delta,
    output wire [5:0] slice_qp,
    output wire [1:0] disable_deblocking_idc,
    output wire signed [7:0] slice_alpha_c0_offset_div2, slice_beta_offset_div2,
    output wire [7:0] first_mb_type,
    output wire has_mb_type,
    output wire [4:0] residual_tc,
    output wire [1:0] residual_t1,
    output wire residual_ok,
    output wire signed [7:0] residual_dc,
    output wire [7:0] residual_csum,
    output wire signed [8:0] residual_coeff [0:15],
    output wire residual_place_pulse, residual_place_ok,
    output wire [4:0] residual_place_tc,
    output wire [1:0] residual_place_t1,
    output wire signed [7:0] residual_place_dc,
    output wire [5:0] residual_place_qp,
    output wire signed [8:0] residual_place_coeff [0:15],
    output wire [BIT_W-1:0] bit_pos_hdr, bit_pos_resid,
    output wire bit_pos_valid, busy
);
    generate
        if (LEGACY_DIAGNOSTIC) begin : legacy_diagnostic
            wire [16:0] legacy_hdr, legacy_resid;
            slice_hdr_parser_legacy parser (
                .bit_pos_hdr(legacy_hdr), .bit_pos_resid(legacy_resid), .*
            );
            assign bit_pos_hdr = BIT_W'(legacy_hdr);
            assign bit_pos_resid = BIT_W'(legacy_resid);
            assign error = 1'b0;
            assign disable_deblocking_idc = 2'd0;
            assign slice_alpha_c0_offset_div2 = 8'sd0;
            assign slice_beta_offset_div2 = 8'sd0;
        end else begin : bounded_header
            slice_hdr_parser_bounded #(.BIT_W(BIT_W)) parser (.*);
        end
    endgenerate
endmodule
`default_nettype wire
