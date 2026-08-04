// Contended-core PLXD bank select (one free ARM core).
//
// Parent 2026-08-04: MiSTer owns ~100% of one A9; product work has ONE core.
// Contended model: ARM polls are slow relative to vsync (many vsyncs/poll).
// Idle dual-core "poll every 1ms while display is frozen" is vacuous for capacity.
//
// Cases:
//   GREEN fixed contended + long PLXD lag: motion, zero display-bank overwrites
//   RED legacy under same lag: display-bank overwrites (force / stale free)
//   NEGATIVE fixed stuck swap_pending: Drop only, never Write
//   NEGATIVE fixed: no re-write of last_pub before display-ack
// Soft-skip never. true rc direct.

#include "libmisterplex/ddr_bank_release_select.hpp"
#include "libmisterplex/input_mailbox.hpp"

#include <algorithm>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

using namespace misterplex;

namespace {

constexpr int kFrames = 200;
constexpr int kVsyncPerPoll = 3; // contended ARM: several vsyncs between polls
constexpr int kPollMax = 50;
// Long mailbox lag: free_mask stays stale across many vsyncs (DDR-busy PLXD pack).
constexpr int kPlxdStaleVsyncs = 12;

struct Fpga {
    int disp = 0;
    int pending = 0;
    bool swap_pending = false;
    int vsync_count = 0;
    int bank_content[2] = {0, 0};
    std::vector<int> displayed;
    BankReleaseStatus plxd{};
    int since_refresh = 0;

    void refreshPlxd() {
        plxd.swap_pending = swap_pending;
        plxd.disp_bank = static_cast<uint8_t>(disp & 1);
        plxd.free_bank_mask =
            swap_pending ? 0 : static_cast<uint8_t>(disp ? 0x1 : 0x2);
        plxd.frames_done = static_cast<uint16_t>(vsync_count & 0xffff);
        since_refresh = 0;
    }

    void doorbell(int bank, int tag) {
        pending = bank & 1;
        bank_content[pending] = tag;
        swap_pending = true;
        // PLXD not refreshed on doorbell (matches RTL).
    }

    void vsync() {
        ++vsync_count;
        ++since_refresh;
        if (swap_pending) {
            disp = pending;
            swap_pending = false;
            displayed.push_back(bank_content[disp]);
        }
        if (since_refresh >= kPlxdStaleVsyncs)
            refreshPlxd();
    }

    void advanceContendedPoll() {
        for (int i = 0; i < kVsyncPerPoll; ++i)
            vsync();
    }
};

struct Stats {
    int presents = 0;
    int drops = 0;
    int waits = 0;
    int disp_overwrites = 0;
    int unique_late = 0;
};

void score_late(const Fpga& fpga, Stats& st) {
    const size_t n = fpga.displayed.size();
    const size_t start = n > 60 ? n - 60 : 0;
    std::vector<int> late(fpga.displayed.begin() + static_cast<long>(start),
                          fpga.displayed.end());
    std::sort(late.begin(), late.end());
    late.erase(std::unique(late.begin(), late.end()), late.end());
    st.unique_late = static_cast<int>(late.size());
}

Stats run_fixed() {
    Fpga fpga;
    fpga.refreshPlxd();
    DdrBankSelectState sel;
    Stats st;
    for (int f = 1; f <= kFrames; ++f) {
        for (int poll = 0; poll <= kPollMax; ++poll) {
            auto r = selectDdrWriteBank(fpga.plxd, sel, kPollMax);
            if (r.action == DdrBankSelectAction::Wait) {
                ++st.waits;
                fpga.advanceContendedPoll();
                continue;
            }
            if (r.action == DdrBankSelectAction::Drop) {
                ++st.drops;
                break;
            }
            const int bank = r.bank & 1;
            if (!fpga.swap_pending && bank == fpga.disp)
                ++st.disp_overwrites;
            fpga.doorbell(bank, f);
            noteDdrBankPublished(sel, bank);
            ++st.presents;
            break;
        }
        fpga.vsync();
        fpga.vsync();
    }
    score_late(fpga, st);
    return st;
}

Stats run_legacy() {
    Fpga fpga;
    fpga.refreshPlxd();
    Stats st;
    int last_pub = 0;
    for (int f = 1; f <= kFrames; ++f) {
        for (int poll = 0; poll <= kPollMax; ++poll) {
            const bool timed_out = (poll >= kPollMax);
            auto r = selectDdrWriteBankLegacyForce(fpga.plxd, last_pub, timed_out);
            if (r.action == DdrBankSelectAction::Wait) {
                ++st.waits;
                fpga.advanceContendedPoll();
                continue;
            }
            const int bank = r.bank & 1;
            if (!fpga.swap_pending && bank == fpga.disp)
                ++st.disp_overwrites;
            fpga.doorbell(bank, f);
            last_pub = bank;
            ++st.presents;
            break;
        }
        fpga.vsync();
        fpga.vsync();
    }
    score_late(fpga, st);
    return st;
}

bool negative_stuck_swap_drop_only() {
    BankReleaseStatus brs{};
    brs.swap_pending = true;
    brs.disp_bank = 0;
    brs.free_bank_mask = 0;
    brs.frames_done = 3;
    DdrBankSelectState sel;
    noteDdrBankPublished(sel, 1);
    int writes = 0, drops = 0;
    for (int i = 0; i < 40; ++i) {
        auto r = selectDdrWriteBank(brs, sel, 8);
        if (r.action == DdrBankSelectAction::Write)
            ++writes;
        if (r.action == DdrBankSelectAction::Drop)
            ++drops;
    }
    return writes == 0 && drops > 0;
}

bool negative_no_rewrite_before_ack() {
    DdrBankSelectState sel;
    BankReleaseStatus brs{};
    brs.swap_pending = false;
    brs.disp_bank = 0;
    brs.free_bank_mask = 0x2;
    brs.frames_done = 0;
    auto r = selectDdrWriteBank(brs, sel, 5);
    if (r.action != DdrBankSelectAction::Write || (r.bank & 1) != 1)
        return false;
    noteDdrBankPublished(sel, 1);
    // Stale free still names published bank while disp has not moved.
    brs.free_bank_mask = 0x2;
    brs.disp_bank = 0;
    int bad = 0;
    for (int i = 0; i < 25; ++i) {
        auto r2 = selectDdrWriteBank(brs, sel, 10);
        if (r2.action == DdrBankSelectAction::Write)
            ++bad;
    }
    return bad == 0;
}

// Legacy on timeout force-writes disp^1 even under contention — RED control.
bool legacy_timeout_force_write() {
    BankReleaseStatus brs{};
    brs.swap_pending = false;
    brs.disp_bank = 0;
    brs.free_bank_mask = 0; // no free
    auto r = selectDdrWriteBankLegacyForce(brs, /*last*/ 0, /*timed_out*/ true);
    return r.action == DdrBankSelectAction::Write && (r.bank & 1) == 1 &&
           std::string(r.reason ? r.reason : "").find("legacy_force") != std::string::npos;
}

} // namespace

