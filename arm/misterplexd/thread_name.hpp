// Best-effort pthread name for /proc/self/task/*/comm (15 char limit).
// One prctl at thread entry — not per-frame. Aids death/CPU attribution.
#pragma once

#include <pthread.h>
#include <cstring>

#if defined(__linux__)
#include <sys/prctl.h>
#endif

namespace misterplex {

inline void setThreadName(const char* name) {
    if (!name || !*name)
        return;
#if defined(__linux__)
    char buf[16];
    std::strncpy(buf, name, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    ::prctl(PR_SET_NAME, buf, 0, 0, 0);
#else
    (void)name;
#endif
}

} // namespace misterplex
