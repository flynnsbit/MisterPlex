module ddr_reader_cdc_reset_tb #(
	parameter bit DROP_RESET_RESPONSE = 1'b0
) (
	input wire clk_sys, clk_ddr, reset,
	input wire DDRAM_BUSY, DDRAM_DOUT_READY,
	input wire [63:0] DDRAM_DOUT,
	output wire [7:0] DDRAM_BURSTCNT, DDRAM_BE,
	output wire [28:0] DDRAM_ADDR,
	output wire [63:0] DDRAM_DIN,
	output wire DDRAM_RD, DDRAM_WE,
	output wire reader_rd, reader_we, reader_busy, reader_response,
	output wire [28:0] reader_addr,
	output wire [63:0] reader_data, reader_response_data, video_nonce,
	output wire command_full, transport_quiet, wrong_owner_response,
	output wire out_valid, au_valid
);
	wire [7:0] reader_burst, reader_be;
	wire reader_want;
	// No media is submitted: these are real Probe/control transactions only.
	ddr_bitstream_reader #(
		.ENABLE_AU_PROTOCOL(1'b1), .MAX_AU_BYTES(8192),
		.MAX_WIDTH(16'd320), .MAX_HEIGHT(16'd240),
		.VIDEO_FEATURES(32'd0), .POLL_DIV_BITS(3)
	) reader (
		.clk(clk_sys), .reset(reset), .enable(1'b1), .flush(1'b0),
		.out_full(1'b0), .out_valid(out_valid),
		.au_ready(1'b1), .au_valid(au_valid), .decoder_idle(1'b1),
		.bit_ready(1'b1), .video_nonce(video_nonce),
		.bus_want(reader_want), .DDRAM_BUSY(reader_busy),
		.DDRAM_BURSTCNT(reader_burst), .DDRAM_ADDR(reader_addr),
		.DDRAM_DIN(reader_data), .DDRAM_BE(reader_be),
		.DDRAM_RD(reader_rd), .DDRAM_WE(reader_we),
		.DDRAM_DOUT(reader_response_data), .DDRAM_DOUT_READY(reader_response)
	);

	wire a_want, a_rd, a_we, a_busy, a_response;
	wire [28:0] a_addr;
	wire [63:0] a_data, a_response_data;
	wire audio_response, publisher_response;
	audio_session_ddr_mux audio_mux (
		.clk(clk_sys), .reset(reset),
		.video_addr(reader_addr), .video_rd(reader_rd), .video_we(reader_we),
		.video_din(reader_data), .video_busy(reader_busy),
		.video_dout(reader_response_data), .video_dout_ready(reader_response),
		.audio_addr(29'd0), .audio_rd(1'b0), .audio_we(1'b0), .audio_din(64'd0),
		.audio_dout_ready(audio_response),
		.ddr_want(a_want), .ddr_addr(a_addr), .ddr_rd(a_rd), .ddr_we(a_we),
		.ddr_din(a_data), .ddr_busy(a_busy),
		.ddr_dout(a_response_data), .ddr_dout_ready(a_response)
	);

	wire m1_want, m1_rd, m1_we, m1_busy, m1_response;
	wire [28:0] m1_addr;
	wire [63:0] m1_data, m1_response_data;
	wire [7:0] m1_be;
	ddr_transport_mux transport (
		.clk(clk_sys), .reset(reset),
		.a_want(a_want), .a_rd(a_rd), .a_we(a_we), .a_addr(a_addr),
		.a_din(a_data), .a_be(reader_be), .a_busy(a_busy),
		.a_dout(a_response_data), .a_dout_ready(a_response),
		.b_want(1'b0), .b_rd(1'b0), .b_we(1'b0), .b_addr(29'd0),
		.b_din(64'd0), .b_be(8'hff), .b_dout_ready(publisher_response),
		.want(m1_want), .rd(m1_rd), .we(m1_we), .addr(m1_addr),
		.din(m1_data), .be(m1_be), .busy(m1_busy), .dout(m1_response_data),
		// Negative control: reproduce losing an owned response during reset.
		.dout_ready(m1_response && !(DROP_RESET_RESPONSE && reset))
	);
	ddr_bus_arbiter #(.M1_HELD_REQUESTS(1'b1), .M1_BLOCK_RAM(1'b1)) arb (
		.clk(clk_ddr), .clk_m1(clk_sys), .reset(reset),
		.m0_rd(1'b0), .m0_we(1'b0), .m0_burstcnt(8'd1),
		.m0_addr(29'd0), .m0_din(64'd0), .m0_be(8'hff),
		.m1_want(m1_want), .m1_rd(m1_rd), .m1_we(m1_we),
		.m1_burstcnt(reader_burst), .m1_addr(m1_addr), .m1_din(m1_data),
		.m1_be(m1_be), .m1_busy(m1_busy),
		.m1_dout(m1_response_data), .m1_dout_ready(m1_response),
		.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
		.DDRAM_RD(DDRAM_RD), .DDRAM_WE(DDRAM_WE)
	);
	assign command_full = arb.g_held.cmd_full;
	assign transport_quiet = arb.g_held.cmd_empty && arb.g_held.rsp_empty &&
		arb.g_held.rsp_left == 0 && !arb.g_held.stalled &&
		!transport.locked && !transport.response_pending &&
		!audio_mux.stalled && !audio_mux.outstanding && !reader_rd && !reader_we;
	assign wrong_owner_response = audio_response || publisher_response;
endmodule
