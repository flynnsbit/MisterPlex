module fpga_video_audio_feedback_tb;
	reg clk = 0;
	always #5 clk = ~clk;
	reg reset = 1, clear = 0;
	reg frame_valid = 0;
	wire frame_ready, mem_rd, mem_ready = 1'b1;
	wire [17:0] mem_addr;
	reg [7:0] mem_data = 0;
	reg mem_valid = 0;
	wire swap_toggle, swap_bank;
	reg display_has_frame = 0;
	reg [15:0] display_frames_done = 0;
	wire idle, error;
	wire [31:0] presentation_count;
	wire bus_want, bus_rd, bus_we;
	wire [28:0] bus_addr;
	wire [63:0] bus_din;
	reg [63:0] bus_dout = 0;
	reg bus_dout_ready = 0;
	reg [63:0] memory [0:2047];
	reg [31:0] sequence_number = 0;
	reg signed [63:0] pts = 0;
	reg audio_valid = 0;
	reg [63:0] audio_epoch = 0, audio_nonce = 0, audio_samples = 0;
	localparam [63:0] SESSION = 64'h1234_5678_9abc_def0;
	localparam [63:0] NONCE = 64'hfeed_8765_1234_abcd;
	localparam integer STATUS_WORD = 32'h2000 >> 3;

	fpga_video_publish #(
		.PICTURE_BYTES(8), .FRAME_BASE(32'h1000), .BANK_STRIDE(32'h20),
		.FEEDBACK_BASE(32'h2000), .ENABLE_AUDIO_CLOCK(1'b1)
	) dut (
		.clk(clk), .reset(reset), .clear(clear), .video_nonce(NONCE),
		.frame_valid(frame_valid), .frame_ready(frame_ready), .frame_bank(1'b0),
		.frame_session_id(SESSION), .frame_seq(sequence_number), .frame_pts(pts),
		.frame_timebase_num(32'd1), .frame_timebase_den(32'd90000),
		.mem_rd(mem_rd), .mem_addr(mem_addr), .mem_ready(mem_ready),
		.mem_data(mem_data), .mem_valid(mem_valid),
		.swap_toggle(swap_toggle), .swap_bank(swap_bank),
		.display_has_frame(display_has_frame), .display_frames_done(display_frames_done),
		.display_swap_pending(1'b0), .display_clear_idle(1'b1),
		.audio_clock_valid(audio_valid), .audio_clock_epoch(audio_epoch),
		.audio_clock_nonce(audio_nonce), .audio_samples_consumed(audio_samples),
		.idle(idle), .error(error), .presentation_count(presentation_count),
		.bus_want(bus_want), .bus_rd(bus_rd), .bus_we(bus_we), .bus_addr(bus_addr),
		.bus_din(bus_din), .bus_busy(1'b0), .bus_dout(bus_dout),
		.bus_dout_ready(bus_dout_ready)
	);

	always @(posedge clk) begin
		mem_valid <= mem_rd && mem_ready;
		if (mem_rd && mem_ready) mem_data <= mem_addr[7:0];
		bus_dout_ready <= bus_rd;
		if (bus_rd) bus_dout <= memory[bus_addr[10:0]];
		if (bus_we) memory[bus_addr[10:0]] <= bus_din;
	end

	task automatic picture(
		input bit valid_clock,
		input [63:0] epoch,
		input [63:0] nonce,
		input [63:0] at_display,
		input bit expect_clock
	);
		bit old_swap;
		reg [31:0] before_count;
		reg [63:0] before_commit;
		begin
			while (!frame_ready) @(negedge clk);
			old_swap = swap_toggle;
			before_count = presentation_count;
			before_commit = memory[STATUS_WORD + 8];
			audio_valid = valid_clock;
			audio_epoch = epoch;
			audio_nonce = nonce;
			audio_samples = 64'd7;
			frame_valid = 1;
			@(negedge clk);
			frame_valid = 0;
			while (swap_toggle == old_swap) @(negedge clk);
			assert (presentation_count == before_count) else $fatal(1, "copy counted as display");
			assert (memory[STATUS_WORD + 8] == before_commit) else $fatal(1, "feedback committed before display");
			audio_samples = at_display;
			display_has_frame = 1;
			display_frames_done = display_frames_done + 1'b1;
			@(negedge clk);
			audio_samples = at_display + 64'd9999;
			audio_valid = !valid_clock;
			audio_epoch = ~epoch;
			audio_nonce = ~nonce;
			while (!idle) @(negedge clk);
			assert (!error && presentation_count == before_count + 1) else $fatal(1, "display count");
			assert (memory[STATUS_WORD] == {expect_clock ? 32'd19 : 32'd3, 32'h4d56_5053})
				else $fatal(1, "audio validity flags");
			assert (memory[STATUS_WORD + 1] == SESSION) else $fatal(1, "session");
			assert (memory[STATUS_WORD + 2] == pts) else $fatal(1, "PTS");
			assert (memory[STATUS_WORD + 4] == {presentation_count, sequence_number})
				else $fatal(1, "sequence");
			assert (memory[STATUS_WORD + 5] == (expect_clock ? at_display : 64'd0))
				else $fatal(1, "clock was not frozen at matching display ACK");
			assert (memory[STATUS_WORD + 6] == NONCE) else $fatal(1, "nonce");
			assert (memory[STATUS_WORD + 8][31:0] == 32'h4d56_5043 &&
			        memory[STATUS_WORD + 8][63:32] != 0) else $fatal(1, "commit");
			sequence_number = sequence_number + 1;
			pts = pts + 64'd3750;
		end
	endtask

	initial begin
		for (integer i = 0; i < 2048; i = i + 1) memory[i] = 0;
		repeat (4) @(negedge clk);
		reset = 0;
		picture(1, SESSION, NONCE, 64'd421120, 1);
		picture(0, SESSION, NONCE, 64'd1234, 0);
		picture(1, SESSION + 1, NONCE, 64'd2345, 0);
		picture(1, SESSION, NONCE + 1, 64'd3456, 0);
		picture(1, SESSION, NONCE, 64'd421120, 1);
		$display("PASS display-ACK audio snapshot identity, validity, immutability and no early publication");
		$finish;
	end

	initial begin
		repeat (2000) @(posedge clk);
		$fatal(1, "feedback test timed out");
	end
endmodule
