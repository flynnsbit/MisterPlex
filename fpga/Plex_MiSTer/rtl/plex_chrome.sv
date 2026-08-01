// plex_chrome — post-ascal player chrome plane (DESIGN SKELETON — not in QSF yet)
//
// Owner: w-osd-hires · docs/plex-chrome-plane-rtl-proposal.md
// Status: static review only. Do NOT add to Quartus until parent grants ONE-fit
// with w-geom + w-fit-1. No exclusive slot claimed by this file alone.
//
// Insertion (sys_top.v HDMI path):
//   ascal → shadowmask → [plex_chrome] → osd hdmi_osd → pins
//   clk = clk_hdmi; din/hs/vs/de from mask; dout to osd.din
//
// Geometry: HDMI_WIDTH / HDMI_HEIGHT (applied). Self-time DE like sys/osd.v.
// Scale: body_scale = clamp(2..8, half_even_round(HDMI_HEIGHT/240))
// ARM: semantic PLXC list only (doorbell+0x130). Never pixels.
//
// Budget prereg (V1 vs t7b/8fdf 23585 ALM / 465 M10K / 44 DSP):
//   M10K +12±4 (cap 24) · ALM +2.5k±1k · DSP 0 · HDMI Fmax HOLD
// Do NOT spend decode_stub 268 M10K until w-fit-1 reclaim maps (telemetry hazard).

`timescale 1ns / 1ps

module plex_chrome #(
    parameter int MAX_CMDS = 256,
    parameter int FONT_W   = 8,
    parameter int FONT_H   = 8
) (
    input  wire        clk_hdmi,
    input  wire        reset,

    // Applied output (sys_top hdmi_width/height → emu HDMI_*)
    input  wire [11:0] HDMI_WIDTH,
    input  wire [11:0] HDMI_HEIGHT,

    // Video pipe (after shadowmask, before hdmi_osd)
    input  wire [23:0] din,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    output reg  [23:0] dout,
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,

    // Semantic channel (CDC from clk_sys / HPS write port — stubbed ports)
    input  wire        cfg_enable,
    input  wire [15:0] cfg_seq,
    input  wire [7:0]  cfg_cmd_count,
    // List RAM write port (clk_sys domain in full design)
    input  wire        list_we,
    input  wire [7:0]  list_waddr,
    input  wire [63:0] list_wdata,

    // Telemetry (optional PLXO)
    output reg         chrome_hw,
    output reg  [11:0] mon_width,
    output reg  [11:0] mon_height,
    output reg  [3:0]  mon_body_scale
);

    // ---- body_scale = clamp(2..8, half-even round(H/240)) ----
    // Combinational model for review; map to registered path in fit.
    function automatic [3:0] body_scale_f(input [11:0] h);
        reg [11:0] q;
        reg [11:0] r;
        reg [4:0]  raw;
        begin
            q = h / 12'd240;
            r = h % 12'd240;
            raw = q[4:0];
            if (r > 12'd120)
                raw = q[4:0] + 5'd1;
            else if (r == 12'd120)
                raw = q[0] ? (q[4:0] + 5'd1) : q[4:0]; // half toward even
            if (raw < 5'd2)
                raw = 5'd2;
            if (raw > 5'd8)
                raw = 5'd8;
            body_scale_f = raw[3:0];
        end
    endfunction

    wire [3:0] body_scale = body_scale_f(HDMI_HEIGHT);

    always @(posedge clk_hdmi) begin
        chrome_hw      <= 1'b1; // strapped when module is in the netlist
        mon_width      <= HDMI_WIDTH;
        mon_height     <= HDMI_HEIGHT;
        mon_body_scale <= body_scale;
    end

    // ---- DE self-time (osd pattern) — hx/hy in active area ----
    reg        de_d;
    reg [11:0] hx, hy;
    reg [11:0] meas_w, meas_h;

    always @(posedge clk_hdmi) begin
        if (reset) begin
            de_d   <= 1'b0;
            hx     <= 12'd0;
            hy     <= 12'd0;
            meas_w <= 12'd0;
            meas_h <= 12'd0;
        end else begin
            de_d <= de_in;
            if (de_in && !de_d) begin
                // rising DE: new line
                hx <= 12'd0;
                if (!vs_in) // crude; full design uses vs edge
                    hy <= hy + 12'd1;
            end else if (de_in) begin
                hx <= hx + 12'd1;
            end
            if (!de_in && de_d) begin
                meas_w <= hx + 12'd1;
            end
            // vs falling → latch frame height (simplified)
            // Full design: match osd.v v_cnt / dsp_width measurement.
            if (vs_in == 1'b0 && hy != 12'd0)
                meas_h <= hy;
        end
    end

    // ---- Passthrough blend stub (Inc-1: enable solid bottom band) ----
    // Full design: list walker + font ROM NN expand into blend.
    // This skeleton only delays din by 1 beat and optionally tints bottom band
    // so a hierarchical map can cost the shell without ROM yet.
    reg [23:0] din_d;
    reg        hs_d, vs_d, de_d2;
    wire       in_band = cfg_enable && de_d2 &&
                         (hy >= (HDMI_HEIGHT - (FONT_H * body_scale) - 12'd16));

    always @(posedge clk_hdmi) begin
        din_d <= din;
        hs_d  <= hs_in;
        vs_d  <= vs_in;
        de_d2 <= de_in;

        hs_out <= hs_d;
        vs_out <= vs_d;
        de_out <= de_d2;
        if (in_band)
            dout <= {din_d[23:16] >> 1, din_d[15:8] >> 1, din_d[7:0] >> 1}; // dim
        else
            dout <= din_d;
    end

    // Silence unused in skeleton (list ports reserved for dual-clock RAM).
    wire _unused = list_we ^ |list_waddr ^ |list_wdata ^ |cfg_seq ^ |cfg_cmd_count
                   ^ |meas_w ^ |meas_h ^ |MAX_CMDS;

endmodule
