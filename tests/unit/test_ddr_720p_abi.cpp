// 720p DDR ABI gate (w-mem): arithmetic, Option-C map, product 480p freeze,
// native-geometry push savings, PLXG encode. true rc direct — soft-skip never.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_mem_map_policy.hpp"
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
    CHECK(kDdrBitstreamMeasuredWorstAuBytes == 60915u);
    CHECK(kDdrBitstreamRingBytes >= kDdrBitstreamMinWorstAuSlots * kDdrBitstreamWorstAuRecordBytes);
    CHECK(kDdrBitstreamRingDataPhys == 0x30100000u);
    CHECK(kDdrBitstreamRingBytes == 262144u);
    CHECK(kDdrBitstreamRingCtrlPhys == 0x30140000u);
    CHECK(kDdrBitstreamRingDataPhys + kDdrBitstreamRingBytes == kDdrBitstreamRingCtrlPhys);
    CHECK(kDdrBitstreamRingCtrlPhys + 0x50u <= t720.phys_base);
    CHECK(t720.doorbell_phys + 0x1000u <= kDdrPl330ScratchPhys);
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
    constexpr double kMappedMibps = kParentDdrMappedBankMibps; // parent 2026-08-03
    constexpr double kArchiveMibps = kDdrArchiveNoSyncMibps; // 59.521 legacy
    const double ms720 = ddrPushMsAtRate(1382400u, kMappedMibps);
    const double ms480 = ddrPushMsAtRate(449280u, kMappedMibps);
    const double ms720archive = ddrPushMsAtRate(1382400u, kArchiveMibps);
    CHECK(ms720 > 14.9 && ms720 < 15.1); // structural ~14.974 @ 88.045
    CHECK(ms720archive > 22.0 && ms720archive < 22.3); // old archive 22.15
    CHECK(ms480 > 4.6 && ms480 < 5.0);   // canvas @ 88.045
    CHECK(kParentDdrBestBank720pFrameMs > 14.9 && kParentDdrBestBank720pFrameMs < 15.1);
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
    const double msNative320 = ddrPushMsAtRate(native320.native_bytes, kMappedMibps);
    const double msCanvas480 = ddrPushMsAtRate(native320.canvas_bytes, kMappedMibps);
    CHECK(msNative320 < 1.5); // ~1.268 @ mapped
    CHECK(msCanvas480 > 4.7 && msCanvas480 < 5.0);
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

    // --- PLXG mailbox contract (5-qword @ +0x2C0; PLXC owns +0x130) ---
    CHECK(kDdrFramePlxgOffset == mailbox_abi::kPlxgOffset);
    CHECK(kDdrFramePlxgMagic == mailbox_abi::kPlxgMagic);
    CHECK(kDdrFramePlxgOffset == 0x2C0u);
    CHECK(mailbox_abi::kPlxgBootstrapPhys == 0x300FF2C0u);
    CHECK(plxgMailboxPhys(kPlex480pYuv420pDoorbellPhys) == 0x300FF000u + 0x2C0u);
    CHECK(plxgMailboxPhys(kPlex720pYuv420pDoorbellPhys) == 0x3047F000u + 0x2C0u);
    // NEG: +0x130 is PLXC chrome ctrl — must not be PLXG.
    CHECK(kDdrFramePlxgOffset != 0x130u);

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
    CHECK(fab320.budget.copy_ms_removed > 3.6 && fab320.budget.copy_ms_removed < 3.8); // ~3.67
    CHECK(fab320.budget.scale_ms_removed_feed480 == kFeedArchiveScaleMs);
    // known floor = copy projection + FEED scale ≈ 5.35 + 2.95 = 8.30 ms
    CHECK(fab320.budget.known_ms_removed_floor > 6.5 &&
          fab320.budget.known_ms_removed_floor < 6.8); // mapped-rate + FEED scale
    std::vector<uint8_t> natPay(fab320.publish_bytes, 0x22);
    DdrFabricOwnedPublishPlan fpub{};
    CHECK(makeDdrFabricOwnedPublishPlan(natPay.data(), 0, fab320, fpub, &err));
    CHECK(fpub.payload_bytes == 115200u);
    CHECK(fpub.publish.layout.frame_bytes == 449280u); // tier bank still 480p
    CHECK(fpub.payload_bytes < fpub.publish.layout.frame_bytes);

    // 720p tier + full 720p content with ARM tight write: pad savings 0.
    // Parent bitrate sweep: 4000k residual ~0.59 ms; candidate 1500k ~9.24 ms.
    // Tight 720p mapped copy ~15.21 ms EXCEEDS BOTH residuals → NOT ship-acceptable.
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
    CHECK(kPlex720pCandidateBitrateKbit == 3100); // PMS maxBR floor (w-path d273d6f8)
    CHECK(kPlex720pCandidateContentBitrateKbit == 2600);
    CHECK(kParent720pDecodeMs1500k == 32.427);
    CHECK(kParent720pDecodeMs2500k == 35.87); // in-session re-anchor
    CHECK(kParent720pDecodeMs2500kArchive == 36.845);
    CHECK(kParent720pDecodeMs2600k == 36.27);
    CHECK(kParent720pDecodeMs3500k == 38.751);
    CHECK(kParent720pDecodeMs4000k == 41.073);
    CHECK(kParent720pDecodeMsDefaultThreads == kParent720pDecodeMs4000k);
    CHECK(kParent720pDecodeMsCandidateTier == kParent720pDecodeMs2600k);
    CHECK(ddr720p24ResidualMsAfterDecodeOnly() > 0.5 &&
          ddr720p24ResidualMsAfterDecodeOnly() < 0.7); // ~0.594 @4000k
    const double resCand =
        ddr720p24ResidualMsAfterDecodeOnly(kParent720pDecodeMsCandidateTier);
    CHECK(resCand > 5.3 && resCand < 5.5); // ~5.397 @2600k product tier
    const double res3500archive =
        ddr720p24ResidualMsAfterDecodeOnly(kParent720pDecodeMs3500k);
    CHECK(res3500archive > 2.9 && res3500archive < 3.0); // archive ~2.916
    const double res1500 =
        ddr720p24ResidualMsAfterDecodeOnly(kParent720pDecodeMs1500k);
    CHECK(res1500 > 9.2 && res1500 < 9.3); // decode residual only; not a delivery tier
    // 1500k residual gain vs 4000k still < present bucket (parent correction).
    CHECK((res1500 - ddr720p24ResidualMsAfterDecodeOnly()) > 8.5 &&
          (res1500 - ddr720p24ResidualMsAfterDecodeOnly()) < 8.8);
    CHECK(kFeedArchiveNonDecodeMs > 18.6 && kFeedArchiveNonDecodeMs < 18.7);

    // Sweep-3: best bank ~15.28 ms; serial FAIL all tiers; host-copy unreachable.
    CHECK(kParentDdrMappedBankMibps == 88.045);
    CHECK(kParentDdrBestBank720pFrameMs == 14.974);
    CHECK(kParentDdrCoherentFlush720pFrameMs == 19.861);
    CHECK(ddr720p24CoherentFlushPenaltyMs() > 4.8 &&
          ddr720p24CoherentFlushPenaltyMs() < 5.0); // vs 14.974 best
    CHECK(!ddr720p24MappedPathFitsAt1500k());
    CHECK(!ddr720p24SerialPathFitsAt2600k()); // product tier serial FAIL ~51.55
    CHECK(!ddr720p24SerialPathFitsAt3500k());
    CHECK(!ddr720p24SerialPathFitsAt4000k());
    CHECK(!ddr720p24HostCopyIsReachableBankRate());
    CHECK(ddrBankCpuStoreMapFlagIsInert());
    CHECK(ddrBankCpuStoreIsStructuralUncachedCeiling());
    CHECK(ddr720p24CpuFullFrameMovePathIsDead());
    CHECK(!ddr720p24HostCopyCeilingFitsAt1500k()); // RETRACTED
    CHECK(ddr720p24MappedToHostCopyMsSaved() == 0.0);
    // Route A sketch (unproven contention): max(36.27,15.283)=36.27 PASS.
    CHECK(ddr720p24OverlapSketchFitsAt2600k());
    CHECK(ddr720p24OverlapMaxDecodeCopyFits(36.27, 14.974));
    CHECK(!ddr720p24OverlapMaxDecodeCopyFits(36.27, 14.974, 36.0));
    // Map policy: cached path must not ring doorbell without flush (red-green).
    CHECK(ddrMemMapConfPublishSafe(true, false));
    CHECK(ddrMemMapConfPublishSafe(true, true));
    CHECK(!ddrMemMapConfPublishSafe(false, false)); // RED without flush
    CHECK(ddrMemMapConfPublishSafe(false, true));
    CHECK(ddrMemMayRingDoorbell(DdrMemMapPolicy::StronglyOrderedSync, false));
    CHECK(!ddrMemMayRingDoorbell(DdrMemMapPolicy::CachedExplicitFlush, false));
    CHECK(ddrMemMayRingDoorbell(DdrMemMapPolicy::CachedExplicitFlush, true));
    {
        const auto syncSpec = ddrMemMapOpenSpec(DdrMemMapPolicy::StronglyOrderedSync);
        CHECK((syncSpec.open_flags & O_SYNC) != 0);
        CHECK(!syncSpec.requires_dcache_flush_before_doorbell);
        const auto cachedSpec = ddrMemMapOpenSpec(DdrMemMapPolicy::CachedExplicitFlush);
        CHECK((cachedSpec.open_flags & O_SYNC) == 0);
        CHECK(cachedSpec.requires_dcache_flush_before_doorbell);
    }

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
    CHECK(fpgaBanks.budget.copy_ms_removed > 14.9 && fpgaBanks.budget.copy_ms_removed < 15.1);
    CHECK(fpgaBanks.budget.known_ms_removed_floor >
          fpgaBanks.budget.copy_ms_removed); // + FEED scale

    // 480p content on 720p canvas: large pad evacuation if ARM had been
    // forced to fill 720p banks (ugly path we refuse to keep on ARM).
    const auto fab480on720 = makeDdrFabricOwnedPresentPlan(
        624, 480, plex720pDdrFrameGeometry(), kPlex720pDdrFramePhysBase);
    CHECK(fab480on720.valid);
    CHECK(fab480on720.publish_bytes == 449280u);
    CHECK(fab480on720.budget.copy_ms_removed > 10.0 &&
          fab480on720.budget.copy_ms_removed < 10.4); // ~14.97-canvas class
    CHECK(fab480on720.budget.known_ms_removed_floor >
          fab480on720.budget.copy_ms_removed); // includes scale floor

    // Tier mismatch guard: 720p layout must never claim product silicon match.
    CHECK(!ddrFrameLayoutMatchesProductSilicon(t720));
    CHECK(!ddrFrameLayoutMatches720pTier(p480));

    // --- Product 720p OUTPUT path: 960x540 native → Option-C canvas (parent 5/5) ---
    CHECK(kPlex720pOutputSourceWidth == 960);
    CHECK(kPlex720pOutputSourceHeight == 540);
    CHECK(kPlex720pOutputSourceBytes == 777600u || kPlex720pOutputSourceBytes == 777600);
    CHECK(static_cast<size_t>(kPlex720pOutputSourceBytes) == yuv420pFrameBytes(960, 540));
    CHECK(kDdr720pOutputSourceWidth == 960);
    const auto out540 = makePlex720pOutputFrom540pSourcePlan();
    CHECK(out540.valid);
    CHECK(out540.publish_bytes == 777600u);
    CHECK(out540.content_w == 960 && out540.content_h == 540);
    CHECK(out540.canvas_layout.phys_base == kPlex720pDdrFramePhysBase);
    CHECK(out540.canvas_layout.coded_width == 1280 ||
          out540.native.canvas_w == 1280);
    CHECK(out540.budget.arm_still_pushes_pixels);
    CHECK(out540.budget.fabric_owned);
    CHECK(!out540.budget.zero_arm_per_pixel); // NOT the FPGA-written path
    // Projected copy @ structural rate should land near parent 8.42 ms
    CHECK(out540.budget.arm_copy_ms > 8.0 && out540.budget.arm_copy_ms < 9.0);
    // Product path budgets decode+sws (26.08), NOT decode-only (22.51).
    CHECK(kParent960x540DecodeMs == kParent960x540DecodeSwsOutMs);
    CHECK(kParent960x540DecodeSwsOutMs == 26.08);
    CHECK(kParent960x540MarginMs == 7.16);
    CHECK(ddr720pOutputProductPathAccepts(out540.budget)); // default sws figure
    CHECK(ddr720pOutputProductPathAccepts(out540.budget, kParent960x540DecodeSwsOutMs));
    // Retracted ship figure: decode-only margin must not be the accept input alone
    // without acknowledging it is optimistic — still mathematically > floor, but
    // product constants pin the sws total.
    {
        const double total = kParent960x540DecodeSwsOutMs + out540.budget.arm_copy_ms;
        const double margin = kFrameBudget24fpsMs - total;
        CHECK(total > 34.0 && total < 35.5); // ~34.50
        CHECK(margin > 7.0 && margin < 7.5); // ~7.16
        CHECK(margin >= kPlex720pOutputMinMarginMs);
        CHECK(total > 34.4 && total < 34.6);
    }
    // True 720p source with CPU copy still fails ship (zero-arm gate)
    CHECK(kParent720pSourceMarginMs < 0.0);
    CHECK(!ddr720p24ShipAcceptsZeroArmPerPixel(out540.budget));
    // TRAP: ARM downscale-from-720p rejected
    CHECK(ddr720pArmDownscalePathRejected(kParent720pArmDownscaleTo960Ms));
    CHECK(ddr720pArmDownscalePathRejected(kParent720pArmDownscaleTo624Ms));
    CHECK(!ddr720pOutputProductPathAccepts(out540.budget, kParent720pArmDownscaleTo960Ms));
    // 1024x576 decode-only margin 6.05 < 7.0 floor → reject
    {
        auto p1024 = makeDdrFabricOwnedPresentPlan(1024, 576, plex720pDdrFrameGeometry(),
                                                   kPlex720pDdrFramePhysBase, 0, 0, false);
        CHECK(p1024.valid);
        CHECK(!ddr720pOutputProductPathAccepts(p1024.budget, kParent1024x576DecodeMs));
    }

    // --- Option-C capacity = usable (stride-4KiB), NOT full stride, NOT w>=1280 ---
    {
        CHECK(kPlex480pYuv420pBankStride == 0x80000u);
        CHECK(kPlex480pYuv420pBankUsableBytes == 520192u);
        CHECK(kDdrBankDoorbellPageBytes == 0x1000u);
        CHECK(kPlex720pOutputSourceBytes == 777600);
        CHECK(kPlex720pOutputSourceBytes > kPlex480pYuv420pBankUsableBytes);
        // Full-stride threshold would wrongly keep 720x482 on legacy (rd-duck #1).
        constexpr size_t kEdge = 720u * 482u * 3u / 2u; // 520560
        CHECK(kEdge == kDdrLegacyUsableEdgeBytes);
        CHECK(kEdge > kPlex480pYuv420pBankUsableBytes);
        CHECK(kEdge < kPlex480pYuv420pBankStride);
        CHECK(!ddrI420PayloadNeedsOptionCBank(449280u)); // 624x480 — fits usable
        CHECK(!ddrI420PayloadNeedsOptionCBank(520191u)); // usable-1 → legacy OK
        CHECK(!ddrI420PayloadNeedsOptionCBank(520192u)); // exact usable → legacy OK
        CHECK(ddrI420PayloadNeedsOptionCBank(520193u));  // usable+1 → Option-C
        CHECK(ddrI420PayloadNeedsOptionCBank(kEdge));    // 720x482
        CHECK(ddrI420PayloadNeedsOptionCBank(777600u));  // 960x540 display
        CHECK(ddrI420PayloadNeedsOptionCBank(783360u));  // 960x544 MB-coded (future DPB)
        CHECK(ddrI420PayloadNeedsOptionCBank(1382400u)); // 1280x720
        // Host/RTL oracle parity (exact bytes, not qword floor).
        CHECK(!plxgPayloadNeedsOptionC(520191u));
        CHECK(!plxgPayloadNeedsOptionC(520192u));
        CHECK(plxgPayloadNeedsOptionC(520193u));
        CHECK(plxgPayloadNeedsOptionC(520560u));
        CHECK(plxgI420PayloadBytes(960, 480, 540) == 777600u);
        CHECK(plxgI420PayloadBytes(720, 360, 482) == 520560u);
        CHECK(plxgGeomDimsOk(960, 540, 960, 480));
        CHECK(!plxgGeomDimsOk(961, 540, 961, 480)); // odd width
        CHECK(!plxgGeomDimsOk(960, 541, 960, 480)); // odd height
        CHECK(ddrSelectBankMapForContent(624, 480) == DdrBankMap::Legacy480p);
        CHECK(ddrSelectBankMapForContent(320, 240) == DdrBankMap::Legacy480p);
        CHECK(ddrSelectBankMapForContent(720, 482) == DdrBankMap::OptionC720p);
        CHECK(ddrSelectBankMapForContent(960, 540) == DdrBankMap::OptionC720p);
        CHECK(ddrSelectBankMapForContent(1280, 720) == DdrBankMap::OptionC720p);
        CHECK(960 < 1280);
        CHECK(ddrSelectBankMapForI420(960, 480, 540) == DdrBankMap::OptionC720p);
        // Fits-bank uses usable, not full stride (bank1 vs doorbell).
        DdrNativeContentLayout edgeCl = makeDdrNativeContentLayout(720, 482);
        CHECK(edgeCl.valid && edgeCl.frame_bytes == kEdge);
        CHECK(!ddrNativeContentFitsBank(edgeCl, kPlex480pYuv420pBankStride));
        CHECK(ddrNativeContentFitsBank(edgeCl, kPlex720pYuv420pBankStride));
        // bank1End <= doorbell for legacy product layout (449280).
        const auto leg = makeDdrFrameLayout(plex480pDdrFrameGeometry());
        CHECK(ddrFrameLayoutValid(leg));
        const uint32_t bank1 = leg.phys_base + leg.bank_stride;
        CHECK(bank1 + static_cast<uint32_t>(leg.frame_bytes) <= leg.doorbell_phys);
        // Hypothetical legacy layout with edge payload would overlap doorbell.
        {
            DdrFrameLayout bad = leg;
            bad.frame_bytes = kEdge;
            bad.width = 720;
            bad.height = 482;
            bad.coded_width = CodedWidth{720};
            bad.coded_height = CodedHeight{482};
            bad.display_width = DisplayWidth{720};
            bad.display_height = DisplayHeight{482};
            bad.crop_left = bad.crop_right = bad.crop_top = bad.crop_bottom = 0;
            bad.presented_width = PresentedWidth{720};
            bad.presented_height = PresentedHeight{482};
            bad.present_x = bad.present_y = 0;
            CHECK(!ddrFrameLayoutValid(bad)); // bank1 overlaps doorbell
        }
        // w-path owns ddrFrameGeometryForFpgaPresent (parent ruling): STORAGE allowlist.
        // 960×540 → identity (not 624 downscale, not 1280 canvas). 320→624 shear-safe.
        const auto g540 = ddrFrameGeometryForFpgaPresent(960, 540);
        CHECK(g540.coded_width.get() == 960);
        CHECK(g540.coded_height.get() == 540);
        CHECK(g540.coded_width.get() != 624);
        CHECK(g540.coded_width.get() != 1280);
        const auto g240 = ddrFrameGeometryForFpgaPresent(320, 240);
        CHECK(g240.coded_width.get() == 624);
        CHECK(g240.coded_height.get() == 480);
        const auto g720 = ddrFrameGeometryForFpgaPresent(1280, 720);
        CHECK(g720.coded_width.get() == 1280 && g720.coded_height.get() == 720);
        // Storage helper same contract; never identity-320.
        CHECK(ddrStorageGeometryForContent(320, 240).coded_width.get() == 624);
        CHECK(ddrStorageGeometryForContent(960, 540).coded_width.get() == 960);
        // Storage vs canvas split (rd-duck #3).
        const auto stor = ddrStorageGeometryForContent(960, 540);
        CHECK(stor.coded_width.get() == 960 && stor.coded_height.get() == 540);
        const auto canv = ddrCanvasGeometryForBankMap(DdrBankMap::OptionC720p);
        CHECK(canv.coded_width.get() == 1280 && canv.coded_height.get() == 720);
        CHECK(stor.coded_width.get() != canv.coded_width.get());
        // Coded vs display: native_push uses DISPLAY 777600, not MB-coded 783360.
        CHECK(kPlex720pOutputSourceDisplayHeight == 540);
        CHECK(kPlex720pOutputSourceCodedHeight == 544);
        CHECK((kPlex720pOutputSourceDisplayHeight & 15) == 12);
        CHECK((kPlex720pOutputSourceCodedHeight & 15) == 0);
        CHECK(kPlex720pOutputSourceDisplayBytes == 777600);
        CHECK(kPlex720pOutputSourceCodedBytes == 783360);
        CHECK(kPlex720pOutputSourceBytes == kPlex720pOutputSourceDisplayBytes);
        CHECK(kPlex720pOutputSourceBytes != kPlex720pOutputSourceCodedBytes);
        CHECK(static_cast<size_t>(kPlex720pOutputSourceCodedBytes) ==
              yuv420pFrameBytes(960, 544));
        CHECK(static_cast<size_t>(kPlex720pOutputSourceDisplayBytes) ==
              yuv420pFrameBytes(960, 540));
        CHECK(!ddrFrameStoreAccepts720pTier(960, 540));
        CHECK(ddrFrameStoreAccepts720pTier(960, 544));
        CHECK(ddrFrameStoreAcceptsOptionCContent(960, 540));
        CHECK(!ddrFrameStoreAcceptsResolution(960, 540));
        const auto out = makePlex720pOutputFrom540pSourcePlan();
        CHECK(out.valid);
        CHECK(out.publish_bytes == 777600u);
        CHECK(out.publish_bytes != 783360u);
        CHECK(out.content_layout.frame_bytes == 777600u);
        CHECK(out.content_layout.u_offset == 518400u);
        CHECK(out.content_layout.v_offset == 648000u);
        // Atomic 5-qword PLXG → latch: STORAGE 960x540, DE 1280x720, Option-C.
        PlxgLatchModel latch{};
        std::vector<uint8_t> ctrl(0x1000, 0);
        PlxgRecord rec{};
        rec.valid = true;
        rec.seq = out.plxg_seq;
        for (int i = 0; i < 5; ++i)
            rec.q[i] = out.plxg_q[i];
        CHECK(plxgProgramRecord(ctrl.data(), rec, latch));
        CHECK(latch.geom_enable);
        CHECK(latch.coded_w == 960 && latch.coded_h == 540);
        CHECK(latch.y_stride == 960 && latch.chroma_stride == 480);
        CHECK(latch.h_de == 1280 && latch.v_de == 720);
        CHECK(plxgPayloadNeedsOptionC(plxgI420PayloadBytes(latch.y_stride, latch.chroma_stride,
                                                           latch.coded_h)));
        // NEG: three temporal same-slot beats are not our wire format.
        CHECK(out.plxg_q[0] != out.plxg_q[1]);
        CHECK(out.plxg_q[1] != out.plxg_q[2]);
        CHECK(out.canvas_layout.phys_base == kPlex720pDdrFramePhysBase);
        CHECK(out.canvas_layout.bank_stride == kPlex720pYuv420pBankStride);
        CHECK(out.canvas_layout.doorbell_phys == kPlex720pYuv420pDoorbellPhys);
        CHECK(ddrSelectBankMapForContent(out.content_w, out.content_h) ==
              DdrBankMap::OptionC720p);
    }

    // --- Airtight 960x540 content layout (native_push strides ≠ canvas) ---
    {
        const auto cl = plex960x540NativeContentLayout();
        CHECK(cl.valid);
        CHECK(cl.width == 960 && cl.height == 540);
        CHECK(cl.y_stride == kPlex720pOutputYStrideBytes);
        CHECK(cl.chroma_stride == kPlex720pOutputChromaStrideBytes);
        CHECK(cl.y_stride == 960);
        CHECK(cl.chroma_stride == 480);
        CHECK(cl.y_offset == 0u);
        CHECK(cl.u_offset == 518400u);
        CHECK(cl.v_offset == 648000u);
        CHECK(cl.u_offset == static_cast<uint32_t>(kPlex720pOutputUPlaneOffset));
        CHECK(cl.v_offset == static_cast<uint32_t>(kPlex720pOutputVPlaneOffset));
        CHECK(cl.frame_bytes == 777600u);
        CHECK(cl.y_line_qwords == 120);
        CHECK(cl.chroma_line_qwords == 60);
        CHECK(ddrNativeContentFitsBank(cl, kPlex720pYuv420pBankStride));
        // Shear class: content y_stride must NOT equal canvas line_bytes 1280.
        CHECK(cl.y_stride != kPlex720pYStrideBytes);
        CHECK(cl.y_stride != out540.canvas_layout.line_bytes);
        CHECK(out540.content_layout.valid);
        CHECK(out540.content_layout.y_stride == 960);
        CHECK(out540.content_layout.frame_bytes == out540.publish_bytes);
        CHECK(out540.publish_bytes != out540.canvas_layout.frame_bytes);
        // Fabric-owned publish plan accepts tight 777600, refuses canvas length.
        std::vector<uint8_t> tight(777600u, 0x10);
        DdrFabricOwnedPublishPlan pub{};
        std::string err;
        CHECK(makeDdrFabricOwnedPublishPlan(tight.data(), 0, out540, pub, &err));
        CHECK(pub.payload_bytes == 777600u);
        CHECK(pub.publish.bank_offset == 0u);
        // NEG: full canvas payload on fabric-owned path when content smaller.
        DdrFabricOwnedPresentPlan bad = out540;
        bad.publish_bytes = out540.canvas_layout.frame_bytes; // 1382400 shear/pad path
        CHECK(!makeDdrFabricOwnedPublishPlan(tight.data(), 0, bad, pub, &err));
        // PLXG atomic record: storage 960x540 + origin via Q1 (not 3 temporal beats).
        {
            PlxgLatchModel lm{};
            std::vector<uint8_t> page(0x1000, 0);
            PlxgRecord r{};
            r.valid = true;
            r.seq = out540.plxg_seq ? out540.plxg_seq : 1;
            for (int i = 0; i < 5; ++i)
                r.q[i] = out540.plxg_q[i];
            CHECK(plxgProgramRecord(page.data(), r, lm));
            CHECK(lm.geom_enable && lm.coded_w == 960 && lm.coded_h == 540);
            CHECK(lm.content_x0 == 0 && lm.content_y0 == 0);
            CHECK(lm.y_stride == 960 && lm.chroma_stride == 480);
            CHECK(lm.h_de == 1280 && lm.v_de == 720);
            // Record lives at +0x2C0 on control page image.
            uint64_t q0le = 0;
            std::memcpy(&q0le, page.data() + mailbox_abi::kPlxgOffset, 8);
            CHECK(static_cast<uint32_t>(q0le) == mailbox_abi::kPlxgMagic);
        }
        auto inset = makeDdrFabricOwnedPresentPlan(960, 540, plex720pDdrFrameGeometry(),
                                                   kPlex720pDdrFramePhysBase, 32, 16, false);
        CHECK(inset.valid);
        CHECK(inset.content_x0 == 32 && inset.content_y0 == 16);
        {
            PlxgLatchModel lm{};
            std::vector<uint8_t> page(0x1000, 0);
            PlxgRecord r{};
            r.valid = true;
            r.seq = inset.plxg_seq ? inset.plxg_seq : 1;
            for (int i = 0; i < 5; ++i)
                r.q[i] = inset.plxg_q[i];
            CHECK(plxgProgramRecord(page.data(), r, lm));
            CHECK(lm.content_x0 == 32 && lm.content_y0 == 16);
        }
        // Odd dims rejected (4:2:0).
        CHECK(!makeDdrNativeContentLayout(961, 540).valid);
        CHECK(!makeDdrNativeContentLayout(960, 541).valid);
    }
    std::fprintf(stderr,
                 "  720p_OUTPUT 960x540 publish=%zu y_stride=%d u=%u v=%u copy_ms=%.3f "
                 "arm=%.2f(sws) margin~%.2f ACCEPT\n",
                 out540.publish_bytes, out540.content_layout.y_stride,
                 out540.content_layout.u_offset, out540.content_layout.v_offset,
                 out540.budget.arm_copy_ms, kParent960x540DecodeSwsOutMs,
                 kFrameBudget24fpsMs - (kParent960x540DecodeSwsOutMs + out540.budget.arm_copy_ms));

    // ---- E2E native publish readback (parent fit gate) ----
    // Proves one 777600 B frame lands on Option-C with storage strides/U/V —
    // the detector that would have caught an unwired 1280 canvas path.
    {
        std::string err;
        CHECK(ddrNativeOptionCPublishReadbackOk(&err));
        if (!err.empty())
            std::fprintf(stderr, "  native_e2e err=%s\n", err.c_str());
        // FFmpeg geometry must be STORAGE for 960x540, never DE canvas / never 624.
        const auto ff = ddrFfmpegGeometryForPresent(960, 540, /*wantFpga=*/true);
        CHECK(ff.coded_width.get() == 960);
        CHECK(ff.coded_height.get() == 540);
        CHECK(ff.coded_width.get() != 1280);
        CHECK(ff.coded_height.get() != 720);
        CHECK(ff.coded_width.get() != 624);
        // Other tiers still pin product 624 canvas (shear-safe).
        const auto ff480 = ddrFfmpegGeometryForPresent(320, 240, true);
        CHECK(ff480.coded_width.get() == kPlex480pCodedWidth.get());
        CHECK(ff480.coded_height.get() == kPlex480pCodedHeight.get());
        // FpgaPresent lockstep with FFmpeg for 960 (w-path ownership; no silent 624).
        const auto fpga540 = ddrFrameGeometryForFpgaPresent(960, 540);
        CHECK(fpga540.coded_width.get() == ff.coded_width.get());
        CHECK(fpga540.coded_height.get() == ff.coded_height.get());
        // B3 red-twin: PLXG coded must yield U@518400, not canvas U@921600.
        CHECK(ddrI420UPlaneOffset(960, 540) == 518400u);
        CHECK(ddrI420UPlaneOffset(1280, 720) == 921600u);
        CHECK(ddrPlxgStorageNotCanvasUBase(960, 540, 518400u));
        CHECK(!ddrPlxgStorageNotCanvasUBase(960, 540, 921600u)); // canvas U = FAIL
        CHECK(ddrPlxgCanvasDimsFault(1280, 720));
        CHECK(!ddrPlxgCanvasDimsFault(960, 540));
        {
            PlxgLatchModel lm{};
            std::vector<uint8_t> page(0x1000, 0);
            PlxgRecord good = makePlxgRecord960x540Native(1);
            CHECK(plxgProgramRecord(page.data(), good, lm));
            const uint32_t uGood = ddrI420UPlaneOffset(lm.coded_w, lm.coded_h);
            CHECK(uGood == 518400u);
            CHECK(ddrPlxgStorageNotCanvasUBase(lm.coded_w, lm.coded_h, uGood));
            // Fault: program canvas dims into coded fields → wrong U base.
            PlxgRecord bad = good;
            bad.seq = 2;
            bad.q[0] = packPlxgQ0(true, true, 2);
            bad.q[2] = packPlxgQ2(/*h_de*/ 1280, /*v_de*/ 720, /*coded*/ 1280, /*ch*/ 720);
            bad.q[3] = packPlxgQ3(/*y*/ 1280, /*c*/ 640, /*dw*/ 1280, /*dh*/ 720);
            PlxgLatchModel lmBad{};
            CHECK(plxgProgramRecord(page.data(), bad, lmBad));
            CHECK(ddrPlxgCanvasDimsFault(lmBad.coded_w, lmBad.coded_h));
            CHECK(ddrI420UPlaneOffset(lmBad.coded_w, lmBad.coded_h) == 921600u);
            CHECK(!ddrPlxgStorageNotCanvasUBase(960, 540,
                                                ddrI420UPlaneOffset(lmBad.coded_w, lmBad.coded_h)));
        }
        // Fabric-owned publish plan exposes copy_bytes=777600 + PLXG program.
        DdrFabricOwnedPublishPlan pub{};
        std::vector<uint8_t> payload(777600u, 0x55);
        CHECK(makeDdrFabricOwnedPublishPlan(payload.data(), 0, out540, pub, &err));
        CHECK(pub.publish.copy_bytes == 777600u);
        CHECK(pub.publish.native_push);
        CHECK(pub.publish.program_plxg);
        CHECK(ddrPublishCopyBytes(pub.publish) == 777600u);
        CHECK(pub.publish.copy_bytes != pub.publish.layout.frame_bytes); // canvas >
        CHECK(pub.publish.layout.phys_base == kPlex720pDdrFramePhysBase);
        std::fprintf(stderr,
                     "  NATIVE_E2E publish_bytes=%zu copy=%zu canvas_fb=%zu "
                     "y_stride=%d u=%u v=%u map=0x%x OK\n",
                     out540.publish_bytes, pub.publish.copy_bytes,
                     pub.publish.layout.frame_bytes, out540.content_layout.y_stride,
                     out540.content_layout.u_offset, out540.content_layout.v_offset,
                     static_cast<unsigned>(pub.publish.layout.phys_base));
    }

    // ---- rd-duck: q1..q4 then q0, tear reject, native→legacy disable, subarb ----
    {
        CHECK(kPlxgPublishOrder[0] == 1 && kPlxgPublishOrder[4] == 0);
        PlxgRecord en = makePlxgRecord960x540Native(1);
        PlxgRecord dis = makePlxgRecordDisable(2);
        CHECK(((en.q[0] >> 33) & 1ull) == 1ull);  // geom_enable
        CHECK(((dis.q[0] >> 33) & 1ull) == 0ull); // disabled
        // Tear: first q0 snap vs mismatched re-read → reject.
        uint64_t snap[5] = {en.q[0], en.q[1], en.q[2], en.q[3], en.q[4]};
        CHECK(plxgPollerAcceptsSnapshot(snap, en.q[0], /*lastSeq=*/0));
        CHECK(!plxgPollerAcceptsSnapshot(snap, en.q[0] ^ 0x10000ull, 0)); // torn
        CHECK(!plxgPollerAcceptsSnapshot(snap, en.q[0], /*lastSeq=*/1));  // stale
        // Atomic store order into page then latch: enable then disable.
        {
            PlxgLatchModel lm{};
            std::vector<uint8_t> page(0x1000, 0);
            CHECK(plxgProgramRecord(page.data(), en, lm));
            CHECK(lm.geom_enable && lm.coded_w == 960);
            PlxgRecord dis2 = makePlxgRecordDisable(2);
            CHECK(plxgProgramRecord(page.data(), dis2, lm));
            CHECK(!lm.geom_enable); // mode exit clears sticky Option-C
        }
        // Legacy full-canvas publish MUST program PLXG disable (not leave sticky).
        {
            std::vector<uint8_t> payload(449280u, 0);
            DdrPublishFrame fr{payload.data(), payload.size(), plex480pDdrFrameGeometry(),
                               DdrFrameFormat::Yuv420p};
            DdrPublishPlan plan{};
            std::string err;
            CHECK(makeDdrPublishPlan(fr, 0, plan, &err));
            CHECK(plan.program_plxg);
            CHECK(!plan.native_push);
            CHECK(((plan.plxg_q[0] >> 33) & 1ull) == 0ull);
        }
        // Raw geom: over-max rejected (no silent clamp-accept).
        CHECK(plxgRawGeomOk(960, 540, 960, 480));
        CHECK(!plxgRawGeomOk(1920, 1080, 1920, 960)); // > MAX 1280x720
        CHECK(!plxgRawGeomOk(0, 540, 960, 480));
        // Subarb: PLXG owner held through RD response even if stream wants mid-beat.
        {
            DdrM1SubarbModel m{};
            m.tick(/*s*/ false, /*p*/ true, /*issue_rd*/ false, /*dr*/ false);
            CHECK(m.grant == DdrM1Owner::Plxg);
            m.tick(false, true, /*issue_rd*/ true, false);
            CHECK(m.outstanding);
            // Stream rises while outstanding — grant must stay PLXG.
            m.tick(/*s*/ true, true, false, false);
            CHECK(m.grant == DdrM1Owner::Plxg);
            CHECK(!m.doutToStream(true));
            CHECK(m.doutToPlxg(true));
            m.tick(true, true, false, /*dout_ready*/ true);
            CHECK(!m.outstanding);
            // While PLXG still wants, owner holds (no mid-session steal).
            m.tick(true, true, false, false);
            CHECK(m.grant == DdrM1Owner::Plxg);
            // After PLXG drops want, stream preferred on next pick.
            m.tick(true, /*p*/ false, false, false);
            CHECK(m.grant == DdrM1Owner::Stream);
        }
        // WE must NOT stick outstanding (bitstream reset telemetry class).
        {
            DdrM1SubarbModel m{};
            m.tick(/*s*/ true, /*p*/ true, false, false);
            CHECK(m.grant == DdrM1Owner::Stream);
            // 9 accepted WEs (no dout_ready) — outstanding stays clear.
            for (int i = 0; i < 9; ++i)
                m.tick(true, true, /*issue_rd*/ false, false, /*issue_we*/ true);
            CHECK(!m.outstanding);
            m.tick(/*s*/ false, true, false, false); // stream done
            CHECK(m.grant == DdrM1Owner::Plxg);
            m.tick(false, true, /*issue_rd*/ true, false);
            CHECK(m.outstanding);
            m.tick(false, true, false, /*dout_ready*/ true);
            CHECK(!m.outstanding);
        }
        // Multi-beat RD: first dout_ready does not clear outstanding.
        {
            DdrM1SubarbModel m{};
            m.tick(true, false, false, false);
            m.tick(true, false, /*issue_rd*/ true, false, false, /*rd_beats*/ 3);
            CHECK(m.outstanding && m.rsp_left == 3);
            m.tick(true, false, false, true);
            CHECK(m.outstanding && m.rsp_left == 2);
            m.tick(true, false, false, true);
            CHECK(m.outstanding && m.rsp_left == 1);
            m.tick(true, false, false, true);
            CHECK(!m.outstanding);
        }
        // Publish order constant is body-then-q0 (not q0-first).
        CHECK(kPlxgPublishOrder[0] != 0);
        std::fprintf(stderr, "  PLXG_TEAR_SUBARB_DISABLE OK\n");
    }

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
                native320.save_ratio, msNative320, msCanvas480, kMappedMibps);
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
                "SHIP_OK=%d residual_4000k=%.3f residual_candidate_2600k=%.3f\n",
                fpgaBanks.publish_bytes, fpgaBanks.budget.known_ms_removed_floor,
                ddr720p24ShipAcceptsZeroArmPerPixel(fpgaBanks.budget) ? 1 : 0,
                ddr720p24ResidualMsAfterDecodeOnly(),
                ddr720p24ResidualMsAfterDecodeOnly(kParent720pDecodeMsCandidateTier));
    std::printf("  residual_1500k_decode_only=%.3f (not a PMS 1280x720 tier)\n",
                ddr720p24ResidualMsAfterDecodeOnly(kParent720pDecodeMs1500k));
    std::printf("  tier_candidate_maxBR_kbit=%d content_kbit=%d copy_ms720_mapped=%.3f "
                "copy_ms720_archive=%.3f\n",
                kPlex720pCandidateBitrateKbit, kPlex720pCandidateContentBitrateKbit,
                ms720, ms720archive);
    std::printf("  serial_fits 1500k=%d 2600k=%d 3500k=%d 4000k=%d hostcopy_reachable=%d "
                "overlap2600_sketch=%d exceeds_candidate=%d\n",
                ddr720p24MappedPathFitsAt1500k() ? 1 : 0,
                ddr720p24SerialPathFitsAt2600k() ? 1 : 0,
                ddr720p24SerialPathFitsAt3500k() ? 1 : 0,
                ddr720p24SerialPathFitsAt4000k() ? 1 : 0,
                ddr720p24HostCopyIsReachableBankRate() ? 1 : 0,
                ddr720p24OverlapSketchFitsAt2600k() ? 1 : 0,
                ddr720p24ArmCopyExceedsCandidateTierMargin(1382400u) ? 1 : 0);
    return 0;
}
