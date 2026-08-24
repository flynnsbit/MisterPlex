// Analog raster mux v1: H class is reset-latched. Live fstart sel change
// must NOT retarget 15.6 kHz <-> 31 kHz. field_odd may still toggle only
// when reset latched 480i. mux6 doorbell ports stay invalid (OSD path).

#include "Vanalog_raster_mux.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>

namespace {

constexpr int kClkHz = 20'000'000;
constexpr int kHzLo15 = 14500;
constexpr int kHzHi15 = 16700;
constexpr int kHzLo31 = 30000;
constexpr int kHzHi33 = 33000;

void tick(Vanalog_raster_mux* top) {
	top->clk = 0;
	top->eval();
	top->clk = 1;
	top->eval();
}

void reset_sel(Vanalog_raster_mux* top, int sel) {
	top->reset = 1;
	top->pal = 0;
	top->raster_sel = static_cast<uint8_t>(sel);
	top->doorbell_sel = 0;
	top->doorbell_valid = 0;
	top->content_index = 0;
	top->pattern = 0;
	for (int i = 0; i < 8; ++i)
		tick(top);
	top->reset = 0;
}

int hz_from_period(int period_clk) {
	if (period_clk <= 0)
		return 0;
	return kClkHz / period_clk;
}

int measure_hs_period(Vanalog_raster_mux* top, int lines) {
	int last_hs = 0;
	int last_rise = -1;
	int sum = 0;
	int n = 0;
	const int max_clk = 200000;
	for (int c = 0; c < max_clk; ++c) {
		tick(top);
		const int hs = top->HSync ? 1 : 0;
		if (hs && !last_hs) {
			if (last_rise >= 0) {
				sum += (c - last_rise);
				n++;
				if (n >= lines)
					break;
			}
			last_rise = c;
		}
		last_hs = hs;
	}
	if (n <= 0)
		return 0;
	return sum / n;
}

int wait_fstart(Vanalog_raster_mux* top, int n) {
	int seen = 0;
	const int max_clk = 2000000;
	for (int c = 0; c < max_clk && seen < n; ++c) {
		tick(top);
		if (top->frame_start)
			seen++;
	}
	return seen;
}

bool in_class(int hz, int lo, int hi) {
	return hz >= lo && hz <= hi;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* top = new Vanalog_raster_mux;
	int fails = 0;

	auto fail = [&](const char* msg) {
		std::printf("FAIL %s\n", msg);
		fails++;
	};

	// ---- reset 240p (15 kHz). Live sel→480p must keep 15 kHz. ----
	reset_sel(top, 0);
	int p = measure_hs_period(top, 4);
	int hz = hz_from_period(p);
	std::printf("reset sel=0 period_clk=%d H=%d Hz scandouble=%d (want 15.6k sd=0)\n", p, hz,
	            top->scandouble_act ? 1 : 0);
	if (!in_class(hz, kHzLo15, kHzHi15) || top->scandouble_act)
		fail("reset 240p is not 15.6 kHz class");

	top->raster_sel = 1;
	const int fs240 = wait_fstart(top, 2);
	std::printf("live sel=1 after 240p reset: fstart=%d scandouble=%d field_odd=%d\n", fs240,
	            top->scandouble_act ? 1 : 0, top->field_odd ? 1 : 0);
	if (fs240 < 2)
		fail("live 240p→480p eval needs fstart (cannot prove latch)");
	if (top->scandouble_act)
		fail("live fstart sel=1 retargeted scandouble (H class) after 240p reset");
	p = measure_hs_period(top, 4);
	hz = hz_from_period(p);
	std::printf("after live sel=1: period_clk=%d H=%d Hz class15=%d class31=%d\n", p, hz,
	            in_class(hz, kHzLo15, kHzHi15) ? 1 : 0, in_class(hz, kHzLo31, kHzHi33) ? 1 : 0);
	if (!in_class(hz, kHzLo15, kHzHi15))
		fail("live fstart sel change retargeted H class off 15.6 kHz");
	if (in_class(hz, kHzLo31, kHzHi33))
		fail("live fstart sel=1 landed in 31 kHz class (forbidden v1)");

	top->raster_sel = 2;
	const int fs240i = wait_fstart(top, 2);
	int saw_field = top->field_odd ? 1 : 0;
	for (int c = 0; c < 400000; ++c) {
		tick(top);
		if (top->field_odd)
			saw_field = 1;
	}
	std::printf("live sel=2 after 240p reset: fstart=%d scandouble=%d saw_field=%d\n", fs240i,
	            top->scandouble_act ? 1 : 0, saw_field);
	if (top->scandouble_act)
		fail("live fstart sel=2 retargeted scandouble after 240p reset");
	if (saw_field)
		fail("live fstart sel=2 started field_odd weave after 240p reset");

	// ---- reset IS allowed to retarget H class (v1 latch at reset). ----
	reset_sel(top, 1);
	p = measure_hs_period(top, 4);
	hz = hz_from_period(p);
	std::printf("reset sel=1 period_clk=%d H=%d Hz scandouble=%d (want ~31k sd=1)\n", p, hz,
	            top->scandouble_act ? 1 : 0);
	if (!in_class(hz, kHzLo31, kHzHi33) || !top->scandouble_act)
		fail("reset 480p is not ~31 kHz class");

	top->raster_sel = 0;
	const int fs480 = wait_fstart(top, 2);
	std::printf("live sel=0 after 480p reset: fstart=%d scandouble=%d\n", fs480,
	            top->scandouble_act ? 1 : 0);
	if (fs480 < 2)
		fail("live 480p→240p eval needs fstart (cannot prove latch)");
	if (!top->scandouble_act)
		fail("live fstart sel=0 retargeted scandouble (H class) after 480p reset");
	p = measure_hs_period(top, 4);
	hz = hz_from_period(p);
	std::printf("after live sel=0: period_clk=%d H=%d Hz class31=%d class15=%d\n", p, hz,
	            in_class(hz, kHzLo31, kHzHi33) ? 1 : 0, in_class(hz, kHzLo15, kHzHi15) ? 1 : 0);
	if (!in_class(hz, kHzLo31, kHzHi33))
		fail("live fstart sel change retargeted H class off ~31 kHz");
	if (in_class(hz, kHzLo15, kHzHi15))
		fail("live fstart sel=0 landed in 15.6 kHz class (forbidden v1)");

	// 480i field toggle still works when reset-latched as 480i.
	reset_sel(top, 2);
	int saw0 = top->field_odd ? 0 : 1;
	int saw1 = top->field_odd ? 1 : 0;
	int fsn = 0;
	for (int c = 0; c < 800000 && fsn < 3; ++c) {
		tick(top);
		if (top->frame_start)
			fsn++;
		if (top->field_odd)
			saw1 = 1;
		else
			saw0 = 1;
	}
	std::printf("reset sel=2 field saw0=%d saw1=%d fstart=%d scandouble=%d\n", saw0, saw1, fsn,
	            top->scandouble_act ? 1 : 0);
	if (top->scandouble_act)
		fail("reset 480i must stay 15 kHz class (scandouble=0)");
	if (!saw0 || !saw1)
		fail("reset-latched 480i field_odd must still toggle");

	if (fails) {
		std::printf("FAIL analog_raster_mux_latch %d checks\n", fails);
		delete top;
		return 1;
	}
	std::printf("OK analog_raster_mux_latch: live fstart does not retarget H class\n");
	delete top;
	return 0;
}
