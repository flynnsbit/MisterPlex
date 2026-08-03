// present_geom_latch — host-programmable content-window + DDR bank geometry.
//
// Magic: PLXG ("Plex Geometry") 0x504C5847. Not PLXW — that magic is already
// used by the bitstream ring session-low stat (mailbox_abi_spec.hpp).
// Control-page offset: DOORBELL+0x800 (ABI FREEZE). Never +0x130 (PLXC).
// Final ABI header ownership: w-mem; this module is the READ/present consumer
// latch so fabric can leave reset-default (all zero → legacy bit-exact path).
//
// Write model (sim + future DDR poller):
//   Host writes qwords 0..4 then pulses commit. On commit, if q0[31:0]==MAGIC
//   and seq != last_seq, shadow → live outputs. Bad magic → no change.
//
// Parent ABI arbitration #2 — PLXG record q0..q5 @ doorbell+0x800..0x82F:
//   q5 @ +0x828 (wr_idx==5), little-endian, same commit as q0..q4:
//     [11:0]  dar_x        display aspect numerator  (0 = unspecified)
//     [23:12] dar_y        display aspect denominator (0 = unspecified)
//     [31:24] content_fps  integer fps               (0 = unspecified)
//     [32]    dar_valid
//     [33]    fps_valid
//     [63:34] RESERVED — must be zero; non-zero → reject whole promotion
//   Fabric must NOT infer DAR from coded_w/h (720×480 anamorphic is unsound).
//   Frame-boundary atomicity (B16) is w-mem; this latch still promotes on commit
//   pulse (poller/TB). Reserved reject is the forward-compat loud fail.
//
// Reset / never-committed: every enable and dimension output is 0 so
// present_content_window + ddr_frame_store stay on synthesis legacy path.
`default_nettype none

module present_geom_latch #(
	parameter [31:0] MAGIC = 32'h504C_5847 // "PLXG"
)(
	input  wire        clk,
	input  wire        reset,

	// Host write port (ARM via DDR image or TB).
	input  wire        wr_en,
	input  wire [2:0]  wr_idx,   // 0..5 (5 = optional DAR qword)
	input  wire [63:0] wr_data,
	input  wire        commit,   // pulse: attempt to promote shadow → live

	// Live outputs (stable until next accepted commit).
	output reg         win_enable,
	output reg         geom_enable,
	output reg [10:0]  content_w,
	output reg [10:0]  content_h,
	output reg [10:0]  content_x0,
	output reg [10:0]  content_y0,
	output reg [10:0]  h_de,
	output reg [10:0]  v_de,
	output reg [10:0]  coded_w,
	output reg [10:0]  coded_h,
	output reg [11:0]  y_stride,
	output reg [10:0]  chroma_stride,
	output reg [10:0]  display_w,
	output reg [10:0]  display_h,
	output reg [10:0]  present_x,
	output reg [10:0]  present_y,
	output reg [10:0]  crop_left,
	output reg [10:0]  crop_top,
	// q5 host DAR + cadence (PMS) — see module header / parent arbitration #2.
	output reg         dar_valid,
	output reg [11:0]  dar_x,
	output reg [11:0]  dar_y,
	output reg         fps_valid,
	output reg [7:0]   content_fps,
	output reg         live_valid,  // 1 after at least one accepted commit
	output reg [15:0]  live_seq
);
	// Shadow bank (host fills, commit promotes). q[5] = DAR+fps qword.
	reg [63:0] sh [0:5];
	reg [15:0] last_seq;

	wire [31:0] sh_magic = sh[0][31:0];
	wire        sh_win   = sh[0][32];
	wire        sh_geom  = sh[0][33];
	wire [15:0] sh_seq   = sh[0][63:48];
	wire        magic_ok = (sh_magic == MAGIC);
	wire        seq_new  = magic_ok && (sh_seq != last_seq);
	// [63:34] reserved — 30 bits must be zero or promotion is rejected.
	wire        q5_rsvd_ok = (sh[5][63:34] == 30'd0);
	wire        promote_ok = seq_new && q5_rsvd_ok;

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			for (i = 0; i < 6; i = i + 1)
				sh[i] <= 64'd0;
			win_enable    <= 1'b0;
			geom_enable   <= 1'b0;
			content_w     <= 11'd0;
			content_h     <= 11'd0;
			content_x0    <= 11'd0;
			content_y0    <= 11'd0;
			h_de          <= 11'd0;
			v_de          <= 11'd0;
			coded_w       <= 11'd0;
			coded_h       <= 11'd0;
			y_stride      <= 12'd0;
			chroma_stride <= 11'd0;
			display_w     <= 11'd0;
			display_h     <= 11'd0;
			present_x     <= 11'd0;
			present_y     <= 11'd0;
			crop_left     <= 11'd0;
			crop_top      <= 11'd0;
			dar_valid     <= 1'b0;
			dar_x         <= 12'd0;
			dar_y         <= 12'd0;
			fps_valid     <= 1'b0;
			content_fps   <= 8'd0;
			live_valid    <= 1'b0;
			live_seq      <= 16'd0;
			last_seq      <= 16'd0;
		end else begin
			if (wr_en && (wr_idx <= 3'd5))
				sh[wr_idx] <= wr_data;

			// Reject non-zero q5 reserved: no live update, seq not advanced (retryable).
			if (commit && promote_ok) begin
				// Q0 flags
				win_enable  <= sh_win;
				geom_enable <= sh_geom;
				live_seq    <= sh_seq;
				last_seq    <= sh_seq;
				live_valid  <= 1'b1;
				// Q1 content window
				content_w  <= sh[1][10:0];
				content_h  <= sh[1][26:16];
				content_x0 <= sh[1][42:32];
				content_y0 <= sh[1][58:48];
				// Q2 DE + coded
				h_de    <= sh[2][10:0];
				v_de    <= sh[2][26:16];
				coded_w <= sh[2][42:32];
				coded_h <= sh[2][58:48];
				// Q3 strides + display
				y_stride      <= sh[3][11:0];
				chroma_stride <= sh[3][26:16];
				display_w     <= sh[3][42:32];
				display_h     <= sh[3][58:48];
				// Q4 present + crop
				present_x <= sh[4][10:0];
				present_y <= sh[4][26:16];
				crop_left <= sh[4][42:32];
				crop_top  <= sh[4][58:48];
				// Q5 DAR + fps (parent arbitration #2 bit layout)
				dar_x       <= sh[5][11:0];
				dar_y       <= sh[5][23:12];
				content_fps <= sh[5][31:24];
				dar_valid   <= sh[5][32];
				fps_valid   <= sh[5][33];
			end
		end
	end
endmodule

`default_nettype wire
