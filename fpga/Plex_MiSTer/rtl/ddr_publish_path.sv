// ddr_publish_path — composed fabric publication (w-mem priority line).
//
// Binds w-path ddr_i420_bank_geom / ddr_publish_job bank ABI to
// ddr_publish_engine (DIRECT doorbell or COPY mem2mem). Intended m2 master
// under ddr_bus_arbiter3; present_want must be driven from m0_cmd (or store
// refill want) so NEW issues yield during scanout.
//
// Cost (source control, not post-fit):
//   M10K = 0  (engine bounce ramstyle=logic; geom/job are wires)
//   ALM  ≈ 250–450 ESTIMATE — UNKNOWN until entity row after product wire
// Against post-strip budget 356 M10K / 27_556 ALM (parent HIT M10K=197).
//
// Not in files.qip. Product enable is a parent decision after device BW.

`default_nettype none

module ddr_publish_path #(
	parameter int CODED_W = 624,
	parameter int CODED_H = 480,
	parameter [31:0] PHYS_BASE = 32'h3000_0000,
	parameter int BANK_STRIDE_BYTES = 32'h0008_0000,
	parameter [31:0] DOORBELL_PHYS = 32'h0,
	parameter int MAX_BURST = 16,
	parameter int ADDR_W = 29
)(
	input  wire              clk,
	input  wire              reset,

	// Host/firmware kick (clk_ddr domain)
	input  wire              start,
	input  wire              cmd_mode,       // 0 DIRECT  1 COPY
	input  wire              bank_sel,       // destination bank 0/1
	input  wire [31:0]       src_phys,       // staging / decode out (COPY)
	input  wire              ring_doorbell,
	input  wire [63:0]       doorbell_word,
	// Optional override length; 0 → geom frame_bytes
	input  wire [31:0]       bytes_override,

	output wire              busy,
	output wire              done_pulse,
	output wire              err,
	output wire              job_legal,
	output wire              src_aligned,
	output wire [31:0]       frame_bytes,
	output wire [31:0]       dst_bank_phys,
	output wire [31:0]       doorbell_phys_o,
	output wire [31:0]       bytes_copied,
	output wire [15:0]       beats_rd,
	output wire [15:0]       beats_wr,

	// Present-side fence (drive from m0_cmd | store refill want)
	input  wire              present_want,

	// f2sdram master (arbiter m2)
	output wire              bus_want,
	input  wire              DDRAM_BUSY,
	output wire [7:0]        DDRAM_BURSTCNT,
	output wire [ADDR_W-1:0] DDRAM_ADDR,
	input  wire [63:0]       DDRAM_DOUT,
	input  wire              DDRAM_DOUT_READY,
	output wire              DDRAM_RD,
	output wire [63:0]       DDRAM_DIN,
	output wire [7:0]        DDRAM_BE,
	output wire              DDRAM_WE
);
	wire [31:0] job_dst, job_fb, job_db;
	wire        job_ok, src_ok;

	ddr_publish_job #(
		.CODED_W(CODED_W),
		.CODED_H(CODED_H),
		.PHYS_BASE(PHYS_BASE),
		.BANK_STRIDE_BYTES(BANK_STRIDE_BYTES),
		.DOORBELL_PHYS(DOORBELL_PHYS)
	) u_job (
		.bank_sel(bank_sel),
		.src_phys(src_phys),
		.dst_bank_phys(job_dst),
		.frame_bytes(job_fb),
		.doorbell_phys(job_db),
		.job_legal(job_ok),
		.src_aligned(src_ok)
	);

	assign job_legal       = job_ok;
	assign src_aligned     = src_ok;
	assign frame_bytes     = job_fb;
	assign dst_bank_phys   = job_dst;
	assign doorbell_phys_o = job_db;

	wire [31:0] bytes_eff =
		(bytes_override != 32'd0) ? bytes_override : job_fb;

	// Rising edge on start → eng_start, or one-cycle illegal pulse (no latch).
	reg        start_q;
	reg        eng_start;
	reg        illegal_pulse;
	wire       eng_busy, eng_done, eng_err;
	wire [31:0] eng_bytes;
	wire [15:0] eng_brd, eng_bwr;

	wire kick = start && !start_q;
	wire kick_bad = kick && (!job_ok || (cmd_mode && !src_ok));
	wire kick_ok  = kick && !kick_bad;

	always @(posedge clk) begin
		if (reset) begin
			start_q <= 1'b0;
			eng_start <= 1'b0;
			illegal_pulse <= 1'b0;
		end else begin
			start_q <= start;
			eng_start <= kick_ok;
			illegal_pulse <= kick_bad;
		end
	end

	ddr_publish_engine #(
		.MAX_BURST(MAX_BURST),
		.ADDR_W(ADDR_W)
	) u_eng (
		.clk(clk),
		.reset(reset),
		.cmd_start(eng_start),
		.cmd_mode(cmd_mode),
		.cmd_src_phys(src_phys),
		.cmd_dst_phys(job_dst),
		.cmd_bytes(bytes_eff),
		.cmd_doorbell_phys(job_db),
		.cmd_ring_doorbell(ring_doorbell),
		.cmd_doorbell_word(doorbell_word),
		.busy(eng_busy),
		.done_pulse(eng_done),
		.err(eng_err),
		.bytes_copied(eng_bytes),
		.beats_rd(eng_brd),
		.beats_wr(eng_bwr),
		.present_want(present_want),
		.bus_want(bus_want),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE)
	);

	assign busy       = eng_busy;
	assign done_pulse = eng_done | illegal_pulse;
	assign err        = eng_err | illegal_pulse;
	assign bytes_copied = eng_bytes;
	assign beats_rd   = eng_brd;
	assign beats_wr   = eng_bwr;
endmodule

`default_nettype wire
