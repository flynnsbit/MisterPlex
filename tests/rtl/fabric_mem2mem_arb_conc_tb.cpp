// Concurrent m0 present-RD + m2 fabric mem2mem through ddr_bus_arbiter3.
// M2_OVER_M0=1: while m2_want, bank-fill outranks scanout (path b policy).
//
// Pre-register:
//   G0 solo m2: beats=576, bank==staging, door=1
//   G1 m0 before+during+after: copy still correct; m0_acc>0 (before/after
//      windows); during fill m2 wins (M2_OVER_M0)
//
#include <cstdint>
#include <cstdio>
#include <deque>
#include <unordered_map>

#include "Vfabric_mem2mem_arb_conc_tb_top.h"
#include "verilated.h"

static const uint32_t kQ = 576u;
static const uint32_t kPhys = 0x30180000u;
static const uint32_t kDoor = 0x30181F00u;
static const uint32_t kStage = 0x30601000u;
static const uint64_t kMagic = 0x504C584Bull;

struct PendRd {
	int delay_left;
	uint64_t data;
};

struct Bus {
	std::unordered_map<uint32_t, uint64_t> m;
	std::deque<PendRd> rdq;
	int lat = 2;
	uint64_t beats_rd = 0, beats_wr = 0, m0_acc = 0, m2_rd = 0;
	uint64_t last_db = 0, door_n = 0;

	void seed() {
		for (uint32_t i = 0; i < kQ; ++i)
			m[(kStage >> 3) + i] =
			    (uint64_t(0xC0DE0000u + i) << 32) | (0xF00Du + i);
	}
	void drive_pre(Vfabric_mem2mem_arb_conc_tb_top* t) {
		t->DDRAM_BUSY = 0;
		if (!rdq.empty()) {
			for (auto& p : rdq) {
				if (p.delay_left > 0)
					p.delay_left--;
			}
		}
		if (!rdq.empty() && rdq.front().delay_left == 0) {
			t->DDRAM_DOUT = rdq.front().data;
			t->DDRAM_DOUT_READY = 1;
			rdq.pop_front();
		} else {
			t->DDRAM_DOUT = 0;
			t->DDRAM_DOUT_READY = 0;
		}
	}
	void sample_post(Vfabric_mem2mem_arb_conc_tb_top* t) {
		if (t->DDRAM_BUSY)
			return;
		if (t->DDRAM_RD) {
			uint32_t q = uint32_t(t->DDRAM_ADDR);
			auto it = m.find(q);
			uint64_t d = it == m.end() ? 0ull : it->second;
			rdq.push_back(PendRd{lat, d});
			beats_rd++;
			if (q >= (kStage >> 3) && q < (kStage >> 3) + kQ + 8)
				m2_rd++;
			else
				m0_acc++;
		}
		if (t->DDRAM_WE) {
			uint32_t q = uint32_t(t->DDRAM_ADDR);
			m[q] = t->DDRAM_DIN;
			beats_wr++;
			if (q == (kDoor >> 3)) {
				door_n++;
				last_db = t->DDRAM_DIN;
			}
		}
	}
	bool bank_ok() const {
		for (uint32_t i = 0; i < kQ; ++i) {
			auto a = m.find((kStage >> 3) + i);
			auto b = m.find((kPhys >> 3) + i);
			if (a == m.end() || b == m.end() || a->second != b->second)
				return false;
		}
		return true;
	}
};

static void clk(Vfabric_mem2mem_arb_conc_tb_top* t, Bus& b, int& m1div) {
	b.drive_pre(t);
	t->clk = 0;
	t->eval();
	t->clk = 1;
	if (++m1div >= 5) {
		m1div = 0;
		t->clk_m1 = !t->clk_m1;
	}
	t->eval();
	b.sample_post(t);
}

