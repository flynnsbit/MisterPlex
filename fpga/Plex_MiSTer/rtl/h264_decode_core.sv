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
    // mb_skip_run ue(v) from the CAVLC slice-data parser. In a P slice each
    // coded macroblock is preceded by a run length; the core drains the run
    // itself as P_Skip macroblocks, so the parser only has to hand over the
    // parsed value once per run.
    input  wire        mb_skip_run_valid,
    input  wire [15:0] mb_skip_run,
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

    // ── Reference picture sample port for motion compensation ──────────────
    // Sample-at-a-time request/response into the reference picture. Requests
    // are (plane, x, y) in the reference frame's own coordinate system, already
    // clamped to the picture; responses must come back in request order.
    //
    // These are POST-deblocking samples: motion compensation reads the filtered
    // reference picture (clause 8.4.2.2), unlike intra prediction which reads
    // the pre-deblock neighbour context inside this module.
    //
    // The DDR-backed reference buffer that services this port is owned
    // elsewhere; this module only drives the handshake.
    output wire        ref_req_valid,
    output wire [1:0]  ref_req_plane,        // 0 = Y, 1 = Cb, 2 = Cr
    output wire [15:0] ref_req_x,
    output wire [15:0] ref_req_y,
    input  wire        ref_req_ready,
    input  wire        ref_rsp_valid,
    input  wire [7:0]  ref_rsp_sample,

    // ── Frame output (decoded frame to present path) ──
    output wire        frame_done,           // pulse: complete frame decoded
    output wire [15:0] frame_mb_count,       // MBs decoded this frame

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
    // product: issue dpb_rd_en/dpb_rd_addr, then consume a later dpb_rd_valid.
    localparam [7:0] ST_IDLE         = 8'd0;
    localparam [7:0] ST_WRITE        = 8'd1;
    localparam [7:0] ST_P16_TAP_REQ  = 8'd2;
    localparam [7:0] ST_P16_TAP_WAIT = 8'd3;
    localparam [7:0] ST_P16_WRITE    = 8'd4;
    localparam [7:0] ST_P16_RES_START = 8'd5;
    localparam [7:0] ST_P16_RES_WAIT  = 8'd6;
    // Standalone Intra_16x16 DC reconstruction (clause 8.3.3.3 + 8.3.4.1).
    // An I_16x16 DC macroblock with no residual is fully described by its
    // prediction, so this path predicts, publishes the result back into the
    // PRE-deblock neighbour context, and writes the macroblock out. It does
    // not go through h264_decode_top: that path is for I_NxN and for the
    // remaining I_16x16 modes.
    localparam [7:0] ST_I16_WAIT     = 8'd7;
    localparam [7:0] ST_I16_COMMIT   = 8'd8;
    localparam [7:0] ST_I16_FLUSH    = 8'd9;
    // P_Skip: no residual, no transform. The reconstructed macroblock is the
    // motion compensated prediction straight from the reference picture.
    //
    // DEBLOCKING: a skipped macroblock is still filtered by the deblocking
    // filter (clause 8.7 derives bS from motion vectors and reference indices,
    // which a skipped MB has). A future deblocking filter must walk these
    // macroblocks too -- do not use "was skipped" as a skip condition there.
    localparam [7:0] ST_PSKIP_WAIT   = 8'd10;
    localparam [4:0] P16_LUMA_RES_BLOCKS = 5'd16;
    localparam [4:0] P16_CHROMA_RES_BLOCKS = 5'd8;
    localparam [4:0] P16_RES_BLOCKS = P16_LUMA_RES_BLOCKS + P16_CHROMA_RES_BLOCKS;
    localparam [15:0] FRAME_W16 = 16'(FRAME_W);
    localparam [15:0] FRAME_H16 = 16'(FRAME_H);
    localparam [15:0] CHROMA_W16 = 16'(FRAME_W / 2);
    localparam [15:0] CHROMA_H16 = 16'(FRAME_H / 2);
    localparam int MB_IDX_W = (MB_W <= 1) ? 1 : $clog2(MB_W);

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
    reg [6:0]  p16_tap_idx;
    reg [9:0]  p16_res_bit_offset_r;
    reg [4:0]  p16_res_block_idx;
    reg        cavlc_start_r;
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
    reg        dpb_rd_en_r;
    reg [31:0] dpb_rd_addr_r;
    reg        p16_wr_en_r;
    reg [31:0] p16_wr_addr_r;
    reg [7:0]  p16_wr_data_r;
    reg [7:0]  lat_recon_y [0:255];
    reg [7:0]  lat_recon_u [0:63];
    reg [7:0]  lat_recon_v [0:63];
    reg signed [15:0] lat_p16_residual_y [0:255];
    reg signed [15:0] lat_p16_residual_u [0:63];
    reg signed [15:0] lat_p16_residual_v [0:63];
    reg [7:0]  p16_luma_ref [0:80];
    reg [7:0]  p16_chroma_ref [0:3];
    reg        intra_active_r;
    reg [7:0]  intra_mb_x_r;
    reg [7:0]  intra_mb_y_r;
    reg        intra_mb_is_ref_r;
    reg        i16_nb_start_r;
    reg        intra_chroma_start_r;
    reg        i16_commit_r;
    reg        pskip_start_r;
    reg        wb_is_pskip_r;
    reg        wb_mv_is_inter_r;
    reg signed [15:0] pskip_mv_x_r;
    reg signed [15:0] pskip_mv_y_r;
    reg        mvcommit_valid_r;
    reg [7:0]  mvcommit_mb_x_r;
    reg        mvcommit_is_inter_r;
    reg [1:0]  mvcommit_ref_r;
    reg signed [15:0] mvcommit_mv_x_r;
    reg signed [15:0] mvcommit_mv_y_r;

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

    function automatic [15:0] clamp_coord(
        input signed [15:0] value,
        input [15:0] limit
    );
        reg signed [16:0] value17;
        reg signed [16:0] limit17;
        begin
            value17 = {value[15], value};
            limit17 = {1'b0, limit};
            if (value17 < 17'sd0)
                clamp_coord = 16'd0;
            else if (value17 >= limit17)
                clamp_coord = limit - 16'd1;
            else
                clamp_coord = value[15:0];
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
    wire [31:0] wb_addr;
    h264_dpb_mb_write_addr #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H)) u_product_wb_addr (
        .bank_base(wb_base),
        .mb_x(wb_mb_x),
        .mb_y(wb_mb_y),
        .plane(wb_plane),
        .sample_idx(wb_sample_idx),
        .addr(wb_addr)
    );

    wire [31:0] syntax_mb_addr32 = {16'd0, syntax_mb_addr_r};
    wire [31:0] syntax_mb_x32 = syntax_mb_addr32 % MB_W;
    wire [31:0] syntax_mb_y32 = syntax_mb_addr32 / MB_W;
    wire [7:0] syntax_mb_x = syntax_mb_x32[7:0];
    wire [7:0] syntax_mb_y = syntax_mb_y32[7:0];
    wire [MB_IDX_W-1:0] syntax_mb_idx = syntax_mb_x[MB_IDX_W-1:0];
    wire [MB_IDX_W-1:0] wb_mb_idx = wb_mb_x[MB_IDX_W-1:0];
    // ── P_Skip: mb_skip_run tracking ───────────────────────────────────────
    wire        skiprun_mb_is_skip;
    wire        skiprun_need_run;
    wire [15:0] skiprun_left;
    wire        skiprun_coded_pending;
    wire        skip_consume;
    h264_mb_skip_run_track u_product_skip_run (
        .clk(clk),
        .reset(reset),
        .slice_start(slice_start),
        .skip_run_valid(mb_skip_run_valid),
        .skip_run(mb_skip_run),
        .mb_consume(skip_consume),
        .mb_is_skip(skiprun_mb_is_skip),
        .need_skip_run(skiprun_need_run),
        .skip_run_left(skiprun_left),
        .coded_pending(skiprun_coded_pending)
    );
    wire slice_is_p = !slice_is_i && !slice_is_idr;
    wire pskip_pending = slice_is_p && skiprun_mb_is_skip;

    wire syntax_p16_candidate = mb_type_valid && !slice_is_i && !slice_is_idr &&
                                !pskip_pending &&
                                (mb_type == 5'd0) && (part_mode == 3'd0);
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

    // ── Macroblock type routing ────────────────────────────────────────────
    // Every macroblock is classified once here; the reconstruction engines
    // below are selected from `mb_route` instead of re-deriving mb_type
    // semantics at each site.
    localparam [2:0] ROUTE_OTHER   = 3'd0;
    localparam [2:0] ROUTE_INTRA4  = 3'd1;
    localparam [2:0] ROUTE_INTRA16 = 3'd2;
    localparam [2:0] ROUTE_PSKIP   = 3'd3;
    localparam [2:0] ROUTE_P16     = 3'd4;

    wire [2:0] mb_route;
    wire [1:0] mb_route_i16_mode;
    wire [1:0] mb_route_cbp_chroma;
    wire       mb_route_cbp_luma_ac;
    wire       mb_route_is_intra;
    wire       mb_route_is_inter;
    wire       mb_route_unsupported;
    h264_mb_recon_route u_product_mb_route (
        .slice_is_i(slice_is_i || slice_is_idr),
        .mb_is_skip(mb_skip),
        .mb_type({1'b0, mb_type}),
        .route(mb_route),
        .i16_pred_mode(mb_route_i16_mode),
        .cbp_chroma(mb_route_cbp_chroma),
        .cbp_luma_ac(mb_route_cbp_luma_ac),
        .is_intra(mb_route_is_intra),
        .is_inter(mb_route_is_inter),
        .unsupported(mb_route_unsupported)
    );
    // I_16x16 DC is the mode this core reconstructs standalone; V/H/Plane keep
    // going through h264_decode_top.
    wire route_is_i16_dc = (mb_route == ROUTE_INTRA16) && (mb_route_i16_mode == 2'd2);

    // ── P_Skip: MV derivation and MC copy ──────────────────────────────────
    wire        pskip_nb_a_present, pskip_nb_a_inter;
    wire [1:0]  pskip_nb_a_ref;
    wire signed [15:0] pskip_nb_a_mv_x, pskip_nb_a_mv_y;
    wire        pskip_nb_b_present, pskip_nb_b_inter;
    wire [1:0]  pskip_nb_b_ref;
    wire signed [15:0] pskip_nb_b_mv_x, pskip_nb_b_mv_y;
    wire        pskip_nb_c_present, pskip_nb_c_inter;
    wire [1:0]  pskip_nb_c_ref;
    wire signed [15:0] pskip_nb_c_mv_x, pskip_nb_c_mv_y;
    wire        pskip_nb_d_present, pskip_nb_d_inter;
    wire [1:0]  pskip_nb_d_ref;
    wire signed [15:0] pskip_nb_d_mv_x, pskip_nb_d_mv_y;
    h264_pskip_nb_ctx #(
        .MB_WIDTH_MAX(MB_W),
        .MB_WIDTH_DEFAULT(MB_W)
    ) u_product_pskip_nb_ctx (
        .clk(clk),
        .reset(reset),
        .mb_x(syntax_mb_x),
        .mb_y(syntax_mb_y),
        .mb_width(mb_width),
        .first_mb_in_slice(first_mb_in_slice),
        .mb_commit(mvcommit_valid_r),
        .commit_mb_x(mvcommit_mb_x_r),
        .commit_is_inter(mvcommit_is_inter_r),
        .commit_ref_idx(mvcommit_ref_r),
        .commit_mv_x(mvcommit_mv_x_r),
        .commit_mv_y(mvcommit_mv_y_r),
        .nb_a_present(pskip_nb_a_present), .nb_a_inter(pskip_nb_a_inter),
        .nb_a_ref(pskip_nb_a_ref), .nb_a_mv_x(pskip_nb_a_mv_x), .nb_a_mv_y(pskip_nb_a_mv_y),
        .nb_b_present(pskip_nb_b_present), .nb_b_inter(pskip_nb_b_inter),
        .nb_b_ref(pskip_nb_b_ref), .nb_b_mv_x(pskip_nb_b_mv_x), .nb_b_mv_y(pskip_nb_b_mv_y),
        .nb_c_present(pskip_nb_c_present), .nb_c_inter(pskip_nb_c_inter),
        .nb_c_ref(pskip_nb_c_ref), .nb_c_mv_x(pskip_nb_c_mv_x), .nb_c_mv_y(pskip_nb_c_mv_y),
        .nb_d_present(pskip_nb_d_present), .nb_d_inter(pskip_nb_d_inter),
        .nb_d_ref(pskip_nb_d_ref), .nb_d_mv_x(pskip_nb_d_mv_x), .nb_d_mv_y(pskip_nb_d_mv_y)
    );

    // P_L0_16x16 motion vector prediction, clause 8.4.1.3. The predictor is
    // shared with P_Skip so a P16x16 macroblock sees P_Skip neighbours (and
    // vice versa) -- with 79% of a P frame skipped, a predictor that only
    // tracked coded macroblocks would drift immediately.
    wire signed [15:0] p16_mvp_x;
    wire signed [15:0] p16_mvp_y;
    wire        p16_mvp_directional;
    h264_pskip_mv_pred u_product_p16_mvp (
        .ref_idx_l0(ref_idx_l0),
        .nb_a_present(pskip_nb_a_present), .nb_a_inter(pskip_nb_a_inter),
        .nb_a_ref(pskip_nb_a_ref), .nb_a_mv_x(pskip_nb_a_mv_x), .nb_a_mv_y(pskip_nb_a_mv_y),
        .nb_b_present(pskip_nb_b_present), .nb_b_inter(pskip_nb_b_inter),
        .nb_b_ref(pskip_nb_b_ref), .nb_b_mv_x(pskip_nb_b_mv_x), .nb_b_mv_y(pskip_nb_b_mv_y),
        .nb_c_present(pskip_nb_c_present), .nb_c_inter(pskip_nb_c_inter),
        .nb_c_ref(pskip_nb_c_ref), .nb_c_mv_x(pskip_nb_c_mv_x), .nb_c_mv_y(pskip_nb_c_mv_y),
        .nb_d_present(pskip_nb_d_present), .nb_d_inter(pskip_nb_d_inter),
        .nb_d_ref(pskip_nb_d_ref), .nb_d_mv_x(pskip_nb_d_mv_x), .nb_d_mv_y(pskip_nb_d_mv_y),
        .mvp_x(p16_mvp_x),
        .mvp_y(p16_mvp_y),
        .directional(p16_mvp_directional)
    );
    wire signed [15:0] p16_mv_from_mvd_x = p16_mvp_x + mvd_x_qpel;
    wire signed [15:0] p16_mv_from_mvd_y = p16_mvp_y + mvd_y_qpel;

    wire signed [15:0] pskip_mv_x;
    wire signed [15:0] pskip_mv_y;
    wire [1:0]  pskip_ref_idx_l0;
    wire signed [15:0] pskip_mvp_x;
    wire signed [15:0] pskip_mvp_y;
    wire        pskip_zero_mv;
    wire [3:0]  pskip_zero_reason;
    h264_pskip_mv u_product_pskip_mv (
        .nb_a_present(pskip_nb_a_present), .nb_a_inter(pskip_nb_a_inter),
        .nb_a_ref(pskip_nb_a_ref), .nb_a_mv_x(pskip_nb_a_mv_x), .nb_a_mv_y(pskip_nb_a_mv_y),
        .nb_b_present(pskip_nb_b_present), .nb_b_inter(pskip_nb_b_inter),
        .nb_b_ref(pskip_nb_b_ref), .nb_b_mv_x(pskip_nb_b_mv_x), .nb_b_mv_y(pskip_nb_b_mv_y),
        .nb_c_present(pskip_nb_c_present), .nb_c_inter(pskip_nb_c_inter),
        .nb_c_ref(pskip_nb_c_ref), .nb_c_mv_x(pskip_nb_c_mv_x), .nb_c_mv_y(pskip_nb_c_mv_y),
        .nb_d_present(pskip_nb_d_present), .nb_d_inter(pskip_nb_d_inter),
        .nb_d_ref(pskip_nb_d_ref), .nb_d_mv_x(pskip_nb_d_mv_x), .nb_d_mv_y(pskip_nb_d_mv_y),
        .mv_x(pskip_mv_x),
        .mv_y(pskip_mv_y),
        .ref_idx_l0(pskip_ref_idx_l0),
        .mvp_x(pskip_mvp_x),
        .mvp_y(pskip_mvp_y),
        .zero_mv(pskip_zero_mv),
        .zero_reason(pskip_zero_reason)
    );

    wire       pskip_pred_valid;
    wire [1:0] pskip_pred_plane;
    wire [7:0] pskip_pred_idx;
    wire [7:0] pskip_pred_sample;
    wire       pskip_busy;
    wire       pskip_done;
    h264_pskip_mc_copy u_product_pskip_mc (
        .clk(clk),
        .reset(reset || slice_start),
        .start(pskip_start_r),
        .mb_x(wb_mb_x),
        .mb_y(wb_mb_y),
        .mv_x_qpel(pskip_mv_x_r),
        .mv_y_qpel(pskip_mv_y_r),
        .frame_w(FRAME_W16),
        .frame_h(FRAME_H16),
        .ref_req_valid(ref_req_valid),
        .ref_req_plane(ref_req_plane),
        .ref_req_x(ref_req_x),
        .ref_req_y(ref_req_y),
        .ref_req_ready(ref_req_ready),
        .ref_rsp_valid(ref_rsp_valid),
        .ref_rsp_sample(ref_rsp_sample),
        .pred_valid(pskip_pred_valid),
        .pred_plane(pskip_pred_plane),
        .pred_idx(pskip_pred_idx),
        .pred_sample(pskip_pred_sample),
        .busy(pskip_busy),
        .done(pskip_done)
    );
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
    h264_cavlc_residual_block u_product_p16_residual0 (
        .clk(clk),
        .reset(reset || slice_start),
        .start(cavlc_start_r),
        .coeff_token_table(3'd0),
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
    wire [6:0] p16_luma_tap_col7 = p16_tap_idx % 7'd9;
    wire [6:0] p16_luma_tap_row7 = p16_tap_idx / 7'd9;
    wire signed [15:0] p16_luma_tap_col = $signed({9'd0, p16_luma_tap_col7}) - 16'sd4;
    wire signed [15:0] p16_luma_tap_row = $signed({9'd0, p16_luma_tap_row7}) - 16'sd4;
    wire [1:0] p16_chroma_tap_x = {1'b0, p16_tap_idx[0]};
    wire [1:0] p16_chroma_tap_y = {1'b0, p16_tap_idx[1]};

    wire [15:0] p16_luma_out_x = {4'd0, wb_mb_x, 4'd0} + {12'd0, wb_sample_idx[3:0]};
    wire [15:0] p16_luma_out_y = {4'd0, wb_mb_y, 4'd0} + {12'd0, wb_sample_idx[7:4]};
    wire [15:0] p16_chroma_out_x = {5'd0, wb_mb_x, 3'd0} + {13'd0, wb_sample_idx[2:0]};
    wire [15:0] p16_chroma_out_y = {5'd0, wb_mb_y, 3'd0} + {13'd0, wb_sample_idx[5:3]};
    wire signed [15:0] p16_luma_base_x = $signed({1'b0, p16_luma_out_x[14:0]}) + (p16_mv_x_qpel_r >>> 2);
    wire signed [15:0] p16_luma_base_y = $signed({1'b0, p16_luma_out_y[14:0]}) + (p16_mv_y_qpel_r >>> 2);
    wire signed [15:0] p16_chroma_base_x = $signed({1'b0, p16_chroma_out_x[14:0]}) + (p16_mv_x_qpel_r >>> 3);
    wire signed [15:0] p16_chroma_base_y = $signed({1'b0, p16_chroma_out_y[14:0]}) + (p16_mv_y_qpel_r >>> 3);
    wire [15:0] p16_ref_x = (wb_plane == 2'd0) ?
        clamp_coord(p16_luma_base_x + p16_luma_tap_col, FRAME_W16) :
        clamp_coord(p16_chroma_base_x + $signed({14'd0, p16_chroma_tap_x}), CHROMA_W16);
    wire [15:0] p16_ref_y = (wb_plane == 2'd0) ?
        clamp_coord(p16_luma_base_y + p16_luma_tap_row, FRAME_H16) :
        clamp_coord(p16_chroma_base_y + $signed({14'd0, p16_chroma_tap_y}), CHROMA_H16);
`ifdef H264_DECODE_CORE_FAULT_SWAP_CHROMA_READ
    wire [1:0] p16_rd_plane = (wb_plane == 2'd1) ? 2'd2 :
                              (wb_plane == 2'd2) ? 2'd1 : wb_plane;
`else
    wire [1:0] p16_rd_plane = wb_plane;
`endif
    wire [31:0] p16_rd_addr;
    h264_dpb_i420_addr #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H)) u_product_p16_rd_addr (
        .base(p16_ref_base_r),
        .plane(p16_rd_plane),
        .x(p16_ref_x),
        .y(p16_ref_y),
        .addr(p16_rd_addr)
    );

    wire [7:0] wb_data = (wb_plane == 2'd0) ? lat_recon_y[wb_sample_idx] :
                         (wb_plane == 2'd1) ? lat_recon_u[wb_sample_idx[5:0]] :
                                               lat_recon_v[wb_sample_idx[5:0]];
    wire signed [15:0] p16_residual_sample =
        (wb_plane == 2'd0) ? lat_p16_residual_y[wb_sample_idx] :
        (wb_plane == 2'd1) ? lat_p16_residual_u[wb_sample_idx[5:0]] :
                             lat_p16_residual_v[wb_sample_idx[5:0]];
    wire [7:0] p16_luma_pred_sample;
    h264_luma_qpel_sample u_product_p16_luma_pred (
        .ref_pix(p16_luma_ref),
        .frac_x(p16_mv_x_qpel_r[1:0]),
        .frac_y(p16_mv_y_qpel_r[1:0]),
        .sample(p16_luma_pred_sample)
    );
    wire [7:0] p16_chroma_pred_sample;
    h264_chroma_epel_sample u_product_p16_chroma_pred (
        .p00(p16_chroma_ref[0]),
        .p10(p16_chroma_ref[1]),
        .p01(p16_chroma_ref[2]),
        .p11(p16_chroma_ref[3]),
        .frac_x(p16_mv_x_qpel_r[2:0]),
        .frac_y(p16_mv_y_qpel_r[2:0]),
        .sample(p16_chroma_pred_sample)
    );
    wire [7:0] p16_pred_sample = (wb_plane == 2'd0) ? p16_luma_pred_sample : p16_chroma_pred_sample;
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
    wire        product_intra_mb_start = mb_type_valid && slice_is_i && !mb_skip &&
                                         !route_is_i16_dc;
    wire [7:0]  product_intra_mb_type = {3'd0, mb_type};
    wire [1:0]  product_intra_i16_mode = intra16x16_mode;
    wire signed [28:0] product_intra_i16_dc [0:15];
    wire [7:0]  product_intra_recon_y [0:255];
    wire [7:0]  product_intra_recon_u [0:63];
    wire [7:0]  product_intra_recon_v [0:63];
    wire        product_intra_recon_valid;
    wire [4:0]  product_intra_blocks_done;
    wire [7:0]  product_intra_ctx_recon_pixels [0:15];
    wire [7:0]  product_intra_ctx_above_unused [0:7];
    wire [7:0]  product_intra_ctx_left_unused [0:3];
    wire [7:0]  product_intra_ctx_top_left_unused;
    wire        product_intra_ctx_has_above_unused;
    wire        product_intra_ctx_has_left_unused;
    wire        product_intra_ctx_has_above_right_unused;
    wire [7:0]  product_intra_ctx_chroma_u_above [0:7];
    wire [7:0]  product_intra_ctx_chroma_v_above [0:7];
    wire [7:0]  product_intra_ctx_chroma_u_left [0:7];
    wire [7:0]  product_intra_ctx_chroma_v_left [0:7];
    wire [7:0]  product_intra_ctx_chroma_u_top_left_unused;
    wire [7:0]  product_intra_ctx_chroma_v_top_left_unused;
    wire        product_intra_ctx_has_chroma_above;
    wire        product_intra_ctx_has_chroma_left;
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
    endgenerate

    // ── Intra_16x16 / chroma DC prediction (pre-deblock neighbour taps) ─────
    // h264_intra_nb_ctx holds reconstructed samples BEFORE the deblocking
    // filter, which is exactly what clause 8.3 requires for intra prediction.
    // The deblocked copy lives in the DPB and feeds motion compensation only.
    wire        i16dc_valid;
    wire [7:0]  i16dc_value;
    wire [7:0]  i16dc_pred [0:255];
    h264_intra16_dc u_product_i16_dc (
        .clk(clk),
        .reset(reset || slice_start),
        .start(i16_nb_start_r),
        .above(product_intra_nb_top),
        .left(product_intra_nb_left),
        .has_above(product_intra_mb_avail_top),
        .has_left(product_intra_mb_avail_left),
        .valid(i16dc_valid),
        .dc_value(i16dc_value),
        .pred(i16dc_pred)
    );

    // Chroma DC runs for every intra macroblock, whichever luma engine owns it,
    // so the previously hard-wired 128 chroma plane is replaced by the real
    // clause 8.3.4.1 prediction. The registered `pred` output holds between
    // start pulses, so h264_decode_top's multi-cycle luma walk still sees a
    // stable chroma macroblock when it finally asserts mb_recon_valid.
    wire        chroma_u_dc_valid;
    wire        chroma_v_dc_valid;
    wire [7:0]  chroma_u_dc_tl, chroma_u_dc_tr, chroma_u_dc_bl, chroma_u_dc_br;
    wire [7:0]  chroma_v_dc_tl, chroma_v_dc_tr, chroma_v_dc_bl, chroma_v_dc_br;
    h264_chroma8_dc u_product_chroma_u_dc (
        .clk(clk),
        .reset(reset || slice_start),
        .start(intra_chroma_start_r),
        .above(product_intra_ctx_chroma_u_above),
        .left(product_intra_ctx_chroma_u_left),
        .has_above(product_intra_ctx_has_chroma_above),
        .has_left(product_intra_ctx_has_chroma_left),
        .valid(chroma_u_dc_valid),
        .dc_tl(chroma_u_dc_tl),
        .dc_tr(chroma_u_dc_tr),
        .dc_bl(chroma_u_dc_bl),
        .dc_br(chroma_u_dc_br),
        .pred(product_intra_recon_u)
    );
    h264_chroma8_dc u_product_chroma_v_dc (
        .clk(clk),
        .reset(reset || slice_start),
        .start(intra_chroma_start_r),
        .above(product_intra_ctx_chroma_v_above),
        .left(product_intra_ctx_chroma_v_left),
        .has_above(product_intra_ctx_has_chroma_above),
        .has_left(product_intra_ctx_has_chroma_left),
        .valid(chroma_v_dc_valid),
        .dc_tl(chroma_v_dc_tl),
        .dc_tr(chroma_v_dc_tr),
        .dc_bl(chroma_v_dc_bl),
        .dc_br(chroma_v_dc_br),
        .pred(product_intra_recon_v)
    );

    // The neighbour context is fed from whichever engine reconstructed the MB.
    wire [7:0] nbctx_recon_y [0:255];
    wire [7:0] nbctx_recon_u [0:63];
    wire [7:0] nbctx_recon_v [0:63];
    genvar nbctx_gi;
    generate
        for (nbctx_gi = 0; nbctx_gi < 256; nbctx_gi = nbctx_gi + 1) begin : g_nbctx_y
            assign nbctx_recon_y[nbctx_gi] = i16_commit_r ? lat_recon_y[nbctx_gi]
                                                          : product_intra_recon_y[nbctx_gi];
        end
        for (nbctx_gi = 0; nbctx_gi < 64; nbctx_gi = nbctx_gi + 1) begin : g_nbctx_c
            assign nbctx_recon_u[nbctx_gi] = product_intra_recon_u[nbctx_gi];
            assign nbctx_recon_v[nbctx_gi] = product_intra_recon_v[nbctx_gi];
        end
    endgenerate

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
        .mb_start(product_intra_mb_start || i16_nb_start_r),
        .block_idx(luma4x4_idx),
        .block_valid(1'b0),
        .recon_pixels(product_intra_ctx_recon_pixels),
        .mb_commit(product_intra_recon_valid || i16_commit_r),
        .recon_y_mb(nbctx_recon_y),
        .recon_u_mb(nbctx_recon_u),
        .recon_v_mb(nbctx_recon_v),
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
        .chroma_u_above(product_intra_ctx_chroma_u_above),
        .chroma_v_above(product_intra_ctx_chroma_v_above),
        .chroma_u_left(product_intra_ctx_chroma_u_left),
        .chroma_v_left(product_intra_ctx_chroma_v_left),
        .chroma_u_top_left(product_intra_ctx_chroma_u_top_left_unused),
        .chroma_v_top_left(product_intra_ctx_chroma_v_top_left_unused),
        .has_chroma_above(product_intra_ctx_has_chroma_above),
        .has_chroma_left(product_intra_ctx_has_chroma_left)
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
    // Standalone I_16x16 DC launch. Deliberately gated on the writeback engine
    // being free so intra_mb_x_r cannot move while h264_intra_nb_ctx is still
    // flushing the previous macroblock into its line buffers.
    wire i16_dc_launch = mb_type_valid && route_is_i16_dc && (wb_state == ST_IDLE) &&
                         !pskip_pending && !p16_launch && !product_recon_mb_valid;
    // Skipped macroblocks carry no syntax of their own, so the core issues them
    // itself while the run is draining. mb_skip_run has already been parsed by
    // the time the run is non-zero, and the coded macroblock that terminates
    // the run arrives afterwards as a normal mb_type_valid pulse.
    wire pskip_launch = pskip_pending && (wb_state == ST_IDLE) &&
                        !p16_launch && !product_recon_mb_valid && !pskip_busy;
    assign skip_consume = pskip_launch || (mb_type_valid && !pskip_pending);
    wire [7:0] product_recon_mb_x = product_intra_recon_valid ? intra_mb_x_r : recon_mb_x;
    wire [7:0] product_recon_mb_y = product_intra_recon_valid ? intra_mb_y_r : recon_mb_y;
    wire product_recon_mb_is_ref = product_intra_recon_valid ? intra_mb_is_ref_r : recon_mb_is_ref;
`ifdef H264_DECODE_CORE_FAULT_DROP_WB
    wire product_wb_en = 1'b0;
`else
    wire product_wb_en = (wb_state == ST_WRITE);
`endif

    integer wb_i;
    always @(posedge clk) begin
        frame_done_r <= 1'b0;
        dpb_rd_en_r <= 1'b0;
        p16_wr_en_r <= 1'b0;
        rbsp_request_valid_r <= 1'b0;
        cavlc_start_r <= 1'b0;
        i16_nb_start_r <= 1'b0;
        intra_chroma_start_r <= 1'b0;
        i16_commit_r <= 1'b0;
        pskip_start_r <= 1'b0;
        mvcommit_valid_r <= 1'b0;
        if (reset || slice_start) begin
            wb_state <= ST_IDLE;
            wb_idx <= 9'd0;
            wb_mb_x <= 8'd0;
            wb_mb_y <= 8'd0;
            wb_mb_is_ref <= 1'b0;
            wb_base <= 32'd0;
            p16_ref_base_r <= 32'd0;
            p16_mv_x_qpel_r <= 16'sd0;
            p16_mv_y_qpel_r <= 16'sd0;
            p16_ref_idx_l0_r <= 2'd0;
            p16_tap_idx <= 7'd0;
            p16_res_bit_offset_r <= 10'd0;
            p16_res_block_idx <= 5'd0;
            cavlc_start_r <= 1'b0;
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
            i16_nb_start_r <= 1'b0;
            intra_chroma_start_r <= 1'b0;
            i16_commit_r <= 1'b0;
            pskip_start_r <= 1'b0;
            wb_is_pskip_r <= 1'b0;
            wb_mv_is_inter_r <= 1'b0;
            pskip_mv_x_r <= 16'sd0;
            pskip_mv_y_r <= 16'sd0;
            mvcommit_valid_r <= 1'b0;
            mvcommit_mb_x_r <= 8'd0;
            mvcommit_is_inter_r <= 1'b0;
            mvcommit_ref_r <= 2'd0;
            mvcommit_mv_x_r <= 16'sd0;
            mvcommit_mv_y_r <= 16'sd0;
            mb_count_r <= 16'd0;
            frame_done_r <= 1'b0;
            dpb_rd_en_r <= 1'b0;
            dpb_rd_addr_r <= 32'd0;
            p16_wr_en_r <= 1'b0;
            p16_wr_addr_r <= 32'd0;
            p16_wr_data_r <= 8'd0;
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
            for (wb_i = 0; wb_i < 81; wb_i = wb_i + 1)
                p16_luma_ref[wb_i] <= 8'd0;
            for (wb_i = 0; wb_i < 4; wb_i = wb_i + 1)
                p16_chroma_ref[wb_i] <= 8'd0;
            for (wb_i = 0; wb_i < MB_W; wb_i = wb_i + 1) begin
                mv_top_x[wb_i] <= 16'sd0;
                mv_top_y[wb_i] <= 16'sd0;
                mv_top_ref[wb_i] <= 2'd0;
                mv_top_valid[wb_i] <= 1'b0;
            end
        end else begin
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
            if (pskip_launch)
                syntax_mb_addr_r <= syntax_mb_addr_r + 16'd1;            if (product_intra_mb_start || i16_dc_launch) begin
                intra_active_r <= 1'b1;
                intra_mb_x_r <= syntax_mb_x;
                intra_mb_y_r <= syntax_mb_y;
                intra_mb_is_ref_r <= 1'b1;
            end
            // One-cycle delay so the neighbour taps have settled on the new
            // macroblock position before the DC engines sample them.
            i16_nb_start_r <= i16_dc_launch;
            intra_chroma_start_r <= product_intra_mb_start || i16_dc_launch;
            if (product_intra_recon_valid)
                intra_active_r <= 1'b0;

            case (wb_state)
            ST_IDLE: begin
                if (p16_launch) begin
                    wb_mb_x <= p16_launch_mb_x;
                    wb_mb_y <= p16_launch_mb_y;
                    wb_mb_is_ref <= p16_launch_is_ref;
                    wb_base <= dpb_write_base;
                    p16_ref_base_r <= dpb_ref_base;
`ifdef H264_DECODE_CORE_FAULT_PERTURB_MV
                    p16_mv_x_qpel_r <= (p16_zero_mv_valid ? mv_x_qpel : p16_mv_from_mvd_x) + 16'sd2;
`else
                    p16_mv_x_qpel_r <= p16_zero_mv_valid ? mv_x_qpel : p16_mv_from_mvd_x;
`endif
                    p16_mv_y_qpel_r <= p16_zero_mv_valid ? mv_y_qpel : p16_mv_from_mvd_y;
                    p16_ref_idx_l0_r <= ref_idx_l0;
                    p16_res_bit_offset_r <= launch_residual_rel_bit_offset[9:0];
                    p16_res_block_idx <= 5'd0;
                    wb_idx <= 9'd0;
                    p16_tap_idx <= 7'd0;
                    for (wb_i = 0; wb_i < 256; wb_i = wb_i + 1)
                        lat_p16_residual_y[wb_i] <= p16_zero_mv_valid ? p16_residual_y[wb_i] : 16'sd0;
                    for (wb_i = 0; wb_i < 64; wb_i = wb_i + 1) begin
                        lat_p16_residual_u[wb_i] <= p16_zero_mv_valid ? p16_residual_u[wb_i] : 16'sd0;
                        lat_p16_residual_v[wb_i] <= p16_zero_mv_valid ? p16_residual_v[wb_i] : 16'sd0;
                    end
                    wb_state <= p16_zero_mv_valid ? ST_P16_TAP_REQ : ST_P16_RES_START;
                    wb_is_pskip_r <= 1'b0;
                    wb_mv_is_inter_r <= 1'b1;
                end else if (product_recon_mb_valid) begin
                    wb_mb_x <= product_recon_mb_x;
                    wb_mb_y <= product_recon_mb_y;
                    wb_mb_is_ref <= product_recon_mb_is_ref;
                    wb_base <= dpb_write_base;
                    wb_idx <= 9'd0;
                    for (wb_i = 0; wb_i < 256; wb_i = wb_i + 1)
                        lat_recon_y[wb_i] <= product_intra_recon_valid ? product_intra_recon_y[wb_i] : recon_y[wb_i];
                    for (wb_i = 0; wb_i < 64; wb_i = wb_i + 1) begin
                        lat_recon_u[wb_i] <= product_intra_recon_valid ? product_intra_recon_u[wb_i] : recon_u[wb_i];
                        lat_recon_v[wb_i] <= product_intra_recon_valid ? product_intra_recon_v[wb_i] : recon_v[wb_i];
                    end
                    wb_state <= ST_WRITE;
                    wb_is_pskip_r <= 1'b0;
                    wb_mv_is_inter_r <= 1'b0;
                end else if (i16_dc_launch) begin
                    wb_mb_x <= syntax_mb_x;
                    wb_mb_y <= syntax_mb_y;
                    wb_mb_is_ref <= 1'b1;
                    wb_base <= dpb_write_base;
                    wb_idx <= 9'd0;
                    wb_is_pskip_r <= 1'b0;
                    wb_mv_is_inter_r <= 1'b0;
                    wb_state <= ST_I16_WAIT;
                end else if (pskip_launch) begin
                    wb_mb_x <= syntax_mb_x;
                    wb_mb_y <= syntax_mb_y;
                    wb_mb_is_ref <= 1'b1;
                    wb_base <= dpb_write_base;
                    wb_idx <= 9'd0;
                    wb_is_pskip_r <= 1'b1;
                    wb_mv_is_inter_r <= 1'b1;
                    // Clause 8.4.1.1: the neighbour taps are read at the
                    // current macroblock position, so the derived MV must be
                    // captured before syntax_mb_addr_r advances.
                    pskip_mv_x_r <= pskip_mv_x;
                    pskip_mv_y_r <= pskip_mv_y;
                    pskip_start_r <= 1'b1;
                    wb_state <= ST_PSKIP_WAIT;
                end
            end
            ST_PSKIP_WAIT: begin
                // P_Skip has no residual and no transform: the macroblock is
                // the motion compensated prediction verbatim.
                if (pskip_pred_valid) begin
                    if (pskip_pred_plane == 2'd0)
                        lat_recon_y[pskip_pred_idx] <= pskip_pred_sample;
                    else if (pskip_pred_plane == 2'd1)
                        lat_recon_u[pskip_pred_idx[5:0]] <= pskip_pred_sample;
                    else
                        lat_recon_v[pskip_pred_idx[5:0]] <= pskip_pred_sample;
                end
                if (pskip_done) begin
                    wb_idx <= 9'd0;
                    wb_state <= ST_WRITE;
                end
            end
            ST_I16_WAIT: begin
                if (i16dc_valid) begin
                    for (wb_i = 0; wb_i < 256; wb_i = wb_i + 1)
                        lat_recon_y[wb_i] <= i16dc_pred[wb_i];
                    for (wb_i = 0; wb_i < 64; wb_i = wb_i + 1) begin
                        lat_recon_u[wb_i] <= product_intra_recon_u[wb_i];
                        lat_recon_v[wb_i] <= product_intra_recon_v[wb_i];
                    end
                    wb_state <= ST_I16_COMMIT;
                end
            end
            ST_I16_COMMIT: begin
                // Publish the PRE-deblock samples back into the intra
                // neighbour context before the macroblock is written out.
                i16_commit_r <= 1'b1;
                intra_active_r <= 1'b0;
                wb_state <= ST_I16_FLUSH;
            end
            ST_I16_FLUSH: begin
                // Hold intra_mb_x_r stable for the cycle in which
                // h264_intra_nb_ctx drains commit_pending into its line buffer.
                wb_idx <= 9'd0;
                wb_state <= ST_WRITE;
            end
            ST_P16_RES_START: begin
                cavlc_start_r <= 1'b1;
                wb_state <= ST_P16_RES_WAIT;
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
                    if (p16_res_block_idx == (P16_RES_BLOCKS - 5'd1)) begin
                        wb_state <= ST_P16_TAP_REQ;
                    end else begin
                        p16_res_block_idx <= p16_res_block_idx + 5'd1;
                        p16_res_bit_offset_r <= cavlc_bit_offset_end;
                        wb_state <= ST_P16_RES_START;
                    end
                end
            end
            ST_P16_TAP_REQ: begin
                dpb_rd_en_r <= 1'b1;
                dpb_rd_addr_r <= p16_rd_addr;
                wb_state <= ST_P16_TAP_WAIT;
            end
            ST_P16_TAP_WAIT: begin
                if (dpb_rd_valid) begin
                    if (wb_plane == 2'd0)
                        p16_luma_ref[p16_tap_idx] <= dpb_rd_data;
                    else
                        p16_chroma_ref[p16_tap_idx[1:0]] <= dpb_rd_data;

                    if ((wb_plane == 2'd0 && p16_tap_idx == 7'd80) ||
                        (wb_plane != 2'd0 && p16_tap_idx == 7'd3)) begin
                        p16_tap_idx <= 7'd0;
                        wb_state <= ST_P16_WRITE;
                    end else begin
                        p16_tap_idx <= p16_tap_idx + 7'd1;
                        wb_state <= ST_P16_TAP_REQ;
                    end
                end
            end
            ST_P16_WRITE: begin
                p16_wr_en_r <= 1'b1;
                p16_wr_addr_r <= wb_addr;
                p16_wr_data_r <= clip_u8(p16_recon_sum);
                if (wb_last_sample) begin
                    wb_state <= ST_IDLE;
                    if (wb_mb_is_ref) begin
                        mb_count_r <= mb_count_r + 16'd1;
                        mv_top_x[wb_mb_idx] <= p16_mv_x_qpel_r;
                        mv_top_y[wb_mb_idx] <= p16_mv_y_qpel_r;
                        mv_top_ref[wb_mb_idx] <= p16_ref_idx_l0_r;
                        mv_top_valid[wb_mb_idx] <= 1'b1;
                        mv_left_x <= p16_mv_x_qpel_r;
                        mv_left_y <= p16_mv_y_qpel_r;
                        mv_left_ref <= p16_ref_idx_l0_r;
                        mv_left_valid <= 1'b1;
                    end
                    mvcommit_valid_r <= 1'b1;
                    mvcommit_mb_x_r <= wb_mb_x;
                    mvcommit_is_inter_r <= 1'b1;
                    mvcommit_ref_r <= p16_ref_idx_l0_r;
                    mvcommit_mv_x_r <= p16_mv_x_qpel_r;
                    mvcommit_mv_y_r <= p16_mv_y_qpel_r;
                    frame_done_r <= wb_mb_is_ref && wb_last_mb;
                end else begin
                    wb_idx <= wb_idx + 9'd1;
                    wb_state <= ST_P16_TAP_REQ;
                end
            end
            ST_WRITE: begin
                if (wb_last_sample) begin
                    wb_state <= ST_IDLE;
                    if (wb_mb_is_ref)
                        mb_count_r <= mb_count_r + 16'd1;
                    // Publish this macroblock's L0 motion so the next P_Skip
                    // derivation sees it as neighbour A/B/C/D. Intra
                    // macroblocks must still be committed (is_inter = 0) so
                    // their refIdx reads back as "not 0" in the special cases.
                    mvcommit_valid_r <= 1'b1;
                    mvcommit_mb_x_r <= wb_mb_x;
                    mvcommit_is_inter_r <= wb_mv_is_inter_r;
                    mvcommit_ref_r <= 2'd0;
                    mvcommit_mv_x_r <= wb_is_pskip_r ? pskip_mv_x_r : 16'sd0;
                    mvcommit_mv_y_r <= wb_is_pskip_r ? pskip_mv_y_r : 16'sd0;
                    frame_done_r <= wb_mb_is_ref && wb_last_mb;
                end else begin
                    wb_idx <= wb_idx + 9'd1;
                end
            end
            default: begin
                wb_state <= ST_IDLE;
            end
            endcase
        end
    end

    assign dpb_wr_en = product_wb_en | p16_wr_en_r;
    assign dpb_wr_addr = p16_wr_en_r ? p16_wr_addr_r : wb_addr;
    assign dpb_wr_data = p16_wr_en_r ? p16_wr_data_r : wb_data;
    assign dpb_rd_en = dpb_rd_en_r;
    assign dpb_rd_addr = dpb_rd_addr_r;
    assign rbsp_request_offset = rbsp_request_offset_r;
    assign rbsp_request_valid = rbsp_request_valid_r;
    assign frame_done = frame_done_r;
    assign frame_mb_count = mb_count_r;
    assign busy = (wb_state != ST_IDLE) || intra_active_r || pskip_busy;
    assign decode_state = wb_state;
    assign current_mb_addr = (wb_state == ST_IDLE) ? syntax_mb_addr_r : wb_mb_addr16;
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
        |mb_route | |mb_route_cbp_chroma | mb_route_cbp_luma_ac |
        mb_route_is_intra | mb_route_is_inter | mb_route_unsupported |
        |i16dc_value | chroma_u_dc_valid | chroma_v_dc_valid |
        |chroma_u_dc_tl | |chroma_u_dc_tr | |chroma_u_dc_bl | |chroma_u_dc_br |
        |chroma_v_dc_tl | |chroma_v_dc_tr | |chroma_v_dc_bl | |chroma_v_dc_br |
        skiprun_need_run | |skiprun_left | skiprun_coded_pending |
        |pskip_ref_idx_l0 | |pskip_mvp_x | |pskip_mvp_y | pskip_zero_mv |
        |pskip_zero_reason | |syntax_mv_x | |syntax_mv_y | p16_mvp_directional;

endmodule
