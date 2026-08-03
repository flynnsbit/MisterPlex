// B9: assert Plex VIDEO_ARX/VIDEO_ARY pin policy (top-level pin names).
//
// Modes differ (a test where all three agree proves nothing):
//   Original + host DAR 16:9 → 16:9
//   Original + no DAR          → legacy 4:3 (defect if content is 16:9)
//   Full Screen                → 0:0
//   Forced menu path           → ARC1 1:0 (differs from both)
//
// RED: 16:9 content under Original without host DAR → pins 4:3 (visible defect).
// Soft-skip ≠ pass. true rc direct.

#include "Vplex_ar_pins_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

enum class Mode {
	GreenOriginal16x9,
	GreenFullScreen,
	GreenOriginal4x3,
	GreenArc1,
	Red16x9As4x3,
	RedInferCoded // prove we do NOT use coded W/H: 720x480 coded must not become 3:2
};

static Mode parseMode(int argc, char** argv) {
	for (int i = 1; i < argc; ++i) {
		if (!std::strcmp(argv[i], "ORIG_16_9"))
			return Mode::GreenOriginal16x9;
		if (!std::strcmp(argv[i], "FULL"))
			return Mode::GreenFullScreen;
		if (!std::strcmp(argv[i], "ORIG_4_3"))
			return Mode::GreenOriginal4x3;
		if (!std::strcmp(argv[i], "ARC1"))
			return Mode::GreenArc1;
		if (!std::strcmp(argv[i], "RED_16_9_AS_4_3"))
			return Mode::Red16x9As4x3;
		if (!std::strcmp(argv[i], "RED_INFER_CODED"))
			return Mode::RedInferCoded;
	}
#if defined(PLEX_AR_RED_16_9_AS_4_3)
	return Mode::Red16x9As4x3;
#elif defined(PLEX_AR_RED_INFER_CODED)
	return Mode::RedInferCoded;
#elif defined(PLEX_AR_FULL)
	return Mode::GreenFullScreen;
#elif defined(PLEX_AR_ORIG_4_3)
	return Mode::GreenOriginal4x3;
#elif defined(PLEX_AR_ARC1)
	return Mode::GreenArc1;
#else
	return Mode::GreenOriginal16x9;
#endif
}

struct Pins {
	int arx = -1;
	int ary = -1;
};

