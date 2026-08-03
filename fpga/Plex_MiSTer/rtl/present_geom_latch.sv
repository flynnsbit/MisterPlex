// present_geom_latch — host-programmable content-window + DDR bank geometry.
//
// Magic: PLXG ("Plex Geometry") 0x504C5847. Not PLXW — that magic is already
// used by the bitstream ring session-low stat (mailbox_abi_spec.hpp).
// Control-page offset: DOORBELL+0x2C0 (after chrome list; PLXC owns +0x130).
// Final ABI header ownership: w-mem; this module is the READ/present consumer
// latch so fabric can leave reset-default (all zero → legacy bit-exact path).
//
// Write model (sim + future DDR poller):
//   Host writes qwords 0..4 then pulses commit. On commit, if q0[31:0]==MAGIC
//   and the (epoch,seq) pair is new, shadow → live outputs. Bad magic → no change.
//
// B4 session/epoch (rd-duck ABA):
//   q0[47:34] = epoch/session_id (14 bits). seq alone is not restart-safe:
//   after FPGA reset last_seq=0, retained DDR q0 seq=N with epoch=0 is an ABA
//   hole if the latch only checks sh_seq != last_seq. Product requires epoch!=0
//   and (epoch,seq) != (last_epoch,last_seq). Host packs epoch via packPlxgQ0.
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
	input  wire [2:0]  wr_idx,   // 0..4
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
	output reg         live_valid,  // 1 after at least one accepted commit
	output reg [15:0]  live_seq,
	output reg [13:0]  live_epoch
);
	// Shadow bank (host fills, commit promotes).
	reg [63:0] sh [0:4];
	reg [15:0] last_seq;
	reg [13:0] last_epoch;

	wire [31:0] sh_magic = sh[0][31:0];
	wire        sh_win   = sh[0][32];
	wire        sh_geom  = sh[0][33];
	// q0[47:34] = epoch/session (14 bits). Zero is illegal on product path.
	wire [13:0] sh_epoch = sh[0][47:34];
	wire [15:0] sh_seq   = sh[0][63:48];
	wire        magic_ok = (sh_magic == MAGIC);
`ifdef PRESENT_GEOM_LATCH_FAULT_NO_EPOCH
	// Red twin: seq-only accept (pre-B4). Reproduces reset ABA on retained seq.
	wire        seq_new  = magic_ok && (sh_seq != last_seq);
`else
	// Product: require nonzero epoch and a new (epoch,seq) pair.
	wire        seq_new  = magic_ok && (sh_epoch != 14'd0) &&
	                       ((sh_epoch != last_epoch) || (sh_seq != last_seq));
`endif

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			for (i = 0; i < 5; i = i + 1)
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
			live_valid    <= 1'b0;
			live_seq      <= 16'd0;
			live_epoch    <= 14'd0;
			last_seq      <= 16'd0;
			last_epoch    <= 14'd0;
		end else begin
			if (wr_en && (wr_idx <= 3'd4))
				sh[wr_idx] <= wr_data;

			if (commit && seq_new) begin
				// Q0 flags
				win_enable  <= sh_win;
				geom_enable <= sh_geom;
				live_seq    <= sh_seq;
				last_seq    <= sh_seq;
				live_epoch  <= sh_epoch;
				last_epoch  <= sh_epoch;
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
			end
		end
	end
endmodule
`default_nettype wire
