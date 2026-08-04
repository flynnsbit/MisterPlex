// plex_m10k_geom.svh — Cyclone V M10K geometry for Path A present buffers.
//
// =====================================================================
// PARENT CORRECTION 2026-08-04 — "1280 bytes = 1 M10K" WAS WRONG AS STATED
// =====================================================================
// Handbook legal configs (depths power-of-two):
//   8K×1 | 4K×2 | 2K×4 | 2K×5 | 1K×8 | 1K×10
//   512×16 | 512×20 | 256×32 | 256×40   (40b = max width)
// **1280 words × 8 bits is NOT a legal config.** Bit capacity still 10_240.
//
// =====================================================================
// rd-duck MEASURED control — product line_buf_ram is 64-bit QWORD class
// =====================================================================
// Artifact: nostub-poststrip1 Plex.fit.rpt leaf
//   |line_buf_ram:gen_line[*].{y,u,v}ram|
//   Y 78×64 useful 4992 → **2 M10K**; U/V 39×64 → **2 M10K each**
//   LINE_SLOTS=16 (LINE_COUNT=8) → 16×(2+2+2) = **96 M10K MEASURED**
// Width 64 + non-power-of-two depth pack to 2 blocks/plane even when bits ≪ 2×10240.
// This is the PRODUCT store layout — not byte-wide 1K×8.
//
// 720p EST same 64b class (LINE_COUNT=16 → 32 slots):
//   Y 160×64 + U 80×64 + V 80×64 = **6 M10K/slot** → **192 M10K EST**
// Alternatives (architectural, not product today):
//   byte-wide 1K×8: Y2+U1+V1 = 4/slot ×32 = **128 M10K EST**
//   pack40 256×40:  Y1+U1+V1 = 3/slot ×32 = **96 M10K EST** (+ 64↔40 gearbox)
//
// Path A present_nn_linebuf_scaler is RGB24 `reg [23:0]` hold — different
// layout class; publish bit_ideal + naive_x8 until a fitter entity row exists.
//
// Post-strip budget (parent MEASURED, layout-independent): 197 chip / 356 free.

localparam int PLEX_M10K_BITS = 10_240;

// Legal max bytes at common handbook widths.
localparam int PLEX_M10K_BYTES_1K_X8   = 1_024; // 1K × 8
localparam int PLEX_M10K_BYTES_256_X40 = 1_280; // 256 × 40 = 5 bytes/word

// ---- Byte-wide / pack40 (alternate addressing; NOT product store) ----
localparam int PLEX_M10K_LUMA_LINE_1280_NAIVE_X8 = 2; // ceil(1280/1024)
localparam int PLEX_M10K_LUMA_LINE_1280_PACK40   = 1; // 256×40, 5-px granular
localparam int PLEX_M10K_LUMA_LINE_1280 = PLEX_M10K_LUMA_LINE_1280_NAIVE_X8;
localparam int PLEX_M10K_CHROMA_LINE_640_NAIVE_X8 = 1;

// ---- Product 64-bit qword line_buf_ram (rd-duck MEASURED @480p) ----
// Per plane per slot M10K — both 78×64 and 39×64 measured 2.
localparam int PLEX_M10K_LINE_PLANE_64B_MEASURED = 2;
// Per dual-set slot (Y+U+V) @480p measured / @720p EST same packing class.
localparam int PLEX_M10K_LINE_SLOT_YUV_64B = 6; // 2+2+2
// 480p LINE_COUNT=8 → LINE_SLOTS=16 → 16*6 = 96 MEASURED.
localparam int PLEX_M10K_STORE_LINEBUF_480P_MEASURED = 96;
// 720p LINE_COUNT=16 → LINE_SLOTS=32 → 32*6 = 192 EST (unfitted).
localparam int PLEX_M10K_STORE_LINEBUF_720P_64B_EST = 192;
// Alternates for 720p 32 slots (ESTIMATE — not product RTL today):
localparam int PLEX_M10K_STORE_LINEBUF_720P_NAIVE_X8_EST = 128; // 4/slot
localparam int PLEX_M10K_STORE_LINEBUF_720P_PACK40_EST   = 96;  // 3/slot + gearbox

localparam int PLEX_720P_LUMA_LINES = 720;

// Parent MEASURED post-strip (nostub-poststrip1) — budget total UNAFFECTED.
localparam int PLEX_M10K_FREE_POSTSTRIP = 356;
localparam int PLEX_M10K_CHIP_POSTSTRIP = 197;

// Full 720p I420 frame BRAM (not linebufs) — neither fits 356 free.
localparam int PLEX_M10K_FULL_I420_720P_BIT_IDEAL = 1078;
localparam int PLEX_M10K_FULL_I420_720P_NAIVE_X8  = 2160;
localparam int PLEX_M10K_FULL_I420_720P_IDEAL = PLEX_M10K_FULL_I420_720P_BIT_IDEAL;

// Free luma lines if spending all 356 on 1280×8 (not store qword class):
localparam int PLEX_M10K_FREE_LUMA_LINES_NAIVE_X8 = PLEX_M10K_FREE_POSTSTRIP /
	PLEX_M10K_LUMA_LINE_1280_NAIVE_X8; // 178
localparam int PLEX_M10K_FREE_LUMA_LINES_PACK40 = PLEX_M10K_FREE_POSTSTRIP /
	PLEX_M10K_LUMA_LINE_1280_PACK40;   // 356

// Headroom after 720p store linebufs (64b EST) in free 356:
//   356 - 192 = 164 M10K left for copy bounce + scaler hold + OSD …
localparam int PLEX_M10K_HEADROOM_AFTER_720P_LINEBUF_64B_EST =
	PLEX_M10K_FREE_POSTSTRIP - PLEX_M10K_STORE_LINEBUF_720P_64B_EST; // 164
