#pragma once

// The single implementation of "HPS DDR bitstream ring" as an
// IBitstreamProducer. Shared by misterplexd and by the standalone bring-up
// feeder so there is exactly one path into the ring: a tool that fed the ring
// differently from the daemon would prove nothing about the daemon.

#include "fpga_spi.hpp"
#include "libmisterplex/h264_bitstream_transport.hpp"

#include <cstdint>
#include <vector>

namespace misterplex {

class FpgaBitstreamProducer final : public h264stream::IBitstreamProducer {
public:
    explicit FpgaBitstreamProducer(FpgaSpi& fpga) : fpga_(fpga) {}

    h264stream::ControlResult begin(uint64_t session_id) override {
        if (active_)
            return h264stream::ControlResult::ActiveSession;
        if (!fpga_.ok() || !fpga_.beginBitstreamSession(session_id, 250))
            return h264stream::ControlResult::Fatal;
        session_id_ = session_id;
        producer_seq_ = 0;
        consumer_seq_ = 0;
        bytes_accepted_ = 0;
        nal_accepted_ = 0;
        desync_count_ = 0;
        last_bad_seq_ = 0;
        active_ = true;
        paused_ = false;
        return h264stream::ControlResult::Ok;
    }

    h264stream::PushResult pushNal(const h264stream::NalView& nal) override {
        if (!active_ || nal.session_id != session_id_ || !nal.annexb || nal.len == 0)
            return h264stream::PushResult::Fatal;
        if (nal.seq != producer_seq_) {
            ++desync_count_;
            last_bad_seq_ = nal.seq;
            return h264stream::PushResult::Desync;
        }
        // Contract: copy-on-push. The caller may reuse the demux accumulator as
        // soon as this function returns, even if a future transport is DMA-backed.
        std::vector<uint8_t> copy(nal.annexb, nal.annexb + nal.len);
        FpgaSpi::BitstreamNal fpgaNal;
        fpgaNal.session_id = nal.session_id;
        fpgaNal.seq = nal.seq;
        fpgaNal.nal_type = nal.nal_type;
        fpgaNal.annexb = copy.data();
        fpgaNal.len = copy.size();
        const auto r = fpga_.pushBitstreamNal(fpgaNal, 0);
        if (r == FpgaSpi::BitstreamPushResult::Full)
            return h264stream::PushResult::Full;
        if (r == FpgaSpi::BitstreamPushResult::Desync) {
            syncStatus();
            return h264stream::PushResult::Desync;
        }
        if (r != FpgaSpi::BitstreamPushResult::Ok)
            return h264stream::PushResult::Fatal;
        ++producer_seq_;
        bytes_accepted_ += copy.size();
        ++nal_accepted_;
        return h264stream::PushResult::Ok;
    }

    h264stream::ControlResult flush(uint64_t session_id) override {
        if (!active_ || session_id != session_id_)
            return h264stream::ControlResult::NoSession;
        if (!fpga_.flushBitstreamSession(session_id, 250))
            return h264stream::ControlResult::Fatal;
        consumer_seq_ = producer_seq_;
        return h264stream::ControlResult::Ok;
    }

    h264stream::ControlResult end(uint64_t session_id) override {
        if (!active_ || session_id != session_id_)
            return h264stream::ControlResult::NoSession;
        if (!fpga_.endBitstreamSession(session_id, 250))
            return h264stream::ControlResult::Fatal;
        active_ = false;
        paused_ = false;
        return h264stream::ControlResult::Ok;
    }

    h264stream::ControlResult pause(uint64_t session_id) override {
        if (!active_ || session_id != session_id_)
            return h264stream::ControlResult::NoSession;
        if (!fpga_.pauseBitstreamSession(session_id, 250))
            return h264stream::ControlResult::Fatal;
        paused_ = true;
        return h264stream::ControlResult::Ok;
    }

    h264stream::ControlResult resume(uint64_t session_id) override {
        if (!active_ || session_id != session_id_)
            return h264stream::ControlResult::NoSession;
        if (!fpga_.resumeBitstreamSession(session_id, 250))
            return h264stream::ControlResult::Fatal;
        paused_ = false;
        return h264stream::ControlResult::Ok;
    }

    h264stream::Telemetry status() const override {
        h264stream::Telemetry t;
        t.session_id = session_id_;
        t.bytes_accepted = bytes_accepted_;
        t.nal_accepted = nal_accepted_;
        t.producer_seq = producer_seq_;
        t.consumer_seq = consumer_seq_;
        t.desync_count = desync_count_;
        t.last_bad_seq = last_bad_seq_;
        t.active = active_;
        t.paused = paused_;
        FpgaSpi::BitstreamStatus s;
        if (fpga_.readBitstreamStatus(s)) {
            t.session_id = s.session_id ? s.session_id : t.session_id;
            t.ring_level_bytes = s.ring_level;
            t.ring_capacity_bytes = s.ring_capacity;
            t.consumer_seq = s.consumer_seq;
            t.underrun_count = s.underrun_count;
            t.overrun_count = s.overrun_count;
            t.desync_count = s.desync_count;
            t.last_bad_seq = s.last_bad_seq;
            t.active = s.active;
            t.paused = s.paused;
        }
        return t;
    }

private:
    void syncStatus() {
        FpgaSpi::BitstreamStatus s;
        if (!fpga_.readBitstreamStatus(s))
            return;
        consumer_seq_ = s.consumer_seq;
        desync_count_ = s.desync_count;
        last_bad_seq_ = s.last_bad_seq;
        paused_ = s.paused;
        active_ = s.active;
    }

    FpgaSpi& fpga_;
    uint64_t session_id_ = 0;
    uint32_t producer_seq_ = 0;
    uint32_t consumer_seq_ = 0;
    uint64_t bytes_accepted_ = 0;
    uint64_t nal_accepted_ = 0;
    uint64_t desync_count_ = 0;
    uint32_t last_bad_seq_ = 0;
    bool active_ = false;
    bool paused_ = false;
};

} // namespace misterplex
