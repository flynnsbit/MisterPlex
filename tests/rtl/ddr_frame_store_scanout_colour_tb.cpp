// Product-geometry colour / stripe gate for ddr_frame_store (c5382bee class).
//
// Parent HW on c5382bee: freeze fixed; heavy green cast; fixed 1px vertical
// striping; RGB diagonal dots; mean~72.3 max~234. Fingerprint math:
//   pure U=V=0 → R~0 B~0 G~Y+135 → mean(RGB)≈G/3 ≈72 for mid Y  — matches.
//
// Cases (env COLOUR_CASE=...):
//   chroma_zero  — Y ramp, U=V=0     → must REPRO green_cast (silicon class)
//   product_uv   — Y ramp, U=V=128   → greyscale CLEAN + blue probe PASS
//   stride640    — pack Y as 640-stride into 624 reader → stripe/fault REPRO
//
// Pre-register: product_uv CLEAN on c5382bee RTL; chroma_zero REPRO; if
// product_uv is GREEN_CAST then RTL matrix/scanout is the defect.

#include "Vddr_frame_store_scanout_colour_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 524288u;
constexpr uint32_t kDoorbellPhys = 0x300FF000u;
constexpr uint32_t kMagic = 0x504C584Bu;
// Product coded geometry (short height for sim).
constexpr int kCodedW = 624;
constexpr int kCodedH = 48;
constexpr int kFrameW = 640;
constexpr int kPresentX = 11;
constexpr int kDispW = 618;
constexpr int kActH = 40;
constexpr int kYQ = kCodedW / 8;            // 78
constexpr int kCQ = kCodedW / 16;           // 39
constexpr int kUQBase = (kCodedW * kCodedH) / 8;
constexpr int kVQBase = kUQBase + (kCodedW * kCodedH) / 32;
constexpr int kHTotal = 800;
constexpr int kVBlank = 16;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t packBytes(const uint8_t b[8]) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(b[i]) << (i * 8);
	return q;
}

uint64_t pack8(uint8_t v) {
	uint8_t b[8];
	for (int i = 0; i < 8; ++i)
		b[i] = v;
	return packBytes(b);
}

// BT.601 full-range match of ddr_frame_store.sv matrix (for diagnostics only).
void yuv2rgb(uint8_t y, uint8_t u, uint8_t v, int& r, int& g, int& b) {
	const int ys = y;
	const int us = int(u) - 128;
	const int vs = int(v) - 128;
	r = ys + (359 * vs) / 256;
	g = ys - (88 * us) / 256 - (183 * vs) / 256;
	b = ys + (454 * us) / 256;
	r = std::max(0, std::min(255, r));
	g = std::max(0, std::min(255, g));
	b = std::max(0, std::min(255, b));
}

enum class PackMode { ChromaZero, ProductUv, Stride640, ByteSwap64, BarsZero, BarsUv };

const char* packName(PackMode m) {
	switch (m) {
	case PackMode::ChromaZero: return "chroma_zero";
	case PackMode::ProductUv: return "product_uv";
	case PackMode::Stride640: return "stride640";
	case PackMode::ByteSwap64: return "byteswap64";
	case PackMode::BarsZero: return "bars_zero";
	case PackMode::BarsUv: return "bars_uv";
	}
	return "?";
}

uint64_t bswap64_bytes(uint64_t q) {
	uint64_t o = 0;
	for (int i = 0; i < 8; ++i)
		o |= ((q >> (i * 8)) & 0xff) << ((7 - i) * 8);
	return o;
}

struct Sim {
	Vddr_frame_store_scanout_colour_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	int kRdDelay = 4;
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