int main() {
    std::cout << "CASE ddr_bank_select_contended EXECUTED\n";
    std::cout << "PRE-REGISTER: contended vsync/poll=" << kVsyncPerPoll
              << " plxd_stale_vsyncs=" << kPlxdStaleVsyncs
              << " fixed→0 overwrite+motion; legacy→overwrites; stuck→Drop; "
                 "legacy_timeout→force\n";

    if (!legacy_timeout_force_write()) {
        std::cerr << "FAIL control: legacy timeout must force disp^1\n";
        return 1;
    }
    std::cout << "PASS control legacy_timeout_force\n";

    const Stats leg = run_legacy();
    std::cout << "raw legacy_contended presents=" << leg.presents
              << " drops=" << leg.drops << " waits=" << leg.waits
              << " disp_overwrites=" << leg.disp_overwrites
              << " unique_late=" << leg.unique_late << "\n";
    if (leg.disp_overwrites <= 0) {
        std::cerr << "FAIL REPRO: legacy contended expected display overwrites "
                     "(stale free / force under lag)\n";
        return 1;
    }
    std::cout << "REPRO_OK legacy_contended disp_overwrites=" << leg.disp_overwrites
              << "\n";

    const Stats fix = run_fixed();
    std::cout << "raw fixed_contended presents=" << fix.presents
              << " drops=" << fix.drops << " waits=" << fix.waits
              << " disp_overwrites=" << fix.disp_overwrites
              << " unique_late=" << fix.unique_late << "\n";
    if (fix.disp_overwrites != 0) {
        std::cerr << "FAIL fixed_contended overwrites=" << fix.disp_overwrites << "\n";
        return 1;
    }
    if (fix.presents < 40) {
        std::cerr << "FAIL fixed_contended presents=" << fix.presents << "\n";
        return 1;
    }
    if (fix.unique_late < 15) {
        std::cerr << "FAIL fixed_contended unique_late=" << fix.unique_late << "\n";
        return 1;
    }
    std::cout << "PASS fixed_contended motion unique_late=" << fix.unique_late
              << " presents=" << fix.presents << " overwrites=0\n";

    if (!negative_stuck_swap_drop_only()) {
        std::cerr << "FAIL negative stuck_swap Drop-only\n";
        return 1;
    }
    std::cout << "PASS negative stuck_swap Drop-only\n";

    if (!negative_no_rewrite_before_ack()) {
        std::cerr << "FAIL negative no rewrite before display-ack\n";
        return 1;
    }
    std::cout << "PASS negative no rewrite before display-ack\n";

    std::cout << "OK ddr_bank_select_contended\n";
    return 0;
}