static int run_case(const char* name, bool contend, int& fails) {
	auto* t = new Vfabric_mem2mem_arb_conc_tb_top;
	Bus b;
	b.seed();
	int m1div = 0;
	t->reset = 1;
	t->start = 0;
	t->bank_sel = 0;
	t->m0_rd = 0;
	t->m0_addr_q = (kPhys >> 3);
	for (int i = 0; i < 16; ++i)
		clk(t, b, m1div);
	t->reset = 0;
	for (int i = 0; i < 8; ++i)
		clk(t, b, m1div);

	// Pre-fill window: m0 traffic alone (proves m0 port under M2_OVER_M0 idle)
	if (contend) {
		for (int i = 0; i < 40; ++i) {
			t->m0_rd = (i % 2) == 0;
			clk(t, b, m1div);
		}
		t->m0_rd = 0;
		for (int i = 0; i < 8; ++i)
			clk(t, b, m1div);
	}
	const uint64_t m0_before = b.m0_acc;

	t->start = 1;
	clk(t, b, m1div);
	t->start = 0;

	uint64_t cyc = 0;
	bool done = false;
	const uint64_t lim = 100000;
	while (cyc < lim) {
		// Keep asserting m0 during fill — M2_OVER_M0 must still complete copy
		t->m0_rd = contend ? 1 : 0;
		clk(t, b, m1div);
		cyc++;
		if (t->frame_done) {
			done = true;
			t->m0_rd = 0;
			for (int i = 0; i < 16; ++i)
				clk(t, b, m1div);
			break;
		}
	}

	// Post window
	if (contend && done) {
		for (int i = 0; i < 40; ++i) {
			t->m0_rd = (i % 2) == 0;
			clk(t, b, m1div);
		}
		t->m0_rd = 0;
	}

	int local = 0;
	if (!done) {
		std::fprintf(stderr, "FAIL %s timeout\n", name);
		local++;
	}
	if (t->dbg_beats_moved != kQ) {
		std::fprintf(stderr, "FAIL %s beats=%u want %u\n", name, t->dbg_beats_moved,
		             kQ);
		local++;
	}
	if (b.beats_wr != kQ + 1) {
		std::fprintf(stderr, "FAIL %s beats_wr=%llu want %u\n", name,
		             (unsigned long long)b.beats_wr, kQ + 1);
		local++;
	}
	if (b.door_n != 1 || (b.last_db & 0xffffffffull) != kMagic) {
		std::fprintf(stderr, "FAIL %s doorbell\n", name);
		local++;
	}
	if (!b.bank_ok()) {
		std::fprintf(stderr, "FAIL %s bank!=staging\n", name);
		local++;
	}
	if (contend && m0_before == 0) {
		std::fprintf(stderr, "FAIL %s m0_before=0\n", name);
		local++;
	}
	if (contend && b.m0_acc <= m0_before) {
		// need some post-fill m0 too
		std::fprintf(stderr, "FAIL %s m0_acc did not grow after fill (%llu<=%llu)\n",
		             name, (unsigned long long)b.m0_acc, (unsigned long long)m0_before);
		local++;
	}

	std::printf("CASE %s contend=%d cyc=%llu beats=%u wr=%llu m0=%llu (pre=%llu) "
	            "m2_rd=%llu door=%llu ok=%d\n",
	            name, contend ? 1 : 0, (unsigned long long)cyc, t->dbg_beats_moved,
	            (unsigned long long)b.beats_wr, (unsigned long long)b.m0_acc,
	            (unsigned long long)m0_before, (unsigned long long)b.m2_rd,
	            (unsigned long long)b.door_n, local == 0 ? 1 : 0);

	fails += local;
	t->final();
	delete t;
	return local;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	int fails = 0;
	run_case("G0_solo_m2", false, fails);
	run_case("G1_m0_contend_M2_OVER_M0", true, fails);
	if (fails) {
		std::fprintf(stderr, "fabric_mem2mem_arb_conc_tb FAILS=%d\n", fails);
		return 1;
	}
	std::printf("fabric_mem2mem_arb_conc_tb PASS\n");
	return 0;
}
