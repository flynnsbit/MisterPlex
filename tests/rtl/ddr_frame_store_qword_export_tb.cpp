// Multi-lane free-lunch from ddr_frame_store qword export (w-scaler).
//
// GREEN (+DDR_FRAME_STORE_EXPORT_QWORDS):
//   Fill Y gradient (byte = x&0xff), U=V=128. Capture export at base_x=16.
//   Reconstruct RGB for lanes 0..3 from one Y qword; must match single-pixel rd_*.
//
// RED (+DDR_FRAME_STORE_FAULT_QWORD_LANE0):
//   Same reconstruct but always pick Y byte0 — must FAIL vs single-pixel.
// Soft-skip≠PASS. true rc direct.

#include "Vddr_frame_store_qword_export_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kDoorbellPhys = 0x300FF000u;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr int kW = 624;
constexpr int kH = 480;
constexpr int kUQ = (kW * kH) / 8;           // 37440
constexpr int kVQ = kUQ + (kW * kH) / 32;    // 46800
constexpr int kYPitchQ = kW / 8;             // 78
constexpr int kCPitchQ = kW / 16;            // 39
constexpr size_t kMemQ = (4u * 1024u * 1024u) / 8u;
constexpr int kHTotal = 800;
constexpr int kVBlank = 16;
constexpr int kFrameW = 640;
constexpr int kFrameH = 64; // short frame for sim speed; fill covers these lines

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint8_t pick8(uint64_t q, unsigned idx) {
	return static_cast<uint8_t>((q >> (8 * (idx & 7u))) & 0xffu);
}

uint8_t sat8(int v) {
	if (v < 0)
		return 0;
	if (v > 255)
		return 255;
	return static_cast<uint8_t>(v);
}

void yuv_to_rgb(uint8_t y, uint8_t u, uint8_t v, uint8_t& r, uint8_t& g, uint8_t& b) {
	const int ys = y;
	const int us = int(u) - 128;
	const int vs = int(v) - 128;
	r = sat8(ys + ((359 * vs) >> 8));
	g = sat8(ys - ((88 * us + 183 * vs) >> 8));
	b = sat8(ys + ((454 * us) >> 8));
}

struct Sim {
	Vddr_frame_store_qword_export_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;

	Sim() : mem(kMemQ, 0) {
		top.clk = 0;
		top.clk_ddr = 0;
		top.reset = 0;
		top.rd_x = 0;
		top.rd_y = 0;
		top.rd_active = 0;
		top.start_req = 1;
		top.bank_sel = 0;
		top.vsync_pulse = 0;
		top.DDRAM_BUSY = 0;
		top.DDRAM_DOUT = 0;
		top.DDRAM_DOUT_READY = 0;
	}

	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

	void fillGradient(int lines_y) {
		for (size_t i = 0; i < mem.size(); ++i)
			mem[i] = 0;
		for (int line = 0; line < lines_y; ++line) {
			for (int x = 0; x < kW; x += 8) {
				uint64_t yq = 0;
				for (int b = 0; b < 8; ++b) {
					if (x + b < kW) {
						const uint8_t yv = static_cast<uint8_t>((x + b + line) & 0xff);
						yq |= uint64_t(yv) << (8 * b);
					}
				}
				const size_t a = size_t(line * kYPitchQ + x / 8);
				if (a < mem.size())
					mem[a] = yq;
			}
		}
		const int lines_c = (lines_y + 1) / 2;
		for (int line = 0; line < lines_c; ++line) {
			for (int q = 0; q < kCPitchQ; ++q) {
				const size_t ua = size_t(kUQ + line * kCPitchQ + q);
				const size_t va = size_t(kVQ + line * kCPitchQ + q);
				uint64_t cq = 0;
				for (int b = 0; b < 8; ++b)
					cq |= uint64_t(128) << (8 * b);
				if (ua < mem.size())
					mem[ua] = cq;
				if (va < mem.size())
					mem[va] = cq;
			}
		}
	}

	void ringDoorbell(int bank, uint32_t seq) {
		const uint32_t off = offQ(kDoorbellPhys);
		mem[off] = (uint64_t(doorbellHi(seq, bank)) << 32) | kMagic;
	}

	void ddrStep() {
		top.DDRAM_BUSY = busy > 0 ? 1 : 0;
		top.DDRAM_DOUT_READY = 0;
		if (busy > 0)
			--busy;
		if (rdDelay > 0) {
			--rdDelay;
		} else if (rdDelay == 0 && rdLeft > 0) {
			const uint32_t idx = addrOffQ(rdAddr) + uint32_t(rdIndex);
			top.DDRAM_DOUT = (idx < mem.size()) ? mem[idx] : 0;
			top.DDRAM_DOUT_READY = 1;
			++rdIndex;
			--rdLeft;
			if (rdLeft == 0)
				rdDelay = -1;
			else
				rdDelay = 0;
		}
		if (top.DDRAM_RD && busy == 0 && rdDelay < 0) {
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
			rdIndex = 0;
			rdDelay = 0;
			busy = 1;
		}
		if (top.DDRAM_WE && busy == 0) {
			const uint32_t idx = addrOffQ(top.DDRAM_ADDR);
			if (idx < mem.size())
				mem[idx] = top.DDRAM_DIN;
			busy = 1;
		}
	}

