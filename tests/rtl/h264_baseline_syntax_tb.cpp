#include "Vh264_baseline_syntax_tb_top.h"
#include "libmisterplex/h264_nal.hpp"
#include "libmisterplex/h264_slice_walk.hpp"
#include "verilated.h"

#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr int MODE_PPS = 0;
constexpr int MODE_SLICE = 1;
constexpr int MODE_MB = 2;
constexpr int MODE_MB_LAYER = 3;
constexpr int PART_P_SKIP = 1;
constexpr int PART_P16X16 = 2;
constexpr int PART_P16X8 = 3;
constexpr int PART_P8X16 = 4;
constexpr int PART_P8X8 = 5;
constexpr int PART_I_NXN = 6;
constexpr int PART_I16X16 = 7;

int failures = 0;

void expect(bool cond, const std::string& msg) {
    if (!cond) {
        std::cerr << msg << "\n";
        ++failures;
    }
}

void tick(Vh264_baseline_syntax_tb_top& dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
}

void reset(Vh264_baseline_syntax_tb_top& dut) {
    dut.reset = 1;
    dut.clear = 0;
    dut.in_valid = 0;
    dut.in_byte = 0;
    dut.in_last = 0;
    dut.mode = MODE_PPS;
    dut.start_bit = 0;
    dut.nal_unit_type = 0;
    dut.nal_ref_idc = 0;
    dut.log2_max_frame_num = 0;
    dut.log2_max_pic_order_cnt_lsb = 0;
    dut.poc_type_in = 2;
    dut.pps_pic_init_qp = 26;
    dut.pps_deblock_ctrl = 0;
    dut.active_slice_type = 2;
    dut.qp_in = 26;
    dut.num_ref_idx_l0_active_minus1 = 0;
    tick(dut);
    tick(dut);
    dut.reset = 0;
    tick(dut);
}

std::vector<uint8_t> readFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

struct Nal {
    uint8_t header = 0;
    std::vector<uint8_t> payload;
};

std::vector<Nal> splitAnnexB(const std::vector<uint8_t>& data) {
    std::vector<Nal> out;
    size_t i = 0;
    while (i + 3 < data.size()) {
        size_t sc = 0;
        if (i + 3 < data.size() && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1)
            sc = 4;
        else if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
            sc = 3;
        if (!sc) {
            ++i;
            continue;
        }
        size_t j = i + sc;
        while (j + 3 < data.size()) {
            if (data[j] == 0 && data[j + 1] == 0 &&
                (data[j + 2] == 1 || (j + 3 < data.size() && data[j + 2] == 0 && data[j + 3] == 1)))
                break;
            ++j;
        }
        if (j + 3 >= data.size())
            j = data.size();
        if (i + sc < j) {
            Nal n;
            n.header = data[i + sc];
            n.payload.assign(data.begin() + static_cast<std::ptrdiff_t>(i + sc + 1),
                             data.begin() + static_cast<std::ptrdiff_t>(j));
            out.push_back(std::move(n));
        }
        i = j;
    }
    return out;
}

bool containsEpb(const std::vector<uint8_t>& payload) {
    for (size_t i = 2; i < payload.size(); ++i)
        if (payload[i - 2] == 0 && payload[i - 1] == 0 && payload[i] == 3)
            return true;
    return false;
}

std::vector<uint8_t> rbspPayload(const std::vector<uint8_t>& payload) {
#ifdef FAULT_SKIP_EPB
    return payload;
#else
    return misterplex::detail::removeEpb(payload.data(), payload.size());
#endif
}

struct Bits {
    std::vector<int> b;
    void bit(int v) { b.push_back(v ? 1 : 0); }
    void ue(uint32_t v) {
        uint32_t code = v + 1;
        int leading = 0;
        for (uint32_t t = code; t > 1; t >>= 1)
            ++leading;
        for (int i = 0; i < leading; ++i)
            bit(0);
        for (int i = leading; i >= 0; --i)
            bit((code >> i) & 1u);
    }
    void se(int32_t v) {
        ue(v <= 0 ? static_cast<uint32_t>(-2 * v) : static_cast<uint32_t>(2 * v - 1));
    }
    std::vector<uint8_t> bytes() {
        bit(1);
        while (b.size() % 8)
            bit(0);
        std::vector<uint8_t> out(b.size() / 8, 0);
        for (size_t i = 0; i < b.size(); ++i)
            out[i / 8] |= static_cast<uint8_t>(b[i] << (7 - (i & 7)));
        return out;
    }
};

