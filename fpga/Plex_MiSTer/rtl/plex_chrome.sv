// plex_chrome — player chrome + fabric idle plane
//
// Owner: w-osd
//
// === THREE DOMAINS (do not conflate — parent 2026-08-03 pivot class) =========
//   STORAGE  : DDR bank payload (product 960×540 I420 = 777600 B). Never a
//              chrome canvas. PLXG describes window into this, not HUD coords.
//   CORE_DE  : Raster the *core* emits into ascal (near-term fit: 960×540).
//              Pre-ascal only. If chrome were inserted here it would be
//              upscaled ~4/3 by ascal → softer glyphs on glass.
//   HDMI_OUT : Post-ascal glass raster (HPS video_mode → 1280×720@60).
//              *** Product chrome lives HERE (sys_top): ***
//                ascal → shadowmask → plex_chrome → osd → pins
//              Ports HDMI_WIDTH/HEIGHT are the *paint beam* (= HDMI_OUT).
//              Layout derives from that beam — NOT from STORAGE, NOT from a
//              frozen 1280 constant while the beam is something else.
//
// Architectural choice (stated, not discovered): keep chrome on HDMI_OUT so
// glyphs/HUD are native glass pixels. Moving chrome to CORE_DE would save no
// ALM of consequence and would soft-upscale chrome 1.333× — refuse unless a
// measured fit forces pre-ascal insertion.
//
// Geometry: paint beam W/H are 12-bit (0..4095). body_scale from layout_h
// (half-even /240, clamp 2..8) → scale=3 @720p HDMI_OUT, scale=2 @540 CORE_DE.
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
// === 720p SCALING DECISION (parent 2026-08-04) ================================
// PICK: procedural layout from paint beam (HDMI_WIDTH×HEIGHT), NOT bitmap
// re-author and NOT a 2.88× pixel upsample of 480p framebuffer art.
//   body_scale = half-even(layout_h/240) clamp 2..8  → 3 @720p, 2 @480/540
//   idle chevron: size=min(W,H)/3, ox/oy centered — pure math (0 M10K)
//   font: 8×8 combo ROM × body_scale (0 M10K); glyphs stay sharp on glass
// REJECT upsample-480p-assets: would need linebufs ~1280×8b = 1 M10K/line
//   (Cyclone V M10K = 10240 bits = 1280 bytes — handbook-class; packing still
//   UNVERIFIED in Quartus) × several lines + soft edges; competes with w-mem copy.
// FRAME_W/H (640→1280) is w-nostub's global switch — chrome does NOT duplicate it.
//
// Budget (yosys generic cell counts, proc+opt_clean+memory -nomap; NOT Quartus ALM/Fmax):
//   list 2×N×64b dual-buffer (consolidated M10K, not N tiny RAMs):
//     N=48  → 6.0 kbit   yosys cells=35509
//     N=80  → 10.0 kbit  yosys cells=56629  (Δ +59% vs 48)
//     N=104 → 13.3 kbit  yosys cells=72469  (Δ +104% vs 48)
//     N=112 → ~14.3 kbit  (product storage; HIT_SCAN=48 caps combo)
//     N=128 → 16.0 kbit  yosys cells=88309  (Δ +149% vs 48)
//   Product M10K EST: list 2×112×64 = 14336 bits → ceil(14336/10240)=2 M10K ideal
//                     (if each bank maps 1 block: 2; shallow dual-port may be 2–4)
//   CDC FIFO DEPTH=128 × 72b = 9216 bits → ≤1 M10K ideal
//   font ROM combinational (0 M10K); idle chevron pure math (0 M10K)
//   TOTAL chrome plane EST: 3–5 M10K, ALM UNKNOWN (no fit this lane; competes w-mem)
//   Fmax on clk_hdmi: UNKNOWN without Quartus — HIT_SCAN is per-pixel combo depth.
//   Evidence: .agent-work/chrome-area/stat_n{48,80,104,128}.txt (yosys only)

