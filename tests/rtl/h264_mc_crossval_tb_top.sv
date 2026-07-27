// Cross-validation wrapper: instantiate w-rel's per-sample modules
// so we can compare their output against our C++ reference model.
// This proves the golden reference is correct against an independent RTL implementation.
module h264_mc_crossval_tb (
    input  wire        clk,
    // Luma interface: 9x9 reference window, fractional position
    input  wire [7:0]  luma_ref [0:80],
    input  wire [1:0]  luma_frac_x,
    input  wire [1:0]  luma_frac_y,
    output wire [7:0]  luma_sample,
    // Chroma interface
    input  wire [7:0]  chroma_p00,
    input  wire [7:0]  chroma_p10,
    input  wire [7:0]  chroma_p01,
    input  wire [7:0]  chroma_p11,
    input  wire [2:0]  chroma_frac_x,
    input  wire [2:0]  chroma_frac_y,
    output wire [7:0]  chroma_sample
);

h264_luma_qpel_sample u_luma (
    .ref_pix (luma_ref),
    .frac_x  (luma_frac_x),
    .frac_y  (luma_frac_y),
    .sample  (luma_sample)
);

h264_chroma_epel_sample u_chroma (
    .p00    (chroma_p00),
    .p10    (chroma_p10),
    .p01    (chroma_p01),
    .p11    (chroma_p11),
    .frac_x (chroma_frac_x),
    .frac_y (chroma_frac_y),
    .sample (chroma_sample)
);

endmodule
