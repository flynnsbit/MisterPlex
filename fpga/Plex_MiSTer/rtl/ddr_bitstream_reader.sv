// HPS DDR compressed-bitstream record-ring reader.
//
// The ARM daemon writes fixed 32-byte records into a power-of-two HPS DDR ring
// and publishes a modulo-2^31 producer byte count in CTRL_PHYS. ABI0 NAL records
// carry Annex-B payload bytes; ABI2 access units carry a 32-byte metadata prefix.
// Control records (begin/flush/end/pause/resume/drain) are
// consumed at record boundaries so a seek/flush cannot splice mid-NAL.  The FPGA
// publishes read_count plus transport telemetry in DDR, keeping this path wholly
// separate from MiSTer's shared HPS<->FPGA SPI/GPO register.
//
// Fabric-decode feed (w-path) — two product wiring options for w-plxd:
//
//   Source-graph note (rd-duck NACK on 19/17 file-union probe): treat LIVE/DEAD
//   counts as instrument-dependent. Post-fit hierarchy + PRODUCT_NO_STUB are
//   authority for what ships. decode_stub is diagnostic/partial; product frames
//   still come from ARM FFmpeg until a complete fabric path is wired and fit.
//   rbsp_filter + exp_golomb remain uninstantiated on the product path today.
//
//   (1) Front-end chain (w-plxd ENABLE_FABRIC_DECODE):
//         reader.out_valid/out_byte/out_last  →  h264_rbsp_filter.in_*
//         reader.out_full                    := !h264_rbsp_filter.in_ready
//         reader.out_flush                   →  h264_rbsp_filter.clear (pulse)
//         rbsp_filter.out_*                  →  bit window (STRIP_EPB=0) → exp_golomb
//
//   (2) Integrated bit feed (ENABLE_BIT_FEED=1): reader does EPB strip + MSB bit
//       window in-module and presents bit_valid/bit_value/bit_ready directly to
//       exp_golomb / CAVLC. Default ENABLE_BIT_FEED=0 keeps stream_path's
//       legacy byte-only contract (out_valid/out_byte/out_full).

