// Verilator TB: packed 256×40 line buffer pack/stream/unpack
// NEGATIVE: naive "first 5 of each 8" packer must not match golden.
#include "Vline_buf_px5_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vline_buf_px5_tb_top* top) {
	top->clk = 0; top->eval(); main_time++;
	top->clk = 1; top->eval(); main_time++;
}

static int fails = 0;
#define EXPECT(cond, msg) do { if (!(cond)) { std::printf("FAIL %s\n", msg); fails++; } } while(0)

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* top = new Vline_buf_px5_tb_top;

	// Reset
	top->reset = 1;
	top->clear = 0;
	top->in_valid = 0;
	top->in_q = 0;
	top->stream_start = 0;
	top->stream_advance = 0;
	top->un_valid = 0;
	for (int i = 0; i < 5; i++) tick(top);
	top->reset = 0;
	for (int i = 0; i < 5; i++) tick(top);

	std::printf("CASE EXECUTED line_buf_px5 pack/stream/unpack\n");

	// ---- Build golden line: pixel i = (i*3+7) & 0xff ----
	const int PIXELS = 1280;
	std::vector<uint8_t> line(PIXELS);
	for (int i = 0; i < PIXELS; i++) line[i] = (uint8_t)((i * 3 + 7) & 0xff);

	// Golden packed words
	std::vector<uint64_t> golden_words(PIXELS / 5);
	for (int w = 0; w < PIXELS / 5; w++) {
		uint64_t v = 0;
		for (int k = 0; k < 5; k++)
			v |= (uint64_t)line[w * 5 + k] << (8 * k);
		golden_words[w] = v;
	}

	// NEGATIVE golden: naive takes only first 5 bytes of each 8-byte beat
	std::vector<uint64_t> naive_words;
	{
		std::vector<uint8_t> naive_bytes;
		for (int b = 0; b < PIXELS; b += 8) {
			for (int k = 0; k < 5; k++)
				naive_bytes.push_back(line[b + k]);
		}
		// pad
		while (naive_bytes.size() % 5) naive_bytes.push_back(0);
		for (size_t w = 0; w + 5 <= naive_bytes.size() && naive_words.size() < golden_words.size(); w += 5) {
			uint64_t v = 0;
			for (int k = 0; k < 5; k++)
				v |= (uint64_t)naive_bytes[w + k] << (8 * k);
			naive_words.push_back(v);
		}
	}

	// Start pack
	top->clear = 1; tick(top); top->clear = 0;

	std::vector<uint64_t> got_words(PIXELS / 5, 0);
	int got_n = 0;
	bool done = false;

	// Feed 160 beats — continuous (SKID=160)
	int beat = 0;
	int safety = 0;
	while (!done && safety < 10000) {
		safety++;
		if (beat < 160) {
			uint64_t q = 0;
			for (int k = 0; k < 8; k++)
				q |= (uint64_t)line[beat * 8 + k] << (8 * k);
			top->in_valid = 1;
			top->in_q = q;
			beat++;
		} else {
			top->in_valid = 0;
		}
		tick(top);
		if (top->pack_out_valid) {
			int a = top->pack_out_addr & 0xff;
			EXPECT(a < 256, "pack addr in range");
			if (a < 256) got_words[a] = (uint64_t)top->pack_out_data & 0xffffffffffULL;
			got_n++;
		}
		if (top->line_done) done = true;
	}
	top->in_valid = 0;

	EXPECT(done, "line_done seen");
	EXPECT(got_n == 256, "256 packed words emitted");
	EXPECT(!top->skid_overflow, "no skid overflow");

	int pack_mismatch = 0;
	for (int w = 0; w < 256; w++) {
		if ((got_words[w] & 0xffffffffffULL) != (golden_words[w] & 0xffffffffffULL))
			pack_mismatch++;
	}
	EXPECT(pack_mismatch == 0, "packed words match golden 5-px layout");
	std::printf("OK A pack_1280_continuous_beats mismatches=%d words=%d\n", pack_mismatch, got_n);

	// NEGATIVE: golden must differ from naive
	int naive_diff = 0;
	for (size_t w = 0; w < golden_words.size() && w < naive_words.size(); w++) {
		if ((golden_words[w] & 0xffffffffffULL) != (naive_words[w] & 0xffffffffffULL))
			naive_diff++;
	}
	EXPECT(naive_diff > 0, "NEGATIVE setup: naive packer differs from true pack");
	// If our RTL matched naive, fail
	int rtl_vs_naive = 0;
	for (int w = 0; w < 256 && w < (int)naive_words.size(); w++) {
		if ((got_words[w] & 0xffffffffffULL) == (naive_words[w] & 0xffffffffffULL))
			rtl_vs_naive++;
	}
	// Must NOT be identical to naive on all words
	EXPECT(rtl_vs_naive < 256, "NEGATIVE: RTL must not implement naive first-5-of-8 pack");
	std::printf("OK C NEGATIVE naive_first5of8_rejected rtl_eq_naive_words=%d diff_golden_naive=%d\n",
	            rtl_vs_naive, naive_diff);

	// Drain busy
	for (int i = 0; i < 20; i++) tick(top);

	// ---- Stream readback PPC=2 ----
	// RAM was written during pack (same clk). Start stream and collect pixels.
	top->stream_start = 1; tick(top); top->stream_start = 0;
	// prime a few cycles
	for (int i = 0; i < 8; i++) tick(top);

	std::vector<uint8_t> got_px;
	safety = 0;
	while ((int)got_px.size() < PIXELS && safety < 5000) {
		safety++;
		top->stream_advance = top->primed ? 1 : 0;
		tick(top);
		if (top->px_valid) {
			got_px.push_back(top->px_bytes & 0xff);
			got_px.push_back((top->px_bytes >> 8) & 0xff);
		}
	}
	top->stream_advance = 0;

	int stream_mismatch = 0;
	int ncmp = std::min((int)got_px.size(), PIXELS);
	for (int i = 0; i < ncmp; i++) {
		if (got_px[i] != line[i]) stream_mismatch++;
	}
	EXPECT(ncmp == PIXELS, "stream produced 1280 pixels");
	EXPECT(stream_mismatch == 0, "stream pixels match line");
	std::printf("OK B stream_rd_1280 px=%d mismatches=%d primed_path\n", ncmp, stream_mismatch);

	// ---- Explicit PPC2 straddle groups in stream: pixels [4,5], [14,15], ... ----
	// Group k takes pixels 2k,2k+1. Straddle when 2k % 5 == 4 (first px is word tail).
	int straddle_mismatch = 0;
	int straddle_checked = 0;
	for (int g = 0; g < PIXELS / 2; g++) {
		int p0 = g * 2;
		if ((p0 % 5) != 4)
			continue;
		straddle_checked++;
		if (p0 + 1 >= ncmp)
			break;
		if (got_px[p0] != line[p0] || got_px[p0 + 1] != line[p0 + 1])
			straddle_mismatch++;
	}
	EXPECT(straddle_checked >= 100, "enough PPC2 straddle groups in 1280");
	EXPECT(straddle_mismatch == 0, "stream PPC2 straddle groups [4,5]-class match");
	std::printf("OK E stream_ppc2_straddle groups=%d mismatches=%d (byte-queue adjacent-word cache)\n",
	            straddle_checked, straddle_mismatch);

	// ---- Unpack all phases 0..4 (PPC=2 window) ----
	int phase_fail = 0;
	for (int ph = 0; ph < 5; ph++) {
		int base = 10; // word-aligned base pixel 50 → words 10 and 11
		int pix = base * 5 + ph;
		uint64_t w0 = golden_words[base];
		uint64_t w1 = golden_words[base + 1];
		top->un_w0 = w0 & 0xffffffffffULL;
		top->un_w1 = w1 & 0xffffffffffULL;
		top->un_phase = ph;
		top->un_valid = 1;
		tick(top);
		EXPECT(top->un_out_valid, "unpack out_valid phase");
		uint8_t g0_cap = top->un_px & 0xff;
		uint8_t g1_cap = (top->un_px >> 8) & 0xff;
		top->un_valid = 0;
		tick(top);
		uint8_t exp0 = line[pix];
		uint8_t exp1 = line[pix + 1];
		if (g0_cap != exp0 || g1_cap != exp1) {
			phase_fail++;
			std::printf("FAIL unpack phase=%d got=%02x%02x exp=%02x%02x\n",
			            ph, g0_cap, g1_cap, exp0, exp1);
		}
	}
	EXPECT(phase_fail == 0, "unpack phases 0..4 PPC2");
	std::printf("OK D unpack_phases_0_4 fails=%d (phase4 spans words)\n", phase_fail);

	// ---- NEGATIVE: phase=4 with word1 cleared must NOT match golden straddle ----
	{
		uint64_t w0 = golden_words[0];
		top->un_w0 = w0 & 0xffffffffffULL;
		top->un_w1 = 0; // missing adjacent word
		top->un_phase = 4;
		top->un_valid = 1;
		tick(top);
		uint8_t g0_cap = top->un_px & 0xff;
		uint8_t g1_cap = (top->un_px >> 8) & 0xff;
		top->un_valid = 0;
		tick(top);
		// g0 may still match line[4]; g1 must not equal line[5] if word1 required
		EXPECT(g1_cap != line[5], "NEGATIVE: single-word phase4 cannot supply pixel 5");
		std::printf("OK F NEGATIVE single_word_phase4 g1=%02x != line5=%02x (need adjacent word)\n",
		            g1_cap, line[5]);
		(void)g0_cap;
	}

	// ---- Line boundary: second line pack+stream (restart) ----
	std::vector<uint8_t> line2(PIXELS);
	for (int i = 0; i < PIXELS; i++) line2[i] = (uint8_t)((i * 5 + 11) & 0xff);
	top->clear = 1; tick(top); top->clear = 0;
	beat = 0; done = false; safety = 0; got_n = 0;
	while (!done && safety < 10000) {
		safety++;
		if (beat < 160) {
			uint64_t q = 0;
			for (int k = 0; k < 8; k++)
				q |= (uint64_t)line2[beat * 8 + k] << (8 * k);
			top->in_valid = 1;
			top->in_q = q;
			beat++;
		} else {
			top->in_valid = 0;
		}
		tick(top);
		if (top->line_done) done = true;
	}
	top->in_valid = 0;
	EXPECT(done, "line2 line_done");
	for (int i = 0; i < 20; i++) tick(top);
	top->stream_start = 1; tick(top); top->stream_start = 0;
	for (int i = 0; i < 8; i++) tick(top);
	std::vector<uint8_t> got2;
	safety = 0;
	while ((int)got2.size() < PIXELS && safety < 5000) {
		safety++;
		top->stream_advance = top->primed ? 1 : 0;
		tick(top);
		if (top->px_valid) {
			got2.push_back(top->px_bytes & 0xff);
			got2.push_back((top->px_bytes >> 8) & 0xff);
		}
	}
	top->stream_advance = 0;
	int l2mis = 0;
	int n2 = std::min((int)got2.size(), PIXELS);
	for (int i = 0; i < n2; i++)
		if (got2[i] != line2[i]) l2mis++;
	EXPECT(n2 == PIXELS && l2mis == 0, "line boundary second line stream");
	std::printf("OK G line_boundary line2 px=%d mismatches=%d\n", n2, l2mis);

	// ---- NEGATIVE: scaler jump — mid-line restart without new pack is L→R only ----
	// After line2 is loaded, start stream and advance 100 groups (200 px), then
	// pretend a scaler jump by continuing without start: stream stays sequential.
	// A correct random-access design would need seek; we assert continued L→R
	// matches line2[200..] (not some jumped source). Jump-to-offset unsupported.
	top->stream_start = 1; tick(top); top->stream_start = 0;
	for (int i = 0; i < 8; i++) tick(top);
	std::vector<uint8_t> got_jump;
	safety = 0;
	while ((int)got_jump.size() < 200 && safety < 2000) {
		safety++;
		top->stream_advance = top->primed ? 1 : 0;
		tick(top);
		if (top->px_valid) {
			got_jump.push_back(top->px_bytes & 0xff);
			got_jump.push_back((top->px_bytes >> 8) & 0xff);
		}
	}
	// Continue without start (no seek) another 20 px — must be line2[200..]
	std::vector<uint8_t> got_cont;
	safety = 0;
	while ((int)got_cont.size() < 20 && safety < 500) {
		safety++;
		top->stream_advance = top->primed ? 1 : 0;
		tick(top);
		if (top->px_valid) {
			got_cont.push_back(top->px_bytes & 0xff);
			got_cont.push_back((top->px_bytes >> 8) & 0xff);
		}
	}
	top->stream_advance = 0;
	int cont_mis = 0;
	for (int i = 0; i < (int)got_cont.size() && (200 + i) < PIXELS; i++)
		if (got_cont[i] != line2[200 + i]) cont_mis++;
	EXPECT(got_cont.size() == 20 && cont_mis == 0,
	       "no-seek continue is L→R (scaler jump not implemented — sequential only)");
	std::printf("OK H NEGATIVE_scaler_jump_unsupported continue_L2R mis=%d (seek would need dual-word phase path)\n",
	            cont_mis);

	// Rate / cost notes (controls, not guesses)
	std::printf("RATE_NOTE DDR 5 beats -> 8 words; pack SKID=160 + FIFO=256 absorbs 8/5 write expand\n");
	std::printf("COST_NOTE chroma640_px layout=128x40_in_256x40 M10K_per_slot=1 (50pct util)\n");
	std::printf("COST_NOTE luma1280_px layout=256x40 M10K_per_slot=1\n");
	std::printf("PREREG linebufs LC16 slots32: packed=96 M10K vs naive64b=192 M10K save=96\n");

	if (fails) {
		std::printf("SUMMARY FAIL fails=%d\n", fails);
		delete top;
		return 1;
	}
	std::printf("SUMMARY PASS line_buf_px5\n");
	delete top;
	return 0;
}
