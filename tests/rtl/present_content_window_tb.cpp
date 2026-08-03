// Red-before-green + 720p-ready gate for present_content_window.
//
// A) LEGACY win_enable=0 FRAME 640×480 on H_DE=529: quarter-class vs 320 intent
// B) WINDOW 320×240 on 529×480 DE: full stretch PASS
// C) LEGACY 480p identity PASS
// D) WINDOW 1280×720 on 529×480 DE (downscale to current glass): full content coverage
// E) WINDOW 1280×720 on 1280×720 DE (identity 720p): 1:1 unique rows/cols
// F) PMS 720×404 → 1280×720 DE (w-path ladder degradation tier): scale + midpoint
// G) Letterbox: 720×404 centred in 1280×720 (x0/y0 offsets)
// H) NEG wrong-scale midpoint: product must map hc mid → content mid (not identity)
//
// MODE=legacy|window|legacy480|720de480|720id|pms404|letterbox|neg_scale|all
// true rc direct.

#include "Vpresent_content_window_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <set>
#include <string>
#include <cmath>

// int abs
using std::abs;

namespace {

struct Sim {
	Vpresent_content_window_tb top{};

	void tick() {
		top.clk = 0;
		top.eval();
		top.clk = 1;
		top.eval();
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

	void settleWindow(int n = 4) {
		top.ce_pix = 0;
		for (int i = 0; i < n; ++i)
			tick();
	}

	void sampleAt(int hc, int py, int h_de, int v_de) {
		top.hc = hc & 0x7ff;
		top.py = py & 0x7ff;
		top.in_content = (hc < h_de && py < v_de) ? 1 : 0;
		top.ce_pix = 1;
		tick();
		top.ce_pix = 0;
		tick();
	}
};

int runLegacyQuarterClass() {
	constexpr int kHDe = 529, kVDe = 480;
	Sim s;
	s.top.win_enable = 0;
	s.top.content_w = 320;
	s.top.content_h = 240;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = 0;
	s.top.v_de = 0;
	s.resetCycles();
	s.settleWindow();

	std::set<int> xs, ys;
	for (int hc = 0; hc < kHDe; ++hc) {
		s.sampleAt(hc, 0, kHDe, kVDe);
		xs.insert(int(s.top.store_x));
	}
	for (int py = 0; py < kVDe; ++py) {
		s.sampleAt(0, py, kHDe, kVDe);
		ys.insert(int(s.top.store_y));
	}
	const int xmax = xs.empty() ? -1 : *xs.rbegin();
	std::cout << "LEGACY unique_x=" << xs.size() << " max_x=" << xmax
	          << " unique_y=" << ys.size() << " max_y=" << (ys.empty() ? -1 : *ys.rbegin())
	          << "\n";
	const bool quarter_class = (xs.size() > 320u) && (xmax > 319);
	const bool full_stretch =
	    (xs.size() == 320u) && (xmax == 319) && (ys.size() == 240u);
	if (!quarter_class || full_stretch) {
		std::cerr << "FAIL legacy: need quarter_class=1 full_stretch=0\n";
		return 1;
	}
	std::cout << "REPRO_OK legacy_fixed_map quarter_class=1 full_stretch=0\n";
	std::cout << "PASS race model legacy\n";
	return 0;
}

int runWindow320() {
	constexpr int kHDe = 529, kVDe = 480;
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = 320;
	s.top.content_h = 240;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = kHDe;
	s.top.v_de = kVDe;
	s.resetCycles();
	s.settleWindow();

	std::set<int> xs, ys;
	for (int hc = 0; hc < kHDe; ++hc) {
		s.sampleAt(hc, 0, kHDe, kVDe);
		xs.insert(int(s.top.store_x));
	}
	for (int py = 0; py < kVDe; ++py) {
		s.sampleAt(0, py, kHDe, kVDe);
		ys.insert(int(s.top.store_y));
	}
	s.sampleAt(0, 0, kHDe, kVDe);
	const int x0 = int(s.top.store_x);
	s.sampleAt(kHDe - 1, 0, kHDe, kVDe);
	const int x_last = int(s.top.store_x);
	s.sampleAt(0, kVDe - 1, kHDe, kVDe);
	const int y_last = int(s.top.store_y);

	std::cout << "WINDOW320 unique_x=" << xs.size() << " max_x=" << *xs.rbegin()
	          << " unique_y=" << ys.size() << " max_y=" << *ys.rbegin() << " x0=" << x0
	          << " x_last=" << x_last << " y_last=" << y_last << "\n";

	int fails = 0;
	auto expect = [&](bool c, const char* m) {
		if (!c) {
			std::cerr << "FAIL window320: " << m << "\n";
			++fails;
		}
	};
	expect(xs.size() == 320u, "unique x=320");
	expect(*xs.begin() == 0 && *xs.rbegin() == 319, "x 0..319");
	expect(ys.size() == 240u, "unique y=240");
	expect(*ys.begin() == 0 && *ys.rbegin() == 239, "y 0..239");
	expect(x0 == 0 && x_last == 319 && y_last == 239, "edges");
	expect(xs.size() != 529u && *xs.rbegin() != 638, "not legacy full bank");
	if (fails)
		return 1;
	std::cout << "PASS present_content_window_320\n";
	std::cout << "PASS race model window\n";
	return 0;
}

int runLegacy480() {
	constexpr int kHDe = 529, kVDe = 480;
	Sim s;
	s.top.win_enable = 0;
	s.top.content_w = 640;
	s.top.content_h = 480;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = 0;
	s.top.v_de = 0;
	s.resetCycles();
	s.settleWindow();

	std::set<int> ys, xs;
	for (int py = 0; py < kVDe; ++py) {
		s.sampleAt(0, py, kHDe, kVDe);
		ys.insert(int(s.top.store_y));
	}
	for (int hc = 0; hc < kHDe; ++hc) {
		s.sampleAt(hc, 0, kHDe, kVDe);
		xs.insert(int(s.top.store_x));
	}
	std::cout << "LEGACY480 unique_y=" << ys.size() << " max_y=" << *ys.rbegin()
	          << " unique_x=" << xs.size() << " max_x=" << *xs.rbegin() << "\n";
	if (ys.size() != 480u || *ys.rbegin() != 479 || xs.size() != 529u || *xs.rbegin() != 638) {
		std::cerr << "FAIL legacy480 identity\n";
		return 1;
	}
	std::cout << "PASS legacy_480p_identity\n";
	return 0;
}

int run720on480() {
	// 1280×720 content mapped across current 529×480 DE (downscale). Proves
	// 11-bit paths + general DE math without waiting for 720p DE retiming.
	constexpr int kHDe = 529, kVDe = 480;
	constexpr int kCw = 1280, kCh = 720;
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = kCw;
	s.top.content_h = kCh;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = kHDe;
	s.top.v_de = kVDe;
	s.resetCycles();
	s.settleWindow();

	std::set<int> xs, ys;
	for (int hc = 0; hc < kHDe; ++hc) {
		s.sampleAt(hc, 0, kHDe, kVDe);
		xs.insert(int(s.top.store_x));
	}
	for (int py = 0; py < kVDe; ++py) {
		s.sampleAt(0, py, kHDe, kVDe);
		ys.insert(int(s.top.store_y));
	}
	s.sampleAt(0, 0, kHDe, kVDe);
	const int x0 = int(s.top.store_x);
	s.sampleAt(kHDe - 1, 0, kHDe, kVDe);
	const int x_last = int(s.top.store_x);
	s.sampleAt(0, kVDe - 1, kHDe, kVDe);
	const int y_last = int(s.top.store_y);

	std::cout << "WIN720on480 unique_x=" << xs.size() << " max_x=" << *xs.rbegin()
	          << " unique_y=" << ys.size() << " max_y=" << *ys.rbegin() << " x0=" << x0
	          << " x_last=" << x_last << " y_last=" << y_last << "\n";

	int fails = 0;
	auto expect = [&](bool c, const char* m) {
		if (!c) {
			std::cerr << "FAIL 720on480: " << m << "\n";
			++fails;
		}
	};
	// NN downscale: unique samples ≤ DE size, but must reach last content pixel.
	expect(x0 == 0, "x0");
	expect(x_last == kCw - 1, "x reaches 1279");
	expect(y_last == kCh - 1, "y reaches 719");
	expect(*xs.begin() == 0 && *ys.begin() == 0, "origin");
	expect(xs.size() == static_cast<size_t>(kHDe), "one x sample per DE col (NN)");
	expect(ys.size() == static_cast<size_t>(kVDe), "one y sample per DE row (NN)");
	// Must NOT clamp into 640 domain (proves STORE_W=1280 path live).
	expect(*xs.rbegin() > 639, "store_x exceeds legacy FRAME_W");
	expect(*ys.rbegin() > 479, "store_y exceeds legacy FRAME_H");
	if (fails)
		return 1;
	std::cout << "PASS present_content_window_720_on_480de\n";
	return 0;
}

int run720identity() {
	// w-clock PRESENT_MULTI_PIXEL: content 1280×720, DE 1280×720 → scale 1.0.
	constexpr int kHDe = 1280, kVDe = 720;
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = 1280;
	s.top.content_h = 720;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = kHDe;
	s.top.v_de = kVDe;
	s.resetCycles();
	s.settleWindow();

	std::set<int> xs, ys;
	// Sparse sample full domain (full 1280×720 nested loop is fine but slower).
	for (int hc = 0; hc < kHDe; ++hc) {
		s.sampleAt(hc, 0, kHDe, kVDe);
		xs.insert(int(s.top.store_x));
	}
	for (int py = 0; py < kVDe; ++py) {
		s.sampleAt(0, py, kHDe, kVDe);
		ys.insert(int(s.top.store_y));
	}
	s.sampleAt(kHDe - 1, kVDe - 1, kHDe, kVDe);
	const int corner = int(s.top.store_x);
	const int cornery = int(s.top.store_y);

	std::cout << "WIN720id unique_x=" << xs.size() << " max_x=" << *xs.rbegin()
	          << " unique_y=" << ys.size() << " max_y=" << *ys.rbegin()
	          << " corner=" << corner << "," << cornery << "\n";

	if (xs.size() != 1280u || *xs.rbegin() != 1279 || ys.size() != 720u ||
	    *ys.rbegin() != 719 || corner != 1279 || cornery != 719) {
		std::cerr << "FAIL 720 identity\n";
		return 1;
	}
	std::cout << "PASS present_content_window_720_identity\n";
	return 0;
}

// Endpoint-exact Q16 (mirrors RTL): ceil((c-1)*65536/(d-1))
int winScale(int content, int de) {
	if (content <= 1 || de <= 1)
		return 0;
	const int64_t num = int64_t(content - 1) * 65536;
	const int64_t den = de - 1;
	return int((num + den - 1) / den);
}

int runPms404() {
	// w-path: PMS delivers 720×404 below maxBR=3100. Fabric must upscale to
	// w-clock 1280×720 DE so ARM never swscales.
	constexpr int kHDe = 1280, kVDe = 720;
	constexpr int kCw = 720, kCh = 404;
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = kCw;
	s.top.content_h = kCh;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = kHDe;
	s.top.v_de = kVDe;
	s.resetCycles();
	s.settleWindow();

	std::set<int> xs, ys;
	for (int hc = 0; hc < kHDe; ++hc) {
		s.sampleAt(hc, 0, kHDe, kVDe);
		xs.insert(int(s.top.store_x));
	}
	for (int py = 0; py < kVDe; ++py) {
		s.sampleAt(0, py, kHDe, kVDe);
		ys.insert(int(s.top.store_y));
	}
	s.sampleAt(0, 0, kHDe, kVDe);
	const int x0 = int(s.top.store_x);
	s.sampleAt(kHDe - 1, 0, kHDe, kVDe);
	const int x_last = int(s.top.store_x);
	s.sampleAt(0, kVDe - 1, kHDe, kVDe);
	const int y_last = int(s.top.store_y);
	// Midpoint: hc ≈ (h_de-1)/2 → store_x ≈ (cw-1)/2
	s.sampleAt((kHDe - 1) / 2, (kVDe - 1) / 2, kHDe, kVDe);
	const int x_mid = int(s.top.store_x);
	const int y_mid = int(s.top.store_y);
	const int sx = winScale(kCw, kHDe);
	const int sy = winScale(kCh, kVDe);
	const int x_mid_exp = ((kHDe - 1) / 2 * sx) >> 16;
	const int y_mid_exp = ((kVDe - 1) / 2 * sy) >> 16;

	std::cout << "CASE pms404 EXECUTED unique_x=" << xs.size()
	          << " max_x=" << *xs.rbegin() << " unique_y=" << ys.size()
	          << " max_y=" << *ys.rbegin() << " x0=" << x0 << " x_last=" << x_last
	          << " y_last=" << y_last << " x_mid=" << x_mid << " exp≈" << x_mid_exp
	          << " y_mid=" << y_mid << " exp≈" << y_mid_exp << " sx=" << sx
	          << " sy=" << sy << "\n";

	int fails = 0;
	auto expect = [&](bool c, const char* m) {
		if (!c) {
			std::cerr << "FAIL pms404: " << m << "\n";
			++fails;
		}
	};
	expect(x0 == 0 && x_last == kCw - 1, "H endpoints 0..719");
	expect(y_last == kCh - 1, "V endpoint 403");
	expect(xs.size() == static_cast<size_t>(kCw), "unique x covers all content cols");
	expect(ys.size() == static_cast<size_t>(kCh), "unique y covers all content rows");
	// Midpoint must track scale, not glass identity (hc=640 → ~360, not 640).
	expect(std::abs(x_mid - x_mid_exp) <= 1, "x midpoint scale");
	expect(std::abs(y_mid - y_mid_exp) <= 1, "y midpoint scale");
	expect(x_mid < 400 && x_mid > 300, "x_mid in content half (not DE half)");
	// Identity-scale fault class would put x_mid == (kHDe-1)/2 == 639.
	expect(x_mid != (kHDe - 1) / 2, "not identity DE map");
	if (fails)
		return 1;
	std::cout << "PASS present_content_window_pms404_to_720p\n";
	return 0;
}

int runLetterbox() {
	// 720×404 content centred in 1280×720: x0=(1280-720)/2=280, y0=(720-404)/2=158.
	constexpr int kHDe = 1280, kVDe = 720;
	constexpr int kCw = 720, kCh = 404;
	constexpr int kX0 = (1280 - 720) / 2; // 280
	constexpr int kY0 = (720 - 404) / 2;  // 158
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = kCw;
	s.top.content_h = kCh;
	s.top.content_x0 = kX0;
	s.top.content_y0 = kY0;
	s.top.h_de = kHDe;
	s.top.v_de = kVDe;
	s.resetCycles();
	s.settleWindow();

	s.sampleAt(0, 0, kHDe, kVDe);
	const int x0 = int(s.top.store_x);
	const int y0 = int(s.top.store_y);
	s.sampleAt(kHDe - 1, kVDe - 1, kHDe, kVDe);
	const int x1 = int(s.top.store_x);
	const int y1 = int(s.top.store_y);

	std::cout << "CASE letterbox EXECUTED x0=" << x0 << " y0=" << y0 << " x1=" << x1
	          << " y1=" << y1 << " expect_x0=" << kX0 << " expect_y0=" << kY0
	          << " expect_x1=" << (kX0 + kCw - 1) << " expect_y1=" << (kY0 + kCh - 1)
	          << "\n";

	if (x0 != kX0 || y0 != kY0 || x1 != kX0 + kCw - 1 || y1 != kY0 + kCh - 1) {
		std::cerr << "FAIL letterbox edges\n";
		return 1;
	}
	std::cout << "PASS present_content_window_letterbox_404\n";
	return 0;
}

// Parent product target: 960×540 ARM-affordable source → fabric 1280×720 glass.
// Scale ≈ 4/3 non-integer — NN shimmer worst case; load-bearing for ship path.
int runProduct540() {
	constexpr int kHDe = 1280, kVDe = 720;
	constexpr int kCw = 960, kCh = 540;
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = kCw;
	s.top.content_h = kCh;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = kHDe;
	s.top.v_de = kVDe;
	s.resetCycles();
	s.settleWindow();

	std::set<int> xs, ys;
	for (int hc = 0; hc < kHDe; ++hc) {
		s.sampleAt(hc, 0, kHDe, kVDe);
		xs.insert(int(s.top.store_x));
	}
	for (int py = 0; py < kVDe; ++py) {
		s.sampleAt(0, py, kHDe, kVDe);
		ys.insert(int(s.top.store_y));
	}
	s.sampleAt(0, 0, kHDe, kVDe);
	const int x0 = int(s.top.store_x);
	s.sampleAt(kHDe - 1, 0, kHDe, kVDe);
	const int x_last = int(s.top.store_x);
	s.sampleAt(0, kVDe - 1, kHDe, kVDe);
	const int y_last = int(s.top.store_y);
	s.sampleAt((kHDe - 1) / 2, (kVDe - 1) / 2, kHDe, kVDe);
	const int x_mid = int(s.top.store_x);
	const int y_mid = int(s.top.store_y);
	const int sx = winScale(kCw, kHDe);
	const int sy = winScale(kCh, kVDe);
	const int x_mid_exp = ((kHDe - 1) / 2 * sx) >> 16;
	const int y_mid_exp = ((kVDe - 1) / 2 * sy) >> 16;

	// Non-integer 4/3: sx != 65536 and != 49152 (3/4) — must be ceil((959)*65536/1279).
	std::cout << "CASE product540 EXECUTED unique_x=" << xs.size()
	          << " max_x=" << *xs.rbegin() << " unique_y=" << ys.size()
	          << " max_y=" << *ys.rbegin() << " x0=" << x0 << " x_last=" << x_last
	          << " y_last=" << y_last << " x_mid=" << x_mid << " exp≈" << x_mid_exp
	          << " y_mid=" << y_mid << " exp≈" << y_mid_exp << " sx=" << sx
	          << " sy=" << sy << " scale≈4/3\n";

	int fails = 0;
	auto expect = [&](bool c, const char* m) {
		if (!c) {
			std::cerr << "FAIL product540: " << m << "\n";
			++fails;
		}
	};
	expect(x0 == 0 && x_last == kCw - 1, "H endpoints 0..959");
	expect(y_last == kCh - 1, "V endpoint 539");
	expect(xs.size() == static_cast<size_t>(kCw), "unique x covers 960 cols");
	expect(ys.size() == static_cast<size_t>(kCh), "unique y covers 540 rows");
	expect(std::abs(x_mid - x_mid_exp) <= 1, "x midpoint scale");
	expect(std::abs(y_mid - y_mid_exp) <= 1, "y midpoint scale");
	// Identity would be mid=639; 1:1 content would be mid=479.5→~479.
	expect(x_mid != (kHDe - 1) / 2, "not identity DE map");
	expect(x_mid > 400 && x_mid < 560, "x_mid in ~4/3 content band");
	expect(sx != 65536 && sx != 0, "non-identity sx");
	// Integer-2× would be sx≈32768 for half width; 960 is not half of 1280.
	expect(kCw * 4 == kHDe * 3, "document 4:3 width ratio product target");
	if (fails)
		return 1;
	std::cout << "PASS present_content_window_product_960x540_to_720p\n";
	return 0;
}

int runNegScaleMidpoint() {
	// Product path: 720→1280 must NOT be identity. This is the green half of the
	// wrong-scale discriminator (FAULT_IDENTITY_SCALE red twin is separate build).
	constexpr int kHDe = 1280, kVDe = 720;
	constexpr int kCw = 720, kCh = 404;
	Sim s;
	s.top.win_enable = 1;
	s.top.content_w = kCw;
	s.top.content_h = kCh;
	s.top.content_x0 = 0;
	s.top.content_y0 = 0;
	s.top.h_de = kHDe;
	s.top.v_de = kVDe;
	s.resetCycles();
	s.settleWindow();

	s.sampleAt((kHDe - 1) / 2, (kVDe - 1) / 2, kHDe, kVDe);
	const int x_mid = int(s.top.store_x);
	const int y_mid = int(s.top.store_y);
	const int sx = winScale(kCw, kHDe);
	const int sy = winScale(kCh, kVDe);
	const int x_exp = (((kHDe - 1) / 2) * sx) >> 16;
	const int y_exp = (((kVDe - 1) / 2) * sy) >> 16;

	std::cout << "CASE neg_scale EXECUTED x_mid=" << x_mid << " y_mid=" << y_mid
	          << " x_exp=" << x_exp << " y_exp=" << y_exp
	          << " identity_would_be=" << ((kHDe - 1) / 2) << "\n";

	// If scale were identity (FAULT), x_mid == 639. Product must be ~359.
	if (x_mid == (kHDe - 1) / 2) {
		std::cerr << "FAIL neg_scale: identity map (scale broken or FAULT build)\n";
		return 1;
	}
	if (std::abs(x_mid - x_exp) > 1 || std::abs(y_mid - y_exp) > 1) {
		std::cerr << "FAIL neg_scale: midpoint off exp\n";
		return 1;
	}
	std::cout << "PASS neg_scale midpoint discriminator live (not identity)\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode_env = std::getenv("WINDOW_MODE");
	std::string mode = mode_env ? mode_env : "all";

	int rc = 0;
	auto run = [&](const char* name, int (*fn)()) {
		if (mode != name && mode != "all")
			return;
		const int r = fn();
		std::cout << name << " rc=" << r << "\n";
		if (r)
			rc = r;
	};

	run("legacy", runLegacyQuarterClass);
	run("window", runWindow320);
	run("legacy480", runLegacy480);
	run("720de480", run720on480);
	run("720id", run720identity);
	run("pms404", runPms404);
	run("product540", runProduct540);
	run("letterbox", runLetterbox);
	run("neg_scale", runNegScaleMidpoint);

	if (mode != "legacy" && mode != "window" && mode != "legacy480" && mode != "720de480" &&
	    mode != "720id" && mode != "pms404" && mode != "product540" && mode != "letterbox" &&
	    mode != "neg_scale" && mode != "all") {
		std::cerr << "unknown WINDOW_MODE=" << mode << "\n";
		return 2;
	}
	if (rc == 0)
		std::cout << "OK present_content_window_tb mode=" << mode << "\n";
	return rc;
}
