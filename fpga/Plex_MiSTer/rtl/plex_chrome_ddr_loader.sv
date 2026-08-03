// plex_chrome_ddr_loader — poll PLXC list from DDR and push to plex_chrome_host_if
//
// Default OFF (ENABLE=0): zero DDR traffic, host_we stuck 0 — nostub-safe.
// When ENABLE=1 (or `PLEX_CHROME_DDR`):
//   1) RD doorbell+0x130 (PLXC). On magic+new seq, RD list[0..count).
//   2) RE-READ PLXC (seqlock). Abort if magic gone or ctrl != snapshot
//      (rd-duck: host may overwrite body while old ctrl still valid).
//   3) Push list words + PLXC ctrl to host_if (payload before ctrl).
//      host_we/addr/data are COMBINATIONAL valid while in S_PUSH_*.
//      host_ready = CDC !wr_full. Advance li / commit last_seq only on
//      valid&&ready same edge the FIFO accepts (wr_en&&!full). Registered
//      host_we + advance-on-ready alone drops the fill-last-slot beat
//      (rd-duck 96e4a50d hole): NBA schedules next we while FIFO takes the
//      previous beat into the final slot.
//   4) Periodically WR doorbell+0x138 (PLXO) so chromePlaneHw can leave fail-closed.
//
// Host contract (ARM writeChromeCommandList):
//   invalidate PLXC magic → write body → write new PLXC magic+seq last.
// Fabric never commits a mixed HUD. See mailbox_abi_spec / plex_chrome_cmds.
//
// FAULT_NO_CTRL_REREAD: skip step 2 (red twin — accepts torn body+old ctrl).

