#include "Vtrue480_i420_tb.h"
#include "verilated.h"

#include "true480_i420_test_support.hpp"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <set>
#include <stdexcept>
#include <string>

namespace {

using true480::Rgb;

struct Metrics {
    uint64_t visible = 0;
    uint64_t yHits = 0;
    uint64_t cHits = 0;
    uint64_t bothHits = 0;
    uint64_t softC = 0;
    uint64_t misses = 0;
    uint64_t orange = 0;
    uint64_t dark = 0;
    uint64_t black = 0;
    uint64_t longestBothRun = 0;
    std::set<int> sourceRows;
    uint16_t underrunBefore = 0;
    uint16_t underrunAfter = 0;
};

class Sim {
public:
    Vtrue480_i420_tb top{};
    true480::DdrModel<Vtrue480_i420_tb> ddr;

    Sim() : ddr(top) {
        top.clk = 0;
        top.clk_ddr = 0;
        top.reset = 0;
        top.rd_x = 0;
        top.rd_y = 0;
        top.rd_active = 0;
        top.vsync_pulse = 0;
        top.DDRAM_BUSY = 0;
        top.DDRAM_DOUT = 0;
        top.DDRAM_DOUT_READY = 0;
    }

    void tick() {
        top.clk = 0;
        top.clk_ddr = 0;
        top.eval();
        for (int i = 0; i < 5; ++i) {
            ddr.drive();
            top.clk_ddr = 1;
            top.eval();
            ddr.startRequests();
            top.clk_ddr = 0;
            top.eval();
        }
        top.clk = 1;
        top.eval();
        top.clk = 0;
        top.eval();
        ++cycle;
        top.vsync_pulse = 0;
    }

    void resetCore() {
        top.reset = 1;
        for (int i = 0; i < 10; ++i)
            tick();
        top.reset = 0;
        for (int i = 0; i < 6; ++i)
            tick();
    }

    void setOutputPixel(int x, int y, bool legacyRows = false) {
        top.rd_x = x;
        top.rd_y = legacyRows ? ((y >> 1) << 1) : y;
        top.rd_active = 1;
    }

    void videoTick(bool legacyRows = false) {
        setOutputPixel(scanX, scanY, legacyRows);
        top.vsync_pulse = (scanX == 0 && scanY == 0);
        tick();
        ++scanX;
        if (scanX == true480::kOutW) {
            scanX = 0;
            ++scanY;
            if (scanY == true480::kOutH)
                scanY = 0;
        }
    }

    void present(int bank) {
        resetCore();
        top.rd_active = 0;
        for (int i = 0; i < 3000; ++i)
            tick();
        ddr.ringDoorbell(bank, 1);
        const uint64_t deadline = cycle + 3ull * true480::kOutW * true480::kOutH;
        while (!top.has_frame && cycle < deadline)
            videoTick();
        if (!top.has_frame)
            throw std::runtime_error("doorbell frame never reached display bank");
        if (!top.doorbell_ok)
            throw std::runtime_error("YUV420p doorbell was not accepted");
    }

    void scanFrames(int count, bool legacyRows = false, int clocksPerPixel = 1) {
        for (int frame = 0; frame < count; ++frame) {
            for (int y = 0; y < true480::kOutH; ++y) {
                for (int x = 0; x < true480::kOutW; ++x) {
                    setOutputPixel(x, y, legacyRows);
                    for (int hold = 0; hold < clocksPerPixel; ++hold) {
                        top.vsync_pulse = (hold == 0 && x == 0 && y == 0);
                        tick();
                    }
                }
            }
        }
    }

    Metrics captureFrame(bool legacyRows = false, int clocksPerPixel = 1) {
        Metrics m;
        uint64_t bothRun = 0;
        m.underrunBefore = top.underrun_count;
        for (int y = 0; y < true480::kOutH; ++y) {
            for (int x = 0; x < true480::kOutW; ++x) {
                setOutputPixel(x, y, legacyRows);
                top.vsync_pulse = (x == 0 && y == 0);
                top.clk = 0;
                top.clk_ddr = 0;
                top.eval();
                if (top.obs_visible_now)
                    m.sourceRows.insert(top.obs_src_y_now);
                for (int hold = 0; hold < clocksPerPixel; ++hold) {
                    top.vsync_pulse = (hold == 0 && x == 0 && y == 0);
                    tick();
                }

                if (!top.obs_visible_pipe)
                    continue;
                ++m.visible;
                if (top.obs_y_hit)
                    ++m.yHits;
                if (top.obs_c_hit)
                    ++m.cHits;
                if (top.obs_y_hit && top.obs_c_hit) {
                    ++m.bothHits;
                    ++bothRun;
                    m.longestBothRun = std::max(m.longestBothRun, bothRun);
                } else {
                    bothRun = 0;
                }
                if (top.obs_y_hit && !top.obs_c_hit)
                    ++m.softC;
                if (top.obs_miss)
                    ++m.misses;
                const Rgb p{top.rd_r, top.rd_g, top.rd_b};
                if (true480::isOrange(p))
                    ++m.orange;
                if (true480::isDark(p))
                    ++m.dark;
                if (p.r <= 2 && p.g <= 2 && p.b <= 2)
                    ++m.black;
            }
        }
        for (int i = 0; i < 8; ++i)
            tick();
        m.underrunAfter = top.underrun_count;
        return m;
    }

