// Models async seek vs stop: a seek thread scheduled before stop must not
// leave demux running after stop invalidates the generation / session.
//
// Pre-fix: stop does not bump seekGen; seek calls seekMs unconditionally →
// demux restarts after stop.
// Fixed: bump seekGen on stop + re-check gen/session before AND after demux;
// post-check kills zombie restart (matches main.cpp seekAsync).
// RED twin (CAST_SEEK_STOP_FAULT): unlocked path must show persist > 0.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <thread>

namespace {

std::mutex seekMu;
std::atomic<uint64_t> seekGen{0};
std::atomic<bool> wantPlay{false};
std::atomic<int> demuxLive{0}; // 1 if demux left running after worker returns

void seek_worker(uint64_t g, bool fixed) {
    std::this_thread::sleep_for(std::chrono::microseconds(200));
    std::lock_guard<std::mutex> lock(seekMu);
    if (fixed) {
        if (g != seekGen.load())
            return;
        if (!wantPlay.load(std::memory_order_relaxed))
            return;
    } else {
        // FAULT: only newer-seek supersession; stop does not bump seekGen.
        if (g != seekGen.load())
            return;
    }
    // Demux restart (seekMs/doPlay). stop may race here without holding seekMu.
    demuxLive.store(1, std::memory_order_relaxed);
    if (fixed) {
        // Post-check + kill zombie (product path after seekMs/doPlay).
        if (g != seekGen.load() || !wantPlay.load(std::memory_order_relaxed)) {
            demuxLive.store(0, std::memory_order_relaxed); // player.stop()
            return;
        }
    }
}

void stop_handler(bool bump_seek_gen) {
    wantPlay.store(false, std::memory_order_relaxed);
    if (bump_seek_gen)
        ++seekGen;
    // player.stop() — if seek already finished without post-check, demux stays up
    // only on the fault path. On fixed path seek's post-check clears demuxLive.
    if (bump_seek_gen) {
        // Product stop also kills current demux; model: clear only if seek not
        // mid-flight holding the "restarted after our kill" case. Simpler: stop
        // always kills current, then a late seek without post-check respawns.
        // Order in product: ++seekGen then player.stop then late seekMs may play.
        demuxLive.store(0, std::memory_order_relaxed);
    }
}

// bad = demux still live after both threads join and wantPlay is false
int race_round(bool fixed, int jitter_us) {
    wantPlay.store(true, std::memory_order_relaxed);
    demuxLive.store(0, std::memory_order_relaxed);
    seekGen.store(0, std::memory_order_relaxed);
    const uint64_t g = ++seekGen;

    std::atomic<int> go{0};
    std::thread seek_thr([&]() {
        while (go.load(std::memory_order_acquire) == 0)
            std::this_thread::yield();
        seek_worker(g, fixed);
    });
    std::thread stop_thr([&]() {
        while (go.load(std::memory_order_acquire) == 0)
            std::this_thread::yield();
        if (jitter_us > 0)
            std::this_thread::sleep_for(std::chrono::microseconds(jitter_us));
        stop_handler(fixed);
    });
    go.store(1, std::memory_order_release);
    seek_thr.join();
    stop_thr.join();

    // Fault path: seek may restart AFTER stop cleared demuxLive (no post-check).
    // Re-run the fault tail: if !fixed and seek set live after stop, it sticks.
    // With threads joined, demuxLive reflects final state.
    if (!wantPlay.load(std::memory_order_relaxed) &&
        demuxLive.load(std::memory_order_relaxed) != 0)
        return 1;
    return 0;
}

int count_bad(bool fixed, int rounds) {
    int bad = 0;
    for (int i = 0; i < rounds; ++i)
        bad += race_round(fixed, (i % 7) * 50);
    return bad;
}

} // namespace

int main() {
#ifdef CAST_SEEK_STOP_FAULT
    // Force fault ordering: stop first, then unconditional seek restart.
    // (Concurrent model alone can miss if stop runs after seek finishes cleanly.)
    int forced = 0;
    for (int i = 0; i < 40; ++i) {
        wantPlay.store(true);
        demuxLive.store(0);
        seekGen.store(0);
        const uint64_t g = ++seekGen;
        stop_handler(/*bump=*/false); // stop without gen bump
        // late seek — pre-fix unconditional
        {
            std::lock_guard<std::mutex> lock(seekMu);
            if (g == seekGen.load()) // still equal — stop did not bump
                demuxLive.store(1);
        }
        if (!wantPlay.load() && demuxLive.load())
            ++forced;
    }
    const int concurrent = count_bad(/*fixed=*/false, 40);
    const int bad = forced + concurrent;
    std::printf("fault_stop_seek_persist=%d (forced=%d concurrent=%d)\n", bad, forced,
                concurrent);
    if (bad == 0) {
        std::fprintf(stderr, "FAIL: fault model never left demux live after stop\n");
        return 1;
    }
    std::printf("RED OK: unlocked stop/seek leaves demux live (%d)\n", bad);
    return 0;
#else
    const int bad_unlocked = count_bad(/*fixed=*/false, 60);
    // Also forced unlocked ordering (stop then seek without gen bump)
    int forced_unlocked = 0;
    for (int i = 0; i < 40; ++i) {
        wantPlay.store(true);
        demuxLive.store(0);
        seekGen.store(0);
        const uint64_t g = ++seekGen;
        stop_handler(/*bump=*/false);
        {
            std::lock_guard<std::mutex> lock(seekMu);
            if (g == seekGen.load())
                demuxLive.store(1); // unconditional
        }
        if (!wantPlay.load() && demuxLive.load())
            ++forced_unlocked;
    }
    const int unlocked = bad_unlocked + forced_unlocked;

    const int bad_fixed = count_bad(/*fixed=*/true, 120);
    int forced_fixed = 0;
    for (int i = 0; i < 40; ++i) {
        wantPlay.store(true);
        demuxLive.store(0);
        seekGen.store(0);
        const uint64_t g = ++seekGen;
        stop_handler(/*bump=*/true); // bumps gen + clears demux
        {
            std::lock_guard<std::mutex> lock(seekMu);
            if (g != seekGen.load())
                ; // abandoned
            else if (!wantPlay.load())
                ;
            else {
                demuxLive.store(1);
                if (g != seekGen.load() || !wantPlay.load())
                    demuxLive.store(0); // post-check kill
            }
        }
        if (!wantPlay.load() && demuxLive.load())
            ++forced_fixed;
    }
    std::printf("unlocked_persist_after_stop=%d fixed_persist_after_stop=%d\n", unlocked,
                bad_fixed + forced_fixed);
    if (bad_fixed + forced_fixed != 0) {
        std::fprintf(stderr, "FAIL: fixed path left demux live after stop\n");
        return 1;
    }
    if (unlocked == 0) {
        std::fprintf(stderr, "FAIL: unlocked path never persisted — vacuous model\n");
        return 1;
    }
    std::printf("PASS seek/stop model (unlocked_persist=%d, fixed clean)\n", unlocked);
    return 0;
#endif
}
