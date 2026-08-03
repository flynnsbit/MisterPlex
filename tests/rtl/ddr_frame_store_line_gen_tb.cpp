// Line-cache frame-gen gate (rd-duck).
// Primary REPRO: same-bank re-publish while pending (no swap yet).
//   FAULT: prep {bank,line} tags still valid → swap shows first publish Y.
//   GOOD: doorbell bumps bank gen + clears tags → must show second publish Y.
// Also: geom pitch change bumps both bank gens.

#include "Vddr_frame_store_line_gen_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
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
constexpr int kHTotal = 160;
constexpr int kRdDelay = 3;
constexpr int kLineCount = 8;

constexpr uint8_t kYFirst = 0x41;
constexpr uint8_t kYSecond = 0xC3; // re-publish while pending
constexpr uint8_t kYOther = 0x82;
constexpr uint8_t kYGeom = 0xE7;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (8 * i);
	return q;
}

struct Sim {
	Vddr_frame_store_line_gen_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	int line_reads = 0;

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
		top.geom_enable = 0;
		top.rt_coded_w = 0;
		top.rt_coded_h = 0;
		top.rt_y_stride = 0;
		top.rt_chroma_stride = 0;
		top.rt_display_w = 0;
		top.rt_display_h = 0;
		top.rt_present_x = 0;
		top.rt_present_y = 0;
		top.rt_crop_left = 0;
		top.rt_crop_top = 0;
		top.DDRAM_BUSY = 0;
		top.DDRAM_DOUT = 0;
		top.DDRAM_DOUT_READY = 0;
	}

	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

	void fillFrame(int bank, uint8_t frameY) {
		const uint32_t base = (bank * kBankStrideBytes) / 8;
		for (int line = 0; line < kH; ++line)
			for (int q = 0; q < kYQ; ++q)
				mem[base + line * kYQ + q] = pack8(frameY);
		for (int line = 0; line < kH / 2; ++line)
			for (int q = 0; q < kCQ; ++q) {
				mem[base + kUQBase + line * kCQ + q] = pack8(128);
				mem[base + kVQBase + line * kCQ + q] = pack8(128);
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
			if (rdAddr != (kDoorbellPhys >> 3))
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
		top.vsync_pulse = 0;
	}

	void driveBeam(bool with_vsync) {
		const bool in_vblank = (vc >= kActH);
		const int rd_y = in_vblank ? (kActH - 1) : vc;
		const bool x_de = (hc >= kPresentX) && (hc < kPresentX + kDispW);
		top.rd_y = rd_y;
		top.rd_active = (x_de && !in_vblank) ? 1 : 0;
		top.rd_x = (hc >= kW) ? (kW - 1) : hc;
		top.vsync_pulse = with_vsync ? 1 : 0;
	}

	bool videoTick() {
		const bool last_line = (vc == (kActH + kVBlank - 1));
		const bool pre_vsync = last_line && (hc == (kHTotal - 2));
		if (pre_vsync) {
			for (int spin = 0; spin < 6000; ++spin) {
				driveBeam(false);
				tick();
				if (top.swap_pending && top.debug_pending_ready)
					break;
			}
			++hc;
		}
		const bool at_frame_start =
		    (hc == (kHTotal - 1)) && (vc == (kActH + kVBlank - 1));
		driveBeam(at_frame_start);
		tick();
		++hc;
		if (hc == kHTotal) {
			hc = 0;
			++vc;
			if (vc == kActH + kVBlank)
				vc = 0;
		}
		return at_frame_start;
	}

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 16; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 8; ++i)
			tick();
	}

	bool waitFramesDone(int target, int max_ticks = 400000) {
		for (int i = 0; i < max_ticks && top.frames_done < target; ++i)
			videoTick();
		return top.frames_done >= target;
	}

	bool waitPendingReady(int max_ticks = 200000) {
		for (int i = 0; i < max_ticks; ++i) {
			videoTick();
			if (top.swap_pending && top.debug_pending_ready)
				return true;
		}
		return false;
	}

	int sampleTopY(int max_frames = 1) {
		int hist[256]{};
		int n = 0, frames = 0;
		const int total = kHTotal * (kActH + kVBlank);
		while (frames < max_frames) {
			for (int i = 0; i < total; ++i) {
				const bool vs = videoTick();
				if (top.has_frame && top.rd_active && int(top.rd_y) < kLineCount) {
					const int r = int(top.rd_r);
					if (r > 0) {
						hist[r & 255]++;
						++n;
					}
				}
				if (vs)
					++frames;
			}
		}
		if (n == 0)
			return -1;
		int best = 0, bestc = -1;
		for (int i = 1; i < 256; ++i)
			if (hist[i] > bestc) {
				bestc = hist[i];
				best = i;
			}
		return best;
	}
};

bool nearY(int got, int expect, int tol = 14) {
	if (got < 0)
		return false;
	const int d = got - expect;
	return d <= tol && d >= -tol;
}

