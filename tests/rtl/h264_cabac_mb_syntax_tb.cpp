#include "Vh264_cabac_mb_syntax_tb.h"
#include "verilated.h"
#include "h264_cabac_init_tables.h"

#include <array>
#include <cstdint>
#include <iostream>
#include <vector>

namespace {

constexpr int kCtxN = 460;
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

struct Syntax {
    int skip = 0;
    int mb_type = 0;
    int cbp_luma = 0;
    int cbp_chroma = 0;
    int qp_delta = 0;
    int mvd_x = 0;
    int mvd_y = 0;
};

int dqpMap(int n) {
    const int mag = (n + 1) >> 1;
    return (n & 1) ? mag : -mag;
}

int decodeMvd(Soft& s, int base) {
    if (s.decode(base, false) == 0) return 0;
    int absv = 1;
    if (s.decode(base + 1, false) == 0) {
        // abs=1
    } else {
        absv = 2;
        while (true) {
            const int b = s.decode(base + 2, false);
            if (b == 0) break;
            if (absv >= 7) {
                ++absv;
                break;
            }
            ++absv;
        }
    }
    const int sign = s.decode(0, true);
    return sign ? -absv : absv;
}

Syntax decodeSyntax(Soft& s, int nA, int nB, bool forceSkip) {
    Syntax out{};
    const int skip = s.decode(11 + nA + nB, false);
    if (forceSkip || skip) {
        out.skip = 1;
        return out;
    }
    if (s.decode(14, false) == 0)
        out.mb_type = 0;
    else if (s.decode(15, false))
        out.mb_type = 3;
    else
        out.mb_type = s.decode(16, false) ? 2 : 1;
    int cbp = 0;
    for (int i = 0; i < 4; ++i)
        if (s.decode(73 + i, false)) cbp |= (1 << i);
    out.cbp_luma = cbp;
    if (s.decode(77, false) == 0)
        out.cbp_chroma = 0;
    else
        out.cbp_chroma = s.decode(78, false) ? 2 : 1;
    if (out.cbp_chroma != 0 || out.cbp_luma != 0) {
        if (s.decode(60, false) == 0)
            out.qp_delta = 0;
        else {
            int n = 1;
            while (n < 31) {
                const int ctx = (n <= 1) ? 61 : 62;
                if (s.decode(ctx, false) == 0) break;
                ++n;
            }
            out.qp_delta = dqpMap(n);
        }
    }
    out.mvd_x = decodeMvd(s, 40);
    out.mvd_y = decodeMvd(s, 47);
    return out;
}

class Sim {
public:
    Vh264_cabac_mb_syntax_tb top{};
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
    s.top.syn_start = 0;
    s.top.slice_type = 1;
    s.top.cabac_init_idc = 0;
    s.top.slice_qp_y = kQp;
    s.top.nA_coded = 0;
    s.top.nB_coded = 0;
    for (int i = 0; i < 4; ++i) s.tick();
    s.top.reset = 0;
    s.tick();
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Sim s;
    reset(s);

    s.top.slice_type = 1;
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
        std::cerr << "FAIL h264_cabac_mb_syntax: init_done never asserted\n";
        return 1;
    }

    Syntax want{};
    std::vector<int> bits;
    bool found = false;
    for (uint32_t seed = 0xACE1u; seed < 0xACE1u + 128u; ++seed) {
        bits.clear();
        uint32_t lfsr = seed;
        for (int i = 0; i < 2048; ++i) {
            bits.push_back(static_cast<int>(lfsr & 1u));
            const uint32_t lsb = lfsr & 1u;
            lfsr >>= 1;
            if (lsb) lfsr ^= 0xBEEFu;
        }
        Soft soft;
        for (int i = 0; i < kCtxN; ++i)
            soft.ctx.at(static_cast<std::size_t>(i)) = initCtx(i, kQp, 1, 0);
        soft.bits = bits;
        soft.prime();
        want = decodeSyntax(soft, 0, 0, false);
        if (!want.skip) {
            found = true;
            break;
        }
    }
    if (!found) {
        std::cerr << "FAIL h264_cabac_mb_syntax: no LFSR seed produced a non-skip P MB\n";
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
        std::cerr << "FAIL h264_cabac_mb_syntax: never primed\n";
        return 1;
    }
    for (int i = 0; i < 16; ++i) {
        feedIfReady();
        s.tick();
    }

    s.top.syn_start = 1;
    feedIfReady();
    s.tick();
    s.top.syn_start = 0;

    int waitSyn = 0;
    while (!s.top.syn_done && waitSyn < 4096) {
        feedIfReady();
        s.tick();
        ++waitSyn;
    }
    s.top.bit_valid = 0;
    if (!s.top.syn_done || !s.top.syn_ok) {
        std::cerr << "FAIL h264_cabac_mb_syntax: done=" << int(s.top.syn_done)
                  << " ok=" << int(s.top.syn_ok) << " cycles=" << waitSyn << "\n";
        return 1;
    }

#ifdef H264_CABAC_SYN_FAULT_FORCE_SKIP
    if (s.top.mb_skip) {
        std::cerr << "FAIL h264_cabac_mb_syntax force-skip: mb stayed skip "
                  << "want_skip=0 type_want=" << want.mb_type
                  << " cbp_l_want=" << want.cbp_luma << "\n";
        return 1;
    }
    std::cerr << "FAIL h264_cabac_mb_syntax force-skip unexpected non-skip type="
              << int(s.top.mb_type) << "\n";
    return 1;
#else
    auto sx6 = [](int v) {
        v &= 63;
        if (v & 32) v -= 64;
        return v;
    };
    const int got_dqp = sx6(static_cast<int>(s.top.qp_delta));
    const int got_mx = static_cast<int16_t>(s.top.mvd_x);
    const int got_my = static_cast<int16_t>(s.top.mvd_y);
    if (int(s.top.mb_skip) != want.skip || int(s.top.mb_type) != want.mb_type ||
        int(s.top.cbp_luma) != want.cbp_luma || int(s.top.cbp_chroma) != want.cbp_chroma ||
        got_dqp != want.qp_delta || got_mx != want.mvd_x || got_my != want.mvd_y) {
        std::cerr << "FAIL h264_cabac_mb_syntax mismatch skip/type/cbp/dqp/mvd "
                  << "got skip=" << int(s.top.mb_skip) << " type=" << int(s.top.mb_type)
                  << " cbp_l=" << int(s.top.cbp_luma) << " cbp_c=" << int(s.top.cbp_chroma)
                  << " dqp=" << got_dqp << " mv=(" << got_mx << ","
                  << got_my << ") want skip=" << want.skip << " type=" << want.mb_type
                  << " cbp_l=" << want.cbp_luma << " cbp_c=" << want.cbp_chroma
                  << " dqp=" << want.qp_delta << " mv=(" << want.mvd_x << "," << want.mvd_y
                  << ")\n";
        return 1;
    }
    std::cout << "OK h264_cabac_mb_syntax: P-slice skip/mb_type/CBP/dqp/mvd matched software; "
              << "skip=0 type=" << want.mb_type << " cbp_l=" << want.cbp_luma
              << " cbp_c=" << want.cbp_chroma << " dqp=" << want.qp_delta
              << " mvd=(" << want.mvd_x << "," << want.mvd_y << ") cycles=" << waitSyn
              << " (NOT a product High-profile slice PASS)\n";
    return 0;
#endif
}
