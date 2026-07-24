#include "fpga_spi.hpp"

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <string>
#include <sys/file.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

// usleep
#include <time.h>

namespace misterplex {
namespace {

constexpr uint8_t FIO_FILE_TX = 0x53;
constexpr uint8_t FIO_FILE_TX_DAT = 0x54;
constexpr uint8_t FIO_FILE_INDEX = 0x55;
constexpr uint8_t UIO_SET_STATUS2 = 0x1e;
constexpr uint8_t UIO_GET_STATUS = 0x29;

// Main_MiSTer owns the same SPI; STOP it for exclusive status/file ops.
// Matches /media/fat/MiSTer and MiSTer_groovy-style host binaries.
std::vector<pid_t> findMisterPids() {
    std::vector<pid_t> out;
    DIR* d = opendir("/proc");
    if (!d)
        return out;
    while (dirent* e = readdir(d)) {
        if (e->d_name[0] < '1' || e->d_name[0] > '9')
            continue;
        char path[96];
        std::snprintf(path, sizeof(path), "/proc/%.32s/cmdline", e->d_name);
        int fd = ::open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            continue;
        char buf[256]{};
        ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
        ::close(fd);
        if (n <= 0)
            continue;
        // cmdline is NUL-separated argv; argv0 is first token
        const char* argv0 = buf;
        if (std::strstr(argv0, "misterplex") != nullptr)
            continue;
        if (std::strstr(argv0, "MiSTer") != nullptr || std::strstr(argv0, "mister") != nullptr)
            out.push_back(static_cast<pid_t>(std::atoi(e->d_name)));
    }
    closedir(d);
    return out;
}

struct MainPause {
    std::vector<pid_t> pids;
    explicit MainPause(bool enable) {
        if (!enable)
            return;
        // BusyBox killall is reliable on MiSTer rootfs
        int r = system("killall -STOP MiSTer 2>/dev/null; "
                       "killall -STOP MiSTer_groovy 2>/dev/null; true");
        (void)r;
        pids = findMisterPids();
        for (pid_t p : pids)
            kill(p, SIGSTOP);
        usleep(15000); // let SPI settle
    }
    ~MainPause() {
        for (pid_t p : pids)
            kill(p, SIGCONT);
        int r = system("killall -CONT MiSTer 2>/dev/null; "
                       "killall -CONT MiSTer_groovy 2>/dev/null; true");
        (void)r;
    }
    MainPause(const MainPause&) = delete;
    MainPause& operator=(const MainPause&) = delete;
};

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
    // Pause Main for clean FIO_FILE_* (short transfers; resume in dtor).
    MainPause pause(true);
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

bool FpgaSpi::sendPcmChunk(const uint8_t* pcm, size_t len, uint8_t index) {
    if (!pcm || !len) {
        err_ = "sendPcmChunk: empty";
        return false;
    }
    // Align to 4-byte stereo frames
    len &= ~size_t(3);
    if (!len)
        return true;
    return sendFileTx(pcm, len, index);
}

bool FpgaSpi::sendBitstreamChunk(const uint8_t* data, size_t len, uint8_t index) {
    if (!data || !len) {
        err_ = "sendBitstreamChunk: empty";
        return false;
    }
    return sendFileTx(data, len, index);
}

bool FpgaSpi::flushAudioFifo() {
    // Pulse status[10] high then low (OSD T[10] / present_core af_wr_flush)
    if (!setStatusBit(10, 1))
        return false;
    // brief hold so FPGA samples the bit
    usleep(2000);
    return setStatusBit(10, 0);
}

bool FpgaSpi::flushBitstreamFifo() {
    if (!setStatusBit(11, 1))
        return false;
    usleep(2000);
    return setStatusBit(11, 0);
}

bool FpgaSpi::getCoreStatus(uint8_t out[16]) {
    if (!ok() || !out) {
        err_ = "getCoreStatus: not open";
        return false;
    }
    // Pause Main so UIO_GET_STATUS is not interleaved mid-transaction.
    MainPause pause(true);
    int lfd = ::open("/tmp/misterplex_spi.lock", O_CREAT | O_RDWR, 0666);
    if (lfd >= 0)
        flock(lfd, LOCK_EX);

    enableIo(1);
    // Main protocol: spi_w(cmd) returns {4'hA, stflg}; next words are status_req.
    uint16_t hdr = spiWord(UIO_GET_STATUS);
    (void)hdr;
    for (int i = 0; i < 16; i += 2) {
        uint16_t w = spiWord(0);
        out[i] = static_cast<uint8_t>(w & 0xFF);
        out[i + 1] = static_cast<uint8_t>((w >> 8) & 0xFF);
    }
    enableIo(0);

    if (lfd >= 0) {
        flock(lfd, LOCK_UN);
        ::close(lfd);
    }
    err_.clear();
    return true;
}

FpgaSpi::CoreStatus FpgaSpi::parseCoreStatus(const uint8_t raw[16]) {
    CoreStatus s;
    const uint16_t w0 = static_cast<uint16_t>(raw[0] | (raw[1] << 8));
    const uint16_t w1 = static_cast<uint16_t>(raw[2] | (raw[3] << 8));
    const uint16_t w2 = static_cast<uint16_t>(raw[4] | (raw[5] << 8));
    const uint16_t w3 = static_cast<uint16_t>(raw[6] | (raw[7] << 8));
    s.has_frame = (w0 & 1) != 0;
    s.has_audio = (w0 & 2) != 0;
    s.has_stream = (w0 & 4) != 0;
    s.audio_underrun = (w0 & 8) != 0;
    s.has_idr = (w0 & 16) != 0;
    s.stub_busy = (w0 & 32) != 0;
    s.sps_valid = (w0 & 64) != 0;
    s.pps_valid = (w0 & 128) != 0;
    s.last_nal_type = static_cast<uint8_t>((w0 >> 8) & 0xFF);
    s.nalu_count = w1;
    s.stream_fifo_level = w2;
    // [63:48] = {slice_type[7:0], first_mb_type[7:0]}
    s.first_mb_type = static_cast<uint8_t>(w3 & 0xFF);
    s.slice_type = static_cast<uint8_t>((w3 >> 8) & 0xFF);
    s.stub_frames = s.slice_type;
    s.wr_count_lo = w3;
    // [47:40] {residual_ok, residual_tc[4:0], residual_t1[1:0]}
    // [39:32] slice_qp
    const uint8_t hi = static_cast<uint8_t>((w2 >> 8) & 0xFF);
    s.residual_ok = (hi & 0x80) != 0;
    s.residual_tc = static_cast<uint8_t>((hi >> 2) & 0x1F);
    s.residual_t1 = static_cast<uint8_t>(hi & 0x3);
    s.slice_qp = static_cast<uint8_t>(w2 & 0x3F);
    s.stream_fifo_level = 0;
    // [95:64] = {sps_width, sps_height}
    s.sps_height = static_cast<uint16_t>(raw[8] | (raw[9] << 8));
    s.sps_width = static_cast<uint16_t>(raw[10] | (raw[11] << 8));
    s.stream_bytes_seen = 0;
    s.stream_bytes_in = static_cast<uint32_t>(raw[12] | (raw[13] << 8) | (raw[14] << 16) | (raw[15] << 24));
    // idr sticky still in flags; count not in status this rev
    s.idr_count = s.has_idr ? 1 : 0;
    return s;
}

bool FpgaSpi::readCoreStatus(CoreStatus& out) {
    // Prefer consistent samples: same nalu+bytes_in twice, or nalu>=1 with matching bytes.
    CoreStatus best{};
    bool have = false;
    for (int attempt = 0; attempt < 8; ++attempt) {
        uint8_t raw[16]{};
        if (!getCoreStatus(raw))
            return false;
        CoreStatus s = parseCoreStatus(raw);
        // Sanity: bytes_seen should be <= bytes_in + small slack, nalu not huge garbage
        bool sane = s.nalu_count < 10000 && s.stream_bytes_in < (1u << 28) &&
                    s.sps_width <= 4096 && s.sps_height <= 2160;
        if (!sane) {
            usleep(10000);
            continue;
        }
        if (have && s.nalu_count == best.nalu_count && s.stream_bytes_in == best.stream_bytes_in &&
            s.has_stream == best.has_stream && s.sps_valid == best.sps_valid) {
            out = s;
            return true;
        }
        best = s;
        have = true;
        // Strong signal: stream with NALs (and optional SPS)
        if (s.has_stream && s.stream_bytes_in > 0 && s.nalu_count > 0) {
            out = s;
            return true;
        }
        usleep(10000);
    }
    out = best;
    return have;
}

} // namespace misterplex