// -----------------------------------------------------------------------------
// bitstream_bit_feeder — byte stream → EPB strip → bit window (MSB-first).
// Lives in this file so files.qip needs no second entry (collision control).
// -----------------------------------------------------------------------------
module bitstream_bit_feeder #(
	parameter int BYTE_Q_DEPTH = 8, // power-of-two skid after optional EPB strip
	// 1: annex-B in, strip 0x000003 (standalone path / ENABLE_BIT_FEED)
	// 0: already-RBSP bytes in (after h264_rbsp_filter) — bit window only
	parameter bit STRIP_EPB = 1'b1
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        clear,

	// Bytes in: annex-B when STRIP_EPB=1, RBSP when STRIP_EPB=0
	input  wire        in_valid,
	input  wire [7:0]  in_byte,
	input  wire        in_last,   // pulses with final byte of a NAL payload
	output wire        in_ready,

	// Continuous bit stream for CAVLC / exp-golomb (H.264 MSB-first within byte)
	output wire        bit_valid,
	output wire        bit_value,
	input  wire        bit_ready,

	output reg         nal_bit_last, // 1-cycle pulse after last RBSP bit of NAL drained
	output reg  [15:0] epb_removed,
	output reg  [15:0] rbsp_bytes,
	output reg  [31:0] bits_out,
	output wire        byte_q_full,
	output wire        byte_q_empty
);
	localparam int QAW = $clog2(BYTE_Q_DEPTH);

	// --- Optional EPB strip (same contract as h264_rbsp_filter when STRIP_EPB=1) ---
	reg [1:0] zero_count;
	reg       inhibit_skip;
	wire      epb_can_accept;
	wire      skip_epb;

	// --- RBSP byte skid (holds bytes while bit consumer backpressures) ---
	reg [7:0] q_data [0:BYTE_Q_DEPTH-1];
	reg       q_last [0:BYTE_Q_DEPTH-1];
	reg [QAW:0] q_wr;
	reg [QAW:0] q_rd;
	wire [QAW:0] q_level = q_wr - q_rd;
	assign byte_q_empty = (q_wr == q_rd);
	assign byte_q_full  = (q_level >= BYTE_Q_DEPTH[QAW:0]);
	assign epb_can_accept = !byte_q_full;
	assign skip_epb = STRIP_EPB && in_valid && epb_can_accept && !inhibit_skip &&
	                  (zero_count == 2'd2) && (in_byte == 8'h03);
	// Accept input when EPB stage can push or skip without growing a full queue.
	assign in_ready = epb_can_accept;

	// --- Current byte under bit extraction ---
	reg        have_cur;
	reg [7:0]  cur_byte;
	reg        cur_last;
	reg [2:0]  bit_idx; // 0 = MSB (bit7)
	reg        pending_nal_last;

	wire bits_in_cur = have_cur;
	assign bit_valid = bits_in_cur;
	assign bit_value = cur_byte[3'd7 - bit_idx];

	wire take_bit = bit_valid && bit_ready;
	wire load_cur = !have_cur && !byte_q_empty;

	integer qi;
	always @(posedge clk) begin
		if (reset || clear) begin
			zero_count <= 2'd0;
			inhibit_skip <= 1'b0;
			epb_removed <= 16'd0;
			rbsp_bytes <= 16'd0;
			bits_out <= 32'd0;
			q_wr <= '0;
			q_rd <= '0;
			have_cur <= 1'b0;
			cur_byte <= 8'd0;
			cur_last <= 1'b0;
			bit_idx <= 3'd0;
			pending_nal_last <= 1'b0;
			nal_bit_last <= 1'b0;
			for (qi = 0; qi < BYTE_Q_DEPTH; qi = qi + 1) begin
				q_data[qi] <= 8'd0;
				q_last[qi] <= 1'b0;
			end
		end else begin
			nal_bit_last <= 1'b0;

			// Optional EPB filter → push RBSP bytes into skid
			if (in_valid && in_ready) begin
				if (skip_epb) begin
					if (epb_removed != 16'hFFFF)
						epb_removed <= epb_removed + 16'd1;
					inhibit_skip <= 1'b1;
					// EPB is not last-of-RBSP content; if in_last, NAL ends after skip
					if (in_last)
						pending_nal_last <= 1'b1;
				end else begin
					q_data[q_wr[QAW-1:0]] <= in_byte;
					q_last[q_wr[QAW-1:0]] <= in_last;
					q_wr <= q_wr + 1'd1;
					if (rbsp_bytes != 16'hFFFF)
						rbsp_bytes <= rbsp_bytes + 16'd1;
					if (STRIP_EPB) begin
						if (in_byte == 8'h00)
							zero_count <= (zero_count == 2'd2) ? 2'd2 : (zero_count + 2'd1);
						else
							zero_count <= 2'd0;
						inhibit_skip <= 1'b0;
					end
				end
			end

			// Load next RBSP byte into bit window when empty
			if (load_cur) begin
				cur_byte <= q_data[q_rd[QAW-1:0]];
				cur_last <= q_last[q_rd[QAW-1:0]];
				q_rd <= q_rd + 1'd1;
				have_cur <= 1'b1;
				bit_idx <= 3'd0;
			end

			// Consume one bit under backpressure
			if (take_bit) begin
				if (bits_out != 32'hFFFF_FFFF)
					bits_out <= bits_out + 32'd1;
				if (bit_idx == 3'd7) begin
					have_cur <= 1'b0;
					bit_idx <= 3'd0;
					if (cur_last || (pending_nal_last && byte_q_empty)) begin
						nal_bit_last <= 1'b1;
						pending_nal_last <= 1'b0;
					end
				end else begin
					bit_idx <= bit_idx + 3'd1;
				end
			end
		end
	end
endmodule

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
	// w-path fabric-decode feed (default off: stream_path byte contract unchanged)
	parameter bit ENABLE_BIT_FEED = 1'b0,
	parameter bit ENABLE_AU_PROTOCOL = 1'b0,
	// These are build claims, not inferred decoder capabilities. Default is
	// explicitly incompatible with product video (features and build ID zero).
	parameter [31:0] VIDEO_FEATURES = 32'd0,
	parameter [31:0] VIDEO_BUILD_ID = 32'd0,
	// Physical transport ceiling includes a reserved Resume header. The
	// integrated top must override this for its actual downstream capacity
	// (currently 8192 bytes), independently of this leaf's ring capacity.
	parameter int MAX_AU_BYTES = RING_BYTES - 96,
	parameter [15:0] MAX_WIDTH = 16'd640,
	parameter [15:0] MAX_HEIGHT = 16'd480
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        enable,
	input  wire        flush,

	// Held valid/data/last: acceptance is out_valid && !out_full.
	// ABI0: one NAL. ABI2: whole AU, potentially multiple NALs (EPB present).
	// The AU scanner, not this transport leaf, owns NAL/RBSP extraction.
	output reg         out_valid,
	output reg  [7:0]  out_byte,
	output reg         out_last,   // final encoded byte of current NAL/AU record
	output reg         out_flush,  // seek/BEGIN/END/FLUSH → rbsp_filter.clear
	input  wire        out_full,

	// Metadata transfers once, before any encoded AU byte. Hold ready low to
	// retain ownership; all fields remain stable until valid && ready.
	output reg         au_valid,
	input  wire        au_ready,
	output reg  [63:0] au_session_id,
	output reg  [31:0] au_seq,
	output reg signed [63:0] au_pts,
	output reg signed [63:0] au_duration,
	output reg  [31:0] au_timebase_num,
	output reg  [31:0] au_timebase_den,
	output reg  [31:0] au_flags,
	// Feedback binding: nonzero only after the Probe's final capability
	// commit is accepted. Invalidated by reset/epoch reset or a new Probe.
	output wire [63:0] video_nonce,
	// Begin's current epoch, available before the first AU/audio Begin.
	// End retains it for final feedback; CTRL reset invalidates it.
	output wire [63:0] video_session_id,
	// Includes scanner/controller/reconstruction AND accepted frame writes.
	// Must be real drain state, never a tie-high in an enabled AU path.
	input  wire        decoder_idle,
	// Observed out-of-band CTRL reset, held until decoder_idle permits ACK.
	// The top must include accepted decoder/presenter AND audio retirement.
	output wire        reset_pending,
	// Reader-owned DDR transactions and held byte/metadata outputs are empty.
	// Meaningful as a reset fence with reset_pending; not a decoder-idle claim.
	output wire        transport_quiescent,

	// Optional integrated RBSP bit feed (ENABLE_BIT_FEED=1).
	// Quartus forbids default values on inputs — parents must tie bit_ready
	// (stream_path uses 1'b1 when the bit port is unused).
	output wire        bit_valid,
	output wire        bit_value,
	input  wire        bit_ready,
	output wire        bit_nal_last,
	output wire [15:0] bit_epb_removed,
	output wire [15:0] bit_rbsp_bytes,
	output wire [31:0] bit_bits_out,

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
	localparam [7:0] EVENT_PROBE = 8'd7;
	localparam [7:0] EVENT_AU = 8'd8;
	localparam [7:0] EVENT_DRAIN = 8'd9;

	// Checked against host/libmisterplex/{mailbox_abi_spec,ddr_bitstream_ring}.hpp
	// by test_ddr_bitstream_reader_transport.sh; the host headers are authority.
	localparam [15:0] VIDEO_ABI = 16'd2;
	localparam [15:0] VIDEO_LAYOUT = 16'd1;
	localparam [31:0] CAPS_MAGIC0 = 32'h4D50_4330;
	localparam [31:0] CAPS_MAGIC1 = 32'h4D50_4331;
	localparam [31:0] CAPS_MAGIC2 = 32'h4D50_4332;
	localparam [31:0] CAPS_MAGIC3 = 32'h4D50_4333;
	localparam [31:0] CAPS_MAGIC4 = 32'h4D50_4334;
	localparam [31:0] CAPS_MAGIC5 = 32'h4D50_4335;
	localparam [31:0] CAPS_MAGIC6 = 32'h4D50_4336;
	localparam [31:0] CAPS_MAGIC7 = 32'h4D50_4337;
	localparam [28:0] CAPS_W = CTRL_W + 29'd10;
	// Header + metadata + one reserved control header (Resume under pause).
	localparam [31:0] AU_LIMIT = (MAX_AU_BYTES < RING_BYTES - 96) ?
	                              32'(MAX_AU_BYTES) : 32'(RING_BYTES - 96);

	localparam [31:0] RING_BYTES_W = 32'(RING_BYTES);
	localparam [31:0] HEADER_BYTES = 32'd32;

	assign DDRAM_BE = 8'hFF;

	localparam [3:0]
		ST_IDLE = 4'd1, ST_COMMAND = 4'd2, ST_CONSUME = 4'd4,
		ST_HEADER = 4'd5, ST_METADATA = 4'd6, ST_META_WAIT = 4'd7,
		ST_FENCE = 4'd8, ST_SKIP = 4'd9, ST_EPOCH = 4'd10;

	localparam [1:0]
		MODE_HEADER  = 2'd0,
		MODE_PAYLOAD = 2'd1,
		MODE_METADATA = 2'd2;

	reg [3:0] state;
	reg [1:0] mode;
	reg [POLL_DIV_BITS-1:0] poll_div;
	reg [63:0] beat_q;
	reg [2:0] byte_idx;
	reg [3:0] beat_left;
	// CTRL bit63 is epoch, NOT a counter bit. All distances and additions
	// truncate to 31 bits, including the private pause lookahead cursor.
	reg [30:0] write_count;
	reg [30:0] read_count;
	reg [30:0] cursor_count;
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
	reg session_v2;
	reg probe_done;
	reg [63:0] probe_nonce;
	reg [63:0] committed_nonce;
	reg [31:0] caps_publication;
	reg caps_pending;
	reg [3:0] caps_step;
	reg lookahead;
	reg paused_data;
	reg [30:0] replay_count;
	reg [31:0] lookahead_seq;
	reg flush_pending;
	reg [30:0] epoch_count;
	reg epoch_value;

	reg [7:0] hdr [0:31];
	reg [4:0] hdr_idx;
	reg [31:0] payload_left;
	reg [63:0] current_session;
	reg [31:0] expected_seq;
	reg [31:0] consumer_seq;
	reg [15:0] desync_count;
	reg [31:0] last_bad_seq;
	wire [7:0] rx_byte = beat_q[8 * byte_idx +: 8];
	assign video_session_id = current_session;
	assign video_nonce = committed_nonce;

	wire [30:0] distance = write_count - read_count;
	wire [31:0] avail = {1'b0, distance};
	wire [30:0] cursor_avail = write_count - cursor_count;
	wire [31:0] ring_level = (avail > RING_BYTES_W) ? RING_BYTES_W : avail;
	wire ring_has_data = have_ctrl && (avail != 32'd0) && !overrun_sticky && !fatal_sticky;
	wire [RING_AW-1:0] read_ring_index = cursor_count[RING_AW-1:0];
	wire [28:0] read_qword_offset = 29'(read_ring_index >> 3);
	wire [2:0] read_byte_index = read_ring_index[2:0];
	wire [31:0] bytes_to_qword_end = 32'd8 - {29'd0, read_byte_index};
	wire [31:0] consume_count_w =
		({1'b0, cursor_avail} < bytes_to_qword_end) ?
		{1'b0, cursor_avail} : bytes_to_qword_end;
	wire [3:0] consume_count = consume_count_w[3:0];
	wire want_poll = enable && (poll_div == {POLL_DIV_BITS{1'b0}});
	wire want_read = (enable || flush_pending) && ring_has_data &&
	                 (cursor_avail != 0) && (beat_left == 4'd0);
	// Bit feeder backpressure (ENABLE_BIT_FEED): hold-reg valid/ready, not a
	// single-cycle pulse. A pulse drops the next byte when the feeder skid is
	// one slot from full (ready sampled cycle N, valid arrives N+1 after full).
	wire bit_feed_in_ready;
	reg         bit_in_valid;
	reg  [7:0]  bit_in_byte;
	reg         bit_in_last;
	wire        bit_fire = bit_in_valid && bit_feed_in_ready;
	wire payload_sink_ok = !out_valid && (!ENABLE_BIT_FEED || !bit_in_valid);
	wire can_consume = (mode != MODE_PAYLOAD) || (payload_sink_ok && !paused);
	wire sinks_empty = !out_valid && !bit_in_valid && !au_valid;
	wire fence_idle = sinks_empty && (!ENABLE_AU_PROTOCOL || decoder_idle);
	wire [15:0] state_flags = {4'd0, fatal_sticky, desync_sticky, paused, active,
	                           overrun_sticky, underrun_sticky, mode, state};

	// Payload byte → bit feeder holding register (cleared only on fire / clear)
	reg         bit_feed_soft_clear; // EVENT_FLUSH / BEGIN / END / host flush
	wire        bit_feed_clear = reset | bit_feed_soft_clear;

	generate
		if (ENABLE_BIT_FEED) begin : g_bit_feed
			bitstream_bit_feeder #(.BYTE_Q_DEPTH(8)) u_bit_feed (
				.clk(clk),
				.reset(reset),
				.clear(bit_feed_clear),
				.in_valid(bit_in_valid),
				.in_byte(bit_in_byte),
				.in_last(bit_in_last),
				.in_ready(bit_feed_in_ready),
				.bit_valid(bit_valid),
				.bit_value(bit_value),
				.bit_ready(bit_ready),
				.nal_bit_last(bit_nal_last),
				.epb_removed(bit_epb_removed),
				.rbsp_bytes(bit_rbsp_bytes),
				.bits_out(bit_bits_out),
				.byte_q_full(),
				.byte_q_empty()
			);
		end else begin : g_bit_feed_off
			assign bit_feed_in_ready = 1'b1;
			assign bit_valid = 1'b0;
			assign bit_value = 1'b0;
			assign bit_nal_last = 1'b0;
			assign bit_epb_removed = 16'd0;
			assign bit_rbsp_bytes = 16'd0;
			assign bit_bits_out = 32'd0;
		end
	endgenerate

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
			publish_pending <= 1'b1;
		end
	endtask

	task automatic reset_parser;
		begin
			mode <= MODE_HEADER;
			hdr_idx <= 5'd0;
			payload_left <= 32'd0;
			beat_left <= 4'd0;
		end
	endtask

	task automatic fail_record;
		begin
			fatal_sticky <= 1'b1;
			mark_desync(hdr32(16));
			beat_left <= 0;
			state <= ST_IDLE;
		end
	endtask

	// Single outstanding command, in the reader clock domain. A request is
	// accepted ONLY on RD/WE && !BUSY. Read ownership lasts through DOUT_READY.
	// Reset kills the parser's result, not the outstanding DDR transaction.
	// The top-level CDC/mux must implement this handshake, not synchronize a
	// foreign-clock busy level and forward a multi-cycle request as a pulse.
	localparam [1:0] BUS_IDLE = 0, BUS_OFFER = 1, BUS_RESPONSE = 2;
	reg [1:0] bus_state = BUS_IDLE;
	reg bus_killed = 1'b0;
	reg bus_write = 1'b0;
	reg [28:0] bus_addr = 0;
	reg [63:0] bus_data = 0;
	reg bus_done = 1'b0;
	reg [63:0] bus_result = 0;
	reg cmd_valid;
	reg cmd_write;
	reg [28:0] cmd_addr;
	reg [63:0] cmd_data;
	localparam [1:0] TX_POLL = 0, TX_DATA = 1, TX_TELEM = 2, TX_CAPS = 3;
	reg [1:0] tx_kind;
	reg [3:0] poll_return_state;
	wire bus_idle = bus_state == BUS_IDLE;
	assign reset_pending = state == ST_EPOCH;
	assign transport_quiescent = bus_idle && !cmd_valid && sinks_empty;
	always @(*) begin
		bus_want = !bus_idle || cmd_valid;
		DDRAM_RD = bus_state == BUS_OFFER && !bus_write;
		DDRAM_WE = bus_state == BUS_OFFER && bus_write;
		DDRAM_ADDR = bus_addr;
		DDRAM_DIN = bus_data;
		DDRAM_BURSTCNT = 8'd1;
	end
	always @(posedge clk) begin
		bus_done <= 1'b0;
		if (reset && !bus_idle)
			bus_killed <= 1'b1;
		case (bus_state)
			BUS_IDLE: if (cmd_valid && !reset) begin
				bus_addr <= cmd_addr;
				bus_data <= cmd_data;
				bus_write <= cmd_write;
				bus_killed <= 1'b0;
				bus_state <= BUS_OFFER;
			end
			BUS_OFFER: if (!DDRAM_BUSY) begin
				if (bus_write || DDRAM_DOUT_READY) begin
					bus_done <= !reset && !bus_killed;
					bus_result <= DDRAM_DOUT;
					bus_state <= BUS_IDLE;
				end else
					bus_state <= BUS_RESPONSE;
			end
			BUS_RESPONSE: if (DDRAM_DOUT_READY) begin
				bus_done <= !reset && !bus_killed;
				bus_result <= DDRAM_DOUT;
				bus_state <= BUS_IDLE;
			end
			default: bus_state <= BUS_IDLE;
		endcase
	end

	task automatic issue(input [1:0] kind, input wr,
	                     input [28:0] addr, input [63:0] data);
		begin
			cmd_valid <= 1'b1;
			cmd_write <= wr;
			cmd_addr <= addr;
			cmd_data <= data;
			tx_kind <= kind;
			if (kind == TX_POLL)
				poll_return_state <= state;
			state <= ST_COMMAND;
		end
	endtask

	wire [15:0] hdr_abi = {hdr[7], hdr[6]};
	wire header_common_ok = hdr32(0) == MAGIC_REC && hdr64(24) == 0 &&
	                         (hdr[4] == EVENT_NAL || hdr[5] == 0);
	wire header_session_ok = active && hdr64(8) == current_session &&
	                          hdr_abi == (session_v2 ? VIDEO_ABI : 16'd0);
	wire header_control_ok = header_session_ok && hdr32(20) == 0 &&
	                          (!session_v2 || hdr32(16) == 0);
	wire at_boundary = mode == MODE_HEADER && hdr_idx == 0;

	always @(posedge clk) begin
		cmd_valid <= 1'b0;
		out_flush <= 1'b0;
		bit_feed_soft_clear <= 1'b0;
		if (out_valid && !out_full) begin
			out_valid <= 1'b0;
			out_last <= 1'b0;
			bytes_out <= bytes_out + 32'd1;
		end
		if (bit_fire) begin
			bit_in_valid <= 1'b0;
			bit_in_last <= 1'b0;
		end
		// A CTRL poll may be outstanding while the metadata sink becomes
		// ready. Observe its handshake globally, not only in ST_META_WAIT.
		if (au_valid && au_ready) begin
			au_valid <= 0;
			mode <= MODE_PAYLOAD;
		end
		if (reset) begin
			state <= ST_IDLE;
			reset_parser();
			poll_div <= 0;
			out_valid <= 0;
			out_byte <= 0;
			out_last <= 0;
			active <= 0;
			paused <= 0;
			bytes_out <= 0;
			underrun_count <= 0;
			overrun_count <= 0;
			desync_count <= 0;
			last_bad_seq <= 0;
			host_write_count <= 0;
			fpga_read_count <= 0;
			write_count <= 0;
			read_count <= 0;
			cursor_count <= 0;
			current_session <= 0;
			expected_seq <= 0;
			consumer_seq <= 0;
			reset_seen <= 0;
			overrun_sticky <= 0;
			underrun_sticky <= 0;
			desync_sticky <= 0;
			fatal_sticky <= 0;
			telem_seq <= 0;
			publish_pending <= 1;
			publish_step <= 0;
			have_ctrl <= 0;
			empty_seen <= 0;
			seen_payload <= 0;
			byte_idx <= 0;
			bit_in_valid <= 0;
			bit_in_byte <= 0;
			bit_in_last <= 0;
			bit_feed_soft_clear <= 1;
			au_valid <= 0;
			au_session_id <= 0;
			au_seq <= 0;
			au_pts <= 0;
			au_duration <= 0;
			au_timebase_num <= 0;
			au_timebase_den <= 0;
			au_flags <= 0;
			committed_nonce <= 0;
			session_v2 <= 0;
			probe_done <= 0;
			probe_nonce <= 0;
			caps_publication <= 0;
			caps_pending <= 0;
			caps_step <= 0;
			lookahead <= 0;
			paused_data <= 0;
			replay_count <= 0;
			lookahead_seq <= 0;
			flush_pending <= 0;
			epoch_count <= 0;
			epoch_value <= 0;
			poll_return_state <= ST_IDLE;
		end else begin
			fpga_read_count <= {1'b0, read_count};
			poll_div <= poll_div + 1'd1;
			if (flush)
				flush_pending <= 1'b1;

			if (active && have_ctrl && seen_payload && avail == 0 &&
			    beat_left == 0 && !empty_seen && !paused) begin
				empty_seen <= 1;
				underrun_sticky <= 1;
				if (underrun_count != 16'hFFFF)
					underrun_count <= underrun_count + 16'd1;
				publish_pending <= 1;
			end else if (avail != 0)
				empty_seen <= 0;
			if (have_ctrl && avail > RING_BYTES_W && !overrun_sticky &&
			    state != ST_EPOCH) begin
				overrun_sticky <= 1;
				if (overrun_count != 16'hFFFF)
					overrun_count <= overrun_count + 16'd1;
				publish_pending <= 1;
			end

			case (state)
				ST_IDLE: if (bus_idle && (enable || flush_pending)) begin
					// Do not publish reset defaults as an acknowledged epoch.
					// Bootstrap must first sample CTRL and retire ST_EPOCH,
					// even when its epoch bit equals reset_seen's reset value.
					if (!have_ctrl)
						issue(TX_POLL, 0, CTRL_W, 0);
					else if (flush_pending && (at_boundary || fatal_sticky) && fence_idle) begin
						epoch_count <= write_count;
						epoch_value <= reset_seen;
						state <= ST_EPOCH;
					end else if (caps_pending) begin
						// Invalidate old publication before changing any reply field.
						// Only the final accepted MPC7 write commits this challenge.
						case (caps_step)
							0: issue(TX_CAPS, 1, CAPS_W + 7, {32'd0, CAPS_MAGIC7});
							1: issue(TX_CAPS, 1, CAPS_W, {VIDEO_LAYOUT, VIDEO_ABI, CAPS_MAGIC0});
							2: issue(TX_CAPS, 1, CAPS_W + 1,
							         {ENABLE_AU_PROTOCOL ? VIDEO_FEATURES : 32'd0, CAPS_MAGIC1});
							3: issue(TX_CAPS, 1, CAPS_W + 2, {MAX_HEIGHT, MAX_WIDTH, CAPS_MAGIC2});
							4: issue(TX_CAPS, 1, CAPS_W + 3, {AU_LIMIT, CAPS_MAGIC3});
							5: issue(TX_CAPS, 1, CAPS_W + 4, {VIDEO_BUILD_ID, CAPS_MAGIC4});
							6: issue(TX_CAPS, 1, CAPS_W + 5, {probe_nonce[31:0], CAPS_MAGIC5});
							7: issue(TX_CAPS, 1, CAPS_W + 6, {probe_nonce[63:32], CAPS_MAGIC6});
							default: issue(TX_CAPS, 1, CAPS_W + 7, {caps_publication, CAPS_MAGIC7});
						endcase
					end else if (publish_pending) begin
						case (publish_step)
							0: issue(TX_TELEM, 1, READ_W, {1'b0, read_count, MAGIC_READ});
							1: issue(TX_TELEM, 1, ERR_W,
							         {overrun_count[7:0], underrun_count[7:0],
							          active, overrun_sticky, underrun_sticky,
							          4'd0, reset_seen, telem_seq + 8'd1, MAGIC_ERR});
							2: issue(TX_TELEM, 1, STAT0_W, {ring_level, MAGIC_ST0});
							3: issue(TX_TELEM, 1, STAT1_W, {consumer_seq, MAGIC_ST1});
							4: issue(TX_TELEM, 1, STAT2_W, {last_bad_seq, MAGIC_ST2});
							5: issue(TX_TELEM, 1, STAT3_W, {current_session[31:0], MAGIC_ST3});
							6: issue(TX_TELEM, 1, STAT4_W, {current_session[63:32], MAGIC_ST4});
							7: issue(TX_TELEM, 1, STAT5_W, {underrun_count, overrun_count, MAGIC_ST5});
							default: issue(TX_TELEM, 1, STAT6_W, {desync_count, state_flags, MAGIC_ST6});
						endcase
					end else if (want_poll) begin
						issue(TX_POLL, 0, CTRL_W, 0);
					end else if (beat_left != 0 && !fatal_sticky && !overrun_sticky)
						state <= ST_CONSUME;
					else if (want_read) begin
						byte_idx <= read_byte_index;
						issue(TX_DATA, 0, DATA_W + read_qword_offset, 0);
					end
				end

				ST_COMMAND: if (bus_done) begin
					state <= ST_IDLE;
					case (tx_kind)
						TX_POLL: begin
							state <= poll_return_state;
							if (bus_result[31:0] == MAGIC_CTRL) begin
								have_ctrl <= 1;
								write_count <= bus_result[62:32];
								host_write_count <= {1'b0, bus_result[62:32]};
								if (bus_result[63] != reset_seen || !have_ctrl) begin
									// First CTRL is a baseline, never permission to replay
									// stale records/capabilities left in DDR by a prior core.
									epoch_count <= bus_result[62:32];
									epoch_value <= bus_result[63];
									out_valid <= 0;
									out_last <= 0;
									au_valid <= 0;
									bit_in_valid <= 0;
									out_flush <= 1;
									bit_feed_soft_clear <= 1;
									state <= ST_EPOCH;
								end
							end
						end
						TX_DATA: begin
							beat_q <= bus_result;
							beat_left <= consume_count;
							state <= ST_CONSUME;
						end
						TX_TELEM: begin
							if (publish_step == 1)
								telem_seq <= telem_seq + 8'd1;
							if (publish_step == 8) begin
								publish_step <= 0;
								publish_pending <= 0;
							end else
								publish_step <= publish_step + 1'd1;
						end
						TX_CAPS: begin
							if (caps_step == 8) begin
								caps_pending <= 0;
								caps_step <= 0;
								probe_done <= 1;
								committed_nonce <= probe_nonce;
								read_count <= cursor_count;
								publish_pending <= 1;
							end else
								caps_step <= caps_step + 1'd1;
						end
					endcase
				end

				ST_EPOCH: if (fence_idle) begin
					read_count <= epoch_count;
					cursor_count <= epoch_count;
					reset_seen <= epoch_value;
					active <= 0;
					paused <= 0;
					lookahead <= 0;
					paused_data <= 0;
					session_v2 <= 0;
					probe_done <= 0;
					committed_nonce <= 0;
					overrun_sticky <= 0;
					underrun_sticky <= 0;
					desync_sticky <= 0;
					fatal_sticky <= 0;
					seen_payload <= 0;
					current_session <= 0;
					expected_seq <= 0;
					consumer_seq <= 0;
					out_flush <= 1;
					bit_feed_soft_clear <= 1;
					publish_pending <= 1;
					publish_step <= 0;
					flush_pending <= 0;
					reset_parser();
					state <= ST_IDLE;
				end

				ST_CONSUME: begin
					if (fatal_sticky || overrun_sticky || avail > RING_BYTES_W)
						state <= ST_IDLE;
					else if (beat_left != 0 && can_consume && (enable || flush_pending)) begin
						byte_idx <= byte_idx + 3'd1;
						beat_left <= beat_left - 4'd1;
						cursor_count <= cursor_count + 31'd1;
						// The last header byte is committed by validation/fence,
						// never speculatively published as a control ACK.
						if (!lookahead && !(mode == MODE_HEADER && hdr_idx == 31)) begin
							read_count <= cursor_count + 31'd1;
							publish_pending <= 1;
						end
						if (beat_left == 1)
							state <= ST_IDLE;
						if (mode == MODE_PAYLOAD) begin
							out_byte <= rx_byte;
							out_valid <= 1;
							out_last <= payload_left == 1;
							bit_in_valid <= ENABLE_BIT_FEED;
							bit_in_byte <= rx_byte;
							bit_in_last <= payload_left == 1;
							seen_payload <= 1;
							payload_left <= payload_left - 32'd1;
							if (payload_left == 1) begin
								mode <= MODE_HEADER;
								hdr_idx <= 0;
							end
						end else begin
							hdr[hdr_idx] <= rx_byte;
							if (hdr_idx == 31) begin
								hdr_idx <= 0;
								state <= mode == MODE_HEADER ? ST_HEADER : ST_METADATA;
							end else
								hdr_idx <= hdr_idx + 5'd1;
						end
					end else if (beat_left == 0)
						state <= ST_IDLE;
					else if (want_poll && bus_idle)
						issue(TX_POLL, 0, CTRL_W, 0);
				end

				ST_HEADER: begin
					state <= ST_IDLE;
					if (!header_common_ok)
						fail_record();
					else if (hdr[4] == EVENT_PROBE) begin
						if (active || hdr_abi != VIDEO_ABI || hdr64(8) == 0 ||
						    hdr64(8) == probe_nonce || hdr32(16) != {16'd0, VIDEO_LAYOUT} ||
						    hdr32(20) != 0)
							fail_record();
						else begin
							probe_nonce <= hdr64(8);
							probe_done <= 0;
							committed_nonce <= 0;
							caps_pending <= 1;
							caps_step <= 0;
							caps_publication <= caps_publication == 32'hFFFFFFFF ?
							                    32'd1 : caps_publication + 32'd1;
						end
					end else if (hdr[4] == EVENT_BEGIN) begin
						if (active || hdr64(8) == 0 || hdr32(20) != 0 || hdr32(16) != 0 ||
						    !(hdr_abi == 0 || (hdr_abi == VIDEO_ABI && ENABLE_AU_PROTOCOL && probe_done)))
							fail_record();
						else
							state <= ST_FENCE;
					end else if (hdr[4] == EVENT_NAL || hdr[4] == EVENT_AU) begin
						if (!header_session_ok ||
						    hdr32(16) != (lookahead ? lookahead_seq : expected_seq) ||
						    (hdr[4] == EVENT_AU && (!session_v2 || !ENABLE_AU_PROTOCOL ||
						      hdr32(20) <= 32 || hdr32(20) - 32 > AU_LIMIT)) ||
						    (hdr[4] == EVENT_NAL && (session_v2 ||
						      hdr32(20) == 0 || hdr32(20) > RING_BYTES_W - HEADER_BYTES)))
							fail_record();
						else if (lookahead) begin
							payload_left <= hdr32(20);
							paused_data <= 1;
							lookahead_seq <= lookahead_seq + 32'd1;
							state <= ST_SKIP;
						end else begin
							read_count <= cursor_count;
							publish_pending <= 1;
							expected_seq <= expected_seq + 32'd1;
							consumer_seq <= hdr32(16);
							if (hdr[4] == EVENT_AU) begin
								au_session_id <= hdr64(8);
								au_seq <= hdr32(16);
								payload_left <= hdr32(20) - 32'd32;
								mode <= MODE_METADATA;
							end else begin
								payload_left <= hdr32(20);
								mode <= MODE_PAYLOAD;
							end
						end
					end else if (hdr[4] >= EVENT_FLUSH && hdr[4] <= EVENT_RESUME ||
					             hdr[4] == EVENT_DRAIN) begin
						if (!header_control_ok ||
						    (hdr[4] == EVENT_DRAIN && (!session_v2 || !ENABLE_AU_PROTOCOL)))
							fail_record();
						else if (lookahead) begin
							if (hdr[4] == EVENT_RESUME) begin
								// Resume is found without consuming the queued data.
								// Re-read it all from DDR in original order.
								lookahead <= 0;
								paused <= 0;
								cursor_count <= replay_count;
								beat_left <= 0;
							end else if (!paused_data) begin
								if (hdr[4] == EVENT_PAUSE) begin
									read_count <= cursor_count;
									replay_count <= cursor_count;
									publish_pending <= 1;
								end else
									state <= ST_FENCE;
							end else if (hdr[4] == EVENT_FLUSH && session_v2)
								lookahead_seq <= 0;
						end else if (hdr[4] == EVENT_PAUSE) begin
							paused <= 1;
							lookahead <= 1;
							paused_data <= 0;
							replay_count <= cursor_count;
							lookahead_seq <= expected_seq;
							read_count <= cursor_count;
							publish_pending <= 1;
						end else if (hdr[4] == EVENT_RESUME) begin
							paused <= 0;
							read_count <= cursor_count;
							publish_pending <= 1;
						end else
							state <= ST_FENCE;
					end else
						fail_record();
				end

				ST_SKIP: begin
					// The ring itself owns paused payload storage. The producer
					// must reserve a control-header slot for an in-band Resume.
					if ({1'b0, cursor_avail} >= payload_left) begin
						cursor_count <= cursor_count + 31'(payload_left);
						beat_left <= 0;
						payload_left <= 0;
						state <= ST_IDLE;
					end else if (bus_idle) begin
						// Keep polling while a paused record is only partly sent.
						issue(TX_POLL, 0, CTRL_W, 0);
					end
				end

				ST_METADATA: begin
					if (hdr64(0) == 64'h8000000000000000 ||
					    hdr32(8) == 0 || hdr[11][7] ||
					    hdr32(12) == 0 || hdr[15][7] ||
					    hdr[23][7] || (hdr32(24) & 32'hFFFFFFFE) != 0 ||
					    hdr32(28) != 0)
						begin
							fail_record();
							last_bad_seq <= au_seq;
						end
					else begin
						au_pts <= hdr64(0);
						au_timebase_num <= hdr32(8);
						au_timebase_den <= hdr32(12);
						au_duration <= hdr64(16);
						au_flags <= hdr32(24);
						au_valid <= 1;
						state <= ST_META_WAIT;
					end
				end
				ST_META_WAIT: if (fatal_sticky || overrun_sticky)
					state <= ST_IDLE;
				else if (!au_valid || au_ready) begin
					au_valid <= 0;
					mode <= MODE_PAYLOAD;
					state <= ST_IDLE;
				end else if (want_poll && bus_idle)
					issue(TX_POLL, 0, CTRL_W, 0);

				ST_FENCE: if (fatal_sticky || overrun_sticky)
					state <= ST_IDLE;
				else if (fence_idle) begin
					read_count <= cursor_count;
					if (lookahead)
						replay_count <= cursor_count;
					publish_pending <= 1;
					state <= ST_IDLE;
					if (hdr[4] == EVENT_BEGIN) begin
						active <= 1;
						paused <= 0;
						session_v2 <= hdr_abi == VIDEO_ABI;
						current_session <= hdr64(8);
						expected_seq <= 0;
						consumer_seq <= 0;
					end else if (hdr[4] == EVENT_END) begin
						active <= 0;
						paused <= 0;
						lookahead <= 0;
					end else if (hdr[4] == EVENT_FLUSH && session_v2) begin
						expected_seq <= 0;
						consumer_seq <= 0;
						lookahead_seq <= 0;
					end
					if (hdr[4] != EVENT_DRAIN) begin
						out_flush <= 1;
						bit_feed_soft_clear <= 1;
						seen_payload <= 0;
					end
				end else if (want_poll && bus_idle)
					issue(TX_POLL, 0, CTRL_W, 0);
				default: state <= ST_IDLE;
			endcase
		end
	end
endmodule
