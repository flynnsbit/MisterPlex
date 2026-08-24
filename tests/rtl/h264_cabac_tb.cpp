#include "Vh264_cabac_tb.h"
#include "verilated.h"
#include "h264_cabac_init_tables.h"

#include <array>
#include <cstdint>
#include <iostream>
#include <vector>

namespace {

constexpr int kCtxN = 460;
constexpr int kBins = 48;
constexpr int kQp = 26;

struct Ctx {
    uint8_t mps = 0;
    uint8_t pstate = 0;
};

uint8_t rangeLps(int s, int q) {
    static const uint8_t t[64][4] = {
        {128,176,208,240},{128,167,197,227},{128,158,187,216},{123,150,178,205},
        {116,142,169,195},{111,135,160,185},{105,128,152,175},{100,122,144,166},
        {95,116,137,158},{90,110,130,150},{85,104,123,142},{81,99,117,135},
        {77,94,111,128},{73,89,105,122},{69,85,100,116},{66,80,95,110},
        {62,76,90,104},{59,72,86,99},{56,69,81,94},{53,65,77,89},
        {51,62,73,85},{48,59,69,80},{46,56,66,76},{43,53,63,72},
        {41,50,59,69},{39,48,56,65},{37,45,54,62},{35,43,51,59},
        {33,41,48,56},{32,39,46,53},{30,37,43,50},{29,35,41,48},
        {27,33,39,45},{26,31,37,43},{24,30,35,41},{23,28,33,39},
        {22,27,32,37},{21,26,30,35},{20,24,29,33},{19,23,27,31},
        {18,22,26,30},{17,21,25,28},{16,20,23,27},{15,19,22,25},
        {14,18,21,24},{14,17,20,23},{13,16,19,22},{12,15,18,21},
        {12,14,17,20},{11,14,16,19},{11,13,15,18},{10,12,15,17},
        {10,12,14,16},{9,11,13,15},{9,11,12,14},{8,10,12,14},
        {8,9,11,13},{7,9,11,12},{7,9,10,12},{7,8,10,11},
        {6,8,9,11},{6,7,9,10},{6,7,8,9},{2,2,2,2}};
    return t[s][q];
}

int transMps(int s) { return s >= 62 ? s : s + 1; }
int transLps(int s) {
    static const int t[64] = {
        0,0,1,2,2,4,4,5,6,7,8,9,9,11,11,12,13,13,15,15,16,16,18,18,19,19,21,21,22,22,23,24,
        24,25,26,26,27,27,28,29,29,30,30,30,31,32,32,33,33,33,34,34,35,35,35,36,36,36,37,37,
        37,38,38,63};
    return t[s];
}

int8_t initM(int ctx, int stype, int iidc) {
    return h264_cabac_init::m(ctx, stype, iidc);
}
int8_t initN(int ctx, int stype, int iidc) {
    return h264_cabac_init::n(ctx, stype, iidc);
}

Ctx initCtx(int ctx, int qp, int stype, int iidc, bool badInit) {
    int pre = (static_cast<int>(initM(ctx, stype, iidc)) * qp) >> 4;
    pre += initN(ctx, stype, iidc);
    if (pre < 1) pre = 1;
    if (pre > 126) pre = 126;
    Ctx c;
    if (pre <= 63) {
        c.pstate = static_cast<uint8_t>(63 - pre);
        c.mps = 0;
    } else {
        c.pstate = static_cast<uint8_t>(pre - 64);
        c.mps = 1;
    }
    if (badInit) c.mps = static_cast<uint8_t>(c.mps ^ 1);
    return c;
}

struct Soft {
    int range = 510;
    int offset = 0;
    std::vector<int> bits;
    std::size_t bpos = 0;
    std::array<Ctx, kCtxN> ctx{};
    bool skipRenorm = false;

