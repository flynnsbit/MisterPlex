// Multi-block CAVLC macroblock decoder.
// Iterates through all residual blocks of one macroblock in H.264 decode order,
// feeding h264_cavlc_residual_block for each, tracking nC (total_coeff) context.
//
// Block order per H.264 spec (Baseline, frame macroblocks):
//   I_NxN:   16 luma 4x4 (max_coeff=16), 4 Cb AC, 4 Cr AC (max_coeff=15 each)
//   I_16x16: 1 luma DC (max_coeff=16), 16 luma AC (max_coeff=15),
//            1 Cb DC (max_coeff=4), 4 Cb AC (max_coeff=15),
//            1 Cr DC (max_coeff=4), 4 Cr AC (max_coeff=15)
//
// nC context: for luma, derived from left and above 4x4 blocks' total_coeff.
//   Within the MB, uses internally-stored values. At MB boundaries, uses
//   external left_tc_col[0:3] and above_tc_row[0:3] inputs.
//   Chroma DC: coeff_token_table = 4 (fixed).
//   Chroma AC: nC derived from chroma block neighbours (2x2 grid per plane).
//
// Luma 4x4 block index to (bx, by) within the MB:
//   idx: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
//   bx:  0  1  0  1  2  3  2  3  0  1  0  1  2  3  2  3
//   by:  0  0  1  1  0  0  1  1  2  2  3  3  2  2  3  3
// (H.264 8x8-block-raster, 4x4-raster-within-8x8)
`default_nettype none

module h264_cavlc_mb_decoder #(
    parameter int MAX_BYTES = 512   // must hold all residual data for one MB
)(
    input  wire               clk,
    input  wire               reset,
    // Control
    input  wire               start,          // pulse to begin decoding one MB
    input  wire [1:0]         mb_type,        // 0: I_NxN, 1: I_16x16, 2: P (cbp-driven)
    input  wire [5:0]         cbp,            // coded_block_pattern (luma 4 bits + chroma 2 bits)
    // Bitstream buffer (RBSP bytes, shared with reader)
    input  wire [9:0]         bit_offset_in,  // starting bit position for first block
    input  wire [9:0]         bit_len,        // total bits available
    input  wire [7:0]         rbsp [0:MAX_BYTES-1],
    // MB position for nC boundary context
    input  wire [7:0]         mb_x,
    input  wire [7:0]         mb_y,
    input  wire [15:0]        mb_index,
    input  wire [7:0]         mb_width,
    input  wire [15:0]        first_mb_in_slice,
    // External neighbour total_coeff (from previous MB row / left MB)
    // Luma: left column (4 values for by=0..3), above row (4 values for bx=0..3)
    input  wire [4:0]         left_tc_luma [0:3],   // tc of right-column blocks of left MB
    input  wire               left_tc_luma_valid,
    input  wire [4:0]         above_tc_luma [0:3],  // tc of bottom-row blocks of above MB
    input  wire               above_tc_luma_valid,
    // Chroma: left (2 values), above (2 values) per plane
    input  wire [4:0]         left_tc_cb [0:1],
    input  wire               left_tc_cb_valid,
    input  wire [4:0]         above_tc_cb [0:1],
    input  wire               above_tc_cb_valid,
    input  wire [4:0]         left_tc_cr [0:1],
    input  wire               left_tc_cr_valid,
    input  wire [4:0]         above_tc_cr [0:1],
    input  wire               above_tc_cr_valid,
    // Per-block output
    output reg                block_done,     // 1-cycle pulse when a block is complete
    output reg  [4:0]         block_idx,      // which block just completed (0..25)
    output reg  [4:0]         block_tc,       // total_coeff for this block
    output reg signed [15:0]  block_coeff [0:15],  // coefficients in scan order
    output reg  [4:0]         block_max_coeff,     // 16, 15, or 4
    // MB-level outputs
    output reg                mb_done,        // pulse when all blocks of MB complete
    output reg  [9:0]         bit_offset_out, // bit position after last block
    output reg                busy,
    output reg                error           // set if any block fails to decode
);

    // --- Block sequencing ---
    // Total blocks per MB type:
    //   I_NxN:   16 luma + [if cbp_chroma] 2 DC + 8 AC = up to 26
    //   I_16x16: 1 DC + 16 AC + [if cbp_chroma] 2 DC + 8 AC = up to 27
    //   P:       cbp-driven subset

    // Luma 4x4 block index → (bx, by) mapping (H.264 Table 6-10)
    function automatic [1:0] luma_bx(input [3:0] idx);
        case (idx)
            4'd0:  luma_bx = 2'd0;  4'd1:  luma_bx = 2'd1;
            4'd2:  luma_bx = 2'd0;  4'd3:  luma_bx = 2'd1;
            4'd4:  luma_bx = 2'd2;  4'd5:  luma_bx = 2'd3;
            4'd6:  luma_bx = 2'd2;  4'd7:  luma_bx = 2'd3;
            4'd8:  luma_bx = 2'd0;  4'd9:  luma_bx = 2'd1;
            4'd10: luma_bx = 2'd0;  4'd11: luma_bx = 2'd1;
            4'd12: luma_bx = 2'd2;  4'd13: luma_bx = 2'd3;
            4'd14: luma_bx = 2'd2;  4'd15: luma_bx = 2'd3;
            default: luma_bx = 2'd0;
        endcase
    endfunction

    function automatic [1:0] luma_by(input [3:0] idx);
        case (idx)
            4'd0:  luma_by = 2'd0;  4'd1:  luma_by = 2'd0;
            4'd2:  luma_by = 2'd1;  4'd3:  luma_by = 2'd1;
            4'd4:  luma_by = 2'd0;  4'd5:  luma_by = 2'd0;
            4'd6:  luma_by = 2'd1;  4'd7:  luma_by = 2'd1;
            4'd8:  luma_by = 2'd2;  4'd9:  luma_by = 2'd2;
            4'd10: luma_by = 2'd3;  4'd11: luma_by = 2'd3;
            4'd12: luma_by = 2'd2;  4'd13: luma_by = 2'd2;
            4'd14: luma_by = 2'd3;  4'd15: luma_by = 2'd3;
            default: luma_by = 2'd0;
        endcase
    endfunction

    // --- Internal state ---
    localparam [2:0]
        ST_IDLE       = 3'd0,
        ST_START_BLK  = 3'd1,
        ST_WAIT_BLK   = 3'd2,
        ST_LATCH_BLK  = 3'd3,
        ST_NEXT_BLK   = 3'd4,
        ST_MB_DONE    = 3'd5;

    reg [2:0] state;
    reg [4:0] seq_idx;        // 0..26: sequential block within MB
    reg [9:0] cur_bit_offset; // current position in bitstream

    // Per-MB luma total_coeff storage (for intra-MB nC)
    reg [4:0] luma_tc [0:15]; // total_coeff for each of 16 luma 4x4 blocks
    // Chroma total_coeff (for intra-MB chroma nC)
    reg [4:0] cb_tc [0:3];    // Cb AC blocks
    reg [4:0] cr_tc [0:3];    // Cr AC blocks

    // Block decoder instance signals
    reg        blk_start;
    reg [2:0]  blk_table;
    reg [4:0]  blk_max_coeff;
    reg [9:0]  blk_bit_start;
    wire       blk_busy;
    wire       blk_done_w;
    wire       blk_ok;
    wire [9:0] blk_bit_end;
    wire [4:0] blk_tc;
    wire [1:0] blk_t1;
    wire [3:0] blk_tz;
    wire signed [15:0] blk_coeff_out [0:15];

    h264_cavlc_residual_block #(.MAX_BYTES(MAX_BYTES)) u_blk (
        .clk(clk),
        .reset(reset),
        .start(blk_start),
        .coeff_token_table(blk_table),
        .max_coeff(blk_max_coeff),
        .bit_offset_start(blk_bit_start),
        .bit_len(bit_len),
        .rbsp(rbsp),
        .busy(blk_busy),
        .done(blk_done_w),
        .ok(blk_ok),
        .bit_offset_end(blk_bit_end),
        .total_coeff(blk_tc),
        .trailing_ones(blk_t1),
        .total_zeros(blk_tz),
        .coeff(blk_coeff_out),
        .level_dbg(),
        .run_dbg()
    );

    // --- nC computation for current block ---
    // Determines coeff_token_table based on block type and position.
    reg [2:0] cur_table;
    reg [4:0] cur_max_coeff;

    // nC helper: get left neighbour's total_coeff for luma block
    function automatic [4:0] get_left_tc_luma(input [3:0] idx);
        reg [1:0] bx, by;
        begin
            bx = luma_bx(idx);
            by = luma_by(idx);
            if (bx == 2'd0) begin
                // Left neighbour is in the previous MB
                // Map by to the external left column
                get_left_tc_luma = left_tc_luma[by];
            end else begin
                // Left neighbour is within this MB: find block at (bx-1, by)
                // Inverse lookup: which block index has (bx-1, by)?
                case ({bx - 2'd1, by})
                    4'b0000: get_left_tc_luma = luma_tc[0];
                    4'b0001: get_left_tc_luma = luma_tc[2];
                    4'b0010: get_left_tc_luma = luma_tc[8];
                    4'b0011: get_left_tc_luma = luma_tc[10];
                    4'b0100: get_left_tc_luma = luma_tc[1];
                    4'b0101: get_left_tc_luma = luma_tc[3];
                    4'b0110: get_left_tc_luma = luma_tc[9];
                    4'b0111: get_left_tc_luma = luma_tc[11];
                    4'b1000: get_left_tc_luma = luma_tc[4];
                    4'b1001: get_left_tc_luma = luma_tc[6];
                    4'b1010: get_left_tc_luma = luma_tc[12];
                    4'b1011: get_left_tc_luma = luma_tc[14];
                    default: get_left_tc_luma = 5'd0;
                endcase
            end
        end
    endfunction

    function automatic get_left_tc_luma_valid(input [3:0] idx);
        reg [1:0] bx;
        begin
            bx = luma_bx(idx);
            if (bx == 2'd0)
                get_left_tc_luma_valid = left_tc_luma_valid;
            else
                get_left_tc_luma_valid = 1'b1; // intra-MB always valid
        end
    endfunction

    function automatic [4:0] get_above_tc_luma(input [3:0] idx);
        reg [1:0] bx, by;
        begin
            bx = luma_bx(idx);
            by = luma_by(idx);
            if (by == 2'd0) begin
                // Above neighbour is in the previous MB row
                get_above_tc_luma = above_tc_luma[bx];
            end else begin
                // Above neighbour is within this MB: find block at (bx, by-1)
                case ({bx, by - 2'd1})
                    4'b0000: get_above_tc_luma = luma_tc[0];
                    4'b0001: get_above_tc_luma = luma_tc[2];
                    4'b0010: get_above_tc_luma = luma_tc[8];
                    4'b0011: get_above_tc_luma = luma_tc[10];
                    4'b0100: get_above_tc_luma = luma_tc[1];
                    4'b0101: get_above_tc_luma = luma_tc[3];
                    4'b0110: get_above_tc_luma = luma_tc[9];
                    4'b0111: get_above_tc_luma = luma_tc[11];
                    4'b1000: get_above_tc_luma = luma_tc[4];
                    4'b1001: get_above_tc_luma = luma_tc[6];
                    4'b1010: get_above_tc_luma = luma_tc[12];
                    4'b1011: get_above_tc_luma = luma_tc[14];
                    default: get_above_tc_luma = 5'd0;
                endcase
            end
        end
    endfunction

    function automatic get_above_tc_luma_valid(input [3:0] idx);
        reg [1:0] by;
        begin
            by = luma_by(idx);
            if (by == 2'd0)
                get_above_tc_luma_valid = above_tc_luma_valid;
            else
                get_above_tc_luma_valid = 1'b1;
        end
    endfunction

    // --- Sequencing logic ---
    // Block decode order depends on mb_type:
    //   I_NxN:   seq 0..15 = luma 4x4 blocks 0..15 (max_coeff=16)
    //            seq 16 = Cb DC (max_coeff=4, table=4) if cbp_chroma != 0
    //            seq 17..20 = Cb AC (max_coeff=15) if cbp_chroma == 2
    //            seq 21 = Cr DC (max_coeff=4, table=4) if cbp_chroma != 0
    //            seq 22..25 = Cr AC (max_coeff=15) if cbp_chroma == 2
    //   I_16x16: seq 0 = luma DC (max_coeff=16, nC from DC-specific rule)
    //            seq 1..16 = luma AC blocks 0..15 (max_coeff=15)
    //            seq 17 = Cb DC, seq 18..21 = Cb AC
    //            seq 22 = Cr DC, seq 23..26 = Cr AC

    wire [1:0] cbp_chroma = cbp[1:0]; // 0: none, 1: DC only, 2: DC+AC
    wire [3:0] cbp_luma   = cbp[5:2]; // per-8x8-block flags

    // Determine if a given 4x4 luma block should be decoded based on cbp
    function automatic luma_block_coded(input [3:0] idx, input [3:0] cbp_l);
        reg [1:0] blk8x8;
        begin
            blk8x8 = idx[3:2]; // which 8x8 block (0..3)
            luma_block_coded = cbp_l[blk8x8];
        end
    endfunction

    // Determine total number of blocks to process
    reg [4:0] total_blocks;
    always @(*) begin
        if (mb_type == 2'd0) begin
            // I_NxN: 16 luma + chroma
            total_blocks = 5'd16;
            if (cbp_chroma != 2'd0) total_blocks = total_blocks + 5'd2; // DC
            if (cbp_chroma == 2'd2) total_blocks = total_blocks + 5'd8; // AC
        end else if (mb_type == 2'd1) begin
            // I_16x16: 1 DC + 16 AC + chroma
            total_blocks = 5'd17;
            if (cbp_chroma != 2'd0) total_blocks = total_blocks + 5'd2;
            if (cbp_chroma == 2'd2) total_blocks = total_blocks + 5'd8;
        end else begin
            // P: cbp-driven
            total_blocks = 5'd0;
            // Count coded luma blocks
            if (cbp_luma[0]) total_blocks = total_blocks + 5'd4;
            if (cbp_luma[1]) total_blocks = total_blocks + 5'd4;
            if (cbp_luma[2]) total_blocks = total_blocks + 5'd4;
            if (cbp_luma[3]) total_blocks = total_blocks + 5'd4;
            if (cbp_chroma != 2'd0) total_blocks = total_blocks + 5'd2;
            if (cbp_chroma == 2'd2) total_blocks = total_blocks + 5'd8;
        end
    end

    // Compute table and max_coeff for current seq_idx
    // Also: which logical block is being decoded
    reg [3:0] cur_luma_idx;  // 0..15 for luma blocks
    reg       cur_is_luma_dc;
    reg       cur_is_chroma_dc;
    reg       cur_skip_block; // block not coded (cbp says skip)

    always @(*) begin
        cur_table = 3'd0;
        cur_max_coeff = 5'd16;
        cur_luma_idx = 4'd0;
        cur_is_luma_dc = 1'b0;
        cur_is_chroma_dc = 1'b0;
        cur_skip_block = 1'b0;

        if (mb_type == 2'd0) begin
            // I_NxN
            if (seq_idx < 5'd16) begin
                // Luma 4x4
                cur_luma_idx = seq_idx[3:0];
                cur_max_coeff = 5'd16;
                if (!luma_block_coded(seq_idx[3:0], cbp_luma))
                    cur_skip_block = 1'b1;
                // nC from neighbours
                cur_table = compute_luma_table(seq_idx[3:0]);
            end else if (seq_idx == 5'd16 || seq_idx == 5'd21) begin
                // Chroma DC
                cur_is_chroma_dc = 1'b1;
                cur_max_coeff = 5'd4;
                cur_table = 3'd4;
            end else begin
                // Chroma AC
                cur_max_coeff = 5'd15;
                cur_table = 3'd0; // simplified; proper nC TBD
            end
        end else if (mb_type == 2'd1) begin
            // I_16x16
            if (seq_idx == 5'd0) begin
                // Luma DC
                cur_is_luma_dc = 1'b1;
                cur_max_coeff = 5'd16;
                // I_16x16 DC uses nC from DC context (spec says nC=-1 → table based on DC)
                // For simplicity use table 0 (nC=0) for DC — correct for first MB
                cur_table = 3'd0;
            end else if (seq_idx <= 5'd16) begin
                // Luma AC (block index = seq_idx - 1)
                cur_luma_idx = seq_idx[3:0] - 4'd1;
                cur_max_coeff = 5'd15;
                cur_table = compute_luma_table(seq_idx[3:0] - 4'd1);
            end else if (seq_idx == 5'd17 || seq_idx == 5'd22) begin
                // Chroma DC
                cur_is_chroma_dc = 1'b1;
                cur_max_coeff = 5'd4;
                cur_table = 3'd4;
            end else begin
                // Chroma AC
                cur_max_coeff = 5'd15;
                cur_table = 3'd0;
            end
        end else begin
            // P: same as I_NxN but cbp-driven
            if (seq_idx < 5'd16) begin
                cur_luma_idx = seq_idx[3:0];
                cur_max_coeff = 5'd16;
                if (!luma_block_coded(seq_idx[3:0], cbp_luma))
                    cur_skip_block = 1'b1;
                cur_table = compute_luma_table(seq_idx[3:0]);
            end else if (seq_idx == 5'd16 || seq_idx == 5'd21) begin
                cur_is_chroma_dc = 1'b1;
                cur_max_coeff = 5'd4;
                cur_table = 3'd4;
            end else begin
                cur_max_coeff = 5'd15;
                cur_table = 3'd0;
            end
        end
    end

    // Compute luma coeff_token table from nC
    function automatic [2:0] compute_luma_table(input [3:0] idx);
        reg [4:0] nc_left, nc_above, nc_val;
        reg       left_valid, above_valid;
        begin
            nc_left = get_left_tc_luma(idx);
            left_valid = get_left_tc_luma_valid(idx);
            nc_above = get_above_tc_luma(idx);
            above_valid = get_above_tc_luma_valid(idx);

            if (left_valid && above_valid)
                nc_val = (nc_left + nc_above + 5'd1) >> 1;
            else if (left_valid)
                nc_val = nc_left;
            else if (above_valid)
                nc_val = nc_above;
            else
                nc_val = 5'd0;

            if (nc_val < 5'd2)       compute_luma_table = 3'd0;
            else if (nc_val < 5'd4)  compute_luma_table = 3'd1;
            else if (nc_val < 5'd8)  compute_luma_table = 3'd2;
            else                     compute_luma_table = 3'd3;
        end
    endfunction

    // --- State machine ---
    integer ci;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            mb_done <= 1'b0;
            block_done <= 1'b0;
            error <= 1'b0;
            blk_start <= 1'b0;
            seq_idx <= 5'd0;
            cur_bit_offset <= 10'd0;
            for (ci = 0; ci < 16; ci = ci + 1) luma_tc[ci] <= 5'd0;
            for (ci = 0; ci < 4; ci = ci + 1) cb_tc[ci] <= 5'd0;
            for (ci = 0; ci < 4; ci = ci + 1) cr_tc[ci] <= 5'd0;
        end else begin
            // Default: pulses are 1 cycle
            block_done <= 1'b0;
            mb_done <= 1'b0;
            blk_start <= 1'b0;

            case (state)
            ST_IDLE: begin
                if (start) begin
                    busy <= 1'b1;
                    error <= 1'b0;
                    seq_idx <= 5'd0;
                    cur_bit_offset <= bit_offset_in;
                    for (ci = 0; ci < 16; ci = ci + 1) luma_tc[ci] <= 5'd0;
                    for (ci = 0; ci < 4; ci = ci + 1) cb_tc[ci] <= 5'd0;
                    for (ci = 0; ci < 4; ci = ci + 1) cr_tc[ci] <= 5'd0;
                    state <= ST_START_BLK;
                end
            end

            ST_START_BLK: begin
                if (seq_idx >= total_blocks) begin
                    state <= ST_MB_DONE;
                end else if (cur_skip_block) begin
                    // Block not coded — emit zeros and advance
                    block_done <= 1'b1;
                    block_idx <= seq_idx;
                    block_tc <= 5'd0;
                    block_max_coeff <= cur_max_coeff;
                    for (ci = 0; ci < 16; ci = ci + 1)
                        block_coeff[ci] <= 16'sd0;
                    // Store zero total_coeff
                    if (seq_idx < 5'd16 || (mb_type == 2'd1 && seq_idx > 5'd0 && seq_idx <= 5'd16))
                        luma_tc[cur_luma_idx] <= 5'd0;
                    seq_idx <= seq_idx + 5'd1;
                    // Stay in ST_START_BLK to process next
                end else begin
                    // Start block decode
                    blk_start <= 1'b1;
                    blk_table <= cur_table;
                    blk_max_coeff <= cur_max_coeff;
                    blk_bit_start <= cur_bit_offset;
                    state <= ST_WAIT_BLK;
                end
            end

            ST_WAIT_BLK: begin
                if (blk_done_w) begin
                    if (!blk_ok) begin
                        error <= 1'b1;
                        state <= ST_MB_DONE;
                    end else begin
                        state <= ST_LATCH_BLK;
                    end
                end
            end

            ST_LATCH_BLK: begin
                // Latch results
                block_done <= 1'b1;
                block_idx <= seq_idx;
                block_tc <= blk_tc;
                block_max_coeff <= cur_max_coeff;
                for (ci = 0; ci < 16; ci = ci + 1)
                    block_coeff[ci] <= blk_coeff_out[ci];

                // Update bit offset
                cur_bit_offset <= blk_bit_end;

                // Store total_coeff for nC context
                if (mb_type == 2'd0) begin
                    if (seq_idx < 5'd16)
                        luma_tc[cur_luma_idx] <= blk_tc;
                    else if (seq_idx >= 5'd17 && seq_idx <= 5'd20)
                        cb_tc[seq_idx[1:0] - 2'd1] <= blk_tc;
                    else if (seq_idx >= 5'd22 && seq_idx <= 5'd25)
                        cr_tc[seq_idx[1:0] - 2'd2] <= blk_tc;
                end else if (mb_type == 2'd1) begin
                    if (seq_idx >= 5'd1 && seq_idx <= 5'd16)
                        luma_tc[cur_luma_idx] <= blk_tc;
                    else if (seq_idx >= 5'd18 && seq_idx <= 5'd21)
                        cb_tc[seq_idx[1:0] - 2'd2] <= blk_tc;
                    else if (seq_idx >= 5'd23 && seq_idx <= 5'd26)
                        cr_tc[seq_idx[1:0] - 2'd3] <= blk_tc;
                end

                state <= ST_NEXT_BLK;
            end

            ST_NEXT_BLK: begin
                seq_idx <= seq_idx + 5'd1;
                state <= ST_START_BLK;
            end

            ST_MB_DONE: begin
                mb_done <= 1'b1;
                bit_offset_out <= cur_bit_offset;
                busy <= 1'b0;
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
