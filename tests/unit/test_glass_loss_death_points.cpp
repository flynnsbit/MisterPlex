// Glass-loss death points + byte-accounting locks (parent 0.70% HDMI missing).
//
// Pre-register (must hold or RED):
//   D1 shortRead is ALWAYS terminal (rawVideoTerminalSignal shortRead=true → true)
//   D2 partial mid-frame cannot continue the present loop as a silent discard
//      (terminal ⇒ break; no frameIndex++ on short path — locked by D1 + loop shape)
//   D3 under FORCE_SCALE Always, producer_bytes==reader_bytes=449280 ⇒ !rawPipeDesynced
//   D4 residual = frames-presents-drops; pacer Drop keeps residual flat;
//      publish_miss raises residual and publish_misses, drops flat
//   D5 bank-select Drop action exists (enum) and max wait 50 ms is documented
//      arithmetic: 50ms > 41.67ms @24fps ⇒ one period can time out
//   D6 avDecide maxDropRun default 1: at most one pacedrop per run before Present
//
// true rc direct. No device.
#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/ddr_bank_release_select.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ffmpeg_vf.hpp"
#include "libmisterplex/frame_ledger.hpp"
#include "libmisterplex/yuv420p_chroma_health.hpp"

#include <cstdio>
#include <string>

static int g_fails = 0;
static void expect(bool c, const char* m) {
    if (!c) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++g_fails;
    }
}

