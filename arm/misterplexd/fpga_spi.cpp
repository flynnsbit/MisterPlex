#include "fpga_spi.hpp"

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

namespace misterplex {
namespace {

constexpr uint8_t FIO_FILE_TX = 0x53;
constexpr uint8_t FIO_FILE_TX_DAT = 0x54;
constexpr uint8_t FIO_FILE_INDEX = 0x55;
constexpr uint8_t UIO_SET_STATUS2 = 0x1e;

} // namespace

FpgaSpi::~FpgaSpi() { close(); }

bool FpgaSpi::open() {
    close();
    fd_ = ::open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (fd_ < 0) {
        err_ = "open /dev/mem failed";
        return false;
    }
    void* p = mmap(nullptr, kMapSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, kMapBase);
    if (p == MAP_FAILED) {
        err_ = "mmap FPGA regs failed";
        ::close(fd_);
        fd_ = -1;
        return false;
    }
    map_ = static_cast<volatile uint32_t*>(p);
    // Seed gpo from hardware
    volatile uint32_t* gpo = map_ + ((kMgrBase - kMapBase + 0x10) >> 2);
    gpo_copy_ = *gpo;
    err_.clear();
    return true;
}

void FpgaSpi::close() {
    if (map_) {
        munmap((void*)map_, kMapSize);
        map_ = nullptr;
    }
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
}

void FpgaSpi::gpoWrite(uint32_t v) {
    gpo_copy_ = v;
    volatile uint32_t* gpo = map_ + ((kMgrBase - kMapBase + 0x10) >> 2);
    *gpo = v;
}

uint32_t FpgaSpi::gpoRead() const { return gpo_copy_; }

int FpgaSpi::gpiRead() const {
    volatile uint32_t* gpi = map_ + ((kMgrBase - kMapBase + 0x14) >> 2);
    return static_cast<int>(*gpi);
}

void FpgaSpi::spiEn(uint32_t mask, int en) {
    uint32_t gpo = gpoRead() | 0x80000000u;
    gpoWrite(en ? (gpo | mask) : (gpo & ~mask));
}

uint16_t FpgaSpi::spiWord(uint16_t word) {
    uint32_t gpo = (gpoRead() & ~(0xFFFFu | SSPI_STROBE)) | word;
    gpoWrite(gpo);
    gpoWrite(gpo | SSPI_STROBE);
    int gpi;
    int spins = 0;
    do {
        gpi = gpiRead();
        if (gpi < 0) {
            err_ = "FPGA not in user mode";
            return 0;
        }
        if (++spins > 1000000) {
            err_ = "SPI ACK timeout (set)";
            return 0;
        }
    } while (!(gpi & static_cast<int>(SSPI_STROBE)));

    gpoWrite(gpo);
    spins = 0;
    do {
        gpi = gpiRead();
        if (gpi < 0) {
            err_ = "FPGA not in user mode";
            return 0;
        }
        if (++spins > 1000000) {
            err_ = "SPI ACK timeout (clr)";
            return 0;
        }
    } while (gpi & static_cast<int>(SSPI_STROBE));
    return static_cast<uint16_t>(gpi);
}

void FpgaSpi::spiByte(uint8_t b) { spiWord(b); }

void FpgaSpi::spiWriteBytes(const uint8_t* p, size_t n) {
    // Fast path (no ACK wait) — matches Main_MiSTer fpga_spi_fast for bulk data.
    uint32_t gpoH = gpoRead() & ~(0xFFFFu | SSPI_STROBE);
    while (n--) {
        uint32_t gpo = gpoH | *p++;
        gpoWrite(gpo);
        gpoWrite(gpo | SSPI_STROBE);
        gpoWrite(gpo);
    }
}

void FpgaSpi::enableFpga(int on) { spiEn(SSPI_FPGA_EN, on); }
void FpgaSpi::enableIo(int on) { spiEn(SSPI_IO_EN, on); }

void FpgaSpi::setIndex(uint8_t index) {
    enableFpga(1);
    spiByte(FIO_FILE_INDEX);
    spiByte(index);
    enableFpga(0);
}

void FpgaSpi::setDownload(int enable) {
    enableFpga(1);
    spiByte(FIO_FILE_TX);
    spiByte(enable ? 0xff : 0x00);
    enableFpga(0);
}

bool FpgaSpi::setStatusBit(int bit, int value) {
    if (!ok() || bit < 0 || bit > 127) {
        err_ = "setStatusBit: bad args";
        return false;
    }
    int lfd = ::open("/tmp/misterplex_spi.lock", O_CREAT | O_RDWR, 0666);
    if (lfd >= 0)
        flock(lfd, LOCK_EX);

    const int byte = bit / 8;
    const int b = bit % 8;
    if (value)
        status_[byte] = static_cast<uint8_t>(status_[byte] | (1u << b));
    else
        status_[byte] = static_cast<uint8_t>(status_[byte] & ~(1u << b));

    enableIo(1);
    spiWord(UIO_SET_STATUS2); // cmd on IO CS
    for (int i = 0; i < 16; i += 2) {
        uint16_t w = static_cast<uint16_t>((status_[i + 1] << 8) | status_[i]);
        spiWord(w);
    }
    enableIo(0);

    if (lfd >= 0) {
        flock(lfd, LOCK_UN);
        ::close(lfd);
    }
    err_.clear();
    return true;
}

bool FpgaSpi::sendFileTx(const uint8_t* data, size_t len, uint8_t index) {
    if (!ok() || !data || !len) {
        err_ = "sendFileTx: not open or empty";
        return false;
    }
    auto t0 = std::chrono::steady_clock::now();
    // Best-effort lock so concurrent tools don't interleave
    int lfd = ::open("/tmp/misterplex_spi.lock", O_CREAT | O_RDWR, 0666);
    if (lfd >= 0)
        flock(lfd, LOCK_EX);

    setIndex(index);
    setDownload(1);

    // Chunk data with FIO_FILE_TX_DAT sessions
    const size_t chunk = 8192;
    size_t off = 0;
    while (off < len) {
        size_t n = len - off;
        if (n > chunk)
            n = chunk;
        enableFpga(1);
        spiByte(FIO_FILE_TX_DAT);
        spiWriteBytes(data + off, n);
        enableFpga(0);
        off += n;
        if (!err_.empty()) {
            setDownload(0);
            if (lfd >= 0) {
                flock(lfd, LOCK_UN);
                ::close(lfd);
            }
            return false;
        }
    }

    setDownload(0);
    if (lfd >= 0) {
        flock(lfd, LOCK_UN);
        ::close(lfd);
    }
    auto t1 = std::chrono::steady_clock::now();
    lastPushMs_ = std::chrono::duration<double, std::milli>(t1 - t0).count();
    err_.clear();
    return true;
}

bool FpgaSpi::sendRgb24Frame(const uint8_t* rgb, int w, int h, uint8_t index) {
    if (!rgb || w <= 0 || h <= 0) {
        err_ = "bad rgb frame";
        return false;
    }
    std::vector<uint8_t> packed(static_cast<size_t>(w) * static_cast<size_t>(h) * 2);
    size_t o = 0;
    for (int i = 0; i < w * h; ++i) {
        const uint8_t r = rgb[i * 3 + 0];
        const uint8_t g = rgb[i * 3 + 1];
        const uint8_t b = rgb[i * 3 + 2];
        const uint16_t p = static_cast<uint16_t>(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
        packed[o++] = static_cast<uint8_t>(p & 0xFF);
        packed[o++] = static_cast<uint8_t>(p >> 8);
    }
    return sendFileTx(packed.data(), packed.size(), index);
}

} // namespace misterplex
