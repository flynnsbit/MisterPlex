// ddr_fabric_decode_arb TB — present-priority vs sticky-DPB negative.
// G0: ENABLE_FABRIC_DECODE=0 ignores DPB/BS saturation; present-only.
// G1: priority arb under DPB flood — present meets deadline (max wait bound).
// G_NEG: same stimulus on naive sticky-DPB MUST miss present deadline.
#include "Vddr_fabric_decode_arb_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vddr_fabric_decode_arb_tb_top* t) {
	t->clk = 0;
	t->eval();
	main_time++;
	t->clk = 1;
	t->eval();
	main_time++;
}

static int fail(const char* msg) {
	std::fprintf(stderr, "FAIL %s\n", msg);
	return 1;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* top = new Vddr_fabric_decode_arb_tb_top;

	// Contract constants (must match plex_decode_ddr_bw.svh arithmetic)
	const int kI420 = 1382400;
	const int kFps = 24;
	const double kPresentMBps = (double)kI420 * kFps / 1e6; // 33.1776
	const double kDpbWrMBps = kPresentMBps;
	const double kBsBudgetMBps = 2.0;
	const double kSumI = kPresentMBps + kDpbWrMBps + 0.0 + kBsBudgetMBps; // 68.3552
	const double kIdealPeak = 90e6 * 8 / 1e6; // 720
	const int kMaxLopri = 16;
	const int kPipe = 4;
	const int kPresentWc = kMaxLopri + kPipe; // 20 ddr cyc bound
	// Deadline for NEG: if present blocked > 64 cyc while commanding → starve
	const int kStarveDeadline = 64;

	std::printf("PREREG_BW present=%.4f dpb_wr=%.4f dpb_mc_I=0 bs_budget=%.1f sum_I=%.4f "
	            "ideal_peak=%.1f fit_avg_payload=%s\n",
	            kPresentMBps, kDpbWrMBps, kBsBudgetMBps, kSumI, kIdealPeak,
	            (kSumI < kIdealPeak) ? "YES_under_ideal_peak_only" : "NO");
	std::printf("WC_BOUND max_lopri=%d pipe=%d present_wc_ddr_cyc=%d "
	            "(<< blackout 46080 ddr cyc @LINE16)\n",
	            kMaxLopri, kPipe, kPresentWc);

	auto reset_idle = [&]() {
		top->reset = 1;
		top->m_p_rd = 0;
		top->m_p_burstcnt = 1;
		top->m_p_addr = 0x10;
		top->m_dpb_want = 0;
		top->m_dpb_rd = 0;
		top->m_dpb_we = 0;
		top->m_dpb_burstcnt = 16;
		top->m_dpb_addr = 0x1000;
		top->m_dpb_din = 0xA5A5A5A5A5A5A5A5ull;
		top->m_bs_want = 0;
		top->m_bs_rd = 0;
		top->m_bs_burstcnt = 4;
		top->m_bs_addr = 0x2000;
		for (int i = 0; i < 8; ++i)
			tick(top);
		top->reset = 0;
		for (int i = 0; i < 4; ++i)
			tick(top);
	};

	// -------- G0: ENABLE=0 transparent — DPB hard-tied want must not own bus --------
	reset_idle();
	int off_p_accept = 0, off_dpb_we_seen = 0;
	top->m_p_rd = 1;
	top->m_p_burstcnt = 1;
	top->m_p_addr = 0x55;
	for (int c = 0; c < 40; ++c) {
		if (top->off_DDRAM_RD && top->off_DDRAM_ADDR == 0x55)
			++off_p_accept;
		// DPB tied want+we inside OFF dut — must never appear on DDRAM
		if (top->off_DDRAM_WE)
			++off_dpb_we_seen;
		if (top->off_m_dpb_busy == 0) {
			// dpb must stay busy when decode off
		}
		tick(top);
		top->m_p_rd = (c < 8) ? 1 : 0;
	}
	if (off_p_accept < 1)
		return fail("G0 ENABLE=0 present never accepted");
	if (off_dpb_we_seen != 0)
		return fail("G0 ENABLE=0 leaked DPB write to DDRAM");
	if (top->off_m_dpb_busy != 1)
		return fail("G0 ENABLE=0 m_dpb_busy must stay 1");
	std::printf("PASS G0 transparent ENABLE=0 present_accept=%d dpb_leak=%d\n",
	            off_p_accept, off_dpb_we_seen);

	// -------- G1: priority under DPB flood --------
	// Phase A: DPB alone grabs bus. Phase B: present asserts continuously; measure
	// first-accept wait (must be ≤ WC). Phase C: present 25% duty so DPB also moves.
	reset_idle();
	top->m_dpb_want = 1;
	top->m_dpb_burstcnt = 16;
	top->m_dpb_we = 1;
	top->m_dpb_rd = 0;
	top->m_p_burstcnt = 1;
	top->m_p_addr = 0x77;
	top->m_p_rd = 0;
	for (int c = 0; c < 32; ++c)
		tick(top); // DPB occupies

	// Phase B — present continuous until first accept
	top->m_p_rd = 1;
	int first_wait = -1;
	int prio_p_beats = 0;
	int prio_dpb_we = 0;
	for (int c = 0; c < 200; ++c) {
		top->m_p_rd = 1;
		top->m_dpb_we = 1;
		top->m_dpb_want = 1;
		if (first_wait < 0) {
			if (top->prio_DDRAM_RD && top->prio_DDRAM_ADDR == 0x77 && !top->prio_m_p_busy)
				first_wait = c;
			else if (!top->prio_m_p_busy && top->prio_DDRAM_RD)
				first_wait = c;
		}
		if (top->prio_DDRAM_RD && top->prio_DDRAM_ADDR == 0x77)
			++prio_p_beats;
		if (top->prio_DDRAM_WE)
			++prio_dpb_we;
		tick(top);
	}
	std::printf("MEAS G1b first_present_wait=%d bound=%d p_beats=%d dpb_we=%d wc_obs=%u\n",
	            first_wait, kPresentWc, prio_p_beats, prio_dpb_we,
	            (unsigned)top->prio_wc_block);
	if (first_wait < 0)
		return fail("G1 present never accepted after DPB occupy");
	if (first_wait > kPresentWc)
		return fail("G1 first present wait exceeded RTL WC bound");

	// Phase C — 25% present duty, continuous DPB want; both must progress
	int max_p_wait = 0;
	int cur_p_wait = 0;
	prio_p_beats = 0;
	prio_dpb_we = 0;
	for (int c = 0; c < 2000; ++c) {
		int want_p = (c % 8) < 2; // 25% duty
		top->m_p_rd = want_p ? 1 : 0;
		top->m_dpb_we = 1;
		top->m_dpb_want = 1;
		if (want_p) {
			if (top->prio_m_p_busy) {
				++cur_p_wait;
				if (cur_p_wait > max_p_wait)
					max_p_wait = cur_p_wait;
			} else {
				if (top->prio_DDRAM_RD && top->prio_DDRAM_ADDR == 0x77)
					++prio_p_beats;
				cur_p_wait = 0;
			}
		} else {
			cur_p_wait = 0;
		}
		if (top->prio_DDRAM_WE)
			++prio_dpb_we;
		tick(top);
	}
	std::printf("MEAS G1c prio present_accept=%d dpb_we=%d max_p_wait=%d wc_obs=%u "
	            "bound=%d\n",
	            prio_p_beats, prio_dpb_we, max_p_wait, (unsigned)top->prio_wc_block,
	            kPresentWc);
	if (prio_p_beats < 30)
		return fail("G1c priority present starved (too few accepts)");
	if (prio_dpb_we < 50)
		return fail("G1c DPB made no progress (arb broken)");
	if (max_p_wait > kPresentWc)
		return fail("G1c present wait exceeded RTL WC bound");
	if ((int)top->prio_wc_block > kPresentWc + 4)
		return fail("G1 sticky wc_present_block_beats over bound");
	std::printf("PASS G1 priority DPB-flood present_ok first_wait=%d max_wait=%d<=%d\n",
	            first_wait, max_p_wait, kPresentWc);

	// Phase D — DPB RD bursts (exercises rsp_pipe WC ≤ MAX_LOPRI_BURST+pipe)
	reset_idle();
	top->m_dpb_want = 1;
	top->m_dpb_burstcnt = 16;
	top->m_dpb_we = 0;
	top->m_dpb_rd = 1;
	top->m_p_rd = 0;
	top->m_p_addr = 0x77;
	top->m_p_burstcnt = 1;
	for (int c = 0; c < 8; ++c)
		tick(top);
	top->m_p_rd = 1;
	int rd_first = -1;
	int rd_max_wait = 0, rd_cur = 0;
	for (int c = 0; c < 500; ++c) {
		top->m_dpb_want = 1;
		top->m_dpb_rd = 1;
		top->m_p_rd = 1;
		if (top->prio_m_p_busy) {
			++rd_cur;
			if (rd_cur > rd_max_wait)
				rd_max_wait = rd_cur;
		} else {
			if (rd_first < 0 && top->prio_DDRAM_RD && top->prio_DDRAM_ADDR == 0x77)
				rd_first = c;
			rd_cur = 0;
		}
		tick(top);
	}
	std::printf("MEAS G1d DPB-RD-flood first=%d max_p_wait=%d bound=%d wc_obs=%u\n",
	            rd_first, rd_max_wait, kPresentWc, (unsigned)top->prio_wc_block);
	if (rd_first < 0)
		return fail("G1d present never accepted under DPB RD flood");
	if (rd_max_wait > kPresentWc)
		return fail("G1d present wait exceeded WC under DPB RD");
	std::printf("PASS G1d DPB-RD flood present WC max_wait=%d<=%d\n", rd_max_wait, kPresentWc);

	// -------- G_NEG: continuous present + sticky DPB (same flood class) --------
	reset_idle();
	top->m_dpb_want = 1;
	top->m_dpb_burstcnt = 16;
	top->m_dpb_we = 1;
	top->m_p_burstcnt = 1;
	top->m_p_addr = 0x77;
	top->m_p_rd = 0;
	for (int c = 0; c < 32; ++c)
		tick(top);
	top->m_p_rd = 1;
	int naive_p_beats = 0;
	int naive_max_wait = 0;
	int naive_cur = 0;
	int naive_deadline_hits = 0;
	for (int c = 0; c < 2000; ++c) {
		top->m_p_rd = 1;
		top->m_dpb_we = 1;
		top->m_dpb_want = 1;
		if (top->naive_m_p_busy) {
			++naive_cur;
			if (naive_cur > naive_max_wait)
				naive_max_wait = naive_cur;
			if (naive_cur > kStarveDeadline)
				++naive_deadline_hits;
		} else {
			if (top->naive_DDRAM_RD && top->naive_DDRAM_ADDR == 0x77)
				++naive_p_beats;
			naive_cur = 0;
		}
		tick(top);
	}
	std::printf("MEAS G_NEG naive present_accept=%d max_wait=%d deadline_hits=%d "
	            "deadline=%d\n",
	            naive_p_beats, naive_max_wait, naive_deadline_hits, kStarveDeadline);
	if (naive_p_beats > 5)
		return fail("G_NEG naive served present too often — sticky broken");
	if (naive_max_wait <= kStarveDeadline)
		return fail("G_NEG naive max_wait did not exceed starve deadline");
	if (naive_deadline_hits == 0)
		return fail("G_NEG no deadline hits — negative case vacuous");
	std::printf("PASS G_NEG naive sticky-DPB starves present (hits=%d max_wait=%d) "
	            "as required negative\n",
	            naive_deadline_hits, naive_max_wait);

	if (!(max_p_wait <= kPresentWc && naive_max_wait > kStarveDeadline))
		return fail("cross: priority/naive deadline relationship broken");	std::printf("PASS ddr_fabric_decode_arb all "
	            "(prio WC-bound + naive NEG starve + ENABLE0 transparent)\n");
	std::printf("POLICY strict_priority_bounded_preemption MAX_LOPRI_BURST=%d "
	            "ENABLE_FABRIC_DECODE default 0\n",
	            kMaxLopri);
	delete top;
	return 0;
}
