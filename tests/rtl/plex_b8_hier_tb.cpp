// B8/B13 product hierarchy: PRESENT_BEAM_960 fallback + PLXG runtime DE.
// COLLISION #5: force_native_960 must NOT override live PLXG.
//
// Product (PRESENT_BEAM_960):
//   1) PLXG idle → 960×540 max-tier fallback (legacy beam proofs).
//   2) PLXG live 624×480 / 320×240 / 416×234 → exact content+strides.
// Red twin FAULT_B8_NO_BEAM: no beam → O[4] legacy (rc!=0 + REPRO).
// Red twin FAULT_B8_FORCE_ALWAYS: unconditional force → 624 inject stays 960 (REPRO).
#include "Vplex_b8_hier_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplex_b8_hier_tb_top* t) {
	t->clk = 0;
	t->eval();
	main_time++;
	t->clk = 1;
	t->eval();
	main_time++;
}

static void clear_inject(Vplex_b8_hier_tb_top* t) {
	t->inject_plxg_live = 0;
	t->inject_cw = 0;
	t->inject_ch = 0;
	t->inject_coded_w = 0;
	t->inject_coded_h = 0;
	t->inject_y_stride = 0;
	t->inject_c_stride = 0;
}

static void inject_geom(Vplex_b8_hier_tb_top* t, int w, int h, int ys, int cs) {
	t->inject_plxg_live = 1;
	t->inject_cw = w;
	t->inject_ch = h;
	t->inject_coded_w = w;
	t->inject_coded_h = h;
	t->inject_y_stride = ys;
	t->inject_c_stride = cs;
	for (int i = 0; i < 8; ++i)
		tick(t);
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	int fails = 0;
	auto fail = [&](const char* m) {
		std::fprintf(stderr, "FAIL %s\n", m);
		++fails;
	};

	auto* t = new Vplex_b8_hier_tb_top;
	t->reset = 1;
	t->content_res_640x480 = 0;
	clear_inject(t);
	for (int i = 0; i < 8; ++i)
		tick(t);
	t->reset = 0;
	for (int i = 0; i < 32; ++i)
		tick(t);

#if defined(FAULT_B8_NO_BEAM)
	std::fprintf(stderr, "=== FAULT_B8_NO_BEAM red twin (expect non-960) ===\n");
	std::fprintf(stderr,
	             "fault: win=%u geom=%u cw=%u ch=%u coded=%ux%u yst=%u\n",
	             t->obs_win_en, t->obs_geom_en, t->obs_content_w, t->obs_content_h,
	             t->obs_coded_w, t->obs_coded_h, t->obs_y_stride);
	if (t->obs_content_w == 960 && t->obs_content_h == 540) {
		fail("fault twin unexpectedly got 960×540 (cannot see B8 defect)");
	} else {
		std::fprintf(stderr, "REPRO b8-plxg-tied-legacy cw=%u ch=%u\n",
		             t->obs_content_w, t->obs_content_h);
		std::fprintf(stderr, "PASS fault twin reproduces legacy content\n");
	}
	if (fails == 0) {
		std::fprintf(stderr, "FAULT_B8_NO_BEAM intentional RED (defect visible)\n");
		delete t;
		return 2;
	}
	delete t;
	return 1;

#elif defined(FAULT_B8_FORCE_ALWAYS)
	// COLLISION #5 red twin: force always-on pins 960 even when PLXG delivers 624.
	std::fprintf(stderr, "=== FAULT_B8_FORCE_ALWAYS (COLLISION #5 red twin) ===\n");
	inject_geom(t, 624, 480, 624, 312);
	std::fprintf(stderr,
	             "force_always+plxg624: cw=%u ch=%u yst=%u geom=%u\n",
	             t->obs_content_w, t->obs_content_h, t->obs_y_stride, t->obs_geom_en);
	if (t->obs_content_w == 624 && t->obs_content_h == 480 && t->obs_y_stride == 624) {
		fail("force_always twin did not pin 960 — cannot see COLLISION #5");
		delete t;
		return 1;
	}
	if (t->obs_content_w != 960 || t->obs_content_h != 540 || t->obs_y_stride != 960) {
		fail("force_always twin expected pinned 960×540/yst=960");
		delete t;
		return 1;
	}
	std::fprintf(stderr,
	             "REPRO collision5-force-overrides-plxg cw=%u ch=%u yst=%u "
	             "(624 inject killed)\n",
	             t->obs_content_w, t->obs_content_h, t->obs_y_stride);
	std::fprintf(stderr, "FAULT_B8_FORCE_ALWAYS intentional RED (COLLISION #5 visible)\n");
	delete t;
	return 2; // harness expects non-zero

#else
	std::fprintf(stderr, "=== PRODUCT PRESENT_BEAM_960 + PLXG runtime DE ===\n");

	// --- 1) PLXG idle → max-tier 960×540 fallback ---
	clear_inject(t);
	for (int i = 0; i < 8; ++i)
		tick(t);
	std::fprintf(stderr,
	             "idle: win=%u geom=%u cw=%u ch=%u coded=%ux%u yst=%u cst=%u de=%ux%u\n",
	             t->obs_win_en, t->obs_geom_en, t->obs_content_w, t->obs_content_h,
	             t->obs_coded_w, t->obs_coded_h, t->obs_y_stride, t->obs_c_stride,
	             t->obs_win_h_de, t->obs_win_v_de);

	if (!t->obs_win_en)
		fail("idle: win_enable=0 under PRESENT_BEAM_960");
	if (!t->obs_geom_en)
		fail("idle: geom_enable=0 under PRESENT_BEAM_960");
	if (t->obs_content_w != 960 || t->obs_content_h != 540)
		fail("idle: content not 960×540 fallback");
	if (t->obs_coded_w != 960 || t->obs_coded_h != 540)
		fail("idle: geom coded not 960×540");
	if (t->obs_y_stride != 960)
		fail("idle: y_stride not 960");
	if (t->obs_c_stride != 480)
		fail("idle: chroma_stride not 480");
	if (t->obs_win_h_de != 960 || t->obs_win_v_de != 540)
		fail("idle: win DE not 960×540");
	if (t->obs_video_arx != 0 || t->obs_video_ary != 0)
		fail("idle: VIDEO_ARX/VIDEO_ARY not Full Screen 0/0");
	const uint32_t u_base = (uint32_t)t->obs_y_stride * (uint32_t)t->obs_coded_h;
	if (u_base != 518400u)
		fail("idle: U base != 518400");
	std::fprintf(stderr, "idle U_base=%u OK\n", u_base);

	int saw_de = 0;
	for (int i = 0; i < 5000; ++i) {
		tick(t);
		if (t->obs_ce_pix && !t->obs_hblank && !t->obs_vblank)
			saw_de++;
	}
	if (saw_de < 100)
		fail("idle: beam produced too few DE samples");
	std::fprintf(stderr, "idle DE samples=%d\n", saw_de);

	// --- 2) PLXG live vectors: exact equality (COLLISION #5 fix) ---
	struct Vec {
		const char* name;
		int w, h, ys, cs;
	};
	const Vec vecs[] = {
	    {"624x480", 624, 480, 624, 312},
	    {"320x240", 320, 240, 320, 160},
	    {"416x234", 416, 234, 416, 208}, // aligned delivery for 426×240 class
	};
	for (const auto& v : vecs) {
		inject_geom(t, v.w, v.h, v.ys, v.cs);
		std::fprintf(stderr,
		             "plxg %s: cw=%u ch=%u yst=%u cst=%u geom=%u de=%ux%u\n", v.name,
		             t->obs_content_w, t->obs_content_h, t->obs_y_stride, t->obs_c_stride,
		             t->obs_geom_en, t->obs_win_h_de, t->obs_win_v_de);
		if (!t->obs_geom_en)
			fail("plxg: present_geom_enable must be 1 when live");
		if ((int)t->obs_content_w != v.w || (int)t->obs_content_h != v.h)
			fail("plxg: content_width/height exact mismatch");
		if ((int)t->obs_coded_w != v.w || (int)t->obs_coded_h != v.h)
			fail("plxg: coded dims exact mismatch");
		if ((int)t->obs_y_stride != v.ys)
			fail("plxg: y_stride exact mismatch");
		if ((int)t->obs_c_stride != v.cs)
			fail("plxg: chroma_stride exact mismatch");
		if ((int)t->obs_win_h_de != v.w || (int)t->obs_win_v_de != v.h)
			fail("plxg: win DE must track content (true-DE)");
		// Must NOT stay pinned at 960 when PLXG live.
		if (t->obs_content_w == 960 && v.w != 960)
			fail("plxg: COLLISION #5 — force still overrides live PLXG");
	}
	std::fprintf(stderr, "PASS plxg runtime DE exact equality (624/320/416)\n");

	// Capacity oracle (host-side Option-C) — independent of force path.
	const uint32_t payload_1280 = 1280u * 720u + 2u * ((1280u / 2u) * (720u / 2u));
	const uint32_t usable = 0x7F000u;
	if (!(payload_1280 > usable))
		fail("oracle: 1280 payload should exceed legacy usable");
	const uint32_t payload_960 = 960u * 540u + 2u * (480u * 270u);
	if (!(payload_960 > usable))
		fail("oracle: 960×540 payload must exceed usable (Option-C)");
	std::fprintf(stderr, "Option-C capacity: p960=%u p1280=%u usable=%u\n", payload_960,
	             payload_1280, usable);

	// Return to idle fallback after live PLXG.
	clear_inject(t);
	for (int i = 0; i < 8; ++i)
		tick(t);
	if (t->obs_content_w != 960 || t->obs_content_h != 540)
		fail("post-plxg: idle fallback not restored to 960×540");

	if (fails) {
		std::fprintf(stderr, "plex_b8_hier FAIL count=%d\n", fails);
		delete t;
		return 1;
	}
	std::fprintf(stderr, "plex_b8_hier ALL PASS (idle960 + plxg runtime DE)\n");
	delete t;
	return 0;
#endif
}
