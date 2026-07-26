#pragma once
// Minimal MiSTer HPS→FPGA SPI bridge for ioctl file_tx (frame store ingest).
// Mirrors Main_MiSTer FIO_FILE_* protocol. Shares GPO/GPI with Main — short
// transfers only; optional flock reduces races.

#include <cstdint>
#include <string>
#include <vector>

namespace misterplex {

class FpgaSpi {
public:
    ~FpgaSpi();

    // Map FPGA manager regs via /dev/mem. Returns false if unavailable (host).
    bool open();
    void close();
    bool ok() const { return map_ != nullptr; }

    // --- Sharing the SPI bus with Main ----------------------------------------
    // The HPS<->FPGA "SPI" is not a bus with arbitration: it is a single 32-bit
    // GPO register in the FPGA manager (0xFF706010) plus a strobe/ACK handshake
    // on GPI. Main_MiSTer assumes it is the sole owner. Two facts make naive
    // sharing fatal:
    //
    //   1. Main's fpga_spi() spins on the ACK handshake with NO timeout — the
    //      only other way out is the FPGA leaving user mode (fpga_io.cpp). If we
    //      rewrite GPO while Main sits between "strobe=1" and "saw ACK", the core
    //      drops ACK, Main never sees it, and Main spins forever. That is a hard
    //      hang: no F12, no OSD, no /dev/MiSTer_cmd, and no way out but killing
    //      the process. This is what used to be blamed on "the Plex core crashing
    //      Main", and what healMainReloadPlex() existed to paper over.
    //   2. Main never re-reads GPO (`#define fpga_gpo_read() gpo_copy`), so any
    //      bits we leave behind are invisible to it.
    //
    // SIGSTOPing Main does not fix either problem — it freezes Main at an
    // arbitrary instruction, including inside the handshake, which is precisely
    // the dangerous case.
    //
    // What is actually safe: stop Main, WAIT until it has really stopped, then
    // read the hardware GPO and check Main's own transaction-enable bits
    // (FPGA_EN/OSD_EN/IO_EN) and the strobe. Main only ever calls fpga_spi()
    // between EnableXxx()/DisableXxx(), so all-clear proves it is between
    // transactions and, being stopped, cannot start one. We then run our
    // transaction, restore GPO byte-for-byte, and resume Main — which wakes up
    // with hardware exactly matching its shadow copy. If Main is mid-transaction
    // we resume it, back off, and retry; if it stays busy the SPI call fails
    // cleanly rather than corrupting anything. See SpiExclusive in fpga_spi.cpp.

    // --- Stranded-Main safety net ---------------------------------------------
    // The safe window above still SIGSTOPs Main for a few microseconds. If
    // misterplexd dies inside that window — crash, SIGKILL, OOM — nothing ever
    // sends SIGCONT and Main is left stopped forever.
    //
    // resumeStrandedMain(): SIGCONT any MiSTer left in state T while we hold no
    // window of our own. Safe to call from anywhere — it only reads /proc and
    // never touches SPI. Call at startup (repairs a previous death) and from a
    // slow watchdog (repairs a hang inside the critical section).
    static void resumeStrandedMain();

    // installCrashGuard(): resume Main from fatal-signal handlers, then re-raise
    // with the default disposition so the crash is still reported normally.
    // Covers everything except SIGKILL, which resumeStrandedMain() mops up on the
    // next start.
    static void installCrashGuard();

    // True while this process holds Main stopped for an SPI critical section.
    static bool mainPaused();

    // False when no MiSTer process exists at all.
    static bool mainAlive();

    // Push a complete raw buffer as an ioctl download (index = OSD F# entry).
    // For Plex core F1 frame store, index is typically 1.
    bool sendFileTx(const uint8_t* data, size_t len, uint8_t index = 1);

    // Convenience: RGB24 WxH → RGB565 LE then sendFileTx.
    bool sendRgb24Frame(const uint8_t* rgb, int w, int h, uint8_t index = 1);

    // Push packed RGB565 LE (host word order: lo,hi per pixel). len must be w*h*2.
    bool sendRgb565Frame(const uint16_t* rgb, int w, int h, uint8_t index = 1);
    bool sendRgb565Bytes(const uint8_t* rgb565le, size_t len, uint8_t index = 1);

