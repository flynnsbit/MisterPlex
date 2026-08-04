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
// rd-duck: SCALAR reader yields bit-identical G0/G1 — refill-demand only, NOT PPC2 closed.
// PPC2 correctness = test_ddr_frame_store_ppc2_distinct.sh (dual-lane + scalar NEG).
// Status: PARTIAL_CLOSED_READER; fabric_bw_closed=false.

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
	std::printf("FAIL 720p_ppc2_bus: %s\n", m);
	return 1;
}

struct FrameDelta {
	Stats s;
	uint16_t frames_done = 0;
	uint16_t underrun_start = 0;
	uint16_t underrun_end = 0;
	uint64_t rgb_samples = 0;
	uint64_t rgb_nonzero = 0;
	uint64_t npx_dual = 0;
	uint32_t rgb_fnv = 2166136261u;
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
	// Sample RGB / dual-lane outputs every sys posedge while has_frame+DE
	// (rd-duck: underrun and rd_* must be *read*, not only wired).
	const uint16_t fd1 = sim.top.frames_done;
	out.underrun_start = sim.top.underrun_count;
	sim.clearStats();
	sim.starve_dout = starve_dout_after_prep;
	sim.accept_cap = accept_cap_after_prep;
	sim.ringDoorbell(0, 2);
	const uint64_t sys0 = sim.st.sys_cycles;
	bool got = false;
	while (sim.st.sys_cycles - sys0 < prep_timeout) {
		const uint8_t prev_clk = sim.clk_sys_lvl;
		sim.advance();
		// Sample on sys rising edge after eval
		if (prev_clk == 0 && sim.clk_sys_lvl == 1) {
			if (sim.top.has_frame && sim.top.rd_active) {
				const uint8_t r = static_cast<uint8_t>(sim.top.rd_r);
				const uint8_t g = static_cast<uint8_t>(sim.top.rd_g);
				const uint8_t b = static_cast<uint8_t>(sim.top.rd_b);
				++out.rgb_samples;
				if (r | g | b)
					++out.rgb_nonzero;
				// FNV-1a over RGB triples
				auto fnv = [&](uint8_t v) {
					out.rgb_fnv ^= v;
					out.rgb_fnv *= 16777619u;
				};
				fnv(r); fnv(g); fnv(b);
				if (sim.top.rd_n_valid && (sim.top.rd_lane_valid_n & 0x3) == 0x3) {
					++out.npx_dual;
					fnv(static_cast<uint8_t>(sim.top.rd_r_n & 0xFF));
					fnv(static_cast<uint8_t>((sim.top.rd_r_n >> 8) & 0xFF));
				}
			}
		}
		if (sim.top.frames_done > fd1 && sim.top.has_frame) {
			got = true;
			break;
		}
	}
	out.s = sim.st;
	out.frames_done = sim.top.frames_done;
	out.underrun_end = sim.top.underrun_count;
	if (!got) {
		std::printf("STEADY_FAIL fd=%u beats=%llu returned=%llu underrun=%u rgb_samp=%llu\n",
		            (unsigned)sim.top.frames_done,
		            (unsigned long long)sim.st.accepted_rd_beats,
		            (unsigned long long)sim.st.returned_rd_beats,
		            (unsigned)sim.top.underrun_count,
		            (unsigned long long)out.rgb_samples);
		out.ok = false;
		return out;
	}
	out.ok = true;
	return out;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);

	std::printf("PRE-REG 720p_ppc2_bus (rd-duck tightened):\n");
	std::printf("  I420_ideal=%llu extra_Y_lines=2 (+%llu) expected_payload=%llu\n",
	            (unsigned long long)kPayloadBeatsIdeal,
	            (unsigned long long)kExtraYLineBeats,
	            (unsigned long long)kPayloadBeatsExpected);
	std::printf("  Y/U/V expect=%llu/%llu/%llu; returned==accepted; class conservation\n",
	            (unsigned long long)kYBeatsExpected,
	            (unsigned long long)kUBeatsExpected,
	            (unsigned long long)kVBeatsExpected);
	std::printf("  G0/G1 ddr_cy<%llu; payload==173120; RGB/npx sampled+FNV; busy↑ blocked>=10\n",
	            (unsigned long long)kBudgetDdrCycles24);
	std::printf("  G2 NEG: starve_dout AFTER prep → steady deadline fail\n");
	std::printf("  beam 825*750@20M ≈32.323fps STRESS (not product rate-match 24fps)\n");
	std::printf("  clocks 20:90 ps half=%lld/%lld PPC=%d LINE=16 PHYS=0x%08x\n",
	            (long long)kHalfSysPs, (long long)kHalfDdrPs, kPPC, kBasePhys);

	if (kUQBase + 2 * kUQwords != static_cast<int>(kPayloadBeatsIdeal))
		return fail("plane qword math != 172800");
	if (kPayloadBeatsExpected != 173120ull)
		return fail("expected payload constant drift");

	// ----- G0 ideal bus -----
	FrameDelta g0 = measureSteadyFrame(0, 0, 0);
	if (!g0.ok)
		return fail("G0 steady frame delta not observed");
	std::printf("CASE G0_steady EXECUTED payload=%llu door=%llu other=%llu total=%llu returned=%llu "
	            "Y=%llu U=%llu V=%llu pad=%llu "
	            "sys_cy=%llu ddr_cy=%llu busy=%llu blocked=%llu max_burst=%llu fd=%u\n",
	            (unsigned long long)g0.s.payload_beats,
	            (unsigned long long)g0.s.doorbell_beats,
	            (unsigned long long)g0.s.other_beats,
	            (unsigned long long)g0.s.accepted_rd_beats,
	            (unsigned long long)g0.s.returned_rd_beats,
	            (unsigned long long)g0.s.payload_y,
	            (unsigned long long)g0.s.payload_u,
	            (unsigned long long)g0.s.payload_v,
	            (unsigned long long)g0.s.payload_pad,
	            (unsigned long long)g0.s.sys_cycles,
	            (unsigned long long)g0.s.ddr_cycles,
	            (unsigned long long)g0.s.busy_cycles,
	            (unsigned long long)g0.s.rd_blocked,
	            (unsigned long long)g0.s.max_burst,
	            (unsigned)g0.frames_done);

	if (g0.s.payload_beats != kPayloadBeatsExpected)
		return fail("G0 payload_beats != derived 173120 (ideal+2 Y lines)");
	if (g0.s.payload_y != kYBeatsExpected || g0.s.payload_u != kUBeatsExpected ||
	    g0.s.payload_v != kVBeatsExpected || g0.s.payload_pad != 0)
		return fail("G0 plane split Y/U/V/pad mismatch (extra must be Y-only)");
	if (g0.s.doorbell_beats == 0)
		return fail("G0 expected doorbell/mailbox RD in frame window");
	if (g0.s.ddr_cycles >= kBudgetDdrCycles24)
		return fail("G0 steady frame exceeded 24fps ddr cycle budget");
	if (g0.s.max_burst < 2)
		return fail("G0 expected burst>1");
	if (g0.s.payload_beats + g0.s.doorbell_beats + g0.s.other_beats != g0.s.accepted_rd_beats)
		return fail("G0 beat conservation: payload+door+other != total");
	if (g0.s.returned_rd_beats != g0.s.accepted_rd_beats)
		return fail("G0 returned_rd_beats != accepted (missing DOUT)");
	if (g0.s.payload_y + g0.s.payload_u + g0.s.payload_v + g0.s.payload_pad !=
	    g0.s.payload_beats)
		return fail("G0 plane sum != payload");

	const unsigned g0_undr =
	    static_cast<unsigned>(g0.underrun_end - g0.underrun_start);
	std::printf("G0_UNDRUN start=%u end=%u delta=%u (delivery OPEN if !=0)\n",
	            (unsigned)g0.underrun_start, (unsigned)g0.underrun_end, g0_undr);
	if (g0.underrun_end < g0.underrun_start)
		return fail("G0 underrun_count wrapped");
	// Do NOT require underrun==0 here — that would false-green delivery.
	// Output path must be exercised (rd-duck: wired-but-unread is a hole).
	if (g0.rgb_samples < 10000)
		return fail("G0 too few RGB samples on DE (outputs unread/black path)");
	if (g0.rgb_nonzero == 0)
		return fail("G0 all RGB zero on DE (stale/black lines would pass beats-only)");
	if (g0.npx_dual < 1000)
		return fail("G0 too few dual-lane rd_n_valid samples");
	if (g0.rgb_fnv == 2166136261u)
		return fail("G0 RGB FNV never updated");
	std::printf("G0_RGB samples=%llu nonzero=%llu npx_dual=%llu fnv=0x%08x underrun_delta=%u\n",
	            (unsigned long long)g0.rgb_samples, (unsigned long long)g0.rgb_nonzero,
	            (unsigned long long)g0.npx_dual, g0.rgb_fnv, g0_undr);

	std::printf("PASS G0 stress payload=%llu (=ideal+%llu Y) door=%llu returned=%llu "
	            "ddr_cy=%llu underrun_delta=%u rgb_fnv=0x%08x\n",
	            (unsigned long long)g0.s.payload_beats,
	            (unsigned long long)kExtraYLineBeats,
	            (unsigned long long)g0.s.doorbell_beats,
	            (unsigned long long)g0.s.returned_rd_beats,
	            (unsigned long long)g0.s.ddr_cycles, g0_undr, g0.rgb_fnv);

	// ----- G1 mild stall (corrected criterion: NOT wall-time; busy/blocked + tight payload) -----
	FrameDelta g1 = measureSteadyFrame(3, 8, 3);
	if (!g1.ok)
		return fail("G1 stalled steady frame not observed");
	std::printf("CASE G1_stall EXECUTED payload=%llu door=%llu total=%llu returned=%llu "
	            "sys_cy=%llu ddr_cy=%llu blocked=%llu busy=%llu\n",
	            (unsigned long long)g1.s.payload_beats,
	            (unsigned long long)g1.s.doorbell_beats,
	            (unsigned long long)g1.s.accepted_rd_beats,
	            (unsigned long long)g1.s.returned_rd_beats,
	            (unsigned long long)g1.s.sys_cycles,
	            (unsigned long long)g1.s.ddr_cycles,
	            (unsigned long long)g1.s.rd_blocked,
	            (unsigned long long)g1.s.busy_cycles);
	if (g1.s.payload_beats != kPayloadBeatsExpected)
		return fail("G1 payload_beats != 173120 (upper+lower locked; no 3x band)");
	if (g1.s.ddr_cycles >= kBudgetDdrCycles24)
		return fail("G1 exceeded 24fps ddr cycle budget");
	if (g1.s.rd_blocked < 10)
		return fail("G1 expected RD-while-BUSY observations");
	if (g1.s.busy_cycles <= g0.s.busy_cycles)
		return fail("G1 expected higher busy_cycles than G0 under stall/hog");
	if (g1.s.payload_beats + g1.s.doorbell_beats + g1.s.other_beats != g1.s.accepted_rd_beats)
		return fail("G1 beat conservation: payload+door+other != total");
	if (g1.s.returned_rd_beats != g1.s.accepted_rd_beats)
		return fail("G1 returned_rd_beats != accepted");
	const unsigned g1_undr =
	    static_cast<unsigned>(g1.underrun_end - g1.underrun_start);
	if (g1.underrun_end < g1.underrun_start)
		return fail("G1 underrun_count wrapped");
	if (g1.rgb_samples < 1000)
		return fail("G1 RGB outputs unread (samples<1000)");
	if (g1.rgb_nonzero == 0)
		return fail("G1 all RGB zero under stall");
	// Still do NOT require underrun_delta==0 — delivery OPEN on stress raster.
	std::printf("G1_RGB samples=%llu nonzero=%llu fnv=0x%08x underrun_delta=%u\n",
	            (unsigned long long)g1.rgb_samples, (unsigned long long)g1.rgb_nonzero,
	            g1.rgb_fnv, g1_undr);
	std::printf("PASS G1 mild-stall payload=%llu blocked=%llu busy=%llu (>G0 %llu) "
	            "ddr_cy=%llu underrun_delta=%u rgb_fnv=0x%08x\n",
	            (unsigned long long)g1.s.payload_beats,
	            (unsigned long long)g1.s.rd_blocked,
	            (unsigned long long)g1.s.busy_cycles,
	            (unsigned long long)g0.s.busy_cycles,
	            (unsigned long long)g1.s.ddr_cycles, g1_undr, g1.rgb_fnv);

	// ----- G2 NEG: starve DOUT after healthy prep — steady deadline must fail -----
	// PRE-REG: starve_dout_after_prep=true → steady waitFrameDelta times out (!ok)
	// with accepted>returned (outstanding starved). Proves gate goes red.
	FrameDelta g2 = measureSteadyFrame(0, 0, 0, /*starve_after_prep=*/true, 0);
	std::printf("CASE G2_NEG_starve_dout EXECUTED ok=%d payload=%llu returned=%llu "
	            "blocked=%llu underrun_delta=%u\n",
	            g2.ok ? 1 : 0,
	            (unsigned long long)g2.s.payload_beats,
	            (unsigned long long)g2.s.returned_rd_beats,
	            (unsigned long long)g2.s.rd_blocked,
	            g2.ok ? (unsigned)(g2.underrun_end - g2.underrun_start) : 0u);
	const bool g2_deadline_fail = !g2.ok;
	const bool g2_payload_fail =
	    g2.ok && (g2.s.payload_beats < kPayloadBeatsIdeal / 2ull);
	const bool g2_return_fail =
	    g2.ok && (g2.s.returned_rd_beats + 1000ull < g2.s.accepted_rd_beats);
	if (!g2_deadline_fail && !g2_payload_fail && !g2_return_fail)
		return fail("G2 NEG starve mutant did not discriminate (expected !ok or starved returns)");
	std::printf("PASS G2 NEG discrimination deadline_fail=%d payload_fail=%d return_fail=%d\n",
	            g2_deadline_fail ? 1 : 0, g2_payload_fail ? 1 : 0, g2_return_fail ? 1 : 0);

	std::printf("NOTE iface_peaks: PPC2 group=6 RGB B/sysclk; I420 amort=3 B/2px; "
	            "headline 33.1776 MB/s/dir — not 1.65888 for FIFO\n");
	std::printf("NOTE status: STRESS_EVIDENCE only; NOT product rate-match; "
	            "NOT reader CLOSED; delivery OPEN (underrun/checksum/rate-match); "
	            "NOT fabric_bw_closed; fit blocker NOT released by this TB\n");

	std::printf("PASS ddr_frame_store_720p_ppc2_bus all "
	            "(tight beat lock + G2 NEG; stress not product integration)\n");
	return 0;
}
