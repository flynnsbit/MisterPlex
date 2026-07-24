#include "fpga_spi.hpp"

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <mutex>
#include <new>
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

// Serialize all HPS↔FPGA SPI (F1/F2/F3 + status). Audio + video + stream threads
// share one FpgaSpi; concurrent sendFileTx without this races GPO and Main pause.
// Also guards err_ (std::string is not thread-safe — concurrent writes crashed soak).
std::mutex& spiMutex() {
    static std::mutex m;
    return m;
}

// Main_MiSTer owns the same SPI; STOP it for exclusive status/file ops.
// Matches /media/fat/MiSTer and MiSTer_groovy-style host binaries.
// IMPORTANT: no system()/fork here — multi-threaded misterplexd (F1+F2+F3) must
// not call system() under load (glibc fork+malloc deadlock → silent process death).
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
        // Exact basename match for main host binaries only (avoid "mister*" false positives)
        const char* base = std::strrchr(argv0, '/');
        base = base ? base + 1 : argv0;
        if (std::strcmp(base, "MiSTer") == 0 || std::strcmp(base, "MiSTer_groovy") == 0)
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
        pids = findMisterPids();
        for (pid_t p : pids)
            kill(p, SIGSTOP);
        if (!pids.empty())
            usleep(10000); // let SPI settle
    }
    ~MainPause() {
        for (pid_t p : pids)
            kill(p, SIGCONT);
    }
    MainPause(const MainPause&) = delete;
    MainPause& operator=(const MainPause&) = delete;
};

// Order: process mutex → flock → MainPause. No system()/fork under the lock.
struct SpiExclusive {
    std::lock_guard<std::mutex> mu;
    int lfd = -1;
    alignas(MainPause) unsigned char pause_storage_[sizeof(MainPause)]{};
    MainPause* pause = nullptr;
    explicit SpiExclusive(bool pauseMain) : mu(spiMutex()) {
        lfd = ::open("/tmp/misterplex_spi.lock", O_CREAT | O_RDWR, 0666);
        if (lfd >= 0)
            flock(lfd, LOCK_EX);
        if (pauseMain)
            pause = new (pause_storage_) MainPause(true);
    }
    ~SpiExclusive() {
        if (pause) {
            pause->~MainPause();
            pause = nullptr;
        }
        if (lfd >= 0) {
            flock(lfd, LOCK_UN);
            ::close(lfd);
        }
    }
    SpiExclusive(const SpiExclusive&) = delete;
    SpiExclusive& operator=(const SpiExclusive&) = delete;
};

bool gpiUserMode(volatile uint32_t* map) {
    if (!map)
        return false;
    constexpr uint32_t kMgrBase = 0xFF706000;
    constexpr uint32_t kMapBase = 0xFF000000;
    volatile uint32_t* gpi = map + ((kMgrBase - kMapBase + 0x14) >> 2);
    // MiSTer: high bit of GPI indicates not-in-user-mode (core reconfig / menu).
    return (static_cast<int>(*gpi) >= 0);
}

} // namespace

FpgaSpi::~FpgaSpi() { close(); }

void FpgaSpi::setErr(std::string msg) {
    // Prefer calling under SpiExclusive; lock if free so lastError races are safe.
    std::lock_guard<std::mutex> g(spiMutex());
    err_ = std::move(msg);
}

void FpgaSpi::clearErr() {
    std::lock_guard<std::mutex> g(spiMutex());
    err_.clear();
}

std::string FpgaSpi::lastError() const {
    std::lock_guard<std::mutex> g(spiMutex());
    return err_;
}

bool FpgaSpi::open() {
    close();
    fd_ = ::open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (fd_ < 0) {
        setErr("open /dev/mem failed");
        return false;
    }
    void* p = mmap(nullptr, kMapSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, kMapBase);
    if (p == MAP_FAILED) {
        setErr("mmap FPGA regs failed");
        ::close(fd_);
        fd_ = -1;
        return false;
    }
    map_ = static_cast<volatile uint32_t*>(p);
    // Seed gpo from hardware
    volatile uint32_t* gpo = map_ + ((kMgrBase - kMapBase + 0x10) >> 2);
    gpo_copy_ = *gpo;
    clearErr();
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
    // Caller must hold SpiExclusive (spiMutex). Touch err_ without re-locking.
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
    SpiExclusive guard(true);
    if (!gpiUserMode(map_)) {
        err_ = "FPGA not in user mode";
        return false;
    }

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

    if (!err_.empty())
        return false;
    err_.clear();
    return true;
}