`timescale 1ns / 1ps

module plex_chrome #(
    parameter int MAX_CMDS = 112, // list storage/ABI depth (may hold > scan)
    // Pre-fit cap (rd-duck yosys): HIT_SCAN drives chrome_at combo cost, not
    // storage. 112/112 ≈ 77.7k cells; 112-store/48-scan ≈ 35.5k (−54%). Shipping
    // daemon path (null title/notice, no buffering) ≤41 cmds incl. huge skip;
    // HIT_SCAN=48 covers that with headroom. Full 102-cmd simultaneous UI is
    // deferred to a scanline-indexed renderer — do not fit HIT_SCAN=112 first.
    parameter int HIT_SCAN = 48,
    parameter int FONT_W   = 8,
    parameter int FONT_H   = 8,
    parameter bit BOOT_DEMO = 1'b0,
    parameter int PX_PER_CLK = 1,  // 1|2|4 — default 1 product-safe
    // Red-twin only (sim): paint idle/HUD/beacon as if the canvas were legacy
    // 624×480 while the DE beam is still true HDMI (1280×720). mon_* always
    // reports the real paint beam. Default 0 = product bit-identical.
    parameter bit FAULT_LEGACY_480P_LAYOUT = 1'b0,
    // Red-twin / domain pin: force HDMI_OUT 1280×720 layout math while the
    // *beam* ports are CORE_DE 960×540. Product chrome is post-ascal on
    // HDMI_OUT (sys_top: ascal→shadowmask→plex_chrome) — there is no product
    // overflow. This fault defends the opposite mistake: a future lane
    // silently relocating chrome *pre*-ascal so ascal softens every glyph
    // ~1.333× without anyone noticing. Pin: paint domain must track the beam
    // the module is wired into. Mutually exclusive with FAULT_LEGACY_480P_LAYOUT.
    parameter bit FAULT_HDMI_LAYOUT_ON_CORE_DE = 1'b0,
    // Red-twin: expand rect/glyph hit by +1 px on right/bottom (classic off-by-one).
    // Bleeds one pixel of chrome into neighbouring video. Default 0 = product.
    parameter bit FAULT_HIT_BLEED = 1'b0
) (
    input  wire        clk_hdmi,
    input  wire        reset,

    // Paint-beam size (product = HDMI_OUT post-ascal). Name is historical;
    // these are NOT "always 1280×720" — they track the DE this module sees.
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
    // Playback chrome fabric signature (magenta TR+BL). ARM overlay never emits
    // FF_2D_95. Parent scores MAGENTA_PX. Active when list/demo paints.
    input  wire        chrome_sig_en,
    // Built-in STOPPED HUD without ARM PLXC (PLEX_FAB_CHROME demo). Off by default.
    input  wire        chrome_demo_en,
    // PLAYING content-independent motion beacon (PLEX_FAB_PLAY_BEACON). Default off.
    // Lime 32×32 block toggles on a free-running vsync divider — fabric-only.
    input  wire        play_beacon_en,

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

    // Active *layout* canvas for paint (idle / demo HUD / beacon / glyph scale).
    // Product: layout == paint beam (HDMI_WIDTH/HEIGHT). Faults force a wrong
    // domain so red-twins catch silent geometry bugs:
    //   FAULT_LEGACY_480P_LAYOUT     → 624×480 math on true beam
    //   FAULT_HDMI_LAYOUT_ON_CORE_DE → 1280 math on CORE_DE beam (domain pin;
    //                                  guards pre-ascal soften, not product overflow)
    wire [11:0] layout_w =
        FAULT_LEGACY_480P_LAYOUT     ? 12'd624  :
        FAULT_HDMI_LAYOUT_ON_CORE_DE ? 12'd1280 :
                                       HDMI_WIDTH;
    wire [11:0] layout_h =
        FAULT_LEGACY_480P_LAYOUT     ? 12'd480 :
        FAULT_HDMI_LAYOUT_ON_CORE_DE ? 12'd720 :
                                       HDMI_HEIGHT;
    wire [3:0]  body_scale = body_scale_f(layout_h);
    // Telemetry always reports the true *beam* (and its scale), never the
    // fault layout — so mon alone cannot green-wash a domain bug.
    wire [3:0]  glass_scale = body_scale_f(HDMI_HEIGHT);

    // mon_* / chrome_hw always update so a post-fit hierarchy row cannot be
    // "entity present, 0 regs" while still claiming a live plane. sys_top folds
    // these into a blanking keep-sink (noprune) so they are not dangling.
    (* noprune *) (* preserve *)
    always @(posedge clk_hdmi) begin
        chrome_hw      <= 1'b1;
        mon_width      <= HDMI_WIDTH;
        mon_height     <= HDMI_HEIGHT;
        mon_body_scale <= glass_scale;
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
            8'd7: pal_rgb = 24'hFF_2D_95; // fabric playback signature (not ARM)
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
    // Transaction-held staging bank (rd-duck hole 2): list beats must not flip
    // target when VS promotes a pending cfg on the same edge as list_we.
    reg        xact_hold;
    reg        xact_bank;
    reg [15:0] cfg_seq_d;

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
        xact_hold = 1'b0;
        xact_bank = 1'b0;
        cfg_seq_d = 16'd0;
    end

    localparam int AW = $clog2(MAX_CMDS);

    reg vs_d;
    // Bank map (rd-duck, do not invert):
    //   chrome_at LIVE  : live_bank ? list_b : list_a
    //   list_we STAGING : if (wr_to_a) list_a else list_b
    //   original write  : if (live_bank) list_a else list_b
    // Therefore normal wr_to_a == live_bank (live_bank=0 → write B, A stays live).
    // Imminent VS swap: post-swap staging is the old live bank → wr_to_a = ~live_bank.
    // FAULT_INVERT_STAGING: normal wr_to_a = ~live_bank (overwrites LIVE HUD).
    // FAULT_VS_BANK: swap under list_we + naive wr_to_a=live_bank (no swap remap).
    wire vs_rise   = vs_in && !vs_d;
    wire want_swap = (cfg_seq != latched_seq);
`ifdef PLEX_CHROME_FAULT_VS_BANK
    // Red twin hole-2: allow VS swap under list_we AND use pre-edge live_bank
    // only (no swap_now bank remap). B cmd0 lands on the bank that becomes
    // LIVE on the same edge; later beats can split or leave staging incomplete.
    wire swap_now  = vs_rise && want_swap; // do not defer
    wire wr_to_a   = xact_hold ? xact_bank : live_bank;
