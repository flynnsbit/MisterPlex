// misterplexd — ARM-side daemon for MiSTerPlex (Phase 0/1 skeleton).
// Later: GDM + companion + demux feed into FPGA.
// Now: health endpoint + status banner so deploy/tests have a process to target.

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

} // namespace

int main(int argc, char** argv) {
    std::string name = "MiSTerPlex";
    int port = 3005;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--name") == 0 && i + 1 < argc)
            name = argv[++i];
        else if (std::strcmp(argv[i], "--port") == 0 && i + 1 < argc)
            port = std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--help") == 0) {
            std::printf("misterplexd [--name NAME] [--port N]\n");
            std::printf("Phase 1: skeleton. Loads with Plex.rbf; full companion in Phase 2.\n");
            return 0;
        }
    }

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    std::fprintf(stderr, "misterplexd: name=%s port=%d phase=1-skeleton\n", name.c_str(), port);
    std::fprintf(stderr, "misterplexd: waiting for Phase 2 companion + native present feed\n");

    // Placeholder: keep process alive for deploy/startup hooks.
    while (!g_stop.load())
        std::this_thread::sleep_for(std::chrono::milliseconds(200));

    std::fprintf(stderr, "misterplexd: exit\n");
    return 0;
}