int cbpInterMap(uint32_t code) {
    static const uint8_t kMap[48] = {
        0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15,
        47, 7, 11, 13, 14, 6, 9, 31, 35, 37, 42, 44,
        33, 34, 36, 40, 39, 43, 45, 46, 17, 18, 20, 24,
        19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41};
    expect(code < 48, "host P CBP code out of range");
    return (code < 48) ? kMap[code] : 0;
}

bool feed(Vh264_baseline_syntax_tb_top& dut, const std::vector<uint8_t>& rbsp, int mode, int startBit = 0) {
    dut.clear = 1;
    tick(dut);
    dut.clear = 0;
    dut.mode = mode;
    dut.start_bit = startBit;
    size_t sent = 0;
    for (int guard = 0; guard < 500000 && !(dut.valid || dut.error); ++guard) {
        dut.in_valid = (sent < rbsp.size()) && !dut.busy;
        if (dut.in_valid) {
            dut.in_byte = rbsp[sent];
            dut.in_last = (sent + 1 == rbsp.size());
        }
        const bool accepted = dut.in_valid && dut.in_ready;
        tick(dut);
        if (accepted)
            ++sent;
    }
    dut.in_valid = 0;
    tick(dut);
    return dut.valid && !dut.error;
}

struct SliceDetail {
    uint32_t mbOffset = 0;
    int alpha = 0;
    int beta = 0;
};

SliceDetail parseSliceDetail(const std::vector<uint8_t>& rbsp, uint8_t nalType, uint8_t nalRefIdc,
                             uint8_t log2FrameNum, uint8_t pocType, const misterplex::PpsInfo& pps) {
    misterplex::detail::BitReader br(rbsp.data(), rbsp.size());
    br.ue();
    uint32_t sliceType = br.ue();
    br.ue();
    br.u(log2FrameNum);
    if (nalType == 5) {
        br.ue();
        br.u(1);
        br.u(1);
    } else if (pocType == 0) {
        br.ue();
    }
    if (sliceType == 0 || sliceType == 5) {
        if (br.u(1))
            br.ue();
        if (br.u(1)) {
            uint32_t idc = 0;
            do {
                idc = br.ue();
                if (idc <= 2)
                    br.ue();
            } while (idc != 3 && br.ok);
        }
    }
    if (nalType != 5 && nalRefIdc) {
        br.u(1);
    }
    br.se();
    SliceDetail d;
    if (pps.deblock_ctrl) {
        uint32_t idc = br.ue();
        if (idc != 1) {
            d.alpha = br.se();
            d.beta = br.se();
        }
    }
    d.mbOffset = static_cast<uint32_t>(br.bit);
    return d;
}

struct MbExpect {
    int start = 0;
    int mode = MODE_MB;
    int skipRun = 0;
    int residual = 0;
    int mbType = 0;
    int part = 0;
    int chroma = 0;
    int cbp = 0;
    int qpDelta = 0;
    int qp = 0;
};

