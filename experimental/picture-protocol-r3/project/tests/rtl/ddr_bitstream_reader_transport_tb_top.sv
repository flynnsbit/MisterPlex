module ddr_bitstream_reader_transport_tb_top #(
	parameter bit ENABLE_AU_PROTOCOL = 1'b1,
	parameter int MAX_AU_BYTES = 8192,
	parameter bit REAL_ALSA = 1'b0
) (
	input wire clk, reset, enable, flush,
	input wire clk_audio, core_local_reset, route_core_audio_reset,
	input wire audio_spi_ss, audio_spi_sck, audio_spi_mosi,
	input wire audio_ram_ready,
	input wire [63:0] audio_ram_data,
	output wire [28:0] audio_ram_address,
	output wire audio_ram_req, audio_reset,
	output wire [15:0] audio_pcm_l, audio_pcm_r,
	output wire audio_actual_active, audio_actual_paused, audio_actual_pending,
	output wire audio_actual_read_pending, audio_actual_reset_draining,
	output wire [1:0] audio_actual_prefetched,
	output wire [63:0] audio_actual_consumed,
	input wire sink_block, sink_read, decoder_idle, au_ready,
	output wire out_valid, out_last, out_flush, out_full,
	output wire [7:0] out_byte,
	output wire [7:0] sink_byte,
	output wire sink_empty,
	output wire au_valid,
	output wire [63:0] au_session_id,
	output wire [31:0] au_seq,
	output wire signed [63:0] au_pts, au_duration,
	output wire [31:0] au_timebase_num, au_timebase_den, au_flags,
	output wire [63:0] video_nonce,
	output wire [63:0] video_session_id,
	output wire reset_pending, transport_quiescent,
	input wire [28:0] audio_addr,
	input wire audio_rd, audio_we,
	input wire [63:0] audio_din,
	output wire audio_busy, audio_dout_ready,
	output wire [63:0] audio_dout,
	input wire audio_mailbox_mode,
	output wire audio_ctrl_toggle,
	output wire [216:0] audio_ctrl_data,
	input wire audio_ctrl_ack_toggle,
	output wire audio_snapshot_toggle,
	input wire audio_snapshot_ack_toggle,
	input wire [447:0] audio_snapshot_data,
	output wire [63:0] audio_clock_epoch, audio_clock_nonce, audio_clock_samples,
	output wire audio_clock_valid, audio_clock_active, audio_clock_paused,
	output wire audio_consumer_quiescent,
	output wire bus_want,
	input wire DDRAM_BUSY, DDRAM_DOUT_READY,
	input wire [63:0] DDRAM_DOUT,
	output wire [7:0] DDRAM_BURSTCNT, DDRAM_BE,
	output wire [28:0] DDRAM_ADDR,
	output wire [63:0] DDRAM_DIN,
	output wire DDRAM_RD, DDRAM_WE,
	output wire active,
	output wire [31:0] bytes_out, host_write_count, fpga_read_count,
	output wire [15:0] underrun_count, overrun_count
);
	wire reader_reset = reset | core_local_reset;
	wire consumer_ctrl_ack, consumer_snapshot_ack;
	wire [447:0] consumer_snapshot_data;
	generate if (REAL_ALSA) begin : g_real_audio
		// The disconnected route is a test-only negative control for the
		// pre-fix core/framework reset mismatch. Production has no bypass.
		wire mpx_audio_reset = reset | (core_local_reset && route_core_audio_reset);
		reg [1:0] mpx_audio_reset_sync = 2'b11;
		always @(posedge clk_audio or posedge mpx_audio_reset) begin
			if (mpx_audio_reset) mpx_audio_reset_sync <= 2'b11;
			else mpx_audio_reset_sync <= {mpx_audio_reset_sync[0], 1'b0};
		end
		assign audio_reset = mpx_audio_reset_sync[1];
		alsa #(.CLK_RATE(48000 * 128), .SESSION_CONTROL(1)) consumer (
			.reset(audio_reset), .clk(clk_audio),
			.ram_address(audio_ram_address), .ram_req(audio_ram_req),
			.ram_ready(audio_ram_ready), .ram_data(audio_ram_data),
			.spi_ss(audio_spi_ss), .spi_sck(audio_spi_sck),
			.spi_mosi(audio_spi_mosi), .spi_miso(),
			.pcm_l(audio_pcm_l), .pcm_r(audio_pcm_r),
			.audio_ctrl_toggle(audio_ctrl_toggle), .audio_ctrl_data(audio_ctrl_data),
			.audio_ctrl_ack_toggle(consumer_ctrl_ack),
			.audio_snapshot_toggle(audio_snapshot_toggle),
			.audio_snapshot_ack_toggle(consumer_snapshot_ack),
			.audio_snapshot_data(consumer_snapshot_data)
		);
		assign audio_actual_active = consumer.g_session.active;
		assign audio_actual_paused = consumer.g_session.paused;
		assign audio_actual_pending = consumer.g_session.pending;
		assign audio_actual_read_pending = consumer.g_session.read_pending;
		assign audio_actual_reset_draining = consumer.g_session.reset_draining;
		assign audio_actual_prefetched = consumer.g_session.ready;
		assign audio_actual_consumed = consumer.g_session.consumed;
	end else begin : g_model_audio
		assign consumer_ctrl_ack = audio_ctrl_ack_toggle;
		assign consumer_snapshot_ack = audio_snapshot_ack_toggle;
		assign consumer_snapshot_data = audio_snapshot_data;
		assign audio_ram_address = 0;
		assign audio_ram_req = 0;
		assign audio_reset = 0;
		assign audio_pcm_l = 0;
		assign audio_pcm_r = 0;
		assign audio_actual_active = 0;
		assign audio_actual_paused = 0;
		assign audio_actual_pending = 0;
		assign audio_actual_read_pending = 0;
		assign audio_actual_reset_draining = 0;
		assign audio_actual_prefetched = 0;
		assign audio_actual_consumed = 0;
	end endgenerate
	wire fifo_full;
	wire reader_busy, reader_rd, reader_we, reader_dout_ready;
	wire [28:0] reader_addr;
	wire [63:0] reader_din, reader_dout;
	wire mux_audio_busy, mux_audio_dout_ready;
	wire [63:0] mux_audio_dout, mailbox_din;
	wire [28:0] mailbox_addr;
	wire mailbox_rd, mailbox_we;
	assign audio_busy = audio_mailbox_mode || mux_audio_busy;
	assign audio_dout = mux_audio_dout;
	assign audio_dout_ready = !audio_mailbox_mode && mux_audio_dout_ready;
	assign out_full = sink_block || fifo_full;
	// Actual production FIFO, deliberately tiny to exercise full rising on
	// the cycle after a byte. Independent reader and downstream stalls compose.
	bitstream_fifo #(.DEPTH(8)) sink (
		.clk(clk), .reset(reader_reset), .wr_flush(out_flush),
		.wr_en(out_valid && !sink_block), .wr_data(out_byte),
		.wr_full(fifo_full), .wr_level(),
		.rd_en(sink_read), .rd_data(sink_byte),
		.rd_empty(sink_empty), .has_data()
	);
	// Test-only stamp verifies nonzero upper-word packing. Only the implemented
	// AU transport bit is set, never decoder/color/picture-commit capabilities.
	ddr_bitstream_reader #(.ENABLE_AU_PROTOCOL(ENABLE_AU_PROTOCOL),
	                       .MAX_AU_BYTES(MAX_AU_BYTES),
	                       .VIDEO_FEATURES(ENABLE_AU_PROTOCOL ? 32'd1 : 32'd0),
	                       .VIDEO_BUILD_ID(ENABLE_AU_PROTOCOL ? 32'hA1B2C3D4 : 32'd0),
	                       .POLL_DIV_BITS(3)) reader (
		.clk(clk), .reset(reader_reset), .enable(enable), .flush(flush),
		.out_valid(out_valid), .out_byte(out_byte), .out_last(out_last),
		.out_flush(out_flush), .out_full(out_full),
		.au_valid(au_valid), .au_ready(au_ready),
		.au_session_id(au_session_id), .au_seq(au_seq),
		.au_pts(au_pts), .au_duration(au_duration),
		.au_timebase_num(au_timebase_num), .au_timebase_den(au_timebase_den),
		.au_flags(au_flags),
		// Audio inactivity fences CTRL reset, not ordinary video Drain:
		// active/paused audio remains valid while its final PCM drains.
		.decoder_idle(decoder_idle && sink_empty &&
		              (!reset_pending || !audio_mailbox_mode || audio_consumer_quiescent)),
		.decoder_fault_valid(1'b0), .decoder_fault_seq(32'd0),
		.video_nonce(video_nonce),
		.video_session_id(video_session_id),
		.reset_pending(reset_pending), .transport_quiescent(transport_quiescent),
		.bit_ready(1'b1), .bit_valid(), .bit_value(), .bit_nal_last(),
		.bit_epb_removed(), .bit_rbsp_bytes(), .bit_bits_out(),
		.bus_want(), .DDRAM_BUSY(reader_busy),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(reader_addr),
		.DDRAM_DOUT(reader_dout), .DDRAM_DOUT_READY(reader_dout_ready),
		.DDRAM_RD(reader_rd), .DDRAM_DIN(reader_din), .DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(reader_we), .active(active), .bytes_out(bytes_out),
		.underrun_count(underrun_count), .overrun_count(overrun_count),
		.host_write_count(host_write_count), .fpga_read_count(fpga_read_count)
	);
	audio_session_mailbox #(.ENABLE(1), .POLL_CYCLES(7)) mailbox (
		.clk(clk), .reset(reader_reset),
		.session_epoch(video_session_id), .probe_nonce(video_nonce),
		.session_active(active && !reset_pending), .supported(),
		.ddr_want(), .ddr_busy(!audio_mailbox_mode || mux_audio_busy),
		.ddr_addr(mailbox_addr), .ddr_rd(mailbox_rd), .ddr_we(mailbox_we),
		.ddr_din(mailbox_din), .ddr_dout(mux_audio_dout),
		.ddr_dout_ready(audio_mailbox_mode && mux_audio_dout_ready),
		.audio_ctrl_toggle(audio_ctrl_toggle), .audio_ctrl_data(audio_ctrl_data),
		.audio_ctrl_ack_toggle(consumer_ctrl_ack),
		.audio_snapshot_toggle(audio_snapshot_toggle),
		.audio_snapshot_ack_toggle(consumer_snapshot_ack),
		.audio_snapshot_data(consumer_snapshot_data),
		.clock_epoch(audio_clock_epoch), .clock_nonce(audio_clock_nonce),
		.samples_consumed(audio_clock_samples), .clock_active(audio_clock_active),
		.clock_valid(audio_clock_valid),
		.clock_paused(audio_clock_paused),
		.consumer_quiescent(audio_consumer_quiescent)
	);
	audio_session_ddr_mux mux (
		.clk(clk), .reset(reader_reset),
		.video_addr(reader_addr), .video_rd(reader_rd), .video_we(reader_we),
		.video_din(reader_din), .video_busy(reader_busy),
		.video_dout(reader_dout), .video_dout_ready(reader_dout_ready),
		.audio_addr(audio_mailbox_mode ? mailbox_addr : audio_addr),
		.audio_rd(audio_mailbox_mode ? mailbox_rd : audio_rd),
		.audio_we(audio_mailbox_mode ? mailbox_we : audio_we),
		.audio_din(audio_mailbox_mode ? mailbox_din : audio_din),
		.audio_busy(mux_audio_busy),
		.audio_dout(mux_audio_dout), .audio_dout_ready(mux_audio_dout_ready),
		.ddr_want(bus_want), .ddr_addr(DDRAM_ADDR), .ddr_rd(DDRAM_RD),
		.ddr_we(DDRAM_WE), .ddr_din(DDRAM_DIN), .ddr_busy(DDRAM_BUSY),
		.ddr_dout(DDRAM_DOUT), .ddr_dout_ready(DDRAM_DOUT_READY)
	);
endmodule
