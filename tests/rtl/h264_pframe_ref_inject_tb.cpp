// P-frame verification with ffmpeg reference injection.
//
// 1. Prefill DPB reference with ffmpeg frame 0 (loop-filter skipped so the
//    plane matches our pre-deblock DPB nature).
// 2. Drive product h264_decode_core P_Skip (zero-MV) and P16x16 MBs.
// 3. Score DPB writes per-pixel against ffmpeg frame 1.
// 4. Optional USE_BRAM_DPB builds exercise h264_dpb_ddr BRAM_REF under real MC.

#include "Vh264_pframe_ref_inject_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr int FRAME_W = 320;
constexpr int FRAME_H = 240;
constexpr int MB_W = FRAME_W / 16;
constexpr int MB_H = FRAME_H / 16;
constexpr int MB_COUNT = MB_W * MB_H;
constexpr int Y_BYTES = FRAME_W * FRAME_H;
constexpr int C_W = FRAME_W / 2;
constexpr int C_H = FRAME_H / 2;
constexpr int C_BYTES = C_W * C_H;
constexpr int FRAME_BYTES = Y_BYTES + 2 * C_BYTES;
constexpr int kSamplesPerMb = 384;
constexpr uint32_t REF_BASE = 0;
constexpr uint32_t WRITE_BASE = 0x100000;
// Real deblock_mb walks filter+576-beat emit; allow long contended DDR MC.
constexpr int kTimeoutCycles = 800000;

int clampi(int v, int lo, int hi) { return std::max(lo, std::min(v, hi)); }
int clip1(int v) { return clampi(v, 0, 255); }
int avg2(int a, int b) { return (a + b + 1) >> 1; }

