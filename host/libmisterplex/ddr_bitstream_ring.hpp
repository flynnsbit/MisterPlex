#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>
#include "mailbox_abi_spec.hpp"

namespace misterplex::ddr_bitstream_ring {

constexpr uint32_t kDataPhys = 0x30100000u;
constexpr uint32_t kCtrlPhys = mailbox_abi::kPlxbAddr;
constexpr uint32_t kReadPhys = 0x30140008u;
constexpr uint32_t kErrPhys = 0x30140010u;
constexpr uint32_t kStat0Phys = 0x30140018u;
constexpr uint32_t kStat1Phys = 0x30140020u;
constexpr uint32_t kStat2Phys = 0x30140028u;
constexpr uint32_t kStat3Phys = 0x30140030u;
constexpr uint32_t kStat4Phys = 0x30140038u;
constexpr uint32_t kStat5Phys = 0x30140040u;
constexpr uint32_t kStat6Phys = 0x30140048u;
constexpr size_t kRingBytes = 262144u;

constexpr uint32_t kCtrlMagic = mailbox_abi::kPlxbMagic;
constexpr uint32_t kCtrlDormantMagic = mailbox_abi::kPlxbDormantMagic;
constexpr uint32_t kReadMagic = 0x504C5852u; // PLXR, FPGA -> HPS
constexpr uint32_t kErrMagic = 0x504C5845u;  // PLXE, FPGA -> HPS
constexpr uint32_t kRecordMagic = 0x504C584Eu; // PLXN, record header
constexpr uint32_t kStat0Magic = 0x504C5854u; // PLXT, ring level
constexpr uint32_t kStat1Magic = 0x504C5855u; // PLXU, consumer seq
constexpr uint32_t kStat2Magic = 0x504C5856u; // PLXV, last bad seq
constexpr uint32_t kStat3Magic = 0x504C5857u; // PLXW, session low
constexpr uint32_t kStat4Magic = 0x504C5859u; // PLXY, session high
constexpr uint32_t kStat5Magic = 0x504C585Au; // PLXZ, underrun/overrun counts
constexpr uint32_t kStat6Magic = 0x504C5851u; // PLXQ, desync/state flags

constexpr size_t kRecordHeaderBytes = 32u;

constexpr int kErrTelemetrySeqShift = 32;
constexpr int kErrUnderrunStickyBit = 45;
constexpr int kErrOverrunStickyBit = 46;
constexpr int kErrActiveBit = 47;
constexpr int kErrUnderrunCountShift = 48;
constexpr int kErrOverrunCountShift = 56;

constexpr int kStat6StateFlagsShift = 32;
constexpr int kStat6UnderrunFlagBit = 6;
constexpr int kStat6OverrunFlagBit = 7;
constexpr int kStat6ActiveFlagBit = 8;
constexpr int kStat6PausedFlagBit = 9;
constexpr int kStat6DesyncFlagBit = 10;
constexpr int kStat6FatalFlagBit = 11;
constexpr int kStat6DesyncCountShift = 48;

enum class Event : uint8_t {
    Begin = 1,
    Nal = 2,
    Flush = 3,
    End = 4,
    Pause = 5,
    Resume = 6,
};

enum class PushResult {
    Ok,
    Full,
    Desync,
    Fatal,
};

struct Nal {
    uint64_t session_id = 0;
    uint32_t seq = 0;
    uint8_t nal_type = 0;
    const uint8_t* annexb = nullptr;
    size_t len = 0;
};

struct Status {
    uint32_t ring_level = 0;
    uint32_t ring_capacity = static_cast<uint32_t>(kRingBytes);
    uint32_t producer_count = 0;
    uint32_t consumer_count = 0;
    uint32_t consumer_seq = 0;
    uint16_t underrun_count = 0;
    uint16_t overrun_count = 0;
    uint16_t desync_count = 0;
    uint32_t last_bad_seq = 0;
    uint64_t session_id = 0;
    bool active = false;
    bool paused = false;
    bool underrun = false;
    bool overrun = false;
    bool desync = false;
    bool fatal = false;
    bool dormant = false;  // PLXD: producer disabled by config (STREAM=0)
};

inline bool decodeErrStatusWord(uint64_t word, Status& status) {
    if (static_cast<uint32_t>(word) != kErrMagic)
        return false;
    status.underrun = ((word >> kErrUnderrunStickyBit) & 1u) != 0;
    status.overrun = ((word >> kErrOverrunStickyBit) & 1u) != 0;
    status.active = ((word >> kErrActiveBit) & 1u) != 0;
    status.underrun_count = static_cast<uint8_t>(word >> kErrUnderrunCountShift);
    status.overrun_count = static_cast<uint8_t>(word >> kErrOverrunCountShift);
    return true;
}

inline bool decodeStat5StatusWord(uint64_t word, Status& status) {
    if (static_cast<uint32_t>(word) != kStat5Magic)
        return false;
    const uint32_t counts = static_cast<uint32_t>(word >> 32);
    status.overrun_count = static_cast<uint16_t>(counts);
    status.underrun_count = static_cast<uint16_t>(counts >> 16);
    return true;
}

inline bool decodeStat6StatusWord(uint64_t word, Status& status) {
    if (static_cast<uint32_t>(word) != kStat6Magic)
        return false;
    const uint32_t ds = static_cast<uint32_t>(word >> 32);
    status.desync_count = static_cast<uint16_t>(ds >> 16);
    const uint16_t flags = static_cast<uint16_t>(ds);
    status.underrun = status.underrun || ((flags >> kStat6UnderrunFlagBit) & 1u);
    status.overrun = status.overrun || ((flags >> kStat6OverrunFlagBit) & 1u);
    status.active = status.active || ((flags >> kStat6ActiveFlagBit) & 1u);
    status.paused = ((flags >> kStat6PausedFlagBit) & 1u) != 0;
    status.desync = ((flags >> kStat6DesyncFlagBit) & 1u) != 0;
    status.fatal = ((flags >> kStat6FatalFlagBit) & 1u) != 0;
    return true;
}

// CTRL @ kCtrlPhys:
//   [31:0]  PLXB
//   [62:32] absolute producer byte count modulo 2^31
//   [63]    reset/flush epoch toggle
// READ @ kReadPhys:
//   [31:0]  PLXR
//   [63:32] absolute FPGA consumer byte count
// ERR @ kErrPhys:
//   [31:0]  PLXE
//   [39:32] telemetry publish seq
//   [45]    underrun sticky
//   [46]    overrun sticky
//   [47]    active
//   [55:48] saturated underrun count low byte
//   [63:56] saturated overrun count low byte
// RECORD header, little-endian, exactly kRecordHeaderBytes:
//   [0..3]   PLXN
//   [4]      Event
//   [5]      nal_type (Event::Nal only)
//   [6..7]   reserved
//   [8..15]  session_id
//   [16..19] seq (Event::Nal continuity is checked FPGA-side)
//   [20..23] payload length in bytes
//   [24..31] reserved, must be zero
// STAT0..6 expose ring level/capacity-derived status, consumer seq,
// underrun/overrun/desync counters, last_bad_seq, active/paused/fatal flags,
// and the FPGA-visible session_id for low-cost host polling.


// ---------------------------------------------------------------------------
// Fabric-decode ingest map (w-mem). Default product ring kept; this documents
// the reserved-window placement so Option-C / PL330 collisions are compile-time
// impossible to miss. Mirror constants live in ddr_frame_layout_params.svh.
// ---------------------------------------------------------------------------

// Reserved DDR window (parent-verified memmap=513M$511M).
constexpr uint32_t kReservedWindowStart = 0x1FF00000u;
constexpr uint32_t kReservedWindowEnd = 0x40000000u;

// Legacy/product compressed bitstream ring (already shipping path).
constexpr uint32_t kRingDataEndPhys = kDataPhys + static_cast<uint32_t>(kRingBytes); // 0x30140000
static_assert(kRingDataEndPhys == kCtrlPhys, "PLXB ctrl sits at ring data end");
static_assert(kRingBytes == 262144u && (kRingBytes & (kRingBytes - 1u)) == 0,
              "ring must be power-of-two");

// Option-C frame banks (ddr_frame_layout.hpp) — must not overlap ring.
constexpr uint32_t kOptionCBasePhys = 0x30180000u;
constexpr uint32_t kOptionCStride = 0x00180000u;
constexpr uint32_t kOptionCDoorbellPhys = 0x3047F000u;
constexpr uint32_t kOptionCMapEnd2Bank = kOptionCBasePhys + 2u * kOptionCStride; // 0x30480000
// PL330 ABI after triple Option-C (w-path).
constexpr uint32_t kPl330ScratchPhys = 0x30600000u;

// Full published map (low → high). Gaps intentional.
//   [0x30100000, 0x30140000)  ring data 256 KiB
//   [0x30140000, 0x30140050)  PLXB/PLXR/PLXE + STAT0..6 (mailbox page)
//   [0x30140050, 0x30180000)  reserved gap (do not place producers)
//   [0x30180000, 0x30480000)  Option-C I420 banks (2 x 0x180000)
//   [0x3047F000, 0x30480000)  YUV doorbell page (inside map end)
//   [0x30480000, 0x30600000)  headroom / triple-buffer room
//   [0x30600000, ...)         PL330 scratch+staging

inline bool rangesOverlap(uint32_t a0, uint32_t a1, uint32_t b0, uint32_t b1) {
    return a0 < b1 && b0 < a1;
}

inline bool bitstreamRingClearsOptionC() {
    return kRingDataEndPhys <= kOptionCBasePhys && kCtrlPhys < kOptionCBasePhys;
}

inline bool bitstreamRingClearsPl330() {
    return kRingDataEndPhys <= kPl330ScratchPhys && kOptionCDoorbellPhys + 0x1000u <= kPl330ScratchPhys;
}

inline bool bitstreamRingInsideReserved() {
    return kDataPhys >= kReservedWindowStart && kRingDataEndPhys <= kReservedWindowEnd &&
           kCtrlPhys >= kReservedWindowStart && (kCtrlPhys + 0x50u) <= kReservedWindowEnd;
}

// Bitrate arithmetic @ product tier (~2585 kbit content, 24 fps).
constexpr double kFabricIngestBitrateKbit = 2585.0;
constexpr double kFabricIngestFps = 24.0;
// Bytes/frame compressed ≈ bitrate/8/fps
inline double bitstreamBytesPerFrame(double kbit, double fps) {
    return (kbit * 1000.0 / 8.0) / fps;
}
inline double bitstreamCpuPushMsAtBankRate(double kbit = kFabricIngestBitrateKbit,
                                          double fps = kFabricIngestFps,
                                          double mibps = 88.045) {
    const double bytes = bitstreamBytesPerFrame(kbit, fps);
    const double mib = bytes / (1024.0 * 1024.0);
    return (mib / mibps) * 1000.0;
}
// ~0.15 ms/f at 2585k/24 @ 88 MiB/s — uncached ceiling stops mattering.

// PLXN record header pack/unpack (host-visible framing). Little-endian on wire.
// Why uncached ordering helps: ARM store buffer drains to device memory in
// program order for strongly-ordered/device mappings; publish producer count
// ONLY after the full record (header+payload) stores are issued. FPGA never
// reads past published count → no partial-record parse. No dcache clean needed
// on product O_SYNC path (structural uncached).

inline void packPlxnHeader(uint8_t out[32], Event ev, uint8_t nal_type, uint64_t session,
                           uint32_t seq, uint32_t payload_len) {
    std::memset(out, 0, 32);
    out[0] = static_cast<uint8_t>(kRecordMagic);
    out[1] = static_cast<uint8_t>(kRecordMagic >> 8);
    out[2] = static_cast<uint8_t>(kRecordMagic >> 16);
    out[3] = static_cast<uint8_t>(kRecordMagic >> 24);
    out[4] = static_cast<uint8_t>(ev);
    out[5] = nal_type;
    for (int i = 0; i < 8; ++i)
        out[8 + i] = static_cast<uint8_t>(session >> (8 * i));
    for (int i = 0; i < 4; ++i)
        out[16 + i] = static_cast<uint8_t>(seq >> (8 * i));
    for (int i = 0; i < 4; ++i)
        out[20 + i] = static_cast<uint8_t>(payload_len >> (8 * i));
}

inline bool unpackPlxnHeader(const uint8_t in[32], Event& ev, uint8_t& nal_type,
                             uint64_t& session, uint32_t& seq, uint32_t& payload_len) {
    const uint32_t mag = static_cast<uint32_t>(in[0]) | (static_cast<uint32_t>(in[1]) << 8) |
                         (static_cast<uint32_t>(in[2]) << 16) | (static_cast<uint32_t>(in[3]) << 24);
    if (mag != kRecordMagic)
        return false;
    ev = static_cast<Event>(in[4]);
    nal_type = in[5];
    session = 0;
    for (int i = 0; i < 8; ++i)
        session |= static_cast<uint64_t>(in[8 + i]) << (8 * i);
    seq = 0;
    payload_len = 0;
    for (int i = 0; i < 4; ++i) {
        seq |= static_cast<uint32_t>(in[16 + i]) << (8 * i);
        payload_len |= static_cast<uint32_t>(in[20 + i]) << (8 * i);
    }
    return true;
}

// Software ring model — unit-testable wrap + seq (no /dev/mem).
// Producer: append header+payload, then advance write_count by record bytes.
// Consumer: may only read [read_count, write_count). Seq must be monotonic +1
// for Event::Nal after Begin. Wrong wrap or skipped seq → Desync/Fatal.

class BitstreamRingModel {
public:
    explicit BitstreamRingModel(size_t cap = kRingBytes) : cap_(cap), mem_(cap, 0) {}

