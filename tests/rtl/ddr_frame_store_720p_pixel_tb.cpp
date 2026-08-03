// Full-pixel Option-C 720p READ proof for ddr_frame_store (w-scaler).
//
// GREEN cases (PIXEL_CASE=...):
//   full_grey   — Y=unique(x,y), U=V=128; every active RGB == (Y,Y,Y)
//   full_chroma — unique Y/U/V; every RGB matches BT.601 matrix (exact RTL form)
//   bank_swap   — bank0 pattern A on glass while bank1 is overwritten mid-scan;
//                 must stay A until doorbell+vsync promotes B
//
// RED / negative (must FAIL the green checker):
//   wrong_stride — pack Y with stride 1296 while geom y_stride=1280
//                  (off-by-16 B/line → diagonal shear). A naive always-PASS
//                  checker would green this; we require mismatch rate high.
//   half_chroma  — U plane shifted by one chroma line (half-line class)
//
// Geometry pins (must match w-mem Option-C + host kPlex720p*):
//   base 0x30180000, bank stride 0x180000, doorbell 0x3047F000
//   y_stride=1280, chroma_stride=640, U@921600 B, V@1152000 B
//
// Soft-skip≠PASS. true rc direct.

#include "Vddr_frame_store_720p_pixel_tb.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

// Option-C (w-mem / parent-verified)
constexpr uint32_t kOptcBase = 0x30180000u;
constexpr uint32_t kOptcBankStride = 0x180000u;
constexpr uint32_t kOptcDoorbell = 0x3047F000u;
constexpr uint32_t kMagicK = 0x504C584Bu;

constexpr int kW = 1280;
constexpr int kH = 720;
constexpr int kYStride = 1280;
constexpr int kCStride = 640;
constexpr int kYPitchQ = kYStride / 8; // 160
constexpr int kCPitchQ = kCStride / 8; // 80
constexpr int kUQ = (kYStride * kH) / 8;           // 115200
constexpr int kCQ = (kCStride * (kH / 2)) / 8;     // 28800
constexpr int kVQ = kUQ + kCQ;                     // 144000
constexpr int kFrameBytes = kW * kH * 3 / 2;       // 1382400

// Scan window: full width every line; full height (parent: every pixel).
constexpr int kActW = kW;
constexpr int kActH = kH;
// Long H blank so DDR can refill 160-qword luma lines before the next active.
constexpr int kHTotal = 2400;
constexpr int kVBlank = 80;
constexpr int kRdDelay = 1;

// Mem spans base → past doorbell (Option-C control page).
constexpr size_t kMemBytes = 0x00300000u; // 3 MiB covers 2×0x180000 + doorbell page
constexpr size_t kMemQ = kMemBytes / 8;

static_assert(kUQ == 115200, "U base qw");
static_assert(kVQ == 144000, "V base qw");
static_assert(kFrameBytes == 1382400, "I420 bytes");
static_assert(kW % 8 == 0, "luma qword align");
static_assert(kW % 2 == 0, "chroma subsample");
// w-clock PPC free-lunch: 1280 divisible by 1,2,4 (not by 3); 1650%4==2 noted by parent.
static_assert(kW % 2 == 0 && kW % 4 == 0, "PPC 2/4 aligned DE width");

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t packBytes(const uint8_t b[8]) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(b[i]) << (i * 8);
	return q;
}

// Exact match of ddr_frame_store.sv: (y<<8 ± coeff*chroma)>>8 then sat8.
void yuv2rgb_rtl(uint8_t y, uint8_t u, uint8_t v, int& r, int& g, int& b) {
	const int ys = static_cast<int>(y);
	const int us = static_cast<int>(u) - 128;
	const int vs = static_cast<int>(v) - 128;
	const int r_w = (ys << 8) + 359 * vs;
	const int g_w = (ys << 8) - 88 * us - 183 * vs;
	const int b_w = (ys << 8) + 454 * us;
	r = r_w >> 8;
	g = g_w >> 8;
	b = b_w >> 8;
	r = std::max(0, std::min(255, r));
	g = std::max(0, std::min(255, g));
	b = std::max(0, std::min(255, b));
}