std::vector<MbExpect> collectIHeaders(const std::vector<uint8_t>& rbsp, int mbW, int mbH, int startBit, int sliceQp) {
    using namespace misterplex;
    detail::BitReader br(rbsp.data(), rbsp.size());
    br.bit = static_cast<size_t>(startBit);
    std::vector<MbExpect> out;
    std::vector<int> tcLuma(static_cast<size_t>(mbW * mbH * 16), -1);
    std::vector<int> tcChr[2] = {std::vector<int>(static_cast<size_t>(mbW * mbH * 4), -1),
                                  std::vector<int>(static_cast<size_t>(mbW * mbH * 4), -1)};
    auto tcatL = [&](int mbx, int mby, int lx, int ly) -> int* {
        if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH || lx < 0 || ly < 0 || lx > 3 || ly > 3)
            return nullptr;
        int& v = tcLuma[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)];
        return (v < 0) ? nullptr : &v;
    };
    auto tcsetL = [&](int mbx, int mby, int lx, int ly, int v) {
        tcLuma[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] = v;
    };
    auto tcatC = [&](int plane, int mbx, int mby, int lx, int ly) -> int* {
        if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH || lx < 0 || ly < 0 || lx > 1 || ly > 1)
            return nullptr;
        int& v = tcChr[plane][static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)];
        return (v < 0) ? nullptr : &v;
    };
    auto tcsetC = [&](int plane, int mbx, int mby, int lx, int ly, int v) {
        tcChr[plane][static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)] = v;
    };
    auto parseChr = [&](int mbx, int mby, int cbpC) {
        if (cbpC) {
            expect(cavlc::residualBlock(br, -1, 4).ok, "host chroma DC Cb parse failed");
            expect(cavlc::residualBlock(br, -1, 4).ok, "host chroma DC Cr parse failed");
        }
        if (cbpC == 2) {
            for (int p = 0; p < 2; ++p) {
                for (int b = 0; b < 4; ++b) {
                    int lx, ly;
                    walk_detail::chrXY(b, lx, ly);
                    int* nA = (lx > 0) ? tcatC(p, mbx, mby, lx - 1, ly) : tcatC(p, mbx - 1, mby, 1, ly);
                    int* nB = (ly > 0) ? tcatC(p, mbx, mby, lx, ly - 1) : tcatC(p, mbx, mby - 1, lx, 1);
                    auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 15);
                    expect(r.ok, "host chroma AC parse failed");
                    tcsetC(p, mbx, mby, lx, ly, r.total_coeff);
                }
            }
        } else {
            for (int p = 0; p < 2; ++p)
                for (int b = 0; b < 4; ++b) {
                    int lx, ly;
                    walk_detail::chrXY(b, lx, ly);
                    tcsetC(p, mbx, mby, lx, ly, 0);
                }
        }
    };

    int qp = sliceQp;
    for (int mby = 0; mby < mbH; ++mby) {
        for (int mbx = 0; mbx < mbW; ++mbx) {
            MbExpect e;
            e.start = static_cast<int>(br.bit);
            uint32_t mt = br.ue();
            e.mbType = static_cast<int>(mt);
            e.part = (mt == 0) ? PART_I_NXN : PART_I16X16;
            if (mt == 0) {
                for (int k = 0; k < 16; ++k)
                    if (br.u(1) == 0)
                        br.u(3);
                e.chroma = static_cast<int>(br.ue());
                uint32_t code = br.ue();
                e.cbp = walk_detail::kMeIntra[code];
                if (e.cbp != 0) {
                    e.qpDelta = br.se();
                    qp += e.qpDelta;
                }
                e.qp = qp;
                e.residual = static_cast<int>(br.bit);
                int cbpL = e.cbp & 15;
                int cbpC = e.cbp >> 4;
                for (int i8 = 0; i8 < 4; ++i8) {
                    if ((cbpL >> i8) & 1) {
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly;
                            walk_detail::blkXY(i8, i4, lx, ly);
                            int* nA = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
                            int* nB = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
                            auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 16);
                            expect(r.ok, "host I4 residual parse failed");
                            tcsetL(mbx, mby, lx, ly, r.total_coeff);
                        }
                    } else {
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly;
                            walk_detail::blkXY(i8, i4, lx, ly);
                            tcsetL(mbx, mby, lx, ly, 0);
                        }
                    }
                }
                parseChr(mbx, mby, cbpC);
            } else {
                int x = static_cast<int>(mt) - 1;
                int cbpC = (x / 4) % 3;
                int cbpL = (x / 12) ? 15 : 0;
                e.cbp = cbpL | (cbpC << 4);
                e.chroma = static_cast<int>(br.ue());
                e.qpDelta = br.se();
                qp += e.qpDelta;
                e.qp = qp;
                e.residual = static_cast<int>(br.bit);
                auto rdc = cavlc::residualBlock(br, walk_detail::ncFrom(tcatL(mbx - 1, mby, 3, 0),
                                                                         tcatL(mbx, mby - 1, 0, 3)), 16);
                expect(rdc.ok, "host I16 DC residual parse failed");
                if (cbpL) {
                    for (int i8 = 0; i8 < 4; ++i8) {
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly;
                            walk_detail::blkXY(i8, i4, lx, ly);
                            auto r = cavlc::residualBlock(br, walk_detail::ncFrom(
                                                              (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly),
                                                              (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3)),
                                                          15);
                            expect(r.ok, "host I16 AC residual parse failed");
                            tcsetL(mbx, mby, lx, ly, r.total_coeff);
                        }
                    }
                } else {
                    for (int ly = 0; ly < 4; ++ly)
                        for (int lx = 0; lx < 4; ++lx)
                            tcsetL(mbx, mby, lx, ly, 0);
                }
                parseChr(mbx, mby, cbpC);
            }
            out.push_back(e);
        }
    }
    expect(br.ok, "host I-slice MB walk bitreader failed");
    return out;
}

struct PWalk {
    std::vector<MbExpect> syntax;
    int coveredMbs = 0;
    int skippedMbs = 0;
    int interMbs = 0;
    int intraMbs = 0;
    int p16x16 = 0;
    int p16x8 = 0;
    int p8x16 = 0;
    int p8x8 = 0;
};

