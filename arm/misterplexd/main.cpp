// misterplexd — ARM-side daemon for MiSTerPlex.
// Phase 2: GDM + companion + FFmpeg → /dev/fb0 (FPGA scanout via MiSTer_fb).

#include "companion.hpp"
#include "media_player.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

namespace {

std::atomic<bool> g_stop{false};
void on_signal(int) { g_stop.store(true); }

// Heuristic: turn playMedia key into something ffmpeg can open.
// Full Plex resolve (token + PMS universal) is next; for now support:
//   - absolute path /media/...
//   - http(s)://...
//   - key starting with /library → needs resolve (placeholder: test pattern)
std::string resolvePlayable(const std::string& keyOrUrl) {
    if (keyOrUrl.empty() || keyOrUrl == "test" || keyOrUrl == "testsrc")
        return {}; // test pattern
    if (keyOrUrl.rfind("http://", 0) == 0 || keyOrUrl.rfind("https://", 0) == 0)
        return keyOrUrl;
    // Local absolute path (not a Plex library key)
    if (keyOrUrl[0] == '/' && keyOrUrl.rfind("/library", 0) != 0 &&
        keyOrUrl.find("%2F") == std::string::npos)
        return keyOrUrl;
    // Plex metadata keys need PMS resolve (Phase 2.1)
    if (keyOrUrl.find("library") != std::string::npos || keyOrUrl.find("%2F") != std::string::npos)
        return {};
    return keyOrUrl;
}

} // namespace

int main(int argc, char** argv) {
    std::string name = "MiSTerPlex";
    std::string machineId = "misterplex-1";
    int port = 3005;
    std::string ffmpeg = "/media/fat/mistercast/bin/ffmpeg";
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--name") == 0 && i + 1 < argc)
            name = argv[++i];
        else if (std::strcmp(argv[i], "--id") == 0 && i + 1 < argc)
            machineId = argv[++i];
        else if (std::strcmp(argv[i], "--port") == 0 && i + 1 < argc)
            port = std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--ffmpeg") == 0 && i + 1 < argc)
            ffmpeg = argv[++i];
        else if (std::strcmp(argv[i], "--help") == 0) {
            std::printf("misterplexd [--name NAME] [--id ID] [--port N] [--ffmpeg PATH]\n");
            return 0;
        }
    }

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    misterplex::MediaPlayer player;
    player.setFfmpegPath(ffmpeg);
    player.setLog([](const std::string& s) { std::fprintf(stderr, "%s\n", s.c_str()); });
    if (!player.initPresent()) {
        std::fprintf(stderr, "misterplexd: WARNING fb present unavailable — companion only\n");
    }

    misterplex::Companion comp;
    comp.setName(name);
    comp.setMachineId(machineId);
    comp.setPort(static_cast<uint16_t>(port));
    comp.setLog([](const std::string& s) { std::fprintf(stderr, "%s\n", s.c_str()); });

    player.setProgress([&](const std::string& st, int64_t t, int64_t d) {
        comp.setState(st, t, d);
    });

    comp.setPlay([&](const std::string& key, int64_t off) {
        std::string playable = resolvePlayable(key);
        if (playable.empty()) {
            // Unresolved Plex key: play a built-in test pattern so cast path is visible
            playable = "testsrc";
            std::fprintf(stderr,
                         "misterplexd: unresolved Plex key=%s — playing test pattern (resolve TBD)\n",
                         key.c_str());
        }
        std::fprintf(stderr, "misterplexd: PLAY %s off=%lld\n", playable.c_str(),
                     static_cast<long long>(off));
        player.play(playable, off);
    });

    // Wire simple pause/stop via companion control — extend companion later
    // (playMedia path already covered)

    if (!comp.start()) {
        std::fprintf(stderr, "misterplexd: companion start failed\n");
        return 1;
    }

    std::fprintf(stderr, "misterplexd: running name=%s id=%s port=%d\n", name.c_str(), machineId.c_str(),
                 port);

    while (!g_stop.load())
        std::this_thread::sleep_for(std::chrono::milliseconds(200));

    player.stop();
    comp.stop();
    return 0;
}
