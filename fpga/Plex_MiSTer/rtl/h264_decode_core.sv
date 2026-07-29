// h264_decode_core — Product H.264 decode datapath skeleton.
// This module replaces decode_stub.sv in the product path. It instantiates
// and connects the individually-verified arithmetic/prediction modules into
// a complete decode pipeline for Baseline Profile CAVLC streams.
//
// STATUS: PARTIAL PRODUCT DATAPATH.
//         Product DPB writeback, P16 syntax handoff, MV prediction state, and
//         an initial scheduled P16 luma CAVLC/IDCT residual traversal are
//         wired. Full residual traversal, P partition modes, deblock, and full
//         decode scheduling remain open.
//
// OWNERSHIP: w-rel (decode datapath integration)
// CONSUMERS: stream_path.sv (instantiates this)
// DEPS:      h264_cavlc_residual_block (w-level)
//            h264_dequant4x4, h264_idct4x4, h264_recon4x4 (w-cabac)
//            h264_intra4x4_pred, h264_intra16x16_pred, h264_chroma8x8_pred (w-plane)
//            h264_chroma_dc_hadamard_inv (w-plane)
//            h264_chroma_qp (w-qp)
//            h264_inter_mc_part (w-mc)
//            h264_dpb_one_ref (w-rel/w-dpb)
//            h264_deblock (w-deblock)

