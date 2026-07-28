// Motion compensation sizing harness - NOT part of the product design.
//
// The block MC path has never had its silicon cost measured, and it cannot be
// measured in the product today: while the decode core's outputs reach no pin,
// Quartus deletes the whole subtree, so Analysis & Synthesis reports it as free.
// Sizing against that number gives a fictitious "it fits".
//
// This top exists only to make the cost measurable now, ahead of the product
// convergence. Every input is driven from a shift register fed by a real pin and
// every output is reduced into a registered pin, so there is no constant to fold
// and no dangling output to delete.
//
// Deliberately outside fpga/Plex_MiSTer/rtl so it is not swept into files.qip
// coverage or product reachability. It is not product RTL and must never be
// reachable from emu.
//
// Scope: h264_inter_mc_part, which instantiates h264_inter_mc_16x16 and through
// it h264_luma_qpel_block_16x16 and h264_chroma_epel_block_8x8, plus
// h264_dpb_one_ref. Five of the seven modules. h264_luma_ref_tap_addr and
// h264_ref_clamp belong to the retired per-sample tap lineage and are sized
// separately if that lineage is kept.
//
// Honest reading of the result: it prices the reference windows and the
// interpolation, and nothing that will drive them. It is a floor, not a quote.

`default_nettype none

module mc_sizing_top #(
    parameter int FRAME_W = 624,
    parameter int FRAME_H = 480
) (
    input  wire clk,
    input  wire reset,
    input  wire serial_in,
    output reg  serial_out
);
    // A pin-fed shift register. Nothing downstream can be constant-folded,
    // because everything depends on serial_in.
    reg [63:0] stim_r;
    always_ff @(posedge clk) begin
        if (reset)
            stim_r <= 64'd1;
        else
            stim_r <= {stim_r[62:0], serial_in ^ stim_r[63]};
    end

    // Reference windows. The block predictor reads these combinationally and in
    // full, so they cannot be inferred as M10K and must land in registers.
    // 441 + 81 + 81 bytes is the number this harness exists to price.
    reg [7:0] luma_win     [0:440];
    reg [7:0] chroma_u_win [0:80];
    reg [7:0] chroma_v_win [0:80];

    integer wi;
    always_ff @(posedge clk) begin
        for (wi = 0; wi < 441; wi = wi + 1)
            luma_win[wi] <= stim_r[7:0] + wi[7:0];
        for (wi = 0; wi < 81; wi = wi + 1) begin
            chroma_u_win[wi] <= stim_r[15:8] + wi[7:0];
            chroma_v_win[wi] <= stim_r[23:16] + wi[7:0];
        end
    end

    wire [7:0] pred_y [0:255];
    wire       pred_y_valid [0:255];
    wire [7:0] pred_u [0:63];
    wire       pred_u_valid [0:63];
    wire [7:0] pred_v [0:63];
    wire       pred_v_valid [0:63];

    h264_inter_mc_part u_mc_part (
        .luma_ref_win(luma_win),
        .chroma_u_ref_win(chroma_u_win),
        .chroma_v_ref_win(chroma_v_win),
        .luma_frac_x(stim_r[25:24]),
        .luma_frac_y(stim_r[27:26]),
        .chroma_frac_x(stim_r[30:28]),
        .chroma_frac_y(stim_r[33:31]),
        .part_w(stim_r[38:34]),
        .part_h(stim_r[43:39]),
        .pred_y(pred_y),
        .pred_y_valid(pred_y_valid),
        .pred_u(pred_u),
        .pred_u_valid(pred_u_valid),
        .pred_v(pred_v),
        .pred_v_valid(pred_v_valid)
    );

    wire        dpb_ref_ready;
    wire [31:0] dpb_current_base;
    wire [31:0] dpb_reference_base;
    wire        dpb_mem_we;
    wire [31:0] dpb_mem_waddr;
    wire [7:0]  dpb_mem_wdata;
    wire        dpb_fetch_busy;
    wire        dpb_fetch_done;
    wire        dpb_fetch_error_no_ref;
    wire [1:0]  dpb_luma_frac_x, dpb_luma_frac_y;
    wire [2:0]  dpb_chroma_frac_x, dpb_chroma_frac_y;
    wire signed [15:0] dpb_luma_origin_x, dpb_luma_origin_y;
    wire signed [15:0] dpb_chroma_origin_x, dpb_chroma_origin_y;
    wire        dpb_mem_rd;
    wire [31:0] dpb_mem_raddr;
    wire        dpb_luma_window_valid;
    wire [8:0]  dpb_luma_window_idx;
    wire [7:0]  dpb_luma_window_sample;
    wire        dpb_chroma_u_window_valid;
    wire        dpb_chroma_v_window_valid;
    wire [6:0]  dpb_chroma_window_idx;
    wire [7:0]  dpb_chroma_window_sample;

    h264_dpb_one_ref #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H)) u_dpb_ref (
        .clk(clk),
        .reset(reset),
        .idr_start(stim_r[44]),
        .frame_done(stim_r[45]),
        .ref_ready(dpb_ref_ready),
        .current_base(dpb_current_base),
        .reference_base(dpb_reference_base),
        .filtered_sample_valid(stim_r[46]),
        .filtered_mb_x(stim_r[7:0]),
        .filtered_mb_y(stim_r[15:8]),
        .filtered_plane(stim_r[17:16]),
        .filtered_sample_idx(stim_r[25:18]),
        .filtered_sample(stim_r[33:26]),
        .mem_we(dpb_mem_we),
        .mem_waddr(dpb_mem_waddr),
        .mem_wdata(dpb_mem_wdata),
        .fetch_start(stim_r[47]),
        .fetch_mb_x(stim_r[41:34]),
        .fetch_mb_y(stim_r[49:42]),
        .fetch_part_mode(stim_r[52:50]),
        .fetch_part_idx(stim_r[54:53]),
        .fetch_part_w(stim_r[59:55]),
        .fetch_part_h(stim_r[63:59]),
        .fetch_mv_x_qpel($signed(stim_r[15:0])),
        .fetch_mv_y_qpel($signed(stim_r[31:16])),
        .fetch_busy(dpb_fetch_busy),
        .fetch_done(dpb_fetch_done),
        .fetch_error_no_ref(dpb_fetch_error_no_ref),
        .luma_frac_x(dpb_luma_frac_x),
        .luma_frac_y(dpb_luma_frac_y),
        .chroma_frac_x(dpb_chroma_frac_x),
        .chroma_frac_y(dpb_chroma_frac_y),
        .luma_origin_x(dpb_luma_origin_x),
        .luma_origin_y(dpb_luma_origin_y),
        .chroma_origin_x(dpb_chroma_origin_x),
        .chroma_origin_y(dpb_chroma_origin_y),
        .mem_rd(dpb_mem_rd),
        .mem_raddr(dpb_mem_raddr),
        .mem_rdata(stim_r[39:32]),
        .mem_rvalid(stim_r[40]),
        .luma_window_valid(dpb_luma_window_valid),
        .luma_window_idx(dpb_luma_window_idx),
        .luma_window_sample(dpb_luma_window_sample),
        .chroma_u_window_valid(dpb_chroma_u_window_valid),
        .chroma_v_window_valid(dpb_chroma_v_window_valid),
        .chroma_window_idx(dpb_chroma_window_idx),
        .chroma_window_sample(dpb_chroma_window_sample)
    );

    // Reduce every output to one pin. An output that reaches no pin is deleted,
    // and a deleted module prices as free; that is the trap this harness exists
    // to avoid, so the reduction must cover all of them.
    integer ri;
    reg mc_fold;
    always_ff @(posedge clk) begin
        mc_fold = 1'b0;
        for (ri = 0; ri < 256; ri = ri + 1)
            mc_fold = mc_fold ^ (^pred_y[ri]) ^ pred_y_valid[ri];
        for (ri = 0; ri < 64; ri = ri + 1)
            mc_fold = mc_fold ^ (^pred_u[ri]) ^ pred_u_valid[ri]
                              ^ (^pred_v[ri]) ^ pred_v_valid[ri];
        serial_out <= mc_fold
            ^ dpb_ref_ready ^ (^dpb_current_base) ^ (^dpb_reference_base)
            ^ dpb_mem_we ^ (^dpb_mem_waddr) ^ (^dpb_mem_wdata)
            ^ dpb_fetch_busy ^ dpb_fetch_done ^ dpb_fetch_error_no_ref
            ^ (^dpb_luma_frac_x) ^ (^dpb_luma_frac_y)
            ^ (^dpb_chroma_frac_x) ^ (^dpb_chroma_frac_y)
            ^ (^dpb_luma_origin_x) ^ (^dpb_luma_origin_y)
            ^ (^dpb_chroma_origin_x) ^ (^dpb_chroma_origin_y)
            ^ dpb_mem_rd ^ (^dpb_mem_raddr)
            ^ dpb_luma_window_valid ^ (^dpb_luma_window_idx)
            ^ (^dpb_luma_window_sample)
            ^ dpb_chroma_u_window_valid ^ dpb_chroma_v_window_valid
            ^ (^dpb_chroma_window_idx) ^ (^dpb_chroma_window_sample);
    end

endmodule

`default_nettype wire
