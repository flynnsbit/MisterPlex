#include "Vtrue480_shared_ddr_tb.h"
#include "verilated.h"

#include "true480_i420_test_support.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kM1BasePhys = 0x30100000u;
constexpr uint32_t kModelBytes = 0x00200000u;

struct ModelConfig {
    int baseLatency = 24;
    int latencyJitter = 32;
    int refreshPeriod = 702;
    int refreshCycles = 9;
    int beatGapPeriod = 17;
    int beatGapCycles = 2;
    bool ideal = false;
};

struct DdrStats {
    uint64_t cycles = 0;
    uint64_t commands = 0;
    uint64_t m0Reads = 0;
    uint64_t m1Reads = 0;
    uint64_t writes = 0;
    uint64_t m0Beats = 0;
    uint64_t m1Beats = 0;
    uint64_t m0ExpectedBeats = 0;
    uint64_t m1ExpectedBeats = 0;
    uint64_t refreshStallCycles = 0;
    uint64_t burstGapCycles = 0;
    uint64_t protocolErrors = 0;
    uint64_t doorbellReads = 0;
    uint64_t doorbellMagicBeats = 0;
    uint64_t lastDoorbellData = 0;
    uint64_t programmedDoorbellData = 0;
    uint64_t doorbellWrites = 0;
    uint64_t lastReadByteAddress = 0;
    uint32_t maxBurst = 0;
    uint32_t minObservedLatency = UINT32_MAX;
    uint32_t maxObservedLatency = 0;
};

class SharedDdrModel {
public:
    SharedDdrModel(Vtrue480_shared_ddr_tb& topRef, ModelConfig config)
        : top(topRef), cfg(config), memory(kModelBytes / 8, 0) {}

    void loadBank(int bank, const std::vector<uint8_t>& frame) {
        if (bank < 0 || bank > 1 || frame.size() != true480::kFrameBytes)
            throw std::runtime_error("invalid shared-DDR frame load");
        const size_t base =
            static_cast<size_t>(bank) * true480::kBankStrideBytes / 8;
        for (size_t byte = 0; byte < frame.size(); byte += 8)
            memory[base + byte / 8] = true480::pack8(frame.data() + byte);
    }

    void seedM1Ring() {
        const size_t first = (kM1BasePhys - true480::kBasePhys) / 8;
        for (size_t i = 0; i < 0x10000 / 8; ++i)
            memory[first + i] = 0xcafe000000000000ull | i;
    }

    void ringDoorbell(int bank, uint32_t sequence) {
        const size_t qword =
            (true480::kDoorbellPhys - true480::kBasePhys) / 8;
        memory[qword] =
            (static_cast<uint64_t>(true480::doorbellHigh(sequence, bank)) << 32) |
            true480::kDoorbellMagic;
        stats.programmedDoorbellData = memory[qword];
    }

    void driveBeforePosedge() {
        top.DDRAM_DOUT_READY = 0;
        bool refresh = false;
        if (!cfg.ideal && cfg.refreshPeriod > 0) {
            const int phase = static_cast<int>(stats.cycles % cfg.refreshPeriod);
            refresh = phase < cfg.refreshCycles;
            if (refresh)
                ++stats.refreshStallCycles;
        }

        if (busyHold > 0)
            --busyHold;
        top.DDRAM_BUSY = (busyHold > 0) || refresh;

        if (transaction.active && transaction.read) {
            ++transaction.age;
            if (transaction.delay > 0) {
                --transaction.delay;
            } else if (!refresh) {
                if (gapLeft > 0) {
                    --gapLeft;
                    ++stats.burstGapCycles;
                } else {
                    top.DDRAM_DOUT =
                        readQword(transaction.addr + transaction.beat);
                    if (static_cast<uint64_t>(transaction.addr +
                                              transaction.beat) *
                            8 ==
                        true480::kDoorbellPhys) {
                        ++stats.doorbellMagicBeats;
                        stats.lastDoorbellData = top.DDRAM_DOUT;
                    }
                    top.DDRAM_DOUT_READY = 1;
                    if (transaction.ownerM1)
                        ++stats.m1Beats;
                    else
                        ++stats.m0Beats;
                    ++transaction.beat;
                    if (!cfg.ideal && cfg.beatGapPeriod > 0 &&
                        transaction.beat < transaction.burst &&
                        transaction.beat % cfg.beatGapPeriod == 0)
                        gapLeft = cfg.beatGapCycles;
                    if (transaction.beat == transaction.burst) {
                        noteLatency();
                        transaction = {};
                    }
                }
            }
        }
        ++stats.cycles;
    }

