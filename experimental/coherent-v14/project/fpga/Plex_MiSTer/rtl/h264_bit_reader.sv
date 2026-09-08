// Byte-addressed synchronous RBSP reader. Counts include the one-past-end
// position: 8192 bytes require 14 length bits and 17 cursor bits.
`default_nettype none
module h264_bit_reader #(
    parameter int ADDR_W = 13,
    parameter int LEN_W = ADDR_W + 1,
    parameter int BIT_W = ADDR_W + 4,
    parameter int RAM_LATENCY = 1
) (
    input wire clk, reset, load,
    input wire [BIT_W-1:0] bit_pos_i,
    input wire [LEN_W-1:0] rbsp_len,
    input wire rbsp_done,
    input wire [7:0] ram_rd,
    output wire [ADDR_W-1:0] ram_addr,
    output reg [BIT_W-1:0] bit_pos,
    output wire cur_bit, aligned, eof, ready,
    output reg error,
    input wire get_bit,
    output reg bit_valid, bit_out,
    input wire start_ue, start_se, start_u,
    input wire [4:0] u_n,
    output reg syn_busy, syn_done, syn_ok,
    output reg [15:0] ue_val,
    output reg signed [15:0] se_val
);
    localparam [2:0] IDLE=0, UE_ZERO=1, UE_VALUE=2, FIXED=3, FAILED=4;
    reg [2:0] st;
    reg [4:0] zeros, left;
    reg [15:0] acc;
    reg se_mode;
    reg [ADDR_W-1:0] issued [0:RAM_LATENCY-1];
    reg [RAM_LATENCY-1:0] issued_valid;
    wire [BIT_W-1:0] end_bit = BIT_W'(rbsp_len) << 3;
    wire capacity_bad = rbsp_len > (LEN_W'(1) << ADDR_W);
    assign ram_addr = bit_pos[ADDR_W+2:3];
    assign eof = capacity_bad || bit_pos >= end_bit;
    assign aligned = bit_pos[2:0] == 0;
    assign cur_bit = ram_rd[7 - bit_pos[2:0]];
    assign ready = !error && !eof && issued_valid[RAM_LATENCY-1] &&
                   issued[RAM_LATENCY-1] == ram_addr;

    task automatic fail;
        begin
            error <= 1;
            syn_busy <= 0;
            syn_done <= 1;
            syn_ok <= 0;
            st <= FAILED;
        end
    endtask

    always @(posedge clk) begin : reader
        integer k;
        reg [16:0] code_num;
        reg [16:0] magnitude;
        bit_valid <= 0;
        syn_done <= 0;
        if (reset || load) begin
            bit_pos <= reset ? '0 : bit_pos_i;
            issued_valid <= '0;
            for (k = 0; k < RAM_LATENCY; k = k + 1) issued[k] <= '0;
            st <= IDLE;
            syn_busy <= 0;
            syn_ok <= 0;
            error <= 0;
            ue_val <= 0;
            se_val <= 0;
            bit_out <= 0;
            zeros <= 0;
            left <= 0;
            acc <= 0;
            se_mode <= 0;
        end else begin
            issued[0] <= ram_addr;
            // A byte written while this cursor was at EOF must traverse the
            // RAM pipeline before newly increased rbsp_len makes it readable.
            issued_valid[0] <= !eof;
            for (k = 1; k < RAM_LATENCY; k = k + 1) begin
                issued[k] <= issued[k-1];
                issued_valid[k] <= issued_valid[k-1];
            end
            if (capacity_bad) fail();
            else case (st)
            IDLE: begin
                if (start_ue || start_se) begin
                    zeros <= 0;
                    acc <= 0;
                    se_mode <= start_se;
                    syn_busy <= 1;
                    syn_ok <= 0;
                    st <= UE_ZERO;
                end else if (start_u) begin
                    if (u_n > 16) fail();
                    else begin
                        left <= u_n;
                        acc <= 0;
                        syn_busy <= 1;
                        syn_ok <= 0;
                        st <= FIXED;
                    end
                end else if (get_bit) begin
                    if (eof && rbsp_done) fail();
                    else if (ready) begin
                        bit_out <= cur_bit;
                        bit_valid <= 1;
                        bit_pos <= bit_pos + 1'b1;
                    end
                end
            end
            UE_ZERO: begin
                if (eof && rbsp_done) fail();
                else if (ready) begin
                    bit_pos <= bit_pos + 1'b1;
                    if (!cur_bit) begin
                        if (zeros == 16) fail();
                        else zeros <= zeros + 1'b1;
                    end else if (zeros == 0) begin
                        ue_val <= 0;
                        se_val <= 0;
                        syn_ok <= 1;
                        syn_busy <= 0;
                        syn_done <= 1;
                        st <= IDLE;
                    end else begin
                        left <= zeros;
                        st <= UE_VALUE;
                    end
                end
            end
            UE_VALUE: begin
                if (eof && rbsp_done) fail();
                else if (ready) begin
                    bit_pos <= bit_pos + 1'b1;
                    acc <= {acc[14:0], cur_bit};
                    left <= left - 1'b1;
                    if (left == 1) begin
                        code_num = (17'd1 << zeros) - 1'b1 + {1'b0, acc[14:0], cur_bit};
                        magnitude = (code_num + 1'b1) >> 1;
                        if (code_num > 65535 ||
                            (se_mode && code_num[0] && magnitude > 32767)) fail();
                        else begin
                            ue_val <= code_num[15:0];
                            se_val <= code_num[0] ? $signed(magnitude[15:0]) :
                                      -$signed(code_num[16:1]);
                            syn_busy <= 0;
                            syn_done <= 1;
                            syn_ok <= 1;
                            st <= IDLE;
                        end
                    end
                end
            end
            FIXED: begin
                if (left == 0) begin
                    ue_val <= acc;
                    se_val <= $signed(acc);
                    syn_busy <= 0;
                    syn_done <= 1;
                    syn_ok <= 1;
                    st <= IDLE;
                end else if (eof && rbsp_done) fail();
                else if (ready) begin
                    acc <= {acc[14:0], cur_bit};
                    bit_pos <= bit_pos + 1'b1;
                    left <= left - 1'b1;
                end
            end
            FAILED: begin
                syn_busy <= 0;
                syn_ok <= 0;
            end
            default: fail();
            endcase
        end
    end
endmodule
`default_nettype wire
