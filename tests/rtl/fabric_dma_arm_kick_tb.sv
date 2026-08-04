// TB: fabric_dma_arm_kick — accept aligned kick; reject misaligned (NEG).
`timescale 1ns / 1ps

module fabric_dma_arm_kick_tb;
	reg clk = 0;
	always #5 clk = ~clk;

	reg reset = 1;
	reg kick = 0;
	reg [31:0] src_phys_i = 32'h3060_1000;
	reg [31:0] bank_phys_i = 32'h3018_0000;
	reg [31:0] frame_bytes_i = 32'd1_382_400;
	reg dma_busy = 0;
	reg dma_done = 0;
	reg dma_err_align = 0;

	wire start;
	wire [31:0] src_phys, bank_phys, frame_bytes;
	wire kick_accept, kick_reject, last_err_align;
	wire [31:0] kicks_accepted, kicks_rejected;

	fabric_dma_arm_kick dut (
		.clk(clk),
		.reset(reset),
		.kick(kick),
		.src_phys_i(src_phys_i),
		.bank_phys_i(bank_phys_i),
		.frame_bytes_i(frame_bytes_i),
		.dma_busy(dma_busy),
		.dma_done(dma_done),
		.dma_err_align(dma_err_align),
		.start(start),
		.src_phys(src_phys),
		.bank_phys(bank_phys),
		.frame_bytes(frame_bytes),
		.kick_accept(kick_accept),
		.kick_reject(kick_reject),
		.last_err_align(last_err_align),
		.kicks_accepted(kicks_accepted),
		.kicks_rejected(kicks_rejected)
	);

	integer fails = 0;
	task automatic tick;
		begin
			@(posedge clk);
			#1;
		end
	endtask

	initial begin
		$display("CASE fabric_dma_arm_kick_tb EXECUTED");
		repeat (4) tick;
		reset = 0;
		tick;

		// POS: aligned kick → start pulse, accept
		kick = 1;
		tick;
		if (start !== 1'b1) begin
			$display("FAIL expected start=1 on aligned kick");
			fails = fails + 1;
		end
		if (kick_accept !== 1'b1) begin
			$display("FAIL expected kick_accept");
			fails = fails + 1;
		end
		if (src_phys !== 32'h3060_1000 || bank_phys !== 32'h3018_0000) begin
			$display("FAIL latched phys mismatch");
			fails = fails + 1;
		end
		kick = 0;
		tick;
		if (start !== 1'b0) begin
			$display("FAIL start must be one-cycle");
			fails = fails + 1;
		end

		// NEG: misaligned src → reject, no start
		src_phys_i = 32'h3060_1001;
		kick = 1;
		tick;
		if (start !== 1'b0) begin
			$display("FAIL NEG: start must stay 0 on misalign");
			fails = fails + 1;
		end
		if (kick_reject !== 1'b1) begin
			$display("FAIL NEG: expected kick_reject");
			fails = fails + 1;
		end
		if (kicks_rejected < 32'd1) begin
			$display("FAIL NEG: kicks_rejected not incremented");
			fails = fails + 1;
		end
		kick = 0;
		tick;

		if (fails != 0) begin
			$display("FAIL fabric_dma_arm_kick_tb fails=%0d", fails);
			$fatal(1);
		end
		$display("PASS fabric_dma_arm_kick_tb pos_accept+neg_misalign");
		$finish;
	end
endmodule
