// Testbench-only wrapper for real h264_cavlc_residual.sv product RTL.
`default_nettype none

module h264_cavlc_residual_tb_top #(
    parameter int MAX_BYTES = 128,
    parameter int BIT_W = $clog2(MAX_BYTES * 8 + 1)
)(
    input  wire               clk,
    input  wire               reset,
    input  wire               start,
    input  wire [2:0]         coeff_token_table,
    input  wire [4:0]         max_coeff,
    input  wire [BIT_W-1:0]   bit_offset_start,
    input  wire [BIT_W-1:0]   bit_len,
    input  wire [7:0]         rbsp [0:MAX_BYTES-1],
    output wire               busy,
    output wire               done,
    output wire               ok,
    output wire [BIT_W-1:0]   bit_offset_end,
    output wire [4:0]         total_coeff,
    output wire [1:0]         trailing_ones,
    output wire [3:0]         total_zeros,
    output wire signed [15:0] coeff [0:15],
    output wire signed [15:0] level_dbg [0:15],
    output wire [3:0]         run_dbg [0:15],
    output wire baseline_done, baseline_ok,
    output reg baseline_done_seen,
    output reg [31:0] baseline_cycles,
    output wire [BIT_W-1:0] baseline_end,
    output wire [4:0] baseline_tc,
    output wire [1:0] baseline_t1,
    output wire [3:0] baseline_zeros,
    output wire signed [15:0] baseline_coeff [0:15], baseline_levels [0:15],
    output wire [3:0] baseline_runs [0:15],
    input wire [BIT_W:0] probe_position, probe_limit,
    output wire [95:0] probe_aligned_window,
    input wire [5:0] probe_long_prefix,
    output wire [31:0] probe_long_code,
    input wire [4:0] probe_mask_dst, probe_mask_idx,
    input wire [2:0] probe_mask_valid,
    output wire [15:0] probe_mask_data,
    output reg               datapath_equivalent,
    output wire [1:0]        placement_stage,
    input  wire [31:0]       probe_window,
    input  wire [2:0]        probe_suffix_length,
    input  wire [1:0]        probe_t1,
    input  wire [31:0]       probe_level_code,
    output wire signed [15:0] probe_level,
    output wire [5:0]        probe_prefix,
    output wire [2:0]        probe_suffix_first,
    output wire [2:0]        probe_suffix_next,
    input  wire [5:0]        probe_consumed,
    input  wire [4:0]        probe_suffix_bits,
    input  wire              probe_first,
    output wire [15:0]       probe_inline_suffix,
    output wire [15:0]       probe_inline_code,
    input  wire [5:0]        probe_fast_row,
    output wire [12:0]       probe_fast_token,
    output wire [9:0]        probe_fast_zeros,
    output wire [9:0]        probe_fast_run,
`ifdef CAVLC_CYCLE_PROBE
    output wire [15:0]        cy_token,
    output wire [15:0]        cy_sign,
    output wire [15:0]        cy_level,
    output wire [15:0]        cy_total_zeros,
    output wire [15:0]        cy_run_before,
    output wire [15:0]        cy_place,
    output wire [15:0]        cy_other,
    output wire [15:0]        cy_total,
`endif

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
    output wire [2:0]         nc_coeff_token_table
);
    wire signed [15:0] dut_coeff [0:15];
    wire baseline_busy;
    h264_cavlc_residual_block_reference #(.MAX_BYTES(MAX_BYTES)) u_baseline (
        .clk(clk), .reset(reset), .start(start),
        .coeff_token_table(coeff_token_table), .max_coeff(max_coeff),
        .bit_offset_start(bit_offset_start), .bit_len(bit_len), .rbsp(rbsp),
        .busy(baseline_busy), .done(baseline_done), .ok(baseline_ok),
        .bit_offset_end(baseline_end), .total_coeff(baseline_tc),
        .trailing_ones(baseline_t1), .total_zeros(baseline_zeros),
        .coeff(baseline_coeff), .level_dbg(baseline_levels), .run_dbg(baseline_runs)
    );
    always @(posedge clk) begin
        if (reset || start) begin baseline_done_seen<=0; baseline_cycles<=0; end
        else begin
            if (baseline_done) baseline_done_seen<=1;
            if (baseline_busy) baseline_cycles<=baseline_cycles+1'b1;
        end
    end

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
`ifdef CAVLC_CYCLE_PROBE
        ,
        .cy_token(cy_token),
        .cy_sign(cy_sign),
        .cy_level(cy_level),
        .cy_total_zeros(cy_total_zeros),
        .cy_run_before(cy_run_before),
        .cy_place(cy_place),
        .cy_other(cy_other),
        .cy_total(cy_total)
