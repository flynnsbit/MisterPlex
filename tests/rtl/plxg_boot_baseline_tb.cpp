#include "Vplxg_boot_baseline_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplxg_boot_baseline_tb_top* t) {
	t->clk = 0; t->eval(); main_time++;
	t->clk = 1; t->eval(); main_time++;
}

static void reset_hold(Vplxg_boot_baseline_tb_top* t, int n = 8) {
	t->reset = 1;
	t->host_publish = 0;
	t->host_publish_2 = 0;
	for (int i = 0; i < n; ++i) tick(t);
	t->reset = 0;
}

// Pre-poll race (rd-duck liveness gap): valid host record at first poll is
// baselined without commit; single same-pair publish never lives; publish_2 commits.
static int run_race_pre_poll(Vplxg_boot_baseline_tb_top* t) {
	t->seed_retained = 0;
	t->seed_race = 1;
	reset_hold(t);

	bool saw_base = false;
	for (int i = 0; i < 5000; ++i) {
		tick(t);
		if (t->cnt_commit > 0) {
			std::fprintf(stderr, "FAIL race: commit before EnsureLive second publish\n");
			return 1;
		}
		if (t->boot_baseline_done && t->cnt_baseline > 0) {
			saw_base = true;
			break;
		}
	}
	std::fprintf(stderr, "=== PRODUCT pre-poll race liveness gap ===\n");
	if (!saw_base || t->last_seq != 3 || t->cnt_commit != 0) {
		std::fprintf(stderr, "FAIL race baseline seq=%u base=%u commit=%u\n",
		             t->last_seq, t->cnt_baseline, t->cnt_commit);
		return 1;
	}
	// Single host_publish does not bump seq on race path → still no commit.
	t->host_publish = 1;
	for (int i = 0; i < 4; ++i) tick(t);
	t->host_publish = 0;
	for (int i = 0; i < 4000; ++i) tick(t);
	if (t->cnt_commit != 0) {
		std::fprintf(stderr, "FAIL race: same-pair publish committed commit=%u\n",
		             t->cnt_commit);
		return 1;
	}
	std::fprintf(stderr, "REPRO gap: pre-poll single publish never live commit=0\n");

	// EnsureLive second distinct seq.
	t->host_publish_2 = 1;
	for (int i = 0; i < 4; ++i) tick(t);
	t->host_publish_2 = 0;
	bool saw_commit = false;
	for (int i = 0; i < 8000; ++i) {
		tick(t);
		if (t->cnt_commit > 0) { saw_commit = true; break; }
	}
	if (!saw_commit || t->last_seq != 4) {
		std::fprintf(stderr, "FAIL race EnsureLive commit=%u last=%u\n",
		             t->cnt_commit, t->last_seq);
		return 1;
	}
	std::fprintf(stderr, "PASS race: baselined seq=3; EnsureLive seq=4 committed\n");
	return 0;
}

// Retained DDR path (existing).
static int run_retained(Vplxg_boot_baseline_tb_top* t) {
	t->seed_retained = 1;
	t->seed_race = 0;
	reset_hold(t);

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
		return 1;
	}
	std::fprintf(stderr, "REPRO retained-promoted-after-fpga-reset commit=%u seq=%u\n",
	             t->cnt_commit, t->last_seq);
	return 2;
#else
	std::fprintf(stderr, "=== PRODUCT boot baseline retained ===\n");
	if (!saw_base) {
		std::fprintf(stderr, "FAIL no baseline of retained seq=7\n");
		return 1;
	}
	if (saw_commit_early || t->cnt_commit != 0) {
		std::fprintf(stderr, "FAIL retained promoted before post-reset publish commit=%u\n",
		             t->cnt_commit);
		return 1;
	}
	if (t->last_seq != 7 || t->last_epoch != 1) {
		std::fprintf(stderr, "FAIL baseline last epoch=%u seq=%u\n",
		             t->last_epoch, t->last_seq);
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
		return 1;
	}
	std::fprintf(stderr, "PASS retained: held; post-reset seq=8 committed\n");
	return 0;
#endif
}

