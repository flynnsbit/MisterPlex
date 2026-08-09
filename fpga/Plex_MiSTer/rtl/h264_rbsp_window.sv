// Slice RBSP byte store with a sliding read window.
//
// CONTRACT (dual-port M10K + multi-beat registered fill — ALM-safe):
//
//   * Write: append-only wr_clear / wr_en / wr_end. Overflow sticky if full.
//   * Read: req_valid captures req_offset and fills window[0:WINDOW_BYTES-1]
//     using one synchronous read port (WORD_BYTES per beat).
//   * LATENCY: about 2*FILL_BEATS cycles (WINDOW=64, WORD=8 → ~16 cycles).
//   * window_valid stays high until the next req_valid (or reset/clear).
//     Consumers gate on: window_valid && (window_base == requested_offset).
//
// overnight3 map: combo bank+rotate design → ~63704 ALMs in this module.
// One DP M10K + sequential fill avoids multi-port replication and combo muxes.

`default_nettype none

module h264_rbsp_window #(
	parameter int DEPTH_BYTES  = 4096,
	parameter int WINDOW_BYTES = 64,
	parameter int WORD_BYTES   = 8
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        wr_clear,
	input  wire        wr_en,
	input  wire [7:0]  wr_data,
	input  wire        wr_end,

	input  wire        req_valid,
	input  wire [15:0] req_offset,

	output reg  [7:0]  window [0:WINDOW_BYTES-1],
	output reg  [15:0] window_base,
	output wire [15:0] window_avail,
	output wire [15:0] length,
	output wire        complete,
	output wire        overflow,
	output reg         window_valid
);
	localparam int WORDS       = (DEPTH_BYTES + WORD_BYTES - 1) / WORD_BYTES;
	localparam int WORD_ADDR_W = (WORDS <= 1) ? 1 : $clog2(WORDS);
	// +1 beat needed when base is unaligned (tail spills into next word)
	localparam int FILL_BEATS  = (WINDOW_BYTES / WORD_BYTES) + 1;
	localparam int BEAT_W      = (FILL_BEATS <= 1) ? 1 : $clog2(FILL_BEATS);
	localparam int LANE_W      = (WORD_BYTES <= 1) ? 1 : $clog2(WORD_BYTES);
	localparam int BYTE_ADDR_W = (DEPTH_BYTES <= 1) ? 1 : $clog2(DEPTH_BYTES);
	localparam [15:0] DEPTH_W  = 16'(DEPTH_BYTES);

	(* ramstyle = "M10K,no_rw_check" *)
	reg [WORD_BYTES*8-1:0] mem [0:WORDS-1];

	reg [15:0]             len_r;
	reg                    complete_r;
	reg                    overflow_r;
	reg [WORD_BYTES*8-1:0] wr_pack_r;
	reg [LANE_W-1:0]       wr_lane_r;
	reg [WORD_ADDR_W-1:0]  wr_word_r;

	wire wr_fits = (len_r < DEPTH_W);
	wire wr_take = wr_en && wr_fits;
	wire wr_last_lane = (wr_lane_r == LANE_W'(WORD_BYTES - 1));

	reg [WORD_BYTES*8-1:0] wr_pack_next;
	integer pi;
	always @(*) begin
		wr_pack_next = wr_pack_r;
		for (pi = 0; pi < WORD_BYTES; pi = pi + 1) begin
			if (wr_take && (wr_lane_r == LANE_W'(pi)))
				wr_pack_next[pi*8 +: 8] = wr_data;
		end
	end

	always @(posedge clk) begin
		if (reset) begin
			len_r      <= 16'd0;
			complete_r <= 1'b0;
			overflow_r <= 1'b0;
			wr_pack_r  <= '0;
			wr_lane_r  <= '0;
			wr_word_r  <= '0;
		end else if (wr_clear) begin
			len_r      <= 16'd0;
			complete_r <= 1'b0;
			overflow_r <= 1'b0;
			wr_pack_r  <= '0;
			wr_lane_r  <= '0;
			wr_word_r  <= '0;
		end else begin
			if (wr_take) begin
				len_r <= len_r + 16'd1;
				if (wr_last_lane) begin
					mem[wr_word_r] <= wr_pack_next;
					wr_pack_r <= '0;
					wr_lane_r <= '0;
					wr_word_r <= wr_word_r + 1'b1;
				end else begin
					wr_pack_r <= wr_pack_next;
					wr_lane_r <= wr_lane_r + 1'b1;
					if (wr_end) begin
						mem[wr_word_r] <= wr_pack_next;
						wr_pack_r <= '0;
						wr_lane_r <= '0;
					end
				end
			end else if (wr_en) begin
				overflow_r <= 1'b1;
			end else if (wr_end && (wr_lane_r != '0)) begin
				mem[wr_word_r] <= wr_pack_r;
				wr_pack_r <= '0;
				wr_lane_r <= '0;
			end

			if (wr_end)
				complete_r <= 1'b1;
		end
	end

	// Fill FSM: beat loop with registered M10K read.
	// Phase 0: drive address. Phase 1: capture word + scatter into window.
	// Unaligned base: lane_offset = fill_base_r[LANE_W-1:0]; window[k] gets
	// the byte at absolute address (fill_base_r + k).  For beat b, byte bj of
	// the word maps to win_idx = b*WORD_BYTES + bj - lane_offset.
	reg                    fill_active_r;
	reg                    fill_phase_r; // 0=addr, 1=capt
	reg [15:0]             fill_base_r;
	reg [LANE_W-1:0]       fill_lane_off_r; // fill_base_r[LANE_W-1:0]
	reg [BEAT_W-1:0]       beat_r;
	reg [WORD_ADDR_W-1:0]  rd_addr_r;
	reg [WORD_BYTES*8-1:0] rd_data_r;

	wire [15:0] req_base_clamped =
		(req_offset >= DEPTH_W) ? (DEPTH_W - 16'(WINDOW_BYTES)) : req_offset;

	integer bi, bj;
	always @(posedge clk) begin
		if (reset || wr_clear) begin
			fill_active_r  <= 1'b0;
			fill_phase_r   <= 1'b0;
			fill_base_r    <= 16'd0;
			fill_lane_off_r <= '0;
			beat_r         <= '0;
			rd_addr_r      <= '0;
			rd_data_r      <= '0;
			window_valid   <= 1'b0;
			window_base    <= 16'd0;
			for (bi = 0; bi < WINDOW_BYTES; bi = bi + 1)
				window[bi] <= 8'd0;
		end else if (req_valid) begin
			fill_active_r  <= 1'b1;
			fill_phase_r   <= 1'b0;
			fill_base_r    <= req_base_clamped;
			fill_lane_off_r <= req_base_clamped[LANE_W-1:0];
			beat_r         <= '0;
			rd_addr_r      <= req_base_clamped[BYTE_ADDR_W-1:LANE_W];
			window_valid   <= 1'b0;
		end else if (fill_active_r) begin
			if (!fill_phase_r) begin
				// Address held on rd_addr_r this cycle; next cycle captures data.
				fill_phase_r <= 1'b1;
			end else begin
				// Scatter captured word into window with lane-offset correction.
				// win_idx = beat_r * WORD_BYTES + bj - fill_lane_off_r
				for (bj = 0; bj < WORD_BYTES; bj = bj + 1) begin : scatter
					// Use 16-bit signed arithmetic to detect negative/overflow
					reg signed [16:0] win_idx_s;
					reg [15:0] abs_byte;
					win_idx_s = 17'(16'(beat_r) * 16'(WORD_BYTES))
					          + 17'(16'(bj)) - 17'({12'd0, fill_lane_off_r});
					abs_byte = fill_base_r + win_idx_s[15:0];
					if (win_idx_s >= 0 && win_idx_s < 17'(WINDOW_BYTES)) begin
						if (abs_byte < len_r)
							window[win_idx_s[15:0]] <= mem[rd_addr_r][bj*8 +: 8];
						else
							window[win_idx_s[15:0]] <= 8'd0;
					end
				end

				// Check if we've filled all WINDOW_BYTES.
				// Last valid win_idx of this beat:
				//   (beat_r+1)*WORD_BYTES - 1 - fill_lane_off_r
				// Done when that >= WINDOW_BYTES-1, i.e.:
				//   (beat_r+1)*WORD_BYTES - fill_lane_off_r >= WINDOW_BYTES
				if (((16'(beat_r) + 16'd1) * 16'(WORD_BYTES) - {12'd0, fill_lane_off_r})
				     >= 16'(WINDOW_BYTES)) begin
					fill_active_r <= 1'b0;
					fill_phase_r  <= 1'b0;
					beat_r        <= '0;
					window_valid  <= 1'b1;
					window_base   <= fill_base_r;
				end else begin
					beat_r       <= beat_r + 1'b1;
					rd_addr_r    <= rd_addr_r + 1'b1;
					fill_phase_r <= 1'b0;
				end
			end
		end
	end

	assign window_avail = (len_r > window_base) ? (len_r - window_base) : 16'd0;
	assign length       = len_r;
	assign complete     = complete_r;
	assign overflow     = overflow_r;
endmodule

`default_nettype wire
