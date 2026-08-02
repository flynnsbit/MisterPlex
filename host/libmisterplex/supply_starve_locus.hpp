// Starve LOCUS: where is supply_ratio starvation, given local back-pressure
// was falsified on hardware (parent 2026-08-02).
//
// Verbatim device evidence that retired "starved_by_backpressure" as the
// default story for the 480p collapse:
//   ffmpeg: 20x futex_wait / 1x do_sys_poll — ZERO pipe_write
//   misterplexd: wchan=pipe_read (consumer waiting)
//   recv_q=0 in 9/10 windows; rcv_space healthy; PMS speed=19.8 complete=1
//   Bytes ~50 KB/s while lone curl gets 127 KB/s on same path
//
// Classes (do NOT force a locus the probes cannot support):
//   ok                 — supply_ratio >= ok_min
//   starved_transport  — starved AND probes show producer not blocked on us
//                        AND consumer waiting AND socket not queued
//   starved_consumer   — starved AND probes show we/ffmpeg not draining
//                        (pipe_write blocked, high recv_q, high pipe fill)
//   starved_unknown    — starved but probes missing/conflicting — COMMON
//   NO-DATA            — supply_ratio not established
//   SESSION_INVALID    — process_epoch / session_epoch / pid changed mid-window
//
// Signals (only those sampleable on device without inventing):
//   supply_ratio          media: line / audio_s÷wall_s
//   sock_Bps              optional measured socket/HTTP byte rate
//   recv_q                optional TCP Recv-Q (NO-DATA ≠ 0)
//   ffmpeg_wchan_*        optional: any thread in pipe_write?
//   daemon_wchan_*        optional: any thread in pipe_read?
//   pipe_fill / backpressure from supply_regime (optional)
//
// drops = pacer Drop ONLY (media_player.cpp droppedFrames_.fetch_add on
// !present path ~:4184). Free ledger residual = frames - presents - drops
// (frame_ledger.hpp). publish_misses is separate.
//
// Counter resets per stream: droppedFrames_/publishMisses_ store(0) :3009/:3010;
// presentCount_ = 0 at raw path :3133. Respawn zeroes them — detect via
// session_epoch / process_epoch / pid change → SESSION_INVALID.
//
// Rule 0: missing probe → NO-DATA field, never 0.0. starved_unknown is honest.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

// Tri-state probe: Unknown must not collapse to false/0.
enum class ProbeTri { Unknown = 0, No = 1, Yes = 2 };

inline const char* probeTriStr(ProbeTri t) {
    switch (t) {
    case ProbeTri::Yes:
        return "yes";
    case ProbeTri::No:
        return "no";
    default:
        return "NO-DATA";
    }
}

enum class StarveLocusClass {
    NoData = 0,
    Ok = 1,
    StarvedTransport = 2,
    StarvedConsumer = 3,
    StarvedUnknown = 4,
    SessionInvalid = 5,
};

inline const char* starveLocusClassStr(StarveLocusClass c) {
    switch (c) {
    case StarveLocusClass::Ok:
        return "ok";
    case StarveLocusClass::StarvedTransport:
        return "starved_transport";
    case StarveLocusClass::StarvedConsumer:
        return "starved_consumer";
    case StarveLocusClass::StarvedUnknown:
        return "starved_unknown";
    case StarveLocusClass::SessionInvalid:
        return "SESSION_INVALID";
    default:
        return "NO-DATA";
    }
}

struct StarveLocusInput {
    bool session_invalid = false; // epoch/pid change mid-window

    bool supply_established = false;
    double supply_ratio = 0.0;
    double ok_min = 0.90;
    const char* ok_min_src = "DEFAULT_ASSUMED";

    // Optional probes — Unknown unless parent/script measured them.
    ProbeTri ffmpeg_in_pipe_write = ProbeTri::Unknown;
    ProbeTri daemon_in_pipe_read = ProbeTri::Unknown;
    bool recv_q_measured = false;
    int64_t recv_q = -1; // only if measured; 0 is a real measurement
    bool sock_Bps_measured = false;
    double sock_Bps = 0.0;
    bool pipe_fill_measured = false;
    double pipe_fill_peak = 0.0; // 0..1
    double pipe_fill_full_min = 0.80;  // DEFAULT_ASSUMED
    double pipe_fill_empty_max = 0.10; // DEFAULT_ASSUMED

    // Free ledger (always arithmetic when counters present)
    bool ledger_ok = false;
    int64_t frames = 0;
    int64_t presents = 0;
    int64_t drops = 0; // pacer only
    int64_t publish_misses = 0;
    // residual = frames - presents - drops (NOT publish_misses)
};

struct StarveLocusResult {
    StarveLocusClass cls = StarveLocusClass::NoData;
    const char* class_str = "NO-DATA";
    const char* reason = "unset";
    bool supply_starved = false;
    double supply_ratio = 0.0;
    bool supply_established = false;
    double ok_min = 0.90;
    const char* ok_min_src = "DEFAULT_ASSUMED";

    int64_t residual = 0; // frames-presents-drops when ledger_ok
    bool residual_ok = false;
    const char* residual_eq = "frames-presents-drops";
    const char* drops_src = "av_pacer_only";
};

