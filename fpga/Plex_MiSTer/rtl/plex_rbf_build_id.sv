// plex_rbf_build_id — fabric stamp binding RBF ↔ git commit (w-fitgate).
//
// Named defect: lab reasoned about current RTL from a months-old bitstream
// (dfebf2bf / G-VID1 @ 0139f2c5) that lacked ddr_frame_store. External
// provenance manifests catch that class post-build; this module puts a
// non-strippable commit prefix + dirty flag INTO the fabric so post-fit
// hierarchy and (optionally) status readback can prove the stamp survived.
//
// Parameters are normally generated into plex_rbf_build_id_params.vh by
// scripts/gen_rbf_build_id_vh.py (git rev-parse). Defaults keep the module
// elaborable when the include is absent.
//
// Quartus must not prune this: outputs are registered with preserve and
// folded into a sticky live bit that the parent top is required to consume.
//
// Does NOT prove functional correctness of decode/present — only that a
// concrete build-id entity exists in the netlist with non-zero MAGIC.

`timescale 1ns / 1ps

module plex_rbf_build_id #(
	// "PLXB" — MisterPlex Build stamp magic (must be non-zero).
	parameter [31:0] MAGIC = 32'h504C5842,
	// First 8 hex chars of git commit as 32-bit value (e.g. 0139f2c5).
	parameter [31:0] COMMIT_PREFIX = 32'h00000000,
	// Worktree dirty at generate time.
	parameter [0:0]  GIT_DIRTY = 1'b1,
	// Active files.qip design-file count at generate time.
	parameter [15:0] QIP_COUNT = 16'd0,
	// Fault inject: force zero stamp (RED twin for sim / expected-fail).
	parameter [0:0]  FAULT_ZERO_STAMP = 1'b0
) (
	input  wire        clk,
	input  wire        reset,
	// Packed stamp: {MAGIC[31:0], COMMIT_PREFIX[31:0]} with dirty in bit0 of lo nibble meta.
	output reg  [63:0] build_id,
	// Sticky 1 after first post-reset sample when MAGIC!=0 and not faulted.
	output reg         id_valid,
	// Single-bit live heart — parent top must consume so fitter cannot prune.
	output wire        stamp_alive
);

	// Meta nibble lives in build_id[3:0] of the low word side-channel:
	//   bit0 = GIT_DIRTY
	//   bit1 = id_valid shadow
	//   bits[15:4] unused in low half; QIP_COUNT sits in build_id[47:32] of high...
	// Layout:
	//   [63:32] MAGIC
	//   [31:16] QIP_COUNT
	//   [15:1]  COMMIT_PREFIX[31:17]  (upper commit bits)
	//   [0]     GIT_DIRTY
	// Full COMMIT_PREFIX also XOR-folded into a keep register so all bits matter.

	wire [63:0] stamp_comb = FAULT_ZERO_STAMP ? 64'd0 : {
		MAGIC,
		QIP_COUNT,
		COMMIT_PREFIX[31:17],
		GIT_DIRTY
	};

	// Fold full commit into a second keep word so low 17 bits are not dropped.
	(* preserve *) reg [31:0] commit_fold_r;
	(* preserve *) reg [63:0] build_id_r;
	(* preserve *) reg        id_valid_r;

	wire stamp_ok = (MAGIC != 32'd0) && !FAULT_ZERO_STAMP;

	always @(posedge clk) begin
		if (reset) begin
			build_id_r    <= 64'd0;
			commit_fold_r <= 32'd0;
			id_valid_r    <= 1'b0;
		end else if (FAULT_ZERO_STAMP) begin
			// RED twin: entire stamp path forced dead (sim / expected-fail).
			build_id_r    <= 64'd0;
			commit_fold_r <= 32'd0;
			id_valid_r    <= 1'b0;
		end else begin
			build_id_r    <= stamp_comb;
			// Mix full prefix so every commit bit toggles flops (anti-strip).
			commit_fold_r <= COMMIT_PREFIX ^ {16'd0, QIP_COUNT} ^ {31'd0, GIT_DIRTY};
			id_valid_r    <= stamp_ok && (stamp_comb[63:32] == MAGIC);
		end
	end

	always @(*) begin
		build_id = build_id_r;
		id_valid = id_valid_r;
	end

	// Live bit: OR of registered stamp + fold — must stay 1 when healthy.
	assign stamp_alive = id_valid_r | (|commit_fold_r) | (|build_id_r[63:32]);

`ifndef SYNTHESIS
	// Sim-only negative: MAGIC=0 must never assert id_valid when not faulted path.
	// (Fault twin uses FAULT_ZERO_STAMP and expects id_valid=0.)
`endif

endmodule