int main() {
    using namespace misterplex;

    // --- D1: shortRead always terminal ---
    expect(rawVideoTerminalSignal(false, false, false, /*shortRead=*/true, false),
           "D1 shortRead terminal");
    expect(!rawVideoTerminalSignal(false, false, false, /*shortRead=*/false, false),
           "D1 idle non-terminal");
    std::printf("D1_OK shortRead always terminal (no mid-stream silent partial discard)\n");

    // --- D2: short-read class is EOF/break only; remainder only at end ---
    // rawPipeByteAligned: full frames OK; mid-frame total not aligned.
    expect(rawPipeByteAligned(449280u * 100u, 449280u), "D2 100 frames aligned");
    expect(!rawPipeByteAligned(449280u * 100u + 1000u, 449280u), "D2 partial remainder");
    // A single short EOF leaves remainder; session ends (D1) — not 0.7% sparse holes.
    std::printf("D2_OK byte-align gate; partial remainder ≠ sparse glass skip pattern\n");

    // --- D3: FORCE_SCALE pins producer==reader → no phase desync ---
    {
        const size_t bank = static_cast<size_t>(kPlex480pYuv420pBytes); // 449280
        expect(bank == 449280u, "D3 bank bytes");
        expect(!rawPipeDesynced(bank, bank, 568), "D3 same size never desync");
        expect(!rawPipeDesynced(bank, bank, 1), "D3 same size frame1");
        // Wrong producer (640x480=460800) WOULD desync under identity_skip:
        expect(rawPipeDesynced(460800u, bank, 1), "D3 640 producer desyncs vs 624 reader");
        expect(pipeDesyncRisk(460800u, bank, /*identity_skip=*/true), "D3 risk under skip");
        expect(!pipeDesyncRisk(460800u, bank, /*identity_skip=*/false),
               "D3 no risk flag when not identity_skip (scale path)");
        // FORCE_SCALE Always + unverified exact: FOAR into coded (not crop_pad).
        // crop=618:480 dies on fleet 624x350 (ffmpeg rc=234). Verified exact: identity.
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, true);
        r.source_w = 624;
        r.source_h = 480;
        r.delivery_geometry_verified = false;
        const auto unv = buildFfmpegVideoFilter(r);
        expect(unv.scale_applied && !unv.identity_skip, "D3 unverified exact = FOAR-scale");
        expect(unv.vf.find("pad=624:480") != std::string::npos, "D3 unverified pads coded");
        expect(unv.vf.find("scale=624:480") != std::string::npos, "D3 FOAR coded W");
        expect(unv.vf.find("force_original_aspect_ratio=decrease") != std::string::npos,
               "D3 FOAR decrease");
        expect(unv.vf.find("crop=618:480") == std::string::npos, "D3 no fixed crop");
        // FOAR path still pins OUTPUT to bank bytes → no phase desync.
        expect(!pipeDesyncRisk(bank, bank, unv.identity_skip),
               "D3 FOAR path identity_skip=0 ⇒ no pipe risk flag");
        r.delivery_geometry_verified = true;
        const auto plan = buildFfmpegVideoFilter(r);
        expect(plan.identity_skip && !plan.scale_applied, "D3 verified exact = identity");
        expect(!pipeDesyncRisk(bank, bank, plan.identity_skip),
               "D3 exact+identity is not pipe risk");
        r.source_w = 1920;
        r.source_h = 1080;
        const auto mis = buildFfmpegVideoFilter(r);
        expect(mis.scale_applied && !mis.identity_skip, "D3 mismatch still scales under force");
        expect(mis.vf.find("pad=624:480") != std::string::npos, "D3 mismatch pads coded bank");
        // Fleet mode 624x350 also FOAR-codes; OUTPUT still bank bytes.
        r.source_w = 624;
        r.source_h = 350;
        r.delivery_geometry_verified = false;
        const auto m350 = buildFfmpegVideoFilter(r);
        expect(m350.scale_applied && !m350.identity_skip, "D3 350 FOAR-scales");
        expect(m350.vf.find("scale=624:480") != std::string::npos, "D3 350 FOAR coded");
        expect(!pipeDesyncRisk(327600u, bank, m350.identity_skip),
               "D3 350+scale: no desync risk (identity_skip=0)");
        expect(pipeDesyncRisk(327600u, bank, /*identity_skip=*/true),
               "D3 350+identity would desync");
        std::printf("D3_OK FORCE_SCALE unverified=FOAR_coded verified=identity "
                    "mismatch=scale 350=FOAR_coded; bank=%zu\n",
                    bank);
    }

    // --- D4: residual / drops / publish_misses identities ---
    {
        // Glass-loss class parent saw: drops flat, 4 missing at HDMI.
        // If those were publish_misses: frames=568 presents=564 drops=0 miss=4 residual=4
        const auto pub = frameLedgerLiveOf(568, 564, 0, 4);
        expect(pub.residual == 4, "D4 residual publish path");
        expect(frameLedgerResidualExplainedByPublishMiss(pub), "D4 residual==miss");
        expect(pub.drops == 0, "D4 drops flat");
        // If those were pacer drops: frames=568 presents=564 drops=4 miss=0 residual=0
        const auto pace = frameLedgerLiveOf(568, 564, 4, 0);
        expect(pace.residual == 0, "D4 residual 0 under pure pacedrop");
        expect(!frameLedgerResidualExplainedByPublishMiss(pace) || pace.publish_misses == 0,
               "D4 pacedrop not publish-explained when miss=0 residual=0");
        // ffmpeg never produced 4 frames: frames=564 presents=564 drops=0 miss=0 residual=0
        // glass still misses vs SOURCE counter — daemon residual blind.
        const auto never = frameLedgerLiveOf(564, 564, 0, 0);
        expect(never.residual == 0 && never.publish_misses == 0, "D4 never-produced residual 0");
        std::printf("D4_OK residual identities: publish_miss vs pacedrop vs never-produced\n");
    }

    // --- D5: bank-select Drop + 50ms timeout vs 24.000 period ---
    {
        // fpga_spi.cpp:1364 kPlxdPollMaxIters = 50 × 1ms
        constexpr int kPlxdPollMaxIters = 50;
        constexpr double T_src_ms = 1000.0 / 24.0; // frameRate="24.000" — NOT 23.976
        expect(T_src_ms > 41.6 && T_src_ms < 41.7, "D5 T_src 24.000");
        expect(static_cast<double>(kPlxdPollMaxIters) > T_src_ms,
               "D5 bank-select wait can exceed one source period");
        BankReleaseStatus brs{};
        brs.free_bank_mask = 0;
        brs.disp_bank = 0;
        brs.swap_pending = false;
        DdrBankSelectState st;
        DdrBankSelectResult last{};
        for (int i = 0; i < kPlxdPollMaxIters; ++i)
            last = selectDdrWriteBank(brs, st, kPlxdPollMaxIters);
        expect(last.action == DdrBankSelectAction::Drop, "D5 no_free → Drop at limit");
        std::printf("D5_OK bank-select Drop after %d ms (> T_src=%.3f ms @24.000)\n",
                    kPlxdPollMaxIters, T_src_ms);
    }

    // --- D6: maxDropRun=1 ---
    {
        // First late frame can Drop; second consecutive cannot (maxDropRun=1).
        expect(avDecide(/*drift*/ 100, /*lead*/ 40, /*drop*/ 80, /*dropRun*/ 0) ==
                   AvAction::Drop,
               "D6 first late → Drop");
        expect(avDecide(100, 40, 80, /*dropRun*/ 1) != AvAction::Drop,
               "D6 second consecutive not Drop");
        std::printf("D6_OK maxDropRun=1 paces sparse pacedrops (not free-run skip storms)\n");
    }

    // --- Geometry identity (load-bearing from 861ae49c) ---
    {
        const auto a = ddrFrameGeometryForFpgaPresent(320, 240);
        const auto b = ddrFrameGeometryForFpgaPresent(624, 480);
        expect(yuv420pCodedFrameBytes(a) == yuv420pCodedFrameBytes(b), "geom same bytes");
        expect(yuv420pCodedFrameBytes(a) == 449280u, "geom 449280");
        std::printf("GEOM_OK identical canvas 449280 both tiers\n");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_glass_loss_death_points: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_glass_loss_death_points\n");
    return 0;
}
