/*
 * Host-side victim for proving death_capture_supervisor.
 * Installs SA_SIGINFO handlers that write the same style death file as the daemon.
 *
 * Modes (argv[1]):
 *   exit [code]     — clean exit (default code 0)
 *   term            — raise SIGTERM (handler records then _exit 0 like daemon)
 *   segv            — deliberate NULL deref → SIGSEGV
 *   sleep           — sleep forever (for external SIGKILL/SIGTERM)
 *   arm-handlers    — install handlers then sleep (default if sleep)
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char g_death_path[512] = "misterplexd.death";
static char g_last_path[512] = "misterplexd.last";

static void as_append(char* buf, size_t cap, size_t* o, const char* s) {
    while (s && *s && *o + 1 < cap) buf[(*o)++] = *s++;
}
static void as_int(char* buf, size_t cap, size_t* o, long v) {
    if (v < 0) {
        if (*o + 1 < cap) buf[(*o)++] = '-';
        v = -v;
    }
    char t[24];
    int n = 0;
    if (v == 0) t[n++] = '0';
    while (v > 0 && n < (int)sizeof(t)) {
        t[n++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (n > 0 && *o + 1 < cap) buf[(*o)++] = t[--n];
}
static void as_hex(char* buf, size_t cap, size_t* o, unsigned long v) {
    as_append(buf, cap, o, "0x");
    int started = 0;
    for (int shift = (int)sizeof(void*) * 8 - 4; shift >= 0; shift -= 4) {
        unsigned nib = (unsigned)((v >> shift) & 0xfu);
        if (!started && nib == 0 && shift > 0) continue;
        started = 1;
        if (*o + 1 < cap)
            buf[(*o)++] = (char)(nib < 10 ? '0' + nib : 'a' + (nib - 10));
    }
    if (!started && *o + 1 < cap) buf[(*o)++] = '0';
}

static void write_last(const char* state) {
    int fd = open(g_last_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    char line[256];
    int n = snprintf(line, sizeof(line), "ts=victim state=%s frames=0 presents=0 pos_ms=0 uptime_s=0 pid=%d\n",
                     state, (int)getpid());
    if (n > 0) (void)write(fd, line, (size_t)n);
    close(fd);
}

static void write_death_info(siginfo_t* info) {
    int fd = open(g_death_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    char buf[256];
    size_t o = 0;
    as_append(buf, sizeof(buf), &o, "death signal=");
    as_int(buf, sizeof(buf), &o, info ? info->si_signo : -1);
    as_append(buf, sizeof(buf), &o, " si_code=");
    as_int(buf, sizeof(buf), &o, info ? info->si_code : 0);
    as_append(buf, sizeof(buf), &o, " si_pid=");
    as_int(buf, sizeof(buf), &o, info ? (long)info->si_pid : 0);
    as_append(buf, sizeof(buf), &o, " si_addr=");
    as_hex(buf, sizeof(buf), &o,
           info ? (unsigned long)(uintptr_t)info->si_addr : 0ul);
    as_append(buf, sizeof(buf), &o, " state=1 pid=");
    as_int(buf, sizeof(buf), &o, (long)getpid());
    as_append(buf, sizeof(buf), &o, "\n");
    (void)write(fd, buf, o);
    close(fd);
}

static void on_crash(int sig, siginfo_t* info, void* uctx) {
    (void)uctx;
    (void)sig;
    write_death_info(info);
    /* restore default and re-raise so parent sees WIFSIGNALED */
    signal(sig, SIG_DFL);
    raise(sig);
}

static void on_term(int sig, siginfo_t* info, void* uctx) {
    (void)uctx;
    (void)sig;
    /* daemon-like: record orderly-ish exit note and exit 0 */
    int fd = open(g_death_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd >= 0) {
        char line[256];
        int n = snprintf(line, sizeof(line),
                         "ts=victim exit_code=0 why=signal-g_stop si_signo=%d si_code=%d si_pid=%d "
                         "state=idle pid=%d\n",
                         info ? info->si_signo : SIGTERM, info ? info->si_code : 0,
                         info ? (int)info->si_pid : 0, (int)getpid());
        if (n > 0) (void)write(fd, line, (size_t)n);
        close(fd);
    }
    _exit(0);
}

static void install_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = on_crash;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
    sigaction(SIGQUIT, &sa, NULL);

    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = on_term;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGTERM, &sa, NULL);
}

int main(int argc, char** argv) {
    const char* mode = "sleep";
    int exit_code = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--death") == 0 && i + 1 < argc) {
            snprintf(g_death_path, sizeof(g_death_path), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--last") == 0 && i + 1 < argc) {
            snprintf(g_last_path, sizeof(g_last_path), "%s", argv[++i]);
        } else if (strcmp(argv[i], "exit") == 0) {
            mode = "exit";
            if (i + 1 < argc && argv[i + 1][0] >= '0' && argv[i + 1][0] <= '9')
                exit_code = atoi(argv[++i]);
        } else if (strcmp(argv[i], "term") == 0 || strcmp(argv[i], "segv") == 0 ||
                   strcmp(argv[i], "sleep") == 0) {
            mode = argv[i];
        }
    }

    install_handlers();
    write_last(mode);
    fprintf(stderr, "victim ready mode=%s pid=%d death=%s\n", mode, (int)getpid(), g_death_path);
    fflush(stderr);

    if (strcmp(mode, "exit") == 0) {
        int fd = open(g_death_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd >= 0) {
            char line[256];
            int n = snprintf(line, sizeof(line),
                             "ts=victim exit_code=%d why=clean-exit state=idle pid=%d\n", exit_code,
                             (int)getpid());
            if (n > 0) (void)write(fd, line, (size_t)n);
            close(fd);
        }
        return exit_code;
    }
    if (strcmp(mode, "term") == 0) {
        raise(SIGTERM);
        /* on_term _exit(0) */
        return 0;
    }
    if (strcmp(mode, "segv") == 0) {
        volatile int* p = (volatile int*)0;
        *p = 42; /* SIGSEGV */
        return 1;
    }
    /* sleep forever — external kill */
    for (;;) pause();
    return 0;
}
