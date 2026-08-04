#!/usr/bin/env bash
# w-clock: multi-consumer BW contract include + fail-closed drift mutation.
# rd-duck NACK: global `ifndef on module-local localparams → second consumer undefined.
# Control:
#   GREEN — two modules each `include plex_720p_bw_contract.svh; lint-only OK
#   RED   — mutated BPS ≠ 33177600 elaborates missing-module gate → must FAIL
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
WORK="$ROOT/.agent-work/w-clock/p720-contract-mc"
VLT=("$ROOT/scripts/run_verilator.sh")
rm -rf "$WORK"
mkdir -p "$WORK/green" "$WORK/red"

INC=(-y "$RTL" -I"$RTL")

# --- GREEN multi-consumer (two modules, same include, no global guard) ---
cat >"$WORK/green/mc_a.sv" <<'SV'
module mc_a (
	output wire [31:0] bps,
	output wire [31:0] i420
);
`include "plex_720p_bw_contract.svh"
	assign bps  = P720_FABRIC_RD_BPS[31:0];
	assign i420 = P720_I420_BYTES[31:0];
	generate
		if (P720_FABRIC_RD_BPS != 33_177_600)
			p720_bw_contract_rd_bps_must_be_33177600 u_gate();
	endgenerate
endmodule
SV
cat >"$WORK/green/mc_b.sv" <<'SV'
module mc_b (
	output wire [31:0] bps,
	output wire [17:0] beats
);
`include "plex_720p_bw_contract.svh"
	assign bps   = P720_FABRIC_RD_BPS[31:0];
	assign beats = P720_BEATS_PER_FRAME[17:0];
	// Second consumer must see MISTERPLEX_* via nested include too.
	wire [31:0] _m = MISTERPLEX_BW_DIR_B_PER_S[31:0];
	generate
		if (P720_BEATS_PER_FRAME != 172_800)
			p720_bw_contract_beats_must_be_172800 u_beats();
		if (MISTERPLEX_BW_DIR_B_PER_S != 33_177_600)
			p720_bw_contract_rd_bps_must_be_33177600 u_m();
	endgenerate
endmodule
SV
cat >"$WORK/green/mc_top.sv" <<'SV'
module mc_top (
	output wire [31:0] a_bps,
	output wire [31:0] b_bps
);
	mc_a u_a(.bps(a_bps), .i420());
	mc_b u_b(.bps(b_bps), .beats());
endmodule
SV

echo "GREEN multi-consumer verilator lint..."
if ! "${VLT[@]}" --lint-only -Wall -Wno-DECLFILENAME -Wno-fatal \
	"${INC[@]}" \
	"$WORK/green/mc_a.sv" "$WORK/green/mc_b.sv" "$WORK/green/mc_top.sv" \
	--top-module mc_top >"$WORK/green/log.txt" 2>&1; then
	echo "FAIL green multi-consumer lint"
	cat "$WORK/green/log.txt"
	echo "true rc=1"
	exit 1
fi
# Must not report undefined P720_/MISTERPLEX_
if grep -E "P720_|MISTERPLEX_" "$WORK/green/log.txt" | grep -Ei "undefined|Cannot find|not found" >/dev/null 2>&1; then
	echo "FAIL green log still has undefined contract symbols"
	cat "$WORK/green/log.txt"
	exit 1
fi
echo "GREEN ok"

# --- RED mutation: drift BPS away from 33177600 → missing-module gate ---
mkdir -p "$WORK/red/rtl"
cp "$RTL/misterplex_bw_contract.svh" "$WORK/red/rtl/"
cp "$RTL/plex_720p_bw_contract.svh" "$WORK/red/rtl/"
# Mutate frame bytes so DIR_B_PER_S = I420*24 drifts off 33177600
# 1_382_400 → 1_382_401 ⇒ BPS = 33177624
sed -i 's/1_382_400/1_382_401/' "$WORK/red/rtl/misterplex_bw_contract.svh"

cat >"$WORK/red/mut_top.sv" <<'SV'
// Fail-closed probe: wrong contract must elaborate missing module.
module mut_top (
	output wire [31:0] bps
);
`include "plex_720p_bw_contract.svh"
	assign bps = P720_FABRIC_RD_BPS[31:0];
	generate
		if (P720_FABRIC_RD_BPS != 33_177_600) begin : g_drift
			p720_bw_contract_rd_bps_must_be_33177600 u_drift_gate();
		end
	endgenerate
endmodule
SV

echo "RED mutation (expect FAIL / missing module)..."
set +e
"${VLT[@]}" --lint-only -Wall -Wno-DECLFILENAME \
	-y "$WORK/red/rtl" -I"$WORK/red/rtl" \
	"$WORK/red/mut_top.sv" \
	--top-module mut_top >"$WORK/red/log.txt" 2>&1
red_rc=$?
set -e
if grep -Eqi "command not found|Verilator not found" "$WORK/red/log.txt"; then
	echo "FAIL red path did not invoke Verilator (tooling)"
	cat "$WORK/red/log.txt"
	exit 1
fi
if [[ "$red_rc" -eq 0 ]]; then
	echo "FAIL red mutation unexpectedly passed (rc=0)"
	cat "$WORK/red/log.txt"
	exit 1
fi
# Must be the intentional missing-module gate, not a random parse error
if ! grep -Eq "MODMISSING|p720_bw_contract_rd_bps_must_be_33177600" "$WORK/red/log.txt"; then
	echo "FAIL red log lacks fail-closed missing-module gate"
	cat "$WORK/red/log.txt"
	exit 1
fi
echo "RED ok (rc=$red_rc) — drift triggers fail-closed MODMISSING"
echo "PASS test_p720_bw_contract_multiconsumer (green multi-consumer + red drift)"
echo "true rc=0"
exit 0
