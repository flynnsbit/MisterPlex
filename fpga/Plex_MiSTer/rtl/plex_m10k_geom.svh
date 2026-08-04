// plex_m10k_geom.svh — Cyclone V M10K geometry for Path A present buffers.
//
// CONTROL (handbook class, not a fit measurement):
//   Intel Cyclone V M10K block = 10_240 bits.
//   One 1280×8-bit luma line = 1280*8 = 10_240 bits = **exactly 1.0 M10K** (ideal packing).
//   One 640×8-bit I420 chroma line = 640*8 = 5_120 bits = **0.5 M10K** ideal.
//
// Ideal bit math ≠ post-fit block count (shallow/wide RAMs pack poorly). Product
// linebuf cost must still be gated against measured fstore M10K (see
// test_720p_present_m10k_budget_static). These constants size *new* scaler RAMs.

localparam int PLEX_M10K_BITS           = 10_240;
localparam int PLEX_M10K_LUMA_LINE_1280 = 1;   // 1280*8 / 10240
localparam int PLEX_M10K_CHROMA_LINE_640 = 1;  // ceil(0.5) → 1 block if alone
localparam int PLEX_720P_LUMA_LINES     = 720;
// Parent check: 356 free M10K ≈ 356 ideal luma lines ≈ half of 720 (360). Luma-only.
localparam int PLEX_M10K_FREE_POSTSTRIP = 356; // parent nostub-poststrip1 MEASURED
localparam int PLEX_M10K_CHIP_POSTSTRIP = 197; // parent MEASURED HIT vs prereg 197
// Full 720p I420 frame in BRAM: 1382400*8/10240 ≈ 1078 M10K — does NOT fit in 356.
localparam int PLEX_M10K_FULL_I420_720P_IDEAL = 1078;
