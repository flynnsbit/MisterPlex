// DDR frame layout contract mirrored from host/libmisterplex/ddr_frame_layout.hpp.
// Product geometry: native 1280×720 I420 (identity coded=display=presented).
// Bank stride 0x180000 / doorbell 0x302FF000 from docs/evidence p720 layout_math
// (frame_bytes=1382400 fits; phys_base 0x30000000).
// Update host kPlex720p* + define-parity pairs together.

localparam int DDR_FRAME_CODED_WIDTH = 1280;
localparam int DDR_FRAME_CODED_HEIGHT = 720;
localparam int DDR_FRAME_DISPLAY_WIDTH = 1280;
localparam int DDR_FRAME_DISPLAY_HEIGHT = 720;
localparam int DDR_FRAME_PRESENTED_WIDTH = 1280;
localparam int DDR_FRAME_PRESENTED_HEIGHT = 720;
localparam int DDR_FRAME_CROP_LEFT = 0;
localparam int DDR_FRAME_CROP_RIGHT = 0;
localparam int DDR_FRAME_CROP_TOP = 0;
localparam int DDR_FRAME_CROP_BOTTOM = 0;
localparam int DDR_FRAME_PILLARBOX_LEFT = 0;
localparam int DDR_FRAME_PILLARBOX_RIGHT = 0;
// RGB565 line qwords for 1280: 1280*2/8 = 320 (legacy path; product is YUV)
localparam int DDR_FRAME_RGB565_LINE_QWORDS = 320;
localparam int DDR_FRAME_YUV_LUMA_LINE_QWORDS = 160;   // 1280/8
localparam int DDR_FRAME_YUV_CHROMA_LINE_QWORDS = 80;  // 1280/16
localparam int DDR_FRAME_RGB565_BYTES = 1843200;       // 1280*720*2
localparam int DDR_FRAME_YUV420P_BYTES = 1382400;      // 1280*720*3/2
localparam int DDR_FRAME_Y_PLANE_OFFSET = 0;
localparam int DDR_FRAME_U_PLANE_OFFSET = 921600;      // 1280*720
localparam int DDR_FRAME_V_PLANE_OFFSET = 1152000;     // Y + 640*360
localparam int DDR_FRAME_Y_STRIDE_BYTES = 1280;
localparam int DDR_FRAME_CHROMA_STRIDE_BYTES = 640;
localparam int DDR_FRAME_RGB565_BANK_STRIDE = 32'h0020_0000;
localparam int DDR_FRAME_YUV420P_BANK_STRIDE = 32'h0018_0000;
localparam int DDR_FRAME_RGB565_DOORBELL_PHYS = 32'h303F_F000;
localparam int DDR_FRAME_YUV420P_DOORBELL_PHYS = 32'h302F_F000;
localparam int DDR_FRAME_YUV_BLACK_Y = 16;
localparam int DDR_FRAME_YUV_BLACK_U = 128;
localparam int DDR_FRAME_YUV_BLACK_V = 128;
