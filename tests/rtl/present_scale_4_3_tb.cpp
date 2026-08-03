// Red-before-green for present_scale_4_3 (product 960×540 → 1280×720).
// A) endpoints + src=floor(dst*3/4)
// B) phase = (3*dst) mod 4 → sequence **0,3,2,1** (NOT dst mod 4 = 0,1,2,3)
// C) NEG: mid must not be identity (639)
// FAULT PHASE_DST / PHASE_OBO: phase=dst[1:0] must FAIL oracle phase checks.
// true rc direct.

#include "Vpresent_scale_4_3_tb.h"
#include "verilated.h"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <set>
#include <string>

namespace {

struct Sim {
	Vpresent_scale_4_3_tb top{};
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
	void sample(int hc, int py) {
		top.hc = hc & 0x7ff;
		top.py = py & 0x7ff;
		top.in_content = (hc < 1280 && py < 720) ? 1 : 0;
		top.ce_pix = 1;
		tick();
		top.ce_pix = 0;
		tick();
	}
};

int src4_3(int dst) { return (dst * 3) / 4; }
// Independent oracle: frac phase of floor(3·dst/4) is (3·dst) mod 4.
int phase4_3(int dst) { return (dst * 3) & 3; }
// Buggy phase (what FAULT_PHASE_DST implements).
int phaseDstMod4(int dst) { return dst & 3; }

// ROM weights for phase index (frac = phase/4).
void weightsForPhase(int ph, int& w0, int& w1) {
	switch (ph & 3) {
	case 0: w0 = 256; w1 = 0; break;
	case 1: w0 = 192; w1 = 64; break;
	case 2: w0 = 128; w1 = 128; break;
	default: w0 = 64; w1 = 192; break;
	}
}

int runProduct() {
	Sim s;
	s.resetCycles();
	std::set<int> xs, ys;
	for (int hc = 0; hc < 1280; ++hc) {
		s.sample(hc, 0);
		xs.insert(int(s.top.store_x));
	}
	for (int py = 0; py < 720; ++py) {
		s.sample(0, py);
		ys.insert(int(s.top.store_y));
	}
	s.sample(0, 0);
	const int x0 = int(s.top.store_x);
	const int ph0 = int(s.top.phase_x);
	const int w00 = int(s.top.wx0);
	const int w01 = int(s.top.wx1);
	s.sample(1, 0);
	const int x1s = int(s.top.store_x);
	const int ph1 = int(s.top.phase_x);
	const int w10 = int(s.top.wx0);
	const int w11 = int(s.top.wx1);
	s.sample(2, 0);
	const int ph2 = int(s.top.phase_x);
	const int w20 = int(s.top.wx0);
	const int w21 = int(s.top.wx1);
	s.sample(3, 0);
	const int ph3 = int(s.top.phase_x);
	const int w30 = int(s.top.wx0);
	const int w31 = int(s.top.wx1);
	s.sample(1279, 719);
	const int x_last = int(s.top.store_x);
	const int y_last = int(s.top.store_y);
	s.sample(639, 359);
	const int x_mid = int(s.top.store_x);
	const int y_mid = int(s.top.store_y);

	std::cout << "CASE scale43_product EXECUTED unique_x=" << xs.size()
	          << " unique_y=" << ys.size() << " x0=" << x0 << " x_last=" << x_last
	          << " y_last=" << y_last << " x_mid=" << x_mid << " y_mid=" << y_mid
	          << " ph=" << ph0 << ph1 << ph2 << ph3 << " w0@0=" << w00 << "/" << w01
	          << " w@1=" << w10 << "/" << w11 << " x@1=" << x1s << "\n";

	int f = 0;
	auto exp = [&](bool c, const char* m) {
		if (!c) {
			std::cerr << "FAIL scale43: " << m << "\n";
			++f;
		}
	};
	// Structural: correct oracle ≠ dst-mod-4 (else test cannot catch the bug).
	exp(phase4_3(0) == 0 && phase4_3(1) == 3 && phase4_3(2) == 2 && phase4_3(3) == 1,
	    "oracle phase seq 0,3,2,1");
	exp(phaseDstMod4(1) == 1 && phaseDstMod4(1) != phase4_3(1),
	    "oracle disagrees dst-mod4 at dst=1 (test can fail buggy RTL)");

	exp(x0 == 0 && x_last == 959, "H endpoints 0..959");
	exp(y_last == 539, "V endpoint 539");
	exp(xs.size() == 960u && ys.size() == 540u, "unique covers source");
	// Correct phase walk: 0,3,2,1 — NOT 0,1,2,3
	exp(ph0 == 0 && ph1 == 3 && ph2 == 2 && ph3 == 1, "phase sequence 0,3,2,1");
	exp(w00 == 256 && w01 == 0, "dst0 phase0 pure NN 256/0");
	exp(w00 + w01 == 256 && w10 + w11 == 256 && w20 + w21 == 256 && w30 + w31 == 256, "all phase weights sum 256");
	// dst=1 → phase 3 → weights 64/192 (frac 3/4), NOT 192/64
	exp(w10 == 64 && w11 == 192, "dst1 phase3 weights 1:3");
	exp(w20 == 128 && w21 == 128, "dst2 phase2 weights 1:1");
	exp(w30 == 192 && w31 == 64, "dst3 phase1 weights 3:1");
	exp(x1s == src4_3(1), "src(1)=0");
	exp(x_last == src4_3(1279), "src(1279)=959");
	exp(x_mid == src4_3(639), "mid x = 639*3/4");
	exp(y_mid == src4_3(359), "mid y = 359*3/4");
	exp(x_mid != 639, "not identity glass map");
	exp(x_mid == 479, "4/3 mid x=479");
	// Full oracle: src + phase + weights H and V
	for (int hc = 0; hc < 64; ++hc) {
		s.sample(hc, 0);
		const int ph = phase4_3(hc);
		int ew0 = 0, ew1 = 0;
		weightsForPhase(ph, ew0, ew1);
		exp(int(s.top.store_x) == src4_3(hc), "src=floor(hc*3/4)");
		exp(int(s.top.phase_x) == ph, "phase_x=(3*hc)mod4");
		exp(int(s.top.wx0) == ew0 && int(s.top.wx1) == ew1, "wx ROM vs oracle");
	}
	for (int py = 0; py < 64; ++py) {
		s.sample(0, py);
		const int ph = phase4_3(py);
		int ew0 = 0, ew1 = 0;
		weightsForPhase(ph, ew0, ew1);
		exp(int(s.top.store_y) == src4_3(py), "src_y=floor(py*3/4)");
		exp(int(s.top.phase_y) == ph, "phase_y=(3*py)mod4");
		exp(int(s.top.wy0) == ew0 && int(s.top.wy1) == ew1, "wy ROM vs oracle");
	}
	if (f)
		return 1;
	std::cout << "PASS present_scale_4_3 product 960x540→1280x720 oracle_phase=0,3,2,1\n";
	return 0;
}

int runNegIdentity() {
	Sim s;
	s.resetCycles();
	s.sample(639, 0);
	const int x = int(s.top.store_x);
	std::cout << "CASE scale43_neg EXECUTED x_mid=" << x << " identity_would=639\n";
	if (x == 639) {
		std::cerr << "FAIL neg: identity (invert fault or broken 4/3)\n";
		return 1;
	}
	if (x != 479) {
		std::cerr << "FAIL neg: expected 479 got " << x << "\n";
		return 1;
	}
	std::cout << "PASS scale43 neg not-identity mid=479\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = std::getenv("SCALE43_MODE");
	std::string m = mode ? mode : "all";
	int rc = 0;
	if (m == "product" || m == "all")
		rc |= runProduct();
	if (m == "neg" || m == "all")
		rc |= runNegIdentity();
	if (m != "product" && m != "neg" && m != "all") {
		std::cerr << "unknown SCALE43_MODE\n";
		return 2;
	}
	return rc;
}
