#pragma once
// Minimal MiSTer HPS→FPGA SPI bridge for ioctl file_tx (frame store ingest).
// Mirrors Main_MiSTer FIO_FILE_* protocol. Shares GPO/GPI with Main — short
// transfers only; optional flock reduces races.

#include <cstdint>
#include <string>
#include <vector>

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_bitstream_ring.hpp"
#include "libmisterplex/ddr_present_bank.hpp"
#include "libmisterplex/input_mailbox.hpp"

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
    // F1 frame presentation is not accepted here: the product frame-store
    // contract is DDR YUV420p only.
    bool sendFileTx(const uint8_t* data, size_t len, uint8_t index = 1);

    // Convenience for non-F1 legacy/debug slots: RGB24 WxH → RGB565 LE then sendFileTx.
    bool sendRgb24Frame(const uint8_t* rgb, int w, int h, uint8_t index = 1);

    // Push packed RGB565 LE to non-F1 legacy/debug slots. len must be w*h*2.
    bool sendRgb565Frame(const uint16_t* rgb, int w, int h, uint8_t index = 1);
    bool sendRgb565Bytes(const uint8_t* rgb565le, size_t len, uint8_t index = 1);

    // C3 DDR frame-store path: planar I420/YUV420p via HPS DDR
    // (/dev/mem @ 0x30000000) plus format-tagged doorbell. RGB565 is not a
    // valid F1 frame-store payload for this RTL.
    bool setDdrFrameLayout(const DdrFrameGeometry& geometry,
                           DdrFrameFormat format = DdrFrameFormat::Yuv420p);
    bool setDdrFrameLayout(int width, int height,
                           DdrFrameFormat format = DdrFrameFormat::Yuv420p);
    DdrFrameLayout ddrFrameLayout() const { return ddrLayout_; }
    bool sendYuv420pFrameDdr(const uint8_t* yuv420p, size_t len,
                             const DdrFrameGeometry& geometry, int bank = 0);
    bool sendYuv420pFrameDdr(const uint8_t* yuv420p, size_t len, int width, int height,
                             int bank = 0);
    // bank is a hint; PLXD may select the free bank. lastPublishedBank() is the
    // bank that was actually written + doorbelled on the last successful publish.
    bool publishDdrFrame(const DdrPublishFrame& frame, int bank = 0);
    int lastPublishedBank() const { return lastPublishedBank_; }
    // DDR frame mmap policy. Default true keeps the proven strongly-ordered/device
    // mapping; false is a lab knob for write-combine/cacheable /dev/mem tests.
    // If a lab proves the no-sync mapping is cacheable, enable flush so the FPGA
    // sees all stores before the DDR doorbell is signalled.
    void setDdrMemSync(bool on);
    void setDdrMemFlush(bool on) { ddrMemFlush_ = on; }
    struct DdrTiming {
        int64_t prep_wait_us = 0;
        int64_t copy_us = 0;
        int64_t flush_us = 0;
        int64_t doorbell_us = 0;
        int64_t post_wait_us = 0;
        int64_t total_us = 0;
        int64_t bank_reuse_wait_us = 0;
        int64_t plxa_poll_us = 0;     // PLXA bank-release poll time (0 = fallback)
        int plxa_poll_iters = 0;      // number of PLXA poll iterations
        bool plxa_used = false;       // true if PLXA drove bank selection
    };
    DdrTiming lastDdrTiming() const { return lastDdrTiming_; }
    struct DdrDoorbellStatus {
        uint32_t seq = 0;
        int bank = 0;
        DdrFrameFormat format = DdrFrameFormat::Yuv420p;
    };
    bool readDdrDoorbellStatus(DdrDoorbellStatus& status);
    bool readFrameStoreStatus(FrameStoreStatus& status);
    bool readBankRelease(BankReleaseStatus& status);

    // PLXD provenance diagnostic — classifies whether the FPGA actually wrote
    // the bank-release mailbox, without requiring valid magic.
    enum class PlxdProvenance {
        Absent,      // magic does not match — cold DDR, pre-PLXD RBF, or corruption
        Residue,     // magic matches but reserved bits non-zero (coincidence/corruption)
        InitOnly,    // magic valid, clean fields, but frames_done==0 — FPGA initialized, never swapped
        Alive,       // magic valid, frames_done>0 — FPGA has completed at least one bank swap
        LiveAdvance, // frames_done advanced between two reads — FPGA is actively running
    };
    struct PlxdDiag {
        PlxdProvenance provenance = PlxdProvenance::Absent;
        uint32_t raw_lo = 0;        // raw [31:0]
        uint32_t raw_hi = 0;        // raw [63:32]
        uint16_t frames_done = 0;
        uint8_t free_bank_mask = 0;
        uint8_t disp_bank = 0;
        bool swap_pending = false;
        uint16_t reserved_bits = 0; // [47:36] should be zero if written by RTL
    };
    PlxdDiag diagnosePlxdProvenance();

    // Physical base used by core ddram_frame_rd (must match RTL PHYS_BASE).
    static constexpr uint32_t kDdrFrameBase = 0x30000000u;
    static constexpr uint32_t kDdrDoorbellPhys = mailbox_abi::kPlxkAddr;
    static constexpr uint32_t kDdrDoorbellMagic = mailbox_abi::kPlxkMagic;

    // --- OSD status mailbox (core -> HPS, zero SPI) ----------------------------
    // ddram_frame_rd publishes the live OSD word here whenever it changes, plus a
    // slow heartbeat. Reading it costs one uncached 64-bit load and, unlike
    // UIO_GET_STATUS, never touches the GPO register Main_MiSTer owns — so it
    // cannot stall or hang Main no matter how often we poll.
    //   [31:0]  magic "PLXS"
    //   [47:32] status[15:0]
    //   [63:48] seq
    static constexpr uint32_t kDdrMailboxPhys = kDdrStatusMailboxPhys;
    static constexpr uint32_t kDdrMailboxMagic = kDdrStatusMailboxMagic; // "PLXS"

    // Read the OSD word from the mailbox. Returns false until the mailbox is
    // proven LIVE, which is the caller's cue to fall back to getCoreStatus().
    // Liveness matters: DDR keeps its contents across a core reload, so a
    // pre-mailbox RBF would otherwise leave us reading the previous core's stale
    // magic forever. The core bumps seq on every publish (change + heartbeat),
    // so we trust the word only while seq keeps advancing.
    bool readOsdMailbox(uint16_t& osd);

    // Read one edge-detected playback command from the input mailbox. This is
    // DDR-only and never falls back to the HPS<->FPGA SPI bus.
    bool readInputMailbox(PlaybackCommand& command);

    // Push raw s16le stereo PCM chunk to audio_fifo (F2 / index 2). Appends.
    bool sendPcmChunk(const uint8_t* pcm, size_t len, uint8_t index = 2);

    // Push elementary bitstream (H.264 annex-B) to F3 bitstream_fifo. Appends.
    bool sendBitstreamChunk(const uint8_t* data, size_t len, uint8_t index = 3);
    // Product path: copy complete Annex-B NAL records into the HPS DDR ring.
    // pushBitstreamNal() copies before returning, so the caller may immediately
    // reuse/free Nal::annexb. Full is transient; Desync/Fatal require a session
    // reset. begin while active is rejected by contract: end the old session first.
    using BitstreamNal = ddr_bitstream_ring::Nal;
    using BitstreamStatus = ddr_bitstream_ring::Status;
    using BitstreamPushResult = ddr_bitstream_ring::PushResult;
    bool beginBitstreamSession(uint64_t session_id, int timeout_ms = 250);
    BitstreamPushResult pushBitstreamNal(const BitstreamNal& nal, int timeout_ms = 250);
    bool flushBitstreamSession(uint64_t session_id, int timeout_ms = 250);
    bool endBitstreamSession(uint64_t session_id, int timeout_ms = 250);
    bool pauseBitstreamSession(uint64_t session_id, int timeout_ms = 250);
    bool resumeBitstreamSession(uint64_t session_id, int timeout_ms = 250);
    bool readBitstreamStatus(BitstreamStatus& status);
    // Write PLXD (dormant) magic to CTRL so a DDR probe can distinguish
    // "producer disabled by config" from "never written / boot residue".
    // Safe to call even when STREAM=0 — it maps the control page, writes one
    // 64-bit word, and unmaps. The FPGA reader ignores PLXD (not PLXB), so
    // this has no side-effects on the decode path.
    bool publishBitstreamDormant();
    // Legacy byte-chunk entry point: wraps each chunk in a default-session NAL
    // record so older call sites keep working while source-demux moves to the
    // explicit record API above.
    bool sendBitstreamChunkDdr(const uint8_t* data, size_t len);
    bool flushBitstreamDdr();

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
        // 3.3l-2: reconstructed-pixel signature for MB0 block0 after inv_quant+IDCT.
        // raw[14]/status[119:112] = XOR of 16 reconstructed Y samples; golden 0x3B.
        uint8_t recon_sig = 0;
        // raw[15]/status[127:120] = P3-3l2 silicon RCA flags. Bits [2:1] may be
        // altered by the Aspect Ratio OSD splice; use the other bits only.
        uint8_t recon_dbg = 0;
        bool ddr_busy = false;      // status_in[79] (v2) — DDR→BRAM copy in flight
        bool swap_pending = false;  // status_in[78] — display bank flip waiting for vsync
        uint8_t stub_frames = 0; // legacy alias
        uint16_t sps_width = 0;
        uint16_t sps_height = 0;
        // Legacy alias: high/low of previous wr_count field (now idr|stub)
        uint16_t wr_count_lo = 0;
        uint32_t stream_bytes_seen = 0; // not in status anymore; kept for API compat (=0)
        uint32_t stream_nalus = 0; // status liveness mirror of nalu_count, not bytes
        uint32_t stream_bytes_in = 0; // deprecated alias of stream_nalus for API compat
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
    bool sendDdrFrame(const DdrPublishFrame& frame, const DdrPublishPlan& plan);

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
    bool ddrMemSync_ = true;
    bool ddrMemFlush_ = false;
    DdrTiming lastDdrTiming_{};
    // Default to the product silicon canvas (624 coded). DECODE=320x240 must not
    // leave the doorbell/stride at the packed-320 layout or the first frame shears.
    DdrFrameLayout ddrLayout_ = makeDdrFrameLayout(productDdrFrameStoreGeometry());
    uint32_t doorbellSeq_ = 0;
    double lastDdrBankDoorbellMs_[2] = {-1.0, -1.0};
    int lastPublishedBank_ = 0;
    bool mboxInit_ = false;
    bool mboxAlive_ = false;
    uint16_t mboxSeq_ = 0;
    double mboxSeqMs_ = 0.0;
    InputMailboxEdgeDetector inputMboxEdge_;
    int ddrKickMode_ = 0; // 0=unknown, 1=doorbell, 2=SPI kick, -1=fail
    double ddrKickFailMs_ = -1.0; // steady_clock timestamp of last ddrKickMode_ = -1
    // PLXD liveness: detect stale/residue mailbox by checking frames_done advances.
    uint16_t plxdLastFramesDone_ = 0;
    int plxdStaleCount_ = 0;       // consecutive reads with no frames_done advance
    bool plxdLivenessProven_ = false; // true once frames_done has advanced at least once
    bool ensureDdrMap();
    void releaseDdrMap();
    bool ensureBitstreamDdrMap();
    void releaseBitstreamDdrMap();
    bool readBitstreamFpgaCount(uint32_t& readCount);
    bool waitBitstreamReadCount(uint32_t target, int timeout_ms);
    BitstreamPushResult writeBitstreamRecord(ddr_bitstream_ring::Event event,
                                             uint64_t session_id,
                                             uint32_t seq,
                                             uint8_t nal_type,
                                             const uint8_t* payload,
                                             size_t len,
                                             int timeout_ms);
    void publishBitstreamCtrl();
    bool waitCoreFlag(bool wantBusy, bool wantPending, int maxUs);
    bool kickDdrSpi(int bank, bool first_verify, bool& saw_busy, bool& saw_kick, bool& saw_frame);
    bool kickDdrDoorbell(int bank);
    uint32_t ddrStatusMailboxPhys() const {
        return ddrLayout_.doorbell_phys + (kDdrMailboxPhys - kDdrDoorbellPhys);
    }
    uint32_t ddrInputMailboxPhys() const {
        return ddrLayout_.doorbell_phys + (kInputMailboxPhys - kDdrDoorbellPhys);
    }
    static constexpr uint32_t kMgrBase = 0xFF706000;
    static constexpr uint32_t kMapBase = 0xFF000000;
    static constexpr size_t kMapSize = 0x01000000;
    static constexpr uint32_t SSPI_FPGA_EN = (1u << 18);
    static constexpr uint32_t SSPI_IO_EN = (1u << 20);
    static constexpr uint32_t SSPI_STROBE = (1u << 17);

    int bitstreamMemFd_ = -1;
    uint8_t* bitstreamMap_ = nullptr;
    size_t bitstreamMapLen_ = 0;
    uint32_t bitstreamWriteCount_ = 0;
    uint64_t bitstreamLegacySessionId_ = 1;
    uint32_t bitstreamLegacySeq_ = 0;
    bool bitstreamLegacyActive_ = false;
    bool bitstreamResetEpoch_ = false;
};

} // namespace misterplex
