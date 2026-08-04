// MULTI+PPC2 shipping-recipe full-frame proof through REAL ddr_frame_store.
//
// NOT the L4-only TB. Recipe:
//   FRAME 1280×720, PX_PER_CLK=2, 720p ABI (0x30180000/0x180000/0x3047F000)
//   clk_sys model 20 MHz — blackout 500 µs = 10000 cycles
//   t_line @ PPC2 = 1280/2/20e6 = 32 µs → cover8/16 FAIL store, cover32 PASS
//
// Modes: blackout | fullframe | boundaries | neg_count | abi_check | fault_480

#include "Vddr_frame_store_multi_ppc2_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kPhysBase720 = 0x30180000u;
constexpr uint32_t kBankStride720 = 0x00180000u;
constexpr uint32_t kDoorbell720 = 0x3047F000u;
constexpr uint32_t kPhysBase480 = 0x30000000u;
constexpr uint32_t kBankStride480 = 0x00080000u;
constexpr uint32_t kDoorbell480 = 0x300FF000u;
constexpr uint32_t kMemBasePhys = 0x30000000u;
constexpr uint32_t kMemBytes = 0x00580000u;
constexpr uint32_t kMagic = 0x504C584Bu;

// MULTI+PPC2 @ 20 MHz blackout model (rd-duck / w-scaler arith).
constexpr int kClkSysHz = 20'000'000;
constexpr int kPpc = 2;
constexpr int kBlackoutUs = 500;
constexpr int kBlackoutSysCycles = (kClkSysHz / 1'000'000) * kBlackoutUs; // 10000
// PREREG cover: t_line_us = 1280/PPC/f * 1e6 = 32; cover_N = N*32
constexpr double kPreRegTLineUs = 32.0;
constexpr double kPreRegCover8Us = 256.0;
constexpr double kPreRegCover16Us = 512.0;

// Active pixel groups per frame at PPC2 (clk_sys ticks with DE).
constexpr int kPreRegActiveGroups = (1280 * 720) / kPpc; // 460800
constexpr int kPreRegActivePixels = 1280 * 720;          // 921600

constexpr uint8_t kLastY0 = 0xA5, kLastU0 = 0x5A, kLastV0 = 0xC3;
constexpr uint8_t kLastY1 = 0x11, kLastU1 = 0x22, kLastV1 = 0x33;

int gW = 1280;
int gH = 720;
int gPpc = kPpc;

// Filled from DUT after reset (FAULT twin may change ABI).
uint32_t gPhysBase = kPhysBase720;
uint32_t gBankStride = kBankStride720;
uint32_t gDoorbell = kDoorbell720;

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
	return static_cast<uint8_t>((x * 3 + y * 5 + bank * 17) & 0xff);
}
uint8_t uAt(int x, int y, int bank) {
	(void)x; (void)y;
	return static_cast<uint8_t>(128 + bank);
}
uint8_t vAt(int x, int y, int bank) {
	(void)x; (void)y;
	return static_cast<uint8_t>(128 - bank);
}

bool near8(int a, int b) { return a + 1 >= b && a <= b + 1; }

uint64_t fnv1a64_update(uint64_t h, uint8_t b) {
	h ^= b;
	h *= 0x100000001b3ull;
	return h;
}

struct Sim {
	Vddr_frame_store_multi_ppc2_tb top{};
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

	void captureAbi() {
		gPhysBase = top.abi_phys_base;
		gBankStride = top.abi_bank_stride;
		gDoorbell = top.abi_doorbell;
		gPpc = top.abi_px_per_clk ? int(top.abi_px_per_clk) : kPpc;
	}

