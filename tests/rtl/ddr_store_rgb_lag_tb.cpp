// B12: measure store rd_active→RGB pipeline lag at product geometries.
#include "Vddr_store_rgb_lag_tb.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

#ifndef LAG_CODED_W
#define LAG_CODED_W 960
#endif

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const int CW = LAG_CODED_W;
	const int CH = 32;
	const int DH = 24;
	const int FW = CW;
	const uint32_t phys = (CW >= 960) ? 0x30180000u : 0x30000000u;
	const uint32_t stride = (CW >= 960) ? 0x00180000u : 0x00080000u;
	const uint32_t doorbell = phys + 2u * stride - 0x1000u;
	const uint32_t kMagic = 0x504C584Bu;

	auto* top = new Vddr_store_rgb_lag_tb;
	std::vector<uint64_t> mem((2ull * stride) / 8, 0);

	auto pack8 = [](uint8_t v) {
		uint64_t q = 0;
		for (int i = 0; i < 8; i++) q |= (uint64_t)v << (8 * i);
		return q;
	};
	auto offQ = [&](uint32_t p) { return (p - phys) / 8u; };
	auto addrOffQ = [&](uint32_t a) { return a - (phys >> 3); };

	const int y_qw = (CW * CH) / 8;
	const int c_qw = (CW * CH) / 32;
	for (int i = 0; i < y_qw; i++) mem[i] = pack8(128);
	for (int i = 0; i < c_qw; i++) {
		mem[y_qw + i] = pack8(128);
		mem[y_qw + c_qw + i] = pack8(128);
	}
	const uint32_t db_hi = (1u << 29) | 1u; // yuv + seq=1 bank0
	mem[offQ(doorbell)] = (static_cast<uint64_t>(db_hi) << 32) | kMagic;

	int busy = 0, rdDelay = -1, rdLeft = 0, rdIndex = 0;
	uint32_t rdAddr = 0;
	const int kRdDelay = 3;
	int hc = 0, vc = 0;
	const int kHTotal = FW + 64;
	const int kVBlank = 8;

	auto ddrStep = [&]() {
		top->DDRAM_BUSY = busy > 0 ? 1 : 0;
		top->DDRAM_DOUT_READY = 0;
		if (busy > 0) --busy;
		if (rdDelay > 0) {
			--rdDelay;
		} else if (rdDelay == 0 && rdLeft > 0) {
			const uint32_t idx = addrOffQ(rdAddr) + (uint32_t)rdIndex;
			top->DDRAM_DOUT = (idx < mem.size()) ? mem[idx] : 0;
			top->DDRAM_DOUT_READY = 1;
			++rdIndex;
			--rdLeft;
			if (rdLeft == 0) rdDelay = -1;
			else rdDelay = 0;
		}
		if (top->DDRAM_RD && busy == 0 && rdDelay < 0) {
			rdAddr = top->DDRAM_ADDR;
			rdLeft = top->DDRAM_BURSTCNT ? top->DDRAM_BURSTCNT : 1;
			rdIndex = 0;
			rdDelay = kRdDelay;
			busy = 1;
		}
		if (top->DDRAM_WE && busy == 0) {
			const uint32_t idx = addrOffQ(top->DDRAM_ADDR);
			if (idx < mem.size()) mem[idx] = top->DDRAM_DIN;
			busy = 1;
		}
	};

	auto tick = [&]() {
		ddrStep();
		top->clk = 0; top->clk_ddr = 0; top->eval(); main_time++;
		top->clk = 1; top->clk_ddr = 1; top->eval(); main_time++;
	};

	auto videoTick = [&]() {
		ddrStep();
		const bool active = (hc < FW) && (vc < DH);
		top->rd_active = active ? 1 : 0;
		top->rd_x = (hc < FW) ? hc : (FW - 1);
		top->rd_y = (vc < DH) ? vc : (DH - 1);
		top->vsync_pulse = (hc == 0 && vc == 0) ? 1 : 0;
		top->clk = 0; top->clk_ddr = 0; top->eval(); main_time++;
		top->clk = 1; top->clk_ddr = 1; top->eval(); main_time++;
		++hc;
		if (hc >= kHTotal) {
			hc = 0;
			++vc;
			if (vc >= DH + kVBlank) vc = 0;
		}
	};

	top->reset = 1; top->rd_x = 0; top->rd_y = 0; top->rd_active = 0;
	top->start_req = 0; top->bank_sel = 0; top->vsync_pulse = 0;
	top->DDRAM_BUSY = 0; top->DDRAM_DOUT = 0; top->DDRAM_DOUT_READY = 0;
	for (int i = 0; i < 16; i++) tick();
	top->reset = 0;
	for (int i = 0; i < 8; i++) tick();

	// Idle polls for doorbell prime
	for (int i = 0; i < 2000; i++) tick();
	top->bank_sel = 0; top->start_req = 1; tick(); top->start_req = 0;

	// Run several frames to fill lines + swap
	for (int i = 0; i < kHTotal * (DH + kVBlank) * 6; i++) videoTick();

	if (!top->has_frame) {
		std::printf("B12_LAG coded_w=%d has_frame=0 lag_cycles=-1 (no frame)\n", CW);
		std::fprintf(stderr, "FAIL: has_frame never asserted\n");
		delete top;
		return 2;
	}

	// Park inactive
	top->rd_active = 0; top->rd_x = 0; top->rd_y = 0;
	for (int i = 0; i < 32; i++) tick();

	// Dwell on line 0 so cache is warm
	hc = 0; vc = 0;
	for (int i = 0; i < FW * 3; i++) {
		top->rd_x = i % FW; top->rd_y = 0; top->rd_active = 1;
		tick();
	}
	top->rd_active = 0;
	for (int i = 0; i < 8; i++) tick();

	// Measure: assert active at x=0,y=0; count ticks until RGB nonzero
	top->rd_x = 0; top->rd_y = 0; top->rd_active = 1;
	int lag = -1;
	for (int c = 0; c < 16; c++) {
		tick();
		if (top->rd_r || top->rd_g || top->rd_b) {
			lag = c + 1;
			break;
		}
	}

	std::printf("B12_LAG coded_w=%d has_frame=%u lag_cycles=%d rgb=%u,%u,%u underrun=%u\n",
	            CW, (unsigned)top->has_frame, lag,
	            (unsigned)top->rd_r, (unsigned)top->rd_g, (unsigned)top->rd_b,
	            (unsigned)top->underrun_count);

	if (lag < 0) {
		std::fprintf(stderr, "FAIL: RGB stayed black\n");
		delete top;
		return 1;
	}
	if (lag < 1 || lag > 6) {
		std::fprintf(stderr, "FAIL: lag=%d outside 1..6\n", lag);
		delete top;
		return 1;
	}
	std::printf("PASS B12 store RGB lag measured lag_cycles=%d at coded_w=%d "
	            "(present_core DE_LAG=3 covers store path @960)\n", lag, CW);
	delete top;
	return 0;
}