bool FpgaSpi::sendFileTx(const uint8_t* data, size_t len, uint8_t index) {
    if (!ok() || !data || !len) {
        err_ = "sendFileTx: not open or empty";
        return false;
    }
    // Clear stale err_ from prior DDR probe/fail so SPI F1/F2/F3 is not poisoned.
    err_.clear();
    auto t0 = std::chrono::steady_clock::now();
    // Mutex + flock + Main pause (no system()/fork — thread-safe under STREAM load).
    SpiExclusive guard(true);
    if (!gpiUserMode(map_)) {
        err_ = "FPGA not in user mode";
        return false;
    }

    setIndex(index);
    setDownload(1);

    // Chunk data with FIO_FILE_TX_DAT sessions.
    // Lab measure @320×240 (153600 B): 8 KiB→~220 ms, 32 KiB→~194 ms, 128 KiB→~196 ms.
    // SPI is the ceiling (~0.8 MB/s); DDR3 bulk (3.1b) needed for real-time F1.
    const size_t chunk = 32768;
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
            return false;
        }
    }

    setDownload(0);
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

bool FpgaSpi::sendRgb565Bytes(const uint8_t* rgb565le, size_t len, uint8_t index) {
    if (!rgb565le || !len || (len & 1)) {
        err_ = "bad rgb565 bytes";
        return false;
    }
    return sendFileTx(rgb565le, len, index);
}

bool FpgaSpi::sendRgb565Frame(const uint16_t* rgb, int w, int h, uint8_t index) {
    if (!rgb || w <= 0 || h <= 0) {
        err_ = "bad rgb565 frame";
        return false;
    }
    const size_t npx = static_cast<size_t>(w) * static_cast<size_t>(h);
    std::vector<uint8_t> packed(npx * 2);
    for (size_t i = 0; i < npx; ++i) {
        const uint16_t p = rgb[i];
        packed[i * 2 + 0] = static_cast<uint8_t>(p & 0xFF);
        packed[i * 2 + 1] = static_cast<uint8_t>(p >> 8);
    }
    return sendFileTx(packed.data(), packed.size(), index);
}

