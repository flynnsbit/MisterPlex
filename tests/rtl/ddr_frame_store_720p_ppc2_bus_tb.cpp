// Full 1280×720 real-reader @ MULTI+PPC2, clk 20:90 + stalls (w-osd).
// REAL ddr_frame_store. rd-duck gate repair after NACK on CLOSED.
//
// PRE-REG (corrected — publish before measure; prior loose G1 wall withdrawn):
//   class = isolated_reader_stress @ beam_fps = 20e6/(825*750) ≈ 32.323 fps
//           NOT product rate-match / NOT 24 fps integration proof
//   payload_ideal = 172800 (I420 qwords)
//   dual-set warm = LINE_COUNT * 240  (Y=160 + C_avg=80 per luma line)
//   payload_expect = ideal + LC*240   (measured LC32→180480, LC8→174720; locked)
//   accepted_RD == returned_DOUT exactly after drain (no in-flight slack)
//   dual-lane: bank Y even=40 odd=200 → lane0/lane1 RGB distinct + match (full-frame FNV)
//   G0 ideal: payload==expect (upper=lower), underrun==0, de_groups>=460800,
//             dual_lane_distinct, fnv==expect, ddr_cy < 3750000, sys_cy==beam period
//   G1 stall (stall_after=3, hog 8/3): SAME tight payload upper+lower + underrun/rgb/fnv,
//             blocked>=10, busy↑, ddr_cy < 3750000 AND beam-locked to G0,
//             sys_cy deadline == one beam period (G1 must finish the frame)
//   G2 negative mutant: hang payload RD after 4096 accepts → MUST fail
//             (underrun>0 or prep/steady timeout or payload short or rgb starved)
//   LC floor >=32; LC=8 shell teeth RED
//
// DOES_NOT_PROVE: HPS shared controller supply, host writes, sustainable DDR BW,
// product 24fps rate-match path, free core during decode.

#include "Vddr_frame_store_720p_ppc2_bus_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30180000u;
constexpr uint32_t kBankStrideBytes = 0x00180000u;
constexpr uint32_t kDoorbellPhys = 0x3047F000u;
constexpr uint32_t kMagic = 0x504C584Bu;

constexpr int kCodedW = 1280;
constexpr int kCodedH = 720;
constexpr int kPPC = 2;
constexpr int kYQ = kCodedW / 8;
constexpr int kCQ = kCodedW / 16;
constexpr int kUQBase = (kCodedW * kCodedH) / 8;
constexpr int kUQwords = (kCodedW * kCodedH) / 32;
constexpr int kVBaseQ = kUQBase + kUQwords;
constexpr uint64_t kPayloadBeatsIdeal = 172800ull;
constexpr uint64_t kBeatsPerLumaLine = 240ull;
constexpr uint64_t kBudgetDdrCycles24 = 3750000ull;

constexpr int kHActiveG = kCodedW / kPPC;
// Measured G0 gap de-rgb_nb=1440 (~2.25 lines); allow 3 active lines pipe/warmup.
constexpr uint64_t kRgbPipeSlack = 3ull * static_cast<uint64_t>(kHActiveG); // 1920
constexpr int kVActive = kCodedH;
constexpr int kHTotalG = 825;
constexpr int kVTotal = 750;
constexpr uint64_t kBeamSysCycles = static_cast<uint64_t>(kHTotalG) * kVTotal;
constexpr double kBeamFps = 20e6 / static_cast<double>(kBeamSysCycles);

constexpr int64_t kHalfSysPs = 25000;
constexpr int64_t kHalfDdrPs = 5556;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (i * 8);
	return q;
}

uint64_t payloadExpect(int line_count) {
	return kPayloadBeatsIdeal + static_cast<uint64_t>(line_count) * kBeatsPerLumaLine;
}

