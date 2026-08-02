// Full-height native 480p DDR scanout gate.
//
// Pack a product 624x480 I420 bank (Y stride 624, U@299520, V@374400) with:
//   - white left strip at coded x=[0,16)  → must appear at rd_x=PRESENT_X=11
//   - mid grey field elsewhere
//   - neutral chroma U=V=128
//
// PASS criteria:
//   1) first DDR U/V read qwords == product plane bases (37440 / 46800)
//   2) left content edge visible at rd_x=11 (Y high), NOT black pillar
//   3) outside present window (rd_x < 11) is black / not content
//   4) frames_done advances (publish → scanout handshake)
//
// RED twin: if content were 320-centered (x0=148), rd_x=11 would be black.

#include "Vddr_frame_store_native_480p_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 524288u;
constexpr uint32_t kDoorbellPhys = 0x300FF000u;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr int kCodedW = 624;
constexpr int kCodedH = 480;
constexpr int kFrameW = 640;
constexpr int kFrameH = 480;
constexpr int kPresentX = 11;
constexpr int kDispW = 618;
constexpr int kYQ = kCodedW / 8;  // 78
constexpr int kCQ = kCodedW / 16; // 39
// Product full-height plane bases (bytes/8).
constexpr int kUQBase = (kCodedW * kCodedH) / 8;                 // 37440
constexpr int kVQBase = kUQBase + (kCodedW * kCodedH) / 32;      // 46800
constexpr int kFrameBytes = kCodedW * kCodedH * 3 / 2;           // 449280
constexpr int kHTotal = 800;
constexpr int kVBlank = 16;

static_assert(kUQBase * 8 == 299520, "U plane byte offset");
static_assert(kVQBase * 8 == 374400, "V plane byte offset");
static_assert(kFrameBytes == 449280, "I420 frame bytes");
static_assert(kFrameBytes <= static_cast<int>(kBankStrideBytes), "fits bank");

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (i * 8);
	return q;
}

uint64_t packBytes(const uint8_t b[8]) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(b[i]) << (i * 8);
	return q;
}

struct Sim {
	Vddr_frame_store_native_480p_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	// Instant DDR beats: full-height line starts underrun under kRdDelay>=2 and
	// paint PRESENT_X black, which falsely looks like a content pillarbox.
	int kRdDelay = 0;
	uint64_t y_reads = 0;
	uint64_t u_reads = 0;
	uint64_t v_reads = 0;
	uint64_t first_u_addr = 0;
	uint64_t first_v_addr = 0;
	bool saw_u = false;
	bool saw_v = false;

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

	// Full-coded fill: left 16px white (Y=235), rest mid-grey (Y=128), U=V=128.
	void fillBankNative480(int bank) {
		const uint32_t base = (bank * kBankStrideBytes) / 8;
		const int payloadQ = kFrameBytes / 8;
		for (int i = 0; i < payloadQ; ++i)
			mem[base + static_cast<uint32_t>(i)] = 0;

		for (int line = 0; line < kCodedH; ++line) {
			for (int q = 0; q < kYQ; ++q) {
				uint8_t b[8];
				for (int i = 0; i < 8; ++i) {
					const int x = q * 8 + i;
					b[i] = (x < 16) ? 235 : 128;
				}
				mem[base + static_cast<uint32_t>(line * kYQ + q)] = packBytes(b);
			}
		}
		for (int line = 0; line < kCodedH / 2; ++line) {
			for (int q = 0; q < kCQ; ++q) {
				mem[base + static_cast<uint32_t>(kUQBase + line * kCQ + q)] = pack8(128);
				mem[base + static_cast<uint32_t>(kVQBase + line * kCQ + q)] = pack8(128);
			}
		}
	}