void setMbCoeffZero(std::vector<int>& tcLuma, std::vector<int> (&tcChr)[2], int mbW, int mbx, int mby) {
    for (int ly = 0; ly < 4; ++ly)
        for (int lx = 0; lx < 4; ++lx)
            tcLuma[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] = 0;
    for (int p = 0; p < 2; ++p)
        for (int ly = 0; ly < 2; ++ly)
            for (int lx = 0; lx < 2; ++lx)
                tcChr[p][static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)] = 0;
}

PWalk collectPHeaders(const std::vector<uint8_t>& rbsp, int mbW, int mbH, int startBit, int sliceQp) {
    using namespace misterplex;
    detail::BitReader br(rbsp.data(), rbsp.size());
    br.bit = static_cast<size_t>(startBit);
    PWalk out;
    const int totalMbs = mbW * mbH;
    std::vector<int> tcLuma(static_cast<size_t>(totalMbs * 16), -1);
    std::vector<int> tcChr[2] = {std::vector<int>(static_cast<size_t>(totalMbs * 4), -1),
                                  std::vector<int>(static_cast<size_t>(totalMbs * 4), -1)};
    auto tcatL = [&](int mbx, int mby, int lx, int ly) -> int* {
        if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH || lx < 0 || ly < 0 || lx > 3 || ly > 3)
            return nullptr;
        int& v = tcLuma[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)];
        return (v < 0) ? nullptr : &v;
    };
    auto tcsetL = [&](int mbx, int mby, int lx, int ly, int v) {
        tcLuma[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] = v;
    };
    auto tcatC = [&](int plane, int mbx, int mby, int lx, int ly) -> int* {
        if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH || lx < 0 || ly < 0 || lx > 1 || ly > 1)
            return nullptr;
        int& v = tcChr[plane][static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)];
        return (v < 0) ? nullptr : &v;
    };
    auto tcsetC = [&](int plane, int mbx, int mby, int lx, int ly, int v) {
        tcChr[plane][static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)] = v;
    };
    auto parseChr = [&](int mbx, int mby, int cbpC) {
        if (cbpC) {
            expect(cavlc::residualBlock(br, -1, 4).ok, "host P chroma DC Cb parse failed");
            expect(cavlc::residualBlock(br, -1, 4).ok, "host P chroma DC Cr parse failed");
        }
        if (cbpC == 2) {
            for (int p = 0; p < 2; ++p) {
                for (int b = 0; b < 4; ++b) {
                    int lx, ly;
                    walk_detail::chrXY(b, lx, ly);
                    int* nA = (lx > 0) ? tcatC(p, mbx, mby, lx - 1, ly) : tcatC(p, mbx - 1, mby, 1, ly);
                    int* nB = (ly > 0) ? tcatC(p, mbx, mby, lx, ly - 1) : tcatC(p, mbx, mby - 1, lx, 1);
                    auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 15);
                    expect(r.ok, "host P chroma AC parse failed");
                    tcsetC(p, mbx, mby, lx, ly, r.total_coeff);
                }
            }
        } else {
            for (int p = 0; p < 2; ++p)
                for (int b = 0; b < 4; ++b) {
                    int lx, ly;
                    walk_detail::chrXY(b, lx, ly);
                    tcsetC(p, mbx, mby, lx, ly, 0);
                }
        }
    };
    auto parseLuma = [&](int mbx, int mby, int cbpL, int maxCoeff) {
        for (int i8 = 0; i8 < 4; ++i8) {
            if ((cbpL >> i8) & 1) {
                for (int i4 = 0; i4 < 4; ++i4) {
                    int lx, ly;
                    walk_detail::blkXY(i8, i4, lx, ly);
                    int* nA = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
                    int* nB = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
                    auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), maxCoeff);
                    expect(r.ok, "host P luma residual parse failed");
                    tcsetL(mbx, mby, lx, ly, r.total_coeff);
                }
            } else {
                for (int i4 = 0; i4 < 4; ++i4) {
                    int lx, ly;
                    walk_detail::blkXY(i8, i4, lx, ly);
                    tcsetL(mbx, mby, lx, ly, 0);
                }
            }
        }
    };
    auto parseIntra = [&](int mbx, int mby, uint32_t mt, MbExpect& e, int& qp) {
        const uint32_t it = mt - 5;
        e.part = (it == 0) ? PART_I_NXN : PART_I16X16;
        if (it == 0) {
            for (int k = 0; k < 16; ++k)
                if (br.u(1) == 0)
                    br.u(3);
            e.chroma = static_cast<int>(br.ue());
            uint32_t code = br.ue();
            e.cbp = walk_detail::kMeIntra[code];
            if (e.cbp != 0) {
                e.qpDelta = br.se();
                qp += e.qpDelta;
            }
            e.qp = qp;
            e.residual = static_cast<int>(br.bit);
            parseLuma(mbx, mby, e.cbp & 15, 16);
            parseChr(mbx, mby, e.cbp >> 4);
        } else {
            int x = static_cast<int>(it) - 1;
            int cbpC = (x / 4) % 3;
            int cbpL = (x / 12) ? 15 : 0;
            e.cbp = cbpL | (cbpC << 4);
            e.chroma = static_cast<int>(br.ue());
            e.qpDelta = br.se();
            qp += e.qpDelta;
            e.qp = qp;
            e.residual = static_cast<int>(br.bit);
            auto rdc = cavlc::residualBlock(br, walk_detail::ncFrom(tcatL(mbx - 1, mby, 3, 0),
                                                                     tcatL(mbx, mby - 1, 0, 3)), 16);
            expect(rdc.ok, "host P/I16 DC residual parse failed");
            parseLuma(mbx, mby, cbpL, 15);
            parseChr(mbx, mby, cbpC);
        }
    };

    int qp = sliceQp;
    for (int mbAddr = 0; mbAddr < totalMbs;) {
        const int skipStart = static_cast<int>(br.bit);
        const uint32_t skipRun = br.ue();
        if (skipRun > 0) {
            MbExpect skip;
            skip.start = skipStart;
            skip.mode = MODE_MB;
            skip.mbType = 0;
            skip.part = PART_P_SKIP;
            skip.residual = static_cast<int>(br.bit);
            skip.qp = qp;
            skip.skipRun = static_cast<int>(skipRun);
            for (uint32_t k = 0; k < skipRun && mbAddr + static_cast<int>(k) < totalMbs; ++k)
                setMbCoeffZero(tcLuma, tcChr, mbW, (mbAddr + static_cast<int>(k)) % mbW, (mbAddr + static_cast<int>(k)) / mbW);
            out.coveredMbs += static_cast<int>(skipRun);
            out.skippedMbs += static_cast<int>(skipRun);
            mbAddr += static_cast<int>(skipRun);
            out.syntax.push_back(skip);
            if (mbAddr >= totalMbs)
                break;
        }
        const int mbx = mbAddr % mbW;
        const int mby = mbAddr / mbW;
        MbExpect e;
        e.start = (skipRun > 0) ? static_cast<int>(br.bit) : skipStart;
        e.mode = (skipRun > 0) ? MODE_MB_LAYER : MODE_MB;
        const uint32_t mt = br.ue();
        e.mbType = static_cast<int>(mt);
        if (mt <= 4) {
            int mvdPairs = 0;
            if (mt == 0) {
                e.part = PART_P16X16;
                mvdPairs = 1;
                ++out.p16x16;
            } else if (mt == 1) {
                e.part = PART_P16X8;
                mvdPairs = 2;
                ++out.p16x8;
            } else if (mt == 2) {
                e.part = PART_P8X16;
                mvdPairs = 2;
                ++out.p8x16;
            } else {
                e.part = PART_P8X8;
                ++out.p8x8;
                for (int s = 0; s < 4; ++s) {
                    uint32_t sub = br.ue();
                    expect(sub <= 3, "host P sub_mb_type out of range");
                    mvdPairs += (sub == 0) ? 1 : (sub == 3 ? 4 : 2);
                }
            }
            for (int p = 0; p < mvdPairs; ++p) {
                br.se();
                br.se();
            }
            uint32_t cbpCode = br.ue();
            e.cbp = cbpInterMap(cbpCode);
            if (e.cbp != 0) {
                e.qpDelta = br.se();
                qp += e.qpDelta;
            }
            e.qp = qp;
            e.residual = static_cast<int>(br.bit);
            parseLuma(mbx, mby, e.cbp & 15, 16);
            parseChr(mbx, mby, e.cbp >> 4);
            ++out.interMbs;
        } else {
            parseIntra(mbx, mby, mt, e, qp);
            ++out.intraMbs;
        }
        ++out.coveredMbs;
        ++mbAddr;
        out.syntax.push_back(e);
    }
    expect(br.ok, "host P-slice MB walk bitreader failed");
    return out;
}

