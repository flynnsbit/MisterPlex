// H.264 reconstructed-neighbour context for intra prediction.
//
// This module stores PRE-DEBLOCK reconstructed samples. Intra prediction reads
// this tap. The DPB/reference path must consume the separate POST-DEBLOCK tap.
// For the measured PMS stream the coded frame is 624x480 = 39x30 complete MBs;
// the default storage depth is therefore exactly full-width, with no partial-MB
// edge assumptions.

module h264_intra_nb_ctx #(
    parameter int MB_WIDTH_MAX = 39,
    parameter int MB_WIDTH_DEFAULT = 39
)(
    input  wire        clk,
    input  wire        reset,

    input  wire [7:0]  mb_x,
    input  wire [7:0]  mb_y,
    input  wire [7:0]  mb_width,
    input  wire [15:0] first_mb_in_slice,
    input  wire        mb_start,

    input  wire [3:0]  block_idx,
    input  wire        block_valid,

    // PRE-deblock reconstructed luma feedback. block_valid stores the current
    // 4x4 block so later blocks in the same MB can consume it immediately.
    input  wire [7:0]  recon_pixels [0:15],

    // Optional whole-MB PRE-deblock commit. The luma array is used when an
    // external decode scheduler commits a full MB at once; chroma arrays are the
    // only chroma source because chroma prediction works at 8x8 granularity.
    input  wire        mb_commit,
    input  wire [7:0]  recon_y_mb [0:255],
    input  wire [7:0]  recon_u_mb [0:63],
    input  wire [7:0]  recon_v_mb [0:63],

    output reg  [7:0]  above [0:7],
    output reg  [7:0]  left [0:3],
    output reg  [7:0]  top_left,
    output reg         has_above,
    output reg         has_left,
    output reg         has_above_right,

    // MB-level luma neighbour adapter for h264_decode_top. Same PRE-deblock
    // storage/tap as the block-level ports above.
    output reg         mb_avail_left,
    output reg         mb_avail_top,
    output reg         mb_avail_topright,
    output reg         mb_avail_topleft,
    output reg  [7:0]  nb_top [0:15],
    output reg  [7:0]  nb_left [0:15],
    output reg  [7:0]  nb_topleft,
    output reg  [7:0]  nb_topright [0:3],

    output reg  [7:0]  chroma_u_above [0:7],
    output reg  [7:0]  chroma_v_above [0:7],
    output reg  [7:0]  chroma_u_left [0:7],
    output reg  [7:0]  chroma_v_left [0:7],
    output reg  [7:0]  chroma_u_top_left,
    output reg  [7:0]  chroma_v_top_left,
    output reg         has_chroma_above,
    output reg         has_chroma_left
);

    localparam int LUMA_ABOVE_DEPTH = MB_WIDTH_MAX * 16;
    localparam int CHROMA_ABOVE_DEPTH = MB_WIDTH_MAX * 8;

    // Raster 4x4 block coordinates within the current luma MB.
    wire [3:0] blk_x = {block_idx[1:0], 2'b00};
    wire [3:0] blk_y = {block_idx[3:2], 2'b00};
    wire [7:0] active_mb_width = (mb_width == 8'd0) ? MB_WIDTH_DEFAULT[7:0] : mb_width;
    wire [15:0] active_mb_width16 = {8'd0, active_mb_width};
    wire [15:0] cur_mb_index = ({8'd0, mb_y} * active_mb_width16) + {8'd0, mb_x};
    wire [15:0] top_mb_index = cur_mb_index - active_mb_width16;
    wire [15:0] top_left_mb_index = top_mb_index - 16'd1;
    wire [15:0] top_right_mb_index = top_mb_index + 16'd1;

    // H.264 neighbour availability is semantic, not just storage-valid: samples
    // that exist in the line buffer but fall before first_mb_in_slice are not
    // available to this slice.
    wire ext_left_available = (mb_x != 8'd0) &&
                              ((cur_mb_index - 16'd1) >= first_mb_in_slice);
    wire ext_top_available = (mb_y != 8'd0) &&
                             (top_mb_index >= first_mb_in_slice);
    wire ext_topleft_available = (mb_x != 8'd0) && (mb_y != 8'd0) &&
                                 (top_left_mb_index >= first_mb_in_slice);
    wire ext_topright_available = (mb_y != 8'd0) &&
                                  ((mb_x + 8'd1) < active_mb_width) &&
                                  (top_right_mb_index >= first_mb_in_slice);

    function automatic int luma_addr(input [7:0] x, input [3:0] col);
        begin
            luma_addr = (int'(x) * 16) + int'(col);
        end
    endfunction

    function automatic int chroma_addr(input [7:0] x, input [2:0] col);
        begin
            chroma_addr = (int'(x) * 8) + int'(col);
        end
    endfunction

    function automatic [7:0] maybe_fault_luma(input [7:0] value);
        begin
`ifdef H264_INTRA_NB_CTX_FAULT_STUB_NEIGHBORS
            maybe_fault_luma = 8'd128;
`else
            maybe_fault_luma = value;
`endif
        end
    endfunction

    function automatic [7:0] maybe_fault_u(input [7:0] u_value, input [7:0] v_value);
        begin
`ifdef H264_INTRA_NB_CTX_FAULT_SWAP_CHROMA_UV
            maybe_fault_u = v_value;
`else
            maybe_fault_u = u_value;
`endif
        end
    endfunction

    function automatic [7:0] maybe_fault_v(input [7:0] u_value, input [7:0] v_value);
        begin
`ifdef H264_INTRA_NB_CTX_FAULT_SWAP_CHROMA_UV
            maybe_fault_v = u_value;
`else
            maybe_fault_v = v_value;
`endif
        end
    endfunction

    // Current-MB PRE-deblock reconstruction. Luma fills block-by-block; chroma is
    // committed as whole 8x8 planes.
    reg [7:0] mb_y_buf [0:15][0:15];
    reg [7:0] mb_u_buf [0:7][0:7];
    reg [7:0] mb_v_buf [0:7][0:7];

    (* ramstyle = "M10K" *) reg [7:0] above_y_row [0:LUMA_ABOVE_DEPTH-1];
    (* ramstyle = "M10K" *) reg [7:0] above_u_row [0:CHROMA_ABOVE_DEPTH-1];
    (* ramstyle = "M10K" *) reg [7:0] above_v_row [0:CHROMA_ABOVE_DEPTH-1];

    reg [7:0] left_y_col [0:15];
    reg [7:0] left_u_col [0:7];
    reg [7:0] left_v_col [0:7];
    reg [7:0] tl_y_corner;
    reg [7:0] tl_u_corner;
    reg [7:0] tl_v_corner;
    reg [7:0] row_tl_y_corner;
    reg [7:0] row_tl_u_corner;
    reg [7:0] row_tl_v_corner;
    reg       commit_pending;

    integer r, c, i;
    always @(posedge clk) begin
        if (reset) begin
            commit_pending <= 1'b0;
            tl_y_corner <= 8'd128;
            tl_u_corner <= 8'd128;
            tl_v_corner <= 8'd128;
            row_tl_y_corner <= 8'd128;
            row_tl_u_corner <= 8'd128;
            row_tl_v_corner <= 8'd128;
            for (r = 0; r < 16; r = r + 1) begin
                left_y_col[r] <= 8'd128;
                for (c = 0; c < 16; c = c + 1)
                    mb_y_buf[r][c] <= 8'd128;
            end
            for (r = 0; r < 8; r = r + 1) begin
                left_u_col[r] <= 8'd128;
                left_v_col[r] <= 8'd128;
                for (c = 0; c < 8; c = c + 1) begin
                    mb_u_buf[r][c] <= 8'd128;
                    mb_v_buf[r][c] <= 8'd128;
                end
            end
        end else begin
            // Commit the previous complete MB into the line buffers/left columns.
            // These are PRE-deblock samples. The deblock/DPB path must not feed
            // back here, or intra prediction will read the wrong tap.
            if (commit_pending) begin
                row_tl_y_corner <= (mb_y != 8'd0) ?
                                   above_y_row[luma_addr(mb_x, 4'd15)] : 8'd128;
                row_tl_u_corner <= (mb_y != 8'd0) ?
                                   above_u_row[chroma_addr(mb_x, 3'd7)] : 8'd128;
                row_tl_v_corner <= (mb_y != 8'd0) ?
                                   above_v_row[chroma_addr(mb_x, 3'd7)] : 8'd128;
                for (i = 0; i < 16; i = i + 1) begin
                    above_y_row[luma_addr(mb_x, i[3:0])] <= maybe_fault_luma(mb_y_buf[15][i]);
                    left_y_col[i] <= maybe_fault_luma(mb_y_buf[i][15]);
                end
                for (i = 0; i < 8; i = i + 1) begin
                    above_u_row[chroma_addr(mb_x, i[2:0])] <= maybe_fault_u(mb_u_buf[7][i], mb_v_buf[7][i]);
                    above_v_row[chroma_addr(mb_x, i[2:0])] <= maybe_fault_v(mb_u_buf[7][i], mb_v_buf[7][i]);
                    left_u_col[i] <= maybe_fault_u(mb_u_buf[i][7], mb_v_buf[i][7]);
                    left_v_col[i] <= maybe_fault_v(mb_u_buf[i][7], mb_v_buf[i][7]);
                end
                commit_pending <= 1'b0;
            end

            if (mb_start) begin
                tl_y_corner <= (mb_x > 8'd0 && mb_y > 8'd0) ? row_tl_y_corner : 8'd128;
                tl_u_corner <= (mb_x > 8'd0 && mb_y > 8'd0) ? row_tl_u_corner : 8'd128;
                tl_v_corner <= (mb_x > 8'd0 && mb_y > 8'd0) ? row_tl_v_corner : 8'd128;
                for (r = 0; r < 16; r = r + 1)
                    for (c = 0; c < 16; c = c + 1)
                        mb_y_buf[r][c] <= 8'd128;
                for (r = 0; r < 8; r = r + 1)
                    for (c = 0; c < 8; c = c + 1) begin
                        mb_u_buf[r][c] <= 8'd128;
                        mb_v_buf[r][c] <= 8'd128;
                    end
            end

            if (block_valid) begin
                for (r = 0; r < 4; r = r + 1)
                    for (c = 0; c < 4; c = c + 1)
                        mb_y_buf[blk_y + r[3:0]][blk_x + c[3:0]] <= recon_pixels[r * 4 + c];
            end

            if (mb_commit) begin
                for (r = 0; r < 16; r = r + 1)
                    for (c = 0; c < 16; c = c + 1)
                        mb_y_buf[r][c] <= recon_y_mb[r * 16 + c];
                for (r = 0; r < 8; r = r + 1)
                    for (c = 0; c < 8; c = c + 1) begin
                        mb_u_buf[r][c] <= recon_u_mb[r * 8 + c];
                        mb_v_buf[r][c] <= recon_v_mb[r * 8 + c];
                    end
                commit_pending <= 1'b1;
            end
        end
    end

    integer oi;
    always @* begin
`ifdef H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE
        has_above = 1'b1;
        has_left = 1'b1;
        has_chroma_above = 1'b1;
        has_chroma_left = 1'b1;
`else
        has_above = ext_top_available || (blk_y != 4'd0);
        has_left = ext_left_available || (blk_x != 4'd0);
        has_chroma_above = ext_top_available;
        has_chroma_left = ext_left_available;
`endif
        has_above_right = 1'b0;
        mb_avail_topright = 1'b0;
        top_left = 8'd128;
        nb_topleft = 8'd128;
        chroma_u_top_left = 8'd128;
        chroma_v_top_left = 8'd128;
        for (oi = 0; oi < 8; oi = oi + 1) begin
            above[oi] = 8'd128;
            chroma_u_above[oi] = 8'd128;
            chroma_v_above[oi] = 8'd128;
            chroma_u_left[oi] = 8'd128;
            chroma_v_left[oi] = 8'd128;
            if (oi < 4) begin
                left[oi] = 8'd128;
                nb_topright[oi] = 8'd128;
            end
        end

`ifdef H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE
        mb_avail_top = 1'b1;
        mb_avail_left = 1'b1;
        mb_avail_topleft = 1'b1;
`else
        mb_avail_top = ext_top_available;
        mb_avail_left = ext_left_available;
        mb_avail_topleft = ext_topleft_available;
`endif
        mb_avail_topright = ext_topright_available;
        for (oi = 0; oi < 16; oi = oi + 1) begin
            nb_top[oi] = mb_avail_top ?
                         maybe_fault_luma(above_y_row[luma_addr(mb_x, oi[3:0])]) : 8'd128;
            nb_left[oi] = mb_avail_left ?
                          maybe_fault_luma(left_y_col[oi]) : 8'd128;
        end
        nb_topleft = (mb_avail_top && mb_avail_left) ? maybe_fault_luma(tl_y_corner) : 8'd128;
        if (mb_avail_topright) begin
            for (oi = 0; oi < 4; oi = oi + 1)
                nb_topright[oi] = maybe_fault_luma(above_y_row[luma_addr(mb_x + 8'd1, oi[3:0])]);
        end

        if (has_above) begin
            if (blk_y != 4'd0) begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    above[oi] = maybe_fault_luma(mb_y_buf[blk_y - 4'd1][blk_x + oi[3:0]]);
                if (blk_x < 4'd12) begin
                    has_above_right = 1'b1;
                    for (oi = 0; oi < 4; oi = oi + 1)
                        above[4 + oi] = maybe_fault_luma(mb_y_buf[blk_y - 4'd1][blk_x + 4'd4 + oi[3:0]]);
                end else begin
                    for (oi = 0; oi < 4; oi = oi + 1)
                        above[4 + oi] = above[3];
                end
            end else begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    above[oi] = maybe_fault_luma(above_y_row[luma_addr(mb_x, blk_x + oi[3:0])]);
                if (blk_x < 4'd12) begin
                    has_above_right = 1'b1;
                    for (oi = 0; oi < 4; oi = oi + 1)
                        above[4 + oi] = maybe_fault_luma(above_y_row[luma_addr(mb_x, blk_x + 4'd4 + oi[3:0])]);
                end else if (ext_topright_available) begin
                    has_above_right = 1'b1;
                    for (oi = 0; oi < 4; oi = oi + 1)
                        above[4 + oi] = maybe_fault_luma(above_y_row[luma_addr(mb_x + 8'd1, oi[3:0])]);
                end else begin
                    for (oi = 0; oi < 4; oi = oi + 1)
                        above[4 + oi] = above[3];
                end
            end
        end

        if (has_left) begin
            if (blk_x != 4'd0) begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    left[oi] = maybe_fault_luma(mb_y_buf[blk_y + oi[3:0]][blk_x - 4'd1]);
            end else begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    left[oi] = maybe_fault_luma(left_y_col[blk_y + oi[3:0]]);
            end
        end

        if (has_above || has_left) begin
            if (blk_x != 4'd0 && blk_y != 4'd0)
                top_left = maybe_fault_luma(mb_y_buf[blk_y - 4'd1][blk_x - 4'd1]);
            else if (blk_x == 4'd0 && blk_y != 4'd0)
                top_left = has_left ? maybe_fault_luma(left_y_col[blk_y - 4'd1]) : 8'd128;
            else if (blk_x != 4'd0 && blk_y == 4'd0)
                top_left = has_above ? maybe_fault_luma(above_y_row[luma_addr(mb_x, blk_x - 4'd1)]) : 8'd128;
            else
                top_left = ext_topleft_available ? maybe_fault_luma(tl_y_corner) : 8'd128;
        end

        if (has_chroma_above) begin
            for (oi = 0; oi < 8; oi = oi + 1) begin
                chroma_u_above[oi] = above_u_row[chroma_addr(mb_x, oi[2:0])];
                chroma_v_above[oi] = above_v_row[chroma_addr(mb_x, oi[2:0])];
            end
        end
        if (has_chroma_left) begin
            for (oi = 0; oi < 8; oi = oi + 1) begin
                chroma_u_left[oi] = left_u_col[oi];
                chroma_v_left[oi] = left_v_col[oi];
            end
        end
        chroma_u_top_left = ext_topleft_available ? tl_u_corner : 8'd128;
        chroma_v_top_left = ext_topleft_available ? tl_v_corner : 8'd128;
    end

endmodule
