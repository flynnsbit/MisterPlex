#include "Vddr_frame_abi_select_tb_top.h"
#include "verilated.h"
#include <cstdio>

static int fails;
#define CHECK(c, m) do { if (!(c)) { std::fprintf(stderr, "FAIL %s\n", m); ++fails; } } while (0)

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vddr_frame_abi_select_tb_top top;
	top.eval();

	// 480p: must stay on product banks
	CHECK(!top.p480_use_720, "NEG: 640x480 must not select 720p ABI");
	CHECK(top.p480_phys == 0x30000000u, "480p PHYS 0x30000000");
	CHECK(top.p480_stride == 0x80000u, "480p stride 0x80000");
	CHECK(top.p480_doorbell == 0x300FF000u, "480p doorbell");
	CHECK(top.p480_coded_w == 624, "480p coded 624");

	// 720p canvas: Option-C ABI
	CHECK(top.p720_use_720, "1280x720 selects 720p ABI");
	CHECK(top.p720_phys == 0x30180000u, "720p PHYS");
	CHECK(top.p720_stride == 0x180000u, "720p stride");
	CHECK(top.p720_doorbell == 0x3047F000u, "720p doorbell");
	CHECK(top.p720_coded_w == 1280, "720p coded_w");
	CHECK(top.p720_coded_h == 720, "720p coded_h");
	CHECK(top.p720_contract_phys_match, "abi_select PHYS == P720_PHYS_BASE contract");

	if (fails) {
		std::printf("ddr_frame_abi_select: %d FAIL\n", fails);
		return 1;
	}
	std::printf(
		"ddr_frame_abi_select: OK 480p stays; 1280x720→720p ABI; "
		"contract PHYS match; NEG 640x480≠720p\n");
	return 0;
}