	uint32_t offQ(uint32_t phys) const { return (phys - kMemBasePhys) / 8u; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kMemBasePhys >> 3); }

	void fillFrame(int bank) {
		const uint32_t base = offQ(gPhysBase + static_cast<uint32_t>(bank) * gBankStride);
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
		const uint32_t off = offQ(gDoorbell);
		if (off >= mem.size()) {
			std::cerr << "FAIL doorbell offset out of mem phys=0x" << std::hex
			          << gDoorbell << std::dec << "\n";
			std::exit(2);
		}
		mem[off] = (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagic;
	}

	void serviceDdrStart() {
		if (top.DDRAM_RD && busy == 0 && rdDelay < 0 && rdLeft == 0) {
			if (hangLineReads && top.DDRAM_ADDR != (gDoorbell >> 3))
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
		captureAbi();
	}

	// Advance glass by PPC pixels per clk_sys (shipping MULTI drain rate).
	void videoTick() {
		top.rd_active = 1;
		top.rd_x = scanX;
		top.rd_y = scanY;
		if (!suppressVsync && scanX == 0 && scanY == 0)
			top.vsync_pulse = 1;
		tick();
		scanX += gPpc;
		if (scanX >= gW) {
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
			          << " phys=0x" << std::hex << gPhysBase
			          << " db=0x" << gDoorbell << std::dec
			          << " debug=0x" << std::hex << int(top.debug_state) << std::dec
			          << "\n";
			std::exit(1);
		}
	}

	uint8_t laneR(int lane) const {
		return static_cast<uint8_t>((top.rd_r_n >> (8 * lane)) & 0xff);
	}
	uint8_t laneG(int lane) const {
		return static_cast<uint8_t>((top.rd_g_n >> (8 * lane)) & 0xff);
	}
	uint8_t laneB(int lane) const {
		return static_cast<uint8_t>((top.rd_b_n >> (8 * lane)) & 0xff);
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
	int groups = 0;
	uint64_t scan_cycles = 0;
	uint64_t pure_pixel_ticks = 0;
	uint16_t underrun = 0;
	int samples_ok = 0;
	int samples_fail = 0;
	int rgb_mismatch = 0;
	uint64_t fnv_got = 0xcbf29ce484222325ull;
	uint64_t fnv_want = 0xcbf29ce484222325ull;
};

// Measured for scalar L4; MULTI N-wide path uses same YUV→RGB pipe depth.
constexpr int kRgbPipeLatency = 1;

ScanResult scanFull(Sim& sim, int bank, bool sample_check) {
	ScanResult r;
	// Bank1 cold scan needs longer settle than bank0 (reset y_bank=0 matches
	// disp_bank=0 and can false-pass bank0; bank1 tags need CDC through).
	sim.suppressVsync = true;
	sim.holdPixel(0, 0, bank == 0 ? 8 : 64);
	sim.suppressVsync = false;
	sim.scanX = 0;
	sim.scanY = 0;
	const uint64_t t0 = sim.cycle;

	struct Pix { uint8_t r, g, b; int x, y; };
	// One pipe entry per group (vector of PPC pixels).
	std::deque<std::vector<Pix>> pipe;

	auto foldLane = [&](uint8_t gr, uint8_t gg, uint8_t gb, const Pix& w, int lane) {
		r.fnv_got = fnv1a64_update(r.fnv_got, gr);
		r.fnv_got = fnv1a64_update(r.fnv_got, gg);
		r.fnv_got = fnv1a64_update(r.fnv_got, gb);
		r.fnv_want = fnv1a64_update(r.fnv_want, w.r);
		r.fnv_want = fnv1a64_update(r.fnv_want, w.g);
		r.fnv_want = fnv1a64_update(r.fnv_want, w.b);
		// Teeth: lane0 multi must match scalar rd_r/g/b (catches yuv_* fn width bugs
		// that only fire when V!=128 — bank0 neutral chroma false-passes).
		if (lane == 0) {
			if (!near8(gr, sim.top.rd_r) || !near8(gg, sim.top.rd_g) ||
			    !near8(gb, sim.top.rd_b)) {
				++r.rgb_mismatch;
				if (r.rgb_mismatch <= 6) {
					std::cerr << "FAIL scalar_vs_multi (" << w.x << "," << w.y
					          << ") bank=" << bank
					          << " multi " << int(gr) << "/" << int(gg) << "/" << int(gb)
					          << " scalar " << int(sim.top.rd_r) << "/" << int(sim.top.rd_g)
					          << "/" << int(sim.top.rd_b) << "\n";
				}
			}
		}
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
		for (int x0 = 0; x0 < gW; x0 += gPpc) {
			sim.videoTick();
			++r.groups;
			std::vector<Pix> grp;
			grp.reserve(static_cast<size_t>(gPpc));
			for (int lane = 0; lane < gPpc; ++lane) {
				const int x = x0 + lane;
				if (x >= gW)
					break;
				++r.pixels;
				++r.pure_pixel_ticks;
				uint8_t er, eg, eb;
				yuvToRgb(yAt(x, y, bank), uAt(x, y, bank), vAt(x, y, bank), er, eg, eb);
				grp.push_back(Pix{er, eg, eb, x, y});
			}
			pipe.push_back(std::move(grp));
			if (static_cast<int>(pipe.size()) > kRgbPipeLatency) {
				const auto wgrp = pipe.front();
				pipe.pop_front();
				for (size_t lane = 0; lane < wgrp.size(); ++lane) {
					foldLane(sim.laneR(static_cast<int>(lane)),
					         sim.laneG(static_cast<int>(lane)),
					         sim.laneB(static_cast<int>(lane)),
					         wgrp[lane], static_cast<int>(lane));
				}
			}
		}
		++r.lines;
	}
	if (!pipe.empty()) {
		const auto& last = pipe.back();
		if (!last.empty())
			sim.holdPixel(last.back().x & ~(gPpc - 1), last.back().y, kRgbPipeLatency + 2);
		while (!pipe.empty()) {
			const auto wgrp = pipe.front();
			pipe.pop_front();
			for (size_t lane = 0; lane < wgrp.size(); ++lane) {
				foldLane(sim.laneR(static_cast<int>(lane)),
				         sim.laneG(static_cast<int>(lane)),
				         sim.laneB(static_cast<int>(lane)),
				         wgrp[lane], static_cast<int>(lane));
			}
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
		std::cerr << "FAIL scanFull: rgb_mismatch=" << r.rgb_mismatch << "\n";
		std::exit(1);
	}
	if (r.fnv_got != r.fnv_want) {
		std::cerr << "FAIL scanFull: FNV mismatch got=0x" << std::hex << r.fnv_got
		          << " want=0x" << r.fnv_want << std::dec << "\n";
		std::exit(1);
	}
	return r;
}

void reportScan(const ScanResult& r, const char* tag) {
	std::cout << "PREREG ppc=" << gPpc
	          << " t_line_us=" << kPreRegTLineUs
	          << " cover8_us=" << kPreRegCover8Us
	          << " cover16_us=" << kPreRegCover16Us
	          << " blackout_cy=" << kBlackoutSysCycles
	          << " active_groups=" << kPreRegActiveGroups
	          << " active_pixels=" << kPreRegActivePixels << "\n";
	std::cout << tag << ": pixels=" << r.pixels << " lines=" << r.lines
	          << " groups=" << r.groups
	          << " pure_pixel_ticks=" << r.pure_pixel_ticks
	          << " wall_scan_cycles=" << r.scan_cycles
	          << " underrun=" << r.underrun
	          << " samples_ok=" << r.samples_ok
	          << " geom=" << gW << "x" << gH
	          << " ppc=" << gPpc << "\n";
	if (r.pixels != gW * gH) {
		std::cerr << "FAIL " << tag << ": pixels=" << r.pixels << " want " << (gW * gH) << "\n";
		std::exit(1);
	}
	if (gPpc == 2 && r.groups != kPreRegActiveGroups && gW == 1280 && gH == 720) {
		std::cerr << "FAIL " << tag << ": groups=" << r.groups
		          << " want " << kPreRegActiveGroups << "\n";
		std::exit(1);
	}
}

int runAbiCheck() {
	Sim sim;
	sim.resetCore();
	std::cout << "abi_check: phys=0x" << std::hex << gPhysBase
	          << " stride=0x" << gBankStride
	          << " doorbell=0x" << gDoorbell << std::dec
	          << " line_count=" << int(sim.top.abi_line_count)
	          << " ppc=" << int(sim.top.abi_px_per_clk) << "\n";
	if (gPhysBase != kPhysBase720 || gBankStride != kBankStride720 ||
	    gDoorbell != kDoorbell720) {
		std::cerr << "FAIL abi_check: MULTI recipe must bind 720p ABI "
		          << "(got phys=0x" << std::hex << gPhysBase << " want 0x" << kPhysBase720
		          << ")\n" << std::dec;
		return 1;
	}
	if (sim.top.abi_px_per_clk != 2) {
		std::cerr << "FAIL abi_check: PX_PER_CLK want 2 got "
		          << int(sim.top.abi_px_per_clk) << "\n";
		return 1;
	}
	// Floor: even if LINE_COUNT param is 8, product floor exposes >=32 unless
	// FORCE_RAW_LINE_COUNT. Default build floors (16 is NOT enough @ PPC2).
	if (sim.top.abi_line_count < 32) {
		std::cerr << "FAIL abi_check: LINE_COUNT floor want>=32 got "
		          << int(sim.top.abi_line_count) << "\n";
		return 1;
	}
	std::cout << "PASS abi_check: MULTI 720p ABI + PPC2 + LINE_COUNT floor>=32\n";
	return 0;
}

int runBlackout() {
	// PREREG arithmetic honesty
	const double t_line = (static_cast<double>(gW) / gPpc) / kClkSysHz * 1e6;
	const double c8 = 8.0 * t_line;
	const double c16 = 16.0 * t_line;
	std::cout << "PREREG blackout arith: t_line_us=" << t_line
	          << " cover8=" << c8 << " cover16=" << c16
	          << " model_us=" << kBlackoutUs << "\n";
	if (c8 >= 500.0 || c16 < 500.0) {
		std::cerr << "FAIL blackout: prereg arith broken c8=" << c8 << " c16=" << c16 << "\n";
		return 2;
	}

	Sim sim;
	sim.fillFrame(0);
	sim.resetCore();
	sim.primeAndPresent(0, 1);

	// Warm a few lines
	for (int i = 0; i < (gW / gPpc) * 24; ++i)
		sim.videoTick();

	const uint16_t ur0 = sim.top.underrun_count;
	sim.hangLineReads = true;
	sim.forceDdrBusy = true;
	for (int i = 0; i < kBlackoutSysCycles; ++i)
		sim.videoTick();
	sim.hangLineReads = false;
	sim.forceDdrBusy = false;
	for (int i = 0; i < (gW / gPpc) * 4; ++i)
		sim.videoTick();

	const uint16_t ur1 = sim.top.underrun_count;
	std::cout << "blackout: underrun before=" << ur0 << " after=" << ur1
	          << " delta=" << (ur1 - ur0)
	          << " blackout_cy=" << kBlackoutSysCycles
	          << " (500us@20MHz) line_count=" << int(sim.top.abi_line_count)
	          << " ppc=" << gPpc << "\n";

	if (ur1 > ur0) {
		std::cerr << "FAIL blackout: underrun during MULTI+PPC2 500us blackout delta="
		          << (ur1 - ur0) << "\n";
		return 1;
	}
	std::cout << "PASS blackout: no underrun MULTI+PPC2 500us@20MHz\n";
	return 0;
}

int runFullframe(int expect_pixels, bool enforce) {
	Sim sim;
	sim.fillFrame(0);
	sim.resetCore();
	if (gPhysBase != kPhysBase720) {
		std::cerr << "FAIL fullframe: ABI not 720p phys=0x" << std::hex << gPhysBase
		          << std::dec << "\n";
		return 1;
	}
	const uint64_t t0 = sim.cycle;
	sim.primeAndPresent(0, 1);
	std::cout << "fullframe: prep_cy=" << (sim.cycle - t0)
	          << " ddr_beats=" << sim.ddrReadBeats
	          << " ddr_issues=" << sim.ddrReadIssues
	          << " abi_phys=0x" << std::hex << gPhysBase << std::dec << "\n";

	const ScanResult r = scanFull(sim, 0, true);
	reportScan(r, "fullframe");
	if (r.underrun != 0) {
		std::cerr << "FAIL fullframe: underrun=" << r.underrun << "\n";
		return 1;
	}
	if (enforce && r.pixels != expect_pixels) {
		std::cerr << "FAIL fullframe: pixels=" << r.pixels << " expect " << expect_pixels << "\n";
		return 1;
	}
	std::cout << "fullframe: fnv=0x" << std::hex << r.fnv_got << std::dec
	          << " rgb_mismatch=0\n";
	std::cout << "PASS fullframe: MULTI+PPC2 1280x720 complete pixels=" << r.pixels
	          << " groups=" << r.groups
	          << " fnv=0x" << std::hex << r.fnv_got << std::dec << "\n";
	return 0;
}

int runBoundaries() {
	Sim sim;
	sim.fillFrame(0);
	sim.fillFrame(1);
	sim.resetCore();
	sim.primeAndPresent(0, 1);
	const ScanResult r0 = scanFull(sim, 0, true);
	reportScan(r0, "boundaries_bank0");
	if (r0.underrun != 0 || r0.pixels != gW * gH)
		return 1;

	Sim sim1;
	sim1.fillFrame(1);
	sim1.resetCore();
	sim1.primeAndPresent(1, 3);
	const ScanResult r1 = scanFull(sim1, 1, true);
	reportScan(r1, "boundaries_bank1");
	if (r1.underrun != 0 || r1.pixels != gW * gH)
		return 1;

	// In-session swap bank0→bank1 mid-stream.
	Sim sim2;
	sim2.fillFrame(0);
	sim2.fillFrame(1);
	sim2.resetCore();
	sim2.primeAndPresent(0, 1);
	for (int i = 0; i < (gW / gPpc) * 48; ++i)
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
		std::cerr << "FAIL boundaries: bank swap never committed\n";
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
	std::cout << "boundaries: swap_bank1_match=" << int(live)
	          << " underrun=" << sim2.top.underrun_count << "\n";
	if (!live) {
		std::cerr << "FAIL boundaries: post-swap (0,0) not bank1\n";
		return 1;
	}
	std::cout << "PASS boundaries: MULTI+PPC2 bank0/bank1/swap OK\n";
	return 0;
}

int runNegCount() {
	const int wrong = 1280 * 480;
	std::cout << "neg_count: wrong expect=" << wrong << " true=" << (gW * gH) << "\n";
	return runFullframe(wrong, true);
}

int runFault480() {
	// Built with FAULT_480P_ABI=1 — doorbell at 480p page while frame is 720p.
	Sim sim;
	sim.resetCore();
	std::cout << "fault_480: phys=0x" << std::hex << gPhysBase
	          << " doorbell=0x" << gDoorbell << std::dec << "\n";
	if (gPhysBase == kPhysBase720) {
		std::cerr << "FAIL fault_480: expected 480p PHYS twin, still 720p\n";
		return 2;
	}
	if (gPhysBase != kPhysBase480 || gDoorbell != kDoorbell480) {
		std::cerr << "FAIL fault_480: unexpected twin ABI\n";
		return 2;
	}
	// Present may still "work" at wrong base if memory is zero — require that
	// shipping abi_check would reject this PHYS (negative twin for shell).
	std::cout << "PASS fault_480: twin elaborates 480p ABI (shell expects RED vs shipping)\n";
	return 0;
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
	if (expect_pixels < 0)
		expect_pixels = gW * gH;

	std::cout << "MULTI_PPC2_TB mode=" << mode << " geom=" << gW << "x" << gH
	          << " expect_pixels=" << expect_pixels << "\n";
	std::cout << "PREREG_NOTE: recipe=PRESENT_MULTI_PIXEL+PPC2+FRAME1280x720 "
	          << "clk=20MHz blackout_cy=" << kBlackoutSysCycles
	          << " cover8_us=" << kPreRegCover8Us
	          << " cover16_us=" << kPreRegCover16Us
	          << " (NOT L4-only TB)\n";

	if (std::strcmp(mode, "abi_check") == 0)
		return runAbiCheck();
	if (std::strcmp(mode, "blackout") == 0)
		return runBlackout();
	if (std::strcmp(mode, "fullframe") == 0)
		return runFullframe(expect_pixels, true);
	if (std::strcmp(mode, "boundaries") == 0)
		return runBoundaries();
	if (std::strcmp(mode, "neg_count") == 0)
		return runNegCount();
	if (std::strcmp(mode, "fault_480") == 0)
		return runFault480();
	std::cerr << "usage: " << argv[0]
	          << " abi_check|blackout|fullframe|boundaries|neg_count|fault_480\n";
	return 2;
}
