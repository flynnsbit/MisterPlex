// Integrated 2-PPC Y 4/3 scaler — pixel oracle through RAM_LAT=1 pipeline.
//
// Component: Y plane only (not RGB). U/V half-res is a separate future path.
//
// A) constant → pix0==pix1==C (sum-256)
// B) H ramp oracle max_abs=0 (full width)
// C) V ramp + V edge (py=0 and py=719) oracle
// D) pair span 2/3-tap interior
// E) RED FAULT_PHASE_DST fails product
// F) req_* comb: tap_base follows floor map on request cycle (not registered-only)
//
// EXECUTED before non-zero rc. true rc direct.

#include "Vpresent_scale_4_3_2ppc_tb.h"
#include "verilated.h"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

namespace {

constexpr int SRC_W = 960;
constexpr int SRC_H = 540;
constexpr int DST_W = 1280;
constexpr int DST_H = 720;

int src43(int dst) { return (dst * 3) / 4; }
int phase43(int dst) { return (dst * 3) & 3; }
int phaseDstBug(int dst) { return dst & 3; }

void wrom(int ph, int& w0, int& w1) {
	static const int W0[4] = {256, 192, 128, 64};
	static const int W1[4] = {0, 64, 128, 192};
	w0 = W0[ph & 3];
	w1 = W1[ph & 3];
}

int bilin256(int p00, int p10, int p01, int p11, int wx0, int wx1, int wy0, int wy1) {
	const int h0 = (p00 * wx0 + p10 * wx1 + 128) >> 8;
	const int h1 = (p01 * wx0 + p11 * wx1 + 128) >> 8;
	return (h0 * wy0 + h1 * wy1 + 128) >> 8;
}

int clampi(int v, int lo, int hi) {
	if (v < lo)
		return lo;
	if (v > hi)
		return hi;
	return v;
}

enum class Pat { Const, HRamp, VRamp, HV };

int srcVal(Pat p, int x, int y, int c) {
	x = clampi(x, 0, SRC_W - 1);
	y = clampi(y, 0, SRC_H - 1);
	switch (p) {
	case Pat::Const:
		return c & 255;
	case Pat::HRamp:
		return x > 255 ? 255 : x;
	case Pat::VRamp:
		return y > 255 ? 255 : y;
	case Pat::HV:
		return clampi(x + 2 * y, 0, 255);
	}
	return 0;
}

int oraclePix(Pat p, int dstx, int dsty, int c, bool useBugPhase) {
	const int s0 = src43(dstx);
	const int s1 = (s0 >= SRC_W - 1) ? s0 : s0 + 1;
	const int t0 = src43(dsty);
	const int t1 = (t0 >= SRC_H - 1) ? t0 : t0 + 1;
	const int phx = useBugPhase ? phaseDstBug(dstx) : phase43(dstx);
	const int phy = useBugPhase ? phaseDstBug(dsty) : phase43(dsty);
	int wx0 = 0, wx1 = 0, wy0 = 0, wy1 = 0;
	wrom(phx, wx0, wx1);
	wrom(phy, wy0, wy1);
	return bilin256(srcVal(p, s0, t0, c), srcVal(p, s1, t0, c), srcVal(p, s0, t1, c),
	                srcVal(p, s1, t1, c), wx0, wx1, wy0, wy1);
}

struct Sim {
	Vpresent_scale_4_3_2ppc_tb top{};

	void tick() {
		top.clk = 0;
		top.eval();
		top.clk = 1;
		top.eval();
	}

	void resetCycles(int n = 4) {
		top.reset = 1;
		top.ce_pix = 0;
		top.use_direct_taps = 0;
		top.in_content = 0;
		for (int i = 0; i < n; ++i)
			tick();
		top.reset = 0;
		tick();
	}

	void driveSrcWindow(Pat p, int base_x, int y0, int y1, int c) {
		top.src_y0_0 = srcVal(p, base_x + 0, y0, c);
		top.src_y0_1 = srcVal(p, base_x + 1, y0, c);
		top.src_y0_2 = srcVal(p, base_x + 2, y0, c);
		top.src_y0_3 = srcVal(p, base_x + 3, y0, c);
		top.src_y1_0 = srcVal(p, base_x + 0, y1, c);
		top.src_y1_1 = srcVal(p, base_x + 1, y1, c);
		top.src_y1_2 = srcVal(p, base_x + 2, y1, c);
		top.src_y1_3 = srcVal(p, base_x + 3, y1, c);
	}