    size_t capacity() const { return cap_; }
    uint32_t writeCount() const { return write_count_; }
    uint32_t readCount() const { return read_count_; }
    size_t level() const {
        return static_cast<size_t>(write_count_ - read_count_);
    }
    bool underrunSticky() const { return underrun_sticky_; }
    bool overrunSticky() const { return overrun_sticky_; }
    bool desyncSticky() const { return desync_sticky_; }
    uint32_t lastBadSeq() const { return last_bad_seq_; }
    uint32_t expectSeq() const { return expect_seq_; }

    PushResult pushRecord(Event ev, uint8_t nal_type, uint64_t session, uint32_t seq,
                          const uint8_t* payload, uint32_t payload_len) {
        if (fatal_)
            return PushResult::Fatal;
        const size_t rec = kRecordHeaderBytes + static_cast<size_t>(payload_len);
        if (level() + rec > cap_) {
            overrun_sticky_ = true;
            return PushResult::Full;
        }
        uint8_t hdr[32];
        packPlxnHeader(hdr, ev, nal_type, session, seq, payload_len);
        writeBytesAt(write_count_, hdr, 32);
        if (payload_len && payload)
            writeBytesAt(write_count_ + 32u, payload, payload_len);
        write_count_ += static_cast<uint32_t>(rec);
        return PushResult::Ok;
    }