`elsif PLEX_CHROME_FAULT_INVERT_STAGING
    // Red twin: normal path writes the LIVE bank (inverted selector).
    wire swap_now  = vs_rise && want_swap && !xact_hold;
    wire wr_to_a = xact_hold ? xact_bank
                             : (swap_now ? live_bank : ~live_bank);
`else
    // Product (rd-duck): defer swap while list xact held; bank map
    // wr_to_a = (swap_now ? ~live_bank : live_bank).
    wire swap_now  = vs_rise && want_swap && !xact_hold;
    wire wr_to_a = xact_hold ? xact_bank
                             : (swap_now ? ~live_bank : live_bank);
`endif

    always @(posedge clk_hdmi) begin
        vs_d      <= vs_in;
        cfg_seq_d <= cfg_seq;
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
            xact_hold <= 1'b0;
            xact_bank <= 1'b0;
            cfg_seq_d <= 16'd0;
        end else begin
            // List write: freeze staging bank for the whole host transaction.
            // Must never target the LIVE bank on a normal (non-swap) beat.
            if (list_we && (list_waddr < MAX_CMDS[7:0])) begin
                if (!xact_hold) begin
                    xact_hold <= 1'b1;
                    xact_bank <= wr_to_a;
                end
                if (wr_to_a)
                    list_a[list_waddr[AW-1:0]] <= list_wdata;
                else
                    list_b[list_waddr[AW-1:0]] <= list_wdata;
            end
            // Ctrl commit ends the list transaction (host: list then ctrl).
            if (cfg_seq != cfg_seq_d)
                xact_hold <= 1'b0;
            if (swap_now) begin
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
        // layout_* — not bare HDMI_*: product equal; FAULT uses 624×480 math.
        idle_size = (layout_w < layout_h) ? (layout_w / 12'd3) : (layout_h / 12'd3);
        if (idle_size < 12'd4) idle_size = 12'd4;
        idle_ox = (layout_w  - idle_size) >> 1;
        idle_oy = (layout_h - idle_size) >> 1;
        if (idle_en && idle_mode == 2'd2) begin
            span_x = (layout_w > idle_size + 12'd16) ?
                     (layout_w - idle_size - 12'd16) : 12'd0;
            span_y = (layout_h > idle_size + 12'd16) ?
                     (layout_h - idle_size - 12'd16) : 12'd0;
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
                        // FAULT_HIT_BLEED: inclusive +1 on right/bottom edges
                        if ({4'd0, px} >= cx && {4'd0, py} >= cy &&
                            {4'd0, px} < (cx + {4'd0, rw} + (FAULT_HIT_BLEED ? 16'd1 : 16'd0)) &&
                            {4'd0, py} < (cy + {4'd0, rh} + (FAULT_HIT_BLEED ? 16'd1 : 16'd0))) begin
                            hit_l = 1'b1;
                            rgb_l = 24'h14_14_28;
                        end
                    end else if (op == 8'd3) begin
                        rw  = {4'd0, cw[47:40]};
                        rh  = {4'd0, cw[55:48]};
                        pal = cw[63:56];
                        if ({4'd0, px} >= cx && {4'd0, py} >= cy &&
                            {4'd0, px} < (cx + {4'd0, rw} + (FAULT_HIT_BLEED ? 16'd1 : 16'd0)) &&
                            {4'd0, py} < (cy + {4'd0, rh} + (FAULT_HIT_BLEED ? 16'd1 : 16'd0))) begin
                            hit_l = 1'b1;
                            rgb_l = pal_rgb(pal);
                        end
                    end
                end
            end
            chrome_at = {hit_l, rgb_l};
        end
    endfunction

    // Fabric signatures (ARM never emits these pure primaries in idle/overlay):
    //   idle:     cyan 00_C8_FF at TL+BR
    //   playback: magenta FF_2D_95 at TR+BL  (orthogonal corners)
    //   playing:  lime 40_FF_40 32×32 mid-right toggle (PLEX_FAB_PLAY_BEACON)
    localparam [11:0] SIG_MARK = 12'd64;
    localparam [11:0] SIG_BAR  = 12'd12;
    localparam [23:0] SIG_CYAN    = 24'h00_C8_FF;
    localparam [23:0] SIG_MAGENTA = 24'hFF_2D_95;
    localparam [23:0] SIG_LIME    = 24'h40_FF_40;
    localparam [11:0] BEACON_SZ   = 12'd32;

    // Free-running vsync divider — independent of video content / ARM.
    reg        vs_d1_bcn;
    reg [4:0]  beacon_div;
    reg        beacon_on;
    always @(posedge clk_hdmi) begin
        if (reset) begin
            vs_d1_bcn  <= 1'b0;
            beacon_div <= 5'd0;
            beacon_on  <= 1'b0;
        end else begin
            vs_d1_bcn <= vs_in;
            if (play_beacon_en && !idle_en && vs_in && !vs_d1_bcn) begin
                // ~16 frames/half-period @60Hz ≈ 0.27 s; 1 s dual-snap sees a flip
                if (beacon_div == 5'd15) begin
                    beacon_div <= 5'd0;
                    beacon_on  <= ~beacon_on;
                end else begin
                    beacon_div <= beacon_div + 5'd1;
                end
            end
            if (!play_beacon_en || idle_en) begin
                beacon_div <= 5'd0;
                beacon_on  <= 1'b0;
            end
        end
    end

    // Mid-right on *layout* canvas (tracks glass; FAULT uses 480p mid-right).
    function automatic play_beacon_mark;
        input [11:0] px, py;
        reg [11:0] x0, y0;
        begin
            play_beacon_mark = 1'b0;
            if (layout_w > (BEACON_SZ + 12'd16) && layout_h > (BEACON_SZ + 12'd32)) begin
                x0 = layout_w - BEACON_SZ - 12'd16;
                y0 = (layout_h >> 1) - (BEACON_SZ >> 1);
                play_beacon_mark = (px >= x0) && (px < (x0 + BEACON_SZ)) &&
                                   (py >= y0) && (py < (y0 + BEACON_SZ));
            end
        end
    endfunction

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

    // Playback chrome signature: top-right + bottom-left (not idle TL/BR).
    function automatic chrome_fab_mark;
        input [11:0] px, py;
        reg tr_h, tr_v, bl_h, bl_v;
        begin
            chrome_fab_mark = 1'b0;
            if (HDMI_WIDTH >= SIG_MARK && HDMI_HEIGHT >= SIG_MARK) begin
                tr_h = (py < SIG_BAR) && (px >= HDMI_WIDTH - SIG_MARK);
                tr_v = (px >= HDMI_WIDTH - SIG_BAR) && (py < SIG_MARK);
                bl_h = (py >= HDMI_HEIGHT - SIG_BAR) && (px < SIG_MARK);
                bl_v = (px < SIG_BAR) && (py >= HDMI_HEIGHT - SIG_MARK);
                chrome_fab_mark = tr_h | tr_v | bl_h | bl_v;
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

    // Built-in STOPPED HUD (no ARM). Geometry mirrors plex_chrome_cmds::buildPlaybackHud
    // at scale from HDMI_H. "STOPPED" + panel + 50% amber bar — enough for glass.
    function automatic [24:0] chrome_demo_at;
        input [11:0] px, py;
        reg [11:0] margin, ph, px0, py0, pw;
        reg [11:0] bar_x, bar_y, bar_w, bar_h, fill_w;
        reg [3:0]  sc;
        reg [11:0] gw, gh, tx, ty, gx, gy, bitx, bity;
        reg [7:0]  fbits;
        reg [7:0]  code;
        reg [3:0]  gi;
        reg        hit_l;
        reg [23:0] rgb_l;
        // "STOPPED" codes
        reg [7:0]  s0, s1, s2, s3, s4, s5, s6;
        begin
            hit_l = 1'b0;
            rgb_l = 24'h00_00_00;
            sc    = body_scale;
            gw    = 12'(FONT_W) * {8'd0, sc};
            gh    = 12'(FONT_H) * {8'd0, sc};
            // Demo HUD from layout canvas (not coded bank; not bare 480p constants).
            margin = (layout_w >> 5);
            if (margin < 12'd8) margin = 12'd8;
            ph = 12'(72) * {8'd0, sc} / 12'd2;
            if (ph < 12'd54) ph = 12'd54;
            if (ph > (layout_h >> 2)) ph = layout_h >> 2;
            px0 = margin;
            py0 = (layout_h > (ph + margin)) ? (layout_h - ph - margin) : 12'd0;
            pw  = (layout_w > (margin << 1)) ? (layout_w - (margin << 1)) : layout_w;
            // panel
            if (px >= px0 && py >= py0 && px < (px0 + pw) && py < (py0 + ph)) begin
                hit_l = 1'b1;
                rgb_l = 24'h14_14_28;
            end
            // STOPPED glyphs (ASCII)
            s0 = 8'h53; s1 = 8'h54; s2 = 8'h4F; s3 = 8'h50;
            s4 = 8'h50; s5 = 8'h45; s6 = 8'h44;
            tx = px0 + 12'd16;
            ty = py0 + 12'd10;
            for (gi = 0; gi < 4'd7; gi = gi + 4'd1) begin
                case (gi)
                    4'd0: code = s0;
                    4'd1: code = s1;
                    4'd2: code = s2;
                    4'd3: code = s3;
                    4'd4: code = s4;
                    4'd5: code = s5;
                    default: code = s6;
                endcase
                if (px >= tx && py >= ty) begin
                    gx = px - tx;
                    gy = py - ty;
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
                tx = tx + (12'(9) * {8'd0, sc}); // FONT_ADVANCE=9
            end
            // track + 50% fill
            bar_x = px0 + 12'd16;
            bar_y = py0 + ph - 12'd18;
            bar_w = (pw > 12'd32) ? (pw - 12'd32) : 12'd8;
            bar_h = 12'd6;
            fill_w = bar_w >> 1;
            if (px >= bar_x && py >= bar_y && px < (bar_x + bar_w) && py < (bar_y + bar_h)) begin
                hit_l = 1'b1;
                rgb_l = 24'h3A_3F_48;
            end
            if (px >= bar_x && py >= bar_y && px < (bar_x + fill_w) && py < (bar_y + bar_h)) begin
                hit_l = 1'b1;
                rgb_l = 24'hFF_B2_20;
            end
            chrome_demo_at = {hit_l, rgb_l};
        end
    endfunction

    // Comb per-lane composite colors for this beat.
    reg [PX_PER_CLK*24-1:0] lane_rgb;
    reg [PX_PER_CLK-1:0]    lane_hit;
    reg [PX_PER_CLK-1:0]    lane_idle;
    integer lane_i;
    reg [11:0] lx;
    reg [24:0] ch;
    reg [24:0] demo;
    reg [23:0] ir;
    reg        chrome_on;
    reg        want_sig;
    reg        want_beacon;

    always @(*) begin
        lane_rgb  = {PX_PER_CLK*24{1'b0}};
        lane_hit  = {PX_PER_CLK{1'b0}};
        lane_idle = {PX_PER_CLK{1'b0}};
        for (lane_i = 0; lane_i < PX_PER_CLK; lane_i = lane_i + 1) begin
            lx = hx0 + lane_i[11:0];
            ch   = chrome_at(lx, hy);
            demo = (chrome_demo_en && !idle_en) ? chrome_demo_at(lx, hy) : 25'd0;
            ir   = idle_rgb_at(lx, hy);
            chrome_on = ch[24] | demo[24];
            want_sig  = chrome_sig_en && !idle_en && (latched_en | chrome_demo_en) &&
                        chrome_fab_mark(lx, hy);
            want_beacon = play_beacon_en && !idle_en && beacon_on &&
                          play_beacon_mark(lx, hy);
            lane_hit[lane_i]  = chrome_on | want_sig | want_beacon;
            lane_idle[lane_i] = idle_en && (idle_mode != 2'd3);
            // Priority: magenta > lime beacon > list > demo HUD > idle > video
            if (want_sig)
                lane_rgb[lane_i*24 +: 24] = SIG_MAGENTA;
            else if (want_beacon)
                lane_rgb[lane_i*24 +: 24] = SIG_LIME;
            else if (ch[24])
                lane_rgb[lane_i*24 +: 24] = ch[23:0];
            else if (demo[24])
                lane_rgb[lane_i*24 +: 24] = demo[23:0];
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