    void sampleCommandAtPosedge() {
        const bool command = top.DDRAM_RD || top.DDRAM_WE;
        if (!command) {
            commandLatched = false;
            return;
        }
        const bool sameCommand =
            commandLatched && latchedAddr == top.DDRAM_ADDR &&
            latchedBurst == top.DDRAM_BURSTCNT &&
            latchedRead == static_cast<bool>(top.DDRAM_RD) &&
            latchedWrite == static_cast<bool>(top.DDRAM_WE);
        if (sameCommand)
            return;
        if (transaction.active || top.DDRAM_BUSY)
            return;
        commandLatched = true;
        latchedAddr = top.DDRAM_ADDR;
        latchedBurst = top.DDRAM_BURSTCNT;
        latchedRead = top.DDRAM_RD;
        latchedWrite = top.DDRAM_WE;
        const uint32_t burst = std::max<uint32_t>(1, top.DDRAM_BURSTCNT);
        transaction.active = true;
        transaction.read = top.DDRAM_RD;
        transaction.ownerM1 =
            static_cast<uint64_t>(top.DDRAM_ADDR) * 8 >= kM1BasePhys;
        transaction.addr = top.DDRAM_ADDR;
        transaction.burst = burst;
        transaction.beat = 0;
        transaction.age = 0;
        transaction.delay =
            cfg.ideal ? 0
                      : cfg.baseLatency +
                            static_cast<int>((stats.commands * 13) %
                                             (cfg.latencyJitter + 1));
        gapLeft = 0;
        busyHold = cfg.ideal ? 1 : 3;
        ++stats.commands;
        stats.maxBurst = std::max(stats.maxBurst, burst);

        if (top.DDRAM_RD) {
            stats.lastReadByteAddress =
                static_cast<uint64_t>(top.DDRAM_ADDR) * 8;
            if (stats.lastReadByteAddress == true480::kDoorbellPhys)
                ++stats.doorbellReads;
            if (transaction.ownerM1) {
                ++stats.m1Reads;
                stats.m1ExpectedBeats += burst;
            } else {
                ++stats.m0Reads;
                stats.m0ExpectedBeats += burst;
            }
        } else {
            ++stats.writes;
            writeQword(top.DDRAM_ADDR, top.DDRAM_DIN, top.DDRAM_BE);
            transaction = {};
        }
    }

    bool idle() const { return !transaction.active; }
    const DdrStats& getStats() const { return stats; }

private:
    struct Transaction {
        bool active = false;
        bool read = false;
        bool ownerM1 = false;
        uint32_t addr = 0;
        uint32_t burst = 0;
        uint32_t beat = 0;
        uint32_t age = 0;
        int delay = 0;
    };

    Vtrue480_shared_ddr_tb& top;
    ModelConfig cfg;
    std::vector<uint64_t> memory;
    Transaction transaction;
    DdrStats stats;
    int busyHold = 0;
    int gapLeft = 0;
    bool commandLatched = false;
    uint32_t latchedAddr = 0;
    uint8_t latchedBurst = 0;
    bool latchedRead = false;
    bool latchedWrite = false;

    void noteLatency() {
        stats.minObservedLatency =
            std::min(stats.minObservedLatency, transaction.age);
        stats.maxObservedLatency =
            std::max(stats.maxObservedLatency, transaction.age);
    }

