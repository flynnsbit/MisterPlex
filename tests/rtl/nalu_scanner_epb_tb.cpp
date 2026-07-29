// Prove product nalu_scanner strips EBSP 00 00 03 on SPS + VCL capture taps.
// Cycle cost: no extra beyond prior design (1 FIFO read/clk streaming; EPB skip is
// same-cycle drop). Note: annex-B start-code leading zeros may append as trailing
// 0x00 on RBSP (not EPB); proof allows zero-only suffix after exact RBSP prefix.
#include "Vnalu_scanner_epb_tb_top.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static std::vector<uint8_t> removeEpbHost(const uint8_t* p, size_t n) {
    std::vector<uint8_t> out;
    out.reserve(n);
    int z = 0;
    for (size_t i = 0; i < n; ++i) {
        const uint8_t b = p[i];
        if (z >= 2 && b == 0x03) {
            z = 0;
            continue;
        }
        out.push_back(b);
        z = (b == 0x00) ? (z < 2 ? z + 1 : 2) : 0;
    }
    return out;
}

static bool hasEpb(const uint8_t* p, size_t n) {
    for (size_t i = 2; i < n; ++i)
        if (p[i - 2] == 0 && p[i - 1] == 0 && p[i] == 3)
            return true;
    return false;
}

static bool rbspMatches(const std::vector<uint8_t>& got, const std::vector<uint8_t>& want,
                        const char* tag) {
    if (got.size() < want.size()) {
        std::cerr << "FAIL " << tag << " RBSP shorter got=" << got.size()
                  << " want=" << want.size() << "\n";
        return false;
    }
    for (size_t i = 0; i < want.size(); ++i) {
        if (got[i] != want[i]) {
            std::cerr << "FAIL " << tag << " RBSP diff @" << i << " got=" << int(got[i])
                      << " want=" << int(want[i]) << "\n";
            return false;
        }
    }
    for (size_t i = want.size(); i < got.size(); ++i) {
        if (got[i] != 0) {
            std::cerr << "FAIL " << tag << " non-zero suffix after RBSP @" << i
                      << " val=" << int(got[i]) << "\n";
            return false;
        }
    }
    return true;
}

