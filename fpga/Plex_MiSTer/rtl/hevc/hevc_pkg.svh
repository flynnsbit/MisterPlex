// HEVC Phase 0 types. Banked RBF. Not compiled into the H.264 image.
`ifndef HEVC_PKG_SVH
`define HEVC_PKG_SVH

localparam int HEVC_CLK_DDR_MHZ = 90;
localparam int HEVC_CTB_MIN = 16;
localparam int HEVC_CTB_MAX = 32;

typedef enum logic [5:0] {
    HEVC_NAL_TRAIL_N   = 6'd0,
    HEVC_NAL_TRAIL_R   = 6'd1,
    HEVC_NAL_TSA_N     = 6'd2,
    HEVC_NAL_TSA_R     = 6'd3,
    HEVC_NAL_STSA_N    = 6'd4,
    HEVC_NAL_STSA_R    = 6'd5,
    HEVC_NAL_RADL_N    = 6'd6,
    HEVC_NAL_RADL_R    = 6'd7,
    HEVC_NAL_RASL_N    = 6'd8,
    HEVC_NAL_RASL_R    = 6'd9,
    HEVC_NAL_IDR_W     = 6'd19,
    HEVC_NAL_IDR_N     = 6'd20,
    HEVC_NAL_CRA       = 6'd21,
    HEVC_NAL_VPS       = 6'd32,
    HEVC_NAL_SPS       = 6'd33,
    HEVC_NAL_PPS       = 6'd34
} hevc_nal_type_e;

typedef enum logic [1:0] {
    HEVC_SLICE_B = 2'd0,
    HEVC_SLICE_P = 2'd1,
    HEVC_SLICE_I = 2'd2
} hevc_slice_type_e;

`endif
