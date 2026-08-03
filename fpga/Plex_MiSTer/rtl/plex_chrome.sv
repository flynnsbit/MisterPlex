// plex_chrome — post-ascal player chrome + fabric idle plane
//
// Owner: w-osd · 720p is the target, not a later bolt-on.
// Insertion (sys_top.v HDMI path):
//   ascal → shadowmask → plex_chrome → osd hdmi_osd → pins
//
// Geometry: HDMI_WIDTH/HEIGHT are 12-bit (0..4095) — covers 1280×720 and 1920×1080.
// No line buffers: a 720p luma line is exactly one M10K; we refuse that cost by
// scanning the command list per pixel instead of buffering a scanline.
// body_scale from HDMI_HEIGHT (half-even /240, clamp 2..8) → scale=3 @720p.
//
// ARM: semantic PLXC list only (doorbell + 0x130 / list @ +0x140). Never pixels.
// When cfg_enable=0 and idle_en=0, video passes through unmodified (1-cycle delay).
//
// Multi-pixel (w-clock present_beam_ppc / route-B 720p scanout):
//   parameter PX_PER_CLK ∈ {1,2,4}. Default 1 = product path today (sys_top 1ppc).
//   din/dout are PX_PER_CLK×24b packed little-endian lane0 in [23:0].
//   Each lane composites at hx0+lane independently (glyph/rect/idle). Pre-ascal
//   PPC on clk_sys does not require this module until N-pixel reaches clk_hdmi.
//
// Cmd pack (64-bit LE, host + RTL):
//   [7:0]   op     0=END 1=RECT 2=GLYPH 3=RECT_PAL
//   [23:8]  x      output pixels
//   [39:24] y
//   GLYPH:  [47:40]=ascii code
//   RECT:   [51:40]=w12  [63:52]=h12   fill=24'h14_14_28
//   RECT_PAL:[47:40]=w8  [55:48]=h8  [63:56]=pal_idx
//            pal 0=panel 1=track 2=amber 3=white 4=edge
//
// Budget (prereg, post nostub reclaim free M10K ~356):
//   list 2×48×64b ≈ 6 kbit → 1–2 M10K consolidated (not 48 tiny RAMs)
//   font ROM combinational (no M10K)
//   idle chevron pure math (0 M10K)
//   ALM: hit scan + idle ~1.5–3k (HIT_SCAN=MAX_CMDS so 720p HUD is fully visible)