static std::vector<uint8_t> readBin(const char* path) {
    std::ifstream in(path, std::ios::binary);
    if (!in)
        throw std::runtime_error(std::string("open failed: ") + path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

struct Nal {
    int type = -1;
    size_t sc = 0;
    std::vector<uint8_t> raw;
};

static std::vector<Nal> splitNals(const std::vector<uint8_t>& ab) {
    std::vector<Nal> out;
    for (size_t i = 0; i + 3 < ab.size();) {
        size_t sc = 0;
        if (ab[i] == 0 && ab[i + 1] == 0 && ab[i + 2] == 0 && ab[i + 3] == 1)
            sc = 4;
        else if (ab[i] == 0 && ab[i + 1] == 0 && ab[i + 2] == 1)
            sc = 3;
        if (!sc) {
            ++i;
            continue;
        }
        size_t j = i + sc;
        size_t k = j;
        while (k + 3 < ab.size()) {
            if (ab[k] == 0 && ab[k + 1] == 0 &&
                (ab[k + 2] == 1 || (k + 3 < ab.size() && ab[k + 2] == 0 && ab[k + 3] == 1)))
                break;
            ++k;
        }
        if (k + 3 >= ab.size())
            k = ab.size();
        Nal n;
        n.sc = sc;
        n.raw.assign(ab.begin() + static_cast<long>(i), ab.begin() + static_cast<long>(k));
        n.type = (j < k) ? (ab[j] & 0x1f) : -1;
        out.push_back(std::move(n));
        i = k;
    }
    return out;
}

static void tick(Vnalu_scanner_epb_tb_top& dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
}

static void resetDut(Vnalu_scanner_epb_tb_top& dut) {
    dut.reset = 1;
    dut.wr_en = 0;
    dut.wr_data = 0;
    dut.wr_flush = 0;
    for (int i = 0; i < 4; ++i)
        tick(dut);
    dut.reset = 0;
    tick(dut);
}

struct Caps {
    std::vector<uint8_t> sps;
    std::vector<uint8_t> vcl;
    int sps_ends = 0;
    int vcl_ends = 0;
};

static Caps runStream(Vnalu_scanner_epb_tb_top& dut, const std::vector<uint8_t>& bytes) {
    Caps c;
    size_t wi = 0;
    std::vector<uint8_t> stream = bytes;
    stream.insert(stream.end(), {0x00, 0x00, 0x00, 0x01, 0x09, 0x10});

    for (int guard = 0; guard < 500000; ++guard) {
        const bool can_wr = (wi < stream.size()) && !dut.wr_full;
        dut.wr_en = can_wr ? 1 : 0;
        dut.wr_data = can_wr ? stream[wi] : 0;
        tick(dut);
        if (can_wr)
            ++wi;

        if (dut.sps_cap_clear)
            c.sps.clear();
        if (dut.sps_cap_en)
            c.sps.push_back(static_cast<uint8_t>(dut.sps_cap_data));
        if (dut.sps_cap_end)
            ++c.sps_ends;

        if (dut.vcl_cap_clear)
            c.vcl.clear();
        if (dut.vcl_cap_en)
            c.vcl.push_back(static_cast<uint8_t>(dut.vcl_cap_data));
        if (dut.vcl_cap_end)
            ++c.vcl_ends;

        if (wi >= stream.size() && (c.vcl_ends + c.sps_ends) > 0 && dut.wr_level == 0)
            break;
    }
    dut.wr_en = 0;
    for (int i = 0; i < 64; ++i) {
        tick(dut);
        if (dut.sps_cap_clear)
            c.sps.clear();
        if (dut.sps_cap_en)
            c.sps.push_back(static_cast<uint8_t>(dut.sps_cap_data));
        if (dut.sps_cap_end)
            ++c.sps_ends;
        if (dut.vcl_cap_clear)
            c.vcl.clear();
        if (dut.vcl_cap_en)
            c.vcl.push_back(static_cast<uint8_t>(dut.vcl_cap_data));
        if (dut.vcl_cap_end)
            ++c.vcl_ends;
    }
    return c;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vnalu_scanner_epb_tb_top dut;
    int fail = 0;

    // Synthetic IDR with 4 EPB patterns (incl. 00 00 03 03 -> RBSP 00 00 03 data).
    const std::vector<uint8_t> syn = {
        0x00, 0x00, 0x00, 0x01,
        0x65,
        0xAA, 0x00, 0x00, 0x03, 0x00,
        0xBB, 0x00, 0x00, 0x03, 0x01,
        0xCC, 0x00, 0x00, 0x03, 0x02,
        0xDD, 0x00, 0x00, 0x03, 0x03,
        0xEE
    };
    const std::vector<uint8_t> synWant = {
        0xAA, 0x00, 0x00, 0x00,
        0xBB, 0x00, 0x00, 0x01,
        0xCC, 0x00, 0x00, 0x02,
        0xDD, 0x00, 0x00, 0x03,
        0xEE
    };
    const auto synPay = std::vector<uint8_t>(syn.begin() + 5, syn.end());
    if (removeEpbHost(synPay.data(), synPay.size()) != synWant) {
        std::cerr << "FAIL host EPB model\n";
        ++fail;
    }
    if (!hasEpb(synPay.data(), synPay.size())) {
        std::cerr << "FAIL synthetic missing 00 00 03 in EBSP\n";
        ++fail;
    }
    const int synEpb = int(synPay.size()) - int(synWant.size());
    if (synEpb != 4) {
        std::cerr << "FAIL expected 4 synthetic EPBs, model=" << synEpb << "\n";
        ++fail;
    }

    resetDut(dut);
    auto cs = runStream(dut, syn);
    if (cs.vcl_ends < 1) {
        std::cerr << "FAIL synthetic: no vcl_cap_end\n";
        ++fail;
    }
    if (!rbspMatches(cs.vcl, synWant, "synthetic VCL"))
        ++fail;
    if (static_cast<int>(dut.idr_count) < 1) {
        std::cerr << "FAIL synthetic idr_count=" << int(dut.idr_count) << "\n";
        ++fail;
    }
    std::cout << "nalu_scanner EPB synthetic: ebsp=" << synPay.size()
              << " rbsp_prefix=" << synWant.size() << " got_len=" << cs.vcl.size()
              << " epb_stripped=" << synEpb
              << " sc_zero_suffix=" << (cs.vcl.size() - synWant.size()) << "\n";

    const char* realPath = (argc > 1) ? argv[1]
                                      : "tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p.264";
    auto ab = readBin(realPath);
    auto nals = splitNals(ab);
    const Nal* spsN = nullptr;
    const Nal* vclEpb = nullptr;
    for (const auto& n : nals) {
        if (n.raw.size() <= n.sc + 1)
            continue;
        const uint8_t* pay = n.raw.data() + n.sc + 1;
        const size_t payn = n.raw.size() - n.sc - 1;
        if (!hasEpb(pay, payn))
            continue;
        if (n.type == 7 && !spsN)
            spsN = &n;
        if ((n.type == 1 || n.type == 5) && !vclEpb)
            vclEpb = &n;
    }
    if (!spsN && !vclEpb) {
        std::cerr << "FAIL real fixture has no NAL with EPB: " << realPath << "\n";
        ++fail;
    }

    if (spsN) {
        resetDut(dut);
        auto cr = runStream(dut, spsN->raw);
        const uint8_t* pay = spsN->raw.data() + spsN->sc + 1;
        const size_t payn = spsN->raw.size() - spsN->sc - 1;
        auto want = removeEpbHost(pay, payn);
        if (cr.sps_ends < 1) {
            std::cerr << "FAIL real SPS: no sps_cap_end\n";
            ++fail;
        }
        if (!rbspMatches(cr.sps, want, "real SPS"))
            ++fail;
        const int stripped = int(payn) - int(want.size());
        std::cout << "nalu_scanner EPB real SPS: ebsp=" << payn << " rbsp=" << want.size()
                  << " got_len=" << cr.sps.size() << " stripped=" << stripped << "\n";
        if (stripped < 1) {
            std::cerr << "FAIL real SPS expected EPB stripped\n";
            ++fail;
        }
    }

    auto checkVcl = [&](const Nal* ve, const char* tag) {
        if (!ve)
            return;
        resetDut(dut);
        auto cr = runStream(dut, ve->raw);
        const uint8_t* pay = ve->raw.data() + ve->sc + 1;
        const size_t payn = ve->raw.size() - ve->sc - 1;
        auto want = removeEpbHost(pay, payn);
        if (!rbspMatches(cr.vcl, want, tag))
            ++fail;
        else
            std::cout << "nalu_scanner EPB " << tag << " VCL: type=" << ve->type
                      << " ebsp=" << payn << " rbsp=" << want.size()
                      << " got_len=" << cr.vcl.size()
                      << " stripped=" << (int(payn) - int(want.size())) << "\n";
    };

    if (vclEpb) {
        checkVcl(vclEpb, "real");
    } else {
        const char* vclPath = (argc > 2) ? argv[2]
                                         : "tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264";
        auto ab2 = readBin(vclPath);
        const Nal* ve = nullptr;
        for (const auto& n : splitNals(ab2)) {
            if (!(n.type == 1 || n.type == 5) || n.raw.size() <= n.sc + 1)
                continue;
            const uint8_t* pay = n.raw.data() + n.sc + 1;
            const size_t payn = n.raw.size() - n.sc - 1;
            if (hasEpb(pay, payn)) {
                // need stable pointer - copy into static storage
                static Nal held;
                held = n;
                ve = &held;
                break;
            }
        }
        if (!ve)
            std::cout << "nalu_scanner EPB real VCL: none in fixtures; synthetic covers VCL strip\n";
        else
            checkVcl(ve, "inter");
    }

    if (fail) {
        std::cerr << "nalu_scanner EPB product-path check FAILED: " << fail << "\n";
        return 1;
    }
    std::cout << "nalu_scanner EPB product-path check PASS: strip=YES"
              << " site=nalu_scanner(epb_z/vcl_z) rbsp_window=stores-stripped-only"
              << " synthetic_epb=4\n";
    return 0;
}
