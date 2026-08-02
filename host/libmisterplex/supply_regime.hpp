// Supply REGIME: separate "path cannot deliver" from "we are not pulling".
//
// Parent hardware (2026-08-02): supply_ratio alone is ambiguous.
//   Solo cast:     ~47 KB/s on the media path, supply_ratio ~0.63, path ceiling ~108 KB/s
//   + concurrent bulk pull on same path: +60.6 KB/s → total ~107.6 KB/s (= ceiling)
// So low supply_ratio does NOT prove the network is the bottleneck — we may be
// the limiter (back-pressure / slow consumer).
//
// What the daemon can observe WITHOUT root / extra privilege
// ----------------------------------------------------------
// CAN (product, no root):
//   1) pipe_bytes = cumulative ::read() from ffmpeg rawvideo stdout (totalBytes).
//      Interval rate pipe_Bps = d_pipe_bytes / d_wall_s.
//      This is POST-DECODE frame bytes into the present loop — NOT HTTP octets
//      on the wire. Tag: measured, src=rawvideo_stdout_read.
//   2) FIONREAD on the rawvideo read fd + F_GETPIPE_SZ capacity.
//      fill = avail / capacity. Empty ⇒ we are waiting on producer (not
//      back-pressuring). Persistently full ⇒ our reader/pacer is the brake.
//      Tag: measured, src=FIONREAD_and_F_GETPIPE_SZ. No root required.
//   3) Optional: /proc/<ffmpeg_pid>/io rchar — process-level read() byte count
//      for the child we spawned. Approximates media+container ingress into
//      ffmpeg, still not TCP-level and not path capacity. Best-effort; NO-DATA
//      if unreadable.
//
// CANNOT (without external instrument / root / peer process):
//   - Path capacity / other flows' share (parent bulk-pull proved ceiling)
//   - TCP Recv-Q on ffmpeg's HTTP socket from outside that process without
//     parsing /proc/net + fd inodes (fragile; owned by w-cpu-1 RCA, not here)
//   - Whether PMS is rate-limiting vs link saturation vs our pull rate
//
// Read chain (quote media_player.cpp present loop):
//   rfd is O_NONBLOCK after open.
//   while (got < frameBytes):
//     n = ::read(rfd, ...)           // EAGAIN → sleep 2ms, retry (NOT a block on pipe write)
//   then avDecide(drift, lead, drop):
//     Hold → sleep 2ms, re-eval     // pacer wait — delays next read → CAN fill pipe
//     Drop → skip presentCleanFrame
//     else presentCleanFrame(...)   // DDR publish under presentMu_ — CAN stall reads
//   So a block that back-pressures ffmpeg is NOT inside read() (NONBLOCK); it is
//   the time spent in Hold/Drop/present between full-frame reads. FIONREAD high
//   means ffmpeg wrote faster than that loop drained.
//
// Counters (correct reset sites — parent citation fix):
//   droppedFrames_.store(0)  @ media_player.cpp play-path :3009 (NOT :2312)
//   publishMisses_.store(0)  @ media_player.cpp play-path :3010 (NOT :2432)
//   drops = pacer Drop only; publish_misses = DDR/FPGA publish fail — SEPARATE.
//
// Rule 0: missing probe → NO-DATA, never 0.0 / never empty=healthy.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

// Parent anchors (fixtures for red-before-green; tag=caller_supplied in tests):
//   path-starved byte rate ~ 47e3 B/s with supply_ratio ~0.63
//   path ceiling ~ 108e3 B/s (solo+bulk)
//   healthy supply_ratio ~0.99
//
// Pipe fill thresholds (DEFAULT_ASSUMED — configurable via args in tests):
//   empty: fill_peak < 0.10  → not back-pressuring (waiting on producer)
//   full:  fill_peak >= 0.80 → back-pressuring (reader slow vs producer)
// Mid band is AMBIGUOUS — do not invent a third fault.
inline constexpr double kDefaultPipeFillEmptyMax = 0.10;
inline constexpr double kDefaultPipeFillFullMin = 0.80;

// Minimum d_wall_s for regime classification (same spirit as supply_ratio).
inline constexpr double kRegimeMinDWallS = 0.40;