// Unique, deterministic I420 samples (not constant planes).
uint8_t yAt(int x, int y, int phase) {
	// phase distinguishes bank A/B patterns for swap test.
	return static_cast<uint8_t>((x * 3 + y * 17 + phase * 41) & 0xFF);
}
uint8_t uAt(int cx, int cy, int phase) {
	return static_cast<uint8_t>(64 + ((cx + cy * 7 + phase * 3) & 0x7F));
}
uint8_t vAt(int cx, int cy, int phase) {
	return static_cast<uint8_t>(64 + ((cx * 5 + cy + phase * 11) & 0x7F));
}

enum class Case {
	FullGrey,
	FullChroma,
	BankSwap,
	WrongStride, // negative — expect high mismatch
	HalfChroma   // negative — U plane +1 chroma line
};

const char* caseName(Case c) {
	switch (c) {
	case Case::FullGrey: return "full_grey";
	case Case::FullChroma: return "full_chroma";
	case Case::BankSwap: return "bank_swap";
	case Case::WrongStride: return "wrong_stride";
	case Case::HalfChroma: return "half_chroma";
	}
	return "?";
}

struct Sim {
	Vddr_frame_store_720p_pixel_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	uint64_t y_reads = 0;
	uint64_t u_reads = 0;
	uint64_t v_reads = 0;
	uint64_t first_y_phys = 0;
	uint64_t first_u_q = 0;
	uint64_t first_v_q = 0;
	bool saw_y = false;
	bool saw_u = false;
	bool saw_v = false;

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

	void arm720Geom() {
		top.geom_enable = 1;
		top.rt_coded_w = kW;
		top.rt_coded_h = kH;
		top.rt_y_stride = kYStride;
		top.rt_chroma_stride = kCStride;
		top.rt_display_w = kW;
		top.rt_display_h = kH;
		top.rt_present_x = 0;
		top.rt_present_y = 0;
		top.rt_crop_left = 0;
		top.rt_crop_top = 0;
	}

	uint32_t addrOffQ(uint32_t addr) const {
		// DDRAM_ADDR is qword address = phys>>3
		return addr - (kOptcBase >> 3);
	}

	void clearStats() {
		y_reads = u_reads = v_reads = 0;
		first_y_phys = first_u_q = first_v_q = 0;
		saw_y = saw_u = saw_v = false;
	}

	void fillBank(int bank, int phase, Case c) {
		const uint32_t bankBaseQ = (static_cast<uint32_t>(bank) * kOptcBankStride) / 8;
		// Clear plane region only (not whole mem — doorbell lives above banks).
		const int planeQ = kFrameBytes / 8;
		for (int i = 0; i < planeQ; ++i) {
			const size_t a = bankBaseQ + static_cast<size_t>(i);
			if (a < mem.size())
				mem[a] = 0;
		}

		const int packYStride = (c == Case::WrongStride) ? 1296 : kYStride;
		const int packYPitchQ = packYStride / 8;

		// Y plane
		for (int y = 0; y < kH; ++y) {
			for (int x = 0; x < kW; x += 8) {
				uint8_t b[8];
				for (int i = 0; i < 8; ++i)
					b[i] = yAt(x + i, y, phase);
				const int linear = y * packYStride + x;
				const size_t a = bankBaseQ + static_cast<size_t>(linear / 8);
				if (a < mem.size())
					mem[a] = packBytes(b);
			}
		}

		// U/V planar. half_chroma: store U at base+one chroma line.
		const int uShiftLines = (c == Case::HalfChroma) ? 1 : 0;
		for (int cy = 0; cy < kH / 2; ++cy) {
			for (int cx = 0; cx < kW / 2; cx += 8) {
				uint8_t ub[8], vb[8];
				for (int i = 0; i < 8; ++i) {
					// wrong_stride uses grey chroma so failures are pure pitch shear.
					const bool grey = (c == Case::FullGrey || c == Case::WrongStride);
					ub[i] = grey ? 128 : uAt(cx + i, cy, phase);
					vb[i] = grey ? 128 : vAt(cx + i, cy, phase);
				}
				const int uLine = cy + uShiftLines;
				if (uLine < kH / 2) {
					const size_t ua =
					    bankBaseQ + static_cast<size_t>(kUQ + uLine * kCPitchQ + cx / 8);
					if (ua < mem.size())
						mem[ua] = packBytes(ub);
				}
				const size_t va =
				    bankBaseQ + static_cast<size_t>(kVQ + cy * kCPitchQ + cx / 8);
				if (va < mem.size())
					mem[va] = packBytes(vb);
			}
		}
		(void)packYPitchQ;
	}

