#pragma once

#include "libmisterplex/h264_nal.hpp"
#include "libmisterplex/h264_slice_walk.hpp"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <vector>

namespace h264_real_p_scope {

constexpr int PART_P_SKIP = 1;
constexpr int PART_P16X16 = 2;
constexpr int PART_P16X8 = 3;
constexpr int PART_P8X16 = 4;
constexpr int PART_P8X8 = 5;
constexpr int PART_I_NXN = 6;
constexpr int PART_I16X16 = 7;

enum class MbKind { Skip, Inter, Intra };

struct MbInfo {
    MbKind kind = MbKind::Inter;
    int part = PART_P16X16;
    int qp = 0;
    int cbp = 0;
    bool nonzero = false;
    int ref = 0;
    int mvx = 0;
    int mvy = 0;
};

struct FrameScope {
    int coded_w = 0;
    int coded_h = 0;
    int display_w = 0;
    int display_h = 0;
    int mb_w = 0;
    int mb_h = 0;
    int total_mbs = 0;
    int syntax_groups = 0;
    int skipped_mbs = 0;
    int inter_mbs = 0;
    int intra_mbs = 0;
    int p16x16 = 0;
    int p16x8 = 0;
    int p8x16 = 0;
    int p8x8 = 0;
    int qp_min = 52;
    int qp_max = -1;
    int epb_payloads = 0;
    std::vector<MbInfo> mbs;
};

struct Nal {
    uint8_t header = 0;
    std::vector<uint8_t> payload;
};

inline std::vector<uint8_t> readFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open real P fixture: " + path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

inline std::vector<Nal> splitAnnexB(const std::vector<uint8_t>& data) {
    std::vector<Nal> out;
    size_t i = 0;
    while (i + 3 < data.size()) {
        size_t sc = 0;
        if (i + 3 < data.size() && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1)
            sc = 4;
        else if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
            sc = 3;
        if (!sc) { ++i; continue; }
        size_t j = i + sc;
        while (j + 3 < data.size()) {
            if (data[j] == 0 && data[j + 1] == 0 &&
                (data[j + 2] == 1 || (j + 3 < data.size() && data[j + 2] == 0 && data[j + 3] == 1)))
                break;
            ++j;
        }
        if (j + 3 >= data.size()) j = data.size();
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

inline int parseDisplayWidthHint(const std::string& fixturePath) {
    const std::size_t slash = fixturePath.find_last_of('/');
    const std::string dir = (slash == std::string::npos) ? std::string("tests/fixtures/p3_inter_pred")
                                                         : fixturePath.substr(0, slash);
    std::ifstream in(dir + "/inter_mc_v1.json");
    if (!in) return 0;
    const std::string text((std::istreambuf_iterator<char>(in)), {});
    const std::size_t d = text.find("\"display\"");
    if (d == std::string::npos) return 0;
    const std::size_t lb = text.find('[', d);
    if (lb == std::string::npos) return 0;
    const char* p = text.c_str() + lb + 1;
    char* end = nullptr;
    long w = std::strtol(p, &end, 10);
    if (end == p || w <= 0 || w > 4096) return 0;
    return static_cast<int>(w);
}

inline bool containsEpb(const std::vector<uint8_t>& payload) {
    for (size_t i = 2; i < payload.size(); ++i)
        if (payload[i - 2] == 0 && payload[i - 1] == 0 && payload[i] == 3)
            return true;
    return false;
}

struct SpsGeometry {
    int coded_w = 0;
    int coded_h = 0;
    int display_w = 0;
    int display_h = 0;
};

inline SpsGeometry parseSpsGeometry(const std::vector<uint8_t>& payload) {
    auto rbsp = misterplex::detail::removeEpb(payload.data(), payload.size());
    misterplex::detail::BitReader br(rbsp.data(), rbsp.size());
    br.u(8); // profile
    br.u(8); // constraint flags
    br.u(8); // level
    br.ue(); // sps id
    br.ue(); // log2_max_frame_num_minus4
    uint32_t poc = br.ue();
    if (poc == 0) br.ue();
    else if (poc == 1) {
        br.u(1); br.se(); br.se();
        uint32_t n = br.ue();
        for (uint32_t i = 0; i < n && br.ok; ++i) br.se();
    }
    br.ue(); // max_num_ref_frames
    br.u(1); // gaps allowed
    uint32_t w_mbs = br.ue() + 1;
    uint32_t h_map = br.ue() + 1;
    uint32_t frame_mbs_only = br.u(1);
    if (!frame_mbs_only) br.u(1);
    br.u(1); // direct_8x8_inference
    uint32_t crop = br.u(1);
    uint32_t l = 0, r = 0, t = 0, b = 0;
    if (crop) { l = br.ue(); r = br.ue(); t = br.ue(); b = br.ue(); }
    if (!br.ok) throw std::runtime_error("real P fixture SPS geometry parse failed");
    SpsGeometry g;
    g.coded_w = static_cast<int>(w_mbs * 16);
    g.coded_h = static_cast<int>(h_map * 16 * (frame_mbs_only ? 1u : 2u));
    g.display_w = g.coded_w - static_cast<int>((l + r) * 2);
    g.display_h = g.coded_h - static_cast<int>((t + b) * 2);
    return g;
}

struct SliceDetail {
    uint32_t mb_offset = 0;
    int slice_qp = 0;
};

inline SliceDetail parseSliceDetail(const std::vector<uint8_t>& rbsp, uint8_t nal_type, uint8_t nal_ref_idc,
                                    uint8_t log2_frame_num, uint8_t poc_type,
                                    const misterplex::PpsInfo& pps) {
    misterplex::detail::BitReader br(rbsp.data(), rbsp.size());
    br.ue();
    uint32_t slice_type = br.ue();
    br.ue();
    br.u(log2_frame_num);
    if (nal_type == 5) {
        br.ue(); br.u(1); br.u(1);
    } else if (poc_type == 0) {
        br.ue();
    }
    const bool is_i = misterplex::isISliceType(static_cast<uint8_t>(slice_type));
    if (!is_i) {
        if (br.u(1)) br.ue();
        if (br.u(1)) {
            uint32_t idc = 0;
            do {
                idc = br.ue();
                if (idc <= 2) br.ue();
            } while (idc != 3 && br.ok);
        }
    }
    if (nal_ref_idc) {
        if (nal_type == 5) { br.u(1); br.u(1); }
        else br.u(1);
    }
    const int qp = std::clamp(static_cast<int>(pps.pic_init_qp) + static_cast<int>(br.se()), 0, 51);
    if (pps.deblock_ctrl) {
        uint32_t idc = br.ue();
        if (idc != 1) { br.se(); br.se(); }
    }
    if (!br.ok) throw std::runtime_error("real P fixture slice header parse failed");
    return SliceDetail{static_cast<uint32_t>(br.bit), qp};
}

inline int cbpInterMap(uint32_t code) {
    static const uint8_t kMap[48] = {
        0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15,
        47, 7, 11, 13, 14, 6, 9, 31, 35, 37, 42, 44,
        33, 34, 36, 40, 39, 43, 45, 46, 17, 18, 20, 24,
        19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41};
    if (code >= 48) throw std::runtime_error("real P fixture inter CBP code out of range");
    return kMap[code];
}

inline void applyQpDelta(int& qp, int delta) {
    qp = (qp + delta) % 52;
    if (qp < 0) qp += 52;
}

inline void setMbCoeffZero(std::vector<int>& tc_luma, std::vector<int> (&tc_chr)[2], int mb_w, int mbx, int mby) {
    for (int ly = 0; ly < 4; ++ly)
        for (int lx = 0; lx < 4; ++lx)
            tc_luma[static_cast<size_t>(((mby * mb_w + mbx) * 16) + ly * 4 + lx)] = 0;
    for (int p = 0; p < 2; ++p)
        for (int ly = 0; ly < 2; ++ly)
            for (int lx = 0; lx < 2; ++lx)
                tc_chr[p][static_cast<size_t>(((mby * mb_w + mbx) * 4) + ly * 2 + lx)] = 0;
}

inline FrameScope parseFirstPFrameScope(const std::string& path) {
    using namespace misterplex;
    auto blob = readFile(path);
    auto chain = parseAnnexBChain(blob.data(), blob.size());
    if (!chain.sps.valid || !chain.pps.valid || !chain.log2_max_frame_num)
        throw std::runtime_error("real P fixture SPS/PPS parse failed: " + path);
    const auto nals = splitAnnexB(blob);
    std::vector<uint8_t> sps_payload;
    std::vector<uint8_t> p_payload;
    uint8_t p_header = 0;
    FrameScope out;
    for (const auto& n : nals) {
        if (containsEpb(n.payload)) ++out.epb_payloads;
        const uint8_t t = n.header & 0x1f;
        if (t == 7) sps_payload = n.payload;
        if (t == 1 && p_payload.empty()) { p_payload = n.payload; p_header = n.header; }
    }
    if (sps_payload.empty() || p_payload.empty())
        throw std::runtime_error("real P fixture missing SPS or first P slice");
    const SpsGeometry geom = parseSpsGeometry(sps_payload);
    out.coded_w = geom.coded_w;
    out.coded_h = geom.coded_h;
    out.display_w = geom.display_w;
    out.display_h = geom.display_h;
    const int displayHint = parseDisplayWidthHint(path);
    if (displayHint > 0 && displayHint <= out.coded_w)
        out.display_w = displayHint;
    out.mb_w = out.coded_w / 16;
    out.mb_h = out.coded_h / 16;
    out.total_mbs = out.mb_w * out.mb_h;
    out.mbs.assign(static_cast<size_t>(out.total_mbs), MbInfo{});

    auto rbsp = detail::removeEpb(p_payload.data(), p_payload.size());
    auto sh = parseSliceHeaderRbsp(p_payload.data(), p_payload.size(), p_header & 0x1f, (p_header >> 5) & 3,
                                   chain.log2_max_frame_num, chain.poc_type, chain.pps);
    if (!sh.valid || misterplex::isISliceType(sh.slice_type))
        throw std::runtime_error("first non-IDR fixture slice is not a P slice");
    const SliceDetail sd = parseSliceDetail(rbsp, p_header & 0x1f, (p_header >> 5) & 3,
                                            chain.log2_max_frame_num, chain.poc_type, chain.pps);

    detail::BitReader br(rbsp.data(), rbsp.size());
    br.bit = sd.mb_offset;
    std::vector<int> tc_luma(static_cast<size_t>(out.total_mbs * 16), -1);
    std::vector<int> tc_chr[2] = {std::vector<int>(static_cast<size_t>(out.total_mbs * 4), -1),
                                  std::vector<int>(static_cast<size_t>(out.total_mbs * 4), -1)};
    auto tcat_l = [&](int mbx, int mby, int lx, int ly) -> int* {
        if (mbx < 0 || mby < 0 || mbx >= out.mb_w || mby >= out.mb_h || lx < 0 || ly < 0 || lx > 3 || ly > 3) return nullptr;
        int& v = tc_luma[static_cast<size_t>(((mby * out.mb_w + mbx) * 16) + ly * 4 + lx)];
        return (v < 0) ? nullptr : &v;
    };
    auto tcset_l = [&](int mbx, int mby, int lx, int ly, int v, MbInfo& mb) {
        tc_luma[static_cast<size_t>(((mby * out.mb_w + mbx) * 16) + ly * 4 + lx)] = v;
        mb.nonzero = mb.nonzero || (v > 0);
    };
    auto tcat_c = [&](int plane, int mbx, int mby, int lx, int ly) -> int* {
        if (mbx < 0 || mby < 0 || mbx >= out.mb_w || mby >= out.mb_h || lx < 0 || ly < 0 || lx > 1 || ly > 1) return nullptr;
        int& v = tc_chr[plane][static_cast<size_t>(((mby * out.mb_w + mbx) * 4) + ly * 2 + lx)];
        return (v < 0) ? nullptr : &v;
    };
    auto tcset_c = [&](int plane, int mbx, int mby, int lx, int ly, int v, MbInfo& mb) {
        tc_chr[plane][static_cast<size_t>(((mby * out.mb_w + mbx) * 4) + ly * 2 + lx)] = v;
        mb.nonzero = mb.nonzero || (v > 0);
    };
    auto parse_chr = [&](int mbx, int mby, int cbp_c, MbInfo& mb) {
        if (cbp_c) {
            auto dc0 = cavlc::residualBlock(br, -1, 4);
            auto dc1 = cavlc::residualBlock(br, -1, 4);
            if (!dc0.ok || !dc1.ok) throw std::runtime_error("real P chroma DC parse failed");
            mb.nonzero = mb.nonzero || dc0.total_coeff > 0 || dc1.total_coeff > 0;
        }
        if (cbp_c == 2) {
            for (int p = 0; p < 2; ++p) {
                for (int b = 0; b < 4; ++b) {
                    int lx, ly;
                    walk_detail::chrXY(b, lx, ly);
                    int* nA = (lx > 0) ? tcat_c(p, mbx, mby, lx - 1, ly) : tcat_c(p, mbx - 1, mby, 1, ly);
                    int* nB = (ly > 0) ? tcat_c(p, mbx, mby, lx, ly - 1) : tcat_c(p, mbx, mby - 1, lx, 1);
                    auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 15);
                    if (!r.ok) throw std::runtime_error("real P chroma AC parse failed");
                    tcset_c(p, mbx, mby, lx, ly, r.total_coeff, mb);
                }
            }
        } else {
            for (int p = 0; p < 2; ++p)
                for (int b = 0; b < 4; ++b) {
                    int lx, ly;
                    walk_detail::chrXY(b, lx, ly);
                    tcset_c(p, mbx, mby, lx, ly, 0, mb);
                }
        }
    };
    auto parse_luma = [&](int mbx, int mby, int cbp_l, int max_coeff, MbInfo& mb) {
        for (int i8 = 0; i8 < 4; ++i8) {
            if ((cbp_l >> i8) & 1) {
                for (int i4 = 0; i4 < 4; ++i4) {
                    int lx, ly;
                    walk_detail::blkXY(i8, i4, lx, ly);
                    int* nA = (lx > 0) ? tcat_l(mbx, mby, lx - 1, ly) : tcat_l(mbx - 1, mby, 3, ly);
                    int* nB = (ly > 0) ? tcat_l(mbx, mby, lx, ly - 1) : tcat_l(mbx, mby - 1, lx, 3);
                    auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), max_coeff);
                    if (!r.ok) throw std::runtime_error("real P luma residual parse failed");
                    tcset_l(mbx, mby, lx, ly, r.total_coeff, mb);
                }
            } else {
                for (int i4 = 0; i4 < 4; ++i4) {
                    int lx, ly;
                    walk_detail::blkXY(i8, i4, lx, ly);
                    tcset_l(mbx, mby, lx, ly, 0, mb);
                }
            }
        }
    };
    auto parse_intra = [&](int mbx, int mby, uint32_t mt, MbInfo& mb, int& qp) {
        const uint32_t it = mt - 5;
        mb.kind = MbKind::Intra;
        mb.part = (it == 0) ? PART_I_NXN : PART_I16X16;
        if (it == 0) {
            for (int k = 0; k < 16; ++k) if (br.u(1) == 0) br.u(3);
            br.ue();
            uint32_t code = br.ue();
            if (code >= 48) throw std::runtime_error("real P intra CBP code out of range");
            mb.cbp = walk_detail::kMeIntra[code];
            if (mb.cbp) applyQpDelta(qp, br.se());
            mb.qp = qp;
            parse_luma(mbx, mby, mb.cbp & 15, 16, mb);
            parse_chr(mbx, mby, mb.cbp >> 4, mb);
        } else {
            int x = static_cast<int>(it) - 1;
            int cbp_c = (x / 4) % 3;
            int cbp_l = (x / 12) ? 15 : 0;
            mb.cbp = cbp_l | (cbp_c << 4);
            br.ue();
            applyQpDelta(qp, br.se());
            mb.qp = qp;
            auto dc = cavlc::residualBlock(br, walk_detail::ncFrom(tcat_l(mbx - 1, mby, 3, 0), tcat_l(mbx, mby - 1, 0, 3)), 16);
            if (!dc.ok) throw std::runtime_error("real P/I16 DC residual parse failed");
            mb.nonzero = mb.nonzero || dc.total_coeff > 0;
            parse_luma(mbx, mby, cbp_l, 15, mb);
            parse_chr(mbx, mby, cbp_c, mb);
        }
        ++out.intra_mbs;
    };