    // Phase 3.1b: bulk RGB565 via DDR3 (/dev/mem @ 0x30000000).
    // Product path: mmap frame + doorbell @ 0x3007F000 (no SPI kick).
    // Fallback: status[12]/[13] SPI kick if doorbell fails first verify.
    // Waits for !ddr_busy and !swap_pending so next write bank is free after vsync.
    // Frame must be 320×240×2 = 153600 B. bank 0 → 0x30000000, bank 1 → 0x30040000.
    bool sendRgb565FrameDdr(const uint8_t* rgb565le, size_t len, int bank = 0);
    bool sendRgb24FrameDdr(const uint8_t* rgb, int w, int h, int bank = 0);
    // Physical base used by core ddram_frame_rd (must match RTL PHYS_BASE).
    static constexpr uint32_t kDdrFrameBase = 0x30000000u;
    static constexpr uint32_t kDdrFrameStride = 0x40000u; // 256 KiB
    static constexpr uint32_t kDdrDoorbellPhys = 0x3007F000u;
    static constexpr uint32_t kDdrDoorbellMagic = 0x504C584Bu; // "PLXK"
    static constexpr size_t kDdrFrameBytes = 320 * 240 * 2;

    // --- OSD status mailbox (core -> HPS, zero SPI) ----------------------------
    // ddram_frame_rd publishes the live OSD word here whenever it changes, plus a
    // slow heartbeat. Reading it costs one uncached 64-bit load and, unlike
    // UIO_GET_STATUS, never touches the GPO register Main_MiSTer owns — so it
    // cannot stall or hang Main no matter how often we poll.
    //   [31:0]  magic "PLXS"
    //   [47:32] status[15:0]
    //   [63:48] seq
    static constexpr uint32_t kDdrMailboxPhys = 0x3007F100u;
    static constexpr uint32_t kDdrMailboxMagic = 0x504C5853u; // "PLXS"

    // Read the OSD word from the mailbox. Returns false until the mailbox is
    // proven LIVE, which is the caller's cue to fall back to getCoreStatus().
    // Liveness matters: DDR keeps its contents across a core reload, so a
    // pre-mailbox RBF would otherwise leave us reading the previous core's stale
    // magic forever. The core bumps seq on every publish (change + heartbeat),
    // so we trust the word only while seq keeps advancing.
    bool readOsdMailbox(uint16_t& osd);

    // Push raw s16le stereo PCM chunk to audio_fifo (F2 / index 2). Appends.
    bool sendPcmChunk(const uint8_t* pcm, size_t len, uint8_t index = 2);

    // Push elementary bitstream (H.264 annex-B) to F3 bitstream_fifo. Appends.
    bool sendBitstreamChunk(const uint8_t* data, size_t len, uint8_t index = 3);

    // Pulse status bit 10 to flush present-domain audio FIFO.
    bool flushAudioFifo();

    // Pulse status bit 11 to flush bitstream FIFO / NAL scanner.
    bool flushBitstreamFifo();

    // UIO_SET_STATUS2: set/clear a single status bit (0–127). Best-effort —
    // does not fully sync with Main's cur_status shadow. Uses private status_[]
    // shadow (starts zero); prefer setStatusWord / setStatusBits for multi-bit.
    bool setStatusBit(int bit, int value);

    // Write full 128-bit status word via UIO_SET_STATUS2 and update private shadow.
    bool setStatusWord(const uint8_t word[16]);

    // Read UIO_GET_STATUS into private shadow, apply bit changes, write back.
    // bits: pairs (bit, value). Only OSD-safe if core status_in v2 preserves [15:0].
    bool setStatusBits(const int* bit_val_pairs, int n_pairs);

    // Core→HPS status via UIO_GET_STATUS (0x29). Fills 16 bytes (128 bits).
    // Layout: see CoreStatus helpers below / docs/phase3-decode.md.
    bool getCoreStatus(uint8_t out[16]);

    // UIO_GET_STRING — the core's CONF_STR exactly as Main_MiSTer sees it.
    bool getConfigString(std::string& out);