    int takeBit() {
        if (bpos >= bits.size()) return 0;
        return bits[bpos++];
    }
    void prime() {
        offset = 0;
        for (int i = 0; i < 9; ++i) offset = (offset << 1) | takeBit();
    }
    int decode(int ctxIdx, bool bypass, bool terminate) {
        int bin = 0;
        if (terminate) {
            const int mpsR = range - 2;
            int rAfter = range;
            int offAfter = offset;
            if (offset >= mpsR) {
                bin = 1;
                offAfter = offset - mpsR;
                rAfter = 2;
            } else {
                bin = 0;
                rAfter = mpsR;
            }
            int s = 0;
            int r = rAfter;
            if (!skipRenorm) {
                while (r < 256 && s < 8) {
                    r <<= 1;
                    ++s;
                }
            }
            int off = offAfter << s;
            for (int i = 0; i < s; ++i) off |= takeBit() << (s - 1 - i);
            range = r;
            offset = off;
            return bin;
        }
        if (bypass) {
            // 9.3.3.2.3: shift 1 bit first, then compare against range.
            const int off = (offset << 1) | takeBit();
            if (off >= range) {
                bin = 1;
                offset = off - range;
            } else {
                bin = 0;
                offset = off;
            }
            return bin;
        }
        Ctx& c = ctx.at(static_cast<std::size_t>(ctxIdx));
        const int rlps = rangeLps(c.pstate, (range >> 6) & 3);
        const int rmps = range - rlps;
        int rAfter = range;
        int offAfter = offset;
        if (offset >= rmps) {
            bin = c.mps ^ 1;
            offAfter = offset - rmps;
            rAfter = rlps;
            if (c.pstate == 0) c.mps ^= 1;
            c.pstate = static_cast<uint8_t>(transLps(c.pstate));
        } else {
            bin = c.mps;
            rAfter = rmps;
            c.pstate = static_cast<uint8_t>(transMps(c.pstate));
        }
        int s = 0;
        int r = rAfter;
        if (!skipRenorm) {
            while (r < 256 && s < 8) {
                r <<= 1;
                ++s;
            }
        }
        int off = offAfter << s;
        for (int i = 0; i < s; ++i) off |= takeBit() << (s - 1 - i);
        range = r;
        offset = off;
        return bin;
    }
};

class Sim {
public:
    Vh264_cabac_tb top{};
    uint64_t cycles = 0;
    void tick() {
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
        top.clk = 0;
        top.eval();
        ++cycles;
    }
};

void reset(Sim& s) {
    s.top.reset = 1;
    s.top.slice_start = 0;
    s.top.bit_valid = 0;
    s.top.dec_req = 0;
    s.top.bypass = 0;
    s.top.terminate = 0;
    s.top.ctx_idx = 0;
    s.top.slice_type = 0;
    s.top.cabac_init_idc = 0;
    s.top.slice_qp_y = kQp;
    for (int i = 0; i < 4; ++i) s.tick();
    s.top.reset = 0;
    s.tick();
}

#ifdef H264_CABAC_FAULT_SKIP_RENORM
const char* kMismatchTag = "skip-renorm";
#elif defined(H264_CABAC_FAULT_BAD_INIT)
const char* kMismatchTag = "bad-init";
#else
const char* kMismatchTag = "bin";
#endif

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Sim s;
    reset(s);

    s.top.slice_type = 0;
    s.top.cabac_init_idc = 0;
    s.top.slice_qp_y = kQp;
    s.top.slice_start = 1;
    s.tick();
    s.top.slice_start = 0;
    int waitInit = 0;
    while (!s.top.init_done && waitInit < 1024) {
        s.tick();
        ++waitInit;
    }
    if (!s.top.init_done) {
        std::cerr << "FAIL h264_cabac: init_done never asserted cycles=" << s.cycles << "\n";
        return 1;
    }
    if (waitInit != kCtxN) {
        std::cerr << "FAIL h264_cabac: init cycles=" << waitInit << " want=" << kCtxN << "\n";
        return 1;
    }

    std::vector<int> bits;
    bits.reserve(1024);
    uint32_t lfsr = 0xBEEFu;
    for (int i = 0; i < 1024; ++i) {
        bits.push_back(static_cast<int>(lfsr & 1u));
        const uint32_t lsb = lfsr & 1u;
        lfsr >>= 1;
        if (lsb) lfsr ^= 0xACE1u;
    }

    std::size_t hwBit = 0;
    auto feedIfReady = [&]() {
        if (s.top.bit_ready && hwBit < bits.size()) {
            s.top.bit_valid = 1;
            s.top.bit_in = bits[hwBit] ? 1 : 0;
            ++hwBit;
        } else {
            s.top.bit_valid = 0;
            s.top.bit_in = 0;
        }
    };

