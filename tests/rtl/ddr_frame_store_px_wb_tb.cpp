// Hardware-style writeback proof for ddr_frame_store:
//   1) wipe luma plane in DDR model to 0x5A
//   2) stream one 16x16 MB of Y (+U/V) via dec_px_*
//   3) assert destination DDR words changed (not just that WE pulsed)
//
// Stress: continuous rd_active (line refill demand) while writeback is in
// flight — pre-aff853b drain-after-refill could starve WB → y_changed=0.

#include "Vddr_frame_store_px_wb_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBaseQword = kBasePhys >> 3; // 0x0600_0000
constexpr uint32_t kBankStride = 65536u;
constexpr uint32_t kBankStrideQ = kBankStride / 8;
constexpr int kW = 80;
constexpr int kH = 48;
constexpr int kYBytes = kW * kH; // 3840
constexpr int kCStride = kW / 2;
constexpr int kCBytes = kCStride * (kH / 2);

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i) q |= (uint64_t)v << (8 * i);
	return q;
}

struct Ddr {
	static const int WORDS = (2 * kBankStride) / 8; // two banks
	uint64_t mem[WORDS];
	int busy_hold = 0;
	struct Beat {
		uint64_t d;
		int lat;
	};
	std::vector<Beat> q;
	int we_pulses = 0;
	int rd_pulses = 0;

	Ddr() { std::memset(mem, 0, sizeof(mem)); }

	int idx_of(uint32_t addr_q) const {
		if (addr_q < kBaseQword) return -1;
		const uint32_t off = addr_q - kBaseQword;
		if (off >= (uint32_t)WORDS) return -1;
		return (int)off;
	}

	void wipe_plane(int bank, int byte_off, int nbytes, uint8_t v) {
		const int base = bank * (int)kBankStrideQ + byte_off / 8;
		const int nq = nbytes / 8;
		for (int i = 0; i < nq; ++i) mem[base + i] = pack8(v);
	}

	void wipe_i420(int bank, uint8_t y, uint8_t u, uint8_t v) {
		wipe_plane(bank, 0, kYBytes, y);
		wipe_plane(bank, kYBytes, kCBytes, u);
		wipe_plane(bank, kYBytes + kCBytes, kCBytes, v);
	}

	int plane_changed_count(int bank, int byte_off, int nbytes, uint8_t wipe) const {
		const int base = bank * (int)kBankStrideQ + byte_off / 8;
		const int nq = nbytes / 8;
		const uint64_t want = pack8(wipe);
		int n = 0;
		for (int i = 0; i < nq; ++i)
			if (mem[base + i] != want) ++n;
		return n;
	}

	int y_changed_count(int bank, uint8_t wipe) const {
		return plane_changed_count(bank, 0, kYBytes, wipe);
	}

	// Count qwords in one MB rectangle that match a constant fill.
	int mb_plane_exact_qwords(int bank, int plane, int mbx, int mby, uint8_t v) const {
		const int base = bank * (int)kBankStrideQ;
		const uint64_t exp = pack8(v);
		int n = 0, total = 0;
		if (plane == 0) {
			const int x0 = mbx * 16, y0 = mby * 16;
			for (int ly = 0; ly < 16; ++ly) {
				const int row = y0 + ly;
				const int q0 = (row * kW + x0) / 8;
				// 16 px = 2 qwords
				for (int q = 0; q < 2; ++q) {
					++total;
					if (mem[base + q0 + q] == exp) ++n;
				}
			}
		} else {
			const int poff = (plane == 1) ? kYBytes : (kYBytes + kCBytes);
			const int x0 = mbx * 8, y0 = mby * 8;
			for (int cy = 0; cy < 8; ++cy) {
				const int row = y0 + cy;
				const int q0 = (poff + row * kCStride + x0) / 8;
				// 8 px = 1 qword
				++total;
				if (mem[base + q0] == exp) ++n;
			}
		}
		(void)total;
		return n;
	}

