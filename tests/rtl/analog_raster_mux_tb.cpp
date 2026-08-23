// Analog raster mux: 240p ~15.6 kHz vs 480p ~31 kHz vs 480i field toggle.
// RED twin: ANALOG_RASTER_FAULT_SWAP_SEL must fail these class checks.
//
// clk_sys = 20 MHz (TB period 1 tick = 1 clk). colorbars Template H_TOTAL=638.

#include "Vanalog_raster_mux.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace {

constexpr int kClkHz = 20'000'000;
constexpr int kHpix = 638;
// 240p: ce/2 → 1276 clk/line. 480p: ce=1 → 638 clk/line.
constexpr int kPeriod240 = kHpix * 2; // 1276 → 15.674 kHz
constexpr int kPeriod480 = kHpix;     // 638  → 31.348 kHz
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

bool in_class(int hz, int lo, int hi) {
	return hz >= lo && hz <= hi;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* top = new Vanalog_raster_mux;
	int fails = 0;

	// ---- 240p 15 kHz class ----
	reset_sel(top, 0);
	const int p240 = measure_hs_period(top, 6);
	const int hz240 = hz_from_period(p240);
	const bool c240 = in_class(hz240, kHzLo15, kHzHi15);
	std::printf("240p sel=0 period_clk=%d H=%d Hz class15=%d (expect ~%d clk / %d Hz)\n",
	            p240, hz240, c240 ? 1 : 0, kPeriod240, hz_from_period(kPeriod240));
	if (!c240) {
		std::printf("FAIL 240p not 15.6 kHz class\n");
		fails++;
	}
	if (in_class(hz240, kHzLo31, kHzHi33)) {
		std::printf("FAIL 240p landed in 31 kHz class (wrong sel)\n");
		fails++;
	}
	if (top->field_odd) {
		std::printf("FAIL 240p field_odd must stay 0\n");
		fails++;
	}

	// Reset-latch: live raster_sel hop must not retune CE (SDC/CDC contract).
	// Skip when 240p class already failed (FAULT swap-sel red twin).
	if (c240) {
		top->raster_sel = 1;
		int fs_live = 0;
		for (int c = 0; c < 500000 && fs_live < 2; ++c) {
			tick(top);
			if (top->frame_start)
				fs_live++;
		}
		const int p_live = measure_hs_period(top, 4);
		const int hz_live = hz_from_period(p_live);
		std::printf("live-hop sel=1 (no reset) period_clk=%d H=%d Hz scandouble=%d fstart=%d\n",
		            p_live, hz_live, top->scandouble_act ? 1 : 0, fs_live);
		if (!in_class(hz_live, kHzLo15, kHzHi15)) {
			std::printf("FAIL live raster_sel hop retuned analog H-rate (sel_lat not reset-only)\n");
			fails++;
		}
		if (top->scandouble_act) {
			std::printf("FAIL live hop set scandouble_act (sel_lat hopped on fstart)\n");
			fails++;
		}
	}

	// ---- 480p ~31 kHz class ----
	reset_sel(top, 1);
	const int p480 = measure_hs_period(top, 6);
	const int hz480 = hz_from_period(p480);
	const bool c480 = in_class(hz480, kHzLo31, kHzHi33);
	std::printf("480p sel=1 period_clk=%d H=%d Hz class31=%d (expect ~%d clk / %d Hz)\n",
	            p480, hz480, c480 ? 1 : 0, kPeriod480, hz_from_period(kPeriod480));
	if (!c480) {
		std::printf("FAIL 480p not ~31 kHz class\n");
		fails++;
	}
	if (in_class(hz480, kHzLo15, kHzHi15)) {
		std::printf("FAIL 480p landed in 15.6 kHz class (wrong sel)\n");
		fails++;
	}
	if (top->field_odd) {
		std::printf("FAIL 480p field_odd must stay 0\n");
		fails++;
	}

	// ---- 480i 15 kHz + field toggle ----
	reset_sel(top, 2);
	const int p480i = measure_hs_period(top, 4);
	const int hz480i = hz_from_period(p480i);
	const bool c480i = in_class(hz480i, kHzLo15, kHzHi15);
	std::printf("480i sel=2 period_clk=%d H=%d Hz class15=%d\n", p480i, hz480i, c480i ? 1 : 0);
	if (!c480i) {
		std::printf("FAIL 480i not 15.6 kHz class\n");
		fails++;
	}
	int saw0 = top->field_odd ? 0 : 1;
	int saw1 = top->field_odd ? 1 : 0;
	int fstart_n = 0;
	const int max_i = 800000;
	for (int c = 0; c < max_i && fstart_n < 3; ++c) {
		tick(top);
		if (top->frame_start)
			fstart_n++;
		if (top->field_odd)
			saw1 = 1;
		else
			saw0 = 1;
	}
	std::printf("480i field_odd saw0=%d saw1=%d frame_starts=%d\n", saw0, saw1, fstart_n);
	if (!saw0 || !saw1) {
		std::printf("FAIL 480i field_odd did not toggle (VGA_F1 weave)\n");
		fails++;
	}

	if (fails) {
		std::printf("FAIL analog_raster_mux %d checks\n", fails);
		delete top;
		return 1;
	}
	std::printf("OK analog_raster_mux: 240p~15.6kHz 480p~31kHz 480i field toggle\n");
	delete top;
	return 0;
}
