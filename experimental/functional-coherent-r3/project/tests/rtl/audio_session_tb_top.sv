module audio_session_tb_top (
	input wire clk_sys, clk_audio, reset,
	input wire [63:0] session_epoch, probe_nonce,
	input wire session_active,
	input wire use_real_reader,
	output wire [63:0] reader_session_epoch, reader_probe_nonce,
	output wire reader_active, reader_reset_pending,
	input wire ring_enable,
	output reg [31:0] ring_reads = 0,
	input wire ddr_busy,
	output wire [28:0] ddr_addr,
	output wire ddr_rd, ddr_we,
	output wire [63:0] ddr_din,
	input wire [63:0] ddr_dout,
	input wire ddr_dout_ready,
	output wire [28:0] ram_address,
	input wire [63:0] ram_data,
	output wire ram_req,
	input wire ram_ready,
	input wire spi_ss, spi_sck, spi_mosi,
	output wire [15:0] pcm_l, pcm_r,
	output wire [63:0] consumed,
	output wire [15:0] rptr,
	output wire rptr_half,
	output wire [1:0] prefetched,
	output wire read_pending, pending, active, paused,
	output wire ctrl_toggle, ctrl_ack,
	output wire [63:0] clock_samples,
	output wire clock_valid, clock_active, clock_paused, consumer_quiescent,
	output wire legacy_ram_req,
	output wire [28:0] legacy_ram_address,
	input wire legacy_ram_ready,
	input wire [63:0] legacy_ram_data,
	output wire [15:0] legacy_l, legacy_r,
	output wire [447:0] legacy_snapshot,
	output wire legacy_ctrl_ack, legacy_snapshot_ack
);
	wire [216:0] ctrl_data;
	wire snapshot_toggle, snapshot_ack;
	wire [447:0] snapshot_data;
	wire audio_busy, audio_rd, audio_we, audio_dout_ready;
	wire [28:0] audio_addr;
	wire [63:0] audio_din, audio_dout;
	wire ring_busy, ring_dout_ready;
	wire [63:0] ring_dout, reader_din;
	wire [28:0] reader_addr;
	wire reader_rd, reader_we;
	reg ring_waiting = 0;
	wire ring_rd = !use_real_reader && ring_enable && !ring_waiting;
	wire [63:0] mailbox_epoch = use_real_reader ? reader_session_epoch : session_epoch;
	wire [63:0] mailbox_nonce = use_real_reader ? reader_probe_nonce : probe_nonce;
	wire mailbox_active = use_real_reader ?
		reader_active && !reader_reset_pending : session_active;
	reg [1:0] audio_reset_sync = 2'b11;
	always @(posedge clk_audio or posedge reset) begin
		if (reset) audio_reset_sync <= 2'b11;
		else audio_reset_sync <= {audio_reset_sync[0], 1'b0};
	end
	wire consumer_reset = use_real_reader ? audio_reset_sync[1] : reset;
	ddr_bitstream_reader #(
		.ENABLE_AU_PROTOCOL(1), .VIDEO_BUILD_ID(32'd1), .VIDEO_FEATURES(32'd0),
		.MAX_AU_BYTES(8192)
	) reader (
		.clk(clk_sys), .reset(reset || !use_real_reader), .enable(use_real_reader),
		.flush(1'b0), .out_valid(), .out_byte(), .out_last(), .out_flush(), .out_full(1'b1),
		.au_valid(), .au_ready(1'b0), .au_session_id(), .au_seq(), .au_pts(),
		.au_duration(), .au_timebase_num(), .au_timebase_den(), .au_flags(),
		.video_nonce(reader_probe_nonce), .video_session_id(reader_session_epoch),
		.reset_pending(reader_reset_pending), .transport_quiescent(),
		.decoder_idle(!reader_reset_pending || consumer_quiescent),
		.bit_ready(1'b1), .bus_want(), .DDRAM_BURSTCNT(), .DDRAM_BE(),
		.DDRAM_ADDR(reader_addr), .DDRAM_RD(reader_rd), .DDRAM_WE(reader_we),
		.DDRAM_DIN(reader_din), .DDRAM_BUSY(ring_busy || !use_real_reader),
		.DDRAM_DOUT(ring_dout), .DDRAM_DOUT_READY(ring_dout_ready && use_real_reader),
		.active(reader_active), .bytes_out(), .underrun_count(), .overrun_count(),
		.host_write_count(), .fpga_read_count()
	);
	always @(posedge clk_sys) begin
		if (ring_rd && !ring_busy) ring_waiting <= !ring_dout_ready;
		if (ring_dout_ready) begin
			ring_waiting <= 0;
			ring_reads <= ring_reads + 1'b1;
		end
	end
	audio_session_ddr_mux mux (
		.clk(clk_sys), .reset(reset),
		.video_addr(use_real_reader ? reader_addr : 29'h6028040),
		.video_rd(use_real_reader ? reader_rd : ring_rd), .video_we(use_real_reader && reader_we),
		.video_din(reader_din), .video_busy(ring_busy), .video_dout(ring_dout),
		.video_dout_ready(ring_dout_ready), .audio_addr(audio_addr),
		.audio_rd(audio_rd), .audio_we(audio_we), .audio_din(audio_din),
		.audio_busy(audio_busy), .audio_dout(audio_dout),
		.audio_dout_ready(audio_dout_ready), .ddr_want(),
		.ddr_addr(ddr_addr), .ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_din(ddr_din),
		.ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready)
	);
	audio_session_mailbox #(.ENABLE(1), .POLL_CYCLES(7)) mailbox (
		.clk(clk_sys), .reset(reset), .session_epoch(mailbox_epoch),
		.probe_nonce(mailbox_nonce), .session_active(mailbox_active), .supported(),
		.ddr_want(), .ddr_busy(audio_busy), .ddr_addr(audio_addr), .ddr_rd(audio_rd),
		.ddr_we(audio_we), .ddr_din(audio_din), .ddr_dout(audio_dout),
		.ddr_dout_ready(audio_dout_ready), .audio_ctrl_toggle(ctrl_toggle),
		.audio_ctrl_data(ctrl_data), .audio_ctrl_ack_toggle(ctrl_ack),
		.audio_snapshot_toggle(snapshot_toggle), .audio_snapshot_ack_toggle(snapshot_ack),
		.audio_snapshot_data(snapshot_data), .clock_epoch(), .clock_nonce(),
		.samples_consumed(clock_samples), .clock_active(clock_active), .clock_paused(clock_paused),
		.clock_valid(clock_valid),
		.consumer_quiescent(consumer_quiescent)
	);
	alsa #(.CLK_RATE(48000 * 128), .SESSION_CONTROL(1)) dut (
		.reset(consumer_reset), .clk(clk_audio), .ram_address(ram_address),
		.ram_data(ram_data), .ram_req(ram_req), .ram_ready(ram_ready),
		.spi_ss(spi_ss), .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_miso(),
		.pcm_l(pcm_l), .pcm_r(pcm_r), .audio_ctrl_toggle(ctrl_toggle),
		.audio_ctrl_data(ctrl_data), .audio_ctrl_ack_toggle(ctrl_ack),
		.audio_snapshot_toggle(snapshot_toggle), .audio_snapshot_ack_toggle(snapshot_ack),
		.audio_snapshot_data(snapshot_data)
	);
	assign consumed = dut.g_session.consumed;
	assign rptr = dut.buf_rptr;
	assign rptr_half = dut.g_session.read_half;
	assign prefetched = dut.g_session.ready;
	assign read_pending = dut.g_session.read_pending;
	assign pending = dut.g_session.pending;
	assign active = dut.g_session.active;
	assign paused = dut.g_session.paused;
	// Deliberately omit SESSION_CONTROL: unchanged ALSA users get the legacy
	// first-buffer synchronization and no audio-session capability/ACK.
	alsa #(.CLK_RATE(48000 * 128)) legacy (
		.reset(reset), .clk(clk_audio), .ram_address(legacy_ram_address),
		.ram_data(legacy_ram_data), .ram_req(legacy_ram_req), .ram_ready(legacy_ram_ready),
		.spi_ss(spi_ss), .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_miso(),
		.pcm_l(legacy_l), .pcm_r(legacy_r),
		.audio_ctrl_toggle(ctrl_toggle), .audio_ctrl_data(ctrl_data),
		.audio_ctrl_ack_toggle(legacy_ctrl_ack),
		.audio_snapshot_toggle(snapshot_toggle), .audio_snapshot_ack_toggle(legacy_snapshot_ack),
		.audio_snapshot_data(legacy_snapshot)
	);
endmodule
