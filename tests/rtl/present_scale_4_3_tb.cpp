// Red-before-green for present_scale_4_3 (product 960×540 → 1280×720).
// A) endpoints + phase ROM + src=dst*3/4
// B) phase sequence 0,1,2,3 and weights
// C) NEG: mid must not be identity (639)
// FAULT builds: INVERT and PHASE_OBO must fail product checks.
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
	s.sample(3, 0);
	const int ph3 = int(s.top.phase_x);
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
	exp(x0 == 0 && x_last == 959, "H endpoints 0..959");
	exp(y_last == 539, "V endpoint 539");
	exp(xs.size() == 960u && ys.size() == 540u, "unique covers source");
	exp(ph0 == 0 && ph1 == 1 && ph2 == 2 && ph3 == 3, "phase sequence 0..3");
	exp(w00 == 255 && w01 == 0, "phase0 pure NN weights");
	exp(w10 == 192 && w11 == 64, "phase1 3:1 weights");
	exp(x1s == src4_3(1), "src(1)=0");
	exp(x_last == src4_3(1279), "src(1279)=959");
	exp(x_mid == src4_3(639), "mid x = 639*3/4");
	exp(y_mid == src4_3(359), "mid y = 359*3/4");
	// Identity would keep x_mid=639; inverted *4/4 keeps near glass.
	exp(x_mid != 639, "not identity glass map");
	exp(x_mid == 479, "4/3 mid x=479");
	// Spot-check more phases
	for (int hc = 0; hc < 16; ++hc) {
		s.sample(hc, 0);
		exp(int(s.top.store_x) == src4_3(hc), "src=hc*3/4 row");
		exp(int(s.top.phase_x) == (hc & 3), "phase=hc[1:0]");
	}
	if (f)
		return 1;
	std::cout << "PASS present_scale_4_3 product 960x540→1280x720\n";
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
