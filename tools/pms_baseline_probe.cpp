#include "../assets/plex-profiles/fpga_profile.hpp"
#include "libmisterplex/h264_cavlc.hpp"

#include <algorithm>
#include <array>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <numeric>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using misterplex::detail::BitReader;
using misterplex::FpgaPmsProfile;
constexpr size_t kTransportMaxAuBytes = misterplex::ddr_bitstream_ring::kMaxAccessUnitBytes;
void require(bool ok, const std::string& reason) {
    if (!ok) throw std::runtime_error(reason);
}
unsigned u(BitReader& b, int n) {
    require(n >= 0 && n <= 32, "invalid bit width");
    auto v = b.u(n); require(b.ok, "truncated RBSP"); return v;
}
unsigned ue(BitReader& b) {
    auto v = b.ue(); require(b.ok, "truncated/oversized Exp-Golomb"); return v;
}
int se(BitReader& b) {
    auto v = b.se(); require(b.ok, "truncated signed Exp-Golomb"); return v;
}
void trailing(BitReader& b) {
    require(u(b, 1) == 1, "missing rbsp_stop_one_bit / unsupported MB syntax");
    while (b.bit % 8) require(u(b, 1) == 0, "nonzero RBSP alignment");
    while (b.bit < b.n * 8) require(u(b, 8) == 0, "unconsumed RBSP bytes");
}
struct Sps {
    unsigned id = 0, refs = 0, frameBits = 0, poc = 0, pocBits = 0;
    unsigned w = 0, h = 0, dw = 0, dh = 0, level = 0;
    std::array<unsigned, 4> crop{};
    unsigned sarNum = 0, sarDen = 0, tick = 0, scale = 0;
    bool sarPresent = false;
    bool videoSignalPresent = false, fullRange = false, colourDescriptionPresent = false;
    unsigned videoFormat = 5, colourPrimaries = 2, transferCharacteristics = 2, matrixCoefficients = 2;
};
struct Pps {
    unsigned id = 0, sps = 0;
    int qp = 26, chromaQp = 0;
    bool deblock = false, constrained = false;
};
struct Stats {
    unsigned spsCount = 0, ppsCount = 0, frames = 0, idr = 0, p = 0, intra = 0;
    unsigned lastIdr = 0, maxGop = 0;
    size_t maxAu = 0;
    size_t maxVclRbsp = 0;
    uint64_t mb = 0, i16 = 0, i4 = 0, p16 = 0, skip = 0, blocks = 0, nonzero = 0, coeffs = 0;
    int minQp = 51, maxQp = 0, minDelta = 0, maxDelta = 0, minLevel = 0, maxLevel = 0;
    int maxMvd = 0;
    std::array<uint64_t, 4> modes{}, chroma{};
    std::array<uint64_t, 9> modes4{};
    std::array<uint64_t, 3> deblock{};
    std::map<int, uint64_t> cbp;
    std::map<unsigned, uint64_t> picturesBySps;
};
Sps parseSps(BitReader& b, const FpgaPmsProfile& c) {
    Sps s;
    unsigned profile = u(b, 8);
    require(profile == 66, "profile_idc=" + std::to_string(profile) + ", expected 66");
    const unsigned constraints = u(b, 8);
    require((constraints & 3) == 0, "SPS reserved constraint bits");
    require(constraints & 0x40, "constraint_set1_flag=0 outside constrained Baseline contract");
    s.level = u(b, 8); require(s.level <= 30, "level_idc exceeds 30");
    s.id = ue(b); require(s.id <= 31, "SPS id");
    s.frameBits = ue(b) + 4; require(s.frameBits <= 16, "frame_num width");
    s.poc = ue(b); require(s.poc == 0 || s.poc == 2, "POC type1 unsupported");
    if (s.poc == 0) { s.pocBits = ue(b) + 4; require(s.pocBits <= 16, "POC width"); }
    s.refs = ue(b);
    require(c.allIdr ? s.refs <= 1 : s.refs == 1,
            "max_num_ref_frames=" + std::to_string(s.refs) + ", expected " +
            (c.allIdr ? "0..1 for all-IDR" : "1"));
    require(!u(b, 1), "frame_num gaps unsupported");
    auto wm = ue(b), hm = ue(b);
    require(wm < 80 && hm < 45, "coded rectangle exceeds reserved720 bound");
    s.w = (wm + 1) * 16; s.h = (hm + 1) * 16;
    require(u(b, 1), "interlaced coded pictures unsupported");
    u(b, 1);
    if (u(b, 1)) for (auto& v : s.crop) v = ue(b);
    uint64_t cx = 2ull * (s.crop[0] + uint64_t(s.crop[1]));
    uint64_t cy = 2ull * (s.crop[2] + uint64_t(s.crop[3]));
    require(cx < s.w && cy < s.h, "invalid crop rectangle");
    s.dw = s.w - cx; s.dh = s.h - cy;
    require(s.w <= unsigned(c.width) && s.h <= unsigned(c.height),
            "coded=" + std::to_string(s.w) + "x" + std::to_string(s.h) +
            " exceeds declared " + c.videoResolution + " cap");
    if (u(b, 1)) {
        if (u(b, 1)) {
            s.sarPresent = true;
            unsigned ar = u(b, 8);
            static const unsigned sar[][2] = {
                {0,0},{1,1},{12,11},{10,11},{16,11},{40,33},{24,11},{20,11},
                {32,11},{80,33},{18,11},{15,11},{64,33},{160,99},{4,3},{3,2},{2,1}};
            if (ar == 255) { s.sarNum = u(b, 16); s.sarDen = u(b, 16); }
            else if (ar != 0) {
                require(ar > 0 && ar < 17, "unspecified/reserved SAR");
                s.sarNum = sar[ar][0]; s.sarDen = sar[ar][1];
            }
            if (ar != 0) require(s.sarNum && s.sarDen, "zero SAR");
        }
        if (u(b, 1)) u(b, 1);
        if (u(b, 1)) {
            s.videoSignalPresent = true;
            s.videoFormat = u(b, 3);
            s.fullRange = u(b, 1);
            if (u(b, 1)) {
                s.colourDescriptionPresent = true;
                s.colourPrimaries = u(b, 8);
                s.transferCharacteristics = u(b, 8);
                s.matrixCoefficients = u(b, 8);
            }
        }
        if (u(b, 1)) { require(ue(b) <= 5 && ue(b) <= 5, "chroma sample location"); }
        if (u(b, 1)) {
            s.tick = u(b, 32); s.scale = u(b, 32); u(b, 1);
            require(s.tick && s.scale &&
                uint64_t(s.scale) * c.fpsDen == uint64_t(s.tick) * 2 * c.fpsNum,
                "VUI film rate differs from declared contract");
        }
        require(!u(b, 1), "NAL HRD outside supported syntax");
        require(!u(b, 1), "VCL HRD outside supported syntax");
        require(!u(b, 1), "pic_struct_present_flag outside supported syntax");
        if (u(b, 1)) {
            u(b, 1); ue(b); ue(b); ue(b); ue(b);
            require(ue(b) == 0, "VUI reordering unsupported");
            require(ue(b) <= 1, "VUI DPB exceeds1");
        }
    }
    trailing(b); return s;
}
bool moreRbsp(const BitReader& b) {
    auto copy = b;
    if (!copy.ok || copy.bit == copy.n * 8) return false;
    if (!copy.u(1)) return true;
    while (copy.bit < copy.n * 8) if (copy.u(1)) return true;
    return false;
}
Pps parsePps(BitReader& b) {
    Pps p;
    p.id = ue(b); p.sps = ue(b); require(p.id <= 255 && p.sps <= 31, "PPS ids");
    require(!u(b, 1), "entropy_cabac=1, expected 0");
    require(!u(b, 1), "bottom-field POC unsupported");
    require(ue(b) == 0, "slice groups unsupported");
    require(ue(b) == 0 && ue(b) == 0, "active references exceed1");
    require(!u(b, 1), "weighted_pred_flag=1 unsupported");
    require(u(b, 2) == 0, "weighted_bipred unsupported");
    p.qp = 26 + se(b); require(p.qp >= 0 && p.qp <= 51, "PPS QP invalid");
    se(b); p.chromaQp = se(b); require(std::abs(p.chromaQp) <= 12, "chroma QP offset");
    p.deblock = u(b, 1); p.constrained = u(b, 1);
    require(!p.constrained, "constrained_intra_pred outside requested experiment");
    require(!u(b, 1), "redundant pictures unsupported");
    if (moreRbsp(b)) {
        require(!u(b, 1), "8x8 transform unsupported");
        require(!u(b, 1), "scaling matrix unsupported");
        require(se(b) == p.chromaQp, "separate chroma QP offset unsupported");
    }
    trailing(b); return p;
}

