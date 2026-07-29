// Left-edge neighbour handshake + I16 availability.
// 1) After mb_start at mb_x=0, delayed start must latch has_left=0 (not stale).
// 2) I16 DC with only top available must ignore garbage left samples.
`default_nettype none
module left_edge_nb_tb_top (
    input  wire        clk,
    input  wire        reset,
    input  wire        mb_start,
    input  wire [7:0]  mb_x,
    input  wire [7:0]  mb_y,
    input  wire [15:0] first_mb,
    input  wire [1:0]  i16_mode,
    input  wire        force_i16_start,
    input  wire        force_has_above,
    input  wire        force_has_left,
    input  wire [7:0]  force_above0,
    input  wire [7:0]  force_left0,
    input  wire        use_force_nb,
    output wire        nb_busy,
    output wire        snap_has_left,
    output wire        snap_has_top,
    output wire [7:0]  snap_left0,
    output wire [7:0]  snap_top0,
    output wire        i16_valid,
    output wire [7:0]  pred_sample
);
    wire [7:0] nb_top [0:15];
    wire [7:0] nb_left [0:15];
    wire [7:0] nb_tl;
    wire [7:0] nb_tr [0:3];
    wire av_l, av_t, av_tr, av_tl;
    wire busy;

    wire [7:0] ry [0:255];
    wire [7:0] ru [0:63];
    wire [7:0] rv [0:63];
    wire [7:0] rp [0:15];
    genvar gi;
    generate
        for (gi = 0; gi < 256; gi++) begin : g_y
            assign ry[gi] = 8'd40;
        end
        for (gi = 0; gi < 64; gi++) begin : g_c
            assign ru[gi] = 8'd128;
            assign rv[gi] = 8'd128;
        end
        for (gi = 0; gi < 16; gi++) begin : g_p
            assign rp[gi] = 8'd40;
        end
    endgenerate

    h264_intra_nb_ctx #(.MB_WIDTH_MAX(39), .MB_WIDTH_DEFAULT(39)) u_ctx (
        .clk(clk), .reset(reset),
        .mb_x(mb_x), .mb_y(mb_y), .mb_width(8'd39),
        .first_mb_in_slice(first_mb),
        .mb_start(mb_start),
        .block_idx(4'd0), .block_valid(1'b0), .recon_pixels(rp),
        .mb_commit(1'b0),
        .recon_y_mb(ry), .recon_u_mb(ru), .recon_v_mb(rv),
        .above(), .left(), .top_left(),
        .has_above(), .has_left(), .has_above_right(),
        .mb_avail_left(av_l), .mb_avail_top(av_t),
        .mb_avail_topright(av_tr), .mb_avail_topleft(av_tl),
        .nb_top(nb_top), .nb_left(nb_left), .nb_topleft(nb_tl), .nb_topright(nb_tr),
        .chroma_u_above(), .chroma_v_above(),
        .chroma_u_left(), .chroma_v_left(),
        .chroma_u_top_left(), .chroma_v_top_left(),
        .has_chroma_above(), .has_chroma_left(),
        .busy(busy)
    );

    reg pend, fire;
    always @(posedge clk) begin
        fire <= 1'b0;
        if (reset) pend <= 1'b0;
        else if (mb_start) pend <= 1'b1;
        else if (pend && !busy) begin
            pend <= 1'b0;
            fire <= 1'b1;
        end
    end

    wire [7:0] above_m [0:15];
    wire [7:0] left_m  [0:15];
    wire [7:0] tl_m;
    wire has_a_m, has_l_m;
    generate
        for (gi = 0; gi < 16; gi++) begin : g_mux
            assign above_m[gi] = use_force_nb ? force_above0 : nb_top[gi];
            assign left_m[gi]  = use_force_nb ? force_left0  : nb_left[gi];
        end
    endgenerate
    assign tl_m    = use_force_nb ? 8'd128 : nb_tl;
    assign has_a_m = use_force_nb ? force_has_above : av_t;
    assign has_l_m = use_force_nb ? force_has_left  : av_l;

    wire start_i16 = use_force_nb ? force_i16_start : fire;

    reg [7:0] rd_addr;
    wire [7:0] rd_data;
    h264_intra16x16_pred #(.PARALLEL_OUT(0)) u_i16 (
        .clk(clk),
        .start(start_i16),
        .mode(i16_mode),
        .above(above_m),
        .left(left_m),
        .top_left(tl_m),
        .has_above(has_a_m),
        .has_left(has_l_m),
        .rd_addr(rd_addr),
        .rd_data(rd_data),
        .unsupported(),
        .valid(i16_valid)
    );

    reg snap_l, snap_t;
    reg [7:0] snap_l0_r, snap_t0_r;
    always @(posedge clk) begin
        if (reset) begin
            snap_l <= 1'b0;
            snap_t <= 1'b0;
            snap_l0_r <= 8'd0;
            snap_t0_r <= 8'd0;
            rd_addr <= 8'd0;
        end else begin
            if (fire) begin
                snap_l    <= av_l;
                snap_t    <= av_t;
                snap_l0_r <= nb_left[0];
                snap_t0_r <= nb_top[0];
            end
            if (i16_valid)
                rd_addr <= 8'd0;
        end
    end

    assign nb_busy = busy;
    assign snap_has_left = snap_l;
    assign snap_has_top  = snap_t;
    assign snap_left0 = snap_l0_r;
    assign snap_top0  = snap_t0_r;
    assign pred_sample = rd_data;
endmodule
`default_nettype wire
