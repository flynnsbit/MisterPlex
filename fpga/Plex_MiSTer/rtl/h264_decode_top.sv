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
// AREA NOTE (fit HARD_FAIL, 248% ALM): this module was the second biggest
// offender at ~19.2k ALUTs. The cost was NOT the arithmetic, it was random
// PARALLEL access into the 256-entry local reconstruction array:
//   * thirteen simultaneous neighbour taps  = thirteen 256:1 byte muxes,
//   * sixteen simultaneous stores           = 256 wide write muxes,
//   * sixteen simultaneous I16 plane taps   = sixteen more 256:1 byte muxes.
// All three are now SEQUENTIAL: one read address and one write address per
// cycle, so the array collapses to a single read mux plus a one-hot write
// decoder. Roughly 30 cycles per 4×4 block instead of 2; latency is negotiable
// here, area is not.
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

    // ── Outputs ──
    output reg         mb_recon_valid,     // Pulse: full MB reconstruction complete
    output reg  [7:0]  recon_y [0:255],    // Reconstructed luma (16×16, raster order)
    output reg  [4:0]  blocks_done        // Running count of blocks completed
);

    // ════════════════════════════════════════════════════════════════════
    // MB TYPE DECODE
    // ════════════════════════════════════════════════════════════════════
    wire is_i16x16 = (mb_type >= 8'd1) && (mb_type <= 8'd24);

    // ════════════════════════════════════════════════════════════════════
    // BLOCK SCAN ORDER — H.264 spec Table 6-10 (4x4 luma block indices).
    // The table is a bit interleave, so it is free as a wire permutation:
    //   x = {idx[2], idx[0], 2'b00}, y = {idx[3], idx[1], 2'b00}
    // ════════════════════════════════════════════════════════════════════
    function automatic [3:0] block_x_offset;
        input [3:0] idx;
        block_x_offset = {idx[2], idx[0], 2'b00};
    endfunction

    function automatic [3:0] block_y_offset;
        input [3:0] idx;
        block_y_offset = {idx[3], idx[1], 2'b00};
    endfunction

    // ════════════════════════════════════════════════════════════════════
    // SHARED ARITHMETIC PIPELINE (dequant → IDCT → recon)
    // ════════════════════════════════════════════════════════════════════
    reg signed [15:0]  pipe_coeff [0:15];
    reg [5:0]          pipe_qp;
    reg [7:0]          pipe_pred [0:15];
    reg [3:0]          pipe_block_idx;
    reg                pipe_is_i16;

    reg signed [28:0] latched_i16_dc [0:15];
    // I_16x16 luma blocks carry 15 AC coefficients at scan positions 1..15 and
    // take position 0 from the luma DC Hadamard, so the scaler must inverse
    // zig-zag with the DC skipped instead of treating coeff[0] as scan 0.
    // AREA: sequential one-scaler/one-butterfly replaces combo dequant+IDCT
    // (~6.5k ALUTs on the failed 115% fit) with ~20 cycles reuse.
    reg                xform_start;
    reg                xform_ready;
    wire               xform_done;
    wire signed [28:0] idct_out [0:15];
    h264_iq_idct_seq u_iqidct (
        .clk(clk),
        .reset(reset),
        .start(xform_start),
        .coeff(pipe_coeff),
        .qp(pipe_qp),
        .max_coeff(pipe_is_i16 ? 5'd15 : 5'd16),
        .skip_dc(pipe_is_i16),
        .dc_override(pipe_is_i16),
        .dc_value(latched_i16_dc[pipe_block_idx]),
        .residual(idct_out),
        .done(xform_done)
    );

    wire [7:0] recon_block [0:15];
    h264_recon4x4 u_recon (
        .pred(pipe_pred),
        .residual(idct_out),
        .recon(recon_block)
    );

    // ════════════════════════════════════════════════════════════════════
    // INTRA 16×16 PREDICTION
    // The plane is read back one sample per cycle in ST_I16FETCH, so there is
    // exactly one 256:1 tap here instead of sixteen.
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
    // INTRA 4×4 PREDICTION — uses per-block reconstructed neighbours
    // ════════════════════════════════════════════════════════════════════
    // Local reconstruction store. ONE read address and ONE write address:
    // that is what keeps it out of the ALUT budget.
    reg  [7:0] local_recon [0:255];
    reg  [7:0] blk_above [0:7]; // 4 above + 4 above-right
    reg  [7:0] blk_left [0:3];
    reg  [7:0] blk_top_left;
    reg        blk_has_above, blk_has_left;

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
    // Sources above/left/topleft samples for each 4×4 block from either the
    // MB-level neighbours or already-reconstructed local blocks.
    //
    // H.264 above-right availability (Table 6-3): NOT available for blocks
    // 3, 7, 11, 13, 15 (right-edge or not-yet-decoded). When unavailable,
    // replicate above[3] → above[4:7]; skipping that substitution is the
    // classic source of corner artifacts.
    // ════════════════════════════════════════════════════════════════════
    wire [3:0] cur_bx = block_x_offset(pipe_block_idx);
    wire [3:0] cur_by = block_y_offset(pipe_block_idx);

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

    wire ar_in_mb = above_right_avail(pipe_block_idx) && (cur_bx < 4'd12);
    wire ar_from_topright = above_right_avail(pipe_block_idx) && (cur_bx >= 4'd12) &&
                            (cur_by == 4'd0) && mb_avail_top && mb_avail_topright;

    // Sequential neighbour walk: 0..3 above, 4..7 above-right, 8..11 left,
    // 12 top-left.
    reg  [3:0] nbc;
    wire [1:0] nb_sub    = nbc[1:0];
    wire [3:0] nb_col_a  = cur_bx + {2'd0, nb_sub};
    wire [3:0] nb_col_ar = cur_bx + 4'd4 + {2'd0, nb_sub};
    wire [3:0] nb_row_l  = cur_by + {2'd0, nb_sub};

    reg  [7:0] nb_addr;
    reg  [7:0] nb_ext;      // value when the tap does not come from local_recon
    reg        nb_use_local;
    always @* begin
        nb_addr      = 8'd0;
        nb_ext       = 8'd128;
        nb_use_local = 1'b0;
        if (nbc <= 4'd3) begin
            if (cur_by != 4'd0) begin
                nb_use_local = 1'b1;
                nb_addr = {cur_by - 4'd1, nb_col_a};
            end else if (mb_avail_top) begin
                nb_ext = nb_top[nb_col_a];
            end
        end else if (nbc <= 4'd7) begin
            if (ar_from_topright) begin
                nb_ext = nb_topright[nb_sub];
            end else if (!ar_in_mb) begin
                nb_ext = blk_above[3];
            end else if (cur_by != 4'd0) begin
                nb_use_local = 1'b1;
                nb_addr = {cur_by - 4'd1, nb_col_ar};
            end else if (mb_avail_top) begin
                nb_ext = nb_top[nb_col_ar];
            end else begin
                nb_ext = blk_above[3];
            end
        end else if (nbc <= 4'd11) begin
            if (cur_bx != 4'd0) begin
                nb_use_local = 1'b1;
                nb_addr = {nb_row_l, cur_bx - 4'd1};
            end else if (mb_avail_left) begin
                nb_ext = nb_left[nb_row_l];
            end
        end else begin
            if (cur_bx != 4'd0 && cur_by != 4'd0) begin
                nb_use_local = 1'b1;
                nb_addr = {cur_by - 4'd1, cur_bx - 4'd1};
            end else if (cur_bx == 4'd0 && cur_by != 4'd0) begin
                if (mb_avail_left) nb_ext = nb_left[cur_by - 4'd1];
            end else if (cur_bx != 4'd0 && cur_by == 4'd0) begin
                if (mb_avail_top) nb_ext = nb_top[cur_bx - 4'd1];
            end else begin
                if (mb_avail_topleft) nb_ext = nb_topleft;
            end
        end
    end

    // The single read port into local_recon.
    wire [7:0] lr_rd_data = local_recon[nb_addr];
    wire [7:0] nb_value = nb_use_local ? lr_rd_data : nb_ext;

    // ════════════════════════════════════════════════════════════════════
    // SEQUENCING — one 4×4 block at a time
    //   ST_NBFETCH  13 cycles: gather the intra 4×4 neighbour taps
    //   ST_PREDCAP   1 cycle : latch the 16 predicted samples
    //   ST_I16FETCH 16 cycles: gather this block's slice of the I16 plane
    //   ST_STORE    16 cycles: write the reconstructed samples back
    // ════════════════════════════════════════════════════════════════════
    localparam [2:0] ST_IDLE     = 3'd0,
                     ST_NBFETCH  = 3'd1,
                     ST_PREDCAP  = 3'd2,
                     ST_I16FETCH = 3'd3,
                     ST_STORE    = 3'd4,
                     ST_DONE     = 3'd5,
                     ST_XFORM    = 3'd6;

    reg [2:0] state;
    reg       mb_started;
    reg [3:0] wcnt;

    // One-deep skid so a block arriving while the previous one is still being
    // written back is not dropped now that a block takes ~30 cycles.
    reg               skid_full;
    reg signed [15:0] skid_coeff [0:15];
    reg [3:0]         skid_index;

    wire busy = (state != ST_IDLE);
    wire launch_ok = mb_started && (!pipe_is_i16 || i16_pred_ready);

    // Store / I16-fetch walk: {cur_by + wcnt[3:2], cur_bx + wcnt[1:0]}
    wire [7:0] walk_addr = {cur_by + {2'd0, wcnt[3:2]}, cur_bx + {2'd0, wcnt[1:0]}};

    integer si;
    always @(posedge clk) begin
        if (reset) begin
            state          <= ST_IDLE;
            mb_recon_valid <= 1'b0;
            blocks_done    <= 5'd0;
            mb_started     <= 1'b0;
            pipe_is_i16    <= 1'b0;
            i16_pred_ready <= 1'b0;
            pipe_block_idx <= 4'd0;
            pipe_qp        <= 6'd0;
            nbc            <= 4'd0;
            wcnt           <= 4'd0;
            xform_start    <= 1'b0;
            xform_ready    <= 1'b0;
            skid_full      <= 1'b0;
            skid_index     <= 4'd0;
            blk_has_above  <= 1'b0;
            blk_has_left   <= 1'b0;
            blk_top_left   <= 8'd128;
            for (si = 0; si < 8; si = si + 1) blk_above[si] <= 8'd128;
            for (si = 0; si < 4; si = si + 1) blk_left[si] <= 8'd128;
            for (si = 0; si < 16; si = si + 1) begin
                pipe_coeff[si] <= 16'sd0;
                skid_coeff[si] <= 16'sd0;
                pipe_pred[si]  <= 8'd128;
                latched_i16_dc[si] <= 29'sd0;
            end
            for (si = 0; si < 256; si = si + 1) begin
                local_recon[si] <= 8'd0;
                recon_y[si]     <= 8'd0;
            end
        end else begin
            mb_recon_valid <= 1'b0;
            xform_start    <= 1'b0;
            if (xform_done)
                xform_ready <= 1'b1;
            if (i16_pred_valid)
                i16_pred_ready <= 1'b1;

            if (i16_dc_valid)
                for (si = 0; si < 16; si = si + 1)
                    latched_i16_dc[si] <= i16_dc[si];

            if (mb_start) begin
                blocks_done    <= 5'd0;
                mb_started     <= 1'b1;
                pipe_is_i16    <= is_i16x16;
                i16_pred_ready <= !is_i16x16;
                pipe_qp        <= mb_qp_y;
                skid_full      <= 1'b0;
            end else if (block_valid && busy && !skid_full) begin
                skid_full  <= 1'b1;
                skid_index <= block_index;
                for (si = 0; si < 16; si = si + 1)
                    skid_coeff[si] <= block_coeff[si];
            end

            case (state)
                ST_IDLE: begin
                    if (launch_ok && (skid_full || block_valid)) begin
                        for (si = 0; si < 16; si = si + 1)
                            pipe_coeff[si] <= skid_full ? skid_coeff[si] : block_coeff[si];
                        pipe_block_idx <= skid_full ? skid_index : block_index;
                        skid_full      <= 1'b0;
                        nbc            <= 4'd0;
                        wcnt           <= 4'd0;
                        xform_start    <= 1'b1;
                        xform_ready    <= 1'b0;
                        state          <= pipe_is_i16 ? ST_I16FETCH : ST_NBFETCH;
                    end
                end

                ST_NBFETCH: begin
                    // Availability only depends on position, so latch it once.
                    if (nbc == 4'd0) begin
                        blk_has_above <= (cur_by != 4'd0) || mb_avail_top;
                        blk_has_left  <= (cur_bx != 4'd0) || mb_avail_left;
                    end
                    if (nbc <= 4'd7)       blk_above[nbc[2:0]] <= nb_value;
                    else if (nbc <= 4'd11) blk_left[nbc[1:0]]  <= nb_value;
                    else                   blk_top_left        <= nb_value;
                    if (nbc == 4'd12) state <= ST_PREDCAP;
                    else              nbc   <= nbc + 4'd1;
                end

                ST_PREDCAP: begin
                    // h264_intra4x4_pred is combinational over the registered
                    // taps, so one cycle after the last tap lands it is stable.
                    for (si = 0; si < 16; si = si + 1)
                        pipe_pred[si] <= i4_pred_pixels[si];
                    wcnt  <= 4'd0;
                    state <= ST_XFORM;
                end

                ST_I16FETCH: begin
                    pipe_pred[wcnt] <= i16_pred_pixels[walk_addr];
                    if (wcnt == 4'd15) begin
                        wcnt  <= 4'd0;
                        state <= ST_XFORM;
                    end else begin
                        wcnt <= wcnt + 4'd1;
                    end
                end

                // Scaler runs in parallel with neighbour/plane walk; wait out residual.
                ST_XFORM: if (xform_ready || xform_done) begin
                    wcnt  <= 4'd0;
                    state <= ST_STORE;
                end

                ST_STORE: begin
                    // residual is registered in the sequential engine; pred stable.
                    local_recon[walk_addr] <= recon_block[wcnt];
                    recon_y[walk_addr]     <= recon_block[wcnt];
                    if (wcnt == 4'd15) begin
                        blocks_done <= blocks_done + 5'd1;
                        state <= (blocks_done == 5'd15) ? ST_DONE : ST_IDLE;
                    end else begin
                        wcnt <= wcnt + 4'd1;
                    end
                end

                ST_DONE: begin
                    mb_recon_valid <= 1'b1;
                    mb_started     <= 1'b0;
                    state          <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    (* keep = 1 *) wire _keep_decode_top_unused =
        i16_unsupported | (|i4_used_mode) | (|mb_x) | (|mb_y);

endmodule

`default_nettype wire
