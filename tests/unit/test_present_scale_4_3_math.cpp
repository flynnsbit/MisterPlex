// Host pin for product 4/3 scale (960×540 → 1280×720) + cost/quality decision.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static int g = 0;
#define EXPECT(c, m) do { if (!(c)) { std::fprintf(stderr, "FAIL %s\n", m); ++g; } } while (0)

static int src43(int dst) { return (dst * 3) / 4; }

int main() {
	EXPECT(960 * 4 == 1280 * 3, "W 4/3");
	EXPECT(540 * 4 == 720 * 3, "H 4/3");
	EXPECT(src43(0) == 0 && src43(1279) == 959, "H endpoints");
	EXPECT(src43(719) == 539, "V last");
	EXPECT(src43(639) == 479, "mid 639→479");
	EXPECT(src43(639) != 639, "not identity");
	// phase = (3*dst) mod 4 → 0,3,2,1 — NOT dst mod 4
	EXPECT(((0 * 3) & 3) == 0 && ((1 * 3) & 3) == 3 && ((2 * 3) & 3) == 2 &&
	           ((3 * 3) & 3) == 1,
	       "phase seq 0,3,2,1");
	EXPECT((1 & 3) != ((1 * 3) & 3), "dst mod4 ≠ oracle at dst=1");
	// phase weights indexed by oracle phase
	const int w0[4] = {256, 192, 128, 64};
	const int w1[4] = {0, 64, 128, 192};
	for (int p = 0; p < 4; ++p)
		EXPECT(w0[p] + w1[p] == 256, "weights sum 256");
	// dst=1 → phase 3 → 64/192
	EXPECT(w0[3] == 64 && w1[3] == 192, "dst1 uses phase3 weights");
	// inverted *4>>2 is identity-ish on low coords
	EXPECT((639 * 4) / 4 == 639, "invert class is identity");
	// Costs (documentation as code)
	constexpr int kNnM10k = 0;
	constexpr int kBilinM10k = 0;      // lerp only
	constexpr int kBilinDualYM10k = 2; // if dual Y hold
	constexpr int kV4TapM10k = 4;      // 4×960 lines worst
	constexpr int kFree = 356;
	EXPECT(kNnM10k + kBilinM10k + kBilinDualYM10k < kFree, "2-tap fits");
	EXPECT(kV4TapM10k < kFree, "4-tap V fits free M10K");
	// clk_pix
	constexpr int kPix24 = 29700000;
	constexpr int kSys = 20000000;
	EXPECT(kPix24 > kSys, "720p24 needs faster clk_pix than sys");
	// Quality decision encoded:
	// vertical_2tap_enough_for_fit = 1; vertical_4tap_if_twitter = 1
	constexpr int kShipVTaps = 2;
	constexpr int kOptionalVTaps = 4;
	EXPECT(kShipVTaps == 2, "ship 2-tap V bilinear");
	EXPECT(kOptionalVTaps == 4, "optional 4-tap if glass twitter");
	std::printf("PASS scale_4_3 math mid=%d endpoints=0..959/539 "
	            "ship_vtaps=%d opt_vtaps=%d bilin_m10k=%d+%d v4_m10k=%d clk_pix24=%d\n",
	            src43(639), kShipVTaps, kOptionalVTaps, kBilinM10k, kBilinDualYM10k,
	            kV4TapM10k, kPix24);
	return g ? 1 : 0;
}
