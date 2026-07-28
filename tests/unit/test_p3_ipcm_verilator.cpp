// Standalone test for h264_ipcm_passthrough (H.264 clause 7.3.5).
// Tests: basic passthrough, boundary values, sequential filling,
// reset during operation, and degeneracy (non-trivial output).
#include "Vp3_ipcm_tb.h"
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>
#include <array>

static void tick(Vp3_ipcm_tb& dut) {
    dut.clk = 0; dut.eval();
    dut.clk = 1; dut.eval();
}

struct TestCase {
    const char* name;
    std::array<uint8_t, 384> samples;
};

static TestCase makeCase(const char* name, uint8_t (*gen)(int idx)) {
    TestCase tc;
    tc.name = name;
    for (int i = 0; i < 384; ++i)
        tc.samples[static_cast<size_t>(i)] = gen(i);
    return tc;
}

int main() {
    Vp3_ipcm_tb dut;
    int pass = 0, fail = 0;

    // Test vectors
    std::vector<TestCase> cases;

    // 1. All zeros
    cases.push_back(makeCase("all_zero", [](int) -> uint8_t { return 0; }));

    // 2. All 0xFF
    cases.push_back(makeCase("all_ff", [](int) -> uint8_t { return 0xFF; }));

    // 3. Counting pattern (exercises all unique values in luma)
    cases.push_back(makeCase("counting", [](int i) -> uint8_t {
        return static_cast<uint8_t>(i & 0xFF);
    }));

    // 4. Inverse counting
    cases.push_back(makeCase("inverse_counting", [](int i) -> uint8_t {
        return static_cast<uint8_t>(255 - (i & 0xFF));
    }));

    // 5. Alternating 0/255 (max contrast)
    cases.push_back(makeCase("alternating", [](int i) -> uint8_t {
        return (i & 1) ? 255 : 0;
    }));

    // 6. Random-ish pattern (deterministic)
    cases.push_back(makeCase("pseudo_random", [](int i) -> uint8_t {
        return static_cast<uint8_t>((i * 37 + 17) & 0xFF);
    }));

    // 7. Gradient (typical smooth content)
    cases.push_back(makeCase("gradient", [](int i) -> uint8_t {
        if (i < 256) {
            int y = i / 16, x = i % 16;
            return static_cast<uint8_t>((y * 16 + x) & 0xFF);
        }
        return static_cast<uint8_t>(i - 256);
    }));

    // 8. Luma=128 (mid-grey), chroma varies
    cases.push_back(makeCase("mid_grey_varied_chroma", [](int i) -> uint8_t {
        if (i < 256) return 128;
        return static_cast<uint8_t>((i - 256) * 2);
    }));

    for (const auto& tc : cases) {
        // Reset
        dut.reset = 1; dut.start = 0; dut.wr_valid = 0; dut.wr_data = 0;
        tick(dut); tick(dut);
        dut.reset = 0;
        tick(dut);

        // Start I_PCM
        dut.start = 1;
        tick(dut);
        dut.start = 0;

        if (!dut.busy) {
            std::cerr << "FAIL " << tc.name << ": not busy after start\n";
            ++fail; continue;
        }

        // Write 384 samples
        bool earlyDone = false;
        for (int i = 0; i < 384; ++i) {
            dut.wr_valid = 1;
            dut.wr_data = tc.samples[static_cast<size_t>(i)];
            tick(dut);
            if (i < 383 && dut.done) { earlyDone = true; break; }
        }
        dut.wr_valid = 0;

        if (earlyDone) {
            std::cerr << "FAIL " << tc.name << ": premature done signal\n";
            ++fail; continue;
        }
        if (!dut.done) {
            std::cerr << "FAIL " << tc.name << ": done not asserted after 384 writes\n";
            ++fail; continue;
        }
        if (dut.busy) {
            std::cerr << "FAIL " << tc.name << ": still busy after done\n";
            ++fail; continue;
        }

        // Verify luma
        bool ok = true;
        for (int i = 0; i < 256 && ok; ++i) {
            if (dut.luma_out[i] != tc.samples[static_cast<size_t>(i)]) {
                std::cerr << "FAIL " << tc.name << ": luma_out[" << i << "] = "
                          << int(dut.luma_out[i]) << " expected " << int(tc.samples[static_cast<size_t>(i)]) << "\n";
                ok = false;
            }
        }
        // Verify Cb
        for (int i = 0; i < 64 && ok; ++i) {
            if (dut.cb_out[i] != tc.samples[static_cast<size_t>(256 + i)]) {
                std::cerr << "FAIL " << tc.name << ": cb_out[" << i << "] = "
                          << int(dut.cb_out[i]) << " expected " << int(tc.samples[static_cast<size_t>(256 + i)]) << "\n";
                ok = false;
            }
        }
        // Verify Cr
        for (int i = 0; i < 64 && ok; ++i) {
            if (dut.cr_out[i] != tc.samples[static_cast<size_t>(320 + i)]) {
                std::cerr << "FAIL " << tc.name << ": cr_out[" << i << "] = "
                          << int(dut.cr_out[i]) << " expected " << int(tc.samples[static_cast<size_t>(320 + i)]) << "\n";
                ok = false;
            }
        }

        if (ok) ++pass;
        else ++fail;
    }

    // Test 9: reset during operation (must cleanly abort)
    {
        dut.reset = 1; tick(dut); tick(dut);
        dut.reset = 0; tick(dut);
        dut.start = 1; tick(dut); dut.start = 0;
        // Write 100 samples then reset
        for (int i = 0; i < 100; ++i) {
            dut.wr_valid = 1; dut.wr_data = 42; tick(dut);
        }
        dut.wr_valid = 0;
        dut.reset = 1; tick(dut); tick(dut);
        dut.reset = 0; tick(dut);
        if (dut.busy || dut.done) {
            std::cerr << "FAIL reset_mid: busy/done after reset\n";
            ++fail;
        } else {
            ++pass;
        }
    }

    // Test 10: back-to-back (start new after done, no reset)
    {
        dut.reset = 1; tick(dut); tick(dut);
        dut.reset = 0; tick(dut);

        for (int round = 0; round < 2; ++round) {
            dut.start = 1; tick(dut); dut.start = 0;
            for (int i = 0; i < 384; ++i) {
                dut.wr_valid = 1;
                dut.wr_data = static_cast<uint8_t>((round + 1) * 50 + i % 200);
                tick(dut);
            }
            dut.wr_valid = 0;
            if (!dut.done) {
                std::cerr << "FAIL back_to_back round " << round << ": no done\n";
                ++fail; goto end;
            }
        }
        // Verify second round's data
        bool ok = true;
        for (int i = 0; i < 256 && ok; ++i) {
            uint8_t exp = static_cast<uint8_t>(100 + i % 200);
            if (dut.luma_out[i] != exp) {
                std::cerr << "FAIL back_to_back: luma_out[" << i << "] = "
                          << int(dut.luma_out[i]) << " expected " << int(exp) << "\n";
                ok = false;
            }
        }
        if (ok) ++pass; else ++fail;
    }

    // Degeneracy check: at least one test must have non-uniform output
    {
        // The counting pattern has 256 distinct luma values — verify
        dut.reset = 1; tick(dut); tick(dut);
        dut.reset = 0; tick(dut);
        dut.start = 1; tick(dut); dut.start = 0;
        for (int i = 0; i < 384; ++i) {
            dut.wr_valid = 1;
            dut.wr_data = static_cast<uint8_t>(i & 0xFF);
            tick(dut);
        }
        dut.wr_valid = 0;
        int distinctLuma = 0;
        std::array<bool, 256> seen{};
        for (int i = 0; i < 256; ++i) {
            if (!seen[dut.luma_out[i]]) { seen[dut.luma_out[i]] = true; ++distinctLuma; }
        }
        if (distinctLuma < 200) {
            std::cerr << "DEGENERACY: only " << distinctLuma << " distinct luma values"
                      << " — passthrough may not be working\n";
            ++fail;
        } else {
            ++pass;
        }
        std::cout << "Degeneracy: " << distinctLuma << "/256 distinct luma values in counting pattern\n";
    }

end:
    std::cout << "I_PCM passthrough: " << pass << " pass, " << fail << " fail"
              << " out of " << (pass + fail) << " tests\n";
    if (fail) {
        std::cerr << "I_PCM PASSTHROUGH TEST FAILED\n";
        return 1;
    }
    std::cout << "I_PCM PASSTHROUGH TEST PASS\n";
    return 0;
}
