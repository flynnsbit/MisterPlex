// Red-before-green for PRESENT_WINDOW_BILINEAR filter path.
// A) frac=0 → out == p00 (NN-equivalent)
// B) frac_x=128, fy=0 → mid between p00 and p10
// C) PMS 720×404→1280×720: x1==x0+1 interior; last col x1==x0 frac=0
// D) NEG: if lerp ignored p10 (always p00), mid fails
// true rc direct.

#include "Vpresent_bilinear_tb.h"
#include "verilated.h"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

namespace {

struct Sim {
	Vpresent_bilinear_tb top{};

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

	void settle(int n = 4) {
		top.ce_pix = 0;
		for (int i = 0; i < n; ++i)
			tick();
	}

	void sample(int hc, int py, int hde, int vde) {
		top.hc = hc & 0x7ff;
		top.py = py & 0x7ff;
		top.in_content = (hc < hde && py < vde) ? 1 : 0;
		top.ce_pix = 1;
		tick();
		top.ce_pix = 0;
		tick(); // lerp registers one ce later aligned with window
		top.ce_pix = 1;
		tick();
		top.ce_pix = 0;
		tick();
	}
};

int expectNear(int got, int exp, int tol, const char* msg) {
	if (std::abs(got - exp) > tol) {
		std::cerr << "FAIL " << msg << " got=" << got << " exp=" << exp << "\n";
		return 1;
	}
	return 0;
}

// Host model matching present_bilinear_lerp >>16 approx.
int lerpHost(int p00, int p10, int p01, int p11, int fx, int fy) {
	const int wx0 = 255 - fx, wy0 = 255 - fy;
	const int w00 = wx0 * wy0, w10 = fx * wy0, w01 = wx0 * fy, w11 = fx * fy;
	const int64_t acc = int64_t(w00) * p00 + int64_t(w10) * p10 + int64_t(w01) * p01 +
	                    int64_t(w11) * p11 + 32768;
	return int((acc >> 16) & 255);
}

int runNnEquiv() {
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = 720;
	s.top.content_h = 404;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = 1280;
	s.top.v_de = 720;
	s.top.p00 = 10;
	s.top.p10 = 200;
	s.top.p01 = 30;
	s.top.p11 = 220;
	s.resetCycles();
	s.settle();
	// Last DE pixel: frac forced 0 → pure p00
	s.sample(1279, 719, 1280, 720);
	std::cout << "CASE nn_equiv EXECUTED out=" << int(s.top.out_pix)
	          << " fx=" << int(s.top.frac_x) << " fy=" << int(s.top.frac_y)
	          << " x=" << int(s.top.store_x) << " x1=" << int(s.top.store_x1) << "\n";
	int f = 0;
	f += expectNear(int(s.top.frac_x), 0, 0, "last fx=0");
	f += expectNear(int(s.top.frac_y), 0, 0, "last fy=0");
	f += expectNear(int(s.top.store_x1), int(s.top.store_x), 0, "last x1==x0");
	f += expectNear(int(s.top.out_pix), 10, 0, "last out==p00");
	if (f)
		return 1;
	std::cout << "PASS bilinear nn_equiv at edge\n";
	return 0;
}

int runMidLerp() {
	// Force known fracs via synthetic taps at interior DE where fx!=0.
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = 720;
	s.top.content_h = 404;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = 1280;
	s.top.v_de = 720;
	s.top.p00 = 0;
	s.top.p10 = 255;
	s.top.p01 = 0;
	s.top.p11 = 255;
	s.resetCycles();
	s.settle();
	// Scan for a sample with frac_x in [64,192]
	int found = 0, out = 0, fx = 0, fy = 0, x = 0, x1 = 0;
	for (int hc = 1; hc < 1279; ++hc) {
		s.sample(hc, 100, 1280, 720);
		fx = int(s.top.frac_x);
		fy = int(s.top.frac_y);
		if (fx >= 64 && fx <= 192) {
			found = 1;
			out = int(s.top.out_pix);
			x = int(s.top.store_x);
			x1 = int(s.top.store_x1);
			break;
		}
	}
	std::cout << "CASE mid_lerp EXECUTED found=" << found << " fx=" << fx
	          << " fy=" << fy << " out=" << out << " x=" << x << " x1=" << x1 << "\n";
	if (!found) {
		std::cerr << "FAIL mid_lerp: no interior frac_x in band (scale dead?)\n";
		return 1;
	}
	if (x1 != x + 1 && x1 != x) {
		std::cerr << "FAIL mid_lerp: x1 not x or x+1\n";
		return 1;
	}
	if (x1 == x + 1 && fx == 0) {
		std::cerr << "FAIL mid_lerp: x1 advanced but fx=0\n";
		return 1;
	}
	const int exp = lerpHost(0, 255, 0, 255, fx, fy);
	if (expectNear(out, exp, 1, "mid lerp vs host"))
		return 1;
	// NEG discriminator: pure NN would always emit p00=0 when fy small and...
	// With p00=0 p10=255 and fx>=64, out must be >> 0.
	if (out < 40) {
		std::cerr << "FAIL mid_lerp: out too close to p00 (lerp not mixing p10)\n";
		return 1;
	}
	std::cout << "PASS bilinear mid_lerp out=" << out << " exp≈" << exp << "\n";
	return 0;
}

int runProduct540Bilinear() {
	// Ship path 960×540 → 1280×720 @ ~4/3: bilinear must mix (NN alone shimmers).
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = 960;
	s.top.content_h = 540;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = 1280;
	s.top.v_de = 720;
	s.top.p00 = 0;
	s.top.p10 = 255;
	s.top.p01 = 0;
	s.top.p11 = 255;
	s.resetCycles();
	s.settle();
	int found = 0, out = 0, fx = 0, x = 0, x1 = 0;
	for (int hc = 1; hc < 1279; ++hc) {
		s.sample(hc, 270, 1280, 720);
		fx = int(s.top.frac_x);
		if (fx >= 40 && fx <= 220) {
			found = 1;
			out = int(s.top.out_pix);
			x = int(s.top.store_x);
			x1 = int(s.top.store_x1);
			break;
		}
	}
	std::cout << "CASE product540_bil EXECUTED found=" << found << " fx=" << fx
	          << " out=" << out << " x=" << x << " x1=" << x1 << "\n";
	if (!found) {
		std::cerr << "FAIL product540_bil: no interior frac (4/3 scale dead)\n";
		return 1;
	}
	if (x1 != x + 1 && !(x1 == x && fx == 0)) {
		std::cerr << "FAIL product540_bil: bad x1\n";
		return 1;
	}
	const int exp = lerpHost(0, 255, 0, 255, fx, int(s.top.frac_y));
	if (expectNear(out, exp, 1, "product540 bil lerp"))
		return 1;
	if (out < 30) {
		std::cerr << "FAIL product540_bil: no p10 mix (NN shimmer class)\n";
		return 1;
	}
	// Endpoints still cover content
	s.sample(0, 0, 1280, 720);
	if (int(s.top.store_x) != 0) {
		std::cerr << "FAIL product540_bil: x0\n";
		return 1;
	}
	s.sample(1279, 719, 1280, 720);
	if (int(s.top.store_x) != 959 || int(s.top.store_y) != 539) {
		std::cerr << "FAIL product540_bil: last 959,539 got " << int(s.top.store_x)
		          << "," << int(s.top.store_y) << "\n";
		return 1;
	}
	std::cout << "PASS bilinear product540 960x540→720p\n";
	return 0;
}

int runNegNnOnly() {
	// Same setup: if implementation ignored p10 (NN-only bug under bilinear build),
	// out stays near 0. Product must mix.
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = 720;
	s.top.content_h = 404;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = 1280;
	s.top.v_de = 720;
	s.top.p00 = 0;
	s.top.p10 = 255;
	s.top.p01 = 0;
	s.top.p11 = 255;
	s.resetCycles();
	s.settle();
	int max_out = 0, max_fx = 0;
	for (int hc = 0; hc < 1280; hc += 3) {
		s.sample(hc, 200, 1280, 720);
		if (int(s.top.out_pix) > max_out) {
			max_out = int(s.top.out_pix);
			max_fx = int(s.top.frac_x);
		}
	}
	std::cout << "CASE neg_nn_only EXECUTED max_out=" << max_out << " at_fx≈" << max_fx
	          << "\n";
	if (max_out < 80) {
		std::cerr << "FAIL neg_nn_only: bilinear never mixed p10 (looks NN-stuck)\n";
		return 1;
	}
	std::cout << "PASS neg_nn_only discriminator (lerp mixes)\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = std::getenv("BILINEAR_MODE");
	std::string m = mode ? mode : "all";
	int rc = 0;
	if (m == "nn_equiv" || m == "all")
		rc |= runNnEquiv();
	if (m == "mid_lerp" || m == "all")
		rc |= runMidLerp();
	if (m == "product540" || m == "all")
		rc |= runProduct540Bilinear();
	if (m == "neg_nn_only" || m == "all")
		rc |= runNegNnOnly();
	if (m != "nn_equiv" && m != "mid_lerp" && m != "product540" && m != "neg_nn_only" &&
	    m != "all") {
		std::cerr << "unknown BILINEAR_MODE\n";
		return 2;
	}
	return rc;
}
