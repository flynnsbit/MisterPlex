// L4 720p ddr_frame_store reader proof.
//
// Modes (argv[1]):
//   blackout  — scan under modelled 500 µs DDR blackout; FAIL if underrun.
//               LINE_COUNT=8 is expected RED; LINE_COUNT=16 expected GREEN.
//   fullframe — scan all 1280×720 pixels; assert final (1279,719) RGB matches
//               the YUV layout prediction (BT.601 as in ddr_frame_store).
//
// Compile-time: -GLINE_COUNT=N on the SV top (default 8).

#include "Vddr_frame_store_l4_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kPhysBase = 0x30180000u;
constexpr uint32_t kBankStride = 0x00180000u;
constexpr uint32_t kDoorbellPhys = 0x3047F000u;
// Cover 480p control-plane mailboxes (0x3007_Fxxx) and 720p banks/doorbell.
constexpr uint32_t kMemBasePhys = 0x30000000u;
constexpr uint32_t kMemBytes = 0x00580000u; // through 0x3057FFFF
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr int kW = 1280;
constexpr int kH = 720;
constexpr int kYQ = kW / 8;                 // 160
constexpr int kCQ = kW / 16;                // 80
constexpr int kYPlaneQ = (kW * kH) / 8;     // 115200
constexpr int kCPlaneQ = (kW * kH) / 32;    // 28800
constexpr int kUQBase = kYPlaneQ;
constexpr int kVQBase = kYPlaneQ + kCPlaneQ;

// 500 µs @ 24 MHz sys (L4 beam model) = 12000 cycles.
// 8 lines × 1280 px ≈ 10240 cy (~427 µs) < 500 µs → underrun expected.
// 16 lines × 1280 ≈ 20480 cy (~853 µs) > 500 µs → hold.
constexpr int kBlackoutSysCycles = 12000;

// Unique last-pixel YUV (layout prediction subject).
constexpr uint8_t kLastY = 0xA5;
constexpr uint8_t kLastU = 0x5A;
constexpr uint8_t kLastV = 0xC3;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) |
	       (1u << 29) | // YUV420p
	       (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (8 * i);
	return q;
}

uint8_t sat8(int v) {
	if (v < 0)
		return 0;
	if (v > 255)
		return 255;
	return static_cast<uint8_t>(v);
}

// Match ddr_frame_store.sv BT.601 integer path (r_calc_w[19:8] style).
void yuvToRgb(uint8_t y, uint8_t u, uint8_t v, uint8_t& r, uint8_t& g, uint8_t& b) {
	const int y_s = static_cast<int>(y);
	const int u_s = static_cast<int>(u) - 128;
	const int v_s = static_cast<int>(v) - 128;
	const int r_w = (y_s << 8) + 359 * v_s;
	const int g_w = (y_s << 8) - 88 * u_s - 183 * v_s;
	const int b_w = (y_s << 8) + 454 * u_s;
	r = sat8(r_w >> 8);
	g = sat8(g_w >> 8);
	b = sat8(b_w >> 8);
}

uint8_t yAt(int x, int y) {
	if (x == kW - 1 && y == kH - 1)
		return kLastY;
	// Mild spatial pattern; neutral chroma → RGB≈Y for spot checks.
	return static_cast<uint8_t>((x * 3 + y * 5) & 0xff);
}

uint8_t uAt(int x, int y) {
	if (x >= kW - 2 && y >= kH - 2)
		return kLastU;
	return 128;
}

