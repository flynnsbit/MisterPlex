// plex_m10k_geom.svh — Cyclone V M10K geometry for Path A present buffers.
//
// =====================================================================
// PARENT CORRECTION 2026-08-04 — "1280 bytes = 1 M10K" WAS WRONG AS STATED
// =====================================================================
// Control: Intel Cyclone V Device Handbook, M10K supported configurations:
//   8K×1 | 4K×2 | 2K×4 | 2K×5 | 1K×8 | 1K×10
//   512×16 | 512×20 | 256×32 | 256×40   (40b = max width)
// Depths are powers of two. **1280 words × 8 bits is NOT a legal config.**
//
// Bit capacity is still 10_240 bits/block. What changes is reachable bytes
// at a given port width:
//
//   Layout                         Bytes/block   1280×8 luma line cost
//   ------------------------------ ------------  -----------------------
//   Naive byte port (1K×8)         1_024         **2 M10K** (1024+256)
//   Packed 40-bit (256×40, 5 px/w) 1_280         **1 M10K** (5-px granular!)
//   Bit-capacity lower bound       1_280 bits/8  1.0 (NOT a legal port)
//
// Packed 40-bit hits 1280 B/block but FORCES 5-pixel-granular access —
// design input for scaler phase / addressing, not a free lunch.
//
// Post-strip budget (parent MEASURED fit, layout-independent):
//   chip 197 / free 356 M10K — still solid.
// Ideal bit math ≠ post-fit block count. Prefer measured entity rows when
// available; until then publish NAIVE_X8 and PACK40 bounds, not a single lie.

localparam int PLEX_M10K_BITS = 10_240;

// Legal max bytes at common widths (handbook configs above).
localparam int PLEX_M10K_BYTES_1K_X8   = 1_024; // 1K × 8
localparam int PLEX_M10K_BYTES_256_X40 = 1_280; // 256 × 40 = 5 bytes/word

// 1280-px × 8-bit luma line cost by layout (ESTIMATE — fit UNVERIFIED).
localparam int PLEX_M10K_LUMA_LINE_1280_NAIVE_X8 = 2; // ceil(1280/1024)
localparam int PLEX_M10K_LUMA_LINE_1280_PACK40   = 1; // 256 words × 40b
// RETRACTED name kept as alias to NAIVE so old refs fail closed if == 1 assumed:
// Do NOT use PLEX_M10K_LUMA_LINE_1280 == 1 without stating PACK40.
localparam int PLEX_M10K_LUMA_LINE_1280 = PLEX_M10K_LUMA_LINE_1280_NAIVE_X8;

// 640-px × 8-bit chroma line: fits one 1K×8 block (640 < 1024).
localparam int PLEX_M10K_CHROMA_LINE_640_NAIVE_X8 = 1;

localparam int PLEX_720P_LUMA_LINES = 720;

// Parent MEASURED post-strip (nostub-poststrip1) — budget total UNAFFECTED.
localparam int PLEX_M10K_FREE_POSTSTRIP = 356;
localparam int PLEX_M10K_CHIP_POSTSTRIP = 197;

// Full 720p I420 frame BRAM cost:
//   Bit-capacity lower bound: 1_382_400 * 8 / 10_240 ≈ 1078 M10K
//   Naive 1K×8 linebufs: Y 720*2 + U 360*1 + V 360*1 = 2160 M10K
// Neither fits in 356 free.
localparam int PLEX_M10K_FULL_I420_720P_BIT_IDEAL = 1078;
localparam int PLEX_M10K_FULL_I420_720P_NAIVE_X8  = 2160;
// Alias for older gates (bit ideal).
localparam int PLEX_M10K_FULL_I420_720P_IDEAL = PLEX_M10K_FULL_I420_720P_BIT_IDEAL;

// How far 356 free goes as *luma lines* (not "half frame" without layout):
//   NAIVE_X8: 356/2 = 178 luma lines
//   PACK40:   356/1 = 356 luma lines
localparam int PLEX_M10K_FREE_LUMA_LINES_NAIVE_X8 = PLEX_M10K_FREE_POSTSTRIP /
	PLEX_M10K_LUMA_LINE_1280_NAIVE_X8;
localparam int PLEX_M10K_FREE_LUMA_LINES_PACK40 = PLEX_M10K_FREE_POSTSTRIP /
	PLEX_M10K_LUMA_LINE_1280_PACK40;
