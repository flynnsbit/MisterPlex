#include "Vplxg_boot_baseline_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplxg_boot_baseline_tb_top* t) {
	t->clk = 0; t->eval(); main_time++;
	t->clk = 1; t->eval(); main_time++;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* t = new Vplxg_boot_baseline_tb_top;
	t->reset = 1;
	t->host_publish = 0;
	for (int i = 0; i < 8; ++i) tick(t);
	t->reset = 0;

	bool saw_base = false;
	bool saw_commit_early = false;
	for (int i = 0; i < 5000; ++i) {
		tick(t);
		if (t->cnt_commit > 0 || t->commit_pulse || t->wr_en_pulse)
			saw_commit_early = true;
		if (t->boot_baseline_done && t->cnt_baseline > 0) {
			saw_base = true;
			break;
		}
	}

#if defined(FAULT_PLXG_NO_BASELINE)
	std::fprintf(stderr, "=== FAULT_PLXG_NO_BASELINE ===\n");
	for (int i = 0; i < 5000 && t->cnt_commit == 0; ++i)
		tick(t);
	std::fprintf(stderr, "fault: base_done=%u base=%u commit=%u last=%u\n",
	             t->boot_baseline_done, t->cnt_baseline, t->cnt_commit, t->last_seq);
	if (t->cnt_commit == 0 || t->last_seq != 7) {
		std::fprintf(stderr, "FAIL fault twin did not promote retained\n");
		delete t;
		return 1;
	}
	std::fprintf(stderr, "REPRO retained-promoted-after-fpga-reset commit=%u seq=%u\n",
	             t->cnt_commit, t->last_seq);
	delete t;
	return 2;
#else
	std::fprintf(stderr, "=== PRODUCT boot baseline ===\n");
	if (!saw_base) {
		std::fprintf(stderr, "FAIL no baseline of retained seq=7\n");
		delete t;
		return 1;
	}
	if (saw_commit_early || t->cnt_commit != 0) {
		std::fprintf(stderr, "FAIL retained promoted before post-reset publish commit=%u\n",
		             t->cnt_commit);
		delete t;
		return 1;
	}
	if (t->last_seq != 7 || t->last_epoch != 1) {
		std::fprintf(stderr, "FAIL baseline last epoch=%u seq=%u\n",
		             t->last_epoch, t->last_seq);
		delete t;
		return 1;
	}
	std::fprintf(stderr, "baseline_ok last_seq=%u commit=%u\n", t->last_seq, t->cnt_commit);

	t->host_publish = 1;
	for (int i = 0; i < 4; ++i) tick(t);
	t->host_publish = 0;
	bool saw_commit = false;
	for (int i = 0; i < 8000; ++i) {
		tick(t);
		if (t->cnt_commit > 0) { saw_commit = true; break; }
	}
	if (!saw_commit || t->last_seq != 8) {
		std::fprintf(stderr, "FAIL post-reset publish commit=%u last=%u\n",
		             t->cnt_commit, t->last_seq);
		delete t;
		return 1;
	}
	std::fprintf(stderr, "PASS boot baseline: retained held; post-reset seq=8 committed\n");
	delete t;
	return 0;
#endif
}