	void ringDoorbell(int bank, uint32_t seq) {
		const uint32_t off = (kOptcDoorbell - kOptcBase) / 8;
		if (off >= mem.size()) {
			std::cerr << "FAIL doorbell off OOR\n";
			return;
		}
		mem[off] = (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagicK;
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
			// Classify relative to bank0 payload (bank1 offsets handled via abs).
			const uint64_t abs_q = static_cast<uint64_t>(rdAddr);
			const uint64_t base_q = kOptcBase >> 3;
			if (abs_q >= base_q) {
				uint64_t rel = abs_q - base_q;
				// Map into bank-local plane index.
				if (rel >= (kOptcBankStride / 8))
					rel -= (kOptcBankStride / 8);
				if (rel < static_cast<uint64_t>(kUQ)) {
					++y_reads;
					if (!saw_y) {
						saw_y = true;
						first_y_phys = static_cast<uint64_t>(rdAddr) << 3;
					}
				} else if (rel < static_cast<uint64_t>(kVQ)) {
					++u_reads;
					if (!saw_u) {
						saw_u = true;
						first_u_q = rel;
					}
				} else if (rel < static_cast<uint64_t>(kVQ + kCQ)) {
					++v_reads;
					if (!saw_v) {
						saw_v = true;
						first_v_q = rel;
					}
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

	void tick() {
		ddrStep();
		const bool active = (hc < kActW) && (vc < kActH);
		top.rd_active = active ? 1 : 0;
		top.rd_x = (hc < kActW) ? hc : (kActW - 1);
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
	}

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 32; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 16; ++i)
			tick();
	}
};

struct PixExpect {
	int x = 0, y = 0;
	int r = 0, g = 0, b = 0;
	bool valid = false;
};

void expectAt(int x, int y, int phase, Case c, int& r, int& g, int& b) {
	const uint8_t Y = yAt(x, y, phase);
	if (c == Case::FullGrey) {
		r = g = b = Y;
		return;
	}
	const int cx = x / 2;
	const int cy = y / 2;
	// half_chroma shifts stored U; model expected *correct* packing for green
	// checker — negatives intentionally diverge.
	const uint8_t U = uAt(cx, cy, phase);
	const uint8_t V = vAt(cx, cy, phase);
	yuv2rgb_rtl(Y, U, V, r, g, b);
}

struct Score {
	uint64_t samples = 0;
	uint64_t match = 0;
	uint64_t mismatch = 0;
	uint64_t black = 0;
	int first_mx = -1, first_my = -1;
	int first_got_r = 0, first_exp_r = 0;
	// Edge probes
	uint64_t edge_n = 0, edge_ok = 0;
	uint64_t last_q_n = 0, last_q_ok = 0; // x in [1272,1279]
	uint64_t odd_y_n = 0, odd_y_ok = 0;
};

Score scoreFrame(Sim& sim, int phase, Case c, int pipe_delay, int score_frames) {
	// score_frames = number of complete frames to accumulate after warmup_frames.
	constexpr int warmup_frames = 1;
	Score s;
	std::array<PixExpect, 8> pipe{};
	int frame = -1;
	int prev_vs = 0;
	const int stop_at = warmup_frames + score_frames;
	while (frame < stop_at) {
		const int vs = sim.top.vsync_pulse;
		if (vs && !prev_vs)
			++frame;
		prev_vs = vs;

		const int x = int(sim.top.rd_x);
		const int y = int(sim.top.rd_y);
		const bool beam = sim.top.rd_active && sim.top.has_frame && frame >= warmup_frames &&
		                  frame < stop_at && x < kActW && y < kActH;

		// Push expected for this beam into delay line.
		for (int i = int(pipe.size()) - 1; i > 0; --i)
			pipe[static_cast<size_t>(i)] = pipe[static_cast<size_t>(i - 1)];
		if (beam) {
			PixExpect e;
			e.x = x;
			e.y = y;
			expectAt(x, y, phase, c, e.r, e.g, e.b);
			e.valid = true;
			pipe[0] = e;
		} else {
			pipe[0] = {};
		}

		const int di = std::min(pipe_delay, int(pipe.size()) - 1);
		const PixExpect& e = pipe[static_cast<size_t>(di)];
		if (e.valid && sim.top.has_frame) {
			const int r = sim.top.rd_r;
			const int g = sim.top.rd_g;
			const int b = sim.top.rd_b;
			++s.samples;
			if ((r | g | b) == 0)
				++s.black;
			const bool ok = (r == e.r && g == e.g && b == e.b);
			if (ok)
				++s.match;
			else {
				++s.mismatch;
				if (s.first_mx < 0) {
					s.first_mx = e.x;
					s.first_my = e.y;
					s.first_got_r = r;
					s.first_exp_r = e.r;
				}
			}
			// Edge classes
			if (e.x == 0 || e.x == kW - 1 || e.y == 0 || e.y == kH - 1) {
				++s.edge_n;
				if (ok)
					++s.edge_ok;
			}
			if (e.x >= 1272 && e.x <= 1279) {
				++s.last_q_n;
				if (ok)
					++s.last_q_ok;
			}
			if (e.y & 1) {
				++s.odd_y_n;
				if (ok)
					++s.odd_y_ok;
			}
		}
		sim.tick();
	}
	return s;
}

int pickPipeDelay(Sim& sim, int phase, Case c) {
	// Score delays 1..4 over one full frame each; pick max match count.
	int best_d = 2;
	uint64_t best_m = 0;
	for (int d = 1; d <= 4; ++d) {
		const Score sc = scoreFrame(sim, phase, c, d, /*score_frames*/ 1);
		std::cout << "PIPE_PROBE d=" << d << " samples=" << sc.samples
		          << " match=" << sc.match << " rate="
		          << (sc.samples ? double(sc.match) / double(sc.samples) : 0.0) << "\n";
		if (sc.match > best_m) {
			best_m = sc.match;
			best_d = d;
		}
	}
	return best_d;
}

int runGreen(Case c) {
	Sim sim;
	sim.resetCore();
	sim.arm720Geom();
	// Let geom CDC settle + doorbell poll prime.
	for (int i = 0; i < 8000; ++i)
		sim.tick();

	const int phaseA = 1;
	const int phaseB = 7;
	sim.clearStats();
	sim.fillBank(/*bank*/ 0, phaseA, c == Case::BankSwap ? Case::FullChroma : c);
	sim.ringDoorbell(0, /*seq*/ 1);

	// Wait until frames_done advances.
	bool got = false;
	for (int i = 0; i < kHTotal * (kActH + kVBlank) * 40; ++i) {
		sim.tick();
		if (sim.top.frames_done >= 1 && sim.top.has_frame) {
			got = true;
			break;
		}
	}
	if (!got) {
		std::cerr << "FAIL " << caseName(c) << ": never got frames_done"
		          << " has_frame=" << int(sim.top.has_frame)
		          << " y_reads=" << sim.y_reads << " u_reads=" << sim.u_reads
		          << " v_reads=" << sim.v_reads
		          << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
		return 1;
	}

	// Bank map proof: first Y must land on Option-C base.
	if (sim.saw_y && sim.first_y_phys != kOptcBase) {
		std::cerr << "FAIL " << caseName(c) << ": first Y phys=0x" << std::hex
		          << sim.first_y_phys << " expect 0x" << kOptcBase << std::dec << "\n";
		return 1;
	}
	if (sim.saw_u && sim.first_u_q != static_cast<uint64_t>(kUQ)) {
		std::cerr << "FAIL " << caseName(c) << ": first U qw=" << sim.first_u_q
		          << " expect " << kUQ << "\n";
		return 1;
	}
	if (sim.saw_v && sim.first_v_q != static_cast<uint64_t>(kVQ)) {
		std::cerr << "FAIL " << caseName(c) << ": first V qw=" << sim.first_v_q
		          << " expect " << kVQ << "\n";
		return 1;
	}

	const Case scoreCase = (c == Case::BankSwap) ? Case::FullChroma : c;
	const int pipe = pickPipeDelay(sim, phaseA, scoreCase);

	// Bank-swap: while displaying A, poison bank1 with B (no doorbell yet).
	if (c == Case::BankSwap) {
		sim.fillBank(/*bank*/ 1, phaseB, Case::FullChroma);
		// Mid-scan frames must still match A.
		const Score mid = scoreFrame(sim, phaseA, Case::FullChroma, pipe, /*frames*/ 2);
		const double mid_ok =
		    mid.samples ? double(mid.match) / double(mid.samples) : 0.0;
		std::cout << "CASE bank_swap MID_A EXECUTED pipe=" << pipe
		          << " samples=" << mid.samples << " match=" << mid.match
		          << " mismatch=" << mid.mismatch << " black=" << mid.black
		          << " rate=" << mid_ok << "\n";
		if (mid.samples < 10000 || mid_ok < 0.995) {
			std::cerr << "FAIL bank_swap: tore into bank1 while disp=A rate=" << mid_ok
			          << " first_m=" << mid.first_mx << "," << mid.first_my
			          << " got_r=" << mid.first_got_r << " exp_r=" << mid.first_exp_r
			          << "\n";
			return 1;
		}
		// Promote B.
		sim.ringDoorbell(1, /*seq*/ 2);
		// Wait swap
		for (int i = 0; i < kHTotal * (kActH + kVBlank) * 8; ++i) {
			sim.tick();
			if (sim.top.frames_done >= 2)
				break;
		}
		const Score after = scoreFrame(sim, phaseB, Case::FullChroma, pipe, /*frames*/ 2);
		const double after_ok =
		    after.samples ? double(after.match) / double(after.samples) : 0.0;
		std::cout << "CASE bank_swap AFTER_B EXECUTED samples=" << after.samples
		          << " match=" << after.match << " mismatch=" << after.mismatch
		          << " rate=" << after_ok << " frames_done=" << int(sim.top.frames_done)
		          << "\n";
		if (after.samples < 10000 || after_ok < 0.995) {
			std::cerr << "FAIL bank_swap: post-swap B not clean rate=" << after_ok << "\n";
			return 1;
		}
		std::cout << "PASS bank_swap no-tear A-hold + clean B "
		          << "mid_rate=" << mid_ok << " after_rate=" << after_ok << "\n";
		return 0;
	}

	// Full-frame pixel check (2 frames after pipe lock).
	const Score sc = scoreFrame(sim, phaseA, scoreCase, pipe, /*frames*/ 2);
	const double ok = sc.samples ? double(sc.match) / double(sc.samples) : 0.0;
	const double black_frac = sc.samples ? double(sc.black) / double(sc.samples) : 1.0;

	std::cout << "CASE " << caseName(c) << " EXECUTED pipe=" << pipe
	          << " samples=" << sc.samples << " match=" << sc.match
	          << " mismatch=" << sc.mismatch << " black=" << sc.black
	          << " rate=" << ok << " black_frac=" << black_frac
	          << " edge_ok=" << sc.edge_ok << "/" << sc.edge_n
	          << " last_q_ok=" << sc.last_q_ok << "/" << sc.last_q_n
	          << " odd_y_ok=" << sc.odd_y_ok << "/" << sc.odd_y_n
	          << " first_y_phys=0x" << std::hex << sim.first_y_phys << std::dec
	          << " first_u_q=" << sim.first_u_q << " first_v_q=" << sim.first_v_q
	          << " y_reads=" << sim.y_reads << " u_reads=" << sim.u_reads
	          << " v_reads=" << sim.v_reads
	          << " frames_done=" << int(sim.top.frames_done)
	          << " underrun=" << int(sim.top.underrun_count) << "\n";

	// Every pixel: require ≥99.5% exact match and full coverage.
	// 1280*720 = 921600; two frames → ~1.84M if no miss. Allow some blank on
	// first linebuf fill but demand huge sample count.
	if (sc.samples < 500000) {
		std::cerr << "FAIL " << caseName(c) << ": undersampled " << sc.samples
		          << " (need full-frame coverage)\n";
		return 1;
	}
	if (ok < 0.995) {
		std::cerr << "FAIL " << caseName(c) << ": pixel match rate " << ok
		          << " first_mismatch x,y=" << sc.first_mx << "," << sc.first_my
		          << " got_r=" << sc.first_got_r << " exp_r=" << sc.first_exp_r << "\n";
		return 1;
	}
	if (sc.last_q_n < 100 || double(sc.last_q_ok) / double(sc.last_q_n) < 0.99) {
		std::cerr << "FAIL " << caseName(c) << ": last-qword columns weak ok="
		          << sc.last_q_ok << "/" << sc.last_q_n << "\n";
		return 1;
	}
	if (sc.odd_y_n < 100 || double(sc.odd_y_ok) / double(sc.odd_y_n) < 0.99) {
		std::cerr << "FAIL " << caseName(c) << ": odd-line chroma weak ok="
		          << sc.odd_y_ok << "/" << sc.odd_y_n << "\n";
		return 1;
	}
	if (black_frac > 0.05) {
		std::cerr << "FAIL " << caseName(c) << ": excessive black_frac=" << black_frac
		          << " (linebuf miss)\n";
		return 1;
	}

	std::cout << "PASS " << caseName(c) << " full-pixel rate=" << ok
	          << " last_q=" << sc.last_q_ok << "/" << sc.last_q_n
	          << " odd_y=" << sc.odd_y_ok << "/" << sc.odd_y_n << "\n";
	return 0;
}

// Negative: green checker must go red (high mismatch).
int runNegative(Case c) {
	Sim sim;
	sim.resetCore();
	sim.arm720Geom();
	for (int i = 0; i < 8000; ++i)
		sim.tick();

	sim.fillBank(0, /*phase*/ 1, c);
	sim.ringDoorbell(0, 1);
	bool got = false;
	for (int i = 0; i < kHTotal * (kActH + kVBlank) * 40; ++i) {
		sim.tick();
		if (sim.top.frames_done >= 1 && sim.top.has_frame) {
			got = true;
			break;
		}
	}
	if (!got) {
		// wrong packing may still present *something*; if no frame at all, still a signal
		std::cout << "CASE " << caseName(c)
		          << " EXECUTED no_frame (acceptable red) y_reads=" << sim.y_reads << "\n";
		std::cout << "PASS red-check " << caseName(c) << ": did not clean-present\n";
		return 0;
	}

	// Score against *correct* FullChroma/FullGrey expectation (phase 1).
	const Case expect = (c == Case::WrongStride) ? Case::FullGrey : Case::FullChroma;
	// For wrong_stride we packed unique grey Y with bad pitch — expect FullGrey model.
	const int phase = 1;
	const int pipe = 2; // fixed; negatives only need high mismatch
	const Score sc = scoreFrame(sim, phase, expect, pipe, /*frames*/ 2);
	const double ok = sc.samples ? double(sc.match) / double(sc.samples) : 1.0;

	std::cout << "CASE " << caseName(c) << " EXECUTED samples=" << sc.samples
	          << " match=" << sc.match << " mismatch=" << sc.mismatch << " rate=" << ok
	          << "\n";

	// Discriminator power: must NOT look like a clean full_grey/full_chroma pass.
	if (sc.samples > 100000 && ok >= 0.99) {
		std::cerr << "FAIL red-check " << caseName(c)
		          << ": incorrectly CLEAN rate=" << ok
		          << " (negative lost power)\n";
		return 1;
	}
	if (sc.samples > 10000 && ok > 0.50 && c == Case::WrongStride) {
		// wrong stride should be catastrophically wrong, not half-ok
		std::cerr << "FAIL red-check wrong_stride: mismatch too weak rate=" << ok << "\n";
		return 1;
	}
	std::cout << "PASS red-check " << caseName(c) << ": dirty rate=" << ok << "\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* env = std::getenv("PIXEL_CASE");
	const std::string which = env ? env : "all";

	// Geometry contract print (cross-lane pin).
	std::cout << "GEOM_PIN Option-C base=0x" << std::hex << kOptcBase
	          << " stride=0x" << kOptcBankStride << " doorbell=0x" << kOptcDoorbell
	          << std::dec << " y_stride=" << kYStride << " c_stride=" << kCStride
	          << " U_qw=" << kUQ << " V_qw=" << kVQ << " I420=" << kFrameBytes
	          << " PPC_align W%4=" << (kW % 4) << "\n";

	int rc = 0;
	if (which == "all" || which == "full_grey")
		rc |= runGreen(Case::FullGrey);
	if (which == "all" || which == "full_chroma")
		rc |= runGreen(Case::FullChroma);
	if (which == "all" || which == "bank_swap")
		rc |= runGreen(Case::BankSwap);
	if (which == "all" || which == "wrong_stride")
		rc |= runNegative(Case::WrongStride);
	if (which == "all" || which == "half_chroma")
		rc |= runNegative(Case::HalfChroma);

	if (which != "all" && which != "full_grey" && which != "full_chroma" &&
	    which != "bank_swap" && which != "wrong_stride" && which != "half_chroma") {
		std::cerr << "FAIL unknown PIXEL_CASE=" << which << "\n";
		return 2;
	}
	return rc;
}
