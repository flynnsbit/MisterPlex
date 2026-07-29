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

	void wipe_luma(int bank, uint8_t y) {
		const int base = bank * (int)kBankStrideQ;
		const int y_qwords = kYBytes / 8;
		for (int i = 0; i < y_qwords; ++i) mem[base + i] = pack8(y);
	}

	int y_changed_count(int bank, uint8_t wipe) const {
		const int base = bank * (int)kBankStrideQ;
		const int y_qwords = kYBytes / 8;
		const uint64_t want = pack8(wipe);
		int n = 0;
		for (int i = 0; i < y_qwords; ++i)
			if (mem[base + i] != want) ++n;
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

void stream_mb(Vddr_frame_store_px_wb_tb* t, Ddr& ddr, int mbx, int mby, uint8_t yval) {
	const int x0 = mbx * 16, y0 = mby * 16;
	for (int ly = 0; ly < 16; ++ly)
		for (int lx = 0; lx < 16; ++lx) push_px(t, ddr, 0, x0 + lx, y0 + ly, yval);
	for (int cy = 0; cy < 8; ++cy)
		for (int cx = 0; cx < 8; ++cx) {
			push_px(t, ddr, 1, mbx * 8 + cx, mby * 8 + cy, 0x80);
			push_px(t, ddr, 2, mbx * 8 + cx, mby * 8 + cy, 0x80);
		}
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

	ddr.wipe_luma(0, 0x5A);
	ddr.wipe_luma(1, 0x5A);
	if (ddr.y_changed_count(0, 0x5A) != 0 || ddr.y_changed_count(1, 0x5A) != 0) {
		std::printf("FAIL: wipe did not stick\n");
		return 1;
	}
	std::printf("WIPE bank0/1 luma=0x5A ok\n");

	// Stress refill contention during writeback.
	t->rd_active = 1;
	t->rd_x = 0;
	t->rd_y = 0;

	const uint8_t kY = 0xA5;
	stream_mb(t, ddr, 0, 0, kY);

	for (int i = 0; i < 30000; ++i) {
		t->rd_x = (t->rd_x + 1) % 64;
		if (t->rd_x == 0) t->rd_y = (t->rd_y + 1) % 48;
		tick(t, ddr);
	}

	const int bank = t->disp_bank ? 1 : 0;
	const int ch0 = ddr.y_changed_count(0, 0x5A);
	const int ch1 = ddr.y_changed_count(1, 0x5A);
	std::printf("AFTER_MB disp_bank=%d we_pulses=%d rd_pulses=%d y_changed bank0=%d bank1=%d\n",
	            bank, ddr.we_pulses, ddr.rd_pulses, ch0, ch1);

	if (ddr.we_pulses == 0) {
		std::printf("FAIL: no DDRAM_WE — writeback never reached DDR master\n");
		return 1;
	}
	const int ch = bank ? ch1 : ch0;
	if (ch == 0) {
		std::printf("FAIL: y_changed=0 on disp_bank=%d (HW PASS_TELEMETRY_NO_WRITEBACK symptom)\n", bank);
		return 1;
	}

	const int base = bank * (int)kBankStrideQ;
	const uint64_t got = ddr.mem[base + 0];
	const uint64_t exp = pack8(kY);
	if (got != exp) {
		std::printf("FAIL: DDR luma qword0 got=0x%016llx want=0x%016llx\n",
		            (unsigned long long)got, (unsigned long long)exp);
		return 1;
	}

	const int u_off = kYBytes / 8;
	const uint64_t ugot = ddr.mem[base + u_off];
	const uint64_t uexp = pack8(0x80);
	if (ugot != uexp) {
		std::printf("FAIL: DDR U qword0 got=0x%016llx want=0x%016llx\n",
		            (unsigned long long)ugot, (unsigned long long)uexp);
		return 1;
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

	std::printf("PASS ddr_frame_store px_wb: dest Y changed=%d qwords bank%d WE=%d "
	            "first_Y_OK first_U_OK\n",
	            ch, bank, ddr.we_pulses);
	delete t;
	return 0;
}