uint8_t vAt(int x, int y) {
	if (x >= kW - 2 && y >= kH - 2)
		return kLastV;
	return 128;
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
		const uint32_t base =
			offQ(kPhysBase + static_cast<uint32_t>(bank) * kBankStride);
		for (int y = 0; y < kH; ++y) {
			for (int q = 0; q < kYQ; ++q) {
				uint64_t word = 0;
				for (int i = 0; i < 8; ++i) {
					const int x = q * 8 + i;
					word |= static_cast<uint64_t>(yAt(x, y)) << (8 * i);
				}
				mem[base + static_cast<uint32_t>(y * kYQ + q)] = word;
			}
		}
		for (int cy = 0; cy < kH / 2; ++cy) {
			for (int q = 0; q < kCQ; ++q) {
				uint64_t uw = 0, vw = 0;
				for (int i = 0; i < 8; ++i) {
					// Each chroma sample covers 2 luma x; pack 8 chroma bytes → 16 luma x.
					const int x = q * 16 + i * 2;
					const int y = cy * 2;
					uw |= static_cast<uint64_t>(uAt(x, y)) << (8 * i);
					vw |= static_cast<uint64_t>(vAt(x, y)) << (8 * i);
				}
				mem[base + kUQBase + static_cast<uint32_t>(cy * kCQ + q)] = uw;
				mem[base + kVQBase + static_cast<uint32_t>(cy * kCQ + q)] = vw;
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
				return; // drop line refill during blackout
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
			rdIndex = 0;
			rdDelay = 1;
			busy = rdLeft + rdDelay + 1;
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
		if (scanX == 0 && scanY == 0)
			top.vsync_pulse = 1;
		tick();
		++scanX;
		if (scanX == kW) {
			scanX = 0;
			++scanY;
			if (scanY == kH)
				scanY = 0;
		}
	}

	bool waitForFrame(int maxCycles) {
		const int start = top.frames_done;
		// Prep-set fill runs on clk_ddr while swap_pending; does not need
		// rd_active. Promote needs vsync_pulse && pending_ready (warm_reset
		// static wait pattern).
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
};

int runBlackout() {
	Sim sim;
	sim.fillFrame(0);
	sim.resetCore();
	// IGNORE_STALE_DOORBELL_AFTER_RESET: first poll must prime before a new
	// doorbell can raise swap_pending (ddr_frame_store.sv db_new_seq).
	for (int i = 0; i < 8000; ++i)
		sim.tick();
	sim.ringDoorbell(0, 1);

	if (!sim.waitForFrame(400000)) {
		std::cerr << "FAIL blackout: never got has_frame "
		          << " frames=" << sim.top.frames_done
		          << " underrun=" << sim.top.underrun_count
		          << " swap_pending=" << int(sim.top.swap_pending)
		          << " doorbell_ok=" << int(sim.top.doorbell_ok)
		          << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec
		          << "\n";
		return 1;
	}

	// Prefill: advance enough lines that the window is warm.
	for (int i = 0; i < kW * 24; ++i)
		sim.videoTick();

	const uint16_t ur0 = sim.top.underrun_count;
	// Modelled DDR blackout: drop line refills for 500 µs of sys time.
	sim.hangLineReads = true;
	sim.forceDdrBusy = true;
	for (int i = 0; i < kBlackoutSysCycles; ++i)
		sim.videoTick();
	sim.hangLineReads = false;
	sim.forceDdrBusy = false;

	// Drain a few more lines after recovery window.
	for (int i = 0; i < kW * 4; ++i)
		sim.videoTick();

	const uint16_t ur1 = sim.top.underrun_count;

	std::cout << "blackout: underrun before=" << ur0 << " after=" << ur1
	          << " delta=" << (ur1 - ur0)
	          << " blackout_cy=" << kBlackoutSysCycles << "\n";

	if (ur1 > ur0) {
		std::cerr << "FAIL blackout: line buffer underran during "
		          << kBlackoutSysCycles << "-cycle (500us@24MHz) DDR blackout "
		          << "delta=" << (ur1 - ur0) << "\n";
		return 1;
	}
	std::cout << "PASS blackout: no underrun across modelled 500us DDR blackout\n";
	return 0;
}

int runFullframe() {
	Sim sim;
	sim.fillFrame(0);
	sim.resetCore();
	for (int i = 0; i < 8000; ++i)
		sim.tick();
	sim.ringDoorbell(0, 1);

	if (!sim.waitForFrame(400000)) {
		std::cerr << "FAIL fullframe: never got has_frame "
		          << " frames=" << sim.top.frames_done
		          << " swap_pending=" << int(sim.top.swap_pending)
		          << " doorbell_ok=" << int(sim.top.doorbell_ok) << "\n";
		return 1;
	}

	// Complete progressive scan of the presented 1280×720 window.
	sim.scanX = 0;
	sim.scanY = 0;
	const uint64_t startCy = sim.cycle;
	for (int y = 0; y < kH; ++y) {
		for (int x = 0; x < kW; ++x)
			sim.videoTick();
	}
	// Hold on the last pixel so the RGB pipeline (rd_*_d / miss_d) settles.
	sim.holdPixel(kW - 1, kH - 1, 32);

	uint8_t er, eg, eb;
	yuvToRgb(kLastY, kLastU, kLastV, er, eg, eb);
	const uint8_t gr = sim.top.rd_r;
	const uint8_t gg = sim.top.rd_g;
	const uint8_t gb = sim.top.rd_b;

	std::cout << "fullframe: scanned " << (kW * kH) << " pixels"
	          << " cycles=" << (sim.cycle - startCy)
	          << " underrun=" << sim.top.underrun_count
	          << " last_rgb got=" << int(gr) << "/" << int(gg) << "/" << int(gb)
	          << " want=" << int(er) << "/" << int(eg) << "/" << int(eb) << "\n";

	if (sim.top.underrun_count != 0) {
		std::cerr << "FAIL fullframe: underrun_count=" << sim.top.underrun_count
		          << " during complete 720p scan\n";
		return 1;
	}
	// Allow ±1 LSB on the fixed-point YUV path.
	auto near = [](int a, int b) { return a + 1 >= b && a <= b + 1; };
	if (!near(gr, er) || !near(gg, eg) || !near(gb, eb)) {
		std::cerr << "FAIL fullframe: final pixel (1279,719) RGB mismatch "
		          << "got " << int(gr) << "/" << int(gg) << "/" << int(gb)
		          << " want " << int(er) << "/" << int(eg) << "/" << int(eb)
		          << " from YUV " << int(kLastY) << "/" << int(kLastU) << "/"
		          << int(kLastV) << "\n";
		return 1;
	}

	// First pixel spot-check after rewind hold.
	sim.holdPixel(0, 0, 64);
	uint8_t fr, fg, fb;
	yuvToRgb(yAt(0, 0), uAt(0, 0), vAt(0, 0), fr, fg, fb);
	if (!near(sim.top.rd_r, fr) || !near(sim.top.rd_g, fg) || !near(sim.top.rd_b, fb)) {
		std::cerr << "FAIL fullframe: first pixel (0,0) mismatch got "
		          << int(sim.top.rd_r) << "/" << int(sim.top.rd_g) << "/"
		          << int(sim.top.rd_b) << " want " << int(fr) << "/" << int(fg)
		          << "/" << int(fb) << "\n";
		return 1;
	}

	std::cout << "PASS fullframe: 1280x720 complete scan, final pixel OK, underrun=0\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = (argc >= 2) ? argv[1] : "blackout";
	if (std::strcmp(mode, "blackout") == 0)
		return runBlackout();
	if (std::strcmp(mode, "fullframe") == 0)
		return runFullframe();
	std::cerr << "usage: " << argv[0] << " blackout|fullframe\n";
	return 2;
}
