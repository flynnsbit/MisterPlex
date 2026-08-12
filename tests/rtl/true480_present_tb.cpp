#include "Vtrue480_present_tb.h"
#include "verilated.h"

#include "true480_i420_test_support.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <set>
#include <stdexcept>
#include <string>

namespace {

struct Metrics {
    uint64_t samples = 0;
    uint64_t yHits = 0;
    uint64_t cHits = 0;
    uint64_t softC = 0;
    uint64_t misses = 0;
    uint64_t orange = 0;
    uint64_t dark = 0;
    uint64_t neutralGray = 0;
    uint64_t black = 0;
    uint64_t longestBothRun = 0;
    uint16_t underrunBefore = 0;
    uint16_t underrunAfter = 0;
    std::set<int> outputRows;
    std::set<int> storeRows;
    std::set<int> sourceRows;
    int minVisibleX = 1 << 30;
    int maxVisibleX = -1;
    int minVisibleY = 1 << 30;
    int maxVisibleY = -1;
    int leftPillar = 0;
    int rightPillar = 0;
};

class Sim {
public:
    Vtrue480_present_tb top{};
    true480::DdrModel<Vtrue480_present_tb> ddr;

    Sim() : ddr(top) {
        top.clk = 0;
        top.clk_ddr = 0;
        top.reset = 0;
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
    }

    void resetCore() {
        top.reset = 1;
        for (int i = 0; i < 12; ++i)
            tick();
        top.reset = 0;
        for (int i = 0; i < 8; ++i)
            tick();
    }

    bool presentFrame(bool requireSwap = true) {
        resetCore();
        for (int i = 0; i < 3000; ++i)
            tick();
        ddr.ringDoorbell(0, 1);
        const uint64_t deadline = cycle + 4ull * 638 * 524;
        while (!top.has_frame && cycle < deadline) {
            if (top.ce_pix && top.obs_in_content) {
                ++noSwapSamples;
                if (top.r <= 2 && top.g <= 2 && top.b <= 2)
                    ++noSwapBlack;
            }
            tick();
        }
        if (!top.has_frame && requireSwap)
            throw std::runtime_error("present_core never swapped the I420 frame");
        return top.has_frame;
    }

    void waitFrameStart() {
        const uint64_t deadline = cycle + 2ull * 638 * 524;
        while (!top.obs_frame_start && cycle < deadline)
            tick();
        if (!top.obs_frame_start)
            throw std::runtime_error("present_core frame_start timeout");
        tick();
    }

    Metrics captureOneFrame() {
        waitFrameStart();
        Metrics m;
        m.underrunBefore = top.underrun_count;
        uint64_t bothRun = 0;
        const uint64_t deadline = cycle + 2ull * 638 * 524;
        while (cycle < deadline) {
                if (top.obs_frame_start)
                    break;
            if (top.ce_pix) {
                const int hc = top.obs_hc;
                const int outputY =
                    top.cfg_active_config ? top.obs_vc : top.obs_py;
                const int visibleX =
                    top.cfg_active_config ? top.obs_store_x : hc;
                const int visibleY =
                    top.cfg_active_config ? top.obs_store_y : top.obs_py;
                if (top.obs_in_content) {
                    m.outputRows.insert(outputY);
                    m.storeRows.insert(top.obs_store_y);
                }
                if (top.obs_visible_now) {
                    m.sourceRows.insert(top.obs_src_y_now);
                    m.minVisibleX = std::min(m.minVisibleX, visibleX);
                    m.maxVisibleX = std::max(m.maxVisibleX, visibleX);
                    m.minVisibleY = std::min(m.minVisibleY, visibleY);
                    m.maxVisibleY = std::max(m.maxVisibleY, visibleY);
                    if (visibleX < true480::kPillarLeft)
                        ++m.leftPillar;
                    if (visibleX >= true480::kPillarLeft + true480::kDisplayW)
                        ++m.rightPillar;
                }
                if (top.obs_visible_pipe) {
                    ++m.samples;
                    if (top.obs_y_hit)
                        ++m.yHits;
                    if (top.obs_c_hit)
                        ++m.cHits;
                    if (top.obs_y_hit && top.obs_c_hit) {
                        ++bothRun;
                        m.longestBothRun = std::max(m.longestBothRun, bothRun);
                    } else {
                        bothRun = 0;
                    }
                    if (top.obs_y_hit && !top.obs_c_hit)
                        ++m.softC;
                    if (top.obs_miss)
                        ++m.misses;
                    const true480::Rgb p{top.r, top.g, top.b};
                    m.orange += true480::isOrange(p);
                    m.dark += true480::isDark(p);
                    m.neutralGray +=
                        std::abs(static_cast<int>(p.r) - static_cast<int>(p.g)) <= 2 &&
                        std::abs(static_cast<int>(p.g) - static_cast<int>(p.b)) <= 2;
                    m.black += p.r <= 2 && p.g <= 2 && p.b <= 2;
                }
            }
            tick();
        }
        m.underrunAfter = top.underrun_count;
        return m;
    }

