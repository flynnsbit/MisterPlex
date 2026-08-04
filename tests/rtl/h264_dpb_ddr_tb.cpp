// DDR-resident DPB unit tests (Verilator).
// Positive: slot List0 order, RMW via byte bridge, window fill matches DDR.
// Negative: wrong eviction / small window must fail when FAULT macros set.
#include "Vh264_dpb_ddr_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vh264_dpb_ddr_tb_top* t) {
	t->clk = 0;
	t->eval();
	main_time++;
	t->clk = 1;
	t->eval();
	main_time++;
}

// Simple DDR model: 64-bit words keyed by qword phys addr (byte_addr>>3).
struct DdrModel {
	// Sparse map via vector of pages would be large; use unordered for TB.
	// For small tests, flat array covering DPB region + small WC region.
	static constexpr uint32_t kBase = 0x30800000u;
	static constexpr size_t kBytes = 0x780000u; // 5 * 0x180000
	std::vector<uint8_t> mem;
	DdrModel() : mem(kBytes, 0) {}
	bool in_range(uint32_t phys, uint32_t len = 1) const {
		if (phys < kBase) return false;
		return phys + len <= kBase + kBytes;
	}
	uint8_t rd8(uint32_t phys) const {
		if (!in_range(phys)) return 0;
		return mem[phys - kBase];
	}
	void wr8(uint32_t phys, uint8_t v) {
		if (!in_range(phys)) return;
		mem[phys - kBase] = v;
	}
	uint64_t rd64(uint32_t qaddr) const {
		uint32_t phys = qaddr << 3;
		uint64_t d = 0;
		for (int i = 0; i < 8; i++)
			d |= (uint64_t)rd8(phys + i) << (8 * i);
		return d;
	}
	void wr64(uint32_t qaddr, uint64_t data, uint8_t be) {
		uint32_t phys = qaddr << 3;
		for (int i = 0; i < 8; i++) {
			if (be & (1u << i))
				wr8(phys + i, (data >> (8 * i)) & 0xff);
		}
	}
};

// Tiny WC frame store at base 0 (64x64 I420 = 6144 bytes).
struct TinyFrame {
	static constexpr int W = 64, H = 64;
	static constexpr int YB = W * H;
	static constexpr int CB = (W / 2) * (H / 2);
	std::vector<uint8_t> mem;
	TinyFrame() : mem(YB + 2 * CB, 0) {
		for (int y = 0; y < H; y++)
			for (int x = 0; x < W; x++)
				mem[y * W + x] = (uint8_t)((x * 3 + y * 5) & 0xff);
		for (int y = 0; y < H / 2; y++)
			for (int x = 0; x < W / 2; x++) {
				mem[YB + y * (W / 2) + x] = (uint8_t)(16 + x + y);
				mem[YB + CB + y * (W / 2) + x] = (uint8_t)(32 + x * 2 + y);
			}
	}
	uint64_t rd64(uint32_t qaddr) const {
		uint32_t phys = qaddr << 3;
		uint64_t d = 0;
		for (int i = 0; i < 8; i++) {
			uint8_t b = (phys + i < mem.size()) ? mem[phys + i] : 0;
			d |= (uint64_t)b << (8 * i);
		}
		return d;
	}
	uint8_t at_y(int x, int y) const {
		if (x < 0) x = 0;
		if (y < 0) y = 0;
		if (x >= W) x = W - 1;
		if (y >= H) y = H - 1;
		return mem[y * W + x];
	}
};

static int g_fail = 0;
#define CHECK(cond, msg)                                                       \
	do {                                                                       \
		if (!(cond)) {                                                         \
			std::fprintf(stderr, "FAIL: %s\n", msg);                           \
			g_fail++;                                                          \
		} else {                                                               \
			std::printf("OK: %s\n", msg);                                      \
		}                                                                      \
	} while (0)