	// Host mirror of comb req for driving src window this cycle.
	static void hostReq(int hc_g, int py, int& base, int& y0, int& y1) {
		const int hc0 = hc_g & ~1;
		const int s0 = src43(hc0);
		const int s1 = src43(hc0 + 1);
		base = (s0 <= s1) ? s0 : s1;
		y0 = src43(py);
		y1 = (y0 >= SRC_H - 1) ? y0 : y0 + 1;
	}

	// One ce_pix beat: set group + src for THIS request.
	void beat(int hc_g, int py, Pat p, int c, int in_c = 1) {
		const int hc0 = hc_g & ~1;
		int base = 0, y0 = 0, y1 = 0;
		hostReq(hc0, py, base, y0, y1);
		top.hc_g = hc0 & 0x7ff;
		top.py = py & 0x7ff;
		top.in_content = in_c;
		driveSrcWindow(p, base, y0, y1, c);
		top.ce_pix = 1;
		tick();
		top.ce_pix = 0;
		tick();
	}

	// Stream one group and return its pixels (RAM_LAT=1 → output on next beat).
	// Uses a dummy follow-up beat with in_content=0 to retire the pipeline.
	void sampleGroup(int hc_g, int py, Pat p, int c) {
		beat(hc_g, py, p, c, 1);
		// Retire: issue dummy request; previous group's taps+meta produce pix
		beat(0, 0, p, c, 0);
	}
};

int runConstant() {
	Sim s;
	s.resetCycles();
	const int C = 0xA5;
	int f = 0;
	auto exp = [&](bool c, const char* m) {
		if (!c) {
			std::cerr << "FAIL const: " << m << "\n";
			++f;
		}
	};
	for (int g = 0; g < 64; g += 2) {
		for (int py : {0, 1, 2, 3, 100, 359, 719}) {
			s.sampleGroup(g, py, Pat::Const, C);
			exp(int(s.top.out_valid) == 1, "out_valid");
			exp(int(s.top.pix0) == C, "pix0 constant");
			exp(int(s.top.pix1) == C, "pix1 constant");
			exp(int(s.top.wx0_a) + int(s.top.wx1_a) == 256, "wx sum 256 a");
			exp(int(s.top.wy0) + int(s.top.wy1) == 256, "wy sum 256");
		}
	}
	std::cout << "CASE scale43_2ppc_const EXECUTED C=0xA5 fails=" << f << "\n";
	if (f)
		return 1;
	std::cout << "PASS scale43_2ppc constant-color sum256\n";
	return 0;
}

int runRampH() {
	Sim s;
	s.resetCycles();
	int f = 0;
	auto exp = [&](bool c, const char* m) {
		if (!c) {
			std::cerr << "FAIL hramp: " << m << "\n";
			++f;
		}
	};
	int checked = 0;
	int max_abs = 0;
	for (int g = 0; g < DST_W; g += 2) {
		for (int py : {0, 1, 2, 3, 359, 719}) {
			s.sampleGroup(g, py, Pat::HRamp, 0);
			const int o0 = oraclePix(Pat::HRamp, g, py, 0, false);
			const int o1 = oraclePix(Pat::HRamp, g + 1, py, 0, false);
			const int d0 = std::abs(int(s.top.pix0) - o0);
			const int d1 = std::abs(int(s.top.pix1) - o1);
			if (d0 > max_abs)
				max_abs = d0;
			if (d1 > max_abs)
				max_abs = d1;
			if (d0 || d1) {
				if (f < 6)
					std::cerr << "FAIL hramp g=" << g << " py=" << py << " got "
					          << int(s.top.pix0) << "/" << int(s.top.pix1) << " exp " << o0
					          << "/" << o1 << "\n";
				++f;
			}
			++checked;
			if (int(s.top.tap_base_x) + 2 <= SRC_W - 1) {
				const int span = int(s.top.store_x1_b) - int(s.top.tap_base_x);
				if ((g & 3) == 2)
					exp(span == 2, "3-tap interior");
				if ((g & 3) == 0)
					exp(span == 1, "2-tap interior");
			}
		}
	}
	s.sampleGroup(0, 0, Pat::HRamp, 0);
	exp(int(s.top.phase_x0) == 0 && int(s.top.phase_x1) == 3, "group0 phases 0,3");
	exp(int(s.top.wx0_b) == 64 && int(s.top.wx1_b) == 192, "g0b 64/192");
	std::cout << "CASE scale43_2ppc_ramp EXECUTED checked=" << checked
	          << " max_abs=" << max_abs << " fails=" << f << "\n";
	if (f || max_abs)
		return 1;
	std::cout << "PASS scale43_2ppc H-ramp oracle max_abs=0\n";
	return 0;
}

int runRampV() {
	Sim s;
	s.resetCycles();
	int f = 0;
	int checked = 0;
	int max_abs = 0;
	// Full vertical + edges; several H groups including 3-tap class
	for (int g : {0, 2, 100, 640, 1278}) {
		for (int py = 0; py < DST_H; ++py) {
			s.sampleGroup(g, py, Pat::VRamp, 0);
			const int o0 = oraclePix(Pat::VRamp, g, py, 0, false);
			const int o1 = oraclePix(Pat::VRamp, g + 1, py, 0, false);
			const int d0 = std::abs(int(s.top.pix0) - o0);
			const int d1 = std::abs(int(s.top.pix1) - o1);
			if (d0 > max_abs)
				max_abs = d0;
			if (d1 > max_abs)
				max_abs = d1;
			if (d0 || d1) {
				if (f < 8)
					std::cerr << "FAIL vramp g=" << g << " py=" << py << " got "
					          << int(s.top.pix0) << "/" << int(s.top.pix1) << " exp " << o0
					          << "/" << o1 << " ph_y=" << int(s.top.phase_y) << "\n";
				++f;
			}
			++checked;
		}
	}
	// Edge: last glass line must use src y floor 539, not 544
	s.sampleGroup(0, 719, Pat::VRamp, 0);
	if (int(s.top.store_y0) != 539) {
		std::cerr << "FAIL vramp edge store_y0 want 539 got " << int(s.top.store_y0) << "\n";
		++f;
	}
	if (int(s.top.store_y1) != 539) {
		// ceil clamped at last
		std::cerr << "FAIL vramp edge store_y1 want 539 got " << int(s.top.store_y1) << "\n";
		++f;
	}
	// Top edge phase0 pure
	s.sampleGroup(0, 0, Pat::VRamp, 0);
	if (int(s.top.phase_y) != 0 || int(s.top.wy0) != 256) {
		std::cerr << "FAIL vramp top phase/wy\n";
		++f;
	}
	// Discriminant: py=1 → phase 3, weights 64/192
	s.sampleGroup(0, 1, Pat::VRamp, 0);
	if (int(s.top.phase_y) != 3 || int(s.top.wy0) != 64 || int(s.top.wy1) != 192) {
		std::cerr << "FAIL vramp py1 phase3 weights got ph=" << int(s.top.phase_y)
		          << " w=" << int(s.top.wy0) << "/" << int(s.top.wy1) << "\n";
		++f;
	}
	std::cout << "CASE scale43_2ppc_vramp EXECUTED checked=" << checked
	          << " max_abs=" << max_abs << " fails=" << f << "\n";
	if (f || max_abs)
		return 1;
	std::cout << "PASS scale43_2ppc V-ramp+edge oracle max_abs=0\n";
	return 0;
}

int runHv() {
	Sim s;
	s.resetCycles();
	int f = 0;
	int checked = 0;
	for (int g = 0; g < 128; g += 2) {
		for (int py = 0; py < 32; ++py) {
			s.sampleGroup(g, py, Pat::HV, 0);
			const int o0 = oraclePix(Pat::HV, g, py, 0, false);
			const int o1 = oraclePix(Pat::HV, g + 1, py, 0, false);
			if (int(s.top.pix0) != o0 || int(s.top.pix1) != o1) {
				if (f < 6)
					std::cerr << "FAIL hv g=" << g << " py=" << py << "\n";
				++f;
			}
			++checked;
		}
	}
	std::cout << "CASE scale43_2ppc_hv EXECUTED checked=" << checked << " fails=" << f << "\n";
	if (f)
		return 1;
	std::cout << "PASS scale43_2ppc HV oracle\n";
	return 0;
}

int runReqComb() {
	// Prove req_* is comb with hc (same cycle), not only registered diag.
	Sim s;
	s.resetCycles();
	int f = 0;
	// Drive without completing pipeline — inspect req after eval with ce=0
	int base = 0, y0 = 0, y1 = 0;
	Sim::hostReq(2, 1, base, y0, y1);
	s.top.hc_g = 2;
	s.top.py = 1;
	s.top.in_content = 1;
	s.driveSrcWindow(Pat::HRamp, base, y0, y1, 0);
	s.top.ce_pix = 0;
	s.top.eval(); // comb only
	if (int(s.top.req_tap_base_x) != base) {
		std::cerr << "FAIL req comb base got " << int(s.top.req_tap_base_x) << " exp " << base
		          << "\n";
		++f;
	}
	if (int(s.top.req_y0) != y0 || int(s.top.req_y1) != y1) {
		std::cerr << "FAIL req comb y got " << int(s.top.req_y0) << "/" << int(s.top.req_y1)
		          << " exp " << y0 << "/" << y1 << "\n";
		++f;
	}
	if (!int(s.top.req_valid)) {
		std::cerr << "FAIL req_valid\n";
		++f;
	}
	// Registered diag must NOT yet show this group (still old/zero)
	// After reset, registered is 0 — req is 1 for g=2
	if (int(s.top.req_tap_base_x) == int(s.top.tap_base_x) && base != 0) {
		// If equal only when both 0; for g=2 base=1, registered should still be 0
		if (int(s.top.tap_base_x) == base) {
			std::cerr << "FAIL: registered tap_base already equals req (no latency split)\n";
			++f;
		}
	}
	std::cout << "CASE scale43_2ppc_req EXECUTED req_base=" << int(s.top.req_tap_base_x)
	          << " reg_base=" << int(s.top.tap_base_x) << " req_y=" << int(s.top.req_y0) << "/"
	          << int(s.top.req_y1) << " fails=" << f << "\n";
	if (f)
		return 1;
	std::cout << "PASS scale43_2ppc comb req_* vs registered diag\n";
	return 0;
}

int runFaultDiscriminant() {
	Sim s;
	s.resetCycles();
	s.sampleGroup(0, 0, Pat::HRamp, 0);
	const int o1 = oraclePix(Pat::HRamp, 1, 0, 0, false);
	const int b1 = oraclePix(Pat::HRamp, 1, 0, 0, true);
	const int got1 = int(s.top.pix1);
	const int ph1 = int(s.top.phase_x1);
	std::cout << "CASE scale43_2ppc_fault EXECUTED pix1=" << got1 << " oracle=" << o1
	          << " bug_oracle=" << b1 << " ph1=" << ph1 << " w=" << int(s.top.wx0_b) << "/"
	          << int(s.top.wx1_b) << "\n";
	if (o1 == b1) {
		std::cerr << "FAIL test blind: good==bug oracle\n";
		return 1;
	}
	if (ph1 != 3) {
		std::cerr << "FAIL scale43_2ppc: phase_x1 want 3 got " << ph1 << "\n";
		return 1;
	}
	if (got1 != o1) {
		std::cerr << "FAIL scale43_2ppc: pix1 want " << o1 << " got " << got1 << "\n";
		return 1;
	}
	std::cout << "PASS scale43_2ppc discriminant o1!=b1 product=oracle\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = std::getenv("SCALE43_2PPC_MODE");
	std::string m = mode ? mode : "all";
	int rc = 0;
	if (m == "const" || m == "all")
		rc |= runConstant();
	if (m == "ramp" || m == "all")
		rc |= runRampH();
	if (m == "vramp" || m == "all")
		rc |= runRampV();
	if (m == "hv" || m == "all")
		rc |= runHv();
	if (m == "req" || m == "all")
		rc |= runReqComb();
	if (m == "fault" || m == "all")
		rc |= runFaultDiscriminant();
	if (m != "const" && m != "ramp" && m != "vramp" && m != "hv" && m != "req" && m != "fault" &&
	    m != "all") {
		std::cerr << "unknown SCALE43_2PPC_MODE\n";
		return 2;
	}
	return rc;
}
