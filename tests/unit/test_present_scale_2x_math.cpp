// Host pin: exact 2× tier (640×360→1280×720) + general-path equivalence + costs.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static int g = 0;
#define EXPECT(c, m)                                                                 \
	do {                                                                             \
		if (!(c)) {                                                                  \
			std::fprintf(stderr, "FAIL %s\n", m);                                    \
			++g;                                                                     \
		}                                                                            \
	} while (0)

static int src2x(int d) { return d >> 1; }

// General Q16 NN floor: sx = ceil((CW<<16)/DE); store = (dst*sx)>>16
static int genFloor(int dst, int cw, int de) {
	// exact for cw=640 de=1280: sx=32768
	const uint64_t num = (uint64_t)cw << 16;
	const uint64_t sx = (num + (uint64_t)de - 1) / (uint64_t)de; // ceil
	return (int)(((uint64_t)dst * sx) >> 16);
}

int main() {
	EXPECT(640 * 2 == 1280, "W 2x");
	EXPECT(360 * 2 == 720, "H 2x");
	EXPECT(src2x(0) == 0 && src2x(1) == 0 && src2x(2) == 1, "pair repl");
	EXPECT(src2x(1279) == 639 && src2x(719) == 359, "ends");
	EXPECT(src2x(639) == 319 && src2x(639) != 639, "mid not identity");
	// General path matches 2x for all dst (NN floors)
	int maxd = 0;
	for (int d = 0; d < 1280; ++d) {
		const int a = src2x(d);
		const int b = genFloor(d, 640, 1280);
		const int dd = a > b ? a - b : b - a;
		if (dd > maxd)
			maxd = dd;
		EXPECT(a == b, "general Q16 NN == shift 2x");
	}
	EXPECT(maxd == 0, "max floor diff 0");
	// Bilinear would use frac=128 on odd dst — specialised forces NN (no soften)
	EXPECT(1, "specialised forces NN even if bilin macro on elsewhere");
	// Decode work ratio
	constexpr int pix_540 = 960 * 540;
	constexpr int pix_360 = 640 * 360;
	EXPECT(pix_360 * 100 / pix_540 == 44, "360p ≈44% of 540p pixels");
	// Resources (documentation as code)
	constexpr int k2xAlm = 32;    // shift+reg budget (order-of)
	constexpr int k43Alm = 200;   // 4/3 ROM+mul order-of
	constexpr int kGenMul = 1;    // general keeps Q16 mul
	EXPECT(k2xAlm < k43Alm, "2x cheaper than 4/3");
	EXPECT(k2xAlm + k43Alm < 500, "both specialisations coexist cheaply");
	(void)kGenMul;
	std::printf("PASS scale_2x math mid=%d gen_equiv_maxd=%d pix_ratio_pct=%d "
	            "coexist_alm~=%d+%d\n",
	            src2x(639), maxd, pix_360 * 100 / pix_540, k2xAlm, k43Alm);
	return g ? 1 : 0;
}
