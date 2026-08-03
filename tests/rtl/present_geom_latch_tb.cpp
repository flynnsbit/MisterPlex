// present_geom_latch RBG: reset-safe, PLXG pack, q5 DAR+fps (ABI #2), reserved reject.
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

// Parent ABI arbitration #2 q5 @ +0x828
uint64_t pack_q5_official(uint16_t dar_x, uint16_t dar_y, uint8_t fps, bool dar_v,
                          bool fps_v, uint64_t reserved_hi = 0) {
	uint64_t w = uint64_t(dar_x & 0xfff) | (uint64_t(dar_y & 0xfff) << 12) |
	             (uint64_t(fps) << 24) | (uint64_t(dar_v) << 32) | (uint64_t(fps_v) << 33);
	w |= (reserved_hi & 0x3FFFFFFFull) << 34;
	return w;
}

// Pre-arbitration B9 packing (WRONG): dar_y at [27:16]
uint64_t pack_q5_old_b9(uint16_t dar_x, uint16_t dar_y, bool dar_v) {
	return uint64_t(dar_x & 0xfff) | (uint64_t(dar_y & 0xfff) << 16) |
	       (uint64_t(dar_v) << 32);
}

struct Sim {
	Vpresent_geom_latch_tb top{};
	void tick() {
		top.clk = 0;
		top.eval();
		top.clk = 1;
		top.eval();
	}
	void resetPulse() {
		top.reset = 1;
		top.wr_en = 0;
		top.commit = 0;
		for (int i = 0; i < 4; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 2; ++i)
			tick();
	}
	void writeQ(int idx, uint64_t data) {
		top.wr_en = 1;
		top.wr_idx = idx;
		top.wr_data = data;
		top.commit = 0;
		tick();
		top.wr_en = 0;
		tick();
	}
	void doCommit() {
		top.commit = 1;
		tick();
		top.commit = 0;
		tick();
	}
	void loadPack(uint32_t magic, bool win, bool geom, uint16_t seq, int cw, int ch,
	              int coded_w, int coded_h, int ys, int cs, uint64_t q5 = 0) {
		writeQ(0, q0(magic, win, geom, seq));
		writeQ(1, pack4x11(cw, ch, 0, 0));
		writeQ(2, pack4x11(0, 0, coded_w, coded_h));
		writeQ(3, pack_stride(ys, cs, coded_w, coded_h));
		writeQ(4, pack4x11(0, 0, 0, 0));
		writeQ(5, q5);
		doCommit();
	}
};
} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Sim s;
	int fails = 0;
	auto expect = [&](bool ok, const char* tag) {
		if (ok)
			std::cout << "PASS " << tag << "\n";
		else {
			std::cerr << "FAIL " << tag << "\n";
			++fails;
		}
	};

	s.resetPulse();
	std::cout << "CASE reset_safe EXECUTED win=" << int(s.top.win_enable)
	          << " geom=" << int(s.top.geom_enable)
	          << " valid=" << int(s.top.live_valid) << "\n";
	if (s.top.win_enable || s.top.geom_enable || s.top.live_valid ||
	    s.top.y_stride != 0 || s.top.coded_w != 0 || s.top.dar_valid ||
	    s.top.fps_valid) {
		std::cerr << "FAIL reset_safe: outputs not zero\n";
		++fails;
	} else {
		std::cout << "PASS reset_safe\n";
	}

	s.loadPack(kMagic, true, true, 1, 1280, 720, 1280, 720, 1280, 640, 0);
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
	    int(s.top.live_seq) != 1 || s.top.dar_valid || s.top.fps_valid) {
		std::cerr << "FAIL plxg_720: fields mismatch\n";
		++fails;
	} else {
		std::cout << "PASS plxg_720\n";
	}

	s.loadPack(kBadMagic, false, false, 2, 320, 240, 624, 480, 624, 312, 0);
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

	s.loadPack(kMagic, true, true, 3, 320, 240, 320, 240, 320, 160, 0);
	std::cout << "CASE plxg_seq3 EXECUTED cw=" << int(s.top.content_w)
	          << " ys=" << int(s.top.y_stride) << " seq=" << int(s.top.live_seq) << "\n";
	if (int(s.top.content_w) != 320 || int(s.top.y_stride) != 320 ||
	    int(s.top.live_seq) != 3) {
		std::cerr << "FAIL plxg_seq3\n";
		++fails;
	} else {
		std::cout << "PASS plxg_seq3\n";
	}

	{
		const uint64_t q5 = pack_q5_official(16, 9, 30, true, true);
		s.loadPack(kMagic, true, true, 4, 960, 540, 960, 540, 960, 480, q5);
		std::cout << "CASE q5_official EXECUTED dar_v=" << int(s.top.dar_valid)
		          << " dar=" << int(s.top.dar_x) << "x" << int(s.top.dar_y)
		          << " fps_v=" << int(s.top.fps_valid)
		          << " fps=" << int(s.top.content_fps)
		          << " seq=" << int(s.top.live_seq) << "\n";
		expect(s.top.dar_valid && int(s.top.dar_x) == 16 && int(s.top.dar_y) == 9,
		       "q5_official_dar_16_9");
		expect(s.top.fps_valid && int(s.top.content_fps) == 30, "q5_official_fps_30");
		expect(int(s.top.live_seq) == 4 && int(s.top.content_w) == 960, "q5_official_geom");
	}

	{
		const uint64_t q5_old = pack_q5_old_b9(16, 9, true);
		s.loadPack(kMagic, true, true, 5, 720, 480, 720, 480, 720, 360, q5_old);
		const int dy = int(s.top.dar_y);
		const int dx = int(s.top.dar_x);
		std::cout << "CASE q5_old_pack_misdecode EXECUTED dar=" << dx << "x" << dy
		          << " (want NOT 16x9 under official decoder)\n";
		const bool looks_like_16_9 = (dx == 16 && dy == 9);
		if (looks_like_16_9) {
			std::cout << "FAIL q5_old_pack still decodes as 16:9 — bit layout not official\n";
			++fails;
		} else {
			std::cout << "PASS q5_old_pack_NOT_16_9 dar=" << dx << "x" << dy << "\n";
			expect(dx == 16 && dy == 144, "q5_old_pack_official_decode_16_144");
		}
	}

	{
		const int seq_hold = int(s.top.live_seq);
		const int cw_hold = int(s.top.content_w);
		const int darx_hold = int(s.top.dar_x);
		const uint64_t q5_bad =
		    pack_q5_official(4, 3, 24, true, true, /*reserved_hi=*/1ull);
		s.loadPack(kMagic, true, true, 6, 320, 240, 320, 240, 320, 160, q5_bad);
		std::cout << "CASE q5_rsvd_reject EXECUTED seq=" << int(s.top.live_seq)
		          << " cw=" << int(s.top.content_w) << " dar_x=" << int(s.top.dar_x)
		          << " (held seq=" << seq_hold << " cw=" << cw_hold << ")\n";
		const bool rejected = (int(s.top.live_seq) == seq_hold &&
		                       int(s.top.content_w) == cw_hold &&
		                       int(s.top.dar_x) == darx_hold);
		if (!rejected) {
			std::cout << "FAIL q5_rsvd_reject: promote applied despite reserved!=0\n";
			++fails;
		} else {
			std::cout << "PASS q5_rsvd_reject held_prev_live\n";
		}
		const uint64_t q5_ok = pack_q5_official(4, 3, 24, true, true, 0);
		s.loadPack(kMagic, true, true, 6, 320, 240, 320, 240, 320, 160, q5_ok);
		expect(int(s.top.live_seq) == 6 && int(s.top.content_w) == 320 &&
		           s.top.dar_valid && int(s.top.dar_x) == 4 && int(s.top.dar_y) == 3 &&
		           s.top.fps_valid && int(s.top.content_fps) == 24,
		       "q5_rsvd_clear_then_accept");
	}

	std::cout << "PLXG_LATCH_DONE fails=" << fails << "\n";
	return fails ? 1 : 0;
}