struct Stats {
	uint64_t accepted_rd_beats = 0;
	uint64_t returned_rd_beats = 0;
	uint64_t payload_beats = 0;
	uint64_t doorbell_beats = 0;
	uint64_t other_beats = 0;
	uint64_t busy_cycles = 0;
	uint64_t rd_blocked = 0;
	uint64_t max_burst = 0;
	uint64_t sys_cycles = 0;
	uint64_t ddr_cycles = 0;
	uint64_t de_groups = 0;
	uint64_t rgb_valid_groups = 0;
	uint64_t rgb_nonblack_groups = 0;
	uint64_t rgb_mismatch = 0;
	uint64_t dual_lane_distinct = 0;
	uint64_t dual_lane_same = 0;
	uint64_t dual_lane_match = 0;
	uint64_t fnv = 14695981039346656037ull;
	uint64_t fnv_want = 14695981039346656037ull;
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
	int hang_payload_after = -1;
	uint64_t payload_accepted_total = 0;
	bool hang_active = false;

	int hc = 0;
	int vc = 0;
	int64_t t_ps = 0;
	int64_t next_sys = kHalfSysPs;
	int64_t next_ddr = kHalfDdrPs;
	uint8_t clk_sys_lvl = 0;
	uint8_t clk_ddr_lvl = 0;
	Stats st{};

	BusModel() : mem((2ull * kBankStrideBytes) / 8ull, 0) {
		top.clk = 0; top.clk_ddr = 0; top.reset = 0;
		top.rd_x = 0; top.rd_y = 0; top.rd_active = 0;
		top.start_req = 0; top.bank_sel = 0; top.vsync_pulse = 0;
		top.DDRAM_BUSY = 0; top.DDRAM_DOUT = 0; top.DDRAM_DOUT_READY = 0;
	}

	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8u; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

	// Dual-lane tooth (rd-duck): even-X Y=40, odd-X Y=200, U=V=128 → R=G=B=Y.
	// Scalar-replicate would force lane0==lane1 and fail dual_lane_distinct/match.
	static constexpr uint8_t kYEven = 40;
	static constexpr uint8_t kYOdd = 200;

