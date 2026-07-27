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

    // -- Cycle counter for budget measurement --
    output reg  [7:0]        cycle_count
);

    // =================================================================
    //  Register file: 256 x 8-bit for 16x16 luma macroblock
    //  Address = {y[3:0], x[3:0]}
    // =================================================================
    reg [7:0] mb_samples [0:255];

    // External write (loading reconstructed samples before start)
    always @(posedge clk) begin : ext_write
        if (sample_wr && !busy)
            mb_samples[sample_waddr] <= sample_wdata;
    end

    // External read (reading deblocked result after done)
    assign sample_rdata = mb_samples[sample_raddr];

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
    reg [1:0] edge_idx;   // 0..3: which edge line
    reg [1:0] seg_idx;    // 0..3: which 4-sample segment

    // =================================================================
    //  Combinational gather: read 8x4 samples from register file
    // =================================================================
    wire [3:0] edge_px = {edge_idx, 2'b00};
    wire [3:0] seg_px  = {seg_idx, 2'b00};

    reg [7:0] g_p3 [0:3], g_p2 [0:3], g_p1 [0:3], g_p0 [0:3];
    reg [7:0] g_q0 [0:3], g_q1 [0:3], g_q2 [0:3], g_q3 [0:3];

    // Helper: luma sample address {y[3:0], x[3:0]}
    function automatic [7:0] saddr;
        input [3:0] x, y;
        begin
            saddr = {y, x};
        end
    endfunction

    integer gi;
    always @* begin
        for (gi = 0; gi < 4; gi = gi + 1) begin
            if (phase == 1'b0) begin
                // Vertical edge at column edge_px.
                // Row index = seg_px + gi
                g_p3[gi] = (edge_px >= 4'd4) ? mb_samples[saddr(edge_px - 4'd4, seg_px + gi[3:0])] : 8'd0;
                g_p2[gi] = (edge_px >= 4'd3) ? mb_samples[saddr(edge_px - 4'd3, seg_px + gi[3:0])] : 8'd0;
                g_p1[gi] = (edge_px >= 4'd2) ? mb_samples[saddr(edge_px - 4'd2, seg_px + gi[3:0])] : 8'd0;
                g_p0[gi] = (edge_px >= 4'd1) ? mb_samples[saddr(edge_px - 4'd1, seg_px + gi[3:0])] : 8'd0;
                g_q0[gi] = mb_samples[saddr(edge_px + 4'd0, seg_px + gi[3:0])];
                g_q1[gi] = (edge_px <= 4'd14) ? mb_samples[saddr(edge_px + 4'd1, seg_px + gi[3:0])] : 8'd0;
                g_q2[gi] = (edge_px <= 4'd13) ? mb_samples[saddr(edge_px + 4'd2, seg_px + gi[3:0])] : 8'd0;
                g_q3[gi] = (edge_px <= 4'd12) ? mb_samples[saddr(edge_px + 4'd3, seg_px + gi[3:0])] : 8'd0;
            end else begin
                // Horizontal edge at row edge_px.
                // Col index = seg_px + gi
                g_p3[gi] = (edge_px >= 4'd4) ? mb_samples[saddr(seg_px + gi[3:0], edge_px - 4'd4)] : 8'd0;
                g_p2[gi] = (edge_px >= 4'd3) ? mb_samples[saddr(seg_px + gi[3:0], edge_px - 4'd3)] : 8'd0;
                g_p1[gi] = (edge_px >= 4'd2) ? mb_samples[saddr(seg_px + gi[3:0], edge_px - 4'd2)] : 8'd0;
                g_p0[gi] = (edge_px >= 4'd1) ? mb_samples[saddr(seg_px + gi[3:0], edge_px - 4'd1)] : 8'd0;
                g_q0[gi] = mb_samples[saddr(seg_px + gi[3:0], edge_px + 4'd0)];
                g_q1[gi] = (edge_px <= 4'd14) ? mb_samples[saddr(seg_px + gi[3:0], edge_px + 4'd1)] : 8'd0;
                g_q2[gi] = (edge_px <= 4'd13) ? mb_samples[saddr(seg_px + gi[3:0], edge_px + 4'd2)] : 8'd0;
                g_q3[gi] = (edge_px <= 4'd12) ? mb_samples[saddr(seg_px + gi[3:0], edge_px + 4'd3)] : 8'd0;
            end
        end
    end

    // =================================================================
    //  bS derivation
    // =================================================================
    reg       p_is_intra, q_is_intra;
    reg       p_has_nz, q_has_nz;
    reg signed [11:0] p_mvx_v, p_mvy_v, q_mvx_v, q_mvy_v;
    reg [1:0] p_ref_v, q_ref_v;
    reg       is_mb_edge, slice_blocked;

    wire is_left_edge = (phase == 1'b0) && (edge_idx == 2'd0);
    wire is_top_edge  = (phase == 1'b1) && (edge_idx == 2'd0);
    wire skip_this    = (is_left_edge && !left_avail) || (is_top_edge && !top_avail);

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

    // =================================================================
    //  Combinational edge filter
    // =================================================================
    wire [7:0] f_p2 [0:3], f_p1 [0:3], f_p0 [0:3];
    wire [7:0] f_q0 [0:3], f_q1 [0:3], f_q2 [0:3];
    wire [7:0] dbg_alpha, dbg_beta;
    wire [5:0] dbg_tc0;

    h264_deblock_edge u_edge (
        .is_chroma(1'b0),
        .bs(derived_bs),
        .qp_avg(qp),
        .slice_alpha_c0_offset(alpha_offset),
        .slice_beta_offset(beta_offset),
        .p3_in(g_p3), .p2_in(g_p2), .p1_in(g_p1), .p0_in(g_p0),
        .q0_in(g_q0), .q1_in(g_q1), .q2_in(g_q2), .q3_in(g_q3),
        .p2_out(f_p2), .p1_out(f_p1), .p0_out(f_p0),
        .q0_out(f_q0), .q1_out(f_q1), .q2_out(f_q2),
        .alpha_dbg(dbg_alpha), .beta_dbg(dbg_beta), .tc0_dbg(dbg_tc0)
    );

    // =================================================================
    //  State machine
    // =================================================================
    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            phase <= 1'b0;
            edge_idx <= 2'd0;
            seg_idx <= 2'd0;
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
                            cycle_count <= 8'd0;
                            state <= S_GATHER;
                        end
                    end
                end

                S_GATHER: begin
                    cycle_count <= cycle_count + 8'd1;
                    if (skip_this) begin
                        // Skip boundary edges when neighbor is unavailable
                        if (seg_idx == 2'd3) begin
                            seg_idx <= 2'd0;
                            if (edge_idx == 2'd3) begin
                                edge_idx <= 2'd0;
                                if (phase == 1'b1)
                                    state <= S_DONE;
                                else
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
                    // Write filtered results back to register file (in-place).
                    // For boundary edges (edge_idx=0), only write q-side samples
                    // inside the current MB; p-side belongs to the neighbor.
                    begin : scatter_blk
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

                    // Advance to next edge segment
                    if (seg_idx == 2'd3) begin
                        seg_idx <= 2'd0;
                        if (edge_idx == 2'd3) begin
                            edge_idx <= 2'd0;
                            if (phase == 1'b1)
                                state <= S_DONE;
                            else begin
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