// supply_ratio submitted-vs-played bias (document, do not hide):
//   audio_s uses audioBytes_ (submitted to MrAudio), NOT audibleClockMs
//   (written - queued). Ring depth ≤ ~512 KiB ≈ 2.67 s of PCM. Interval bias
//   equals -Δqueued/(48000*4). Over a 1.0 s log tick a 100 ms ring swing moves
//   ratio by ~0.10. Minimum trustworthy SINGLE interval for hard starved calls
//   when only submitted audio is available: prefer d_wall_s >= 3.0 s, or require
//   N consecutive 1 s starved ticks. Cumulative over ≥10 s dilutes ring swing.
inline constexpr double kSupplyRatioMinTrustWallS = 3.0;

enum class SupplyRegimeClass {
    NoData = 0,
    Ok = 1,
    StarvedByPath = 2,          // low supply, pipe empty/low → waiting on source
    StarvedByBackpressure = 3,  // low supply, pipe full → we are the brake
    StarvedAmbiguous = 4,       // low supply, fill mid / probes missing
};

inline const char* supplyRegimeClassStr(SupplyRegimeClass c) {
    switch (c) {
    case SupplyRegimeClass::Ok:
        return "ok";
    case SupplyRegimeClass::StarvedByPath:
        return "starved_by_path";
    case SupplyRegimeClass::StarvedByBackpressure:
        return "starved_by_backpressure";
    case SupplyRegimeClass::StarvedAmbiguous:
        return "starved_ambiguous";
    case SupplyRegimeClass::NoData:
    default:
        return "NO-DATA";
    }
}

struct SupplyRegimeInput {
    // supply_ratio interval result
    bool supply_interval_ok = false;
    double supply_ratio = 0.0; // valid iff supply_interval_ok
    bool supply_starved = false;

    // pipe bytes (rawvideo stdout cumulative at endpoints)
    bool prev_pipe_valid = false;
    int64_t prev_pipe_bytes = 0;
    int64_t pipe_bytes = 0;
    double d_wall_s = 0.0;

    // FIONREAD / capacity — use NO-DATA sentinels, never fake 0
    bool fionread_ok = false;     // false → avail unknown
    int pipe_avail_bytes = -1;    // last sample
    int pipe_avail_peak_bytes = -1; // max over interval; -1 unknown
    bool capacity_ok = false;
    int pipe_capacity_bytes = -1; // F_GETPIPE_SZ; -1 unknown

    double fill_empty_max = kDefaultPipeFillEmptyMax;
    double fill_full_min = kDefaultPipeFillFullMin;
};

struct SupplyRegimeResult {
    bool established = false;
    SupplyRegimeClass cls = SupplyRegimeClass::NoData;
    const char* class_str = "NO-DATA";
    const char* reason = "unset";

    bool pipe_rate_ok = false;
    double pipe_Bps = 0.0; // d_pipe_bytes / d_wall_s
    int64_t d_pipe_bytes = 0;

    bool fill_ok = false;
    double fill_peak = 0.0; // peak_avail / capacity
    int pipe_avail_peak_bytes = -1;
    int pipe_capacity_bytes = -1;

    double supply_ratio = 0.0;
    bool supply_starved = false;
};

