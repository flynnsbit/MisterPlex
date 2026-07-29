// H.264 Baseline CAVLC residual block decoder building blocks.
// Sequential bit/table decoder; outputs coefficients in CAVLC scan order for h264_dequant4x4.

module h264_cavlc_nc_predictor (
    input  wire [7:0]  mb_x,
    input  wire [7:0]  mb_y,
    input  wire [15:0] mb_index,
    input  wire [7:0]  mb_width,
    input  wire [15:0] first_mb_in_slice,
    input  wire [1:0]  block_x,
    input  wire [1:0]  block_y,
    input  wire        left_tc_valid,
    input  wire [4:0]  left_tc,
    input  wire        up_tc_valid,
    input  wire [4:0]  up_tc,
    output wire        nA_available,
    output wire        nB_available,
    output wire [4:0]  nC,
    output wire [2:0]  coeff_token_table
);
    wire left_mb_available = (mb_x != 8'd0) && ((mb_index - 16'd1) >= first_mb_in_slice);
    wire up_mb_available   = (mb_y != 8'd0) && ((mb_index - {8'd0, mb_width}) >= first_mb_in_slice);
    assign nA_available = left_tc_valid && ((block_x != 2'd0) || left_mb_available);
    assign nB_available = up_tc_valid   && ((block_y != 2'd0) || up_mb_available);
    assign nC = (nA_available && nB_available) ? ((left_tc + up_tc + 5'd1) >> 1) :
                nA_available ? left_tc :
                nB_available ? up_tc : 5'd0;
    assign coeff_token_table = (nC < 5'd2) ? 3'd0 :
                               (nC < 5'd4) ? 3'd1 :
                               (nC < 5'd8) ? 3'd2 : 3'd3;
endmodule

module h264_cavlc_residual_block #(
    parameter int MAX_BYTES = 64
)(
    input  wire               clk,
    input  wire               reset,
    input  wire               start,
    input  wire [2:0]         coeff_token_table, // 0:nC<2, 1:nC<4, 2:nC<8, 3:nC>=8, 4:chroma_dc
    input  wire [4:0]         max_coeff,         // 16 luma, 15 AC-only, 4 chroma DC
    input  wire [9:0]         bit_offset_start,
    input  wire [9:0]         bit_len,
    input  wire [7:0]         rbsp [0:MAX_BYTES-1],
    output reg                busy,
    output reg                done,
    output reg                ok,
    output reg [9:0]          bit_offset_end,
    output reg [4:0]          total_coeff,
    output reg [1:0]          trailing_ones,
    output reg [3:0]          total_zeros,
    output reg signed [15:0]  coeff [0:15],
    output reg signed [15:0]  level_dbg [0:15],
    output reg [3:0]          run_dbg [0:15]
);
    localparam [4:0]
        ST_IDLE       = 5'd0,
        ST_TOKEN_BIT  = 5'd1,
        ST_TOKEN_CHK  = 5'd2,
        ST_SIGN       = 5'd3,
        ST_LVL_PRE    = 5'd4,
        ST_LVL_SUF    = 5'd5,
        ST_LVL_STORE  = 5'd6,
        ST_TZ_BIT     = 5'd7,
        ST_TZ_CHK     = 5'd8,
        ST_RUN_BIT    = 5'd9,
        ST_RUN_CHK    = 5'd10,
        ST_PLACE_INIT = 5'd11,
        ST_PLACE_STEP = 5'd12,
        ST_DONE       = 5'd13,
        ST_FAIL       = 5'd14;

    reg [4:0] st;
    reg [9:0] bit_pos;
    reg [15:0] code;
    reg [4:0] code_len;
    reg [4:0] tc_r;
    reg [1:0] t1_r;
    reg [4:0] idx;
    reg [2:0] suffix_length;
    reg [5:0] prefix;
    reg [4:0] suffix_left;
    reg [31:0] suffix_acc;
    reg first_non_t1;
    reg [31:0] level_code;
    reg [3:0] zeros_left;
    reg [4:0] place_i;
    reg signed [5:0] coeff_num;

    // Size the byte index from MAX_BYTES: a fixed [8:3] slice silently wraps
    // every byte at or above 64 when the instance is wider (slice_hdr_parser
    // uses MAX_BYTES=96).
    localparam int BYTE_IDX_W = (MAX_BYTES <= 2) ? 1 : $clog2(MAX_BYTES);
    wire [BYTE_IDX_W-1:0] rbsp_byte_idx = bit_pos[BYTE_IDX_W+2:3];
    wire cur_bit = (bit_pos < bit_len) ? rbsp[rbsp_byte_idx][3'd7 - bit_pos[2:0]] : 1'b0;
    wire token_too_long = (coeff_token_table == 3'd3) ? (code_len >= 5'd6) :
                          (coeff_token_table == 3'd4) ? (code_len >= 5'd8) : (code_len >= 5'd16);
    wire tz_is_chroma = (max_coeff == 5'd4);

    function automatic [7:0] coeff_token_lookup(input [2:0] tab, input [4:0] len, input [15:0] bits);
        begin
            coeff_token_lookup = 8'd0;
            case ({tab, len, bits})
            24'h010001: coeff_token_lookup = {1'b1, 5'd0, 2'd0};
            24'h060005: coeff_token_lookup = {1'b1, 5'd1, 2'd0};
            24'h020001: coeff_token_lookup = {1'b1, 5'd1, 2'd1};
            24'h080007: coeff_token_lookup = {1'b1, 5'd2, 2'd0};
            24'h060004: coeff_token_lookup = {1'b1, 5'd2, 2'd1};
            24'h030001: coeff_token_lookup = {1'b1, 5'd2, 2'd2};
            24'h090007: coeff_token_lookup = {1'b1, 5'd3, 2'd0};
            24'h080006: coeff_token_lookup = {1'b1, 5'd3, 2'd1};
            24'h070005: coeff_token_lookup = {1'b1, 5'd3, 2'd2};
            24'h050003: coeff_token_lookup = {1'b1, 5'd3, 2'd3};
            24'h0a0007: coeff_token_lookup = {1'b1, 5'd4, 2'd0};
            24'h090006: coeff_token_lookup = {1'b1, 5'd4, 2'd1};
            24'h080005: coeff_token_lookup = {1'b1, 5'd4, 2'd2};
            24'h060003: coeff_token_lookup = {1'b1, 5'd4, 2'd3};
            24'h0b0007: coeff_token_lookup = {1'b1, 5'd5, 2'd0};
            24'h0a0006: coeff_token_lookup = {1'b1, 5'd5, 2'd1};
            24'h090005: coeff_token_lookup = {1'b1, 5'd5, 2'd2};
            24'h070004: coeff_token_lookup = {1'b1, 5'd5, 2'd3};
            24'h0d000f: coeff_token_lookup = {1'b1, 5'd6, 2'd0};
            24'h0b0006: coeff_token_lookup = {1'b1, 5'd6, 2'd1};
            24'h0a0005: coeff_token_lookup = {1'b1, 5'd6, 2'd2};
            24'h080004: coeff_token_lookup = {1'b1, 5'd6, 2'd3};
            24'h0d000b: coeff_token_lookup = {1'b1, 5'd7, 2'd0};
            24'h0d000e: coeff_token_lookup = {1'b1, 5'd7, 2'd1};
            24'h0b0005: coeff_token_lookup = {1'b1, 5'd7, 2'd2};
            24'h090004: coeff_token_lookup = {1'b1, 5'd7, 2'd3};
            24'h0d0008: coeff_token_lookup = {1'b1, 5'd8, 2'd0};
            24'h0d000a: coeff_token_lookup = {1'b1, 5'd8, 2'd1};
            24'h0d000d: coeff_token_lookup = {1'b1, 5'd8, 2'd2};
            24'h0a0004: coeff_token_lookup = {1'b1, 5'd8, 2'd3};
            24'h0e000f: coeff_token_lookup = {1'b1, 5'd9, 2'd0};
            24'h0e000e: coeff_token_lookup = {1'b1, 5'd9, 2'd1};
            24'h0d0009: coeff_token_lookup = {1'b1, 5'd9, 2'd2};
            24'h0b0004: coeff_token_lookup = {1'b1, 5'd9, 2'd3};
            24'h0e000b: coeff_token_lookup = {1'b1, 5'd10, 2'd0};
            24'h0e000a: coeff_token_lookup = {1'b1, 5'd10, 2'd1};
            24'h0e000d: coeff_token_lookup = {1'b1, 5'd10, 2'd2};
            24'h0d000c: coeff_token_lookup = {1'b1, 5'd10, 2'd3};
            24'h0f000f: coeff_token_lookup = {1'b1, 5'd11, 2'd0};
            24'h0f000e: coeff_token_lookup = {1'b1, 5'd11, 2'd1};
            24'h0e0009: coeff_token_lookup = {1'b1, 5'd11, 2'd2};
            24'h0e000c: coeff_token_lookup = {1'b1, 5'd11, 2'd3};
            24'h0f000b: coeff_token_lookup = {1'b1, 5'd12, 2'd0};
            24'h0f000a: coeff_token_lookup = {1'b1, 5'd12, 2'd1};
            24'h0f000d: coeff_token_lookup = {1'b1, 5'd12, 2'd2};
            24'h0e0008: coeff_token_lookup = {1'b1, 5'd12, 2'd3};
            24'h10000f: coeff_token_lookup = {1'b1, 5'd13, 2'd0};
            24'h0f0001: coeff_token_lookup = {1'b1, 5'd13, 2'd1};
            24'h0f0009: coeff_token_lookup = {1'b1, 5'd13, 2'd2};
            24'h0f000c: coeff_token_lookup = {1'b1, 5'd13, 2'd3};
            24'h10000b: coeff_token_lookup = {1'b1, 5'd14, 2'd0};
            24'h10000e: coeff_token_lookup = {1'b1, 5'd14, 2'd1};
            24'h10000d: coeff_token_lookup = {1'b1, 5'd14, 2'd2};
            24'h0f0008: coeff_token_lookup = {1'b1, 5'd14, 2'd3};
            24'h100007: coeff_token_lookup = {1'b1, 5'd15, 2'd0};
            24'h10000a: coeff_token_lookup = {1'b1, 5'd15, 2'd1};
            24'h100009: coeff_token_lookup = {1'b1, 5'd15, 2'd2};
            24'h10000c: coeff_token_lookup = {1'b1, 5'd15, 2'd3};
            24'h100004: coeff_token_lookup = {1'b1, 5'd16, 2'd0};
            24'h100006: coeff_token_lookup = {1'b1, 5'd16, 2'd1};
            24'h100005: coeff_token_lookup = {1'b1, 5'd16, 2'd2};
            24'h100008: coeff_token_lookup = {1'b1, 5'd16, 2'd3};
            24'h220003: coeff_token_lookup = {1'b1, 5'd0, 2'd0};
            24'h26000b: coeff_token_lookup = {1'b1, 5'd1, 2'd0};
            24'h220002: coeff_token_lookup = {1'b1, 5'd1, 2'd1};
            24'h260007: coeff_token_lookup = {1'b1, 5'd2, 2'd0};
            24'h250007: coeff_token_lookup = {1'b1, 5'd2, 2'd1};
            24'h230003: coeff_token_lookup = {1'b1, 5'd2, 2'd2};
            24'h270007: coeff_token_lookup = {1'b1, 5'd3, 2'd0};
            24'h26000a: coeff_token_lookup = {1'b1, 5'd3, 2'd1};
            24'h260009: coeff_token_lookup = {1'b1, 5'd3, 2'd2};
            24'h240005: coeff_token_lookup = {1'b1, 5'd3, 2'd3};
            24'h280007: coeff_token_lookup = {1'b1, 5'd4, 2'd0};
            24'h260006: coeff_token_lookup = {1'b1, 5'd4, 2'd1};
            24'h260005: coeff_token_lookup = {1'b1, 5'd4, 2'd2};
            24'h240004: coeff_token_lookup = {1'b1, 5'd4, 2'd3};
            24'h280004: coeff_token_lookup = {1'b1, 5'd5, 2'd0};
            24'h270006: coeff_token_lookup = {1'b1, 5'd5, 2'd1};
            24'h270005: coeff_token_lookup = {1'b1, 5'd5, 2'd2};
            24'h250006: coeff_token_lookup = {1'b1, 5'd5, 2'd3};
            24'h290007: coeff_token_lookup = {1'b1, 5'd6, 2'd0};
            24'h280006: coeff_token_lookup = {1'b1, 5'd6, 2'd1};
            24'h280005: coeff_token_lookup = {1'b1, 5'd6, 2'd2};
            24'h260008: coeff_token_lookup = {1'b1, 5'd6, 2'd3};
            24'h2b000f: coeff_token_lookup = {1'b1, 5'd7, 2'd0};
            24'h290006: coeff_token_lookup = {1'b1, 5'd7, 2'd1};
            24'h290005: coeff_token_lookup = {1'b1, 5'd7, 2'd2};
            24'h260004: coeff_token_lookup = {1'b1, 5'd7, 2'd3};
            24'h2b000b: coeff_token_lookup = {1'b1, 5'd8, 2'd0};
            24'h2b000e: coeff_token_lookup = {1'b1, 5'd8, 2'd1};
            24'h2b000d: coeff_token_lookup = {1'b1, 5'd8, 2'd2};
            24'h270004: coeff_token_lookup = {1'b1, 5'd8, 2'd3};
            24'h2c000f: coeff_token_lookup = {1'b1, 5'd9, 2'd0};
            24'h2b000a: coeff_token_lookup = {1'b1, 5'd9, 2'd1};
            24'h2b0009: coeff_token_lookup = {1'b1, 5'd9, 2'd2};
            24'h290004: coeff_token_lookup = {1'b1, 5'd9, 2'd3};
            24'h2c000b: coeff_token_lookup = {1'b1, 5'd10, 2'd0};
            24'h2c000e: coeff_token_lookup = {1'b1, 5'd10, 2'd1};
            24'h2c000d: coeff_token_lookup = {1'b1, 5'd10, 2'd2};
            24'h2b000c: coeff_token_lookup = {1'b1, 5'd10, 2'd3};
            24'h2c0008: coeff_token_lookup = {1'b1, 5'd11, 2'd0};
            24'h2c000a: coeff_token_lookup = {1'b1, 5'd11, 2'd1};
            24'h2c0009: coeff_token_lookup = {1'b1, 5'd11, 2'd2};
            24'h2b0008: coeff_token_lookup = {1'b1, 5'd11, 2'd3};
            24'h2d000f: coeff_token_lookup = {1'b1, 5'd12, 2'd0};
            24'h2d000e: coeff_token_lookup = {1'b1, 5'd12, 2'd1};
            24'h2d000d: coeff_token_lookup = {1'b1, 5'd12, 2'd2};
            24'h2c000c: coeff_token_lookup = {1'b1, 5'd12, 2'd3};
            24'h2d000b: coeff_token_lookup = {1'b1, 5'd13, 2'd0};
            24'h2d000a: coeff_token_lookup = {1'b1, 5'd13, 2'd1};
            24'h2d0009: coeff_token_lookup = {1'b1, 5'd13, 2'd2};
            24'h2d000c: coeff_token_lookup = {1'b1, 5'd13, 2'd3};
            24'h2d0007: coeff_token_lookup = {1'b1, 5'd14, 2'd0};
            24'h2e000b: coeff_token_lookup = {1'b1, 5'd14, 2'd1};
            24'h2d0006: coeff_token_lookup = {1'b1, 5'd14, 2'd2};
            24'h2d0008: coeff_token_lookup = {1'b1, 5'd14, 2'd3};
            24'h2e0009: coeff_token_lookup = {1'b1, 5'd15, 2'd0};
            24'h2e0008: coeff_token_lookup = {1'b1, 5'd15, 2'd1};
            24'h2e000a: coeff_token_lookup = {1'b1, 5'd15, 2'd2};
            24'h2d0001: coeff_token_lookup = {1'b1, 5'd15, 2'd3};
            24'h2e0007: coeff_token_lookup = {1'b1, 5'd16, 2'd0};
            24'h2e0006: coeff_token_lookup = {1'b1, 5'd16, 2'd1};
            24'h2e0005: coeff_token_lookup = {1'b1, 5'd16, 2'd2};
            24'h2e0004: coeff_token_lookup = {1'b1, 5'd16, 2'd3};
            24'h44000f: coeff_token_lookup = {1'b1, 5'd0, 2'd0};
            24'h46000f: coeff_token_lookup = {1'b1, 5'd1, 2'd0};
            24'h44000e: coeff_token_lookup = {1'b1, 5'd1, 2'd1};
            24'h46000b: coeff_token_lookup = {1'b1, 5'd2, 2'd0};
            24'h45000f: coeff_token_lookup = {1'b1, 5'd2, 2'd1};
            24'h44000d: coeff_token_lookup = {1'b1, 5'd2, 2'd2};
            24'h460008: coeff_token_lookup = {1'b1, 5'd3, 2'd0};
            24'h45000c: coeff_token_lookup = {1'b1, 5'd3, 2'd1};
            24'h45000e: coeff_token_lookup = {1'b1, 5'd3, 2'd2};
            24'h44000c: coeff_token_lookup = {1'b1, 5'd3, 2'd3};
            24'h47000f: coeff_token_lookup = {1'b1, 5'd4, 2'd0};
            24'h45000a: coeff_token_lookup = {1'b1, 5'd4, 2'd1};
            24'h45000b: coeff_token_lookup = {1'b1, 5'd4, 2'd2};
            24'h44000b: coeff_token_lookup = {1'b1, 5'd4, 2'd3};
            24'h47000b: coeff_token_lookup = {1'b1, 5'd5, 2'd0};
            24'h450008: coeff_token_lookup = {1'b1, 5'd5, 2'd1};
            24'h450009: coeff_token_lookup = {1'b1, 5'd5, 2'd2};
            24'h44000a: coeff_token_lookup = {1'b1, 5'd5, 2'd3};
            24'h470009: coeff_token_lookup = {1'b1, 5'd6, 2'd0};
            24'h46000e: coeff_token_lookup = {1'b1, 5'd6, 2'd1};
            24'h46000d: coeff_token_lookup = {1'b1, 5'd6, 2'd2};
            24'h440009: coeff_token_lookup = {1'b1, 5'd6, 2'd3};
            24'h470008: coeff_token_lookup = {1'b1, 5'd7, 2'd0};
            24'h46000a: coeff_token_lookup = {1'b1, 5'd7, 2'd1};
            24'h460009: coeff_token_lookup = {1'b1, 5'd7, 2'd2};
            24'h440008: coeff_token_lookup = {1'b1, 5'd7, 2'd3};
            24'h48000f: coeff_token_lookup = {1'b1, 5'd8, 2'd0};
            24'h47000e: coeff_token_lookup = {1'b1, 5'd8, 2'd1};
            24'h47000d: coeff_token_lookup = {1'b1, 5'd8, 2'd2};
            24'h45000d: coeff_token_lookup = {1'b1, 5'd8, 2'd3};
            24'h48000b: coeff_token_lookup = {1'b1, 5'd9, 2'd0};
            24'h48000e: coeff_token_lookup = {1'b1, 5'd9, 2'd1};
            24'h47000a: coeff_token_lookup = {1'b1, 5'd9, 2'd2};
            24'h46000c: coeff_token_lookup = {1'b1, 5'd9, 2'd3};
            24'h49000f: coeff_token_lookup = {1'b1, 5'd10, 2'd0};
            24'h48000a: coeff_token_lookup = {1'b1, 5'd10, 2'd1};
            24'h48000d: coeff_token_lookup = {1'b1, 5'd10, 2'd2};
            24'h47000c: coeff_token_lookup = {1'b1, 5'd10, 2'd3};
            24'h49000b: coeff_token_lookup = {1'b1, 5'd11, 2'd0};
            24'h49000e: coeff_token_lookup = {1'b1, 5'd11, 2'd1};
            24'h480009: coeff_token_lookup = {1'b1, 5'd11, 2'd2};
            24'h48000c: coeff_token_lookup = {1'b1, 5'd11, 2'd3};
            24'h490008: coeff_token_lookup = {1'b1, 5'd12, 2'd0};
            24'h49000a: coeff_token_lookup = {1'b1, 5'd12, 2'd1};
            24'h49000d: coeff_token_lookup = {1'b1, 5'd12, 2'd2};
            24'h480008: coeff_token_lookup = {1'b1, 5'd12, 2'd3};
            24'h4a000d: coeff_token_lookup = {1'b1, 5'd13, 2'd0};
            24'h490007: coeff_token_lookup = {1'b1, 5'd13, 2'd1};
            24'h490009: coeff_token_lookup = {1'b1, 5'd13, 2'd2};
            24'h49000c: coeff_token_lookup = {1'b1, 5'd13, 2'd3};
            24'h4a0009: coeff_token_lookup = {1'b1, 5'd14, 2'd0};
            24'h4a000c: coeff_token_lookup = {1'b1, 5'd14, 2'd1};
            24'h4a000b: coeff_token_lookup = {1'b1, 5'd14, 2'd2};
            24'h4a000a: coeff_token_lookup = {1'b1, 5'd14, 2'd3};
            24'h4a0005: coeff_token_lookup = {1'b1, 5'd15, 2'd0};
            24'h4a0008: coeff_token_lookup = {1'b1, 5'd15, 2'd1};
            24'h4a0007: coeff_token_lookup = {1'b1, 5'd15, 2'd2};
            24'h4a0006: coeff_token_lookup = {1'b1, 5'd15, 2'd3};
            24'h4a0001: coeff_token_lookup = {1'b1, 5'd16, 2'd0};
            24'h4a0004: coeff_token_lookup = {1'b1, 5'd16, 2'd1};
            24'h4a0003: coeff_token_lookup = {1'b1, 5'd16, 2'd2};
            24'h4a0002: coeff_token_lookup = {1'b1, 5'd16, 2'd3};
            24'h660003: coeff_token_lookup = {1'b1, 5'd0, 2'd0};
            24'h660000: coeff_token_lookup = {1'b1, 5'd1, 2'd0};
            24'h660001: coeff_token_lookup = {1'b1, 5'd1, 2'd1};
            24'h660004: coeff_token_lookup = {1'b1, 5'd2, 2'd0};
            24'h660005: coeff_token_lookup = {1'b1, 5'd2, 2'd1};
            24'h660006: coeff_token_lookup = {1'b1, 5'd2, 2'd2};
            24'h660008: coeff_token_lookup = {1'b1, 5'd3, 2'd0};
            24'h660009: coeff_token_lookup = {1'b1, 5'd3, 2'd1};
            24'h66000a: coeff_token_lookup = {1'b1, 5'd3, 2'd2};
            24'h66000b: coeff_token_lookup = {1'b1, 5'd3, 2'd3};
            24'h66000c: coeff_token_lookup = {1'b1, 5'd4, 2'd0};
            24'h66000d: coeff_token_lookup = {1'b1, 5'd4, 2'd1};
            24'h66000e: coeff_token_lookup = {1'b1, 5'd4, 2'd2};
            24'h66000f: coeff_token_lookup = {1'b1, 5'd4, 2'd3};
            24'h660010: coeff_token_lookup = {1'b1, 5'd5, 2'd0};
            24'h660011: coeff_token_lookup = {1'b1, 5'd5, 2'd1};
            24'h660012: coeff_token_lookup = {1'b1, 5'd5, 2'd2};
            24'h660013: coeff_token_lookup = {1'b1, 5'd5, 2'd3};
            24'h660014: coeff_token_lookup = {1'b1, 5'd6, 2'd0};
            24'h660015: coeff_token_lookup = {1'b1, 5'd6, 2'd1};
            24'h660016: coeff_token_lookup = {1'b1, 5'd6, 2'd2};
            24'h660017: coeff_token_lookup = {1'b1, 5'd6, 2'd3};
            24'h660018: coeff_token_lookup = {1'b1, 5'd7, 2'd0};
            24'h660019: coeff_token_lookup = {1'b1, 5'd7, 2'd1};
            24'h66001a: coeff_token_lookup = {1'b1, 5'd7, 2'd2};
            24'h66001b: coeff_token_lookup = {1'b1, 5'd7, 2'd3};
            24'h66001c: coeff_token_lookup = {1'b1, 5'd8, 2'd0};
            24'h66001d: coeff_token_lookup = {1'b1, 5'd8, 2'd1};
            24'h66001e: coeff_token_lookup = {1'b1, 5'd8, 2'd2};
            24'h66001f: coeff_token_lookup = {1'b1, 5'd8, 2'd3};
            24'h660020: coeff_token_lookup = {1'b1, 5'd9, 2'd0};
            24'h660021: coeff_token_lookup = {1'b1, 5'd9, 2'd1};
            24'h660022: coeff_token_lookup = {1'b1, 5'd9, 2'd2};
            24'h660023: coeff_token_lookup = {1'b1, 5'd9, 2'd3};
            24'h660024: coeff_token_lookup = {1'b1, 5'd10, 2'd0};
            24'h660025: coeff_token_lookup = {1'b1, 5'd10, 2'd1};
            24'h660026: coeff_token_lookup = {1'b1, 5'd10, 2'd2};
            24'h660027: coeff_token_lookup = {1'b1, 5'd10, 2'd3};
            24'h660028: coeff_token_lookup = {1'b1, 5'd11, 2'd0};
            24'h660029: coeff_token_lookup = {1'b1, 5'd11, 2'd1};
            24'h66002a: coeff_token_lookup = {1'b1, 5'd11, 2'd2};
            24'h66002b: coeff_token_lookup = {1'b1, 5'd11, 2'd3};
            24'h66002c: coeff_token_lookup = {1'b1, 5'd12, 2'd0};
            24'h66002d: coeff_token_lookup = {1'b1, 5'd12, 2'd1};
            24'h66002e: coeff_token_lookup = {1'b1, 5'd12, 2'd2};
            24'h66002f: coeff_token_lookup = {1'b1, 5'd12, 2'd3};
            24'h660030: coeff_token_lookup = {1'b1, 5'd13, 2'd0};
            24'h660031: coeff_token_lookup = {1'b1, 5'd13, 2'd1};
            24'h660032: coeff_token_lookup = {1'b1, 5'd13, 2'd2};
            24'h660033: coeff_token_lookup = {1'b1, 5'd13, 2'd3};
            24'h660034: coeff_token_lookup = {1'b1, 5'd14, 2'd0};
            24'h660035: coeff_token_lookup = {1'b1, 5'd14, 2'd1};
            24'h660036: coeff_token_lookup = {1'b1, 5'd14, 2'd2};
            24'h660037: coeff_token_lookup = {1'b1, 5'd14, 2'd3};
            24'h660038: coeff_token_lookup = {1'b1, 5'd15, 2'd0};
            24'h660039: coeff_token_lookup = {1'b1, 5'd15, 2'd1};
            24'h66003a: coeff_token_lookup = {1'b1, 5'd15, 2'd2};
            24'h66003b: coeff_token_lookup = {1'b1, 5'd15, 2'd3};
            24'h66003c: coeff_token_lookup = {1'b1, 5'd16, 2'd0};
            24'h66003d: coeff_token_lookup = {1'b1, 5'd16, 2'd1};
            24'h66003e: coeff_token_lookup = {1'b1, 5'd16, 2'd2};
            24'h66003f: coeff_token_lookup = {1'b1, 5'd16, 2'd3};
            24'h820001: coeff_token_lookup = {1'b1, 5'd0, 2'd0};
            24'h860007: coeff_token_lookup = {1'b1, 5'd1, 2'd0};
            24'h810001: coeff_token_lookup = {1'b1, 5'd1, 2'd1};
            24'h860004: coeff_token_lookup = {1'b1, 5'd2, 2'd0};
            24'h860006: coeff_token_lookup = {1'b1, 5'd2, 2'd1};
            24'h830001: coeff_token_lookup = {1'b1, 5'd2, 2'd2};
            24'h860003: coeff_token_lookup = {1'b1, 5'd3, 2'd0};
            24'h870003: coeff_token_lookup = {1'b1, 5'd3, 2'd1};
            24'h870002: coeff_token_lookup = {1'b1, 5'd3, 2'd2};
            24'h860005: coeff_token_lookup = {1'b1, 5'd3, 2'd3};
            24'h860002: coeff_token_lookup = {1'b1, 5'd4, 2'd0};
            24'h880003: coeff_token_lookup = {1'b1, 5'd4, 2'd1};
            24'h880002: coeff_token_lookup = {1'b1, 5'd4, 2'd2};
            24'h870000: coeff_token_lookup = {1'b1, 5'd4, 2'd3};
            default: coeff_token_lookup = 8'd0;
            endcase
        end
    endfunction

    function automatic [4:0] total_zeros_lookup(input chroma, input [4:0] tc, input [3:0] len, input [8:0] bits);
        begin
            total_zeros_lookup = 5'd0;
            case ({chroma, tc, len, bits})
            19'h02201: total_zeros_lookup = {1'b1, 4'd0};
            19'h02603: total_zeros_lookup = {1'b1, 4'd1};
            19'h02602: total_zeros_lookup = {1'b1, 4'd2};
            19'h02803: total_zeros_lookup = {1'b1, 4'd3};
            19'h02802: total_zeros_lookup = {1'b1, 4'd4};
            19'h02a03: total_zeros_lookup = {1'b1, 4'd5};
            19'h02a02: total_zeros_lookup = {1'b1, 4'd6};
            19'h02c03: total_zeros_lookup = {1'b1, 4'd7};
            19'h02c02: total_zeros_lookup = {1'b1, 4'd8};
            19'h02e03: total_zeros_lookup = {1'b1, 4'd9};
            19'h02e02: total_zeros_lookup = {1'b1, 4'd10};
            19'h03003: total_zeros_lookup = {1'b1, 4'd11};
            19'h03002: total_zeros_lookup = {1'b1, 4'd12};
            19'h03203: total_zeros_lookup = {1'b1, 4'd13};
            19'h03202: total_zeros_lookup = {1'b1, 4'd14};
            19'h03201: total_zeros_lookup = {1'b1, 4'd15};
            19'h04607: total_zeros_lookup = {1'b1, 4'd0};
            19'h04606: total_zeros_lookup = {1'b1, 4'd1};
            19'h04605: total_zeros_lookup = {1'b1, 4'd2};
            19'h04604: total_zeros_lookup = {1'b1, 4'd3};
            19'h04603: total_zeros_lookup = {1'b1, 4'd4};
            19'h04805: total_zeros_lookup = {1'b1, 4'd5};
            19'h04804: total_zeros_lookup = {1'b1, 4'd6};
            19'h04803: total_zeros_lookup = {1'b1, 4'd7};
            19'h04802: total_zeros_lookup = {1'b1, 4'd8};
            19'h04a03: total_zeros_lookup = {1'b1, 4'd9};
            19'h04a02: total_zeros_lookup = {1'b1, 4'd10};
            19'h04c03: total_zeros_lookup = {1'b1, 4'd11};
            19'h04c02: total_zeros_lookup = {1'b1, 4'd12};
            19'h04c01: total_zeros_lookup = {1'b1, 4'd13};
            19'h04c00: total_zeros_lookup = {1'b1, 4'd14};
            19'h06805: total_zeros_lookup = {1'b1, 4'd0};
            19'h06607: total_zeros_lookup = {1'b1, 4'd1};
            19'h06606: total_zeros_lookup = {1'b1, 4'd2};
            19'h06605: total_zeros_lookup = {1'b1, 4'd3};
            19'h06804: total_zeros_lookup = {1'b1, 4'd4};
            19'h06803: total_zeros_lookup = {1'b1, 4'd5};
            19'h06604: total_zeros_lookup = {1'b1, 4'd6};
            19'h06603: total_zeros_lookup = {1'b1, 4'd7};
            19'h06802: total_zeros_lookup = {1'b1, 4'd8};
            19'h06a03: total_zeros_lookup = {1'b1, 4'd9};
            19'h06a02: total_zeros_lookup = {1'b1, 4'd10};
            19'h06c01: total_zeros_lookup = {1'b1, 4'd11};
            19'h06a01: total_zeros_lookup = {1'b1, 4'd12};
            19'h06c00: total_zeros_lookup = {1'b1, 4'd13};
            19'h08a03: total_zeros_lookup = {1'b1, 4'd0};
            19'h08607: total_zeros_lookup = {1'b1, 4'd1};
            19'h08805: total_zeros_lookup = {1'b1, 4'd2};
            19'h08804: total_zeros_lookup = {1'b1, 4'd3};
            19'h08606: total_zeros_lookup = {1'b1, 4'd4};
            19'h08605: total_zeros_lookup = {1'b1, 4'd5};
            19'h08604: total_zeros_lookup = {1'b1, 4'd6};
            19'h08803: total_zeros_lookup = {1'b1, 4'd7};
            19'h08603: total_zeros_lookup = {1'b1, 4'd8};
            19'h08802: total_zeros_lookup = {1'b1, 4'd9};
            19'h08a02: total_zeros_lookup = {1'b1, 4'd10};
            19'h08a01: total_zeros_lookup = {1'b1, 4'd11};
            19'h08a00: total_zeros_lookup = {1'b1, 4'd12};
            19'h0a805: total_zeros_lookup = {1'b1, 4'd0};
            19'h0a804: total_zeros_lookup = {1'b1, 4'd1};
            19'h0a803: total_zeros_lookup = {1'b1, 4'd2};
            19'h0a607: total_zeros_lookup = {1'b1, 4'd3};
            19'h0a606: total_zeros_lookup = {1'b1, 4'd4};
            19'h0a605: total_zeros_lookup = {1'b1, 4'd5};
            19'h0a604: total_zeros_lookup = {1'b1, 4'd6};
            19'h0a603: total_zeros_lookup = {1'b1, 4'd7};
            19'h0a802: total_zeros_lookup = {1'b1, 4'd8};
            19'h0aa01: total_zeros_lookup = {1'b1, 4'd9};
            19'h0a801: total_zeros_lookup = {1'b1, 4'd10};
            19'h0aa00: total_zeros_lookup = {1'b1, 4'd11};
            19'h0cc01: total_zeros_lookup = {1'b1, 4'd0};
            19'h0ca01: total_zeros_lookup = {1'b1, 4'd1};
            19'h0c607: total_zeros_lookup = {1'b1, 4'd2};
            19'h0c606: total_zeros_lookup = {1'b1, 4'd3};
            19'h0c605: total_zeros_lookup = {1'b1, 4'd4};
            19'h0c604: total_zeros_lookup = {1'b1, 4'd5};
            19'h0c603: total_zeros_lookup = {1'b1, 4'd6};
            19'h0c602: total_zeros_lookup = {1'b1, 4'd7};
            19'h0c801: total_zeros_lookup = {1'b1, 4'd8};
            19'h0c601: total_zeros_lookup = {1'b1, 4'd9};
            19'h0cc00: total_zeros_lookup = {1'b1, 4'd10};
            19'h0ec01: total_zeros_lookup = {1'b1, 4'd0};
            19'h0ea01: total_zeros_lookup = {1'b1, 4'd1};
            19'h0e605: total_zeros_lookup = {1'b1, 4'd2};
            19'h0e604: total_zeros_lookup = {1'b1, 4'd3};
            19'h0e603: total_zeros_lookup = {1'b1, 4'd4};
            19'h0e403: total_zeros_lookup = {1'b1, 4'd5};
            19'h0e602: total_zeros_lookup = {1'b1, 4'd6};
            19'h0e801: total_zeros_lookup = {1'b1, 4'd7};
            19'h0e601: total_zeros_lookup = {1'b1, 4'd8};
            19'h0ec00: total_zeros_lookup = {1'b1, 4'd9};
            19'h10c01: total_zeros_lookup = {1'b1, 4'd0};
            19'h10801: total_zeros_lookup = {1'b1, 4'd1};
            19'h10a01: total_zeros_lookup = {1'b1, 4'd2};
            19'h10603: total_zeros_lookup = {1'b1, 4'd3};
            19'h10403: total_zeros_lookup = {1'b1, 4'd4};
            19'h10402: total_zeros_lookup = {1'b1, 4'd5};
            19'h10602: total_zeros_lookup = {1'b1, 4'd6};
            19'h10601: total_zeros_lookup = {1'b1, 4'd7};
            19'h10c00: total_zeros_lookup = {1'b1, 4'd8};
            19'h12c01: total_zeros_lookup = {1'b1, 4'd0};
            19'h12c00: total_zeros_lookup = {1'b1, 4'd1};
            19'h12801: total_zeros_lookup = {1'b1, 4'd2};
            19'h12403: total_zeros_lookup = {1'b1, 4'd3};
            19'h12402: total_zeros_lookup = {1'b1, 4'd4};
            19'h12601: total_zeros_lookup = {1'b1, 4'd5};
            19'h12401: total_zeros_lookup = {1'b1, 4'd6};
            19'h12a01: total_zeros_lookup = {1'b1, 4'd7};
            19'h14a01: total_zeros_lookup = {1'b1, 4'd0};
            19'h14a00: total_zeros_lookup = {1'b1, 4'd1};
            19'h14601: total_zeros_lookup = {1'b1, 4'd2};
            19'h14403: total_zeros_lookup = {1'b1, 4'd3};
            19'h14402: total_zeros_lookup = {1'b1, 4'd4};
            19'h14401: total_zeros_lookup = {1'b1, 4'd5};
            19'h14801: total_zeros_lookup = {1'b1, 4'd6};
            19'h16800: total_zeros_lookup = {1'b1, 4'd0};
            19'h16801: total_zeros_lookup = {1'b1, 4'd1};
            19'h16601: total_zeros_lookup = {1'b1, 4'd2};
            19'h16602: total_zeros_lookup = {1'b1, 4'd3};
            19'h16201: total_zeros_lookup = {1'b1, 4'd4};
            19'h16603: total_zeros_lookup = {1'b1, 4'd5};
            19'h18800: total_zeros_lookup = {1'b1, 4'd0};
            19'h18801: total_zeros_lookup = {1'b1, 4'd1};
            19'h18401: total_zeros_lookup = {1'b1, 4'd2};
            19'h18201: total_zeros_lookup = {1'b1, 4'd3};
            19'h18601: total_zeros_lookup = {1'b1, 4'd4};
            19'h1a600: total_zeros_lookup = {1'b1, 4'd0};
            19'h1a601: total_zeros_lookup = {1'b1, 4'd1};
            19'h1a201: total_zeros_lookup = {1'b1, 4'd2};
            19'h1a401: total_zeros_lookup = {1'b1, 4'd3};
            19'h1c400: total_zeros_lookup = {1'b1, 4'd0};
            19'h1c401: total_zeros_lookup = {1'b1, 4'd1};
            19'h1c201: total_zeros_lookup = {1'b1, 4'd2};
            19'h1e200: total_zeros_lookup = {1'b1, 4'd0};
            19'h1e201: total_zeros_lookup = {1'b1, 4'd1};
            19'h42201: total_zeros_lookup = {1'b1, 4'd0};
            19'h42401: total_zeros_lookup = {1'b1, 4'd1};
            19'h42601: total_zeros_lookup = {1'b1, 4'd2};
            19'h42600: total_zeros_lookup = {1'b1, 4'd3};
            19'h44201: total_zeros_lookup = {1'b1, 4'd0};
            19'h44401: total_zeros_lookup = {1'b1, 4'd1};
            19'h44400: total_zeros_lookup = {1'b1, 4'd2};
            19'h46201: total_zeros_lookup = {1'b1, 4'd0};
            19'h46200: total_zeros_lookup = {1'b1, 4'd1};
            default: total_zeros_lookup = 5'd0;
            endcase
        end
    endfunction

    function automatic [4:0] run_before_lookup(input [3:0] zeros, input [3:0] len, input [4:0] bits);
        reg [3:0] row;
        begin
            row = (zeros < 4'd7) ? zeros : 4'd7;
            run_before_lookup = 5'd0;
            case ({row, len, bits})
            13'h0221: run_before_lookup = {1'b1, 4'd0};
            13'h0220: run_before_lookup = {1'b1, 4'd1};
            13'h0421: run_before_lookup = {1'b1, 4'd0};
            13'h0441: run_before_lookup = {1'b1, 4'd1};
            13'h0440: run_before_lookup = {1'b1, 4'd2};
            13'h0643: run_before_lookup = {1'b1, 4'd0};
            13'h0642: run_before_lookup = {1'b1, 4'd1};
            13'h0641: run_before_lookup = {1'b1, 4'd2};
            13'h0640: run_before_lookup = {1'b1, 4'd3};
            13'h0843: run_before_lookup = {1'b1, 4'd0};
            13'h0842: run_before_lookup = {1'b1, 4'd1};
            13'h0841: run_before_lookup = {1'b1, 4'd2};
            13'h0861: run_before_lookup = {1'b1, 4'd3};
            13'h0860: run_before_lookup = {1'b1, 4'd4};
            13'h0a43: run_before_lookup = {1'b1, 4'd0};
            13'h0a42: run_before_lookup = {1'b1, 4'd1};
            13'h0a63: run_before_lookup = {1'b1, 4'd2};
            13'h0a62: run_before_lookup = {1'b1, 4'd3};
            13'h0a61: run_before_lookup = {1'b1, 4'd4};
            13'h0a60: run_before_lookup = {1'b1, 4'd5};
            13'h0c43: run_before_lookup = {1'b1, 4'd0};
            13'h0c60: run_before_lookup = {1'b1, 4'd1};
            13'h0c61: run_before_lookup = {1'b1, 4'd2};
            13'h0c63: run_before_lookup = {1'b1, 4'd3};
            13'h0c62: run_before_lookup = {1'b1, 4'd4};
            13'h0c65: run_before_lookup = {1'b1, 4'd5};
            13'h0c64: run_before_lookup = {1'b1, 4'd6};
            13'h0e67: run_before_lookup = {1'b1, 4'd0};
            13'h0e66: run_before_lookup = {1'b1, 4'd1};
            13'h0e65: run_before_lookup = {1'b1, 4'd2};
            13'h0e64: run_before_lookup = {1'b1, 4'd3};
            13'h0e63: run_before_lookup = {1'b1, 4'd4};
            13'h0e62: run_before_lookup = {1'b1, 4'd5};
            13'h0e61: run_before_lookup = {1'b1, 4'd6};
            13'h0e81: run_before_lookup = {1'b1, 4'd7};
            13'h0ea1: run_before_lookup = {1'b1, 4'd8};
            13'h0ec1: run_before_lookup = {1'b1, 4'd9};
            13'h0ee1: run_before_lookup = {1'b1, 4'd10};
            13'h0f01: run_before_lookup = {1'b1, 4'd11};
            13'h0f21: run_before_lookup = {1'b1, 4'd12};
            13'h0f41: run_before_lookup = {1'b1, 4'd13};
            13'h0f61: run_before_lookup = {1'b1, 4'd14};
            default: run_before_lookup = 5'd0;
            endcase
        end
    endfunction

    function automatic signed [15:0] level_from_code(input [31:0] code_in);
        reg signed [15:0] mask;
        reg signed [15:0] t;
        reg [31:0] half;
        begin
            mask = code_in[0] ? -16'sd1 : 16'sd0;
            half = (code_in + 32'd2) >> 1;
            t = $signed(half[15:0]);
            level_from_code = (t ^ mask) - mask;
        end
    endfunction

    function automatic [3:0] idx4(input [4:0] v);
        begin
            idx4 = v[3:0];
        end
    endfunction

    function automatic [15:0] level_mag(input signed [15:0] lvl);
        begin
            level_mag = lvl[15] ? (~lvl[15:0] + 16'd1) : lvl[15:0];
        end
    endfunction

    // 9.2.2.1 first non-T1: force suffixLength>=1, then +1 if |level|>3.
    // Must use magnitude — signed tests miss level<=-4 and desync the slice.
    // (717330a unsigned (level+3)>6u is equivalent: |level|>=4.)
    function automatic [2:0] suffix_next_first(input signed [15:0] lvl);
        begin
            suffix_next_first = (level_mag(lvl) > 16'd3) ? 3'd2 : 3'd1;
        end
    endfunction

    function automatic [2:0] suffix_next(input [2:0] cur_suf, input signed [15:0] lvl);
        reg [15:0] lim;
        begin
            case (cur_suf)
            3'd0: lim = 16'd0;
            3'd1: lim = 16'd3;
            3'd2: lim = 16'd6;
            3'd3: lim = 16'd12;
            3'd4: lim = 16'd24;
            default: lim = 16'd48;
            endcase
            suffix_next = cur_suf;
            if (cur_suf < 3'd6 && level_mag(lvl) > lim)
                suffix_next = cur_suf + 3'd1;
        end
    endfunction

    task automatic clear_arrays;
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1) begin
                coeff[i] <= 16'sd0;
                level_dbg[i] <= 16'sd0;
                run_dbg[i] <= 4'd0;
            end
        end
    endtask

    always @(posedge clk) begin
        reg [7:0] tok;
        reg [4:0] zlk;
        reg [4:0] rlk;
        reg signed [15:0] lvl_tmp;
        reg signed [5:0] next_coeff_num;
        reg level_bad;
        integer ci;

        done <= 1'b0;
        if (reset) begin
            st <= ST_IDLE;
            busy <= 1'b0;
            ok <= 1'b0;
            done <= 1'b0;
            bit_pos <= 10'd0;
            bit_offset_end <= 10'd0;
            total_coeff <= 5'd0;
            trailing_ones <= 2'd0;
            total_zeros <= 4'd0;
            clear_arrays();
        end else begin
            case (st)
            ST_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    ok <= 1'b0;
                    bit_pos <= bit_offset_start;
                    bit_offset_end <= bit_offset_start;
                    code <= 16'd0;
                    code_len <= 5'd0;
                    total_coeff <= 5'd0;
                    trailing_ones <= 2'd0;
                    total_zeros <= 4'd0;
                    tc_r <= 5'd0;
                    t1_r <= 2'd0;
                    idx <= 5'd0;
                    clear_arrays();
                    st <= ST_TOKEN_BIT;
                end
            end

            ST_TOKEN_BIT: begin
                if (bit_pos >= bit_len) st <= ST_FAIL;
                else begin
                    code <= {code[14:0], cur_bit};
                    code_len <= code_len + 5'd1;
                    bit_pos <= bit_pos + 10'd1;
                    st <= ST_TOKEN_CHK;
                end
            end

            ST_TOKEN_CHK: begin
                tok = coeff_token_lookup(coeff_token_table, code_len, code);
                if (tok[7]) begin
                    tc_r <= tok[6:2];
                    t1_r <= tok[1:0];
                    total_coeff <= tok[6:2];
                    trailing_ones <= tok[1:0];
                    if (tok[6:2] > max_coeff || {3'd0, tok[1:0]} > tok[6:2])
                        st <= ST_FAIL;
                    else if (tok[6:2] == 5'd0) begin
                        ok <= 1'b1;
                        bit_offset_end <= bit_pos;
                        st <= ST_DONE;
                    end else begin
                        idx <= 5'd0;
                        if (tok[1:0] != 2'd0) st <= ST_SIGN;
                        else begin
                            suffix_length <= (tok[6:2] > 5'd10) ? 3'd1 : 3'd0;
                            first_non_t1 <= 1'b1;
                            idx <= 5'd0;
                            prefix <= 6'd0;
                            st <= ST_LVL_PRE;
                        end
                    end
                end else if (token_too_long) st <= ST_FAIL;
                else st <= ST_TOKEN_BIT;
            end

            ST_SIGN: begin
                if (bit_pos >= bit_len) st <= ST_FAIL;
                else begin
                    level_dbg[idx[3:0]] <= cur_bit ? -16'sd1 : 16'sd1;
                    bit_pos <= bit_pos + 10'd1;
                    if (idx + 5'd1 >= {3'd0, t1_r}) begin
                        idx <= {3'd0, t1_r};
                        if (tc_r == {3'd0, t1_r}) begin
                            code <= 16'd0; code_len <= 5'd0; st <= ST_TZ_BIT;
                        end else begin
                            suffix_length <= (tc_r > 5'd10 && t1_r < 2'd3) ? 3'd1 : 3'd0;
                            first_non_t1 <= 1'b1;
                            prefix <= 6'd0;
                            st <= ST_LVL_PRE;
                        end
                    end else idx <= idx + 5'd1;
                end
            end

            ST_LVL_PRE: begin
                if (bit_pos >= bit_len) st <= ST_FAIL;
                else begin
                    bit_pos <= bit_pos + 10'd1;
                    if (cur_bit == 1'b0) begin
                        prefix <= prefix + 6'd1;
                        if (prefix >= 6'd31) st <= ST_FAIL;
                    end else begin
                        suffix_acc <= 32'd0;
                        if (first_non_t1) begin
                            if (prefix < 6'd14) suffix_left <= {2'd0, suffix_length};
                            else if (prefix == 6'd14) suffix_left <= (suffix_length != 0) ? {2'd0, suffix_length} : 5'd4;
                            else suffix_left <= prefix[4:0] - 5'd3;
                        end else begin
                            if (prefix == 6'd14 && suffix_length == 3'd0) suffix_left <= 5'd4;
                            else if (prefix < 6'd15) suffix_left <= {2'd0, suffix_length};
                            else suffix_left <= prefix[4:0] - 5'd3;
                        end
                        st <= ST_LVL_SUF;
                    end
                end
            end

            ST_LVL_SUF: begin
                if (suffix_left == 5'd0) begin
                    st <= ST_LVL_STORE;
                end else if (bit_pos >= bit_len) st <= ST_FAIL;
                else begin
                    suffix_acc <= {suffix_acc[30:0], cur_bit};
                    suffix_left <= suffix_left - 5'd1;
                    bit_pos <= bit_pos + 10'd1;
                end
            end

            ST_LVL_STORE: begin
                level_bad = 1'b0;
                if (first_non_t1) begin
                    if (prefix < 6'd14) begin
                        level_code = ({26'd0, prefix} << suffix_length) + suffix_acc;
                    end else if (prefix == 6'd14) begin
                        if (suffix_length != 0) level_code = (32'd14 << suffix_length) + suffix_acc;
                        else level_code = 32'd14 + suffix_acc;
                    end else begin
                        level_code = (32'd15 << suffix_length) +
                                     ((suffix_length == 3'd0) ? 32'd15 : 32'd0);
                        if (prefix >= 6'd16) level_code = level_code + (32'd1 << (prefix - 6'd3)) - 32'd4096;
                        level_code = level_code + suffix_acc;
                    end
                    if (t1_r < 2'd3) level_code = level_code + 32'd2;
                    level_bad = (idx >= 5'd16 || level_code > 32'd65535);
                    if (!level_bad) begin
                        lvl_tmp = level_from_code(level_code);
                        level_dbg[idx[3:0]] <= lvl_tmp;
                        suffix_length <= suffix_next_first(lvl_tmp);
                        first_non_t1 <= 1'b0;
                    end
                end else begin
                    if (prefix < 6'd15) begin
                        level_code = ({26'd0, prefix} << suffix_length) + suffix_acc;
                    end else begin
                        level_code = (32'd15 << suffix_length) +
                                     ((suffix_length == 3'd0) ? 32'd15 : 32'd0);
                        if (prefix >= 6'd16) level_code = level_code + (32'd1 << (prefix - 6'd3)) - 32'd4096;
                        level_code = level_code + suffix_acc;
                    end
                    level_bad = (idx >= 5'd16 || level_code > 32'd65535);
                    if (!level_bad) begin
                        lvl_tmp = level_from_code(level_code);
                        level_dbg[idx[3:0]] <= lvl_tmp;
                        suffix_length <= suffix_next(suffix_length, lvl_tmp);
                    end
                end
                if (level_bad) begin
                    st <= ST_FAIL;
                end else if (idx + 5'd1 >= tc_r) begin
                    code <= 16'd0; code_len <= 5'd0; st <= ST_TZ_BIT;
                end else begin
                    idx <= idx + 5'd1;
                    prefix <= 6'd0;
                    suffix_acc <= 32'd0;
                    st <= ST_LVL_PRE;
                end
            end

            ST_TZ_BIT: begin
                if (tc_r >= max_coeff) begin
                    total_zeros <= 4'd0;
                    zeros_left <= 4'd0;
                    idx <= 5'd0;
                    st <= ST_PLACE_INIT;
                end else if (bit_pos >= bit_len) st <= ST_FAIL;
                else begin
                    code <= {code[14:0], cur_bit};
                    code_len <= code_len + 5'd1;
                    bit_pos <= bit_pos + 10'd1;
                    st <= ST_TZ_CHK;
                end
            end

            ST_TZ_CHK: begin
                zlk = total_zeros_lookup(tz_is_chroma, tc_r, code_len[3:0], code[8:0]);
                if (zlk[4]) begin
                    total_zeros <= zlk[3:0];
                    zeros_left <= zlk[3:0];
                    idx <= 5'd0;
                    code <= 16'd0; code_len <= 5'd0;
                    if (tc_r <= 5'd1 || zlk[3:0] == 4'd0) begin
                        run_dbg[idx4(tc_r - 5'd1)] <= zlk[3:0];
                        st <= ST_PLACE_INIT;
                    end else st <= ST_RUN_BIT;
                end else if (code_len >= (tz_is_chroma ? 5'd3 : 5'd9)) st <= ST_FAIL;
                else st <= ST_TZ_BIT;
            end

            ST_RUN_BIT: begin
                if (idx >= tc_r - 5'd1 || zeros_left == 4'd0) begin
                    run_dbg[idx4(tc_r - 5'd1)] <= zeros_left;
                    st <= ST_PLACE_INIT;
                end else if (bit_pos >= bit_len) st <= ST_FAIL;
                else begin
                    code <= {code[14:0], cur_bit};
                    code_len <= code_len + 5'd1;
                    bit_pos <= bit_pos + 10'd1;
                    st <= ST_RUN_CHK;
                end
            end

            ST_RUN_CHK: begin
                rlk = run_before_lookup(zeros_left, code_len[3:0], code[4:0]);
                if (rlk[4]) begin
                    if (rlk[3:0] > zeros_left) st <= ST_FAIL;
                    else begin
                        run_dbg[idx[3:0]] <= rlk[3:0];
                        zeros_left <= zeros_left - rlk[3:0];
                        code <= 16'd0; code_len <= 5'd0;
                        if (idx + 5'd1 >= tc_r - 5'd1 || (zeros_left - rlk[3:0]) == 4'd0) begin
                            run_dbg[idx4(tc_r - 5'd1)] <= zeros_left - rlk[3:0];
                            st <= ST_PLACE_INIT;
                        end else begin
                            idx <= idx + 5'd1;
                            st <= ST_RUN_BIT;
                        end
                    end
                end else if (code_len >= ((zeros_left < 4'd7) ? 5'd3 : 5'd11)) st <= ST_FAIL;
                else st <= ST_RUN_BIT;
            end

            ST_PLACE_INIT: begin
                for (ci = 0; ci < 16; ci = ci + 1)
                    coeff[ci] <= 16'sd0;
                coeff_num <= -6'sd1;
                place_i <= tc_r;
                st <= ST_PLACE_STEP;
            end

            ST_PLACE_STEP: begin
                if (place_i == 5'd0) begin
                    ok <= 1'b1;
                    bit_offset_end <= bit_pos;
                    st <= ST_DONE;
                end else begin
                    place_i <= place_i - 5'd1;
                    next_coeff_num = coeff_num + {2'd0, run_dbg[idx4(place_i - 5'd1)]} + 6'sd1;
                    coeff_num <= next_coeff_num;
                    // max_coeff=15 (Intra16x16ACLevel / ChromaACLevel): positions 0..14 only.
                    // Placing into 0..15 as if 16-coeff desyncs the next block's bit pointer.
                    if (next_coeff_num < $signed({1'b0, max_coeff}))
                        coeff[next_coeff_num[3:0]] <= level_dbg[idx4(place_i - 5'd1)];
                    else st <= ST_FAIL;
                end
            end

            ST_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                st <= ST_IDLE;
            end

            default: begin
                busy <= 1'b0;
                ok <= 1'b0;
                bit_offset_end <= bit_pos;
                done <= 1'b1;
                st <= ST_IDLE;
            end
            endcase
        end
    end
endmodule