    for (int i = 0; i < 24; ++i) {
        feedIfReady();
        s.tick();
    }

    Soft soft;
#ifdef H264_CABAC_FAULT_BAD_INIT
    const bool badInit = true;
#else
    const bool badInit = false;
#endif
    (void)badInit;
    // Golden software never takes the RTL fault macros.
    for (int i = 0; i < kCtxN; ++i)
        soft.ctx.at(static_cast<std::size_t>(i)) = initCtx(i, kQp, 0, 0, false);
    soft.bits = bits;
    soft.prime();

    std::vector<int> want;
    want.reserve(kBins);
    for (int i = 0; i < kBins; ++i) want.push_back(soft.decode(i % 16, i == 40, i == 47));
    int wantOnes = 0;
    for (int b : want) wantOnes += b;
    if (wantOnes < 2 || wantOnes > (kBins - 2)) {
        std::cerr << "FAIL h264_cabac: vacuous golden bins ones=" << wantOnes << " n=" << kBins << "\n";
        return 1;
    }

    std::vector<int> got;
    got.reserve(kBins);
    int gotN = 0;
    int consec = 0;
    int maxConsec = 0;
    uint64_t decodeTicks = 0;
    bool primedSeen = false;
    while (gotN < kBins && decodeTicks < 10000) {
        s.top.dec_req = 1;
        s.top.ctx_idx = static_cast<uint16_t>(gotN % 16);
        s.top.bypass = (gotN == 40) ? 1 : 0;
        s.top.terminate = (gotN == 47) ? 1 : 0;
        feedIfReady();
        s.tick();
        ++decodeTicks;
        if (s.top.dec_valid) {
            primedSeen = true;
            got.push_back(static_cast<int>(s.top.dec_bin));
            ++gotN;
            ++consec;
            if (consec > maxConsec) maxConsec = consec;
        } else {
            if (primedSeen && static_cast<int>(s.top.dbg_fifo_count) >= 8) {
                std::cerr << "FAIL h264_cabac: not 1 bin/cycle at bin " << gotN
                          << " fifo=" << int(s.top.dbg_fifo_count)
                          << " stall=" << int(s.top.dec_stall) << "\n";
                return 1;
            }
            consec = 0;
        }
    }
    s.top.dec_req = 0;
    s.top.bit_valid = 0;

    if (static_cast<int>(got.size()) != kBins) {
        std::cerr << "FAIL h264_cabac: decoded " << got.size() << " bins want=" << kBins
                  << " stall=" << int(s.top.dec_stall) << " fifo=" << int(s.top.dbg_fifo_count) << "\n";
        return 1;
    }
    for (int i = 0; i < kBins; ++i) {
        if (got.at(static_cast<std::size_t>(i)) != want.at(static_cast<std::size_t>(i))) {
            std::cerr << "FAIL h264_cabac " << kMismatchTag << " mismatch at " << i
                      << " got=" << got.at(static_cast<std::size_t>(i))
                      << " want=" << want.at(static_cast<std::size_t>(i))
                      << " range=" << int(s.top.dbg_range) << " offset=" << int(s.top.dbg_offset) << "\n";
            return 1;
        }
    }
    if (maxConsec < 8) {
        std::cerr << "FAIL h264_cabac: never held 8 consecutive 1-bin/cycle bins maxConsec="
                  << maxConsec << " decode_ticks=" << decodeTicks << "\n";
        return 1;
    }
    const double cycPerBin = static_cast<double>(decodeTicks) / kBins;
    const double mbin = 20.0 / cycPerBin;
    std::cout << "OK h264_cabac: " << kBins << " bins (regular+bypass+terminate) matched software model; "
              << "init_cycles=" << waitInit << " decode_ticks=" << decodeTicks
              << " max_consec_1bin=" << maxConsec << " cyc/bin=" << cycPerBin
              << " implied_Mbin_s_at_20MHz=" << mbin
              << " vs_planning_8.775 (1 bin/cycle when fifo>=8; NOT a product CABAC syntax PASS)\n";
    return 0;
}
