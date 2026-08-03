// E2E: plex_chrome_ddr_loader → host_if → plex_chrome
// Proves ARM-style DDR PLXC becomes pixels without ARM baking.
`timescale 1ns / 1ps

module plex_chrome_e2e_tb (
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
    output wire        chrome_hw,
    output wire        cfg_enable_mon,
    output wire        idle_en_mon,
    // TB mem preload
    input  wire        mem_we_host,
    input  wire [28:0] mem_addr_host,
    input  wire [63:0] mem_wdata_host,
    // loader mon
    output wire [15:0] last_seq,
    output wire [31:0] cnt_loads,
    output wire [63:0] mem_plxo_q,
    input  wire        has_frame,
    input  wire [1:0]  osd_idle_mode
);

    reg [63:0] mem [0:511];
    integer ii;
    initial for (ii = 0; ii < 512; ii = ii + 1) mem[ii] = 64'd0;

    always @(posedge clk) begin
        if (mem_we_host && mem_addr_host < 29'd512)
            mem[mem_addr_host[8:0]] <= mem_wdata_host;
    end

    wire        m_req, m_we;
    wire [28:0] m_addr;
    wire [63:0] m_wdata;
    reg         m_gnt, m_rd_valid;
    reg  [63:0] m_rdata;
    reg         pend_rd;
    reg  [28:0] pend_addr;

    always @(posedge clk) begin
        if (reset) begin
            m_gnt <= 1'b0;
            m_rd_valid <= 1'b0;
            m_rdata <= 64'd0;
            pend_rd <= 1'b0;
            pend_addr <= 29'd0;
        end else begin
            m_gnt <= 1'b0;
            m_rd_valid <= 1'b0;
            if (pend_rd) begin
                m_rd_valid <= 1'b1;
                m_rdata <= (pend_addr < 29'd512) ? mem[pend_addr[8:0]] : 64'd0;
                pend_rd <= 1'b0;
            end else if (m_req) begin
                m_gnt <= 1'b1;
                pend_addr <= m_addr;
                if (m_we) begin
                    if (m_addr < 29'd512)
                        mem[m_addr[8:0]] <= m_wdata;
                end else
                    pend_rd <= 1'b1;
            end
        end
    end

    wire        host_we;
    wire [7:0]  host_addr;
    wire [63:0] host_wdata;
    wire [11:0] mon_w, mon_h;
    wire [3:0]  mon_scale;

    plex_chrome_ddr_loader #(
        .ENABLE(1'b1),
        .MAX_CMDS(48),
        .DOORBELL_PHYS(32'h0),
        .POLL_DIV(16'd4)
    ) u_loader (
        .clk(clk),
        .reset(reset),
        .m_req(m_req),
        .m_we(m_we),
        .m_addr(m_addr),
        .m_wdata(m_wdata),
        .m_gnt(m_gnt),
        .m_rd_valid(m_rd_valid),
        .m_rdata(m_rdata),
        .host_we(host_we),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .chrome_hw(chrome_hw),
        .mon_w(mon_w),
        .mon_h(mon_h),
        .mon_scale(mon_scale),
        .last_seq(last_seq),
        .busy(),
        .cnt_loads(cnt_loads),
        .cnt_plxo_wr(),
        .cnt_bad_magic()
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
    assign idle_en_mon = idle_en;

    plex_chrome_host_if #(.MAX_CMDS(48)) u_if (
        .clk(clk),
        .reset(reset),
        .host_we(host_we),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .has_frame(has_frame),
        .osd_idle_mode(osd_idle_mode),
        .idle_phase_in(16'd0),
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
        .chrome_hw(chrome_hw),
        .mon_width(mon_w),
        .mon_height(mon_h),
        .mon_body_scale(mon_scale)
    );

    assign mem_plxo_q = mem[9'h27]; // 0x138/8

endmodule
