#pragma once

#include "ddr_frame_layout.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace misterplex {

class LastFrameLatch {
public:
    void clear() {
        frame_.clear();
        geometry_ = DdrFrameGeometry{};
        have_ = false;
    }

    void remember(const uint8_t* frame, size_t len, const DdrFrameGeometry& geometry) {
        if (!frame || len == 0 || geometry.coded_width <= 0 || geometry.coded_height <= 0) {
            clear();
            return;
        }
        frame_.assign(frame, frame + len);
        geometry_ = geometry;
        have_ = true;
    }

    bool haveFrame() const { return have_ && !frame_.empty(); }
    const DdrFrameGeometry& geometry() const { return geometry_; }
    const std::vector<uint8_t>& frame() const { return frame_; }

    template <typename Sender>
    bool publishToBothBanks(Sender&& send, int& nextBank) const {
        if (!haveFrame())
            return false;
        int bank = nextBank & 1;
#ifdef LAST_FRAME_LATCH_FAULT_IDLE_GEOMETRY
        DdrFrameGeometry sendGeometry = plex480pDdrFrameGeometry();
#else
        DdrFrameGeometry sendGeometry = geometry_;
#endif
        if (!send(frame_.data(), frame_.size(), sendGeometry, bank))
            return false;
        nextBank = bank ^ 1;
        bank = nextBank & 1;
        if (!send(frame_.data(), frame_.size(), sendGeometry, bank))
            return false;
        nextBank = bank ^ 1;
        return true;
    }

private:
    std::vector<uint8_t> frame_;
    DdrFrameGeometry geometry_{};
    bool have_ = false;
};

} // namespace misterplex
