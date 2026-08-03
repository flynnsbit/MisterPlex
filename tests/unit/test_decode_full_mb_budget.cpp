// Full-MB decode budget arithmetic — honest complete-pipeline close check.
//
// Acceptance metric is complete-frame latency, NOT p95 per-MB:
//   frame_cy = sum(cavlc) + N_MB * (recon + pred_or_mc + deblock + ddr + ctrl)
// Unimplemented stages are ESTIMATED (fixture allocations), never scored 0.
//
// Negative cases a naive wrong implementation must fail:
//   1) Scoring MC/deblock/DDR as 0 → false 720p@24 PASS
//   2) Using p95 CAVLC+luma34 alone as acceptance while complete P-frame is OVER

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

int g_fails = 0;

void expect(bool cond, const std::string& msg) {
    if (!cond) {
        std::cerr << "FAIL: " << msg << "\n";
        ++g_fails;
    }
}

// Fixture allocations from
// tests/fixtures/p3_multinal/plex_inter_p16_624x480_decode_throughput_v1.json
struct StageEst {
    int recon = 48;     // 24 blk * 2 cy
    int intra = 30;
    int mc = 250;
    int deblock = 100;
    int ddr = 50;
    int ctrl = 30;
};

double mb_I(double cavlc, const StageEst& e) {
    return cavlc + e.recon + e.intra + /*mc*/ 0 + e.deblock + e.ddr + e.ctrl;
}
double mb_P(double cavlc, const StageEst& e) {
    return cavlc + e.recon + /*intra*/ 0 + e.mc + e.deblock + e.ddr + e.ctrl;
}

double frame_cy(double cy_per_mb, int n_mb) { return cy_per_mb * n_mb; }

double fclk_hz(double frame_cycles, double fps) { return frame_cycles * fps; }

}  // namespace

int main() {
    const StageEst e{};
    const double clk = 20e6;
    const double fps24 = 24.0;
    const int mb720 = 80 * 45;  // 3600
    const double frame_budget_24 = clk / fps24;  // 833333.333...
    const double bud_hd24_mb = clk / fps24 / mb720;  // ~231.481

    // --- Arithmetic anchors ---
    expect(std::abs(bud_hd24_mb - 231.481) < 0.01, "720p24 cy/MB budget ~231.481");
    expect(std::abs(frame_budget_24 - 833333.333) < 0.1, "frame budget 20e6/24");

    // Reviewer 246.2: when CAVLC_all_p95=196.2, luma recon 34, chroma recon 16
    const double reviewer_p95 = 196.2 + 34.0 + 16.0;
    expect(std::abs(reviewer_p95 - 246.2) < 0.01, "reviewer 196.2+34+16=246.2");
    expect(reviewer_p95 > bud_hd24_mb, "reviewer partial already OVER 231.5");

    // Full recon from fixture is 48, not 34 (34 is luma-only hardcoded legacy)
    expect(e.recon == 48, "fixture recon=48 for 24 blocks");
    expect(16 * 2 + 8 * 2 == 48, "16Y+8C at 2 cy/block");

    // Dense residual mean from remeasure on 624 stream (documented in report).
    // Use 24.28 as measured mean; test locks the combine rules not the stream.
    const double cavlc_mean_dense = 24.28;
    const double cavlc_p95_example = 154.5;
    const double cavlc_max_example = 288.0;

    const double i_mean = mb_I(cavlc_mean_dense, e);
    const double p_mean = mb_P(cavlc_mean_dense, e);
    const double p_max = mb_P(cavlc_max_example, e);
    const double fixed_I_only = mb_I(0.0, e);  // zero CAVLC
    const double fixed_P_only = mb_P(0.0, e);

    // Killer fact: fixed stages alone (no residual parse) already exceed 231.5.
    expect(fixed_I_only > bud_hd24_mb,
           "I fixed stages alone (258) OVER 231.5 — zero-CAVLC still fails");
    expect(fixed_P_only > bud_hd24_mb, "P fixed stages alone (478) OVER 231.5");
    expect(i_mean > bud_hd24_mb, "I mean complete MB OVER 231.5");
    expect(p_mean > bud_hd24_mb, "P mean complete MB OVER 231.5");
    expect(p_mean > 400.0, "P mean includes MC250 → >400");
    expect(p_max > 700.0, "P max with dense residual >> budget");
    const double frame_p = frame_cy(p_mean, mb720);
    const double frame_i = frame_cy(i_mean, mb720);
    expect(frame_p > frame_budget_24, "P complete frame OVER 24fps budget @20MHz");
    expect(frame_i > frame_budget_24, "I complete frame OVER 24fps budget @20MHz");

    const double fclk_p = fclk_hz(frame_p, fps24);
    expect(fclk_p > 40e6, "P mean needs >40 MHz clk_sys");
    expect(fclk_p < 80e6, "P mean need stays under 80 MHz (plausible ceiling check)");

    // --- Negative 1: scoring unimplemented as zero falsely PASSES ---
    StageEst free_unimplemented = e;
    free_unimplemented.mc = 0;
    free_unimplemented.deblock = 0;
    free_unimplemented.ddr = 0;
    const double fake_p = mb_P(cavlc_mean_dense, free_unimplemented);
    // cavlc + recon48 + ctrl30 = 102.28 < 231.5 → false under
    expect(fake_p < bud_hd24_mb,
           "negative: zeroing MC/deblock/DDR yields false UNDER (must detect)");
    expect(mb_P(cavlc_mean_dense, e) > bud_hd24_mb,
           "honest P with estimates is OVER — opposite of free_unimplemented");

    // --- Negative 2: legacy p95 partial can UNDER while complete frame OVER ---
    const double legacy_partial = cavlc_p95_example + 34.0;  // no chroma recon, no MC
    expect(legacy_partial < bud_hd24_mb,
           "negative: legacy p95+34 UNDER 231.5 on dense p95=154.5");
    expect(frame_p > frame_budget_24,
           "negative: same content complete P frame still OVER — p95 false PASS");

    // --- Chroma addition to 34 ---
    const double with_chroma_recon = cavlc_p95_example + 34.0 + 16.0;
    expect(with_chroma_recon < bud_hd24_mb,
           "p95+50 may still under on this stream — max/frame metric needed");
    const double with_full_recon_max = cavlc_max_example + 48.0;
    expect(with_full_recon_max > bud_hd24_mb, "max CAVLC+full recon OVER");

    // Fixture sum of allocations
    const int sum_alloc = 50 + 48 + 30 + 250 + 100 + 50 + 30;  // parse+... from fixture
    expect(sum_alloc == 558, "fixture sum_allocated=558");
    expect(sum_alloc > static_cast<int>(bud_hd24_mb),
           "fixture allocation sum alone exceeds 720p24 cy/MB budget");

    if (g_fails != 0) {
        std::cerr << "test_decode_full_mb_budget FAIL count=" << g_fails << "\n";
        return 1;
    }
    std::cout << "test_decode_full_mb_budget PASS\n"
              << "  reviewer_246.2=" << reviewer_p95 << "\n"
              << "  mb_I_mean=" << i_mean << " mb_P_mean=" << p_mean << "\n"
              << "  frame_P_720=" << frame_p << " budget_24=" << frame_budget_24 << "\n"
              << "  fclk_P_mean_MHz=" << (fclk_p / 1e6) << "\n"
              << "  NEG_zero_unimpl_false_under=" << fake_p << "\n"
              << "  NEG_legacy_p95_partial=" << legacy_partial << "\n";
    return 0;
}
