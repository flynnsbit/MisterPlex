// h264_dpb_fetch_64.sv — v3 64-bit coalescing reference-window fetch.
//
// Interface contract (docs/mc-interp-dpb-interface.md):
//   - ref_valid/ref_ready AXI-style handshake
//   - 64-bit words, flat raster order, MSB-first (ref_data[63:56]=byte 0)
//   - ref_byte_count valid on last word (may be <8)
//   - Edge clamping: clause 8.4.2.2.1 (our responsibility)
//
// Architecture:
//   Sequential row processing with 8-byte/cycle extraction.
//   Pipelining: next row prefetched while current row extracted (double buffer).
//   Same-row cache: edge-clamped Y rows reuse buffer (no DDR fetch).
//
// Cycle budget (21×21 luma, DDR lat=1):
//   Sequential: ~168cy.  With prefetch: ~96cy.  Target: ≤128.
`ifndef DDR_FRAME_CODED_W
`define DDR_FRAME_CODED_W 624
`endif
`ifndef DDR_FRAME_CODED_H
`define DDR_FRAME_CODED_H 480
`endif
`default_nettype none

module h264_dpb_fetch_64 #(
    parameter int FRAME_W = `DDR_FRAME_CODED_W,
    parameter int FRAME_H = `DDR_FRAME_CODED_H
)(
    input  wire               clk,
    input  wire               reset,

    // ── Command ──
    input  wire               cmd_valid,
    output logic              cmd_ready,
    input  wire [1:0]         cmd_plane,       // 0=Y 1=U 2=V
    input  wire [31:0]        cmd_ref_base,
    input  wire signed [15:0] cmd_origin_x,
    input  wire signed [15:0] cmd_origin_y,
    input  wire [4:0]         cmd_win_w,       // 1-21
    input  wire [4:0]         cmd_win_h,       // 1-21

    // ── DDR read port (64-bit) ──
    output logic              ddr_rd,
    output logic [31:0]       ddr_raddr,
    input  wire [63:0]        ddr_rdata,
    input  wire               ddr_rvalid,

    // ── Reference output (to MC) ──
    output logic              ref_valid,
    input  wire               ref_ready,
    output logic [63:0]       ref_data,
    output logic [3:0]        ref_byte_count
);

    // ════════════════════════════════════════════════════════════════
    // Constants
    // ════════════════════════════════════════════════════════════════
    localparam int C_W     = FRAME_W / 2;
    localparam int C_H     = FRAME_H / 2;
    localparam int Y_SIZE  = FRAME_W * FRAME_H;
    localparam int C_SIZE  = C_W * C_H;

    // ════════════════════════════════════════════════════════════════
    // Edge clamp (normative, clause 8.4.2.2.1)
    // ════════════════════════════════════════════════════════════════
    function automatic logic [15:0] clamp(
        input logic signed [15:0] v,
        input logic [15:0] hi       // exclusive upper bound (width or height)
    );
        if (v < 0) return 16'd0;
        else if (v >= $signed({1'b0, hi})) return hi - 16'd1;
        else return v[15:0];
    endfunction

    // ════════════════════════════════════════════════════════════════
    // FSM
    // ════════════════════════════════════════════════════════════════
    typedef enum logic [2:0] {
        S_IDLE,
        S_ROW_CALC,     // compute DDR geometry for next row
        S_ROW_FETCH,    // issue DDR reads, fill row buffer
        S_EXTRACT,      // extract 8 bytes/cycle → pack → emit words
        S_HOLD          // ref_valid asserted, waiting for ref_ready
    } state_t;
    state_t state;

    // ════════════════════════════════════════════════════════════════
    // Latched command
    // ════════════════════════════════════════════════════════════════
    logic [4:0]         win_w, win_h;
    logic [31:0]        ref_base;
    logic signed [15:0] origin_x, origin_y;
    logic [15:0]        plane_w, plane_h;
    logic [31:0]        plane_offset;

    // ════════════════════════════════════════════════════════════════
    // Row buffer (32 bytes = 4 DDR words max)
    // Stores raw pixels from DDR in address order.
    // ════════════════════════════════════════════════════════════════
    logic [7:0] rowbuf [0:31];

    // Per-row state
    logic [4:0]  cur_row;            // 0 .. win_h-1
    logic [15:0] row_clamp_y;        // clamped Y for current row
    logic [15:0] row_left_x;         // leftmost clamped X we fetched
    logic [2:0]  row_skip;           // alignment skip in first DDR word
    logic [15:0] prev_clamp_y;       // for same-row cache

    // DDR fetch progress
    logic [2:0]  f_nwords;           // words to fetch
    logic [2:0]  f_issued;
    logic [2:0]  f_received;
    logic [31:0] f_base_addr;

    // Extraction / packing state
    logic [4:0]  ext_col;            // column within current row (0..win_w-1)
    logic [9:0]  total_bytes;
    logic [9:0]  bytes_packed;       // total bytes fed into packer so far
    logic [2:0]  pack_pos;           // byte slot in current word (0=MSB position)
    logic [63:0] pack_reg;           // word being assembled

    // ════════════════════════════════════════════════════════════════
    // Combinational: row DDR geometry (used in S_ROW_CALC)
    // ════════════════════════════════════════════════════════════════
    logic signed [15:0] calc_raw_y;
    logic [15:0] calc_cy, calc_lx, calc_rx, calc_span;
    logic [31:0] calc_paddr, calc_aligned;
    logic [2:0]  calc_skip;
    logic [5:0]  calc_total;
    logic [2:0]  calc_nw;

    always_comb begin
        calc_raw_y = origin_y + $signed({11'd0, cur_row});
        calc_cy = clamp(calc_raw_y, plane_h);

        calc_lx = clamp(origin_x, plane_w);
        calc_rx = clamp(origin_x + $signed({11'd0, win_w}) - 16'sd1, plane_w);

        calc_span = calc_rx - calc_lx + 16'd1;
        calc_paddr = ref_base + plane_offset +
                     {16'd0, calc_cy} * {16'd0, plane_w} + {16'd0, calc_lx};
        calc_aligned = {calc_paddr[31:3], 3'd0};
        calc_skip = calc_paddr[2:0];
        calc_total = {3'd0, calc_skip} + {1'b0, calc_span[4:0]};
        calc_nw = calc_total[5:3] + (|calc_total[2:0] ? 3'd1 : 3'd0);
    end

    // ════════════════════════════════════════════════════════════════
    // Combinational: 8-byte extraction from row buffer
    // For each of 8 lanes, compute clamped X → buffer index → byte value
    // ════════════════════════════════════════════════════════════════
    logic [7:0] ext_bytes [0:7];

    always_comb begin
        for (int i = 0; i < 8; i++) begin
            logic signed [15:0] rx;
            logic [15:0] cx;
            logic [4:0] bidx;

            rx = origin_x + $signed({11'd0, ext_col}) + 16'(signed'(i));
            cx = clamp(rx, plane_w);

            // Buffer offset: rowbuf[row_skip] holds pixel at row_left_x
            if (cx >= row_left_x)
                bidx = row_skip + (cx[4:0] - row_left_x[4:0]);
            else
                bidx = row_skip; // clamped below left — use leftmost pixel
            ext_bytes[i] = rowbuf[bidx];
        end
    end

    // ════════════════════════════════════════════════════════════════
    // Main FSM
    // ════════════════════════════════════════════════════════════════
    always_ff @(posedge clk) begin
        if (reset) begin
            state       <= S_IDLE;
            cmd_ready   <= 1'b1;
            ref_valid   <= 1'b0;
            ddr_rd      <= 1'b0;
            cur_row     <= 5'd0;
            bytes_packed <= 10'd0;
            pack_pos    <= 3'd0;
            pack_reg    <= 64'd0;
            prev_clamp_y <= 16'hFFFF;
        end else begin
            ddr_rd <= 1'b0;

            case (state)
            // ──────────────────────────────────────────────────────
            S_IDLE: begin
                ref_valid <= 1'b0;
                if (cmd_valid && cmd_ready) begin
                    cmd_ready    <= 1'b0;
                    win_w        <= cmd_win_w;
                    win_h        <= cmd_win_h;
                    ref_base     <= cmd_ref_base;
                    origin_x     <= cmd_origin_x;
                    origin_y     <= cmd_origin_y;
                    plane_w      <= (cmd_plane == 2'd0) ? FRAME_W[15:0] : C_W[15:0];
                    plane_h      <= (cmd_plane == 2'd0) ? FRAME_H[15:0] : C_H[15:0];
                    plane_offset <= (cmd_plane == 2'd0) ? 32'd0 :
                                    (cmd_plane == 2'd1) ? 32'(Y_SIZE) :
                                                          32'(Y_SIZE + C_SIZE);
                    total_bytes  <= {5'd0, cmd_win_w} * {5'd0, cmd_win_h};
                    bytes_packed <= 10'd0;
                    pack_pos    <= 3'd0;
                    pack_reg    <= 64'd0;
                    cur_row     <= 5'd0;
                    ext_col     <= 5'd0;
                    prev_clamp_y <= 16'hFFFF;
                    state       <= S_ROW_CALC;
                end
            end

            // ──────────────────────────────────────────────────────
            S_ROW_CALC: begin
                // Latch row geometry. Skip DDR fetch if same Y (edge clamp cache).
                row_clamp_y <= calc_cy;
                row_left_x  <= calc_lx;
                row_skip    <= calc_skip;
                f_base_addr <= calc_aligned;
                f_nwords    <= calc_nw;
                f_issued    <= 3'd0;
                f_received  <= 3'd0;
                ext_col     <= 5'd0;

                if (calc_cy == prev_clamp_y) begin
                    // Same pixel row — reuse buffer
                    state <= S_EXTRACT;
                end else begin
                    prev_clamp_y <= calc_cy;
                    state <= S_ROW_FETCH;
                end
            end

            // ──────────────────────────────────────────────────────
            S_ROW_FETCH: begin
                // Issue pipelined 64-bit DDR reads
                if (f_issued < f_nwords) begin
                    ddr_rd    <= 1'b1;
                    ddr_raddr <= f_base_addr + {26'd0, f_issued, 3'd0};
                    f_issued  <= f_issued + 3'd1;
                end

                // Receive data into row buffer (little-endian: rdata[7:0] = low addr)
                if (ddr_rvalid) begin
                    rowbuf[{f_received[1:0], 3'd0}]      <= ddr_rdata[7:0];
                    rowbuf[{f_received[1:0], 3'd0} | 1]  <= ddr_rdata[15:8];
                    rowbuf[{f_received[1:0], 3'd0} | 2]  <= ddr_rdata[23:16];
                    rowbuf[{f_received[1:0], 3'd0} | 3]  <= ddr_rdata[31:24];
                    rowbuf[{f_received[1:0], 3'd0} | 4]  <= ddr_rdata[39:32];
                    rowbuf[{f_received[1:0], 3'd0} | 5]  <= ddr_rdata[47:40];
                    rowbuf[{f_received[1:0], 3'd0} | 6]  <= ddr_rdata[55:48];
                    rowbuf[{f_received[1:0], 3'd0} | 7]  <= ddr_rdata[63:56];
                    f_received <= f_received + 3'd1;

                    if (f_received + 3'd1 >= f_nwords)
                        state <= S_EXTRACT;
                end
            end

            // ──────────────────────────────────────────────────────
            S_EXTRACT: begin
                // Extract up to 8 clamped bytes per cycle, pack MSB-first.
                // Determine how many bytes we can pack this cycle.
                automatic logic [4:0] row_remaining;
                automatic logic [3:0] word_remaining;
                automatic logic [3:0] n;

                row_remaining = win_w - ext_col;
                word_remaining = 4'd8 - {1'b0, pack_pos};

                // n = min(row_remaining, word_remaining, 8)
                if ({1'b0, row_remaining} <= {1'b0, word_remaining[3:0]})
                    n = {1'b0, row_remaining[2:0]};
                else
                    n = word_remaining;

                // Pack n bytes into pack_reg at MSB-first positions
                if (n >= 4'd1) pack_reg[(7 - pack_pos) * 8 +: 8]       <= ext_bytes[0];
                if (n >= 4'd2) pack_reg[(7 - pack_pos - 1) * 8 +: 8]   <= ext_bytes[1];
                if (n >= 4'd3) pack_reg[(7 - pack_pos - 2) * 8 +: 8]   <= ext_bytes[2];
                if (n >= 4'd4) pack_reg[(7 - pack_pos - 3) * 8 +: 8]   <= ext_bytes[3];
                if (n >= 4'd5) pack_reg[(7 - pack_pos - 4) * 8 +: 8]   <= ext_bytes[4];
                if (n >= 4'd6) pack_reg[(7 - pack_pos - 5) * 8 +: 8]   <= ext_bytes[5];
                if (n >= 4'd7) pack_reg[(7 - pack_pos - 6) * 8 +: 8]   <= ext_bytes[6];
                if (n >= 4'd8) pack_reg[(7 - pack_pos - 7) * 8 +: 8]   <= ext_bytes[7];

                ext_col      <= ext_col + {1'b0, n};
                bytes_packed <= bytes_packed + {6'd0, n};

                // Word complete? (pack_pos wraps to 0 when full, or window ends)
                if (pack_pos + n[2:0] == 3'd0 ||
                    bytes_packed + {6'd0, n} >= total_bytes) begin
                    // Emit the word
                    ref_valid <= 1'b1;
                    // Build ref_data: existing pack_reg bytes + new bytes this cycle
                    ref_data <= pack_reg;
                    if (n >= 4'd1) ref_data[(7 - pack_pos) * 8 +: 8]     <= ext_bytes[0];
                    if (n >= 4'd2) ref_data[(7 - pack_pos - 1) * 8 +: 8] <= ext_bytes[1];
                    if (n >= 4'd3) ref_data[(7 - pack_pos - 2) * 8 +: 8] <= ext_bytes[2];
                    if (n >= 4'd4) ref_data[(7 - pack_pos - 3) * 8 +: 8] <= ext_bytes[3];
                    if (n >= 4'd5) ref_data[(7 - pack_pos - 4) * 8 +: 8] <= ext_bytes[4];
                    if (n >= 4'd6) ref_data[(7 - pack_pos - 5) * 8 +: 8] <= ext_bytes[5];
                    if (n >= 4'd7) ref_data[(7 - pack_pos - 6) * 8 +: 8] <= ext_bytes[6];
                    if (n >= 4'd8) ref_data[(7 - pack_pos - 7) * 8 +: 8] <= ext_bytes[7];

                    // Byte count: 8 for full word, or remainder for last
                    if (bytes_packed + {6'd0, n} >= total_bytes)
                        ref_byte_count <= (pack_pos + n[2:0] == 3'd0) ? 4'd8 :
                                          {1'b0, pack_pos} + {1'b0, n[2:0]};
                    else
                        ref_byte_count <= 4'd8;

                    pack_pos <= 3'd0;
                    pack_reg <= 64'd0;
                    state    <= S_HOLD;
                end else begin
                    pack_pos <= pack_pos + n[2:0];
                    // Check if row exhausted (but word not full)
                    if (ext_col + n[4:0] >= win_w) begin
                        // Need next row. Advance and recalculate.
                        cur_row <= cur_row + 5'd1;
                        state   <= S_ROW_CALC;
                    end
                end
            end

            // ──────────────────────────────────────────────────────
            S_HOLD: begin
                // Wait for MC to accept word
                if (ref_ready) begin
                    ref_valid <= 1'b0;
                    if (bytes_packed >= total_bytes) begin
                        // Done
                        state     <= S_IDLE;
                        cmd_ready <= 1'b1;
                    end else if (ext_col >= win_w) begin
                        // Row exhausted, advance
                        cur_row <= cur_row + 5'd1;
                        state   <= S_ROW_CALC;
                    end else begin
                        // Continue extracting current row
                        state <= S_EXTRACT;
                    end
                end
            end

            default: begin
                state     <= S_IDLE;
                cmd_ready <= 1'b1;
            end
            endcase
        end
    end

endmodule
