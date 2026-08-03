#include "libmisterplex/fabric_ddr_bandwidth.hpp"
#include <cmath>
#include <cstdio>

using namespace misterplex;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#c); ++fails; } } while(0)
static bool near(double a, double b, double eps = 1e-3) { return std::fabs(a - b) < eps; }

int main() {
    CHECK(kFabricDdrPeakMBps == 720.0);
    CHECK(kFabric720pFrameBytes == 1382400);
    CHECK(kFabric720pFrameBeats == 172800);
    CHECK(near(kWriterMBps24, 33.1776));
    CHECK(near(kWriterMBps60, 82.944));
    CHECK(near(kCombinedMBps24, 66.3552));
    CHECK(near(kCombinedMBps60, 165.888));
    CHECK(near(kCombinedFracPeak24, 66.3552 / 720.0));
    CHECK(near(kCombinedFracPeak60, 165.888 / 720.0));
    // Theoretical peak headroom: 24 and 60 both under 85% of peak bytes
    CHECK(fabricCombinedFitsTheoreticalPeak(24.0));
    CHECK(fabricCombinedFitsTheoreticalPeak(60.0));
    // Half-share model: writer alone still closes at 60 (82.9 < 360)
    CHECK(writerClosesAtFpsWithHalfShare(60.0));
    CHECK(writerClosesAtFpsWithHalfShare(24.0));
    // Sticky full-frame lockout ~1.92 ms (defect class if sticky returns)
    CHECK(stickyM2FullFrameLockoutMs() > 1.9 && stickyM2FullFrameLockoutMs() < 2.0);
    // Multi-pixel clk_sys: 720p60 / 2ppc = 37.125 MHz > product 20 MHz
    CHECK(near(clkSysHzForPpc(60.0, 2) / 1e6, 37.125));
    CHECK(near(clkSysHzForPpc(24.0, 2) / 1e6, 14.85)); // CEA full blanking
    // w-clock quoted 11.06 for 720p24@2ppc — that used a different blanking model;
    // CEA 1650*750*24/2 = 14.85 MHz. Record both; do not silently equate.
    CHECK(clkSysHzForPpc(24.0, 2) > 20e6 ? false : true); // 14.85 < 20 PASS
    CHECK(clkSysHzForPpc(60.0, 2) > 20e6); // 37.125 > 20 — needs 4ppc or faster clk
    CHECK(near(clkSysHzForPpc(60.0, 4) / 1e6, 18.5625)); // under 20

    // Clean ARM budget anchors
    CHECK(near(kParentCleanDecodeAloneMs, 35.94));
    CHECK(near(kParentCleanDecodeMarginMs, 5.727));
    CHECK(kParentCleanDecodePlusMemPeerMs > kFrameBudget24Ms);
    CHECK(kParentBankCpuStoreStructuralCeiling);
    CHECK(near(kParentCleanBankStoreMibps, 88.045));

    // Fabric decode+present (bitstream ring + refs + recon + scan) — theoretical.
    const double dec24 = fabricDecodePresentCombinedMBps(24.0, 1.5);
    const double dec60 = fabricDecodePresentCombinedMBps(60.0, 1.5);
    CHECK(dec24 > 100.0 && dec24 < 150.0);
    CHECK(dec60 > 250.0 && dec60 < 350.0);
    CHECK(dec60 < kFabricDdrPeakMBps * 0.5);
    CHECK(fabricBitstreamRingReadMBps(2585.0) < 0.5);

    // IMPORTANT: theoretical peak fit ≠ device PASS. Mark unknown for glass.
    // Device sustained fabric BW: parent post-fit only.

    if (fails) { std::fprintf(stderr,"test_fabric_ddr_bandwidth: %d fails\n", fails); return 1; }
    std::printf("test_fabric_ddr_bandwidth: OK\n");
    std::printf("  peak_MBps=%.1f writer24=%.3f scan24=%.3f comb24=%.3f frac24=%.4f\n",
                kFabricDdrPeakMBps, kWriterMBps24, kScanMBps24, kCombinedMBps24,
                kCombinedFracPeak24);
    std::printf("  writer60=%.3f comb60=%.3f frac60=%.4f sticky_lock_ms=%.3f\n",
                kWriterMBps60, kCombinedMBps60, kCombinedFracPeak60,
                stickyM2FullFrameLockoutMs());
    std::printf("  clk_sys_2ppc_24=%.3fMHz clk_sys_2ppc_60=%.3fMHz clk_sys_4ppc_60=%.3fMHz\n",
                clkSysHzForPpc(24.0, 2) / 1e6, clkSysHzForPpc(60.0, 2) / 1e6,
                clkSysHzForPpc(60.0, 4) / 1e6);
    std::printf("  decode_present24=%.1f decode_present60=%.1f bitstream_rd=%.3f\n",
                dec24, dec60, fabricBitstreamRingReadMBps(2585.0));
    std::printf("  THEORETICAL_ONLY device_fabric_BW=unknown_until_parent_fit\n");
    return 0;
}
