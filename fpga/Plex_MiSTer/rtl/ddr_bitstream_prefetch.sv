// Burst prefetch front-end for the HPS DDR compressed-bitstream ring.
//
// The record reader used to issue one single-qword DDR read, wait the full
// round trip, consume at most 8 bytes and then start over.  That ties the
// bitstream rate to DDR latency, and DDR latency here is VARIABLE (the DPB
// fetch path already got caught assuming otherwise) so the worst case, not the
// average, is what the decoder sees.
//
// This module decouples the two: it keeps a byte FIFO deep enough to cover a
// full round trip, issues multi-qword bursts to refill it, and tracks beats
// in flight so it never depends on WHEN a beat comes back, only on the order
// beats come back in (which Avalon-MM guarantees within a burst).
//
// Ring rules:
//   * The producer pointer `write_count` and the consumer pointer this module
//     publishes as `read_count` are ABSOLUTE byte counts, never ring offsets.
//     Empty is read_count == write_count and full is write_count - read_count
//     == RING_BYTES; the two are distinct because the counts are absolute, so
//     the ambiguity a bare pair of ring offsets would have simply cannot arise.
//   * write_count is NOT qword aligned: records carry variable length payloads,
//     so the producer routinely stops in the middle of a qword.  The final,
//     partially produced qword IS fetched (otherwise the last few bytes of a
//     NAL would never arrive) but the bytes above write_count in it are never
//     delivered, and the qword is refetched once the producer extends it.  The
//     refetch is what keeps stale tail bytes from ever reaching the parser.
//   * A burst never crosses the ring wrap: the fetch is clipped at the end of
//     the ring and the next burst restarts at the ring base.
//
// Backpressure is strict.  A burst is only issued when the FIFO has room for
// it INCLUDING everything already in flight, and bytes leave only on
// out_valid && out_ready, so a stalled decoder can neither drop nor duplicate a
// byte.  When the ring runs dry out_valid simply drops.

