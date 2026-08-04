// L4 720p ddr_frame_store reader proof.
//
// Modes (argv[1]):
//   blackout   — 500 µs DDR blackout underrun gate (LINE_COUNT via -G)
//   fullframe  — complete progressive scan; cycle budget; boundary samples
//   boundaries — bank0 full scan + bank0→bank1 swap + bank1 full scan
//   awkward    — non-multiple-of-16 height (FRAME_H via -G / L4_TB_H)
//   neg_count  — intentionally wrong expected pixel count → must FAIL
//
// Optional: --expect-pixels N  (fullframe only; default W*H)

#include "Vddr_frame_store_l4_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <deque>
#include <vector>

namespace {

constexpr uint32_t kPhysBase = 0x30180000u;
constexpr uint32_t kBankStride = 0x00180000u;
constexpr uint32_t kDoorbellPhys = 0x3047F000u;
constexpr uint32_t kMemBasePhys = 0x30000000u;
// Covers bank0@PHYS, bank1@PHYS+STRIDE, doorbell@0x3047F000 (end 0x30580000).
constexpr uint32_t kMemBytes = 0x00580000u;
constexpr uint32_t kMagic = 0x504C584Bu;

// L4 beam budget @ 24 MHz (layout params / w-clock):
//   H_TOTAL=1312 V_TOTAL=762 → 999_744 cycles/frame
//   DE active 1280*720 = 921_600 at 1 px/clk
// PRE-REGISTERED before measure:
constexpr int kBeamHTotal = 1312;
constexpr int kBeamVTotal = 762;
constexpr int kBudgetCyclesPerFrame = kBeamHTotal * kBeamVTotal; // 999744
constexpr int kPreRegActiveScan720 = 1280 * 720;                 // 921600
constexpr int kPreRegBlankMargin = kBudgetCyclesPerFrame - kPreRegActiveScan720; // 78144

constexpr int kBlackoutSysCycles = 12000; // 500 µs @ 24 MHz

constexpr uint8_t kLastY0 = 0xA5, kLastU0 = 0x5A, kLastV0 = 0xC3;
constexpr uint8_t kLastY1 = 0x11, kLastU1 = 0x22, kLastV1 = 0x33;

int gW = 1280;
int gH = 720;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint8_t sat8(int v) {
	if (v < 0) return 0;
	if (v > 255) return 255;
	return static_cast<uint8_t>(v);
}

void yuvToRgb(uint8_t y, uint8_t u, uint8_t v, uint8_t& r, uint8_t& g, uint8_t& b) {
	const int y_s = static_cast<int>(y);
	const int u_s = static_cast<int>(u) - 128;
	const int v_s = static_cast<int>(v) - 128;
	r = sat8(((y_s << 8) + 359 * v_s) >> 8);
	g = sat8(((y_s << 8) - 88 * u_s - 183 * v_s) >> 8);
	b = sat8(((y_s << 8) + 454 * u_s) >> 8);
}

uint8_t yAt(int x, int y, int bank) {
	if (x == gW - 1 && y == gH - 1)
		return bank ? kLastY1 : kLastY0;
	return static_cast<uint8_t>((x * 3 + y * 5 + bank * 17) & 0xff);
}

uint8_t uAt(int x, int y, int bank) {
	if (x >= gW - 2 && y >= gH - 2)
		return bank ? kLastU1 : kLastU0;
	return static_cast<uint8_t>(128 + bank);
}

uint8_t vAt(int x, int y, int bank) {
	if (x >= gW - 2 && y >= gH - 2)
		return bank ? kLastV1 : kLastV0;
	return static_cast<uint8_t>(128 - bank);
}

bool near8(int a, int b) { return a + 1 >= b && a <= b + 1; }

uint64_t fnv1a64_update(uint64_t h, uint8_t b) {
	h ^= b;
	h *= 0x100000001b3ull;
	return h;
}

struct Sim {
	Vddr_frame_store_l4_tb top{};
	std::vector<uint64_t> mem;
	uint64_t cycle = 0;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int scanX = 0;
	int scanY = 0;
	bool forceDdrBusy = false;
	bool hangLineReads = false;
	bool suppressVsync = false;
	uint64_t ddrReadBeats = 0;
	uint64_t ddrReadIssues = 0;