`timescale 1ns / 1ps

module plex_chrome #(
    parameter int MAX_CMDS = 48,
    parameter int HIT_SCAN = 48, // == MAX_CMDS: full list visible @720p HUD budget
    parameter int FONT_W   = 8,
    parameter int FONT_H   = 8,
    parameter bit BOOT_DEMO = 1'b0,
    parameter int PX_PER_CLK = 1  // 1|2|4 — default 1 product-safe
) (
    input  wire        clk_hdmi,
    input  wire        reset,

    input  wire [11:0] HDMI_WIDTH,
    input  wire [11:0] HDMI_HEIGHT,

    input  wire [PX_PER_CLK*24-1:0] din,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    output reg  [PX_PER_CLK*24-1:0] dout,
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,

    input  wire        cfg_enable,
    input  wire [15:0] cfg_seq,
    input  wire [7:0]  cfg_cmd_count,
    input  wire        list_we,
    input  wire [7:0]  list_waddr,
    input  wire [63:0] list_wdata,

    input  wire        idle_en,
    input  wire [1:0]  idle_mode,
    input  wire [15:0] idle_phase,
    // Fabric-only signature (cyan corner brackets). ARM idle never paints this.
    // Parent scores CYAN_PX to distinguish fabric from daemon idle.
    input  wire        idle_sig_en,

    output reg         chrome_hw,
    output reg  [11:0] mon_width,
    output reg  [11:0] mon_height,
    output reg  [3:0]  mon_body_scale
);

    function automatic [3:0] body_scale_f(input [11:0] h);
        reg [11:0] q, r;
        reg [4:0]  raw;
        begin
            q   = h / 12'd240;
            r   = h % 12'd240;
            raw = q[4:0];
            if (r > 12'd120)
                raw = q[4:0] + 5'd1;
            else if (r == 12'd120)
                raw = q[0] ? (q[4:0] + 5'd1) : q[4:0];
            if (raw < 5'd2) raw = 5'd2;
            if (raw > 5'd8) raw = 5'd8;
            body_scale_f = raw[3:0];
        end
    endfunction

    wire [3:0] body_scale = body_scale_f(HDMI_HEIGHT);

    always @(posedge clk_hdmi) begin
        chrome_hw      <= 1'b1;
        mon_width      <= HDMI_WIDTH;
        mon_height     <= HDMI_HEIGHT;
        mon_body_scale <= body_scale;
    end

    function automatic [7:0] inv_sc_q8(input [3:0] sc);
        case (sc)
            4'd2: inv_sc_q8 = 8'd128;
            4'd3: inv_sc_q8 = 8'd85;
            4'd4: inv_sc_q8 = 8'd64;
            4'd5: inv_sc_q8 = 8'd51;
            4'd6: inv_sc_q8 = 8'd43;
            4'd7: inv_sc_q8 = 8'd36;
            4'd8: inv_sc_q8 = 8'd32;
            default: inv_sc_q8 = 8'd128;
        endcase
    endfunction

    function automatic [11:0] div_by_scale(input [11:0] v, input [3:0] sc);
        reg [19:0] prod;
        begin
            prod = {8'd0, v} * {12'd0, inv_sc_q8(sc)};
            div_by_scale = prod[19:8];
        end
    endfunction

    function automatic [7:0] font_row(input [7:0] code, input [2:0] row);
        reg [7:0] ch;
        reg [7:0] bits;
        begin
            ch = code;
            if (ch >= "a" && ch <= "z")
                ch = ch - 8'd32;
            bits = 8'h00;
            case (ch)
                " ": bits = 8'h00;
                "0": case (row)
                    0: bits=8'h7C; 1: bits=8'hC6; 2: bits=8'hCE; 3: bits=8'hD6;
                    4: bits=8'hE6; 5: bits=8'hC6; 6: bits=8'h7C; default: bits=8'h00;
                endcase
                "1": case (row)
                    0: bits=8'h18; 1: bits=8'h38; 2: bits=8'h18; 3: bits=8'h18;
                    4: bits=8'h18; 5: bits=8'h18; 6: bits=8'h7E; default: bits=8'h00;
                endcase
                "2": case (row)
                    0: bits=8'h7C; 1: bits=8'hC6; 2: bits=8'h06; 3: bits=8'h1C;
                    4: bits=8'h70; 5: bits=8'hC0; 6: bits=8'hFE; default: bits=8'h00;
                endcase
                "3": case (row)
                    0: bits=8'h7C; 1: bits=8'hC6; 2: bits=8'h06; 3: bits=8'h3C;
                    4: bits=8'h06; 5: bits=8'hC6; 6: bits=8'h7C; default: bits=8'h00;
                endcase
                "4": case (row)
                    0: bits=8'h1C; 1: bits=8'h3C; 2: bits=8'h6C; 3: bits=8'hCC;
                    4: bits=8'hFE; 5: bits=8'h0C; 6: bits=8'h0C; default: bits=8'h00;
                endcase
                "5": case (row)
                    0: bits=8'hFE; 1: bits=8'hC0; 2: bits=8'hFC; 3: bits=8'h06;
                    4: bits=8'h06; 5: bits=8'hC6; 6: bits=8'h7C; default: bits=8'h00;
                endcase
                "6": case (row)
                    0: bits=8'h3C; 1: bits=8'h60; 2: bits=8'hC0; 3: bits=8'hFC;
                    4: bits=8'hC6; 5: bits=8'hC6; 6: bits=8'h7C; default: bits=8'h00;
                endcase
                "7": case (row)
                    0: bits=8'hFE; 1: bits=8'h06; 2: bits=8'h0C; 3: bits=8'h18;
                    4: bits=8'h30; 5: bits=8'h30; 6: bits=8'h30; default: bits=8'h00;
                endcase
                "8": case (row)
                    0: bits=8'h7C; 1: bits=8'hC6; 2: bits=8'hC6; 3: bits=8'h7C;
                    4: bits=8'hC6; 5: bits=8'hC6; 6: bits=8'h7C; default: bits=8'h00;
                endcase
                "9": case (row)
                    0: bits=8'h7C; 1: bits=8'hC6; 2: bits=8'hC6; 3: bits=8'h7E;
                    4: bits=8'h06; 5: bits=8'h0C; 6: bits=8'h78; default: bits=8'h00;
                endcase
                ":": case (row)
                    0: bits=8'h00; 1: bits=8'h18; 2: bits=8'h18; 3: bits=8'h00;
                    4: bits=8'h18; 5: bits=8'h18; 6: bits=8'h00; default: bits=8'h00;
                endcase
                "-": case (row)
                    0: bits=8'h00; 1: bits=8'h00; 2: bits=8'h00; 3: bits=8'h7E;
                    4: bits=8'h00; 5: bits=8'h00; 6: bits=8'h00; default: bits=8'h00;
                endcase
                ".": case (row)
                    0: bits=8'h00; 1: bits=8'h00; 2: bits=8'h00; 3: bits=8'h00;
                    4: bits=8'h00; 5: bits=8'h18; 6: bits=8'h18; default: bits=8'h00;
                endcase
                "/": case (row)
                    0: bits=8'h06; 1: bits=8'h0C; 2: bits=8'h18; 3: bits=8'h30;
                    4: bits=8'h60; 5: bits=8'hC0; 6: bits=8'h80; default: bits=8'h00;
                endcase
                "A": case (row)
                    0: bits=8'h38; 1: bits=8'h6C; 2: bits=8'hC6; 3: bits=8'hC6;
                    4: bits=8'hFE; 5: bits=8'hC6; 6: bits=8'hC6; default: bits=8'h00;
                endcase
                "B": case (row)
                    0: bits=8'hFC; 1: bits=8'hC6; 2: bits=8'hC6; 3: bits=8'hFC;
                    4: bits=8'hC6; 5: bits=8'hC6; 6: bits=8'hFC; default: bits=8'h00;
                endcase
                "C": case (row)
                    0: bits=8'h7C; 1: bits=8'hC6; 2: bits=8'hC0; 3: bits=8'hC0;
                    4: bits=8'hC0; 5: bits=8'hC6; 6: bits=8'h7C; default: bits=8'h00;
                endcase
                "D": case (row)
                    0: bits=8'hF8; 1: bits=8'hCC; 2: bits=8'hC6; 3: bits=8'hC6;
                    4: bits=8'hC6; 5: bits=8'hCC; 6: bits=8'hF8; default: bits=8'h00;
                endcase
                "E": case (row)
                    0: bits=8'hFE; 1: bits=8'hC0; 2: bits=8'hC0; 3: bits=8'hFC;
                    4: bits=8'hC0; 5: bits=8'hC0; 6: bits=8'hFE; default: bits=8'h00;
                endcase
                "F": case (row)
                    0: bits=8'hFE; 1: bits=8'hC0; 2: bits=8'hC0; 3: bits=8'hFC;
                    4: bits=8'hC0; 5: bits=8'hC0; 6: bits=8'hC0; default: bits=8'h00;
                endcase
                "G": case (row)
                    0: bits=8'h7C; 1: bits=8'hC6; 2: bits=8'hC0; 3: bits=8'hCE;
                    4: bits=8'hC6; 5: bits=8'hC6; 6: bits=8'h7C; default: bits=8'h00;
                endcase
                "H": case (row)
                    0: bits=8'hC6; 1: bits=8'hC6; 2: bits=8'hC6; 3: bits=8'hFE;
                    4: bits=8'hC6; 5: bits=8'hC6; 6: bits=8'hC6; default: bits=8'h00;
                endcase
                "I": case (row)
                    0: bits=8'h7E; 1: bits=8'h18; 2: bits=8'h18; 3: bits=8'h18;
                    4: bits=8'h18; 5: bits=8'h18; 6: bits=8'h7E; default: bits=8'h00;
                endcase
                "K": case (row)
                    0: bits=8'hC6; 1: bits=8'hCC; 2: bits=8'hD8; 3: bits=8'hF0;
                    4: bits=8'hD8; 5: bits=8'hCC; 6: bits=8'hC6; default: bits=8'h00;
                endcase
                "L": case (row)
                    0: bits=8'hC0; 1: bits=8'hC0; 2: bits=8'hC0; 3: bits=8'hC0;
                    4: bits=8'hC0; 5: bits=8'hC0; 6: bits=8'hFE; default: bits=8'h00;
                endcase
                "M": case (row)
                    0: bits=8'hC6; 1: bits=8'hEE; 2: bits=8'hFE; 3: bits=8'hD6;
                    4: bits=8'hC6; 5: bits=8'hC6; 6: bits=8'hC6; default: bits=8'h00;
                endcase
                "N": case (row)
                    0: bits=8'hC6; 1: bits=8'hE6; 2: bits=8'hF6; 3: bits=8'hDE;
                    4: bits=8'hCE; 5: bits=8'hC6; 6: bits=8'hC6; default: bits=8'h00;
                endcase
                "O": case (row)
                    0: bits=8'h7C; 1: bits=8'hC6; 2: bits=8'hC6; 3: bits=8'hC6;
                    4: bits=8'hC6; 5: bits=8'hC6; 6: bits=8'h7C; default: bits=8'h00;
                endcase
                "P": case (row)
                    0: bits=8'hFC; 1: bits=8'hC6; 2: bits=8'hC6; 3: bits=8'hFC;
                    4: bits=8'hC0; 5: bits=8'hC0; 6: bits=8'hC0; default: bits=8'h00;
                endcase
                "R": case (row)
                    0: bits=8'hFC; 1: bits=8'hC6; 2: bits=8'hC6; 3: bits=8'hFC;
                    4: bits=8'hD8; 5: bits=8'hCC; 6: bits=8'hC6; default: bits=8'h00;
                endcase
                "S": case (row)
                    0: bits=8'h7C; 1: bits=8'hC6; 2: bits=8'hC0; 3: bits=8'h7C;
                    4: bits=8'h06; 5: bits=8'hC6; 6: bits=8'h7C; default: bits=8'h00;
                endcase
                "T": case (row)
                    0: bits=8'hFE; 1: bits=8'h18; 2: bits=8'h18; 3: bits=8'h18;
                    4: bits=8'h18; 5: bits=8'h18; 6: bits=8'h18; default: bits=8'h00;
                endcase
                "U": case (row)
                    0: bits=8'hC6; 1: bits=8'hC6; 2: bits=8'hC6; 3: bits=8'hC6;
                    4: bits=8'hC6; 5: bits=8'hC6; 6: bits=8'h7C; default: bits=8'h00;
                endcase
                "W": case (row)
                    0: bits=8'hC6; 1: bits=8'hC6; 2: bits=8'hC6; 3: bits=8'hD6;
                    4: bits=8'hFE; 5: bits=8'hEE; 6: bits=8'hC6; default: bits=8'h00;
                endcase
                "Y": case (row)
                    0: bits=8'hC6; 1: bits=8'hC6; 2: bits=8'h6C; 3: bits=8'h38;
                    4: bits=8'h18; 5: bits=8'h18; 6: bits=8'h18; default: bits=8'h00;
                endcase
                "#", 8'h23: bits = 8'hFF;
                default: bits = 8'h00;
            endcase
            font_row = bits;
        end
    endfunction

    function automatic [23:0] pal_rgb(input [7:0] idx);
        case (idx)
            8'd0: pal_rgb = 24'h14_14_28;
            8'd1: pal_rgb = 24'h3A_3F_48;
            8'd2: pal_rgb = 24'hFF_B2_20;
            8'd3: pal_rgb = 24'hEB_EE_F4;
            8'd4: pal_rgb = 24'h46_4A_52;
            8'd5: pal_rgb = 24'h1F_23_26;
            8'd6: pal_rgb = 24'hE5_A0_0D;
            default: pal_rgb = 24'h14_14_28;
        endcase
    endfunction

    (* ramstyle = "no_rw_check, M10K" *) (* noprune *) (* preserve *)
    reg [63:0] list_a [0:MAX_CMDS-1];
    (* ramstyle = "no_rw_check, M10K" *) (* noprune *) (* preserve *)
    reg [63:0] list_b [0:MAX_CMDS-1];
    reg        live_bank;
    reg [15:0] latched_seq;
    reg [7:0]  latched_count;
    reg        latched_en;

    localparam [63:0] BOOT_DEMO_CMD =
        {8'h00, 8'h00, 8'h23, 16'd64, 16'd64, 8'd2};

    integer li;
    initial begin
        for (li = 0; li < MAX_CMDS; li = li + 1) begin
            list_a[li] = 64'd0;
            list_b[li] = 64'd0;
        end
        if (BOOT_DEMO) begin
            list_a[0]     = BOOT_DEMO_CMD;
            live_bank     = 1'b0;
            latched_seq   = 16'd1;
            latched_count = 8'd1;
            latched_en    = 1'b1;
        end else begin
            live_bank     = 1'b0;
            latched_seq   = 16'd0;
            latched_count = 8'd0;
            latched_en    = 1'b0;
        end
    end

    localparam int AW = $clog2(MAX_CMDS);

    always @(posedge clk_hdmi) begin
        if (list_we && (list_waddr < MAX_CMDS[7:0])) begin
            if (live_bank)
                list_a[list_waddr[AW-1:0]] <= list_wdata;
            else
                list_b[list_waddr[AW-1:0]] <= list_wdata;
        end
    end

    reg vs_d;
    always @(posedge clk_hdmi) begin
        vs_d <= vs_in;
        if (reset) begin
            if (BOOT_DEMO) begin
                latched_en    <= 1'b1;
                latched_seq   <= 16'd1;
                latched_count <= 8'd1;
                live_bank     <= 1'b0;
            end else begin
                latched_en    <= 1'b0;
                latched_seq   <= 16'd0;
                latched_count <= 8'd0;
                live_bank     <= 1'b0;
            end
        end else if (vs_in && !vs_d) begin
            if (cfg_seq != latched_seq) begin
                latched_seq   <= cfg_seq;
                latched_count <= (cfg_cmd_count > MAX_CMDS[7:0]) ? MAX_CMDS[7:0]
                                                                : cfg_cmd_count;
                latched_en    <= cfg_enable;
                live_bank     <= ~live_bank;
            end
        end
    end

    // Pixel coords: hx0 is leftmost lane of this beat. Advance by PX_PER_CLK.
    // 1-cycle dout pipeline pairs hit with the same din sample.
    localparam [11:0] PPC = PX_PER_CLK[11:0];
    reg        de_d;
    reg [11:0] x_cnt, y_cnt;
    wire [11:0] hx0 = de_in ? (de_d ? (x_cnt + PPC) : 12'd0) : 12'd0;
    wire [11:0] hy  = y_cnt;

    always @(posedge clk_hdmi) begin
        if (reset) begin
            de_d  <= 1'b0;
            x_cnt <= 12'd0;
            y_cnt <= 12'd0;
        end else begin
            de_d <= de_in;
            if (vs_in && !vs_d) begin
                x_cnt <= 12'd0;
                y_cnt <= 12'd0;
            end else if (de_in) begin
                if (!de_d)
                    x_cnt <= 12'd0;
                else
                    x_cnt <= x_cnt + PPC;
            end else if (de_d) begin
                y_cnt <= y_cnt + 12'd1;
                x_cnt <= 12'd0;
            end
        end
    end

    function automatic idle_chevron(
        input [11:0] x, y, ox, oy, size
    );
        reg signed [12:0] lx, ly;
        reg [11:0] half, stroke;
        reg signed [12:0] d;
        begin
            idle_chevron = 1'b0;
            if (size != 0) begin
                lx = {1'b0, x} - {1'b0, ox};
                ly = {1'b0, y} - {1'b0, oy};
                if (lx >= 0 && ly >= 0 && lx < {1'b0, size} && ly < {1'b0, size}) begin
                    half   = size >> 1;
                    stroke = (size / 12'd5 == 0) ? 12'd1 : (size / 12'd5);
                    if (ly[11:0] <= half)
                        d = lx - ly;
                    else
                        d = lx - ({1'b0, size} - 13'd1 - ly);
                    if (d >= 0 && d < {1'b0, stroke})
                        idle_chevron = 1'b1;
                end
            end
        end
    endfunction

    // Shared idle geometry (not per-lane).
    reg [11:0] idle_size, idle_ox, idle_oy;
    reg [11:0] span_x, span_y;
    reg [15:0] ph, tri_w, half_ph;
    reg [31:0] drift;

    always @(*) begin
        span_x    = 12'd0;
        span_y    = 12'd0;
        ph        = 16'd0;
        half_ph   = 16'd600;
        tri_w     = 16'd0;
        drift     = 32'd0;
        idle_size = (HDMI_WIDTH < HDMI_HEIGHT) ? (HDMI_WIDTH / 12'd3) : (HDMI_HEIGHT / 12'd3);
        if (idle_size < 12'd4) idle_size = 12'd4;
        idle_ox = (HDMI_WIDTH  - idle_size) >> 1;
        idle_oy = (HDMI_HEIGHT - idle_size) >> 1;
        if (idle_en && idle_mode == 2'd2) begin
            span_x = (HDMI_WIDTH > idle_size + 12'd16) ?
                     (HDMI_WIDTH - idle_size - 12'd16) : 12'd0;
            span_y = (HDMI_HEIGHT > idle_size + 12'd16) ?
                     (HDMI_HEIGHT - idle_size - 12'd16) : 12'd0;
            ph = idle_phase % 16'd1200;
            half_ph = 16'd600;
            tri_w = (ph < half_ph) ? ph : (16'd1200 - ph);
            drift = ({16'd0, tri_w} * {20'd0, span_x}) / 32'd600;
            idle_ox = 12'd8 + drift[11:0];
            ph = (idle_phase + 16'd300) % 16'd1200;
            tri_w = (ph < half_ph) ? ph : (16'd1200 - ph);
            drift = ({16'd0, tri_w} * {20'd0, span_y}) / 32'd600;
            idle_oy = 12'd8 + drift[11:0];
        end
    end

    // Per-pixel chrome hit (cmd list scan). Returns {hit, rgb}.
    function automatic [24:0] chrome_at;
        input [11:0] px, py;
        integer    ci;
        reg [63:0] cw;
        reg [7:0]  op, code, pal;
        reg [15:0] cx, cy;
        reg [11:0] rw, rh;
        reg [3:0]  sc;
        reg [11:0] gx, gy, bitx, bity, gw, gh;
        reg [7:0]  fbits;
        reg [7:0]  scan_n;
        reg        hit_l;
        reg [23:0] rgb_l;
        begin
            hit_l  = 1'b0;
            rgb_l  = 24'h00_00_00;
            sc     = body_scale;
            gw     = 12'(FONT_W) * {8'd0, sc};
            gh     = 12'(FONT_H) * {8'd0, sc};
            scan_n = (latched_count > HIT_SCAN[7:0]) ? HIT_SCAN[7:0] : latched_count;
            for (ci = 0; ci < HIT_SCAN; ci = ci + 1) begin
                if (latched_en && (ci < scan_n)) begin
                    cw   = live_bank ? list_b[ci] : list_a[ci];
                    op   = cw[7:0];
                    cx   = cw[23:8];
                    cy   = cw[39:24];
                    code = cw[47:40];
                    if (op == 8'd2) begin
                        if ({4'd0, px} >= cx && {4'd0, py} >= cy) begin
                            gx = px - cx[11:0];
                            gy = py - cy[11:0];
                            if (gx < gw && gy < gh) begin
                                bitx  = div_by_scale(gx, sc);
                                bity  = div_by_scale(gy, sc);
                                fbits = font_row(code, bity[2:0]);
                                if (bitx < 12'(FONT_W) && fbits[7 - bitx[2:0]]) begin
                                    hit_l = 1'b1;
                                    rgb_l = 24'hFF_FF_FF;
                                end
                            end
                        end
                    end else if (op == 8'd1) begin
                        rw = cw[51:40];
                        rh = cw[63:52];
                        if ({4'd0, px} >= cx && {4'd0, py} >= cy &&
                            {4'd0, px} < (cx + {4'd0, rw}) &&
                            {4'd0, py} < (cy + {4'd0, rh})) begin
                            hit_l = 1'b1;
                            rgb_l = 24'h14_14_28;
                        end
                    end else if (op == 8'd3) begin
                        rw  = {4'd0, cw[47:40]};
                        rh  = {4'd0, cw[55:48]};
                        pal = cw[63:56];
                        if ({4'd0, px} >= cx && {4'd0, py} >= cy &&
                            {4'd0, px} < (cx + {4'd0, rw}) &&
                            {4'd0, py} < (cy + {4'd0, rh})) begin
                            hit_l = 1'b1;
                            rgb_l = pal_rgb(pal);
                        end
                    end
                end
            end
            chrome_at = {hit_l, rgb_l};
        end
    endfunction

    // Fabric signature: cyan L-brackets at TL + BR. ARM idle_screen.hpp never
    // emits 00_C8_FF. MARK=64 BAR=12 → ~2.8k cyan px @ any canvas ≥128×128.
    localparam [11:0] SIG_MARK = 12'd64;
    localparam [11:0] SIG_BAR  = 12'd12;
    localparam [23:0] SIG_CYAN = 24'h00_C8_FF;

    function automatic idle_fab_mark;
        input [11:0] px, py;
        reg tl_h, tl_v, br_h, br_v;
        begin
            idle_fab_mark = 1'b0;
            if (HDMI_WIDTH >= SIG_MARK && HDMI_HEIGHT >= SIG_MARK) begin
                tl_h = (py < SIG_BAR)  && (px < SIG_MARK);
                tl_v = (px < SIG_BAR)  && (py < SIG_MARK);
                br_h = (py >= HDMI_HEIGHT - SIG_BAR) &&
                       (px >= HDMI_WIDTH - SIG_MARK);
                br_v = (px >= HDMI_WIDTH - SIG_BAR) &&
                       (py >= HDMI_HEIGHT - SIG_MARK);
                idle_fab_mark = tl_h | tl_v | br_h | br_v;
            end
        end
    endfunction

    function automatic [23:0] idle_rgb_at;
        input [11:0] px, py;
        begin
            idle_rgb_at = 24'h00_00_00;
            if (idle_en && idle_mode != 2'd3) begin
                if (idle_mode == 2'd1)
                    idle_rgb_at = 24'h00_00_00;
                else if (idle_sig_en && idle_fab_mark(px, py))
                    idle_rgb_at = SIG_CYAN; // fabric-only — above chevron/bg
                else if (idle_chevron(px, py, idle_ox, idle_oy, idle_size))
                    idle_rgb_at = 24'hE5_A0_0D;
                else
                    idle_rgb_at = 24'h1F_23_26;
            end
        end
    endfunction

    // Comb per-lane composite colors for this beat.
    reg [PX_PER_CLK*24-1:0] lane_rgb;
    reg [PX_PER_CLK-1:0]    lane_hit;
    reg [PX_PER_CLK-1:0]    lane_idle;
    integer lane_i;
    reg [11:0] lx;
    reg [24:0] ch;
    reg [23:0] ir;

    always @(*) begin
        lane_rgb  = {PX_PER_CLK*24{1'b0}};
        lane_hit  = {PX_PER_CLK{1'b0}};
        lane_idle = {PX_PER_CLK{1'b0}};
        for (lane_i = 0; lane_i < PX_PER_CLK; lane_i = lane_i + 1) begin
            lx = hx0 + lane_i[11:0];
            ch = chrome_at(lx, hy);
            ir = idle_rgb_at(lx, hy);
            lane_hit[lane_i]  = ch[24];
            lane_idle[lane_i] = idle_en && (idle_mode != 2'd3);
            if (ch[24])
                lane_rgb[lane_i*24 +: 24] = ch[23:0];
            else if (idle_en && (idle_mode != 2'd3))
                lane_rgb[lane_i*24 +: 24] = ir;
            else
                lane_rgb[lane_i*24 +: 24] = din[lane_i*24 +: 24];
        end
    end

    reg [PX_PER_CLK*24-1:0] din_d, lane_rgb_d;
    reg        hs_d, vs_d2, de_d2;
    reg [PX_PER_CLK-1:0] lane_hit_d, lane_idle_d;
    reg        idle_en_d;

    always @(posedge clk_hdmi) begin
        din_d       <= din;
        lane_rgb_d  <= lane_rgb;
        lane_hit_d  <= lane_hit;
        lane_idle_d <= lane_idle;
        hs_d        <= hs_in;
        vs_d2       <= vs_in;
        de_d2       <= de_in;
        idle_en_d   <= idle_en;

        hs_out <= hs_d;
        vs_out <= vs_d2;
        de_out <= de_d2;
        if (de_d2)
            dout <= lane_rgb_d; // already per-lane: hit / idle / din
        else
            dout <= din_d;
    end

endmodule
