// TB ddr_publish_engine: DIRECT, COPY, present priority, NEG no-yield occupancy.
`timescale 1ns/1ps

module ddr_publish_engine_tb;
	localparam int MAX_BURST = 8;
	localparam int MEM_WORDS = 4096;

	reg clk = 0;
	reg reset;
	always #5 clk = ~clk;

	reg cmd_start, cmd_mode, cmd_ring_doorbell, present_want;
	reg [31:0] cmd_src_phys, cmd_dst_phys, cmd_bytes, cmd_doorbell_phys;
	reg [63:0] cmd_doorbell_word;

	wire busy, done_pulse, err, bus_want;
	wire [31:0] bytes_copied;
	wire [15:0] beats_rd, beats_wr;

	reg         DDRAM_BUSY;
	wire [7:0]  DDRAM_BURSTCNT;
	wire [28:0] DDRAM_ADDR;
	reg  [63:0] DDRAM_DOUT;
	reg         DDRAM_DOUT_READY;
	wire        DDRAM_RD, DDRAM_WE;
	wire [63:0] DDRAM_DIN;
	wire [7:0]  DDRAM_BE;

	reg [63:0] mem [0:MEM_WORDS-1];
	integer fails;
	integer copy_issues_while_present;
	integer issues;

	// Accepted-command pipeline
	reg [7:0]  rd_left;
	reg [28:0] rd_addr;
	reg        wr_busy_cy;

	ddr_publish_engine #(.MAX_BURST(MAX_BURST)) dut (
		.clk(clk), .reset(reset),
		.cmd_start(cmd_start), .cmd_mode(cmd_mode),
		.cmd_src_phys(cmd_src_phys), .cmd_dst_phys(cmd_dst_phys),
		.cmd_bytes(cmd_bytes), .cmd_doorbell_phys(cmd_doorbell_phys),
		.cmd_ring_doorbell(cmd_ring_doorbell), .cmd_doorbell_word(cmd_doorbell_word),
		.busy(busy), .done_pulse(done_pulse), .err(err),
		.bytes_copied(bytes_copied), .beats_rd(beats_rd), .beats_wr(beats_wr),
		.present_want(present_want),
		.bus_want(bus_want),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE)
	);

	// Memory model: accept RD/WE when !BUSY; RD returns beats next cycles.
	always @(posedge clk) begin
		if (reset) begin
			DDRAM_BUSY <= 1'b0;
			DDRAM_DOUT_READY <= 1'b0;
			DDRAM_DOUT <= 64'd0;
			rd_left <= 8'd0;
			wr_busy_cy <= 1'b0;
		end else begin
			DDRAM_DOUT_READY <= 1'b0;
			if (wr_busy_cy) begin
				wr_busy_cy <= 1'b0;
				DDRAM_BUSY <= 1'b0;
			end else if (rd_left != 8'd0) begin
				DDRAM_DOUT <= mem[rd_addr[11:0]];
				DDRAM_DOUT_READY <= 1'b1;
				rd_addr <= rd_addr + 29'd1;
				rd_left <= rd_left - 8'd1;
				if (rd_left == 8'd1)
					DDRAM_BUSY <= 1'b0;
			end else if (DDRAM_RD && !DDRAM_BUSY) begin
				// Accept read
				rd_left <= DDRAM_BURSTCNT;
				rd_addr <= DDRAM_ADDR;
				DDRAM_BUSY <= 1'b1;
			end else if (DDRAM_WE && !DDRAM_BUSY) begin
				// Accept write — commit same cycle, busy 1 cy after
				mem[DDRAM_ADDR[11:0]] <= DDRAM_DIN;
				wr_busy_cy <= 1'b1;
				DDRAM_BUSY <= 1'b1;
			end
		end
	end

	task automatic step;
		begin @(posedge clk); #1; end
	endtask

	task automatic wait_done;
		integer g;
		begin
			g = 0;
			while (!done_pulse && g < 500000) begin step(); g = g + 1; end
			if (!done_pulse) begin
				$display("FAIL timeout");
				fails = fails + 1;
			end
		end
	endtask

	task automatic test_direct;
		begin
			$display("=== G_DIRECT ===");
			mem[12'h300] = 64'd0;
			present_want = 0;
			cmd_mode = 0;
			cmd_src_phys = 0;
			cmd_dst_phys = 0;
			cmd_bytes = 0;
			cmd_doorbell_phys = 32'h1800; // word 0x300
			cmd_ring_doorbell = 1;
			cmd_doorbell_word = 64'h0123456789ABCDEF;
			cmd_start = 1; step(); cmd_start = 0;
			wait_done();
			if (err || beats_rd != 0 || mem[12'h300] !== 64'h0123456789ABCDEF) begin
				$display("FAIL DIRECT err=%0d brd=%0d mem=%h", err, beats_rd, mem[12'h300]);
				fails = fails + 1;
			end else $display("PASS DIRECT");
		end
	endtask

	task automatic test_copy;
		integer w;
		begin
			$display("=== G0 COPY ===");
			for (w = 0; w < MEM_WORDS; w = w + 1)
				mem[w] = 64'hDEADBEEF00000000 | w[31:0];
			for (w = 0; w < 8; w = w + 1)
				mem[12'h010 + w] = 64'hA5A5000000000000 | (w + 1);
			present_want = 0;
			cmd_mode = 1;
			cmd_src_phys = 32'h80;    // word 0x10
			cmd_dst_phys = 32'h800;   // word 0x100
			cmd_bytes = 64;
			cmd_doorbell_phys = 32'h1000; // word 0x200
			cmd_ring_doorbell = 1;
			cmd_doorbell_word = 64'h504C584400000001;
			cmd_start = 1; step(); cmd_start = 0;
			wait_done();
			if (err || bytes_copied != 64) begin
				$display("FAIL G0 err=%0d bytes=%0d", err, bytes_copied);
				fails = fails + 1;
			end
			for (w = 0; w < 8; w = w + 1) begin
				if (mem[12'h100 + w] !== (64'hA5A5000000000000 | (w + 1))) begin
					$display("FAIL G0 dst[%0d]=%h", w, mem[12'h100 + w]);
					fails = fails + 1;
				end
			end
			if (mem[12'h200] !== 64'h504C584400000001) begin
				$display("FAIL G0 db=%h", mem[12'h200]);
				fails = fails + 1;
			end
			if (fails == 0) $display("PASS G0");
			// note: fails may already be >0 from prior; print G0 status via local
		end
	endtask

	task automatic test_prio;
		integer w;
		integer local_fail;
		begin
			$display("=== G1 present priority ===");
			local_fail = 0;
			for (w = 0; w < 64; w = w + 1)
				mem[w] = 64'h1111000000000000 | w[31:0];
			for (w = 0; w < 64; w = w + 1)
				mem[12'h200 + w] = 64'd0;
			present_want = 0;
			cmd_mode = 1;
			cmd_src_phys = 0;
			cmd_dst_phys = 32'h1000;
			cmd_bytes = 256;
			cmd_ring_doorbell = 0;
			cmd_start = 1; step(); cmd_start = 0;
			repeat (8) step();
			present_want = 1;
			copy_issues_while_present = 0;
			repeat (50) begin
				// Count NEW accepts while present held: RD/WE high and !BUSY
				if (present_want && !DDRAM_BUSY && (DDRAM_RD || DDRAM_WE))
					copy_issues_while_present = copy_issues_while_present + 1;
				step();
			end
			present_want = 0;
			wait_done();
			if (copy_issues_while_present > 1) begin
				$display("FAIL G1 new_issues_while_present=%0d", copy_issues_while_present);
				fails = fails + 1;
				local_fail = 1;
			end
			for (w = 0; w < 32; w = w + 1) begin
				if (mem[12'h200 + w] !== (64'h1111000000000000 | w[31:0])) begin
					$display("FAIL G1 data[%0d]=%h", w, mem[12'h200 + w]);
					fails = fails + 1;
					local_fail = 1;
				end
			end
			if (!local_fail)
				$display("PASS G1 issues_while_present=%0d", copy_issues_while_present);
		end
	endtask

	task automatic test_neg;
		begin
			$display("=== G_NEG present_want=0 occupancy ===");
			present_want = 0;
			cmd_mode = 1;
			cmd_src_phys = 0;
			cmd_dst_phys = 32'h2000;
			cmd_bytes = 512;
			cmd_ring_doorbell = 0;
			cmd_start = 1; step(); cmd_start = 0;
			issues = 0;
			repeat (100) begin
				if (DDRAM_RD || DDRAM_WE) issues = issues + 1;
				step();
			end
			wait_done();
			if (issues < 8) begin
				$display("FAIL G_NEG expected copy traffic got %0d", issues);
				fails = fails + 1;
			end else begin
				$display("PASS G_NEG copy_occupancy=%0d (priority-less would starve present)", issues);
			end
		end
	endtask

	initial begin
		fails = 0;
		reset = 1;
		cmd_start = 0;
		cmd_mode = 0;
		present_want = 0;
		cmd_src_phys = 0;
		cmd_dst_phys = 0;
		cmd_bytes = 0;
		cmd_doorbell_phys = 0;
		cmd_ring_doorbell = 0;
		cmd_doorbell_word = 0;
		repeat (5) step();
		reset = 0;
		repeat (2) step();
		test_direct();
		test_copy();
		test_prio();
		test_neg();
		if (fails != 0) begin
			$display("FAIL ddr_publish_engine_tb fails=%0d", fails);
			$fatal(1);
		end
		$display("PASS ddr_publish_engine_tb all");
		$finish;
	end
endmodule
