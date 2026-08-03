// TB top: fake 64-bit mem + dual ENABLE on/off loaders.
`timescale 1ns / 1ps

module plex_chrome_ddr_loader_tb (
    input  wire        clk,
    input  wire        reset,
    input  wire        mem_we_host,   // TB preload
    input  wire [28:0] mem_addr_host,
    input  wire [63:0] mem_wdata_host,
    input  wire        run_tick,      // advance soft time (unused; clk is enough)
    // observe ENABLE=1
    output wire        host_we_on,
    output wire [7:0]  host_addr_on,
    output wire [63:0] host_wdata_on,
    output wire [15:0] last_seq_on,
    output wire [31:0] cnt_loads_on,
    output wire [31:0] cnt_plxo_on,
    output wire [31:0] cnt_bad_on,
    output wire [63:0] mem_plxo_q,
    // observe ENABLE=0 quiet
    output wire        host_we_off,
    output wire        m_req_off
);

    // Simple dual-port-ish mem model: 512 qwords
    reg [63:0] mem [0:511];
    integer i;
    initial begin
        for (i = 0; i < 512; i = i + 1)
            mem[i] = 64'd0;
    end

    always @(posedge clk) begin
        if (mem_we_host && mem_addr_host < 29'd512)
            mem[mem_addr_host[8:0]] <= mem_wdata_host;
    end

    // Arbiter: 2-phase — cycle0 req, cycle1 gnt(+write), cycle2 rd_valid for reads.
    wire        m_req_on, m_we_on;
    wire [28:0] m_addr_on;
    wire [63:0] m_wdata_on;
    reg         m_gnt_on, m_rd_valid_on;
    reg  [63:0] m_rdata_on;
    reg         pend_rd;
    reg  [28:0] pend_addr;
    reg         pend_we;
    reg  [63:0] pend_wdata;

    wire        m_req_off_w, m_we_off;
    wire [28:0] m_addr_off;
    wire [63:0] m_wdata_off;

    always @(posedge clk) begin
        if (reset) begin
            m_gnt_on      <= 1'b0;
            m_rd_valid_on <= 1'b0;
            m_rdata_on    <= 64'd0;
            pend_rd       <= 1'b0;
            pend_addr     <= 29'd0;
            pend_we       <= 1'b0;
            pend_wdata    <= 64'd0;
        end else begin
            m_gnt_on      <= 1'b0;
            m_rd_valid_on <= 1'b0;
            if (pend_rd) begin
                m_rd_valid_on <= 1'b1;
                m_rdata_on    <= (pend_addr < 29'd512) ? mem[pend_addr[8:0]] : 64'd0;
                pend_rd       <= 1'b0;
            end else if (m_req_on) begin
                m_gnt_on   <= 1'b1;
                pend_addr  <= m_addr_on;
                pend_we    <= m_we_on;
                pend_wdata <= m_wdata_on;
                if (m_we_on) begin
                    if (m_addr_on < 29'd512)
                        mem[m_addr_on[8:0]] <= m_wdata_on;
                end else begin
                    pend_rd <= 1'b1;
                end
            end
        end
    end

    // DOORBELL 0x3007F000 → qword base = 0x600FE00 — too large for 512.
    // Use DOORBELL_PHYS=0 so offsets map 0x130/8 etc. into small mem.
    plex_chrome_ddr_loader #(
        .ENABLE(1'b1),
        .MAX_CMDS(48),
        .DOORBELL_PHYS(32'h0),
        .POLL_DIV(16'd4)
    ) u_on (
        .clk(clk),
        .reset(reset),
        .m_req(m_req_on),
        .m_we(m_we_on),
        .m_addr(m_addr_on),
        .m_wdata(m_wdata_on),
        .m_gnt(m_gnt_on),
        .m_rd_valid(m_rd_valid_on),
        .m_rdata(m_rdata_on),
        .host_we(host_we_on),
        .host_addr(host_addr_on),
        .host_wdata(host_wdata_on),
        .chrome_hw(1'b1),
        .mon_w(12'd1280),
        .mon_h(12'd720),
        .mon_scale(4'd3),
        .last_seq(last_seq_on),
        .busy(),
        .cnt_loads(cnt_loads_on),
        .cnt_plxo_wr(cnt_plxo_on),
        .cnt_bad_magic(cnt_bad_on)
    );

    plex_chrome_ddr_loader #(
        .ENABLE(1'b0),
        .DOORBELL_PHYS(32'h0),
        .POLL_DIV(16'd4)
    ) u_off (
        .clk(clk),
        .reset(reset),
        .m_req(m_req_off_w),
        .m_we(m_we_off),
        .m_addr(m_addr_off),
        .m_wdata(m_wdata_off),
        .m_gnt(1'b0),
        .m_rd_valid(1'b0),
        .m_rdata(64'd0),
        .host_we(host_we_off),
        .host_addr(),
        .host_wdata(),
        .chrome_hw(1'b1),
        .mon_w(12'd1280),
        .mon_h(12'd720),
        .mon_scale(4'd3),
        .last_seq(),
        .busy(),
        .cnt_loads(),
        .cnt_plxo_wr(),
        .cnt_bad_magic()
    );

    assign m_req_off = m_req_off_w;
    // PLXO at offset 0x138 → qword 0x27
    assign mem_plxo_q = mem[9'h27];
    wire _u = run_tick;

endmodule