static void test_slot_mgr(Vh264_dpb_ddr_tb_top* t, bool expect_wrong_evict_fault) {
	t->reset = 1;
	t->sm_idr = 0;
	t->sm_frame_done = 0;
	t->sm_frame_num = 0;
	for (int i = 0; i < 4; i++) tick(t);
	t->reset = 0;
	for (int i = 0; i < 2; i++) tick(t);

	// IDR
	t->sm_idr = 1;
	t->sm_frame_num = 0;
	tick(t);
	t->sm_idr = 0;
	tick(t);
	CHECK(t->sm_current_base == 0x30800000u, "IDR current = slot0 base");
	CHECK(t->sm_ref_ready == 0, "IDR clears ref_ready");
	CHECK(t->sm_ref_count == 0, "IDR ref_count=0");

	// Promote frames 0..4 (5 promotes fill 4 refs + new current; 5th promotes force evict)
	uint32_t last_ref0 = 0;
	for (int f = 0; f < 6; f++) {
		t->sm_frame_num = (uint16_t)(f + 1);
		t->sm_frame_done = 1;
		tick(t);
		t->sm_frame_done = 0;
		for (int k = 0; k < 2; k++) tick(t);
		if (f == 0) {
			CHECK(t->sm_ref_ready == 1, "first promote sets ref_ready");
			CHECK(t->sm_ref_count == 1, "one ref after first promote");
			CHECK(t->sm_ref_base0 == 0x30800000u, "List0[0]=slot0 after first");
			last_ref0 = t->sm_ref_base0;
		}
		if (f >= 1) {
			// Most recent promoted slot becomes List0[0]
			CHECK(t->sm_ref_base0 != 0, "List0[0] non-zero");
			// Newest should differ from previous oldest path
			last_ref0 = t->sm_ref_base0;
		}
		(void)last_ref0;
	}
	// After 6 promotes from IDR: slots cycle with eviction.
	CHECK(t->sm_ref_count >= 1 && t->sm_ref_count <= 4, "ref_count in 1..4");
	CHECK(t->sm_alloc_error == 0, "no alloc_error in sliding window");

	// Positive: List0[0] is the most recently promoted frame's slot base.
	// After loop, last promote made previous current into newest ref.
	// We cannot easily know slot without tracing; check bases are in DPB map.
	auto in_dpb = [](uint32_t b) {
		return b >= 0x30800000u && b < 0x30F80000u && ((b - 0x30800000u) % 0x180000u) == 0;
	};
	CHECK(in_dpb(t->sm_ref_base0), "ref_base0 on slot grid");
	CHECK(in_dpb(t->sm_current_base), "current_base on slot grid");

	if (expect_wrong_evict_fault) {
		// Fill 4 refs + 1 current (no free), promote once more → eviction.
		// Capture current before that promote:
		//   GOOD: becomes List0[0] (newest short-term ref)
		//   FAULT: chosen as victim → absent from List0
		t->reset = 1;
		for (int i = 0; i < 4; i++) tick(t);
		t->reset = 0;
		t->sm_idr = 1;
		t->sm_frame_num = 0;
		tick(t);
		t->sm_idr = 0;
		tick(t);
		for (int f = 0; f < 4; f++) {
			t->sm_frame_num = (uint16_t)(f + 1);
			t->sm_frame_done = 1;
			tick(t);
			t->sm_frame_done = 0;
			tick(t);
		}
		uint32_t just_promoted = t->sm_current_base;
		t->sm_frame_num = 5;
		t->sm_frame_done = 1;
		tick(t);
		t->sm_frame_done = 0;
		tick(t);
		bool in_list = (t->sm_ref_base0 == just_promoted) ||
		               (t->sm_ref_base1 == just_promoted) ||
		               (t->sm_ref_base2 == just_promoted) ||
		               (t->sm_ref_base3 == just_promoted);
		CHECK(!in_list, "FAULT: just-promoted newest was evicted (negative)");
		CHECK(t->sm_ref_base0 != just_promoted,
		      "FAULT: List0[0] is not the just-promoted frame");
	} else {
		// Good path: after filling, force eviction of OLDEST — List0[0] (newest) remains.
		t->reset = 1;
		for (int i = 0; i < 4; i++) tick(t);
		t->reset = 0;
		t->sm_idr = 1;
		tick(t);
		t->sm_idr = 0;
		tick(t);
		for (int f = 0; f < 4; f++) {
			t->sm_frame_done = 1;
			tick(t);
			t->sm_frame_done = 0;
			tick(t);
		}
		// 4 refs + 1 cur. Promote current → must become List0[0]; oldest drops.
		uint32_t just_promoted = t->sm_current_base;
		uint32_t oldest = t->sm_ref_base3;
		t->sm_frame_done = 1;
		tick(t);
		t->sm_frame_done = 0;
		tick(t);
		bool oldest_gone = (t->sm_ref_base0 != oldest) && (t->sm_ref_base1 != oldest) &&
		                   (t->sm_ref_base2 != oldest) && (t->sm_ref_base3 != oldest);
		CHECK(t->sm_ref_base0 == just_promoted,
		      "positive: just-promoted frame is List0[0]");
		CHECK(oldest_gone, "positive: oldest ref evicted");
	}
}

