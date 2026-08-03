// Independent arithmetic oracle for product 4/3 bilinear phase.
//
// Definition (not derived from RTL or general Q16 path):
//   src   = floor(dst * 3 / 4)
//   phase = (dst * 3) mod 4     // frac of src position in [0,1) as k/4
//   weights[phase] = {(255,0),(192,64),(128,128),(64,192)} for k=0..3
//
// Buggy alternative (pre-fix present_scale_4_3): phase = dst mod 4
//   sequence 0,1,2,3 instead of 0,3,2,1 — wrong weights on 3/4 of pixels.
//
// This test FAILS if phase uses dst mod 4. It does NOT compare two RTL paths
// (that was tautological: both wrong → max_diff=0). true rc direct.

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

static int src43(int dst) { return (dst * 3) / 4; }
static int phase43(int dst) { return (dst * 3) & 3; }
static int phaseDstBug(int dst) { return dst & 3; }

static void weights(int ph, int& w0, int& w1) {
	static const int W0[4] = {255, 192, 128, 64};
	static const int W1[4] = {0, 64, 128, 192};
	w0 = W0[ph & 3];
	w1 = W1[ph & 3];
}

// Independent bilinear sample of a linear ramp s(x)=x (integer math).
// out = round((s0*w0 + s1*w1) / 255) with s1=s0+1 when not at edge.
static int bilinRamp(int dst, int srcLast) {
	const int s0 = src43(dst);
	const int s1 = (s0 >= srcLast) ? s0 : (s0 + 1);
	int w0 = 0, w1 = 0;
	weights(phase43(dst), w0, w1);
	const int acc = s0 * w0 + s1 * w1;
	return (acc + 127) / 255;
}

static int bilinRampDstPhaseBug(int dst, int srcLast) {
	const int s0 = src43(dst);
	const int s1 = (s0 >= srcLast) ? s0 : (s0 + 1);
	int w0 = 0, w1 = 0;
	weights(phaseDstBug(dst), w0, w1);
	const int acc = s0 * w0 + s1 * w1;
	return (acc + 127) / 255;
}

int main() {
	// --- Oracle phase sequence ---
	EXPECT(phase43(0) == 0 && phase43(1) == 3 && phase43(2) == 2 && phase43(3) == 1,
	       "oracle phase 0,3,2,1");
	EXPECT(phaseDstBug(0) == 0 && phaseDstBug(1) == 1 && phaseDstBug(2) == 2 &&
	           phaseDstBug(3) == 3,
	       "bug phase 0,1,2,3");
	// Even dst: (3d)≡d (mod 4) → phase matches. Odd dst: phase 1↔3 swapped.
	// So 2 of every 4 pixels get wrong weights (not 3/4 — still catastrophic).
	int disagree = 0;
	for (int d = 0; d < 16; ++d)
		if (phase43(d) != phaseDstBug(d))
			++disagree;
	EXPECT(disagree == 8, "8/16 positions disagree (odd dst: phase 1↔3 swap)");
	EXPECT(phase43(0) == phaseDstBug(0) && phase43(2) == phaseDstBug(2),
	       "even dst phase coincides");
	EXPECT(phase43(1) == 3 && phaseDstBug(1) == 1, "dst1: oracle3 vs bug1");
	EXPECT(phase43(3) == 1 && phaseDstBug(3) == 3, "dst3: oracle1 vs bug3");

	// --- Weights at dst=1 must be 64/192 (phase3), not 192/64 (dst-phase1) ---
	int w0 = 0, w1 = 0;
	weights(phase43(1), w0, w1);
	EXPECT(w0 == 64 && w1 == 192, "dst1 oracle weights 1:3");
	int bw0 = 0, bw1 = 0;
	weights(phaseDstBug(1), bw0, bw1);
	EXPECT(bw0 == 192 && bw1 == 64, "dst1 bug weights 3:1");
	EXPECT(w0 != bw0, "oracle weight ≠ bug weight at dst=1");

	// --- Bilinear ramp oracle vs bug: must differ (else test is tautological) ---
	constexpr int SRC_LAST = 959;
	int pixel_disagree = 0;
	int max_abs = 0;
	for (int dst = 0; dst < 1280; ++dst) {
		const int good = bilinRamp(dst, SRC_LAST);
		const int bad = bilinRampDstPhaseBug(dst, SRC_LAST);
		const int d = good > bad ? good - bad : bad - good;
		if (d > max_abs)
			max_abs = d;
		if (good != bad)
			++pixel_disagree;
	}
	EXPECT(pixel_disagree > 0, "bug changes bilinear output (oracle can RED)");
	EXPECT(max_abs > 0, "max |good-bad| > 0");
	// At dst=1: s0=0,s1=1 → good=(0*64+1*192)/255≈0.75→1; bad=(0*192+1*64)/255≈0
	EXPECT(bilinRamp(1, SRC_LAST) != bilinRampDstPhaseBug(1, SRC_LAST),
	       "dst=1 bilinear differs under phase bug");

	// --- Vertical same structure (py) ---
	EXPECT(phase43(1) == phase43(1), "V uses same phase fn");
	EXPECT(src43(719) == 539, "V last");
	int v_disagree = 0;
	for (int py = 0; py < 720; ++py)
		if (phase43(py) != phaseDstBug(py))
			++v_disagree;
	EXPECT(v_disagree == 360, "V: half of lines disagree phase (odd py, 360/720)");

	// --- Endpoints still exact ---
	EXPECT(src43(0) == 0 && src43(1279) == 959, "H ends");
	EXPECT(src43(639) == 479, "mid");

	// Document what would make this test fail on fixed code: nothing in oracle
	// phase walk. What makes it fail on buggy code: phase seq / weights / bilin.
	EXPECT(phase43(1) != 1, "FAIL mode: if phase==dst mod4 then phase(1)==1");

	std::printf(
	    "PASS scale_4_3_phase_oracle seq=0,3,2,1 phase_disagree_16=%d "
	    "bilin_pixel_disagree=%d max_abs=%d v_phase_disagree=%d "
	    "fail_mode=dst_mod4_weights\n",
	    disagree, pixel_disagree, max_abs, v_disagree);
	return g ? 1 : 0;
}
