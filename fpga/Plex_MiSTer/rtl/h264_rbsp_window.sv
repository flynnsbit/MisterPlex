// h264_rbsp_window — serves h264_decode_core's 64-byte random-access RBSP view.
//
// WHY THIS EXISTS
//
// h264_decode_core takes `rbsp_byte[0:63]` plus `rbsp_window_base`, and asks
// for a new view via `rbsp_request_offset`/`rbsp_request_valid`. In
// stream_path.sv that input was tied off:
//
//     assign core_rbsp_byte[core_gi] = 8'd0;   // and rbsp_window_base(16'd0)
//
// so the product decoder was decoding a constant zero bitstream. Wiring the
// decoder's *outputs* into ddr_frame_store (Stage A) does not fix that: the
// pixels would be a function of 64 zero bytes. This module is the supply side
// of that path -- the last hop of ARM -> DDR ring -> ddr_bitstream_reader ->
// nalu_scanner slice capture -> here -> decoder.
//
// STRUCTURE, AND WHY IT IS THIS SHAPE
//
// The view is random-access: the decoder can request any byte offset in the
// slice, so a shift register will not do. A single byte-wide RAM would need 64
// sequential reads per request. Instead the slice RBSP is striped across 64
// byte-lane RAMs, lane = offset[5:0], row = offset[15:6]. Any 64-byte window
// then spans at most two rows, so every lane reads its own RAM once and picks
// row or row+1 depending on whether its lane index is below the base's lane.
// One cycle, 64 parallel reads, no stalls.
//
// The output pair (`window_base`, `byte_out`) is always self-consistent: they
// are registered together, so a consumer can never see new bytes labelled with
// an old base. `window_base` is exported rather than assumed, because the
// decoder indexes with it.
//
// Capture is write-only during `cap_en` and the window is served from the RAM,
// so bytes can be requested while later bytes are still arriving. Requests
// beyond what has been captured return zero and raise `underflow` rather than
// returning stale RAM contents, because a decoder that silently consumed the
// previous slice's bytes would produce plausible-looking wrong pixels -- the
// hardest kind of bug to see on a screen.

`default_nettype none

module h264_rbsp_window #(
	// Bytes of one slice RBSP held for random access. 8 KB covers a 624x480
	// baseline slice at the measured ~7.2 KB per VCL NAL.
	parameter integer BUF_BYTES = 8192
) (
	input  wire        clk,
	input  wire        reset,

	// Slice RBSP capture, byte-serial, from nalu_scanner's slice tap.
	input  wire        cap_clear,   // start of a new slice payload
	input  wire        cap_en,
	input  wire [7:0]  cap_data,
	input  wire        cap_end,     // slice payload complete

	// Random-access view request from h264_decode_core.
	input  wire        request_valid,
	input  wire [15:0] request_offset,

	// The view. byte_out[i] is stream byte (window_base + i).
	output reg  [7:0]  byte_out [0:63],
	output reg  [15:0] window_base,
	output reg         window_valid,

	// Telemetry. bytes_captured is the authoritative "how much of this slice do
	// we actually have", which is what makes underflow detectable at all.
	output reg  [15:0] bytes_captured,
	output reg         slice_complete,
	output reg         overflow,     // slice larger than BUF_BYTES
	output reg         underflow     // window requested past bytes_captured
);

	localparam integer LANES     = 64;
	localparam integer ROWS      = BUF_BYTES / LANES;
	localparam integer ROW_BITS  = $clog2(ROWS);

	// Write pointer over the slice payload.
	reg [15:0] wr_ptr;
	wire [5:0]           wr_lane = wr_ptr[5:0];
	wire [ROW_BITS-1:0]  wr_row  = wr_ptr[ROW_BITS+5:6];
	wire wr_in_range = (wr_ptr < BUF_BYTES[15:0]);
	wire do_write    = cap_en && wr_in_range && !cap_clear;

	// Requested base, and the two rows a 64-byte window can touch. The last
	// request is held in req_base_r rather than re-derived from window_base:
	// window_base lags the request by a cycle, so feeding it back would make an
	// idle cycle re-fetch the *previous* window and undo the one just served.
	reg [15:0] req_base_r;
	wire [15:0]          req_base = request_valid ? request_offset : req_base_r;
	wire [5:0]           req_lane = req_base[5:0];
	wire [ROW_BITS-1:0]  req_row  = req_base[ROW_BITS+5:6];
	wire [ROW_BITS-1:0]  req_row1 = req_row + {{(ROW_BITS-1){1'b0}}, 1'b1};

	// Pipeline copies of the values the lane stage needs, aligned to the
	// registered RAM output.
	reg [5:0]  req_lane_q;
	reg [15:0] window_base_next_q;
	reg [15:0] bytes_captured_q;

	// 64 byte-lane memories. Each lane holds every 64th stream byte, so a
	// window read is one access per lane rather than 64 accesses to one RAM.
	// A lane is fixed to a residue class of the stream offset, NOT to an output
	// position: stream byte (base + i) lives in lane (base + i) mod 64. The
	// output stage below therefore has to rotate.
	wire [7:0] lane_val [0:63];

	genvar li;
	generate
		for (li = 0; li < LANES; li = li + 1) begin : gen_lane
			localparam [15:0] LANE_IDX = li[15:0];
			(* ramstyle = "no_rw_check" *) reg [7:0] lane_mem [0:ROWS-1];
			reg [7:0] rd_row_q;
			reg [7:0] rd_row1_q;

			always @(posedge clk) begin
				if (do_write && wr_lane == li[5:0])
					lane_mem[wr_row] <= cap_data;
				rd_row_q  <= lane_mem[req_row];
				rd_row1_q <= lane_mem[req_row1];
			end

			// Lanes below the base's lane belong to the next row: the window
			// starts mid-row and wraps once.
			// Degenerate at the end lanes (lane 0 never wraps, lane 63 wraps
			// for any non-zero base); that is the correct behaviour, not a
			// mistake, so the constant-comparison warning is silenced here.
			/* verilator lint_off CMPCONST */
`ifdef H264_RBSP_WINDOW_FAULT_NO_WRAP
			wire lane_wraps = 1'b0;  // intentional fault: single-row window
