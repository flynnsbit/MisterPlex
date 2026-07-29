// HPS DDR compressed-bitstream record-ring reader.
//
// The ARM daemon writes fixed 32-byte records into a power-of-two HPS DDR ring
// and publishes an absolute producer byte count in CTRL_PHYS.  NAL records carry
// Annex-B payload bytes; control records (begin/flush/end/pause/resume) are
// consumed at record boundaries so a seek/flush cannot splice mid-NAL.  The FPGA
// publishes read_count plus transport telemetry in DDR, keeping this path wholly
// separate from MiSTer's shared HPS<->FPGA SPI/GPO register.

module ddr_bitstream_reader #(
	parameter [31:0] DATA_PHYS  = 32'h3010_0000,
	parameter [31:0] CTRL_PHYS  = 32'h3014_0000,
	parameter [31:0] READ_PHYS  = 32'h3014_0008,
	parameter [31:0] ERR_PHYS   = 32'h3014_0010,
	parameter [31:0] STAT0_PHYS = 32'h3014_0018,
	parameter [31:0] STAT1_PHYS = 32'h3014_0020,
	parameter [31:0] STAT2_PHYS = 32'h3014_0028,
	parameter [31:0] STAT3_PHYS = 32'h3014_0030,
	parameter [31:0] STAT4_PHYS = 32'h3014_0038,
	parameter [31:0] STAT5_PHYS = 32'h3014_0040,
	parameter [31:0] STAT6_PHYS = 32'h3014_0048,
	parameter int RING_BYTES    = 262144,
	parameter int POLL_DIV_BITS = 6,
	// Mailbox poll rate when the ring is running low.  Producer latency shows up
	// directly as decoder starvation, so a nearly empty ring is polled roughly
	// eight times more often than a comfortable one.
	parameter int POLL_DIV_FAST_BITS = 3,
	parameter int RING_LOW_BYTES = 8192,
	parameter int PREFETCH_QWORDS = 64,
	parameter int PREFETCH_BURST  = 16
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        enable,
	input  wire        flush,

	output reg         out_valid,
	output reg  [7:0]  out_byte,
	output reg         out_flush,
	input  wire        out_full,

	output reg         bus_want,
	input  wire        DDRAM_BUSY,
	output reg   [7:0] DDRAM_BURSTCNT,
	output reg  [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output reg         DDRAM_RD,
	output reg  [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output reg         DDRAM_WE,

	output reg         active,
	output reg  [31:0] bytes_out,
	output reg  [15:0] underrun_count,
	output reg  [15:0] overrun_count,
	output reg  [31:0] host_write_count,
	output reg  [31:0] fpga_read_count
);
	localparam int RING_AW = $clog2(RING_BYTES);
	localparam [28:0] DATA_W  = DATA_PHYS[31:3];
	localparam [28:0] CTRL_W  = CTRL_PHYS[31:3];
	localparam [28:0] READ_W  = READ_PHYS[31:3];
	localparam [28:0] ERR_W   = ERR_PHYS[31:3];
	localparam [28:0] STAT0_W = STAT0_PHYS[31:3];
	localparam [28:0] STAT1_W = STAT1_PHYS[31:3];
	localparam [28:0] STAT2_W = STAT2_PHYS[31:3];
	localparam [28:0] STAT3_W = STAT3_PHYS[31:3];
	localparam [28:0] STAT4_W = STAT4_PHYS[31:3];
	localparam [28:0] STAT5_W = STAT5_PHYS[31:3];
	localparam [28:0] STAT6_W = STAT6_PHYS[31:3];

	localparam [31:0] MAGIC_CTRL = 32'h504C_5842; // PLXB
	localparam [31:0] MAGIC_READ = 32'h504C_5852; // PLXR
	localparam [31:0] MAGIC_ERR  = 32'h504C_5845; // PLXE
	localparam [31:0] MAGIC_REC  = 32'h504C_584E; // PLXN
	localparam [31:0] MAGIC_ST0  = 32'h504C_5854; // PLXT
	localparam [31:0] MAGIC_ST1  = 32'h504C_5855; // PLXU
	localparam [31:0] MAGIC_ST2  = 32'h504C_5856; // PLXV
	localparam [31:0] MAGIC_ST3  = 32'h504C_5857; // PLXW
	localparam [31:0] MAGIC_ST4  = 32'h504C_5859; // PLXY
	localparam [31:0] MAGIC_ST5  = 32'h504C_585A; // PLXZ
	localparam [31:0] MAGIC_ST6  = 32'h504C_5851; // PLXQ

	localparam [7:0] EVENT_BEGIN  = 8'd1;
	localparam [7:0] EVENT_NAL    = 8'd2;
	localparam [7:0] EVENT_FLUSH  = 8'd3;
	localparam [7:0] EVENT_END    = 8'd4;
	localparam [7:0] EVENT_PAUSE  = 8'd5;
	localparam [7:0] EVENT_RESUME = 8'd6;

	localparam [31:0] RING_BYTES_W = 32'(RING_BYTES);
	localparam [31:0] HEADER_BYTES = 32'd32;

	assign DDRAM_BE = 8'hFF;

	localparam [3:0]
		ST_RESET     = 4'd0,
		ST_IDLE      = 4'd1,
		ST_POLL      = 4'd2;

	localparam [1:0]
		MODE_HEADER  = 2'd0,
		MODE_PAYLOAD = 2'd1,
		MODE_DROP    = 2'd2;

	reg [3:0] state;
	reg [1:0] mode;
	reg [POLL_DIV_BITS-1:0] poll_div;
	reg [31:0] write_count;
	reg [31:0] read_count;
	reg reset_seen;
	reg overrun_sticky;
	reg underrun_sticky;
	reg desync_sticky;
	reg fatal_sticky;
	reg paused;
	reg [7:0] telem_seq;
	reg publish_pending;
	reg [3:0] publish_step;
	reg have_ctrl;
	reg empty_seen;
	reg seen_payload;

	reg [7:0] hdr [0:31];
	reg [4:0] hdr_idx;
	reg [31:0] payload_left;
	reg [63:0] current_session;
	reg [31:0] expected_seq;
	reg [31:0] consumer_seq;
	reg [15:0] desync_count;
	reg [31:0] last_bad_seq;
	reg [7:0] rx_byte;

	wire ctrl_magic_ok = DDRAM_DOUT[31:0] == MAGIC_CTRL;
	wire ctrl_reset = DDRAM_DOUT[63];
	wire [30:0] ctrl_write_count = DDRAM_DOUT[62:32];
	wire [31:0] avail = write_count - read_count;
	wire [31:0] ring_level = (avail > RING_BYTES_W) ? RING_BYTES_W : avail;
	wire ring_ok = have_ctrl && !overrun_sticky && !fatal_sticky;

	// Burst prefetch front-end.  It owns the ring fetch pointer and the byte
	// FIFO; this module keeps the DDR arbitration and the record parser.
	wire        pf_fetch_req;
	wire [28:0] pf_fetch_addr;
	wire  [7:0] pf_fetch_len;
	wire        pf_out_valid;
	wire  [7:0] pf_out_byte;
	wire [31:0] pf_read_count;
	wire [31:0] pf_fetch_count;
	wire  [7:0] pf_fifo_qwords;
	wire        pf_beats_pending;
	reg         pf_grant;
	reg  [7:0]  pf_grant_len;
	reg         pf_sync;
	reg  [31:0] pf_sync_count;
	wire        rd_is_prefetch;

	wire ring_low = ring_level < 32'(RING_LOW_BYTES);
	wire poll_tick = ring_low ? (poll_div[POLL_DIV_FAST_BITS-1:0] == {POLL_DIV_FAST_BITS{1'b0}})
	                          : (poll_div == {POLL_DIV_BITS{1'b0}});
	wire want_poll = enable && poll_tick && !pf_beats_pending;
	wire want_read = enable && ring_ok && pf_fetch_req;
	wire want_pub = enable && publish_pending;
	wire can_consume = (mode != MODE_PAYLOAD) || !out_full;
	wire byte_take = pf_out_valid && can_consume && !flush;
	wire [15:0] state_flags = {4'd0, fatal_sticky, desync_sticky, paused, active,
	                           overrun_sticky, underrun_sticky, mode, state};

	ddr_bitstream_prefetch #(
		.FIFO_QWORDS(PREFETCH_QWORDS),
		.BURST_QWORDS(PREFETCH_BURST),
		.RING_BYTES(RING_BYTES)
	) u_prefetch (
		.clk(clk),
		.reset(reset),
		.enable(enable && ring_ok),
		.sync_valid(pf_sync),
		.sync_count(pf_sync_count),
		.write_count(write_count),
		.ring_base_qw(DATA_W),
		.fetch_req(pf_fetch_req),
		.fetch_addr(pf_fetch_addr),
		.fetch_len(pf_fetch_len),
		.fetch_grant(pf_grant),
		.fetch_grant_len(pf_grant_len),
		.beat_valid(DDRAM_DOUT_READY && rd_is_prefetch),
		.beat_data(DDRAM_DOUT),
		.out_valid(pf_out_valid),
		.out_byte(pf_out_byte),
		.out_ready(can_consume && !flush),
		.read_count(pf_read_count),
		.fetch_count(pf_fetch_count),
		.fifo_qwords(pf_fifo_qwords),
		.beats_pending(pf_beats_pending)
	);
	assign rd_is_prefetch = pf_beats_pending && (state != ST_POLL);

	// Fetch pointer is telemetry the mailbox has no slot for yet; keep it loaded
	// so the prefetch output cannot be optimised away.
	wire _unused_pf_fetch = |pf_fetch_count;

	function automatic [31:0] hdr32(input int base);
		begin
			hdr32 = {hdr[base + 3], hdr[base + 2], hdr[base + 1], hdr[base + 0]};
		end
	endfunction

	function automatic [63:0] hdr64(input int base);
		begin
			hdr64 = {hdr[base + 7], hdr[base + 6], hdr[base + 5], hdr[base + 4],
			         hdr[base + 3], hdr[base + 2], hdr[base + 1], hdr[base + 0]};
		end
	endfunction

	task automatic mark_desync(input [31:0] bad_seq);
		begin
			desync_sticky <= 1'b1;
			last_bad_seq <= bad_seq;
			if (desync_count != 16'hFFFF)
				desync_count <= desync_count + 16'd1;
			// Restart the telemetry sweep from step 0.  Ordinary byte traffic
			// only re-arms publish_pending, so an event landing late in a sweep
			// would otherwise finish the sweep without ever rewriting the
			// mailbox word that carries it.
			publish_pending <= 1'b1;
			publish_step <= 4'd0;
		end
	endtask

	task automatic reset_parser;
		begin
			mode <= MODE_HEADER;
			hdr_idx <= 5'd0;
			payload_left <= 32'd0;
		end
	endtask

	wire bus_want_comb =
		(state == ST_IDLE) ? (want_poll || want_read || want_pub || pf_beats_pending) :
		(state == ST_POLL);

	always @(posedge clk) begin
		out_valid <= 1'b0;
		out_flush <= 1'b0;
		// Avalon-MM: hold RD/WE until the bridge drops waitrequest (BUSY).
		// One-cycle pulses are lost across the m1 busy CDC and never land in
		// DDR — which is exactly the "PLXR never rewrites" failure on silicon.
		if (!DDRAM_BUSY) begin
			DDRAM_RD <= 1'b0;
			DDRAM_WE <= 1'b0;
		end
		pf_grant <= 1'b0;
		pf_sync <= 1'b0;

		if (reset) begin
			state <= ST_RESET;
			mode <= MODE_HEADER;
			poll_div <= '0;
			DDRAM_RD <= 1'b0;
			DDRAM_WE <= 1'b0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_ADDR <= 29'd0;
			DDRAM_DIN <= 64'd0;
			bus_want <= 1'b0;
			active <= 1'b0;
			paused <= 1'b0;
			bytes_out <= 32'd0;
			underrun_count <= 16'd0;
			overrun_count <= 16'd0;
			desync_count <= 16'd0;
			last_bad_seq <= 32'd0;
			host_write_count <= 32'd0;
			fpga_read_count <= 32'd0;
			write_count <= 32'd0;
			read_count <= 32'd0;
			current_session <= 64'd0;
			expected_seq <= 32'd0;
			consumer_seq <= 32'd0;
			reset_seen <= 1'b0;
			overrun_sticky <= 1'b0;
			underrun_sticky <= 1'b0;
			desync_sticky <= 1'b0;
			fatal_sticky <= 1'b0;
			telem_seq <= 8'd0;
			publish_pending <= 1'b1;
			publish_step <= 4'd0;
			have_ctrl <= 1'b0;
			empty_seen <= 1'b0;
			seen_payload <= 1'b0;
			hdr_idx <= 5'd0;
			payload_left <= 32'd0;
			pf_sync_count <= 32'd0;
		end else if (!enable) begin
			state <= ST_IDLE;
			bus_want <= 1'b0;
			active <= 1'b0;
			paused <= 1'b0;
			reset_parser();
		end else begin
			bus_want <= !flush && bus_want_comb;
			poll_div <= poll_div + 1'd1;

			if (flush) begin
				pf_sync <= 1'b1;
				pf_sync_count <= write_count;
				read_count <= write_count;
				fpga_read_count <= write_count;
				active <= 1'b0;
				paused <= 1'b0;
				overrun_sticky <= 1'b0;
				underrun_sticky <= 1'b0;
				desync_sticky <= 1'b0;
				fatal_sticky <= 1'b0;
				seen_payload <= 1'b0;
				current_session <= 64'd0;
				expected_seq <= 32'd0;
				consumer_seq <= 32'd0;
				out_flush <= 1'b1;
				publish_pending <= 1'b1;
				publish_step <= 4'd0;
				state <= ST_IDLE;
				reset_parser();
			end

			if (active && have_ctrl && seen_payload && (avail == 32'd0) &&
			    !pf_out_valid && !pf_beats_pending && !empty_seen && !paused) begin
				empty_seen <= 1'b1;
				underrun_sticky <= 1'b1;
				if (underrun_count != 16'hFFFF)
					underrun_count <= underrun_count + 16'd1;
				publish_pending <= 1'b1;
				publish_step <= 4'd0;
			end else if (avail != 32'd0) begin
				empty_seen <= 1'b0;
			end

			if (avail > RING_BYTES_W && !overrun_sticky) begin
				overrun_sticky <= 1'b1;
				if (overrun_count != 16'hFFFF)
					overrun_count <= overrun_count + 16'd1;
				publish_pending <= 1'b1;
				publish_step <= 4'd0;
			end

			case (state)
				ST_RESET: begin
					state <= ST_IDLE;
					publish_pending <= 1'b1;
					publish_step <= 4'd0;
				end

				ST_IDLE: begin
					if (publish_pending && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_BURSTCNT <= 8'd1;
						case (publish_step)
							4'd0: begin
								DDRAM_ADDR <= READ_W;
								DDRAM_DIN <= {read_count, MAGIC_READ};
								DDRAM_WE <= 1'b1;
								publish_step <= 4'd1;
							end
							4'd1: begin
								DDRAM_ADDR <= ERR_W;
								DDRAM_DIN <= {overrun_count[7:0], underrun_count[7:0],
								              active, overrun_sticky, underrun_sticky, 5'd0,
								              telem_seq + 8'd1, MAGIC_ERR};
								DDRAM_WE <= 1'b1;
								telem_seq <= telem_seq + 8'd1;
								publish_step <= 4'd2;
							end
							4'd2: begin
								DDRAM_ADDR <= STAT0_W;
								DDRAM_DIN <= {pf_fifo_qwords, ring_level[23:0], MAGIC_ST0};
								DDRAM_WE <= 1'b1;
								publish_step <= 4'd3;
							end
							4'd3: begin
								DDRAM_ADDR <= STAT1_W;
								DDRAM_DIN <= {consumer_seq, MAGIC_ST1};
								DDRAM_WE <= 1'b1;
								publish_step <= 4'd4;
							end
							4'd4: begin
								DDRAM_ADDR <= STAT2_W;
								DDRAM_DIN <= {last_bad_seq, MAGIC_ST2};
								DDRAM_WE <= 1'b1;
								publish_step <= 4'd5;
							end
							4'd5: begin
								DDRAM_ADDR <= STAT3_W;
								DDRAM_DIN <= {current_session[31:0], MAGIC_ST3};
								DDRAM_WE <= 1'b1;
								publish_step <= 4'd6;
							end
							4'd6: begin
								DDRAM_ADDR <= STAT4_W;
								DDRAM_DIN <= {current_session[63:32], MAGIC_ST4};
								DDRAM_WE <= 1'b1;
								publish_step <= 4'd7;
							end
							4'd7: begin
								DDRAM_ADDR <= STAT5_W;
								DDRAM_DIN <= {underrun_count, overrun_count, MAGIC_ST5};
								DDRAM_WE <= 1'b1;
								publish_step <= 4'd8;
							end
							default: begin
								DDRAM_ADDR <= STAT6_W;
								DDRAM_DIN <= {desync_count, state_flags, MAGIC_ST6};
								DDRAM_WE <= 1'b1;
								publish_step <= 4'd0;
								publish_pending <= 1'b0;
							end
						endcase
					end else if (want_poll && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= CTRL_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						state <= ST_POLL;
					end else if (want_read && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= pf_fetch_addr;
						DDRAM_BURSTCNT <= pf_fetch_len;
						pf_grant_len <= pf_fetch_len;
						DDRAM_RD <= 1'b1;
						pf_grant <= 1'b1;
					end
				end

				ST_POLL: begin
					if (DDRAM_DOUT_READY) begin
						if (ctrl_magic_ok) begin
							have_ctrl <= 1'b1;
							write_count <= {1'b0, ctrl_write_count};
							host_write_count <= {1'b0, ctrl_write_count};
							if (ctrl_reset != reset_seen) begin
								reset_seen <= ctrl_reset;
								pf_sync <= 1'b1;
								pf_sync_count <= {1'b0, ctrl_write_count};
								read_count <= {1'b0, ctrl_write_count};
								fpga_read_count <= {1'b0, ctrl_write_count};
								active <= 1'b0;
								paused <= 1'b0;
								overrun_sticky <= 1'b0;
								underrun_sticky <= 1'b0;
								desync_sticky <= 1'b0;
								fatal_sticky <= 1'b0;
								seen_payload <= 1'b0;
								current_session <= 64'd0;
								expected_seq <= 32'd0;
								consumer_seq <= 32'd0;
								out_flush <= 1'b1;
								publish_pending <= 1'b1;
								publish_step <= 4'd0;
								reset_parser();
							end
						end
						state <= ST_IDLE;
					end
				end

				default: state <= ST_IDLE;
			endcase

			// Record parser.  It runs independently of the DDR state machine so
			// a burst in flight and a stalled decoder never interact: bytes only
			// move on byte_take, so nothing is dropped and nothing is replayed.
			if (byte_take) begin
					begin
						rx_byte = pf_out_byte;
						read_count <= pf_read_count + 32'd1;
						fpga_read_count <= pf_read_count + 32'd1;
						publish_pending <= 1'b1;

						if (mode == MODE_PAYLOAD) begin
							out_byte <= rx_byte;
							out_valid <= 1'b1;
							bytes_out <= bytes_out + 32'd1;
							seen_payload <= 1'b1;
							payload_left <= payload_left - 32'd1;
							if (payload_left == 32'd1) begin
								mode <= MODE_HEADER;
								hdr_idx <= 5'd0;
							end
						end else if (mode == MODE_DROP) begin
							payload_left <= payload_left - 32'd1;
							if (payload_left == 32'd1) begin
								mode <= MODE_HEADER;
								hdr_idx <= 5'd0;
							end
						end else begin
							hdr[hdr_idx] = rx_byte;
							if (hdr_idx == 5'd31) begin
								hdr_idx <= 5'd0;
								if (hdr32(0) != MAGIC_REC || hdr32(24) != 32'd0) begin
									fatal_sticky <= 1'b1;
									active <= 1'b0;
									mark_desync(hdr32(16));
								end else if (hdr[4] == EVENT_BEGIN) begin
									if (active || hdr32(20) != 32'd0) begin
										fatal_sticky <= 1'b1;
										mark_desync(hdr32(16));
									end else begin
										active <= 1'b1;
										paused <= 1'b0;
										current_session <= hdr64(8);
										expected_seq <= 32'd0;
										consumer_seq <= 32'd0;
										seen_payload <= 1'b0;
										out_flush <= 1'b1;
									end
								end else if (hdr[4] == EVENT_NAL) begin
									if (!active || paused || hdr64(8) != current_session ||
									    hdr32(16) != expected_seq) begin
										mark_desync(hdr32(16));
										if (hdr32(20) != 32'd0) begin
											payload_left <= hdr32(20);
											mode <= MODE_DROP;
										end
									end else begin
										consumer_seq <= hdr32(16);
										expected_seq <= hdr32(16) + 32'd1;
										if (hdr32(20) != 32'd0) begin
											payload_left <= hdr32(20);
											mode <= MODE_PAYLOAD;
										end
									end
								end else if (hdr[4] == EVENT_FLUSH) begin
									if (!active || hdr64(8) != current_session || hdr32(20) != 32'd0) begin
										mark_desync(hdr32(16));
									end else begin
										out_flush <= 1'b1;
										seen_payload <= 1'b0;
									end
								end else if (hdr[4] == EVENT_END) begin
									if (!active || hdr64(8) != current_session || hdr32(20) != 32'd0) begin
										mark_desync(hdr32(16));
									end else begin
										active <= 1'b0;
										paused <= 1'b0;
										out_flush <= 1'b1;
									end
								end else if (hdr[4] == EVENT_PAUSE) begin
									if (!active || hdr64(8) != current_session || hdr32(20) != 32'd0)
										mark_desync(hdr32(16));
									else
										paused <= 1'b1;
								end else if (hdr[4] == EVENT_RESUME) begin
									if (!active || hdr64(8) != current_session || hdr32(20) != 32'd0)
										mark_desync(hdr32(16));
									else
										paused <= 1'b0;
								end else begin
									mark_desync(hdr32(16));
								end
							end else begin
								hdr_idx <= hdr_idx + 5'd1;
							end
						end

					end
			end
		end
	end
endmodule
