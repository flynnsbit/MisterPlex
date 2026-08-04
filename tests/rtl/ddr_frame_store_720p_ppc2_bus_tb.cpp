// Full 1280×720 real-reader beat delta @ MULTI+PPC2, clk 20:90 + stalls (w-osd).
// Parent/rd-duck hard blocker: FULL frame AND injected stalls together @20:90.
// REAL ddr_frame_store (not stub). Classifies payload vs doorbell/mailbox.
//
// PRE-REG (publish before measure):
//   payload ideal = 172800 beats (1382400/8 I420 qwords)
//   G0 full+ideal: payload>=172800, de_groups>=460800, underrun=0, ddr_cy<3750000
//   G1 full+stall: payload complete, de>=460800, underrun=0, blocked>=10, busy↑
//   LINE_COUNT product floor >= 32; LC=8 teeth must RED
//   V-blank rd_y=0 so want_y prefetches frame start (else wrap underruns)
//   PPC=2: rd_x steps by 2; PX_PER_CLK=2 in DUT

#include "Vddr_frame_store_720p_ppc2_bus_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30180000u;
constexpr uint32_t kBankStrideBytes = 0x00180000u; // 1.5 MiB
constexpr uint32_t kDoorbellPhys = 0x3047F000u;
constexpr uint32_t kMagic = 0x504C584Bu;

constexpr int kCodedW = 1280;
constexpr int kCodedH = 720;
constexpr int kPPC = 2;
constexpr int kYQ = kCodedW / 8;           // 160
constexpr int kCQ = kCodedW / 16;          // 80
constexpr int kUQBase = (kCodedW * kCodedH) / 8;   // 115200 Y qwords
constexpr int kUQwords = (kCodedW * kCodedH) / 32; // 28800 U qwords
constexpr int kVBaseQ = kUQBase + kUQwords;        // 144000 V base
// Total payload qwords = 115200+28800+28800 = 172800
constexpr uint64_t kPayloadBeatsIdeal = 172800ull;
constexpr uint64_t kBudgetDdrCycles24 = 3750000ull; // 90e6/24

// Beam on clk_sys: MULTI-class groups (2 px/clk). CEA-ish totals halved in X.
constexpr int kHActiveG = kCodedW / kPPC; // 640
constexpr int kVActive = kCodedH;         // 720
constexpr int kHTotalG = 825;             // 1650/2
constexpr int kVTotal = 750;              // CEA V total

// 20 MHz sys, 90 MHz ddr — half-periods in ps
constexpr int64_t kHalfSysPs = 25000; // 50 ns period
constexpr int64_t kHalfDdrPs = 5556;  // ~11.111 ns period

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (i * 8);
	return q;
}

struct Stats {
	uint64_t accepted_rd_beats = 0;
	uint64_t payload_beats = 0;
	uint64_t doorbell_beats = 0;
	uint64_t other_beats = 0;
	uint64_t busy_cycles = 0;
	uint64_t rd_blocked = 0;
	uint64_t max_burst = 0;
	uint64_t sys_cycles = 0;
	uint64_t ddr_cycles = 0;
	uint64_t de_groups = 0;
	uint16_t underrun_start = 0;
	uint16_t underrun_end = 0;
	uint16_t underrun_delta() const {
		return static_cast<uint16_t>(underrun_end - underrun_start);
	}
};

struct BusModel {
	Vddr_frame_store_720p_ppc2_bus_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int kRdDelay = 4;
	int stall_after_accept = 0;
	int hog_period = 0;
	int hog_len = 0;
	int hog_cnt = 0;
	int hog_left = 0;

	int hc = 0;
	int vc = 0;
	int64_t t_ps = 0;
	int64_t next_sys = kHalfSysPs;
	int64_t next_ddr = kHalfDdrPs;
	uint8_t clk_sys_lvl = 0;
	uint8_t clk_ddr_lvl = 0;

	Stats st{};