`else
			wire lane_wraps = (LANE_IDX[5:0] < req_lane_q);
`endif
			/* verilator lint_on CMPCONST */

			assign lane_val[li] = lane_wraps ? rd_row1_q : rd_row_q;
		end
	endgenerate

	// Output stage: byte_out[i] is stream byte (window_base + i), so output slot
	// i is fed by lane (req_lane + i) mod 64 -- a barrel rotate of the lane
	// vector by the base's lane. Without it the window would be correct bytes
	// in the wrong order for every unaligned base, which is exactly the kind of
	// fault that still produces a picture and so cannot be spotted by eye.
	genvar oi;
	generate
		for (oi = 0; oi < LANES; oi = oi + 1) begin : gen_out
			localparam [15:0] OUT_IDX = oi[15:0];
			wire [5:0]  src_lane    = req_lane_q + OUT_IDX[5:0];
			wire [15:0] byte_offset = window_base_next_q + OUT_IDX;

			always @(posedge clk) begin
				if (reset) begin
					byte_out[oi] <= 8'd0;
`ifdef H264_RBSP_WINDOW_FAULT_STALE_TAIL
				end else if (1'b0) begin  // intentional fault: serve stale RAM past capture
`else
				end else if (byte_offset >= bytes_captured_q) begin
`endif
					// Never hand back bytes we do not have. Stale RAM contents
					// would decode into plausible wrong pixels.
					byte_out[oi] <= 8'd0;
				end else begin
					byte_out[oi] <= lane_val[src_lane];
				end
			end
		end
	endgenerate

	always @(posedge clk) begin
		if (reset) begin
			wr_ptr             <= 16'd0;
			bytes_captured     <= 16'd0;
			slice_complete     <= 1'b0;
			overflow           <= 1'b0;
			underflow          <= 1'b0;
			req_base_r         <= 16'd0;
			window_base        <= 16'd0;
			window_valid       <= 1'b0;
			req_lane_q         <= 6'd0;
			window_base_next_q <= 16'd0;
			bytes_captured_q   <= 16'd0;
		end else begin
			req_base_r         <= req_base;
			req_lane_q         <= req_lane;
			window_base_next_q <= req_base;
			bytes_captured_q   <= bytes_captured;
			window_base        <= window_base_next_q;
			window_valid       <= (bytes_captured != 16'd0);

			if (cap_clear) begin
				wr_ptr         <= 16'd0;
				bytes_captured <= 16'd0;
				slice_complete <= 1'b0;
				overflow       <= 1'b0;
				underflow      <= 1'b0;
			end else begin
				if (cap_en) begin
					if (wr_in_range) begin
						wr_ptr         <= wr_ptr + 16'd1;
						bytes_captured <= wr_ptr + 16'd1;
					end else begin
						overflow <= 1'b1;
					end
				end
				if (cap_end)
					slice_complete <= 1'b1;
				// Sticky: one underflow is enough to invalidate the picture,
				// and a per-request pulse would be missed by anything sampling
				// at frame rate.
				if (request_valid && (request_offset >= bytes_captured))
					underflow <= 1'b1;
			end
		end
	end

endmodule

`default_nettype wire