	int yQ() const { return gW / 8; }
	int cQ() const { return gW / 16; }
	int yPlaneQ() const { return (gW * gH) / 8; }
	int cPlaneQ() const { return (gW * gH) / 32; }
	int uQBase() const { return yPlaneQ(); }
	int vQBase() const { return yPlaneQ() + cPlaneQ(); }

	Sim() : mem(kMemBytes / 8u, 0) {
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

	uint32_t offQ(uint32_t phys) const { return (phys - kMemBasePhys) / 8u; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kMemBasePhys >> 3); }

	void fillFrame(int bank) {
		const uint32_t base = offQ(kPhysBase + static_cast<uint32_t>(bank) * kBankStride);
		const int yq = yQ();
		const int cq = cQ();
		for (int y = 0; y < gH; ++y) {
			for (int q = 0; q < yq; ++q) {
				uint64_t word = 0;
				for (int i = 0; i < 8; ++i) {
					const int x = q * 8 + i;
					word |= static_cast<uint64_t>(yAt(x, y, bank)) << (8 * i);
				}
				mem[base + static_cast<uint32_t>(y * yq + q)] = word;
			}
		}
		const int ch = gH / 2;
		for (int cy = 0; cy < ch; ++cy) {
			for (int q = 0; q < cq; ++q) {
				uint64_t uw = 0, vw = 0;
				for (int i = 0; i < 8; ++i) {
					const int x = q * 16 + i * 2;
					const int y = cy * 2;
					uw |= static_cast<uint64_t>(uAt(x, y, bank)) << (8 * i);
					vw |= static_cast<uint64_t>(vAt(x, y, bank)) << (8 * i);
				}
				mem[base + static_cast<uint32_t>(uQBase() + cy * cq + q)] = uw;
				mem[base + static_cast<uint32_t>(vQBase() + cy * cq + q)] = vw;
			}
		}
	}

