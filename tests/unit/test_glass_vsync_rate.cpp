// Pure modular12 glass Δ-rate math (no device). Soft-skip ≠ PASS.
// COMPILE FAIL is RED. Exit 0 only when all asserts hold.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/glass_vsync_rate.hpp"
#include "libmisterplex/input_mailbox.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>

static int fails = 0;
#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                   \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

int main() {
    using namespace misterplex;

    // --- ABI pins ---
    CHECK(kGlassVsyncModBits == 12u);
    CHECK(kGlassVsyncModulus == 4096u);
    CHECK(kGlassVsyncMask == 0x0FFFu);
    CHECK(mailbox_abi::kPlxdGlassVsyncBit == 4u);
    CHECK(mailbox_abi::kPlxdGlassVsyncWidth == 12u);
    CHECK(mailbox_abi::kPlxdOffset == 0x128u);

    // Product PLXD phys from layout SoT (no inventing address).
    {
        const uint32_t db = kPlex720pYuv420pDoorbellPhys;
        const uint32_t plxd = bankReleaseMailboxPhys(db);
        CHECK(db == 0x302FF000u);
        CHECK(plxd == 0x302FF128u);
        CHECK(plxd == db + mailbox_abi::kPlxdOffset);
    }

    // Ideal glass Hz pin: 30e6/(1650*750) = 24.2424...
    {
        const double ideal = 30000000.0 / (1650.0 * 750.0);
        CHECK(std::fabs(kIdealGlassHzClkPix30 - ideal) < 1e-12);
        CHECK(kIdealGlassHzClkPix30 > 24.24 && kIdealGlassHzClkPix30 < 24.25);
        // NEGATIVE: must not equal grabber-ish 31.25
        CHECK(std::fabs(kIdealGlassHzClkPix30 - 31.25) > 1.0);
    }

    // --- modular12Delta positive ---
    CHECK(modular12Delta(0, 0) == 0);
    CHECK(modular12Delta(10, 10) == 0);
    CHECK(modular12Delta(0, 1) == 1);
    CHECK(modular12Delta(100, 148) == 48);
    // wrap: 4090 → 5 = 11
    CHECK(modular12Delta(4090, 5) == 11);
    CHECK(modular12Delta(0x0FFF, 0) == 1);
    CHECK(modular12Delta(0x0FFE, 0x0001) == 3);
    // full almost-wrap
    CHECK(modular12Delta(0, 0x0FFF) == 0x0FFF);
    // inputs above 12 bits must still mask via subtraction & 0xFFF
    CHECK(modular12Delta(0x1ABC, 0x1ABD) == 1); // low12 equal except +1

    // --- glassVsyncFromPlxdHi ---
    CHECK(glassVsyncFromPlxdHi(0x00070005u) == 0);
    CHECK(glassVsyncFromPlxdHi(0x12340AB8u) == 0x0AB);
    CHECK(glassVsyncFromPlxdHi(0xFFFFFFF2u) == 0xFFF);
    // agrees with decodeBankReleaseWord glass field
    {
        BankReleaseStatus br{};
        const uint64_t word =
            (static_cast<uint64_t>(0x12340AB8u) << 32) | kBankReleaseMailboxMagic;
        CHECK(decodeBankReleaseWord(word, br));
        CHECK(br.glass_vsync_count == 0x0AB);
        CHECK(br.frames_done == 0x1234);
        CHECK(glassVsyncFromPlxdHi(0x12340AB8u) == br.glass_vsync_count);
    }

    // --- glassRateFromPair ---
    // Known rate: delta=48 over 2.0 s → 24.0 Hz
    {
        const auto r = glassRateFromPair(100, 148, 2.0, 2.0);
        CHECK(r.ok);
        CHECK(r.delta == 48);
        CHECK(std::fabs(r.rate_hz - 24.0) < 1e-12);
        CHECK(r.verdict && r.verdict[0] == 'M'); // MEASURED
    }
    // Wrap path rate: 4090→5 delta=11 over 2.0 s → 5.5 Hz
    {
        const auto r = glassRateFromPair(4090, 5, 2.0, 2.0);
        CHECK(r.ok);
        CHECK(r.delta == 11);
        CHECK(std::fabs(r.rate_hz - 5.5) < 1e-12);
    }
    // Ideal-ish: ~48.48 counts in 2.0 s ≈ 24.24 Hz (integer delta)
    {
        // 24.2424... * 2 = 48.4848 → use delta=48 → 24.0 (instrument uses int counts)
        const auto r = glassRateFromPair(0, 48, 2.0);
        CHECK(r.ok);
        CHECK(r.delta == 48);
        CHECK(std::fabs(r.rate_hz - 24.0) < 1e-12);
    }
    // STALE_OR_ZERO over ≥2 s (live 75065b0c class)
    {
        const auto r = glassRateFromPair(0, 0, 2.5, 2.0);
        CHECK(!r.ok);
        CHECK(r.delta == 0);
        CHECK(r.rate_hz == 0.0);
        CHECK(r.verdict && r.verdict[0] == 'S'); // STALE_OR_ZERO
    }
    // UNSCORED short window (even if delta non-zero) — soft ≠ PASS
    {
        const auto r = glassRateFromPair(0, 50, 1.0, 2.0);
        CHECK(!r.ok);
        CHECK(r.delta == 50);
        CHECK(r.verdict && r.verdict[0] == 'U'); // UNSCORED
    }
    // BAD_DT
    {
        const auto r = glassRateFromPair(0, 10, 0.0, 2.0);
        CHECK(!r.ok);
        CHECK(r.verdict && r.verdict[0] == 'B'); // BAD_DT
    }
    {
        const auto r = glassRateFromPair(0, 10, -1.0, 2.0);
        CHECK(!r.ok);
        CHECK(r.verdict && r.verdict[0] == 'B');
    }

    // NEGATIVE: uint16 modular subtraction without 12-bit mask is WRONG for wrap
    // (if c0=4090, c1=5 as uint16: 5-4090 underflows to large; we must use &0xFFF).
    {
        const uint16_t naive =
            static_cast<uint16_t>(static_cast<uint16_t>(5) - static_cast<uint16_t>(4090));
        // naive is 5-4090 mod 65536 = 61451, not 11
        CHECK(naive != 11);
        CHECK(modular12Delta(4090, 5) == 11);
        CHECK(modular12Delta(4090, 5) != naive);
    }

    if (fails) {
        std::fprintf(stderr, "test_glass_vsync_rate: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_glass_vsync_rate: OK\n");
    std::printf("  modular12_mask=0x%03X modulus=%u\n", kGlassVsyncMask, kGlassVsyncModulus);
    std::printf("  product_plxd=0x%08X (doorbell+0x128)\n",
                bankReleaseMailboxPhys(kPlex720pYuv420pDoorbellPhys));
    std::printf("  ideal_glass_hz_clk_pix30=%.10f (tag=derived; not RATE_PASS)\n",
                kIdealGlassHzClkPix30);
    std::printf("  live_75065b0c_pred=STALE_OR_ZERO until bank_vsync pack RBF\n");
    return 0;
}
