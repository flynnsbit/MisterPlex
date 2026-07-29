// H.264 reconstructed-neighbour context (PRE-deblock).
// Line buffers (above_y/u/v) are true M10K: sync 1R1W, registered raddr, no
// array reset, sequential gather into nb_* regs.  Current-MB luma stays a small
// register file (256 B) written block-by-block — product path only needs MB-level
// taps from the line buffers.  No always@* RAM reads (VRFX / logic-RAM hazard).

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
    input  wire [7:0]  recon_pixels [0:15],
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
    output reg         has_chroma_left,
    output wire        busy
);
    localparam int LUMA_ABOVE_DEPTH   = MB_WIDTH_MAX * 16;
    localparam int CHROMA_ABOVE_DEPTH = MB_WIDTH_MAX * 8;
    localparam int AY_AW = $clog2(LUMA_ABOVE_DEPTH);
    localparam int AC_AW = $clog2(CHROMA_ABOVE_DEPTH);

    wire [7:0] active_mb_width = (mb_width == 8'd0) ? MB_WIDTH_DEFAULT[7:0] : mb_width;
    wire [15:0] aw16 = {8'd0, active_mb_width};
    wire [15:0] cur_mb  = ({8'd0, mb_y} * aw16) + {8'd0, mb_x};
    wire [15:0] top_mb  = cur_mb - aw16;
    wire [15:0] tl_mb   = top_mb - 16'd1;
    wire [15:0] tr_mb   = top_mb + 16'd1;

    wire ext_left = (mb_x != 8'd0) && ((cur_mb - 16'd1) >= first_mb_in_slice);
    wire ext_top  = (mb_y != 8'd0) && (top_mb >= first_mb_in_slice);
    wire ext_tl   = (mb_x != 8'd0) && (mb_y != 8'd0) && (tl_mb >= first_mb_in_slice);
    wire ext_tr   = (mb_y != 8'd0) && ((mb_x + 8'd1) < active_mb_width) && (tr_mb >= first_mb_in_slice);

    function automatic [7:0] fl(input [7:0] v);
`ifdef H264_INTRA_NB_CTX_FAULT_STUB_NEIGHBORS
        fl = 8'd128;
`else
        fl = v;
`endif
    endfunction
    function automatic [7:0] fu(input [7:0] u, input [7:0] v);
`ifdef H264_INTRA_NB_CTX_FAULT_SWAP_CHROMA_UV
        fu = v;
`else
        fu = u;
`endif
    endfunction
    function automatic [7:0] fv(input [7:0] u, input [7:0] v);
`ifdef H264_INTRA_NB_CTX_FAULT_SWAP_CHROMA_UV
        fv = u;
`else
        fv = v;
`endif
    endfunction

    // Current-MB store (registers — 256 B; written 16-wide on block_valid)
    reg [7:0] mb_y_buf [0:15][0:15];
    reg [7:0] mb_u_buf [0:7][0:7];
    reg [7:0] mb_v_buf [0:7][0:7];

    // M10K line buffers
    (* ramstyle = "M10K" *) reg [7:0] above_y_mem [0:LUMA_ABOVE_DEPTH-1];
    (* ramstyle = "M10K" *) reg [7:0] above_u_mem [0:CHROMA_ABOVE_DEPTH-1];
    (* ramstyle = "M10K" *) reg [7:0] above_v_mem [0:CHROMA_ABOVE_DEPTH-1];

    reg [AY_AW-1:0] ay_raddr, ay_waddr;
    reg [AC_AW-1:0] au_raddr, au_waddr, av_raddr, av_waddr;
    reg [7:0] ay_wdata, au_wdata, av_wdata, ay_rdata, au_rdata, av_rdata;
    reg ay_we, au_we, av_we;

    always @(posedge clk) begin
        ay_rdata <= above_y_mem[ay_raddr];
        if (ay_we) above_y_mem[ay_waddr] <= ay_wdata;
        au_rdata <= above_u_mem[au_raddr];
        if (au_we) above_u_mem[au_waddr] <= au_wdata;
        av_rdata <= above_v_mem[av_raddr];
        if (av_we) above_v_mem[av_waddr] <= av_wdata;
    end

    reg [7:0] left_y_col [0:15];
    reg [7:0] left_u_col [0:7];
    reg [7:0] left_v_col [0:7];
    reg [7:0] row_tl_y, row_tl_u, row_tl_v;
    reg [7:0] tl_y, tl_u, tl_v;

    wire [3:0] blk_x = {block_idx[2], block_idx[0], 2'b00};
    wire [3:0] blk_y = {block_idx[3], block_idx[1], 2'b00};

    localparam [3:0]
        ST_IDLE = 4'd0,
        ST_PUB  = 4'd1,   // publish edges: write line buffers + left cols
        ST_GTOP = 4'd2,
        ST_GTR  = 4'd3,
        ST_GCHR = 4'd4,
        ST_GBLK = 4'd5;

    reg [3:0] st;
    reg [5:0] cnt;
    reg [1:0] ph; // 0 issue, 1 wait, 2 capture
    reg pend_pub, pend_gmb, pend_gblk;
    reg [3:0] gblk;
    reg [7:0] hx, hy;
    reg [7:0] pub_y_row [0:15];
    reg [7:0] pub_u_row [0:7];
    reg [7:0] pub_v_row [0:7];
    reg [7:0] pub_y_col [0:15];
    reg [7:0] pub_u_col [0:7];
    reg [7:0] pub_v_col [0:7];

    assign busy = (st != ST_IDLE) || pend_pub || pend_gmb || pend_gblk;

    wire [AY_AW-1:0] ay_base = hx * 16;
    wire [AC_AW-1:0] ac_base = hx * 8;

    integer r, c, i;

    always @(posedge clk) begin
        ay_we <= 1'b0;
        au_we <= 1'b0;
        av_we <= 1'b0;

        if (reset) begin
            st <= ST_IDLE;
            cnt <= 6'd0;
            ph <= 2'd0;
            pend_pub <= 1'b0;
            pend_gmb <= 1'b0;
            pend_gblk <= 1'b0;
            gblk <= 4'd0;
            hx <= 8'd0;
            hy <= 8'd0;
            row_tl_y <= 8'd128; row_tl_u <= 8'd128; row_tl_v <= 8'd128;
            tl_y <= 8'd128; tl_u <= 8'd128; tl_v <= 8'd128;
            ay_raddr <= '0; au_raddr <= '0; av_raddr <= '0;
            ay_waddr <= '0; au_waddr <= '0; av_waddr <= '0;
            ay_wdata <= 8'd0; au_wdata <= 8'd0; av_wdata <= 8'd0;
            has_above <= 1'b0; has_left <= 1'b0; has_above_right <= 1'b0;
            has_chroma_above <= 1'b0; has_chroma_left <= 1'b0;
            mb_avail_left <= 1'b0; mb_avail_top <= 1'b0;
            mb_avail_topright <= 1'b0; mb_avail_topleft <= 1'b0;
            top_left <= 8'd128; nb_topleft <= 8'd128;
            chroma_u_top_left <= 8'd128; chroma_v_top_left <= 8'd128;
            for (i = 0; i < 16; i = i + 1) begin
                left_y_col[i] <= 8'd128;
                nb_top[i] <= 8'd128;
                nb_left[i] <= 8'd128;
                pub_y_row[i] <= 8'd128;
                pub_y_col[i] <= 8'd128;
            end
            for (i = 0; i < 8; i = i + 1) begin
                left_u_col[i] <= 8'd128; left_v_col[i] <= 8'd128;
                above[i] <= 8'd128;
                chroma_u_above[i] <= 8'd128; chroma_v_above[i] <= 8'd128;
                chroma_u_left[i] <= 8'd128; chroma_v_left[i] <= 8'd128;
                pub_u_row[i] <= 8'd128; pub_v_row[i] <= 8'd128;
                pub_u_col[i] <= 8'd128; pub_v_col[i] <= 8'd128;
                if (i < 4) begin
                    left[i] <= 8'd128;
                    nb_topright[i] <= 8'd128;
                end
            end
            for (r = 0; r < 16; r = r + 1)
                for (c = 0; c < 16; c = c + 1)
                    mb_y_buf[r][c] <= 8'd128;
            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1) begin
                    mb_u_buf[r][c] <= 8'd128;
                    mb_v_buf[r][c] <= 8'd128;
                end
        end else begin
            // ── fill current MB ───────────────────────────────────────
            if (mb_start) begin
                hx <= mb_x;
                hy <= mb_y;
`ifdef H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE
                mb_avail_top <= 1'b1;
                mb_avail_left <= 1'b1;
                mb_avail_topleft <= 1'b1;
                mb_avail_topright <= ext_tr;
                has_chroma_above <= 1'b1;
                has_chroma_left <= 1'b1;
`else
                mb_avail_top <= ext_top;
                mb_avail_left <= ext_left;
                mb_avail_topleft <= ext_tl;
                mb_avail_topright <= ext_tr;
                has_chroma_above <= ext_top;
                has_chroma_left <= ext_left;
`endif
                tl_y <= (mb_x > 8'd0 && mb_y > 8'd0) ? row_tl_y : 8'd128;
                tl_u <= (mb_x > 8'd0 && mb_y > 8'd0) ? row_tl_u : 8'd128;
                tl_v <= (mb_x > 8'd0 && mb_y > 8'd0) ? row_tl_v : 8'd128;
`ifndef H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE
                if (ext_tl) begin
                    nb_topleft <= fl(row_tl_y);
                    chroma_u_top_left <= row_tl_u;
                    chroma_v_top_left <= row_tl_v;
                end else begin
                    nb_topleft <= 8'd128;
                    chroma_u_top_left <= 8'd128;
                    chroma_v_top_left <= 8'd128;
                end
`else
                nb_topleft <= fl(row_tl_y);
                chroma_u_top_left <= row_tl_u;
                chroma_v_top_left <= row_tl_v;
`endif
                for (i = 0; i < 16; i = i + 1) begin
                    nb_top[i] <= 8'd128;
                    nb_left[i] <= 8'd128;
                end
                for (i = 0; i < 4; i = i + 1)
                    nb_topright[i] <= 8'd128;
                for (i = 0; i < 8; i = i + 1) begin
                    chroma_u_above[i] <= 8'd128;
                    chroma_v_above[i] <= 8'd128;
                    chroma_u_left[i] <= 8'd128;
                    chroma_v_left[i] <= 8'd128;
                end
`ifdef H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE
                for (i = 0; i < 16; i = i + 1)
                    nb_left[i] <= fl(left_y_col[i]);
                for (i = 0; i < 8; i = i + 1) begin
                    chroma_u_left[i] <= left_u_col[i];
                    chroma_v_left[i] <= left_v_col[i];
                end
`else
                if (ext_left) begin
                    for (i = 0; i < 16; i = i + 1)
                        nb_left[i] <= fl(left_y_col[i]);
                    for (i = 0; i < 8; i = i + 1) begin
                        chroma_u_left[i] <= left_u_col[i];
                        chroma_v_left[i] <= left_v_col[i];
                    end
                end
`endif
                for (r = 0; r < 16; r = r + 1)
                    for (c = 0; c < 16; c = c + 1)
                        mb_y_buf[r][c] <= 8'd128;
                for (r = 0; r < 8; r = r + 1)
                    for (c = 0; c < 8; c = c + 1) begin
                        mb_u_buf[r][c] <= 8'd128;
                        mb_v_buf[r][c] <= 8'd128;
                    end
                pend_gmb <= 1'b1;
                // Always refresh block taps after MB start (gblk may already equal block_idx).
                pend_gblk <= 1'b1;
                gblk <= block_idx;
`ifdef H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE
                has_above <= 1'b1;
                has_left  <= 1'b1;
                has_above_right <= 1'b1;
`else
                has_above <= ext_top;
                has_left  <= ext_left;
                has_above_right <= 1'b0;
`endif
            end

            if (block_valid) begin
                for (r = 0; r < 4; r = r + 1)
                    for (c = 0; c < 4; c = c + 1)
                        mb_y_buf[blk_y + r[3:0]][blk_x + c[3:0]] <=
                            fl(recon_pixels[r * 4 + c]);
            end

            if (mb_commit) begin
                // Snapshot edges into regs, then sequential M10K publish.
                for (i = 0; i < 16; i = i + 1) begin
                    pub_y_row[i] <= fl(mb_y_buf[15][i]);
                    pub_y_col[i] <= fl(mb_y_buf[i][15]);
                end
                for (r = 0; r < 8; r = r + 1)
                    for (c = 0; c < 8; c = c + 1) begin
                        mb_u_buf[r][c] <= recon_u_mb[r * 8 + c];
                        mb_v_buf[r][c] <= recon_v_mb[r * 8 + c];
                    end
                for (i = 0; i < 8; i = i + 1) begin
                    pub_u_row[i] <= fu(recon_u_mb[56 + i], recon_v_mb[56 + i]);
                    pub_v_row[i] <= fv(recon_u_mb[56 + i], recon_v_mb[56 + i]);
                    pub_u_col[i] <= fu(recon_u_mb[i*8 + 7], recon_v_mb[i*8 + 7]);
                    pub_v_col[i] <= fv(recon_u_mb[i*8 + 7], recon_v_mb[i*8 + 7]);
                end
                hx <= mb_x;
                hy <= mb_y;
                pend_pub <= 1'b1;
            end

            case (st)
            ST_IDLE: begin
                ph <= 2'd0;
                cnt <= 6'd0;
                if (pend_pub) begin
                    pend_pub <= 1'b0;
                    st <= ST_PUB;
                    // Capture prior above[15] for row_tl before overwrite (if top row exists)
                    if (hy != 8'd0)
                        ay_raddr <= ay_base + 4'd15;
                end else if (pend_gmb) begin
                    pend_gmb <= 1'b0;
                    if (mb_avail_top)
                        st <= ST_GTOP;
                    else if (mb_avail_topright)
                        st <= ST_GTR;
                    else if (has_chroma_above)
                        st <= ST_GCHR;
                    else if (pend_gblk) begin
                        pend_gblk <= 1'b0;
                        st <= ST_GBLK;
                    end
                end else if (pend_gblk) begin
                    pend_gblk <= 1'b0;
                    st <= ST_GBLK;
                end
            end

            // cnt: 0 issue tl read, 1 wait, 2 capture tl + start writes
            // 2..17 write Y[0..15]; 18 issue U tl; 19 wait; 20 capture U tl + write U[0]
            // 20..27 write U; 28-29 V tl; 30..37 write V
            ST_PUB: begin
                if (cnt == 6'd0) begin
                    if (hy != 8'd0)
                        ay_raddr <= ay_base + 4'd15;
                    cnt <= 6'd1;
                end else if (cnt == 6'd1) begin
                    cnt <= 6'd2;
                end else if (cnt == 6'd2) begin
                    row_tl_y <= (hy != 8'd0) ? ay_rdata : 8'd128;
                    ay_waddr <= ay_base + 4'd0;
                    ay_wdata <= pub_y_row[0];
                    ay_we <= 1'b1;
                    left_y_col[0] <= pub_y_col[0];
                    cnt <= 6'd3;
                end else if (cnt < 6'd18) begin
                    // cnt 3..17 → Y index 1..15
                    ay_waddr <= ay_base + (cnt - 6'd2);
                    ay_wdata <= pub_y_row[cnt - 6'd2];
                    ay_we <= 1'b1;
                    left_y_col[cnt - 6'd2] <= pub_y_col[cnt - 6'd2];
                    cnt <= cnt + 6'd1;
                end else if (cnt == 6'd18) begin
                    if (hy != 8'd0)
                        au_raddr <= ac_base + 3'd7;
                    cnt <= 6'd19;
                end else if (cnt == 6'd19) begin
                    cnt <= 6'd20;
                end else if (cnt == 6'd20) begin
                    row_tl_u <= (hy != 8'd0) ? au_rdata : 8'd128;
                    au_waddr <= ac_base;
                    au_wdata <= pub_u_row[0];
                    au_we <= 1'b1;
                    left_u_col[0] <= pub_u_col[0];
                    cnt <= 6'd21;
                end else if (cnt < 6'd28) begin
                    au_waddr <= ac_base + (cnt - 6'd20);
                    au_wdata <= pub_u_row[cnt - 6'd20];
                    au_we <= 1'b1;
                    left_u_col[cnt - 6'd20] <= pub_u_col[cnt - 6'd20];
                    cnt <= cnt + 6'd1;
                end else if (cnt == 6'd28) begin
                    if (hy != 8'd0)
                        av_raddr <= ac_base + 3'd7;
                    cnt <= 6'd29;
                end else if (cnt == 6'd29) begin
                    cnt <= 6'd30;
                end else if (cnt == 6'd30) begin
                    row_tl_v <= (hy != 8'd0) ? av_rdata : 8'd128;
                    av_waddr <= ac_base;
                    av_wdata <= pub_v_row[0];
                    av_we <= 1'b1;
                    left_v_col[0] <= pub_v_col[0];
                    cnt <= 6'd31;
                end else if (cnt < 6'd38) begin
                    av_waddr <= ac_base + (cnt - 6'd30);
                    av_wdata <= pub_v_row[cnt - 6'd30];
                    av_we <= 1'b1;
                    left_v_col[cnt - 6'd30] <= pub_v_col[cnt - 6'd30];
                    cnt <= cnt + 6'd1;
                end else begin
                    st <= ST_IDLE;
                    cnt <= 6'd0;
                end
            end

            ST_GTOP: begin
                if (cnt < 6'd16) begin
                    if (ph == 2'd0) begin
                        ay_raddr <= (hx * 16) + cnt[3:0];
                        ph <= 2'd1;
                    end else if (ph == 2'd1) begin
                        ph <= 2'd2;
                    end else begin
                        nb_top[cnt[3:0]] <= fl(ay_rdata);
                        ph <= 2'd0;
                        cnt <= cnt + 6'd1;
                    end
                end else begin
                    cnt <= 6'd0; ph <= 2'd0;
                    if (mb_avail_topright) st <= ST_GTR;
                    else if (has_chroma_above) st <= ST_GCHR;
                    else if (pend_gblk) begin pend_gblk <= 1'b0; st <= ST_GBLK; end
                    else st <= ST_IDLE;
                end
            end

            ST_GTR: begin
                if (cnt < 6'd4) begin
                    if (ph == 2'd0) begin
                        ay_raddr <= ((hx + 8'd1) * 16) + cnt[3:0];
                        ph <= 2'd1;
                    end else if (ph == 2'd1) begin
                        ph <= 2'd2;
                    end else begin
                        nb_topright[cnt[1:0]] <= fl(ay_rdata);
                        ph <= 2'd0;
                        cnt <= cnt + 6'd1;
                    end
                end else begin
                    cnt <= 6'd0; ph <= 2'd0;
                    if (has_chroma_above) st <= ST_GCHR;
                    else if (pend_gblk) begin pend_gblk <= 1'b0; st <= ST_GBLK; end
                    else st <= ST_IDLE;
                end
            end

            ST_GCHR: begin
                if (cnt < 6'd8) begin
                    if (ph == 2'd0) begin
                        au_raddr <= (hx * 8) + cnt[2:0];
                        av_raddr <= (hx * 8) + cnt[2:0];
                        ph <= 2'd1;
                    end else if (ph == 2'd1) begin
                        ph <= 2'd2;
                    end else begin
                        chroma_u_above[cnt[2:0]] <= au_rdata;
                        chroma_v_above[cnt[2:0]] <= av_rdata;
                        ph <= 2'd0;
                        cnt <= cnt + 6'd1;
                    end
                end else begin
                    cnt <= 6'd0; ph <= 2'd0;
                    if (pend_gblk) begin pend_gblk <= 1'b0; st <= ST_GBLK; end
                    else st <= ST_IDLE;
                end
            end

            // Block-level from mb_y_buf regs + line buffer (no wide comb ports)
            ST_GBLK: begin
                begin : gblk_body
                    reg [3:0] bx, by;
                    bx = {gblk[2], gblk[0], 2'b00};
                    by = {gblk[3], gblk[1], 2'b00};
`ifdef H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE
                    has_above <= 1'b1;
                    has_left  <= 1'b1;
`else
                    has_above <= mb_avail_top || (by != 4'd0);
                    has_left  <= mb_avail_left || (bx != 4'd0);
`endif
                    // Produce all taps in a few cycles from regs / already-gathered nb_top
                    if (cnt == 6'd0) begin
                        // above[0:3]
                        if (by != 4'd0) begin
                            for (i = 0; i < 4; i = i + 1)
                                above[i] <= fl(mb_y_buf[by - 4'd1][bx + i[3:0]]);
                        end else if (mb_avail_top) begin
                            for (i = 0; i < 4; i = i + 1)
                                above[i] <= nb_top[bx + i[3:0]];
                        end else begin
                            for (i = 0; i < 4; i = i + 1)
                                above[i] <= 8'd128;
                        end
                        cnt <= 6'd1;
                    end else if (cnt == 6'd1) begin
                        // above[4:7] / above-right
                        if (bx < 4'd12) begin
                            has_above_right <= (mb_avail_top || by != 4'd0);
                            if (by != 4'd0) begin
                                for (i = 0; i < 4; i = i + 1)
                                    above[4 + i] <= fl(mb_y_buf[by - 4'd1][bx + 4'd4 + i[3:0]]);
                            end else if (mb_avail_top) begin
                                for (i = 0; i < 4; i = i + 1)
                                    above[4 + i] <= nb_top[bx + 4'd4 + i[3:0]];
                            end else begin
                                for (i = 0; i < 4; i = i + 1)
                                    above[4 + i] <= above[3];
                            end
                        end else if (by == 4'd0 && mb_avail_topright) begin
                            has_above_right <= 1'b1;
                            for (i = 0; i < 4; i = i + 1)
                                above[4 + i] <= nb_topright[i];
                        end else begin
                            has_above_right <= 1'b0;
                            for (i = 0; i < 4; i = i + 1)
                                above[4 + i] <= above[3];
                        end
                        cnt <= 6'd2;
                    end else if (cnt == 6'd2) begin
                        if (bx != 4'd0) begin
                            for (i = 0; i < 4; i = i + 1)
                                left[i] <= fl(mb_y_buf[by + i[3:0]][bx - 4'd1]);
                        end else if (mb_avail_left) begin
                            for (i = 0; i < 4; i = i + 1)
                                left[i] <= fl(left_y_col[by + i[3:0]]);
                        end else begin
                            for (i = 0; i < 4; i = i + 1)
                                left[i] <= 8'd128;
                        end
                        if (bx != 4'd0 && by != 4'd0)
                            top_left <= fl(mb_y_buf[by - 4'd1][bx - 4'd1]);
                        else if (bx == 4'd0 && by != 4'd0)
                            top_left <= mb_avail_left ? fl(left_y_col[by - 4'd1]) : 8'd128;
                        else if (bx != 4'd0 && by == 4'd0)
                            top_left <= mb_avail_top ? nb_top[bx - 4'd1] : 8'd128;
                        else
                            top_left <= mb_avail_topleft ? fl(tl_y) : 8'd128;
                        st <= ST_IDLE;
                        cnt <= 6'd0;
                    end
                end
            end

            default: st <= ST_IDLE;
            endcase

            // On-demand block gather when block_idx changes (TB / skeleton)
            if (!block_valid && !mb_start && !mb_commit && (st == ST_IDLE) &&
                !pend_pub && !pend_gmb && !pend_gblk && (block_idx != gblk)) begin
                pend_gblk <= 1'b1;
                gblk <= block_idx;
            end
        end
    end

    wire _unused_y = |recon_y_mb[0];
endmodule
