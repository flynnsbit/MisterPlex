// Fabric idle layout red-twins + green HDMI_OUT path.
// FAULT_480P_GEOM=1 clamps beam to 624×480 (old red path).
// FAULT_LEGACY_480P_LAYOUT=1: beam 1280×720, paint 480p-derived.
// FAULT_HDMI_LAYOUT_ON_CORE_DE=1: beam CORE_DE 960×540, paint HDMI 1280×720 math
//   (ascal-pivot class — wrong domain).
// FAULT_LAYOUT_FROM_HTOTAL=1: layout_w from H_TOTAL (default 1600) not H_ACTIVE.
// CORE_DE_BEAM=1 (green optional): beam+layout 960×540 (pre-ascal insertion sim).
`timescale 1ns / 1ps

module plex_chrome_idle720_tb #(
    parameter bit FAULT_480P_GEOM = 1'b0,
    parameter bit FAULT_LEGACY_480P_LAYOUT = 1'b0,
    parameter bit FAULT_HDMI_LAYOUT_ON_CORE_DE = 1'b0,
    parameter bit FAULT_NARROW_BEAM_X = 1'b0,
    parameter bit FAULT_LAYOUT_FROM_HTOTAL = 1'b0,
    parameter int FAULT_HTOTAL_W = 1600,
    parameter bit CORE_DE_BEAM = 1'b0,
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
    input  wire        idle_sig_en,
    output wire        idle_en_mon,
    output wire [15:0] idle_phase_mon,
    output wire [11:0] mon_width,
    output wire [11:0] mon_height,
    output wire [3:0]  mon_body_scale
);

    // Paint beam: product HDMI_OUT 1280×720; CORE_DE / hdmi-on-de fault 960×540.
    wire [11:0] geom_w =
        FAULT_480P_GEOM              ? 12'd624  :
        (FAULT_HDMI_LAYOUT_ON_CORE_DE || CORE_DE_BEAM) ? 12'd960 :
                                         12'd1280;
    wire [11:0] geom_h =
        FAULT_480P_GEOM              ? 12'd480 :
        (FAULT_HDMI_LAYOUT_ON_CORE_DE || CORE_DE_BEAM) ? 12'd540 :
                                         12'd720;

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

    plex_chrome_host_if #(.MAX_CMDS(112)) u_if (
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
        .MAX_CMDS(112),
        .HIT_SCAN(48),
        .PX_PER_CLK(PX_PER_CLK),
        .FAULT_LEGACY_480P_LAYOUT(FAULT_LEGACY_480P_LAYOUT),
        .FAULT_HDMI_LAYOUT_ON_CORE_DE(FAULT_HDMI_LAYOUT_ON_CORE_DE),
        .FAULT_NARROW_BEAM_X(FAULT_NARROW_BEAM_X),
        .FAULT_LAYOUT_FROM_HTOTAL(FAULT_LAYOUT_FROM_HTOTAL),
        .FAULT_HTOTAL_W(FAULT_HTOTAL_W)
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
        .idle_sig_en(idle_sig_en),
        .chrome_sig_en(1'b0),
        .chrome_demo_en(1'b0),
        .play_beacon_en(1'b0),
        .chrome_hw(),
        .mon_width(mon_width),
        .mon_height(mon_height),
        .mon_body_scale(mon_body_scale)
    );

endmodule