`timescale 1ns / 1ps

module plex_chrome_ddr_loader #(
    parameter bit        ENABLE         = 1'b0,
    parameter int        MAX_CMDS       = 112,
    // Product YUV bootstrap page (same as DDR_FRAME_YUV420P_DOORBELL_PHYS).
    // NOT packed-320 0x3007_F000 — that is a historical example map only.
    parameter [31:0]     DOORBELL_PHYS  = 32'h300F_F000,
    parameter [31:0]     PLXC_OFF       = 32'h130,
    parameter [31:0]     PLXO_OFF       = 32'h138,
    parameter [31:0]     PLXL_OFF       = 32'h140,
    parameter [15:0]     POLL_DIV       = 16'd256   // idle cycles between PLXC polls
) (
    input  wire        clk,
    input  wire        reset,

    // 64-bit single-beat memory master (qword address = phys[31:3])
    output reg         m_req,
    output reg         m_we,
    output reg  [28:0] m_addr,
    output reg  [63:0] m_wdata,
    input  wire        m_gnt,       // 1-cycle grant → start of access
    input  wire        m_rd_valid,  // read data valid (1 cycle)
    input  wire [63:0] m_rdata,

    // → plex_chrome_host_if (or CDC wr port). host_ready = !wr_full.
    // host_we/addr/data are comb valid (held stable across stalls).
    input  wire        host_ready,
    output wire        host_we,
    output wire [7:0]  host_addr,
    output wire [63:0] host_wdata,

    // PLXO source (from plex_chrome mon)
    input  wire        chrome_hw,
    input  wire [11:0] mon_w,
    input  wire [11:0] mon_h,
    input  wire [3:0]  mon_scale,

    // observability
    output reg  [15:0] last_seq,
    output reg         busy,
    output reg  [31:0] cnt_loads,
    output reg  [31:0] cnt_plxo_wr,
    output reg  [31:0] cnt_bad_magic,
    output reg  [31:0] cnt_torn       // seqlock abort (ctrl changed mid-body)
);

    localparam [31:0] MAGIC_C = 32'h504C_5843; // PLXC
    localparam [31:0] MAGIC_O = 32'h504C_584F; // PLXO

    localparam [28:0] PLXC_W = 29'((DOORBELL_PHYS + PLXC_OFF) >> 3);
    localparam [28:0] PLXO_W = 29'((DOORBELL_PHYS + PLXO_OFF) >> 3);
    localparam [28:0] PLXL_W = 29'((DOORBELL_PHYS + PLXL_OFF) >> 3);

    localparam [3:0] S_IDLE        = 4'd0;
    localparam [3:0] S_RD_CTRL     = 4'd1;
    localparam [3:0] S_WAIT_CTRL   = 4'd2;
    localparam [3:0] S_RD_LIST     = 4'd3;
    localparam [3:0] S_WAIT_LIST   = 4'd4;
    localparam [3:0] S_PUSH_LIST   = 4'd5;
    localparam [3:0] S_PUSH_CTRL   = 4'd6;
    localparam [3:0] S_WR_PLXO     = 4'd7;
    localparam [3:0] S_WAIT_PLXO   = 4'd8;
    localparam [3:0] S_RD_CTRL2    = 4'd9;  // seqlock re-read
    localparam [3:0] S_WAIT_CTRL2  = 4'd10;

    reg [3:0]  st;
    reg [15:0] poll_ctr;
    reg [15:0] snap_seq;
    reg        snap_en;
    reg [7:0]  snap_count;
    reg [7:0]  li;          // list index
    reg [63:0] list_q [0:MAX_CMDS-1];
    reg [63:0] ctrl_q;
    reg        need_plxo;
    reg [15:0] plxo_hb;

    // Combinational valid while pushing — same-cycle handshake with FIFO
    // wr_en&&!wr_full. Do NOT register host_we then advance on ready (one-slot drop).
    wire push_list = ENABLE && (st == S_PUSH_LIST);
    wire push_ctrl = ENABLE && (st == S_PUSH_CTRL);
    assign host_we = push_list || push_ctrl;
    assign host_addr = push_ctrl ? 8'hFF : li;
    assign host_wdata = push_ctrl ? ctrl_q
                                  : list_q[li[$clog2(MAX_CMDS)-1:0]];

    function automatic [63:0] pack_plxo;
        input hw;
        input [11:0] w;
        input [11:0] h;
        input [3:0]  sc;
        begin
            // [31:0] magic, [32] chrome_hw, [44:33] mon_w, [56:45] mon_h, [60:57] scale
            pack_plxo = {3'd0, sc, h, w, hw, MAGIC_O};
        end
    endfunction

    integer ti;
    always @(posedge clk) begin
        if (reset) begin
            st          <= S_IDLE;
            poll_ctr    <= 16'd0;
            m_req       <= 1'b0;
            m_we        <= 1'b0;
            m_addr      <= 29'd0;
            m_wdata     <= 64'd0;
            last_seq    <= 16'd0;
            busy        <= 1'b0;
            cnt_loads   <= 32'd0;
            cnt_plxo_wr <= 32'd0;
            cnt_bad_magic <= 32'd0;
            cnt_torn    <= 32'd0;
            snap_seq    <= 16'd0;
            snap_en     <= 1'b0;
            snap_count  <= 8'd0;
            li          <= 8'd0;
            ctrl_q      <= 64'd0;
            need_plxo   <= 1'b1;
            plxo_hb     <= 16'd0;
            for (ti = 0; ti < MAX_CMDS; ti = ti + 1)
                list_q[ti] <= 64'd0;
        end else if (!ENABLE) begin
            // Hard quiet when off — no bus, no host beats (host_we comb=0 via st)
            m_req      <= 1'b0;
            m_we       <= 1'b0;
            busy       <= 1'b0;
            st         <= S_IDLE;
        end else begin
            // Drop req one cycle after grant (2-phase: req → gnt → data/complete)
            if (m_gnt)
                m_req <= 1'b0;

            case (st)
                S_IDLE: begin
                    busy <= 1'b0;
                    poll_ctr <= poll_ctr + 16'd1;
                    plxo_hb  <= plxo_hb + 16'd1;
                    if (plxo_hb == 16'd0)
                        need_plxo <= 1'b1;
                    if (need_plxo) begin
                        m_req   <= 1'b1;
                        m_we    <= 1'b1;
                        m_addr  <= PLXO_W;
                        m_wdata <= pack_plxo(chrome_hw, mon_w, mon_h, mon_scale);
                        st      <= S_WR_PLXO;
                        busy    <= 1'b1;
                    end else if (poll_ctr >= POLL_DIV) begin
                        poll_ctr <= 16'd0;
                        m_req  <= 1'b1;
                        m_we   <= 1'b0;
                        m_addr <= PLXC_W;
                        st     <= S_RD_CTRL;
                        busy   <= 1'b1;
                    end
                end

                S_RD_CTRL: begin
                    if (m_gnt)
                        st <= S_WAIT_CTRL;
                    else if (!m_req) begin
                        m_req  <= 1'b1;
                        m_we   <= 1'b0;
                        m_addr <= PLXC_W;
                    end
                end

                S_WAIT_CTRL: begin
                    if (m_rd_valid) begin
                        if (m_rdata[31:0] != MAGIC_C) begin
                            cnt_bad_magic <= cnt_bad_magic + 32'd1;
                            st <= S_IDLE;
                        end else if (m_rdata[63:48] == last_seq) begin
                            st <= S_IDLE;
                        end else begin
                            ctrl_q     <= m_rdata;
                            snap_seq   <= m_rdata[63:48];
                            snap_en    <= m_rdata[32];
                            snap_count <= (m_rdata[41:34] > MAX_CMDS[7:0]) ?
                                          MAX_CMDS[7:0] : m_rdata[41:34];
                            li <= 8'd0;
                            if (((m_rdata[41:34] > MAX_CMDS[7:0]) ? MAX_CMDS[7:0]
                                                                  : m_rdata[41:34]) == 8'd0) begin
`ifdef FAULT_NO_CTRL_REREAD
                                st <= S_PUSH_CTRL;