    // Consumer pulls one record. Returns false on underrun (honest starve).
    bool pullRecord(Event& ev, uint8_t& nal_type, uint64_t& session, uint32_t& seq,
                    std::vector<uint8_t>& payload) {
        payload.clear();
        if (level() < kRecordHeaderBytes) {
            underrun_sticky_ = true;
            return false;
        }
        uint8_t hdr[32];
        peekBytes(0, hdr, 32);
        if (!unpackPlxnHeader(hdr, ev, nal_type, session, seq, payload_len_tmp_)) {
            desync_sticky_ = true;
            fatal_ = true;
            return false;
        }
        const size_t need = kRecordHeaderBytes + static_cast<size_t>(payload_len_tmp_);
        if (level() < need) {
            // Partial publish — leave read_count; sticky underrun (no silent splice).
            underrun_sticky_ = true;
            return false;
        }
        payload.resize(payload_len_tmp_);
        if (payload_len_tmp_)
            peekBytes(kRecordHeaderBytes, payload.data(), payload_len_tmp_);
        read_count_ += static_cast<uint32_t>(need);

        if (ev == Event::Begin) {
            expect_seq_ = 0;
            session_ = session;
        } else if (ev == Event::Nal) {
            if (seq != expect_seq_) {
                last_bad_seq_ = seq;
                desync_sticky_ = true;
                return false; // honest fail — do not silently splice
            }
            ++expect_seq_;
        }
        return true;
    }

