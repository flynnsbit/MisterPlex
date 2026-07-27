#include "Vstream_path_ddr_ring_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr uint32_t DATA_PHYS = 0x30100000u;
constexpr uint32_t CTRL_PHYS = 0x30140000u;
constexpr uint32_t RING_BYTES = 262144u;
constexpr uint32_t DATA_W = DATA_PHYS >> 3;
constexpr uint32_t CTRL_W = CTRL_PHYS >> 3;
constexpr uint32_t MAGIC_CTRL = 0x504C5842u;

int failures = 0;

void expect(bool cond, const std::string& msg) {
    if (!cond) {
        std::cerr << msg << "\n";
        ++failures;
    }
}

struct DdrModel {
    struct Pending {
        int delay = 0;
        uint32_t addr = 0;
    };

    std::unordered_map<uint32_t, uint64_t> mem;
    std::vector<Pending> pending;

    uint64_t load(uint32_t addr) const {
        auto it = mem.find(addr);
        return it == mem.end() ? 0 : it->second;
    }

    void storeByte(uint32_t byteOffset, uint8_t v) {
        uint32_t qaddr = DATA_W + ((byteOffset & (RING_BYTES - 1u)) >> 3);
        uint32_t lane = byteOffset & 7u;
        uint64_t word = load(qaddr);
        word &= ~(0xffull << (lane * 8u));
        word |= static_cast<uint64_t>(v) << (lane * 8u);
        mem[qaddr] = word;
    }

    void writeRing(uint32_t absoluteStart, const std::vector<uint8_t>& bytes) {
        for (size_t i = 0; i < bytes.size(); ++i)
            storeByte(absoluteStart + static_cast<uint32_t>(i), bytes[i]);
    }

    void publishCtrl(uint32_t writeCount, bool epoch) {
        mem[CTRL_W] = (static_cast<uint64_t>(epoch ? 1u : 0u) << 63) |
                      (static_cast<uint64_t>(writeCount & 0x7fffffffu) << 32) |
                      MAGIC_CTRL;
    }

    void afterPosedge(Vstream_path_ddr_ring_tb_top& dut) {
        if (dut.ddr_we)
            mem[static_cast<uint32_t>(dut.ddr_addr)] = dut.ddr_din;
        if (dut.ddr_rd)
            pending.push_back(Pending{2, static_cast<uint32_t>(dut.ddr_addr)});

        dut.ddr_model_dout_ready = 0;
        dut.ddr_model_dout = 0;
        std::vector<Pending> next;
        for (auto p : pending) {
            --p.delay;
            if (p.delay <= 0 && !dut.ddr_model_dout_ready) {
                dut.ddr_model_dout = load(p.addr);
                dut.ddr_model_dout_ready = 1;
            } else {
                next.push_back(p);
            }
        }
        pending.swap(next);
    }
};

void tick(Vstream_path_ddr_ring_tb_top& dut, DdrModel& ddr) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
    ddr.afterPosedge(dut);
}

void reset(Vstream_path_ddr_ring_tb_top& dut, DdrModel& ddr) {
    dut.reset = 1;
    dut.ioctl_download = 0;
    dut.ioctl_wr = 0;
    dut.ioctl_dout = 0;
    dut.enable = 1;
    dut.flush = 0;
    dut.ddr_stream_enable = 0;
    dut.ddr_busy = 0;
    dut.ddr_model_dout = 0;
    dut.ddr_model_dout_ready = 0;
    for (int i = 0; i < 6; ++i)
        tick(dut, ddr);
    dut.reset = 0;
    tick(dut, ddr);
}

void sendIoctl(Vstream_path_ddr_ring_tb_top& dut, DdrModel& ddr,
               const std::vector<uint8_t>& bytes) {
    dut.ddr_stream_enable = 0;
    dut.ioctl_download = 1;
    for (uint8_t b : bytes) {
        dut.ioctl_dout = b;
        dut.ioctl_wr = 1;
        tick(dut, ddr);
        dut.ioctl_wr = 0;
        tick(dut, ddr);
    }
    dut.ioctl_download = 0;
    for (int i = 0; i < 300; ++i)
        tick(dut, ddr);
}

bool waitFor(Vstream_path_ddr_ring_tb_top& dut, DdrModel& ddr, int cycles,
             bool (*pred)(const Vstream_path_ddr_ring_tb_top&)) {
    for (int i = 0; i < cycles; ++i) {
        tick(dut, ddr);
        if (pred(dut))
            return true;
    }
    return false;
}

