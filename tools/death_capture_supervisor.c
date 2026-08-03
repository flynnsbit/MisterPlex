/*
 * Parent-side death capture for misterplexd (or any child).
 *
 * Survives SIGKILL/OOM of the child: waitpid + last /proc sample + log tail.
 * In-process handlers cannot run for SIGKILL/OOM — this parent is the only
 * reliable path for those classes.
 *
 * Usage:
 *   death_capture_supervisor --once --dir DIR --log CHILDLOG -- \
 *       /path/to/child [args...]
 *
 * Writes:
 *   DIR/death_capture.log     append-only SUPERVISE_EXIT records
 *   DIR/death_events.jsonl    one JSON object per death (machine-readable)
 *   DIR/proc_sample.last      last /proc sample before reaping
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;

static void on_parent_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static void utc_ts(char* buf, size_t n) {
    time_t now = time(NULL);
    struct tm tm;
    gmtime_r(&now, &tm);
    if (n < 21) { if (n) buf[0] = '\0'; return; }
    /* Fixed 20-char ISO UTC + NUL; avoid truncation warnings on small n. */
    (void)snprintf(buf, n, "%04d-%02d-%02dT%02d:%02d:%02dZ",
                   tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min,
                   tm.tm_sec);
}

static int read_file(const char* path, char* out, size_t outn) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, out, outn > 0 ? outn - 1 : 0);
    close(fd);
    if (n < 0) return -1;
    out[n] = '\0';
    /* collapse newlines to spaces for single-line logs */
    for (ssize_t i = 0; i < n; i++) {
        if (out[i] == '\n' || out[i] == '\r') out[i] = ' ';
    }
    return (int)n;
}

static void trim_inplace(char* s) {
    if (!s) return;
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t')) s[--n] = '\0';
    size_t i = 0;
    while (s[i] == ' ' || s[i] == '\t') i++;
    if (i) memmove(s, s + i, strlen(s + i) + 1);
}

/* Extract VmRSS / VmHWM kB from /proc/pid/status text. */
static long parse_kb_field(const char* status, const char* key) {
    const char* r = strstr(status, key);
    if (!r) return -1;
    r += strlen(key);
    while (*r == ' ' || *r == '\t' || *r == ':') r++;
    char* end = NULL;
    long v = strtol(r, &end, 10);
    if (end == r) return -1;
    return v;
}

static void parse_status_mem(const char* status, long* vmrss_kb, long* vmhwm_kb) {
    *vmrss_kb = parse_kb_field(status, "VmRSS:");
    *vmhwm_kb = parse_kb_field(status, "VmHWM:");
}

typedef struct {
    long oom_score;
    long oom_score_adj;
    long vmrss_kb;
    long vmhwm_kb;
    int valid;
    char ts[32];
} ProcSample;

static void sample_proc(pid_t pid, ProcSample* s) {
    memset(s, 0, sizeof(*s));
    s->oom_score = -1;
    s->oom_score_adj = -1;
    s->vmrss_kb = -1;
    s->vmhwm_kb = -1;
    utc_ts(s->ts, sizeof(s->ts));
    char path[128];
    char buf[8192];
    snprintf(path, sizeof(path), "/proc/%d/oom_score", (int)pid);
    if (read_file(path, buf, sizeof(buf)) >= 0) {
        s->oom_score = strtol(buf, NULL, 10);
        s->valid = 1;
    }
    snprintf(path, sizeof(path), "/proc/%d/oom_score_adj", (int)pid);
    if (read_file(path, buf, sizeof(buf)) >= 0) {
        s->oom_score_adj = strtol(buf, NULL, 10);
        s->valid = 1;
    }
    /* Direct open of status — do not depend on read_file first. */
    snprintf(path, sizeof(path), "/proc/%d/status", (int)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n > 0) {
            buf[n] = '\0';
            parse_status_mem(buf, &s->vmrss_kb, &s->vmhwm_kb);
            s->valid = 1;
        }
    }
}

