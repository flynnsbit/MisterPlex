// TB: plex_chrome double-bank VS coincidence (rd-duck hole 2).
// Direct list_we/cfg ports — no host_if — so list beat and VS can share an edge.
`timescale 1ns / 1ps

module plex_chrome_vs_bank_tb (
    input  wire        clk,
    input  wire        reset,
    input  wire [11:0] HDMI_WIDTH,
    input  wire [11:0] HDMI_HEIGHT,
    input  wire [23:0] din,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    output wire [23:0] dout,
    output wire        de_out,
    input  wire        cfg_enable,
    input  wire [15:0] cfg_seq,
    input  wire [7:0]  cfg_cmd_count,
    input  wire        list_we,
    input  wire [7:0]  list_waddr,
    input  wire [63:0] list_wdata,
    output wire        chrome_hw,
    output wire [11:0] mon_width,
    output wire [11:0] mon_height,
    output wire [3:0]  mon_body_scale
);

    plex_chrome #(
        .BOOT_DEMO(0),
        .MAX_CMDS(16),
        .HIT_SCAN(16)
    ) u_chrome (
        .clk_hdmi(clk),
        .reset(reset),
        .HDMI_WIDTH(HDMI_WIDTH),
        .HDMI_HEIGHT(HDMI_HEIGHT),
        .din(din),
        .hs_in(hs_in),
        .vs_in(vs_in),
        .de_in(de_in),
        .dout(dout),
        .hs_out(),
        .vs_out(),
        .de_out(de_out),
        .cfg_enable(cfg_enable),
        .cfg_seq(cfg_seq),
        .cfg_cmd_count(cfg_cmd_count),
        .list_we(list_we),
        .list_waddr(list_waddr),
        .list_wdata(list_wdata),
        .idle_en(1'b0),
        .idle_mode(2'd0),
        .idle_phase(16'd0),
        .idle_sig_en(1'b0),
        .chrome_sig_en(1'b0),
        .chrome_demo_en(1'b0),
        .play_beacon_en(1'b0),
        .chrome_hw(chrome_hw),
        .mon_width(mon_width),
        .mon_height(mon_height),
        .mon_body_scale(mon_body_scale)
    );

endmodule