// Syntax-only CAVLC walk. Keep levels wide; never saturate to match FPGA shortcuts.
int residual(BitReader& b, int nc, int maxCoeff, Stats& st) {
    namespace t = misterplex::cavlc::tables;
    auto vlc = [&](const uint8_t* lens, const uint8_t* bits, int n) {
        int index = 0;
        require(t::matchMap(b, lens, bits, n, index) && b.ok, "invalid CAVLC VLC");
        return index;
    };
    int tab = nc < 2 ? 0 : nc < 4 ? 1 : nc < 8 ? 2 : 3;
    int token = nc == -1 ? vlc(t::chroma_dc_len, t::chroma_dc_bits, 20)
                        : vlc(t::coeff_token_len[tab], t::coeff_token_bits[tab], 68);
    int tc = token / 4, ones = token % 4;
    require(tc <= maxCoeff && ones <= tc, "invalid CAVLC coefficient token");
    ++st.blocks; st.coeffs += tc; st.nonzero += tc != 0;
    if (!tc) return 0;
    for (int i = 0; i < ones; ++i) {
        int level = u(b, 1) ? -1 : 1;
        st.minLevel = std::min(st.minLevel, level); st.maxLevel = std::max(st.maxLevel, level);
    }
    int suffix = tc > 10 && ones < 3 ? 1 : 0;
    for (int i = ones; i < tc; ++i) {
        int prefix = 0;
        while (!u(b, 1)) require(++prefix <= 28, "CAVLC level prefix exceeds bounded syntax");
        int suffixBits = prefix == 14 && !suffix ? 4 : prefix >= 15 ? prefix - 3 : suffix;
        int64_t code = (int64_t(std::min(prefix, 15)) << suffix) + u(b, suffixBits);
        if (prefix >= 15 && !suffix) code += 15;
        if (prefix >= 16) code += (int64_t(1) << (prefix - 3)) - 4096;
        if (i == ones && ones < 3) code += 2;
        int64_t level = code & 1 ? -(code + 1) / 2 : (code + 2) / 2;
        require(level >= -32768 && level <= 32767, "residual exceeds signed16 contract");
        st.minLevel = std::min(st.minLevel, int(level)); st.maxLevel = std::max(st.maxLevel, int(level));
        if (!suffix) suffix = 1;
        if (suffix < 6 && std::abs(level) > (3 << (suffix - 1))) ++suffix;
    }
    int zeros = 0;
    if (tc < maxCoeff)
        zeros = maxCoeff == 4 ? vlc(t::chroma_tz_len[tc-1], t::chroma_tz_bits[tc-1], 4)
                              : vlc(t::total_zeros_len[tc-1], t::total_zeros_bits[tc-1], 17-tc);
    require(zeros + tc <= maxCoeff, "CAVLC total_zeros overflow");
    for (int i = 0; i < tc - 1 && zeros; ++i) {
        int run;
        if (zeros < 7) run = vlc(t::run_len[zeros-1], t::run_bits[zeros-1], zeros+1);
        else {
            int v = u(b, 3); run = 7 - v;
            if (!v) while (!u(b, 1)) require(++run <= 15, "CAVLC run overflow");
        }
        require(run <= zeros, "CAVLC run exceeds zeros"); zeros -= run;
    }
    return tc;
}
void macroblocks(BitReader& b, const Sps& s, bool isP, int qp, Stats& st) {
    const int width = s.w / 16, count = width * (s.h / 16);
    std::vector<int> luma(count * 16, -1), pred(count * 16, -1), chroma[2]{
        std::vector<int>(count * 4, -1), std::vector<int>(count * 4, -1)};
    auto at = [&](std::vector<int>& map, int dim, int x, int y) {
        if (x < 0 || y < 0 || x >= width * dim || y >= int(s.h / 16) * dim) return -1;
        return map[((y/dim)*width+x/dim)*dim*dim+(y%dim)*dim+x%dim];
    };
    auto nc = [&](std::vector<int>& map, int dim, int x, int y) {
        int a = at(map, dim, x-1, y), bval = at(map, dim, x, y-1);
        return a < 0 ? std::max(0, bval) : bval < 0 ? a : (a + bval + 1)/2;
    };
    static const int interCbp[48] = {
        0,16,1,2,4,8,32,3,5,10,12,15,47,7,11,13,14,6,9,31,35,37,42,44,
        33,34,36,40,39,43,45,46,17,18,20,24,19,21,26,28,23,27,29,30,22,25,38,41};
    static const int intraCbp[48] = {
        47,31,15,0,23,27,29,30,7,11,13,14,39,43,45,46,16,3,5,10,12,19,21,26,
        28,35,37,42,44,1,2,4,8,17,18,20,24,6,9,22,25,32,33,34,36,40,38,41};
    int mb = 0;
    while (mb < count) {
        if (isP) {
            unsigned run = ue(b); require(run <= unsigned(count-mb), "mb_skip_run exceeds picture");
            for (unsigned i = 0; i < run; ++i, ++mb) {
                std::fill_n(luma.begin()+mb*16, 16, 0);
                std::fill_n(pred.begin()+mb*16, 16, 2);
                for (auto& plane : chroma) std::fill_n(plane.begin()+mb*4, 4, 0);
                ++st.skip; ++st.mb;
                st.minQp = std::min(st.minQp, qp); st.maxQp = std::max(st.maxQp, qp);
            }
            if (mb == count) break;
        }
        int mt = ue(b), cbp = 0;
        const int mx = mb % width, my = mb / width;
        const bool intra = !isP || mt >= 5;
        if (isP && intra) mt -= 5;
        bool i16 = intra && mt != 0;
        std::fill_n(pred.begin()+mb*16, 16, 2);
        if (intra) {
            require(mt >= 0 && mt <= 24,
                    mt == 25 ? "I_PCM unsupported (not compressed prototype)" :
                               "unsupported intra MB");
            if (i16) {
                ++st.i16; ++st.modes[(mt-1)%4];
                cbp = ((mt-1)/12 ? 15 : 0) | (((mt-1)/4)%3 << 4);
            } else {
                ++st.i4;
                for (int i8 = 0; i8 < 4; ++i8)
                    for (int i4 = 0; i4 < 4; ++i4) {
                        int x = (i8%2)*2+i4%2, y = (i8/2)*2+i4/2;
                        int a = at(pred, 4, mx*4+x-1, my*4+y);
                        int bv = at(pred, 4, mx*4+x, my*4+y-1);
                        int predicted = a < 0 || bv < 0 ? 2 : std::min(a, bv);
                        int actual = predicted;
                        if (!u(b, 1)) { int rem = u(b, 3); actual = rem + (rem >= predicted); }
                        require(actual <= 8, "I4 prediction mode");
                        pred[mb*16+y*4+x] = actual; ++st.modes4[actual];
                    }
            }
            unsigned mode = ue(b); require(mode <= 3, "chroma prediction mode"); ++st.chroma[mode];
            if (!i16) {
                unsigned code = ue(b); require(code < 48, "invalid intra CBP"); cbp = intraCbp[code];
            }
        } else {
            require(mt == 0, "P partition unsupported: only P16x16 and Pskip");
            ++st.p16;
            int x = se(b), y = se(b);
            require(std::abs(x) <= 32767 && std::abs(y) <= 32767, "MVD exceeds signed16");
            st.maxMvd = std::max({st.maxMvd, std::abs(x), std::abs(y)});
            unsigned code = ue(b); require(code < 48, "invalid inter CBP"); cbp = interCbp[code];
        }
        ++st.cbp[cbp];
        if (i16 || cbp) {
            int delta = se(b); require(delta >= -26 && delta <= 25, "mb_qp_delta out of range");
            st.minDelta = std::min(st.minDelta, delta); st.maxDelta = std::max(st.maxDelta, delta);
            qp = (qp + delta + 52) % 52;
        }
        st.minQp = std::min(st.minQp, qp); st.maxQp = std::max(st.maxQp, qp);
        require(qp >= 10 && qp <= 40, "macroblock QP outside10..40 contract");
        if (i16) residual(b, nc(luma, 4, mx*4, my*4), 16, st);
        for (int i8 = 0; i8 < 4; ++i8)
            for (int i4 = 0; i4 < 4; ++i4) {
                int x = (i8%2)*2+i4%2, y = (i8/2)*2+i4/2;
                int tc = cbp & (1<<i8) ? residual(b, nc(luma, 4, mx*4+x, my*4+y),
                                                 i16 ? 15 : 16, st) : 0;
                luma[mb*16+y*4+x] = tc;
            }
        const int cc = cbp >> 4;
        if (cc) { residual(b, -1, 4, st); residual(b, -1, 4, st); }
        for (auto& plane : chroma)
            for (int k = 0; k < 4; ++k)
                plane[mb*4+k] = cc == 2 ? residual(b, nc(plane, 2, mx*2+k%2, my*2+k/2), 15, st) : 0;
        ++mb; ++st.mb;
    }
    trailing(b);
}
void slice(BitReader& b, unsigned type, unsigned ref, const std::map<unsigned,Sps>& sps,
           const std::map<unsigned,Pps>& pps, const FpgaPmsProfile& c, Stats& st) {
    require(ue(b) == 0, "multiple/partial slices unsupported (one complete slice per AU)");
    unsigned cls = ue(b); require(cls <= 9, "invalid slice_type"); cls %= 5;
    require(cls == 0 || cls == 2, cls == 1 ? "b_slices=1, expected 0" : "SP/SI unsupported");
    require(type != 5 || cls == 2, "IDR must be I slice");
    require(!c.allIdr || type == 5, "all-IDR contract emitted non-IDR");
    auto pi = pps.find(ue(b)); require(pi != pps.end(), "slice references missing PPS");
    const auto& p = pi->second;
    auto si = sps.find(p.sps); require(si != sps.end(), "PPS references missing SPS");
    const auto& s = si->second;
    unsigned frameNum = u(b, s.frameBits);
    if (type == 5) { require(frameNum == 0, "IDR frame_num nonzero"); ue(b); }
    if (s.poc == 0) u(b, s.pocBits);
    if (cls == 0) {
        if (u(b, 1)) require(ue(b) == 0, "slice active references exceed1");
        require(!u(b, 1), "reference list modification unsupported");
    }
    require(ref != 0, "non-reference VCL outside bounded prototype");
    if (type == 5) {
        u(b, 1); require(!u(b, 1), "long-term IDR reference unsupported");
    } else require(!u(b, 1), "adaptive reference marking unsupported");
    int qp = p.qp + se(b); require(qp >= 10 && qp <= 40, "slice QP outside10..40 contract");
    unsigned deblock = p.deblock ? ue(b) : 0; require(deblock <= 2, "invalid deblock_idc");
    if (p.deblock && deblock != 1) {
        int alpha = se(b), beta = se(b);
        require(alpha == 0 && beta == 0, "nonzero deblock offsets outside experiment");
    }
    require(c.filteringOff ? deblock == 1 : deblock == 0,
            "emitted deblocking policy differs from requested filter-" +
            std::string(c.filteringOff ? "off" : "on"));
    ++st.deblock[deblock];
    require(st.frames || type == 5, "capture does not begin with IDR");
    if (type == 5) {
        if (st.frames) st.maxGop = std::max(st.maxGop, st.frames-st.lastIdr);
        st.lastIdr = st.frames; ++st.idr;
    } else require(st.frames-st.lastIdr < unsigned(c.maxGop), "GOP exceeds contract");
    ++st.frames; cls == 0 ? ++st.p : ++st.intra;
    macroblocks(b, s, cls == 0, qp, st);
    ++st.picturesBySps[s.id];
}
std::vector<std::pair<size_t,size_t>> nals(const std::vector<uint8_t>& data) {
    std::vector<std::pair<size_t,size_t>> out;
    for (size_t i = 0; i + 3 <= data.size();) {
        size_t sc = i+4 <= data.size() && !data[i] && !data[i+1] && !data[i+2] && data[i+3]==1 ? 4 :
                    !data[i] && !data[i+1] && data[i+2]==1 ? 3 : 0;
        if (sc) { out.emplace_back(i, sc); i += sc; } else ++i;
    }
    return out;
}
int usage() {
    std::cerr << "usage: pms_baseline_probe --annexb FILE --prototype idr|ip"
                 " [--mode 240p|480p|480i|720p] [--fps 24|24000/1001]"
                 " [--filter on|off] [--reserved-experiment] [--require-full-size] [--json FILE]\n"
                 "       [--max-au-bytes N] (use --probe-contract for transport ceiling;\n"
                 "       lower to the advertised encoded-AU capacity)\n"
                 "       [--max-vcl-rbsp-bytes N] (independent de-escaped VCL payload limit)\n"
                 "       [--require-limited-bt601] (unknown matrix is not scanout qualification)\n"
                 "Live capture: tests/hw/test_pms_baseline_profile.sh (secret-safe config/env).\n";
    return 2;
}
} // namespace
int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--probe-abi") {
        std::cout << "6\n";
        return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--probe-contract") {
        std::cout << "{\"abi\":6,\"max_au_bytes\":" << kTransportMaxAuBytes << "}\n";
        return 0;
    }
    std::string path, prototype = "ip", mode = "240p", fps = "24", filter = "on", json;
    std::size_t maxAuBytes = kTransportMaxAuBytes;
    std::size_t maxVclRbspBytes = 0;
    bool reserved = false, full = false, requireColor = false;
    try {
        for (int i = 1; i < argc; ++i) {
            std::string a = argv[i];
            if (a == "--reserved-experiment") { reserved = true; continue; }
            if (a == "--require-full-size") { full = true; continue; }
            if (a == "--require-limited-bt601") { requireColor = true; continue; }
            if (a == "--help") return usage();
            if (++i == argc) return usage();
            std::string v = argv[i];
            if (a == "--annexb") path = v;
            else if (a == "--prototype") prototype = v;
            else if (a == "--mode") mode = v;
            else if (a == "--fps") fps = v;
            else if (a == "--filter") filter = v;
            else if (a == "--json") json = v;
            else if (a == "--max-au-bytes") {
                require(!v.empty() && v.find_first_not_of("0123456789") == std::string::npos,
                        "max AU bytes must be a positive integer");
                maxAuBytes = std::stoull(v);
                require(maxAuBytes > 0 && maxAuBytes <= kTransportMaxAuBytes,
                        "max AU bytes exceeds" + std::to_string(kTransportMaxAuBytes) +
                        " transport ceiling or is zero");
            } else if (a == "--max-vcl-rbsp-bytes") {
                require(!v.empty() && v.find_first_not_of("0123456789") == std::string::npos,
                        "max VCL RBSP bytes must be a positive integer");
                maxVclRbspBytes = std::stoull(v);
                require(maxVclRbspBytes > 0 && maxVclRbspBytes <= kTransportMaxAuBytes,
                        "max VCL RBSP bound is zero or exceeds the transport envelope");
            }
            else return usage();
        }
        if (path.empty() || (fps != "24" && fps != "24/1" && fps != "24000/1001") ||
            (filter != "on" && filter != "off")) return usage();
        FpgaPmsProfile c; std::string why;
        const bool selected = misterplex::selectFpgaPmsProfile(prototype, mode,
            fps == "24000/1001" ? 24000 : 24, fps == "24000/1001" ? 1001 : 1,
            filter == "off", c, &why, reserved);
        require(selected, why);
        c.maxAuBytes = maxAuBytes;
        std::ifstream in(path, std::ios::binary | std::ios::ate);
        require(bool(in), "cannot read Annex-B capture");
        auto size = in.tellg(); require(size > 0 && size <= (64 << 20), "capture size must be1..64MiB");
        in.seekg(0); std::vector<uint8_t> data(static_cast<size_t>(size));
        require(bool(in.read(reinterpret_cast<char*>(data.data()), size)), "short capture read");
        auto ns = nals(data); require(!ns.empty() && ns[0].first == 0, "missing Annex-B start");
        Stats st; std::map<unsigned,Sps> sps; std::map<unsigned,Pps> pps;
        std::map<unsigned,std::vector<uint8_t>> spsBytes, ppsBytes;
        size_t auBytes = 0; bool hasVcl = false;
        for (size_t i = 0; i < ns.size(); ++i) {
            size_t start = ns[i].first+ns[i].second, end = i+1 < ns.size() ? ns[i+1].first : data.size();
            require(start < end, "empty NAL");
            uint8_t h = data[start]; require(!(h & 128), "forbidden_zero_bit");
            unsigned type = h & 31;
            if (hasVcl && (type == 1 || type == 5 || type == 6 || type == 7 || type == 8 || type == 9)) {
                st.maxAu = std::max(st.maxAu, auBytes); auBytes = 0; hasVcl = false;
            }
            auBytes += end-ns[i].first;
            require(auBytes <= c.maxAuBytes, "AU exceeds selected bound=" +
                    std::to_string(c.maxAuBytes) + " bytes");
            auto rbsp = misterplex::detail::removeEpb(data.data()+start+1, end-start-1);
            BitReader b(rbsp.data(), rbsp.size());
            if (type == 7) {
                auto s = parseSps(b, c);
                require(!spsBytes.count(s.id) || spsBytes[s.id] == rbsp,
                        "SPS replacement requires a separately qualified stream epoch");
                spsBytes[s.id] = rbsp;
                if (full) require(s.w == unsigned(c.width) && s.h == unsigned(c.height) &&
                                  s.dw == unsigned(c.width) && s.dh == unsigned(c.height),
                                  "not a full-sized decoded/visible tier picture: coded=" +
                                  std::to_string(s.w) + "x" + std::to_string(s.h) +
                                  " visible=" + std::to_string(s.dw) + "x" + std::to_string(s.dh) +
                                  ", required=" + c.videoResolution);
                sps[s.id] = s; ++st.spsCount;
            } else if (type == 8) {
                auto p = parsePps(b);
                require(!ppsBytes.count(p.id) || ppsBytes[p.id] == rbsp,
                        "PPS replacement requires a separately qualified stream epoch");
                ppsBytes[p.id] = rbsp; pps[p.id] = p; ++st.ppsCount;
            } else if (type == 1 || type == 5) {
                st.maxVclRbsp = std::max(st.maxVclRbsp, rbsp.size());
                require(!maxVclRbspBytes || rbsp.size() <= maxVclRbspBytes,
                        "VCL RBSP exceeds selected bound=" + std::to_string(maxVclRbspBytes) + " bytes");
                slice(b, type, (h>>5)&3, sps, pps, c, st); hasVcl = true;
            } else require(type == 6 || type == 9 || type == 10 || type == 11 || type == 12,
                           "unsupported NAL type");
        }
        st.maxAu = std::max(st.maxAu, auBytes);
        st.maxGop = std::max(st.maxGop, st.frames-st.lastIdr);
        require(st.frames > 1 && !sps.empty() && !pps.empty(), "incomplete multi-picture stream");
        require(c.allIdr || st.p > 0, "IP experiment has no P picture");
        require(st.nonzero > 0, "no normally compressed residual content observed");
        bool colorSignalingOk = true;
        for (const auto& entry : sps) {
            const auto& s = entry.second;
            colorSignalingOk &= !s.fullRange && (s.matrixCoefficients == 5 || s.matrixCoefficients == 6);
        }
        std::cout << "PMS_BASELINE_CONTRACT profile=" << c.clientProfileName
                  << " cap=" << c.videoResolution << " reserved=" << c.reserved << "\n";
        for (const auto& entry : sps) {
            const auto& s = entry.second;
            std::cout << "PMS_BASELINE_DELIVERED sps=" << s.id << " profile_idc=66 level_idc=" << s.level
                      << " entropy_cabac=0 max_num_ref_frames=" << s.refs << " poc_type=" << s.poc
                      << " coded=" << s.w << "x" << s.h << " display=" << s.dw << "x" << s.dh
                      << " crop_lrtb=" << s.crop[0] << "," << s.crop[1] << "," << s.crop[2] << "," << s.crop[3]
                      << " mb_columns=" << s.w/16 << " mb_rows=" << s.h/16
                      << " mb_per_picture=" << (s.w/16)*(s.h/16)
                      << " packed_i420_strides=" << s.w << "/" << s.w/2
                      << " sar_present=" << s.sarPresent << " sar=" << s.sarNum << "/" << s.sarDen
                      << " video_signal_present=" << s.videoSignalPresent
                      << " full_range=" << s.fullRange
                      << " colour_description_present=" << s.colourDescriptionPresent
                      << " colour_primaries=" << s.colourPrimaries
                      << " transfer_characteristics=" << s.transferCharacteristics
                      << " matrix_coefficients=" << s.matrixCoefficients
                      << " vui=" << s.scale << "/" << 2ull*s.tick << "\n";
        }
        std::cout << "PMS_BASELINE_SLICES frames=" << st.frames << " idr=" << st.idr << " i=" << st.intra
                  << " p=" << st.p << " b=0 max_gop=" << st.maxGop << " max_au_bytes=" << st.maxAu
                  << " au_limit=" << c.maxAuBytes << " au_headroom_bytes=" << c.maxAuBytes-st.maxAu
                  << " max_vcl_rbsp_bytes=" << st.maxVclRbsp
                  << " bytes=" << data.size() << " deblock_0_1_2=" << st.deblock[0] << ","
                  << st.deblock[1] << "," << st.deblock[2] << "\n"
                  << "PMS_BASELINE_MB count=" << st.mb << " I16=" << st.i16 << " P16=" << st.p16
                  << " skip=" << st.skip << " I4=" << st.i4 << " PCM=0 qp=" << st.minQp << ".." << st.maxQp
                  << " qp_delta=" << st.minDelta << ".." << st.maxDelta
                  << " residual_blocks=" << st.blocks << " nonzero_blocks=" << st.nonzero
                  << " coefficients=" << st.coeffs << " level=" << st.minLevel << ".." << st.maxLevel
                  << " max_abs_mvd=" << st.maxMvd << "\nPMS_BASELINE_MODES i16=";
        for (auto v : st.modes) std::cout << v << ",";
        std::cout << " i4="; for (auto v : st.modes4) std::cout << v << ",";
        std::cout << " chroma="; for (auto v : st.chroma) std::cout << v << ",";
        std::cout << " cbp="; for (auto v : st.cbp) std::cout << v.first << ":" << v.second << ",";
        std::cout << "\n";
        if (!json.empty()) {
            std::ofstream out(json);
            out << "{\"syntax_complete\":true,\"frames\":" << st.frames << ",\"max_au_bytes\":" << st.maxAu
                << ",\"au_limit_bytes\":" << c.maxAuBytes
                << ",\"max_vcl_rbsp_bytes\":" << st.maxVclRbsp
                << ",\"bytes\":" << data.size() << ",\"idr\":" << st.idr
                << ",\"p\":" << st.p << ",\"max_gop\":" << st.maxGop
                << ",\"mb\":" << st.mb << ",\"i16\":" << st.i16 << ",\"i4\":" << st.i4 << ",\"p16\":" << st.p16
                << ",\"skip\":" << st.skip << ",\"nonzero_blocks\":" << st.nonzero
                << ",\"qp_min\":" << st.minQp << ",\"qp_max\":" << st.maxQp
                << ",\"level_min\":" << st.minLevel << ",\"level_max\":" << st.maxLevel
                << ",\"max_coded_width\":" << c.width << ",\"max_coded_height\":" << c.height
                << ",\"limited_bt601_signaling_ok\":" << (colorSignalingOk ? "true" : "false")
                << ",\"geometry\":[";
            bool first = true;
            for (const auto& entry : sps) {
                const auto& s = entry.second;
                if (!first) out << ",";
                first = false;
                const uint64_t yBytes = uint64_t(s.w)*s.h;
                uint64_t darNum = uint64_t(s.dw)*s.sarNum;
                uint64_t darDen = uint64_t(s.dh)*s.sarDen;
                const bool sarKnown = darNum && darDen;
                if (sarKnown) {
                    const auto divisor = std::gcd(darNum, darDen);
                    darNum /= divisor; darDen /= divisor;
                }
                out << "{\"sps_id\":" << s.id << ",\"pictures\":" << st.picturesBySps[s.id]
                    << ",\"coded_width\":" << s.w << ",\"coded_height\":" << s.h
                    << ",\"visible_width\":" << s.dw << ",\"visible_height\":" << s.dh
                    << ",\"mb_columns\":" << s.w/16 << ",\"mb_rows\":" << s.h/16
                    << ",\"macroblocks_per_picture\":" << (s.w/16)*(s.h/16)
                    << ",\"crop_pixels_lrtb\":[" << s.crop[0]*2 << "," << s.crop[1]*2 << ","
                    << s.crop[2]*2 << "," << s.crop[3]*2 << "]"
                    << ",\"sar_signaled\":" << (s.sarPresent ? "true" : "false")
                    << ",\"sar_known\":" << (sarKnown ? "true" : "false")
                    << ",\"sar_num\":" << s.sarNum << ",\"sar_den\":" << s.sarDen
                    << ",\"bitstream_dar_num\":" << (sarKnown ? std::to_string(darNum) : "null")
                    << ",\"bitstream_dar_den\":" << (sarKnown ? std::to_string(darDen) : "null")
                    << ",\"color\":{\"video_signal_type_present\":" << (s.videoSignalPresent ? "true" : "false")
                    << ",\"video_format\":" << s.videoFormat
                    << ",\"range_signaled\":" << (s.videoSignalPresent ? "true" : "false")
                    << ",\"full_range_flag\":" << (s.fullRange ? 1 : 0)
                    << ",\"colour_description_present\":" << (s.colourDescriptionPresent ? "true" : "false")
                    << ",\"colour_primaries\":" << s.colourPrimaries
                    << ",\"transfer_characteristics\":" << s.transferCharacteristics
                    << ",\"matrix_coefficients\":" << s.matrixCoefficients
                    << ",\"matrix_signaled\":" << (s.colourDescriptionPresent ? "true" : "false")
                    << ",\"matrix_known\":" << (s.matrixCoefficients != 2 ? "true" : "false") << "}"
                    << ",\"packed_i420\":{\"y_stride\":" << s.w << ",\"chroma_stride\":" << s.w/2
                    << ",\"y_offset\":0,\"u_offset\":" << yBytes << ",\"v_offset\":" << yBytes+yBytes/4
                    << ",\"frame_bytes\":" << yBytes+yBytes/2 << "}}";
            }
            out << "]}\n";
            require(bool(out), "cannot write JSON report");
        }
        for (const auto& entry : sps) {
            const auto& s = entry.second;
            require(!s.fullRange, "unsupported full-range video for limited-BT601 scanout");
            require(s.matrixCoefficients == 2 || s.matrixCoefficients == 5 || s.matrixCoefficients == 6,
                    "unsupported matrix_coefficients=" + std::to_string(s.matrixCoefficients) +
                    " for limited-BT601 scanout");
        }
        require(!requireColor || colorSignalingOk,
                "matrix_coefficients=2 unspecified; limited-BT601 signaling unproven");
        std::cout << "PASS syntax-only bounded compressed stream; framePTS/bitrate/default-decoder/"
                     "PMS-origin/FPGA/glass qualification remain separate\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL pms_baseline_profile: " << e.what() << "\n";
        return 1;
    }
}
