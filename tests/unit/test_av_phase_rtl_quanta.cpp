// Locks RTL-derived A/V phase quanta for the 117.10 ms session-latched defect.
// RED if someone "fixes" constants to make 3*24fps frames match 117.10, or
// claims audio sample/a_en2 mute is the two-state quantum.
//
// COMPILE FAIL is RED. Soft-skip is not used.
#include "libmisterplex/av_phase_rtl_quanta.hpp"
#include "libmisterplex/input_mailbox.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdio>
#include <cstdlib>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;
    using namespace misterplex::av_phase_rtl;

    // --- Literals match cited RTL ------------------------------------------
    CHECK(kAlsaClkRateHz == 24576000);
    CHECK(kAudioSampleRateHz == 48000);
    CHECK(kAlsaSamplePeriodCycles == 512);
    CHECK(kClkSysHz == 20000000);
    CHECK(kColorbarsHPeriod == 638);
    CHECK(kNtscScandoubleLines == 524);
    CHECK(kAudioOutAen2MuteSamples == 8192);
    CHECK(kF2AudioFifoDepthSamples == 2048);

    // T_disp ns = 638 * 524 * 50
    CHECK(kNtscDispFrameNs == 638LL * 524LL * 50LL);
    CHECK(kNtscDispFrameNs == 16715600LL);

    // Audio sample = 1/48000 s → cannot be a 117 ms two-state quantum
    CHECK(kAlsaSamplePeriodCycles * kAudioSampleRateHz == kAlsaClkRateHz);
    CHECK(!audioSampleQuantumCanExplainMsX100(kParentClusterSepMsX100));

    // a_en2 mute = 8192/48000 s = 170.666... ms — post-reset only, not 117.10
    {
        // exact: mute_ms * 48000 == 8192 * 1000
        CHECK(kAudioOutAen2MuteSamples * 1000LL == 8192LL * 1000LL);
        const int64_t mute_num = kAudioOutAen2MuteSamples * 1000LL; // ms * rate
        const int64_t sep_num = kParentClusterSepMsX100 * 480LL; // sep_ms*100 * 480 = ms*rate*100/100?
        // Compare mute vs 117.10 ms in sample counts: 117.10 ms * 48 = 5620.8 samples
        const int64_t sep_samples_x10 = (kParentClusterSepMsX100 * 48LL) / 10; // 56208/10? 
        // 117.10 * 48 = 5620.8 samples → *10 = 56208
        CHECK((kParentClusterSepMsX100 * 48LL) == 562080LL); // 11710*48
        CHECK(kAudioOutAen2MuteSamples * 100LL != 562080LL / 10); // rough
        CHECK(!aen2MuteEqualsSepMsX100(kParentClusterSepMsX100));
        // Explicit: |170.666 - 117.10| >> 1 ms
        // mute_ms_x100 rounded: 819200/48 = 17066.666 → 17067
        const int64_t mute_ms_x100 = (kAudioOutAen2MuteSamples * 1000LL * 100LL + 24000) / 48000;
        CHECK(mute_ms_x100 == 17067 || mute_ms_x100 == 17066);
        CHECK(iabs(mute_ms_x100 - kParentClusterSepMsX100) > 5000); // >50 ms
        (void)mute_num;
        (void)sep_num;
        (void)sep_samples_x10;
    }

    // F2 FIFO full = 2048/48 ms ≈ 42.67 ms — not product path; not 117.10
    {
        const int64_t f2_ms_x100 = (kF2AudioFifoDepthSamples * 1000LL * 100LL) / 48000;
        CHECK(f2_ms_x100 == 4266); // 42.666... → 4266 floor
        CHECK(iabs(f2_ms_x100 - kParentClusterSepMsX100) > 5000);
    }

    // --- HYP: 3 content frames @ 24.000 fps = 125.00 ms — REJECTED ----------
    CHECK(kHyp3Content24MsX100 == 12500);
    CHECK(hyp3Content24RejectedForParentSep());
    CHECK(iabs(kHyp3Content24MsX100 - kParentClusterSepMsX100) == 790); // 7.90 ms
    // Within-cluster spread ~10-15 ms cannot absorb 7.9 ms systematic error
    // against a 35x session-latched ratio; kill explicitly.
    CHECK(iabs(kHyp3Content24MsX100 - kParentClusterSepMsX100) > 500);

    // --- 7 * T_disp arithmetic only (mechanism NOT-FOUND) -------------------
    CHECK(nDisplayFramesMsX100(1) == 1672); // 16.715600 → 1672 centi-ms rounded?
    // 16715600 ns → ms*100 = 16715600/10000 = 1671.56 → round 1672
    CHECK(kNtscDispFrameNs / 10000 == 1671);
    CHECK(nDisplayFramesMsX100(7) == 11701); // 117.0092 ms
    CHECK(sevenDispArithCompatibleWithParentSep());
    CHECK(iabs(kSevenDispMsX100 - kParentClusterSepMsX100) == 9); // 0.09 ms

    // 0..1 display frame lag after pending_ready is the coded normal window
    CHECK(nDisplayFramesMsX100(0) == 0);
    CHECK(nDisplayFramesMsX100(1) == 1672);
    CHECK(iabs(nDisplayFramesMsX100(1) - kParentClusterSepMsX100) > 9000);

    // --- PLXD / PLXD4 is VIDEO frames_done, not audio -----------------------
    CHECK(kPlxdLoPhys == 0x300FF128u);
    CHECK(kPlxdHiPhys == 0x300FF12Cu);
    CHECK(kProductDoorbellPhys == 0x300FF000u);
    CHECK(mailbox_abi::kPlxdOffset == 0x128u);
    CHECK(kBankReleaseMailboxOffset == mailbox_abi::kPlxdOffset);
    CHECK(mailbox_abi::frameStoreMailboxPhys(kProductDoorbellPhys, mailbox_abi::kPlxdOffset) ==
          kPlxdLoPhys);
    // Product PLXD4 = doorbell + 0x12C (high half of 64-bit PLXD qword)
    CHECK(mailbox_abi::frameStoreMailboxPhys(kProductDoorbellPhys, mailbox_abi::kPlxdOffset) + 4u ==
          kPlxdHiPhys);

    // RTL pack case: frames_done=7, free=1, disp=1, swap=0 → hi=0x00070005
    {
        constexpr uint32_t hi = 0x00070005u;
        CHECK(plxd4FramesDone(hi) == 7);
        CHECK(plxd4FreeMask(hi) == 1);
        CHECK(plxd4DispBank(hi) == 1);
        CHECK(!plxd4SwapPending(hi));

        BankReleaseStatus br{};
        const uint64_t word =
            (static_cast<uint64_t>(hi) << 32) | kBankReleaseMailboxMagic;
        CHECK(decodeBankReleaseWord(word, br));
        CHECK(br.frames_done == 7);
        CHECK(br.frames_done == plxd4FramesDone(hi));
    }

    // High word alone is sufficient for frames_done (devmem 0x300FF12C)
    {
        constexpr uint32_t hi = 0x12340008u; // swap=1, disp=0, free=0, fd=0x1234
        CHECK(plxd4FramesDone(hi) == 0x1234);
        CHECK(plxd4SwapPending(hi));
        CHECK(plxd4DispBank(hi) == 0);
        CHECK(plxd4FreeMask(hi) == 0);
    }

    // No second ABI: +0x12C is NOT an audio phase mailbox — it is PLXD[63:32].
    CHECK(kPlxdHiPhys - kPlxdLoPhys == 4u);

    if (fails) {
        std::fprintf(stderr, "test_av_phase_rtl_quanta: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_av_phase_rtl_quanta: OK\n");
    std::printf("  T_disp_ns=%lld (tag=derived-from-rtl-literal)\n",
                static_cast<long long>(kNtscDispFrameNs));
    std::printf("  7*T_disp_ms_x100=%lld parent_sep_ms_x100=%lld (arith only)\n",
                static_cast<long long>(kSevenDispMsX100),
                static_cast<long long>(kParentClusterSepMsX100));
    std::printf("  hyp3_content24 REJECTED |err_ms_x100|=%lld\n",
                static_cast<long long>(iabs(kHyp3Content24MsX100 - kParentClusterSepMsX100)));
    std::printf("  audio_sample/a_en2/F2 cannot explain 117.10 (correct negatives)\n");
    return 0;
}