module ddr_bitstream_prefetch #(
	parameter int FIFO_QWORDS   = 64,
	parameter int BURST_QWORDS  = 16,
	parameter int RING_BYTES    = 262144
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        enable,

	// Drop everything buffered and restart the consumer pointer.
	input  wire        sync_valid,
	input  wire [31:0] sync_count,

	input  wire [31:0] write_count,
	input  wire [28:0] ring_base_qw,

	// DDR request side.  The parent owns the DDR port and arbitrates; this
	// module only asks.  fetch_grant means the parent issued the read THIS
	// cycle with the address and length presented here.
	output wire        fetch_req,
	output wire [28:0] fetch_addr,
	output wire  [7:0] fetch_len,
	input  wire        fetch_grant,
	// Length the parent actually programmed into BURSTCNT for this grant.  The
	// parent registers ADDR/BURSTCNT a cycle before it can raise fetch_grant,
	// so burst_qw may have moved on; the grant length is the authoritative one.
	input  wire  [7:0] fetch_grant_len,

	// DDR return side, one beat per DDRAM_DOUT_READY belonging to this module.
	input  wire        beat_valid,
	input  wire [63:0] beat_data,

	output wire        out_valid,
	output wire  [7:0] out_byte,
	input  wire        out_ready,

	output wire [31:0] read_count,
	output wire [31:0] fetch_count,
	output wire  [7:0] fifo_qwords,
	output wire        beats_pending
);
	localparam int RING_QWORDS = RING_BYTES / 8;
	localparam int RING_QW_AW  = $clog2(RING_QWORDS);
	localparam int FIFO_AW     = $clog2(FIFO_QWORDS);
	localparam [31:0] RING_BYTES_W = 32'(RING_BYTES);

	(* ramstyle = "M10K" *)
	reg [63:0] fifo_mem [0:FIFO_QWORDS-1];
	reg [FIFO_AW:0] fifo_wr;
	reg [FIFO_AW:0] fifo_rd;

	// Absolute byte pointers.  deliver_ptr is what the parser has consumed;
	// fetch_ptr is qword aligned and always >= deliver_ptr.
	reg [31:0] deliver_ptr;
	reg [31:0] fetch_ptr;
	reg [7:0]  inflight;
	reg [7:0]  drop_beats;
	reg [2:0]  out_lane;
	// Tail bookkeeping: the aligned address of the partially produced qword we
	// last fetched, and the producer count it was fetched under.
	reg        partial_valid;
	reg [31:0] partial_ptr;
	reg [31:0] partial_wc;

	wire [FIFO_AW:0] fifo_used = fifo_wr - fifo_rd;
	wire [FIFO_AW:0] fifo_free = FIFO_QWORDS[FIFO_AW:0] - fifo_used;
	wire fifo_empty = (fifo_wr == fifo_rd);

	// Qwords the producer has touched (ceiling, so the partial tail counts).
	wire [31:0] produced_qw = (write_count + 32'd7) >> 3;
	wire [31:0] fetched_qw  = fetch_ptr >> 3;
	wire [31:0] ready_qw    = (produced_qw > fetched_qw) ? (produced_qw - fetched_qw)
	                                                     : 32'd0;

	wire [RING_QW_AW-1:0] ring_qw_index = fetched_qw[RING_QW_AW-1:0];
	wire [31:0] qw_to_ring_end = 32'(RING_QWORDS) - {{(32-RING_QW_AW){1'b0}}, ring_qw_index};

	// Room that is genuinely free once every beat already asked for lands.
	wire [31:0] fifo_room = {{(31-FIFO_AW){1'b0}}, fifo_free} - {24'd0, inflight};
	// A resync in progress owns the FIFO until its stale beats have drained.

	function automatic [31:0] min32(input [31:0] a, input [31:0] b);
		min32 = (a < b) ? a : b;
	endfunction

	wire [31:0] burst_qw = min32(min32(ready_qw, qw_to_ring_end),
	                             min32(fifo_room, 32'(BURST_QWORDS)));

	// The tail qword has to be reread once the producer extends it, and that can
	// only be done safely after everything ahead of it has been delivered.
	wire tail_stale = partial_valid && (write_count != partial_wc) &&
	                  (deliver_ptr >= partial_ptr);

	assign fetch_req  = enable && (drop_beats == 8'd0) && !tail_stale &&
	                    (burst_qw != 32'd0);
	assign fetch_addr = ring_base_qw + {{(29-RING_QW_AW){1'b0}}, ring_qw_index};
	assign fetch_len  = burst_qw[7:0];

	wire [63:0] head_qword = fifo_mem[fifo_rd[FIFO_AW-1:0]];
	wire [7:0]  head_byte =
		(out_lane == 3'd0) ? head_qword[7:0] :
		(out_lane == 3'd1) ? head_qword[15:8] :
		(out_lane == 3'd2) ? head_qword[23:16] :
		(out_lane == 3'd3) ? head_qword[31:24] :
		(out_lane == 3'd4) ? head_qword[39:32] :
		(out_lane == 3'd5) ? head_qword[47:40] :
		(out_lane == 3'd6) ? head_qword[55:48] : head_qword[63:56];

	// The head qword may start before deliver_ptr when the consumer pointer was
	// resynchronised mid-qword; out_lane carries that skew.
	// A discard cycle must not present a byte: the parent consumes on out_valid
	// alone, so offering a byte we are about to drop would hand the parser the
	// same byte twice and desynchronise the record stream.
	assign out_valid = enable && !fifo_empty && !sync_valid && !tail_stale &&
	                   (deliver_ptr < write_count);
	assign out_byte  = head_byte;

	assign read_count    = deliver_ptr;
	assign fetch_count   = fetch_ptr;
	assign fifo_qwords   = {{(8-FIFO_AW-1){1'b0}}, fifo_used};
	assign beats_pending = (inflight != 8'd0) || (drop_beats != 8'd0);

	wire [7:0] grant_add = fetch_grant ? fetch_grant_len : 8'd0;
	// A beat landing on the very cycle we decide to discard has to be counted
	// off there and then, or the discard count runs one high and eats a good
	// beat from the next burst.
	wire [7:0] beat_now = beat_valid ? 8'd1 : 8'd0;
	wire [7:0] sync_pend  = inflight + grant_add;
	wire [7:0] sync_drop  = (sync_pend > beat_now) ? (sync_pend - beat_now) : 8'd0;
	wire [7:0] tail_pend  = drop_beats + inflight + grant_add;
	wire [7:0] tail_drop  = (tail_pend > beat_now) ? (tail_pend - beat_now) : 8'd0;
	wire beat_drop = beat_valid && (drop_beats != 8'd0);
	wire beat_keep = beat_valid && (drop_beats == 8'd0) && (inflight != 8'd0);

	always @(posedge clk) begin
		if (reset) begin
			fifo_wr <= '0;
			fifo_rd <= '0;
			deliver_ptr <= 32'd0;
			fetch_ptr <= 32'd0;
			inflight <= 8'd0;
			drop_beats <= 8'd0;
			out_lane <= 3'd0;
			partial_valid <= 1'b0;
			partial_ptr <= 32'd0;
			partial_wc <= 32'd0;
		end else if (sync_valid) begin
			// Everything buffered belongs to the old position: drop it.  Beats
			// still in flight must still be counted off as they land, but they
			// are written nowhere.
			fifo_wr <= '0;
			fifo_rd <= '0;
			deliver_ptr <= sync_count;
			fetch_ptr <= {sync_count[31:3], 3'd0};
			out_lane <= sync_count[2:0];
			// Beats already asked for still come back.  They belong to the old
			// position, so they must be counted off and thrown away rather than
			// pushed: dropping the count instead would desynchronise the FIFO
			// against the next burst.
			drop_beats <= sync_drop;
			inflight <= 8'd0;
			partial_valid <= 1'b0;
		end else if (tail_stale) begin
			// Internal resync onto the qword that holds deliver_ptr.  Nothing
			// buffered can be lost here: deliver_ptr has already reached the
			// partial qword, so everything ahead of it is spoken for.
			fifo_wr <= '0;
			fifo_rd <= '0;
			fetch_ptr <= {deliver_ptr[31:3], 3'd0};
			out_lane <= deliver_ptr[2:0];
			drop_beats <= tail_drop;
			inflight <= 8'd0;
			partial_valid <= 1'b0;
		end else begin
			if (fetch_grant) begin
				fetch_ptr <= fetch_ptr + {fetch_grant_len[28:0], 3'd0};
				if ((write_count[2:0] != 3'd0) &&
				    ((fetched_qw + {24'd0, fetch_grant_len}) >= produced_qw)) begin
					partial_valid <= 1'b1;
					partial_ptr <= {write_count[31:3], 3'd0};
					partial_wc <= write_count;
				end
			end

			inflight <= inflight + grant_add - (beat_keep ? 8'd1 : 8'd0);

			if (beat_drop)
				drop_beats <= drop_beats - 8'd1;

			if (beat_keep) begin
				fifo_mem[fifo_wr[FIFO_AW-1:0]] <= beat_data;
				fifo_wr <= fifo_wr + 1'b1;
			end

			if (out_valid && out_ready) begin
				deliver_ptr <= deliver_ptr + 32'd1;
				out_lane <= out_lane + 3'd1;
				if (out_lane == 3'd7)
					fifo_rd <= fifo_rd + 1'b1;
			end
		end
	end

	// RING_BYTES_W is the full/empty reference the parent publishes; keep it
	// observable so the parameter cannot be silently mismatched away.
	wire _unused_ring = |RING_BYTES_W;
endmodule
