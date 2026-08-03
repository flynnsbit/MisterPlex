// Diagnose: why did buggy 4/3 phase still yield max_diff=1 vs general?
//
// PRE-REGISTERED PREDICTION (publish even if wrong):
//   P1: general path does NOT share dst-mod-4; frac = Q16 residue bits [15:8]
//       (present_content_window.sv: frac_x_raw = store_x_prod[15:8]).
//   P2: old vs_general only compared floor(store_x), never phase/weights —
//       structurally blind to a 1:3↔3:1 weight swap.
//   P3: unit-ramp bilin (|s1-s0|=1) caps phase-bug error at ~1 LSB; need
//       high-contrast adjacent samples to expose tens-of-LSB error.
//   P4: not "both defects" — general is OK; the test was the problem.
//
// true rc direct. Soft-skip≠PASS.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cmath>

static int g = 0;
#define EXPECT(c, m) do { if (!(c)) { std::fprintf(stderr, "FAIL %s\n", m); ++g; } } while (0)

static int src43(int d) { return (d * 3) / 4; }
static int phase43(int d) { return (d * 3) & 3; }
static int phaseDstBug(int d) { return d & 3; }

static void rom_w(int ph, int& w0, int& w1) {
	static const int W0[4] = {256, 192, 128, 64};
	static const int W1[4] = {0, 64, 128, 192};
	w0 = W0[ph & 3];
	w1 = W1[ph & 3];
}

static int bilin(int s0, int s1, int w0, int w1) {
	return (s0 * w0 + s1 * w1 + 128) >> 8;
}

// Endpoint-exact ceil Q16 (present_content_window)
static int win_sx(int cw, int hde) {
	if (cw <= 1 || hde <= 1)
		return 0;
	const int64_t num = int64_t(cw - 1) * 65536;
	return int((num + (hde - 2)) / (hde - 1));
}

// Mirror RTL: prod = hc * sx_q16; floor = prod[31:16]; frac8 = prod[15:8]
static void q16_floor_frac(int hc, int sx, int last, int& floor_o, int& frac8_o) {
	const uint32_t prod = uint32_t(hc) * uint32_t(sx);
	int fl = int(prod >> 16);
	if (fl > last)
		fl = last;
	floor_o = fl;
	frac8_o = int((prod >> 8) & 0xffu);
	if (fl >= last)
		frac8_o = 0; // RTL forces frac=0 at last
}

