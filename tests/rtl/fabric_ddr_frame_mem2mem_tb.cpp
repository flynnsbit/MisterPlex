// fabric_ddr_frame_mem2mem_tb — path (b) fabric mem2mem retires ARM bank copy.
//
// Pre-register (before measure):
//   P0 ideal no-stall: beats_moved == 172800; cycles floor ≥ 2*172800 = 345600
//      clk_ddr (serial RD then WE, outstanding=1) + drain + doorbell.
//   P1 injected BUSY: still correct payload+doorbell; cycles > P0.
//   P2 bank1 write lands at PHYS+STRIDE.
//
// Compare wall: T_arm_copy = 14.978 ms (parent archive). Ideal peak @90 MHz
//   345600/90e6 ≈ 3.84 ms round-trip min (R then W serial outstanding=1).
//
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unordered_map>

#include "Vfabric_ddr_frame_mem2mem_tb_top.h"
#include "verilated.h"

static const uint32_t kFrameBytes = 1382400u;
static const uint32_t kFrameQwords = kFrameBytes / 8u; // 172800
static const uint32_t kPhysBase = 0x30180000u;
static const uint32_t kStride = 0x180000u;
static const uint32_t kDoorbell = 0x3047F000u;
static const uint32_t kStaging = 0x30601000u;
static const uint64_t kMagic = 0x504C584Bull;

struct MemModel {
	std::unordered_map<uint32_t, uint64_t> m; // qword index → data
	int lat = 2; // cycles after RD accept until DOUT_READY high for one cycle
	int busy_every = 0;
	int busy_phase = 0;
	int rd_delay = -1; // -1 idle; 0 = deliver this cycle; >0 counting down
	uint64_t rd_data = 0;
	uint64_t beats_rd = 0;
	uint64_t beats_wr = 0;
	uint64_t doorbell_writes = 0;
	uint64_t last_db = 0;

	void seed_staging(uint32_t nq) {
		for (uint32_t i = 0; i < nq; ++i) {
			uint32_t q = (kStaging >> 3) + i;
			m[q] = (uint64_t(0xA5A50000u + i) << 32) | uint64_t(0x5A5A0000u + i);
		}
	}

	bool busy_now() const {
		if (busy_every <= 0)
			return false;
		return (busy_phase % busy_every) == 0;
	}

	// Drive inputs BEFORE posedge so DUT samples them.
	void drive_pre(Vfabric_ddr_frame_mem2mem_tb_top* t) {
		busy_phase++;
		t->DDRAM_BUSY = busy_now() ? 1 : 0;
		if (rd_delay == 0) {
			t->DDRAM_DOUT = rd_data;
			t->DDRAM_DOUT_READY = 1;
			rd_delay = -1;
		} else {
			t->DDRAM_DOUT = 0;
			t->DDRAM_DOUT_READY = 0;
			if (rd_delay > 0)
				rd_delay--;
		}
	}

	// Sample outputs AFTER posedge.
	void sample_post(Vfabric_ddr_frame_mem2mem_tb_top* t) {
		if (!t->DDRAM_BUSY) {
			if (t->DDRAM_RD) {
				uint32_t q = uint32_t(t->DDRAM_ADDR);
				auto it = m.find(q);
				rd_data = (it == m.end()) ? 0ull : it->second;
				rd_delay = lat; // deliver after `lat` full cycles
				beats_rd++;
			}
			if (t->DDRAM_WE) {
				uint32_t q = uint32_t(t->DDRAM_ADDR);
				uint64_t d = t->DDRAM_DIN;
				m[q] = d;
				beats_wr++;
				if (q == (kDoorbell >> 3)) {
					doorbell_writes++;
					last_db = d;
				}
			}
		}
	}

	bool bank_matches_staging(int bank, uint32_t nq) const {
		uint32_t base = (kPhysBase >> 3) + (bank ? (kStride >> 3) : 0u);
		uint32_t st = kStaging >> 3;
		for (uint32_t i = 0; i < nq; ++i) {
			auto a = m.find(st + i);
			auto b = m.find(base + i);
			if (a == m.end() || b == m.end() || a->second != b->second)
				return false;
		}
		return true;
	}
};

static void clk(Vfabric_ddr_frame_mem2mem_tb_top* t, MemModel& mem) {
	mem.drive_pre(t);
	t->clk = 0;
	t->eval();
	t->clk = 1;
	t->eval();
	mem.sample_post(t);
}