inline StarveLocusResult computeStarveLocus(const StarveLocusInput& in) {
    StarveLocusResult r;
    r.ok_min = in.ok_min;
    r.ok_min_src = (in.ok_min_src && in.ok_min_src[0]) ? in.ok_min_src : "DEFAULT_ASSUMED";
    r.supply_ratio = in.supply_ratio;
    r.supply_established = in.supply_established;

    if (in.ledger_ok) {
        r.residual_ok = true;
        r.residual = in.frames - in.presents - in.drops;
    }

    if (in.session_invalid) {
        r.cls = StarveLocusClass::SessionInvalid;
        r.class_str = starveLocusClassStr(r.cls);
        r.reason = "session_epoch_or_pid_changed";
        return r;
    }

    if (!in.supply_established || !std::isfinite(in.supply_ratio)) {
        r.cls = StarveLocusClass::NoData;
        r.class_str = starveLocusClassStr(r.cls);
        r.reason = "supply_ratio_NO-DATA";
        return r;
    }

    r.supply_starved = (in.supply_ratio + 1e-15 < in.ok_min);
    if (!r.supply_starved) {
        r.cls = StarveLocusClass::Ok;
        r.class_str = starveLocusClassStr(r.cls);
        r.reason = "supply_ok";
        return r;
    }

    // --- starved: try to localise; default unknown ---
    const bool fill_full =
        in.pipe_fill_measured && in.pipe_fill_peak >= in.pipe_fill_full_min;
    const bool fill_empty =
        in.pipe_fill_measured && in.pipe_fill_peak < in.pipe_fill_empty_max;
    const bool recv_high =
        in.recv_q_measured && in.recv_q > 0; // any queued bytes = not drained
    const bool recv_zero = in.recv_q_measured && in.recv_q == 0;

    // Consumer-side: we/ffmpeg not draining what has already arrived.
    if (in.ffmpeg_in_pipe_write == ProbeTri::Yes || fill_full || recv_high) {
        r.cls = StarveLocusClass::StarvedConsumer;
        r.class_str = starveLocusClassStr(r.cls);
        if (in.ffmpeg_in_pipe_write == ProbeTri::Yes)
            r.reason = "ffmpeg_blocked_pipe_write";
        else if (fill_full)
            r.reason = "rawvideo_pipe_full";
        else
            r.reason = "recv_q_nonzero";
        return r;
    }

    // Transport-side: consumer waiting, producer not write-blocked, socket empty.
    // Requires POSITIVE evidence on the key probes — missing → unknown.
    const bool consumer_waiting = (in.daemon_in_pipe_read == ProbeTri::Yes) || fill_empty;
    const bool producer_not_blocked = (in.ffmpeg_in_pipe_write == ProbeTri::No);
    const bool socket_empty = recv_zero;

    if (consumer_waiting && producer_not_blocked && socket_empty) {
        r.cls = StarveLocusClass::StarvedTransport;
        r.class_str = starveLocusClassStr(r.cls);
        r.reason = "consumer_wait_producer_idle_recv_q_0";
        return r;
    }

    // Parent collapse shape with only partial probes still → unknown unless
    // the full transport triad is present.
    r.cls = StarveLocusClass::StarvedUnknown;
    r.class_str = starveLocusClassStr(r.cls);
    if (!in.recv_q_measured && in.ffmpeg_in_pipe_write == ProbeTri::Unknown &&
        in.daemon_in_pipe_read == ProbeTri::Unknown && !in.pipe_fill_measured)
        r.reason = "starved_no_locus_probes";
    else if (in.ffmpeg_in_pipe_write == ProbeTri::Unknown ||
             in.daemon_in_pipe_read == ProbeTri::Unknown || !in.recv_q_measured)
        r.reason = "starved_partial_probes";
    else
        r.reason = "starved_probes_conflict";
    return r;
}

// Gate rc for parent script / unit tests.
//   0 ok
//   2 starved_transport
//   3 starved_consumer
//   4 starved_unknown   (hard — positively starved, locus not proven)
//  79 SESSION_INVALID
//  77 NO-DATA
inline int starveLocusGateRc(const StarveLocusResult& r) {
    switch (r.cls) {
    case StarveLocusClass::Ok:
        return 0;
    case StarveLocusClass::StarvedTransport:
        return 2;
    case StarveLocusClass::StarvedConsumer:
        return 3;
    case StarveLocusClass::StarvedUnknown:
        return 4;
    case StarveLocusClass::SessionInvalid:
        return 79;
    default:
        return 77;
    }
}

inline std::string formatStarveLocusFragment(const StarveLocusResult& r) {
    char ratio[32];
    if (r.supply_established)
        std::snprintf(ratio, sizeof(ratio), "%.3f", r.supply_ratio);
    else
        std::snprintf(ratio, sizeof(ratio), "NO-DATA");

    char resid[32];
    if (r.residual_ok)
        std::snprintf(resid, sizeof(resid), "%lld", static_cast<long long>(r.residual));
    else
        std::snprintf(resid, sizeof(resid), "NO-DATA");

    char buf[512];
    std::snprintf(buf, sizeof(buf),
                  "starve_locus=%s starve_locus_reason=%s "
                  "supply_ratio=%s supply_ratio_ok_min=%.3f "
                  "supply_ratio_ok_min_src=%s "
                  "residual=%s residual_eq=%s "
                  "drops_src=%s "
                  "starve_locus_tag=%s",
                  r.class_str, r.reason, ratio, r.ok_min, r.ok_min_src, resid,
                  r.residual_eq, r.drops_src,
                  (r.cls == StarveLocusClass::NoData ||
                   r.cls == StarveLocusClass::SessionInvalid)
                      ? "NO-DATA"
                      : "measured");
    return std::string(buf);
}

} // namespace misterplex