module h264_decode_core #(
    parameter int FRAME_W   = 320,
    parameter int FRAME_H   = 240,
    parameter int MB_W      = (FRAME_W + 15) / 16,
    parameter int MB_H      = (FRAME_H + 15) / 16,
    parameter int MB_COUNT  = MB_W * MB_H
)(
    input  wire        clk,
    input  wire        reset,

    // ── Slice header inputs (from slice_hdr_parser via stream_path) ──
    input  wire        slice_start,          // pulse: new slice available
    input  wire        slice_is_idr,
    input  wire        slice_is_i,
    input  wire [5:0]  slice_qp_y,           // SliceQPy = 26 + pic_init_qp + slice_qp_delta
    input  wire [15:0] first_mb_in_slice,
    input  wire [7:0]  mb_width,             // from SPS
    input  wire [7:0]  mb_height,            // from SPS

    // ── PPS parameters ──
    input  wire signed [4:0] pps_chroma_qp_index_offset, // se(), range [-12,+12]
    input  wire        constrained_intra_pred_flag,
    // num_ref_idx_l0_active_minus1 + 1, from the slice header or the PPS
    // default. When it is 1 the ref_idx_l0 syntax element is absent from the
    // bitstream entirely and the index is inferred as 0.
    input  wire [7:0]  num_ref_idx_l0_active,

    // ── In-loop deblocking filter controls (slice header) ──
    input  wire [1:0]  disable_deblocking_filter_idc,
    input  wire signed [4:0] slice_alpha_c0_offset,
    input  wire signed [4:0] slice_beta_offset,

    // ── Bitstream access (RBSP bytes for CAVLC residual parsing) ──
    // The CAVLC residual block decoder needs random-access to RBSP bits.
    // This interface provides a window of RBSP bytes around the current position.
    input  wire [7:0]  rbsp_byte [0:63],     // 64-byte window of RBSP data
    input  wire [15:0] rbsp_window_base,     // byte offset of rbsp_byte[0] in stream
    output wire [15:0] rbsp_request_offset,  // request: advance window to this offset
    output wire        rbsp_request_valid,

    // ── Macroblock type/mode from slice parser (per-MB) ──
    // w-level delivers these as it iterates through the slice.
    input  wire        mb_type_valid,        // pulse: mb_type decoded for current MB
    input  wire [4:0]  mb_type,              // H.264 mb_type for I/P slices
    input  wire        mb_skip,              // P-slice skip
    input  wire [3:0]  intra4x4_modes [0:15], // I_NxN: 9 modes per 4×4 block
    input  wire [1:0]  intra16x16_mode,      // I_16x16: 0=V, 1=H, 2=DC, 3=Plane
    input  wire [1:0]  chroma_pred_mode,     // 0=DC, 1=H, 2=V, 3=Plane
    input  wire [3:0]  cbp_luma,             // coded_block_pattern luma (4 8×8 groups)
    input  wire [1:0]  cbp_chroma,           // coded_block_pattern chroma (0=none,1=DC,2=DC+AC)
    input  wire signed [5:0] mb_qp_delta,    // se(), per-MB QP delta
    input  wire [15:0] mb_residual_bit_offset, // RBSP bit offset for this MB's residual syntax

    // ── Product intra luma residual block pulse interface (from CAVLC/parser) ──
    // Coefficients are H.264 zigzag/scan order. h264_dequant4x4 performs the
    // zigzag→raster placement internally before IDCT.
    input  wire        luma4x4_valid,
    input  wire [3:0]  luma4x4_idx,
    input  wire [5:0]  luma4x4_qp,
    input  wire [4:0]  luma4x4_total_coeff,
    input  wire [1:0]  luma4x4_trailing_ones,
    input  wire signed [15:0] luma4x4_coeff_zigzag [0:15],

    // ── Motion vector inputs (for P-slices, from w-mc MV predictor) ──
    input  wire signed [15:0] mv_x_qpel,     // quarter-pel MV x
    input  wire signed [15:0] mv_y_qpel,     // quarter-pel MV y
    input  wire [2:0]  part_mode,            // partition mode
    input  wire [1:0]  part_idx,             // sub-partition index
    input  wire signed [15:0] mvd_x_qpel,    // quarter-pel MVD x for current P partition
    input  wire signed [15:0] mvd_y_qpel,    // quarter-pel MVD y for current P partition
    input  wire [1:0]  ref_idx_l0,           // reference index for current P partition

    // ── Reconstructed macroblock input (from the decode/recon pipeline) ──
    // This is the product handoff into DPB writeback.  It is intentionally
    // sample-based: no synthetic fill is generated inside this module.
    input  wire        recon_mb_valid,        // pulse: recon_y/u/v contain one complete MB
    input  wire [7:0]  recon_mb_x,
    input  wire [7:0]  recon_mb_y,
    input  wire        recon_mb_is_ref,
    input  wire [31:0] dpb_write_base,
    input  wire [7:0]  recon_y [0:255],
    input  wire [7:0]  recon_u [0:63],
    input  wire [7:0]  recon_v [0:63],

    // ── First product P16×16 zero-MV reconstruction path ──
    // One full MB of residuals is provided by the future P residual walker.
    // This path fetches the co-located reference MB from DPB, clips
    // prediction+residual, and commits the reconstructed MB through the
    // product writeback address path below.
    input  wire        p16_zero_mv_valid,
    input  wire [7:0]  p16_mb_x,
    input  wire [7:0]  p16_mb_y,
    input  wire        p16_mb_is_ref,
    input  wire [31:0] dpb_ref_base,
    input  wire signed [15:0] p16_residual_y [0:255],
    input  wire signed [15:0] p16_residual_u [0:63],
    input  wire signed [15:0] p16_residual_v [0:63],

    // ── DPB memory interface (to external SRAM/DDR) ──
    // Write: decoded frame samples to reference store
    output wire        dpb_wr_en,
    output wire [31:0] dpb_wr_addr,
    output wire [7:0]  dpb_wr_data,
    // Read: reference fetch for inter prediction
    output wire        dpb_rd_en,
    output wire [31:0] dpb_rd_addr,
    input  wire [7:0]  dpb_rd_data,
    input  wire        dpb_rd_valid,
    // Backpressure from a variable-latency DPB (the DDR-resident store).
    // Tie low for a fixed-latency on-chip SRAM.
    input  wire        dpb_rd_stall,
    // Pulses on the exact edge the internal reference address generator moves
    // its current/reference bank pointers. A DDR-resident DPB must sequence
    // its own flush/invalidate from this, not from the frame_done output,
    // which is a later status signal.
    output wire        dpb_ref_swap,

    // ── Product present writeback (decoded samples to the display store) ──
    // Same committed sample stream as dpb_wr_*, but expressed as plane +
    // frame-relative (x,y) so the consumer owns the surface stride.  The DDR
    // frame store uses the CODED geometry (624x480), which is not the same as
    // this core's FRAME_W/FRAME_H present geometry, so a byte address computed
    // here would land on the wrong stride.
    output wire        px_wr_en,
    output wire [1:0]  px_wr_plane,          // 0=Y, 1=U, 2=V
    output wire [15:0] px_wr_x,
    output wire [15:0] px_wr_y,
    output wire [7:0]  px_wr_data,

    // ── Frame output (decoded frame to present path) ──
    output wire        frame_done,           // pulse: complete frame decoded
    output wire [15:0] frame_mb_count,       // MBs decoded this frame

    // ── Bitstream desynchronisation evidence (to h264_stream_recovery) ──
    // CAVLC is a variable-length code, so a wrong table entry consumes the
    // wrong number of bits and everything after it is meaningless.  These are
    // the cheap symptoms of that having happened.
    output wire        err_cavlc_miss,       // a VLC lookup matched no code
    output wire        err_bad_mb_type,      // mb_type illegal for the slice type
    output wire        err_mb_overrun,       // mb address ran past PicSizeInMbs

    // Low while the recovery logic is waiting for an IDR: no new macroblock
    // may launch, because the reference every P picture predicts from is
    // already corrupt.
    input  wire        decode_enable,

    // ── Throughput telemetry ──
    // Per-stage cycle accounting for the macroblock pipeline, published as one
    // rotating 64-bit mailbox word.  See h264_perf_counters.sv for the layout.
    output wire [63:0] perf_mbox_word,

    // ── Status/debug ──
    output wire        busy,
    output wire [7:0]  decode_state,         // FSM state for debug
    output wire [15:0] current_mb_addr,      // current MB being decoded
    output wire        error                 // unrecoverable decode error
);

    // ════════════════════════════════════════════════════════════════════
    // INTERNAL ARCHITECTURE (not yet implemented — interface contracts below)
    // ════════════════════════════════════════════════════════════════════
    //
    // The decode pipeline processes one macroblock at a time in raster order:
    //
    //  ┌─────────────────────────────────────────────────────────────────┐
    //  │ For each MB in slice:                                           │
    //  │  1. Determine mb_type, prediction mode, CBP, QP                 │
    //  │  2. For I_16x16: parse 16 DC coefficients → Hadamard            │
    //  │  3. For each of 24 blocks (16Y + 4Cb + 4Cr):                    │
    //  │     a. Compute nC from neighbours                               │
    //  │     b. Parse CAVLC residual (if CBP says block is coded)        │
    //  │     c. Place Hadamard DC at position [0] (I_16x16/chroma DC)    │
    //  │     d. Dequantize                                               │
    //  │     e. IDCT                                                     │
    //  │     f. Compute prediction (intra from neighbours, or MC fetch)  │
    //  │     g. Reconstruct: clip(pred + residual)                       │
    //  │     h. Store reconstructed samples in line buffer               │
    //  │  4. After all blocks: write MB to DPB                           │
    //  │  5. After all MBs: deblock filter → reference frame update      │
    //  └─────────────────────────────────────────────────────────────────┘
    //
    // ════════════════════════════════════════════════════════════════════
    // INTERFACE CONTRACTS (what each sub-module expects)
    // ════════════════════════════════════════════════════════════════════
    //
    // h264_cavlc_residual_block (w-level):
    //   IN:  start, coeff_token_table[2:0], max_coeff[4:0],
    //        bit_offset_start[9:0], bit_len[9:0], rbsp[0:63]
    //   OUT: busy, done, ok, bit_offset_end[9:0], total_coeff[4:0],
    //        trailing_ones[1:0], total_zeros[3:0],
    //        coefficients signed [15:0] [0:15]
    //   CONTRACT: Start pulse → busy high → done pulse with coefficients.
    //             Caller must not re-start until done.
    //             nC context comes from h264_cavlc_nc_predictor.
    //
    // h264_dequant4x4 (w-cabac):
    //   IN:  coeff signed [15:0] [0:15], qp[5:0], max_coeff[4:0]
    //   OUT: dequant signed [28:0] [0:15]
    //   CONTRACT: Combinational. Width: 29 bits end-to-end.
    //
    // h264_idct4x4 (w-cabac):
    //   IN:  dequant signed [28:0] [0:15]
    //   OUT: residual signed [28:0] [0:15]
    //   CONTRACT: Combinational. Butterfly + shift.
    //
    // h264_recon4x4 (w-cabac):
    //   IN:  pred[7:0] [0:15], residual signed [28:0] [0:15]
    //   OUT: recon[7:0] [0:15]
    //   CONTRACT: Combinational. clip(pred + (residual >> 6), 0, 255).
    //
    // h264_intra4x4_pred (w-plane):
    //   IN:  mode[3:0], above[7:0][0:7], left[7:0][0:3], top_left[7:0],
    //        has_above, has_left
    //   OUT: used_mode[3:0], pred[7:0][0:15]
    //   CONTRACT: Combinational. 9 modes. Needs 4 above + 4 above-right +
    //             4 left + 1 top-left from reconstructed neighbours.
    //
    // h264_intra16x16_pred (w-plane):
    //   IN:  mode[1:0], above[7:0][0:15], left[7:0][0:15], top_left[7:0],
    //        has_above, has_left
    //   OUT: unsupported, pred[7:0][0:255]
    //   CONTRACT: Combinational. 4 modes (V/H/DC/Plane).
    //             Needs full top row (16) + full left column (16) + top-left.
    //
    // h264_chroma8x8_pred (w-plane):
    //   IN:  mode[1:0], above[7:0][0:7], left[7:0][0:7], top_left[7:0],
    //        has_above, has_left
    //   OUT: pred[7:0][0:63]
    //   CONTRACT: Combinational. Same 4 modes as I16x16, on 8×8 block.
    //
    // h264_chroma_dc_hadamard_inv (w-plane):
    //   IN:  coeff signed [15:0] [0:3], qp[5:0]
    //   OUT: dc signed [17:0] [0:3]
    //   CONTRACT: Combinational. QPc input (post chroma QP mapping).
    //
    // h264_chroma_qp (w-qp):
    //   IN:  qp_y[5:0]
    //   OUT: qp_c[5:0]
    //   CONTRACT: Combinational. Table 8-15 lookup.
    //
    // h264_inter_mc_part (w-mc):
    //   IN:  luma_ref_win[7:0][0:440], chroma_u/v_ref_win[7:0][0:80],
    //        luma_frac_x/y[1:0], chroma_frac_x/y[2:0], part_w/h[4:0]
    //   OUT: pred_y[7:0][0:255], pred_u/v[7:0][0:63], valid flags
    //   CONTRACT: Combinational. 6-tap FIR for luma, bilinear for chroma.
    //
    // h264_dpb_one_ref (w-rel/w-dpb):
    //   IN:  fetch_start, fetch_mb_x/y, fetch_mv_x/y_qpel, etc.
    //   OUT: fetch_busy, fetch_done, luma/chroma window samples
    //   CONTRACT: Sequential. Issues memory reads, fills reference window.
    //             One cycle per sample read.
    //
    // h264_deblock (w-deblock):
    //   Operates on complete reconstructed MBs after decode.
    //   Needs: QP, mb_type of current and neighbours, MVs, recon samples.
    //   Writes filtered samples back to DPB reference slot.
    //   CONTRACT: Post-reconstruction, pre-DPB-commit for reference use.
    //
    // ════════════════════════════════════════════════════════════════════
    // NEIGHBOUR CONTEXT (w-ctl coordination point)
    // ════════════════════════════════════════════════════════════════════
    //
    // Two kinds of neighbour state needed:
    //   1. nC (total_coeff) per 4×4 block — for CAVLC table selection
    //      Storage: left column (4 values) + top row (4×MB_W values)
    //      Update: after each block's CAVLC parse
    //
    //   2. Reconstructed samples — for intra prediction
    //      Storage: left column (16Y+8U+8V) + top row (16×MB_W Y + 8×MB_W U/V)
    //      Update: after each block's reconstruction
    //
    // Both are "state indexed by neighbouring block position" and should
    // share the same line-buffer RAM infrastructure (w-ctl).
    //
    // ════════════════════════════════════════════════════════════════════

    // ════════════════════════════════════════════════════════════════════
    // PRODUCT DPB WRITEBACK
    // ════════════════════════════════════════════════════════════════════
    // Latch one reconstructed native-I420 macroblock, then stream 384 samples:
    //   Y:  16×16 samples (idx 0..255)
    //   U:   8×8 samples (idx 256..319)
    //   V:   8×8 samples (idx 320..383)
    //
    // Addressing is shared with h264_dpb_one_ref via h264_dpb_mb_write_addr,
    // so writeback and later MC fetch agree on native-I420 layout.
    // The P16 path uses the same external DPB read contract as the rest of the
    // product: h264_dpb_one_ref issues dpb_rd_en/dpb_rd_addr, then consumes a
    // later dpb_rd_valid to fill the block MC reference windows.
    localparam [7:0] ST_IDLE         = 8'd0;
    localparam [7:0] ST_WRITE        = 8'd1;
    localparam [7:0] ST_P16_REF_SEED = 8'd2;
    localparam [7:0] ST_P16_WIN_FETCH = 8'd3;
    localparam [7:0] ST_P16_WRITE    = 8'd4;
    localparam [7:0] ST_P16_RES_START = 8'd5;
    localparam [7:0] ST_P16_RES_WAIT  = 8'd6;
    localparam [7:0] ST_COMMIT        = 8'd7;
    localparam [7:0] ST_FRAME_BOUNDARY = 8'd8;
    localparam [7:0] ST_DEBLOCK       = 8'd12;
    localparam [7:0] ST_P16_WIN_START = 8'd9;
    localparam [7:0] ST_P16_RES_IDCT  = 8'd10;
    localparam [7:0] ST_P16_RES_EDGE  = 8'd11;
    // Motion compensation is now a multi-cycle engine rather than a
    // combinational function of the reference window, so it gets its own
    // state between the window fetch retiring and the prediction writeback.
    localparam [7:0] ST_P16_MC        = 8'd13;
    // Sequential M10K fill / residual store (one write port per array).
    localparam [7:0] ST_LATCH_RECON     = 8'd14;
    localparam [7:0] ST_P16_RES_STORE   = 8'd15;
    localparam [7:0] ST_P16_RES_ZERO    = 8'd16;
    localparam [7:0] ST_WRITE_PRIME     = 8'd17;
    localparam [7:0] ST_P16_WRITE_PRIME = 8'd18;
    localparam [7:0] ST_P16_LATCH_RES   = 8'd19;
    // Hold one cycle after arming M10K raddr so lat_*_q is valid before emit.
    localparam [7:0] ST_WRITE_HOLD      = 8'd20;
    localparam [7:0] ST_P16_WRITE_HOLD  = 8'd21;
    // ── Residual traversal steps, in H.264 residual() order ─────────────
    //   0       Intra16x16DCLevel     (16 coeff, only when the MB is I_16x16)
    //   1..16   luma 4x4 blkIdx 0..15 (15 coeff when I_16x16, else 16)
    //   17,18   chroma DC Cb then Cr  (4 coeff, coeff_token table 4)
    //   19..26  chroma AC Cb 0..3 then Cr 0..3 (15 coeff)
    localparam [4:0] RES_STEP_LUMA_DC    = 5'd0;
    localparam [4:0] RES_STEP_LUMA_AC0   = 5'd1;
    localparam [4:0] RES_STEP_CHROMA_DC0 = 5'd17;
    localparam [4:0] RES_STEP_CHROMA_AC0 = 5'd19;
    localparam [4:0] RES_STEP_LAST       = 5'd26;
    localparam int MB_IDX_W = (MB_W <= 1) ? 1 : $clog2(MB_W);
    localparam int CORE_MB_AW = (MB_COUNT <= 1) ? 1 : $clog2(MB_COUNT);

    reg [7:0]  wb_state;
    reg [8:0]  wb_idx;
    reg [7:0]  wb_mb_x;
    reg [7:0]  wb_mb_y;
    reg        wb_mb_is_ref;
    reg        wb_mb_is_intra;
    reg [5:0]  intra_qp_y_r;
    reg        dbf_start_r;
    reg        dbf_smp_valid_d;
    reg [8:0]  dbf_smp_idx_d;
    reg [7:0]  dbf_smp_data_d;
    reg [31:0] wb_base;
    reg [31:0] p16_ref_base_r;
    reg signed [15:0] p16_mv_x_qpel_r;
    reg signed [15:0] p16_mv_y_qpel_r;
    reg [1:0]  p16_ref_idx_l0_r;
    reg        p16_fetch_start_r;
    reg        p16_mc_start_r;
    reg        p16_ref_seed_r;
    reg [9:0]  p16_res_bit_offset_r;
    reg [4:0]  p16_res_block_idx;
    reg        cavlc_start_r;
    // Stage C residual scheduling context.
    //   cbp: H.264 7.4.5 -- a block whose coded_block_pattern bit is 0 has no
    //   bits in the stream at all. Decoding it anyway consumes bits belonging to
    //   the next block and desynchronises the rest of the macroblock.
    reg [3:0]  p16_cbp_luma_r;
    reg [1:0]  p16_cbp_chroma_r;
    //   nC: coeff_token table selection (H.264 9.2.1) needs total_coeff of the
    //   left and upper 4x4 neighbours. Kept as this macroblock's 16 values, the
    //   right column of the macroblock to the left, and a per-column line buffer
    //   of the bottom row of the macroblock row above (same shape as mv_top_*).
    reg [4:0]  res_tc_cur [0:15];
    reg [4:0]  res_tc_left [0:3];
    reg        res_tc_left_valid;
    reg [4:0]  res_tc_top [0:(MB_W*4)-1];
    reg        res_tc_top_valid [0:MB_W-1];
    //   Chroma nC context: 4 4x4 blocks per component. Index encoding is
    //   {component, block_y, block_x} for the current macroblock, {component,
    //   block_y} for the left column and {column, component, block_x} for the
    //   top line buffer.
    reg [4:0]  res_tc_cur_c [0:7];
    reg [4:0]  res_tc_left_c [0:3];
    reg [4:0]  res_tc_top_c [0:(MB_W*4)-1];
    //   DC coefficients that bypass the 4x4 scaler and are substituted into
    //   raster position 0 of every block of the plane (8.5.10 / 8.5.11).
    reg signed [28:0] res_luma_dc [0:15];
    reg signed [28:0] res_cdc_u [0:3];
    reg signed [28:0] res_cdc_v [0:3];
    reg        res_i16x16_r;
    reg        res_ac_from_cavlc;
    reg [5:0]  mb_qp_y_r;
    reg [5:0]  cur_qp_y_r;
    integer    res_tc_i;
    reg [15:0] syntax_mb_addr_r;
    reg [15:0] rbsp_request_offset_r;
    reg        rbsp_request_valid_r;
    reg signed [15:0] mv_top_x [0:MB_W-1];
    reg signed [15:0] mv_top_y [0:MB_W-1];
    reg [1:0]  mv_top_ref [0:MB_W-1];
    reg        mv_top_valid [0:MB_W-1];
    reg signed [15:0] mv_left_x;
    reg signed [15:0] mv_left_y;
    reg [1:0]  mv_left_ref;
    reg        mv_left_valid;
    reg [15:0] mb_count_r;
    reg        frame_done_r;
    reg        wb_commit_p16;
    // MB working buffers as discrete M10K instances (not FF planes).
    // Case-muxed multi-array always blocks OOMed quartus_map; one module
    // per plane matches line_buf_ram and maps cleanly.
    reg        lat_recon_we;
    reg [1:0]  lat_recon_wplane;
    reg [7:0]  lat_recon_waddr;
    reg [7:0]  lat_recon_wdata;
    reg [1:0]  lat_recon_rplane;
    reg [7:0]  lat_recon_raddr;
    wire [7:0] lat_recon_y_q;
    wire [7:0] lat_recon_u_q;
    wire [7:0] lat_recon_v_q;
    // rplane is registered one cycle before use (same as raddr).
    reg  [1:0] lat_recon_rplane_q;
    reg  [1:0] lat_res_rplane_q;
    wire [7:0] lat_recon_q = (lat_recon_rplane_q == 2'd0) ? lat_recon_y_q :
                             (lat_recon_rplane_q == 2'd1) ? lat_recon_u_q :
                                                           lat_recon_v_q;
    reg        lat_res_we;
    reg [1:0]  lat_res_wplane;
    reg [7:0]  lat_res_waddr;
    reg signed [15:0] lat_res_wdata;
    reg [1:0]  lat_res_rplane;
    reg [7:0]  lat_res_raddr;
    wire [15:0] lat_res_y_q;
    wire [15:0] lat_res_u_q;
    wire [15:0] lat_res_v_q;
    wire signed [15:0] lat_res_q = (lat_res_rplane_q == 2'd0) ? $signed(lat_res_y_q) :
                                   (lat_res_rplane_q == 2'd1) ? $signed(lat_res_u_q) :
                                                               $signed(lat_res_v_q);
    wire lat_recon_we_y = lat_recon_we && (lat_recon_wplane == 2'd0);
    wire lat_recon_we_u = lat_recon_we && (lat_recon_wplane == 2'd1);
    wire lat_recon_we_v = lat_recon_we && (lat_recon_wplane >= 2'd2);
    wire lat_res_we_y = lat_res_we && (lat_res_wplane == 2'd0);
    wire lat_res_we_u = lat_res_we && (lat_res_wplane == 2'd1);
    wire lat_res_we_v = lat_res_we && (lat_res_wplane >= 2'd2);

    mb_sample_ram #(.DEPTH(256), .AW(8), .DATA_W(8)) u_lat_recon_y (
        .clk(clk), .we(lat_recon_we_y), .waddr(lat_recon_waddr), .wdata(lat_recon_wdata),
        .raddr(lat_recon_raddr), .rdata(lat_recon_y_q)
    );
    mb_sample_ram #(.DEPTH(64), .AW(6), .DATA_W(8)) u_lat_recon_u (
        .clk(clk), .we(lat_recon_we_u), .waddr(lat_recon_waddr[5:0]), .wdata(lat_recon_wdata),
        .raddr(lat_recon_raddr[5:0]), .rdata(lat_recon_u_q)
    );
    mb_sample_ram #(.DEPTH(64), .AW(6), .DATA_W(8)) u_lat_recon_v (
        .clk(clk), .we(lat_recon_we_v), .waddr(lat_recon_waddr[5:0]), .wdata(lat_recon_wdata),
        .raddr(lat_recon_raddr[5:0]), .rdata(lat_recon_v_q)
    );
    mb_sample_ram #(.DEPTH(256), .AW(8), .DATA_W(16)) u_lat_res_y (
        .clk(clk), .we(lat_res_we_y), .waddr(lat_res_waddr), .wdata(lat_res_wdata[15:0]),
        .raddr(lat_res_raddr), .rdata(lat_res_y_q)
    );
    mb_sample_ram #(.DEPTH(64), .AW(6), .DATA_W(16)) u_lat_res_u (
        .clk(clk), .we(lat_res_we_u), .waddr(lat_res_waddr[5:0]), .wdata(lat_res_wdata[15:0]),
        .raddr(lat_res_raddr[5:0]), .rdata(lat_res_u_q)
    );
    mb_sample_ram #(.DEPTH(64), .AW(6), .DATA_W(16)) u_lat_res_v (
        .clk(clk), .we(lat_res_we_v), .waddr(lat_res_waddr[5:0]), .wdata(lat_res_wdata[15:0]),
        .raddr(lat_res_raddr[5:0]), .rdata(lat_res_v_q)
    );
    reg [3:0]  res_store_i;
    reg [7:0]  p16_pred_q;
    reg        p16_pred_in_part_q;
    // The reference windows are no longer staged in registers here.  They
    // stream straight into the MC engines' internal window RAMs, because 603
    // bytes of register file with runtime indices is what produced the
    // 89,888-ALUT interpolator the fit rejected.
    reg        intra_active_r;
    reg [7:0]  intra_mb_x_r;
    reg [7:0]  intra_mb_y_r;
    reg        intra_mb_is_ref_r;

    function automatic [7:0] clip_u8(input signed [17:0] value);
        begin
            if (value < 18'sd0)
                clip_u8 = 8'd0;
            else if (value > 18'sd255)
                clip_u8 = 8'd255;
            else
                clip_u8 = value[7:0];
        end
    endfunction

    function automatic signed [15:0] sat16(input signed [28:0] value);
        begin
            if (value > 29'sd32767)
                sat16 = 16'sd32767;
            else if (value < -29'sd32768)
                sat16 = -16'sd32768;
            else
                sat16 = value[15:0];
        end
    endfunction

    function automatic [7:0] luma4x4_index(input [3:0] block, input [3:0] sample);
        begin
            luma4x4_index = {block[3:2], sample[3:2], block[1:0], sample[1:0]};
        end
    endfunction

    function automatic [5:0] chroma4x4_index(input [1:0] block, input [3:0] sample);
        begin
            chroma4x4_index = {block[1], sample[3:2], block[0], sample[1:0]};
        end
    endfunction

    wire [1:0] wb_plane = (wb_idx < 9'd256) ? 2'd0 :
                          (wb_idx < 9'd320) ? 2'd1 : 2'd2;
    wire [8:0] wb_u_idx9 = wb_idx - 9'd256;
    wire [8:0] wb_v_idx9 = wb_idx - 9'd320;
    wire [7:0] wb_sample_idx = (wb_plane == 2'd0) ? wb_idx[7:0] :
                               (wb_plane == 2'd1) ? wb_u_idx9[7:0] :
                                                     wb_v_idx9[7:0];
    // Next-sample decode for 1-cycle writeback pipeline (arm next RAM/MC read
    // while emitting the current registered sample).
    wire [8:0] wb_idx_n = wb_idx + 9'd1;
    wire [1:0] wb_plane_n = (wb_idx_n < 9'd256) ? 2'd0 :
                            (wb_idx_n < 9'd320) ? 2'd1 : 2'd2;
    wire [7:0] wb_sample_idx_n =
        (wb_plane_n == 2'd0) ? wb_idx_n[7:0] :
        (wb_plane_n == 2'd1) ? 8'(wb_idx_n - 9'd256) :
                               8'(wb_idx_n - 9'd320);
    wire [8:0] wb_idx_nn = wb_idx + 9'd2;
    wire [1:0] wb_plane_nn = (wb_idx_nn < 9'd256) ? 2'd0 :
                             (wb_idx_nn < 9'd320) ? 2'd1 : 2'd2;
    wire [7:0] wb_sample_idx_nn =
        (wb_plane_nn == 2'd0) ? wb_idx_nn[7:0] :
        (wb_plane_nn == 2'd1) ? 8'(wb_idx_nn - 9'd256) :
                                8'(wb_idx_nn - 9'd320);
    wire [31:0] syntax_mb_addr32 = {16'd0, syntax_mb_addr_r};
    wire [31:0] syntax_mb_x32 = syntax_mb_addr32 % MB_W;
    wire [31:0] syntax_mb_y32 = syntax_mb_addr32 / MB_W;
    wire [7:0] syntax_mb_x = syntax_mb_x32[7:0];
    wire [7:0] syntax_mb_y = syntax_mb_y32[7:0];
    wire [MB_IDX_W-1:0] syntax_mb_idx = syntax_mb_x[MB_IDX_W-1:0];
    wire [MB_IDX_W-1:0] wb_mb_idx = wb_mb_x[MB_IDX_W-1:0];
    wire syntax_p16_candidate = mb_type_valid && !slice_is_i && !slice_is_idr &&
                                (mb_skip || (mb_type == 5'd0)) &&
                                (mb_skip || (part_mode == 3'd0));
    wire syntax_p16_launch = syntax_p16_candidate && (wb_state == ST_IDLE) && decode_enable;
    wire p16_launch = p16_zero_mv_valid || syntax_p16_launch;
    wire [7:0] p16_launch_mb_x = p16_zero_mv_valid ? p16_mb_x : syntax_mb_x;
    wire [7:0] p16_launch_mb_y = p16_zero_mv_valid ? p16_mb_y : syntax_mb_y;
    wire p16_launch_is_ref = p16_zero_mv_valid ? p16_mb_is_ref : 1'b1;
    wire [15:0] syntax_request_byte_offset = {3'd0, mb_residual_bit_offset[15:3]};

    // ── Per-macroblock QP (7.4.5): mb_qp_delta is only present when the MB
    //    actually carries coefficients, and wraps modulo 52.
    wire mb_is_i16 = slice_is_i && !mb_skip && (mb_type != 5'd0);
    wire mb_has_residual = !mb_skip &&
                           ((cbp_luma != 4'd0) || (cbp_chroma != 2'd0) || mb_is_i16);
    wire signed [7:0] qp_delta_sum = $signed({2'b00, cur_qp_y_r}) +
                                     $signed({{2{mb_qp_delta[5]}}, mb_qp_delta});
    wire signed [7:0] qp_delta_wrap = (qp_delta_sum < 8'sd0)  ? (qp_delta_sum + 8'sd52) :
                                      (qp_delta_sum > 8'sd51) ? (qp_delta_sum - 8'sd52) :
                                                                 qp_delta_sum;
    wire [5:0] qp_launch = p16_zero_mv_valid ? slice_qp_y :
                           mb_has_residual   ? qp_delta_wrap[5:0] : cur_qp_y_r;

    wire [1:0] eff_ref_idx_l0 = (num_ref_idx_l0_active <= 8'd1) ? 2'd0 : ref_idx_l0;

    wire syntax_has_left = (syntax_mb_x != 8'd0) && mv_left_valid && (mv_left_ref == eff_ref_idx_l0);
    wire syntax_has_top = mv_top_valid[syntax_mb_idx] && (mv_top_ref[syntax_mb_idx] == eff_ref_idx_l0);
    wire [MB_IDX_W-1:0] syntax_top_right_idx = (syntax_mb_x32 + 32'd1 < MB_W) ?
                                      (syntax_mb_idx + MB_IDX_W'(1)) : syntax_mb_idx;
    wire syntax_has_top_right = (syntax_mb_x32 + 32'd1 < MB_W) &&
                                mv_top_valid[syntax_top_right_idx] &&
                                (mv_top_ref[syntax_top_right_idx] == eff_ref_idx_l0);
`ifdef H264_DECODE_CORE_FAULT_DROP_MV_NEIGHBOR
    wire mv_avail_a = 1'b0;
    wire mv_avail_b = 1'b0;
    wire mv_avail_c = 1'b0;
`else
    wire mv_avail_a = syntax_has_left;
    wire mv_avail_b = syntax_has_top;
    wire mv_avail_c = syntax_has_top_right;
`endif
    wire signed [15:0] syntax_mv_x;
    wire signed [15:0] syntax_mv_y;
    wire signed [15:0] syntax_mv_pred_x;
    wire signed [15:0] syntax_mv_pred_y;
    wire syntax_mv_skip_zero;
    h264_mv_pred_part u_product_p16_mv_pred (
        .part_mode(3'd0),
        .part_idx(2'd0),
        .avail_a(mv_avail_a),
        .avail_b(mv_avail_b),
        .avail_c(mv_avail_c),
        .avail_d(1'b0),
        .mv_a_x(mv_left_x),
        .mv_a_y(mv_left_y),
        .mv_b_x(mv_top_x[syntax_mb_idx]),
        .mv_b_y(mv_top_y[syntax_mb_idx]),
        .mv_c_x(mv_top_x[syntax_top_right_idx]),
        .mv_c_y(mv_top_y[syntax_top_right_idx]),
        .mv_d_x(16'sd0),
        .mv_d_y(16'sd0),
        .mvd_x(mvd_x_qpel),
        .mvd_y(mvd_y_qpel),
        .p_skip(mb_skip),
        .pred_x(syntax_mv_pred_x),
        .pred_y(syntax_mv_pred_y),
        .mv_x(syntax_mv_x),
        .mv_y(syntax_mv_y),
        .skip_zero(syntax_mv_skip_zero)
    );

    wire [15:0] launch_residual_window_bit_base = {rbsp_window_base[12:0], 3'd0};
    wire [15:0] launch_residual_rel_bit_offset = mb_residual_bit_offset - launch_residual_window_bit_base;
    wire        cavlc_busy;
    wire        cavlc_done;
    wire        cavlc_ok;
    wire [9:0]  cavlc_bit_offset_end;
    wire [4:0]  cavlc_total_coeff;
    wire [1:0]  cavlc_trailing_ones;
    wire [3:0]  cavlc_total_zeros;
    wire signed [15:0] cavlc_coeff [0:15];
    wire signed [15:0] cavlc_level_dbg [0:15];
    wire [3:0]  cavlc_run_dbg [0:15];
    wire signed [15:0] cavlc_dequant_coeff [0:15];
    genvar cavlc_coeff_i;
    generate
        for (cavlc_coeff_i = 0; cavlc_coeff_i < 16; cavlc_coeff_i = cavlc_coeff_i + 1) begin : g_cavlc_dequant_coeff
`ifdef H264_DECODE_CORE_FAULT_SWAP_SCHEDULED_COEFF
            if (cavlc_coeff_i == 0)
                assign cavlc_dequant_coeff[cavlc_coeff_i] = cavlc_coeff[1];
            else if (cavlc_coeff_i == 1)
                assign cavlc_dequant_coeff[cavlc_coeff_i] = cavlc_coeff[0];
            else
                assign cavlc_dequant_coeff[cavlc_coeff_i] = cavlc_coeff[cavlc_coeff_i];
`elsif H264_DECODE_CORE_FAULT_SWAP_CHROMA_SCHEDULED_COEFF
            if (cavlc_coeff_i == 0)
                assign cavlc_dequant_coeff[cavlc_coeff_i] = (p16_res_block_idx >= RES_STEP_CHROMA_DC0) ? cavlc_coeff[1] : cavlc_coeff[0];
            else if (cavlc_coeff_i == 1)
                assign cavlc_dequant_coeff[cavlc_coeff_i] = (p16_res_block_idx >= RES_STEP_CHROMA_DC0) ? cavlc_coeff[0] : cavlc_coeff[1];
            else
                assign cavlc_dequant_coeff[cavlc_coeff_i] = cavlc_coeff[cavlc_coeff_i];
`else
            assign cavlc_dequant_coeff[cavlc_coeff_i] = cavlc_coeff[cavlc_coeff_i];
`endif
        end
    endgenerate
    // ── Residual step decode (H.264 residual() traversal order) ────────
    wire res_is_luma_dc   = (p16_res_block_idx == RES_STEP_LUMA_DC);
    wire res_is_luma_ac   = (p16_res_block_idx >= RES_STEP_LUMA_AC0) &&
                            (p16_res_block_idx < RES_STEP_CHROMA_DC0);
    wire res_is_chroma_dc = (p16_res_block_idx >= RES_STEP_CHROMA_DC0) &&
                            (p16_res_block_idx < RES_STEP_CHROMA_AC0);
    wire res_is_chroma_ac = (p16_res_block_idx >= RES_STEP_CHROMA_AC0);

    // Luma 4x4 block index (Table 6-10): the bitstream walks the four 8x8
    // groups in raster order and each group's four 4x4 blocks in raster order,
    // which is x4 = {blk[2], blk[0]}, y4 = {blk[3], blk[1]}.
    wire [3:0] res_luma_blk    = p16_res_block_idx[3:0] - 4'd1;
    wire [1:0] res_luma_x4     = {res_luma_blk[2], res_luma_blk[0]};
    wire [1:0] res_luma_y4     = {res_luma_blk[3], res_luma_blk[1]};
    // luma4x4_index() takes {row, column}.
    wire [3:0] res_luma_raster = {res_luma_y4, res_luma_x4};
    wire [1:0] res_cbp_group   = res_luma_blk[3:2];

    // Chroma: two components of four 4x4 blocks each, raster within the 8x8.
    wire [4:0] res_cac_i       = p16_res_block_idx - RES_STEP_CHROMA_AC0;
    wire       res_chroma_is_v = res_is_chroma_dc ?
                                 (p16_res_block_idx == (RES_STEP_CHROMA_DC0 + 5'd1)) :
                                 res_cac_i[2];
    wire [1:0] res_chroma_blk  = res_cac_i[1:0];

    // ── coded_block_pattern gating (7.4.5) ─────────────────────────────
    // A block whose CBP bit is 0 has no bits in the stream at all; decoding it
    // anyway consumes the next block's bits. Intra_16x16 DC and chroma DC are
    // still present even when the matching AC bits are not, and those DC
    // values must still be transformed into residual samples.
    wire res_luma_dc_coded   = res_i16x16_r;
    wire res_luma_ac_coded   = p16_cbp_luma_r[res_cbp_group];
    wire res_chroma_dc_coded = (p16_cbp_chroma_r != 2'd0);
    wire res_chroma_ac_coded = (p16_cbp_chroma_r == 2'd2);
    wire res_block_coded = res_is_luma_dc   ? res_luma_dc_coded   :
                           res_is_luma_ac   ? res_luma_ac_coded   :
                           res_is_chroma_dc ? res_chroma_dc_coded :
                                              res_chroma_ac_coded;
    // Uncoded block that still receives a DC term: transform with zero AC.
    wire res_dc_present = res_is_luma_ac   ? res_i16x16_r :
                          res_is_chroma_ac ? res_chroma_dc_coded : 1'b0;

    // ── nC neighbour context ───────────────────────────────────────────
    wire [1:0] res_nc_blk_x = res_is_luma_dc ? 2'd0 :
                              res_is_luma_ac ? res_luma_x4 :
                                               {1'b0, res_chroma_blk[0]};
    wire [1:0] res_nc_blk_y = res_is_luma_dc ? 2'd0 :
                              res_is_luma_ac ? res_luma_y4 :
                                               {1'b0, res_chroma_blk[1]};
    wire       res_left_internal = (res_nc_blk_x != 2'd0);
    wire       res_up_internal   = (res_nc_blk_y != 2'd0);
    wire [2:0] res_c_sel      = {res_chroma_is_v, res_chroma_blk[1], res_chroma_blk[0]};
    wire [2:0] res_c_left_sel = {res_chroma_is_v, res_chroma_blk[1], 1'b0};
    wire [2:0] res_c_up_sel   = {res_chroma_is_v, 1'b0, res_chroma_blk[0]};
    wire [1:0] res_c_left_edge = {res_chroma_is_v, res_chroma_blk[1]};
    wire [MB_IDX_W+1:0] res_c_top_idx =
        {wb_mb_x[MB_IDX_W-1:0], res_chroma_is_v, res_chroma_blk[0]};

    wire [4:0] res_left_tc = res_is_chroma_ac ?
        (res_left_internal ? res_tc_cur_c[res_c_left_sel] : res_tc_left_c[res_c_left_edge]) :
        (res_left_internal ? res_tc_cur[{res_nc_blk_y, res_nc_blk_x - 2'd1}] : res_tc_left[res_nc_blk_y]);
    wire       res_left_tc_valid = res_left_internal ? 1'b1 : res_tc_left_valid;
    wire [4:0] res_up_tc = res_is_chroma_ac ?
        (res_up_internal ? res_tc_cur_c[res_c_up_sel] : res_tc_top_c[res_c_top_idx]) :
        (res_up_internal ? res_tc_cur[{res_nc_blk_y - 2'd1, res_nc_blk_x}] :
                           res_tc_top[{wb_mb_x[MB_IDX_W-1:0], res_nc_blk_x}]);
    wire       res_up_tc_valid = res_up_internal ? 1'b1 : res_tc_top_valid[wb_mb_x[MB_IDX_W-1:0]];
    wire [15:0] res_mb_index = ({8'd0, wb_mb_y} * {8'd0, mb_width}) + {8'd0, wb_mb_x};

    wire [4:0] res_nC;
    wire [2:0] res_coeff_token_table;
    h264_cavlc_nc_predictor u_product_res_nc (
        .mb_x(wb_mb_x),
        .mb_y(wb_mb_y),
        .mb_index(res_mb_index),
        .mb_width(mb_width),
        .first_mb_in_slice(first_mb_in_slice),
        .block_x(res_nc_blk_x),
        .block_y(res_nc_blk_y),
        .left_tc_valid(res_left_tc_valid),
        .left_tc(res_left_tc),
        .up_tc_valid(res_up_tc_valid),
        .up_tc(res_up_tc),
        .nA_available(),
        .nB_available(),
        .nC(res_nC),
        .coeff_token_table(res_coeff_token_table)
    );

    // Chroma DC uses nC = -1 (table 4); everything else is neighbour-derived.
    wire [2:0] res_token_table = res_is_chroma_dc ? 3'd4 : res_coeff_token_table;
    wire       res_skip_dc = (res_is_luma_ac && res_i16x16_r) || res_is_chroma_ac;
    wire [4:0] res_max_coeff = res_is_chroma_dc ? 5'd4 :
                               res_skip_dc      ? 5'd15 : 5'd16;

    h264_cavlc_residual_block u_product_p16_residual0 (
        .clk(clk),
        .reset(reset || slice_start),
        .start(cavlc_start_r),
        .coeff_token_table(res_token_table),
        .max_coeff(res_max_coeff),
        .bit_offset_start(p16_res_bit_offset_r),
        .bit_len(10'd512),
        .rbsp(rbsp_byte),
        .busy(cavlc_busy),
        .done(cavlc_done),
        .ok(cavlc_ok),
        .bit_offset_end(cavlc_bit_offset_end),
        .total_coeff(cavlc_total_coeff),
        .trailing_ones(cavlc_trailing_ones),
        .total_zeros(cavlc_total_zeros),
        .coeff(cavlc_coeff),
        .level_dbg(cavlc_level_dbg),
        .run_dbg(cavlc_run_dbg)
    );

    // ── Inverse transform chain ────────────────────────────────────────
    // Uncoded blocks present zero AC to the scaler so that a DC-only block
    // still produces its flat residual.
    wire signed [15:0] res_ac_coeff [0:15];
    genvar res_ci;
    generate
        for (res_ci = 0; res_ci < 16; res_ci = res_ci + 1) begin : g_res_ac_coeff
            assign res_ac_coeff[res_ci] = res_ac_from_cavlc ? cavlc_dequant_coeff[res_ci] : 16'sd0;
        end
    endgenerate

    wire [5:0] res_qp_c;
    h264_chroma_qp u_product_res_chroma_qp (
        .qp_y(mb_qp_y_r),
        .chroma_qp_index_offset(pps_chroma_qp_index_offset),
        .qp_c(res_qp_c)
    );
    wire [5:0] res_qp = (res_is_chroma_dc || res_is_chroma_ac) ? res_qp_c : mb_qp_y_r;

    wire signed [28:0] res_luma_dc_new [0:15];
    h264_luma_dc_hadamard_inv u_product_res_luma_dc (
        .coeff(cavlc_dequant_coeff),
        .qp(mb_qp_y_r),
        .dc(res_luma_dc_new)
    );

    wire signed [15:0] res_chroma_dc_coeff [0:3];
    assign res_chroma_dc_coeff[0] = cavlc_dequant_coeff[0];
    assign res_chroma_dc_coeff[1] = cavlc_dequant_coeff[1];
    assign res_chroma_dc_coeff[2] = cavlc_dequant_coeff[2];
    assign res_chroma_dc_coeff[3] = cavlc_dequant_coeff[3];
    wire signed [28:0] res_chroma_dc_new [0:3];
    h264_chroma_dc_hadamard_inv u_product_res_chroma_dc (
        .coeff(res_chroma_dc_coeff),
        .qp(res_qp_c),
        .dc(res_chroma_dc_new)
    );

    wire signed [28:0] res_dc_value = res_is_chroma_ac ?
        (res_chroma_is_v ? res_cdc_v[res_chroma_blk] : res_cdc_u[res_chroma_blk]) :
        res_luma_dc[res_luma_raster];
    wire res_dc_override = res_is_chroma_ac ? res_chroma_dc_coded : res_i16x16_r;

    wire signed [28:0] p16_res_dequant [0:15];
    wire signed [28:0] p16_res_idct [0:15];
    h264_dequant4x4_flex u_product_p16_res_dequant (
        .coeff(res_ac_coeff),
        .qp(res_qp),
        .max_coeff(res_skip_dc ? 5'd15 : 5'd16),
        .skip_dc(res_skip_dc),
        .dc_override(res_dc_override),
        .dc_value(res_dc_value),
        .dequant(p16_res_dequant)
    );
    h264_idct4x4 u_product_p16_res_idct (
        .dequant(p16_res_dequant),
        .residual(p16_res_idct)
    );
`ifdef H264_DECODE_CORE_FAULT_DROP_LAST_LUMA_RESIDUAL
    wire p16_drop_this_luma_residual = (p16_res_block_idx == (RES_STEP_CHROMA_DC0 - 5'd1));
`else
    wire p16_drop_this_luma_residual = 1'b0;
`endif
`ifdef H264_DECODE_CORE_FAULT_DROP_LAST_CHROMA_RESIDUAL
    wire p16_drop_this_chroma_residual = (p16_res_block_idx == RES_STEP_LAST);
`else
    wire p16_drop_this_chroma_residual = 1'b0;
`endif
`ifdef H264_DECODE_CORE_FAULT_SWAP_CHROMA_RESIDUAL
    wire p16_swap_chroma_residual = 1'b1;
`else
    wire p16_swap_chroma_residual = 1'b0;
`endif
    // ════════════════════════════════════════════════════════════════════
    // PRODUCT P16×16 MOTION COMPENSATION
    // ════════════════════════════════════════════════════════════════════
    // h264_dpb_one_ref owns the POST-deblock reference store: it consumes the
    // filtered sample stream, generates the native-I420 write addresses, and
    // fetches one 21×21 luma + two 9×9 chroma reference windows per inter MB.
    // h264_inter_mc_part then computes the full 16×16 luma / 8×8 chroma
    // prediction block from those windows.
    //
    // Bank management stays with the outer level (dpb_write_base/dpb_ref_base
    // inputs), so the embedded reference store's own bank pointers are used
    // only as rebase anchors on the external memory ports.
    wire        dpb_ref_ready;
    wire [31:0] dpb_ref_current_base;
    wire [31:0] dpb_ref_reference_base;
    wire        dpb_ref_mem_we;
    wire [31:0] dpb_ref_mem_waddr;
    wire [7:0]  dpb_ref_mem_wdata;
    wire        dpb_ref_mem_rd;
    wire [31:0] dpb_ref_mem_raddr;
    wire        dpb_ref_fetch_busy;
    wire        dpb_ref_fetch_done;
    wire        dpb_ref_fetch_error_no_ref;
    wire [1:0]  dpb_ref_luma_frac_x;
    wire [1:0]  dpb_ref_luma_frac_y;
    wire [2:0]  dpb_ref_chroma_frac_x;
    wire [2:0]  dpb_ref_chroma_frac_y;
    wire signed [15:0] dpb_ref_luma_origin_x;
    wire signed [15:0] dpb_ref_luma_origin_y;
    wire signed [15:0] dpb_ref_chroma_origin_x;
    wire signed [15:0] dpb_ref_chroma_origin_y;
    wire        dpb_ref_luma_window_valid;
    wire [8:0]  dpb_ref_luma_window_idx;
    wire [7:0]  dpb_ref_luma_window_sample;
    wire        dpb_ref_chroma_u_window_valid;
    wire        dpb_ref_chroma_v_window_valid;
    wire [6:0]  dpb_ref_chroma_window_idx;
    wire [7:0]  dpb_ref_chroma_window_sample;

    // Registered M10K read data (address driven one cycle earlier in PRIME/WRITE).
    wire [7:0] wb_data = lat_recon_q;
    wire signed [15:0] p16_residual_sample = lat_res_q;
    // Skip / fully-uncoded MB: do not depend on residual RAM contents.
    wire p16_residual_all_zero =
        (p16_cbp_luma_r == 4'd0) && (p16_cbp_chroma_r == 2'd0);

    wire [7:0] p16_pred_y_rd_data;
    wire [7:0] p16_pred_u_rd_data;
    wire [7:0] p16_pred_v_rd_data;
    wire       p16_pred_y_in_part;
    wire       p16_pred_c_in_part;
    wire [7:0] p16_pred_y_head [0:15];
    wire p16_mc_busy;
    wire p16_mc_done;
    // Fractional parts. A quarter-luma-sample vector is already an
    // eighth-chroma-sample vector in 4:2:0, so luma takes mv[1:0] against a
    // mv>>>2 integer origin and chroma takes mv[2:0] against mv>>>3. Both
    // slices are the correct modulo for negative vectors because the shifts
    // are arithmetic.
    // During ST_P16_WRITE (non-last) fetch the *next* sample so pred_q and
    // residual M10K data line up for a single-cycle emit stream.
    wire [8:0] p16_mc_rd_flat =
        ((wb_state == ST_P16_WRITE) && !wb_last_sample) ? wb_idx_n : wb_idx;
    wire [1:0] p16_mc_rd_plane =
        (p16_mc_rd_flat < 9'd256) ? 2'd0 :
        (p16_mc_rd_flat < 9'd320) ? 2'd1 : 2'd2;
    wire [7:0] p16_mc_rd_idx =
        (p16_mc_rd_plane == 2'd0) ? p16_mc_rd_flat[7:0] :
        (p16_mc_rd_plane == 2'd1) ? 8'(p16_mc_rd_flat - 9'd256) :
                                    8'(p16_mc_rd_flat - 9'd320);

    h264_mc_block u_product_p16_mc (
        .clk(clk),
        .reset(reset),
        .start(p16_mc_start_r),
        .busy(p16_mc_busy),
        .done(p16_mc_done),
        .luma_win_wr(dpb_ref_luma_window_valid),
        .luma_win_addr(dpb_ref_luma_window_idx),
        .luma_win_data(dpb_ref_luma_window_sample),
        .chroma_u_win_wr(dpb_ref_chroma_u_window_valid),
        .chroma_v_win_wr(dpb_ref_chroma_v_window_valid),
        .chroma_win_addr(dpb_ref_chroma_window_idx),
        .chroma_win_data(dpb_ref_chroma_window_sample),
        .luma_frac_x(p16_mv_x_qpel_r[1:0]),
        .luma_frac_y(p16_mv_y_qpel_r[1:0]),
        .chroma_frac_x(p16_mv_x_qpel_r[2:0]),
        .chroma_frac_y(p16_mv_y_qpel_r[2:0]),
        .part_w(5'd16),
        .part_h(5'd16),
        .pred_y_rd_idx(p16_mc_rd_idx),
        .pred_y_rd_data(p16_pred_y_rd_data),
        .pred_y_rd_in_part(p16_pred_y_in_part),
        .pred_c_rd_idx(p16_mc_rd_idx[5:0]),
        .pred_u_rd_data(p16_pred_u_rd_data),
        .pred_v_rd_data(p16_pred_v_rd_data),
        .pred_c_rd_in_part(p16_pred_c_in_part),
        .pred_y_head(p16_pred_y_head)
    );
    // The engines' prediction read ports are asynchronous, so the writeback
    // walk indexes them directly and needs no extra pipeline stage.
    wire p16_pred_in_part = (p16_mc_rd_plane == 2'd0) ? p16_pred_y_in_part
                                                      : p16_pred_c_in_part;
    wire [7:0] p16_pred_sample_async = !p16_pred_in_part ? 8'd0 :
                                 (p16_mc_rd_plane == 2'd0) ? p16_pred_y_rd_data :
                                 (p16_mc_rd_plane == 2'd1) ? p16_pred_u_rd_data :
                                                             p16_pred_v_rd_data;
    // Align MC (async) with residual M10K (1-cycle read): use registered pred.
    wire [7:0] p16_pred_sample = p16_pred_q;
`ifdef H264_DECODE_CORE_FAULT_DROP_PRED
    wire signed [17:0] p16_pred_term = 18'sd0;
`else
    wire signed [17:0] p16_pred_term = {10'd0, p16_pred_sample};
`endif
`ifdef H264_DECODE_CORE_FAULT_DROP_RESIDUAL
    wire signed [17:0] p16_residual_term = 18'sd0;
`else
    wire signed [17:0] p16_residual_term = p16_residual_all_zero ? 18'sd0 :
        {{2{p16_residual_sample[15]}}, p16_residual_sample};
`endif
    wire signed [17:0] p16_recon_sum = p16_pred_term + p16_residual_term;

    // Align plane select with registered RAM read data (1-cycle raddr latency).
    always @(posedge clk) begin
        lat_recon_rplane_q <= lat_recon_rplane;
        lat_res_rplane_q   <= lat_res_rplane;
    end
    wire [31:0] wb_mb_x32 = {24'd0, wb_mb_x};
    wire [31:0] wb_mb_y32 = {24'd0, wb_mb_y};
    wire [31:0] mb_width32 = {24'd0, mb_width};
    wire [31:0] mb_height32 = {24'd0, mb_height};
    wire [31:0] wb_mb_addr32 = wb_mb_y32 * MB_W + wb_mb_x32;
    wire [15:0] wb_mb_addr16 = wb_mb_addr32[15:0];
    wire        wb_last_sample = (wb_idx == 9'd383);
    wire        wb_last_mb = (wb_mb_x32 == (MB_W - 1)) &&
                             (wb_mb_y32 == (MB_H - 1));
    // Gate on IDLE so multi-cycle M10K recon latch cannot race a new MB.
    wire        product_intra_mb_start = mb_type_valid && slice_is_i && !mb_skip &&
                                         decode_enable && (wb_state == ST_IDLE);
    wire [7:0]  product_intra_mb_type = {3'd0, mb_type};
    wire [1:0]  product_intra_i16_mode = intra16x16_mode;
    wire signed [28:0] product_intra_i16_dc [0:15];
    wire [7:0]  product_intra_recon_y [0:255];
    wire [7:0]  product_intra_recon_u [0:63];
    wire [7:0]  product_intra_recon_v [0:63];
    wire signed [15:0] product_intra_chroma_residual_u [0:63];
    wire signed [15:0] product_intra_chroma_residual_v [0:63];
    wire        product_intra_recon_valid;
    wire [4:0]  product_intra_blocks_done;
    wire [7:0]  product_intra_ctx_recon_pixels [0:15];
    wire [7:0]  product_intra_ctx_above_unused [0:7];
    wire [7:0]  product_intra_ctx_left_unused [0:3];
    wire [7:0]  product_intra_ctx_top_left_unused;
    wire        product_intra_ctx_has_above_unused;
    wire        product_intra_ctx_has_left_unused;
    wire        product_intra_ctx_has_above_right_unused;
    wire [7:0]  product_intra_chroma_u_above [0:7];
    wire [7:0]  product_intra_chroma_v_above [0:7];
    wire [7:0]  product_intra_chroma_u_left [0:7];
    wire [7:0]  product_intra_chroma_v_left [0:7];
    wire [7:0]  product_intra_chroma_u_topleft;
    wire [7:0]  product_intra_chroma_v_topleft;
    wire        product_intra_has_chroma_above;
    wire        product_intra_has_chroma_left;
    wire        product_intra_mb_avail_left;
    wire        product_intra_mb_avail_top;
    wire        product_intra_mb_avail_topright;
    wire        product_intra_mb_avail_topleft;
    wire [7:0]  product_intra_nb_top [0:15];
    wire [7:0]  product_intra_nb_left [0:15];
    wire [7:0]  product_intra_nb_topleft;
    wire [7:0]  product_intra_nb_topright [0:3];
    genvar intra_gi;
    generate
        for (intra_gi = 0; intra_gi < 16; intra_gi = intra_gi + 1) begin : g_product_intra_i16_dc
            assign product_intra_i16_dc[intra_gi] = 29'sd0;
            assign product_intra_ctx_recon_pixels[intra_gi] = 8'd128;
        end
        for (intra_gi = 0; intra_gi < 64; intra_gi = intra_gi + 1) begin : g_product_intra_chroma_residual
            // The core's residual walker does not yet run for intra
            // macroblocks, so intra chroma is prediction-only for now.
            assign product_intra_chroma_residual_u[intra_gi] = 16'sd0;
            assign product_intra_chroma_residual_v[intra_gi] = 16'sd0;
        end
    endgenerate

    wire product_recon_mb_valid = recon_mb_valid || product_intra_recon_valid;
    wire [7:0] product_recon_mb_x = product_intra_recon_valid ? intra_mb_x_r : recon_mb_x;
    wire [7:0] product_recon_mb_y = product_intra_recon_valid ? intra_mb_y_r : recon_mb_y;
    wire product_recon_mb_is_ref = product_intra_recon_valid ? intra_mb_is_ref_r : recon_mb_is_ref;

    h264_intra_nb_ctx #(
        .MB_WIDTH_MAX(MB_W),
        .MB_WIDTH_DEFAULT(MB_W)
    ) u_product_intra_nb_ctx (
        .clk(clk),
        .reset(reset),
        .mb_x(intra_mb_x_r),
        .mb_y(intra_mb_y_r),
        .mb_width(mb_width),
        .first_mb_in_slice(first_mb_in_slice),
        .mb_start(product_intra_mb_start),
        .block_idx(luma4x4_idx),
        .block_valid(1'b0),
        .constrained_intra_pred(constrained_intra_pred_flag),
        // Every retired macroblock, intra or inter -- the intra path's own
        // mb_commit only ever carries intra reconstruction, which is not
        // enough to know that a neighbour was inter-coded.
        .mb_coded_valid(product_recon_mb_valid),
        .mb_coded_is_intra(product_intra_recon_valid),
        .mb_coded_x(product_recon_mb_x),
        .recon_pixels(product_intra_ctx_recon_pixels),
        .mb_commit(product_intra_recon_valid),
        .recon_y_mb(product_intra_recon_y),
        .recon_u_mb(product_intra_recon_u),
        .recon_v_mb(product_intra_recon_v),
        .above(product_intra_ctx_above_unused),
        .left(product_intra_ctx_left_unused),
        .top_left(product_intra_ctx_top_left_unused),
        .has_above(product_intra_ctx_has_above_unused),
        .has_left(product_intra_ctx_has_left_unused),
        .has_above_right(product_intra_ctx_has_above_right_unused),
        .mb_avail_left(product_intra_mb_avail_left),
        .mb_avail_top(product_intra_mb_avail_top),
        .mb_avail_topright(product_intra_mb_avail_topright),
        .mb_avail_topleft(product_intra_mb_avail_topleft),
        .nb_top(product_intra_nb_top),
        .nb_left(product_intra_nb_left),
        .nb_topleft(product_intra_nb_topleft),
        .nb_topright(product_intra_nb_topright),
        .chroma_u_above(product_intra_chroma_u_above),
        .chroma_v_above(product_intra_chroma_v_above),
        .chroma_u_left(product_intra_chroma_u_left),
        .chroma_v_left(product_intra_chroma_v_left),
        .chroma_u_top_left(product_intra_chroma_u_topleft),
        .chroma_v_top_left(product_intra_chroma_v_topleft),
        .has_chroma_above(product_intra_has_chroma_above),
        .has_chroma_left(product_intra_has_chroma_left)
    );

    h264_decode_top u_product_intra_mb (
        .clk(clk),
        .reset(reset || slice_start),
        .mb_start(product_intra_mb_start),
        .mb_type(product_intra_mb_type),
        .mb_qp_y(luma4x4_qp),
        .mb_x(intra_mb_x_r),
        .mb_y(intra_mb_y_r),
        .i16_pred_mode(product_intra_i16_mode),
        .block_valid(luma4x4_valid),
        .block_index(luma4x4_idx),
        .block_coeff(luma4x4_coeff_zigzag),
        .i16_dc_valid(product_intra_mb_start),
        .i16_dc(product_intra_i16_dc),
        .chroma_pred_mode(chroma_pred_mode),
        .nb_chroma_u_above(product_intra_chroma_u_above),
        .nb_chroma_v_above(product_intra_chroma_v_above),
        .nb_chroma_u_left(product_intra_chroma_u_left),
        .nb_chroma_v_left(product_intra_chroma_v_left),
        .nb_chroma_u_topleft(product_intra_chroma_u_topleft),
        .nb_chroma_v_topleft(product_intra_chroma_v_topleft),
        .mb_avail_chroma_above(product_intra_has_chroma_above),
        .mb_avail_chroma_left(product_intra_has_chroma_left),
        .chroma_residual_u(product_intra_chroma_residual_u),
        .chroma_residual_v(product_intra_chroma_residual_v),
        .recon_u(product_intra_recon_u),
        .recon_v(product_intra_recon_v),
        .i4_modes(intra4x4_modes),
        .mb_avail_left(product_intra_mb_avail_left),
        .mb_avail_top(product_intra_mb_avail_top),
        .mb_avail_topright(product_intra_mb_avail_topright),
        .mb_avail_topleft(product_intra_mb_avail_topleft),
        .nb_top(product_intra_nb_top),
        .nb_left(product_intra_nb_left),
        .nb_topleft(product_intra_nb_topleft),
        .nb_topright(product_intra_nb_topright),
        .mb_recon_valid(product_intra_recon_valid),
        .recon_y(product_intra_recon_y),
        .blocks_done(product_intra_blocks_done)
    );

`ifdef H264_DECODE_CORE_FAULT_DROP_WB
    wire product_wb_en = 1'b0;
`else
    // ST_WRITE_PRIME only arms the M10K read address; emit on ST_WRITE.
    wire product_wb_en = (wb_state == ST_WRITE);
`endif
    wire p16_sample_wb_en = (wb_state == ST_P16_WRITE);
    wire deblock_filtered_sample_valid = product_wb_en | p16_sample_wb_en;
    wire deblock_filtered_mb_valid = (wb_state == ST_COMMIT);
    wire deblock_filtered_frame_done = deblock_filtered_mb_valid && wb_last_mb;
    wire deblock_frame_boundary = (wb_state == ST_FRAME_BOUNDARY);

    // ── In-loop deblocking ────────────────────────────────────────────────
    // The reconstruction stream feeds the macroblock deblocker one cycle
    // delayed so the engine has already latched this macroblock's metadata on
    // dbf_start_r. Its output is the POST-deblock stream: the DPB reference
    // store and the present writeback both take it, while intra prediction and
    // neighbour context keep reading the PRE-deblock reconstruction registers.
    wire       dbf_out_valid;
    wire [1:0] dbf_out_plane;
    wire [15:0] dbf_out_x;
    wire [15:0] dbf_out_y;
    wire [7:0] dbf_out_data;
    wire       dbf_busy;
    wire       dbf_mb_done;
    wire       dbf_smp_done = dbf_smp_valid_d && (dbf_smp_idx_d == 9'd383);
    wire [15:0] dbf_nz_luma_w;
    genvar dbf_g;
    generate
        for (dbf_g = 0; dbf_g < 16; dbf_g = dbf_g + 1) begin : g_dbf_nz
            assign dbf_nz_luma_w[dbf_g] = (res_tc_cur[dbf_g] != 5'd0);
        end
    endgenerate

    h264_deblock_mb #(
        .FRAME_W(FRAME_W),
        .FRAME_H(FRAME_H)
    ) u_product_deblock (
        .clk(clk),
        .reset(reset),
        .slice_start(slice_start),
        .disable_deblocking(disable_deblocking_filter_idc == 2'd1),
        .slice_alpha_c0_offset(slice_alpha_c0_offset),
        .slice_beta_offset(slice_beta_offset),
        .mb_start(dbf_start_r),
        .mb_x(wb_mb_x),
        .mb_y(wb_mb_y),
        .mb_is_intra(wb_mb_is_intra),
        .mb_qp_y(mb_qp_y_r),
        .mb_qp_c(res_qp_c),
        .mb_nz_luma(dbf_nz_luma_w),
        .mb_mv_x(wb_mb_is_intra ? 16'sd0 : p16_mv_x_qpel_r),
        .mb_mv_y(wb_mb_is_intra ? 16'sd0 : p16_mv_y_qpel_r),
        .mb_ref_idx(wb_mb_is_intra ? 2'd0 : p16_ref_idx_l0_r),
        .smp_valid(dbf_smp_valid_d),
        .smp_idx(dbf_smp_idx_d),
        .smp_data(dbf_smp_data_d),
        .smp_done(dbf_smp_done),
        .out_valid(dbf_out_valid),
        .out_plane(dbf_out_plane),
        .out_x(dbf_out_x),
        .out_y(dbf_out_y),
        .out_data(dbf_out_data),
        .busy(dbf_busy),
        .mb_done(dbf_mb_done)
    );

    // Absolute picture coordinates back to the macroblock-relative form the
    // reference store's address generator expects. The deblocked window spans
    // into the left / upper neighbour, so this must be a true division, not a
    // reuse of wb_mb_x/wb_mb_y.
    wire [7:0] dbf_wb_mb_x = (dbf_out_plane == 2'd0) ? dbf_out_x[11:4] : dbf_out_x[10:3];
    wire [7:0] dbf_wb_mb_y = (dbf_out_plane == 2'd0) ? dbf_out_y[11:4] : dbf_out_y[10:3];
    wire [7:0] dbf_wb_sample_idx = (dbf_out_plane == 2'd0) ?
                                   {dbf_out_y[3:0], dbf_out_x[3:0]} :
                                   {2'd0, dbf_out_y[2:0], dbf_out_x[2:0]};

    wire deblock_wb_valid;
    wire [CORE_MB_AW-1:0] deblock_wb_mb_addr;
    wire deblock_wb_is_ref;
    wire deblock_dpb_invalidate_refs;
    wire deblock_ref_ready_pulse;
    wire [1:0] deblock_ref_ready_slot;
    wire deblock_commit_order_error;

    h264_deblock_writeback_ctrl #(
        .MB_COUNT(MB_COUNT),
        .FRAME_SLOT_W(2),
        .SAMPLES_PER_MB(384)
    ) u_core_deblock_wb (
        .clk(clk),
        .reset(reset),
        .idr_frame_start(slice_start && slice_is_idr),
        .filtered_sample_valid(deblock_filtered_sample_valid),
        .filtered_mb_valid(deblock_filtered_mb_valid),
        .filtered_mb_addr(wb_mb_addr32[CORE_MB_AW-1:0]),
        .filtered_mb_is_ref(wb_mb_is_ref),
        .filtered_frame_done(deblock_filtered_frame_done),
        .frame_slot_i(2'd0),
        .frame_boundary(deblock_frame_boundary),
        .wb_valid(deblock_wb_valid),
        .wb_mb_addr(deblock_wb_mb_addr),
        .wb_is_ref(deblock_wb_is_ref),
        .dpb_invalidate_refs(deblock_dpb_invalidate_refs),
        .ref_ready_pulse(deblock_ref_ready_pulse),
        .ref_ready_slot(deblock_ref_ready_slot),
        .commit_order_error(deblock_commit_order_error)
    );

    // The external DPB read contract returns data one edge after the address
    // is registered; h264_dpb_one_ref aligns returned data with its own
    // pending_*_d1 metadata two edges after issue. One skid stage adapts the
    // former to the latter without reordering reads.
    reg        dpb_rd_valid_q;
    reg [7:0]  dpb_rd_data_q;
    always @(posedge clk) begin
        if (reset) begin
            dpb_rd_valid_q <= 1'b0;
            dpb_rd_data_q  <= 8'd0;
        end else begin
            dpb_rd_valid_q <= dpb_rd_valid;
            dpb_rd_data_q  <= dpb_rd_data;
        end
    end

    // POST-deblock reference store + inter reference window fetch.
    // filtered_sample_* is the same committed POST-deblock sample stream that
    // feeds the deblock writeback controller, so MC never taps PRE-deblock
    // reconstruction. ref_ready is promoted from deblock_ref_ready_pulse (the
    // post-frame-boundary promotion), or seeded once when the outer level hands
    // this core an externally-owned reference bank via dpb_ref_base.
    wire [7:0] dpb_ref_filtered_sample = p16_sample_wb_en ? clip_u8(p16_recon_sum) : wb_data;
    wire product_dpb_ref_swap = deblock_ref_ready_pulse | p16_ref_seed_r;
    assign dpb_ref_swap = product_dpb_ref_swap;
    h264_dpb_one_ref #(
        .FRAME_W(FRAME_W),
        .FRAME_H(FRAME_H)
    ) u_product_dpb_ref (
        .clk(clk),
        .reset(reset),
        .idr_start(slice_start && slice_is_idr),
        .frame_done(product_dpb_ref_swap),
        .ref_ready(dpb_ref_ready),
        .current_base(dpb_ref_current_base),
        .reference_base(dpb_ref_reference_base),
        .filtered_sample_valid(dbf_out_valid),
        .filtered_mb_x(dbf_wb_mb_x),
        .filtered_mb_y(dbf_wb_mb_y),
        .filtered_plane(dbf_out_plane),
        .filtered_sample_idx(dbf_wb_sample_idx),
        .filtered_sample(dbf_out_data),
        .mem_we(dpb_ref_mem_we),
        .mem_waddr(dpb_ref_mem_waddr),
        .mem_wdata(dpb_ref_mem_wdata),
        .fetch_start(p16_fetch_start_r),
        .fetch_mb_x(wb_mb_x),
        .fetch_mb_y(wb_mb_y),
        .fetch_part_mode(3'd0),
        .fetch_part_idx(2'd0),
        .fetch_part_w(5'd16),
        .fetch_part_h(5'd16),
        .fetch_mv_x_qpel(p16_mv_x_qpel_r),
        .fetch_mv_y_qpel(p16_mv_y_qpel_r),
        .fetch_busy(dpb_ref_fetch_busy),
        .fetch_done(dpb_ref_fetch_done),
        .fetch_error_no_ref(dpb_ref_fetch_error_no_ref),
        .luma_frac_x(dpb_ref_luma_frac_x),
        .luma_frac_y(dpb_ref_luma_frac_y),
        .chroma_frac_x(dpb_ref_chroma_frac_x),
        .chroma_frac_y(dpb_ref_chroma_frac_y),
        .luma_origin_x(dpb_ref_luma_origin_x),
        .luma_origin_y(dpb_ref_luma_origin_y),
        .chroma_origin_x(dpb_ref_chroma_origin_x),
        .chroma_origin_y(dpb_ref_chroma_origin_y),
        .mem_rd(dpb_ref_mem_rd),
        .mem_raddr(dpb_ref_mem_raddr),
        .mem_rdata(dpb_rd_data_q),
        .mem_rvalid(dpb_rd_valid_q),
        .mem_stall(dpb_rd_stall),
        .luma_window_valid(dpb_ref_luma_window_valid),
        .luma_window_idx(dpb_ref_luma_window_idx),
        .luma_window_sample(dpb_ref_luma_window_sample),
        .chroma_u_window_valid(dpb_ref_chroma_u_window_valid),
        .chroma_v_window_valid(dpb_ref_chroma_v_window_valid),
        .chroma_window_idx(dpb_ref_chroma_window_idx),
        .chroma_window_sample(dpb_ref_chroma_window_sample)
    );

    // Rebase the reference store's internal bank pointers onto the bank bases
    // the outer level owns. Both are plane-linear i420 offsets, so subtracting
    // the internal anchor and adding the external base is exact.
`ifdef H264_DECODE_CORE_FAULT_SWAP_CHROMA_READ
    wire [31:0] p16_win_plane_off = dpb_ref_mem_raddr - dpb_ref_reference_base;
    wire [31:0] p16_luma_plane_sz = 32'(FRAME_W) * 32'(FRAME_H);
    wire [31:0] p16_chroma_plane_sz = 32'(FRAME_W / 2) * 32'(FRAME_H / 2);
    wire [31:0] p16_rd_offset =
        (p16_win_plane_off < p16_luma_plane_sz) ? p16_win_plane_off :
        (p16_win_plane_off < (p16_luma_plane_sz + p16_chroma_plane_sz)) ?
            (p16_win_plane_off + p16_chroma_plane_sz) :
            (p16_win_plane_off - p16_chroma_plane_sz);
`else
    wire [31:0] p16_rd_offset = dpb_ref_mem_raddr - dpb_ref_reference_base;
`endif
    wire [31:0] p16_win_rd_addr = p16_ref_base_r + p16_rd_offset;
    wire [31:0] product_wb_addr = wb_base + (dpb_ref_mem_waddr - dpb_ref_current_base);

    integer wb_i;

    // Shared residual traversal helpers. Both are called from the residual
    // states below; keeping them here avoids three copies of the same
    // step/latch code drifting apart.
    task automatic res_step_advance;
        begin
            if (p16_res_block_idx == RES_STEP_LAST) begin
                wb_state <= ST_P16_RES_EDGE;
            end else begin
                p16_res_block_idx <= p16_res_block_idx + 5'd1;
                wb_state <= ST_P16_RES_START;
            end
        end
    endtask

    // One residual sample address for sequential M10K store (res_store_i = 0..15).
    wire [7:0] res_store_luma_addr  = luma4x4_index(res_luma_raster, res_store_i);
    wire [5:0] res_store_chroma_addr = chroma4x4_index(res_chroma_blk, res_store_i);
    wire signed [15:0] res_store_sample = sat16(p16_res_idct[res_store_i]);
    wire res_store_to_v = (res_chroma_is_v ^ p16_swap_chroma_residual);

    always @(posedge clk) begin
        frame_done_r <= deblock_ref_ready_pulse;
        p16_fetch_start_r <= 1'b0;
        p16_mc_start_r <= 1'b0;
        p16_ref_seed_r <= 1'b0;
        rbsp_request_valid_r <= 1'b0;
        cavlc_start_r <= 1'b0;
        if (reset || slice_start) begin
            wb_state <= ST_IDLE;
            wb_idx <= 9'd0;
            wb_mb_x <= 8'd0;
            wb_mb_y <= 8'd0;
            wb_mb_is_ref <= 1'b0;
            wb_mb_is_intra <= 1'b0;
            dbf_start_r <= 1'b0;
            dbf_smp_valid_d <= 1'b0;
            dbf_smp_idx_d <= 9'd0;
            dbf_smp_data_d <= 8'd0;
            wb_base <= 32'd0;
            p16_ref_base_r <= 32'd0;
            p16_mv_x_qpel_r <= 16'sd0;
            p16_mv_y_qpel_r <= 16'sd0;
            p16_ref_idx_l0_r <= 2'd0;
            p16_fetch_start_r <= 1'b0;
        p16_mc_start_r <= 1'b0;
            p16_ref_seed_r <= 1'b0;
            p16_res_bit_offset_r <= 10'd0;
            p16_res_block_idx <= 5'd0;
            cavlc_start_r <= 1'b0;
            wb_commit_p16 <= 1'b0;
            p16_cbp_luma_r <= 4'd0;
            p16_cbp_chroma_r <= 2'd0;
            res_tc_left_valid <= 1'b0;
            res_i16x16_r <= 1'b0;
            res_ac_from_cavlc <= 1'b0;
            mb_qp_y_r <= slice_qp_y;
            cur_qp_y_r <= slice_qp_y;
            for (res_tc_i = 0; res_tc_i < 16; res_tc_i = res_tc_i + 1) begin
                res_tc_cur[res_tc_i] <= 5'd0;
                res_luma_dc[res_tc_i] <= 29'sd0;
            end
            for (res_tc_i = 0; res_tc_i < 8; res_tc_i = res_tc_i + 1)
                res_tc_cur_c[res_tc_i] <= 5'd0;
            for (res_tc_i = 0; res_tc_i < 4; res_tc_i = res_tc_i + 1) begin
                res_tc_left[res_tc_i] <= 5'd0;
                res_tc_left_c[res_tc_i] <= 5'd0;
                res_cdc_u[res_tc_i] <= 29'sd0;
                res_cdc_v[res_tc_i] <= 29'sd0;
            end
            for (res_tc_i = 0; res_tc_i < MB_W * 4; res_tc_i = res_tc_i + 1) begin
                res_tc_top[res_tc_i] <= 5'd0;
                res_tc_top_c[res_tc_i] <= 5'd0;
            end
            for (res_tc_i = 0; res_tc_i < MB_W; res_tc_i = res_tc_i + 1)
                res_tc_top_valid[res_tc_i] <= 1'b0;
            syntax_mb_addr_r <= reset ? 16'd0 : first_mb_in_slice;
            rbsp_request_offset_r <= 16'd0;
            rbsp_request_valid_r <= 1'b0;
            mv_left_x <= 16'sd0;
            mv_left_y <= 16'sd0;
            mv_left_ref <= 2'd0;
            mv_left_valid <= 1'b0;
            intra_active_r <= 1'b0;
            intra_mb_x_r <= 8'd0;
            intra_mb_y_r <= 8'd0;
            intra_mb_is_ref_r <= 1'b0;
            intra_qp_y_r <= 6'd26;
            mb_count_r <= 16'd0;
            frame_done_r <= 1'b0;
            // Do not reset M10K array contents — breaks inference into block RAM.
            lat_recon_we <= 1'b0;
            lat_res_we <= 1'b0;
            res_store_i <= 4'd0;
            p16_pred_q <= 8'd0;
            p16_pred_in_part_q <= 1'b0;
            for (wb_i = 0; wb_i < MB_W; wb_i = wb_i + 1) begin
                mv_top_x[wb_i] <= 16'sd0;
                mv_top_y[wb_i] <= 16'sd0;
                mv_top_ref[wb_i] <= 2'd0;
                mv_top_valid[wb_i] <= 1'b0;
            end
        end else begin
            dbf_start_r <= 1'b0;
            lat_recon_we <= 1'b0;
            lat_res_we <= 1'b0;
            dbf_smp_valid_d <= deblock_filtered_sample_valid;
            dbf_smp_idx_d <= wb_idx;
            dbf_smp_data_d <= dpb_ref_filtered_sample;

            if (syntax_p16_candidate) begin
                rbsp_request_valid_r <= 1'b1;
`ifdef H264_DECODE_CORE_FAULT_BAD_RBSP_REQ
                rbsp_request_offset_r <= syntax_request_byte_offset + 16'd1;
`else
                rbsp_request_offset_r <= syntax_request_byte_offset;
`endif
            end
            if (mb_type_valid)
                syntax_mb_addr_r <= syntax_mb_addr_r + 16'd1;
            if (product_intra_mb_start) begin
                intra_active_r <= 1'b1;
                intra_mb_x_r <= syntax_mb_x;
                intra_mb_y_r <= syntax_mb_y;
                intra_mb_is_ref_r <= 1'b1;
                // Latch QPy at the syntax edge: the reconstruction pulse that
                // launches the writeback arrives many cycles later, when the
                // slice-level mb_qp_delta inputs no longer describe this
                // macroblock. The deblocker needs the right QP for alpha/beta.
                intra_qp_y_r <= qp_launch;
                cur_qp_y_r <= qp_launch;
            end
            if (product_intra_recon_valid)
                intra_active_r <= 1'b0;

            case (wb_state)
            ST_IDLE: begin
                if (p16_launch) begin
                    wb_mb_x <= p16_launch_mb_x;
                    wb_mb_y <= p16_launch_mb_y;
                    wb_mb_is_ref <= p16_launch_is_ref;
                    wb_mb_is_intra <= 1'b0;
                    wb_base <= dpb_write_base;
                    p16_ref_base_r <= dpb_ref_base;
`ifdef H264_DECODE_CORE_FAULT_PERTURB_MV
                    p16_mv_x_qpel_r <= (p16_zero_mv_valid ? mv_x_qpel : syntax_mv_x) + 16'sd2;
`else
                    p16_mv_x_qpel_r <= p16_zero_mv_valid ? mv_x_qpel : syntax_mv_x;
`endif
                    p16_mv_y_qpel_r <= p16_zero_mv_valid ? mv_y_qpel : syntax_mv_y;
                    p16_ref_idx_l0_r <= eff_ref_idx_l0;
                    p16_res_bit_offset_r <= launch_residual_rel_bit_offset[9:0];
                    p16_res_block_idx <= 5'd0;
                    p16_cbp_luma_r <= mb_skip ? 4'd0 : cbp_luma;
                    p16_cbp_chroma_r <= mb_skip ? 2'd0 : cbp_chroma;
                    // The walker only launches inter macroblocks today, so
                    // there is no Intra_16x16 luma DC block in the chain.
                    res_i16x16_r <= 1'b0;
                    res_ac_from_cavlc <= 1'b0;
                    mb_qp_y_r <= qp_launch;
                    cur_qp_y_r <= qp_launch;
                    for (res_tc_i = 0; res_tc_i < 16; res_tc_i = res_tc_i + 1) begin
                        res_tc_cur[res_tc_i] <= 5'd0;
                        res_luma_dc[res_tc_i] <= 29'sd0;
                    end
                    for (res_tc_i = 0; res_tc_i < 8; res_tc_i = res_tc_i + 1)
                        res_tc_cur_c[res_tc_i] <= 5'd0;
                    for (res_tc_i = 0; res_tc_i < 4; res_tc_i = res_tc_i + 1) begin
                        res_cdc_u[res_tc_i] <= 29'sd0;
                        res_cdc_v[res_tc_i] <= 29'sd0;
                    end
                    wb_idx <= 9'd0;
                    wb_commit_p16 <= 1'b0;
                    res_store_i <= 4'd0;
                    // External TB residual plane: stream into M10K. Product path
                    // relies on residual_all_zero or per-block store/zero.
                    if (p16_zero_mv_valid)
                        wb_state <= ST_P16_LATCH_RES;
                    else
                        wb_state <= ST_P16_RES_START;
                end else if (product_recon_mb_valid && !dbf_busy) begin
                    // Same handover rule as the inter path: the loop filter
                    // may still be emitting the previous macroblock's window.
                    wb_mb_x <= product_recon_mb_x;
                    wb_mb_y <= product_recon_mb_y;
                    wb_mb_is_ref <= product_recon_mb_is_ref;
                    wb_mb_is_intra <= product_intra_recon_valid;
                    if (product_intra_recon_valid)
                        mb_qp_y_r <= intra_qp_y_r;
                    dbf_start_r <= 1'b1;
                    wb_base <= dpb_write_base;
                    wb_idx <= 9'd0;
                    wb_commit_p16 <= 1'b0;
                    // Sequential M10K fill — not a 384-wide parallel latch.
                    wb_state <= ST_LATCH_RECON;
                end
            end
            ST_LATCH_RECON: begin
                // One sample/cycle into lat_recon_* from the recon port arrays.
                lat_recon_we <= 1'b1;
                lat_recon_wplane <= wb_plane;
                lat_recon_waddr <= wb_sample_idx;
                if (wb_plane == 2'd0)
                    lat_recon_wdata <= product_intra_recon_valid ?
                        product_intra_recon_y[wb_sample_idx] : recon_y[wb_sample_idx];
                else if (wb_plane == 2'd1)
                    lat_recon_wdata <= product_intra_recon_valid ?
                        product_intra_recon_u[wb_sample_idx[5:0]] : recon_u[wb_sample_idx[5:0]];
                else
                    lat_recon_wdata <= product_intra_recon_valid ?
                        product_intra_recon_v[wb_sample_idx[5:0]] : recon_v[wb_sample_idx[5:0]];
                if (wb_last_sample) begin
                    wb_idx <= 9'd0;
                    wb_state <= ST_WRITE_PRIME;
                end else begin
                    wb_idx <= wb_idx + 9'd1;
                end
            end
            ST_P16_LATCH_RES: begin
                lat_res_we <= 1'b1;
                lat_res_wplane <= wb_plane;
                lat_res_waddr <= wb_sample_idx;
                if (wb_plane == 2'd0)
                    lat_res_wdata <= p16_residual_y[wb_sample_idx];
                else if (wb_plane == 2'd1)
                    lat_res_wdata <= p16_residual_u[wb_sample_idx[5:0]];
                else
                    lat_res_wdata <= p16_residual_v[wb_sample_idx[5:0]];
                if (wb_last_sample) begin
                    wb_idx <= 9'd0;
                    wb_state <= ST_P16_REF_SEED;
                end else begin
                    wb_idx <= wb_idx + 9'd1;
                end
            end
            ST_P16_RES_START: begin
                if (res_block_coded) begin
                    cavlc_start_r <= 1'b1;
                    res_ac_from_cavlc <= 1'b1;
                    wb_state <= ST_P16_RES_WAIT;
                end else if (res_dc_present) begin
                    // No AC bits in the stream, but the plane DC still reaches
                    // this block: transform it with a zero AC field.
                    res_ac_from_cavlc <= 1'b0;
                    res_store_i <= 4'd0;
                    wb_state <= ST_P16_RES_IDCT;
                end else begin
                    // Uncoded and DC-free.
                    if (res_is_luma_ac)
                        res_tc_cur[res_luma_raster] <= 5'd0;
                    if (res_is_chroma_ac)
                        res_tc_cur_c[res_c_sel] <= 5'd0;
                    if (res_is_luma_dc)
                        for (res_tc_i = 0; res_tc_i < 16; res_tc_i = res_tc_i + 1)
                            res_luma_dc[res_tc_i] <= 29'sd0;
                    if (res_is_chroma_dc)
                        for (res_tc_i = 0; res_tc_i < 4; res_tc_i = res_tc_i + 1) begin
                            if (res_chroma_is_v)
                                res_cdc_v[res_tc_i] <= 29'sd0;
                            else
                                res_cdc_u[res_tc_i] <= 29'sd0;
                        end
                    // Partial-cbp: zero this 4x4 in M10K. Full-zero MB skips
                    // RAM writes and forces residual_term=0 on the add.
                    if ((res_is_luma_ac || res_is_chroma_ac) && !p16_residual_all_zero) begin
                        res_store_i <= 4'd0;
                        wb_state <= ST_P16_RES_ZERO;
                    end else begin
                        res_step_advance();
                    end
                end
            end
            ST_P16_RES_IDCT: begin
                // DC-only block: residual is produced from DC + zero AC.
                if (res_is_luma_ac)
                    res_tc_cur[res_luma_raster] <= 5'd0;
                if (res_is_chroma_ac)
                    res_tc_cur_c[res_c_sel] <= 5'd0;
`ifndef H264_DECODE_CORE_FAULT_DROP_SCHEDULED_RESIDUAL
                res_store_i <= 4'd0;
                wb_state <= ST_P16_RES_STORE;
`else
                res_step_advance();
`endif
            end
            ST_P16_RES_STORE: begin
                // One IDCT sample per cycle into residual M10K.
                // Finish by clearing res_store_i so the next block's first
                // STORE cycle sees 0 (NBA from WAIT alone is one cycle late,
                // which previously left res_store_i==15 and stored only one
                // sample per subsequent 4x4 before advancing).
                if (res_is_luma_ac && !p16_drop_this_luma_residual) begin
                    lat_res_we <= 1'b1;
                    lat_res_wplane <= 2'd0;
                    lat_res_waddr <= res_store_luma_addr;
                    lat_res_wdata <= res_store_sample;
                end else if (res_is_chroma_ac && !p16_drop_this_chroma_residual) begin
                    lat_res_we <= 1'b1;
                    lat_res_wplane <= res_store_to_v ? 2'd2 : 2'd1;
                    lat_res_waddr <= {2'b0, res_store_chroma_addr};
                    lat_res_wdata <= res_store_sample;
                end
                if (res_store_i == 4'd15) begin
                    res_store_i <= 4'd0;
                    res_step_advance();
                end else begin
                    res_store_i <= res_store_i + 4'd1;
                end
            end
            ST_P16_RES_ZERO: begin
                if (res_is_luma_ac) begin
                    lat_res_we <= 1'b1;
                    lat_res_wplane <= 2'd0;
                    lat_res_waddr <= res_store_luma_addr;
                    lat_res_wdata <= 16'sd0;
                end else if (res_is_chroma_ac) begin
                    lat_res_we <= 1'b1;
                    lat_res_wplane <= res_store_to_v ? 2'd2 : 2'd1;
                    lat_res_waddr <= {2'b0, res_store_chroma_addr};
                    lat_res_wdata <= 16'sd0;
                end
                if (res_store_i == 4'd15) begin
                    res_store_i <= 4'd0;
                    res_step_advance();
                end else begin
                    res_store_i <= res_store_i + 4'd1;
                end
            end
            ST_P16_RES_WAIT: begin
                if (cavlc_done) begin
                    if (cavlc_ok) begin
                        if (res_is_luma_dc) begin
                            for (res_tc_i = 0; res_tc_i < 16; res_tc_i = res_tc_i + 1)
                                res_luma_dc[res_tc_i] <= res_luma_dc_new[res_tc_i];
                            p16_res_bit_offset_r <= cavlc_bit_offset_end;
                            res_step_advance();
                        end else if (res_is_chroma_dc) begin
                            for (res_tc_i = 0; res_tc_i < 4; res_tc_i = res_tc_i + 1) begin
                                if (res_chroma_is_v)
                                    res_cdc_v[res_tc_i] <= res_chroma_dc_new[res_tc_i];
                                else
                                    res_cdc_u[res_tc_i] <= res_chroma_dc_new[res_tc_i];
                            end
                            p16_res_bit_offset_r <= cavlc_bit_offset_end;
                            res_step_advance();
                        end else begin
                            // AC block: nC now, then sequential residual store.
                            if (res_is_luma_ac)
                                res_tc_cur[res_luma_raster] <= cavlc_total_coeff;
                            if (res_is_chroma_ac)
                                res_tc_cur_c[res_c_sel] <= cavlc_total_coeff;
                            p16_res_bit_offset_r <= cavlc_bit_offset_end;
`ifndef H264_DECODE_CORE_FAULT_DROP_SCHEDULED_RESIDUAL
                            res_store_i <= 4'd0;
                            wb_state <= ST_P16_RES_STORE;
`else
                            res_step_advance();
`endif
                        end
                    end else begin
                        if (res_is_luma_ac)
                            res_tc_cur[res_luma_raster] <= 5'd0;
                        if (res_is_chroma_ac)
                            res_tc_cur_c[res_c_sel] <= 5'd0;
                        p16_res_bit_offset_r <= cavlc_bit_offset_end;
                        res_step_advance();
                    end
                end
            end
            ST_P16_RES_EDGE: begin
                // Roll this macroblock's edge total_coeff into the left
                // registers and the per-column top line buffers.
                res_tc_left_valid <= 1'b1;
                for (res_tc_i = 0; res_tc_i < 4; res_tc_i = res_tc_i + 1) begin
                    res_tc_left[res_tc_i] <= res_tc_cur[{res_tc_i[1:0], 2'd3}];
                    res_tc_top[{wb_mb_x[MB_IDX_W-1:0], res_tc_i[1:0]}] <=
                        res_tc_cur[{2'd3, res_tc_i[1:0]}];
                    res_tc_left_c[res_tc_i[1:0]] <= res_tc_cur_c[{res_tc_i[1:0], 1'b1}];
                    res_tc_top_c[{wb_mb_x[MB_IDX_W-1:0], res_tc_i[1:0]}] <=
                        res_tc_cur_c[{res_tc_i[1], 1'b1, res_tc_i[0]}];
                end
                res_tc_top_valid[wb_mb_x[MB_IDX_W-1:0]] <= 1'b1;
                wb_state <= ST_P16_REF_SEED;
            end
            ST_P16_REF_SEED: begin
                // Publish the externally-owned reference bank into the local
                // reference store once, then start the block reference fetch.
                if (dpb_ref_ready) begin
                    p16_fetch_start_r <= 1'b1;
                    wb_state <= ST_P16_WIN_START;
                end else begin
                    p16_ref_seed_r <= 1'b1;
                end
            end
            ST_P16_WIN_START: begin
                wb_state <= ST_P16_WIN_FETCH;
            end
            ST_P16_WIN_FETCH: begin
                // The window samples go straight into the engines' window
                // RAMs off the same valid/index/sample strobes; nothing is
                // staged here any more.
                if (dpb_ref_fetch_done) begin
                    // The last window sample lands on this same edge, so the
                    // engine's first window RAM read happens after it.
                    p16_mc_start_r <= 1'b1;
                    wb_state <= ST_P16_MC;
                end
            end
            ST_P16_MC: begin
                // The loop filter owns a private copy of the macroblock, so it
                // is still emitting the previous one while this one is
                // predicted.  Hand over only once it has retired that copy.
                if (p16_mc_done && !dbf_busy) begin
                    // res_tc_cur is final by now, so the deblocker latches the
                    // real per-4x4 coded-coefficient flags for bS derivation.
                    dbf_start_r <= 1'b1;
                    wb_idx <= 9'd0;
                    wb_state <= ST_P16_WRITE_PRIME;
                end
            end
            ST_WRITE_PRIME: begin
                // Present raddr=0 for the HOLD cycle read.
                lat_recon_rplane <= 2'd0;
                lat_recon_raddr <= 8'd0;
                wb_idx <= 9'd0;
                wb_state <= ST_WRITE_HOLD;
            end
            ST_WRITE_HOLD: begin
                // During HOLD raddr=0 → lat_recon_q gets sample0 at end.
                // Prefetch sample1 address so WRITE0's read yields sample1.
                lat_recon_rplane <= 2'd0;
                lat_recon_raddr <= 8'd1;
                wb_state <= ST_WRITE;
            end
            ST_P16_WRITE_PRIME: begin
                lat_res_rplane <= 2'd0;
                lat_res_raddr <= 8'd0;
                wb_idx <= 9'd0;
                // MC async for sample0 (p16_mc_rd sees wb_idx=0 this cycle).
                p16_pred_q <= p16_pred_sample_async;
                p16_pred_in_part_q <= p16_pred_in_part;
                wb_state <= ST_P16_WRITE_HOLD;
            end
            ST_P16_WRITE_HOLD: begin
                // res_q ← residual0 (raddr was 0 during this cycle).
                // Prefetch residual1; keep pred_q as sample0 from PRIME.
                lat_res_rplane <= 2'd0;
                lat_res_raddr <= 8'd1;
                wb_state <= ST_P16_WRITE;
            end
            ST_P16_WRITE: begin
                // q holds residual[wb_idx]; pred_q holds pred[wb_idx].
                if (wb_last_sample) begin
                    wb_commit_p16 <= 1'b1;
                    wb_state <= ST_DEBLOCK;
                end else begin
                    // Advance emit index; raddr was already next during this
                    // cycle (set last beat / HOLD). Point raddr at idx+2.
                    wb_idx <= wb_idx_n;
                    // Prefetch address for sample after next (wb_idx+2).
                    lat_res_rplane <= wb_plane_nn;
                    lat_res_raddr <= wb_sample_idx_nn;
                    // Capture pred for the new wb_idx (wb_idx_n): MC ports
                    // already see wb_idx_n while in ST_P16_WRITE && !last.
                    p16_pred_q <= p16_pred_sample_async;
                    p16_pred_in_part_q <= p16_pred_in_part;
                end
            end
            ST_WRITE: begin
                // lat_recon_q holds sample[wb_idx] (prefetched previous cycle).
                if (wb_last_sample) begin
                    wb_commit_p16 <= 1'b0;
                    wb_state <= ST_DEBLOCK;
                end else begin
                    wb_idx <= wb_idx_n;
                    lat_recon_rplane <= wb_plane_nn;
                    lat_recon_raddr <= wb_sample_idx_nn;
                end
            end
            // The macroblock is only committed once its filtered window,
            // including the strips that belong to the left and upper
            // neighbours, has been written out.
            // ── Pipeline overlap ────────────────────────────────────────
            // The filter emits a 576-beat window: the macroblock plus the
            // strips of the left and upper neighbours its edge filtering
            // rewrote.  At one sample per cycle into a byte-wide writeback
            // port that is 576 of the 712 cycles a macroblock gets, and
            // waiting for it here serialised the whole pipeline behind it.
            //
            // It works from its own copy, so the core does not have to stay
            // parked: it commits and moves on to fetch, predict and
            // reconstruct the next macroblock while the previous one drains.
            // The handover point in ST_P16_MC / ST_IDLE is where the next
            // macroblock waits, which keeps macroblocks in order through the
            // filter and preserves its left/upper neighbour state.
            //
            // The last macroblock of a frame is the exception: ST_COMMIT is
            // what raises filtered_frame_done and swaps the reference bank, so
            // committing early there would swap the bank out from under the
            // samples still being emitted.
            ST_DEBLOCK: begin
                if (dbf_mb_done || !(wb_mb_is_ref && wb_last_mb))
                    wb_state <= ST_COMMIT;
            end
            ST_COMMIT: begin
                if (wb_mb_is_ref) begin
                    mb_count_r <= mb_count_r + 16'd1;
                    if (wb_commit_p16) begin
                        mv_top_x[wb_mb_idx] <= p16_mv_x_qpel_r;
                        mv_top_y[wb_mb_idx] <= p16_mv_y_qpel_r;
                        mv_top_ref[wb_mb_idx] <= p16_ref_idx_l0_r;
                        mv_top_valid[wb_mb_idx] <= 1'b1;
                        mv_left_x <= p16_mv_x_qpel_r;
                        mv_left_y <= p16_mv_y_qpel_r;
                        mv_left_ref <= p16_ref_idx_l0_r;
                        mv_left_valid <= 1'b1;
                    end
                end
                wb_state <= (wb_mb_is_ref && wb_last_mb) ? ST_FRAME_BOUNDARY : ST_IDLE;
            end
            ST_FRAME_BOUNDARY: begin
                wb_state <= ST_IDLE;
            end
            default: begin
                wb_state <= ST_IDLE;
            end
            endcase
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // THROUGHPUT TELEMETRY
    // ════════════════════════════════════════════════════════════════════
    // At 20 MHz with 1170 macroblocks at ~24 fps the whole pipeline gets 712
    // cycles per macroblock.  Charge every cycle of a macroblock to exactly
    // one stage so the per-stage totals sum to the macroblock total and no
    // stage can quietly eat the budget.
    localparam [2:0] PERF_ST_PARSE   = 3'd0;  // mb_type, residual walk, IDCT
    localparam [2:0] PERF_ST_FETCH   = 3'd1;  // reference window fetch
    localparam [2:0] PERF_ST_MC      = 3'd2;  // interpolation
    localparam [2:0] PERF_ST_WRITE   = 3'd3;  // reconstruction writeback
    localparam [2:0] PERF_ST_DEBLOCK = 3'd4;  // in-loop filter
    localparam [2:0] PERF_ST_OTHER   = 3'd5;  // commit, frame boundary

    reg [2:0] perf_stage;
    always @* begin
        case (wb_state)
        ST_P16_RES_START, ST_P16_RES_WAIT,
        ST_P16_RES_IDCT, ST_P16_RES_STORE, ST_P16_RES_ZERO,
        ST_P16_RES_EDGE:                  perf_stage = PERF_ST_PARSE;
        ST_P16_REF_SEED, ST_P16_WIN_START,
        ST_P16_WIN_FETCH:                 perf_stage = PERF_ST_FETCH;
        ST_P16_MC:                        perf_stage = PERF_ST_MC;
        ST_LATCH_RECON, ST_P16_LATCH_RES,
        ST_WRITE_PRIME, ST_WRITE_HOLD,
        ST_P16_WRITE_PRIME, ST_P16_WRITE_HOLD,
        ST_P16_WRITE, ST_WRITE:           perf_stage = PERF_ST_WRITE;
        ST_DEBLOCK:                       perf_stage = PERF_ST_DEBLOCK;
        default:                          perf_stage = PERF_ST_OTHER;
        endcase
    end

    // Idle time between macroblocks is not a pipeline cost and must not be
    // charged to whichever stage happened to run last.
    wire perf_active = (wb_state != ST_IDLE);
    wire perf_mb_done = (wb_state == ST_COMMIT);

    h264_perf_counters #(
        .NSTAGES(6)
    ) u_product_perf (
        .clk(clk),
        .reset(reset),
        .active(perf_active),
        .stage_id(perf_stage),
        .mb_done(perf_mb_done),
        .frame_done(frame_done_r),
        .mbox_word(perf_mbox_word)
    );

    assign dpb_wr_en = dpb_ref_mem_we;
    assign dpb_wr_addr = product_wb_addr;
    assign dpb_wr_data = dpb_ref_mem_wdata;

    // Present writeback: POST-deblock stream, plane + frame-relative (x,y).
    assign px_wr_en    = dbf_out_valid;
    assign px_wr_plane = dbf_out_plane;
    assign px_wr_x     = dbf_out_x;
    assign px_wr_y     = dbf_out_y;
    assign px_wr_data  = dbf_out_data;
    assign dpb_rd_en = dpb_ref_mem_rd;
    assign dpb_rd_addr = p16_win_rd_addr;
    assign rbsp_request_offset = rbsp_request_offset_r;
    assign rbsp_request_valid = rbsp_request_valid_r;
    assign frame_done = frame_done_r;
    assign frame_mb_count = mb_count_r;
    assign busy = (wb_state != ST_IDLE) || intra_active_r;
    assign decode_state = wb_state;
    assign current_mb_addr = (wb_state == ST_IDLE) ? syntax_mb_addr_r : wb_mb_addr16;
    // ── Desync detectors ────────────────────────────────────────────────
    // Baseline mb_type ranges, 7.4.5 Tables 7-11 and 7-13: an I slice has
    // 0..25 (I_NxN, the 24 I_16x16 flavours, I_PCM); a P slice has 0..4 for
    // the inter types and 5..30 for the intra types offset by 5.  Anything
    // above those is not a code point, so the bit position that produced it
    // was already wrong.
    assign err_bad_mb_type = mb_type_valid && !mb_skip &&
                             (slice_is_i ? (mb_type > 5'd25) : (mb_type > 5'd30));

    // The macroblock address is derived by counting, so it running past the
    // picture means macroblocks were invented that the slice never coded.
    assign err_mb_overrun = mb_type_valid && (syntax_mb_addr32 >= (MB_W * MB_H));

    // The residual decoder reports every lookup that fell off the end of its
    // table without matching a code.
    assign err_cavlc_miss = cavlc_done && !cavlc_ok;

    assign error = (mb_width != 8'd0 && mb_width32 != MB_W) ||
                   (mb_height != 8'd0 && mb_height32 != MB_H);

    (* keep = 1 *) wire _keep_decode_core_inputs =
        slice_is_idr | slice_is_i | |slice_qp_y | |first_mb_in_slice |
        |pps_chroma_qp_index_offset | |rbsp_byte[0] | |rbsp_window_base |
        mb_type_valid | |mb_type | mb_skip | |intra4x4_modes[0] |
        |intra16x16_mode | |chroma_pred_mode | |cbp_luma | |cbp_chroma |
        |mb_qp_delta | |mb_residual_bit_offset | luma4x4_valid | |luma4x4_idx |
        |luma4x4_qp | |luma4x4_total_coeff | |luma4x4_trailing_ones |
        |luma4x4_coeff_zigzag[0] | product_intra_mb_avail_left |
        product_intra_mb_avail_top | product_intra_mb_avail_topright |
        product_intra_mb_avail_topleft | |product_intra_nb_top[0] |
        |product_intra_nb_left[0] | |product_intra_nb_topleft |
        |product_intra_nb_topright[0] | product_intra_recon_valid |
        |product_intra_blocks_done | |mv_x_qpel | |mv_y_qpel |
        |part_mode | |part_idx | cavlc_busy | |cavlc_bit_offset_end |
        |cavlc_total_coeff | |cavlc_trailing_ones | |cavlc_total_zeros |
        |cavlc_level_dbg[0] | |cavlc_run_dbg[0] |
        deblock_wb_valid | |deblock_wb_mb_addr | deblock_wb_is_ref |
        deblock_dpb_invalidate_refs | deblock_ref_ready_pulse |
        |deblock_ref_ready_slot | deblock_commit_order_error;

endmodule