`else
                                st <= S_RD_CTRL2;
`endif
                            end else
                                st <= S_RD_LIST;
                        end
                    end
                end

                S_RD_LIST: begin
                    if (m_gnt)
                        st <= S_WAIT_LIST;
                    else begin
                        m_req  <= 1'b1;
                        m_we   <= 1'b0;
                        m_addr <= PLXL_W + {21'd0, li};
                    end
                end

                S_WAIT_LIST: begin
                    if (m_rd_valid) begin
                        list_q[li[$clog2(MAX_CMDS)-1:0]] <= m_rdata;
                        if (li + 8'd1 >= snap_count) begin
                            li <= 8'd0;
`ifdef FAULT_NO_CTRL_REREAD
                            // RED: commit without proving ctrl still matches body.
                            st <= S_PUSH_LIST;
`else
                            st <= S_RD_CTRL2;
`endif
                        end else begin
                            li <= li + 8'd1;
                            st <= S_RD_LIST;
                        end
                    end
                end

                // Seqlock: re-sample PLXC after body. Host must keep magic invalid
                // while rewriting body; any ctrl change vs snapshot aborts.
                S_RD_CTRL2: begin
                    if (m_gnt)
                        st <= S_WAIT_CTRL2;
                    else if (!m_req) begin
                        m_req  <= 1'b1;
                        m_we   <= 1'b0;
                        m_addr <= PLXC_W;
                    end
                end

                S_WAIT_CTRL2: begin
                    if (m_rd_valid) begin
                        if (m_rdata[31:0] != MAGIC_C) begin
                            // Invalidate window or torn — do not commit, do not bump last_seq.
                            cnt_torn <= cnt_torn + 32'd1;
                            st <= S_IDLE;
                        end else if (m_rdata != ctrl_q) begin
                            cnt_torn <= cnt_torn + 32'd1;
                            st <= S_IDLE;
                        end else if (snap_count == 8'd0) begin
                            st <= S_PUSH_CTRL;
                        end else begin
                            li <= 8'd0;
                            st <= S_PUSH_LIST;
                        end
                    end
                end

                S_PUSH_LIST: begin
                    // host_we/addr/data comb present current li. Advance only
                    // when ready — same edge FIFO does wr_en && !wr_full.
                    if (host_ready) begin
                        if (li + 8'd1 >= snap_count)
                            st <= S_PUSH_CTRL;
                        else
                            li <= li + 8'd1;
                    end
                end

                S_PUSH_CTRL: begin
                    // last_seq only on accepted ctrl beat (valid&&ready).
                    if (host_ready) begin
                        last_seq   <= snap_seq;
                        cnt_loads  <= cnt_loads + 32'd1;
                        need_plxo  <= 1'b1;
                        st         <= S_IDLE;
                    end
                end

                S_WR_PLXO: begin
                    if (m_gnt) begin
                        cnt_plxo_wr <= cnt_plxo_wr + 32'd1;
                        need_plxo   <= 1'b0;
                        st          <= S_WAIT_PLXO;
                    end else if (!m_req) begin
                        m_req   <= 1'b1;
                        m_we    <= 1'b1;
                        m_addr  <= PLXO_W;
                        m_wdata <= pack_plxo(chrome_hw, mon_w, mon_h, mon_scale);
                    end
                end

                S_WAIT_PLXO: begin
                    st <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
