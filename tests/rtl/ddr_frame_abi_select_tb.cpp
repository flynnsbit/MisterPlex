// RED-before-green intent: 1280x720 FRAME (MULTI recipe, no L4) must pick
// 720p phys/doorbell/stride and LINE_COUNT floor 16. 640x480 stays 480p.
#include "Vddr_frame_abi_select_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vddr_frame_abi_select_tb_top top;
	top.eval();

	const uint32_t PHYS_480 = 0x30000000u;
	const uint32_t DOOR_480 = 0x300FF000u;
	const uint32_t STRIDE_480 = 0x00080000u;
	const uint32_t PHYS_720 = 0x30180000u;
	const uint32_t DOOR_720 = 0x3047F000u;
	const uint32_t STRIDE_720 = 0x00180000u;

	int rc = 0;
	std::printf("PRE-REG: 480→phys=0x30000000 lines=8; 720→phys=0x30180000 lines=16 coded=1280\n");

	if (top.p480_use_720 != 0) {
		std::fprintf(stderr, "FAIL 480p probe selected 720p ABI\n");
		rc = 1;
	}
	if (top.p480_phys != PHYS_480 || top.p480_doorbell != DOOR_480 ||
	    top.p480_stride != STRIDE_480 || top.p480_coded_w != 624 ||
	    top.p480_lines != 8) {
		std::fprintf(stderr,
			"FAIL 480p abi phys=0x%08x door=0x%08x stride=0x%08x coded=%u lines=%u\n",
			top.p480_phys, top.p480_doorbell, top.p480_stride,
			top.p480_coded_w, top.p480_lines);
		rc = 1;
	}

	if (top.p720_use_720 != 1) {
		std::fprintf(stderr, "FAIL 720p FRAME did not select 720p ABI (MULTI-class)\n");
		rc = 1;
	}
	if (top.p720_phys != PHYS_720 || top.p720_doorbell != DOOR_720 ||
	    top.p720_stride != STRIDE_720 || top.p720_coded_w != 1280) {
		std::fprintf(stderr,
			"FAIL 720p abi phys=0x%08x door=0x%08x stride=0x%08x coded=%u\n",
			top.p720_phys, top.p720_doorbell, top.p720_stride, top.p720_coded_w);
		rc = 1;
	}
	// Blackout: FRAME_LINES_8 input must floor to 16 on 720p ABI
	if (top.p720_lines != 16) {
		std::fprintf(stderr, "FAIL 720p line floor: got %u want 16 (8→16)\n",
			top.p720_lines);
		rc = 1;
	}

	if (rc == 0) {
		std::printf("ddr_frame_abi_select TB PASS "
			"480 phys=0x%08x lines=%u; 720 phys=0x%08x lines=%u coded=%u\n",
			top.p480_phys, top.p480_lines,
			top.p720_phys, top.p720_lines, top.p720_coded_w);
	}
	return rc;
}
