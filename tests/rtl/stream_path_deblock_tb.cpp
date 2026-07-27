#include "Vstream_path_deblock_tb.h"
#include "verilated.h"

#include <array>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct EdgeIO { std::array<uint8_t,4> p3{}, p2{}, p1{}, p0{}, q0{}, q1{}, q2{}, q3{}; };
struct EdgeOut { std::array<uint8_t,4> p2{}, p1{}, p0{}, q0{}, q1{}, q2{}; };

int clip(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
int clip8(int v) { return clip(v, 0, 255); }
int absdiff(int a, int b) { return a >= b ? a - b : b - a; }

std::vector<uint8_t> readBytes(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open " + path);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), {});
}
std::string readText(const std::string& path) {
    std::ifstream in(path);
    if (!in) throw std::runtime_error("cannot open " + path);
    return std::string(std::istreambuf_iterator<char>(in), {});
}

int countNals(const std::vector<uint8_t>& data) {
    int n = 0;
    for (size_t i = 0; i + 3 < data.size();) {
        if (i + 4 <= data.size() && data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1) { ++n; i += 4; }
        else if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) { ++n; i += 3; }
        else ++i;
    }
    return n;
}

int parseIntAfter(const std::string& text, const std::string& key, std::size_t start = 0) {
    std::string needle = "\"" + key + "\"";
    size_t p = text.find(needle, start);
    if (p == std::string::npos) throw std::runtime_error("missing key " + key);
    p = text.find(':', p);
    if (p == std::string::npos) throw std::runtime_error("malformed key " + key);
    ++p;
    while (p < text.size() && std::isspace(static_cast<unsigned char>(text[p]))) ++p;
    char* end = nullptr;
    long v = std::strtol(text.c_str() + p, &end, 10);
    if (end == text.c_str() + p) throw std::runtime_error("bad int " + key);
    return static_cast<int>(v);
}

std::vector<uint8_t> parseByteArrayAfter(const std::string& text, const std::string& key, std::size_t start = 0) {
    std::string needle = "\"" + key + "\"";
    size_t p = text.find(needle, start);
    if (p == std::string::npos) throw std::runtime_error("missing array " + key);
    p = text.find('[', p);
    size_t q = text.find(']', p);
    if (p == std::string::npos || q == std::string::npos) throw std::runtime_error("malformed array " + key);
    std::vector<uint8_t> out;
    const char* cur = text.c_str() + p + 1;
    const char* end = text.c_str() + q;
    while (cur < end) {
        while (cur < end && (std::isspace(static_cast<unsigned char>(*cur)) || *cur == ',')) ++cur;
        if (cur >= end) break;
        char* next = nullptr;
        long v = std::strtol(cur, &next, 10);
        if (next == cur || v < 0 || v > 255) throw std::runtime_error("bad byte in " + key);
        out.push_back(static_cast<uint8_t>(v));
        cur = next;
    }
    return out;
}

int alphaTable(int idx) {
    static constexpr int t[52] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,4,5,6,7,8,9,10,12,13,15,17,20,22,25,28,32,36,40,45,50,56,63,71,80,90,101,113,127,144,162,182,203,226,255,255};
    return t[clip(idx, 0, 51)];
}
int betaTable(int idx) {
    static constexpr int t[52] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,2,2,3,3,3,3,4,4,4,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18};
    return t[clip(idx, 0, 51)];
}
int tc0Table(int idx, int bs) {
    static constexpr int t[52][3] = {
        {-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},
        {-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},{-1,-1,-1},
        {0,0,0},{0,0,1},{0,0,1},{0,0,1},{0,0,1},{0,1,1},{0,1,1},{1,1,1},
        {1,1,1},{1,1,1},{1,1,1},{1,1,2},{1,1,2},{1,1,2},{1,1,2},{1,2,3},
        {1,2,3},{2,2,3},{2,2,4},{2,3,4},{2,3,4},{3,3,5},{3,4,6},{3,4,6},
        {4,5,7},{4,5,8},{4,6,9},{5,7,10},{6,8,11},{6,8,13},{7,10,14},{8,11,16},
        {9,12,18},{10,13,20},{11,15,23},{13,17,25}};
    return (bs >= 1 && bs <= 3) ? t[clip(idx, 0, 51)][bs - 1] : 0;
}

