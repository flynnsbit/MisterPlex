#include "libmisterplex/a10_present_phase.hpp"
#include <cstdio>

#if MPX_A10_PRESENT_PHASE
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <memory>
#include <new>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

namespace {
using namespace misterplex;
class ReadOnlyPage {
public:
    ReadOnlyPage(int fd, uint32_t address) : base_(address & ~4095u) {
        map_ = ::mmap(nullptr, 4096, PROT_READ, MAP_SHARED, fd, base_);
    }
    ReadOnlyPage(const ReadOnlyPage&) = delete;
    ReadOnlyPage& operator=(const ReadOnlyPage&) = delete;
    ~ReadOnlyPage() { if (map_ != MAP_FAILED) ::munmap(map_, 4096); }
    bool ok() const { return map_ != MAP_FAILED; }
    template<size_t N>
    bool read(uint32_t address, std::array<uint64_t, N>& out) const noexcept {
        if (!ok() || address < base_ || address + N * 8 > base_ + 4096 ||
            address % 8 != 0) return false;
        const volatile uint32_t* p = reinterpret_cast<const volatile uint32_t*>(
            static_cast<const unsigned char*>(map_) + address - base_);
        auto load = [&](size_t i) { const auto lo = p[2*i]; const auto hi = p[2*i+1];
            return uint64_t(lo) | (uint64_t(hi) << 32); };
        for (size_t i = 0; i < N; ++i) out[i] = load(i);
        __sync_synchronize();
        for (size_t i = 0; i < N; ++i) if (out[i] != load(i)) return false;
        return true; // A bounded equality check, not a cross-mailbox atomic snapshot.
    }
private:
    uint32_t base_;
    void* map_ = MAP_FAILED;
};
int64_t mono() {
    timespec t{};
    if (::clock_gettime(CLOCK_MONOTONIC, &t)) return -1;
    return int64_t(t.tv_sec)*1000000 + t.tv_nsec/1000;
}
void field(uint64_t value, bool valid) {
    if (valid) std::printf(",%llu", static_cast<unsigned long long>(value));
    else std::fputs(",u", stdout);
}
}

