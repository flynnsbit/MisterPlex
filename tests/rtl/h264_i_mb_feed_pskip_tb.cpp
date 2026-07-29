// Real RTL sim: multi-MB P walker mb_skip_run boundaries on h264_i_mb_feed.
#include "Vh264_i_mb_feed_pskip_tb_top.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

int failures = 0;

void expect(bool cond, const std::string& msg) {
    if (!cond) {
        std::cerr << "FAIL: " << msg << "\n";
        ++failures;
    }
}

struct Bits {
    std::vector<uint8_t> bytes;
    int nbits = 0;

    void pushBit(int b) {
        if ((nbits & 7) == 0)
            bytes.push_back(0);
        if (b)
            bytes.back() |= static_cast<uint8_t>(1u << (7 - (nbits & 7)));
        ++nbits;
    }

    void ue(uint32_t v) {
        // unsigned exp-Golomb: zeros + '1' + binary(v+1 without leading 1)
        uint32_t x = v + 1;
        int msb = 31;
        while (msb > 0 && ((x >> msb) & 1u) == 0)
            --msb;
        for (int i = 0; i < msb; ++i)
            pushBit(0);
        for (int i = msb; i >= 0; --i)
            pushBit((x >> i) & 1);
    }

    void se(int32_t v) {
        if (v <= 0)
            ue(static_cast<uint32_t>(-2 * v));
        else
            ue(static_cast<uint32_t>(2 * v - 1));
    }

    void trailing() {
        // rbsp_stop_one_bit + zero align to byte
        pushBit(1);
        while (nbits & 7)
            pushBit(0);
    }
};

struct Sim {
    Vh264_i_mb_feed_pskip_tb_top top{};
    std::vector<uint8_t> rbsp;
    uint16_t lengthBytes = 0;

    void tick() {
        // Serve RBSP window requests combinationally before/after edge.
        serveWindow();
        top.clk = 0;
        top.eval();
        serveWindow();
        top.clk = 1;
        top.eval();
        serveWindow();
    }

    void serveWindow() {
        if (!top.rbsp_request_valid)
            return;
        const uint16_t base = top.rbsp_request_offset;
        top.rbsp_window_base = base;
        for (int i = 0; i < 64; ++i) {
            const size_t abs = static_cast<size_t>(base) + static_cast<size_t>(i);
            top.rbsp_byte_in[i] = (abs < rbsp.size()) ? rbsp[abs] : 0;
        }
    }

    void loadRbsp(const Bits& b) {
        rbsp = b.bytes;
        lengthBytes = static_cast<uint16_t>(b.bytes.size());
        top.rbsp_length = lengthBytes;
        top.rbsp_complete = 1;
        top.rbsp_window_base = 0;
        for (int i = 0; i < 64; ++i)
            top.rbsp_byte_in[i] = (static_cast<size_t>(i) < rbsp.size()) ? rbsp[i] : 0;
    }

    void reset() {
        top.reset = 1;
        top.slice_go = 0;
        top.core_busy = 0;
        top.mb_width = 2;
        top.mb_height = 2;
        top.first_mb_in_slice = 0;
        top.slice_qp_y = 26;
        top.first_mb_type = 0;
        top.first_mb_p_skip = 0;
        top.first_p_skip_run = 0;
        top.first_mb_intra = 0;
        top.first_mb_part_mode = 0;
        top.first_cbp_luma = 0;
        top.first_cbp_chroma = 0;
        top.first_residual_bit_offset = 0;
        top.rbsp_complete = 0;
        top.rbsp_length = 0;
        top.rbsp_window_base = 0;
        for (int i = 0; i < 64; ++i)
            top.rbsp_byte_in[i] = 0;
        tick();
        tick();
        top.reset = 0;
        tick();
    }
};

struct Pulse {
    bool skip = false;
    bool intra = false;
    uint8_t mbType = 0;
    uint8_t cbpL = 0;
    uint8_t cbpC = 0;
};

struct RunResult {
    std::vector<Pulse> pulses;
    bool done = false;
    bool error = false;
    bool desync = false;
    bool desyncEarly = false;
    bool desyncLong = false;
    int requests = 0;
};