void checkRealPpsSliceAndIFrame(Vh264_baseline_syntax_tb_top& dut) {
    const auto blob = readFile("tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264");
    expect(!blob.empty(), "missing p3_host_recon fixture");
    auto chain = misterplex::parseAnnexBChain(blob.data(), blob.size());
    expect(chain.sps.valid && chain.pps.valid && chain.slice.valid, "host chain parse failed");
    const auto nals = splitAnnexB(blob);
    std::vector<uint8_t> ppsPayload;
    std::vector<uint8_t> vclPayload;
    uint8_t vclHeader = 0;
    for (const auto& n : nals) {
        if ((n.header & 0x1f) == 8)
            ppsPayload = n.payload;
        if ((n.header & 0x1f) == 5) {
            vclPayload = n.payload;
            vclHeader = n.header;
        }
    }
    auto ppsRbsp = rbspPayload(ppsPayload);
    expect(feed(dut, ppsRbsp, MODE_PPS), "RTL PPS parse failed");
    expect(dut.pps_id == chain.pps.pps_id, "PPS id mismatch");
    expect(dut.sps_id == chain.pps.sps_id, "PPS sps id mismatch");
    expect(dut.entropy_cabac == chain.pps.entropy_cabac, "PPS entropy flag mismatch");
    expect(static_cast<int8_t>(dut.pic_init_qp) == chain.pps.pic_init_qp, "PPS pic_init_qp mismatch");
    expect(dut.deblock_ctrl == chain.pps.deblock_ctrl, "PPS deblock_ctrl mismatch");

    auto vclRbsp = rbspPayload(vclPayload);
    SliceDetail sd = parseSliceDetail(vclRbsp, vclHeader & 0x1f, (vclHeader >> 5) & 3,
                                      chain.log2_max_frame_num, chain.poc_type, chain.pps);
    dut.nal_unit_type = vclHeader & 0x1f;
    dut.nal_ref_idc = (vclHeader >> 5) & 3;
    dut.log2_max_frame_num = chain.log2_max_frame_num;
    dut.poc_type_in = chain.poc_type;
    dut.pps_pic_init_qp = chain.pps.pic_init_qp;
    dut.pps_deblock_ctrl = chain.pps.deblock_ctrl;
    expect(feed(dut, vclRbsp, MODE_SLICE), "RTL slice header parse failed");
    expect(dut.first_mb_in_slice == chain.slice.first_mb_in_slice, "slice first_mb mismatch");
    expect(dut.slice_type == chain.slice.slice_type, "slice type mismatch");
    expect(dut.frame_num == chain.slice.frame_num, "slice frame_num mismatch");
    expect(static_cast<int8_t>(dut.slice_qp_delta) == chain.slice.slice_qp_delta, "slice_qp_delta mismatch");
    expect(static_cast<int8_t>(dut.slice_qp) == chain.slice.slice_qp, "slice_qp mismatch");
    expect(dut.disable_deblocking_idc == chain.slice.disable_deblocking_idc, "deblock idc mismatch");
    expect(static_cast<int8_t>(dut.slice_alpha_c0_offset_div2) == sd.alpha, "deblock alpha mismatch");
    expect(static_cast<int8_t>(dut.slice_beta_offset_div2) == sd.beta, "deblock beta mismatch");
    expect(dut.macroblock_bit_offset == sd.mbOffset, "slice macroblock offset mismatch");

    const int mbW = (chain.sps.width + 15) / 16;
    const int mbH = (chain.sps.height + 15) / 16;
    auto mbs = collectIHeaders(vclRbsp, mbW, mbH, static_cast<int>(sd.mbOffset), chain.slice.slice_qp);
    int i4 = 0, i16 = 0;
    for (size_t i = 0; i < mbs.size(); ++i) {
        const auto& e = mbs[i];
        dut.active_slice_type = chain.slice.slice_type;
        dut.qp_in = (i == 0) ? chain.slice.slice_qp : mbs[i - 1].qp;
        expect(feed(dut, vclRbsp, MODE_MB, e.start), "RTL I macroblock parse failed at " + std::to_string(i));
        expect(dut.mb_type == e.mbType, "I MB type mismatch at " + std::to_string(i));
        expect(dut.partition_mode == e.part, "I MB partition mismatch at " + std::to_string(i));
        expect(dut.intra_chroma_pred_mode == e.chroma, "I MB chroma mode mismatch at " + std::to_string(i));
        expect(dut.coded_block_pattern == e.cbp, "I MB CBP mismatch at " + std::to_string(i));
        expect(static_cast<int8_t>(dut.mb_qp_delta) == e.qpDelta, "I MB qp_delta mismatch at " + std::to_string(i));
        expect(static_cast<int8_t>(dut.mb_qp) == e.qp, "I MB qp mismatch at " + std::to_string(i));
        expect(dut.residual_bit_offset == e.residual, "I MB residual offset mismatch at " + std::to_string(i));
        if (e.part == PART_I_NXN)
            ++i4;
        else if (e.part == PART_I16X16)
            ++i16;
    }
    expect(mbs.size() == 300, "fixture did not grade all 300 I macroblocks");
    std::cout << "I-slice MB coverage: total=" << mbs.size() << " I_NxN=" << i4 << " I16x16=" << i16 << "\n";
}

