// Locks RTL-derived A/V phase quanta (T_disp, sample period, a_en2, PLXD4).
// Does NOT encode retracted OLD-argv cluster sep 117.10 ms.
// COMPILE FAIL is RED. Soft-skip is not used.
//
// Durable anti-restore guard: poison the identifier as a macro BEFORE including
// the header. #if defined() cannot see C++ constexpr names (rd-review: restoring
// inline constexpr kParentClusterSepMsX100 left GUARD_TEST_RC=0). If the header
// redeclares the name, the preprocessor expands the poison and the compile fails.
// Poison must NOT expand to a valid identifier (a plain rename still compiles).
// Expand to a parenthesized string so `constexpr int64_t NAME = …` is a syntax error.
#define kParentClusterSepMsX100                                                                             \
    ("RETRACTED_OLD_ARGV_ARTIFACT_kParentClusterSepMsX100_do_not_restore")
#include "libmisterplex/av_phase_rtl_quanta.hpp"
#undef kParentClusterSepMsX100
#include "libmisterplex/input_mailbox.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"

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

    // Audio sample = 1/48000 s → cannot explain a ≥1 ms separation alone
    CHECK(kAlsaSamplePeriodCycles * kAudioSampleRateHz == kAlsaClkRateHz);
    CHECK(!audioSampleQuantumCanExplainMsX100(100)); // 1.00 ms
    CHECK(audioSampleQuantumCanExplainMsX100(2));    // 0.02 ms

    // a_en2 mute = 8192/48000 s ≈ 170.67 ms — not equal to 3×24fps content (125 ms)
    {
        CHECK(!aen2MuteEqualsSepMsX100(kHyp3Content24MsX100));
        const int64_t mute_ms_x100 = aen2MuteMsX100();
        CHECK(mute_ms_x100 == 17067 || mute_ms_x100 == 17066);
        CHECK(iabs(mute_ms_x100 - kHyp3Content24MsX100) > 4000); // >40 ms
    }

    // F2 FIFO full = 2048/48 ms ≈ 42.67 ms — not product path under MrAudio
    {
        const int64_t f2_ms_x100 = (kF2AudioFifoDepthSamples * 1000LL * 100LL) / 48000;
        CHECK(f2_ms_x100 == 4266); // 42.666... → 4266 floor
        CHECK(iabs(f2_ms_x100 - kHyp3Content24MsX100) > 5000);
    }

    // 3 content frames @ 24.000 fps = 125.00 ms (content arithmetic, not HDMI)
    CHECK(kHyp3Content24MsX100 == 12500);
    CHECK(kContentFps24 == 24);

    // 7 * T_disp pure RTL arithmetic ≈ 117.01 ms — NOT pinned to any lab sep
    CHECK(nDisplayFramesMsX100(0) == 0);
    CHECK(nDisplayFramesMsX100(1) == 1672); // 16.715600 → 1672 centi-ms rounded
    CHECK(kNtscDispFrameNs / 10000 == 1671);
    CHECK(nDisplayFramesMsX100(7) == 11701);
    CHECK(kSevenDispMsX100 == 11701);
    // Distance 125.00 − 117.01 = 7.99 ms (content vs display arithmetic only)
    CHECK(iabs(kHyp3Content24MsX100 - kSevenDispMsX100) == 799);

    // --- PLXD / PLXD4 is VIDEO frames_done, not audio -----------------------
    // Phys bases come from ddr_frame_layout (single SoT); offset from mailbox_abi.
    CHECK(mailbox_abi::kPlxdOffset == 0x128u);
    CHECK(kBankReleaseMailboxOffset == mailbox_abi::kPlxdOffset);
    {
        const uint32_t doorbell = kPlex480pYuv420pDoorbellPhys;
        const uint32_t plxd_lo = mailbox_abi::frameStoreMailboxPhys(
            doorbell, mailbox_abi::kPlxdOffset);
        const uint32_t plxd_hi = plxd_lo + 4u;
        CHECK(plxd_lo == doorbell + 0x128u);
        CHECK(plxd_hi == doorbell + 0x12Cu);
        CHECK(plxd_hi - plxd_lo == 4u);
    }

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

    {
        constexpr uint32_t hi = 0x12340008u;
        CHECK(plxd4FramesDone(hi) == 0x1234);
        CHECK(plxd4SwapPending(hi));
        CHECK(plxd4DispBank(hi) == 0);
        CHECK(plxd4FreeMask(hi) == 0);
    }

    if (fails) {
        std::fprintf(stderr, "test_av_phase_rtl_quanta: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_av_phase_rtl_quanta: OK\n");
    std::printf("  T_disp_ns=%lld (tag=derived-from-rtl-literal)\n",
                static_cast<long long>(kNtscDispFrameNs));
    std::printf("  7*T_disp_ms_x100=%lld (tag=derived-from-rtl-literal; NOT lab cluster)\n",
                static_cast<long long>(kSevenDispMsX100));
    std::printf("  3*content24_ms_x100=%lld (tag=content-arithmetic)\n",
                static_cast<long long>(kHyp3Content24MsX100));
    std::printf("  kParentClusterSepMsX100=DELETED; poison-macro guard active (redeclare in header => compile RED)\n");
    return 0;
}