RunResult runSlice(Sim& s, int maxCycles = 20000) {
    RunResult r;
    s.top.slice_go = 1;
    s.tick();
    s.top.slice_go = 0;

    for (int c = 0; c < maxCycles; ++c) {
        if (s.top.rbsp_request_valid)
            ++r.requests;
        if (s.top.mb_type_valid) {
            Pulse p;
            p.skip = s.top.mb_skip;
            p.intra = s.top.mb_intra;
            p.mbType = s.top.mb_type;
            p.cbpL = s.top.cbp_luma;
            p.cbpC = s.top.cbp_chroma;
            r.pulses.push_back(p);
        }
        if (s.top.frame_feed_done || s.top.error) {
            r.done = s.top.frame_feed_done;
            r.error = s.top.error;
            r.desync = s.top.slice_desync;
            r.desyncEarly = s.top.slice_desync_early;
            r.desyncLong = s.top.slice_desync_long;
            // Drain a few cycles so sticky flags settle.
            for (int k = 0; k < 4; ++k)
                s.tick();
            r.done = s.top.frame_feed_done || r.done;
            r.error = s.top.error || r.error;
            r.desync = s.top.slice_desync || r.desync;
            r.desyncEarly = s.top.slice_desync_early || r.desyncEarly;
            r.desyncLong = s.top.slice_desync_long || r.desyncLong;
            return r;
        }
        s.tick();
    }
    std::cerr << "FAIL: timeout waiting for frame_feed_done/error\n";
    ++failures;
    r.error = true;
    return r;
}

void checkEosSkipRun() {
    // 2x2 pic: first mb_skip_run already consumed as 4; remaining is only trailing.
    Sim s;
    s.reset();
    Bits b;
    b.trailing();
    s.loadRbsp(b);

    s.top.mb_width = 2;
    s.top.mb_height = 2;
    s.top.first_mb_p_skip = 1;
    s.top.first_p_skip_run = 4;
    s.top.first_residual_bit_offset = 0;

    auto r = runSlice(s);
    expect(r.done, "EOS skip-run: frame_feed_done");
    expect(!r.error, "EOS skip-run: no error");
    expect(!r.desync && !r.desyncEarly && !r.desyncLong, "EOS skip-run: no desync");
    expect(r.pulses.size() == 4, "EOS skip-run: 4 MBs emitted got=" + std::to_string(r.pulses.size()));
    for (size_t i = 0; i < r.pulses.size(); ++i) {
        expect(r.pulses[i].skip, "EOS skip-run: MB" + std::to_string(i) + " is skip");
        expect(!r.pulses[i].intra, "EOS skip-run: MB" + std::to_string(i) + " not intra");
        expect(r.pulses[i].cbpL == 0 && r.pulses[i].cbpC == 0,
               "EOS skip-run: MB" + std::to_string(i) + " cbp zero");
    }
    std::cout << "OK case EOS-ending skip_run: mb=4 all skip desync=0\n";
}

void checkZeroSkipRunThenCoded() {
    // 2x2: first skip_run=1 already consumed → emit MB0 skip.
    // Then mid-slice skip_run==0 (legal), coded P_L0_16x16 cbp=0, then skip_run=2 to EOS.
    Sim s;
    s.reset();
    Bits b;
    b.ue(0); // mid skip_run = 0
    b.ue(0); // mb_type P_L0_16x16
    b.se(0); // mvd_x
    b.se(0); // mvd_y
    b.ue(0); // inter CBP code 0 → cbp=0
    b.ue(2); // final skip_run covers remaining 2 MBs
    b.trailing();
    s.loadRbsp(b);

    s.top.mb_width = 2;
    s.top.mb_height = 2;
    s.top.first_mb_p_skip = 1;
    s.top.first_p_skip_run = 1;
    s.top.first_residual_bit_offset = 0;

    auto r = runSlice(s);
    expect(r.done, "zero-run: frame_feed_done");
    expect(!r.error, "zero-run: no error");
    expect(!r.desync && !r.desyncEarly && !r.desyncLong, "zero-run: no desync");
    expect(r.pulses.size() == 4, "zero-run: 4 MBs got=" + std::to_string(r.pulses.size()));
    if (r.pulses.size() == 4) {
        expect(r.pulses[0].skip, "zero-run: MB0 skip");
        expect(!r.pulses[1].skip && r.pulses[1].mbType == 0, "zero-run: MB1 coded P16x16");
        expect(r.pulses[2].skip && r.pulses[3].skip, "zero-run: MB2/3 skip");
    }
    std::cout << "OK case mb_skip_run==0 mid-slice: skip/coded/skip/skip\n";
}

