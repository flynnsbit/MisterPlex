// h264_decode_top — Real intra macroblock decode datapath.
//
// Processes all 16 luma 4×4 blocks of a macroblock sequentially through a
// shared dequant → IDCT → recon pipeline.
//
// AREA: random parallel access into a 256-byte reconstruction array was the
// bulk of the old 19k-ALUT cost (neighbour taps + store + I16 plane slice).
// Everything is sequential now: one read address and one write address per
// cycle into a single M10K, plus a streaming sample port so the parent does
// not need a second parallel copy of the plane.
//
// OWNER: w-rel.

`default_nettype none

module h264_decode_top (
    input  wire        clk,
    input  wire        reset,

    input  wire        mb_start,
    input  wire [7:0]  mb_type,
    input  wire [5:0]  mb_qp_y,
    input  wire [7:0]  mb_x,
    input  wire [7:0]  mb_y,

    input  wire [1:0]  i16_pred_mode,

    input  wire        block_valid,
    input  wire [3:0]  block_index,
    input  wire signed [15:0] block_coeff [0:15],

    input  wire        i16_dc_valid,
    input  wire signed [28:0] i16_dc [0:15],

    input  wire [3:0]  i4_modes [0:15],

    input  wire        mb_avail_left,
    input  wire        mb_avail_top,
    input  wire        mb_avail_topright,
    input  wire        mb_avail_topleft,
    input  wire [7:0]  nb_top [0:15],
    input  wire [7:0]  nb_left [0:15],
    input  wire [7:0]  nb_topleft,
    input  wire [7:0]  nb_topright [0:3],

    // Streaming PRE-deblock recon (one sample / cycle during store walk).
    output reg         recon_sample_valid,
    output reg  [7:0]  recon_sample_idx,
    output reg  [7:0]  recon_sample,
    // Per-4x4 block commit for neighbour context (16 samples, raster 4x4).
    output reg         block_recon_valid,
    output reg  [3:0]  block_recon_idx,
    output reg  [7:0]  block_recon_pixels [0:15],
    // MB complete pulse (line-buffer commit edge).
    output reg         mb_recon_valid,
    output reg  [4:0]  blocks_done
);

    wire is_i16x16 = (mb_type >= 8'd1) && (mb_type <= 8'd24);

    function automatic [3:0] block_x_offset;
        input [3:0] idx;
        block_x_offset = {idx[2], idx[0], 2'b00};
    endfunction

    function automatic [3:0] block_y_offset;
        input [3:0] idx;
        block_y_offset = {idx[3], idx[1], 2'b00};
    endfunction

    reg signed [15:0]  pipe_coeff [0:15];
    reg [5:0]          pipe_qp;
    reg [7:0]          pipe_pred [0:15];
    reg [3:0]          pipe_block_idx;
    reg                pipe_is_i16;

    reg signed [28:0] latched_i16_dc [0:15];
    reg                xform_start;
    reg                xform_ready;
    wire               xform_done;
    wire signed [28:0] idct_out [0:15];

    // AREA: one sequential scaler + one shared butterfly instead of the
    // combinational h264_dequant4x4_flex + h264_idct4x4 pair, which cost
    // ~4.5k ALUTs and 16 DSP blocks to finish in one cycle work that this
    // block-serial walk only issues once every ~30 cycles.
    // Hadamard DC plane is raster {y4,x4}; block_index is H.264 blkIdx
    // (x={b[2],b[0]}, y={b[3],b[1]}).  Wrong map → flat-looking wrong brightness.
    wire [1:0] pipe_x4 = {pipe_block_idx[2], pipe_block_idx[0]};
    wire [1:0] pipe_y4 = {pipe_block_idx[3], pipe_block_idx[1]};
    wire [3:0] pipe_dc_raster = {pipe_y4, pipe_x4};

    h264_iq_idct_seq u_iqidct (
        .clk(clk),
        .reset(reset),
        .start(xform_start),
        .coeff(pipe_coeff),
        .qp(pipe_qp),
        .max_coeff(pipe_is_i16 ? 5'd15 : 5'd16),
        .skip_dc(pipe_is_i16),
        .dc_override(pipe_is_i16),
        .dc_value(latched_i16_dc[pipe_dc_raster]),
        .residual(idct_out),
        .done(xform_done)
    );

    wire [7:0] recon_block [0:15];
    h264_recon4x4 u_recon (
        .pred(pipe_pred),
        .residual(idct_out),
        .recon(recon_block)
    );

    wire       i16_unsupported;
    wire       i16_pred_valid;
    reg        i16_pred_ready;
    wire [7:0] i16_rd_data;
    reg  [4:0] fcnt;
    wire [7:0] i16_addr = {cur_by + {2'd0, fcnt[3:2]}, cur_bx + {2'd0, fcnt[1:0]}};
    // PARALLEL_OUT=0: the plane lives in an M10K inside the predictor and is
    // walked one sample per cycle, so there is no 256:1 byte mux here.
    h264_intra16x16_pred #(.PARALLEL_OUT(0)) u_i16_pred (
        .clk(clk),
        .start(mb_start && is_i16x16),
        .mode(i16_pred_mode),
        .above(nb_top),
        .left(nb_left),
        .top_left(nb_topleft),
        .has_above(mb_avail_top),
        .has_left(mb_avail_left),
        .rd_addr(i16_addr),
        .rd_data(i16_rd_data),
        .unsupported(i16_unsupported),
        .valid(i16_pred_valid)
    );

    // Single M10K reconstruction store. Sync read: address one cycle early.
    (* ramstyle = "M10K" *) reg [7:0] recon_mem [0:255];
    reg  [7:0] mem_raddr;
    reg  [7:0] mem_rdata;
    reg  [7:0] mem_waddr;
    reg  [7:0] mem_wdata;
    reg        mem_we;

    always @(posedge clk) begin
        mem_rdata <= recon_mem[mem_raddr];
        if (mem_we)
            recon_mem[mem_waddr] <= mem_wdata;
    end

    reg  [7:0] blk_above [0:7];
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

    wire [3:0] cur_bx = block_x_offset(pipe_block_idx);
    wire [3:0] cur_by = block_y_offset(pipe_block_idx);

    function automatic above_right_avail;
        input [3:0] bidx;
        case (bidx)
            4'd3, 4'd7, 4'd11, 4'd13, 4'd15: above_right_avail = 1'b0;
            default: above_right_avail = 1'b1;
        endcase
    endfunction

    wire ar_in_mb = above_right_avail(pipe_block_idx) && (cur_bx < 4'd12);
    wire ar_from_topright = above_right_avail(pipe_block_idx) && (cur_bx >= 4'd12) &&
                            (cur_by == 4'd0) && mb_avail_top && mb_avail_topright;

    // Neighbour walk: 13 taps × 2 phases (ADDR then CAPTURE) for sync RAM.
    reg  [4:0] nbc;
    wire [3:0] tap_i   = nbc[4:1];
    wire       tap_cap = nbc[0];
    wire [1:0] nb_sub  = tap_i[1:0];
    wire [3:0] nb_col_a  = cur_bx + {2'd0, nb_sub};
    wire [3:0] nb_col_ar = cur_bx + 4'd4 + {2'd0, nb_sub};
    wire [3:0] nb_row_l  = cur_by + {2'd0, nb_sub};

    reg  [7:0] nb_addr;
    reg  [7:0] nb_ext;
    reg        nb_use_mem;
    always @* begin
        nb_addr    = 8'd0;
        nb_ext     = 8'd128;
        nb_use_mem = 1'b0;
        if (tap_i <= 4'd3) begin
            if (cur_by != 4'd0) begin
                nb_use_mem = 1'b1;
                nb_addr = {cur_by - 4'd1, nb_col_a};
            end else if (mb_avail_top) begin
                nb_ext = nb_top[nb_col_a];
            end
        end else if (tap_i <= 4'd7) begin
            if (ar_from_topright) begin
                nb_ext = nb_topright[nb_sub];
            end else if (!ar_in_mb) begin
                nb_ext = blk_above[3];
            end else if (cur_by != 4'd0) begin
                nb_use_mem = 1'b1;
                nb_addr = {cur_by - 4'd1, nb_col_ar};
            end else if (mb_avail_top) begin
                nb_ext = nb_top[nb_col_ar];
            end else begin
                nb_ext = blk_above[3];
            end
        end else if (tap_i <= 4'd11) begin
            if (cur_bx != 4'd0) begin
                nb_use_mem = 1'b1;
                nb_addr = {nb_row_l, cur_bx - 4'd1};
            end else if (mb_avail_left) begin
                nb_ext = nb_left[nb_row_l];
            end
        end else begin
            if (cur_bx != 4'd0 && cur_by != 4'd0) begin
                nb_use_mem = 1'b1;
                nb_addr = {cur_by - 4'd1, cur_bx - 4'd1};
            end else if (cur_bx == 4'd0 && cur_by != 4'd0) begin
                if (mb_avail_left) nb_ext = nb_left[cur_by - 4'd1];
            end else if (cur_bx != 4'd0 && cur_by == 4'd0) begin
                if (mb_avail_top) nb_ext = nb_top[cur_bx - 4'd1];
            end else if (mb_avail_topleft) begin
                nb_ext = nb_topleft;
            end
        end
    end

    wire [7:0] nb_value = nb_use_mem ? mem_rdata : nb_ext;

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

    reg               skid_full;
    reg signed [15:0] skid_coeff [0:15];
    reg [3:0]         skid_index;

    wire busy = (state != ST_IDLE);
    wire launch_ok = mb_started && (!pipe_is_i16 || i16_pred_ready);

    wire [7:0] walk_addr = {cur_by + {2'd0, wcnt[3:2]}, cur_bx + {2'd0, wcnt[1:0]}};

    integer si;
    always @(posedge clk) begin
        recon_sample_valid <= 1'b0;
        block_recon_valid  <= 1'b0;
        mb_recon_valid     <= 1'b0;
        mem_we             <= 1'b0;

        if (reset) begin
            state          <= ST_IDLE;
            blocks_done    <= 5'd0;
            mb_started     <= 1'b0;
            pipe_is_i16    <= 1'b0;
            i16_pred_ready <= 1'b0;
            pipe_block_idx <= 4'd0;
            pipe_qp        <= 6'd0;
            nbc            <= 5'd0;
            wcnt           <= 4'd0;
            fcnt           <= 5'd0;
            xform_start    <= 1'b0;
            xform_ready    <= 1'b0;
            skid_full      <= 1'b0;
            skid_index     <= 4'd0;
            blk_has_above  <= 1'b0;
            blk_has_left   <= 1'b0;
            blk_top_left   <= 8'd128;
            mem_raddr      <= 8'd0;
            mem_waddr      <= 8'd0;
            mem_wdata      <= 8'd0;
            block_recon_idx  <= 4'd0;
            recon_sample_idx <= 8'd0;
            recon_sample     <= 8'd0;
            for (si = 0; si < 8; si = si + 1) blk_above[si] <= 8'd128;
            for (si = 0; si < 4; si = si + 1) blk_left[si] <= 8'd128;
            for (si = 0; si < 16; si = si + 1) begin
                pipe_coeff[si] <= 16'sd0;
                skid_coeff[si] <= 16'sd0;
                pipe_pred[si]  <= 8'd128;
                latched_i16_dc[si] <= 29'sd0;
                block_recon_pixels[si] <= 8'd128;
            end
        end else begin
            xform_start <= 1'b0;
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
                        nbc            <= 5'd0;
                        wcnt           <= 4'd0;
                        fcnt           <= 5'd0;
                        xform_start    <= 1'b1;
                        xform_ready    <= 1'b0;
                        state          <= pipe_is_i16 ? ST_I16FETCH : ST_NBFETCH;
                    end
                end

                ST_NBFETCH: begin
                    if (!tap_cap) begin
                        if (tap_i == 4'd0) begin
                            blk_has_above <= (cur_by != 4'd0) || mb_avail_top;
                            blk_has_left  <= (cur_bx != 4'd0) || mb_avail_left;
                        end
                        if (nb_use_mem)
                            mem_raddr <= nb_addr;
                        nbc <= nbc + 5'd1;
                    end else begin
                        if (tap_i <= 4'd7)
                            blk_above[tap_i[2:0]] <= nb_value;
                        else if (tap_i <= 4'd11)
                            blk_left[tap_i[1:0]] <= nb_value;
                        else
                            blk_top_left <= nb_value;

                        if (tap_i == 4'd12)
                            state <= ST_PREDCAP;
                        else
                            nbc <= nbc + 5'd1;
                    end
                end

                ST_PREDCAP: begin
                    for (si = 0; si < 16; si = si + 1)
                        pipe_pred[si] <= i4_pred_pixels[si];
                    wcnt  <= 4'd0;
                    state <= ST_XFORM;
                end

                // The scaler/transform engine runs alongside the neighbour or
                // plane walk; this only ever waits out the residual cycles.
                ST_XFORM: if (xform_ready || xform_done) begin
                    wcnt  <= 4'd0;
                    state <= ST_STORE;
                end

                // Sync M10K read: address on cycle n, sample lands on n+1.
                ST_I16FETCH: begin
                    if (fcnt != 5'd0)
                        pipe_pred[fcnt[3:0] - 4'd1] <= i16_rd_data;
                    if (fcnt == 5'd16) begin
                        wcnt  <= 4'd0;
                        state <= ST_XFORM;
                    end else begin
                        fcnt <= fcnt + 5'd1;
                    end
                end

                ST_STORE: begin
                    mem_we    <= 1'b1;
                    mem_waddr <= walk_addr;
                    mem_wdata <= recon_block[wcnt];

                    recon_sample_valid <= 1'b1;
                    recon_sample_idx   <= walk_addr;
                    recon_sample       <= recon_block[wcnt];

                    block_recon_pixels[wcnt] <= recon_block[wcnt];

                    if (wcnt == 4'd15) begin
                        block_recon_valid <= 1'b1;
                        block_recon_idx   <= pipe_block_idx;
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