	void tickHold(int x, int y, bool active) {
		ddrStep();
		top.rd_active = active ? 1 : 0;
		top.rd_x = x;
		top.rd_y = y;
		top.vsync_pulse = 0;
		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		top.clk = 1;
		top.clk_ddr = 1;
		top.eval();
	}

	void tickScan() {
		ddrStep();
		const bool active = (hc < kFrameW) && (vc < kFrameH);
		top.rd_active = active ? 1 : 0;
		top.rd_x = (hc < kFrameW) ? hc : (kFrameW - 1);
		top.rd_y = (vc < kFrameH) ? vc : (kFrameH - 1);
		top.vsync_pulse = (hc == 0 && vc == 0) ? 1 : 0;
		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		top.clk = 1;
		top.clk_ddr = 1;
		top.eval();
		++hc;
		if (hc >= kHTotal) {
			hc = 0;
			++vc;
			if (vc >= kFrameH + kVBlank)
				vc = 0;
		}
	}

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 16; ++i)
			tickScan();
		top.reset = 0;
		for (int i = 0; i < 8; ++i)
			tickScan();
	}
};

uint8_t lane_y(uint64_t yq, uint64_t yq_hi, bool hi_valid, int base_x, int lane) {
	const int x = base_x + lane;
#ifdef DDR_FRAME_STORE_FAULT_QWORD_LANE0
	(void)x;
	(void)yq_hi;
	(void)hi_valid;
	return pick8(yq, 0);
#else
	const int base_qw = base_x >> 3;
	const int x_qw = x >> 3;
	if (x_qw != base_qw) {
		if (!hi_valid)
			return 0; // force mismatch if hi missing on straddle
		return pick8(yq_hi, unsigned(x) & 7u);
	}
	return pick8(yq, unsigned(x) & 7u);
#endif
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	for (int i = 1; i < argc; ++i)
		(void)argv[i];

	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 4000; ++i)
		sim.tickScan();

	sim.fillGradient(kFrameH + 4);
	sim.ringDoorbell(0, 1);

	const int maxTicks = kHTotal * (kFrameH + kVBlank) * 12;
	for (int i = 0; i < maxTicks && int(sim.top.frames_done) < 1; ++i)
		sim.tickScan();
	if (int(sim.top.frames_done) < 1) {
		std::cerr << "FAIL: never got frames_done debug=0x" << std::hex
		          << int(sim.top.debug_state) << std::dec << "\n";
		return 1;
	}
	// Extra frames so linebufs warm.
	for (int i = 0; i < kHTotal * (kFrameH + kVBlank) * 2; ++i)
		sim.tickScan();

	const int line_y = 10;

	auto capture_at = [&](int base_x, uint64_t& yq, uint64_t& yq_hi, bool& hi_ok,
	                      uint64_t& uq, uint64_t& vq, int& bx) -> bool {
		yq = yq_hi = uq = vq = 0;
		bx = -1;
		hi_ok = false;
		bool got = false;
		for (int i = 0; i < 2000; ++i)
			sim.tickHold(0, line_y, true);
		for (int i = 0; i < 80; ++i) {
			sim.tickHold(base_x, line_y, true);
			if (sim.top.rd_qword_valid) {
				yq = sim.top.rd_y_qword;
				yq_hi = sim.top.rd_y_qword_hi;
				hi_ok = sim.top.rd_y_hi_valid != 0;
				uq = sim.top.rd_u_qword;
				vq = sim.top.rd_v_qword;
				bx = int(sim.top.rd_src_x_q);
				got = true;
			}
		}
		return got;
	};

	auto sample_rgb = [&](int x, uint8_t& r, uint8_t& g, uint8_t& b) -> bool {
		bool got = false;
		for (int i = 0; i < 60; ++i) {
			sim.tickHold(x, line_y, true);
			if (sim.top.rd_r != 0 || sim.top.rd_g != 0 || sim.top.rd_b != 0) {
				r = sim.top.rd_r;
				g = sim.top.rd_g;
				b = sim.top.rd_b;
				got = true;
			}
		}
		return got;
	};

	auto run_group = [&](const char* name, int base_x, int nlanes, bool expect_straddle) -> int {
		uint64_t yq, yq_hi, uq, vq;
		bool hi_ok;
		int bx;
		if (!capture_at(base_x, yq, yq_hi, hi_ok, uq, vq, bx)) {
			std::cerr << "FAIL " << name << ": no rd_qword_valid\n";
			return 1;
		}
		std::cout << "CASE " << name << "_capture EXECUTED base_x=" << base_x
		          << " rd_src_x_q=" << bx << " hi_valid=" << (hi_ok ? 1 : 0)
		          << " y0=" << int(pick8(yq, 0)) << " y7=" << int(pick8(yq, 7))
		          << " hi0=" << int(pick8(yq_hi, 0)) << "\n";
		if (bx != base_x) {
			std::cerr << "FAIL " << name << ": rd_src_x_q=" << bx << " expected " << base_x << "\n";
			return 1;
		}
		if (expect_straddle && !hi_ok) {
			std::cerr << "FAIL " << name << ": expected rd_y_hi_valid on straddle base\n";
			return 1;
		}
		if (pick8(yq, 0) == pick8(yq, 1) && pick8(yq, 1) == pick8(yq, 7)) {
			std::cerr << "FAIL " << name << ": Y qword not gradient\n";
			return 1;
		}

		int fails = 0;
		for (int lane = 0; lane < nlanes; ++lane) {
			const int x = base_x + lane;
			uint8_t sp_r, sp_g, sp_b;
			if (!sample_rgb(x, sp_r, sp_g, sp_b)) {
				std::cerr << "FAIL " << name << ": no RGB at x=" << x << "\n";
				return 1;
			}
			const uint8_t y = lane_y(yq, yq_hi, hi_ok, bx, lane);
			const uint8_t u = pick8(uq, unsigned(x >> 1) & 7u);
			const uint8_t v = pick8(vq, unsigned(x >> 1) & 7u);
			uint8_t er, eg, eb;
			yuv_to_rgb(y, u, v, er, eg, eb);
			const bool ok = (er == sp_r && eg == sp_g && eb == sp_b);
			std::cout << "CASE " << name << "_lane" << lane << " EXECUTED x=" << x
			          << " y=" << int(y) << " single=" << std::hex << int(sp_r) << int(sp_g)
			          << int(sp_b) << " export=" << int(er) << int(eg) << int(eb) << std::dec
			          << (ok ? " OK\n" : " MISMATCH\n");
			if (!ok)
				++fails;
		}
		return fails;
	};

	// A) aligned free-lunch (no straddle for N=4)
	int fails_a = run_group("aligned", /*base_x=*/16, /*nlanes=*/4, /*straddle=*/false);
	// B) straddle: base_x=23 → lane0 in qw2 byte7, lane1 in qw3 byte0
	int fails_b = run_group("straddle", /*base_x=*/23, /*nlanes=*/2, /*straddle=*/true);

	// Negative: a consumer that ignores hi on straddle must fail (structural red-check)
	{
		uint64_t yq, yq_hi, uq, vq;
		bool hi_ok;
		int bx;
		if (!capture_at(23, yq, yq_hi, hi_ok, uq, vq, bx) || !hi_ok) {
			std::cerr << "FAIL neg_no_hi setup\n";
			return 1;
		}
		const uint8_t y_wrong = pick8(yq, unsigned(24) & 7u); // byte0 of LO, not HI
		const uint8_t y_right = pick8(yq_hi, 0);
		std::cout << "CASE neg_ignore_hi EXECUTED wrong_y=" << int(y_wrong)
		          << " right_y=" << int(y_right) << "\n";
		if (y_wrong == y_right) {
			std::cerr << "FAIL neg_ignore_hi: lo/hi bytes collided — cannot discriminate\n";
			return 1;
		}
		std::cout << "PASS red-check neg_ignore_hi: lo-byte != hi-byte on straddle\n";
	}

#ifdef DDR_FRAME_STORE_FAULT_QWORD_LANE0
	const int fails = fails_a + fails_b;
	if (fails == 0) {
		std::cerr << "FAIL red: FAULT_QWORD_LANE0 unexpectedly matched\n";
		return 1;
	}
	std::cout << "PASS red-check FAULT_QWORD_LANE0 mismatches=" << fails << "\n";
	std::cout << "QWORD_EXPORT_RED_DONE rc=0\n";
	return 0;
#else
	if (fails_a != 0) {
		std::cerr << "FAIL green aligned fails=" << fails_a << "\n";
		return 1;
	}
	if (fails_b != 0) {
		std::cerr << "FAIL green straddle fails=" << fails_b << "\n";
		return 1;
	}
	std::cout << "PASS Y qword gradient discriminator\n";
	std::cout << "PASS green multi-lane free-lunch\n";
	std::cout << "PASS green straddle y_qword_hi\n";
	std::cout << "QWORD_EXPORT_GREEN_DONE fails=0\n";
	return 0;
#endif
}
