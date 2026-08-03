// Integrated 2-PPC 4/3 scaler — pixel oracle (not coords-only).
//
// A) constant frame → pix0==pix1==C (sum-256 exact)
// B) H ramp s(x)=x on both lines → independent bilin oracle per dst
// C) pair {2,3} needs 3 unique H taps (span store_x1_b - tap_base == 2)
// D) RED FAULT_PHASE_DST: dst1 weights swap → pixel disagrees oracle
//
// EXECUTED before non-zero rc accepted by harness script.
// true rc direct.

#include "Vpresent_scale_4_3_2ppc_tb.h"
#include "verilated.h"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr int SRC_W = 960;
constexpr int SRC_H = 540;
constexpr int DST_W = 1280;

int src43(int dst) { return (dst * 3) / 4; }
int phase43(int dst) { return (dst * 3) & 3; }
int phaseDstBug(int dst) { return dst & 3; }

void wrom(int ph, int& w0, int& w1) {
	static const int W0[4] = {256, 192, 128, 64};
	static const int W1[4] = {0, 64, 128, 192};
	w0 = W0[ph & 3];
	w1 = W1[ph & 3];
}

// Independent 2-tap H then V, sum-256, round >>8.
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

// Synthetic source. HRamp saturates at 255 so s0/s1 stay ordered (no wrap).
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
	const int p00 = srcVal(p, s0, t0, c);
	const int p10 = srcVal(p, s1, t0, c);
	const int p01 = srcVal(p, s0, t1, c);
	const int p11 = srcVal(p, s1, t1, c);
	return bilin256(p00, p10, p01, p11, wx0, wx1, wy0, wy1);
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
		for (int i = 0; i < n; ++i)
			tick();
		top.reset = 0;
		tick();
	}

	void driveTaps(Pat p, int base_x, int y0, int y1, int c) {
		top.tap_y0_0 = srcVal(p, base_x + 0, y0, c);
		top.tap_y0_1 = srcVal(p, base_x + 1, y0, c);
		top.tap_y0_2 = srcVal(p, base_x + 2, y0, c);
		top.tap_y0_3 = srcVal(p, base_x + 3, y0, c);
		top.tap_y1_0 = srcVal(p, base_x + 0, y1, c);
		top.tap_y1_1 = srcVal(p, base_x + 1, y1, c);
		top.tap_y1_2 = srcVal(p, base_x + 2, y1, c);
		top.tap_y1_3 = srcVal(p, base_x + 3, y1, c);
	}

	// One group sample: need base_x before drive — compute host-side.
	void sampleGroup(int hc_g, int py, Pat p, int c) {
		const int hc0 = hc_g & ~1;
		const int s0 = src43(hc0);
		const int s1 = src43(hc0 + 1);
		const int base = (s0 <= s1) ? s0 : s1;
		const int y0 = src43(py);
		const int y1 = (y0 >= SRC_H - 1) ? y0 : y0 + 1;
		top.hc_g = hc0 & 0x7ff;
		top.py = py & 0x7ff;
		top.in_content = (hc0 < DST_W && py < 720) ? 1 : 0;
		driveTaps(p, base, y0, y1, c);
		top.ce_pix = 1;
		tick();
		top.ce_pix = 0;
		tick();
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
	// Sweep several groups including 3-tap pairs
	for (int g = 0; g < 64; g += 2) {
		for (int py : {0, 1, 2, 3, 100, 359}) {
			s.sampleGroup(g, py, Pat::Const, C);
			exp(int(s.top.pix0) == C, "pix0 constant");
			exp(int(s.top.pix1) == C, "pix1 constant");
			exp(int(s.top.wx0_a) + int(s.top.wx1_a) == 256, "wx sum 256 a");
			exp(int(s.top.wx0_b) + int(s.top.wx1_b) == 256, "wx sum 256 b");
			exp(int(s.top.wy0) + int(s.top.wy1) == 256, "wy sum 256");
		}
	}
	std::cout << "CASE scale43_2ppc_const EXECUTED C=0xA5 groups=32 pyset=6 fails=" << f
	          << "\n";
	if (f)
		return 1;
	std::cout << "PASS scale43_2ppc constant-color sum256\n";
	return 0;
}

