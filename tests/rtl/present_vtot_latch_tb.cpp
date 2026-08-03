// Adversarial runtime V_TOTAL: mid-frame 705→564 must NOT stall.
// rd-duck: comb rt_vtotal as v_last with vc>563 never hits wrap.
// Expect: current frame finishes at active=705; next frames active=564; true_de holds.
// true rc direct. EXECUTED before accept.

#include "Vpresent_true_de_count_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cmath>

static vluint64_t main_time = 0;
double sc_time_stamp() { return double(main_time); }

static void tick(Vpresent_true_de_count_tb *top)
{
	top->clk = 0;
	top->eval();
	main_time++;
	top->clk = 1;
	top->eval();
	main_time++;
}

static void wait_frame_start(Vpresent_true_de_count_tb *top, int guard_clks)
{
	int g = guard_clks;
	while (!top->frame_start && g-- > 0)
		tick(top);
	if (g <= 0) {
		std::fprintf(stderr, "FAIL no frame_start (stall?)\n");
		std::exit(2);
	}
}

// Count clks from current frame_start cycle through next frame_start edge.
static int measure_frame_clks(Vpresent_true_de_count_tb *top, int *vtot_seen_min, int *vtot_seen_max,
                              int *de_pixels, int *store_req)
{
	*vtot_seen_min = 100000;
	*vtot_seen_max = 0;
	*de_pixels = 0;
	*store_req = 0;
	int clks = 0;
	const int limit = 1182 * 800 + 10000;
	// Already on frame_start cycle.
	for (;;) {
		const int vt = int(top->vtot_active);
		if (vt < *vtot_seen_min)
			*vtot_seen_min = vt;
		if (vt > *vtot_seen_max)
			*vtot_seen_max = vt;
		if (top->de_out)
			(*de_pixels)++;
		if (top->in_content_raw)
			(*store_req)++;
		tick(top);
		clks++;
		if (top->frame_start)
			break;
		if (clks > limit) {
			std::fprintf(stderr, "FAIL frame exceeded %d clks (no wrap)\n", limit);
			std::exit(2);
		}
	}
	return clks;
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	auto *top = new Vpresent_true_de_count_tb;

	top->win_enable = 1;
	top->content_w = 960;
	top->content_h = 540;
	top->content_x0 = 0;
	top->content_y0 = 0;
	top->win_h_de = 960;
	top->win_v_de = 540;
	top->use_rt_vtotal = 1;
	top->rt_vtotal = 705; // start film
	top->use_rt_geom = 0;
	top->rt_h_de = 0;
	top->rt_v_active = 0;

	top->reset = 1;
	top->clk = 0;
	for (int i = 0; i < 20; ++i)
		tick(top);
	top->reset = 0;
	for (int i = 0; i < 5; ++i)
		tick(top);

	// Warmup one full frame at 705.
	wait_frame_start(top, 1182 * 800);
	int vmin, vmax, dep, sreq;
	int clks0 = measure_frame_clks(top, &vmin, &vmax, &dep, &sreq);
	if (clks0 != 1182 * 705 || vmin != 705 || vmax != 705) {
		std::fprintf(stderr, "FAIL warmup frame clks=%d vtot=%d..%d expect 833310/705\n", clks0,
		             vmin, vmax);
		std::printf("CASE vtot_latch EXECUTED phase=warmup FAIL\n");
		return 1;
	}

	// Now on frame_start of a fresh 705 frame. Advance into vertical blank past 563.
	// Adversarial: host writes 564 while vc>563 — old comb path would stall.
	int g = 1182 * 800;
	while (!(int(top->vc) >= 600 && int(top->hc) == 10) && g-- > 0)
		tick(top);
	if (g <= 0) {
		std::fprintf(stderr, "FAIL never reached vc>=600\n");
		return 2;
	}
	const int vc_at_write = int(top->vc);
	const int vtot_before = int(top->vtot_active);
	top->rt_vtotal = 564; // mid-frame request — must NOT apply until wrap
	top->eval();

	// Finish this frame: must still wrap (frame_start) with active staying 705.
	int clks_rest = 0;
	int vtot_mid_min = 100000, vtot_mid_max = 0;
	int saw_fs = 0;
	g = 1182 * 200;
	while (g-- > 0) {
		const int vt = int(top->vtot_active);
		if (vt < vtot_mid_min)
			vtot_mid_min = vt;
		if (vt > vtot_mid_max)
			vtot_mid_max = vt;
		tick(top);
		clks_rest++;
		if (top->frame_start) {
			saw_fs = 1;
			break;
		}
	}
	if (!saw_fs) {
		std::printf("CASE vtot_latch EXECUTED phase=midframe_stall "
		            "vc_at_write=%d vtot_before=%d FAIL no frame_start\n",
		            vc_at_write, vtot_before);
		std::fprintf(stderr, "FAIL STALL: no frame_start after mid-frame 705→564\n");
		return 1;
	}

	// frame_start cycle: vtot_act should now be 564 (applied on wrap).
	const int vtot_at_fs = int(top->vtot_active);
	int clks1 = measure_frame_clks(top, &vmin, &vmax, &dep, &sreq);

	std::printf(
	    "CASE vtot_latch EXECUTED mode=MIDFRAME_705_to_564 "
	    "vc_at_write=%d vtot_before=%d mid_vtot=%d..%d vtot_at_fs=%d "
	    "next_clks=%d next_vtot=%d..%d next_de_pixels=%d next_store_req=%d "
	    "clks_rest_after_write=%d\n",
	    vc_at_write, vtot_before, vtot_mid_min, vtot_mid_max, vtot_at_fs, clks1, vmin, vmax, dep,
	    sreq, clks_rest);

	int fails = 0;
#define CHECK(c, m)                                                                 \
	do {                                                                            \
		if (!(c)) {                                                                 \
			std::fprintf(stderr, "FAIL %s\n", m);                                   \
			++fails;                                                                \
		}                                                                           \
	} while (0)

	CHECK(vc_at_write > 563, "wrote while vc>563");
	CHECK(vtot_before == 705, "active was 705 at write");
	CHECK(vtot_mid_min == 705 && vtot_mid_max == 705, "active stayed 705 until wrap");
	CHECK(saw_fs == 1, "frame_start after mid write");
	CHECK(vtot_at_fs == 564, "applied 564 on wrap");
	CHECK(clks1 == 1182 * 564, "next frame 666648 clks");
	CHECK(vmin == 564 && vmax == 564, "next frame active 564");
	CHECK(dep == 960 * 540, "next de_pixels 518400");
	CHECK(sreq == 960 * 540, "next store_req 518400");

	if (fails) {
		std::printf("FAIL vtot_latch fails=%d\n", fails);
		delete top;
		return 1;
	}
	std::printf("PASS vtot_latch midframe 705→564 no-stall next=30Hz store_full\n");
	delete top;
	return 0;
}