int run_case(bool expect_fresh) {
	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 1500; ++i)
		sim.tick();

	std::cout << "PRE-REGISTER line_gen=" << int(sim.top.debug_line_gen)
	          << " expect_fresh=" << int(expect_fresh)
	          << " Y_first=0x" << std::hex << int(kYFirst)
	          << " Y_second=0x" << int(kYSecond) << std::dec << "\n";

	// Seed an opposite bank on display so bank0 is purely prep on first publish.
	sim.fillFrame(1, kYOther);
	sim.ringDoorbell(1, 1);
	if (!sim.waitFramesDone(1)) {
		std::cerr << "FAIL: seed frames_done=1\n";
		return 1;
	}

	// Publish bank0 first payload and wait until prep is ready (no swap yet).
	sim.fillFrame(0, kYFirst);
	sim.ringDoorbell(0, 2);
	if (!sim.waitPendingReady()) {
		std::cerr << "FAIL: first bank0 publish never pending_ready\n";
		return 1;
	}
	const int reads_at_ready = sim.line_reads;
	std::cout << "first_pending_ready gen0=" << int(sim.top.debug_bank_gen0)
	          << " reads=" << reads_at_ready << "\n";

	// Re-publish bank0 with NEW pixels while still pending (rd-duck class).
	sim.fillFrame(0, kYSecond);
	sim.ringDoorbell(0, 3);
	// Give CDC a few lines; FAULT may stay ready without refetch.
	for (int i = 0; i < kHTotal * 3; ++i)
		sim.videoTick();
	const int reads_after_repub = sim.line_reads - reads_at_ready;
	std::cout << "after_repub swap_pend=" << int(sim.top.swap_pending)
	          << " pend_rdy=" << int(sim.top.debug_pending_ready)
	          << " reads_delta=" << reads_after_repub
	          << " gen0=" << int(sim.top.debug_bank_gen0) << "\n";

	// Now allow swap and sample top lines of displayed bank0.
	const int fd0 = sim.top.frames_done;
	if (!sim.waitFramesDone(fd0 + 1)) {
		std::cerr << "FAIL: no swap after re-publish\n";
		return 1;
	}
	const int y = sim.sampleTopY(1);
	std::cout << "sample after_swap Y=" << y << " gen0=" << int(sim.top.debug_bank_gen0)
	          << " gen1=" << int(sim.top.debug_bank_gen1) << "\n";

	const bool fresh = nearY(y, kYSecond);
	const bool stale = nearY(y, kYFirst) && !fresh;

	if (expect_fresh) {
		if (!fresh) {
			std::cerr << "FAIL line_gen=1: expected second publish Y~" << int(kYSecond)
			          << " got " << y << " stale=" << stale << "\n";
			return 1;
		}
		if (reads_after_repub < 4) {
			std::cerr << "FAIL line_gen=1: re-publish must refetch, reads_delta="
			          << reads_after_repub << "\n";
			return 1;
		}
		// Geom epoch
		const int g0b = sim.top.debug_bank_gen0;
		const int g1b = sim.top.debug_bank_gen1;
		sim.top.geom_enable = 1;
		sim.top.rt_coded_w = 80;
		sim.top.rt_coded_h = 48;
		sim.top.rt_y_stride = 88;
		sim.top.rt_chroma_stride = 40;
		sim.top.rt_display_w = 64;
		sim.top.rt_display_h = 40;
		sim.top.rt_present_x = 4;
		sim.top.rt_present_y = 0;
		for (int i = 0; i < 3000; ++i)
			sim.tick();
		if (sim.top.debug_bank_gen0 <= g0b && sim.top.debug_bank_gen1 <= g1b) {
			std::cerr << "FAIL: geom pitch change did not bump bank gens ("
			          << g0b << "," << g1b << " -> " << int(sim.top.debug_bank_gen0)
			          << "," << int(sim.top.debug_bank_gen1) << ")\n";
			return 1;
		}
		std::cout << "PASS line_gen_product: fresh_Y=" << y
		          << " repub_reads=" << reads_after_repub
		          << " geom_gen_bump=1\n";
		return 0;
	}

	// FAULT twin
	if (stale) {
		std::cout << "REPRO_OK line_gen_fault: stale_Y=" << y
		          << " matched_first=" << int(kYFirst)
		          << " repub_reads=" << reads_after_repub << "\n";
		return 0;
	}
	if (reads_after_repub < 4 && sim.top.debug_pending_ready) {
		// Stayed ready without refetch — still the defect class even if sample
		// later got overwritten by beam refill.
		std::cout << "REPRO_OK line_gen_fault: false_ready_no_refetch reads_delta="
		          << reads_after_repub << " y=" << y << "\n";
		return 0;
	}
	std::cerr << "FAIL line_gen=0: expected stale Y or false-ready, got Y=" << y
	          << " reads_delta=" << reads_after_repub << "\n";
	return 1;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* env = std::getenv("LINE_GEN_EXPECT_FRESH");
	const bool expect_fresh = (env == nullptr) ? true : (std::string(env) != "0");
	const int rc = run_case(expect_fresh);
	std::cout << "line_gen_tb rc=" << rc << " expect_fresh=" << int(expect_fresh) << "\n";
	return rc;
}