inline SupplyRegimeResult computeSupplyRegime(const SupplyRegimeInput& in) {
    SupplyRegimeResult r;
    r.supply_ratio = in.supply_ratio;
    r.supply_starved = in.supply_starved;
    r.pipe_avail_peak_bytes = in.pipe_avail_peak_bytes;
    r.pipe_capacity_bytes = in.pipe_capacity_bytes;

    if (!(in.d_wall_s >= kRegimeMinDWallS) || !std::isfinite(in.d_wall_s)) {
        r.reason = "d_wall_le0";
        return r;
    }
    if (!in.supply_interval_ok) {
        r.reason = "supply_ratio_NO-DATA";
        return r;
    }

    // Pipe delivery rate (always computable if prev valid).
    if (in.prev_pipe_valid && in.pipe_bytes >= in.prev_pipe_bytes) {
        r.d_pipe_bytes = in.pipe_bytes - in.prev_pipe_bytes;
        r.pipe_Bps = static_cast<double>(r.d_pipe_bytes) / in.d_wall_s;
        r.pipe_rate_ok = true;
    } else if (in.prev_pipe_valid && in.pipe_bytes < in.prev_pipe_bytes) {
        r.reason = "pipe_bytes_reset";
        // still may classify from fill + supply if available
    }

    // Fill fraction from peak FIONREAD.
    if (in.fionread_ok && in.capacity_ok && in.pipe_capacity_bytes > 0 &&
        in.pipe_avail_peak_bytes >= 0) {
        r.fill_peak = static_cast<double>(in.pipe_avail_peak_bytes) /
                      static_cast<double>(in.pipe_capacity_bytes);
        if (r.fill_peak > 1.0)
            r.fill_peak = 1.0;
        r.fill_ok = true;
    }

    r.established = true;

    if (!in.supply_starved) {
        r.cls = SupplyRegimeClass::Ok;
        r.reason = "supply_ok";
        r.class_str = supplyRegimeClassStr(r.cls);
        return r;
    }

    // supply starved — localise with fill if possible
    if (!r.fill_ok) {
        r.cls = SupplyRegimeClass::StarvedAmbiguous;
        r.reason = "starved_fill_NO-DATA";
        r.class_str = supplyRegimeClassStr(r.cls);
        return r;
    }
    if (r.fill_peak < in.fill_empty_max) {
        r.cls = SupplyRegimeClass::StarvedByPath;
        r.reason = "starved_pipe_empty";
        r.class_str = supplyRegimeClassStr(r.cls);
        return r;
    }
    if (r.fill_peak >= in.fill_full_min) {
        r.cls = SupplyRegimeClass::StarvedByBackpressure;
        r.reason = "starved_pipe_full";
        r.class_str = supplyRegimeClassStr(r.cls);
        return r;
    }
    r.cls = SupplyRegimeClass::StarvedAmbiguous;
    r.reason = "starved_fill_mid";
    r.class_str = supplyRegimeClassStr(r.cls);
    return r;
}

// Gate rc for host red-before-green / parent scorers.
//   0 = ok
//   2 = starved_by_path
//   3 = starved_by_backpressure
//   4 = starved_ambiguous (still a positive starved detection — hard, not 77)
//  77 = NO-DATA
inline int supplyRegimeGateRc(const SupplyRegimeResult& r) {
    if (!r.established || r.cls == SupplyRegimeClass::NoData)
        return 77;
    switch (r.cls) {
    case SupplyRegimeClass::Ok:
        return 0;
    case SupplyRegimeClass::StarvedByPath:
        return 2;
    case SupplyRegimeClass::StarvedByBackpressure:
        return 3;
    case SupplyRegimeClass::StarvedAmbiguous:
        return 4;
    default:
        return 77;
    }
}