static void write_sample_file(const char* dir, const ProcSample* s, pid_t pid) {
    char path[512];
    snprintf(path, sizeof(path), "%s/proc_sample.last", dir);
    FILE* f = fopen(path, "w");
    if (!f) return;
    fprintf(f,
            "ts=%s pid=%d valid=%d oom_score=%ld oom_score_adj=%ld VmRSS_kB=%ld VmHWM_kB=%ld\n",
            s->ts, (int)pid, s->valid, s->oom_score, s->oom_score_adj, s->vmrss_kb, s->vmhwm_kb);
    fclose(f);
}

static void snap_file(const char* path, char* out, size_t outn) {
    out[0] = '\0';
    if (!path || !path[0]) return;
    if (read_file(path, out, outn) < 0) {
        snprintf(out, outn, "(absent)");
        return;
    }
    trim_inplace(out);
    if (!out[0]) snprintf(out, outn, "(empty)");
}

/* Last ~2 KiB of child log, single-line-ish. */
static void snap_log_tail(const char* logpath, char* out, size_t outn) {
    out[0] = '\0';
    if (!logpath || !logpath[0]) {
        snprintf(out, outn, "(no-child-log)");
        return;
    }
    int fd = open(logpath, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        snprintf(out, outn, "(log-absent)");
        return;
    }
    off_t sz = lseek(fd, 0, SEEK_END);
    if (sz < 0) {
        close(fd);
        snprintf(out, outn, "(log-seek-fail)");
        return;
    }
    const off_t want = 2048;
    off_t start = sz > want ? sz - want : 0;
    if (lseek(fd, start, SEEK_SET) < 0) {
        close(fd);
        snprintf(out, outn, "(log-seek-fail)");
        return;
    }
    size_t cap = outn > 1 ? outn - 1 : 0;
    if (cap > 2048) cap = 2048;
    ssize_t n = read(fd, out, cap);
    close(fd);
    if (n < 0) {
        snprintf(out, outn, "(log-read-fail)");
        return;
    }
    out[n] = '\0';
    for (ssize_t i = 0; i < n; i++) {
        if (out[i] == '\n' || out[i] == '\r') out[i] = '|';
    }
    trim_inplace(out);
    if (!out[0]) snprintf(out, outn, "(log-empty)");
}

static const char* sig_name(int sig) {
    switch (sig) {
    case SIGHUP: return "SIGHUP";
    case SIGINT: return "SIGINT";
    case SIGQUIT: return "SIGQUIT";
    case SIGILL: return "SIGILL";
    case SIGABRT: return "SIGABRT";
    case SIGBUS: return "SIGBUS";
    case SIGFPE: return "SIGFPE";
    case SIGKILL: return "SIGKILL";
    case SIGSEGV: return "SIGSEGV";
    case SIGPIPE: return "SIGPIPE";
    case SIGTERM: return "SIGTERM";
    default: return "SIG_OTHER";
    }
}

static void json_escape(const char* in, char* out, size_t outn) {
    size_t o = 0;
    if (!in) {
        if (outn) out[0] = '\0';
        return;
    }
    for (const unsigned char* p = (const unsigned char*)in; *p && o + 2 < outn; ++p) {
        if (*p == '"' || *p == '\\') {
            if (o + 3 >= outn) break;
            out[o++] = '\\';
            out[o++] = (char)*p;
        } else if (*p < 0x20) {
            out[o++] = ' ';
        } else {
            out[o++] = (char)*p;
        }
    }
    out[o] = '\0';
}