    uint64_t noSwapSampleCount() const { return noSwapSamples; }
    uint64_t noSwapBlackCount() const { return noSwapBlack; }

private:
    uint64_t cycle = 0;
    uint64_t noSwapSamples = 0;
    uint64_t noSwapBlack = 0;
};

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string calibration;
    bool requireActiveConfig = false;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--calibrate-keepv22")
            calibration = "keepv22";
        else if (arg == "--calibrate-keepv27")
            calibration = "keepv27";
        else if (arg == "--require-active-config")
            requireActiveConfig = true;
        else {
            std::cerr << "unknown argument: " << arg << "\n";
            return 2;
        }
    }
    try {
        Sim sim;
        sim.top.eval();
        const bool activeConfig = sim.top.cfg_active_config;
        const bool nativeBeam = sim.top.cfg_native_beam_source;
        const int fillStride = sim.top.cfg_y_fill_stride;
        std::cout << "TRUE480_PRESENT_BUILD_CONFIG active_define="
                  << activeConfig << " native_beam_source=" << nativeBeam
                  << " y_fill_stride=" << fillStride
                  << " required=" << requireActiveConfig << "\n";
        if (requireActiveConfig &&
            (!activeConfig || !nativeBeam || fillStride != 1)) {
            std::cerr << "FAIL true480 present active configuration disappeared: "
                         "define/native beam/fill stride contract is not active\n";
            return 1;
        }
        if (!calibration.empty() && activeConfig) {
            std::cerr << "FAIL true480 snapshot calibration must remain "
                         "PLEX_PRESENT_TRUE_480P macro-OFF\n";
            return 1;
        }
        const auto frame = true480::makeIdleI420();
        sim.ddr.loadBank(0, frame);
        sim.ddr.loadBank(1, frame);
        const bool swapped = sim.presentFrame(calibration != "keepv27");
        if (calibration == "keepv27") {
            const uint64_t samples = sim.noSwapSampleCount();
            const uint64_t black = sim.noSwapBlackCount();
            const bool ok = !swapped && samples > 100000 &&
                            black >= samples * 99 / 100;
            std::cout << "TRUE480_CAL_KEEPV27 has_frame=" << swapped
                      << " active_samples=" << samples
                      << " black_samples=" << black
                      << " phenotype=BLACK_NO_SWAP\n";
            if (!ok) {
                std::cerr << "FAIL keepv27 calibration: expected unchanged "
                             "real path to remain black with no frame swap\n";
                return 1;
            }
            std::cout << "PASS keepv27 calibrated black/no-swap without forced misses\n";
            return 0;
        }
        sim.captureOneFrame();
        sim.captureOneFrame();
        const Metrics m = sim.captureOneFrame();

        if (calibration == "keepv22") {
            const bool ok =
                swapped && m.outputRows.size() == 240 &&
                m.storeRows.size() == 240 && m.sourceRows.size() == 240 &&
                m.yHits > 100000 && m.cHits > 10000 &&
                m.cHits < m.yHits / 3 && m.softC > 100000 &&
                m.orange == 0 && m.neutralGray > 100000 &&
                m.underrunAfter == m.underrunBefore;
            std::cout << "TRUE480_CAL_KEEPV22 has_frame=" << swapped
                      << " output_rows=" << m.outputRows.size()
                      << " store_rows=" << m.storeRows.size()
                      << " source_rows=" << m.sourceRows.size()
                      << " y_hits=" << m.yHits << " c_hits=" << m.cHits
                      << " soft_c=" << m.softC
                      << " neutral_gray=" << m.neutralGray
                      << " orange=" << m.orange
                      << " black=" << m.black
                      << " underrun_delta="
                      << (m.underrunAfter - m.underrunBefore)
                      << " phenotype=NEUTRAL_GRAY_C_STARVATION\n";
            if (!ok) {
                std::cerr << "FAIL keepv22 calibration: expected unchanged "
                             "240-row neutral-gray/C-starvation phenotype\n";
                return 1;
            }
            std::cout << "PASS keepv22 calibrated neutral gray/C starvation "
                         "without forced misses\n";
            return 0;
        }

        bool ok = true;
        if (m.outputRows.size() != true480::kOutH ||
            m.storeRows.size() != true480::kOutH ||
            m.sourceRows.size() != true480::kOutH) {
            std::cerr << "FAIL true480 present row_identity output_rows="
                      << m.outputRows.size() << " store_rows=" << m.storeRows.size()
                      << " source_rows=" << m.sourceRows.size()
                      << " expected=480; legacy Template store_y=2*py is forbidden\n";
            ok = false;
        }
        if (m.minVisibleX != 11 || m.maxVisibleX != 628 ||
            m.minVisibleY != 0 || m.maxVisibleY != 479 ||
            m.leftPillar != 0 || m.rightPillar != 0) {
            std::cerr << "FAIL true480 present geometry x=[" << m.minVisibleX << ","
                      << m.maxVisibleX << "] y=[" << m.minVisibleY << ","
                      << m.maxVisibleY << "] pillar_visible=" << m.leftPillar
                      << "+" << m.rightPillar
                      << " expected x=[11,628] y=[0,479]\n";
            ok = false;
        }
        if (m.yHits == 0 || m.cHits == 0 || m.longestBothRun < 512) {
            std::cerr << "FAIL true480 present sustained_hits y=" << m.yHits
                      << " c=" << m.cHits << " both_run=" << m.longestBothRun << "\n";
            ok = false;
        }
        if (m.softC != 0) {
            std::cerr << "FAIL true480 present settled_visible_soft_c count="
                      << m.softC << "\n";
            ok = false;
        }
        if (m.underrunAfter != m.underrunBefore) {
            std::cerr << "FAIL true480 present steady_underrun before="
                      << m.underrunBefore << " after=" << m.underrunAfter << "\n";
            ok = false;
        }
        if (m.orange < 4000 || m.dark < 200000) {
            std::cerr << "FAIL true480 present orange_on_dark orange=" << m.orange
                      << " dark=" << m.dark << "\n";
            ok = false;
        }

        std::cout << "TRUE480_PRESENT output_rows=" << m.outputRows.size()
                  << " store_rows=" << m.storeRows.size()
                  << " source_rows=" << m.sourceRows.size()
                  << " visible_x=" << m.minVisibleX << ".." << m.maxVisibleX
                  << " visible_y=" << m.minVisibleY << ".." << m.maxVisibleY
                  << " y_hits=" << m.yHits << " c_hits=" << m.cHits
                  << " soft_c=" << m.softC
                  << " underrun_delta=" << (m.underrunAfter - m.underrunBefore)
                  << " orange=" << m.orange << " dark=" << m.dark
                  << " neutral_gray=" << m.neutralGray
                  << " black=" << m.black << "\n";
        return ok ? 0 : 1;
    } catch (const std::exception& e) {
        std::cerr << "FAIL true480_present_tb: " << e.what() << "\n";
        return 1;
    }
}
