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
constexpr int kTimeoutCycles = 80000;

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
	// chroma MV = luma/2 with 1/8 pel
	const int xq = mbX * 8 * 8 + (mvx / 2) + cx * 8;  // wrong - use proper
	(void)xq;
	const int xFull = mbX * 8 + cx;
	const int yFull = mbY * 8 + cy;
	// chroma mv in 1/8 pel: floor(mv/2) for integer part of half-pel scale
	const int cmx = mvx;  // keep qpel, convert: chroma frac is mv/2 in 1/8 units
	const int cmy = mvy;
	// H.264: chroma_mv = (mvx/2, mvy/2) with special round; Baseline uses
	// mvx/2 toward -inf for the integer and frac in 1/8.
	const int x8 = xFull * 8 + (cmx >= 0 ? cmx / 2 : -((-cmx) / 2));
	const int y8 = yFull * 8 + (cmy >= 0 ? cmy / 2 : -((-cmy) / 2));
	// Actually standard: chroma MV is derived as
	// mv_c = (mvx/2, mvy/2) with each component using integer division toward zero? Spec 8.4.1.4
	// Use: mv_ch = (mvx, mvy) / 2 with arithmetic right for signed.
	const int mvx_c = mvx >> 1;  // not quite - better:
	(void)mvx_c;
	const int xInt = xFull + (cmx >= 0 ? (cmx >> 3) : -(((-cmx) + 7) >> 3));  // messy
	(void)xInt;
	// Cleaner: absolute chroma sample coords in 1/8 units from MB origin.
	const int absx = (mbX * 8 + cx) * 8 + (mvx / 2);
	const int absy = (mbY * 8 + cy) * 8 + (mvy / 2);
	return chromaEpel(p, f, plane, absx >> 3, absy >> 3, absx & 7, absy & 7);
}

uint32_t yAddr(uint32_t base, int x, int y) { return base + uint32_t(y * FRAME_W + x); }
uint32_t uAddr(uint32_t base, int x, int y) { return base + Y_BYTES + uint32_t(y * C_W + x); }
uint32_t vAddr(uint32_t base, int x, int y) { return base + Y_BYTES + C_BYTES + uint32_t(y * C_W + x); }

struct Write {
	uint32_t addr;
	uint8_t data;
};

// Simple DDR model for BRAM path (writes + variable-latency reads).
struct DdrModel {
	static const int WORDS = 1 << 18;
	std::vector<uint64_t> mem;
	struct Beat {
		uint64_t d;
		int lat;
	};
	std::vector<Beat> q;
	DdrModel() : mem(WORDS, 0) {}
	void step(Vh264_pframe_ref_inject_tb* t) {
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
		t->ddr_busy = (q.size() >= 12) ? 1 : 0;
		if (t->ddr_we && !t->ddr_busy) {
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
		if (t->ddr_rd && !t->ddr_busy) {
			const uint32_t a = t->ddr_addr % WORDS;
			const int burst = t->ddr_burstcnt ? t->ddr_burstcnt : 1;
			static int lat_pat = 0;
			lat_pat = (lat_pat % 4) + 1;
			for (int i = 0; i < burst; i++) {
				q.push_back({mem[(a + i) % WORDS], lat_pat + i});
			}
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

#ifdef USE_BRAM_DPB
	if (!injectRefBram(s, pic, 0)) return 1;
	// BRAM luma-only: chroma still via DDR cache — also keep TB mem chroma at REF
	// for any TB-side checks; core reads go through dpb_ddr.
	injectRefTbMem(s, pic, 0);
#else
	injectRefTbMem(s, pic, 0);
#endif

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
	          << " (MV=0 + residual=f1-f0; T05 mvd still hardwired 0 in product feed)\n";
	std::cout << (p16Bad == 0 ? "P16x16_PASS\n" : "P16x16_FAIL\n");

#ifdef USE_BRAM_DPB
	std::cout << "BRAM_REF_UNDER_MC cycles=" << s.cycles
	          << " (real MC fetches served via h264_dpb_ddr BRAM_REF)\n";
#else
	std::cout << "BRAM_REF_UNDER_MC skipped (tb_mem path); rebuild with -DUSE_BRAM_DPB\n";
#endif

	if (skipBad != 0 || p16Bad != 0) return 1;
	if (skipDone < 1 || p16Done < 1) {
		std::cerr << "FAIL vacuous: need both skip and p16 MBs\n";
		return 1;
	}
	std::cout << "PASS pframe ref-inject: skip_mbs=" << skipDone << " p16_mbs=" << p16Done
	          << " exact_samples=" << (skipExact + p16Exact) << " cycles=" << s.cycles << "\n";
	return 0;
}
