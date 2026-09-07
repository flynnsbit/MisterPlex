// Two 256x16 one-bit text banks, not a frame buffer. The only write port is the
// overlay ioctl plane: decoded/reference pixels never enter writable storage.
// hps_io WIDE=0 receives one low byte per 16-bit SPI transaction, byte addresses.
module playback_overlay_plane (
    input  wire        clk_sys,
    input  wire        reset,
    input  wire        session_active,
    input  wire [63:0] session_epoch,
    input  wire [63:0] session_nonce,
    input  wire        ioctl_download,
    input  wire [15:0] ioctl_index,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    output wire        ioctl_wait,
    output reg  [31:0] accepted_sequence,
    output reg  [31:0] rejected_packets,
    input  wire        clk_pix,
    input  wire        ce_in,
    input  wire [7:0]  r_in, g_in, b_in,
    input  wire        hs_in, vs_in, de_in,
    output reg         ce_out,
    output reg  [7:0]  r_out, g_out, b_out,
    output reg         hs_out, vs_out, de_out,
    output wire        visible
);
    localparam [26:0] PACKET_BYTES = 27'd576;
    localparam [26:0] HEADER_BYTES = 27'd64;
    reg [7:0] text_ram [0:1023];
    reg [511:0] rx_header;
    reg [511:0] held_header;
    reg [511:0] active_header;
    reg request, acknowledge;
    (* async_reg = "true" *) reg ack_meta, ack_sync;
    (* async_reg = "true" *) reg req_meta, req_sync;
    (* async_reg = "true" *) reg block_meta, block_sync;
    reg held_fence;
    reg fence_active;
    reg invalidation_pending;
    reg [63:0] fence_epoch, fence_nonce;
    wire identity_changed = session_active != fence_active ||
                            session_epoch != fence_epoch || session_nonce != fence_nonce;
    wire fence_dirty = invalidation_pending || identity_changed;
    wire pending = request != ack_sync;
    wire block_pixels = !session_active || fence_dirty || (pending && held_fence);
    wire selected = ioctl_download && ioctl_index == 16'd6;
    wire identity_valid = session_active && session_epoch != 0 && session_nonce != 0;
    wire ready = !pending && !fence_dirty && identity_valid;
    reg downloading, receiving, malformed;
    reg [10:0] received;
    // A stopped/invalid session cannot become ready by waiting. Drain it (and
    // already rejected transfers); only live ownership handshakes may stall HPS.
    assign ioctl_wait = selected && !reset && identity_valid &&
                        !(downloading && malformed) && (pending || fence_dirty);
    wire [31:0] rx_sequence = rx_header[192 +: 32];
    wire valid_header =
        rx_header[0 +: 32] == 32'h314f504d &&
        rx_header[32 +: 16] == 16'd1 &&
        rx_header[48 +: 16] == 16'd576 &&
        rx_header[64 +: 64] == session_epoch &&
        rx_header[128 +: 64] == session_nonce &&
        rx_sequence != 0 && rx_sequence > accepted_sequence &&
        rx_header[224 +: 16] <= 16'd31 &&
        rx_header[240 +: 8] <= 8'd4 &&
        (rx_header[248 +: 8] == 8'd1 || rx_header[248 +: 8] == 8'd2 ||
         rx_header[248 +: 8] == 8'd4) &&
        rx_header[256 +: 16] <= 16'd2047 &&
        rx_header[272 +: 16] <= 16'd2047 &&
        rx_header[288 +: 16] <= rx_header[416 +: 16] &&
        rx_header[304 +: 16] == 0 &&
        rx_header[344 +: 8] == 0 && rx_header[376 +: 8] == 0 &&
        rx_header[408 +: 8] == 0 &&
        rx_header[416 +: 16] != 0 && rx_header[416 +: 16] <= 16'd256 &&
        (!rx_header[228] || rx_header[416 +: 16] == 16'd256) &&
        rx_header[432 +: 16] == 16'd24 &&
        rx_header[448 +: 32] == 32'h544d434f &&
        rx_header[480 +: 32] == ~rx_sequence;

    always @(posedge clk_sys) begin
        if (reset) begin
            request <= 0;
            ack_meta <= 0; ack_sync <= 0;
            held_header <= 0; held_fence <= 0;
            fence_active <= 0; fence_epoch <= 0; fence_nonce <= 0;
            invalidation_pending <= 0;
            downloading <= 0; receiving <= 0; malformed <= 0;
            received <= 0; rx_header <= 0;
            accepted_sequence <= 0; rejected_packets <= 0;
        end else begin
            ack_meta <= acknowledge;
            ack_sync <= ack_meta;
            downloading <= selected;
            // Flush can deassert active for one sys cycle while the descriptor
            // mailbox is busy. Retain it even if the same identity resumes
            // before that descriptor's ACK or before the pixel clock advances.
            if (identity_changed)
                invalidation_pending <= 1;
            if (fence_dirty && !pending) begin
                // The same held-bus mailbox carries clears. A stale in-flight
                // descriptor is masked until this clear is acknowledged.
                held_header <= 0;
                held_fence <= 1;
                invalidation_pending <= 0;
                request <= ~request;
                fence_active <= session_active;
                fence_epoch <= session_epoch;
                fence_nonce <= session_nonce;
                if (session_epoch != fence_epoch || session_nonce != fence_nonce)
                    accepted_sequence <= 0;
            end
            if (selected && !downloading) begin
                receiving <= 0;
                malformed <= 0;
                received <= 0;
                rx_header <= 0;
            end
            if (selected && downloading && receiving && !ready)
                malformed <= 1;
            if (selected && ioctl_wr) begin
                // A wait-honoring sender may assert download before the bank
                // is available. Acquire reception on its first accepted byte.
                if (ready && (!downloading || !malformed) &&
                    ioctl_addr == (downloading ? {16'd0, received} : 27'd0) &&
                    ioctl_addr < PACKET_BYTES) begin
                    receiving <= 1;
                    if (ioctl_addr < HEADER_BYTES)
                        rx_header[ioctl_addr[5:0]*8 +: 8] <= ioctl_dout;
                    received <= (downloading ? received : 11'd0) + 11'd1;
                end else begin
                    malformed <= 1;
                end
            end
            if (downloading && !selected) begin
                receiving <= 0;
                if (receiving && !malformed && received == 11'd576 &&
                    ready && valid_header) begin
                    held_header <= rx_header;
                    held_fence <= 0;
                    request <= ~request;
                    accepted_sequence <= rx_sequence;
                end else begin
                    rejected_packets <= rejected_packets + 32'd1;
                end
            end
        end
    end

    // Keep reset logic out of the RAM processes to permit dual-clock M10K
    // inference. An uncommitted bank is never displayed, including after reset.
    wire [8:0] write_offset = ioctl_addr[8:0] - 9'd64;
    always @(posedge clk_sys) begin
        if (!reset && selected && ioctl_wr && receiving && downloading &&
            !malformed && ready && ioctl_addr == {16'd0, received} &&
            ioctl_addr >= HEADER_BYTES && ioctl_addr < PACKET_BYTES)
            text_ram[{~request, write_offset}] <= ioctl_dout;
    end

    reg [11:0] beam_x, beam_y;
    reg [11:0] measured_width, viewport_width, viewport_height;
    reg de_previous, vs_previous;
    wire frame_edge = ce_in && vs_in && !vs_previous;
    wire [11:0] pixel_x = de_previous ? beam_x : 12'd0;
    wire auto_fit = active_header[228];
    wire [15:0] view_w = {4'd0, viewport_width};
    wire [15:0] view_h = {4'd0, viewport_height};
    wire viewport_valid = view_w >= 16'd6 && view_h >= 16'd24;
    wire [15:0] margin_x = view_w >= 16'd128 ? 16'd8 : view_w >> 4;
    wire [15:0] margin_y_pre = view_h >= 16'd128 ? 16'd8 : view_h >> 4;
    wire [15:0] margin_y = view_h < 16'd24 ? 16'd0 :
                          margin_y_pre > view_h - 16'd24 ? view_h - 16'd24 :
                          margin_y_pre;
    wire [15:0] available_w = view_w - (margin_x << 1);
    wire [15:0] available_h = view_h - margin_y;
    wire [1:0] auto_scale = available_w >= 16'd1024 && available_h >= 16'd96 ? 2'd2 :
                           available_w >= 16'd512 && available_h >= 16'd48 ? 2'd1 : 2'd0;
    wire [15:0] auto_width = (available_w >> auto_scale) >= 16'd256 ? 16'd256 :
                            available_w >> auto_scale;
    wire [15:0] origin_x = auto_fit ? (view_w - (auto_width << auto_scale)) >> 1 :
                                     active_header[256 +: 16];
    wire [15:0] origin_y = auto_fit ? available_h - (16'd24 << auto_scale) :
                                     active_header[272 +: 16];
    wire [15:0] delta_x = {4'd0, pixel_x} - origin_x;
    wire [15:0] delta_y = {4'd0, beam_y} - origin_y;
    wire [1:0] scale_shift = auto_fit ? auto_scale :
                             active_header[248 +: 8] == 8'd4 ? 2'd2 :
                             active_header[248 +: 8] == 8'd2 ? 2'd1 : 2'd0;
    wire [15:0] panel_width = auto_fit ? auto_width : active_header[416 +: 16];
    wire [17:0] scaled_progress = active_header[288 +: 9] * auto_width[8:0];
    wire [15:0] panel_progress = auto_fit ? {6'd0, scaled_progress[17:8]} :
                                          active_header[288 +: 16];
    wire [15:0] local_x = delta_x >> scale_shift;
    wire [15:0] local_y = delta_y >> scale_shift;
    reg active_bank;
    reg active_visible;
    assign visible = active_visible && !block_sync && (!auto_fit || viewport_valid);
    wire in_panel = visible && de_in && {4'd0, pixel_x} >= origin_x &&
                    {4'd0, beam_y} >= origin_y &&
                    local_x < panel_width &&
                    local_y < 16'd24;
    wire text_region = local_y < 16'd8 ? active_header[225] :
                       local_y < 16'd16 && active_header[226];
    wire progress_region = local_y >= 16'd20 && local_y < 16'd23 &&
                           active_header[227];
    wire [9:0] read_address = {active_bank, local_y[3:0], local_x[7:3]};
    reg [7:0] text_byte;
    always @(posedge clk_pix) begin
        if (ce_in)
            text_byte <= text_ram[read_address];
    end

    reg stage_valid, stage_hs, stage_vs, stage_de;
    reg [23:0] stage_rgb, stage_fg, stage_bg, stage_accent;
    reg stage_text, stage_progress, stage_fill;
    reg [2:0] stage_bit;
    always @(posedge clk_pix) begin
        if (reset) begin
            req_meta <= 0; req_sync <= 0; acknowledge <= 0;
            block_meta <= 1; block_sync <= 1;
            active_header <= 0; active_visible <= 0; active_bank <= 0;
            beam_x <= 0; beam_y <= 0; de_previous <= 0; vs_previous <= 0;
            measured_width <= 0; viewport_width <= 0; viewport_height <= 0;
            stage_valid <= 0;
            stage_hs <= 0; stage_vs <= 0; stage_de <= 0;
            stage_rgb <= 0; stage_fg <= 0; stage_bg <= 0; stage_accent <= 0;
            stage_text <= 0; stage_progress <= 0; stage_fill <= 0; stage_bit <= 0;
            ce_out <= 0; r_out <= 0; g_out <= 0; b_out <= 0;
            hs_out <= 0; vs_out <= 0; de_out <= 0;
        end else begin
            req_meta <= request;
            req_sync <= req_meta;
            block_meta <= block_pixels;
            block_sync <= block_meta;
            if (block_sync)
                active_visible <= 0;
            if (frame_edge && req_sync != acknowledge) begin
                // Bundled-data CDC: held_header and its RAM bank are stable
                // before the synchronized request and through returned ACK.
                active_header <= held_header;
                active_bank <= req_sync;
                active_visible <= held_header[224] && held_header[240 +: 8] != 0 &&
                                  !block_sync;
                acknowledge <= req_sync;
            end
            if (ce_in) begin
                vs_previous <= vs_in;
                de_previous <= de_in;
                if (frame_edge) begin
                    // Measure actual DE, not decoded storage or an assumed
                    // scandoubler mode. Geometry is coherent for the next frame.
                    if (measured_width != 0 && beam_y != 0) begin
                        viewport_width <= measured_width;
                        viewport_height <= beam_y;
                    end
                    measured_width <= 0;
                    beam_x <= 0;
                    beam_y <= 0;
                end else begin
                    beam_x <= de_in ? pixel_x + 12'd1 : 12'd0;
                    if (!de_in && de_previous) begin
                        beam_y <= beam_y + 12'd1;
                        if (beam_x > measured_width)
                            measured_width <= beam_x;
                    end
                end
            end
            stage_valid <= ce_in;
            if (ce_in) begin
                stage_rgb <= {r_in, g_in, b_in};
                stage_hs <= hs_in; stage_vs <= vs_in; stage_de <= de_in;
                stage_fg <= active_header[320 +: 24];
                stage_bg <= active_header[352 +: 24];
                stage_accent <= active_header[384 +: 24];
                stage_bit <= ~local_x[2:0];
                stage_text <= in_panel && text_region;
                stage_progress <= in_panel && progress_region;
                stage_fill <= local_x < panel_progress;
            end
            // All RGB/sync/DE signals have the same two-register latency, even
            // when hidden. Do not bypass only the RGB half of this pipeline.
            ce_out <= stage_valid;
            if (stage_valid) begin
                hs_out <= stage_hs; vs_out <= stage_vs; de_out <= stage_de;
                if (stage_text && !block_sync)
                    {r_out, g_out, b_out} <= text_byte[stage_bit] ? stage_fg : stage_bg;
                else if (stage_progress && !block_sync)
                    {r_out, g_out, b_out} <= stage_fill ? stage_accent : stage_bg;
                else
                    {r_out, g_out, b_out} <= stage_rgb;
            end
        end
    end
endmodule