	void step(Vddr_frame_store_px_wb_tb* t) {
		t->DDRAM_DOUT_READY = 0;
		t->DDRAM_DOUT = 0;
		if (busy_hold > 0) {
			t->DDRAM_BUSY = 1;
			--busy_hold;
		} else {
			t->DDRAM_BUSY = (q.size() >= 16) ? 1 : 0;
		}
		if (!q.empty()) {
			for (auto& b : q) --b.lat;
			if (q.front().lat <= 0) {
				t->DDRAM_DOUT_READY = 1;
				t->DDRAM_DOUT = q.front().d;
				q.erase(q.begin());
			}
		}
		if (t->DDRAM_WE && !t->DDRAM_BUSY) {
			const int i = idx_of((uint32_t)t->DDRAM_ADDR);
			if (i >= 0) {
				mem[i] = t->DDRAM_DIN;
				++we_pulses;
			}
		}
		if (t->DDRAM_RD && !t->DDRAM_BUSY) {
			const int i = idx_of((uint32_t)t->DDRAM_ADDR);
			const int burst = t->DDRAM_BURSTCNT ? t->DDRAM_BURSTCNT : 1;
			++rd_pulses;
			for (int b = 0; b < burst; ++b) {
				uint64_t d = 0;
				if (i >= 0) {
					const int ii = i + b;
					if (ii >= 0 && ii < WORDS) d = mem[ii];
				}
				q.push_back({d, 2 + b});
			}
		}
	}
};

void tick(Vddr_frame_store_px_wb_tb* t, Ddr& ddr) {
	t->clk = 0;
	t->eval();
	for (int i = 0; i < 4; ++i) {
		t->clk_ddr = 0;
		t->eval();
		ddr.step(t);
		t->clk_ddr = 1;
		t->eval();
		ddr.step(t);
	}
	t->clk = 1;
	t->eval();
	for (int i = 0; i < 4; ++i) {
		t->clk_ddr = 0;
		t->eval();
		ddr.step(t);
		t->clk_ddr = 1;
		t->eval();
		ddr.step(t);
	}
}

void push_px(Vddr_frame_store_px_wb_tb* t, Ddr& ddr, int plane, int x, int y, uint8_t v) {
	t->dec_px_wr_en = 1;
	t->dec_px_plane = plane & 3;
	t->dec_px_x = x;
	t->dec_px_y = y;
	t->dec_px_data = v;
	tick(t, ddr);
	t->dec_px_wr_en = 0;
}

