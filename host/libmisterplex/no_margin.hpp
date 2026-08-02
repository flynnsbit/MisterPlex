// No-link-margin classification — design implementation without magic bitrates.
//
// Parent ladder (rk30/rk34/rk35) falsified "2000 kbit request causes drops".
// What remains is intermittent stress when delivered goodput sits near path
// capacity with near-zero margin. This header only *classifies and recommends
// operator-visible actions*; it does NOT rewrite maxVideoBitrate.
//
// Anti-oscillation: any future adaptive path must go through multi-window
// streaks (see link_cap.hpp hysteresis). Single blips on RTT 2.9–227 ms WiFi
// must never flip policy.
#pragma once

#include <cmath>
#include <cstdint>
#include <string>

namespace misterplex {

// supply_iv: Δaudio_s / Δwall_s over a steady window (startup excluded).
// Parent uses last 2/3 of the cast window. Values:
//   ~1.0 healthy realtime
//   <<1 starved / not realtime
// Empty / non-finite → NO-DATA (never treat as 0.0 success).
struct NoMarginSample {
    double supply_iv = 0.0;          // required; must be finite and >0 to score
    bool supply_iv_ok = false;       // false = NO-DATA
    double goodput_mbit_s = 0.0;     // optional; 0 + !goodput_ok = NO-DATA
    bool goodput_ok = false;
    double capacity_mbit_s = 0.0;    // optional path capacity estimate
    bool capacity_ok = false;
    int drop_delta = 0;              // presents dropped in window; <0 = NO-DATA
    bool drop_delta_ok = false;
};

enum class NoMarginClass {
    NoData = 0,
    HealthyHeadroom,   // realtime + goodput well under capacity (or capacity unknown)
    HealthyTight,      // realtime but goodput ≥ tightFrac * capacity
    IntermittentStress,// realtime now but drop_delta>0 while tight — user-wording class
    SustainedStarve,   // supply_iv clearly below starveThr for this window
};

struct NoMarginDecision {
    NoMarginClass cls = NoMarginClass::NoData;
    const char* name = "NO-DATA";
    // Operator-facing recommendation only — daemon must not auto-apply without
    // explicit conf and hysteresis.
    const char* action = "none";
    std::string detail;
};

inline const char* noMarginClassName(NoMarginClass c) {
    switch (c) {
    case NoMarginClass::HealthyHeadroom:
        return "HEALTHY_HEADROOM";
    case NoMarginClass::HealthyTight:
        return "HEALTHY_TIGHT";
    case NoMarginClass::IntermittentStress:
        return "INTERMITTENT_STRESS";
    case NoMarginClass::SustainedStarve:
        return "SUSTAINED_STARVE";
    default:
        return "NO-DATA";
    }
}

// Defaults chosen as *classification* thresholds, not product bitrate constants.
// starveThr: below this supply_iv is not realtime (parent collapse was ~0.47;
//            healthy ladder sits ~0.99). 0.90 leaves room for measurement noise.
// tightFrac: goodput/capacity ≥ this ⇒ near saturation (parent ~1.0 on rk30).
// These may be conf-tuned later; they are not maxVideoBitrate.
inline NoMarginDecision classifyNoMargin(const NoMarginSample& s,
                                         double starveThr = 0.90,
                                         double tightFrac = 0.90) {
    NoMarginDecision d;
    if (!s.supply_iv_ok || !std::isfinite(s.supply_iv) || s.supply_iv <= 0.0) {
        d.cls = NoMarginClass::NoData;
        d.name = noMarginClassName(d.cls);
        d.action = "none";
        d.detail = "supply_iv=NO-DATA";
        return d;
    }

    const bool starved = s.supply_iv < starveThr;
    bool tight = false;
    if (s.goodput_ok && s.capacity_ok && s.capacity_mbit_s > 0.0 &&
        std::isfinite(s.goodput_mbit_s) && std::isfinite(s.capacity_mbit_s)) {
        tight = (s.goodput_mbit_s / s.capacity_mbit_s) >= tightFrac;
    }

    if (starved) {
        d.cls = NoMarginClass::SustainedStarve;
        d.name = noMarginClassName(d.cls);
        // Do NOT auto-lower bitrate. Surface + optional operator ladder/tier.
        d.action = "log_warn_no_auto_bitrate; optional_operator_lower_tier_or_fix_path";
        d.detail = "supply_iv=" + std::to_string(s.supply_iv) + " < starveThr=" +
                   std::to_string(starveThr);
        return d;
    }

    const bool drops = s.drop_delta_ok && s.drop_delta > 0;
    if (tight && drops) {
        d.cls = NoMarginClass::IntermittentStress;
        d.name = noMarginClassName(d.cls);
        d.action = "log_info_intermittent; prefer_SUSPEND_MAIN_if_CPU; do_not_oscillate_bitrate";
        d.detail = "realtime supply_iv=" + std::to_string(s.supply_iv) +
                   " but drop_delta=" + std::to_string(s.drop_delta) +
                   " with goodput/capacity tight";
        return d;
    }

    if (tight) {
        d.cls = NoMarginClass::HealthyTight;
        d.name = noMarginClassName(d.cls);
        d.action = "observe_only; margin_near_zero";
        d.detail = "realtime + tight goodput/capacity; intermittent drops possible on perturbation";
        return d;
    }

    d.cls = NoMarginClass::HealthyHeadroom;
    d.name = noMarginClassName(d.cls);
    d.action = "none";
    d.detail = "realtime supply_iv=" + std::to_string(s.supply_iv) +
               (s.capacity_ok ? " capacity_known" : " capacity=NO-DATA");
    return d;
}

// Streak gate for any future *action* (not mere log class). Prevents WiFi blip
// oscillation: require `need` consecutive windows of the same actionable class
// before recommending a sticky operator hint change.
struct NoMarginStreakState {
    NoMarginClass last = NoMarginClass::NoData;
    int streak = 0;
};

inline bool noMarginStreakReady(NoMarginStreakState& st, NoMarginClass now, int need = 3) {
    if (now == NoMarginClass::NoData) {
        st.streak = 0;
        st.last = now;
        return false;
    }
    if (now == st.last)
        st.streak++;
    else {
        st.last = now;
        st.streak = 1;
    }
    return st.streak >= need;
}

} // namespace misterplex
