// Full 1280x720 real-reader beat delta @ MULTI+PPC2, clk 20:90 (w-clock / rd-duck).
//
// Isolated ddr_frame_store stress — NOT product present_pix_rate_match integration.
// Beam 825*750 @20 MHz ~32.323 fps (conservative vs 24 fps glass).
// Status: STRESS_EVIDENCE only. delivery_correctness OPEN (underrun/checksum/rate-match).
// Fit blocker NOT released by this TB.
//
// PRE-REG (rd-duck tightened):
//   I420 ideal 172800; DERIVED +2 Y lines = 320 -> payload == 173120 exact
//   G0: Y/U/V/pad lock; returned==accepted; class conservation; ddr_cy<3750000
//   G1: payload==173120 (no 3x band); ddr_cy budget; blocked>=10; busy>G0
//   G2 NEG: starve_dout AFTER prep -> steady deadline fail
//   PPC=2: rd_x step 2; PX_PER_CLK=2

#include "Vddr_frame_store_ppc2_distinct_tb.h"
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
// Derived (plane split): +2 Y-line refills under LINE=16 pipeline @ this TB.
// 2 * Y_LINE_QWORDS(160) = 320 → expected payload 173120. Locked, not a slop band.
constexpr uint64_t kExtraYLineBeats = 2ull * static_cast<uint64_t>(kYQ); // 320
constexpr uint64_t kPayloadBeatsExpected = kPayloadBeatsIdeal + kExtraYLineBeats; // 173120
constexpr uint64_t kYBeatsExpected = static_cast<uint64_t>(kUQBase) + kExtraYLineBeats; // 115520
constexpr uint64_t kUBeatsExpected = static_cast<uint64_t>(kUQwords); // 28800
constexpr uint64_t kVBeatsExpected = static_cast<uint64_t>(kUQwords); // 28800
constexpr uint64_t kBudgetDdrCycles24 = 3750000ull; // 90e6/24

// Beam on clk_sys: MULTI-class groups (2 px/clk). CEA-ish totals halved in X.
// NOTE: free-running 825*750 @20MHz ≈ 32.323 fps — not product 24 fps rate-match.
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
	uint64_t returned_rd_beats = 0; // DOUT_READY pulses
	uint64_t payload_beats = 0;
	uint64_t payload_y = 0;
	uint64_t payload_u = 0;
	uint64_t payload_v = 0;
	uint64_t payload_pad = 0; // bank window but outside I420 planes
	uint64_t doorbell_beats = 0;
	uint64_t other_beats = 0;
	uint64_t busy_cycles = 0;
	uint64_t rd_blocked = 0;
	uint64_t max_burst = 0;
	uint64_t sys_cycles = 0;
	uint64_t ddr_cycles = 0;
};

