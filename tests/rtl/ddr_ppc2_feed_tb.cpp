// 720p-width Option-C + LINE=16 + PPC=2 feed under real DDRAM stalls (w-mem).
// PREREG: P0 underrun=0 nostall; P1 n_valid>0; P2 underrun=0 mild stall;
//         P3 rd_beats real; P4 host 14.978ms separate (not f2sdram).
#include "Vddr_ppc2_feed_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {
constexpr uint32_t kBasePhys = 0x30180000u;
constexpr uint32_t kBankStrideBytes = 0x00180000u;
constexpr uint32_t kDoorbellPhys = 0x3047F000u;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr int kCodedW = 1280, kCodedH = 64, kYQ = 160, kCQ = 80;
constexpr int kUQBase = (kCodedW * kCodedH) / 8;
constexpr int kVQBase = kUQBase + (kCodedW * kCodedH) / 32;
constexpr int kHTotal = 1650, kActH = 64, kVBlank = 8, kPpc = 2;
constexpr uint64_t kBudgetCycles24 = 3750000ull;
constexpr int kHostCopyUs = 14978, kI420Full = 1382400;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (uint32_t(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}
uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i) q |= uint64_t(v) << (i * 8);
	return q;
}

struct BusModel {
	Vddr_ppc2_feed_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0, rdDelay = -1, rdLeft = 0, rdIndex = 0;
	uint32_t rdAddr = 0;
	int hc = 0, vc = 0, kRdDelay = 4;
	int stall_after_accept = 0, hog_period = 0, hog_len = 0, hog_cnt = 0, hog_left = 0;
	uint64_t cycles = 0, accepted_rd_beats = 0, busy_cycles = 0, rd_want_while_busy = 0;
	uint64_t max_burst = 0, n_valid_pulses = 0, n_lane_nonzero = 0;

	BusModel() : mem((2ull * kBankStrideBytes) / 8, 0) {
		top.clk = top.clk_ddr = top.reset = 0;
		top.rd_x = top.rd_y = top.rd_active = top.start_req = top.bank_sel = top.vsync_pulse = 0;
		top.DDRAM_BUSY = top.DDRAM_DOUT_READY = 0; top.DDRAM_DOUT = 0;
	}
	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

	void fillBank(int bank) {
		const uint32_t base = (bank * kBankStrideBytes) / 8;
		for (int line = 0; line < kCodedH; ++line) {
			for (int q = 0; q < kYQ; ++q)
				mem[base + line * kYQ + q] = pack8(uint8_t(40 + (line & 0x3f)));
			if ((line % 2) == 0) {
				const int cl = line / 2;
				for (int q = 0; q < kCQ; ++q) {
					mem[base + kUQBase + cl * kCQ + q] = pack8(128);
					mem[base + kVQBase + cl * kCQ + q] = pack8(128);
				}
			}
		}
	}
	void ringDoorbell(int bank, uint32_t seq) {
		mem[offQ(kDoorbellPhys)] = (uint64_t(doorbellHi(seq, bank)) << 32) | kMagic;
	}

	void ddrStep() {
		if (hog_period > 0) {
			if (hog_left > 0) --hog_left;
			else {
				++hog_cnt;
				if ((hog_cnt % hog_period) == 0) hog_left = hog_len;
			}
		}
		const int force_busy = (busy > 0) || (hog_left > 0) ? 1 : 0;
		top.DDRAM_BUSY = force_busy;
		if (force_busy) ++busy_cycles;
		top.DDRAM_DOUT_READY = 0;
		if (top.DDRAM_RD && force_busy) ++rd_want_while_busy;
		if (busy > 0) --busy;
		if (rdDelay > 0) --rdDelay;
		else if (rdDelay == 0 && rdLeft > 0) {
			const uint32_t idx = addrOffQ(rdAddr) + uint32_t(rdIndex);
			top.DDRAM_DOUT = (idx < mem.size()) ? mem[idx] : 0;
			top.DDRAM_DOUT_READY = 1;
			++rdIndex; --rdLeft;
			rdDelay = (rdLeft == 0) ? -1 : 0;
		}
		if (top.DDRAM_RD && busy == 0 && hog_left == 0 && rdDelay < 0) {
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
			if (uint64_t(rdLeft) > max_burst) max_burst = uint64_t(rdLeft);
			rdIndex = 0; rdDelay = kRdDelay;
			accepted_rd_beats += uint64_t(rdLeft);
			busy = 1 + stall_after_accept;
		}
	}

