// fabric_ddr_attach — credit-aware path → arbiter3 m2.
// Macro FABRIC_DDR_WRITER default OFF.
//
`default_nettype none

module fabric_ddr_attach #(
	parameter int CODED_W = 1280,
	parameter int CODED_H = 720,
	parameter [31:0] PHYS_BASE = 32'h3018_0000,
	parameter int HPS_BANK_STRIDE_BYTES = 32'h0018_0000,
	parameter [31:0] DOORBELL_PHYS = 32'h3047_F000,
	parameter int WRITE_DRAIN_CYCLES = 16,
	parameter bit USE_INTERNAL_PATTERN = 1'b1
)(
	input  wire        clk,
	input  wire        reset,

	// Continuous produce enable (level). Claim/commit gated by credit.
	input  wire        produce_en,
	// Vsync swap pulse (clk domain)
	input  wire        vsync_swap,

	input  wire        ext_valid,
	output wire        ext_ready,
	input  wire [63:0] ext_data,
	input  wire        ext_frame_start,
	input  wire [1:0]  ext_bank_id,

	output wire        m2_want,
	input  wire        m2_busy,
	output wire  [7:0] m2_burstcnt,
	output wire [28:0] m2_addr,
	input  wire [63:0] m2_dout,
	input  wire        m2_dout_ready,
	output wire        m2_rd,
	output wire [63:0] m2_din,
	output wire  [7:0] m2_be,
	output wire        m2_we,

	output wire        busy,
	output wire        frame_done,
	output wire [28:0] dbg_seq,
	output wire [1:0]  dbg_last_bank,
	// PLXD-compatible credit status (for host / hierarchy keep)
	output wire  [1:0] free_mask,
	output wire        disp_bank,
	output wire        swap_pending,
	output wire [15:0] frames_done,
	output wire [7:0]  frame_phase
);
	wire        claim_ack;
	wire [1:0]  claim_bank;
	reg         claim_req;
	reg         start_r;
	reg  [1:0]  bank_r;
	reg  [2:0]  st;
	localparam [2:0] ST_IDLE=0, ST_CLAIM=1, ST_RUN=2, ST_WAIT_DONE=3;

	wire path_busy, path_done;
	wire [7:0] phase_out;

	fabric_bank_credit credit (
		.clk(clk),
		.reset(reset),
		.vsync_swap(vsync_swap),
		.claim_req(claim_req),
		.claim_ack(claim_ack),
		.claim_bank(claim_bank),
		.commit_pulse(path_done),
		.commit_bank(bank_r),
		.free_mask(free_mask),
		.disp_bank(disp_bank),
		.swap_pending(swap_pending),
		.pending_bank(),
		.frames_done(frames_done),
		.next_free_bank(),
		.any_free()
	);

	always @(posedge clk) begin
		if (reset) begin
			st        <= ST_IDLE;
			claim_req <= 1'b0;
			start_r   <= 1'b0;
			bank_r    <= 2'd0;
		end else begin
			claim_req <= 1'b0;
			start_r   <= 1'b0;
			case (st)
			ST_IDLE: begin
				if (produce_en && !path_busy)
					st <= ST_CLAIM;
			end
			ST_CLAIM: begin
				if (!produce_en)
					st <= ST_IDLE;
				else begin
					claim_req <= 1'b1;
					if (claim_ack) begin
						bank_r  <= claim_bank;
						start_r <= 1'b1;
						st      <= ST_RUN;
					end
				end
			end
			ST_RUN: begin
				// start is one-cycle; wait path busy then done
				if (path_busy)
					st <= ST_WAIT_DONE;
				else if (!start_r)
					st <= ST_CLAIM; // retry if start missed
			end
			ST_WAIT_DONE: begin
				if (path_done)
					st <= ST_IDLE;
			end
			default: st <= ST_IDLE;
			endcase
		end
	end

	fabric_ddr_write_path #(
		.CODED_W(CODED_W),
		.CODED_H(CODED_H),
		.PHYS_BASE(PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES(HPS_BANK_STRIDE_BYTES),
		.DOORBELL_PHYS(DOORBELL_PHYS),
		.WRITE_DRAIN_CYCLES(WRITE_DRAIN_CYCLES),
		.USE_INTERNAL_PATTERN(USE_INTERNAL_PATTERN)
	) path (
		.clk(clk),
		.reset(reset),
		.start(start_r),
		.bank_id(bank_r),
		.frame_phase_in(8'd0),
		.use_ext_phase(1'b0),
		.ext_valid(ext_valid),
		.ext_ready(ext_ready),
		.ext_data(ext_data),
		.ext_frame_start(ext_frame_start),
		.ext_bank_id(ext_bank_id),
		.DDRAM_CLK(),
		.DDRAM_BUSY(m2_busy),
		.DDRAM_BURSTCNT(m2_burstcnt),
		.DDRAM_ADDR(m2_addr),
		.DDRAM_DOUT(m2_dout),
		.DDRAM_DOUT_READY(m2_dout_ready),
		.DDRAM_RD(m2_rd),
		.DDRAM_DIN(m2_din),
		.DDRAM_BE(m2_be),
		.DDRAM_WE(m2_we),
		.busy(path_busy),
		.frame_done(path_done),
		.dbg_seq(dbg_seq),
		.dbg_last_bank(dbg_last_bank),
		.frame_phase_out(phase_out)
	);

	assign busy       = path_busy | (st != ST_IDLE);
	assign frame_done = path_done;
	assign m2_want    = path_busy | (st == ST_RUN) | (st == ST_WAIT_DONE);
	assign frame_phase = phase_out;

	// Hierarchy keep: credit + phase must survive fit when enabled
	(* keep = 1 *) wire _keep_attach =
		|free_mask | disp_bank | swap_pending | |frames_done | |phase_out | busy;

endmodule

`default_nettype wire
