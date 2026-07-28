#pragma once

#include "libmisterplex/h264_bitstream_transport.hpp"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <thread>
#include <utility>
#include <vector>

namespace misterplex::h264stream {

inline size_t annexBStartLen(const uint8_t* p, size_t n, size_t off = 0) {
    if (!p || off >= n)
        return 0;
    if (off + 4 <= n && p[off] == 0 && p[off + 1] == 0 && p[off + 2] == 0 && p[off + 3] == 1)
        return 4;
    if (off + 3 <= n && p[off] == 0 && p[off + 1] == 0 && p[off + 2] == 1)
        return 3;
    return 0;
}

inline uint8_t annexBNalType(const uint8_t* annexb, size_t len) {
    const size_t sc = annexBStartLen(annexb, len, 0);
    if (!sc || sc >= len)
        return 0;
    return annexb[sc] & 0x1f;
}

struct DispatchConfig {
    int max_full_retries = 50;
    int full_retry_sleep_ms = 2;
    // Re-send SPS/PPS ahead of every IDR so that EVERY IDR in the ring is a
    // valid decoder entry point. Without this the parameter sets are pushed
    // once per session and a consumer that starts late, restarts, or loses the
    // head of the ring to a wrap can never decode anything again. 7 IDRs per
    // title at ~30 bytes each -- the cost is nil, the failure it removes is total.
    bool replay_parameters_each_idr = true;
    // A full ring means the FPGA consumer is absent or stalled, which is the
    // NORMAL condition during decoder bring-up. Dropping to the next IDR and
    // resuming is recoverable; killing the feed for the rest of the session is
    // not, and leaves the decoder looking at a stale ring through no fault of
    // its own.
    bool resync_on_full = true;
    // Stage-B bring-up: feed keyframes only. Non-IDR slices are dropped, so
    // the ring carries nothing but self-contained pictures -- 7 per title for
    // the measured content instead of 350. A decoder that can only do intra
    // then has a stream it can consume in full rather than a stream where 98%
    // of the NALs are ones it must silently ignore. Off in the product path.
    bool idr_only = false;
    std::function<void(int)> sleep_ms = [](int ms) {
        std::this_thread::sleep_for(std::chrono::milliseconds(ms));
    };
};

struct DispatchStats {
    uint64_t nal_seen = 0;
    uint64_t nal_pushed = 0;
    uint64_t bytes_pushed = 0;
    uint64_t nal_dropped_paused = 0;
    uint64_t sps_replayed = 0;
    uint64_t pps_replayed = 0;
    uint64_t full_retries = 0;
    uint64_t full_escalations = 0;
    uint64_t desync_or_fatal = 0;
    uint64_t resyncs = 0;            // times the ring stayed full and we dropped to the next IDR
    uint64_t nal_dropped_resync = 0; // NALs discarded while waiting for that IDR
    uint64_t nal_dropped_idr_only = 0; // non-IDR slices dropped by idr_only
};

class AnnexBFramer {
public:
    explicit AnnexBFramer(size_t maxAccumBytes = 2 * 1024 * 1024) : max_acc_(maxAccumBytes) {}

    void reset() {
        acc_.clear();
        parse_from_ = 0;
    }

    template <typename Fn>
    bool push(const uint8_t* data, size_t len, Fn&& onNal) {
        if (data && len)
            acc_.insert(acc_.end(), data, data + len);
        return emitComplete(false, std::forward<Fn>(onNal));
    }

    template <typename Fn>
    bool finish(Fn&& onNal) {
        return emitComplete(true, std::forward<Fn>(onNal));
    }

private:
    template <typename Fn>
    bool emitComplete(bool final, Fn&& onNal) {
        size_t i = parse_from_;
        while (i + 3 < acc_.size()) {
            if (annexBStartLen(acc_.data(), acc_.size(), i))
                break;
            ++i;
        }
        if (i > 0) {
            acc_.erase(acc_.begin(), acc_.begin() + static_cast<std::ptrdiff_t>(i));
            parse_from_ = 0;
            i = 0;
        }
        while (i + 3 < acc_.size()) {
            const size_t sc = annexBStartLen(acc_.data(), acc_.size(), i);
            if (!sc) {
                ++i;
                continue;
            }
            size_t j = i + sc;
            bool foundNext = false;
            while (j + 2 < acc_.size()) {
                if (annexBStartLen(acc_.data(), acc_.size(), j)) {
                    foundNext = true;
                    break;
                }
                ++j;
            }
            if (!foundNext) {
                if (!final) {
                    parse_from_ = i;
                    if (acc_.size() > max_acc_)
                        reset();
                    return true;
                }
                j = acc_.size();
            }
            if (j > i + sc) {
                onNal(acc_.data() + i, j - i);
            }
            i = j;
            if (final && i >= acc_.size())
                break;
        }
        if (i > 0 && i <= acc_.size())
            acc_.erase(acc_.begin(), acc_.begin() + static_cast<std::ptrdiff_t>(i));
        parse_from_ = 0;
        return true;
    }

    size_t max_acc_ = 0;
    std::vector<uint8_t> acc_;
    size_t parse_from_ = 0;
};

class NalDispatcher {
public:
    NalDispatcher(IBitstreamProducer& producer, DispatchConfig cfg = {})
        : producer_(producer), cfg_(std::move(cfg)) {}

    ControlResult begin(uint64_t session_id) {
        const auto r = producer_.begin(session_id);
        if (r != ControlResult::Ok)
            return r;
        session_id_ = session_id;
        seq_ = 0;
        active_ = true;
        paused_ = false;
        sps_delivered_ = false;
        pps_delivered_ = false;
        sps_.clear();
        pps_.clear();
        stats_ = {};
        return ControlResult::Ok;
    }

