// Red/green gate: playback-rate PLXD bank select under *stale free_mask*.
//
// Parent HW: same RBF c5382bee + daemon e9f79de2 — idle animates, playback
// freezes (identical HDMI md5 over ~15s) while presents keep climbing at ~24fps.
// Product RTL sustained scanout gate PASSES when doorbells only fire on
// !swap_pending. Defect class is ARM free_mask consumption under stale PLXD.
//
// Model:
//   - FPGA swaps on vsync when pending_ready (always true here).
//   - PLXD snapshot refreshes only every kStaleVsyncs vsyncs (or on heartbeat),
//     modelling DDR-busy delay of the bank mailbox write after swap.
//   - Legacy ARM: freeBank() + force(disp^1) on timeout — no display-ack.
//   - Fixed ARM: selectDdrWriteBank + drop on timeout — no force-write.
//
// Pre-register:
//   RED  legacy: presents advance, displayed content sequence freezes / collides
//        with display bank writes (free_eq_disp or same-bank overwrite count).
//   GREEN fixed: displayed content tracks publishes; zero display-bank overwrites.
// EXECUTE markers required — compile-only is rc!=0.

#include "libmisterplex/ddr_bank_release_select.hpp"
#include "libmisterplex/input_mailbox.hpp"

#include <algorithm>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

using namespace misterplex;

namespace {

constexpr int kFrames = 400;          // multi-hundred presents (playback class)
constexpr int kVsyncPerFrame = 2;     // ~24fps content on ~48–60Hz display
constexpr int kStaleVsyncs = 3;       // PLXD lag after real swap (RED enabler)
constexpr int kPollMax = 50;          // matches sendDdrFrame 50×1ms

struct FpgaModel {
    int disp = 0;
    int pending = 0;
    bool swap_pending = false;
    int real_frames_done = 0; // real swaps
    int vsync_count = 0;
    // Stale PLXD snapshot
    BankReleaseStatus plxd{};
    int since_plxd_refresh = 0;
    std::vector<int> displayed_seq; // bank content tags shown after each vsync swap

    // bank_content[b] = last published tag (frame index+1) or 0
    int bank_content[2] = {0, 0};

    void refreshPlxd() {
        plxd.swap_pending = swap_pending;
        plxd.disp_bank = static_cast<uint8_t>(disp & 1);
        if (swap_pending)
            plxd.free_bank_mask = 0;
        else
            plxd.free_bank_mask = static_cast<uint8_t>(disp ? 0x1 : 0x2);
        // LEGACY FAULT MODEL only (pre-fix pack): vsync count stuffed into
        // frames_done so PLXD looked live while swaps stuck. Product RTL packs
        // real swap counter (ddr_frame_store.sv frames_done++ on swap only).
        // This gate still uses the fault packing to exercise stale-free ARM paths.
        plxd.frames_done = static_cast<uint16_t>(vsync_count & 0xffff);
        since_plxd_refresh = 0;
    }

    void doorbell(int bank, int tag) {
        pending = bank & 1;
        bank_content[pending] = tag;
        swap_pending = true;
        // PLXD intentionally NOT refreshed on doorbell (matches RTL).
    }

