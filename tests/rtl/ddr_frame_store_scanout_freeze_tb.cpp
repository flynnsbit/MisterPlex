// Real-RTL scanout freeze gate (parent HW: 9eb1431a src_y_line → one frozen band).
//
// Pre-register:
//   WANT_Y_LINE_ONLY=1 + PENDING_READY_STICKY_PREP=0 → FAIL freeze (9eb1431a)
//   WANT_Y_LINE_ONLY=1 + PENDING_READY_STICKY_PREP=1 → PASS motion + swaps (fix)
// No WANT_Y_FORCE_TOP.

#include "Vddr_frame_store_scanout_freeze_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <set>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 65536u;
constexpr uint32_t kDoorbellPhys = 0x3001F000u;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr int kW = 80;
constexpr int kH = 48;
constexpr int kDispW = 64;
constexpr int kPresentX = 4;
constexpr int kActH = 40;
constexpr int kVBlank = 48;
constexpr int kYQ = kW / 8;
constexpr int kCQ = kW / 16;
constexpr int kUQBase = (kW * kH) / 8;
constexpr int kVQBase = kUQBase + (kW * kH) / 32;
constexpr int kRdDelay = 2;
constexpr int kFrames = 6;
constexpr int kHTotal = 160;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) |
	       (1u << 29) |
	       (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (i * 8);
	return q;
}

struct Sim {
	Vddr_frame_store_scanout_freeze_tb top{};
	std::vector<uint64_t> mem;
	uint64_t cycle = 0;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	int line_reads = 0;
	int poll_reads = 0;

	Sim() : mem((2 * kBankStrideBytes) / 8, 0) {
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

	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

	void fillFrame(int bank, uint8_t yBase) {
		const uint32_t base = (bank * kBankStrideBytes) / 8;
		for (int line = 0; line < kH; ++line) {
			const uint8_t y = static_cast<uint8_t>(yBase + line * 3);
			for (int q = 0; q < kYQ; ++q)
				mem[base + line * kYQ + q] = pack8(y);
		}
		for (int line = 0; line < kH / 2; ++line) {
			for (int q = 0; q < kCQ; ++q) {
				mem[base + kUQBase + line * kCQ + q] = pack8(128);
				mem[base + kVQBase + line * kCQ + q] = pack8(128);
			}
		}
	}

	void ringDoorbell(int bank, uint32_t seq) {
		mem[offQ(kDoorbellPhys)] =
		    (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagic;
	}

	void serviceDdrStart() {
		if (top.DDRAM_RD && busy == 0 && rdDelay < 0 && rdLeft == 0) {
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT;
			rdIndex = 0;
			rdDelay = kRdDelay;
			busy = rdLeft + rdDelay + 2;
			if (rdAddr == (kDoorbellPhys >> 3))
				++poll_reads;
			else
				++line_reads;
		}
		if (top.DDRAM_WE && busy == 0) {
			const uint32_t off = addrOffQ(top.DDRAM_ADDR);
			if (off < mem.size())
				mem[off] = top.DDRAM_DIN;
			busy = 3;
		}
	}

	void serviceDdrDrive() {
		top.DDRAM_DOUT_READY = 0;
		if (busy > 0)
			--busy;
		top.DDRAM_BUSY = (busy > 0);
		if (rdDelay >= 0) {
			if (rdDelay > 0) {
				--rdDelay;
			} else if (rdLeft > 0) {
				const uint32_t off = addrOffQ(rdAddr + rdIndex);
				top.DDRAM_DOUT = off < mem.size() ? mem[off] : 0;
				top.DDRAM_DOUT_READY = 1;
				++rdIndex;
				--rdLeft;
				if (rdLeft == 0)
					rdDelay = -1;
			}
		}
	}

	void tick() {
		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		serviceDdrDrive();
		top.clk = 1;
		top.clk_ddr = 1;
		top.eval();
		serviceDdrStart();
		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		++cycle;
		top.vsync_pulse = 0;
	}

	void driveBeam(bool with_vsync) {
		const int last_y = kActH - 1;
		const bool in_vblank = (vc >= kActH);
		const int rd_y = in_vblank ? last_y : vc;
		const bool x_de = (hc >= kPresentX) && (hc < kPresentX + kDispW);
		const bool y_de = !in_vblank;
		top.rd_y = rd_y;
		top.rd_active = (x_de && y_de) ? 1 : 0;
		top.rd_x = (hc >= kW) ? (kW - 1) : hc;
		top.vsync_pulse = with_vsync ? 1 : 0;
	}

	bool videoTick() {
		const bool last_line = (vc == (kActH + kVBlank - 1));
		const bool pre_vsync = last_line && (hc == (kHTotal - 2));
		if (pre_vsync) {
			hc = kHTotal - 2;
			for (int spin = 0; spin < 12000; ++spin) {
				driveBeam(false);
				tick();
				if (!top.swap_pending && top.debug_state_ddr == 0)
					break;
				if (top.swap_pending && top.debug_pending_ready &&
				    top.debug_state_ddr == 0)
					break;
			}
			++hc;
		}
		const bool at_frame_start =
		    (hc == (kHTotal - 1)) && (vc == (kActH + kVBlank - 1));
		driveBeam(at_frame_start);
		const int pend_now = top.debug_pending_ready;
		const int swap_now = top.swap_pending;
		tick();
		if (at_frame_start) {
			last_vsync_pend = pend_now;
			last_vsync_swap = swap_now;
			last_vsync_state = top.debug_state_ddr;
			last_vsync_need_prep = top.debug_need_y_prep;
			last_vsync_need_cur = top.debug_need_y_cur;
			last_vsync_prc = top.debug_pending_ready_c;
			last_vsync_sched = top.debug_sched_valid;
			last_vsync_sfp = top.debug_sched_for_pend;
			last_vsync_want = top.debug_want_y;
		}
		++hc;
		if (hc == kHTotal) {
			hc = 0;
			++vc;
			if (vc == kActH + kVBlank)
				vc = 0;
		}
		return at_frame_start;
	}
	int last_vsync_pend = 0;
	int last_vsync_swap = 0;
	int last_vsync_state = 0;
	int last_vsync_need_prep = 0;
	int last_vsync_need_cur = 0;
	int last_vsync_prc = 0;
	int last_vsync_sched = 0;
	int last_vsync_sfp = 0;
	int last_vsync_want = 0;

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 16; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 8; ++i)
			tick();
	}
};

