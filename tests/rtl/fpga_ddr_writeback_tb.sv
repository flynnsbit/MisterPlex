// fpga_ddr_writeback testbench — verify byte accumulation, BE, and doorbell ABI.
// Doorbell ABI: lo32=MAGIC_PLXK(0x504C584B), hi32={bank[31], format[30:29]=2'b01, seq[28:0]}
`timescale 1ns/1ps

module fpga_ddr_writeback_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg reset = 1;
    reg dpb_wr_en = 0;
    reg [31:0] dpb_wr_addr = 0;
    reg [7:0] dpb_wr_data = 0;
    reg frame_done = 0;

    wire ddr_want;
    reg  ddr_busy = 0;
    wire [7:0] ddr_burstcnt;
    wire [28:0] ddr_addr;
    wire [63:0] ddr_din;
    wire [7:0] ddr_be;
    wire ddr_we;
    wire ddr_rd;
    wire [15:0] frames_written;
    wire active;

    fpga_ddr_writeback #(
        .PHYS_BASE(32'h3000_0000),
        .BANK_STRIDE_BYTES(32'h0008_0000),
        .DOORBELL_PHYS(32'h300F_F000)
    ) dut (
        .clk(clk),
        .reset(reset),
        .dpb_wr_en(dpb_wr_en),
        .dpb_wr_addr(dpb_wr_addr),
        .dpb_wr_data(dpb_wr_data),
        .frame_done(frame_done),
        .ddr_want(ddr_want),
        .ddr_busy(ddr_busy),
        .ddr_burstcnt(ddr_burstcnt),
        .ddr_addr(ddr_addr),
        .ddr_din(ddr_din),
        .ddr_be(ddr_be),
        .ddr_we(ddr_we),
        .ddr_rd(ddr_rd),
        .frames_written(frames_written),
        .active(active)
    );

    integer i;
    integer errors = 0;

    task write_byte(input [31:0] addr, input [7:0] data);
        begin
            @(posedge clk);
            dpb_wr_en <= 1;
            dpb_wr_addr <= addr;
            dpb_wr_data <= data;
            @(posedge clk);
            dpb_wr_en <= 0;
        end
    endtask

    task wait_ddr_write;
        begin
            while (!ddr_we) @(posedge clk);
            @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("fpga_ddr_writeback_tb.vcd");
        $dumpvars(0, fpga_ddr_writeback_tb);

        repeat(5) @(posedge clk);
        reset <= 0;
        repeat(5) @(posedge clk);

        // ── TEST 1: Full 8-byte qword accumulation ──
        $display("TEST 1: 8-byte accumulation + BE=FF");
        for (i = 0; i < 8; i = i + 1)
            write_byte(32'd0 + i, 8'hA0 + i[7:0]);

        wait_ddr_write;

        if (ddr_addr !== 29'h0600_0000) begin
            $display("FAIL T1: addr=%h exp 06000000", ddr_addr);
            errors = errors + 1;
        end
        if (ddr_din !== 64'hA7A6A5A4A3A2A1A0) begin
            $display("FAIL T1: din=%h exp A7A6A5A4A3A2A1A0", ddr_din);
            errors = errors + 1;
        end
        if (ddr_be !== 8'hFF) begin
            $display("FAIL T1: be=%h exp FF", ddr_be);
            errors = errors + 1;
        end
        if (ddr_burstcnt !== 8'd1) begin
            $display("FAIL T1: burstcnt=%d exp 1", ddr_burstcnt);
            errors = errors + 1;
        end

        repeat(10) @(posedge clk);

        // ── TEST 2: Doorbell ABI ──
        // hi32 = {bank=0, format=2'b01, seq=29'd1}
        // Expected hi32 = 32'b0_01_00000000000000000000000000001 = 32'h2000_0001
        // Full 64b = {32'h2000_0001, 32'h504C_584B}
        $display("TEST 2: doorbell ABI (format=1 YUV420p)");
        @(posedge clk);
        frame_done <= 1;
        @(posedge clk);
        frame_done <= 0;

        wait_ddr_write;

        // Address: 0x300FF000 >> 3 = 29'h0601FE00
        if (ddr_addr !== 29'h0601_FE00) begin
            $display("FAIL T2: addr=%h exp 0601FE00", ddr_addr);
            errors = errors + 1;
        end
        // lo32 = PLXK magic
        if (ddr_din[31:0] !== 32'h504C_584B) begin
            $display("FAIL T2: lo32=%h exp 504C584B", ddr_din[31:0]);
            errors = errors + 1;
        end
        // hi32[31] = bank = 0 (first frame written to bank 0)
        if (ddr_din[63] !== 1'b0) begin
            $display("FAIL T2: bank=%b exp 0", ddr_din[63]);
            errors = errors + 1;
        end
        // hi32[30:29] = format = 2'b01 (YUV420p — CRITICAL for ddr_frame_store acceptance)
        if (ddr_din[62:61] !== 2'b01) begin
            $display("FAIL T2: format=%b exp 01", ddr_din[62:61]);
            errors = errors + 1;
        end
        // hi32[28:0] = seq = 1 (first doorbell)
        if (ddr_din[60:32] !== 29'd1) begin
            $display("FAIL T2: seq=%d exp 1", ddr_din[60:32]);
            errors = errors + 1;
        end
        if (ddr_be !== 8'hFF) begin
            $display("FAIL T2: be=%h exp FF", ddr_be);
            errors = errors + 1;
        end
        if (frames_written !== 16'd1) begin
            $display("FAIL T2: frames_written=%d exp 1", frames_written);
            errors = errors + 1;
        end

        repeat(10) @(posedge clk);

        // ── TEST 3: Bank toggle — second frame goes to bank 1 ──
        $display("TEST 3: bank toggle (writes to bank 1)");
        for (i = 0; i < 8; i = i + 1)
            write_byte(32'd0 + i, 8'hB0 + i[7:0]);
        wait_ddr_write;
        // Bank 1 base: (0x3000_0000 + 0x0008_0000) >> 3 = 0x30080000 >> 3 = 29'h06010000
        if (ddr_addr !== 29'h0601_0000) begin
            $display("FAIL T3: addr=%h exp 06010000", ddr_addr);
            errors = errors + 1;
        end

        repeat(10) @(posedge clk);

        // ── TEST 4: Partial qword flush before doorbell ──
        $display("TEST 4: partial flush before doorbell (BE != FF)");
        // Write only 3 bytes to a qword, then frame_done forces flush
        write_byte(32'd16, 8'hC0);  // lane 0
        write_byte(32'd18, 8'hC2);  // lane 2
        write_byte(32'd19, 8'hC3);  // lane 3
        @(posedge clk);
        frame_done <= 1;
        @(posedge clk);
        frame_done <= 0;

        // Should see partial write first, then doorbell
        wait_ddr_write;
        // Partial flush: BE should have lanes 0,2,3 set = 8'b0000_1101 = 8'h0D
        if (ddr_be !== 8'h0D) begin
            $display("FAIL T4: partial be=%h exp 0D", ddr_be);
            errors = errors + 1;
        end
        if (ddr_din[7:0] !== 8'hC0) begin
            $display("FAIL T4: lane0=%h exp C0", ddr_din[7:0]);
            errors = errors + 1;
        end
        if (ddr_din[23:16] !== 8'hC2) begin
            $display("FAIL T4: lane2=%h exp C2", ddr_din[23:16]);
            errors = errors + 1;
        end

        // Then doorbell
        wait_ddr_write;
        if (ddr_din[31:0] !== 32'h504C_584B) begin
            $display("FAIL T4: doorbell lo32=%h exp 504C584B", ddr_din[31:0]);
            errors = errors + 1;
        end
        // Bank=1 now (toggled after test 2 doorbell)
        if (ddr_din[63] !== 1'b1) begin
            $display("FAIL T4: doorbell bank=%b exp 1", ddr_din[63]);
            errors = errors + 1;
        end
        if (ddr_din[62:61] !== 2'b01) begin
            $display("FAIL T4: doorbell format=%b exp 01", ddr_din[62:61]);
            errors = errors + 1;
        end
        // seq=2
        if (ddr_din[60:32] !== 29'd2) begin
            $display("FAIL T4: doorbell seq=%d exp 2", ddr_din[60:32]);
            errors = errors + 1;
        end

        repeat(10) @(posedge clk);

        if (errors == 0)
            $display("PASS: fpga_ddr_writeback_tb — all tests passed");
        else
            $display("FAIL: fpga_ddr_writeback_tb — %0d errors", errors);

        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
