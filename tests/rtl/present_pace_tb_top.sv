// Dual instance: ENABLE=0 and ENABLE=1 behind enable_sel mux for TB.
`timescale 1ns / 1ps

module present_pace_tb (
    input  wire        clk,
    input  wire        reset,
    input  wire        vsync_pulse,
    input  wire        swap_req_toggle,
    input  wire        pending_bank,
    input  wire        pending_ready,
    input  wire [7:0]  content_fps,
    input  wire [7:0]  display_hz,
    input  wire        enable_sel, // 0→read off, 1→read on (both always run)

    output wire        do_swap_off,
    output wire [31:0] cnt_presented_off,
    output wire        do_swap_on,
    output wire [31:0] cnt_presented_on,
    output wire [31:0] cnt_late_on,
    output wire [31:0] cnt_early_hold_on,
    output wire [31:0] cnt_vsync_on
);

    present_pace_seq #(.ENABLE(1'b0)) u_off (
        .clk(clk),
        .reset(reset),
        .vsync_pulse(vsync_pulse),
        .swap_req_toggle(swap_req_toggle),
        .pending_bank(pending_bank),
        .pending_ready(pending_ready),
        .content_fps(content_fps),
        .display_hz(display_hz),
        .do_swap(do_swap_off),
        .disp_bank(),
        .has_frame(),
        .swap_pending(),
        .cnt_presented(cnt_presented_off),
        .cnt_repeats(),
        .cnt_drops(),
        .cnt_late(),
        .cnt_early_hold(),
        .cnt_vsync(),
        .advance_unique_mon(),
        .display_index_mon(),
        .content_index_mon()
    );

    present_pace_seq #(.ENABLE(1'b1)) u_on (
        .clk(clk),
        .reset(reset),
        .vsync_pulse(vsync_pulse),
        .swap_req_toggle(swap_req_toggle),
        .pending_bank(pending_bank),
        .pending_ready(pending_ready),
        .content_fps(content_fps),
        .display_hz(display_hz),
        .do_swap(do_swap_on),
        .disp_bank(),
        .has_frame(),
        .swap_pending(),
        .cnt_presented(cnt_presented_on),
        .cnt_repeats(),
        .cnt_drops(),
        .cnt_late(cnt_late_on),
        .cnt_early_hold(cnt_early_hold_on),
        .cnt_vsync(cnt_vsync_on),
        .advance_unique_mon(),
        .display_index_mon(),
        .content_index_mon()
    );

    wire _unused = enable_sel;

endmodule