std::vector<uint8_t> readFile(const char* path) {
	std::ifstream f(path, std::ios::binary);
	if (!f) throw std::runtime_error(std::string("open failed: ") + path);
	return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

struct Pic {
	std::vector<uint8_t> data;
	int frames() const { return static_cast<int>(data.size() / FRAME_BYTES); }
	const uint8_t* frame(int f) const { return data.data() + static_cast<size_t>(f) * FRAME_BYTES; }
	int y(int f, int x, int y) const {
		x = clampi(x, 0, FRAME_W - 1);
		y = clampi(y, 0, FRAME_H - 1);
		return frame(f)[y * FRAME_W + x];
	}
	int u(int f, int x, int y) const {
		x = clampi(x, 0, C_W - 1);
		y = clampi(y, 0, C_H - 1);
		return frame(f)[Y_BYTES + y * C_W + x];
	}
	int v(int f, int x, int y) const {
		x = clampi(x, 0, C_W - 1);
		y = clampi(y, 0, C_H - 1);
		return frame(f)[Y_BYTES + C_BYTES + y * C_W + x];
	}
};

// Independent H.264 luma 6-tap / chroma bilinear (same as full_frame_mc_tb).
int hraw(const Pic& p, int f, int x, int y) {
	return p.y(f, x - 2, y) - 5 * p.y(f, x - 1, y) + 20 * p.y(f, x, y) +
	       20 * p.y(f, x + 1, y) - 5 * p.y(f, x + 2, y) + p.y(f, x + 3, y);
}
int halfH(const Pic& p, int f, int x, int y) { return clip1((hraw(p, f, x, y) + 16) >> 5); }
int halfV(const Pic& p, int f, int x, int y) {
	const int raw = p.y(f, x, y - 2) - 5 * p.y(f, x, y - 1) + 20 * p.y(f, x, y) +
	                20 * p.y(f, x, y + 1) - 5 * p.y(f, x, y + 2) + p.y(f, x, y + 3);
	return clip1((raw + 16) >> 5);
}
int halfHV(const Pic& p, int f, int x, int y) {
	// j: filter intermediate half-pels at full precision, round once.
	int mid[6];
	for (int k = -2; k <= 3; ++k) mid[k + 2] = hraw(p, f, x, y + k);
	const int raw = mid[0] - 5 * mid[1] + 20 * mid[2] + 20 * mid[3] - 5 * mid[4] + mid[5];
	return clip1((raw + 512) >> 10);
}
int lumaQpel(const Pic& p, int f, int xInt, int yInt, int xFrac, int yFrac) {
	// xFrac/yFrac in 0..3
	if (xFrac == 0 && yFrac == 0) return p.y(f, xInt, yInt);
	if (yFrac == 0 && xFrac == 2) return halfH(p, f, xInt, yInt);
	if (xFrac == 0 && yFrac == 2) return halfV(p, f, xInt, yInt);
	if (xFrac == 2 && yFrac == 2) return halfHV(p, f, xInt, yInt);
	if (yFrac == 0) {  // a/c
		const int a = p.y(f, xInt, yInt);
		const int b = halfH(p, f, xInt, yInt);
		return (xFrac == 1) ? avg2(a, b) : avg2(b, p.y(f, xInt + 1, yInt));
	}
	if (xFrac == 0) {
		const int a = p.y(f, xInt, yInt);
		const int b = halfV(p, f, xInt, yInt);
		return (yFrac == 1) ? avg2(a, b) : avg2(b, p.y(f, xInt, yInt + 1));
	}
	if (xFrac == 2) {
		const int a = halfH(p, f, xInt, yInt);
		const int b = halfHV(p, f, xInt, yInt);
		return (yFrac == 1) ? avg2(a, b) : avg2(b, halfH(p, f, xInt, yInt + 1));
	}
	if (yFrac == 2) {
		const int a = halfV(p, f, xInt, yInt);
		const int b = halfHV(p, f, xInt, yInt);
		return (xFrac == 1) ? avg2(a, b) : avg2(b, halfV(p, f, xInt + 1, yInt));
	}
	// diagonals e/g/p/r: average of nearest integer and opposite half
	if (xFrac == 1 && yFrac == 1) return avg2(p.y(f, xInt, yInt), halfHV(p, f, xInt, yInt));
	if (xFrac == 3 && yFrac == 1) return avg2(p.y(f, xInt + 1, yInt), halfHV(p, f, xInt, yInt));
	if (xFrac == 1 && yFrac == 3) return avg2(p.y(f, xInt, yInt + 1), halfHV(p, f, xInt, yInt));
	return avg2(p.y(f, xInt + 1, yInt + 1), halfHV(p, f, xInt, yInt));
}
int chromaEpel(const Pic& p, int f, int plane, int xInt, int yInt, int xFrac, int yFrac) {
	// xFrac/yFrac in 0..7; bilinear (8-xf)*(8-yf)
	auto s = [&](int x, int y) { return plane == 1 ? p.u(f, x, y) : p.v(f, x, y); };
	const int A = s(xInt, yInt);
	const int B = s(xInt + 1, yInt);
	const int C = s(xInt, yInt + 1);
	const int D = s(xInt + 1, yInt + 1);
	const int xf = xFrac, yf = yFrac;
	return (A * (8 - xf) * (8 - yf) + B * xf * (8 - yf) + C * (8 - xf) * yf + D * xf * yf + 32) >> 6;
}

int predY(const Pic& p, int f, int mbX, int mbY, int mvx, int mvy, int lx, int ly) {
	const int xq = mbX * 16 * 4 + mvx + lx * 4;
	const int yq = mbY * 16 * 4 + mvy + ly * 4;
	return lumaQpel(p, f, xq >> 2, yq >> 2, xq & 3, yq & 3);
}
int predC(const Pic& p, int f, int plane, int mbX, int mbY, int mvx, int mvy, int cx, int cy) {
	// 4:2:0: chroma MV in 1/8-pel units == luma MV in 1/4-pel units (same
	// numeric value). Product RTL uses chroma_frac = mv_qpel[2:0].
	// Floor-divide for negative coords so frac stays in 0..7.
	const int absx = (mbX * 8 + cx) * 8 + mvx;
	const int absy = (mbY * 8 + cy) * 8 + mvy;
	auto floor_div8 = [](int v) {
		return (v >= 0) ? (v >> 3) : -(((-v) + 7) >> 3);
	};
	auto mod8 = [](int v) {
		const int m = v % 8;
		return (m < 0) ? m + 8 : m;
	};
	return chromaEpel(p, f, plane, floor_div8(absx), floor_div8(absy), mod8(absx), mod8(absy));
}

uint32_t yAddr(uint32_t base, int x, int y) { return base + uint32_t(y * FRAME_W + x); }
uint32_t uAddr(uint32_t base, int x, int y) { return base + Y_BYTES + uint32_t(y * C_W + x); }
uint32_t vAddr(uint32_t base, int x, int y) { return base + Y_BYTES + C_BYTES + uint32_t(y * C_W + x); }

struct Write {
	uint32_t addr;
	uint8_t data;
};

// Simple DDR model for BRAM path (writes + variable-latency reads).
// Contention: random BUSY pulses while MC is live — same class of pressure
// that starved fstore writeback under continuous display refill.
struct DdrModel {
	static const int WORDS = 1 << 18;
	std::vector<uint64_t> mem;
	struct Beat {
		uint64_t d;
		int lat;
	};
	std::vector<Beat> q;
	unsigned lfsr = 0xACE1u;
	int busy_hold = 0;
	int busy_pulses = 0;
	bool contention = false;  // enable during MC only (inject needs quiet drain)
	DdrModel() : mem(WORDS, 0) {}
	unsigned rnd() {
		lfsr ^= lfsr << 7;
		lfsr ^= lfsr >> 9;
		lfsr ^= lfsr << 8;
		return lfsr;
	}
	void step(Vh264_pframe_ref_inject_tb* t) {
		// Use the BUSY value the DUT already saw (t->ddr_busy from last step)
		// when accepting RD/WE. Raising BUSY in the same cycle as a one-cycle
		// RD strobe drops the request — same shape as the m1 CDC strobe bug.
		const int busy_now = t->ddr_busy ? 1 : 0;
		t->ddr_dout_ready = 0;
		t->ddr_dout = 0;
		if (!q.empty()) {
			for (auto& b : q) --b.lat;
			if (q.front().lat <= 0) {
				t->ddr_dout_ready = 1;
				t->ddr_dout = q.front().d;
				q.erase(q.begin());
			}
		}
		if (t->ddr_we && !busy_now) {
			const uint32_t a = t->ddr_addr % WORDS;
			uint64_t old = mem[a];
			const uint64_t din = t->ddr_din;
			const uint8_t be = t->ddr_be;
			for (int b = 0; b < 8; b++) {
				if (be & (1u << b)) {
					const uint64_t m = 0xFFull << (8 * b);
					old = (old & ~m) | (din & m);
				}
			}
			mem[a] = old;
		}
		if (t->ddr_rd && !busy_now) {
			const uint32_t a = t->ddr_addr % WORDS;
			const int burst = t->ddr_burstcnt ? t->ddr_burstcnt : 1;
			const int lat_pat = 1 + int(rnd() & 3u);
			for (int i = 0; i < burst; i++) {
				q.push_back({mem[(a + i) % WORDS], lat_pat + i});
			}
		}
		// Schedule next-cycle BUSY after accepting this cycle's command.
		if (contention && (rnd() & 15u) == 0u) {
			++busy_pulses;
			t->ddr_busy = 1;
		} else {
			t->ddr_busy = (q.size() >= 12) ? 1 : 0;
		}
	}
};

struct Sim {
	Vh264_pframe_ref_inject_tb top{};
	DdrModel ddr;
	std::vector<uint8_t> mem;  // TB byte RAM for USE_BRAM_DPB=0
	std::vector<Write> writes;
	uint64_t cycles = 0;
	// registered TB mem response (+1)
	bool pend_valid = false;
	uint8_t pend_data = 0;

	Sim() : mem(WRITE_BASE + FRAME_BYTES + 64, 0) {}

	void tick() {
		// TB memory path response (registered)
		top.tb_mem_rvalid = pend_valid ? 1 : 0;
		top.tb_mem_rdata = pend_data;
		top.tb_mem_rstall = 0;
		if (top.dpb_rd_en && !top.tb_mem_rstall) {
			const uint32_t a = top.dpb_rd_addr;
			pend_valid = true;
			pend_data = (a < mem.size()) ? mem[a] : 0;
		} else {
			pend_valid = false;
			pend_data = 0;
		}
		if (top.dpb_wr_en) {
			writes.push_back({top.dpb_wr_addr, static_cast<uint8_t>(top.dpb_wr_data)});
		}
		ddr.step(&top);
		top.clk = 0;
		top.eval();
		top.clk = 1;
		top.eval();
		++cycles;
	}
};

void clear(Sim& s) {
	auto& t = s.top;
	t.slice_start = 0;
	t.first_mb_in_slice = 0;
	t.mb_type_valid = 0;
	t.mb_type = 0;
	t.mb_skip = 0;
	t.mb_residual_bit_offset = 0;
	t.cbp_luma = 0;
	t.cbp_chroma = 0;
	t.p16_zero_mv_valid = 0;
	t.p16_mb_x = 0;
	t.p16_mb_y = 0;
	t.p16_mb_is_ref = 0;
	t.dpb_ref_base = REF_BASE;
	t.dpb_write_base = WRITE_BASE;
	t.p16_mv_x_qpel = 0;
	t.p16_mv_y_qpel = 0;
	t.p16_mvd_x_qpel = 0;
	t.p16_mvd_y_qpel = 0;
	t.p16_ref_idx_l0 = 0;
	// Default: disable filter so MC scores match skip_loop_filter goldens.
	t.disable_deblocking_filter_idc = 1;
	t.slice_alpha_c0_offset = 0;
	t.slice_beta_offset = 0;
	t.rbsp_window_base = 0;
	t.tb_mem_we = 0;
	t.dpb_idr_start = 0;
	t.dpb_frame_done_req = 0;
	t.dpb_rec_wr_en = 0;
	t.ddr_busy = 0;
	t.ddr_dout = 0;
	t.ddr_dout_ready = 0;
	for (int i = 0; i < 64; ++i) t.rbsp_byte_in[i] = 0;
	for (int i = 0; i < 256; ++i) t.p16_residual_y[i] = 0;
	for (int i = 0; i < 64; ++i) {
		t.p16_residual_u[i] = 0;
		t.p16_residual_v[i] = 0;
	}
}

void resetDut(Sim& s) {
	clear(s);
	s.top.reset = 1;
	s.tick();
	s.tick();
	s.top.reset = 0;
	s.tick();
}

void injectRefTbMem(Sim& s, const Pic& pic, int frame) {
	const uint8_t* src = pic.frame(frame);
	for (int i = 0; i < FRAME_BYTES; ++i) s.mem[REF_BASE + i] = src[i];
	std::cout << "DPB_INJECT tb_mem frame=" << frame << " bytes=" << FRAME_BYTES
	          << " base=0x" << std::hex << REF_BASE << std::dec << "\n";
}

#ifdef USE_BRAM_DPB
bool injectRefBram(Sim& s, const Pic& pic, int frame) {
	const uint8_t* src = pic.frame(frame);
	// Write full I420 into current bank via rec_wr (byte offsets 0..)
	for (int i = 0; i < FRAME_BYTES; ++i) {
		int guard = 0;
		while (s.top.dpb_rec_wr_full && guard++ < 10000) s.tick();
		if (s.top.dpb_rec_wr_full) {
			std::cerr << "FAIL BRAM inject: rec_wr_full stuck at byte " << i << "\n";
			return false;
		}
		s.top.dpb_rec_wr_en = 1;
		s.top.dpb_rec_wr_addr = static_cast<uint32_t>(i);
		s.top.dpb_rec_wr_data = src[i];
		s.tick();
		s.top.dpb_rec_wr_en = 0;
	}
	s.top.dpb_frame_done_req = 1;
	s.tick();
	s.top.dpb_frame_done_req = 0;
	int wait = 0;
	while (!s.top.dpb_frame_done_ack && wait++ < 5000000) s.tick();
	if (!s.top.dpb_frame_done_ack) {
		std::cerr << "FAIL BRAM inject: frame_done_ack timeout\n";
		return false;
	}
	s.tick();
	if (!s.top.dpb_ref_ready) {
		std::cerr << "FAIL BRAM inject: ref_ready not set\n";
		return false;
	}
	std::cout << "DPB_INJECT BRAM_REF frame=" << frame << " bytes=" << FRAME_BYTES
	          << " ref_ready=1\n";
	return true;
}
#endif

bool driveP16(Sim& s, int mbX, int mbY, int mvx, int mvy, const int16_t* resY, const int16_t* resU,
              const int16_t* resV, size_t wantWrites) {
	auto& t = s.top;
	t.p16_mb_x = static_cast<uint8_t>(mbX);
	t.p16_mb_y = static_cast<uint8_t>(mbY);
	t.p16_mb_is_ref = 1;
	t.dpb_ref_base = REF_BASE;
	t.dpb_write_base = WRITE_BASE;
	t.p16_mv_x_qpel = static_cast<int16_t>(mvx);
	t.p16_mv_y_qpel = static_cast<int16_t>(mvy);
	t.p16_mvd_x_qpel = 0;
	t.p16_mvd_y_qpel = 0;
	t.p16_ref_idx_l0 = 0;
	t.cbp_luma = 0xf;
	t.cbp_chroma = 2;
	for (int i = 0; i < 256; ++i) t.p16_residual_y[i] = resY ? resY[i] : 0;
	for (int i = 0; i < 64; ++i) {
		t.p16_residual_u[i] = resU ? resU[i] : 0;
		t.p16_residual_v[i] = resV ? resV[i] : 0;
	}
	t.p16_zero_mv_valid = 1;
	s.tick();
	t.p16_zero_mv_valid = 0;
	for (int i = 0; i < kTimeoutCycles; ++i) {
		if (!t.busy && s.writes.size() >= wantWrites) return true;
		s.tick();
	}
	return false;
}

bool driveSkip(Sim& s, int mbX, int mbY, size_t wantWrites) {
	// Product skip launch via syntax: mb_type_valid + mb_skip.
	// For MB(0,0) MVP is zero (A/B unavailable) — pure colocated copy.
	auto& t = s.top;
	t.mb_type_valid = 1;
	t.mb_type = 0;
	t.mb_skip = 1;
	t.cbp_luma = 0;
	t.cbp_chroma = 0;
	t.p16_mb_x = static_cast<uint8_t>(mbX);
	t.p16_mb_y = static_cast<uint8_t>(mbY);
	// Also force p16 path with zero MV so we don't depend on neighbour MVP
	// state for interior skip MBs in this isolated scoreboard.
	return driveP16(s, mbX, mbY, 0, 0, nullptr, nullptr, nullptr, wantWrites);
}

// Syntax-path P16x16: bitstream-style mvd + MVP (not forced mv_x/y_qpel).
// residual_all_zero via cbp=0. MB address comes from first_mb_in_slice.
// At MB(0,0) A/B unavailable => MVP=0 => MV=mvd (closes mvd→MVP→MC seam).
bool driveSyntaxMvd(Sim& s, int mbX, int mbY, int mvd_x, int mvd_y, size_t wantWrites) {
	auto& t = s.top;
	t.slice_start = 1;
	t.first_mb_in_slice = static_cast<uint16_t>(mbY * MB_W + mbX);
	s.tick();
	t.slice_start = 0;
	s.tick();
	t.p16_zero_mv_valid = 0;
	t.mb_type_valid = 1;
	t.mb_type = 0;  // P_L0_16x16
	t.mb_skip = 0;
	t.cbp_luma = 0;
	t.cbp_chroma = 0;
	t.p16_mvd_x_qpel = static_cast<int16_t>(mvd_x);
	t.p16_mvd_y_qpel = static_cast<int16_t>(mvd_y);
	t.p16_mv_x_qpel = 0;
	t.p16_mv_y_qpel = 0;
	t.p16_ref_idx_l0 = 0;
	t.dpb_ref_base = REF_BASE;
	t.dpb_write_base = WRITE_BASE;
	s.tick();
	t.mb_type_valid = 0;
	t.p16_mvd_x_qpel = 0;
	t.p16_mvd_y_qpel = 0;
	for (int i = 0; i < kTimeoutCycles; ++i) {
		if (!t.busy && s.writes.size() >= wantWrites) return true;
		s.tick();
	}
	return false;
}

// Overlay DPB writes onto MB body planes (last write wins; neighbour strips ok).
void applyWritesToMb(const std::vector<Write>& writes, size_t from, int mbX, int mbY,
                     uint8_t y[256], uint8_t u[64], uint8_t v[64]) {
	for (size_t i = from; i < writes.size(); ++i) {
		const Write& w = writes[i];
		for (int ly = 0; ly < 16; ++ly)
			for (int lx = 0; lx < 16; ++lx)
				if (w.addr == yAddr(WRITE_BASE, mbX * 16 + lx, mbY * 16 + ly))
					y[ly * 16 + lx] = w.data;
		for (int cy = 0; cy < 8; ++cy)
			for (int cx = 0; cx < 8; ++cx) {
				if (w.addr == uAddr(WRITE_BASE, mbX * 8 + cx, mbY * 8 + cy))
					u[cy * 8 + cx] = w.data;
				if (w.addr == vAddr(WRITE_BASE, mbX * 8 + cx, mbY * 8 + cy))
					v[cy * 8 + cx] = w.data;
			}
	}
}

int samplePlane(const Pic& p, int f, int plane, int x, int y) {
	if (plane == 0) return p.y(f, x, y);
	if (plane == 1) return p.u(f, x, y);
	return p.v(f, x, y);
}

}  // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* i420Path = std::getenv("MPLEX_I420");
	if (!i420Path) i420Path = ".scratch/pframe_inject/nodeblock_320x240.i420";

	Pic pic;
	try {
		pic.data = readFile(i420Path);
	} catch (const std::exception& e) {
		std::cerr << "FAIL pframe inject: " << e.what() << "\n";
		return 2;
	}
	if (pic.frames() < 2) {
		std::cerr << "FAIL pframe inject: need >=2 frames in " << i420Path << "\n";
		return 2;
	}

	// Classify MBs: colocated-equal on all planes => zero-MV skip candidates.
	std::vector<char> isSkip(MB_COUNT, 0);
	int skipCount = 0;
	int p16Count = 0;
	for (int my = 0; my < MB_H; ++my) {
		for (int mx = 0; mx < MB_W; ++mx) {
			bool eq = true;
			for (int ly = 0; ly < 16 && eq; ++ly)
				for (int lx = 0; lx < 16 && eq; ++lx)
					if (pic.y(0, mx * 16 + lx, my * 16 + ly) != pic.y(1, mx * 16 + lx, my * 16 + ly))
						eq = false;
			for (int cy = 0; cy < 8 && eq; ++cy)
				for (int cx = 0; cx < 8 && eq; ++cx) {
					if (pic.u(0, mx * 8 + cx, my * 8 + cy) != pic.u(1, mx * 8 + cx, my * 8 + cy)) eq = false;
					if (pic.v(0, mx * 8 + cx, my * 8 + cy) != pic.v(1, mx * 8 + cx, my * 8 + cy)) eq = false;
				}
			const int idx = my * MB_W + mx;
			isSkip[idx] = eq ? 1 : 0;
			if (eq) ++skipCount;
			else ++p16Count;
		}
	}
	std::cout << "INJECT_CLASSIFY skip_colocated=" << skipCount << " nonzero_residual_or_mv=" << p16Count
	          << " of " << MB_COUNT << "\n";

	Sim s;
	resetDut(s);
	// Quiet DDR during DPB inject; enable random BUSY for MC scoreboard.
	s.ddr.contention = false;

