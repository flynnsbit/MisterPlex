// DDR frame layout contract mirrored from host/libmisterplex/ddr_frame_layout.hpp.
// The C++ unit/RTL invariant tests compare these values against the host header;
// update both sides together if the stream geometry or bank layout changes.

localparam int DDR_FRAME_CODED_WIDTH = 624;
localparam int DDR_FRAME_CODED_HEIGHT = 480;
localparam int DDR_FRAME_DISPLAY_WIDTH = 618;
localparam int DDR_FRAME_DISPLAY_HEIGHT = 480;
localparam int DDR_FRAME_PRESENTED_WIDTH = 640;
localparam int DDR_FRAME_PRESENTED_HEIGHT = 480;
localparam int DDR_FRAME_CROP_LEFT = 0;
localparam int DDR_FRAME_CROP_RIGHT = 6;
localparam int DDR_FRAME_CROP_TOP = 0;
localparam int DDR_FRAME_CROP_BOTTOM = 0;
localparam int DDR_FRAME_PILLARBOX_LEFT = 11;
localparam int DDR_FRAME_PILLARBOX_RIGHT = 11;
localparam int DDR_FRAME_RGB565_LINE_QWORDS = 156;
localparam int DDR_FRAME_YUV_LUMA_LINE_QWORDS = 78;
localparam int DDR_FRAME_YUV_CHROMA_LINE_QWORDS = 39;
localparam int DDR_FRAME_RGB565_BYTES = 599040;
localparam int DDR_FRAME_YUV420P_BYTES = 449280;
localparam int DDR_FRAME_Y_PLANE_OFFSET = 0;
localparam int DDR_FRAME_U_PLANE_OFFSET = 299520;
localparam int DDR_FRAME_V_PLANE_OFFSET = 374400;
localparam int DDR_FRAME_Y_STRIDE_BYTES = 624;
localparam int DDR_FRAME_CHROMA_STRIDE_BYTES = 312;
localparam int DDR_FRAME_RGB565_BANK_STRIDE = 32'h000C_0000;
localparam int DDR_FRAME_YUV420P_BANK_STRIDE = 32'h0008_0000;
localparam int DDR_FRAME_RGB565_DOORBELL_PHYS = 32'h3017_F000;
localparam int DDR_FRAME_YUV420P_DOORBELL_PHYS = 32'h300F_F000;
localparam int DDR_FRAME_YUV_BLACK_Y = 16;
localparam int DDR_FRAME_YUV_BLACK_U = 128;
localparam int DDR_FRAME_YUV_BLACK_V = 128;

// ---- 720p tier (opt-in present path; geom/PLXG handshake) ----
// Landed for hierarchy/parity. Default present path still uses 480p constants
// above. Do not retarget PRESENTED_* product defaults here.
// Synthesizable view: rtl/ddr_i420_bank_geom.sv (w-path; M10K=0).
localparam int DDR_FRAME_720P_CODED_WIDTH = 1280;
localparam int DDR_FRAME_720P_CODED_HEIGHT = 720;
localparam int DDR_FRAME_720P_DISPLAY_WIDTH = 1280;
localparam int DDR_FRAME_720P_DISPLAY_HEIGHT = 720;
localparam int DDR_FRAME_720P_PRESENTED_WIDTH = 1280;
localparam int DDR_FRAME_720P_PRESENTED_HEIGHT = 720;
localparam int DDR_FRAME_720P_PILLARBOX_LEFT = 0;
localparam int DDR_FRAME_720P_PILLARBOX_RIGHT = 0;
localparam int DDR_FRAME_720P_YUV420P_BYTES = 1382400;
localparam int DDR_FRAME_720P_Y_PLANE_OFFSET = 0;
localparam int DDR_FRAME_720P_U_PLANE_OFFSET = 921600;
localparam int DDR_FRAME_720P_V_PLANE_OFFSET = 1152000;
localparam int DDR_FRAME_720P_Y_STRIDE_BYTES = 1280;
localparam int DDR_FRAME_720P_CHROMA_STRIDE_BYTES = 640;
localparam int DDR_FRAME_720P_YUV_LUMA_LINE_QWORDS = 160;
localparam int DDR_FRAME_720P_YUV_CHROMA_LINE_QWORDS = 80;
localparam int DDR_FRAME_720P_YUV420P_BANK_STRIDE = 32'h0018_0000;
localparam int DDR_FRAME_720P_PHYS_BASE = 32'h3018_0000;
localparam int DDR_FRAME_720P_YUV420P_DOORBELL_PHYS = 32'h3047_F000;
