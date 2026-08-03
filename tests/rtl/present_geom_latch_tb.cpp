// present_geom_latch RBG: reset-safe, accept PLXG pack, reject bad magic.
#include "Vpresent_geom_latch_tb.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>

namespace {
constexpr uint32_t kMagic = 0x504C5847u; // PLXG
constexpr uint32_t kBadMagic = 0x504C5857u; // PLXW (bitstream — must NOT latch)

uint64_t q0(uint32_t magic, bool win, bool geom, uint16_t seq) {
	return uint64_t(magic) | (uint64_t(win) << 32) | (uint64_t(geom) << 33) |
	       (uint64_t(seq) << 48);
}
uint64_t pack4x11(uint16_t a, uint16_t b, uint16_t c, uint16_t d) {
	return uint64_t(a & 0x7ff) | (uint64_t(b & 0x7ff) << 16) |
	       (uint64_t(c & 0x7ff) << 32) | (uint64_t(d & 0x7ff) << 48);
}
uint64_t pack_stride(uint16_t ystride, uint16_t cstride, uint16_t dw, uint16_t dh) {
	return uint64_t(ystride & 0xfff) | (uint64_t(cstride & 0x7ff) << 16) |
	       (uint64_t(dw & 0x7ff) << 32) | (uint64_t(dh & 0x7ff) << 48);
}

struct Sim {
	Vpresent_geom_latch_tb top{};
	void tick() {
		top.clk = 0; top.eval();
		top.clk = 1; top.eval();
	}
	void resetPulse() {
		top.reset = 1; top.wr_en = 0; top.commit = 0;
		for (int i = 0; i < 4; ++i) tick();
		top.reset = 0;
		for (int i = 0; i < 2; ++i) tick();
	}
	void writeQ(int idx, uint64_t data) {
		top.wr_en = 1; top.wr_idx = idx; top.wr_data = data; top.commit = 0;
		tick();
		top.wr_en = 0;
		tick();
	}
	void doCommit() {
		top.commit = 1; tick();
		top.commit = 0; tick();
	}
	void loadPack(uint32_t magic, bool win, bool geom, uint16_t seq,
	              int cw, int ch, int coded_w, int coded_h, int ys, int cs) {
		writeQ(0, q0(magic, win, geom, seq));
		writeQ(1, pack4x11(cw, ch, 0, 0));
		writeQ(2, pack4x11(0, 0, coded_w, coded_h));
		writeQ(3, pack_stride(ys, cs, coded_w, coded_h));
		writeQ(4, pack4x11(0, 0, 0, 0));
		doCommit();
	}
};
} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Sim s;
	int fails = 0;

	// A) reset → all safe zero
	s.resetPulse();
	std::cout << "CASE reset_safe EXECUTED win=" << int(s.top.win_enable)
	          << " geom=" << int(s.top.geom_enable)
	          << " valid=" << int(s.top.live_valid) << "\n";
	if (s.top.win_enable || s.top.geom_enable || s.top.live_valid ||
	    s.top.y_stride != 0 || s.top.coded_w != 0) {
		std::cerr << "FAIL reset_safe: outputs not zero\n";
		++fails;
	} else {
		std::cout << "PASS reset_safe\n";
	}

	// B) good PLXG 720p pack
	s.loadPack(kMagic, true, true, 1, 1280, 720, 1280, 720, 1280, 640);
	std::cout << "CASE plxg_720 EXECUTED win=" << int(s.top.win_enable)
	          << " geom=" << int(s.top.geom_enable)
	          << " cw=" << int(s.top.content_w) << " ch=" << int(s.top.content_h)
	          << " coded=" << int(s.top.coded_w) << "x" << int(s.top.coded_h)
	          << " y_stride=" << int(s.top.y_stride)
	          << " c_stride=" << int(s.top.chroma_stride)
	          << " seq=" << int(s.top.live_seq) << "\n";
	if (!s.top.win_enable || !s.top.geom_enable || int(s.top.content_w) != 1280 ||
	    int(s.top.content_h) != 720 || int(s.top.coded_w) != 1280 ||
	    int(s.top.y_stride) != 1280 || int(s.top.chroma_stride) != 640 ||
	    int(s.top.live_seq) != 1) {
		std::cerr << "FAIL plxg_720: fields mismatch\n";
		++fails;
	} else {
		std::cout << "PASS plxg_720\n";
	}

	// C) negative: PLXW magic must not overwrite live 720p state
	s.loadPack(kBadMagic, false, false, 2, 320, 240, 624, 480, 624, 312);
	std::cout << "CASE neg_plxw_magic EXECUTED win=" << int(s.top.win_enable)
	          << " geom=" << int(s.top.geom_enable)
	          << " y_stride=" << int(s.top.y_stride)
	          << " seq=" << int(s.top.live_seq) << "\n";
	if (!s.top.win_enable || !s.top.geom_enable || int(s.top.y_stride) != 1280 ||
	    int(s.top.live_seq) != 1) {
		std::cerr << "FAIL neg_plxw_magic: bad magic overwrote live state\n";
		++fails;
	} else {
		std::cout << "PASS neg_plxw_magic: PLXW rejected, 720p state held\n";
	}

	// D) new seq updates
	s.loadPack(kMagic, true, true, 3, 320, 240, 320, 240, 320, 160);
	std::cout << "CASE plxg_seq3 EXECUTED cw=" << int(s.top.content_w)
	          << " ys=" << int(s.top.y_stride) << " seq=" << int(s.top.live_seq) << "\n";
	if (int(s.top.content_w) != 320 || int(s.top.y_stride) != 320 ||
	    int(s.top.live_seq) != 3) {
		std::cerr << "FAIL plxg_seq3\n";
		++fails;
	} else {
		std::cout << "PASS plxg_seq3\n";
	}

	std::cout << "PLXG_LATCH_DONE fails=" << fails << "\n";
	return fails ? 1 : 0;
}
