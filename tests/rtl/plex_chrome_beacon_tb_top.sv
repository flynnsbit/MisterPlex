// PLAYING lime beacon — content-independent motion marker.
`timescale 1ns / 1ps
module plex_chrome_beacon_tb (
    input  wire        clk,
    input  wire        reset,
    input  wire [11:0] HDMI_WIDTH,
    input  wire [11:0] HDMI_HEIGHT,
    input  wire [23:0] din,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    output wire [23:0] dout,
    input  wire        play_beacon_en
);
    plex_chrome #(
        .BOOT_DEMO(0),
        .MAX_CMDS(8),
        .HIT_SCAN(8),
        .PX_PER_CLK(1)
    ) u_dut (
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
        .de_out(),
        .cfg_enable(1'b0),
        .cfg_seq(16'd0),
        .cfg_cmd_count(8'd0),
        .list_we(1'b0),
        .list_waddr(8'd0),
        .list_wdata(64'd0),
        .idle_en(1'b0),
        .idle_mode(2'd0),
        .idle_phase(16'd0),
        .idle_sig_en(1'b0),
        .chrome_sig_en(1'b0),
        .chrome_demo_en(1'b0),
        .play_beacon_en(play_beacon_en),
        .chrome_hw(),
        .mon_width(),
        .mon_height(),
        .mon_body_scale()
    );
endmodule