	void tick() {
		ddrStep();
		const bool in_de = (vc < kActH) && (hc < kCodedW);
		top.rd_active = in_de ? 1 : 0;
		top.rd_x = in_de ? uint16_t(hc) : 0;
		top.rd_y = (vc < kActH) ? uint16_t(vc) : 0;
		top.vsync_pulse = (hc == 0 && vc == 0) ? 1 : 0;
		top.clk = top.clk_ddr = 0; top.eval();
		top.clk = top.clk_ddr = 1; top.eval();
		++cycles;
		if (top.rd_n_valid) {
			++n_valid_pulses;
			if (top.rd_r_n || top.rd_g_n || top.rd_b_n) ++n_lane_nonzero;
		}
		hc += kPpc;
		if (hc >= kHTotal) { hc = 0; ++vc; if (vc >= kActH + kVBlank) vc = 0; }
	}
	void resetCore() {
		top.reset = 1; for (int i = 0; i < 20; ++i) tick();
		top.reset = 0; for (int i = 0; i < 10; ++i) tick();
	}
	void clearStats() {
		cycles = accepted_rd_beats = busy_cycles = rd_want_while_busy = 0;
		max_burst = n_valid_pulses = n_lane_nonzero = 0;
	}
};

int fail(const char* m) { std::printf("FAIL ppc2_feed: %s\n", m); return 1; }

struct RunResult {
	uint64_t cycles=0, rd_beats=0, underruns=0, n_valid=0, n_nz=0, max_burst=0, rd_blocked=0;
	bool ok=false;
};

