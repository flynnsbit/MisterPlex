`timescale 1ns/1ps
module audio_fifo_boundary_tb;
	localparam DEPTH = 2048;
	reg clk_wr = 0, clk_rd = 0;
	reg run_wr = 1, run_rd = 1, reset = 1, wr_flush = 0, wr_en = 0, rd_enable = 1;
	reg [31:0] wr_data = 0;
	wire wr_full, underrun, has_audio;
	wire [15:0] wr_level, sample_l, sample_r;
	real wr_half = 25.0;
	integer rate = 20, scenario = 0, epoch = 1, seqnum = 1;
	integer accepted = 0, rendered = 0, aborted = 0;
	reg [31:0] expected[$];
	reg [31:0] last_sample = 0, want;
	audio_fifo #(.DEPTH(DEPTH)) dut (.*);
	initial begin
		if (!$value$plusargs("RATE=%d",rate)) rate = 20;
		if (!$value$plusargs("CASE=%d",scenario)) scenario = 0;
		wr_half = rate == 85 ? 1000.0/170.0 : 25.0;
		forever begin #(wr_half); if (run_wr) clk_wr = ~clk_wr; end
	end
	initial begin
		#3.0;
		forever begin #(1000.0/49.152); if (run_rd) clk_rd = ~clk_rd; end
	end
	always @(posedge clk_wr) if (!reset && !wr_flush && wr_en && !wr_full) begin
		expected.push_back(wr_data);
		accepted++;
	end
	always @(negedge clk_rd) begin
		if (!reset && !wr_flush && {sample_r,sample_l} != last_sample && {sample_r,sample_l} != 0) begin
			if (!expected.size()) $fatal(1,"FIFO orphan sample %h",{sample_r,sample_l});
			want = expected.pop_front();
			if ({sample_r,sample_l} !== want)
				$fatal(1,"FIFO content/order rate=%0d case=%0d got=%h want=%h",rate,scenario,{sample_r,sample_l},want);
			rendered++;
		end
		last_sample = {sample_r,sample_l};
	end
	task automatic send(input integer count);
		integer left, limit;
		begin
			left = count; limit = 0;
			while (left) begin
				@(negedge clk_wr);
				wr_en = !wr_full;
				wr_data = {16'(16'h8000 ^ (epoch << 11) ^ seqnum),16'(seqnum)};
				@(posedge clk_wr);
				if (wr_en && !wr_full) begin left--; seqnum++; end
				limit++;
				if (limit > count*100000) $fatal(1,"FIFO bounded write readiness");
			end
			@(negedge clk_wr); wr_en = 0;
		end
	endtask
	task automatic drain;
		integer limit;
		begin
			limit = 0;
			while (expected.size()) begin
				@(negedge clk_rd); limit++;
				if (limit > (DEPTH+32)*520) $fatal(1,"FIFO bounded drain");
			end
			repeat (5) @(negedge clk_wr);
			if (wr_level != 0) $fatal(1,"FIFO occupancy after drain: %0d",wr_level);
		end
	endtask
	task automatic cancel_epoch(input bit flush);
		begin
			@(negedge clk_wr); #1;
			aborted += expected.size(); expected.delete();
			if (flush) wr_flush = 1; else reset = 1;
			epoch++; seqnum = 1;
			#1;
			if ({sample_r,sample_l} != 0 || has_audio)
				$fatal(1,"FIFO reset/flush not observed while read clock stopped");
			@(negedge clk_wr);
			wr_flush = 0; reset = 0;
			last_sample = 0;
		end
	endtask
	initial begin
		repeat (8) @(negedge clk_wr); reset = 0;
		repeat (12) @(negedge clk_rd);
		case (scenario)
			0: begin
				rd_enable = 0;
				send(DEPTH);
				repeat (4) @(negedge clk_wr);
				if (!wr_full || wr_level != DEPTH) $fatal(1,"FIFO full occupancy %0d",wr_level);
				rd_enable = 1; drain();
				send(DEPTH+17); drain();
				repeat (1026) @(negedge clk_rd);
				if (!has_audio || !underrun) $fatal(1,"FIFO underrun/has-audio contract");
			end
			1,2: begin
				send(8); drain();
				@(negedge clk_rd); run_rd = 0;
				send(7);
				cancel_epoch(scenario == 2);
				repeat (12) @(negedge clk_wr);
				if (!wr_full) $fatal(1,"FIFO accepts before stopped reader reset readiness");
				run_rd = 1;
				repeat (12) @(negedge clk_rd);
				send(19); drain();
			end
			3: begin
				send(9); drain();
				@(negedge clk_rd); run_rd = 0;
				cancel_epoch(0);
				cancel_epoch(1);
				@(negedge clk_wr); run_wr = 0;
				#23; reset = 1; #17; reset = 0;
				#200;
				if ({sample_r,sample_l} != 0 || has_audio) $fatal(1,"FIFO repeated stopped reset");
				run_rd = 1;
				repeat (12) @(negedge clk_rd);
				if (!wr_full) $fatal(1,"FIFO write owner not reset-ready");
				run_wr = 1;
				repeat (12) @(negedge clk_wr);
				rd_enable = 0; send(13);
				repeat (7) @(negedge clk_rd);
				rd_enable = 1; drain();
			end
			default: $fatal(1,"Unknown scenario");
		endcase
		if (accepted != rendered+aborted || expected.size())
			$fatal(1,"FIFO accounting accepted=%0d rendered=%0d aborted=%0d",accepted,rendered,aborted);
		$display("PASS audio_fifo_boundary rate=%0d case=%0d accepted=%0d rendered=%0d aborted=%0d",
			rate,scenario,accepted,rendered,aborted);
		$finish;
	end
	initial begin #300000000; $fatal(1,"FIFO boundary timeout"); end
endmodule