    // NEG helper: force write_count ahead without payload (partial publish).
    void corruptAdvanceWrite(uint32_t bytes) { write_count_ += bytes; }

    // NEG helper: poke ring bytes at absolute producer offset (wrap bug inject).
    void pokeAtWriteOffset(uint32_t abs_off, const uint8_t* p, size_t n) {
        for (size_t i = 0; i < n; ++i)
            mem_[(abs_off + static_cast<uint32_t>(i)) & (cap_ - 1)] = p[i];
    }

private:
    void writeBytesAt(uint32_t abs_off, const uint8_t* p, size_t n) {
        for (size_t i = 0; i < n; ++i)
            mem_[(abs_off + static_cast<uint32_t>(i)) & (cap_ - 1)] = p[i];
    }
    void peekBytes(size_t off, uint8_t* p, size_t n) const {
        for (size_t i = 0; i < n; ++i)
            p[i] = mem_[(read_count_ + static_cast<uint32_t>(off + i)) & (cap_ - 1)];
    }

    size_t cap_;
    std::vector<uint8_t> mem_;
    uint32_t write_count_ = 0;
    uint32_t read_count_ = 0;
    uint32_t expect_seq_ = 0;
    uint32_t last_bad_seq_ = 0;
    uint32_t payload_len_tmp_ = 0;
    uint64_t session_ = 0;
    bool underrun_sticky_ = false;
    bool overrun_sticky_ = false;
    bool desync_sticky_ = false;
    bool fatal_ = false;
};


} // namespace misterplex::ddr_bitstream_ring