int main(int argc, char** argv) {
    // This source is not yet approved to run on hardware. A future explicit
    // grant must wrap it in fresh current-pair and held-capture ownership gates.
    if (argc != 2) { std::fputs("Expected bounded seconds 1..60\n", stderr); return 2; }
    char* end = nullptr;
    const long seconds = std::strtol(argv[1], &end, 10);
    if (!end || *end || seconds < 1 || seconds > 60) return 2;
    const int fd = ::open("/dev/mem", O_RDONLY | O_SYNC | O_CLOEXEC);
    if (fd < 0) { std::fputs("Read-only mapping unavailable\n", stderr); return 2; }
    ReadOnlyPage bank(fd, a10_phase::kBankAddress);
    ReadOnlyPage feedback(fd, mailbox_abi::kVideoCapsAddr);
    ::close(fd);
    if (!bank.ok() || !feedback.ok()) return 2;
    std::array<uint64_t, 8> initial{};
    ddr_bitstream_ring::VideoCapabilities initialCaps;
    if (!feedback.read(mailbox_abi::kVideoCapsAddr, initial) ||
        !ddr_bitstream_ring::decodeVideoCapabilities(initial,
            (initial[5] >> 32) | (initial[6] & 0xffffffff00000000ULL), initialCaps) ||
        !initialCaps.supportsVideo() || initialCaps.build_id != a10_phase::kBuild) {
        std::fputs("Expected a10 capability tuple unavailable\n", stderr);
        return 2;
    }
    std::unique_ptr<a10_phase::Collector<>> collector(new (std::nothrow) a10_phase::Collector<>());
    if (!collector) { std::fputs("Observer storage unavailable\n", stderr); return 2; }
    a10_phase::Observer observer;
    std::fprintf(stderr, "A10_PHASE_ARMED build=390fd76b read_only=1 seconds=%ld\n", seconds);
    const int64_t start = mono();
    if (start < 0) return 2;
    const int64_t deadline = start + seconds*1000000;
    while (true) {
        const int64_t before = mono();
        if (before < 0) return 2;
        if (before >= deadline) break;
        a10_phase::Input in;
        std::array<uint64_t, 8> caps{}, mast{};
        std::array<uint64_t, 9> picture{};
        std::array<uint64_t, 1> banks{}, frame{};
        if (feedback.read(mailbox_abi::kVideoCapsAddr, caps)) {
            const auto observedNonce = (caps[5] >> 32) | (caps[6] & 0xffffffff00000000ULL);
            in.capsRead = ddr_bitstream_ring::decodeVideoCapabilities(caps, observedNonce, in.caps);
        }
        in.bankRead = bank.read(a10_phase::kBankAddress, banks) &&
            decodeBankReleaseWord(banks[0], in.bank);
        in.frameRead = bank.read(a10_phase::kFrameAddress, frame) &&
            decodeFrameStoreStatusWord(frame[0], in.frame);
        in.mastRead = feedback.read(mailbox_abi::kAudioStatusAddr, mast) &&
            audio_session::decodeStatus(mast, in.mast);
        in.mvpsRead = in.capsRead && in.mastRead &&
            feedback.read(mailbox_abi::kVideoPresentationAddr, picture) &&
            ddr_bitstream_ring::decodeVideoPresentation(picture, in.mast.session_id, in.caps.nonce, in.mvps);
        const int64_t after = mono();
        if (after < before) return 2;
        collector->add(observer.sample(in, before, after));
        ::usleep(1000);
    }
    // Polling has stopped. No per-record allocation/formatting/I/O in the loop.
    static char outputBuffer[65536];
    std::setvbuf(stdout, outputBuffer, _IOFBF, sizeof(outputBuffer));
    std::printf("A10_PHASE_BEGIN version=1 build=390fd76b source=readonly capacity=%zu attempted=%llu retained=%llu sampled=%llu dropped=%llu\n",
        a10_phase::kCapacity, (unsigned long long)collector->attempted,
        (unsigned long long)collector->retained, (unsigned long long)collector->sampledOut,
        (unsigned long long)collector->dropped);
    for (size_t n = 0; n < collector->retained; ++n) {
        const auto& r = collector->records[n];
        std::printf("%lld,%lld,%u", (long long)r.beforeUs, (long long)r.afterUs, r.valid);
        field(r.session, r.valid & a10_phase::Mast); field(r.nonce, r.valid & a10_phase::Caps);
        field(r.refreshCount, r.valid & a10_phase::Bank); field(r.bankBits, r.valid & a10_phase::Bank);
        field(r.presentationCount, r.valid & a10_phase::Mvps);
        field(r.auSequence, r.valid & a10_phase::Mvps);
        field(r.presentationPublication, r.valid & a10_phase::Mvps);
        if (r.valid & a10_phase::Mvps) std::printf(",%lld", (long long)r.originalPts);
        else std::fputs(",u", stdout);
        field(r.timebaseNum, r.valid & a10_phase::Mvps); field(r.timebaseDen, r.valid & a10_phase::Mvps);
        field(r.frozenAtAck, r.valid & a10_phase::FrozenAck);
        field(r.liveConsumed, r.valid & a10_phase::Mast); field(r.mastPublication, r.valid & a10_phase::Mast);
        field(r.audioBits, r.valid & a10_phase::Mast); field(r.audioError, r.valid & a10_phase::Mast);
        field(r.underruns, r.valid & a10_phase::Frame); field(r.frameState, r.valid & a10_phase::Frame);
        std::fputc('\n', stdout);
    }
    std::puts("A10_PHASE_END");
    return std::fflush(stdout) || std::ferror(stdout) ? 1 : 0;
}
#else
int main() { std::puts("A10 presentation-phase sampler disabled at compile time"); }
#endif