inline std::string formatSupplyRegimeFragment(const SupplyRegimeResult& r) {
    char pipeRate[48];
    if (r.pipe_rate_ok)
        std::snprintf(pipeRate, sizeof(pipeRate), "%.0f", r.pipe_Bps);
    else
        std::snprintf(pipeRate, sizeof(pipeRate), "NO-DATA");

    char fill[32];
    if (r.fill_ok)
        std::snprintf(fill, sizeof(fill), "%.3f", r.fill_peak);
    else
        std::snprintf(fill, sizeof(fill), "NO-DATA");

    char peak[32], cap[32];
    if (r.pipe_avail_peak_bytes >= 0)
        std::snprintf(peak, sizeof(peak), "%d", r.pipe_avail_peak_bytes);
    else
        std::snprintf(peak, sizeof(peak), "NO-DATA");
    if (r.pipe_capacity_bytes >= 0)
        std::snprintf(cap, sizeof(cap), "%d", r.pipe_capacity_bytes);
    else
        std::snprintf(cap, sizeof(cap), "NO-DATA");

    char dpipe[32];
    if (r.pipe_rate_ok)
        std::snprintf(dpipe, sizeof(dpipe), "%lld", static_cast<long long>(r.d_pipe_bytes));
    else
        std::snprintf(dpipe, sizeof(dpipe), "NO-DATA");

    const char* bp = "NO-DATA";
    if (r.established) {
        if (r.cls == SupplyRegimeClass::StarvedByBackpressure)
            bp = "yes";
        else if (r.cls == SupplyRegimeClass::StarvedByPath)
            bp = "no";
        else if (r.fill_ok)
            bp = "ambiguous";
        else if (r.cls == SupplyRegimeClass::Ok)
            bp = "no";
    }

    char buf[768];
    if (r.established) {
        std::snprintf(
            buf, sizeof(buf),
            "supply_regime=%s supply_regime_reason=%s "
            "pipe_Bps=%s pipe_Bps_src=d_pipe_bytes/d_wall_s "
            "pipe_bytes_scope=rawvideo_stdout_NOT_http "
            "d_pipe_bytes=%s "
            "pipe_fill_peak=%s pipe_avail_peak_B=%s pipe_cap_B=%s "
            "pipe_fill_src=FIONREAD_peak/F_GETPIPE_SZ "
            "backpressure=%s "
            "supply_ratio_trust_note=submitted_not_played_min_wall_s=%.1f "
            "supply_regime_tag=measured",
            r.class_str, r.reason, pipeRate, dpipe, fill, peak, cap, bp,
            kSupplyRatioMinTrustWallS);
    } else {
        std::snprintf(
            buf, sizeof(buf),
            "supply_regime=NO-DATA supply_regime_reason=%s "
            "pipe_Bps=%s pipe_Bps_src=d_pipe_bytes/d_wall_s "
            "pipe_bytes_scope=rawvideo_stdout_NOT_http "
            "d_pipe_bytes=%s "
            "pipe_fill_peak=%s pipe_avail_peak_B=%s pipe_cap_B=%s "
            "pipe_fill_src=FIONREAD_peak/F_GETPIPE_SZ "
            "backpressure=NO-DATA "
            "supply_ratio_trust_note=submitted_not_played_min_wall_s=%.1f "
            "supply_regime_tag=NO-DATA",
            r.reason, pipeRate, dpipe, fill, peak, cap, kSupplyRatioMinTrustWallS);
    }
    return std::string(buf);
}

// Best-effort /proc/<pid>/io rchar reader. Returns false → NO-DATA (never 0).
inline bool readProcPidIoRchar(int pid, int64_t* out_rchar) {
    if (!out_rchar || pid <= 0)
        return false;
    char path[64];
    std::snprintf(path, sizeof(path), "/proc/%d/io", pid);
    FILE* f = std::fopen(path, "r");
    if (!f)
        return false;
    char line[128];
    bool ok = false;
    while (std::fgets(line, sizeof(line), f)) {
        if (std::strncmp(line, "rchar:", 6) == 0) {
            long long v = 0;
            if (std::sscanf(line + 6, "%lld", &v) == 1 && v >= 0) {
                *out_rchar = static_cast<int64_t>(v);
                ok = true;
            }
            break;
        }
    }
    std::fclose(f);
    return ok;
}

inline std::string formatFfmpegRcharFragment(bool ok, double bps, int64_t d_rchar) {
    char buf[240];
    if (ok) {
        std::snprintf(buf, sizeof(buf),
                      "ffmpeg_rchar_Bps=%.0f ffmpeg_rchar_Bps_src=d_rchar/d_wall_s "
                      "d_ffmpeg_rchar=%lld ffmpeg_rchar_scope=child_proc_io_NOT_tcp "
                      "ffmpeg_rchar_tag=measured",
                      bps, static_cast<long long>(d_rchar));
    } else {
        std::snprintf(buf, sizeof(buf),
                      "ffmpeg_rchar_Bps=NO-DATA ffmpeg_rchar_Bps_src=d_rchar/d_wall_s "
                      "d_ffmpeg_rchar=NO-DATA ffmpeg_rchar_scope=child_proc_io_NOT_tcp "
                      "ffmpeg_rchar_tag=NO-DATA");
    }
    return std::string(buf);
}

} // namespace misterplex
