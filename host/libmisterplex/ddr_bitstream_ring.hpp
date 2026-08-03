#pragma once

#include <cstddef>
#include <cstdint>
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

// ---- Product SPS geometry for fabric-decoder / ring consumers (parent measured) ----
// Bitstream is MB-coded 960×544 with SPS bottom crop 4 → display 540.
// libavcodec applies crop before AVFrame, so the ARM *frame-bank* path sees 540.
// Any consumer of *coded* NALs from this ring (fabric decoder, future recon)
// must size DPB/recon for 544 and apply the 4-line bottom crop itself.
// Do not re-derive from ffprobe coded_height (post-crop).
constexpr int kProductSpsCodedW = 960;
constexpr int kProductSpsCodedH = 544;
constexpr int kProductSpsDisplayH = 540;
constexpr int kProductSpsCropBottomLines = 4;
constexpr int kProductSpsCodedI420Bytes = 960 * 544 * 3 / 2; // 783360
constexpr int kProductSpsDisplayI420Bytes = 960 * 540 * 3 / 2; // 777600
static_assert(kProductSpsCodedH - kProductSpsCropBottomLines == kProductSpsDisplayH,
              "SPS crop 544-4=540");
static_assert(kProductSpsCodedI420Bytes == 783360, "coded I420");
static_assert(kProductSpsDisplayI420Bytes == 777600, "display I420");

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

} // namespace misterplex::ddr_bitstream_ring
