// H.264 deblocking filter macroblock scheduler.
// Orchestrates edge filtering in normative order for one macroblock:
//   1. Vertical edges left-to-right (x=0,4,8,12)
//   2. Horizontal edges top-to-bottom (y=0,4,8,12)
// Filtering is in-place: each edge operates on already-filtered samples.
//
// Architecture: the macroblock's 16x16 luma samples are held in an internal
// register file.  Gather/scatter to the combinational edge filter is done via
// muxing each cycle, so one edge segment takes 1 cycle (gather+filter) +
// 1 cycle (scatter writeback) = 2 cycles per segment.  With 24 internal luma
// segments (no boundary edges) that is 48 cycles; with all 32 segments it is
// 64.  Chroma adds another 16 segments -> 96 cycles total (under 100 budget).
//
// The MB sample address is {y[3:0], x[3:0]} = row-major 16x16 layout.
//
// ═══════════════════════════════════════════════════════════════════════
//  INTERFACE CONTRACT — what this module needs from the pipeline
// ═══════════════════════════════════════════════════════════════════════
//
//  FROM PARSER / CABAC:
//    mb_intra[15:0]      — per-4x4-block intra flag (H.264 raster scan)
//    mb_nonzero[15:0]    — per-4x4-block coded-block-pattern flag
//    disable_idc[1:0]    — slice header: disable_deblocking_filter_idc
//    qp[5:0]             — QPy for this MB (QPp+QPq averaged at the edge)
//    alpha_offset[4:0]   — slice_alpha_c0_offset_div2 * 2
//    beta_offset[4:0]    — slice_beta_offset_div2 * 2
//
//  FROM MC / MV PREDICTOR:
//    mb_mvx[0:15], mb_mvy[0:15]  — quarter-pel MVs per 4x4 block
//    mb_ref[0:15]                 — reference index per 4x4 block
//    (bS=1 when |mvx_diff| >= 4 qpel OR |mvy_diff| >= 4 qpel OR ref differs)
//
//  FROM NEIGHBOR CONTEXT (w-ctl / line buffer):
//    left_avail, top_avail          — neighbor availability
//    left_same_slice, top_same_slice — for disable_idc=2
//    left_intra[3:0], left_nonzero[3:0], left_mvx/mvy/ref[0:3]
//    top_intra[3:0], top_nonzero[3:0], top_mvx/mvy/ref[0:3]
//
//  MISSING (not yet implemented):
//    left_samples[0:63]  — 4 columns × 16 rows from left neighbor (luma)
//    top_samples[0:63]   — 16 cols × 4 rows from top neighbor (luma)
//    Chroma sample ports (8×8 Cb + 8×8 Cr register files)
//    Chroma QP averaging (QPc differs from QPy per H.264 table 8-15)
//
//  OUTPUT CONTRACT:
//    The 256-byte register file contains post-deblock luma samples.
//    'done' pulses HIGH for one cycle when filtering completes.
//    DPB must store POST-DEBLOCK output (this is the reference for MC).
//    Intra prediction uses PRE-DEBLOCK reconstructed neighbors.
//    Getting this backwards produces plausible video that drifts.
//
// Product RTL only: test scaffolding belongs under tests/rtl.

