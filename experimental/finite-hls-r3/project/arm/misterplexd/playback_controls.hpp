#pragma once

#include "companion.hpp"
#include "pms_timeline.hpp"
#include <atomic>
#include <cstdio>
#include <mutex>
#include <utility>

namespace misterplex {

struct TransportGenerations {
    std::atomic<uint64_t>& play;
    std::atomic<uint64_t>& seek;

    TransportRequest accept(TransportCommand command, uint64_t epoch) {
        TransportRequest request;
        if (command == TransportCommand::Seek || command == TransportCommand::Previous ||
            command == TransportCommand::Stop)
            request.seekGeneration = ++seek;
        else
            request.seekGeneration = seek.load();
        request.generation = command == TransportCommand::Seek || command == TransportCommand::Stop
            ? ++play : play.load();
        request.epoch = epoch;
        return request;
    }

    bool current(const TransportRequest& request) const {
        return request.generation == play.load() && request.seekGeneration == seek.load();
    }
};

// Caller owns the serialized player/reporter handoff. stop() returns its
// post-join snapshot, not the position/duration it subsequently clears.
template<class Player>
void retirePlayback(Player& player, PmsTimelineReporter& reporter) {
    const auto final = player.stop();
    reporter.endSession(final.timeMs, final.durationMs);
}

template<class Player, class Start, class Clear, class Post>
void wirePlaybackControls(Companion& companion, Player& player, PmsTimelineReporter& reporter,
                          TransportGenerations generations, std::atomic<uint64_t>& activePlay,
                          std::mutex& handoff, std::mutex& seekMutex,
                          Start start, Clear clear, Post post) {
    companion.setTransportQueued([generations, &player](TransportCommand command) mutable {
        return generations.accept(command, player.playbackEpoch());
    });
    auto pauseResume = [generations, &player, &handoff](const TransportRequest& request, bool pause) {
        std::lock_guard<std::mutex> lock(handoff);
        if (!generations.current(request) || player.playbackEpoch() != request.epoch ||
            !player.playing())
            return;
        if (pause)
            player.pause();
        else
            player.resume();
    };
    companion.setPause([pauseResume](const TransportRequest& request) {
        pauseResume(request, true);
    });
    companion.setResume([pauseResume](const TransportRequest& request) {
        pauseResume(request, false);
    });
    companion.setStop([generations, &player, &reporter, &handoff, clear]
                      (const TransportRequest& request) {
        std::lock_guard<std::mutex> lock(handoff);
        if (!generations.current(request))
            return;
        retirePlayback(player, reporter);
        clear();
    });
    companion.setSeek([generations, &player, &activePlay, &handoff, &seekMutex, start, post]
                      (const TransportRequest& request) {
        post([generations, &player, &activePlay, &handoff, &seekMutex, start, request] {
            std::lock_guard<std::mutex> seekLock(seekMutex);
            if (!generations.current(request))
                return;
            try {
                const auto& media = request.media;
                if (media.key.rfind("/library", 0) == 0 ||
                    media.key.find("library/metadata") != std::string::npos) {
                    start(media);
                } else {
                    {
                        std::lock_guard<std::mutex> lock(handoff);
                        if (!generations.current(request))
                            return;
                        const auto binding = player.startedPlayback();
                        if (binding.generation != 0 &&
                            binding.generation == request.originGeneration &&
                            binding.epoch == request.epoch &&
                            binding.epoch == player.playbackEpoch()) {
                            player.seekMs(media.offsetMs, [&activePlay, request] {
                                activePlay.store(request.generation);
                            }, request.generation);
                            return;
                        }
                    }
                    // Loading/unknown bindings belong to the captured request,
                    // not the previous currentUrl. start() reacquires handoff.
                    if (generations.current(request))
                        start(media);
                }
            } catch (...) {
                std::fputs("misterplexd: seek exception\n", stderr);
            }
        });
    });
}

} // namespace misterplex