    uint64_t readQword(uint32_t qwordAddr) {
        const uint64_t byteAddr = static_cast<uint64_t>(qwordAddr) * 8;
        if (byteAddr < true480::kBasePhys ||
            byteAddr >= true480::kBasePhys + kModelBytes) {
            ++stats.protocolErrors;
            return 0;
        }
        return memory[(byteAddr - true480::kBasePhys) / 8];
    }

    void writeQword(uint32_t qwordAddr, uint64_t value, uint8_t be) {
        const uint64_t byteAddr = static_cast<uint64_t>(qwordAddr) * 8;
        if (byteAddr < true480::kBasePhys ||
            byteAddr >= true480::kBasePhys + kModelBytes) {
            ++stats.protocolErrors;
            return;
        }
        uint64_t& word = memory[(byteAddr - true480::kBasePhys) / 8];
        if (byteAddr == true480::kDoorbellPhys)
            ++stats.doorbellWrites;
        for (int i = 0; i < 8; ++i) {
            if (be & (1u << i)) {
                const uint64_t mask = 0xffull << (i * 8);
                word = (word & ~mask) | (value & mask);
            }
        }
    }
};

struct FrameMetrics {
    uint64_t active = 0;
    uint64_t visible = 0;
    uint64_t yHits = 0;
    uint64_t cHits = 0;
    uint64_t softC = 0;
    uint64_t misses = 0;
    uint64_t orange = 0;
    uint64_t dark = 0;
    uint64_t black = 0;
    uint64_t geometryErrors = 0;
    uint64_t sourceErrors = 0;
    std::set<int> rows;
    std::set<int> visibleXs;
    uint16_t underrunBefore = 0;
    uint16_t underrunAfter = 0;
    uint32_t m1ReadsBefore = 0;
    uint32_t m1ReadsAfter = 0;
    uint32_t m1ResponsesBefore = 0;
    uint32_t m1ResponsesAfter = 0;
    uint32_t m1WantBefore = 0;
    uint32_t m1WantAfter = 0;
    DdrStats ddrBefore;
    DdrStats ddrAfter;
};

class Sim {
public:
    explicit Sim(ModelConfig cfg) : ddr(top, cfg) {
        top.clk_sys = 0;
        top.clk_ddr = 0;
        top.reset = 0;
        top.m1_run = 0;
        top.DDRAM_BUSY = 0;
        top.DDRAM_DOUT = 0;
        top.DDRAM_DOUT_READY = 0;
        top.eval();
    }

    void reset() {
        top.reset = 1;
        runSysCycles(24);
        top.reset = 0;
        runSysCycles(24);
    }

    void runSysCycles(uint64_t count) {
        const uint64_t target = sysPosedges + count;
        while (sysPosedges < target)
            event();
    }

    void runUntilFrameStart() {
        bool sawLow = !top.beam_frame_start;
        const uint64_t start = sysPosedges;
        while (sysPosedges - start < 800000) {
            event();
            if (!top.beam_frame_start)
                sawLow = true;
            if (sawLow && lastSysPosedge && top.beam_frame_start)
                return;
        }
        throw std::runtime_error("native 672x496 beam did not wrap");
    }

    bool presentFrame() {
        ddr.ringDoorbell(0, 1);
        top.m1_run = 1;
        for (int frame = 0; frame < 5; ++frame) {
            runUntilFrameStart();
            if (top.has_frame && top.doorbell_ok)
                return true;
        }
        return false;
    }