    Rgb settleAt(int x, int y, bool wantY, bool wantC, int maxCycles = 30000) {
        setOutputPixel(x, y);
        top.vsync_pulse = 0;
        int matched = 0;
        for (int i = 0; i < maxCycles; ++i) {
            tick();
            const bool state = (!wantY || top.obs_y_hit) && (!wantC || top.obs_c_hit);
            if (state) {
                if (++matched >= 12)
                    return {top.rd_r, top.rd_g, top.rd_b};
            } else {
                matched = 0;
            }
        }
        throw std::runtime_error("pixel did not reach requested Y/C hit state");
    }

    Rgb settleAtYHitCMiss(int x, int y, int maxCycles = 50000) {
        setOutputPixel(x, y);
        top.vsync_pulse = 0;
        int matched = 0;
        for (int i = 0; i < maxCycles; ++i) {
            tick();
            if (ddr.sawHungCRead() && top.obs_y_hit && !top.obs_c_hit) {
                if (++matched >= 12)
                    return {top.rd_r, top.rd_g, top.rd_b};
            } else {
                matched = 0;
            }
        }
        throw std::runtime_error("forced C miss never produced explicit Y-hit/C-miss");
    }

    Rgb settleAtYMiss(int x, int y, int maxCycles = 30000) {
        setOutputPixel(x, y);
        top.vsync_pulse = 0;
        for (int i = 0; i < maxCycles; ++i) {
            tick();
            if (ddr.sawHungYRead() && !top.obs_y_hit) {
                for (int hold = 0; hold < 12; ++hold)
                    tick();
                return {top.rd_r, top.rd_g, top.rd_b};
            }
        }
        throw std::runtime_error("forced Y miss never reached explicit no-Y-hit state");
    }

private:
    uint64_t cycle = 0;
    int scanX = 0;
    int scanY = 0;
};

void printRgb(const char* label, Rgb p) {
    std::cout << label << "=" << static_cast<int>(p.r) << ","
              << static_cast<int>(p.g) << "," << static_cast<int>(p.b);
}

int checkGeometry(Vtrue480_i420_tb& top) {
    int failures = 0;
    std::set<int> rows;
    uint64_t visible = 0;
    for (int y = 0; y < true480::kOutH; ++y) {
        for (int x = 0; x < true480::kOutW; ++x) {
            top.rd_x = x;
            top.rd_y = y;
            top.rd_active = 1;
            top.clk = 0;
            top.clk_ddr = 0;
            top.eval();
            const bool expectedVisible =
                x >= true480::kPillarLeft &&
                x < true480::kPillarLeft + true480::kDisplayW;
            if (static_cast<bool>(top.obs_visible_now) != expectedVisible)
                ++failures;
            if (top.obs_visible_now) {
                ++visible;
                rows.insert(top.obs_src_y_now);
                if (top.obs_src_x_now != x - true480::kPillarLeft ||
                    top.obs_src_y_now != y)
                    ++failures;
            }
        }
    }
    if (visible != static_cast<uint64_t>(true480::kDisplayW) * true480::kOutH)
        ++failures;
    if (rows.size() != true480::kOutH)
        ++failures;
    if (failures) {
        std::cerr << "FAIL true480 geometry exact_crop_pillars visible=" << visible
                  << " unique_rows=" << rows.size()
                  << " mismatches=" << failures
                  << " expected=11+618+11x480 crop_left=0\n";
        return 1;
    }
    std::cout << "PASS true480 geometry exact_crop_pillars=11+618+11x480"
              << " unique_rows=480\n";
    return 0;
}

int runGood(bool legacyRows, bool requireUnderrunZero) {
    Sim sim;
    const auto frame = true480::makeIdleI420();
    sim.ddr.loadBank(0, frame);
    sim.ddr.loadBank(1, frame);
    sim.present(0);
    if (!legacyRows && checkGeometry(sim.top) != 0)
        return 1;
    const int clocksPerPixel = requireUnderrunZero ? 1 : 3;
    sim.scanFrames(2, legacyRows, clocksPerPixel);
    const Metrics m = sim.captureFrame(legacyRows, clocksPerPixel);

    const uint64_t expectedVisible =
        static_cast<uint64_t>(true480::kDisplayW) * true480::kOutH;
    bool ok = true;
    if (m.sourceRows.size() != true480::kOutH) {
        std::cerr << "FAIL true480 row_identity unique_rows=" << m.sourceRows.size()
                  << " expected=480 mode=" << (legacyRows ? "legacy_store_y_2py" : "identity")
                  << "\n";
        ok = false;
    }
    if (m.visible + 16 < expectedVisible || m.visible > expectedVisible + 16) {
        std::cerr << "FAIL true480 visible_count got=" << m.visible
                  << " expected=" << expectedVisible << "\n";
        ok = false;
    }
    if (m.yHits < expectedVisible * 99 / 100 ||
        m.cHits < expectedVisible * 99 / 100 ||
        m.longestBothRun < 512) {
        std::cerr << "FAIL true480 sustained_hits Y=" << m.yHits
                  << " C=" << m.cHits << " both_run=" << m.longestBothRun
                  << " visible=" << m.visible << "\n";
        ok = false;
    }
    if (m.softC != 0) {
        std::cerr << "FAIL true480 settled_visible_soft_c_fallback count=" << m.softC
                  << "\n";
        ok = false;
    }
    if (requireUnderrunZero && m.underrunAfter != m.underrunBefore) {
        std::cerr << "FAIL true480 steady_underrun before=" << m.underrunBefore
                  << " after=" << m.underrunAfter << "\n";
        ok = false;
    }
    uint64_t expectedOrangeCount = 0;
    uint64_t expectedDarkCount = 0;
    for (int y = 0; y < true480::kOutH; ++y) {
        for (int x = true480::kPillarLeft;
             x < true480::kPillarLeft + true480::kDisplayW; ++x) {
            const Rgb p = true480::expectedAt(frame, x, y);
            expectedOrangeCount += true480::isOrange(p);
            expectedDarkCount += true480::isDark(p);
        }
    }
    if (m.orange + 32 < expectedOrangeCount * 98 / 100 ||
        m.dark + 32 < expectedDarkCount * 98 / 100) {
        std::cerr << "FAIL true480 orange_on_dark orange=" << m.orange
                  << "/" << expectedOrangeCount << " dark=" << m.dark
                  << "/" << expectedDarkCount
                  << " black_visible=" << m.black << "\n";
        ok = false;
    }

    const Rgb orange = sim.settleAt(330, 240, true, true);
    const Rgb dark = sim.settleAt(20, 20, true, true);
    const Rgb leftPillar = sim.settleAt(10, 240, false, false);
    const Rgb rightPillar = sim.settleAt(629, 240, false, false);
    const Rgb expectedOrange = true480::expectedAt(frame, 330, 240);
    const Rgb expectedDark = true480::expectedAt(frame, 20, 20);
    if (!true480::near(orange, expectedOrange) ||
        !true480::near(dark, expectedDark) ||
        leftPillar.r > 2 || leftPillar.g > 2 || leftPillar.b > 2 ||
        rightPillar.r > 2 || rightPillar.g > 2 || rightPillar.b > 2) {
        std::cerr << "FAIL true480 representative_rgb ";
        printRgb("orange", orange);
        std::cerr << " ";
        printRgb("want_orange", expectedOrange);
        std::cerr << " ";
        printRgb("dark", dark);
        std::cerr << " ";
        printRgb("want_dark", expectedDark);
        std::cerr << " ";
        printRgb("left_pillar", leftPillar);
        std::cerr << " ";
        printRgb("right_pillar", rightPillar);
        std::cerr << "\n";
        ok = false;
    }

    std::cout << "TRUE480_FRAME mode=" << (legacyRows ? "legacy_store_y_2py" : "identity")
              << " clocks_per_pixel=" << clocksPerPixel
              << " visible=" << m.visible << " y_hits=" << m.yHits
              << " c_hits=" << m.cHits << " soft_c=" << m.softC
              << " unique_rows=" << m.sourceRows.size()
              << " underrun_delta=" << (m.underrunAfter - m.underrunBefore)
              << " orange=" << m.orange << " dark=" << m.dark << " ";
    printRgb("orange_rgb", orange);
    std::cout << " ";
    printRgb("dark_rgb", dark);
    std::cout << "\n";
    return ok ? 0 : 1;
}

int runCMiss(bool observationOnly) {
    Sim sim;
    const auto frame = true480::makeIdleI420();
    sim.ddr.loadBank(0, frame);
    sim.ddr.loadBank(1, frame);
    sim.present(0);
    sim.scanFrames(1);
    sim.ddr.setHangC(true);
    const Rgb got = sim.settleAtYHitCMiss(20, 100);
    const Rgb want = true480::expectedAt(frame, 20, 100, true);
    const bool explicitMiss = sim.ddr.sawHungCRead() && sim.top.obs_y_hit && !sim.top.obs_c_hit;
    const bool gray = true480::near(got, want) &&
                      std::abs(static_cast<int>(got.r) - static_cast<int>(got.g)) <= 2 &&
                      std::abs(static_cast<int>(got.g) - static_cast<int>(got.b)) <= 2;
    std::cout << "TRUE480_FORCE_C_MISS explicit_y_hit_c_miss=" << explicitMiss << " ";
    printRgb("rgb", got);
    std::cout << " ";
    printRgb("neutral_expected", want);
    std::cout << " class=" << (gray ? "NEUTRAL_GRAY" : "NOT_NEUTRAL_GRAY") << "\n";
    if (!explicitMiss)
        return 1;
    if (observationOnly)
        return 0;
    if (!gray) {
        std::cerr << "FAIL true480 force_c_miss: explicit C miss did not use neutral UV; "
                     "required RTL behavior is hard-miss-on-Y only plus U=V=128 fallback\n";
        return 1;
    }
    return 0;
}

int runYMiss() {
    Sim sim;
    const auto frame = true480::makeIdleI420();
    sim.ddr.loadBank(0, frame);
    sim.ddr.loadBank(1, frame);
    sim.present(0);
    sim.scanFrames(1);
    sim.ddr.setHangY(true);
    const Rgb got = sim.settleAtYMiss(20, 100);
    const bool black = got.r <= 2 && got.g <= 2 && got.b <= 2;
    std::cout << "TRUE480_FORCE_Y_MISS explicit_y_miss="
              << (sim.ddr.sawHungYRead() && !sim.top.obs_y_hit) << " ";
    printRgb("rgb", got);
    std::cout << " class=" << (black ? "BLACK" : "NOT_BLACK") << "\n";
    return black ? 0 : 1;
}

int runBadBank() {
    Sim sim;
    const auto idle = true480::makeIdleI420();
    const auto blackFrame = true480::makeBlackI420();
    sim.ddr.loadBank(0, idle);
    sim.ddr.loadBank(1, blackFrame);
    sim.present(1);
    sim.scanFrames(2);
    const Metrics m = sim.captureFrame();
    const Rgb got = sim.settleAt(330, 240, true, true);
    const bool black = got.r <= 18 && got.g <= 18 && got.b <= 18;
    const bool hits = m.yHits > 1000 && m.cHits > 1000 && sim.top.obs_disp_bank == 1;
    std::cout << "TRUE480_FORCE_BAD_BANK disp_bank=" << static_cast<int>(sim.top.obs_disp_bank)
              << " y_hits=" << m.yHits << " c_hits=" << m.cHits << " ";
    printRgb("rgb", got);
    std::cout << " class=" << (black ? "BLACK" : "NOT_BLACK") << "\n";
    return black && hits ? 0 : 1;
}

std::string scenarioFromArgs(int argc, char** argv) {
    std::string scenario = "good";
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--scenario" && i + 1 < argc)
            scenario = argv[++i];
    }
    return scenario;
}