	BusModel() : mem((2ull * kBankStrideBytes) / 8ull, 0) {
		top.clk = 0;
		top.clk_ddr = 0;
		top.reset = 0;
		top.rd_x = 0;
		top.rd_y = 0;
		top.rd_active = 0;
		top.start_req = 0;
		top.bank_sel = 0;
		top.vsync_pulse = 0;
		top.DDRAM_BUSY = 0;
		top.DDRAM_DOUT = 0;
		top.DDRAM_DOUT_READY = 0;
	}

	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8u; }
	uint32_t addrOffQ(uint32_t addr) const {
		return addr - (kBasePhys >> 3);
	}

	void fillBank(int bank) {
		const uint32_t base = (bank * kBankStrideBytes) / 8u;
		for (int line = 0; line < kCodedH; ++line) {
			for (int q = 0; q < kYQ; ++q)
				mem[base + line * kYQ + q] = pack8(static_cast<uint8_t>(16 + (line & 0x7f)));
		}
		for (int line = 0; line < kCodedH / 2; ++line) {
			for (int q = 0; q < kCQ; ++q) {
				mem[base + kUQBase + line * kCQ + q] = pack8(128);
				mem[base + kVBaseQ + line * kCQ + q] = pack8(128);
			}
		}
	}

	void ringDoorbell(int bank, uint32_t seq) {
		mem[offQ(kDoorbellPhys)] =
		    (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagic;
	}

	void classifyAccept(uint32_t addr_q, int nbeats) {
		const uint64_t n = static_cast<uint64_t>(nbeats);
		st.accepted_rd_beats += n;
		const uint32_t door_q = kDoorbellPhys >> 3;
		// Bank payload window: two banks from PHYS_BASE
		const uint32_t bank0 = kBasePhys >> 3;
		const uint32_t bank_end = bank0 + (2u * kBankStrideBytes) / 8u;
		if (addr_q >= door_q && addr_q < door_q + 64u) {
			st.doorbell_beats += n;
		} else if (addr_q >= bank0 && addr_q < bank_end) {
			st.payload_beats += n;
		} else {
			st.other_beats += n;
		}
	}

	void ddrComb() {
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
			++st.busy_cycles;
		top.DDRAM_DOUT_READY = 0;
		if (top.DDRAM_RD && force_busy)
			++st.rd_blocked;

		if (busy > 0)
			--busy;

		if (rdDelay > 0) {
			--rdDelay;
		} else if (rdDelay == 0 && rdLeft > 0) {
			const uint32_t idx = addrOffQ(rdAddr) + static_cast<uint32_t>(rdIndex);
			top.DDRAM_DOUT = (idx < mem.size()) ? mem[idx] : 0;
			top.DDRAM_DOUT_READY = 1;
			++rdIndex;
			--rdLeft;
			if (rdLeft == 0)
				rdDelay = -1;
			else
				rdDelay = 0;
		}

		if (top.DDRAM_RD && busy == 0 && hog_left == 0 && rdDelay < 0) {
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
			if (static_cast<uint64_t>(rdLeft) > st.max_burst)
				st.max_burst = static_cast<uint64_t>(rdLeft);
			rdIndex = 0;
			rdDelay = kRdDelay;
			classifyAccept(rdAddr, rdLeft);
			busy = 1 + stall_after_accept;
		}
		if (top.DDRAM_WE && busy == 0 && hog_left == 0) {
			const uint32_t idx = addrOffQ(top.DDRAM_ADDR);
			if (idx < mem.size())
				mem[idx] = top.DDRAM_DIN;
			busy = 1 + stall_after_accept;
		}
	}

	void driveBeam() {
		const bool de = (hc < kHActiveG) && (vc < kVActive);
		top.rd_active = de ? 1 : 0;
		// Even x for PPC=2 group alignment (store comment).
		const int x_px = (hc < kHActiveG) ? (hc * kPPC) : (kCodedW - kPPC);
		top.rd_x = x_px;
		// V-blank: hold rd_y=0 so src_y/want_y prefetches line 0 before active.
		// Holding last-line (719) through blank caused wrap underruns at y=0 (diag).
		top.rd_y = (vc < kVActive) ? vc : 0;
		top.vsync_pulse = (hc == 0 && vc == 0) ? 1 : 0;
	}

	void advanceBeamOnSysPosedge() {
		if ((hc < kHActiveG) && (vc < kVActive))
			++st.de_groups;
		++hc;
		if (hc >= kHTotalG) {
			hc = 0;
			++vc;
			if (vc >= kVTotal)
				vc = 0;
		}
	}

	void evalLevels() {
		driveBeam();
		top.clk = clk_sys_lvl;
		top.clk_ddr = clk_ddr_lvl;
		top.eval();
	}

	// Advance to next clock edge (sys or ddr). DDR model steps on ddr posedge only.
	void advance() {
		const int64_t next = (next_ddr < next_sys) ? next_ddr : next_sys;
		t_ps = next;
		const bool sys_edge = (t_ps == next_sys);
		const bool ddr_edge = (t_ps == next_ddr);
		if (sys_edge) {
			clk_sys_lvl ^= 1;
			next_sys += kHalfSysPs;
			if (clk_sys_lvl == 1) {
				++st.sys_cycles;
				advanceBeamOnSysPosedge();
			}
		}
		if (ddr_edge) {
			clk_ddr_lvl ^= 1;
			next_ddr += kHalfDdrPs;
			if (clk_ddr_lvl == 1) {
				++st.ddr_cycles;
				ddrComb();
			}
		}
		evalLevels();
	}

	void clearStats() {
		st = Stats{};
		st.underrun_start = top.underrun_count;
	}
	void snapshotUnderrunEnd() { st.underrun_end = top.underrun_count; }

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 200; ++i)
			advance();
		top.reset = 0;
		for (int i = 0; i < 100; ++i)
			advance();
	}

	// Run until frames_done increases, or timeout_sys_cycles.
	bool waitFrameDelta(uint16_t fd0, uint64_t timeout_sys) {
		const uint64_t sys0 = st.sys_cycles;
		while (st.sys_cycles - sys0 < timeout_sys) {
			advance();
			if (top.frames_done > fd0 && top.has_frame)
				return true;
		}
		return top.frames_done > fd0;
	}
};

