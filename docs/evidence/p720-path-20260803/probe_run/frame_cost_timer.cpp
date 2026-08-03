// Per-frame wall timer for ffmpeg rawvideo/null paths. Build-host only.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <algorithm>
#include <cmath>

using clk = std::chrono::steady_clock;

static double pct(std::vector<double>& v, double p) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    double idx = (p/100.0) * (v.size()-1);
    size_t i = (size_t)idx;
    double f = idx - i;
    if (i+1 < v.size()) return v[i]*(1-f) + v[i+1]*f;
    return v.back();
}

int main(int argc, char** argv) {
    // frame_cost_timer --label L --frame-bytes N --frames M -- [-- ffmpeg...]
    const char* label = "run";
    size_t frameBytes = 0;
    int maxFrames = 360;
    int argi = 1;
    while (argi < argc) {
        if (!strcmp(argv[argi], "--label") && argi+1 < argc) { label = argv[++argi]; ++argi; continue; }
        if (!strcmp(argv[argi], "--frame-bytes") && argi+1 < argc) { frameBytes = (size_t)atoll(argv[++argi]); ++argi; continue; }
        if (!strcmp(argv[argi], "--frames") && argi+1 < argc) { maxFrames = atoi(argv[++argi]); ++argi; continue; }
        if (!strcmp(argv[argi], "--")) { ++argi; break; }
        fprintf(stderr, "unknown %s\n", argv[argi]); return 2;
    }
    if (argi >= argc) { fprintf(stderr, "need cmd\n"); return 2; }

    int pfd[2];
    if (frameBytes > 0) {
        if (pipe(pfd) != 0) { perror("pipe"); return 1; }
#ifdef F_SETPIPE_SZ
        (void)fcntl(pfd[0], F_SETPIPE_SZ, 2*1024*1024);
#endif
    }

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 1; }
    if (pid == 0) {
        if (frameBytes > 0) {
            dup2(pfd[1], 1);
            close(pfd[0]); close(pfd[1]);
        } else {
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) { dup2(devnull, 1); close(devnull); }
        }
        int err = open("/dev/null", O_WRONLY);
        if (err >= 0) { dup2(err, 2); close(err); }
        execvp(argv[argi], argv+argi);
        _exit(127);
    }
    if (frameBytes > 0) close(pfd[1]);

    std::vector<double> dt_ms;
    dt_ms.reserve(maxFrames);
    auto t0 = clk::now();
    auto prev = t0;
    int frames = 0;

    if (frameBytes == 0) {
        // null sink: wait only — no per-frame (child writes nowhere useful)
        int st=0; waitpid(pid, &st, 0);
        auto t1 = clk::now();
        double wall = std::chrono::duration<double,std::milli>(t1-t0).count();
        printf("frame_timer label=%s mode=null_wait frames=0 wall_ms=%.3f child_exit=%d\n",
               label, wall, st);
        return 0;
    }

    std::vector<uint8_t> buf(frameBytes);
    while (frames < maxFrames) {
        size_t got = 0;
        while (got < frameBytes) {
            ssize_t n = read(pfd[0], buf.data()+got, frameBytes-got);
            if (n < 0) { if (errno==EINTR) continue; break; }
            if (n == 0) break;
            got += (size_t)n;
        }
        if (got < frameBytes) break;
        auto now = clk::now();
        double d = std::chrono::duration<double,std::milli>(now-prev).count();
        prev = now;
        dt_ms.push_back(d);
        frames++;
    }
    close(pfd[0]);
    int st=0; waitpid(pid, &st, 0);
    auto t1 = clk::now();
    double wall = std::chrono::duration<double,std::milli>(t1-t0).count();

    if (dt_ms.empty()) {
        printf("frame_timer label=%s mode=raw frames=0 wall_ms=%.3f FAIL\n", label, wall);
        return 1;
    }
    // drop first frame (startup)
    std::vector<double> body(dt_ms.begin()+ (dt_ms.size()>1?1:0), dt_ms.end());
    double sum=0; for (double x: body) sum+=x;
    double mean = sum/body.size();
    auto body2 = body;
    double p50=pct(body2,50), p95=pct(body2,95), p99=pct(body2,99);
    double mx = *std::max_element(body.begin(), body.end());
    double mn = *std::min_element(body.begin(), body.end());
    // stdev
    double var=0; for (double x: body) var+=(x-mean)*(x-mean);
    double sd = std::sqrt(var/body.size());

    // Mark spikes: frames where dt > mean+2*sd, and map to keyframe positions if known
    int spikes=0;
    for (double x: body) if (x > mean + 2*sd) spikes++;

    printf("frame_timer label=%s mode=raw n=%zu mean_ms=%.4f p50=%.4f p95=%.4f p99=%.4f max=%.4f min=%.4f sd=%.4f "
           "p99_minus_mean=%.4f spikes_gt_mean+2sd=%d wall_ms=%.3f child_st=%d\n",
           label, body.size(), mean, p50, p95, p99, mx, mn, sd, p99-mean, spikes, wall, st);

    // dump first 20 and top 10 slowest indices for IDR correlation
    std::vector<std::pair<double,int>> ord;
    for (size_t i=0;i<body.size();++i) ord.push_back({body[i], (int)i+1}); // +1 skip startup → frame index in file approx
    std::sort(ord.begin(), ord.end(), [](auto&a,auto&b){return a.first>b.first;});
    printf("frame_timer_slowest label=%s", label);
    for (int k=0;k<10 && k<(int)ord.size();++k)
        printf(" idx=%d:%.3f", ord[k].second, ord[k].first);
    printf("\n");
    return 0;
}
