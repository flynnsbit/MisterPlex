// REAL RTL: I16 AC CAVLC max_coeff=15 bit-position + decode_top AC non-zero.
`default_nettype none
module i16_ac_bits_tb_top (
    input  wire        clk,
    input  wire        reset,
    // CAVLC dual
    input  wire        cav_start,
    input  wire [2:0]  cav_table,
    input  wire [4:0]  cav_max,
    input  wire [9:0]  cav_bit0,
    input  wire [7:0]  cav_rbsp [0:63],
    output wire        cav_done,
    output wire        cav_ok,
    output wire [9:0]  cav_bit_end,
    output wire [4:0]  cav_tc,
    output wire signed [15:0] cav_coeff [0:15],
    // QP
    input  wire [5:0]  qp_prev,
    input  wire signed [7:0] qp_delta,
    output wire [5:0]  qp_y,
    input  wire [5:0]  qp_y_for_c,
    input  wire signed [4:0] chroma_off,
    output wire [5:0]  qp_c,
    // decode_top I16
    input  wire        mb_start,
    input  wire [7:0]  mb_type,
    input  wire [5:0]  mb_qp,
    input  wire [1:0]  i16_mode,
    input  wire        blk_valid,
    input  wire [3:0]  blk_idx,
    input  wire signed [15:0] blk_coeff [0:15],
    input  wire        i16_dc_valid,
    input  wire signed [28:0] i16_dc [0:15],
    input  wire        avail_l,
    input  wire        avail_t,
    input  wire [7:0]  nb_top [0:15],
    input  wire [7:0]  nb_left [0:15],
    input  wire [7:0]  nb_tl,
    input  wire [7:0]  nb_tr [0:3],
    output wire        mb_done,
    output wire [7:0]  recon_sample,
    output wire        recon_sample_valid,
    output wire [7:0]  recon_sample_idx
);
    h264_cavlc_residual_block #(.MAX_BYTES(64)) u_cav (
        .clk(clk), .reset(reset), .start(cav_start),
        .coeff_token_table(cav_table), .max_coeff(cav_max),
        .bit_offset_start(cav_bit0), .bit_len(10'd512), .rbsp(cav_rbsp),
        .busy(), .done(cav_done), .ok(cav_ok), .bit_offset_end(cav_bit_end),
        .total_coeff(cav_tc), .trailing_ones(), .total_zeros(),
        .coeff(cav_coeff), .level_dbg(), .run_dbg()
    );
    h264_qp_y_add_delta u_qp (.prev_qp(qp_prev), .mb_qp_delta(qp_delta), .qp_y(qp_y));
    h264_chroma_qp u_cqp (.qp_y(qp_y_for_c), .chroma_qp_index_offset(chroma_off), .qp_c(qp_c));

    wire [3:0] i4m [0:15];
    genvar gi;
    generate for (gi = 0; gi < 16; gi = gi + 1) begin : g
        assign i4m[gi] = 4'd2;
    end endgenerate

    h264_decode_top u_top (
        .clk(clk), .reset(reset),
        .mb_start(mb_start), .mb_type(mb_type), .mb_qp_y(mb_qp),
        .mb_x(8'd0), .mb_y(8'd0), .i16_pred_mode(i16_mode),
        .block_valid(blk_valid), .block_index(blk_idx), .block_coeff(blk_coeff),
        .i16_dc_valid(i16_dc_valid), .i16_dc(i16_dc), .i4_modes(i4m),
        .mb_avail_left(avail_l), .mb_avail_top(avail_t),
        .mb_avail_topright(1'b0), .mb_avail_topleft(1'b0),
        .nb_top(nb_top), .nb_left(nb_left), .nb_topleft(nb_tl), .nb_topright(nb_tr),
        .nb_busy(1'b0),
        .recon_sample_valid(recon_sample_valid),
        .recon_sample_idx(recon_sample_idx),
        .recon_sample(recon_sample),
        .block_recon_valid(), .block_recon_idx(), .block_recon_pixels(),
        .mb_recon_valid(mb_done), .blocks_done()
    );
endmodule
`default_nettype wire