int fail(const char* m) {
	std::printf("FAIL 720p_ppc2_bus: %s\n", m);
	return 1;
}

struct FrameDelta {
	Stats s;
	uint16_t frames_done = 0;
	int line_count = 0;
	bool ok = false;
};

FrameDelta measureSteadyFrame(int stall_after, int hog_period, int hog_len) {
	FrameDelta out;
	BusModel sim;
	sim.stall_after_accept = stall_after;
	sim.hog_period = hog_period;
	sim.hog_len = hog_len;
	sim.fillBank(0);
	sim.resetCore();
	out.line_count = static_cast<int>(sim.top.abi_line_count);

	// Prep: allow doorbell poll + first present.
	sim.ringDoorbell(0, 1);
	const uint64_t prep_timeout = 3ull * 833333ull; // ~3 frame times @20M
	const uint16_t fd_start = sim.top.frames_done;
	if (!sim.waitFrameDelta(fd_start, prep_timeout)) {
		std::printf("PREP_FAIL frames_done=%u has_frame=%u beats=%llu\n",
		            (unsigned)sim.top.frames_done, (unsigned)sim.top.has_frame,
		            (unsigned long long)sim.st.accepted_rd_beats);
		return out;
	}

	// Steady delta: clear counters at frames_done edge, wait for next.
	const uint16_t fd1 = sim.top.frames_done;
	sim.clearStats();
	// Re-ring so next frame is available (double-buffer style present).
	sim.ringDoorbell(0, 2);
	if (!sim.waitFrameDelta(fd1, prep_timeout)) {
		std::printf("STEADY_FAIL fd=%u beats=%llu\n", (unsigned)sim.top.frames_done,
		            (unsigned long long)sim.st.accepted_rd_beats);
		return out;
	}
	sim.snapshotUnderrunEnd();
	out.s = sim.st;
	out.frames_done = sim.top.frames_done;
	out.ok = true;
	return out;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	constexpr uint64_t kFullDeGroups =
	    static_cast<uint64_t>(kCodedW / kPPC) * static_cast<uint64_t>(kCodedH);

	std::printf("PRE-REG 720p_ppc2_bus FULL+STALL @20:90:\n");
	std::printf("  payload_ideal=%llu de_groups_full=%llu\n",
	            (unsigned long long)kPayloadBeatsIdeal,
	            (unsigned long long)kFullDeGroups);
	std::printf("  G0 full+ideal: payload>=ideal underrun=0 de>=full ddr_cy<%llu\n",
	            (unsigned long long)kBudgetDdrCycles24);
	std::printf("  G1 full+stall: payload complete underrun=0 blocked>=10 busy↑ de>=full\n");
	std::printf("  clocks 20:90 half_ps=%lld/%lld PPC=%d PHYS=0x%08x LC_floor=32\n",
	            (long long)kHalfSysPs, (long long)kHalfDdrPs, kPPC, kBasePhys);

	if (kUQBase + 2 * kUQwords != static_cast<int>(kPayloadBeatsIdeal))
		return fail("plane qword math != 172800");

	FrameDelta g0 = measureSteadyFrame(0, 0, 0);
	if (!g0.ok)
		return fail("G0 steady frame delta not observed");
	std::printf("CASE G0_full_ideal EXECUTED payload=%llu door=%llu other=%llu total=%llu "
	            "sys_cy=%llu ddr_cy=%llu busy=%llu blocked=%llu max_burst=%llu "
	            "de_groups=%llu underrun_delta=%u LC=%d fd=%u\n",
	            (unsigned long long)g0.s.payload_beats,
	            (unsigned long long)g0.s.doorbell_beats,
	            (unsigned long long)g0.s.other_beats,
	            (unsigned long long)g0.s.accepted_rd_beats,
	            (unsigned long long)g0.s.sys_cycles,
	            (unsigned long long)g0.s.ddr_cycles,
	            (unsigned long long)g0.s.busy_cycles,
	            (unsigned long long)g0.s.rd_blocked,
	            (unsigned long long)g0.s.max_burst,
	            (unsigned long long)g0.s.de_groups,
	            (unsigned)g0.s.underrun_delta(), g0.line_count,
	            (unsigned)g0.frames_done);
	if (g0.line_count < 32)
		return fail("G0 LINE_COUNT must be >=32");
	if (g0.s.payload_beats < kPayloadBeatsIdeal)
		return fail("G0 payload_delta < 172800 (incomplete I420 read)");
	if (g0.s.payload_beats > kPayloadBeatsIdeal * 3ull)
		return fail("G0 payload_delta > 3x ideal (unbounded refill)");
	if (g0.s.doorbell_beats == 0)
		return fail("G0 expected doorbell/mailbox RD in frame window");
	if (g0.s.ddr_cycles >= kBudgetDdrCycles24)
		return fail("G0 steady frame exceeded 24fps ddr cycle budget");
	if (g0.s.max_burst < 2)
		return fail("G0 expected burst>1");
	if (g0.s.de_groups < kFullDeGroups)
		return fail("G0 DE groups < full 1280x720 frame");
	if (g0.s.underrun_delta() != 0) {
		std::printf("G0 underrun_delta=%u\n", (unsigned)g0.s.underrun_delta());
		return fail("G0 underrun under full+ideal @20:90");
	}
	std::printf("PASS G0 full+ideal payload=%llu overhead=%llu ddr_cy=%llu de=%llu und=0\n",
	            (unsigned long long)g0.s.payload_beats,
	            (unsigned long long)(g0.s.accepted_rd_beats - g0.s.payload_beats),
	            (unsigned long long)g0.s.ddr_cycles,
	            (unsigned long long)g0.s.de_groups);

	FrameDelta g1 = measureSteadyFrame(3, 8, 3);
	if (!g1.ok)
		return fail("G1 stalled FULL frame not observed");
	std::printf("CASE G1_full_stall EXECUTED payload=%llu door=%llu total=%llu "
	            "sys_cy=%llu ddr_cy=%llu busy=%llu blocked=%llu max_burst=%llu "
	            "de_groups=%llu underrun_delta=%u LC=%d fd=%u\n",
	            (unsigned long long)g1.s.payload_beats,
	            (unsigned long long)g1.s.doorbell_beats,
	            (unsigned long long)g1.s.accepted_rd_beats,
	            (unsigned long long)g1.s.sys_cycles,
	            (unsigned long long)g1.s.ddr_cycles,
	            (unsigned long long)g1.s.busy_cycles,
	            (unsigned long long)g1.s.rd_blocked,
	            (unsigned long long)g1.s.max_burst,
	            (unsigned long long)g1.s.de_groups,
	            (unsigned)g1.s.underrun_delta(), g1.line_count,
	            (unsigned)g1.frames_done);
	if (g1.s.payload_beats < kPayloadBeatsIdeal)
		return fail("G1 full+stall payload incomplete");
	if (g1.s.payload_beats > kPayloadBeatsIdeal * 3ull)
		return fail("G1 payload unbounded");
	if (g1.s.rd_blocked < 10)
		return fail("G1 expected RD-while-BUSY (>=10)");
	if (g1.s.busy_cycles <= g0.s.busy_cycles)
		return fail("G1 expected higher busy_cycles than G0 under stall/hog");
	if (g1.s.de_groups < kFullDeGroups)
		return fail("G1 DE groups < full frame");
	if (g1.s.ddr_cycles >= kBudgetDdrCycles24)
		return fail("G1 over 24fps ddr cycle budget");
	if (g1.s.underrun_delta() != 0) {
		std::printf("G1 underrun_delta=%u LC=%d\n", (unsigned)g1.s.underrun_delta(),
		            g1.line_count);
		return fail("G1 underrun under full-frame+stall");
	}
	std::printf("PASS G1 full+stall payload=%llu blocked=%llu busy=%llu (>G0 %llu) "
	            "ddr_cy=%llu de=%llu und=0\n",
	            (unsigned long long)g1.s.payload_beats,
	            (unsigned long long)g1.s.rd_blocked,
	            (unsigned long long)g1.s.busy_cycles,
	            (unsigned long long)g0.s.busy_cycles,
	            (unsigned long long)g1.s.ddr_cycles,
	            (unsigned long long)g1.s.de_groups);

	std::printf("BEAT_SUMMARY term=payload_RD_beats/frame (NOT T_copy_arm ms)\n");
	std::printf("  G0_ideal payload=%llu total_rd=%llu ddr_cy=%llu sys_cy=%llu residual=%lld\n",
	            (unsigned long long)g0.s.payload_beats,
	            (unsigned long long)g0.s.accepted_rd_beats,
	            (unsigned long long)g0.s.ddr_cycles,
	            (unsigned long long)g0.s.sys_cycles,
	            (long long)kBudgetDdrCycles24 - (long long)g0.s.ddr_cycles);
	std::printf("  G1_stall payload=%llu total_rd=%llu ddr_cy=%llu sys_cy=%llu blocked=%llu residual=%lld\n",
	            (unsigned long long)g1.s.payload_beats,
	            (unsigned long long)g1.s.accepted_rd_beats,
	            (unsigned long long)g1.s.ddr_cycles,
	            (unsigned long long)g1.s.sys_cycles,
	            (unsigned long long)g1.s.rd_blocked,
	            (long long)kBudgetDdrCycles24 - (long long)g1.s.ddr_cycles);
	std::printf("PASS ddr_frame_store_720p_ppc2_bus FULL+STALL @20:90 LC>=32\n");
	return 0;
}