    ControlResult flushForSeek(uint64_t new_session_id) {
        if (active_) {
            const auto f = producer_.flush(session_id_);
            if (f != ControlResult::Ok)
                return f;
            const auto e = producer_.end(session_id_);
            if (e != ControlResult::Ok)
                return e;
            active_ = false;
        }
        return begin(new_session_id);
    }

    ControlResult end() {
        if (!active_)
            return ControlResult::NoSession;
        const auto r = producer_.end(session_id_);
        if (r == ControlResult::Ok)
            active_ = false;
        return r;
    }

    ControlResult pause() {
        if (!active_)
            return ControlResult::NoSession;
        const auto r = producer_.pause(session_id_);
        if (r == ControlResult::Ok)
            paused_ = true;
        return r;
    }

    ControlResult resume() {
        if (!active_)
            return ControlResult::NoSession;
        const auto r = producer_.resume(session_id_);
        if (r == ControlResult::Ok) {
            paused_ = false;
            sps_delivered_ = false;
            pps_delivered_ = false;
        }
        return r;
    }

    PushResult handleNal(const uint8_t* annexb, size_t len) {
        if (!active_ || !annexb || !len)
            return PushResult::Fatal;
        const uint8_t type = annexBNalType(annexb, len);
        if (type == 0)
            return PushResult::Fatal;
        ++stats_.nal_seen;

        if (type == 7)
            sps_.assign(annexb, annexb + len);
        else if (type == 8)
            pps_.assign(annexb, annexb + len);

        if (paused_) {
            ++stats_.nal_dropped_paused;
            return PushResult::Ok;
        }

        // Resyncing: the ring stayed full, so the consumer has certainly lost
        // stream continuity. Only an IDR can restore it; everything else is
        // undecodable without the frames we already dropped.
        if (resyncing_) {
            if (type != 5) {
                ++stats_.nal_dropped_resync;
                return PushResult::Ok;
            }
            resyncing_ = false;
            sps_delivered_ = false;
            pps_delivered_ = false;
        }

        if (cfg_.idr_only && type == 1) {
            ++stats_.nal_dropped_idr_only;
            return PushResult::Ok;
        }

        // An IDR is a random-access point only if the parameter sets precede
        // it. Re-arm so they are re-sent, making every IDR self-contained.
        if (type == 5 && cfg_.replay_parameters_each_idr) {
            sps_delivered_ = false;
            pps_delivered_ = false;
        }

        if (type == 1 || type == 5) {
            const auto pr = replayParametersIfNeeded();
            if (pr != PushResult::Ok)
                return absorbFull(pr);
        }

        const auto r = pushWithBackpressure(annexb, len, type, false);
        if (r == PushResult::Ok) {
            if (type == 7)
                sps_delivered_ = true;
            else if (type == 8)
                pps_delivered_ = true;
        }
        return absorbFull(r);
    }

    const DispatchStats& stats() const { return stats_; }
    uint64_t sessionId() const { return session_id_; }
    uint32_t nextSeq() const { return seq_; }

private:
    // A full ring is backpressure, not corruption. Convert it into a resync
    // request so the producer keeps running and rejoins at the next IDR.
    // Returned as Ok because the caller's contract is "anything but Ok is
    // fatal" -- and a stalled consumer must not be fatal to the producer.
    PushResult absorbFull(PushResult r) {
        if (r != PushResult::Full || !cfg_.resync_on_full)
            return r;
        if (!resyncing_) {
            resyncing_ = true;
            ++stats_.resyncs;
        }
        sps_delivered_ = false;
        pps_delivered_ = false;
        return PushResult::Ok;
    }

    PushResult replayParametersIfNeeded() {
        if (!sps_delivered_) {
            if (sps_.empty())
                return PushResult::Desync;
            const auto r = pushWithBackpressure(sps_.data(), sps_.size(), 7, true);
            if (r != PushResult::Ok)
                return r;
            sps_delivered_ = true;
            ++stats_.sps_replayed;
        }
        if (!pps_delivered_) {
            if (pps_.empty())
                return PushResult::Desync;
            const auto r = pushWithBackpressure(pps_.data(), pps_.size(), 8, true);
            if (r != PushResult::Ok)
                return r;
            pps_delivered_ = true;
            ++stats_.pps_replayed;
        }
        return PushResult::Ok;
    }

    PushResult pushWithBackpressure(const uint8_t* data, size_t len, uint8_t type, bool replay) {
        for (int attempt = 0; attempt <= cfg_.max_full_retries; ++attempt) {
            NalView nal{session_id_, seq_, type, data, len};
            const auto r = producer_.pushNal(nal);
            if (r == PushResult::Ok) {
                ++seq_;
                ++stats_.nal_pushed;
                stats_.bytes_pushed += len;
                (void)replay;
                return r;
            }
            if (r != PushResult::Full) {
                ++stats_.desync_or_fatal;
                return r;
            }
            ++stats_.full_retries;
            if (attempt == cfg_.max_full_retries)
                break;
            if (cfg_.sleep_ms && cfg_.full_retry_sleep_ms > 0)
                cfg_.sleep_ms(cfg_.full_retry_sleep_ms);
        }
        ++stats_.full_escalations;
        return PushResult::Full;
    }

    IBitstreamProducer& producer_;
    DispatchConfig cfg_;
    uint64_t session_id_ = 0;
    uint32_t seq_ = 0;
    bool active_ = false;
    bool paused_ = false;
    bool sps_delivered_ = false;
    bool pps_delivered_ = false;
    bool resyncing_ = false;
    std::vector<uint8_t> sps_;
    std::vector<uint8_t> pps_;
    DispatchStats stats_;
};

} // namespace misterplex::h264stream