static void emit_record(const char* dir, const char* label, pid_t pid, int status,
                        const ProcSample* last, const char* death_path, const char* last_path,
                        const char* child_log, double uptime_s) {
    char ts[32];
    utc_ts(ts, sizeof(ts));

    int wifexited = WIFEXITED(status);
    int wifsignaled = WIFSIGNALED(status);
    int wifstopped = WIFSTOPPED(status);
    int exit_status = wifexited ? WEXITSTATUS(status) : -1;
    int termsig = wifsignaled ? WTERMSIG(status) : -1;
    int cores = (wifsignaled && WCOREDUMP(status)) ? 1 : 0;

    char death_snap[512];
    char last_snap[512];
    char log_snap[2200];
    snap_file(death_path, death_snap, sizeof(death_snap));
    snap_file(last_path, last_snap, sizeof(last_snap));
    snap_log_tail(child_log, log_snap, sizeof(log_snap));

    /* Stale-death detection: if signaled with SIGKILL, handler cannot run. */
    const char* death_freshness = "n/a";
    if (wifsignaled && termsig == SIGKILL) {
        death_freshness =
            (strstr(death_snap, "death signal=9") != NULL) ? "UNEXPECTED_handler_ran"
                                                           : "stale_or_absent_expected";
    } else if (wifsignaled && termsig != SIGKILL) {
        death_freshness = (death_snap[0] && strcmp(death_snap, "(absent)") != 0 &&
                           strcmp(death_snap, "(empty)") != 0)
                              ? "present"
                              : "absent";
    }

    char line[4096];
    int n = snprintf(
        line, sizeof(line),
        "%s SUPERVISE_EXIT label=%s pid=%d wait_status=0x%x "
        "WIFEXITED=%d WEXITSTATUS=%d WIFSIGNALED=%d WTERMSIG=%d signal_name=%s "
        "WCOREDUMP=%d WIFSTOPPED=%d uptime_s=%.3f "
        "oom_score=%ld oom_score_adj=%ld VmRSS_kB=%ld VmHWM_kB=%ld proc_sample_ts=%s "
        "death_freshness=%s last={%s} death={%s} log_tail={%s}\n",
        ts, label ? label : "-", (int)pid, (unsigned)status, wifexited, exit_status, wifsignaled,
        termsig, wifsignaled ? sig_name(termsig) : "n/a", cores, wifstopped, uptime_s,
        last->oom_score, last->oom_score_adj, last->vmrss_kb, last->vmhwm_kb,
        last->valid ? last->ts : "none", death_freshness, last_snap, death_snap, log_snap);

    char path[512];
    snprintf(path, sizeof(path), "%s/death_capture.log", dir);
    FILE* f = fopen(path, "a");
    if (f) {
        fwrite(line, 1, (size_t)(n > 0 ? n : 0), f);
        fclose(f);
    }
    /* also stdout for prove harness */
    fputs(line, stdout);
    fflush(stdout);

    char je_death[600], je_last[600], je_log[2400];
    json_escape(death_snap, je_death, sizeof(je_death));
    json_escape(last_snap, je_last, sizeof(je_last));
    json_escape(log_snap, je_log, sizeof(je_log));

    snprintf(path, sizeof(path), "%s/death_events.jsonl", dir);
    f = fopen(path, "a");
    if (f) {
        fprintf(f,
                "{\"ts\":\"%s\",\"label\":\"%s\",\"pid\":%d,\"wait_status\":%u,"
                "\"WIFEXITED\":%s,\"WEXITSTATUS\":%d,\"WIFSIGNALED\":%s,\"WTERMSIG\":%d,"
                "\"signal_name\":\"%s\",\"WCOREDUMP\":%s,\"uptime_s\":%.3f,"
                "\"oom_score\":%ld,\"oom_score_adj\":%ld,\"VmRSS_kB\":%ld,\"VmHWM_kB\":%ld,"
                "\"proc_sample_ts\":\"%s\",\"death_freshness\":\"%s\","
                "\"last\":\"%s\",\"death\":\"%s\",\"log_tail\":\"%s\"}\n",
                ts, label ? label : "-", (int)pid, (unsigned)status, wifexited ? "true" : "false",
                exit_status, wifsignaled ? "true" : "false", termsig,
                wifsignaled ? sig_name(termsig) : "n/a", cores ? "true" : "false", uptime_s,
                last->oom_score, last->oom_score_adj, last->vmrss_kb, last->vmhwm_kb,
                last->valid ? last->ts : "none", death_freshness, je_last, je_death, je_log);
        fclose(f);
    }
}

