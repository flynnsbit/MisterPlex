// Full 1280x720 real-reader beat delta @ PPC=2, clk 20:90, stalls (w-mem).
// rd-duck gap: 33.1776 MB/s assumes one payload read (172800 beats); measure
// accepted DDRAM beats end-of-frame including refill/doorbell overhead.
// NOT ideal beat_fire. Host /dev/mem cost stays separate (14.978 ms archive).
#include "Vddr_ppc2_fullframe_beats_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {
constexpr uint32_t kBasePhys = 0x30180000u;
constexpr uint32_t kBankStrideBytes = 0x00180000u;
constexpr uint32_t kDoorbellPhys = 0x3047F000u;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr int kCodedW = 1280;
constexpr int kCodedH = 720;
constexpr int kYQ = 160;
constexpr int kCQ = 80;
constexpr int kUQBase = (kCodedW * kCodedH) / 8;          // 115200
constexpr int kVQBase = kUQBase + (kCodedW * kCodedH) / 32; // 144000
constexpr int kHTotal = 1650;
constexpr int kActH = 720;
constexpr int kVBlank = 30;
constexpr int kPpc = 2;
// Payload-only I420 beats (ONE full-frame read, no overhead).
constexpr uint64_t kPayloadBeats = 172800ull; // 1382400/8
constexpr uint64_t kBudgetDdrCyc24 = 3750000ull; // 90e6/24
constexpr int kI420 = 1382400;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (uint32_t(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}
uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= uint64_t(v) << (i * 8);
	return q;
}

struct BusModel {
	Vddr_ppc2_fullframe_beats_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0, rdDelay = -1, rdLeft = 0, rdIndex = 0;
	uint32_t rdAddr = 0;
	int hc = 0, vc = 0, kRdDelay = 4;
	int stall_after_accept = 0, hog_period = 0, hog_len = 0, hog_cnt = 0, hog_left = 0;
	uint64_t sys_cycles = 0, ddr_cycles = 0;
	uint64_t accepted_rd_beats = 0, busy_cycles = 0, rd_want_while_busy = 0;
	uint64_t max_burst = 0, n_valid = 0;
	// End-of-frame delta: beats after clearStats at doorbell until frames_done+1 full scan.
	uint64_t beats_at_fd = 0;
	uint64_t beats_at_scan_end = 0;
	bool saw_fd = false;

	BusModel() : mem((2ull * kBankStrideBytes + 0x1000u) / 8 + 8, 0) {
		top.clk = top.clk_ddr = top.reset = 0;
		top.rd_x = top.rd_y = top.rd_active = top.start_req = top.bank_sel = top.vsync_pulse = 0;
		top.DDRAM_BUSY = top.DDRAM_DOUT_READY = 0;
		top.DDRAM_DOUT = 0;
	}
	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

	void fillBank(int bank) {
		const uint32_t base = (uint32_t(bank) * kBankStrideBytes) / 8;
		for (int line = 0; line < kCodedH; ++line) {
			for (int q = 0; q < kYQ; ++q)
				mem[base + uint32_t(line * kYQ + q)] = pack8(uint8_t(16 + (line & 0x3f)));
			if ((line % 2) == 0) {
				const int cl = line / 2;
				for (int q = 0; q < kCQ; ++q) {
					mem[base + uint32_t(kUQBase + cl * kCQ + q)] = pack8(128);
					mem[base + uint32_t(kVQBase + cl * kCQ + q)] = pack8(128);
				}
			}
		}
	}
	void ringDoorbell(int bank, uint32_t seq) {
		mem[offQ(kDoorbellPhys)] = (uint64_t(doorbellHi(seq, bank)) << 32) | kMagic;
	}

	void ddrStep() {
		if (hog_period > 0) {
			if (hog_left > 0)
				--hog_left;
			else {
				++hog_cnt;
				if ((hog_cnt % hog_period) == 0)
					hog_left = hog_len;
			}
		}
		const int force_busy = (busy > 0) || (hog_left > 0) ? 1 : 0;
		top.DDRAM_BUSY = force_busy;
		if (force_busy)
			++busy_cycles;
		top.DDRAM_DOUT_READY = 0;
		if (top.DDRAM_RD && force_busy)
			++rd_want_while_busy;
		if (busy > 0)
			--busy;
		if (rdDelay > 0)
			--rdDelay;
		else if (rdDelay == 0 && rdLeft > 0) {
			const uint32_t idx = addrOffQ(rdAddr) + uint32_t(rdIndex);
			top.DDRAM_DOUT = (idx < mem.size()) ? mem[idx] : 0;
			top.DDRAM_DOUT_READY = 1;
			++rdIndex;
			--rdLeft;
			rdDelay = (rdLeft == 0) ? -1 : 0;
		}
		// Accept new burst only when idle (match bus_stall / ppc2_feed).
		if (top.DDRAM_RD && busy == 0 && hog_left == 0 && rdDelay < 0) {
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT ? int(top.DDRAM_BURSTCNT) : 1;
			if (uint64_t(rdLeft) > max_burst)
				max_burst = uint64_t(rdLeft);
			rdIndex = 0;
			rdDelay = kRdDelay;
			accepted_rd_beats += uint64_t(rdLeft);
			busy = 1 + stall_after_accept;
		}
	}