void checkReal624PFrame(Vh264_baseline_syntax_tb_top& dut) {
    const auto blob = readFile("tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264");
    expect(!blob.empty(), "missing 624x480 p3_inter_pred fixture");
    auto chain = misterplex::parseAnnexBChain(blob.data(), blob.size());
    expect(chain.sps.valid && chain.pps.valid, "host 624 chain SPS/PPS parse failed");
    expect(chain.sps.width == 624 && chain.sps.height == 480, "624 fixture geometry changed");
    const auto nals = splitAnnexB(blob);
    std::vector<uint8_t> spsPayload;
    std::vector<uint8_t> ppsPayload;
    std::vector<uint8_t> pPayload;
    uint8_t pHeader = 0;
    int epbPayloads = 0;
    for (const auto& n : nals) {
        bool hasEpb = false;
        for (size_t i = 2; i < n.payload.size(); ++i)
            if (n.payload[i - 2] == 0 && n.payload[i - 1] == 0 && n.payload[i] == 3)
                hasEpb = true;
        if (hasEpb)
            ++epbPayloads;
        if ((n.header & 0x1f) == 7)
            spsPayload = n.payload;
        if ((n.header & 0x1f) == 8)
            ppsPayload = n.payload;
        if ((n.header & 0x1f) == 1 && pPayload.empty()) {
            pPayload = n.payload;
            pHeader = n.header;
        }
    }
    expect(epbPayloads > 0, "624 fixture no longer exercises emulation-prevention removal");
    expect(containsEpb(spsPayload), "624 SPS no longer contains EPB bytes");
    auto spsRbsp = rbspPayload(spsPayload);
    expect(!containsEpb(spsRbsp), "EPB removal failed before SPS/RBSP syntax parse");
    auto ppsRbsp = rbspPayload(ppsPayload);
    expect(feed(dut, ppsRbsp, MODE_PPS), "RTL 624 PPS parse failed");
    auto pRbsp = rbspPayload(pPayload);
    SliceDetail sd = parseSliceDetail(pRbsp, pHeader & 0x1f, (pHeader >> 5) & 3,
                                      chain.log2_max_frame_num, chain.poc_type, chain.pps);
    auto sh = misterplex::parseSliceHeaderRbsp(pPayload.data(), pPayload.size(), pHeader & 0x1f,
                                               (pHeader >> 5) & 3, chain.log2_max_frame_num,
                                               chain.poc_type, chain.pps);
    expect(sh.valid && (sh.slice_type == 0 || sh.slice_type == 5), "first 624 non-IDR is not a valid P slice");
    dut.nal_unit_type = pHeader & 0x1f;
    dut.nal_ref_idc = (pHeader >> 5) & 3;
    dut.log2_max_frame_num = chain.log2_max_frame_num;
    dut.poc_type_in = chain.poc_type;
    dut.pps_pic_init_qp = chain.pps.pic_init_qp;
    dut.pps_deblock_ctrl = chain.pps.deblock_ctrl;
    expect(feed(dut, pRbsp, MODE_SLICE), "RTL 624 P slice header parse failed");
    expect(dut.first_mb_in_slice == sh.first_mb_in_slice, "624 P slice first_mb mismatch");
    expect(dut.slice_type == sh.slice_type, "624 P slice type mismatch");
    expect(static_cast<int8_t>(dut.slice_qp) == sh.slice_qp, "624 P slice qp mismatch");
    expect(dut.macroblock_bit_offset == sd.mbOffset, "624 P macroblock offset mismatch");

    const int mbW = (chain.sps.width + 15) / 16;
    const int mbH = (chain.sps.height + 15) / 16;
    auto walk = collectPHeaders(pRbsp, mbW, mbH, static_cast<int>(sd.mbOffset), sh.slice_qp);
    expect(mbW == 39 && mbH == 30 && walk.coveredMbs == 1170, "624 P walk did not cover 1170 macroblocks");
    int qp = sh.slice_qp;
    for (size_t i = 0; i < walk.syntax.size(); ++i) {
        const auto& e = walk.syntax[i];
        dut.active_slice_type = sh.slice_type;
        dut.qp_in = qp;
        dut.num_ref_idx_l0_active_minus1 = 0;
        expect(feed(dut, pRbsp, e.mode, e.start), "RTL 624 P macroblock parse failed at syntax " + std::to_string(i));
        if (e.part == PART_P_SKIP) {
            expect(dut.mb_skipped && dut.mb_skip_run == e.skipRun, "624 P skip_run mismatch at syntax " + std::to_string(i));
            expect(dut.partition_mode == PART_P_SKIP, "624 P skip partition mismatch at syntax " + std::to_string(i));
            expect(dut.residual_bit_offset == e.residual, "624 P skip residual offset mismatch at syntax " + std::to_string(i));
        } else {
            expect(!dut.mb_skipped, "624 P non-skip reported skipped at syntax " + std::to_string(i));
            expect(dut.mb_type == e.mbType, "624 P MB type mismatch at syntax " + std::to_string(i));
            expect(dut.partition_mode == e.part, "624 P partition mismatch at syntax " + std::to_string(i));
            expect(dut.coded_block_pattern == e.cbp, "624 P CBP mismatch at syntax " + std::to_string(i));
            expect(static_cast<int8_t>(dut.mb_qp_delta) == e.qpDelta, "624 P qp_delta mismatch at syntax " + std::to_string(i));
            expect(static_cast<int8_t>(dut.mb_qp) == e.qp, "624 P qp mismatch at syntax " + std::to_string(i));
            expect(dut.residual_bit_offset == e.residual, "624 P residual offset mismatch at syntax " + std::to_string(i));
            qp = e.qp;
        }
    }
    std::cout << "P-slice Scope detail: 1170/1170 real 624x480 MBs via "
              << walk.syntax.size() << " syntax groups, skipped=" << walk.skippedMbs
              << " inter=" << walk.interMbs << " intra=" << walk.intraMbs
              << " P16x16=" << walk.p16x16 << " P16x8=" << walk.p16x8
              << " P8x16=" << walk.p8x16 << " P8x8=" << walk.p8x8
              << " EPB_payloads=" << epbPayloads << "\n";
}