static void usage(const char* argv0) {
    fprintf(stderr,
            "Usage: %s [--once] [--dir DIR] [--log CHILDLOG] [--label L] [--death PATH] "
            "[--last PATH] -- child [args...]\n"
            "  Parent waitpid capture. SIGKILL/OOM of child still yield WTERMSIG/exit + last "
            "proc sample.\n",
            argv0);
}

int main(int argc, char** argv) {
    const char* dir = ".";
    const char* child_log = "";
    const char* label = "run";
    const char* death_path = "";
    const char* last_path = "";
    int once = 0;
    int sep = -1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) {
            sep = i;
            break;
        }
        if (strcmp(argv[i], "--once") == 0) once = 1;
        else if (strcmp(argv[i], "--dir") == 0 && i + 1 < argc) dir = argv[++i];
        else if (strcmp(argv[i], "--log") == 0 && i + 1 < argc) child_log = argv[++i];
        else if (strcmp(argv[i], "--label") == 0 && i + 1 < argc) label = argv[++i];
        else if (strcmp(argv[i], "--death") == 0 && i + 1 < argc) death_path = argv[++i];
        else if (strcmp(argv[i], "--last") == 0 && i + 1 < argc) last_path = argv[++i];
        else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown arg: %s\n", argv[i]);
            usage(argv[0]);
            return 2;
        }
    }
    if (sep < 0 || sep + 1 >= argc) {
        usage(argv[0]);
        return 2;
    }

    if (mkdir(dir, 0755) < 0 && errno != EEXIST) {
        perror("mkdir dir");
        return 1;
    }

    /* default breadcrumb paths under dir */
    char death_buf[512], last_buf[512];
    if (!death_path[0]) {
        snprintf(death_buf, sizeof(death_buf), "%s/misterplexd.death", dir);
        death_path = death_buf;
    }
    if (!last_path[0]) {
        snprintf(last_buf, sizeof(last_buf), "%s/misterplexd.last", dir);
        last_path = last_buf;
    }

    signal(SIGINT, on_parent_signal);
    signal(SIGTERM, on_parent_signal);

    do {
        struct timespec t0;
        clock_gettime(CLOCK_MONOTONIC, &t0);

        pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            return 1;
        }
        if (pid == 0) {
            /* child */
            char** child_argv = &argv[sep + 1];
            execvp(child_argv[0], child_argv);
            perror("execvp");
            _exit(127);
        }

        char ts[32];
        utc_ts(ts, sizeof(ts));
        fprintf(stderr, "%s SUPERVISE_SPAWN label=%s pid=%d\n", ts, label, (int)pid);

        ProcSample last;
        memset(&last, 0, sizeof(last));
        last.oom_score = -1;
        last.oom_score_adj = -1;
        last.vmrss_kb = -1;
        last.vmhwm_kb = -1;

        int status = 0;
        for (;;) {
            if (g_stop) {
                kill(pid, SIGTERM);
            }
            ProcSample cur;
            sample_proc(pid, &cur);
            if (cur.valid) {
                /* Zombies often keep oom_score but drop VmRSS — retain prior mem. */
                if (cur.vmrss_kb < 0 && last.vmrss_kb >= 0) cur.vmrss_kb = last.vmrss_kb;
                if (cur.vmhwm_kb < 0 && last.vmhwm_kb >= 0) cur.vmhwm_kb = last.vmhwm_kb;
                last = cur;
                write_sample_file(dir, &last, pid);
            }

            int wr = waitpid(pid, &status, WNOHANG);
            if (wr == pid) break;
            if (wr < 0) {
                if (errno == EINTR) continue;
                perror("waitpid");
                return 1;
            }
            struct timespec tsleep = {.tv_sec = 0, .tv_nsec = 50 * 1000 * 1000};
            nanosleep(&tsleep, NULL);
        }

        struct timespec t1;
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double up = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;

        emit_record(dir, label, pid, status, &last, death_path, last_path, child_log, up);

        if (once) {
            if (WIFEXITED(status)) return WEXITSTATUS(status);
            if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
            return 1;
        }

        /* backoff 2s between respawns in loop mode */
        sleep(2);
    } while (!g_stop);

    return 0;
}
