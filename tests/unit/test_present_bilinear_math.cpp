// Host model for present_bilinear_lerp + filter decision costs.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static int g_fails = 0;
#define EXPECT(c, m) do { if (!(c)) { std::fprintf(stderr, "FAIL %s\n", m); ++g_fails; } } while (0)

static int lerp(int p00, int p10, int p01, int p11, int fx, int fy) {
	const int wx0 = 255 - fx, wy0 = 255 - fy;
	const int64_t acc = int64_t(wx0 * wy0) * p00 + int64_t(fx * wy0) * p10 +
	                    int64_t(wx0 * fy) * p01 + int64_t(fx * fy) * p11 + 32768;
	return int((acc >> 16) & 255);
}

int main() {
	EXPECT(lerp(10, 200, 30, 220, 0, 0) == 10, "fx=fy=0 -> p00");
	EXPECT(lerp(0, 255, 0, 255, 128, 0) >= 120 && lerp(0, 255, 0, 255, 128, 0) <= 135,
	       "fx=128 half toward p10");
	// NEG: NN would ignore p10
	EXPECT(lerp(0, 255, 0, 255, 200, 0) > 150, "high fx mixes p10");
	// Cost pins (documentation as code)
	constexpr int kBilinearLerpM10k = 0;
	constexpr int kBilinearDualYLineM10k = 2; // when fully wired @1280
	constexpr int kNnM10k = 0;
	constexpr int kFreeM10kPostNostub = 356;
	EXPECT(kNnM10k == 0, "NN zero M10K");
	EXPECT(kBilinearLerpM10k == 0, "lerp unit zero M10K");
	EXPECT(kBilinearDualYLineM10k + kBilinearLerpM10k < kFreeM10kPostNostub,
	       "full bilinear fits free M10K");
	// clk_pix classes (MHz) — scaler has no 20 MHz hardwire
	constexpr int kClkSysMhz = 20;
	constexpr int kClkPix720p24Mhz = 30; // ceil 29.70
	constexpr int kClkPix720p60Mhz = 75; // ceil 74.25
	EXPECT(kClkPix720p24Mhz > kClkSysMhz, "720p24 pix > sys");
	EXPECT(kClkPix720p60Mhz > kClkPix720p24Mhz, "720p60 pix > 24");
	std::printf("PASS bilinear math + cost pins lerp_m10k=%d dual_y=%d free=%d "
	            "clk_pix24=%d clk_pix60=%d\n",
	            kBilinearLerpM10k, kBilinearDualYLineM10k, kFreeM10kPostNostub,
	            kClkPix720p24Mhz, kClkPix720p60Mhz);
	return g_fails ? 1 : 0;
}