void checkWindowBoundarySkipRun() {
    // Start residual offset near end of first 64B window so next skip_run parse
    // must request a new base (burst/window boundary).
    // Pic 2x3=6 MBs: first skip_run=2 consumed → emit 2 skips at mb 0,1.
    // Remaining bits live at absolute bit offset 500 (byte 62..).
    constexpr int kBitOff = 500; // byte 62, bit 4 — near 64B edge
    Bits b;
    // Pre-pad zeros up to kBitOff, then payload.
    while (b.nbits < kBitOff)
        b.pushBit(0);
    b.ue(0); // skip_run 0
    b.ue(0); // P16x16
    b.se(0);
    b.se(0);
    b.ue(0); // cbp0
    b.ue(3); // skip remaining 3
    b.trailing();

    Sim s;
    s.reset();
    s.loadRbsp(b);
    s.top.mb_width = 2;
    s.top.mb_height = 3;
    s.top.first_mb_p_skip = 1;
    s.top.first_p_skip_run = 2;
    s.top.first_residual_bit_offset = static_cast<uint16_t>(kBitOff);

    auto r = runSlice(s);
    expect(r.done, "win-boundary: frame_feed_done");
    expect(!r.error, "win-boundary: no error");
    expect(!r.desync && !r.desyncEarly && !r.desyncLong, "win-boundary: no desync");
    expect(r.pulses.size() == 6, "win-boundary: 6 MBs got=" + std::to_string(r.pulses.size()));
    expect(r.requests >= 1, "win-boundary: at least one rbsp window request");
    if (r.pulses.size() == 6) {
        expect(r.pulses[0].skip && r.pulses[1].skip, "win-boundary: first run skips");
        expect(!r.pulses[2].skip, "win-boundary: coded after zero-run");
        expect(r.pulses[3].skip && r.pulses[4].skip && r.pulses[5].skip,
               "win-boundary: trailing skip run");
    }
    std::cout << "OK case skip_run across window boundary: requests=" << r.requests << "\n";
}

void checkDesyncLongOverrun() {
    // skip_run claims more MBs than PicSizeInMbs.
    Sim s;
    s.reset();
    Bits b;
    b.trailing();
    s.loadRbsp(b);
    s.top.mb_width = 2;
    s.top.mb_height = 2;
    s.top.first_mb_p_skip = 1;
    s.top.first_p_skip_run = 8; // > 4
    s.top.first_residual_bit_offset = 0;

    auto r = runSlice(s);
    expect(r.desync || r.error, "overrun: sticky desync/error");
    expect(r.desyncLong || r.error, "overrun: desync_long");
    expect(r.pulses.size() == 4, "overrun: only PicSizeInMbs pulses got=" + std::to_string(r.pulses.size()));
    std::cout << "OK case skip_run overrun desync_long: pulses=" << r.pulses.size()
              << " desync_long=" << r.desyncLong << "\n";
}

void checkDesyncEarlyShort() {
    // First skip_run shorter than pic, then only trailing → early desync.
    Sim s;
    s.reset();
    Bits b;
    b.trailing();
    s.loadRbsp(b);
    s.top.mb_width = 2;
    s.top.mb_height = 2;
    s.top.first_mb_p_skip = 1;
    s.top.first_p_skip_run = 1;
    s.top.first_residual_bit_offset = 0;

    auto r = runSlice(s);
    expect(r.desync, "early: sticky desync");
    expect(r.desyncEarly, "early: desync_early");
    expect(r.pulses.size() == 1, "early: only 1 MB got=" + std::to_string(r.pulses.size()));
    std::cout << "OK case early EOS desync_early: pulses=" << r.pulses.size() << "\n";
}

// Header-path style: mb_skip_run==0 means first_mb_p_skip=0 and first coded MB is loaded.
void checkFirstCodedAfterZeroRunHeaderStyle() {
    // 2x2: first coded P16x16 cbp0 already parsed by header; remaining:
    // skip_run=3 to end.
    Sim s;
    s.reset();
    Bits b;
    b.ue(3);
    b.trailing();
    s.loadRbsp(b);
    s.top.mb_width = 2;
    s.top.mb_height = 2;
    s.top.first_mb_p_skip = 0;
    s.top.first_p_skip_run = 0;
    s.top.first_mb_type = 0;
    s.top.first_mb_intra = 0;
    s.top.first_mb_part_mode = 0;
    s.top.first_cbp_luma = 0;
    s.top.first_cbp_chroma = 0;
    s.top.first_residual_bit_offset = 0;

    auto r = runSlice(s);
    expect(r.done, "hdr-zero: frame_feed_done");
    expect(!r.error && !r.desync, "hdr-zero: clean");
    expect(r.pulses.size() == 4, "hdr-zero: 4 MBs got=" + std::to_string(r.pulses.size()));
    if (r.pulses.size() == 4) {
        expect(!r.pulses[0].skip && r.pulses[0].mbType == 0, "hdr-zero: MB0 coded");
        expect(r.pulses[1].skip && r.pulses[2].skip && r.pulses[3].skip, "hdr-zero: 3 skips");
    }
    std::cout << "OK case header-style skip_run==0 first coded then skip-to-EOS\n";
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    checkEosSkipRun();
    checkZeroSkipRunThenCoded();
    checkWindowBoundarySkipRun();
    checkDesyncLongOverrun();
    checkDesyncEarlyShort();
    checkFirstCodedAfterZeroRunHeaderStyle();
    if (failures) {
        std::cerr << "h264_i_mb_feed pskip RTL check FAILED: " << failures << " failures\n";
        return 1;
    }
    std::cout << "h264_i_mb_feed pskip RTL check PASS: "
                 "EOS-run, zero-run, window-boundary, desync_long, desync_early, header-zero\n";
    return 0;
}
