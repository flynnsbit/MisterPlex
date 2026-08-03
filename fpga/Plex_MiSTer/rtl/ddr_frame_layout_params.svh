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

// ---- Opt-in 720p / Option-C tier (mirror kPlex720p* in ddr_frame_layout.hpp) ----
// Product synthesis still uses DDR_FRAME_* 480p above. Option-C phys after ring.
// Reader selects Option-C when geom_enable AND storage I420 does not fit legacy
// *usable* payload = bank_stride - 0x1000 (520192), NOT full 524288 and NOT
// coded_w>=1280. Product STORAGE is 960×540 / 777600 B (ARM/libavcodec crop).
// Canvas DE is 1280×720 — separate from rt_coded_* storage. SPS coded 544 is
// bitstream/fabric-decoder only. FABRIC_NATIVE_720P_GEOM forces 1280 canvas demo.
localparam int DDR_FRAME_720P_CODED_WIDTH = 1280;
localparam int DDR_FRAME_720P_CODED_HEIGHT = 720;
localparam int DDR_FRAME_720P_DISPLAY_WIDTH = 1280;
localparam int DDR_FRAME_720P_DISPLAY_HEIGHT = 720;
localparam int DDR_FRAME_720P_PRESENTED_WIDTH = 1280;
localparam int DDR_FRAME_720P_PRESENTED_HEIGHT = 720;
localparam int DDR_FRAME_720P_CROP_LEFT = 0;
localparam int DDR_FRAME_720P_CROP_RIGHT = 0;
localparam int DDR_FRAME_720P_CROP_TOP = 0;
localparam int DDR_FRAME_720P_CROP_BOTTOM = 0;
localparam int DDR_FRAME_720P_PILLARBOX_LEFT = 0;
localparam int DDR_FRAME_720P_PILLARBOX_RIGHT = 0;
localparam int DDR_FRAME_720P_YUV_LUMA_LINE_QWORDS = 160;
localparam int DDR_FRAME_720P_YUV_CHROMA_LINE_QWORDS = 80;
localparam int DDR_FRAME_720P_YUV420P_BYTES = 1382400;
localparam int DDR_FRAME_720P_Y_PLANE_OFFSET = 0;
localparam int DDR_FRAME_720P_U_PLANE_OFFSET = 921600;
localparam int DDR_FRAME_720P_V_PLANE_OFFSET = 1152000;
localparam int DDR_FRAME_720P_Y_STRIDE_BYTES = 1280;
localparam int DDR_FRAME_720P_CHROMA_STRIDE_BYTES = 640;
localparam int DDR_FRAME_720P_YUV420P_BANK_STRIDE = 32'h0018_0000;
localparam int DDR_FRAME_720P_PHYS_BASE = 32'h3018_0000;
localparam int DDR_FRAME_720P_YUV420P_DOORBELL_PHYS = 32'h3047_F000;