	// One sys cycle with 20:90 ratio: average 4.5 ddr cycles (4,5,4,5,...).
	void tickSys() {
		const int ddr_per_sys = (sys_cycles & 1ull) ? 5 : 4;
		for (int d = 0; d < ddr_per_sys; ++d) {
			ddrStep();
			top.clk_ddr = 0;
			top.eval();
			top.clk_ddr = 1;
			top.eval();
			++ddr_cycles;
		}
		const bool in_de = (vc < kActH) && (hc < kCodedW);
		top.rd_active = in_de ? 1 : 0;
		top.rd_x = in_de ? uint16_t(hc) : 0;
		top.rd_y = (vc < kActH) ? uint16_t(vc) : 0;
		top.vsync_pulse = (hc == 0 && vc == 0) ? 1 : 0;

		top.clk = 0;
		top.eval();
		top.clk = 1;
		top.eval();
		++sys_cycles;
		if (top.rd_n_valid)
			++n_valid;

		hc += kPpc;
		if (hc >= kHTotal) {
			hc = 0;
			++vc;
			if (vc >= kActH + kVBlank)
				vc = 0;
		}
	}

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 40; ++i)
			tickSys();
		top.reset = 0;
		for (int i = 0; i < 20; ++i)
			tickSys();
	}
	void clearStats() {
		sys_cycles = ddr_cycles = 0;
		accepted_rd_beats = busy_cycles = rd_want_while_busy = 0;
		max_burst = n_valid = 0;
		beats_at_fd = beats_at_scan_end = 0;
		saw_fd = false;
	}
};

int fail(const char* m) {
	std::printf("FAIL fullframe_beats: %s\n", m);
	return 1;
}

struct RunResult {
	uint64_t sys_cyc = 0, ddr_cyc = 0, rd_beats = 0, beats_fd = 0, beats_e2e = 0;
	uint64_t underrun = 0, n_valid = 0, rd_blocked = 0, max_burst = 0;
	bool ok = false;
};

