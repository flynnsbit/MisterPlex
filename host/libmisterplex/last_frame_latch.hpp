#pragma once

#include "ddr_frame_layout.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace misterplex {

class LastFrameLatch {
public:
    class CachedFrame {
    public:
        const uint8_t* data() const { return bytes_.data(); }
        size_t size() const { return bytes_.size(); }
        const DdrFrameGeometry& geometry() const { return geometry_; }
        const DdrFrameLayout& layout() const { return layout_; }
        bool valid() const { return valid_ && !bytes_.empty() && ddrFrameLayoutValid(layout_); }

    private:
        friend class LastFrameLatch;

        bool reset(const uint8_t* frame, size_t len, const DdrFrameGeometry& geometry) {
            const DdrFrameLayout layout = makeDdrFrameLayout(
                geometry, kDdrFramePhysBase, kDdrFrameStrideAlign, DdrFrameFormat::Yuv420p);
            if (!frame || len == 0 || !ddrFrameLayoutValid(layout) || len != layout.frame_bytes) {
                clear();
                return false;
            }
            bytes_.assign(frame, frame + len);
            geometry_ = geometry;
            layout_ = layout;
            valid_ = true;
            return true;
        }

        void clear() {
            bytes_.clear();
            geometry_ = DdrFrameGeometry{};
            layout_ = DdrFrameLayout{};
            valid_ = false;
        }

        void forceGeometryForFault(const DdrFrameGeometry& geometry) {
            geometry_ = geometry;
            layout_ = makeDdrFrameLayout(geometry, kDdrFramePhysBase, kDdrFrameStrideAlign,
                                         DdrFrameFormat::Yuv420p);
        }

        std::vector<uint8_t> bytes_;
        DdrFrameGeometry geometry_{};
        DdrFrameLayout layout_{};
        bool valid_ = false;
    };

    struct Publication {
        const CachedFrame& frame;
        int bank = 0;
        uint32_t bank_phys = 0;
    };

    bool remember(const uint8_t* frame, size_t len, const DdrFrameGeometry& geometry) {
        return cached_.reset(frame, len, geometry);
    }

    void clear() { cached_.clear(); }

    bool haveFrame() const { return cached_.valid(); }
    const CachedFrame& frame() const { return cached_; }

    template <typename Sender>
    bool publishToBothBanks(Sender&& send, int& nextBank) const {
        if (!haveFrame())
            return false;
#ifdef LAST_FRAME_LATCH_FAULT_IDLE_GEOMETRY
        CachedFrame sendFrame = cached_;
        sendFrame.forceGeometryForFault(plex480pDdrFrameGeometry());
#else
        const CachedFrame& sendFrame = cached_;
#endif
        int bank = nextBank & 1;
        if (!publishOne(send, sendFrame, bank))
            return false;
        nextBank = bank ^ 1;
        bank = nextBank & 1;
        if (!publishOne(send, sendFrame, bank))
            return false;
        nextBank = bank ^ 1;
        return true;
    }

private:
    template <typename Sender>
    static bool publishOne(Sender&& send, const CachedFrame& frame, int bank) {
#ifdef LAST_FRAME_LATCH_FAULT_BANK_BASE
        const DdrFrameLayout wrong = makeDdrFrameLayout(
            plex480pDdrFrameGeometry(), kDdrFramePhysBase, kDdrFrameStrideAlign,
            DdrFrameFormat::Yuv420p);
        const uint32_t bankPhys = wrong.phys_base + static_cast<uint32_t>(bank & 1) * wrong.bank_stride;
#else
        const uint32_t bankPhys = frame.layout().phys_base +
                                  static_cast<uint32_t>(bank & 1) * frame.layout().bank_stride;
#endif
        return send(Publication{frame, bank & 1, bankPhys});
    }

    CachedFrame cached_;
};

} // namespace misterplex
