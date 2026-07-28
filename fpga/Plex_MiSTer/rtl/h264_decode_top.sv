// h264_decode_top — Real intra macroblock decode datapath.
//
// Processes all 16 luma 4×4 blocks of a macroblock sequentially through a
// shared dequant → IDCT → recon pipeline. Stores 256 reconstructed luma pixels.
//
// INTERFACE: Block-serial. Feed 16 coefficients per block, strobe block_valid.
// After 16 blocks, mb_recon_valid pulses and recon_y[0:255] is the full MB.
//
// PREDICTION: Instantiates h264_intra4x4_pred and h264_intra16x16_pred.
// Neighbour context comes from external line buffers via nb_* ports.
// When no neighbours are available (mb_avail_left=0, mb_avail_top=0),
// prediction falls back to DC=128 — correct per H.264 spec §8.3.1.2.
//
// THIS IS THE MODULE THAT MOVES INTEGRATED_PIPELINE_COVERAGE.
//
// OWNER: w-rel.

`default_nettype none

module h264_decode_top (
    input  wire        clk,
    input  wire        reset,

    // ── Macroblock-level inputs ──
    input  wire        mb_start,           // Pulse: begin new macroblock
    input  wire [7:0]  mb_type,            // H.264 mb_type (0=I_NxN, 1-24=I_16x16, 25=I_PCM)
    input  wire [5:0]  mb_qp_y,            // Luma QP for this MB
    input  wire [7:0]  mb_x,               // MB column (0-based)
    input  wire [7:0]  mb_y,               // MB row (0-based)

    // ── I_16x16 prediction mode (from slice header parsing) ──
    input  wire [1:0]  i16_pred_mode,      // 0=V, 1=H, 2=DC, 3=Plane

    // ── Per-block coefficient input ──
    input  wire        block_valid,        // Pulse: coefficients ready
    input  wire [3:0]  block_index,        // 0-15 (H.264 raster-to-zigzag scan order)
    input  wire signed [15:0] block_coeff [0:15], // CAVLC coefficients (zigzag order)

    // ── I_16x16 DC bypass (from Hadamard transform) ──
    input  wire        i16_dc_valid,       // Hadamard DC values ready (all 16)
    input  wire signed [28:0] i16_dc [0:15], // Post-Hadamard DC for each 4x4 block

    // ── I_4x4 prediction modes (from parsing) ──
    input  wire [3:0]  i4_modes [0:15],    // Per-block intra4x4 prediction mode

    // ── Neighbour context (from w-ctl line buffer) ──
    input  wire        mb_avail_left,
    input  wire        mb_avail_top,
    input  wire        mb_avail_topright,
    input  wire        mb_avail_topleft,
    input  wire [7:0]  nb_top [0:15],      // 16 samples from MB above (top row)
    input  wire [7:0]  nb_left [0:15],     // 16 samples from MB to the left (right col)
    input  wire [7:0]  nb_topleft,         // Top-left corner sample
    input  wire [7:0]  nb_topright [0:3],  // 4 samples above-right of current 4x4

    // ── Chroma 8x8 prediction context (from w-ctl line buffer) ──
    input  wire [1:0]  chroma_pred_mode,   // 0=DC, 1=H, 2=V, 3=Plane
    input  wire [7:0]  nb_chroma_u_above [0:7],
    input  wire [7:0]  nb_chroma_v_above [0:7],
    input  wire [7:0]  nb_chroma_u_left [0:7],
    input  wire [7:0]  nb_chroma_v_left [0:7],
    input  wire [7:0]  nb_chroma_u_topleft,
    input  wire [7:0]  nb_chroma_v_topleft,
    input  wire        mb_avail_chroma_above,
    input  wire        mb_avail_chroma_left,

    // ── Chroma residual, already inverse-transformed (8.5.11 + 8.5.12) ──
    input  wire signed [15:0] chroma_residual_u [0:63],
    input  wire signed [15:0] chroma_residual_v [0:63],

    // ── Outputs ──
    output reg         mb_recon_valid,     // Pulse: full MB reconstruction complete
    output reg  [7:0]  recon_y [0:255],    // Reconstructed luma (16×16, raster order)
    output reg  [7:0]  recon_u [0:63],     // Reconstructed Cb (8×8, raster order)
    output reg  [7:0]  recon_v [0:63],     // Reconstructed Cr (8×8, raster order)
    output reg  [4:0]  blocks_done        // Running count of blocks completed
);

    // ════════════════════════════════════════════════════════════════════
    // MB TYPE DECODE
    // ════════════════════════════════════════════════════════════════════
    wire is_i_nxn  = (mb_type == 8'd0);
    wire is_i16x16 = (mb_type >= 8'd1) && (mb_type <= 8'd24);
    // wire is_ipcm   = (mb_type == 8'd25); // TODO: w-plane delivers I_PCM

    // ════════════════════════════════════════════════════════════════════
    // BLOCK SCAN ORDER — H.264 spec Table 6-10 (4x4 luma block indices)
    // Maps block_index (0-15) to x,y pixel offset within the 16×16 MB
    // ════════════════════════════════════════════════════════════════════
    function automatic [3:0] block_x_offset;
        input [3:0] idx;
        case (idx)
            4'd0:  block_x_offset = 4'd0;
            4'd1:  block_x_offset = 4'd4;
            4'd2:  block_x_offset = 4'd0;
            4'd3:  block_x_offset = 4'd4;
            4'd4:  block_x_offset = 4'd8;
            4'd5:  block_x_offset = 4'd12;
            4'd6:  block_x_offset = 4'd8;
            4'd7:  block_x_offset = 4'd12;
            4'd8:  block_x_offset = 4'd0;
            4'd9:  block_x_offset = 4'd4;
            4'd10: block_x_offset = 4'd0;
            4'd11: block_x_offset = 4'd4;
            4'd12: block_x_offset = 4'd8;
            4'd13: block_x_offset = 4'd12;
            4'd14: block_x_offset = 4'd8;
            default: block_x_offset = 4'd12;
        endcase
    endfunction

    function automatic [3:0] block_y_offset;
        input [3:0] idx;
        case (idx)
            4'd0:  block_y_offset = 4'd0;
            4'd1:  block_y_offset = 4'd0;
            4'd2:  block_y_offset = 4'd4;
            4'd3:  block_y_offset = 4'd4;
            4'd4:  block_y_offset = 4'd0;
            4'd5:  block_y_offset = 4'd0;
            4'd6:  block_y_offset = 4'd4;
            4'd7:  block_y_offset = 4'd4;
            4'd8:  block_y_offset = 4'd8;
            4'd9:  block_y_offset = 4'd8;
            4'd10: block_y_offset = 4'd12;
            4'd11: block_y_offset = 4'd12;
            4'd12: block_y_offset = 4'd8;
            4'd13: block_y_offset = 4'd8;
            4'd14: block_y_offset = 4'd12;
            default: block_y_offset = 4'd12;
        endcase
    endfunction

    // ════════════════════════════════════════════════════════════════════
    // SHARED ARITHMETIC PIPELINE (dequant → IDCT → recon)
    // ════════════════════════════════════════════════════════════════════
    reg signed [15:0]  pipe_coeff [0:15];
    reg [5:0]          pipe_qp;
    reg [7:0]          pipe_pred [0:15];
    reg [3:0]          pipe_block_idx;
    reg                pipe_valid;
    reg                pipe_is_i16;

    wire signed [28:0] dq_final [0:15];
    reg signed [28:0] latched_i16_dc [0:15];
    // I_16x16 luma blocks carry 15 AC coefficients at scan positions 1..15 and
    // take position 0 from the luma DC Hadamard, so the scaler must inverse
    // zig-zag with the DC skipped instead of treating coeff[0] as scan 0.
    h264_dequant4x4_flex u_dequant (
        .coeff(pipe_coeff),
        .qp(pipe_qp),
        .max_coeff(pipe_is_i16 ? 5'd15 : 5'd16),
        .skip_dc(pipe_is_i16),
        .dc_override(pipe_is_i16),
        .dc_value(latched_i16_dc[pipe_block_idx]),
        .dequant(dq_final)
    );

    wire signed [28:0] idct_out [0:15];
    h264_idct4x4 u_idct (
        .dequant(dq_final),
        .residual(idct_out)
    );

    wire [7:0] recon_block [0:15];
    h264_recon4x4 u_recon (
        .pred(pipe_pred),
        .residual(idct_out),
        .recon(recon_block)
    );

    // ════════════════════════════════════════════════════════════════════
    // INTRA 16×16 PREDICTION
    // ════════════════════════════════════════════════════════════════════
    wire       i16_unsupported;
    wire       i16_pred_valid;
    reg        i16_pred_ready;
    wire [7:0] i16_pred_pixels [0:255];
    h264_intra16x16_pred u_i16_pred (
        .clk(clk),
        .start(mb_start && is_i16x16),
        .mode(i16_pred_mode),
        .above(nb_top),
        .left(nb_left),
        .top_left(nb_topleft),
        .has_above(mb_avail_top),
        .has_left(mb_avail_left),
        .unsupported(i16_unsupported),
        .valid(i16_pred_valid),
        .pred(i16_pred_pixels)
    );

    // ════════════════════════════════════════════════════════════════════
    // CHROMA 8×8 PREDICTION + RESIDUAL
    // ════════════════════════════════════════════════════════════════════
    // Both chroma components share the 16×16 macroblock's prediction mode and
    // are reconstructed as clip(pred + residual) when the luma blocks finish.
    wire       chroma_u_pred_valid;
    wire       chroma_v_pred_valid;
    wire [7:0] chroma_u_pred [0:63];
    wire [7:0] chroma_v_pred [0:63];

    h264_chroma8x8_pred u_chroma_u_pred (
        .clk(clk),
        .start(mb_start),
        .mode(chroma_pred_mode),
        .above(nb_chroma_u_above),
        .left(nb_chroma_u_left),
        .top_left(nb_chroma_u_topleft),
        .has_above(mb_avail_chroma_above),
        .has_left(mb_avail_chroma_left),
        .valid(chroma_u_pred_valid),
        .pred(chroma_u_pred)
    );

    h264_chroma8x8_pred u_chroma_v_pred (
        .clk(clk),
        .start(mb_start),
        .mode(chroma_pred_mode),
        .above(nb_chroma_v_above),
        .left(nb_chroma_v_left),
        .top_left(nb_chroma_v_topleft),
        .has_above(mb_avail_chroma_above),
        .has_left(mb_avail_chroma_left),
        .valid(chroma_v_pred_valid),
        .pred(chroma_v_pred)
    );

    function automatic [7:0] clip_chroma;
        input signed [17:0] v;
        begin
            if (v < 18'sd0) clip_chroma = 8'd0;
            else if (v > 18'sd255) clip_chroma = 8'd255;
            else clip_chroma = v[7:0];
        end
    endfunction

    // ════════════════════════════════════════════════════════════════════
    // INTRA 4×4 PREDICTION — uses per-block reconstructed neighbours
    // ════════════════════════════════════════════════════════════════════
    // For each 4×4 block, we need the 4 samples above, 4 to the left,
    // top-left corner, and optionally 4 above-right.
    // These come from either the MB-level neighbours or from already-
    // reconstructed blocks within this MB.

    // Local reconstruction store — as blocks complete, their samples
    // become available as neighbours for subsequent blocks
    reg [7:0] local_recon [0:255];

    // Per-block neighbour derivation
    reg [7:0] blk_above [0:7]; // 4 above + 4 above-right
    reg [7:0] blk_left [0:3];
    reg [7:0] blk_top_left;
    reg       blk_has_above, blk_has_left;

    wire [3:0] i4_used_mode;
    wire [7:0] i4_pred_pixels [0:15];
    h264_intra4x4_pred u_i4_pred (
        .mode(i4_modes[pipe_block_idx]),
        .above(blk_above),
        .left(blk_left),
        .top_left(blk_top_left),
        .has_above(blk_has_above),
        .has_left(blk_has_left),
        .used_mode(i4_used_mode),
        .pred(i4_pred_pixels)
    );

    // ════════════════════════════════════════════════════════════════════
    // BLOCK NEIGHBOUR DERIVATION
    // Determines above/left/topleft samples for each 4×4 block within
    // the macroblock, sourcing from either MB-level neighbours or from
    // already-reconstructed local blocks.
    //
    // H.264 above-right availability (Table 6-3): NOT available for
    // blocks 3, 7, 11, 13, 15 (right-edge or not-yet-decoded).
    // When unavailable, replicate above[3] → above[4:7].
    // ════════════════════════════════════════════════════════════════════
    reg [3:0] cur_bx, cur_by; // pixel x,y of current block's top-left within MB

    // Above-right availability within the MB (H.264 spec constraint)
    // In 4×4-block units: above-right is at (bx4+1, by4-1)
    // NOT available when: bx4==3 (right edge), or block not yet decoded
    function automatic above_right_avail;
        input [3:0] bidx;
        case (bidx)
            4'd3:  above_right_avail = 1'b0; // AR block 4 not yet decoded
            4'd7:  above_right_avail = 1'b0; // AR outside MB (right edge)
            4'd11: above_right_avail = 1'b0; // AR block 12 not yet decoded
            4'd13: above_right_avail = 1'b0; // AR outside MB (right edge)
            4'd15: above_right_avail = 1'b0; // AR outside MB (right edge)
            default: above_right_avail = 1'b1;
        endcase
    endfunction

    integer ni;
    always @* begin
        cur_bx = block_x_offset(pipe_block_idx);
        cur_by = block_y_offset(pipe_block_idx);

        // Default: no neighbours
        blk_has_above = 1'b0;
        blk_has_left  = 1'b0;
        blk_top_left  = 8'd128;
        for (ni = 0; ni < 8; ni = ni + 1) blk_above[ni] = 8'd128;
        for (ni = 0; ni < 4; ni = ni + 1) blk_left[ni] = 8'd128;

        // ABOVE (4 samples from row cur_by-1, columns cur_bx to cur_bx+3)
        if (cur_by != 4'd0) begin
            // Within-MB: use already-decoded block above
            blk_has_above = 1'b1;
            for (ni = 0; ni < 4; ni = ni + 1)
                blk_above[ni] = local_recon[({cur_by - 4'd1, cur_bx} + ni[7:0])];
            // Above-right: only if available per H.264 spec
            if (above_right_avail(pipe_block_idx) && cur_bx < 4'd12)
                for (ni = 0; ni < 4; ni = ni + 1)
                    blk_above[4 + ni] = local_recon[({cur_by - 4'd1, cur_bx + 4'd4} + ni[7:0])];
            else
                for (ni = 0; ni < 4; ni = ni + 1)
                    blk_above[4 + ni] = blk_above[3]; // replicate last
        end else begin
            // Top row of MB: use MB-level above neighbour
            if (mb_avail_top) begin
                blk_has_above = 1'b1;
                for (ni = 0; ni < 4; ni = ni + 1)
                    blk_above[ni] = nb_top[{cur_bx} + ni[3:0]];
                // Above-right from MB above
                if (above_right_avail(pipe_block_idx) && cur_bx < 4'd12)
                    for (ni = 0; ni < 4; ni = ni + 1)
                        blk_above[4 + ni] = nb_top[{cur_bx + 4'd4} + ni[3:0]];
                else if (above_right_avail(pipe_block_idx) && mb_avail_topright)
                    for (ni = 0; ni < 4; ni = ni + 1)
                        blk_above[4 + ni] = nb_topright[ni];
                else
                    for (ni = 0; ni < 4; ni = ni + 1)
                        blk_above[4 + ni] = blk_above[3];
            end
        end

        // LEFT (4 samples from column cur_bx-1, rows cur_by to cur_by+3)
        if (cur_bx != 4'd0) begin
            // Within-MB: use already-decoded block to the left
            blk_has_left = 1'b1;
            for (ni = 0; ni < 4; ni = ni + 1)
                blk_left[ni] = local_recon[{cur_by + ni[3:0], cur_bx - 4'd1}];
        end else begin
            // Left edge of MB: use MB-level left neighbour
            if (mb_avail_left) begin
                blk_has_left = 1'b1;
                for (ni = 0; ni < 4; ni = ni + 1)
                    blk_left[ni] = nb_left[{cur_by} + ni[3:0]];
            end
        end

        // TOP-LEFT corner
        if (cur_bx != 4'd0 && cur_by != 4'd0) begin
            blk_top_left = local_recon[{cur_by - 4'd1, cur_bx - 4'd1}];
        end else if (cur_bx == 4'd0 && cur_by != 4'd0) begin
            if (mb_avail_left)
                blk_top_left = nb_left[{cur_by} - 4'd1];
            else
                blk_top_left = 8'd128;
        end else if (cur_bx != 4'd0 && cur_by == 4'd0) begin
            if (mb_avail_top)
                blk_top_left = nb_top[{cur_bx} - 4'd1];
            else
                blk_top_left = 8'd128;
        end else begin
            // top-left corner of MB
            if (mb_avail_topleft)
                blk_top_left = nb_topleft;
            else
                blk_top_left = 8'd128;
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // PREDICTION MUX — select I_16x16 or I_4x4 prediction for this block
    // ════════════════════════════════════════════════════════════════════
    integer pi;
    always @* begin
        if (pipe_is_i16) begin
            // I_16x16: take 4×4 slice from the full 16×16 prediction
            for (pi = 0; pi < 4; pi = pi + 1)
                for (ni = 0; ni < 4; ni = ni + 1)
                    pipe_pred[pi*4 + ni] = i16_pred_pixels[({cur_by + pi[3:0], cur_bx + ni[3:0]})];
        end else begin
            // I_4x4: per-block prediction
            for (pi = 0; pi < 16; pi = pi + 1)
                pipe_pred[pi] = i4_pred_pixels[pi];
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // SEQUENCING — process blocks one at a time, store results
    // ════════════════════════════════════════════════════════════════════
    localparam [1:0] ST_IDLE  = 2'd0,
                     ST_BLOCK = 2'd1,
                     ST_STORE = 2'd2,
                     ST_DONE  = 2'd3;

    reg [1:0] state;
    reg       mb_started;

    integer si;
    always @(posedge clk) begin
        if (reset) begin
            state         <= ST_IDLE;
            mb_recon_valid <= 1'b0;
            blocks_done   <= 5'd0;
            pipe_valid    <= 1'b0;
            mb_started    <= 1'b0;
            pipe_is_i16   <= 1'b0;
            i16_pred_ready <= 1'b0;
            pipe_block_idx <= 4'd0;
            pipe_qp       <= 6'd0;
            for (si = 0; si < 16; si = si + 1) begin
                pipe_coeff[si] <= 16'sd0;
                latched_i16_dc[si] <= 29'sd0;
            end
            for (si = 0; si < 256; si = si + 1) begin
                local_recon[si] <= 8'd0;
                recon_y[si]     <= 8'd0;
            end
            for (si = 0; si < 64; si = si + 1) begin
                recon_u[si] <= 8'd128;
                recon_v[si] <= 8'd128;
            end
        end else begin
            mb_recon_valid <= 1'b0;
            if (i16_pred_valid)
                i16_pred_ready <= 1'b1;

            // Latch I_16x16 DC values when provided
            if (i16_dc_valid)
                for (si = 0; si < 16; si = si + 1)
                    latched_i16_dc[si] <= i16_dc[si];

            // MB start: reset block counter
            if (mb_start) begin
                blocks_done <= 5'd0;
                mb_started  <= 1'b1;
                pipe_is_i16 <= is_i16x16;
                i16_pred_ready <= !is_i16x16;
                pipe_qp     <= mb_qp_y;
            end

            case (state)
                ST_IDLE: begin
                    if (block_valid && mb_started && (!pipe_is_i16 || i16_pred_ready)) begin
                        // Latch coefficients and block index
                        for (si = 0; si < 16; si = si + 1)
                            pipe_coeff[si] <= block_coeff[si];
                        pipe_block_idx <= block_index;
                        pipe_valid     <= 1'b1;
                        state          <= ST_STORE;
                    end
                end

                ST_STORE: begin
                    // Pipeline is combinational — results ready THIS cycle
                    // Store reconstructed 4×4 block into local buffer
                    pipe_valid <= 1'b0;
                    for (si = 0; si < 4; si = si + 1)
                        for (ni = 0; ni < 4; ni = ni + 1) begin
                            local_recon[{cur_by + si[3:0], cur_bx + ni[3:0]}] <=
                                recon_block[si*4 + ni];
                        end
                    blocks_done <= blocks_done + 5'd1;

                    if (blocks_done == 5'd15) begin
                        // All 16 luma blocks done — output full MB
                        state <= ST_DONE;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                ST_DONE: begin
                    // Copy local_recon to output
                    for (si = 0; si < 256; si = si + 1)
                        recon_y[si] <= local_recon[si];
                    for (si = 0; si < 64; si = si + 1) begin
                        recon_u[si] <= clip_chroma($signed({10'd0, chroma_u_pred[si]}) +
                                                   $signed(chroma_residual_u[si]));
                        recon_v[si] <= clip_chroma($signed({10'd0, chroma_v_pred[si]}) +
                                                   $signed(chroma_residual_v[si]));
                    end
                    mb_recon_valid <= 1'b1;
                    mb_started     <= 1'b0;
                    state          <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
