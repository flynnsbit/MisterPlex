// DDR frame layout contract mirrored from host/libmisterplex/ddr_frame_layout.hpp.
// The C++ unit/RTL invariant tests compare these values against the host header;
// update both sides together if the stream geometry or bank layout changes.
//
// PRODUCT MAX TIER (ascal_true_de_960): DDR_FRAME_PRESENTED_* = 960×540 ceiling.
// Runtime DE tracks delivered content (PMS does not upscale; smaller sources stay
// native). CODED/DISPLAY/bank plane defaults below remain the LEGACY 480p silicon
// canvas used when geom_enable=0 without OPTION_C. Under `define OPTION_C,
// ddr_frame_store re-bases LEG_* bank map to Option-C PHYS/stride/doorbell so a
// geom-off path cannot sit on 0x30000000/0x80000 while the campaign max tier is
// 960×540 (B1). FRAME_W=960 QSF alone does NOT re-base the store.
//
// LEGACY 480p constants: DDR_FRAME_LEGACY480_* (dual-header ↔ kPlex480p*).
// AGGRESSIVE 720p canvas: DDR_FRAME_720P_* — Option-C after bitstream ring.

// ---- Product presented max tier (runtime-variable true-DE ceiling) ----
// Gate/layout lock: PRESENTED names the max glass-side content tier, not a fixed
// raster. CODED_* below stay legacy 480p storage defaults for geom_enable=0.
localparam int DDR_FRAME_PRESENTED_WIDTH = 960;
localparam int DDR_FRAME_PRESENTED_HEIGHT = 540;

// ---- Legacy 480p storage/bank defaults (geom_enable=0 without OPTION_C) ----
localparam int DDR_FRAME_CODED_WIDTH = 624;
localparam int DDR_FRAME_CODED_HEIGHT = 480;
localparam int DDR_FRAME_DISPLAY_WIDTH = 618;
localparam int DDR_FRAME_DISPLAY_HEIGHT = 480;
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
// Bootstrap control page (PLXG/PLXC) stays on legacy doorbell even under Option-C
// banks — chicken-egg safe. Frame payload doorbell may move with OPTION_C re-base.
localparam int DDR_FRAME_YUV420P_DOORBELL_PHYS = 32'h300F_F000;
localparam int DDR_FRAME_YUV_BLACK_Y = 16;
localparam int DDR_FRAME_YUV_BLACK_U = 128;
localparam int DDR_FRAME_YUV_BLACK_V = 128;

// Explicit legacy-480 aliases (dual-header ↔ kPlex480pPresented*).
localparam int DDR_FRAME_LEGACY480_PRESENTED_WIDTH = 640;
localparam int DDR_FRAME_LEGACY480_PRESENTED_HEIGHT = 480;
localparam int DDR_FRAME_LEGACY480_CODED_WIDTH = 624;
localparam int DDR_FRAME_LEGACY480_CODED_HEIGHT = 480;
localparam int DDR_FRAME_LEGACY480_YUV420P_BANK_STRIDE = 32'h0008_0000;
localparam int DDR_FRAME_LEGACY480_YUV420P_DOORBELL_PHYS = 32'h300F_F000;
localparam int DDR_FRAME_LEGACY480_PHYS_BASE = 32'h3000_0000;

// ---- Aggressive 720p tier (opt-in; requires RBF + daemon PLXG handshake) ----
// Geometry: coded=display=presented 1280x720 identity (16:9, no pillar).
// phys_base Option-C 0x30180000 (after bitstream ring @ 0x30100000 / PLXB @ 0x30140000).
// bank_stride = alignUp(1382400, 256KiB) = 0x180000; doorbell = base + 2*stride - 0x1000.
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
// Parent-verified 2026-08-02: memmap=513M$511M reserves 0x1FF00000..0x40000000;
// Option-C window unclaimed in /proc/iomem. DDR headroom is abundant.
localparam int DDR_FRAME_RESERVED_WINDOW_START = 32'h1FF0_0000;
localparam int DDR_FRAME_RESERVED_WINDOW_END   = 32'h4000_0000;
// 2-bank product map end (doorbell page + 4KiB) and optional 3-bank map size.
localparam int DDR_FRAME_720P_MAP_BYTES_2BANK = 32'h0030_0000; // 2*0x180000
localparam int DDR_FRAME_720P_MAP_BYTES_3BANK = 32'h0048_0000; // 3*0x180000 triple
// Triple-buffer doorbell candidate (base+3*stride-0x1000) — not product until
// ddr_frame_store bank field widens beyond 1 bit.
localparam int DDR_FRAME_720P_TRIPLE_DOORBELL_PHYS = 32'h305F_F000;
// PLXG geometry mailbox offset from active doorbell (ARM→FPGA program word).
// FIXED wire ABI (parent freeze) — independent of chrome MAX_CMDS / list depth.
localparam int DDR_FRAME_PLXG_OFFSET = 32'h800;

