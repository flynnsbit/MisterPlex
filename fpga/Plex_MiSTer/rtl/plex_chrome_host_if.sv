// plex_chrome_host_if — PLXC control + list push toward plex_chrome
//
// host_we beats:
//   addr 0xFF = PLXC control qword
//   addr 0..MAX-1 = command list words
// list_we is derived from host_we — never const 0 (c74c6863).
//
// Fabric idle phase (PLEX_FAB_IDLE / fab_phase_en):
//   When fab_phase_en=1, idle_phase advances on vsync rising (fabric owns timing;
//   ARM does not doorbell phase). When 0, idle_phase tracks idle_phase_in.

`timescale 1ns / 1ps

module plex_chrome_host_if #(
    parameter int MAX_CMDS = 112
) (
    input  wire        clk,
    input  wire        reset,

    input  wire        host_we,
    input  wire [7:0]  host_addr,
    input  wire [63:0] host_wdata,

    input  wire        has_frame,
    input  wire [1:0]  osd_idle_mode,
    input  wire [15:0] idle_phase_in,
    // Fabric phase: vsync level (edge inside). fab_phase_en=0 → host phase only.
    input  wire        vsync_in,
    input  wire        fab_phase_en,

    output reg         list_we,
    output reg  [7:0]  list_waddr,
    output reg  [63:0] list_wdata,

    output reg         cfg_enable,
    output reg  [15:0] cfg_seq,
    output reg  [7:0]  cfg_cmd_count,

    output reg         idle_en,
    output reg  [1:0]  idle_mode,
    output reg  [15:0] idle_phase,

    output reg         chrome_hw_sticky,
    output reg  [15:0] plxo_seq
);

    localparam [31:0] MAGIC_C = 32'h504C_5843; // PLXC
    wire [7:0] count_field = host_wdata[41:34];
    wire [7:0] count_clamped =
        (count_field > MAX_CMDS[7:0]) ? MAX_CMDS[7:0] : count_field;

    reg vsync_d;

    always @(posedge clk) begin
        if (reset) begin
            list_we       <= 1'b0;
            list_waddr    <= 8'd0;
            list_wdata    <= 64'd0;
            cfg_enable    <= 1'b0;
            cfg_seq       <= 16'd0;
            cfg_cmd_count <= 8'd0;
            idle_en       <= 1'b0;
            idle_mode     <= 2'd0;
            idle_phase    <= 16'd0;
            chrome_hw_sticky <= 1'b1;
            plxo_seq      <= 16'd0;
            vsync_d       <= 1'b0;
        end else begin
            list_we <= 1'b0;
            chrome_hw_sticky <= 1'b1;
            idle_mode  <= osd_idle_mode;
            idle_en <= (!has_frame) && (osd_idle_mode != 2'd3);
            vsync_d <= vsync_in;

            if (fab_phase_en) begin
                if (vsync_in && !vsync_d)
                    idle_phase <= idle_phase + 16'd1;
            end else begin
                idle_phase <= idle_phase_in;
            end

            if (host_we) begin
                if (host_addr == 8'hFF) begin
                    if (host_wdata[31:0] == MAGIC_C) begin
                        cfg_enable    <= host_wdata[32];
                        cfg_cmd_count <= count_clamped;
                        cfg_seq       <= host_wdata[63:48];
                        plxo_seq      <= plxo_seq + 16'd1;
                    end
                end else if (host_addr < MAX_CMDS[7:0]) begin
                    list_we    <= 1'b1;
                    list_waddr <= host_addr;
                    list_wdata <= host_wdata;
                end
            end
        end
    end

endmodule
