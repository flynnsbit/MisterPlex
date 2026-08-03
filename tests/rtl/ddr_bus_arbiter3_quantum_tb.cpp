// Sustained m2 WE vs m0 RD — quantum preemption oracle (rd-duck).
//
// Scenario: continuous fabric write of N_QWORDS >> LINE_COUNT(8) while m0
// always wants single-beat RDs (scanout refill). Product bounds m2 sticky to
// M2_QUANTUM_BEATS=8 so m0 cannot be locked out for a full I420 frame.
// FAULT_STICKY_NO_QUANTUM holds grant_m2 through continuous WE → REPRO starve.
//
// Env ARB3_QMODE=product|fault
#include "Vddr_bus_arbiter3_quantum_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vddr_bus_arbiter3_quantum_tb_top* top) {
	top->clk = 0;
	top->eval();
	main_time++;
	top->clk = 1;
	if ((main_time % 5u) == 0u)
		top->clk_m1 = !top->clk_m1;
	top->eval();
	main_time++;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = std::getenv("ARB3_QMODE");
	if (!mode)
		mode = "product";
	const bool fault = (std::string(mode) == "fault");

	auto* top = new Vddr_bus_arbiter3_quantum_tb_top;
	top->DDRAM_BUSY = 0;
	top->DDRAM_DOUT = 0;
	top->DDRAM_DOUT_READY = 0;
	top->m0_rd = 0;
	top->m0_addr = 0x100;
	top->m1_want = 0;
	top->m1_rd = 0;
	top->m1_addr = 0;
	top->m2_want = 0;
	top->m2_we = 0;
	top->m2_addr = 0x200;
	top->m2_din = 0xA5A5A5A5A5A5A5A5ull;
	top->clk_m1 = 0;
	top->reset = 1;
	for (int i = 0; i < 20; ++i)
		tick(top);
	top->reset = 0;
	for (int i = 0; i < 10; ++i)
		tick(top);

	// 960×540 I420 = 97200 qwords; use 256 (>> LINE_COUNT=8) to keep sim short
	// while still exceeding cache-depth continuous sticky.
	constexpr int kStreamQwords = 256;
	constexpr int kQuantum = 8;
	// Product max consecutive accepted m2 WEs while m0 wants must be ≤ quantum
	// (+1 for the beat that triggers yield). FAULT holds for the whole stream.
	constexpr int kProductMaxM2Streak = kQuantum + 2;
	constexpr int kFaultMinM2Streak = 64; // clearly > cache depth

	top->m2_want = 1;
	top->m2_we = 1;
	top->m0_rd = 1; // continuous scanout demand
	top->m0_addr = 0x100;

	int m0_accepts = 0;
	int m2_accepts = 0;
	int m2_streak = 0;
	int max_m2_streak = 0;
	int m0_wait = 0;
	int max_m0_wait = 0;
	int m2_left = kStreamQwords;

	for (int cyc = 0; cyc < 20000 && (m2_left > 0 || m0_accepts < 4); ++cyc) {
		// Ideal memory: accept cmd when !BUSY; return RD data next cycle.
		const bool cmd_slot = !top->DDRAM_BUSY;
		const bool accepted_we =
		    cmd_slot && top->DDRAM_WE && !top->DDRAM_RD;
		const bool accepted_rd =
		    cmd_slot && top->DDRAM_RD && !top->DDRAM_WE;

		if (accepted_we) {
			++m2_accepts;
			--m2_left;
			++m2_streak;
			if (m2_streak > max_m2_streak)
				max_m2_streak = m2_streak;
			top->m2_addr = top->m2_addr + 1;
			if (m2_left <= 0) {
				top->m2_we = 0;
				top->m2_want = 0;
			}
			// m0 still waiting during this WE
			if (top->m0_rd) {
				++m0_wait;
				if (m0_wait > max_m0_wait)
					max_m0_wait = m0_wait;
			}
		} else if (accepted_rd) {
			++m0_accepts;
			m2_streak = 0;
			m0_wait = 0;
			top->m0_addr = top->m0_addr + 1;
			// Single-beat rsp next cycle
			top->DDRAM_DOUT_READY = 1;
			top->DDRAM_DOUT = 0x1111;
		} else {
			top->DDRAM_DOUT_READY = 0;
			if (top->m0_rd && top->m0_busy) {
				++m0_wait;
				if (m0_wait > max_m0_wait)
					max_m0_wait = m0_wait;
			} else if (!top->m0_busy && !top->m0_rd) {
				m0_wait = 0;
			}
		}

		tick(top);
		// Clear one-cycle ready after tick (rsp consumed)
		if (top->m0_dout_ready)
			top->DDRAM_DOUT_READY = 0;
	}

	top->m0_rd = 0;
	top->m2_we = 0;
	top->m2_want = 0;
	for (int i = 0; i < 8; ++i)
		tick(top);

	std::printf("MEASURED mode=%s m2_accepts=%d m0_accepts=%d max_m2_streak=%d "
	            "max_m0_wait=%d stream=%d quantum=%d\n",
	            mode, m2_accepts, m0_accepts, max_m2_streak, max_m0_wait,
	            kStreamQwords, kQuantum);

	if (m2_accepts < kStreamQwords) {
		std::fprintf(stderr, "FAIL m2 incomplete accepts=%d want=%d\n", m2_accepts,
		             kStreamQwords);
		delete top;
		return 1;
	}
	if (m0_accepts < 1) {
		std::fprintf(stderr, "FAIL m0 zero accepts (total starve)\n");
		delete top;
		return 1;
	}

	if (fault) {
		// REPRO: continuous sticky WE locks m0 past cache depth
		if (max_m2_streak < kFaultMinM2Streak) {
			std::fprintf(stderr,
			             "FAIL fault twin: max_m2_streak=%d < %d (cannot see defect)\n",
			             max_m2_streak, kFaultMinM2Streak);
			delete top;
			return 1;
		}
		std::printf("REPRO_OK arb3 sticky m2 locks scanout max_m2_streak=%d "
		            "(> LINE_COUNT cache)\n",
		            max_m2_streak);
		delete top;
		return 0; // REPRO success of red twin
	}

	// PRODUCT: m2 streak while m0 wants must stay near quantum
	if (max_m2_streak > kProductMaxM2Streak) {
		std::fprintf(stderr,
		             "FAIL product: max_m2_streak=%d > %d (quantum broken)\n",
		             max_m2_streak, kProductMaxM2Streak);
		delete top;
		return 1;
	}
	// m0 must land many times across 256-beat write (not once at end)
	if (m0_accepts < (kStreamQwords / (kQuantum + 4))) {
		std::fprintf(stderr,
		             "FAIL product: m0_accepts=%d too low for interleaved quantum\n",
		             m0_accepts);
		delete top;
		return 1;
	}
	std::printf("OK arb3 quantum: m0 interleaved during >cache-depth m2 stream "
	            "max_m2_streak=%d m0_accepts=%d\n",
	            max_m2_streak, m0_accepts);
	delete top;
	return 0;
}