    void vsync() {
        ++vsync_count;
        ++since_plxd_refresh;
        if (swap_pending) {
            disp = pending;
            swap_pending = false;
            ++real_frames_done;
            displayed_seq.push_back(bank_content[disp]);
        }
        if (since_plxd_refresh >= kStaleVsyncs)
            refreshPlxd();
    }
};

struct RunStats {
    int presents = 0;
    int drops = 0;
    int waits = 0;
    int disp_bank_overwrites = 0; // wrote bank == real disp while !swap_pending
    int free_eq_disp_writes = 0;  // wrote using free==disp from snapshot
    int unique_late_display = 0;
    int last_display_tag = 0;
    int frozen_tail = 0; // trailing identical display tags
};

RunStats run_legacy() {
    FpgaModel fpga;
    fpga.refreshPlxd();
    RunStats st;
    int last_pub = 0;
    for (int f = 1; f <= kFrames; ++f) {
        bool wrote = false;
        for (int poll = 0; poll <= kPollMax; ++poll) {
            const bool timed_out = (poll >= kPollMax);
            auto r = selectDdrWriteBankLegacyForce(fpga.plxd, last_pub, timed_out);
            if (r.action == DdrBankSelectAction::Wait) {
                ++st.waits;
                // 1ms poll ≈ advance nothing; wall time: allow a vsync every few polls
                if ((poll % 8) == 7)
                    fpga.vsync();
                continue;
            }
            // Write
            const int bank = r.bank & 1;
            if (!fpga.swap_pending && bank == fpga.disp)
                ++st.disp_bank_overwrites;
            if (fpga.plxd.anyFree() && fpga.plxd.freeBank() == static_cast<int>(fpga.plxd.disp_bank))
                ++st.free_eq_disp_writes;
            fpga.doorbell(bank, f);
            last_pub = bank;
            ++st.presents;
            wrote = true;
            break;
        }
        if (!wrote)
            ++st.drops;
        for (int v = 0; v < kVsyncPerFrame; ++v)
            fpga.vsync();
    }
    // Late display uniqueness / freeze tail
    const size_t n = fpga.displayed_seq.size();
    const size_t start = n > 100 ? n - 100 : 0;
    std::vector<int> late;
    for (size_t i = start; i < n; ++i)
        late.push_back(fpga.displayed_seq[i]);
    std::vector<int> uniq = late;
    std::sort(uniq.begin(), uniq.end());
    uniq.erase(std::unique(uniq.begin(), uniq.end()), uniq.end());
    st.unique_late_display = static_cast<int>(uniq.size());
    st.last_display_tag = n ? fpga.displayed_seq.back() : 0;
    st.frozen_tail = 0;
    if (n >= 2) {
        const int last = fpga.displayed_seq.back();
        for (size_t i = n; i-- > 0;) {
            if (fpga.displayed_seq[i] != last)
                break;
            ++st.frozen_tail;
        }
    }
    return st;
}

RunStats run_fixed() {
    FpgaModel fpga;
    fpga.refreshPlxd();
    DdrBankSelectState sel;
    RunStats st;
    for (int f = 1; f <= kFrames; ++f) {
        bool wrote = false;
        for (int poll = 0; poll <= kPollMax; ++poll) {
            auto r = selectDdrWriteBank(fpga.plxd, sel, kPollMax);
            if (r.action == DdrBankSelectAction::Wait) {
                ++st.waits;
                if ((poll % 8) == 7)
                    fpga.vsync();
                continue;
            }
            if (r.action == DdrBankSelectAction::Drop) {
                ++st.drops;
                // drop frame — do not doorbell
                wrote = false;
                break;
            }
            const int bank = r.bank & 1;
            if (!fpga.swap_pending && bank == fpga.disp)
                ++st.disp_bank_overwrites;
            if (fpga.plxd.anyFree() && fpga.plxd.freeBank() == static_cast<int>(fpga.plxd.disp_bank))
                ++st.free_eq_disp_writes;
            fpga.doorbell(bank, f);
            noteDdrBankPublished(sel, bank);
            ++st.presents;
            wrote = true;
            break;
        }
        if (!wrote && st.drops == 0) {
            // loop exited without write and without Drop path counting — treat as drop
        }
        for (int v = 0; v < kVsyncPerFrame; ++v)
            fpga.vsync();
    }
    const size_t n = fpga.displayed_seq.size();
    const size_t start = n > 100 ? n - 100 : 0;
    std::vector<int> late;
    for (size_t i = start; i < n; ++i)
        late.push_back(fpga.displayed_seq[i]);
    std::vector<int> uniq = late;
    std::sort(uniq.begin(), uniq.end());
    uniq.erase(std::unique(uniq.begin(), uniq.end()), uniq.end());
    st.unique_late_display = static_cast<int>(uniq.size());
    st.last_display_tag = n ? fpga.displayed_seq.back() : 0;
    st.frozen_tail = 0;
    if (n >= 2) {
        const int last = fpga.displayed_seq.back();
        for (size_t i = n; i-- > 0;) {
            if (fpga.displayed_seq[i] != last)
                break;
            ++st.frozen_tail;
        }
    }
    return st;
}

} // namespace

int main() {
    std::cout << "CASE playback_bank_select EXECUTED\n";
    std::cout << "PRE-REGISTER: legacy under stale PLXD free → display-bank overwrites "
                 "and/or collapsed late display tags; fixed → motion, 0 disp overwrites\n";

    RunStats leg = run_legacy();
    std::cout << "raw legacy presents=" << leg.presents
              << " drops=" << leg.drops
              << " waits=" << leg.waits
              << " disp_overwrites=" << leg.disp_bank_overwrites
              << " free_eq_disp_writes=" << leg.free_eq_disp_writes
              << " unique_late_display=" << leg.unique_late_display
              << " frozen_tail=" << leg.frozen_tail
              << " last_tag=" << leg.last_display_tag
              << "\n";

    // RED: legacy must show the freeze/collision class.
    const bool legacy_bad = (leg.disp_bank_overwrites >= 10) ||
                            (leg.unique_late_display <= 5 && leg.presents >= 100) ||
                            (leg.frozen_tail >= 40);
    if (!legacy_bad) {
        std::cerr << "FAIL legacy: expected stale-free collision/freeze class, looked healthy "
                  << "disp_overwrites=" << leg.disp_bank_overwrites
                  << " unique_late=" << leg.unique_late_display
                  << " frozen_tail=" << leg.frozen_tail << "\n";
        return 1;
    }
    std::cout << "REPRO_OK legacy_stale_free: disp_overwrites=" << leg.disp_bank_overwrites
              << " unique_late=" << leg.unique_late_display
              << " frozen_tail=" << leg.frozen_tail << "\n";

    RunStats fix = run_fixed();
    std::cout << "raw fixed presents=" << fix.presents
              << " drops=" << fix.drops
              << " waits=" << fix.waits
              << " disp_overwrites=" << fix.disp_bank_overwrites
              << " free_eq_disp_writes=" << fix.free_eq_disp_writes
              << " unique_late_display=" << fix.unique_late_display
              << " frozen_tail=" << fix.frozen_tail
              << " last_tag=" << fix.last_display_tag
              << "\n";

    const bool fixed_ok = (fix.disp_bank_overwrites == 0) &&
                          (fix.unique_late_display >= 40) &&
                          (fix.frozen_tail <= 3) &&
                          (fix.presents >= (kFrames * 3) / 4);
    if (!fixed_ok) {
        std::cerr << "FAIL fixed: expected sustained display motion without disp overwrites "
                  << "disp_overwrites=" << fix.disp_bank_overwrites
                  << " unique_late=" << fix.unique_late_display
                  << " frozen_tail=" << fix.frozen_tail
                  << " presents=" << fix.presents << "\n";
        return 1;
    }
    std::cout << "PASS fixed_display_ack: motion unique_late=" << fix.unique_late_display
              << " presents=" << fix.presents
              << " drops=" << fix.drops
              << " disp_overwrites=0\n";
    std::cout << "OK ddr_playback_bank_select: REPRO_OK legacy + PASS fixed (EXECUTED)\n";
    return 0;
}
