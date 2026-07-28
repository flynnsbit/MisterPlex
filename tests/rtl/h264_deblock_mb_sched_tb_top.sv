// Testbench wrapper for h264_deblock_mb_scheduler.
`default_nettype none

module h264_deblock_mb_sched_tb (
    input  wire              clk,
    input  wire              reset,

    // -- Control --
    input  wire              start,
    output wire              busy,
    output wire              done,

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

    // -- Per-4x4-block metadata --
    input  wire [15:0]       mb_intra,
    input  wire [15:0]       mb_nonzero,
    input  wire signed [11:0] mb_mvx  [0:15],
    input  wire signed [11:0] mb_mvy  [0:15],
    input  wire [1:0]        mb_ref  [0:15],

    // -- Left neighbor --
    input  wire [3:0]        left_intra,
    input  wire [3:0]        left_nonzero,
    input  wire signed [11:0] left_mvx [0:3],
    input  wire signed [11:0] left_mvy [0:3],
    input  wire [1:0]        left_ref [0:3],

    // -- Top neighbor --
    input  wire [3:0]        top_intra,
    input  wire [3:0]        top_nonzero,
    input  wire signed [11:0] top_mvx [0:3],
    input  wire signed [11:0] top_mvy [0:3],
    input  wire [1:0]        top_ref [0:3],

    // -- Sample load --
    input  wire              sample_wr,
    input  wire [7:0]        sample_waddr,
    input  wire [7:0]        sample_wdata,

    // -- Sample read --
    input  wire [7:0]        sample_raddr,
    output wire [7:0]        sample_rdata,

    // -- Chroma sample load --
    input  wire              chroma_wr,
    input  wire [5:0]        chroma_waddr,
    input  wire [7:0]        chroma_wdata,
    input  wire              chroma_sel,

    // -- Chroma sample read --
    input  wire [5:0]        chroma_raddr,
    input  wire              chroma_rsel,
    output wire [7:0]        chroma_rdata,

    // -- Chroma QP --
    input  wire [5:0]        chroma_qp,

    // -- Cycle count --
    output wire [7:0]        cycle_count
);

    h264_deblock_mb_scheduler u_sched (
        .clk(clk),
        .reset(reset),
        .start(start),
        .busy(busy),
        .done(done),
        .disable_idc(disable_idc),
        .qp(qp),
        .alpha_offset(alpha_offset),
        .beta_offset(beta_offset),
        .left_avail(left_avail),
        .top_avail(top_avail),
        .left_same_slice(left_same_slice),
        .top_same_slice(top_same_slice),
        .mb_intra(mb_intra),
        .mb_nonzero(mb_nonzero),
        .mb_mvx(mb_mvx),
        .mb_mvy(mb_mvy),
        .mb_ref(mb_ref),
        .left_intra(left_intra),
        .left_nonzero(left_nonzero),
        .left_mvx(left_mvx),
        .left_mvy(left_mvy),
        .left_ref(left_ref),
        .top_intra(top_intra),
        .top_nonzero(top_nonzero),
        .top_mvx(top_mvx),
        .top_mvy(top_mvy),
        .top_ref(top_ref),
        .sample_wr(sample_wr),
        .sample_waddr(sample_waddr),
        .sample_wdata(sample_wdata),
        .sample_raddr(sample_raddr),
        .sample_rdata(sample_rdata),
        .chroma_wr(chroma_wr),
        .chroma_waddr(chroma_waddr),
        .chroma_wdata(chroma_wdata),
        .chroma_sel(chroma_sel),
        .chroma_raddr(chroma_raddr),
        .chroma_rsel(chroma_rsel),
        .chroma_rdata(chroma_rdata),
        .chroma_qp(chroma_qp),
        .cycle_count(cycle_count)
    );

endmodule

`default_nettype wire
