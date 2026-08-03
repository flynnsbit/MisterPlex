// Route A falsifier proxy (w-path): drain rawvideo frames from CMD stdout and
// write each frame either to ordinary RAM or to a /dev/mem bank phys.
//
// This does NOT implement ffmpeg get_buffer2 into the bank (ref frames would
// also live uncached — likely worse). It bounds the *output store* cost of
// landing decoded pixels on the uncached bank vs RAM.
//
// Parent:
//   route_a_bank_probe --frames 300 --sink ram  -- ffmpeg ... -f rawvideo ...
//   route_a_bank_probe --frames 300 --sink bank --bank-phys 0x30300000 -- ffmpeg ...
//
// PRE: bank sink wall_ms/f >= ram + ~10 ms if uncached store dominates;
//      if bank ≈ ram, hypothesis weak (unexpected).

#include "libmisterplex/ddr_frame_layout.hpp"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace {

double nowSec() {
    using C = std::chrono::steady_clock;
    return std::chrono::duration<double>(C::now().time_since_epoch()).count();
}

} // namespace

int main(int argc, char** argv) {
    int frames = 300;
    size_t frame_bytes = static_cast<size_t>(misterplex::kPlex720pYuv420pBytes);
    std::string sink = "ram";
    uint32_t bank_phys = misterplex::kPlex720pDdrFramePhysBase +
                         misterplex::kPlex720pYuv420pBankStride; // bank1
    int cmd_i = -1;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--") {
            cmd_i = i + 1;
            break;
        } else if (a == "--frames" && i + 1 < argc)
            frames = std::atoi(argv[++i]);
        else if (a == "--frame-bytes" && i + 1 < argc)
            frame_bytes = static_cast<size_t>(std::strtoull(argv[++i], nullptr, 0));
        else if (a == "--sink" && i + 1 < argc)
            sink = argv[++i];
        else if (a == "--bank-phys" && i + 1 < argc)
            bank_phys = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 0));
        else if (a == "--help") {
            std::printf("route_a_bank_probe --sink ram|bank [--bank-phys 0x..] "
                        "[--frames N] -- CMD...\n");
            return 0;
        }
    }
    if (cmd_i < 0 || cmd_i >= argc || frames < 1 || frame_bytes < 64) {
        std::fprintf(stderr, "bad args (need -- CMD)\n");
        return 2;
    }

    uint8_t* dst = nullptr;
    std::vector<uint8_t> ram;
    int memfd = -1;
    void* map = MAP_FAILED;
    size_t map_len = 0;
    uint32_t map_base = 0;

    if (sink == "ram") {
        ram.resize(frame_bytes);
        dst = ram.data();
    } else if (sink == "bank") {
        memfd = ::open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
        if (memfd < 0) {
            std::perror("open /dev/mem");
            return 1;
        }
        map_base = bank_phys & ~0xFFFu;
        map_len = ((bank_phys - map_base) + frame_bytes + 0xFFFu) & ~static_cast<size_t>(0xFFFu);
        map = ::mmap(nullptr, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, memfd,
                     static_cast<off_t>(map_base));
        if (map == MAP_FAILED) {
            std::perror("mmap bank");
            return 1;
        }
        dst = static_cast<uint8_t*>(map) + (bank_phys - map_base);
    } else {
        std::fprintf(stderr, "sink must be ram|bank\n");
        return 2;
    }

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        std::perror("pipe");
        return 1;
    }
    const pid_t pid = fork();
    if (pid < 0) {
        std::perror("fork");
        return 1;
    }
    if (pid == 0) {
        ::dup2(pipefd[1], STDOUT_FILENO);
        ::close(pipefd[0]);
        ::close(pipefd[1]);
        execvp(argv[cmd_i], &argv[cmd_i]);
        std::perror("execvp");
        _exit(127);
    }
    ::close(pipefd[1]);

    std::vector<uint8_t> buf(frame_bytes);
    int got = 0;
    size_t off = 0;
    const double t0 = nowSec();
    double copy_s = 0;
    while (got < frames) {
        const ssize_t n = ::read(pipefd[0], buf.data() + off, frame_bytes - off);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            std::perror("read");
            break;
        }
        if (n == 0)
            break;
        off += static_cast<size_t>(n);
        if (off < frame_bytes)
            continue;
        const double c0 = nowSec();
        std::memcpy(dst, buf.data(), frame_bytes);
        __sync_synchronize();
        copy_s += nowSec() - c0;
        off = 0;
        ++got;
    }
    const double wall = nowSec() - t0;
    ::close(pipefd[0]);
    int st = 0;
    waitpid(pid, &st, 0);

    if (map != MAP_FAILED)
        ::munmap(map, map_len);
    if (memfd >= 0)
        ::close(memfd);

    const double ms = got > 0 ? (wall * 1000.0 / got) : -1;
    const double copy_ms = got > 0 ? (copy_s * 1000.0 / got) : -1;
    std::printf("route_a_bank_probe sink=%s bank_phys=0x%08x frames=%d frame_bytes=%zu\n",
                sink.c_str(), bank_phys, got, frame_bytes);
    std::printf("wall_ms_per_frame=%.3f copy_only_ms_per_frame=%.3f wall_s=%.3f\n", ms, copy_ms,
                wall);
    std::printf("NOTE: proxy output-store only; true DecodeIntoBank refs also uncached\n");
    std::printf("route_a_bank_probe: DONE true_rc=%d\n", got >= frames ? 0 : 1);
    return got >= frames ? 0 : 1;
}
