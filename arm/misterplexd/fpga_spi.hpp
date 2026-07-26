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

    // After HPS SPI present traffic, Main often ignores F12 / MiSTer_cmd until the
    // MiSTer process is restarted (SPI bus left inconsistent; Main stays state=R).
    // Restart Main and reload Plex.rbf so OSD works again. Call after play stop.
    // Glitches video briefly; required until DDR kick is memory-mapped (no SPI).
    static bool healMainReloadPlex(const char* plexRbf = "/media/fat/_Utility/Plex.rbf");

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
