// Host unit test: crashDumpWriteNow emits required fields without raising.
#include "crash_dump.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <unistd.h>

static void die(const char* msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    std::exit(1);
}

int main() {
    const char* path = "build/crash_dump_unit.out";
    ::unlink(path);
    int fd = ::open(path, O_CREAT | O_TRUNC | O_RDWR | O_CLOEXEC, 0644);
    if (fd < 0)
        die("open out");

    misterplex::crashDumpInit(fd);
    misterplex::crashDumpNoteKey("/library/metadata/42", "42");
    misterplex::crashDumpWriteNow(11, reinterpret_cast<void*>(0xdeadbeefUL));

    if (::lseek(fd, 0, SEEK_SET) < 0)
        die("lseek");
    char buf[8192];
    ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    ::close(fd);
    if (n <= 0)
        die("empty dump");
    buf[n] = 0;
    std::string s(buf);

    auto need = [&](const char* frag) {
        if (s.find(frag) == std::string::npos) {
            std::fprintf(stderr, "missing %s in:\n%s\n", frag, buf);
            die("missing field");
        }
    };
    need("===== misterplexd FATAL =====");
    need("signal=11");
    need("si_addr=0xdeadbeef");
    need("tid=");
    need("load_base=0x");
    need("context=key=/library/metadata/42 session=42");
    need("raw_frames:");
    need("symbols");
    need("===== end FATAL =====");

    std::printf("PASS test_crash_dump\n");
    return 0;
}
