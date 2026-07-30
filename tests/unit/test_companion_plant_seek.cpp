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

    // Regression: playMedia plants scrubTarget=0, then demux starts far ahead
    // (viewOffset applied in doPlay, or first progress jumps). The FAR hold branch
    // must not freeze the Web poll scrubber at the stale plant forever — only
    // suppress rewinds while demux is still *behind* the plant (seek restart@0).
    misterplex::Companion ahead;
    ahead.setMachineId("misterplex-dev");
    misterplex::PlayRequest fromStart = req;
    fromStart.offsetMs = 0;
    fromStart.offsetPresent = false;
    ahead.stagePlay(fromStart);
    require(ahead.bindMedia(fromStart, 1286942), "bindMedia rejected offset-0 plant");
    // Demux reports playing well past plant (simulates viewOffset start / jump).
    ahead.setState("playing", 120000, 1286942);
    const std::string live = ahead.timelineXml("ahead-of-plant");
    require(has(live, "state=\"playing\""), "ahead-of-plant lost playing: " + live);
    require(has(live, "time=\"120000\""),
            "scrubber froze at plant 0 while demux was ahead: " + live);

    // doPlay path: seedPlaybackPosition rebases plant before demux starts.
    misterplex::Companion seeded;
    seeded.setMachineId("misterplex-dev");
    seeded.stagePlay(fromStart); // plant 0
    require(seeded.bindMedia(fromStart, 1286942), "bindMedia rejected seed plant");
    seeded.seedPlaybackPosition(120000, 1286942);
    const std::string seededXml = seeded.timelineXml("seeded-viewoffset");
    require(has(seededXml, "time=\"120000\""),
            "seedPlaybackPosition did not move scrubber: " + seededXml);
    seeded.setState("playing", 0, 1286942); // demux restart behind seeded plant
    const std::string seededPin = seeded.timelineXml("seeded-restart");
    require(has(seededPin, "time=\"120000\""),
            "seeded plant must pin across demux restart@0: " + seededPin);
    seeded.setState("playing", 120500, 1286942);
    const std::string seededLive = seeded.timelineXml("seeded-live");
    require(has(seededLive, "time=\"120500\""),
            "seeded plant must release once demux passes: " + seededLive);

    // Seek plant must still pin across early demux restart@0 (do not adopt rewind).
    misterplex::Companion seekHold;
    seekHold.setMachineId("misterplex-dev");
    seekHold.stagePlay(req); // offset 42000
    require(seekHold.bindMedia(req, 1286942), "bindMedia rejected seek plant");
    seekHold.setState("playing", 0, 1286942); // demux restart behind plant
    const std::string pinned = seekHold.timelineXml("seek-restart");
    require(has(pinned, "time=\"42000\""),
            "seek plant must pin across demux restart@0: " + pinned);
    seekHold.setState("playing", 42400, 1286942); // catch-up past plant
    const std::string released = seekHold.timelineXml("seek-caught-up");
    require(has(released, "time=\"42400\""),
            "seek plant must release once demux passes plant: " + released);

    std::cout << "test_companion_plant_seek: OK\n";
    return 0;
}