    struct CoreStatus {
        bool has_frame = false;
        bool has_audio = false;
        bool has_stream = false;
        bool audio_underrun = false;
        bool has_idr = false;
        bool stub_busy = false;
        bool sps_valid = false;
        bool pps_valid = false;
        uint8_t last_nal_type = 0;
        uint16_t nalu_count = 0;
        uint16_t stream_fifo_level = 0;
        uint8_t idr_count = 0;
        uint8_t slice_type = 0;
        uint8_t first_mb_type = 0;
        uint8_t slice_qp = 0;
        uint8_t residual_tc = 0;
        uint8_t residual_t1 = 0;
        bool residual_ok = false;
        int8_t residual_dc = 0; // 3.3k: scan-order coeff[0] after levels+runs
        // 3.3l-1: residualCsum8 = XOR satS8(coeff[i]); raw[13]/status[111:104].
        // Golden Baseline first residual = 0x14 (20). Pre-3.3l-1 RBF: stream_bytes[7:0].
        uint8_t residual_csum = 0;
        bool ddr_busy = false;      // status_in[79] (v2) — DDR→BRAM copy in flight
        bool swap_pending = false;  // status_in[78] — display bank flip waiting for vsync
        uint8_t stub_frames = 0; // legacy alias
        uint16_t sps_width = 0;
        uint16_t sps_height = 0;
        // Legacy alias: high/low of previous wr_count field (now idr|stub)
        uint16_t wr_count_lo = 0;
        uint32_t stream_bytes_seen = 0; // not in status anymore; kept for API compat (=0)
        uint32_t stream_bytes_in = 0;
    };
    // Parse getCoreStatus raw bytes into fields.
    static CoreStatus parseCoreStatus(const uint8_t raw[16]);
    bool readCoreStatus(CoreStatus& out);

    // Thread-safe copy of last error (F1/F2/F3 share this object).
    std::string lastError() const;
    // Last successful frame push duration (ms)
    double lastPushMs() const { return lastPushMs_; }

private:
    void setErr(std::string msg);
    void clearErr();
    void gpoWrite(uint32_t v);
    uint32_t gpoRead() const;
    int gpiRead() const;
    void spiEn(uint32_t mask, int en);
    uint16_t spiWord(uint16_t word);
    void spiByte(uint8_t b);
    void spiWriteBytes(const uint8_t* p, size_t n);
    void enableFpga(int on);
    void enableIo(int on);
    void setIndex(uint8_t index);
    void setDownload(int enable);
    // Caller holds SpiExclusive + user mode.
    void writeStatusWordRaw(const uint8_t word[16]);
    bool readStatusRaw(uint8_t out[16]);

    int fd_ = -1;
    volatile uint32_t* map_ = nullptr;
    uint32_t gpo_copy_ = 0;
    uint8_t status_[16]{};
    double lastPushMs_ = 0;
    std::string err_;
    // Persistent HPS DDR frame window (both banks + doorbell page).
    int ddrMemFd_ = -1;
    uint8_t* ddrMap_ = nullptr;
    size_t ddrMapLen_ = 0;
    uint32_t doorbellSeq_ = 0;
    bool mboxInit_ = false;
    bool mboxAlive_ = false;
    uint16_t mboxSeq_ = 0;
    double mboxSeqMs_ = 0.0;
    int ddrKickMode_ = 0; // 0=unknown, 1=doorbell, 2=SPI kick, -1=fail
    bool ensureDdrMap();
    void releaseDdrMap();
    bool waitCoreFlag(bool wantBusy, bool wantPending, int maxUs);
    bool kickDdrSpi(int bank, bool first_verify, bool& saw_busy, bool& saw_kick, bool& saw_frame);
    bool kickDdrDoorbell(int bank);
    static constexpr uint32_t kMgrBase = 0xFF706000;
    static constexpr uint32_t kMapBase = 0xFF000000;
    static constexpr size_t kMapSize = 0x01000000;
    static constexpr uint32_t SSPI_FPGA_EN = (1u << 18);
    static constexpr uint32_t SSPI_IO_EN = (1u << 20);
    static constexpr uint32_t SSPI_STROBE = (1u << 17);
};

} // namespace misterplex