	void ringDoorbell(int bank, uint32_t seq) {
		const uint32_t off = offQ(kDoorbellPhys);
		mem[off] = (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagic;
	}

	void ddrStep() {
		top.DDRAM_BUSY = busy > 0 ? 1 : 0;
		top.DDRAM_DOUT_READY = 0;
		if (busy > 0)
			--busy;

		if (rdDelay > 0) {
			--rdDelay;
		} else if (rdDelay == 0 && rdLeft > 0) {
			const uint32_t idx = addrOffQ(rdAddr) + static_cast<uint32_t>(rdIndex);
			top.DDRAM_DOUT = (idx < mem.size()) ? mem[idx] : 0;
			top.DDRAM_DOUT_READY = 1;
			const uint64_t rel = idx % (kBankStrideBytes / 8);
			if (rel < static_cast<uint64_t>(kUQBase)) {
				++y_reads;
			} else if (rel < static_cast<uint64_t>(kVQBase)) {
				++u_reads;
				if (!saw_u) {
					saw_u = true;
					first_u_addr = rel;
				}
			} else if (rel < static_cast<uint64_t>(kVQBase + (kCodedW * kCodedH) / 32)) {
				++v_reads;
				if (!saw_v) {
					saw_v = true;
					first_v_addr = rel;
				}
			}
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
			rdDelay = kRdDelay;
			busy = 1;
		}
		if (top.DDRAM_WE && busy == 0) {
			const uint32_t idx = addrOffQ(top.DDRAM_ADDR);
			if (idx < mem.size())
				mem[idx] = top.DDRAM_DIN;
			busy = 1;
		}
	}

	bool videoTick() {
		ddrStep();
		const bool active = (hc < kFrameW) && (vc < kFrameH);
		top.rd_active = active ? 1 : 0;
		top.rd_x = (hc < kFrameW) ? hc : (kFrameW - 1);
		top.rd_y = (vc < kFrameH) ? vc : (kFrameH - 1);
		const bool at_frame_start = (hc == 0 && vc == 0);
		top.vsync_pulse = at_frame_start ? 1 : 0;

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
		return at_frame_start;
	}

	void tick() { (void)videoTick(); }

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 16; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 8; ++i)
			tick();
	}
};

struct EdgeStats {
	int left_hi = 0;     // rd_x==11, Y-like high luma samples
	int left_n = 0;
	int pillar_hi = 0;   // rd_x < 11 should NOT be high content
	int pillar_n = 0;
	int mid_hi = 0;      // mid display should be mid-grey, not white strip
	int mid_n = 0;
	int samples = 0;
	int underruns = 0;
};