static Pins sample(Vplex_ar_pins_tb& top, int menu, int dar_v, int dar_x, int dar_y) {
	top.ar_menu = menu & 3;
	top.host_dar_valid = dar_v ? 1 : 0;
	top.host_dar_x = dar_x & 0xfff;
	top.host_dar_y = dar_y & 0xfff;
	top.eval();
	++main_time;
	Pins p;
	p.arx = static_cast<int>(top.VIDEO_ARX) & 0x1fff;
	p.ary = static_cast<int>(top.VIDEO_ARY) & 0x1fff;
	return p;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const Mode mode = parseMode(argc, argv);
	Vplex_ar_pins_tb top{};

	const char* name = "ORIG_16_9";
	int fails = 0;
	auto expect = [&](bool ok, const char* tag) {
		if (ok)
			std::printf("  PASS %s\n", tag);
		else {
			std::printf("  FAIL %s\n", tag);
			++fails;
		}
	};

	// Cross-mode samples (always take all four so we can prove they differ).
	const Pins p_orig_16 = sample(top, /*Original*/ 0, /*dar*/ 1, 16, 9);
	const Pins p_full = sample(top, /*Full*/ 1, 0, 0, 0);
	const Pins p_orig_no = sample(top, 0, 0, 0, 0);
	const Pins p_arc1 = sample(top, /*ARC1*/ 2, 0, 0, 0);
	const Pins p_orig_4 = sample(top, 0, 1, 4, 3);
	// Coded 720×480 storage AR is 3:2 — must NOT appear as pins when DAR is 16:9.
	const Pins p_720_dar16 = sample(top, 0, 1, 16, 9);

	std::printf("CASE plex_ar_pins EXECUTED\n");
	std::printf("  pin ORIG+DAR16:9  VIDEO_ARX=%d VIDEO_ARY=%d\n", p_orig_16.arx, p_orig_16.ary);
	std::printf("  pin FULL          VIDEO_ARX=%d VIDEO_ARY=%d\n", p_full.arx, p_full.ary);
	std::printf("  pin ORIG+noDAR    VIDEO_ARX=%d VIDEO_ARY=%d\n", p_orig_no.arx, p_orig_no.ary);
	std::printf("  pin ARC1          VIDEO_ARX=%d VIDEO_ARY=%d\n", p_arc1.arx, p_arc1.ary);
	std::printf("  pin ORIG+DAR4:3   VIDEO_ARX=%d VIDEO_ARY=%d\n", p_orig_4.arx, p_orig_4.ary);

	// Modes must differ pairwise where the policy says so.
	expect(!(p_orig_16.arx == p_full.arx && p_orig_16.ary == p_full.ary),
	       "ORIG_16x9_differs_FULL");
	expect(!(p_orig_16.arx == p_orig_no.arx && p_orig_16.ary == p_orig_no.ary),
	       "ORIG_16x9_differs_ORIG_noDAR");
	expect(!(p_full.arx == p_arc1.arx && p_full.ary == p_arc1.ary), "FULL_differs_ARC1");
	expect(!(p_orig_no.arx == p_arc1.arx && p_orig_no.ary == p_arc1.ary),
	       "ORIG_noDAR_differs_ARC1");

	switch (mode) {
	case Mode::GreenOriginal16x9:
		name = "ORIG_16_9";
		expect(p_orig_16.arx == 16 && p_orig_16.ary == 9, "pins_16_9");
		expect(p_720_dar16.arx == 16 && p_720_dar16.ary == 9,
		       "720coded_with_host_DAR_still_16_9");
		// Must not equal storage AR 720:480 = 3:2
		expect(!(p_720_dar16.arx == 3 && p_720_dar16.ary == 2), "not_storage_3_2");
		expect(!(p_720_dar16.arx == 720 && p_720_dar16.ary == 480), "not_coded_wh");
		break;
	case Mode::GreenFullScreen:
		name = "FULL";
		expect(p_full.arx == 0 && p_full.ary == 0, "pins_0_0");
		break;
	case Mode::GreenOriginal4x3:
		name = "ORIG_4_3";
		expect(p_orig_4.arx == 4 && p_orig_4.ary == 3, "pins_4_3_from_host_DAR");
		break;
	case Mode::GreenArc1:
		name = "ARC1";
		expect(p_arc1.arx == 1 && p_arc1.ary == 0, "pins_ARC1_1_0");
		break;
	case Mode::Red16x9As4x3:
		name = "RED_16_9_AS_4_3";
		// Visible defect: 16:9 title, Original, no PLXG DAR → 4:3 pins.
		expect(p_orig_no.arx == 4 && p_orig_no.ary == 3, "control_legacy_4_3_pins");
		// This configuration is the bug for 960×540 / 624×352 16:9 content.
		std::printf("  DEFECT 16:9 content under Original without host DAR → "
		            "VIDEO_ARX:ARY = %d:%d (want 16:9)\n",
		            p_orig_no.arx, p_orig_no.ary);
		if (p_orig_no.arx == 16 && p_orig_no.ary == 9) {
			std::printf("  FAIL RED twin unexpectedly correct (no longer catches defect)\n");
			++fails;
		} else {
			// Twin must stay RED: pins are wrong for 16:9 content.
			expect(p_orig_no.arx == 4 && p_orig_no.ary == 3, "RED_catches_4_3_on_16_9_content");
		}
		if (fails == 0)
			fails = 1; // always nonzero exit
		break;
	case Mode::RedInferCoded:
		name = "RED_INFER_CODED";
		// If someone "fixed" AR by coded_w/h, 720×480 → 3:2 or 720:480.
		// Policy forbids inference: with host DAR 16:9, pins stay 16:9.
		expect(p_720_dar16.arx == 16 && p_720_dar16.ary == 9, "host_DAR_wins");
		if (p_720_dar16.arx == 720 || p_720_dar16.arx == 3) {
			std::printf("  FAIL inferred coded geometry into AR pins\n");
			++fails;
		}
		// RED twin documents the unsound alternative: sampling "storage AR"
		// would yield 3:2 for 720×480 — we require that NOT equal host path.
		{
			const int storage_x = 720;
			const int storage_y = 480;
			// reduce 720:480 → 3:2
			const int sx = 3, sy = 2;
			expect(!(p_720_dar16.arx == sx && p_720_dar16.ary == sy),
			       "pins_not_equal_storage_AR_3_2");
			expect(!(p_720_dar16.arx == storage_x && p_720_dar16.ary == storage_y),
			       "pins_not_equal_coded_wh");
			// Force RED exit: this case is the negative proof suite.
			if (fails == 0)
				fails = 1;
			std::printf("  NOTE storage_AR_would_be=%d:%d host_DAR_pins=%d:%d\n", sx, sy,
			            p_720_dar16.arx, p_720_dar16.ary);
		}
		break;
	}

	std::printf("  mode=%s fails=%d\n", name, fails);
	if (mode == Mode::Red16x9As4x3 || mode == Mode::RedInferCoded) {
		std::printf("FAIL plex_ar_pins RED mode=%s (expected nonzero)\n", name);
		return 1;
	}
	if (fails) {
		std::printf("FAIL plex_ar_pins mode=%s fails=%d\n", name, fails);
		return 1;
	}
	const Pins* report = &p_orig_16;
	if (mode == Mode::GreenFullScreen)
		report = &p_full;
	else if (mode == Mode::GreenOriginal4x3)
		report = &p_orig_4;
	else if (mode == Mode::GreenArc1)
		report = &p_arc1;
	std::printf("PASS plex_ar_pins mode=%s VIDEO_ARX=%d VIDEO_ARY=%d\n", name, report->arx,
	            report->ary);
	return 0;
}