static void test_byte_bridge(Vh264_dpb_ddr_tb_top* t) {
	DdrModel ddr;
	t->reset = 1;
	t->br_mem_we = 0;
	t->br_mem_rd = 0;
	t->br_ddr_busy = 0;
	t->br_ddr_dout = 0;
	t->br_ddr_dout_ready = 0;
	for (int i = 0; i < 4; i++) tick(t);
	t->reset = 0;
	for (int i = 0; i < 2; i++) tick(t);

	const uint32_t base = 0x30800000u;
	// Write 16 sequential bytes
	for (int i = 0; i < 16; i++) {
		t->br_mem_we = 1;
		t->br_mem_waddr = base + i;
		t->br_mem_wdata = (uint8_t)(0xA0 + i);
		// Service DDR
		t->br_ddr_busy = 0;
		t->br_ddr_dout_ready = 0;
		tick(t);
		if (t->br_ddr_we) {
			ddr.wr64(t->br_ddr_addr, t->br_ddr_din, t->br_ddr_be);
		}
		t->br_mem_we = 0;
		// drain pending
		for (int k = 0; k < 4; k++) {
			tick(t);
			if (t->br_ddr_we)
				ddr.wr64(t->br_ddr_addr, t->br_ddr_din, t->br_ddr_be);
		}
	}
	// Flush tail
	for (int k = 0; k < 8; k++) {
		tick(t);
		if (t->br_ddr_we)
			ddr.wr64(t->br_ddr_addr, t->br_ddr_din, t->br_ddr_be);
	}

	int wr_ok = 0;
	for (int i = 0; i < 16; i++) {
		if (ddr.rd8(base + i) == (uint8_t)(0xA0 + i)) wr_ok++;
	}
	CHECK(wr_ok == 16, "byte bridge write returns exact bytes in DDR model");

	// Read back — cache hits return rvalid on the mem_rd cycle; misses hold
	// ddr_rd until dout_ready.
	int rd_ok = 0;
	for (int i = 0; i < 16; i++) {
		t->br_mem_rd = 1;
		t->br_mem_raddr = base + i;
		t->br_ddr_dout_ready = 0;
		t->br_ddr_busy = 0;
		tick(t);
		t->br_mem_rd = 0;
		bool got = false;
		// Cache-hit path: rvalid already high after the request tick.
		if (t->br_mem_rvalid) {
			if (t->br_mem_rdata == (uint8_t)(0xA0 + i))
				rd_ok++;
			else
				std::fprintf(stderr, "  bridge rd[%d] got=0x%02x want=0x%02x\n",
				             i, t->br_mem_rdata, 0xA0 + i);
			got = true;
		}
		for (int k = 0; k < 64 && !got; k++) {
			if (t->br_ddr_rd) {
				t->br_ddr_dout = ddr.rd64((uint32_t)t->br_ddr_addr);
				t->br_ddr_dout_ready = 1;
			} else {
				t->br_ddr_dout_ready = 0;
			}
			if (t->br_ddr_we)
				ddr.wr64((uint32_t)t->br_ddr_addr, t->br_ddr_din, t->br_ddr_be);
			tick(t);
			if (t->br_mem_rvalid) {
				if (t->br_mem_rdata == (uint8_t)(0xA0 + i))
					rd_ok++;
				else
					std::fprintf(stderr, "  bridge rd[%d] got=0x%02x want=0x%02x\n",
					             i, t->br_mem_rdata, 0xA0 + i);
				got = true;
			}
		}
		if (!got)
			std::fprintf(stderr, "  bridge rd[%d] timeout rvalid\n", i);
		t->br_ddr_dout_ready = 0;
	}
	CHECK(rd_ok == 16, "byte bridge read returns exactly what was written");
}

static void service_wc_ddr(Vh264_dpb_ddr_tb_top* t, TinyFrame& fr) {
	t->wc_ddr_busy = 0;
	t->wc_ddr_dout_ready = 0;
	if (t->wc_ddr_rd) {
		// one cycle later ready
		uint32_t q = t->wc_ddr_addr;
		tick(t);
		t->wc_ddr_dout = fr.rd64(q);
		t->wc_ddr_dout_ready = 1;
		tick(t);
		t->wc_ddr_dout_ready = 0;
	} else {
		tick(t);
	}
}