	void fillBank(int bank) {
		const uint32_t base = (bank * kBankStrideBytes) / 8u;
		for (int line = 0; line < kCodedH; ++line) {
			for (int q = 0; q < kYQ; ++q) {
				uint64_t word = 0;
				for (int i = 0; i < 8; ++i) {
					const int x = q * 8 + i;
					const uint8_t y = (x & 1) ? kYOdd : kYEven;
					word |= static_cast<uint64_t>(y) << (8 * i);
				}
				mem[base + static_cast<uint32_t>(line * kYQ + q)] = word;
			}
		}
		for (int line = 0; line < kCodedH / 2; ++line)
			for (int q = 0; q < kCQ; ++q) {
				mem[base + kUQBase + line * kCQ + q] = pack8(128);
				mem[base + kVBaseQ + line * kCQ + q] = pack8(128);
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
		if (addr_q >= door_q && addr_q < door_q + 64u) {
			st.doorbell_beats += n;
		} else if (addr_q >= bank0 && addr_q < bank_end) {
			st.payload_beats += n;
			payload_accepted_total += n;
			if (hang_payload_after >= 0 &&
			    payload_accepted_total >= static_cast<uint64_t>(hang_payload_after))
				hang_active = true;
		} else {
			st.other_beats += n;
		}
	}

	void ddrComb() {
		if (hog_period > 0) {
			if (hog_left > 0) --hog_left;
			else {
				++hog_cnt;
				if ((hog_cnt % hog_period) == 0) hog_left = hog_len;
			}
		}
		const int force_busy = (busy > 0) || (hog_left > 0) ? 1 : 0;
		top.DDRAM_BUSY = force_busy;
		if (force_busy) ++st.busy_cycles;
		top.DDRAM_DOUT_READY = 0;
		if (top.DDRAM_RD && force_busy) ++st.rd_blocked;
		if (busy > 0) --busy;

		if (hang_active && rdLeft > 0) {
			const uint32_t door_q = kDoorbellPhys >> 3;
			if (!(rdAddr >= door_q && rdAddr < door_q + 64u)) {
				rdLeft = 0;
				rdDelay = -1;
			}
		}

		if (rdDelay > 0) {
			--rdDelay;
		} else if (rdDelay == 0 && rdLeft > 0) {
			const uint32_t idx = addrOffQ(rdAddr) + static_cast<uint32_t>(rdIndex);
			top.DDRAM_DOUT = (idx < mem.size()) ? mem[idx] : 0;
			top.DDRAM_DOUT_READY = 1;
			++st.returned_rd_beats;
			++rdIndex;
			--rdLeft;
			rdDelay = (rdLeft == 0) ? -1 : 0;
		}

		if (top.DDRAM_RD && busy == 0 && hog_left == 0 && rdDelay < 0) {
			const uint32_t addr = top.DDRAM_ADDR;
			const uint32_t door_q = kDoorbellPhys >> 3;
			const bool is_door = (addr >= door_q && addr < door_q + 64u);
			if (hang_active && !is_door) {
				++st.rd_blocked;
			} else {
				rdAddr = addr;
				rdLeft = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
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
			if (idx < mem.size()) mem[idx] = top.DDRAM_DIN;
			busy = 1 + stall_after_accept;
		}
	}

	void driveBeam() {
		const bool de = (hc < kHActiveG) && (vc < kVActive);
		top.rd_active = de ? 1 : 0;
		top.rd_x = (hc < kHActiveG) ? (hc * kPPC) : (kCodedW - kPPC);
		top.rd_y = (vc < kVActive) ? vc : (kVActive - 1);
		top.vsync_pulse = (hc == 0 && vc == 0) ? 1 : 0;
	}

	void sampleRgbOnSysPosedge() {
		if (!top.rd_active) return;
		++st.de_groups;
		if (!top.rd_n_valid) return;
		++st.rgb_valid_groups;
		const uint8_t r0 = static_cast<uint8_t>(top.rd_r_n & 0xff);
		const uint8_t g0 = static_cast<uint8_t>(top.rd_g_n & 0xff);
		const uint8_t b0 = static_cast<uint8_t>(top.rd_b_n & 0xff);
		const uint8_t r1 = static_cast<uint8_t>((top.rd_r_n >> 8) & 0xff);
		const uint8_t g1 = static_cast<uint8_t>((top.rd_g_n >> 8) & 0xff);
		const uint8_t b1 = static_cast<uint8_t>((top.rd_b_n >> 8) & 0xff);
		// U=V=128 → R=G=B=Y. Expect lane0=Yeven, lane1=Yodd for every valid group.
		const bool gray0 = (r0 == g0) && (g0 == b0);
		const bool gray1 = (r1 == g1) && (g1 == b1);
		const bool match = gray0 && gray1 && (r0 == kYEven) && (r1 == kYOdd);
		const bool nb = (r0 >= 16) || (r1 >= 16);
		if (!gray0 || !gray1) ++st.rgb_mismatch;
		if (match) {
			++st.rgb_nonblack_groups;
			++st.dual_lane_match;
		}
		if (r0 != r1 || g0 != g1 || b0 != b1) ++st.dual_lane_distinct;
		else ++st.dual_lane_same;
		auto fold = [&](uint64_t& h, uint8_t v) { h ^= v; h *= 1099511628211ull; };
		fold(st.fnv, r0); fold(st.fnv, g0); fold(st.fnv, b0);
		fold(st.fnv, r1); fold(st.fnv, g1); fold(st.fnv, b1);
		// Full-frame expected checksum over every valid dual-lane sample (same order).
		fold(st.fnv_want, kYEven); fold(st.fnv_want, kYEven); fold(st.fnv_want, kYEven);
		fold(st.fnv_want, kYOdd); fold(st.fnv_want, kYOdd); fold(st.fnv_want, kYOdd);
	}

	void advanceBeamOnSysPosedge() {
		++hc;
		if (hc >= kHTotalG) {
			hc = 0; ++vc;
			if (vc >= kVTotal) vc = 0;
		}
	}

	void evalLevels() {
		driveBeam();
		top.clk = clk_sys_lvl; top.clk_ddr = clk_ddr_lvl;
		top.eval();
	}

	void advance() {
		const int64_t next = (next_ddr < next_sys) ? next_ddr : next_sys;
		t_ps = next;
		const bool sys_edge = (t_ps == next_sys);
		const bool ddr_edge = (t_ps == next_ddr);
		if (sys_edge) {
			clk_sys_lvl ^= 1; next_sys += kHalfSysPs;
			if (clk_sys_lvl == 1) {
				++st.sys_cycles;
				sampleRgbOnSysPosedge();
				advanceBeamOnSysPosedge();
			}
		}
		if (ddr_edge) {
			clk_ddr_lvl ^= 1; next_ddr += kHalfDdrPs;
			if (clk_ddr_lvl == 1) { ++st.ddr_cycles; ddrComb(); }
		}
		evalLevels();
	}

	void clearStats() { st = Stats{}; st.underrun_start = top.underrun_count; }
	void snapshotUnderrunEnd() { st.underrun_end = top.underrun_count; }

	// Complete in-flight DDR beats without advancing the beam / DE counters.
	void drainDdrBeats(int max_steps = 20000) {
		top.rd_active = 0;
		top.vsync_pulse = 0;
		for (int i = 0; i < max_steps; ++i) {
			if (rdLeft <= 0 && rdDelay < 0 && busy <= 0) break;
			// tick ddr only
			clk_ddr_lvl ^= 1;
			top.clk_ddr = clk_ddr_lvl;
			if (clk_ddr_lvl == 1) {
				++st.ddr_cycles;
				ddrComb();
			}
			top.clk = clk_sys_lvl;
			top.eval();
			clk_ddr_lvl ^= 1;
			top.clk_ddr = clk_ddr_lvl;
			if (clk_ddr_lvl == 1) {
				++st.ddr_cycles;
				ddrComb();
			}
			top.eval();
		}
	}

	void resetCore() {
		top.reset = 1; for (int i = 0; i < 200; ++i) advance();
		top.reset = 0; for (int i = 0; i < 100; ++i) advance();
	}

	bool waitFrameDelta(uint16_t fd0, uint64_t timeout_sys) {
		const uint64_t sys0 = st.sys_cycles;
		while (st.sys_cycles - sys0 < timeout_sys) {
			advance();
			if (top.frames_done > fd0 && top.has_frame) return true;
		}
		return top.frames_done > fd0;
	}
};

int fail(const char* m) { std::printf("FAIL 720p_ppc2_bus: %s\n", m); return 1; }

struct FrameDelta {
	Stats s;
	uint16_t frames_done = 0;
	int line_count = 0;
	bool ok = false;
	bool timed_out = false;
};

FrameDelta measureSteadyFrame(int stall_after, int hog_period, int hog_len, int hang_after) {
	FrameDelta out;
	BusModel sim;
	sim.stall_after_accept = stall_after;
	sim.hog_period = hog_period;
	sim.hog_len = hog_len;
	sim.hang_payload_after = hang_after;
	sim.fillBank(0);
	sim.resetCore();
	out.line_count = static_cast<int>(sim.top.abi_line_count);

	sim.ringDoorbell(0, 1);
	const uint64_t prep_timeout = 3ull * kBeamSysCycles;
	const uint16_t fd_start = sim.top.frames_done;
	if (!sim.waitFrameDelta(fd_start, prep_timeout)) {
		std::printf("PREP_FAIL frames=%u has=%u beats=%llu und=%u hang=%d\n",
		            (unsigned)sim.top.frames_done, (unsigned)sim.top.has_frame,
		            (unsigned long long)sim.st.accepted_rd_beats,
		            (unsigned)sim.top.underrun_count, hang_after);
		out.timed_out = true; out.s = sim.st; out.s.underrun_end = sim.top.underrun_count;
		return out;
	}

	const uint16_t fd1 = sim.top.frames_done;
	sim.clearStats();
	sim.ringDoorbell(0, 2);
	if (!sim.waitFrameDelta(fd1, prep_timeout)) {
		std::printf("STEADY_FAIL fd=%u beats=%llu und=%u hang=%d\n",
		            (unsigned)sim.top.frames_done, (unsigned long long)sim.st.accepted_rd_beats,
		            (unsigned)sim.top.underrun_count, hang_after);
		out.timed_out = true; sim.snapshotUnderrunEnd(); out.s = sim.st;
		return out;
	}
	// Drain in-flight DDR beats so accepted==returned is exact (rd-duck conservation).
	// Do NOT advance beam — extra DE would corrupt dual-lane/FNV full-frame gates.
	sim.drainDdrBeats();
	sim.snapshotUnderrunEnd();
	out.s = sim.st; out.frames_done = sim.top.frames_done; out.ok = true;
	return out;
}

void printCase(const char* name, const FrameDelta& d) {
	std::printf(
	    "CASE %s EXECUTED payload=%llu door=%llu other=%llu accepted=%llu returned=%llu "
	    "sys_cy=%llu ddr_cy=%llu busy=%llu blocked=%llu max_burst=%llu "
	    "de_groups=%llu rgb_valid=%llu rgb_nonblack=%llu rgb_mismatch=%llu "
	    "dual_dist=%llu dual_same=%llu dual_match=%llu "
	    "fnv=0x%016llx fnv_want=0x%016llx underrun_delta=%u LC=%d fd=%u ok=%d\n",
	    name, (unsigned long long)d.s.payload_beats, (unsigned long long)d.s.doorbell_beats,
	    (unsigned long long)d.s.other_beats, (unsigned long long)d.s.accepted_rd_beats,
	    (unsigned long long)d.s.returned_rd_beats, (unsigned long long)d.s.sys_cycles,
	    (unsigned long long)d.s.ddr_cycles, (unsigned long long)d.s.busy_cycles,
	    (unsigned long long)d.s.rd_blocked, (unsigned long long)d.s.max_burst,
	    (unsigned long long)d.s.de_groups, (unsigned long long)d.s.rgb_valid_groups,
	    (unsigned long long)d.s.rgb_nonblack_groups, (unsigned long long)d.s.rgb_mismatch,
	    (unsigned long long)d.s.dual_lane_distinct, (unsigned long long)d.s.dual_lane_same,
	    (unsigned long long)d.s.dual_lane_match,
	    (unsigned long long)d.s.fnv, (unsigned long long)d.s.fnv_want,
	    (unsigned)d.s.underrun_delta(), d.line_count,
	    (unsigned)d.frames_done, d.ok ? 1 : 0);
}

bool checkBeatConservation(const char* tag, const FrameDelta& d) {
	const uint64_t acc = d.s.accepted_rd_beats;
	const uint64_t ret = d.s.returned_rd_beats;
	// Exact after drain (rd-duck): no in-flight slack allowance.
	if (ret != acc) {
		std::printf("%s returned(%llu) != accepted(%llu) (exact conservation)\n", tag,
		            (unsigned long long)ret, (unsigned long long)acc);
		return false;
	}
	if (d.s.payload_beats + d.s.doorbell_beats + d.s.other_beats != acc) {
		std::printf("%s class sum != accepted\n", tag);
		return false;
	}
	return true;
}

bool checkPayloadTight(const char* tag, const FrameDelta& d) {
	const uint64_t expect = payloadExpect(d.line_count);
	if (d.s.payload_beats != expect) {
		std::printf("%s payload got=%llu expect=%llu (ideal+LC(%d)*240)\n", tag,
		            (unsigned long long)d.s.payload_beats, (unsigned long long)expect, d.line_count);
		return false;
	}
	return true;
}

bool checkOutput(const char* tag, const FrameDelta& d, uint64_t full_de) {
	if (d.s.underrun_delta() != 0) {
		std::printf("%s underrun_delta=%u\n", tag, (unsigned)d.s.underrun_delta());
		return false;
	}
	if (d.s.de_groups < full_de) {
		std::printf("%s de_groups=%llu < %llu\n", tag, (unsigned long long)d.s.de_groups, (unsigned long long)full_de);
		return false;
	}
	// dual_lane_match counts correct 40/200 pairs; allow pipe warmup slack.
	if (d.s.dual_lane_match + kRgbPipeSlack < full_de) {
		std::printf("%s dual_lane_match=%llu + slack(%llu) < de %llu\n", tag,
		            (unsigned long long)d.s.dual_lane_match,
		            (unsigned long long)kRgbPipeSlack,
		            (unsigned long long)full_de);
		return false;
	}
	if (d.s.dual_lane_distinct == 0 || d.s.dual_lane_distinct <= d.s.dual_lane_same) {
		std::printf("%s dual_lane not distinct dist=%llu same=%llu (scalar replicate?)\n", tag,
		            (unsigned long long)d.s.dual_lane_distinct,
		            (unsigned long long)d.s.dual_lane_same);
		return false;
	}
	if (d.s.rgb_mismatch != 0) {
		std::printf("%s rgb_mismatch=%llu\n", tag, (unsigned long long)d.s.rgb_mismatch);
		return false;
	}
	if (d.s.fnv != d.s.fnv_want) {
		std::printf("%s full-frame FNV got=0x%016llx want=0x%016llx\n", tag,
		            (unsigned long long)d.s.fnv, (unsigned long long)d.s.fnv_want);
		return false;
	}
	return true;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	constexpr uint64_t kFullDeGroups =
	    static_cast<uint64_t>(kCodedW / kPPC) * static_cast<uint64_t>(kCodedH);

	std::printf("PRE-REG 720p_ppc2_bus FULL+STALL @20:90 (rd-duck gate repair):\n");
	std::printf("  class=isolated_reader_stress beam_fps=%.3f (NOT product 24fps rate-match)\n", kBeamFps);
	std::printf("  payload_expect=ideal+LC*240; accepted≈returned; underrun==0; rgb nonblack\n");
	std::printf("  G0 ideal tight; G1 stall busy↑+same tight bounds+ddr_cy<%llu\n",
	            (unsigned long long)kBudgetDdrCycles24);
	std::printf("  G2 hang-mutant MUST fail (underrun/timeout/short/rgb)\n");
	std::printf("  clocks 20:90 half_ps=%lld/%lld PPC=%d LC_floor=32 PHYS=0x%08x\n",
	            (long long)kHalfSysPs, (long long)kHalfDdrPs, kPPC, kBasePhys);

	if (kUQBase + 2 * kUQwords != static_cast<int>(kPayloadBeatsIdeal))
		return fail("plane qword math != 172800");
	if (payloadExpect(32) != 180480ull) return fail("expect LC32 != 180480");
	if (payloadExpect(8) != 174720ull) return fail("expect LC8 != 174720");

	FrameDelta g0 = measureSteadyFrame(0, 0, 0, -1);
	printCase("G0_full_ideal", g0);
	if (!g0.ok) return fail("G0 steady frame delta not observed");
	if (g0.line_count < 32) return fail("G0 LINE_COUNT must be >=32");
	if (!checkPayloadTight("G0", g0)) return fail("G0 payload not tight (ideal+LC*240)");
	if (!checkBeatConservation("G0", g0)) return fail("G0 beat conservation");
	if (g0.s.doorbell_beats == 0) return fail("G0 expected doorbell RD");
	if (g0.s.ddr_cycles >= kBudgetDdrCycles24) return fail("G0 ddr_cy over 24fps budget wall");
	if (g0.s.max_burst < 2) return fail("G0 burst<=1");
	// Deadline: one beam period (+ drain margin < 5% beam).
	if (g0.s.sys_cycles < kBeamSysCycles) return fail("G0 sys_cy shorter than one beam period");
	if (g0.s.sys_cycles > kBeamSysCycles + kBeamSysCycles / 20ull)
		return fail("G0 sys_cy deadline miss (>> one beam + drain)");
	if (!checkOutput("G0", g0, kFullDeGroups)) return fail("G0 output/underrun/rgb/dual/fnv");
	std::printf("PASS G0 tight payload=%llu returned=%llu und=0 dual_match=%llu fnv_ok\n",
	            (unsigned long long)g0.s.payload_beats, (unsigned long long)g0.s.returned_rd_beats,
	            (unsigned long long)g0.s.dual_lane_match);

	// G1 corrected wall (prereg): beam-locked ddr_cy ≈ G0; discrimination = busy↑ + mutant G2.
	FrameDelta g1 = measureSteadyFrame(3, 8, 3, -1);
	printCase("G1_full_stall", g1);
	if (!g1.ok) return fail("G1 stalled FULL frame not observed");
	if (!checkPayloadTight("G1", g1)) return fail("G1 payload not tight");
	if (!checkBeatConservation("G1", g1)) return fail("G1 beat conservation");
	if (g1.s.rd_blocked < 10) return fail("G1 expected RD-while-BUSY (>=10)");
	if (g1.s.busy_cycles <= g0.s.busy_cycles) return fail("G1 busy_cycles not higher than G0");
	if (g1.s.ddr_cycles >= kBudgetDdrCycles24) return fail("G1 ddr_cy over 24fps budget wall");
	// G1 deadline: must complete the stalled frame within one beam + drain (not hang).
	if (g1.s.sys_cycles < kBeamSysCycles) return fail("G1 sys_cy shorter than one beam");
	if (g1.s.sys_cycles > kBeamSysCycles + kBeamSysCycles / 20ull)
		return fail("G1 deadline miss: sys_cy >> one beam (stall caused frame slip)");
	// Upper beat bound = lower bound (tight equality already); restate payload ceiling.
	if (g1.s.payload_beats > payloadExpect(g1.line_count))
		return fail("G1 payload upper bound exceeded");
	const uint64_t ddr_tol = g0.s.ddr_cycles / 50ull + 1ull;
	if (g1.s.ddr_cycles + ddr_tol < g0.s.ddr_cycles ||
	    g1.s.ddr_cycles > g0.s.ddr_cycles + ddr_tol)
		return fail("G1 ddr_cy not beam-locked to G0");
	if (!checkOutput("G1", g1, kFullDeGroups)) return fail("G1 output/underrun/rgb/dual/fnv");
	std::printf("PASS G1 stall payload=%llu blocked=%llu busy=%llu deadline_sys=%llu und=0 dual_match=%llu\n",
	            (unsigned long long)g1.s.payload_beats, (unsigned long long)g1.s.rd_blocked,
	            (unsigned long long)g1.s.busy_cycles, (unsigned long long)g1.s.sys_cycles,
	            (unsigned long long)g1.s.dual_lane_match);

	std::printf("PRE-REG G2: hang payload after 4096 accepts → must NOT pass tight/underrun/rgb\n");
	FrameDelta g2 = measureSteadyFrame(0, 0, 0, 4096);
	printCase("G2_hang_mutant", g2);
	const int lc = g2.line_count > 0 ? g2.line_count : 32;
	// Mutant must fail at least one hard product gate (not merely "different").
	const bool g2_failed =
	    !g2.ok || g2.timed_out || g2.s.underrun_delta() != 0 ||
	    g2.s.payload_beats < payloadExpect(lc) ||
	    g2.s.rgb_nonblack_groups + kRgbPipeSlack < kFullDeGroups ||
	    g2.s.de_groups < kFullDeGroups ||
	    g2.s.fnv == 14695981039346656037ull ||
	    g2.s.rgb_nonblack_groups == 0;
	if (!g2_failed) return fail("G2 hang mutant did not discriminate (gate tooth broken)");
	std::printf("PASS G2 hang mutant discriminated (ok=%d timeout=%d und=%u payload=%llu rgb_nb=%llu)\n",
	            g2.ok ? 1 : 0, g2.timed_out ? 1 : 0, (unsigned)g2.s.underrun_delta(),
	            (unsigned long long)g2.s.payload_beats, (unsigned long long)g2.s.rgb_nonblack_groups);

	std::printf("BEAT_SUMMARY class=frame_store_reader_demand isolated_stress_fps=%.3f\n", kBeamFps);
	std::printf("  payload_formula=172800+LC*240 LC32_expect=180480 (dual-set warm locked)\n");
	std::printf("  G0 payload_RD=%llu door_RD=%llu accepted=%llu returned=%llu ddr_cy=%llu\n",
	            (unsigned long long)g0.s.payload_beats, (unsigned long long)g0.s.doorbell_beats,
	            (unsigned long long)g0.s.accepted_rd_beats, (unsigned long long)g0.s.returned_rd_beats,
	            (unsigned long long)g0.s.ddr_cycles);
	std::printf("  G1 payload_RD=%llu door_RD=%llu accepted=%llu returned=%llu blocked=%llu\n",
	            (unsigned long long)g1.s.payload_beats, (unsigned long long)g1.s.doorbell_beats,
	            (unsigned long long)g1.s.accepted_rd_beats, (unsigned long long)g1.s.returned_rd_beats,
	            (unsigned long long)g1.s.rd_blocked);
	std::printf("  PROVES: tight beats+upper, underrun0, dual-lane/full-frame FNV, G1 deadline, G2 RED\n");
	std::printf("  DOES_NOT_PROVE: HPS supply, host write, product 24fps rate-match, sustainable BW\n");
	std::printf("  class=isolated_reader_stress beam_fps=%.3f (adopt harness NOT CLOSED)\n", kBeamFps);
	std::printf("PASS ddr_frame_store_720p_ppc2_bus gate-repaired (NOT fit-release CLOSED)\n");
	return 0;
}
