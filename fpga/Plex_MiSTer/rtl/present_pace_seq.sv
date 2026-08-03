// present_pace_seq — fabric vsync-locked present sequencer (fab-pace)
//
// Default OFF: parameter ENABLE=0 (or leave `PLEX_FAB_PACE` undefined).
// When OFF, behaviour matches legacy ddr_frame_store: swap on every vsync
// that has swap_pending && pending_ready (producer-paced doorbell).
// When ON (`PLEX_FAB_PACE` / ENABLE=1): fabric owns unique-frame release using
// the same floor(n*cf/dh) cadence as present_cadence.sv / cadence.hpp.
//
// Contract (w-mem doorbell writer / this consumer) — see
// docs/present-pace-doorbell-contract.md:
//   - Writer rings swap_req_toggle + publishes pending_bank + pending_ready=1
//     only after the full bank payload is visible to the reader.
//   - This module never swaps except on vsync_pulse (no mid-scan tear).
//   - Late producer: repeat disp_bank (cnt_late/cnt_repeats). Never black.
//   - Early producer: hold pending until cadence advance_unique (cnt_early_hold).
//
// Judder policy (product default, not silent):
//   Fixed display_hz (typically 60) + content_fps (24) → 2:3 pulldown via
//   floor cadence (unique advances 24 times per 60 ticks). Alternative
//   match-source 24/48 Hz rasters are a separate product switch (w-clock /
//   match-source-hz) — not implied by enabling this sequencer.
//
// Multi-pixel present (w-clock): this sequencer is frame-level (vsync), not
// pixel-level. PPC does not change swap timing. plex_chrome sits post-ascal
// on clk_hdmi (1 px/clk today); see docs/present-pace-doorbell-contract.md §chrome.

`timescale 1ns / 1ps

module present_pace_seq #(
    parameter bit ENABLE = 1'b0  // product default OFF — nostub-safe
) (
    input  wire        clk,
    input  wire        reset,

    // 1-cycle pulse at start of display frame (beam frame_start / vsync edge)
    input  wire        vsync_pulse,

    // Doorbell CDC already synced into clk domain by caller (ddr_frame_store style)
    input  wire        swap_req_toggle, // edge vs last seen ⇒ new producer frame
    input  wire        pending_bank,
    input  wire        pending_ready,   // bank fully readable

    input  wire [7:0]  content_fps,     // e.g. 24
    input  wire [7:0]  display_hz,      // e.g. 60

    output reg         do_swap,         // 1-cycle: commit pending → disp this vsync
    output reg         disp_bank,
    output reg         has_frame,
    output reg         swap_pending,

    // Parent-readable counters (sticky until reset)
    output reg [31:0]  cnt_presented,   // successful bank flips
    output reg [31:0]  cnt_repeats,     // vsync kept prior frame (no swap)
    output reg [31:0]  cnt_drops,       // new doorbell while previous still pending
    output reg [31:0]  cnt_late,        // cadence wanted unique but !pending_ready
    output reg [31:0]  cnt_early_hold,  // pending ready but cadence holds
    output reg [31:0]  cnt_vsync,       // total vsync pulses seen
    output reg         advance_unique_mon,
    output reg [31:0]  display_index_mon,
    output reg [31:0]  content_index_mon
);

    // --- cadence (inline copy of present_cadence math; keep in lockstep) ---
    function automatic [31:0] floor_mul;
        input [31:0] n;
        input [7:0]  cf;
        input [7:0]  dh;
        begin
            if (dh == 0)
                floor_mul = n;
            else
                floor_mul = (n * {24'd0, cf}) / {24'd0, dh};
        end
    endfunction

    reg [31:0] display_index;
    reg [31:0] content_index;

    reg        swap_req_seen;
    reg        pending_bank_r;

    // Combinational-style locals for this tick (blocking inside clocked block).
    reg        adv_now;
    reg [31:0] next_content;
    reg [31:0] content_after;
    reg        pending_now;
    reg        bank_now;

    always @(posedge clk) begin
        if (reset) begin
            do_swap            <= 1'b0;
            disp_bank          <= 1'b0;
            has_frame          <= 1'b0;
            swap_pending       <= 1'b0;
            swap_req_seen      <= 1'b0;
            pending_bank_r     <= 1'b0;
            display_index      <= 32'd0;
            content_index      <= 32'd0;
            cnt_presented      <= 32'd0;
            cnt_repeats        <= 32'd0;
            cnt_drops          <= 32'd0;
            cnt_late           <= 32'd0;
            cnt_early_hold     <= 32'd0;
            cnt_vsync          <= 32'd0;
            advance_unique_mon <= 1'b0;
            display_index_mon  <= 32'd0;
            content_index_mon  <= 32'd0;
        end else begin
            do_swap     <= 1'b0;
            pending_now = swap_pending;
            bank_now    = pending_bank_r;

            if (swap_req_toggle != swap_req_seen) begin
                if (swap_pending)
                    cnt_drops <= cnt_drops + 32'd1;
                swap_req_seen  <= swap_req_toggle;
                pending_bank_r <= pending_bank;
                swap_pending   <= 1'b1;
                pending_now    = 1'b1;
                bank_now       = pending_bank;
            end

            if (vsync_pulse) begin
                cnt_vsync <= cnt_vsync + 32'd1;

                if (!ENABLE || content_fps == 8'd0 || display_hz == 8'd0 ||
                    content_fps >= display_hz) begin
                    adv_now       = 1'b1;
                    content_after = content_index + 32'd1;
                end else begin
                    next_content = floor_mul(display_index, content_fps, display_hz);
                    if (display_index == 32'd0 || next_content != content_index) begin
                        adv_now       = 1'b1;
                        content_after = next_content;
                    end else begin
                        adv_now       = 1'b0;
                        content_after = content_index;
                    end
                end
                content_index <= content_after;
                display_index <= display_index + 32'd1;

                if (!ENABLE) begin
                    if (pending_now && pending_ready) begin
                        do_swap       <= 1'b1;
                        disp_bank     <= bank_now;
                        has_frame     <= 1'b1;
                        swap_pending  <= 1'b0;
                        cnt_presented <= cnt_presented + 32'd1;
                    end else begin
                        cnt_repeats <= cnt_repeats + 32'd1;
                        if (pending_now && !pending_ready)
                            cnt_late <= cnt_late + 32'd1;
                    end
                end else if (adv_now) begin
                    if (pending_now && pending_ready) begin
                        do_swap       <= 1'b1;
                        disp_bank     <= bank_now;
                        has_frame     <= 1'b1;
                        swap_pending  <= 1'b0;
                        cnt_presented <= cnt_presented + 32'd1;
                    end else begin
                        cnt_repeats <= cnt_repeats + 32'd1;
                        cnt_late    <= cnt_late + 32'd1;
                    end
                end else begin
                    cnt_repeats <= cnt_repeats + 32'd1;
                    if (pending_now && pending_ready)
                        cnt_early_hold <= cnt_early_hold + 32'd1;
                end

                advance_unique_mon <= adv_now;
                display_index_mon  <= display_index + 32'd1;
                content_index_mon  <= content_after;
            end
        end
    end

endmodule