`default_nettype none

module h264_deblock_mb_scheduler (
    input  wire              clk,
    input  wire              reset,

    // -- Start / status --
    input  wire              start,
    output reg               busy,
    output reg               done,

    // -- Slice parameters --
    input  wire [1:0]        disable_idc,
    input  wire [5:0]        qp,
    input  wire signed [4:0] alpha_offset,
    input  wire signed [4:0] beta_offset,

    // -- Neighbor availability --
    input  wire              left_avail,
    input  wire              top_avail,
    input  wire              left_same_slice,
    input  wire              top_same_slice,

    // -- Per-4x4-block metadata (H.264 raster scan order 0..15) --
    input  wire [15:0]       mb_intra,
    input  wire [15:0]       mb_nonzero,
    input  wire signed [11:0] mb_mvx  [0:15],
    input  wire signed [11:0] mb_mvy  [0:15],
    input  wire [1:0]        mb_ref  [0:15],

    // -- Left neighbor block metadata (4 rows from top to bottom) --
    input  wire [3:0]        left_intra,
    input  wire [3:0]        left_nonzero,
    input  wire signed [11:0] left_mvx [0:3],
    input  wire signed [11:0] left_mvy [0:3],
    input  wire [1:0]        left_ref [0:3],

    // -- Top neighbor block metadata (4 columns from left to right) --
    input  wire [3:0]        top_intra,
    input  wire [3:0]        top_nonzero,
    input  wire signed [11:0] top_mvx [0:3],
    input  wire signed [11:0] top_mvy [0:3],
    input  wire [1:0]        top_ref [0:3],

    // -- MB sample load interface --
    input  wire              sample_wr,
    input  wire [7:0]        sample_waddr,
    input  wire [7:0]        sample_wdata,

    // -- MB sample read interface (post-deblock) --
    input  wire [7:0]        sample_raddr,
    output wire [7:0]        sample_rdata,

    // -- Chroma sample load interface (8x8 per plane) --
    input  wire              chroma_wr,
    input  wire [5:0]        chroma_waddr,   // {y[2:0], x[2:0]}
    input  wire [7:0]        chroma_wdata,
    input  wire              chroma_sel,      // 0=Cb, 1=Cr

    // -- Chroma sample read interface --
    input  wire [5:0]        chroma_raddr,
    input  wire              chroma_rsel,     // 0=Cb, 1=Cr
    output wire [7:0]        chroma_rdata,

    // -- Chroma QP (QPc from table 8-15, differs from QPy above QP 30) --
    input  wire [5:0]        chroma_qp,

    // -- Cycle counter for budget measurement --
    output reg  [7:0]        cycle_count
);

    // =================================================================
    //  Register file: 256 x 8-bit for 16x16 luma macroblock
    //  Address = {y[3:0], x[3:0]}
    // =================================================================
    reg [7:0] mb_samples [0:255];

    // =================================================================
    //  Chroma register files: 64 x 8-bit each for 8x8 Cb and Cr
    //  Address = {y[2:0], x[2:0]}
    // =================================================================
    reg [7:0] cb_samples [0:63];
    reg [7:0] cr_samples [0:63];

    // External write (loading reconstructed samples before start)
    always @(posedge clk) begin : ext_write
        if (sample_wr && !busy)
            mb_samples[sample_waddr] <= sample_wdata;
    end

    // External read (reading deblocked result after done)
    assign sample_rdata = mb_samples[sample_raddr];

    // Chroma external write
    always @(posedge clk) begin : chroma_ext_write
        if (chroma_wr && !busy) begin
            if (!chroma_sel)
                cb_samples[chroma_waddr] <= chroma_wdata;
            else
                cr_samples[chroma_waddr] <= chroma_wdata;
        end
    end

    // Chroma external read
    assign chroma_rdata = chroma_rsel ? cr_samples[chroma_raddr]
                                      : cb_samples[chroma_raddr];

    // =================================================================
    //  H.264 4x4 block raster scan <-> (bx, by) mapping
    //  idx:  0  1  4  5
    //        2  3  6  7
    //        8  9 12 13
    //       10 11 14 15
    // =================================================================
    function automatic [3:0] blk_from_xy;
        input [1:0] bx, by;
        begin
            case ({by, bx})
                4'b0000: blk_from_xy = 4'd0;
                4'b0001: blk_from_xy = 4'd1;
                4'b0010: blk_from_xy = 4'd4;
                4'b0011: blk_from_xy = 4'd5;
                4'b0100: blk_from_xy = 4'd2;
                4'b0101: blk_from_xy = 4'd3;
                4'b0110: blk_from_xy = 4'd6;
                4'b0111: blk_from_xy = 4'd7;
                4'b1000: blk_from_xy = 4'd8;
                4'b1001: blk_from_xy = 4'd9;
                4'b1010: blk_from_xy = 4'd12;
                4'b1011: blk_from_xy = 4'd13;
                4'b1100: blk_from_xy = 4'd10;
                4'b1101: blk_from_xy = 4'd11;
                4'b1110: blk_from_xy = 4'd14;
                4'b1111: blk_from_xy = 4'd15;
                default: blk_from_xy = 4'd0;
            endcase
        end
    endfunction

    // =================================================================
    //  State machine
    // =================================================================
    localparam [1:0] S_IDLE    = 2'd0;
    localparam [1:0] S_GATHER  = 2'd1;
    localparam [1:0] S_SCATTER = 2'd2;
    localparam [1:0] S_DONE    = 2'd3;

    reg [1:0] state;
    reg       phase;      // 0=vertical, 1=horizontal
    reg [1:0] edge_idx;   // luma: 0..3 (edges), chroma: 0..1 (edges)
    reg [1:0] seg_idx;    // luma: 0..3, chroma: 0..1

    // Chroma processing phases:
    // 0 = luma, 1 = Cb, 2 = Cr
    reg [1:0] plane;      // 0=luma, 1=Cb, 2=Cr
    wire      is_chroma_phase = (plane != 2'd0);
    wire      is_cr_phase     = (plane == 2'd2);

    // =================================================================
    //  Combinational gather: read 8x4 samples from register file
    // =================================================================
    // Luma: edge_px = edge_idx*4 in {0,4,8,12}; seg_px = seg_idx*4 in {0,4,8,12}
    // Chroma: edge_px = edge_idx*4 in {0,4}; seg_px = seg_idx*4 in {0,4}
    wire [3:0] edge_px = {edge_idx, 2'b00};
    wire [3:0] seg_px  = {seg_idx, 2'b00};

    // Chroma-specific: address into 8x8 register file {y[2:0], x[2:0]}
    wire [2:0] chr_edge_px = {edge_idx[0], 2'b00};  // 0 or 4
    wire [2:0] chr_seg_px  = {seg_idx[0], 2'b00};   // 0 or 4

    reg [7:0] g_p3 [0:3], g_p2 [0:3], g_p1 [0:3], g_p0 [0:3];
    reg [7:0] g_q0 [0:3], g_q1 [0:3], g_q2 [0:3], g_q3 [0:3];

    // Helper: luma sample address {y[3:0], x[3:0]}
    function automatic [7:0] saddr;
        input [3:0] x, y;
        begin
            saddr = {y, x};
        end
    endfunction

    // Helper: chroma sample address {y[2:0], x[2:0]}
    function automatic [5:0] caddr;
        input [2:0] x, y;
        begin
            caddr = {y, x};
        end
    endfunction

    integer gi;
    always @* begin
        for (gi = 0; gi < 4; gi = gi + 1) begin
            if (!is_chroma_phase) begin
                // --- LUMA gather ---
                if (phase == 1'b0) begin
                    // Vertical edge at column edge_px
                    g_p3[gi] = (edge_px >= 4'd4) ? mb_samples[saddr(edge_px - 4'd4, seg_px + gi[3:0])] : 8'd0;
                    g_p2[gi] = (edge_px >= 4'd3) ? mb_samples[saddr(edge_px - 4'd3, seg_px + gi[3:0])] : 8'd0;
                    g_p1[gi] = (edge_px >= 4'd2) ? mb_samples[saddr(edge_px - 4'd2, seg_px + gi[3:0])] : 8'd0;
                    g_p0[gi] = (edge_px >= 4'd1) ? mb_samples[saddr(edge_px - 4'd1, seg_px + gi[3:0])] : 8'd0;
                    g_q0[gi] = mb_samples[saddr(edge_px + 4'd0, seg_px + gi[3:0])];
                    g_q1[gi] = (edge_px <= 4'd14) ? mb_samples[saddr(edge_px + 4'd1, seg_px + gi[3:0])] : 8'd0;
                    g_q2[gi] = (edge_px <= 4'd13) ? mb_samples[saddr(edge_px + 4'd2, seg_px + gi[3:0])] : 8'd0;
                    g_q3[gi] = (edge_px <= 4'd12) ? mb_samples[saddr(edge_px + 4'd3, seg_px + gi[3:0])] : 8'd0;
                end else begin
                    // Horizontal edge at row edge_px
                    g_p3[gi] = (edge_px >= 4'd4) ? mb_samples[saddr(seg_px + gi[3:0], edge_px - 4'd4)] : 8'd0;
                    g_p2[gi] = (edge_px >= 4'd3) ? mb_samples[saddr(seg_px + gi[3:0], edge_px - 4'd3)] : 8'd0;
                    g_p1[gi] = (edge_px >= 4'd2) ? mb_samples[saddr(seg_px + gi[3:0], edge_px - 4'd2)] : 8'd0;
                    g_p0[gi] = (edge_px >= 4'd1) ? mb_samples[saddr(seg_px + gi[3:0], edge_px - 4'd1)] : 8'd0;
                    g_q0[gi] = mb_samples[saddr(seg_px + gi[3:0], edge_px + 4'd0)];
                    g_q1[gi] = (edge_px <= 4'd14) ? mb_samples[saddr(seg_px + gi[3:0], edge_px + 4'd1)] : 8'd0;
                    g_q2[gi] = (edge_px <= 4'd13) ? mb_samples[saddr(seg_px + gi[3:0], edge_px + 4'd2)] : 8'd0;
                    g_q3[gi] = (edge_px <= 4'd12) ? mb_samples[saddr(seg_px + gi[3:0], edge_px + 4'd3)] : 8'd0;
                end
            end else begin
                // --- CHROMA gather (from Cb or Cr register file) ---
                if (phase == 1'b0) begin
                    // Vertical edge at column chr_edge_px (0 or 4)
                    g_p3[gi] = (chr_edge_px >= 3'd4) ? (is_cr_phase ? cr_samples[caddr(chr_edge_px - 3'd4, chr_seg_px + gi[2:0])] : cb_samples[caddr(chr_edge_px - 3'd4, chr_seg_px + gi[2:0])]) : 8'd0;
                    g_p2[gi] = (chr_edge_px >= 3'd3) ? (is_cr_phase ? cr_samples[caddr(chr_edge_px - 3'd3, chr_seg_px + gi[2:0])] : cb_samples[caddr(chr_edge_px - 3'd3, chr_seg_px + gi[2:0])]) : 8'd0;
                    g_p1[gi] = (chr_edge_px >= 3'd2) ? (is_cr_phase ? cr_samples[caddr(chr_edge_px - 3'd2, chr_seg_px + gi[2:0])] : cb_samples[caddr(chr_edge_px - 3'd2, chr_seg_px + gi[2:0])]) : 8'd0;
                    g_p0[gi] = (chr_edge_px >= 3'd1) ? (is_cr_phase ? cr_samples[caddr(chr_edge_px - 3'd1, chr_seg_px + gi[2:0])] : cb_samples[caddr(chr_edge_px - 3'd1, chr_seg_px + gi[2:0])]) : 8'd0;
                    g_q0[gi] = is_cr_phase ? cr_samples[caddr(chr_edge_px + 3'd0, chr_seg_px + gi[2:0])] : cb_samples[caddr(chr_edge_px + 3'd0, chr_seg_px + gi[2:0])];
                    g_q1[gi] = (chr_edge_px <= 3'd6) ? (is_cr_phase ? cr_samples[caddr(chr_edge_px + 3'd1, chr_seg_px + gi[2:0])] : cb_samples[caddr(chr_edge_px + 3'd1, chr_seg_px + gi[2:0])]) : 8'd0;
                    g_q2[gi] = (chr_edge_px <= 3'd5) ? (is_cr_phase ? cr_samples[caddr(chr_edge_px + 3'd2, chr_seg_px + gi[2:0])] : cb_samples[caddr(chr_edge_px + 3'd2, chr_seg_px + gi[2:0])]) : 8'd0;
                    g_q3[gi] = (chr_edge_px <= 3'd4) ? (is_cr_phase ? cr_samples[caddr(chr_edge_px + 3'd3, chr_seg_px + gi[2:0])] : cb_samples[caddr(chr_edge_px + 3'd3, chr_seg_px + gi[2:0])]) : 8'd0;
                end else begin
                    // Horizontal edge at row chr_edge_px (0 or 4)
                    g_p3[gi] = (chr_edge_px >= 3'd4) ? (is_cr_phase ? cr_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px - 3'd4)] : cb_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px - 3'd4)]) : 8'd0;
                    g_p2[gi] = (chr_edge_px >= 3'd3) ? (is_cr_phase ? cr_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px - 3'd3)] : cb_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px - 3'd3)]) : 8'd0;
                    g_p1[gi] = (chr_edge_px >= 3'd2) ? (is_cr_phase ? cr_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px - 3'd2)] : cb_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px - 3'd2)]) : 8'd0;
                    g_p0[gi] = (chr_edge_px >= 3'd1) ? (is_cr_phase ? cr_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px - 3'd1)] : cb_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px - 3'd1)]) : 8'd0;
                    g_q0[gi] = is_cr_phase ? cr_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px + 3'd0)] : cb_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px + 3'd0)];
                    g_q1[gi] = (chr_edge_px <= 3'd6) ? (is_cr_phase ? cr_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px + 3'd1)] : cb_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px + 3'd1)]) : 8'd0;
                    g_q2[gi] = (chr_edge_px <= 3'd5) ? (is_cr_phase ? cr_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px + 3'd2)] : cb_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px + 3'd2)]) : 8'd0;
                    g_q3[gi] = (chr_edge_px <= 3'd4) ? (is_cr_phase ? cr_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px + 3'd3)] : cb_samples[caddr(chr_seg_px + gi[2:0], chr_edge_px + 3'd3)]) : 8'd0;
                end
            end
        end
    end

    // =================================================================
    //  bS derivation (luma: combinational; chroma: stored from luma phase)
    // =================================================================
    // Store luma bS during scatter for chroma reuse.
    // Index: [phase][edge_idx][seg_idx]
    // For chroma 4:2:0, each chroma segment maps to max of 2 luma segments.
    reg [2:0] luma_bs_store [0:1][0:3][0:3];  // [V/H][edge][seg]

    reg       p_is_intra, q_is_intra;
    reg       p_has_nz, q_has_nz;
    reg signed [11:0] p_mvx_v, p_mvy_v, q_mvx_v, q_mvy_v;
    reg [1:0] p_ref_v, q_ref_v;
    reg       is_mb_edge, slice_blocked;

    wire is_left_edge = (phase == 1'b0) && (edge_idx == 2'd0);
    wire is_top_edge  = (phase == 1'b1) && (edge_idx == 2'd0);
    wire skip_this    = (is_left_edge && !left_avail) || (is_top_edge && !top_avail);

    // Chroma bS: max of 2 corresponding luma segments
    // Chroma V edge 0 → luma V edge 0; Chroma V edge 1 → luma V edge 2
    // Chroma H edge 0 → luma H edge 0; Chroma H edge 1 → luma H edge 2
    wire [1:0] chr_luma_edge = {edge_idx[0], 1'b0};  // 0 or 2
    wire [1:0] chr_luma_seg0 = {seg_idx[0], 1'b0};   // 0 or 2
    wire [1:0] chr_luma_seg1 = {seg_idx[0], 1'b1};   // 1 or 3

    wire [2:0] chr_bs_a = luma_bs_store[phase][chr_luma_edge][chr_luma_seg0];
    wire [2:0] chr_bs_b = luma_bs_store[phase][chr_luma_edge][chr_luma_seg1];
    wire [2:0] chroma_bs = (chr_bs_a > chr_bs_b) ? chr_bs_a : chr_bs_b;

    always @* begin
        is_mb_edge = is_left_edge || is_top_edge;
        slice_blocked = 1'b0;
        if (disable_idc == 2'd2) begin
            if (is_left_edge && !left_same_slice) slice_blocked = 1'b1;
            if (is_top_edge  && !top_same_slice)  slice_blocked = 1'b1;
        end

        // Q block
        if (phase == 1'b0) begin
            q_is_intra = mb_intra[blk_from_xy(edge_idx, seg_idx)];
            q_has_nz   = mb_nonzero[blk_from_xy(edge_idx, seg_idx)];
            q_mvx_v    = mb_mvx[blk_from_xy(edge_idx, seg_idx)];
            q_mvy_v    = mb_mvy[blk_from_xy(edge_idx, seg_idx)];
            q_ref_v    = mb_ref[blk_from_xy(edge_idx, seg_idx)];
        end else begin
            q_is_intra = mb_intra[blk_from_xy(seg_idx, edge_idx)];
            q_has_nz   = mb_nonzero[blk_from_xy(seg_idx, edge_idx)];
            q_mvx_v    = mb_mvx[blk_from_xy(seg_idx, edge_idx)];
            q_mvy_v    = mb_mvy[blk_from_xy(seg_idx, edge_idx)];
            q_ref_v    = mb_ref[blk_from_xy(seg_idx, edge_idx)];
        end

        // P block
        if (is_left_edge) begin
            p_is_intra = left_intra[seg_idx];
            p_has_nz   = left_nonzero[seg_idx];
            p_mvx_v    = left_mvx[seg_idx];
            p_mvy_v    = left_mvy[seg_idx];
            p_ref_v    = left_ref[seg_idx];
        end else if (is_top_edge) begin
            p_is_intra = top_intra[seg_idx];
            p_has_nz   = top_nonzero[seg_idx];
            p_mvx_v    = top_mvx[seg_idx];
            p_mvy_v    = top_mvy[seg_idx];
            p_ref_v    = top_ref[seg_idx];
        end else if (phase == 1'b0) begin
            p_is_intra = mb_intra[blk_from_xy(edge_idx - 2'd1, seg_idx)];
            p_has_nz   = mb_nonzero[blk_from_xy(edge_idx - 2'd1, seg_idx)];
            p_mvx_v    = mb_mvx[blk_from_xy(edge_idx - 2'd1, seg_idx)];
            p_mvy_v    = mb_mvy[blk_from_xy(edge_idx - 2'd1, seg_idx)];
            p_ref_v    = mb_ref[blk_from_xy(edge_idx - 2'd1, seg_idx)];
        end else begin
            p_is_intra = mb_intra[blk_from_xy(seg_idx, edge_idx - 2'd1)];
            p_has_nz   = mb_nonzero[blk_from_xy(seg_idx, edge_idx - 2'd1)];
            p_mvx_v    = mb_mvx[blk_from_xy(seg_idx, edge_idx - 2'd1)];
            p_mvy_v    = mb_mvy[blk_from_xy(seg_idx, edge_idx - 2'd1)];
            p_ref_v    = mb_ref[blk_from_xy(seg_idx, edge_idx - 2'd1)];
        end
    end

    wire [2:0] derived_bs;
    wire       unsup_ref;

    h264_deblock_bs u_bs (
        .disable_all(disable_idc == 2'd1),
        .slice_boundary_blocked(slice_blocked),
        .mb_boundary(is_mb_edge),
        .p_intra(p_is_intra),
        .q_intra(q_is_intra),
        .p_nonzero(p_has_nz),
        .q_nonzero(q_has_nz),
        .p_ref(p_ref_v),
        .q_ref(q_ref_v),
        .p_mvx(p_mvx_v),
        .p_mvy(p_mvy_v),
        .q_mvx(q_mvx_v),
        .q_mvy(q_mvy_v),
        .bs(derived_bs),
        .unsupported_ref(unsup_ref)
    );

    // Select bS: luma uses derived_bs, chroma uses stored max
    wire [2:0] active_bs = is_chroma_phase ? chroma_bs : derived_bs;

    // =================================================================
    //  Combinational edge filter (muxed for luma/chroma)
    // =================================================================
    wire [7:0] f_p2 [0:3], f_p1 [0:3], f_p0 [0:3];
    wire [7:0] f_q0 [0:3], f_q1 [0:3], f_q2 [0:3];
    wire [7:0] dbg_alpha, dbg_beta;
    wire [5:0] dbg_tc0;

    // QPc from table 8-15 differs from QPy above QP 30
    wire [5:0] active_qp = is_chroma_phase ? chroma_qp : qp;

    h264_deblock_edge u_edge (
        .is_chroma(is_chroma_phase),
        .bs(active_bs),
        .qp_avg(active_qp),
        .slice_alpha_c0_offset(alpha_offset),
        .slice_beta_offset(beta_offset),
        .p3_in(g_p3), .p2_in(g_p2), .p1_in(g_p1), .p0_in(g_p0),
        .q0_in(g_q0), .q1_in(g_q1), .q2_in(g_q2), .q3_in(g_q3),
        .p2_out(f_p2), .p1_out(f_p1), .p0_out(f_p0),
        .q0_out(f_q0), .q1_out(f_q1), .q2_out(f_q2),
        .alpha_dbg(dbg_alpha), .beta_dbg(dbg_beta), .tc0_dbg(dbg_tc0)
    );

    // =================================================================
    //  State machine: luma V→H, then Cb V→H, then Cr V→H
    //  Luma: 4 edges × 4 segments × 2 phases = 32 segments (64 cycles)
    //  Chroma: 2 edges × 2 segments × 2 phases × 2 planes = 16 segments (32 cycles)
    //  Total: 96 cycles/MB
    // =================================================================

    // Limits depend on plane: luma uses 0..3, chroma uses 0..1
    wire [1:0] seg_max  = is_chroma_phase ? 2'd1 : 2'd3;
    wire [1:0] edge_max = is_chroma_phase ? 2'd1 : 2'd3;

    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            phase <= 1'b0;
            edge_idx <= 2'd0;
            seg_idx <= 2'd0;
            plane <= 2'd0;
            cycle_count <= 8'd0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        if (disable_idc == 2'd1) begin
                            done <= 1'b1;
                            cycle_count <= 8'd1;
                        end else begin
                            busy <= 1'b1;
                            phase <= 1'b0;
                            edge_idx <= 2'd0;
                            seg_idx <= 2'd0;
                            plane <= 2'd0;
                            cycle_count <= 8'd0;
                            state <= S_GATHER;
                        end
                    end
                end

                S_GATHER: begin
                    cycle_count <= cycle_count + 8'd1;
                    if (skip_this && !is_chroma_phase) begin
                        // Skip boundary edges when neighbor is unavailable (luma only)
                        if (seg_idx == seg_max) begin
                            seg_idx <= 2'd0;
                            if (edge_idx == edge_max) begin
                                edge_idx <= 2'd0;
                                if (phase == 1'b1) begin
                                    // Phase done — advance plane
                                    phase <= 1'b0;
                                    if (plane == 2'd2)
                                        state <= S_DONE;
                                    else
                                        plane <= plane + 2'd1;
                                end else
                                    phase <= 1'b1;
                            end else
                                edge_idx <= edge_idx + 2'd1;
                        end else
                            seg_idx <= seg_idx + 2'd1;
                    end else if (is_chroma_phase && skip_this) begin
                        // Skip chroma boundary edges too
                        if (seg_idx == seg_max) begin
                            seg_idx <= 2'd0;
                            if (edge_idx == edge_max) begin
                                edge_idx <= 2'd0;
                                if (phase == 1'b1) begin
                                    phase <= 1'b0;
                                    if (plane == 2'd2)
                                        state <= S_DONE;
                                    else
                                        plane <= plane + 2'd1;
                                end else
                                    phase <= 1'b1;
                            end else
                                edge_idx <= edge_idx + 2'd1;
                        end else
                            seg_idx <= seg_idx + 2'd1;
                    end else begin
                        state <= S_SCATTER;
                    end
                end

                S_SCATTER: begin
                    cycle_count <= cycle_count + 8'd1;

                    if (!is_chroma_phase) begin
                        // --- LUMA scatter: write filtered results back ---
                        // Store bS for chroma reuse
                        luma_bs_store[phase][edge_idx][seg_idx] <= derived_bs;

                        begin : scatter_luma_blk
                            integer si;
                            for (si = 0; si < 4; si = si + 1) begin
                                if (phase == 1'b0) begin
                                    // Vertical edge
                                    if (!is_left_edge) begin
                                        mb_samples[saddr(edge_px - 4'd3, seg_px + si[3:0])] <= f_p2[si];
                                        mb_samples[saddr(edge_px - 4'd2, seg_px + si[3:0])] <= f_p1[si];
                                        mb_samples[saddr(edge_px - 4'd1, seg_px + si[3:0])] <= f_p0[si];
                                    end
                                    mb_samples[saddr(edge_px + 4'd0, seg_px + si[3:0])] <= f_q0[si];
                                    mb_samples[saddr(edge_px + 4'd1, seg_px + si[3:0])] <= f_q1[si];
                                    mb_samples[saddr(edge_px + 4'd2, seg_px + si[3:0])] <= f_q2[si];
                                end else begin
                                    // Horizontal edge
                                    if (!is_top_edge) begin
                                        mb_samples[saddr(seg_px + si[3:0], edge_px - 4'd3)] <= f_p2[si];
                                        mb_samples[saddr(seg_px + si[3:0], edge_px - 4'd2)] <= f_p1[si];
                                        mb_samples[saddr(seg_px + si[3:0], edge_px - 4'd1)] <= f_p0[si];
                                    end
                                    mb_samples[saddr(seg_px + si[3:0], edge_px + 4'd0)] <= f_q0[si];
                                    mb_samples[saddr(seg_px + si[3:0], edge_px + 4'd1)] <= f_q1[si];
                                    mb_samples[saddr(seg_px + si[3:0], edge_px + 4'd2)] <= f_q2[si];
                                end
                            end
                        end
                    end else begin
                        // --- CHROMA scatter: write only p0/q0 (chroma never modifies p1/p2/q1/q2) ---
                        begin : scatter_chroma_blk
                            integer si;
                            for (si = 0; si < 4; si = si + 1) begin
                                if (phase == 1'b0) begin
                                    // Vertical edge in chroma
                                    if (!is_left_edge && chr_edge_px >= 3'd1) begin
                                        if (is_cr_phase)
                                            cr_samples[caddr(chr_edge_px - 3'd1, chr_seg_px + si[2:0])] <= f_p0[si];
                                        else
                                            cb_samples[caddr(chr_edge_px - 3'd1, chr_seg_px + si[2:0])] <= f_p0[si];
                                    end
                                    if (is_cr_phase)
                                        cr_samples[caddr(chr_edge_px + 3'd0, chr_seg_px + si[2:0])] <= f_q0[si];
                                    else
                                        cb_samples[caddr(chr_edge_px + 3'd0, chr_seg_px + si[2:0])] <= f_q0[si];
                                end else begin
                                    // Horizontal edge in chroma
                                    if (!is_top_edge && chr_edge_px >= 3'd1) begin
                                        if (is_cr_phase)
                                            cr_samples[caddr(chr_seg_px + si[2:0], chr_edge_px - 3'd1)] <= f_p0[si];
                                        else
                                            cb_samples[caddr(chr_seg_px + si[2:0], chr_edge_px - 3'd1)] <= f_p0[si];
                                    end
                                    if (is_cr_phase)
                                        cr_samples[caddr(chr_seg_px + si[2:0], chr_edge_px + 3'd0)] <= f_q0[si];
                                    else
                                        cb_samples[caddr(chr_seg_px + si[2:0], chr_edge_px + 3'd0)] <= f_q0[si];
                                end
                            end
                        end
                    end

                    // Advance to next edge segment
                    if (seg_idx == seg_max) begin
                        seg_idx <= 2'd0;
                        if (edge_idx == edge_max) begin
                            edge_idx <= 2'd0;
                            if (phase == 1'b1) begin
                                // Both V and H done for this plane
                                phase <= 1'b0;
                                if (plane == 2'd2)
                                    state <= S_DONE;
                                else begin
                                    plane <= plane + 2'd1;
                                    state <= S_GATHER;
                                end
                            end else begin
                                phase <= 1'b1;
                                state <= S_GATHER;
                            end
                        end else begin
                            edge_idx <= edge_idx + 2'd1;
                            state <= S_GATHER;
                        end
                    end else begin
                        seg_idx <= seg_idx + 2'd1;
                        state <= S_GATHER;
                    end
                end

                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