    FrameMetrics captureFrame() {
        runUntilFrameStart();
        FrameMetrics m;
        m.underrunBefore = top.underrun_count;
        m.m1ReadsBefore = top.m1_reads_issued;
        m.m1ResponsesBefore = top.m1_responses_seen;
        m.m1WantBefore = top.m1_want_cycles;
        m.ddrBefore = ddr.getStats();
        bool leftStart = false;
        const uint64_t start = sysPosedges;
        while (sysPosedges - start < 800000) {
            event();
            if (!lastSysPosedge)
                continue;
            if (!top.beam_frame_start)
                leftStart = true;
            if (leftStart && top.beam_frame_start)
                break;
            if (!top.pixel_step || !top.beam_active)
                continue;
            ++m.active;
            const int x = top.beam_x;
            const int y = top.beam_y;
            const bool expectedVisible =
                x >= true480::kPillarLeft &&
                x < true480::kPillarLeft + true480::kDisplayW;
            if (static_cast<bool>(top.obs_visible_now) != expectedVisible)
                ++m.geometryErrors;
            if (top.obs_visible_now) {
                m.rows.insert(top.obs_src_y_now);
                m.visibleXs.insert(x);
                if (top.obs_src_x_now != x - true480::kPillarLeft ||
                    top.obs_src_y_now != y)
                    ++m.sourceErrors;
            }
            if (!top.obs_visible_pipe)
                continue;
            ++m.visible;
            m.yHits += top.obs_y_hit;
            m.cHits += top.obs_c_hit;
            m.softC += top.obs_y_hit && !top.obs_c_hit;
            m.misses += top.obs_miss;
            const true480::Rgb p{top.rd_r, top.rd_g, top.rd_b};
            m.orange += true480::isOrange(p);
            m.dark += true480::isDark(p);
            m.black += p.r <= 2 && p.g <= 2 && p.b <= 2;
        }
        m.underrunAfter = top.underrun_count;
        m.m1ReadsAfter = top.m1_reads_issued;
        m.m1ResponsesAfter = top.m1_responses_seen;
        m.m1WantAfter = top.m1_want_cycles;
        m.ddrAfter = ddr.getStats();
        return m;
    }

    void stopM1AndDrain() {
        top.m1_run = 0;
        for (int i = 0; i < 2000; ++i) {
            event();
            if (top.m1_reads_issued == top.m1_responses_seen && ddr.idle())
                return;
        }
    }

    Vtrue480_shared_ddr_tb top{};
    SharedDdrModel ddr;

private:
    uint64_t now = 0;
    uint64_t nextDdrEdge = 2;
    uint64_t nextSysEdge = 9;
    uint64_t sysPosedges = 0;
    bool lastSysPosedge = false;

    void event() {
        now = std::min(nextDdrEdge, nextSysEdge);
        const bool ddrEdge = now == nextDdrEdge;
        const bool sysEdge = now == nextSysEdge;
        const bool ddrRise = ddrEdge && !top.clk_ddr;
        const bool sysRise = sysEdge && !top.clk_sys;
        if (ddrRise) {
            ddr.driveBeforePosedge();
            // The f2sdram bridge samples commands at this edge. In
            // particular, the arbiter can drop grant_m1 in the NBA update,
            // so sampling its post-edge combinational mux loses the pulse.
            ddr.sampleCommandAtPosedge();
        }
        if (ddrEdge) {
            top.clk_ddr = !top.clk_ddr;
            nextDdrEdge += 2;
        }
        if (sysEdge) {
            top.clk_sys = !top.clk_sys;
            nextSysEdge += 9;
        }
        top.eval();
        if (sysRise)
            ++sysPosedges;
        lastSysPosedge = sysRise;
    }
};

int checkResourceContract(const Vtrue480_shared_ddr_tb& top) {
    bool ok = true;
    if (top.cfg_line_count != 8) {
        std::cerr << "FAIL true480 shared M10K_depth line_count="
                  << static_cast<int>(top.cfg_line_count)
                  << " required=8 (four lines cannot cover modeled stalls; "
                     "sixteen exceeds the product budget)\n";
        ok = false;
    }
    if (top.cfg_linebuf_bits != 159744) {
        std::cerr << "FAIL true480 shared M10K_bits got=" << top.cfg_linebuf_bits
                  << " required=159744\n";
        ok = false;
    }
    if (top.cfg_m10k_estimate > 96 || top.cfg_m10k_estimate != 96) {
        std::cerr << "FAIL true480 shared M10K_budget estimate="
                  << top.cfg_m10k_estimate << " required=96 maximum=96\n";
        ok = false;
    }
    return ok ? 0 : 1;
}

