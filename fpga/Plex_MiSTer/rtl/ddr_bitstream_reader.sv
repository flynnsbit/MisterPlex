// HPS DDR compressed-bitstream record-ring reader.
//
// The ARM daemon writes fixed 32-byte records into a power-of-two HPS DDR ring
// and publishes an absolute producer byte count in CTRL_PHYS.  NAL records carry
// Annex-B payload bytes; control records (begin/flush/end/pause/resume) are
// consumed at record boundaries so a seek/flush cannot splice mid-NAL.  The FPGA
// publishes read_count plus transport telemetry in DDR, keeping this path wholly
// separate from MiSTer's shared HPS<->FPGA SPI/GPO register.

// Physical map (must match host/libmisterplex/ddr_bitstream_ring.hpp):
//   720p dual-bank frame store occupies [0x30000000, 0x30300000) with doorbell
//   0x302FF000. Ring sits AFTER that map end — legacy 0x3010_0000/0x3014_0000
//   collided with bank0 and made ddr_status unreadable.
//   DATA  0x30300000..0x3033FFFF (256 KiB)
//   CTRL+ 0x30340000 (PLXB/PLXR/PLXE/STATn)
module ddr_bitstream_reader #(
	parameter [31:0] DATA_PHYS  = 32'h3030_0000,
	parameter [31:0] CTRL_PHYS  = 32'h3034_0000,
	parameter [31:0] READ_PHYS  = 32'h3034_0008,
	parameter [31:0] ERR_PHYS   = 32'h3034_0010,
	parameter [31:0] STAT0_PHYS = 32'h3034_0018,
	parameter [31:0] STAT1_PHYS = 32'h3034_0020,
	parameter [31:0] STAT2_PHYS = 32'h3034_0028,
	parameter [31:0] STAT3_PHYS = 32'h3034_0030,
	parameter [31:0] STAT4_PHYS = 32'h3034_0038,
	parameter [31:0] STAT5_PHYS = 32'h3034_0040,
	parameter [31:0] STAT6_PHYS = 32'h3034_0048,
	parameter int RING_BYTES    = 262144,
	parameter int POLL_DIV_BITS = 6
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
		ST_POLL      = 4'd2,
		ST_READ_WAIT = 4'd3,
		ST_CONSUME   = 4'd4,
		// o96: force complete lite PLXR→PLXE without poll/read stealing mid-step.
		// o95 arm_publish still PUBLISH_DEAD (PLXR only, PLXE=0 on wipe).
		ST_PUBLISH   = 4'd5;

	localparam [1:0]
		MODE_HEADER  = 2'd0,
		MODE_PAYLOAD = 2'd1,
		MODE_DROP    = 2'd2;

	reg [3:0] state;
	reg [1:0] mode;
	reg [POLL_DIV_BITS-1:0] poll_div;
	reg [63:0] beat_q;
	reg [2:0] byte_idx;
	reg [3:0] beat_left;
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
	// o97: cycles to wait after PLXR WE before PLXE so m1 we_ack_s2 of first
	// grant cannot clear m1_we_req after second WE latch (o96 ST_PUBLISH still
	// DEAD: PLXR live PLXE=0 — 1-cycle WE gap races ack_s2).
	reg [4:0] pub_gap;
	reg have_ctrl;
	reg empty_seen;
	reg seen_payload;
	// o49 RCA: poll_div==0 is a 1-cycle pulse; m1 grant/busy CDC needs many
	// cycles → CTRL RD starved (live telem_seq=1). o50 sticky FF STA-hostile.
	// o54 8/64 window: setup −77 hold −283. o55: level want_poll ONLY until
	// first PLXB, then original 1-cycle pulse; keep ST_POLL reissue.
	// o67: poll-complete heartbeat — live o66 stream-only still never moves
	// PLXR after boot publish; distinguish ST_POLL stuck vs silent !PLXB RD.
	// o68: o67 telem stuck at 1 ⇒ ST_POLL never saw DOUT_READY. Timeout abandons
	// poll, stamps last_bad, forces publish so WE path/heartbeat is visible.
	reg [5:0] poll_hb;
	reg [15:0] poll_wait;
	reg [15:0] hb_div;
	reg [15:0] stuck_cnt;
	// o83: drop o81 rd_inflight. o82 PUBLISH_DEAD; o80 without it was LIVE.
	// Stale-beat protection: age-only m1 FIFO pop (o68/o82).
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
	wire ring_has_data = have_ctrl && (avail != 32'd0) && !overrun_sticky && !fatal_sticky;
	wire [RING_AW-1:0] read_ring_index = read_count[RING_AW-1:0];
	wire [28:0] read_qword_offset = 29'(read_ring_index >> 3);
	wire [2:0] read_byte_index = read_ring_index[2:0];
	wire [31:0] bytes_to_qword_end = 32'd8 - {29'd0, read_byte_index};
	wire [31:0] consume_count_w =
		(avail < bytes_to_qword_end) ? avail : bytes_to_qword_end;
	wire [3:0] consume_count = consume_count_w[3:0];
	// Until first PLXB: level (survives m1 busy CDC). After: 1-cyc/64 like o44.
	// o100: also level-poll when avail==0 after have_ctrl so host write_count
	// growth is re-sampled (o98 STREAM1: plant 0→0x40 one-shot; CONT stuck at
	// 0x40 because pulse-only poll lost under per-beat/HB publish pressure).
	// While ring_has_data (avail!=0): keep 1-cyc/64 only — avoid CTRL spam mid-drain.
	// o88 soft hold KEPT on want_read (o99 removed it + IDLE reorder + dropped
	// per-beat arm_publish → plant cons_max=0x8 REGRESS). o100 does NOT touch
	// READ_WAIT-until-DOUT, IDLE publish-first priority, or o91 empty-beat arm.
	// o87 kept LIVE wipe + R3 no beat-end publish; plant still cons=0/telem freeze.
	wire want_poll = enable && (
		!have_ctrl ||
		(avail == 32'd0) ||
		(poll_div == {POLL_DIV_BITS{1'b0}})
	);
	// o88: soft hold — suppress DATA want_read only while publish_pending so
	// the 9-step WE can finish after a beat. Do NOT gate want_poll (o86 hard
	// hold on poll+read + WE-before-RD regressed wipe to PUBLISH_DEAD).
	wire want_read = enable && !publish_pending && ring_has_data && (beat_left == 4'd0);
	wire want_pub = enable && publish_pending;
	wire can_consume = (mode != MODE_PAYLOAD) || !out_full;
	wire [15:0] state_flags = {4'd0, fatal_sticky, desync_sticky, paused, active,
	                           overrun_sticky, underrun_sticky, mode, state};

	function automatic [7:0] beat_byte(input [63:0] beat, input [2:0] idx);
		begin
			case (idx)
				3'd0: beat_byte = beat[7:0];
				3'd1: beat_byte = beat[15:8];
				3'd2: beat_byte = beat[23:16];
				3'd3: beat_byte = beat[31:24];
				3'd4: beat_byte = beat[39:32];
				3'd5: beat_byte = beat[47:40];
				3'd6: beat_byte = beat[55:48];
				default: beat_byte = beat[63:56];
			endcase
		end
	endfunction

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

	// o95: re-arm must not reset publish_step while a lite publish (PLXR→PLXE)
	// is in flight. o94 post-DOUT / empty-beat re-arms every 8B and kept
	// restarting at step0 → PLXR live (cons advanced) but PLXE never written
	// (wipe telem_u=0 / PUBLISH_DEAD with cons=0x40 residual).
	task automatic arm_publish;
		begin
			if (!publish_pending)
				publish_step <= 4'd0;
			publish_pending <= 1'b1;
		end
	endtask

	task automatic mark_desync(input [31:0] bad_seq);
		begin
			desync_sticky <= 1'b1;
			last_bad_seq <= bad_seq;
			if (desync_count != 16'hFFFF)
				desync_count <= desync_count + 16'd1;
			arm_publish();
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

	wire bus_want_comb =
		(state == ST_IDLE) ? (want_poll || want_read || want_pub) :
		((state == ST_POLL) || (state == ST_READ_WAIT) || (state == ST_PUBLISH));

	always @(posedge clk) begin
		out_valid <= 1'b0;
		out_flush <= 1'b0;
		DDRAM_RD <= 1'b0;
		DDRAM_WE <= 1'b0;

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
			pub_gap <= 5'd0;
			have_ctrl <= 1'b0;
			empty_seen <= 1'b0;
			seen_payload <= 1'b0;
			poll_hb <= 6'd0;
			poll_wait <= 16'd0;
			hb_div <= 16'd0;
			stuck_cnt <= 16'd0;
			beat_left <= 4'd0;
			byte_idx <= 3'd0;
			hdr_idx <= 5'd0;
			payload_left <= 32'd0;
		end else if (!enable) begin
			state <= ST_IDLE;
			bus_want <= 1'b0;
			active <= 1'b0;
			paused <= 1'b0;
			reset_parser();
		end else begin
			bus_want <= !flush && bus_want_comb;
			poll_div <= poll_div + 1'd1;

			// o80: free-running publish heartbeat (~2ms @30MHz) independent of
			// POLL completion. If ST_READ_WAIT/CONSUME wedges, telem used to
			// freeze forever; force publish_pending so IDLE can emit PLXR.
			hb_div <= hb_div + 16'd1;
			if (hb_div == 16'hffff) begin
				arm_publish();
			end
			// o80: escape non-IDLE stick (~2ms) back to IDLE for publish/poll.
			if (state == ST_IDLE || state == ST_RESET)
				stuck_cnt <= 16'd0;
			else if (stuck_cnt != 16'hffff)
				stuck_cnt <= stuck_cnt + 16'd1;
			if (state != ST_IDLE && state != ST_RESET && stuck_cnt == 16'hffff) begin
				last_bad_seq <= 32'hDEAD0004;
				arm_publish();
				poll_wait <= 16'd0;
				state <= ST_IDLE;
			end

			if (flush) begin
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
				arm_publish();
				state <= ST_IDLE;
				reset_parser();
			end

			if (active && have_ctrl && seen_payload && (avail == 32'd0) &&
			    (beat_left == 4'd0) && !empty_seen && !paused) begin
				empty_seen <= 1'b1;
				underrun_sticky <= 1'b1;
				if (underrun_count != 16'hFFFF)
					underrun_count <= underrun_count + 16'd1;
				arm_publish();
			end else if (avail != 32'd0) begin
				empty_seen <= 1'b0;
			end

			if (avail > RING_BYTES_W && !overrun_sticky) begin
				overrun_sticky <= 1'b1;
				if (overrun_count != 16'hFFFF)
					overrun_count <= overrun_count + 16'd1;
				arm_publish();
			end

			case (state)
				ST_RESET: begin
					state <= ST_IDLE;
					arm_publish();
				end

				ST_IDLE: begin
					// o72: publish MUST beat poll. o79: after DEAD0003 CONSUME timeout we
					// land here with beat_left>0 — publish/poll first, then resume
					// CONSUME (want_read alone cannot, it requires beat_left==0).
					// o96: issue PLXR then enter ST_PUBLISH for PLXE — do not stay in
					// IDLE between steps (want_poll level pre-have_ctrl can race the
					// post-WE dead cycle; o95 step-preserve still wiped PLXE=0).
					if (publish_pending && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_BURSTCNT <= 8'd1;
						if (publish_step == 4'd0) begin
							DDRAM_ADDR <= READ_W;
							DDRAM_DIN <= {read_count, MAGIC_READ};
							DDRAM_WE <= 1'b1;
							publish_step <= 4'd1;
							// ≥16 cyc: grant + 2FF ack_s2 + margin before second WE
							pub_gap <= 5'd16;
							poll_wait <= 16'd0;
							state <= ST_PUBLISH;
						end else begin
							// Recover mid-lite (step1) if re-entered IDLE without ST_PUBLISH.
							DDRAM_ADDR <= ERR_W;
							DDRAM_DIN <= {overrun_count[7:0], underrun_count[7:0],
							              active, overrun_sticky, underrun_sticky, 5'd0,
							              telem_seq + 8'd1, MAGIC_ERR};
							DDRAM_WE <= 1'b1;
							telem_seq <= telem_seq + 8'd1;
							publish_step <= 4'd0;
							publish_pending <= 1'b0;
					end
					end else if (want_poll && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= CTRL_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						poll_wait <= 16'd0;
						state <= ST_POLL;
					end else if (want_read && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= DATA_W + read_qword_offset;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						byte_idx <= read_byte_index;
						state <= ST_READ_WAIT;
					end else if (beat_left != 4'd0) begin
						// o79: resume partial beat after publish/poll window
						state <= ST_CONSUME;
						poll_wait <= 16'd0;
					end
				end

				// o96/o97: second lite WE only — no poll/read until PLXE posted.
				// o97: wait pub_gap after PLXR so first m1 we_ack_s2 cannot drop
				// m1_we_req that latched PLXE (o96 1-cycle gap → PLXE lost, PLXR ok).
				ST_PUBLISH: begin
					if (pub_gap != 5'd0) begin
						pub_gap <= pub_gap - 5'd1;
					end else if (!DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_ADDR <= ERR_W;
						DDRAM_DIN <= {overrun_count[7:0], underrun_count[7:0],
						              active, overrun_sticky, underrun_sticky, 5'd0,
						              telem_seq + 8'd1, MAGIC_ERR};
						DDRAM_WE <= 1'b1;
						telem_seq <= telem_seq + 8'd1;
						publish_step <= 4'd0;
						publish_pending <= 1'b0;
						state <= ST_IDLE;
					end else if (poll_wait == 16'hFFFF) begin
						// Escape if bus stuck; re-arm so IDLE can retry PLXE path.
						last_bad_seq <= 32'hDEAD0006;
						poll_wait <= 16'd0;
						state <= ST_IDLE;
					end else begin
						poll_wait <= poll_wait + 16'd1;
					end
				end

				// o54: reissue CTRL RD while waiting (grant/busy CDC); want_poll
				// is level/window combo so IDLE can arm without sticky FF.
				ST_POLL: begin
					// o83: accept DOUT without rd_inflight (restore o80 LIVE path).
					if (DDRAM_DOUT_READY) begin
						// o67: always stash low 32 of CTRL beat (PLXB or garbage).
						last_bad_seq <= DDRAM_DOUT[31:0];
						poll_wait <= 16'd0;
						if (ctrl_magic_ok) begin
							have_ctrl <= 1'b1;
							write_count <= {1'b0, ctrl_write_count};
							host_write_count <= {1'b0, ctrl_write_count};
							// Epoch edge: host zeroed the ring and toggled CTRL[63].
							// Always snap consumer to 0 — NEVER to current write_count.
							// Race: flush(count=0,epoch++) then Begin(count=32) can land
							// in one POLL; snapping to write_count would skip Begin+NALs
							// and leave PLXR consumer stuck at 0 forever (o12 STREAM=1).
							if (ctrl_reset != reset_seen) begin
								reset_seen <= ctrl_reset;
								read_count <= 32'd0;
								fpga_read_count <= 32'd0;
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
								arm_publish();
								reset_parser();
							end
						end
						// Heartbeat publish every 64 POLL completions (not every beat —
						// o61 always-publish was STA-red). Proves DOUT path + exposes
						// last_bad_seq/telem_seq on host without full diag tax.
						poll_hb <= poll_hb + 6'd1;
						if (poll_hb == 6'd63) begin
							arm_publish();
						end
						state <= ST_IDLE;
					end else if (poll_wait == 16'hFFFF) begin
						// o68: ~2ms @30MHz with no DOUT — abandon, publish marker.
						last_bad_seq <= 32'hDEAD0001; // poll timeout, no DOUT_READY
						arm_publish();
						poll_wait <= 16'd0;
						state <= ST_IDLE;
					end else begin
						poll_wait <= poll_wait + 16'd1;
						// o83/o80: reissue CTRL RD while waiting (grant/busy CDC).
						if (!DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
							DDRAM_ADDR <= CTRL_W;
							DDRAM_BURSTCNT <= 8'd1;
							DDRAM_RD <= 1'b1;
						end
					end
				end

				ST_READ_WAIT: begin
					// o74: mirror ST_POLL timeout — DATA RD with no DOUT left BSR
					// stuck out of IDLE (no publish, cons=0) after have_ctrl.
					// o83: accept without rd_inflight (o80).
					// o98: drop o94 abandon-on-publish_pending. o97 pub_gap fixed
					// wipe LIVE (PLXE moving telem_u=32) but plant cons_max=0 —
					// HB/publish re-arm during READ_WAIT cancelled DATA DOUT so
					// CONSUME never advanced read_count. Finish DATA beat first;
					// publish after DOUT (keep post-DOUT arm) or timeout.
					if (DDRAM_DOUT_READY) begin
						beat_q <= DDRAM_DOUT;
						beat_left <= consume_count;
						poll_wait <= 16'd0;
						// o94/o98: surface after DATA beat; then ST_IDLE publishes
						// (pending) and resumes CONSUME via beat_left.
						arm_publish();
						state <= ST_IDLE;
					end else if (poll_wait == 16'hFFFF) begin
						last_bad_seq <= 32'hDEAD0002; // data RD timeout
						arm_publish();
						poll_wait <= 16'd0;
						state <= ST_IDLE;
					end else begin
						poll_wait <= poll_wait + 16'd1;
						if (!DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
							DDRAM_ADDR <= DATA_W + read_qword_offset;
							DDRAM_BURSTCNT <= 8'd1;
							DDRAM_RD <= 1'b1;
						end
					end
				end

				ST_CONSUME: begin
					if (beat_left != 4'd0 && can_consume) begin
						rx_byte = beat_byte(beat_q, byte_idx);
						byte_idx <= byte_idx + 3'd1;
						beat_left <= beat_left - 4'd1;
						read_count <= read_count + 32'd1;
						fpga_read_count <= read_count + 32'd1;
						// o85: do NOT publish every byte. Per-byte publish_pending forced a
						// full 9-beat PLXR..ST6 WE burst between nearly every DATA beat and
						// left m1 WE dead after plant (telem freeze, cons sticky). Publish
						// on beat end / record boundary / desync / HB only.

						if (mode == MODE_PAYLOAD) begin
							out_byte <= rx_byte;
							out_valid <= 1'b1;
							bytes_out <= bytes_out + 32'd1;
							seen_payload <= 1'b1;
							payload_left <= payload_left - 32'd1;
							if (payload_left == 32'd1) begin
								mode <= MODE_HEADER;
								hdr_idx <= 5'd0;
								arm_publish();
							end
						end else if (mode == MODE_DROP) begin
							payload_left <= payload_left - 32'd1;
							if (payload_left == 32'd1) begin
								mode <= MODE_HEADER;
								hdr_idx <= 5'd0;
								arm_publish();
							end
						end else begin
							hdr[hdr_idx] = rx_byte;
							if (hdr_idx == 5'd31) begin
								hdr_idx <= 5'd0;
								// Always surface PLXR after a full 32B header parse.
								arm_publish();
								if (hdr32(0) != MAGIC_REC || hdr32(24) != 32'd0) begin
									// o85: desync+continue, no fatal_sticky. Permanent fatal
									// cleared ring_has_data and froze cons at 0x20 on junk
									// plant (o80–o84). Epoch flush still hard-resets; host
									// STREAM can re-align. Keep draining remaining avail.
									active <= 1'b0;
									mark_desync(hdr32(16));
								end else if (hdr[4] == EVENT_BEGIN) begin
									if (active || hdr32(20) != 32'd0) begin
										// Protocol error on BEGIN — desync, keep bus alive.
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

						// o91: do NOT jump IDLE on beat_left==1 same cycle as last byte
						// (o90 did; fit STA_RED setup g2 -0.159 / hold g0 -0.246 — no deploy).
						// After last byte, nonblocking beat_left→0; next cycle empty branch
						// arms lite publish + IDLE. Same host cadence as o90 (RD→CONSUME→
						// 2WE→RD) with less combo on the consume path for STA.
						poll_wait <= 16'd0;
					end else if (beat_left == 4'd0) begin
						// o91: every completed DATA beat → lite publish (PLXR+PLXE).
						// o89 never armed here → plant cons=0 after DATA; o84 per-byte
						// reached 0x20. Empty-entry publish restores beat surface.
						state <= ST_IDLE;
						arm_publish();
						poll_wait <= 16'd0;
					end else if (poll_wait == 16'hFFFF) begin
						// o74: out_full (or other) stall — return to IDLE so
						// publish/poll can run; keep beat for retry.
						last_bad_seq <= 32'hDEAD0003;
						arm_publish();
						poll_wait <= 16'd0;
						state <= ST_IDLE;
					end else begin
						poll_wait <= poll_wait + 16'd1;
					end
				end

				default: state <= ST_IDLE;
			endcase
		end
	end
endmodule
