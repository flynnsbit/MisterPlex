#include "Vplex_bw_status_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vplex_bw_status_tb_top top;

	// PRE-REG: after clocks, stamp = 33177600 B/s, 172800 beats, ppc=2, nack=1
	top.clk = 0;
	top.eval();
	for (int i = 0; i < 4; i++) {
		top.clk = 1; top.eval();
		top.clk = 0; top.eval();
	}

	const uint32_t dir = static_cast<uint32_t>(top.dir_bps);
	const uint32_t beats = static_cast<uint32_t>(top.beats);
	const uint32_t rw = static_cast<uint32_t>(top.rw_pair);
	const uint32_t ppc = static_cast<uint32_t>(top.ppc);
	const uint32_t nack = static_cast<uint32_t>(top.nack_de);
	const uint32_t tcopy = static_cast<uint32_t>(top.t_copy_us);
	const uint32_t budget = static_cast<uint32_t>(top.budget_us);

	int rc = 0;
	if (dir != 33177600u) {
		std::fprintf(stderr, "FAIL dir_bps=%u want 33177600\n", dir);
		rc = 1;
	}
	if (beats != 172800u) {
		std::fprintf(stderr, "FAIL beats=%u want 172800\n", beats);
		rc = 1;
	}
	if (rw != 345600u) {
		std::fprintf(stderr, "FAIL rw_pair=%u want 345600\n", rw);
		rc = 1;
	}
	if (ppc != 2u) {
		std::fprintf(stderr, "FAIL ppc=%u want 2\n", ppc);
		rc = 1;
	}
	if (nack != 1u) {
		std::fprintf(stderr, "FAIL nack_de=%u want 1\n", nack);
		rc = 1;
	}
	if (tcopy != 14978u) {
		std::fprintf(stderr, "FAIL t_copy_us=%u want 14978 (parent HW)\n", tcopy);
		rc = 1;
	}
	if (budget != 41667u) {
		std::fprintf(stderr, "FAIL budget_us=%u want 41667\n", budget);
		rc = 1;
	}
	if (!(tcopy < budget)) {
		std::fprintf(stderr, "FAIL t_copy not < budget\n");
		rc = 1;
	}
	if (dir == 3u || dir == 30u) {
		std::fprintf(stderr, "FAIL stamped DDR load looks like DE-peak 3.0\n");
		rc = 1;
	}

	if (rc == 0) {
		std::printf("PASS plex_bw_status: dir_bps=%u beats=%u rw=%u ppc=%u nack=%u "
			"t_copy_us=%u budget_us=%u\n",
			dir, beats, rw, ppc, nack, tcopy, budget);
	}
	top.final();
	return rc;
}
