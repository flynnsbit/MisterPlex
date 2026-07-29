// Minimal host hybrid compose check + mutation twin.
// Pre-register @ 320x240: 300 MB/frame; I,P×11 → fpga_mb=300 host_mb=3300.
#include "libmisterplex/hybrid_compose.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using namespace misterplex::hybrid;

static void fail(const char* msg) {
    std::fprintf(stderr, "FAIL hybrid_compose_host: %s\n", msg);
    std::exit(1);
}

static void fill_plane(std::vector<uint8_t>& p, int w, int h, int frames, uint8_t yv) {
    const int fb = frameBytes(w, h);
    p.assign(static_cast<size_t>(frames * fb), 0);
    for (int f = 0; f < frames; ++f) {
        uint8_t* base = p.data() + static_cast<size_t>(f * fb);
        std::memset(base, yv + static_cast<uint8_t>(f), static_cast<size_t>(w * h));
        std::memset(base + w * h, 0x80, static_cast<size_t>((w / 2) * (h / 2) * 2));
    }
}

int main() {
    constexpr int W = 320, H = 240, F = 12;
    constexpr int NMB = 300;
    // Pre-register
    std::fprintf(stderr,
                 "PRE-REGISTER hybrid_compose_host: 320x240 → %d MB/frame; kinds I+11P → "
                 "fpga_mb=%d host_mb=%d (ARM owns all P MBs under CAP_INTER_*=0)\n",
                 NMB, NMB, NMB * 11);

    std::vector<char> kinds = {'I', 'P', 'P', 'P', 'P', 'P', 'P', 'P', 'P', 'P', 'P', 'P'};
    OwnMap map = buildOwnMapFromKinds(W, H, kinds);
    if (!map.complete)
        fail("default own map incomplete");

    std::vector<uint8_t> gold, bad_fpga;
    fill_plane(gold, W, H, F, 0x40);
    bad_fpga = gold;
    // Corrupt P-frame 1 Y (mutation source)
    {
        const int fb = frameBytes(W, H);
        std::memset(bad_fpga.data() + fb, 0x5A, static_cast<size_t>(W * H));
    }

    std::vector<uint8_t> out;
    ComposeSummary sum{};
    if (!composeI420(gold.data(), gold.size(), gold.data(), gold.size(), W, H, F, map, out,
                     sum, /*allow_host_fallback=*/false))
        fail(sum.fail_reason ? sum.fail_reason : "compose green");
    if (sum.fpga_mb != NMB || sum.host_mb != NMB * 11 || sum.total_mb != NMB * F)
        fail("fraction miss vs pre-register");
    if (sum.product_recon_ok)
        fail("product_recon_ok must be 0 with host MBs");
    if (out != gold)
        fail("default compose must equal host=fpga golden");
    std::fprintf(stderr, "OK hybrid_compose_host green: fpga_mb=%d/%d host_mb=%d\n",
                 sum.fpga_mb, sum.total_mb, sum.host_mb);

    // Mutation twin: claim inter as FPGA (CAP_INTER on) + bad FPGA P pixels → composite ≠ gold
    Caps claim = Caps{};
    claim.cap_inter_p16 = true;
    claim.cap_inter_pskip = true;
    OwnMap claim_map = buildOwnMapFromKinds(W, H, kinds, claim);
    ComposeSummary bad_sum{};
    std::vector<uint8_t> bad_out;
    if (!composeI420(bad_fpga.data(), bad_fpga.size(), gold.data(), gold.size(), W, H, F,
                     claim_map, bad_out, bad_sum, /*allow_host_fallback=*/false))
        fail("mutation compose should succeed structurally");
    if (bad_sum.fpga_mb != NMB * F)
        fail("claimed-inter must mark all MBs FPGA");
    if (bad_out == gold)
        fail("MUTATION twin did not diverge — silent plausible failure");
    std::fprintf(stderr,
                 "OK hybrid_compose_host mutation twin: claim-inter + bad FPGA went RED "
                 "(bytes differ)\n");

    // Fail-closed: unmarked MB
    OwnMap hole = map;
    hole.owners.pop_back();
    hole.complete = false;
    ComposeSummary hole_sum{};
    std::vector<uint8_t> hole_out;
    if (composeI420(gold.data(), gold.size(), gold.data(), gold.size(), W, H, F, hole,
                    hole_out, hole_sum, false))
        fail("incomplete map must hard-fail");
    if (!hole_sum.hard_fail)
        fail("incomplete map must set hard_fail");
    std::fprintf(stderr, "OK hybrid_compose_host fail-closed incomplete map\n");

    // product_recon_ok signal with host MBs must hard-fail
    OwnMap one = buildFrameOwnMap(W, H, 'P');
    FpgaOwnSignal sig;
    sig.valid = true;
    sig.product_recon_ok = true;
    ComposeSummary contra{};
    if (applyFpgaOwnSignal(one, sig, &contra))
        fail("product_recon_ok + host MB must fail");
    std::fprintf(stderr, "OK hybrid_compose_host product_recon_ok contradiction hard-fail\n");

    // Live decision: P frame, no FPGA plane, fallback → all host, 300 host MB
    std::vector<uint8_t> host1, comp;
    fill_plane(host1, W, H, 1, 0x22);
    FpgaOwnSignal live = signalFromStatus(true, /*P*/ 0, 0, true, true, true, false);
    PresentDecision d =
        decidePresentFrame(W, H, 'P', host1.data(), host1.size(), nullptr, 0, live, Caps{},
                           comp, /*allow_host_fallback=*/true, /*allow_skip_host_f1=*/false);
    if (!d.ok)
        fail(d.fail_reason ? d.fail_reason : "decide P");
    if (d.summary.host_mb != NMB || d.summary.fpga_mb != 0)
        fail("P frame must be 300 host MB under default caps");
    std::fprintf(stderr, "OK hybrid_compose_host decide P: %s\n", d.log_line.c_str());

    // Pre-register publish actual
    std::fprintf(stderr,
                 "ACTUAL hybrid_compose_host: fpga_fraction=%d/%d host_fraction=%d/%d "
                 "ARM_owned_mb_per_P_frame=%d (falsify if CAP_INTER default becomes 1)\n",
                 NMB, NMB * F, NMB * 11, NMB * F, NMB);
    std::printf("test_hybrid_compose_host: OK\n");
    return 0;
}
