#include "Vh264_cabac_residual_tb.h"
#include "verilated.h"
#include "h264_cabac_init_tables.h"

#include <array>
#include <cstdint>
#include <iostream>
#include <vector>

namespace {

constexpr int kCtxN = 460;
constexpr int kQp = 26;
constexpr int kMaxCoeff = 16;

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

Ctx initCtx(int ctx, int qp, int stype, int iidc) {
    int pre = (static_cast<int>(h264_cabac_init::m(ctx, stype, iidc)) * qp) >> 4;
    pre += h264_cabac_init::n(ctx, stype, iidc);
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
    return c;
}

struct Soft {
    int range = 510;
    int offset = 0;
    std::vector<int> bits;
    std::size_t bpos = 0;
    std::array<Ctx, kCtxN> ctx{};

    int takeBit() {
        if (bpos >= bits.size()) return 0;
        return bits[bpos++];
    }
    void prime() {
        offset = 0;
        for (int i = 0; i < 9; ++i) offset = (offset << 1) | takeBit();
    }
    int decode(int ctxIdx, bool bypass) {
        if (bypass) {
            const int off = (offset << 1) | takeBit();
            if (off >= range) {
                offset = off - range;
                return 1;
            }
            offset = off;
            return 0;
        }
        Ctx& c = ctx.at(static_cast<std::size_t>(ctxIdx));
        const int rlps = rangeLps(c.pstate, (range >> 6) & 3);
        const int rmps = range - rlps;
        int rAfter = range;
        int offAfter = offset;
        int bin = 0;
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
        while (r < 256 && s < 8) {
            r <<= 1;
            ++s;
        }
        int off = offAfter << s;
        for (int i = 0; i < s; ++i) off |= takeBit() << (s - 1 - i);
        range = r;
        offset = off;
        return bin;
    }
};

int cbfBase(int cat) {
    static const int t[] = {85, 89, 93, 97, 101};
    return t[cat];
}
int sigBase(int cat) {
    static const int t[] = {105, 120, 134, 149, 152};
    return t[cat];
}
int lastBase(int cat) {
    static const int t[] = {166, 181, 191, 206, 209};
    return t[cat];
}
int absBase(int cat) {
    static const int t[] = {227, 237, 247, 257, 266};
    return t[cat];
}
int lvl1Ctx(int n) {
    static const int t[] = {1, 2, 3, 4, 0, 0, 0, 0};
    return t[n & 7];
}
int gt1Ctx(int n) {
    static const int t[] = {5, 5, 5, 5, 6, 7, 8, 9};
    return t[n & 7];
}
int trans0(int n) {
    static const int t[] = {1, 2, 3, 3, 4, 5, 6, 7};
    return t[n & 7];
}
int trans1(int n) {
    static const int t[] = {4, 4, 4, 4, 5, 6, 7, 7};
    return t[n & 7];
}

struct Residual {
    std::array<int, 16> coeff{};
    int total = 0;
};

Residual decodeResidual(Soft& s, int cat, int nA, int nB, int maxCoeff, bool forceCbf0) {
    Residual out{};
    const int cbf = s.decode(cbfBase(cat) + nA + 2 * nB, false);
    if (forceCbf0 || cbf == 0) return out;
    std::array<int, 16> sig{};
    int last = maxCoeff - 1;
    for (int i = 0; i < maxCoeff - 1; ++i) {
        if (s.decode(sigBase(cat) + i, false)) {
            sig[static_cast<std::size_t>(i)] = 1;
            if (s.decode(lastBase(cat) + i, false)) {
                last = i;
                break;
            }
        }
        if (i == maxCoeff - 2) {
            sig[static_cast<std::size_t>(maxCoeff - 1)] = 1;
            last = maxCoeff - 1;
        }
    }
    if (maxCoeff <= 1) {
        sig[0] = 1;
        last = 0;
    }
    int node = 0;
    for (int i = last; i >= 0; --i) {
        if (!sig[static_cast<std::size_t>(i)]) continue;
        int absv = 1;
        if (s.decode(absBase(cat) + lvl1Ctx(node), false) == 0) {
            node = trans0(node);
        } else {
            node = trans1(node);
            absv = 2;
            while (absv < 15 && s.decode(absBase(cat) + gt1Ctx(node), false))
                ++absv;
            if (absv >= 15) {
                int j = 0;
                while (s.decode(0, true) && j < 23) ++j;
                absv = 1;
                while (j-- > 0) absv = (absv << 1) | s.decode(0, true);
                absv += 14;
            }
        }
        const int sign = s.decode(0, true);
        out.coeff[static_cast<std::size_t>(i)] = sign ? -absv : absv;
        ++out.total;
    }
    return out;
}

class Sim {
public:
    Vh264_cabac_residual_tb top{};
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
    s.top.res_start = 0;
    s.top.slice_type = 0;
    s.top.cabac_init_idc = 0;
    s.top.slice_qp_y = kQp;
    s.top.cat = 2;
    s.top.cbf_nA = 0;
    s.top.cbf_nB = 0;
    s.top.max_coeff = kMaxCoeff;
    for (int i = 0; i < 4; ++i) s.tick();
    s.top.reset = 0;
    s.tick();
}

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
        std::cerr << "FAIL h264_cabac_residual: init_done never asserted\n";
        return 1;
    }

    Residual want{};
    std::vector<int> bits;
    bool found = false;
    for (uint32_t seed = 0xBEEFu; seed < 0xBEEFu + 64u; ++seed) {
        bits.clear();
        uint32_t lfsr = seed;
        for (int i = 0; i < 2048; ++i) {
            bits.push_back(static_cast<int>(lfsr & 1u));
            const uint32_t lsb = lfsr & 1u;
            lfsr >>= 1;
            if (lsb) lfsr ^= 0xACE1u;
        }
        Soft soft;
        for (int i = 0; i < kCtxN; ++i)
            soft.ctx.at(static_cast<std::size_t>(i)) = initCtx(i, kQp, 0, 0);
        soft.bits = bits;
        soft.prime();
        want = decodeResidual(soft, 2, 0, 0, kMaxCoeff, false);
        if (want.total >= 1) {
            found = true;
            break;
        }
    }
    if (!found) {
        std::cerr << "FAIL h264_cabac_residual: no LFSR seed produced a coded 4x4\n";
        return 1;
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
    int waitPrime = 0;
    while (!s.top.primed && waitPrime < 64) {
        feedIfReady();
        s.tick();
        ++waitPrime;
    }
    if (!s.top.primed) {
        std::cerr << "FAIL h264_cabac_residual: never primed fifo=" << int(s.top.dbg_fifo_count) << "\n";
        return 1;
    }
    for (int i = 0; i < 16; ++i) {
        feedIfReady();
        s.tick();
    }

    s.top.res_start = 1;
    feedIfReady();
    s.tick();
    s.top.res_start = 0;

    int waitRes = 0;
    while (!s.top.res_done && waitRes < 4096) {
        feedIfReady();
        s.tick();
        ++waitRes;
    }
    s.top.bit_valid = 0;
    if (!s.top.res_done || !s.top.res_ok) {
        std::cerr << "FAIL h264_cabac_residual: done=" << int(s.top.res_done)
                  << " ok=" << int(s.top.res_ok) << " cycles=" << waitRes << "\n";
        return 1;
    }

#ifdef H264_CABAC_RES_FAULT_FORCE_CBF0
    if (static_cast<int>(s.top.total_coeff) == 0) {
        std::cerr << "FAIL h264_cabac_residual force-cbf0: residual stayed zero total=0 want_total="
                  << want.total << " coeff0_want=" << want.coeff[0] << "\n";
        return 1;
    }
    std::cerr << "FAIL h264_cabac_residual force-cbf0 unexpected non-zero total="
              << int(s.top.total_coeff) << "\n";
    return 1;
#else
    if (static_cast<int>(s.top.total_coeff) != want.total) {
        std::cerr << "FAIL h264_cabac_residual total_coeff got=" << int(s.top.total_coeff)
                  << " want=" << want.total << "\n";
        return 1;
    }
    for (int i = 0; i < 16; ++i) {
        const int got = static_cast<int>(s.top.coeff[i]);
        if (got != want.coeff[static_cast<std::size_t>(i)]) {
            std::cerr << "FAIL h264_cabac_residual coeff mismatch at scan " << i
                      << " got=" << got << " want=" << want.coeff[static_cast<std::size_t>(i)]
                      << " total=" << want.total << "\n";
            return 1;
        }
    }
    if (s.top.dec_req != 0 && s.top.res_done) {
        // idle after done is allowed to drop req
    }
    std::cout << "OK h264_cabac_residual: cat=2 luma 4x4 residual_block_cabac matched software; "
              << "total_coeff=" << want.total << " decode_cycles=" << waitRes
              << " (NOT a product High-profile slice PASS)\n";
    return 0;
#endif
}