	void ringDoorbell(int bank, uint32_t seq) {
		const uint32_t off = offQ(kDoorbellPhys);
		if (off >= mem.size()) {
			std::cerr << "FAIL doorbell offset out of mem\n";
			std::exit(2);
		}
		mem[off] = (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagic;
	}

	void serviceDdrStart() {
		if (top.DDRAM_RD && busy == 0 && rdDelay < 0 && rdLeft == 0) {
			if (hangLineReads && top.DDRAM_ADDR != (kDoorbellPhys >> 3))
				return;
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
			rdIndex = 0;
			rdDelay = 1;
			busy = rdLeft + rdDelay + 1;
			++ddrReadIssues;
		}
		if (top.DDRAM_WE && busy == 0) {
			const uint32_t off = addrOffQ(top.DDRAM_ADDR);
			if (off < mem.size())
				mem[off] = top.DDRAM_DIN;
			busy = 2;
		}
	}

	void serviceDdrDrive() {
		top.DDRAM_DOUT_READY = 0;
		if (busy > 0)
			--busy;
		top.DDRAM_BUSY = forceDdrBusy || (busy > 0) ? 1 : 0;
		if (rdDelay >= 0) {
			if (rdDelay > 0) {
				--rdDelay;
			} else if (rdLeft > 0) {
				const uint32_t off = addrOffQ(rdAddr + static_cast<uint32_t>(rdIndex));
				top.DDRAM_DOUT = off < mem.size() ? mem[off] : 0;
				top.DDRAM_DOUT_READY = 1;
				++rdIndex;
				--rdLeft;
				++ddrReadBeats;
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

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 16; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 8; ++i)
			tick();
	}

	void videoTick() {
		top.rd_active = 1;
		top.rd_x = scanX;
		top.rd_y = scanY;
		if (!suppressVsync && scanX == 0 && scanY == 0)
			top.vsync_pulse = 1;
		tick();
		++scanX;
		if (scanX == gW) {
			scanX = 0;
			++scanY;
			if (scanY == gH)
				scanY = 0;
		}
	}

	bool waitForFrame(int maxCycles) {
		const int start = top.frames_done;
		for (int i = 0; i < maxCycles; ++i) {
			top.rd_active = 0;
			top.rd_x = 0;
			top.rd_y = 0;
			if ((i % 64) == 0)
				top.vsync_pulse = 1;
			tick();
			if (top.frames_done > start && top.has_frame)
				return true;
		}
		return top.has_frame != 0;
	}

	void holdPixel(int x, int y, int n) {
		top.rd_x = x;
		top.rd_y = y;
		top.rd_active = 1;
		for (int i = 0; i < n; ++i)
			tick();
	}

	void primeAndPresent(int bank, uint32_t seq) {
		for (int i = 0; i < 8000; ++i)
			tick();
		ringDoorbell(bank, seq);
		if (!waitForFrame(400000)) {
			std::cerr << "FAIL never got has_frame bank=" << bank
			          << " frames=" << top.frames_done
			          << " swap_pending=" << int(top.swap_pending)
			          << " doorbell_ok=" << int(top.doorbell_ok)
			          << " debug=0x" << std::hex << int(top.debug_state) << std::dec
			          << "\n";
			std::exit(1);
		}
	}
};

bool sampleHere(int x, int y) {
	if (x == 0 && y == 0) return true;
	if (x == gW - 1 && y == 0) return true;
	if (x == 0 && y == gH - 1) return true;
	if (x == gW - 1 && y == gH - 1) return true;
	if (gH >= 16 && x == gW / 2 && y == gH - 16) return true;
	if (x == gW - 8 && y == gH - 1) return true;
	return false;
}

struct ScanResult {
	int pixels = 0;
	int lines = 0;
	uint64_t scan_cycles = 0;
	uint64_t pure_pixel_ticks = 0;
	uint16_t underrun = 0;
	int samples_ok = 0;
	int samples_fail = 0;
	int rgb_mismatch = 0;
	uint64_t fnv_got = 0xcbf29ce484222325ull;
	uint64_t fnv_want = 0xcbf29ce484222325ull;
};

// ddr_frame_store RGB path depth (rd_* -> YUV combo -> rd_r/g/b).
// Measured: latency=1 is byte-identical FNV over full 1280x720 (921600 px);
// latency 0/2+ go RED. If this drifts, full-frame FNV goes RED.
constexpr int kRgbPipeLatency = 1;

ScanResult scanFull(Sim& sim, int bank, bool sample_check) {
	ScanResult r;
	// Settle video-side line-hit CDC after present: dwell on (0,0) with
	// rd_active like post-vsync blanking. Without this, bank1 cold scans
	// miss (y_bank_v2/disp_bank) while bank0 can false-pass because reset
	// y_bank=0 matches initial disp_bank=0 even before tags CDC through.
	sim.suppressVsync = true;
	sim.holdPixel(0, 0, 8);
	sim.suppressVsync = false;
	sim.scanX = 0;
	sim.scanY = 0;
	const uint64_t t0 = sim.cycle;
	struct Pix { uint8_t r, g, b; int x, y; };
	std::deque<Pix> pipe;

	auto fold = [&](uint8_t gr, uint8_t gg, uint8_t gb, const Pix& w) {
		r.fnv_got = fnv1a64_update(r.fnv_got, gr);
		r.fnv_got = fnv1a64_update(r.fnv_got, gg);
		r.fnv_got = fnv1a64_update(r.fnv_got, gb);
		r.fnv_want = fnv1a64_update(r.fnv_want, w.r);
		r.fnv_want = fnv1a64_update(r.fnv_want, w.g);
		r.fnv_want = fnv1a64_update(r.fnv_want, w.b);
		if (!near8(gr, w.r) || !near8(gg, w.g) || !near8(gb, w.b)) {
			++r.rgb_mismatch;
			if (r.rgb_mismatch <= 6) {
				std::cerr << "FAIL rgb (" << w.x << "," << w.y << ") bank=" << bank
				          << " got " << int(gr) << "/" << int(gg) << "/" << int(gb)
				          << " want " << int(w.r) << "/" << int(w.g) << "/" << int(w.b)
				          << "\n";
			}
		}
		if (sample_check && sampleHere(w.x, w.y)) {
			if (!near8(gr, w.r) || !near8(gg, w.g) || !near8(gb, w.b))
				++r.samples_fail;
			else
				++r.samples_ok;
		}
	};

	for (int y = 0; y < gH; ++y) {
		for (int x = 0; x < gW; ++x) {
			sim.videoTick();
			++r.pixels;
			++r.pure_pixel_ticks;
			uint8_t er, eg, eb;
			yuvToRgb(yAt(x, y, bank), uAt(x, y, bank), vAt(x, y, bank), er, eg, eb);
			pipe.push_back(Pix{er, eg, eb, x, y});
			if (static_cast<int>(pipe.size()) > kRgbPipeLatency) {
				const Pix w = pipe.front();
				pipe.pop_front();
				fold(sim.top.rd_r, sim.top.rd_g, sim.top.rd_b, w);
			}
		}
		++r.lines;
	}
	// Drain pipeline at last pixel.
	if (!pipe.empty()) {
		const Pix last = pipe.back();
		sim.holdPixel(last.x, last.y, kRgbPipeLatency + 2);
		while (!pipe.empty()) {
			const Pix w = pipe.front();
			pipe.pop_front();
			fold(sim.top.rd_r, sim.top.rd_g, sim.top.rd_b, w);
		}
	}

	r.scan_cycles = sim.cycle - t0;
	r.underrun = sim.top.underrun_count;
	if (sample_check && r.samples_fail != 0)
		std::exit(1);
	if (sample_check && r.samples_ok < 4) {
		std::cerr << "FAIL scanFull: too few boundary samples ok=" << r.samples_ok << "\n";
		std::exit(1);
	}
	if (r.rgb_mismatch != 0) {
		std::cerr << "FAIL scanFull: rgb_mismatch=" << r.rgb_mismatch << " of "
		          << r.pixels << "\n";
		std::exit(1);
	}
	if (r.fnv_got != r.fnv_want) {
		std::cerr << "FAIL scanFull: full-frame FNV mismatch got=0x" << std::hex
		          << r.fnv_got << " want=0x" << r.fnv_want << std::dec << "\n";
		std::exit(1);
	}
	return r;
}

void reportBudget(const ScanResult& r, const char* tag) {
	std::cout << "PREREG active_scan_720=" << kPreRegActiveScan720
	          << " beam_budget=" << kBudgetCyclesPerFrame
	          << " blank_margin=" << kPreRegBlankMargin << "\n";
	std::cout << tag << ": pixels=" << r.pixels << " lines=" << r.lines
	          << " pure_pixel_ticks=" << r.pure_pixel_ticks
	          << " wall_scan_cycles=" << r.scan_cycles
	          << " underrun=" << r.underrun
	          << " samples_ok=" << r.samples_ok
	          << " geom=" << gW << "x" << gH << "\n";
	const int64_t delta_pure =
		static_cast<int64_t>(r.pure_pixel_ticks) -
		static_cast<int64_t>(gW) * static_cast<int64_t>(gH);
	std::cout << tag << ": delta_pure_vs_WxH=" << delta_pure
	          << " (must be 0)\n";
	if (delta_pure != 0) {
		std::cerr << "FAIL " << tag << ": pure pixel tick count mismatch\n";
		std::exit(1);
	}
	if (gW == 1280 && gH == 720) {
		const int64_t vs_prereg =
			static_cast<int64_t>(r.pure_pixel_ticks) - kPreRegActiveScan720;
		const int64_t vs_budget =
			static_cast<int64_t>(r.pure_pixel_ticks) - kBudgetCyclesPerFrame;
		std::cout << tag << ": delta_vs_prereg_active=" << vs_prereg
		          << " delta_vs_beam_budget=" << vs_budget
		          << " (negative => under budget / fits)\n";
		if (r.pure_pixel_ticks > static_cast<uint64_t>(kBudgetCyclesPerFrame)) {
			std::cerr << "CRITICAL: pure active ticks exceed L4 beam budget "
			          << r.pure_pixel_ticks << " > " << kBudgetCyclesPerFrame << "\n";
			std::exit(1);
		}
	}
}

int runBlackout() {
	Sim sim;
	sim.fillFrame(0);
	sim.resetCore();
	sim.primeAndPresent(0, 1);

	for (int i = 0; i < gW * 24; ++i)
		sim.videoTick();

	const uint16_t ur0 = sim.top.underrun_count;
	sim.hangLineReads = true;
	sim.forceDdrBusy = true;
	for (int i = 0; i < kBlackoutSysCycles; ++i)
		sim.videoTick();
	sim.hangLineReads = false;
	sim.forceDdrBusy = false;
	for (int i = 0; i < gW * 4; ++i)
		sim.videoTick();

	const uint16_t ur1 = sim.top.underrun_count;
	std::cout << "blackout: underrun before=" << ur0 << " after=" << ur1
	          << " delta=" << (ur1 - ur0)
	          << " blackout_cy=" << kBlackoutSysCycles
	          << " geom=" << gW << "x" << gH << "\n";

	if (ur1 > ur0) {
		std::cerr << "FAIL blackout: line buffer underran during "
		          << kBlackoutSysCycles << "-cycle (500us@24MHz) DDR blackout "
		          << "delta=" << (ur1 - ur0) << "\n";
		return 1;
	}
	std::cout << "PASS blackout: no underrun across modelled 500us DDR blackout\n";
	return 0;
}

int runFullframe(int expect_pixels, bool enforce_expect) {
	Sim sim;
	sim.fillFrame(0);
	sim.resetCore();
	const uint64_t t_reset = sim.cycle;
	sim.primeAndPresent(0, 1);
	const uint64_t prep_cycles = sim.cycle - t_reset;
	std::cout << "fullframe: prep_to_has_frame_cycles=" << prep_cycles
	          << " ddr_read_beats=" << sim.ddrReadBeats
	          << " ddr_read_issues=" << sim.ddrReadIssues << "\n";

	const ScanResult r = scanFull(sim, 0, true);
	reportBudget(r, "fullframe");

	if (r.underrun != 0) {
		std::cerr << "FAIL fullframe: underrun_count=" << r.underrun << "\n";
		return 1;
	}
	if (r.lines != gH) {
		std::cerr << "FAIL fullframe: lines=" << r.lines << " want " << gH << "\n";
		return 1;
	}
	if (enforce_expect && r.pixels != expect_pixels) {
		std::cerr << "FAIL fullframe: pixels=" << r.pixels << " expect "
		          << expect_pixels << "\n";
		return 1;
	}
	std::cout << "fullframe: fnv=0x" << std::hex << r.fnv_got << std::dec
	          << " rgb_mismatch=" << r.rgb_mismatch
	          << " (FNV covers all " << r.pixels << " RGB triples)\n";
	std::cout << "PASS fullframe: " << gW << "x" << gH
	          << " complete scan, boundary samples OK, underrun=0"
	          << " pixels=" << r.pixels
	          << " fnv=0x" << std::hex << r.fnv_got << std::dec << "\n";
	return 0;
}

int runBoundaries() {
	// 1) Bank0 full progressive scan with in-scan boundary samples.
	Sim sim;
	sim.fillFrame(0);
	sim.fillFrame(1);
	sim.resetCore();
	sim.primeAndPresent(0, 1);

	const ScanResult r0 = scanFull(sim, 0, true);
	reportBudget(r0, "boundaries_bank0");
	if (r0.underrun != 0) {
		std::cerr << "FAIL boundaries: bank0 underrun=" << r0.underrun << "\n";
		return 1;
	}
	if (r0.pixels != gW * gH) {
		std::cerr << "FAIL boundaries: bank0 pixels=" << r0.pixels << " want "
		          << (gW * gH) << "\n";
		return 1;
	}

	// 2) Bank1 fresh present at PHYS+STRIDE — proves bank-wrap addressing and
	//    distinct last-pixel markers (not a silent alias of bank0).
	Sim sim1;
	sim1.fillFrame(1);
	sim1.resetCore();
	sim1.primeAndPresent(1, 3);
	const ScanResult r1 = scanFull(sim1, 1, true);
	reportBudget(r1, "boundaries_bank1_fresh");
	if (r1.underrun != 0) {
		std::cerr << "FAIL boundaries: bank1 fresh underrun=" << r1.underrun << "\n";
		return 1;
	}
	if (r1.pixels != gW * gH) {
		std::cerr << "FAIL boundaries: bank1 pixels=" << r1.pixels << " want "
		          << (gW * gH) << "\n";
		return 1;
	}

	uint8_t rr0, gg0, bb0, rr1, gg1, bb1;
	yuvToRgb(kLastY0, kLastU0, kLastV0, rr0, gg0, bb0);
	yuvToRgb(kLastY1, kLastU1, kLastV1, rr1, gg1, bb1);
	if (rr0 == rr1 && gg0 == gg1 && bb0 == bb1) {
		std::cerr << "FAIL boundaries: bank markers not distinct\n";
		return 1;
	}

	// 3) In-session bank transition: short bank0 display, doorbell bank1, long
	//    idle prep, vsync commit, require bank1 RGB at (0,0).
	Sim sim2;
	sim2.fillFrame(0);
	sim2.fillFrame(1);
	sim2.resetCore();
	sim2.primeAndPresent(0, 1);
	for (int i = 0; i < gW * 48; ++i)
		sim2.videoTick();
	const int f0 = sim2.top.frames_done;
	sim2.ringDoorbell(1, 9);
	for (int i = 0; i < 150000; ++i) {
		sim2.top.rd_active = 0;
		sim2.tick();
	}
	bool swapped = false;
	for (int i = 0; i < 100000; ++i) {
		sim2.top.rd_active = 0;
		if ((i % 64) == 0)
			sim2.top.vsync_pulse = 1;
		sim2.tick();
		if (sim2.top.frames_done > f0 && sim2.top.has_frame && !sim2.top.swap_pending) {
			swapped = true;
			break;
		}
	}
	if (!swapped) {
		std::cerr << "FAIL boundaries: in-session bank1 swap never committed "
		          << "frames=" << sim2.top.frames_done << " start=" << f0
		          << " swap_pending=" << int(sim2.top.swap_pending) << "\n";
		return 1;
	}
	sim2.suppressVsync = true;
	uint8_t er, eg, eb;
	yuvToRgb(yAt(0, 0, 1), uAt(0, 0, 1), vAt(0, 0, 1), er, eg, eb);
	bool live = false;
	for (int i = 0; i < 40000; ++i) {
		sim2.holdPixel(0, 0, 1);
		if (near8(sim2.top.rd_r, er) && near8(sim2.top.rd_g, eg) &&
		    near8(sim2.top.rd_b, eb)) {
			live = true;
			break;
		}
	}
	std::cout << "boundaries: in_session_swap_bank1_match=" << int(live)
	          << " got=" << int(sim2.top.rd_r) << "/" << int(sim2.top.rd_g) << "/"
	          << int(sim2.top.rd_b) << " want=" << int(er) << "/" << int(eg) << "/"
	          << int(eb)
	          << " underrun=" << sim2.top.underrun_count << "\n";
	if (!live) {
		std::cerr << "FAIL boundaries: in-session swap committed but (0,0) is not "
		          << "bank1 content (reader/bank-tag path)\n";
		return 1;
	}

	std::cout << "PASS boundaries: last-line/MB-row + bank1@PHYS+STRIDE + in-session "
	          << "swap pixels_b0=" << r0.pixels << " pixels_b1=" << r1.pixels
	          << " underrun=0\n";
	return 0;
}

int runAwkward() {
	if ((gH % 16) == 0) {
		std::cerr << "FAIL awkward: height " << gH
		          << " is multiple of 16 - build with non-multiple (e.g. 718)\n";
		return 2;
	}
	if ((gH % 2) != 0) {
		std::cerr << "FAIL awkward: height must be even for 420 chroma\n";
		return 2;
	}
	std::cout << "awkward: geom=" << gW << "x" << gH << " H%16=" << (gH % 16) << "\n";

	Sim sim;
	sim.fillFrame(0);
	sim.resetCore();
	sim.primeAndPresent(0, 1);
	const ScanResult r = scanFull(sim, 0, true);
	reportBudget(r, "awkward");
	if (r.underrun != 0) {
		std::cerr << "FAIL awkward: underrun=" << r.underrun << "\n";
		return 1;
	}
	if (r.pixels != gW * gH || r.lines != gH) {
		std::cerr << "FAIL awkward: pixels/lines " << r.pixels << "/" << r.lines
		          << " want " << (gW * gH) << "/" << gH << "\n";
		return 1;
	}
	std::cout << "PASS awkward: non-multiple-of-16 height " << gH
	          << " full scan OK pixels=" << r.pixels << "\n";
	return 0;
}

int runNegCount() {
	const int wrong = 1280 * 480; // 614400 — 480p-era leftover
	std::cout << "neg_count: intentionally expecting wrong pixels=" << wrong
	          << " (true WxH=" << (gW * gH) << ")\n";
	return runFullframe(wrong, true);
}





void applyGeomFromEnv() {
	if (const char* w = std::getenv("L4_TB_W"))
		gW = std::atoi(w);
	if (const char* h = std::getenv("L4_TB_H"))
		gH = std::atoi(h);
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = "fullframe";
	int expect_pixels = -1;
	for (int i = 1; i < argc; ++i) {
		if (std::strcmp(argv[i], "--expect-pixels") == 0 && i + 1 < argc) {
			expect_pixels = std::atoi(argv[++i]);
			continue;
		}
		if (argv[i][0] != '-')
			mode = argv[i];
	}

	gW = 1280;
	gH = 720;
	applyGeomFromEnv();
	if (expect_pixels < 0)
		expect_pixels = gW * gH;

	std::cout << "L4_TB mode=" << mode << " geom=" << gW << "x" << gH
	          << " expect_pixels=" << expect_pixels << "\n";
	std::cout << "PREREG_NOTE: active_scan_720=" << kPreRegActiveScan720
	          << " beam_budget_cycles=" << kBudgetCyclesPerFrame
	          << " blank_margin=" << kPreRegBlankMargin << "\n";

	if (std::strcmp(mode, "blackout") == 0)
		return runBlackout();
	if (std::strcmp(mode, "fullframe") == 0)
		return runFullframe(expect_pixels, true);
	if (std::strcmp(mode, "boundaries") == 0)
		return runBoundaries();
	if (std::strcmp(mode, "awkward") == 0)
		return runAwkward();
	if (std::strcmp(mode, "neg_count") == 0)
		return runNegCount();
	std::cerr << "usage: " << argv[0]
	          << " blackout|fullframe|boundaries|awkward|neg_count "
	             "[--expect-pixels N]\n";
	return 2;
}
