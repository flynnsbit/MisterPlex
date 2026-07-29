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
    input  wire        mb_intra,             // 1 = I MB or intra-in-P (mb_type is I-coded)
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
    // num_ref_idx_l0_active = minus1+1; when 1, ref_idx is inferred 0.
    input  wire [7:0]  num_ref_idx_l0_active,
    // Full partition syntax arrays from the slice walker.
    input  wire [7:0]  part_sub_mb_types,
    input  wire [7:0]  part_ref_idx_l0,
    input  wire [15:0] part_mvd_valid,
    input  wire signed [15:0] part_mvd_x [0:15],
    input  wire signed [15:0] part_mvd_y [0:15],

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

    // ── Status/debug ──
    // intra_blocks_done is the reconstruction front-end's accepted-block count
    // for the current macroblock.  The macroblock feeder needs it as a real
    // handshake: the 4x4 reconstruction pipeline only accepts one block every
    // other cycle (and not at all until Intra_16x16 prediction is ready), so a
    // free-running burst of 16 block pulses silently loses half of them.
    output wire [4:0]  intra_blocks_done,
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
    localparam [7:0] ST_P16_WIN_START = 8'd9;
    localparam [7:0] ST_PART_PRED     = 8'd12;
    localparam [7:0] ST_PART_ADV      = 8'd13;
    localparam [4:0] P16_LUMA_RES_BLOCKS = 5'd16;
    localparam [4:0] P16_CHROMA_RES_BLOCKS = 5'd8;
    localparam [4:0] P16_RES_BLOCKS = P16_LUMA_RES_BLOCKS + P16_CHROMA_RES_BLOCKS;
    localparam int MB_IDX_W = (MB_W <= 1) ? 1 : $clog2(MB_W);
    localparam int CORE_MB_AW = (MB_COUNT <= 1) ? 1 : $clog2(MB_COUNT);

    reg [7:0]  wb_state;
    reg [8:0]  wb_idx;
    reg [7:0]  wb_mb_x;
    reg [7:0]  wb_mb_y;
    reg        wb_mb_is_ref;
    reg [31:0] wb_base;
    reg [31:0] p16_ref_base_r;
    reg signed [15:0] p16_mv_x_qpel_r;
    reg signed [15:0] p16_mv_y_qpel_r;
    reg [1:0]  p16_ref_idx_l0_r;
    reg        p16_fetch_start_r;
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
    reg [7:0]  lat_recon_y [0:255];
    reg [7:0]  lat_recon_u [0:63];
    reg [7:0]  lat_recon_v [0:63];
    reg signed [15:0] lat_p16_residual_y [0:255];
    reg signed [15:0] lat_p16_residual_u [0:63];
    reg signed [15:0] lat_p16_residual_v [0:63];
    reg [7:0]  p16_luma_ref [0:440];
    reg [7:0]  p16_chroma_u_ref [0:80];
    reg [7:0]  p16_chroma_v_ref [0:80];
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
    wire [31:0] syntax_mb_addr32 = {16'd0, syntax_mb_addr_r};
    wire [31:0] syntax_mb_x32 = syntax_mb_addr32 % MB_W;
    wire [31:0] syntax_mb_y32 = syntax_mb_addr32 / MB_W;
    wire [7:0] syntax_mb_x = syntax_mb_x32[7:0];
    wire [7:0] syntax_mb_y = syntax_mb_y32[7:0];
    wire [MB_IDX_W-1:0] syntax_mb_idx = syntax_mb_x[MB_IDX_W-1:0];
    wire [MB_IDX_W-1:0] wb_mb_idx = wb_mb_x[MB_IDX_W-1:0];
    // P_Skip / P16x16 / P16x8 / P8x16 / P8x8 (and P_8x8ref0). Multi-partition
    // modes walk slots sequentially through the shared MC engine below.
    wire syntax_inter_candidate = mb_type_valid && !slice_is_i && !slice_is_idr &&
                                !mb_intra &&
                                (mb_skip || (mb_type <= 5'd4)) &&
                                (mb_skip || (part_mode <= 3'd3));
    wire syntax_p16_candidate = syntax_inter_candidate &&
                                (mb_skip || (part_mode == 3'd0) || (mb_type == 5'd0));
    wire syntax_ppart_candidate = syntax_inter_candidate && !mb_skip &&
                                  (part_mode >= 3'd1) && (part_mode <= 3'd3);
    wire syntax_p16_launch = syntax_p16_candidate && (wb_state == ST_IDLE);
    wire p16_launch = p16_zero_mv_valid || syntax_p16_launch;
    wire [7:0] p16_launch_mb_x = p16_zero_mv_valid ? p16_mb_x : syntax_mb_x;
    wire [7:0] p16_launch_mb_y = p16_zero_mv_valid ? p16_mb_y : syntax_mb_y;
    wire p16_launch_is_ref = p16_zero_mv_valid ? p16_mb_is_ref : 1'b1;
    wire [15:0] syntax_request_byte_offset = {3'd0, mb_residual_bit_offset[15:3]};

    wire syntax_has_left = (syntax_mb_x != 8'd0) && mv_left_valid && (mv_left_ref == ref_idx_l0);
    wire syntax_has_top = mv_top_valid[syntax_mb_idx] && (mv_top_ref[syntax_mb_idx] == ref_idx_l0);
    wire [MB_IDX_W-1:0] syntax_top_right_idx = (syntax_mb_x32 + 32'd1 < MB_W) ?
                                      (syntax_mb_idx + MB_IDX_W'(1)) : syntax_mb_idx;
    wire syntax_has_top_right = (syntax_mb_x32 + 32'd1 < MB_W) &&
                                mv_top_valid[syntax_top_right_idx] &&
                                (mv_top_ref[syntax_top_right_idx] == ref_idx_l0);
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

    // ── Sequential multi-partition walk (16x8 / 8x16 / 8x8) ───────────────
    // One shared geometry+MVP+MC path, cycled over slots. No parallel predictors.
    reg [3:0]  part_slot_r;
    reg [2:0]  part_mode_r;
    reg        part_start_r;
    reg signed [15:0] part_mv_x_r, part_mv_y_r;
    reg        part_active_r;
    reg        part_mb_start_r;
    reg        part_blk_wr_r;
    reg [15:0] part_blk_mask_r;
    reg signed [15:0] part_blk_mv_x_r, part_blk_mv_y_r;
    reg [1:0]  part_blk_ref_r;
    reg        part_commit_r;

    wire [4:0] part_geo_x, part_geo_y, part_geo_w, part_geo_h;
    wire       part_geo_valid;
    h264_part_geometry u_part_geo (
        .part_mode(part_mode_r),
        .slot(part_slot_r),
        .sub_mb_type(part_sub_mb_types[part_slot_r[3:2]*2 +: 2]),
        .part_x(part_geo_x), .part_y(part_geo_y),
        .part_w(part_geo_w), .part_h(part_geo_h),
        .part_valid(part_geo_valid)
    );
    wire [15:0] part_geo_mask;
    h264_part_mask u_part_mask (
        .part_x(part_geo_x), .part_y(part_geo_y),
        .part_w(part_geo_w), .part_h(part_geo_h),
        .mask(part_geo_mask)
    );
    wire [1:0] part_ref_slot = (num_ref_idx_l0_active <= 8'd1) ? 2'd0
                               : part_ref_idx_l0[part_slot_r[3:2]*2 +: 2];

    wire nb_a_p, nb_a_i, nb_b_p, nb_b_i, nb_c_p, nb_c_i, nb_d_p, nb_d_i;
    wire [1:0] nb_a_r, nb_b_r, nb_c_r, nb_d_r;
    wire signed [15:0] nb_a_x, nb_a_y, nb_b_x, nb_b_y, nb_c_x, nb_c_y, nb_d_x, nb_d_y;
    h264_mv_nb_ctx4x4 #(.MB_WIDTH_MAX(MB_W), .MB_WIDTH_DEFAULT(MB_W)) u_mv_nb4 (
        .clk(clk), .reset(reset),
        .mb_x(syntax_mb_x), .mb_y(syntax_mb_y),
        .mb_width(mb_width), .first_mb_in_slice(first_mb_in_slice),
        .mb_start(part_mb_start_r),
        .blk_wr_valid(part_blk_wr_r),
        .blk_wr_mask(part_blk_mask_r),
        .blk_wr_inter(1'b1),
        .blk_wr_ref(part_blk_ref_r),
        .blk_wr_mv_x(part_blk_mv_x_r),
        .blk_wr_mv_y(part_blk_mv_y_r),
        .mb_commit(part_commit_r),
        .commit_mb_x(syntax_mb_x),
        .q_x(part_geo_x), .q_y(part_geo_y), .q_w(part_geo_w),
        .q_ref_idx(part_ref_slot),
        .nb_a_present(nb_a_p), .nb_a_inter(nb_a_i), .nb_a_ref(nb_a_r),
        .nb_a_mv_x(nb_a_x), .nb_a_mv_y(nb_a_y),
        .nb_b_present(nb_b_p), .nb_b_inter(nb_b_i), .nb_b_ref(nb_b_r),
        .nb_b_mv_x(nb_b_x), .nb_b_mv_y(nb_b_y),
        .nb_c_present(nb_c_p), .nb_c_inter(nb_c_i), .nb_c_ref(nb_c_r),
        .nb_c_mv_x(nb_c_x), .nb_c_mv_y(nb_c_y),
        .nb_d_present(nb_d_p), .nb_d_inter(nb_d_i), .nb_d_ref(nb_d_r),
        .nb_d_mv_x(nb_d_x), .nb_d_mv_y(nb_d_y)
    );
    wire signed [15:0] part_mvp_x, part_mvp_y;
    wire part_shape_override;
    h264_mv_pred_partition u_part_mvp (
        .part_mode(part_mode_r), .slot(part_slot_r), .ref_idx_l0(part_ref_slot),
        .nb_a_present(nb_a_p), .nb_a_inter(nb_a_i), .nb_a_ref(nb_a_r),
        .nb_a_mv_x(nb_a_x), .nb_a_mv_y(nb_a_y),
        .nb_b_present(nb_b_p), .nb_b_inter(nb_b_i), .nb_b_ref(nb_b_r),
        .nb_b_mv_x(nb_b_x), .nb_b_mv_y(nb_b_y),
        .nb_c_present(nb_c_p), .nb_c_inter(nb_c_i), .nb_c_ref(nb_c_r),
        .nb_c_mv_x(nb_c_x), .nb_c_mv_y(nb_c_y),
        .nb_d_present(nb_d_p), .nb_d_inter(nb_d_i), .nb_d_ref(nb_d_r),
        .nb_d_mv_x(nb_d_x), .nb_d_mv_y(nb_d_y),
        .mvp_x(part_mvp_x), .mvp_y(part_mvp_y),
        .shape_override(part_shape_override)
    );
    wire signed [15:0] part_mv_comb_x = part_mvp_x + part_mvd_x[part_slot_r];
    wire signed [15:0] part_mv_comb_y = part_mvp_y + part_mvd_y[part_slot_r];

    // Slot order: 16x8/8x16 use 0 then 1; P8x8 walks only slots whose
    // sub_mb_type covers them (geometry reports invalid for empty slots).
    wire [3:0] part_slot_limit = (part_mode_r == 3'd3) ? 4'd15 : 4'd1;
    wire ppart_launch = syntax_ppart_candidate && (wb_state == ST_IDLE);

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
                assign cavlc_dequant_coeff[cavlc_coeff_i] = (p16_res_block_idx >= P16_LUMA_RES_BLOCKS) ? cavlc_coeff[1] : cavlc_coeff[0];
            else if (cavlc_coeff_i == 1)
                assign cavlc_dequant_coeff[cavlc_coeff_i] = (p16_res_block_idx >= P16_LUMA_RES_BLOCKS) ? cavlc_coeff[0] : cavlc_coeff[1];
            else
                assign cavlc_dequant_coeff[cavlc_coeff_i] = cavlc_coeff[cavlc_coeff_i];
`else
            assign cavlc_dequant_coeff[cavlc_coeff_i] = cavlc_coeff[cavlc_coeff_i];
`endif
        end
    endgenerate
    // Block geometry follows luma4x4_index(): index[7:4] is the row, so
    // block[3:2] is the 4x4 row and block[1:0] the 4x4 column.
    wire [1:0] res_blk_x = p16_res_block_idx[1:0];
    wire [1:0] res_blk_y = p16_res_block_idx[3:2];
    wire       res_is_luma = (p16_res_block_idx < P16_LUMA_RES_BLOCKS);
    // 8x8 coded_block_pattern group under this core's raster 4x4 ordering.
    wire [1:0] res_cbp_group = {res_blk_y[1], res_blk_x[1]};
    wire       res_block_coded = res_is_luma ? p16_cbp_luma_r[res_cbp_group]
                                             : (p16_cbp_chroma_r == 2'd2);

    wire       res_left_internal = (res_blk_x != 2'd0);
    wire       res_up_internal   = (res_blk_y != 2'd0);
    wire [4:0] res_left_tc = res_left_internal ? res_tc_cur[{res_blk_y, res_blk_x - 2'd1}]
                                               : res_tc_left[res_blk_y];
    wire       res_left_tc_valid = res_left_internal ? 1'b1 : res_tc_left_valid;
    wire [4:0] res_up_tc = res_up_internal ? res_tc_cur[{res_blk_y - 2'd1, res_blk_x}]
                                           : res_tc_top[{wb_mb_x[MB_IDX_W-1:0], res_blk_x}];
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
        .block_x(res_blk_x),
        .block_y(res_blk_y),
        .left_tc_valid(res_left_tc_valid),
        .left_tc(res_left_tc),
        .up_tc_valid(res_up_tc_valid),
        .up_tc(res_up_tc),
        .nA_available(),
        .nB_available(),
        .nC(res_nC),
        .coeff_token_table(res_coeff_token_table)
    );

    h264_cavlc_residual_block u_product_p16_residual0 (
        .clk(clk),
        .reset(reset || slice_start),
        .start(cavlc_start_r),
        // Chroma AC has no neighbour context stored yet, so it still predicts
        // from table 0; luma is fully contexted.
        .coeff_token_table(res_is_luma ? res_coeff_token_table : 3'd0),
        .max_coeff(5'd16),
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
    wire signed [28:0] p16_res_dequant [0:15];
    wire signed [28:0] p16_res_idct [0:15];
    h264_dequant4x4 u_product_p16_res_dequant (
        .coeff(cavlc_dequant_coeff),
        .qp(slice_qp_y),
        .max_coeff(5'd16),
        .dequant(p16_res_dequant)
    );
    h264_idct4x4 u_product_p16_res_idct (
        .dequant(p16_res_dequant),
        .residual(p16_res_idct)
    );
`ifdef H264_DECODE_CORE_FAULT_DROP_LAST_LUMA_RESIDUAL
    wire p16_drop_this_luma_residual = (p16_res_block_idx == (P16_LUMA_RES_BLOCKS - 5'd1));
`else
    wire p16_drop_this_luma_residual = 1'b0;
`endif
`ifdef H264_DECODE_CORE_FAULT_DROP_LAST_CHROMA_RESIDUAL
    wire p16_drop_this_chroma_residual = (p16_res_block_idx == (P16_RES_BLOCKS - 5'd1));
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

    wire [7:0] wb_data = (wb_plane == 2'd0) ? lat_recon_y[wb_sample_idx] :
                         (wb_plane == 2'd1) ? lat_recon_u[wb_sample_idx[5:0]] :
                                               lat_recon_v[wb_sample_idx[5:0]];
    wire signed [15:0] p16_residual_sample =
        (wb_plane == 2'd0) ? lat_p16_residual_y[wb_sample_idx] :
        (wb_plane == 2'd1) ? lat_p16_residual_u[wb_sample_idx[5:0]] :
                             lat_p16_residual_v[wb_sample_idx[5:0]];

    wire [7:0] p16_pred_y [0:255];
    wire       p16_pred_y_valid [0:255];
    wire [7:0] p16_pred_u [0:63];
    wire       p16_pred_u_valid [0:63];
    wire [7:0] p16_pred_v [0:63];
    wire       p16_pred_v_valid [0:63];
    h264_inter_mc_part u_product_p16_mc (
        .luma_ref_win(p16_luma_ref),
        .chroma_u_ref_win(p16_chroma_u_ref),
        .chroma_v_ref_win(p16_chroma_v_ref),
        .luma_frac_x(p16_mv_x_qpel_r[1:0]),
        .luma_frac_y(p16_mv_y_qpel_r[1:0]),
        .chroma_frac_x(p16_mv_x_qpel_r[2:0]),
        .chroma_frac_y(p16_mv_y_qpel_r[2:0]),
        .part_w(5'd16),
        .part_h(5'd16),
        .pred_y(p16_pred_y),
        .pred_y_valid(p16_pred_y_valid),
        .pred_u(p16_pred_u),
        .pred_u_valid(p16_pred_u_valid),
        .pred_v(p16_pred_v),
        .pred_v_valid(p16_pred_v_valid)
    );
    // 4x4 raster index inside the MB for the current luma/chroma sample.
    wire [3:0] part_luma_blk4 = {wb_sample_idx[7:6], wb_sample_idx[3:2]};
    // Map chroma sample into covering luma 8x8 top-left 4x4 for mask probe.
    wire [3:0] part_chroma_luma_blk4 = {wb_sample_idx[5], 1'b0, wb_sample_idx[2], 1'b0};
    wire part_mask_hit = part_active_r && (
        (wb_plane == 2'd0) ? part_blk_mask_r[part_luma_blk4]
                           : part_blk_mask_r[part_chroma_luma_blk4]
    );
    wire p16_pred_in_part = part_active_r ? part_mask_hit :
                            ((wb_plane == 2'd0) ? p16_pred_y_valid[wb_sample_idx] :
                             (wb_plane == 2'd1) ? p16_pred_u_valid[wb_sample_idx[5:0]] :
                                                  p16_pred_v_valid[wb_sample_idx[5:0]]);
    wire [7:0] p16_pred_sample = !p16_pred_in_part ? 8'd0 :
                                 (wb_plane == 2'd0) ? p16_pred_y[wb_sample_idx] :
                                 (wb_plane == 2'd1) ? p16_pred_u[wb_sample_idx[5:0]] :
                                                      p16_pred_v[wb_sample_idx[5:0]];
`ifdef H264_DECODE_CORE_FAULT_DROP_PRED
    wire signed [17:0] p16_pred_term = 18'sd0;
`else
    wire signed [17:0] p16_pred_term = {10'd0, p16_pred_sample};
`endif
`ifdef H264_DECODE_CORE_FAULT_DROP_RESIDUAL
    wire signed [17:0] p16_residual_term = 18'sd0;
`else
    wire signed [17:0] p16_residual_term = {{2{p16_residual_sample[15]}}, p16_residual_sample};
`endif
    wire signed [17:0] p16_recon_sum = p16_pred_term + p16_residual_term;
    wire [31:0] wb_mb_x32 = {24'd0, wb_mb_x};
    wire [31:0] wb_mb_y32 = {24'd0, wb_mb_y};
    wire [31:0] mb_width32 = {24'd0, mb_width};
    wire [31:0] mb_height32 = {24'd0, mb_height};
    wire [31:0] wb_mb_addr32 = wb_mb_y32 * MB_W + wb_mb_x32;
    wire [15:0] wb_mb_addr16 = wb_mb_addr32[15:0];
    wire        wb_last_sample = (wb_idx == 9'd383);
    wire        wb_last_mb = (wb_mb_x32 == (MB_W - 1)) &&
                             (wb_mb_y32 == (MB_H - 1));
    wire        product_intra_mb_start = mb_type_valid && mb_intra && !mb_skip;
    // intra_mb_x_r/intra_mb_y_r only take the new macroblock position on the
    // edge AFTER mb_start, but the neighbour-context store and the prediction
    // front-end both latch their state ON mb_start.  Feeding them the stale
    // register shifts every macroblock's neighbours one position to the left,
    // which is fatal once the raster sweep walks a whole frame.
    wire [7:0]  intra_mb_x_now = product_intra_mb_start ? syntax_mb_x : intra_mb_x_r;
    wire [7:0]  intra_mb_y_now = product_intra_mb_start ? syntax_mb_y : intra_mb_y_r;
    wire [7:0]  product_intra_mb_type = {3'd0, mb_type};
    wire [1:0]  product_intra_i16_mode = intra16x16_mode;
    wire signed [28:0] product_intra_i16_dc [0:15];
    wire [7:0]  product_intra_recon_y [0:255];
    // Real chroma recon (prediction + residual add). No longer hard-tied to 128.
    reg  [7:0]  product_intra_recon_u [0:63];
    reg  [7:0]  product_intra_recon_v [0:63];
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
    // Chroma 8x8 prediction (spec 8.3.4). DC uses per-4x4-quadrant averages —
    // do NOT reuse the luma DC single-value rule (see h264_chroma8x8_pred).
    reg         product_chroma_start_r;
    wire        product_chroma_u_valid;
    wire        product_chroma_v_valid;
    wire [7:0]  product_chroma_u_pred [0:63];
    wire [7:0]  product_chroma_v_pred [0:63];
    genvar intra_gi;
    integer chroma_pi;
    generate
        for (intra_gi = 0; intra_gi < 16; intra_gi = intra_gi + 1) begin : g_product_intra_i16_dc
            assign product_intra_i16_dc[intra_gi] = 29'sd0;
            assign product_intra_ctx_recon_pixels[intra_gi] = 8'd128;
        end
    endgenerate

    h264_chroma8x8_pred u_product_chroma_u_pred (
        .clk(clk),
        .start(product_chroma_start_r),
        .mode(chroma_pred_mode),
        .above(product_intra_chroma_u_above),
        .left(product_intra_chroma_u_left),
        .top_left(product_intra_chroma_u_topleft),
        .has_above(product_intra_has_chroma_above),
        .has_left(product_intra_has_chroma_left),
        .valid(product_chroma_u_valid),
        .pred(product_chroma_u_pred)
    );
    h264_chroma8x8_pred u_product_chroma_v_pred (
        .clk(clk),
        .start(product_chroma_start_r),
        .mode(chroma_pred_mode),
        .above(product_intra_chroma_v_above),
        .left(product_intra_chroma_v_left),
        .top_left(product_intra_chroma_v_topleft),
        .has_above(product_intra_has_chroma_above),
        .has_left(product_intra_has_chroma_left),
        .valid(product_chroma_v_valid),
        .pred(product_chroma_v_pred)
    );

    always @(posedge clk) begin
        product_chroma_start_r <= product_intra_mb_start;
        if (reset) begin
            for (chroma_pi = 0; chroma_pi < 64; chroma_pi = chroma_pi + 1) begin
                product_intra_recon_u[chroma_pi] <= 8'd128;
                product_intra_recon_v[chroma_pi] <= 8'd128;
            end
        end else begin
            // Prediction-only for now: feed still bit-syncs chroma residual for
            // stream position, and P-slice residual is applied on the inter path.
            // Intra chroma residual IDCT add remains a follow-on.
            if (product_chroma_u_valid) begin
                for (chroma_pi = 0; chroma_pi < 64; chroma_pi = chroma_pi + 1)
                    product_intra_recon_u[chroma_pi] <= product_chroma_u_pred[chroma_pi];
            end
            if (product_chroma_v_valid) begin
                for (chroma_pi = 0; chroma_pi < 64; chroma_pi = chroma_pi + 1)
                    product_intra_recon_v[chroma_pi] <= product_chroma_v_pred[chroma_pi];
            end
        end
    end

    h264_intra_nb_ctx #(
        .MB_WIDTH_MAX(MB_W),
        .MB_WIDTH_DEFAULT(MB_W)
    ) u_product_intra_nb_ctx (
        .clk(clk),
        .reset(reset),
        .mb_x(intra_mb_x_now),
        .mb_y(intra_mb_y_now),
        .mb_width(mb_width),
        .first_mb_in_slice(first_mb_in_slice),
        .mb_start(product_intra_mb_start),
        .block_idx(luma4x4_idx),
        .block_valid(1'b0),
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
        .mb_x(intra_mb_x_now),
        .mb_y(intra_mb_y_now),
        .i16_pred_mode(product_intra_i16_mode),
        .block_valid(luma4x4_valid),
        .block_index(luma4x4_idx),
        .block_coeff(luma4x4_coeff_zigzag),
        .i16_dc_valid(product_intra_mb_start),
        .i16_dc(product_intra_i16_dc),
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

    wire product_recon_mb_valid = recon_mb_valid || product_intra_recon_valid;
    wire [7:0] product_recon_mb_x = product_intra_recon_valid ? intra_mb_x_r : recon_mb_x;
    wire [7:0] product_recon_mb_y = product_intra_recon_valid ? intra_mb_y_r : recon_mb_y;
    wire product_recon_mb_is_ref = product_intra_recon_valid ? intra_mb_is_ref_r : recon_mb_is_ref;
`ifdef H264_DECODE_CORE_FAULT_DROP_WB
    wire product_wb_en = 1'b0;
`else
    wire product_wb_en = (wb_state == ST_WRITE);
`endif
    wire p16_sample_wb_en = (wb_state == ST_P16_WRITE) &&
                             (!part_active_r || part_mask_hit);
    wire deblock_filtered_sample_valid = product_wb_en | p16_sample_wb_en;
    wire deblock_filtered_mb_valid = (wb_state == ST_COMMIT);
    wire deblock_filtered_frame_done = deblock_filtered_mb_valid && wb_last_mb;
    wire deblock_frame_boundary = (wb_state == ST_FRAME_BOUNDARY);
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
    h264_dpb_one_ref #(
        .FRAME_W(FRAME_W),
        .FRAME_H(FRAME_H)
    ) u_product_dpb_ref (
        .clk(clk),
        .reset(reset),
        .idr_start(slice_start && slice_is_idr),
        .frame_done(deblock_ref_ready_pulse | p16_ref_seed_r),
        .ref_ready(dpb_ref_ready),
        .current_base(dpb_ref_current_base),
        .reference_base(dpb_ref_reference_base),
        .filtered_sample_valid(deblock_filtered_sample_valid),
        .filtered_mb_x(wb_mb_x),
        .filtered_mb_y(wb_mb_y),
        .filtered_plane(wb_plane),
        .filtered_sample_idx(wb_sample_idx),
        .filtered_sample(dpb_ref_filtered_sample),
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
    always @(posedge clk) begin
        frame_done_r <= deblock_ref_ready_pulse;
        p16_fetch_start_r <= 1'b0;
        p16_ref_seed_r <= 1'b0;
        rbsp_request_valid_r <= 1'b0;
        cavlc_start_r <= 1'b0;
        part_start_r <= 1'b0;
        part_mb_start_r <= 1'b0;
        part_blk_wr_r <= 1'b0;
        part_commit_r <= 1'b0;
        if (reset || slice_start) begin
            wb_state <= ST_IDLE;
            wb_idx <= 9'd0;
            wb_mb_x <= 8'd0;
            wb_mb_y <= 8'd0;
            wb_mb_is_ref <= 1'b0;
            wb_base <= 32'd0;
            p16_ref_base_r <= 32'd0;
            part_slot_r <= 4'd0;
            part_mode_r <= 3'd0;
            part_active_r <= 1'b0;
            part_mv_x_r <= 16'sd0;
            part_mv_y_r <= 16'sd0;
            part_blk_mask_r <= 16'd0;
            part_blk_mv_x_r <= 16'sd0;
            part_blk_mv_y_r <= 16'sd0;
            part_blk_ref_r <= 2'd0;
            p16_mv_x_qpel_r <= 16'sd0;
            p16_mv_y_qpel_r <= 16'sd0;
            p16_ref_idx_l0_r <= 2'd0;
            p16_fetch_start_r <= 1'b0;
            p16_ref_seed_r <= 1'b0;
            p16_res_bit_offset_r <= 10'd0;
            p16_res_block_idx <= 5'd0;
            cavlc_start_r <= 1'b0;
            wb_commit_p16 <= 1'b0;
            p16_cbp_luma_r <= 4'd0;
            p16_cbp_chroma_r <= 2'd0;
            res_tc_left_valid <= 1'b0;
            for (res_tc_i = 0; res_tc_i < 16; res_tc_i = res_tc_i + 1)
                res_tc_cur[res_tc_i] <= 5'd0;
            for (res_tc_i = 0; res_tc_i < 4; res_tc_i = res_tc_i + 1)
                res_tc_left[res_tc_i] <= 5'd0;
            for (res_tc_i = 0; res_tc_i < MB_W * 4; res_tc_i = res_tc_i + 1)
                res_tc_top[res_tc_i] <= 5'd0;
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
            mb_count_r <= 16'd0;
            frame_done_r <= 1'b0;
            for (wb_i = 0; wb_i < 256; wb_i = wb_i + 1)
                lat_recon_y[wb_i] <= 8'd0;
            for (wb_i = 0; wb_i < 64; wb_i = wb_i + 1) begin
                lat_recon_u[wb_i] <= 8'd0;
                lat_recon_v[wb_i] <= 8'd0;
            end
            for (wb_i = 0; wb_i < 256; wb_i = wb_i + 1)
                lat_p16_residual_y[wb_i] <= 16'sd0;
            for (wb_i = 0; wb_i < 64; wb_i = wb_i + 1) begin
                lat_p16_residual_u[wb_i] <= 16'sd0;
                lat_p16_residual_v[wb_i] <= 16'sd0;
            end
            for (wb_i = 0; wb_i < 441; wb_i = wb_i + 1)
                p16_luma_ref[wb_i] <= 8'd0;
            for (wb_i = 0; wb_i < 81; wb_i = wb_i + 1) begin
                p16_chroma_u_ref[wb_i] <= 8'd0;
                p16_chroma_v_ref[wb_i] <= 8'd0;
            end
            for (wb_i = 0; wb_i < MB_W; wb_i = wb_i + 1) begin
                mv_top_x[wb_i] <= 16'sd0;
                mv_top_y[wb_i] <= 16'sd0;
                mv_top_ref[wb_i] <= 2'd0;
                mv_top_valid[wb_i] <= 1'b0;
            end
        end else begin
            if (syntax_p16_candidate || syntax_ppart_candidate) begin
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
            end
            if (product_intra_recon_valid)
                intra_active_r <= 1'b0;

            case (wb_state)
            ST_IDLE: begin
                if (ppart_launch) begin
                    wb_mb_x <= syntax_mb_x;
                    wb_mb_y <= syntax_mb_y;
                    wb_mb_is_ref <= 1'b1;
                    wb_base <= dpb_write_base;
                    p16_ref_base_r <= dpb_ref_base;
                    part_mode_r <= part_mode;
                    part_slot_r <= 4'd0;
                    part_active_r <= 1'b1;
                    part_mb_start_r <= 1'b1;
                    p16_cbp_luma_r <= cbp_luma;
                    p16_cbp_chroma_r <= cbp_chroma;
                    p16_res_bit_offset_r <= launch_residual_rel_bit_offset[9:0];
                    p16_res_block_idx <= 5'd0;
                    for (res_tc_i = 0; res_tc_i < 16; res_tc_i = res_tc_i + 1)
                        res_tc_cur[res_tc_i] <= 5'd0;
                    wb_idx <= 9'd0;
                    wb_commit_p16 <= 1'b0;
                    for (wb_i = 0; wb_i < 256; wb_i = wb_i + 1)
                        lat_p16_residual_y[wb_i] <= 16'sd0;
                    for (wb_i = 0; wb_i < 64; wb_i = wb_i + 1) begin
                        lat_p16_residual_u[wb_i] <= 16'sd0;
                        lat_p16_residual_v[wb_i] <= 16'sd0;
                    end
                    // Decode residual once for the whole MB, then walk partitions.
                    wb_state <= ST_P16_RES_START;
                end else if (p16_launch) begin
                    wb_mb_x <= p16_launch_mb_x;
                    wb_mb_y <= p16_launch_mb_y;
                    wb_mb_is_ref <= p16_launch_is_ref;
                    wb_base <= dpb_write_base;
                    p16_ref_base_r <= dpb_ref_base;
`ifdef H264_DECODE_CORE_FAULT_PERTURB_MV
                    p16_mv_x_qpel_r <= (p16_zero_mv_valid ? mv_x_qpel : syntax_mv_x) + 16'sd2;
`else
                    p16_mv_x_qpel_r <= p16_zero_mv_valid ? mv_x_qpel : syntax_mv_x;
`endif
                    p16_mv_y_qpel_r <= p16_zero_mv_valid ? mv_y_qpel : syntax_mv_y;
                    p16_ref_idx_l0_r <= (num_ref_idx_l0_active <= 8'd1) ? 2'd0 : ref_idx_l0;
                    p16_res_bit_offset_r <= launch_residual_rel_bit_offset[9:0];
                    p16_res_block_idx <= 5'd0;
                    p16_cbp_luma_r <= mb_skip ? 4'd0 : cbp_luma;
                    p16_cbp_chroma_r <= mb_skip ? 2'd0 : cbp_chroma;
                    for (res_tc_i = 0; res_tc_i < 16; res_tc_i = res_tc_i + 1)
                        res_tc_cur[res_tc_i] <= 5'd0;
                    wb_idx <= 9'd0;
                    wb_commit_p16 <= 1'b0;
                    for (wb_i = 0; wb_i < 256; wb_i = wb_i + 1)
                        lat_p16_residual_y[wb_i] <= p16_zero_mv_valid ? p16_residual_y[wb_i] : 16'sd0;
                    for (wb_i = 0; wb_i < 64; wb_i = wb_i + 1) begin
                        lat_p16_residual_u[wb_i] <= p16_zero_mv_valid ? p16_residual_u[wb_i] : 16'sd0;
                        lat_p16_residual_v[wb_i] <= p16_zero_mv_valid ? p16_residual_v[wb_i] : 16'sd0;
                    end
                    wb_state <= p16_zero_mv_valid ? ST_P16_REF_SEED : ST_P16_RES_START;
                end else if (product_recon_mb_valid) begin
                    wb_mb_x <= product_recon_mb_x;
                    wb_mb_y <= product_recon_mb_y;
                    wb_mb_is_ref <= product_recon_mb_is_ref;
                    wb_base <= dpb_write_base;
                    wb_idx <= 9'd0;
                    wb_commit_p16 <= 1'b0;
                    for (wb_i = 0; wb_i < 256; wb_i = wb_i + 1)
                        lat_recon_y[wb_i] <= product_intra_recon_valid ? product_intra_recon_y[wb_i] : recon_y[wb_i];
                    for (wb_i = 0; wb_i < 64; wb_i = wb_i + 1) begin
                        lat_recon_u[wb_i] <= product_intra_recon_valid ? product_intra_recon_u[wb_i] : recon_u[wb_i];
                        lat_recon_v[wb_i] <= product_intra_recon_valid ? product_intra_recon_v[wb_i] : recon_v[wb_i];
                    end
                    wb_state <= ST_WRITE;
                end
            end
            ST_P16_RES_START: begin
                if (res_block_coded) begin
                    cavlc_start_r <= 1'b1;
                    wb_state <= ST_P16_RES_WAIT;
                end else begin
                    // No bits in the stream for this block: leave the residual
                    // latch at its launch zero and do not advance bit_offset.
                    if (res_is_luma)
                        res_tc_cur[p16_res_block_idx[3:0]] <= 5'd0;
                    if (p16_res_block_idx == (P16_RES_BLOCKS - 5'd1)) begin
                        res_tc_left_valid <= 1'b1;
                        for (res_tc_i = 0; res_tc_i < 4; res_tc_i = res_tc_i + 1) begin
                            res_tc_left[res_tc_i] <= res_tc_cur[{res_tc_i[1:0], 2'd3}];
                            res_tc_top[{wb_mb_x[MB_IDX_W-1:0], res_tc_i[1:0]}] <=
                                res_tc_cur[{2'd3, res_tc_i[1:0]}];
                        end
                        res_tc_top_valid[wb_mb_x[MB_IDX_W-1:0]] <= 1'b1;
                        wb_state <= part_active_r ? ST_PART_PRED : ST_P16_REF_SEED;
                    end else begin
                        p16_res_block_idx <= p16_res_block_idx + 5'd1;
                    end
                end
            end
            ST_P16_RES_WAIT: begin
                if (cavlc_done) begin
`ifndef H264_DECODE_CORE_FAULT_DROP_SCHEDULED_RESIDUAL
                    if (cavlc_ok) begin
                        for (wb_i = 0; wb_i < 16; wb_i = wb_i + 1) begin
                            if (p16_res_block_idx < P16_LUMA_RES_BLOCKS) begin
                                if (!p16_drop_this_luma_residual)
                                    lat_p16_residual_y[luma4x4_index(p16_res_block_idx[3:0], wb_i[3:0])] <= sat16(p16_res_idct[wb_i]);
                            end else if (p16_res_block_idx < (P16_LUMA_RES_BLOCKS + 5'd4)) begin
                                if (!p16_drop_this_chroma_residual) begin
                                    if (p16_swap_chroma_residual)
                                        lat_p16_residual_v[chroma4x4_index(p16_res_block_idx[1:0], wb_i[3:0])] <= sat16(p16_res_idct[wb_i]);
                                    else
                                        lat_p16_residual_u[chroma4x4_index(p16_res_block_idx[1:0], wb_i[3:0])] <= sat16(p16_res_idct[wb_i]);
                                end
                            end else begin
                                if (!p16_drop_this_chroma_residual) begin
                                    if (p16_swap_chroma_residual)
                                        lat_p16_residual_u[chroma4x4_index(p16_res_block_idx[1:0], wb_i[3:0])] <= sat16(p16_res_idct[wb_i]);
                                    else
                                        lat_p16_residual_v[chroma4x4_index(p16_res_block_idx[1:0], wb_i[3:0])] <= sat16(p16_res_idct[wb_i]);
                                end
                            end
                        end
                    end
`endif
                    if (res_is_luma)
                        res_tc_cur[p16_res_block_idx[3:0]] <= cavlc_ok ? cavlc_total_coeff : 5'd0;

                    if (p16_res_block_idx == (P16_RES_BLOCKS - 5'd1)) begin
                        // Roll this macroblock's edge total_coeff into the left
                        // register and the per-column top line buffer.
                        res_tc_left_valid <= 1'b1;
                        for (res_tc_i = 0; res_tc_i < 4; res_tc_i = res_tc_i + 1) begin
                            res_tc_left[res_tc_i] <= res_tc_cur[{res_tc_i[1:0], 2'd3}];
                            res_tc_top[{wb_mb_x[MB_IDX_W-1:0], res_tc_i[1:0]}] <=
                                res_tc_cur[{2'd3, res_tc_i[1:0]}];
                        end
                        res_tc_top_valid[wb_mb_x[MB_IDX_W-1:0]] <= 1'b1;
                        wb_state <= part_active_r ? ST_PART_PRED : ST_P16_REF_SEED;
                    end else begin
                        p16_res_block_idx <= p16_res_block_idx + 5'd1;
                        p16_res_bit_offset_r <= cavlc_bit_offset_end;
                        wb_state <= ST_P16_RES_START;
                    end
                end
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
                if (dpb_ref_luma_window_valid)
                    p16_luma_ref[dpb_ref_luma_window_idx] <= dpb_ref_luma_window_sample;
                if (dpb_ref_chroma_u_window_valid)
                    p16_chroma_u_ref[dpb_ref_chroma_window_idx] <= dpb_ref_chroma_window_sample;
                if (dpb_ref_chroma_v_window_valid)
                    p16_chroma_v_ref[dpb_ref_chroma_window_idx] <= dpb_ref_chroma_window_sample;
                if (dpb_ref_fetch_done)
                    wb_state <= ST_P16_WRITE;
            end
            ST_P16_WRITE: begin
                if (wb_last_sample) begin
                    wb_commit_p16 <= 1'b1;
                    if (part_active_r)
                        wb_state <= ST_PART_ADV;
                    else
                        wb_state <= ST_COMMIT;
                end else begin
                    wb_idx <= wb_idx + 9'd1;
                end
            end
            ST_PART_PRED: begin
                if (part_geo_valid) begin
                    part_mv_x_r <= part_mv_comb_x;
                    part_mv_y_r <= part_mv_comb_y;
                    p16_mv_x_qpel_r <= part_mv_comb_x;
                    p16_mv_y_qpel_r <= part_mv_comb_y;
                    p16_ref_idx_l0_r <= part_ref_slot;
                    part_blk_wr_r <= 1'b1;
                    part_blk_mask_r <= part_geo_mask;
                    part_blk_mv_x_r <= part_mv_comb_x;
                    part_blk_mv_y_r <= part_mv_comb_y;
                    part_blk_ref_r <= part_ref_slot;
                    wb_idx <= 9'd0;
                    // Shared full-MB MC engine; writeback is mask-gated so only
                    // this partition's samples commit. Residual already latched.
                    wb_state <= ST_P16_REF_SEED;
                end else begin
                    wb_state <= ST_PART_ADV;
                end
            end
            ST_PART_ADV: begin
                if (part_slot_r >= part_slot_limit) begin
                    part_active_r <= 1'b0;
                    part_commit_r <= 1'b1;
                    wb_state <= ST_COMMIT;
                end else begin
                    part_slot_r <= part_slot_r + 4'd1;
                    wb_state <= ST_PART_PRED;
                end
            end
            ST_WRITE: begin
                if (wb_last_sample) begin
                    wb_commit_p16 <= 1'b0;
                    wb_state <= ST_COMMIT;
                end else begin
                    wb_idx <= wb_idx + 9'd1;
                end
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

    assign dpb_wr_en = product_wb_en | p16_sample_wb_en;
    assign dpb_wr_addr = product_wb_addr;
    assign dpb_wr_data = dpb_ref_filtered_sample;

    // Present writeback: same sample stream, plane + frame-relative (x,y).
    wire [15:0] px_luma_x   = {4'd0, wb_mb_x, 4'd0} + {12'd0, wb_sample_idx[3:0]};
    wire [15:0] px_luma_y   = {4'd0, wb_mb_y, 4'd0} + {12'd0, wb_sample_idx[7:4]};
    wire [15:0] px_chroma_x = {5'd0, wb_mb_x, 3'd0} + {13'd0, wb_sample_idx[2:0]};
    wire [15:0] px_chroma_y = {5'd0, wb_mb_y, 3'd0} + {13'd0, wb_sample_idx[5:3]};
    assign px_wr_en    = product_wb_en | p16_sample_wb_en;
    assign px_wr_plane = wb_plane;
    assign px_wr_x     = (wb_plane == 2'd0) ? px_luma_x : px_chroma_x;
    assign px_wr_y     = (wb_plane == 2'd0) ? px_luma_y : px_chroma_y;
    assign px_wr_data  = dpb_ref_filtered_sample;
    assign dpb_rd_en = dpb_ref_mem_rd;
    assign dpb_rd_addr = p16_win_rd_addr;
    assign rbsp_request_offset = rbsp_request_offset_r;
    assign rbsp_request_valid = rbsp_request_valid_r;
    assign frame_done = frame_done_r;
    assign frame_mb_count = mb_count_r;
    assign intra_blocks_done = product_intra_blocks_done;
    assign busy = (wb_state != ST_IDLE) || intra_active_r;
    assign decode_state = wb_state;
    assign current_mb_addr = (wb_state == ST_IDLE) ? syntax_mb_addr_r : wb_mb_addr16;
    wire _keep_part_syn = |part_sub_mb_types | |part_ref_idx_l0 | |part_mvd_valid |
                        |part_mvd_x[0] | |part_mvd_y[0] | |num_ref_idx_l0_active |
                        part_geo_valid | part_shape_override | part_active_r;
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
        |part_mode | |part_idx | _keep_part_syn | cavlc_busy | |cavlc_bit_offset_end |
        |cavlc_total_coeff | |cavlc_trailing_ones | |cavlc_total_zeros |
        |cavlc_level_dbg[0] | |cavlc_run_dbg[0] |
        deblock_wb_valid | |deblock_wb_mb_addr | deblock_wb_is_ref |
        deblock_dpb_invalidate_refs | deblock_ref_ready_pulse |
        |deblock_ref_ready_slot | deblock_commit_order_error;

endmodule
