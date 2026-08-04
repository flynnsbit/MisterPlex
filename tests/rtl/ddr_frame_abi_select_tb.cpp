#include "Vddr_frame_abi_select_tb_top.h"
#include "verilated.h"
#include <cstdio>

static int fails;
#define CHECK(c, m) do { if (!(c)) { std::fprintf(stderr, "FAIL %s\n", m); ++fails; } } while (0)

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vddr_frame_abi_select_tb_top top;
	top.eval();

	// Legacy 640×480 FRAME: DDR_FS_USE_720P_ABI off, but product DDR_FRAME_* is
	// already 1280×720 banks (0x30000000 / 0x302FF000 / stride 0x180000).
	CHECK(!top.p480_use_720, "NEG: 640x480 must not set USE_720P_ABI");
	CHECK(top.p480_phys == 0x30000000u, "legacy frame still product PHYS");
	CHECK(top.p480_stride == 0x180000u, "product bank stride");
	CHECK(top.p480_doorbell == 0x302FF000u, "product doorbell");
	CHECK(top.p480_coded_w == 1280, "product coded W is 1280 silicon");

	// 1280×720 glass: USE_720P_ABI on, same product map (not Option-C 0x3018/0x3047)
	CHECK(top.p720_use_720, "1280x720 selects 720p ABI");
	CHECK(top.p720_phys == 0x30000000u, "720p product PHYS 0x30000000");
	CHECK(top.p720_stride == 0x180000u, "720p stride");
	CHECK(top.p720_doorbell == 0x302FF000u, "720p product doorbell 0x302FF000");
	CHECK(top.p720_coded_w == 1280, "720p coded_w");
	CHECK(top.p720_coded_h == 720, "720p coded_h");
	CHECK(top.p720_contract_phys_match, "abi_select PHYS == P720_PHYS_BASE contract");

	if (fails) {
		std::printf("ddr_frame_abi_select: %d FAIL\n", fails);
		return 1;
	}
	std::printf(
		"ddr_frame_abi_select: OK product map 0x30000000/0x302FF000; "
		"1280x720 USE_720P; 640x480 not USE_720P; contract PHYS match\n");
	return 0;
}
