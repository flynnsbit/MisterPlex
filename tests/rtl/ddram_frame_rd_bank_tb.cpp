#include "Vddram_frame_rd.h"
#include "verilated.h"

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

static uint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vddram_frame_rd& dut) {
    dut.clk = 0;
    dut.eval();
    ++main_time;
    dut.clk = 1;
    dut.eval();
    ++main_time;
    dut.clk = 0;
    dut.eval();
}

static void init_inputs(Vddram_frame_rd& dut) {
    dut.clk = 0;
    dut.reset = 0;
    dut.start_req = 0;
    dut.bank_sel = 0;
    dut.swap_pending = 0;
    dut.status_osd = 0;
    dut.input_cmd_valid = 0;
    dut.input_cmd = 0;
    dut.sdram_test_state = 0;
    dut.sdram_size_code = 0;
    dut.sdram_error_count = 0;
    dut.sdram_read_sample = 0;
    dut.sdram_first_fail_valid = 0;
    dut.sdram_first_fail_addr = 0;
    dut.sdram_first_fail_expect = 0;
    dut.frame_sdram_state = 0;
    dut.frame_underrun_count = 0;
    dut.DDRAM_BUSY = 0;
    dut.DDRAM_DOUT = 0;
    dut.DDRAM_DOUT_READY = 0;
    dut.wr_ready = 1;
}

static void reset(Vddram_frame_rd& dut) {
    init_inputs(dut);
    dut.reset = 1;
    tick(dut);
    tick(dut);
    dut.reset = 0;
}

static uint32_t expected_qword_addr(int bank) {
    const auto layout =
        misterplex::makeDdrFrameLayout(misterplex::plex480pDdrFrameGeometry(),
                                       misterplex::kDdrFramePhysBase,
                                       misterplex::kDdrFrameStrideAlign,
                                       misterplex::DdrFrameFormat::Yuv420p);
    return (layout.phys_base + static_cast<uint32_t>(bank) * layout.bank_stride) >> 3;
}

static uint32_t expected_stride() {
    const auto layout =
        misterplex::makeDdrFrameLayout(misterplex::plex480pDdrFrameGeometry(),
                                       misterplex::kDdrFramePhysBase,
                                       misterplex::kDdrFrameStrideAlign,
                                       misterplex::DdrFrameFormat::Yuv420p);
    return layout.bank_stride;
}

static uint32_t doorbell_qword_addr() {
    const auto layout =
        misterplex::makeDdrFrameLayout(misterplex::plex480pDdrFrameGeometry(),
                                       misterplex::kDdrFramePhysBase,
                                       misterplex::kDdrFrameStrideAlign,
                                       misterplex::DdrFrameFormat::Yuv420p);
    return layout.doorbell_phys >> 3;
}

static bool wait_frame_read(Vddram_frame_rd& dut, const char* path, int bank) {
    const uint32_t expect = expected_qword_addr(bank);
    const uint32_t db = doorbell_qword_addr();
    for (int i = 0; i < 64; ++i) {
        tick(dut);
        if (dut.DDRAM_RD && dut.DDRAM_ADDR != db) {
            if (dut.DDRAM_ADDR != expect) {
                std::fprintf(stderr,
                             "DDR bank select RTL failed for %s bank=%d: first read "
                             "addr=0x%08x expected=0x%08x (derived stride=0x%05x)\n",
                             path, bank, static_cast<unsigned>(dut.DDRAM_ADDR),
                             static_cast<unsigned>(expect),
                             static_cast<unsigned>(expected_stride()));
                return false;
            }
            return true;
        }
    }
    std::fprintf(stderr, "DDR bank select RTL failed for %s bank=%d: no frame read issued\n",
                 path, bank);
    return false;
}

static bool check_spi_bank(Vddram_frame_rd& dut, int bank) {
    reset(dut);
    dut.bank_sel = bank;
    dut.start_req = 1;
    tick(dut);
    dut.start_req = 0;
    return wait_frame_read(dut, "SPI status[13]", bank);
}

static bool check_doorbell_bank(Vddram_frame_rd& dut, int bank) {
    reset(dut);
    const uint32_t db = doorbell_qword_addr();
    bool saw_poll = false;
    for (int i = 0; i < 512; ++i) {
        tick(dut);
        if (dut.DDRAM_RD && dut.DDRAM_ADDR == db) {
            saw_poll = true;
            break;
        }
    }
    if (!saw_poll) {
        std::fprintf(stderr, "DDR bank select RTL failed for doorbell bank=%d: no doorbell poll\n",
                     bank);
        return false;
    }
    const uint32_t hi =
        misterplex::ddrDoorbellHi(1, bank, misterplex::DdrFrameFormat::Yuv420p);
    dut.DDRAM_DOUT = (static_cast<uint64_t>(hi) << 32) | misterplex::kDdrFrameDoorbellMagic;
    dut.DDRAM_DOUT_READY = 1;
    tick(dut);
    dut.DDRAM_DOUT_READY = 0;
    dut.DDRAM_DOUT = 0;
    return wait_frame_read(dut, "mmap doorbell DDRAM_DOUT[63]", bank);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int fails = 0;
    Vddram_frame_rd dut;
    for (int bank = 0; bank <= 1; ++bank) {
        if (!check_spi_bank(dut, bank))
            ++fails;
        if (!check_doorbell_bank(dut, bank))
            ++fails;
    }
    if (fails)
        return 1;
    std::puts("OK ddram_frame_rd bank select: SPI status[13] and doorbell DDRAM_DOUT[63] choose derived bank base");
    return 0;
}
