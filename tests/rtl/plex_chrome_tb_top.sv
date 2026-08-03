// Thin top for Verilator — plex_chrome + host_if
`timescale 1ns / 1ps

module plex_chrome_tb (
    input  wire        clk,
    input  wire        reset,
    input  wire [11:0] HDMI_WIDTH,
    input  wire [11:0] HDMI_HEIGHT,
    input  wire [23:0] din,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    output wire [23:0] dout,
    output wire        hs_out,
    output wire        vs_out,
    output wire        de_out,
    input  wire        host_we,
    input  wire [7:0]  host_addr,
    input  wire [63:0] host_wdata,
    input  wire        has_frame,
    input  wire [1:0]  osd_idle_mode,
    input  wire [15:0] idle_phase_in,
    output wire        chrome_hw,
    output wire [3:0]  mon_body_scale,
    output wire        cfg_enable_mon,
    output wire        idle_en_mon
);

    wire        list_we;
    wire [7:0]  list_waddr;
    wire [63:0] list_wdata;
    wire        cfg_enable;
    wire [15:0] cfg_seq;
    wire [7:0]  cfg_cmd_count;
    wire        idle_en;
    wire [1:0]  idle_mode;
    wire [15:0] idle_phase;

    assign cfg_enable_mon = cfg_enable;
    assign idle_en_mon    = idle_en;

    plex_chrome_host_if #(.MAX_CMDS(112)) u_if (
        .clk(clk),
        .reset(reset),
        .host_we(host_we),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .has_frame(has_frame),
        .osd_idle_mode(osd_idle_mode),
        .idle_phase_in(idle_phase_in),
        .vsync_in(vs_in),
        .fab_phase_en(1'b0),
        .list_we(list_we),
        .list_waddr(list_waddr),
        .list_wdata(list_wdata),
        .cfg_enable(cfg_enable),
        .cfg_seq(cfg_seq),
        .cfg_cmd_count(cfg_cmd_count),
        .idle_en(idle_en),
        .idle_mode(idle_mode),
        .idle_phase(idle_phase),
        .chrome_hw_sticky(),
        .plxo_seq()
    );

    plex_chrome #(
        .BOOT_DEMO(0),
        .MAX_CMDS(112),
        .HIT_SCAN(48)
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
        .hs_out(hs_out),
        .vs_out(vs_out),
        .de_out(de_out),
        .cfg_enable(cfg_enable),
        .cfg_seq(cfg_seq),
        .cfg_cmd_count(cfg_cmd_count),
        .list_we(list_we),
        .list_waddr(list_waddr),
        .list_wdata(list_wdata),
        .idle_en(idle_en),
        .idle_mode(idle_mode),
        .idle_phase(idle_phase),
        .idle_sig_en(1'b0),
        .chrome_sig_en(1'b0),
        .chrome_demo_en(1'b0),
        .play_beacon_en(1'b0),
        .chrome_hw(chrome_hw),
        .mon_width(),
        .mon_height(),
        .mon_body_scale(mon_body_scale)
    );

endmodule
