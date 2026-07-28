#pragma once

#include <algorithm>
#include <cctype>
#include <string>

#include <sys/wait.h>
#include <unistd.h>

namespace misterplex {

inline std::string actualRbfShortMd5(const std::string& path) {
    int fds[2] = {-1, -1};
    if (path.empty() || pipe(fds) != 0)
        return {};
    const pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return {};
    }
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        close(fds[1]);
        execlp("md5sum", "md5sum", path.c_str(), static_cast<char*>(nullptr));
        _exit(127);
    }
    close(fds[1]);
    char buf[256];
    std::string out;
    for (;;) {
        const ssize_t n = read(fds[0], buf, sizeof(buf));
        if (n <= 0)
            break;
        out.append(buf, static_cast<size_t>(n));
        if (out.size() > 64)
            break;
    }
    close(fds[0]);
    int status = 0;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        return {};
    if (out.size() < 32)
        return {};
    for (size_t i = 0; i < 32; ++i) {
        if (!std::isxdigit(static_cast<unsigned char>(out[i])))
            return {};
    }
    std::string shortMd5 = out.substr(0, 8);
    std::transform(shortMd5.begin(), shortMd5.end(), shortMd5.begin(), [](unsigned char ch) {
        return static_cast<char>(std::toupper(ch));
    });
    return shortMd5;
}

inline std::string rbfIdentityLabelFromFile(const std::string& path) {
    const std::string md5 = actualRbfShortMd5(path);
    return md5.empty() ? std::string{} : "RBF " + md5;
}

} // namespace misterplex