EdgeOut refEdge(const EdgeIO& in, bool chroma, int bs, int qp, int alphaOff, int betaOff) {
    EdgeOut out{in.p2, in.p1, in.p0, in.q0, in.q1, in.q2};
    int alpha = alphaTable(qp + alphaOff), beta = betaTable(qp + betaOff), tc0 = tc0Table(qp + alphaOff, bs);
    for (int i = 0; i < 4; ++i) {
        int p3=in.p3[i], p2=in.p2[i], p1=in.p1[i], p0=in.p0[i], q0=in.q0[i], q1=in.q1[i], q2=in.q2[i], q3=in.q3[i];
        bool ok = bs && absdiff(p0,q0) < alpha && absdiff(p1,p0) < beta && absdiff(q1,q0) < beta;
        bool ap = absdiff(p2,p0) < beta, aq = absdiff(q2,q0) < beta;
        bool strong = absdiff(p0,q0) < ((alpha >> 2) + 2);
        if (!ok) continue;
        if (bs == 4) {
            if (chroma) { out.p0[i] = clip8((2*p1+p0+q1+2)>>2); out.q0[i] = clip8((2*q1+q0+p1+2)>>2); }
            else if (strong) {
                if (ap) { out.p0[i]=clip8((p2+2*p1+2*p0+2*q0+q1+4)>>3); out.p1[i]=clip8((p2+p1+p0+q0+2)>>2); out.p2[i]=clip8((2*p3+3*p2+p1+p0+q0+4)>>3); }
                else out.p0[i]=clip8((2*p1+p0+q1+2)>>2);
                if (aq) { out.q0[i]=clip8((p1+2*p0+2*q0+2*q1+q2+4)>>3); out.q1[i]=clip8((p0+q0+q1+q2+2)>>2); out.q2[i]=clip8((p0+q0+q1+3*q2+2*q3+4)>>3); }
                else out.q0[i]=clip8((2*q1+q0+p1+2)>>2);
            } else { out.p0[i]=clip8((2*p1+p0+q1+2)>>2); out.q0[i]=clip8((2*q1+q0+p1+2)>>2); }
        } else {
            int tc = chroma ? tc0 + 1 : tc0 + (ap ? 1 : 0) + (aq ? 1 : 0);
            int delta = clip((((q0-p0)<<2) + (p1-q1) + 4) >> 3, -tc, tc);
            out.p0[i]=clip8(p0+delta); out.q0[i]=clip8(q0-delta);
            if (!chroma && ap) out.p1[i]=clip8(p1 + clip((p2 + ((p0+q0+1)>>1) - 2*p1) >> 1, -tc0, tc0));
            if (!chroma && aq) out.q1[i]=clip8(q1 + clip((q2 + ((p0+q0+1)>>1) - 2*q1) >> 1, -tc0, tc0));
        }
    }
    return out;
}

void tick(Vstream_path_deblock_tb& dut) { dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); }

void setEdge(Vstream_path_deblock_tb& dut, const EdgeIO& e, bool chroma, int bs) {
    dut.db_is_chroma = chroma; dut.db_bs_in = bs; dut.db_alpha_off = 0; dut.db_beta_off = 0;
    for (int i=0;i<4;++i) { dut.db_p3_in[i]=e.p3[i]; dut.db_p2_in[i]=e.p2[i]; dut.db_p1_in[i]=e.p1[i]; dut.db_p0_in[i]=e.p0[i]; dut.db_q0_in[i]=e.q0[i]; dut.db_q1_in[i]=e.q1[i]; dut.db_q2_in[i]=e.q2[i]; dut.db_q3_in[i]=e.q3[i]; }
}
EdgeOut pipeEdge(Vstream_path_deblock_tb& dut, const EdgeIO& e, bool chroma, int bs) {
    setEdge(dut, e, chroma, bs); dut.db_valid_i = 1; tick(dut);
    EdgeIO poison{}; setEdge(dut, poison, false, 0); dut.db_valid_i = 0; tick(dut);
    if (!dut.db_valid_o) throw std::runtime_error("deblock pipe did not assert valid_o after registered latency");
    EdgeOut out{};
    for (int i=0;i<4;++i) { out.p2[i]=dut.db_p2_out[i]; out.p1[i]=dut.db_p1_out[i]; out.p0[i]=dut.db_p0_out[i]; out.q0[i]=dut.db_q0_out[i]; out.q1[i]=dut.db_q1_out[i]; out.q2[i]=dut.db_q2_out[i]; }
    tick(dut);
    return out;
}
bool same(const EdgeOut& a, const EdgeOut& b) { return a.p2==b.p2 && a.p1==b.p1 && a.p0==b.p0 && a.q0==b.q0 && a.q1==b.q1 && a.q2==b.q2; }

