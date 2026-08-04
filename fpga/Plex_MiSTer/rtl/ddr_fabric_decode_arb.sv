// ddr_fabric_decode_arb.sv — RT multi-client f2sdram arbiter for fabric decode (w-mem).
//
// Clients (parent naming):
//   (c) present / ddr_frame_store  — HARD REALTIME display reads  → m_p  (highest)
//   (b) DPB recon WR + MC RD       — high bandwidth, soft deadline → m_dpb
//   (a) bitstream fetch            — buffered, lowest             → m_bs
//
// Policy: strict priority with bounded preemption (not pure RR).
//   Justify: present underrun tears the glass; DPB/BS can stall a few µs.
//   Low-priority masters may only start a burst ≤ MAX_LOPRI_BURST beats.
//   Once accepted, that burst completes (no mid-beat kill on DDRAM), then
//   present is always next if m_p_cmd. WC present block from RTL:
//     PDEC_PRESENT_WC_DDR_CYC = MAX_LOPRI_BURST + ARB_PIPE  (see plex_decode_ddr_bw.svh)
//
// ENABLE_FABRIC_DECODE=0 (product default): m_dpb/m_bs wants forced off internally.
//   Only present commands the port — same combinational mux path as idle 2-master
//   when grant_lopri=0 (no extra grant FSM cycles on the accepted command).
//
// Additive module: does NOT replace ddr_bus_arbiter.sv / ddr_bus_arbiter3.sv.
// Product wire stays on existing arbiter until parent enables fabric decode.
//
`default_nettype none

module ddr_fabric_decode_arb #(
	parameter bit ENABLE_FABRIC_DECODE = 1'b0,
	parameter int MAX_LOPRI_BURST      = 16
) (
	input  wire        clk,    // clk_ddr 90 MHz
	input  wire        reset,

	// --- (c) present ---
	output wire        m_p_busy,
	input  wire  [7:0] m_p_burstcnt,
	input  wire [28:0] m_p_addr,
	output wire [63:0] m_p_dout,
	output wire        m_p_dout_ready,
	input  wire        m_p_rd,
	input  wire [63:0] m_p_din,
	input  wire  [7:0] m_p_be,
	input  wire        m_p_we,

	// --- (b) DPB ---
	input  wire        m_dpb_want,
	output wire        m_dpb_busy,
	input  wire  [7:0] m_dpb_burstcnt,
	input  wire [28:0] m_dpb_addr,
	output wire [63:0] m_dpb_dout,
	output wire        m_dpb_dout_ready,
	input  wire        m_dpb_rd,
	input  wire [63:0] m_dpb_din,
	input  wire  [7:0] m_dpb_be,
	input  wire        m_dpb_we,

	// --- (a) bitstream ---
	input  wire        m_bs_want,
	output wire        m_bs_busy,
	input  wire  [7:0] m_bs_burstcnt,
	input  wire [28:0] m_bs_addr,
	output wire [63:0] m_bs_dout,
	output wire        m_bs_dout_ready,
	input  wire        m_bs_rd,
	input  wire [63:0] m_bs_din,
	input  wire  [7:0] m_bs_be,
	input  wire        m_bs_we,

	// --- physical DDRAM ---
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,

	// observability (TB / meters)
	output wire  [1:0] grant_oh,       // 0=present default, 1=dpb, 2=bs
	output wire  [7:0] wc_present_block_beats // sticky max observed present wait (beats of lopri)
);

	`include "plex_decode_ddr_bw.svh"

	// synthesis translate_off
	initial begin
		if (MAX_LOPRI_BURST > 255)
			$error("ddr_fabric_decode_arb: MAX_LOPRI_BURST %0d > 255", MAX_LOPRI_BURST);
		if (MAX_LOPRI_BURST < 1)
			$error("ddr_fabric_decode_arb: MAX_LOPRI_BURST must be >= 1");
		// WC bound must fit inside LINE=16 blackout cover (ddr cycles).
		if ((MAX_LOPRI_BURST + PDEC_ARB_PIPE_DDR_CYC) > PDEC_BLACKOUT_DDR_CYC)
			$error("ddr_fabric_decode_arb: present WC %0d > blackout %0d ddr cyc",
				MAX_LOPRI_BURST + PDEC_ARB_PIPE_DDR_CYC, PDEC_BLACKOUT_DDR_CYC);
	end
	// synthesis translate_on

	wire dpb_want_eff = ENABLE_FABRIC_DECODE && m_dpb_want;
	wire bs_want_eff  = ENABLE_FABRIC_DECODE && m_bs_want;

	wire m_p_cmd   = m_p_rd   | m_p_we;
	wire m_dpb_cmd = m_dpb_rd | m_dpb_we;
	wire m_bs_cmd  = m_bs_rd  | m_bs_we;

	// grant: 0 present (default mux), 1 dpb, 2 bs
	reg [1:0] grant_r;
	reg [8:0] rsp_left;
	reg [1:0] rsp_owner;     // who owns outstanding read beats
	reg [63:0] rsp_data_r;
	reg        rsp_valid_r;
	reg [1:0]  rsp_owner_r;
	reg [7:0]  wc_block_r;
	reg [7:0]  present_wait_r;

	wire rsp_active = (rsp_left != 9'd0);
	wire rsp_pipe   = rsp_active | rsp_valid_r;

	wire use_dpb = (grant_r == 2'd1);
	wire use_bs  = (grant_r == 2'd2);
	// present is default when grant_r==0

	function automatic [7:0] clamp_burst;
		input [7:0] b;
		begin
			if (b == 8'd0)
				clamp_burst = 8'd1;
			else if (b > MAX_LOPRI_BURST[7:0])
				clamp_burst = MAX_LOPRI_BURST[7:0];
			else
				clamp_burst = b;
		end
	endfunction

	wire [7:0] dpb_burst_c = clamp_burst(m_dpb_burstcnt);
	wire [7:0] bs_burst_c  = clamp_burst(m_bs_burstcnt);
	wire [7:0] sel_burst =
		use_dpb ? dpb_burst_c :
		use_bs  ? bs_burst_c  : m_p_burstcnt;

	// Present is busy only when DDRAM busy, lopri owns grant, or lopri owns rsp.
	assign m_p_busy = DDRAM_BUSY | (grant_r != 2'd0) |
	                  (rsp_active && (rsp_owner != 2'd0)) |
	                  (rsp_valid_r && (rsp_owner_r != 2'd0));

	assign m_dpb_busy = DDRAM_BUSY | (grant_r != 2'd1) |
	                    (rsp_active && (rsp_owner != 2'd1)) |
	                    (rsp_valid_r && (rsp_owner_r != 2'd1)) |
	                    !ENABLE_FABRIC_DECODE;

	assign m_bs_busy = DDRAM_BUSY | (grant_r != 2'd2) |
	                   (rsp_active && (rsp_owner != 2'd2)) |
	                   (rsp_valid_r && (rsp_owner_r != 2'd2)) |
	                   !ENABLE_FABRIC_DECODE;

	assign DDRAM_BURSTCNT = use_dpb ? dpb_burst_c :
	                        use_bs  ? bs_burst_c  : m_p_burstcnt;
	assign DDRAM_ADDR     = use_dpb ? m_dpb_addr :
	                        use_bs  ? m_bs_addr  : m_p_addr;
	assign DDRAM_RD       = use_dpb ? m_dpb_rd :
	                        use_bs  ? m_bs_rd  : m_p_rd;
	assign DDRAM_DIN      = use_dpb ? m_dpb_din :
	                        use_bs  ? m_bs_din  : m_p_din;
	assign DDRAM_BE       = use_dpb ? m_dpb_be :
	                        use_bs  ? m_bs_be  : m_p_be;
	assign DDRAM_WE       = use_dpb ? m_dpb_we :
	                        use_bs  ? m_bs_we  : m_p_we;

	wire rsp_raw = DDRAM_DOUT_READY & rsp_active;

	assign m_p_dout       = rsp_data_r;
	assign m_p_dout_ready = rsp_valid_r & (rsp_owner_r == 2'd0);
	assign m_dpb_dout       = rsp_data_r;
	assign m_dpb_dout_ready = rsp_valid_r & (rsp_owner_r == 2'd1);
	assign m_bs_dout       = rsp_data_r;
	assign m_bs_dout_ready = rsp_valid_r & (rsp_owner_r == 2'd2);

	assign grant_oh = grant_r;
	assign wc_present_block_beats = wc_block_r;

	// Bound constant exported for TB (parameter path).
	// WC ≤ MAX_LOPRI_BURST beats of lopri ownership while present waits.

	always @(posedge clk) begin
		if (reset) begin
			grant_r <= 2'd0;
			rsp_left <= 9'd0;
			rsp_owner <= 2'd0;
			rsp_data_r <= 64'd0;
			rsp_valid_r <= 1'b0;
			rsp_owner_r <= 2'd0;
			wc_block_r <= 8'd0;
			present_wait_r <= 8'd0;
		end else begin
			rsp_valid_r <= rsp_raw;
			if (rsp_raw) begin
				rsp_data_r  <= DDRAM_DOUT;
				rsp_owner_r <= rsp_owner;
			end
			if (DDRAM_DOUT_READY && rsp_active)
				rsp_left <= rsp_left - 9'd1;

			// Track present wait while blocked by lopri grant/rsp
			if (m_p_cmd && m_p_busy) begin
				if (present_wait_r != 8'hff)
					present_wait_r <= present_wait_r + 8'd1;
				if (present_wait_r + 8'd1 > wc_block_r)
					wc_block_r <= present_wait_r + 8'd1;
			end else if (!m_p_busy) begin
				present_wait_r <= 8'd0;
			end

			if (!DDRAM_BUSY && !rsp_pipe) begin
				if (grant_r == 2'd1) begin
					// DPB owns: accept one cmd then drop grant (bounded burst)
					if (m_dpb_rd) begin
						rsp_owner <= 2'd1;
						rsp_left  <= {1'b0, sel_burst};
						grant_r   <= 2'd0; // free for present next
					end else if (m_dpb_we) begin
						grant_r <= 2'd0;
					end else if (!dpb_want_eff || m_p_cmd) begin
						grant_r <= 2'd0; // present pre-empts idle dpb hold
					end
				end else if (grant_r == 2'd2) begin
					if (m_bs_rd) begin
						rsp_owner <= 2'd2;
						rsp_left  <= {1'b0, sel_burst};
						grant_r   <= 2'd0;
					end else if (m_bs_we) begin
						grant_r <= 2'd0;
					end else if (!bs_want_eff || m_p_cmd) begin
						grant_r <= 2'd0;
					end
				end else begin
					// grant_r==0 present default
					if (m_p_rd) begin
						rsp_owner <= 2'd0;
						rsp_left  <= {1'b0, m_p_burstcnt};
						// stay grant 0
					end else if (m_p_we) begin
						// present write rare; no grant change
					end else if (!m_p_cmd && dpb_want_eff) begin
						grant_r <= 2'd1;
					end else if (!m_p_cmd && bs_want_eff) begin
						grant_r <= 2'd2;
					end
					// CRITICAL: if m_p_cmd, never grant lopri — present wins immediately
				end
			end
		end
	end
endmodule

// ---------------------------------------------------------------------------
// Naive sticky-DPB arbiter (TB NEGATIVE ONLY) — no present priority.
// While m_dpb_want, DPB keeps the bus forever. Present starves past deadline.
// A priority-less design fails G_NEG; product arb must PASS the same stimulus.
// ---------------------------------------------------------------------------
module ddr_fabric_decode_arb_naive_sticky_dpb (
	input  wire        clk,
	input  wire        reset,
	output wire        m_p_busy,
	input  wire  [7:0] m_p_burstcnt,
	input  wire [28:0] m_p_addr,
	output wire [63:0] m_p_dout,
	output wire        m_p_dout_ready,
	input  wire        m_p_rd,
	input  wire [63:0] m_p_din,
	input  wire  [7:0] m_p_be,
	input  wire        m_p_we,
	input  wire        m_dpb_want,
	output wire        m_dpb_busy,
	input  wire  [7:0] m_dpb_burstcnt,
	input  wire [28:0] m_dpb_addr,
	output wire [63:0] m_dpb_dout,
	output wire        m_dpb_dout_ready,
	input  wire        m_dpb_rd,
	input  wire [63:0] m_dpb_din,
	input  wire  [7:0] m_dpb_be,
	input  wire        m_dpb_we,
	input  wire        m_bs_want,
	output wire        m_bs_busy,
	input  wire  [7:0] m_bs_burstcnt,
	input  wire [28:0] m_bs_addr,
	output wire [63:0] m_bs_dout,
	output wire        m_bs_dout_ready,
	input  wire        m_bs_rd,
	input  wire [63:0] m_bs_din,
	input  wire  [7:0] m_bs_be,
	input  wire        m_bs_we,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE
);
	reg grant_dpb;
	reg [8:0] rsp_left;
	reg rsp_owner_dpb;
	reg [63:0] rsp_data_r;
	reg rsp_valid_r;
	reg rsp_owner_dpb_r;

	wire rsp_active = (rsp_left != 9'd0);
	wire rsp_pipe = rsp_active | rsp_valid_r;

	assign m_p_busy = DDRAM_BUSY | grant_dpb |
	                  (rsp_active && rsp_owner_dpb) |
	                  (rsp_valid_r && rsp_owner_dpb_r);
	assign m_dpb_busy = DDRAM_BUSY | !grant_dpb |
	                    (rsp_active && !rsp_owner_dpb) |
	                    (rsp_valid_r && !rsp_owner_dpb_r);
	assign m_bs_busy = 1'b1; // unused in sticky-dpb negative

	assign DDRAM_BURSTCNT = grant_dpb ? m_dpb_burstcnt : m_p_burstcnt;
	assign DDRAM_ADDR     = grant_dpb ? m_dpb_addr     : m_p_addr;
	assign DDRAM_RD       = grant_dpb ? m_dpb_rd       : m_p_rd;
	assign DDRAM_DIN      = grant_dpb ? m_dpb_din      : m_p_din;
	assign DDRAM_BE       = grant_dpb ? m_dpb_be       : m_p_be;
	assign DDRAM_WE       = grant_dpb ? m_dpb_we       : m_p_we;

	assign m_p_dout = rsp_data_r;
	assign m_p_dout_ready = rsp_valid_r && !rsp_owner_dpb_r;
	assign m_dpb_dout = rsp_data_r;
	assign m_dpb_dout_ready = rsp_valid_r && rsp_owner_dpb_r;
	assign m_bs_dout = 64'd0;
	assign m_bs_dout_ready = 1'b0;

	wire rsp_raw = DDRAM_DOUT_READY & rsp_active;
	/* unused ports keep lint quiet */
	wire _u = m_bs_want | m_bs_rd | m_bs_we | (|m_bs_burstcnt) | (|m_bs_addr) | (|m_bs_din) | (|m_bs_be);

	always @(posedge clk) begin
		if (reset) begin
			grant_dpb <= 1'b0;
			rsp_left <= 9'd0;
			rsp_owner_dpb <= 1'b0;
			rsp_data_r <= 64'd0;
			rsp_valid_r <= 1'b0;
			rsp_owner_dpb_r <= 1'b0;
		end else begin
			rsp_valid_r <= rsp_raw;
			if (rsp_raw) begin
				rsp_data_r <= DDRAM_DOUT;
				rsp_owner_dpb_r <= rsp_owner_dpb;
			end
			if (DDRAM_DOUT_READY && rsp_active)
				rsp_left <= rsp_left - 9'd1;

			if (!DDRAM_BUSY && !rsp_pipe) begin
				if (grant_dpb) begin
					if (m_dpb_rd) begin
						rsp_owner_dpb <= 1'b1;
						rsp_left <= {1'b0, m_dpb_burstcnt};
						// STICKY: do not drop grant while want — starves present
						if (!m_dpb_want)
							grant_dpb <= 1'b0;
					end else if (m_dpb_we) begin
						if (!m_dpb_want)
							grant_dpb <= 1'b0;
					end else if (!m_dpb_want) begin
						grant_dpb <= 1'b0;
					end
				end else begin
					// Naive: DPB always preferred over present when want
					if (m_dpb_want)
						grant_dpb <= 1'b1;
					else if (m_p_rd) begin
						rsp_owner_dpb <= 1'b0;
						rsp_left <= {1'b0, m_p_burstcnt};
					end
				end
			end
		end
	end
endmodule

`default_nettype wire