`endif
    );

    assign probe_prefix = u_residual.clz32(probe_window);
    assign probe_aligned_window = u_residual.align_window(
        u_residual.select_window_words(probe_position), probe_position[5:0],
        probe_position<probe_limit ? probe_limit-probe_position : (BIT_W+1)'(0));
    assign probe_long_code = u_residual.long_level_code(
        probe_long_prefix, probe_suffix_length, probe_level_code, probe_first, probe_t1);
    assign probe_mask_data = u_residual.level_write_data(
        probe_mask_dst, probe_mask_idx, probe_mask_valid,
        probe_window[15:0], probe_window[31:16], probe_level_code[15:0]);
`ifdef CAVLC_FAST_VLC_TEST
    assign probe_fast_token = u_residual.fast_token(probe_fast_row[2:0], probe_window[31:16]);
    assign probe_fast_zeros = u_residual.fast_zeros(probe_fast_row, probe_window[31:23]);
    assign probe_fast_run = u_residual.fast_run(probe_fast_row[3:0], probe_window[31:21]);
`else
    assign probe_fast_token = 0;
    assign probe_fast_zeros = 0;
    assign probe_fast_run = 0;
`endif
    assign probe_level = u_residual.level_from_code(probe_level_code);
`ifdef CAVLC_TIMING_BASELINE
    // The frozen pre-timing RTL has level-valued helper arguments instead.
    assign probe_suffix_first = 3'd0;
    assign probe_suffix_next = 3'd0;
    assign probe_inline_suffix = 16'd0;
    assign probe_inline_code = 16'd0;
`else
    assign probe_suffix_first =
        u_residual.suffix_next_first(probe_prefix, probe_suffix_length, probe_t1);
    assign probe_suffix_next =
        u_residual.suffix_next(probe_suffix_length, probe_prefix);
    assign probe_inline_suffix =
        u_residual.inline_suffix(probe_window, probe_consumed, probe_suffix_bits);
    assign probe_inline_code =
        u_residual.decode_inline_level_code(probe_prefix, probe_suffix_length,
                                           probe_inline_suffix, probe_first, probe_t1);
`endif

    // Test-only reference equations for the factored combinational networks.
    // Keep arbitrary-bit reads and ordered scatter out of product RTL.
    reg [95:0] reference_window;
    reg signed [15:0] reference_coeff [0:15];
    reg reference_bad;
    assign placement_stage =
        u_residual.st == u_residual.ST_PLACE_SUM ? 2'd1 :
        u_residual.st == u_residual.ST_PLACE_MAP ? 2'd2 :
        u_residual.st == u_residual.ST_PLACE_STEP ? 2'd3 : 2'd0;
    always @* begin : reference_datapath
        integer k, p, pi, sum, count;
        reg signed [5:0] cnum;
        reference_window = 96'd0;
        for (k = 0; k < 96; k = k + 1) begin
            p = u_residual.bit_pos + k;
            if (p < bit_len && (p >> 3) < MAX_BYTES)
                reference_window[95-k] = rbsp[p >> 3][7-(p & 7)];
        end
        for (k = 0; k < 16; k = k + 1) reference_coeff[k] = 16'sd0;
        cnum = -6'sd1;
        reference_bad = 1'b0;
        for (pi = 16; pi >= 1; pi = pi - 1) begin
            if (pi <= u_residual.tc_r && !reference_bad) begin
                cnum = cnum + {2'd0, run_dbg[pi-1]} + 6'sd1;
                if (cnum >= 0 && cnum < $signed({1'b0, max_coeff}))
                    reference_coeff[cnum[3:0]] = level_dbg[pi-1];
                else reference_bad = 1'b1;
            end
        end
        datapath_equivalent = (!u_residual.window_consuming ||
                              (u_residual.window_valid && u_residual.window_position==u_residual.bit_pos &&
                               reference_window === u_residual.stream_window));
        for (k = 0; k < 16; k = k + 1) begin
            sum = 0;
            count = placement_stage == 1 ? 4 : 16;
            for (pi = 0; pi < 16; pi = pi + 1)
                if (pi >= k && pi < k + count && pi < u_residual.tc_r)
                    sum = sum + int'(run_dbg[pi]) + 1;
            if (placement_stage == 1 || placement_stage == 2)
                datapath_equivalent = datapath_equivalent && (u_residual.place_sum[k] === 9'(sum));
            if (placement_stage == 3)
                datapath_equivalent = datapath_equivalent &&
                    (reference_bad === u_residual.place_bad) &&
                    (reference_coeff[k] === u_residual.placed_coeff[k]);
        end
    end

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
endmodule

`default_nettype wire