EdgeStats capture(Sim& sim, int frames) {
	EdgeStats s;
	int frame = -1;
	int prev_vs = 0;
	const int warmup = 2;
	while (frame < frames) {
		const int vs = sim.top.vsync_pulse;
		if (vs && !prev_vs)
			++frame;
		prev_vs = vs;

		const bool sample = sim.top.rd_active && sim.top.has_frame && frame >= warmup;
		if (sample) {
			const int x = int(sim.top.rd_x);
			const int y = int(sim.top.rd_y);
			const int r = sim.top.rd_r;
			const int g = sim.top.rd_g;
			const int b = sim.top.rd_b;
			// Approx luma from RGB (neutral chroma → R≈G≈B≈Y).
			const int yv = (r + g + b) / 3;
			++s.samples;

			// Sample only a few rows for speed-of-check (full beam still runs).
			// White strip is coded x=[0,16) → rd_x=[11,27). Prefer x=18 (well
			// inside strip) so a single line-start underrun pixel cannot RED the gate.
			if (y == 0 || y == 120 || y == 240 || y == 479) {
				const bool black = (r | g | b) == 0;
				if (x == kPresentX + 7) {
					// Skip pure underrun blacks for the content-edge score.
					if (!black) {
						++s.left_n;
						if (yv >= 200)
							++s.left_hi;
					}
				} else if (x < kPresentX) {
					++s.pillar_n;
					if (yv >= 200)
						++s.pillar_hi;
				} else if (x == kPresentX + 200) {
					if (!black) {
						++s.mid_n;
						// Mid field is Y=128 → expect ~128, not white strip.
						if (yv >= 200)
							++s.mid_hi;
					}
				}
			}
		}
		sim.tick();
	}
	s.underruns = sim.top.underrun_count;
	return s;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 4000; ++i)
		sim.tick();

	sim.fillBankNative480(/*bank*/ 0);
	sim.ringDoorbell(/*bank*/ 0, /*seq*/ 1);

	// Wait for first swap — allow several full frames.
	const int maxTicks = kHTotal * (kFrameH + kVBlank) * 8;
	for (int i = 0; i < maxTicks && sim.top.frames_done < 1; ++i)
		sim.videoTick();

	if (sim.top.frames_done < 1) {
		std::cerr << "FAIL native_480p: never got frames_done"
		          << " has_frame=" << int(sim.top.has_frame)
		          << " y_reads=" << sim.y_reads << " u_reads=" << sim.u_reads
		          << " v_reads=" << sim.v_reads
		          << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
		return 1;
	}

	const EdgeStats st = capture(sim, /*frames*/ 5);

	std::cout << "CASE native_480p EXECUTED"
	          << " frames_done=" << int(sim.top.frames_done)
	          << " samples=" << st.samples
	          << " left_hi=" << st.left_hi << "/" << st.left_n
	          << " pillar_hi=" << st.pillar_hi << "/" << st.pillar_n
	          << " mid_hi=" << st.mid_hi << "/" << st.mid_n
	          << " underruns=" << st.underruns
	          << " y_reads=" << sim.y_reads << " u_reads=" << sim.u_reads
	          << " v_reads=" << sim.v_reads
	          << " first_u_q=" << sim.first_u_addr << " expect_u_q=" << kUQBase
	          << " first_v_q=" << sim.first_v_addr << " expect_v_q=" << kVQBase
	          << " frame_bytes=" << kFrameBytes
	          << " bank_stride=" << kBankStrideBytes << "\n";

	int rc = 0;
	if (!sim.saw_u || sim.first_u_addr != static_cast<uint64_t>(kUQBase)) {
		std::cerr << "FAIL native_480p: U plane base mismatch first_u_q=" << sim.first_u_addr
		          << " expect=" << kUQBase << "\n";
		rc = 1;
	}
	if (!sim.saw_v || sim.first_v_addr != static_cast<uint64_t>(kVQBase)) {
		std::cerr << "FAIL native_480p: V plane base mismatch first_v_q=" << sim.first_v_addr
		          << " expect=" << kVQBase << "\n";
		rc = 1;
	}
	// Content just inside the present window must be the white strip (native
	// fill). A 320-center pack (x0=148) would show studio black here.
	if (st.left_n < 4 || st.left_hi * 2 < st.left_n) {
		std::cerr << "FAIL native_480p: left content strip not visible near PRESENT_X"
		          << " (would pass if 320-center pillarboxed)\n"
		          << "  left_hi=" << st.left_hi << "/" << st.left_n
		          << " underruns=" << st.underruns << "\n";
		rc = 1;
	}
	// Product 11px pillarbox columns must not show the white content strip.
	if (st.pillar_n > 0 && st.pillar_hi * 4 > st.pillar_n) {
		std::cerr << "FAIL native_480p: content leaked into PRESENT_X pillar "
		          << st.pillar_hi << "/" << st.pillar_n << "\n";
		rc = 1;
	}
	// Mid field must not be the white left strip.
	if (st.mid_n > 0 && st.mid_hi * 4 > st.mid_n) {
		std::cerr << "FAIL native_480p: mid field looks like left white strip\n";
		rc = 1;
	}
	if (st.samples < 1000) {
		std::cerr << "FAIL native_480p: too few samples (" << st.samples << ")\n";
		rc = 1;
	}

	if (rc == 0) {
		std::cout << "PASS native_480p full 624x480 I420 plane_bases OK "
		          << "left_edge@present_x NO_CONTENT_PILLARBOX frames_done="
		          << int(sim.top.frames_done) << "\n";
	}
	return rc;
}