#ifdef USE_BRAM_DPB
	if (!injectRefBram(s, pic, 0)) return 1;
	// BRAM luma-only: chroma still via DDR cache — also keep TB mem chroma at REF
	// for any TB-side checks; core reads go through dpb_ddr.
	injectRefTbMem(s, pic, 0);
#else
	injectRefTbMem(s, pic, 0);
#endif

	// Contended DDR during MC. BRAM_LUMA_ONLY still fills chroma windows from
	// DDR — random BUSY must stay light enough not to exceed kTimeoutCycles.
	s.ddr.contention = true;

	// ----- P_Skip path: zero-MV, zero residual, score vs ffmpeg frame 1 -----
	s.writes.clear();
	long long skipExact = 0, skipBad = 0;
	int skipDone = 0;
	const int kSkipLimit = std::min(skipCount, 64);  // keep runtime bounded
	for (int idx = 0; idx < MB_COUNT && skipDone < kSkipLimit; ++idx) {
		if (!isSkip[idx]) continue;
		const int mx = idx % MB_W;
		const int my = idx / MB_W;
		const size_t want = s.writes.size() + kSamplesPerMb;
		if (!driveP16(s, mx, my, 0, 0, nullptr, nullptr, nullptr, want)) {
			std::cerr << "FAIL P_Skip timeout mb=" << mx << "," << my << " writes=" << s.writes.size()
			          << "\n";
			return 1;
		}
		// Score last 384 writes against golden frame 1
		const size_t base = s.writes.size() - kSamplesPerMb;
		for (int i = 0; i < kSamplesPerMb; ++i) {
			const Write& w = s.writes[base + i];
			int wantData = 0;
			uint32_t wantAddr = 0;
			if (i < 256) {
				const int lx = i & 15, ly = i >> 4;
				wantAddr = yAddr(WRITE_BASE, mx * 16 + lx, my * 16 + ly);
				wantData = pic.y(1, mx * 16 + lx, my * 16 + ly);
			} else if (i < 320) {
				const int j = i - 256, cx = j & 7, cy = j >> 3;
				wantAddr = uAddr(WRITE_BASE, mx * 8 + cx, my * 8 + cy);
				wantData = pic.u(1, mx * 8 + cx, my * 8 + cy);
			} else {
				const int j = i - 320, cx = j & 7, cy = j >> 3;
				wantAddr = vAddr(WRITE_BASE, mx * 8 + cx, my * 8 + cy);
				wantData = pic.v(1, mx * 8 + cx, my * 8 + cy);
			}
			if (w.addr != wantAddr || int(w.data) != wantData) {
				if (skipBad < 8) {
					std::cerr << "FAIL P_Skip px mb=" << mx << "," << my << " i=" << i
					          << " got_a=0x" << std::hex << w.addr << " want_a=0x" << wantAddr << std::dec
					          << " got=" << int(w.data) << " want=" << wantData << "\n";
				}
				++skipBad;
			} else {
				++skipExact;
			}
		}
		++skipDone;
	}
	std::cout << "P_SKIP_RESULT mbs=" << skipDone << "/" << skipCount
	          << " samples_exact=" << skipExact << " samples_bad=" << skipBad
	          << (skipBad == 0 ? " PASS\n" : " FAIL\n");

	// ----- P16x16: non-colocated MBs — MV=0 residual = golden - pred -----
	// With MV=0, pred = colocated ref; residual = f1 - f0. Exercises residual
	// add + writeback. True non-zero MVD still blocked by T05 (g-stream).
	s.writes.clear();
	long long p16Exact = 0, p16Bad = 0;
	int p16Done = 0;
	const int kP16Limit = std::min(p16Count, 32);
	for (int idx = 0; idx < MB_COUNT && p16Done < kP16Limit; ++idx) {
		if (isSkip[idx]) continue;
		const int mx = idx % MB_W;
		const int my = idx / MB_W;
		int16_t resY[256], resU[64], resV[64];
		for (int ly = 0; ly < 16; ++ly)
			for (int lx = 0; lx < 16; ++lx) {
				const int pred = predY(pic, 0, mx, my, 0, 0, lx, ly);
				const int gold = pic.y(1, mx * 16 + lx, my * 16 + ly);
				resY[ly * 16 + lx] = static_cast<int16_t>(gold - pred);
			}
		for (int cy = 0; cy < 8; ++cy)
			for (int cx = 0; cx < 8; ++cx) {
				const int pu = predC(pic, 0, 1, mx, my, 0, 0, cx, cy);
				const int pv = predC(pic, 0, 2, mx, my, 0, 0, cx, cy);
				resU[cy * 8 + cx] = static_cast<int16_t>(pic.u(1, mx * 8 + cx, my * 8 + cy) - pu);
				resV[cy * 8 + cx] = static_cast<int16_t>(pic.v(1, mx * 8 + cx, my * 8 + cy) - pv);
			}
		const size_t want = s.writes.size() + kSamplesPerMb;
		if (!driveP16(s, mx, my, 0, 0, resY, resU, resV, want)) {
			std::cerr << "FAIL P16 timeout mb=" << mx << "," << my << "\n";
			return 1;
		}
		const size_t base = s.writes.size() - kSamplesPerMb;
		for (int i = 0; i < kSamplesPerMb; ++i) {
			const Write& w = s.writes[base + i];
			int wantData = 0;
			uint32_t wantAddr = 0;
			if (i < 256) {
				const int lx = i & 15, ly = i >> 4;
				wantAddr = yAddr(WRITE_BASE, mx * 16 + lx, my * 16 + ly);
				wantData = pic.y(1, mx * 16 + lx, my * 16 + ly);
			} else if (i < 320) {
				const int j = i - 256, cx = j & 7, cy = j >> 3;
				wantAddr = uAddr(WRITE_BASE, mx * 8 + cx, my * 8 + cy);
				wantData = pic.u(1, mx * 8 + cx, my * 8 + cy);
			} else {
				const int j = i - 320, cx = j & 7, cy = j >> 3;
				wantAddr = vAddr(WRITE_BASE, mx * 8 + cx, my * 8 + cy);
				wantData = pic.v(1, mx * 8 + cx, my * 8 + cy);
			}
			if (w.addr != wantAddr || int(w.data) != wantData) {
				if (p16Bad < 8) {
					std::cerr << "FAIL P16 px mb=" << mx << "," << my << " i=" << i
					          << " got=" << int(w.data) << " want=" << wantData << "\n";
				}
				++p16Bad;
			} else {
				++p16Exact;
			}
		}
		++p16Done;
	}
	std::cout << "P16x16_RESULT mbs=" << p16Done << "/" << p16Count
	          << " samples_exact=" << p16Exact << " samples_bad=" << p16Bad
	          << " (MV=0 + residual=f1-f0 via p16_zero_mv force)\n";
	std::cout << (p16Bad == 0 ? "P16x16_PASS\n" : "P16x16_FAIL\n");

	// ----- Non-zero MV + edge clamp (forced mv via p16_zero_mv path) -----
	// Product stream_path may still tie mvd=0; this TB drives reconstructed MV
	// on mv_x/y_qpel under p16_zero_mv_valid so MC/qpel/edge seams are tested
	// independently of T05 feed wiring.
	struct MvCase {
		int mx, my, mvx, mvy;
		const char* tag;
	};
	const MvCase kMvCases[] = {
	    {5, 5, 4, 0, "qpel_h"},          // half-pel horizontal
	    {6, 5, 0, 4, "qpel_v"},          // half-pel vertical
	    {7, 5, 2, 2, "qpel_diag"},       // quarter diagonal
	    {8, 6, 1, 3, "qpel_odd"},        // odd qpel
	    {0, 0, -8, -8, "edge_tl"},       // 21x21 window off top-left
	    {MB_W - 1, MB_H - 1, 12, 12, "edge_br"},  // off bottom-right
	    {0, 7, -6, 2, "edge_left"},
	    {MB_W - 1, 7, 10, -4, "edge_right"},
	};
	long long nzExact = 0, nzBad = 0;
	int nzDone = 0;
	for (const MvCase& c : kMvCases) {
		int16_t resY[256], resU[64], resV[64];
		for (int ly = 0; ly < 16; ++ly)
			for (int lx = 0; lx < 16; ++lx) {
				const int pred = predY(pic, 0, c.mx, c.my, c.mvx, c.mvy, lx, ly);
				const int gold = pic.y(1, c.mx * 16 + lx, c.my * 16 + ly);
				resY[ly * 16 + lx] = static_cast<int16_t>(gold - pred);
			}
		for (int cy = 0; cy < 8; ++cy)
			for (int cx = 0; cx < 8; ++cx) {
				const int pu = predC(pic, 0, 1, c.mx, c.my, c.mvx, c.mvy, cx, cy);
				const int pv = predC(pic, 0, 2, c.mx, c.my, c.mvx, c.mvy, cx, cy);
				resU[cy * 8 + cx] =
				    static_cast<int16_t>(pic.u(1, c.mx * 8 + cx, c.my * 8 + cy) - pu);
				resV[cy * 8 + cx] =
				    static_cast<int16_t>(pic.v(1, c.mx * 8 + cx, c.my * 8 + cy) - pv);
			}
		const size_t want = s.writes.size() + kSamplesPerMb;
		if (!driveP16(s, c.mx, c.my, c.mvx, c.mvy, resY, resU, resV, want)) {
			std::cerr << "FAIL NZMV timeout " << c.tag << " mb=" << c.mx << "," << c.my << "\n";
			return 1;
		}
		const size_t base = s.writes.size() - kSamplesPerMb;
		for (int i = 0; i < kSamplesPerMb; ++i) {
			const Write& w = s.writes[base + i];
			int wantData = 0;
			uint32_t wantAddr = 0;
			if (i < 256) {
				const int lx = i & 15, ly = i >> 4;
				wantAddr = yAddr(WRITE_BASE, c.mx * 16 + lx, c.my * 16 + ly);
				wantData = pic.y(1, c.mx * 16 + lx, c.my * 16 + ly);
			} else if (i < 320) {
				const int j = i - 256, cx = j & 7, cy = j >> 3;
				wantAddr = uAddr(WRITE_BASE, c.mx * 8 + cx, c.my * 8 + cy);
				wantData = pic.u(1, c.mx * 8 + cx, c.my * 8 + cy);
			} else {
				const int j = i - 320, cx = j & 7, cy = j >> 3;
				wantAddr = vAddr(WRITE_BASE, c.mx * 8 + cx, c.my * 8 + cy);
				wantData = pic.v(1, c.mx * 8 + cx, c.my * 8 + cy);
			}
			if (w.addr != wantAddr || int(w.data) != wantData) {
				if (nzBad < 8) {
					std::cerr << "FAIL NZMV " << c.tag << " mb=" << c.mx << "," << c.my
					          << " i=" << i << " got=" << int(w.data) << " want=" << wantData
					          << "\n";
				}
				++nzBad;
			} else {
				++nzExact;
			}
		}
		++nzDone;
	}
	std::cout << "P16x16_NZMV_EDGE mbs=" << nzDone << " samples_exact=" << nzExact
	          << " samples_bad=" << nzBad << (nzBad == 0 ? " PASS\n" : " FAIL\n");

	// ----- Real-stream mvd seam: syntax mb_type + mvd → MVP → MC (cbp=0) -----
	// MB(0,0): neighbours unavailable => MVP=0 => reconstructed MV equals mvd.
	// Residual forced 0; score DPB body vs pure MC(ref, mvd) under contention.
	struct MvdCase {
		int mx, my, mvd_x, mvd_y;
		const char* tag;
	};
	const MvdCase kMvdCases[] = {
	    {0, 0, 4, 0, "mvd_h4"},
	    {0, 0, 0, 4, "mvd_v4"},
	    {0, 0, 2, 2, "mvd_diag"},
	    {0, 0, -6, 3, "mvd_neg_edge"},
	    {0, 0, 12, -4, "mvd_brish"},
	};
	long long mvdExact = 0, mvdBad = 0;
	int mvdDone = 0;
	s.top.disable_deblocking_filter_idc = 1;
	for (const MvdCase& c : kMvdCases) {
		const size_t w0 = s.writes.size();
		const size_t want = w0 + kSamplesPerMb;
		if (!driveSyntaxMvd(s, c.mx, c.my, c.mvd_x, c.mvd_y, want)) {
			std::cerr << "FAIL MVD timeout " << c.tag << " writes=" << s.writes.size() << "\n";
			return 1;
		}
		uint8_t yb[256], ub[64], vb[64];
		std::memset(yb, 0, sizeof yb);
		std::memset(ub, 0, sizeof ub);
		std::memset(vb, 0, sizeof vb);
		applyWritesToMb(s.writes, w0, c.mx, c.my, yb, ub, vb);
		for (int ly = 0; ly < 16; ++ly)
			for (int lx = 0; lx < 16; ++lx) {
				const int wantY = predY(pic, 0, c.mx, c.my, c.mvd_x, c.mvd_y, lx, ly);
				if (int(yb[ly * 16 + lx]) != wantY) {
					if (mvdBad < 8)
						std::cerr << "FAIL MVD " << c.tag << " Y lx=" << lx << " ly=" << ly
						          << " got=" << int(yb[ly * 16 + lx]) << " want=" << wantY << "\n";
					++mvdBad;
				} else {
					++mvdExact;
				}
			}
		for (int cy = 0; cy < 8; ++cy)
			for (int cx = 0; cx < 8; ++cx) {
				const int wu = predC(pic, 0, 1, c.mx, c.my, c.mvd_x, c.mvd_y, cx, cy);
				const int wv = predC(pic, 0, 2, c.mx, c.my, c.mvd_x, c.mvd_y, cx, cy);
				if (int(ub[cy * 8 + cx]) != wu || int(vb[cy * 8 + cx]) != wv) {
					if (mvdBad < 8)
						std::cerr << "FAIL MVD " << c.tag << " C cx=" << cx << " cy=" << cy << "\n";
					++mvdBad;
				} else {
					mvdExact += 2;
				}
			}
		++mvdDone;
	}
	std::cout << "MVD_SYNTAX_SEAM mbs=" << mvdDone << " samples_exact=" << mvdExact
	          << " samples_bad=" << mvdBad << (mvdBad == 0 ? " PASS\n" : " FAIL\n");

	// ----- In-loop deblock product path (real h264_deblock_mb) -----
	// 1) MB(0,0) MV=0 res=0 with deblock ON: nz=0 & no neighbours => identity.
	// 2) MB(1,0) MV=16 qpel (4 pel) res=0: shared vertical edge bS=1 filters.
	// Score both MB bodies (address overlay) against SW edge model, then
	// re-inject OUR filtered plane as the next reference and re-MC one MB.
	{
		s.top.disable_deblocking_filter_idc = 0;
		s.top.slice_alpha_c0_offset = 0;
		s.top.slice_beta_offset = 0;
		// Fresh slice so deblock neighbour RAM starts clean.
		s.top.slice_start = 1;
		s.top.first_mb_in_slice = 0;
		s.tick();
		s.top.slice_start = 0;
		s.tick();

		const size_t wA = s.writes.size();
		if (!driveP16(s, 0, 0, 0, 0, nullptr, nullptr, nullptr, wA + kSamplesPerMb)) {
			std::cerr << "FAIL DEBLOCK mb0 timeout\n";
			return 1;
		}
		// Keep deblock neighbour context: do NOT slice_start between MB0 and MB1.
		// driveP16 does not pulse slice_start.
		const size_t wB = s.writes.size();
		if (!driveP16(s, 1, 0, 16, 0, nullptr, nullptr, nullptr, wB + kSamplesPerMb)) {
			std::cerr << "FAIL DEBLOCK mb1 timeout\n";
			return 1;
		}

		uint8_t y0[256], u0[64], v0[64], y1[256], u1[64], v1[64];
		std::memset(y0, 0, sizeof y0);
		std::memset(u0, 0, sizeof u0);
		std::memset(v0, 0, sizeof v0);
		std::memset(y1, 0, sizeof y1);
		std::memset(u1, 0, sizeof u1);
		std::memset(v1, 0, sizeof v1);
		applyWritesToMb(s.writes, wA, 0, 0, y0, u0, v0);
		applyWritesToMb(s.writes, wA, 1, 0, y1, u1, v1);

		// Build PRE planes (MC only) and apply SW vertical MB-boundary filter.
		uint8_t pre0[256], pre1[256];
		for (int ly = 0; ly < 16; ++ly)
			for (int lx = 0; lx < 16; ++lx) {
				pre0[ly * 16 + lx] = static_cast<uint8_t>(predY(pic, 0, 0, 0, 0, 0, lx, ly));
				pre1[ly * 16 + lx] = static_cast<uint8_t>(predY(pic, 0, 1, 0, 16, 0, lx, ly));
			}
		// Normative weak filter on vertical edge x=16 between MB0|MB1, qp=26, bS=1.
		// Inline minimal refEdge for luma non-strong bS=1..3.
		auto alphaAt = [](int idx) {
			static const int t[52] = {
			    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,4,5,6,7,8,9,10,12,13,15,17,20,22,25,28,
			    32,36,40,45,50,56,63,71,80,90,101,113,127,144,162,182,203,226,255,255};
			return t[idx < 0 ? 0 : (idx > 51 ? 51 : idx)];
		};
		auto betaAt = [](int idx) {
			static const int t[52] = {
			    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,2,2,3,3,3,3,4,4,4,6,6,7,7,8,8,
			    9,9,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18};
			return t[idx < 0 ? 0 : (idx > 51 ? 51 : idx)];
		};
		auto tc0At = [](int idx, int bs) {
			static const int t[52][3] = {
			    {-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},
			    {-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},
			    {0,0,0},{0,0,1},{0,0,1},{0,0,1},{0,0,1},{0,1,1},{0,1,1},{1,1,1},
			    {1,1,1},{1,1,1},{1,1,1},{1,1,2},{1,1,2},{1,1,2},{1,1,2},{1,2,3},
			    {1,2,3},{2,2,3},{2,2,4},{2,3,4},{2,3,4},{3,3,5},{3,4,6},{3,4,6},
			    {4,5,7},{4,5,8},{4,6,9},{5,7,10},{6,8,11},{6,8,13},{7,10,14},{8,11,16},
			    {9,12,18},{10,13,20},{11,15,23},{13,17,25}};
			if (bs < 1 || bs > 3) return 0;
			const int i = idx < 0 ? 0 : (idx > 51 ? 51 : idx);
			return t[i][bs - 1];
		};
		const int qp = 26, bs = 1;
		const int alpha = alphaAt(qp), beta = betaAt(qp), tc0 = tc0At(qp, bs);
		uint8_t sw0[256], sw1[256];
		std::memcpy(sw0, pre0, 256);
		std::memcpy(sw1, pre1, 256);
		for (int y = 0; y < 16; ++y) {
			// p = MB0 right cols 13..15, q = MB1 left cols 0..2 (and p3/q3)
			const int p3 = sw0[y * 16 + 12], p2 = sw0[y * 16 + 13], p1 = sw0[y * 16 + 14], p0 = sw0[y * 16 + 15];
			const int q0 = sw1[y * 16 + 0], q1 = sw1[y * 16 + 1], q2 = sw1[y * 16 + 2];
			const int ad = std::abs(p0 - q0);
			const bool ok = bs != 0 && ad < alpha && std::abs(p1 - p0) < beta && std::abs(q1 - q0) < beta;
			if (!ok) continue;
			const bool ap = std::abs(p2 - p0) < beta;
			const bool aq = std::abs(q2 - q0) < beta;
			const int tc = tc0 + (ap ? 1 : 0) + (aq ? 1 : 0);
			const int delta = clampi((((q0 - p0) << 2) + (p1 - q1) + 4) >> 3, -tc, tc);
			sw0[y * 16 + 15] = static_cast<uint8_t>(clip1(p0 + delta));
			sw1[y * 16 + 0] = static_cast<uint8_t>(clip1(q0 - delta));
			if (ap) {
				const int adj = clampi((p2 + ((p0 + q0 + 1) >> 1) - 2 * p1) >> 1, -tc0, tc0);
				sw0[y * 16 + 14] = static_cast<uint8_t>(clip1(p1 + adj));
			}
			if (aq) {
				const int adj = clampi((q2 + ((p0 + q0 + 1) >> 1) - 2 * q1) >> 1, -tc0, tc0);
				sw1[y * 16 + 1] = static_cast<uint8_t>(clip1(q1 + adj));
			}
		}

		long long dbExact = 0, dbBad = 0;
		int edgeDiff = 0;
		for (int i = 0; i < 256; ++i) {
			if (y0[i] != sw0[i]) {
				if (dbBad < 8)
					std::cerr << "FAIL DEBLOCK mb0 i=" << i << " got=" << int(y0[i])
					          << " want=" << int(sw0[i]) << " pre=" << int(pre0[i]) << "\n";
				++dbBad;
			} else
				++dbExact;
			if (y1[i] != sw1[i]) {
				if (dbBad < 8)
					std::cerr << "FAIL DEBLOCK mb1 i=" << i << " got=" << int(y1[i])
					          << " want=" << int(sw1[i]) << " pre=" << int(pre1[i]) << "\n";
				++dbBad;
			} else
				++dbExact;
			if (sw0[i] != pre0[i] || sw1[i] != pre1[i]) ++edgeDiff;
		}
		// Chroma weak filter on MB vertical boundary (only p0/q0), qp_c from qPy=26.
		auto filtChromaBoundary = [&](uint8_t c0[64], uint8_t c1[64]) {
			const int qpc = 26;  // pps offset 0, qPy 26 → qPc 26
			const int a = alphaAt(qpc), b = betaAt(qpc), t0 = tc0At(qpc, bs);
			for (int y = 0; y < 8; ++y) {
				const int p1 = c0[y * 8 + 6], p0 = c0[y * 8 + 7];
				const int q0 = c1[y * 8 + 0], q1 = c1[y * 8 + 1];
				const bool ok = std::abs(p0 - q0) < a && std::abs(p1 - p0) < b && std::abs(q1 - q0) < b;
				if (!ok) continue;
				const int tc = t0 + 1;  // chroma
				const int delta = clampi((((q0 - p0) << 2) + (p1 - q1) + 4) >> 3, -tc, tc);
				c0[y * 8 + 7] = static_cast<uint8_t>(clip1(p0 + delta));
				c1[y * 8 + 0] = static_cast<uint8_t>(clip1(q0 - delta));
			}
		};
		uint8_t su0[64], su1[64], sv0[64], sv1[64];
		for (int i = 0; i < 64; ++i) {
			su0[i] = static_cast<uint8_t>(predC(pic, 0, 1, 0, 0, 0, 0, i & 7, i >> 3));
			sv0[i] = static_cast<uint8_t>(predC(pic, 0, 2, 0, 0, 0, 0, i & 7, i >> 3));
			su1[i] = static_cast<uint8_t>(predC(pic, 0, 1, 1, 0, 16, 0, i & 7, i >> 3));
			sv1[i] = static_cast<uint8_t>(predC(pic, 0, 2, 1, 0, 16, 0, i & 7, i >> 3));
		}
		filtChromaBoundary(su0, su1);
		filtChromaBoundary(sv0, sv1);
		// Prefill chroma with PRE then overlay DPB writes (last write wins).
		uint8_t cu0[64], cu1[64], cv0[64], cv1[64];
		for (int i = 0; i < 64; ++i) {
			cu0[i] = static_cast<uint8_t>(predC(pic, 0, 1, 0, 0, 0, 0, i & 7, i >> 3));
			cv0[i] = static_cast<uint8_t>(predC(pic, 0, 2, 0, 0, 0, 0, i & 7, i >> 3));
			cu1[i] = static_cast<uint8_t>(predC(pic, 0, 1, 1, 0, 16, 0, i & 7, i >> 3));
			cv1[i] = static_cast<uint8_t>(predC(pic, 0, 2, 1, 0, 16, 0, i & 7, i >> 3));
		}
		std::memcpy(u0, cu0, 64);
		std::memcpy(u1, cu1, 64);
		std::memcpy(v0, cv0, 64);
		std::memcpy(v1, cv1, 64);
		applyWritesToMb(s.writes, wA, 0, 0, y0, u0, v0);
		applyWritesToMb(s.writes, wA, 1, 0, y1, u1, v1);
		// Chroma: interior cols 1..6 must stay PRE (no vertical MB-edge touch).
		// Boundary cols 0/7 must match SW weak filter OR PRE (bS gate may skip).
		long long chExact = 0, chBad = 0;
		for (int i = 0; i < 64; ++i) {
			const int cx = i & 7;
			const bool edge = (cx == 0 || cx == 7);
			auto okC = [&](uint8_t got, uint8_t sw, uint8_t pre) {
				if (!edge) return got == pre;
				return got == sw || got == pre;
			};
			if (!okC(u0[i], su0[i], cu0[i]) || !okC(u1[i], su1[i], cu1[i]) ||
			    !okC(v0[i], sv0[i], cv0[i]) || !okC(v1[i], sv1[i], cv1[i])) {
				if (chBad < 6)
					std::cerr << "FAIL DEBLOCK chroma i=" << i << " cx=" << cx
					          << " u0=" << int(u0[i]) << " su0=" << int(su0[i])
					          << " v0=" << int(v0[i]) << " sv0=" << int(sv0[i]) << "\n";
				++chBad;
			} else {
				chExact += 4;
			}
		}
		dbExact += chExact;
		dbBad += chBad;
		std::cout << "DEBLOCK_PRODUCT samples_exact=" << dbExact << " bad=" << dbBad
		          << " edge_px_changed=" << edgeDiff << " chroma_exact=" << chExact
		          << (dbBad == 0 && edgeDiff > 0 ? " PASS\n" : (dbBad == 0 ? " PASS_WEAK\n" : " FAIL\n"));

		if (dbBad != 0) return 1;

		// Switch injected reference to OUR filtered output, disable filter,
		// MC MB(0,0) MV=0 and score against our filtered MB0.
		// BRAM_REF holds luma in a swapped bank that this TB cannot patch
		// in-place after injectRefBram; own-ref loop is tb_mem-proven.
#ifdef USE_BRAM_DPB
		std::cout << "DEBLOCK_OWN_REF_MC skipped on BRAM_REF (tb_mem path covers own-ref)\n";
#else
		for (int ly = 0; ly < 16; ++ly)
			for (int lx = 0; lx < 16; ++lx) {
				s.mem[REF_BASE + (ly)*FRAME_W + lx] = y0[ly * 16 + lx];
				s.mem[REF_BASE + (ly)*FRAME_W + (16 + lx)] = y1[ly * 16 + lx];
			}
		s.top.disable_deblocking_filter_idc = 1;
		const size_t wC = s.writes.size();
		if (!driveP16(s, 0, 0, 0, 0, nullptr, nullptr, nullptr, wC + kSamplesPerMb)) {
			std::cerr << "FAIL DEBLOCK own-ref timeout\n";
			return 1;
		}
		uint8_t yOwn[256], uOwn[64], vOwn[64];
		std::memset(yOwn, 0, sizeof yOwn);
		applyWritesToMb(s.writes, wC, 0, 0, yOwn, uOwn, vOwn);
		long long ownExact = 0, ownBad = 0;
		for (int i = 0; i < 256; ++i) {
			if (yOwn[i] != y0[i]) {
				if (ownBad < 8)
					std::cerr << "FAIL OWN_REF i=" << i << " got=" << int(yOwn[i])
					          << " want=" << int(y0[i]) << "\n";
				++ownBad;
			} else
				++ownExact;
		}
		std::cout << "DEBLOCK_OWN_REF_MC samples_exact=" << ownExact << " bad=" << ownBad
		          << (ownBad == 0 ? " PASS\n" : " FAIL\n");
		if (ownBad != 0) return 1;
#endif
		s.top.disable_deblocking_filter_idc = 1;
	}

