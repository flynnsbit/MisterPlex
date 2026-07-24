// Host mirror of nalu_scanner start-code logic (unit, no FPGA).
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

static int countNalu(const uint8_t* p, size_t n) {
    int count = 0;
    int zrun = 0;
    bool pend = false;
    for (size_t i = 0; i < n; ++i) {
        uint8_t b = p[i];
        if (pend) {
            ++count;
            pend = false;
            zrun = 0;
            continue;
        }
        if (b == 0x00) {
            if (zrun < 3)
                ++zrun;
        } else if (b == 0x01 && zrun >= 2) {
            pend = true;
            zrun = 0;
        } else {
            zrun = 0;
        }
    }
    return count;
}

int main() {
    // Same layout as scripts/gen_test_annexb.py
    std::vector<uint8_t> blob;
    auto add4 = [&](uint8_t t, const std::string& pay) {
        blob.insert(blob.end(), {0, 0, 0, 1, static_cast<uint8_t>(0x60 | (t & 0x1f))});
        blob.insert(blob.end(), pay.begin(), pay.end());
    };
    add4(7, "SPS");
    add4(8, "PPS");
    add4(5, "IDR");
    blob.insert(blob.end(), {0, 0, 1, 0x61, 'P'});
    int c = countNalu(blob.data(), blob.size());
    if (c != 4) {
        std::printf("FAIL count=%d want 4\n", c);
        return 1;
    }
    std::printf("test_annexb_count: OK (count=%d)\n", c);
    return 0;
}
