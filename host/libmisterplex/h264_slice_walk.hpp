// Baseline I-slice residual walker — Phase 3.3h.
// Uses FFmpeg-layout CAVLC tables via residualBlock(); tracks luma + chroma nC.
#pragma once
#include "libmisterplex/h264_cavlc.hpp"

#include <cstdint>
#include <utility>
#include <string>
#include <vector>

namespace misterplex {

struct SliceWalkResult {
    int mb_decoded = 0;
    int mb_total = 0;
    int fail_mb = -1;
    const char* fail_reason = nullptr;
    int first_residual_tc = -1;
    int first_residual_t1 = -1;
};

namespace walk_detail {

// Intra coded_block_pattern me mapping (FFmpeg golomb_to_intra4x4_cbp)
static const uint8_t kMeIntra[48] = {
    47, 31, 15, 0,  23, 27, 29, 30, 7,  11, 13, 14, 39, 43, 45, 46,
    16, 3,  5,  10, 12, 19, 21, 26, 28, 35, 37, 42, 44, 1,  2,  4,
    8,  17, 18, 20, 24, 6,  9,  22, 25, 32, 33, 34, 36, 40, 38, 41};

inline int ncFrom(const int* a, const int* b) {
    if (!a && !b)
        return 0;
    if (!a)
        return *b;
    if (!b)
        return *a;
    return (*a + *b + 1) >> 1;
}

inline void blkXY(int i8, int i4, int& lx, int& ly) {
    lx = (i8 % 2) * 2 + (i4 % 2);
    ly = (i8 / 2) * 2 + (i4 / 2);
}

inline void chrXY(int blk, int& lx, int& ly) {
    lx = blk % 2;
    ly = blk / 2;
}


// FFmpeg golomb_to_inter4x4_cbp (matches rtl cbp_inter)
static const uint8_t kMeInter[48] = {
    0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13,
    14, 6, 9, 31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46,
    17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41};

inline bool isPSliceType(uint8_t t) { return t == 0 || t == 5; }

// Landed P-header (RTL / FULL_SLICE_CAVLC.md §6): three u(1) after frame_num.
inline const char* parsePHeaderThreeU1(detail::BitReader& br, int& nref_l0) {
    if (br.u(1)) {
        for (;;) {
            uint32_t mmco = br.ue();
            if (!br.ok)
                return "mmco";
            if (mmco == 0)
                break;
            if (mmco == 1 || mmco == 3)
                br.ue();
            if (mmco == 2)
                br.ue();
            if (mmco == 3 || mmco == 6)
                br.ue();
            if (mmco == 4)
                br.ue();
        }
    }
    if (br.u(1))
        nref_l0 = static_cast<int>(br.ue()) + 1;
    if (br.u(1)) {
        for (;;) {
            uint32_t idc = br.ue();
            if (!br.ok)
                return "rplm";
            if (idc == 3)
                break;
            if (idc <= 2)
                br.ue();
            else
                return "rplm_idc";
        }
    }
    return nullptr;
}

} // namespace walk_detail

// Walk I-slice residual of first IDR/I NAL until failure or all MBs.
inline SliceWalkResult walkISliceResiduals(const uint8_t* annexb, size_t n) {
    SliceWalkResult out;
    auto chain = parseAnnexBChain(annexb, n);
    if (!chain.sps.valid || !chain.pps.valid || !chain.slice.valid) {
        out.fail_reason = "no chain";
        return out;
    }
    // Find VCL NAL payload
    size_t i = 0;
    const uint8_t* pay = nullptr;
    size_t plen = 0;
    uint8_t ntype = 0;
    while (i + 3 < n) {
        size_t sc = 0;
        if (i + 3 < n && annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 0 &&
            annexb[i + 3] == 1)
            sc = 4;
        else if (annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 1)
            sc = 3;
        else {
            ++i;
            continue;
        }
        size_t j = i + sc;
        while (j + 3 < n) {
            if (annexb[j] == 0 && annexb[j + 1] == 0 &&
                (annexb[j + 2] == 1 || (j + 3 < n && annexb[j + 2] == 0 && annexb[j + 3] == 1)))
                break;
            ++j;
        }
        if (j + 3 >= n)
            j = n;
        uint8_t t = annexb[i + sc] & 0x1f;
        if (t == 5 || t == 1) {
            pay = annexb + i + sc + 1;
            plen = j - (i + sc + 1);
            ntype = t;
            break;
        }
        i = j;
    }
    if (!pay) {
        out.fail_reason = "no VCL";
        return out;
    }
    auto rbsp = detail::removeEpb(pay, plen);
    detail::BitReader br(rbsp.data(), rbsp.size());
    br.ue(); // first_mb
    br.ue(); // slice_type
    br.ue(); // pps_id
    br.u(chain.log2_max_frame_num);
    if (ntype == 5) {
        br.ue(); // idr_pic_id
        br.u(1); // no_output_of_prior_pics_flag
        br.u(1); // long_term_reference_flag
    }
    br.se(); // slice_qp_delta
    if (chain.pps.deblock_ctrl) {
        uint32_t d = br.ue();
        if (d != 1) {
            br.se();
            br.se();
        }
    }

    const int mbW = (chain.sps.width + 15) / 16;
    const int mbH = (chain.sps.height + 15) / 16;
    out.mb_total = mbW * mbH;

    // Luma 4x4 TotalCoeff map: index (mby*mbW+mbx)*16 + ly*4 + lx
    std::vector<int> tcLuma(static_cast<size_t>(mbW * mbH * 16), -1);
    // Chroma AC 2x2 TotalCoeff per plane
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

    auto parseChr = [&](int mbx, int mby, int cbp_c) -> const char* {
        if (cbp_c) {
            if (!cavlc::residualBlock(br, -1, 4).ok || !cavlc::residualBlock(br, -1, 4).ok)
                return "chrDC";
        }
        if (cbp_c == 2) {
            for (int p = 0; p < 2; ++p) {
                for (int b = 0; b < 4; ++b) {
                    int lx, ly;
                    walk_detail::chrXY(b, lx, ly);
                    int* nA = (lx > 0) ? tcatC(p, mbx, mby, lx - 1, ly) : tcatC(p, mbx - 1, mby, 1, ly);
                    int* nB = (ly > 0) ? tcatC(p, mbx, mby, lx, ly - 1) : tcatC(p, mbx, mby - 1, lx, 1);
                    int nC = walk_detail::ncFrom(nA, nB);
                    auto r = cavlc::residualBlock(br, nC, 15);
                    if (!r.ok)
                        return "chrAC";
                    tcsetC(p, mbx, mby, lx, ly, r.total_coeff);
                }
            }
        } else {
            // Uncoded chroma AC → TotalCoeff 0 for neighbors
            for (int p = 0; p < 2; ++p)
                for (int b = 0; b < 4; ++b) {
                    int lx, ly;
                    walk_detail::chrXY(b, lx, ly);
                    tcsetC(p, mbx, mby, lx, ly, 0);
                }
        }
        return nullptr;
    };

    for (int mby = 0; mby < mbH; ++mby) {
        for (int mbx = 0; mbx < mbW; ++mbx) {
            int mb = mby * mbW + mbx;
            if (!br.ok) {
                out.fail_mb = mb;
                out.fail_reason = "br";
                return out;
            }
            uint32_t mt = br.ue();
            if (mt > 25) {
                out.fail_mb = mb;
                out.fail_reason = "mb_type";
                return out;
            }
            if (mt == 25) {
                // PCM
                while (br.ok && (br.bit % 8) != 0)
                    br.u(1);
                for (int k = 0; k < 384 && br.ok; ++k)
                    br.u(8);
                for (int ly = 0; ly < 4; ++ly)
                    for (int lx = 0; lx < 4; ++lx)
                        tcsetL(mbx, mby, lx, ly, 16);
                for (int p = 0; p < 2; ++p)
                    for (int b = 0; b < 4; ++b) {
                        int lx, ly;
                        walk_detail::chrXY(b, lx, ly);
                        tcsetC(p, mbx, mby, lx, ly, 16);
                    }
                out.mb_decoded++;
                continue;
            }
            if (mt == 0) {
                // I_NxN
                for (int k = 0; k < 16; ++k)
                    if (br.u(1) == 0)
                        br.u(3);
                br.ue(); // chroma pred
                uint32_t code = br.ue();
                if (code >= 48) {
                    out.fail_mb = mb;
                    out.fail_reason = "me_cbp";
                    return out;
                }
                int cbp = walk_detail::kMeIntra[code];
                int cbp_l = cbp & 15;
                int cbp_c = cbp >> 4;
                if (cbp != 0)
                    br.se(); // mb_qp_delta
                for (int i8 = 0; i8 < 4; ++i8) {
                    if ((cbp_l >> i8) & 1) {
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly;
                            walk_detail::blkXY(i8, i4, lx, ly);
                            int* nA = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly)
                                               : tcatL(mbx - 1, mby, 3, ly);
                            int* nB = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1)
                                               : tcatL(mbx, mby - 1, lx, 3);
                            int nC = walk_detail::ncFrom(nA, nB);
                            auto r = cavlc::residualBlock(br, nC, 16);
                            if (!r.ok) {
                                out.fail_mb = mb;
                                out.fail_reason = "I4_res";
                                return out;
                            }
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
                if (const char* e = parseChr(mbx, mby, cbp_c)) {
                    out.fail_mb = mb;
                    out.fail_reason = e;
                    return out;
                }
            } else {
                // I_16x16 — intra_chroma_pred_mode is coded for all Intra MBs (7.3.5)
                int x = static_cast<int>(mt) - 1;
                int cbp_c = (x / 4) % 3;
                int cbp_l = (x / 12) ? 15 : 0;
                br.ue(); // intra_chroma_pred_mode
                br.se(); // mb_qp_delta
                int* nA = tcatL(mbx - 1, mby, 3, 0);
                int* nB = tcatL(mbx, mby - 1, 0, 3);
                int nC = walk_detail::ncFrom(nA, nB);
                auto r = cavlc::residualBlock(br, nC, 16);
                if (!r.ok) {
                    out.fail_mb = mb;
                    out.fail_reason = "I16_dc";
                    return out;
                }
                if (out.first_residual_tc < 0) {
                    out.first_residual_tc = r.total_coeff;
                    out.first_residual_t1 = r.trailing_ones;
                }
                if (cbp_l) {
                    for (int i8 = 0; i8 < 4; ++i8)
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly;
                            walk_detail::blkXY(i8, i4, lx, ly);
                            int* a =
                                (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
                            int* b =
                                (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
                            auto rr = cavlc::residualBlock(br, walk_detail::ncFrom(a, b), 15);
                            if (!rr.ok) {
                                out.fail_mb = mb;
                                out.fail_reason = "I16_ac";
                                return out;
                            }
                            tcsetL(mbx, mby, lx, ly, rr.total_coeff);
                        }
                } else {
                    for (int ly = 0; ly < 4; ++ly)
                        for (int lx = 0; lx < 4; ++lx)
                            tcsetL(mbx, mby, lx, ly, 0);
                }
                if (const char* e = parseChr(mbx, mby, cbp_c)) {
                    out.fail_mb = mb;
                    out.fail_reason = e;
                    return out;
                }
            }
            out.mb_decoded++;
        }
    }
    return out;
}

struct PWalkAllResult {
    int p_slices = 0;
    int p_full = 0;
    int fail_p = -1;
    const char* fail_reason = nullptr;
    std::vector<SliceWalkResult> each;
};

// Walk one P slice (p_index among type-1 P NALs). 7.3.4 skip_run; P_L0_16x16 only.
inline SliceWalkResult walkPSliceResiduals(const uint8_t* annexb, size_t n, int p_index = 0) {
    SliceWalkResult out;
    auto chain = parseAnnexBChain(annexb, n);
    if (!chain.sps.valid || !chain.pps.valid) {
        out.fail_reason = "no chain";
        return out;
    }
    const uint8_t* pay = nullptr;
    size_t plen = 0;
    int seen_p = 0;
    size_t i = 0;
    while (i + 3 < n) {
        size_t sc = 0;
        if (i + 3 < n && annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 0 &&
            annexb[i + 3] == 1)
            sc = 4;
        else if (annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 1)
            sc = 3;
        else {
            ++i;
            continue;
        }
        size_t j = i + sc;
        while (j + 3 < n) {
            if (annexb[j] == 0 && annexb[j + 1] == 0 &&
                (annexb[j + 2] == 1 || (j + 3 < n && annexb[j + 2] == 0 && annexb[j + 3] == 1)))
                break;
            ++j;
        }
        if (j + 3 >= n)
            j = n;
        uint8_t hdr = annexb[i + sc];
        uint8_t t = hdr & 0x1f;
        if (t == 1) {
            const uint8_t* p = annexb + i + sc + 1;
            size_t pl = j - (i + sc + 1);
            auto rb = detail::removeEpb(p, pl);
            detail::BitReader peek(rb.data(), rb.size());
            peek.ue();
            uint32_t st = peek.ue();
            if (walk_detail::isPSliceType(static_cast<uint8_t>(st))) {
                if (seen_p == p_index) {
                    pay = p;
                    plen = pl;
                    break;
                }
                ++seen_p;
            }
        }
        i = j;
    }
    if (!pay) {
        out.fail_reason = "no P VCL";
        return out;
    }
    auto rbsp = detail::removeEpb(pay, plen);
    detail::BitReader br(rbsp.data(), rbsp.size());
    br.ue(); // first_mb
    br.ue(); // slice_type
    br.ue(); // pps_id
    br.u(chain.log2_max_frame_num);
    int nref = static_cast<int>(chain.pps.num_ref_idx_l0_default) + 1;
    if (const char* e = walk_detail::parsePHeaderThreeU1(br, nref)) {
        out.fail_reason = e;
        return out;
    }
    br.se(); // slice_qp_delta
    if (chain.pps.deblock_ctrl) {
        uint32_t d = br.ue();
        if (d != 1) {
            br.se();
            br.se();
        }
    }

    const int mbW = (chain.sps.width + 15) / 16;
    const int mbH = (chain.sps.height + 15) / 16;
    out.mb_total = mbW * mbH;

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

    auto parseChr = [&](int mbx, int mby, int cbp_c) -> const char* {
        if (cbp_c) {
            if (!cavlc::residualBlock(br, -1, 4).ok || !cavlc::residualBlock(br, -1, 4).ok)
                return "chrDC";
        }
        if (cbp_c == 2) {
            for (int p = 0; p < 2; ++p) {
                for (int b = 0; b < 4; ++b) {
                    int lx, ly;
                    walk_detail::chrXY(b, lx, ly);
                    int* nA = (lx > 0) ? tcatC(p, mbx, mby, lx - 1, ly) : tcatC(p, mbx - 1, mby, 1, ly);
                    int* nB = (ly > 0) ? tcatC(p, mbx, mby, lx, ly - 1) : tcatC(p, mbx, mby - 1, lx, 1);
                    int nC = walk_detail::ncFrom(nA, nB);
                    auto r = cavlc::residualBlock(br, nC, 15);
                    if (!r.ok)
                        return "chrAC";
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
        return nullptr;
    };

    auto zeroNeigh = [&](int mbx, int mby) {
        for (int ly = 0; ly < 4; ++ly)
            for (int lx = 0; lx < 4; ++lx)
                tcsetL(mbx, mby, lx, ly, 0);
        for (int p = 0; p < 2; ++p)
            for (int b = 0; b < 4; ++b) {
                int lx, ly;
                walk_detail::chrXY(b, lx, ly);
                tcsetC(p, mbx, mby, lx, ly, 0);
            }
    };

    auto parseI4 = [&](int mbx, int mby) -> const char* {
        for (int k = 0; k < 16; ++k)
            if (br.u(1) == 0)
                br.u(3);
        br.ue();
        uint32_t code = br.ue();
        if (code >= 48)
            return "me_cbp";
        int cbp = walk_detail::kMeIntra[code];
        int cbp_l = cbp & 15;
        int cbp_c = cbp >> 4;
        if (cbp != 0)
            br.se();
        for (int i8 = 0; i8 < 4; ++i8) {
            if ((cbp_l >> i8) & 1) {
                for (int i4 = 0; i4 < 4; ++i4) {
                    int lx, ly;
                    walk_detail::blkXY(i8, i4, lx, ly);
                    int* nA = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
                    int* nB = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
                    auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 16);
                    if (!r.ok)
                        return "I4_res";
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
        return parseChr(mbx, mby, cbp_c);
    };

    auto parseI16 = [&](int mbx, int mby, uint32_t mt_i) -> const char* {
        int x = static_cast<int>(mt_i) - 1;
        int cbp_c = (x / 4) % 3;
        int cbp_l = (x / 12) ? 15 : 0;
        br.ue();
        br.se();
        int* nA = tcatL(mbx - 1, mby, 3, 0);
        int* nB = tcatL(mbx, mby - 1, 0, 3);
        auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 16);
        if (!r.ok)
            return "I16_dc";
        if (cbp_l) {
            for (int i8 = 0; i8 < 4; ++i8)
                for (int i4 = 0; i4 < 4; ++i4) {
                    int lx, ly;
                    walk_detail::blkXY(i8, i4, lx, ly);
                    int* a = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
                    int* b = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
                    auto rr = cavlc::residualBlock(br, walk_detail::ncFrom(a, b), 15);
                    if (!rr.ok)
                        return "I16_ac";
                    tcsetL(mbx, mby, lx, ly, rr.total_coeff);
                }
        } else {
            for (int ly = 0; ly < 4; ++ly)
                for (int lx = 0; lx < 4; ++lx)
                    tcsetL(mbx, mby, lx, ly, 0);
        }
        return parseChr(mbx, mby, cbp_c);
    };

    uint32_t skip_run = 0;
    bool need_skip = true;
    for (int mby = 0; mby < mbH; ++mby) {
        for (int mbx = 0; mbx < mbW; ++mbx) {
            int mb = mby * mbW + mbx;
            if (!br.ok) {
                out.fail_mb = mb;
                out.fail_reason = "br";
                return out;
            }
            if (skip_run != 0) {
                zeroNeigh(mbx, mby);
                skip_run--;
                out.mb_decoded++;
                continue;
            }
            if (need_skip) {
                skip_run = br.ue();
                need_skip = false;
                if (!br.ok) {
                    out.fail_mb = mb;
                    out.fail_reason = "skip_run";
                    return out;
                }
                if (skip_run != 0) {
                    zeroNeigh(mbx, mby);
                    skip_run--;
                    out.mb_decoded++;
                    continue;
                }
            }
            uint32_t mt = br.ue();
            if (mt == 0) {
                // P_L0_16x16 — Phase 1: 1 ref → omit te; no P_16x8
                if (nref > 1)
                    br.ue();
                br.se();
                br.se();
                uint32_t code = br.ue();
                if (code >= 48) {
                    out.fail_mb = mb;
                    out.fail_reason = "me_cbp";
                    return out;
                }
                int cbp = walk_detail::kMeInter[code];
                int cbp_l = cbp & 15;
                int cbp_c = cbp >> 4;
                if (cbp != 0)
                    br.se();
                for (int i8 = 0; i8 < 4; ++i8) {
                    if ((cbp_l >> i8) & 1) {
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly;
                            walk_detail::blkXY(i8, i4, lx, ly);
                            int* nA = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly)
                                               : tcatL(mbx - 1, mby, 3, ly);
                            int* nB = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1)
                                               : tcatL(mbx, mby - 1, lx, 3);
                            auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 16);
                            if (!r.ok) {
                                out.fail_mb = mb;
                                out.fail_reason = "P16_res";
                                return out;
                            }
                            if (out.first_residual_tc < 0) {
                                out.first_residual_tc = r.total_coeff;
                                out.first_residual_t1 = r.trailing_ones;
                            }
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
                if (const char* e = parseChr(mbx, mby, cbp_c)) {
                    out.fail_mb = mb;
                    out.fail_reason = e;
                    return out;
                }
                need_skip = true;
            } else if (mt >= 5 && mt <= 29) {
                uint32_t imt = mt - 5;
                const char* e = (imt == 0) ? parseI4(mbx, mby) : parseI16(mbx, mby, imt);
                if (e) {
                    out.fail_mb = mb;
                    out.fail_reason = e;
                    return out;
                }
                need_skip = true;
            } else {
                out.fail_mb = mb;
                out.fail_reason = (mt == 1 || mt == 2) ? "p_part" : "mb_type";
                return out;
            }
            out.mb_decoded++;
        }
    }
    return out;
}

inline PWalkAllResult walkAllPSliceResiduals(const uint8_t* annexb, size_t n) {
    PWalkAllResult all;
    for (int p = 0; p < 32; ++p) {
        auto w = walkPSliceResiduals(annexb, n, p);
        if (w.fail_reason && std::string(w.fail_reason) == "no P VCL")
            break;
        all.p_slices++;
        all.each.push_back(w);
        if (w.mb_decoded == w.mb_total && w.mb_total > 0)
            all.p_full++;
        else if (all.fail_p < 0) {
            all.fail_p = p;
            all.fail_reason = w.fail_reason ? w.fail_reason : "short";
        }
    }
    if (all.p_slices == 0 && all.fail_reason == nullptr)
        all.fail_reason = "no P VCL";
    return all;
}

} // namespace misterplex