void checkSyntheticP(Vh264_baseline_syntax_tb_top& dut) {
    dut.active_slice_type = 0;
    dut.qp_in = 10;
    Bits skip;
    skip.ue(3);
    expect(feed(dut, skip.bytes(), MODE_MB), "P_Skip parse failed");
    expect(dut.mb_skipped && dut.mb_skip_run == 3 && dut.partition_mode == PART_P_SKIP, "P_Skip fields mismatch");

    Bits p16;
    p16.ue(0); // mb_skip_run
    p16.ue(0); // P_L0_16x16
    p16.se(0);
    p16.se(0);
    p16.ue(0); // CBP inter code -> 0
    expect(feed(dut, p16.bytes(), MODE_MB), "P16x16 parse failed");
    expect(!dut.mb_skipped && dut.mb_type == 0 && dut.partition_mode == PART_P16X16 && dut.coded_block_pattern == 0,
           "P16x16 fields mismatch");

    Bits p8;
    p8.ue(0); // mb_skip_run
    p8.ue(3); // P_8x8
    p8.ue(0);
    p8.ue(1);
    p8.ue(2);
    p8.ue(3);
    for (int i = 0; i < 18; ++i)
        p8.se(0);
    p8.ue(1); // CBP inter code -> 16
    p8.se(2);
    expect(feed(dut, p8.bytes(), MODE_MB), "rare P8x8 parse failed");
    expect(dut.partition_mode == PART_P8X8, "rare P8x8 partition did not execute");
    expect(dut.coded_block_pattern == 16, "rare P8x8 CBP mismatch");
    expect(static_cast<int8_t>(dut.mb_qp_delta) == 2 && static_cast<int8_t>(dut.mb_qp) == 12, "rare P8x8 QP mismatch");
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "Scope: RTL product syntax parser, 1170/1170 MBs of one real 624x480 Baseline P frame (39x30), plus 300/300 real 320x240 IDR MBs and synthetic rare P modes\n";
    Vh264_baseline_syntax_tb_top dut;
    reset(dut);
    checkRealPpsSliceAndIFrame(dut);
    checkReal624PFrame(dut);
    checkSyntheticP(dut);
    if (failures) {
        std::cerr << "h264 baseline syntax RTL check FAILED: " << failures << " failures\n";
        return 1;
    }
    std::cout << "h264 baseline syntax RTL check PASS: PPS, slice header/deblock offsets, 300/300 real I macroblocks, 1170/1170 real 624x480 P macroblocks, synthetic P_Skip/P16x16/rare P8x8\n";
    return 0;
}
