`timescale 1ns/1ps
module audio_control_boundary_tb;
	reg src_clk = 0, dst_clk = 0, run_src = 1, run_dst = 1;
	reg src_valid = 0, src_reset_event = 0, async_reset = 1;
	reg [178:0] src_data = 0;
	wire [178:0] dst_data;
	wire dst_valid, dst_reset;
	real half_sys = 25.0;
	integer rate = 20, updates = 0, reset_edges = 0;
	reg [178:0] legal[$], prior = 0, final_word;
	audio_control_cdc dut (.*);
	initial begin
		if (!$value$plusargs("RATE=%d",rate)) rate = 20;
		half_sys = rate == 85 ? 1000.0/170.0 : 25.0;
		forever begin #(half_sys); if (run_src) src_clk = ~src_clk; end
	end
	initial begin
		#7;
		forever begin #(1000.0/49.152); if (run_dst) dst_clk = ~dst_clk; end
	end
	always @(posedge dst_reset) if (dst_valid) reset_edges++;
	always @(negedge dst_clk) if (dst_valid && dst_data != prior) begin
		bit found;
		found = 0;
		foreach (legal[i]) if (legal[i] == dst_data) found = 1;
		if (!found) $fatal(1,"Audio control exposed a partial/unsubmitted tuple");
		updates++; prior = dst_data;
	end
	task automatic command(input integer tag, input bit reset_filter);
		reg [178:0] word;
		begin
			word = {19'(tag ^ 19'h35a17),32'(tag*97),32'(tag*319+1),32'(tag*127+3),
				32'(tag*17+7),32'(tag*63+11)};
			@(negedge src_clk); src_valid = 0;
			src_reset_event = reset_filter;
			if (reset_filter) async_reset = 1;
			for (integer i=0;i<11;i++) begin
				@(negedge src_clk); src_data[i*16+:16] = word[i*16+:16];
			end
			@(negedge src_clk); src_data[178:176] = word[178:176];
			// Actual sys_top waits an idle cycle for its final acx shift.
			@(negedge src_clk); src_reset_event = 0; async_reset = 0;
			@(negedge src_clk); legal.push_back(word); src_valid = 1; final_word = word;
		end
	endtask
	task automatic settle;
		integer limit;
		begin
			limit = 0;
			while (!dst_valid || dst_data != final_word || dst_reset) begin
				@(negedge dst_clk); limit++;
				if (limit > 100) $fatal(1,"Audio control bounded recovery");
			end
			repeat (12) @(negedge dst_clk);
		end
	endtask
	initial begin
		repeat (5) @(negedge src_clk); async_reset = 0;
		command(1,1); settle();
		for (integer i=2;i<8;i++) begin command(i,0); settle(); end
		@(negedge dst_clk); run_dst = 0;
		command(17,1); command(29,1); command(43,0);
		repeat (20) @(negedge src_clk);
		run_dst = 1; settle();
		@(negedge src_clk); run_src = 0;
		#3; async_reset = 1; #11; async_reset = 0;
		repeat (12) @(negedge dst_clk);
		if (dst_reset || dst_data != final_word) $fatal(1,"Audio controls lost across source stop/reset");
		run_src = 1;
		command(61,1); settle();
		if (updates < 8 || reset_edges < 2) $fatal(1,"Insufficient control/reset exercise");
		$display("PASS audio_control_boundary rate=%0d updates=%0d reset_edges=%0d",rate,updates,reset_edges);
		$finish;
	end
	initial begin #1000000; $fatal(1,"Audio control timeout"); end
endmodule