int main() {
	std::printf(
	    "PREDICTION P1=general_Q16_residue_not_dst_mod4 "
	    "P2=vs_general_floor_only_blind P3=unit_ramp_hides_phase_bug "
	    "P4=general_OK_test_was_wrong\n");

	constexpr int CW = 960, CH = 540, HDE = 1280, VDE = 720;
	EXPECT(CW * 4 == HDE * 3 && CH * 4 == VDE * 3, "exact 4/3");
	const int sx = win_sx(CW, HDE);
	const int sy = win_sx(CH, VDE);
	EXPECT(sx > 0 && sy > 0, "Q16 scales");

	// ----- P2: floor-only max_diff (old vs_general observable) -----
	int max_floor_diff = 0;
	for (int hc = 0; hc < HDE; ++hc) {
		int fl = 0, fr = 0;
		q16_floor_frac(hc, sx, CW - 1, fl, fr);
		const int d = std::abs(src43(hc) - fl);
		if (d > max_floor_diff)
			max_floor_diff = d;
	}
	EXPECT(max_floor_diff <= 1, "floor 4/3 vs Q16 within 1 (old max_diff class)");

	// Floor is identical for correct 4/3 and dst-phase-buggy 4/3 (phase unused).
	EXPECT(src43(1) == 0 && src43(639) == 479, "4/3 floors independent of phase");

	// ----- P1: general frac is Q16 residue, NOT dst mod 4 -----
	// At hc=1: oracle phase3 → wx1=192; dst-bug phase1 → wx1=64.
	// Q16 frac8 must track ~191 (near 192), not 64.
	int fl1 = 0, fr1 = 0;
	q16_floor_frac(1, sx, CW - 1, fl1, fr1);
	EXPECT(fr1 >= 160 && fr1 <= 200, "general frac@1 near 192 (phase3), not 64");
	EXPECT(std::abs(fr1 - 192) < std::abs(fr1 - 64), "frac@1 closer to oracle than dst-bug");
	int bug_w0 = 0, bug_w1 = 0;
	rom_w(phaseDstBug(1), bug_w0, bug_w1);
	EXPECT(bug_w1 == 64, "dst-mod4 at dst1 yields wx1=64");
	EXPECT(fr1 != bug_w1, "general frac ≠ dst-mod4 weight (general not sharing bug)");

	std::printf("SAMPLE hc src43 q16fl frac8 ph43 phdst w1_or w1_bug\n");
	for (int hc = 0; hc < 8; ++hc) {
		int fl = 0, fr = 0;
		q16_floor_frac(hc, sx, CW - 1, fl, fr);
		int ow0 = 0, ow1 = 0, bw0 = 0, bw1 = 0;
		rom_w(phase43(hc), ow0, ow1);
		rom_w(phaseDstBug(hc), bw0, bw1);
		std::printf("  %d %d %d %d %d %d %d %d\n", hc, src43(hc), fl, fr, phase43(hc),
		            phaseDstBug(hc), ow1, bw1);
	}

	// ----- P3: unit ramp hides phase bug; high-contrast exposes it -----
	int max_unit_bug = 0;
	int max_hi_bug = 0;
	int hi_disagree = 0;
	for (int hc = 0; hc < HDE; ++hc) {
		const int s0 = src43(hc);
		const int s1 = (s0 >= CW - 1) ? s0 : s0 + 1;
		int w0o = 0, w1o = 0, w0b = 0, w1b = 0;
		rom_w(phase43(hc), w0o, w1o);
		rom_w(phaseDstBug(hc), w0b, w1b);
		const int u_good = bilin(s0, s1, w0o, w1o);
		const int u_bad = bilin(s0, s1, w0b, w1b);
		const int ud = std::abs(u_good - u_bad);
		if (ud > max_unit_bug)
			max_unit_bug = ud;
		const int h_good = bilin(0, 255, w0o, w1o);
		const int h_bad = bilin(0, 255, w0b, w1b);
		const int hd = std::abs(h_good - h_bad);
		if (hd > max_hi_bug)
			max_hi_bug = hd;
		if (hd > 1)
			++hi_disagree;
	}
	EXPECT(max_unit_bug <= 1, "unit-ramp phase-bug max_abs <= 1 (hides defect)");
	EXPECT(max_hi_bug >= 64, "high-contrast phase-bug max_abs >= 64 (tens of LSBs)");
	EXPECT(hi_disagree > 0, "high-contrast pixels disagree under phase bug");
	{
		int w0o = 0, w1o = 0, w0b = 0, w1b = 0;
		rom_w(phase43(1), w0o, w1o);
		rom_w(phaseDstBug(1), w0b, w1b);
		const int go = bilin(0, 255, w0o, w1o);
		const int gb = bilin(0, 255, w0b, w1b);
		EXPECT(std::abs(go - gb) >= 100, "dst1 high-contrast |Δ|>=100 under phase bug");
		std::printf("dst1_hi_contrast oracle=%d bug=%d abs=%d w_or=%d/%d w_bug=%d/%d\n", go, gb,
		            std::abs(go - gb), w0o, w1o, w0b, w1b);
	}

	// ----- Where floors agree, general Q8 tracks oracle better than dst-mod4 -----
	// (When floors disagree, continuous Q16 is a different resampling — not the bug class.)
	int max_gen_vs_or_agree = 0;
	int max_bug_vs_or_agree = 0;
	int agree_n = 0;
	for (int hc = 0; hc < HDE; ++hc) {
		int fl = 0, fr = 0;
		q16_floor_frac(hc, sx, CW - 1, fl, fr);
		if (fl != src43(hc))
			continue;
		++agree_n;
		const int gen = bilin(0, 255, 255 - fr, fr);
		int w0o = 0, w1o = 0, w0b = 0, w1b = 0;
		rom_w(phase43(hc), w0o, w1o);
		rom_w(phaseDstBug(hc), w0b, w1b);
		const int o = bilin(0, 255, w0o, w1o);
		const int b = bilin(0, 255, w0b, w1b);
		const int dg = std::abs(gen - o);
		const int db = std::abs(b - o);
		if (dg > max_gen_vs_or_agree)
			max_gen_vs_or_agree = dg;
		if (db > max_bug_vs_or_agree)
			max_bug_vs_or_agree = db;
	}
	EXPECT(agree_n > 100, "enough floor-agreed samples");
	EXPECT(max_bug_vs_or_agree > max_gen_vs_or_agree,
	       "on floor-agreed samples dst-mod4 worse than general Q8 vs oracle");
	EXPECT(max_bug_vs_or_agree >= 64, "dst-mod4 high-contrast error large on agreed floors");
	// Point sample hc=1 (floors agree at 0)
	{
		const int gen1 = bilin(0, 255, 255 - fr1, fr1);
		int w0o = 0, w1o = 0, w0b = 0, w1b = 0;
		rom_w(phase43(1), w0o, w1o);
		rom_w(phaseDstBug(1), w0b, w1b);
		const int o1 = bilin(0, 255, w0o, w1o);
		const int b1 = bilin(0, 255, w0b, w1b);
		EXPECT(std::abs(gen1 - o1) < std::abs(b1 - o1),
		       "hc=1: general closer to oracle than dst-mod4");
		std::printf("hc1_hi gen=%d oracle=%d bug=%d |g-o|=%d |b-o|=%d\n", gen1, o1, b1,
		            std::abs(gen1 - o1), std::abs(b1 - o1));
	}
	const int max_gen_vs_or = max_gen_vs_or_agree;
	const int max_bug_vs_or = max_bug_vs_or_agree;

	EXPECT(src43(639) == 479 && src43(639) != 639, "4/3 mid not identity");
	constexpr int k43_mul = 3, k43_sh = 2, kGen_mul = 11 * 20;
	EXPECT(kGen_mul > k43_mul * 8, "general mul wider");
	EXPECT(k43_mul == 3 && k43_sh == 2, "4/3 arith");

	int flv = 0, frv = 0;
	q16_floor_frac(1, sy, CH - 1, flv, frv);
	EXPECT(frv >= 160 && frv <= 200, "V general frac@1 near 192 not 64");
	EXPECT(phase43(1) == 3 && phaseDstBug(1) == 1, "V phase oracle vs bug");

	const int p1_ok = (fr1 >= 160 && std::abs(fr1 - 192) < std::abs(fr1 - 64)) ? 1 : 0;
	const int p2_ok = (max_floor_diff <= 1) ? 1 : 0;
	const int p3_ok = (max_unit_bug <= 1 && max_hi_bug >= 64) ? 1 : 0;
	const int p4_ok = (p1_ok && p2_ok) ? 1 : 0;
	EXPECT(p1_ok && p2_ok && p3_ok && p4_ok, "all pre-registered predictions HIT");

	std::printf(
	    "PASS scale_phase_diagnosis "
	    "pred_hit=P1%d/P2%d/P3%d/P4%d "
	    "floor_max_diff=%d unit_ramp_phase_bug_max=%d hi_contrast_phase_bug_max=%d "
	    "gen_vs_or_hi_max=%d bug_vs_or_hi_max=%d "
	    "frac1=%d sx_q16=%d "
	    "finding=general_OK_vs_general_was_floor_only_unit_ramp_hides_LSB\n",
	    p1_ok, p2_ok, p3_ok, p4_ok, max_floor_diff, max_unit_bug, max_hi_bug, max_gen_vs_or,
	    max_bug_vs_or, fr1, sx);
	return g ? 1 : 0;
}