// Fresh zero DDR + exactly one post-reset publication.
static int run_fresh_zero(Vplxg_boot_baseline_tb_top* t) {
	t->seed_retained = 0;
	t->seed_race = 0;
	reset_hold(t);

	bool saw_empty_base = false;
	for (int i = 0; i < 5000; ++i) {
		tick(t);
		if (t->boot_baseline_done && t->cnt_baseline == 0) {
			if (t->last_seq == 0 && t->cnt_commit == 0) {
				saw_empty_base = true;
				break;
			}
		}
		if (t->cnt_commit > 0) {
			std::fprintf(stderr, "FAIL fresh: commit before host publish\n");
			return 1;
		}
	}

#if defined(FAULT_PLXG_EMPTY_NO_BASELINE)
	std::fprintf(stderr, "=== FAULT_PLXG_EMPTY_NO_BASELINE ===\n");
	if (t->boot_baseline_done) {
		std::fprintf(stderr, "FAIL red twin completed baseline on empty\n");
		return 1;
	}
	t->host_publish = 1;
	for (int i = 0; i < 4; ++i) tick(t);
	t->host_publish = 0;
	for (int i = 0; i < 8000; ++i) tick(t);
	if (t->cnt_commit != 0) {
		std::fprintf(stderr, "FAIL red twin committed first publish commit=%u\n",
		             t->cnt_commit);
		return 1;
	}
	if (!(t->boot_baseline_done && t->cnt_baseline > 0 && t->last_seq == 1)) {
		std::fprintf(stderr, "FAIL red twin did not swallow first as baseline "
		             "done=%u base=%u last=%u\n",
		             t->boot_baseline_done, t->cnt_baseline, t->last_seq);
		return 1;
	}
	std::fprintf(stderr,
	             "REPRO empty-no-baseline swallowed first publish last=%u commit=0\n",
	             t->last_seq);
	return 2;
#else
	std::fprintf(stderr, "=== PRODUCT fresh zero + one publish ===\n");
	if (!saw_empty_base) {
		std::fprintf(stderr, "FAIL fresh: empty observation did not complete baseline "
		             "done=%u base=%u bad_magic=%u\n",
		             t->boot_baseline_done, t->cnt_baseline, t->cnt_bad_magic);
		return 1;
	}
	std::fprintf(stderr, "empty_baseline_ok bad_magic=%u\n", t->cnt_bad_magic);

	t->host_publish = 1;
	for (int i = 0; i < 4; ++i) tick(t);
	t->host_publish = 0;
	bool saw_commit = false;
	for (int i = 0; i < 8000; ++i) {
		tick(t);
		if (t->cnt_commit > 0) { saw_commit = true; break; }
	}
	if (!saw_commit || t->last_seq != 1 || t->cnt_baseline != 0) {
		std::fprintf(stderr, "FAIL fresh one-publish commit=%u last=%u base=%u\n",
		             t->cnt_commit, t->last_seq, t->cnt_baseline);
		return 1;
	}
	std::fprintf(stderr, "PASS fresh zero: one publish seq=1 committed\n");
	return 0;
#endif
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = std::getenv("PLXG_BASELINE_MODE");
	if (!mode) mode = "retained";

	auto* t = new Vplxg_boot_baseline_tb_top;
	t->seed_race = 0;
	t->host_publish_2 = 0;
	int rc = 1;
	if (std::strcmp(mode, "fresh") == 0)
		rc = run_fresh_zero(t);
	else if (std::strcmp(mode, "race") == 0)
		rc = run_race_pre_poll(t);
	else
		rc = run_retained(t);

	if (rc == 0 && std::strcmp(mode, "retained") == 0) {
#if !defined(FAULT_PLXG_NO_BASELINE) && !defined(FAULT_PLXG_EMPTY_NO_BASELINE)
		int rc2 = run_fresh_zero(t);
		if (rc2 != 0) {
			delete t;
			return rc2;
		}
		int rc3 = run_race_pre_poll(t);
		if (rc3 != 0) {
			delete t;
			return rc3;
		}
		std::fprintf(stderr,
		             "PASS boot baseline: retained + fresh-zero + pre-poll race\n");
#endif
	}
	delete t;
	return rc;
}
