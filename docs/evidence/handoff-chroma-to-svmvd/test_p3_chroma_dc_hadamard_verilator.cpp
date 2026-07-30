// Host-locked vectors for h264_chroma_dc_hadamard_inv (invChromaDc2x2).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "Vp3_chroma_dc_hadamard_tb.h"
#include "verilated.h"

static int16_t host_inv(const int16_t c[4], int qp, int16_t dc[4]) {
	const int a0 = c[0], b0 = c[1], c0v = c[2], d0 = c[3];
	const int a = a0 + b0;
	const int e = a0 - b0;
	const int b = c0v - d0;
	const int cv = c0v + d0;
	static const int mf0[6] = {10, 11, 13, 14, 16, 18};
	const int qmul = (mf0[qp % 6] * 16) << (qp / 6 + 2);
	dc[0] = static_cast<int16_t>(((a + cv) * qmul) >> 7);
	dc[1] = static_cast<int16_t>(((e + b) * qmul) >> 7);
	dc[2] = static_cast<int16_t>(((a - cv) * qmul) >> 7);
	dc[3] = static_cast<int16_t>(((e - b) * qmul) >> 7);
	return 0;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vp3_chroma_dc_hadamard_tb top;
	struct Case { int16_t c[4]; int qp; } cases[] = {
		{{0, 0, 0, 0}, 18},
		{{1, 0, 0, 0}, 18},
		{{3, -1, 2, 4}, 26},
		{{-7, 5, -3, 1}, 12},
		{{100, -40, 20, -10}, 36},
	};
	int fails = 0;
	for (const auto& tc : cases) {
		top.c0 = tc.c[0]; top.c1 = tc.c[1]; top.c2 = tc.c[2]; top.c3 = tc.c[3];
		top.qpc = tc.qp;
		top.eval();
		int16_t exp[4];
		host_inv(tc.c, tc.qp, exp);
		int16_t got[4] = {
			static_cast<int16_t>(top.d0), static_cast<int16_t>(top.d1),
			static_cast<int16_t>(top.d2), static_cast<int16_t>(top.d3)};
		for (int i = 0; i < 4; ++i) {
			if (got[i] != exp[i]) {
				std::fprintf(stderr,
					"FAIL chroma_dc qp=%d i=%d got=%d want=%d c=[%d,%d,%d,%d]\n",
					tc.qp, i, got[i], exp[i], tc.c[0], tc.c[1], tc.c[2], tc.c[3]);
				++fails;
			}
		}
	}
	if (fails) {
		std::fprintf(stderr, "FAIL p3_chroma_dc_hadamard: %d mismatches\n", fails);
		return 1;
	}
	std::printf("OK p3_chroma_dc_hadamard cases=%zu\n", sizeof(cases) / sizeof(cases[0]));
	return 0;
}