	void fillBank(int bank, PackMode mode) {
		const uint32_t base = (bank * kBankStrideBytes) / 8;
		// Clear bank payload region.
		for (int i = 0; i < (kCodedW * kCodedH * 3 / 2) / 8; ++i)
			mem[base + i] = 0;

		const bool zeroChroma =
		    (mode == PackMode::ChromaZero || mode == PackMode::BarsZero);
		const uint8_t uFill = zeroChroma ? 0 : 128;
		const uint8_t vFill = zeroChroma ? 0 : 128;

		// Y plane.
		for (int line = 0; line < kCodedH; ++line) {
			if (mode == PackMode::Stride640) {
				// Pack as if line_bytes=320 into a 624-wide reader: each coded line
				// starts 320 bytes later in the writer stream → diagonal edge / stripe.
				// Content: white bar at writer-x [16,48), black elsewhere.
				for (int q = 0; q < kYQ; ++q)
					mem[base + line * kYQ + q] = pack8(16);
				const int writerStride = 320;
				for (int x = 0; x < writerStride; ++x) {
					const int linear = line * writerStride + x;
					const int dstQ = base + (linear / 8);
					const int dstB = linear % 8;
					if (dstQ >= base + static_cast<uint32_t>(kYQ * kCodedH))
						break;
					uint64_t qw = mem[dstQ];
					const uint8_t yv = (x >= 16 && x < 48) ? 220 : 16;
					qw &= ~(uint64_t{0xff} << (dstB * 8));
					qw |= uint64_t{yv} << (dstB * 8);
					mem[dstQ] = qw;
				}
			} else if (mode == PackMode::BarsZero || mode == PackMode::BarsUv) {
				// 1px alternating high-contrast bars (parent "fixed vertical striping" class).
				for (int q = 0; q < kYQ; ++q) {
					uint8_t b[8];
					for (int i = 0; i < 8; ++i) {
						const int x = q * 8 + i;
						b[i] = (x & 1) ? 220 : 16;
					}
					mem[base + line * kYQ + q] = packBytes(b);
				}
			} else {
				// Horizontal ramp Y(x) = 16 + (x % 200).
				for (int q = 0; q < kYQ; ++q) {
					uint8_t b[8];
					for (int i = 0; i < 8; ++i) {
						const int x = q * 8 + i;
						b[i] = static_cast<uint8_t>(16 + (x % 200));
					}
					mem[base + line * kYQ + q] = packBytes(b);
				}
			}
		}
		// Chroma planes (planar I420). Blue probe row0: U=255 V=0 on product_uv.
		for (int line = 0; line < kCodedH / 2; ++line) {
			for (int q = 0; q < kCQ; ++q) {
				uint8_t u = uFill;
				uint8_t v = vFill;
				if (mode == PackMode::ProductUv && line == 0) {
					u = 255;
					v = 0;
				}
				mem[base + kUQBase + line * kCQ + q] = pack8(u);
				mem[base + kVQBase + line * kCQ + q] = pack8(v);
			}
		}
		// Optional: reverse bytes within each 64-bit word (AXI endian class).
		if (mode == PackMode::ByteSwap64) {
			const int yWords = kYQ * kCodedH;
			const int cWords = kCQ * (kCodedH / 2);
			for (int i = 0; i < yWords; ++i)
				mem[base + i] = bswap64_bytes(mem[base + i]);
			for (int i = 0; i < cWords; ++i) {
				mem[base + kUQBase + i] = bswap64_bytes(mem[base + kUQBase + i]);
				mem[base + kVQBase + i] = bswap64_bytes(mem[base + kVQBase + i]);
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

	// Match freeze TB beam: free-run X through blank; vsync at end of blank.
	bool videoTick() {
		ddrStep();
		const bool active = (hc < kFrameW) && (vc < kActH);
		top.rd_active = active ? 1 : 0;
		top.rd_x = (hc < kFrameW) ? hc : (kFrameW - 1);
		top.rd_y = (vc < kActH) ? vc : (kActH - 1);
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
			if (vc >= kActH + kVBlank)
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

struct Metrics {
	double mean_r = 0, mean_g = 0, mean_b = 0;
	int max_rgb = 0;
	int samples = 0;
	int green_cast_votes = 0;
	int stripe_edges = 0;
	int stripe_pairs = 0;
	int blue_probe_ok = 0;
	int blue_probe_n = 0;
	int grey_ok = 0;
	int grey_n = 0;
	int underruns = 0;
};

Metrics capture(Sim& sim, int frames) {
	Metrics m;
	int last_g = -1;
	const int warmup = 2;
	int frame = -1;
	int prev_vs = 0;
	while (frame < frames) {
		const int vs = sim.top.vsync_pulse;
		if (vs && !prev_vs)
			++frame;
		prev_vs = vs;

		const bool sample = sim.top.rd_active && sim.top.has_frame && frame >= warmup &&
		                    int(sim.top.rd_x) >= kPresentX &&
		                    int(sim.top.rd_x) < kPresentX + kDispW &&
		                    int(sim.top.rd_y) < kActH;
		if (sample) {
			const int r = sim.top.rd_r;
			const int g = sim.top.rd_g;
			const int b = sim.top.rd_b;
			m.mean_r += r;
			m.mean_g += g;
			m.mean_b += b;
			m.max_rgb = std::max(m.max_rgb, std::max(r, std::max(g, b)));
			++m.samples;
			// Green-cast vote: G dominates R and B by ≥30 (U=V=0 class).
			if (g >= r + 30 && g >= b + 30)
				++m.green_cast_votes;
			// Vertical stripe energy: adjacent G differ by ≥40 inside active.
			if (last_g >= 0) {
				++m.stripe_pairs;
				if (std::abs(g - last_g) >= 40)
					++m.stripe_edges;
			}
			last_g = g;
			// Reset stripe adjacency at line wrap.
			if (int(sim.top.rd_x) == kPresentX + kDispW - 1)
				last_g = -1;

			const bool black = (r | g | b) == 0;
			// Blue probe: first chroma row (display y 0..1) with product_uv U=255 V=0
			// expect B dominant, R low. Score only non-miss pixels (underrun→black).
			if (!black && int(sim.top.rd_y) <= 1) {
				++m.blue_probe_n;
				if (b >= 180 && r <= 60)
					++m.blue_probe_ok;
			} else if (!black && int(sim.top.rd_y) >= 4) {
				// Neutral chroma rows: greyscale |R-G| and |G-B| small.
				++m.grey_n;
				if (std::abs(r - g) <= 12 && std::abs(g - b) <= 12)
					++m.grey_ok;
			}
		}
		sim.tick();
	}
	if (m.samples > 0) {
		m.mean_r /= m.samples;
		m.mean_g /= m.samples;
		m.mean_b /= m.samples;
	}
	m.underruns = sim.top.underrun_count;
	return m;
}

int runCase(PackMode mode) {
	Sim sim;
	sim.resetCore();
	// Idle polls so doorbell_primed rises before first token (IGNORE_STALE path).
	for (int i = 0; i < 4000; ++i)
		sim.tick();

	int bank = 0;
	uint32_t seq = 1;
	sim.fillBank(bank, mode);
	sim.ringDoorbell(bank, seq);

	// Wait for first vsync swap (frames_done) — same contract as freeze TB.
	for (int i = 0; i < 200000 && sim.top.frames_done < 1; ++i)
		sim.videoTick();
	if (sim.top.frames_done < 1) {
		std::cerr << "FAIL " << packName(mode) << ": never got first frames_done"
		          << " has_frame=" << int(sim.top.has_frame)
		          << " swap_pending=" << int(sim.top.swap_pending)
		          << " y_reads=" << sim.y_reads << " u_reads=" << sim.u_reads
		          << " v_reads=" << sim.v_reads
		          << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
		return 1;
	}

	// Second bank for swap stress.
	if (!sim.top.swap_pending) {
		bank ^= 1;
		++seq;
		sim.fillBank(bank, mode);
		sim.ringDoorbell(bank, seq);
		for (int i = 0; i < kHTotal * 4; ++i)
			sim.videoTick();
	}

	const Metrics m = capture(sim, /*frames*/ 6);
	const double green_frac =
	    m.samples ? double(m.green_cast_votes) / double(m.samples) : 0.0;
	const double stripe_frac =
	    m.stripe_pairs ? double(m.stripe_edges) / double(m.stripe_pairs) : 0.0;
	const bool green_cast = green_frac >= 0.50 && m.mean_g >= m.mean_r + 25.0 &&
	                        m.mean_g >= m.mean_b + 25.0;
	// Parent mean~72 with pure green mono: mean_rgb = (mr+mg+mb)/3
	const double mean_rgb = (m.mean_r + m.mean_g + m.mean_b) / 3.0;

	std::cout << "CASE " << packName(mode) << " EXECUTED"
	          << " samples=" << m.samples
	          << " mean_r=" << m.mean_r << " mean_g=" << m.mean_g << " mean_b=" << m.mean_b
	          << " mean_rgb=" << mean_rgb << " max=" << m.max_rgb
	          << " green_frac=" << green_frac << " stripe_frac=" << stripe_frac
	          << " green_cast=" << (green_cast ? 1 : 0)
	          << " blue_ok=" << m.blue_probe_ok << "/" << m.blue_probe_n
	          << " grey_ok=" << m.grey_ok << "/" << m.grey_n
	          << " underruns=" << m.underruns
	          << " y_reads=" << sim.y_reads << " u_reads=" << sim.u_reads
	          << " v_reads=" << sim.v_reads
	          << " first_u_q=" << sim.first_u_addr << " expect_u_q=" << kUQBase
	          << " first_v_q=" << sim.first_v_addr << " expect_v_q=" << kVQBase
	          << " frames_done=" << int(sim.top.frames_done) << "\n";

	// Plane base check (must match host layout contract).
	if (sim.saw_u && sim.first_u_addr != static_cast<uint64_t>(kUQBase)) {
		std::cerr << "FAIL " << packName(mode) << ": U plane base wrong first_u_q="
		          << sim.first_u_addr << " expect=" << kUQBase << "\n";
		return 1;
	}
	if (sim.saw_v && sim.first_v_addr != static_cast<uint64_t>(kVQBase)) {
		std::cerr << "FAIL " << packName(mode) << ": V plane base wrong first_v_q="
		          << sim.first_v_addr << " expect=" << kVQBase << "\n";
		return 1;
	}
	if (sim.u_reads == 0 || sim.v_reads == 0) {
		std::cerr << "FAIL " << packName(mode) << ": chroma never fetched u_reads="
		          << sim.u_reads << " v_reads=" << sim.v_reads << "\n";
		return 1;
	}
	if (m.samples < 100) {
		std::cerr << "FAIL " << packName(mode) << ": too few samples " << m.samples << "\n";
		return 1;
	}

	if (mode == PackMode::ChromaZero || mode == PackMode::BarsZero) {
		if (!green_cast) {
			std::cerr << "FAIL " << packName(mode)
			          << ": expected REPRO green_cast (silicon class)\n";
			return 1;
		}
		// High-contrast Y under dead chroma must show vertical stripe energy.
		if (mode == PackMode::BarsZero && stripe_frac < 0.40) {
			std::cerr << "FAIL bars_zero: expected high stripe_frac got " << stripe_frac
			          << "\n";
			return 1;
		}
		std::cout << "REPRO_OK " << packName(mode) << " green_cast=1 mean_rgb=" << mean_rgb
		          << " stripe_frac=" << stripe_frac
		          << " (c5382bee fingerprint class)\n";
		return 0;
	}

	if (mode == PackMode::BarsUv) {
		// Correct chroma + 1px bars: greyscale bars, high stripe, no green_cast.
		if (green_cast) {
			std::cerr << "FAIL bars_uv: unexpected green_cast\n";
			return 1;
		}
		if (stripe_frac < 0.40) {
			std::cerr << "FAIL bars_uv: expected high stripe_frac got " << stripe_frac
			          << "\n";
			return 1;
		}
		if (m.grey_n > 50 && double(m.grey_ok) / m.grey_n < 0.85) {
			std::cerr << "FAIL bars_uv: bars not greyscale grey_ok=" << m.grey_ok << "/"
			          << m.grey_n << "\n";
			return 1;
		}
		std::cout << "PASS bars_uv CLEAN green_cast=0 stripe_frac=" << stripe_frac
		          << " grey_ok=" << m.grey_ok << "/" << m.grey_n << "\n";
		return 0;
	}

	if (mode == PackMode::Stride640 || mode == PackMode::ByteSwap64) {
		// Discriminator packs must not match product_uv CLEAN signature.
		const bool dirty = green_cast || stripe_frac >= 0.08 ||
		                   (m.grey_n > 100 && double(m.grey_ok) / m.grey_n < 0.90) ||
		                   (mode == PackMode::Stride640 && m.max_rgb >= 200) ||
		                   (mode == PackMode::ByteSwap64 && stripe_frac >= 0.05);
		const bool product_like =
		    !green_cast && stripe_frac < 0.05 && m.grey_n > 100 &&
		    double(m.grey_ok) / m.grey_n >= 0.95 &&
		    (mode != PackMode::Stride640 || m.max_rgb < 180);
		if (product_like || !dirty) {
			std::cerr << "FAIL " << packName(mode)
			          << ": expected REPRO dirty; product_like=" << product_like
			          << " dirty=" << dirty << " stripe_frac=" << stripe_frac << "\n";
			return 1;
		}
		std::cout << "REPRO_OK " << packName(mode) << " dirty=1 stripe_frac=" << stripe_frac
		          << " green_cast=" << (green_cast ? 1 : 0) << " max=" << m.max_rgb << "\n";
		return 0;
	}

	// product_uv: must NOT green-cast; neutral rows greyscale; blue probe on y0.
	if (green_cast) {
		std::cerr << "FAIL product_uv: unexpected GREEN_CAST on c5382bee RTL "
		          << "mean_r/g/b=" << m.mean_r << "/" << m.mean_g << "/" << m.mean_b << "\n";
		return 1;
	}
	if (m.grey_n > 50 && double(m.grey_ok) / m.grey_n < 0.85) {
		std::cerr << "FAIL product_uv: neutral chroma not greyscale grey_ok="
		          << m.grey_ok << "/" << m.grey_n << "\n";
		return 1;
	}
	if (m.blue_probe_n < 20) {
		std::cerr << "FAIL product_uv: blue probe unscored (all miss?) n="
		          << m.blue_probe_n << "\n";
		return 1;
	}
	if (double(m.blue_probe_ok) / m.blue_probe_n < 0.50) {
		std::cerr << "FAIL product_uv: blue probe failed ok=" << m.blue_probe_ok
		          << "/" << m.blue_probe_n << "\n";
		return 1;
	}
	// Stripe: ramp has legitimate |ΔG| from Y ramp (~1 per px) — threshold 40
	// should only fire on true striping. Allow a little noise.
	if (stripe_frac >= 0.20) {
		std::cerr << "FAIL product_uv: vertical stripe_frac=" << stripe_frac
		          << " too high on clean pack\n";
		return 1;
	}
	std::cout << "PASS product_uv CLEAN green_cast=0 stripe_frac=" << stripe_frac
	          << " blue_ok=" << m.blue_probe_ok << "/" << m.blue_probe_n
	          << " grey_ok=" << m.grey_ok << "/" << m.grey_n << "\n";
	return 0;
}

}  // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* env = std::getenv("COLOUR_CASE");
	std::string which = env ? env : "all";

	// Reference fingerprint (no DUT): U=V=0 mid-Y → mean_rgb class.
	{
		int r, g, b;
		yuv2rgb(128, 0, 0, r, g, b);
		std::cout << "REF yuv2rgb Y128 U0 V0 -> " << r << "/" << g << "/" << b
		          << " mean=" << (r + g + b) / 3.0
		          << " (silicon mean~72 class if mono-green)\n";
		yuv2rgb(128, 128, 128, r, g, b);
		std::cout << "REF yuv2rgb Y128 U128 V128 -> " << r << "/" << g << "/" << b << "\n";
		yuv2rgb(128, 255, 0, r, g, b);
		std::cout << "REF yuv2rgb Y128 U255 V0 -> " << r << "/" << g << "/" << b << "\n";
	}

	int rc = 0;
	if (which == "all" || which == "chroma_zero")
		rc |= runCase(PackMode::ChromaZero);
	if (which == "all" || which == "product_uv")
		rc |= runCase(PackMode::ProductUv);
	if (which == "all" || which == "stride640")
		rc |= runCase(PackMode::Stride640);
	if (which == "all" || which == "bars_zero")
		rc |= runCase(PackMode::BarsZero);
	if (which == "all" || which == "bars_uv")
		rc |= runCase(PackMode::BarsUv);
	if (which == "byteswap64")
		rc |= runCase(PackMode::ByteSwap64);
	if (which != "all" && which != "chroma_zero" && which != "product_uv" &&
	    which != "stride640" && which != "byteswap64" && which != "bars_zero" &&
	    which != "bars_uv") {
		std::cerr << "FAIL unknown COLOUR_CASE=" << which << "\n";
		return 2;
	}
	return rc;
}