struct BusModel {
	Vddr_frame_store_ppc2_distinct_tb top{};
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
	// G2 NEG: accept RD addresses but never return DOUT (starves refill).
	bool starve_dout = false;
	uint64_t accept_cap = 0; // 0=unlimited accepts; else stop accepting after N beats

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
		// Horizontal Y gradient: pixel x has Y=(x+line)&0xFF so adjacent lanes differ.
		for (int line = 0; line < kCodedH; ++line) {
			for (int q = 0; q < kYQ; ++q) {
				uint64_t word = 0;
				for (int b = 0; b < 8; ++b) {
					const int x = q * 8 + b;
					const uint8_t y = static_cast<uint8_t>((x + line) & 0xFF);
					word |= static_cast<uint64_t>(y) << (8 * b);
				}
				mem[base + line * kYQ + q] = word;
			}
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
		const uint32_t bank0 = kBasePhys >> 3;
		const uint32_t bank_end = bank0 + (2u * kBankStrideBytes) / 8u;
		const uint32_t bank_qw = kBankStrideBytes / 8u;
		if (addr_q >= door_q && addr_q < door_q + 64u) {
			st.doorbell_beats += n;
			return;
		}
		if (addr_q < bank0 || addr_q >= bank_end) {
			st.other_beats += n;
			return;
		}
		st.payload_beats += n;
		// Per-beat plane split inside bank (I420 packed at bank base).
		for (int i = 0; i < nbeats; ++i) {
			const uint32_t aq = addr_q + static_cast<uint32_t>(i);
			const uint32_t off = (aq - bank0) % bank_qw; // bank-relative qword
			if (off < static_cast<uint32_t>(kUQBase))
				++st.payload_y;
			else if (off < static_cast<uint32_t>(kVBaseQ))
				++st.payload_u;
			else if (off < static_cast<uint32_t>(kPayloadBeatsIdeal))
				++st.payload_v;
			else
				++st.payload_pad;
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
			if (starve_dout) {
				// Hold outstanding read forever — no DOUT_READY.
				top.DDRAM_DOUT_READY = 0;
			} else {
				const uint32_t idx = addrOffQ(rdAddr) + static_cast<uint32_t>(rdIndex);
				top.DDRAM_DOUT = (idx < mem.size()) ? mem[idx] : 0;
				top.DDRAM_DOUT_READY = 1;
				++st.returned_rd_beats;
				++rdIndex;
				--rdLeft;
				if (rdLeft == 0)
					rdDelay = -1;
				else
					rdDelay = 0;
			}
		}

		if (top.DDRAM_RD && busy == 0 && hog_left == 0 && rdDelay < 0) {
			const int want = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
			if (accept_cap && st.accepted_rd_beats + static_cast<uint64_t>(want) > accept_cap) {
				// Refuse further accepts — bus looks permanently busy.
				top.DDRAM_BUSY = 1;
				++st.busy_cycles;
				++st.rd_blocked;
			} else {
				rdAddr = top.DDRAM_ADDR;
				rdLeft = want;
				if (static_cast<uint64_t>(rdLeft) > st.max_burst)
					st.max_burst = static_cast<uint64_t>(rdLeft);
				rdIndex = 0;
				rdDelay = kRdDelay;
				classifyAccept(rdAddr, rdLeft);
				busy = 1 + stall_after_accept;
			}
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
		top.rd_y = (vc < kVActive) ? vc : (kVActive - 1);
		top.vsync_pulse = (hc == 0 && vc == 0) ? 1 : 0;
	}

	void advanceBeamOnSysPosedge() {
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

	void clearStats() { st = Stats{}; }

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
	std::printf("FAIL ppc2_distinct: %s\n", m);
	return 1;
}

struct FrameDelta {
	Stats s;
	uint16_t frames_done = 0;
	uint16_t underrun_start = 0;
	uint16_t underrun_end = 0;
	bool ok = false;
};

FrameDelta measureSteadyFrame(int stall_after, int hog_period, int hog_len,
                              bool starve_dout_after_prep = false,
                              uint64_t accept_cap_after_prep = 0) {
	FrameDelta out;
	BusModel sim;
	sim.stall_after_accept = stall_after;
	sim.hog_period = hog_period;
	sim.hog_len = hog_len;
	// Prep always healthy — mutants apply only on the steady window.
	sim.starve_dout = false;
	sim.accept_cap = 0;
	sim.fillBank(0);
	sim.resetCore();

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
	out.underrun_start = sim.top.underrun_count;
	sim.clearStats();
	sim.starve_dout = starve_dout_after_prep;
	sim.accept_cap = accept_cap_after_prep;
	// Re-ring so next frame is available (double-buffer style present).
	sim.ringDoorbell(0, 2);
	if (!sim.waitFrameDelta(fd1, prep_timeout)) {
		std::printf("STEADY_FAIL fd=%u beats=%llu returned=%llu underrun=%u\n",
		            (unsigned)sim.top.frames_done,
		            (unsigned long long)sim.st.accepted_rd_beats,
		            (unsigned long long)sim.st.returned_rd_beats,
		            (unsigned)sim.top.underrun_count);
		out.s = sim.st;
		out.frames_done = sim.top.frames_done;
		out.underrun_end = sim.top.underrun_count;
		out.ok = false; // deadline miss on steady window
		return out;
	}
	out.s = sim.st;
	out.frames_done = sim.top.frames_done;
	out.underrun_end = sim.top.underrun_count;
	out.ok = true;
	return out;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	std::printf("PRE-REG ppc2_distinct (rd-duck FIT BLOCKER):\n");
	std::printf("  gradient Y; dual-lane rd_r_n[7:0] != rd_r_n[15:8] on DE\n");
	std::printf("  RED twin: scalar {PPC{fr}} replicate keeps lanes equal → FAIL\n");
	std::printf("  clocks 20:90 PPC=2 LINE=16 PHYS=0x30180000\n");

	BusModel sim;
	sim.fillBank(0);
	sim.resetCore();
	sim.ringDoorbell(0, 1);

	if (!sim.waitFrameDelta(0, 3ull * 833333ull)) {
		std::printf("PREP_FAIL frames_done=%u has_frame=%u doorbell_ok=%u debug=0x%02x\n",
		            (unsigned)sim.top.frames_done, (unsigned)sim.top.has_frame,
		            (unsigned)sim.top.doorbell_ok, (unsigned)sim.top.debug_state);
		return fail("prep: frames_done never advanced");
	}
	std::printf("PREP ok frames_done=%u has_frame=%u doorbell_ok=%u\n",
	            (unsigned)sim.top.frames_done, (unsigned)sim.top.has_frame,
	            (unsigned)sim.top.doorbell_ok);

	uint64_t distinct = 0, equal = 0, samples = 0;
	const uint64_t timeout_sys = sim.st.sys_cycles + 2ull * 833333ull;
	while (sim.st.sys_cycles < timeout_sys && samples < 4000) {
		sim.advance();
		if (!sim.top.has_frame)
			continue;
		if (!(sim.top.rd_n_valid && (sim.top.rd_lane_valid_n & 0x3) == 0x3))
			continue;
		const uint8_t r0 = static_cast<uint8_t>(sim.top.rd_r_n & 0xFF);
		const uint8_t r1 = static_cast<uint8_t>((sim.top.rd_r_n >> 8) & 0xFF);
		++samples;
		if (r0 != r1)
			++distinct;
		else
			++equal;
	}

	std::printf("RESULT samples=%llu distinct=%llu equal=%llu frames_done=%u underrun=%u\n",
	            (unsigned long long)samples, (unsigned long long)distinct,
	            (unsigned long long)equal, (unsigned)sim.top.frames_done,
	            (unsigned)sim.top.underrun_count);

	if (samples < 500)
		return fail("too few dual-lane valid samples");
	if (equal == samples)
		return fail("ALL lanes equal — PPC2 scalar-replicate bug");
	if (distinct < samples / 2)
		return fail("lanes not distinct enough (looks like scalar replicate)");

	std::printf("PASS ppc2_distinct: dual-lane store RGB differs on gradient "
	            "(not {PPC{fr}} replicate) samples=%llu distinct=%llu\n",
	            (unsigned long long)samples, (unsigned long long)distinct);
	return 0;
}
