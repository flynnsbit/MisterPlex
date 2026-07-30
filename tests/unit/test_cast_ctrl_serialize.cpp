// Models Companion ctrlMu_ + MediaPlayer transport: timeline plant and signal
// must be one unit. Without the lock, concurrent pause/play desynchronises.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>

namespace {

std::mutex ctrlMu;
// 0=playing, 1=paused (atomic so torn updates are visible without data race UB)
std::atomic<int> timeline{0};
std::atomic<int> transport{0}; // 0=running, 1=stopped

void pause_body() {
    timeline.store(1, std::memory_order_relaxed);
    // Non-trivial gap (real path: overlay + SIGSTOP) — concurrent resume plants
    // timeline=playing then this still sets transport=stopped → desync.
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    transport.store(1, std::memory_order_relaxed);
}

void resume_body() {
    timeline.store(0, std::memory_order_relaxed);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    transport.store(0, std::memory_order_relaxed);
}

void pause_unlocked() { pause_body(); }
void resume_unlocked() { resume_body(); }

void pause_locked() {
    std::lock_guard<std::mutex> g(ctrlMu);
    pause_body();
}

void resume_locked() {
    std::lock_guard<std::mutex> g(ctrlMu);
    resume_body();
}

bool consistent() {
    return timeline.load(std::memory_order_relaxed) == transport.load(std::memory_order_relaxed);
}

int race_desyncs(bool locked, int rounds) {
    int bad = 0;
    for (int r = 0; r < rounds; ++r) {
        std::atomic<int> go{0};
        auto run = [&](bool pause) {
            while (go.load(std::memory_order_acquire) == 0)
                std::this_thread::yield();
            if (pause) {
                if (locked)
                    pause_locked();
                else
                    pause_unlocked();
            } else {
                if (locked)
                    resume_locked();
                else
                    resume_unlocked();
            }
        };
        std::thread t1(run, true);
        std::thread t2(run, false);
        std::thread t3(run, true);
        std::thread t4(run, false);
        go.store(1, std::memory_order_release);
        t1.join();
        t2.join();
        t3.join();
        t4.join();
        if (!consistent())
            ++bad;
    }
    return bad;
}

} // namespace

int main() {
#ifdef CAST_CTRL_FAULT_NO_SERIALIZE
    const int bad = race_desyncs(/*locked=*/false, 200);
    std::printf("fault_unlocked_inconsistencies=%d\n", bad);
    if (bad == 0) {
        std::fprintf(stderr, "FAIL: unlocked race saw no inconsistency (vacuous)\n");
        return 1;
    }
    std::printf("RED OK: unlocked pause/play desyncs (%d)\n", bad);
    return 0;
#else
    const int bad_unlocked = race_desyncs(/*locked=*/false, 100);
    const int bad_locked = race_desyncs(/*locked=*/true, 200);
    std::printf("unlocked_inconsistencies=%d locked_inconsistencies=%d\n", bad_unlocked,
                bad_locked);
    if (bad_locked != 0) {
        std::fprintf(stderr, "FAIL: locked path still desyncs (%d)\n", bad_locked);
        return 1;
    }
    if (bad_unlocked == 0) {
        std::fprintf(stderr,
                     "FAIL: unlocked path never desynced — model does not discriminate\n");
        return 1;
    }
    pause_locked();
    if (!consistent()) {
        std::fprintf(stderr, "FAIL: final paused inconsistent\n");
        return 1;
    }
    std::printf("PASS ctrl serialize model (unlocked desyncs=%d, locked clean)\n",
                bad_unlocked);
    return 0;
#endif
}