static int run_case(const char* name, int busy_every, int bank, int& fails) {
	auto* t = new Vfabric_ddr_frame_mem2mem_tb_top;
	MemModel mem;
	mem.lat = 2;
	mem.busy_every = busy_every;
	mem.seed_staging(kFrameQwords);

	t->reset = 1;
	t->start = 0;
	t->bank_sel = bank ? 1 : 0;
	t->staging_phys_use_rt = 0;
	t->staging_phys_rt = 0;
	for (int i = 0; i < 8; ++i)
		clk(t, mem);
	t->reset = 0;
	for (int i = 0; i < 4; ++i)
		clk(t, mem);

	// Pulse start one cycle
	t->start = 1;
	clk(t, mem);
	t->start = 0;

	const uint64_t max_cyc = 3ull * 1000ull * 1000ull;
	uint64_t cyc = 0;
	bool done = false;
	while (cyc < max_cyc) {
		clk(t, mem);
		cyc++;
		if (t->frame_done) {
			done = true;
			clk(t, mem);
			break;
		}
	}

	int local = 0;
	auto fail = [&](const char* msg) {
		std::fprintf(stderr, "FAIL %s: %s\n", name, msg);
		local++;
	};

	if (!done)
		fail("timeout waiting frame_done");
	if (t->dbg_beats_moved != kFrameQwords) {
		std::fprintf(stderr, "FAIL %s: beats_moved=%u want %u\n", name,
		             t->dbg_beats_moved, kFrameQwords);
		local++;
	}
	if (mem.beats_rd != kFrameQwords) {
		std::fprintf(stderr, "FAIL %s: mem.beats_rd=%llu want %u\n", name,
		             (unsigned long long)mem.beats_rd, kFrameQwords);
		local++;
	}
	if (mem.beats_wr != kFrameQwords + 1u) {
		std::fprintf(stderr, "FAIL %s: mem.beats_wr=%llu want %u\n", name,
		             (unsigned long long)mem.beats_wr, kFrameQwords + 1u);
		local++;
	}
	if (mem.doorbell_writes != 1) {
		std::fprintf(stderr, "FAIL %s: doorbell_writes=%llu\n", name,
		             (unsigned long long)mem.doorbell_writes);
		local++;
	}
	if ((mem.last_db & 0xFFFFFFFFull) != kMagic) {
		std::fprintf(stderr, "FAIL %s: doorbell lo magic 0x%llx\n", name,
		             (unsigned long long)(mem.last_db & 0xffffffffull));
		local++;
	}
	uint32_t db_hi = uint32_t(mem.last_db >> 32);
	int bank_bit = (db_hi >> 31) & 1;
	if (bank_bit != bank) {
		std::fprintf(stderr, "FAIL %s: doorbell bank_bit=%d want %d hi=0x%08x\n",
		             name, bank_bit, bank, db_hi);
		local++;
	}
	if (!mem.bank_matches_staging(bank, kFrameQwords))
		fail("bank payload != staging seed");

	const double t_ms = (double)cyc / 90e6 * 1000.0;
	const double t_arm = 14.978;
	std::printf("CASE %s bank=%d busy_every=%d cyc=%llu t_est_ms@90MHz=%.3f "
	            "vs T_arm=%.3f ms beats_moved=%u rd=%llu wr=%llu ok=%d\n",
	            name, bank, busy_every, (unsigned long long)cyc, t_ms, t_arm,
	            t->dbg_beats_moved, (unsigned long long)mem.beats_rd,
	            (unsigned long long)mem.beats_wr, local == 0 ? 1 : 0);

	if (busy_every == 0 && done && t_ms >= t_arm) {
		std::fprintf(stderr,
		             "FAIL %s: ideal fabric slower than ARM copy (%.3f >= %.3f)\n",
		             name, t_ms, t_arm);
		local++;
	}

	fails += local;
	t->final();
	delete t;
	return local;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	int fails = 0;

	run_case("G0_ideal_b0", 0, 0, fails);
	run_case("G1_busy4_b0", 4, 0, fails);
	run_case("G2_ideal_b1", 0, 1, fails);

	if (fails) {
		std::fprintf(stderr, "fabric_ddr_frame_mem2mem_tb FAILS=%d\n", fails);
		return 1;
	}
	std::printf("fabric_ddr_frame_mem2mem_tb PASS\n");
	return 0;
}
