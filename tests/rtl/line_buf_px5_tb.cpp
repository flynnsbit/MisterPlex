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

	// ---- Unpack phase=4 span (word0 last byte + word1 first) ----
	uint64_t w0 = golden_words[0];
	uint64_t w1 = golden_words[1];
	top->un_w0 = (uint32_t)(w0 & 0xffffffffULL) | (((uint64_t)((w0 >> 32) & 0xff)) << 32); // 40b
	// Verilator 40-bit: use lower
	top->un_w0 = w0 & 0xffffffffffULL;
	top->un_w1 = w1 & 0xffffffffffULL;
	top->un_phase = 4;
	top->un_valid = 1;
	tick(top); // registered: out_valid high this cycle
	EXPECT(top->un_out_valid, "unpack out_valid");
	uint8_t g0_cap = top->un_px & 0xff;
	uint8_t g1_cap = (top->un_px >> 8) & 0xff;
	top->un_valid = 0;
	tick(top);
	uint8_t exp0 = line[4];
	uint8_t exp1 = line[5];
	EXPECT(g0_cap == exp0 && g1_cap == exp1, "unpack phase4 spans words");
	std::printf("OK D unpack_phase4 span got=%02x%02x exp=%02x%02x\n", g0_cap, g1_cap, exp0, exp1);

	// Chroma 640 cost note (control print, not a guess)
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