static void test_ref_win_cache(Vh264_dpb_ddr_tb_top* t, bool expect_small_win_fault) {
	TinyFrame fr;
	t->reset = 1;
	t->wc_ref_ready = 0;
	t->wc_reference_base = 0;
	t->wc_fetch_start = 0;
	t->wc_ddr_busy = 0;
	t->wc_ddr_dout_ready = 0;
	for (int i = 0; i < 4; i++) tick(t);
	t->reset = 0;
	for (int i = 0; i < 2; i++) tick(t);

	t->wc_ref_ready = 1;
	t->wc_reference_base = 0;
	t->wc_fetch_mb_x = 2; // MB at (32,32)
	t->wc_fetch_mb_y = 2;
	t->wc_fetch_part_mode = 0;
	t->wc_fetch_part_idx = 0;
	t->wc_fetch_mv_x = 0; // integer
	t->wc_fetch_mv_y = 0;
	t->wc_fetch_start = 1;
	tick(t);
	t->wc_fetch_start = 0;

	std::vector<uint8_t> win(441, 0);
	int got = 0;
	for (int guard = 0; guard < 200000 && !t->wc_fetch_done; guard++) {
		if (t->wc_luma_window_valid) {
			if (t->wc_luma_window_idx < 441) {
				win[t->wc_luma_window_idx] = t->wc_luma_window_sample;
				got++;
			}
		}
		service_wc_ddr(t, fr);
	}
	CHECK(t->wc_fetch_done == 1, "ref win cache fetch_done");
	CHECK(got == 441, "ref win cache streamed 441 luma samples");

	// Expected: origin = mb*16 = 32, window -2 => window (30,30)..(50,50)
	int origin = 32;
	int match = 0;
	int border_match = 0;
	int border_total = 0;
	for (int r = 0; r < 21; r++) {
		for (int c = 0; c < 21; c++) {
			int x = origin - 2 + c;
			int y = origin - 2 + r;
			uint8_t exp = fr.at_y(x, y);
			uint8_t gotb = win[r * 21 + c];
			if (gotb == exp) match++;
			// Border ring (outside center 16x16)
			bool border = (r < 2 || r >= 19 || c < 2 || c >= 19);
			if (border) {
				border_total++;
				if (gotb == exp) border_match++;
			}
		}
	}
	if (expect_small_win_fault) {
		// Border should NOT fully match (zeros or wrong).
		CHECK(border_match < border_total, "FAULT small win: border mismatches (negative)");
		CHECK(match < 441, "FAULT small win: not full window correct");
	} else {
		CHECK(match == 441, "positive: full 21x21 window matches DDR pattern");
		CHECK(border_match == border_total, "positive: qpel border samples correct");
	}
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	bool fault_evict = false;
	bool fault_small = false;
#ifdef H264_DPB_DDR_FAULT_WRONG_EVICT
	fault_evict = true;
#endif
#ifdef H264_DPB_DDR_FAULT_SMALL_WIN
	fault_small = true;
#endif
	// Also accept CLI for harness without recompile flags in cpp
	for (int i = 1; i < argc; i++) {
		if (std::string(argv[i]) == "--fault-evict") fault_evict = true;
		if (std::string(argv[i]) == "--fault-small") fault_small = true;
	}

	auto* t = new Vh264_dpb_ddr_tb_top;

	// Zero inputs
	t->sm_idr = 0;
	t->sm_frame_done = 0;
	t->sm_frame_num = 0;
	t->br_mem_we = 0;
	t->br_mem_rd = 0;
	t->br_mem_waddr = 0;
	t->br_mem_wdata = 0;
	t->br_mem_raddr = 0;
	t->br_ddr_busy = 0;
	t->br_ddr_dout = 0;
	t->br_ddr_dout_ready = 0;
	t->wc_ref_ready = 0;
	t->wc_reference_base = 0;
	t->wc_fetch_start = 0;
	t->wc_fetch_mb_x = 0;
	t->wc_fetch_mb_y = 0;
	t->wc_fetch_part_mode = 0;
	t->wc_fetch_part_idx = 0;
	t->wc_fetch_mv_x = 0;
	t->wc_fetch_mv_y = 0;
	t->wc_ddr_busy = 0;
	t->wc_ddr_dout = 0;
	t->wc_ddr_dout_ready = 0;

	std::printf("=== h264_dpb_ddr TB fault_evict=%d fault_small=%d ===\n",
	            fault_evict, fault_small);

	if (!fault_small) {
		// Slot tests only on non-small builds (same binary either way for slots)
		test_slot_mgr(t, fault_evict);
		if (!fault_evict)
			test_byte_bridge(t);
	}
	if (!fault_evict)
		test_ref_win_cache(t, fault_small);

	int rc = 0;
	if (fault_evict || fault_small) {
		// Negative twin: must have recorded at least one intentional FAIL check
		// that passed the negative assertion. g_fail counts failed CHECKs.
		// For FAULT builds, the negative CHECK should succeed (g_fail not incremented
		// for that line). If FAULT is broken (acts correct), negative CHECK fails.
		if (g_fail != 0) {
			std::printf("NEGATIVE_TWIN: assertions failed count=%d (FAULT ineffective?)\n",
			            g_fail);
			rc = 1;
		} else {
			std::printf("NEGATIVE_TWIN OK: fault behaviour detected as expected\n");
			rc = 0;
		}
	} else {
		if (g_fail != 0) {
			std::printf("POSITIVE FAILED count=%d\n", g_fail);
			rc = 1;
		} else {
			std::printf("POSITIVE OK\n");
			rc = 0;
		}
	}

	t->final();
	delete t;
	return rc;
}
