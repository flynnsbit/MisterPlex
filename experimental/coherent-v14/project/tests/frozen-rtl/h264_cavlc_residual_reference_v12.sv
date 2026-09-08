// H.264 Baseline CAVLC residual block decoder building blocks.
// Sequential bit/table decoder; outputs coefficients in CAVLC scan order for h264_dequant4x4.

module h264_cavlc_nc_predictor_reference (
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
    assign nC = (nA_available && nB_available) ? (({1'b0, left_tc} + {1'b0, up_tc} + 6'd1) >> 1) :
                nA_available ? left_tc :
                nB_available ? up_tc : 5'd0;
    assign coeff_token_table = (nC < 5'd2) ? 3'd0 :
                               (nC < 5'd4) ? 3'd1 :
                               (nC < 5'd8) ? 3'd2 : 3'd3;
endmodule

module h264_cavlc_residual_block_reference #(
    parameter int MAX_BYTES = 64,
    parameter int BIT_W = $clog2(MAX_BYTES * 8 + 1),
`ifdef CAVLC_LEVEL_LANES
    parameter int LEVEL_LANES = `CAVLC_LEVEL_LANES
`else
    parameter int LEVEL_LANES = 3
`endif
)(
    input  wire               clk,
    input  wire               reset,
    input  wire               start,
    input  wire [2:0]         coeff_token_table, // 0:nC<2, 1:nC<4, 2:nC<8, 3:nC>=8, 4:chroma_dc
    input  wire [4:0]         max_coeff,         // 16 luma, 15 AC-only, 4 chroma DC
    input  wire [BIT_W-1:0]   bit_offset_start,
    input  wire [BIT_W-1:0]   bit_len,
    input  wire [7:0]         rbsp [0:MAX_BYTES-1],
    output reg                busy,
    output reg                done,
    output reg                ok,
    output reg [BIT_W-1:0]    bit_offset_end,
    output reg [4:0]          total_coeff,
    output reg [1:0]          trailing_ones,
    output reg [3:0]          total_zeros,
    output reg signed [15:0]  coeff [0:15],
    output reg signed [15:0]  level_dbg [0:15],
    output reg [3:0]          run_dbg [0:15]
`ifdef CAVLC_CYCLE_PROBE
    ,
    // Measurement-only stage cycle counters (cleared on start, freeze at done).
    output reg [15:0]         cy_token,      // ST_TOKEN_BIT + ST_TOKEN_CHK
    output reg [15:0]         cy_sign,       // ST_SIGN (trailing ones)
    output reg [15:0]         cy_level,      // ST_LVL_PRE + ST_LVL_SUF + ST_LVL_STORE
    output reg [15:0]         cy_total_zeros,// ST_TZ_BIT + ST_TZ_CHK
    output reg [15:0]         cy_run_before, // ST_RUN_BIT + ST_RUN_CHK
    output reg [15:0]         cy_place,      // ST_PLACE_INIT + ST_PLACE_STEP
    output reg [15:0]         cy_other,      // IDLE sample edge / DONE / FAIL overhead in block
    output reg [15:0]         cy_total       // all cycles while busy (start accept .. done pulse)
`endif
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
        ST_FAIL       = 5'd14,
        ST_WIN_SELECT = 5'd15,
        ST_WIN_ALIGN  = 5'd16,
        ST_LVL_CHECK  = 5'd17;

    reg [4:0] st;
    reg [BIT_W:0] bit_pos;
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

    // One shared word-select network replaces independent arbitrary-bit reads
    // for every bit of every speculative level/run window. Three <=32-bit
    // levels need at most 96 bits; aligning within an 8-byte word needs 160.
    localparam int WINDOW_ROWS = (MAX_BYTES + 7) / 8;
    wire [BIT_W:0] live_available_bits =
        (bit_pos < {1'b0, bit_len}) ? ({1'b0, bit_len} - bit_pos) : '0;
    reg [159:0] window_words_q;
    reg [5:0] window_shift_q;
    reg [BIT_W:0] available_bits, window_position;
    reg [95:0] stream_window;
    reg [4:0] window_resume;
    reg window_valid;
    wire window_consuming = st==ST_TOKEN_BIT || st==ST_SIGN || st==ST_LVL_PRE ||
        st==ST_LVL_SUF || st==ST_TZ_BIT || st==ST_RUN_BIT;

    function automatic [159:0] select_window_words(input [BIT_W:0] position);
        integer row, lane;
        begin
            select_window_words = 160'd0;
            for (row = 0; row < WINDOW_ROWS; row = row + 1) begin
                for (lane = 0; lane < 20; lane = lane + 1) begin
                    if (row * 8 + lane < MAX_BYTES)
                        select_window_words[159 - lane * 8 -: 8] =
                            select_window_words[159 - lane * 8 -: 8] |
                            (rbsp[row * 8 + lane] &
                             {8{(position >> 6) == (BIT_W+1)'(row)}});
                end
            end
        end
    endfunction

    function automatic [95:0] align_window(
        input [159:0] words, input [5:0] shift, input [BIT_W:0] available);
        reg [159:0] aligned;
        integer b;
        begin
            aligned = words << shift;
            for (b=0;b<96;b=b+1)
                align_window[95-b] = available>b ? aligned[159-b] : 1'b0;
        end
    endfunction

    task automatic read_window(input [4:0] resume_state);
        begin
            window_resume <= resume_state;
            window_valid <= 1'b0;
            st <= ST_WIN_SELECT;
        end
    endtask

    function automatic [31:0] window32(input [6:0] offset);
        reg [95:0] shifted;
        begin
            shifted = stream_window << offset;
            window32 = shifted[95:64];
        end
    endfunction

    function automatic [1:0] clz4_nonzero(input [3:0] w);
        begin
            casez (w)
                4'b1???: clz4_nonzero = 2'd0;
                4'b01??: clz4_nonzero = 2'd1;
                4'b001?: clz4_nonzero = 2'd2;
                default: clz4_nonzero = 2'd3;
            endcase
        end
    endfunction

    function automatic [2:0] clz8_nonzero(input [7:0] w);
        clz8_nonzero = (|w[7:4]) ? {1'b0, clz4_nonzero(w[7:4])}
                                  : {1'b1, clz4_nonzero(w[3:0])};
    endfunction

    function automatic [3:0] clz16_nonzero(input [15:0] w);
        clz16_nonzero = (|w[15:8]) ? {1'b0, clz8_nonzero(w[15:8])}
                                    : {1'b1, clz8_nonzero(w[7:0])};
    endfunction

    // Balanced nibble/byte/halfword encoding, with an explicit all-zero sentinel.
    function automatic [5:0] clz32(input [31:0] w);
        clz32 = !(|w) ? 6'd32 :
                (|w[31:16]) ? {2'b00, clz16_nonzero(w[31:16])}
                              : {2'b01, clz16_nonzero(w[15:0])};
    endfunction

    // Extract n MSBs of window as integer (n in 1..32).
    function automatic [31:0] take_msb(input [31:0] w, input [5:0] n);
        begin
            if (n == 6'd0)
                take_msb = 32'd0;
            else if (n >= 6'd32)
                take_msb = w;
            else
                take_msb = w >> (6'd32 - n);
        end
    endfunction
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

    `include "h264_cavlc_fast_vlc.svh"

    function automatic signed [15:0] level_from_code(input [31:0] code_in);
        begin
            // -(floor(code/2)+1) is ~floor(code/2), including -32768.
            level_from_code = code_in[0] ? $signed(~code_in[16:1])
                                         : $signed(code_in[16:1] + 16'd1);
        end
    endfunction

    function automatic [3:0] idx4(input [4:0] v);
        begin
            idx4 = v[3:0];
        end
    endfunction

    // The first suffix length is 0 or 1. abs(level)>3 means levelCode>=6;
    // removing the first-level +2 correction gives prefix thresholds 4/2
    // (TrailingOnes<3) or 6/3. Escapes exceed either threshold.
    function automatic [2:0] suffix_next_first(
        input [5:0] pfx, input [2:0] cur_suf, input [1:0] t1);
        reg [5:0] threshold;
        begin
            threshold = (cur_suf == 0) ? ((t1 < 3) ? 6'd4 : 6'd6)
                                       : ((t1 < 3) ? 6'd2 : 6'd3);
            suffix_next_first = (pfx >= threshold) ? 3'd2 : 3'd1;
        end
    endfunction

    // For subsequent levels, levelCode=(prefix<<suffixLength)+suffix.
    // abs(level)>3<<(suffixLength-1) iff prefix>=3, including escapes.
    // Keep this feedback independent of signed coefficient conversion/range checks.
    function automatic [2:0] suffix_next(input [2:0] cur_suf, input [5:0] pfx);
        begin
            suffix_next = cur_suf;
            if (cur_suf < 3'd6 && (cur_suf == 0 || pfx >= 6'd3))
                suffix_next = cur_suf + 3'd1;
        end
    endfunction

    // Complete inline levels have at most 14 suffix bits. Align once at the
    // end of the codeword instead of cascading prefix-left and suffix-right shifts.
    function automatic [15:0] inline_suffix(
        input [31:0] w, input [5:0] consumed, input [4:0] suffix_bits);
        reg [31:0] shifted;
        begin
            shifted = w >> (6'd32 - consumed);
            inline_suffix = shifted[15:0] & (16'hFFFF >> (5'd16 - suffix_bits));
        end
    endfunction

    function automatic [15:0] decode_inline_level_code(
        input [5:0] pfx, input [2:0] sl, input [15:0] suffix,
        input first, input [1:0] t1);
        reg [11:0] base;
        reg [15:0] escape_bits;
        begin
            base = (pfx >= 6'd15 && sl == 0) ? 12'd30 :
                   ((pfx < 6'd15 ? {8'd0, pfx[3:0]} : 12'd15) << sl);
            if (first && t1 < 2'd3) base = base + 12'd2;
            // Only prefixes 16/17 escape within 32 bits. Their offsets occupy
            // bits 12/13, disjoint from base (<1923), so no offset adder is needed.
            escape_bits = (pfx == 6'd16) ? 16'h1000 :
                          (pfx == 6'd17) ? 16'h3000 : 16'd0;
            decode_inline_level_code = ({4'd0, base} | escape_bits) + suffix;
        end
    endfunction

    function automatic level_fits(input [31:0] lc);
        // +32768 is not representable; -32768 (code 65535) is.
        level_fits = lc <= 32'd65535 && lc != 32'd65534;
    endfunction

    function automatic [31:0] long_level_code(
        input [5:0] pfx, input [2:0] sl, input [31:0] suffix,
        input first, input [1:0] t1);
        reg [31:0] base;
        begin
            base = ({26'd0, pfx < 15 ? pfx : 6'd15} << sl);
            if (pfx>=15 && sl==0) base = base + 32'd15;
            if (pfx>=16) base = base + (32'd1 << (pfx-6'd3)) - 32'd4096;
            long_level_code = base + suffix + ((first && t1<3) ? 32'd2 : 32'd0);
        end
    endfunction

    function automatic [15:0] level_write_data(
        input [4:0] dst, base_idx, input [2:0] valid,
        input [15:0] a, b, c);
        level_write_data =
            (a & {16{valid[0] && base_idx==dst}}) |
            (b & {16{LEVEL_LANES>=2 && valid[1] && dst>=1 && base_idx==dst-5'd1}}) |
            (c & {16{LEVEL_LANES>=3 && valid[2] && dst>=2 && base_idx==dst-5'd2}});
    endfunction

    // The cursor/suffix feedback does not depend on converted coefficients.
    // Retire that metadata immediately, then convert in parallel with the next
    // syntax operation. TZ always separates the final level from placement.
    reg [2:0] level_pipe_valid;
    reg [4:0] level_pipe_idx;
    reg level_pipe_first;
    reg [1:0] level_pipe_t1;
    reg [31:0] level_pipe_win [0:2];
    reg [5:0] level_pipe_prefix [0:2];
    reg [5:0] level_pipe_consumed [0:2];
    reg [4:0] level_pipe_suffix_bits [0:2];
    reg [2:0] level_pipe_suffix_length [0:2];
    wire signed [15:0] level_pipe_value [0:2];
    genvar level_lane;
    generate for (level_lane = 0; level_lane < 3; level_lane = level_lane + 1) begin : g_level_convert
        if (level_lane == 0 || LEVEL_LANES >= level_lane+1) begin: g_active
        wire [15:0] codeword = decode_inline_level_code(
            level_pipe_prefix[level_lane], level_pipe_suffix_length[level_lane],
            inline_suffix(level_pipe_win[level_lane], level_pipe_consumed[level_lane],
                          level_pipe_suffix_bits[level_lane]),
            level_lane == 0 && level_pipe_first, level_pipe_t1);
        assign level_pipe_value[level_lane] = level_from_code({16'd0, codeword});
        end else begin: g_inactive
            assign level_pipe_value[level_lane] = 16'sd0;
        end
    end endgenerate

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

    reg signed [15:0] placed_coeff [0:15];
    reg [3:0] place_index [0:15];
    reg [15:0] place_valid;
    reg place_bad;
    always @* begin : place_one_hot
        integer src, dst;
        reg signed [5:0] cnum;
        cnum = -6'sd1;
        place_valid = 16'd0;
        place_bad = 1'b0;
        for (src = 15; src >= 0; src = src - 1) begin
            place_index[src] = 4'd0;
            if (src < tc_r && !place_bad) begin
                cnum = cnum + {2'd0, run_dbg[src]} + 6'sd1;
                if (cnum >= 0 && cnum < $signed({1'b0, max_coeff})) begin
                    place_index[src] = cnum[3:0];
                    place_valid[src] = 1'b1;
                end else place_bad = 1'b1;
            end
        end
        // Nonnegative runs make all valid destinations distinct. Use an OR
        // selection, not sixteen ordered variable-index writes per output.
        for (dst = 0; dst < 16; dst = dst + 1) begin
            placed_coeff[dst] = 16'sd0;
            for (src = 0; src < 16; src = src + 1)
                placed_coeff[dst] = placed_coeff[dst] |
                    (level_dbg[src] &
                     {16{place_valid[src] && place_index[src] == 4'(dst)}});
        end
    end

    always @(posedge clk) begin
        reg [7:0] tok;
        reg [4:0] zlk;
        reg [4:0] rlk;
        reg signed [15:0] lvl_tmp;
        reg signed [5:0] next_coeff_num;
        reg level_bad;
        integer ci;

        done <= 1'b0;
        level_pipe_valid <= 3'd0;
        if (reset) begin
            st <= ST_IDLE;
            busy <= 1'b0;
            ok <= 1'b0;
            done <= 1'b0;
            bit_pos <= 10'd0;
            bit_offset_end <= 10'd0;
            window_valid <= 1'b0;
            total_coeff <= 5'd0;
            trailing_ones <= 2'd0;
            total_zeros <= 4'd0;
            clear_arrays();
`ifdef CAVLC_CYCLE_PROBE
            cy_token <= 16'd0;
            cy_sign <= 16'd0;
            cy_level <= 16'd0;
            cy_total_zeros <= 16'd0;
            cy_run_before <= 16'd0;
            cy_place <= 16'd0;
            cy_other <= 16'd0;
            cy_total <= 16'd0;
`endif
        end else begin
            for (ci = 0; ci < 16; ci = ci + 1) begin
                if ((level_pipe_valid[0] && level_pipe_idx == 5'(ci)) ||
                    (LEVEL_LANES >= 2 && level_pipe_valid[1] && ci >= 1 && level_pipe_idx == 5'(ci-1)) ||
                    (LEVEL_LANES >= 3 && level_pipe_valid[2] && ci >= 2 && level_pipe_idx == 5'(ci-2)))
                    level_dbg[ci] <= level_write_data(5'(ci), level_pipe_idx, level_pipe_valid,
                        level_pipe_value[0], level_pipe_value[1], level_pipe_value[2]);
            end
`ifdef CAVLC_CYCLE_PROBE
            // Count this cycle's state before transitions (busy window).
            if (busy || start) begin
                cy_total <= cy_total + 16'd1;
                case (st)
                ST_TOKEN_BIT, ST_TOKEN_CHK: cy_token <= cy_token + 16'd1;
                ST_SIGN:                    cy_sign <= cy_sign + 16'd1;
                ST_LVL_PRE, ST_LVL_SUF, ST_LVL_STORE, ST_LVL_CHECK: cy_level <= cy_level + 16'd1;
                ST_TZ_BIT, ST_TZ_CHK:       cy_total_zeros <= cy_total_zeros + 16'd1;
                ST_RUN_BIT, ST_RUN_CHK:     cy_run_before <= cy_run_before + 16'd1;
                ST_PLACE_INIT, ST_PLACE_STEP: cy_place <= cy_place + 16'd1;
                default:                    cy_other <= cy_other + 16'd1;
                endcase
            end
`endif
            case (st)
            ST_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    window_valid <= 1'b0;
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
`ifdef CAVLC_CYCLE_PROBE
                    cy_token <= 16'd0;
                    cy_sign <= 16'd0;
                    cy_level <= 16'd0;
                    cy_total_zeros <= 16'd0;
                    cy_run_before <= 16'd0;
                    cy_place <= 16'd0;
                    cy_other <= 16'd0;
                    cy_total <= 16'd0;
`endif
                    if (bit_len > MAX_BYTES * 8 || bit_offset_start >= bit_len ||
                        !(max_coeff == 5'd4 || max_coeff == 5'd15 || max_coeff == 5'd16) ||
                        coeff_token_table > 3'd4 ||
                        ((coeff_token_table == 3'd4) != (max_coeff == 5'd4)))
                        st <= ST_FAIL;
                    else read_window(ST_TOKEN_BIT);
                end
            end

            ST_WIN_SELECT: begin
                window_words_q <= select_window_words(bit_pos);
                window_shift_q <= 6'(bit_pos);
                available_bits <= live_available_bits;
                window_position <= bit_pos;
                st <= ST_WIN_ALIGN;
            end
            ST_WIN_ALIGN: begin
                stream_window <= align_window(window_words_q, window_shift_q, available_bits);
                window_valid <= 1'b1;
                st <= window_resume;
            end

            // Parallel prefix-free token: try lengths 1..max in one cycle.
            ST_TOKEN_BIT: begin
                if (available_bits == 0) st <= ST_FAIL;
                else begin : g_tok_par
                    reg [31:0] twin;
                    reg [4:0] blen;
                    reg [7:0] tbest;
                    reg [12:0] decoded_token;
                    reg found_t;
                    twin = window32(7'd0);
                    decoded_token = fast_token(coeff_token_table, twin[31:16]);
                    tbest = decoded_token[12:5];
                    blen = decoded_token[4:0];
                    found_t = decoded_token[12] && available_bits >= blen;
                    if (!found_t) st <= ST_FAIL;
                    else begin
                        bit_pos <= bit_pos + {5'd0, blen};
                        tc_r <= tbest[6:2];
                        t1_r <= tbest[1:0];
                        total_coeff <= tbest[6:2];
                        trailing_ones <= tbest[1:0];
                        if (tbest[6:2] > max_coeff || {3'd0, tbest[1:0]} > tbest[6:2])
                            st <= ST_FAIL;
                        else if (tbest[6:2] == 5'd0) begin
                            ok <= 1'b1;
                            bit_offset_end <= bit_pos + {5'd0, blen};
                            st <= ST_DONE;
                        end else begin
                            idx <= 5'd0;
                            if (tbest[1:0] != 2'd0) read_window(ST_SIGN);
                            else begin
                                suffix_length <= (tbest[6:2] > 5'd10) ? 3'd1 : 3'd0;
                                first_non_t1 <= 1'b1;
                                prefix <= 6'd0;
                                read_window(ST_LVL_PRE);
                            end
                        end
                    end
                end
            end

            ST_TOKEN_CHK: st <= ST_FAIL;

            // All trailing-one signs in one cycle (t1 ≤ 3).
            ST_SIGN: begin
                if ({8'd0, t1_r} > available_bits) st <= ST_FAIL;
                else begin
                    // peek up to 3 sign bits
                    begin : g_signs
                        reg [31:0] sw;
                        sw = window32(7'd0);
                        if (t1_r >= 2'd1)
                            level_dbg[0] <= sw[31] ? -16'sd1 : 16'sd1;
                        if (t1_r >= 2'd2)
                            level_dbg[1] <= sw[30] ? -16'sd1 : 16'sd1;
                        if (t1_r >= 2'd3)
                            level_dbg[2] <= sw[29] ? -16'sd1 : 16'sd1;
                    end
                    bit_pos <= bit_pos + {8'd0, t1_r};
                    idx <= {3'd0, t1_r};
                    if (tc_r == {3'd0, t1_r}) begin
                        code <= 16'd0; code_len <= 5'd0; read_window(ST_TZ_BIT);
                    end else begin
                        suffix_length <= (tc_r > 5'd10 && t1_r < 2'd3) ? 3'd1 : 3'd0;
                        first_non_t1 <= 1'b1;
                        prefix <= 6'd0;
                        read_window(ST_LVL_PRE);
                    end
                end
            end

            // Up to three non-T1 levels per cached decode beat.
            ST_LVL_PRE: begin
                if (available_bits == 0) st <= ST_FAIL;
                else begin : g_lvl_tri
                    reg [31:0] win_a, win_b, win_c;
                    reg [5:0] pfx_a, pfx_b, pfx_c;
                    reg [BIT_W:0] avail_a, cons_a, cons_b, cons_c;
                    reg [4:0] sleft_a, sleft_b, sleft_c;
                    reg [2:0] sl_a, sl_b, sl_c, sl_cur;
                    reg do_b, do_c, bad_a, first_a;
                    reg [1:0] n_ok;

                    first_a = first_non_t1;
                    sl_cur = suffix_length;
                    win_a = window32(7'd0);
                    pfx_a = clz32(win_a);
                    avail_a = available_bits;
                    do_b = 1'b0;
                    do_c = 1'b0;
                    bad_a = 1'b1;
                    n_ok = 2'd0;

                    // Speculative addresses depend only on prefixes/suffix sizes.
                    // Coefficient range/EOF checks gate retirement, not lookahead.
                    if (pfx_a == 6'd14 && sl_cur == 0) sleft_a = 5'd4;
                    else if (pfx_a < 6'd15) sleft_a = {2'd0, sl_cur};
                    else sleft_a = pfx_a[4:0] - 5'd3;
                    cons_a = {4'd0, pfx_a} + 10'd1 + {5'd0, sleft_a};
                    sl_a = first_a ? suffix_next_first(pfx_a, sl_cur, t1_r)
                                   : suffix_next(sl_cur, pfx_a);
                    win_b=0; pfx_b=32; sleft_b=0; cons_b=0; sl_b=sl_a;
                    win_c=0; pfx_c=32; sleft_c=0; cons_c=0; sl_c=sl_a;
                    if (LEVEL_LANES >= 2) begin
                        win_b = window32(7'(cons_a));
                        pfx_b = clz32(win_b);
                        if (pfx_b < 6'd15) sleft_b = {2'd0, sl_a};
                        else sleft_b = pfx_b[4:0] - 5'd3;
                        cons_b = {4'd0, pfx_b} + 10'd1 + {5'd0, sleft_b};
                        sl_b = suffix_next(sl_a, pfx_b);
                        if (LEVEL_LANES >= 3) begin
                            win_c = window32(7'(cons_a + cons_b));
                            pfx_c = clz32(win_c);
                            if (pfx_c < 6'd15) sleft_c = {2'd0, sl_b};
                            else sleft_c = pfx_c[4:0] - 5'd3;
                            cons_c = {4'd0, pfx_c} + 10'd1 + {5'd0, sleft_c};
                            sl_c = suffix_next(sl_b, pfx_c);
                        end
                    end

                    if (pfx_a >= 6'd32 || {6'd0, pfx_a} >= {2'd0, avail_a} || pfx_a > 6'd31) begin
                        st <= ST_FAIL;
                    end else begin
                        if (cons_a > avail_a) begin
                            st <= ST_FAIL;
                        end else if (({1'b0, pfx_a} + 7'd1 + {1'b0, sleft_a}) > 7'd32) begin
                            prefix <= pfx_a;
                            bit_pos <= bit_pos + {4'd0, pfx_a} + 10'd1;
                            suffix_left <= sleft_a;
                            suffix_acc <= 32'd0;
                            read_window(ST_LVL_SUF);
                        end else begin
                            // An inline escape uses 2*prefix-2 <= 32 bits, so
                            // prefix<=17 and levelCode<=30593 even at suffixLength7.
                            // Only the long-escape store needs a signed16 range check.
                            bad_a = (idx >= 5'd16);
                            if (!bad_a) n_ok = 2'd1;

                            // Level B
                            if (LEVEL_LANES >= 2 && !bad_a && (idx + 5'd1 < tc_r) &&
                                (cons_a < avail_a)) begin
                                if (!(pfx_b >= 6'd32 ||
                                      {6'd0, pfx_b} >= {2'd0, (avail_a - cons_a)} ||
                                      pfx_b > 6'd31)) begin
                                    if ((cons_a + cons_b <= avail_a) &&
                                        (({1'b0, pfx_b} + 7'd1 + {1'b0, sleft_b}) <= 7'd32)) begin
                                        // idx+1 < tc_r <= 16 also bounds the destination.
                                        do_b = 1'b1;
                                        n_ok = 2'd2;
                                    end
                                end
                            end

                            // Level C
                            if (LEVEL_LANES >= 3 && do_b && (idx + 5'd2 < tc_r)) begin
                                if (cons_a + cons_b < avail_a) begin
                                    if (!(pfx_c >= 6'd32 ||
                                          {6'd0, pfx_c} >= {2'd0, (avail_a - cons_a - cons_b)} ||
                                          pfx_c > 6'd31)) begin
                                        if ((cons_a + cons_b + cons_c <= avail_a) &&
                                            (({1'b0, pfx_c} + 7'd1 + {1'b0, sleft_c}) <= 7'd32)) begin
                                            do_c = 1'b1;
                                            n_ok = 2'd3;
                                        end
                                    end
                                end
                            end

                            if (bad_a) begin
                                st <= ST_FAIL;
                            end else begin
                                first_non_t1 <= 1'b0;
                                level_pipe_valid <= {do_c, do_b, 1'b1};
                                level_pipe_idx <= idx;
                                level_pipe_first <= first_a;
                                level_pipe_t1 <= t1_r;
                                level_pipe_win[0] <= win_a;
                                level_pipe_prefix[0] <= pfx_a;
                                level_pipe_consumed[0] <= 6'(cons_a);
                                level_pipe_suffix_bits[0] <= sleft_a;
                                level_pipe_suffix_length[0] <= sl_cur;
                                if (LEVEL_LANES >= 2 && do_b) begin
                                    level_pipe_win[1] <= win_b;
                                    level_pipe_prefix[1] <= pfx_b;
                                    level_pipe_consumed[1] <= 6'(cons_b);
                                    level_pipe_suffix_bits[1] <= sleft_b;
                                    level_pipe_suffix_length[1] <= sl_a;
                                end
                                if (LEVEL_LANES >= 3 && do_c) begin
                                    level_pipe_win[2] <= win_c;
                                    level_pipe_prefix[2] <= pfx_c;
                                    level_pipe_consumed[2] <= 6'(cons_c);
                                    level_pipe_suffix_bits[2] <= sleft_c;
                                    level_pipe_suffix_length[2] <= sl_b;
                                end
                                if (n_ok == 2'd3) begin
                                    suffix_length <= sl_c;
                                    bit_pos <= bit_pos + cons_a + cons_b + cons_c;
                                    if (idx + 5'd3 >= tc_r) begin
                                        code <= 16'd0; code_len <= 5'd0; read_window(ST_TZ_BIT);
                                    end else begin
                                        idx <= idx + 5'd3;
                                        read_window(ST_LVL_PRE);
                                    end
                                end else if (n_ok == 2'd2) begin
                                    suffix_length <= sl_b;
                                    bit_pos <= bit_pos + cons_a + cons_b;
                                    if (idx + 5'd2 >= tc_r) begin
                                        code <= 16'd0; code_len <= 5'd0; read_window(ST_TZ_BIT);
                                    end else begin
                                        idx <= idx + 5'd2;
                                        read_window(ST_LVL_PRE);
                                    end
                                end else begin
                                    suffix_length <= sl_a;
                                    bit_pos <= bit_pos + cons_a;
                                    if (idx + 5'd1 >= tc_r) begin
                                        code <= 16'd0; code_len <= 5'd0; read_window(ST_TZ_BIT);
                                    end else begin
                                        idx <= idx + 5'd1;
                                        read_window(ST_LVL_PRE);
                                    end
                                end
                            end
                        end
                    end
                end
            end

            // Long-escape suffix tail (prefix already consumed).
            ST_LVL_SUF: begin
                if (suffix_left == 5'd0) begin
                    st <= ST_LVL_STORE;
                end else if ({5'd0, suffix_left} > available_bits) st <= ST_FAIL;
                else begin : g_long_suf
                    reg [31:0] win2;
                    win2 = window32(7'd0);
                    suffix_acc <= take_msb(win2, {1'b0, suffix_left});
                    bit_pos <= bit_pos + {5'd0, suffix_left};
                    suffix_left <= 5'd0;
                    st <= ST_LVL_STORE;
                end
            end

            // Complete level after long-escape suffix path only.
            ST_LVL_STORE: begin
                level_code <= long_level_code(prefix, suffix_length, suffix_acc, first_non_t1, t1_r);
                st <= ST_LVL_CHECK;
            end
            ST_LVL_CHECK: begin
                level_bad = idx >= 5'd16 || !level_fits(level_code);
                if (!level_bad) begin
                    lvl_tmp = level_from_code(level_code);
                    level_dbg[idx[3:0]] <= lvl_tmp;
                    if (first_non_t1) begin
                        suffix_length <= suffix_next_first(prefix, suffix_length, t1_r);
                        first_non_t1 <= 1'b0;
                    end else suffix_length <= suffix_next(suffix_length, prefix);
                end
                if (level_bad) st <= ST_FAIL;
                else if (idx + 5'd1 >= tc_r) begin
                    code <= 16'd0; code_len <= 5'd0; read_window(ST_TZ_BIT);
                end else begin
                    idx <= idx + 5'd1;
                    read_window(ST_LVL_PRE);
                end
            end

            ST_TZ_BIT: begin
                if (tc_r >= max_coeff) begin
                    total_zeros <= 4'd0;
                    zeros_left <= 4'd0;
                    idx <= 5'd0;
                    st <= ST_PLACE_INIT;
                end else if (available_bits == 0) st <= ST_FAIL;
                else begin : g_tz_par
                    reg [31:0] zwin;
                    reg [4:0] zbest_len;
                    reg [4:0] zbest;
                    reg [9:0] decoded_zeros;
                    reg found_z;
                    zwin = window32(7'd0);
                    decoded_zeros = fast_zeros({tz_is_chroma, tc_r}, zwin[31:23]);
                    zbest = decoded_zeros[9:5];
                    zbest_len = decoded_zeros[4:0];
                    found_z = decoded_zeros[9] && available_bits >= zbest_len;
                    if (!found_z || {1'b0, zbest[3:0]} + tc_r > max_coeff) st <= ST_FAIL;
                    else begin
                        bit_pos <= bit_pos + {5'd0, zbest_len};
                        total_zeros <= zbest[3:0];
                        zeros_left <= zbest[3:0];
                        idx <= 5'd0;
                        code <= 16'd0; code_len <= 5'd0;
                        if (tc_r <= 5'd1 || zbest[3:0] == 4'd0) begin
                            run_dbg[idx4(tc_r - 5'd1)] <= zbest[3:0];
                            st <= ST_PLACE_INIT;
                        end else read_window(ST_RUN_BIT);
                    end
                end
            end

            ST_TZ_CHK: st <= ST_FAIL;

            // Up to two run_before symbols/cycle (zeros_left chained).
            ST_RUN_BIT: begin
                if (idx >= tc_r - 5'd1 || zeros_left == 4'd0) begin
                    run_dbg[idx4(tc_r - 5'd1)] <= zeros_left;
                    st <= ST_PLACE_INIT;
                end else if (available_bits == 0) st <= ST_FAIL;
                else begin : g_run_pair
                    reg [31:0] rwin_a, rwin_b;
                    reg [4:0] rblen_a, rblen_b;
                    reg [4:0] rbest_a, rbest_b;
                    reg [9:0] decoded_run_a, decoded_run_b;
                    reg found_a, found_b, do_b;
                    reg [3:0] zl_a, zl_b, run_a, run_b;
                    reg [BIT_W:0] bpos_a;
                    rwin_a = window32(7'd0);
                    decoded_run_a = fast_run(zeros_left < 4'd7 ? zeros_left : 4'd7, rwin_a[31:21]);
                    rbest_a = decoded_run_a[9:5];
                    rblen_a = decoded_run_a[4:0];
                    found_a = decoded_run_a[9] && available_bits >= rblen_a;

                    do_b = 1'b0;
                    found_b = 1'b0;
                    rbest_b = 5'd0;
                    rblen_b = 5'd0;
                    run_a = 4'd0;
                    run_b = 4'd0;
                    zl_a = zeros_left;
                    zl_b = zeros_left;
                    bpos_a = bit_pos;

                    if (!found_a) st <= ST_FAIL;
                    else if (rbest_a[3:0] > zeros_left) st <= ST_FAIL;
                    else begin
                        run_a = rbest_a[3:0];
                        zl_a = zeros_left - run_a;
                        bpos_a = bit_pos + {5'd0, rblen_a};

                        // Second run if more coeffs remain and zeros remain.
                        if (idx + 5'd1 < tc_r - 5'd1 && zl_a != 4'd0 && rblen_a < available_bits) begin
                            rwin_b = window32({2'd0, rblen_a});
                            decoded_run_b = fast_run(zl_a < 4'd7 ? zl_a : 4'd7, rwin_b[31:21]);
                            rbest_b = decoded_run_b[9:5];
                            rblen_b = decoded_run_b[4:0];
                            found_b = decoded_run_b[9] && available_bits - rblen_a >= rblen_b;
                            if (found_b && rbest_b[3:0] <= zl_a) begin
                                run_b = rbest_b[3:0];
                                zl_b = zl_a - run_b;
                                do_b = 1'b1;
                            end
                        end

                        code <= 16'd0; code_len <= 5'd0;
                        if (do_b) begin
                            run_dbg[idx[3:0]] <= run_a;
                            run_dbg[idx[3:0] + 4'd1] <= run_b;
                            zeros_left <= zl_b;
                            bit_pos <= bpos_a + {5'd0, rblen_b};
                            if (idx + 5'd2 >= tc_r - 5'd1 || zl_b == 4'd0) begin
                                run_dbg[idx4(tc_r - 5'd1)] <= zl_b;
                                st <= ST_PLACE_INIT;
                            end else begin
                                idx <= idx + 5'd2;
                                read_window(ST_RUN_BIT);
                            end
                        end else begin
                            run_dbg[idx[3:0]] <= run_a;
                            zeros_left <= zl_a;
                            bit_pos <= bpos_a;
                            if (idx + 5'd1 >= tc_r - 5'd1 || zl_a == 4'd0) begin
                                run_dbg[idx4(tc_r - 5'd1)] <= zl_a;
                                st <= ST_PLACE_INIT;
                            end else begin
                                idx <= idx + 5'd1;
                                read_window(ST_RUN_BIT);
                            end
                        end
                    end
                end
            end

            ST_RUN_CHK: st <= ST_FAIL;

            ST_PLACE_INIT: begin
                for (ci = 0; ci < 16; ci = ci + 1)
                    coeff[ci] <= placed_coeff[ci];
                if (place_bad) st <= ST_FAIL;
                else begin
                    ok <= 1'b1;
                    bit_offset_end <= bit_pos;
                    st <= ST_DONE;
                end
            end

            ST_PLACE_STEP: st <= ST_FAIL; // unused (bulk place)

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

    // synthesis translate_off
    always @(posedge clk)
        if (!reset && window_consuming)
            assert (window_valid && window_position==bit_pos && available_bits==live_available_bits)
                else $error("CAVLC consumed an unowned/stale window response");
    // synthesis translate_on
endmodule
