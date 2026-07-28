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
    parameter int MB_COUNT  = MB_W * MB_H,
    // In-loop deblocking.  0 keeps the pre-deblock writeback behaviour that the
    // existing core writeback/p16z/real-slice gates were captured against; the
    // product instantiation in stream_path.sv sets 1.  The filter is always
    // elaborated -- only the DPB data selection and the extra writeback states
    // are parameterised -- so this is a feature flag, never a painter switch.
    parameter bit DEBLOCK_IN_LOOP = 1'b0
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

    // -- Slice deblocking filter control (from slice_hdr_parser) --
    input  wire [1:0]        slice_disable_deblocking_filter_idc,
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
    //   IN:  coeff signed [8:0] [0:15], qp[5:0], max_coeff[4:0]
    //   OUT: dequant signed [17:0] [0:15]
    //   CONTRACT: Combinational. Width: 29 bits internal (sat to 18 out).
    //
    // h264_idct4x4 (w-cabac):
    //   IN:  dequant signed [17:0] [0:15]
    //   OUT: residual signed [17:0] [0:15]
    //   CONTRACT: Combinational. Butterfly + shift.
    //
    // h264_recon4x4 (w-cabac):
    //   IN:  pred[7:0] [0:15], residual signed [17:0] [0:15]
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
    localparam [7:0] ST_COMMIT        = 8'd7;
    localparam [7:0] ST_FRAME_BOUNDARY = 8'd8;
    localparam [7:0] ST_DB_LOAD        = 8'd9;
    localparam [7:0] ST_DB_RUN         = 8'd10;
    localparam [7:0] ST_DB_STORE       = 8'd11;
    localparam [4:0] P16_LUMA_RES_BLOCKS = 5'd16;
    localparam [4:0] P16_CHROMA_RES_BLOCKS = 5'd8;
    localparam [4:0] P16_RES_BLOCKS = P16_LUMA_RES_BLOCKS + P16_CHROMA_RES_BLOCKS;
    localparam [15:0] FRAME_W16 = 16'(FRAME_W);
    localparam [15:0] FRAME_H16 = 16'(FRAME_H);
    localparam [15:0] CHROMA_W16 = 16'(FRAME_W / 2);
    localparam [15:0] CHROMA_H16 = 16'(FRAME_H / 2);
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
    reg        wb_commit_p16;
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
    wire syntax_p16_candidate = mb_type_valid && !slice_is_i && !slice_is_idr &&
                                (mb_skip || (mb_type == 5'd0)) &&
                                (mb_skip || (part_mode == 3'd0));
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

    // ==================================================================
    // In-loop deblocking filter (W-DEBLOCK-O5)
    // ------------------------------------------------------------------
    // The reconstructed macroblock is filtered before it reaches the DPB.
    // The filter needs a 4-sample skirt on the left and top edges because
    // clause 8.7 rewrites p2/p1/p0 on the neighbour side of a macroblock
    // edge, so the core keeps:
    //   * left context in registers (last filtered MB of this row)
    //   * top  context in a per-MB-column line buffer, staged in and out
    //     one byte per cycle so it infers a RAM instead of a register file.
    // Scope note (do not overstate): the current-macroblock portion of the
    // filtered neighbourhood is what gets committed to the DPB.  Rewriting
    // the skirt of already-committed neighbour macroblocks needs a one-MB
    // commit delay and is OPEN.  The normatively complete filter behaviour
    // is proven at 1170/1170 real P-frame macroblocks by
    // tests/unit/test_h264_deblock_mb_full_frame.sh.
    // ==================================================================
    localparam int DB_TOP_Y_WORDS = MB_W * 64;
    localparam int DB_TOP_C_WORDS = MB_W * 32;

    reg [7:0] db_top_y [0:DB_TOP_Y_WORDS-1];
    reg [7:0] db_top_u [0:DB_TOP_C_WORDS-1];
    reg [7:0] db_top_v [0:DB_TOP_C_WORDS-1];
    reg [7:0] db_topbuf_y [0:63];
    reg [7:0] db_topbuf_u [0:31];
    reg [7:0] db_topbuf_v [0:31];
    reg [7:0] db_left_y [0:63];
    reg [7:0] db_left_u [0:31];
    reg [7:0] db_left_v [0:31];
    reg [6:0] db_seq_idx;
    reg       db_start_r;

    // Per-macroblock coding context needed for the bS derivation.  QPy tracks
    // the normative running slice QP; the per-4x4 coded-block mask is derived
    // from cbp_luma at 8x8 granularity (an over-approximation that can raise
    // bS from 1 to 2 but never lowers it) because the core does not expose a
    // per-4x4 mask yet.
    reg        db_syn_intra;
    reg [5:0]  db_syn_qp;
    reg [15:0] db_syn_nz;
    reg signed [11:0] db_syn_mvx;
    reg signed [11:0] db_syn_mvy;
    reg [1:0]  db_syn_ref;
    reg [5:0]  db_qp_run;

    // Syntax context as of this cycle.  mb_type_valid may land on the same
    // cycle as recon_mb_valid, so the capture below has to see the combinational
    // value, not last macroblock's registered copy.
    // QPy accumulation per clause 7.4.5:
    //   QPy = ((QPy_prev + mb_qp_delta + 52) % 52)   for 8-bit (QpBdOffsetY = 0)
    // The +52 bias is not optional and the sum must not be evaluated in 6 bits.
    // The previous form added a two's-complement mb_qp_delta into a 6-bit
    // unsigned accumulator, so a negative delta wrapped mod 64 before the mod 52
    // ever ran: 442 of the 2704 (QPy_prev, delta) pairs came out wrong, every one
    // of them a negative delta.  w-cast measured the same bug class from the
    // parser side and reports QPy_range=3..33 for the real 624x480 P frame.
    // Sum range is [0-26+52, 51+25+52] = [26, 128], so 8 bits suffice and two
    // conditional subtractions replace the modulo -- exact, and cheaper than the
    // divider the `%` was inferring.
    wire [7:0] db_qp_biased = {2'd0, db_qp_run} + {{2{mb_qp_delta[5]}}, mb_qp_delta} + 8'd52;
`ifdef H264_DECODE_CORE_FAULT_QP_WRAP_LINEAR
    // Red proof: restore the 6-bit wrapping form this replaced.
    wire [5:0] db_qp_next = (db_qp_run + {{1{mb_qp_delta[5]}}, mb_qp_delta[4:0]}) % 6'd52;
`else
    wire [7:0] db_qp_sub1 = (db_qp_biased >= 8'd104) ? (db_qp_biased - 8'd104) : db_qp_biased;
    wire [7:0] db_qp_sub2 = (db_qp_sub1   >= 8'd52)  ? (db_qp_sub1   - 8'd52)  : db_qp_sub1;
    wire [5:0] db_qp_next = db_qp_sub2[5:0];
`endif
    wire       db_syn_intra_now = mb_type_valid ? (slice_is_i || (!mb_skip && (mb_type >= 5'd5)))
                                                : db_syn_intra;
    wire [5:0] db_syn_qp_now    = mb_type_valid ? db_qp_next : db_syn_qp;
    wire [15:0] db_syn_nz_now   = mb_type_valid ? {{4{cbp_luma[3]}}, {4{cbp_luma[2]}},
                                                  {4{cbp_luma[1]}}, {4{cbp_luma[0]}}}
                                                : db_syn_nz;
    wire signed [11:0] db_syn_mvx_now = mb_type_valid ? mv_x_qpel[11:0] : db_syn_mvx;
    wire signed [11:0] db_syn_mvy_now = mb_type_valid ? mv_y_qpel[11:0] : db_syn_mvy;
    wire [1:0] db_syn_ref_now   = mb_type_valid ? ref_idx_l0 : db_syn_ref;

    reg        db_cur_intra;
    reg [5:0]  db_cur_qp;
    reg [15:0] db_cur_nz;
    reg signed [11:0] db_cur_mvx;
    reg signed [11:0] db_cur_mvy;
    reg [1:0]  db_cur_ref;

    reg        db_left_intra;
    reg [5:0]  db_left_qp;
    reg [15:0] db_left_nz;
    reg signed [11:0] db_left_mvx;
    reg signed [11:0] db_left_mvy;
    reg [1:0]  db_left_ref;
    reg        db_left_avail;

    reg        db_top_intra [0:MB_W-1];
    reg [5:0]  db_top_qp    [0:MB_W-1];
    reg [15:0] db_top_nz    [0:MB_W-1];
    reg signed [11:0] db_top_mvx [0:MB_W-1];
    reg signed [11:0] db_top_mvy [0:MB_W-1];
    reg [1:0]  db_top_ref   [0:MB_W-1];
    reg        db_top_avail [0:MB_W-1];

    wire [MB_IDX_W-1:0] db_mb_col = wb_mb_x[MB_IDX_W-1:0];
    wire [31:0] db_top_y_base = {{(32-MB_IDX_W){1'b0}}, db_mb_col} * 32'd64;
    wire [31:0] db_top_c_base = {{(32-MB_IDX_W){1'b0}}, db_mb_col} * 32'd32;

    wire [7:0] db_nb_y_i [0:399];
    wire [7:0] db_nb_u_i [0:143];
    wire [7:0] db_nb_v_i [0:143];
    wire [7:0] db_nb_y_o [0:399];
    wire [7:0] db_nb_u_o [0:143];
    wire [7:0] db_nb_v_o [0:143];

    genvar dbr, dbc;
    generate
        for (dbr = 0; dbr < 20; dbr = dbr + 1) begin : g_db_nb_y_row
            for (dbc = 0; dbc < 20; dbc = dbc + 1) begin : g_db_nb_y_col
                if (dbr < 4 && dbc < 4)
                    assign db_nb_y_i[dbr*20 + dbc] = 8'd128; // corner is never a tap
                else if (dbr < 4)
                    assign db_nb_y_i[dbr*20 + dbc] = db_topbuf_y[dbr*16 + (dbc-4)];
                else if (dbc < 4)
                    assign db_nb_y_i[dbr*20 + dbc] = db_left_y[(dbr-4)*4 + dbc];
                else
                    assign db_nb_y_i[dbr*20 + dbc] = lat_recon_y[(dbr-4)*16 + (dbc-4)];
            end
        end
        for (dbr = 0; dbr < 12; dbr = dbr + 1) begin : g_db_nb_c_row
            for (dbc = 0; dbc < 12; dbc = dbc + 1) begin : g_db_nb_c_col
                if (dbr < 4 && dbc < 4) begin : g_db_c_corner
                    assign db_nb_u_i[dbr*12 + dbc] = 8'd128;
                    assign db_nb_v_i[dbr*12 + dbc] = 8'd128;
                end else if (dbr < 4) begin : g_db_c_top
                    assign db_nb_u_i[dbr*12 + dbc] = db_topbuf_u[dbr*8 + (dbc-4)];
                    assign db_nb_v_i[dbr*12 + dbc] = db_topbuf_v[dbr*8 + (dbc-4)];
                end else if (dbc < 4) begin : g_db_c_left
                    assign db_nb_u_i[dbr*12 + dbc] = db_left_u[(dbr-4)*4 + dbc];
                    assign db_nb_v_i[dbr*12 + dbc] = db_left_v[(dbr-4)*4 + dbc];
                end else begin : g_db_c_cur
                    assign db_nb_u_i[dbr*12 + dbc] = lat_recon_u[(dbr-4)*8 + (dbc-4)];
                    assign db_nb_v_i[dbr*12 + dbc] = lat_recon_v[(dbr-4)*8 + (dbc-4)];
                end
            end
        end
    endgenerate

    wire db_busy;
    wire db_done;
    wire [15:0] db_luma_modified;
    wire [15:0] db_chroma_modified;
    wire [15:0] db_edge_segments;
    wire [15:0] db_bs4_segments;
    wire [5:0]  db_last_chroma_qp;
    wire        db_pipe_error;
    wire        db_unsupported_ref;

    h264_deblock_mb_filter u_core_deblock_mb (
        .clk(clk),
        .reset(reset),
        .start(db_start_r),
        .busy(db_busy),
        .done(db_done),
        .disable_deblocking_filter_idc(slice_disable_deblocking_filter_idc),
        .slice_alpha_c0_offset(slice_alpha_c0_offset),
        .slice_beta_offset(slice_beta_offset),
        .chroma_qp_index_offset(pps_chroma_qp_index_offset),
        .left_mb_avail(db_left_avail),
        .top_mb_avail(db_top_avail[db_mb_col]),
        .left_mb_other_slice(1'b0),
        .top_mb_other_slice(1'b0),
        .cur_intra(db_cur_intra),
        .cur_qp_y(db_cur_qp),
        .cur_nz(db_cur_nz),
        .cur_mvx({16{db_cur_mvx}}),
        .cur_mvy({16{db_cur_mvy}}),
        .cur_ref({16{db_cur_ref}}),
        .left_intra(db_left_intra),
        .left_qp_y(db_left_qp),
        .left_nz(db_left_nz),
        .left_mvx({16{db_left_mvx}}),
        .left_mvy({16{db_left_mvy}}),
        .left_ref({16{db_left_ref}}),
        .top_intra(db_top_intra[db_mb_col]),
        .top_qp_y(db_top_qp[db_mb_col]),
        .top_nz(db_top_nz[db_mb_col]),
        .top_mvx({16{db_top_mvx[db_mb_col]}}),
        .top_mvy({16{db_top_mvy[db_mb_col]}}),
        .top_ref({16{db_top_ref[db_mb_col]}}),
        .nb_y_i(db_nb_y_i),
        .nb_u_i(db_nb_u_i),
        .nb_v_i(db_nb_v_i),
        .nb_y_o(db_nb_y_o),
        .nb_u_o(db_nb_u_o),
        .nb_v_o(db_nb_v_o),
        .luma_modified_samples(db_luma_modified),
        .chroma_modified_samples(db_chroma_modified),
        .edge_segments_filtered(db_edge_segments),
        .bs4_segments(db_bs4_segments),
        .last_chroma_qp_avg(db_last_chroma_qp),
        .filter_pipe_error(db_pipe_error),
        .unsupported_ref(db_unsupported_ref)
    );

    wire [31:0] db_wb_y_off = ({28'd0, wb_sample_idx[7:4]} + 32'd4) * 32'd20 +
                              {28'd0, wb_sample_idx[3:0]} + 32'd4;
    wire [31:0] db_wb_c_off = ({29'd0, wb_sample_idx[5:3]} + 32'd4) * 32'd12 +
                              {29'd0, wb_sample_idx[2:0]} + 32'd4;
    wire [7:0] db_wb_data = (wb_plane == 2'd0) ? db_nb_y_o[db_wb_y_off] :
                            (wb_plane == 2'd1) ? db_nb_u_o[db_wb_c_off] :
                                                  db_nb_v_o[db_wb_c_off];
    wire [7:0] recon_wb_data = (wb_plane == 2'd0) ? lat_recon_y[wb_sample_idx] :
                               (wb_plane == 2'd1) ? lat_recon_u[wb_sample_idx[5:0]] :
                                                     lat_recon_v[wb_sample_idx[5:0]];
`ifdef H264_DECODE_CORE_FAULT_PRE_DEBLOCK_TO_DPB
    wire [7:0] wb_data = recon_wb_data;
`else
    wire [7:0] wb_data = DEBLOCK_IN_LOOP ? db_wb_data : recon_wb_data;
`endif

    integer db_i;
    always @(posedge clk) begin
        db_start_r <= 1'b0;
        if (reset) begin
            db_seq_idx <= 7'd0;
            db_left_avail <= 1'b0;
            db_left_intra <= 1'b0;
            db_left_qp <= 6'd0;
            db_left_nz <= 16'd0;
            db_left_mvx <= 12'sd0;
            db_left_mvy <= 12'sd0;
            db_left_ref <= 2'd0;
            db_cur_intra <= 1'b0;
            db_cur_qp <= 6'd0;
            db_cur_nz <= 16'd0;
            db_cur_mvx <= 12'sd0;
            db_cur_mvy <= 12'sd0;
            db_cur_ref <= 2'd0;
            db_syn_intra <= 1'b0;
            db_syn_qp <= 6'd0;
            db_syn_nz <= 16'd0;
            db_syn_mvx <= 12'sd0;
            db_syn_mvy <= 12'sd0;
            db_syn_ref <= 2'd0;
            db_qp_run <= 6'd0;
            for (db_i = 0; db_i < MB_W; db_i = db_i + 1) begin
                db_top_avail[db_i] <= 1'b0;
                db_top_intra[db_i] <= 1'b0;
                db_top_qp[db_i] <= 6'd0;
                db_top_nz[db_i] <= 16'd0;
                db_top_mvx[db_i] <= 12'sd0;
                db_top_mvy[db_i] <= 12'sd0;
                db_top_ref[db_i] <= 2'd0;
            end
            for (db_i = 0; db_i < 64; db_i = db_i + 1) begin
                db_left_y[db_i] <= 8'd0;
                db_topbuf_y[db_i] <= 8'd0;
            end
            for (db_i = 0; db_i < 32; db_i = db_i + 1) begin
                db_left_u[db_i] <= 8'd0;
                db_left_v[db_i] <= 8'd0;
                db_topbuf_u[db_i] <= 8'd0;
                db_topbuf_v[db_i] <= 8'd0;
            end
        end else begin
            if (slice_start) begin
                db_qp_run <= slice_qp_y;
                db_left_avail <= 1'b0;
                if (slice_is_idr) begin
                    for (db_i = 0; db_i < MB_W; db_i = db_i + 1)
                        db_top_avail[db_i] <= 1'b0;
                end
            end
            if (mb_type_valid) begin
                db_syn_intra <= db_syn_intra_now;
                db_syn_qp <= db_syn_qp_now;
                db_qp_run <= db_qp_next;
                db_syn_nz <= db_syn_nz_now;
                db_syn_mvx <= db_syn_mvx_now;
                db_syn_mvy <= db_syn_mvy_now;
                db_syn_ref <= db_syn_ref_now;
            end
            if (wb_state == ST_IDLE && recon_mb_valid) begin
                db_cur_intra <= db_syn_intra_now;
                db_cur_qp <= db_syn_qp_now;
                db_cur_nz <= db_syn_nz_now;
                db_cur_mvx <= db_syn_mvx_now;
                db_cur_mvy <= db_syn_mvy_now;
                db_cur_ref <= db_syn_ref_now;
                db_seq_idx <= 7'd0;
                if (recon_mb_x == 8'd0) db_left_avail <= 1'b0;
            end
            if (wb_state == ST_DB_LOAD) begin
                db_topbuf_y[db_seq_idx[5:0]] <= db_top_y[db_top_y_base + {25'd0, db_seq_idx}];
                if (!db_seq_idx[5]) begin
                    db_topbuf_u[db_seq_idx[4:0]] <= db_top_u[db_top_c_base + {27'd0, db_seq_idx[4:0]}];
                    db_topbuf_v[db_seq_idx[4:0]] <= db_top_v[db_top_c_base + {27'd0, db_seq_idx[4:0]}];
                end
                db_seq_idx <= db_seq_idx + 7'd1;
                if (db_seq_idx == 7'd63) begin
                    db_seq_idx <= 7'd0;
                    db_start_r <= 1'b1;
                end
            end
            if (wb_state == ST_DB_STORE) begin
                // bottom four rows of the filtered MB become the next row's top
                db_top_y[db_top_y_base + {25'd0, db_seq_idx}] <=
                    db_nb_y_o[(12 + {30'd0, db_seq_idx[5:4]} + 32'd4) * 32'd20 +
                              {28'd0, db_seq_idx[3:0]} + 32'd4];
                if (!db_seq_idx[5]) begin
                    db_top_u[db_top_c_base + {27'd0, db_seq_idx[4:0]}] <=
                        db_nb_u_o[(4 + {30'd0, db_seq_idx[4:3]} + 32'd4) * 32'd12 +
                                  {29'd0, db_seq_idx[2:0]} + 32'd4];
                    db_top_v[db_top_c_base + {27'd0, db_seq_idx[4:0]}] <=
                        db_nb_v_o[(4 + {30'd0, db_seq_idx[4:3]} + 32'd4) * 32'd12 +
                                  {29'd0, db_seq_idx[2:0]} + 32'd4];
                end
                db_seq_idx <= db_seq_idx + 7'd1;
                if (db_seq_idx == 7'd63) begin
                    db_seq_idx <= 7'd0;
                    db_top_avail[db_mb_col] <= 1'b1;
                    db_top_intra[db_mb_col] <= db_cur_intra;
                    db_top_qp[db_mb_col] <= db_cur_qp;
                    db_top_nz[db_mb_col] <= db_cur_nz;
                    db_top_mvx[db_mb_col] <= db_cur_mvx;
                    db_top_mvy[db_mb_col] <= db_cur_mvy;
                    db_top_ref[db_mb_col] <= db_cur_ref;
                    db_left_avail <= 1'b1;
                    db_left_intra <= db_cur_intra;
                    db_left_qp <= db_cur_qp;
                    db_left_nz <= db_cur_nz;
                    db_left_mvx <= db_cur_mvx;
                    db_left_mvy <= db_cur_mvy;
                    db_left_ref <= db_cur_ref;
                    for (db_i = 0; db_i < 64; db_i = db_i + 1)
                        db_left_y[db_i] <= db_nb_y_o[((db_i / 4) + 4) * 20 + (db_i % 4) + 16];
                    for (db_i = 0; db_i < 32; db_i = db_i + 1) begin
                        db_left_u[db_i] <= db_nb_u_o[((db_i / 4) + 4) * 12 + (db_i % 4) + 8];
                        db_left_v[db_i] <= db_nb_v_o[((db_i / 4) + 4) * 12 + (db_i % 4) + 8];
                    end
                end
            end
        end
    end

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
`ifdef H264_DECODE_CORE_FAULT_DROP_WB
    wire product_wb_en = 1'b0;
`else
    wire product_wb_en = (wb_state == ST_WRITE);
`endif
    wire p16_sample_wb_en = (wb_state == ST_P16_WRITE);
    wire deblock_filtered_sample_valid = product_wb_en | p16_sample_wb_en;
`ifdef H264_DECODE_CORE_FAULT_COMMIT_BEFORE_SAMPLES
    // Commit the macroblock while its filtered sample run is still in flight.
    // This is the ordering-contract violation that an integration change is
    // most likely to introduce, so it has to be caught, not assumed.
    wire deblock_filtered_mb_valid = (wb_state == ST_WRITE) && (wb_idx == 9'd300);
`else
    wire deblock_filtered_mb_valid = (wb_state == ST_COMMIT);
`endif
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

    integer wb_i;
    always @(posedge clk) begin
        frame_done_r <= deblock_ref_ready_pulse;
        dpb_rd_en_r <= 1'b0;
        p16_wr_en_r <= 1'b0;
        rbsp_request_valid_r <= 1'b0;
        cavlc_start_r <= 1'b0;
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
            wb_commit_p16 <= 1'b0;
            syntax_mb_addr_r <= reset ? 16'd0 : first_mb_in_slice;
            rbsp_request_offset_r <= 16'd0;
            rbsp_request_valid_r <= 1'b0;
            mv_left_x <= 16'sd0;
            mv_left_y <= 16'sd0;
            mv_left_ref <= 2'd0;
            mv_left_valid <= 1'b0;
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

            case (wb_state)
            ST_IDLE: begin
                if (p16_launch) begin
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
                    p16_ref_idx_l0_r <= ref_idx_l0;
                    p16_res_bit_offset_r <= launch_residual_rel_bit_offset[9:0];
                    p16_res_block_idx <= 5'd0;
                    wb_idx <= 9'd0;
                    p16_tap_idx <= 7'd0;
                    wb_commit_p16 <= 1'b0;
                    for (wb_i = 0; wb_i < 256; wb_i = wb_i + 1)
                        lat_p16_residual_y[wb_i] <= p16_zero_mv_valid ? p16_residual_y[wb_i] : 16'sd0;
                    for (wb_i = 0; wb_i < 64; wb_i = wb_i + 1) begin
                        lat_p16_residual_u[wb_i] <= p16_zero_mv_valid ? p16_residual_u[wb_i] : 16'sd0;
                        lat_p16_residual_v[wb_i] <= p16_zero_mv_valid ? p16_residual_v[wb_i] : 16'sd0;
                    end
                    wb_state <= p16_zero_mv_valid ? ST_P16_TAP_REQ : ST_P16_RES_START;
                end else if (recon_mb_valid) begin
                    wb_mb_x <= recon_mb_x;
                    wb_mb_y <= recon_mb_y;
                    wb_mb_is_ref <= recon_mb_is_ref;
                    wb_base <= dpb_write_base;
                    wb_idx <= 9'd0;
                    wb_commit_p16 <= 1'b0;
                    for (wb_i = 0; wb_i < 256; wb_i = wb_i + 1)
                        lat_recon_y[wb_i] <= recon_y[wb_i];
                    for (wb_i = 0; wb_i < 64; wb_i = wb_i + 1) begin
                        lat_recon_u[wb_i] <= recon_u[wb_i];
                        lat_recon_v[wb_i] <= recon_v[wb_i];
                    end
                    wb_state <= DEBLOCK_IN_LOOP ? ST_DB_LOAD : ST_WRITE;
                end
            end
            ST_DB_LOAD: begin
                if (db_seq_idx == 7'd63) wb_state <= ST_DB_RUN;
            end
            ST_DB_RUN: begin
                if (db_done) wb_state <= ST_DB_STORE;
            end
            ST_DB_STORE: begin
                if (db_seq_idx == 7'd63) wb_state <= ST_WRITE;
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
                    wb_commit_p16 <= 1'b1;
                    wb_state <= ST_COMMIT;
                end else begin
                    wb_idx <= wb_idx + 9'd1;
                    wb_state <= ST_P16_TAP_REQ;
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

    assign dpb_wr_en = product_wb_en | p16_wr_en_r;
    assign dpb_wr_addr = p16_wr_en_r ? p16_wr_addr_r : wb_addr;
    assign dpb_wr_data = p16_wr_en_r ? p16_wr_data_r : wb_data;
    assign dpb_rd_en = dpb_rd_en_r;
    assign dpb_rd_addr = dpb_rd_addr_r;
    assign rbsp_request_offset = rbsp_request_offset_r;
    assign rbsp_request_valid = rbsp_request_valid_r;
    assign frame_done = frame_done_r;
    assign frame_mb_count = mb_count_r;
    assign busy = (wb_state != ST_IDLE);
    assign decode_state = wb_state;
    assign current_mb_addr = (wb_state == ST_IDLE) ? syntax_mb_addr_r : wb_mb_addr16;
    assign error = (mb_width != 8'd0 && mb_width32 != MB_W) ||
                   (mb_height != 8'd0 && mb_height32 != MB_H);

    (* keep = 1 *) wire _keep_decode_core_inputs =
        slice_is_idr | slice_is_i | |slice_qp_y | |first_mb_in_slice |
        |pps_chroma_qp_index_offset | |rbsp_byte[0] | |rbsp_window_base |
        mb_type_valid | |mb_type | mb_skip | |intra4x4_modes[0] |
        |intra16x16_mode | |chroma_pred_mode | |cbp_luma | |cbp_chroma |
        |mb_qp_delta | |mb_residual_bit_offset | |mv_x_qpel | |mv_y_qpel |
        |part_mode | |part_idx | cavlc_busy | |cavlc_bit_offset_end |
        |cavlc_total_coeff | |cavlc_trailing_ones | |cavlc_total_zeros |
        |cavlc_level_dbg[0] | |cavlc_run_dbg[0] |
        deblock_wb_valid | |deblock_wb_mb_addr | deblock_wb_is_ref |
        deblock_dpb_invalidate_refs | deblock_ref_ready_pulse |
        |deblock_ref_ready_slot | deblock_commit_order_error |
        db_busy | |db_luma_modified | |db_chroma_modified | |db_edge_segments |
        |db_bs4_segments | |db_last_chroma_qp | db_pipe_error | db_unsupported_ref;

endmodule
