// IDR handling and bitstream desynchronisation recovery.
//
// WHY THIS MATTERS ON THIS CONTENT
//   The stream is 7 IDRs against 343 P frames.  An IDR is the only place a
//   decoder can re-enter with no dependence on history, so the expected cost
//   of a desync is on the order of fifty frames of wrong picture -- two
//   seconds -- and the worst case is the rest of the GOP.  There is no cheap
//   mid-GOP recovery available: every P frame predicts from the reference the
//   desync already corrupted, so "carry on and hope" is strictly worse than
//   stopping, because it keeps writing garbage into the reference that the
//   next 300 frames will predict from.
//
// WHAT COUNTS AS A DESYNC
//   CAVLC is a variable-length code.  A wrong table entry does not corrupt one
//   coefficient, it consumes the wrong number of bits, and from that point the
//   bit position is meaningless.  The symptoms are all cheap to detect and all
//   mean the same thing:
//
//     - a coeff_token / total_zeros / run_before lookup that matched no code
//     - a macroblock type that does not exist for the slice type
//     - the macroblock address running past PicSizeInMbs
//     - slice data ending before the last macroblock of the slice
//     - bits left over after the last macroblock of the slice
//
//   The last two are the ones that catch a desync that happened to stay inside
//   every table: the bit position and the macroblock count disagree at the end
//   of the slice.
//
// WHAT RECOVERY DOES
//   Stop decoding the slice immediately -- do not emit the rest of it -- and
//   wait for the next IDR.  Resynchronisation reuses the existing
//   nalu_scanner, which already owns start-code detection across DDR burst
//   boundaries and already classifies nal_unit_type 5; a second private
//   scanner would be a second place for the start-code emulation-prevention
//   rules to be got wrong, and the two would disagree at burst boundaries.
//
//   While resyncing, freeze_output holds the last complete good frame on
//   screen.  Showing the partially decoded frame would be worse than showing a
//   stale one, and showing nothing is worse than both.
//
// IDR HANDLING
//   An IDR slice, whether or not anything was wrong, flushes the DPB, resets
//   frame_num and picture order count state, and drops any partially decoded
//   macroblock state left behind by the previous picture.  That is required by
//   the standard for a correct decode and it is also exactly the reset a
//   recovering decoder needs, so the same pulses serve both paths.

`default_nettype none

module h264_stream_recovery (
	input  wire        clk,
	input  wire        reset,

	// ── Slice boundaries, from the shared nalu_scanner / slice header path ──
	input  wire        slice_start,        // pulse: a slice header has been parsed
	input  wire        slice_is_idr,       // that slice is in an IDR picture
	input  wire        slice_end,          // pulse: slice data consumed

	// ── Desync evidence from the decode pipeline ──
	input  wire        err_cavlc_miss,     // a VLC lookup matched no code
	input  wire        err_bad_mb_type,    // mb_type illegal for this slice type
	input  wire        err_mb_overrun,     // mb address >= PicSizeInMbs
	input  wire        err_slice_short,    // slice data ran out early
	input  wire        err_slice_long,     // bits left after the last macroblock

	// ── Control back into the pipeline ──
	output wire        decode_enable,      // low: stop consuming this slice
	output reg         dpb_flush,          // pulse: invalidate every reference
	output reg         poc_reset,          // pulse: reset frame_num / POC state
	output reg         mb_state_clear,     // pulse: drop partial macroblock state
	output wire        freeze_output,      // hold the last good frame on screen

	// ── Telemetry ──
	output wire        resync_active,
	output reg [15:0]  desync_count,
	output reg [2:0]   last_desync_reason
);
	localparam [2:0] RSN_NONE        = 3'd0;
	localparam [2:0] RSN_CAVLC       = 3'd1;
	localparam [2:0] RSN_MB_TYPE     = 3'd2;
	localparam [2:0] RSN_MB_OVERRUN  = 3'd3;
	localparam [2:0] RSN_SLICE_SHORT = 3'd4;
	localparam [2:0] RSN_SLICE_LONG  = 3'd5;

	localparam [1:0] S_RUN       = 2'd0;
	localparam [1:0] S_ABORT     = 2'd1;
	localparam [1:0] S_WAIT_IDR  = 2'd2;

	reg [1:0] state;

	// Any one of these means the bit position is no longer trustworthy.  They
	// are ranked only so the telemetry reports the most specific cause when
	// several fire on the same cycle.
	wire any_err = err_cavlc_miss | err_bad_mb_type | err_mb_overrun |
	               err_slice_short | err_slice_long;

	wire [2:0] err_reason =
		err_cavlc_miss   ? RSN_CAVLC       :
		err_bad_mb_type  ? RSN_MB_TYPE     :
		err_mb_overrun   ? RSN_MB_OVERRUN  :
		err_slice_short  ? RSN_SLICE_SHORT :
		                   RSN_SLICE_LONG;

	// Decoding is inhibited from the moment the error is seen until an IDR
	// re-establishes a picture that depends on nothing.
	assign decode_enable  = (state == S_RUN);
	assign resync_active  = (state != S_RUN);
	// The last complete good frame stays on screen for the whole resync.  A
	// partially decoded frame is worse than a stale one.
	assign freeze_output  = (state != S_RUN);

	always @(posedge clk) begin
		if (reset) begin
			state              <= S_RUN;
			dpb_flush          <= 1'b0;
			poc_reset          <= 1'b0;
			mb_state_clear     <= 1'b0;
			desync_count       <= 16'd0;
			last_desync_reason <= RSN_NONE;
		end else begin
			dpb_flush      <= 1'b0;
			poc_reset      <= 1'b0;
			mb_state_clear <= 1'b0;

			case (state)
			S_RUN: begin
				// An IDR always resets the decoder, desync or not: 7.4.3 and
				// 8.2.1 require frame_num and the picture order count to
				// restart and every reference to be marked unused.
				if (slice_start && slice_is_idr) begin
					dpb_flush      <= 1'b1;
					poc_reset      <= 1'b1;
					mb_state_clear <= 1'b1;
				end else if (any_err) begin
					last_desync_reason <= err_reason;
					if (desync_count != 16'hFFFF)
						desync_count <= desync_count + 16'd1;
					// Drop whatever the broken macroblock left behind before
					// anything downstream can commit it.
					mb_state_clear <= 1'b1;
					state          <= S_ABORT;
				end
			end

			// One cycle to let the abort take effect with decode_enable
			// already low, so nothing races the transition into the wait.
			S_ABORT: begin
				state <= S_WAIT_IDR;
			end

			S_WAIT_IDR: begin
				// Resume only on an IDR.  Every P picture between here and
				// there predicts from the reference the desync corrupted, so
				// resuming mid-GOP would decode a picture that is wrong by
				// construction and then feed it forward.
				if (slice_start && slice_is_idr) begin
					dpb_flush      <= 1'b1;
					poc_reset      <= 1'b1;
					mb_state_clear <= 1'b1;
					state          <= S_RUN;
				end
			end

			default: state <= S_RUN;
			endcase

			// A slice that ends while decoding is inhibited is simply
			// discarded; nothing to do but stay in the wait.
			if (slice_end && state == S_ABORT) state <= S_WAIT_IDR;
		end
	end
endmodule

`default_nettype wire