EdgeIO gatherV(const std::vector<uint8_t>& f, int x, int y) {
    EdgeIO e{}; int w=16;
    for (int r=0;r<4;++r) { int yy=y+r; e.p3[r]=f[yy*w+x-4]; e.p2[r]=f[yy*w+x-3]; e.p1[r]=f[yy*w+x-2]; e.p0[r]=f[yy*w+x-1]; e.q0[r]=f[yy*w+x]; e.q1[r]=f[yy*w+x+1]; e.q2[r]=f[yy*w+x+2]; e.q3[r]=f[yy*w+x+3]; }
    return e;
}
void scatterV(std::vector<uint8_t>& f, int x, int y, const EdgeOut& o) {
    int w=16;
    for (int r=0;r<4;++r) { int yy=y+r; f[yy*w+x-3]=o.p2[r]; f[yy*w+x-2]=o.p1[r]; f[yy*w+x-1]=o.p0[r]; f[yy*w+x]=o.q0[r]; f[yy*w+x+1]=o.q1[r]; f[yy*w+x+2]=o.q2[r]; }
}

uint32_t fnv1a(const std::vector<uint8_t>& v) { uint32_t h=2166136261u; for (uint8_t b:v) { h^=b; h*=16777619u; } return h; }

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string annexbPath, goldenPath; bool faultBs = false;
    for (int i=1;i<argc;++i) {
        std::string a=argv[i];
        if (a=="--annexb" && i+1<argc) annexbPath=argv[++i];
        else if (a=="--mb-golden" && i+1<argc) goldenPath=argv[++i];
        else if (a=="--fault-bs") faultBs=true;
        else { std::cerr << "usage: " << argv[0] << " --annexb path --mb-golden path [--fault-bs]\n"; return 2; }
    }
    if (annexbPath.empty() || goldenPath.empty()) { std::cerr << "missing fixture paths\n"; return 2; }

    try {
        auto bytes = readBytes(annexbPath);
        std::string json = readText(goldenPath);
        int inputNalCount = countNals(bytes);
        if (inputNalCount < 2) throw std::runtime_error("fixture has fewer than 2 NALs");
        if (json.find("\"format\": \"misterplex.p3.mb_golden.v1\"") == std::string::npos) throw std::runtime_error("missing mb_golden.v1 format");
        if (json.find("\"first_recon_signature8_hex\": \"0x3b\"") == std::string::npos || json.find("\"first_pred_only_signature8_hex\": \"0x00\"") == std::string::npos) throw std::runtime_error("missing latency signature rejects");
        size_t mbPos = json.find("\"macroblock\"");
        size_t samplesPos = json.find("\"samples\"");
        int goldenQp = parseIntAfter(json, "qp", mbPos == std::string::npos ? 0 : mbPos);
        auto reconY = parseByteArrayAfter(json, "recon_y", samplesPos == std::string::npos ? 0 : samplesPos);
        if (reconY.size() != 256) throw std::runtime_error("mb_golden recon_y is not 16x16");

        Vstream_path_deblock_tb dut;
        dut.clk=0; dut.reset=1; dut.ioctl_download=0; dut.ioctl_wr=0; dut.ioctl_dout=0; dut.enable=1; dut.flush=0;
        dut.use_stream_qp=1; dut.use_stream_intra=1; dut.db_valid_i=0; dut.db_is_chroma=0; dut.db_bs_in=0; dut.db_qp_avg=0; dut.db_alpha_off=0; dut.db_beta_off=0;
        dut.bs_disable_all=0; dut.bs_slice_boundary_blocked=0; dut.bs_mb_boundary=0; dut.bs_p_intra=0; dut.bs_q_intra=0; dut.bs_p_nonzero=0; dut.bs_q_nonzero=0; dut.bs_p_ref=0; dut.bs_q_ref=0; dut.bs_p_mvx=0; dut.bs_p_mvy=0; dut.bs_q_mvx=0; dut.bs_q_mvy=0;
        for (int i=0;i<4;++i) { dut.db_p3_in[i]=dut.db_p2_in[i]=dut.db_p1_in[i]=dut.db_p0_in[i]=0; dut.db_q0_in[i]=dut.db_q1_in[i]=dut.db_q2_in[i]=dut.db_q3_in[i]=0; }
        uint16_t lastFrames = 0;
        int frameEvents = 0;
        std::vector<int> frameSigs, frameDbg;
        int placePulses = 0;
        auto tickObs = [&]() {
            tick(dut);
            if (dut.residual_place_pulse) ++placePulses;
            if (dut.stub_frames != lastFrames) {
                lastFrames = dut.stub_frames;
                ++frameEvents;
                frameSigs.push_back(dut.recon_sig);
                frameDbg.push_back(dut.recon_dbg);
            }
        };
        auto feedBytes = [&]() {
            dut.ioctl_download = 1;
            for (uint8_t b: bytes) {
                dut.ioctl_dout = b;
                dut.ioctl_wr = 1;
                tickObs();
            }
            dut.ioctl_wr = 0;
            dut.ioctl_download = 0;
            tickObs();
        };
        auto runUntilFrames = [&](int wantFrames, int maxCycles) {
            for (int cyc=0; cyc<maxCycles && frameEvents<wantFrames; ++cyc) tickObs();
        };

        for (int i=0;i<4;++i) tickObs();
        dut.reset=0;
        tickObs();

        feedBytes();
        runUntilFrames(1, 500000);
        feedBytes();
        runUntilFrames(2, 500000);

        const int totalInputNals = inputNalCount * 2;
        const size_t totalInputBytes = bytes.size() * 2;
        std::cout << "stream_path raw: input_nals=" << totalInputNals << " bytes=" << totalInputBytes
                  << " bytes_in=" << dut.bytes_in << " bytes_seen=" << dut.bytes_seen
                  << " nalu_count=" << dut.nalu_count << " sps=" << int(dut.sps_count)
                  << " pps=" << int(dut.pps_count) << " idr=" << int(dut.idr_count)
                  << " slices=" << int(dut.slice_count) << " frames=" << dut.stub_frames
                  << " residual_place_pulses=" << placePulses << " qp=" << int(dut.slice_qp)
                  << " mb=" << int(dut.sps_mb_w) << "x" << int(dut.sps_mb_h)
                  << " residual_csum=0x" << std::hex << int(dut.residual_csum)
                  << " recon_sig=0x" << int(dut.recon_sig) << " recon_dbg=0x" << int(dut.recon_dbg) << std::dec << "\n";
        if (frameEvents < 2 || (int(dut.idr_count) + int(dut.slice_count)) < 2) throw std::runtime_error("multi-NAL stream did not produce at least two decoded VCL frames");
        if (placePulses < 2) throw std::runtime_error("expected residual place pulse for both VCLs");
        if (dut.residual_csum != 0x14 || dut.recon_sig != 0x3b) throw std::runtime_error("stream_path handoff did not preserve residual into recon");
        if ((dut.recon_dbg & 0x79) != 0x79) throw std::runtime_error("recon debug bits do not show coeff/dequant/idct/recon/valid path");
        if (int(dut.slice_qp) != goldenQp) throw std::runtime_error("stream QP differs from mb_golden QP");

        dut.bs_disable_all=0; dut.bs_slice_boundary_blocked=0; dut.bs_p_nonzero=0; dut.bs_q_nonzero=0; dut.bs_p_ref=0; dut.bs_q_ref=0; dut.bs_p_mvx=0; dut.bs_p_mvy=0; dut.bs_q_mvx=0; dut.bs_q_mvy=0; dut.use_stream_intra=1;
        dut.bs_mb_boundary=1; dut.eval(); int bsMb = dut.bs_derived;
        dut.bs_mb_boundary=0; dut.eval(); int bsInternal = dut.bs_derived;
        dut.use_stream_intra=0; dut.bs_p_intra=0; dut.bs_q_intra=0; dut.bs_p_nonzero=1; dut.eval(); int bsResidual = dut.bs_derived;
        if (bsMb != 4 || bsInternal != 3 || bsResidual != 2) throw std::runtime_error("boundary-strength derivation failed");

        dut.use_stream_qp=1; dut.db_bs_in=3; dut.db_alpha_off=0; dut.db_beta_off=0; dut.eval();
        int alpha = dut.db_alpha, beta = dut.db_beta, tc0 = dut.db_tc0;
        if (alpha != alphaTable(goldenQp) || beta != betaTable(goldenQp) || tc0 != tc0Table(goldenQp, 3)) throw std::runtime_error("thresholds do not match stream QP average");

        std::vector<uint8_t> loopRef = reconY;
        bool foundChanged = false; int chosenX = -1, chosenY = -1; int chosenSampleX = -1, chosenSampleY = -1; EdgeOut chosenOut{};
        for (int x : {4,8,12}) for (int y : {0,4,8,12}) {
            EdgeIO e = gatherV(loopRef, x, y);
            EdgeOut want = refEdge(e, false, 3, goldenQp, 0, 0);
            EdgeOut got = pipeEdge(dut, e, false, 3);
            if (!same(want, got)) throw std::runtime_error("luma deblock output mismatch");
            for (int r = 0; r < 4 && !foundChanged; ++r) {
                if (got.p2[r] != e.p2[r]) { chosenSampleX = x - 3; chosenSampleY = y + r; foundChanged = true; }
                else if (got.p1[r] != e.p1[r]) { chosenSampleX = x - 2; chosenSampleY = y + r; foundChanged = true; }
                else if (got.p0[r] != e.p0[r]) { chosenSampleX = x - 1; chosenSampleY = y + r; foundChanged = true; }
                else if (got.q0[r] != e.q0[r]) { chosenSampleX = x; chosenSampleY = y + r; foundChanged = true; }
                else if (got.q1[r] != e.q1[r]) { chosenSampleX = x + 1; chosenSampleY = y + r; foundChanged = true; }
                else if (got.q2[r] != e.q2[r]) { chosenSampleX = x + 2; chosenSampleY = y + r; foundChanged = true; }
            }
            if (foundChanged) { chosenX=x; chosenY=y; chosenOut=got; goto edge_found; }
        }
edge_found:
        if (!foundChanged) throw std::runtime_error("no changing luma edge found in mb_golden fixture");
        uint8_t unfilteredPred = loopRef[chosenSampleY * 16 + chosenSampleX];
        scatterV(loopRef, chosenX, chosenY, chosenOut);
        uint8_t nextPred = loopRef[chosenSampleY * 16 + chosenSampleX];
        if (nextPred == unfilteredPred) throw std::runtime_error("in-loop reference did not feed filtered sample to next prediction");

        EdgeIO chroma{{118,119,120,121},{120,121,122,123},{122,123,124,125},{125,126,127,128},{131,132,133,134},{136,137,138,139},{138,139,140,141},{140,141,142,143}};
        EdgeOut chromaWant = refEdge(chroma, true, 2, goldenQp, 0, 0);
        EdgeOut chromaGot = pipeEdge(dut, chroma, true, 2);
        if (!same(chromaWant, chromaGot)) throw std::runtime_error("chroma deblock output mismatch");

        std::cout << "deblock raw: bs_mb=" << bsMb << " bs_internal=" << bsInternal
                  << " bs_residual=" << bsResidual << " alpha=" << alpha << " beta=" << beta
                  << " tc0=" << tc0 << " loop_edge=x" << chosenX << "y" << chosenY
                  << " changed_sample=x" << chosenSampleX << "y" << chosenSampleY
                  << " unfiltered_next=" << int(unfilteredPred) << " filtered_next=" << int(nextPred)
                  << " ref_fnv=0x" << std::hex << fnv1a(loopRef) << std::dec << "\n";

        if (faultBs) {
            std::vector<uint8_t> badRef = reconY;
            EdgeIO e = gatherV(badRef, chosenX, chosenY);
            EdgeOut wrong = pipeEdge(dut, e, false, 0);
            scatterV(badRef, chosenX, chosenY, wrong);
            if (badRef == loopRef) throw std::runtime_error("wrong bS perturbation did not alter the gate");
            std::cerr << "FAIL expected wrong bS red-check: correct_fnv=0x" << std::hex << fnv1a(loopRef)
                      << " wrong_fnv=0x" << fnv1a(badRef) << std::dec << "\n";
            return 1;
        }

        std::cout << "OK stream_path deblock integration: multi-NAL stream handoff, bS, thresholds, chroma, in-loop ref update\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL stream_path deblock integration: " << e.what() << "\n";
        return 1;
    }
}