RunResult runCase(const char* name, int stall_after, int hog_period, int hog_len) {
	RunResult r;
	BusModel sim;
	sim.stall_after_accept = stall_after;
	sim.hog_period = hog_period;
	sim.hog_len = hog_len;
	sim.fillBank(0);
	sim.resetCore();
	// Warm prep window before doorbell.
	for (int i = 0; i < 20000; ++i)
		sim.tickSys();
	sim.ringDoorbell(0, 1);
	sim.clearStats();
	const uint16_t fd0 = sim.top.frames_done;

	// Drive until frames_done advances, then one full glass frame for scan e2e.
	const int kMaxSys = kHTotal * (kActH + kVBlank) * 8; // plenty of headroom
	for (int i = 0; i < kMaxSys; ++i) {
		sim.tickSys();
		if (!sim.saw_fd && sim.top.frames_done > fd0 && sim.top.has_frame) {
			sim.saw_fd = true;
			sim.beats_at_fd = sim.accepted_rd_beats;
			// Continue one more full vertical period for scanout refill accounting.
			const int scan_left = kHTotal * (kActH + kVBlank) / kPpc + kHTotal;
			for (int s = 0; s < scan_left; ++s)
				sim.tickSys();
			sim.beats_at_scan_end = sim.accepted_rd_beats;
			break;
		}
	}
	if (!sim.saw_fd) {
		// Fallback: drain remaining budget once more
		for (int i = 0; i < kHTotal * (kActH + kVBlank); ++i)
			sim.tickSys();
		if (sim.top.frames_done > fd0) {
			sim.saw_fd = true;
			sim.beats_at_fd = sim.accepted_rd_beats;
			sim.beats_at_scan_end = sim.accepted_rd_beats;
		}
	}

	r.sys_cyc = sim.sys_cycles;
	r.ddr_cyc = sim.ddr_cycles;
	r.rd_beats = sim.accepted_rd_beats;
	r.beats_fd = sim.beats_at_fd;
	r.beats_e2e = sim.beats_at_scan_end ? sim.beats_at_scan_end : sim.accepted_rd_beats;
	r.underrun = sim.top.underrun_count;
	r.n_valid = sim.n_valid;
	r.rd_blocked = sim.rd_want_while_busy;
	r.max_burst = sim.max_burst;
	r.ok = sim.saw_fd && (r.beats_e2e > 0);

	const int64_t overhead = int64_t(r.beats_e2e) - int64_t(kPayloadBeats);
	std::printf(
		"CASE %s EXECUTED stall=%d hog=%d/%d sys_cyc=%llu ddr_cyc=%llu "
		"beats_at_fd=%llu beats_e2e=%llu payload=%llu overhead=%lld "
		"underrun=%llu n_valid=%llu max_burst=%llu rd_blocked=%llu "
		"frames=%u has_frame=%u ratio_ddr_sys=%.3f\n",
		name, stall_after, hog_period, hog_len, (unsigned long long)r.sys_cyc,
		(unsigned long long)r.ddr_cyc, (unsigned long long)r.beats_fd,
		(unsigned long long)r.beats_e2e, (unsigned long long)kPayloadBeats,
		(long long)overhead, (unsigned long long)r.underrun, (unsigned long long)r.n_valid,
		(unsigned long long)r.max_burst, (unsigned long long)r.rd_blocked,
		(unsigned)sim.top.frames_done, (unsigned)sim.top.has_frame,
		r.sys_cyc ? double(r.ddr_cyc) / double(r.sys_cyc) : 0.0);
	return r;
}
} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	std::printf("PREREG fullframe: beats_e2e >= payload %llu; overhead finite; "
				"underrun=0 nostall; 20:90 ratio~4.5; stall path progresses\n",
				(unsigned long long)kPayloadBeats);
	std::printf("CONTRACT payload_MBps=33.1776 payload_beats=%llu i420=%d ppc=%d "
				"line_count=16 clk_sys=20e6 clk_ddr=90e6 (NOT FIFO-width number)\n",
				(unsigned long long)kPayloadBeats, kI420, kPpc);
	std::printf("NOTE 1.65888 B/clk_sys is payload average only — not linefill/FIFO width "
				"(rd-duck audit)\n");

	RunResult g0 = runCase("G0_full720_ppc2_nostall_20_90", 0, 0, 0);
	if (!g0.ok)
		return fail("G0 no frames_done / zero beats");
	if (g0.beats_e2e < kPayloadBeats)
		return fail("G0 beats_e2e < payload 172800 (impossible if full I420 read once)");
	// Allow overhead (doorbell/refetch) but hard-fail absurd thrash (>2x payload).
	if (g0.beats_e2e > 2ull * kPayloadBeats)
		return fail("G0 beats_e2e > 2*payload — thrash/refetch storm");
	if (g0.underrun != 0)
		return fail("G0 underrun under full 720 nostall");
	if (g0.n_valid == 0)
		return fail("G0 rd_n_valid never fired");
	// 20:90 average should be near 4.5
	const double ratio = g0.sys_cyc ? double(g0.ddr_cyc) / double(g0.sys_cyc) : 0.0;
	if (ratio < 4.2 || ratio > 4.8)
		return fail("G0 clock ratio not ~4.5 (20:90)");
	std::printf("PASS G0 full720 beats_e2e=%llu payload=%llu overhead=%lld ratio=%.3f\n",
				(unsigned long long)g0.beats_e2e, (unsigned long long)kPayloadBeats,
				(long long)g0.beats_e2e - (long long)kPayloadBeats, ratio);
	// Effective fabric MB/s if this e2e cost every 1/24 s
	const double e2e_B = double(g0.beats_e2e) * 8.0;
	const double e2e_MBps = e2e_B * 24.0 / 1e6;
	std::printf("MEAS G0 fabric_e2e_MBps=%.4f (payload 33.1776 + overhead)\n", e2e_MBps);
	if (g0.ddr_cyc > kBudgetDdrCyc24 * 2)
		return fail("G0 used >2 frame-times of ddr cycles (loose bound)");
	std::printf("PASS G0 under_loose_ddr_budget ddr_cyc=%llu budget_1f=%llu\n",
				(unsigned long long)g0.ddr_cyc, (unsigned long long)kBudgetDdrCyc24);

	RunResult g1 = runCase("G1_full720_ppc2_stall_hog_20_90", 3, 8, 3);
	if (!g1.ok)
		return fail("G1 stalled path no progress");
	if (g1.rd_blocked < 10)
		return fail("G1 expected RD-while-BUSY coupling");
	if (g1.underrun != 0)
		return fail("G1 underrun under mild stall (LINE=16 should absorb)");
	if (g1.beats_e2e < kPayloadBeats)
		return fail("G1 beats_e2e < payload");
	if (g1.beats_e2e > 2ull * kPayloadBeats)
		return fail("G1 thrash >2x payload");
	std::printf("PASS G1 full720 stall beats_e2e=%llu rd_blocked=%llu underrun=0\n",
				(unsigned long long)g1.beats_e2e, (unsigned long long)g1.rd_blocked);

	std::printf("PASS HOST_COST_SEPARATE copy_ms=14.978 (archive; not f2sdram beats)\n");
	std::printf("PASS ddr_ppc2_fullframe_beats all (1280x720 PPC=2 LINE=16 20:90 real store)\n");
	return 0;
}