bool count2(const Vstream_path_ddr_ring_tb_top& dut) { return dut.nalu_count >= 2; }
bool active(const Vstream_path_ddr_ring_tb_top& dut) { return dut.stream_ddr_active; }
bool overrunSeen(const Vstream_path_ddr_ring_tb_top& dut) {
    return dut.stream_ddr_overruns != 0;
}
bool underrunSeen(const Vstream_path_ddr_ring_tb_top& dut) {
    return dut.stream_ddr_underruns != 0;
}
bool wrapBytesDone(const Vstream_path_ddr_ring_tb_top& dut) {
    return dut.stream_ddr_bytes_out >= 13;
}

void runIoctlStillWorks() {
    Vstream_path_ddr_ring_tb_top dut;
    DdrModel ddr;
    reset(dut, ddr);
    std::vector<uint8_t> annexb = {
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00,
        0x00, 0x00, 0x01, 0x68, 0xce, 0x06,
    };
    sendIoctl(dut, ddr, annexb);
    expect(dut.nalu_count >= 2, "ioctl F3 path no longer reports >=2 NALs");
    expect(dut.last_nal_type == 0x68, "ioctl F3 path lost PPS NAL framing");
}

void runWrapNormal() {
    Vstream_path_ddr_ring_tb_top dut;
    DdrModel ddr;
    reset(dut, ddr);
    const uint32_t start = RING_BYTES - 3u;
    std::vector<uint8_t> annexb = {
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00,
        0x00, 0x00, 0x01, 0x68, 0xce, 0x06,
    };
    ddr.publishCtrl(start, true);
    dut.ddr_stream_enable = 1;
    expect(waitFor(dut, ddr, 600, active), "DDR ring never became active");
    ddr.writeRing(start, annexb);
    ddr.publishCtrl(start + static_cast<uint32_t>(annexb.size()), true);
    expect(waitFor(dut, ddr, 4000, count2), "DDR ring wrap did not deliver two NALs");
    expect(waitFor(dut, ddr, 1000, wrapBytesDone), "DDR ring wrap did not drain all bytes");
    expect(dut.last_nal_type == 0x68, "DDR ring wrap corrupted PPS NAL type");
    expect(dut.stream_ddr_bytes_out >= annexb.size(),
           "DDR ring bytes_out did not advance: got " +
               std::to_string(dut.stream_ddr_bytes_out) + " expected >= " +
               std::to_string(annexb.size()));
    expect(dut.stream_ddr_host_write == start + annexb.size(),
           "DDR ring host write counter mismatch");
}

void runUnderrun() {
    Vstream_path_ddr_ring_tb_top dut;
    DdrModel ddr;
    reset(dut, ddr);
    std::vector<uint8_t> bytes = {0, 0, 1, 0x67, 0x11, 0x22, 0x33, 0x44};
    ddr.publishCtrl(0, true);
    dut.ddr_stream_enable = 1;
    expect(waitFor(dut, ddr, 600, active), "underrun setup never became active");
    ddr.writeRing(0, bytes);
    ddr.publishCtrl(static_cast<uint32_t>(bytes.size()), true);
    auto consumed = [&](const Vstream_path_ddr_ring_tb_top& d) {
        return d.stream_ddr_bytes_out >= bytes.size();
    };
    for (int i = 0; i < 3000 && !consumed(dut); ++i)
        tick(dut, ddr);
    expect(consumed(dut), "underrun setup never consumed initial bytes");
    expect(waitFor(dut, ddr, 2000, underrunSeen), "DDR ring underrun telemetry stayed zero");
}

void runOverrun() {
    Vstream_path_ddr_ring_tb_top dut;
    DdrModel ddr;
    reset(dut, ddr);
    ddr.publishCtrl(0, true);
    dut.ddr_stream_enable = 1;
    expect(waitFor(dut, ddr, 600, active), "overrun setup never became active");
    ddr.publishCtrl(RING_BYTES + 1u, true);
    expect(waitFor(dut, ddr, 1200, overrunSeen), "DDR ring overrun telemetry stayed zero");
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    runIoctlStillWorks();
    runWrapNormal();
    runUnderrun();
    runOverrun();
    if (failures) {
        std::cerr << "stream_path DDR ring RTL check FAILED: " << failures << " failures\n";
        return 1;
    }
    std::cout << "stream_path DDR ring RTL check PASS: ioctl_NALs>=2 wrap_NALs>=2 "
                 "underrun_red_guard overrun_red_guard ring_bytes=262144\n";
    return 0;
}
