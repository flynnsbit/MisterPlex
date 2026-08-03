// 720p DDR ABI gate (w-mem): arithmetic, Option-C map, product 480p freeze,
// native-geometry push savings, PLXG encode. true rc direct — soft-skip never.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_present_bank.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                       \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

int main() {
    using namespace misterplex;

    // --- Arithmetic from source formulas (not parent-table trust) ---
    CHECK(yuv420pFrameBytes(1280, 720) == 1382400u);
    CHECK(static_cast<size_t>(kPlex720pYuv420pBytes) == 1382400u);
    CHECK(kPlex720pYStrideBytes == 1280);
    CHECK(kPlex720pChromaStrideBytes == 640);
    CHECK(kPlex720pYPlaneOffset == 0);
    CHECK(kPlex720pUPlaneOffset == 1280 * 720);
    CHECK(kPlex720pVPlaneOffset == 1280 * 720 + (1280 / 2) * (720 / 2));
    CHECK(kPlex720pYuvLumaLineQwords == 1280 / 8);
    CHECK(kPlex720pYuvChromaLineQwords == 1280 / 16);
    // 1280 B luma line = 10240 bits = exactly one M10K depth*width bit budget unit.
    CHECK(kPlex720pYStrideBytes * 8 == 10240);
    CHECK(alignUpU32(1382400u, kDdrFrameStrideAlign) == 0x180000u);
    CHECK(kPlex720pYuv420pBankStride == 0x180000u);
    // Naive enlarge at product phys base (documents why Option-A is banned).
    const auto naive =
        makeDdrFrameLayout(plex720pDdrFrameGeometry(), kDdrFramePhysBase, kDdrFrameStrideAlign);
    CHECK(naive.bank_stride == 0x180000u);
    CHECK(naive.doorbell_phys == 0x302FF000u); // base + 2*stride - 0x1000
    CHECK(naive.map_bytes == 0x300000u);
    // Parent brief said doorbell >= 0x30300000 — CORRECTED: geometry formula yields
    // 0x302FF000 at base 0x30000000; map *ends* at 0x30300000. Option-A still stomps
    // bitstream ring @0x30100000 (bank0 ends 0x30151800).
    CHECK(kDdrFramePhysBase + naive.frame_bytes > 0x30100000u);

    // --- Option-C 720p tier (ratified) ---
    const auto t720 = makePlex720pDdrFrameLayout();
    CHECK(ddrFrameLayoutValid(t720));
    CHECK(ddrFrameLayoutMatches720pTier(t720));
    CHECK(!ddrFrameLayoutMatchesProductSilicon(t720));
    CHECK(t720.phys_base == kPlex720pDdrFramePhysBase);
    CHECK(t720.phys_base == 0x30180000u);
    CHECK(t720.bank_stride == 0x180000u);
    CHECK(t720.doorbell_phys == 0x3047F000u);
    CHECK(t720.doorbell_phys == t720.phys_base + 2u * t720.bank_stride - 0x1000u);
    CHECK(t720.frame_bytes == 1382400u);
    CHECK(t720.y_offset == 0u);
    CHECK(t720.u_offset == 921600u);
    CHECK(t720.v_offset == 1152000u);
    CHECK(t720.line_bytes == 1280);
    CHECK(t720.chroma_line_bytes == 640);
    CHECK(t720.line_qwords == 160);
    CHECK(t720.chroma_line_qwords == 80);
    // Banks clear of bitstream ring [0x30100000, 0x30140000) and PLXB.
    CHECK(t720.phys_base >= 0x30180000u);
    CHECK(t720.phys_base + t720.frame_bytes <= t720.phys_base + t720.bank_stride);
    CHECK(t720.phys_base + t720.bank_stride + t720.frame_bytes <= t720.doorbell_phys);

    // Publish plan at Option-C phys base (bank1).
    std::vector<uint8_t> yuv(t720.frame_bytes, 0x10);
    DdrPublishFrame fr{yuv.data(), yuv.size(), plex720pDdrFrameGeometry(), DdrFrameFormat::Yuv420p};
    DdrPublishPlan plan{};
    std::string err;
    CHECK(makePlex720pDdrPublishPlan(fr, 1, plan, &err));
    CHECK(plan.layout.phys_base == 0x30180000u);
    CHECK(plan.bank_offset == 0x180000u);
    CHECK(plan.bank_phys == 0x30300000u);
    CHECK(plan.layout.doorbell_phys == 0x3047F000u);
    // Default phys base must NOT silently produce Option-C addresses.
    DdrPublishPlan badBase{};
    CHECK(makeDdrPublishPlan(fr, 1, badBase, &err)); // valid math at 0x30000000
    CHECK(badBase.layout.doorbell_phys == 0x302FF000u);
    CHECK(badBase.layout.doorbell_phys != kPlex720pYuv420pDoorbellPhys);

    // --- Product 480p must not regress ---
    const auto p480 = makeDdrFrameLayout(plex480pDdrFrameGeometry());
    CHECK(ddrFrameLayoutMatchesProductSilicon(p480));
    CHECK(p480.bank_stride == 0x80000u);
    CHECK(p480.doorbell_phys == 0x300FF000u);
    CHECK(p480.frame_bytes == 449280u);
    CHECK(!ddrFrameStoreAcceptsResolution(1280, 720)); // product gate still rejects
    CHECK(ddrFrameStoreAccepts720pTier(1280, 720));
    CHECK(ddrFrameStoreAccepts720pTier(624, 480)); // smaller fits in 720p stride
    CHECK(!ddrFrameStoreAccepts720pTier(1920, 1080));

    // Pixel / bandwidth arithmetic (quoted rates from p480-bandwidth archive).
    constexpr double kNoSyncMibps = 59.521; // docs/evidence/p480/p480-bandwidth.md
    const double ms720 = ddrPushMsAtRate(1382400u, kNoSyncMibps);
    const double ms480 = ddrPushMsAtRate(449280u, kNoSyncMibps);
    CHECK(ms480 > 7.0 && ms480 < 7.5);   // ~7.199 measured class
    CHECK(ms720 > 22.0 && ms720 < 22.5); // ~22.149 projection
    // Push payload rate (decimal MB/s) at 24/30 fps.
    const double push24 = 1382400.0 * 24.0 / 1e6;
    const double push30 = 1382400.0 * 30.0 / 1e6;
    CHECK(push24 > 33.0 && push24 < 33.3);
    CHECK(push30 > 41.4 && push30 < 41.6);
    const double pixRatio =
        (1280.0 * 720.0) / (static_cast<double>(kPlex480pCodedWidth.get()) *
                            static_cast<double>(kPlex480pCodedHeight.get()));
    CHECK(pixRatio > 3.07 && pixRatio < 3.08);

    // --- fab-dma native geometry savings ---
    const auto native320 = makeDdrNativePushPlan(320, 240, plex480pDdrFrameGeometry());
    CHECK(native320.valid);
    CHECK(native320.native_bytes == 115200u);
    CHECK(native320.canvas_bytes == 449280u);
    CHECK(native320.saved_bytes == 334080u);
    // 334080/449280 ≈ 0.7436
    CHECK(native320.save_ratio > 0.74 && native320.save_ratio < 0.75);
    const double msNative320 = ddrPushMsAtRate(native320.native_bytes, kNoSyncMibps);
    const double msCanvas480 = ddrPushMsAtRate(native320.canvas_bytes, kNoSyncMibps);
    CHECK(msNative320 < 2.0);
    CHECK(msCanvas480 > 7.0);
    // Full 720p content on 720p canvas: no pad savings.
    const auto native720 = makeDdrNativePushPlan(1280, 720, plex720pDdrFrameGeometry());
    CHECK(native720.valid);
    CHECK(native720.saved_bytes == 0u);
    CHECK(native720.save_ratio == 0.0);
    // 480p content into 720p canvas would save if fabric window used.
    const auto n480on720 = makeDdrNativePushPlan(624, 480, plex720pDdrFrameGeometry());
    CHECK(n480on720.valid);
    CHECK(n480on720.native_bytes == 449280u);
    CHECK(n480on720.canvas_bytes == 1382400u);
    CHECK(n480on720.saved_bytes == 1382400u - 449280u);

    std::vector<uint8_t> src320(115200u, 0x41);
    std::vector<uint8_t> dst320(115200u, 0);
    CHECK(copyYuv420pNativeOrigin(src320.data(), 320, 240, dst320.data(), dst320.size()));
    CHECK(dst320[0] == 0x41);
    CHECK(dst320[115199] == 0x41);
    CHECK(!copyYuv420pNativeOrigin(src320.data(), 320, 240, dst320.data(), 100)); // cap fail

    // --- PLXG mailbox contract ---
    CHECK(kDdrFramePlxgOffset == mailbox_abi::kPlxgOffset);
    CHECK(kDdrFramePlxgMagic == mailbox_abi::kPlxgMagic);
    CHECK(plxgMailboxPhys(kPlex480pYuv420pDoorbellPhys) == 0x300FF000u + 0x130u);
    CHECK(plxgMailboxPhys(kPlex720pYuv420pDoorbellPhys) == 0x3047F000u + 0x130u);

    // Parent-verified reserved window (2026-08-02 device evidence).
    CHECK(kPlexDdrReservedWindowStart == 0x1FF00000u);
    CHECK(kPlexDdrReservedWindowEnd == 0x40000000u);
    CHECK(kPlex720pDdrFramePhysBase >= kPlexDdrReservedWindowStart);
    CHECK(kPlex720pYuv420pDoorbellPhys + 0x1000u <= kPlexDdrReservedWindowEnd);
    CHECK(kPlex720pMapBytes2Bank == 2u * kPlex720pYuv420pBankStride);
    CHECK(kPlex720pMapBytes3Bank == 3u * kPlex720pYuv420pBankStride);
    CHECK(kPlex720pDdrFramePhysBase + kPlex720pMapBytes3Bank <= kPlexDdrReservedWindowEnd);
    CHECK(kPlex720pTripleDoorbellPhys ==
          kPlex720pDdrFramePhysBase + 3u * kPlex720pYuv420pBankStride - 0x1000u);
    const uint64_t word = encodePlxgGeometryWord(1280, 720, true, true);
    int dw = 0, dh = 0;
    bool en = false, nat = false;
    CHECK(decodePlxgGeometryWord(word, dw, dh, en, nat));
    CHECK(dw == 1280 && dh == 720 && en && nat);
    CHECK(!decodePlxgGeometryWord(0, dw, dh, en, nat));
    const uint64_t win = encodePlxgContentWindow(320, 240, 0, 0);
    int cw = 0, ch = 0;
    CHECK(decodePlxgContentWindow(win, cw, ch));
    CHECK(cw == 320 && ch == 240);
    CHECK(!decodePlxgGeometryWord(win, dw, dh, en, nat)); // window beat ≠ geometry
    const uint64_t org = encodePlxgContentOrigin(148, 120);
    int ox = 0, oy = 0;
    CHECK(decodePlxgContentOrigin(org, ox, oy));
    CHECK(ox == 148 && oy == 120);

    // --- Fabric-owned present: ARM out of scale/pad/pack (preferred) ---
    CHECK(fabricOwnedForbidsArmCanvasPack());
    CHECK(fabricOwnedForbidsArmFfmpegScalePad());
    CHECK(fabricOwnedForbidsArmClearYuvCropPad());
    // 320 content on product 480p canvas — evacuate pad copy + FEED scale bucket.
    const auto fab320 =
        makeDdrFabricOwnedPresentPlan(320, 240, plex480pDdrFrameGeometry(), kDdrFramePhysBase);
    CHECK(fab320.valid);
    CHECK(fab320.publish_bytes == 115200u);
    CHECK(fab320.publish_bytes != 449280u);
    CHECK(fab320.budget.fabric_owned);
    CHECK(fab320.budget.arm_still_pushes_pixels); // until FPGA decode
    CHECK(fab320.budget.copy_ms_removed > 5.3 && fab320.budget.copy_ms_removed < 5.4);
    CHECK(fab320.budget.scale_ms_removed_feed480 == kFeedArchiveScaleMs);
    // known floor = copy projection + FEED scale ≈ 5.35 + 2.95 = 8.30 ms
    CHECK(fab320.budget.known_ms_removed_floor > 8.2 &&
          fab320.budget.known_ms_removed_floor < 8.4);
    std::vector<uint8_t> natPay(fab320.publish_bytes, 0x22);
    DdrFabricOwnedPublishPlan fpub{};
    CHECK(makeDdrFabricOwnedPublishPlan(natPay.data(), 0, fab320, fpub, &err));
    CHECK(fpub.payload_bytes == 115200u);
    CHECK(fpub.publish.layout.frame_bytes == 449280u); // tier bank still 480p
    CHECK(fpub.payload_bytes < fpub.publish.layout.frame_bytes);

    // 720p tier + full 720p content with ARM tight write: pad savings 0.
    // Parent bitrate sweep: 4000k residual ~0.59 ms; candidate 1500k ~9.24 ms.
    // Tight 720p memcpy ~22.15 ms EXCEEDS BOTH → NOT ship-acceptable either tier.
    const auto fab720 = makeDdrFabricOwnedPresentPlan(
        1280, 720, plex720pDdrFrameGeometry(), kPlex720pDdrFramePhysBase);
    CHECK(fab720.valid);
    CHECK(fab720.publish_bytes == 1382400u);
    CHECK(fab720.budget.copy_ms_removed == 0.0);
    CHECK(fab720.budget.scale_ms_removed_feed480 == kFeedArchiveScaleMs);
    CHECK(fab720.budget.known_ms_removed_floor == kFeedArchiveScaleMs);
    CHECK(fab720.canvas_layout.doorbell_phys == 0x3047F000u);
    CHECK(fab720.budget.arm_still_pushes_pixels);
    CHECK(!ddr720p24ShipAcceptsZeroArmPerPixel(fab720.budget));
    CHECK(ddr720p24ArmCopyExceedsDecodeMargin(1382400u)); // 4000k residual
    CHECK(ddr720p24ArmCopyExceedsCandidateTierMargin(1382400u)); // 1500k residual
    CHECK(kPlex720pCandidateBitrateKbit == 1500);
    CHECK(kParent720pDecodeMs1500k == 32.427);
    CHECK(kParent720pDecodeMs4000k == 41.073);
    CHECK(kParent720pDecodeMsDefaultThreads == kParent720pDecodeMs4000k);
    CHECK(ddr720p24ResidualMsAfterDecodeOnly() > 0.5 &&
          ddr720p24ResidualMsAfterDecodeOnly() < 0.7); // ~0.594 @4000k
    const double res1500 =
        ddr720p24ResidualMsAfterDecodeOnly(kParent720pDecodeMsCandidateTier);
    CHECK(res1500 > 9.2 && res1500 < 9.3); // ~9.24
    // Tier saves ~8.65 ms vs 4000k — still less than full-frame copy ~22 ms.
    CHECK((res1500 - ddr720p24ResidualMsAfterDecodeOnly()) > 8.5 &&
          (res1500 - ddr720p24ResidualMsAfterDecodeOnly()) < 8.8);
    CHECK(kFeedArchiveNonDecodeMs > 18.6 && kFeedArchiveNonDecodeMs < 18.7);

    // ONLY ship path: FPGA-written banks, ARM push_bytes=0.
    const auto fpgaBanks =
        makeDdrFpgaWrittenBankPlan(plex720pDdrFrameGeometry(), kPlex720pDdrFramePhysBase);
    CHECK(fpgaBanks.valid);
    CHECK(fpgaBanks.publish_bytes == 0u);
    CHECK(fpgaBanks.budget.arm_push_bytes == 0u);
    CHECK(fpgaBanks.budget.arm_copy_ms == 0.0);
    CHECK(!fpgaBanks.budget.arm_still_pushes_pixels);
    CHECK(fpgaBanks.budget.zero_arm_per_pixel);
    CHECK(ddr720p24ShipAcceptsZeroArmPerPixel(fpgaBanks.budget));
    // Entire canvas copy term counted as removed vs ARM-push baseline.
    CHECK(fpgaBanks.budget.copy_ms_removed > 22.0 && fpgaBanks.budget.copy_ms_removed < 22.3);
    CHECK(fpgaBanks.budget.known_ms_removed_floor >
          fpgaBanks.budget.copy_ms_removed); // + FEED scale

    // 480p content on 720p canvas: large pad evacuation if ARM had been
    // forced to fill 720p banks (ugly path we refuse to keep on ARM).
    const auto fab480on720 = makeDdrFabricOwnedPresentPlan(
        624, 480, plex720pDdrFrameGeometry(), kPlex720pDdrFramePhysBase);
    CHECK(fab480on720.valid);
    CHECK(fab480on720.publish_bytes == 449280u);
    CHECK(fab480on720.budget.copy_ms_removed > 14.0); // 22.15-7.20 class
    CHECK(fab480on720.budget.known_ms_removed_floor >
          fab480on720.budget.copy_ms_removed); // includes scale floor

    // Tier mismatch guard: 720p layout must never claim product silicon match.
    CHECK(!ddrFrameLayoutMatchesProductSilicon(t720));
    CHECK(!ddrFrameLayoutMatches720pTier(p480));

    if (fails) {
        std::fprintf(stderr, "test_ddr_720p_abi: %d fails\n", fails);
        return 1;
    }
    std::printf("test_ddr_720p_abi: OK\n");
    std::printf("  720p bytes=%d stride=0x%x base=0x%x doorbell=0x%x\n", kPlex720pYuv420pBytes,
                static_cast<unsigned>(kPlex720pYuv420pBankStride),
                static_cast<unsigned>(kPlex720pDdrFramePhysBase),
                static_cast<unsigned>(kPlex720pYuv420pDoorbellPhys));
    std::printf("  native320 save_ratio=%.4f ms_native=%.3f ms_canvas=%.3f (@%.3f MiB/s)\n",
                native320.save_ratio, msNative320, msCanvas480, kNoSyncMibps);
    std::printf("  push_MBps 24=%.3f 30=%.3f copy_ms720=%.3f\n", push24, push30, ms720);
    std::printf("  FABRIC_OWNED 320on480 known_ms_removed_floor=%.3f "
                "(copy=%.3f + feed_scale=%.3f)\n",
                fab320.budget.known_ms_removed_floor, fab320.budget.copy_ms_removed,
                fab320.budget.scale_ms_removed_feed480);
    std::printf("  FABRIC_OWNED 720 native known_ms_removed_floor=%.3f "
                "(copy=%.3f; arm_still_pushes=%d) SHIP_OK=%d\n",
                fab720.budget.known_ms_removed_floor, fab720.budget.copy_ms_removed,
                fab720.budget.arm_still_pushes_pixels ? 1 : 0,
                ddr720p24ShipAcceptsZeroArmPerPixel(fab720.budget) ? 1 : 0);
    std::printf("  FPGA_WRITTEN_BANKS publish_bytes=%zu known_ms_removed_floor=%.3f "
                "SHIP_OK=%d residual_4000k=%.3f residual_1500k=%.3f\n",
                fpgaBanks.publish_bytes, fpgaBanks.budget.known_ms_removed_floor,
                ddr720p24ShipAcceptsZeroArmPerPixel(fpgaBanks.budget) ? 1 : 0,
                ddr720p24ResidualMsAfterDecodeOnly(),
                ddr720p24ResidualMsAfterDecodeOnly(kParent720pDecodeMsCandidateTier));
    std::printf("  tier_candidate_kbit=%d copy_ms720=%.3f exceeds_1500k_margin=%d "
                "exceeds_4000k_margin=%d\n",
                kPlex720pCandidateBitrateKbit, ms720,
                ddr720p24ArmCopyExceedsCandidateTierMargin(1382400u) ? 1 : 0,
                ddr720p24ArmCopyExceedsDecodeMargin(1382400u) ? 1 : 0);
    return 0;
}