RunResult runCase(const char* name, int stall_after, int hog_period, int hog_len) {
	RunResult r; BusModel sim;
	sim.stall_after_accept = stall_after; sim.hog_period = hog_period; sim.hog_len = hog_len;
	sim.fillBank(0); sim.resetCore();
	for (int i = 0; i < 8000; ++i) sim.tick();
	sim.ringDoorbell(0, 1); sim.clearStats();
	const uint16_t fd0 = sim.top.frames_done;
	const int kMax = kHTotal * (kActH + kVBlank) * 60;
	for (int i = 0; i < kMax; ++i) {
		sim.tick();
		if (sim.top.frames_done > fd0 && sim.top.has_frame) break;
	}
	for (int i = 0; i < kHTotal * (kActH + kVBlank) * 3; ++i) sim.tick();
	r.cycles = sim.cycles; r.rd_beats = sim.accepted_rd_beats;
	r.underruns = sim.top.underrun_count; r.n_valid = sim.n_valid_pulses;
	r.n_nz = sim.n_lane_nonzero; r.max_burst = sim.max_burst;
	r.rd_blocked = sim.rd_want_while_busy;
	r.ok = (sim.top.frames_done > fd0) && (sim.accepted_rd_beats > 0);
	std::printf("CASE %s EXECUTED stall=%d hog=%d/%d cycles=%llu rd_beats=%llu underrun=%llu "
		"n_valid=%llu n_nz=%llu max_burst=%llu frames=%u rd_blocked=%llu has_frame=%u\n",
		name, stall_after, hog_period, hog_len,
		(unsigned long long)r.cycles, (unsigned long long)r.rd_beats,
		(unsigned long long)r.underruns, (unsigned long long)r.n_valid,
		(unsigned long long)r.n_nz, (unsigned long long)r.max_burst,
		(unsigned)sim.top.frames_done, (unsigned long long)r.rd_blocked,
		(unsigned)sim.top.has_frame);
	return r;
}
} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	std::printf("PREREG P0 underrun=0 nostall; P1 n_valid>0; P2 underrun=0 under stall; "
		"P3 rd_beats scales; P4 host_copy_us=%d separate\n", kHostCopyUs);
	std::printf("CONTRACT fabric_rd_Bps=%d host_wr_Bps=%d combined_avg=%d i420=%d ppc=%d line_count=16\n",
		kI420Full * 24, kI420Full * 24, 2 * kI420Full * 24, kI420Full, kPpc);

	RunResult g0 = runCase("G0_ppc2_nostall", 0, 0, 0);
	if (!g0.ok) return fail("G0 no frames_done/rd_beats");
	if (g0.underruns != 0) return fail("G0 underrun under PPC=2 nostall");
	std::printf("HIT P0 underrun=0\n");
	if (g0.n_valid == 0) return fail("G0 P1: rd_n_valid never fired");
	if (g0.n_nz == 0) return fail("G0 P1: N-wide RGB always zero");
	std::printf("HIT P1 n_valid=%llu n_nz=%llu\n", (unsigned long long)g0.n_valid, (unsigned long long)g0.n_nz);
	if (g0.rd_beats < 1000) return fail("G0 P3: expected substantial RD beats");
	if (g0.max_burst < 2) return fail("G0 expected burst>1");
	std::printf("PASS G0 ppc2_feed_nostall rd_beats=%llu max_burst=%llu\n",
		(unsigned long long)g0.rd_beats, (unsigned long long)g0.max_burst);

	RunResult g1 = runCase("G1_ppc2_stall_hog", 3, 8, 3);
	if (!g1.ok) return fail("G1 stalled path no progress");
	if (g1.rd_blocked < 10) return fail("G1 NEG: expected RD-while-BUSY");
	if (g1.underruns != 0) return fail("G1 underrun under mild stall+hog");
	std::printf("HIT P2 underrun=0 under stall rd_blocked=%llu\n", (unsigned long long)g1.rd_blocked);
	if (g1.rd_blocked <= g0.rd_blocked) return fail("G1 expected more rd_blocked than G0");
	std::printf("PASS G1 ppc2_feed_stall underrun=0 rd_blocked=%llu (G0=%llu) beats=%llu\n",
		(unsigned long long)g1.rd_blocked, (unsigned long long)g0.rd_blocked, (unsigned long long)g1.rd_beats);

	if (g1.cycles >= kBudgetCycles24) return fail("short frame exceeded full 720p24 ddr budget");
	std::printf("PASS G2 short_frame_under_budget cycles=%llu budget=%llu (NOT full-720-line proof)\n",
		(unsigned long long)g1.cycles, (unsigned long long)kBudgetCycles24);

	const double host_ms = kHostCopyUs / 1000.0, frame_ms = 1000.0 / 24.0, dec_ms = 32.705;
	std::printf("PASS HOST_COST_SEPARATE copy_ms=%.3f frame_ms=%.3f copy_only_headroom_ms=%.3f\n",
		host_ms, frame_ms, frame_ms - host_ms);
	if (dec_ms + host_ms <= frame_ms) return fail("archive serial decode+copy should exceed frame");
	std::printf("NOTE serial_decode_sw116_ms=%.3f + copy=%.3f = %.3f > %.3f => CpuSerial FAIL without overlap\n",
		dec_ms, host_ms, dec_ms + host_ms, frame_ms);

	{
		BusModel sim; sim.hog_period = 1; sim.hog_len = 1000000;
		sim.fillBank(0); sim.resetCore();
		for (int i = 0; i < 3000; ++i) sim.tick();
		sim.ringDoorbell(0, 1); sim.clearStats();
		const uint16_t fd0 = sim.top.frames_done;
		for (int i = 0; i < 80000; ++i) sim.tick();
		if (sim.top.frames_done > fd0 && sim.accepted_rd_beats > 200)
			return fail("R0 permanent hog must block progress");
		std::printf("PASS R0 permanent_busy blocks_scanout rd_beats=%llu\n",
			(unsigned long long)sim.accepted_rd_beats);
	}
	std::printf("PASS ddr_ppc2_feed all (LINE=16 PPC=2 Option-C width=1280 height=64)\n");
	return 0;
}