void stream_mb(Vddr_frame_store_px_wb_tb* t, Ddr& ddr, int mbx, int mby,
               uint8_t yval, uint8_t uval, uint8_t vval) {
	const int x0 = mbx * 16, y0 = mby * 16;
	for (int ly = 0; ly < 16; ++ly)
		for (int lx = 0; lx < 16; ++lx) push_px(t, ddr, 0, x0 + lx, y0 + ly, yval);
	// Full U plane then full V — one shared px_acc; do not interleave planes
	// mid-qword or lanes never reach 7 and chroma is silently never pushed.
	for (int cy = 0; cy < 8; ++cy)
		for (int cx = 0; cx < 8; ++cx)
			push_px(t, ddr, 1, mbx * 8 + cx, mby * 8 + cy, uval);
	for (int cy = 0; cy < 8; ++cy)
		for (int cx = 0; cx < 8; ++cx)
			push_px(t, ddr, 2, mbx * 8 + cx, mby * 8 + cy, vval);
}

}  // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* t = new Vddr_frame_store_px_wb_tb;
	Ddr ddr;

	t->reset = 1;
	t->dec_px_wr_en = 0;
	t->dec_px_plane = 0;
	t->dec_px_x = 0;
	t->dec_px_y = 0;
	t->dec_px_data = 0;
	t->vsync_pulse = 0;
	t->rd_active = 0;
	t->rd_x = 0;
	t->rd_y = 0;
	t->DDRAM_BUSY = 0;
	t->DDRAM_DOUT = 0;
	t->DDRAM_DOUT_READY = 0;
	for (int i = 0; i < 16; ++i) tick(t, ddr);
	t->reset = 0;
	for (int i = 0; i < 32; ++i) tick(t, ddr);

	// Poison Y+U+V so a silent chroma drop cannot masquerade as wipe residue.
	ddr.wipe_i420(0, 0x5A, 0x3C, 0xC3);
	ddr.wipe_i420(1, 0x5A, 0x3C, 0xC3);
	if (ddr.y_changed_count(0, 0x5A) != 0 || ddr.y_changed_count(1, 0x5A) != 0) {
		std::printf("FAIL: wipe did not stick\n");
		return 1;
	}
	std::printf("WIPE bank0/1 I420 Y=0x5A U=0x3C V=0xC3 ok\n");

	// Stress refill contention during writeback (AW=5 chroma-drop class).
	t->rd_active = 1;
	t->rd_x = 0;
	t->rd_y = 0;
	// Extra bus stalls so px_fifo (async_fifo M10K FWFT) must absorb backlog.
	ddr.busy_hold = 0;

	// Four MBs: fills > one MB of luma qwords so AW=8 depth + chroma tail matter.
	// Distinct U/V per MB prove chroma pushes were not dropped.
	const uint8_t kY[4] = {0xA5, 0x5A, 0x11, 0xEE};
	const uint8_t kU[4] = {0x10, 0x20, 0x30, 0x40};
	const uint8_t kV[4] = {0xF0, 0xE0, 0xD0, 0xC0};
	for (int m = 0; m < 4; ++m) {
		// Inject periodic busy so WB and refill contend on the same master.
		if ((m & 1) == 0) ddr.busy_hold = 12;
		stream_mb(t, ddr, m, 0, kY[m], kU[m], kV[m]);
	}

	for (int i = 0; i < 60000; ++i) {
		t->rd_x = (t->rd_x + 1) % 64;
		if (t->rd_x == 0) t->rd_y = (t->rd_y + 1) % 48;
		if ((i % 17) == 0) ddr.busy_hold = 3;
		tick(t, ddr);
	}

	const int bank = t->disp_bank ? 1 : 0;
	const int chY = ddr.plane_changed_count(bank, 0, kYBytes, 0x5A);
	const int chU = ddr.plane_changed_count(bank, kYBytes, kCBytes, 0x3C);
	const int chV = ddr.plane_changed_count(bank, kYBytes + kCBytes, kCBytes, 0xC3);
	const int drops = (int)t->px_fifo_drop_count;
	std::printf("AFTER_MBS disp_bank=%d we_pulses=%d rd_pulses=%d "
	            "changed Y=%d U=%d V=%d px_fifo_drops=%d\n",
	            bank, ddr.we_pulses, ddr.rd_pulses, chY, chU, chV, drops);

	if (ddr.we_pulses == 0) {
		std::printf("FAIL: no DDRAM_WE — writeback never reached DDR master\n");
		return 1;
	}
	if (chY == 0) {
		std::printf("FAIL: y_changed=0 on disp_bank=%d (HW PASS_TELEMETRY_NO_WRITEBACK symptom)\n", bank);
		return 1;
	}
	if (chU == 0 || chV == 0) {
		std::printf("FAIL: chroma plane still wipe poison — pushes dropped (AW=5 class)\n");
		return 1;
	}
	if (drops != 0) {
		std::printf("FAIL: px_fifo_drop_count=%d (full ignored / depth regression)\n", drops);
		return 1;
	}

	// Exact per-MB Y/U/V qwords in destination memory (not WE pulses).
	// Y MB: 16 rows * 2 qwords = 32; U/V MB: 8 rows * 1 qword = 8.
	for (int m = 0; m < 4; ++m) {
		const int yq = ddr.mb_plane_exact_qwords(bank, 0, m, 0, kY[m]);
		const int uq = ddr.mb_plane_exact_qwords(bank, 1, m, 0, kU[m]);
		const int vq = ddr.mb_plane_exact_qwords(bank, 2, m, 0, kV[m]);
		std::printf("MB%d exact_qwords Y=%d/32 U=%d/8 V=%d/8\n", m, yq, uq, vq);
		if (yq != 32 || uq != 8 || vq != 8) {
			std::printf("FAIL: MB%d dest incomplete Y=%d U=%d V=%d (FWFT/chroma drop)\n",
			            m, yq, uq, vq);
			return 1;
		}
	}

	// Read-side: vsync should arm has_frame from dec_px_seen; line refill from
	// same disp_bank that writeback targeted.
	t->vsync_pulse = 1;
	tick(t, ddr);
	t->vsync_pulse = 0;
	for (int i = 0; i < 8000; ++i) {
		t->rd_active = 1;
		t->rd_x = i % 16;
		t->rd_y = (i / 16) % 16;
		tick(t, ddr);
	}
	std::printf("READSIDE has_frame=%d rd_rgb=%u,%u,%u\n", (int)t->has_frame,
	            (unsigned)t->rd_r, (unsigned)t->rd_g, (unsigned)t->rd_b);

	std::printf("PASS ddr_frame_store px_wb M10K-FWFT: 4MB YUV exact under contention "
	            "drops=0 bank%d WE=%d Ych=%d Uch=%d Vch=%d\n",
	            bank, ddr.we_pulses, chY, chU, chV);
	delete t;
	return 0;
}