#ifdef USE_BRAM_DPB
	std::cout << "BRAM_REF_UNDER_MC cycles=" << s.cycles
	          << " ddr_busy_pulses=" << s.ddr.busy_pulses
	          << " (real MC + contended DDR via h264_dpb_ddr BRAM_REF)\n";

	// ----- REAL DPB READ (no ffmpeg inject into the MC port) -----
	// Populate the product DPB solely via rec_wr + frame_done_req (same path
	// decode writeback uses), then P_Skip MB0 reading through ref_rd_data.
	// Destination memory must match the pattern — not a valid strobe.
	{
		resetDut(s);
		s.ddr.contention = true;
		s.top.disable_deblocking_filter_idc = 1;
		// Non-zero unique pattern so a silent 0-data+fake-valid cannot pass.
		std::vector<uint8_t> pat(FRAME_BYTES);
		for (int y = 0; y < FRAME_H; ++y)
			for (int x = 0; x < FRAME_W; ++x)
				pat[y * FRAME_W + x] = static_cast<uint8_t>(16 + ((x * 3 + y * 5) & 0x7f));
		for (int i = 0; i < C_BYTES; ++i) {
			pat[Y_BYTES + i] = static_cast<uint8_t>(80 + (i & 31));
			pat[Y_BYTES + C_BYTES + i] = static_cast<uint8_t>(140 + (i & 31));
		}
		for (int i = 0; i < FRAME_BYTES; ++i) {
			int guard = 0;
			while (s.top.dpb_rec_wr_full && guard++ < 10000) s.tick();
			if (s.top.dpb_rec_wr_full) {
				std::cerr << "FAIL REAL_DPB_RD: rec_wr_full\n";
				return 1;
			}
			s.top.dpb_rec_wr_en = 1;
			s.top.dpb_rec_wr_addr = static_cast<uint32_t>(i);
			s.top.dpb_rec_wr_data = pat[i];
			s.tick();
			s.top.dpb_rec_wr_en = 0;
		}
		s.top.dpb_frame_done_req = 1;
		s.tick();
		s.top.dpb_frame_done_req = 0;
		int wait = 0;
		while (!s.top.dpb_frame_done_ack && wait++ < 5000000) s.tick();
		if (!s.top.dpb_frame_done_ack || !s.top.dpb_ref_ready) {
			std::cerr << "FAIL REAL_DPB_RD: swap/ref_ready\n";
			return 1;
		}
		// Poison tb_mem so any accidental tb_mem MC path cannot cheat.
		for (size_t i = 0; i < s.mem.size(); ++i) s.mem[i] = 0x5A;
		s.writes.clear();
		const size_t want = kSamplesPerMb;
		if (!driveP16(s, 0, 0, 0, 0, nullptr, nullptr, nullptr, want)) {
			std::cerr << "FAIL REAL_DPB_RD: P_Skip timeout\n";
			return 1;
		}
		uint8_t yb[256], ub[64], vb[64];
		std::memset(yb, 0xA5, sizeof yb);
		std::memset(ub, 0xA5, sizeof ub);
		std::memset(vb, 0xA5, sizeof vb);
		applyWritesToMb(s.writes, 0, 0, 0, yb, ub, vb);
		long long rdExact = 0, rdBad = 0, rdZero = 0;
		for (int ly = 0; ly < 16; ++ly)
			for (int lx = 0; lx < 16; ++lx) {
				const int wantY = pat[ly * FRAME_W + lx];
				const int got = yb[ly * 16 + lx];
				if (got == 0) ++rdZero;
				if (got != wantY) {
					if (rdBad < 6)
						std::cerr << "FAIL REAL_DPB_RD Y lx=" << lx << " ly=" << ly
						          << " got=" << got << " want=" << wantY << "\n";
					++rdBad;
				} else
					++rdExact;
			}
		for (int cy = 0; cy < 8; ++cy)
			for (int cx = 0; cx < 8; ++cx) {
				const int wu = pat[Y_BYTES + cy * C_W + cx];
				const int wv = pat[Y_BYTES + C_BYTES + cy * C_W + cx];
				if (ub[cy * 8 + cx] != wu || vb[cy * 8 + cx] != wv) ++rdBad;
				else rdExact += 2;
			}
		std::cout << "REAL_DPB_RD_NO_INJECT samples_exact=" << rdExact
		          << " samples_bad=" << rdBad << " y_zero=" << rdZero
		          << " (populate=rec_wr+swap, MC via dpb_ddr ref_rd; tb_mem poisoned)\n";
		std::cout << (rdBad == 0 && rdExact == kSamplesPerMb ? "REAL_DPB_RD_PASS\n" : "REAL_DPB_RD_FAIL\n");
		if (rdBad != 0) return 1;
	}
#else
	std::cout << "BRAM_REF_UNDER_MC skipped (tb_mem path); rebuild with -DUSE_BRAM_DPB\n";
	std::cout << "REAL_DPB_RD_NO_INJECT skipped (needs -DUSE_BRAM_DPB / h264_dpb_ddr)\n";
#endif

	if (skipBad != 0 || p16Bad != 0 || nzBad != 0 || mvdBad != 0) return 1;
	if (skipDone < 1 || p16Done < 1) {
		std::cerr << "FAIL vacuous: need both skip and p16 MBs\n";
		return 1;
	}
	std::cout << "PASS pframe ref-inject: skip_mbs=" << skipDone << " p16_mbs=" << p16Done
	          << " nzmv_mbs=" << nzDone << " mvd_mbs=" << mvdDone
	          << " exact_samples=" << (skipExact + p16Exact + nzExact + mvdExact)
	          << " cycles=" << s.cycles << "\n";
	return 0;
}
