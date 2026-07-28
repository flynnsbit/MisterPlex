#include <cstdlib>
#include <iostream>
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

} // namespace

int main() {
    misterplex::Companion comp;
    comp.setMachineId("misterplex-dev");

    misterplex::PlayRequest req;
    req.key = "/library/metadata/3";
    req.ratingKey = "3";
    req.playQueueItemId = "3";
    req.address = "192.168.1.41";
    req.protocol = "http";
    req.port = "32400";
    req.serverMachineId = "plex-server";
    req.offsetMs = 42000;
    req.offsetPresent = true;

    comp.stagePlay(req);
    require(comp.bindMedia(req, 1286942), "bindMedia rejected planted seek");

    const std::string planted = comp.timelineXml("planted");
    require(has(planted, "location=\"fullScreenVideo\""),
            "planted seek not fullScreenVideo: " + planted);
    require(has(planted, "time=\"42000\""), "planted seek did not report 42000: " + planted);
    require(has(planted, "key=\"/library/metadata/3\""),
            "planted seek lost media key: " + planted);

    // Empty/failed demux after a planted seek reaches the same state=="stopped"
    // branch as terminal EOF, but with media time 0. It must NOT clear the media
    // bind or scrub target: the user has not reached terminal playback; the player
    // has merely failed before confirming progress at the planted offset.
    comp.setState("stopped", 0, 1286942);

    const std::string after = comp.timelineXml("after-empty-stop");
    require(has(after, "location=\"fullScreenVideo\""),
            "planted seek was cleared by stopped@0: " + after);
    require(has(after, "state=\"buffering\""),
            "planted seek stopped@0 should remain buffering: " + after);
    require(has(after, "time=\"42000\""),
            "planted seek time was not preserved: " + after);
    require(has(after, "key=\"/library/metadata/3\""),
            "planted seek key was cleared: " + after);

    misterplex::Companion freshPlay;
    freshPlay.setMachineId("misterplex-dev");
    req.offsetMs = 0;
    req.offsetPresent = true;
    freshPlay.stagePlay(req);
    require(freshPlay.bindMedia(req, 1286942), "bindMedia rejected fresh play");
    // First real progress can arrive more than kScrubCatchupMs after playMedia
    // because the rawvideo path waits for FFmpeg, audio origin, and the first
    // decoded frame. That is still progress beyond the planted play offset, not
    // stale pre-seek progress. The client-facing poll must advance.
    freshPlay.setState("playing", 2500, 1286942);
    const std::string freshPlaying = freshPlay.timelineXml("fresh-playing");
    require(has(freshPlaying, "state=\"playing\""),
            "fresh play did not report playing: " + freshPlaying);
    require(has(freshPlaying, "time=\"2500\""),
            "fresh play progress stayed pinned at zero: " + freshPlaying);
    freshPlay.setState("paused", 2500, 1286942);
    const std::string freshPaused = freshPlay.timelineXml("fresh-paused");
    require(has(freshPaused, "state=\"paused\""),
            "fresh play pause did not report paused: " + freshPaused);
    require(has(freshPaused, "time=\"2500\""),
            "fresh play pause stayed pinned at zero: " + freshPaused);

    misterplex::Companion staleSeek;
    staleSeek.setMachineId("misterplex-dev");
    req.offsetMs = 42000;
    req.offsetPresent = true;
    staleSeek.stagePlay(req);
    require(staleSeek.bindMedia(req, 1286942), "bindMedia rejected stale seek");
    staleSeek.setState("playing", 2500, 1286942);
    const std::string stale = staleSeek.timelineXml("stale-seek");
    require(has(stale, "time=\"42000\""),
            "stale pre-seek progress was allowed to rewind planted seek: " + stale);
    require(has(stale, "state=\"playing\""),
            "stale pre-seek progress should reflect transport only: " + stale);

    std::cout << "test_companion_plant_seek: OK\n";
    return 0;
}
