#pragma once

#include "ddr_bitstream_ring.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <stdexcept>
#include <unordered_map>
#include <vector>

namespace misterplex::test {

namespace ring = misterplex::ddr_bitstream_ring;
using RingBytes = std::vector<uint8_t>;

inline RingBytes encodeRingRecord(ring::Event event, uint64_t session, uint32_t seq = 0,
                                 const RingBytes& payload = {},
                                 uint16_t version = mailbox_abi::kFpgaVideoAbiVersion,
                                 uint8_t nalType = 0) {
    RingBytes bytes(ring::kRecordHeaderBytes + payload.size(), 0);
    ring::putLe32(bytes.data(), ring::kRecordMagic);
    bytes[4] = static_cast<uint8_t>(event);
    bytes[5] = nalType;
    bytes[6] = static_cast<uint8_t>(version);
    bytes[7] = static_cast<uint8_t>(version >> 8);
    ring::putLe64(bytes.data() + 8, session);
    ring::putLe32(bytes.data() + 16, seq);
    ring::putLe32(bytes.data() + 20, static_cast<uint32_t>(payload.size()));
    std::copy(payload.begin(), payload.end(), bytes.begin() + ring::kRecordHeaderBytes);
    return bytes;
}

// The caller supplies the real demux/fixture identity and original timestamps.
// This helper does not invent PTS, split AUs, or touch decoder/reference state.
inline RingBytes encodeAccessUnitRecord(const ring::AccessUnit& au,
                                       size_t maxBytes = ring::kMaxAccessUnitBytes) {
    if (!ring::validAccessUnit(au, maxBytes))
        throw std::runtime_error("invalid/oversized AU supplied to DDR BFM");
    const auto metadata = ring::encodeAccessUnitMetadata(au);
    RingBytes payload(metadata.begin(), metadata.end());
    payload.insert(payload.end(), au.annexb, au.annexb + au.len);
    return encodeRingRecord(ring::Event::AccessUnit, au.session_id, au.seq, payload);
}

// Single-qword, held-request slave shared by the transport and decoded-AU
// benches. Keep this object alive across DUT reset: accepted DDR reads are
// not cancelled by a parser reset. Addresses are DDR qword addresses.
class DdrBitstreamRingBfm {
public:
    struct Pending {
        bool valid = false;
        unsigned delay = 0;
        uint64_t data = 0;
    };
    struct Transfer {
        bool read = false, write = false;
        uint32_t address = 0;
        uint64_t data = 0;
        uint8_t byteEnable = 0;
    };

    std::unordered_map<uint32_t, uint64_t> words;
    Pending pending;
    unsigned reads = 0, writes = 0, busyOffers = 0;

    uint64_t load(uint32_t address) const {
        const auto it = words.find(address);
        return it == words.end() ? 0 : it->second;
    }

    void publishCtrl(uint32_t producer, bool epoch) {
        words[ring::kCtrlPhys >> 3] = (uint64_t(producer & ring::kCountMask) << 32) |
                                    (uint64_t(epoch) << 63) | ring::kCtrlMagic;
    }

    void append(uint32_t& producer, const RingBytes& bytes) {
        for (uint8_t byte : bytes) {
            const uint32_t offset = producer & (ring::kRingBytes - 1);
            auto& word = words[(ring::kDataPhys >> 3) + (offset >> 3)];
            const unsigned shift = 8 * (offset & 7);
            word = (word & ~(0xffull << shift)) | (uint64_t(byte) << shift);
            producer = (producer + 1) & ring::kCountMask;
        }
    }

    bool readStatus(ring::Status& status) const {
        const uint64_t read = load(ring::kReadPhys >> 3);
        const uint64_t ctrl = load(ring::kCtrlPhys >> 3);
        const uint64_t level = load(ring::kStat0Phys >> 3);
        const uint64_t seq = load(ring::kStat1Phys >> 3);
        const uint64_t bad = load(ring::kStat2Phys >> 3);
        const uint64_t lo = load(ring::kStat3Phys >> 3);
        const uint64_t hi = load(ring::kStat4Phys >> 3);
        status = {};
        if (uint32_t(read) != ring::kReadMagic || uint32_t(ctrl) != ring::kCtrlMagic ||
            uint32_t(level) != ring::kStat0Magic || uint32_t(seq) != ring::kStat1Magic ||
            uint32_t(bad) != ring::kStat2Magic ||
            uint32_t(lo) != ring::kStat3Magic || uint32_t(hi) != ring::kStat4Magic ||
            !ring::decodeErrStatusWord(load(ring::kErrPhys >> 3), status) ||
            !ring::decodeStat5StatusWord(load(ring::kStat5Phys >> 3), status) ||
            !ring::decodeStat6StatusWord(load(ring::kStat6Phys >> 3), status))
            return false;
        status.consumer_count = uint32_t(read >> 32) & ring::kCountMask;
        status.producer_count = uint32_t(ctrl >> 32) & ring::kCountMask;
        status.ring_level = uint32_t(level >> 32);
        status.consumer_seq = uint32_t(seq >> 32);
        status.last_bad_seq = uint32_t(bad >> 32);
        status.session_id = (lo >> 32) | (hi & 0xffffffff00000000ull);
        return true;
    }