int runRamp() {
	Sim s;
	s.resetCycles();
	int f = 0;
	auto exp = [&](bool c, const char* m) {
		if (!c) {
			std::cerr << "FAIL ramp: " << m << "\n";
			++f;
		}
	};
	int checked = 0;
	int max_abs = 0;
	// Full product width groups at several py
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
			if (d0 != 0 || d1 != 0) {
				if (f < 8) {
					std::cerr << "FAIL ramp g=" << g << " py=" << py << " pix0=" << int(s.top.pix0)
					          << " o0=" << o0 << " pix1=" << int(s.top.pix1) << " o1=" << o1
					          << " ph=" << int(s.top.phase_x0) << int(s.top.phase_x1) << "\n";
				}
				++f;
			}
			++checked;
			// Interior only: right edge clamps ceil→floor so span shrinks.
			if (int(s.top.tap_base_x) + 2 <= SRC_W - 1) {
				const int span = int(s.top.store_x1_b) - int(s.top.tap_base_x);
				if ((g & 3) == 2)
					exp(span == 2, "3-tap pair span==2 interior");
				if ((g & 3) == 0)
					exp(span == 1, "2-tap pair span==1 interior");
			}
		}
	}
	// Phase sequence on group 0: pix sides phases 0 and 3
	s.sampleGroup(0, 0, Pat::HRamp, 0);
	exp(int(s.top.phase_x0) == 0 && int(s.top.phase_x1) == 3, "group0 phases 0,3");
	exp(int(s.top.wx0_a) == 256 && int(s.top.wx1_a) == 0, "g0a NN 256/0");
	exp(int(s.top.wx0_b) == 64 && int(s.top.wx1_b) == 192, "g0b 64/192");
	s.sampleGroup(2, 0, Pat::HRamp, 0);
	exp(int(s.top.phase_x0) == 2 && int(s.top.phase_x1) == 1, "group2 phases 2,1");

	std::cout << "CASE scale43_2ppc_ramp EXECUTED checked=" << checked
	          << " max_abs=" << max_abs << " fails=" << f << "\n";
	if (f)
		return 1;
	if (max_abs != 0)
		return 1;
	std::cout << "PASS scale43_2ppc H-ramp oracle max_abs=0\n";
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

// Proves the harness can go red: good oracle ≠ bug oracle at dst1, and product
// RTL matches good. Under +define FAULT_PHASE_DST, pix1 tracks bug → rc≠0.
int runFaultDiscriminant() {
	Sim s;
	s.resetCycles();
	s.sampleGroup(0, 0, Pat::HRamp, 0);
	const int o1 = oraclePix(Pat::HRamp, 1, 0, 0, /*useBugPhase=*/false);
	const int b1 = oraclePix(Pat::HRamp, 1, 0, 0, /*useBugPhase=*/true);
	const int got1 = int(s.top.pix1);
	const int ph1 = int(s.top.phase_x1);
	std::cout << "CASE scale43_2ppc_fault EXECUTED pix1=" << got1 << " oracle=" << o1
	          << " bug_oracle=" << b1 << " ph1=" << ph1 << " w=" << int(s.top.wx0_b) << "/"
	          << int(s.top.wx1_b) << "\n";
	if (o1 == b1) {
		std::cerr << "FAIL test blind: good==bug oracle at dst1 (cannot RED)\n";
		return 1;
	}
	// Product expectations (fail under FAULT_PHASE_DST RTL):
	if (ph1 != 3) {
		std::cerr << "FAIL scale43_2ppc: phase_x1 want 3 got " << ph1 << "\n";
		return 1;
	}
	if (got1 != o1) {
		std::cerr << "FAIL scale43_2ppc: pix1 want oracle " << o1 << " got " << got1 << "\n";
		return 1;
	}
	if (got1 == b1) {
		std::cerr << "FAIL scale43_2ppc: pix1 matches bug oracle (phase dst-mod4)\n";
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
		rc |= runRamp();
	if (m == "hv" || m == "all")
		rc |= runHv();
	if (m == "fault" || m == "all")
		rc |= runFaultDiscriminant();
	if (m != "const" && m != "ramp" && m != "hv" && m != "fault" && m != "all") {
		std::cerr << "unknown SCALE43_2PPC_MODE\n";
		return 2;
	}
	return rc;
}