uint64_t mix(uint64_t h, uint64_t x) {
	return h ^ (x + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
}

struct FrameObs {
	std::set<int> hit_ys;
	uint64_t hash = 0;
	int hit_px = 0;
	int miss_px = 0;
	int max_want = 0;
	int unique_want = 0;
	int pend_rdy_cycles = 0;
	int swap_at_vsync = 0;
	int pend_at_vsync = 0;
	int frames_done_delta = 0;
	int st = 0, np = 0, nc = 0, prc = 0, sch = 0, sfp = 0, wy = 0;
};

FrameObs runFrame(Sim& sim, std::set<int>& want_seen) {
	FrameObs o;
	const int fd0 = sim.top.frames_done;
	const int total = kHTotal * (kActH + kVBlank);
	for (int i = 0; i < total; ++i) {
		const int y = sim.top.rd_y;
		const int active = sim.top.rd_active;
		if (sim.top.debug_pending_ready)
			++o.pend_rdy_cycles;
		const bool vs = sim.videoTick();
		if (vs) {
			o.swap_at_vsync = sim.last_vsync_swap;
			o.pend_at_vsync = sim.last_vsync_pend;
			o.st = sim.last_vsync_state;
			o.np = sim.last_vsync_need_prep;
			o.nc = sim.last_vsync_need_cur;
			o.prc = sim.last_vsync_prc;
			o.sch = sim.last_vsync_sched;
			o.sfp = sim.last_vsync_sfp;
			o.wy = sim.last_vsync_want;
		}
		if (active) {
			const int r = sim.top.rd_r;
			const int g = sim.top.rd_g;
			const int b = sim.top.rd_b;
			const bool black = (r | g | b) == 0;
			if (black)
				++o.miss_px;
			else {
				++o.hit_px;
				o.hit_ys.insert(y);
				o.hash = mix(o.hash, (uint64_t(r) << 16) | (uint64_t(g) << 8) | b);
				o.hash = mix(o.hash, uint64_t(y));
			}
		}
		want_seen.insert(sim.top.debug_want_y);
		if (sim.top.debug_want_y > o.max_want)
			o.max_want = sim.top.debug_want_y;
	}
	o.unique_want = static_cast<int>(want_seen.size());
	o.frames_done_delta = sim.top.frames_done - fd0;
	return o;
}

int run_policy(const char* label, bool expect_pass) {
	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 2000; ++i)
		sim.tick();

	std::vector<FrameObs> frames;
	std::vector<uint64_t> hashes;
	int bank = 0;
	uint32_t seq = 1;
	sim.fillFrame(bank, static_cast<uint8_t>(40 + seq * 17));
	sim.ringDoorbell(bank, seq);

	for (int i = 0; i < 50000 && sim.top.frames_done < 1; ++i)
		sim.videoTick();
	if (sim.top.frames_done < 1) {
		std::cerr << "FAIL " << label << ": never got first frames_done"
		          << " has_frame=" << int(sim.top.has_frame)
		          << " swap_pending=" << int(sim.top.swap_pending)
		          << " line_reads=" << sim.line_reads
		          << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
		return 1;
	}

	for (int f = 0; f < kFrames; ++f) {
		if (!sim.top.swap_pending) {
			bank ^= 1;
			++seq;
			sim.fillFrame(bank, static_cast<uint8_t>(40 + seq * 17));
			sim.ringDoorbell(bank, seq);
			for (int i = 0; i < kHTotal * 2; ++i)
				sim.videoTick();
		}

		std::set<int> want_seen;
		FrameObs o = runFrame(sim, want_seen);
		frames.push_back(o);
		hashes.push_back(o.hash);

		std::cout << "raw " << label << " frame=" << f
		          << " frames_done=" << sim.top.frames_done
		          << " fd_delta=" << o.frames_done_delta
		          << " swap_pend=" << int(sim.top.swap_pending)
		          << " pend_rdy_cy=" << o.pend_rdy_cycles
		          << " at_vsync(swap=" << o.swap_at_vsync
		          << ",pend=" << o.pend_at_vsync
		          << ",st=" << o.st
		          << ",np=" << o.np << ",nc=" << o.nc
		          << ",prc=" << o.prc
		          << ",sch=" << o.sch << ",sfp=" << o.sfp
		          << ",want=" << o.wy << ")"
		          << " buf=" << int(sim.top.debug_disp_buf)
		          << " db=" << int(sim.top.debug_disp_bank)
		          << " pb=" << int(sim.top.debug_pending_bank)
		          << " yv_cur=0x" << std::hex << int(sim.top.debug_y_valid_cur)
		          << " yv_prep=0x" << int(sim.top.debug_y_valid_prep)
		          << " cv_prep=0x" << int(sim.top.debug_c_valid_prep) << std::dec
		          << " cur_ylines=[" << int(sim.top.debug_y_line0) << ","
		          << int(sim.top.debug_y_line1) << ","
		          << int(sim.top.debug_y_line2) << ","
		          << int(sim.top.debug_y_line3) << "]"
		          << " cur_ybanks=0x" << std::hex << int(sim.top.debug_y_bank_cur) << std::dec
		          << " hit_px=" << o.hit_px << " miss_px=" << o.miss_px
		          << " unique_hit_y=" << o.hit_ys.size()
		          << " hash=0x" << std::hex << o.hash << std::dec
		          << " underrun=" << sim.top.underrun_count
		          << " line_reads=" << sim.line_reads
		          << "\n";
	}

	std::set<uint64_t> uh(hashes.begin(), hashes.end());
	int max_unique_y = 0;
	for (auto& o : frames)
		if (static_cast<int>(o.hit_ys.size()) > max_unique_y)
			max_unique_y = static_cast<int>(o.hit_ys.size());

	int late_unique_y = 9999;
	std::set<uint64_t> late_hashes;
	for (size_t i = 2; i < frames.size(); ++i) {
		late_hashes.insert(frames[i].hash);
		if (static_cast<int>(frames[i].hit_ys.size()) < late_unique_y)
			late_unique_y = static_cast<int>(frames[i].hit_ys.size());
	}
	const bool motion = late_hashes.size() >= 2;
	const bool one_line_band = late_unique_y <= 4;
	const bool no_swap = sim.top.frames_done < 3;
	const bool freeze = (one_line_band && !motion) || no_swap;

	std::cout << "summary " << label
	          << " distinct_hashes_all=" << uh.size()
	          << " late_hashes=" << late_hashes.size()
	          << " max_unique_hit_y=" << max_unique_y
	          << " late_min_unique_y=" << late_unique_y
	          << " motion=" << motion
	          << " one_line_band=" << one_line_band
	          << " no_swap=" << no_swap
	          << " freeze=" << freeze
	          << " frames_done=" << sim.top.frames_done
	          << " line_reads=" << sim.line_reads
	          << " sticky_probe=" << int(sim.top.debug_sticky_prep)
	          << " recycle_probe=" << int(sim.top.debug_prep_recycle)
	          << "\n";

	if (expect_pass) {
		if (no_swap || !motion) {
			std::cerr << "FAIL " << label
			          << ": expected moving scanout with advancing frames_done"
			          << " late_min_unique_y=" << late_unique_y
			          << " late_hashes=" << late_hashes.size()
			          << " frames_done=" << sim.top.frames_done << "\n";
			return 1;
		}
		std::cout << "PASS " << label << ": motion + swaps"
		          << " frames_done=" << sim.top.frames_done
		          << " late_hashes=" << late_hashes.size() << "\n";
		return 0;
	}

	if (!(no_swap || (!motion && one_line_band))) {
		std::cerr << "FAIL " << label
		          << ": expected silicon-class freeze, but scanout looked alive"
		          << " late_min_unique_y=" << late_unique_y
		          << " late_hashes=" << late_hashes.size()
		          << " frames_done=" << sim.top.frames_done
		          << " — TB still does not reproduce HW\n";
		return 1;
	}
	std::cout << "REPRO_OK " << label
	          << ": freeze-class reproduced (one_line_band=" << one_line_band
	          << " motion=" << motion
	          << " no_swap=" << no_swap
	          << " late_min_unique_y=" << late_unique_y << ")\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Sim probe;
	probe.resetCore();
	const bool sticky = probe.top.debug_sticky_prep != 0;
	const bool recycle = probe.top.debug_prep_recycle != 0;
	const bool product = sticky && recycle;

	if (!product) {
		std::cout << "build: LINE_ONLY + sticky=" << sticky
		          << " recycle=" << recycle
		          << " (9eb1431a-class / expect freeze)\n";
		return run_policy("src_y_line_9eb1431a", /*expect_pass=*/false);
	}
	std::cout << "build: LINE_ONLY + sticky=1 recycle=1 (product fix)\n";
	return run_policy("src_y_line_product_fix", /*expect_pass=*/true);
}
