// Red-before-green gate for fabric content window (present_content_window).
//
// A) FIXED/legacy map (win_enable=0, FRAME 640x480 scales):
//    DE samples as if full bank — unique store_x spans past 319.
//    Asserting "full 320 content stretch" MUST FAIL (quarter-size class).
// B) WINDOW map (win_enable=1, content 320x240 @ 0,0):
//    unique store_x = 320 (0..319), unique store_y = 240 (0..239).
//    hc last → 319, py last → 239. MUST PASS.
//
// A test that passes both ways is worthless. Shell drives MODE=legacy|window.
// true rc direct.

#include "Vpresent_content_window_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <set>
#include <string>

namespace {

constexpr int kHDe = 529;
constexpr int kVDe = 480;
constexpr int kFrameW = 640;
constexpr int kFrameH = 480;

struct Sim {
	Vpresent_content_window_tb top{};
	uint64_t t = 0;

	void tick() {
		top.clk = 0;
		top.eval();
		top.clk = 1;
		top.eval();
		++t;
	}

	void resetCycles(int n = 4) {
		top.reset = 1;
		top.ce_pix = 0;
		top.hc = 0;
		top.py = 0;
		top.in_content = 0;
		for (int i = 0; i < n; ++i)
			tick();
		top.reset = 0;
		tick();
	}

	// After changing window regs, burn a few cycles so sx_r/sy_r update
	// (scales register off the pixel path).
	void settleWindow(int n = 3) {
		top.ce_pix = 0;
		for (int i = 0; i < n; ++i)
			tick();
	}

