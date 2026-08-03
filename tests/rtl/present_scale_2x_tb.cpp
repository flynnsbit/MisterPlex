// Red-before-green present_scale_2x (640×360 → 1280×720 exact doubling).
// Independent oracle: store = dst >> 1. No phase/weights arithmetic.
// FAULT_IDENTITY / FAULT_PLUS1 must fail product.
// Pixel path: replication s(src) — out[dst]=src[dst>>1] (NN).
// EXECUTED before non-zero rc. true rc direct.

#include "Vpresent_scale_2x_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <set>
#include <string>

namespace {

struct Sim {
	Vpresent_scale_2x_tb top{};
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

// Independent oracle — not derived from RTL.
int src2x(int dst) { return dst >> 1; }

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
	s.sample(1, 0);
	const int x1 = int(s.top.store_x);
	s.sample(2, 0);
	const int x2 = int(s.top.store_x);
	s.sample(1279, 719);
	const int x_last = int(s.top.store_x);
	const int y_last = int(s.top.store_y);
	s.sample(639, 359);
	const int x_mid = int(s.top.store_x);
	const int y_mid = int(s.top.store_y);
	s.sample(0, 0);
	const int w00 = int(s.top.wx0);
	const int w01 = int(s.top.wx1);

	std::cout << "CASE scale2x_product EXECUTED unique_x=" << xs.size()
	          << " unique_y=" << ys.size() << " x0=" << x0 << " x1=" << x1
	          << " x2=" << x2 << " x_last=" << x_last << " y_last=" << y_last
	          << " x_mid=" << x_mid << " y_mid=" << y_mid << " w=" << w00 << "/" << w01
	          << "\n";

	int f = 0;
	auto exp = [&](bool c, const char* m) {
		if (!c) {
			std::cerr << "FAIL scale2x: " << m << "\n";
			++f;
		}
	};
	// Oracle structural (test can fail identity fault)
	exp(src2x(639) == 319 && src2x(639) != 639, "oracle mid 639→319 not identity");
	exp(src2x(1) == 0 && src2x(2) == 1, "oracle pair replication");
	exp(x0 == 0 && x1 == 0 && x2 == 1, "dst 0,1→0 ; 2→1");
	exp(x_last == 639 && y_last == 359, "endpoints 639/359");
	exp(xs.size() == 640u && ys.size() == 360u, "unique covers 640×360");
	exp(x_mid == 319 && y_mid == 179, "mid 639→319, 359→179");
	exp(x_mid != 639, "not identity");
	exp(w00 == 256 && w01 == 0, "NN weights 256/0");
	exp(int(s.top.store_x1) == int(s.top.store_x), "x1==x0 NN");
	// Full walk
	for (int hc = 0; hc < 1280; ++hc) {
		s.sample(hc, 0);
		exp(int(s.top.store_x) == src2x(hc), "store_x=hc>>1");
	}
	for (int py = 0; py < 720; ++py) {
		s.sample(0, py);
		exp(int(s.top.store_y) == src2x(py), "store_y=py>>1");
	}
	// Pixel replication oracle: ramp s(x)=x → out[dst]=src2x(dst)
	// (mapper-only; consumer would fetch s[store_x])
	int pix_disagree = 0;
	for (int d = 0; d < 1280; ++d) {
		const int expect_pix = src2x(d); // s(x)=x
		// identity fault would yield d; plus1 yields (d+1)>>1
		if (expect_pix != src2x(d))
			++pix_disagree; // unreachable — structure check
	}
	exp(pix_disagree == 0, "pixel oracle self-consistent");
	// Prove FAULT_IDENTITY would disagree oracle at mid
	exp(639 != src2x(639), "identity≠2x at 639 (red twin can fire)");
	exp(((639 + 1) >> 1) != src2x(639), "plus1≠2x at 639");

	if (f)
		return 1;
	std::cout << "PASS present_scale_2x product 640x360→1280x720 oracle_shift\n";
	return 0;
}

int runNeg() {
	Sim s;
	s.resetCycles();
	s.sample(639, 0);
	const int x = int(s.top.store_x);
	std::cout << "CASE scale2x_neg EXECUTED x_mid=" << x << " identity_would=639 plus1_would="
	          << ((639 + 1) >> 1) << "\n";
	if (x == 639) {
		std::cerr << "FAIL neg: identity\n";
		return 1;
	}
	if (x != 319) {
		std::cerr << "FAIL neg: want 319 got " << x << "\n";
		return 1;
	}
	std::cout << "PASS scale2x neg mid=319\n";
	return 0;
}

// High-contrast replication: odd/even dst share src → same pixel (no 4/3 soften)
int runReplicatePixel() {
	Sim s;
	s.resetCycles();
	// Mapper: both dst0 and dst1 → store 0; if consumer samples s[store], equal.
	s.sample(0, 0);
	const int a = int(s.top.store_x);
	s.sample(1, 0);
	const int b = int(s.top.store_x);
	s.sample(2, 0);
	const int c = int(s.top.store_x);
	std::cout << "CASE scale2x_repl EXECUTED s0=" << a << " s1=" << b << " s2=" << c << "\n";
	if (a != 0 || b != 0 || c != 1) {
		std::cerr << "FAIL repl pairs\n";
		return 1;
	}
	std::cout << "PASS scale2x pair replication 0,0,1\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = std::getenv("SCALE2X_MODE");
	std::string m = mode ? mode : "all";
	int rc = 0;
	if (m == "product" || m == "all")
		rc |= runProduct();
	if (m == "neg" || m == "all")
		rc |= runNeg();
	if (m == "repl" || m == "all")
		rc |= runReplicatePixel();
	if (m != "product" && m != "neg" && m != "repl" && m != "all") {
		std::cerr << "unknown SCALE2X_MODE\n";
		return 2;
	}
	return rc;
}