int runProof(bool idealModel, bool resourceOnly, bool requireActiveConfig) {
    ModelConfig cfg;
    if (idealModel) {
        cfg.ideal = true;
        cfg.baseLatency = 0;
        cfg.latencyJitter = 0;
        cfg.refreshPeriod = 0;
        cfg.refreshCycles = 0;
        cfg.beatGapPeriod = 0;
        cfg.beatGapCycles = 0;
    }
    Sim sim(cfg);
    sim.top.eval();
    const bool activeConfig = sim.top.cfg_active_config;
    const bool nativeBeam = sim.top.cfg_native_beam_source;
    const int fillStride = sim.top.cfg_y_fill_stride;
    std::cout << "TRUE480_SHARED_BUILD_CONFIG active_define=" << activeConfig
              << " native_beam_source=" << nativeBeam
              << " y_fill_stride=" << fillStride
              << " required=" << requireActiveConfig << "\n";
    if (requireActiveConfig &&
        (!activeConfig || !nativeBeam || fillStride != 1)) {
        std::cerr << "FAIL true480 shared active configuration disappeared: "
                     "define/native beam/fill stride contract is not active\n";
        return 1;
    }
    const int resourceRc = checkResourceContract(sim.top);
    if (resourceOnly)
        return resourceRc;
    if (resourceRc != 0)
        return resourceRc;
    if (idealModel) {
        std::cerr << "FAIL true480 shared idealized_DDR_refused latency=0 "
                     "refresh_stalls=0 burst_gaps=0\n";
        return 1;
    }

    const auto frame = true480::makeIdleI420();
    sim.ddr.loadBank(0, frame);
    sim.ddr.loadBank(1, frame);
    sim.ddr.seedM1Ring();
    sim.reset();
    // Let the frame store observe the reset/empty doorbell first. Its strict
    // sequence protocol intentionally primes before accepting a new token.
    sim.runSysCycles(5000);
    if (!sim.presentFrame()) {
        const auto& s = sim.ddr.getStats();
        std::cerr << "FAIL true480 shared frame did not swap within five native frames"
                  << " doorbell_ok=" << static_cast<int>(sim.top.doorbell_ok)
                  << " frames_done=" << sim.top.frames_done
                  << " underrun=" << sim.top.underrun_count
                  << " commands=" << s.commands
                  << " m0_reads=" << s.m0Reads
                  << " m1_reads=" << s.m1Reads
                  << " m0_beats=" << s.m0Beats
                  << " m1_beats=" << s.m1Beats
                  << " writes=" << s.writes
                  << " store_state=" << static_cast<int>(sim.top.store_debug_state)
                  << " m0_rd=" << static_cast<int>(sim.top.store_m0_rd)
                  << " m0_we=" << static_cast<int>(sim.top.store_m0_we)
                  << " m0_busy=" << static_cast<int>(sim.top.store_m0_busy)
                  << " m1_state=" << static_cast<int>(sim.top.test_m1_state)
                  << " m1_want=" << static_cast<int>(sim.top.test_m1_want)
                  << " m1_busy=" << static_cast<int>(sim.top.test_m1_busy)
                  << " m1_rd=" << static_cast<int>(sim.top.test_m1_rd)
                  << " m1_we=" << static_cast<int>(sim.top.test_m1_we)
                  << " m1_issued=" << sim.top.m1_reads_issued
                  << " m1_seen=" << sim.top.m1_responses_seen
                  << " doorbell_reads=" << s.doorbellReads
                  << " doorbell_beats=" << s.doorbellMagicBeats
                  << " last_doorbell_data=0x" << std::hex
                  << s.lastDoorbellData
                  << " programmed_doorbell=0x" << s.programmedDoorbellData
                  << " doorbell_writes=" << std::dec << s.doorbellWrites
                  << " last_read_byte=0x" << std::hex
                  << s.lastReadByteAddress << std::dec
                  << " protocol_errors=" << s.protocolErrors << "\n";
        return 1;
    }
    for (int i = 0; i < 3; ++i)
        sim.captureFrame();
    const FrameMetrics m = sim.captureFrame();
    sim.stopM1AndDrain();

    const uint64_t expectedActive =
        static_cast<uint64_t>(true480::kOutW) * true480::kOutH;
    const uint64_t expectedVisible =
        static_cast<uint64_t>(true480::kDisplayW) * true480::kOutH;
    const uint64_t m0Beats = m.ddrAfter.m0Beats - m.ddrBefore.m0Beats;
    const uint64_t m1Beats = m.ddrAfter.m1Beats - m.ddrBefore.m1Beats;
    const uint64_t refreshCycles =
        m.ddrAfter.refreshStallCycles - m.ddrBefore.refreshStallCycles;
    const uint64_t gapCycles =
        m.ddrAfter.burstGapCycles - m.ddrBefore.burstGapCycles;
    const uint32_t m1Reads = m.m1ReadsAfter - m.m1ReadsBefore;
    const uint32_t m1Responses =
        m.m1ResponsesAfter - m.m1ResponsesBefore;
    const uint32_t m1WantCycles = m.m1WantAfter - m.m1WantBefore;

    bool ok = true;
    auto fail = [&ok](const std::string& what) {
        std::cerr << "FAIL true480 shared " << what << "\n";
        ok = false;
    };
    if (m.active != expectedActive)
        fail("active_pixels got=" + std::to_string(m.active) +
             " expected=" + std::to_string(expectedActive));
    if (m.visible + 8 < expectedVisible || m.visible > expectedVisible + 8)
        fail("visible_pixels got=" + std::to_string(m.visible) +
             " expected=" + std::to_string(expectedVisible));
    if (m.geometryErrors || m.sourceErrors || m.rows.size() != 480 ||
        m.visibleXs.size() != 618)
        fail("geometry crop=11+618+11 rows=" +
             std::to_string(m.rows.size()) + " visible_x=" +
             std::to_string(m.visibleXs.size()) + " geom_errors=" +
             std::to_string(m.geometryErrors) + " source_errors=" +
             std::to_string(m.sourceErrors));
    if (m.yHits < expectedVisible * 999 / 1000 ||
        m.cHits < expectedVisible * 999 / 1000)
        fail("sustained_hits Y=" + std::to_string(m.yHits) +
             " C=" + std::to_string(m.cHits) +
             " visible=" + std::to_string(m.visible));
    if (m.softC != 0)
        fail("settled_visible_soft_c_fallback count=" +
             std::to_string(m.softC));
    if (m.misses != 0)
        fail("settled_visible_miss count=" + std::to_string(m.misses));
    if (m.underrunAfter != m.underrunBefore ||
        m.underrunAfter == UINT16_MAX)
        fail("steady_underrun before=" +
             std::to_string(m.underrunBefore) + " after=" +
             std::to_string(m.underrunAfter));
    if (m.orange < 5000 || m.dark < 200000 || m.black > 16)
        fail("orange_on_dark orange=" + std::to_string(m.orange) +
             " dark=" + std::to_string(m.dark) +
             " black=" + std::to_string(m.black));
    if (m1Reads < 10000 || m1Responses + 1 < m1Reads ||
        m1Beats < 10000 || m1WantCycles < 10000)
        fail("m1_stream_service reads=" + std::to_string(m1Reads) +
             " responses=" + std::to_string(m1Responses) +
             " physical_beats=" + std::to_string(m1Beats) +
             " want_cycles=" + std::to_string(m1WantCycles));
    if (sim.top.m1_reads_issued != sim.top.m1_responses_seen ||
        sim.top.m1_protocol_errors != 0)
        fail("m1_beat_conservation issued=" +
             std::to_string(sim.top.m1_reads_issued) + " seen=" +
             std::to_string(sim.top.m1_responses_seen) + " errors=" +
             std::to_string(sim.top.m1_protocol_errors));
    if (m0Beats < 50000 || m0Beats > 70000 ||
        m0Beats + m1Beats > 100000 || m.ddrAfter.maxBurst < 39)
        fail("m0_burst_traffic beats=" + std::to_string(m0Beats) +
             " shared_beats=" + std::to_string(m0Beats + m1Beats) +
             " max_burst=" + std::to_string(m.ddrAfter.maxBurst));
    if (refreshCycles < 1000 || gapCycles < 1000)
        fail("nonideal_stalls refresh_cycles=" +
             std::to_string(refreshCycles) +
             " burst_gap_cycles=" + std::to_string(gapCycles));
    if (m.ddrAfter.protocolErrors != 0)
        fail("DDR_protocol_errors=" +
             std::to_string(m.ddrAfter.protocolErrors));
    if (m.ddrAfter.minObservedLatency < 25 ||
        m.ddrAfter.maxObservedLatency < 60)
        fail("DDR_latency_range min=" +
             std::to_string(m.ddrAfter.minObservedLatency) + " max=" +
             std::to_string(m.ddrAfter.maxObservedLatency));
    if (sim.ddr.getStats().m1Reads != sim.ddr.getStats().m1Beats)
        fail("physical_m1_conservation reads=" +
             std::to_string(sim.ddr.getStats().m1Reads) + " beats=" +
             std::to_string(sim.ddr.getStats().m1Beats));
    if (sim.ddr.getStats().m0ExpectedBeats != sim.ddr.getStats().m0Beats ||
        sim.ddr.getStats().m1ExpectedBeats != sim.ddr.getStats().m1Beats)
        fail("physical_burst_conservation m0_expected=" +
             std::to_string(sim.ddr.getStats().m0ExpectedBeats) +
             " m0_seen=" + std::to_string(sim.ddr.getStats().m0Beats) +
             " m1_expected=" +
             std::to_string(sim.ddr.getStats().m1ExpectedBeats) +
             " m1_seen=" + std::to_string(sim.ddr.getStats().m1Beats));

    std::cout
        << "TRUE480_SHARED_DDR line_count="
        << static_cast<int>(sim.top.cfg_line_count)
        << " linebuf_bits=" << sim.top.cfg_linebuf_bits
        << " m10k_estimate=" << sim.top.cfg_m10k_estimate
        << " active=" << m.active << " visible=" << m.visible
        << " unique_rows=" << m.rows.size()
        << " y_hits=" << m.yHits << " c_hits=" << m.cHits
        << " soft_c=" << m.softC
        << " underrun_delta=" << (m.underrunAfter - m.underrunBefore)
        << " orange=" << m.orange << " dark=" << m.dark
        << " m0_beats=" << m0Beats << " m1_reads=" << m1Reads
        << " m1_responses=" << m1Responses << " m1_beats=" << m1Beats
        << " m1_want_cycles=" << m1WantCycles
        << " refresh_stall_cycles=" << refreshCycles
        << " burst_gap_cycles=" << gapCycles
        << " latency_min=" << m.ddrAfter.minObservedLatency
        << " latency_max=" << m.ddrAfter.maxObservedLatency
        << "\n";
    if (ok)
        std::cout << "PASS true480 shared real_arbiter stride1_480 "
                     "periodic_STREAM nonideal_DDR no_steady_underrun\n";
    return ok ? 0 : 1;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    bool ideal = false;
    bool resourceOnly = false;
    bool requireActiveConfig = false;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--ideal-ddr")
            ideal = true;
        else if (arg == "--resource-only")
            resourceOnly = true;
        else if (arg == "--require-active-config")
            requireActiveConfig = true;
        else {
            std::cerr << "unknown argument: " << arg << "\n";
            return 2;
        }
    }
    try {
        return runProof(ideal, resourceOnly, requireActiveConfig);
    } catch (const std::exception& e) {
        std::cerr << "FAIL true480 shared exception: " << e.what() << "\n";
        return 1;
    }
}