bool FpgaSpi::sendRgb565FrameDdr(const uint8_t* rgb565le, size_t len, int bank) {
    if (!rgb565le || len != kDdrFrameBytes) {
        err_ = "sendRgb565FrameDdr: need 320x240 RGB565 (153600 B)";
        return false;
    }
    if (bank < 0 || bank > 1) {
        err_ = "sendRgb565FrameDdr: bank must be 0 or 1";
        return false;
    }
    auto t0 = std::chrono::steady_clock::now();

    // Map frame bank in HPS-visible DDR (same window cores use for 0x3xxxxxxx).
    const off_t phys = static_cast<off_t>(kDdrFrameBase + static_cast<uint32_t>(bank) * kDdrFrameStride);
    int mfd = ::open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (mfd < 0) {
        err_ = "sendRgb565FrameDdr: open /dev/mem failed";
        return false;
    }
    // Map a full page-aligned region covering the bank stride.
    const size_t mapLen = kDdrFrameStride;
    void* p = mmap(nullptr, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, phys);
    if (p == MAP_FAILED) {
        err_ = "sendRgb565FrameDdr: mmap frame bank failed";
        ::close(mfd);
        return false;
    }
    std::memcpy(p, rgb565le, len);
    // Ensure visibility before kicking the FPGA DMA (O_SYNC map + explicit clean).
    __sync_synchronize();
    munmap(p, mapLen);
    ::close(mfd);

    // status[13]=bank, status[12]=start (rising edge). Pulse start high→sample→low.
    if (!setStatusBit(13, bank ? 1 : 0)) {
        err_ = "sendRgb565FrameDdr: set bank bit failed: " + err_;
        return false;
    }
    if (!setStatusBit(12, 0))
        return false;
    usleep(200); // settle so rising edge is clean
    if (!setStatusBit(12, 1))
        return false;
    // Core DMA for 153600 B is typically <2 ms @ clk_sys. Avoid SPI status polls
    // in the hot path (each UIO_GET_STATUS pauses Main ~ms). One-shot verify once.
    static int ddr_verified = 0; // 0=unknown, 1=ok, -1=missing
    if (ddr_verified == 0) {
        bool saw_busy = false;
        for (int i = 0; i < 20 && !saw_busy; ++i) {
            usleep(200);
            CoreStatus st;
            if (readCoreStatus(st) && st.ddr_busy)
                saw_busy = true;
        }
        // Drain busy
        for (int i = 0; i < 20; ++i) {
            usleep(200);
            CoreStatus st;
            if (readCoreStatus(st) && !st.ddr_busy)
                break;
        }
        ddr_verified = saw_busy ? 1 : -1;
        if (!saw_busy) {
            setStatusBit(12, 0);
            err_ = "sendRgb565FrameDdr: no ddr_busy (core RBF lacks 3.1b DDR path?)";
            return false;
        }
    } else if (ddr_verified < 0) {
        setStatusBit(12, 0);
        err_ = "sendRgb565FrameDdr: DDR path previously unavailable";
        return false;
    } else {
        usleep(2500); // allow DMA to finish without SPI thrash
    }
    setStatusBit(12, 0);
    // Ensure Force-bars debug off so frame_store is visible (same as SPI path).
    setStatusBit(9, 0);

    auto t1 = std::chrono::steady_clock::now();
    lastPushMs_ = std::chrono::duration<double, std::milli>(t1 - t0).count();
    err_.clear();
    return true;
}

bool FpgaSpi::sendRgb24FrameDdr(const uint8_t* rgb, int w, int h, int bank) {
    if (!rgb || w != 320 || h != 240) {
        err_ = "sendRgb24FrameDdr: need 320x240 RGB24";
        return false;
    }
    std::vector<uint8_t> packed(kDdrFrameBytes);
    size_t o = 0;
    for (int i = 0; i < w * h; ++i) {
        const uint8_t r = rgb[i * 3 + 0];
        const uint8_t g = rgb[i * 3 + 1];
        const uint8_t b = rgb[i * 3 + 2];
        const uint16_t px =
            static_cast<uint16_t>(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
        packed[o++] = static_cast<uint8_t>(px & 0xFF);
        packed[o++] = static_cast<uint8_t>(px >> 8);
    }
    return sendRgb565FrameDdr(packed.data(), packed.size(), bank);
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
    // Mutex + flock + Main pause so UIO_GET_STATUS is not interleaved.
    SpiExclusive guard(true);
    if (!gpiUserMode(map_)) {
        err_ = "FPGA not in user mode";
        return false;
    }

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

    if (!err_.empty())
        return false;
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
    // [39:32] = {ddr_busy, 0, slice_qp[5:0]}
    // [127:96] {residual_dc[7:0], stream_bytes_in[23:0]} (3.3k)
    const uint8_t hi = static_cast<uint8_t>((w2 >> 8) & 0xFF);
    s.residual_ok = (hi & 0x80) != 0;
    s.residual_tc = static_cast<uint8_t>((hi >> 2) & 0x1F);
    s.residual_t1 = static_cast<uint8_t>(hi & 0x3);
    s.ddr_busy = (w2 & 0x80) != 0;
    s.slice_qp = static_cast<uint8_t>(w2 & 0x3F);
    s.stream_fifo_level = 0;
    // [95:64] = {sps_width, sps_height}
    s.sps_height = static_cast<uint16_t>(raw[8] | (raw[9] << 8));
    s.sps_width = static_cast<uint16_t>(raw[10] | (raw[11] << 8));
    s.stream_bytes_seen = 0;
    s.stream_bytes_in = static_cast<uint32_t>(raw[12] | (raw[13] << 8) | (raw[14] << 16));
    s.residual_dc = static_cast<int8_t>(raw[15]);
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
