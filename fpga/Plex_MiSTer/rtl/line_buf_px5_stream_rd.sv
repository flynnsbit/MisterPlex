// line_buf_px5_stream_rd — L→R byte stream from packed 40-bit line RAM.
//
// Adjacent-word cache = 16-byte queue (not a second M10K port). PPC=2 groups
// straddle packed words every 5 groups: pixels [4,5] sit in word0[4] + word1[0].
// Queue holds both sides after two captures so a single SDP read port keeps the
// 256×40 = 1 M10K/line saving. No combinational /5 or %5 — only a fill counter
// on the pack side and a byte pop count here.
//
// start: left-edge pulse (see ddr_frame_store; HBlank clamps x to LAST so
//        !rd_x_visible never fires when PRESENT_X=0).
// advance: consume PPC bytes/cycle when queue depth allows.
//
// Registered SDP RAM: rd_data lags rd_addr by 1 cycle; peer always-block sample
// needs one more → issue uses waitcnt=2 before capture.
// One fetch in flight; steady PPC=2 needs 2 B/cyc, supply is 5 B / 2 cyc = 2.5.
// Mid-line random src_x / scaler jumps: NOT supported (would need dual-word
// window + phase or 2× M10K). M10K: 0. ALM EST ~80.

module line_buf_px5_stream_rd #(
	parameter int PPC    = 2,
	parameter int AW     = 8,
	parameter int PIXELS = 1280
)(
	input  wire             clk,
	input  wire             reset,
	input  wire             start,
	input  wire             advance,
	output reg  [AW-1:0]    rd_addr,
	input  wire [39:0]      rd_data,
	output reg              px_valid,
	output reg  [8*PPC-1:0] px_bytes,
	output wire             primed
);
	localparam int NWORDS = PIXELS / 5;

	reg [7:0] q [0:15];
	reg [4:0] qn;
	reg [AW-1:0] wrd_next;
	reg [1:0] waitcnt; // 0=idle, 2=just issued, 1=capture this cycle
	reg active;
	integer i;

	reg [7:0] wq [0:15];
	reg [4:0] wqn;
	reg [AW-1:0] wwrd;
	reg [1:0] wwc;

	assign primed = active && (qn >= 5'(PPC));

	always @(posedge clk) begin
		if (reset) begin
			rd_addr <= '0;
			px_valid <= 1'b0;
			px_bytes <= '0;
			qn <= 5'd0;
			wrd_next <= '0;
			waitcnt <= 2'd0;
			active <= 1'b0;
			for (i = 0; i < 16; i = i + 1)
				q[i] <= 8'd0;
		end else begin
			px_valid <= 1'b0;

			for (i = 0; i < 16; i = i + 1)
				wq[i] = q[i];
			wqn = qn;
			wwrd = wrd_next;
			wwc = waitcnt;

			if (start) begin
				active <= 1'b1;
				for (i = 0; i < 16; i = i + 1)
					wq[i] = 8'd0;
				wqn = 5'd0;
				rd_addr <= '0;
				wwrd = AW'(1);
				wwc = 2'd2; // capture mem[0] in 2 cycles
			end else if (active) begin
				if (wwc == 2'd1) begin
					// rd_data holds mem[addr] issued 2 cycles ago
					wq[wqn + 0] = rd_data[7:0];
					wq[wqn + 1] = rd_data[15:8];
					wq[wqn + 2] = rd_data[23:16];
					wq[wqn + 3] = rd_data[31:24];
					wq[wqn + 4] = rd_data[39:32];
					wqn = wqn + 5'd5;
					wwc = 2'd0;
				end else if (wwc == 2'd2) begin
					wwc = 2'd1;
				end

				if (advance && (wqn >= 5'(PPC))) begin
					for (i = 0; i < PPC; i = i + 1)
						px_bytes[i*8 +: 8] <= wq[i];
					px_valid <= 1'b1;
					for (i = 0; i < 16 - PPC; i = i + 1)
						wq[i] = wq[i + PPC];
					wqn = wqn - 5'(PPC);
				end

				// Prefetch while depth low — keeps word N+1 in flight so the
				// [4,5] straddle group never waits a full RAM turnaround.
				if (wwc == 2'd0 && (wqn < 5'd10) && (int'(wwrd) < NWORDS)) begin
					rd_addr <= wwrd;
					wwrd = wwrd + 1'b1;
					wwc = 2'd2;
				end
			end

			for (i = 0; i < 16; i = i + 1)
				q[i] <= wq[i];
			qn <= wqn;
			wrd_next <= wwrd;
			waitcnt <= wwc;
		end
	end
endmodule
