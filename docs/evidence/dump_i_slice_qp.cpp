// Gold I-slice per-MB qp + bit_pos after mb_qp_delta (lockstep with h264_slice_walk).
#include "libmisterplex/h264_nal.hpp"
#include "libmisterplex/h264_cavlc.hpp"
#include "libmisterplex/h264_slice_walk.hpp"
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace misterplex;

static std::vector<uint8_t> readFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1]
        : "tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264";
    auto buf = readFile(path);
    auto chain = parseAnnexBChain(buf.data(), buf.size());
    if (!chain.sps.valid || !chain.pps.valid) {
        fprintf(stderr, "no sps/pps\n");
        return 2;
    }
    // Find first IDR NAL payload
    size_t i = 0;
    const uint8_t* pay = nullptr;
    size_t plen = 0;
    uint8_t ntype = 0;
    while (i + 3 < buf.size()) {
        size_t sc = 0;
        if (i + 4 <= buf.size() && buf[i]==0&&buf[i+1]==0&&buf[i+2]==0&&buf[i+3]==1) sc = 4;
        else if (buf[i]==0&&buf[i+1]==0&&buf[i+2]==1) sc = 3;
        else { ++i; continue; }
        size_t h = i + sc;
        if (h >= buf.size()) break;
        uint8_t t = buf[h] & 0x1f;
        size_t j = h + 1;
        while (j + 3 < buf.size()) {
            if (buf[j]==0&&buf[j+1]==0&&(buf[j+2]==1 || (buf[j+2]==0&&j+3<buf.size()&&buf[j+3]==1)))
                break;
            ++j;
        }
        if (t == 5) {
            pay = buf.data() + h + 1;
            plen = j - (h + 1);
            ntype = t;
            break;
        }
        i = j;
    }
    if (!pay) { fprintf(stderr, "no IDR\n"); return 3; }

    auto rbsp = detail::removeEpb(pay, plen);
    detail::BitReader br(rbsp.data(), rbsp.size());
    br.ue(); // first_mb
    br.ue(); // slice_type
    br.ue(); // pps_id
    br.u(chain.log2_max_frame_num);
    if (ntype == 5) {
        br.ue(); // idr_pic_id
        br.u(1);
        br.u(1);
    }
    int32_t sqpd = br.se();
    int qp = static_cast<int>(chain.pps.pic_init_qp) + sqpd;
    if (qp < 0) qp = 0;
    if (qp > 51) qp = 51;
    printf("GOLD_HDR pic_init_qp=%d slice_qp_delta=%d slice_qp=%d bit_after_hdr_pre_db=%zu\n",
           chain.pps.pic_init_qp, sqpd, qp, br.bit);
    if (chain.pps.deblock_ctrl) {
        uint32_t d = br.ue();
        if (d != 1) { br.se(); br.se(); }
    }
    printf("GOLD_HDR bit_at_first_mb=%zu\n", br.bit);

    const int mbW = (chain.sps.width + 15) / 16;
    const int mbH = (chain.sps.height + 15) / 16;
    std::vector<int> tcLuma(static_cast<size_t>(mbW * mbH * 16), -1);
    std::vector<int> tcChr[2] = {
        std::vector<int>(static_cast<size_t>(mbW * mbH * 4), -1),
        std::vector<int>(static_cast<size_t>(mbW * mbH * 4), -1)};
    auto tcatL = [&](int mbx, int mby, int lx, int ly) -> int* {
        if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH) return nullptr;
        int& v = tcLuma[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)];
        return (v < 0) ? nullptr : &v;
    };
    auto tcsetL = [&](int mbx, int mby, int lx, int ly, int v) {
        tcLuma[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] = v;
    };
    auto tcatC = [&](int plane, int mbx, int mby, int lx, int ly) -> int* {
        if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH) return nullptr;
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
                    int lx, ly; walk_detail::chrXY(b, lx, ly);
                    int* nA = (lx > 0) ? tcatC(p, mbx, mby, lx - 1, ly) : tcatC(p, mbx - 1, mby, 1, ly);
                    int* nB = (ly > 0) ? tcatC(p, mbx, mby, lx, ly - 1) : tcatC(p, mbx, mby - 1, lx, 1);
                    auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 15);
                    if (!r.ok) return "chrAC";
                    tcsetC(p, mbx, mby, lx, ly, r.total_coeff);
                }
            }
        } else {
            for (int p = 0; p < 2; ++p)
                for (int b = 0; b < 4; ++b) {
                    int lx, ly; walk_detail::chrXY(b, lx, ly);
                    tcsetC(p, mbx, mby, lx, ly, 0);
                }
        }
        return nullptr;
    };

    for (int mby = 0; mby < mbH; ++mby) {
        for (int mbx = 0; mbx < mbW; ++mbx) {
            int mb = mby * mbW + mbx;
            if (!br.ok) { printf("FAIL br at mb=%d\n", mb); return 4; }
            size_t bit_before = br.bit;
            uint32_t mt = br.ue();
            if (mt > 25) { printf("FAIL mt at mb=%d\n", mb); return 5; }
            int qp_before = qp;
            int32_t se = 0;
            uint32_t ue_delta = 0;
            int cbp = -1;
            int i16 = 0;
            if (mt == 25) {
                while (br.ok && (br.bit % 8) != 0) br.u(1);
                for (int k = 0; k < 384 && br.ok; ++k) br.u(8);
                for (int ly=0;ly<4;++ly) for (int lx=0;lx<4;++lx) tcsetL(mbx,mby,lx,ly,16);
                for (int p=0;p<2;++p) for (int b=0;b<4;++b) {
                    int lx,ly; walk_detail::chrXY(b,lx,ly); tcsetC(p,mbx,mby,lx,ly,16);
                }
                printf("GOLD_MB mb=%d mt=%u i16=0 cbp=PCM qp=%d bit_pos=%zu (pcm)\n", mb, mt, qp, br.bit);
                continue;
            }
            if (mt == 0) {
                for (int k = 0; k < 16; ++k)
                    if (br.u(1) == 0) br.u(3);
                br.ue(); // chroma
                uint32_t code = br.ue();
                cbp = walk_detail::kMeIntra[code];
                int cbp_l = cbp & 15;
                int cbp_c = cbp >> 4;
                if (cbp != 0) {
                    // peek ue by re-implementing se with capture
                    size_t b0 = br.bit;
                    // manual ue
                    int z = 0;
                    while (br.ok && br.u1() == 0) ++z;
                    if (z == 0) ue_delta = 0;
                    else ue_delta = (1u << z) - 1u + br.u(z);
                    if ((ue_delta & 1u) == 0) se = -static_cast<int32_t>(ue_delta / 2);
                    else se = static_cast<int32_t>((ue_delta + 1) / 2);
                    qp += se;
                    (void)b0;
                }
                size_t bit_after_delta = br.bit;
                for (int i8 = 0; i8 < 4; ++i8) {
                    if ((cbp_l >> i8) & 1) {
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly; walk_detail::blkXY(i8, i4, lx, ly);
                            int* nA = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
                            int* nB = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
                            auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 16);
                            if (!r.ok) { printf("FAIL I4 mb=%d\n", mb); return 6; }
                            tcsetL(mbx, mby, lx, ly, r.total_coeff);
                        }
                    } else {
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly; walk_detail::blkXY(i8, i4, lx, ly);
                            tcsetL(mbx, mby, lx, ly, 0);
                        }
                    }
                }
                if (const char* e = parseChr(mbx, mby, cbp_c)) {
                    printf("FAIL %s mb=%d\n", e, mb); return 7;
                }
                if (mb >= 125 && mb <= 145)
                    printf("GOLD_QP mb=%d mt=%u i16=0 cbp=0x%x qp_before=%d ue=%u se=%d qp=%d bit_before=%zu bit_after_delta=%zu bit_end=%zu\n",
                           mb, mt, cbp, qp_before, ue_delta, se, qp, bit_before, bit_after_delta, br.bit);
                else if (mb < 5 || (qp != qp_before))
                    printf("GOLD_QP mb=%d mt=%u i16=0 cbp=0x%x qp_before=%d ue=%u se=%d qp=%d bit_after_delta=%zu\n",
                           mb, mt, cbp, qp_before, ue_delta, se, qp, bit_after_delta);
            } else {
                i16 = 1;
                int x = static_cast<int>(mt) - 1;
                int cbp_c = (x / 4) % 3;
                int cbp_l = (x / 12) ? 15 : 0;
                cbp = (cbp_c << 4) | cbp_l;
                br.ue(); // chroma
                size_t b0 = br.bit;
                int z = 0;
                while (br.ok && br.u1() == 0) ++z;
                if (z == 0) ue_delta = 0;
                else ue_delta = (1u << z) - 1u + br.u(z);
                if ((ue_delta & 1u) == 0) se = -static_cast<int32_t>(ue_delta / 2);
                else se = static_cast<int32_t>((ue_delta + 1) / 2);
                qp += se;
                size_t bit_after_delta = br.bit;
                (void)b0;
                int* nA = tcatL(mbx - 1, mby, 3, 0);
                int* nB = tcatL(mbx, mby - 1, 0, 3);
                auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 16);
                if (!r.ok) { printf("FAIL I16dc mb=%d\n", mb); return 8; }
                if (cbp_l) {
                    for (int i8 = 0; i8 < 4; ++i8)
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly; walk_detail::blkXY(i8, i4, lx, ly);
                            int* a = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
                            int* b = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
                            auto rr = cavlc::residualBlock(br, walk_detail::ncFrom(a, b), 15);
                            if (!rr.ok) { printf("FAIL I16ac mb=%d\n", mb); return 9; }
                            tcsetL(mbx, mby, lx, ly, rr.total_coeff);
                        }
                } else {
                    for (int ly=0;ly<4;++ly) for (int lx=0;lx<4;++lx) tcsetL(mbx,mby,lx,ly,0);
                }
                if (const char* e = parseChr(mbx, mby, cbp_c)) {
                    printf("FAIL %s mb=%d\n", e, mb); return 10;
                }
                if (mb >= 125 && mb <= 145)
                    printf("GOLD_QP mb=%d mt=%u i16=1 cbp=0x%x qp_before=%d ue=%u se=%d qp=%d bit_before=%zu bit_after_delta=%zu bit_end=%zu\n",
                           mb, mt, cbp, qp_before, ue_delta, se, qp, bit_before, bit_after_delta, br.bit);
                else if (mb < 5 || se != 0)
                    printf("GOLD_QP mb=%d mt=%u i16=1 cbp=0x%x qp_before=%d ue=%u se=%d qp=%d bit_after_delta=%zu\n",
                           mb, mt, cbp, qp_before, ue_delta, se, qp, bit_after_delta);
            }
        }
    }
    printf("GOLD_DONE mbs=%d final_qp=%d bit=%zu ok=%d\n", mbW*mbH, qp, br.bit, (int)br.ok);
    return 0;
}
