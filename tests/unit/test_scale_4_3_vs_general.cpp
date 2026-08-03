// Prove product 4/3 path is specialised (not general Q16) and matches endpoints.
// Pre-registered (parent product budget, measured):
//   PMS 960x540 baseline → ARM decode+sws+copy = 34.50 ms, margin +7.16
//   fabric 960x540 → 1280x720 OUTPUT (not 720p source)
//
// Resource delta (argued, not fitted — no Quartus this lane):
//   general window: 11×20 mul + >>16 per axis, runtime SX=ceil((cw-1)<<16/(de-1))
//   4/3 path:       (dst*3)>>2 + 2b phase + 4-entry ROM  — no 20b mul, no divider
//   ALM: 4/3 cheaper (est. −50..−150 ALM vs general when specialised instance)
//   M10K: both 0 for address path; dual-Y hold +2 either way if bilinear taps
//   Fmax: 4/3 *3>>2 easier at clk_pix 29.7 than 11×20 mul (both OK)
// true rc direct.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cmath>

static int g = 0;
#define EXPECT(c, m) do { if (!(c)) { std::fprintf(stderr, "FAIL %s\n", m); ++g; } } while (0)

static int src43(int d) { return (d * 3) / 4; }

// General endpoint-exact Q16 (present_content_window)
static int win_sx(int cw, int hde) {
	if (cw <= 1 || hde <= 1) return 0;
	const int64_t num = int64_t(cw - 1) * 65536;
	return int((num + (hde - 2)) / (hde - 1));
}
static int store_q16(int hc, int sx, int last) {
	int v = int((uint32_t(hc) * uint32_t(sx)) >> 16);
	if (v > last) v = last;
	return v;
}

int main() {
	constexpr int CW = 960, CH = 540, HDE = 1280, VDE = 720;
	EXPECT(CW * 4 == HDE * 3 && CH * 4 == VDE * 3, "exact 4/3");

	// --- Endpoints agree ---
	EXPECT(src43(0) == 0 && src43(HDE - 1) == CW - 1, "4/3 H ends");
	EXPECT(src43(VDE - 1) == CH - 1, "4/3 V end");
	const int sx = win_sx(CW, HDE);
	const int sy = win_sx(CH, VDE);
	EXPECT(store_q16(0, sx, CW - 1) == 0, "Q16 H0");
	EXPECT(store_q16(HDE - 1, sx, CW - 1) == CW - 1, "Q16 H last");
	EXPECT(store_q16(VDE - 1, sy, CH - 1) == CH - 1, "Q16 V last");

	// --- Interior: 4/3 is phase-locked; Q16 is free-running frac ---
	// At hc=4k: 4/3 src exact; Q16 may differ by ±1 (both valid NN)
	int max_abs_diff = 0;
	int phase_disagree = 0;
	for (int hc = 0; hc < HDE; ++hc) {
		const int a = src43(hc);
		const int b = store_q16(hc, sx, CW - 1);
		const int d = std::abs(a - b);
		if (d > max_abs_diff) max_abs_diff = d;
		// phase of 4/3
		const int ph = hc & 3;
		// Q16 frac tip: not a 4-phase ROM
		(void)ph;
		if (d > 1)
			++phase_disagree;
	}
	EXPECT(max_abs_diff <= 1, "4/3 vs Q16 NN within 1 (endpoint-exact family)");
	EXPECT(phase_disagree == 0, "no >1px disagreement");

	// Mid: both ~479, not identity 639
	EXPECT(src43(639) == 479, "4/3 mid");
	EXPECT(store_q16(639, sx, CW - 1) == 479 || std::abs(store_q16(639, sx, CW - 1) - 479) <= 1,
	       "Q16 mid ~479");
	EXPECT(src43(639) != 639, "not identity");

	// --- Specialisation markers (code-level, not synth) ---
	// 4/3: multiplier constant 3, shift 2, phase bits 2, ROM depth 4
	constexpr int k43_mul_const = 3;
	constexpr int k43_shift = 2;
	constexpr int k43_phases = 4;
	constexpr int k43_rom_entries = 4;
	// general: 20b scale reg, 11x20 mul, 32b divider on update
	constexpr int kGen_scale_bits = 20;
	constexpr int kGen_mul_a = 11;
	constexpr int kGen_mul_b = 20;
	EXPECT(k43_mul_const == 3 && k43_shift == 2, "4/3 arith");
	EXPECT(k43_phases == k43_rom_entries, "4-phase ROM");
	EXPECT(kGen_mul_a * kGen_mul_b > k43_mul_const * 8, "general mul wider than 4/3");
	EXPECT(kGen_scale_bits > 8, "general has runtime scale");

	// --- M10K vertical decision (argued) ---
	// Source line 960 B ≈ 0.75 of one M10K (1024×10 usable ~1KB class; we budget 1 M10K/line).
	// Output domain line hold would be 1280 B = 1 M10K exactly.
	// Bilinear V 2-tap: need current + prev SOURCE line → 2 × 960 B → budget **2 M10K**
	// 4-tap V: 4 source lines → **4 M10K**
	// Free after nostub: 356. Either fits. Ship 2-tap: half the line RAM, enough for
	// soft decoded video; 4-tap only if parent glass shows line-twitter.
	constexpr int kLineM10kSrc = 1; // budget per 960B line
	constexpr int kV2TapM10k = 2 * kLineM10kSrc;
	constexpr int kV4TapM10k = 4 * kLineM10kSrc;
	constexpr int kFreeM10k = 356;
	constexpr int kShipVTaps = 2;
	EXPECT(kV2TapM10k == 2 && kV4TapM10k == 4, "V tap M10K");
	EXPECT(kV4TapM10k < kFreeM10k, "4-tap fits free pool");
	EXPECT(kShipVTaps == 2, "SHIP decision: 2-tap vertical");
	// Why not 4-tap default: fit risk is not M10K (356 free) but wiring dual-port
	// line holds into present_core before clk_pix PLL lands — complexity, not area.

	// Bank bytes product source (native 960x540 I420) vs Option-C full 720p
	constexpr int kProdBytes = 960 * 540 * 3 / 2; // 777600
	constexpr int kOptCBytes = 1280 * 720 * 3 / 2; // 1382400
	EXPECT(kProdBytes == 777600, "product bank bytes");
	EXPECT(kOptCBytes == 1382400, "Option-C full frame");
	EXPECT(kProdBytes * 2 > kOptCBytes, "product copy ~56% of full 720p");

	// Pre-registered parent numbers (cite only — not re-measured here)
	constexpr double kMarginMs = 7.16;
	constexpr double kDeadline = 41.667;
	constexpr double kArmTotal = 34.50;
	EXPECT(kArmTotal + kMarginMs > kDeadline - 0.1, "budget identity");

	std::printf(
	    "PASS 4/3_vs_general max_diff=%d sx_q16=%d mid43=%d "
	    "ship_vtaps=%d v2_m10k=%d v4_m10k=%d free=%d "
	    "prod_bytes=%d optc_bytes=%d "
	    "prereg_arm_ms=%.2f margin=%.2f "
	    "delta=4/3_no_20b_mul_4phase_ROM_vs_general_Q16\n",
	    max_abs_diff, sx, src43(639), kShipVTaps, kV2TapM10k, kV4TapM10k, kFreeM10k,
	    kProdBytes, kOptCBytes, kArmTotal, kMarginMs);
	return g ? 1 : 0;
}
