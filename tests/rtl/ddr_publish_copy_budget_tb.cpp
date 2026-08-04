// Locks PRE-REGISTERED PL330/fabric pins then checks computed µs.
// Device BW is explicitly NOT verified here (pl330_dev_verified must be 0).
#include "Vddr_publish_copy_budget_tb_top.h"
#include "verilated.h"
#include <cstdio>

static int fails;
#define CHECK(c, m) do { if (!(c)) { std::fprintf(stderr, "FAIL %s\n", m); ++fails; } } while (0)

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vddr_publish_copy_budget_tb_top top;
	top.eval();

	// PRE-REGISTERED pins (must match rtl localparam; change = GOLDEN-CHANGE)
	CHECK(top.pl330_m10k == 0, "PREREG pl330 M10K=0");
	CHECK(top.pl330_alm == 0, "PREREG pl330 ALM=0");
	CHECK(top.fab_m10k == 2, "PREREG fabric bounce M10K=2 (128x64b EST 2x256x32)");
	CHECK(top.fab_alm == 400, "PREREG fabric ALM EST=400");
	CHECK(top.pl330_bw == 150000u, "PREREG pl330 150 MB/s EST");
	CHECK(top.fab_peak == 720000u, "PREREG fabric peak 720 MB/s");
	CHECK(top.t_arm == 14978u, "PREREG T_copy_arm 14.978 ms");

	// Computed: t_pl330 = 1382400*1000/150000 = 9216 µs
	CHECK(top.t_pl330 == 9216u, "t_pl330 9.216 ms @150MB/s EST");
	// t_fab_rw = 2*(1382400/8)/90e6 * 1e6 = 3840 µs
	CHECK(top.t_fab_rw == 3840u, "t_fabric_ideal_rw 3.840 ms");
	CHECK(top.t_fab_r == 1920u, "t_fabric_present_R 1.920 ms");
	CHECK(top.t_budget == 41666u, "24fps budget ~41.666 ms");
	CHECK(top.r_req == 33177600u, "R_req 33.1776 MB/s");

	CHECK(top.pl330_beats_arm, "PL330 EST beats ARM memcpy");
	CHECK(top.fab_beats_arm, "fabric ideal beats ARM");
	CHECK(top.fab_fits_24, "fabric ideal fits 24fps budget");
	CHECK(top.pl330_fits_24, "PL330 EST fits 24fps budget");

	// Contention structural
	CHECK(top.fab_contends_present, "fabric shares present DDRAM port");
	CHECK(!top.pl330_contends_present, "PL330 does not share f2sdram");
	CHECK(top.pl330_contends_cpu, "PL330 shares HPS DDR with MiSTer");
	CHECK(top.dyn_base_zero_m10k, "dyn-base preferred M10K=0");

	// Honesty bits
	CHECK(!top.pl330_dev_verified, "PL330 BW NOT device-verified here");
	CHECK(!top.fab_dev_verified, "fabric real ms NOT device-verified here");

	if (fails) {
		std::printf("ddr_publish_copy_budget: %d FAIL\n", fails);
		return 1;
	}
	std::printf(
		"ddr_publish_copy_budget: OK PREREG locked; "
		"t_pl330=9.216ms EST t_fab_rw=3.840ms ideal; "
		"fabric contends present; PL330 does not; device BW unverified\n");
	return 0;
}
