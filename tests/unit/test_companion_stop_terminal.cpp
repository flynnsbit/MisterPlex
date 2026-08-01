// Gate: after cast+play+stop (clearMedia), timeline must converge to a terminal
// state (stopped@navigation) within the next poll — never stick in buffering
// solely because castBound_ remained true.
//
// Parent device evidence (daemon 9ce2c2d1): HDMI overlay STOPPED while
// /player/timeline/poll stayed state=buffering across two stops + ~30s.
// holdIdle used (prePlayHold_ || castBound_) without requiring a media plant.
//
// History: holdIdle introduced 814df4a8 (2026-07-24) — NOT a same-day regression
// vs f3aa2443; latent until exercised with castBound after clearMedia.
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string>

#define private public
#include "companion.hpp"
#undef private

namespace {

void require(bool ok, const std::string& msg) {
    if (!ok) {
        std::cerr << "FAIL: " << msg << "\n";
        std::exit(1);
    }
}

bool has(const std::string& s, const std::string& needle) {
    return s.find(needle) != std::string::npos;
}

misterplex::PlayRequest episodeRequest() {
    misterplex::PlayRequest req;
    req.key = "/library/metadata/9";
    req.ratingKey = "9";
    req.playQueueItemId = "9";
    req.address = "192.168.1.41";
    req.protocol = "http";
    req.port = "32400";
    req.serverMachineId = "plex-server";
    req.offsetMs = 0;
    req.offsetPresent = true;
    return req;
}

} // namespace

int main() {
    misterplex::Companion comp;
    comp.setMachineId("misterplex-dev");

    auto req = episodeRequest();
    comp.stagePlay(req);
    // Simulate cast bind the way playMedia does (castBound_ + wantPlay_).
    {
        std::lock_guard<std::mutex> lock(comp.mu_);
        comp.castBound_ = true;
        comp.wantPlay_ = true;
        comp.prePlayHold_ = false;
        comp.state_ = "playing";
        comp.timeMs_ = 12000;
        comp.durationMs_ = 600000;
        comp.pendingKey_ = req.key;
        comp.pendingRatingKey_ = req.ratingKey;
    }
    require(comp.bindMedia(req, 600000), "bindMedia rejected");
    comp.setState("playing", 12000, 600000);
    const std::string live = comp.timelineXml("live");
    require(has(live, "state=\"playing\""), "live not playing: " + live);
    require(has(live, "location=\"fullScreenVideo\""), "live not fullScreen: " + live);

    // Explicit stop path (same as HTTP isStop → clearMedia).
    comp.clearMedia();
    // Bounded convergence: first poll after stop must already be terminal.
    // (No async timer in companion — "within bound" == next timelineXml.)
    const std::string stopped = comp.timelineXml("after-stop");
    require(has(stopped, "location=\"navigation\""),
            "stop did not return navigation: " + stopped);
    require(has(stopped, "state=\"stopped\""),
            "stop must be terminal stopped, got: " + stopped);
    require(!has(stopped, "state=\"buffering\""),
            "stop stuck in buffering (castBound hold defect): " + stopped);
    require(has(stopped, "duration=\"0\""), "stop retained duration: " + stopped);
    require(!has(stopped, "key=\"/library/metadata/9\""),
            "stop retained media key: " + stopped);

    // Second poll still terminal (parent saw stickiness across ~30s / two stops).
    const std::string again = comp.timelineXml("after-stop-2");
    require(has(again, "state=\"stopped\""), "second poll left terminal: " + again);
    require(!has(again, "state=\"buffering\""), "second poll re-entered buffering: " + again);

    // endMediaSession (EOF) with castBound must also terminate.
    misterplex::Companion eof;
    eof.setMachineId("misterplex-dev");
    req = episodeRequest();
    eof.stagePlay(req);
    require(eof.bindMedia(req, 1000), "eof bind");
    {
        std::lock_guard<std::mutex> lock(eof.mu_);
        eof.castBound_ = true;
    }
    eof.setState("playing", 900, 1000);
    eof.endMediaSession(1000, 1000);
    const std::string eofXml = eof.timelineXml("eof-cast");
    require(has(eofXml, "state=\"stopped\""), "EOF+castBound not stopped: " + eofXml);
    require(!has(eofXml, "state=\"buffering\""), "EOF+castBound buffering: " + eofXml);

    std::cout << "test_companion_stop_terminal: OK stopped@navigation after clearMedia "
                 "with castBound (not buffering forever)\n";
    return 0;
}
