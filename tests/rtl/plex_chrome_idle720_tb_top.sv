// Native 1280×720 fabric idle + vsync phase — PX_PER_CLK=1 and fault hook.
// FAULT_480P_GEOM=1 clamps HDMI mon/geometry inputs to 624×480-style math so
// the 720p probe RED-fails (red-before-green).
`timescale 1ns / 1ps

module plex_chrome_idle720_tb #(
    parameter bit FAULT_480P_GEOM = 1'b0,
    parameter int PX_PER_CLK = 1
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [PX_PER_CLK*24-1:0] din,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    output wire [PX_PER_CLK*24-1:0] dout,
    output wire        de_out,
    input  wire        has_frame,
    input  wire [1:0]  osd_idle_mode,
    input  wire        fab_phase_en,
    input  wire [15:0] idle_phase_in,
    output wire        idle_en_mon,
    output wire [15:0] idle_phase_mon,
    output wire [11:0] mon_width,
    output wire [11:0] mon_height,
    output wire [3:0]  mon_body_scale
);

    // Product geometry under test: 1280×720. Fault path pretends 480p clamp.
    wire [11:0] geom_w = FAULT_480P_GEOM ? 12'd624 : 12'd1280;
    wire [11:0] geom_h = FAULT_480P_GEOM ? 12'd480 : 12'd720;

    wire        list_we;
    wire [7:0]  list_waddr;
    wire [63:0] list_wdata;
    wire        cfg_enable;
    wire [15:0] cfg_seq;
    wire [7:0]  cfg_cmd_count;
    wire        idle_en;
    wire [1:0]  idle_mode;
    wire [15:0] idle_phase;

    assign idle_en_mon    = idle_en;
    assign idle_phase_mon = idle_phase;

    plex_chrome_host_if #(.MAX_CMDS(48)) u_if (
        .clk(clk),
        .reset(reset),
        .host_we(1'b0),
        .host_addr(8'd0),
        .host_wdata(64'd0),
        .has_frame(has_frame),
        .osd_idle_mode(osd_idle_mode),
        .idle_phase_in(idle_phase_in),
        .vsync_in(vs_in),
        .fab_phase_en(fab_phase_en),
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
        .MAX_CMDS(48),
        .HIT_SCAN(48),
        .PX_PER_CLK(PX_PER_CLK)
    ) u_chrome (
        .clk_hdmi(clk),
        .reset(reset),
        .HDMI_WIDTH(geom_w),
        .HDMI_HEIGHT(geom_h),
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
        .idle_en(idle_en),
        .idle_mode(idle_mode),
        .idle_phase(idle_phase),
        .chrome_hw(),
        .mon_width(mon_width),
        .mon_height(mon_height),
        .mon_body_scale(mon_body_scale)
    );

endmodule
