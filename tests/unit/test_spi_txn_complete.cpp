// SPI multi-word transaction completeness — Sweep 115 defect class.
//
// Defect: kickDdrSpi / writeStatusWordRaw could fail mid-spiWord sequence and
// still report success (or leave a partial status kick). Idle paint then left
// DDR scanning stub/garbage while make unit stayed green.
//
// RED against f315ffb3-class policy:
//   - short wall ACK (kSpiAckUseWallTimeout / 2 ms) is forbidden
//   - a commit that ignores phase failure must fail this test
// GREEN: spiTxnCommitAll stops on first failure; all-ok commits succeed.
//
// Also models status-write word count (cmd + 8×u16).

#include "libmisterplex/spi_ack_wait.hpp"

#include <cstdio>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

// Naive wrong commit: keeps going and returns true anyway (the defect).
template <typename IssueFn>
bool naiveAlwaysOkCommit(int words, IssueFn issue) {
    for (int i = 0; i < words; ++i)
        (void)issue(i);
    return true; // SILENT PARTIAL SUCCESS
}

int main() {
    using namespace misterplex;

    // --- Policy pins that fail f315ffb3 (2 ms wall) ---------------------------
    CHECK(kSpiAckUseWallTimeout == false);
    CHECK(kSpiAckMaxPolls >= 1000000);
    // If someone reintroduces a wall constant used as abort, it must not be
    // in the forbidden short band. We expose only the forbidden marker.
    CHECK(kSpiAckForbiddenShortWallUs > 2000);

    // Status write is cmd + 8 data words.
    CHECK(kStatusWriteSpiWords == 9);

    // --- All phases OK --------------------------------------------------------
    {
        int failed_at = -2;
        const char* err = "unset";
        std::vector<int> issued;
        const bool ok = spiTxnCommitAll(
            kStatusWriteSpiWords,
            [&](int i) -> SpiTxnPhaseResult {
                issued.push_back(i);
                return SpiTxnPhaseResult{true, nullptr};
            },
            failed_at, err);
        CHECK(ok);
        CHECK(failed_at == -1);
        CHECK(err == nullptr);
        CHECK(static_cast<int>(issued.size()) == kStatusWriteSpiWords);
    }

    // --- Phase 3 fails: must abort, not continue, not succeed -----------------
    {
        int failed_at = -2;
        const char* err = nullptr;
        std::vector<int> issued;
        const bool ok = spiTxnCommitAll(
            kStatusWriteSpiWords,
            [&](int i) -> SpiTxnPhaseResult {
                issued.push_back(i);
                if (i == 3)
                    return SpiTxnPhaseResult{false, "SPI ACK timeout (set)"};
                return SpiTxnPhaseResult{true, nullptr};
            },
            failed_at, err);
        CHECK(!ok);
        CHECK(failed_at == 3);
        CHECK(err != nullptr && std::string(err).find("SPI ACK") != std::string::npos);
        // Must not have issued phases after the failure.
        CHECK(static_cast<int>(issued.size()) == 4); // 0..3
        CHECK(issued.back() == 3);
    }

    // --- RED twin: naive always-ok would "succeed" on the same failure --------
    {
        std::vector<int> issued;
        const bool naive_ok = naiveAlwaysOkCommit(kStatusWriteSpiWords, [&](int i) {
            issued.push_back(i);
            if (i == 3)
                return SpiTxnPhaseResult{false, "SPI ACK timeout (set)"};
            return SpiTxnPhaseResult{true, nullptr};
        });
        // Document the defect: naive returns true after partial issue.
        CHECK(naive_ok == true);
        CHECK(static_cast<int>(issued.size()) == kStatusWriteSpiWords);
        // Production helper must disagree with naive on this input.
        int failed_at = -1;
        const char* err = nullptr;
        const bool prod_ok = spiTxnCommitAll(
            kStatusWriteSpiWords,
            [&](int i) -> SpiTxnPhaseResult {
                if (i == 3)
                    return SpiTxnPhaseResult{false, "SPI ACK timeout (set)"};
                return SpiTxnPhaseResult{true, nullptr};
            },
            failed_at, err);
        CHECK(prod_ok == false);
        CHECK(naive_ok != prod_ok);
    }

    // --- Zero words is vacuously OK -------------------------------------------
    {
        int failed_at = 99;
        const char* err = "x";
        CHECK(spiTxnCommitAll(0, [](int) { return SpiTxnPhaseResult{false, "nope"}; }, failed_at,
                              err));
        CHECK(failed_at == -1);
    }

    if (fails) {
        std::fprintf(stderr, "test_spi_txn_complete: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_spi_txn_complete: OK\n");
    return 0;
}