    bool resetAcknowledged(uint32_t producer, bool epoch) const {
        ring::Status status;
        return readStatus(status) && status.consumer_count == (producer & ring::kCountMask) &&
               status.reset_epoch == epoch && !status.active && !status.fatal &&
               !status.desync && !status.overrun;
    }

    bool canAppend(uint32_t producer, size_t recordBytes, bool isData = true) const {
        ring::Status status;
        if (!readStatus(status) || status.fatal || status.desync || status.overrun)
            return false;
        const uint32_t used = ring::countDistance(producer, status.consumer_count);
        const size_t reserve = isData ? ring::kControlReserveBytes : 0;
        if (used > ring::kRingBytes || reserve > ring::kRingBytes - used)
            return false;
        return recordBytes <= ring::kRingBytes - used - reserve;
    }

    bool capabilitiesFor(uint64_t nonce, ring::VideoCapabilities& caps) const {
        std::array<uint64_t, 8> words{};
        for (unsigned i = 0; i < words.size(); ++i)
            words[i] = load((mailbox_abi::kVideoCapsAddr >> 3) + i);
        return ring::decodeVideoCapabilities(words, nonce, caps);
    }

    // Caller sets its clocks low, calls beforePosedge(), samples stream/sink
    // handshakes, raises clocks and evals, then calls afterPosedge().
    // DUT/adapter exposes DDRAM_{BUSY,DOUT,DOUT_READY,ADDR,RD,WE,DIN,BE,BURSTCNT}
    // and eval(); clock names and decoder/sink behavior remain caller-owned.
    template<class Dut>
    Transfer beforePosedge(Dut& dut, uint64_t cycle, bool forceBusy = false,
                           bool randomStalls = true, bool zeroLatency = true) {
        dut.DDRAM_BUSY = forceBusy || (randomStalls && cycle % 23 < 8);
        dut.DDRAM_DOUT_READY = 0;
        dut.DDRAM_DOUT = 0;
        returning_ = false;
        if (pending.valid && --pending.delay == 0) {
            dut.DDRAM_DOUT_READY = 1;
            dut.DDRAM_DOUT = pending.data;
            returning_ = true;
        }
        dut.eval();
        check(!(dut.DDRAM_RD && dut.DDRAM_WE), "simultaneous DDR read/write");
        if (held_) {
            check((dut.DDRAM_RD || dut.DDRAM_WE) && dut.DDRAM_ADDR == priorAddress_ &&
                  dut.DDRAM_DIN == priorData_ && bool(dut.DDRAM_WE) == priorWrite_,
                  "DDR request changed/disappeared while busy");
        }
        held_ = (dut.DDRAM_RD || dut.DDRAM_WE) && dut.DDRAM_BUSY;
        if (held_) {
            ++busyOffers;
            priorAddress_ = dut.DDRAM_ADDR;
            priorData_ = dut.DDRAM_DIN;
            priorWrite_ = dut.DDRAM_WE;
        }
        transfer_ = {bool(dut.DDRAM_RD && !dut.DDRAM_BUSY),
                     bool(dut.DDRAM_WE && !dut.DDRAM_BUSY),
                     uint32_t(dut.DDRAM_ADDR), uint64_t(dut.DDRAM_DIN),
                     uint8_t(dut.DDRAM_BE)};
        if (transfer_.read || transfer_.write)
            check(dut.DDRAM_BURSTCNT == 1, "DDR ring BFM requires single-qword requests");
        if (transfer_.read) {
            check(!pending.valid, "read response ownership duplicated");
            ++reads;
            if (zeroLatency && cycle % 13 == 0) {
                dut.DDRAM_DOUT_READY = 1;
                dut.DDRAM_DOUT = load(transfer_.address);
                dut.eval();
            } else {
                pending = {true, unsigned(2 + cycle % 19), load(transfer_.address)};
            }
        }
        return transfer_;
    }

    void afterPosedge() {
        if (returning_)
            pending.valid = false;
        if (transfer_.write) {
            ++writes;
            auto& word = words[transfer_.address];
            for (unsigned lane = 0; lane < 8; ++lane) {
                if (transfer_.byteEnable & (1u << lane)) {
                    const uint64_t mask = 0xffull << (8 * lane);
                    word = (word & ~mask) | (transfer_.data & mask);
                }
            }
        }
    }

private:
    static void check(bool condition, const char* message) {
        if (!condition)
            throw std::runtime_error(message);
    }
    Transfer transfer_;
    bool returning_ = false, held_ = false, priorWrite_ = false;
    uint32_t priorAddress_ = 0;
    uint64_t priorData_ = 0;
};

} // namespace misterplex::test