	void sampleAt(int hc, int py) {
		top.hc = hc & 0x3ff;
		top.py = py & 0x3ff;
		top.in_content = (hc < kHDe && py < kVDe) ? 1 : 0;
		top.ce_pix = 1;
		tick();
		top.ce_pix = 0;
		tick(); // store_x/y register on ce_pix; read after edge
	}
};

int runLegacyQuarterClass() {
	// win_enable=0: SX/SY from FRAME 640x480. Content intent is 320 island
	// at origin, but scales still address 640 domain → samples past x=319.
	Sim s;
	s.top.win_enable = 0;
	s.top.content_w = 320;
	s.top.content_h = 240;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.resetCycles();
	s.settleWindow();

	std::set<int> xs, ys;
	for (int hc = 0; hc < kHDe; ++hc) {
		s.sampleAt(hc, 0);
		xs.insert(int(s.top.store_x));
	}
	for (int py = 0; py < kVDe; ++py) {
		s.sampleAt(0, py);
		ys.insert(int(s.top.store_y));
	}

	const int xmax = xs.empty() ? -1 : *xs.rbegin();
	const int ymax = ys.empty() ? -1 : *ys.rbegin();
	std::cout << "LEGACY unique_x=" << xs.size() << " max_x=" << xmax
	          << " unique_y=" << ys.size() << " max_y=" << ymax << "\n";

	// Host-math negative: pad-only / fixed scale samples >320 unique x and
	// reaches past content width 319. That is the quarter-size class.
	const bool quarter_class = (xs.size() > 320u) && (xmax > 319);
	if (!quarter_class) {
		std::cerr << "FAIL legacy: expected quarter-size class (unique_x>320 and max_x>319)\n";
		return 1;
	}

	// The "full 320 stretch" assertion MUST fail under legacy — prove it.
	const bool full_stretch =
	    (xs.size() == 320u) && (xmax == 319) && (ys.size() == 240u) && (ymax == 239);
	if (full_stretch) {
		std::cerr << "FAIL legacy: full 320 stretch must NOT hold under fixed FRAME map\n";
		return 1;
	}

	std::cout << "REPRO_OK legacy_fixed_map quarter_class=1 full_stretch=0\n";
	std::cout << "PASS race model legacy\n";
	return 0;
}

int runWindowPass() {
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = 320;
	s.top.content_h = 240;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.resetCycles();
	s.settleWindow();

	std::set<int> xs, ys;
	for (int hc = 0; hc < kHDe; ++hc) {
		s.sampleAt(hc, 0);
		xs.insert(int(s.top.store_x));
	}
	for (int py = 0; py < kVDe; ++py) {
		s.sampleAt(0, py);
		ys.insert(int(s.top.store_y));
	}

	s.sampleAt(0, 0);
	const int x0 = int(s.top.store_x);
	const int y0 = int(s.top.store_y);
	s.sampleAt(kHDe - 1, 0);
	const int x_last = int(s.top.store_x);
	s.sampleAt(0, kVDe - 1);
	const int y_last = int(s.top.store_y);

	std::cout << "WINDOW unique_x=" << xs.size() << " max_x=" << (xs.empty() ? -1 : *xs.rbegin())
	          << " unique_y=" << ys.size() << " max_y=" << (ys.empty() ? -1 : *ys.rbegin())
	          << " x0=" << x0 << " x_last=" << x_last << " y0=" << y0 << " y_last=" << y_last
	          << "\n";

	int fails = 0;
	auto expect = [&](bool c, const char* m) {
		if (!c) {
			std::cerr << "FAIL window: " << m << "\n";
			++fails;
		}
	};

	expect(xs.size() == 320u, "unique store_x covers all 320 content cols");
	expect(!xs.empty() && *xs.begin() == 0 && *xs.rbegin() == 319, "store_x range 0..319");
	expect(ys.size() == 240u, "unique store_y covers all 240 content rows");
	expect(!ys.empty() && *ys.begin() == 0 && *ys.rbegin() == 239, "store_y range 0..239");
	expect(x0 == 0, "hc0 -> x0");
	expect(x_last == 319, "hc last -> x last");
	expect(y0 == 0, "py0 -> y0");
	expect(y_last == 239, "py last -> y last");

	// Legacy 640 path must NOT hold under window (guards tautology).
	expect(xs.size() != 529u, "window must not emit 529 unique x of full bank");
	expect(*xs.rbegin() != 638, "window must not reach FRAME_W legacy max 638");

	if (fails) {
		std::cerr << "window fails=" << fails << "\n";
		return 1;
	}
	std::cout << "PASS present_content_window_320\n";
	std::cout << "PASS race model window\n";
	return 0;
}

int runLegacy480Identity() {
	// win_enable=0 product path: unique y = 480, scale 1.0 — 480p must keep working.
	Sim s;
	s.top.win_enable = 0;
	s.top.content_w = 640; // ignored
	s.top.content_h = 480;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.resetCycles();
	s.settleWindow();

	std::set<int> ys, xs;
	for (int py = 0; py < kVDe; ++py) {
		s.sampleAt(0, py);
		ys.insert(int(s.top.store_y));
	}
	for (int hc = 0; hc < kHDe; ++hc) {
		s.sampleAt(hc, 0);
		xs.insert(int(s.top.store_x));
	}

	std::cout << "LEGACY480 unique_y=" << ys.size() << " max_y=" << (ys.empty() ? -1 : *ys.rbegin())
	          << " unique_x=" << xs.size() << " max_x=" << (xs.empty() ? -1 : *xs.rbegin())
	          << "\n";

	if (ys.size() != 480u || *ys.begin() != 0 || *ys.rbegin() != 479) {
		std::cerr << "FAIL legacy480: unique Y must be 0..479\n";
		return 1;
	}
	if (xs.size() != 529u || *xs.rbegin() != 638) {
		std::cerr << "FAIL legacy480: unique X must be 529 spanning to 638\n";
		return 1;
	}
	std::cout << "PASS legacy_480p_identity\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode_env = std::getenv("WINDOW_MODE");
	std::string mode = mode_env ? mode_env : "all";

	int rc = 0;
	if (mode == "legacy" || mode == "all") {
		const int r = runLegacyQuarterClass();
		std::cout << "legacy_quarter rc=" << r << "\n";
		if (r)
			rc = r;
	}
	if (mode == "window" || mode == "all") {
		const int r = runWindowPass();
		std::cout << "window rc=" << r << "\n";
		if (r)
			rc = r;
	}
	if (mode == "legacy480" || mode == "all") {
		const int r = runLegacy480Identity();
		std::cout << "legacy480 rc=" << r << "\n";
		if (r)
			rc = r;
	}
	if (mode != "legacy" && mode != "window" && mode != "legacy480" && mode != "all") {
		std::cerr << "unknown WINDOW_MODE=" << mode << "\n";
		return 2;
	}
	if (rc == 0)
		std::cout << "OK present_content_window_tb mode=" << mode << "\n";
	return rc;
}
