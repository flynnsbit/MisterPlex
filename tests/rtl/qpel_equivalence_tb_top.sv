// Testbench-only wrapper that instantiates BOTH quarter-pel luma
// implementations that currently exist in the product tree:
//
//   h264_luma_qpel_sample      (fpga/Plex_MiSTer/rtl/h264_inter_pred.sv)
//       9x9 window -> one sample.  Was h264_decode_core's
//       u_product_p16_luma_pred until w-swap-o5-mc (4f4312b).
//   h264_luma_qpel_block_16x16 (fpga/Plex_MiSTer/rtl/h264_dpb.sv)
//       21x21 window -> 16x16 block.  Reimplements the 6-tap FIR with its
//       own local functions; it does NOT instantiate the sample module.
//
// Nothing else in the tree proves these two agree.  That is the same shape as
// the DECODE_REAL_INTRA split that left each configuration holding half a
// decoder with every unit test green, so it gets an explicit gate.
`default_nettype none

module qpel_equivalence_tb_top (
    // Shared 25x25 reference plane, indexed [row * 25 + col] with the plane
    // origin two samples above/left of the block window origin.  Feeding both
    // DUTs from one plane means neither can be advantaged by window framing.
    input  wire [7:0] plane [0:624],
    input  wire [1:0] frac_x,
    input  wire [1:0] frac_y,
    // Output position under test, 0..15 in each axis.
    input  wire [3:0] pos_x,
    input  wire [3:0] pos_y,

    output wire [7:0] block_pred,
    output wire [7:0] sample_pred
);
    // ref_win[r][c] == plane[r+2][c+2] : the block DUT's 21x21 window.
    wire [7:0] ref_win [0:440];
    genvar r, c;
    generate
        for (r = 0; r < 21; r = r + 1) begin : g_win_r
            for (c = 0; c < 21; c = c + 1) begin : g_win_c
                assign ref_win[r * 21 + c] = plane[(r + 2) * 25 + (c + 2)];
            end
        end
    endgenerate

    wire [7:0] block_out [0:255];

    h264_luma_qpel_block_16x16 u_block (
        .ref_win(ref_win),
        .frac_x(frac_x),
        .frac_y(frac_y),
        .pred(block_out)
    );

    assign block_pred = block_out[{pos_y, 4'd0} + {4'd0, pos_x}];

    // The sample DUT's 9x9 window is centred at its own (4,4).  The block DUT
    // computes output (pos_x,pos_y) about ref_win(pos_y+2, pos_x+2), which is
    // plane(pos_y+4, pos_x+4).  So sample (4,4) must be plane(pos_y+4,pos_x+4)
    // and sample (rr,cc) is plane(pos_y+rr, pos_x+cc).  Every index stays
    // inside the 25x25 plane for all 16x16 positions, so the sample DUT sees
    // true plane data even where it reaches outside the block DUT's window.
    wire [7:0] ref_pix [0:80];
    genvar rr, cc;
    generate
        for (rr = 0; rr < 9; rr = rr + 1) begin : g_pix_r
            for (cc = 0; cc < 9; cc = cc + 1) begin : g_pix_c
                assign ref_pix[rr * 9 + cc] =
                    plane[({4'd0, pos_y} + rr) * 25 + ({4'd0, pos_x} + cc)];
            end
        end
    endgenerate

    wire [7:0] sample_out;

    h264_luma_qpel_sample u_sample (
        .ref_pix(ref_pix),
        .frac_x(frac_x),
        .frac_y(frac_y),
        .sample(sample_out)
    );

`ifdef QPEL_EQUIV_NEGATIVE_TEST
    // Red proof: perturb one implementation and require the gate to fail.
    assign sample_pred = sample_out ^ 8'd1;
`else
    assign sample_pred = sample_out;
`endif
endmodule

`default_nettype wire
