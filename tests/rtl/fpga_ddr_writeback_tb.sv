// fpga_ddr_writeback testbench — verify byte accumulation and doorbell.
`timescale 1ns/1ps

module fpga_ddr_writeback_tb;
    reg clk = 0;
    always #5 clk = ~clk;  // 100 MHz

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
            // Wait for ddr_we to assert
            while (!ddr_we) @(posedge clk);
            @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("fpga_ddr_writeback_tb.vcd");
        $dumpvars(0, fpga_ddr_writeback_tb);

        // Release reset
        repeat(5) @(posedge clk);
        reset <= 0;
        repeat(5) @(posedge clk);

        // Test 1: Write 8 bytes to same qword → should trigger one DDR write
        $display("TEST 1: 8-byte accumulation");
        for (i = 0; i < 8; i = i + 1) begin
            write_byte(32'd0 + i, 8'hA0 + i[7:0]);
        end

        wait_ddr_write;

        // Check address: PHYS_BASE[31:3] + 0 = 32'h3000_0000 >> 3 = 29'h06000000
        if (ddr_addr !== 29'h0600_0000) begin
            $display("FAIL: ddr_addr = %h, expected 06000000", ddr_addr);
            errors = errors + 1;
        end
        // Check data
        if (ddr_din !== 64'hA7A6A5A4A3A2A1A0) begin
            $display("FAIL: ddr_din = %h, expected A7A6A5A4A3A2A1A0", ddr_din);
            errors = errors + 1;
        end
        if (ddr_burstcnt !== 8'd1) begin
            $display("FAIL: burstcnt = %d", ddr_burstcnt);
            errors = errors + 1;
        end

        repeat(10) @(posedge clk);

        // Test 2: frame_done → doorbell write
        $display("TEST 2: doorbell on frame_done");
        @(posedge clk);
        frame_done <= 1;
        @(posedge clk);
        frame_done <= 0;

        wait_ddr_write;

        // Doorbell address: 0x300FF000 >> 3 = 29'h0601FE00
        if (ddr_addr !== 29'h0601_FE00) begin
            $display("FAIL: doorbell addr = %h, expected 0601FE00", ddr_addr);
            errors = errors + 1;
        end
        // Check PLXK magic in lower 32 bits
        if (ddr_din[31:0] !== 32'h504C_584B) begin
            $display("FAIL: doorbell magic = %h, expected 504C584B", ddr_din[31:0]);
            errors = errors + 1;
        end
        // Bank bit should be 0 initially (first frame goes to bank 0, doorbell switches to bank 1)
        if (ddr_din[63] !== 1'b0) begin
            $display("FAIL: doorbell bank = %b, expected 0", ddr_din[63]);
            errors = errors + 1;
        end
        if (frames_written !== 16'd1) begin
            $display("FAIL: frames_written = %d, expected 1", frames_written);
            errors = errors + 1;
        end

        repeat(10) @(posedge clk);

        // Test 3: Second frame writes to bank 1
        $display("TEST 3: bank toggle");
        for (i = 0; i < 8; i = i + 1) begin
            write_byte(32'd0 + i, 8'hB0 + i[7:0]);
        end
        wait_ddr_write;
        // Bank 1 base = (0x3000_0000 + 0x0008_0000) >> 3 = (0x30080000) >> 3 = 29'h06010000
        if (ddr_addr !== 29'h0601_0000) begin
            $display("FAIL: bank1 addr = %h, expected 06010000", ddr_addr);
            errors = errors + 1;
        end

        repeat(10) @(posedge clk);

        // Summary
        if (errors == 0)
            $display("PASS: fpga_ddr_writeback_tb — all tests passed");
        else
            $display("FAIL: fpga_ddr_writeback_tb — %0d errors", errors);

        $finish;
    end

    // Timeout
    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