bool requireActiveConfigFromArgs(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == "--require-active-config")
            return true;
    }
    return false;
}

int checkActiveConfig(bool required) {
    Vtrue480_i420_tb top;
    top.eval();
    const bool active = top.cfg_active_config;
    const int stride = top.cfg_y_fill_stride;
    const uint32_t fallbackPolls =
        top.cfg_stale_doorbell_fallback_polls;
    std::cout << "TRUE480_BUILD_CONFIG active_define=" << active
              << " y_fill_stride=" << stride
              << " stale_doorbell_fallback_polls=" << fallbackPolls
              << " required=" << required << "\n";
    if (required && (!active || stride != 1 || fallbackPolls != 4096)) {
        std::cerr << "FAIL true480 active configuration disappeared: "
                    "PLEX_PRESENT_TRUE_480P=0, Y_FILL_STRIDE!=1, or "
                    "STALE_DOORBELL_FALLBACK_POLLS!=4096\n";
        return 1;
    }
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        if (checkActiveConfig(requireActiveConfigFromArgs(argc, argv)) != 0)
            return 1;
        const std::string scenario = scenarioFromArgs(argc, argv);
        if (scenario == "good")
            return runGood(false, true);
        if (scenario == "smoke")
            return runGood(false, false);
        if (scenario == "legacy")
            return runGood(true, false);
        if (scenario == "c-miss")
            return runCMiss(false);
        if (scenario == "c-miss-observe")
            return runCMiss(true);
        if (scenario == "y-miss")
            return runYMiss();
        if (scenario == "bad-bank")
            return runBadBank();
        std::cerr << "unknown --scenario " << scenario << "\n";
        return 2;
    } catch (const std::exception& e) {
        std::cerr << "FAIL true480_i420_tb: " << e.what() << "\n";
        return 1;
    }
}