// ---- Compressed bitstream ring (fabric-decode ingest; product PLXB path) ----
// Must stay clear of Option-C banks and PL330 scratch. Host mirror:
// host/libmisterplex/ddr_bitstream_ring.hpp
localparam int DDR_BITSTREAM_RING_DATA_PHYS = 32'h3010_0000;
localparam int DDR_BITSTREAM_RING_BYTES     = 262144; // 256 KiB, power-of-two
localparam int DDR_BITSTREAM_RING_CTRL_PHYS = 32'h3014_0000; // PLXB
localparam int DDR_BITSTREAM_RING_READ_PHYS = 32'h3014_0008; // PLXR
localparam int DDR_BITSTREAM_RING_ERR_PHYS  = 32'h3014_0010; // PLXE
localparam int DDR_BITSTREAM_RECORD_HEADER_BYTES = 32;
// PL330 after Option-C triple end (w-path) — collision fence only
localparam int DDR_PL330_SCRATCH_PHYS = 32'h3060_0000;
// Parent-measured AU sizes (real720p_2600k.mp4). Ring headroom uses WORST keyframe.
localparam int DDR_BITSTREAM_MEASURED_MEAN_AU_BYTES  = 13507;
localparam int DDR_BITSTREAM_MEASURED_MIN_AU_BYTES   = 413;
localparam int DDR_BITSTREAM_MEASURED_WORST_AU_BYTES = 60915;
localparam int DDR_BITSTREAM_MIN_WORST_AU_SLOTS      = 3;
localparam int DDR_BITSTREAM_WORST_AU_RECORD_BYTES =
    DDR_BITSTREAM_RECORD_HEADER_BYTES + DDR_BITSTREAM_MEASURED_WORST_AU_BYTES; // 60947
// Fabric-decode stream expectation (parent-measured PMS): Constrained Baseline
// CAVLC, no B-frames. profile_idc=66. CABAC not present in RTL — refuse in host gate.
localparam int DDR_BITSTREAM_PROFILE_IDC_BASELINE = 66;
localparam int DDR_BITSTREAM_CODEC_FLAG_CONSTRAINT_SET1 = 1;
localparam int DDR_BITSTREAM_CODEC_FLAG_CABAC = 2;
// H.264 level: product REQUESTS 30; PMS DELIVERS 31 for 1280x720 (MaxFS).
// DPB / ref buffer sizing must use delivered level (see h264_level_limits.hpp).
localparam int DDR_H264_REQUESTED_LEVEL = 30;
localparam int DDR_H264_DELIVERED_LEVEL_720P = 31;
localparam int DDR_H264_720P_FRAME_SIZE_MBS = 3600; // 80*45
localparam int DDR_H264_L31_MAX_DPB_FRAMES_720P = 5; // 18000/3600
localparam int DDR_H264_OPTIONC_PRESENT_BANKS = 2;   // display double-buffer != DPB
// Product 720p OUTPUT path (parent 2026-08-03): ARM source 960x540 native push,
// fabric upscales to 1280x720 canvas. NOT 720p source. PLXG native_push=1.
// Tight content layout (native_push=1): strides are CONTENT, not canvas 1280.
// Using canvas Y_STRIDE on a 960-wide tight payload shears (88509163-class).
// Display 960x540 (not MB-aligned); MB-coded 960x544 for bitstream only.
// Bank map: capacity (frame_bytes > legacy 0x80000) → Option-C — NOT width>=1280.
localparam int DDR_FRAME_720P_OUTPUT_SOURCE_WIDTH = 960;
localparam int DDR_FRAME_720P_OUTPUT_SOURCE_HEIGHT = 540;
localparam int DDR_FRAME_720P_OUTPUT_SOURCE_BYTES = 777600; // display tight I420
localparam int DDR_FRAME_720P_OUTPUT_SOURCE_DISPLAY_WIDTH = 960;
localparam int DDR_FRAME_720P_OUTPUT_SOURCE_DISPLAY_HEIGHT = 540;
localparam int DDR_FRAME_720P_OUTPUT_SOURCE_CODED_WIDTH = 960;
localparam int DDR_FRAME_720P_OUTPUT_SOURCE_CODED_HEIGHT = 544;
localparam int DDR_FRAME_720P_OUTPUT_SOURCE_DISPLAY_BYTES = 777600;
localparam int DDR_FRAME_720P_OUTPUT_SOURCE_CODED_BYTES = 783360;
localparam int DDR_FRAME_720P_OUTPUT_Y_STRIDE_BYTES = 960;
localparam int DDR_FRAME_720P_OUTPUT_CHROMA_STRIDE_BYTES = 480;
localparam int DDR_FRAME_720P_OUTPUT_Y_PLANE_OFFSET = 0;
localparam int DDR_FRAME_720P_OUTPUT_U_PLANE_OFFSET = 518400; // 960*540
localparam int DDR_FRAME_720P_OUTPUT_V_PLANE_OFFSET = 648000; // 518400+480*270
localparam int DDR_FRAME_720P_OUTPUT_Y_LINE_QWORDS = 120;     // 960/8
localparam int DDR_FRAME_720P_OUTPUT_CHROMA_LINE_QWORDS = 60; // 480/8
// Legacy bank stride and *usable* capacity. Doorbell page steals the last 4 KiB
// of the two-bank window (doorbell = base + 2*stride - 0x1000), so bank1 payload
// must fit in stride - 0x1000. Selector must use usable, not full stride.
localparam int DDR_FRAME_LEGACY_BANK_STRIDE_BYTES = 32'h0008_0000; // 524288
localparam int DDR_FRAME_BANK_DOORBELL_PAGE_BYTES = 32'h1000;      // 4096
localparam int DDR_FRAME_LEGACY_BANK_USABLE_BYTES = 32'h0007_F000; // 520192 = 0x80000-0x1000
localparam int DDR_FRAME_720P_BANK_USABLE_BYTES = 32'h0017_F000;   // 1568768 = 0x180000-0x1000