    int qp = sd.slice_qp;
    for (int mb_addr = 0; mb_addr < out.total_mbs;) {
        const uint32_t skip_run = br.ue();
        ++out.syntax_groups;
        bool had_skip_group = false;
        if (skip_run > 0) {
            had_skip_group = true;
            for (uint32_t k = 0; k < skip_run && mb_addr + static_cast<int>(k) < out.total_mbs; ++k) {
                int cur = mb_addr + static_cast<int>(k);
                int mbx = cur % out.mb_w;
                int mby = cur / out.mb_w;
                MbInfo mb;
                mb.kind = MbKind::Skip;
                mb.part = PART_P_SKIP;
                mb.qp = qp;
                out.qp_min = std::min(out.qp_min, mb.qp);
                out.qp_max = std::max(out.qp_max, mb.qp);
                out.mbs[static_cast<size_t>(cur)] = mb;
                setMbCoeffZero(tc_luma, tc_chr, out.mb_w, mbx, mby);
            }
            out.skipped_mbs += static_cast<int>(skip_run);
            mb_addr += static_cast<int>(skip_run);
            if (mb_addr >= out.total_mbs) break;
        }
        if (had_skip_group)
            ++out.syntax_groups;
        int mbx = mb_addr % out.mb_w;
        int mby = mb_addr / out.mb_w;
        MbInfo mb;
        const uint32_t mt = br.ue();
        if (mt <= 4) {
            mb.kind = MbKind::Inter;
            int mvd_pairs = 0;
            if (mt == 0) { mb.part = PART_P16X16; mvd_pairs = 1; ++out.p16x16; }
            else if (mt == 1) { mb.part = PART_P16X8; mvd_pairs = 2; ++out.p16x8; }
            else if (mt == 2) { mb.part = PART_P8X16; mvd_pairs = 2; ++out.p8x16; }
            else {
                mb.part = PART_P8X8; ++out.p8x8;
                for (int s = 0; s < 4; ++s) {
                    uint32_t sub = br.ue();
                    if (sub > 3) throw std::runtime_error("real P sub_mb_type out of range");
                    mvd_pairs += (sub == 0) ? 1 : (sub == 3 ? 4 : 2);
                }
            }
            for (int p = 0; p < mvd_pairs; ++p) {
                int dx = br.se();
                int dy = br.se();
                if (p == 0) { mb.mvx = dx; mb.mvy = dy; }
            }
            mb.cbp = cbpInterMap(br.ue());
            if (mb.cbp) applyQpDelta(qp, br.se());
            mb.qp = qp;
            parse_luma(mbx, mby, mb.cbp & 15, 16, mb);
            parse_chr(mbx, mby, mb.cbp >> 4, mb);
            ++out.inter_mbs;
        } else {
            parse_intra(mbx, mby, mt, mb, qp);
        }
        out.qp_min = std::min(out.qp_min, mb.qp);
        out.qp_max = std::max(out.qp_max, mb.qp);
        out.mbs[static_cast<size_t>(mb_addr)] = mb;
        ++mb_addr;
    }
    if (!br.ok) throw std::runtime_error("real P fixture bitreader failed during MB walk");
    if (out.skipped_mbs + out.inter_mbs + out.intra_mbs != out.total_mbs)
        throw std::runtime_error("real P fixture MB accounting mismatch");
    return out;
}

inline bool isIntra(const MbInfo& mb) { return mb.kind == MbKind::Intra; }
inline bool isSkip(const MbInfo& mb) { return mb.kind == MbKind::Skip; }
inline bool isInter(const MbInfo& mb) { return mb.kind == MbKind::Inter; }

} // namespace h264_real_p_scope
